#!/usr/bin/env bash
# REQ-XM-4 end-to-end: an echo CLIENT and an echo SERVER hold a conversation across
# two bridges and the hub.
#
#   client -> bridge A local endpoint -> hub -> bridge B -> echo server
#          <-                        <-     <-            <-
#
# This is the acceptance test for the proxy path: it proves not merely that a request
# reaches the far side, but that a real client and a real server exchange payloads
# that come back byte-for-byte identical, including payloads large enough to span
# several tunnel frames (which is what actually exercises chunk ordering and
# reassembly rather than just connectivity).
#
# Nothing here talks to the hub or to bridge B directly — the client only ever
# contacts bridge A's local endpoint, which is the whole point of the feature: no
# inbound port, no user bearer token, no browser session anywhere in the path.
#
# Stands up a THROWAWAY stack on its own ports and tears it down again. It never
# touches a stack it did not start: every process it launches is recorded by PID and
# only those PIDs are killed. (Do not "clean up" by pattern-matching command lines on
# a shared host — that takes down other people's stacks.)
#
# Usage:
#   tests/e2e_xm4_proxy_echo_test.sh
#
# Point it somewhere else with env vars (all optional):
#   XM4_HUB_PORT       hub listen port                  (default 8391)
#   XM4_PROXY_PORT     dev-proxy port (auth injection)  (default 8390)
#   XM4_BRIDGE_A_PORT  bridge A service port            (default 49725)
#   XM4_BRIDGE_A_LOCAL bridge A LOCAL ENDPOINT port     (default 49726) <- client target
#   XM4_BRIDGE_B_PORT  bridge B service port            (default 49727)
#   XM4_BRIDGE_B_LOCAL bridge B local endpoint port     (default 49728)
#   XM4_ECHO_PORT      echo server port on bridge B     (default 45201)
#   XM4_ROUNDS         payload-set repetitions          (default 3)
#   XM4_KEEP=1         leave the stack running for poking at afterwards
#   ODIN               odin binary (default: odin on PATH, via nix develop)
#
# Requires: a working odin toolchain (the repo's nix dev shell provides one) and
# python3. Exits 0 only if every round trip came back byte-identical.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"

HUB_PORT="${XM4_HUB_PORT:-8391}"
PROXY_PORT="${XM4_PROXY_PORT:-8390}"
A_PORT="${XM4_BRIDGE_A_PORT:-49725}"
A_LOCAL="${XM4_BRIDGE_A_LOCAL:-49726}"
B_PORT="${XM4_BRIDGE_B_PORT:-49727}"
B_LOCAL="${XM4_BRIDGE_B_LOCAL:-49728}"
ECHO_PORT="${XM4_ECHO_PORT:-45201}"
ROUNDS="${XM4_ROUNDS:-3}"

SESSION_ID=""
WORK="$(mktemp -d -t xm4-echo-XXXX)"
BIN="$WORK/bin"; mkdir -p "$BIN" "$WORK/run-a" "$WORK/run-b" "$WORK/logs"

# Only these PIDs are ever killed. NEVER clean up by pattern-matching command lines
# on a shared host: a substring like a username or a flag value is shared by every
# stack on the box, and matching it takes down other people's work.
PIDS=()
# shellcheck source=../scripts/lib/hub-oidc-dev.sh
. "$ROOT/scripts/lib/hub-oidc-dev.sh"
# Browser-session auth for requests through the dev-proxy (filled after sign-in).
AUTH=()
pcurl() { curl "${AUTH[@]}" "$@"; }

cleanup() {
  if [ "${XM4_KEEP:-0}" = "1" ]; then
    echo "[xm4] XM4_KEEP=1 — leaving stack up. Work dir: $WORK"
    echo "[xm4]   client: python3 tests/xm4_echo_client.py --endpoint 127.0.0.1:$A_LOCAL --session-id ${SESSION_ID:-<none>}"
    return
  fi
  # Kill the echo server FIRST, through the hub, while the stack is still alive.
  # It is a GRANDCHILD (bridge B spawns it via its pty-host daemon), so it is not in
  # PIDS and killing the bridge alone orphans it — leaving $ECHO_PORT bound and making
  # the next run fail its own port precheck.
  if [ -n "${SESSION_ID:-}" ]; then
    pcurl -s -X DELETE "http://127.0.0.1:$PROXY_PORT/api/v1/shells/$SESSION_ID" >/dev/null 2>&1 || true
    sleep 1
  fi
  for pid in "${PIDS[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null || true; done
  sleep 1
  # The per-bridge pty-host daemons are also grandchildren. Match them on THIS RUN'S
  # work dir, which no other stack can share — never on the binary name alone.
  for pid in $(pgrep -f "pty-host.*$WORK" 2>/dev/null || true); do kill "$pid" 2>/dev/null || true; done
  # Last resort for the echo server if the hub-side kill did not land (e.g. the hub
  # died early): match this run's own script path AND port, not either alone.
  for pid in $(pgrep -f "xm4_echo_server.py $ECHO_PORT" 2>/dev/null || true); do kill "$pid" 2>/dev/null || true; done
  sleep 1
  rm -rf "$WORK"
  hub_oidc_stop_mock
}
trap cleanup EXIT

