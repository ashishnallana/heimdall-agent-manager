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

# Start the hub (replace /path/to/ with your actual paths)
ham-hub \
  --db /var/lib/heimdall/hub.db \
  --migrations-dir /path/to/share/ham-hub/migrations \
  --port 8081 \
  --host 127.0.0.1
```

The hub binds to `127.0.0.1` by default. Put nginx/Caddy in front to expose it over
HTTPS. The web UI is served as a static bundle and can be served by the same reverse proxy.

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
ExecStart=/usr/local/bin/ham-hub \
    --db /var/lib/heimdall/hub.db \
    --migrations-dir /usr/local/share/ham-hub/migrations \
    --port 8081 \
    --host 127.0.0.1
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
                --port 8081 --host 127.0.0.1
            '';
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
2. **Authentik:** create a **separate** Proxy Provider and Application for `hub-preview.example.com`:
   - *Mode:* **Forward auth (single application)**. This gives a host-only cookie, so the preview
     host's cookie never authenticates the hub. Do **not** use domain-level mode here.
   - *Authorization flow:* an implicit-consent flow (the redirect must complete silently inside the
     preview iframe).
   - **"Intercept header authentication": OFF.** Otherwise Authentik consumes the `Authorization`
     header that your previewed apps send to their own backends.
   - Bind the same users/group that may use Heimdall. The hub additionally enforces that each
     preview is opened only by the session owner.
3. **Reverse proxy:** forward auth in front of the hub, **overriding** the identity headers. The hub
   trusts `X-authentik-*` only from `--trusted-proxy-cidr` addresses, and the proxy must never pass
   through client-supplied values.
4. **Same-site note:** if the preview host shares the hub's registrable domain (as in this example),
   the hub's CSRF guard (Origin / `Sec-Fetch-Site` checks on mutating requests and WebSocket handshakes)
   is what stops previewed code from acting through your browser session. Keep `--ui-origin` set
   correctly. Keep the Authentik session cookie `HttpOnly` and, if possible, host-only.

**nginx (NixOS) example**

```nix
services.nginx.virtualHosts."hub-preview.example.com" = {
  enableACME = true;
  forceSSL = true;
  # Authentik embedded/standalone outpost endpoints for this host
  locations."/outpost.goauthentik.io" = {
    proxyPass = "http://127.0.0.1:9000/outpost.goauthentik.io";
    extraConfig = ''
      proxy_set_header Host $host;
      proxy_set_header X-Original-URL $scheme://$http_host$request_uri;
      proxy_pass_request_body off;
      proxy_set_header Content-Length "";
      auth_request_set $auth_cookie $upstream_http_set_cookie;
      add_header Set-Cookie $auth_cookie;
    '';
  };
  locations."@goauthentik_proxy_signin".extraConfig = ''
    internal;
    add_header Set-Cookie $auth_cookie;
    return 302 /outpost.goauthentik.io/start?rd=$scheme://$http_host$request_uri;
  '';
  # Only preview paths reach the hub; everything else is 404 at the edge.
  locations."/".return = "404";
  locations."/p/" = {
    proxyPass = "http://127.0.0.1:8081";   # the hub API listener, not a UI/static layer
    proxyWebsockets = true;
    extraConfig = ''
      auth_request     /outpost.goauthentik.io/auth/nginx;
      error_page 401 = @goauthentik_proxy_signin;
      auth_request_set $auth_cookie $upstream_http_set_cookie;
      add_header Set-Cookie $auth_cookie;

      # OVERRIDE identity headers from the auth response; never pass client values.
      auth_request_set $ak_username $upstream_http_x_authentik_username;
      auth_request_set $ak_name     $upstream_http_x_authentik_name;
      auth_request_set $ak_email    $upstream_http_x_authentik_email;
      proxy_set_header X-authentik-username $ak_username;
      proxy_set_header X-authentik-name     $ak_name;
      proxy_set_header X-authentik-email    $ak_email;

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
		reverse_proxy /outpost.goauthentik.io/* http://127.0.0.1:9000
		forward_auth http://127.0.0.1:9000 {
			uri /outpost.goauthentik.io/auth/caddy
			copy_headers X-Authentik-Username X-Authentik-Name X-Authentik-Email
			trusted_proxies private_ranges
		}
		reverse_proxy /p/* 127.0.0.1:8081 {
			flush_interval -1
		}
		respond 404
	}
}
```
Caddy's `copy_headers` sets these headers from the auth response. **Verify on your Caddy version** that a
client-supplied `X-Authentik-Username` is replaced or removed (send one with curl while signed in and check
the hub's access log). The hub must never see a client-chosen identity.

**Check it**

```bash
curl -sI https://hub-preview.example.com/p/anything/     # signed out: 302 to Authentik
# In a signed-in browser: https://hub-preview.example.com/api/v1/me must be 404, never hub JSON.
```

### 1.7 Single-user / VPN setup with dev-proxy (no TLS cert required)

> **When to use this:** You are the only user, the hub is reachable only through a
> private VPN (Tailscale, WireGuard, etc.) or a local network, and you do not want to
> manage TLS certificates. If the hub is publicly accessible on the internet, **do not
> use this approach** — use a real TLS terminator (nginx + ACME, Caddy, or Tailscale
> HTTPS) so that credentials and agent traffic are encrypted in transit.

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

---

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
toolchain, no source checkout. For an HTTPS or WSS hub, install `socat` first:

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
5. Registers and starts a user service
   (`~/.config/systemd/user/heimdall-bridge.service` on Linux,
   `~/Library/LaunchAgents/works.earendil.heimdall-bridge.plist` on macOS).
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

`socat` (the default bridge → hub TLS transport) is not bundled; install it
with your system package manager (`sudo apt install socat`,
`brew install socat`) if it is not already on `PATH`. `openssl` is likewise
not bundled: the `HAM_TLS_BACKEND=s_client` fallback resolves it from your
system `PATH`.

**Then enroll and let it hand off to the registered service:**

```bash
# 1. Configure vault encryption, so there is a key to unlock when you approve.
#    Replace the placeholder with your 64-character hexadecimal vault key.
heimdall vault set-key <64-hex>
heimdall vault status

# 2. On this device: enroll. Nothing is created on the hub
#    first, and there is no token to copy between machines — this machine prints a
#    link and a short code, you approve it in a browser, and the credential is
#    delivered here directly. Writes ~/.config/heimdall/bridge-token (mode 0600)
#    and updates config.toml with the hub URL. Add --headless if this machine has
#    no browser of its own.
#
#    The Hub supplies the browser origin. Enrollment receives any encrypted vault
#    key, restarts the registered service, and exits.
ham-bridge enroll --hub https://hub.example.com

# 3. From a second shell: enrollment, service state, hub connection, versions
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

### 2.2 What the bridge needs

| Component | Purpose |
|-----------|---------|
| `ham-bridge` | Odin binary — agent supervisor, shell job executor, fs explorer |
| `ham-pty-host` | Rust binary — spawns agent CLIs in real PTYs (replaces tmux wrapper) |
| `ham-ctl` | CLI used by agents to read/send messages, update tasks, etc. |
| `socat` | TLS transport for bridge → hub connection (default backend; not bundled — system `PATH`) |
| `openssl` | Legacy fallback TLS transport (`HAM_TLS_BACKEND=s_client`; not bundled — system `PATH`) |
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
| socat | ≥ 1.7 | Bridge → hub TLS tunnel |
| openssl / libssl | ≥ 1.1 | TLS; socat OpenSSL engine |

### 2.4 Building

**With Nix**

```bash
# Build bridge binary (bundles socat + openssl on PATH via wrapProgram)
nix build .#ham-bridge

# Release binaries for the public tarballs (fully static on Linux, no nix
# store references — these are what the release workflow ships; REQ-INST-16)
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

**Credential shapes, because the distinction is a security decision and not a naming
detail:** `hba_` is the expiring access credential and the only shape that
authenticates. `hbf_` is a refresh credential, accepted at the refresh endpoint alone.
`hbr_` is the **legacy** non-expiring token — no longer minted and no longer accepted; a
bridge still carrying one is told to re-enroll rather than given a generic rejection.

**Step 3 — Configure vault encryption**

The bridge receives its vault key from the browser: enrollment delivers it, and a
bridge that starts locked is unsealed from **Settings → Bridges → Unseal**. The
bridge keeps the key in its own per-bridge keyring/Keychain entry (see above). It
does **not** read `~/.config/heimdall/vault_key`: that file is shared by every
bridge of the OS user, so a bridge that only has it starts locked until unsealed.

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

## Appendix — Bridge on Android (Termux)

A bridge can run on an Android phone or tablet inside [Termux](https://termux.dev),
supervised by `termux-services` (runit). It uses the dedicated `termux-arm64` release
bundle (`heimdall-local-termux-arm64-<version>.tar.gz`, from v0.3.29). The bridge detects
Termux at run time from `TERMUX_VERSION` or a `$PREFIX` under `/data/data/com.termux`.

**Why a separate bundle:** Android runs every app process, Termux included, under a
seccomp allowlist derived from bionic, and kills the process (`SIGSYS`) on any other
syscall. The `linux-arm64` binaries are statically linked against glibc, which calls
`set_robust_list` at process start before `main`. Android blocks that call, so they die
on launch. The `termux-arm64` bundle has the same binaries linked statically against
musl, which makes no blocked call at start-up. Each release checks this in CI with
`scripts/release/android-seccomp-probe.sh`.

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
`locked`, and a WARN in its log points at **Settings → Bridges → Unseal**.

| Action | Effect on Android |
|--------|-------------------|
| Unseal (Settings → Bridges) | Writes `vault_key.sealed`; creates the Keystore key on first use, or when `termux-keystore list` shows it was removed. If signing fails while the key still exists, the unseal fails and the existing key and file are left untouched |
| Lock (`vault.lock`) | Deletes `vault_key.sealed` and wipes the key from memory; the Keystore key stays |
| Reset (`vault.reset`) | As lock, and also `termux-keystore delete heimdall-bridge-<bridge_id>` |

### Install and enroll

The installer supports Termux directly. It verifies `termux-keystore` and
`termux-services`, installs the `termux-arm64` bundle, creates the runit service
`$PREFIX/var/service/ham-bridge` (`run` + `log/run`, same environment as the systemd
unit), enables it with `sv-enable`, and enrolls:

```bash
pkg install curl python socat termux-api termux-services   # then restart Termux once
curl -fsSL https://raw.githubusercontent.com/tanmayv/heimdall-agent-manager/main/scripts/install.sh \
  | bash -s -- --hub https://hub.example.com
```

If you pass `--version` for a release older than v0.3.29, which has no Termux bundle, the
installer prints a WARN and installs `linux-arm64` instead. That bundle will not start
under Android's seccomp, so drop `--version` or pass a newer release.

One Termux install runs **one** Hub: the released bridge restarts exactly
`$PREFIX/var/service/ham-bridge` after enrollment, so a second `--hub` is refused until
the first is removed (`install.sh --hub <url> --uninstall`, which keeps the enrollment).
Per-Hub config lives in `~/.config/heimdall/bridges/<name>/`, binaries and data in
`~/.local/share/heimdall/bridges/<name>/`.

On approval the bridge seals the delivered vault key, reads it back through the
Keystore, and runs `sv restart "$PREFIX/var/service/ham-bridge"`.

Logs: `tail -f "$PREFIX/var/log/sv/ham-bridge/current"`. Status: `sv status ham-bridge`.

If the bridge reports `locked` after a restart (for example after Termux:API was
reinstalled, which wipes its Keystore keys), unseal it again from
**Settings → Bridges → Unseal**.
