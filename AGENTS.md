# Heimdall AI Manager Project Guide

Heimdall is a local multi-agent orchestration system built around four runtime pieces:

- `ham-daemon` — the durable control plane and HTTP/WS server
- `ham-wrapper` — the tmux-backed agent launcher/runtime shim
- `ham-ctl` — the CLI used by operators, agents, and tests
- Heimdall UI — the Electron/Vite/React/Redux desktop client

The daemon owns durable state, runtime routing, and notification fanout. Wrappers boot agents, register them, generate bootstrap files, and keep heartbeats/activity flowing back to the daemon. CLI and UI mostly fetch durable state over HTTP/REST/RPC. Agent-facing WebSockets are primarily event/summary channels: messages and chat do **not** stream full inbox bodies over WS, and agents/UI fetch the durable records after notification.

## Architecture Invariants

- The daemon is the source of truth for durable task, memory, project, team, VCS, artifact, auth, and agent-identity state.
- Runtime sockets, live wrapper status, and user WebSocket connections are in-memory projections rebuilt on restart.
- `agent_id` is the durable identity tier; `agent_instance_id` is the concrete running/project-bound instance.
- Wrapper bootstrap files (`AGENTS.md`, optional skills files, manifest) are assembled locally on the bridge via the content-addressed Bootstrap Fragment Cache (Hub ↔ Bridge protocol 2 manifest + sha256 blob store) with fallback to full hub generation.
- Agent inbox/chat WebSockets are metadata-only notification channels; task/lifecycle UI notifications may embed compact task/chain payloads, but durable state still lives behind REST/RPC/CLI fetches.

### Socket lifetime across threads

This codebase has produced the same concurrency defect five times: **a socket closed on one
thread while another thread is blocked reading it.** If you are about to copy a stream-teardown
pattern from `src/bridge/local_proxy.odin`, `src/bridge/hub_runtime_client.odin` (the `tunnel_*`
procs) or `src/hub/transport/http/shell_session_handlers.odin`, read this first — the pattern you
are copying protects **memory**, and on its own it will not protect the **fd**.

**A registered stream has two resources with two different owners. Do not conflate them.**

1. **Memory — the independent-key probe.** A stream struct is reachable from a map, and two
   threads can both decide the stream is finished. Whoever removes the map key owns the free;
   the loser finds the key absent and must not dereference the pointer at all. Capture anything
   you still need (ids, handles) as stack locals at entry.

2. **The fd — the reader owns it.** The thread that blocks in `recv` on a socket is its **sole
   closer**, on **every** exit path. Every other thread may only `shutdown(..., .Receive)` /
   `SHUT_RD` to *wake* that reader; it must never `close`.

**Why `close` from the other thread is not an option.** Measured on Linux, in-tree:

- `close()` **cannot** unblock a `recv` that is already parked. The parked `recv` holds the
  `struct file`, so the socket is merely orphaned and the reader sleeps **forever** — one leaked
  thread per teardown, unbounded, each pinning a socket and its buffers. `/proc/<pid>/fd` looks
  clean throughout, which is why this keeps shipping unnoticed.
- If the reader is instead *between* `recv` calls when the close lands, its next `recv` re-resolves
  the fd **number**, which a new connection may already own. It then reads a stranger's bytes and
  forwards them under the dead stream's id. fd-number reuse on the very next dial is confirmed.
- `shutdown(.Receive)` on a **still-open** fd wakes a parked `recv` in tens of microseconds,
  returning `(0, nil)`. Issued *after* a close it does nothing — the fd is already invalid. So
  shutdown must always precede the close, and the close must come from the reader.

**Three rules that follow, each of which has been got wrong here:**

- **Never gate the close on the key race.** `if i_won_the_key_race { close(fd) }` leaks the fd on
  the losing path, because the probe governs memory only. The close belongs outside that branch.
- **Never `close` the same fd from a proc that runs for both directions or both owners.** Each fd
  gets exactly one owning `close`; four closes per fd is a defect this repo actually shipped, and
  each spurious close frees the number for an unrelated live connection.
- **A receive timeout is not end-of-stream.** `core:net` reports a graceful close as `(0, nil)` and
  a timeout as `Would_Block`/`Timeout` (`-1`/`EAGAIN` for raw `posix.recv`), so the common
  `if err != nil || n <= 0 do break` will tear down a live idle connection once per period. Handle
  the timeout wake as "keep going", and use it to re-check whether teardown has happened — via the
  independent key, never by dereferencing the struct.

**Joining is a valid alternative, but only where the closer can afford to block.** Making the
reader joinable and doing shutdown → join → close concentrates ownership in the closer and is what
`shell_session_handlers.odin` does. Do not force it onto a teardown that runs on a WebSocket
reader thread: stalling that thread stalls the whole hub connection behind one local socket. In the
bridge, reader-owns-close is used precisely because the closing thread is the WS reader.

## Identity Model

- `agent_id`
  - Durable identity shared across projects and runs.
  - Stored in `src/daemon/agent_id_store.odin` as `Agent_Id_Record`.
- `agent_instance_id`
  - Concrete instance/session identity, often `agent_id@project-or-scope`.
  - Stored durably as `Agent_Instance_Record`, mirrored live in `Agent_Record`.
- `conversation_id`
  - Agent-to-agent inbox/message stream key.
- `client_instance_id`
  - Durable user-client/UI identity for `/user-client/register`, `/user-rpc`, and `/user-ws`.
- `agent_token`, `client_token`
  - Random bearer tokens persisted in `auth/tokens.db` and recovered after daemon restart.
- `ws_token`, `reconnect_token`
  - Wrapper/WebSocket session credentials returned by `/register` / `/reconnect`.

## Root Files

- `flake.nix`
  - Nix flake defining build packages/apps such as `ham-daemon`, `ham-wrapper`, `ham-ctl`, and UI packaging.
- `package.json`
  - Electron/Vite/React/TypeScript UI package scripts and dependencies.
- `config.toml`
  - Main runtime config for daemon, wrapper, providers, model tiers, startup/activity detection, guide agent, managed run dirs, and ctl defaults.
- `README.md`
  - High-level project overview.
- `AGENTS.md`
  - This architecture/bootstrap guide.

## Source Layout

```text
src/
  contracts/          shared protocol/data contracts
  ctl/                ham-ctl CLI
  daemon/             ham-daemon server, stores, services, notifications
  lib/
    config/           config parser/defaults
    http_client/      local HTTP client helpers
    tmux/             tmux launch/control helpers
    vcs/              git/jj workspace helpers
    ws/               WebSocket client helpers
  prompts/            bootstrap/profile/persona/task-chain guidance text
  test_agent/         smoke-test agent helpers
  ui/                 Electron/Vite/React/Redux app
  wrapper/            ham-wrapper runtime/bootstrap generator
```

## Package Summaries

### `src/contracts`

Shared contracts used across binaries.

- `identity.odin`
  - Core identity types such as `Agent_Instance_ID`, `Agent_Class`, and the client kind/access-mode/capability enums.
- `lifecycle.odin`
  - The `/register` request type.
- `protocol.odin`
  - Build/version constants (`APP_VERSION`, `GIT_COMMIT`, `BUILD_TIMESTAMP`, `PROTOCOL_VERSION`).
- `memory_provider.odin`
  - The shared `Memory_Type` enum.
- `artifacts.odin`
  - The `Artifact_ID` type.

### `src/daemon`

The `ham-daemon` package. It is both the runtime hub and the persistence boundary.

Key responsibilities:

- HTTP server and route dispatch (`server.odin`, `rest_router.odin`, `*_http.odin`, `*_rest.odin`)
- Wrapper lifecycle: `/register`, `/heartbeat`, `/startup`, `/ws`, `/agents/start`, `/agents/stop`
- Agent runtime registry and lifecycle notifications (`registry.odin`, `agent_runtime_tracker.odin`, `agent_lifecycle_notifications.odin`)
- Task chains/tasks/comments/votes/participants, projections, review routing, nudge scheduling, and durable notification outbox (`task_*.odin`)
- User/agent chat plus approvals (`chat_*.odin`, `message_db_service.odin`, `user_rpc.odin`, `user_ws.odin`)
- Durable memory proposal/approval pipeline (`memory_*.odin`)
- Projects/teams/VCS/artifacts/auth/preferences/audit (`project_store.odin`, `team_*.odin`, `vcs_*.odin`, `artifact_*.odin`, `0_auth_db_service.odin`, `user_pref_db_service.odin`, `audit_db_service.odin`)
- Hub/router scaffolding and guide/test services (`hub_*`, `router_*`, `guide_*`, `test_run.odin`)

### `src/wrapper`

The `ham-wrapper` package. It turns a daemon-issued start request into a managed tmux session.

Key responsibilities:

- Resolve provider profile / model tier / run directory / project context
- Register with daemon and receive `conversation_id`, `agent_token`, and WS info
- Generate managed bootstrap files (`AGENTS.md` or `CLAUDE.md`, optional `MEMORY.md`, skills files, `.heimdall-bootstrap-manifest`)
- Launch the real agent command in tmux
- Run startup detection and activity detection without persisting raw terminal transcripts
- Maintain WebSocket connection, heartbeat loop, and startup/activity status reporting
- Recover from daemon restarts via re-registration / WS reconnect logic

### `src/ctl`

The `ham-ctl` CLI used by both humans and agents.

Current command families are much broader than the original POC:

- `health`
- `agents ...`
- `send`, `inbox`
- `tasks ...`, `task-chains ...`
- `projects ...`, `teams ...`, `workspace ...`, `chains ...`, `attention`
- `memory ...`
- `users ...`, `chat ...`
- `artifacts ...`
- `start-success`
- `help work-guide`

### `src/ui`

The Heimdall desktop UI.

- Electron shell in `src/ui/electron`
- HTTP API client in `src/ui/api/daemonApi.ts`
- Redux slices in `src/ui/store/*`
- React components in `src/ui/components/*`
- Exposes/consumes the debug-element surface used by the Electron debug API
- Uses `/user-client/register`, `/user-ws`, REST reads, and `/user-rpc` mutations for most interactive flows

### `src/lib`

Shared libraries used by daemon/wrapper/ctl.

