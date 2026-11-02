---
name: heimdall-ctl-communication
description: How an agent communicates through Heimdall with ham-ctl — signal readiness at startup (start-success), read your inbox and message history (chat read), send to the user or another agent (chat send --to), and keep user-facing chat separate from technical task comments. Load when communicating through Heimdall: replying to the user, coordinating agent-to-agent, or reacting to a new-message notification.
---

# Heimdall CLI communication

Use the managed Heimdall CLI wrapper from your agent run directory for all Heimdall communication: `./bin/ham-ctl`.

Messages from the user arrive through Heimdall, NOT your terminal. Text printed to stdout/stderr is NOT delivered to the user. You MUST use `ham-ctl` to read incoming messages and to send responses.

## 1. Startup signaling
- Once your agent instance is initialized, dependencies are confirmed, and you are fully ready to work, signal startup readiness:
  `./bin/ham-ctl start-success`

## 2. Reading messages & inbox
- Read unread inbound messages:
  `./bin/ham-ctl chat read`
- Read full history or transcript:
  `./bin/ham-ctl chat read --transcript [--limit N] [--since <timestamp>]`
- Include previously read messages:
  `./bin/ham-ctl chat read --include-read [--limit N]`

## 3. Sending messages
- **To the user**:
  `./bin/ham-ctl chat send --to user --body "<your message>"`
  - ALWAYS communicate status, answers, and completion to the user via this command.
  - Keep replies concise, concrete, and actionable: state what you did/found, exact results (commands run, files/paths, commit hashes), blockers, and next steps. Avoid dumping large raw logs inline.
- **To another agent instance (agent-to-agent)**:
  `./bin/ham-ctl chat send --to <agent-instance-id> --body "<message>"`
  - Use exact instance IDs (e.g. `inst_...`), not display names or slugs.

### Asking questions
- For a set of questions, send one grouped message:
  ```bash
  ./bin/ham-ctl chat send --to user --body "Choose the release settings." --questions-file questions.json
  ```
  The file is a UTF-8 JSON object with `version: 1` and a `questions` array. Each question has `id`, `text`, `options` (objects with `id` and `label`), and optional `selection_mode` (`single` by default, or `multiple`). See `ham-ctl-reference` for a complete example, validation limits, and the delivered `multi_question_answer` contract.
- Each question accepts selections or a typed custom answer instead. Selecting an option does not send a message; the user answers every question and explicitly submits the group.
- For one simple choice, use `--options "Option A,Option B"` or repeated `--option`. Do not combine flat options with `--questions-file`; grouped messages are user-only.
- Flat options and grouped-question controls work only while their message is the **LAST durable user-visible message** in that agent conversation. Any newer user or agent message expires them (agent-to-agent rows do not count). Keep related questions together and avoid follow-up messages while waiting for answers.
- Use the existing task review UI for task approval, or record the user's explicit verdict via `review post --on-behalf-of user`. Task approval does not require action cards. Never treat answer selection or silence as approval.

## 4. Separation of concerns: Chat vs Task Comments
- **Task Comments** (`ham-ctl task comment <task-id> --body "..."`):
  - Use for technical progress tracking, step-by-step audit trails, test run outputs, code diff summaries, and review handoffs.
  - Permanent, auditable engineering logs attached directly to tasks in the chain.
- **Chat Send** (`ham-ctl chat send --to user|agent-instance-id --body "..."`):
  - Use for direct conversation with the user (answering questions, confirming intent, reporting milestones, acknowledging requests).
  - Use for peer agent coordination and routing questions/blockers to the coordinator.