# Heimdall Tooling
- Use `{{ctl_bin}} ...` (`./.heimdall/bin/ham-ctl`) for Heimdall task, lease, review, verify, chat, project, and memory workflows.
- Track all work in Heimdall Task System v2 tasks; read `TASK.md` in your run directory on every wake, run `ham-ctl verify`, and submit with `ham-ctl lease submit`.

# Agent Operating Rules (Task System v2)
These rules govern how you work in Heimdall Task System v2. Follow them every session.

## 1. Always track work in Heimdall tasks and read `TASK.md`
Every non-trivial unit of work is tracked in a Heimdall task and dispatched via a hub-managed lease:
- On wake, the bridge materializes `<run_dir>/TASK.md` with your active lease header, wake reason (`first_grant`, `expired`, `changes_requested`, `handoff`, `reopened`), structured `brief` (`goal`, `acceptance`, `verify`, `inputs`, `review_roles`, `auto_submit`, `require_independent_verify`), resolved inputs, previous attempt facets (`where_you_are`, `previous_attempt`, `dead_ends`), open review `findings`, chain summary, and the 10-line protocol card.
- Read `TASK.md` first on every wake, or inspect/claim your lease with `{{ctl_bin}} lease next`.
- Check the inbox using `{{ctl_bin}} chat read` for pending messages before starting anything new.
- If any command returns `409 lease_lost`, **stop immediately** without touching the working tree or committing further changes — another attempt now owns the task.

## 2. Coordinator vs Worker vs Reviewer responsibilities
- **Coordinator** (`coordinator_agent_instance_id`):
  - The **only** free-form user channel for the chain (`chat send --to user`).
  - Triages incoming work (`ticket` vs `workflow`) and proposes the chain DAG with `ham-ctl task-chain propose --file <proposal.json> [--auto-approve]`.
  - Maintains the chain summary (`<= 60` lines) via `ham-ctl task-chain summary set <text>` (or `--stdin`).
  - Reacts to one-line coordinator attention notifications (`proposal_decided`, `blocked_on`, `budget_exhausted`, `oscillation`, `ready_unclaimed`, `review_requested_from_user`, `chain_complete`).
  - Posts proxy user reviews when the user approves in chat: `ham-ctl review post --task <id> --verdict approve|request_changes --on-behalf-of user`.
- **Worker** (assignee):
  - Executes the leased task described in `TASK.md`.
  - Runs `ham-ctl verify` to execute `brief.verify` in a tracked Run session that heartbeats the lease automatically.
  - Submits completed work with `ham-ctl lease submit --summary "<summary>" [--handoff-file <json>] [--output-file <json>] [--artifacts-file <json>]` (or lets `brief.auto_submit` submit automatically when `ham-ctl verify` exits `0` on a clean working tree).
  - Releases incomplete work with `ham-ctl lease handoff --summary "<summary>" --handoff-file <json>` (recording `done`, `remaining`, `next_steps`, `dead_ends`, `warnings`) or parks external blockers with `ham-ctl lease block --waiting-on human|task|external --reason "<reason>"`.
- **Reviewer**:
  - Woken with a `review` lease when a task enters `in_review`.
  - Inspects the attempt's `vcs`, `verify`, `handoff`, and `artifacts` facets in `TASK.md` (and fetches truncated/referenced items via `ham-ctl task fetch <task_id> <ref>`).
  - Runs `ham-ctl verify --independent [<task_id>]` when independent verification in a clean detached git worktree at `vcs.head` is required (`brief.require_independent_verify`) or warranted by risk.
  - Records the review verdict and structured findings via `ham-ctl review post --task <id> --verdict approve|request_changes [--findings-file <json>]`.

## 3. User-facing communication goes through the coordinator
The **only** free-form user channel is the task-chain coordinator.
- If you are **not** the coordinator, route every question, blocker, or scope change to the coordinator via `ham-ctl lease block --waiting-on human --reason "..."`, a task comment (`ham-ctl task comment <task_id> --body "..."`), or `ham-ctl chat send --to <coordinator_instance_id> --body "..."`.
- If you are the coordinator, acknowledge user messages promptly with `ham-ctl chat send --to user --body "..."`, use `--options` for discrete choices, and use `ham-ctl task-chain propose` for chain plans requiring user approval.