- `config` — config structs/defaults/parser for daemon data dirs, wrapper launch/bootstrap settings, provider/model tiers, startup/activity detection, guide agent, and ctl defaults
- `http_client` — local daemon HTTP calls
- `tmux` — tmux lifecycle helpers
- `vcs` — git/jj workspace helpers
- `ws` — wrapper-side WebSocket client

## Core Data Structures and Stores

### Identities and auth

- `Agent_Id_Record`
  - Durable identity: display name, template, role, default provider, default tier, state.
  - Append-only JSONL store in `src/daemon/agent_id_store.odin`.
- `Agent_Instance_Record`
  - Durable instance binding: `agent_instance_id`, `agent_id`, provider, project, run dir, tier, scope, role, current task timestamps.
  - Append-only JSONL store in `src/daemon/agent_store.odin`.
- `Agent_Record`
  - In-memory runtime/session projection: live socket, heartbeat, tmux pane, pid, startup/activity state, provider cache.
  - Lives in `src/daemon/registry.odin`.
- Auth tokens
  - `agent_token` and `client_token` are persisted in SQLite (`src/daemon/0_auth_db_service.odin`) and recovered across daemon restarts.

### Tasks, chains, comments, votes, and participants

Defined primarily in `src/daemon/task_store.odin`.

- `Task_Chain_State`
  - Durable chain projection: project/team/workspace ids, title/description, coordinator, default reviewer, final summary, archive/evaluation flags.
- `Task_State`
  - Durable task projection: title, description, acceptance criteria, assignee, dependencies, timestamps, status.
- `Task_Event`
  - Event log record for task/chain mutations, comments, votes, status changes, nudges, archive events, and final summary.
- `Task_Participant`
  - Extra role membership beyond the primary assignee/coordinator/default reviewer.
  - Roles include `assignee`, `coordinator`, `lgtm_required`, `lgtm_optional`, and `subscriber`.
- `Task_Comment_State`
  - Durable comments with `resolved` state.
- `Task_LGTM_Vote_State`
  - Durable reviewer vote state (`approved`, role, comment, timestamp).
- Task statuses
  - Core task states are `planning`, `queued`, `in_progress`, `review_ready`, `approved`, `blocked`, and `cancelled`.
  - `ready` is accepted as a CLI/HTTP alias for `queued`.
- Storage model
  - Tasks are event-shaped and projected into in-memory arrays plus SQLite tables (`task_db_service.odin`).
  - The daemon also keeps a durable task notification outbox for retryable per-agent notifications.

### User/agent chat

Defined in `src/daemon/chat_store.odin` and `message_db_service.odin`.

- `Chat_Event`
  - Append/delivered/read/failure events for human↔agent chat.
- `Chat_Message`
  - Durable SQLite row keyed by `message_id`, `user_id`, `agent_instance_id`, direction, body, chain id, delivery/read timestamps, and failure info.
- Read state
  - Stored durably per conversation/direction in the chat DB and exposed through `/user-rpc`, `/chats/...`, and UI slices.

### Memory

Defined by `src/contracts/memory_provider.odin` and implemented by `src/daemon/memory_*.odin`.

- `Memory_Record`
  - Durable current record.
- `Memory_Event`
  - Durable proposal/approval/rejection/archive history.
- Types
  - `fact`, `habit`, `episode`, `expertise`, `skill`.
  - `template_id` is a memory scope target, not a memory type.
- Statuses
  - `pending`, `active`, `archived`, `rejected`.
- Targeting dimensions
  - `target_agent_id`, `target_team_kind`, `target_role`, `target_project_id`.
- Storage
  - SQLite in `memory/memory.db` with event history and applicable-memory queries.

### Projects, teams, VCS workspaces, and artifacts

- `Project_Record`
  - Durable project metadata plus loose anchors (`type`, `value`, `note`).
  - Append-only JSONL store in `src/daemon/project_store.odin`.
- `Team_Record` / `Team_Member_Record`
  - Durable chain team and roster records in `teams/teams.db`.
  - Team members can be generated agents or `user_proxy` slots with `route_to` metadata.
- `Vcs_Workspace_Record`
  - Durable workspace handle in `vcs/vcs.db`: project, chain, path, base ref, branch/change, status, keep-on-archive.
- `Artifact_Record`
  - Durable artifact metadata in `artifacts/artifacts.db`; blob bytes live under the artifact blob store.

### Bootstrap artifacts

Generated by `src/wrapper/main.odin`.

- Managed files can include `AGENTS.md`, `CLAUDE.md`, `MEMORY.md`, and per-skill `SKILL.md` files under directories such as `.agents/skills/` or `skills/`.
- The wrapper writes `.heimdall-bootstrap-manifest` so it can clean up only files it previously managed.
- Bootstrap content is assembled from live identity data, project/team/chain/workspace context, active approved memories/templates, and agent template persona/instructions.

## Persistence Model

Heimdall is **not** an in-memory-only system.

Current storage is mixed by subsystem:

- SQLite: auth tokens, tasks/projections/outbox, chat/messages, memory, teams, VCS workspaces, artifacts, preferences, audits
- JSONL append-only stores: durable agent identities/instances, projects, some legacy/migration paths
- In-memory runtime projections: live wrapper registry, active sockets, pending WS connections, provider-memory agent inbox implementation

A good rule of thumb: durable business state lives on disk; live transport/session state stays in memory.

## Runtime Data Flow

### 1. Agent start and bootstrap generation

1. `ham-ctl agents start ...` or UI start action sends `POST /agents/start`.
2. The daemon validates/provider-resolves the request, upserts durable agent identity state, and launches `ham-wrapper` detached.
3. The wrapper calls `/health`, then `/register`.
4. The daemon returns `agent_instance_id`, `conversation_id`, WS info, `agent_token`, template persona/instructions, and team-role context.
5. The wrapper optionally validates project context, fetches applicable memories/project/team/chain/workspace state, writes managed bootstrap files, and launches the real agent command in tmux.
6. The wrapper reports startup status, heartbeats, and activity snapshots; the agent later signals `start-success` through `ham-ctl ... start-success`.

### 2. Agent-to-agent inbox messaging

1. Agent CLI/RPC sends a message through `/agent-rpc`.
2. `message_service.odin` routes through the configured message provider and emits message-bus events.
3. The daemon sends a metadata-only `messages_available` WS event to the target agent, including `conversation_id`, sender, and `pending_count`.
4. The target agent fetches actual bodies through inbox/fetch RPC/CLI.
5. Read events produce `messages_read` notifications back to the sender.

### 3. User ↔ agent chat

1. The UI registers a `client_instance_id` and `client_token` via `/user-client/register`, heartbeats via `/user-client/heartbeat`, and opens `/user-ws/<client_instance_id>`.
2. Human sends use `/user-rpc action=send_to_agent`; agent sends use `chat send-to-user` / chat HTTP helpers.
3. Chat bodies are stored durably in the chat/message SQLite store.
4. WS `chat_event` fanout tells the UI/user client that a conversation changed and carries metadata such as `message_id`, direction, chain id, and unread count.
5. UI/CLI fetch full bodies through `/chats/...` or `/user-rpc fetch_chat`, and mark read via `/user-rpc mark_read`.

### 4. Task lifecycle and review routing

1. Task and chain mutations append `Task_Event` records.
2. Projections update `Task_State`, `Task_Chain_State`, comments, participants, and votes.
3. Automatic gating promotes tasks from `planning` to `queued`, then to `in_progress` when the assignee is free.
4. `tasks done` moves a task to `review_ready`; required `lgtm_required` votes auto-approve it.
5. Notification routing is status-aware:
   - `queued` / `in_progress` → assignee (+ subscribers)
   - `review_ready` → required reviewers with fallback routing
   - `approved` / `blocked` / `cancelled` → assignee + coordinator (+ subscribers)
   - review-ready comments are not themselves a reviewer broadcast; nudges and status ownership determine who gets pinged live
6. User-facing task WS events can include embedded task/chain snapshots, while agent-facing notifications stay lightweight summaries.
7. If live delivery fails, the daemon queues a durable notification outbox entry for replay.

### 5. Memory lifecycle

1. Agents or users propose memory changes (`new`, `edit`, `archive`, `rollback`).
2. Proposal records are stored as `pending`.
3. Approval promotes the proposed memory to `active` (or archives/replaces the target on edit/archive/rollback flows).
4. Wrapper bootstrap generation calls `/memory/applicable` to pull only active memories/templates relevant to the current agent/team/role/project scope.

### 6. Project / team / VCS / artifact lifecycle

- Projects are durable metadata records with loose anchors; they are hints, not mandatory cwd bindings.
- Creating chains can allocate a team, generated roster, optional VCS workspace setup tasks, and workspace records.
- VCS endpoints under `/chains/{id}/workspace...` expose status, diff, pull-base, merge-preview, merge, and archive flows.
- Completing a VCS-backed chain can leave a workspace `merge_pending` until the merge/keep/archive decision is resolved.
- Artifact metadata is stored durably; blobs are served separately via artifact content routes.

## Current Control / Launch Model

Default config path:

```text
~/.config/heimdall/config.toml
```

Pass `--config <path>` to override.

### Agent command profiles

`config.toml` supports multiple wrapper agent command profiles, each with command args, model-tier mapping, bootstrap feature settings, startup/activity detection, and prompt-delivery behavior.

Example knobs that exist today:

- `wrapper.default_agent`
- `wrapper.agent_run_dir`, `wrapper.use_random_dir`
- per-profile `command`, `prompt_flags`, `yolo_flags`, `starter_prompt`
- per-profile `models.{cheap,normal,smart}`
- per-profile bootstrap feature blocks such as `bootstrap.AGENTS_MD`, `bootstrap.MEMORY_MD`, and `bootstrap.SKILLS`
- per-profile `startup_detection` and `activity_detection`
- guide-agent defaults under `[guide_agent]`

### Startup detection

Wrappers can classify startup without persisting raw transcripts.

Per-profile startup detection can:

- probe a bounded tmux capture window in memory
- auto-press safe keys for known prompts
- classify `starting`, `ready`, `startup_blocked`, `startup_failed`, or `startup_unknown`
- report only sanitized diagnostics back to the daemon

### `ham-ctl` command families

Run `ham-ctl --help` for the current surface. Important families include:

