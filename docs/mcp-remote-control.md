# Remote MCP chain control

This documents the core remote chain control tools. It does not activate a
deployment. The separate synthetic OAuth probe is not a real-data endpoint.

Configure the integrated Hub using [mcp-delegated-oauth.md](mcp-delegated-oauth.md),
then give the client the public HTTPS URL ending in `/api/v1/mcp`. Standard OAuth
discovery, registration, PKCE and refresh require no custom headers or new agent
identity. Native APIs retain their existing approved-device gates.

## Tools

| Tool | Input | Result |
| --- | --- | --- |
| `chains.list` | Optional `limit` 1–100 (default 50), offset `cursor` | Readable owned chains, optional next cursor |
| `chains.get` | `chain_id` | Readable chain, tasks, current-attempt review verdict metadata and comments |
| `chains.create` | Plain `title` (1–500 bytes), optional `description` (up to 20,000 bytes) | Encrypted draft chain; no assignment or agent launch |
| `chains.message` | Required `chain_id`, stable `request_id`, nonblank `body` (up to 20,000 UTF-8 bytes) | Accepted user message; coordinator instance, conversation and message IDs; optional delivery warning |
| `events.wait` | `chain_id`, optional `timeout_ms` | `status`, transient `event`, `refresh_required`, fresh `state` |

Pagination is a current-state offset, not a snapshot or replay cursor. A get is
bounded to 1,000 tasks and 2,000 comments. Serialized input/output is capped at
4 MiB; larger results fail instead of silently truncating.

Only the small chain/task/comment projection is returned. Full briefs, handoffs,
facets, internal defaults, review findings and arbitrary nested fields are
excluded. Ownership is checked before decryption. Device output is checked again
against requested IDs, metadata, field allowlists and array lengths. Missing
keys, malformed envelopes and ciphertext left in a projection fail closed;
locked placeholders are not successful results.

Creation seals both fields, including an empty description, under the verified
current vault/epoch. The final credential/grant/directory check and persistence
share one SQLite transaction and connection; failure rolls back the write. A
transport failure can still hide a committed creation. Never automatically retry
an ambiguous `chains.create` call.

## Decryption modes

Hosted mode is the explicit, unchecked-by-default connection opt-in. It uses
U2's request-local verified keyring, described in
[mcp-hosted-vault.md](mcp-hosted-vault.md). Devices may be offline after setup;
new epochs still need an approved device to deliver a current signed wrap.

Default mode requires an approved online bridge with an unlocked vault, or an
approved unlocked browser tab explicitly enabled in **Settings → Devices → AI
connections → Allow this tab to decrypt AI requests**. Unlocking alone does not
enable it. This per-tab setting starts off on reload and withdraws on lock,
sign-out/account change or user-socket loss. Hub registration binds owner,
device and tab generation; the existing socket heartbeat renews it. If the tab
cannot withdraw or renew, registration expires within 60 seconds.

Bridge selection requires enrollment, directory approval and the
`mcp_transform_v1` runtime feature. The bridge verifies the full signed directory,
consent pin, key commits, persisted full account-root pin and epoch floor before
using its existing unsealed keyring. It gains no directory approval or wrap
privilege. One bridge gets up to 1.5 seconds before browser fallback, within the
four-second device budget. No new pairing/recovery/key-transfer flow is used.

The existing user WebSocket carries only a bounded availability hint. Browser
registration, job fetch and replies use signed-device HTTP (same-origin session,
or native OIDC with its existing v2 proof). This refines the plan's proposed
WebSocket replies: plaintext transforms and credential handling stay outside the
socket receive loop. The hint fan-out has a 100 ms total budget and skips busy
writers without introducing a stream sequence gap.

Jobs contain original signed public consent and requested content, never raw
OAuth credentials, delegated private capability or raw keyrings. Their digest
binds owner, resource, grant/revision, operation, payload, signed directory,
request ID, random generation and deadline. A domain-separated device signature
also binds the reply's device identity and result hash. Browser claims bind their
live registration generation. Expired, duplicate, wrong-device and stale replies
are refused. Grant liveness is checked before delivery/completion and again
before returning to the client.

Pending jobs/results use request-lifetime memory: 64 global slots, at most four
jobs per owner. Replies bypass the Hub's generic command-result cache and the
bridge's completed-command reply cache. Request-owned keys and known plaintext
buffers are wiped on exit; sensitive HTTP bodies and writer copies are wiped
after bounded forwarding. JavaScript strings and transport/runtime copies
prevent a claim of perfect process-memory erasure. This feature does not persist
plaintext results or user keyrings.

No responding worker means `decryption_unavailable`. Keep durable consent;
do not launch pairing, delete the connection or retry a create automatically.

## Polling and cancellation

`events.wait` defaults to 20 seconds, caps waiting at 25 seconds, and budgets
30 seconds for the server operation including authorization and forwarding.
Ingress timeouts must exceed 30 seconds. Bounded transient event-bus waiters
filter owner and requested chain, subscribe before waiting, and fetch fresh state
after a hint or timeout. There is no durable history or cross-restart cursor.

Authenticated `notifications/cancelled` cancels the matching credential-scoped
request. Waits check cooperatively and release registrations/slots on exit.
An HTTP disconnect without this notification does not interrupt native crypto
or SQLite work; cleanup uses the remaining request budget. Revoked/expired
credentials return OAuth 401; unavailable decryption is a tool error. Stream-only
GET returns 405.

Claude must actively call `events.wait` while executing a monitoring request,
with a stopping condition and budget. There is no unsolicited provider push,
SSE subscription, sampling, model wake-up or guarantee after execution stops.

## Validation and deployment boundary

Synthetic cross-runtime fixtures cover signed jobs/replies and wrong owners,
keys, pins, generations and deadlines. Integration tests cover owner services,
encrypted creation/rollback, stateless reuse, fresh waits, cancellation,
revocation, default-mode unavailability, proved browser replies, cache exclusion
and an actual URL-only HTTP round trip. Real Claude read/create/wait, a new
conversation and a cold deployed-process restart remain deployment acceptance
checks; local tests do not mean the public real-data service is live.


## Messages to coordinators

Request the explicit `mcp:chains:message` consent capability and reconnect to
approve it. This permission sends messages as the connected user and can wake
the coordinator on an owned machine; task-write and instance-control scopes do
not imply it. Legacy grants cannot list or invoke `chains.message`.

The tool routes through the current canonical coordinator membership of the
owned chain. It never chooses a coordinator from the mirror column or accepts a
caller-selected sender/conversation. Text is sealed in hosted and device modes
and appears in normal chat as a user message. Message, encrypted conversation
preview and idempotency receipt commit together before owner UI events, attention
updates, native stopped-session restart and user notice delivery.

Reuse `request_id` with the same chain and body after ambiguous results.
An identical retry returns the original target/message, even if the coordinator
has changed, and does not notify it twice. Different arguments with the same
request ID return `idempotency_conflict`. A sealing device must still be
available for device-mode calls, including retries.

`status: "accepted"` means durable persistence, not agent readiness or execution.
A post-commit runtime failure returns `delivery_warning: "bridge_offline"` or
`"delivery_unavailable"` with the saved IDs. The message remains readable in chat.
Retries do not resend its notification; repair the session through normal
controls if needed. No new durable delivery queue or background replay is added.
The tool does not return the message body, attachments, review controls, or
general chat access.
