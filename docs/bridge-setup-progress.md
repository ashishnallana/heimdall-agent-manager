# Bridge lifecycle CLI: `setup --json-progress`, `status --json`, `list --json`

`ham-bridge` is the single source of truth for installing and inspecting a bridge on
Linux (systemd --user), macOS (launchd LaunchAgent), Windows (per-user Scheduled Task)
and Termux (runit). Electron, the bridge tray and the thin `install.sh` / `install.ps1`
bootstraps drive it through the commands below and parse their JSON. Implementation:
`src/lib/bridgesvc` (naming, layout, ports, rendering, setup engine, lock) and
`src/bridge/service_cmds.odin` / `src/bridge/setup_cmd.odin` (live side effects).

## Profiles, service names and ports

A bridge **profile** is `(hub, optional profile name)`. Everything derives from it:

| Item | Value |
|---|---|
| hub name | lower-cased host, every char outside `[a-z0-9-]` -> `-`, plus `-<port>` for a non-default port |
| service name | `heimdall-bridge-<hub name>[_<profile>]` (profile: `^[a-z0-9][a-z0-9-]{0,30}$`) |
| state dir | `~/.config/heimdall/bridges/<service>` (Windows `%APPDATA%\heimdall\bridges\<service>`) |
| data dir | `~/.local/share/heimdall/bridges/<service>` (Windows `%LOCALAPPDATA%\heimdall\bridges\<service>`) |
| systemd | `~/.config/systemd/user/<service>.service` |
| launchd | `~/Library/LaunchAgents/<service>.plist`, label `<service>` |
| Scheduled Task | `\<service>`, runs `<data dir>\run.cmd` |
| runit | `$PREFIX/var/service/<service>/run` |
| ports | `<state dir>/ports.json` = `[bridge, endpoint]` |

Ports are allocated per profile: the persisted pair is kept while free; another
profile's recorded pair is never taken; otherwise the allocator walks up from
`49323/49324`. Two profiles or two OS users therefore no longer collide. This is the
same layout `install.sh` / `install.ps1` create, so existing installs are adopted in
place.

## `ham-bridge setup`

```bash
ham-bridge setup --hub https://hub.example.com [--profile work] \
  [--new-bridge | --reuse-bridge brg_...] [--headless] [--json-progress]
```

Installs from the bundle the running `ham-bridge` ships in (the directory of the
executable). Steps, in order:

| step | does | undo on rollback |
|---|---|---|
| `lock` | `<state dir>/.install.lock` = `"<pid> <unix seconds>"`, written to a temp file and hard-linked into place (exclusive create where hard links are unsupported), so it is never seen half-written | released |
| `stage` | records (once) whether the old service was installed/running; copies bundle binaries to `<data dir>/.staging` (`skipped` when run from the installed `bin/`) | staging removed |
| `binaries` | `bin/` -> `bin.bak/`, staging -> `bin/` | `bin.bak/` restored |
| `config` | writes `config.toml` only when missing, `hub-url`, `profile`; refuses a state dir of another hub | previous files restored |
| `ports` | allocate / keep the profile's ports | previous `ports.json` restored |
| `service` | renders the service file **on every run** and registers it (daemon-reload + enable / `schtasks /Create /F`) | previous file restored, re-registered |
| `enroll` | runs `bin/ham-bridge enroll` unless already enrolled (`skipped`); `--new-bridge`, or `--reuse-bridge` naming another bridge than the current credential's, forces it | kept (credential stays valid; a re-run reuses it) |
| `extensions` | copies the bundle's `share/heimdall/extensions` to `<data dir>/extensions` (previous copy kept as `extensions.bak`), then for every detected provider (claude, codex, antigravity) installs or repairs the Heimdall extension: a registration from another source, outdated, disabled/errored or half-installed (marketplace without plugin) is removed (`plugin uninstall`/`remove` + `marketplace remove`) and added again from the bundle, then verified; one `progress` event per provider. A provider still failing after self-heal is reported in the step message and does not roll back the install. `ham-bridge extensions sync [--data-dir D] [--source S] [--json-progress]` runs the same work after an update | bundle copy restored from `extensions.bak`; provider registrations are left as repaired |
| `start` | restart if running, else start; on macOS a restart is `bootout` + `bootstrap` so launchd re-reads the re-rendered plist | service stopped |
| `verify` | waits up to 45 s for `running && connected` (from the token-free status), counting only a `runtime-status.json` written after the (re)start by a process other than the replaced bridge | service stopped |