```bash
ham-ctl task-chains <list|create|show|update|members|add-agent|publish|complete> [--as user|agent]
ham-ctl tasks <list|create|update|status|done|depend|cancel|comment|comments|vote|votes|nudge> [--as user|agent]
ham-ctl agents list|start|create|update
ham-ctl send|inbox
ham-ctl projects ...
ham-ctl teams ...
ham-ctl workspace ...
ham-ctl memory ...
ham-ctl users ...
ham-ctl chat ...
ham-ctl artifacts ...
ham-ctl help work-guide
```

Top-level `ham-ctl task-chains` and `ham-ctl tasks` unify user and agent operations with full parity. Use `--as user` (direct HTTP to Hub with user token) or `--as agent` (IPC relay through local Bridge with agent token). Task ids are globally unique, so `tasks show/comments/status/comment/vote/nudge/...` need only the `<task-id>` — the Hub derives the chain server-side and `--chain` is never required. `tasks list` defaults to the caller instance's own chain when `--chain` is omitted.

### Daemon-managed agent start

All managed launches go through the daemon. `ham-ctl` or the UI does **not** spawn wrappers directly for normal operation; it requests `POST /agents/start`, and the daemon launches `ham-wrapper` on the daemon host.

## Token Model

Agent and user tokens are random bearer tokens persisted by the auth DB.

Do **not** assume deterministic formats such as `agent_<agent_instance_id>`.

Examples:

```json
{"agent_token":"agt_<random-hex>"}
{"client_token":"uct_<random-hex>"}
```

For daemon-launched wrappers, the daemon may pre-generate the agent token, return it to ctl/UI, and pass it to the wrapper so the wrapper registers using the same durable credential.

## UI Debug IDs

Every interactive element in the Electron UI must have a `data-debug-id` attribute. The Electron debug API (exposed at `http://127.0.0.1:<debug-port>/elements`, `/click`, `/type`, etc.) uses these IDs to locate and interact with elements programmatically.

### Naming convention

- Format: `kebab-case` strings, all lowercase.
- Pattern: `<page-or-context>-<element-role>[-<qualifier>]`
- For list items that repeat, append the item's stable ID: `agent-item-${agent.id}`, `chain-card-${chainId}`.
- For indexed rows (e.g. anchor arrays), append the index: `create-anchor-type-0`, `detail-anchor-remove-btn-2`.
- For tier/tab variants, append the variant value: `start-agent-model-tier-smart`, `agents-tab-templates`.

### Required elements

All of the following element types must have `data-debug-id`:
- `button` — every button, including icon-only buttons and items that act as buttons
- `input` — every text/radio/checkbox input
- `select` — every dropdown
- `textarea` — every multi-line input
- `label` wrapping a radio input — use on the `<label>` itself for radio groups styled as clickable tiles

### Per-component registry

