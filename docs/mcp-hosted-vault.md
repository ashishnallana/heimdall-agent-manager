# Hosted vault reads and epoch delivery (U2)

U2 implements request-local Odin decryption for explicitly opted-in MCP grants.
It remains disabled with the delegated OAuth feature until explicitly configured;
no deployment or remote chain-tool implementation is included in this change.
U3 supplies the four tools and their ownership, routing and polling behavior.

## Read-time trust

`src/lib/vault/directory_verify.odin` verifies the complete signed directory log,
using the same rules as the browser verifier. It checks canonical statements,
contiguous sequence/hash links, owner, root key/id, signatures, the issuer's
approver authority at each operation, approval uniqueness, revocation and epoch
progression. Current approved device rows must agree with the log. Rows alone
never introduce trusted keys.

The signed consent pins a full SHA256 directory head at its initial version and
the vault id. A later directory must extend that head. The grant's canonical
signature and every binding are rechecked under a currently trusted approver who
was already approved at the consent version. Current wraps must name the exact
recipient, current epoch, and a directory version within that epoch's verified
log segment. Their signer must still be an approved approver. After ECDH opening,
every keyring entry must match its signed epoch commitment, including older keys;
owner, vault and current epoch must also agree.

This pins the consent history and checks freshness against the live directory.
It does not claim an external, rollback-proof witness if an operator maliciously
rolls back all server state together. The hosted trust concession and deployment
controls in [delegated OAuth](mcp-delegated-oauth.md) continue to apply.

## Request ownership and field transforms

`hosted_with_access` authenticates the client-held sealed access credential and
checks live account, client, grant/family, expiry and owner bindings. It opens the
keyring into a request-owned stack value, explicitly passes a borrowed pointer to
a synchronous transform, and wipes keyrings/private scalars on exits. There is no
module-global user key or plaintext result cache. ECDH private-key objects and
temporary unwrapped keyrings are also cleared.

The transform runs outside the database lock. Before returning its result, a
second transaction rechecks credential expiry/revocation and the directory head
and epoch. A discarded result is wiped and never returned. Callbacks must return
request-owned strings and must not retain the borrowed keyring. Runtime copies,
allocator behavior and crash behavior prevent a perfect RAM-zeroization claim.

`transforms.odin` handles chain title/description, task fields and embedded tokens,
and comment bodies. It applies the local four-tool POC's explicit field whitelist,
omitting task briefs, handoff/facet blobs and comment-summary internals. Claimed envelopes that cannot open
fail the entire transform; no locked placeholder or plaintext fallback is used.
Explicit record-owner fields must match the keyring owner. Chain creation helpers
always seal under the verified current epoch. U3 must still authorize ownership
before fetching records or mutating services; cryptographic field transforms do
not substitute for business-service authorization.

Missing current wraps, bad signed directories, unknown epochs or commitment
mismatches return `decryption_unavailable`. Expired/revoked credentials return
`invalid_token`. A client connection is not silently deleted or paired again.
Once a valid current wrap is delivered, the existing credential works with it,
including while all user devices are offline.

## Rotation and repair

Initial signed consent remains immutable. `mcp_epoch_wraps` (migration 176) stores
only a current signed encrypted keyring wrap and public bindings for each grant.
The undeployed initial MCP migration moved to 175 when current main added release
migration 174. No deployed MCP schema identity was changed.

Approved devices fetch `/api/v1/mcp/oauth/recipients`, independently verify each
signed consent against their pinned directory, and seal current keyring bytes to
the public recipient from that consent. They POST the signed wrap to
`/api/v1/mcp/oauth/wraps`. The server rechecks owner/grant/revision, resource,
current directory head/version, current epoch and approved signer in the same
dedicated write transaction. A revoked grant/family/client cannot receive future
delivery. The server cannot inspect epoch keys at upload time; a signed wrap of
incorrect keys is rejected by commitment checks when the client presents its
private capability at read time.

Device rotation and revocation automatically attempt connector fanout after the
signed directory commit and local key refresh. These are deliberately separate
commits: any delivery gap fails closed in the hosted reader. Delivery failure
does not misreport the completed directory rotation as rolled back. Settings →
Devices → AI connections shows the failure and a **Refresh decryption keys**
repair action. Retry uses the same connector grant and requires no reconnect.

Browser sessions require same-origin POSTs and approved device proof. Native
approved devices may use the existing OIDC plus centrally verified v2 device
proof for wrap delivery and connection management. Initial browser consent keeps
its existing session-only ceremony. Delegated MCP bearer credentials never gain
native user or directory authority.

## Verification

Synthetic WebCrypto/Odin vectors cover interleaved users, signed consent pinning,
full approval/revoke log verification, current and historical epoch commitments,
missing/stale/wrong-key wraps, delivery without reconnect, and revocation or
rotation during a transform. Browser tests cover recipient tampering, wrong
resources, revoked approvers, automatic post-rotation delivery and repair after
network failure. HTTP tests cover approved-device recipient lookup and signed
wrap upload alongside the existing consent/refresh/disconnect tests.
