# Separate preview origin — design (audit item 1)

Task: `task_18dd3f9c0087b9f7` (T6) · Chain: Preview tunnel hardening (`chain_18dd3ba73ff31c0b`)
Inputs: `docs/audits/preview_origin_and_backend_audit.md` (§4.1, §6 item 1), T0 spike `task_18dd3ebb9922580a`.
Status: **DRAFT v2.1 (2026-10-11), auth via Authentik.** User decisions: one **single preview origin** set by a flag (`--preview-origin https://heimdall-preview.mundus.in`), same-site with the hub, plus a **CSRF guard**. The per-preview-subdomain variant (v1) is kept in §7 as a future option.

---

## 0. Why (evidence)

- **Live in T0 (iOS Safari, prod hub):** JS inside the preview read the parent DOM and got
  `GET /api/v1/me` → 200. Previewed code therefore has the user's full hub privileges, which
  includes starting shells on every connected bridge.
- **T0 NO-GO for the cheap fix:** without `allow-same-origin`, the frame's origin is `null`. Module
  scripts, same-path `fetch` and `localStorage` all fail, so every modern SPA build breaks.
- **The fix:** serve previews from an origin that is **not the hub's** (the githubusercontent pattern).
  v2 uses a single preview origin for all previews; per-preview subdomains (§7) are a later upgrade.

## 1. New findings from this design pass (code facts)

| # | Fact | Where | Consequence |
|---|---|---|---|
| F1 | The hub reads `Authorization: Bearer` first. A non-`hut_` bearer gets **401**, before the tunnel. | `src/hub/service/auth/auth_service.odin:294-305` | Bearer-auth apps can **never** work on the shared origin, even after T2. The preview host must not use `resolve_auth`. |
| F2 | The hub answers **every** `OPTIONS` with 204 before routing. | `src/hub/transport/http/server.odin:81-84` | CORS preflights from the previewed app never reach the upstream. The preview host must forward `OPTIONS`. |
| F3 | The hub has **no CSRF, Origin or `Sec-Fetch-Site` check** on its API. | grep over `src/hub` | If preview hosts are **same-site** with the hub (subdomains of the same registrable domain), previewed JS can send credentialed same-site requests to the hub. SameSite cookies do not stop that. |
| F4 | Routing is path-only; there is no Host-based dispatch. | `router.odin:112`, `server.odin:95-105` | On a preview host, `/api/v1/me` would be routed to the **hub API**. Host dispatch must run **before** every router call. |
| F5 | Hub auth = trusted-proxy identity headers (`X-authentik-*` from `trusted_proxy_cidrs`) **or** a `hut_` bearer. | `auth_service.odin:287-327` | Authentik must **not** front preview hosts, and the hub must ignore identity headers on preview hosts. |
| F6 | The sidebar is an iframe embedded by the hub page. | `PreviewSidebar.tsx:257-265` | A preview cookie would be third-party if the preview origin were a **different site**. With `heimdall-preview.mundus.in` it is **same-site**, so a host-only `SameSite=Lax` cookie is first-party in the iframe, including on iOS Safari. |

## 2. Design (v2: single preview origin)

### 2.1 Configuration (flags)
| Flag / config key | Example | Meaning |
|---|---|---|
| `--ui-origin` / `ui_origin` (**exists**, `src/hub/main.odin:233`, `config_bind.odin:30`) | `https://heimdall.mundus.in` | The hub UI origin. Now also the **only accepted `Origin`** for mutating hub requests (CSRF guard). |
| `--preview-origin` / `preview_origin` (**new**) | `https://heimdall-preview.mundus.in` | Origin that serves previews. **Empty = feature off**: today's `/api/v1/preview/<sid>/` behaviour is unchanged. Validation at startup: it must be `https://`, have no path, and differ from `ui_origin` (fatal error otherwise). |
| `--preview-legacy-path` / `preview_legacy_path` (**new**, default `true` for one release, then `false`) | `false` | Whether the vulnerable same-origin `/api/v1/preview/**` route stays available once `preview_origin` is set. |

