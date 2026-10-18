---
name: worker-task-management
description: How a WORKER or REVIEWER agent works a Task System v2 lease with ham-ctl — read TASK.md, work in the per-task Workdir, heartbeat, verify (`ham-ctl verify [--independent]`), submit / hand off / block (`lease submit|handoff|block`) with decisions and dead ends, fetch referenced context (`task fetch`), and post structured reviews (`review post`). Also how to share what you learned with the tasks that come after yours. Load whenever you are a worker or reviewer on a chain.
---

# Worker & reviewer task management (Task System v2)

The Hub hands you work as a **lease** on one task. You never set task status: holding a work lease *is* `in_progress`; `lease submit` moves the task to `in_review` (or `done` when nobody reviews it). Work only on the leased task; route scope questions to the coordinator (task comment, or `ham-ctl chat send --to <coordinator-instance-id>`).

All commands use `./.heimdall/bin/ham-ctl`. Exact flags: the `ham-ctl-reference` skill or `ham-ctl <group> --help`.

## Decision table: which command, when
| Situation | Command |
|---|---|
| Woken, or unsure what you hold | read `TASK.md`, then `lease next` |
| Idle and want work (solo mode, or after finishing) | `lease next` |
| Need context `TASK.md` omitted or points to | `task fetch <task-id> <ref>` |
| Long stretch without ham-ctl calls | `lease heartbeat --note "<progress>"` (at least every 15 min) |
| Made a choice others might re-open, or hit a dead end | note it now; pass it at submit/handoff as `--decision` / `--dead-end` |
| Work done, ready to prove it | commit everything in the Workdir, then `verify` |
| `verify` passed on a clean tree | `lease submit --summary … [--decision …] [--dead-end …]` |
| `verify` failed | fix, commit, `verify` again; never submit a failing head |
| Submit refused (`409 verify_*`) | commit, `verify` at the new head, `lease submit` again |
| Context or time running out, not finished | `lease handoff --summary … --next-steps … [--dead-end …]` |
| Need a user decision or an external system | `lease block --waiting-on user --reason "<question>"` (or `--waiting-on <system>`) |
| Brief is ambiguous or contradicts itself | `task comment <task-id> --body "<what is unclear>"`, then block if you cannot proceed |
| Woken with **Merge Conflict** | merge the directory's branch into yours in the Workdir, resolve, commit, `verify`, submit |
| Woken with `changes_requested` | address every Open Finding, `verify`, submit |
| Woken with **Your Block Was Answered** | continue with the answer; no need to ask again |
| Any command returns `409 lease_lost` | stop at once; touch nothing |
| Woken as a reviewer | read the role description (`lease next`), inspect the head, `verify --independent` if required, then `review post` |
| Review: everything checks out | `review post --verdict approve` |
| Review: something is wrong | `review post --verdict request_changes --summary … [--findings-file …]` |
| Solo: an urgent task arrives mid-task | `lease switch <task_id> --summary "<where you left off>"` |
| Found an unrelated bug | `issue list --query …`, then `issue vote <id>` or `issue create`; do not fix it in this task |

Never: set task status by hand, review your own work, or keep working after `lease_lost`.

## 1. On wake: read `TASK.md`
The Bridge writes `<run_dir>/TASK.md` before your turn. It is your authoritative context. Sections, in order (each only when it applies):

| Section | What it tells you |
|---|---|
| Header | `lease_id`, attempt `n/max`, `review_rounds`, deadlines, placement (bridge, directory, provider, model) and the **Workdir** + branch |
| Solo Mode | you are the chain's coordinator *and* worker (see §8) |
| Your Block Was Answered | the question you blocked on and the user's answer |
| Rejected At The Gate | why a workflow gate rejected your previous output |
| Merge Conflict | your finished branch did not merge; reconcile it (see §2) |
| Brief | goal, acceptance checklist, verify command (`ham-ctl task show <id>` has the full brief) |
| Chain Summary | done tasks (+ commit), open tasks, **dead ends from every attempt in the chain**, coordinator notes |
| From The Tasks This One Waits For | each dependency's handoff summary, decisions, dead ends, next steps, last commit, verify result, output |
| Resolved Inputs | the refs your brief lists in `inputs`, resolved |
| Where You Are / Previous Attempt | VCS state; the last attempt's outcome, handoff, verify result and heartbeat note |
| Open Findings | review findings you must address |
| Why You Were Chosen | the wake reason: `first_grant`, `review`, `changes_requested`, `handoff`, `answered`, `reopened`, `expired…`, `retry_after_expiry`, `released`, `user_stopped` |
| Protocol Rules | the 11-rule card; follow it |

`ham-ctl lease next` returns your lease (`status: current`), grants a ready task (`granted`, rewrites `TASK.md`) or `none`. Its JSON also carries what each review role must check (`lease.review_roles[].description`).

## 2. Work in the Workdir
In a git directory every task gets its own checkout: `<dir>/.heimdall/worktrees/<task_id>` on branch `heimdall/<task_id>`. **`cd` to the Workdir and do all edits and commits there.** `verify` and `lease submit` run there automatically. When the task is `done` the Hub merges your branch into the directory's branch. Work from tasks you depend on is already merged into your starting point.

If you are woken with a **Merge Conflict** section: in the Workdir, merge the directory's current branch into yours, resolve, commit, `ham-ctl verify`, submit.

