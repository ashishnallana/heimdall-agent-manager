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

- **Multi-agent by design.** A Coordinator breaks the work into a task chain and delegates
  each task to a Worker agent. A separate Reviewer then votes LGTM or NGTM, and a task only
  completes once every required reviewer has approved it.
- **Persistent, scoped memory.** Facts, habits, episodes, and skills are stored durably and
  injected into each agent at bootstrap. Knowledge is scoped to an agent, a project, a
  device, or the whole fleet, so it survives across sessions and is shared where it belongs.
- **Fresh context every task.** Agents restart after each task. No single conversation ever
  grows long enough to degrade, and every task starts from a clean, focused window.
- **Structured audit trail.** Progress is captured as structured task comments and status
  changes — the real record of what happened, not an after-the-fact AI summary you have to
  trust.
- **Provider-agnostic.** Each agent is a thin adapter over whatever LLM you choose. Heimdall
  does not care which provider backs an agent, so you can mix and match freely.
- **Cross-device fleet.** Agents run on any device you own and are coordinated through a
  single hub, so your laptop, workstation, and servers all pull work from the same board.

## Architecture

Heimdall is a hub-and-bridge system. A central hub owns all shared state; one bridge per
device spawns and supervises the agent processes that do the work. Agents and humans both
drive the system through a CLI, and a desktop and web UI render the whole thing live.

- **Hub (Odin).** The central REST and WebSocket server. It manages agents, task chains,
  memories, and projects, and is the single source of truth for all shared state.
- **Bridge (Odin).** Runs on each device. It spawns and manages the Claude Code agent
  processes, executes shell commands on their behalf, and handles filesystem exploration so
  agents can read and search a project safely.
- **ham-ctl.** The command-line interface used by agents and humans alike to create and
  update tasks, read and send messages, propose memories, and run tracked shell commands.
- **UI (React / TypeScript / Electron + web).** The dashboard. It provides a task board, a
  conversation view, memory management, shell-job tracking, and a fleet view of every
  running agent across every device.

## How work flows

A typical run looks like this:

1. You describe what you want to the Coordinator through the UI or `ham-ctl`.
2. The Coordinator plans a task chain and assigns each task to a Worker, with a Reviewer
   attached.
3. A Worker picks up its task in a fresh agent session, does the work, records progress as
   task comments, and hands off for review.
4. The Reviewer inspects the change and votes. On LGTM the task completes; on NGTM it goes
   back to the Worker with feedback.
5. When the chain finishes, its memories are proposed for approval and carried forward to
   future work.

Everything above is visible and steerable in real time from the dashboard, and every step
leaves a durable record.

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

### One coordinator, many short-lived workers

Work starts when you create a Project (a name + the path to your codebase) and launch
a Coordinator agent. The Coordinator is the only persistent agent — it holds the plan,
owns the task chain, and is the person you talk to. Every other agent lives only for
the duration of a single task.

When the Coordinator assigns a task, Heimdall spawns a fresh Worker and a fresh
Reviewer. The Worker runs in a clean context — no leftover conversation history, no
accumulated confusion — and loads only the memories that are relevant to its task. When
the task completes (Reviewer votes LGTM), both the Worker and Reviewer are stopped.
If the chain needs them again for another task, new instances are started. This keeps
each agent's context window small and its reasoning sharp.

### Agents learn through memory proposals

An agent cannot update its own permanent knowledge. Instead, when it discovers something
worth keeping — a project convention, a build quirk, a decision rationale — it *proposes*
a memory. Proposals sit in a queue until you review them on the Memory page in the UI.
You approve the ones that are accurate and discard the rest. Only approved memories are
injected into future agents.

This makes learning intentional. Agents accumulate knowledge at the speed you trust them,
not at the speed they generate text.

### You steer from the task board

You do not need to watch every agent session. The normal working pattern is:

1. Describe the goal to the Coordinator in the conversation panel.
2. The Coordinator plans the chain and starts workers autonomously.
3. You check in on the task board to see progress, read task comments, and spot
   anything that looks off.
4. If a task is going the wrong direction, post a comment on it — the Worker reads task
   comments and adjusts. If the whole plan needs rethinking, tell the Coordinator.
5. When a task finishes, glance at the Reviewer's verdict and the evidence comment
   before it closes.

Everything is asynchronous. You do not have to be present for each step; agents keep
working and the board reflects real progress.

### The ideal first session

```
1. Add a project in the UI (name + local path on the bridge device).
2. Start a Coordinator agent for that project.
3. Send the Coordinator a message describing what you want to build or fix.
4. Watch the task chain appear. The Coordinator will ask clarifying questions if
   anything is ambiguous before delegating.
5. Let workers run. Check back on the board when convenient.
6. Review memory proposals on the Memory page after the chain completes.
7. Repeat — the next chain starts with accumulated project knowledge already loaded.
```

---

## Key concepts

The entities below are the building blocks of Heimdall. Understanding what each one is
and how it connects to the others makes the rest of the system easy to reason about.

---

### Agent ID

A stable identifier for a *type* of agent — a named role such as `coordinator`,
`worker`, or `reviewer`. The Agent ID is not tied to a specific running process. It is
used when configuring which LLM provider backs a role, which skill set it loads at
bootstrap, and which memories are scoped to it.