| Component | Key IDs |
|-----------|---------|
| `AgentPaneComposerPanel` | `agent-pane-composer-panel`, `agent-pane-terminal`, `agent-pane-stream-disconnected`, `agent-pane-retry-connection-btn` |
| `HomePage` | `home-getting-started-page`, `home-getting-started-hero`, `home-getting-started-title`, `home-getting-started-subtitle`, `home-getting-started-feature-grid`, `home-prompt-card`, `home-active-project-label`, `home-prompt-composer-shell`, `home-prompt-input`, `home-prompt-error`, `home-conversation-progress`, `home-prompt-submit-btn`, `home-action-grid`, `home-create-agent-btn`, `home-create-conversation-btn`, `home-create-task-chain-btn`, `home-create-project-btn`, `home-feature-overview`, `home-open-memory-btn`, `home-memory-total`, `home-memory-pending`, `home-recent-task-chains`, `home-new-chain-btn`, `home-chain-search-input`, `home-chain-search-count`, `home-chain-search-empty`, `home-chain-row-${chainId}`, `home-chain-open-btn-${chainId}`, `home-project-new-chain-btn-${projectId}`, `home-running-agents-panel`, `home-running-agents-refresh-btn`, `home-running-agents-list`, `home-running-agent-${agentId}`, `home-running-agent-chat`, `home-running-agent-chat-title`, `home-running-agent-chat-status`, `home-running-agent-chat-scroll`, `home-running-agent-chat-message-actions-${messageId}`, `home-running-agent-chat-message-copy-btn-${messageId}`, `home-running-agent-chat-status-banner`, `home-running-agent-chat-status-start-btn`, `home-running-agent-chat-composer-shell`, `home-running-agent-chat-input`, `home-running-agent-chat-send-error`, `home-running-agent-chat-upload-error`, `home-running-agent-chat-send-btn`, `home-running-agent-chat-artifact-upload-button`, `home-agent-picker`, `home-http-load-evidence`, `home-periodic-evidence`, `home-ws-evidence`, `home-local-action-evidence` |
| `AttentionPage` | `attention-approval-${itemId}-approve-btn`, `attention-approval-${itemId}-reject-btn`, `attention-blocked-${taskId}-message-btn`, `attention-blocked-${taskId}-open-btn`, `attention-merge-${chainId}-merge-btn`, `attention-merge-${chainId}-keep-btn`, `attention-merge-${chainId}-abandon-btn`, `attention-merge-${chainId}-show-diff-btn` |
| `Sidebar` | `attention-bell-btn`, `attention-bell-badge`, `nav-home-btn`, `nav-memory-btn`, `nav-agents-btn`, `nav-task-chains-btn`, `nav-projects-btn`, `nav-settings-btn`, `conversation-sidebar-collapse-btn`, `conversation-sidebar-expand-btn`, `conversation-sidebar-expand-full-btn`, `conversation-collapsed-nav`, `nav-${itemId}-collapsed-btn`, `conversation-focused-sidebar`, `conversation-active-chains`, `conversation-sidebar-chain-${chainId}`, `sidebar-durable-agents`, `sidebar-agent-group-${agentId}`, `sidebar-agent-group-open-btn-${agentId}`, `sidebar-agent-new-instance-btn-${agentId}`, `sidebar-agent-status-${agentId}`, `sidebar-agent-status-label-${agentId}`, `sidebar-agent-live-instances-${agentId}`, `sidebar-agent-live-instance-row-${agentInstanceId}`, `sidebar-agent-live-instance-status-${agentInstanceId}`, `sidebar-conversations-paged-list`, `sidebar-conversations-show-more-btn`, `sidebar-conversations-loading`, `sidebar-agents-paged-list`, `sidebar-agents-show-more-btn`, `sidebar-agents-loading`, `sidebar-agent-instances-panel`, `sidebar-agent-instances-title-${agentId}`, `sidebar-agent-instances-launch-row-${agentId}`, `sidebar-agent-instances-close-btn`, `sidebar-agent-instances-empty`, `sidebar-agent-instance-row-${agentInstanceId}`, `sidebar-agent-instance-status-${agentInstanceId}`, `sidebar-agent-instance-status-label-${agentInstanceId}`, `sidebar-conversations`, `sidebar-new-conversation-btn`, `conversation-thread-${agentId}`, `conversation-thread-open-btn-${agentId}`, `conversation-thread-status-${agentId}`, `conversation-thread-status-label-${agentId}`, `sidebar-agent-launch-btn`, `sidebar-agent-launch-name-input`, `sidebar-agent-launch-role-input`, `sidebar-agent-launch-provider-select`, `sidebar-agent-launch-project-select`, `sidebar-agent-launch-tier-select`, `sidebar-agent-launch-save-defaults-label`, `sidebar-agent-launch-save-defaults-checkbox`, `sidebar-agent-launch-submit-btn`, `sidebar-agent-launch-cancel-btn`, `sidebar-agent-launch-progress`, `sidebar-agent-launch-done-btn`, `sidebar-agent-launch-new-btn`, `sidebar-agent-picker-close-btn`, `sidebar-agent-${agentId}`, `sidebar-chain-list`, `sidebar-chain-${chainId}`, `sidebar-new-chain-btn`, `sidebar-project-agent-session-tree`, `sidebar-project-group-${projectId}`, `sidebar-project-toggle-btn-${projectId}`, `sidebar-project-body-${projectId}`, `sidebar-project-chevron-${projectId}`, `sidebar-project-empty-${projectId}`, `sidebar-agent-status-dot-${agentId}`, `sidebar-session-row-${conversationId}`, `sidebar-session-status-dot-${conversationId}`, `sidebar-session-coordinator-name-${conversationId}`, `sidebar-session-group-separator-${conversationId}`, `sidebar-bridge-legend`, `sidebar-bridge-legend-item-${bridgeId}` |
| `AgentsPanel` | `agents-add-agent-btn`, `agents-create-name-input`, `agents-create-template-select`, `agents-create-instructions-toggle-btn`, `agents-create-instructions-input`, `agents-create-bridge-scope`, `agents-create-provider-scope`, `agents-create-provider-select`, `agents-create-tier-select`, `agents-create-submit-btn`, `agents-create-header-cancel-btn`, `agents-create-footer-cancel-btn`, `agents-no-capabilities-warning`, `agents-no-capabilities-bridges-link`, `agents-no-capabilities-providers-link`, `agents-agent-row-${agentId}`, `agents-agent-open-btn-${agentId}`, `agents-agent-launch-btn-${agentId}`, `agents-agent-archive-btn-${agentId}` |
| `AgentsManagementSurface` | `agents-management-surface`, `agents-management-back-btn`, `agents-management-create-card`, `agents-management-create-identity-btn`, `agents-management-create-hint`, `agents-management-new-proxy-btn`, `agents-management-list`, `agents-management-agent-${agentId}`, `agents-management-open-btn-${agentId}`, `agents-management-manage-btn-${agentId}`, `agents-management-launch-btn-${agentId}`, `agents-management-delete-btn-${agentId}` |
| `TaskChainsSurface` | `task-chains-surface`, `task-chains-back-btn`, `task-chains-new-btn`, `task-chains-active-list`, `task-chains-active-row-${chainId}`, `task-chains-completed-list`, `task-chains-completed-row-${chainId}` |
| `ProjectsSurface` | `projects-surface`, `projects-new-btn`, `projects-create-form`, `projects-create-name-input`, `projects-create-path-input`, `projects-create-error`, `projects-create-submit-btn`, `projects-create-cancel-btn`, `projects-search-input`, `projects-list`, `projects-empty`, `projects-row-${projectId}`, `project-detail`, `project-detail-back-btn`, `project-detail-title`, `project-detail-about`, `project-detail-edit-btn`, `project-detail-path`, `project-detail-description`, `project-detail-description-empty`, `project-detail-name-input`, `project-detail-description-input`, `project-detail-default-path-input`, `project-detail-about-error`, `project-detail-save-btn`, `project-detail-cancel-btn`, `project-detail-agents`, `project-detail-new-agent-btn`, `project-detail-agents-empty`, `project-detail-agent-${agentId}`, `project-detail-memory`, `project-detail-open-memory-btn`, `project-detail-memory-empty`, `project-detail-memory-${memoryId}`, `project-detail-bridge-paths`, `project-detail-default-path-input`, `project-detail-default-path-save-btn`, `project-detail-default-path-error`, `project-detail-bridge-paths-empty`, `project-detail-bridge-path-row-${bridgeId}`, `project-detail-bridge-path-status-${bridgeId}`, `project-detail-bridge-path-create-${bridgeId}`, `project-detail-bridge-path-recheck-${bridgeId}`, `project-detail-bridge-path-override-${bridgeId}`, `project-detail-bridge-path-reset-${bridgeId}`, `project-detail-bridge-picker-${bridgeId}` (see BridgeDirectoryPicker) |
| `BridgeDirectoryPicker` | `<debugId>`, `${debugId}-close-btn`, `${debugId}-breadcrumb`, `${debugId}-crumb-${index}`, `${debugId}-list`, `${debugId}-loading`, `${debugId}-empty`, `${debugId}-entry-${name}`, `${debugId}-hidden-toggle`, `${debugId}-new-folder-btn`, `${debugId}-new-folder-input`, `${debugId}-new-folder-create-btn`, `${debugId}-path-input`, `${debugId}-error`, `${debugId}-create-typed-btn`, `${debugId}-pick-btn` |
| `ProjectFilesPanel` | `${debugPrefix}-panel` (prefix `project-files`), `project-files-title`, `project-files-last-refreshed`, `project-files-refresh-btn`, `project-files-close-btn`, `project-files-no-project`, `project-files-breadcrumb`, `project-files-crumb-${i}`, `project-files-list`, `project-files-loading`, `project-files-empty`, `project-files-load-error`, `project-files-entry-${name}`, `project-files-truncated`, `project-files-error`, `project-files-file-view`, `project-files-file-back-btn`, `project-files-file-md-toggle-btn`, `project-files-file-wrap-toggle-btn`, `project-files-file-unviewable`, `project-files-file-image`, `project-files-file-markdown`, `project-files-file-code`, `project-files-file-text`, `project-files-comments-bar`, `project-files-comments-count`, `project-files-comments-clear-btn`, `project-files-comments-send-btn`, `project-files-line-${n}`, `project-files-line-comment-btn-${n}`, `project-files-line-composer-${n}`, `project-files-line-composer-input-${n}`, `project-files-line-composer-save-${n}`, `project-files-line-composer-cancel-${n}`, `project-files-line-comment-${id}`, `project-files-line-comment-edit-${id}`, `project-files-line-comment-edit-input-${id}`, `project-files-line-comment-edit-save-${id}`, `project-files-line-comment-delete-${id}` |
| `ChainView` | `chain-view`, `chain-back-btn`, `chain-workspace-btn`, `chain-open-editor-btn`, `chain-tasks-toggle-btn`, `chain-split-view`, `chain-coordinator-panel`, `chain-coordinator-live-status`, `chain-coordinator-message-actions-${messageId}`, `chain-coordinator-message-copy-btn-${messageId}`, `chain-coordinator-load-older-messages-btn`, `chain-coordinator-status-banner`, `chain-coordinator-status-start-btn`, `chain-coordinator-composer-shell`, `chain-coordinator-composer-input`, `chain-coordinator-send-btn`, `chain-coordinator-runtime-controls`, `chain-coordinator-provider-select`, `chain-coordinator-tier-select`, `chain-coordinator-project-select`, `chain-coordinator-runtime-pending-hint`, `chain-progress-panel`, `chain-progress-bar`, `chain-progress-complete-count`, `chain-progress-active-count`, `chain-progress-review-count`, `chain-progress-blocked-count`, `chain-task-surface`, `chain-task-count`, `chain-task-list-active`, `chain-task-list-completed`, `chain-task-row-${taskId}`, `chain-task-row-${taskId}-open-btn`, `chain-task-row-${taskId}-expand-btn`, `chain-task-row-${taskId}-title`, `chain-task-row-${taskId}-status`, `chain-task-row-${taskId}-agents`, `chain-task-assignee-${agentId}`, `chain-task-assignee-chat-btn-${agentId}`, `chain-task-reviewer-${agentId}`, `chain-task-reviewer-chat-btn-${agentId}`, `task-detail-actions-${taskId}`, `task-detail-description-${taskId}`, `task-detail-votes-${taskId}`, `task-detail-comments-${taskId}`, `task-detail-comments-load-older-btn-${taskId}`, `task-detail-comment-${taskId}-${commentIndex}`, `task-detail-completion-comment-${taskId}-${commentIndex}`, `task-detail-comment-textarea-${taskId}`, `task-detail-comment-submit-btn-${taskId}`, `task-detail-assignee-picker-btn-${taskId}`, `task-detail-reviewer-picker-btn-${taskId}`, `task-agent-picker-close-btn`, `task-assignee-agent-picker`, `task-reviewer-agent-picker`, `task-detail-status-done-btn-${taskId}`, `task-detail-status-block-btn-${taskId}`, `task-detail-status-later-btn-${taskId}`, `task-detail-status-cancel-btn-${taskId}`, `task-detail-status-start-btn-${taskId}`, `task-detail-vote-lgtm-btn-${taskId}`, `task-detail-vote-ngtm-btn-${taskId}`, `task-detail-nudge-textarea-${taskId}`, `task-detail-nudge-btn-${taskId}`, `chain-agent-open-btn-${agentId}`, `chain-agent-chat-btn-${agentId}`, `global-right-sidebar-toggle-btn`, `global-right-sidebar`, `global-right-sidebar-close-btn`, `global-right-sidebar-tabs`, `global-right-sidebar-diffs-tab`, `global-right-sidebar-artifacts-tab`, `global-right-sidebar-diff-list`, `global-right-sidebar-diff-empty`, `global-right-sidebar-artifact-list`, `chain-http-load-evidence`, `chain-ws-evidence`, `chain-local-action-evidence` |
| `ArtifactViewer` | `artifact-viewer`, `artifact-viewer-breadcrumb`, `artifact-viewer-meta-strip`, `artifact-viewer-version-select`, `artifact-viewer-rollback-btn`, `artifact-viewer-rollback-reason-input`, `artifact-viewer-rollback-confirm-btn`, `artifact-viewer-rollback-cancel-btn`, `artifact-viewer-annotate-toggle`, `artifact-viewer-annotations-panel`, `artifact-viewer-copy-all-annotations-btn`, `artifact-viewer-download-btn`, `artifact-viewer-close-btn`, `artifact-viewer-text-selection-summary`, `artifact-viewer-add-annotation-comment-input`, `artifact-viewer-add-annotation-btn`, `artifact-viewer-clear-text-selection-btn`, `artifact-viewer-png-annotation-panel`, `artifact-viewer-png-annotation-layer`, `artifact-viewer-png-preview`, `artifact-viewer-png-annotation-draft`, `artifact-viewer-png-region-summary`, `artifact-viewer-image-annotation-comment-input`, `artifact-viewer-add-image-annotation-btn`, `artifact-viewer-annotation-comment-input`, `artifact-viewer-annotation-save-btn`, `artifact-viewer-annotation-cancel-btn`, `artifact-viewer-annotation-edit-btn`, `artifact-viewer-annotation-copy-btn`, `artifact-viewer-annotation-remove-btn` |
| `GuideSidePanel` | `guide-side-panel`, `guide-side-panel-agent`, `guide-side-panel-status-dot`, `guide-side-panel-status`, `guide-side-panel-close-btn`, `guide-debug-toggle-btn`, `guide-current-page-send-btn`, `guide-debug-info`, `guide-chat-message-actions-${messageId}`, `guide-chat-message-copy-btn-${messageId}`, `guide-chat-load-older-messages-btn`, `guide-chat-status-banner`, `guide-chat-status-start-btn`, `guide-chat-composer-shell`, `guide-chat-composer-input`, `guide-chat-send-btn`, `guide-chat-artifact-upload-btn`, `guide-chat-artifact-upload-input`, `guide-chat-upload-error` |
| `AgentDetailPage` | `agent-detail-page`, `agent-detail-back-btn`, `agent-detail-title`, `agent-detail-live-status`, `agent-detail-all-instances-btn`, `agent-detail-start-btn`, `agent-detail-stop-btn`, `agent-detail-edit-btn`, `agent-detail-delete-btn`, `agent-detail-action-error`, `agent-detail-stop-progress`, `agent-detail-stop-progress-bar`, `agent-detail-stop-step-${stepKey}`, `agent-detail-stop-progress-dismiss-btn`, `agent-detail-edit-close-btn`, `agent-detail-edit-name-input`, `agent-detail-edit-provider-select`, `agent-detail-edit-project-select`, `agent-detail-edit-tier-select`, `agent-detail-edit-cancel-btn`, `agent-detail-edit-save-btn`, `agent-detail-project`, `agent-detail-role`, `agent-detail-provider`, `agent-detail-runtime`, `agent-detail-chat`, `agent-detail-chat-artifacts-toggle-btn`, `agent-detail-chat-artifacts-panel`, `agent-detail-chat-artifacts-upload-btn`, `agent-detail-chat-artifacts-upload-input`, `agent-detail-chat-artifacts-refresh-btn`, `agent-detail-chat-artifacts-close-btn`, `agent-detail-chat-artifacts-list`, `agent-detail-chat-artifact-row-${artifactId}`, `agent-detail-refresh-chat-btn`, `agent-detail-chat-message-actions-${messageId}`, `agent-detail-chat-message-copy-btn-${messageId}`, `agent-detail-chat-load-older-messages-btn`, `agent-detail-chat-status-banner`, `agent-detail-chat-status-start-btn`, `agent-detail-chat-composer-shell`, `agent-detail-chat-input`, `agent-detail-chat-provider-select`, `agent-detail-chat-tier-select`, `agent-detail-chat-project-select`, `agent-detail-chat-runtime-controls`, `agent-detail-chat-runtime-pending-hint`, `agent-detail-chat-runtime-restart-status`, `agent-detail-chat-runtime-restart-error`, `agent-detail-nudge-btn`, `agent-detail-chat-send-btn`, `agent-detail-chat-sidebar`, `agent-detail-chat-chain-empty`, `agent-detail-chat-chain-summary`, `agent-detail-chat-chain-open-btn`, `agent-detail-chat-sidebar-tasks`, `agent-detail-chat-sidebar-task-${taskId}`, `agent-detail-tasks`, `agent-detail-task-${taskId}`, `agent-detail-task-open-btn-${taskId}`, `agent-detail-task-title-${taskId}`, `agent-detail-task-status-${taskId}`, `agent-detail-task-meta-${taskId}`, `agent-detail-task-description-${taskId}`, `agent-detail-task-open-chain-${taskId}`, `agent-detail-memory`, `agent-detail-memory-refresh-btn`, `agent-detail-memory-add-btn`, `agent-detail-memory-item-${memoryId}`, `agent-detail-memory-edit-btn-${memoryId}`, `agent-memory-editor`, `agent-memory-editor-body-vim-edit-btn`, `agent-memory-editor-close-btn`, `agent-memory-editor-type-select`, `agent-memory-editor-title-input`, `agent-memory-editor-body-textarea`, `agent-memory-editor-evidence-input`, `agent-memory-editor-cancel-btn`, `agent-memory-editor-save-btn`, `agent-detail-default-provider-scope`, `agent-detail-default-provider-select`, `agent-detail-default-tier-select`, `agent-detail-default-save-btn`, `agent-detail-bridge-row-${bridgeId}`, `agent-detail-bridge-toggle-${bridgeId}`, `agent-detail-bridge-provider-scope-${bridgeId}`, `agent-detail-bridge-provider-select-${bridgeId}`, `agent-detail-bridge-tier-select-${bridgeId}`, `agent-detail-bridge-effective-${bridgeId}`, `agent-detail-bridge-save-btn-${bridgeId}`, `agent-detail-launch-instance-header-btn`, `agent-detail-launch-instance-btn`, `agent-detail-launch-bridge-select`, `agent-detail-launch-provider-select`, `agent-detail-launch-tier-select`, `agent-detail-launch-project-select`, `agent-detail-launch-submit-btn`, `agent-detail-instance-row-${instanceId}`, `agent-detail-instance-status-${instanceId}`, `agent-detail-instance-taskchain-btn-${instanceId}`, `agent-detail-instance-open-btn-${instanceId}`, `agent-detail-instance-stop-btn-${instanceId}`, `agent-detail-instance-restart-btn-${instanceId}` |
| `AgentIdentityPage` | `agent-identity-page`, `agent-identity-breadcrumb`, `agent-identity-back-btn`, `agent-identity-edit-btn`, `agent-identity-new-instance-btn`, `agent-identity-summary`, `agent-identity-title`, `agent-identity-instance-count`, `agent-identity-edit-defaults-btn`, `agent-identity-template`, `agent-identity-default-project`, `agent-identity-provider-tier`, `agent-identity-memory-summary`, `agent-identity-edit-modal`, `agent-identity-edit-close-btn`, `agent-identity-edit-name-input`, `agent-identity-edit-provider-select`, `agent-identity-edit-project-select`, `agent-identity-edit-tier-select`, `agent-identity-edit-template-select`, `agent-identity-edit-error`, `agent-identity-edit-cancel-btn`, `agent-identity-edit-save-btn`, `agent-identity-template-panel`, `agent-identity-template-toggle-btn`, `agent-identity-template-content`, `agent-identity-template-persona`, `agent-identity-template-instructions`, `agent-identity-memory-panel`, `agent-identity-memory-empty`, `agent-identity-memory-item-${memoryId}`, `agent-identity-remote-panel`, `agent-identity-remote-agent-id`, `agent-identity-remote-peer`, `agent-identity-remote-daemon`, `agent-identity-remote-remap-btn`, `agent-identity-remote-remap-panel`, `agent-identity-remote-remap-select`, `agent-identity-remote-remap-input`, `agent-identity-remote-remap-cancel-btn`, `agent-identity-remote-remap-save-btn`, `agent-identity-instance-summary-list`, `agent-identity-instance-summary-group-${group}`, `agent-identity-instance-summary-row-${agentInstanceId}`, `agent-identity-instance-summary-status-${agentInstanceId}`, `agent-identity-instance-summary-id-${agentInstanceId}`, `agent-identity-instance-summary-context-${agentInstanceId}` |
| `NewConversationPage` | `new-conversation-page`, `new-convo-breadcrumb`, `new-convo-back-btn`, `new-convo-project-select`, `new-convo-hero-card`, `new-convo-context-strip`, `new-convo-title`, `new-convo-subtitle`, `new-convo-suggestion-grid`, `new-convo-option-ask-btn`, `new-convo-option-open-chain-btn`, `new-convo-option-pick-agent-btn`, `new-convo-option-plan-work-btn`, `new-convo-composer-shell`, `new-convo-input`, `new-convo-error`, `new-convo-progress`, `new-convo-agent-select`, `new-convo-advanced-toggle`, `new-convo-bridge-select`, `new-convo-provider-select`, `new-convo-tier-select`, `new-convo-no-runnable-agent-warning`, `new-convo-no-bridge-warning`, `new-convo-send-btn`, `new-convo-project-path-hint` |
| `MessageBubble` | `message-bubble-copy-btn-${messageId}` |
| `MemoryManagementPage` | `memory-management-surface`, `memory-management-home-btn`, `memory-refresh-btn`, `memory-filters-reset-btn`, `memory-filter-agent-select`, `memory-filter-project-select`, `memory-filter-template-select`, `memory-filter-bridge-select`, `memory-filter-search-input`, `memory-filter-type-select`, `memory-filter-status-select`, `memory-filter-targeting-select`, `memory-filter-pending-active-checkbox`, `memory-form-title-input`, `memory-form-type-select`, `memory-form-agent-select`, `memory-form-project-select`, `memory-form-template-select`, `memory-form-bridge-select`, `memory-form-source-task-input`, `memory-form-body-textarea`, `memory-form-metadata-textarea`, `memory-form-reason-textarea`, `memory-form-evidence-textarea`, `memory-form-submit-btn` |
| `MemoryPanel` | `settings-memory-panel`, `memory-refresh-btn`, `memory-create-toggle-btn`, `memory-create-cancel-btn`, `memory-create-title-input`, `memory-create-body-textarea`, `memory-create-evidence-input`, `memory-create-submit-btn`, `memory-create-error`, `memory-filter-status-select`, `memory-filter-type-select`, `settings-memory-row-${memoryId}`, `memory-row-open-btn-${memoryId}`, `memory-row-edit-btn-${memoryId}`, `memory-row-archive-btn-${memoryId}`, `memory-row-scope-${memoryId}`, `memory-proposals-panel`, `memory-proposal-${memoryId}`, `memory-proposal-title-input-${memoryId}`, `memory-proposal-body-textarea-${memoryId}`, `memory-proposal-evidence-input-${memoryId}`, `memory-proposal-scope-${memoryId}`, `memory-proposal-save-btn-${memoryId}`, `memory-proposal-approve-btn-${memoryId}`, `memory-proposal-reject-btn-${memoryId}`, `memory-edit-title-input-${memoryId}`, `memory-edit-body-textarea-${memoryId}`, `memory-edit-evidence-input-${memoryId}`, `memory-edit-cancel-btn-${memoryId}`, `memory-edit-save-btn-${memoryId}` |
| `MemoryScopeSelector` | `${debugPrefix}-agent-select`, `${debugPrefix}-project-select`, `${debugPrefix}-bridge-select`, `${debugPrefix}-template-select`, `${debugPrefix}-type-select`, `${debugPrefix}-summary`; current prefixes include `memory-scope`, `memory-filter-scope`, `memory-proposal-scope-${memoryId}`, and `memory-edit-scope-${memoryId}` |
| `ConversationThreadPage` | `conversation-thread-page`, `conversation-thread-back-btn`, `conversation-thread-breadcrumb`, `conversation-thread-header`, `conversation-thread-overflow-menu-btn`, `conversation-thread-overflow-menu`, `conversation-thread-overflow-details`, `conversation-thread-title`, `conversation-thread-title-input`, `conversation-thread-title-save-btn`, `conversation-thread-title-cancel-btn`, `conversation-thread-title-edit-btn`, `conversation-thread-title-error`, `conversation-thread-project-chip`, `conversation-thread-status-chip`, `conversation-thread-refresh-btn`, `conversation-thread-artifacts-toggle-btn`, `conversation-thread-artifacts-panel`, `conversation-thread-artifacts-upload-btn`, `conversation-thread-artifacts-upload-input`, `conversation-thread-artifacts-refresh-btn`, `conversation-thread-artifacts-close-btn`, `conversation-thread-artifacts-list`, `conversation-thread-artifact-row-${artifactId}`, `conversation-thread-action-error`, `conversation-thread-summary-card`, `conversation-thread-instance-label`, `conversation-thread-affordance-strip`, `conversation-thread-transcript`, `conversation-thread-empty-state`, `conversation-thread-empty-avatar`, `conversation-thread-empty-title`, `conversation-thread-empty-persona`, `conversation-thread-worked-status`, `conversation-thread-load-older-sentinel`, `conversation-thread-message-${messageId}`, `conversation-thread-message-actions-${messageId}`, `conversation-thread-message-copy-btn-${messageId}`, `conversation-thread-agent`, `conversation-thread-instance`, `conversation-thread-bridge`, `conversation-thread-provider`, `conversation-thread-tier`, `conversation-thread-status`, `conversation-thread-chain`, `conversation-right-panel-toggle-btn`, `conversation-right-panel-toggle-progress`, `conversation-right-panel`, `conversation-right-panel-tabs`, `conversation-right-panel-tab-tasks`, `conversation-right-panel-tab-files`, `conversation-composer-status-banner`, `conversation-composer-status-start-btn`, `conversation-composer-shell`, `conversation-composer-card`, `conversation-composer-context`, `conversation-composer-bridge-chip`, `conversation-composer-project-chip`, `conversation-composer-input`, `conversation-composer-send-error`, `conversation-composer-upload-error`, `conversation-composer-starting-indicator`, `conversation-composer-status`, `conversation-composer-toolbar`, `conversation-tasks-btn`, `conversation-runtime-status-chip`, `conversation-runtime-status-menu`, `conversation-runtime-status-toggle-btn`, `conversation-runtime-menu-btn`, `conversation-runtime-menu`, `conversation-runtime-mobile-sheet`, `conversation-runtime-mobile-sheet-panel`, `conversation-runtime-mobile-sheet-title`, `conversation-runtime-mobile-sheet-close`, `conversation-runtime-controls`, `conversation-provider-option-${provider}`, `conversation-tier-option-${tier}`, `conversation-reconfigure-status`, `conversation-bridge-select`, `conversation-provider-select`, `conversation-tier-select`, `conversation-project-select`, `conversation-runtime-pending-hint`, `conversation-request-pane-btn`, `conversation-pane-capture-loading-${messageId}`, `conversation-pane-capture-output-${messageId}`, `conversation-pane-capture-error-${messageId}`, `conversation-pane-capture-retry-${messageId}`, `conversation-composer-send-btn`, `conversation-attach-btn`, `conversation-attach-input`, `conversation-attachment-tray`, `conversation-attachment-${localId}`, `conversation-attachment-retry-${localId}`, `conversation-attachment-remove-${localId}`, `conversation-attachment-progress-${localId}`, `conversation-attachment-error-${localId}`, `conversation-attachment-uploading-hint`, `conversation-attachment-failed-hint`, `conversation-system-message-${messageId}`, `conversation-action-message-${messageId}`, `conversation-action-tray`, `conversation-tray-notice`, `conversation-composer-tray-mode`, `conversation-composer-tray-mode-cancel` |
| `StartAgentAction` | `attention-start-agent`, `attention-start-agent-error`, `action-tray-start-agent-${cardId}`, `action-tray-start-agent-error-${cardId}` |
| `ActionTray` | `action-tray`, `action-tray-title`, `action-tray-pager`, `action-tray-prev`, `action-tray-next`, `action-tray-page`, `action-tray-show-composer`, `action-tray-cards`, `action-tray-actions-blocked`, `action-tray-actions-review`, `action-tray-answer`, `action-tray-approve`, `action-tray-request-changes`, `action-tray-delegate`, `action-tray-more`, `action-tray-snooze`, `action-tray-open`, `action-tray-delegate-picker`, `action-tray-delegate-${agentId}`, `action-tray-snooze-menu`, `action-tray-snooze-${presetId}`, `action-tray-panel-close`, `action-tray-need-you-pill` |
| `ActionTaskCard` | `action-tray-card-blocked`, `action-tray-card-review`, `action-tray-card-title`, `action-tray-card-agent`, `action-tray-card-need`, `action-tray-card-ask`, `action-tray-card-question`, `action-tray-card-no-ask`, `action-tray-review-result`, `action-tray-review-summary`, `action-tray-review-decisions`, `action-tray-review-verify`, `action-tray-review-verify-skipped`, `action-tray-review-shots`, `action-tray-shot-${index}`, `action-tray-review-links`, `action-tray-review-changes`, `action-tray-review-excerpt`, `action-tray-review-empty`, `action-tray-lightbox`, `action-tray-lightbox-close` |
| `AppShell` | `shell-breadcrumbs`, `shell-breadcrumb-crumb-${index}`, `shell-breadcrumb-link-${index}`, `shell-new-chat-button`, `shell-command-palette-button`, `settings-sub-nav`, `settings-sub-nav-bridges`, `settings-sub-nav-providers`, `settings-sub-nav-projects`, `settings-sub-nav-templates`, `settings-sub-nav-memory`, `settings-sub-nav-defaults`, `settings-sub-nav-devices` |
| `TemplatesPanel` | `settings-templates-panel`, `settings-templates-new-btn`, `settings-templates-list`, `settings-templates-empty`, `settings-template-row-${templateId}`, `settings-template-edit-btn-${templateId}`, `settings-template-delete-btn-${templateId}`, `settings-template-delete-confirm-${templateId}`, `settings-template-delete-cancel-${templateId}`, `settings-template-editor`, `settings-template-name-input`, `settings-template-description-input`, `settings-template-persona-input`, `settings-template-instructions-input`, `settings-template-editor-error`, `settings-template-save-btn`, `settings-template-cancel-btn` |
| `UnifiedWorkspaceShell` | `workspace-shell` |
| `WorkspaceLeftSidebar` | `workspace-left-sidebar` |
| `WorkspaceMainRegion` | `workspace-main-region`, `workspace-top-bar`, `workspace-content-outlet` |
| `ContextInspector` | `workspace-inspector`, `workspace-inspector-toggle-btn`, `workspace-inspector-expand-btn`, `workspace-inspector-tabs`, `workspace-inspector-tab-${tabId}`, `workspace-inspector-panel-${tabId}`, `workspace-inspector-empty` |
| `TaskChainOverview` | `taskchain-overview`, `taskchain-overview-title`, `taskchain-overview-status`, `taskchain-overview-description-toggle-btn`, `taskchain-overview-progress`, `taskchain-overview-progress-todo`, `taskchain-overview-progress-in_progress`, `taskchain-overview-progress-in_validation`, `taskchain-overview-progress-validated_good`, `taskchain-overview-progress-blocked`, `taskchain-overview-members`, `taskchain-overview-member-${agentId}`, `taskchain-overview-add-member-btn`, `taskchain-overview-member-remove-btn-${agentInstanceId}`, `taskchain-task-row-${taskId}`, `taskchain-task-expand-btn-${taskId}`, `taskchain-task-title-${taskId}`, `taskchain-task-description-${taskId}`, `taskchain-task-status-${taskId}`, `taskchain-task-priority-${taskId}`, `taskchain-task-assignee-${taskId}`, `taskchain-task-reviewers-${taskId}`, `taskchain-task-blocked-${taskId}`, `taskchain-task-comments-${taskId}`, `taskchain-task-comment-${taskId}-${index}`, `taskchain-task-comment-load-older-btn-${taskId}`, `taskchain-task-comment-input-${taskId}`, `taskchain-task-comment-submit-btn-${taskId}`, `taskchain-task-nudge-btn-${taskId}`, `taskchain-task-lgtm-btn-${taskId}`, `taskchain-task-ngtm-btn-${taskId}`, `taskchain-task-status-menu-btn-${taskId}`, `taskchain-task-status-${statusKey}-btn-${taskId}`, `taskchain-task-cancel-btn-${taskId}`, `taskchain-new-task-btn`, `taskchain-new-task-title-input`, `taskchain-new-task-submit-btn`, `taskchain-overview-back-btn` |
| `GenericAgentWorkspacePage` | `generic-agent-page`, `generic-agent-page-body`, `generic-agent-page-composer-region` |
| `RuntimeRestartControls` | `${debugPrefix}-runtime-menu-btn`, `${debugPrefix}-runtime-menu`, `${debugPrefix}-runtime-controls`, `${debugPrefix}-provider-select`, `${debugPrefix}-tier-select`, `${debugPrefix}-project-select`, `${debugPrefix}-restart-btn`, `${debugPrefix}-runtime-pending-hint` (debugPrefix is `chain-coordinator`, `conversation`, and `agent-detail-chat` for the wired composers) |
| `ChatComposer` | `<shellDebugId>`, `<inputDebugId>`, `<sendButtonDebugId>`, `<sendErrorDebugId>`, `<uploadErrorDebugId>`, plus upload ids from `<debugIdPrefix>-btn` and `<debugIdPrefix>-input`; when runtime controls are supplied, `${runtimeControls.debugPrefix}-runtime-menu-btn` and `${runtimeControls.debugPrefix}-runtime-menu` |
| `ChatMessageList` | `${debugPrefix}-scroll`, `${debugPrefix}-load-older-sentinel`, `${debugPrefix}-message-${messageId}`, `${debugPrefix}-message-${messageId}-time`, `${debugPrefix}-message-actions-${messageId}`, `${debugPrefix}-message-copy-btn-${messageId}`, `${debugPrefix}-message-${messageId}-status`, `${debugPrefix}-jump-latest-btn` |
| `MultiQuestionForm` | `${debugPrefix}-form`, `${debugPrefix}-locked`, `${debugPrefix}-question-${questionId}-choice-${optionId}`, `${debugPrefix}-question-${questionId}-option-${optionId}`, `${debugPrefix}-question-${questionId}-custom`, `${debugPrefix}-submit`, `${debugPrefix}-answered`, `${debugPrefix}-error`; chat prefixes are `${chatDebugPrefix}-questions-${messageId}` |
| `MultiQuestionDemo` (dev fixture) | `mq-demo-new-user`, `mq-demo-new-agent`, `mq-demo-lock`, `mq-demo-fail`, `mq-demo-deliveries`; shared chat IDs use prefix `mq-demo` |
| `ChatSidebar` | `<debugId>` |
| `ChatWorkBanner` | `${debugPrefix}-status-banner`, `${debugPrefix}-status-start-btn` |
| `ChainWorkspaceBox` | `workspace-refresh-btn`, `workspace-pull-base-btn`, `workspace-preview-merge-btn`, `workspace-file-${slug}`, `workspace-show-diff-btn`, `workspace-diff-file-select`, `workspace-copy-diff-btn`, `workspace-ask-coordinator-btn` |
| `NewChainModal` | `new-chain-project-select`, `new-chain-title-input`, `new-chain-goal-textarea`, `new-chain-goal-vim-edit-btn`, `new-chain-wants-vcs-checkbox`, `new-chain-project-vcs-status`, `new-chain-coordinator-select`, `new-chain-coordinator-preview`, `new-chain-skill-note`, `new-chain-cancel-btn`, `new-chain-create-btn` |
| `NewProjectModal` | `new-project-name-input`, `new-project-description-textarea`, `new-project-repo-input`, `new-project-vcs-select`, `new-project-cancel-btn`, `new-project-submit-btn` |
| `ChainEditor` | `chain-editor-participants-panel`, `chain-editor-chain-controls-panel`, `chain-editor-chain-title-input`, `chain-editor-description-vim-edit-btn`, `chain-editor-chain-description-textarea`, `chain-editor-chain-coordinator-picker-btn`, `chain-editor-chain-reviewer-picker-btn`, `chain-editor-chain-save-btn`, `chain-editor-chain-pause-btn`, `chain-editor-chain-complete-btn` |
| `SettingsPage` | `settings-modal`, `settings-rail`, `settings-body`, `settings-close-btn`, `settings-single-daemon-note`, `settings-nav-${key}`, `settings-nav-defaults`, `settings-nav-daemon`, `settings-nav-providers`, `settings-default-agents-panel`, `settings-default-agents-refresh-btn`, `settings-default-agents-save-btn`, `settings-default-agent-use-${use}-row`, `settings-default-agent-use-${use}-picker-btn`, `settings-default-agent-use-${use}-value`, `settings-default-agents-save-message`, `settings-daemon-single-active-banner`, `settings-daemon-list`, `settings-daemon-row-${daemonKey}`, `settings-daemon-reconnect-btn-${daemonKey}`, `settings-daemon-remove-btn-${daemonKey}`, `settings-daemon-url-input`, `settings-daemon-label-input`, `settings-daemon-user-input`, `settings-daemon-add-btn`, `settings-peer-daemon-list`, `settings-peer-daemon-row-${peerKey}`, `settings-peer-daemon-reconnect-btn-${peerKey}`, `settings-peer-daemon-remove-btn-${peerKey}`, `settings-peer-daemon-url-input`, `settings-peer-daemon-label-input`, `settings-peer-daemon-token-input`, `settings-peer-daemon-connect-btn`, `settings-debug-server-checkbox`, `settings-providers-single-daemon-banner`, `settings-providers-daemon-select`, `settings-providers-list`, `settings-provider-card-${providerName}`, `settings-provider-default-btn-${providerName}`, `providers-bridge-select`, `providers-add-btn`, `providers-provider-row-${providerName}`, `providers-enabled-toggle-${providerName}`, `providers-edit-btn-${providerName}`, `providers-delete-btn-${providerName}`, `providers-test-btn-${providerName}`, `providers-test-result-${providerName}`, `providers-refresh-caps-btn`, `provider-source-badge-${providerName}`, `providers-editor-name-input`, `providers-enabled-toggle-editor`, `providers-editor-command-input`, `providers-editor-command-chip-input`, `providers-editor-command-chip-add-btn`, `providers-editor-command-chip-${index}`, `providers-editor-command-chip-remove-btn-${index}`, `providers-editor-prompt-flags-chip-input`, `providers-editor-prompt-flags-chip-add-btn`, `providers-editor-prompt-flags-chip-${index}`, `providers-editor-prompt-flags-chip-remove-btn-${index}`, `providers-editor-yolo-flags-chip-input`, `providers-editor-yolo-flags-chip-add-btn`, `providers-editor-yolo-flags-chip-${index}`, `providers-editor-yolo-flags-chip-remove-btn-${index}`, `providers-editor-startup-blocked-patterns-chip-input`, `providers-editor-startup-blocked-patterns-chip-add-btn`, `providers-editor-startup-blocked-patterns-chip-${index}`, `providers-editor-startup-blocked-patterns-chip-remove-btn-${index}`, `providers-editor-startup-auto-enter-patterns-chip-input`, `providers-editor-startup-auto-enter-patterns-chip-add-btn`, `providers-editor-startup-auto-enter-patterns-chip-${index}`, `providers-editor-startup-auto-enter-patterns-chip-remove-btn-${index}`, `providers-editor-startup-auto-enter-pre-keys-chip-input`, `providers-editor-startup-reason-mapping-chip-input`, `providers-editor-startup-reason-mapping-reason-input`, `providers-editor-startup-reason-mapping-chip-add-btn`, `providers-editor-startup-reason-mapping-chip-${index}`, `providers-editor-startup-reason-mapping-chip-remove-btn-${index}`, `providers-editor-command-input`, `providers-editor-models-flag-input`, `providers-editor-models-cheap-input`, `providers-editor-models-normal-input`, `providers-editor-models-smart-input`, `providers-editor-prompt-flags-input`, `providers-editor-yolo-flags-input`, `providers-editor-prompt-delivery-input`, `providers-editor-starter-prompt-input`, `providers-editor-startup-enabled-checkbox`, `providers-editor-startup-unknown-blocked-checkbox`, `providers-editor-startup-probe-input`, `providers-editor-startup-capture-interval-input`, `providers-editor-startup-blocked-patterns-input`, `providers-editor-startup-auto-enter-patterns-input`, `providers-editor-startup-auto-enter-pre-keys-input`, `providers-editor-startup-reason-mapping-input`, `providers-editor-activity-enabled-checkbox`, `providers-editor-activity-sample-lines-input`, `providers-editor-activity-ignore-bottom-input`, `providers-editor-activity-check-interval-input`, `providers-editor-activity-min-gap-input`, `providers-editor-activity-max-gap-input`, `providers-editor-save-btn`, `providers-editor-header-cancel-btn`, `providers-editor-footer-cancel-btn`, `settings-default-agent-provider-select`, `settings-default-agent-tier-select`, `settings-default-agent-save-btn`, `settings-back-btn`, `settings-create-agent-btn`, `settings-create-agent-modal`, `settings-create-agent-name-input`, `settings-create-agent-template-select`, `settings-create-agent-provider-select`, `settings-create-agent-tier-select`, `settings-create-agent-cancel-btn`, `settings-create-agent-cancel-secondary-btn`, `settings-create-agent-submit-btn`, `settings-create-agent-error`, `settings-direct-chat-agent-select`, `settings-direct-chat-feed`, `settings-direct-chat-message-${messageId}`, `settings-direct-chat-message-actions-${messageId}`, `settings-direct-chat-message-copy-btn-${messageId}`, `settings-direct-chat-status-banner`, `settings-direct-chat-status-start-btn`, `settings-direct-chat-composer-shell`, `settings-direct-chat-input`, `settings-direct-chat-send-btn`, `settings-bridges-panel`, `settings-bridges-add-btn`, `settings-bridges-load-error`, `settings-bridges-error`, `settings-bridges-enroll-panel`, `settings-bridges-enroll-label`, `settings-bridges-enroll-cancel`, `settings-bridges-enroll-create`, `settings-bridges-enroll-result`, `settings-bridges-enroll-command`, `settings-bridges-enroll-copy-token`, `settings-bridges-enroll-done`, `settings-bridges-pending`, `settings-bridges-pending-${enrollmentId}`, `settings-bridges-pending-revoke-${enrollmentId}`, `settings-bridges-list`, `settings-bridges-empty`, `settings-bridge-row-${bridgeId}`, `settings-bridge-status-${bridgeId}`, `settings-bridge-rename-input-${bridgeId}`, `settings-bridge-ready-${bridgeId}`, `settings-bridge-status-label-${bridgeId}`, `settings-bridge-caps-${bridgeId}`, `settings-bridge-rename-save-${bridgeId}`, `settings-bridge-rename-cancel-${bridgeId}`, `settings-bridge-revoke-confirm-${bridgeId}`, `settings-bridge-revoke-cancel-${bridgeId}`, `settings-bridge-rename-btn-${bridgeId}`, `settings-bridge-revoke-btn-${bridgeId}`, `settings-bridges-gap-note`, `settings-projects-panel`, `settings-project-name-input`, `settings-project-description-input`, `settings-project-create-btn`, `settings-project-row-${projectId}`, `settings-memory-panel`, `settings-memory-row-${memoryId}`, `settings-defaults-panel`, `settings-default-agent-row-${agentId}`, `settings-project-create-form`, `settings-project-repo-input`, `settings-project-vcs-select`, `settings-project-default-path-input`, `settings-project-create-error`, `settings-project-open-btn-${projectId}`, `settings-project-edit-btn-${projectId}`, `settings-project-save-btn-${projectId}`, `settings-project-bridge-path-row-${bridgeId}`, `settings-project-bridge-path-input-${bridgeId}`, `settings-project-bridge-path-save-btn-${bridgeId}`, `settings-project-bridge-path-validate-btn-${bridgeId}`, `settings-project-bridge-path-remove-btn-${bridgeId}`, `settings-project-bridge-path-status-${bridgeId}` |
| `SessionConfig` | `session-config-reconnect-btn`, `session-config-daemon-url`, `session-config-user-id` |
| `DeviceVaultScreens` | `device-genesis-screen`, `device-waiting-screen`, `device-waiting-code`, `device-waiting-no-code`, `device-waiting-new-code-btn`, `device-waiting-fingerprint`, `device-waiting-reset-scheduled`, `device-waiting-reset-btn`, `device-waiting-reset-confirm-btn`, `device-waiting-reset-cancel-btn`, `device-waiting-error`, `device-other-account-warning`, `device-other-account-alert`, `device-other-account-ack-checkbox`, `device-other-account-continue-btn`, `device-other-account-error`, `device-vault-unsupported`, `device-vault-revoked`, `device-vault-reapprove-btn`, `device-vault-reapprove-error`, `device-vault-initializing`, `device-vault-error`, `device-vault-error-message`, `device-vault-retry-btn`, `device-vault-start-over-btn`, `device-vault-start-over-phrase-input`, `device-vault-reset-device-data-phrase-input`, `device-vault-reset-device-data-btn`, `device-vault-pair-again-btn`, `device-vault-error-detail` |
| `DeviceApprovalPage` | `device-approval-page`, `device-approval-code-input`, `device-approval-lookup-btn`, `device-approval-change-code-btn`, `device-approval-requested-at`, `device-approval-review`, `device-approval-kind`, `device-approval-host-label`, `device-approval-fingerprint`, `device-approval-label-input`, `device-approval-approve-btn`, `device-approval-deny-btn`, `device-approval-progress`, `device-approval-done`, `device-approval-home-btn`, `device-approval-another-btn`, `device-approval-error` |
| `DevicesPanel` | `settings-devices-panel`, `settings-devices-account-fingerprint`, `settings-devices-log-head`, `settings-devices-reset-alert`, `settings-devices-reset-cancel-btn`, `settings-devices-add-link`, `settings-devices-list`, `settings-devices-empty`, `settings-device-row-${deviceId}`, `settings-device-current-badge`, `settings-device-retired-hint-${deviceId}`, `settings-device-unpaired-hint-${deviceId}`, `settings-device-revoke-confirm-${deviceId}`, `settings-device-revoke-single-approver-${deviceId}`, `settings-device-revoke-approved-${deviceId}`, `settings-device-key-error-${deviceId}`, `settings-device-send-key-btn-${deviceId}` (only after a failed delivery), `settings-device-approve-link-${deviceId}`, `settings-device-deny-btn-${deviceId}`, `settings-device-revoke-btn-${deviceId}` (never rendered for the current device), `settings-device-revoke-confirm-btn-${deviceId}`, `settings-device-revoke-cancel-btn-${deviceId}`, `settings-devices-notice`, `settings-devices-error` |
| `RecoveryKeySection` | `settings-recovery-key`, `settings-recovery-key-status`, `settings-recovery-key-create-btn`, `settings-recovery-key-replace-btn`, `settings-recovery-key-words`, `settings-recovery-key-word-${n}`, `settings-recovery-key-written-btn`, `settings-recovery-key-cancel-btn`, `settings-recovery-key-confirm`, `settings-recovery-key-confirm-input-${i}`, `settings-recovery-key-confirm-btn`, `settings-recovery-key-confirm-cancel-btn`, `settings-recovery-key-notice`, `settings-recovery-key-error` |
| `RecoveryRestoreForm` | `device-recovery-restore-open-btn`, `device-recovery-restore`, `device-recovery-restore-words-input`, `device-recovery-restore-submit-btn`, `device-recovery-restore-cancel-btn`, `device-recovery-restore-error`, `device-recovery-restore-done`, `device-recovery-restore-devices-link` |
| `VaultResetBanner` | `vault-reset-banner`, `vault-reset-banner-cancel-btn`, `vault-reset-banner-error`, `vault-stale-head-banner`, `vault-stale-head-confirm-btn`, `vault-stale-head-error`, `vault-pending-devices-banner` |
| `ShortcutCheatsheetModal` / `ChordHud` | `shortcut-cheatsheet-modal`, `shortcut-cheatsheet-modal-close-btn`, `shortcut-cheatsheet-action-${actionId}`, `shortcut-chord-hud` |
| `BridgesPanel` | `settings-bridge-plan-upgrade-${bridgeId}` |
| `RuntimeConfigurationOptions` | `${debugPrefix}-bridge-plan-upgrade` |
| `ExtensionBadges` | `provider-extension-badge-${provider}`, `provider-extension-help-${provider}`, `provider-extension-install-hint-${provider}`, `provider-extension-install-copy-btn-${provider}`, `conversation-signal-badge`, `conversation-signal-badge-btn` |
| `PermissionCards` | `conversation-permission-cards`, `permission-card-${id}`, `permission-card-countdown-${id}`, `permission-card-status-${id}`, `permission-card-input-${id}`, `permission-card-diff-toggle-${id}`, `permission-card-diff-${id}`, `permission-card-error-${id}`, `permission-card-allow-btn-${id}`, `permission-card-deny-btn-${id}`, `permission-card-expired-${id}`, `terminal-prompt-card-${id}`, `terminal-prompt-open-btn-${id}` (`${id}` = blocker_id) |
| `LiveToolActivity` | `live-tool-activity`, `live-tools-row`, `live-tools-summary`, `live-tools-duration`, `live-tools-agent`, `live-tools-shell-${sessionId}` (clickable shell row) |

