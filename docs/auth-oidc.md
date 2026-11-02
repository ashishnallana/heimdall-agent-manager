# Authentication: OIDC only

Heimdall users sign in **only** through an OpenID Connect provider (Authentik in
the examples). The hub accepts two kinds of user credentials:

| Client | Credential | Auth kind |
|---|---|---|
| Web UI (browser) | Opaque, server-side session cookie `__Host-heimdall_session`, created by the hub's own OIDC authorization-code login | `Session` |
| Native apps (iOS, later Electron) | OIDC bearer **access token** plus a v2 device request signature | `OIDC` |
| Dedicated preview origin | Host-only `__Host-heimdall_preview` cookie, derived from a browser session | `Session` |

Non-user credentials are unchanged: bridge access/refresh tokens (`hba_`/`hbf_`),
agent instance assertions (`hit_`), and the bridge device-enrollment flow (now
approved by a signed-in browser user).

The following are **removed**: trusted-proxy / forward-auth identity headers
(`X-authentik-username` …), Hub-issued user API tokens (`hut_`), the
`/api/v1/me/tokens*` routes, `ham-hub tokens`, and the user device-authorization
grant. A `hut_` bearer gets `401 "Heimdall user tokens are no longer supported;
sign in with OIDC"`.

Design and history: `docs/plans/oidc-only-auth.md`.

## How a request is authenticated

`resolve_auth`, in order:

1. A credential in the query or JSON body → 401. Bearer tokens belong in `Authorization`.
2. An `Authorization` header is present:
   - a bridge credential gets 403 ("bridge token cannot call user APIs");
   - `hut_` gets 401;
   - anything else is validated as an OIDC access token, followed by the v2 device-proof gate.
3. Otherwise, a `__Host-heimdall_session` cookie is looked up in the session store.
4. Otherwise → 401.

There is no fallthrough: an invalid session cookie is a 401.

**OIDC bearer validation.**
- The token must be RS256, verified against the provider's JWKS. The JWKS is cached
  process-wide and is refreshed at most once per 60 s (single-flight), and only when it
  is missing, older than 10 min, or the `kid` is unknown. Signatures are checked before
  any network call.
- Claims: `iss` must equal `oidc_issuer` exactly (trailing slash included); `aud` must
  contain `oidc_api_audience`; `scope` must contain `oidc_api_scope`; `exp`/`nbf`/`iat`
  are checked with 60 s leeway.
- UserInfo is then called once per token (single-flight per token hash). Its `sub` must
  match the token's.
- Results are cached by SHA-256 of the token for at most 30 s, never beyond the token's expiry.
- Provider outages return **503** (unreachable, 5xx, provider 429) or **429** (the hub's
  outbound cap of 8 concurrent provider calls). Neither is a 401, so a native app does not
  discard its session. UserInfo 401/403 gives 401 (sign in again).

**Identity → Hub user.**
- `(issuer, subject)` maps to one Hub user (`user_external_identities`, at most one identity
  per user). The link is stable across username changes. Email is never used to match.
- An existing link is read without a write lock.
- An unlinked subject is handled as follows:
  - If a user named like its `preferred_username` exists, it is claimed **only** when
    `oidc_claim_existing_users=true`. Otherwise 403: "ask the operator to link it".
  - If no such user exists, it is provisioned only when `auto_provision_users=true`. The
    default is **false** when OIDC is configured. Otherwise 403.
  - In the browser, both refusals end at `/?auth_error=forbidden`.

## Browser login, sessions and cookies

The hub is an OIDC client of the **same provider and issuer** as the native app. It uses
Authorization Code + PKCE (S256) + `state` + `nonce`, and tokens never reach JavaScript.

