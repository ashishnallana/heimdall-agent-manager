# Heimdall Preview — Origin, Routing & Backend/Frontend Requirements Audit

- **Date:** 2026-10-10
- **Task:** `task_18dd3bad06c9248a`
- **Scope:** the browser preview tunnel (`/api/v1/preview/<session_id>/**`) and the bridge-local
  reverse path (`http://127.0.0.1:<local_endpoint_port>/proxy/<session_id>/**`). Static code
  audit; nothing was changed.
- **Goal measured against:** a previewed web page should load reliably and be able to talk to
  (a) a backend running locally on **any** connected machine and (b) real remote APIs.

Legend: **[code]** = verified by reading the source line cited · **[infer]** = follows from the code
together with standard browser/framework behaviour, but was not exercised live.

---

## 1. How a preview request actually flows

```
Browser (hub UI, https://<hub>)                               Bridge host
  └─ <iframe src="/api/v1/preview/<sid>/<path>">                  │
        │  same origin as the hub, sends Authentik cookie         │
        ▼                                                         │
  Authentik / forward-auth proxy  ──►  Hub                        │
        shell_session_preview_proxy_handler                       │
        · require_auth + owner == caller + status=running + port>0│
        · strips "/api/v1/preview/<sid>"                          │
        · REBUILDS the request (header allowlist, Host rewrite)   │
        · tunnel_open / tunnel_data over the bridge WS  ─────────►│ bridge_hub_handle_tunnel_open
                                                                  │  · re-checks running + port
                                                                  │  · dial 127.0.0.1:<server_port> (IPv4 only)
        ◄──────────── raw upstream response bytes, unmodified ────┘
```

| Step | Location | Behaviour |
|---|---|---|
| Route | `src/hub/app/wiring.odin:671` | `ANY /api/v1/preview/**`, raw-socket upgrade route (streams, handles WS). |
| Auth | `src/hub/transport/http/shell_session_handlers.odin:309-341` | Normal user session auth; only the **session owner** gets through (403 for anyone else). Port comes from the session record, never from the request (SSRF fence). |
| Path | `shell_session_handlers.odin:402-406` | Prefix stripped; upstream sees `/<path>`. **Nothing tells the upstream what the prefix was.** |
| Request rebuild | `shell_session_handlers.odin:648-688` (`_preview_build_http_request`) | `Host: 127.0.0.1:<port>`; `Connection: close` (non-WS); only an **allowlist** of headers is forwarded (see §2). |
| Dial | `src/bridge/hub_runtime_client.odin:4712-4714` | `net.IP4_Loopback` only — no `::1`, no LAN address, no other host. |
| Response | `shell_session_handlers.odin:554` | Upstream bytes are written back verbatim. **No response header is added, removed or rewritten.** |
| UI | `src/ui/components/shells/PreviewSidebar.tsx:257-265` | `<iframe sandbox="allow-same-origin allow-scripts allow-forms allow-popups">`, same origin as the hub UI. |
| Reverse path | `src/bridge/local_proxy.odin`, `src/hub/transport/http/bridge_proxy_relay.odin:91` | A process on any bridge host can call `127.0.0.1:<local_endpoint_port>/proxy/<sid>/…` to reach another session of the **same owner** on any bridge. Uses the **same** `_preview_build_http_request`, so the same allowlist applies. No user auth (accepted trade, REQ-XM-5 pending). |

---

## 2. What the upstream (the previewed server) actually receives

**[code]** `_preview_build_http_request` forwards **only**:

`Accept`, `Accept-Encoding`, `Accept-Language`, `Content-Type`, `Content-Length`, `Cache-Control`,
`Range`, `If-None-Match`, `If-Modified-Since` — plus `Upgrade`, `Connection`, `Sec-WebSocket-*`
on a WebSocket upgrade.

It writes **`Host: 127.0.0.1:<server_port>`** itself.

Everything else is **dropped**, which notably includes:

| Dropped header | Who relies on it | Consequence |
|---|---|---|
| `Origin` | CORS middleware, CSRF origin checks, WS origin validators (Django Channels `AllowedHostsOriginValidator`, Socket.IO `cors.origin`, Phoenix `check_origin`) | Upstream sees **no Origin at all**. Lenient servers treat that as same-origin; strict ones reject it (WS 403, CSRF failure). |
| `Cookie` | Session auth (Django, Rails, Express-session, NextAuth, Laravel…) | **Cookie-session login can never work** — the upstream's own cookie is never sent back to it (see §4.3). |
| `Authorization` | Bearer/JWT APIs, Basic auth | **Token-auth APIs reached through the preview get 401.** |
| `X-CSRF-Token`, `X-CSRFToken`, `X-XSRF-TOKEN`, `X-Requested-With` | Django, Rails, Laravel, Angular | State-changing requests (POST/PUT/DELETE) fail CSRF checks. |
| Any custom `X-*` (`X-API-Key`, `Idempotency-Key`, `traceparent`, …) | App-defined | Silently missing. |
| `Referer`, `User-Agent` | Analytics, some CSRF checks (Django's HTTPS Referer check), UA sniffing | Missing. |
| `If-Match`, `If-Unmodified-Since`, `Content-Encoding` | Optimistic concurrency, compressed request bodies | Missing; a compressed request body arrives with no encoding header. |
| `X-Forwarded-Host/Proto/For/Prefix`, `Forwarded` | Every framework's "behind a proxy" support | **Never sent.** The upstream believes it is `http://127.0.0.1:<port>/` at the root. |

**Origin the upstream sees, per scenario:**

| Request originates from | Arrives at upstream with |
|---|---|
| Browser → hub preview path (iframe or new tab) | **No `Origin`**, `Host: 127.0.0.1:<port>`, no cookies, no auth, no forwarding headers |
| Browser → hub preview path, WebSocket | Same — `Origin` stripped even on upgrade |
| A process on any bridge host → `127.0.0.1:<lep>/proxy/<sid>/` | Same rebuilt request (shared builder) |
| Upstream's own server-side calls to a backend on its loopback (e.g. Vite `server.proxy`, Next rewrites) | Whatever that dev server sends — the hub is not involved |
| Browser **directly** → a real remote API (`https://api.example.com`) | `Origin: https://<hub-host>` (the hub origin, **not** `localhost:<port>`) |

---

## 3. Use-case matrix

| # | Scenario | Works today? | Why / what is needed |
|---|---|---|---|
| A | Static site / SPA **production build** with **relative** asset URLs (`base: './'`) | ✅ | Everything resolves under the prefix. This is the supported path (matches the existing project memory "serve the PROD build through the tunnel, never dev mode"). |
| B | SPA with **absolute** asset/API paths (`/assets/x.js`, `fetch('/api/…')`) | ❌ | The browser resolves them against the hub origin root → hits the hub, not the upstream. Needs a document-relative base (`VITE_API_BASE=.` pattern in `src/ui/api/apiBase.ts`) or a prefix-aware build. |
| C | **Dev servers** (Vite dev, Next dev, CRA, Angular `ng serve`) | ⚠️ mostly ❌ | They emit root-absolute module URLs (`/@vite/client`, `/_next/…`, `/src/main.tsx`) and an HMR WebSocket at a root path. Only works if you configure `base`/`basePath` to the exact `/api/v1/preview/<sid>/`, which changes per session. |
| D | Frontend calls a backend on the **same bridge host** via a **dev-server proxy** (`/api` → `localhost:8000` in Vite/Next config), with relative fetch (`./api/...`) | ✅ (with header caveats) | Browser → hub → bridge → dev server → backend over the bridge's loopback. Backend sees the dev server's request; the headers the browser sent were already stripped at the hub (§2). |
| E | Frontend calls `http://localhost:8000` **directly** from browser JS | ❌ | `localhost` resolves on the **viewer's** machine, not the bridge host. With the hub on https it is also mixed content (blocked). Works only by accident when the viewer is on the bridge host. |
| F | Frontend calls a backend that is **another preview session** (same or another bridge) via `/api/v1/preview/<other-sid>/…` | ✅ same-origin, ⚠️ fragile | Same origin, so **no CORS needed** and the user's cookie authenticates it. But the frontend must know the other session's id at runtime, and §2 header stripping applies. |
| G | Frontend's **server side** (SSR, BFF) on bridge A calls a backend on bridge B | ✅ via XM-4 | Call `http://127.0.0.1:<local_endpoint_port>/proxy/<sid-B>/…` from bridge A. Same owner only. Same header allowlist. |
| H | Browser JS calls a **real remote API** (`https://api.example.com`) | ✅ if that API's CORS allows the **hub origin** | `Origin: https://<hub-host>`. The API must list it in `Access-Control-Allow-Origin`; allowlisting `http://localhost:5173` is not enough. With credentials: `SameSite=None; Secure` cookies, `Access-Control-Allow-Credentials: true`, and still subject to the browser blocking third-party cookies. |
| I | **OAuth/OIDC** login (Google, GitHub, Auth0, Authentik) | ❌ in practice | The redirect URI would be `https://<hub>/api/v1/preview/<sid>/callback`, which changes with every session id, and the app builds it from `Host: 127.0.0.1:<port>` anyway (see §4.2). |
| J | **Cookie-session** login inside the previewed app | ❌ | `Cookie` is never forwarded (§4.3). |
| K | **Bearer-token** APIs through the preview path | ❌ | `Authorization` is dropped. |
| L | **SSE** / long-poll | ⚠️ | Streams fine, but `PREVIEW_IDLE_TIMEOUT = 120s` (`shell_session_handlers.odin:294`) kills a stream with no bytes for 2 min. Send heartbeats under 120 s. |
| M | **WebSocket** backend | ✅ / ⚠️ | Bidirectional relay (XM-2). Fails on servers that **require** an `Origin` header, or that need cookie/`Authorization` auth on the handshake. |
| N | Dev server bound to **`::1` only** (Node ≥17 resolving `localhost` → IPv6, Vite default `localhost`) | ❌ | Bridge dials IPv4 `127.0.0.1` only → `port_closed`. Bind `127.0.0.1` / `0.0.0.0` or pass `--host 127.0.0.1`. |
| O | Server bound to a **LAN IP only**, or running in a container/VM without a loopback port mapping | ❌ | Loopback-only dial. |
| P | Machine clients (curl from a laptop, mobile app, **inbound webhooks** from Stripe/GitHub) | ❌ | The hub sits behind Authentik forward auth and requires the owner's browser session. There is no public/unauthenticated preview URL. |
| Q | Sharing the preview link with another user | ❌ by design | Owner check → 403. |
| R | Upstream sends `X-Frame-Options: DENY` or `CSP frame-ancestors 'none'` | ❌ in sidebar | Relayed verbatim → the iframe is blocked (`SAMEORIGIN` is fine because hub and preview share an origin). Opening in a new tab still works. |

---

## 4. Findings

### 4.1 🔴 SECURITY — the previewed app runs with full hub privileges (same origin + permissive sandbox)

**[code]** The preview is served from the **hub's own origin** (`previewAccessUrl`,
`src/ui/components/shells/shellModel.ts:481`), and the iframe uses
`sandbox="allow-same-origin allow-scripts …"` (`PreviewSidebar.tsx:264`). Per the HTML spec,
`allow-scripts` + `allow-same-origin` on a same-origin document is no sandbox at all; the frame can even
remove its own sandbox attribute.