### Shared component: SearchableSelect

`SearchableSelect` is the scalable single-select used where option lists can be large (10–50+), e.g. the New chat agent/project pickers. It requires a `debugId` and derives child IDs: `${debugId}` (trigger button), `${debugId}-popover`, `${debugId}-search-input`, `${debugId}-list`, `${debugId}-option-${value}`, `${debugId}-empty`, `${debugId}-loading`, and `${debugId}-count`. Each option renders title + optional tag + subtitle + monospace id, and search matches title/tag/subtitle/id/keywords. Current callers: `new-convo-agent-select`, `new-convo-project-select`.

### Shared component: AgentSelect

`AgentSelect` accepts an optional `debugId` prop that maps directly to `data-debug-id` on the underlying `<select>`. Always pass `debugId` when using `AgentSelect`:

```tsx
<AgentSelect debugId="create-task-assignee-select" ... />
```

### Shared component: AgentPicker

`AgentPicker` accepts a required `debugId` prop and derives child IDs from it: `${debugId}-search-input`, `${debugId}-agent-grid`, `${debugId}-agent-card-${agentId}`, `${debugId}-agent-run-${agentId}`, `${debugId}-remote-section-${peerId}`, `${debugId}-remote-card-${peerId}-${remoteAgentSlug}`, `${debugId}-run-id-input`, `${debugId}-run-submit-btn`, `${debugId}-create-id-input`, and `${debugId}-create-submit-btn`. Always pass a page-specific `debugId` such as `home-agent-picker`.

