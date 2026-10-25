#!/usr/bin/env bash
# PTY streaming smoke: hub + dev-proxy + bridge from THIS tree on isolated ports, one
# interactive shell session, a Node ws client counting frames/bytes on the viewer socket,
# and the hub's /metrics counters for the bridge->hub hop.
#
#   SMOKE_ROOT=<dir with src/>  (defaults to this tree)  SMOKE_TAG=after scripts/pty-stream-smoke.sh
#
# Ports: hub 18081, proxy 18080, bridge 19327/19328 (override via SMOKE_* env). Everything
# lives under $HOME/.cache/heimdall-tests/smoke-<tag> (never /tmp: new binaries there get
# SIGKILLed by the endpoint agent). Tears everything down on exit.
set -euo pipefail
ROOT="${SMOKE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CLIENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${SMOKE_TAG:-after}"
HUB_PORT="${SMOKE_HUB_PORT:-18081}"
PROXY_PORT="${SMOKE_PROXY_PORT:-18080}"
B_PORT="${SMOKE_BRIDGE_PORT:-19327}"
B_LOCAL="${SMOKE_BRIDGE_LOCAL:-19328}"
METRICS_PORT="${SMOKE_METRICS_PORT:-18091}"
PTY_HOST_BIN="${SMOKE_PTY_HOST_BIN:-/usr/local/google/home/tanmayvijay/heimdall-agent-manager/result-ptyhost/bin/ham-pty-host}"
WORK="$HOME/.cache/heimdall-tests/smoke-$TAG"
rm -rf "$WORK"; mkdir -p "$WORK/bin" "$WORK/run-b" "$WORK/logs"
PIDS=()
SID=""
# shellcheck source=lib/hub-oidc-dev.sh
. "$CLIENT_DIR/scripts/lib/hub-oidc-dev.sh"
AUTH=()
UI="http://127.0.0.1:$PROXY_PORT"
cleanup() {
  [ -n "$SID" ] && curl -s "${AUTH[@]}" -X DELETE "http://127.0.0.1:$PROXY_PORT/api/v1/shells/$SID" >/dev/null 2>&1 || true
  hub_oidc_stop_mock
  sleep 1
  for pid in "${PIDS[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null || true; done
  sleep 1
  for pid in $(pgrep -f "pty-host.*$WORK" 2>/dev/null || true); do kill "$pid" 2>/dev/null || true; done
  for pid in "${PIDS[@]:-}"; do [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true; done
  echo "[smoke] torn down; logs in $WORK/logs"
}
trap cleanup EXIT
port_busy() { ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$1\$"; }
for p in "$HUB_PORT" "$PROXY_PORT" "$B_PORT" "$B_LOCAL" "$METRICS_PORT"; do
  port_busy "$p" && { echo "[smoke] port $p busy" >&2; exit 1; }
done
export PATH="$HOME/.local/bin:$PATH"
export LIBRARY_PATH="/nix/store/7a0nx1a0rdc5s07vxrsdhplqnzncl5z9-sqlite-3.53.3/lib:${LIBRARY_PATH:-}"
echo "[smoke] building from $ROOT"
( cd "$ROOT" && odin build src/hub -collection:odin_test=src -out:"$WORK/bin/hub" \
  && odin build src/bridge -collection:odin_test=src -out:"$WORK/bin/bridge" \
  && odin build src/dev_proxy -collection:odin_test=src -out:"$WORK/bin/devproxy" )

# Users sign in only with OIDC: run the mock provider and sign in as tanmay below.
hub_oidc_start_mock "$WORK/logs" tanmay
hub_oidc_export_env
HEIMDALL_METRICS_ADDR="127.0.0.1:$METRICS_PORT" "$WORK/bin/hub" --listen "127.0.0.1:$HUB_PORT" --db "$WORK/hub.db" --migrations-dir "$ROOT/src/hub/repository/sqlite/migrations" --ui-origin "$UI" > "$WORK/logs/hub.log" 2>&1 & PIDS+=($!)
"$WORK/bin/devproxy" --listen "127.0.0.1:$PROXY_PORT" --hub-url "http://127.0.0.1:$HUB_PORT" --default-user tanmay > "$WORK/logs/devproxy.log" 2>&1 & PIDS+=($!)
for _ in $(seq 1 120); do curl -sf -o /dev/null "http://127.0.0.1:$PROXY_PORT/api/v1/health" && break || sleep 0.25; done
SESSION="$(hub_oidc_login "$UI" tanmay)"
AUTH=(-H "$(hub_oidc_cookie "$SESSION")" -H "Origin: $UI")
api() { curl -s "${AUTH[@]}" -X "$1" "http://127.0.0.1:$PROXY_PORT$2" -H 'Content-Type: application/json' ${3:+-d "$3"}; }

AUTHZ="$(api POST /api/v1/device/authorize '{"client":"ham-bridge","device_label":"pty-smoke","os":"linux","os_user":"tester","bridge_public_key":"040102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40","code_challenge":"J6jJRRlTiLmCVJAjMgzOjMLRQ-xSS_tovxAjutN8JWI","code_challenge_method":"S256"}')"
USER_CODE="$(printf '%s' "$AUTHZ" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["user_code"])')"
DEVICE_CODE="$(printf '%s' "$AUTHZ" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["device_code"])')"
api POST /api/v1/device/approve "{\"user_code\":\"$USER_CODE\",\"approve\":true}" >/dev/null
TOKEN_RESP="$(api POST /api/v1/device/token "{\"device_code\":\"$DEVICE_CODE\",\"code_verifier\":\"heimdall-req-impl-6-test-code-verifier-aaaa\"}")"
printf '%s' "$TOKEN_RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["access_token"])' > "$WORK/b.token"
printf '%s' "$TOKEN_RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"].get("refresh_token",""))' > "$WORK/b.token.refresh"
chmod 600 "$WORK/b.token" "$WORK/b.token.refresh"