**[infer]** Any JavaScript served by the previewed server (the user's code, **any npm dependency**, an
untrusted repo the agent cloned) can:

- read/drive `window.parent` (the hub UI), its DOM, `localStorage` and IndexedDB;
- call **every** hub API with the user's Authentik cookie: create agents, start shells on **any**
  connected bridge, read vault content. That makes one malicious package a path to RCE across every
  connected machine;
- do all of the above even when opened in a new tab, because the origin is the same.

**[code + infer] Response headers are relayed unmodified**, which adds two persistence vectors:

- `Service-Worker-Allowed: /` on a script response lets the previewed page register a **service worker
  scoped to the whole hub origin**, which then intercepts the real hub UI persistently, even after the
  session is gone.
- `Set-Cookie` from the upstream lands on the hub origin with whatever `Path`/`Domain` it chooses, so it
  can shadow or collide with hub/Authentik cookies.

Note the knock-on: because preview and hub share an origin, the hub **cannot** safely start forwarding
`Cookie` to the upstream (that would hand the Authentik session cookie to the previewed server). The
stripping in §2 is correct *for a shared origin*, and that is exactly why cookie-auth apps can never
work under the current design.

### 4.2 🟠 Host rewrite without forwarding headers breaks redirects and absolute URLs

**[code]** `Host: 127.0.0.1:<port>`, no `X-Forwarded-*`, and the response is not rewritten.
**[infer]** Frameworks that build absolute URLs from the request (`redirect('/login')` turned into
`http://127.0.0.1:5173/login`, OAuth `redirect_uri`, password-reset links, `url_for(_external=True)`,
Next `basePath` detection) produce URLs that point at the **viewer's** loopback. A `Location: /login`
(root-absolute) escapes the prefix and lands on the hub SPA. Django `ALLOWED_HOSTS` and Vite
`server.allowedHosts` happen to pass because the Host is loopback, so this is the one upside.

