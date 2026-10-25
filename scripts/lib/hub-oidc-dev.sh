# shellcheck shell=bash
# Local DEV/TEST sign-in for a ham-hub: users authenticate only with OIDC, so
# scripts run tools/mock-oidc (TEST key, auto-approve) and sign in through the
# real browser flow. Source this file, then:
#
#   hub_oidc_start_mock "$WORK"            # sets MOCK_OIDC_PORT / MOCK_OIDC_PID
#   hub_oidc_export_env                    # exports HAM_OIDC_* for the hub process
#   "$HUB_BIN" ... --ui-origin "$UI_ORIGIN" &
#   SESSION=$(hub_oidc_login "$HUB_BASE" alice)
#   curl -H "$(hub_oidc_cookie "$SESSION")" -H "Origin: $UI_ORIGIN" ...
#
# Never use against a real identity provider or a production hub.

_HUB_OIDC_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

hub_oidc_free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'
}

# hub_oidc_start_mock <log-dir> [default-username]
hub_oidc_start_mock() {
  local dir="${1:-/tmp}" user="${2:-dev}"
  MOCK_OIDC_PORT="${MOCK_OIDC_PORT:-$(hub_oidc_free_port)}"
  python3 "$_HUB_OIDC_REPO/tools/mock-oidc/mock_oidc.py" --port "$MOCK_OIDC_PORT" --username "$user" \
    >"$dir/mock-oidc.log" 2>&1 &
  MOCK_OIDC_PID=$!
  local i
  for i in $(seq 1 100); do
    curl -sf -o /dev/null "http://127.0.0.1:$MOCK_OIDC_PORT/application/o/heimdall-native/jwks/" && return 0
    sleep 0.1
  done
  echo "mock OIDC provider did not start (see $dir/mock-oidc.log)" >&2
  return 1
}

hub_oidc_stop_mock() {
  [ -n "${MOCK_OIDC_PID:-}" ] && kill "$MOCK_OIDC_PID" 2>/dev/null || true
}

# hub_oidc_export_env [redirect-base]: exports the hub's OIDC settings for the
# mock. With redirect-base, the callback is pinned to <redirect-base>/api/v1/auth/callback.
hub_oidc_export_env() {
  local issuer="http://127.0.0.1:$MOCK_OIDC_PORT/application/o/heimdall-native/"
  export HAM_OIDC_ALLOW_INSECURE_LOCALHOST=1
  export HAM_OIDC_ISSUER="$issuer"
  export HAM_OIDC_JWKS_URL="${issuer}jwks/"
  export HAM_OIDC_USERINFO_URL="${issuer}userinfo/"
  export HAM_OIDC_AUTHORIZE_URL="${issuer}authorize/"
  export HAM_OIDC_TOKEN_URL="${issuer}token/"
  export HAM_OIDC_END_SESSION_URL="${issuer}end-session/"
  export HAM_OIDC_API_AUDIENCE=heimdall-api
  export HAM_OIDC_API_SCOPE=heimdall.api
  export HAM_OIDC_WEB_CLIENT_ID=heimdall-web
  export HAM_AUTO_PROVISION_USERS=true
  export HAM_OIDC_CLAIM_EXISTING_USERS=true
  if [ -n "${1:-}" ]; then export HAM_OIDC_REDIRECT_URI="${1%/}/api/v1/auth/callback"; fi
}

# hub_oidc_login <hub-or-proxy-base> [username] -> prints the raw session id
hub_oidc_login() {
  python3 "$_HUB_OIDC_REPO/tests/hub_oidc_login.py" "$1" "${2:-dev}"
}

# hub_oidc_cookie <session> -> a curl -H value
hub_oidc_cookie() {
  printf 'Cookie: __Host-heimdall_session=%s' "$1"
}
