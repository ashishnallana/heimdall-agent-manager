---
name: heimdall-preview-setup
description: How to share a web app or API you are running on localhost (dev server, prod build, backend) with the user you are talking to through Heimdall, so they can open it in the Heimdall preview sidebar or on their phone. Covers `ham-ctl shell serve --port`, presenting the hub-returned `preview_url` verbatim, making apps work under the preview path prefix, frontend/backend on different machines, and troubleshooting blank or stopped previews. Load whenever you want the user to see, click through, or test something you started locally. Never send them a localhost URL.
---

# Share a local web app through Heimdall

## When to use

Use this skill whenever a Heimdall user should see or test an HTTP app that you run locally. The user, often on a phone or another machine, cannot open `http://localhost:<port>` on your machine. Start a port-declared server session and give them the `preview_url` returned by the Hub.

## Start and share the preview

1. Build the frontend for production. Prefer its production preview/static server over a development server; the many module requests and dev-only WebSocket assumptions of a dev server are fragile through the tunnel.
2. Bind the service to `127.0.0.1`. Heimdall also falls back to `::1`, but IPv4 loopback is the predictable choice.
3. Start it as a managed long-running session, declaring the same port:

   ```bash
   ham-ctl shell serve --cmd 'npm run preview -- --host 127.0.0.1 --port 4173' \
     --port 4173 --cwd /absolute/path/to/app
   ```

   `--port` is optional for a server session, but required to make that session previewable. The Hub exposes the session to its owner without opening an inbound port on the machine.
4. Share the link the Hub gives you. `ham-ctl shell serve` (and `ham-ctl shell show <sid>`, any time later) prints a line such as:

   ```text
   Preview: https://heimdall-preview.example.com/p/sh_18dd.../
   ```

   Send that URL to the user **verbatim**. It is also the `preview_url` field of the shell-session JSON. You never need to know the preview origin yourself: the Hub builds `preview_url` from its own `--preview-origin` configuration and picks the right form. Never build a URL from `server_port` or the session id, and never send the user a localhost URL. If no `Preview:` line appears, the session has no declared port; start it with `--port`.

The URL has one of two forms:

- With a preview origin configured: `<preview_origin>/p/<sid>/`. It is isolated from the Hub origin and protected by its own preview sign-in: the Hub mints a host-only `__Host-heimdall_preview` cookie for the user's Hub session (an unauthenticated navigation bounces through the Hub and back automatically). If the iframe asks for authentication, tell the user to click **Sign in / open in new tab** once.
- Legacy mode: `<ui_origin>/api/v1/preview/<sid>/`. It shares the Hub origin. Only preview trusted code: JavaScript here runs with the user's Hub-origin privileges.

Both modes retain a session path prefix, so the application rules below apply to both.

## Frontend checklist

- Emit document-relative assets: Vite `base: './'`, Create React App `"homepage": "."`, or Angular `<base href="./">`. For Next.js, `basePath` is build-time and contains the session-specific prefix, so prefer a proxy/BFF or a framework setup that can accept the runtime prefix.
- Use document-relative same-app calls such as `fetch('api/items')` or `fetch('./api/items')`, not root-relative `/api/items`.
- Serve the production build, for example `vite build && vite preview --host 127.0.0.1`, or `npx serve -s dist -l 4173`.
- Use hash routing, or configure the upstream SPA fallback so a refresh below the session prefix still returns the application shell.
- Never call `http://localhost:<port>` from browser JavaScript. On a phone, `localhost` is the phone.
- Do not emit `X-Frame-Options: DENY` or CSP `frame-ancestors 'none'` if the app must render in the sidebar.

## Backend behavior through the tunnel

The upstream receives its original method, path below the session prefix, query, and body. It sees `Host: 127.0.0.1:<declared-port>` plus:

- `X-Forwarded-Host`, `X-Forwarded-Proto: https`, `X-Forwarded-Prefix`, and `X-Forwarded-For`;
- browser `Origin`, `Authorization` (in legacy mode only non-Bearer schemes such as Basic; see below), common CSRF headers, conditional/content headers, and WebSocket negotiation headers when applicable.

