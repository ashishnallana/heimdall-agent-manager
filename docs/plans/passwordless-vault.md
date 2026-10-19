# Passwordless vault — implementation plan

Status: approved for implementation · Branch: `passwordless-vault`
Proposal: https://claude.ai/artifact/SkGGa5tdZEnW92UbKxkXVL

## Product requirements (from the owner)

1. **No master password, no vault lock/unlock UI.** Each device generates its own keys; the account keyring is wrapped to every approved device. Remove (do not hide) password setup, unlock, lock and onboarding screens and state.
2. **One approval surface.** A notification on approved devices plus the page `/device/add?code=…` where a logged-in user on an approved device approves a pending device by its device code. The same flow enrolls **new bridges** and **new browser logins**. Electron is out of scope.
3. **Device list with revoke.** Settings lists every connected device (browsers, bridges, recovery) with label, kind, fingerprint, approved-by and last-seen. Any device can be revoked **except the current device** (enforced in UI and by the hub). Revoking the last approver-capable device is refused unless a recovery key exists. Revoke rotates to a new epoch and re-unseals the remaining bridges.
4. **No backward compatibility.** v1 envelopes, PBKDF2, `user_vaults`, password migration, "vault not configured" plaintext modes and any legacy-format fallbacks are deleted, not shimmed. Dev data may be wiped; old bridges re-enroll.
5. **Production security bar — no shortcuts.** This ships to real users.
6. **Vault reset (decided by the engineering lead, revisit if needed).** Creating the account root (genesis) and registering devices need an interactive browser login, not a CLI token. If the root was set up by someone else or every device is lost and there is no recovery key, the user can request a reset from a fresh login; it runs after a 72-hour delay, every session and device is notified, and any approved device can cancel it. A reset destroys the directory and all keys (history becomes unreadable).

## Engineering rules for every phase

- Treat the hub as hostile for confidentiality and integrity of the device directory. Clients verify every signature/chain before wrapping or trusting keys; fail closed.
- Tests are kept MINIMAL for now (owner decision): shared TS+Odin vectors plus a compact set of security-critical negatives (tamper, epoch swap, unknown epoch/alg, replay, unsigned keys, CAS/self-revoke on the hub). The longer per-phase negative lists are a backlog, not a gate. Implementation must still be fully fail-closed.
- Tests are HERMETIC (owner requirement): no real OS keystore (inject a fake backend), no HOME/USERPROFILE or real data dirs (per-test temp dirs), no network or fixed ports (ephemeral ports / in-process fakes), no running hub/bridge/vite, injectable clock and randomness where assertions depend on them, order- and parallel-independent. The P2.5 e2e script starts its own throwaway hub on an ephemeral port with a temp DB.
- No plaintext fallbacks for fields that must be encrypted. No silent catch-and-continue around crypto. Randomness failure aborts.
- Constant-time comparison for MACs/tags/fingerprints where compared outside GCM. Zero raw key bytes after use where the runtime allows.
- CAS (version) on every directory mutation; 409 on conflict.
- Keep code idiomatic with the surrounding files; no new dependencies without a stated reason.
- Each phase is implemented by a coder agent, then reviewed by an adversarial security reviewer, then fixed, until no critical/high findings remain. Each phase lands as its own commit(s) on `passwordless-vault`.

## Verification (Windows)

```powershell
$odin="$env:LOCALAPPDATA\Programs\Odin\dist\odin.exe"
# checks for each of src/hub src/bridge src/ctl src/lib/vault, with no -target, -target:linux_amd64, -target:darwin_arm64
& $odin check src/bridge -collection:odin_test=src -target:linux_amd64
# tests needing sqlite
& $odin test <pkg> -collection:odin_test=src "-extra-linker-flags:/LIBPATH:C:/Users/Tanmay/heimdall-win-build/deps/lib" -out:$env:USERPROFILE\.cache\heimdall-tests\x.exe
npm run typecheck; npm test; npm run build
```

Bridge/ctl suites that spawn `sh`/`setsid` can't run on Windows; select tests with `-define:ODIN_TEST_NAMES=...`.

---




## 0. What the code does today (constraints the plan has to respect)

**The vault key is a single 32-byte AES key everywhere.**
- UI: `src/ui/utils/vaultCrypto.ts` holds one active CryptoKey (:26-58). It also keeps the raw key as hex in memory for bridge delivery (`activeBridgeVaultKeyHex`, :27, :42-45), and has PBKDF2 code (:281-316).
- Bridge: `bridge_read_vault_key()` (`src/bridge/main.odin:879`) returns one 64-hex string.
- ham-ctl: `ctl_read_vault_key` (`src/ctl/vault.odin:55`) does the same. There are about 85 call sites in ctl.

**The v1 envelope and its literal prefix are duplicated in many places.**
- Prefix constants: UI `vaultCrypto.ts:17`, bridge `vault_decrypt.odin:10`, ctl `vault_content.odin:16`, hub `domain/vault_text_caps.odin:33`.
- Hub code that hardcodes `vault:v1:`:
  - `taskchain_repo_sqlite.odin:290`
  - `agent_service.odin:892`
  - `bridge_service.odin:464`
  - `taskchain_service.odin:921,1292,1332`
  - `taskv2/facets.odin:61,107`
  - `agent_action_handlers.odin:283`
  - `issue_handlers.odin:20`
  - `shell_stream_screen_snapshot.odin:279-290` (base64-decodes the armor body into a SCREEN frame)
- UI regexes: about 15 components, e.g. `ChatMessageList.tsx:90`, `MessageItem.tsx:81`, `TaskCommentsThread.tsx:98-121`, `vaultTextHelper.ts:121,132`, `vaultContent.ts:35,82`.

**Encrypted PTY frames carry no epoch.** The format is nonce(12)|tag(16)|ct (`pty_host_stream_worker.odin:600-690`, `ptyWire.ts:78-92`). The bridge builds the nonce as salt[4]||seq.