### Shared component: AgentPickerV2

`AgentPickerV2` is the store-backed, side-effect-free agent selector. It reads agents + durable identities from `useListAgentsQuery` and owns all filtering/search/grouping; callers only configure `entityTypes` (`agent_id` / `agent_instance_id`), `multiple`, `projectId`, `includeRemoteProxies`, `includeUserProxy`, `filterPredicate`, and `defaultSelected` (an `AgentSelection[]` or `string[]` used to pre-highlight/seed the selection). It emits `AgentSelection[]` via `onChange` (single-mode click, fires immediately) or `onConfirm` (multi-mode OK). It never launches or binds agents. Bound remote proxies appear inline (local ids) with a `remote` tag. It requires a `debugId` and derives child IDs: `${debugId}-close-btn`, `${debugId}-search-input`, `${debugId}-results`, `${debugId}-selected-summary`, `${debugId}-chip-${type}:${id}`, `${debugId}-chip-remove-btn-${type}:${id}`, `${debugId}-clear-all-btn`, `${debugId}-section-agent-ids`, `${debugId}-section-instances`, `${debugId}-row-${type}:${id}`, `${debugId}-row-remote-tag-${type}:${id}`, `${debugId}-loading`, `${debugId}-empty`, and (multi-mode) `${debugId}-footer`, `${debugId}-cancel-btn`, `${debugId}-ok-btn`. Current callers: `task-assignee-agent-picker` (single) and `task-reviewer-agent-picker` (multi).

