# Heimdall

A multi-agent orchestration system for developers who want more than a single chat window.

Heimdall runs a fleet of autonomous AI coding agents across your machines, coordinates
their work through a shared hub, and gives you a real-time dashboard to watch, steer, and
audit everything they do. Instead of one long conversation that slowly falls apart, you get
a team of specialized agents with durable memory, independent review, and a structured
record of every decision.

## The problem

If you do real project work in a single Claude Code chat session, you keep hitting the same
walls:

- **Context explosion.** A long conversation degrades in quality as the window fills up, and
  when you restart to clear it you lose everything you had built up.
- **No parallelism.** One thread means one thing at a time. You cannot investigate a bug,
  implement a feature, and review a change at the same time.
- **No persistent memory.** The agent forgets your project's facts, conventions, and past
  decisions between every session, so you re-explain the same context again and again.
- **No audit trail.** To find out what actually happened you have to re-read the entire
  conversation. There is no structured, skimmable record of the work.
- **No independent review.** The same agent that writes the code also signs off on it.
  Nothing ever gets a genuine second pair of eyes.
- **Provider lock-in.** You are tied to a single LLM provider, with no easy way to mix
  models or switch when a better one comes along.

## How Heimdall solves it

- **Multi-agent coordination.** A Coordinator publishes focused tasks and configures a fleet
  of durable agent identities. Workers hold leases; required reviewers and optional user
  approval decide whether the submitted attempt is accepted.
- **Persistent, scoped memory.** Facts, habits, episodes, expertise, and skills are stored
  durably and made available at bootstrap. Scope can combine agent, project, template, and
  device targets, so approved knowledge survives individual sessions.
- **Focused task context.** Each lease carries the task brief, previous attempts, dependency
  handoffs, and relevant chain context. Ordinary workers/reviewers are re-bootstrapped when
  reused; Solo mode lets the Coordinator do the work while the user reviews.
- **Structured audit trail.** Task events, attempts, comments, decisions, and review verdicts
  record the work and the evidence used to accept it.
- **Provider choice.** Provider launch recipes and model catalogs let you select the available
  coding agent and model on each Bridge, with native extensions for supported runtime signals.
- **Cross-device fleet.** Agents execute on your devices while the Hub coordinates their work,
  including ordinary tickets and staged workflow runs in the same chain.

## Architecture

Heimdall is a Hub-and-Bridge system. A central Hub owns durable shared state; a Bridge on each
execution device manages its local processes. The desktop and web UI show conversations,
tasks, memory, artifacts, shells, and runtime activity.

- **Hub (`ham-hub`, Odin).** Authenticates requests and coordinates agents, task leases,
  reviews, dependencies, workflow runs, projects, and content through SQLite-backed services.
- **Bridge (`ham-bridge`, Odin).** Connects to the Hub, materializes agent bootstrap files,
  discovers local providers/models, and handles tracked shell jobs and project files.
- **Terminal host (`ham-pty-host`, Rust).** The Bridge's local daemon for launching agent
  processes and managing terminal input, output, and screen state. Agent launches no longer
  use the old wrapper/tmux runtime.
- **CLI (`ham-ctl`, Odin).** Agents use their generated run-directory wrapper to read chat,
  pull/submit leases, propose memories, and operate other authorized resources through the
  local Bridge. Operators have a separate Hub command surface.
- **UI (React / TypeScript / Redux, Electron + web).** The interface to the Hub, with
  conversations, the attention deck, task/fleet views, and terminal/artifact tools.

See [the contributor architecture guide](AGENTS.md), [runtime connection lifecycle](docs/runtime-registry.md),
[terminal transport](docs/pane-transport.md), and [self-hosting](SELF_HOSTING.md).

## How work flows

1. Describe the goal to the Coordinator.
2. The Coordinator creates a plan and publishes tasks with goals, acceptance items, and
   dependencies, or starts a staged workflow run.
3. Eligible workers receive leases. Each reads its task context and works in the named
   checkout; Git-backed tasks use their own worktree.