**Unseal protocol.**
- `src/bridge/unseal_protocol.odin` is ECDH P-256 → HKDF-SHA256 (zero salt, info `heimdall-bridge-unseal-v1`) → AES-GCM.
- AAD is `bridge_id:ts:nonce`, with a second JSON-form AAD accepted as a fallback (:281-299).
- The plaintext must be 32 bytes or 64 hex chars (:302-311).
- The TS mirror is `src/ui/utils/vaultBridgeUnseal.ts:138-265`.

**The bridge's ECDH key is per-process and also serves as its enrollment identity** (`enroll_device_flow.odin:941`). The comment block at `BridgeEnrollmentApprovalPage.tsx:36-48` admits the key changes on every restart and is trusted as served by the hub.

**Every bridge keystore assumes a 64-hex key.**
- `keystore_linux.odin:221`, `keystore_darwin.odin:197`, `keystore_android.odin:63`, `keystore_windows.odin:61-99`.
- Windows Credential Manager limits the blob to 2560 bytes.

**Hub vault storage.**
- `user_vaults` is created in `047_user_vaults.sql`.
- Saves are a blind upsert: `user_vault_service.odin:49-68` and `user_vault_repo_sqlite.odin:62-79` use `ON CONFLICT DO UPDATE` with no compare-and-swap (CAS).
- The table is re-created by a self-heal twin (`migrations.odin:876` calls `upgrade_user_vaults_schema` at :1466). There is also a skip-guard (:678) and a `migration_sql` entry (:944).
- `migration_order :: [95]string` (:420) is a fixed-size array.
- Routes: `wiring.odin:523-524`. Bridge minting refuses to run without a `user_vaults` row (`wiring.odin:883`).

**`device_auth` is the bridge/CLI device-code flow.** Grants live in memory (`grant_store.odin`). Routes are at `wiring.odin:494-499`. The UI page `/device/add?code=` (`AppShell.tsx:1237,1903`) renders `BridgeEnrollmentApprovalPage.tsx` (1318 lines, password prompt at :731-793).

**Search key.** It is HKDF of the raw key with domain `heimdall/task-chain-search-rpc/v1`, in TS (`taskChainSearchKey.ts:3-43`) and in the bridge (`task_chain_search_rpc.odin:15-35`). It is coupled to the raw bridge key material in `vaultSlice.ts:48-71`.

**Shell `enc_spec` authorization** means "holds any vault key" (`hub_runtime_client.odin:4260-4271`).

**Odin has the primitives we need.** The installed `core:crypto/ecdsa` provides `sign_raw` / `verify_raw` with raw r‖s signatures, which matches WebCrypto ECDSA. So the hub and the bridge can both verify browser signatures.

**Event fan-out:** `events.publish_resource_changed` (`event_bus.odin:61`). Push notifications go through `service/push/push_service.odin`.

**Tooling.**
- Odin is not on Git Bash's PATH. It lives at `%LOCALAPPDATA%\Programs\Odin\dist\odin.exe` (nightly `dev-2026-09`).
- The Windows `sqlite3.lib` is at `C:\Users\Tanmay\heimdall-win-build\deps\lib`.
- `npm test` lists test files explicitly in `package.json`, so new test files must match an existing glob or be added.

## 1. Wire formats (shared by all phases)

All binary values are hex unless marked b64. Signatures are ECDSA P-256 / SHA-256, raw r‖s (64 bytes).

**Device identity (browser).**
- Two non-extractable WebCrypto key pairs stored in IndexedDB (`heimdall_device` DB): ECDSA P-256 for signing and ECDH P-256 for receiving wraps.
- Separate keys are justified because WebCrypto cannot use one P-256 key for both ECDH and ECDSA.
- `device_id = "dev_" + hex(SHA256(sign_pub_raw65))[0:32]`.
- `fingerprint` = first 8 bytes of `SHA256(sign_pub‖ecdh_pub)` as four groups of four hex digits. This reuses the style of `bridge_key_fingerprint_for`.

**Bridge identity.**
- A new persistent ECDSA P-256 key, created at enrollment and stored in the keystore next to the keyring.
- Each boot, the bridge signs its ephemeral ECDH unseal key with it. The canonical bytes are:

  `heimdall-bridge-unseal-key/v1\n<bridge_id>\n<ecdh_pub_hex>\n<boot_id>`

**Credential agility (passkeys / YubiKeys later — design for it now, do not build it).**
A directory entry is a *credential* with two independent capabilities, each named by an algorithm id, verified/dispatched through one allowlist on every runtime (unknown id → reject, fail closed):
- `sign_alg` — how the entry signs statements and request signatures. Now: `ecdsa-p256-sha256` (raw r‖s over the canonical bytes). Later: `webauthn-es256` (assertion where `challenge = SHA256(canonical bytes)`; signature object carries `authenticator_data` + `client_data_json`), which a passkey or YubiKey can produce.
- `wrap_alg` — how a keyring copy is wrapped to the entry. Now: `ecdh-p256-hkdf-sha256-aes256gcm`. Later: `webauthn-prf-hkdf-sha256-aes256gcm` (PRF/hmac-secret output → HKDF → AES-GCM; per-wrap PRF salt in the wrap JSON) for passkeys/YubiKeys.
- `kind` is a display/policy class (`browser|bridge|recovery` now; `passkey|security_key` later). Policy (who may approve, who counts toward the last-approver guard) is computed by ONE function per runtime from `kind`, never by scattered string compares. Bridges: never approve.
Consequences for the formats below: every signature is a JSON object `{"alg":…,"sig":…}` (plus alg-specific fields), every wrap JSON carries `"alg"`, statements carry `subject_sign_alg` and `subject_wrap_alg`, and the hub stores `sign_alg`/`wrap_alg` columns. `kind` is validated in domain code (not an SQL CHECK) so a new kind needs no table rebuild. No passkey code ships now; the extension points are the allowlists and the dispatch functions, each with a test proving unknown ids are rejected.

