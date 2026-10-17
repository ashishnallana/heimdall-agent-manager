---
name: coordinator-task-management
description: How a task-chain COORDINATOR uses ham-ctl in Task System v2 to triage (ticket vs workflow), propose chains (`task-chain propose`), run and manage workflow chains (`ham-ctl workflow templates|define|run|status|output|retry|cancel`), maintain the chain summary (`task-chain summary set`), configure fleet placement (`task-chain fleet set`), react to one-line attention notifications (`proposal_decided`, `blocked_on`, `budget_exhausted`, `oscillation`, `ready_unclaimed`, `review_requested_from_user`, `stage_failed`, `chain_complete`), post proxy user reviews (`review post --on-behalf-of user`), and complete the chain. Load whenever you are the coordinator of a chain.
---

# Coordinator task management (Task System v2 — delegate, do not do the work yourself)

You are the coordinator. Your job is to PLAN, TRIAGE, PROPOSE, and ORCHESTRATE. Substantial implementation, verification, and review are executed by leased WORKER and REVIEWER agents, not by you.

All commands use the managed wrapper from your run directory: `./.heimdall/bin/ham-ctl`. For exact flags of any command, load the `ham-ctl-reference` skill.

## 1. Triage: `ticket` vs `workflow` and `task-chain propose` / `ham-ctl workflow`
When the user requests work, first triage the shape of the chain:
- **`ticket`**: A single, self-contained unit of work with a clear brief (`goal`, `acceptance`, `verify`) and no multi-step dependency fan-out. A ticket brief can also specify `"on_output": {"start_workflow": "<workflow_name>", "inputs": {...}}` so completing the ticket automatically starts a workflow run in the same transaction.
- **`workflow`**: Either a declarative `workflow.v1` stage pipeline (`ham-ctl workflow run` or `task-chain propose` with `"kind": "workflow", "workflow": "<template_name>"`) with lazy stage materialisation, `parallel: N` or `for_each` expansion (`task_list.v1`, `findings.v1`), and human `gate` stages, or an explicit task DAG proposal.

### Running or proposing a declarative workflow (`workflow.v1`)
Inspect built-in (`explore_plan_build`, `fix_flaky_tests`, `security_audit`) and owner-defined templates, define custom workflows, or start a workflow run on a chain:
```bash
# List available workflow templates (built-in + owner-defined)
./.heimdall/bin/ham-ctl workflow templates

# Define a custom versioned workflow.v1 JSON definition
./.heimdall/bin/ham-ctl workflow define --file my_workflow.json

# Start a workflow run directly on a chain (snapshots workflow_snapshot_json and materialises root stages)
./.heimdall/bin/ham-ctl workflow run explore_plan_build \
  --chain <chain-id> \
  --input goal="Add rate limiting to API" \
  --input verify_cmd="make test"

# Or propose a workflow run for user approval (or immediate execution with --auto-approve)
cat > wf_proposal.json <<'EOF'
{
  "kind": "workflow",
  "workflow": "fix_flaky_tests",
  "rationale": "Reproduce, isolate per-failure fixes with for_each, and gate on regression suite.",
  "inputs": {
    "target": "src/auth",
    "test_cmd": "make test-auth"
  }
}
EOF
./.heimdall/bin/ham-ctl task-chain propose --file wf_proposal.json [--auto-approve]

# Inspect stage views, materialised stage instances, and orphaned_work
./.heimdall/bin/ham-ctl workflow status [<chain-id>]

# Read ordered output facets across all instances of a completed stage
./.heimdall/bin/ham-ctl workflow output [<chain-id>] <stage_key>

# Retry a failed/cancelled stage (pass --cascade when downstream stages are already materialised;
# unchanged .Done items in downstream for_each stages are carried forward automatically)
./.heimdall/bin/ham-ctl workflow retry [<chain-id>] <stage_key_or_task_id> [--cascade]

# Cancel a workflow chain and reclaim all live leases
./.heimdall/bin/ham-ctl workflow cancel [<chain-id>]
```
> **Note**: Once a chain is running a workflow (`kind == "workflow"`), its task graph is owned by the Hub stage materialiser — manual `task create`, `task update`, and `task depend` return `403 workflow_immutable`.