### 4.3 🟠 Auth inside the previewed app is impossible (cookie and bearer)

**[code]** `Cookie` and `Authorization` are not in the allowlist. Cookie-session apps loop on login;
SPA + JWT apps get 401 on every API call that goes through the preview path. CSRF header tokens are
also dropped, so even unauthenticated POST forms in Django/Rails/Laravel fail.

**[infer]** Forwarding `Authorization` is low risk on its own (the browser only attaches it when page JS
sets it), but it must be verified that the Authentik forward-auth layer in front of the hub does not try
to interpret an `Authorization: Bearer/Basic` header as **its own** credential and reject the request
before it reaches the hub.

### 4.4 🟡 The path prefix forces per-app configuration

**[code]** Upstream sees `/`, the browser sees `/api/v1/preview/<sid>/`. **[infer]** Every app has to be
built prefix-agnostic (relative base) or prefix-aware (a runtime `base`/`basePath` equal to a per-session
value). Dev servers with HMR are the worst case. This is the single biggest source of "the preview is
blank" reports.

### 4.5 🟡 Loopback IPv4 only

**[code]** `hub_runtime_client.odin:4713`. Servers bound to `::1` (common default now) get `port_closed`
with no hint in the UI that IPv6 is the cause.

### 4.6 🟡 `Connection: close` on every request

**[code]** `shell_session_handlers.odin:661`. Each asset is a new `tunnel_open` + TCP dial on the bridge.
**[infer]** A dev-mode page loading hundreds of ES modules pays a hub↔bridge round trip plus a dial per
module. That is noticeable latency, though it is correct.

### 4.7 🟡 Idle timeout 120 s for non-WS streams

**[code]** `PREVIEW_IDLE_TIMEOUT`. SSE/long-poll endpoints need heartbeats under 120 s.

### 4.8 ℹ️ Not verified

- How the hub HTTP parser handles **chunked request bodies** (`Transfer-Encoding: chunked`, used by
  streaming `fetch` uploads) and its maximum buffered body size for this raw route. `Transfer-Encoding`
  is not in the allowlist, so a chunked body would need to be de-chunked by the hub and re-sent with a
  `Content-Length`. Worth a test.
- Whether Authentik/forward-auth adds headers or strips paths for `/api/v1/preview/**`.

---

## 5. What backends and frontends must do today (developer guidance)

### Frontend
1. **Build with a relative base** (`base: './'` in Vite, `homepage: "."` in CRA, `<base href="./">` in
   Angular) and use **document-relative** API paths (`fetch('api/x')` or `./api/x`, never `/api/x`).
2. **Serve the production build**, not the dev server (`vite build && vite preview --host 127.0.0.1`,
   `npx serve -s dist`).
3. Reach local backends **through your own server**: a dev-server proxy (`server.proxy`), Next rewrites,
   or a BFF. Never call `http://localhost:<port>` from browser JS.
4. For a backend on **another machine**: from server-side code use
   `http://127.0.0.1:<local_endpoint_port>/proxy/<sid>/…`. From browser code use
   `/api/v1/preview/<sid>/…`, with the session id injected at runtime.
5. For **remote APIs** called from the browser, expect `Origin: https://<hub-host>`.
6. Don't depend on cookies, `Authorization`, CSRF headers or custom headers reaching your server through
   the preview path.
7. Use hash routing (`#/route`), or make sure deep links resolve relative to the prefix; a hard refresh
   on `/api/v1/preview/<sid>/users/1` must be served by the upstream SPA fallback.

### Backend
1. **Bind `127.0.0.1`** (or `0.0.0.0`), not `::1` or a LAN IP. Declare the port on the session
   (`ham-ctl shell serve --port N`).