**Signed statements.** Canonical bytes are UTF-8 lines joined by `\n` in a fixed field order, with no trailing newline.
- Values must match `[A-Za-z0-9_.:-]*`. Free text such as labels is base64url.
- Template:

  ```
  heimdall-vault-statement/v1
  type=<genesis|approve|revoke|epoch|wrap|recovery>
  user_id=…
  directory_version=<n>        (the version the CAS write expects)
  issuer_device_id=…
  issued_at_ms=…
  subject_device_id=…
  subject_kind=<browser|bridge|recovery>
  subject_sign_pub=…
  subject_ecdh_pub=…           (empty for bridge)
  subject_sign_alg=…           (e.g. ecdsa-p256-sha256)
  subject_wrap_alg=…           (e.g. ecdh-p256-hkdf-sha256-aes256gcm; empty for bridge)
  subject_label_b64=…
  epoch=<n>
  epoch_commit=…
  wrap_sha256=…
  ```

- Fields that do not apply to a type are present but empty, so the layout is fixed.
- `epoch_commit = HMAC-SHA256(epoch_key, "heimdall-epoch-commit|<user_id>|<epoch>")`. It lets a receiver check that the keyring it unwrapped matches the signed epoch.
- `genesis` is self-signed by the root device. It sets epoch 1 and pins `root_sign_pub`.

**Keyring plaintext (binary).**
- Layout: `"HKR1" | u16be uid_len | user_id | u32be current_epoch | u16be count | count × (u32be epoch | key[32])`, entries ascending.
- Capped at 64 epochs: 4+2+64+4+2+64·36 = 2380 bytes, which fits the Windows Credential limit.
- Epochs start at 1.

**Keyring wrap (stored on the hub, one per recipient).**
- Construction: ephemeral ECDH → HKDF-SHA256 (32 zero-byte salt, info `heimdall-keyring-wrap-v1`) → AES-256-GCM.
- AAD = `heimdall-keyring-wrap-v1|<user_id>|<recipient_device_id>|<directory_version>|<current_epoch>`.
- JSON shape:

  ```json
  {"v":1,"alg":"ecdh-p256-hkdf-sha256-aes256gcm","recipient_device_id","directory_version","current_epoch",
   "ephemeral_public_key","iv","ciphertext" /* ct‖tag */,
   "wrapped_by_device_id","signature" /* wrap statement; wrap_sha256 = SHA256(canonical wrap JSON minus signature) */}
  ```

**Bridge unseal v2.**
- The payload keeps the existing fields and adds `"format":"keyring-v1"`, `"current_epoch"`, and the bridge's `"unseal_key_signature"` echo.
- HKDF info becomes `heimdall-bridge-unseal-v2`.
- AAD = `heimdall-bridge-unseal-v2|<bridge_id>|<timestamp>|<nonce>|<current_epoch>`.
- The plaintext is the keyring bytes. The v1 AAD forms and the 32/64-byte plaintext paths are deleted.

**Content envelope v2.**
- Format: `vault:v2:e<epoch>:<b64std(nonce12‖tag16‖ct)>`, where epoch is decimal 1..4294967295 with no leading zero.
- AAD = `heimdall-vault-v2|e<epoch>`.
- Token regex: `vault:v2:e[1-9][0-9]{0,9}:[A-Za-z0-9+/]+={0,2}`.
- Encryption always uses the current epoch. Decryption picks the key by the epoch in the header; an unknown epoch shows as the locked marker.

**PTY payload v2** (revised after the P1 security review, finding H2).
- Per-stream subkey: `HKDF-SHA256(ikm=epoch_key, salt=salt16, info="heimdall-pty-v2|<session_id>|<out|in>")`; `in` and `out` use separate subkeys.
- Layout: `u32be epoch | salt16 | nonce12 | tag16 | ct`. A fresh random `salt16` on every stream-worker start and every epoch change; the nonce may be a counter within a subkey and is never reused under it.
- AAD = `heimdall-pty-v2|e<epoch>|<session_id>|out` for output and `heimdall-pty-v2|e<epoch>|<session_id>|in|<counter>|<bridge_boot_id>` for input. The counter is the nonce counter (u32 0 ‖ u64be counter); the bridge rejects any counter that does not increase for its (session, salt) stream (finding M1). `bridge_boot_id` is the bridge process's unseal boot id (announced to viewers in `ready`/`stream_ready`), so frames captured before a bridge restart, when the in-memory replay state is lost, no longer authenticate. `enc_spec` nonces are cached for their ±60 s window.
- Pane captures (`get_agent_pane`, `shell_get_pane`) are sealed as `vault:v2:e<N>:b64(salt16‖nonce‖tag‖ct)` PTY `out` frames; chat pane captures (`capture_agent_pane`) as v2 content envelopes. Locked → `vault_locked`, seal failure → `encryption_failed`, never plaintext.
- The hub snapshot code (`shell_stream_screen_snapshot.odin`) passes these fields through unchanged.

**Search key v2.**
- HKDF(ikm = current epoch key, salt = `heimdall/task-chain-search-rpc/v2`, info = `…/v2|e<epoch>`).
- The RPC envelope carries `epoch`, and the AAD appends `|e<epoch>`.
- The bridge accepts only the current epoch.

