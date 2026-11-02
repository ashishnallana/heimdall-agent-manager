# Claude browser agent → Hub-blind HTML bundle upload: feasibility

Status: **feasibility study, not implemented.** Task `task_18e44763bb01b861`, chain
`chain_18e43a321b7b6c60`. Complements `docs/plans/mcp-large-artifact-transfers.md`
(the "transfer plan"), whose executors are local `ham-ctl` or a Heimdall browser tab
where the user picks the file (§3 of that plan). Neither is an autonomous upload by
the **Claude browser agent** (claude.ai web/desktop/mobile using our remote MCP
connector). This document says what that client can actually do, which path keeps
the Hub blind, and what has to change. No application code changes here.

Target scenario (user):

1. On claude.ai, Claude writes an HTML site (one page or a multi-file bundle) and
   uploads it to Heimdall by itself. The user does not download or upload any file.
2. On another device, the user opens Heimdall and previews the bundle. This keeps
   working after the Claude conversation ends and after staging expires.
3. **Strict E2EE:** the Hub never receives plaintext bytes, plaintext digests,
   names or descriptions, or any key that can decrypt them.

Anthropic sees the plaintext in every option: Claude writes it. The requirement is
about the **Hub** (our server, its operators, or anyone who compromises it).

## 1. Verified Claude browser capabilities (primary sources)

Every source is official Anthropic documentation or the official MCP Apps
specification. Retrieved 2026-11-02. ✔ = documented, ✖ = documented as not
supported, ? = undocumented (anything we build on it is an assumption, §3).

| # | Capability | Verdict | Source and quote |
|---|---|---|---|
| C1 | Where MCP calls come from | ✔ Anthropic cloud only, never the user's device | claude.com/docs/connectors/building/mcp-apps/troubleshooting.md: "MCP tool calls are proxied through Claude's backend and egress from Anthropic's published IP ranges, not the user's device." |
| C2 | Connector endpoint address | ✔ public, globally routable IPv4 only; private, CGNAT and loopback addresses are rejected | claude.com/docs/connectors/building/troubleshooting.md: "If any resolved address isn't globally routable, Claude rejects the connection … Connectors are IPv4-only." Exception: MCP tunnels, "available to organizations on the Claude Enterprise plan by request" (…/mcp-tunnels/overview.md). |
| C3 | Transport and auth | ✔ Streamable HTTP (legacy SSE deprecated); OAuth with DCR, CIMD or a pre-registered client, PKCE S256 | …/building/index.md; …/building/troubleshooting.md |
| C4 | MCP features | ✔ tools, prompts, resources, text and image results. ✖ "Resource subscriptions, Sampling, Advanced or draft capabilities" | …/building/index.md |
| C5 | Elicitation (form and URL mode) | ✖/? Anthropic does not document it; it falls under "advanced or draft" | Not documented. A third-party vendor page also says it is unsupported. |
| C6 | Tool result size and time | ✔ "Maximum tool result size: ~150,000 characters", "Tool call timeout: 240 seconds" | …/building/index.md |
| C7 | Tool **argument** size | ? not documented. Bounded by model output: current models list "Max output: 128K tokens" (API limit; the claude.ai cap is not published) | platform.claude.com/docs/en/about-claude/models/overview |
| C8 | MCP Apps (`ui://` resources) render | ✔ web, desktop, mobile | claude.com/docs/connectors/overview ("full remote MCP support & MCP Apps") |
| C9 | MCP App sandbox origin | ✔ `{hash}.claudemcpcontent.com`, nested iframe; `_meta.ui.domain` gives a stable origin | …/mcp-apps/troubleshooting.md; ext-apps spec 2026-01-26 `apps.mdx` |
| C10 | MCP App network | ✔ `connect-src 'none'` by default; `_meta.ui.csp.connectDomains` allows `fetch` **from the user's device**, so the server must answer CORS for `*.claudemcpcontent.com` | …/mcp-apps/design-guidelines.md, …/mcp-apps/troubleshooting.md, ext-apps spec |
| C11 | MCP App ↔ host | ✔ gets the tool input and result (`ontoolinput`/`ontoolresult`), can call server tools with visibility `"app"`, can open links (always with a confirmation dialog for custom connectors) | ext-apps spec; …/mcp-apps/external-links.md |
| C12 | MCP App storage and WebCrypto | ? not documented (`allow-same-origin` implies storage exists, probably partitioned under claude.ai) | ext-apps spec has no storage section |
| C13 | Code execution sandbox ("Create and edit files") | ✔ isolated container. Egress can be **off**, **package managers + domains you specify**, or **all domains**. "network communication remains possible through [MCP] connections regardless of the network egress setting"; 30 MB per file | support.claude.com/en/articles/12111783 |
| C14 | Sandbox file → connector tool as bytes | ? not documented. The only documented direction is large MCP results written *into* the sandbox | same, and …/mcp-apps/troubleshooting.md |
| C15 | Artifacts calling MCP connectors | ✔ paid plans, web and desktop, with per-tool approval | support.claude.com/en/articles/9487310 |
| C16 | Artifact `fetch` to any origin | ? no official CSP documentation | — |
| C17 | Custom Skills (user-uploaded scripts the model runs in the sandbox) | ? **not verified in this study.** Believed available on paid plans with code execution. Must be verified before T-B3 (§6) | to verify: support.claude.com Skills articles |