HEIMDALL_BRIDGE_PTY_HOST=1 HEIMDALL_HAM_PTY_HOST_BIN="$PTY_HOST_BIN" \
"$WORK/bin/bridge" --hub "http://127.0.0.1:$HUB_PORT" --bridge-token-file "$WORK/b.token" \
  --bind-host 127.0.0.1 --port "$B_PORT" --local-endpoint-port "$B_LOCAL" --local-run-dir "$WORK/run-b" > "$WORK/logs/bridge.log" 2>&1 & PIDS+=($!)
for _ in $(seq 1 60); do grep -q "runtime ready" "$WORK/logs/bridge.log" 2>/dev/null && break || sleep 0.5; done
grep -q "runtime ready" "$WORK/logs/bridge.log" || { echo "[smoke] bridge never connected"; tail -20 "$WORK/logs/bridge.log"; exit 1; }
B_ID="$(api GET /api/v1/bridges | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][-1]["bridge_id"])')"
echo "[smoke] bridge = $B_ID"
api PUT /api/v1/me/experiments/streaming_terminal_pane '{"enabled":true}' >/dev/null
SID="$(api POST "/api/v1/bridges/$B_ID/shells" '{"kind":"shell"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["session"]["session_id"])')"
echo "[smoke] session = $SID"
sleep 1

metrics() { curl -s "http://127.0.0.1:$METRICS_PORT/metrics" | grep -E "^heimdall_shell_(output_bytes_total|output_frames_total|fanout_bytes_total|input_bytes_total)|^heimdall_bridge_ws_frames_total.*(shell_pty_output|shell_pty_input)" || true; }
echo "[smoke] --- metrics before ---"; metrics
( cd "$CLIENT_DIR" && SMOKE_LEGACY="${SMOKE_LEGACY:-}" SMOKE_COOKIE="__Host-heimdall_session=$SESSION" SMOKE_ORIGIN="$UI" SMOKE_WS_URL="ws://127.0.0.1:$PROXY_PORT/api/v1/shells/$SID/stream" node scripts/pty-stream-smoke-client.mjs ) | tee "$WORK/logs/client.log"
echo "[smoke] --- metrics after ---"; metrics
echo "[smoke] bridge log tail:"; grep -E "compact|overflow|WARN" "$WORK/logs/bridge.log" | tail -5 || true
