# Heimdall Self-Hosting Guide

Heimdall is a hub-and-bridge system. The hub (daemon + web UI) runs on one central
device and stores all durable state. A bridge runs on each device where AI agent
processes (Claude Code, Codex, etc.) actually execute. The two sides communicate over
HTTPS, so they can live on different machines, networks, and operating systems.

---

## Part 1 — Hub and UI (one device, internet/VPN-accessible)

The hub is the central control plane. It exposes a REST/WebSocket API that bridges,
the web UI, and `ham-ctl` all connect to. It only needs to run on one machine.

### 1.1 What the hub needs

| Component | Purpose |
|-----------|---------|
| `ham-hub` | Odin binary — HTTP/WS server, task/memory/agent state, SQLite persistence |
| `ham-ctl` | CLI for humans and agents |
| Web UI / Electron app | React + Vite dashboard (optional for server-only setups) |
| A TLS terminator | nginx, Caddy, or Tailscale — exposes hub to internet or VPN |

### 1.2 Build dependencies

**Nix (recommended — all dependencies are pinned)**

```bash
# Install Nix with flakes support
curl -L https://nixos.org/nix/install | sh
# Enable flakes (add to ~/.config/nix/nix.conf or /etc/nix/nix.conf)
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

**Manual build dependencies (if not using Nix)**

| Dependency | Version | Purpose |
|------------|---------|---------|
| Odin compiler | ≥ 2024-11 (LLVM 18/21) | Compiles hub, bridge, ctl |
| SQLite 3 | ≥ 3.40 | Hub database (linked at build time) |
| Node.js | ≥ 20 | Builds the web UI |
| npm | ≥ 10 | UI dependency management |
| Electron | from npm | Desktop app wrapper |

### 1.3 Building

**With Nix (recommended)**

```bash
git clone https://github.com/tanmayv/heimdall-agent-manager
cd heimdall-agent-manager

# Build hub binary
nix build .#ham-hub

# Build CLI
nix build .#ham-ctl

# Build web UI (for browser access)
nix build .#heimdall

# Run the hub directly (wraps ham-hub with correct --migrations-dir)
nix run .#hub -- --db /var/lib/heimdall/hub.db --port 8081
```

**Manual build**

```bash
# Clone the repo
git clone https://github.com/tanmayv/heimdall-agent-manager
cd heimdall-agent-manager

# Build hub
odin build src/hub -collection:odin_test=src -out:./bin/ham-hub

# Build CLI
odin build src/ctl -collection:odin_test=src -out:./bin/ham-ctl

# Build UI (outputs to dist/)
npm install --legacy-peer-deps
npm run build
```

### 1.4 Running the hub

```bash
# Create data directory
mkdir -p /var/lib/heimdall

# OIDC provider (required: users sign in only with OIDC; see docs/auth-oidc.md)
export HAM_OIDC_ISSUER=https://auth.example.com/application/o/heimdall/
export HAM_OIDC_JWKS_URL=https://auth.example.com/application/o/heimdall/jwks/
export HAM_OIDC_USERINFO_URL=https://auth.example.com/application/o/userinfo/
export HAM_OIDC_AUTHORIZE_URL=https://auth.example.com/application/o/authorize/
export HAM_OIDC_TOKEN_URL=https://auth.example.com/application/o/token/
export HAM_OIDC_END_SESSION_URL=https://auth.example.com/application/o/heimdall/end-session/
export HAM_OIDC_API_AUDIENCE=heimdall-api
export HAM_OIDC_API_SCOPE=heimdall.api
export HAM_OIDC_WEB_CLIENT_ID=<provider client id>

# Start the hub (replace /path/to/ with your actual paths)
ham-hub \
  --db /var/lib/heimdall/hub.db \
  --migrations-dir /path/to/share/ham-hub/migrations \
  --port 8081 \
  --host 127.0.0.1 \
  --ui-origin https://hub.example.com
```

The hub refuses to start without the OIDC settings and `--ui-origin` (an https origin).
Configure the provider as described in [docs/auth-oidc.md](docs/auth-oidc.md#authentik-setup-mundus-as-the-example)
and link existing users with `ham-hub users link-oidc` (or set
`HAM_AUTO_PROVISION_USERS=true` / `HAM_OIDC_CLAIM_EXISTING_USERS=true` deliberately).
For local development use `tools/mock-oidc` (see its README).

The hub binds to `127.0.0.1` by default. Put nginx/Caddy in front to expose it over
HTTPS. The web UI is served as a static bundle and can be served by the same reverse proxy.

### 1.4a Billing and plan enforcement

A self-hosted hub with no Paddle credentials or price ID is unlimited by default.
If any Paddle API key, client token, webhook secret, or Hobbyist price ID is set,
plan limits turn on, even when checkout is not fully configured. Set enforcement
explicitly to control it independently of checkout:

```bash
# Enforce catalog plans and account overrides without requiring Paddle.
export HEIMDALL_BILLING_ENFORCE_PLAN_LIMITS=true

# The flag takes precedence over the environment.
ham-hub --db /var/lib/heimdall/hub.db --billing-enforce-plan-limits false
```

With enforcement enabled, Free includes **one bridge**, **view-only agent
terminals**, **two concurrent terminal streams**, and **no user shells**.
Hobbyist includes two bridges, terminal input, unlimited streams, and user shells.
Agent `run`/`serve` automation keeps working. Counts use `-1` for unlimited;
`0` means zero allowed.

The hub returns `402 plan_limit_reached` with limit details and an Account upgrade
path. Excess WebSocket streams receive a typed error and close `4402`. Over-limit
bridges are disabled rather than revoked and can be re-enabled after an upgrade
or override. Existing sessions are not killed.

For catalog configuration, the entitlement/override table, SQL examples,
30-second cache behavior, and a manual preview checklist, see
[Account billing and plan limits](docs/account-billing.md).

### 1.5 Systemd service (Linux hub)

Create `/etc/systemd/system/heimdall-hub.service`:

```ini
[Unit]
Description=Heimdall Hub
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=heimdall
Group=heimdall
# HAM_OIDC_* settings (see 1.4); the client secret, if any, by file path only
EnvironmentFile=/etc/heimdall/hub-oidc.env
ExecStart=/usr/local/bin/ham-hub \
    --db /var/lib/heimdall/hub.db \
    --migrations-dir /usr/local/share/ham-hub/migrations \
    --port 8081 \
    --host 127.0.0.1 \
    --ui-origin https://hub.example.com
Restart=on-failure
RestartSec=5s
StateDirectory=heimdall
WorkingDirectory=/var/lib/heimdall

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now heimdall-hub
```

### 1.6 NixOS module (hub + nginx)

In `nix-homelab-config` or any NixOS flake:

```nix
{
  inputs.heimdall.url = "github:tanmayv/heimdall-agent-manager";

  nixosConfigurations.myhub = nixpkgs.lib.nixosSystem {
    modules = [
      {
        environment.systemPackages = [
          inputs.heimdall.packages.x86_64-linux.ham-hub
          inputs.heimdall.packages.x86_64-linux.ham-ctl
        ];

        systemd.services.heimdall-hub = {
          description = "Heimdall Hub";
          after = [ "network-online.target" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            ExecStart = ''
              ${inputs.heimdall.packages.x86_64-linux.ham-hub}/bin/ham-hub \
                --db /var/lib/heimdall/hub.db \
                --migrations-dir ${inputs.heimdall.packages.x86_64-linux.ham-hub}/share/ham-hub/migrations \
                --port 8081 --host 127.0.0.1 --ui-origin https://hub.example.com
            '';
            # HAM_OIDC_* (see 1.4 and docs/auth-oidc.md); keep secrets in files (sops/agenix).
            EnvironmentFile = "/run/secrets/heimdall-hub-oidc.env";
            Restart = "on-failure";
            StateDirectory = "heimdall";
            DynamicUser = true;
          };
        };

        # Serve hub API + web UI via nginx
        services.nginx.virtualHosts."hub.example.com" = {
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            proxyPass = "http://127.0.0.1:8081";
            proxyWebsockets = true;
          };
        };
      }
    ];
  };
}
```

### 1.6a Preview origin (recommended when previews are enabled)

Shell-session previews (`ham-ctl shell serve --port N`) run code from your projects in the
browser. Served from the hub's own origin, that code has your full hub privileges. Serve previews
from a **separate origin** instead:

```bash
ham-hub ... \
  --ui-origin      https://hub.example.com \
  --preview-origin https://hub-preview.example.com   # empty = previews stay on the hub origin