port_busy() { ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$1\$"; }
for p in "$HUB_PORT" "$PROXY_PORT" "$A_PORT" "$A_LOCAL" "$B_PORT" "$B_LOCAL" "$ECHO_PORT"; do
  if port_busy "$p"; then
    echo "[xm4] FAIL: port $p is already in use. Override the XM4_* env vars to pick a free block." >&2
    exit 1
  fi
done

echo "[xm4] building hub, bridge and dev-proxy"
ODIN_BIN="${ODIN:-odin}"
build() { "$ODIN_BIN" build "$1" -collection:odin_test=src -out:"$2"; }
if command -v "$ODIN_BIN" >/dev/null 2>&1; then
  build src/hub "$BIN/hub"; build src/bridge "$BIN/bridge"; build src/dev_proxy "$BIN/devproxy"
else
  # The hub links against sqlite3, which is only on the search path inside the dev shell.
  nix develop "$ROOT" --command bash -c "cd '$ROOT' && odin build src/hub -collection:odin_test=src -out:'$BIN/hub' && odin build src/bridge -collection:odin_test=src -out:'$BIN/bridge' && odin build src/dev_proxy -collection:odin_test=src -out:'$BIN/devproxy'"
fi

echo "[xm4] starting hub on 127.0.0.1:$HUB_PORT"
hub_oidc_start_mock "$WORK" tanmay
hub_oidc_export_env
"$BIN/hub" --listen "127.0.0.1:$HUB_PORT" --db "$WORK/hub.db" --ui-origin "http://127.0.0.1:$PROXY_PORT" \
  > "$WORK/logs/hub.log" 2>&1 & PIDS+=($!)

echo "[xm4] starting dev-proxy on 127.0.0.1:$PROXY_PORT (forwards the browser session; sign-in via mock OIDC)"
"$BIN/devproxy" --listen "127.0.0.1:$PROXY_PORT" --hub-url "http://127.0.0.1:$HUB_PORT" --default-user tanmay \
  > "$WORK/logs/devproxy.log" 2>&1 & PIDS+=($!)

for _ in $(seq 1 40); do
  curl -sf -o /dev/null "http://127.0.0.1:$PROXY_PORT/api/v1/health" && break || sleep 0.25
done

# Sign in as tanmay through the dev-proxy: real OIDC flow against the mock provider.
SESSION="$(hub_oidc_login "http://127.0.0.1:$PROXY_PORT" tanmay)" || { echo "[xm4] FAIL: OIDC sign-in failed"; exit 1; }
AUTH=(-H "$(hub_oidc_cookie "$SESSION")" -H "Origin: http://127.0.0.1:$PROXY_PORT")

api() { pcurl -s -X "$1" "http://127.0.0.1:$PROXY_PORT$2" -H 'Content-Type: application/json' ${3:+-d "$3"}; }

enroll() { # $1=label $2=token file -> writes the ACCESS token to $2
  # ===== BROWSER-APPROVED DEVICE FLOW (REQ-ENROLL-9) =====
  #
  # This replaced "mint a one-time enrollment token, then exchange it at
  # POST /api/v1/bridges/enroll". Both endpoints are deleted and 404 now, and
  # `bridge enroll --hub --enrollment-token` is gone with them.
  #
  # It drives the three HTTP steps directly rather than shelling out to
  # `bridge enroll --hub`, because that command waits for an approval and would
  # need backgrounding plus output scraping. Here the script IS the approver:
  # these suites talk through the dev-proxy, which authenticates every request
  # as the local user, so the approval is a real authenticated one.
  #
  # Three things that are hard refusals, not warnings:
  #   - bridge_public_key must be a 130-char lowercase-hex uncompressed P-256 point
  #   - do NOT send bridge_key_fingerprint; the Hub derives it and rejects a
  #     body-supplied one that disagrees
  #   - PKCE is mandatory and S256-only; the pair below is precomputed
  local authz user_code device_code tok
  authz="$(api POST /api/v1/device/authorize "{\"client\":\"ham-bridge\",\"device_label\":\"$1\",\"os\":\"linux\",\"os_user\":\"tester\",\"bridge_public_key\":\"040102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40\",\"code_challenge\":\"J6jJRRlTiLmCVJAjMgzOjMLRQ-xSS_tovxAjutN8JWI\",\"code_challenge_method\":\"S256\"}")"
  user_code="$(printf '%s' "$authz" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["user_code"])')"
  device_code="$(printf '%s' "$authz" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["device_code"])')"
  api POST /api/v1/device/approve "{\"user_code\":\"$user_code\",\"approve\":true}" >/dev/null
  # The access token is the credential; the refresh half goes beside it under
  # the ".refresh" suffix the bridge itself uses, so a bridge started with
  # --bridge-token-file "$2" can renew rather than dying after an hour.
  tok="$(api POST /api/v1/device/token "{\"device_code\":\"$device_code\",\"code_verifier\":\"heimdall-req-impl-6-test-code-verifier-aaaa\"}")"
  printf '%s' "$tok" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["access_token"])' > "$2"
  printf '%s' "$tok" | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print(d.get("refresh_token",""))' > "$2.refresh"
  chmod 600 "$2" "$2.refresh"
}

