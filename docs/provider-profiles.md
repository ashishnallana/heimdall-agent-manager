# Provider profiles and isolated local homes

A provider profile is one account and runtime configuration for a provider on one bridge. Two Claude profiles can use different config directories, environment variables and extension installations. Profile identity follows an agent through launch, conversation reconfiguration, permission-mode changes and fleet placement. An unavailable profile fails the launch; Heimdall does not silently switch accounts.

## Configure a profile

Open **Settings → Bridges → Provider profiles**, or choose the bridge on the **Providers** settings page. Editing requires an online, unsealed bridge and an unlocked browser device.

Choose **Add provider**, then complete **Provider → Identity → Config**:

1. Pick the provider.
2. Enter a label and accent. The suggested ID uses the driver plus four random base32 characters. IDs are unique per bridge, start with a lowercase letter, contain lowercase letters, digits, underscores or hyphens, and fit in 32 characters. Catalog provider slugs are reserved for defaults.
3. Configure runtime fields, environment variables and custom models, then save.

The ID, driver, accent and enablement are visible to the hub. Labels are vault-encrypted; IDs are not derived from labels. Editing a label does not rename an existing ID.

Every provider has a default profile whose ID equals its driver, such as `claude`. Existing agents and fleets keep that identity. **Reset overrides** clears its local config, environment, label and accent while keeping enablement. Defaults cannot be deleted. Custom profiles have **Delete**; move non-terminal agents and fleet references first if `profile_in_use` is reported. Disable prevents new launches without deleting a profile or stopping a running agent.

The detail page includes provider detection, model refresh, a temporary provider test and extension install/update/uninstall. Each action uses the selected profile. Installing an extension into one account does not install it into another. The enrollment checklist configures defaults; custom accounts are managed on the profiles page.

## Runtime fields

| Field | Meaning |
| --- | --- |
| Binary | Executable name resolved on the bridge PATH, or executable path on that bridge. |
| Claude config directory | Sets `CLAUDE_CONFIG_DIR`. |
| Codex home | Shared/runtime home for `CODEX_HOME`; this is not operating-system HOME. |
| Codex shadow home | Optional overlay with private authentication/local state and shared allowed runtime entries. |
| Launch arguments | Literal editor rows, at most 32 arguments of 1 KiB each; no shell expansion. |
| Custom models | Additional model IDs, separate from observed models. Clearing them does not leave them in discovery history. |
| Antigravity authentication | Auth method, secret API key, Google Cloud project and location. Custom arguments/models are not supported for this driver. |

Directory fields accept absolute paths or leading `~`, expanded against the bridge HOME. A missing runtime directory is created as a private leaf only when its parent exists and is writable. Binary paths must resolve to executable files. Runtime paths are not confined to `fs_root`; that root confines project browsing.

Profiles inherit the bridge HOME; there is no general HOME override. Use the driver-specific config/home field for separate accounts. Environment rows cannot set `HOME`, `USERPROFILE` or `HEIMDALL_*`. Composition is bridge environment → profile environment → forced driver-directory/auth fields → managed `HEIMDALL_*` variables. A typed directory wins over an environment row for the same driver variable.

Arguments follow the catalog/permission/model arguments and precede prompt arguments. Discovery and extension installation use fixed recipes, rather than the custom launch arguments.

Codex shadow and shared homes must not overlap, including through symlink aliases. Shadow authentication is private and cannot be an `auth.json` symlink. Allowed shared entries are linked; auth, locks and other private entries stay local. Sign in using the provider’s normal authentication flow in the intended directory.

## Config directory choices

Claude profiles offer **Inherit**, **Random**, and **Custom** in both the add wizard and editor.

- **Inherit** clears the override and uses the bridge's default Claude configuration.
- **Random** chooses a unique private directory under the bridge HOME. Saving creates it with private permissions. The displayed path remains stable across mode switches, saves and reopening; the bridge resolves `~`, including USERPROFILE on Windows.
- **Custom** uses a nonempty path you enter on the bridge.

