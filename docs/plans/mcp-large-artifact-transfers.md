# MCP large artifact transfers (15 MiB files and HTML bundles) — strict E2EE

> **Superseded (2026-11-02, task `task_18e449b0b41218f2`).** This design is **not**
> the direction for Heimdall. Large MCP artifacts (≤ 15 MiB, incl. HTML bundles) go
> through the ordinary artifact create path — exact JSON entry content and `files` —
> sealed by the **existing MCP encryption/decryption relay** (approved bridge or
> unlocked browser in device mode, Hub keyring in hosted mode), with artifact-specific
> relay limits raised for that path. The standalone transfer-handle architecture
> described here (staging tables, `hxt_` data path, blind token checks, transfer
> receipts, pre-body admission and streaming hooks) was implemented in
> `42da6ed8..bf234a70` and then **removed from source**; migration
> `187_mcp_artifact_transfers.sql` is no longer registered. The 15 MiB limit
> (`13d3b242`) and HTML bundle support (`2919dec8`) remain. The text below is kept
> as historical context only — do not implement it.

Status: **superseded (see banner above); historically a design.** Task `task_18e442c8474574d1`, chain
`chain_18e43a321b7b6c60` (REQ-ART-1/REQ-ART-2). This revision **supersedes** the
design at commit `9bd7b372` (task `task_18e4411ea03fd52a`), whose staging and hosted
seal/open let the Hub see transfer plaintext (§10). It unblocks
`task_18e43fc82ae1bc46`. No application code is changed by this document.

## 1. Requirement

An MCP-connected client must be able to **upload** an artifact of up to
`contracts.ARTIFACT_MAX_CONTENT_BYTES` = **15,728,640 decoded bytes** (binary or
text, including `kind = html-bundle` `.zip` archives) and **download** any owned
artifact up to that size **byte-exactly**, under **strict end-to-end encryption**:

- **E1.** The Hub never receives plaintext file bytes, plaintext digests of them,
  plaintext artifact names/descriptions, or any key able to decrypt them — in any
  connection mode, including grants that opted into hosted decryption.
- **E2.** Only a *trusted executor* seals and opens: an approved, unlocked vault
  device that the user controls (a bridge reached through local `ham-ctl`, or an
  approved browser tab of the Heimdall UI). The Hub stages, stores and serves
  ciphertext only.
- **E3.** The Hub never hands anyone a URL that returns plaintext. Download URLs
  return the stored v2 ciphertext; plaintext exists only inside the executor.
- **E4.** Persisted artifacts keep the existing vault v2 format, so every current
  reader (web UI, HTML bundle viewer, `ham-ctl artifact`, `GET
  /api/v1/artifacts/{id}/content`) works unchanged.

"Strict" is relative to the existing web trust model: the browser executor runs UI
code served by the Hub, exactly like every other vault operation in the web UI
today; the Electron desktop app and `ham-ctl` do not have this caveat. This design
adds no new trust in the Hub beyond that.

## 2. Source facts that shape the design

Line numbers are at `9bd7b372`.

| Fact | Where | Consequence |
|---|---|---|
| A v2 token is `vault:v2:<vault_id 16 hex>:e<epoch>:<b64(nonce‖tag‖ct)>`, AES-256-GCM, AAD = `heimdall-vault-v2\|<vault_id>\|e<epoch>` | `src/lib/vault/envelope.odin:21-35,82-91,246-262` | AAD does **not** bind the artifact, so a Hub could swap two ciphertexts of the same vault undetected by GCM → receipts (§6) bind artifact id. `len(ct) = len(pt)`, so plaintext size is derivable from ciphertext length (inherent leak, also true today). |
| Max armored size of a 15 MiB plaintext = 38-byte max header + `4·⌈(15,728,640+28)/3⌉` = **20,971,598 B** | `src/hub/domain/vault_text_caps.odin:38-39,79-82` (`vault_armored_max_bytes`) | Hub enforces the decoded 15 MiB limit **blind**, by arithmetic on the token length and padding. |
| `content_service.create_artifact` accepts an already-armored value and only size-checks it | `src/hub/service/content/content_service.odin:31-38,354` | Ciphertext-only commit reuses it; vault id/epoch checks are new and transfer-specific (§5.4). |
| Native content GET returns the **stored** value (ciphertext for sealed artifacts) | `src/hub/transport/http/content_handlers.odin:255-270` | Downloads need **no** staging: serve the stored token. |
| `ham-ctl` gets the keyring from `$HEIMDALL_VAULT_KEYRING` or the local bridge (`agent.vault.get`, agent token required) | `src/ctl/vault.odin:14-18,60-118`; `src/bridge/agent_api.odin:297-301` | Shell executor = local `ham-ctl` inside a Heimdall agent (or the dev env override). Plain shells without an agent token have no keyring source (§8). |
| Bridges sign domain-separated statements with their enrolled identity key; only the `heimdall-mcp-worker-result/v1` prefix is accepted today | `src/bridge/unseal_protocol.odin:439-445`; `src/bridge/mcp_transform.odin:36-40` | New receipt domain needs a second allowed prefix, never arbitrary text. |
| Browser devices sign with `signP256(identity.signPrivateKey, …)` | `src/ui/utils/mcpWorker.ts:200-203` | Same primitive for browser receipts. |
| Browser has `encryptVaultBytes`, `decryptVaultBytes`, `readHtmlBundle` | `src/ui/utils/vaultCrypto.ts:420,538`; `src/ui/utils/htmlBundle.ts:265` | Browser executor reuses them byte-exactly (proved by `tests/ui_artifact_bytes_vault_test.ts`). |
| UI routes live in the URL **hash** | `src/ui/utils/appLocation.ts:9-18` | A browser transfer link `https://<hub>/#/artifact-transfers/<id>` never sends its route to the server; it carries no secret anyway. |
| Hub verifies the signed device directory in Odin | `src/lib/vault/directory_verify.odin`; `src/hub/service/mcp/hosted.odin:14` (`verified_grant_directory`) | Hub can check receipt signatures and current vault id/epoch without any key. |
| MCP JSON-RPC body ≤ 512 KiB, 30 s request window | `src/hub/transport/http/mcp_control_handlers.odin:37,145,153,265` | Bytes cannot ride in tool calls; MCP only negotiates. |

## 3. Client reality

A 15 MiB file is 20,971,520 base64 bytes: it cannot pass through a model's context
(chain dead end). MCP tools therefore only **negotiate** a transfer; bytes move on a
separate HTTPS data path, **and they must be sealed before they leave the trusted
executor**. Who can be the executor decides what each client can do:

| Client | Executor | Upload | Download |
|---|---|---|---|
| Coding agent with a shell running **as a Heimdall agent** on an enrolled bridge (Claude Code, Codex, … launched by Heimdall) | local `ham-ctl` + local bridge keyring/identity | yes | yes (to a local file) |
| Programmatic SDK client on a Heimdall agent host | spawns `ham-ctl` (same as above) | yes | yes |
| Chat-only client (claude.ai web, mobile chat) | the user's **approved, unlocked Heimdall browser tab**, opened from a link | yes, user picks the file | yes, user saves the file |
| Any client on a machine **without** a keyring source | none | **unsupported** | **unsupported** |

The model never sees file bytes in any row; it sees ids, ciphertext digests and
states.

## 4. Data paths

```
UPLOAD
 model ──tools/call artifacts.upload_begin──▶ Hub: transfer row, reserved art_id, token
 model ◀── {transfer_id, artifact_id, upload_url, token, executor hints}
 executor (ham-ctl+bridge │ browser tab)
   read file → validate (size; html-bundle) → seal v2 under current epoch → re-open+compare
   → seal name/description/attestation → sign receipt (device key)
   ──PUT/PATCH ciphertext──▶ Hub staging (ciphertext only, resumable)
   ──POST …/seal {receipt, sealed metadata}──▶ Hub: blind checks → state sealed
 model ──tools/call artifacts.upload_commit──▶ Hub: re-check grant/epoch/receipt, insert artifact
                                              (stored value = the uploaded v2 token)

DOWNLOAD
 model ──tools/call artifacts.download_begin──▶ Hub: transfer row bound to art_id + ciphertext sha256
 model ◀── {transfer_id, download_url, token, ciphertext_sha256, receipt_present, executor hints}
 executor ──GET [Range] ciphertext──▶ Hub serves the STORED v2 token bytes
   verify ciphertext sha256 → open v2 → verify upload receipt + sealed attestation
   → write file atomically (ham-ctl) / save Blob (browser)
   ──POST …/opened {open receipt}──▶ Hub: state delivered (no plaintext, signed)
 model ──tools/call artifacts.transfer_status──▶ {state: delivered, verified_by: device}
```

No key is ever sent to the Hub; there is no transfer-specific key at all. Content
is sealed directly under the vault epoch key the executor already holds, which is
why the stored artifact is a normal v2 value (E4) and why the Hub needs no staging
encryption: everything it stages is already ciphertext.

## 5. Protocol

### 5.1 MCP tools

All tools require a stable `request_id` (except `transfer_status`) and follow the
existing receipt/idempotency rules (`docs/mcp-capabilities.md`, artifact write
section: identical retry → same result, changed arguments → `conflict`, receipt
commits with the native change). Upload tools need `mcp:artifacts:write`; download
tools need `mcp:artifacts:read`; status/cancel need the scope of the transfer's
direction. Legacy `mcp:chains` grants gain nothing. **No transfer tool enters
`hosted_with_access` or sends a device control job**: the transfer path never
opens a keyring on the Hub, even for hosted-mode grants (E1).

**`artifacts.upload_begin`**

```json
{"type":"object","additionalProperties":false,
 "required":["request_id","kind","content_type"],
 "properties":{
  "request_id":{"type":"string","minLength":1,"maxLength":128},
  "kind":{"type":"string","enum":["file","text","markdown","json","html-bundle"]},
  "content_type":{"type":"string","maxLength":255},
  "ext":{"type":"string","maxLength":32},
  "project_id":{"type":"string","maxLength":256},
  "chain_id":{"type":"string","maxLength":256},
  "task_id":{"type":"string","maxLength":256},
  "agent_id":{"type":"string","maxLength":256},
  "agent_instance_id":{"type":"string","maxLength":256}}}
```

There is deliberately **no `name`, `description`, `size_bytes` or `sha256`**
argument: tool arguments reach the Hub in plaintext, so these are supplied to the
executor locally and arrive at the Hub sealed (name, description) or inside the
sealed attestation (plaintext digest). `kind`/`content_type`/`ext` are the same
plaintext metadata columns every artifact already has. `kind = html-bundle`
requires `content_type = application/zip`. Associations are validated now and
again at commit (`content_service.odin:354`, `artifact_context_owned`).

Result:

```json
{"transfer_id":"xfr_…","artifact_id":"art_…","state":"receiving",
 "upload_url":"https://<hub>/api/v1/mcp/transfers/xfr_…",
 "token":"hxt_<43 base64url chars>",
 "limits":{"plaintext_max_bytes":15728640,"ciphertext_max_bytes":20971598,"chunk_max_bytes":8388608},
 "expires_at":"…",
 "executor":{
   "shell":"printf '%s' '<token>' | ham-ctl artifact transfer upload --url <upload_url> --token-stdin --file <path> [--name <n>] [--description <d>] [--entry index.html]",
   "browser_url":"https://<hub>/#/artifact-transfers/xfr_…"}}
```

**Transfer token exposure is accepted by design.** The `hxt_…` token is returned in
a tool result, so it is in the model's context and transcript, and a model-run
shell will usually carry it on its command line or in history. That is acceptable
because the token is a **ciphertext-only, per-transfer, short-lived bearer**: it
addresses one transfer row, expires with it (≤ 60 min, §7), is rotated on
`*_begin` replay and grants no plaintext, no key and no other artifact. Someone
holding it can at most upload ciphertext that will fail the receipt check (they hold
no device key) or fetch ciphertext they cannot open. `--token-stdin` (shown above)
is the documented form because it keeps the token out of `argv`/`ps`; `ham-ctl`
also accepts `--token-env <VAR>`. `ham-ctl` never accepts the token as a flag
value, and never logs it.

`artifact_id` is **reserved** now so the executor's receipt can bind it (§6). Replay
of the same `request_id` returns the same transfer with a freshly minted token
(only `sha256(token)` is stored; the old token stops working); replay after a
terminal state returns the state without a token.

**`artifacts.upload_commit`** `{request_id, transfer_id}` → in the same call,
`{"state":"committed","artifact_id","link":"artifact://art_…","revision","encrypted":true,"ciphertext_bytes","ciphertext_sha256","sealed_by":{"device_id","device_kind"}}`.
Errors: `not_sealed` (**retryable**, `received_bytes` and `state` included: the
executor has not finished), `stale_epoch`, `receipt_invalid`, `ciphertext_invalid`,
`quota_exceeded`, `transfer_expired`, `cancelled`. Retryable errors store no
receipt. Commit does no cryptography beyond SHA-256 and signature verification, so
it is short (no 30 s concern; §7).