2. Accept requests with **no `Origin`** and `Host: 127.0.0.1:<port>`. Relax WS origin validators and
   CSRF origin checks in preview/dev mode.
3. Emit **relative** redirects (`Location: login`, not `/login` or `http://127.0.0.1:…/login`).
4. Don't send `X-Frame-Options: DENY` / `frame-ancestors 'none'` if you want the sidebar view.
5. For SSE/long-poll, send a heartbeat at least every 120 s.
6. **Real APIs called from a preview:** add `https://<hub-host>` to the CORS allowlist. For credentialed
   calls also set `Access-Control-Allow-Credentials: true` and `SameSite=None; Secure` cookies. For
   OAuth, register a redirect URI, which is impractical today because the URL contains the session id.

---

## 6. Recommendations for the platform

Ordered by impact. Items 1–2 are architectural; 3–7 are incremental and could ship independently.

| # | Recommendation | Fixes | Effort |
|---|---|---|---|
| 1 | **Give each preview its own origin**, e.g. `https://<sid>.preview.<hub-domain>` (wildcard DNS + wildcard TLS + forward-auth on the wildcard host), served at **path `/`**. Authenticate with a short-lived signed token issued by the hub and exchanged for a cookie **scoped to that preview host**. This is the Codespaces/Gitpod/StackBlitz model. | 4.1 (isolation from the hub and between previews), 4.4 (no prefix, so dev servers/HMR/absolute paths just work), 4.3 (Cookie/Authorization can then be forwarded safely), stable OAuth redirect URIs, simpler CORS story (`Origin` = the preview host) | L |
| 2 | Until (1) ships, **tighten the iframe**: drop `allow-same-origin` (the page becomes an opaque origin: no hub cookies, no parent access). The cost is that the URL-bar sync in `PreviewSidebar.tsx` must move to `postMessage` or be dropped, and the previewed page loses `localStorage`. Pair it with a warning on "open in new tab". | 4.1 (partially; a new tab is still same-origin) | S |
| 3 | **Filter response headers at the hub**: strip `Service-Worker-Allowed`; rewrite or strip `Set-Cookie` (force `Path=/api/v1/preview/<sid>/`, drop `Domain`); rewrite `Location` headers that point at `127.0.0.1:<port>` or are root-absolute into the prefix. Needs a minimal response-head parser on the relay; the body still streams. | 4.1 (persistence vectors), 4.2 | M |
| 4 | **Send forwarding headers**: `X-Forwarded-Host: <hub-host>`, `X-Forwarded-Proto: https`, `X-Forwarded-Prefix: /api/v1/preview/<sid>`, `X-Forwarded-For`. Most frameworks can then generate correct absolute URLs and redirects when told to trust the proxy. | 4.2, 4.4 (for prefix-aware frameworks) | S |
| 5 | **Widen the request allowlist** to forward `Authorization` (after verifying Authentik ignores it on this route), `Origin` **rewritten** to the public preview origin, CSRF headers (`X-CSRF-Token`, `X-CSRFToken`, `X-XSRF-TOKEN`, `X-Requested-With`), `If-Match`, `If-Unmodified-Since`, `Content-Encoding`, `User-Agent`, `Referer`. Alternatively switch to a **denylist** (hop-by-hop headers + `Cookie` + the forward-auth identity headers such as `X-authentik-*`). Keep stripping `Cookie` while the origin is shared. | 4.3, scenario M | S |
| 6 | **Dial `::1` as a fallback** when `127.0.0.1` is refused (still loopback, same SSRF fence), and surface `port_closed` in the UI with "is the server bound to 127.0.0.1?". | 4.5 | S |
| 7 | Allow **keep-alive** to the upstream (pool one connection per stream id or per session) and document the 120 s idle timeout. | 4.6, 4.7 | M |
| 8 | Optional, a separate decision: an **opt-in public/unauthenticated preview link** (per-session, revocable, expiring) for webhooks, mobile devices and sharing. Must only be considered after (1). | scenarios P, Q | M |

Suggested test coverage for whichever items are picked up: a hermetic upstream on the bridge that echoes
the request line + headers. Assert the forwarded header set (both the preview and `/proxy` paths, since
they share `_preview_build_http_request`), `Location`/`Set-Cookie` rewriting, and an IPv6-only listener.
