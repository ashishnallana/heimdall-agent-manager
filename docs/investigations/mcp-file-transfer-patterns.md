# MCP file upload and download: how other MCP servers do it, and how our relay fits

Research report for task `task_18e448fdc1adefeb` (chain *HTML Bundles and 15 MB
Artifacts*). This is a comparative study, **not** an implementation plan. It follows the
user steering of 2026-11-02 17:04Z: Heimdall already has a relay that does the
encryption and decryption, so other MCP servers serve only as **interface references**,
and the relay is traced first.

All external sources were retrieved on **2026-11-02**. Repository references are at
base `d910a2e4`. Legend: ✔ confirmed by the cited source, ✖ the source says it is
not supported, ? unknown or undocumented.

---

## 0. Answer in brief

1. **No surveyed MCP server moves large files through the model.** Real servers use one
   of four shapes. (a) Model-written content goes inline in tool arguments: GitHub and
   Google Drive. (b) Small files come back inline as base64 or an embedded resource:
   GitHub up to 1 MB, Drive, Google Cloud Storage up to 8 MiB, the filesystem reference
   server. (c) A **download link** replaces large content: GitHub at 1 MB and above, a
   `resource_link` plus the raw URL. (d) **Short-lived signed upload/download URLs** that
   code in a sandbox calls directly: Box hosted MCP, `get_upload_url` /
   `get_download_url`. Box documents that (d) works "only in agentic (code-executing)
   environments".
2. **MCP itself has no file-upload primitive yet.** Tool inputs are JSON arguments only.
   The proposals SEP-1306, SEP-2356 and SEP-2631 all closed without merging. The current
   draft is the experimental `io.modelcontextprotocol/files` extension, in an open PR:
   metadata first, then the server returns an HTTPS PUT target, then the client uploads
   and retries. It needs host (client) support, and Claude does not document any.
3. **None of these patterns encrypts end to end.** Every vendor server receives
   plaintext over TLS and relies on its own storage encryption at rest. That is
   server-side encryption, not E2EE.
4. **Our relay is keyless at the Hub, but it does not keep the Hub blind.** In
   `device` mode, Claude's tool arguments reach the Hub in plaintext. The Hub puts that
   plaintext into a signed `Control_Job` and relays it to an approved bridge or an
   unlocked browser. That device seals it with the vault keyring and returns ciphertext.
   The Hub never holds vault keys in this mode, but the plaintext passes through Hub
   memory (wiped after use). In `hosted` mode the Hub itself opens the keyring for the
   duration of the call (§2.4). Only native paths are Hub-blind today: `ham-ctl artifact
   create` seals on the bridge, and viewers decrypt in the browser.
5. **The smallest extension that reuses the relay** is the Box shape, routed through the
   relay (§5, option A):
   - an MCP tool returns a single-use HTTPS upload URL;
   - Claude's code sandbox PUTs the bytes, up to 15 MiB;
   - the approved bridge pulls them through the existing relay authorization, seals
     them with the keyring it already has, and stores **ciphertext** through the transfer
     backend that is already merged (`bf234a70`).

   No new keys, no Claude-side crypto. **But it has the same trust boundary as today's
   relay: the Hub sees plaintext in transit.** It therefore conflicts with the strict
   "Hub handles ciphertext only" reading in the chain summary. That conflict is reported
   here (§4) for a decision. This report does not design around it.
6. **No surveyed pattern meets all constraints at once:** autonomous Claude upload, 15 MiB,
   no crypto on Claude, *and* a blind Hub. The only route that keeps plaintext off the
   Hub without crypto on Claude is for the bytes to go to a trusted-device endpoint
   instead of the Hub (§5, option B). That route remains unproven on claude.ai.

---

## 1. Constraints used for the assessment

| ID | Constraint (from brief and chain summary) |
|---|---|
| K1 | The Claude browser (claude.ai) MCP agent uploads HTML artifacts and bundles **autonomously**, with no manual file picking |
| K2 | Up to **15 MiB = 15,728,640 decoded bytes** (`src/contracts/artifacts.odin:20`) |
| K3 | No vault keys, no encryption helper and no inbox public key on Claude. Vault crypto runs only on trusted user devices |
| K4 | Hub-blind E2EE: the Hub handles ciphertext only (desired, see §4 for the conflict) |
| K5 | Other authorized devices can decrypt and preview after the uploader disconnects |

