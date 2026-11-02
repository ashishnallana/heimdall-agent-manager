---
name: memory-management-workflow
description: How an agent proposes and reads durable Heimdall memories with ham-ctl and picks the right scope. Covers the four scope dimensions (agent, project, bridge, template) plus global, the memory types (fact/habit/episode/expertise/skill), the propose→human-approve workflow (agents propose; approval is a human/operator action, not an agent verb), and the memory propose/list/show/content commands. Load when creating, scoping, or reviewing durable long-term agent knowledge.
---

# Heimdall Memory Management & Workflow Skill

Use Heimdall memory management for managing long-term agent knowledge, project scopes, habits, facts, and expertise.

All commands use the managed wrapper from your run directory: `./bin/ham-ctl`.

## Scope Selection Rules
Scope is set by FOUR id-list dimensions on `memory propose` — there is NO `--scope`
word-flag. Each dimension accepts singular/plural spellings and either repeated flags or
comma-separated values (e.g. `--project-ids proj_1,proj_2` == `--project proj_1 --project proj_2`):

- **Agent Scope** (`--agent-id`/`--agent-ids`/`--agent`/`--agents`): Knowledge specific to an agent definition across its instances. If you omit the agent dimension it defaults to the caller's own agent.
- **Project Scope** (`--project-id`/`--project-ids`/`--project`/`--projects`): Knowledge scoped to a specific project repository.
- **Bridge Scope** (`--bridge-id`/`--bridge-ids`/`--bridge`/`--bridges`): Host environment or infrastructure knowledge.
- **Template Scope** (`--template-id`/`--template-ids`/`--template`/`--templates`): Guidance for agents initialized from a specific template.
- **Global Scope**: Omit the scope flags entirely for system-wide knowledge applicable across all agents, projects, and bridges. An omitted dimension applies broadly (to all).
- **Ephemeral Instances**: Ephemeral instance memories bind durably to the instance's underlying agent_id (and project/bridge where applicable).

For the exact `memory` command syntax (and every other ham-ctl group), see the `ham-ctl-reference` skill.

## Memory Types
- `fact`: Static declarative truth or project configuration.
- `habit`: Behavioral pattern or operational preference.
- `episode`: Record of specific past event or task run outcome.
- `expertise`: Special knowledge, architectural insight, or deep domain rule.
- `skill`: Machine-actionable procedure or SKILL.md instruction set.
Template targeting is available through the `--template` scope flag; template is not a memory type.

## Propose-Review-Approve Workflow
- Agents propose new memories in `pending` status using `ham-ctl memory propose`.
- Approval is a HUMAN/operator action — there is no agent `ham-ctl memory approve` verb.
  A human reviews pending proposals in the Settings -> Memory UI, via `ham-ctl hub memories
  approve <id>` (hub/user token), or by accepting a Curator action card (a `memory.approve`
  operation). Approval flips the status to `active`; proposals can also be edited or rejected.
- As an agent you only propose and read (`propose`, `list`, `show`, `content`); you cannot
  approve your own or others' memories.
- System memories (`owner_user_id = 'system'`) are read-only.

## CLI Usage Examples (ham-ctl, agent mode)
- **Propose a memory** (project + agent scope):
  `./bin/ham-ctl memory propose --type fact --title "Build Rule" --body "Always run tests before committing." --project-ids <project-id> --agent-ids <agent-id>`
- **Propose a template-scoped memory**:
  `./bin/ham-ctl memory propose --type habit --title "Reviewer checklist" --body "..." --template-ids <template-id>`
- **List memories**:
  `./bin/ham-ctl memory list [--status active|pending] [--type <type>]`
- **Show memory details / read the body**:
  `./bin/ham-ctl memory show <memory-id>` · `./bin/ham-ctl memory content <memory-id>`