A new Random directory has no copied authentication: sign in once for that profile using the provider CLI. Switching modes or deleting a profile leaves previous runtime directories intact; remove those manually when no longer needed. If the bridge has no home directory or cannot create the path, saving reports the bridge error.

## Test a saved profile

After saving, check the provider and refresh its models if needed. Choose an active **Test model**, then **Test profile** to run that exact account in a live terminal. Unsaved changes must be saved first.

Click the terminal to type, complete sign-in or configure the provider. Interactive input requires terminal input in your account plan and an unlocked bridge vault; read-only plans retain their restrictions. The run uses the profile's stored environment and runtime directory on the bridge. New random directories start signed out.

The terminal stays live after `start-success` until you mark the run validated. Validation stops it; closing/cancelling also stops it, with expiry as a fallback. Validation is session-only. Provider configuration written to its runtime directory remains for later launches.

## Environment and secrets

Environment rows are sensitive by default. Sensitive values are blank on every read; the editor shows **Stored secret, enter a new value to replace**.

- Leave a replacement empty to keep the stored secret.
- Enter a replacement to change it.
- Use **Clear stored secret** to erase it.
- Remove the variable to delete its row and secret.
- Clear or replace a stored secret before renaming it or making it non-sensitive.

The API key follows the same rule. After a successful save, replacement drafts leave component state and the browser fetches a redacted view. Non-sensitive values are returned to an unlocked editor and stored in ordinary local settings. The hub still receives only the sealed operation, never a plaintext environment name or value.

## Storage and trust

This implements the approved trusted-host design: local profile settings are **not encrypted at rest**. Under the configured bridge `data_dir`:

- `bridge/provider_profiles.json` is schema-v2 JSON, mode `0600`. It holds typed non-sensitive settings, paths, arguments and secret-redaction flags.
- `bridge/profile-secrets/` is mode `0700`, with separate `0600` files for sensitive environment values and API keys.
- Account keyring, identity and epoch material use the existing bridge keystore. There is no additional profile encryption key.

The local OS user and provider processes are trusted. A process under that same user can read these files, and a provider receives its materialized secrets. Permissions protect against other OS users. Sensitivity is a redaction/separate-storage policy, not a boundary against the bridge host.

The hub stores only allowlisted registry metadata: bridge/profile IDs, driver, encrypted label, accent, enablement, config-presence flags, environment/argument/custom-model counts, state and timestamps. It does not persist profile values, paths, environment names or arguments. Observed models and per-profile status are separate projections.

### Browser-to-bridge channel

Every operation, including get/remove/reset, is sealed under the account keyring’s **current epoch**:

```json
{"op":"upsert","profile_id":"claude_k3fq","body":{},"bridge_id":"brg_...","boot_id":"...","ts":1793350000000,"nonce":"fresh-random-value"}
```

The hub relays only `{"sealed":"vault:v2:..."}`. The bridge requires an unsealed current-epoch keyring, authenticates the seal, matches bridge/boot identity, checks timestamp freshness and nonce replay, and matches the outer route to the opened operation/profile. Get responses are sealed and matched to the request nonce; sensitive values are redacted inside them.

A changed boot gets one explicit `profile_stale_boot` retry with a fresh nonce, preserving the draft. Ambiguous network failures are not automatically retried. Revoked devices without the new epoch key cannot author post-revocation operations.

The hub has no account keyring. Other unsealed bridges of the same account do hold it: the user explicitly accepted that shared-account exposure. The receiving bridge enforces bridge binding by policy, rather than cryptographically isolating it from all other bridges in that account.

Authoritative reports reconcile the registry: missing referenced profiles stay `missing` and disabled; unreferenced ones disappear. Failed reports do not prune. A newly added catalog slug colliding with a custom ID does not merge identities or silently fall back.

## Local development isolation

On Linux, a new local bridge defaults to an isolated provider home:

```bash
scripts/local-hub.sh start --name profiles
scripts/local-bridge.sh start --name profiles --hub profiles --auto-enroll
```

