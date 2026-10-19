# Mixed work inside a task chain

Implementation plan and infrastructure handoff, 2026-10-19.

Current scope: backend, persistence, REST/agent actions, Bridge, CLI and bootstrap/context. UI implementation is explicitly deferred by the user. Independent review, automated tests, migration execution and manual testing have not been performed for the final cutover. Earlier foundation pass counts below describe an older implementation state only.

## Product decision

A task chain is the permanent container for a goal, coordinator, conversation, fleet, directories, summary, and final acceptance. It contains ordinary tickets and any number of workflow runs. Choosing a workflow changes how one portion of work executes; it never changes the chain's execution type or creates another top-level UI entry.

Example: one authentication improvement chain contains a requirements ticket, a security-audit run, remediation tickets, and a regression-verification run. The same coordinator adds each as the need emerges. Starting a workflow never transfers coordinator ownership.

No backward compatibility is required. Replace the ticket/workflow distinction and old command contracts together; do not preserve separate ticket/workflow execution types, child workflow chains, adapters, or legacy aliases. The user subsequently required ALL chains to use the one `mixed_work` model, including chains created for coordinator conversations.

## Requirements

| ID | Requirement |
| --- | --- |
| REQ-MW-1 | One chain and coordinator persist across ordinary tickets and multiple concurrent or sequential workflow runs. |
| REQ-MW-2 | Coordinator can add either work form to an active published chain, with complete validation and atomic activation. |
| REQ-MW-3 | Workflow tasks, stage identity, outputs, concurrency limits and retries are isolated by run and execution generation. |
| REQ-MW-4 | Typed same-chain dependencies support ticket â†’ run, run â†’ ticket, run â†’ run and ticket â†’ ticket; only successful prerequisites unblock work. |
| REQ-MW-5 | Retry/cancel cannot admit stale results, silently invalidate completed consumers or affect unrelated work. |
| REQ-MW-6 | Chain remains open when current work finishes and closes only through explicit final acceptance. |
| REQ-MW-7 | Hub, persistence, REST/RPC, bridge, CLI, context/bootstrap and UI implement the same contract. |
| REQ-MW-8 | One UI entry exposes mixed work, scoped actions, dependencies, failures and historical executions. |
| REQ-MW-9 | Restart, duplicate requests, authorization and race handling preserve the model. |

## Evidence from current code

These are current constraints to remove, not assumptions based on the older root architecture guide:

- `src/hub/domain/taskchain.odin`: `Task_Chain.kind` selects ticket/workflow; workflow definition reference and snapshot live on the chain. `Task` has stage key/index but no run identity. Cancellation currently satisfies task dependencies.
- `src/hub/repository/sqlite/migrations/090_task_v2.sql`: stage identity is unique on `(chain_id, stage_key, stage_index)`; chain snapshot has an immutability trigger.
- `src/hub/service/taskv2/workflow.odin`: workflow activation rejects already published chains; stage fold/materialization/output/retry operate on a chain. Empty-stage completion is currently written into snapshot-related state. Output triggers spawn another chain. Retry can remove dependency edges and park tasks by changing stage keys.
- `src/hub/service/taskchain/taskchain_service.odin`: `require_not_workflow_chain` prohibits manual mutations for the entire chain. `reconcile_chain_status` automatically completes chains when current tasks finish.
- `src/hub/service/taskv2/service.odin`, `matcher.odin`, `pack.odin`: reconciliation, stage concurrency and worker packs infer workflow membership from chain/stage context.
- `src/hub/service/taskv2/verbs_m2.odin`: propose/decide activates an entire chain as a workflow.
- `src/ui/components/taskchain/TaskChainOverview.tsx`: `chain.kind` selects either the board or `WorkflowPipelineView`.
- `src/ctl/taskv2_cmds.odin`, `src/ui/api/endpoints/tasks.ts`: workflow operations identify a chain rather than a run.
- `src/prompts/skills/coordinator-task-management/SKILL.md`: triage asks the coordinator to choose a chain type; commands and mutation restrictions reflect that model.

## Durable contract

Keep existing task event/attempt/review/lease machinery. Introduce run records, not a second worker engine and not a generic execution framework.

### Chain and task changes

- All task chains have the one `kind: mixed_work`, including conversation-created chains. Remove workflow definition/snapshot fields from `Task_Chain`. Tickets versus workflow runs is an item choice rather than a chain type. This supersedes the original separate-purpose proposal at the user's explicit request.
- Add chain `work_revision` (monotonic integer) and `completion_summary`. Any work membership/dependency mutation and any task/run lifecycle change increments the revision. Completion must supply an expected revision.
- Add nullable task `workflow_run_id` and `workflow_execution_no`. Both are absent for an ordinary ticket, both present for a generated task. Stage key/index are immutable generated identity, not scratch storage for cancelled or carried items.
- Change the unique generated identity to `(workflow_run_id, workflow_execution_no, stage_key, stage_index)` with a partial index for generated tasks. Add composite ownership/chain foreign-key checks. Gate tasks must belong to runs and remain human-resolved.

### New records

