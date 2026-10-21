#!/usr/bin/env bash
# local-bridge.sh — run an isolated, named local bridge against an explicit hub.
#
# Usage: scripts/local-bridge.sh <start|enroll|stop|status|help> [options]
#
#   --name NAME                 instance name (default: default). State lives in
#                               $HEIMDALL_LOCAL_STATE_ROOT/bridges/NAME
#   --hub-url URL               hub API URL, e.g. http://127.0.0.1:18081
#   --hub NAME                  take --hub-url (and --approve-url) from a local-hub.sh instance
#   --port N                    bridge port                 (default 49427)
#   --local-endpoint-port N     agent-facing endpoint port  (default 49428)
#   --auto-enroll               if not enrolled yet, run the device flow and approve
#                               it through --approve-url (the hub's dev proxy, which
#                               signs the request in as the local user)
#   --approve-url URL           dev-proxy URL that approves the device code
#   --build MODE                nix | odin | none (default nix)
#   --bin-dir DIR               take ham-bridge/ham-ctl/ham-pty-host from DIR
#   --pty-host-bin PATH         ham-pty-host to run agents with (default: built, else PATH)
#
# `enroll` runs the device flow in the foreground: it prints the code, and a human
# approves it in the hub UI (or it is approved automatically with --approve-url).
# `start` without a credential starts nothing unless --auto-enroll is given.
#
# Providers (claude, codex, ...) are the real installed CLIs: the bridge discovers
# them with its normal probe when the hub asks, and agents inherit your real HOME so
# provider logins keep working. Installed bridge credentials are never copied or
# read; this bridge gets its own credential under its instance directory.
set -euo pipefail
LR_TAG=local-bridge
# shellcheck source=local-runtime/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/local-runtime/lib.sh"

usage() { sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

CMD="${1:-help}"; [ $# -gt 0 ] && shift
NAME=default HUB_URL="" HUB_NAME="" PORT="" EP_PORT="" AUTO=0 APPROVE_URL=""
BUILD="${HEIMDALL_LOCAL_BUILD:-nix}" BIN_DIR="" PTY_BIN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --hub-url) HUB_URL="$2"; shift 2 ;;
    --hub) HUB_NAME="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --local-endpoint-port) EP_PORT="$2"; shift 2 ;;
    --auto-enroll) AUTO=1; shift ;;
    --approve-url) APPROVE_URL="$2"; shift 2 ;;
    --build) BUILD="$2"; shift 2 ;;
    --bin-dir) BIN_DIR="$2"; BUILD=none; shift 2 ;;
    --pty-host-bin) PTY_BIN="$2"; shift 2 ;;
    -h|--help) CMD=help; shift ;;
    *) lr_die "unknown option $1 (see: $0 help)" ;;
  esac
done
lr_valid_name "$NAME" || lr_die "invalid --name '$NAME' (lowercase letters, digits, dashes)"
DIR="$(lr_instance_dir bridge "$NAME")"
ENV_FILE="$DIR/instance.env"
CFG="$DIR/config.toml"
TOKEN="$DIR/credentials/bridge-token"   # the refresh token is $TOKEN.refresh

