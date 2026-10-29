# Heimdall AI Manager Project Guide

Heimdall is a Hub-and-Bridge multi-agent orchestration system. The current runtime consists of:

- `ham-hub` (Odin) — durable state, authorization, task coordination, and HTTP/WebSocket APIs.
- `ham-bridge` (Odin) — one per execution device; connects to the Hub and manages local agents,
  shell jobs, files, provider discovery, and bootstrap materialization.
- `ham-pty-host` (Rust) — the Bridge's local agent process and terminal host.
- `ham-ctl` (Odin) — the CLI for agents and operators.
- Heimdall UI — React/TypeScript/Redux with Electron and web clients.

The Hub coordinates execution on Bridges; it does not launch agent processes on the Hub host.
Agent launches use `ham-pty-host`. The old `ham-daemon`/`ham-wrapper` and tmux agent-launch
architecture is historical, not a runtime option. The authoritative launch path is
[`src/bridge/pty_host_runtime.odin`](src/bridge/pty_host_runtime.odin).

## Architecture Invariants

- The Hub owns durable agents/instances, tasks, workflows, chat, memory, projects, artifacts,
  authorization, and audit state. The repository layer persists it in SQLite.
- Live Bridge connections, runtime maps, viewers, and tool activity are transient projections;
  they are not substitutes for durable records. See [runtime registry](docs/runtime-registry.md).
- `agent_id` is a durable identity; `agent_instance_id` identifies one managed instance. An
  instance record can survive process exit and be restarted; it is not a PID.
- Before starting an agent, the Bridge recreates its managed run directory and materializes
  instructions, memories, skills, and the CLI shim. Bootstrap uses content-addressed manifests
  and blobs, with a full-payload fallback.
- Agent message notifications tell the agent to fetch durable messages with `ham-ctl chat read`.
  Do not infer message bodies or task completion from a terminal notification.
- Every task v2 mutation runs in one unit of work; network operations and other side effects
  occur after commit. Preserve the `tx_mutex -> state_mutex` lock order. See
  [task v2 service](src/hub/service/taskv2/service.odin).
- Owner authorization, agent/Bridge credentials, and human sessions are different boundaries.
  Never broaden runtime access by substituting one user's identity for another.

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

## Identity and Authorization

The current records are defined in [`src/hub/domain`](src/hub/domain) and auth contracts in
[`src/contracts/auth.odin`](src/contracts/auth.odin):

| Identifier | Meaning |
| --- | --- |
| `agent_id` | Durable named agent, associated with a template and instructions. Fleet rows, task assignees, and reviewers use this identity. |
| `agent_instance_id` | Managed instance bound to an agent, Bridge, provider/model, run directory, conversation, and optional project/chain. |
| `conversation_id` | Durable conversation binding used to read and route chat. |
| `bridge_id` | Enrolled execution device and its authenticated Hub connection. |
| `task_id` / `lease_id` | Durable work item / temporary authority to work or review its current attempt. |

Humans sign in through OIDC/browser sessions; Bridges use enrolled Bridge credentials; agents
use instance tokens through the local Bridge. Do not assume token values or derive credentials
from identifiers. See [authentication](docs/auth-oidc.md),
[desktop login](docs/desktop-auth.md), and [self-hosting](SELF_HOSTING.md).

The durable owner boundary is enforced by
[`src/hub/service/ownership/ownership.odin`](src/hub/service/ownership/ownership.odin).
Fleet roles are agent work/review roles, not a grant of human access to another person's runtime.

## Repository Layout

```text
src/
  contracts/          shared wire and auth contracts
  hub/
    domain/           durable records and domain types
    repository/iface/ repository contracts and unit-of-work boundary
    repository/sqlite/ SQLite implementations and migrations
    service/          application services; taskv2 is the lease/review/workflow engine
    transport/http/   HTTP and WebSocket handlers
  bridge/             local execution, bootstrap, provider hooks, and Hub connection
  ctl/                ham-ctl command parsing and agent/user operations
  lib/                shared HTTP, auth/vault, VCS, transport, and utility code
  prompts/            shipped agent instructions, skills, and workflow templates
  ui/                 React/Redux app, API client, and Electron shell
tools/pty_host/        Rust ham-pty-host daemon and protocol
extensions/           provider-native activity, file-edit, and permission hooks
```