### 2.2 Preview URL and how it is presented
- Canonical URL: **`<preview_origin>/p/<sid>/`**.
- The hub computes `preview_url` and returns it on **every shell-session JSON** (REST + `ham-ctl shell
  serve/run/list/show` output) whenever `server_port > 0`. Agents and the UI never build preview URLs
  themselves. With `preview_origin` empty, `preview_url` = `<ui_origin>/api/v1/preview/<sid>/`.
- Opening it directly (new tab, a link from an agent) works: Authentik signs the user in if needed.
- **T7 skill** (`heimdall-preview-setup`) instructs agents to present `preview_url` exactly as returned.

### 2.3 Infra (ops, `nix-homelab-config`)
- One DNS record `heimdall-preview.mundus.in` pointing at the existing reverse proxy, and a normal cert
  (HTTP-01; no wildcard).
- A proxy vhost to the hub **behind Authentik forward-auth**, the same way as the hub vhost. The proxy must
  **set (override)** `X-authentik-*` from the auth response and never pass client-supplied values
  (the standard `auth_request_set` + `proxy_set_header` pattern). Preserve `Host`, allow WS upgrade,
  disable buffering.
- Authentik provider for the preview host: a **separate proxy provider in single-application mode**
  (a host-only cookie on `heimdall-preview.mundus.in`), **NOT domain-level** forward auth. Then the cookie
  the preview origin holds is a different credential from the hub's: if it ever leaked, it would open
  previews only, never the hub. Use implicit consent so the redirect dance stays silent in the iframe.
  **Disable "Intercept header authentication"** so an app's own `Authorization: Bearer/Basic` is not
  consumed by Authentik.
- **Cookie-tossing check:** previewed JS can set `Domain=mundus.in` cookies. Verify Authentik's session
  cookie is `HttpOnly` and tolerate collisions (a residual risk; worst case a forced logout).

### 2.4 Owner-only access (decided 2026-10-11: **Authentik only**; no hub-issued tickets or cookies, not even as a fallback)
1. Every request to `<preview_origin>/**` passes Authentik forward-auth. Unauthenticated users never reach
   the hub.
2. The hub's preview-origin handler authenticates with **trusted-proxy identity only**: a new
   `resolve_trusted_proxy_auth` that reuses the second half of `resolve_auth` (auth_service.odin:306-326)
   and **skips the Bearer branch** (F1), so an app's `Authorization` header is never treated as a hub
   credential.
3. Per request: `session(<sid>).owner_user_id == authenticated user`, session running, port > 0, otherwise
   403 or 404.
4. Before forwarding upstream, strip `X-authentik-*` (T2 already does) and **strip Authentik's cookies**
   (`authentik_proxy_*`, `authentik_session`) from `Cookie`. The app's own cookies are forwarded.
5. **Iframe sign-in:** if the Authentik session has expired, the redirect chain ends on a login page that
   cannot render in the sidebar iframe (X-Frame-Options). UI fallback: "Sign in" opens `preview_url` in a
   new tab. When the user is already signed in, the forward-auth redirects complete invisibly (same-site,
   first-party).
6. Logout and expiry follow Authentik automatically.

| Attacker has | Result |
|---|---|
| A different Heimdall account | Passes Authentik, then the hub owner check → 403 |
| The preview URL, no account | Authentik login → blocked |
| A spoofed `X-authentik-username` | Overridden by the proxy; the hub only trusts `trusted_proxy_cidrs` |
| An app `Authorization` header | Not intercepted (Authentik setting) and ignored for hub auth (step 2) |
| JS in one of the owner's other previews | ⚠️ Same preview origin: can request the owner's other previews (accepted v2 trade-off, §7) |

*No hub-side auth fallback (user decision).* If silent re-auth in the iOS Safari iframe misbehaves, the
supported path is the "Sign in" / open-in-new-tab button, and fixes go into Authentik/proxy config.

