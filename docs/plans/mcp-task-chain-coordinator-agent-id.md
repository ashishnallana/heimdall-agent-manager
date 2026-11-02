# Required coordinator agent ID for MCP task-chain creation

Status: proposed; implementation requires explicit user approval of planning task
`task_18e43a5ae97fa917`.

## Goal and scope

Require callers creating task chains through MCP to supply an explicit durable
coordinator agent ID. A durable `agent_id` (`agt_...`) identifies the selected
coordinator; a runtime `agent_instance_id` (`inst_...`) is not a substitute.

This task changes documentation only. After approval, the implementation task
will identify and report the exact source and test paths in the
heimdall-agent-manager checkout. The implementation must occur in its assigned
worktree, not by modifying the shared checkout.

## Implementation sequence

1. Trace MCP tool registration, the task-chain creation input schema, decoded
   request handling, and the existing coordinator resolution and ownership checks.
   Record the current field name, caller authorization context, any implicit
   fallback, and the shared call paths used by non-MCP clients. Identify exact
   source and test paths at that point; this plan does not claim those have
   already been inspected.
2. Mark the coordinator agent ID field as required in the MCP creation input
   schema, retain its string type, and describe the durable identity requirement.
   Update relevant tool descriptions/examples so callers know to select an
   accessible durable agent before requesting chain creation.
3. Enforce the same requirement at runtime, including when schema validation is
   bypassed. Reject omitted, empty, whitespace-only, wrong-type, malformed,
   instance-ID, nonexistent, and inaccessible IDs before creating durable chain
   state or launching a coordinator. Use existing ID and authorization helpers
   rather than introducing a second ownership policy.
4. Resolve the explicitly supplied durable agent using the existing coordinator
   resolution path and the authenticated MCP caller's access boundary. Do not
   silently replace invalid input with a default, current instance, newly created
   agent, or another user's identity. Preserve existing instance selection/launch
   semantics after valid durable identity resolution; this requirement does not
   introduce an online-instance prerequisite.
5. Keep the stricter required-field rule at the MCP boundary where possible.
   Preserve existing non-MCP creation defaults and behavior. If shared validation
   must change, document the precise reason, affected callers, and compatibility
   impact before broadening the implementation; seek a task amendment when the
   change exceeds this approved scope.
6. Add focused regression coverage, run affected tests and a relevant Hub build,
   and submit the implementation for review with exact commands, outcomes,
   changed paths, and any remaining limitations.

## Errors and atomicity

Use the existing MCP error envelope and error-code conventions. Missing/empty
values should name the required coordinator field and explain that it needs a
durable agent ID. Malformed values and instance IDs should explain the accepted
identity type. A nonexistent or inaccessible ID should instruct the caller to
choose an accessible agent without revealing another owner's agent details.
Reuse established not-found/forbidden disclosure behavior.

Failure must leave no new chain, coordinator binding, or coordinator launch
side effect. Preserve existing transaction and post-commit side-effect rules.

## Regression matrix

| Case | Required result |
| --- | --- |
| MCP tool schema | Coordinator agent ID appears in the creation schema's required list and has string type plus durable-ID guidance. |
| Field omitted | Actionable runtime error, including direct handler invocation bypassing schema validation; no creation side effects. |
| Empty string or whitespace-only string | Required-field error; no creation side effects. |
| Wrong JSON type, malformed ID, or instance ID | Invalid-input error identifying the durable agent requirement; no creation side effects. |
| Well-formed but nonexistent durable ID | Existing safe lookup error; no creation side effects or fallback. |
| Another owner's inaccessible durable ID | Access denied through existing policy; no information leak, creation side effects, or identity substitution. |
| Valid accessible durable ID | Successful chain creation bound to exactly that durable coordinator, exercising existing resolution behavior. |
| Valid ID with no running instance | Existing coordinator launch/resolution semantics preserved; durable identity is not confused with liveness. |
| Existing non-MCP creation cases | Existing default/explicit coordinator behavior remains unchanged, including successful creation. |

Choose fixtures using repository ID helpers and ownership conventions.
Include both contract/schema assertions and runtime tests so schema-only
enforcement cannot mask a missing handler check. For failures, inspect persisted
state and the existing launch-dispatch test seam where available.

## Verification and handoff

For this planning task, review the document against all three acceptance items,
run `git diff --check`, and verify that only this plan is changed. No compile or
runtime tests are needed for a documentation-only plan.

For the approved implementation, use the repository's Nix Odin toolchain, pass
`-collection:odin_test=src`, and place uniquely named test binaries under
`$HOME/.cache/heimdall-tests`. Select exact focused test/build commands after
source-path discovery, and record their outcomes without claiming broader
coverage than was run.

## Approval gate and exclusions

Submit this planning task through its required user review gate. Do not begin
source edits, implementation test changes, or deployment before explicit user
approval of this task. A chat selection or silence is not an approval verdict.

No migration of existing chains, change to coordinator reassignment, new agent
creation workflow, UI redesign, deployment, or unrelated task-engine refactor is
included. The intended compatibility change is limited to MCP callers that
previously omitted a coordinator: they must now explicitly select an accessible
durable agent.
