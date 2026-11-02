# MCP large artifact transfers (15 MiB files and HTML bundles)

Status: **design, not implemented.** Task `task_18e4411ea03fd52a`, chain
`chain_18e43a321b7b6c60` (REQ-ART-1/REQ-ART-2). It unblocks
`task_18e43fc82ae1bc46` (close the MCP large-artifact and HTML-bundle upload gaps).
No application code is changed by this document.

## 1. Goal and acceptance target

An MCP-connected client must be able to:

- **upload** any artifact up to `contracts.ARTIFACT_MAX_CONTENT_BYTES` =
  **15,728,640 decoded bytes** (binary or text, including `kind = html-bundle`
  `.zip` archives), and
- **download** any owned artifact up to that size **byte-exactly**,

through MCP-driven artifact workflows, without changing the persisted artifact
format that the web UI, `ham-ctl` and `GET /api/v1/artifacts/*/content` already
read.

## 2. What limits us today (source evidence)

Line numbers are at commit `2919dec8`.

| Limit | Where | Effect on 15 MiB |
|---|---|---|
| MCP JSON-RPC body ≤ 512 KiB | `src/hub/transport/http/mcp_control_handlers.odin:37` (`MCP_CONTROL_MAX_BODY_BYTES`), enforced at `:153` | a 15 MiB file cannot ride in `tools/call` arguments |
| Whole MCP request window 30 s; the 5 s figure is only the response **write** timeout (`min(5 s, remaining of 30 s)`) | `mcp_control_handlers.odin:145` (write timeout), `:265` (a tool result after 30 s elapsed becomes `cancelled`) | compute must finish well inside 30 s minus write time; moving 20+ MiB of JSON per call is not viable |
| `artifacts.create.content` ≤ 65,536 bytes, text MIME only, no NUL | `src/hub/transport/http/mcp_resource_arguments.odin:17,98-105`; `src/hub/service/mcp/control.odin:122` (`kind==.Artifact && key=="content" && len>65536`) | text-only, 64 KiB |
| `artifacts.get` copies ≤ 128 KiB stored, opens text MIME only | `src/hub/service/mcp/artifacts.odin:16,32` | binary/HTML bundle → `unsupported_content_type`; > 128 KiB → `content_too_large` |
| Device control job payload/result ≤ 4 MiB, deadline ≤ 4 s | `src/hub/service/mcp/control.odin:92,134`; `src/hub/service/mcp/worker_broker.odin:65`; `src/hub/transport/http/mcp_worker_handlers.odin:55,74,79` | device-decrypted results capped at 4 MiB / 4 s |
| Device result must contain no `vault:v2:` token | `control.odin:134` (`strings.contains(result,vault.VAULT_V2_PREFIX)`) | sealed bytes cannot be returned through the broker |
| Persisted vault value = **one** v2 AES-GCM token (`vault:v2:<vault>:e<epoch>:<b64(nonce‖tag‖ct)>`) | `src/lib/vault/envelope.odin:21-31,238-330` | any range read needs a full decrypt of the whole 15 MiB value |
| Artifact HTTP request bound = base64(armored 15 MiB) + 1 MiB, under the shared 80 MiB reader cap | `src/hub/transport/http/artifact_limits.odin` | HTTP request bodies are read whole into memory (no streaming) |
| Native download returns the **stored** value (ciphertext for sealed artifacts) | `src/hub/transport/http/content_handlers.odin:252-270` | an MCP client without vault keys cannot use it directly |

The live connector schema as seen by this Claude Code session (Heimdall MCP
connector, tool `artifacts_create`) confirms the shipped contract:
`content.maxLength = 65536`, `content_type ∈ {text/plain,text/markdown,application/json}`,
description "No filesystem paths, remote fetch, binary uploads".

### What the MCP spec does and does not constrain (primary source)

MCP specification **2025-11-25** (fetched 2026-11-02):

- **No maximum message size** is defined for `tools/call` or Streamable HTTP
  (`/basic/transports`, `/server/tools`). Servers MUST rate-limit; clients SHOULD
  time out tool calls. Raising our caps does **not** violate MCP.
- Tool results may contain `resource_link` (`{"type":"resource_link","uri",…}`) and
  embedded `resource`; resource contents may be binary `blob` (base64)
  (`/server/tools`, `/server/resources`). No size limit is defined.
- **URL-mode elicitation** exists: "direct users to external URLs for out-of-band
  interactions that must not pass through the MCP client"; clients MUST show the URL
  and MUST NOT open it without consent (`/client/elicitation`). Clients opt in with
  `"elicitation":{"url":{}}`.
- `notifications/cancelled` cancels an in-flight request; `notifications/progress`
  reports progress with a `progressToken` (`/basic/utilities/*`).

## 3. Client feasibility — the deciding constraint

The binding constraint is not the protocol; it is **where the bytes travel**.
In every mainstream MCP client the *model* generates `tools/call` arguments and
reads tool results.