- [`flake.nix`](flake.nix) defines `ham-hub`, `ham-bridge`, `ham-pty-host`, `ham-ctl`,
  UI packaging, and release builds.
- [`package.json`](package.json) defines frontend scripts and dependencies.
- [`SELF_HOSTING.md`](SELF_HOSTING.md) is the operator setup/configuration guide.
- [`src/hub/service/taskv2`](src/hub/service/taskv2) is the current task engine.
  [The earlier FSM proposal](docs/fsm_task_chain_engine.md) is historical design material,
  not the current state/command reference.

### Outbound HTTP boundary

- `httpc` — the ONLY outbound HTTP(S) client (libcurl). Requests are structured (parsed base URL + path segments + query params, validated headers, JSON/form/raw bodies); never build URLs, headers or bodies with string interpolation. `scripts/check-http-boundary.sh` (also `nix flake check`) fails if any other package touches libcurl or `http_client` comes back. See `src/lib/httpc/README.md`.
  - **One pinned libcurl, linked statically.** `nix/libcurl-pin.json` pins the curl (and zlib) source tarball for every build; `nix/libcurl.nix` builds it (Linux release: static musl with OpenSSL 3; macOS release: static OpenSSL 3 + Apple SecTrust; Nix-native packages and `nix develop`: the same version as a shared library) and `scripts/windows/build-libcurl.ps1` builds it for Windows (Schannel). Release binaries are fully static on Linux and gated by `scripts/release/package-local-binary-tarball.sh` (no NEEDED at all; macOS: system frameworks only) and `scripts/windows/check-dependencies.ps1`. Builds pass `-define:HAM_CURL_VERSION=<pin>` and `httpc.init()` refuses any other libcurl. To bump: edit the pin (version, URLs, SHA-256 checked against the release signature), build the `release-*` attrs, run the httpc suite. Never link nixpkgs' `curl` into an Odin package.

## Durable State and Runtime Projections

The Hub's domain/repository/service layers replace the old daemon JSONL stores. Durable business
records are persisted by [`src/hub/repository/sqlite`](src/hub/repository/sqlite). Task events
and attempts retain history; live lease rows are released when work ends. Runtime connection
maps, process handles, viewer queues, pending permission prompts, and activity snapshots have
their own lifetimes.

Do not equate a live process, a durable instance record, and a task lease. A task can be waiting
for review while its worker process has stopped; an instance can be restarted for another
attempt. See [task records](src/hub/domain/taskv2.odin),
[instance records](src/hub/domain/agent.odin), and [pane transport](docs/pane-transport.md).

Memory has five domain types: `fact`, `habit`, `episode`, `expertise`, and `skill`.
Targeting uses lists of agent, project, template, and Bridge IDs; non-empty dimensions must all
match. Pending proposals need human approval before becoming active bootstrap knowledge.
`template` is a targeting dimension, not a memory type accepted by the content service. See
[`src/hub/domain/content.odin`](src/hub/domain/content.odin) and
[the memory/bootstrap reference](docs/reference/heimdall_memory_system_and_bootstrap.md).

Artifacts have durable metadata and separately stored content. A shell session, artifact,
conversation, and task each have their own ownership checks; access to one must not imply
access to another.

## Agent Launch and Bootstrap

1. The UI, CLI, or task matcher requests a managed instance launch. The Hub validates ownership
   and resolves the target Bridge and provider/model before dispatching a Bridge command.
2. The Bridge prepares the provider command and recreates the managed instance run directory.
   [Pre-spawn materialization](src/bridge/bootstrap_prespawn.odin) writes the bootstrap before
   a provider process starts.