## 4. Structured Task Briefs (`brief`) and Context Pack (`TASK.md`)
Every executable task in Task System v2 carries a validated `brief`:
- `goal`: One-paragraph statement of the outcome.
- `acceptance`: Non-empty array of concrete, independently verifiable criteria.
- `verify`: Exact command run by `ham-ctl verify` (or `"none"` only when an `output` schema contract is provided).
- `inputs`: Optional array of references (`#<event_id>`, `output:<task_id>`, `facet:<task_id>:<attempt_no>:<kind>`) resolved into `TASK.md`.
- `review_roles`: Required review roles (e.g. `reviewer`, `security`).
- `auto_submit`: When `true`, a passing `ham-ctl verify` (exit `0`) on a clean working tree at `head` automatically invokes `lease submit` with `auto: true`.
- `require_independent_verify`: When `true`, the review gate requires a passing `verify` facet with `"independent": true` (from `ham-ctl verify --independent`) before transitioning to `done`.

When `TASK.md` exceeds the 8k-token (`32 KiB`) cap, the bridge drops large sections in strict order (`resolved inputs` -> `previous verify summary` -> `previous handoff summary`) — never slicing mid-field and never dropping `brief`, `dead_ends`, or open `findings` — and inserts a pointer:
```bash
ham-ctl task fetch <task_id> <ref>
```
Supported `<ref>` formats for `ham-ctl task fetch <task_id> <ref>`:
- `#<event_id>` — fetch a task event by ID.
- `output:<task_id>` — fetch a predecessor task's `output` facet.
- `facet:<task_id>:<attempt_no>:<kind>` — fetch an attempt facet (`vcs`, `verify`, `handoff`, `output`, `findings`, `runtime`, `artifacts`).
- `dir:<directory_id>:<rev>:<path>` — fetch a file at a specific revision from a chain directory.
- `<path>@<rev>` or `<path>` — fetch a file at `<rev>` or at the task's latest `vcs.head`.

## 5. `ham-ctl` Task System v2 Cheatsheet
- `ham-ctl lease next` — inspect current lease (`status: "current"`) or claim next ready task (`status: "granted"`); updates `<run_dir>/TASK.md`.
- `ham-ctl lease heartbeat [--note "<text>"]` — extend lease TTL and optionally record a progress note.
- `ham-ctl verify [<task_id>] [--independent]` — run `brief.verify` in a tracked Run session (with `--independent`, runs in an ephemeral detached git worktree at the attempt's `vcs.head` and records `"independent": true`).
- `ham-ctl lease submit --summary "<text>" [--handoff-file <json>] [--output-file <json>] [--artifacts-file <json>] [--verify none]` — submit the current attempt for review (or direct completion if no review gates apply).
- `ham-ctl lease handoff --summary "<text>" [--handoff-file <json>]` — release lease back to `ready` with structured handoff (`done`, `remaining`, `next_steps`, `dead_ends`, `warnings`).
- `ham-ctl lease block --waiting-on human|task|external --reason "<text>" [--ref <id>] [--summary "<text>"]` — block the task on an external dependency or human decision.
- `ham-ctl review post [<task_id>] --verdict approve|request_changes [--findings-file <json>] [--on-behalf-of user]` — post a review verdict and optional structured findings (`[{"severity":"blocker|major|minor|nit","file":"...","line":1,"message":"..."}]`).
- `ham-ctl task fetch <task_id> <ref>` — fetch an event, facet, or file-at-commit reference on demand.
- `ham-ctl task create --title "<title>" --goal "<goal>" --acceptance "<item>" --verify "<cmd>" [--assignee <agt_id>] [--review-role <role>] [--depends-on <id,id>] [--auto-submit] [--require-independent-verify] [--brief-file <json>]` — create a v2 task.
- `ham-ctl task update <task_id> [...]` — update task fields or brief.
- `ham-ctl task publish <task_id>` / `ham-ctl task-chain publish [<chain_id>]` — validate briefs and publish tasks (`422 brief_incomplete` lists any missing brief fields).
- `ham-ctl task-chain summary set "<text>" [--chain <id>]` (or `--stdin`) — set the chain summary (`<= 60` lines).
- `ham-ctl task-chain propose --file <proposal.json> [--auto-approve] [--chain <id>]` — create a chain proposal and its draft tasks in a single transaction.
- `ham-ctl task-chain decide [<chain_id>] --decision approve|reject [--reason "<text>"]` — approve or reject a pending chain proposal.
- `ham-ctl task-chain fleet set <chain_id> --agent <agt_id> --capacity <N> [--min-warm <M>] [--idle-ttl <sec>] [--roles worker,reviewer] [--bridge <brg_id>] [--provider <p>] [--model <m>] [--bridge-models <json>]` — configure fleet capacity and placement.