- `GET /api/v1/auth/login?return_to=<same-origin path>`
  - `return_to` must be a relative path. `//`, `/\`, schemes, control characters and any
    encoded variant of these are refused, as is anything still percent-encoded after
    decoding.
  - Rate-limited to 20 per client IP per minute.
  - Sets `__Host-heimdall_login`. It contains state, nonce, PKCE verifier, `return_to` and
    expiry, sealed with XChaCha20-Poly1305 under a per-process key. No server-side row is
    created.
  - 302 to the provider's authorize endpoint.
- `GET /api/v1/auth/callback?code&state`
  - The query `state` must equal the sealed state. Each state is single use, expires after
    10 min, and dies with a hub restart.
  - The code is exchanged at the token endpoint (https only, bounded, provider error bodies
    are never echoed). The client secret is sent with HTTP Basic only if one is configured;
    otherwise this is a public PKCE client.
  - The **ID token** is validated: RS256 via the JWKS cache; `iss` must equal `oidc_issuer`;
    `aud` must contain `oidc_web_client_id` (and `azp` must equal it when present or when
    several audiences are listed); `exp`/`nbf`/`iat` with leeway; `nonce` must match.
  - The user is resolved as above and a session is created.
  - 302 to `return_to`. Failures go to `/?auth_error=1` or `/?auth_error=forbidden`, with a
    redacted `oidc_login_rejected stage=…` log line.
- `POST /api/v1/auth/logout` (CSRF-checked)
  - Deletes the session and the preview sessions derived from it, and expires the cookie.
  - Returns `{logout_url}`: the provider end-session URL with `post_logout_redirect_uri`
    and `id_token_hint`, or `/`.
- `GET /api/v1/auth/config` returns `{mode: "oidc", login_url, logout_url, logout}`.
  `GET /api/v1/me/logout-url` returns the end-session URL.

**Session cookie.**
- `__Host-heimdall_session=<32 random bytes, base64url>; Path=/; Secure; HttpOnly; SameSite=Lax`,
  with Max-Age equal to the absolute TTL.
- The server stores only `sha256(id)` in `user_sessions`.
- Absolute lifetime is 7 days (`session_ttl_hours`). Idle lifetime is 24 h
  (`session_idle_hours`); `last_seen` is written at most once a minute.
- A cookie name that appears more than once is ignored.

**CSRF and WebSockets.**
- For every hub-origin request, a cookie-bearing request that changes state must be
  `Sec-Fetch-Site: same-origin` or carry `Origin == ui_origin`. A cookie WebSocket upgrade
  must carry `Origin == ui_origin`.
- `ui_origin` is therefore mandatory.
- User WebSocket tickets (`POST /api/v1/me/ws-ticket`) are issued only to browser sessions.
  They are single use, last 30 s, and are re-validated when consumed.
- Long-lived streams re-check the session at least every 30 s while the client sends frames:
  user WS, shell/agent PTY, LSP, tool stream and preview WebSockets. A logout or expiry
  therefore ends them within roughly 30–60 s. OIDC-bearer streams end at token expiry.

**Expiry and cleanup.** The reaper purges expired sessions and expired v2 device-proof nonces.

## Preview origin

With `--preview-origin` set, previewed apps run on their own host, and the hub
session cookie (host-only) never reaches it. Sign-in on that host works like this:

1. A navigation to `<preview>/p/<sid>/…` without a valid preview cookie gets:
   - a per-flow `__Host-heimdall_preview_bind_<id>` cookie (300 s). Its value is
     `<random>.<mint time>.<HMAC tag>`, minted by the hub under a sub-key derived only for
     this purpose. A value without a valid tag, or minted more than 300 s ago, is never
     accepted. At most 16 bind cookies are kept: beyond that the oldest (by mint time) are
     expired (cookie-bomb cap). A redeem whose bind cookie is missing, stale or foreign, or
     whose ticket expired, starts a fresh bound flow (within the hop limit) instead of failing;
   - a 302 to `<ui_origin>/api/v1/preview-auth/start?session=<sid>&return_to=…&bind=<sha256>&bind_id=<id>&hop=<n>`.
     After 3 consecutive bounces (a browser that drops the cookie) the hub shows a 403
     explanation instead of looping. The count is kept in a 30 s host-only
     `__Host-heimdall_preview_hop` cookie, and from the second bounce on also as a
     `__heimdall_hop` query parameter on `return_to`. That parameter is stripped before
     forwarding, so on the normal path the app's URL stays clean.

   Other requests get 401.
2. The start route requires the hub session; without one it bounces through login. It
   checks that the user owns `<sid>` and that `return_to` is under `/p/<sid>/`. It then
   mints a ticket: single use, 60 s, stored hashed, bound to the user, the parent session,
   `<sid>` and the bind hash. Then it redirects to `<preview>/__heimdall/preview-auth?ticket=…`.

   A start request without `bind` (a direct link) goes first through
   `<preview>/__heimdall/preview-bind`.
3. The hub, not the app, redeems the ticket. Redemption needs that flow's bind cookie (concurrent
   previews have independent flows), and it clears that cookie. It
   sets `__Host-heimdall_preview` (HttpOnly, Secure, SameSite=Lax, host-only, lifetime equal
   to what is left of the parent session) and redirects to `return_to`.
4. Preview requests authenticate **only** with that cookie. `Authorization` belongs to the
   app, and the hub session cookie is ignored. All `__Host-heimdall_*` (and `authentik_*`)
   cookies are stripped before forwarding.
   - A preview session ends with its parent session: immediately on logout, and within 15 s
     of expiry, unlink or disable.
   - Each parent session can hold at most 32 preview sessions.
   - Preview tickets and sessions live in hub memory. After a restart the next navigation
     simply bounces again.

**Edge requirement:** on the preview host, forward `/p/` **and** `/__heimdall/` to the
hub API listener, and return 404 for everything else.

## Configuration

Every key can be set with an environment variable or a flag; the flag wins. The hub **refuses
to start** unless both OIDC bearer and browser login are configured.

| Key | Env | Flag | Notes |
|---|---|---|---|
| issuer | `HAM_OIDC_ISSUER` | `--oidc-issuer` | exact `iss`, trailing slash preserved |
| JWKS URL | `HAM_OIDC_JWKS_URL` | `--oidc-jwks-url` | |
| UserInfo URL | `HAM_OIDC_USERINFO_URL` | `--oidc-userinfo-url` | |
| API audience | `HAM_OIDC_API_AUDIENCE` | `--oidc-api-audience` | required in native access tokens (e.g. `heimdall-api`) |
| API scope | `HAM_OIDC_API_SCOPE` | `--oidc-api-scope` | required in native access tokens (e.g. `heimdall.api`) |
| authorize URL | `HAM_OIDC_AUTHORIZE_URL` | `--oidc-authorize-url` | browser login |
| token URL | `HAM_OIDC_TOKEN_URL` | `--oidc-token-url` | browser login |
| end-session URL | `HAM_OIDC_END_SESSION_URL` | `--oidc-end-session-url` | optional; RP-initiated logout |
| web client id | `HAM_OIDC_WEB_CLIENT_ID` | `--oidc-web-client-id` | the provider's client id; the ID token `aud` must contain it |
| web client secret | `HAM_OIDC_WEB_CLIENT_SECRET_FILE` | `--oidc-web-client-secret-file` | optional **path**; unset = public PKCE client |
| redirect URI | `HAM_OIDC_REDIRECT_URI` | `--oidc-redirect-uri` | default `<ui_origin>/api/v1/auth/callback` |
| UI origin | — | `--ui-origin` | required; CSRF origin, redirect base |
| preview origin | — | `--preview-origin` | optional dedicated preview host |
| session lifetime | `HAM_SESSION_TTL_HOURS` | `--session-ttl-hours` | default 168 |
| session idle | `HAM_SESSION_IDLE_HOURS` | `--session-idle-hours` | default 24 (capped at the TTL) |
| claim existing users | `HAM_OIDC_CLAIM_EXISTING_USERS` | `--oidc-claim-existing-users` | `true`/`false`, default `false` |
| auto-provision users | `HAM_AUTO_PROVISION_USERS` | `--auto-provision-users` | `true`/`false`; default `false` with OIDC |
| XFF trusted proxies | — | `--forwarded-for-trusted-cidr` | client-IP resolution only (rate limits, audit); default `127.0.0.1/32`; the right-most X-Forwarded-For hop outside these CIDRs is the client |
| **dev only** | `HAM_OIDC_ALLOW_INSECURE_LOCALHOST=1` | `--oidc-allow-insecure-localhost` | accept `http://` endpoints / `ui_origin` / redirect whose host is exactly `localhost`, `127.0.0.1` or `[::1]`; prints a warning |

