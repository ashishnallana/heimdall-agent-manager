# MCP capability foundation

Existing `mcp:chains` connections retain their four original tools. They do not
gain task, agent, instance, memory, project, issue or artifact permissions through
a refresh, deployment or hosted-decryption opt-in. Messaging and external task
leases are excluded.

The catalog is filtered by the connection's signed permissions. Task read adds
`tasks.list` and `tasks.get`; task write adds `tasks.comment`, `tasks.create`,
`tasks.update`, `tasks.control` and `chains.configure`. Agent read adds
`agents.list/get`; agent write adds `agents.create/update/archive`. Instance read
adds `instances.list/get/operations`, `bridges.list` and `providers.list`.
Instance control adds `instances.create/start/stop/reconfigure`. Memory and project
read add `list/get`; their writes add `create/update/archive`. Issue read adds
`list/get`; issue write adds `create/update/delete/comment`. Artifact read adds
`artifacts.list/get`; artifact write adds `artifacts.create/update/delete`.

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

## Artifact content and task results

Artifact tools use native artifact records and stable `artifact://art_…` links.
`artifacts.create` accepts `name`, optional `description`, `content` and an exact
`content_type`: `text/plain`, `text/markdown` or `application/json`. Text must be
valid UTF-8 without NUL bytes; JSON creation additionally requires one complete
JSON value. Name is limited to 500 bytes, description to 20,000 bytes, and content
to 65,536 bytes. All three prose fields are sealed under the verified current
vault epoch. The native record's `size_bytes` describes stored bytes, including
encryption overhead; it is not a plaintext size promise.

Optional owned `project_id`, `chain_id`, `task_id`, `agent_id` and
`agent_instance_id` establish native associations. Native consistency checks
apply to task/chain and instance/agent/project combinations. When only a task is
provided, its chain is derived inside the same write transaction. These are
associations, not proof that an agent executed or completed a task.

`artifacts.list` returns metadata without content. It supports these association
filters and owner/filter-bound `created_at` + `artifact_id` keyset cursors, with
the usual default 50 / maximum 100 records and a 1 MiB page budget. A filter must
refer to an owned target. `artifacts.get` opens bounded content by default;
`include_content: false` reads metadata and revision only. Content is a string,
including for JSON documents; arbitrary nested business objects are not opened.

Native artifacts produced outside MCP use the same vault text format and can be
retrieved by an external client with artifact-read consent. After a task finishes,
call `artifacts.list` with its `task_id`, then `artifacts.get` with a returned
`artifact_id`. Preserve the returned `link` for the user. Task-read and
artifact-read permissions are independent; knowing a task or artifact ID grants
no access by itself.

Content reads copy at most 128 KiB of stored text out of SQLite and open at most
64 KiB of UTF-8 plaintext. Unsupported MIME types (including HTML and binary),
oversized stored content, and missing external blob content return metadata with
`content_error`: `unsupported_content_type`, `content_too_large`, or
`content_unavailable`. Legacy MIME parameters such as `charset=utf-8` are
recognized. Invalid UTF-8, NUL, oversized decrypted content, or a locked/unavailable
epoch fail the content transform closed; retry with `include_content: false` to
read metadata. Legacy names/descriptions above 48 KiB or excessive other metadata
return `result_too_large`. No blob path is followed or exposed. Metadata update
and deletion do not load stored content, even for a large native binary.

`artifacts.update` changes **only name and description**, preserving native
metadata-update semantics. An explicitly empty description clears it through an
encrypted empty string. Content replacement, association changes, versions and
rollback are unavailable. The opaque `revision` binds native metadata,
associations and stored length; native artifact content is immutable through
this lifecycle. Both update and delete require `expected_revision` from a read
or preceding mutation. Same-timestamp metadata changes still conflict.

`artifacts.delete` permanently deletes the native row. It is not an archive or
soft delete; existing links subsequently become unavailable. Legacy tombstones
are hidden. Every write requires a stable `request_id`. The native change and
metadata-only receipt commit together after final live-grant/account/epoch checks.
Identical retries return the original result even after deletion; changed payloads
conflict. Receipt replay does not re-seal content or recreate a deleted artifact.
The mutation result includes `resource_id`, `revision`, `state` and `link`.