**`artifacts.download_begin`** `{request_id, artifact_id}` →

```json
{"transfer_id":"xfr_…","state":"ready","artifact_id":"art_…","revision":"…",
 "download_url":"https://<hub>/api/v1/mcp/transfers/xfr_…","token":"hxt_…",
 "encryption":"vault-v2","ciphertext_bytes":20971589,"ciphertext_sha256":"…",
 "receipt_present":true,"kind":"html-bundle","content_type":"application/zip",
 "expires_at":"…","max_fetches":8,
 "executor":{
   "shell":"printf '%s' '<token>' | ham-ctl artifact transfer download --url <download_url> --token-stdin --expect-artifact art_… -o <path>",
   "browser_url":"https://<hub>/#/artifact-transfers/xfr_…"}}
```

`receipt_present` is **advisory** (it tells the model what to expect); executors never
rely on it (§5.3 receipt policy).

The Hub computes `ciphertext_sha256` over the stored bytes at begin; the transfer is
bound to that digest and the artifact `revision`. Native artifact content is
immutable, so the stored token is the snapshot; artifact deletion ends the transfer
(`GET` → `410`). `encryption = "none"` (a legacy plaintext artifact in a vault
account) is **refused** with `not_encrypted`: the bytes were never E2EE and the
transfer path does not pretend otherwise; the native download route remains.
Accounts with no vault get `vault_required` for every transfer tool.

**`artifacts.transfer_status`** `{transfer_id}` →
`{state, direction, received_bytes, ciphertext_bytes, expires_at, error?, sealed_by?, opened_by?:{device_id, device_kind, verification:"verified"|"unverified", verified:bool, at}}`
(`verified` is true only for a signed `verified` result, §6.3).

**`artifacts.transfer_cancel`** `{request_id, transfer_id}` → `{state:"cancelled"}`;
idempotent; deletes staging immediately.

States: upload `receiving → sealed → committed`; download `ready → delivered`
(an open receipt arrived; further fetches still allowed until TTL/`max_fetches`);
any non-terminal → `cancelled | expired | failed`. Terminal rows keep metadata for
24 h for idempotent replay, then are purged.

### 5.2 Transfer HTTP data path

Route family `/api/v1/mcp/transfers/{transfer_id}`, registered beside
`mcp_control_register_routes` (`mcp_control_handlers.odin:38`). Authentication is
**either** `Authorization: Bearer hxt_…` (shell executor) **or** the native
same-origin browser session plus approved-device request proof (browser executor,
the pattern already required for browser wrap delivery, `docs/mcp-hosted-vault.md`
"Browser sessions require same-origin POSTs and approved device proof"). OAuth MCP
access tokens are not accepted. There is **no `?t=` query token** and no
unauthenticated link.

| Method + path | Direction | Purpose |
|---|---|---|
| `GET /{id}` (`Accept: application/json`) | both | descriptor: `{transfer_id, direction, artifact_id, owner_user_id, vault_id, current_epoch, kind, content_type, ext, state, received_bytes, ciphertext_bytes?, ciphertext_sha256?, limits, expires_at}` |
| `PUT /{id}/ciphertext` | upload | whole token, only when `received_bytes = 0`; `Content-Length` required, ≤ 20,971,598 |
| `PATCH /{id}/ciphertext` | upload | append; `Upload-Offset` must equal `received_bytes` (else `409` + current offset); body 1 B … 8 MiB |
| `HEAD /{id}/ciphertext` | both | upload: `Upload-Offset`; download: `Content-Length`, `Accept-Ranges: bytes`, `Repr-Digest: sha-256=:<b64 of ciphertext sha256>:` |
| `POST /{id}/seal` | upload | JSON `{receipt, signature, device_id, name_token, description_token, attestation_token}` → `sealed` |
| `GET /{id}/ciphertext` | download | stored v2 token bytes, `200` or `206` single range; `Content-Type: application/octet-stream`, `Content-Disposition: attachment`, `Cache-Control: no-store`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `Repr-Digest`; counts toward `max_fetches` |
| `POST /{id}/opened` | download | JSON open receipt (§6.3) → `delivered` |
| `DELETE /{id}` | both | cancel |

Bodies are bounded before reading (≤ 8 MiB PATCH, ≤ 20,971,598 PUT, the PUT
streamed to chunk rows rather than buffered), stay far below the shared 80 MiB
reader cap (`artifact_limits.odin`), and are admitted only under the global
data-path semaphore (§7). Ciphertext bodies are
never parsed as JSON; only the small `seal`/`opened` bodies are (≤ 64 KiB).

### 5.3 Executor flows

**Shell (`ham-ctl artifact transfer upload`)**, inside a Heimdall agent:

1. Read the token from stdin (`--token-stdin`) or a named env var (`--token-env`),
   never from a flag value. `GET` the
   descriptor; refuse unless `direction = upload`, `state = receiving`, and
   `owner_user_id`/`vault_id` equal the local keyring's (`ctl_read_vault_keyring`,
   `src/ctl/vault.odin:74`). The keyring's current epoch must equal the descriptor's
   `current_epoch` (else refresh/stop: `stale_epoch`).
2. Read the file; refuse > 15,728,640 B (`ctl_artifact_content_size_error`,
   `src/ctl/agent_mode.odin:768`). For `html-bundle`, run the existing ctl validator
   (`src/ctl/html_bundle.odin`: `html_bundle_parse_zip`, member allowlist, entry,
   manifest, 50 MiB expansion bound). No Hub-side validator is needed.
3. `vault.seal` the bytes (one v2 token), re-open it and compare SHA-256, wipe the
   re-opened copy. Seal `name` (default: file basename), `description`, and the
   attestation JSON (§6.2) as separate v2 tokens under the same epoch.
4. Ask the local bridge to sign the receipt statement (new local RPC
   `agent.vault.sign_transfer_receipt`, §6.1).
5. `PUT` (or resumable `PATCH`es with `HEAD` probes), then `POST …/seal`. Print a
   JSON line `{transfer_id, artifact_id, state:"sealed", ciphertext_sha256}` for the
   model, which then calls `artifacts.upload_commit`.

**Shell download (`ham-ctl artifact transfer download --expect-artifact art_… -o out`)**:
`GET` descriptor (must match `--expect-artifact`, owner, vault), fetch ciphertext
with `Range` resume into a temp file next to `out`, verify `ciphertext_sha256`,
`vault.open`, fetch the upload receipt + attestation (included in the descriptor
when `receipt_present`), verify via bridge RPC `agent.vault.verify_transfer_receipt`
(signature under the bridge's verified directory, artifact id = expected,
ciphertext digest equal, attestation opens and its plaintext SHA-256/size match),
`fsync` + rename, wipe buffers, `POST …/opened` with result `verified`.