### 2.4b Can previewed code steal or use the main-account cookie?
| Path | Defence | Result |
|---|---|---|
| Preview **JS reads** `document.cookie` | Authentik cookies are `HttpOnly` (**verify in P6** with the Set-Cookie flags) | Not readable |
| Preview **server** receives the cookie | The hub strips `authentik_*` cookies and `X-authentik-*` before forwarding (REQ-PO-4) | Never sent upstream |
| The preview-origin cookie is replayed against the hub | A separate single-application provider means a **different, host-only cookie** | Worthless at `heimdall.mundus.in` |
| Preview JS **uses** the browser's hub cookie (same-site `fetch`/form to the hub, which the browser attaches automatically) | CORS (no `Access-Control-Allow-Origin`) blocks reading responses; the **CSRF guard** (§2.6) rejects every mutating request whose `Sec-Fetch-Site` ≠ `same-origin` or `Origin` ≠ `ui_origin`; hub `GET`s must stay side-effect free (**audit in P4**) | Blocked |
| Preview JS opens a **WebSocket** to the hub (`/api/v1/shells/*/stream`, etc.). WebSockets are **not** covered by CORS, and the cookie is attached | **WS handshake `Origin` check == `ui_origin`** in the CSRF guard (§2.6). This is the critical one: without it, previewed code could drive your shells. | Blocked |
| Preview JS calls Authentik's own API at `auth.mundus.in` | Authentik's Django CSRF protection, plus CORS for reads | Blocked |

### 2.5 Hub request path on the preview origin
1. **Host dispatch first** (F4): in `server.odin`, **before the `OPTIONS` short-circuit (F2) and before
   every router call**, a request whose `Host` equals the `preview_origin` host goes to
   `preview_origin_handler`. **Nothing** on the preview origin can reach hub routes, UI or static files.
2. Routes on the preview origin: `/__ham/enter`, `/__ham/health`, and `/p/<sid>/**` (tunneled). Everything
   else is 404.
3. Reuse the existing tunnel relay from `shell_session_preview_proxy_handler` with prefix `/p/<sid>`.
4. Request rebuild (T2 builder): `X-Forwarded-Prefix: /p/<sid>`, `X-Forwarded-Host: heimdall-preview.mundus.in`,
   `X-Forwarded-Proto: https`. **Forward `Cookie` minus `__Host-ham_pv`**: the app's cookies are already
   path-scoped to `/p/<sid>/` by T3, and the origin is isolated from the hub. Forward `Authorization` (F1 no
   longer applies) and `OPTIONS`. Keep stripping `X-authentik-*`.
5. Response (T3 filter, prefix `/p/<sid>`): keep the `Service-Worker-Allowed` strip, the Set-Cookie
   `Path=/p/<sid>/` and `Domain` drop, and the `Location` rewrite. Add `Referrer-Policy: same-origin` if absent.

### 2.6 CSRF guard on the hub (required: F3 + same-site preview origin)
Every hub route that is not `GET`/`HEAD`/`OPTIONS`: if `Sec-Fetch-Site` is present, it must be `same-origin`;
else, if `Origin` is present, it must equal `ui_origin`; else (non-browser clients such as `ham-ctl` with `hut_`
or bridge tokens) allow. **Every** raw/upgrade route (all WS streams: shells, LSP, events, the UI socket) checks `Origin == ui_origin` on the handshake, and **rejects a missing `Origin` when a cookie is present**, because WebSockets bypass CORS (cross-site WebSocket hijacking). Also audit that no hub `GET` route has side effects. **It
must ship before `preview_origin` is enabled in prod.**

### 2.7 UI
- `previewAccessUrl` (`src/ui/components/shells/shellModel.ts:481`) returns `session.preview_url`, which
  the sidebar uses directly as the iframe `src`. A "Sign in" button opens it in a new tab when Authentik needs a login.
- Iframe `sandbox` stays `allow-scripts allow-same-origin allow-forms allow-popups`. `allow-same-origin` now
  means the **preview** origin, not the hub's, so it is safe.
- URL bar / back button: cross-origin frames can't be read, so show the last path the user typed or
  navigated to via the bar. Optional later: a `postMessage` bridge.
- "Open in new tab" uses `preview_url`. It is safe.