4. The worker records checks and decisions and submits the attempt. Required reviewers use
   `approve` or `request_changes`; tasks that require user approval also wait for your verdict.
5. Accepted Git-backed work is merged through its Bridge. Merge failures and conflicts remain
   visible, and downstream work waits for successful prerequisites.
6. The Coordinator explicitly completes the chain after all included tickets and workflow
   runs succeed and no leases or pending proposal remain. Useful lessons can be proposed as
   durable memories for your review.

In Solo mode, the Coordinator pulls and implements each task itself and the user reviews.
It remains running between tasks; it does not delegate by default.

A finished batch is not the same as a completed chain. Work and reviews leave a durable record
that you can inspect and steer from the UI.

## macOS desktop app

Download the signed and notarized DMG for the Mac's architecture from GitHub Releases
(`arm64` for Apple Silicon, `x64` for Intel), drag Heimdall to Applications, and sign in
with the Hub's OIDC provider. Heimdall then stays available as a lightweight macOS menu-bar
app when its main window is closed.

The menu-bar control shows the local Bridge state, installed version, Hub, and signed-in
user. It can install the Bridge bundled in the DMG, start enrollment and display/copy the
browser pairing code, check for updates, restart the Bridge, or re-enroll the same durable
Bridge identity. `Launch at Login` is enabled on first install and can be disabled from the
same menu. Quitting the desktop app removes the menu item but does not stop the separately
managed Bridge LaunchAgent.

## Windows desktop app

Download `Heimdall-<version>-x64.exe` from GitHub Releases and follow the setup wizard.
Windows releases are currently unsigned, so Windows identifies the publisher as unknown
and Microsoft Defender SmartScreen may require `More info` → `Run anyway`. Verify the
installer against the release's `SHA256SUMS` before running it. The per-user install does
not require administrator access. Sign in with the Hub's OIDC provider; Heimdall then
stays available in the Windows notification area when its main window is closed. Windows
on Arm currently runs the x64 build through the operating system's compatibility layer.

The tray control shows the local Bridge state, installed version, Hub, and signed-in user.
It can install the checksum-verified Bridge bundled with the desktop app, start enrollment and
display/copy the browser pairing code, check for Bridge or Heimdall updates, restart the
Bridge, or re-enroll the same durable Bridge identity. `Launch at Login` is enabled on
first install and can be disabled from the tray. Quitting the desktop app removes the tray
icon but does not stop the separately managed Bridge Scheduled Task.

## Keyboard shortcuts

Heimdall's unmodified-key shortcuts use a Vim-style sequence grammar. Press `?` to open
the live cheatsheet for the actions available in the current view.

- `g` scopes an action to the whole app and opens the resulting resource in its own
  Workspace.
- `s` scopes an action to the current Workspace and focused pane.
- `o` opens an existing resource; `n` creates a new one.
- `c` means conversation, `t` means task-chain coordinator conversation, and `s` means
  shell.
- For Workspace resource actions, no suffix replaces the focused pane, `v` opens to the
  right, and `h` opens below.

### Global resource actions

| Chord | Action |
| --- | --- |
| `g o c` | Choose and open an existing conversation |
| `g o t` | Choose a task chain and open its coordinator conversation |
| `g o s` | Choose and open a running shell across all projects |
| `g n c` | Open a new-conversation launcher with the composer focused |
| `g n s` | Open a new-shell launcher with **Start shell** focused |

`g h` still goes Home and `g s` still opens Settings. `g n t` is reserved because
creating a task chain is not the same operation as opening its coordinator.

### Current Workspace resource actions

| Base chord | Resource | Placement suffixes |
| --- | --- | --- |
| `s o c` | Existing conversation | none = replace, `v` = right, `h` = below |
| `s o t` | Task-chain coordinator | none = replace, `v` = right, `h` = below |
| `s o s` | Running shell | none = replace, `v` = right, `h` = below |
| `s n c` | New-conversation launcher | none = replace, `v` = right, `h` = below |
| `s n s` | New-shell launcher | none = replace, `v` = right, `h` = below |

