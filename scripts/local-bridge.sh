#!/usr/bin/env bash
# local-bridge.sh — run an isolated, named local bridge against an explicit hub.
#
# Usage: scripts/local-bridge.sh <start|enroll|stop|status|help> [options]
#
#   --name NAME                 instance name (default: default). State lives in
#                               $HEIMDALL_LOCAL_STATE_ROOT/bridges/NAME
#   --hub-url URL               hub API URL, e.g. http://127.0.0.1:18081
#   --hub NAME                  take --hub-url (and the seed approver) from a local-hub.sh instance
#   --port N                    bridge port                 (default 49427)
#   --local-endpoint-port N     agent-facing endpoint port  (default 49428)
#   --auto-enroll               if not enrolled yet, enroll first and approve it
#                               headlessly with the seed approver of the --hub
#                               instance (local-hub.sh seeds it), then start. Without
#                               a seed approver the approval waits for the hub UI.
#   --user NAME                 with --auto-enroll, approve as that seeded account of
#                               the --hub (e.g. paid), so the bridge is that user's
#                               (default: the hub's dev proxy user)
#   --build MODE                nix | odin | none (default nix)
#   --bin-dir DIR               take ham-bridge/ham-ctl/ham-pty-host from DIR
#   --pty-host-bin PATH         ham-pty-host to run agents with (default: built, else PATH)
#
# `enroll` runs the device flow (`ham-bridge enroll --headless`) in the foreground. It
# prints the hub's approval link and a pairing code; a trusted device of the hub's
# user (the browser on that hub's UI) opens the link, types the code once and
# approves, which also delivers the vault keyring to this bridge. The hub cannot
# approve a bridge by itself (hub-blind pairing). `enroll --auto-enroll` and
# `start --auto-enroll` let the seed approver do that instead. `start` without a
# credential starts nothing unless --auto-enroll is given.
#
# Providers (claude, codex, ...) are the real installed CLIs: the bridge discovers
# them with its normal probe when the hub asks, and agents inherit your real HOME so
# provider logins keep working. Installed bridge credentials are never copied or
# read; this bridge gets its own credential under its instance directory.
set -euo pipefail
LR_TAG=local-bridge
# shellcheck source=local-runtime/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/local-runtime/lib.sh"

usage() { sed -n '2,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

CMD="${1:-help}"; [ $# -gt 0 ] && shift
NAME=default HUB_URL="" HUB_NAME="" PORT="" EP_PORT="" AUTO=0 APPROVE_URL="" APPROVER_KEY="" APPROVE_USER=""
BUILD="${HEIMDALL_LOCAL_BUILD:-nix}" BIN_DIR="" PTY_BIN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --hub-url) HUB_URL="$2"; shift 2 ;;
    --hub) HUB_NAME="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --local-endpoint-port) EP_PORT="$2"; shift 2 ;;
    --auto-enroll) AUTO=1; shift ;;
    --user) APPROVE_USER="$2"; shift 2 ;;
    --build) BUILD="$2"; shift 2 ;;
    --bin-dir) BIN_DIR="$2"; BUILD=none; shift 2 ;;
    --pty-host-bin) PTY_BIN="$2"; shift 2 ;;
    -h|--help) CMD=help; shift ;;
    *) lr_die "unknown option $1 (see: $0 help)" ;;
  esac
done
lr_valid_name "$NAME" || lr_die "invalid --name '$NAME' (lowercase letters, digits, dashes)"
[ -z "$APPROVE_USER" ] || lr_valid_name "$APPROVE_USER" || lr_die "invalid --user '$APPROVE_USER'"
DIR="$(lr_instance_dir bridge "$NAME")"
ENV_FILE="$DIR/instance.env"
CFG="$DIR/config.toml"
TOKEN="$DIR/credentials/bridge-token"   # the refresh token is $TOKEN.refresh