3. [Bootstrap assembly](src/bridge/bootstrap_service.odin) writes provider-specific instructions
   (`AGENTS.md` or `CLAUDE.md`), applicable memory/skills, `heimdall-bootstrap-manifest.json`,
   and `./.heimdall/bin/ham-ctl`. The Bridge also supplies the local endpoint, instance identity,
   and agent credential.
4. The Bridge spawns the agent through the local `ham-pty-host` daemon. The daemon owns child
   processes, terminal I/O, and terminal state; the Bridge forwards runtime observations to
   the Hub.
5. Provider-native extensions supply structured activity, tools, edits, and permission events
   where supported. Capability and provider differences matter; do not infer a successful tool
   result from a terminal screen or from a missing native event.
6. Once initialized, the agent signals readiness with `ham-ctl start-success`. Incoming notices
   direct it to fetch messages or a task context pack.

Provider launch recipes live in the Hub catalog, with effective provider availability and
model observations per Bridge. The catalog records executable/arguments, model selection,
prompt delivery, bootstrap paths, and extension metadata. Provider authentication is part of
the execution device's provider setup; do not describe the catalog as a universal API-key store.
See [provider records](src/hub/domain/provider.odin) and
[`src/hub/service/provider`](src/hub/service/provider).

## Task Lifecycle and Reviews

A task's stored states are `backlog`, `ready`, `in_progress`, `in_review`, `done`, and
`cancelled`. Blocking, holds, startup failures, and lease expiry add lifecycle detail; they
are not a license to set a task's status manually. See
[`src/hub/domain/taskchain.odin`](src/hub/domain/taskchain.odin) and
[the fold](src/hub/service/taskv2/fold.odin).

- Create a task with a non-empty goal and acceptance items, then publish it if it is a draft.
  Assign ordinary work to durable `agt_...` identities, not another runtime's `inst_...` ID.
  Workers choose and report appropriate checks; briefs do not configure a verification command.
- A work lease makes a ready task `in_progress`. One instance holds at most one lease; one
  task has at most one work lease. `lease next` returns the current lease or claims eligible work.
- Read `TASK.md` on wake. When it names a Workdir, do all edits, checks, and commits there.
  Git-backed chain directories use per-task worktrees; do not edit the shared checkout instead.
- Record a short plan and milestones as task comments. Keep a long-running lease alive with
  `lease heartbeat` at least every 15 minutes. A `lease_lost` response ends the old authority.
- `lease submit` records the attempt and releases the lease for review. `lease handoff`
  returns unfinished work; `lease block` records an external dependency. There is no
  `tasks done` or manual status transition in the current agent workflow.
- Reviews use `review post --verdict approve|request_changes`. The gate checks the current
  attempt's required named reviewers, fleet review roles, and user approval when required.
  The author does not review their own work. A request for changes wins over approvals.
- Review completion and merge-back are separate outcomes. A task's branch is merged through
  its directory's Bridge; conflicts/failures remain visible and affect downstream readiness.
- Task dependencies and workflow-run dependencies require success. Chains contain both ordinary
  tickets and engine-managed workflow stages. Use workflow run/status/output/retry/cancel for
  those runs rather than editing stage identities.
- Finishing the current batch does not complete the chain. Inspect `task-chain graph`, then
  explicitly complete the current work revision once all included items succeeded, no leases
  remain, and any pending proposal is decided.

### Solo mode

When the coordinator is also a worker in the fleet, it pulls work with `lease next`; it is
not automatically wake-granted work. User review is the default, and the soloist cannot approve
its own work. The coordinator stays running across lease submissions/switches. Ordinary
non-coordinator lease holders are stopped on release and re-bootstrapped when reused; a reused
durable instance does not mean the previous provider conversation is retained.
See [lease release and solo rules](src/hub/service/taskv2/lease.odin).

### CLI and Communication

