# MCP capability foundation

Existing `mcp:chains` connections retain their four original tools. They do not
gain task, agent, instance, memory, project, issue or artifact permissions through
a refresh, deployment or hosted-decryption opt-in. Messaging and external task
leases are excluded.

The catalog is filtered by the connection's signed permissions. Task read adds
`tasks.list` and `tasks.get`; task write adds `tasks.comment`, `tasks.create`,
`tasks.update`, `tasks.control` and `chains.configure`. Other capability groups
remain foundations for subsequent increments and expose no tools yet.

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

## Task tools

Task reads expose bounded, typed projections: title, description, goal,
acceptance, assignment, bridge pin, dependencies, current review verdicts,
blocking metadata/reason and an opaque `revision`. `tasks.get` includes comments;
`tasks.list` pages at up to 100 tasks. Full briefs, attempt facets and arbitrary
nested data are not returned. Legacy chain snapshots keep their original
projection. Connections with task-write permission additionally receive
`configuration_revision` and public fleet placement metadata in `chains.get`.

Every new write requires a caller-chosen `request_id`. Reuse the same ID and
identical arguments after an ambiguous response. A different argument set with
the same ID returns `idempotency_conflict`. Receipts are scoped to owner, grant
and tool, and persist only argument digests and public result identifiers.
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
