---
name: ham-ctl-reference
description: Authoritative command reference for the ham-ctl agent CLI — every group (bridge, agents, task-chain, task, issue, chat, memory, artifact, shell, context, start-success) with exact verbs, flags, and valid values. Also covers shell sessions as a way to put a running process in front of the user — they can watch its stdout live and, if it serves HTTP on a declared port, open its UI as a preview in Heimdall — no inbound port on either machine, and it works when the Hub is on a different host. Includes how two services in separate sessions call each other through the Hub. Load whenever you need the precise ham-ctl syntax for a Heimdall action and want to get flags, positional ids, task/chain statuses, vote results, or memory scopes right the first time.
---

# ham-ctl command reference

`ham-ctl` is the agent control CLI for Heimdall. Every command is callable with your
agent token (already configured) via the managed wrapper in your run directory:

```
./.heimdall/bin/ham-ctl <group> <verb> [<positional-id>] [--flags]
```

Conventions used below:
- `<id>` positional args come right after the verb; most commands need only the
  positional id (task/chain ids are globally unique, so `--chain` is usually optional).
- Each command prints a single JSON response line.
- Run `./.heimdall/bin/ham-ctl <group> --help` for the built-in reference of any group;
  `./.heimdall/bin/ham-ctl --help` lists all groups.

Groups: `bridge`, `agents`, `task-chain`, `task`, `workflow`, `lease`, `verify`, `review`, `issue`, `chat`, `memory`, `artifact`,
`shell`, `context`, `start-success`.

---

## bridge — discover bridges and their providers
- `bridge list [--scope hub|configured|all]` — bridges you can target. Default `all` =
  Hub-registered + locally-configured peers + this host (self).
- `bridge providers [--bridge <id>]` — providers (and tiers) for one bridge, or all.

## agents — durable identities, templates, and runtime instances
- `agents list` — your durable agent identities.
- `agents identity create --name <n> [--template <id>] [--provider <p>] [--slug <s>] [--instructions <t>]` — create a durable agent.
- `agents template list` — list agent templates (personas).
- `agents template create --name <n> [--description <d>] [--persona <t>] [--instructions <t>]` — create a template.
- `agents instance list [--agent <id>] [--live]` — list instances (durable, or only live with `--live`).
- `agents new-instance <agent-id> [--project <id>] [--bridge <id>] [--provider <p>] [--chain <id>]` — launch a NEW instance of a durable agent.
- `agents start <instance-id>` — start a STOPPED instance (errors if already running).
- `agents stop <instance-id> [--reason <t>]` — stop a running instance.
- `agents restart <instance-id>` — restart (stop-then-start) an instance.

## task-chain — your task chains
- `task-chain list [--mine] [--project <id>]` — chains (`--mine` = ones you coordinate).
- `task-chain show [<chain-id>]` — show a chain (defaults to your current chain), including embedded `tasks` and `directories`.
- `task-chain create --title <title> [--description <desc>] [--kind <kind>] [--coordinator <agt_id>] [--bridge <brg_id>] [--project <proj_id>] [--provider <p>]` — create a task chain. If `--coordinator` is provided, provisions or assigns the coordinator agent instance.
- `task-chain set-title <title> [--chain <id>]` — rename a chain (coordinator only).
- `task-chain set-description <text> [--chain <id>]` (or `--stdin`) — set the chain
  description (coordinator only; pass `""` to clear; `--chain` defaults to your chain).