**Receipt policy (normative).** `receipt_present`, the receipt and the attestation
all come from the Hub, so the executor treats them as **untrusted input**: a
malicious Hub can claim `receipt_present:false` and serve any other same-vault v2
token, which GCM opens fine (v2 AAD binds only vault id + epoch, §2). Therefore:

- `ham-ctl artifact transfer download` is **verified-only**. With no receipt, or a
  receipt that fails any check, it writes **no output file** (the temp file is
  removed), posts no open receipt, prints
  `{"transfer_id","artifact_id","verification":"receipt_absent"|"receipt_invalid"}`
  and exits with status `3`. There is deliberately **no flag** to accept unverified
  bytes on the transfer path: the shell command line is copied from a Hub-supplied
  hint (`executor.shell`), so an escape flag would be one the Hub could inject.
  `ham-ctl` also ignores any unknown flag in that hint (hard error).
- Artifacts that legitimately have no receipt (everything created before this
  feature, and anything created through the native `ham-ctl artifact create`, UI
  upload or MCP text tools) are read through the **existing native** path
  (`ham-ctl artifact download`, the web viewer), which offers the same
  vault+epoch-only integrity it offers today and never claims more.
  `download_begin` still serves them; the shell executor refuses them with
  `receipt_absent` and its message names the native command.
- The browser page shows a receipt-less or invalid-receipt download as a
  distinct **Unverified origin** state (warning panel, no Save button). Saving
  requires a second, explicit user action ("Save unverified copy"), and the page
  then posts an open receipt with result `unverified`. An invalid receipt
  (signature/fields/attestation mismatch) is never saveable.
- `transfer_status` reports `opened_by.verification` exactly as signed
  (`verified` | `unverified`); the Hub sets `state = delivered` for both but
  `opened_by.verified = true` **only** for `verified`, and the result field is part
  of the signed statement, so the Hub cannot upgrade it.

**Browser (`#/artifact-transfers/<id>`)**: the user opens the link in their own
signed-in Heimdall tab. The page requires an approved, unlocked device (existing
`DeviceVaultScreens` flow) and shows the transfer's direction, kind, associations
and expiry before anything happens. Upload: user picks a file → size check →
`readHtmlBundle` for bundles → `encryptVaultBytes` + re-open compare → seal
metadata/attestation → receipt signed with `signP256` → chunked `PATCH` with resume
→ `POST seal`. Download: fetch ciphertext → digest → `decryptVaultBytes` → verify
receipt with the browser directory verifier (`vaultDirectoryVerify.ts`) → save via a
Blob `download` link (plaintext never leaves the tab) → `POST opened`; a missing or
invalid receipt follows the receipt policy above (Unverified origin state). Nothing in
the page renders artifact HTML; bundles are saved as `.zip` (the viewer remains the
place to view them, with its script-disabled sandbox).

### 5.4 Hub-side blind checks at `seal` and again at `upload_commit`

All without keys:

1. Staged bytes form exactly one canonical token: prefix `vault:v2:`, 16 lowercase
   hex vault id, `:e` + `parse_epoch` grammar, `:`, strict base64 alphabet with
   correct padding and length (streamed over chunks; no decode buffer).
2. `vault_id` = owner's vault from the verified directory; `epoch` = the directory's
   **current** epoch at commit time (rotation in between → `stale_epoch`, transfer
   `failed`; the executor starts a new transfer — a re-seal is unavoidable).
3. Decoded payload length = `3·L/4 − padding`; plaintext length = payload − 28;
   require `1 ≤ plaintext ≤ 15,728,640`, so the 15 MiB limit is exact although the
   Hub never decrypts.
4. SHA-256 of staged bytes = receipt `ciphertext_sha256`; `received_bytes` =
   receipt `ciphertext_bytes`.
5. Receipt: canonical, domain-separated, fields equal to the transfer row (owner,
   vault, epoch, transfer id, reserved artifact id, kind, content type), signature
   valid for a device that is **currently trusted** in the verified directory with a
   kind allowed to seal (bridge or browser device), `issued_ms` within the transfer
   lifetime, not previously used (unique per transfer).
6. `name_token`, `description_token`, `attestation_token` are canonical tokens of
   the same vault/epoch, their SHA-256 values match the receipt, and they respect
   the existing name/description armored caps.
7. At commit only: live grant/family/account recheck (same liveness as MCP writes),
   CAS `sealed → committed`, `create_artifact` with the reserved id and the token as
   content, receipt row and MCP receipt — one transaction. The native `sha256`
   column stays **empty** (a plaintext digest in clear would allow confirmation
   attacks); the ciphertext digest lives in the receipt table.

## 6. Receipts

### 6.1 Upload receipt (signed by the sealing device)

Newline-joined canonical statement, every field a restricted single-line value
(same style as `control_reply_statement`, `control_job.odin:37-40`):

```
heimdall-artifact-transfer-receipt/v1
seal
<owner_user_id>
<vault_id>
e<epoch>
<transfer_id>
<artifact_id>
<kind>
<content_type>
<ciphertext_bytes>
<ciphertext_sha256>
<sha256(name_token)>
<sha256(description_token)>
<sha256(attestation_token)>
<device_id>
<issued_ms>
```

Signature: P-256 with the device identity key (bridge: enrolled identity via
`bridge_*_sign` with an allowlisted prefix; browser: `signP256`). The bridge's new
local RPC `agent.vault.sign_transfer_receipt` accepts only this exact grammar with
`seal`/`open` verbs and its **own** owner/vault/device id, and signs nothing else;
it is reachable only with an agent token, the same trust that already receives the
whole keyring (`src/ctl/vault.odin:16-18`).

### 6.2 Sealed attestation (opened only by key holders)

`attestation_token = seal(JSON{"v":1,"plaintext_bytes":N,"plaintext_sha256":"…","kind":…,"bundle":{"validator":"html-bundle/v1","entry":"index.html","members":k}|null})`.
Downloaders open it and compare against the decrypted bytes, so even a
same-vault ciphertext swap or a receipt replayed onto another artifact is detected
(receipt binds artifact id; attestation binds plaintext). The Hub stores it opaque.
This protection needs the receipt to be present; a Hub that strips it is handled by
the executor receipt policy (§5.3), not by the attestation.

### 6.3 Open receipt (signed by the downloading device)

```
heimdall-artifact-transfer-receipt/v1
open
<owner_user_id>
<vault_id>
e<epoch of the served token>
<download transfer_id>
<artifact_id>
<verified|unverified>
<ciphertext_bytes served>
<ciphertext_sha256 served>
<device_id>
<issued_ms>
```

