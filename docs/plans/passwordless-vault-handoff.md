# Passwordless vault: handoff

Branch: `passwordless-vault` (pushed to `origin`). Design and formats: [`passwordless-vault.md`](passwordless-vault.md). Security notes: `SECURITY.md`.

## State

The passwordless vault is implemented end to end and was tested manually on Windows (hub, dev proxy, Vite UI, real `ham-bridge`, Firefox):

- First browser creates the vault with no password; there is no lock/unlock UI anywhere.
- New browsers and bridges pair with one 14-symbol code typed once on an approved device (`/device/add`). The hub never sees the code (salted, PBKDF2-stretched pairing keys; `key_mac` / `pair_mac`).
- Settings → Devices lists browsers, bridges and the recovery key; revoke (never the current device, never the last approver without a recovery key), deny, automatic rotation and automatic bridge key delivery.
- Opt-in 12-word recovery key: create/replace in Settings → Devices; restore from a new browser's pairing screen ("Use recovery key").
- Directory is a hash-linked, contiguous, signed log verified from genesis by every client; pins detect rollback/forks. Bridges verify a signed chain proof and pin the account root on their first key delivery (stamped with the pairing code).
- Content envelope `vault:v2:<vault_id>:e<epoch>:…`; keyring HKR2; PTY per-stream subkeys with replay counters bound to the bridge boot id; enc_spec bound to bridge/session/kind/boot; fs writes bound to bridge + project root + path; pane/shell captures sealed.
- Several bridges per machine: vault state, credential file and locks are scoped to (hub origin, bridge id). `ham-bridge enroll --hub <url>` uses exactly that hub; `ham-bridge vault prune` cleans dead scopes on request.
- Vault JSON is typed (structs + `json.marshal` / `unmarshal`); the only hand-built forms are the canonical signed/hashed encoders in `src/lib/vault`.
- Password-era code (user_vaults, PBKDF2 password vault, bridge lock, "disabled" vault mode) is deleted. No backward compatibility: existing hubs need a fresh vault, bridges must re-enroll.

## Verified at the last merge (c98a1135)

- `odin check` clean for `src/hub`, `src/bridge`, `src/ctl`, `src/lib/vault` on windows, linux_amd64, darwin_arm64.
- `npm run typecheck` clean.
- `npm run test:e2e:vault`: all 12 steps pass (pairing, hostile-hub cases, bridge chain proof, revoke/rotation, signed-log attacks, deny/reset, recovery create + restore, changed user id).
- Branch-level runs before the final merge (not re-run after it): `odin test src/lib/vault` (25), ctl (136), bridge vault tests, hub vault/device tests, `tests/device_auth_*`, `npm test` 914/915 (1 fixture-gated skip), `npm run build`, `npm run test:e2e:bridge-enroll` (real enroll against two throwaway hubs).

## Remaining work

1. **Full post-merge verification**: rerun `npm test`, `npm run build`, `npm run test:e2e:bridge-enroll`, and the Odin test packages above on the merged branch.
2. **Security review of the last two merges** (pairing hardening and P4: recovery key, vault id, fs-write v3, card-operation sealing, prune). Every earlier phase had an adversarial review; these two did not get a final one.
3. **Linux/macOS test runs**: bridge fs / vcs-save / shell-gate / enroll tests are posix-only or fail on Windows temp paths; `enroll_atomic` tests hang on Windows (pre-existing). Run on Linux CI.
4. **Residual risks to decide on** (documented in the plan §1/§3):
   - Stale-head fork for a device offline across a revocation (freshness guard pauses automatic actions only).
   - Bridges cannot see revocations; only the epoch floor protects an offline bridge.
   - Bridge ephemeral-key freshness is bound only to the boot id.
   - Keyring caps at 64 epochs; needs compaction for very long-lived accounts.
   - The hub serves the UI JavaScript (compromised UI origin is out of scope).
   - Pairing uses salted PBKDF2 over a 70-bit code rather than a PAKE; a PAKE (CPace/SPAKE2) would remove offline checks entirely.
5. **Hand-built JSON outside the vault scope**: hub bridge-record serializer, bridge heartbeat, other non-vault frames; `ctl/vault_content.odin` keeps documented byte splicing for invalid UTF-8.
6. **Out of scope so far**: Electron app (device flow not ported), passkeys/YubiKeys (designed for via `sign_alg`/`wrap_alg` allowlists, not built).
7. **Windows port leftovers** (from the earlier Windows work): UTF-8 loss in `ham-ctl` arguments, child processes inheriting socket handles, startup-nudge race, Windows service (Scheduled Task) and the `.ps1` update supervisor, release packaging.
8. **Housekeeping**: remove merged worktrees (`ham-wt-chain`, `ham-wt-p3`, `ham-wt-p4`, `ham-wt-pair`) and their branches; `ham-wt-mixed-work` and `docs/plans/mixed-work-task-chains.md` belong to other work and were left alone. Open a PR for `passwordless-vault`.

## Running the dev stack on Windows

Binaries are built with `odin build src/<pkg> -collection:odin_test=src "-extra-linker-flags:/LIBPATH:<dir with sqlite3.lib>"` (static SQLite 3.54.1 with FTS5).

```sh
ham-hub --listen 127.0.0.1:8081 --db <dir>/hub.db --migrations-dir src/hub/repository/sqlite/migrations \
        --trusted-proxy-cidr 127.0.0.1/32 --ui-origin http://127.0.0.1:5173
ham-dev-proxy --listen 127.0.0.1:8080 --hub-url http://127.0.0.1:8081 --default-user <user>
# UI (PowerShell): HEIMDALL_HUB_API_URL, HEIMDALL_DEV_PROXY_URL, and the dev-only
# VITE_PAIRING_HUB_ORIGIN=http://127.0.0.1:8081 (pairing binds the hub origin; Vite serves on its own port)
npx vite --host 127.0.0.1 --port 5173
ham-bridge enroll --hub http://127.0.0.1:8081 --config <dir>/config.toml --bridge-token-file <dir>/bridge-token --headless
ham-bridge --config <dir>/config.toml --bridge-token-file <dir>/bridge-token
```

After any vault format change, wipe the hub DB and clear the browser's site data for the UI origin.