### Adding new elements

When adding any new interactive element to the UI:

1. Choose an ID following the naming convention above.
2. Add `data-debug-id="your-id"` to the element.
3. Add the ID to the relevant row in the per-component registry table above.

## Wrapper Lifecycle Notes

- Wrapper checks for an exact existing tmux window before registration.
- If the window exists, wrapper prints the tmux location and asks whether to close it.
- Tmux window matching uses exact `list-windows` matching, not fuzzy tmux target matching.
- Wrapper exits if the agent tmux pane disappears.
- Wrapper attempts re-registration and WS reconnect after repeated heartbeat failures, allowing it to survive daemon restarts.
- When creating a new tmux session, wrapper creates the agent window directly and avoids an extra default shell window.

## Git Hooks

- Run `scripts/install-git-hooks.sh` once per clone (worktrees share it). Its pre-commit hook
  runs `scripts/check-npm-deps-hash.sh --staged` whenever `package-lock.json` or `flake.nix`
  is staged and fails if `flake.nix`'s `npmDepsHash` no longer matches the lockfile. It skips
  when `nix` is not on `PATH`.
- A stale `npmDepsHash` still builds on any machine that has the old deps in its store
  (fixed-output derivation), so it only breaks on a fresh deploy — do not rely on a local
  `nix build` to catch it.