---

## 2. Existing Heimdall relay, traced from source

### 2.1 Components and where they run

| Piece | Runs on | Source |
|---|---|---|
| MCP endpoint `/api/v1/mcp` (JSON-RPC over HTTP, OAuth bearer) | Hub | `src/hub/transport/http/mcp_control_handlers.odin:38-43,142-295` |
| Mode switch: `hosted` → in-Hub transform, otherwise relay to a device | Hub | `mcp_control_handlers.odin:254-258`, `mcp_resource_write.odin:23-25` |
| Relay job builder and waiter (`mcp_device_transform`) | Hub | `src/hub/transport/http/mcp_worker_handlers.odin:63-107` |
| In-memory job broker: 64 slots, at most 4 per owner | Hub (RAM only) | `src/hub/service/mcp/worker_broker.odin:11,29-43` |
| Push to an enrolled bridge: runtime command `mcp_transform` | Hub → bridge WS | `src/hub/app/mcp_bridge.odin:14-56` |
| Bridge transformer: verifies the job, seals or opens with its unlocked keyring, signs the reply | **Bridge (trusted device)** | `src/bridge/mcp_transform.odin:10-45` |
| Browser transformer: pull `GET/POST /api/v1/mcp/oauth/jobs` after a hint | **Unlocked approved browser** | `mcp_worker_handlers.odin:108-137`, `src/ui/services/mcpWorker.ts:61-69` |
| Job contract, verification, operations | shared lib | `src/lib/vault/control_job.odin:28-36,49-74,116-165` |
| How the bridge got the keyring: browser → bridge ECDH unseal v2 (ephemeral key, identity-signed) | Bridge | `src/bridge/unseal_protocol.odin:14-29` |

### 2.2 Upload direction (e.g. `artifacts.create`, `tasks.comment`, `chains.create`)

```text
Claude model ──tools/call {content:"<plaintext>"}──► Anthropic backend ──TLS──► Hub /api/v1/mcp
  Hub: parse args (≤512 KiB body) → Control_Job{operation:"seal_resource", payload:<plaintext JSON>,
       consent+signature, directory snapshot, deadline ≤ now+4 s}         [plaintext in Hub RAM]
  Hub ─► bridge (WS "mcp_transform", ≤1 MiB)   or   hint → browser pulls job
  Device: control_job_verify (owner, resource, consent signed by approver, directory, epoch,
          device trusted) → seal fields with vault keyring → sign reply statement
  Device ─► Hub: Control_Reply{result:<vault:v2 ciphertext>, signature}
  Hub: verify signature + exact sealed shape → store ciphertext row → tool result to Claude
```

Evidence: the plaintext goes into the payload at `mcp_worker_handlers.odin:77-80`. The
device verifies and seals at `mcp_transform.odin:31-32` and `control_job.odin:116-121`.
The Hub checks the sealed shape at `mcp_resource_write.odin:29-31`.

### 2.3 Download direction (e.g. `artifacts.get`, `tasks.get`)

The Hub reads **ciphertext** records and sends them as the job payload (`operation:"read"`).
The device decrypts them and returns **plaintext JSON**. The Hub checks that the reply
has exactly the requested shape and contains no `vault:v2` tokens
(`control.odin:133-166`, line 134). It then returns that plaintext to Claude as a text
tool result (`mcp_control_handlers.odin:281-294`). For artifacts, the Hub copies at most
**128 KiB** of stored text, and at most **64 KiB** of UTF-8 plaintext is opened. HTML and
binary types are refused (`docs/mcp-capabilities.md:86-91`).

### 2.4 Hosted mode (opt-in)

With a `hosted` grant, the access credential carries a private capability. Inside the
request, the Hub uses it to unwrap the vault keyring with ECDH P-256, runs the transform
in process, and wipes the keyring (`src/hub/service/mcp/hosted.odin:72,94-104,112-135`).
In this mode **the Hub holds keys for the duration of the call**. `docs/mcp-capabilities.md:42`
calls device versus hosted "an independent choice".

### 2.5 Current limits (all source-confirmed)

