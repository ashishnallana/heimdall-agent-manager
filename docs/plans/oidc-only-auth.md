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
