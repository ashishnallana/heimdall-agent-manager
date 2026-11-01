# MCP capability foundation

Existing `mcp:chains` connections retain their four original tools. They do not
gain task, agent, instance, memory, project, issue or artifact permissions through
a refresh, deployment or hosted-decryption opt-in. Messaging and external task
leases are excluded.

This foundation defines permissions for subsequent tool increments; it does not
advertise or activate those unimplemented tools. The current tool catalog stays
at four chain tools until each implementation is independently reviewed.

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

Successful consent redirects and token responses use the sensitive HTTP writer
cleanup path. This closes the response-flag omission from audit A04; it does not
claim complete erasure of all request, allocator, TLS or JavaScript copies.

Deploy compatible Hub, UI and bridges together before using version 2 consent.
Older device workers reject the unknown version and fail closed; legacy version 1
connections remain supported. No production deployment is included in this change.
The separate audit's ingress buffering, registration lifecycle, loss-free epoch
lifecycle and verified recovery work remain outstanding. Do not enable broader
plaintext traffic without resolving the relevant rollout gates.