When a step fails with a **known** failure the engine remediates and retries it (at
most 2 times), reporting every attempt:

| failure | remediation |
|---|---|
| `stale_lock` | lock owner pid is dead, the lock is older than 30 min, or unreadable and older than 10 s: remove it (an unreadable lock younger than that is being written by a live setup and is `fatal`) |
| `partial_install` | leftover/half-copied staging: discard and re-stage (restores `bin/` from `bin.bak/` if needed) |
| `stale_service` | supervisor command failed or `bin/` is busy (Windows): stop the service; at `start`/`verify` also re-register; at `verify` also start it again |
| `port_in_use` | service not running and its port is held by another process: stop, re-allocate ports, re-render; at `verify` also start it again |

The plan per step and failure is `bridgesvc.remediation_plan`.

Any other failure (`fatal`), or a known one that persists, rolls back every completed
step in reverse order (the failed step first), and the previous install is started
again if it was running. Exit status: `0` success, `1` failure.

### `--json-progress` protocol

One JSON object per line on stdout (UTF-8, `\n`-terminated). Enrollment's own
prompts (approval URL) still go to stdout/stderr as plain text lines, so consumers
must skip lines that do not parse as JSON objects.

```json
{"step":"ports","state":"start","pct":44,"message":"","log":"","attempt":1}
{"step":"ports","state":"ok","pct":55,"message":"bridge 49325, endpoint 49326","log":"","attempt":1}
{"step":"verify","state":"retry","pct":88,"message":"service is not running and port 49325 is held by another process; remediation: stopped the service, moved to ports 49327/49328, re-rendered and re-registered the service, started it again","log":"/home/u/.local/share/heimdall/bridges/heimdall-bridge-hub-example-com/logs/bridge.err.log","attempt":1,"failure":"port_in_use"}
{"step":"setup","state":"done","pct":100,"message":"bridge installed, enrolled and running","log":"","attempt":0}
```

