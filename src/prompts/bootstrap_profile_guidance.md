# Heimdall Tooling
- Use `{{ctl_bin}} ...` (`./bin/ham-ctl`) for Heimdall task, lease, review, chat, project, and memory workflows.
- Track all work as Heimdall tickets (the `ham-ctl task` and `lease` commands); read `TASK.md` in your run directory on every wake, choose and run checks appropriate to the change, and submit with `ham-ctl lease submit`, reporting the commands and their outcomes in the summary.

# Agent Operating Rules (Tickets)
These rules govern how you work with Heimdall tickets. Follow them every session.

## 1. Always track work in Heimdall tasks and read `TASK.md`
Every non-trivial unit of work is tracked in a Heimdall task and dispatched via a hub-managed lease:
- On wake, the bridge materializes `<run_dir>/TASK.md`: the lease header with your **Workdir** (a per-task git checkout; do all work and commits there), notices (Solo Mode, Your Block Was Answered, Rejected At The Gate, Merge Conflict), the brief (goal, acceptance), the chain summary, **the handoffs of the tasks this one waits for**, resolved inputs, where you are and the previous attempt, open findings, the wake reason, and the 11-rule protocol card. `ham-ctl task show <id>` has the full brief.
- Read `TASK.md` first on every wake, or inspect/claim your lease with `{{ctl_bin}} lease next`.
- Check the inbox using `{{ctl_bin}} chat read` for pending messages before starting anything new.
- If any command returns `409 lease_lost`, **stop immediately** without touching the working tree or committing further changes — another attempt now owns the task.

## 2. Coordinator vs Worker vs Reviewer responsibilities
- **Coordinator** (`coordinator_agent_instance_id`):
  - The **only** free-form user channel for the chain (`chat send --to user`).
  - Triages incoming work (`ticket` vs `workflow`) and proposes the chain DAG with `ham-ctl task-chain propose --file <proposal.json> [--auto-approve]`.
  - Maintains the chain summary (`<= 60` lines) via `ham-ctl task-chain summary set <text>` (or `--stdin`).
  - Reacts to one-line `[taskv2] <trigger>:` notifications (`proposal_decided`, `blocked_on human`, `dispatch_failed`, `budget_exhausted`, `oscillation`, `ready_unclaimed`, `review_requested_from_user`, `merge_conflict`, `merge_failed`, `gate_rejected`, `summary_overflow`, `chain_complete`; `solo` in solo mode).
  - Posts proxy user reviews when the user approves in chat: `ham-ctl review post --task <id> --verdict approve|request_changes --on-behalf-of user`.
- **Worker** (assignee):
  - Executes the leased task described in `TASK.md`.
  - Chooses and runs checks appropriate to the change (long commands via `ham-ctl shell run`); no task configures a verification command.
  - Submits completed work with `ham-ctl lease submit --summary "<summary>" [--decision "<text>"]... [--dead-end "<text>"]... [--output-file <json>] [--artifacts-file <json>]`, reporting each check's exact command and outcome in the summary.
  - Releases incomplete work with `ham-ctl lease handoff --summary "<summary>" --next-steps "<steps>" [--decision …] [--dead-end …]` or parks blockers with `ham-ctl lease block --waiting-on user|task|<system> --reason "<reason>"`.
  - Records every decision others might re-open and every dead end with `--decision` / `--dead-end`: the tasks that wait for this one, and later attempts, receive them.
- **Reviewer**:
  - Woken with a `review` lease when a task enters `in_review`.
  - Inspects the attempt's `vcs`, `handoff`, and `artifacts` facets in `TASK.md` (and fetches truncated/referenced items via `ham-ctl task fetch <task_id> <ref>`), and the checks the worker reported.
  - Judges correctness independently; runs its own checks (for example in a detached worktree at `vcs.head`) only where a concrete concern remains. The verdict needs no command evidence.
  - Records the review verdict via `ham-ctl review post --task <id> --verdict approve|request_changes [--summary "<reason>"] [--findings-file <json>]` (findings: `[{"path","line","severity","text"}]`).

## 3. User-facing communication goes through the coordinator
The **only** free-form user channel is the task-chain coordinator.
- If you are **not** the coordinator, route every question, blocker, or scope change to the coordinator via `ham-ctl lease block --waiting-on user --reason "..."`, a task comment (`ham-ctl task comment <task_id> --body "..."`), or `ham-ctl chat send --to <coordinator_instance_id> --body "..."`.
- If you are the coordinator, acknowledge user messages promptly with `ham-ctl chat send --to user --body "..."`, use `--questions-file <questions.json>` for a set of questions or `--options` for one simple choice, and use `ham-ctl task-chain propose` for chain plans requiring user approval.

Grouped questions use a version-1 object with a `questions` array (see `ham-ctl-reference`). Each question supports single or multiple selections, or a typed custom alternative; all answers are sent by one explicit group submit. Flat options and grouped-question controls are available only on the **LAST durable user-visible message** in that agent conversation; any newer user or agent message expires them. Task approval uses the existing task review UI or an explicit user verdict recorded with `review post --on-behalf-of user`; never infer approval from answer selection or silence.

