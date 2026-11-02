# Delegated MCP OAuth (U1)

U1 adds explicit device-signed connector consent, durable public grants and
client-held sealed OAuth credentials. It is disabled by default and has not been
deployed. U2 supplies actual hosted decryption and epoch-wrap delivery; U3 supplies
the four remote tools and device routing. Enabling U1 alone does not provide those
tools. The existing synthetic `/api/v1/mcp-spike` remains a separate U0 probe.

The implemented U3 transport and device-worker behavior are documented in
[mcp-remote-control.md](mcp-remote-control.md); deployment remains a separate step.

## Authorization boundaries

The authorization server uses the existing OIDC browser sign-in and Ninjy session.
Sign-in alone cannot approve a connector. Consent completion requires a same-origin
POST, a device-signed request from an already approved approver, and a separate
domain-separated consent signature. The signature covers fixed-order JSON after
`heimdall-mcp-consent/v1\n`: owner, vault, client, resource, scope, grant/family and
revision, mode, recipient public key, approver, directory head/version, epoch,
issue time and keyring-wrap hash.

The default mode uses an approved online bridge or unlocked browser to decrypt.
Hosted mode is a separate unchecked opt-in. Its consent explains that the service
will receive decryption access in RAM and send readable results to the AI provider.
It creates a new extractable P-256 ECDH recipient, never exports an existing device
identity key, and seals the current keyring using the existing signed
ECDH/HKDF-SHA256/AES-GCM wrap construction. The server verifies the scalar matches
the signed public recipient, the wrap hash and signature, and the current directory
context before issuing a code. Native device-wrap parsing still rejects delegated
recipients; a separate exact-recipient parser is used only after grant validation.

Every credential redemption checks the durable grant, family and registered client,
and the live account/vault authority. Disconnect or client/account revocation,
vault reset, or revocation of the approving device stops use. A connector receives
no directory mutation, device approval, worker, reviewer or lease authority. Its
bearer credentials are never accepted by existing native Hub endpoints.

## Credentials and refresh recovery

`mcp1.<key-id>.<base64(nonce12 | tag16 | ciphertext)>` uses AES-256-GCM under a
stable deployment envelope key. Its AAD is
`heimdall-mcp-credential-v1|<key-id>`. The encrypted JSON includes credential type,
issuer, owner, vault, client, resource, scope, grant/revision, family, recipient,
random token id, timestamps and delegated private capability. Authorization codes
add the exact redirect and S256 challenge. Type and all durable bindings are checked
after authentication. Envelope parsing is bounded and base64 must be canonical.

Codes expire after 120 seconds and are consumed once with exact redirect/client,
resource and PKCE validation. Access expires after 10 minutes. Refresh families
have no automatic idle/absolute expiry in this opt-in POC; explicit revocation or
key retirement can require reconnecting with an existing approved unlocked device.

Every successful refresh rotates. The previous refresh permits three duplicate
redemptions before its exclusive 30-second deadline, returning the **exact same
serialized successor response**. Additional duplicates inside grace receive
`temporarily_unavailable` without revocation. An authenticated consumed refresh
presented at or after the deadline revokes only its own family. Forged credentials
and wrong-client requests cannot select a victim family to revoke.

The retry capsule is `hex(salt32).base64(nonce12 | tag16 | ciphertext)`, encrypted
with AES-256-GCM. Its key is HKDF-SHA256 with fresh random salt, **raw previous
refresh credential** as IKM, and info `heimdall-mcp-refresh-retry-v1`. Fixed-order
JSON AAD binds owner, client, resource, grant/revision, family, parent hash, child
hash and deadline. Neither a stored token hash nor the deployment sealing keys can
open this capsule. No service-key wrapping of the retry response is stored.

Issue, consume, rotate, duplicate counter and revocation changes commit in one
`BEGIN IMMEDIATE` transaction on a dedicated connection. Authority reads use this
same connection, avoiding a deadlock with shared-connection writers. One atomic
winner issues the successor. A crash before commit leaves the parent usable; after
commit, persisted capsule/bindings and unchanged deployment keys recover retries
across a process restart. Losing the response beyond grace requires reconnecting.