| Limit | Value | Source |
|---|---|---|
| MCP JSON-RPC body | 512 KiB | `mcp_control_handlers.odin:37,153` |
| `artifacts.create` content | 65,536 bytes; `text/plain`, `text/markdown`, `application/json` only | `src/lib/vault/control_resources.odin:48`, `control_transform.odin:78`, `docs/mcp-capabilities.md:47-51` |
| Relay job payload / job JSON / reply | 4 MiB / 5 MiB / 4 MiB | `control_job.odin:50`, `worker_broker.odin:31,65` |
| Bridge command frame | 1 MiB (both ends) | `mcp_bridge.odin:38`, `mcp_transform.odin:12` |
| Relay deadline | ≤ 4 s set by Hub (≤ 5 s accepted); bridge gets 1.5 s before browser fallback | `mcp_worker_handlers.odin:74,98`, `control_job.odin:50`, `mcp_bridge.odin:46` |
| Whole tool call | 29–30 s | `mcp_control_handlers.odin:145,265` |
| Concurrent relay jobs | 64 global, 4 per owner | `worker_broker.odin:11,36` |
| Artifact content (all channels) | 15 MiB decoded | `src/contracts/artifacts.odin:20`, `docs/mcp-capabilities.md:55-64` |

### 2.6 Hub-blind pieces that already exist

- **Native agents:** `ham-ctl artifact create --file|--directory` seals on the bridge
  before upload, HTML bundles (ZIP) included. The Hub receives an armored envelope only
  (`src/ctl/agent_mode.odin:765-830`).
- **Ciphertext transfer backend** (`bf234a70`): `src/hub/service/mcp/transfers.odin:3-9`
  states the invariant ("nothing in this file seals, opens, holds a keyring"). It provides
  staging plus HTTP routes at `/api/v1/mcp/transfers/**`
  (`mcp_transfer_handlers.odin:94-96`, wired in `src/hub/app/wiring.odin:672`), with
  bounds in `src/contracts/artifacts.odin:33-48`: 8 MiB PATCH chunks, 1 MiB stored rows,
  2 uploads per owner, 48 MiB staged per owner, 15 min idle / 60 min absolute TTL.
  **No MCP tool exposes it yet.** `mcp_tools.json` lists only `artifacts.list/get/create/update/delete`
  for artifacts. The MCP/client task `task_18e442d6e89f4103` is on hold.

### 2.7 Previous assumptions corrected

- The chain's earlier strict reading treated the relay as compatible with "Hub handles
  ciphertext only". **The source shows it is not.** The relay removes *keys* from the Hub
  in device mode. It does not remove *plaintext*. That holds for every MCP write (args)
  and every MCP read (results), because MCP terminates at the Hub. Earlier study
  `d910a2e4` (R1) reached the same conclusion for tool arguments.
- The relay is **not** a byte pipe. Job, frame and deadline bounds (§2.5) cap it at about
  1 MiB per bridge job and about 4 s, so 15 MiB cannot ride in one job unchanged.

---

## 3. How other MCP servers transfer files

### 3.1 The protocol baseline

- **Tool inputs are JSON arguments** validated by `inputSchema`. The spec defines no file
  input type ([tools.mdx 2025-11-25][spec-tools]).
- **Tool results** can be text, image (`data` base64), audio (base64), `resource_link`,
  or an embedded resource with `text` or `blob` (base64) ([spec-tools]; [resources.mdx][spec-res]).
  For `https://` resources the spec says servers SHOULD use the scheme only when the
  client "is able to fetch and load the resource directly from the web on its own"
  ([spec-res]).
- **Standardization history (all unmerged):**
  - [SEP-1306][sep1306], binary elicitation: closed 2026-03-12 as "Superseded by #2356".
  - [SEP-2356][sep2356], `x-mcp-file` plus `data:` URIs: closed unmerged 2026-06-26,
    superseded by #2631.
  - [SEP-2631][sep2631], `files/authorizeUpload|Download`: closed unmerged 2026-10-14,
    with work continuing in [experimental-ext-file-uploads PR #1][ext-pr] (open,
    created 2026-10-14).
- **Draft extension flow** ([ext draft][ext-draft], unmerged):
  1. Client declares the extension.
  2. The file argument carries `{id,name,mimeType,size,digest}` without `data`.
  3. The server returns an `upload_required`/input-required result with an HTTPS PUT
     `url` and `headers`.
  4. The client PUTs, then retries with the same arguments.

  Further rules in the draft:
  - Inline `data` is bounded by `maxInlineBytes`.
  - For downloads, a `resource_link` carries a `_meta` download target. "Hosts MUST remove
    the download target before the result reaches model context."
  - Chunked or resumable transfer is listed under Future Work.
  - The extension *requires host support*, and hosts "SHOULD NOT show `x-mcp-file`
    properties to a model that emits arguments as tokens".