| Record | Fields / constraints |
| --- | --- |
| `Workflow_Run` | `run_id`, `chain_id`, `owner_user_id`, `title`, immutable resolved `definition_id/version/spec_json/inputs_json`, `current_execution_no`, `created_by_kind/id`, optional source task/attempt/trigger key, `created_at`, `updated_at`, `revision`. |
| `Workflow_Run_Execution` | `(run_id, execution_no)` primary key; `state: draft | pending | running | succeeded | failed | cancelled`, resolved input snapshot, timestamps, failure code/detail, output manifest. Old executions never become current again. |
| `Workflow_Stage_Execution` | `(run_id, execution_no, stage_key)`; expansion status and item count, including durable successful zero-item expansion. Stage progress otherwise folds from that execution's tasks. No mutable markers inside definition JSON. |
| `Workflow_Run_Event` | Append-only event id, chain/run/execution ids, owner, actor, timestamp, kind, payload; created, activated, started, stage-expanded, succeeded, failed, retried, cancelled. Events and cached projections update together. |
| `Work_Dependency` | chain/owner, dependent kind/id and prerequisite kind/id, each kind `task | workflow_run`; unique edge; endpoints must be an ordinary ticket or run in that chain. No external edge may address a generated task. |
| `Work_Input_Receipt` | At consumer start: dependent identity/execution or task attempt, prerequisite identity, consumed task attempt or run execution, and output manifest reference. Receipts preserve provenance after edges change. |
| `Work_Scope_Decision` | chain/owner, item kind/id, action `exclude | include`, actor, required reason, timestamp. Latest decision controls final acceptance inclusion; exclusion never marks a dependency successful. |

Persist run creation idempotency on `(owner, chain, request_id)` with a request hash: duplicate identical request returns the existing run; changed body returns conflict. Automatic output triggers have a unique `(source_task_id, source_attempt_no, trigger_key)` and create a run in the source chain in the same transaction. Reopening a source task produces a new attempt and a separately visible run; it does not overwrite the previous run.

Task state events remain authoritative for tasks. Run events plus immutable definition and stage expansion records are authoritative for run projection. Add rebuild tests, transactional event sequence allocation and owner-immutable triggers. Do not introduce opaque JSON as the only durable representation of membership or dependencies.

### Deployment without compatibility

Choose a clean data epoch for the task engine: pre-change task/chain data is unsupported by the new engine. Add a schema marker and fail startup with a clear task-data reset requirement on an incompatible populated task schema; never silently erase data or reset unrelated chat, identity, vault or billing tables. Provide a separately invoked scoped reset command/script for development and test installations. Fresh installations initialize only the new schema. No converters, dual readers or compatibility routes. Updating UI, bridge, Hub and CLI is one coordinated release.

## Execution and ownership

### Ordinary tickets and workflow runs

The owner user and chain coordinator can create/edit ordinary tickets and create, activate, retry or cancel runs. Other workers retain existing lease-bound task submission and review permissions. A workflow task's brief, stage identity, generated dependencies and lifecycle controls belong to the engine: ordinary task update/depend/cancel/reopen endpoints reject those mutations with `workflow_task_managed` and a run link. Comments remain allowed. Human gate approve/reject stays available. Move the existing whole-chain restriction to this per-task boundary.

Run inputs and definition version are frozen at creation. Input references to prerequisites are validated then; referenced output values are resolved and snapshotted at execution start with receipts. Editing a definition affects future runs only. Changed inputs require a new run, not a retry. An explicit source/provenance link can relate replacement runs.

Runs inherit the chain coordinator, fleet and placement rules; they do not own a second coordinator or copy chain directories/fleet. Validate required review roles before activation. Prevent workflow creation from silently widening chain fleet policy; coordinator explicitly configures missing templates/roles. Existing task placement precedence remains unchanged.

Starting a run on a published chain validates everything and creates the run, pending execution, stage expansion and ready root tasks atomically. A run with unmet external prerequisites remains pending, without worker leases. On a draft chain, creation produces a draft execution; chain publish validates all tickets/runs together before activating them. Empty chains may be published for coordinator planning. Adding work to completed/cancelled/archived chains returns conflict; explicitly reopen eligible chains first.

### Dependencies and completion

Use one DAG of ordinary ticket/run nodes. Validate endpoint scope/ownership, self-edges and transitive cycles across both kinds in the same transaction. Internal stage DAGs stay private to their run. Existing internal task edges may remain engine implementation details, with explicit provenance separating them from external work dependencies.

A prerequisite succeeds only when an ordinary task is `Done`, or the referenced run's current execution is `succeeded`. Cancelled tasks and cancelled/failed runs block dependents. Remove the existing global rule that cancellation unblocks task dependents, and update gate/materialization code to use success rather than terminality. Coordinator can remove/replace a prerequisite explicitly; record the reason and history. Adding an unmet prerequisite to already started/completed work returns conflict rather than silently rewriting its input contract.

A run succeeds only after every required stage succeeds and every expansion finishes, including zero-item fan-out and gate approval. A blocked worker or temporarily unavailable bridge yields a running run with a derived blocked badge, not failure. Exhausted task budget or exhausted gate replan budget makes the run failed with a durable reason; halt new materialization, reclaim outstanding leases and cancel unfinished generated tasks in that execution. Completed outputs remain available for diagnosis; partial outputs never satisfy the run dependency.

Progress becoming idle emits `work_batch_finished`, not chain completion. The coordinator may add more tickets/runs indefinitely while active. Explicit `complete` checks all included ordinary tickets are done, included runs succeeded, no drafts, no live leases, and a nonempty final summary. Failed/cancelled work must be retried/replaced or explicitly excluded with a reason. Excluded active work must first be cancelled; included dependents still cannot depend on excluded unsuccessful work. Require at least one included successful item. Keep final acceptance separate from archive/cleanup; close-related runtime cleanup only runs after this transition.

Completion uses `expected_work_revision`; a simultaneous work addition or task/run transition wins or completion wins, never both. A stale completion returns `409 work_changed`. Reopen is explicit and preserves prior completion events/summaries. Remove both service and engine paths that infer chain completion from all currently materialized tasks.

### Retry and cancellation: deliberate first-release simplification

