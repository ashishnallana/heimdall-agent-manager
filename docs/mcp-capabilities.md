# MCP capability foundation

Existing `mcp:chains` connections retain their four original tools. They do not
gain task, agent, instance, memory, project, issue or artifact permissions through
a refresh, deployment or hosted-decryption opt-in. Messaging and external task
leases are excluded.

The catalog is filtered by the connection's signed permissions. Task read adds
`tasks.list` and `tasks.get`; task write adds `tasks.comment`, `tasks.create`,
`tasks.update`, `tasks.control` and `chains.configure`. Agent read adds
`agents.list/get`; agent write adds `agents.create/update/archive`. Instance read
adds `instances.list/get`, `bridges.list` and `providers.list`. Remaining capability
groups are foundations for subsequent increments and expose no tools yet.

The optional scopes are `mcp:<resource>:read` and `mcp:<resource>:write` for tasks,
agents, memories, projects, issues and artifacts. Runtime sessions use
`mcp:instances:read` and `mcp:instances:control`; runtime discovery belongs to the
read permission. Task placement configuration belongs to task write. Write does
not imply read. Approval authority and permission-mode escalation are excluded.

An OAuth authorization request must include `mcp:chains` and any additional
permissions the connector requests. Missing scope preserves the legacy default.
OAuth request order is normalized, but unknown/duplicate scopes are rejected.
The consent page starts all additional permissions unchecked and can select only
a subset of the request. A client that requests only the legacy scope cannot
receive broader rights: it must start a new authorization requesting them.

Legacy consent uses version 1 and `heimdall-mcp-consent/v1`. Expanded consent uses
version 2 and a distinct `heimdall-mcp-consent/v2` signature domain, with the full
canonical selected scope string included in signed data and bound into the
grant, family and sealed credentials. Both browser and native device verifiers
check the same version/scope/domain rules. A version or permission change without
a new valid signature fails. OAuth requested permissions cap the signed subset.

Access/refresh responses report the actual selected scope. Refresh preserves it;
an explicit token-endpoint scope must match the existing credential after
canonicalization. Narrowing or broadening a family requires fresh consent rather
than silently changing that family's rights. Revocation and current-directory
checks remain in force. Device versus hosted decryption is an independent choice.

## Agent definitions and target discovery

Agent tools address durable `agent_id` values; instance tools address
`agent_instance_id`. Definition create/update/archive never creates, starts,
stops or moves a runtime session. Archive preserves historic references and
leaves existing sessions running under native rules.

Agent writes require stable `request_id` values; update/archive additionally
require `expected_revision` from `agents.get` or the list summary. Revisions
cover the full native definition and support rows, including same-timestamp
native edits. The native write and public metadata-only retry receipt share
one live-grant transaction. COMMIT consumes that transaction on either outcome.
Native template availability and all support-bridge ownership checks apply.

`name`, `slug` and `instructions` are current-epoch encrypted. Names/slugs are
bounded to 500 bytes; instructions to 64 KiB. An explicit empty instruction
string clears it through an encrypted empty value. Lists omit instructions;
encrypted slugs are labels, so use `agent_id` for identity and deduplication.
The transport envelope permits 512 KiB to cover worst-case JSON escaping;
individual tool field limits still apply.
get returns typed instructions and up to 100 support rows. Oversized legacy
instructions return `instructions_error` while metadata/revision remain readable.
Support replacements contain explicit owned bridge IDs, enablement, priority
0–100 and maximum instances 0–64 (zero keeps native unlimited semantics).

New definitions retain the native `yolo` default unless `ask` is selected.
An explicit definition update may tighten `yolo` to `ask`; weakening an existing
`ask` definition returns `permission_escalation_not_allowed`. Omitted mode stays
unchanged. Runtime moves remain a separate capability and preserve permission mode.

All lists default to 50 records, cap at 100, and return `records_kind`, `records`
and optional `next_cursor`. Agent state and instance agent/bridge/runtime-state
filters apply before stable owner/filter-bound keyset paging. Cursors are seek
positions, not authorization credentials; owner and resource checks still apply.

`providers.list` requires an owned `bridge_id` and optionally an owned
`agent_id`. It exposes exact provider-profile identities, effective observed or
fallback models, model provenance/status and configuration-eligibility flags.
Flags account for native profile validation, provider/model state and detection,
agent archival/support, and bridge status/enrollment/plan state. They are a
snapshot, not a capacity reservation: task/launch writes recheck current rules.
No alternate bridge/profile is silently substituted.

Profiles page with the ordinary `limit`/`cursor`. Each profile's models page
independently with `model_limit` (default 50, max 100). To continue, select the
returned `provider_profile` and pass its `models_next_cursor` as `model_cursor`;
model cursors bind owner, bridge, agent and profile. Do not combine model and
profile cursors. Unknown exact profiles return `not_found`.

Public projections omit tokens/hashes, environment, executable arguments and
paths, transcripts, launch epochs and raw diagnostic errors. Provider labels and
model labels use typed decryption in both browser and native workers. Native
provider-view strings are copied before those views are freed.

## Task tools