The result line is covered by the signature. `unverified` is produced only by the browser after the user's explicit
"Save unverified copy"; `ham-ctl` never produces it. Failures and refusals are not
signed or posted (the executor reports them locally); the transfer stays `ready`.
The Hub verifies the signature and directory trust and sets `delivered`;
`transfer_status` reports `opened_by.verification` from the signed field and
`verified:true` only when it says `verified` — the model learns *whether* a trusted
device got verified bytes, never the bytes.

### 6.4 What the receipts prove

| Attack by a malicious Hub | Detected by |
|---|---|
| Read content, name, description | impossible: no key (E1) |
| Flip/truncate ciphertext | GCM tag + ciphertext digest |
| Serve another same-vault artifact's ciphertext **with** its receipt | receipt artifact id ≠ expected; attestation digest → refused |
| **Strip the receipt** (`receipt_present:false`) and serve another same-vault token | `ham-ctl`: refused (`receipt_absent`, exit 3, no file); browser: Unverified-origin state, saved only on explicit user confirmation and reported `unverified`, never `verified` (§5.3 receipt policy) |
| Substitute content of a **receipt-less** artifact (pre-existing / native-path artifacts) | **not detected** by any reader — v2 AAD binds only vault+epoch. Same as every native reader today; the transfer path refuses (shell) or labels (browser) these, it does not protect them |
| Replay a receipt for another transfer | transfer/artifact ids in signed statement; unique per transfer |
| Forge a receipt | needs a trusted device key; executors verify against their **own** verified directory, not the Hub's word |
| Downgrade to a stale/old epoch | blind check 2 at the Hub; executors seal only under their verified current epoch |
| Confirm a guessed file | no plaintext digest in clear |
| Learn size | **not prevented** (ciphertext length, inherent in v2; same as today) |

Substitution protection therefore exists **only for artifacts committed through a
transfer with a verified receipt, and only on the transfer download path**. Closing
the gap for all artifacts needs an envelope whose AAD binds the artifact id (a v3
format plus migration of every reader) — out of scope here because E4 keeps v2.

## 7. Bounds, overhead and resources

| Bound | Value |
|---|---|
| Plaintext per artifact | ≤ 15,728,640 B, enforced blind (§5.4.3) |
| Ciphertext per upload | ≤ 20,971,598 B (`vault_armored_max_bytes`); overhead = 28 B nonce+tag, ×4/3 base64, ≤ 38 B header → **×4/3 + ≤ 78 B** (≈ 33.3 %; 15 MiB → 20,971,589 B at a 1-digit epoch) |
| Request size | PATCH ≤ 8 MiB (3 PATCHes for 15 MiB), PUT ≤ 20,971,598, `seal`/`opened` JSON ≤ 64 KiB |
| Active transfers per owner | ≤ 2 uploads, ≤ 4 downloads |
| Staged ciphertext | per owner ≤ 48 MiB, global ≤ 512 MiB (config `mcp_transfer_staging_max_bytes`); downloads stage nothing |
| TTL | idle 15 min since last byte, absolute 60 min since begin; janitor ≤ 60 s |
| Download fetches | ≤ 8 full-or-ranged GETs; ≤ 2 concurrent GETs per owner |
| Rate limits | per grant ≤ 10 `*_begin` / hour, ≤ 60 data-path requests / minute |
| Data-path concurrency (**global**, all owners) | ≤ 8 in-flight body-carrying requests (`PUT`/`PATCH`/`GET …/ciphertext`), config `mcp_transfer_data_path_max_concurrent`; a counting semaphore acquired **before** reading the request body or touching SQLite. Full → `503 Service Unavailable` + `Retry-After: 2` and JSON `{error:"busy", retry_after_ms:2000}`, nothing read or written; executors retry with jittered backoff (≤ 5 tries, then report `busy`). Per-owner limits above still apply first (`429` + `Retry-After`). Commits: ≤ 2 concurrent globally (separate semaphore), MCP result `busy` with `retry_after_ms`, retryable, no receipt stored |
| Hub memory | upload: `PUT` and `PATCH` bodies (bearer `hxt_` executor) are streamed to chunk rows in ≤ 1 MiB pieces (never a body buffer; *as implemented*, stricter than the original 8 MiB `PATCH` buffer); browser-executor (session + device proof) bodies are limited to one ≤ 1 MiB window per request (`413 browser_chunk_size` otherwise) because the v2 proof signs `sha256(body)` and must be verified before any byte is appended — the browser uploads with `PATCH`+`Upload-Offset` in ≤ 1 MiB windows; download `GET`: streamed from SQLite in ≤ 1 MiB windows (`substr(CAST(content AS BLOB), off+1, 1048576)` on the artifact row, same row/owner predicates as `artifact_bounded.odin:8-24`), never a full-value copy; commit concatenates chunk rows into one ≤ 21 MiB value (≈ 42 MiB peak with the bound-parameter copy). **Global worst case** = 8 × 8 MiB (data path) + 2 × 42 MiB (commits) ≈ **148 MiB**, independent of owner count — **no cryptographic buffers, no keyring** |
| Slot holding (*as implemented*) | A request that holds a data-path slot can never wait on its peer without bound: the browser branch checks session, `Origin`, device-proof headers and transfer ownership **before** reading any body byte (unauthenticated → `401`/`403`/`404` with no read); the server sets a 30 s socket receive/send idle timeout on every slot holder, and a streamed body must complete within 30 s + declared length ÷ 64 KiB/s (15 MiB ≈ 270 s). Idle or deadline expiry ends the read like an early close: the bytes received are kept (resume offset), `400 incomplete_body` + `Upload-Offset`, and the slot is released (`STREAM_BODY_*` in `server.odin`, injectable via `Pre_Body_Gate` for tests) |
| Executor memory | ≈ 72 MiB peak for a 15 MiB seal (plaintext + payload + base64 + token, `envelope.odin:246-262`), local to the user's machine or tab |
| Storage | staging rows deleted at commit/TTL; persisted artifact identical in size to a `ham-ctl` sealed upload; receipt row ≈ 2 KiB |

## 8. Unsupported client capabilities (explicit)

- **No Hub-side crypto fallback.** If no executor is available the transfer simply
  never reaches `sealed`; there is no hosted or device-job path that would expose
  plaintext to the Hub.
- **Shells without a keyring source**: a terminal on a bridge host that is not a
  Heimdall agent (no agent token), or any machine without an enrolled bridge.
  `ham-ctl` refuses with `vault_unavailable`. Making plain user shells executors
  needs a user-authenticated local bridge channel — a separate design.
