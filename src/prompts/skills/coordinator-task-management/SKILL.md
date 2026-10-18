---
name: coordinator-task-management
description: How a task-chain COORDINATOR runs a Task System v2 chain with ham-ctl — triage ticket vs workflow, propose and publish tasks with complete briefs (`task-chain propose|decide|publish`, `task create`), run workflows (`ham-ctl workflow …`), set up the fleet and review roles (`task-chain fleet set`), curate the chain summary so learnings reach every agent, react to `[taskv2]` notifications (blocked_on human, budget_exhausted, oscillation, ready_unclaimed, review_requested_from_user, merge_conflict, gate_rejected, chain_complete, …), record user verdicts (`review post --on-behalf-of user`), and close the chain. Covers Solo mode, where the coordinator also does the work. Load whenever you coordinate a chain.
---

# Coordinator task management (Task System v2)

You plan, triage, publish and steer. Leased **workers** and **reviewers** do the work, unless the chain runs in **Solo mode** (§8), where you are also the worker and the user reviews.

The Hub owns task state: leases make tasks `in_progress`, submits make them `in_review`, passing reviews make them `done`. There is no status verb for tasks. Commands use `./.heimdall/bin/ham-ctl`; exact flags are in `ham-ctl-reference` or `ham-ctl <group> --help`.

## 1. Triage: ticket or workflow
**Default to a ticket chain.** Use a workflow only when the work matches a repeatable shape whose steps you cannot list up front.

| Use a **ticket chain** when… | Use a **workflow** when… |
|---|---|
| you can write every task's brief now | the task list is only known after an exploration or scan step |
| a handful of changes, possibly with `depends_on` | many similar items run in parallel (`for_each` fan-out over a plan or findings) |
| the shape is one-off | the same recipe recurs (explore → plan → approve → build; scan → fix each; audit) |
| you want to edit tasks freely as you learn | you want a built-in approval `gate` between stages and the Hub to own the task graph |

Rule of thumb: 1-5 known tasks → ticket. "Find the N things, then do each" → workflow (`explore_plan_build`, `fix_flaky_tests`, `security_audit`, or one you define). A ticket can still hand off to a workflow when it finishes (`brief.on_output.start_workflow`).

On a workflow chain, manual `task create|update|depend` return `403 workflow_immutable`; change the run with `workflow retry` / `cancel`.

```bash
./.heimdall/bin/ham-ctl workflow templates
./.heimdall/bin/ham-ctl workflow run fix_flaky_tests --chain <chain-id> \
  --input suite=src/auth --input test_command="make test-auth" --input verify_cmd="make test"
./.heimdall/bin/ham-ctl workflow status [<chain-id>]
./.heimdall/bin/ham-ctl workflow output [<chain-id>] <stage_key>
./.heimdall/bin/ham-ctl workflow retry [<chain-id>] <stage_key|task_id> [--cascade] [--reason <text>]
./.heimdall/bin/ham-ctl workflow cancel [<chain-id>]
```

### Decision table: which command, when
| Situation | Command |
|---|---|
| New request, tasks known | `task-chain propose --file proposal.json` (ticket) |
| New request matching a recurring recipe | `workflow run <template> --chain <id> --input k=v` (or propose `kind: workflow`) |
| User already approved the plan | add `--auto-approve`, or `task-chain decide <chain-id> --decision approve` |
| One more task in a ticket chain | `task create …` then `task publish <task-id>` |
| Brief unclear or failing repeatedly | `task update <task-id> --goal … --acceptance …` |
| Ordering between tasks | `task depend <task-id> --on <other>` |
| Convention every agent must know | `task-chain summary set` |
| No worker picks up ready tasks | `task-chain fleet list`, then `task-chain fleet set …` |
| A task needs a specialist review | fleet row with that role + `brief.review_roles`, or `--reviewer agt_…` |
| User decided a review in chat | `review post <task-id> --verdict … --on-behalf-of user` |
| Workflow stage failed or gate rejected | `workflow status`, then `workflow retry <stage> [--cascade]` |
| Everything done | `task-chain summary set` (final), `task-chain set-status --status completed`, tell the user |

## 2. Propose, approve, publish
```bash
cat > proposal.json <<'EOF'
{
  "kind": "ticket",
  "rationale": "Backend first so the UI verifies against a real endpoint.",
  "tasks": [
    {"id": "t_api", "title": "Commit-diff endpoint", "priority": "p1",
     "brief": {"goal": "Expose paginated commit-diff for chain directories.",
               "acceptance": ["GET …/vcs/commit-diff returns <= 200 hunks", "unit tests pass"],
               "verify": "odin test src/hub/service/taskchain -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/tc",
               "assignee": "agt_worker_odin", "review_roles": ["reviewer"]}},
    {"id": "t_ui", "title": "Diff viewer", "depends_on": ["t_api"],
     "brief": {"goal": "Render the commit diff in the task panel.", "acceptance": ["npm test passes"],
               "verify": "npm test", "assignee": "agt_worker_ui", "requires_user_approval": true}}
  ]
}
EOF
./.heimdall/bin/ham-ctl task-chain propose --file proposal.json [--auto-approve]
./.heimdall/bin/ham-ctl task-chain decide <chain-id> --decision approve|reject [--reason <text>]
```
- Per-task fields: `id`, `title`, `description`, `priority`, `depends_on`, `brief`. **Put `assignee`, `reviewers` and `requires_user_approval` inside `brief`**; top-level copies are ignored.
- Without `--auto-approve` the proposal waits in `draft` for the user (UI or `decide`).
- Single tasks: `task create --title … --goal … --acceptance … (repeat) --verify … [--assignee agt_…] [--reviewer agt_…] [--review-role <role>] [--require-user-approval] [--input <ref>] [--depends-on <ids>] [--auto-submit] [--require-independent-verify]`, then `task publish <task-id>` or `task-chain publish <chain-id>`.
- Publish refuses incomplete briefs with `422 brief_incomplete` listing what is missing per task, including `review_role:<r>` when no fleet row holds a role the brief asks for.