resolve() {
  if [ -n "$HUB_NAME" ]; then
    local henv; henv="$(lr_instance_dir hub "$HUB_NAME")/instance.env"
    [ -f "$henv" ] || lr_die "no local hub instance '$HUB_NAME'"
    HUB_URL="${HUB_URL:-$(lr_env_get "$henv" HUB_URL)}"
    APPROVE_URL="${APPROVE_URL:-$(lr_env_get "$henv" PROXY_URL)}"
  fi
  local rec
  rec="$(lr_env_get "$ENV_FILE" HUB_URL)"
  if [ -n "$rec" ] && [ -n "$HUB_URL" ] && [ "$rec" != "$HUB_URL" ]; then
    lr_die "bridge '$NAME' is enrolled with $rec; use a new --name for another hub"
  fi
  HUB_URL="${HUB_URL:-$rec}"
  [ -n "$HUB_URL" ] || lr_die "--hub-url or --hub is required"
  [[ "$HUB_URL" =~ ^https?://[^/]+$ ]] || lr_die "--hub-url must be scheme://host:port with no path"
  APPROVE_URL="${APPROVE_URL:-$(lr_env_get "$ENV_FILE" APPROVE_URL)}"
  rec="$(lr_env_get "$ENV_FILE" BRIDGE_PORT)"
  [ -n "$rec" ] && [ -n "$PORT" ] && [ "$PORT" != "$rec" ] && lr_die "bridge '$NAME' is recorded with port $rec"
  PORT="${PORT:-${rec:-49427}}"
  rec="$(lr_env_get "$ENV_FILE" LOCAL_ENDPOINT_PORT)"
  [ -n "$rec" ] && [ -n "$EP_PORT" ] && [ "$EP_PORT" != "$rec" ] && lr_die "bridge '$NAME' is recorded with endpoint port $rec"
  EP_PORT="${EP_PORT:-${rec:-49428}}"
}

prepare() {
  mkdir -p "$DIR"/{bin,logs,run,data,credentials,agent-runs,endpoint,enroll-bin}
  chmod 700 "$DIR/credentials"
  lr_env_write "$ENV_FILE" "KIND=bridge" "NAME=$NAME" "HUB_URL=$HUB_URL" "APPROVE_URL=$APPROVE_URL" \
    "BRIDGE_PORT=$PORT" "LOCAL_ENDPOINT_PORT=$EP_PORT" "CONFIG=$CFG" "TOKEN_FILE=$TOKEN" "CHECKOUT=$LR_ROOT"
  node "$LR_HELPERS/bridge-config.mjs" --template "$LR_ROOT/config.toml" --out "$CFG" \
    --dir "$DIR" --hub-url "$HUB_URL" --port "$PORT" --name "$NAME"
  BIN="${BIN_DIR:-$DIR/bin}"
  if [ -z "$BIN_DIR" ]; then
    local comps=(bridge ctl)
    [ -z "$PTY_BIN" ] && [ "$BUILD" = nix ] && comps+=(pty-host)
    HEIMDALL_LOCAL_BUILD="$BUILD" lr_build "$BIN" "${comps[@]}"
  fi
  BRIDGE_BIN="$(lr_bin "$BIN" ham-bridge)"; CTL_BIN="$(lr_bin "$BIN" ham-ctl)"
  if [ -z "$PTY_BIN" ]; then
    if [ -x "$BIN/ham-pty-host" ]; then PTY_BIN="$BIN/ham-pty-host"
    else PTY_BIN="$(command -v ham-pty-host || true)"; fi
  fi
  [ -n "$PTY_BIN" ] && [ -x "$PTY_BIN" ] || lr_die "no ham-pty-host found; pass --pty-host-bin"
}

enrolled() { [ -s "$TOKEN" ] && [ -s "$TOKEN.refresh" ]; }

# enroll_flow <auto 0|1>: the supported device flow (ham-bridge enroll --headless).
enroll_flow() {
  local auto="$1" log="$DIR/logs/enroll.log"
  rm -f "$log"
  # `ham-bridge enroll` finishes by restarting the INSTALLED bridge service
  # (systemctl --user restart heimdall-bridge / sv / launchctl). A local instance
  # must never touch it, so those three names resolve to no-ops for this one
  # process only; this launcher starts the bridge itself afterwards.
  local shim
  for shim in systemctl sv launchctl; do
    printf '#!/bin/sh\necho "local-bridge: skipped installed-service call: %s $*"\nexit 0\n' "$shim" > "$DIR/enroll-bin/$shim"
    chmod 0755 "$DIR/enroll-bin/$shim"
  done
  lr_log "device-flow enrollment against $HUB_URL"
  env -u PREFIX PATH="$DIR/enroll-bin:$PATH" "$BRIDGE_BIN" enroll --hub "$HUB_URL" --headless \
    --config "$CFG" --bridge-token-file "$TOKEN" > "$log" 2>&1 &
  local pid=$! code="" i
  for i in $(seq 1 60); do
    code="$(grep -aiE 'enter (the|device) code' "$log" 2>/dev/null | tail -1 | awk '{print $NF}' || true)"
    [ -n "$code" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  if [ -z "$code" ]; then
    kill "$pid" 2>/dev/null || true
    sed 's/^/  /' "$log" >&2; lr_die "enrollment printed no device code"
  fi
  if [ "$auto" = 1 ]; then
    [ -n "$APPROVE_URL" ] || { kill "$pid" 2>/dev/null || true; lr_die "--auto-enroll needs --approve-url or --hub NAME"; }
    lr_log "approving device code $code via $APPROVE_URL"
    local resp
    resp="$(curl -s -m 10 -X POST "$APPROVE_URL/api/v1/device/approve" -H 'Content-Type: application/json' \
      -d "{\"user_code\":\"$code\",\"approve\":true}")" || resp='{"error":"approve request failed"}'
    case "$resp" in *'"error"'*) kill "$pid" 2>/dev/null || true; lr_die "approval failed: $resp" ;; esac
  else
    lr_log "approve device code $code in the hub UI (Bridges -> enroll); waiting..."
  fi
  if ! wait "$pid"; then sed 's/^/  /' "$log" >&2; lr_die "enrollment failed"; fi
  enrolled || { sed 's/^/  /' "$log" >&2; lr_die "enrollment wrote no access/refresh token pair"; }
  lr_log "enrolled; credential in $DIR/credentials (the bridge rotates it)"
}

start() {
  lr_lock "$DIR"
  resolve
  lr_owned_pid "$DIR" bridge >/dev/null && lr_die "bridge '$NAME' is already running"
  lr_check_ports "$DIR" "$PORT" "$EP_PORT"
  prepare
  if ! enrolled; then
    [ "$AUTO" = 1 ] || lr_die "bridge '$NAME' is not enrolled; run '$0 enroll --name $NAME' or pass --auto-enroll"
    enroll_flow 1
  fi
  lr_log "starting bridge on 127.0.0.1:$PORT -> $HUB_URL"
  lr_spawn "$DIR" bridge "$DIR/logs/bridge.log" env \
    "HEIMDALL_HAM_CTL_BIN=$CTL_BIN" "HEIMDALL_BRIDGE_PTY_HOST=1" "HEIMDALL_HAM_PTY_HOST_BIN=$PTY_BIN" \
    "$BRIDGE_BIN" --config "$CFG" --bind-host 127.0.0.1 --port "$PORT" --hub "$HUB_URL" \
    --bridge-token-file "$TOKEN" --local-endpoint-port "$EP_PORT" --local-run-dir "$DIR/endpoint"
  local i
  for i in $(seq 1 60); do
    grep -q 'bridge hub runtime ready' "$DIR/logs/bridge.log" 2>/dev/null && break
    lr_owned_pid "$DIR" bridge >/dev/null || { tail -20 "$DIR/logs/bridge.log" >&2; lr_die "bridge exited"; }
    sleep 0.5
  done
  grep -q 'bridge hub runtime ready' "$DIR/logs/bridge.log" \
    || lr_log "WARN: no 'hub runtime ready' yet; check $DIR/logs/bridge.log"
  status
}

enroll() {
  lr_lock "$DIR"
  resolve
  lr_owned_pid "$DIR" bridge >/dev/null && lr_die "stop bridge '$NAME' before re-enrolling"
  prepare
  enroll_flow "$AUTO"
}

stop() {
  [ -d "$DIR" ] || { lr_log "no instance '$NAME'"; return 0; }
  lr_lock "$DIR"
  lr_stop_svc "$DIR" bridge
  lr_log "bridge '$NAME' stopped (state kept in $DIR)"
}

status() {
  [ -f "$ENV_FILE" ] || { lr_log "no instance '$NAME' under $(lr_state_root)/bridges"; return 1; }
  echo "bridge instance '$NAME' ($DIR)"
  lr_svc_status "$DIR" bridge
  echo "  hub      : $(lr_env_get "$ENV_FILE" HUB_URL)"
  echo "  ports    : bridge $(lr_env_get "$ENV_FILE" BRIDGE_PORT), endpoint $(lr_env_get "$ENV_FILE" LOCAL_ENDPOINT_PORT)"
  if enrolled; then echo "  enrolled : yes"; else echo "  enrolled : no"; fi
  local paths="$DIR/data/bridge/provider_paths.json"
  if [ -f "$paths" ]; then
    echo "  providers: $(node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).providers||[];console.log(p.map(x=>`${x.provider}=${x.state}`).join(" ")||"(none probed)")' "$paths" 2>/dev/null)"
  else
    echo "  providers: (not probed yet)"
  fi
}

case "$CMD" in
  start) start ;;
  enroll) enroll ;;
  stop) stop ;;
  status) status ;;
  help) usage ;;
  *) usage; exit 2 ;;
esac