| field | meaning |
|---|---|
| `step` | `lock`, `stage`, `binaries`, `config`, `ports`, `service`, `enroll`, `extensions`, `start`, `verify`, or `setup` for the final event |
| `state` | `start`, `progress` (an informational line within a step, e.g. one provider's extension result), `ok`, `skipped`, `retry` (a remediation was attempted), `failed`, `rollback` (one step undone), `done` |
| `pct` | overall progress 0-100 |
| `message` | human-readable detail |
| `log` | path of a log with details, or `""` |
| `attempt` | 1-based attempt of the step |
| `failure` | on `retry`/`failed`: `stale_lock`, `port_in_use`, `stale_service`, `partial_install`, `fatal` |

A failed run ends with one `failed` event followed by `rollback` events; a
successful run ends with `{"step":"setup","state":"done",...}`.

## `ham-bridge status [--json]` and `ham-bridge list [--json]`

Readable locally **without the rotating bridge token** (F22): everything comes from
files the OS user owns plus the supervisor. The running bridge rewrites
`<state dir>/runtime-status.json` (mode 0600) on every hub connect, disconnect and
heartbeat; a file older than 10 minutes is not trusted for `connected`.

```bash
ham-bridge status --json [--hub URL [--profile P] | --service NAME]
ham-bridge list --json
ham-bridge service start|stop|restart|status [--hub URL [--profile P] | --service NAME]
```

Profile resolution: `--service`, else `--hub [--profile]`, else
`HEIMDALL_BRIDGE_SERVICE_NAME` (set in every rendered service), else the only
installed profile.

```json
{"profile":"work","service":"heimdall-bridge-hub-example-com_work","backend":"systemd",
 "hub":"https://hub.example.com","installed":true,"enrolled":true,"running":true,
 "connected":true,"vault":"unlocked","version":"0.5.18","bridge_id":"brg_abc",
 "bridge_port":49325,"endpoint_port":49326,"state_dir":"/home/u/.config/heimdall/bridges/heimdall-bridge-hub-example-com_work",
 "state":"connected","needs_reenrollment":false}
```

`state` is the one word a tray / Electron renders: `not_installed`, `not_enrolled`,
`needs_reenrollment`, `stopped`, `disconnected` or `connected`.

**Needs re-enrollment (F21, F7).** When the hub refuses this bridge's credential
(the bridge was revoked, a refresh got 401, an enrolled bridge has no credential, or
an older hub's vault key was never delivered), the bridge writes
`<state dir>/needs-reenrollment.json` (`{bridge_id,hub,reason,hint,at}`, 0600) and
then **parks** — no listener, no hub connection, exit code 0 once the marker goes
away — instead of exiting non-zero into a supervisor crash loop. (A revocation that
arrives on a live session exits 0 at once; systemd's `Restart=on-failure` then leaves
the unit stopped, launchd / Scheduled Task restart it into the park. Either way the
re-enrollment restarts the registered service itself.) `status --json`
then reports `"state":"needs_reenrollment","needs_reenrollment":true` with
`reenroll_reason` (`revoked|refresh_rejected|credential_missing|vault_key_timeout`)
and `reenroll_hint` (the `ham-bridge enroll --hub … --config …` command that
recovers it). A successful enrollment removes the marker; a marker naming an older
bridge id than the profile's current credential is ignored.

## `ham-bridge enroll` hardening

- **Running service (F2).** `enroll` stops its own profile's registered service
  (systemd, launchd, Scheduled Task, runit) before taking the config lock, retries
  the lock for up to 10 s while the process exits, (re)starts the registered service
  with the new credential on success — whether or not it was running — and starts it
  again (once) if the enrollment fails after stopping it.
- **Lost device code (REQ-ENR-12).** The hub keeps device grants in memory, so a hub
  restart loses the code being polled (which still polls `pending`, anti-enumeration).
  `/device/authorize` and every `/device/token` answer carry `grant_epoch`, the grant
  store's lifetime id; a changed epoch — or an `expired` answer for a request nobody
  approved — makes `enroll` request a new device code and pairing code (at most 2
  times) and show them again. Under `--json-progress` each code is also printed as
  `{"event":"enroll_code","approval_url":…,"pairing_code":…,"issue":n}`. Hubs without
  `grant_epoch` keep the old behaviour (poll until the deadline).
- **Another account (F1).** When the profile's bridge was approved by a different
  Heimdall account than the one approving now, `enroll` asks `[y/N]` on a terminal
  or requires `--replace-other-account` (headless / `--json-progress`). Confirmed,
  it revokes the old bridge on the hub with the old bridge's own token
  (`POST /api/v1/bridge/self/revoke`, best effort), deletes its access/refresh token
  files, rotation leftovers, vault keyring, identity record, re-enroll journal and
  needs-reenrollment marker, then writes the new credential. The local wipe runs
  before the hub revoke (the old token is held in memory), so a failed wipe leaves the
  old bridge working rather than revoked and half deleted; a credential-file conflict
  is checked before either. Declined, nothing is written and the just-approved bridge
  is revoked again.
- **Vault key timeout (F7).** With an atomic-enrollment hub everything is rolled
  back (a previous credential stays usable; re-run to retry). With an older hub the
  profile is marked `needs_reenrollment` (`vault_key_timeout`) and the retry command
  printed; the service parks until that re-enrollment. Every successful enrollment
  (atomic or not) clears the marker before restarting the service.

`vault` is `unlocked`, `locked`, `unpaired` or `unknown` (no runtime status yet).
`list --json` returns `{"profiles":[<status>, ...]}` sorted by service name. With no
installed profile, `status --json` prints `{"installed":false,"error":"..."}` and exits 0.

## `ham-bridge uninstall`

```bash
ham-bridge uninstall [--hub URL [--profile P] | --service NAME] [--keep-data | --purge] [--json-progress] [--yes]
```

Removes one profile and **every credential and secret** it holds (F20). The default
is `--keep-data` (logs and agent data stay); `--purge` removes the data dir too. An
interactive terminal is asked to confirm unless `--yes`/`--headless`/`--json-progress`.
Steps (bridgesvc `run_uninstall`; `--json-progress` emits the same event lines as setup,
plus state `warning`):

| step | removes |
|---|---|
| `revoke` | the hub revokes the bridge, called with the bridge's own token (`POST /api/v1/bridge/self/revoke`), read before anything is deleted. An unreachable hub is retried, then a `warning` (revoke it in Settings -> Devices); local secrets are wiped anyway |
| `stop` | stops the service and waits for the bridge pid; remediation: stop again, TERM, then KILL. The pid from `runtime-status.json` is used only when it is a `ham-bridge*` process (`/proc/<pid>/comm`, `ps -o comm=`, `Get-Process .Path`), or, when the OS cannot say, while the service runs: a stale file's reused pid is never waited on or signalled |
| `unregister` | systemd `disable` + unit file + `daemon-reload`; launchd `bootout` + plist; `schtasks /Delete`; runit service dir |
| `secrets` | access/refresh token files, `.pending-rotation-v1`, refresh request and marker files, the vault keyring, identity record and epoch floor in Keychain / Credential Manager / kernel keyring (private files on Linux), the per-scope vault dir |
| `extensions` | `<data>/extensions{,.bak,.new}` |
| `caches` | `.staging`, `run/`, `cache/`, `bootstrap-cache/`, `updates/`, `run.cmd`, `task.xml` |
| `binaries` | `bin/`, `bin.bak/` |
| `state` | the profile's state dir (config, ports, hub-url, markers) |
| `data` | the data dir (`--purge` only) |

A step that still fails after remediation is reported (`failed`) and the uninstall
continues; exit status is non-zero when anything was left behind. On Windows a
running `.exe` is locked, so an uninstall started from `bin\ham-bridge.exe` asks for
confirmation, starts a copy in `%TEMP%` on the same console (`--yes --relocated
--wait-pid <pid>`) and exits; the copy waits for that pid to exit (30 s) before it
starts. A run from a temp copy (relocated, or the remote uninstall) deletes its own
executable at the end: unlinked on POSIX, removed by a hidden PowerShell 3 s after
exit on Windows, so `--purge` leaves no binary behind.

**Remote uninstall.** `POST /api/v1/bridges/{id}/uninstall` `{"purge": true}` (user
session of the owning account only; another account gets 404, a bridge token 403, an
offline bridge 422 — revoke it instead) sends `{"type":"bridge_uninstall","command_id",
"mode":"purge"|"keep_data"}` to the live bridge. The bridge acks `accepted` and starts
`ham-bridge uninstall --purge --yes --service <its service>` from a copy outside `bin/`
in a session of its own, which revokes it on the hub and wipes it. Every request is
audit-logged: `ham-hub bridge_uninstall outcome=dispatched|denied|offline|failed
bridge_id= user_id= command_id= request_id= detail=`.

## `ham-bridge update`

```bash
ham-bridge update --bundle DIR [--hub URL [--profile P] | --service NAME] [--json-progress] [--detach]
```

Runs the NEW binary's `setup --headless` for the profile (`DIR/ham-bridge` or
`DIR/bin/ham-bridge`, preflighted with `--version`). That transaction is the update:
staging, `bin.bak`, service re-render, extensions on every OS, restart, health =
running **and** connected to the hub, and on failure `bin.bak` restored and the old
bridge restarted. Inside the service being updated (or with `--detach`) it runs in a
session of its own. `--version V|latest` resolves the GitHub release, downloads this
OS/arch's bundle and SHA-256 verifies it against `SHA256SUMS` before applying it; an
unknown or unverifiable release changes nothing.

**Hub-initiated update.** The bridge stops its PTY host (found through the socket's
peer pid; only a `ham-pty-host` image is signalled), hands the staged bundle to
`ham-bridge update --detach` and waits for it (30 s): the preflight (hub recorded,
bundle binary runs) happens before setup is detached, so an early failure comes back
to the hub as a failed update and the PTY host restarts on the next launch. There is
no update script any more (`apply-bridge-update.{sh,ps1}` were removed): a bridge that
is not a bridgesvc profile install, or a hub downgrade, is refused before anything is
downloaded, and bridges installed before this release are reinstalled once with
`curl -fsSL install.ninjy.ai | bash` (Windows: `irm install.ninjy.ai/ps1 | iex`).