All provider URLs, `ui_origin` and the redirect URI must be `https://`, except in the dev-only
mode above. Setting some browser-login keys without the others is a startup error.

**Client IP behind a reverse proxy.** The per-client limits (sign-in starts,
device-authorization requests) and the device-approval audit key on the client
IP. The hub trusts `X-Forwarded-For` only when the TCP peer is inside
`--forwarded-for-trusted-cidr`, and then takes the **right-most hop that is not
itself a trusted proxy**. Hops further left are client-supplied and ignored. Your
edge must therefore put the real client address in that header. Otherwise every
request looks like it came from the proxy and shares one rate-limit bucket. For
example, nginx behind Cloudflare:

```nginx
# Only Cloudflare reaches this nginx: overwrite (not append) with Cloudflare's view.
proxy_set_header X-Forwarded-For $http_cf_connecting_ip;   # CF-Connecting-IP
# Without Cloudflare: proxy_set_header X-Forwarded-For $remote_addr;
```

Only trust `CF-Connecting-IP` if the origin accepts connections from Cloudflare
alone. Any client that can reach nginx directly can set that header to anything.

These now **abort startup**: `--trusted-proxy-cidr`, `--login-url`, `--logout-url`,
and a set `HAM_AUTH_MODE` (any value).

## Authentik setup (Mundus as the example)

