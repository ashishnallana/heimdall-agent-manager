---
name: worker-task-management
description: How a WORKER (or reviewer) agent uses ham-ctl to execute assigned tasks, report progress, hand off for review, and vote — covering the full task lifecycle and status vocabulary, the in_progress→in_validation handoff, implicit LGTM-quorum completion, and the QUICK vs COMPREHENSIVE reviewer checklists with risk-based tier selection. Load whenever you are a non-coordinator (worker or reviewer) member of a chain and need to run, hand off, or review a task.
---

# Worker task management (execute your assigned tasks)

You are a worker on this chain. Do the tasks ASSIGNED to you and report progress. Do not coordinate the whole chain or take on unassigned work — route that to the coordinator.

All commands use the managed wrapper: `./.heimdall/bin/ham-ctl`. For exact flags of any command, load the `ham-ctl-reference` skill.

## 0. Before you start (non-negotiable: don't assume, share your plan, escalate)
- DO NOT ASSUME OR INVENT anything not stated in the task. If any required detail is missing, ambiguous, or contradictory (paths, acceptance criteria, commands, expected behavior), STOP and ask the coordinator BEFORE doing the work — never guess, never silently expand scope. Ask by posting a task comment stating exactly what is unclear; if urgent, message the coordinator (the "Coordinator:" id in your bootstrap header) with `./.heimdall/bin/ham-ctl chat send --to <coordinator-instance-id> --body "..."`.
- SHARE YOUR PLAN first: before substantial work, post a brief numbered plan as a task comment (what you will change, which files, how you will verify) so the coordinator can course-correct early. As a reviewer, post your review tier and what you will check before you dig in.
- Work WITH the coordinator: route blockers, questions, and scope changes to the coordinator rather than deciding unilaterally; proceed once you have what you need.

## 1. Find your work
- `./.heimdall/bin/ham-ctl task list [--chain <id>]` — list tasks; focus on those assigned to you and currently actionable (your current task is assigned by the hub).
- Read the task description and the chain description for the REQ-IDs and acceptance criteria your task must satisfy.
- To catch up on discussion efficiently, `task list`/`task show` return a compact `comment_summary` (count, last_comment_at, author, preview), NOT full bodies. When the summary shows new activity, read only the recent bodies: `./.heimdall/bin/ham-ctl task comments <task-id> --last N` (newest N, max 100). Prefer a small N.

## 2. Do the work with visible progress
- Comment at every meaningful step, on blockers, and before handoff: `./.heimdall/bin/ham-ctl task comment <task-id> --body "<what you did, what changed, what is next>"`.
- Do not do substantial work that has no task. If one is missing, ask the coordinator to create it (do not silently expand scope).

## 3. Hand off for review
- When done, post a summary comment of what to review and the evidence (tests run + output, build result, files/paths, ids).
- Task System v2: `task status` (and the `in_progress`/`in_validation` transitions it drove) was removed. Tasks now carry a hub-driven `state` (`backlog`, `ready`, `in_progress`, `in_review`, `done`, `cancelled`); the `lease.*` verbs that submit/hand off/block a task arrive with the next milestone. Until then, hand off via your summary comment.
- You never "mark it done" yourself: completion happens on the reviewer quorum, which also unblocks dependent tasks. If review requests changes, address the feedback, comment what you changed, and re-submit.

### Pre-completion wrap-up checklist
Before any handoff, workers must complete the mandatory wrap-up checklist:
1. Wrap up code changes and verify tests.
2. Commit and push changes if needed.
3. Post a handoff/wrap-up comment (`ham-ctl task comment <task_id> --body "..."`) capturing work summary, stash state, and context.
4. Clean up task descriptions and scratch files.

## 4. Reviewing (when you are a reviewer)
You cannot review a task assigned to you. Task System v2: `task vote` was removed; the `review.post` verb that replaces it arrives with the next milestone. Until then record your verdict (`lgtm`/`ngtm`) and feedback as a task comment. A satisfied LGTM quorum (no `ngtm`) auto-completes the task and unblocks its dependents, so review promptly — a stalled review blocks the chain.

**In BOTH tiers: verify against ACTUAL behavior (run the command / read the source / build+test) — never from the assignee's summary alone. An `lgtm` MUST cite the evidence you checked; an `ngtm` MUST list concrete, actionable fix steps.**

### Which tier? (selection guidance)
The coordinator states the required tier in the task (Dependencies & handoff). If it's missing, choose by risk:
- QUICK — docs / comments / cosmetic / text-only changes with no runtime-behavior impact.
- COMPREHENSIVE — code that changes runtime behavior, schemas, generated output, security, or public interfaces.
- When in doubt → COMPREHENSIVE.

### QUICK review checklist (low-risk / cosmetic / doc-only) — time-boxed
1. Read the task's acceptance-criteria checklist and the assignee's handoff comment.
2. Read the actual diff/changed files.
3. Confirm EACH acceptance-criteria item is met (tick them off one by one).
4. Run the ONE key verification command the task names; confirm it succeeds.
5. Confirm build/tests the task cites are green (from the assignee's cited output, and spot-run if quick).
6. Confirm the handoff cited real evidence (not just "done").
7. Verdict: `lgtm` with "verified: <what you checked>", or `ngtm` with the exact fixes.

### COMPREHENSIVE review checklist (behavioral / higher-risk)
1. Read the task's REQ-IDs, acceptance criteria, and handoff comment.
2. Independently REBUILD from the checkout (don't trust the assignee's build): run the task's build command yourself.
3. Run the full or closely-related test suite; confirm green yourself.
4. Cross-check the change against the source of truth and CITE it (`file:line`) — re-derive every load-bearing claim.
5. Adversarial checks: edge cases, regressions, and any contradictions or duplication the change introduces.
6. If the change has generated/codegen artifacts, confirm they were regenerated and MATCH the source (re-run the generator; diff).
7. Give evidence PER acceptance-criterion (map each criterion → the command output or file:line that proves it).
8. Classify findings as blocking vs non-blocking.
9. Verdict: `lgtm` only if every criterion is proven with cited evidence; otherwise `ngtm` listing concrete, actionable steps.

Route disagreements you can't resolve to the coordinator; don't take over the implementation.

## 5. Communication
- Route questions, blockers, and user-facing messages through the coordinator (`chat send --to <coordinator-agent-instance-id>`).
- See the `heimdall-ctl-communication` skill for messaging syntax, chat conventions, and separating technical logs (task comments) from user communication (`chat send --to user`).
- `task nudge` was removed in Task System v2; to request attention on a stalled task, comment on it or message the coordinator.

Keep your task comments current at all times so the chain reflects real progress.
