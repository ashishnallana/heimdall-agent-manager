#!/usr/bin/env bash
# Dev login smoke (DEV/TEST): sign-in through ham-dev-proxy's OIDC broker, seen
# from a browser on the Heimdall preview origin. Runs mock OIDC + hub + dev proxy +
# scripts/preview-server.mjs behind relay.py, a stand-in for the Hub's preview relay
# (path prefix, no Sec-Fetch-*, hub cookies stripped, Set-Cookie paths rewritten):
#
#   client (Origin: https://preview.smoke.test) -> relay.py /p/<sid>/
#     -> preview-server.mjs -> ham-dev-proxy -> ham-hub <- mock OIDC
#
# Checks login, /me, a CSRF-checked POST, the user WebSocket and logout on that
# path, and that foreign origins get no session. See docs/auth-oidc.md
# ("Local development").
#
# Usage: scripts/oidc-smoke/dev-login-smoke.sh [ham-hub] [ham-dev-proxy]
#   (default: ./result-hub/bin/ham-hub and ./result-devproxy/bin/ham-dev-proxy,
#    as built by scripts/dev-stack.sh build)
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); WT=$(cd "$D/../.." && pwd)
HUB_BIN=${1:-$WT/result-hub/bin/ham-hub}
PROXY_BIN=${2:-$WT/result-devproxy/bin/ham-dev-proxy}
for b in "$HUB_BIN" "$PROXY_BIN"; do [ -x "$b" ] || { echo "missing binary $b (scripts/dev-stack.sh build)"; exit 2; }; done
S=${SMOKE_STATE_DIR:-$HOME/.cache/heimdall-dev-login-smoke}; rm -rf "$S"; mkdir -p "$S/dist" "$S/xdg"
# shellcheck source=../lib/hub-oidc-dev.sh
. "$WT/scripts/lib/hub-oidc-dev.sh"
port() { hub_oidc_free_port; }
HUB=$(port); PROXY=$(port); APP=$(port); RELAY=$(port); UI=$(port)
UI_ORIGIN=http://127.0.0.1:$UI
SID=sh_devloginsmoke
PREVIEW_ORIGIN=https://preview.smoke.test
echo '<!doctype html><title>smoke</title>' > "$S/dist/index.html"

pids=()
trap 'kill "${pids[@]}" 2>/dev/null; hub_oidc_stop_mock' EXIT
# The proxy picks the account (login_hint); "reviewer" is in its default roster.
hub_oidc_start_mock "$S" reviewer || exit 1
hub_oidc_export_env
"$HUB_BIN" --listen 127.0.0.1:$HUB --db "$S/hub.db" --migrations-dir "$WT/src/hub/repository/sqlite/migrations" \
  --ui-origin "$UI_ORIGIN" > "$S/hub.log" 2>&1 & pids+=($!)
XDG_DATA_HOME="$S/xdg" XDG_CONFIG_HOME="$S/xdg" HEIMDALL_HOME="$S/xdg/heimdall" "$PROXY_BIN" \
  --listen 127.0.0.1:$PROXY --hub-url http://127.0.0.1:$HUB --hub-ui-origin "$UI_ORIGIN" \
  --default-user reviewer > "$S/dev-proxy.log" 2>&1 & pids+=($!)
HEIMDALL_PREVIEW_PORT=$APP HEIMDALL_PREVIEW_UPSTREAM=http://127.0.0.1:$PROXY \
  HEIMDALL_PREVIEW_URL_FILE="$S/preview-url" HAM_CTL=/nonexistent \
  node "$WT/scripts/preview-server.mjs" --dir "$S/dist" > "$S/preview-server.log" 2>&1 & pids+=($!)
python3 "$D/relay.py" $RELAY "/p/$SID" $APP > "$S/relay.log" 2>&1 & pids+=($!)

for i in $(seq 1 60); do curl -sf -o /dev/null http://127.0.0.1:$HUB/api/v1/health && break; sleep 0.5; done
for i in $(seq 1 40); do curl -sf -o /dev/null "http://127.0.0.1:$RELAY/p/$SID/" && break; sleep 0.25; done
# Written after the server is up, as ui-preview.sh does once shell start returns.
echo "$PREVIEW_ORIGIN/p/$SID/" > "$S/preview-url"

python3 "$D/dev_login_checks.py" --relay "http://127.0.0.1:$RELAY/p/$SID" --proxy "http://127.0.0.1:$PROXY" \
  --preview-origin "$PREVIEW_ORIGIN" --user reviewer
rc=$?
[ $rc -eq 0 ] || echo "logs in $S (hub.log, dev-proxy.log, preview-server.log, relay.log)"
exit $rc