resolve() {
  HUB_NAME="${HUB_NAME:-$(lr_env_get "$ENV_FILE" HUB_NAME)}"
  if [ -n "$HUB_NAME" ]; then
    local henv; henv="$(lr_instance_dir hub "$HUB_NAME")/instance.env"
    [ -f "$henv" ] || lr_die "no local hub instance '$HUB_NAME'"
    HUB_URL="${HUB_URL:-$(lr_env_get "$henv" HUB_URL)}"
    APPROVE_URL="$(lr_env_get "$henv" PROXY_URL)"
    APPROVER_KEY="$(lr_env_get "$henv" APPROVER_KEY)"
    # local-hub.sh keeps a seeded account's approver under approver/users/<user>/.
    [ -z "$APPROVE_USER" ] || APPROVER_KEY="$(dirname "$APPROVER_KEY")/users/$APPROVE_USER/device.json"
  fi
  local rec
  rec="$(lr_env_get "$ENV_FILE" HUB_URL)"
  if [ -n "$rec" ] && [ -n "$HUB_URL" ] && [ "$rec" != "$HUB_URL" ]; then
    lr_die "bridge '$NAME' is enrolled with $rec; use a new --name for another hub"
  fi
  HUB_URL="${HUB_URL:-$rec}"
  [ -n "$HUB_URL" ] || lr_die "--hub-url or --hub is required"
  [[ "$HUB_URL" =~ ^https?://[^/]+$ ]] || lr_die "--hub-url must be scheme://host:port with no path"
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
  lr_env_write "$ENV_FILE" "KIND=bridge" "NAME=$NAME" "HUB_URL=$HUB_URL" "HUB_NAME=$HUB_NAME" \
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

# seed_approve <code>: headless approval by the hub instance's seed approver
# (scripts/local-runtime/approver.mjs: the UI's vault modules, real API calls).
seed_approve() {
  lr_log "approving pairing code with the seed approver of hub '$HUB_NAME'${APPROVE_USER:+ as $APPROVE_USER}"
  (cd "$LR_ROOT" && node --import ./tests/helpers/vaultEndpointHarness.ts "$LR_HELPERS/approver.mjs" bridge \
    --api "$APPROVE_URL" --key "$APPROVER_KEY" --code "$1" --label "local-$NAME" ${APPROVE_USER:+--user "$APPROVE_USER"}) 2>&1 | sed 's/^/  /'
  return "${PIPESTATUS[0]}"
}

# enroll_flow <auto 0|1>: the supported device flow (ham-bridge enroll --headless).
enroll_flow() {
  local auto="$1" log="$DIR/logs/enroll.log"
  if [ "$auto" = 1 ] && { [ -z "$HUB_NAME" ] || [ ! -s "$APPROVER_KEY" ]; }; then
    lr_log "no seed approver (needs --hub NAME of a seeded local-hub.sh instance); approve in the hub UI"
    auto=0
  fi
  rm -f "$log"
  # `ham-bridge enroll` finishes by restarting the INSTALLED bridge service
  # (systemctl --user restart heimdall-bridge / sv / launchctl). A local instance
  # must never touch it, so those three names resolve to no-ops for this one
  # process only; this launcher starts the bridge itself afterwards.
  local shim
  for shim in systemctl sv launchctl; do
    # enroll captures the command's stdout, so the record goes to a log file.
    printf '#!/bin/sh\necho "local-bridge: skipped installed-service call: %s $*" >> "%s"\nexit 0\n' \
      "$shim" "$DIR/logs/enroll-shims.log" > "$DIR/enroll-bin/$shim"
    chmod 0755 "$DIR/enroll-bin/$shim"
  done
  lr_log "device-flow enrollment against $HUB_URL"
  # Own session, so giving up reaches every process a wrapper started.
  setsid env -u PREFIX PATH="$DIR/enroll-bin:$PATH" "$BRIDGE_BIN" enroll --hub "$HUB_URL" --headless \
    --config "$CFG" --bridge-token-file "$TOKEN" > "$log" 2>&1 &
  local pid=$! prompt="" i
  for i in $(seq 1 60); do
    prompt="$(lr_enroll_prompt "$log")"
    [ -n "$prompt" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  if [ -z "$prompt" ]; then
    kill -- "-$pid" 2>/dev/null || true
    sed 's/^/  /' "$log" >&2; lr_die "ham-bridge enroll printed no approval link and pairing code"
  fi
  local url="${prompt% *}" code="${prompt#* }"
  if [ "$auto" = 1 ]; then
    seed_approve "$code" || { kill -- "-$pid" 2>/dev/null || true; sed 's/^/  /' "$log" >&2; lr_die "headless approval failed"; }
  else
    # Hub-blind pairing: the hub cannot approve a bridge by itself. A trusted vault
    # device of the hub's user (the browser on this hub's UI) types the code once,
    # signs the approval and hands the bridge its keyring; this process waits.
    lr_log "approve this bridge in the hub UI: open $url"
    lr_log "and type the pairing code once: $code"
    lr_log "(a seeded local hub first asks that browser to pair: local-hub.sh approve-device --code ...)"
    lr_log "waiting for approval (ham-bridge enroll gives up when the code expires)..."
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
    enroll_flow "$AUTO"
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
