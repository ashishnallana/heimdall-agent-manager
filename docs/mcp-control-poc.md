# MCP chain control-plane POC

This development-checkout POC exposes exactly four tools over local MCP stdio:

| Tool | Arguments | Result |
| --- | --- | --- |
| `chains.list` | optional `limit` (1–100), `cursor` | Readable owned chains and pagination |
| `chains.get` | `chain_id` | Chain plus task states and current review verdicts |
| `chains.create` | `title`, optional `description` | New empty `mixed_work` chain |
| `events.wait` | `chain_id`, optional `timeout_ms` (1–30000) | Live change hint or timeout, plus refreshed chain/task state |

The client acts as the authenticated **user**. It never becomes an agent instance,
assignee, or reviewer. Creating a chain does not start an agent. This POC has no
fleet operations, task mutations, other resource CRUD, or automatic agent wake-up.

## Run

Use Node **24 or later**, with development dependencies installed by `npm ci`.
The shared UI crypto modules run through Node's native TypeScript stripping;
`ws` is already in the development lockfile and used by existing WS smoke clients.
No new npm dependency, Hub route, vault format, or auth grant is introduced.

Provide these variables to the MCP server process:

```bash
export HEIMDALL_MCP_HUB_URL=https://your-hub.example
# Obtain a native OIDC access token through your configured provider, then enter
# it without putting it in shell history. This is a developer POC prerequisite.
read -rs -p 'OIDC access token: ' HEIMDALL_MCP_OIDC_TOKEN
export HEIMDALL_MCP_OIDC_TOKEN
node /absolute/checkout/scripts/heimdall-mcp.mjs
```

The token must have the Hub's configured issuer, API audience and scope, as
described in [OIDC authentication](auth-oidc.md). It is **not** a Claude/Codex API
key, an ID token, a removed `hut_` token, or an agent/bridge credential. The POC
does not launch an OAuth login or refresh access tokens. If the token expires,
restart with a fresh one. No browser cookies or managed-agent credentials are
copied. HTTP is permitted only for a loopback development Hub; otherwise use HTTPS.

Configure the MCP client to launch `node` with the absolute script path and the
two environment variables above. For clients using an `mcpServers` JSON config,
the server entry has this shape (supply the token through its inherited process
environment, rather than saving a credential in the JSON):

```json
{
  "mcpServers": {
    "heimdall": {
      "command": "node",
      "args": ["/absolute/checkout/scripts/heimdall-mcp.mjs"],
      "env": { "HEIMDALL_MCP_HUB_URL": "https://your-hub.example" }
    }
  }
}
```

This is a server-entry example, not a promise that every client uses the same
configuration file format. Client UI installation and OAuth polish are deferred.

## Pair and try it

1. Sign in to Ninjy on an already approved device with an initialized vault.
2. Connect the MCP server and ask for `chains.list`.
3. The first call returns `pairing_pending` with a pairing code. The server also
   prints the code and fingerprint to **stderr**. On the existing Ninjy device,
   use the normal **Add device** flow and approve **Ninjy MCP POC (ephemeral)**.
4. Retry `chains.list`. Then call `chains.create` with a test title and description,
   followed by `chains.get` for the returned `chain_id`.
5. Call `events.wait` for an existing chain with tasks. Change a task or its review
   through Ninjy while the tool is waiting. It returns a scoped change notice and
   fresh chain/task state. It exposes review verdicts, not encrypted review bodies.

The process holds an ephemeral non-extractable device identity in RAM. **Each
server restart requires pairing again.** Existing pending/approved device records
remain visible in Ninjy and can be revoked there; stopping the process does not
delete durable device records. Do not restart repeatedly just to retry pairing.

Pairing reuses the web UI's identity, registration, pairing MAC, signed-directory
verification, keyring wrap and content transformers. Native HTTP and WebSocket
requests carry the Hub's v2 device proof. The OIDC issuer/subject determines the
user; tools cannot supply an owner or substitute an identity. Keys are never sent
to the model or stored in a new key file. This local adapter uses the existing
device vault implementation directly; it does not export keys from a bridge.

Encrypted fields are opened only after approval and directory verification.
Chain writes are sealed with the current epoch. Missing keys, wrong vaults,
revocation, expired authentication, and unreadable output fail explicitly rather
than returning ciphertext as usable task text.

## Event semantics and limits

`events.wait` is cooperative waiting, **not push into an idle model turn**. The
client must call it again to continue waiting. Each call checks chain ownership,
opens the existing authenticated user WebSocket, waits for its ready handshake,
filters to the requested chain, and closes it when done. Only scoped IDs/change
metadata are returned; unrelated user events are discarded. User/device access is
checked again before returning fresh state. Timeout excludes authentication and
refresh HTTP requests, each of which has a 15-second network deadline.

Events are transient hints. There is no durable cursor, replay, or exactly-once
guarantee, and changes between waits can be missed as events. Always use the
returned snapshot; after reconnect or a failed wait, call `chains.get`. The
snapshot reflects current state even when no hint was observed. The Hub continues
to enforce task and review rules independently of event delivery.

One tool call runs at a time because the reused keyring session is process-wide.
Concurrent calls receive a retryable `busy` result. MCP cancellation interrupts an
active event wait, and EOF/termination closes sockets and drops local key access.
The POC negotiates an MCP revision up to `2025-11-25`; a client must support one
of the offered legacy stdio revisions. Claude Channels, newer protocol-specific
subscriptions, automatic login/refresh, persistent device storage, and packaged
distribution are follow-on work.

## Verification

```bash
node --test tests/mcp_control_plane_test.mjs
node --import ./tests/helpers/vaultEndpointHarness.ts --test \
  tests/ui_vault_pairing_flow_test.ts tests/ui_vault_keyring_test.ts
npx tsc -p tsconfig.renderer.json --noEmit
```

The MCP suite uses the existing signed-vault fixture/builders and a real local
WebSocket server. It covers readable results and encrypted writes, pairing MAC
failure, revocation, expired auth, denied foreign-chain reads/subscriptions,
request proofs, protocol framing, timeout/cancellation and clean stdout. A live
provider token, real-device approval, and an interactive Claude/Codex smoke run
remain deployment acceptance checks; hermetic tests do not establish those.