Retry reruns the entire run as a new execution generation under the same run id, from the immutable definition and inputs. Preserve all old tasks/events/output history. Remove stage retry, stage-key rewriting, cascade carry-forward and cross-stage VCS reuse in this release. Existing human gate replanning also starts a fresh execution, retaining a run-level replan count so full retries cannot accidentally reset the gate's bounded auto-replan budget. This increases repeated work but substantially reduces correctness risk in mixed work; targeted stage retries can be a later feature with a separately reviewed invalidation design.

Before retrying, reject if any external consumer has an execution receipt for this run, including consumers that have completed, been cancelled, or had their dependency edge removed. Return `409 output_already_consumed` with consumer ids and consumed execution. Resolve that situation through a new replacement run and explicit follow-up/rework tickets. Do not silently revoke another run's work or reopen a done ticket. If no consumer has started, retry clears current success, returns consumers to waiting, and increments the generation atomically before matching. Ordinary task reopen uses the same receipt guard; old attempts cannot silently invalidate run inputs either.

Run cancel cancels only its current execution, reclaims its work/review leases, stops materialization and leaves ordinary tickets/other runs intact. Chain cancel intentionally cancels all unfinished work, recording run and task events. Cancellation is idempotent. Cancelling a succeeded execution is rejected; exclusion from final acceptance is a separate action. Retry is allowed for failed/cancelled/succeeded runs only on active chains and subject to the consumption guard.

Every submission/review/heartbeat carries the lease's task attempt and, for generated tasks, run execution identity. After cancel/retry, an old lease cannot submit output, advance a stage, record a review or send a completion notification. Lease revocation, run generation change, dependency projection, events and queued effects belong to one UoW; wake/stop/notify effects run after commit. External processes may take time to stop, but their output is fenced immediately. Report existing VCS heads as orphaned work; never delete commits as part of retry/cancel.

## Public interfaces

Canonical REST surface (use current HTTP router conventions and authorization, with these resource shapes):

```text
GET/POST /task-chains/{chain_id}/workflow-runs
GET      /workflow-runs/{run_id}
GET      /workflow-runs/{run_id}/executions
GET      /workflow-runs/{run_id}/output?stage_key=...&execution_no=...
POST     /workflow-runs/{run_id}/retry
POST     /workflow-runs/{run_id}/cancel
GET/POST /task-chains/{chain_id}/work-dependencies
DELETE   /task-chains/{chain_id}/work-dependencies/{dependency_id}
POST     /task-chains/{chain_id}/work-scope-decisions
POST     /task-chains/{chain_id}/complete
```

Run creation accepts definition reference, title, literal inputs/input references, prerequisites and request id. It returns `{run, current_execution, chain_id, work_revision}`. Mutation commands take expected run/work revisions where appropriate. List/detail responses contain derived status/progress and typed waiting reasons. Generated task DTOs always expose run/execution/stage identity. Output defaults to current execution; historical access requires an explicit execution number. Define typed errors rather than routing by message strings.

Workflow definitions/templates remain independent reusable resources. Remove chain-kind create flags, workflow activation of existing draft chains, chain-addressed workflow status/output/retry/cancel, and workflow proposals that convert chain type. Proposals instead contain a set of ordinary tickets, workflow-run specifications and typed edges. Proposal acceptance adds these atomically to the current chain, including mid-work, under a revision check.

Expose equivalent agent RPC methods (`agent.workflow.run|list|status|output|retry|cancel`, plus dependency/scope/complete methods) with run ids for run operations. User REST and agent RPC call the same service authorization and transaction logic. Bridge proxy validators must accept the same new fields and reject removed fields.

Proposed CLI contract:

```text
ham-ctl workflow run security_audit --chain <chain> --input target=src --request-id <id>
ham-ctl workflow list --chain <chain>
ham-ctl workflow status <run-id>
ham-ctl workflow output <run-id> --stage <key> [--execution <n>]
ham-ctl workflow retry <run-id> --reason <text>
ham-ctl workflow cancel <run-id> --execution <number> --reason <text>
ham-ctl task-chain depend <chain> --item task:<id> --on workflow_run:<id>
ham-ctl task-chain exclude <chain> --item workflow_run:<id> --reason <text>
ham-ctl task-chain complete <chain> --expected-work-revision <n> --summary-file <file>
```

Keep ordinary ticket creation commands. Require a chain for run creation, inferred only from authenticated active-chain context when available; never implicitly create another chain. Require explicit run ids for run operations, since multiple runs may exist. Document these as proposed commands until implemented.

## Coordinator, context and notification changes

Rewrite `src/prompts/skills/coordinator-task-management/SKILL.md` around choosing the next work unit: use tickets for known bounded work and a run for a repeatable/dynamic stage graph. Explain that both coexist, how to inspect failed runs and receipts, and that batch completion is an opportunity to assess the goal before explicit acceptance.

Update `src/hub/service/taskv2/pack.odin`, chain summaries, context responses and bootstrap fragments to include ordinary work counts, current runs and ids, waiting/failed reasons, output references, execution numbers and final acceptance readiness. Worker packs identify their run/stage plus consumed upstream output manifests; ordinary tickets can consume run outputs through the same receipt-aware resolver. Keep payloads bounded; full event logs/output bodies are fetched separately. Search wrapper/bootstrap and persisted coordinator skill-memory seeds so live bootstraps do not retain chain-type instructions.

Notification events carry chain id, optional run/execution id, resource revision, event id and compact status metadata. Persist/reuse the existing durable effect/outbox mechanism; add durable delivery where current effects are transient. Deduplicate after reconnect by event id. The coordinator receives run failure, gate intervention, dependency blockage, run completion and batch-finished summaries. Workers receive only their lease/task changes. Coalesce related stage changes; avoid a notification per fan-out child. UI fetches current canonical resources after invalidation, and old-generation events cannot replace newer run state.