From an agent run directory, use the generated `./.heimdall/bin/ham-ctl` wrapper.
It authenticates to the local Bridge, which routes authorized operations to the Hub.
User/operator commands have a separate `ham-ctl hub` surface; inspect `ham-ctl help hub`
rather than copying retired `--as user`/`--as agent` examples.

```bash
ham-ctl --help
ham-ctl task --help
ham-ctl task-chain --help
ham-ctl lease --help
ham-ctl workflow --help
ham-ctl chat read
ham-ctl chat send --to user --body "Progress and next steps."
ham-ctl lease next
ham-ctl task comment <task-id> --body "1. Inspect the source. 2. Make and check the change."
ham-ctl lease heartbeat --note "Checking the change."
ham-ctl lease submit --summary "Files changed; checks and outcomes." --decision "Choice and why."
ham-ctl review post --verdict approve
ham-ctl task recheck <task-id>
ham-ctl task-chain graph
ham-ctl task-chain complete <chain-id> --expected-work-revision <n> --summary "Final evidence."
```

Use chat for user-facing replies, questions, and milestone updates. Use task comments and the
submit handoff for technical evidence, decisions, dead ends, and checks. `chat send --to` accepts
`user` or an exact target instance ID; the recipient fetches durable messages with `chat read`.
Do not treat a notification, answer selection, or silence as a review verdict.

Choose a tracked shell run for build/test commands and any command that may take time:

```bash
ham-ctl shell run --cmd 'npm run build' --cwd <workdir>
ham-ctl shell run --cmd 'long-running-check' --cwd <workdir> --bg
ham-ctl shell serve --cmd 'npm run dev' --cwd <workdir> --port 5173
ham-ctl shell log <session-id>
```

A foreground `shell run` waits for completion; `--bg` explicitly backgrounds it. `serve`
starts a long-running service. Always pass the actual working directory. For a user preview,
present the returned `preview_url`; see the preview guidance below.

## UI Debug IDs

