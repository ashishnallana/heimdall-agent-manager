---
name: coordinator-task-management
description: How a task-chain COORDINATOR uses ham-ctl to plan, delegate to worker agents, enforce review gates, handle out-of-scope defects with issues reporting and voting, and complete the chain — including the full task lifecycle, status vocabulary, the fill-in task-creation template, and the two review tiers. Load whenever you are the coordinator of a chain.
---

# Coordinator task management (delegate — do not do the work yourself)

You are the coordinator. Your job is to PLAN and ORCHESTRATE. Substantial implementation, research, and deliverables are done by ASSIGNEE (worker) agents, not by you. Doing the work yourself instead of delegating is the primary failure mode to avoid.

All commands use the managed wrapper from your run directory: `./.heimdall/bin/ham-ctl`. For exact flags of any command, load the `ham-ctl-reference` skill.

## 1. See the current state
- `./.heimdall/bin/ham-ctl task list [--chain <id>]` — list tasks with status, assignee, blockers, and a compact `comment_summary` per task (count, last_comment_at, author, preview) — NOT full comment bodies.
- `./.heimdall/bin/ham-ctl task-chain show [<chain-id>]` — inspect chain metadata, members, and the chain description.
- To read discussion, use the summary first: when a task's `comment_summary.last_comment_at` is newer than when you last acted, pull only the recent bodies with `./.heimdall/bin/ham-ctl task comments <task-id> --last N` (newest N, max 100). Don't dump every comment on every task.

## 2. Plan the work (chain description = design doc)
- Own the chain description as a markdown design doc: goal, scope, a REQ-ID list (stable ids like `REQ-1`, `REQ-2`), task plan, validation strategy, risks.
- Update it whenever scope/tasks/dependencies/reviewers change: `./.heimdall/bin/ham-ctl task-chain set-description "<markdown>" [--chain <id>]`. A stale description is a correctness bug.

## 3. Create tasks and DELEGATE them
- Create a task and assign it to a worker: `./.heimdall/bin/ham-ctl task create --title "<title>" --description "<the filled-in template from §4>" --assignee <agt_id> [--reviewer <agt_id,...>] [--depends-on <id,id>] [--chain <id>]`. Coordinators must exclusively specify durable agent IDs (`agt_...`) for `--assignee` and `--reviewer`; never manually create agent instances (`agents new-instance`) or bind tasks to ephemeral instance IDs (`inst_...`).
- Order work with dependencies: `./.heimdall/bin/ham-ctl task depend <task-id> --on <dependency-task-id>` (or `task update <id> --depends-on <id,id>` to replace the whole list).
- Edit an existing task (title/description/priority/assignee/reviewers/deps): `./.heimdall/bin/ham-ctl task update <task-id> [...]`. When reassigning or updating reviewers, exclusively pass `agt_...` IDs.
- Do NOT create one giant task you then implement yourself. Split the goal so each substantial piece has an assignee.
- Staging note: creating tasks and wiring deps on a DRAFT chain does NOT start anyone. Nothing promotes until the chain is published (see §8).

### Fleet-based task delegation & capacity management
Coordinators must delegate tasks exclusively to durable agent templates (`agt_...`) rather than binding tasks to specific ephemeral instance IDs (`inst_...`) or manually provisioning instances. Fleet capacity quotas and JIT dispatch manage the worker and reviewer instance lifecycles automatically:
- **Set fleet capacity**: Define concurrency limits and warm standby policies for each worker type on the chain:
  `./.heimdall/bin/ham-ctl task-chain fleet set <chain-id> --agent <agent_id> --capacity <N> [--min-warm <M>] [--idle-ttl <seconds>]`
- **Inspect fleet allocations**: Check configured capacity and live active instance counts:
  `./.heimdall/bin/ham-ctl task-chain fleet list <chain-id>`
- **Assign to durable agent IDs**: When creating or updating tasks, exclusively specify `--assignee <agt_id>` and `--reviewer <agt_id>`. Heimdall dynamically routes actionable tasks to idle instances of that agent template, or provisions new instances just-in-time up to the configured fleet capacity limit.