## UI behavior

One chain row/sidebar entry and conversation remain throughout the work. The overview shows a combined Work view with ordinary ticket rows and expandable workflow-run cards. Cards display run title/template, execution number, progress, waiting/failure/gate state and scoped controls; expanding embeds the existing pipeline view parameterized by run id. Generated tasks appear inside their run, with a detail link back to the run, rather than duplicating them as unrelated board tickets.

Provide Add ticket and Start workflow on active chains, including while other work is running. Creation chooses a template, inputs and prerequisites and previews required fleet/review roles. Chain creation asks for the goal/coordinator; it does not force an execution mode. Show derived Tickets/Workflows/Mixed badges only as informational summaries.

Dependency selectors choose ordinary tickets or entire runs. Cancel dialogs name the affected run and show waiting dependents; chain cancel names the broader scope. Retry explains full-run rerun and shows guarded consumers when rejected. Historical executions are available read-only. Add a Finish work action with final summary, outstanding/included/excluded work and a current revision; never auto-navigate away when the latest batch finishes. Vault-locked states follow current content protection behavior; engine-readable workflow spec/inputs follow existing trust rules rather than a new plaintext bypass.

Primary files: `src/ui/components/taskchain/TaskChainOverview.tsx`, `TaskChainsPage.tsx`, `CreateChainModal.tsx`, `src/ui/components/tasks/WorkflowPipelineView.tsx`, `taskActions.ts`, `src/ui/api/endpoints/tasks.ts`, `taskChains.ts`, and `src/ui/api/taskWire.ts`. Add `WorkflowRunCard`, `StartWorkflowRunModal`, typed mixed-work dependency controls and completion dialog. Add stable `data-debug-id` to every interactive element, with run and execution identifiers where repeated. Scope cache tags and invalidations to chain/run; do not invalidate every chain for one run's progress.

## Implementation sequence

Each step must leave its contracts and focused tests reviewable. Deliver the breaking release only after all steps pass; no deployed period with incompatible Hub and clients.

| Step | Work and exact subsystems | Exit evidence |
| --- | --- | --- |
| 1. Contract and schema | Add domain run/dependency/scope records in `src/hub/domain/taskv2.odin` (or a dedicated `workflow_run.odin`); change `taskchain.odin`; add repository vtable/functions in `repository/iface/taskv2_repo.odin` and `taskchain_repo.odin`; implement SQL repositories, new schema epoch/migration registration and indexes/triggers. | Ownership, constraints, immutable snapshots, schema-epoch refusal and run/event replay tests. REQ-MW-1/3/9. |
| 2. Run engine extraction | Refactor `service/taskv2/workflow.odin` to run/execution scoped folds, expansion/output/failure; update `fold.odin`, `service.odin`, `matcher.odin`, `lease.odin`, `pack.odin`, `gate.odin`, `events.odin`. Replace stage retry/carry-forward with full-execution retry and scoped cancellation. | Two runs using identical stage names do not collide or share max_parallel; restart/empty expansion/lease-fence tests. REQ-MW-3/5/9. |
| 3. Mixed orchestration | Update `service/taskchain/taskchain_service.odin`, task engine dependency/fold/gate code, `verbs.odin` and `verbs_m2.odin`; add typed work DAG, receipts, scope decisions, mid-work proposals, explicit completion and reopen. Output triggers create same-chain runs. | Atomic mixed creation, cycle rejection, strict-success blocking, consumption guards and completion races. REQ-MW-1/2/4/5/6. |
| 4. Transport and CLI | Update `src/hub/transport/http/taskchain_handlers.odin`, `agent_action_handlers.odin`, route registration and actual DTO/contract writers; `src/bridge/agent_api.odin`; `src/ctl/taskv2_cmds.odin` and help. Remove obsolete chain-type routes and flags. | User/agent authorization parity, request/response fixtures, stale-field rejection, duplicate request coverage. REQ-MW-7/9. |
| 5. Context and effects | Update packs, summary/context builders, coordinator prompt skill and skill-memory seeds; durable run/batch notifications and UI invalidation metadata. | Agent sees same coordinator/chain plus correct runs and outputs; reconnect receives one actionable completion/failure summary. REQ-MW-1/7/9. |
| 6. UI | Replace exclusive overview branch with mixed view; implement run creation/dependency/scoped retry/cancel/history/final acceptance; update wire adapters and cache handling. | Rendered interaction tests and debug API scenario, vault harness, stable debug ids. REQ-MW-2/8. |
| 7. Removal and end-to-end acceptance | Update existing taskv2 tests, workflow UI tests, coordinator docs and `scripts/task-v2-smoke.sh`; remove unused old code and definitions from help/memory seeds. | Clean contract searches, focused Odin suites, UI typecheck/tests and mixed-work smoke scenario. All requirements. |

Search proof at completion must cover `CHAIN_KIND_TICKET`, `CHAIN_KIND_WORKFLOW`, `workflow_snapshot_json`, `workflow_def_ref`, `require_not_workflow_chain`, old stage-key parking prefixes, `chain.kind === 'workflow'`, chain-addressed workflow endpoints and old coordinator triage language. Remaining references must be deliberately removed or explicitly historical test/schema fixtures. Preserve private conversation behavior through `purpose` and verify all chain consumers, including search, fleet cleanup and context.

## Validation matrix