### What these facts rule out

- **R1. Model-written text in tool arguments always reaches the Hub in plaintext.**
  Anthropic sends `tools/call` to the connector URL (C1). Our connector URL is the
  Hub (`/api/v1/mcp`). TLS ends at the Hub, and MCP has no argument encryption.
  Our own "device mode" `artifacts.create` gets the content in clear and forwards it
  to the bridge as `job.payload` (`src/bridge/mcp_transform.odin:10-14`). Under the
  strict requirement, **any design where plaintext travels in arguments to a
  Hub-terminated connector fails.** That covers today's `artifacts.create`, an
  `upload_inline`, and MCP App `ontoolinput`: the same arguments also go to the
  server (C1, C11).
- **R2. No path from the user's browser reaches a trusted device directly.** MCP
  traffic never starts in the browser (C1). The only code that runs in the user's
  browser is an MCP App or an artifact. The App's HTML is a `ui://` resource *served
  by the connector*, which is the Hub, so it is Hub-controlled code. It has no
  Heimdall device keys either, because it runs on a different origin (C9, C12).
  The App also gets the plaintext only through tool input, which R1 already rules
  out.
- **R3. A bridge cannot be a connector on a private address** (C2), except through
  an Enterprise MCP tunnel or a public tunnel that the user runs.
- **R4. Large bytes cannot pass through the model.** Already a chain dead end
  (15 MiB = 20,971,520 base64 bytes). Model output (C7) is roughly 100–250 KB of
  HTML per call (inferred, §3 A4).

What remains: encryption has to happen in a place the Hub does not control, with a
key the Hub cannot replace. On claude.ai there are only two such places. One is
**the code execution sandbox** (Anthropic's container, running code the model writes
or the user installs). The other is **a trusted device the user exposes as its own
connector**.

## 2. Candidate paths

| Path | Where it encrypts | Hub blind? | Autonomous? | Setup and online needs | Verdict |
|---|---|---|---|---|---|
| **P0** today's `artifacts.create` (device or hosted mode) | bridge or Hub, **after** the Hub receives the arguments | ✖ (R1) | ✔ (text up to 64 KiB) | — | Fails strict E2EE |
| **P1** MCP App iframe encrypts | user's browser, Hub-served code | ✖ the plaintext reaches it only through tool input (R1, R2) | ✔ | — | Incompatible |
| **P2** Claude artifact page uploads | user's browser | ✖ goes through connector tools (C15) → R1; direct `fetch` is undocumented (C16) | partly | — | Incompatible / unverified |
| **P3** Sandbox encrypts to a vault **inbox public key**, then PUTs ciphertext to the Hub data path | Anthropic sandbox | ✔ if the key is pinned outside the Hub (§4.2) | ✔ | Code execution on; Hub domain on the egress allowlist (C13); a pinned key or Skill installed once; **no device online during upload** | **Recommended** |
| **P3i** as P3, but the ciphertext goes back through a tool argument | Anthropic sandbox | ✔ ciphertext only | ✔ for small files | Code execution on; no egress needed | Fallback; size and accuracy unproven (A5) |
| **P4** The user's bridge is a second connector over a public TLS-passthrough tunnel; the bridge seals | trusted bridge | ✔ if TLS ends on the bridge and the tunnel provider is not the Hub | ✔ (text per call ≤ C7) | Bridge online and unlocked **during upload**; public tunnel (Tailscale Funnel, Cloudflare Tunnel, Enterprise MCP tunnel); OAuth served by the bridge | Alternative for users who cannot enable egress |
| **P5** tradeoff: hosted decryption consent | Hub | ✖ by definition | ✔ | — | Only if the user relaxes strict E2EE |