| Fact | Kind |
|---|---|
| 15,728,640 B → 20,971,520 B base64 (~5–7 M tokens). No current model context fits it, and generating it token-by-token would take hours and corrupt bytes. | arithmetic + **assumption** about tokenizer density (order of magnitude is robust) |
| Spec-level: tool args/results carry no size limit, so a *programmatic* MCP client (SDK script) can send large args. | source (spec) |
| Claude Code, Codex CLI, Heimdall agents and similar coding agents have a shell and can run `curl`/`sha256sum` against a URL, keeping bytes out of the model context. | source: this session's own tool set (Bash); **assumption** that other coding agents behave similarly |
| Chat-only clients (e.g. claude.ai web chat) have no general HTTP PUT with custom headers; a human can open/download a URL in a browser. | **assumption** (no primary doc consulted); treat chat clients as download-via-human only |
| URL-mode elicitation lets a server ask the user to open a URL out of band; support is client-opt-in. | source (spec); per-client support **unverified** |

Consequence: **any design that moves file bytes through tool arguments or tool
results only works for programmatic clients**, never for model-driven workflows.
A transfer must use a data path outside the model context, with MCP tools only
negotiating it.

## 4. Alternatives compared

### (1) Bounded MCP chunks + chunked ciphertext storage

Tools `artifacts.upload_chunk{transfer_id,index,data_base64}` / `artifacts.read_chunk`
with ≤ 256 KiB chunks (fits the 512 KiB body), stored as a new chunked v3 envelope
(per-chunk AES-GCM, AAD = artifact‖index‖final) so ranges decrypt independently.

- Cost: new persisted encryption format v3 plus readers in Odin (`src/lib/vault`),
  TypeScript (`src/ui/...` vault + `encryptVaultBytes`), `ham-ctl`; migration or
  dual-read of every artifact path; HTML-bundle viewer must read v3; key-rotation and
  "previous vault" marker logic duplicated. 15 MiB / 256 KiB = **60 tool calls** up and
  down, each carrying base64 through the model.
- Client feasibility: **fails** for model-driven clients (§3): 20 MiB of base64 through
  the context. Works only for SDK scripts.
- Verdict: **rejected.** Highest cost, worst feasibility. Chunked storage solves a
  range-read problem that disappears once downloads are staged (§5.6).

### (2) Artifact-specific bulk vault jobs, monolithic storage kept

Raise the MCP body cap (e.g. 24 MiB) for `artifacts.create`, add `content_base64`,
and give artifact jobs a separate broker lane with ≤ 24 MiB payloads and ≤ 30 s
deadlines; `artifacts.get` returns `content_base64` up to 15 MiB.

- Cost: moderate — no new format; but 20–28 MiB JSON parse + base64 decode + seal per
  request in the MCP handler (≈ 3× file size resident), a large-message broker lane
  (`worker_broker.odin`, `mcp_worker_handlers.odin`), relaxing the
  "no vault token in result" rule for one job kind, and a 30 s window that a slow
  device misses.
- Client feasibility: **fails** for model-driven clients for the same reason as (1):
  bytes still cross the model context. Spec-legal, but not usable.
- Verdict: **rejected as the client path.** Its useful idea — keep monolithic v2 storage
  and do one bounded seal/open per artifact — is **adopted** server-side in (3).

### (3) MCP tools negotiate scoped transfer handles; bytes move over plain HTTPS

MCP tools create a short-lived, single-artifact **transfer** and return an HTTPS URL
plus a transfer-scoped bearer token. The client moves bytes with `curl` (or the user's
browser for downloads). A final MCP call commits the upload. Persisted storage stays
one monolithic v2 token; staging is encrypted at rest under an ephemeral per-transfer
key.

- Cost: one new HTTP route family, two tables (staging), four MCP tools, one
  sealed-commit path reusing `vault.seal` / `content_service.create_artifact`. No new
  persisted format; no reader changes in UI/ctl.