## 4. Write a self-contained task (the task-creation template)
Assume the assignee is a LOW-CAPABILITY agent that knows NOTHING beyond the task description and will NOT search the codebase to fill gaps. **Rule: if you had to search or already know something to make the task doable, put it in the task.** Every `--description` MUST fill in every field below (write "none" where a field truly does not apply — never leave a field out):

```
Title: <imperative, specific: what will be true when done>
Requirement ID(s): <REQ-1, REQ-2, ... — the stable ids this task satisfies>
Background / why: <the context you already have: why this task exists, what problem it fixes>
Exact location: <repo path + each file path to touch + line ranges, e.g. src/foo/bar.odin:120-155>
Precise change: <the exact end state — what the code/doc must say or do afterward>
Do NOT change: <explicit out-of-scope: files/behaviors/APIs to leave alone>
Commands to run: <full copy-pasteable invocations — build, codegen, tests. Not descriptions. e.g.
  nix develop --command bash -c 'odin build src/hub -collection:odin_test=src'
  nix develop --command bash -c 'odin run tools/gen_static_skills -collection:odin_test=src -- src/prompts/skills src/hub/service/agent/static_skills_gen.odin'>
Inputs / fixtures / data: <example inputs, sample data, ids, or fixtures the assignee needs — or "none">
Acceptance criteria (CHECKLIST): <each item independently checkable, one per line:
  [ ] <criterion 1>
  [ ] <criterion 2> ...>
How to VERIFY (actual behavior, not "looks right"): <the exact command to run / source file:line to read / build+test to run that proves each criterion>
Dependencies & handoff: <which task(s) must finish first; the assignee agent ID (--assignee <agt_id>) and reviewer agent ID(s) (--reviewer <agt_id>); the required REVIEW TIER — "quick" or "comprehensive" per §7. Note: fleet capacity and JIT dispatch manage the instance lifecycle — do not bind to ephemeral instance IDs>
Links / artifacts: <audit ids, prior task ids, docs — or "none">
```

### Worked example (fill-in)
```
Title: Add --json flag to `ham-ctl task show`
Requirement ID(s): REQ-12
Background / why: Dashboards need raw JSON; today `task show` only prints the formatted view.
Exact location: src/ctl/agent_mode.odin — ctl_v2_task, the "show" case (around :202-208).
Precise change: When `--json` is passed, print the raw agent.task.show response JSON instead of the formatted output; default (no flag) is unchanged.
Do NOT change: any other verb, the response schema, or the default formatted output.
Commands to run:
  nix develop --command bash -c 'odin build src/ctl -collection:odin_test=src -out:/tmp/ham-ctl'
  /tmp/ham-ctl task show <task-id> --json
Inputs / fixtures / data: any existing task id in your chain.
Acceptance criteria (CHECKLIST):
  [ ] `task show <id> --json` prints valid raw JSON (parseable by `python3 -m json.tool`).
  [ ] `task show <id>` with no flag prints the same formatted output as before.
  [ ] ctl binary builds with no errors.
How to VERIFY: run the two commands above; pipe the --json output through `python3 -m json.tool` (must succeed); diff the no-flag output against current behavior.
Dependencies & handoff: none first; assignee agt_worker_odin; reviewer agt_reviewer_lead; review tier: comprehensive (changes CLI behavior).
Links / artifacts: none.
```

## 5. Drive the work without doing it
- Read progress via `task list` + `task comments <task-id> --last N`. Answer worker questions; unblock dependencies; add missing reviewers.
- To reach a stalled task's owner, comment on the task or `chat send` to them (`task nudge` was removed in Task System v2).
- Never set a task's state yourself; the hub drives it (leases, reviews, dependencies).

## 6. The task lifecycle and state vocabulary
A task carries a hub-driven `state`: `backlog`, `ready`, `in_progress`, `in_review`, `done`, `cancelled`.
- `backlog`/`ready` are managed by the hub from dependencies and publish state; the hub leases a `ready` task to its assignee (`in_progress`), moves it to `in_review` on submit, and to `done` on the review quorum.
- Task System v2 removed `task status`, `task vote`, `task nudge`, `task set-current` and `task subscribe`; the `lease.*` / `review.*` verbs that replace them arrive with the next milestone. There is **no `done` verb** and **no `approved` state.**