Every interactive element in the UI must have a `data-debug-id` attribute. UI tests and browser automation (Playwright/Puppeteer scripts under `tests/e2e/` and `scripts/`) use these IDs as stable selectors. The Electron app deliberately has no debug-control server (REQ-ELECTRON-NO-REMOTE-DEBUG-1); do not add one.

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
| `HomeChainSearch` | `home-chain-prev-btn`, `home-chain-next-btn`, `home-chain-page-status`, `home-chain-retry-btn` |
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
| `AppearanceSettings` | `settings-external-keyboard-checkbox` |
| `SessionConfig` | `session-config-reconnect-btn`, `session-config-daemon-url`, `session-config-user-id` |
| `DeviceVaultScreens` | `device-genesis-screen`, `device-waiting-screen`, `device-waiting-code`, `device-waiting-no-code`, `device-waiting-new-code-btn`, `device-waiting-fingerprint`, `device-waiting-reset-scheduled`, `device-waiting-reset-btn`, `device-waiting-reset-confirm-btn`, `device-waiting-reset-cancel-btn`, `device-waiting-error`, `device-other-account-warning`, `device-other-account-alert`, `device-other-account-ack-checkbox`, `device-other-account-continue-btn`, `device-other-account-error`, `device-vault-unsupported`, `device-vault-revoked`, `device-vault-reapprove-btn`, `device-vault-reapprove-error`, `device-vault-initializing`, `device-vault-error`, `device-vault-error-message`, `device-vault-retry-btn`, `device-vault-start-over-btn`, `device-vault-start-over-phrase-input`, `device-vault-reset-device-data-phrase-input`, `device-vault-reset-device-data-btn`, `device-vault-pair-again-btn`, `device-vault-error-detail` |
| `DeviceApprovalPage` | `device-approval-page`, `device-approval-code-input`, `device-approval-lookup-btn`, `device-approval-change-code-btn`, `device-approval-requested-at`, `device-approval-review`, `device-approval-kind`, `device-approval-host-label`, `device-approval-fingerprint`, `device-approval-label-input`, `device-approval-approve-btn`, `device-approval-deny-btn`, `device-approval-progress`, `device-approval-done`, `device-approval-home-btn`, `device-approval-another-btn`, `device-approval-error` |
| `DevicesPanel` | `settings-devices-panel`, `settings-devices-account-fingerprint`, `settings-devices-log-head`, `settings-devices-reset-alert`, `settings-devices-reset-cancel-btn`, `settings-devices-add-link`, `settings-devices-list`, `settings-devices-empty`, `settings-device-row-${deviceId}`, `settings-device-current-badge`, `settings-device-retired-hint-${deviceId}`, `settings-device-unpaired-hint-${deviceId}`, `settings-device-revoke-confirm-${deviceId}`, `settings-device-revoke-single-approver-${deviceId}`, `settings-device-revoke-approved-${deviceId}`, `settings-device-key-error-${deviceId}`, `settings-device-send-key-btn-${deviceId}` (only after a failed delivery), `settings-device-approve-link-${deviceId}`, `settings-device-deny-btn-${deviceId}`, `settings-device-revoke-btn-${deviceId}` (never rendered for the current device), `settings-device-revoke-confirm-btn-${deviceId}`, `settings-device-revoke-cancel-btn-${deviceId}`, `settings-devices-notice`, `settings-devices-error` |
| `RecoveryKeySection` | `settings-recovery-key`, `settings-recovery-key-status`, `settings-recovery-key-create-btn`, `settings-recovery-key-replace-btn`, `settings-recovery-key-words`, `settings-recovery-key-word-${n}`, `settings-recovery-key-written-btn`, `settings-recovery-key-cancel-btn`, `settings-recovery-key-confirm`, `settings-recovery-key-confirm-input-${i}`, `settings-recovery-key-confirm-btn`, `settings-recovery-key-confirm-cancel-btn`, `settings-recovery-key-notice`, `settings-recovery-key-error` |
| `RecoveryRestoreForm` | `device-recovery-restore-open-btn`, `device-recovery-restore`, `device-recovery-restore-words-input`, `device-recovery-restore-submit-btn`, `device-recovery-restore-cancel-btn`, `device-recovery-restore-error`, `device-recovery-restore-done`, `device-recovery-restore-devices-link` |
| `VaultResetBanner` | `vault-reset-banner`, `vault-reset-banner-cancel-btn`, `vault-reset-banner-error`, `vault-stale-head-banner`, `vault-stale-head-confirm-btn`, `vault-stale-head-error`, `vault-pending-devices-banner` |
| `ShortcutCheatsheetModal` / `ChordHud` | `shortcut-cheatsheet-modal`, `shortcut-cheatsheet-modal-close-btn`, `shortcut-cheatsheet-action-${actionId}`, `shortcut-chord-hud` |
| `BridgesPanel` | `settings-bridge-plan-upgrade-${bridgeId}`, `settings-bridge-uninstall-btn-${bridgeId}`, `settings-bridge-uninstall-confirm-${bridgeId}`, `settings-bridge-uninstall-cancel-${bridgeId}` (uninstall/revoke controls render only in Electron, when `window.odinApi.bridgeManager` exists; the web panel offers Update + Rename only) |
| `ThisMachineCard` (Electron only, top of `BridgesPanel`) | `settings-this-machine-card`, `settings-this-machine-status`, `settings-this-machine-version`, `settings-this-machine-hub`, `settings-this-machine-hub-edit`, `settings-this-machine-hub-input`, `settings-this-machine-hub-save`, `settings-this-machine-hub-cancel`, `settings-this-machine-profile-input`, `settings-this-machine-reenroll-hint`, `settings-this-machine-setup-btn`, `settings-this-machine-update-btn`, `settings-this-machine-reenroll-btn`, `settings-this-machine-uninstall-btn`, `settings-this-machine-cancel-btn`, `settings-this-machine-error`, `settings-this-machine-operation`, `settings-this-machine-confirm-${kind}`, `settings-this-machine-confirm-ok`, `settings-this-machine-confirm-cancel`, `settings-this-machine-purge`, `settings-bridge-wizard`, `settings-bridge-wizard-progress`, `settings-bridge-wizard-step-${step}`, `settings-bridge-wizard-recoveries-${step}`, `settings-bridge-wizard-pairing`, `settings-bridge-wizard-copy-code`, `settings-bridge-wizard-open-log-${step}`, `settings-bridge-wizard-result`, `settings-bridge-wizard-retry`, `settings-bridge-wizard-replace-account`, `settings-bridge-log-toggle`, `settings-bridge-log` |
| `SidebarUpdateBadge` | `shell-bridge-status-control`, `shell-bridge-status-btn`, `shell-bridge-status-popover`, `shell-bridge-check-update-btn`, `shell-bridge-update-available-btn`, `shell-bridge-manage-btn` (opens Settings > Bridges), `shell-bridge-operation-error` |
| `RuntimeConfigurationOptions` | `${debugPrefix}-bridge-plan-upgrade`, `${debugPrefix}-model-refresh-btn`, `${debugPrefix}-model-catalog-status` |
| `ModelCatalogRefresh` in fleet rows | `fleet-${agentId}-${bridgeId}-model-refresh-btn`, `fleet-${agentId}-${bridgeId}-model-catalog-status` |
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

