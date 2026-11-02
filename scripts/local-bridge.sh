#!/usr/bin/env bash
# local-bridge.sh — run an isolated, named local bridge against an explicit hub.
#
# Usage: scripts/local-bridge.sh <start|enroll|reseed-auth|stop|status|help> [options]
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
#   --approval-base-url URL     browser UI base, including a preview path prefix;
#                               only changes the approval link, not the hub API
#   --user NAME                 with --auto-enroll, approve as that seeded account of
#                               the --hub (e.g. paid), so the bridge is that user's
#                               (default: the hub's dev proxy user)
#   --build MODE                nix | odin | none (default nix)
#   --bin-dir DIR               take ham-bridge/ham-ctl/ham-pty-host from DIR
#   --pty-host-bin PATH         ham-pty-host to run agents with (default: built, else PATH)
#   --shared-home               run providers with your real HOME (see "Provider home")
#   --isolated-home             the default for a new instance on Linux (macOS: opt
#                               in, not yet verified there); refused for an instance
#                               recorded as shared, like --shared-home the other way
#   --purge-home                with stop: purge this isolated instance's vault,
#                               profiles/secrets and provider home
#   --providers LIST            providers whose auth is seeded into an isolated home
#                               (default: claude,codex,gemini,pi,git)
#
# `enroll` runs the device flow (`ham-bridge enroll --headless`) in the foreground. It
# prints the hub's approval link and a pairing code; a trusted device of the hub's
# user (the browser on that hub's UI) opens the link, types the code once and
# approves, which also delivers the vault keyring to this bridge. The hub cannot
# approve a bridge by itself (hub-blind pairing). `enroll --auto-enroll` and
# `start --auto-enroll` let the seed approver do that instead. `start` without a
# credential starts nothing unless --auto-enroll is given.
#
# Provider home. Providers (claude, codex, ...) are the real installed CLIs, found
# on your PATH. By default (Linux; on macOS only with --isolated-home, since the
# Keychain-backed sign-ins have not been verified with a moved HOME) a new instance
# runs the bridge and everything it starts
# with HOME=<instance>/home (XDG dirs inside it; CLAUDE_CONFIG_DIR, CODEX_HOME,
# GEMINI_CONFIG_DIR and HEIMDALL_HOME unset), so an extension installed from this
# bridge's hub lands there, never in your ~/.claude or ~/.codex. On first use your
# provider sign-in, onboarding/consent state and project trust are COPIED in
# (scripts/local-runtime/provider-home.mjs; listed with checksums in
# home/.heimdall-home-manifest.json); plugins, hooks, MCP servers, status-line and
# notify commands, and history are not. Your real
# home is only read. A copied OAuth session can expire or be rotated by either
# side: sign in again normally and run `reseed-auth`. API keys and
# CLAUDE_CODE_OAUTH_TOKEN in your environment pass through unchanged. The directory
# picker stays on your real HOME. --shared-home keeps the old behaviour (agents use
# your real HOME). The mode is fixed when an instance is created: an instance made
# before isolation existed stays shared. Installed bridge credentials are never
# copied or read; this bridge gets its own credential under its instance directory.
set -euo pipefail
LR_TAG=local-bridge
# shellcheck source=local-runtime/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/local-runtime/lib.sh"

