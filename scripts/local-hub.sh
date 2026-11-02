#!/usr/bin/env bash
# local-hub.sh — run an isolated, named local Heimdall hub with its browser UI.
#
# Usage: scripts/local-hub.sh <start|stop|status|approve-device|help> [options]
#
#   --name NAME        instance name (default: default). State lives in
#                      $HEIMDALL_LOCAL_STATE_ROOT/hubs/NAME (default root:
#                      ~/.local/state/heimdall-local)
#   --hub-port N       hub API port            (default 18081)
#   --proxy-port N     ham-dev-proxy port      (default 18080)
#   --ui-port N        browser UI (Vite) port  (default 15173)
#   --oidc-port N      mock OIDC provider port (default 18090; DEV ONLY, see
#                      tools/mock-oidc/README.md)
#   --public-origin URL  origin the browser uses when the UI is reached through a
#                      reverse proxy (e.g. https://hub-dev.example), as
#                      scheme://host[:port] with no path. The dev proxy attaches the
#                      brokered session for it as for the local UI. Not needed for a
#                      Heimdall preview (dev-preview.sh, ui-preview.sh). Recorded and
#                      reused on restart; pass --public-origin local to drop it.
#   --user NAME        dev user the browser signs in as (default: $USER): the dev
#                      proxy passes it to the mock OIDC provider as login_hint
#   --build MODE       nix | odin | none       (default: nix; none = use --bin-dir as is)
#   --bin-dir DIR      take ham-hub/ham-dev-proxy from DIR instead of building
#   --no-ui            do not start the browser UI
#   --no-seed          do not seed sample agents, chains, memories, the approver or
#                      the paid account
#   --no-plan-limits   do not enforce billing plan limits (on by default, so local
#                      runs behave like the free plan for the default user)
#   --code CODE        (approve-device) pairing code the hub UI shows a new browser
#
# Accounts: the dev proxy signs in as --user, which stays on the free plan.
# Seeding also creates the dev proxy user "paid" on the hobbyist plan (set in
# hub.db by local-runtime/plans.mjs), with its own sample data and seed approver.
# Switch accounts in the browser with /_dev/login?user=paid (or the /_dev/ page).
# Users authenticate only with OIDC, here against the bundled mock provider
# (tools/mock-oidc). The dev proxy signs in on the browser's behalf as the selected
# user and keeps the hub session itself (docs/auth-oidc.md, "Local development"),
# so sign-in also works through a Heimdall preview, which strips hub cookies.
#
# Seeding also creates the hub user's vault with a SEED APPROVER device whose key
# stays in approver/device.json (0600) of this instance. It lets
# `local-bridge.sh start --hub NAME --auto-enroll` approve bridges headlessly. The
# browser is therefore not the vault root of a local hub: when the UI asks to pair
# this browser, approve it with `approve-device --code <code>`.
#
# Ports are recorded on first start and reused afterwards; passing a different
# port for an existing instance is refused (stop it and use a new --name instead).
# Start refuses ports that are busy or recorded by another instance. Stop only
# signals processes this instance started (pid + start time recorded under run/).
# Nothing here touches the installed hub/bridge, ~/.local/share/heimdall, or
# systemd units.
set -euo pipefail
LR_TAG=local-hub
# shellcheck source=local-runtime/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/local-runtime/lib.sh"

