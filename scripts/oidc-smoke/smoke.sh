#!/usr/bin/env bash
# Browser-less OIDC UI smoke (DEV/TEST): mock OIDC provider + hub + a static
# front serving the built UI (dist/) and proxying /api/ to the hub, like Caddy.
# Scripts login -> callback -> /api/v1/me + first UI calls -> ws-ticket -> logout.
#
# Usage: npm run build && scripts/oidc-smoke/smoke.sh [path/to/ham-hub]
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); WT=$(cd "$D/../.." && pwd)
HUB_BIN=${1:-$WT/result/bin/ham-hub}
S=${SMOKE_STATE_DIR:-$HOME/.cache/heimdall-oidc-smoke}; rm -rf "$S"; mkdir -p "$S"
OIDC=19490; HUB=19481; UI=19473; ORIGIN=http://127.0.0.1:$UI
python3 $WT/tools/mock-oidc/mock_oidc.py --port $OIDC --username alice > $S/oidc.log 2>&1 & P1=$!
eval "$(python3 $WT/tools/mock-oidc/mock_oidc.py --port $OIDC --ui-origin $ORIGIN --print-env | grep -v '^#' | sed 's/^/export /')"
"$HUB_BIN" --listen 127.0.0.1:$HUB --db $S/hub.db --ui-origin $ORIGIN > $S/hub.log 2>&1 & P2=$!
python3 $D/front.py $WT/dist http://127.0.0.1:$HUB $UI > $S/front.log 2>&1 & P3=$!
trap 'kill $P1 $P2 $P3 2>/dev/null' EXIT
for i in $(seq 1 60); do curl -sf http://127.0.0.1:$HUB/api/v1/health >/dev/null && break; sleep 0.5; done
pass=0; fail=0; check() { if [ "$2" = "$3" ]; then echo "ok   $1"; pass=$((pass+1)); else echo "FAIL $1 (got '$2', want '$3')"; fail=$((fail+1)); fi; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
hdr() { curl -s -D - -o /dev/null "$@" | tr -d '\r'; }
check "UI index served" "$(code $ORIGIN/)" 200
check "index references built assets" "$(curl -s $ORIGIN/ | grep -q 'assets/index-' && echo yes)" yes
check "/me unauthenticated -> 401" "$(code $ORIGIN/api/v1/me)" 401
check "auth config mode=oidc" "$(curl -s $ORIGIN/api/v1/auth/config | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["mode"])')" oidc
# 1. /login -> mock authorize (login cookie set)
H1=$(hdr "$ORIGIN/api/v1/auth/login?return_to=%2F%23%2Fhome")
LOC1=$(echo "$H1" | sed -n 's/^Location: //Ip'); LOGIN=$(echo "$H1" | sed -n 's/^Set-Cookie: \(__Host-heimdall_login=[^;]*\).*/\1/Ip')
check "login redirects to provider" "$(echo "$LOC1" | grep -c "^http://127.0.0.1:$OIDC/application/o/heimdall-native/authorize/")" 1
check "login cookie set" "$([ -n "$LOGIN" ] && echo yes)" yes
# 2. provider auto-approves -> callback at the UI origin
LOC2=$(hdr "$LOC1" | sed -n 's/^Location: //Ip')
check "provider redirects to callback" "$(echo "$LOC2" | grep -c "^$ORIGIN/api/v1/auth/callback?")" 1
# 3. callback through the front -> session cookie + return_to
H3=$(hdr -H "Cookie: $LOGIN" "$LOC2")
check "callback returns to return_to" "$(echo "$H3" | sed -n 's/^Location: //Ip')" "/#/home"
SESSION=$(echo "$H3" | sed -n 's/^Set-Cookie: \(__Host-heimdall_session=[^;]*\).*/\1/Ip')
check "session cookie HttpOnly+Secure+Lax" "$(echo "$H3" | grep -i '^Set-Cookie: __Host-heimdall_session=' | grep -c 'Secure; HttpOnly; SameSite=Lax')" 1
# 4. the UI's first API calls succeed with the cookie
check "/me with cookie -> 200" "$(code -H "Cookie: $SESSION" $ORIGIN/api/v1/me)" 200
check "/me is alice" "$(curl -s -H "Cookie: $SESSION" $ORIGIN/api/v1/me | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["user_id"])')" alice
for p in /api/v1/me/experiments /api/v1/projects /api/v1/bridges /api/v1/agents; do check "GET $p with cookie" "$(code -H "Cookie: $SESSION" $ORIGIN$p)" 200; done
check "ws-ticket (same-origin POST)" "$(code -X POST -H "Cookie: $SESSION" -H "Origin: $ORIGIN" -H 'Content-Type: application/json' -d '{}' $ORIGIN/api/v1/me/ws-ticket)" 200
check "cross-origin POST with cookie refused" "$(code -X POST -H "Cookie: $SESSION" -H 'Origin: https://evil.example' -H 'Content-Type: application/json' -d '{}' $ORIGIN/api/v1/me/ws-ticket)" 403
check "hut_ bearer -> 401" "$(code -H 'Authorization: Bearer hut_old' $ORIGIN/api/v1/me)" 401
# 5. logout -> provider end-session URL, cookie expired, /me 401
OUT=$(curl -s -D $S/logout.h -X POST -H "Cookie: $SESSION" -H "Origin: $ORIGIN" -H 'Content-Type: application/json' -d '{}' $ORIGIN/api/v1/auth/logout)
check "logout returns end-session url" "$(echo "$OUT" | python3 -c 'import sys,json;u=json.load(sys.stdin)["data"]["logout_url"];print("end-session" in u and "id_token_hint=" in u)')" True
check "logout expires cookie" "$(tr -d '\r' < $S/logout.h | grep -ic '^Set-Cookie: __Host-heimdall_session=;.*Max-Age=0')" 1
check "/me after logout -> 401" "$(code -H "Cookie: $SESSION" $ORIGIN/api/v1/me)" 401
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