P3 reuses the most completed work: the ciphertext-only data path `bf234a70`, the
transfer tools `19282048`, and the bounds and slots. It also needs no device online
at upload time. P4 gives an authenticated origin but needs an always-online,
publicly reachable bridge.

## 3. Assumptions (must be demonstrated, not yet verified)

| Id | Assumption | How to prove it | Blocks |
|---|---|---|---|
| A1 | Sandbox code can reach `https://<hub>` once that domain is on the egress allowlist (Pro/Max: "package managers + domains you specify"; Team/Enterprise: owner setting) | Spike: `curl -sI https://<hub>/healthz` from a claude.ai analysis run with and without the allowlist entry | P3 |
| A2 | The sandbox has Python `cryptography` (or can `pip install` it via the package-manager egress) | Spike: `python -c "import cryptography"` | P3, P3i |
| A3 | Custom Skills exist on the user's plan and run their bundled script unchanged (C17) | Install a test Skill and run it | P3 pinning option (b) |
| A4 | Claude can write a multi-file site into the sandbox and zip it there | Spike (low risk) | P3 |
| A5 | Claude can copy ≤ 32 KiB of base64 from tool output into a tool argument without errors | 20 trials; GCM rejects any corrupted copy | P3i |
| A6 | claude.ai honours `additionalProperties:false` schemas and per-tool disable in connector settings | Settings UI check | §4.4 residual |

None of A1–A6 is claimed as fact. The **first replacement task (T-B0, §6) is a spike
that proves them on claude.ai** and records evidence (screenshots and transcripts in
an artifact), before any implementation.

## 4. Recommended design: P3 "sandbox seals to the vault inbox"

### 4.1 Keys: a vault inbox key pair

- When an epoch is created or rotated, a trusted device (browser or bridge) generates
  a P-256 ECDH key pair `(inbox_sk_e, inbox_pk_e)`.
- It stores an **inbox key record**
  `{vault_id, epoch, inbox_pk (hex), sealed_sk = vault v2 token of inbox_sk under epoch e, created_by_device_id, signature}`.
  The signature is over the domain-separated statement
  `heimdall-vault-inbox/v1|<user_id>|<vault_id>|e<epoch>|<inbox_pk>` and is made
  with the device identity key: P-256 ECDSA, the same primitive as directory
  statements (`src/lib/vault/statement.odin`, `src/ui/utils/mcpWorker.ts:200-203`).
- Every unlocked device opens `sealed_sk` with the keyring it already holds. No new
  key distribution is needed, and the multi-epoch keyring
  (`src/lib/vault/keyring.odin`) keeps old envelopes openable after rotation.
- The Hub stores the record and can check the signature against the verified
  directory (`src/lib/vault/directory_verify.odin`). It cannot open `sealed_sk`.
- Primitives already exist: `ecdh_hkdf_key` (`src/lib/vault/channels.odin:28-42`,
  ECDH P-256 → HKDF-SHA256) and AES-256-GCM. On the browser side, WebCrypto
  ECDH/HKDF/AES-GCM, with non-extractable device keys
  (`src/ui/utils/deviceIdentity.ts:127-157`).

### 4.2 Pinning `inbox_pk` outside the Hub (the key point)

A public key handed out by the Hub at upload time is worthless against a malicious
Hub: it would hand out its own key. The sandbox therefore uses a key the user
installed **on the Claude side**. The user picks one option:

- **(a) Project or custom instructions:** the Heimdall UI shows, under *Settings →
  Vault → Claude upload key*, a block like
  `HEIMDALL_INBOX v1 <vault_id> e<epoch> <inbox_pk_hex>`. The user pastes it into a
  Claude Project's instructions. The model must use exactly this key.
  - Weakness: the Hub writes the tool descriptions and results the model reads, so a
    malicious Hub could try to persuade the model to use another key (prompt
    injection).
- **(b) Custom Skill (preferred if A3 holds):** the UI produces a Skill zip,
  `heimdall-sealed-upload`, containing `seal_upload.py` with `inbox_pk` hard-coded
  plus a SHA-256 self-check. The user downloads it once from Heimdall and installs it
  in Claude.
  - The script ignores any key the Hub supplies. The Hub can still lie in text, but
    it cannot change the encryption code or the key.
  - This is a one-time setup step, not a per-upload file transfer.
- Epoch rotation creates a new inbox key. Option (a) needs re-pasting; option (b)
  needs reinstalling. Until then, uploads keep working against the old epoch's
  key, because every device keeps old epochs. The UI reports "Claude upload key is
  stale" and offers revocation.

### 4.3 Envelope format `vault:inbox1`

```
vault:inbox1:<vault_id 16 hex>:e<epoch>:<b64( eph_pk(65) ‖ nonce(12) ‖ ct ‖ tag(16) )>
key = HKDF-SHA256(ikm = ECDH(eph_sk, inbox_pk_e), salt = 32×0x00,
                  info = "heimdall-vault-inbox-v1|<vault_id>|e<epoch>|<transfer_id>|<artifact_id>")
AAD = "heimdall-vault-inbox-v1|<vault_id>|e<epoch>|<transfer_id>|<artifact_id>|<kind>|<content_type>"
plaintext = file bytes (html-bundle: the .zip)
```

- AAD binds the reserved artifact id. This fixes the v2 swap limitation that the
  transfer plan §2 mentions.
- `len(ct) = len(pt)`, so the Hub's blind 15 MiB check is the same arithmetic with an
  extra 65 B overhead.
- `name` and `description` are sealed the same way, as separate small `inbox1`
  tokens with `|name` / `|description` appended to `info` and AAD.

### 4.4 Sequence

```
 Claude (model)            Anthropic sandbox                 Hub (ciphertext only)          trusted device (later, any)
 ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 writes site files ───────▶ /tmp/site/*, zip → site.zip
 tools/call artifacts.upload_begin{request_id, kind:"html-bundle",
        content_type:"application/zip", envelope:"inbox1"} ───────────────▶ transfer row, reserved art_id, hxt_ token,
                                                                   inbox_key {vault_id, epoch, inbox_pk, record_sig}
 ◀──────────────────────────────────── {transfer_id, artifact_id, upload_url, token, inbox_key}
 runs seal_upload.py ─────▶ check pinned pk == inbox_key.inbox_pk (mismatch → abort, report)
   (token via env var)      read zip ≤ 15,728,640 B; validate bundle (members/size, mirrors
                            src/ctl/html_bundle.odin rules); seal inbox1; seal name/description
                            PUT …/transfers/{id}/ciphertext (Authorization: Bearer hxt_…) ──▶ staging (≤1 MiB rows)
                            POST …/transfers/{id}/seal {envelope:"inbox1", sealed_name, …} ──▶ blind checks §4.5 → sealed
                            prints {transfer_id, ciphertext_sha256}
 tools/call artifacts.upload_commit{request_id, transfer_id, ciphertext_sha256} ─▶ insert artifact, content = inbox1 token,
                                                                   origin = "claude_sandbox_unverified"
 ◀─────────────── {artifact_id, link, state:"committed", finalized:false}
                                                                                           (other device, any time)
                                                                   GET artifact (inbox1) ─────▶ open sealed_sk with keyring,
                                                                                                 ECDH/HKDF/GCM open, readHtmlBundle,
                                                                                                 preview (inert JS)
                                                                   ◀── optional finalize: re-seal as v2 + signed
                                                                       "finalized" receipt (same artifact id, revision+1)
```

- **Cross-device view after the uploader disconnects:** the inbox1 token is a
  committed artifact, not staging, so it survives staging expiry. Any unlocked
  device can open it. Finalizing is optional: it moves storage to plain v2 for older
  readers and records who opened it.