echo "[xm4] enrolling bridge A (originating) and bridge B (target)"
enroll xm4-echo-A "$WORK/a.token"
enroll xm4-echo-B "$WORK/b.token"

"$BIN/bridge" --hub "http://127.0.0.1:$HUB_PORT" --bridge-token-file "$WORK/a.token" \
  --port "$A_PORT" --local-endpoint-port "$A_LOCAL" --local-run-dir "$WORK/run-a" \
  > "$WORK/logs/bridge-a.log" 2>&1 & PIDS+=($!)
"$BIN/bridge" --hub "http://127.0.0.1:$HUB_PORT" --bridge-token-file "$WORK/b.token" \
  --port "$B_PORT" --local-endpoint-port "$B_LOCAL" --local-run-dir "$WORK/run-b" \
  > "$WORK/logs/bridge-b.log" 2>&1 & PIDS+=($!)

echo "[xm4] waiting for both bridges to report 'bridge hub runtime ready'"
for _ in $(seq 1 60); do
  if grep -q "runtime ready" "$WORK/logs/bridge-a.log" 2>/dev/null \
  && grep -q "runtime ready" "$WORK/logs/bridge-b.log" 2>/dev/null; then break; fi
  sleep 0.5
done
grep -q "runtime ready" "$WORK/logs/bridge-a.log" || { echo "[xm4] FAIL: bridge A never connected"; exit 1; }
grep -q "runtime ready" "$WORK/logs/bridge-b.log" || { echo "[xm4] FAIL: bridge B never connected"; exit 1; }

B_ID="$(api GET /api/v1/bridges | python3 -c '
import json,sys
# Bridge B is the second enrolled; match it by name.
for b in json.load(sys.stdin)["data"]:
    if (b.get("name") or "").endswith("echo-B"): print(b["bridge_id"]); break
')"
if [ -z "$B_ID" ]; then
  # Older hubs may not echo the name back; fall back to the most recently enrolled.
  B_ID="$(api GET /api/v1/bridges | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][-1]["bridge_id"])')"
fi
echo "[xm4] bridge B = $B_ID"

echo "[xm4] starting the ECHO SERVER as a kind=server session on bridge B (port $ECHO_PORT)"
SESSION_ID="$(api POST "/api/v1/bridges/$B_ID/shells" \
  "{\"kind\":\"server\",\"cmd\":\"python3 $ROOT/tests/xm4_echo_server.py $ECHO_PORT\",\"cwd\":\"$WORK\",\"label\":\"xm4-echo\",\"server_port\":$ECHO_PORT}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["session"]["session_id"])')"
echo "[xm4] echo session = $SESSION_ID"

for _ in $(seq 1 40); do curl -sf -o /dev/null "http://127.0.0.1:$ECHO_PORT/ping" && break || sleep 0.25; done
curl -sf -o /dev/null "http://127.0.0.1:$ECHO_PORT/ping" || { echo "[xm4] FAIL: echo server never came up"; exit 1; }

echo
echo "[xm4] ===== running the echo CLIENT through bridge A's local proxy ====="
echo "[xm4] the client contacts ONLY 127.0.0.1:$A_LOCAL — never the hub, bridge B, or the echo server"
echo
python3 "$ROOT/tests/xm4_echo_client.py" \
  --endpoint "127.0.0.1:$A_LOCAL" --session-id "$SESSION_ID" --rounds "$ROUNDS"
RC=$?

echo
if [ $RC -eq 0 ]; then echo "[xm4] PASS — client and echo server conversed across the full chain"; else echo "[xm4] FAIL"; fi
exit $RC