- `task-chain summary set <text> [--chain <id>]` (or `--stdin`) — set the curated chain summary
  (`<= 60` lines; coordinator only; surfaced in every agent's `TASK.md` context pack).
- `task-chain propose --file <proposal.json> [--auto-approve] [--chain <id>]` — create a chain
  proposal (`kind: "task"|"workflow_run"`, `rationale`, `alternative`, `tasks` array or `workflow` + `inputs`) and its draft
  tasks in a single transaction (coordinator only). With `--auto-approve`, validates briefs and
  publishes (or runs the proposed workflow) immediately.
- `task-chain decide <chain-id> --decision approve|reject [--reason <text>]` — approve or reject
  a pending chain proposal (publishes all tasks or starts the proposed workflow atomically on `approve`).
- `task-chain publish <chain-id>` — validate all task briefs and publish the chain (`422 brief_incomplete` lists missing fields per task, including `review_role:<r>` when no fleet row holds a requested role). `decide` and `publish` need the chain id (positional or `--chain`).
- `task-chain set-status --status <active|cancelled|archived> [--chain <id>]` — change
  the chain status (coordinator only). Completion uses `task-chain complete` with a work revision and final summary.
- `task-chain archive [<chain-id>]` / `unarchive [<chain-id>]` — archive or restore a chain (coordinator only).
- `task-chain pin <chain-id>` / `unpin <chain-id>` — pin a chain to the top of the sidebar.

### Relevant directories (`task-chain directory`)
Associate one or more working directories (local checkouts, CitC workspaces, repos) with a task chain so participating agents and the UI know which workspaces/directories are in scope. Directories are also embedded directly in `task-chain show [<chain-id>]` and `GET /api/v1/task-chains/:id` output under the `"directories"` array.

- `task-chain directory list [--chain <id>]` — list relevant directories for a task chain (`--chain` defaults to your current chain).
- `task-chain directory add --path <path> [--bridge <bridge_id>] [--vcs-kind <kind>] [--chain <id>]` — associate a directory with the chain.
- `task-chain directory update <directory-id> [--path <path>] [--bridge <bridge_id>] [--vcs-kind <kind>] [--chain <id>]` — update an existing directory entry.
- `task-chain directory remove <directory-id> [--chain <id>]` — disassociate a directory from the chain.

#### Directory JSON shape (lean payload)
Directory objects use a lean payload shape containing only operational fields. To keep coordination lightweight, metadata like timestamps (`created_at`, `updated_at`) and authorship/owner fields are intentionally omitted:

```json
{
  "directory_id": "dir_18d7a123bc45de67",
  "path": "/usr/local/google/home/tanmayvijay/heimdall-cloudtop",
  "bridge_id": "brg_18d03379a7d6d47b",
  "vcs_kind": "git",
  "vcs": {}
}
```

Fields:
- `directory_id`: Unique identifier for the directory record (`dir_...`).
- `path`: Target directory path on the bridge host.
- `bridge_id`: Identifier of the bridge where the directory resides.
- `vcs_kind`: Version control system kind (`git`, `citc`, `jj`, or empty).
- `vcs`: Object containing VCS-specific details (branch, commit, status, etc.).

#### Command examples
```bash
# List directories for the current chain
ham-ctl task-chain directory list

# List directories for a specific chain
ham-ctl task-chain directory list --chain chain_18d711c5384a0119

# Add a directory to the chain
ham-ctl task-chain directory add --path /usr/local/google/home/tanmayvijay/heimdall-cloudtop --bridge brg_18d03379a7d6d47b --vcs-kind git

# Add a directory to a specific chain
ham-ctl task-chain directory add --chain chain_18d711c5384a0119 --path /google/src/cloud/tanmayvijay/heimdall --vcs-kind citc

# Update an existing directory's path or bridge
ham-ctl task-chain directory update dir_18d7a123bc45de67 --path /usr/local/google/home/tanmayvijay/heimdall-cloudtop-v2

# Remove a directory from the chain
ham-ctl task-chain directory remove dir_18d7a123bc45de67

# View chain details with embedded directories
ham-ctl task-chain show chain_18d711c5384a0119
```

### Fleet management (`task-chain fleet`)
Configure and inspect agent concurrency caps and placement (fleets) for a task chain. Fleets allow tasks to be assigned to durable agent types (`agt_...`) instead of individual instances (`inst_...`). Heimdall dynamically routes or provisions worker and reviewer instances to satisfy fleet capacity and placement rules.

- `task-chain fleet list [<chain-id>]` — list fleet capacities, placement (`roles`, `bridge_id`, `provider`, `model`, `bridge_models`), and live active worker counts for a chain (defaults to current chain if omitted).
- `task-chain fleet set <chain-id> --agent <agent_id> --capacity <N> [--min-warm <M>] [--idle-ttl <seconds>] [--roles worker,reviewer] [--bridge <bridge_id>] [--provider <p>] [--model <m>] [--bridge-models <json>] [--bridge-models-file <path>]` — configure fleet capacity and placement for an agent class on the chain.

#### Fleet JSON shape
`task-chain fleet list` returns a JSON array of fleet configurations:
```json
[
  {
    "chain_id": "chain_18d711c5384a0119",
    "agent_id": "agt_worker",
    "capacity": 3,
    "active_count": 1,
    "min_warm": 0,
    "idle_ttl_seconds": 300,
    "roles": ["worker", "reviewer"],
    "bridge_id": "brg_main",
    "provider": "claude",
    "model": "claude-opus-4-6",
    "bridge_models": {},
    "created_at": "2026-09-24T00:00:00Z",
    "updated_at": "2026-09-24T00:00:00Z"
  }
]
```

Fields:
- `chain_id`: Unique identifier of the task chain (`chain_...`).
- `agent_id`: Durable agent template identifier (`agt_...`).
- `capacity`: Maximum concurrent running worker instances allocated for this agent on the chain.
- `active_count`: Currently active (running or busy) worker instances assigned to tasks in this chain.
- `min_warm`: Minimum warm standby instances to maintain.
- `idle_ttl_seconds`: Time before idle instances are stopped or decommissioned.
- `roles`: Allowed lease roles for this fleet row (`["worker"]`, `["reviewer"]`, or `["worker", "reviewer"]`).
- `bridge_id`, `provider`, `model`, `bridge_models`: Optional placement and model overrides.

#### Command examples
```bash
# List fleets for the current chain
ham-ctl task-chain fleet list

# Set worker fleet capacity and placement
ham-ctl task-chain fleet set chain_18d711c5384a0119 --agent agt_worker --capacity 4 --roles worker --bridge brg_main

# Set reviewer fleet capacity with warm standby and idle timeout
ham-ctl task-chain fleet set chain_18d711c5384a0119 --agent agt_reviewer --capacity 2 --min-warm 1 --idle-ttl 600 --roles reviewer
```

## task, lease, verify, review — Task System v2
A positional `<task-id>` identifies the task and is enough on its own (task ids are
globally unique — you rarely need `--chain`).

- `task list [--chain <id>]` — your chain's tasks. Each carries a `comment_summary`
  (count, last_comment_at, author, preview) — NOT full comment bodies.
- `task show <task-id> [--chain <id>]` — a task + its `brief` + `comment_summary` + facets.
- `task comments <task-id> [--last N]` — fetch comment BODIES; `--last N` = newest N (max 100).
- `task create --title <t> [--description <d>] [--priority p0|p1|p2] [--assignee <agt_id>] [--reviewer <agt_id,agt_id,...>] [--depends-on <id,id>] [--bridge <bridge-id>] [--chain <id>] [--goal <g>] [--acceptance <a>]... [--verify <cmd>] [--input <ref>]... [--review-role <r>]... [--output-schema <task_list.v1|findings.v1>] [--on-output-workflow <name>] [--auto-submit] [--require-independent-verify] [--require-user-approval] [--brief-file <path.json>]` — create a task.
  `--assignee` and `--reviewer` take durable agent IDs (`agt_...`) only.
- `task update <task-id> [--title <t>] [--description <d>] [--priority p0|p1|p2] [--assignee <agt_id>] [--reviewer <agt_id,agt_id,...>] [--depends-on <id,id>] [--bridge <bridge-id>] [--goal <g>] [--acceptance <a>]... [--verify <cmd>] [--input <ref>]... [--review-role <r>]... [--output-schema <task_list.v1|findings.v1>] [--on-output-workflow <name>] [--auto-submit] [--require-independent-verify] [--require-user-approval | --no-require-user-approval] [--brief-file <path.json>]` — edit an existing task.
- `task publish <task-id>` — validate the task's brief and publish it (`422 brief_incomplete` lists any missing fields).
- `task comment <task-id> --body <t>` (or `--stdin`) `[--notify <id,id>]` — add a comment.
- `task depend <task-id> --on <task-id>|task:<task-id>|workflow_run:<run-id> [--chain <id>]` — add one prerequisite to a ticket. A `workflow_run:` prerequisite becomes a chain-level graph edge on the whole run (the ticket stays ineligible until that run succeeds). Other typed refs (stage keys, `workflow:` names, issues) are rejected with guidance; use `task-chain depend` for run-on-ticket or run-on-run edges. `--depends-on` on `task create`/`task update` takes ticket ids only (`task:<id>` accepted) and `update --depends-on` replaces the whole list.
- `task fetch <task-id> <ref>` — fetch one event (`#<event_id>`), output (`output:<task_id>`), facet (`facet:<task_id>:<attempt_no>:<kind>`), or file-at-commit (`dir:<dir_id>:<rev>:<path>`, `<path>@<rev>`, or `<path>`) referenced by `TASK.md`.
- `lease next` — inspect the lease you hold (status `current`) or claim the next ready task inline (status `granted`), updating `<run_dir>/TASK.md`; returns `none` when idle.
- `lease heartbeat [--note <text>]` — extend the lease TTL and optionally record a progress note. On `409 lease_lost`, stop immediately without touching the working tree.
- `lease submit --summary <s> [handoff flags] [--output-file <json>] [--artifacts-file <json>] [--artifacts <json>] [--verify none] [--lease <id>]` — finish the attempt (task → `in_review`, or `done` with no review gates). Requires a passing `ham-ctl verify` at the current head when `brief.verify` configures a command (omitted, blank, or `"none"` skips verification) (`409 verify_required|verify_failed|verify_stale|verify_dirty`). Validates `output` against the brief's output contract (`task_list.v1`, `findings.v1`).
- `lease handoff --summary <s> [handoff flags] [--lease <id>]` — stop without finishing; the task returns to `ready` and the next holder gets your handoff.
- `lease switch <task_id> --summary <s> [handoff flags]` — solo mode: hand off the current task (attempt not counted) and take `<task_id>` (must be `ready`) in one step.
- **Handoff flags** (submit, handoff, switch): `--decision <text>` and `--dead-end <text>` (repeat per item), `--next-steps <text>`; or `--handoff-file <json>` (`{"decisions":[…],"dead_ends":[…],"next_steps":"…"}`) instead, not both. Decisions and dead ends reach every task that waits for this one and the next attempt; dead ends also go into the chain summary for all tasks.
- `lease block --waiting-on <kind> --reason <text> [--ref <id>] [--summary <s>]` — park the task in `backlog` on a blocker. `<kind>` is free text: `user` (the user must answer; the answer appears in `TASK.md`), `task`, or an external system.
- `verify [<task-id>] [--independent] [--bridge <id>]` — run `brief.verify` as a Run session labelled for this attempt (`verify <task_id> #<attempt_no> @<head> [independent]`), heartbeating while it runs. With `--independent`, runs inside an ephemeral detached git worktree at `vcs.head` and records `"independent": true` on the `verify` facet. When `brief.auto_submit` is `true` and a normal `verify` exits `0` on a clean working tree, automatically submits the lease (`auto: true`).
- `review post [<task-id>] --verdict approve|request_changes [--summary <reason>] [--findings-file <json>] [--task <id>] [--on-behalf-of user]` — record a review verdict. Findings: `[{"path","line","severity","text"}]`. `request_changes` needs `--summary` or findings. Response: `gate: waiting|approved|changes_requested`. Coordinators pass `--on-behalf-of user` to record the user's verdict on tasks that require user approval (or gates whose approver is `user`); refused in solo mode for your own work.

### Task states
A task carries a `state`: `backlog`, `ready`, `in_progress`, `in_review`, `done`, `cancelled`.
State is driven by the hub (leases, reviews, dependencies); agents do not set it directly.
The v1 verbs `task status`, `task vote`, `task nudge` and `task set-current` no longer exist.

### Mixed work
All chains have `kind: mixed_work`. Choose tickets or workflow runs per item while
keeping the same chain, coordinator, team, and directories. See coordinator-task-management.

## workflow — runs inside a mixed-work task chain
- `workflow templates` lists built-ins and owner definitions; `workflow define --file <definition.json>` saves a version.
- `workflow run <ref> --chain <id> --request-id <stable-key> [--title <text>] [--input k=v ...] [--inputs-file <json>] [--after task:<id>|workflow_run:<id> ...]` snapshots a recipe into that chain. Reuse the request key on network retries.
- `workflow list --chain <id>` lists runs and the chain work revision.
- `workflow status <run-id> [--execution <n>]` inspects a current or historical execution.
- `workflow output <run-id> <stage-key> [--execution <n>]` reads outputs.
- `workflow history <run-id>` reads executions and lifecycle events.
- `workflow retry <run-id> --expected-revision <n> --reason <text>` creates fresh execution/tasks for a terminal run. Consumed outputs block retry. Stage/cascade retry is unsupported.
- `workflow cancel <run-id> --execution <number> [--reason <text>]` cancels only that run.
- Agents may omit `--chain` on create/list to use their own chain; run IDs are explicit.
- Configure the chain fleet before starting; recipes never create fleet rows.

### Authoring workflow definitions (fan-out)
- A stage may set `for_each` to fan out one task per array item. Two sources are supported:
  - Stage output: `"<stage>.outputs[0].<field>"` (also `<stage>.output.<field>`, `stage.<stage>.output.<field>`, or `<stage>.outputs[].<field>` to concatenate every instance's array). The stage must be in `depends_on` and declare an output contract.
  - Workflow input: `"inputs.<name>"` (alias `workflow.input.<name>`), a top-level input that is a JSON array. No echo stage is needed. If the definition declares `inputs`, the name must be declared with `"type": "array"` (or `list`, `array<...>`, `T[]`); an array `default` is allowed. Nested paths (`inputs.a.b`) are rejected at `workflow define`.
- Supply array inputs with `--inputs-file <json>` (for example `{"subtopics":[{"key":"auth","title":"Auth"},"billing"]}`); `--input k=v` always passes a string.
- A missing or `null` input uses the declared array `default`; otherwise `workflow run` rejects it, and also rejects a non-array value or more than 256 items, before anything is created, so a bad input never dispatches part of a run. The value is resolved from the run's immutable input snapshot; `workflow retry` re-expands from that same snapshot.
- Items expand in array order: item *i* becomes `stage_index` *i*, and re-reconciliation never duplicates a task.
- An empty array is valid: the stage completes with zero tasks and its downstream stages start as usual.
- At most 256 items per fan-out stage (input or stage output). A stage output over the limit fails the run at expansion (`workflow_fan_out_too_large`) without creating that stage's tasks.
- Placeholders per item: `{{item.<field>}}` for object items (`{{item.key}}` falls back to `id`, then `item_<index>`; an item `priority` overrides the stage priority), `{{item}}` for the whole item (a string item renders unquoted, a number as written, an object as JSON), plus `{{stage.index}}` and `{{stage.count}}`. Scalar items have no fields: `{{item.<field>}}` is empty (except `{{item.key}}`, which is `item_<index>`) and item `priority` does not apply. `{{inputs.<name>}}` for an array input renders the JSON array (or its declared default).

### Mixed-work graph, scope, and completion
Same verbs and flags in agent mode and user mode. The chain is positional (`task-chain graph <chain-id>`) or `--chain <id>`; `graph`, `depend`, `remove-dependency` and `scope` default to your own chain, `complete` always needs an explicit chain id. Mutations require the chain owner or its coordinator; other agents get `403 Forbidden`.
- `task-chain graph [<chain-id>]` reads dependency (with dependency ids) and scope history plus `work_revision`.
- `task-chain depend [<chain-id>] --item task:<id>|workflow_run:<id> --on task:<id>|workflow_run:<id>` adds an acyclic prerequisite before the consumer starts (idempotent).
- `task-chain remove-dependency [<chain-id>] --dependency <id> --reason <text>` explicitly removes an edge without erasing provenance or consumption receipts.
- `task-chain scope [<chain-id>] --item task:<id>|workflow_run:<id> --action include|exclude --reason <text>` records a scope decision. Exclusion requires terminal work and does not unblock dependents.
- `task-chain complete <chain-id> --expected-work-revision <n> --summary <text>` explicitly accepts the final result. Every included item must succeed, with no leases or pending proposal. Read a fresh graph revision first (a stale one is a `work_changed` conflict). Finishing a batch never closes the chain automatically.
- Generated stage tasks cannot be manually created, edited, reopened, or cancelled; use run controls. Historical executions remain readable.

## issue — track, discuss, and vote on issues and blockers
Manage defects, toolchain quirks, environment problems, and out-of-scope bugs across
the system. Supports lean list views, detail inspect with threaded comments, voting
with single-vote enforcement per instance/user, and unvoting.

A positional `<issue-id>` identifies the issue right after the verb.

- `issue list [--status <new|fixed|obsolete>] [--scope <global|project|agent_id|bridge_id>] [--target-id <id>] [--chain <id>] [--query <text>] [--voter-id <id>] [--limit <limit>] [--offset <offset>]` — list issues. Returns a **lean payload** containing `description_preview`, `comment_count`, `vote_count`, and `has_voted` (when voter ID is supplied), omitting the full description and comments array.
- `issue show <issue-id> [--voter-id <id>]` — show full issue details, including the full `description`, metadata, `closed_at`, `vote_count`, `comment_count`, `has_voted` (for the specified or caller identity), and embedded `comments` array.
- `issue create --title <title> [--description <desc>] [--scope <global|project|agent_id|bridge_id>] [--target-id <id>] [--chain <id>] [--created-by <id>]` — create a new issue with status `new`.
- `issue update <issue-id> [--title <title>] [--description <desc>] [--status <new|fixed|obsolete>] [--scope <scope>] [--target-id <id>] [--chain <id>]` — update an issue. Setting status to `fixed` or `obsolete` automatically populates the `closed_at` timestamp; setting back to `new` clears `closed_at`.
- `issue comment <issue-id> --body <body> [--stdin] [--author-id <id>] [--author-name <name>]` — add a comment to an issue.
- `issue comment <issue-id> list` (or `issue comments <issue-id>`) — list comments for an issue.
- `issue vote <issue-id> [--voter-id <id>] [--voter-name <name>]` — cast an upvote on an issue. Each user or agent instance can vote only once; duplicate votes are rejected with HTTP 409 Conflict. Increments `vote_count` and sets `has_voted: true`.
- `issue unvote <issue-id> [--voter-id <id>]` — retract a previously cast vote. Decrements `vote_count` and sets `has_voted: false`. Returns 404 if no vote exists for the voter.
- `issue delete <issue-id>` (or `issue remove <issue-id>`) — permanently delete an issue, including its comments and votes.

### Issue statuses and scopes
- **Statuses**:
  - `new` — open issue (default upon creation).
  - `fixed` — resolved issue (sets `closed_at`).
  - `obsolete` — discarded / no longer relevant (sets `closed_at`).
- **Scopes** (`--scope` / `--scope-type`):
  - `global` — system-wide or cross-project defects (default).
  - `project` — project-specific defects (`--target-id` specifies project ID).
  - `agent_id` (alias `agent`) — agent template or runtime instance issues (`--target-id` specifies agent ID).
  - `bridge_id` (alias `bridge`) — host/bridge-specific issues (`--target-id` specifies bridge ID).

### Issue JSON shapes

#### Lean list shape (`issue list`)
```json
{
  "issue_id": "iss_18d7a123bc45de67",
  "title": "Compiler segfault on empty generic struct",
  "description_preview": "Reproduces when compiling with -vet-unused...",
  "status": "new",
  "scope_type": "project",
  "target_id": "proj_18c6879e443756f1",
  "chain_id": "chain_18d711c5384a0119",
  "created_by": "inst_18d78eed201a0bcf",
  "created_at": "2026-09-22T14:00:00Z",
  "updated_at": "2026-09-22T14:05:00Z",
  "closed_at": "",
  "vote_count": 3,
  "comment_count": 2,
  "has_voted": false
}
```

#### Detail shape (`issue show`, `issue create`, `issue update`)
```json
{
  "issue_id": "iss_18d7a123bc45de67",
  "title": "Compiler segfault on empty generic struct",
  "description": "Full reproduction logs and stack trace...",
  "status": "new",
  "scope_type": "project",
  "target_id": "proj_18c6879e443756f1",
  "chain_id": "chain_18d711c5384a0119",
  "created_by": "inst_18d78eed201a0bcf",
  "created_at": "2026-09-22T14:00:00Z",
  "updated_at": "2026-09-22T14:05:00Z",
  "closed_at": "",
  "vote_count": 3,
  "comment_count": 2,
  "has_voted": true,
  "comments": [
    {
      "comment_id": "icmt_18d7a9876543210f",
      "issue_id": "iss_18d7a123bc45de67",
      "author_id": "inst_18d78eed201a0bcf",
      "author_name": "worker #42",
      "body": "Confirmed also on NixOS 24.05 with odin-nightly.",
      "created_at": "2026-09-22T14:02:00Z",
      "updated_at": "2026-09-22T14:02:00Z"
    }
  ]
}
```

### Command examples
```bash
# Search for existing issues to avoid filing duplicates
ham-ctl issue list --query "compiler segfault"

# Vote on an existing issue
ham-ctl issue vote iss_18d7a123bc45de67

# Retract a vote
ham-ctl issue unvote iss_18d7a123bc45de67

# Create a new issue scoped to a project
ham-ctl issue create --title "Broken libsqlite3 dependency" \
  --description "Fails to link on Ubuntu 22.04 with missing symbol sqlite3_column_table_name" \
  --scope project --target-id proj_18c6879e443756f1

# View issue details including threaded comments
ham-ctl issue show iss_18d7a123bc45de67

# Add a diagnostic comment to an issue
ham-ctl issue comment iss_18d7a123bc45de67 --body "Workaround: export CGO_CFLAGS=-DSQLITE_ENABLE_COLUMN_METADATA"

# Resolve an issue
ham-ctl issue update iss_18d7a123bc45de67 --status fixed
```

## chat — inbox and sending
- `chat read [--limit N] [--since T] [--include-read] [--transcript]` — read messages.
- `chat send --to <user|agent-instance-id> --body <t>` (or `--stdin`) — send a message.
  `--to` is REQUIRED: `user` for the bound user, or an exact agent-instance-id for
  agent-to-agent.
- `chat set-title <title>` — DEPRECATED: conversation titles are no longer used. Do not
  call it; name your work with `task-chain set-title` (coordinator only) instead.

## shell — run commands and long-lived sessions on the Bridge host
THE THREE KINDS, enforced by the hub:
- `run` — a one-shot command with captured output. **AGENT ONLY.** FOREGROUND by default:
  it BLOCKS until the command exits and prints the output inline, and sends NO
  notification because you already hold the result. A run is NEVER moved to the
  background on its own, however long it takes. Bounded by a 30-minute cap.
- `server` — a long-running process with captured output and an OPTIONAL port. Startable
  by an agent or a user. Returns as soon as it is up. NOT subject to the 30-minute cap.
- `shell` — an interactive terminal. **USER ONLY**, no output capture.

The retired spellings `interactive`, `command` and `agent` are REJECTED by the hub, not
aliased. There is no separate command-execution group any more: `shell run` is how an agent
runs a command, and it is the only way.

- `shell run --cmd <command> [--cwd <dir>] [--label <lbl>] [--bg]` — run a command and
  WAIT for it. `--bg` instead returns a session id immediately and notifies you on
  completion; only backgrounded runs notify. Ctrl-C does not stop a run — it keeps going
  and stays reachable with `shell log` and `shell kill`. Bridge, agent, conversation and
  project come from your own context; the conversation cannot be overridden.
- `shell serve --cmd <command> [--port <n>] [--cwd <dir>] [--label <lbl>]` — start a
  long-running process. `--port` is OPTIONAL; a portless server is valid and simply
  exposes nothing. Two live sessions cannot hold the same port on one bridge — the second
  is refused, naming the holder.
- `shell background <session_id>` — move a running FOREGROUND run to the background.
  Releases whoever is waiting on it and notifies on completion from then on. One-way.
- `shell start --bridge <id> [--kind run|shell|server] [--cmd <cmd>]
  [--cwd <dir>] [--label <lbl>] [--port <n>] [--project <id>] [--chain <id>]` — launch a
  session explicitly. Scope is per kind and enforced by the hub: `server` needs `--chain`,
  `run` needs `--agent`, `shell` needs neither. Returns `{session_id, status, pid}`.
  - `--port <n>` declares the port the process binds. A declared port is what makes the
    session reachable over HTTP (see below), whatever its `--kind`. It does not have to
    be declared at start — see `shell set-port`.
- `shell list --bridge <id> | --chain <id> [--project <id>] [--status <s>]` — one of
  `--bridge` or `--chain` is REQUIRED. `--project` alone fails with
  `chain_id query parameter is required`. Columns: session_id, kind, label, status, pid,
  server_port, uptime.
- `shell log <session_id> [--offset N] [--limit N] [--grep <pattern>]` — returns
  `{lines, truncated, total_lines}`. `--offset` skips lines from the HEAD of the log and
  `--limit` caps how many come back; there is no tail mode, so "the end of the log" is an
  explicit offset.
- `shell capture <session_id>` — snapshot of the current terminal screen.
- `shell signal <session_id> --signal <int>` — send a POSIX signal (e.g. 2 = SIGINT).
- `shell restart <session_id>` — stop then start; returns `{session_id, pid, status}`.
- `shell set-port <session_id> --port <n> | --clear` — declare (or clear) the port of a
  session that is ALREADY running, for the usual case: you open an interactive terminal,
  then decide to run a server in it, so there was nothing to declare at start. Takes
  effect immediately on both access paths, with no restart. `--port 0` and `--clear` are
  the same request. Refused with 409 on a session that has exited, and 404 on one you do
  not own. Returns the updated session.
- `shell kill <session_id>` — terminate the session.

### Sending an HTTP request to a server session, via the Bridge
A `--kind server --port N` session is reachable from this host through the Bridge's
local endpoint — the same endpoint `ham-ctl` itself talks to. No inbound port is opened
and no user token or browser session is involved:

```
http://127.0.0.1:<local_endpoint_port>/proxy/<session_id>/<path>
```

The Bridge relays over the WebSocket it already holds to the Hub; the Hub splices it to
the Bridge that owns `<session_id>`, and that Bridge dials `127.0.0.1:<declared port>`.
Method, path, query string and body are all forwarded.

Find the local endpoint port (TCP fallback; default `49324`) with
`bridge list --scope configured` -> `{"local_endpoint_port": 49324}`. The unix socket
path is in `$HEIMDALL_BRIDGE_ENDPOINT` (`unix:/path/to/bridge.sock`).

```bash
# start a server session
ham-ctl shell start --bridge brg_abc --kind server --port 8000 \
  --cwd /srv/site --cmd 'python3 -m http.server 8000 --bind 127.0.0.1'
# -> {"session_id":"sh_123","status":"running","pid":...}

# reach it over TCP
curl http://127.0.0.1:49324/proxy/sh_123/index.html

# or: an interactive session you started a server inside afterwards
ham-ctl shell set-port sh_456 --port 3000
curl http://127.0.0.1:49324/proxy/sh_456/

# or over the unix socket ham-ctl already uses
curl --unix-socket "${HEIMDALL_BRIDGE_ENDPOINT#unix:}" \
  http://localhost/proxy/sh_123/index.html
```

The target must be `status=running`, have a declared port, and be owned by you. Any
session kind qualifies — an interactive shell you started a server inside is reachable
too, whether the port was declared with `start --port` or later with `set-port`.
Refusals come back as JSON `{"error":"<reason>"}`:

| status | reason | meaning |
| --- | --- | --- |
| 404 | `session_not_found` | no such session, or it is not yours |
| 409 | `session_not_running` | session has exited |
| 409 | `no_server_port` | no port declared — use `shell set-port` |
| 403 | `cross_owner` | belongs to another user |
| 503 | `unavailable` | Bridge cannot reach the Hub |

Any process on this host that can reach the local endpoint can use this path and acts
with the Bridge owner's authority; it is disabled by `--no-local-proxy` or
`[bridge] local_proxy_enabled=false`.

### Showing a running process to the user
A session serves two user-facing surfaces at once, and both are live:

- **stdout** — any session, no port needed. The user sees it in the session pane; you
  read the same stream with `shell log <session_id>`.
- **a preview** — any session with a declared port. The Hub serves it to the user's
  browser at `<hub-origin>/api/v1/preview/<session_id>/`, tunnelled to the Bridge that
  owns the session. Nothing is exposed: no inbound port is opened on the Bridge host or
  the Hub, and it works with the Hub on a different machine.

So `shell start --port N` is the way to hand someone a dev server, a report, a
dashboard, or any HTTP UI running on a Bridge host they cannot reach directly.

### Two sessions calling each other through the Hub
Every preview lives under the same parent path, so a page in one session reaches a
service in another with a **relative** URL — no host, no port, no Hub name in the page:

```js
// page served at <hub>/api/v1/preview/<FE_SESSION>/
const api = (p) => new URL(`../${BACKEND_SESSION}/${p}`, location.href).toString();
//   -> <hub>/api/v1/preview/<BACKEND_SESSION>/<p>
```

Both sessions are then same-origin with the Hub and with each other, so this needs no
CORS headers and triggers no preflight. The same relative form also resolves correctly
under the Bridge-local `/proxy/<session_id>/` path above, because that path has the same
`<prefix>/<session_id>/` shape — which means you can verify a browser flow server-side
with `curl` before anyone opens it.

Verified end to end: `POST` crosses the tunnel with method and body intact, responses
carry real server state across calls, and non-2xx statuses propagate unchanged (a 404
from the target arrives as a 404, not as a tunnel error).

**Limitation — no service discovery.** A session id does not exist until
`shell start` returns, and it is *not* injected into the process environment. There is no
name resolution between sessions. Start the callee first and pass its id to the caller
(env var, config file, or generated markup); or start the caller, then bind the port
later with `set-port`. Two services that must reference each other need one of them to
learn the other's id after the fact.

### Limitations when a session is previewed in a browser
The Hub strips `/api/v1/preview/<session_id>` before forwarding and does **not** rewrite
HTML. Your process therefore sees ordinary root-relative paths, while the browser sees
the prefix. That asymmetry is behind every problem below.

- **Absolute URLs break.** A page emitting `/assets/app.js` makes the browser resolve it
  against the Hub root, not your session — the preview renders blank. Emit
  **relative** URLs (`./assets/app.js`) and it works at any prefix, unchanged.
- **Emitting the prefix instead is not enough on its own.** Telling a dev server its
  public base is `/api/v1/preview/<id>/` fixes the HTML, but that server will then `404`
  the stripped paths the Hub forwards. Satisfying both ends needs a small reverse proxy
  on the declared port that re-adds the prefix before the dev server sees it (and relays
  `Upgrade`, or HMR dies).
- **Path-routed SPAs match no route.** The app reads `location.pathname` and gets
  `/api/v1/preview/<id>/`. Hash routing avoids this — but check the no-hash fallback:
  Heimdall's own UI falls back to the real pathname when the hash is empty
  (`src/ui/utils/appLocation.ts`), and the preview URL carries no hash, so it must be
  seeded (`location.replace(location.pathname + '#/')`) before app code runs.
- **A previewed page is same-origin with the Hub.** Its own absolute `/api/v1/...`
  requests go to the **Hub**, authenticated as the viewing user — not to your session,
  and not through any proxy your dev server configures, because those requests never
  reach your dev server at all. Use the relative `../<session_id>/` form above to address
  a session deliberately.

## memory — durable memories
- `memory list [--agent-ids <id,...>] [--project-ids <id,...>] [--bridge-ids <id,...>] [--template-ids <id,...>] [--status <s>] [--type <t>] [--limit <n>]` — list memories (metadata only).
- `memory show <memory-id>` — full memory details (body + evidence).
- `memory content <memory-id>` — print the raw memory body.
- `memory propose --type <t> --title <t> [--description <t>] [--body <t>] [--evidence <t>] [--agent-ids <id,...>] [--project-ids <id,...>] [--bridge-ids <id,...>] [--template-ids <id,...>]` — propose a durable memory.

### Memory scope (FOUR dimensions — there is no `--scope` word-flag)
Scope is set by four id-list dimensions, each accepting singular/plural spellings and
either repeated flags or comma-separated values:

| Dimension | Accepted flag spellings |
|-----------|-------------------------|
| agent     | `--agent-id` / `--agent-ids` / `--agent` / `--agents` |
| project   | `--project-id` / `--project-ids` / `--project` / `--projects` |
| bridge    | `--bridge-id` / `--bridge-ids` / `--bridge` / `--bridges` |
| template  | `--template-id` / `--template-ids` / `--template` / `--templates` |

An OMITTED dimension applies broadly (to all); the agent dimension defaults to the
caller's own agent. "Global" scope = omit the scope flags. Repeatable or comma-separated:
`--project-ids proj_1,proj_2` and `--project proj_1 --project proj_2` are equivalent.

## context — instance snapshot
- `context` — one-shot snapshot of this instance: chain, current task, and unread counts.
  Takes no arguments.

## start-success — startup signal
- `start-success` — signal this instance is ready. Run once at startup; idempotent.

Task verification commands are optional: omit `brief.verify` (or use an empty value or `"none"`) when no command applies. Publishing and submission do not require a verify result or an output contract in that case. If a command is configured, passing verification is required and `--verify none` cannot bypass it. `ham-ctl verify` reports success with nothing to run when no command is configured.