This increment accepts no filesystem paths, filenames to read, remote fetch URLs,
base64/binary uploads, arbitrary metadata, origin fields or owner/actor overrides.
An artifact's text is returned as data; MCP neither executes nor renders it.

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

## Runtime lifecycle and moves

`instances.create` requires a durable owned `agent_id`, an existing active owned
`chain_id`, and the full destination: `bridge_id`, `project_id` (explicitly empty
to clear), `provider`, `provider_profile` and `model`. It creates a worker member
in that chain, without replacing its coordinator. The new instance and its
conversation reuse the definition's sealed name as their label; ciphertext is
never corrupted by appending a plaintext counter. Creation inherits the native
agent permission mode. Runtime tools accept no permission override, environment,
credentials, shell commands, message text or force-stop flag.

All four writes require a stable `request_id` of at most 128 bytes and an opaque
`expected_revision`: use the definition's `revision` from `agents.get` for create,
and the runtime `revision` from `instances.get` for other actions. Runtime
revisions cover configuration, launch/run generation, effective permission mode,
runtime/startup state, user-stop flag and current task binding. Ordinary heartbeat
timestamps do not invalidate them. This revision differs from the native numeric
`configuration_revision`, which the move adapter supplies internally.

An active task lease or task binding returns `active_task_lease`. Explicitly hold
the task and wait for its native checkpoint/lease handoff before controlling its
runtime. Lifecycle writes do not silently release or transfer active task work.
The prepared lifecycle intent and lease check share a transaction. Both automatic
matching and the engine's final grant check exclude prepared/ambiguous intents and active
native moves, while counting their instance toward capacity. An indexed pending
intent lookup avoids scanning completed receipt history. No alternate machine,
profile or model is substituted when the requested target is unavailable.

The adapter commits a durable intent before sending any runtime command, and
never holds a database transaction across a network preflight or send. Create
preparation, conversation/membership and receipt commit atomically; rollback also
cancels its launch reservation. Delegated authorization, runtime revision and
lease checks run again at native acceptance, after remote move preflight. A
cancellation or revoked credential observed there prevents dispatch. Cancellation
after dispatch does not undo an accepted operation.

Responses contain only operation/resource IDs, opaque revision, safe phase/error
codes and status. Acceptance or a sent command is not proof of a ready runtime.
Poll `instances.operations` with `operation_tool` (one of the four write tools)
and the original `request_id`; this requires instance read permission. Reads and
identical write retries observe progress and never resend commands. Receipts bind
the owner, connection grant and tool; changed arguments with the same request ID
return `idempotency_conflict`, before checking an old revision. Revoked credentials
cannot replay receipts, and a new connection cannot read the old grant's history.

Create/start complete only after the expected native run is ready; stop completes
only after the corresponding run reports stopped. Native moves expose their real
`prepared`, `stopping`, `source_stopped`, `launching`, `ready`, `failed` and
`recovery_required` phases. Source stop acknowledgement or native offline-source
fencing must precede destination launch. Moves preserve instance/conversation/
chain identity and the existing permission override. Their native operation ID
and `operation_revision` are public, but command IDs, launch assertions, private
paths, labels and raw failure messages are omitted.

For a move in `recovery_required`, intentionally call `instances.reconfigure`
with a **new** `request_id`, the original destination, `retry_request_id` pointing
to the earlier move request, and `expected_operation_revision` from polling.
Also refresh the instance revision. Native retry continues the same move and
launch epoch; replaying this retry request cannot create another runtime. It does
not create a second move or silently change its destination.

Ambiguous create/start/stop failures are reported as `repair_required`; they are
excluded from new task grants and are not automatically resent. A process interruption or failed progress write can
leave `dispatch_unconfirmed`/`progress_unconfirmed`: the prepared intent remains
excluded from new task grants until native/operator recovery reconciles it.
Polling does not clear this guard or infer that a command was sent. A missing
runtime confirmation after three minutes also requires repair. This conservative
path favors avoiding duplicate launches over automatic crash recovery. The tools
do not claim exactly-once physical execution across process/network failures.