```

The hub then returns every preview link as `preview_url = <preview-origin>/p/<session-id>/`, and
**any request for that host is answered only by the preview relay**. Hub APIs, UI and assets are
never served there. Point the preview host at the **hub API listener directly**: a UI/static layer with an
SPA fallback would swallow `/p/…`. As defense in depth, proxy only `/p/` and return 404 for everything else.

**Requirements**

1. **DNS + TLS:** one record for `hub-preview.example.com` pointing at the same reverse proxy. A normal
   (HTTP-01) certificate is enough.
2. **No forward-auth.** The hub authenticates the preview host itself with a host-only
   `__Host-heimdall_preview` cookie. It is minted on the preview host from a one-time, browser-bound
   ticket that `<ui_origin>/api/v1/preview-auth/start` issues to the signed-in owner (details in
   [docs/auth-oidc.md](docs/auth-oidc.md#preview-origin)). Unauthenticated preview navigations
   bounce through the hub UI origin automatically.
3. **Reverse proxy:** forward `/p/` **and** `/__heimdall/` on the preview host to the **hub API
   listener**, keep the `Host` header, and return 404 for everything else.
4. **Same-site note:** if the preview host shares the hub's registrable domain (as in this example),
   the hub's CSRF guard (Origin / `Sec-Fetch-Site` checks on mutating requests and WebSocket handshakes)
   is what stops previewed code from acting through your browser session. Keep `--ui-origin` set
   correctly.

**Legacy same-origin route.** Once `--preview-origin` is set, the old `/api/v1/preview/<session-id>/`
route on the hub origin answers **404** (code served from it could call every hub API as the viewer).
`--preview-legacy-path true` reopens it for old links; the hub then logs a `WARNING:` line at startup,
as it does when `--preview-origin` is unset. Prefer migrating links to `preview_url` over the opt-in.

**What reaches the previewed app.** On both routes the hub strips its own cookies
(`__Host-heimdall_*`) and any `authentik_*` cookies. Only the preview origin additionally forwards
the app's other cookies and the vault request signature headers
(`X-Heimdall-Device-Id`/`-Ts`/`-Nonce`/`-Sig`, so a Heimdall hub can be previewed and paired). On the
legacy route `Authorization: Bearer …` is dropped because it may be a hub bearer; other schemes
(Basic, Digest) pass through. On the preview origin the hub ignores `Authorization` for its own auth,
so the header belongs to the app and is forwarded unchanged.

**nginx (NixOS) example**

```nix
services.nginx.virtualHosts."hub-preview.example.com" = {
  enableACME = true;
  forceSSL = true;
  # Only preview paths and the hub's preview sign-in endpoints reach the hub.
  locations."/".return = "404";
  locations."/__heimdall/".proxyPass = "http://127.0.0.1:8081";
  locations."/p/" = {
    proxyPass = "http://127.0.0.1:8081";   # the hub API listener, not a UI/static layer
    proxyWebsockets = true;
    extraConfig = ''
      proxy_set_header Host $host;          # the hub dispatches on Host
      proxy_buffering off;                  # streaming / SSE through the relay
      proxy_read_timeout 1h;
    '';
  };
};
```

**Caddy example**

```caddy
hub-preview.example.com {
	route {
		reverse_proxy /__heimdall/* 127.0.0.1:8081
		reverse_proxy /p/* 127.0.0.1:8081 {
			flush_interval -1
		}
		respond 404
	}
}
```

**Check it**

```bash
curl -sI https://hub-preview.example.com/p/anything/ -H 'Sec-Fetch-Mode: navigate'
#   signed out: 302 to https://hub.example.com/api/v1/preview-auth/start?...&bind=...
# In a signed-in browser: https://hub-preview.example.com/api/v1/me must be 404, never hub JSON.
```

### 1.6b Serving the web UI (compression and caching)

The hub serves only `/api/v1`; the web UI is the static `dist/` from `npm run build`
(`$out/share/heimdall/dist` in the Nix package), served by your reverse proxy. Two settings
decide how fast it loads (the snippets below show only those; keep your TLS and auth directives):

- **Compression.** The JS is text and shrinks about 4× with gzip, more with brotli.
- **Caching.** Everything under `assets/` has a content hash in its file name, so it can be
  cached forever; a release ships new names. `index.html`, `notification-sw.js` and
  `manifest.webmanifest` keep their names and must be revalidated, or browsers keep loading
  the previous release.

**nginx**

```nginx
gzip on;
gzip_types text/css application/javascript application/json image/svg+xml application/manifest+json;

root /usr/share/heimdall/dist;

location /api/v1/ {
    proxy_pass http://127.0.0.1:8081;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
}
location /assets/ {
    add_header Cache-Control "public, max-age=31536000, immutable";
}
location / {
    add_header Cache-Control "no-cache";
    try_files $uri /index.html;
}
```

**Caddy**

```caddy
hub.example.com {
    encode zstd gzip
    handle /api/v1/* {
        reverse_proxy 127.0.0.1:8081
    }
    handle {
        root * /usr/share/heimdall/dist
        @hashed path /assets/*
        @unhashed not path /assets/*
        header @hashed Cache-Control "public, max-age=31536000, immutable"
        header @unhashed Cache-Control "no-cache"
        try_files {path} /index.html
        file_server
    }
}
```

**Check it**

```bash
curl -sI -H 'Accept-Encoding: gzip' https://hub.example.com/ | grep -i cache-control    # no-cache
js=$(curl -s https://hub.example.com/ | grep -o 'assets/index-[^"]*\.js')
curl -sI -H 'Accept-Encoding: gzip' "https://hub.example.com/$js" | grep -iE 'content-encoding|cache-control'
# expect: content-encoding: gzip (or br/zstd) and cache-control: ... immutable
```

### 1.7 Single-user / VPN setup with dev-proxy (no TLS cert required)

> **When to use this:** You are the only user, the hub is reachable only through a
> private VPN (Tailscale, WireGuard, etc.) or a local network, and you do not want to
> manage TLS certificates. If the hub is publicly accessible on the internet, **do not
> use this approach** — use a real TLS terminator (nginx + ACME, Caddy, or Tailscale
> HTTPS) so that credentials and agent traffic are encrypted in transit.

> **Browser sign-in needs HTTPS.** Users sign in with OIDC and the hub requires an
> `https://` `--ui-origin` (session cookies are `Secure` `__Host-` cookies). A plain-HTTP
> setup below is therefore only suitable for **bridge** traffic; serve the UI origin over
> HTTPS (e.g. Tailscale HTTPS or Caddy with an internal CA). `HAM_OIDC_ALLOW_INSECURE_LOCALHOST=1`
> is for development on `localhost` only.

For a personal, VPN-only deployment you can skip the reverse proxy entirely and use
a simple dev-proxy (e.g. `caddy reverse-proxy` in plain HTTP mode, or a one-liner
`socat`/`nginx` forward) that just routes plain HTTP to the hub. The hub itself
already handles all authentication; the only risk you are accepting is that traffic
on the VPN is unencrypted — acceptable when the VPN itself provides the transport
security.

**Option A — Caddy as a plain HTTP proxy (no certificates)**

```bash
# Install Caddy, then create /etc/caddy/Caddyfile:
:80 {
    reverse_proxy 127.0.0.1:8081
}
```

```bash
sudo systemctl enable --now caddy
```

Bridges and the web UI connect to `http://<vpn-ip>` (port 80). No certificate
management needed.

**Option B — socat one-liner (quick test / no daemon)**

```bash
# Forward public VPN port 8080 → hub on 127.0.0.1:8081
socat TCP-LISTEN:8080,fork,reuseaddr TCP:127.0.0.1:8081
```

Bridges connect to `http://<vpn-ip>:8080`. This is a foreground process; wrap it in
a systemd unit or `tmux` session if you want it to persist.

**Option C — nginx plain HTTP proxy**

```nginx
# /etc/nginx/sites-available/heimdall
server {
    listen 80;
    server_name _;   # or your VPN hostname

    location / {
        proxy_pass         http://127.0.0.1:8081;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade $http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host $host;
    }
}
```

```bash
sudo ln -s /etc/nginx/sites-available/heimdall /etc/nginx/sites-enabled/
sudo systemctl reload nginx
```

**Configuring bridges to use a plain HTTP hub**

When the hub is served over plain HTTP, pass its `http://` API origin to
`ham-bridge enroll` and to the bridge service. The Hub supplies its configured
browser origin in the authorize response:

```bash
ham-bridge enroll \
  --hub http://<vpn-ip> \
  --bridge-token-file ~/.config/heimdall/bridge-token
```

It prints a link and a short code; open the link on any device, check the code and key
fingerprint match what this machine shows, and approve. Add `--headless` if this
machine has no browser of its own.

The `--hub` flag in the systemd/launchd service should match (e.g.
`http://100.x.x.x` for a Tailscale IP).

### 1.8 Hub telemetry (Prometheus + Grafana, optional)

The hub keeps Prometheus metrics in-process at all times (cheap atomics) and
serves them on a **separate, private listener** when asked to:

```bash
ham-hub ... --metrics-addr 127.0.0.1:9464        # or HEIMDALL_METRICS_ADDR=127.0.0.1:9464
curl -s http://127.0.0.1:9464/metrics | head
```

- Off by default (`--metrics-addr` empty). The flag takes an IPv4 `host:port`
  only; keep it on loopback — `/metrics` will carry owner ids once fleet
  metrics land, and it is never routed on the public port.
- The listener answers only `GET /metrics` and `GET /healthz`, one request at
  a time, with 5 s socket timeouts. Content type is
  `text/plain; version=0.0.4; charset=utf-8`.
- What you get today: `heimdall_http_requests_total{route,method,status_class}`
  (route = matched **pattern**, never the raw path; `unmatched` otherwise),
  `heimdall_http_request_duration_seconds` (router dispatch only — WebSocket
  upgrades and the preview relay are excluded), `heimdall_http_in_flight`,
  `heimdall_http_accept_errors_total`, the standard `process_*` family from
  `/proc/self`, `heimdall_hub_build_info{version,commit}`, and the lib's own
  `heimdall_metrics_series` / `heimdall_metrics_scrape_duration_seconds`.
- DB latency / lock-contention telemetry (`heimdall_db_*`, extra
  `heimdall_sqlite_*` families and `db_slow_request` log lines) is **on by
  default** (`HEIMDALL_DB_TELEMETRY` unset = `basic`); set
  `HEIMDALL_DB_TELEMETRY=off` and restart to opt out. Any other value fails
  boot. See [`docs/reference/db-telemetry.md`](docs/reference/db-telemetry.md).
- Fleet metrics (`heimdall_bridge_*`, `heimdall_ws_*`, `heimdall_shell_*`,
  `heimdall_preview_*`, `heimdall_lsp_sessions`, SQLite/reaper/auth/billing
  counters) carry `bridge_id` at most; the owner appears only on
  `heimdall_bridge_info`, which disappears when the bridge disconnects. Join:
  `heimdall_shell_sessions * on(bridge_id) group_left(owner) heimdall_bridge_info`.
- **Bridge host resources** (`heimdall_bridge_process_resident_bytes`,
  `..._cpu_seconds_total`, `heimdall_bridge_host_memory_bytes`,
  `heimdall_bridge_host_load1`, `heimdall_bridge_disk_free_bytes`,
  `heimdall_instance_resident_bytes{provider}`, `heimdall_instance_cpu_seconds_total{provider}`)
  ride on the bridge's existing 45 s heartbeat as a `stats` object — one `ps -A`
  per heartbeat on the bridge host, no inbound connection. The hub size-caps,
  clamps and rate-limits (5 s) what it accepts and maps providers onto its
  catalog (`claude|codex|copilot|antigravity|gemini|other`).
  **`telemetry_enabled` now governs both** the local Telegraf exporter and
  these heartbeat stats: `disabled` turns them off (the hub says so in
  `bridge_ready` and on `set_telemetry`), `inherit`/`enabled` keep them on.
  Bridges older than this release simply send no `stats`.

**Full stack on the NixOS hub host** (Prometheus 15 d / 8 GB, node_exporter,
blackbox probe of your public URL, Grafana behind Authentik OIDC for the
`heimdall-admins` group only):

```nix
imports = [ "${inputs.heimdall}/tools/telemetry/hub/nixos-telemetry.nix" ];
services.heimdall-telemetry = {
  enable = true;
  telemetryDir = "${inputs.heimdall}/tools/telemetry/hub";
  publicUrl = "https://hub.example.com";
  grafanaDomain = "grafana.example.com";
  authentikUrl = "https://auth.example.com";
  oauthClientSecretFile = "/run/secrets/grafana-oauth";   # from your secrets manager
};
# and add `--metrics-addr 127.0.0.1:9464` to systemd.services.heimdall-hub ExecStart
```

Authentik needs a group `heimdall-admins`, an OAuth2/OIDC provider +
application with redirect URI `https://grafana.example.com/login/generic_oauth`,
and a group-membership policy bound to that application. Grafana additionally
enforces `role_attribute_strict`, so a user outside the group is refused even
if Authentik lets them through. Alert rules live in
`tools/telemetry/hub/alerts.yml` (`promtool check rules` clean); import
Grafana.com dashboard **1860** for host graphs and the provisioned
**Heimdall / Hub Health** for the hub (**Heimdall / Hub DB** for DB latency and lock
contention). Details, non-Nix snippets and how a dashboard update reaches Grafana:
[`tools/telemetry/hub/README.md`](tools/telemetry/hub/README.md).

### 1.9 Bridge error events (why a bridge is failing)

Bridges relay **structured warn/error events** to the hub over their existing
WebSocket: a `code` from a fixed enum (`hub_connect_failed`, `hub_ws_closed`,
`provider_missing`, `agent_exited_early`, `pty_host_unreachable`,
`update_apply_failed`, …) plus a few typed fields (`stage`, `reason`,
`provider`, `exit_code`, `hub_status`, …) whose values are integers or enum
names. **No free text ever leaves the bridge** — no paths, argv, hostnames,
output — so there is nothing to scrub; the hub renders the human sentence from
`code` + fields. The bridge keeps a 256-entry ring, dedups identical events into
a `count`, and flushes ≤ 10 entries / ≤ 4 KiB per frame after each
`bridge_ready` (so the reason for the *previous* disconnect arrives on
reconnect). Shipping follows the same switch as the heartbeat stats
(`telemetry_enabled = disabled` turns it off on both ends; the local stderr line
is always printed).

On the hub, every event is:

- **counted**: `heimdall_bridge_errors_total{code,level}` (fleet-wide),
  `heimdall_bridge_errors_by_bridge_total{bridge_id}`, plus
  `heimdall_bridge_log_entries_total`, `..._log_dropped_total` (bridge ring
  drops), `..._log_queue_dropped_total` (hub queue overflow),
  `heimdall_bridge_frames_rejected_total{reason="log_*"}`;
- **stored** in SQLite (`bridge_log_events`, ≤ 500 rows per bridge, 7 days,
  written by one background thread in batches — never from a socket reader);
- **readable by the owner** in *Settings → Bridges → Recent errors*, or
  `GET /api/v1/bridges/{bridge_id}/events?limit=100&before_id=<id>` →
  `{events:[{id,ts_ms,received_at,level,code,fields,count,message}],has_more,next_before_id}`;
  `DELETE …/events` purges. Revoking a bridge deletes its events.

Per-connection abuse bounds: 300-event burst then 20 per 10 s, 4 KiB frames,
unknown codes → `other`, unknown field keys → entry rejected.

**Optional log backend.** Start the hub with

```bash
ham-hub ... --log-push-url http://127.0.0.1:9428     # or HEIMDALL_LOG_PUSH_URL
```

and the same writer thread also POSTs each committed batch to
`<url>/insert/loki/api/v1/push` (VictoriaLogs; Loki accepts the identical
body). Stream labels are only `{job="heimdall-bridge", level}`; `bridge_id`,
`code`, hub `version` and the fields are structured metadata — never `owner`.
2 s timeout, 4xx dropped, 5xx retried once, failures in
`heimdall_log_push_failures_total`; the SQLite ring and the owner API never
depend on the backend. On the NixOS hub host:

```nix
services.heimdall-telemetry.logs.enable = true;   # VictoriaLogs 127.0.0.1:9428, 15 d,
                                                  # journald upload (ham-hub, nginx, …),
                                                  # Grafana VictoriaLogs datasource + plugin
# and add `--log-push-url http://127.0.0.1:9428` to the heimdall-hub ExecStart
```

That provisions the **Heimdall / Bridge Events** dashboard (errors by code,
per-bridge rate, codes first seen in 24 h, event stream) and a *Bridge errors*
row on **Fleet**; `alerts.yml` gains `HeimdallBridgeDangerousErrors`,
`HeimdallBridgeUnknownErrorCodes`, `HeimdallBridgeUpdateFailures`,
`HeimdallLogPushFailures`, `HeimdallBridgeLogQueueDrops`. The hub's own
journal arrives via `systemd-journal-upload` (whole-host journal — filter with
`_SYSTEMD_UNIT:"heimdall-hub.service"` in LogsQL).

---

### 1.10 Upgrading from trusted-proxy (forward-auth) authentication

Hubs before OIDC-only authenticated browsers with forward-auth identity headers
(`X-authentik-*`) and offered Hub user tokens (`hut_`). Both are gone.

1. **Back up the database.**
2. **Configure the provider** (one OAuth2/OIDC provider shared with native apps; add
   `<ui_origin>/api/v1/auth/callback` as a redirect URI) — see
   [docs/auth-oidc.md](docs/auth-oidc.md#authentik-setup-mundus-as-the-example).
3. **Set the HAM_OIDC_* environment** (1.4) and keep `--ui-origin` (https).
4. **Remove from the hub command line**: `--trusted-proxy-cidr`, `--login-url`, `--logout-url`
   — they now **abort startup**, as does a leftover `HAM_AUTH_MODE`. If the hub sits behind a
   proxy and you relied on the CIDR for client-IP logging/rate limits, use
   `--forwarded-for-trusted-cidr` (no auth meaning).
5. **Remove forward-auth** (Authentik outpost, `auth_request` / `forward_auth`, `X-authentik-*`
   header injection) in front of the hub and the preview host; on the preview host forward
   `/p/` and `/__heimdall/` (1.6a).
6. **Link existing users** so they keep their data: `ham-hub users link-oidc --user <id>
   --subject <sub>` per user, or one deploy with `HAM_OIDC_CLAIM_EXISTING_USERS=true` (claims the
   existing user whose name equals the provider `preferred_username` on first sign-in; requires
   non-editable usernames). New users are created only with `HAM_AUTO_PROVISION_USERS=true`.
7. **User tokens**: migration 135 deletes all `hut_` tokens; `ham-ctl` user mode and the
   Electron app cannot sign in until they gain OIDC support. Bridges are unaffected.

## Part 2 — Bridge (one per agent-running device)

The bridge runs on every machine where AI agent processes execute — your laptop,
workstation, desktop, any server that spawns Claude Code / Codex sessions. It
connects outbound to the hub and never needs to be publicly reachable itself.

> **Fast path:** section 2.1 installs prebuilt binaries with a single
> `curl | bash` line and manages the node through the `heimdall` CLI. Sections
> 2.2–2.10 cover the same ground manually (source builds, hand-written service
> files, Nix/Home Manager) for advanced setups.

### 2.1 Quick install (recommended)

On any Linux (x86_64, arm64) or macOS (Intel, Apple Silicon) machine, install
prebuilt binaries with the one-line installer — no Nix, no Odin, no Rust
toolchain, no source checkout. The binaries carry their own HTTPS client
(libcurl, statically linked; the Linux binaries are fully static and run on any
distribution, Alpine and old glibc included), so no libcurl or OpenSSL is
needed. For an HTTPS or WSS hub, install `socat` first:

```bash
sudo apt install socat  # Debian/Ubuntu
brew install socat      # macOS
```

The installer checks this dependency before any download or write and stops with
these commands if it is missing. Nix builds provide `socat` through the wrapped
bridge runtime; this prerequisite applies to the prebuilt installer path.

```bash
curl -fsSL https://raw.githubusercontent.com/tanmayv/heimdall-agent-manager/main/scripts/install.sh | bash
```

Variants:

```bash
# Pin a specific release tag
curl -fsSL https://raw.githubusercontent.com/tanmayv/heimdall-agent-manager/main/scripts/install.sh \
  | bash -s -- --version v0.1.0

# Download from a self-hosted hub mirror instead of GitHub Releases
curl -fsSL https://raw.githubusercontent.com/tanmayv/heimdall-agent-manager/main/scripts/install.sh \
  | bash -s -- --hub https://hub.example.com

# A second bridge to the same Hub for this OS user (another Heimdall user);
# see 2.1.2
curl -fsSL https://raw.githubusercontent.com/tanmayv/heimdall-agent-manager/main/scripts/install.sh \
  | bash -s -- --hub https://hub.example.com --name bob
```

The installer:

1. Detects your platform and fails cleanly on unsupported ones.
2. Downloads the release tarball and its `SHA256SUMS`, and **verifies the
   SHA-256 checksum before extracting anything**.
3. Installs `heimdall`, `ham-bridge`, `ham-pty-host` and `ham-ctl` to
   `~/.local/bin` — no sudo required. Under `curl | sudo bash` the binaries go
   to `/usr/local/bin` while the service file and PATH lines are written for
   the invoking user (resolved from `SUDO_USER`) and chowned to them, so the
   install never splits between `/usr/local/bin` and `/root`; running as root
   without a resolvable `SUDO_USER` is refused. The installer never installs
   an `openssl` — not even from an older release tarball that still ships one:
   `openssl` is a generic name the installer does not own, and writing it into
   a shared `/usr/local/bin` could clobber the host's own. REQ-INST-21 retired
   the bundled-openssl machinery precisely because its provenance record could
   then get that host file deleted on uninstall. The legacy
   `HAM_TLS_BACKEND=s_client` path resolves `openssl` from your system `PATH`.
4. Wires the install directory onto `PATH` in the shell config files that
   actually exist for your shell — `~/.bashrc` / `~/.bash_profile` (bash),
   `~/.zshrc` / `~/.zprofile` (zsh, and the login-shell files macOS reads),
   or `~/.config/fish/config.fish` (fish) — idempotently, and under sudo in
   the invoking user's files rather than root's. A config file for a shell you
   do not use is never created.

   **A shell config file that cannot be written is not an install failure.**
   On NixOS and anywhere home-manager manages your dotfiles, `~/.bashrc` and
   `~/.zshrc` are symlinks into a read-only `/nix/store` path, so the append
   cannot succeed. The installer says which file it could not write, prints a
   copy-pasteable snippet — the plain `export PATH=...` line, the
   home-manager `home.sessionPath` form, and the fish `fish_add_path` form —
   and **carries on to register the service and exits 0**. When no file could
   be written at all, the closing summary states that the install succeeded
   and that only `PATH` needs your action.
5. Registers and starts a per-Hub user service
   (`~/.config/systemd/user/heimdall-bridge-<hub>.service` on Linux,
   `~/Library/LaunchAgents/heimdall-bridge-<hub>.plist` on macOS; with
   `--name <profile>` the name ends in `_<profile>`, see 2.1.2). A legacy
   `heimdall-bridge.service` / `works.earendil.heimdall-bridge.plist` for the
   same Hub is migrated to the per-Hub name.
   An existing, differing service file is first backed up next to it as
   `<name>.bak-<UTC timestamp>`; an identical file is left untouched; pass
   `--force-service` to overwrite a differing file without keeping a backup.
6. Runs browser-approved enrollment interactively. Enrollment restarts the service
   with its new credential and exits.

The registered service always carries the mandatory `--hub <url>`. Enrollment also
writes the same Hub API origin to `config.toml` for wrapper and CLI use.

The Hub URL is never a binary mirror. `install.sh` always downloads the selected
version and `SHA256SUMS` from the project's GitHub release.

Preview every planned action without writing anything:

```bash
bash scripts/install.sh --dry-run --hub https://hub.example.com
```

To reverse an install, pass `--uninstall`:

```bash
bash scripts/install.sh --uninstall --dry-run   # report only, changes nothing
bash scripts/install.sh --uninstall
```

It stops the bridge service (best effort), removes the four binaries, removes
the service file, and strips the
`PATH` lines it added — matched by the `# Added by heimdall install.sh`
marker, so your own `PATH` edits are untouched. It deliberately **keeps** your
state and names the path for each, so you can remove it by hand if you really
want it gone:

- `~/.config/heimdall` — the bridge token and `config.toml`, i.e. your
  enrollment. Uninstalling the binaries does not un-enroll the device.
- `<service file>.bak-*` — service files you had before an install replaced
  them. These are recovery artifacts, not installer debris.
- Any `openssl` at the install directory. The installer never installs one —
  not even from an older release tarball that still ships a bundled `openssl` —
  so `--uninstall` has nothing of its own to remove and never touches the name.
  `openssl` is a generic name the installer does not own: older versions
  installed a bundled copy and recorded `<install dir>/.heimdall-openssl.sha256`
  as proof of authorship, and REQ-INST-21 retired that machinery after its
  provenance record got a host's own `/usr/local/bin/openssl` overwritten and
  then deleted. Whatever `openssl` sits there now is yours or your package
  manager's, and it stays.

The bridge's HTTPS client is **libcurl** (`src/lib/httpc`), linked
**statically** at the version pinned in `nix/libcurl-pin.json` (currently
8.23.0), so nothing is needed from the host:

- Linux: fully static (musl) with OpenSSL 3 and zlib inside — no glibc, no
  libcurl, no OpenSSL on the host; it runs on Alpine, Debian 11, Ubuntu 20.04+,
  Fedora and anything else with a Linux kernel.
- macOS: OpenSSL 3 and zlib inside; certificates are verified by Apple's
  SecTrust (the system keychains and trust settings).
- Windows: Schannel and the Windows certificate store.

Trust anchors, in order: `HAM_TLS_CA_FILE` (that bundle only), then
`SSL_CERT_FILE` / `SSL_CERT_DIR`, then the system store. On Linux the system
store is the first of `/etc/ssl/certs/ca-certificates.crt`,
`/etc/pki/tls/certs/ca-bundle.crt`,
`/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem`, `/etc/ssl/ca-bundle.pem`,
`/etc/ssl/cert.pem` that exists, else `/etc/ssl/certs` when it holds hashed
certificates, else a Mozilla CA bundle embedded in the binary (so a minimal
container without `ca-certificates` still connects). `ham-bridge --probe-hub
<hub>` prints which one it used. The bridge never uses a proxy from the
environment.

`socat` (the default bridge → hub **WebSocket** TLS transport) is not bundled;
install it with your system package manager (`sudo apt install socat`,
`brew install socat`) if it is not already on `PATH`. `openssl` is likewise
not bundled: the `HAM_TLS_BACKEND=s_client` WebSocket fallback resolves it from
your system `PATH`. `HAM_TLS_BACKEND` does not affect HTTPS.

**Then enroll and let it hand off to the registered service:**

```bash
# 1. On this device: enroll. Nothing is created on the hub
#    first, and there is no token to copy between machines — this machine prints a
#    link and a short code, you approve it in a browser, and the credential is
#    delivered here directly. Writes ~/.config/heimdall/bridge-token (mode 0600)
#    and updates config.toml with the hub URL. Add --headless if this machine has
#    no browser of its own.
#
#    The Hub supplies the browser origin. Enrollment receives any encrypted vault
#    key, restarts the registered service, and exits.
ham-bridge enroll --hub https://hub.example.com

# 2. From a second shell: enrollment, service state, hub connection, versions
heimdall status
```

The installer starts the registered service before enrollment. Enrollment opens
only a temporary Hub connection, so it does not collide with the service's local
ports. The delivered vault key is persisted before the service restart, per
bridge: on Linux in the user keyring as `heimdall:vault_key:<bridge_id>`, on macOS
in the login Keychain (service `works.earendil.heimdall-bridge.vault`, account
`<bridge_id>`). Several bridges enrolled on one machine therefore never share,
overwrite, or purge each other's key.

For a non-desktop Linux host, enable lingering so the user service survives logout:

```bash
sudo loginctl enable-linger "$USER"
```

On a non-desktop Linux host, lingering is required so the user service keeps
running after the last login session ends; without it, the bridge stops when you
log out. This does not apply to the macOS LaunchAgent.

Keeping the node current is one command as well:

```bash
heimdall update --check   # report current vs latest release, download nothing
heimdall update           # verify checksums, swap binaries, restart the service
```

`heimdall logs [-f]` tails the service logs and `heimdall doctor` runs local
diagnostics (ports, permissions, harnesses, service unit). Run
`heimdall --help` for the full command list.

### 2.1.1 Windows quick install

On Windows 10 (1809+) or 11, x64 (Windows on Arm runs the x64 bundle under
emulation), run from a **normal, non-elevated** PowerShell — Windows PowerShell 5.1
or PowerShell 7. No administrator rights, no execution-policy change (nothing runs
from a `.ps1` file), and no `socat`: the Windows bridge uses the system TLS stack
(Schannel, both for its statically linked libcurl and for the WebSocket).

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/tanmayv/heimdall-agent-manager/main/scripts/install.ps1))) -Hub https://hub.example.com
```

Once your Hub serves the script at `/public/install.ps1`, the same form works with
`irm https://hub.example.com/public/install.ps1`. Do not use `irm ... | iex` with
arguments: `iex` cannot pass `-Hub`. From a checkout:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install.ps1 -Hub https://hub.example.com
```

`scripts/install.ps1` follows the same six steps as `install.sh` and takes the same
options: `-Hub URL` (asked for when omitted), `-Version TAG`, `-DryRun`,
`-Uninstall`, `-ReEnroll` / `-KeepEnrollment`, `-NonInteractive`, `-Help`, plus
`-FromDir DIR` to install locally built `ham-bridge.exe`, `ham-pty-host.exe` and
`ham-ctl.exe` (from `DIR` or `DIR\bin`; no download or checksum — for testing
before a release exists; `scripts/windows/build.ps1` builds them).

1. **Hub and platform.** The Hub URL is canonicalized exactly as `install.sh`
   does it (HTTP(S) origin only; credentials, paths, queries and fragments are
   rejected; explicit port only when non-default; IDN and IPv6 handled), giving the
   per-Hub service name, e.g. `heimdall-bridge-hub-example-com`.
2. **Preflight and verified release.** The Hub is checked first (20 s budget, exact
   failure reason). Without `-Version` the newest *promoted* GitHub release carrying
   `heimdall-local-windows-amd64-<tag>.zip` and `SHA256SUMS` is used; the zip's
   SHA-256 is verified, verified bundles are cached in
   `%LOCALAPPDATA%\heimdall\cache\releases`, and only the expected regular files
   are extracted (`bin\ham-bridge.exe`, `bin\ham-pty-host.exe`, `bin\ham-ctl.exe`,
   `bin\heimdall.exe` and `scripts\apply-bridge-update.ps1` when shipped). The new
   `ham-bridge.exe --probe-hub` must reach the Hub before anything is replaced.
3. **Replace this Hub's service.** The previous task for this Hub is stopped and
   its binaries replaced; other Hubs' installs are untouched.
4. **Ports and ham-ctl routing.** A free loopback port pair per Hub (`ports.json`),
   `config.toml`, and a per-Hub CLI wrapper `ham-ctl-<service>.cmd` that sets
   `HEIMDALL_BRIDGE_ENDPOINT` and `--config`.
5. **Register the service and enroll.** A per-user Scheduled Task named after the
   service starts at logon, runs without elevation and without any console window
   (`wscript.exe` runs a small hidden service loop, `bin\bridge-service.js`, that
   restarts the bridge 5 s after a failure, like systemd `Restart=on-failure`), and
   carries the same environment as the Linux unit. The task stays stopped while
   `ham-bridge enroll` runs: it prints a pairing code that you type at
   `<hub>/device/add` in a browser that is already approved. `-NonInteractive`
   prints the enrollment command instead.
6. **Ready.** The task is started and the bridge must be listening on its port.

| What | Where |
| --- | --- |
| Config, token (`bridge-token`), `hub-url`, `ports.json`, `enroll.ps1` | `%APPDATA%\heimdall\bridges\<service>` |
| Binaries, service loop, `ham-ctl-<service>.cmd` | `%LOCALAPPDATA%\heimdall\bridges\<service>\bin` |
| Logs (`bridge.out.log`, `bridge.err.log`, rotated at 10 MB) | `%LOCALAPPDATA%\heimdall\bridges\<service>\logs` |

Both directories are restricted to your account (inheritance removed, a single
full-control entry for your SID) — the Windows form of the `0700`/`0600` modes
`install.sh` sets. Re-enroll later with
`powershell -NoProfile -ExecutionPolicy Bypass -File "%APPDATA%\heimdall\bridges\<service>\enroll.ps1"`,
which stops the task, enrolls and starts it again. Manage the task with
`Get-ScheduledTask <service>`, `Stop-ScheduledTask <service>` and
`Start-ScheduledTask <service>`.

`-Uninstall` (with the same `-Hub`) removes the task and the binaries and keeps
the credential, config and agent data. A second concurrent installer run is
refused by a lock in `%APPDATA%\heimdall\bridges\.install-lock`.

### 2.1.2 Several bridges for one OS user (profiles)

By default `install.sh` installs **one** bridge per Hub for an OS user: the
service name comes from the Hub URL alone (`heimdall-bridge-<hub>`, e.g.
`heimdall-bridge-hub-example-com`), so a second run against the same Hub
reinstalls that bridge rather than adding another. To run a second bridge to the
**same Hub** from the **same OS account** — typically so a second Heimdall user
(a colleague, or your own second account) gets their own bridge on this machine —
give it a profile name with `--name` (or `HEIMDALL_BRIDGE_NAME`):

```bash
# Existing default bridge, enrolled as Heimdall user A: unchanged.
# Second bridge for Heimdall user B on the same Hub:
curl -fsSL https://raw.githubusercontent.com/tanmayv/heimdall-agent-manager/main/scripts/install.sh \
  | bash -s -- --hub https://hub.example.com --name bob

# Same thing through the environment:
curl -fsSL https://raw.githubusercontent.com/tanmayv/heimdall-agent-manager/main/scripts/install.sh \
  | HEIMDALL_BRIDGE_NAME=bob bash -s -- --hub https://hub.example.com
```

`--name` wins over `HEIMDALL_BRIDGE_NAME` when both are set. A profile name is
1–31 characters of lower-case letters, digits and `-`, starting with a letter or
digit (`^[a-z0-9][a-z0-9-]{0,30}$`); anything else is refused before the
installer touches the machine.

**What a profile gets.** The profile is appended to the service name as
`heimdall-bridge-<hub>_<profile>` (e.g. `heimdall-bridge-hub-example-com_bob`).
The Hub part never contains `_`, so a profile name can never collide with
another Hub's bridge. Everything else derives from that name, so each profile
is a fully separate bridge:

| | Default bridge | Profile `bob` |
| --- | --- | --- |
| Service (Linux) | `~/.config/systemd/user/heimdall-bridge-hub-example-com.service` | `~/.config/systemd/user/heimdall-bridge-hub-example-com_bob.service` |
| Service (macOS) | `~/Library/LaunchAgents/heimdall-bridge-hub-example-com.plist` | `~/Library/LaunchAgents/heimdall-bridge-hub-example-com_bob.plist` |
| Config, token, `enroll.sh` | `~/.config/heimdall/bridges/heimdall-bridge-hub-example-com/` | `~/.config/heimdall/bridges/heimdall-bridge-hub-example-com_bob/` |
| Binaries, data, extensions | `~/.local/share/heimdall/bridges/heimdall-bridge-hub-example-com/` | `~/.local/share/heimdall/bridges/heimdall-bridge-hub-example-com_bob/` |
| CLI wrapper | `<data dir>/bin/ham-ctl-heimdall-bridge-hub-example-com` | `<data dir>/bin/ham-ctl-heimdall-bridge-hub-example-com_bob` |

Each profile also gets its own loopback port pair, its own bridge id and
credential, and its own vault key (keyed by bridge id, see 2.1). The profile is
recorded in `<config dir>/profile`, and the systemd unit's `Description` ends in
`(profile bob)`. Without `--name`, names, paths and file contents are exactly
what earlier installers produced.

**Enroll the profile as the right Heimdall user.** Enrollment approves the
bridge for whichever Heimdall account is signed in to the browser that opens the
link. For a second user's profile, open the link in a browser where *that* user
is signed in (another browser profile or a private window), or hand the link and
code to them. Each bridge only ever acts for the account that approved it. To
enroll later, run the profile's own `<config dir>/enroll.sh`.

**Manage a profile by passing the same `--name` again.** `--uninstall` and
`--re-enroll` act only on the bridge named by `--hub` plus `--name`; without
`--name` they act on the default bridge, never on a profile:

```bash
# Re-enroll only bob's bridge (e.g. approve it as a different user)
bash scripts/install.sh --hub https://hub.example.com --name bob --re-enroll

# Remove only bob's bridge; the default bridge keeps running
bash scripts/install.sh --hub https://hub.example.com --name bob --uninstall
```

As for the default bridge, `--uninstall` removes the profile's service and its
`<data dir>/bin` and keeps its credential, config and agent data
(`--uninstall --dry-run` names both), so re-installing with the same `--name`
picks the enrollment back up. Migration of a legacy (pre per-Hub)
`heimdall-bridge` service only ever happens for the default bridge; installing a
profile never retires or copies an existing service or credential.

**Termux does not support profiles.** One Termux install runs one bridge, the
runit service `ham-bridge` (see [Bridge on Android](#appendix--bridge-on-android-termux)),
so `install.sh` refuses `--name`/`HEIMDALL_BRIDGE_NAME` there with an error
before it changes anything. Use a separate Android user or device instead.
The Windows installer (2.1.1) does not take a profile name yet.

**Provider extensions are shared by every bridge of the OS user.** Each bridge
ships its own copy of the Heimdall provider extensions in
`<data dir>/extensions`, but the place the agent CLIs *register* a plugin is per
OS user, not per bridge: Claude Code's plugin and marketplace settings under
`~/.claude`, the Codex plugin marketplace under `~/.codex`, and the Antigravity
(`agy`) plugin list. All bridges of one OS user, profiles included, therefore
share a single registration, pointing into one bridge's `extensions` directory.
Installing the extension from a bridge follows a **no-downgrade rule**:

- If the provider already has the Heimdall extension registered and enabled at
  the **same or a newer** version than the one this bridge ships, the install
  succeeds and the registration is **left unchanged** (it reports *already
  installed … registration left unchanged*). An older bridge therefore never
  re-points the shared registration to its own older copy.
- If the registered version is **older**, unknown, disabled, broken or absent,
  the install registers this bridge's copy as before and verifies it.

In practice: with all bridges on the same release, nothing changes. With
versions skewed, the newest bridge's extension stays registered and older
bridges use it too. Keep profiles on the same release (let self-update run, or
update each one). `--uninstall` keeps `<data dir>/extensions`, so it never breaks
the shared registration; deleting a profile's data directory by hand can, if the
registration points into it. In that case install the provider extension again
from a remaining bridge.

### 2.2 What the bridge needs

| Component | Purpose |
|-----------|---------|
| `ham-bridge` | Odin binary — agent supervisor, shell job executor, fs explorer |
| `ham-pty-host` | Rust binary — spawns agent CLIs in real PTYs (replaces tmux wrapper) |
| `ham-ctl` | CLI used by agents to read/send messages, update tasks, etc. |
| libcurl (built in) | HTTPS client for every bridge → hub REST call; linked statically at the pinned version (`nix/libcurl-pin.json`), nothing to install |
| `socat` | TLS transport for the bridge → hub WebSocket (default backend; not bundled — system `PATH`) |
| `openssl` | Legacy fallback WebSocket TLS transport (`HAM_TLS_BACKEND=s_client`; not bundled — system `PATH`) |
| The agent CLI | `claude`, `codex`, or any other supported CLI |

### 2.3 Build dependencies

**Nix (recommended)**

Same Nix setup as the hub. The bridge and pty-host are built from the same flake.

**Manual build dependencies**

| Dependency | Version | Purpose |
|------------|---------|---------|
| Odin compiler | ≥ 2024-11 (LLVM 18/21) | Compiles bridge, ctl |
| Rust toolchain | stable (≥ 1.77) | Compiles ham-pty-host |
| cargo | (with Rust) | Rust build tool |
| libcurl (dev headers not needed) | the pin in `nix/libcurl-pin.json` (≥ 8.11 accepted unpinned) | HTTPS client (`src/lib/httpc`; `nix develop` provides the pinned build) |
| socat | ≥ 1.7 | Bridge → hub WebSocket TLS tunnel |
| openssl / libssl | ≥ 1.1 | WebSocket TLS; socat OpenSSL engine |

### 2.4 Building

**With Nix**

```bash
# Build bridge binary (links the pinned libcurl's shared library from the store;
# socat + openssl on PATH via wrapProgram)
nix build .#ham-bridge

# Release binaries for the public tarballs (no nix store references — these are
# what the release workflow ships; REQ-INST-16). Linux: fully static musl ELFs
# with the pinned libcurl + OpenSSL 3 + zlib linked in; macOS: the same libraries
# static, only system frameworks dynamic; ham-pty-host fully static.
nix build .#release-ham-bridge .#release-ham-ctl .#release-ham-pty-host .#release-heimdall

# Build pty-host (Rust — hermetic crane build)
nix build .#ham-pty-host

# Build CLI
nix build .#ham-ctl

# Build the heimdall management CLI (enroll/status/service/update)
nix build .#ham-manager

# Or run the bridge directly (sets all required env vars automatically)
nix run .#bridge -- --hub https://hub.example.com --bridge-token-file ~/.config/heimdall/bridge-token
```

**Manual build**

```bash
# Bridge (Odin)
odin build src/bridge -collection:odin_test=src -out:./bin/ham-bridge

# CLI (Odin)
odin build src/ctl -collection:odin_test=src -out:./bin/ham-ctl

# Management CLI (Odin) — the `heimdall` command used by sections 2.1/2.5
odin build src/manager -collection:odin_test=src -out:./bin/heimdall

# pty-host (Rust — must be in tools/pty_host/)
cd tools/pty_host && cargo build --release
cp target/release/ham-pty-host ~/bin/ham-pty-host
```

### 2.5 First-time enrollment

Enrollment is **browser-approved**. This machine asks the hub for a short code, prints
it together with a link and a key fingerprint, and a human approves it in a browser; the
hub then delivers an expiring access credential (`hba_…`) to this machine directly.

**There is no enrollment token.** Nothing is created on the hub beforehand, and nothing
secret is copied between machines — so there is no secret to paste, mistype, or leave in
shell history. If you are looking for `ham-ctl bridge enroll-token --new`, the `hbe_`
one-time token, or `heimdall enroll <token>`, all three are **deleted**.

**Enrollment must be completed before the bridge can connect** — the bridge will refuse
to start (or will immediately exit) if it has no valid credential file. Once enrollment
is done, start (or restart) the bridge normally using the same file; the bridge refreshes
its own credential and no re-enrollment is needed unless the file is lost or the bridge
is explicitly revoked.

> **Order matters:** run `ham-bridge enroll` first, then start `ham-bridge`. You cannot
> enroll through a running bridge instance — enrollment is a one-shot CLI command that
> writes the credential file and then exits.

**Enroll the bridge on the device**

```bash
mkdir -p ~/.config/heimdall
ham-bridge enroll \
  --hub https://hub.example.com \
  --bridge-token-file ~/.config/heimdall/bridge-token
# → Prints a link, a short code and a key fingerprint. Open the link on any device,
#   check the code and fingerprint match what this machine shows, and approve.
#   Writes the hba_ credential to ~/.config/heimdall/bridge-token (mode 0600) and
#   records the hub URL and bridge id in ~/.config/heimdall/config.toml.
#   The command exits when enrollment is complete.
#
#   Add --headless if this machine has no browser of its own.
```

`--hub` takes the **Hub API origin**. The Hub's `--ui-origin` setting supplies the
browser URL in the authorize response; clients never derive one hostname from the
other. `HAM_BRIDGE_HUB_URL` sets the Hub origin from the environment.

**Re-enrolling: reuse the bridge or register a new one.** When the config already
records a bridge id (`daemon_id`) for this hub, `ham-bridge enroll` offers that id to
the approver for reuse. The id is only a hint: the approval page shows it only to its
owner, and the approver chooses. Reusing it keeps the bridge's id, name and history.
The previous identity, credential and config stay in place until the hub commits the
new enrollment, and a rollback (denied, expired, or the vault key was never
delivered) restores them. `--reuse-bridge <brg_id>` offers another of your bridges.
`--new-bridge` offers none. The two flags are mutually exclusive. The command prints
the outcome as `Re-enrolled existing bridge <id>` or `Registered new bridge <id>`.
`install.sh --re-enroll` keeps the config so the previous id is offered, and
`install.sh --new-bridge` (or `enroll.sh --new-bridge`) registers a new bridge.

**Credential shapes, because the distinction is a security decision and not a naming
detail:** `hba_` is the expiring access credential and the only shape that
authenticates. `hbf_` is a refresh credential, accepted at the refresh endpoint alone.
`hbr_` is the **legacy** non-expiring token — no longer minted and no longer accepted; a
bridge still carrying one is told to re-enroll rather than given a generic rejection.

**Step 3 — Configure vault encryption**

Vault encryption is set up in the UI, not on the command line:

1. Enable encryption once: **Settings → Bridges → Enable Encryption**, and choose
   the master password that protects the vault key in your browser.
2. Unseal each bridge from **Settings → User Vault → Unseal**. The browser delivers the
   key to that bridge (enrollment does the same for a bridge approved while the vault
   is unlocked), and the bridge keeps it in its own per-bridge keyring/Keychain entry
   (see above), so a restart does not need another unseal.

Agents spawned by a bridge get the key from that bridge on demand (`ham-ctl` asks
it over the local socket), so they pick up an unseal without a respawn.
`HEIMDALL_VAULT_KEY=<64-hex>` is honoured by `ham-ctl` only as a **single-bridge
development override**; do not use it for normal operation.

There is no key file and no `vault` command in the `heimdall` CLI any more. An old
`~/.config/heimdall/vault_key` left over from earlier releases is ignored (it is not
deleted); you may remove it.

**Step 4 — Start (or restart) the bridge normally**

After enrollment the bridge is started exactly the same way every time — just point it
at the token file. No enrollment flags are needed again.

```bash
ham-bridge \
  --hub https://hub.example.com \
  --bridge-token-file ~/.config/heimdall/bridge-token \
  --port 49323

# Or, if you set up the systemd/launchd service (sections 2.8–2.9):
systemctl --user restart heimdall-bridge   # Linux
launchctl kickstart -k gui/$(id -u)/works.earendil.heimdall-bridge  # macOS
```

The bridge reads the token file on every start and reconnects to the hub automatically.
You never need to touch the hub again for this device unless you deliberately revoke
the token.

### 2.6 Bridge token file

The token file is a plain text file containing a single `hbr_…` token:

```
hbr_18abc...
```

- Keep it at mode `0600` (`chmod 600 ~/.config/heimdall/bridge-token`).
- The path is passed to `ham-bridge` via `--bridge-token-file`.
- Losing it requires re-enrollment (Step 1–2 above).
- To revoke a bridge, delete the token record on the hub:
  `ham-ctl bridge revoke --bridge-id <id>`.

### 2.7 Required environment variables

The bridge needs these env vars set (or passed via `nix run .#bridge` which sets them
automatically):

```bash
# Path to ham-pty-host binary
export HEIMDALL_HAM_PTY_HOST_BIN=/usr/local/bin/ham-pty-host

# Enable pty-host agent runtime (recommended; set false to fall back to tmux)
export HEIMDALL_BRIDGE_PTY_HOST=true

# Path to ham-ctl binary (agents call this to communicate with hub)
export HEIMDALL_HAM_CTL_BIN=/usr/local/bin/ham-ctl
```

### 2.8 Systemd user service (Linux bridge)

Create `~/.config/systemd/user/heimdall-bridge.service`:

```ini
[Unit]
Description=Heimdall Bridge
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ham-bridge \
    --hub https://hub.example.com \
    --bridge-token-file %h/.config/heimdall/bridge-token \
    --port 49323 \
    --local-endpoint-port 49324 \
    --local-run-dir /tmp/heimdall-bridge-local
Environment=HEIMDALL_HAM_PTY_HOST_BIN=/usr/local/bin/ham-pty-host
Environment=HEIMDALL_BRIDGE_PTY_HOST=true
Environment=HEIMDALL_HAM_CTL_BIN=/usr/local/bin/ham-ctl
Restart=on-failure
RestartSec=5s
KillMode=process

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now heimdall-bridge
# Check status
systemctl --user status heimdall-bridge
journalctl --user -u heimdall-bridge -f
```

### 2.9 launchd agent (macOS bridge)

Create `~/Library/LaunchAgents/works.earendil.heimdall-bridge.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>works.earendil.heimdall-bridge</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/ham-bridge</string>
    <string>--hub</string>
    <string>https://hub.example.com</string>
    <string>--bridge-token-file</string>
    <string>/Users/you/.config/heimdall/bridge-token</string>
    <string>--port</string>
    <string>49323</string>
    <string>--local-endpoint-port</string>
    <string>49324</string>
    <string>--local-run-dir</string>
    <string>/tmp/heimdall-bridge-local</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HEIMDALL_HAM_PTY_HOST_BIN</key>
    <string>/usr/local/bin/ham-pty-host</string>
    <key>HEIMDALL_BRIDGE_PTY_HOST</key>
    <string>true</string>
    <key>HEIMDALL_HAM_CTL_BIN</key>
    <string>/usr/local/bin/ham-ctl</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>Crashed</key>
    <true/>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>StandardOutPath</key>
  <string>/tmp/heimdall-logs/heimdall-bridge.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/heimdall-logs/heimdall-bridge.err.log</string>
</dict>
</plist>
```

```bash
mkdir -p /tmp/heimdall-logs
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/works.earendil.heimdall-bridge.plist
launchctl kickstart -k gui/$(id -u)/works.earendil.heimdall-bridge
# Check status
launchctl print gui/$(id -u)/works.earendil.heimdall-bridge
tail -f /tmp/heimdall-logs/heimdall-bridge.err.log
```

### 2.10 Home Manager module (NixOS / nix-darwin bridge)

The flake ships a Home Manager module for declarative bridge setup:

```nix
{
  inputs.heimdall.url = "github:tanmayv/heimdall-agent-manager";

  homeConfigurations.you = home-manager.lib.homeManagerConfiguration {
    modules = [
      inputs.heimdall.homeModules.default
      {
        programs.heimdall = {
          enable = true;
          packageNames = [ "bridge" "ctl" "pty-host" ];

          bridge = {
            enable = true;
            hubUrl = "https://hub.example.com";
            # Path to the enrolled hba_ credential written by `ham-bridge enroll --hub`
            tokenFile = "/home/you/.config/heimdall/bridge-token";
            port = 49323;
          };

          ctl.daemonUrl = "http://127.0.0.1:49323";
        };
      }
    ];
  };
}
```

After `home-manager switch`, a systemd user service (Linux) or launchd agent (macOS)
named `heimdall-bridge` is created and started automatically.

---

### 2.11 Bridge self-update

When the Hub asks a bridge to update, the bridge downloads the release bundle for its
target, checks its SHA-256, extracts it into `DATA_DIR/updates/stage` and runs the
**staged** bundle's `scripts/apply-bridge-update.sh` (the update supervisor). The
supervisor stops the bridge and its PTY hosts, swaps `bin/` atomically, restarts the
service and polls the bridge's health endpoint; if the bridge is not healthy in time it
restores `bin.bak` and writes `logs/update_rollback.log`. It needs only bash, POSIX
userland, `ps`, `tar`, `curl` and the service manager (`systemctl --user`, `launchctl`
or Termux `sv`); no Python or Perl.

#### Caller interface

The supervisor is always the copy shipped with the version being installed, so it
must work for every bridge that may call it. The caller says what it is:

| Flag | Meaning |
| --- | --- |
| `--interface N` | Caller contract version. Absent means `1`, the original argv. Current callers send `2`. |
| `--from-version VER` | Version of the running bridge. Required by interface 2. |
| `--to-version VER` | Version being installed. Required by interface 2. |

- **Newer interface.** An `--interface` above the newest one the script supports
  (`2`), a non-numeric value, or interface 2 without both versions exits with code `2`
  and a message on stderr, before anything is stopped, cleaned up or swapped.
- **Legacy callers.** Bridges released before interface 2 call the supervisor without
  `--from-version`. It logs `Legacy caller (interface 1, no --from-version)` and runs
  the version-independent flow unchanged.
- **Version hooks.** The section `Version hooks` in `apply-bridge-update.sh`
  (`run_version_hooks`) is the one place for release-specific update logic: a `case` on
  `FROM_VERSION` / `TO_VERSION` for exact versions and globs, and
  `version_before` / `version_at_least` (SemVer 2.0 precedence, `semver_compare`) for
  ranges. Hooks run before the bridge is stopped and log the upgrade direction; a hook
  that must abort exits non-zero and leaves the running bridge untouched. Range hooks
  never match a version that is not SemVer, and legacy callers get no hooks, so a fix
  they need belongs in the version-independent flow.
- **PTY cleanup mode.** `--stop-pty-hosts-only` (run by the bridge before it starts
  the detached supervisor) accepts the same three flags and runs the same hooks first.

```bash
apply-bridge-update.sh --interface 2 --from-version 0.5.6 --to-version 0.5.7 \
  --data-dir ~/.local/share/heimdall --stage-dir ~/.local/share/heimdall/updates/stage \
  --bridge-port 49323 --bridge-pid 12345
```

`apply-bridge-update.sh --help` lists every flag.

## Quick-start checklist

### Hub (once)
- [ ] Build or install `ham-hub`, `ham-ctl`
- [ ] Create a data directory and run `ham-hub --db … --migrations-dir …`
- [ ] Put a TLS-terminating reverse proxy in front (nginx/Caddy/Tailscale)
- [ ] Confirm the API is reachable: `curl https://hub.example.com/api/v1/health`

### Each bridge device (once per device)
Recommended — the quick install (section 2.1) handles the first three items:
- [ ] Run the one-line installer:
      `curl -fsSL https://raw.githubusercontent.com/tanmayv/heimdall-agent-manager/main/scripts/install.sh | bash -s -- --hub https://hub.example.com`
- [ ] Enroll: `ham-bridge enroll --hub https://hub.example.com` — approve the
      printed link and short code in a browser. Nothing to create on the hub first.
- [ ] Start the bridge service (systemd user service or launchd agent)
- [ ] Verify with `heimdall status`; confirm the bridge appears in the hub UI
      or via `ham-ctl bridge list`

Manual path (sections 2.2–2.10, for source/air-gapped setups):
- [ ] Build or install `ham-bridge`, `ham-pty-host`, `ham-ctl`
- [ ] Install runtime dependencies: `socat`, `openssl`
- [ ] Enroll: `ham-bridge enroll --hub <hub-origin> --bridge-token-file ~/.config/heimdall/bridge-token`
- [ ] Set `HEIMDALL_HAM_PTY_HOST_BIN`, `HEIMDALL_BRIDGE_PTY_HOST=true`, `HEIMDALL_HAM_CTL_BIN`

### Subsequent runs
The bridge reads `--bridge-token-file` on startup and reconnects automatically.
Re-enrollment is only needed if the token file is lost or the bridge is revoked.

---

## Appendix — Bridge on Android (Termux)

A bridge can run on an Android phone or tablet inside [Termux](https://termux.dev),
supervised by `termux-services` (runit). It uses the dedicated `termux-arm64` release
bundle (`heimdall-local-termux-arm64-<version>.tar.gz`, from v0.3.29). The bridge detects
Termux at run time from `TERMUX_VERSION` or a `$PREFIX` under `/data/data/com.termux`.

**Why a separate bundle:** Android runs every app process, Termux included, under a
seccomp allowlist derived from bionic, and kills the process (`SIGSYS`) on any other
syscall. glibc calls `set_robust_list` at process start before `main`, and Android
blocks that call, so a glibc-static binary dies on launch. The `termux-arm64` bundle's
binaries are linked statically against musl, which makes no blocked call at start-up;
`scripts/release/android-seccomp-probe.sh` checks this. (Release binaries up to v0.5.3
were glibc-static or glibc-linked on `linux-arm64`; since the static-libcurl build the
`linux-arm64` binaries are musl-static too, built by the same recipe. The termux bundle
stays separate because its build identifies itself as `termux-arm64` for self-update.)

### Requirements

- Android 12 or newer (tested on Android 15), aarch64.
- The **Termux:API** Android app (from the same source as Termux itself, F-Droid or
  GitHub; the two must match), plus the matching package, and `termux-services`:

  ```bash
  pkg install termux-api termux-services
  # Restart Termux once so the service daemon starts.
  ```

- `termux-keystore` must work. The installer refuses to run on Termux without it.

### How the vault key is stored on Android

Termux has no kernel keyring (no keyutils, and app processes are seccomp-blocked
from it), and the bridge never writes a plaintext key file. Instead:

1. On the first unseal, the bridge creates a non-exportable RSA-2048 key in the
   Android Keystore under the alias `heimdall-bridge-<bridge_id>`.
2. It signs a fixed per-bridge label with that key and derives an AES-256 key
   (HKDF-SHA256) from the signature.
3. It seals the vault key with AES-256-GCM into
   `~/.config/heimdall/bridges/<bridge_id>/vault_key.sealed` (mode `0600`).

On restart the bridge re-derives the AES key through the Keystore and unwraps the
file once; after that the key is served from the bridge's locked memory. The file is useless without this device's Keystore key. Several bridges on one
device each get their own alias and their own file.

**Fail closed:** if `termux-keystore` is missing, fails or times out, the vault key
is not persisted (enrollment aborts and purges it). Each unseal also signs twice and
refuses if the two signatures differ, then reopens the file it wrote; enrollment
re-checks the file itself before restarting the service. A restarted bridge then reports
`locked`, and a WARN in its log points at **Settings → User Vault → Unseal**.

| Action | Effect on Android |
|--------|-------------------|
| Unseal (Settings → User Vault) | Writes `vault_key.sealed`; creates the Keystore key on first use, or when `termux-keystore list` shows it was removed. If signing fails while the key still exists, the unseal fails and the existing key and file are left untouched |
| Lock (`vault.lock`) | Deletes `vault_key.sealed` and wipes the key from memory; the Keystore key stays |
| Reset (`vault.reset`) | As lock, and also `termux-keystore delete heimdall-bridge-<bridge_id>` |

### Install and enroll

The installer supports Termux directly. It verifies `termux-keystore` and
`termux-services`, installs the `termux-arm64` bundle, creates the runit service
`$PREFIX/var/service/ham-bridge` (`run` + `log/run`, same environment as the systemd
unit), enables it with `sv-enable`, and enrolls:

```bash
pkg install curl socat termux-api termux-services   # then restart Termux once
curl -fsSL https://raw.githubusercontent.com/tanmayv/heimdall-agent-manager/main/scripts/install.sh \
  | bash -s -- --hub https://hub.example.com
```

If you pass `--version` for a release older than v0.3.29, which has no Termux bundle, the
installer prints a WARN and installs `linux-arm64` instead. That bundle will not start
under Android's seccomp, so drop `--version` or pass a newer release.

One Termux install runs **one** Hub: the released bridge restarts exactly
`$PREFIX/var/service/ham-bridge` after enrollment, so a second `--hub` is refused until
the first is removed (`install.sh --hub <url> --uninstall`, which keeps the enrollment).
For the same reason Termux refuses bridge profiles (`--name` / `HEIMDALL_BRIDGE_NAME`,
see 2.1.2).
Per-Hub config lives in `~/.config/heimdall/bridges/<name>/`, binaries and data in
`~/.local/share/heimdall/bridges/<name>/`.

On approval the bridge seals the delivered vault key, reads it back through the
Keystore, and runs `sv restart "$PREFIX/var/service/ham-bridge"`.

Logs: `tail -f "$PREFIX/var/log/sv/ham-bridge/current"`. Status: `sv status ham-bridge`.

If the bridge reports `locked` after a restart (for example after Termux:API was
reinstalled, which wipes its Keystore keys), unseal it again from
**Settings → User Vault → Unseal**.

### Self-update

The update flow and the supervisor's caller interface are described in
[2.11 Bridge self-update](#211-bridge-self-update). A Termux bridge updates only to the `termux-arm64` bundle. It never falls back to
`linux-arm64`, because a glibc `linux-arm64` bundle (every release up to v0.5.3) dies
under Android's seccomp filter (`set_robust_list`, SIGSYS) and leaves a bridge that
cannot restart.

- **Release target.** The termux bundle is built with
  `-define:HAM_RELEASE_TARGET=termux-arm64`. Its bridge reports `target: termux-arm64`
  in its hello, and the Hub stores it as `os: termux`, `arch: arm64`. A `linux-*` build
  that finds itself under Termux also reports `termux-<arch>`, but it **refuses**
  self-update: reinstall it with `install.sh`.
- **Hub catalog.** The Hub resolves updates from the manifest at
  `HEIMDALL_UPDATE_MANIFEST_PATH`. Add a `termux-arm64` entry under `targets` that
  points to `heimdall-local-termux-arm64-<tag>.tar.gz` and gives its `SHA256SUMS`
  digest:

  ```json
  {"version": "0.3.30", "targets": {
    "linux-arm64":  {"tarball_url": ".../heimdall-local-linux-arm64-v0.3.30.tar.gz",  "sha256": "..."},
    "termux-arm64": {"tarball_url": ".../heimdall-local-termux-arm64-v0.3.30.tar.gz", "sha256": "..."}}}
  ```

  If the manifest has no `termux-arm64` entry, **Settings → Bridges** shows
  "v0.3.30 not available for termux-arm64" (`update_artifact_available: false`), and
  starting an update is rejected with "not available for this target".
- **Upgrade the Hub first.** Hubs at v0.3.29 or older do not know `termux-arm64`. They
  refuse the hello of a newer Termux bridge with "unsupported bridge target", so the
  bridge stays offline until the Hub is upgraded.
- **Defence in depth.**
  - The bridge refuses a `download_url` whose file name is another target's
    `heimdall-local-<target>` bundle.
  - Under Termux, `apply-bridge-update.sh` refuses any staged bundle whose
    `METADATA.json` target is not `termux-*`, before it stops anything.
  - The bridge runs the staged bundle's copy of that script, so this also covers
    v0.3.29 Termux bridges, which still report `linux-arm64`.
- **Service.** `apply-bridge-update.sh` drives the runit service with
  `sv down` / `sv up "$PREFIX/var/service/ham-bridge"` and never calls `systemctl`.
  `sv down` keeps runsv from restarting the old binary while it is being replaced.
  On a failed health check it rolls back and runs `sv up` again.
- **`heimdall update`.** Uses the same target. On GitHub it reports
  "<tag> is not available for target termux-arm64" when the release has no termux
  asset. On a `--hub` mirror it aborts when `SHA256SUMS` has no
  `heimdall-local-termux-arm64.tar.gz` entry. It brackets the binary swap with
  `sv down|up` instead of systemctl.