Task reads expose bounded, typed projections: title, description, goal,
acceptance, input references, assignment, bridge pin, dependencies, current review
verdicts with durable reviewer and instance references, and an opaque `revision`.
`tasks.get` adds native-policy `allowed_actions`, the latest attempt's metadata
and typed handoff summary, and separate block/hold reasons and numeric
`since_ms` values. A hold reports `checkpoint_requested` while a lease remains.
Arbitrary attempt facets and unapproved brief fields are not returned.

Existing-ticket tools require both `chain_id` and `task_id`; membership and owner
are checked before decryption or mutation, including retries. `tasks.list`
supports canonical `state` and durable `assignee_agent_id` filters before stable
keyset pagination (up to 100 tasks). Cursors bind the owner, chain and filters.
Create/update accept native priorities `p0`, `p1` and `p2`.

Task metadata is independent of comment volume. Comments are opt-in through
`include_comments`, with `comment_limit` (1–100, default 50), `comment_cursor`
and `comments_next_cursor`. Pages bind the owner/chain/task and contain at most
1 MiB of stored bodies. A legacy body over 256 KiB returns metadata with
`body_error: "comment_too_large"`, without its body; paging can continue.
Comment responses and reads preserve the delegated user, client and grant IDs,
timestamp, and `author_kind: "delegated_user"`; no agent/reviewer is impersonated.
Legacy chain snapshots keep their original
projection. Connections with task-write permission additionally receive
`configuration_revision` and public fleet placement metadata in `chains.get`.

Every new write requires a caller-chosen `request_id`. Reuse the same ID and
identical arguments after an ambiguous response. A different argument set with
the same ID returns `idempotency_conflict`. Receipts are scoped to owner, grant
and tool, and persist only argument digests and public operation metadata.
Mutation responses include resulting state, publish state, revision, applied
field names, `changed`, `checkpoint_requested`, `blocked` and status
`completed`, `accepted` (checkpoint pending), or `noop`. Recheck adds bounded
action/reason codes such as `lease_dispatched`, `state_changed`, `held`,
`lease_active`, `review_pending`, `fleet_capacity` and `native_blocker`.
Private native explanation text remains in the scoped task read; receipts never
store human prose. Identical retries return the original operation snapshot,
even when later native work changes the task; refresh with `tasks.get`.
Revoked or expired credentials cannot replay a receipt. Reconnecting creates a
new grant: it does not authorize replaying the old grant's receipts.

`tasks.update` and `tasks.control` require `expected_revision` from `tasks.get`.
`chains.configure` requires `expected_revision` from the chain's
`configuration_revision`. Revisions cover complete stored native records and
relevant dependencies/fleet configuration, including same-timestamp native
edits. A conflict requires a fresh read and a new intentional request ID; an
identical successful retry is resolved before checking its now-old revision.

Prose is sealed under the verified current epoch, including goals, acceptance
items, comments and control reasons. Device/browser jobs bind the exact tool
into their digest and independently check its signed capability. The native
outer transaction rechecks the live grant, account and directory on the same
SQLite connection used for the mutation and receipt. Nested engine effects run
after the outer commit. A failed receipt or audit-event write rolls back the
business mutation.
Outer rollback and failed commit also discard queued engine effects and release
their launch reservations; a nested savepoint release does not transfer cleanup
responsibility away from the outer transaction.

To offload work, configure a fleet row with `chains.configure` action `fleet`,
an owned durable `agent_id`, explicit owned online `bridge_id`, and a provider,
profile and model supported on that bridge. Then create the task with matching
`assignee_agent_id` and `bridge_id`. A draft chain retains draft tasks; publishing
the chain through action `publish` validates briefs and activates native
dispatch. Creating on a live chain publishes immediately and can dispatch.
The native matcher retains its capacity, eligibility, review and lease rules.
Fleet configuration preserves existing per-bridge selections and writes an
explicit selection for the chosen bridge. The same durable agent can therefore
receive bridge-pinned tasks on multiple configured machines. A task targeting a
bridge without an explicit fleet selection returns
`placement_configuration_required` rather than inheriting another target.
Disabled agent/bridge support is also respected. Offline, unsupported and foreign targets return
explicit errors (`bridge_offline`, `provider_unavailable`, `not_found`). An
archived agent returns `agent_archived`. No alternate target is silently chosen.

Task control supports `publish`, `cancel`, `reopen`, `answer`, `hold`, `release`
and `recheck`; hold/cancel/answer require an encrypted reason. Native restrictions
on leased edits and workflow-managed tasks remain authoritative. There is no
arbitrary state setter, messaging tool, review approval or external lease tool.
Write does not imply task-read permission: clients that need revisions should
request both capabilities explicitly.

The repository/engine regression proves assignment to one of two synthetic
bridges, exclusive lease selection, retry handling and target errors. Actual
multi-machine execution and artifact retrieval remain the separate end-to-end
acceptance gate; synthetic lease matching is not evidence of remote execution.

Successful consent redirects and token responses use the sensitive HTTP writer
cleanup path. This closes the response-flag omission from audit A04; it does not
claim complete erasure of all request, allocator, TLS or JavaScript copies.

Deploy compatible Hub, UI and bridges together before using version 2 consent.
Older device workers reject the unknown version and fail closed; legacy version 1
connections remain supported. No production deployment is included in this change.
The separate audit's ingress buffering, registration lifecycle, loss-free epoch
lifecycle and verified recovery work remain outstanding. Do not enable broader
plaintext traffic without resolving the relevant rollout gates.