usage() { sed -n '2,56p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

CMD="${1:-help}"; [ $# -gt 0 ] && shift
NAME=default HUB_URL="" HUB_NAME="" PORT="" EP_PORT="" AUTO=0 APPROVE_URL="" APPROVER_KEY="" APPROVE_USER="" APPROVAL_BASE_URL=""
BUILD="${HEIMDALL_LOCAL_BUILD:-nix}" BIN_DIR="" PTY_BIN="" HOME_MODE="" PROVIDERS="" PURGE_HOME=0
# Captured before anything can change HOME: the developer's real home, which seeds
# an isolated provider home and stays the directory picker's root.
REAL_HOME="$HOME"
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --hub-url) HUB_URL="$2"; shift 2 ;;
    --hub) HUB_NAME="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --local-endpoint-port) EP_PORT="$2"; shift 2 ;;
    --approval-base-url) APPROVAL_BASE_URL="$2"; shift 2 ;;
    --auto-enroll) AUTO=1; shift ;;
    --user) APPROVE_USER="$2"; shift 2 ;;
    --build) BUILD="$2"; shift 2 ;;
    --bin-dir) BIN_DIR="$2"; BUILD=none; shift 2 ;;
    --pty-host-bin) PTY_BIN="$2"; shift 2 ;;
    --shared-home) HOME_MODE=0; shift ;;
    --isolated-home) HOME_MODE=1; shift ;;
    --providers) PROVIDERS="$2"; shift 2 ;;
    --purge-home) PURGE_HOME=1; shift ;;
    -h|--help) CMD=help; shift ;;
    *) lr_die "unknown option $1 (see: $0 help)" ;;
  esac
done
[ "$PURGE_HOME" = 0 ] || [ "$CMD" = stop ] || lr_die "--purge-home is only valid with stop"
lr_valid_name "$NAME" || lr_die "invalid --name '$NAME' (lowercase letters, digits, dashes)"
[ -z "$APPROVE_USER" ] || lr_valid_name "$APPROVE_USER" || lr_die "invalid --user '$APPROVE_USER'"
DIR="$(lr_instance_dir bridge "$NAME")"
ENV_FILE="$DIR/instance.env"
CFG="$DIR/config.toml"
TOKEN="$DIR/credentials/bridge-token"   # the refresh token is $TOKEN.refresh
PHOME="$DIR/home"

resolve() {
  HUB_NAME="${HUB_NAME:-$(lr_env_get "$ENV_FILE" HUB_NAME)}"
  if [ -n "$HUB_NAME" ]; then
    local henv; henv="$(lr_instance_dir hub "$HUB_NAME")/instance.env"
    [ -f "$henv" ] || lr_die "no local hub instance '$HUB_NAME'"
    HUB_URL="${HUB_URL:-$(lr_env_get "$henv" HUB_URL)}"
    APPROVE_URL="$(lr_env_get "$henv" PROXY_URL)"
    # The seed approver signs in like a browser and must send the hub's CSRF origin.
    export HEIMDALL_LOCAL_UI_ORIGIN="$(lr_env_get "$henv" UI_ORIGIN)"
    APPROVER_KEY="$(lr_env_get "$henv" APPROVER_KEY)"
    # local-hub.sh keeps a seeded account's approver under approver/users/<user>/.
    [ -z "$APPROVE_USER" ] || APPROVER_KEY="$(dirname "$APPROVER_KEY")/users/$APPROVE_USER/device.json"
  fi
  APPROVAL_BASE_URL="${APPROVAL_BASE_URL:-$(lr_env_get "$ENV_FILE" APPROVAL_BASE_URL)}"
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
  # The home mode is fixed at creation: the bridge's identity file lives under the
  # HOME it ran with, so switching would orphan the enrollment. An instance created
  # before ISOLATED_HOME was recorded used the real HOME.
  rec="$(lr_env_get "$ENV_FILE" ISOLATED_HOME)"
  [ -z "$rec" ] && [ -f "$ENV_FILE" ] && rec=0
  if [ -n "$rec" ] && [ -n "$HOME_MODE" ] && [ "$HOME_MODE" != "$rec" ]; then
    lr_die "bridge '$NAME' uses $([ "$rec" = 1 ] && echo "an isolated provider home" || echo "your real HOME (shared)"); use a new --name to change it"
  fi
  # macOS keeps sign-ins (the vault keyring, Claude OAuth) in the login Keychain;
  # isolation stays opt-in there until it is verified with a moved HOME.
  local default_mode=1
  [ "$(uname -s)" = Darwin ] && default_mode=0
  ISOLATED="${rec:-${HOME_MODE:-$default_mode}}"
  if [ -z "$rec" ] && [ "$ISOLATED" = 1 ] && [ "$(uname -s)" = Darwin ]; then
    lr_log "WARN: --isolated-home on macOS is not verified yet (Keychain sign-ins); use --shared-home if providers or enroll misbehave"
  fi
  PROVIDERS="${PROVIDERS:-$(lr_env_get "$ENV_FILE" PROVIDERS)}"
  PROVIDERS="${PROVIDERS:-claude,codex,gemini,pi,git}"
  ISO_ENV=()
  if [ "$ISOLATED" = 1 ]; then
    ISO_ENV=(-u CLAUDE_CONFIG_DIR -u CODEX_HOME -u GEMINI_CONFIG_DIR -u HEIMDALL_HOME
      "HOME=$PHOME" "XDG_CONFIG_HOME=$PHOME/.config" "XDG_DATA_HOME=$PHOME/.local/share"
      "XDG_STATE_HOME=$PHOME/.local/state" "XDG_CACHE_HOME=$PHOME/.cache")
  fi
}

