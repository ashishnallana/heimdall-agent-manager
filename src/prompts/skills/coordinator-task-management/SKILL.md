---
name: coordinator-task-management
description: How a task-chain COORDINATOR runs a Task System v2 chain with ham-ctl — choose tickets or workflow runs within one mixed-work chain, propose and publish tasks with complete briefs (`task-chain propose|decide|publish`, `task create`), run workflows (`ham-ctl workflow …`), set up the fleet and review roles (`task-chain fleet set`), curate the chain summary so learnings reach every agent, react to `[taskv2]` notifications (blocked_on human, budget_exhausted, oscillation, ready_unclaimed, review_requested_from_user, merge_conflict, gate_rejected, work_batch_finished, workflow_complete, …), record user verdicts (`review post --on-behalf-of user`), and close the chain. Covers Solo mode, where the coordinator also does the work. Load whenever you coordinate a chain.
---

# Coordinator task management (Task System v2)

You plan, triage, publish and steer. Leased **workers** and **reviewers** do the work, unless the chain runs in **Solo mode** (§8), where you are also the worker and the user reviews.

The Hub owns task state: leases make tasks `in_progress`, submits make them `in_review`, passing reviews make them `done`. There is no status verb for tasks. Commands use `./.heimdall/bin/ham-ctl`; exact flags are in `ham-ctl-reference` or `ham-ctl <group> --help`.

## 1. Choose the next work item, not a chain type
Every task chain is `mixed_work`. You remain coordinator of the same chain, team,
and directories throughout. Add ordinary tickets when their briefs are known;
add workflow runs for recurring recipes or discovery followed by fan-out. Reassess
this choice as work evolves. Neither choice creates a second chain.

Ordinary tickets remain editable. Workflow-generated stage tasks are engine-managed;
inspect their run and use whole-run retry/cancel rather than editing stage identities.
Configure shared fleet roles before starting a recipe; runs never widen the fleet.

```bash
./.heimdall/bin/ham-ctl workflow templates
./.heimdall/bin/ham-ctl workflow run fix_flaky_tests --chain <chain-id> --request-id <stable-key> \
  --input suite=src/auth --input test_command="make test-auth" --input verify_cmd="make test" \
  --after task:<investigation-id>
./.heimdall/bin/ham-ctl workflow list --chain <chain-id>
./.heimdall/bin/ham-ctl workflow status <run-id>
./.heimdall/bin/ham-ctl workflow output <run-id> <stage-key> [--execution <n>]
./.heimdall/bin/ham-ctl workflow history <run-id>
./.heimdall/bin/ham-ctl workflow retry <run-id> --expected-revision <revision> --reason "<why>"
./.heimdall/bin/ham-ctl workflow cancel <run-id> --execution <number> --reason "<why>"
./.heimdall/bin/ham-ctl task-chain depend --chain <chain-id> --item task:<validation-id> --on workflow_run:<run-id>
```

To fan out over a list you already know, define a stage with
`"for_each": "inputs.<array-input>"` and pass the list with `--inputs-file`; no
echo stage is needed. An empty list completes that stage with zero tasks. See
ham-ctl-reference "Authoring workflow definitions" for item placeholders.

Creation request keys are caller-selected and reused on network retries. A key
with different inputs fails. Retry creates a new execution with fresh tasks and
preserves all old attempts. Stage/cascade retry is unsupported. If outputs have
already been consumed, retry/reopen is refused with consumer references; create
replacement work and explicitly change the future dependency graph instead.

Use `task-chain graph [<chain-id>]` to inspect dependencies, scope history, and
`work_revision`. Dependencies can join any ticket or whole run in this same chain.
For a ticket waiting on a run, `task depend <task-id> --on workflow_run:<run-id>`
is the same graph edge; `--depends-on` on `task create`/`update` takes ticket ids only.
Cancelled, failed, or excluded items do not satisfy prerequisites. Remove an edge
explicitly with `task-chain remove-dependency --dependency <id> --reason "<why>"`.
The graph verbs default to your chain; only you (the coordinator) or the owner may change it.

A new proposal can add work to an active chain mid-work. Its `kind` is `task` or
`workflow_run`, describing the proposed item, never changing the chain type.
Decide a pending proposal before proposing another.

