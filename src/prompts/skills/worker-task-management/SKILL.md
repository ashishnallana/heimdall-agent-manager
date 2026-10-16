---
name: worker-task-management
description: How a WORKER or REVIEWER agent uses ham-ctl in Task System v2 to read TASK.md, manage leases (`lease next/heartbeat/submit/handoff/block`), run verification (`verify [--independent]`), fetch context refs (`task fetch`), and post structured reviews (`review post`). Load whenever you are a worker or reviewer on a chain.
---

# Worker & Reviewer task management (Task System v2)

You are a worker or reviewer on this chain. Work exclusively on the task currently leased to you by the Hub. Do not coordinate the whole chain or take on unassigned work — route scope questions to the coordinator.

All commands use the managed wrapper: `./.heimdall/bin/ham-ctl`. For exact flags of any command, load the `ham-ctl-reference` skill.

## 1. Read `TASK.md` on wake and inspect your lease (`lease next`)
When the Hub wakes you for a work or review lease, the Bridge materializes `<run_dir>/TASK.md` before your turn starts.
1. **Read `TASK.md` first.** It contains:
   - **Lease header**: `lease_id`, `kind` (`work` or `review`), `attempt_no` / `max_attempts`, `review_round`, `expires_at`, `hard_deadline_at`, and resolved `placement` (`bridge_id`, `directory_id`, `cwd`, `provider`, `model`).
   - **Why (`why`)**: Why you were woken (`first_grant`, `expired`, `changes_requested`, `handoff`, or `reopened`).
   - **Brief (`brief`)**: `goal`, `acceptance` checklist, `verify` command, `inputs`, `review_roles`, `auto_submit`, and `require_independent_verify`.
   - **Resolved inputs (`inputs`)**: Inline payloads for `#<event_id>`, `output:<task_id>`, or `facet:<task_id>:<attempt_no>:<kind>`.
   - **Where you are & Previous attempt (`where_you_are`, `previous_attempt`)**: Previous `vcs` state (`base`, `head`, `dirty`), `verify` result, `handoff` (`done`, `remaining`, `next_steps`, `dead_ends`, `warnings`), and last heartbeat note.
   - **Open review findings (`findings`)**: Blocking and non-blocking findings from prior review rounds.
   - **Chain summary (`chain.summary`)** and the **10-line protocol card**.
2. You can also query or claim your lease explicitly at any time:
   ```bash
   ./.heimdall/bin/ham-ctl lease next
   ```
   This returns `status: "current"` (existing lease), `status: "granted"` (newly claimed ready task, updating `TASK.md`), or `status: "none"`.

## 2. Fetch truncated or referenced context (`task fetch`)
When `TASK.md` exceeds the 8k-token (`32 KiB`) cap, large inputs or prior attempt summaries are replaced with a pointer (`ham-ctl task fetch <task_id> <ref>`). `brief`, `dead_ends`, and open `findings` are never dropped. Fetch any referenced item on demand:
```bash
# Fetch an event by ID
./.heimdall/bin/ham-ctl task fetch <task-id> "#evt_123"

# Fetch a predecessor task's output facet
./.heimdall/bin/ham-ctl task fetch <task-id> "output:task_prev"

# Fetch a specific attempt facet (vcs, verify, handoff, output, findings, runtime, artifacts)
./.heimdall/bin/ham-ctl task fetch <task-id> "facet:<task-id>:1:handoff"

# Fetch a file at a specific revision from a chain directory or task vcs.head
./.heimdall/bin/ham-ctl task fetch <task-id> "dir:<directory-id>:<rev>:src/main.odin"
./.heimdall/bin/ham-ctl task fetch <task-id> "src/main.odin@<rev>"
./.heimdall/bin/ham-ctl task fetch <task-id> "src/main.odin"
```

## 3. Execute work, heartbeat (`lease heartbeat`), and handle `409 lease_lost`
- Every `ham-ctl` command implicitly heartbeats your active lease. During long analysis or edits without CLI calls, send an explicit heartbeat with a progress note:
  ```bash
  ./.heimdall/bin/ham-ctl lease heartbeat --note "Implemented fold transitions; running unit tests next"
  ```
- **CRITICAL (`409 lease_lost`)**: If any `ham-ctl` command returns `409 lease_lost`, your lease expired or was reclaimed. **Stop immediately** — do NOT modify files, do NOT commit, and do NOT run further build commands in the working tree.