State is under `$HEIMDALL_LOCAL_STATE_ROOT` (normally `~/.local/state/heimdall-local`); provider HOME is `bridges/profiles/home`. The installed bridge service is not restarted. The real home stays the directory picker’s `fs_root`, so projects outside the isolated provider home remain accessible.

Initial seeding copies allowlisted provider auth, onboarding/trust and Git files. It filters code-running configuration, including hooks, plugins, MCP servers and status-line commands. It does not copy history, installed bridge credentials or extension installations. The checksum manifest is `home/.heimdall-home-manifest.json`.

Inherited `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `GEMINI_CONFIG_DIR` and `HEIMDALL_HOME` are cleared; HOME/XDG point inside the instance. Authentication environment variables may still pass through. Copied OAuth tokens can expire or rotate; sign in normally and run `reseed-auth` as needed. A separate profile runtime directory receives no automatic auth seeding.

The bridge’s extension assets are synced from the checkout’s `extensions/` into its own `data/extensions` at start, so preview installs test the extension under development.

```bash
scripts/local-bridge.sh reseed-auth --name profiles
scripts/local-bridge.sh stop --name profiles --purge-home
scripts/local-hub.sh stop --name profiles
```

Purge removes this bridge’s vault scope and profile settings/secrets before deleting its isolated home and enrollment credentials, and clears the stale enrolled bridge ID so the next start can enroll afresh. If vault cleanup fails, the home is kept for recovery. Explicit profile runtime directories are user data and are **not deleted**; their preservation is intentional.

An instance’s home mode is fixed. `--shared-home` deliberately uses the real home; older pre-isolation instances remain shared. On macOS isolation is opt-in and moved-HOME Keychain sign-ins are unverified. The shell smoke below is Linux-oriented, not a native Windows/macOS runtime claim.

## Reproduce the integration check

Supply built binaries from this checkout (`ham-hub`, `ham-dev-proxy`, `ham-bridge`, `ham-ctl`, `ham-pty-host`), installed UI dependencies and an installed Claude CLI:

```bash
HEIMDALL_PROFILE_SMOKE_BIN_DIR=/absolute/path/to/binaries \
  timeout 900 bash scripts/provider-profiles-smoke.sh
```

`HEIMDALL_PROFILE_SMOKE_PORT_BASE` selects private loopback ports (default `39300`). `HEIMDALL_PROFILE_SMOKE_REAL_CLAUDE` can select the vendor executable. Missing prerequisites fail rather than silently skip.

The test starts the actual local hub, OIDC/dev proxy, UI and bridge. It uses the production UI profile client and verified seed-device keyring. Real Claude plugin commands install the checkout’s local marketplace into the default isolated home and two profile directories. Agent execution uses a recording fixture through the real Hub/Bridge/PTY/bootstrap/start-success path, avoiding cloud model calls; this does not claim a live language-model response.

It checks copies/manifest, filtered code config, decoys, external project registration/browsing, profile argv/env, redacted reads, hub DB/WAL/SHM plaintext exclusion, secret-file permissions, provider-home checksums, purge and released ports. The real-home check hashes both provider trees. Active Codex session/history streams, model cache and runtime SQLite databases/journals are reported separately because the executing agent writes them during the test; every other file, including auth, config and plugins, must retain its checksum. Requests and child commands are bounded. Failures clean up owned services; `HEIMDALL_PROFILE_SMOKE_KEEP_FAILURE=1` retains private diagnostics.

`HEIMDALL_PROFILE_SMOKE_KEEP=1` proves purge first, then restores a live review stack without repeating plugin installation. `HEIMDALL_PROFILE_SMOKE_STATE_FILE` records its state directory; `HEIMDALL_PROFILE_SMOKE_RESULT` saves acceptance JSON. This opt-in leaves processes/disposable keys for review: stop/purge those named instances and remove that private directory afterwards. Never point this integration script at production.

See [the launcher contract](../scripts/local-runtime/CONTRACT.md) and [local runtime smoke](../scripts/local-runtime-smoke.sh). Unit/behavior tests are separate from this real-runtime integration check.
