# Plan: OIDC-only authentication for the Hub

Status: in progress · Branch: `feat/oidc-only-auth` (worktree `/home/tanmay/hamwt-oidc`, from `main` @ 55a93637)
First rollout target: **Mundus** hub (`heimdall.mundus.in` on dawnstar). Brolabs switches later, same code, config only.

## Goal

1. Merge the native-app OIDC support (today only on `repair/native-v0445`, deployed to Mundus as an
   out-of-tree override) into `main`, so one release tag serves every hub.
2. Delete trusted-proxy header authentication (`X-authentik-username` etc. + `trusted_proxy_cidrs`).
3. Delete Hub-managed user API tokens (`hut_`). The Hub no longer issues, stores, lists or accepts them.
4. OIDC is the only way a **user** authenticates:
   - **Web UI** → Hub-side OIDC Authorization Code + PKCE (confidential client) → opaque server-side
     session, `__Host-` cookie. ("Backend-for-frontend"; tokens never reach JS.)
   - **Native clients** (iOS now, Electron later) → OIDC bearer access token + v2 device request
     signature (the existing native path, unchanged semantics).
5. Non-user credentials are untouched: bridge `hba_`/`hbf_` tokens, instance tokens, bridge
   device-flow enrollment/approval (approval now authenticated by the browser session).

Out of scope: Electron/ham-ctl user-mode migration to OIDC (they will stop authenticating as users;
accepted), brolabs Authentik config, the nix config repo (handled separately by the orchestrator).

## Design

### Auth kinds (`src/contracts/auth.odin`)
- Remove `User_Token` and `Trusted_Proxy`. Add `Session` (browser cookie) and `OIDC` (bearer).
- Every check of the form `kind == .User_Token || kind == .Trusted_Proxy` becomes a single helper
  `contracts.is_user_auth(ctx)` (Session or OIDC). Where code specifically required an *interactive
  browser* (`vault_directory_handlers.odin` genesis/approve, device approval page, billing origin
  check) use `.Session` (and, where the native app legitimately needs it — vault directory/bootstrap
  per the native branch — also `.OIDC` with a verified device proof, as on the native branch).
- `user_token_id` on `Auth_Context` (stream revocation) is replaced by `session_id` for Session and
  left empty for OIDC (OIDC streams are bounded by token expiry checks; keep whatever revocation hook
  the native branch used for proof/token revocation identities).

### Config (no hard-coded issuer)
Replace the native branch's hard-coded `auth.mundus.in` constants and `HAM_AUTH_MODE` with config
keys (CLI flag + env, following existing `config_bind.odin`/`main.odin` conventions):

| key / env | meaning |
|---|---|
| `oidc_issuer` / `HAM_OIDC_ISSUER` | exact `iss` (trailing slash preserved) |
| `oidc_jwks_url` / `HAM_OIDC_JWKS_URL` | JWKS endpoint |
| `oidc_userinfo_url` / `HAM_OIDC_USERINFO_URL` | UserInfo endpoint |
| `oidc_authorize_url` / `HAM_OIDC_AUTHORIZE_URL` | browser authorization endpoint |
| `oidc_token_url` / `HAM_OIDC_TOKEN_URL` | code exchange endpoint |
| `oidc_end_session_url` / `HAM_OIDC_END_SESSION_URL` | optional RP-initiated logout |
| `oidc_api_audience` / `HAM_OIDC_API_AUDIENCE` | bearer `aud` required for native tokens (Mundus: `heimdall-api`) |
| `oidc_api_scope` / `HAM_OIDC_API_SCOPE` | required bearer scope (Mundus: `heimdall.api`) |
| `oidc_web_client_id` / `HAM_OIDC_WEB_CLIENT_ID` | client id the hub uses for browser login at the SAME provider; defaults to the provider's (native) client id; the ID token `aud` must equal it |
| `oidc_web_client_secret_file` / `HAM_OIDC_WEB_CLIENT_SECRET_FILE` | optional path to a client secret (never a literal in env/argv); unset → public-client PKCE |
| `oidc_claim_existing_users` / `HAM_OIDC_CLAIM_EXISTING_USERS` | default `false`; `true` lets an unlinked subject claim the existing user whose name equals its `preferred_username` |
| `auto_provision_users` / `HAM_AUTO_PROVISION_USERS` / `--auto-provision-users` | explicit `true`/`false`; unset → `false` when OIDC is configured (`true` otherwise) |
| `oidc_redirect_uri` | default `<ui_origin>/api/v1/auth/callback` |
| `session_ttl_hours` / idle | sensible defaults: absolute 7d, idle 24h |

Explicit endpoints (no discovery fetch at startup) keep startup deterministic and testable.
Startup fails with a clear message if the required OIDC keys are missing — except for a documented
local-dev/test configuration (see Dev & tests). Remove `auto_provision_users` semantics only if
they no longer apply. Identity resolution uses `user_external_identities` (issuer+subject → user;
stable across username changes; email never used for matching; `UNIQUE(user_id)`, one identity per
user). **Policy (phase 1 review):** an existing link is a plain read. An unlinked subject whose
normalized `preferred_username` matches an existing user is claimed **only** when
`oidc_claim_existing_users=true`; otherwise 403 "ask the operator to link it". An unlinked subject
with no matching user is provisioned only when `auto_provision_users` is on (default off with
OIDC); otherwise 403. Operators link/unlink with
`ham-hub users link-oidc --user <id> [--issuer <iss>] --subject <sub>` /
`ham-hub users unlink-oidc --user <id> [--issuer <iss>]` (`--issuer` defaults to `oidc_issuer`).
Existing Mundus users keep their `user_id`: those the native branch already linked resolve as
before; any not yet linked are linked by the operator (or a one-off deploy with
`HAM_OIDC_CLAIM_EXISTING_USERS=true`).