For example, `s o t v` chooses a task chain and opens its coordinator to the right.
`s n t` is reserved. A base chord such as `s n c` is both an action and a prefix: press
`Enter` to execute it immediately, add `v` or `h`, or pause for 1.2 seconds to execute
the base action.

### Pane focus, size, and exchange

| Chord | Action |
| --- | --- |
| `s h/j/k/l` | Focus the nearest Main pane left/down/up/right |
| `s r h/l` | Narrow/widen the focused Main pane by 5%; decrease/increase focused aux width |
| `s r k/j` | Shorten/tall the focused Main pane by 5% |
| `s r =` | Equalize Main panes; reset the focused aux pane to its default width |
| `s e h/j/k/l` | Exchange the focused Main pane with its nearest directional neighbor |
| `s w` | Focus the next Main pane |
| `s x` | Close the focused Main pane |
| `s m` | Toggle focused Main pane maximization |

The auxiliary pane is a separate dock, so it can be resized but not exchanged with a
Main pane. Shortcut sequences are shielded while typing in editable controls, Monaco,
terminals, and dialogs. Hold `Ctrl+Alt` for the established one-shot override when an
editable control has focus.

## Philosophy

Heimdall is built around a simple idea: **agents should be cheap to start, focused on
one thing, and easy for a human to steer.**

### One coordinator, leased workers

A Coordinator holds the plan, owns the chain, and is your point of contact. Fleet rows identify
which durable agents can work or review, their capacity, and their launch settings. Tasks can
name reviewers or require every fleet member holding a review role.

The task engine grants leases and releases them on submission, handoff, blocking, or expiry.
Ordinary non-coordinator holders are stopped on release and re-bootstrapped when reused. An
instance record may be reused without carrying forward the previous provider conversation.
The task context pack carries the structured handoff instead.

Solo mode keeps the Coordinator running as the worker. It pulls one task at a time, submits to
the user's review, and can continue other ready work while that review is pending. The Soloist
cannot approve its own work.

### Agents learn through memory proposals

An agent cannot update its own permanent knowledge. Instead, when it discovers something
worth keeping — a project convention, a build quirk, a decision rationale — it *proposes*
a memory. Proposals sit in a queue until you review them on the Memory page in the UI.
You approve the ones that are accurate and discard the rest. Only approved memories are
injected into future agents.

This makes learning intentional. Agents accumulate knowledge at the speed you trust them,
not at the speed they generate text.

### You steer from the task board

1. Describe the goal to the Coordinator in the conversation panel.
2. Review the plan when approval is required, then follow task progress and comments.
3. Send steering to the Coordinator or current worker when requirements change; use task
   comments for a durable record of findings and decisions.
4. Review submitted work and its reported checks. Required user review is an explicit gate,
   not implied by answering a question or leaving a comment.
5. If a task appears stuck, inspect its blocker, review requirements, and Bridge status.
   `ham-ctl task recheck <task-id>` re-evaluates current gates/readiness and merge recovery;
   it does not approve work or take over a live lease.

Work continues asynchronously where prerequisites and approval policy allow it.

### The ideal first session

1. Add a project and its codebase path on the execution Bridge.
2. Start a Coordinator for that project and describe the goal.
3. Review the proposed plan and clarify requirements.
4. Use Solo mode for work you want one agent to own, or configure a worker/reviewer fleet.
5. Follow progress, resolve questions, and review work in the attention/task surfaces.
6. Review proposed memories so future sessions inherit the knowledge you approve.

---

## Key concepts

The entities below are the building blocks of Heimdall. Understanding what each one is
and how it connects to the others makes the rest of the system easy to reason about.

---

### Agent ID

A durable named agent identity, such as a project's implementation agent or reviewer. It
stores its template/instructions and can have runtime instances on different Bridges.
Fleet work/review roles and capacity are separate configuration on that identity.