## Persistence and operational controls

`mcp_records` stores a typed allowlist of public metadata: registrations, pending
requests, signed grants, public recipients, encrypted wraps, credential hashes,
family/replay state and bounded encrypted retry capsules. No raw code, access or
refresh token, private capability, opened keyring or readable tool result is
persisted. The capsule's raw parent credential is absent from the database.
Database plus deployment keys alone cannot recover the delegated capability.

The reaper clears expired capsules and expired code/access/pending rows at startup
and on its configured cadence (normally 20 seconds). Access to a capsule ends at
the exact retry deadline independently of cleanup. Physical deletion can lag by a
reaper pass, and backups/SQLite historical pages may retain old ciphertext. Retain
consumed refresh hashes as family replay tombstones. This does not claim secure
erasure of backups or perfect RAM zeroization.

Before any hosted deployment:

- Use HTTPS, restricted key-file permissions and a stable random 256-bit deployment
  key. Keep supported prior keys explicit; removing one may require reconnects.
- Disable request/response-body, Authorization-header, query-string, consent and
  token logging at ingress, CDN, proxy, APM and application layers. In particular,
  a consent body contains a transient private scalar. Never attach it to audit,
  exception reports, analytics or session records. Hub handlers emit only fixed
  operation/error text; database errors use fixed SQL with bound public metadata.
- Keep core dumps and swap disabled/restricted for the service. No raw credentials
  or keyrings belong in crash capture. Restrict secret-file and database backups;
  do not back up raw client credentials alongside them.
- Require independent auth/crypto review of this construction and the deployed
  logging/backup controls. The hosted service is trusted not to copy material it
  sees in RAM; this is not protection against a malicious service.

U1's explicit development flag is `--mcp-oauth-key-file <path>`. The restricted JSON
file has `{"keys":[{"id":"current-id","key_hex":"<64 lowercase hex digits>"}]}`;
the current key comes first, with at most three explicitly retained prior keys.
Ids are unique lowercase letters/digits/hyphens. Empty/all-zero/invalid keys fail
closed. The raw key is never passed in argv or environment. A persistent database,
HTTPS `ui_origin`, and existing OIDC browser login are required. Synthetic probe
mode and delegated mode cannot be enabled together. No activation is implied by
committing this code.

The issuer endpoints are `/api/v1/mcp/oauth/{authorize,register,token}`. The consent
screen is `/#/mcp/consent`; connections are managed in Settings → Devices → AI
connections. Registrations accept one exact HTTPS callback, public-client auth
method `none`, S256 and the combined `mcp:chains` scope. No remote metadata fetch
is made. Initial registration is capped at 256 clients; pending consent at 16 per
owner. Apply ingress rate limits and operational registration management before
wider availability.

## Verification and remaining work

The service tests cover envelope tampering/type/key confusion, retry binding and
entropy failure, code PKCE/single-use, expiry, replay isolation, eight concurrent
redemptions, restart retry, disconnect and actual SQLite-file non-persistence. A
synthetic fixture generated by the production browser builders verifies signed
consent, scalar/public binding and signed-wrap interoperability in Odin. HTTP
tests exercise real browser device proof, CSRF rejection, token exchange, identical
refresh responses and disconnect; existing native auth rejects delegated tokens.
The browser tests verify the default mode does not read keyring bytes and hosted
mode uses a fresh recipient without exporting device identity keys.

U2's [hosted vault path](mcp-hosted-vault.md) verifies the signed directory/epoch
chain, wraps and epoch commits, and delivers current wraps to connector recipients.
U3
must implement only `chains.list`, `chains.get`, `chains.create`, and client-driven
`events.wait` (20-second default, 25-second maximum wait, 30-second total deadline).
The user excluded unsolicited push, subscriptions and sampling. Polling needs a
stopping condition and an actively executing client; background model wake-up is
not promised.