## 3. Heartbeat and `409 lease_lost`
Every `ham-ctl` call heartbeats implicitly. During long stretches without CLI calls, leave a note (it survives into the next attempt if this one dies):
```bash
./.heimdall/bin/ham-ctl lease heartbeat --note "fold transitions done; running unit tests"
```
**`409 lease_lost`: stop immediately.** Do not edit, commit or build further; the Hub re-wakes you with a fresh pack if needed.

## 4. Verify
Never submit without a passing verify at the exact commit you submit:
```bash
./.heimdall/bin/ham-ctl verify
```
It runs `brief.verify` as a tracked run and records a `verify` facet (`command`, `exit_code`, `head_at_start`, `head_at_end`, `dirty`, `summary`, `independent`). With `brief.auto_submit: true`, a passing verify on a clean tree submits for you (summary from your commit subjects).

## 5. Submit, hand off, or block — and share what you learned
The tasks after yours see only their `TASK.md`. What you write here is what they learn:

| You write | Where it goes |
|---|---|
| `--summary` (line 1 = what exists now) | chain summary for **every** later task; full text to dependents and the next attempt |
| `--decision` (repeat per item) | dependents and the next attempt |
| `--dead-end` (repeat per item) | chain summary for every task, dependents, next attempt; never dropped for size |
| `--next-steps` | dependents and the next attempt |
| `--output-file` | dependents (inline when small), workflow fan-out / templates |

**Record every decision others might re-open and every dead end in these flags, not only in the summary text** (protocol rule 11).

```bash
# Finished
./.heimdall/bin/ham-ctl lease submit \
  --summary "Added refresh_tokens table and rotation in auth/tokens.py; unittest green" \
  --decision "sha256 for token hashes (bcrypt too slow per request)" \
  --dead-end "SQLite partial index on revoked_at: our migrator rejects it" \
  [--output-file output.json] [--artifacts-file artifacts.json]

# Not finished (context or time running out): the next holder starts from this
./.heimdall/bin/ham-ctl lease handoff \
  --summary "Migration done; handler wiring remains" \
  --next-steps "add the route in wiring.odin; run odin test src/hub/service/taskchain" \
  --dead-end "taking state_mutex before tx_mutex violates lockorder"

# Waiting on the user or something external
./.heimdall/bin/ham-ctl lease block --waiting-on user \
  --reason "Should the commit-diff limit default to 100 or 200?"
```
- Inline flags or `--handoff-file handoff.json` (`{"decisions":[…],"dead_ends":[…],"next_steps":"…"}`), not both.
- `artifacts.json`: `{"items":[{"kind":"file","path":"…","label":"…"},{"kind":"url","url":"…"},{"kind":"preview_port","port":5173}]}`.
- Submit refusals `409 verify_required | verify_failed | verify_stale | verify_dirty`: commit everything, re-run `ham-ctl verify` at the new head, submit again.
- A block parks the task in `backlog`; the answer arrives in `TASK.md` ("Your Block Was Answered"). `--waiting-on` is free text: `user` for the user, `task` for another task, anything else for external systems.

## 6. Fetch omitted or referenced context
`TASK.md` is capped (~8k tokens). When it overflows, resolved inputs go first, then dependency outputs, then the previous verify output, then the previous handoff summary; each is replaced by a fetch pointer. The brief, dead ends and open findings are never dropped.
```bash
./.heimdall/bin/ham-ctl task fetch <task-id> "#123"                          # an event (integer id)
./.heimdall/bin/ham-ctl task fetch <task-id> "output:<other-task-id>"        # another task's output
./.heimdall/bin/ham-ctl task fetch <task-id> "facet:<task-id>:1:handoff"     # handoff|vcs|verify|output|runtime|artifacts
./.heimdall/bin/ham-ctl task fetch <task-id> "src/main.odin@<rev>"           # a file at a revision
./.heimdall/bin/ham-ctl task fetch <task-id> "dir:<directory-id>:<rev>:src/main.odin"
```

## 7. Reviewing
When `TASK.md` says `reviewer` (a review lease):
1. Read the brief, the submitted attempt (summary, verify, handoff) and the role description in `lease next` (`lease.review_roles[].description`): it says what *your* role must check.
2. Inspect the change at the submitted head (`git show --stat <head>`, or `task fetch <task-id> "<path>@<head>"`).
3. Verify independently whenever `brief.require_independent_verify` is set (and for any behavioural change):
   ```bash
   ./.heimdall/bin/ham-ctl verify --independent
   ```
   It checks out the submitted head in a throwaway worktree, runs the verify command there and records `independent: true`.
4. Post the verdict:
   ```bash
   ./.heimdall/bin/ham-ctl review post --verdict approve

   cat > findings.json <<'EOF'
   [{"path": "src/hub/service/taskv2/gate.odin", "line": 142, "severity": "blocker",
     "text": "require_independent_verify must check independent == true"}]
   EOF
   ./.heimdall/bin/ham-ctl review post --verdict request_changes \
     --summary "independent verify is not enforced" --findings-file findings.json
   ```
   Findings use `path`, `line`, `severity`, `text`. `request_changes` needs `--summary` or findings. The response says `gate: waiting|approved|changes_requested`. When every required review passes, the task is `done`, its branch is merged and its dependents become ready.

## 8. Solo mode
When `TASK.md` has a **Solo Mode** section you are the coordinator and the worker; the user reviews. Pull work with `lease next` (nothing is pushed to you), submit, and pull the next task right away. To take an urgent task mid-way: `ham-ctl lease switch <task_id> --summary "<where you left the current one>"` (the current task returns to `ready`; the attempt is not counted). You never review your own work; the Hub refuses it.