**Connected to:** instances, memory targets, fleet rows, task assignees, and named reviewers.

---

### Agent Instance ID

A managed instance of a durable agent on a Bridge, with a provider/model, run directory,
conversation, and optional project/chain. Its database record can outlive a process and be
restarted. The ID is not a PID and need not change for every lease.

**Connected to:** Agent ID, Bridge, conversation, run directory, and the current task lease.
Tasks are assigned to durable agent identities; a lease records the actual holder instance.

---

### Project

A codebase or workspace that agents work on. A Project has a name, a local path on the
bridge, and an optional VCS remote. Memories can be scoped to a project, so all agents
working on that project share the same accumulated knowledge.

**Connected to:** Memory (project-scoped memories are shared across all agents on that
project), Task Chain (a chain usually targets a specific project), Bridge (the project
path resolves on the bridge that hosts the agent).

---

### Memory

Durable knowledge that persists across agent sessions. Memory is made available to an agent
at bootstrap so its runtime starts with applicable facts, conventions, and past
decisions. There are five types:

| Type | What it stores | Example |
|------|---------------|---------|
| **Fact** | Objective, stable truths about the project or environment | "The hub API runs on port 8081" |
| **Habit** | Preferred working patterns or conventions | "Always run `npm run typecheck` before committing" |
| **Episode** | Records of past events, decisions, or incidents | "The migration on 2025-03-15 required a manual SQL fix" |
| **Expertise** | Reusable technical knowledge and reasoning | "How to diagnose a provider startup failure" |
| **Skill** | Reusable procedures or mini-runbooks | "How to add a new icon to Icon.tsx" |

Each memory can target lists of agents, projects, templates, and Bridges. Non-empty
dimensions must all match; empty target lists allow wider applicability. Only approved active
knowledge is made available at bootstrap. A template is a scope target, not a memory type.

**Connected to:** Agent ID, Project, Bridge, and agent template. Agents can propose lessons
from task work, and humans decide what becomes durable knowledge.

---

### Task Chain

A coordinated collection of work. Every chain can contain ordinary tickets and workflow
runs, with explicit dependencies between them. A task's brief names its goal, acceptance,
assignee, and review policy; leases and review verdicts record its attempts.

Task completion requires its current review gate. Chain completion is a separate, explicit
operation that checks all included work, merge outcomes, active leases, pending proposals,
and the current work revision. Finishing the current batch alone does not complete it.

**Connected to:** Project, Coordinator instance, fleet identities, tasks, workflow runs,
directories, review records, and shared chain context.

---

### Agent Run Dir

A managed directory on the Bridge for an agent instance's bootstrap and runtime context.
Before a provider process starts, the Bridge recreates it and writes instructions, applicable
memories/skills, a manifest, and `./bin/ham-ctl`.

A run directory is separate from the task's code checkout. Read `TASK.md` and use its
Workdir for project edits, checks, and commits; do not put project changes in the bootstrap
directory or assume its contents survive a relaunch.

**Connected to:** Agent Instance ID, Bridge, task context pack, provider bootstrap, and CLI shim.

---

### Bridge

The per-device daemon that connects a machine to the hub. The bridge:

- Authenticates to the hub using an expiring bridge credential (`hba_…`), obtained by
  browser-approved enrollment and refreshed automatically — see `SELF_HOSTING.md`.
- Spawns and supervises agent processes (via `ham-pty-host`).
- Executes tracked shell commands on behalf of agents and streams output back.
- Serves the local filesystem to agents for safe project exploration.

One bridge runs on each machine that should host agent processes. All bridges connect
to the same hub.

**Connected to:** Agent Instance ID (the bridge spawns and owns instances), Agent Run
Dir (run dirs are created on the bridge filesystem), Provider (the bridge resolves local
provider launch settings), Hub (bridge→hub connection is
outbound: REST over HTTPS and WebSocket over WSS through the statically linked,
pinned libcurl (`src/lib/httpc`)).

