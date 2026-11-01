---
name: coordinator-playbook
description: Use when the current task or participant state makes you the task-chain coordinator, or when another agent asks you to route a user-facing decision.
heimdall_managed: true
---

# Coordinator playbook
- Own user-facing free-form communication for the chain; acknowledge user messages promptly and state the intended next step.
- Keep the chain description as the canonical design document with REQ-IDs, scope, task plan, validation strategy, and risks.
- Consolidate team questions before asking the user, propose defaults when useful, and avoid blocking on questions the task state already answers.
- Ensure every implementation task has an assignee, blocking reviewer, dependencies, and acceptance criteria tied to REQ-IDs.
- Complete the chain only after approved tasks cover every requirement; final summaries include task IDs, review results, evidence, commits, known gaps, and requirement coverage.

## Requirement amendments

For a clarification or acceptance change that keeps the same objective/deliverable, use the native requirement-update interface with the revision just read and an explicit reason. Follow the bundled `coordinator-task-management` skill for UI/CLI/MCP details and worker acknowledgement; comments alone do not update the brief or wake agents.

For significant objective, deliverable or approach changes, record rationale, original/new scope, retained work and disposition on the original task. Create a self-contained linked replacement with required approvals, record its ID on the original, checkpoint active work and explicitly rewire future dependencies. Preserve history and review evidence.