**Bridge keyring authentication** (added after the P1 security review, finding C1). The ECDH unseal alone does not say who sent the keyring, so a hostile hub could seal its own keyring to a bridge.
- P1 (in place): the keyring's `user_id` must equal the bridge's enrolled owner, and once a keyring is stored a new one is accepted only as a strict superset (identical keys for every shared epoch, `current_epoch` not lower). No rollback.
- P2/P3 (implemented: `src/lib/vault/bridge_chain.odin`, called from `bridge_unseal_decrypt_and_verify`; sender `buildBridgeChainProof` in `src/ui/utils/vaultDirectoryVerify.ts`, TS reference verifier `verifyBridgeChainProof`; shared vector `bridge_chain` in `tests/fixtures/vault_v2_vectors.json`). Every unseal v2 payload carries a `chain_proof` member (public signed data, so it is not inside the AEAD; the sealed plaintext stays the HKR1 keyring and `format` stays `keyring-v1`):

  ```json
  {"v":1, "user_id", "root_device_id", "root_sign_alg", "root_sign_pub",
   "genesis":{"statement","signature"},
   "epoch":{"epoch":<current_epoch>,"statement","signature"},
   "issuer_chain":[link…],                       // epoch issuer's approvals, root-first, root excluded
   "subject_approval":{"statement","signature","issuer_chain":[link…]}}
  // link = {"device_id","kind","sign_alg","sign_public_key","approval_statement","approval_signature"}
  // signatures: the signature-object JSON text (or the object)
  ```

  The bridge refuses unless: `user_id` = its enrolled owner = the keyring's user; the root key/alg are valid and `root_device_id` is derived from `root_sign_pub`; the root equals the pinned root (the FIRST unseal after enrollment pins it, in the epoch-floor record `HEF2`, same persistence and fail-closed rules as the floor; kept across a lock, deleted with the identity); genesis is canonical, self-signed by the root and describes it, and the root's kind may approve; each link is a canonical `approve` by the previous link (root first) describing the link, whose id is derived from its key and whose kind may approve (never a bridge); the `epoch` statement is for exactly the keyring's `current_epoch`, issued and signed by the last `issuer_chain` link (or the root), with `epoch_commit` equal (constant time) to the HMAC of the delivered current key; `subject_approval` is a canonical `approve` by the last link of its own chain (or the root) whose subject is this bridge (`subject_kind=bridge`, `subject_sign_pub` = its identity key, id derived from it). Statement user_ids prove the owner; the hub-reported owner pinned at enrollment is only a consistency check.
- Residual risks: (1) the first unseal is trusted to whoever sealed it — the approving device in the normal flow, but a hostile hub racing it could substitute its own root and keyring; `ham-bridge enroll` prints the pinned account fingerprint (first 8 bytes of SHA256(root_sign_pub), quads, as in Settings → Devices) for the owner to compare. (2) The proof carries no revocations, so a compromised approver keeps producing valid proofs after it is revoked; only the epoch floor stops it (it never learns the post-revocation epoch key), and only once the bridge has accepted that newer epoch — a bridge offline across the revocation can still be fed a fake newer epoch by it.
- The bridge identity key lives in persistent storage on every OS and is created only at enrollment. If it is lost, the bridge enters "identity lost; re-enroll" and never regenerates on its own (finding H1).

**Command epoch floor.** `enc_spec`, PTY input frames and search RPCs are rejected by the bridge unless epoch == current epoch.

## 2. Phases

### P1 — Crypto core and v2 envelope on every runtime (UI, bridge, ctl, hub prefixes)

During this phase the UI keeps its old password vault as the source of key material, wrapped as a single-epoch keyring `{epoch 1}`. That makes the phase build and test on its own. The adapter is deleted in P3.

**Create**
- `src/lib/vault/` (package `vault`):
  - `envelope.odin`: v2 seal/open, token scanning, embedded-token replace.
  - `keyring.odin`: `Vault_Keyring` struct, parse/serialize HKR1, `keyring_key_for_epoch`, secure wipe.
  - `statement.odin`: canonical builders and an ECDSA `verify_raw` wrapper.
  - `vault_test.odin`.
- The duplicated bridge/ctl envelope code moves into this package.
- `tests/fixtures/vault_v2_vectors.json`: fixed keys, nonces and expected envelope, keyring, wrap and statement bytes. TS reads it directly; Odin uses `#load`.
- `src/ui/utils/vaultKeyring.ts`: `VaultKeyring` = `{userId, currentEpoch, keys: Map<number, CryptoKey>}`, non-extractable.
- `src/ui/utils/vaultStatements.ts`: canonical bytes, sign/verify.
- `tests/ui_vault_v2_envelope_test.ts`, `tests/ui_vault_keyring_test.ts`.

**Modify**
- `vaultCrypto.ts`:
  - Prefix becomes v2.
  - `encryptVaultText` / `decryptVaultText` / `resolveCryptoKey` take a `VaultKeyring`.
  - `getActiveVaultKey()` returns `VaultKeyring | null`, and `tsc` will list all 57 consumer files (215 call sites).
- Add one exported `VAULT_TOKEN_RE` and replace the per-component regexes listed in §0.
- `vaultContent.ts`, `vaultChats.ts`, `ptyWire.ts`, `useShellStream.ts`, `shells.ts` (enc_spec).
- `taskChainSearchKey.ts`: per-epoch derivation from the keyring, not raw hex.
- `vaultBridgeUnseal.ts`: v2 payload with keyring bytes.
- Bridge:
  - `vault_decrypt.odin` and `main.odin:879`: `bridge_read_vault_keyring() -> (Vault_Keyring, bool)`. The env override becomes `HEIMDALL_VAULT_KEYRING` (b64 HKR1).
  - Every caller: `agent_api.odin:460`, `fs_management.odin:933,1010,1598`, `hub_runtime_client.odin:153,4260`, `task_chain_search_*.odin`, `pty_host_stream_worker.odin`, `bootstrap_*.odin`, `agent_taskv2_vcs.odin`.
  - Keystores (all four OS files plus `keystore_scope.odin`): store and read the binary keyring; add `keystore_store_identity_key` / `keystore_read_identity_key`.
  - `unseal_protocol.odin`: v2 only; generate, persist and sign with the identity key; expose `unseal_key_signature` in the hello / public-key payload.
  - On keyring install: bump `bridge_task_chain_search_generation()` and re-salt PTY streams.
