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
 "bridge_port":49325,"endpoint_port":49326,"state_dir":"/home/u/.config/heimdall/bridges/heimdall-bridge-hub-example-com_work"}
```

`vault` is `unlocked`, `locked`, `unpaired` or `unknown` (no runtime status yet).
`list --json` returns `{"profiles":[<status>, ...]}` sorted by service name. With no
installed profile, `status --json` prints `{"installed":false,"error":"..."}` and exits 0.