**Decision (phase 1 review, finding 5): one provider, one issuer.** Identities are keyed by a single
issuer and `UNIQUE(user_id)`, and a separate Authentik provider for the web client would have a
different issuer, so already-linked users would get 409s. Therefore browser login uses the **same**
Authentik provider/issuer as native (the existing `heimdall-native` provider). The hub is a client
of that provider using Authorization Code + PKCE (S256) + `state` + `nonce`. A client secret is
optional (`oidc_web_client_secret_file`): sent if configured, otherwise public-client PKCE.
`oidc_web_client_id` defaults to the provider's client id. The ID token must have `iss ==
oidc_issuer` and `aud == oidc_web_client_id`. Tokens stay server-side (BFF); the session cookie
design below is unchanged. The operator only adds the hub callback redirect URI
(`<ui_origin>/api/v1/auth/callback`) to the existing provider. The `UNIQUE(user_id)` schema stays.

### Browser session flow (new)
Routes (public, no auth):
- `GET /api/v1/auth/login?return_to=<path>` → create `state`, `nonce`, PKCE `code_verifier`
  (S256), store them server-side keyed by state (short TTL, single use) **and** bind to the browser
  with a `__Host-heimdall_login` cookie (HttpOnly, Secure, SameSite=Lax, Path=/, 10 min). 302 to
  authorize URL with `response_type=code`, `scope=openid profile email`, `client_id`, `redirect_uri`,
  `state`, `nonce`, `code_challenge`. `return_to` must be a same-origin relative path (reject `//`,
  schemes, backslashes) — open-redirect safe.
- `GET /api/v1/auth/callback?code&state` → verify state matches cookie + server record (single use),
  exchange code at token URL with client secret (HTTP Basic or post; Authentik accepts both) and
  `code_verifier` (client secret only when `oidc_web_client_secret_file` is set; otherwise a public
  PKCE client at the same provider/issuer as native); validate the **ID token** (RS256 via existing JWKS code, `iss`, `aud == web
  client id`, `exp`/`iat` skew, `nonce`); resolve user via the shared external-identity claim; create
  session; set `__Host-heimdall_session` (HttpOnly, Secure, SameSite=Lax, Path=/, Max-Age = absolute
  TTL); clear login cookie; 302 to `return_to` (default `/`). On any failure: log a redacted stage,
  302 to `/?auth_error=1` (never echo provider errors raw).
- `POST /api/v1/auth/logout` → CSRF/Origin-checked; delete session row; expire cookie; respond with
  JSON `{logout_url}` (end-session URL with `id_token_hint` if stored + `post_logout_redirect_uri` =
  ui_origin) so the UI can navigate there. Keep `GET /api/v1/me/logout-url` working or replace it.
- `GET /api/v1/auth/config` → `{ mode: "oidc", login_url: "/api/v1/auth/login", logout: "POST /api/v1/auth/logout" }` (keep backwards-compatible field names the UI reads).

Session storage (new migration, next free number after 133 — check at implementation time):
`user_sessions(session_id_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(user_id),
created_at, last_seen_at, expires_at, idle_expires_at, id_token TEXT NULL /* for end-session hint
only */, user_agent TEXT NULL)` + `oidc_login_states(state_hash PK, nonce, code_verifier,
return_to, expires_at)`. Store only SHA-256 of the session id / state (256-bit random from
`core:crypto`, base64url). Touch `last_seen_at` at most once per minute (no hot-path write per
request). Reaper (`src/hub/app/reaper.odin`) purges expired sessions/login states and expired
`vault_request_nonces`.

Request resolution (`resolve_auth`):
1. `token_in_query_or_body` rejection stays.
2. `Authorization: Bearer` present → bridge-shaped tokens rejected as today; `hut_` → **rejected**
   ("user tokens are no longer supported; sign in with OIDC"); anything else → `resolve_oidc_auth`
   (then `oidc_device_gate`, as on the native branch).
3. Else session cookie present → `resolve_session_auth`.
4. Else 401 `Unauthenticated`.
Preview-host requests: preview apps own `Authorization` and cookies on the preview origin — verify
`preview_origin_security` paths never accept the hub session cookie from a preview origin and never
forward `__Host-heimdall_*` cookies upstream (extend the existing header-stripping that drops
`x-authentik-*` / `authentik_*` cookies to drop the new cookie names; keep the authentik stripping
too, harmless).
CSRF: cookie-authenticated **state-changing** requests (non-GET/HEAD/OPTIONS) must pass the existing
Origin check (`csrf_origin_equal` / `ui_origin`) — audit `middleware.odin`; today some protection
assumed the proxy. WebSocket upgrades authenticated by cookie must check `Origin == ui_origin`.

### What gets deleted
- `resolve_trusted_proxy_auth`, `Trusted_Proxy_Config` header fields, `trusted_proxy_cidrs` config/
  flag/env plumbing for *auth* (keep any CIDR list still used for client-IP resolution in
  `device_auth/ip.odin` — rename it `forwarded_for_trusted_cidrs` if it must stay), `require_trusted_proxy_auth`
  (callers use `require_auth` + a Session check where an interactive browser is required).