- **Chat-only clients** cannot read or produce file bytes themselves; they hand the
  user a `browser_url` and wait (`transfer_status`). If the user has no approved,
  unlocked browser tab, the transfer expires.
- **Model reading content**: bytes never enter the model context; a model can learn
  only metadata, ciphertext digests and verification status.
- **Unvaulted accounts** (`vault_required`) and **legacy plaintext artifacts**
  (`not_encrypted`): out of scope for E2EE transfers.
- **Verified download of receipt-less artifacts**: sealed artifacts created before
  this feature or through native paths have no receipt. The shell executor refuses
  them (`receipt_absent`, use `ham-ctl artifact download`); the browser saves them
  only as an explicitly confirmed `unverified` copy. Their content can be
  substituted by a malicious Hub with another same-vault token without detection,
  exactly as for every native reader today (§6.4).
- **Remote placement** (asking a bridge on another machine to write a download to
  its disk, or to read a path on its disk for upload): not offered — the Hub would
  be choosing local paths on a user machine.
- **Mobile browsers**: work if the tab is an approved device and can hold ≈ 72 MiB;
  otherwise unsupported.
- **Pre-existing MCP text tools are not changed by this design and are not strict
  E2EE**: `artifacts.create/get` content in device mode returns/accepts plaintext
  through the Hub (device job results), and in hosted mode the Hub decrypts
  (`docs/mcp-remote-control.md` "Decryption modes"). Flagged for a separate
  decision; out of this ticket's scope.

## 9. Retries, replay, cancellation, failure

- **Tool calls**: idempotent by `request_id`; commit is a CAS `sealed → committed`
  in the same transaction as the artifact insert and MCP receipt, so concurrent or
  ambiguous commits yield exactly one artifact and the same result on replay.
- **Data path**: upload resumes from `HEAD` `Upload-Offset`; wrong offset → `409`
  with the current offset; a duplicate `seal` with the identical receipt returns
  `200` (idempotent), a different receipt after `sealed` → `409`. Download resumes
  with `Range` against the fixed `ciphertext_sha256`.
- **Executor crash** mid-upload: `ham-ctl` writes the sealed token to a temp file
  and a resume record (`<file>.heimdall-transfer`: transfer id + ciphertext digest;
  no key, no plaintext) **before** the first byte is sent, so a re-run resumes the
  **same** token from `Upload-Offset`. Without that record (or after the browser tab
  was closed) and `received_bytes > 0`, the executor cancels and the model begins a
  new transfer: a fresh seal produces different ciphertext (new nonce), which cannot
  continue a partial upload. With `received_bytes = 0` it simply re-seals.
- **Cancellation**: `artifacts.transfer_cancel`, `DELETE`, or the user's Cancel in
  the browser page; staging deleted in one transaction.
- **Replay protection**: tokens are 32 random bytes, stored as `sha256`, rotated on
  `*_begin` replay; receipts are bound to one transfer and one artifact; open
  receipts must name the ciphertext digest the transfer served; transfer rows are
  per grant, so another grant's token or session never addresses them (`404`).
- **Revocation**: grant/family/account revocation fails every data-path request
  of that grant with `401` and deletes staging. A device revoked between `seal` and
  `commit` → `receipt_invalid` at commit.
- **Failure**: any blind-check failure → `failed`, staging deleted, nothing
  inserted. Hub restart loses nothing (staging is ordinary ciphertext rows) —
  unlike the superseded design, transfers survive restarts.

## 10. Why the previous design (9bd7b372) is superseded

It staged **plaintext** (under a Hub-memory key `K_t`), had the Hub hash and
validate plaintext, sealed/opened in `hosted_with_access` with the grant's keyring,
re-staged plaintext for downloads and offered `browser_url = download_url?t=token`
that returned plaintext. Every one of those violates E1/E3. Kept from it: scoped
per-transfer bearer tokens, resumable offset uploads, ranged downloads, request-id
idempotency, monolithic v2 storage, quotas/TTL and the "bytes never through the
model" rule. Dropped: `K_t`, Hub-side bundle validation (the shared `src/lib`
validator ticket), hosted/device seal-open jobs, plaintext `sha256`/`size_bytes`
tool arguments, `?t=` links.

## 11. Storage and compatibility

Migration `187_mcp_artifact_transfers.sql` (next after
`src/hub/repository/sqlite/migrations/186_extension_version_sync_0_5_36.sql`):

```sql
CREATE TABLE mcp_transfers (
  transfer_id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL, client_id TEXT NOT NULL,
  grant_id TEXT NOT NULL, family_id TEXT NOT NULL,
  direction TEXT NOT NULL CHECK (direction IN ('upload','download')),
  state TEXT NOT NULL, error TEXT NOT NULL DEFAULT '',
  token_sha256 TEXT NOT NULL,
  artifact_id TEXT NOT NULL,             -- reserved (upload) or target (download)
  artifact_revision TEXT NOT NULL DEFAULT '',
  request_id TEXT NOT NULL, request_digest TEXT NOT NULL,
  kind TEXT NOT NULL, content_type TEXT NOT NULL, ext TEXT NOT NULL DEFAULT '',
  associations TEXT NOT NULL DEFAULT '{}',
  vault_id TEXT NOT NULL, epoch INTEGER NOT NULL,
  received_bytes INTEGER NOT NULL DEFAULT 0,
  ciphertext_bytes INTEGER NOT NULL DEFAULT 0, ciphertext_sha256 TEXT NOT NULL DEFAULT '',
  fetches INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL, touched_at TEXT NOT NULL, expires_at TEXT NOT NULL,
  UNIQUE (owner_user_id, client_id, request_id)
);
CREATE INDEX mcp_transfers_expiry ON mcp_transfers(state, expires_at);
CREATE TABLE mcp_transfer_chunks (            -- ciphertext only
  transfer_id TEXT NOT NULL REFERENCES mcp_transfers(transfer_id) ON DELETE CASCADE,
  chunk_index INTEGER NOT NULL, offset INTEGER NOT NULL, bytes BLOB NOT NULL,
  PRIMARY KEY (transfer_id, chunk_index)
);
CREATE TABLE artifact_transfer_receipts (     -- outlives the transfer
  artifact_id TEXT PRIMARY KEY, owner_user_id TEXT NOT NULL,
  statement TEXT NOT NULL, signature TEXT NOT NULL, device_id TEXT NOT NULL,
  attestation_token TEXT NOT NULL, ciphertext_sha256 TEXT NOT NULL,
  created_at TEXT NOT NULL
);
```