- **No device has to be online during the upload.**
- The bearer token is shown to the model and the transcript. The transfer plan
  §5.3 already accepts this (ciphertext only, one transfer, ≤ 60 min).
- **Residual risk:** a malicious Hub can still tell the model, through tool text,
  to call a plaintext tool. Mitigation: the user disables `artifacts.create` and
  `artifacts.update` for this connector in claude.ai (A6), and the Hub refuses
  plaintext content on grants flagged `strict_e2ee` (§5).

### 4.5 Hub blind checks for inbox1 (no key involved)

The Hub checks:
- the prefix, `vault_id` = owner vault, and `epoch` ∈ epochs with an inbox record
  whose signature verifies against the directory;
- base64 canonical form and length ≤ `inbox1_armored_max(15 MiB)`;
- `eph_pk` is a valid P-256 point (public check);
- that the transfer is bound to (owner, grant, artifact id).

It **cannot** validate bundle contents (transfer plan dead end). The viewer validates
them with `readHtmlBundle` and keeps JS inert.

### 4.6 What the user sees and what is proven

| Property | P3 |
|---|---|
| Hub learns plaintext, plaintext digest, name or key | No. Only length (inherent, as with v2) and timing |
| Confidentiality against a malicious Hub | Yes, provided the pin (§4.2) is honoured |
| **Origin authenticity** | **No.** Anyone with `inbox_pk`, including the Hub, can create an inbox1 envelope. The viewer labels these artifacts "Uploaded by Claude (origin not verified)", like the transfer plan's Unverified-origin state. With option (b) the Skill can print `sha256(zip)` in the Claude chat and the viewer shows the same digest, so the user can compare by eye. The digest stays on the Anthropic and device sides and is never sent to the Hub. |
| Substitution / swap between artifacts | Prevented by AAD binding of transfer and artifact id (§4.3) |
| HTML bundle safety | Same viewer sandbox as today: scripts removed, no `allow-scripts` (`docs/html-bundle-artifacts.md`) |

## 5. Exact implementation changes (P3), reusing completed work

Reused unchanged:
- `bf234a70`: ciphertext-only transfer storage and HTTP, bearer `hxt_`, pre-body
  gate, slots and deadlines (`src/hub/transport/http/mcp_transfer_handlers.odin`,
  `src/hub/service/mcp/transfers.odin`).
- `19282048`: transfer MCP tools and strict argument parser
  (`src/hub/service/mcp/transfer_tools.odin`,
  `src/hub/transport/http/mcp_transfer_tools.odin`).
- 15 MiB limits (`13d3b242`) and the HTML bundle viewer (`2919dec8`).

`03da07c2` (bridge transfer receipt signing) stays useful for the shell path and for
the "finalized" receipt.

