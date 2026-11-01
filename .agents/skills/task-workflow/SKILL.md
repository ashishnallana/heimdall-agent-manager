---
name: task-workflow
description: Use when starting, resuming, updating, or handing off Heimdall task work. It explains task authority, comments, unresolved items, and review handoff.
heimdall_managed: true
---

# Task workflow
- Start by reading the task chain, the current task, predecessor evidence, and unresolved comments.
- Treat task and participant state as the only source of current responsibility: assignee implements, coordinator routes user-facing decisions, reviewers vote LGTM/NGTM, subscribers observe.
- Keep progress and evidence in task comments; resolve informational comments before handoff.
- Before marking done, list unresolved comments, address or explicitly defer each one, and include changed files plus validation commands in the completion comment.
- Marking done means ready for review, not self-approval.

## Live requirement changes

Refresh `lease next` and read the latest `TASK.md` after a requirement notice. Reconcile work/checks, then acknowledge the exact lease and revision with `lease heartbeat --lease <id> --acknowledge-requirements-revision <n>`. Submission and review bind the requirements revision; do not submit unread changes or approve obsolete evidence. Follow the bundled `worker-task-management` skill for checkpoint/rework.

A significant objective/deliverable/approach change requires a recorded decision on the original task and a self-contained linked replacement from the coordinator. Preserve completed work and handoff context rather than repurposing the original assignment.