usage() { sed -n '2,46p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

CMD="${1:-help}"; [ $# -gt 0 ] && shift
NAME=default HUB_PORT="" PROXY_PORT="" UI_PORT="" OIDC_PORT="" PUBLIC_ORIGIN="" DEV_USER="${USER:-local}"
BUILD="${HEIMDALL_LOCAL_BUILD:-nix}" BIN_DIR="" UI=1 SEED=1 PLAN_LIMITS=true CODE=""
# Seeded paid accounts as user:plan; each must be in the dev proxy's default roster.
SEED_PLANS="paid:hobbyist"
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --hub-port) HUB_PORT="$2"; shift 2 ;;
    --proxy-port) PROXY_PORT="$2"; shift 2 ;;
    --ui-port) UI_PORT="$2"; shift 2 ;;
    --oidc-port) OIDC_PORT="$2"; shift 2 ;;
    --public-origin) PUBLIC_ORIGIN="${2%/}"; shift 2 ;;
    --user) DEV_USER="$2"; shift 2 ;;
    --build) BUILD="$2"; shift 2 ;;
    --bin-dir) BIN_DIR="$2"; BUILD=none; shift 2 ;;
    --no-ui) UI=0; shift ;;
    --no-seed) SEED=0; shift ;;
    --no-plan-limits) PLAN_LIMITS=false; shift ;;
    --code) CODE="$2"; shift 2 ;;
    -h|--help) CMD=help; shift ;;
    *) lr_die "unknown option $1 (see: $0 help)" ;;
  esac
done
lr_valid_name "$NAME" || lr_die "invalid --name '$NAME' (lowercase letters, digits, dashes)"
if [ -n "$PUBLIC_ORIGIN" ] && [ "$PUBLIC_ORIGIN" != local ] && ! [[ "$PUBLIC_ORIGIN" =~ ^https?://[^/[:space:]]+$ ]]; then
  lr_die "--public-origin must be scheme://host[:port] with no path (got '$PUBLIC_ORIGIN')"
fi
DIR="$(lr_instance_dir hub "$NAME")"
ENV_FILE="$DIR/instance.env"
APPROVER_KEY="$DIR/approver/device.json"

# node_modules carries Vite for the UI and esbuild for the approver's UI modules.
ensure_node_modules() {
  [ -x "$LR_ROOT/node_modules/.bin/vite" ] && [ -d "$LR_ROOT/node_modules/esbuild" ] && return 0
  lr_log "installing UI dependencies (npm ci --legacy-peer-deps)"
  (cd "$LR_ROOT" && npm ci --legacy-peer-deps --no-audit --no-fund)
}

# approver <verb> [args]: scripts/local-runtime/approver.mjs against this hub's proxy,
# as the default user. Pass --key and --user to act for a seeded account instead.
approver() {
  local verb="$1"; shift
  (cd "$LR_ROOT" && node --import ./tests/helpers/vaultEndpointHarness.ts "$LR_HELPERS/approver.mjs" \
    "$verb" --api "http://127.0.0.1:$PROXY_PORT" --key "$APPROVER_KEY" "$@")
}

# init_approver <label> [approver args]: the seed approver; exit 3 means another
# device (a browser) rooted that vault first, so its bridges are approved in the UI.
init_approver() {
  local label="$1" rc=0; shift
  approver init "$@" 2>&1 | sed "s/^/[$LR_TAG] /" || rc="${PIPESTATUS[0]}"
  case "$rc" in
    0) ;;
    3) lr_log "WARN: no seed approver for $label; --auto-enroll is unavailable for it" ;;
    *) stop_all; lr_die "seed approver failed for $label" ;;
  esac
}

# seed_accounts: each SEED_PLANS user gets sample data (its first request creates the
# account), its plan in hub.db, and a seed approver under approver/users/<user>/.
seed_accounts() {
  local entry user plan
  for entry in $SEED_PLANS; do
    user="${entry%%:*}" plan="${entry#*:}"
    if [ "$user" = "$DEV_USER" ]; then lr_log "WARN: --user $user is a seeded paid account; it stays on $plan"; fi
    node "$LR_HELPERS/seed.mjs" --api "http://127.0.0.1:$PROXY_PORT" --record "$DIR/seed-$user.json" --user "$user" \
      | sed "s/^/[$LR_TAG] $user: /" || { stop_all; lr_die "seeding $user failed"; }
    node "$LR_HELPERS/plans.mjs" --db "$DIR/hub.db" --user "$user" --plan "$plan" \
      | sed "s/^/[$LR_TAG] /" || { stop_all; lr_die "setting the $plan plan for $user failed"; }
    init_approver "$user" --key "$DIR/approver/users/$user/device.json" --user "$user"
  done
}