| Acceptance case | Requirements / intended location |
| --- | --- |
| Publish a chain with ticket A; finish A; add audit run R; create ticket B depending on R; add verification run V depending on B; coordinator/id/conversation remain unchanged; explicit completion succeeds last. | REQ-MW-1/2/6/8; service tests, UI rendered interaction and smoke. |
| Two security-audit runs use the same stage keys with max_parallel=1; each may lease one item while chain fleet global limits still apply. | REQ-MW-3; `taskv2/m3b_test.odin`, matcher/lease suites. |
| Ticket/run cycle, cross-chain endpoint, owner mismatch and dependency on a generated task are rejected atomically. | REQ-MW-4/9; service and HTTP tests. |
| Cancelled task, failed/cancelled run and rejected gate never release success dependents. Exclusion does not bypass a dependent's prerequisite. | REQ-MW-4/5/6; fold/gate/dependency tests. |
| Zero fan-out succeeds exactly once; malformed output fails contract validation; unfinished expansion prevents premature success after restart. | REQ-MW-3/9; workflow/repository restart tests. |
| Retry before a consumer starts gives a new generation, pauses dependent readiness and preserves previous output history. Retry after any consumer receipt returns conflict, even after edge removal. | REQ-MW-4/5; workflow and receipt repository tests. |
| Cancel/retry races with submission, approval and heartbeat: exactly one transition wins; stale lease cannot complete new execution; unrelated tickets and runs keep their leases. | REQ-MW-5/9; transaction/lease and HTTP tests. |
| Task budget/gate replan exhaustion fails only its run, cancels unfinished run tasks and emits a deduplicated coordinator notice; a bridge outage only blocks. | REQ-MW-3/5/9; timers/gate/effects tests. |
| Completing a chain races with adding a ticket/run: stale revision conflicts; no completed chain contains newly admitted runnable work. All-current-work-done alone never closes it or stops its coordinator. | REQ-MW-2/6/9; service status sync tests. |
| Duplicate run-create/output-trigger retries and restart do not duplicate runs, expansions or notifications. Definition edits leave existing snapshots unchanged. | REQ-MW-3/7/9; UoW, repository, transport tests. |
| Worker cannot mutate generated briefs/dependencies or cancel runs; coordinator cannot bypass gate user approval; owner can perform scoped operations. | REQ-MW-5/7/9; authorization parity tests. |
| UI shows one chain entry, mixed contents, correct run-scoped actions, history, blockers, completion exclusions and vault-protected text; every button/input/select/textarea has debug id. | REQ-MW-8; `tests/ui_task_v2_*`, workflow tests and new mixed-work rendered tests. |

Use existing `src/hub/service/taskv2/m3b_test.odin`, lease/fold/pack suites, `src/hub/service/taskchain/taskchain_service_test.odin`, `src/hub/taskchain_status_sync_test.odin`, repository tests and `src/ctl/taskv2_cmds_test.odin` as entry points. Run repository-supported Odin package test commands with its collection configuration, `npm run typecheck`, targeted Node UI tests through `tests/helpers/vaultEndpointHarness.ts`, then `scripts/task-v2-smoke.sh` extended for mixed work. Report actual commands and results during implementation; no implementation tests were run for this planning document.

## Deliberate boundaries and follow-ups

- Entire-run retries and consumed-output guards are a first-release choice, not an accidental regression. Targeted stage retries, automatic cascading rework and cross-generation carry-forward are deferred.
- External dependencies target whole runs. Exposing stage outputs as independently successful public dependency nodes is deferred; output inspection remains available.
- No workflow-in-workflow containers: workflow output triggers may add sibling runs to the chain with provenance, using the same coordinator and idempotency rules. Validate trigger references and enforce a per-chain automatic-trigger budget to prevent unbounded recursive spawning; budget exhaustion becomes coordinator attention without repeated side effects.
- No generic work-item table, independent run fleet, automatic completed-chain reopening, silent data migration, or hidden child chains.
- The most visible behavior change beyond mixed work is explicit chain completion and success-only dependency satisfaction. Ship the coordinator instructions and UI completion controls in the same release so active work has an obvious close path.

These decisions make the plan implementable without additional product clarification. They should be reviewed as part of implementation kickoff, especially the cost/correctness tradeoff of full-run retry and the intentionally unsupported old task-data epoch.


## Implementation checkpoint: run persistence foundation

Started 2026-10-19 in `C:/Users/Tanmay/ham-wt-mixed-work`, branch
`mixed-work-task-chains`, based on `40348ff2` (`passwordless-vault` HEAD).
The original checkout's uncommitted vault changes were not copied or modified.
No commits, merges or deployment were performed.

This checkpoint implements part of step 1, covering the persistence portions of
REQ-MW-1, REQ-MW-3 and REQ-MW-9. It is not the engine cutover or a usable mixed-work
UI yet. The old workflow engine is still untouched; no compatibility adapters,
legacy-data converters or fallback readers were introduced.

Implemented files:

- `src/hub/domain/workflow_run.odin`: typed run identity, immutable definition and
  inputs, execution generations, durable stage expansion and ordered run events.
- `src/hub/repository/iface/workflow_run_repo.odin`, `taskchain_repo.odin`: shared
  task-engine repository surface, owner-scoped reads, idempotency-key lookup,
  revision-checked updates and insert/append operations.
- `src/hub/repository/sqlite/workflow_run_repo_sqlite.odin`,
  `taskchain_repo_sqlite.odin`: SQLite implementation on the existing connection
  and unit of work. Creation and the first execution must commit together.
- `src/hub/repository/sqlite/migrations/095_workflow_runs.sql`, `migrations.odin`:
  registered embedded/on-disk schema, composite ownership references, immutable
  snapshots/history, state transition guards, deferred current-execution FK,
  retry-generation guard and ledger recovery after schema commit.
- `src/hub/repository/sqlite/workflow_run_repo_test.odin`: seven behavior tests for
  multiple runs/stage keys, owner isolation, verbatim event payloads, empty
  expansion, stale revisions, retry history, frozen inputs, malformed records,
  real UoW creation, deferred-FK rollback and restart/ledger recovery.