## 4. Verify your work (`ham-ctl verify` and `brief.auto_submit`)
Never claim a task is complete without running `ham-ctl verify`:
```bash
./.heimdall/bin/ham-ctl verify
```
- `ham-ctl verify` runs `brief.verify` from your current task as a tracked Run session labelled `verify <task_id> #<attempt_no> @<head>`, heartbeating your lease automatically while it runs.
- On exit, the Hub records the `verify` facet (`exit_code`, `cmd`, `head`, `summary`, `independent: false`) on your current attempt.
- **Automatic submit (`brief.auto_submit`)**: If the task's `brief.auto_submit` is `true`, `ham-ctl verify` exits `0`, and your working tree is clean (`dirty == false`) at `head`, `ham-ctl verify` automatically submits your lease (`agent.lease.submit` with `auto: true` and a summary built from commit subjects since `vcs_base`) and prints the submit result.

## 5. Submit, hand off, or block (`lease submit` / `lease handoff` / `lease block`)

### Submit completed work (`lease submit`)
Once `ham-ctl verify` passes at your current `HEAD` (and all changes are committed if working in a repo), submit the attempt:
```bash
./.heimdall/bin/ham-ctl lease submit \
  --summary "Implemented commit-diff pagination and added unit tests" \
  [--handoff-file handoff.json] \
  [--output-file output.json] \
  [--artifacts-file artifacts.json]
```
- `artifacts.json` records structured deliverables (`{"items":[{"kind":"file","path":"...","label":"..."},{"kind":"url","url":"..."},{"kind":"preview_port","port":5173}]}`).
- If the Hub returns `409 verify_required`, `409 verify_failed`, `409 verify_stale`, or `409 verify_dirty`, fix the issue (commit uncommitted files, re-run `ham-ctl verify` at the new `HEAD`) and re-run `lease submit`.

### Hand off incomplete work (`lease handoff`)
If you must stop before finishing (approaching deadline or context limit), hand off cleanly so the next attempt starts with your findings and `dead_ends`:
```bash
cat > handoff.json <<'EOF'
{
  "done": ["Added SQLite migration for chain summary"],
  "remaining": ["Wire HTTP handler and unit tests"],
  "next_steps": ["Add route in wiring.odin", "Run odin test src/hub/service/taskchain"],
  "dead_ends": ["Do not acquire state_mutex before tx_mutex (violates lockorder)"],
  "warnings": ["Keep summary <= 60 lines"]
}
EOF

./.heimdall/bin/ham-ctl lease handoff \
  --summary "Migration complete; handler wiring remaining" \
  --handoff-file handoff.json
```

### Block on an external dependency (`lease block`)
If you cannot proceed without a human decision, another task, or an external system:
```bash
./.heimdall/bin/ham-ctl lease block \
  --waiting-on human \
  --reason "Need confirmation whether commit-diff limit should default to 100 or 200" \
  --summary "Blocked on API pagination default"
```

## 6. Reviewing (`review post` and `verify --independent`)
When woken with a `review` lease (`kind: "review"` in `TASK.md`):
1. Read `TASK.md` — inspect the `brief` (`goal`, `acceptance`, `verify`, `require_independent_verify`), the submitted attempt's `vcs`, `verify`, `handoff`, and `artifacts` facets, and any prior `findings`.
2. Inspect changed files at the submitted revision using `ham-ctl task fetch <task-id> "<path>@<head>"` or in the checkout.
3. **Run independent verification (`ham-ctl verify --independent`)**:
   - Whenever `brief.require_independent_verify` is `true` (or for any behavioral/code review), run:
     ```bash
     ./.heimdall/bin/ham-ctl verify --independent [<task-id>]
     ```
   - This checks out the submitted `vcs.head` into an ephemeral detached git worktree, runs `brief.verify` with label `verify <task_id> #<attempt_no> @<head> independent`, records `"independent": true` on the `verify` facet, and removes the worktree on exit without touching the main working tree.
4. **Post your review verdict (`ham-ctl review post`)**:
   - Approve when every acceptance criterion is verified:
     ```bash
     ./.heimdall/bin/ham-ctl review post <task-id> --verdict approve
     ```
   - Request changes with structured findings when criteria are unmet:
     ```bash
     cat > findings.json <<'EOF'
     [
       {
         "severity": "blocker",
         "file": "src/hub/service/taskv2/gate.odin",
         "line": 142,
         "message": "require_independent_verify must check independent == true on the verify facet."
       }
     ]
     EOF

     ./.heimdall/bin/ham-ctl review post <task-id> \
       --verdict request_changes \
       --findings-file findings.json
     ```
   - When all required review gates and `require_independent_verify` are satisfied with no `request_changes`, the Hub transitions the task to `done` and unblocks dependents automatically.