# Recorded ports win; a conflicting explicit port is an error, not a silent change.
resolve_port() { # <var> <key> <default>
  local cur="${!1}" rec; rec="$(lr_env_get "$ENV_FILE" "$2")"
  if [ -n "$rec" ] && [ -n "$cur" ] && [ "$cur" != "$rec" ]; then
    lr_die "instance '$NAME' is recorded with $2=$rec; use a new --name for different ports"
  fi
  printf -v "$1" '%s' "${cur:-${rec:-$3}}"
}

start() {
  lr_lock "$DIR"
  if lr_owned_pid "$DIR" hub >/dev/null; then lr_die "hub '$NAME' is already running (see: $0 status --name $NAME)"; fi
  resolve_port HUB_PORT HUB_PORT 18081
  resolve_port PROXY_PORT PROXY_PORT 18080
  resolve_port UI_PORT UI_PORT 15173
  resolve_port OIDC_PORT OIDC_PORT 18090
  local ports=("$HUB_PORT" "$PROXY_PORT" "$OIDC_PORT"); [ "$UI" = 1 ] && ports+=("$UI_PORT")
  lr_check_ports "$DIR" "${ports[@]}"

  mkdir -p "$DIR"/{bin,logs,run,xdg/data,xdg/config,xdg/state}
  local ui_origin="http://127.0.0.1:$UI_PORT"
  # Unlike ports, the public origin is no collision resource: an explicit value
  # replaces the recorded one, "local" clears it, and omitting it keeps it.
  case "$PUBLIC_ORIGIN" in
    local) PUBLIC_ORIGIN="" ;;
    "") PUBLIC_ORIGIN="$(lr_env_get "$ENV_FILE" PUBLIC_ORIGIN)" ;;
  esac
  # The hub enforces exactly one browser origin for CSRF (csrf_decide): the local UI.
  # Browsers never talk to the hub with their own session: the dev proxy brokers the
  # sign-in and sends this Origin itself, for the local UI and for any origin it
  # trusts (loopback, --public-origin, and the preview relays' rewritten origin).
  local csrf_origin="$ui_origin"
  # The seed/approver helpers sign in like browsers and must send this Origin.
  export HEIMDALL_LOCAL_UI_ORIGIN="$csrf_origin"
  # Bridges pair against the hub API URL and browsers against their page origin;
  # list every one so an approver on any of them does not see a foreign origin.
  local pairing_origins="http://127.0.0.1:$HUB_PORT,http://127.0.0.1:$PROXY_PORT,$ui_origin${PUBLIC_ORIGIN:+,$PUBLIC_ORIGIN}"
  lr_env_write "$ENV_FILE" \
    "KIND=hub" "NAME=$NAME" "HUB_PORT=$HUB_PORT" "PROXY_PORT=$PROXY_PORT" "UI_PORT=$UI_PORT" "OIDC_PORT=$OIDC_PORT" \
    "HUB_URL=http://127.0.0.1:$HUB_PORT" "PROXY_URL=http://127.0.0.1:$PROXY_PORT" \
    "UI_URL=$ui_origin" "UI_ORIGIN=$csrf_origin" "PUBLIC_ORIGIN=$PUBLIC_ORIGIN" \
    "DEV_USER=$DEV_USER" "APPROVER_KEY=$APPROVER_KEY" "CHECKOUT=$LR_ROOT"

  local bin="${BIN_DIR:-$DIR/bin}"
  [ -z "$BIN_DIR" ] && HEIMDALL_LOCAL_BUILD="$BUILD" lr_build "$bin" hub dev-proxy
  local hub_bin proxy_bin migrations
  hub_bin="$(lr_bin "$bin" ham-hub)"; proxy_bin="$(lr_bin "$bin" ham-dev-proxy)"
  migrations="$LR_ROOT/src/hub/repository/sqlite/migrations"

  # The hub and proxy get a private XDG/HEIMDALL_HOME so nothing they persist
  # (dev-proxy user roster, caches) lands in the installed data dir.
  local iso=(env "XDG_DATA_HOME=$DIR/xdg/data" "XDG_CONFIG_HOME=$DIR/xdg/config"
             "XDG_STATE_HOME=$DIR/xdg/state" "HEIMDALL_HOME=$DIR/xdg/data/heimdall")

  # Users authenticate only with OIDC. Locally that is tools/mock-oidc (TEST key,
  # auto-approve, http on loopback only), never a real identity provider.
  lr_log "starting mock OIDC provider on 127.0.0.1:$OIDC_PORT (dev only)"
  lr_spawn "$DIR" oidc "$DIR/logs/mock-oidc.log" python3 "$LR_ROOT/tools/mock-oidc/mock_oidc.py" \
    --port "$OIDC_PORT" --username "$DEV_USER"
  lr_wait_http "http://127.0.0.1:$OIDC_PORT/application/o/heimdall-native/jwks/" 15 || { tail -20 "$DIR/logs/mock-oidc.log" >&2 || true; stop_all; lr_die "mock OIDC provider did not come up"; }
  local issuer="http://127.0.0.1:$OIDC_PORT/application/o/heimdall-native/"
  local oidc_env=("HAM_OIDC_ALLOW_INSECURE_LOCALHOST=1" "HAM_OIDC_ISSUER=$issuer" "HAM_OIDC_JWKS_URL=${issuer}jwks/"
                  "HAM_OIDC_USERINFO_URL=${issuer}userinfo/" "HAM_OIDC_AUTHORIZE_URL=${issuer}authorize/"
                  "HAM_OIDC_TOKEN_URL=${issuer}token/" "HAM_OIDC_END_SESSION_URL=${issuer}end-session/"
                  "HAM_OIDC_API_AUDIENCE=heimdall-api" "HAM_OIDC_API_SCOPE=heimdall.api" "HAM_OIDC_WEB_CLIENT_ID=heimdall-web"
                  "HAM_AUTO_PROVISION_USERS=true" "HAM_OIDC_CLAIM_EXISTING_USERS=true")

  lr_log "starting hub on 127.0.0.1:$HUB_PORT (db $DIR/hub.db)"
  lr_spawn "$DIR" hub "$DIR/logs/hub.log" "${iso[@]}" "${oidc_env[@]}" "$hub_bin" \
    --listen "127.0.0.1:$HUB_PORT" --db "$DIR/hub.db" --migrations-dir "$migrations" \
    --ui-origin "$csrf_origin" --pairing-hub-origins "$pairing_origins" \
    --billing-enforce-plan-limits "$PLAN_LIMITS"
  if ! lr_wait_http "http://127.0.0.1:$HUB_PORT/api/v1/health" 30 || ! lr_owned_pid "$DIR" hub >/dev/null; then
    tail -20 "$DIR/logs/hub.log" >&2 || true
    stop_all; lr_die "hub did not become healthy"
  fi

  lr_log "starting dev proxy on 127.0.0.1:$PROXY_PORT as user '$DEV_USER'"
  lr_spawn "$DIR" proxy "$DIR/logs/dev-proxy.log" "${iso[@]}" "$proxy_bin" \
    --listen "127.0.0.1:$PROXY_PORT" --hub-url "http://127.0.0.1:$HUB_PORT" --default-user "$DEV_USER" \
    --hub-ui-origin "$csrf_origin" ${PUBLIC_ORIGIN:+--trusted-origin "$PUBLIC_ORIGIN"}
  if ! lr_wait_http "http://127.0.0.1:$PROXY_PORT/api/v1/health" 15; then
    tail -20 "$DIR/logs/dev-proxy.log" >&2 || true
    stop_all; lr_die "dev proxy did not come up"
  fi

  if [ "$SEED" = 1 ]; then
    command -v node >/dev/null || { stop_all; lr_die "node is required for seeding (or pass --no-seed)"; }
    node "$LR_HELPERS/seed.mjs" --api "http://127.0.0.1:$PROXY_PORT" --record "$DIR/seed.json" \
      | sed "s/^/[$LR_TAG] /" || { stop_all; lr_die "seeding failed"; }
    ensure_node_modules || { stop_all; lr_die "npm ci failed"; }
    # The hub is still usable without a seed approver; bridges are then approved in the UI.
    init_approver "$DEV_USER"
    seed_accounts
  fi

  if [ "$UI" = 1 ]; then
    ensure_node_modules || { stop_all; lr_die "npm ci failed"; }
    lr_log "starting browser UI on $ui_origin"
    lr_spawn "$DIR" ui "$DIR/logs/ui.log" env \
      "HEIMDALL_DEV_PROXY_URL=http://127.0.0.1:$PROXY_PORT" "HEIMDALL_HUB_API_URL=http://127.0.0.1:$HUB_PORT" \
      "$LR_ROOT/node_modules/.bin/vite" "$LR_ROOT" --host 127.0.0.1 --port "$UI_PORT" --strictPort
    lr_wait_http "$ui_origin/" 60 || { tail -20 "$DIR/logs/ui.log" >&2 || true; stop_all; lr_die "UI did not come up"; }
  fi
  status
}