The receipt row is deleted with its artifact. Read compatibility: artifacts created
by transfer are ordinary sealed artifacts (name/description/content are v2 tokens),
indistinguishable to the web UI, the bundle viewer, `ham-ctl artifact show/download`
and native content GET. `artifacts.get` (metadata) gains `receipt_present` and, for
content it cannot inline, the hint `"download": "artifacts.download_begin"`. Old Hub
versions ignore the new tables; rollback = drop them.

## 12. Validation plan (tests proving Hub-blind transfers)

All Odin tests under `nix develop --command odin test … -collection:odin_test=src`.

1. **Hub holds no key (structural)**: a static test asserts that the transfer
   service, data-path handlers and MCP transfer tools do not reference
   `hosted_with_access`, `vault.open*`, `vault.seal*`, keyring types or control-job
   enqueueing (same style as existing source-scan tests).
2. **Hub-blind round trip**: test Hub built with hosted decryption **disabled** and
   no keyring; a test executor holding a synthetic keyring uploads a
   15,728,640-byte random non-UTF-8 payload seeded with marker strings, commits,
   downloads and opens it → byte-exact. Then scan the SQLite file, WAL, every staged
   row, transfer row, receipt row, captured logs and HTTP responses: none contains
   the plaintext markers, the plaintext SHA-256, or the name/description; the
   stored content is exactly the uploaded token.
3. **Blind limit**: plaintext 15,728,640 accepted, 15,728,641 rejected by token
   length arithmetic; malformed base64/padding, wrong vault id, stale epoch, two
   concatenated tokens → `ciphertext_invalid`/`stale_epoch`.
4. **Receipts**: wrong signer, revoked device, field mismatch, receipt replay onto
   another transfer, reused receipt, digest mismatch → rejected; Odin ↔ WebCrypto
   cross-runtime vectors for statement, signature and attestation.
5. **Tamper on download**: Hub test double serves (a) a flipped byte, (b) another
   same-vault artifact's token, (c) a different receipt → executor refuses in all
   three, writes no output file, posts no open receipt. (d) **Receipt strip**: the
   double reports `receipt_present:false`, omits receipt/attestation and serves
   another same-vault token for the requested artifact → `ham-ctl` exits 3 with
   `verification:"receipt_absent"`, no output file, no open receipt; the browser
   page shows Unverified origin with no Save button, and only after the explicit
   confirm posts an open receipt whose signed result is `unverified`; the Hub's
   `transfer_status` then reports `verified:false` (an attempt to post `verified`
   with that signature fails verification). (e) The `executor.shell` hint with an
   injected unknown flag (e.g. `--allow-unverified`) is rejected by `ham-ctl`.
6. **Data path**: PUT, PATCH resume, wrong offset `409`, overrun rejected, `Range`
   reassembly, `max_fetches`, TTL expiry, quotas, cancel deletes chunks, restart
   keeps staging, revoked grant → `401` + wipe, cross-owner → `404`, headers
   (`no-store`, `nosniff`, `attachment`, `Repr-Digest`), no `?t=` accepted.
   **Global overload**: with the data-path semaphore held at its limit by other
   owners, a ninth request gets `503` + `Retry-After` before its body is read
   (assert no chunk row written, request body not consumed beyond headers); a
   third concurrent commit gets MCP `busy` with no receipt and succeeds on retry;
   a `GET` of a 15 MiB artifact allocates no buffer > 1 MiB (tracking allocator)
   and a `PUT` of 20,971,589 B lands as ≤ 1 MiB chunk rows.
7. **MCP tools**: schemas reject `name`/`sha256`/`size_bytes`; scope gating;
   idempotent replay with token rotation; concurrent commits → one artifact;
   `not_sealed` retryable without a receipt; hosted-mode grant still never enters
   `hosted_with_access` (spy).
8. **HTML bundle**: `ham-ctl` and browser executors reject invalid bundles before
   any byte is uploaded; a committed 15 MiB bundle opens in the viewer flow
   (`tests/ui_html_bundle_test.ts`) with scripts still disabled.
9. **Executors**: `src/ctl` tests for upload/download/resume with a fake Hub and
   `--vault-keyring`; bridge RPC signs only the receipt grammar for its own
   owner/vault/device; UI `node --test` for the transfer page logic
   (seal/receipt/open with WebCrypto, Blob save, no network call carries plaintext —
   asserted by a fetch spy).
10. **Manual (no deploy in this chain)**: local Hub + Heimdall-agent Claude Code
    session using the documented `ham-ctl` flow; browser link flow in a local UI.