**Connected to:** Agent Instance ID (each running instance carries an Agent ID),
Memory (some memory is scoped per-agent by Agent ID), Task Chain (coordinator and
worker roles are identified by Agent ID).

---

### Agent Instance ID

The unique identifier for one *running* agent process. Every time an agent is spawned
for a task it receives a fresh Instance ID. The Instance ID is used to route chat
messages to that specific process, track its status in the fleet view, and identify
which bridge it is running on.

**Connected to:** Agent ID (each instance is one running copy of an agent role),
Bridge (an instance always lives on exactly one bridge), Task Chain (a task is assigned
to an instance by its Instance ID), Agent Run Dir (each instance has its own run
directory on the bridge).

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

Durable knowledge that persists across agent sessions. Memory is injected into an agent
at bootstrap so it starts each task already aware of facts, conventions, and past
decisions. There are four types:

| Type | What it stores | Example |
|------|---------------|---------|
| **Fact** | Objective, stable truths about the project or environment | "The hub API runs on port 8081" |
| **Habit** | Preferred working patterns or conventions | "Always run `npm run typecheck` before committing" |
| **Episode** | Records of past events, decisions, or incidents | "The migration on 2025-03-15 required a manual SQL fix" |
| **Skill** | Reusable procedures or mini-runbooks | "How to add a new icon to Icon.tsx" |

Each memory is scoped to one of: `agent_id` (personal to one agent role), `project_id`
(shared by all agents on a project), `bridge_id` (host-level facts about a device), or
fleet-wide.

**Connected to:** Agent ID (agent-scoped memories), Project (project-scoped memories),
Bridge (bridge-scoped memories), Task Chain (chains produce memories at completion that
are proposed for approval and carried forward).

---

### Task Chain

A structured unit of work made up of ordered tasks. A Coordinator creates the chain,
assigns each task to a Worker, and attaches a Reviewer. A task only completes once the
required reviewer quorum has voted LGTM; the chain completes when all its tasks are
done. Task chains are the primary audit trail — every status change, comment, and vote
is recorded durably.

**Connected to:** Agent ID / Agent Instance ID (coordinator, worker, and reviewer
instances are attached to the chain), Project (a chain targets a project), Memory
(chains produce memory proposals on completion), Reconcile (the Reconcile operation
re-evaluates a chain's task assignment and status).

---

### Agent Run Dir

A temporary working directory created on the bridge for each agent instance. It holds
the instance's runtime state: the `ham-ctl` binary, environment config, the
`.heimdall/` bootstrap folder, and any scratch files the agent writes during its
session. The run dir is cleaned up when the instance exits.

**Connected to:** Agent Instance ID (one run dir per instance), Bridge (the run dir is
a filesystem path on the bridge host), `ham-ctl` (the agent CLI binary is placed in
the run dir so the agent always has a consistent path to it).

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
Dir (run dirs are created on the bridge filesystem), Provider (the bridge passes
provider credentials to agent processes at spawn time), Hub (bridge→hub connection is
outbound over HTTPS using `socat` as the TLS transport).

---

### Provider

The LLM backend that backs an agent. A provider record stores which API (Claude,
OpenAI Codex, etc.) and model to use, along with the credentials needed to call it.
Providers are configured on the hub and referenced by Agent ID, so swapping a model
requires changing one record rather than touching every agent.

**Connected to:** Agent ID (each agent role is configured with a provider), Bridge (the
bridge injects provider credentials into the agent environment at spawn time), Agent
Instance ID (a running instance uses whichever provider its Agent ID was configured
with at spawn time).

---

### Reconcile (task chain)

Reconcile is the operation that re-evaluates a task chain's current state and
re-assigns any tasks that need attention — for example tasks that have no assigned
instance, tasks whose assigned instance has died, or tasks that were blocked by a
dependency that has since completed. Running Reconcile from the UI or via `ham-ctl
task chain reconcile <chain-id>` is the normal way to un-stick a chain after a
coordinator restart or a bridge reconnect.

**Connected to:** Task Chain (reconcile targets one chain), Agent Instance ID
(reconcile spawns new instances or re-assigns existing ones), Bridge (new instances
are launched on an available bridge).

---

## Install a bridge

Connect a Linux or macOS machine to your Hub with one command (replace the URL for a self-hosted Hub):

```bash
curl -fsSL https://raw.githubusercontent.com/tanmayv/heimdall-agent-manager/main/scripts/install.sh | bash -s -- --hub https://hub.mundus.in
```

The installer downloads and verifies the binaries, registers the system service,
opens browser-based enrollment when needed, saves the approved credential, and starts
the bridge. Install `socat` first (`apt install socat` or `brew install socat`). See
[`SELF_HOSTING.md`](SELF_HOSTING.md) for deployment, headless, and troubleshooting details.

On Windows 10/11 (x64), from a normal (non-admin) PowerShell:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/tanmayv/heimdall-agent-manager/main/scripts/install.ps1))) -Hub https://hub.mundus.in
```

It installs the bridge as a per-user Scheduled Task (no window, starts at logon) and
needs no `socat`; see [Windows quick install](SELF_HOSTING.md#211-windows-quick-install).