Validation (Windows, Odin on PATH; collection `odin_test=src`):

```powershell
odin test src/hub/repository/sqlite -collection:odin_test=src -define:ODIN_TEST_NAMES=test_mixed_work_runs_are_independent_and_owner_scoped,test_mixed_work_snapshot_idempotency_and_revision_guards,test_mixed_work_retry_preserves_generation_history,test_mixed_work_ownership_constraints_and_atomic_creation,test_mixed_work_events_and_expansions_are_append_only,test_mixed_work_records_survive_reopen_and_migration_reentry,test_mixed_work_invalid_contracts_fail_closed -extra-linker-flags:/LIBPATH:C:/Users/Tanmay/heimdall-win-build/deps/lib -out:mixed-work-repo-tests.exe
odin run tests/migration_bootstrap_test -collection:odin_test=src -extra-linker-flags:/LIBPATH:C:/Users/Tanmay/heimdall-win-build/deps/lib -out:mixed-work-migrations.exe
odin check src/hub -collection:odin_test=src -no-entry-point
odin build src/hub -collection:odin_test=src -extra-linker-flags:/LIBPATH:C:/Users/Tanmay/heimdall-win-build/deps/lib -out:mixed-work-hub.exe
git diff --check
```

All commands above exited 0. Seven focused tests passed; both migration paths
produced identical schemas. The full repository suite exited 1: 100/103 passed
(at that run it included the initial six mixed-work tests). The three failures
were `test_step_changes_is_per_statement_under_concurrent_writes`,
`test_tx_mutex_serializes_uow` and `test_tx_uow_nested_savepoint`, with database
open/seed failures. Running exactly those three tests in the original checkout
also exited 1 with the same failures. Existing unrelated memory-leak warnings
were emitted by the broad suite. Do not report the broad suite as green.

Nix is unavailable on Windows PATH and in the available WSL shell, so the Nix
package check is still pending; the native Windows Hub build passed instead.

Next: complete the durable mixed-work DAG, receipts and scope contracts; wire
run/execution identity through generated task persistence; extract the workflow
engine from chain scope. Remove old chain execution-kind fields during the
coordinated engine/transport/UI cutover and implement the planned task-data epoch
boundary there. Consumption-aware retry guards, lease fencing, explicit chain
completion and user-visible mixed work have not been implemented by this slice.


## Implementation checkpoint: mixed dependencies and consumption

Continued in the same worktree and branch on 2026-10-19. This adds the durable
DAG/receipt/scope portion of step 1 and the ordinary-ticket integration portion
of step 3, covering backend work toward REQ-MW-4/5/6/9. The complete feature is
not ready for use: workflow execution is still chain-scoped, and new public
transport/CLI/UI and explicit chain completion are pending.

Implemented contracts and behavior:

- `src/hub/domain/mixed_work.odin`: typed ticket/run references, dependency
  lifetimes (including removal actor/time/reason), consumption receipts and
  ordered include/exclude scope decisions. Removal is a tombstone on an immutable
  edge; re-adding creates a new edge. There is one unique active edge per pair.
  This replaces the need for a separate dependency-removal audit event table.
- `src/hub/repository/sqlite/migrations/096_mixed_work_graph.sql`: all four
  ticket/run edge combinations, recursive cycle rejection, same-chain/owner and
  ordinary-ticket endpoint validation, append-only provenance, current successful
  generation checks and consumed-output guards. Referenced ticket identity and
  consumed output facets cannot be rewritten. Exclusion requires terminal work;
  it never satisfies a prerequisite. Embedded registration and ledger restart
  recovery are updated in `migrations.odin`.
- `src/hub/repository/iface/mixed_work_repo.odin` and
  `src/hub/repository/sqlite/mixed_work_repo_sqlite.odin`: owner-scoped graph,
  receipt and scope persistence on the existing task-engine connection/UoW;
  wired through the existing taskchain repository vtable.
- `src/hub/service/taskv2/mixed_work.odin`: transactional owner/coordinator
  operations, duplicate-add/remove idempotency, readiness, input capture and
  actionable consumed-output conflicts listing consumers and generations.
  Started work cannot acquire new prerequisites. Each consumer start captures
  exact source generations and manifests; cancellation, completion or removal
  never erases those receipts. Ticket manifests identify an output facet by task
  and attempt; run manifests freeze the execution's output manifest JSON.
- `src/hub/service/taskv2/service.odin`, `lease.odin`, `verbs_m2.odin`: ticket
  folding and grant checks honor the new graph; grants capture receipts in the
  same transaction as their lease/attempt/event; consumed tickets reject reopen
  with `output_already_consumed` before recording a new event. Each grant has a
  savepoint because the matcher intentionally skips failed candidates while
  committing other work. Effects transfer to the parent after release and retain
  the existing restart-wins coalescing rule; no wake occurs before outer commit.
- `src/hub/service/taskv2/service_test.odin`: Windows file-backed fixtures use the
  existing TEMP directory because HOME is normally absent there. No environment
  variables are repurposed. This permits the actual engine suite to run locally.
- `src/hub/service/taskv2/mixed_work_test.odin`: 14 new tests, including real
  published-ticket folds and lease grants, injected receipt-storage failure,
  parent rollback, stale ready projections, typed cycles, authority, exclusions,
  consumed-output reopen protection and restart/ledger recovery. Tests that seed
  run lifecycle projections explicitly do not claim run-engine coverage.

Validation commands (Windows; each final command exited 0):