### Provider extension installation controls

The web app no longer installs provider extensions; `ham-bridge setup` / `ham-bridge update` does. The manual install hint and copy button live in `ExtensionBadges` (above).

| Component | Debug IDs |
| --- | --- |
| `BridgesPanel` | `settings-bridge-update-extensions` |

### Quoted context controls
| Component | Debug IDs |
|---|---|
| QuoteSelectionPopover | `message-quote-popover`, `message-quote-btn`, `message-quote-status` |
| ComposerContextChips | `composer-quote-chips`, `composer-quote-chip-${quoteId}`, `composer-quote-details-${quoteId}`, `composer-quote-remove-${quoteId}`, `composer-quote-source-${quoteId}` |

### Adding new elements

When adding any new interactive element to the UI:

1. Choose an ID following the naming convention above.
2. Add `data-debug-id="your-id"` to the element.
3. Add the ID to the relevant row in the per-component registry table above.

## Runtime Lifecycle Notes

- The Bridge uses the local `ham-pty-host` daemon for agent launch and terminal I/O;
  legacy PTY runtime flags do not restore tmux or wrapper launches.
- Pre-spawn bootstrap recreation clears the managed run directory before writing the new
  instance context. Keep project edits in the task Workdir, not the bootstrap directory.
- Bridge reconnect rebuilds connection-scoped runtime observations. Durable instance and
  task records remain in the Hub; disconnection alone is not proof a remote process stopped.
- Provider-native permissions and activity are capability-dependent. Preserve native prompt
  fallback when a hook times out or cannot deliver a decision.
- Keep socket ownership and viewer backpressure rules intact when changing terminal transport.
  See [runtime registry](docs/runtime-registry.md) and [pane transport](docs/pane-transport.md).

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

When coordinating a chain:

1. **Verify the work:** inspect task outputs, checks, review outcomes, and merge results.
2. **Finish explicitly:** read `ham-ctl task-chain graph` for the current work revision. Every
   included ticket must be done and every included workflow run must have succeeded; no
   leases or pending proposal may remain. Then run:
   ```bash
   ham-ctl task-chain complete <chain-id> --expected-work-revision <n> --summary "Final acceptance and evidence."
   ```
3. **Record evidence:** the completion summary must identify results, checks and outcomes,
   commits, changed paths, and any limits. Do not report unrun tests as passing.
4. **Propose a quality rating:** state `good` or `bad` with objective rationale. Batch-finished
   notifications are a cue to assess remaining work, not to infer chain completion.
5. **Preserve review authority:** keep required user gates. Record a verdict on behalf of the
   user only after an explicit user decision; never infer approval from silence.

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

