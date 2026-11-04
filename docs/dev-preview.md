> Moved verbatim from the "Preview-Driven UI Development" section of the former `AGENTS.md`.

# Preview-Driven UI Development (Live Production Data + Instant HMR)

For rapid UI development, testing, and agent workflows, Heimdall supports a **live preview-driven development environment**. This allows developers and agents to make changes to the React/TypeScript frontend and see updates reflected in real time against **live production Hub data**, without running a local hub, maintaining fixtures, or mocking APIs.

### Key Capabilities
- **Real Production Data**: The preview is hosted under the production Hub origin (`https://heimdall.mundus.in/api/v1/preview/<session_id>/#/`). All frontend requests to `/api/v1/...` go directly to the production Hub, authenticated via the user's browser session (Authentik).
- **Instant Hot Module Replacement (HMR)**: Edits to `src/ui/` trigger sub-second module replacement in the preview window without losing React component state or page position.
- **Monaco LSP Integration**: Editing code within Heimdall's editor provides real-time TypeScript diagnostics, hover tips, autocomplete, and symbol navigation backed by the local TypeScript Language Server on the bridge.

### Architecture

```
[ Browser: https://heimdall.mundus.in/api/v1/preview/<session_id>/#/ ]
   │
   ├─► API Requests (/api/v1/...) ───────────► Real Production Hub (Authenticated via Cookies)
   │
   ├─► Assets / Modules (/api/v1/preview/<session_id>/...) ──► Production Hub Tunnel
   │                                                                   │
   └─► WebSocket HMR (wss://.../api/v1/preview/<session_id>/) ───────┤
                                                                       ▼
                                                       [ Bridge Host: 127.0.0.1:49324 ]
                                                                       │
                                                       (Strips /api/v1/preview/<session_id>)
                                                                       │
                                                                       ▼
                                                [ Reverse Proxy: declared port 5173 ]
                                                (scripts/dev-preview.mjs)
                                                  - Re-adds /api/v1/preview/<session_id>/
                                                  - Injects SLASH_GUARD into HTML
                                                  - Relays WebSocket Upgrade frames
                                                                       │
                                                                       ▼
                                                [ Internal Vite Dev Server: port 5174 ]
                                                (vite --base /api/v1/preview/<session_id>/)
```

1. **Declared Session Port (5173)**:
   The reverse proxy (`scripts/dev-preview.mjs`) listens on the declared shell session port. When the Hub forwards tunnel traffic, the path prefix is stripped. The reverse proxy re-adds `/api/v1/preview/<session_id>/` and forwards requests to the internal Vite server.
2. **Internal Vite Dev Server (5174)**:
   Runs standard Vite configured with `--base /api/v1/preview/<session_id>/`. Because all module imports and asset tags include the prefix, the browser requests them through the tunnel rather than falling back to the Hub root.
3. **Hash Navigation Guard (`SLASH_GUARD`)**:
   The reverse proxy injects an inline script into HTML responses to ensure the SPA router initializes with `#/` (`history.replaceState`), preventing the route map from rejecting the tunnel pathname.
4. **WebSocket HMR Relay**:
   The proxy handles WebSocket `Upgrade` events and pipes raw duplex traffic directly to Vite, maintaining an active HMR connection for live updates.

### Usage

#### Start the Dev Preview
Run the launcher script from the repository root:
```bash
./scripts/dev-preview.sh
# or via npm
npm run dev:preview
```
This automatically:
1. Cleans up any existing dev preview shell sessions.
2. Starts the server shell session on the bridge.
3. Launches internal Vite and the reverse proxy.
4. Validates local tunnel responses and prints the active preview URL.

#### Open the Preview
Navigate to the printed preview URL:
```
https://heimdall.mundus.in/api/v1/preview/<session_id>/#/
```

#### Stream Server Logs
To monitor requests, Vite compilation, and diagnostics:
```bash
ham-ctl shell log <session_id>
```

#### Stop the Dev Preview
```bash
./scripts/dev-preview.sh --stop
```

### Environment Variables
- `HEIMDALL_PREVIEW_PORT`: Port for the reverse proxy (default: `5173`).
- `HEIMDALL_VITE_PORT`: Port for internal Vite dev server (default: `5174`).
- `HEIMDALL_BRIDGE_ID`: Explicit bridge ID override (defaults to auto-detecting the online bridge).
- `HEIMDALL_PREVIEW_CHAIN`: Optional task chain ID to file the session under.