In legacy mode, browser `Origin` is the Hub origin, `Cookie` is never forwarded, and an `Authorization: Bearer ...` header is consumed by the Hub's own authentication before forwarding (an unknown Bearer token is rejected with `401`), so only non-Bearer schemes such as Basic reach the app. On the preview origin, `Origin` is the preview origin, `Authorization` is left for the app, `OPTIONS` reaches the app, and application cookies are forwarded after all Hub cookies (`__Host-heimdall_*`, and legacy `authentik_*`) are removed. Hub credentials never reach the app in either mode.

Use `X-Forwarded-Prefix` when generating absolute URLs. The Hub rewrites root/local `Location` responses under the active session prefix, forces each `Set-Cookie` `Path` to that prefix, drops its `Domain`, and strips `Service-Worker-Allowed`. Prefer relative URLs anyway.

For SSE or long polling, emit a heartbeat more often than every 120 seconds. The non-WebSocket preview relay has a 120-second idle timeout.

## Connect a frontend to a backend

For a backend in the same app/session, use document-relative URLs. When possible, put the API behind the frontend server with a dev-server proxy, framework rewrite, BFF, or SSR handler so the browser still calls a relative path.

For a real remote API called directly by the browser, configure CORS for the actual public origin: `https://<preview-host>` in preview-origin mode or `https://<hub-host>` in legacy mode. Add credential settings only when the API needs them.

### Backend on machine A, frontend on machine B, viewed on a phone

Start two port-declared sessions owned by the same Heimdall user:

- `sidA`: backend on bridge A;
- `sidB`: frontend on bridge B.

Give the user `sidB`'s Hub-returned `preview_url` verbatim. Inject `sidA` into the frontend at runtime; session ids are not service-discovered or automatically added to the process environment.

Choose one connection pattern:

1. **Browser to backend:** in preview-origin mode call `/p/<sidA>/api/...`; in legacy mode call `/api/v1/preview/<sidA>/api/...`. This is same-origin, needs no CORS, carries the preview-origin authentication cookie where applicable, and is owner-checked by the Hub.
2. **Frontend server/BFF/SSR to backend:** on machine B call `http://127.0.0.1:<bridge-B-local_endpoint_port>/proxy/<sidA>/api/...`; browser code calls a document-relative path such as `api/...`. Find the local endpoint port with `ham-ctl bridge list --scope configured`.

Both sessions must have the same owner. Cookies returned by either app are path-scoped to its own session prefix. Keep the relative-base, production-build, and SSE-heartbeat rules above. On the first phone visit, the user may need **Sign in / open in new tab** once.

## Diagnose blank or stopped previews

The sidebar uses the session's `preview_url`. A stopped session remains open and shows status and exit code; **Preview · Stdout** displays its captured output. When a user reports a blank or stopped preview, check session status and **Stdout** first.

| Symptom | Check and fix |
|---|---|
| Blank page | Open **Stdout**, confirm the session is running, then inspect browser errors. Verify the production server bound the declared port and assets use a relative base. |
| `404` for `/assets/...` | The build emitted root-absolute paths. Configure `base: './'`, `homepage: "."`, or `<base href="./">`, rebuild, and restart. |
| `port_closed` | The declared port does not match the listener, or the process is not listening. Bind the exact port to `127.0.0.1`; `::1` is supported only as fallback. |
| WebSocket `403` | The dev server is rejecting the public Origin or forwarded Host. Prefer a production build; otherwise allow the public preview/Hub origin and trust the forwarded headers in preview mode. |
| API `401` | Check which mode is active. Legacy strips cookies and cannot carry `Authorization: Bearer` (the Hub consumes or rejects it); use the preview origin, or a frontend proxy/BFF that adds the token server-side. Preview-origin strips only the Hub's own cookies and forwards `Authorization`. Also confirm both sessions share an owner. |
| Redirect loop | Trust `X-Forwarded-Proto`, `X-Forwarded-Host`, and `X-Forwarded-Prefix`; emit relative redirects when possible. |
| Refused to frame / X-Frame-Options | Remove `X-Frame-Options: DENY` and restrictive `frame-ancestors` for this preview build. |

Never work around an owner check, publish a bridge port, or paste local credentials into frontend code. If the preview contains untrusted dependencies or content, do not open it in legacy mode.