```powershell
odin test src/hub/service/taskv2 -collection:odin_test=src -define:ODIN_TEST_THREADS=4 -extra-linker-flags:/LIBPATH:C:/Users/Tanmay/heimdall-win-build/deps/lib -out:mixed-work-service-suite.exe
odin test src/hub/repository/sqlite -collection:odin_test=src -define:ODIN_TEST_THREADS=2 -define:ODIN_TEST_NAMES=test_mixed_work_runs_are_independent_and_owner_scoped,test_mixed_work_snapshot_idempotency_and_revision_guards,test_mixed_work_retry_preserves_generation_history,test_mixed_work_ownership_constraints_and_atomic_creation,test_mixed_work_events_and_expansions_are_append_only,test_mixed_work_records_survive_reopen_and_migration_reentry,test_mixed_work_invalid_contracts_fail_closed -extra-linker-flags:/LIBPATH:C:/Users/Tanmay/heimdall-win-build/deps/lib -out:mixed-work-repo-tests.exe
odin run tests/migration_bootstrap_test -collection:odin_test=src -extra-linker-flags:/LIBPATH:C:/Users/Tanmay/heimdall-win-build/deps/lib -out:mixed-work-migrations.exe
odin build src/hub -collection:odin_test=src -extra-linker-flags:/LIBPATH:C:/Users/Tanmay/heimdall-win-build/deps/lib -out:mixed-work-hub.exe
git diff --check
```

The final full engine run passed **94/94 tests**, including the 14 new graph
cases. Persistence passed **7/7**. Embedded/on-disk bootstrap produced identical
schemas. The first engine run exposed a restart/stop coalescing regression from
moving grant effects across savepoints; the effect transfer was corrected, the
specific existing regression test passed, and the entire suite then passed.
The full engine log is `%TEMP%/ham-mixed-work-service-suite.log`. Generated build
executables were removed from the worktree. Nix package validation remains
pending because the available Windows/WSL environment has no Nix installation.

Remaining cutover work: generated-task run/execution identity and run-scoped
materialization/concurrency/output/retry/cancel; same-chain output triggers;
revision-checked explicit final acceptance and scope application; transport/CLI,
worker/coordinator context, notifications and combined UI. The old
`task_dependencies` graph and chain-owned workflow fields will be removed during
that coordinated cutover. The new tables are not exposed as a compatibility
route or alternate engine mode. Nothing was committed, merged or deployed.


## Infrastructure handoff - final cutover

The user deferred UI implementation and requested a commit and branch push after
infrastructure completion. Mockups are design artifacts only; src/ui is unchanged.
All task chains now use mixed_work. There is no ticket/workflow/private-conversation
execution split in the Hub, and no chain-level workflow snapshot or definition.

Implemented surfaces:

- Run-scoped recipe snapshot, caller-keyed idempotent creation, executions, durable
  expansion history (including empty fan-out), lifecycle events and output manifest.
- Stage tasks carry run/execution identity. Materialization and concurrency limits
  are scoped to that identity. Whole-run retry makes fresh tasks; old tasks and
  execution records are retained. Generated definitions and stage identity are immutable.
- One typed external DAG for ordinary tickets and whole runs, cycle/same-owner/
  same-chain checks, strict-success readiness, immutable input receipts, auditable
  dependency removal and explicit scope decisions. Generated tasks remain private
  to a run and cannot be edited, reopened or cancelled individually.
- Input receipts are recorded atomically with starting a ticket attempt or run.
  Consumed output blocks provider reopening/retry, even after edges are removed.
  Worker TASK.md includes run identity and exact-generation fetch commands.
- Ordinary tasks and workflow stages wait for successful worktree merges before
  satisfying dependencies. Merge replies reconcile the mixed work graph.
- Proposals can add work during an active published chain. Output triggers add a
  sibling run in the same chain, consuming their source ticket or whole parent run.
  Logical expansion/trigger failures roll back partial run/stage writes and notify
  the coordinator without discarding the producer's successful submission.
- Completion requires current work_revision, nonempty acceptance summary, successful
  included work, no outstanding merge/lease or proposal, and at least one success.
  Completion history is immutable. Batch completion never implicitly closes a chain.
- Restart recovery reconciles runs and tickets together before matching.
- Shared fleet roles must be configured; starting a run never creates fleet rows.
- Coordinator and CLI-reference bootstrap skill sources now document the new model.

### REST / agent / CLI contract

| Operation | REST | CLI |
| --- | --- | --- |
| Create/list runs | POST/GET /api/v1/task-chains/{id}/workflow-runs | workflow run REF --chain ID --request-id KEY; workflow list --chain ID |
| Inspect run | GET /api/v1/workflow-runs/{id}?execution_no=N | workflow status RUN [--execution N] |
| Stage outputs | GET /api/v1/workflow-runs/{id}/output?stage_key=KEY&execution_no=N | workflow output RUN STAGE [--execution N] |
| Execution/event history | GET /api/v1/workflow-runs/{id}/executions | workflow history RUN |
| Whole-run retry | POST /api/v1/workflow-runs/{id}/retry | workflow retry RUN --expected-revision N --reason TEXT |
| Cancel run | POST /api/v1/workflow-runs/{id}/cancel | workflow cancel RUN --execution N --reason TEXT |
| Graph/scope history | GET /api/v1/task-chains/{id}/work/graph | task-chains graph --chain ID |
| Add dependency | POST /api/v1/task-chains/{id}/work/depend | task-chains depend --chain ID --item task:ID --on workflow_run:ID |
| Remove edge | POST /api/v1/task-chains/{id}/work/remove-dependency | task-chains remove-dependency --chain ID --dependency ID --reason TEXT |
| Scope decision | POST /api/v1/task-chains/{id}/work/scope | task-chains scope --chain ID --item REF --action include/exclude --reason TEXT |
| Final acceptance | POST /api/v1/task-chains/{id}/work/complete | task-chains complete --chain ID --expected-work-revision N --summary TEXT |