# seed_home: copy provider auth, consent and trust from the real home into the
# isolated one (never the other way). Agents run under endpoint/ and agent-runs/.
seed_home() {
  node "$LR_HELPERS/provider-home.mjs" seed --real-home "$REAL_HOME" --home "$PHOME" --providers "$PROVIDERS" \
    --trust-root "$DIR/endpoint" --trust-root "$DIR/agent-runs" | sed "s/^/[$LR_TAG] /"
  return "${PIPESTATUS[0]}"
}

prepare() {
  mkdir -p "$DIR"/{bin,logs,run,data,credentials,agent-runs,endpoint,enroll-bin}
  chmod 700 "$DIR/credentials"
  if [ "$ISOLATED" = 1 ]; then
    node "$LR_HELPERS/profile-state.mjs" sync --instance "$DIR" --checkout "$LR_ROOT" || lr_die "extension sync failed"
  fi
  lr_env_write "$ENV_FILE" "KIND=bridge" "NAME=$NAME" "HUB_URL=$HUB_URL" "HUB_NAME=$HUB_NAME" \
    "BRIDGE_PORT=$PORT" "APPROVAL_BASE_URL=$APPROVAL_BASE_URL" "LOCAL_ENDPOINT_PORT=$EP_PORT" "CONFIG=$CFG" "TOKEN_FILE=$TOKEN" "CHECKOUT=$LR_ROOT" \
    "BIN_DIR=${BIN_DIR:-$DIR/bin}" "ISOLATED_HOME=$ISOLATED" "PROVIDERS=$PROVIDERS" "HOME_DIR=$([ "$ISOLATED" = 1 ] && echo "$PHOME" || echo "$REAL_HOME")"
  local fs_args=()
  [ "$ISOLATED" = 1 ] && fs_args=(--fs-root "$REAL_HOME")
  node "$LR_HELPERS/bridge-config.mjs" --template "$LR_ROOT/config.toml" --out "$CFG" \
    --dir "$DIR" --hub-url "$HUB_URL" --port "$PORT" --name "$NAME" ${fs_args[@]+"${fs_args[@]}"}
  if [ "$ISOLATED" = 1 ] && [ ! -f "$PHOME/.heimdall-home-manifest.json" ]; then
    lr_log "seeding isolated provider home $PHOME from $REAL_HOME"
    seed_home || lr_die "seeding the provider home failed"
  fi
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
  local approval_args=()
  [ -z "$APPROVAL_BASE_URL" ] || approval_args=(--approval-base-url "$APPROVAL_BASE_URL")
  # Same HOME as the running bridge, so the identity it writes is the one start finds.
  setsid env -u PREFIX ${ISO_ENV[@]+"${ISO_ENV[@]}"} PATH="$DIR/enroll-bin:$PATH" "$BRIDGE_BIN" enroll --hub "$HUB_URL" --headless "${approval_args[@]}" \
    --config "$CFG" --bridge-token-file "$TOKEN" > "$log" 2>&1 &
  local pid=$! prompt="" i
  for i in $(seq 1 60); do
    prompt="$(lr_enroll_prompt "$log")"
    [ -n "$prompt" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  # Enrollment may exit between the final prompt read and the liveness check.
  [ -n "$prompt" ] || prompt="$(lr_enroll_prompt "$log")"
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
  lr_spawn "$DIR" bridge "$DIR/logs/bridge.log" env ${ISO_ENV[@]+"${ISO_ENV[@]}"} \
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

reseed_auth() {
  [ -f "$ENV_FILE" ] || lr_die "no bridge instance '$NAME'"
  lr_lock "$DIR"
  resolve
  [ "$ISOLATED" = 1 ] || lr_die "bridge '$NAME' uses your real HOME (--shared-home); nothing to reseed"
  seed_home || lr_die "reseeding the provider home failed"
  lr_log "provider home reseeded; running agents pick it up on their next start"
}

stop() {
  [ -d "$DIR" ] || { lr_log "no instance '$NAME'"; return 0; }
  lr_lock "$DIR"
  if [ "$PURGE_HOME" = 1 ] && [ "$(lr_env_get "$ENV_FILE" ISOLATED_HOME)" != 1 ]; then
    lr_die "--purge-home requires a recorded isolated-home instance"
  fi
  lr_stop_svc "$DIR" bridge
  if [ "$PURGE_HOME" = 1 ]; then
    resolve
    local id bridge_bin stored_bin
    id="$(sed -n 's/^daemon_id = "\(brg_[0-9a-f]*\)"$/\1/p' "$CFG" | head -1)"
    if [ -n "$id" ]; then
      stored_bin="$(lr_env_get "$ENV_FILE" BIN_DIR)"
      bridge_bin="$(lr_bin "${BIN_DIR:-${stored_bin:-$DIR/bin}}" ham-bridge)"
      env ${ISO_ENV[@]+"${ISO_ENV[@]}"} "$bridge_bin" vault prune --remove-scope "$id" --hub "$HUB_URL" \
        || lr_die "vault purge failed; provider home kept"
    fi
    node "$LR_HELPERS/profile-state.mjs" purge --instance "$DIR" || lr_die "profile purge failed; provider home kept"
    rm -rf "$PHOME"
    # The home held this enrollment's identity. Require enrollment again.
    rm -rf "$DIR/credentials"
    lr_log "isolated vault, profiles, secrets and provider home purged"
  fi
  lr_log "bridge '$NAME' stopped (state kept in $DIR)"
}

status() {
  [ -f "$ENV_FILE" ] || { lr_log "no instance '$NAME' under $(lr_state_root)/bridges"; return 1; }
  echo "bridge instance '$NAME' ($DIR)"
  lr_svc_status "$DIR" bridge
  echo "  hub      : $(lr_env_get "$ENV_FILE" HUB_URL)"
  echo "  ports    : bridge $(lr_env_get "$ENV_FILE" BRIDGE_PORT), endpoint $(lr_env_get "$ENV_FILE" LOCAL_ENDPOINT_PORT)"
  if enrolled; then echo "  enrolled : yes"; else echo "  enrolled : no"; fi
  if [ "$(lr_env_get "$ENV_FILE" ISOLATED_HOME)" = 1 ]; then
    echo "  home     : $PHOME (isolated; seeded: $(node -e 'try{const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(m.providers.join(",")||"none")}catch{console.log("not yet")}' "$PHOME/.heimdall-home-manifest.json"))"
  else
    echo "  home     : real HOME (shared)"
  fi
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
  reseed-auth) reseed_auth ;;
  stop) stop ;;
  status) status ;;
  help) usage ;;
  *) usage; exit 2 ;;
esac