- `enroll_device_flow.odin`: the authorize body adds `bridge_identity_public_key`.
- ham-ctl:
  - `vault.odin` and `vault_content.odin` use `lib/vault`.
  - `agent.vault.get` returns `{"keyring_b64","current_epoch"}`.
  - Drop `ENC:v1` / v1 decoding.
- Hub: one helper `domain.vault_token_prefix_len` / `is_vault_armored` in `vault_text_caps.odin`, used at every literal listed in §0.
- Hub `bridge_handlers.odin:303-360,523-560`: relay `unseal_key_signature` and the identity key.

**Acceptance**
- The same vectors pass in TS and Odin.
- Bridge, ctl and UI round-trip v2 content across epochs 1 and 2.
- A v1 token is treated as opaque and never decrypted.

**Required negative tests**
- Flipped tag, ciphertext or AAD bytes fail.
- Changing the epoch digits in the header fails, both because the key differs and because AAD binds the epoch.
- Unknown epoch shows the locked marker; it must not throw or leak.
- Truncated or oversized payloads, bad base64, and epoch 0 or leading-zero epochs are rejected.
- Keyring with more than 64 epochs, duplicate or unsorted epochs, wrong magic, or a different `user_id` is rejected.
- Unseal: replayed nonce; skew over 30 s; wrong bridge_id; v1 AAD form; 32-byte plaintext; signature on the ephemeral key by a different identity key; identity-key mismatch.
- `enc_spec` or search RPC under a non-current epoch is rejected.
- PTY: frames with the same epoch and salt never repeat a nonce across a worker restart.
- CSPRNG failure fails closed: `lib/os_random` returns false and nothing is sealed.

### P2 — Hub device directory and APIs (additive; `user_vaults` untouched)

**Create** `src/hub/repository/sqlite/migrations/092_vault_device_directory.sql`. Also add it to `migration_order` (size 96), `migration_sql`, and add a skip-guard plus an `upgrade_vault_directory_schema` twin.

```sql
CREATE TABLE vault_directories(user_id TEXT PRIMARY KEY, version INTEGER NOT NULL,
  current_epoch INTEGER NOT NULL, root_device_id TEXT NOT NULL,
  genesis_statement TEXT NOT NULL, genesis_signature TEXT NOT NULL,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE TABLE vault_devices(device_id TEXT PRIMARY KEY, user_id TEXT NOT NULL,
  kind TEXT NOT NULL, label TEXT NOT NULL,  -- validated in domain code (credential agility)
  sign_alg TEXT NOT NULL, wrap_alg TEXT NOT NULL DEFAULT '',
  sign_public_key TEXT NOT NULL, ecdh_public_key TEXT NOT NULL DEFAULT '',
  fingerprint TEXT NOT NULL, bridge_id TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL CHECK(status IN('pending','approved','revoked')),
  user_code TEXT, code_expires_at TEXT,
  approval_statement TEXT, approval_signature TEXT, approved_by_device_id TEXT,
  revocation_statement TEXT, revocation_signature TEXT, revoked_by_device_id TEXT,
  recovery_blob TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL, approved_at TEXT, revoked_at TEXT, last_seen_at TEXT,
  UNIQUE(user_id, sign_public_key));
CREATE UNIQUE INDEX vault_devices_pending_code ON vault_devices(user_code) WHERE status='pending';
CREATE TABLE vault_epochs(user_id TEXT NOT NULL, epoch INTEGER NOT NULL,
  statement TEXT NOT NULL, signature TEXT NOT NULL, created_at TEXT NOT NULL,
  PRIMARY KEY(user_id, epoch));
CREATE TABLE vault_wrapped_keyrings(user_id TEXT NOT NULL, device_id TEXT NOT NULL,
  directory_version INTEGER NOT NULL, current_epoch INTEGER NOT NULL,
  wrap_json TEXT NOT NULL, updated_at TEXT NOT NULL, PRIMARY KEY(user_id, device_id));
```

**Create** the hub code:
- `src/hub/domain/vault_directory.odin`: types, validation, statement parsing via `lib/vault`.
- `src/hub/repository/iface/vault_directory_repo.odin` and `src/hub/repository/sqlite/vault_directory_repo_sqlite.odin`.
  - Every mutation runs in one `BEGIN IMMEDIATE` transaction with `UPDATE vault_directories SET version=version+1 … WHERE user_id=? AND version=?`.
  - If 0 rows change, return `Conflict` (409) with the current version.
- `src/hub/service/vault_directory/service.odin`.
- `src/hub/transport/http/vault_directory_handlers.odin`.
- Tests: `vault_directory_repo_test.odin`, `service_test.odin`, `src/hub/vault_directory_handler_test.odin`.

**Request signing.** Every mutation except `register` and `genesis` needs these headers:
- `X-Heimdall-Device-Id`
- `X-Heimdall-Device-Ts`
- `X-Heimdall-Device-Nonce`
- `X-Heimdall-Device-Sig` over `heimdall-device-request/v1\n<METHOD>\n<path>\n<user_id>\n<ts>\n<nonce>\n<hex sha256(body)>`

The hub checks:
- The signer is an approved non-bridge device of the session user.
- `|ts| ≤ 60 s`.
- The nonce is unused (ring cache, reusing the `Unseal_Nonce_Cache` pattern).
- The `verify_raw` signature.

Statement signatures are verified on the hub too, as defense in depth. Clients still verify everything.

**Endpoints** (cookie auth, under `/api/v1`)