Agent Bridge methods use agent.workflow.{run,runs,status,output,history,retry,cancel}
and agent.work.{graph,depend,remove_dependency,scope,complete}. Mutations require
chain owner/coordinator; read endpoints enforce owned-chain access. The run request
body is {ref,title?,inputs?,request_id,prerequisites?:[{kind,id}]}. Retry accepts only
run_id (agent envelope), expected_revision and reason; obsolete stage/cascade input
fails validation. Work refs use kind task or workflow_run, never a stage task.

### Breaking storage cutover

Migration 097 refuses installations containing chain-owned workflow snapshots or
legacy task dependency rows. It does not delete/reset/convert that business data.
Use a fresh disposable task database for the first review/manual exercise. No live
Hub, runtime database or user data has been changed during this implementation.
The final schema removes old workflow columns, sets mixed_work as the only chain
kind/default, separates external work_dependencies from private stage dependencies,
and records a cutover epoch. The schema repair path does not recreate legacy
columns or chain-scoped stage indexes on subsequent startup.

### Validation boundary and review focus

Only static/compiler checks, native builds and git diff checks were authorized
for this continuation. No automated suite, migration/bootstrap executable, live
Hub exercise or manual test was run after the user asked to hold tests. Do not
reuse the earlier 94/94 or 7/7 foundation results as evidence for this cutover.

Normal Odin checks compile test bodies but do not execute them. Contract fixtures
were updated for canonical graph writes, immutable generated identity, strict
cancellation behavior and explicit acceptance. The previous chain-owned workflow
integration tests were replaced with run-scoped integration cases; fan-out, gates,
output triggers, restart, asynchronous merge and failure isolation need independent
review and actual regression execution before acceptance. No UI tests have been
updated or run, because UI integration is deferred and still uses old contracts.
Nix is unavailable in this Windows environment; Nix package checks remain pending.

The reviewer should inspect migration 097/bootstrap reentry, cross-mode DAG and
receipt atomicity, stale execution rejection, savepoint effect ownership, fleet
coverage, proposal activation, output-trigger failures, merge readiness, final
acceptance revisions, Bridge context rendering and CLI/HTTP parity. After review,
exercise a fresh database with ticket -> run -> ticket, two concurrent runs with
matching stage keys, retries/history, cancelled/excluded prerequisites, consumed
output guards, explicit completion and restart recovery.


Final local build evidence (executed, all exit 0; no test executables were run):

```powershell
odin check src/hub -collection:odin_test=src
odin check src/ctl -collection:odin_test=src
odin check src/bridge -collection:odin_test=src
odin build src/hub -collection:odin_test=src -extra-linker-flags:/LIBPATH:C:/Users/Tanmay/heimdall-win-build/deps/lib -out:C:/Users/Tanmay/AppData/Local/Temp/ham-mixed-work-build/ham-hub.exe
odin build src/ctl -collection:odin_test=src -out:C:/Users/Tanmay/AppData/Local/Temp/ham-mixed-work-build/ham-ctl.exe
odin build src/bridge -collection:odin_test=src -extra-linker-flags:/LIBPATH:C:/Users/Tanmay/heimdall-win-build/deps/lib -out:C:/Users/Tanmay/AppData/Local/Temp/ham-mixed-work-build/ham-bridge.exe
git diff --check
```

Build outputs are outside the worktree. Earlier object build artifacts in the
worktree were removed. Run request hashes canonicalize nested input object keys,
so duplicate requests remain idempotent across JSON serialization order changes.


### Independent review fixes (REQ-MW-2/5/6/7/9)

- Generic chain PATCH rejects `status=completed`, including reopened chains with an old summary. Final acceptance remains exclusively revision checked. Generic updates now run under the same repository UoW wrapper as other lifecycle mutations.
- Run cancel requires `execution_no`; CLI requires `--execution N`. A repeat cancellation of a previously cancelled execution returns without reconciling or touching a later execution. Unknown cancel fields are rejected.
- Proposal decisions centrally require the owner or that chain's coordinator before either approve or reject can mutate state.
- Fleet validation requires eligible positive-capacity worker coverage, named reviewer rows, and role coverage before creation and after stage placeholder expansion. The built-in solo coordinator's implicit worker row remains supported; coordinators remain ineligible to review.
- Merge policy is **settle before cancel/retry**. Pending Done-task merges (including offline delivery and unacknowledged failures) reject run cancel/retry and chain cancel. Jobs and recovery only send/apply merges for the current, non-cancelled execution. Failed executions may settle already-Done tasks before explicit retry. No repository rollback of already merged work is promised.
- Merge commands use a stable task/attempt identity. Bridge stores settled results in the repository's ignored `.heimdall/merge-results/` directory before acknowledging them, in addition to its bounded in-memory cache. Delayed duplicate commands replay the result rather than re-running a conflicted historical branch. If writing the receipt fails, the Hub receives a failure and the generation remains fenced until recovery. Receipts must be retained alongside managed worktrees.
- **Deferred P2:** terminal coordinator delivery still uses transient effects. Terminal execution state and events are durable and readable, but a crash/disconnection can lose its live notice. A proper durable acknowledged notification outbox is a separate follow-up; it is not claimed fixed here.

Regression source covers reopened-chain completion bypass, execution-targeted duplicate cancellation, pending-merge fencing, proposal authority, fleet coverage, and CLI target serialization. No tests, migrations, live Hub, or manual tests were executed during this fix pass. Native checks/builds are recorded in the parent handoff; Nix is unavailable on this Windows host. UI remains deferred.
