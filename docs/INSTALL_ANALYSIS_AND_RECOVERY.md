# Bridge install, update and recovery

This replaces the earlier analysis of the twin `install.sh` / `install.ps1`
installers (audit findings F17–F19: drifting twin installers, frozen generated
`enroll.*` scripts, and the `heimdall` manager / Nix module targeting an obsolete
layout). There is now one implementation of the bridge lifecycle: the `ham-bridge`
binary. Everything else only gets a verified `ham-bridge` onto the machine and
calls it.

## Entry points

| Entry point | What it does | Then runs |
| --- | --- | --- |
| `curl -fsSL install.ninjy.ai \| bash -s -- --hub URL` ([`scripts/install.sh`](../scripts/install.sh)) | resolves the newest promoted release (or `--version`), downloads the bundle, verifies it against `SHA256SUMS` | `ham-bridge setup --headless` + passthrough flags |
| `irm install.ninjy.ai/ps1 \| iex` ([`scripts/install.ps1`](../scripts/install.ps1)) | the same on Windows (zip bundle) | `ham-bridge.exe setup --headless` |
| Desktop app, tray | ships or downloads the bundle | `ham-bridge setup --json-progress` |
| Hub "Update" (Settings → Bridges) | the bridge downloads and verifies the hub-named bundle | `ham-bridge update --bundle DIR` |
| `ham-bridge update --version TAG\|latest` | resolves the GitHub release, downloads and SHA-256 verifies the bundle | the same `--bundle` path |
| Home Manager module ([`nix/home-manager.nix`](../nix/home-manager.nix)) | declares the service under the same profile service name (`heimdall-bridge-<hub>[_<profile>]`) | the Nix-built `ham-bridge` |

The release resolve / download / verify logic exists exactly twice: the minimal
bootstrap copy in `install.sh` / `install.ps1` (needed because `ham-bridge` is not
on the machine yet) and `src/bridge/release_fetch.odin` for updates. The bootstraps
contain no install, enroll or service logic. There are no generated `enroll.*`
scripts and no `heimdall` manager binary any more: `ham-bridge enroll`, `status`,
`update` and `uninstall` replace them, and every fix reaches existing installs with
the next update.

## Transaction and rollback

`ham-bridge setup` runs the steps `lock → stage → binaries → config → ports →
service → enroll → extensions → start → verify` (`src/lib/bridgesvc/setup.odin`).
A failing step is classified, remediated and retried where that is safe (for
example a stale install lock, a stale service registration, or a provider extension
installed from another source); otherwise the whole transaction is undone: `bin.bak`
is restored, the previous service file is re-registered and the previous bridge is
restarted if it was running. Progress events: [bridge-setup-progress.md](bridge-setup-progress.md).

`ham-bridge update` runs the *new* binary's `setup` for the installed profile, so an
update gets the same rollback. `--version` refuses an unknown tag, a draft, a release
without this target's bundle or without `SHA256SUMS`, and a bundle whose digest does
not match exactly one `SHA256SUMS` entry; nothing on the machine changes in those
cases.

## Recovery playbook

| Symptom | Recovery |
| --- | --- |
| Install failed part-way | Re-run the same command; setup is idempotent and the previous install was restored. |
| Bridge not running / crash-looping | `ham-bridge status --json` shows each profile and its service state; re-run `ham-bridge setup --hub URL` to re-render and restart the service. |
| Credential revoked or machine enrolled by another account | `ham-bridge enroll --hub URL` (add `--new-bridge` for a new id); the old bridge's secrets are wiped after confirmation. |
| Update left an older version running | The update rolled back (its output names the failed step). Retry with `ham-bridge update --version latest`. |
| Wrong or broken binaries | `curl -fsSL install.ninjy.ai \| bash -s -- --hub URL` reinstalls over the existing profile, keeping its enrollment. |
| Remove a bridge | `ham-bridge uninstall --hub URL [--profile P]` (`--keep-data` keeps credential and data, `--purge` also wipes secrets). |
| Hub cannot be reached from the bridge | `ham-bridge --probe-hub URL` shows the TLS library and CA bundle the bridge's own client used. |