- **Integrity evidence for base64 in arguments:** the redmine-mcp-server maintainer
  reports an agent re-emitting a 3,232-byte PNG as base64. The call carried 4,280 of
  4,312 characters, still valid base64, and a corrupt file was stored
  ([SEP-2631 comment][redmine]). This is community evidence, not a vendor document.
- **Cross-server/sandbox-produced files** (exactly our K1 case) are noted as *not covered*
  by SEP-2631 in a [comment from an implementer][xserver]: "the host holds the bytes
  and is the only party that can satisfy the input."

### 3.2 Claude client facts that bound every pattern

| Fact | Verdict | Source |
|---|---|---|
| MCP calls are proxied by Anthropic's backend, not the user's device | ✔ | [Claude MCP Apps troubleshooting][cl-apps] |
| Supported: tools, prompts, resources; text and image results; text and binary resources. Not supported: subscriptions, sampling | ✔ | [Claude connector building][cl-build] |
| Max tool result ~150,000 characters; tool call timeout 240 s | ✔ | [cl-build] |
| A larger result is written into the code-execution sandbox instead of the conversation (when the sandbox is active) | ✔ | [cl-apps] |
| Code execution egress: plan-dependent; "package managers and specific domains" allowlist documented for Team/Enterprise; "network communication remains possible through [MCP] connections regardless of the network egress setting" | ✔ | [Claude support 12111783][cl-sandbox] |
| Sandbox code can call a connector tool with file bytes | ? undocumented | — |
| Claude supports the draft file-uploads extension or `x-mcp-file` | ? no evidence; extension unmerged | [ext-pr] |
| Size limit on tool *arguments* | ? undocumented (bounded by model output) | — |

### 3.3 Server-by-server evidence

| Server (status) | Upload tool and schema | Download tool and schema | Bytes come from → go to | Encoding | Inline limit | Auth | Resumable | Claude web | Autonomous upload shown | Encryption |
|---|---|---|---|---|---|---|---|---|---|---|
| **GitHub MCP** (`github/github-mcp-server`, maintained; remote `api.githubcopilot.com/mcp/`) | `create_or_update_file {owner,repo,path,content,message,branch,sha?}`, content is the file "exactly as it should appear… Do not base64-encode it"; `push_files {files:[{path,content}]}` ([README][gh-readme]; [source][gh-src] L448-545, L1639) | `get_file_contents {owner,repo,path,ref?,sha?}`: text → embedded resource `text`; binary → embedded `blob`; **≥1 MB → `resource_link` + `download_url` in text** ([gh-src] L1104-1190) | model tokens → GitHub server → REST; download: GitHub → model, or a URL | model text (upload); embedded resource / link (download) | 1 MB read; upload bounded by model output | OAuth/PAT, scopes `repo` | ✖ | listed among hosts (Claude Desktop) | ✔ for model-written text only | TLS + GitHub at rest; plaintext at server |
| **Google Drive MCP** (Google, **Developer Preview**, `drivemcp.googleapis.com/mcp/v1`) | `create_file {title, contentMimeType, base64Content \| textContent, parentId, disableConversionToGoogleType}`, "For non-UTF8 contents, use the `base64_content` field" ([create_file][gd-create]) | `download_file_content {fileId, exportMimeType?}` → `{id,title,mimeType,content}` where content is "base64 encoded" ([download][gd-dl]); `read_file_content` for text | model tokens → Google; Google → model | base64 or text in JSON both ways | ? undocumented | OAuth, Drive scopes | ✖ | ✔ configure for Claude.ai Pro/Max/Team/Enterprise with redirect `https://claude.ai/api/mcp/auth_callback` ([config][gd-cfg]) | only via model-emitted base64 | TLS + Google at rest |
| **Box MCP** (Box, hosted `mcp.box.com`; community repo **discontinued**) | `upload_file` "Uploads a new file", `upload_file_version`; **`get_upload_url`** "temporary, single-use URL for uploading binary files" (default **Off**, admin-enabled) ([Box tools][box-tools]) | `get_file_content`; **`get_download_url`** temporary single-use URL (default Off) | **sandbox code → `upload.box.com`** directly; `dl.boxcloud.com` → sandbox | raw HTTP body via URL; inline for `upload_file` (schema not published) | ? | OAuth (`root_readwrite` …) ([setup][box-setup]) | ? | ✔ Claude connector ([Box Claude][box-claude]); "Some clients require you to allowlist specific domains" | **documented as needing a code-executing agent**; no Claude-specific demo found | TLS + Box at rest; admin guardrails ([admin][box-admin]) |
| **Google Cloud Storage MCP** (Google remote) | `write_text` (text only) | `read_object`: text or binary, "maximum supported file size is 8MiB" ([GCS MCP][gcs]) | model ↔ GCS | text / binary block | 8 MiB read | Google OAuth | ✖ | ? | text only | TLS + GCS at rest |
| **Filesystem reference** (`modelcontextprotocol/servers`, local stdio) | `write_file {path, content}` | `read_media_file` → image/audio block or embedded resource `blob`, base64 ([fs-src] L326-388) | **client-local disk** | base64 | none stated | none (local) | ✖ | ✖ not a remote connector | n/a | none |
| *Box community server (discontinued, REST-backed)* | `box_file_upload_tool {content: str\|bytes, file_name, parent_folder_id}` ([legacy doc][box-legacy]) | `box_file_download_tool {file_id, save_file?, save_path?}` | model or local path | — | — | — | — | — | — | — |