### Proposing an explicit task DAG with `task-chain propose`
```bash
cat > proposal.json <<'EOF'
{
  "kind": "ticket",
  "rationale": "Split backend fold/verbs from UI drawer so both verify independently.",
  "alternative": "Single monolithic task (rejected: mixes Odin and TypeScript verify gates).",
  "tasks": [
    {
      "id": "task_backend",
      "title": "Implement Hub fold and lease verbs",
      "assignee": "agt_worker_odin",
      "brief": {
        "goal": "Implement pure event fold and lease lifecycle endpoints.",
        "acceptance": [
          "odin test src/hub/service/taskv2 passes",
          "fold.odin has zero I/O imports"
        ],
        "verify": "odin test src/hub/service/taskv2 -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/tv2",
        "review_roles": ["reviewer"],
        "auto_submit": true,
        "require_independent_verify": true
      }
    },
    {
      "id": "task_ui",
      "title": "Wire FleetManagementDrawer placement controls",
      "assignee": "agt_worker_ui",
      "depends_on": ["task_backend"],
      "brief": {
        "goal": "Expose per-row roles and bridge placement in FleetManagementDrawer.",
        "acceptance": ["npm test passes", "npm run typecheck passes"],
        "verify": "npm test",
        "review_roles": ["reviewer"]
      }
    }
  ]
}
EOF

./.heimdall/bin/ham-ctl task-chain propose --file proposal.json
```
- Pass `--auto-approve` when the user has already pre-authorized immediate execution or for a straightforward `ticket` that does not require a separate plan sign-off.
- Otherwise, `task-chain propose` leaves the chain in `draft` with `proposal.status = "pending"` for user approval in the UI (or via `task-chain decide --decision approve|reject`).

## 2. Maintain the chain summary (`<= 60` lines)
The Hub maintains a mechanical chain summary on task transitions (preserving `dead_ends` across attempts) and injects it into every agent's `TASK.md` context pack (`pack.chain.summary`). Whenever key architectural decisions, scope updates, or cross-task invariants change, set a concise curated summary (`<= 60` lines):
```bash
./.heimdall/bin/ham-ctl task-chain summary set "Foundation tasks complete; UI integration in progress."
# Or multi-line via stdin (must be <= 60 lines):
./.heimdall/bin/ham-ctl task-chain summary set --stdin <<'EOF'
Goal: Ship Task System v2 M3
Done:
- [x] task_backend: pure fold + lease verbs verified
In flight:
- [ ] task_ui: FleetManagementDrawer placement editor
Dead ends to avoid:
- Do not write Odin test binaries to /tmp (SIGKILL on this host)
EOF
```

## 3. Fleet placement & capacity management (`task-chain fleet set`)
Assign tasks exclusively to durable agent identities (`agt_...`), never ephemeral instance IDs (`inst_...`). Configure fleet concurrency, warm pools, allowed roles (`worker`, `reviewer`), and bridge/model placement with `task-chain fleet set`:
```bash
# Inspect current fleet allocations
./.heimdall/bin/ham-ctl task-chain fleet list [<chain-id>]

# Configure worker + reviewer fleet placement
./.heimdall/bin/ham-ctl task-chain fleet set <chain-id> \
  --agent agt_worker_odin \
  --capacity 3 \
  --min-warm 1 \
  --idle-ttl 300 \
  --roles worker,reviewer \
  --bridge brg_main \
  --provider claude \
  --model claude-opus-4-6
```

## 4. Writing self-contained task briefs (`task create` / `task update` / `task publish`)
Every executable task requires a complete `brief` before it or its chain can be published (`422 brief_incomplete` lists any missing fields per task):
```bash
./.heimdall/bin/ham-ctl task create \
  --title "Add commit-diff endpoint" \
  --assignee agt_worker_odin \
  --goal "Expose paginated commit-diff for chain directories." \
  --acceptance "GET /api/v1/task-chains/{cid}/directories/{did}/vcs/commit-diff returns <=200 hunks" \
  --acceptance "Unit tests pass" \
  --verify "odin test src/hub/service/taskchain -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/tc" \
  --input "output:task_foundation" \
  --review-role reviewer \
  --auto-submit \
  --require-independent-verify
```
- Publish individual draft tasks with `./.heimdall/bin/ham-ctl task publish <task-id>` or publish the whole chain with `./.heimdall/bin/ham-ctl task-chain publish [<chain-id>]`.