| Endpoint | Body / result |
|---|---|
| `GET /vault/directory` | `{version,current_epoch,root_device_id,genesis:{statement,signature},devices:[{device_id,kind,label,fingerprint,status,sign_public_key,ecdh_public_key,bridge_id,approved_by_device_id,approval_statement,approval_signature,revocation_*,created_at,approved_at,revoked_at,last_seen_at}],epochs:[{epoch,statement,signature}]}`, or 404 `{configured:false}`. Updates `last_seen_at` when a signed header is present. |
| `POST /vault/directory/genesis` | `{device:{…pubs,label}, genesis_statement, signature, epoch_statement, epoch_signature, wrap}`. 409 if a directory exists. Self-signed by the root. |
| `POST /vault/devices/register` | `{kind:"browser",label,sign_public_key,ecdh_public_key,proof_signature}` (self-signed `register` statement). Returns `{device_id,fingerprint,user_code,code_expires_at}`. Idempotent per key; rate-limited with `verify_rate_allow`. Publishes `resource_changed("vault_devices",id,"pending")` and a push notification **without the code**. |
| `GET /vault/devices/self` | Signed by the pending or approved device. Returns `{status,directory_version,wrap?}`. Also delivered as a WS nudge. |
| `POST /device/verify` (extended `device_auth_handlers.odin:129`) | Resolves a code against bridge grants **and** pending browser devices. Returns `{kind:"bridge"|"browser", fingerprint, label, …}`. |
| `POST /vault/devices/{id}/approve` | `{expected_version, statement, signature, wrap}`. Bridge approvals go through `POST /device/approve` with an added `vault_approval:{expected_version,statement,signature}`, written atomically with the grant approval. No wrap is stored for bridges. |
| `POST /vault/devices/{id}/revoke` | `{expected_version, revoke_statement, signature, epoch_statement, epoch_signature, wraps:[…]}`. Rejected when: the target is the signer (409 `self_revoke`); afterwards no approved browser or recovery device would remain; the wraps do not cover exactly the remaining approved browser and recovery devices at `current_epoch+1`; the epoch is not `current+1`; the version is stale (409). It then revokes the bridge's tokens (existing bridge revoke) and publishes events. |
| `PATCH /vault/devices/{id}` | Signed label change. |

**Bridge enrollment gate.** `wiring.odin:883`: replace `user_vault_get` with "vault directory exists". The grant carries `bridge_identity_public_key`; `bridge_grant.odin` adds validation and a fingerprint for it.

**Wiring.** Add routes after `wiring.odin:524`, plus graph fields alongside :65/:76/:91.

**Acceptance:** the full CRUD and CAS flow is exercised by Odin tests.

**Required negative tests**
- Stale `expected_version` returns 409 and leaves the database unchanged. Run two concurrent approvals; exactly one wins.
- Unsigned, wrong-signer, bridge-signer, revoked-signer, cross-user signer, replayed nonce and expired timestamp are all rejected.
- Body tampered after signing is rejected.
- Self-revoke is rejected.
- Revoking the last approver with no recovery device is rejected.
- Revoke with missing or extra wraps, or with epoch ≠ current+1, is rejected.
- A second genesis is rejected.
- Register with a mismatched proof is rejected. A duplicate key is idempotent.
- Expired code is rejected. Code brute force is rate-limited.
- A browser code cannot resolve as a bridge grant and vice versa.

### P2.5 — Headless API end-to-end test (no UI)