Repository integration uses synthetic bridge transports to verify lifecycle,
cross-provider moves, command ordering, recovery, lease isolation and revocation.
Physical cross-machine execution remains the separate acceptance task.

## Memories, projects and issues

Resource writes require a stable `request_id` (up to 128 bytes); edits, archives,
issue deletion and issue comments also require `expected_revision` from the
resource's `get`. Revisions cover complete native records, project path
associations, and native issue comment/vote counts. Same-timestamp native edits
therefore conflict. Omitted fields remain unchanged; an empty description or
evidence is sealed as an explicit clear. Unsupported fields, arbitrary metadata,
owner/author overrides and noncanonical enum values are rejected.

The live grant, account/directory, native mutations and metadata-only receipt
share the same SQLite transaction. Plaintext prose is never stored in retry
receipts. Receipts are checked before encryption and current-record lookups:
an identical issue-delete or comment retry remains replayable after deletion.
A changed payload with the same key conflicts. Memory attention projection runs
only after the outer commit; failed commits discard it. Native issue-comment
parent updates are checked so a failure rolls back the child and receipt too.

Memory creation always uses native `pending` status and its default 24-hour
expiry unless an explicit expiry is supplied. There is no approval/rejection
tool or writable status field. Updating an owned pending/active memory follows
native policy and preserves that status; editing active knowledge requires the
explicit signed memory-write permission. System memories may be read and carry
`read_only: true`; every mutation of them is refused. Archives retain rows and
references, and archived/rejected memories retain native edit restrictions.

All four target dimensions are available as `agent_ids`, `project_ids`,
`bridge_ids` and `template_ids` (native template IDs use `tmpl_`). Each list has
at most 100 unique, validated available/owned IDs. An empty list means broad
applicability in that dimension; nonempty dimensions are ANDed. List filters
preserve the native global-or-matching semantics. Title/description/body/evidence
are encrypted under the verified current epoch, with a 64-KiB body limit and
20-KiB description/evidence limits. Lists omit bodies/evidence; get returns them.

Project names/descriptions are encrypted. Slugs, repository URLs, VCS kind and
paths retain their native operational representation; legacy encrypted slugs
are opened as typed labels. An omitted create slug receives a generated label
without exposing the plaintext name. Explicit empty `repo_url`/`vcs_kind` clears
them, while omission preserves them. `default_path` remains required and nonempty.
Optional `bridge_paths` contains up to 20 owned `{bridge_id, path}` deltas:
nonempty paths set an override, empty paths remove it. Changes remain unvalidated
until native runtime preflight; this API neither reads the filesystem nor runs
commands. Get exposes at most 100 associations and their validation flag/time,
omitting raw validation diagnostics. Project archive retains dependent records.

Issue status is exactly `new`, `fixed` or `obsolete`; native close/reopen times
apply. Scope is exactly `global`, `project`, `agent_id` or `bridge_id`, with a
matching owned target (global requires an empty target). Optional chain links
must also be owned. Changing scope requires a compatible explicit target;
no foreign reference or implicit owner fallback is accepted. Comments use the
delegated user's identity and cannot impersonate an agent. `issues.delete` is
explicitly destructive and follows native child deletion semantics.

Lists use stable owner/tool/filter-bound created-time-plus-ID cursors, default
50/max 100 records and a 1-MiB stored-text page budget. Issue lists provide a
512-byte UTF-8 description preview after decryption; `issues.get` returns the
full description. Comments are opt-in through `include_comments` and page
separately with `comment_limit`/`comment_cursor` and `comments_next_cursor`, bound
to the parent issue. Oversized legacy prose returns a typed `*_error` marker
instead of an unbounded decrypt job. New typed worker jobs bind exact resource
tools to signed rights, project path metadata and nested issue comment IDs,
authors and cursors; unknown private fields are never forwarded.

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