## 5. Reacting to coordinator one-line attention notifications
The Hub never spams the coordinator on routine `lease_granted`, `lease_heartbeat`, or `verify_finished` events. You receive a concise one-line `attention [<event>] ...` notification **only** on these actionable conditions:

1. **`proposal_decided`** (`decision=approve` or `decision=reject`):
   - On `approve`: tasks (or workflow root stages) are now published and dispatching; monitor progress and keep the user informed at milestones.
   - On `reject`: read the rejection reason, revise the task briefs/DAG, and submit an updated `task-chain propose` (or discuss with the user).
2. **`blocked_on`** (`waiting_on.kind == "human"`):
   - A worker called `lease block --waiting-on human`. Read the task's blocker reason (`ham-ctl task show <task-id>`), formulate a clear question for the user with `ham-ctl chat send --to user --body "..." --options "..."`, and once answered, update the task brief/comments and unblock or re-ready the task.
3. **`budget_exhausted`** (task reached `max_attempts`):
   - Inspect the attempt facets (`ham-ctl task fetch <task-id> facet:<task-id>:<attempt>:handoff` and `verify`), diagnose why attempts failed, and either refine the brief / split the task or retry the workflow stage via `ham-ctl workflow retry [<chain-id>] <stage_key>`.
4. **`oscillation`** (`review_round >= 3` bounce between worker and reviewer):
   - Read the reviewer's `findings` facet and the worker's `handoff` facet to resolve the ambiguity in `brief.acceptance` or `brief.goal` via `ham-ctl task update <task-id>`.
5. **`ready_unclaimed`** (task sat `ready` for `> 10m` with no eligible fleet):
   - Check `ham-ctl task-chain fleet list` and `ham-ctl bridge list`; adjust fleet `capacity`, `roles`, or `bridge_id` with `ham-ctl task-chain fleet set` so an eligible worker instance can claim the lease.
6. **`review_requested_from_user`** (`requires_user_approval` task or workflow `gate` stage entered `in_review`):
   - Present a concise summary and verification evidence to the user (`chat send --to user --options "Approve,Request changes"`). When the user responds in chat, record their verdict via coordinator proxy review (see §6).
7. **`stage_failed`** (a workflow stage had an instance cancel/fail or a gate rejected):
   - Inspect `ham-ctl workflow status [<chain-id>]`, address the failure or discuss with the user, and re-run the stage via `ham-ctl workflow retry [<chain-id>] <stage_key> [--cascade]`.
8. **`chain_complete`** (every task / workflow stage in the chain reached `done`):
   - Write the final chain summary (`ham-ctl task-chain summary set`), mark the chain completed (`ham-ctl task-chain set-status --status completed`), and send the final deliverable summary to the user (`ham-ctl chat send --to user`).

## 6. Coordinator proxy review (`--on-behalf-of user`)
When a task has `requires_user_approval: true` (or is a workflow `gate` stage with `approver != "user"`) and the user approves or requests changes in chat, record the verdict on the user's behalf:
```bash
./.heimdall/bin/ham-ctl review post <task-id> \
  --verdict approve \
  --on-behalf-of user
```
This records `actor_kind = "coordinator"` and `on_behalf_of = "user"` on the review event and satisfies the approval gate in the Hub (triggering downstream workflow stage materialisation in the same UoW when applicable).

## 7. Out-of-scope defects & issues (report, search, and vote)
When you encounter unrelated bugs or host toolchain issues:
- Search first: `./.heimdall/bin/ham-ctl issue list [--query "<text>"]`
- Vote on existing issues: `./.heimdall/bin/ham-ctl issue vote <issue-id>`
- File new issues: `./.heimdall/bin/ham-ctl issue create --title "<summary>" --description "<details>" [--scope <global|project|agent_id|bridge_id>] [--target-id <id>]`
