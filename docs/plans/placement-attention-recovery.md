# Placement attention and recovery plan

Planning task: task_18e43e0aac4a37c1. Status: proposed; source implementation requires user approval.

## Problem and evidence

A ticket or review can wait indefinitely on an offline bridge without an actionable
Need Attention card. The observed reviewer fleet selected an offline MacBook
although the ticket's bridge was Riverwood.

In src/hub/service/taskv2/matcher.odin, resolve_placement uses the task pin only
when honour_pin is true. Work grants pass true; review grants pass false and use
the reviewer's fleet placement before directory/coordinator fallbacks. Review
matching currently skips an offline bridge. Worker matching records bridge_offline
as an agent failure. Review matching also defers a failure when another review
lease is live. Neither an unrelated live review nor the ticket's displayed bridge
should hide the failed reviewer's actual placement.

The card projector in src/hub/service/card/card_projector.odin derives one task
card and guards its actions with attempt, attention and blocked_on identity.
Existing agent_not_running cards offer Start agent. The effective reviewer bridge
can differ from task.bridge_id. The UI's assignReviewerAgent helper replaces the
named-reviewer list and disables user approval; it is unsuitable for targeted
placement repair without preserving other review requirements.

## Requirements

- REQ-PLACE-1: Surface actionable placement failures for both workers and each
  outstanding reviewer, including phase, role, durable agent, effective bridge,
  placement source and human-readable cause. Distinguish offline/missing/ineligible
  placement from ordinary fleet capacity, directory serialization, dependencies,
  deliberate holds and transient retry backoff.
- REQ-PLACE-2: Offer Change bridge and Change assignee / Change reviewer through
  owner-authorized controls with explicit scope, native validation, concurrency
  guards and active-lease protection.
- REQ-PLACE-3: Retry matching after a successful repair; reconcile cards when
  bridges reconnect or configuration changes; deduplicate and retire resolved
  failures without losing review, question or Start agent attention.

## Proposed behavior

Represent placement failures separately from the ticket's business state. A
review remains in_review and keeps completed verdicts and valid live leases.
Record a collection keyed by task, attempt, phase, agent and review requirement
(named reviewer or role). A stable fingerprint includes cause, effective placement
and configuration version; do not regenerate it merely because time passed.

Persist the structured failure collection through the existing repository/unit of
work conventions; add a migration and repository coverage if no suitable durable
record exists. The implementation must choose the concrete storage shape after
checking existing task facets/events, and document that choice. Do not overload a
single global blocked_on value with several independent review failures.

Project a separate placement card per task and attempt, grouping its outstanding
placement failures. Use a distinct deterministic card ID from the existing task
review/question card. Preserve existing agent_not_running Start agent consent and
avoid duplicate placement entries for the same cause. A card states, for example,
"Reviewer reviewer on MacBook is unavailable: bridge offline", with the effective
bridge and source shown. Multiple reviewer failures have separate action targets.

An idle bridge reconnect is expected to recover automatically. Show actionable
offline placement as soon as matching establishes that it prevents dispatch;
do not require a timeout or repeated user re-check. Reconcile on bridge state
changes, task/fleet edits, match outcomes and lease transitions. Dismissal/snooze
uses existing card semantics; configuration changes invalidate stale operations.
A resolved group retires the placement card; other attention cards remain.

## Recovery controls and scope

| Target | Action | Scope |
| --- | --- | --- |
| Worker | Change bridge | Ticket bridge pin; labels explicitly say "This ticket" |
| Worker | Change assignee | Replace this ticket's durable assignee |
| Named reviewer | Change reviewer | Replace only that named reviewer, keeping others |
| Review role | Change reviewer | Select an eligible fleet agent for that role; do not silently remove the role requirement |
| Reviewer | Change bridge | Change this agent's fleet placement for the chain; labels explicitly say "All tickets using this fleet" |

This plan preserves existing reviewer placement precedence. A task-local reviewer
bridge override would require a separate design and is outside this change.
Before changing a fleet bridge, show its chain-wide scope and affected queued work.
Do not silently reuse a worker's task pin for review dispatch.

For a role-based review, restrict choices to eligible fleet rows holding that role.
Where multiple agents can fulfill the role, retain normal matching rather than
invent a named requirement. If no eligible choice exists, link to fleet
configuration with the role preselected and explain that changing fleet roles
affects the chain. The implementation must not imply a per-task role assignment
that the native model cannot express.

Use owned active durable identities and enrolled eligible bridges. Apply native
provider/profile/model and directory/workspace validation before accepting a
bridge. A worker bridge move must have a valid directory/workspace on that bridge;
do not copy a host-local path blindly. If a required workspace mapping is absent,
show the actionable configuration error and keep the card.

Keep requires_user_approval, unrelated reviewers, role requirements and existing
valid verdicts intact. Apply native review re-gating rules for the changed
requirement; do not count a replaced reviewer's verdict toward its replacement.
No repair approves work or changes requirement content.

## Authority, races and leases