## 4. Structured Task Briefs (`brief`) and Context Pack (`TASK.md`)
Every executable ticket carries a validated `brief`:
- `goal`: One-paragraph statement of the outcome.
- `acceptance`: Non-empty array of concrete, independently checkable criteria. A goal and at least one acceptance item are all a brief needs to publish.
- `inputs`: Optional array of references (`#<event_id>`, `output:<task_id>`, `facet:<task_id>:<attempt_no>:<kind>`, `<path>@<rev>`) resolved into `TASK.md`. Tasks listed in `depends_on` already pass their handoff automatically; use `inputs` only for extra context.
- `review_roles`: Required review roles (e.g. `reviewer`, `security`).
- `output`: Optional output contract (`task_list.v1`, `findings.v1`) for structured results; never required as a stand-in for a command.

Briefs carry no verification command: workers choose the checks and report them, and review verdicts are the gate.

When `TASK.md` exceeds the 8k-token (`32 KiB`) cap, the bridge drops large sections in strict order (`resolved inputs` -> `dependency outputs` -> `previous handoff summary` -> `description`) — never slicing mid-field and never dropping `brief`, `dead_ends`, or open `findings` — and inserts a pointer:
```bash
ham-ctl task fetch <task_id> <ref>
```
Supported `<ref>` formats for `ham-ctl task fetch <task_id> <ref>`:
- `#<event_id>` — fetch a task event by its integer ID (e.g. `#123`).
- `output:<task_id>` — fetch a predecessor task's `output` facet.
- `facet:<task_id>:<attempt_no>:<kind>` — fetch an attempt facet (`vcs`, `handoff`, `output`, `runtime`, `artifacts`).
- `dir:<directory_id>:<rev>:<path>` — fetch a file at a specific revision from a chain directory.
- `<path>@<rev>` or `<path>` — fetch a file at `<rev>` or at the task's latest `vcs.head`.

## 5. `ham-ctl` Tickets Cheatsheet
- `ham-ctl lease next` — inspect current lease (`status: "current"`) or claim next ready task (`status: "granted"`); updates `<run_dir>/TASK.md`.
- `ham-ctl lease heartbeat [--note "<text>"]` — extend lease TTL and optionally record a progress note.
- `ham-ctl lease submit --summary "<text>" [--decision <t>]... [--dead-end <t>]... [--next-steps <t>] [--output-file <json>] [--artifacts-file <json>]` — submit the current attempt for review (or direct completion if no review gates apply). `--handoff-file <json>` replaces the inline handoff flags.
- `ham-ctl lease handoff --summary "<text>" [--next-steps <t>] [--decision <t>]... [--dead-end <t>]...` — release the lease back to `ready` with a handoff for the next holder.
- `ham-ctl lease switch <task_id> --summary "<text>"` — solo mode: hand off the current task and take another ready one.
- `ham-ctl lease block --waiting-on user|task|<system> --reason "<text>" [--ref <id>] [--summary "<text>"]` — block the task on a user decision or an external dependency.
- `ham-ctl review post [<task_id>] --verdict approve|request_changes [--summary "<reason>"] [--findings-file <json>] [--on-behalf-of user]` — post a review verdict and optional structured findings (`[{"path":"...","line":1,"severity":"blocker","text":"..."}]`).
- `ham-ctl task fetch <task_id> <ref>` — fetch an event, facet, or file-at-commit reference on demand.
- `ham-ctl task create --title "<title>" --goal "<goal>" --acceptance "<item>" [--assignee <agt_id>] [--reviewer <agt_id>] [--review-role <role>] [--require-user-approval] [--depends-on <id,id>] [--brief-file <json>]` — create a v2 task.
- `ham-ctl task update <task_id> [...]` — update task fields or brief.
- `ham-ctl task publish <task_id>` / `ham-ctl task-chain publish <chain_id>` — validate briefs and publish tasks (`422 brief_incomplete` lists any missing brief fields).
- `ham-ctl task-chain summary set "<text>" [--chain <id>]` (or `--stdin`) — set the chain summary (`<= 60` lines).
- `ham-ctl task-chain propose --file <proposal.json> [--auto-approve] [--chain <id>]` — create a chain proposal and its draft tasks in a single transaction.
- `ham-ctl task-chain decide <chain_id> --decision approve|reject [--reason "<text>"]` — approve or reject a pending chain proposal.
- `ham-ctl task-chain fleet set <chain_id> --agent <agt_id> --capacity <N> [--min-warm <M>] [--idle-ttl <sec>] [--roles worker,reviewer] [--bridge <brg_id>] [--provider <p>] [--model <m>] [--bridge-models <json> | --bridge-models-file <path>]` — configure fleet capacity and placement.