## 3. Requirements
| REQ | Requirement |
|---|---|
| REQ-PO-1 | `--preview-origin` flag/config, startup validation, feature off when empty; `--preview-legacy-path`. |
| REQ-PO-2 | `preview_url` on all shell-session JSON and `ham-ctl shell` output, computed by the hub. |
| REQ-PO-3 | Host dispatch before the router and the OPTIONS short-circuit; the preview origin can never reach hub routes (test: `GET /api/v1/me` with the preview Host → 404, never hub JSON). |
| REQ-PO-4 | Preview origin behind Authentik; hub uses trusted-proxy identity only (no Bearer branch) + per-request owner check; strip Authentik cookies before forwarding. |
| REQ-PO-5 | Forward Cookie (minus Authentik cookies), Authorization and OPTIONS to the upstream; never forward `X-authentik-*`. |
| REQ-PO-6 | T2/T3 builder and filter parameterised by prefix `/p/<sid>`; `Referrer-Policy` default. |
| REQ-PO-7 | UI uses `preview_url`, with a new-tab sign-in fallback; legacy path behind the flag. |
| REQ-PO-8 | **Required** CSRF guard (§2.6) on all mutating hub routes and WS handshakes. |
| REQ-PO-9 | SELF_HOSTING.md: the preview origin DNS/cert/vhost (nginx + Caddy) and the Authentik host-only cookie check. |
| REQ-PO-10 | T7 skill documents `preview_url` presentation, the preview origin and its caveats. |

## 4. Task breakdown (created after LGTM)
| Task | Scope | Size | Depends on |
|---|---|---|---|
| P1 Config flags + validation + `preview_url` on session JSON and ham-ctl (REQ-PO-1, 2) | main.odin, config_bind.odin, shell session JSON, ctl | M | — |
| P2 Host dispatch + preview-origin handler reusing the relay; builder/filter prefix param (REQ-PO-3, 5, 6) | server.odin, shell_session_handlers.odin | L | P1, T3 |
| P3 `resolve_trusted_proxy_auth` + owner check + Authentik-cookie strip (REQ-PO-4) | auth_service.odin + preview handler | S | P1 |
| P4 CSRF guard (REQ-PO-8) | middleware.odin, server.odin, upgrade handlers | M | — |
| P5 UI: `preview_url` iframe, "Sign in" new-tab fallback, URL bar (REQ-PO-7) | shellModel.ts, PreviewSidebar.tsx | S | P1 |
| P6 Ops + docs: DNS, cert, vhost **behind Authentik** (header interception off); SELF_HOSTING.md (REQ-PO-9) | nix-homelab-config (user) + docs | S | — |
| P7 E2E on a prod-like stack (incl. iOS Safari iframe cookie check), enable the flag, deploy | — | S | all |

T7 (skill) depends on P1 (for `preview_url`) and documents both modes.

## 5. Risks
1. **CSRF guard regressions:** non-browser clients and WS handshakes must keep working. The guard allows a
   missing `Sec-Fetch-Site`/`Origin` (bearer clients). Test `ham-ctl`, bridge and UI flows.
2. **Previews share one origin (v2 trade-off):** one of the owner's previews can read the owner's other
   previews, and storage/service workers are shared. It cannot reach the hub. Upgrade path in §7.
3. **Cookie tossing onto `.mundus.in`:** residual; mitigated by a host-only Authentik cookie (P6 check).
4. **Path prefix stays:** dev-server/HMR caveats remain (the T7 skill documents them); §7 removes them.
5. **Authentik in the iframe:** the login page can't render inside it, so the new-tab fallback is required. Verify silent re-auth on iOS Safari in P7. If it fails, previews open in a new tab (no hub-side auth fallback, by decision).
6. **Authentik config drift:** if header interception is left ON, bearer-auth apps break at the proxy. Add it to the P6 checklist.

## 6. XSS: contain, not prevent
An XSS or malicious dependency in a previewed app still runs, but **in the preview origin**:
no hub DOM access, no readable hub API responses (no CORS), JSON POSTs to the hub fail preflight,
simple POSTs are rejected by the CSRF guard, and no service worker can sit over the hub UI. A compromise
of a preview stays inside the owner's previews.

## 7. Future: per-preview subdomains (v1 design, deferred)
`https://<random-label>.preview.mundus.in/` at path `/`, with wildcard DNS and a DNS-01 wildcard cert.
It isolates previews from each other and removes the path prefix. Auth: Authentik on the wildcard host.
