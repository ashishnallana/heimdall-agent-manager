# Architecture

The detailed architecture reference. Read [AGENTS.md](../AGENTS.md) first for the working rules;
this document explains how the pieces fit together and where to open the code for each flow.
Everything here is derived from the source tree. Older design notes under `docs/` (and older
revisions of `AGENTS.md`) may mention `ham-daemon`, `ham-wrapper` or tmux-based launching: those
are **historical**. Agents are launched under a PTY by `ham-pty-host` (see
[Agent launch and bootstrap](#51-agent-launch-and-bootstrap)). The only tmux code left is the
small helper in [src/lib/tmux/tmux.odin](../src/lib/tmux/tmux.odin) (`send_text`,
`ensure_not_copy_mode`), imported by [src/lib/agent_runtime/runtime.odin](../src/lib/agent_runtime/runtime.odin)
and [src/dev_proxy/store.odin](../src/dev_proxy/store.odin).

Contents: [1 Components](#1-components-and-binaries) · [2 Hub](#2-hub-internals) ·
[3 Bridge](#3-bridge-internals) · [4 Shared libs](#4-shared-libraries-srclib) ·
[5 Key flows](#5-key-flows) · [6 Storage and vault](#6-storage-and-the-vault-boundary) ·
[7 Tests](#7-tests)

---

## 1. Components and binaries

Odin code uses one import collection, `odin_test`, rooted at `src/` (`import x "odin_test:lib/ws"`).
The flake builds each Odin binary from its package directory ([flake.nix](../flake.nix),
`packages` → `ham-hub`, `ham-bridge`, `ham-ctl`, `ham-dev-proxy`, `ham-test-agent`,
`ham-pty-host`, plus `release-*` variants).

| Binary | Source | Language | Role |
|---|---|---|---|
| `ham-hub` | [src/hub](../src/hub) (`main.odin`) | Odin | Central server: HTTP + WebSocket API, SQLite store, task engine, MCP surface, OIDC auth, metrics. One per deployment. |
| `ham-bridge` | [src/bridge](../src/bridge) (`main.odin`) | Odin | Per-machine agent that holds an outbound WebSocket to the hub, launches/stops agents and shells, serves the agent-local API, manages worktrees/filesystem/VCS. |
| `ham-pty-host` | [tools/pty_host](../tools/pty_host) (`tools/pty_host/src/main.rs`, `daemon.rs`) | Rust | Per-machine PTY daemon: spawns agent processes under a PTY, keeps a VT screen model, fans output out to attached clients over a unix socket. |
| `ham-ctl` | [src/ctl](../src/ctl) (`main.odin`) | Odin | The CLI. *Agent mode* ([agent_mode.odin](../src/ctl/agent_mode.odin)) talks to the local bridge with the instance token; *hub/user mode* ([hub_mode.odin](../src/ctl/hub_mode.odin)) talks to the hub directly. |
| `ham-dev-proxy` | [src/dev_proxy](../src/dev_proxy) | Odin | Local dev-only reverse proxy that signs in to a (mock) OIDC provider on behalf of a selected dev user and forwards to the hub ([proxy.odin](../src/dev_proxy/proxy.odin), [broker.odin](../src/dev_proxy/broker.odin)); has its own management UI/API ([ui.odin](../src/dev_proxy/ui.odin), [api.odin](../src/dev_proxy/api.odin)). |
| UI | [src/ui](../src/ui) (`main.tsx`) | TypeScript / React / Redux Toolkit | The web app, also packaged as the Electron desktop app ([src/ui/electron](../src/ui/electron), `main.cts`, `preload.cts`). Built by Vite ([vite.config.js](../vite.config.js)). |
| `ham-test-agent` | [src/test_agent](../src/test_agent) | Odin | Scripted stand-in for a provider CLI used by tests (see also [tools/mock_agent](../tools/mock_agent)). |
| `mcp_probe` | [src/mcp_probe](../src/mcp_probe) | Odin | Probe client for the hub's MCP endpoint. |

Supporting trees: [src/contracts](../src/contracts) (wire types shared by hub, bridge and ctl:
`envelope.odin`, `protocol.odin`, `pty_wire.odin`, `bridge.odin`, `extension.odin`, `errors.odin`, …),
[src/templates](../src/templates) (built-in agent role templates: coordinator, worker, reviewer,
soloist, curator, empty), [tools/gen_static_skills](../tools/gen_static_skills/main.odin) (code generator,
see below), [tools/vault_vectors](../tools/vault_vectors), [tools/mock-oidc](../tools/mock-oidc/README.md).

### Provider extensions

[extensions/](../extensions) ships one directory per supported agent CLI. Each registers hooks that
forward tool/permission/lifecycle events to the bridge as `ham.ext.v1` events:

- [extensions/claude-code](../extensions/claude-code) — `hooks/hooks.json`, [README](../extensions/claude-code/README.md)
- [extensions/codex](../extensions/codex) — `hooks/hooks.json`, [README](../extensions/codex/README.md), `fixtures/`
- [extensions/antigravity](../extensions/antigravity) — `hooks.json`, `plugin.json`, [README](../extensions/antigravity/README.md)

The flake copies `extensions/` into the bridge package (`$out/share/heimdall/extensions`). The bridge
detects, installs and reconciles them on the host (`src/bridge/provider_extension_*.odin`) and ingests
their events ([extension_ingest.odin](../src/bridge/extension_ingest.odin),
[extension_permission.odin](../src/bridge/extension_permission.odin)).

### Shipped prompts and skills

[src/prompts](../src/prompts) holds the text the hub injects into every agent run:
`bootstrap_agents.md` and `bootstrap_profile_guidance.md` (the generated `AGENTS.md`/`CLAUDE.md` an
agent sees), `skills/<name>/` (the canonical skills: `ham-ctl-reference`, `worker-task-management`,
`coordinator-task-management`, `heimdall-ctl-communication`, `memory-management-workflow`,
`search-command`, `heimdall-preview-setup`, `artifact-authoring`) and `workflows/*.json`
(built-in workflow definitions). At hub build time `tools/gen_static_skills` compiles the skills into
[static_skills_gen.odin](../src/hub/service/agent/static_skills_gen.odin) (flake.nix runs
`odin run tools/gen_static_skills -collection:odin_test=src -- src/prompts/skills src/hub/service/agent/static_skills_gen.odin`).

### Who talks to whom

```
                         ┌───────────────────────────── Browser / Electron UI ─────────────────────────────┐
                         │  Redux store, vault (WebCrypto), xterm.js panes                                   │
                         └──────┬───────────────────────────┬───────────────────────────┬───────────────────┘
                                │ HTTPS REST (/api/v1, cookie │ WebSocket: user event     │ WebSocket: pane /
                                │ session or bearer)          │ stream (useUserWebSocket) │ shell PTY binary frames
                                ▼                             ▼                           ▼
  ┌───────────────┐  HTTP  ┌──────────────────────────────────────────────────────────────────┐
  │ ham-dev-proxy │───────▶│                            ham-hub                                │
  │ (dev only)    │        │  transport/http → service/* → repository/sqlite (SQLite file)     │
  └───────────────┘        │  MCP endpoint, OIDC login, /metrics listener, reaper              │
  external MCP clients ───▶│                                                                  │
   (Ninjy connector)  HTTP └───────▲──────────────────────────────────────────────────────────┘
                                   │ one outbound WebSocket per bridge (bridge token `hbr_…`):
                                   │ JSON commands hub→bridge, heartbeats/results bridge→hub,
                                   │ binary PTY frames (never chunked), HTTP-over-WS relays
                          ┌────────┴─────────┐
                          │    ham-bridge    │  (one per machine/profile; service, tray, updater)
                          └─┬─────────┬────┬─┘
        AF_UNIX socket      │         │    │ child processes: git/jj, provider CLIs' extension hooks
   (src/lib/local_socket)   │         │    └──────────────▲──────────────────────────
                            │         │ local HTTP endpoint on 127.0.0.1:<port>
                            │         │ (agent API, /proxy/<session>/…, extension events)
                            │         ▼                    │
                  ┌─────────▼───┐  ┌────────────────┐      │ hooks (ham.ext.v1)
                  │ ham-pty-host│  │ ham-ctl (agent │──────┘
                  │ daemon      │  │ mode, per-agent│
                  └──┬──────────┘  │ shim + token)  │
        PTY (pty_wire│ frames)     └───────▲────────┘
                  ┌──▼────────────────┐    │ invoked by the agent
                  │ provider CLI      │────┘
                  │ (claude/codex/…)  │   each agent also gets a run dir with bootstrap files
                  └───────────────────┘
```

Transports in one line each: **UI↔hub** HTTPS + WebSocket; **bridge↔hub** a single bridge-initiated
WebSocket (no inbound port on the bridge host); **ham-ctl↔bridge** HTTP on loopback, or the `unix:`
endpoint over `src/lib/local_socket`; **bridge↔ham-pty-host** a framed protocol over an AF_UNIX
socket ([pty_host_client.odin](../src/bridge/pty_host_client.odin) ↔ [dproto.rs](../tools/pty_host/src/dproto.rs));
**ham-pty-host↔agent** a real PTY; **bridge→hub outbound HTTP** is libcurl via `src/lib/httpc`;
**preview/proxy** traffic is spliced through the hub over the existing bridge WebSocket
([local_proxy.odin](../src/bridge/local_proxy.odin), [bridge_proxy_relay.odin](../src/hub/transport/http/bridge_proxy_relay.odin)).

---

## 2. Hub internals

`main` in [src/hub/main.odin](../src/hub/main.odin) installs the crash logger, initialises libcurl,
handles subcommands (`ham-hub users …`), then calls into the `app` package.

Layering (dependencies point downward; each layer only imports the ones below it):

```
transport/http   handlers, router, middleware, WebSocket upgrade/streams
      │
service/*        business rules, one package per domain area
      │
repository/iface storage interfaces (Odin structs of procs)   domain  (pure types, errors, ids)
      │
repository/sqlite  implementations, migrations, unit of work
```

### `src/hub/app` — wiring and cross-cutting runtime

- [app.odin](../src/hub/app/app.odin), [wiring.odin](../src/hub/app/wiring.odin) — `App_Graph` builds every repository,
  service and handler group and connects them; [config_bind.odin](../src/hub/app/config_bind.odin) binds env/config to `Hub_Config`.
- MCP surface: `mcp_*.odin` (`mcp_catalog`, `mcp_task_control`, `mcp_task_mutations`, `mcp_chain_create`,
  `mcp_chain_messages`, `mcp_delegation`, `mcp_artifacts`, `mcp_resources`, `mcp_runtime`, `mcp_bridge`) bind
  `service/mcp` into the HTTP transport; the tool schema is [mcp_tools.json](../src/hub/transport/http/mcp_tools.json).
- [reaper.odin](../src/hub/app/reaper.odin) — periodic cleanup (stale sessions, bridges, shell sessions, logs);
  [reaper_metrics.odin](../src/hub/app/reaper_metrics.odin).
- Metrics: [metrics_listener.odin](../src/hub/app/metrics_listener.odin) (separate listener),
  [metrics_db_collectors.odin](../src/hub/app/metrics_db_collectors.odin).
- OIDC: [users_oidc.odin](../src/hub/app/users_oidc.odin) (`ham-hub users link-oidc|unlink-oidc|logout`); the login flow is
  `service/auth/oidc.odin`. The hub authenticates users **only** through OIDC (see [auth-oidc.md](auth-oidc.md)).
- [bridge_plans.odin](../src/hub/app/bridge_plans.odin) — bridge update plans.

### `src/hub/domain`

Plain types and errors, no I/O: `agent.odin`, `bridge.odin`, `taskchain.odin` (`Task_State`: `backlog`, `ready`,
`in_progress`, `in_review`, `done`, `cancelled`), `taskv2.odin`, `workflow_run.odin`, `mixed_work.odin`,
`project.odin`, `provider.odin`, `shell_session.odin`, `card.odin`, `action.odin`, `content.odin`, `search.odin`,
`billing.odin`, `user.odin`, `vault_directory.odin`, `errors.odin` (`Domain_Error`), `ids.odin`, and more.

### Repositories

- [repository/iface](../src/hub/repository/iface) — one interface per aggregate (`taskv2_repo.odin`, `taskchain_repo.odin`,
  `agent_repo.odin`, `content_repo.odin`, …) and [unit_of_work.odin](../src/hub/repository/iface/unit_of_work.odin).
- [repository/sqlite](../src/hub/repository/sqlite) — implementations (`*_repo_sqlite.odin`), connection handling
  ([conn.odin](../src/hub/repository/sqlite/conn.odin)), transactions ([tx.odin](../src/hub/repository/sqlite/tx.odin)),
  FTS search ([search_fts.odin](../src/hub/repository/sqlite/search_fts.odin), [fts_repair.odin](../src/hub/repository/sqlite/fts_repair.odin)),
  and numbered SQL migrations in [migrations/](../src/hub/repository/sqlite/migrations) (`001_foundation.sql` …),
  applied by `run_migrations` in [migrations.odin](../src/hub/repository/sqlite/migrations.odin). Migrations are bundled
  into the hub package under `share/ham-hub/migrations`.

### `src/hub/service/*`

| Package | Responsibility |
|---|---|
| [agent](../src/hub/service/agent) | Agent definitions and instances: create/prepare/restart, launch command, bootstrap manifest rendering, blockers, reconfiguration, live tool-activity stream; holds generated static skills. |
| [auth](../src/hub/service/auth) | OIDC login, user sessions and cookie/bearer resolution, preview-origin auth. |
| [billing](../src/hub/service/billing) | Plans, entitlements (e.g. shells, terminals), billing webhooks and metrics. |
| [bridge](../src/hub/service/bridge) | Bridge records and tokens, device enrollment (pending/atomic), credential rotation, update catalog and promoted releases. |
| [bridge_log](../src/hub/service/bridge_log) | Ingest and rendering of log lines pushed by bridges. |
| [bridge_runtime](../src/hub/service/bridge_runtime) | The live bridge WebSocket connections: command sink (`send_runtime_command`, `send_runtime_command_wait`), chunked command reassembly, runtime protocol. |
| [card](../src/hub/service/card) | Attention/action cards: projection from events, placement, attention notifications. |
| [content](../src/hub/service/content) | Conversations, messages, memories, templates, multi-question messages, title nudges, message delivery to agents. |
| [device_auth](../src/hub/service/device_auth) | RFC 8628 device-authorization grant used by bridge enrollment (codes, grants, approval page). |
| [events](../src/hub/service/events) | In-process user event bus (feeds the user WebSocket), attention debouncer, poll hints. |
| [issue](../src/hub/service/issue) | Issue tracker records and comments. |
| [mcp](../src/hub/service/mcp) | Hosted MCP server logic: registration, OAuth-style consent and delegation, capabilities, catalog/resource/task reads and mutations, worker broker. |
| [ownership](../src/hub/service/ownership) | Owner/tenant scoping checks used across services. |
| [project](../src/hub/service/project) | Projects, and the in-memory `Bridge_Runtime_Registry` (which bridge connection is live) — see [runtime-registry.md](runtime-registry.md). |
| [provider](../src/hub/service/provider) | Provider catalog, bridge provider state, models (effective/discovered), provider profiles. |
| [push](../src/hub/service/push) | Web Push enrollment, VAPID, payload encryption and send. |
| [search](../src/hub/service/search) | Cross-entity search service over the FTS indexes. |
| [shell_session](../src/hub/service/shell_session) | Interactive/background shell sessions: create, viewers, output fan-out, snapshots, retention, reaping. |
| [taskchain](../src/hub/service/taskchain) | Task chains (coordinator-owned groups of tasks): brief contract, control policy, review roles, placement recovery. |
| [taskv2](../src/hub/service/taskv2) | The Task System v2 engine: event-sourced task fold, leases, matcher/placement, review gate, merge-back, timers, workflows, wake effects. |
| [user](../src/hub/service/user) | User records and conversation launch preferences. |
| [vault_directory](../src/hub/service/vault_directory) | Server-side view of the device/vault directory (statements are verified, never decrypted). |

Also under `src/hub`: [bootcache](../src/hub/bootcache/epoch.odin) (content epoch counter that invalidates bridge-side
bootstrap caches) and [platform](../src/hub/platform) (clock, id generation, randomness, DB telemetry).

### `src/hub/transport/http`

[server.odin](../src/hub/transport/http/server.odin) is a thread-per-connection HTTP server over `core:net`;
[router.odin](../src/hub/transport/http/router.odin) maps routes; [middleware.odin](../src/hub/transport/http/middleware.odin)
authenticates; [respond.odin](../src/hub/transport/http/respond.odin) and `parse.odin` are shared helpers. Handler groups
(files `*_handlers.odin`): agents and instances (`agent_*`), agent actions from `ham-ctl` (`agent_action_handlers.odin`),
bridges (`bridge_*`, including `bridge_enroll_ws.odin`, heartbeat inventory, auto-update, diagnostics, logs, proxy relay),
auth/session/device-auth/OIDC gate, content (conversations, messages, memories, artifacts), projects, providers and
extensions, shell sessions and jobs (`shell_*`, including binary stream frames and screen snapshots), task chains and
mixed work, MCP (`mcp_*`), search, cards/actions/attention, billing, push, issues, vault directory, metrics
(`metrics_*`), LSP, experiments, and the tool-activity relay.

---

## 3. Bridge internals

The bridge is a flat Odin package (`package main`, [src/bridge](../src/bridge)); files are grouped by prefix.

- **Enrollment and identity.** `enroll_device_flow.odin` (RFC 8628 device grant with PKCE and a hub-blind pairing
  code), `enroll_atomic.odin` (two-phase credential staging so a crash never leaves a half-enrolled machine),
  `enroll_account_replace.odin`, `reenroll_identity.odin`, `setup_cmd.odin`/`service_cmds.odin` (install the OS
  service via [src/lib/bridgesvc](../src/lib/bridgesvc)), `keystore_{linux,darwin,windows,android}.odin` (OS keystore for
  the bridge credential and vault keyring), `vault_decrypt.odin`, `unseal_protocol.odin`.
- **Hub runtime client.** [hub_runtime_client.odin](../src/bridge/hub_runtime_client.odin) —
  `bridge_hub_runtime_worker` (connect/reconnect loop), `bridge_hub_runtime_loop` (read loop, heartbeats) and
  `bridge_hub_handle_command` (the switch over every hub→bridge command type).
  [hub_command_dispatch.odin](../src/bridge/hub_command_dispatch.odin) classifies commands (`bridge_command_spec`),
  orders and bounds them; `hub_command_reassembly.odin` joins chunked frames; `retry_*.odin`, `dependency_breaker.odin`
  and `hub_quiescence.odin` handle backoff and drain.
- **Bootstrap.** [bootstrap_prespawn.odin](../src/bridge/bootstrap_prespawn.odin) (`bridge_prespawn_materialize`,
  `bridge_prespawn_env`), [bootstrap_service.odin](../src/bridge/bootstrap_service.odin)
  (`bridge_bootstrap_fetch_and_materialize`, writes skills, the per-agent `ham-ctl` shim),
  [bootstrap_cache.odin](../src/bridge/bootstrap_cache.odin) (content-addressed blob cache + manifest store) and
  `bootstrap_rpc.odin` (file-set RPC).
- **PTY host runtime.** [pty_host_runtime.odin](../src/bridge/pty_host_runtime.odin) (ensure daemon,
  `bridge_pty_host_build_spawn`, spawn/restart/close, `bridge_pty_host_deliver_to_agent`),
  [pty_host_client.odin](../src/bridge/pty_host_client.odin) (framed protocol client),
  `pty_host_stream_worker.odin` (streams PTY output to the hub), `pty_host_events.odin`, `pty_host_activity.odin`.
- **Shell sessions.** `bridge_shell_session.odin` (session map), `shell_*.odin` (spec persistence, output retention and
  sanitising, run-wait, reconcile after restart, inventory, exited-outbox, cwd), and the `shell_*` handlers inside
  `hub_runtime_client.odin` (`bridge_hub_handle_shell_start`).
- **Agent-local API.** [agent_api.odin](../src/bridge/agent_api.odin) routes `agent.<domain>.<verb>` calls from
  `ham-ctl` either as hub envelope calls or raw REST with the instance token; `agent_token_store.odin` issues and
  invalidates per-instance tokens; `wrapper_endpoint.odin` serves the loopback endpoint; `agent_wake.odin` and
  `agent_reconcile.odin` wake/reconcile instances after reconnects.
- **Extensions.** `provider_extension_{detect,install,bundle,reconcile,codex_own}.odin` manage host-side installs;
  `extension_ingest.odin` reduces `ham.ext.v1` events and publishes only leased, sanitised tool/permission state;
  `extension_permission.odin`, `permission_relay.odin` and `extension_blockers.odin` relay permission requests to the hub as agent blockers.
- **Providers.** `provider_catalog_cache.odin` (catalog snapshot pushed by the hub), `provider_profiles.odin`/`provider_store.odin`,
  `provider_model_discovery.odin` (probes run only on `provider_models_discover`).
- **Auto-update.** [auto_update.odin](../src/bridge/auto_update.odin) (quiet-window updates under a kernel lock),
  `update_cmd.odin`, `release_fetch.odin`, `bridge_update`/`bridge_uninstall` commands, `recovery_command.odin`.
- **Filesystem and VCS.** [fs_management.odin](../src/bridge/fs_management.odin) (sandboxed `fs_*` commands confined to a trusted root),
  `vcs_api.odin` with `vcs_git.odin`/`vcs_jj.odin` (backing the UI's VCS panel and the task worktree/merge commands),
  `agent_taskv2_vcs.odin`, `project_path_validation.odin`.
- **Local proxy.** [local_proxy.odin](../src/bridge/local_proxy.odin) — `http://127.0.0.1:<port>/proxy/<session>/…`
  forwarded over the hub WebSocket to the bridge that owns the target shell session.
- **Other.** `tray_*.odin` (desktop tray companion), `lsp_session.odin`, `tool_activity_live.odin`,
  `bridge_telemetry.odin`, `blog.odin` (bridge log push), `instance_lock_*.odin` (one bridge per profile).

---

## 4. Shared libraries (`src/lib`)

| Package | One-line responsibility |
|---|---|
| [agent_runtime](../src/lib/agent_runtime) | Per-agent run-dir contract: the `ham-ctl` shim location/invocation the bridge writes and every agent-facing string cites. |
| [bridgesvc](../src/lib/bridgesvc) | Platform-service model for bridge lifecycle (systemd/launchd/runit/Scheduled Task): setup, status, tray, uninstall engines. |
| [config](../src/lib/config) | Shared config-file/environment helpers. |
| [crashlog](../src/lib/crashlog) | Fatal-signal handler that writes a reason and backtrace to stderr, then re-raises. |
| [httpc](../src/lib/httpc) | The outbound HTTP(S) client (libcurl) and the `wss://` WebSocket handshake/stream (`websocket_connect`); boundary enforced by [scripts/check-http-boundary.sh](../scripts/check-http-boundary.sh), which explicitly allows the plain-`ws://` handshake in `lib/ws`. |
| [jsonx](../src/lib/jsonx) | Byte-preserving JSON reader and `find_value` helpers that cannot abort on hostile input. |
| [local_socket](../src/lib/local_socket) | AF_UNIX stream sockets for same-machine IPC (ham-ctl→bridge, bridge↔pty-host), per-OS backends. |
| [lockorder](../src/lib/lockorder) | Runtime check for the hub lock order `tx_mutex → state_mutex`. |
| [metrics](../src/lib/metrics) | Allocation-disciplined Prometheus client and text exposition; process collector. |
| [os_random](../src/lib/os_random) | OS CSPRNG that fails closed instead of panicking (credentials, PKCE, device codes). |
| [tls_stream](../src/lib/tls_stream) | Legacy TLS client helpers (socat/openssl relay on Unix, SSPI on Windows) retained with tests; not the active `wss://` path, which goes through `httpc`. |
| [tmux](../src/lib/tmux) | Small tmux pane-input helper (`send_text`); legacy, not the launch path. |
| [tool_live](../src/lib/tool_live) | Bounded, volatile tracker and wire limits for live tool-activity state. |
| [vault](../src/lib/vault) | The single Odin implementation of the passwordless-vault wire formats (v2 envelope, HKR2 keyring, signed statements, unseal v2, PTY v2 frames, control scopes); mirrored in TS by `src/ui/utils/vault*.ts`. |
| [vcs](../src/lib/vcs) | VCS abstraction over git, jj and fig (`git.odin`, `jj.odin`, `fig.odin`). |
| [ws](../src/lib/ws) | WebSocket framing, reader, server frames and text-frame chunking for the bridge↔hub channel. `connect_with_bearer` sends `wss://` through `connect_tls_with_bearer` → `httpc.websocket_connect` (libcurl); plain `ws://` dials with `core:net` directly. |

---

## 5. Key flows

### 5.1 Agent launch and bootstrap

1. A launch is requested (UI REST, MCP, or the task matcher). [agent_service.odin](../src/hub/service/agent/agent_service.odin)
   `create_instance` → `prepare_instance` validates the provider/model and saves the instance;
   `reserve_runtime_launch` and `send_instance_launch` send a `launch_agent` command to the owning bridge through
   `service/bridge_runtime` (`send_runtime_command`). `restart_instance` reuses the path.
2. On the bridge, `bridge_hub_handle_command` (`type == "launch_agent"`) acks, then calls `bridge_runtime_launch_agent` →
   `bridge_runtime_launch_agent_pty_host` ([hub_runtime_client.odin](../src/bridge/hub_runtime_client.odin)). It issues an agent
   token (`bridge_agent_token_issue`), ensures the local endpoint, and clean-slates the run dir.
3. Bootstrap files come from the hub: `bridge_bootstrap_fetch_and_materialize` ([bootstrap_service.odin](../src/bridge/bootstrap_service.odin))
   and `bridge_prespawn_materialize` ([bootstrap_prespawn.odin](../src/bridge/bootstrap_prespawn.odin)) fetch the manifest
   (hub handlers `bridge_instance_bootstrap_handler` / `bridge_agent_manifest_handler`, which honour `If-None-Match`)
   and then the blobs by content hash (`bootstrap-blob` route), cached in [bootstrap_cache.odin](../src/bridge/bootstrap_cache.odin).
   The rendered content (memories, task context, messages) is built by `write_bootstrap_*` in
   [agent_service.odin](../src/hub/service/agent/agent_service.odin); skills and the per-agent `ham-ctl` shim are written into the run dir
   (`bridge_bootstrap_write_skills`, `bridge_bootstrap_write_ham_ctl_wrapper`). The hub's `bootcache` epoch is bumped when content changes.
   Background: [heimdall_memory_system_and_bootstrap.md](reference/heimdall_memory_system_and_bootstrap.md).
4. The bridge builds a spawn request (`bridge_pty_host_build_spawn` / `…_for_profile` in
   [pty_host_runtime.odin](../src/bridge/pty_host_runtime.odin): provider command, profile args, env, permission mode) and
   `bridge_pty_host_spawn` sends it to the `ham-pty-host` daemon, which starts the provider CLI under a PTY
   ([daemon.rs](../tools/pty_host/src/daemon.rs), [host.rs](../tools/pty_host/src/host.rs)).
5. The agent runs `ham-ctl start-success` (agent mode → `agent.start_success`); the hub handler in
   [agent_action_handlers.odin](../src/hub/transport/http/agent_action_handlers.odin) calls `mark_instance_start_success`, and the task engine's
   `on_start_success` ([lease.odin](../src/hub/service/taskv2/lease.odin)) confirms any pending lease.

### 5.2 Task System v2 lifecycle

Design record: [plans/task-system-v2.md](plans/task-system-v2.md) and [fsm_task_chain_engine.md](fsm_task_chain_engine.md).
Engine: [src/hub/service/taskv2](../src/hub/service/taskv2).

- **State is a fold of events.** [fold.odin](../src/hub/service/taskv2/fold.odin) `fold_task` is a pure function from a task's ordered
  events to its state (`backlog`/`ready`/`in_progress`/`in_review`/`done`/`cancelled`); `tasks.state` is a cached projection that
  `refold_task` / `refold_chain` ([service.odin](../src/hub/service/taskv2/service.odin)) rewrite after every event, with
  [fold_cache.odin](../src/hub/service/taskv2/fold_cache.odin) as a cache. Attempt budgets and review-round limits are encoded in the fold rules.
- **Publishing.** `chain_propose` / `chain_proposal_decide` / `approve_and_publish_chain_in_uow` ([verbs_m2.odin](../src/hub/service/taskv2/verbs_m2.odin)),
  validated against [brief_schema.odin](../src/hub/service/taskv2/brief_schema.odin) (`validate_brief_for_publish`).
- **Matching and leases.** `match_chain_in_uow` ([matcher.odin](../src/hub/service/taskv2/matcher.odin)) pairs ready tasks and owed
  reviews with fleet members (`pick_instance`, `grant_work`, `grant_reviews`, JIT launch via `jit_prepare`); placement/model
  resolution is in [placement.odin](../src/hub/service/taskv2/placement.odin). Leases: `grant_attempt_in_uow`, `heartbeat_in_uow`,
  `release_in_uow`, `expire_lease_in_uow` ([lease.odin](../src/hub/service/taskv2/lease.odin)). The agent-facing context pack is
  `build_pack_json` ([pack.odin](../src/hub/service/taskv2/pack.odin)) → `TASK.md`.
- **Verbs.** `lease_next`, `lease_heartbeat` ([verbs.odin](../src/hub/service/taskv2/verbs.odin)); `lease_submit`, `lease_handoff`, `lease_block`,
  `lease_switch`, `review_post`, `user_review`, `task_reopen`, `task_hold`, `task_fetch` ([verbs_m2.odin](../src/hub/service/taskv2/verbs_m2.odin)).
  These are reached through `ham-ctl lease|review|task …` (see [src/ctl/taskv2_cmds.odin](../src/ctl/taskv2_cmds.odin)) and the MCP task tools.
- **Review gate.** `evaluate_gate_in_uow` ([gate.odin](../src/hub/service/taskv2/gate.odin)) evaluates the required review pairs
  ([review_pairs.odin](../src/hub/service/taskv2/review_pairs.odin)) and user approval. `changes_requested` is a gate *result*, not a task state:
  it records `EV_CHANGES_REQUESTED`, and the fold returns the task to `ready` (spending review-round budget), or parks it in `backlog`
  with a human `oscillation` block after three rounds. Approval records `EV_APPROVED`, and the fold moves the task to `done`.
- **Merge-back.** On done, `effect_merge_worktree` queues a `Merge_Effect`; `flush_merges` → `merge_job_run` → `run_merge`
  ([merge.odin](../src/hub/service/taskv2/merge.odin)) sends a merge command to the bridge that owns the task worktree
  (`task_worktree` in lease.odin names the per-task workdir and branch; bridge side: [agent_taskv2_vcs.odin](../src/bridge/agent_taskv2_vcs.odin)).
- **Timers.** Lease TTL, hard cap, unconfirmed grants, idle TTL, ready-unclaimed, stalled review/dependency, stale hold:
  [timers.odin](../src/hub/service/taskv2/timers.odin) (`fire_due`, run on `timer_thread_proc`).
- **Unit of work and lock order.** Every mutation runs inside `begin_uow` / `end_uow` ([service.odin](../src/hub/service/taskv2/service.odin)),
  which opens a SQLite transaction guarded by the process-wide `tx_mutex` ([tx.odin](../src/hub/repository/sqlite/tx.odin)). Side effects
  (bridge wakes, stops, publishes, merges, nudges, coordinator notices) are *recorded* in `Effects` and only flushed (`flush_effects`) after the commit
  and after the lock is released; a rolled-back transaction cancels its reservations. The **only legal lock order** is
  `tx_mutex` → `Bridge_Runtime_Connection.state_mutex`: code holding a connection's `state_mutex` must never open a unit of work.
  [src/lib/lockorder](../src/lib/lockorder/lockorder.odin) enforces it (panics in debug builds, counts violations in release).
- **Workflows.** [workflow.odin](../src/hub/service/taskv2/workflow.odin), `workflow_execution.odin` run the JSON definitions in
  `src/prompts/workflows/`; mixed ticket/workflow chains are in `mixed_work.odin`.

### 5.3 Chat message delivery and wake notifications

1. A user message arrives via REST; `persist_user_message` then `deliver_user_message` ([user_message.odin](../src/hub/service/content/user_message.odin))
   save it, update the conversation preview and call `notify_agent_message_checked` ([content_service.odin](../src/hub/service/content/content_service.odin)).
   Agent→user and agent→agent messages use `send_agent_message` / `send_agent_to_agent` in the same file.
2. `notify_agent_message_checked` looks up the instance's bridge and sends a `notify_agent_message` runtime command (or reports `Bridge_Offline`).
3. On the bridge, `bridge_hub_handle_command` (`type == "notify_agent_message"`) calls `bridge_pty_host_deliver_to_agent`
   ([pty_host_runtime.odin](../src/bridge/pty_host_runtime.odin)), which types a one-line notice into the agent's PTY (bracketed paste, then Enter).
   The message body is *not* in the notice: the agent reads it with `ham-ctl chat read`.
4. Task notifications use sibling commands (`notify_task_nudge`, `task_status_changed_notify`). Waking an idle or absent agent is `wake_agent`:
   the task engine's `effect_wake_lease` / `flush_wakes` ([wake.odin](../src/hub/service/taskv2/wake.odin)) batch wake entries per bridge/chain, and the
   bridge side is [agent_wake.odin](../src/bridge/agent_wake.odin) (`bridge_task_wake_if_needed`, with gating and backoff in `bridge_wake_gate`).
5. Live UI updates ride the user WebSocket fed by `service/events` (`event_bus.odin`, `attention_debouncer.odin`).

### 5.4 Provider catalog and model resolution

- The hub owns the **provider catalog** (providers, models, state `active`…): `list_catalog` / `catalog_body_etag`
  ([provider_service.odin](../src/hub/service/provider/provider_service.odin)); it is pushed to bridges as `provider_catalog` /
  `provider_catalog_version` commands and cached by [provider_catalog_cache.odin](../src/bridge/provider_catalog_cache.odin).
- Each bridge reports what it can actually run (detection, profiles, discovered models): `apply_discovery_report`,
  `apply_model_discovery_report`, `apply_effective_models` ([provider_models.odin](../src/hub/service/provider/provider_models.odin)).
  Model probes run only on an explicit `provider_models_discover` ([provider_model_discovery.odin](../src/bridge/provider_model_discovery.odin)).
- **Resolution at launch:** `validate_launchable` checks an explicit provider/model against the catalog ∩ bridge support, and never silently substitutes.
  For task leases, `resolve_launch_model` / `lease_launch_model` ([placement.odin](../src/hub/service/taskv2/placement.odin)) fill empty
  values from the catalog (rank, then id) intersected with the bridge; fleet rows can pin a model or profile per bridge.
- Provider profiles (custom args/env per provider): [provider_profiles.odin](../src/hub/service/provider/provider_profiles.odin) and
  [bridge provider_profiles.odin](../src/bridge/provider_profiles.odin); see [provider-profiles.md](provider-profiles.md).

### 5.5 Shell sessions and previews

- **Create.** REST → `shell_session_create` ([shell_session_service.odin](../src/hub/service/shell_session/shell_session_service.odin)) checks entitlements
  (`shell_session_require_shells`), persists the session and sends `shell_start` to the bridge. Kinds are *run* (one-shot, can block in the foreground via the
  bridge-local wait in [shell_run_wait.odin](../src/bridge/shell_run_wait.odin)), *server* (long-running, optional port) and interactive *shell* (users only); CLI is `ham-ctl shell …` ([shell_cmds.odin](../src/ctl/shell_cmds.odin)).
- **Run.** `bridge_hub_handle_shell_start` ([hub_runtime_client.odin](../src/bridge/hub_runtime_client.odin)) spawns the process through `ham-pty-host`;
  state lives in `Bridge_Shell_Session_Map` ([bridge_shell_session.odin](../src/bridge/bridge_shell_session.odin)); output retention and reconcile-after-restart are `shell_output_retention.odin` and `shell_reconcile.odin`.
- **Stream.** Viewers attach over a WebSocket ([shell_stream_*](../src/hub/transport/http/shell_stream_screen_snapshot.odin)); the hub
  broadcasts PTY output and status frames (`shell_session_broadcast_output`, `…_status`, `…_stream_ready`) and serves screen snapshots from `shell_snapshot_cache.odin`.
  Binary PTY frames are never chunked (`src/lib/ws/chunk.odin`); the wire is described in [plans/pty-streaming-binary-wire.md](plans/pty-streaming-binary-wire.md) and [pane-transport.md](pane-transport.md).
- **Preview.** A server session with a port gets a `preview_url` from `shell_session_preview_url` ([shell_session_rest_handlers.odin](../src/hub/transport/http/shell_session_rest_handlers.odin)),
  served on a separate preview origin (`preview_origin_host_matches` in [server.odin](../src/hub/transport/http/server.odin); auth in `service/auth/preview_auth.odin`).
  Requests are relayed over the bridge WebSocket ([bridge_proxy_relay.odin](../src/hub/transport/http/bridge_proxy_relay.odin)) to the owning bridge, which dials `127.0.0.1:<port>`.
  Session-to-session calls use the bridge-local `/proxy/<session>/…` endpoint ([local_proxy.odin](../src/bridge/local_proxy.odin)).

---

## 6. Storage and the vault boundary

- **Hub database.** One SQLite file, opened by `sqlite.Conn` ([conn.odin](../src/hub/repository/sqlite/conn.odin)); schema is the ordered SQL files in
  [migrations/](../src/hub/repository/sqlite/migrations), tracked per version (`migration_applied`, `mark_migration_applied`), with a few Odin-side upgrades
  in `migrations.odin`. Reads and writes go through the `iface` repositories; writes that must be atomic use the unit of work
  (`tx.odin`, `tx_mutex`). OIDC identities live on a second connection (`oidc_identity_db` in `App_Graph`; see `native_oidc_schema.odin`).
  Design notes: [plans/sqlite-reader-pool.md](plans/sqlite-reader-pool.md), [reference/db-telemetry.md](reference/db-telemetry.md).
- **Bootstrap blobs.** Rendered bootstrap files are content-addressed: the hub serves a manifest with hashes, the bridge fetches blobs by hash and stores
  them in a size-bounded LRU directory cache (`bootstrap_cache_put`, `bootstrap_cache_evict_lru_locked`, hash verified by `bootstrap_cache_verify_hash`).
  Manifests are kept per agent/role/provider/project so the conditional request can answer 304.
- **Bridge-local state.** Credentials in the OS keystore (`keystore_*.odin`), profile state dirs, run dirs per instance, managed-files manifest,
  runtime status file (see `src/lib/bridgesvc/status.odin`).
- **Vault (client-side encryption).** The passwordless vault is specified in [plans/passwordless-vault.md](plans/passwordless-vault.md) and implemented once in
  Odin ([src/lib/vault](../src/lib/vault)) and once in TypeScript (`src/ui/utils/vault*.ts`: `vaultContent.ts`, `vaultKeyring.ts`, `vaultCrypto.ts`,
  `vaultPairing.ts`, …), pinned together by [tools/vault_vectors](../tools/vault_vectors). Human content — message bodies, task prose, memories, project/chain text,
  artifacts, search keys — is encrypted in the UI with the account keyring into `vault:v2:…` envelopes before it reaches the hub, so the hub stores ciphertext.
  Bridges and `ham-ctl` obtain the keyring by hub-blind pairing at enrollment (`bridge_unseal` → `unseal_protocol.odin`, authenticated by `bridge_chain.odin`) and decrypt/encrypt
  locally (`vault_decrypt.odin`, `src/ctl/vault*.odin`); PTY frames use the v2 PTY format. Structural metadata (ids, assignment, dependencies, approval flags, states)
  stays plaintext because the engine must reason over it. The hub verifies signed device statements (`service/vault_directory`) but holds no root key; an
  opt-in hosted-vault mode for MCP is described in [mcp-hosted-vault.md](mcp-hosted-vault.md). When a client has no keyring it sees locked placeholders
  (`vault_locked`), never plaintext.

---

## 7. Tests

| Kind | Where | How to run |
|---|---|---|
| Odin unit/integration | `*_test.odin` next to the code (e.g. [src/hub/service/taskv2](../src/hub/service/taskv2), [src/bridge](../src/bridge), [src/ctl](../src/ctl)), plus package-level suites in [tests/](../tests) (`hub_*_test.odin`, `device_auth_*_test.odin`, `bridge_*_test.odin`) | `odin test <package-dir> -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/<unique>` (always a unique `-out`, binary under `$HOME`; see [AGENTS.md](../AGENTS.md) "Running Odin Tests"). Inside the dev shell from [flake.nix](../flake.nix) (`nix develop`). |
| Rust (`ham-pty-host`) | `#[test]` modules in [tools/pty_host/src](../tools/pty_host/src) | `cargo test -- --test-threads=1` in `tools/pty_host`; Nix runs the same via crane (`cargoTestExtraArgs` in flake.nix). |
| TypeScript unit/UI | [tests/ui_*_test.ts](../tests), `tests/*.test.ts`, [tests/helpers](../tests/helpers) | `npm test` (Node's built-in runner with [vaultEndpointHarness.ts](../tests/helpers/vaultEndpointHarness.ts); the explicit file list is the `test` script in [package.json](../package.json)), `npm run typecheck` (`tsc -b`), `npm run test:task-chain-search`, `npm run test:pane-transport`. |
| Python and shell | [tests/test_*.py](../tests), `tests/e2e_*.sh`, `tests/*.sh` (installers, release targets, dev proxy, hub HTTP APIs, shell/proxy end-to-end) | `python3 tests/test_<name>.py` or `python3 -m unittest discover -s tests -p 'test_*.py'`; `bash tests/e2e_<name>.sh` (some need a built hub/bridge). |
| End-to-end (browser / bridge) | [tests/e2e](../tests/e2e) (`bridge_lifecycle_e2e.mjs`, `bridge_real_enroll_e2e.mjs`, `vault_devices_api_e2e.mjs`, browser checks) and `scripts/e2e-*.sh|ps1` | `npm run test:e2e:vault`, `npm run test:e2e:profiles`, `npm run test:e2e:bridge-enroll` (Windows); the bridge lifecycle job in [bridge-lifecycle-e2e.yml](../.github/workflows/bridge-lifecycle-e2e.yml) builds `.#ham-hub`, `.#release-ham-bridge`, `.#release-ham-pty-host` and runs the `.mjs` e2e files with `node --import ./tests/helpers/vaultEndpointHarness.ts`. |
| Repo checks | `checks.http-boundary` in flake.nix → [scripts/check-http-boundary.sh](../scripts/check-http-boundary.sh) | `nix flake check`, or run the script directly. |

CI lives in [.github/workflows](../.github/workflows): `install-sh.yml` and `install-ps1.yml` (installer tests),
`bridge-lifecycle-e2e.yml`, `release-local-binaries.yml` (cross-platform release builds plus the desktop extension-delivery
test and UI build), `promote-release.yml`, `verify-storeless-mechanism.yml`. There is no single workflow that runs every
Odin suite: run the packages you touched.