- Client feasibility: **works** for any client with a shell (coding agents, Heimdall
  agents, SDK scripts); **download works** for chat clients via a link the human opens
  (or URL-mode elicitation where supported); **upload from chat-only clients remains
  impossible** (the file isn't reachable by the client anyway) — documented, not hidden.
- Verdict: **recommended.**

| | (1) chunks + v3 | (2) bulk jobs | (3) transfer handles |
|---|---|---|---|
| Model-driven client feasible | no | no | **yes** (shell clients; human download) |
| New persisted crypto format | yes (v3) | no | **no** |
| UI / ctl reader changes | yes | no | **no** |
| MCP calls per 15 MiB upload | ~60 | 1 (huge) | **2** + 1–4 HTTP PUT/PATCH |
| Peak server memory per transfer | low | ~3× file in MCP handler | bounded, ≈ 72 MiB only during a hosted commit/prepare (§5.7) |
| Resumable | per chunk | no | **yes** (offset-based) |

## 5. Recommended design: scoped transfer handles

### 5.1 Overview

```
client (model)             MCP /api/v1/mcp                  transfer HTTP /api/v1/mcp/transfers/{id}
  artifacts.upload_begin ─────▶ create transfer, token  ◀─┐
  ◀── {transfer_id, upload_url, token, chunk_max, expires_at}
  (shell) curl PUT/PATCH bytes ──────────────────────────────▶ append, stream sha256, AEAD-stage
  artifacts.upload_commit ────▶ verify size+sha256, seal v2 once, create_artifact
  ◀── {artifact_id, link, revision, size_bytes, sha256}

  artifacts.download_begin ───▶ open v2 once, AEAD-stage plaintext
  ◀── {transfer_id, download_url, token, size_bytes, sha256, expires_at}
  (shell or human) curl GET [Range] ─────────────────────────▶ decrypt staged chunks, stream
```

### 5.2 MCP tool schemas

All tools require a stable `request_id` and follow the existing receipt/idempotency
rules (`docs/mcp-capabilities.md`, artifact write section). Upload tools require
`mcp:artifacts:write`; download tools require `mcp:artifacts:read`;
`artifacts.transfer_status`/`transfer_cancel` require either, and only see transfers
of the same kind they could create. Legacy `mcp:chains` connections gain nothing
(`src/hub/service/mcp/capabilities.odin:55` gets the new names).

**`artifacts.upload_begin`**

```json
{
  "type": "object", "additionalProperties": false,
  "required": ["request_id", "name", "size_bytes", "sha256", "content_type"],
  "properties": {
    "request_id": {"type": "string", "minLength": 1, "maxLength": 128},
    "name": {"type": "string", "minLength": 1, "maxLength": 500},
    "description": {"type": "string", "maxLength": 20000},
    "size_bytes": {"type": "integer", "minimum": 1, "maximum": 15728640},
    "sha256": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
    "content_type": {"type": "string", "maxLength": 255,
      "description": "MIME of the decoded bytes, e.g. application/zip, image/png, text/html"},
    "kind": {"type": "string", "enum": ["file", "text", "markdown", "json", "html-bundle"], "default": "file"},
    "ext": {"type": "string", "maxLength": 32},
    "entry": {"type": "string", "maxLength": 1024, "description": "html-bundle entry member; default index.html"},
    "project_id": {"type": "string", "maxLength": 256},
    "chain_id": {"type": "string", "maxLength": 256},
    "task_id": {"type": "string", "maxLength": 256},
    "agent_id": {"type": "string", "maxLength": 256},
    "agent_instance_id": {"type": "string", "maxLength": 256}
  }
}
```

Result:

```json
{
  "transfer_id": "xfr_…",
  "state": "receiving",
  "upload_url": "https://<hub>/api/v1/mcp/transfers/xfr_…",
  "token": "hxt_<43 base64url chars>",
  "received_bytes": 0,
  "chunk_max_bytes": 8388608,
  "expires_at": "2026-11-02T15:20:00Z"
}
```

`kind = html-bundle` requires `content_type = application/zip`. Association fields are
validated at begin (same rules as `artifacts.create`, `content_service.odin:354`
`artifact_context_owned` at `:497`) and re-validated at commit. A repeat of the same
`request_id` with identical arguments returns the same transfer and its current
`received_bytes`, with a **freshly minted token** that replaces the previous one
(only `sha256(token)` is stored, so the original cannot be returned); replay after a
terminal state returns that state without a token.

**`artifacts.upload_commit`**

```json
{"type":"object","additionalProperties":false,
 "required":["request_id","transfer_id"],
 "properties":{"request_id":{"type":"string","minLength":1,"maxLength":128},
               "transfer_id":{"type":"string","pattern":"^xfr_[A-Za-z0-9]{1,64}$"}}}
```

Result (hosted): always terminal within the call —
`{"transfer_id","state":"committed","artifact_id","link":"artifact://art_…","revision","size_bytes":15728640,"sha256"}`.
Hosted commit never returns `committing` and never continues after the call (key
boundary, §5.5). Result (device mode, T5 only): `{"transfer_id","state":"committing"}`;
poll `artifacts.transfer_status`.

Errors: `transfer_incomplete` (with `received_bytes`), `digest_mismatch`,
`bundle_invalid` (with the validator's reason), `transfer_expired`,
`decryption_unavailable`, `quota_exceeded`, and the **retryable** `busy`
(`{"error":"busy","retryable":true,"retry_after_ms":…}`, seal/open semaphore full)
and `cancelled` (30 s window elapsed or client cancelled). Retryable errors leave the
transfer in `receiving` with its staging intact and record **no receipt** (receipts
commit only together with the native change, `docs/mcp-capabilities.md:114-117`), so a
replay with the same `request_id` re-attempts the commit. `digest_mismatch` and
`bundle_invalid` are terminal (`failed`).

**`artifacts.download_begin`**

```json
{"type":"object","additionalProperties":false,
 "required":["request_id","artifact_id"],
 "properties":{"request_id":{"type":"string","minLength":1,"maxLength":128},
               "artifact_id":{"type":"string","maxLength":256},
               "elicit":{"type":"boolean","default":false,
                 "description":"also ask the user to open the link via URL-mode elicitation when the client supports it"}}}
```

Result: `{"transfer_id","state":"ready","download_url","token","size_bytes","sha256","content_type","name","expires_at","max_fetches":8}`
plus a `resource_link` content item (`uri = download_url`, `mimeType`, `size`) for
clients that render links. For human download the result also carries
`browser_url = download_url + "?t=<token>"` (see §5.4 for its stricter rules).
`size_bytes`/`sha256` are of the **decoded** bytes.

In hosted mode `download_begin` opens and stages synchronously inside the call and
returns `state: "ready"` or an error; it never returns `preparing` (that state exists
only for device mode, T5). `busy`/`cancelled` are retryable and create **no** transfer
row and no receipt.

Replay and snapshot semantics for `download_begin`:

- Same `request_id`, identical arguments, transfer still `ready`: returns the same
  `transfer_id`, `sha256`, `expires_at` and the **remaining** `max_fetches` (the counter
  is not reset), with a freshly minted token. Because only `sha256(token)` is stored,
  rotation is the only way to return a usable token; it **invalidates** the previous
  token and any `browser_url` built from it. A client that has already shown a
  `browser_url` to the user must not replay; it should call `download_begin` with a new
  `request_id` (new transfer, counted against quotas) if it needs another link.
- Replay after a terminal state (`expired`, `cancelled`, `failed`, or fetches
  exhausted → `expired`) returns that state without a token; it does not re-prepare.
- The staged bytes are an immutable **snapshot** of the artifact taken inside the
  `download_begin` call (identified by the returned `revision`). A later artifact
  edit, re-upload or delete does not change what the transfer serves; the transfer
  keeps serving the snapshot until TTL/fetch exhaustion. Exception: if the owner's
  grant is revoked or the account disabled, the transfer is wiped (§5.4). Archive/
  delete of the artifact also schedules a wipe of its download transfers at the next
  janitor tick, so a deleted artifact is downloadable for at most one tick after
  deletion (T1 sets the transfer janitor interval to ≤ 60 s; the existing
  maintenance tick interval is not assumed).

**`artifacts.transfer_status`** `{transfer_id}` → `{state, kind:"upload"|"download", received_bytes|size_bytes, expires_at, error?}`.

**`artifacts.transfer_cancel`** `{request_id, transfer_id}` → `{state:"cancelled"}`;
idempotent; wipes staging immediately.

States: hosted `receiving → committed`, `ready` (created ready); device mode (T5) adds
`receiving → committing → committed` and `preparing → ready`; any non-terminal →
`cancelled | expired | failed`. Terminal states keep a metadata-only row for 24 h for idempotent
replay, then are purged.

### 5.3 Transfer HTTP endpoints (data path, outside MCP JSON-RPC)

Route family `/api/v1/mcp/transfers/{transfer_id}` registered next to
`mcp_control_register_routes` (`mcp_control_handlers.odin:38`). Authentication is
**only** `Authorization: Bearer hxt_…` (or `?t=` for browser GET, below). Neither the
OAuth access token nor a session cookie is accepted, and the transfer token is
accepted nowhere else.

| Method | Purpose | Notes |
|---|---|---|
| `PUT` | upload whole content in one request | body ≤ `size_bytes`; only when `received_bytes = 0`; `Content-Length` required |
| `PATCH` | append at offset (resumable) | headers `Upload-Offset: <n>` (must equal `received_bytes`), body 1 B … `chunk_max_bytes` (8 MiB); returns `204` + `Upload-Offset` |
| `HEAD` | resume probe | upload: `Upload-Offset`, `Upload-Length`; download: `Content-Length`, `Accept-Ranges: bytes`, `Repr-Digest: sha-256=:<b64>:` |
| `GET` | download | `200` full or `206` with a single `Range: bytes=a-b`; `Content-Disposition: attachment`, `Cache-Control: no-store`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `Repr-Digest` |
| `DELETE` | cancel | same as `artifacts.transfer_cancel` |

Each request body is bounded by `chunk_max_bytes` (PATCH) or `size_bytes` (PUT, ≤
15 MiB) and therefore stays well under the shared 80 MiB reader cap
(`artifact_limits.odin`). Bodies are never parsed as JSON. Uploaded HTML/JS is never
served back from this route except as `attachment` with `nosniff`.

Example client flow (shell client):

```bash
sha=$(sha256sum site.zip | cut -d' ' -f1); size=$(stat -c%s site.zip)
# tools/call artifacts.upload_begin {name, size_bytes:$size, sha256:$sha, kind:"html-bundle", content_type:"application/zip"}
curl -fsS -X PUT -H "Authorization: Bearer $TOKEN" --data-binary @site.zip "$URL"
# on network failure:
off=$(curl -fsSI -H "Authorization: Bearer $TOKEN" "$URL" | awk -F': ' 'tolower($1)=="upload-offset"{print $2+0}')
tail -c +$((off+1)) site.zip | head -c 8388608 | curl -fsS -X PATCH -H "Authorization: Bearer $TOKEN" -H "Upload-Offset: $off" --data-binary @- "$URL"
# tools/call artifacts.upload_commit {transfer_id}

# download
curl -fsS -H "Authorization: Bearer $TOKEN" -o out.bin "$URL"
echo "$SHA  out.bin" | sha256sum -c -
curl -fsS -C - -H "Authorization: Bearer $TOKEN" -o out.bin "$URL"   # resume via Range
```

### 5.4 Auth, owner isolation and token handling

- Transfer row binds `owner_user_id`, MCP `client_id`, grant id and family id, scope
  used, kind, artifact id (download) and `sha256(token)`. Every transfer HTTP request
  loads the row by id, compares `sha256(token)` in constant time, then **rechecks the
  live grant/family/account** (the same liveness used by `hosted_with_access`,
  `src/hub/service/mcp/hosted.odin:112`). Grant revocation, disconnect or account
  disable makes every transfer of that grant fail with `401` and schedules a wipe.
- Tokens: 32 random bytes, prefix `hxt_`, never logged. Access logs record the route
  template, not query strings. `?t=` is accepted **only** for `GET`/`HEAD` of a
  download transfer, with `Referrer-Policy: no-referrer`, `Cache-Control: no-store`,
  and counts toward `max_fetches` (8).
- Ownership: the MCP tools authorize through the existing owner-scoped content
  service (`content.get_artifact_bounded` / `create_artifact` with
  `control_auth(owner)`); knowing a `transfer_id` grants nothing without its token,
  and a token grants nothing beyond its one transfer. Cross-owner reads return
  `404`, indistinguishable from unknown ids.
- Rate limiting (spec MUST): per grant ≤ 30 transfer HTTP requests / minute,
  ≤ 10 `*_begin` / hour.

### 5.5 Encryption and key boundaries

Persisted artifacts stay **exactly** as today: one v2 token under the verified
current epoch (`vault.seal`, `envelope.odin:271`), or plain bytes for unvaulted
owners — the same rule as `content_service.create_artifact`. No reader changes.

Staging (≤ 60 min) is encrypted at rest with an **ephemeral per-transfer key**
`K_t` (32 random bytes) using the existing AES-256-GCM primitive
`vault.seal_with_nonce_aad` / `open_payload_with_key_aad` (`envelope.odin:246,289`):
each ≤ 1 MiB staged chunk is sealed with a random nonce and
`AAD = "heimdall-xfer-v1|" ‖ transfer_id ‖ "|" ‖ u32 index ‖ "|" ‖ u8 final`.
This is a reuse of the current primitive for transient data, **not** a new persisted
artifact format. `K_t` lives only in process memory (map keyed by `transfer_id`,
wiped with `crypto.zero_explicit` on terminal state). A Hub restart therefore loses
in-flight transfers (`state: failed, error: transfer_lost`); clients restart them.
This is deliberate: wrapping `K_t` under a vault key would require the OAuth
credential on every data-path request, which the transfer token intentionally is
not.

Why staging cannot use the vault key directly: transfer HTTP requests carry only the
transfer token, so the hosted keyring (opened per request from the sealed access
credential, `docs/mcp-hosted-vault.md`) is unavailable there. The keyring is opened
exactly once, inside the MCP `upload_commit` / `download_begin` call.

Who sees plaintext: the Hub sees transfer plaintext in-flight, exactly as it already
does for `artifacts.create` content today. This design keeps that trust level and
does not weaken it.

Decryption modes:

| Mode | Upload commit | Download prepare |
|---|---|---|
| **Hosted** (`hosted_with_access`) | Inside the callback: decrypt staging with `K_t` into one buffer, verify size+sha256 and the HTML bundle (§5.8), seal one v2 token with the borrowed keyring, wipe the plaintext, re-open the token and compare sha256, return the token. After the callback: existing second-transaction recheck, then `create_artifact` + `committed` + receipt in one transaction | Inside the callback: open the already-loaded v2 value once, seal ≤ 1 MiB chunks under `K_t` into memory, wipe plaintext, return the chunks. After the recheck: insert the transfer row and chunks in one transaction |
| **Device** (default) | Hub sends a control job `artifact_transfer_seal{transfer_id, seal_url, fetch_token}` (small payload, existing ≤ 4 MiB lane). The approved, unlocked device fetches staged plaintext over HTTPS with a device-scoped one-time fetch token, seals with its keyring (`encryptVaultBytes`), validates bundles with `readHtmlBundle`, and POSTs the sealed value to `/api/v1/mcp/transfers/{id}/sealed` with its existing signed device proof. Hub verifies device signature, epoch, armored size bound, then `create_artifact` | Symmetric job `artifact_transfer_open`: device GETs the sealed value via its normal artifact route, decrypts, PUTs plaintext into staging. Hub verifies size and computes sha256 |

**Hosted call boundary (normative).** `hosted_with_access` opens the keyring, runs the
transform callback **synchronously** between its two DB transactions, and wipes the
keyring on return; the callback "may only use the borrowed keyring synchronously; it
must not retain it" (`src/hub/service/mcp/hosted.odin:108-122`). Therefore every
hosted step that needs the vault keyring — staging decrypt + validation + seal +
re-open for upload, open + `K_t` re-staging for download — runs entirely inside that
one callback within the MCP call. Nothing that needs the keyring is ever deferred to a
background job, retried later from saved state, or continued after the response. The
callback outputs only ciphertext (the v2 token or `K_t` chunks) through its `ctx`; all
DB writes happen in the handler after the final recheck, matching the existing
`artifacts.create` sealed path (`mcp_control_handlers.odin:255-270`). If the semaphore
is full the callback is never entered (`busy`); if the 30 s window elapses
(`mcp_control_handlers.odin:265`) or the client cancels, the output is wiped and
discarded and the transfer stays `receiving` (upload) or is never created (download).

Budget (assumption, to be measured in T4): three AES-256-GCM passes over 15 MiB plus
base64 and SHA-256 are expected to take well under 5 s on Hub hardware; T4 adds a
timing test that fails if a 15,728,640-byte hosted commit exceeds 10 s, leaving
≥ 15 s headroom inside the 30 s window for the write timeout and DB work.

The device lanes keep large bytes **out of the broker** (`worker_broker.odin:65`,
`control.odin:134` unchanged): the job carries only ids and tokens. Device mode is a
later stage (§8, T5); until it lands, transfer tools in device mode return
`decryption_unavailable` with a hint to enable hosted decryption or use `ham-ctl`.

### 5.6 Integrity

- Client declares `size_bytes` and `sha256` at begin. The Hub streams SHA-256 over
  plaintext as bytes arrive and rejects a PUT/PATCH that would exceed `size_bytes`.
  Commit requires `received_bytes == size_bytes` and digest equality, and **after
  sealing re-opens the sealed value and compares the digest** before inserting (catches
  any seal bug; costs one extra decrypt during the bounded commit).
- Staged chunks are AEAD-protected with index and final flag in AAD: reordering,
  truncation or substitution fails `open`.
- Downloads publish `sha256` in the tool result and `Repr-Digest`; the documented
  client flow verifies with `sha256sum -c`.
- MCP does **not** add a plaintext digest to persisted artifact metadata (the
  `revision` comment at `artifacts.odin:19-20` explains why); the existing `sha256`
  column keeps its current native semantics. Transfer rows keep the digest only until
  purge.

### 5.7 Quotas, TTL, concurrency and memory bounds

| Bound | Value |
|---|---|
| Size per transfer | ≤ 15,728,640 decoded bytes (`contracts.ARTIFACT_MAX_CONTENT_BYTES`) |
| PATCH body | ≤ 8 MiB; PUT body ≤ `size_bytes` |
| Active transfers per owner | ≤ 4 (≤ 2 uploads, ≤ 2 downloads) |
| Staged bytes per owner / global | ≤ 64 MiB / ≤ 512 MiB (config `mcp_transfer_staging_max_bytes`) |
| Idle TTL / absolute TTL | 15 min since last byte / 60 min since begin |
| Download fetches | ≤ 8 complete-or-ranged GETs per transfer |
| Global seal/open concurrency | semaphore of 2 (commit + prepare share it), acquired **before** entering `hosted_with_access`; waiters get retryable `busy` with `retry_after_ms` rather than queueing |
| Peak memory per hosted commit | ≈ **72 MiB** (derivation below) |
| Peak memory per hosted prepare | ≈ **72 MiB**: stored armored value 21 + decoded payload 15 + plaintext 15 + `K_t` chunks 15 (+ ~6 KiB chunk headers) |
| Global seal/open bound | 2 slots × 72 MiB ≈ **144 MiB**, plus the data-path row below |
| Per-request memory on the data path | ≤ one request body (≤ 15 MiB) + one 1 MiB staged chunk |

Commit peak derivation (`src/lib/vault/envelope.odin:246-262,309-318`; F = 15 MiB, A = armored ≈ 20 MiB + prefix):

1. Decrypt staging → plaintext P (F). Validation (§5.8) adds ≤ 2F for the largest
   member while it is checked (inflate buffer + clone, `html_bundle.odin:287-304`),
   freed before step 2: peak ≈ 3F = 45 MiB.
2. `vault.seal`: payload `nonce‖tag‖ct` (F, temp, zeroed by `defer`) + base64 (A,
   temp) + concatenated token (A): peak P + F + 2A ≈ 15 + 15 + 21 + 21 = **72 MiB**.
3. Wipe and free P (its sha256 was already checked in step 1) and release the
   temp allocations of step 2 (the callback runs in a scoped arena or calls
   `free_all(context.temp_allocator)` after copying the token out).
4. Re-open: `envelope_parse` payload (F, temp) + plaintext P′ (F) next to the token
   (A): ≈ 51 MiB; sha256(P′) compared, P′ wiped.

Without step 3 the re-open would add 2F on top of step 2 (≈ 102 MiB); step 3 is
therefore mandatory and covered by test 7.

A janitor (existing periodic maintenance tick) expires transfers, deletes staging
rows and wipes `K_t`. Expired/cancelled staging is deleted in one transaction per
transfer.

### 5.8 HTML bundles

`kind = html-bundle` uploads must pass the same validation as `ham-ctl`
(`src/ctl/html_bundle.odin`: ZIP structure, `HTML_BUNDLE_ALLOWED_EXTENSIONS`, entry
exists, ≤ 1000 entries, ≤ 50 MiB expanded, 64 KiB manifest) **before sealing**:

- Hosted: Hub runs the validator on the decrypted staging buffer at commit. This needs
  the validator moved from `src/ctl` into a shared package (e.g.
  `src/lib/html_bundle`) imported by both ctl and hub (ticket T3). Expansion is
  bounded by the existing 50 MiB declared+actual check. Memory: today
  `html_bundle_from_zip` inflates every member into `context.temp_allocator` and
  keeps them until the temp arena is freed, then clones the archive
  (`html_bundle.odin:495-532`) — up to 50 MiB expanded + 15 MiB clone. T3 adds a
  validate-only entry point (`html_bundle_validate(data, entry) -> (entry, err)`)
  that inflates **one member at a time**, frees it (via a per-member arena) before
  the next, never clones or rewrites the archive (it rejects a bundle without a
  manifest/entry rather than appending one), and retains only the central-directory
  metadata (≤ 1000 entries × ≤ 1 KiB paths ≈ 1 MiB). Its peak is therefore ≤ 2 ×
  largest member (≤ 2 × 15 MiB) + ~1 MiB, freed before sealing (§5.7 step 1). The
  ctl packaging path keeps its current behaviour.
- Device: the device runs `readHtmlBundle` (`src/ui/utils/htmlBundle.ts`) before
  sealing.

The viewer keeps its own validation and the script-disabled sandbox (REQ-ART-2). A
download of a bundle returns the exact `.zip` bytes as `attachment`; the transfer
route never renders HTML.

### 5.9 Retries, resumability, cancellation and failure handling

- Tool calls: idempotent by `request_id` (identical args → same result; changed args
  → `conflict`). An ambiguous `upload_commit` is safe to retry: the artifact insert,
  the compare-and-set `receiving → committed` and the receipt commit in one
  transaction after the hosted recheck. Two concurrent commits of the same transfer
  may both seal; the CAS lets exactly one insert, and the loser wipes its token and
  returns the winner's committed result. A per-transfer in-memory "sealing" flag
  makes the second concurrent call return `busy` early in the common case.
- Data path: upload resumes from `HEAD` `Upload-Offset`; a PATCH with a wrong offset
  gets `409` + the current offset; download resumes with `Range` (`curl -C -`).
- Hosted commit/prepare is synchronous (§5.5 boundary). The budget is the 30 s
  request window (`mcp_control_handlers.odin:265`) minus the ≤ 5 s response write
  timeout (`:145`), not 5 s of compute. Semaphore full → retryable `busy`; window
  exceeded or cancelled → retryable `cancelled`; in both cases the output is wiped,
  upload transfers stay `receiving`, no download transfer is created, no receipt is
  stored, and a replay with the same `request_id` retries. Only device mode (T5)
  returns `committing`/`preparing` for `transfer_status` polling, because there the
  keyring lives on the device and the Hub holds none. `notifications/progress` is
  not emitted (the current handler has no progress support and calls are short).
- Cancellation: `artifacts.transfer_cancel`, HTTP `DELETE`, or MCP
  `notifications/cancelled` on an in-flight `upload_commit`/`download_begin` (the
  latter cancels only if sealing has not yet produced the artifact; otherwise the
  committed result stands and is returned on replay).
- Failure: any digest/size/bundle/epoch failure moves the transfer to `failed` and
  wipes staging immediately; nothing partial is ever inserted as an artifact. Device
  job timeout → `failed: device_unavailable`. Restart → `failed: transfer_lost`.

### 5.10 Storage, migration and read compatibility

New migration `187_mcp_artifact_transfers.sql` (next free number after
`186_extension_version_sync_0_5_36.sql`):

```sql
CREATE TABLE mcp_transfers (
  transfer_id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL, client_id TEXT NOT NULL,
  grant_id TEXT NOT NULL, family_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('upload','download')),
  state TEXT NOT NULL, error TEXT NOT NULL DEFAULT '',
  token_sha256 TEXT NOT NULL,
  artifact_id TEXT NOT NULL DEFAULT '',
  request_id TEXT NOT NULL, request_digest TEXT NOT NULL,
  metadata TEXT NOT NULL,            -- name/description sealed like artifacts.create; ids; mime/kind/ext/entry
  size_bytes INTEGER NOT NULL, received_bytes INTEGER NOT NULL DEFAULT 0,
  sha256 TEXT NOT NULL, fetches INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL, touched_at TEXT NOT NULL, expires_at TEXT NOT NULL,
  UNIQUE (owner_user_id, client_id, request_id)
);
CREATE INDEX mcp_transfers_expiry ON mcp_transfers(state, expires_at);
CREATE TABLE mcp_transfer_chunks (
  transfer_id TEXT NOT NULL REFERENCES mcp_transfers(transfer_id) ON DELETE CASCADE,
  chunk_index INTEGER NOT NULL, ciphertext BLOB NOT NULL,   -- nonce‖tag‖ct under K_t
  PRIMARY KEY (transfer_id, chunk_index)
);
```

Read compatibility: no existing table or value changes. Artifacts created by transfer
are indistinguishable from `POST /api/v1/artifacts` uploads, so the web UI, HTML
bundle viewer, `ham-ctl artifact show/download` and `artifacts.get` (metadata) work
unchanged. Old Hub versions ignore the new tables. Rollback = drop the tables; no
artifact data lives there beyond TTL.

`artifacts.get` keeps its 64 KiB inline text behavior; when content is too large or
binary it additionally returns `"download": "artifacts.download_begin"` as a hint.

## 6. Security review checklist

- Transfer token ≠ OAuth token; scoped to one transfer, one direction, one owner,
  one grant; hashed at rest; constant-time compare; revoked with the grant.
- No plaintext at rest beyond in-memory buffers; staging AEAD under memory-only `K_t`.
- No `vault:v2:` value ever crosses the broker; device lanes move bytes over HTTPS
  with device proof.
- No HTML/JS rendering on the transfer route (`attachment`, `nosniff`, `no-store`).
- DoS: bounded body, per-grant rate limits, per-owner/global staging quotas,
  2-slot seal/open semaphore with non-blocking `busy`.
- Logs: no tokens, no query strings, no plaintext digests.

## 7. Validation plan

Unit / integration (all under `nix develop --command odin test …`, see chain dead
ends):

1. `src/hub/service/mcp`: tool argument validation (size 15,728,640 accepted,
   15,728,641 rejected; sha256 pattern; html-bundle requires zip), scope gating
   (read vs write vs legacy `mcp:chains`), idempotent replay and conflict.
2. Transfer service: PUT whole, PATCH resume with wrong offset → 409, overrun
   rejected, idle/absolute TTL expiry, quota exhaustion, cancel wipes chunks and
   `K_t`, restart simulation → `transfer_lost`, AEAD chunk reorder/truncate → open
   fails.
3. **Byte-exact round trip**: 15,728,640-byte non-UTF-8 random payload →
   `upload_begin` → PUT → `upload_commit` (hosted) → `download_begin` → GET →
   identical bytes and digest; also the same via 2 PATCHes, and a ranged GET
   reassembly (`0-8388607`, `8388608-`). Hosted commit/download return terminal
   `committed`/`ready` in the same call (never `committing`/`preparing`); a fake
   transform clock past 30 s yields `cancelled`, the transfer stays `receiving` with
   staging intact, no receipt exists, and a replay with the same `request_id`
   commits. Test that the hosted transform retains no keyring pointer after return
   (the keyring is wiped and the callback ctx holds only ciphertext). Timing guard:
   15,728,640-byte hosted commit < 10 s. `download_begin` replay: same transfer,
   rotated token (old token → 401), `max_fetches` not reset; artifact edited/deleted
   after `download_begin` → GET still returns the snapshot until the janitor tick
   (delete) or TTL (edit).
4. HTML bundle: valid 15 MiB bundle commits and opens in
   `tests/ui_html_bundle_test.ts` flow; bundle with a disallowed member or missing
   entry → `bundle_invalid`, nothing inserted.
5. Ownership: user B's token/transfer id on user A's transfer → 404/401; revoked
   grant mid-upload → 401 and staging wiped.
6. HTTP: `src/hub/transport/http` tests for headers (`Upload-Offset`, `Range`,
   `Repr-Digest`, `no-store`, `nosniff`), `?t=` rejected for PUT/PATCH, body bounds.
7. Memory: tracking-allocator test that a hosted 15 MiB commit peaks ≤ 75 MiB and
   prepare ≤ 75 MiB (§5.7), that P is wiped before the re-open, that the bundle
   validator holds at most one inflated member at a time, and that the semaphore
   returns retryable `busy` (transfer still `receiving`) at 3 concurrent commits.
8. Device mode (T5): browser test with a fake broker, seal/open lanes, signature
   rejection, stale epoch rejection.
9. End-to-end manual (no live deploy in this chain): local Hub + Claude Code connector
   using the documented `curl` flow.

## 8. Implementation tickets (staged)

| # | Ticket | Depends | Scope |
|---|---|---|---|
| T1 | Transfer storage and service | – | migration 187, repo procs, transfer service (state machine, `K_t` map, AEAD staging, quotas, TTL janitor, semaphore); unit tests 2, 7 |
| T2 | Transfer HTTP data path | T1 | `/api/v1/mcp/transfers/{id}` PUT/PATCH/HEAD/GET/DELETE, token auth + grant liveness, rate limits, headers; tests 5, 6 |
| T3 | Shared HTML bundle validator | – | move validator from `src/ctl/html_bundle.odin` into `src/lib/html_bundle`; add streaming validate-only entry point (one member resident at a time, no archive clone, §5.8); ctl keeps behaviour; existing ctl tests stay green |
| T4 | Hosted MCP tools | T1, T2, T3 | `artifacts.upload_begin/upload_commit/download_begin/transfer_status/transfer_cancel` (argument parsing in `mcp_resource_arguments.odin`, catalog, capabilities), hosted seal/open + re-open digest check, `artifacts.get` hint; tests 1, 3, 4 |
| T5 | Device-mode lanes | T4 | control job kinds `artifact_transfer_seal/open`, device fetch/sealed endpoints with device proof, UI worker implementation; test 8 |
| T6 | Docs and skills | T4 | `docs/mcp-capabilities.md` (replace "no binary uploads"), `docs/html-bundle-artifacts.md` upload table, artifact-authoring skill client flow, threat-model notes |

T1–T4 alone satisfy the acceptance target for hosted-decryption connections; T5
extends it to default device decryption.

## 9. Decisions and open items

- **Decided:** keep monolithic v2 persisted storage; no v3 format (staging solves range
  reads; v3 would touch every reader).
- **Decided:** bytes never cross the model context; MCP negotiates, HTTPS carries.
- **Decided:** staging key is memory-only; restart loses in-flight transfers.
- **Decided:** hosted seal/open runs only inside the synchronous `hosted_with_access`
  callback; no background continuation in hosted mode; overload/time-out are
  retryable errors with no receipt. Async states exist only for device mode.
- **Open (assumption):** hosted 15 MiB commit time on production hardware; guarded by
  the T4 timing test.
- **Open (user):** whether chat-only clients' download link should be offered via
  URL-mode elicitation by default (`elicit` defaults to `false` here).
- **Open (unverified assumption):** per-client support for URL-mode elicitation and
  `resource_link` rendering in specific chat clients; verify against each client's own
  docs before T6 copy.