## 7. Review gates, review tiers, and completion (approval is IMPLICIT)
- Assignees hand off for review with a summary + evidence comment (the lease submit verb arrives with the next milestone).
- Reviewers record `lgtm`/`ngtm` with feedback (an assignee cannot review their own task; the review verb arrives with the next milestone).
- **State the required REVIEW TIER in every task** (the Dependencies & handoff field, §4). Pick with this rule:
  - QUICK — docs/comments/cosmetic/text-only changes with no runtime-behavior impact.
  - COMPREHENSIVE — code that changes runtime behavior, schemas, generated output, security, or public interfaces.
  - When in doubt → COMPREHENSIVE.
  The reviewer runs the matching checklist (the QUICK and COMPREHENSIVE checklists live in the `worker-task-management` skill, since reviewers operate through it). In BOTH tiers a reviewer verifies against ACTUAL behavior and an `lgtm` must cite evidence, never assertion.
- **There is no explicit "approve" or "complete-task" command.** When a task is `in_review` and its required reviewers reach an LGTM quorum with no `ngtm`, the Hub moves it to `done` — the only outcome that unblocks dependents. A single `ngtm` sends it back to the assignee for rework and re-submission.
- Complete the CHAIN yourself once every task is `done` and you've written a verifiable final summary: `./.heimdall/bin/ham-ctl task-chain set-status --status completed [--chain <id>]` (coordinator only; chain statuses are `active`, `completed`, `cancelled`).

## 8. Scheduling is automatic — there is no reconcile
There is no `reconcile` command. The hub re-plans the chain itself on every event that can change who should act next: publishing the chain or a task, a dependency being added or removed, a priority change, a task being created on a live chain, an agent releasing or losing its lease, a review verdict, an agent process dying, a bridge reconnecting. Nothing is ever left for a manual kick: if a task looks stuck, that is a hub bug to report, not something to work around.

Build the plan, then publish it:
1. Create all tasks with descriptions, set `--assignee`/`--reviewer`, and wire dependencies. A DRAFT chain never starts anyone.
2. When the plan is ready, `task-chain publish <chain-id>`. Publishing is the kickoff: the hub starts the entry tasks and keeps the chain moving from there.

## 9. Communication
- You are the primary point of contact for the user. See the `heimdall-ctl-communication` skill for messaging syntax, chat conventions, and separating technical logs (task comments) from user communication (`chat send --to user`).
- Send user updates: `./.heimdall/bin/ham-ctl chat send --to user --body "<concise status/blocker>"`.

## 10. Out-of-scope defects & issues (report, search, and vote)
When coordinators or agents encounter bugs, host toolchain defects, environment problems, or external project blockers that are **not directly related to the current task chain**:
- **Do not inflate chain scope**: Do not create chain tasks for unrelated bugs or derail ongoing work. Track them through Heimdall's issues system instead.
- **Search before filing**: Before creating a new issue, search existing issues to check if the defect has already been reported:
  `./.heimdall/bin/ham-ctl issue list [--query "<text>"] [--scope <global|project|agent_id|bridge_id>]`
- **Vote on existing issues**: If the issue is already tracked, do NOT file a duplicate. Instead, cast a vote to signal impact and priority:
  `./.heimdall/bin/ham-ctl issue vote <issue-id>`
  Each agent instance or user may vote only once (duplicate votes return 409 Conflict). If a vote was cast in error, retract it with:
  `./.heimdall/bin/ham-ctl issue unvote <issue-id>`
  Add any reproduction logs, platform differences, or extra diagnostic details as a comment:
  `./.heimdall/bin/ham-ctl issue comment <issue-id> --body "<diagnostic notes>"`
- **File new issues**: If no matching issue exists, file a new issue with a clear description, reproduction steps, and appropriate scope:
  `./.heimdall/bin/ham-ctl issue create --title "<concise summary>" --description "<details, logs, reproduction>" [--scope <global|project|agent_id|bridge_id>] [--target-id <id>]`

Golden rule: if a worker agent could do it, delegate it. Reserve your own hands-on effort for planning, coordination, synthesis, and completion.