What could not be verified:
- **Hosted Box tool `inputSchema`s** are not published. They are visible only through an
  authenticated `tools/list`, which this research did not call.
- **Dropbox and Microsoft OneDrive/SharePoint:** searches returned only third-party
  servers (Workato, community PyPI and GitHub projects), not first-party MCP
  documentation. They are excluded rather than assumed. Third-party listings
  (unverified) describe a Graph upload-session flow and a ~4 MB base64 cap.
- **Claude-specific demonstrations** of Box `get_upload_url` running in the claude.ai
  sandbox were not found.

### 3.4 The recurring patterns

| # | Pattern | Who | Fits large files? |
|---|---|---|---|
| P1 | Model-written content inline in arguments | GitHub, Drive, GCS `write_text`, our `artifacts.create` | ✖ bounded by model output, corrupts binary (redmine #305) |
| P2 | Inline result: embedded resource or base64 field | GitHub < 1 MB, Drive, GCS ≤ 8 MiB, filesystem | ✖ above ~150k chars Claude diverts it to the sandbox |
| P3 | Link instead of bytes (`resource_link` / URL) | GitHub ≥ 1 MB, ext-draft downloads | ✔ for download if the fetcher can reach the URL |
| P4 | Short-lived signed upload/download URL, used by sandbox code | Box `get_upload_url/get_download_url`, redmine v2.16 tickets | ✔ size; needs sandbox egress to the URL host |
| P5 | Client-local path (stdio) | filesystem reference | ✖ remote connectors cannot reach the client's disk |
| P6 | Host-mediated out-of-band upload (`x-mcp-file`, PUT target) | ext draft only | ? needs host support; not shown in Claude |

---

## 4. Fit against our constraints

| Pattern | K1 autonomous Claude | K2 15 MiB | K3 no Claude crypto | K4 Hub-blind (Hub = MCP server) | K5 later decrypt |
|---|---|---|---|---|---|
| P1 inline args (+ relay seal) | ✔ (today) | ✖ (65,536 B; model output) | ✔ | ✖ plaintext in args at Hub | ✔ |
| P2 inline results (relay open) | ✔ | ✖ (64 KiB window; 150k chars) | ✔ | ✖ plaintext result from Hub | n/a |
| P3 link download | ✔ if sandbox can reach Hub | ✔ | ✔ | ✖ if the link serves plaintext; ciphertext-only links are useless to Claude without keys | n/a |
| P4 signed URL upload to Hub + relay seal | ✔ if egress allows the Hub domain (plan-dependent, A1 in `docs/plans/claude-browser-e2ee-artifact-upload.md`) | ✔ | ✔ | ✖ plaintext body reaches Hub | ✔ (stored as ciphertext) |
| P4 signed URL to a trusted-device endpoint | ? device must be publicly reachable (Claude rejects private IPs; tunnels Enterprise-only per earlier study C2) | ✔ | ✔ | ✔ bytes bypass the Hub | ✔ |
| P6 host-mediated | ? no Claude support | ✔ | ✔ | ✖ same as P4 when the target is the Hub | ✔ |

**Conclusion.** With the Hub as the MCP server and the upload target, every pattern
delivers plaintext to the Hub, because Claude cannot encrypt (K3). K3 and K4 can both
hold only if plaintext goes to a trusted device and never to the Hub. In other words, the
upload URL must point at the bridge, not the Hub. That route is unproven for claude.ai
(public reachability, egress allowlist). Server-side encryption at rest, as in Box,
Google and GitHub, does not satisfy K4 and is not E2EE.

**Trust-boundary decision needed (before any redesign):** either
(i) accept the relay's existing boundary for Claude uploads: *keyless* Hub, transient
plaintext in Hub memory, ciphertext at rest, the same as `artifacts.create` today, or
(ii) keep strict K4 and require the trusted-device endpoint route (option B), which needs
a reachability spike first.

---

## 5. Minimal reuse of the existing relay (reference design, not approved work)

### Option A: Box-style upload URL, sealed by the existing relay device (boundary (i))

Interface borrowed from Box `get_upload_url` and the ext draft (metadata first, then a
PUT target, then a retry or commit):

1. **Tool `artifacts.upload_begin`** `{name, content_type, kind: "html-bundle"|"file", size, sha256}`
   returns `{upload_url, expires_at, transfer_id}`. Rules:
   - The Hub refuses anything over 15 MiB from the metadata before any bytes move.
   - The upload URL is single-use and short-lived.
   - The tool description tells the model to PUT from the code sandbox, never to inline
     the content.
2. **Sandbox `PUT upload_url`** with raw bytes. The Hub streams them to a short-lived
   plaintext staging area. This is new: `transfers.odin` forbids plaintext, so the area
   must be separate.
3. **Hub enqueues a relay job.** It uses the existing `Control_Job`, consent, directory
   and signature checks with a new operation `seal_staged`. Its payload carries only
   `{transfer_id, size, sha256, kind, content_type}`, never the bytes. That keeps it
   under the 1 MiB frame.
4. **The bridge** (`mcp_transform.odin`) verifies the job as it does today, then pulls
   the staged plaintext over HTTPS with its enrolled identity. It checks size and
   SHA-256, seals with its unlocked keyring as `ham-ctl artifact create` does (and
   validates the bundle ZIP), and uploads the ciphertext through the **existing**
   `/api/v1/mcp/transfers` data path. It commits with its device-signed receipt.
5. **The Hub** stores the ciphertext artifact and deletes the plaintext staging. The
   tool result (or `artifacts.upload_status`) returns `artifact://…`.

What is reused: relay authorization (`control_job_verify`), bridge selection
(`mcp_bridge.odin`), the bridge's existing keyring and sealing, HTML bundle packaging
and validation, the ciphertext transfer backend, its receipts and limits.

What changes:
- The relay deadline (4–5 s) cannot cover a 15 MiB seal plus upload. Step 4 must reply
  "accepted" within the deadline and finish asynchronously, or the job needs its own
  longer deadline.
- The relay's 1 MiB frame and 4 MiB payload bounds stay untouched, because no bytes
  travel inside jobs.

**Trust boundary:** the Hub sees plaintext from step 2 until staging is deleted, and
Anthropic's sandbox holds it too. That matches the current relay for small writes, but
it is **not** Hub-blind.

Downloads for Claude would follow P3: a `resource_link` with a one-time URL. Serving
plaintext to Claude means the relay device decrypts into Hub staging, so the same
boundary applies. Downloads by *trusted devices* are already Hub-blind: the Hub serves
the stored ciphertext and the viewer decrypts.

### Option B: trusted-device endpoint (boundary (ii), unproven)

Same tool shape, but `upload_url` points to an endpoint terminated **on the bridge**, so
the Hub only brokers the URL. Before anyone designs this, it needs proof that a claude.ai
sandbox can reach a user-run public endpoint on the user's plan, and an answer to how
Claude learns a URL the Hub cannot redirect. As in earlier studies, this remains a
candidate, not a solution.

---

## 6. Unknowns and negative results

- ? Hosted Box `upload_file` and `get_upload_url` input schemas (no public schema; no
  authenticated `tools/list` was called).
- ? Whether Box `get_upload_url` has been demonstrated in the claude.ai sandbox. Box says
  it needs a code-executing agent and a domain allowlist on some clients.
- ? Claude support for `x-mcp-file` or the files extension: no documentation, and the
  extension is unmerged.
- ? Whether claude.ai Pro/Max egress can reach a custom domain such as the Hub (plan
  dependent; carried from the earlier study's A1).
- ? Whether sandbox code can invoke connector tools with file bytes.
- ✖ No first-party Dropbox or Microsoft OneDrive/SharePoint MCP documentation found in
  this research. Only third-party servers were found, so they are excluded.
- ✖ No surveyed vendor offers client-side or end-to-end encryption for MCP transfers.
- ✖ MCP has no merged file-transfer primitive (SEP-1306, 2356 and 2631 all closed
  unmerged).

---

## 7. Sources (retrieved 2026-11-02)

[spec-tools]: https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/docs/specification/2025-11-25/server/tools.mdx
[spec-res]: https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/docs/specification/2025-11-25/server/resources.mdx
[sep1306]: https://github.com/modelcontextprotocol/modelcontextprotocol/issues/1306
[sep2356]: https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2356
[sep2631]: https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2631
[redmine]: https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2631#issuecomment-5947482568
[xserver]: https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2631#issuecomment-6167017451
[ext-pr]: https://github.com/modelcontextprotocol/experimental-ext-file-uploads/pull/1
[ext-draft]: https://github.com/modelcontextprotocol/experimental-ext-file-uploads/blob/6101d34eb52b21d4b87028543ecd1fd59ed3d5df/specification/draft/file-uploads.md
[gh-readme]: https://github.com/github/github-mcp-server/blob/f2a07cd13243ea9773a0ef42692e5b0e156f0951/README.md
[gh-src]: https://github.com/github/github-mcp-server/blob/f2a07cd13243ea9773a0ef42692e5b0e156f0951/pkg/github/repositories.go
[gd-create]: https://developers.google.com/workspace/drive/api/reference/mcp/tools_list/create_file
[gd-dl]: https://developers.google.com/workspace/drive/api/reference/mcp/tools_list/download_file_content
[gd-cfg]: https://developers.google.com/workspace/drive/api/guides/configure-mcp-server
[box-tools]: https://developer.box.com/guides/box-mcp/tools.md
[box-setup]: https://developer.box.com/guides/box-mcp/setup.md
[box-claude]: https://docs.box.com/en/box-mcp/configuring-box-mcp-server/claude.md
[box-admin]: https://docs.box.com/en/box-mcp/admin-controls.md
[box-legacy]: https://github.com/box-community/mcp-server-box/blob/main/docs/box_tools_files.md
[gcs]: https://docs.cloud.google.com/storage/docs/reference/mcp
[fs-src]: https://github.com/modelcontextprotocol/servers/blob/194cc86e3ae6400958555bd4116849d822d69263/src/filesystem/server.ts
[cl-build]: https://claude.com/docs/connectors/building/index.md
[cl-apps]: https://claude.com/docs/connectors/building/mcp-apps/troubleshooting.md
[cl-sandbox]: https://support.claude.com/en/articles/12111783

- MCP spec 2025-11-25: [tools][spec-tools], [resources][spec-res]
- SEPs: [1306][sep1306], [2356][sep2356], [2631][sep2631] (comments [redmine][redmine], [cross-server][xserver]); extension [PR #1][ext-pr], [draft][ext-draft]
- GitHub MCP: [README][gh-readme], [repositories.go][gh-src] (commit `f2a07cd1`, 2026-10-28)
- Google Drive MCP: [create_file][gd-create], [download_file_content][gd-dl], [configure][gd-cfg]; Google Cloud Storage MCP: [reference][gcs]
- Box MCP: [tools][box-tools], [setup][box-setup], [Claude][box-claude], [admin controls][box-admin], [legacy community docs][box-legacy]
- Filesystem reference server: [server.ts][fs-src] (commit `194cc86e`)
- Anthropic: [connector building][cl-build], [MCP Apps troubleshooting][cl-apps], [code execution and file creation][cl-sandbox]
- Repository: files cited inline in §2 at base `d910a2e4`; related plans `docs/plans/claude-browser-e2ee-artifact-upload.md`, `docs/plans/mcp-large-artifact-transfers.md`