Use **one** OAuth2/OpenID provider for both the native app and the hub's browser login. Identities
are keyed by issuer, and a second provider would have a different issuer.

1. **Provider** (`heimdall-native` on Mundus):
   - Client type **public** is enough: the hub uses PKCE. If you make it confidential, give
     the hub the secret through `HAM_OIDC_WEB_CLIENT_SECRET_FILE` (SOPS/agenix), never in
     argv or env.
   - Redirect URIs:
     - `<ui_origin>/api/v1/auth/callback`, e.g. `https://heimdall.mundus.in/api/v1/auth/callback`;
     - plus the native app's existing redirect URI(s). Keep those unchanged.
   - Signing key: an RS256 certificate.
   - **Subject mode: keep it stable** (e.g. "Based on the User's hashed ID"). Changing it
     changes every `sub`, and every link then refers to the old subject.
   - Scopes: `openid`, `profile`, `email`, plus a custom scope mapping for `heimdall.api`.
     It must make access tokens carry `aud` containing `heimdall-api` and `scope` containing
     `heimdall.api`. The native app requests it; the browser login requests only
     `openid profile email`.
   - Access token validity: native app policy. The hub caches validation for ≤ 30 s.
2. **Application** bound to the provider, with a **policy/group binding** so that only intended
   users can get tokens (e.g. group `heimdall-users`).
3. **Usernames must not be user-editable** (disable "Allow users to change username"). The
   first link uses `preferred_username` (with claim/provision); after that, the subject decides.
4. Hub settings for Mundus:

   ```sh
   HAM_OIDC_ISSUER=https://auth.mundus.in/application/o/heimdall-native/
   HAM_OIDC_JWKS_URL=https://auth.mundus.in/application/o/heimdall-native/jwks/
   HAM_OIDC_USERINFO_URL=https://auth.mundus.in/application/o/userinfo/
   HAM_OIDC_AUTHORIZE_URL=https://auth.mundus.in/application/o/authorize/
   HAM_OIDC_TOKEN_URL=https://auth.mundus.in/application/o/token/
   HAM_OIDC_END_SESSION_URL=https://auth.mundus.in/application/o/heimdall-native/end-session/
   HAM_OIDC_API_AUDIENCE=heimdall-api
   HAM_OIDC_API_SCOPE=heimdall.api
   HAM_OIDC_WEB_CLIENT_ID=<client id of the heimdall-native provider>
   # ham-hub --ui-origin https://heimdall.mundus.in [--preview-origin https://heimdall-preview.mundus.in]
   ```

5. Remove forward-auth (outposts, `auth_request`, `forward_auth`, `X-authentik-*`
   headers) in front of the hub and the preview host. The hub no longer reads them.

## Operator CLI

These run against the hub database, using the same flags/env as the server:

```sh
ham-hub users link-oidc   --user <user_id> --subject <sub> [--issuer <iss>]   # --issuer defaults to oidc_issuer
ham-hub users unlink-oidc --user <user_id> [--issuer <iss>]                    # also ends the user's sessions
ham-hub users logout      --user <user_id>                                     # end every browser session
ham-hub users disable     --user <user_id>                                     # refuse all sign-ins; ends sessions
ham-hub users enable      --user <user_id>
ham-hub users create      --name <name> --email <email>                        # pre-provision, then link-oidc
```

`link-oidc` refuses unknown or disabled users, a subject already linked to another user, and a
user who already has an identity. Re-linking the same pair is a no-op.

The subject is the `sub` claim the provider issues for that user. Read it from a token or
UserInfo response for the user; with hashed subject mode it is not the username. The alternative
is a one-off deploy with `HAM_OIDC_CLAIM_EXISTING_USERS=true`, which links existing users on their
next sign-in.

## Migrations and rollback

| Migration | Effect |
|---|---|
| `native_001_oidc_identities.sql` | `user_external_identities` and `vault_request_nonces`. Databases from the native branch may record it as `113_oidc_identities.sql`, `115_oidc_identities.sql` or `native_001_oidc_identities.sql`; all are recognised and never re-applied (the schema is verified, and an incomplete legacy schema fails closed). |
| `134_user_sessions.sql` | `user_sessions` (hashes only). |
| `135_clear_user_api_tokens.sql` | Deletes all `hut_` tokens and keeps the `user_api_tokens` table, so older binaries (which ALTER it on start) can still be rolled back to. A later release drops the table. |

**Rollback** to a pre-OIDC binary works schema-wise: the extra tables are ignored. But user tokens
are gone, and trusted-proxy auth must be re-enabled at the edge. Take a DB backup before upgrading.

## Threat notes

- **Tokens never reach JavaScript.** The browser holds only HttpOnly `__Host-` cookies; the
  hub keeps the ID token only for the logout hint.
- **Login CSRF and replay:** state is sealed in this browser's cookie, single use, and expires
  in 10 min; nonce binds the ID token; PKCE binds the code.
- **Open redirect:** `return_to` must be a strictly relative path, both for the hub and for
  the preview.
- **CSRF:** the Origin / `Sec-Fetch-Site` check covers all cookie writes and cookie WebSockets.
  The preview host is same-site but a different origin, so its requests fail the Origin check.
- **Preview isolation:** the app never sees hub cookies, and the hub never uses the app's
  `Authorization`. Tickets are browser-bound, so a planted ticket cannot sign a victim into
  someone else's preview. Known limit: the preview cookie is host-wide, so a previewed app can
  make credentialed requests to the *same user's* other previews (it cannot read the cookie).
  **Accepted residual risk:** script already running on the victim's own preview origin could
  plant a bind value it harvested within the last 300 s (for example as a non-HttpOnly cookie
  of the same name), and so steer that browser's next preview sign-in. This is accepted: script
  in that position can already phish the user inside the previewed app. It cannot forge a value
  (HMAC under a hub-only key), cannot reuse one after 300 s, and never obtains the hub session
  or the preview cookie.
- **Provider outage:** 503/429 rather than 401. Forged tokens never cause provider calls
  (cached JWKS, rate-limited refresh, outbound cap).
- **Identity claiming:** off by default. Usernames must be immutable in the provider, and the
  app must be group-bound.
- **Rate limits:** `/auth/login` creates no state server-side and is limited per client IP. The
  client IP is the right-most untrusted X-Forwarded-For hop, so a forged left part cannot pick it.
- **Session revocation:** logout, `users logout|unlink-oidc|disable` and expiry all end sessions;
  streams notice within about a minute.

## Local development

See `tools/mock-oidc/README.md` (a stdlib-only mock provider, the HAM_OIDC_* env it prints,
and `HAM_OIDC_ALLOW_INSECURE_LOCALHOST=1`). `scripts/oidc-smoke/smoke.sh` runs a browser-less
login → `/me` → logout check against the built UI.

### Dev login through `ham-dev-proxy`