- `hut_` everything: `issue_user_api_token`, `verify_user_api_token`, `list/revoke`, `/api/v1/me/tokens*`
  routes and handlers, `ham-hub tokens` CLI subcommand, device-authorization **user token** issuance
  (`issue_device_authorization_token`) and its grant type. Bridge device grants (`bridge_grant.odin`)
  stay. Add a migration that drops the user-token table(s) (or leaves them inert — prefer drop, with a
  note) — check `user_repo_sqlite.odin` for table names.
- `ham-hub users create` may stay (operator pre-provisioning) if it doesn't depend on tokens.
- Metrics label `trusted_proxy`/`user_token` → `session`/`oidc`.

### Native branch port (from `repair/native-v0445`, diff vs `v0.4.45`)
Port the auth-relevant parts only:
`src/hub/service/auth/oidc.odin` (+tests, testdata), `repository/sqlite/external_identity.odin`,
`native_oidc_schema.odin`, `migrations/native_001_oidc_identities.sql` **with its legacy-ledger alias
logic** (Mundus DB may contain `113_oidc_identities.sql` / `115_oidc_identities.sql` /
`native_001_oidc_identities.sql`; all must be accepted, none re-applied, fresh DBs apply normally),
`transport/http/oidc_device_gate.odin` (+tests), `raw_target` on `Request`, vault-directory service/
handler changes, `iface` additions, the isolated identity connection in `wiring.odin`, and the
`user_handlers` changes. Skip unrelated files that rode along via merges (task-chain search tests,
`tests/ui_*search*`, `tests/verify-search-v2.sh`, `native-integration.json`) unless needed to compile.
Inspect each with `git diff v0.4.45 repair/native-v0445 -- <file>`.

### UI (`src/ui`)
- `AppShell.tsx` `fetchPublicAuthConfig`/login/logout: login = navigate to
  `/api/v1/auth/login?return_to=<current path>`; logout = `POST /api/v1/auth/logout` then navigate to
  returned `logout_url` (or `/`).