## Running Odin Tests

- Always pass `-collection:odin_test=src` and a unique `-out:` so parallel runs do not
  clobber each other's binaries, e.g.
  `odin test src/hub/transport/http -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/http-$$`.
- **Put the test binary under `$HOME` (e.g. `$HOME/.cache/heimdall-tests/`), not `/tmp`.**
  On managed cloudtops an endpoint agent (CrowdStrike Falcon; `audit INTEGRITY_RULE`
  entries in the journal) SIGKILLs the *first* execution of a never-seen binary under
  `/tmp` a few seconds in. The symptom is the whole suite dying with exit 137 right after
  a fresh build, while re-running the identical binary passes — it is not a test bug, and
  no in-tree process sends the signal (verified with `strace -f -e signal=all`). The same
  fresh binary built into `$HOME` passes on its first run.
- Bridge tests spawn real children (`setsid sh -c …`, `git`, `ps`); kill them with
  `bridge_shell_test_kill_pid`, which only group-kills a child that is provably its own
  session leader and never the runner's group.

## Task Chain Best Practices

When coordinating a task chain, the designated Coordinator Agent must adhere to the following workflow upon task completion:

1. **Verify All Tasks:** Review the outputs of all individual tasks in the chain to ensure they are fully complete, correct, and work together.
2. **Submit Verifiable Evidence:** When moving the task chain to `completed` (using the `ham-ctl task-chains status --status completed --final-summary "..."` command), the coordinator must provide a comprehensive, high-fidelity final summary. This summary MUST include:
   - **Verifiable Results/Evidence:** Specific outputs, behavior descriptions, or test logs proving correctness.
   - **Git Commits:** The hashes of all commits created or reviewed as part of the task chain.
   - **File Paths:** Precise relative or absolute paths of the files modified or created.
   - **Result Summary:** A concise overview of the accomplishments.
3. **Propose Quality Rating:** Propose a quality rating status of `good` or `bad` for the task chain.
4. **Reasoning:** Provide clear, objective engineering rationale explaining why the chain succeeded (`good`) or if there were critical defects or difficulties encountered (`bad`).

## Preview-Driven UI Development (Live Production Data + Instant HMR)

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