Prove P1+P2 work together through real HTTP before any UI exists. Add `tests/e2e/vault_devices_api_e2e.mjs` (Node, global WebCrypto, no new deps) plus a runner script `scripts/e2e-vault-devices.ps1` (and `.sh`) that starts a throwaway hub (temp DB, `--trusted-proxy-cidr 127.0.0.1/32`, dev proxy or trusted-proxy user header) and drives it with **simulated devices** built on the same TS crypto modules the UI will use (`vaultKeyring.ts`, `vaultStatements.ts`, wrap code):
1. Device A: register + genesis (epoch 1), wraps to itself; fetch directory, verify the chain client-side.
2. Device B: register → pending with user_code; A resolves the code via `/device/verify`, signs approval, wraps keyring to B; B polls `/vault/devices/self`, unwraps, verifies `epoch_commit`; A and B decrypt each other's v2 content.
3. Bridge: run a real `ham-bridge` enrollment against the throwaway hub where possible (device code approved by A via the API, then unseal v2 to the bridge's signed ephemeral key) and confirm the bridge reports the vault unlocked; if a real bridge cannot run in CI on this OS, simulate the bridge side with the Odin unseal code exercised by an Odin test, and say so.
4. Revoke B from A → epoch 2, wraps to remaining devices; B can no longer fetch a wrap; new content is `e2`; A reads e1 and e2.
5. Attacks via raw HTTP: self-revoke (409), last-approver revoke without recovery (409), stale version (409), concurrent approvals (exactly one wins), replayed request nonce, forged signature, hub-side injected device row (insert directly into the temp DB) → clients refuse to wrap to it, wrong-user cookie.
Acceptance: script exits 0 on Windows; output lists each step PASS/FAIL. Add it to the plan's verification list and keep it green in P3/P4. If any step cannot be automated, document the manual equivalent with exact curl/PowerShell commands.

### P3 — UI device identity, unified approval, devices page and rotation (delete every password and lock surface)

**Create**
- `src/ui/utils/deviceIdentity.ts`: IndexedDB key pairs, pins `{root_device_id, root_sign_pub, max_directory_version, max_epoch}`.
- `vaultDirectoryVerify.ts`:
  - Walks genesis → approvals → revocations → epochs.
  - Checks signatures, issuers that were approved at issue time and not revoked before, monotonic versions and epochs, and the pinned root.
  - Fails closed.
- `vaultKeyringSession.ts`:
  - Unwraps the hub copy with the device ECDH key and checks `epoch_commit`.
  - Installs non-extractable AES keys.
  - Obtains raw keyring bytes only transiently to re-wrap, then zeroes them.
- `src/ui/api/endpoints/vaultDevices.ts`: RTK endpoints plus the request signer.
- `src/ui/store/deviceVaultSlice.ts`: states `unsupported | initializing | genesis | pending-approval | confirm-account | ready | revoked | error`. Serializable only.
- Components:
  - `components/devices/DeviceGenesisScreen.tsx`
  - `DeviceWaitingScreen.tsx`: shows code and fingerprint; blocks the app.
  - `AccountFingerprintConfirm.tsx`: the new device shows the account fingerprint, SHA256(root_sign_pub) truncated to 64 bits, and the user confirms it matches Settings on the old device before keys are installed.
  - `DeviceApprovalPage.tsx`: a unified rewrite of `BridgeEnrollmentApprovalPage.tsx` at `/device/add`. The user types the code; the page shows kind, label and fingerprint; the user confirms. Browser: sign approval and wrap. Bridge: sign approval via `/device/approve`, then verify the bridge's signed ephemeral key, then send unseal v2.
  - `components/settings/DevicesPanel.tsx` at `/settings/devices`:
    - Lists browsers, bridges and the recovery device with label, kind, fingerprint, approved-by label and last seen.
    - Revoke is disabled for the current device and for the last approver when no recovery exists.
    - Revoke flow: new epoch key → keyring with `current+1` → wraps to the remaining devices → POST → re-unseal every connected approved bridge.
  - A pending-device toast and attention entry driven by the WS `vault_devices` event (`wsInvalidation.ts`).
- Tests:
  - `tests/ui_vault_device_identity_test.ts`
  - `ui_vault_directory_verify_test.ts`
  - `ui_vault_rotation_test.ts`
  - `ui_device_approval_page_test.ts`
  - `ui_vault_devices_panel_test.ts`

**Modify**
- `vaultSlice.ts`: remove it, or reduce it to keyring accessors. The async import side effects inside reducers (:293-303, :365-372) go.
- `main.tsx:66-95`: replace rehydration with device boot.
- `AppShell.tsx:90-122,304-342,1251,1414-1518`: remove the vault panel, onboarding and lock state; add the gating screens and the devices route.
- `bridges.ts:200-240`: `unsealAllConnectedBridges` requires a verified identity signature.
- `BridgeSettingsPanel.tsx`, `bridgeVaultStatus.ts`: a "locked" bridge is shown as "awaiting key", with an approve or re-unseal action and no password.
- `usePaneVaultLock.ts`, `VaultLockedOverlay.tsx`: overlay text only, no unlock.

**Delete**
- `VaultOnboardingModal.tsx`, `VaultOnboardingHost.tsx`, `VaultPasswordPurposeNote.tsx`, `VaultPanel.tsx`.
- `vaultPersistence.ts`.
- `BridgeEnrollmentApprovalPage.tsx` (replaced).
- `userVault.ts` usage.
- The P1 password→keyring adapter.
- Tests: `ui_vault_onboarding_test.ts`, `ui_vault_panel_test.ts`, `ui_vault_unlock_race_test.ts`, `ui_vault_unlock_transition_test.ts`, `ui_vault_unseal_hex_convergence_test.ts`, `ui_vault_persistence_test.ts`.
- Update the `package.json` test list to match.

**Required negative tests**
- A hub-injected device (no valid chain) never gets a wrap.
- A chain with a forged or revoked issuer, a swapped root, a lower version or epoch (rollback against the pins), or a device approved after its approver was revoked is rejected.
- A wrap signed by a non-approved device is rejected.
- A wrap AAD naming a different recipient or version is rejected.
- `epoch_commit` mismatch is rejected.
- Bridge ephemeral key unsigned or signed by the wrong identity: unseal is refused.
- The self-revoke button is absent, and the API call returns 409.
- A pending device cannot reach decrypted UI.
- A 409 during revoke re-fetches, re-verifies and retries once, and never double-rotates.

### P4 — Recovery key and dead-code removal

**Recovery key**
- 12 BIP-39 words (reuses `generate12RecoveryWords` / `validateRecoveryWords`) → HKDF-SHA256(entropy, salt `heimdall-recovery-v1`, info `wrap`) → AES key.
- The browser generates random, extractable ECDH and ECDSA P-256 key pairs. It encrypts their PKCS#8 bytes with that AES key, using AAD `heimdall-recovery-v1|<user_id>|<device_id>`.
- It registers them as kind `recovery`, approved, with `recovery_blob`. Rotations wrap to it like any other device.
- Restore on a fresh browser: register → enter words → decrypt the recovery keys → verify the chain → unwrap → sign approval of the new browser as the recovery issuer → optionally revoke the lost devices.
- The 128-bit entropy makes PBKDF2 unnecessary.
- Files: `src/ui/utils/vaultRecovery.ts`, a recovery section in `DevicesPanel.tsx`, a restore entry on `DeviceWaitingScreen.tsx`, `tests/ui_vault_recovery_test.ts`.

**Hub cleanup**
- Add `093_drop_user_vaults.sql` (`DROP TABLE IF EXISTS user_vaults;`).
- Delete `upgrade_user_vaults_schema` and its call (`migrations.odin:876,1466`). Otherwise it re-creates the table.
- Remove the 047 skip-guard (:678).
- Delete `domain/user_vault.odin`, `service/user_vault/`, `user_vault_handlers.odin`, the user-vault repo and iface, `repos.odin:16`, wiring lines `wiring.odin:27,65,76,91,255,258,342,523-524`, `user_vault_handler_test.odin` and `user_vault_repo_test.odin`.

**UI cleanup**
- Delete from `vaultCrypto.ts`: PBKDF2, `deriveKeyFrom*`, `encrypt/decryptVaultKeyEnvelope*`, `activeBridgeVaultKeyHex`.
- Remove `VaultKeyNotExportableError` paths.
- Remove the ctl `vault lock` and UI lock code. Keep bridge `vault.reset` for purge-on-revoke.
- Update `tests/device_auth_security_matrix_test.odin`, `tests/e2e_req_fix_2_vault_delivery.sh` and `tests/helpers/req_fix_2_seal.mjs` to v2.
- Docs: `SECURITY.md`.

**Required negative tests**
- Wrong words fail.
- Valid words for another user fail (AAD binding).
- A tampered recovery blob fails.
- A revoked recovery device cannot approve.
- `grep -rn "vault:v1\|PBKDF2\|kdf_salt\|master password" src` returns nothing.

## 3. Threat model (hub assumed hostile for confidentiality)

| Threat | Mitigation |
|---|---|
| Hostile hub reads data | Hub stores only wraps and ciphertext. Keys never leave devices except as ECDH-wrapped keyrings. |
| Hub injects a device or swaps keys | Clients wrap only to devices with a verified signed chain to the pinned root. The new device confirms the account fingerprint out of band. Bridge ephemeral keys must be signed by an identity key that a human approved. |
| Hub rollback or hiding a revocation | Version and epoch pins are monotonic in IndexedDB. Statements carry `directory_version`. |
| Stolen session cookie | Can register a pending device but cannot approve one: that needs an approved device's signature plus the code typed from the new screen, and notifications never carry the code. Every mutation needs a device signature. Revoked devices are rejected. |
| Revoked device holding old epochs | New content uses the new epoch. Bridges reject non-current epochs for commands. Tokens are revoked. Residual: old content stays readable, and content writes under old epochs remain possible over a live session. Recommend signing out sessions on revoke. |
| Replay | Request-signature nonce and timestamp. Unseal nonce, timestamp and bridge_id. Search RPC nonce and expiry. Statements bound to version. |
| Tampered ciphertext / AAD | GCM with AAD binding epoch, recipient, version and bridge. There is no plaintext fallback for command fields. |
| Nonce reuse | Random 96-bit nonces. PTY salt is fresh per worker and per epoch, and seq never resets under a salt. Each epoch has its own key. |
| CAS races | Single-transaction versioned UPDATE; 409 leads to re-verify and retry. |
| Randomness failure | WebCrypto throws. Odin uses `lib/os_random` and `crypto.rand_bytes`; any failure aborts sealing and key generation. |
| Compromised UI origin | Out of scope and stated as residual. The hub serves the JS, as already noted at `BridgeEnrollmentApprovalPage.tsx:36-41`. |

## 4. Verification commands (Windows)

PowerShell setup:
```powershell
$odin="$env:LOCALAPPDATA\Programs\Odin\dist\odin.exe"
$out="$env:USERPROFILE\.cache\heimdall-tests"
```

- **Checks.** I verified that `& $odin check src/hub -collection:odin_test=src -no-entry-point` and `& $odin check src/bridge -collection:odin_test=src -target:linux_amd64` both exit 0. Run the same for `src/hub`, `src/bridge`, `src/ctl` and `src/lib/vault` with no target (windows) and with `-target:linux_amd64` and `-target:darwin_arm64`.
- **Odin tests.** I have not run tests on Windows yet, so the first run needs confirming:
  - `& $odin test src/lib/vault -collection:odin_test=src -out:$out\vault.exe`
  - Hub tests also need SQLite: `& $odin test src/hub/repository/sqlite -collection:odin_test=src "-extra-linker-flags:/LIBPATH:C:\Users\Tanmay\heimdall-win-build\deps\lib" -out:$out\repo.exe`. Same for `src/hub/service/vault_directory` and `src/hub`.
  - Bridge and ctl suites spawn `sh` / `setsid`, so select tests with `-define:ODIN_TEST_NAMES=main.test_unseal_…,…`. Run full bridge suites on Linux CI.
- **UI:** `npm run typecheck`, `npm test`, `npm run build`.

## 5. Other gotchas

- `getActiveVaultKey()` changes type, which cascades through 57 files. Do it in P1 and let `tsc` enumerate them.
- `decryptVaultText` returns non-armored input unchanged (`vaultCrypto.ts:576-583`). Fields that must be encrypted (enc_spec, unseal) must not accept plaintext.
- `agent.vault.get` gives every local agent process the whole keyring (all epochs). That is the existing trust level, now with history included; document it.
- Bridge grants live in memory, so a hub restart drops pending bridge approvals. Pending browsers are durable.
- The `npm test` script enumerates files explicitly, so new files must match an existing glob or be added.

### Critical Files for Implementation
- C:\Users\Tanmay\heimdall-agent-manager\src\ui\utils\vaultCrypto.ts
- C:\Users\Tanmay\heimdall-agent-manager\src\bridge\unseal_protocol.odin
- C:\Users\Tanmay\heimdall-agent-manager\src\bridge\vault_decrypt.odin (plus keystore_*.odin and main.odin:879)
- C:\Users\Tanmay\heimdall-agent-manager\src\hub\repository\sqlite\migrations.odin (plus app\wiring.odin)
- C:\Users\Tanmay\heimdall-agent-manager\src\ui\components\enrollment\BridgeEnrollmentApprovalPage.tsx (to be replaced by DeviceApprovalPage.tsx)
## Backlog carried into P4 (from P1 fix round 2)

- fs-write channel binds bridge + path but not the project root; include the resolved absolute path (or root id) in the AAD.
- Card `operations` (e.g. `issue.create` title/description) stay plaintext because the hub executes them; seal the content fields the hub only stores.
- Remove the hub's `'disabled'` vault-status vocabulary and the UI NotConfigured badge (no plaintext mode exists).
- Hub test for client-chosen shell session ids; fs read tests still swap the global `bridge_fs_read_page_bytes`.
- Bridge fs / vcs-save / shell-gate integration tests need a Linux run (they fail on Windows temp paths or are `!windows`).
