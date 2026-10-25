# mock-oidc — local OIDC provider (DEV / TEST ONLY)

The hub authenticates users **only** with OIDC (browser session from its own
authorization-code login, or an OIDC bearer for native apps). For local
development and tests, `mock_oidc.py` is a tiny stdlib-only provider:

- auto-approves every authorization request for one user (`--username`, or the
  last `login_hint` in the request — `ham-dev-proxy` adds its selected dev user);
- requires PKCE S256, honours `state` and `nonce`, single-use codes;
- signs ID/access tokens with the **test-only** key committed in
  `src/hub/service/auth/testdata/oidc_rs256_signing.json`.

Never expose it beyond 127.0.0.1 or point a production hub at it. The hub only
accepts its `http://` endpoints with `HAM_OIDC_ALLOW_INSECURE_LOCALHOST=1`, and
only for an exact loopback host.

## Run a hub against it

```bash
python3 tools/mock-oidc/mock_oidc.py --port 9400 --username alice &

# Hub environment (prints HAM_OIDC_* incl. HAM_OIDC_ALLOW_INSECURE_LOCALHOST=1):
eval "$(python3 tools/mock-oidc/mock_oidc.py --port 9400 --ui-origin http://127.0.0.1:8081 \
        --print-env | grep -v '^#' | sed 's/^/export /')"
ham-hub --listen 127.0.0.1:8081 --db /tmp/dev-hub.db --ui-origin http://127.0.0.1:8081
```

Open `http://127.0.0.1:8081/api/v1/auth/login` (or the UI) and you are signed
in as `alice`. `--print-env` also sets `HAM_AUTO_PROVISION_USERS=true` and
`HAM_OIDC_CLAIM_EXISTING_USERS=true` so dev users are created/linked on first
sign-in. If the hub's `--ui-origin` is not the hub itself (e.g. a Vite dev
server or ham-dev-proxy in front of it), the redirect URI defaults to
`<ui-origin>/api/v1/auth/callback`; set `HAM_OIDC_REDIRECT_URI` to override.

## Endpoints

Issuer: `http://127.0.0.1:<port>/application/o/heimdall-native/`

| path (under the issuer) | |
|---|---|
| `authorize/` | auto-approve → `302 redirect_uri?code&state` |
| `token/` | `authorization_code` + PKCE → `id_token` (aud = client id, nonce) + `access_token` (aud includes `--api-audience`, scope includes `--api-scope`) |
| `jwks/` | public half of the test key |
| `userinfo/` | `Authorization: Bearer <access_token>` → claims; 401 otherwise |
| `end-session/` | `302 post_logout_redirect_uri` |
| `.well-known/openid-configuration` | discovery document (informational; the hub does not fetch it) |
| `/__mock/access-token` (POST, not under the issuer) | `{"username": "...", "subject"?: "..."}` → a native-app bearer for tests |

Subjects: the default user gets `--subject` (default `mock-subject-dev`); any
other username `u` gets `mock-u`.

Flags: `--port`, `--username`, `--subject`, `--client-id` (default
`heimdall-web`), `--client-secret` (require one at the token endpoint),
`--api-audience` (default `heimdall-api`), `--api-scope` (default
`heimdall.api`), `--token-ttl`, `--print-env`, `--verbose`.

## Helpers

- Python: `tests/hub_oidc_login.py` — `MockOIDC.start()`, `mock.hub_env(hub_base)`,
  `login(hub_base, username)` (runs the real browser flow, returns the session id),
  `session_headers(session, ui_origin)`, `mock.access_token(username)`.
- Node: `tests/e2e/hubOidc.mjs` — `startMockOidc()`, `hubLogin()`, `sessionHeaders()`,
  `sessionPool()`.
- Shell: `scripts/lib/hub-oidc-dev.sh` — `hub_oidc_start_mock`, `hub_oidc_export_env`,
  `hub_oidc_login`, `hub_oidc_cookie`.

Cookie-authenticated state-changing requests must send `Origin: <ui-origin>`
(the hub's CSRF check); the helpers do.