| Area | Files | Change |
|---|---|---|
| Inbox key record | new `src/lib/vault/inbox.odin` (+ test); `src/ui/utils/vaultInbox.ts` (+ `tests/ui_vault_inbox_test.ts`) | Statement build/verify, record JSON, `inbox1` open (device side), blind length arithmetic; cross-runtime test vectors (Odin ↔ TS ↔ a Python reference script) |
| Storage | `src/hub/repository/sqlite/migrations/188_vault_inbox_keys.sql`, repository procs | `vault_inbox_keys(user_id, vault_id, epoch, inbox_pk, sealed_sk, created_by_device_id, signature, created_at)` |
| HTTP | `src/hub/transport/http/vault_directory_handlers.odin` | `PUT /api/v1/vault/inbox-keys/{epoch}` (session + approved device proof, signature verified); `GET` for owner devices |
| Transfer service | `src/hub/service/mcp/transfers.odin`, `src/lib/vault/envelope_blind.odin`, `src/hub/repository/sqlite/migrations/187_mcp_artifact_transfers.sql` follow-up column | `envelope` field (`v2` \| `inbox1`), blind checks §4.5, `commit` stores the inbox1 token, `origin = claude_sandbox_unverified` |
| MCP tools | `src/hub/transport/http/mcp_tools.json`, `mcp_transfer_tools.odin`, `src/hub/service/mcp/transfer_tools.odin` (the last two exist on `19282048`/`03da07c2`, branch of `task_18e442d6e89f4103`, not yet on this base `bf234a70`) | `upload_begin` accepts `envelope:"inbox1"` and returns `inbox_key` + `sandbox_hint`; descriptions state that the pinned key wins; result never carries plaintext |
| Strict grants | `src/hub/service/mcp/capabilities.odin`, consent UI | grant flag `strict_e2ee` refuses plaintext `content` in `artifacts.create/update` (`content_requires_sealed_upload`) |
| Sandbox script | new `tools/claude-skill/heimdall-sealed-upload/` (`SKILL.md`, `seal_upload.py`, `test_seal_upload.py`) | Python `cryptography`; pinned pk; bundle checks; PUT/seal; prints ciphertext sha256 and plaintext sha256 |
| UI | `src/ui/components/settings/RecoveryKeySection.tsx` (or a new sibling `ClaudeUploadKey.tsx`), `ArtifactViewer.tsx`, `HtmlBundlePreview.tsx`, `src/ui/utils/htmlBundle.ts` | create/rotate inbox key on epoch change; "Claude upload key" panel (pin block + Skill zip download); open inbox1 artifacts; unverified-origin badge with digest; optional finalize to v2 |
| ctl | `src/ctl/artifact*.odin` | `ham-ctl artifact get` opens inbox1 (agent keyring) |
| Docs | `docs/mcp-capabilities.md`, `docs/html-bundle-artifacts.md`, transfer plan §3/§8 | Claude browser row, setup, residual risks |

P4, if the user wants it later, is a separate project: bridge-hosted MCP server
with its own OAuth AS, a tunnel adapter, and sealing via existing
`vault.seal`. It is not planned here.

## 6. Replacement task plan

| Task | Scope | Depends | Gate |
|---|---|---|---|
| **T-B0 spike** (no product code) | Prove A1–A6 on the user's claude.ai plan: egress to the Hub domain, `cryptography`, Skills, zip, base64 copy accuracy, per-tool disable. Output: an evidence artifact | this review | **user**: confirms the setup cost (code execution + egress allowlist + one-time pin/Skill) is acceptable, or picks P4/P5 |
| **T-B1** inbox keys | §5 rows "Inbox key record", "Storage", "HTTP", UI create/rotate | T-B0 | review |
| **T-B2** inbox1 transfers | §5 rows "Transfer service", "MCP tools", "Strict grants"; tests: blind checks, AAD binding, plaintext-marker scan (reuse `mcp_transfer_tools_test.odin` patterns) | T-B1, `bf234a70`, `19282048` | review |
| **T-B3** sandbox Skill/script | `tools/claude-skill/…`, cross-runtime vectors | T-B1 | review |
| **T-B4** viewer + cross-device | open, preview and finalize inbox1; unverified badge; REQ-CROSS-DEVICE test (upload from claude.ai, disconnect, staging expiry, open on a second device) | T-B2, T-B3 | review + **user demo on claude.ai** |

Existing tasks:
- `task_18e442d6e89f4103` (held at `03da07c2`): keep its finished X4 (`19282048`).
  Narrow the rest to the shell executor (X5: finish and verify the bridge receipt
  RPC, `ham-ctl artifact transfer`). Drop X6 (the browser tab executor where the
  user picks a file), since it is not autonomous.
- `task_18e442dc5048dd2a`: depends on T-B4 as well.
- `task_18e43fc82ae1bc46`: closes after T-B4 is demonstrated.

## 7. Decisions and open items

- **Decided:** any plaintext in tool arguments to the Hub connector fails strict
  E2EE (R1). MCP App and artifact paths cannot avoid it (R2).
- **Decided:** recommend P3 (sandbox encrypts to a vault-shared inbox key pinned on
  the Claude side, ciphertext over the existing data path).
- **Tradeoff (accepted only with user sign-off):** P3 needs code execution, a
  Hub-domain egress allowlist and a one-time pin or Skill. P3 cannot prove the
  origin of an upload.
- **Open (user):** P3 vs P4 (an online bridge with a public tunnel gives an
  authenticated origin) vs P5 (relax strict E2EE).
- **Open (verify):** A1–A6 in T-B0.