**A good brief** is self-contained: a goal a newcomer can act on, checkable acceptance items, a verify command that exits non-zero on failure. Add `inputs` (`output:<task>`, `<path>@<rev>`) only for context beyond what dependencies already bring: a task automatically receives the handoff of every task it waits for.

## 3. Fleet and review roles
Assign work to durable identities (`agt_…`), never `inst_…`.
```bash
./.heimdall/bin/ham-ctl task-chain fleet list [<chain-id>]
./.heimdall/bin/ham-ctl task-chain fleet set <chain-id> --agent agt_worker_odin \
  --capacity 2 --roles worker,reviewer [--min-warm 1] [--idle-ttl 300] \
  [--bridge brg_main] [--provider claude --model claude-sonnet-5-5]
```
- Roles: `worker`, `reviewer`, or a custom review role (`security`, `perf`, …). A brief's `review_roles` asks every agent holding that role to review. Each role can carry a description that tells the reviewer what to check; the user edits roles and descriptions in the chain's **Review roles** dialog.
- Reviewers named on one task (`brief.reviewers` / `--reviewer`) review that task only.
- Each agent's bridge comes from: the task's bridge pin, then its fleet row's bridge, then the chain's first directory, then your own bridge.

## 4. Share learnings across the chain
Agents see only their `TASK.md`. Use the channels the Hub carries forward:

| What | Where | Who sees it |
|---|---|---|
| Conventions every task must follow ("use `pytest -q`", "never touch `legacy/`") | `task-chain summary set` (≤ 60 lines) | every agent, every attempt |
| What a task produced, decided, ruled out | worker's `lease submit` `--summary`, `--decision`, `--dead-end`, `--output-file` | dependents (full), every task (summary line 1 + dead ends in the chain summary) |
| Extra context for one task | `brief.inputs` | that task |
| Lessons that outlive the chain (build quirks, project rules) | `ham-ctl memory propose` (project scope) | future chains |

The Hub keeps a mechanical chain summary (done tasks with their commit, open tasks, every dead end) and appends your curated notes. Keep yours short and current; compact it when you get `summary_overflow`.
```bash
./.heimdall/bin/ham-ctl task-chain summary set --stdin <<'EOF'
Conventions: tests with `pytest -q`; never edit legacy/.
Decided: token hashes are sha256 (t_api).
EOF
```

## 5. React to `[taskv2]` notifications
Routine events stay quiet. You get one line, `[taskv2] <trigger>: …`, only when something needs you:

| Trigger | Do this |
|---|---|
| `proposal_decided` (approved / rejected) | approved: tasks are dispatching, keep the user posted. Rejected: read the reason, revise, propose again |
| `blocked_on human` | a worker ran `lease block --waiting-on user`. Read the question (`task show <id>`), ask the user with `chat send --options …`. Their answer (given in the task's UI) re-readies the task and appears in the worker's `TASK.md` |
| `budget_exhausted` | read the attempts (`task fetch <id> facet:<id>:<n>:handoff` and `…:verify`), then sharpen or split the brief (`task update`) or `workflow retry` |
| `oscillation` | review rounds keep bouncing: read the open findings (`task show`) and the handoff, make `acceptance` unambiguous |
| `ready_unclaimed` | no eligible worker: check `task-chain fleet list` and `bridge list`, fix capacity, roles or bridge |
| `review_requested_from_user` | summarise the evidence for the user (`chat send --options "Approve,Request changes"`), then record their verdict (§6) |
| `merge_conflict` / `merge_failed` | a done task's branch did not merge; the task returns to its worker with a Merge Conflict section. For `merge_failed` (merge never ran, e.g. bridge offline) check the bridge |
| `gate_rejected` | a workflow gate was rejected `max_replans` times: talk to the user, then `workflow retry <stage>` |
| `summary_overflow` | compact the chain summary (`task-chain summary set`) |
| `chain_complete` | write the final summary, `task-chain set-status --status completed`, send the user the deliverables |

## 6. Recording the user's verdict
- Workflow gates with approver `user_or_coordinator`: your own `review post --verdict approve|request_changes` decides.
- Tasks with `requires_user_approval` and gates with approver `user`: when the user decides in chat, record it for them:
  ```bash
  ./.heimdall/bin/ham-ctl review post <task-id> --verdict approve --on-behalf-of user
  ./.heimdall/bin/ham-ctl review post <task-id> --verdict request_changes --on-behalf-of user \
    --summary "<the user's reason>"
  ```
  The user can also approve directly from their attention deck.

## 7. Closing and out-of-scope defects
- Close: `task-chain set-status --status completed` once every task is `done` or `cancelled`.
- Unrelated bugs: search `issue list --query …`, vote `issue vote <id>`, or file `issue create --title … --description …`.

## 8. Solo mode
The chain is solo when you are the Soloist or hold a worker fleet row yourself. Then:
- You pull work with `lease next` (nothing is pushed), work it per `worker-task-management`, and `lease submit`. Lapsed leases are not counted as attempts.
- New tasks default to `requires_user_approval`; the user reviews from their attention deck. To opt a task out: `task update <id> --no-require-user-approval`.
- You never review your own work (`403 solo_self_review`).
- `[taskv2] solo: task … is ready for you` means pull it with `lease next`.
- Urgent request mid-task: create the task, then `lease switch <task_id> --summary "<where you left off>"`.