- Global 401 handling in the API layer (`src/ui/api/*`): on 401 from a user API, redirect to login
  (once; avoid loops — don't redirect if already on the callback/error path).
- Remove any token-management UI (`/me/tokens`) and trusted-proxy references in `src/ui/api`.
- Keep `credentials: 'include'`; confirm WebSocket connections are same-origin so the cookie flows.
- Vite dev server (`vite.config.js`) currently fakes proxy headers — replace with the dev flow below.

### Dev & tests
- Tests that authenticate with `X-authentik-username` + trusted CIDR need a replacement helper:
  an Odin test helper that creates a session row and returns a `Cookie:` header (and a fixture OIDC
  signer for bearer tests — reuse `testdata/oidc_rs256.json`). Update Odin tests, python tests and
  e2e scripts accordingly; delete tests that only covered removed behaviour (trusted proxy, `hut_`).
- Local dev: add a tiny mock OIDC provider (python stdlib, under `tools/` or `scripts/`) implementing
  authorize (auto-approve a configured user), token, jwks, userinfo, using the fixture key — so the
  dev stack and e2e can log in for real. Document in `SELF_HOSTING.md` / dev docs. Do **not** add a
  production bypass flag.
- `ham-dev-proxy` tests referencing trusted proxy: update or drop the header injection.

### Docs
- `docs/heimdall-native-oidc.md` (move from nix repo content where relevant) → `docs/auth-oidc.md`:
  config keys, Authentik setup (ONE provider shared by native and the hub's browser login; add the
  hub callback redirect URI), session model, threat notes. **Authentik requirements** (security
  relevant, since `preferred_username` drives first-link claiming/provisioning): usernames must not
  be user-editable (disable "Allow users to change username"), and the application must be bound to
  a group/policy so only intended users can obtain tokens. Document `ham-hub users link-oidc` /
  `unlink-oidc` and the claim/provision defaults.
- `SECURITY.md`, `SELF_HOSTING.md`: remove trusted-proxy/forward-auth instructions.

## Work phases (each ends with tests green + a commit + review)

1. **Port native OIDC to main** (bearer path, identity claim, device gate, migrations w/ aliases),
   configurable endpoints, no behaviour removal yet. Odin auth/http/sqlite suites pass.
2. **Browser sessions**: login/callback/logout, session store + migration, cookie resolution, CSRF/
   WebSocket Origin checks, reaper, preview cookie stripping. Unit + http tests incl. negative cases
   (bad state, replayed state, wrong nonce, wrong aud, expired, open-redirect `return_to`,
   cross-origin POST with cookie, preview origin with cookie).
3. **Delete trusted-proxy auth and `hut_` tokens**; migrate all auth-kind checks; drop routes/CLI;
   migrate tests to the new helpers; mock OIDC provider for dev/e2e.
4. **UI**: login/logout/401 handling, remove token UI, vite dev flow. `npm run build` + UI tests.
5. **Docs** + final full verification (all Odin test packages the repo's AGENTS.md lists, `nix build
   .#ham-hub .#heimdall`, UI tests), upgrade test against a copy of a DB at v0.4.43+native ledger
   shape (fixture from the native branch's upgrade tests).

## Verification commands
- `odin test src/hub/<pkg> -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/<pkg>-$$` for
  `service/auth`, `transport/http`, `repository/sqlite`, `service/vault_directory`, `service/device_auth`, and `tests/` packages touched.
- `npm run build` (UI), relevant `tests/*.ts` UI tests.
- `nix build .#ham-hub .#heimdall` from the worktree.

## Rollout (orchestrator, after review)
1. Tag release from main; config repo: drop `heimdall-native-hub` input/override/assertion, set OIDC
   env + `HAM_OIDC_WEB_CLIENT_SECRET_FILE` (SOPS), remove nginx/Caddy forward-auth + `X-authentik-*`
   for Mundus, update deployd health expectations.
2. User adds the hub callback redirect URI to the existing Mundus `heimdall-native` provider (same
   issuer; no new provider), and confirms usernames are not user-editable and the app is bound to a
   group/policy. Before cut-over, list Mundus users without a `user_external_identities` row and
   link them (`ham-hub users link-oidc`) or deploy once with `HAM_OIDC_CLAIM_EXISTING_USERS=true`.
   Note: with OIDC configured, `auto_provision_users` now defaults to **false** — Mundus will not
   auto-create users on first sign-in (OIDC bearer, browser login, or trusted proxy while it
   remains). Set `HAM_AUTO_PROVISION_USERS=true` only if that is wanted.
3. Backup Mundus DB, deploy via deployd, verify UI login, native bearer probe, bridge approval,
   confirm or roll back.

## Deviations

Phase 1 (native OIDC port):
- **Bridge credentials in OIDC mode.** The native branch sent every `Authorization` header on a
  user route to `resolve_oidc_auth`, so a misrouted `hba_`/`hbr_`/`hbf_` got the generic 401
  "invalid OIDC access token". `resolve_auth` now keeps today's explicit 403 "bridge token cannot
  call user APIs" for those shapes before OIDC resolution (matches "bridge-shaped tokens rejected
  as today" in Request resolution). `hut_` stays rejected by OIDC resolution (401) as on the
  native branch; phase 3 gives it the dedicated message.
- **API scope is configuration.** The native branch hard-coded the `heimdall.api` scope; it is now
  `oidc_api_scope` (required when OIDC is enabled). Bearer validation fails closed (`stage=config`)
  if issuer, audience, scope, JWKS or UserInfo URL is empty.
- **`oidc_mode` = issuer configured.** `HAM_AUTH_MODE` is gone; `Auth_Service.oidc_mode` is set
  iff `oidc_issuer` is non-empty (`app.oidc_configured`). `app.validate_oidc_config` runs in
  `main` and `build_graph`: OIDC settings without an issuer, or an issuer without JWKS/UserInfo/
  audience/scope, or a non-https provider endpoint, is a startup error. The web-client keys
  (`authorize/token/end_session/web_client_id/web_client_secret_file/redirect_uri`) are accepted
  now and only URL-checked; phase 2 enforces them.
- **Migration constant renamed** `MIGRATION_115_OIDC_IDENTITIES` → `MIGRATION_NATIVE_001_OIDC_IDENTITIES`
  (same file, same alias logic). `native_001_oidc_identities.sql` is ordered after
  `133_extension_version_sync_0_4_46.sql`.
- **`multi_question.answer_questions`** (not touched on the native branch) also accepts `.OIDC`,
  like every other user-only check. `tool_stream_handler` was left as on the native branch
  (no OIDC: its live re-authorization, `live_user_authorized`, has no OIDC notion yet) — revisit
  with sessions in phase 2/3.
- Skipped from the native diff as unrelated: `bridge_handlers.odin` (search-v2 relay parsing),
  `provider_extension_handlers_test.odin` (catalog min-version fixture), task-chain search tests,
  `tests/*search*`, `native-integration.json`, `docs/heimdall-native-oidc.md` (phase 5).

Phase 1 review follow-up:
- JWKS is a shared, parsed, mutex-protected cache (refresh after 10 min, usable up to 60 min while a
  refresh is suppressed/failing). Signatures are verified against it before any network call; a
  refresh (TTL or unknown `kid`) is single-flight and at most once per 60 s; suppressed/failed →
  reject with no network call. Outbound OIDC fetches (JWKS + UserInfo) are capped at 8 concurrent;
  excess fails closed immediately. The per-request JWK/token "shape" log lines from the native
  branch were dropped (one `oidc_jwks_refreshed keys=N` line per refresh remains).
- 60 s clock leeway on `exp`/`nbf`; `iat` may not be more than 60 s in the future. The token cache
  entry still expires at `min(now+30 s, exp+leeway)`.
- A set `HAM_AUTH_MODE` (any value, even empty) refuses startup and names the `HAM_OIDC_*` keys.
- v1 device proofs keep `NONCE_DEVICE_QUOTA = 64`; v2 uses a separate bucket with 4096.
- Identity resolution reads first; `BEGIN IMMEDIATE` only to create the first link (the user_id is
  not additionally cached in the 30 s token entry — the read is a single indexed lookup).
- **Search relay ported after all.** Main's UI (`src/ui/utils/taskChainSearch.ts`) and bridge
  (`src/bridge/task_chain_search_rpc.odin`) speak `search:v2:e<epoch>:…` envelopes, but main's hub
  relay (`task_chain_search_relay_handler`) still required the `search:v1:` prefix, so relayed
  task-chain search was rejected as "invalid search envelope" on main/v0.4.46. The native lineage
  fixed this in e46e604a (present in a16f0142 and repair/native-v0445). Ported that change
  (`bridge_handlers.odin` + `task_chain_search_relay_test.odin`) only.

Carried over to later phases (from the phase 1 review):
- (7) Long-lived streams under OIDC: WebSocket tickets are refused for OIDC and
  `live_user_authorized` has no OIDC/Session notion; streams must be bounded by token/session expiry
  (phase 2 sessions: re-check `session_id` validity; OIDC bearer streams: close at token `exp`).
- `tool_stream_handler` still excludes OIDC (see above) — fold into `is_user_auth` + the stream
  revalidation above in phase 2/3.
- Remaining informational review notes (log redaction review of provider responses, metrics labels
  `oidc`/`session`, the `ham-hub tokens` OIDC guard only seeing env) are handled in phases 3/5.

Phase 2 (browser sessions):
- **Config.** New: `session_ttl_hours` / `HAM_SESSION_TTL_HOURS` / `--session-ttl-hours` (default 168)
  and `session_idle_hours` / `HAM_SESSION_IDLE_HOURS` / `--session-idle-hours` (default 24, capped
  at the TTL). Browser login is enabled iff `oidc_issuer` + `oidc_authorize_url` + `oidc_token_url`
  + `oidc_web_client_id` are set (`app.web_login_configured`); any web key without the rest, or
  without `ui_origin` (the CSRF origin), is a startup error. `oidc_web_client_id` must be set
  explicitly: the Hub has no other way to learn the provider's client id (the native app's client id
  is not Hub config) — for Mundus it is the `heimdall-native` provider's client id.
  `oidc_redirect_uri` defaults to `<ui_origin>/api/v1/auth/callback` and must be https (localhost
  http allowed for dev). The client secret file is read once at startup; unreadable/empty → error.
- **Session store.** Migration `134_user_sessions.sql` (registered after `native_001_…`), times as
  integer Unix ms rather than text. Session id: 32 random bytes (base64url) from the OS CSPRNG;
  only `sha256_hex` is stored. Login state: 32-byte state, 32-byte nonce, 48-byte PKCE verifier
  (64 chars); keyed by `sha256_hex(state)`, 10 min TTL, consumed with `DELETE … RETURNING` before any
  other check (single use even on failure). The login cookie's value is the state itself and must
  equal the query `state` (constant-time).
- **Cookies.** `__Host-heimdall_session` (Path=/, Secure, HttpOnly, SameSite=Lax, Max-Age = TTL) and
  `__Host-heimdall_login` (same, Max-Age=600, cleared on every callback outcome). A cookie name that
  appears more than once in the request is treated as absent.
- **Resolution order** (`resolve_auth`, both modes): query/body token rejection → `Authorization`
  (OIDC mode: bridge 403, else OIDC + device gate; legacy: bridge 403, `hut_`) → session cookie →
  trusted proxy. An invalid/expired session cookie falls through to trusted proxy (still present
  until phase 3) and thus to 401 without proxy identity.
- **Auth kinds.** `.Session` added; `contracts.is_user_auth` (Session/OIDC/User_Token/Trusted_Proxy)
  and `contracts.is_interactive_browser_auth` (Session/Trusted_Proxy) replace every explicit kind
  list. `require_interactive_user` = interactive browser OR OIDC (native app, as before); billing's
  Origin check applies to interactive browser principals. Device approval/pairing stays "any user"
  (it accepted user tokens before, so it was never interactive-only). `tool_stream_handler` now
  accepts any user principal.
- **CSRF.** No middleware change was needed: `csrf_decide` already runs for every non-preview
  request in `handle_client` and refuses cookie-bearing state-changing requests unless
  `Sec-Fetch-Site: same-origin` or `Origin == ui_origin`, and cookie-bearing WebSocket upgrades
  unless `Origin == ui_origin`. What was missing was the guarantee that `ui_origin` is set — browser
  login now requires it. Tests cover cross-origin, same-site and metadata-less cookie POSTs and
  cookie upgrades.
- **WS tickets.** Session principals get user WebSocket tickets (the UI depends on them); a ticket
  carries kind, `session_id` and expiry so the stream it opens keeps the session's revalidation.
  OIDC bearer principals still get none.
- **Streams (item 7).** `live_user_authorized` now checks Session (row exists and is within
  absolute/idle expiry) and OIDC (`now < expires_ms`, the token exp + leeway carried on the
  context). A `Stream_Auth_Guard` re-checks every 30 s on the user WS, shell PTY and agent PTY read
  loops (the tool stream already re-checked via `live_user_authorized`), and enforces the hard
  `expires_ms` on every frame. Gap: the check runs when the client sends a frame (heartbeats every
  ~25 s; idle sockets time out at 120 s), so logout ends a stream within roughly 30-60 s, not
  instantly.
- **Preview isolation.** The preview origin still authenticates only via trusted proxy (never the
  session cookie); `__Host-heimdall_*` (and `heimdall_*`) cookies are stripped from anything
  forwarded upstream, alongside the existing `authentik_*` stripping. NOTE for phase 3: deleting
  trusted proxy leaves the dedicated preview origin with no auth path — it needs its own design
  (e.g. a short-lived preview ticket minted by a Session principal).
- **Callback outcomes.** Protocol/validation failures → `302 /?auth_error=1`; identity-policy
  refusals (unlinked / not provisioned / disabled / link conflict) → `302 /?auth_error=forbidden`
  so the UI can say "ask the operator to link your account". Logs carry only
  `oidc_login_rejected stage=<stage>`; provider error text and token-endpoint error bodies are never
  echoed or logged. Token exchange uses the bounded outbound path (same 8-slot cap), https only,
  `client_id` always in the form and HTTP Basic (form-encoded id/secret) only when a secret is set.
- **ID token.** RS256 via the shared JWKS cache, `iss == oidc_issuer`, `aud` contains the web
  client id (`azp` must equal it when present or when several audiences are listed), exp/nbf/iat
  with the 60 s leeway (iat required), nonce (constant-time). Identity comes from the ID token
  claims (no UserInfo call) and goes through the same link/claim/provision policy.
- **Logout.** `POST /api/v1/auth/logout` always 200: deletes the session row, expires the cookie and
  returns `{logout_url}` = end-session URL with `post_logout_redirect_uri=<ui_origin>/` and
  `id_token_hint` (when stored), else `/`. `GET /api/v1/me/logout-url` returns the end-session URL
  (no hint). `GET /api/v1/auth/config` adds `mode` (`oidc`/`trusted_proxy`) and `logout`.
- **Reaper.** Every sweep purges expired sessions, login states and `vault_request_nonces`; the
  session store is wired even without browser login so v2 nonces are always purged.
- **Tests.** ID tokens are minted at test time with a new TEST-ONLY RSA key
  (`testdata/oidc_rs256_signing.json`, generator alongside): the existing fixture's private key was
  discarded, and the nonce/aud/exp must vary per test.

Availability follow-up (after phase 1 approval):
- Outbound-cap refusals map to `Rate_Limited` (429) and provider transport failures (JWKS/UserInfo
  unreachable, no usable key set) to `Provider_Unavailable` (503) — never 401, which would make the
  native app drop its session. Forged/invalid tokens stay 401.
- UserInfo is single-flight per token hash: concurrent first uses of a new token wait for the
  leader, which publishes its outcome only after caching the identity.
- JWKS has a reserved outbound slot (general requests may use 7 of 8). A refresh refused by the cap
  is not counted against the 60 s window. A request that meets an in-flight refresh waits for it
  (bounded by the 5 s fetch timeout) and re-runs its key lookup once.
- `ham-hub users link-oidc` refuses inactive users.

Phase 2 review follow-up:
- No commit on this branch is to be tagged before phase 3 lands: phases 2 and 3 are only safe
  together (phase 2 still lets an invalid session cookie fall through to trusted-proxy identity).
- UserInfo 401/403 (and other 4xx) → 401 re-authenticate; only no response, 5xx or a provider 429
  → 503. The injectable fetch now returns the HTTP status.
- `GET /api/v1/auth/login` is limited to 20 starts per client IP per minute (client IP via the
  forwarded-for resolver and its trusted CIDRs) and refused while 10 000 unexpired login states
  exist; both answer 429 and create no row.
- `return_to` that is still percent-encoded after the last decode pass is refused.
- WS tickets are re-validated when consumed (a ticket minted before logout is dead); the LSP stream
  also runs the stream auth guard.
- `ham-hub users unlink-oidc` ends the user's sessions; new `users logout --user <id>` and
  `users disable|enable --user <id>` (disable also ends sessions). There was no other disable path.
- Redirect URI / `ui_origin`: https, or http only when the host is exactly `localhost`,
  `127.0.0.1` or `[::1]`.
- **Migration number:** `134_user_sessions.sql` must be renumbered if `main` gains its own 134
  before this branch merges (and its registry/fixture references updated).

Phase 3 (delete trusted proxy + `hut_`, preview-origin auth):
- **Auth kinds.** `Trusted_Proxy` and `User_Token` are gone, and so is `Auth_Context.user_token_id`.
  New `Internal_User` replaces the in-process "hub acting for the owner" contexts that used to be
  built with `.User_Token` (reaper, card/action follow-ups, matcher, title nudges). It is never
  resolved from a request. `is_user_auth` = Session | OIDC | Internal_User;
  `is_interactive_browser_auth` = Session.
- **Resolution.** `resolve_auth` = query/body-token 401 → Authorization: bridge 403, `hut_` 401
  "Heimdall user tokens are no longer supported; sign in with OIDC", else OIDC → session cookie →
  401. No fallthrough: an invalid session cookie is a 401.
- **Config.** The hub refuses to start unless OIDC bearer AND browser login are configured
  (`app.require_oidc_config`). `--trusted-proxy-cidr`, `--login-url`, `--logout-url` abort startup
  with a message. The XFF CIDR list (client-IP resolution only) is now
  `forwarded_for_trusted_cidrs` / `--forwarded-for-trusted-cidr` (default `127.0.0.1/32`). The
  username/display-name/email header settings are deleted. Dev mode:
  `HAM_OIDC_ALLOW_INSECURE_LOCALHOST=1` / `--oidc-allow-insecure-localhost` is the only way to use
  http:// OIDC endpoints, `ui_origin` or redirect URI, and only for an exact loopback host; startup
  prints a warning. There is no other bypass.
- **User tokens.** Deleted: issue/verify/list/revoke, `/api/v1/me/tokens*`, `ham-hub tokens`
  (now exits with a removal message), `users create` token output, `domain.User_API_Token` and the
  repository procs. Migration `135_clear_user_api_tokens.sql` empties the table (see the phase 3
  review follow-up: the table itself is kept for rollback safety). Device authorization: the user-token grant kind became `Grant_Kind.Unsupported` (the zero
  value); authorize without `bridge_public_key` is refused; the user token minter seam was removed.
  Bridge enrollment/approval is unchanged and is approved by a session (or OIDC) user. The legacy
  `/api/v1/device` HTML page redirects a browser without a session to the OIDC login.
- **ham-ctl.** A `hut_` user token makes ham-ctl print a clear "user tokens were removed; user
  mode is not available" message instead of failing against the hub. Agent mode is unaffected.
- **Metrics.** `heimdall_auth_failures_total{kind}` kinds: session, oidc, bridge_token,
  instance_token, missing, other (`hut_` and query/body credentials → other).
- **Preview origin (as built).** Preview tickets and preview sessions are kept in hub process
  memory (`Preview_Auth_Store`), not in SQLite: tickets live 60 s, and a preview session ends when
  its parent session does (checked at most every 15 s, and immediately on logout through
  `web_logout`). So no migration is needed, and after a hub restart the next preview navigation
  just bounces through the start route again. Flow:
  `<preview>/p/<sid>/...` without `__Host-heimdall_preview` → for a navigation, 302 to
  `<ui_origin>/api/v1/preview-auth/start?session=<sid>&return_to=<path>`; for anything else, 401.
  The start route needs the Hub session (otherwise it sends the browser through
  `/api/v1/auth/login?return_to=<start URL>`). It checks that the user owns `<sid>` and that
  `return_to` is a safe path under `/p/<sid>/`, mints a 32-byte ticket (stored hashed; single use;
  60 s; bound to user + parent session + sid) and 302s to
  `<preview>/__heimdall/preview-auth?ticket=…`. That endpoint is handled by the hub before any
  proxying; it sets `__Host-heimdall_preview` (Path=/, Secure, HttpOnly, SameSite=Lax, Max-Age =
  the parent's remaining lifetime) and 302s to `return_to`. On the preview host only that cookie
  authenticates: never `Authorization` (the previewed app owns it) and never the hub session
  cookie. All `__Host-heimdall_*` cookies are stripped before forwarding.
  **Deviation:** the start route is a GET, not a CSRF-checked POST. This keeps direct preview links
  (and the UI's existing `preview_url` links/iframes) working with no UI change. It is equally
  safe: the ticket only ever travels in a redirect to the hub-handled preview sign-in endpoint, it
  is single use, and it grants access only to a preview the signed-in user already owns. A forced
  navigation can at most sign the victim into their own preview.
  Limitation (same as with Authentik before): the preview cookie is host-wide, so a previewed app
  can make credentialed requests to that user's other `/p/<sid>/` previews. It can never read the
  cookie, and never reach hub APIs (CSRF Origin check; CORS without credentials).
- `ham-hub users unlink-oidc/logout/disable` run in a separate process, so they cannot drop the
  server's in-memory preview sessions directly. They delete the parent session rows, and preview
  sessions die at their next parent re-check (≤ 15 s).

Phase 4 (UI):
- `src/ui/auth/oidcSession.ts` holds the pure helpers, with unit tests in `tests/ui_oidc_session_test.ts`:
  - The sign-in link is `/api/v1/auth/login?return_to=<path+search+hash>`. `auth_error` is
    stripped from it, and protocol-relative paths are refused.
  - `auth_error` is read and turned into a message.
  - Loop protection: at most one automatic redirect per 30 s, stored in `sessionStorage`. There
    is never an automatic redirect after a failed sign-in.
  - Logout POSTs `/api/v1/auth/logout` and the browser then follows `logout_url`.
- `AppShell`:
  - The `login_url`/`logout_url` config fields, meta tags and the `/auth/config` fetch are
    removed.
  - A 401 from a user API (vault/device routes excluded) shows the sign-in landing.
  - A 429/503 from `/api/v1/me` shows "Sign-in provider unavailable — Retrying…" and re-checks
    every 5 s without redirecting.
  - `?auth_error=1` shows "Sign-in did not complete". `?auth_error=forbidden` shows "Your account
    isn't linked to a Heimdall user; ask the operator to run ham-hub users link-oidc".
  - The logout control is now a button that POSTs logout.
- The token-management UI (`UserTokensPanel`, the `/me/tokens` endpoints, the settings tab and
  route) is removed. Trusted-proxy wording is removed from `src/ui`.
- The WebSocket ticket flow (`POST /api/v1/me/ws-ticket` with the cookie, same origin) is
  unchanged and works for Session principals. The user WS opens with the cookie, and the Origin is
  checked.
- Electron (out of scope): its sign-in screen now says that desktop sign-in is unavailable on an
  OIDC-only hub (TODO(oidc)). No other Electron behaviour was changed.
- Vite dev: `vite.config.js` proxies `/api/v1` to the dev proxy / hub, which uses
  `tools/mock-oidc`, and never fakes identity (done with the phase 3 tooling).
- `scripts/oidc-smoke/smoke.sh` is a browser-less end-to-end check: mock OIDC + hub + a static
  front (like Caddy) serving `dist/`. It runs login → callback (cookie attributes) → `/me` and the
  UI's first calls → ws-ticket → CSRF refusal → logout → 401.

Phase 3 review follow-up:
- **Rollback safety:** migration 135 now runs `DELETE FROM user_api_tokens;` and keeps the
  table. Binaries from the deployed native-v0445 lineage run `upgrade_user_api_tokens_schema`
  (an `ALTER TABLE user_api_tokens …`) after every migration pass, so a dropped table would
  crash-loop on rollback. Emptying it also kills any `hut_` token if an old binary returns.
  **TODO (later release, once rollback to pre-OIDC binaries is no longer possible):** drop
  `user_api_tokens`, its trigger and its index. The new code tolerates the table being present
  or absent.
- **Login state is stateless:** an unauthenticated `/auth/login` creates no row. State, nonce,
  PKCE verifier, `return_to` and expiry are sealed into `__Host-heimdall_login` with
  XChaCha20-Poly1305 (`core:crypto/chacha20poly1305`) under a per-process random key; AAD is
  `heimdall-login-v1`.
  - The callback opens the cookie and requires query `state` == sealed state (constant time).
  - Each state is single use: hashes of consumed states are kept in memory until they expire,
    bounded at 16 384 entries with oldest-first eviction.
  - A hub restart invalidates in-flight logins.
  - `oidc_login_states` was removed from the (unreleased) migration 134, together with every
    repository method that used it.
  - The per-IP limit stays (20 per minute). When the per-IP window map is full it evicts the
    oldest windows instead of refusing.
- **Client IP:** `resolve_client_ip`, which device-auth shares, now takes the **right-most**
  X-Forwarded-For hop that is not inside a trusted CIDR, not the first hop. That matches nginx
  `$proxy_add_x_forwarded_for` behind a Caddy that trusts 127.0.0.1. A client-supplied left part
  can no longer choose the IP.
- **Preview handoff is bound to the browser:**
  - A preview-host bounce sets `__Host-heimdall_preview_bind` (random; HttpOnly, Secure,
    SameSite=Lax, host-only, 300 s) and passes `bind=sha256(value)` to the start route.
  - The ticket stores the bind hash. Redeem requires the matching bind cookie and clears it.
  - A start request without `bind` first goes to `<preview>/__heimdall/preview-bind`, which sets
    the cookie and comes back, so direct links still work.
  - A navigation with a valid preview cookie for a session the user doesn't own is re-routed
    through start instead of getting a 404.
  - Normal bounces are no longer counted as auth failures.
- **Preview WebSockets** (HMR) run the stream auth guard; they close (`auth_revoked`) once the
  user session behind them is logged out or expires.
- **Per-parent cap:** at most 32 preview sessions per parent session; the oldest is replaced.

Phase 5 (docs + verification):
- `docs/auth-oidc.md` covers the model, every config key, the session/cookie/preview model,
  Authentik setup (Mundus example), the operator CLI, migrations/rollback and threat notes.
  `SECURITY.md` and `SELF_HOSTING.md` no longer describe forward-auth. `SELF_HOSTING.md` §1.10 is
  the upgrade path from trusted-proxy auth. The preview edge must forward `/__heimdall/` as well
  as `/p/`.
- Pre-existing, unrelated: `nix build .#ham-bootstrap-golden-test` fails to link (`-lsqlite3`
  missing in its mkOdinPackage). It fails identically at 6ce3e02f.

## Post-cutover follow-ups

Done on `feat/oidc-followups`:
- [x] **Per-flow preview bind cookie** `__Host-heimdall_preview_bind_<id>`. The 8-character id
  is carried as `bind_id` through start and the ticket, and redeem reads and clears only its own
  cookie (Max-Age 300). Concurrent previews no longer overwrite each other's bind cookie.
- [x] **Hub-minted bind value**: `<random>.<HMAC-SHA256(hub process key,
  "heimdall-preview-bind|<id>|<random>")[:16]>`. Redeem refuses a value whose tag does not
  verify, so a non-HttpOnly cookie planted by previewed script cannot be redeemed against.
- [x] **Bounce hop counter**: `hop` travels through start and the ticket, and redeem returns to
  `return_to?__heimdall_hop=N`. The parameter is stripped before anything is forwarded to the
  app. More than 3 consecutive bounces end in a clear 403 explaining that the browser refuses
  the preview cookie.
- [x] **UI**: `currentReturnTo` falls back to `/` whenever the hub's `safe_return_to` would
  refuse the path (`isSafeReturnTo` mirrors it). `postLogout` only follows `https:` URLs or
  single-`/` paths (`safeLogoutTarget`); anything else goes to `/`.
- [x] **Docs**: `docs/auth-oidc.md` explains the right-most untrusted X-Forwarded-For rule and
  gives the Cloudflare `CF-Connecting-IP` nginx example.

Review nice-to-haves (also done):
- [x] The bind value carries its mint time under the MAC (`<random>.<ts>.<tag>`), and the 300 s
  window is enforced server-side.
- [x] Sub-keys derived from the process key: `HMAC(key, "heimdall-login-seal-v1")` for the
  login AEAD and `HMAC(key, "heimdall-preview-bind-v1")` for the bind tag.
- [x] Cookie-bomb cap: at most 16 bind cookies, and beyond that only the oldest (by the mint
  time in the value) are expired. A redeem with a missing, stale or foreign bind cookie, or an
  expired ticket, re-bounces within the hop limit instead of returning 403. Without this, every
  pane bouncing at once after a hub restart would kill each other's flows.
- [x] `__heimdall_hop` is appended only from hop 2 on. Between handoffs the count lives in a
  30 s `__Host-heimdall_preview_hop` cookie, so the normal path keeps the URL clean while loops
  are still caught.
- [x] The residual risk (script on the victim's own preview origin planting a harvested bind
  value) is documented and accepted.

Remaining carry-overs:
- **Drop `user_api_tokens`** in a later release, once rolling back to pre-OIDC binaries is no
  longer possible. Migration 135 only empties it.
- **Electron and ham-ctl OIDC sign-in.** Both currently say that user tokens were removed.
- **Migration numbering** before each merge to `main`: there is no new migration on this branch.