stop_all() { lr_stop_svc "$DIR" ui; lr_stop_svc "$DIR" proxy; lr_stop_svc "$DIR" hub; lr_stop_svc "$DIR" oidc; }

stop() {
  [ -d "$DIR" ] || { lr_log "no instance '$NAME'"; return 0; }
  lr_lock "$DIR"
  stop_all
  lr_log "hub '$NAME' stopped (state kept in $DIR)"
}

status() {
  [ -f "$ENV_FILE" ] || { lr_log "no instance '$NAME' under $(lr_state_root)/hubs"; return 1; }
  echo "hub instance '$NAME' ($DIR)"
  lr_svc_status "$DIR" hub; lr_svc_status "$DIR" proxy; lr_svc_status "$DIR" ui; lr_svc_status "$DIR" oidc
  echo "  hub api : $(lr_env_get "$ENV_FILE" HUB_URL)"
  echo "  proxy   : $(lr_env_get "$ENV_FILE" PROXY_URL)  (bridge enrollment approvals)"
  echo "  ui      : $(lr_env_get "$ENV_FILE" UI_URL)"
  echo "  oidc    : http://127.0.0.1:$(lr_env_get "$ENV_FILE" OIDC_PORT)/application/o/heimdall-native/  (mock, dev only)"
  local pub; pub="$(lr_env_get "$ENV_FILE" PUBLIC_ORIGIN)"
  [ -n "$pub" ] && echo "  public  : $pub  (trusted browser origin)"
  if [ -s "$APPROVER_KEY" ]; then echo "  approver: $APPROVER_KEY"; else echo "  approver: none (approve bridges in the UI)"; fi
  local entry
  for entry in $SEED_PLANS; do
    [ -s "$DIR/seed-${entry%%:*}.json" ] && echo "  account : ${entry%%:*} on ${entry#*:} (/_dev/login?user=${entry%%:*})"
  done
  return 0
}

# approve-device: let a browser join this hub's vault (the UI shows it a pairing code).
approve_device() {
  [ -n "$CODE" ] || lr_die "approve-device needs --code <pairing code shown by the UI>"
  [ -f "$ENV_FILE" ] || lr_die "no hub instance '$NAME'"
  lr_owned_pid "$DIR" proxy >/dev/null || lr_die "hub '$NAME' is not running"
  PROXY_PORT="$(lr_env_get "$ENV_FILE" PROXY_PORT)"
  export HEIMDALL_LOCAL_UI_ORIGIN="$(lr_env_get "$ENV_FILE" UI_ORIGIN)"
  approver device --code "$CODE" || lr_die "browser approval failed"
}

case "$CMD" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  approve-device) approve_device ;;
  help) usage ;;
  *) usage; exit 2 ;;
esac