The local stacks (`scripts/local-hub.sh`, `scripts/dev-stack.sh`) put `ham-dev-proxy` in
front of the hub, and the browser UI (Vite, or a preview server) sends `/api/v1` and
`/_dev` to it. A browser cannot always hold the hub session cookie: the Heimdall preview
relay strips `__Host-heimdall_*` cookies and rewrites every `Set-Cookie` Path to the preview
prefix, which a `__Host-` cookie may not carry. So the proxy signs in **on the browser's
behalf**, after the relay. Hub auth is unchanged: the proxy runs the hub's real
authorization-code flow.

1. **Sign-in.** A page navigation to `/api/v1/auth/login?return_to=…` reaches the proxy,
   which runs hub `/auth/login` → mock `/authorize` (`login_hint` = the selected dev user,
   auto-approved) → hub `/auth/callback` without the browser, keeps the hub session in
   memory per dev user, and answers `302` to the relative `return_to`. No hub cookie goes
   to the browser. Script-driven sign-in (fetch-style requests, `seed.mjs`,
   `tests/hub_oidc_login.py`) is not brokered: those requests get the provider redirect and
   then carry their own session cookie, which the proxy forwards unchanged.
2. **Requests.** A request without its own bearer or hub session cookie gets the brokered
   session for its dev user (`ham_dev_user` cookie, else the active user), plus
   `Origin: <hub --ui-origin>` for the hub's CSRF check. WebSocket upgrades are handled the
   same way. When the hub answers 401, the proxy signs in again once and retries.
3. **Who gets it.** Only a trusted browser origin: loopback, or a `--trusted-origin` the
   proxy was started with. A request with `Sec-Fetch-Site` other than `same-origin`/`none`
   never gets it. A foreign page the developer has open therefore cannot use the proxy as a
   CSRF bypass.
4. **Sign-out and switching.** `POST /api/v1/auth/logout` drops the cached session, and
   until the next sign-in nothing is signed in automatically. `/_dev/login?user=<name>`
   (or the `/_dev/` page) switches the dev user.
5. **Real provider.** Brokering only engages when the hub's provider is a loopback mock.
   Against a real provider the proxy keeps the browser-driven flow and only adds
   `login_hint`.

**Origins.** The hub's `--ui-origin` is always the local UI. That is Vite on
`http://127.0.0.1:5173` for `dev-stack.sh` (override with `HAM_DEV_UI_ORIGIN` or
`HAM_DEV_UI_PORT`), and `http://127.0.0.1:<--ui-port>` for `local-hub.sh`. Sign-in on
localhost therefore lands on the UI, and cookie WebSockets pass CSRF. The proxy is started
with `--hub-ui-origin` set to the same value.

**Through a Heimdall preview.** `scripts/dev-preview.sh` (Vite with HMR) and
`scripts/ui-preview.sh` (built bundle) need no configuration. They forward `/api/v1` to the
running `local-hub.sh` instance's proxy (`$HEIMDALL_LOCAL_HUB`, default `default`), or else
to `dev-stack.sh`'s `:8080` (`scripts/lib/dev-proxy-upstream.sh`). `HEIMDALL_PREVIEW_UPSTREAM`
overrides that choice. Their relays (`dev-preview.mjs`, `preview-server.mjs`) learn the
preview origin from the session's `preview_url`. A request whose `Origin` is exactly that
origin is forwarded with the relay's own loopback origin, so the proxy trusts it
(`scripts/lib/preview-origin.mjs`). Any other `Origin` passes through unchanged and gets no
session.

**Other reverse proxies** in front of the UI need their public origin trusted
explicitly: `local-hub.sh start --public-origin https://dev.example`, or
`HAM_DEV_TRUSTED_ORIGINS=https://dev.example` (comma separated) for `dev-stack.sh`.

**Smoke.** `scripts/oidc-smoke/dev-login-smoke.sh [ham-hub] [ham-dev-proxy]` runs mock
OIDC, the hub, the proxy and `preview-server.mjs` behind `scripts/oidc-smoke/relay.py`, a
stand-in for the hub's preview relay (path prefix, no `Sec-Fetch-*`, hub cookies stripped,
`Set-Cookie` paths rewritten). It then checks, from the preview origin: sign-in, `/me`, a
CSRF-checked POST, the user WebSocket and logout. It also checks that foreign origins get
no session.