11. **REQ-CROSS-DEVICE (two devices, one vault)**: isolated test owner with a
    synthetic vault and two approved devices, A (bridge + `ham-ctl` executor) and B
    (browser/WebCrypto device), sharing the keyring via the existing synced-vault
    wrap mechanism (no test-only key path on the Hub). (a) A uploads a 15,728,640 B
    binary file and a 15 MiB HTML bundle through the full MCP tools + HTTP flow and
    commits. (b) A **disconnects** (bridge stopped, its sessions revoked from the
    test Hub's live set) and the transfer janitor runs past staging TTL so every
    `mcp_transfer_chunks` row and transfer token is gone. (c) B in a **fresh
    session** lists the artifacts (sealed names open on B), downloads via the
    native content route **and** via a new `download_begin` transfer → byte-exact,
    receipt `verified` with A as sealer, and the bundle renders in the viewer
    (`HtmlBundlePreview`) with scripts disabled. (d) B locked → open requires
    unlock first; another owner → `404`; B revoked → no keyring delivery and
    transfer data path `401`; a vault epoch rotation after commit → B (current
    keyring keeps every epoch entry, `src/lib/vault/keyring.odin:8-9,185-189`)
    still opens it, and a new upload sealed under
    the old epoch fails `stale_epoch`. (e) The §12.2 plaintext-marker scan is
    repeated over the Hub DB/WAL/logs/HTTP captures of the whole two-device run.
    Over-limit (15,728,641 B) is rejected by A before any byte is sent and, when
    forced by a test executor, by the Hub's blind check.

## 13. Implementation tickets (staged; replace T1–T6 of 9bd7b372)

| # | Ticket | Depends | Exact source files |
|---|---|---|---|
| X1 | Receipt + blind-token library | – | new `src/lib/vault/transfer_receipt.odin` (statement build/parse, attestation JSON, verify against `Verified_Directory`), new `src/lib/vault/envelope_blind.odin` (streaming canonical-token check, plaintext-length arithmetic) + tests; new `src/ui/utils/artifactTransferReceipt.ts` + `tests/ui_artifact_transfer_receipt_test.ts` (cross-runtime vectors) |
| X2 | Transfer storage + service | X1 | `src/hub/repository/sqlite/migrations/187_mcp_artifact_transfers.sql`, repo procs beside the MCP repository, new `src/hub/service/mcp/transfers.odin` (state machine, quotas, TTL janitor, blind checks §5.4, commit with reserved id), `src/hub/service/content/content_service.odin` (create with reserved id; receipt row delete with artifact) |
| X3 | Transfer HTTP data path | X2 | new `src/hub/transport/http/mcp_transfer_handlers.odin` (+ registration next to `mcp_control_register_routes`, `mcp_control_handlers.odin:38`), session + device-proof auth for browser, token auth for shell, rate limits, headers; tests §12.6 |
| X4 | MCP tools | X2, X3 | `src/hub/service/mcp/catalog.odin`, `capabilities.odin`, `transfers.odin`, `src/hub/transport/http/mcp_resource_arguments.odin`, `mcp_control_handlers.odin` (dispatch, no hosted path), `src/hub/app/mcp_artifacts.odin`, `src/hub/service/mcp/artifacts.odin` (`receipt_present`, download hint); tests §12.1-3, §12.7 |
| X5 | Bridge + `ham-ctl` executor | X1, X3 | `src/bridge/agent_api.odin` (`agent.vault.sign_transfer_receipt`, `agent.vault.verify_transfer_receipt`), `src/bridge/unseal_protocol.odin` (allowlisted receipt prefix beside `bridge_mcp_sign_result`), new `src/ctl/artifact_transfer.odin` (`ham-ctl artifact transfer upload|download|status|cancel`, reusing `ctl_read_vault_keyring`, `vault.seal/open`, `src/ctl/html_bundle.odin`); tests §12.5, §12.8-9 |
| X6 | Browser executor | X1, X3 | new `src/ui/components/ArtifactTransferPage.tsx`, hash route in the app router (`src/ui/utils/appLocation.ts` grammar), reuse `encryptVaultBytes`/`decryptVaultBytes` (`vaultCrypto.ts`), `readHtmlBundle`, `vaultDirectoryVerify.ts`, device identity signing; `AGENTS.md` test-id table; tests §12.8-9 |
| X7 | Docs, skills, threat model | X4-X6 | `docs/mcp-capabilities.md` (transfer tools; state that text tools are not strict E2EE), `docs/html-bundle-artifacts.md` (upload paths), `docs/mcp-remote-control.md`, artifact-authoring + ham-ctl-reference skills (executor commands), this plan → "implemented" |

X1–X5 deliver the shell path; X6 adds chat-only clients via the browser. Each
ticket keeps the chain rules: source only, no push/deploy/restart/live mutation.

### 13.1 Mapping onto the chain's staged tickets

X1–X7 are work packages, not new tickets; they are assigned to the three staged
tasks (each task got a comment with this split):

| Staged task | Packages | Also owns | Tests it must deliver |
|---|---|---|---|
| `task_18e442d120604cf4` — ciphertext-only storage + HTTP | **X1 (Odin half)**, **X2**, **X3** | `src/contracts/artifacts.odin` (ciphertext max = `vault_armored_max_bytes(ARTIFACT_MAX_CONTENT_BYTES)`, chunk max, transfer limits beside `ARTIFACT_MAX_CONTENT_BYTES`), `src/hub/transport/http/artifact_limits.odin` (data-path body bounds), global data-path/commit semaphores and `503`/`busy` (§7) | §12.1 (structural no-key scan for service + handlers), §12.3, §12.4 (Odin side), §12.6 incl. global overload; Hub-blind upload/commit with a **test executor** (synthetic keyring in test code only) |
| `task_18e442d6e89f4103` — MCP tools + trusted clients | **X4**, **X5**, **X6**, **X1 (TS half**: `artifactTransferReceipt.ts` + cross-runtime vectors) | receipt policy (§5.3: verified-only `ham-ctl`, browser Unverified-origin state, signed `verified|unverified`), `--token-stdin`, resume record, bundle validation in both executors | §12.1 (MCP tool scan), §12.2, §12.4 (cross-runtime vectors), §12.5 incl. (d)/(e) receipt strip, §12.7, §12.8 (executor rejection), §12.9 |
| `task_18e442dc5048dd2a` — cross-device + integration | **X7** | UI listing/viewer compatibility for transfer-created artifacts (`src/ui/api/endpoints/artifacts.ts`, `ArtifactViewer.tsx`, `HtmlBundlePreview.tsx`, `src/ui/utils/htmlBundle.ts`), user/agent guidance and limitations (`docs/mcp-capabilities.md`, `docs/html-bundle-artifacts.md`, skills) | **§12.11 (REQ-CROSS-DEVICE)**, §12.8 viewer half, §12.2 repeated end to end, §12.10 manual, over-limit through the full flow |

Invariants every one of the three tasks carries: no transfer code path calls
`hosted_with_access`, `vault.open*`/`vault.seal*` on the Hub, or enqueues a device
control job; the Hub stores and serves ciphertext only and checks it blind (§5.4);
no plaintext digest/name/description in clear; no `?t=` or plaintext URL; tokens
stored as `sha256` only.

## 14. Decisions and open items

- **Decided:** strict E2EE — no Hub-side seal/open for transfers, in any mode;
  executors are the only key holders.
- **Decided:** seal directly under the vault epoch key (no transfer key, no key
  exchange through the Hub); persisted value stays a normal v2 token.
- **Decided:** integrity beyond GCM through signed device receipts plus a sealed
  attestation; the plaintext digest is never stored or sent in clear.
- **Decided:** Hub enforces the 15 MiB decoded limit blind from token length.
- **Decided:** the Hub's receipt claims are untrusted; the shell transfer download
  is verified-only with no escape flag, the browser labels and gates unverified
  saves, and receipt-less artifacts get no substitution protection (v2 limitation).
- **Decided:** Hub memory is bounded globally (data-path and commit semaphores,
  `503`/`busy`), not only per owner; downloads stream in ≤ 1 MiB windows.
- **Decided:** HTML bundle validation happens in the executor (ctl validator /
  `readHtmlBundle`) and again in the viewer; the Hub cannot and does not validate.
- **Open (user):** whether to keep, restrict or redesign the existing non-E2EE MCP
  text content tools (§8, last bullet).
- **Open (user):** whether plain user shells on bridge hosts should become
  executors (needs a user-authenticated local bridge channel).
- **Open (assumption):** per-client rendering of `browser_url` links in chat
  clients; verify in X7 against each client's docs.