---

### Provider

The installed coding-agent runtime, such as Claude Code or Codex. The Hub's catalog describes
how to launch it, select models, deliver prompts, write bootstrap files, and discover native
extension capabilities. Each Bridge reports what is installed/enabled and its model observations.

Provider authentication belongs to the execution device's provider setup. Selecting a provider
in the catalog does not itself sign in to that provider. The effective launch settings can
vary by agent, instance, fleet, and Bridge.

**Connected to:** Agent Instance ID, Bridge provider status, model catalogs, fleet launch
settings, and provider extensions.

---

### Task recheck

The task engine re-evaluates eligible work as relevant events occur: dependencies, reviews,
lease releases/expiry, fleet changes, and Bridge lifecycle updates. To investigate a stuck task,
use `ham-ctl task recheck <task-id>`. It recomputes gate/readiness/dispatch and merge recovery
without approving work or disturbing a live lease.

Use `ham-ctl task-chain graph` for dependencies and the current work revision. Complete a
finished chain explicitly:

```bash
ham-ctl task-chain complete <chain-id> --expected-work-revision <n> --summary "Final evidence."
```

The old manual chain-reconcile/status workflow is not the current CLI.

**Connected to:** Task, lease, reviews, fleet capacity, dependency graph, and merge outcome.

---

## Install a bridge

Connect a Linux or macOS machine to your Hub with one command, headless (replace the
URL for a self-hosted Hub):

```bash
curl -fsSL install.ninjy.ai | bash -s -- --hub https://hub.mundus.in
```

`curl -fsSL install.ninjy.ai | bash` serves [`scripts/install.sh`](scripts/install.sh), a
thin bootstrap: it resolves the newest promoted release (or `--version TAG`), downloads
this machine's bundle, verifies it against the release's `SHA256SUMS`, and runs
`ham-bridge setup --headless` with every other flag passed through (`--profile NAME`,
`--new-bridge`, `--reuse-bridge ID`, `--json-progress`). `ham-bridge` does the rest:
installs the binaries and provider extensions, registers the user service, prints the
browser approval link and waits for it, starts the bridge and rolls back on failure.
The binaries link their HTTPS and WSS client (libcurl, pinned in `nix/libcurl-pin.json`)
statically, and the Linux ones are fully static, so they run on any distribution.

On Windows 10/11 (x64), from a normal (non-admin) PowerShell:

```powershell
& ([scriptblock]::Create((irm install.ninjy.ai/ps1))) -Hub https://hub.mundus.in
# or, with the options in the environment:
$env:HEIMDALL_HUB = 'https://hub.mundus.in'; irm install.ninjy.ai/ps1 | iex
```

[`scripts/install.ps1`](scripts/install.ps1) does the same on Windows; the bridge runs as
a per-user Scheduled Task. Both scripts are self-contained and also attached to every
release.

Afterwards everything goes through `ham-bridge`:

```bash
ham-bridge status --json                 # installed bridges and their state
ham-bridge update --version latest       # or --version vX.Y.Z; SHA-256 verified, rolls back on failure
ham-bridge uninstall --hub https://hub.mundus.in [--purge]
```

Updates started from the Hub (Settings → Bridges → Update) run the same
`ham-bridge update` from the new release.

> **Upgrading a bridge installed before the single `ham-bridge` flow:** release bundles
> no longer ship `scripts/apply-bridge-update.sh`/`.ps1`, so a bridge installed by an
> older release cannot be updated from the Hub to this release. Reinstall it once with
> the command above (`curl -fsSL install.ninjy.ai | bash -s -- --hub <url>`, or
> `irm install.ninjy.ai/ps1 | iex` on Windows); later updates work from the Hub again.
> See [SELF_HOSTING.md §2.11](SELF_HOSTING.md#211-bridge-self-update).

See [`SELF_HOSTING.md`](SELF_HOSTING.md#21-install-a-bridge) for details and troubleshooting.