Card action payloads identify task, attempt, target phase/agent/role, expected
failure fingerprint, expected current assignment and expected placement/fleet
version. Authenticate the owner and validate all guards inside the mutation
transaction. Reject stale or foreign targets without side effects; refresh the
card after conflict. A client must not supply arbitrary card operations or
unchecked instance IDs.

Never move, stop or revoke a live lease to repair another target. Reject changes
that affect the target's active lease and explain the existing checkpoint/hold
workflow. A fleet bridge edit may update future placement while preserving
already-granted leases; make this visible in the confirmation. Concurrent reviewer
leases on other targets must continue. Workflow-managed assignments remain under
workflow lifecycle controls; unsupported edits link to their native configuration.

Commit configuration and the corresponding blocker/card update atomically where
supported. Run scheduling and launches through existing post-commit/native engine
paths. A launch failure remains actionable and does not consume work-attempt
budget or silently restart a user-stopped agent. Repeated identical requests must
not create duplicate launches, cards or audit events.

## Implementation tickets after approval

Each ticket requires user review. Work stays in this chain, with this soloist
implementing and verifying it. Create these tickets only after plan approval.

### 1. Record worker and reviewer placement failures

Goal: implement the structured per-target failure collection and reconcile it
without changing ticket/review business state or placement precedence.

Primary paths:

- src/hub/service/taskv2/matcher.odin
- src/hub/service/taskv2/ (native re-check, bridge/fleet rematch and lease lifecycle)
- src/hub/domain/ and src/hub/repository/sqlite/ if a durable schema addition is needed

Acceptance: offline/missing/ineligible placement is recorded for every owed target;
normal queueing is excluded; valid parallel review leases/verdicts survive;
reconnect and placement repairs clear only resolved targets; user-stop consent and
attempt accounting remain intact. Add focused matcher/repository regression tests.
Dependency: approved planning task.

### 2. Project placement cards and add guarded recovery APIs

Goal: expose a deterministic grouped placement card and owner-only native recovery
operations with explicit task/fleet scope.

Primary paths:

- src/hub/service/card/card_projector.odin
- src/hub/service/card/card_attention.odin
- src/hub/service/card/card_service.odin
- src/hub/transport/http/card_handlers.odin
- src/hub/transport/http/taskchain_handlers.odin
- src/hub/service/taskchain/ and src/hub/service/taskv2/ native mutations
- src/hub/service/card/card_attention_blockers_test.odin and adjacent card tests

Acceptance: projection preserves other attention; bridge and assignment actions
validate ownership/eligibility/guards, preserve unrelated requirements and active
leases, audit scope, retry scheduling and retain actionable launch failures.
Native API tests cover forged, stale, concurrent and workflow-managed requests.
Dependency: ticket 1.

### 3. Add placement recovery controls to Need Attention

Goal: let the owner inspect each failed worker/reviewer placement, select a bridge
or eligible identity and understand the scope before applying a native repair.

Primary paths:

- src/ui/components/attention/AttentionCardBody.tsx
- src/ui/components/attention/AttentionComposer.tsx
- src/ui/components/attention/attentionModel.ts
- src/ui/services/attention/attentionActions.ts
- src/ui/api/endpoints/attention.ts
- src/ui/store/attentionSlice.ts
- existing UI interaction/debug-selector registry required by AGENTS.md

Acceptance: controls use effective role/agent/bridge data, show task vs fleet scope,
support multiple failed reviewers, preserve selections on request errors and
refresh stale cards, have accessible labels and registered data-debug-id values.
Cover critical interaction flows with existing UI testing conventions.
Dependencies: tickets 1 and 2.

## Verification strategy

Workers choose exact commands and report them at the submitted commit.
Required coverage:

- ready worker and in_review reviewer offline/missing bridge;
- several reviewers with one active, one failed and one already approved;
- full fleet, directory lock, held ticket, dependencies and backoff produce no
  misleading placement card;
- reconnect, fleet edits, task edits and lease grants remove resolved entries;
- task bridge differs from reviewer fleet bridge and UI shows the effective bridge;
- targeted reviewer replacement preserves other reviewers and user approval;
- role eligibility, absent workspace mapping and provider mismatch fail clearly;
- cross-owner IDs, stale attempt/fingerprint/configuration, concurrent repair and
  duplicate request are rejected or safely replayed;
- live target lease and workflow restrictions are enforced;
- user-stopped agent is never restarted without explicit consent;
- UI bridge/agent selection, scope confirmation, errors and card retirement.

Run focused Odin engine/card/HTTP suites, relevant UI tests and type checking;
build touched Hub/UI targets. Inspect the final diff and clean working tree.
Do not use live production task mutations as implementation tests.

## Risks and boundaries

Separate placement-card identity and durable per-target tracking are necessary to
avoid overwriting existing review attention. Fleet bridge edits have chain-wide
impact, so scope disclosure and optimistic concurrency are essential. Cross-host
workspaces and multiple review roles must use native validation rather than UI
assumptions. Preserve existing automatic launch and explicit-stop policy.

This planning change contains documentation only. No scheduler policy, source,
database, deployment or existing live review lease is changed by this plan.