## 2. Propose, approve, publish
```bash
cat > proposal.json <<'EOF'
{
  "kind": "task",
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
- Without `--auto-approve` the proposal waits for an explicit decision. Existing work continues.
- Single tasks: `task create --title … --goal … --acceptance … (repeat) --verify … [--assignee agt_…] [--reviewer agt_…] [--review-role <role>] [--require-user-approval] [--input <ref>] [--depends-on <ids>] [--auto-submit] [--require-independent-verify]`, then `task publish <task-id>` or `task-chain publish <chain-id>`.
- Publish refuses incomplete briefs with `422 brief_incomplete` listing what is missing per task, including `review_role:<r>` when no fleet row holds a role the brief asks for.

**A good brief** is self-contained: a goal a newcomer can act on, checkable acceptance items, an optional verify command that exits non-zero on failure. Add `inputs` (`output:<task>`, `<path>@<rev>`) only for context beyond what dependencies already bring: a task automatically receives the handoff of every task it waits for.

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
| `agent_not_running` | A ready task cannot obtain a running agent, or a leased holder exited/lost its heartbeat. `task show <id>` shows `blocked_on.kind=agent_not_running` (legacy `dispatch` is equivalent), with agent/provider/model/bridge/error. The user can choose **Start agent** in the attention deck or chat tray; a failed start stays blocked and shows its error inline for retry. Fix the cause, then use the card or `task unblock <id> [--note <reason>]`; editing the affected fleet row also clears the block. No work attempt budget is spent. Full fleet rows remain queued without blocking |
| `review_requested_from_user` | summarise the evidence for the user (`chat send --options "Approve,Request changes"`), then record their verdict (§6) |
| `merge_conflict` / `merge_failed` | a done task's branch did not merge; the task returns to its worker with a Merge Conflict section. For `merge_failed` (merge never ran, e.g. bridge offline) check the bridge |
| `gate_rejected` | a workflow gate was rejected: inspect the feedback, talk to the user, and retry the whole run if appropriate |
| `summary_overflow` | compact the chain summary (`task-chain summary set`) |
| `work_batch_finished` / `workflow_complete` | assess the goal; add more work or explicitly complete the chain |

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
- Completion is explicit. Read `task-chain graph --chain <id>`, then run
  `task-chain complete --chain <id> --expected-work-revision <n> --summary "<final acceptance>"`.
  Every included ticket must be published and done; every included run must have
  succeeded; no live leases or pending proposal may remain. At least one success
  is required. A changed revision requires a fresh inspection, not a blind retry.
- Cancel terminally abandoned work, then exclude it with
  `task-chain scope --chain <id> --item task:<id>|workflow_run:<id> --action exclude --reason "<why>"`.
  Exclusion is auditable and never makes a failed prerequisite successful.
- Unrelated bugs: search `issue list --query …`, vote `issue vote <id>`, or file `issue create --title … --description …`.

## 8. Solo mode
The chain is solo when you are the Soloist or hold a worker fleet row yourself. Then:
- You pull work with `lease next` (nothing is pushed), work it per `worker-task-management`, and `lease submit`. Lapsed leases are not counted as attempts.
- New tasks default to `requires_user_approval`; the user reviews from their attention deck. To opt a task out: `task update <id> --no-require-user-approval`.
- You never review your own work (`403 solo_self_review`).
- `[taskv2] solo: task … is ready for you` means pull it with `lease next`.
- Urgent request mid-task: create the task, then `lease switch <task_id> --summary "<where you left off>"`.

Task verification commands are optional: omit `brief.verify` (or use an empty value or `"none"`) when no command applies. Publishing and submission do not require a verify result or an output contract in that case. If a command is configured, run it before submitting, or explicitly use `lease submit --skip-verify --skip-verify-reason "<why>"` with a non-empty written reason. The skip is recorded on the attempt and shown as a warning to reviewers. Tasks with `require_independent_verify: true` cannot skip. `--verify none` alone does not bypass a configured command. The coordinator/owner can correct `verify` or `acceptance` on a leased task using a brief containing only those fields; other brief fields are preserved, and the next verify invocation uses the new command. `ham-ctl verify` reports success with nothing to run when no command is configured.
