# Ephemeral live tools: integrated verification

Integration branch: `live-tools-integrate`, based on fetched `origin/main`
`f4c39179`, with full approved backend `a58451fa` and UI `9feb2ba5`
ancestry. Merge commit: `38d150dc`.

## Integration fix

The first real-stack run showed owner-scoped live pushes working while every
one-shot REST snapshot failed after five seconds. The Bridge command dispatcher
rejected `tool_activity_live_request` before its implemented handler could run.
Registering it as a known immediate control frame fixes attach, chain reads,
reconnect, and restart recovery. The bounded memory-only handler performs no
process or network waits. The dispatcher regression covers this registration;
the fresh-stack harness exercises the complete request/reply transport.

## Reproduce

```bash
bash /home/tanmay/hamwt/live-tools-integrate/verify-live-tools-integrate.sh
```

The script enters `nix develop`, creates a unique evidence directory under
`~/.cache/heimdall-tests`, builds integrated Hub/Bridge/CLI/dev-proxy binaries,
and runs 11 focused Odin regressions, the real-stack harness, 28 UI tests (including subtests),
TypeScript, and Vite/Electron production builds. It uses the installed
`ham-pty-host` (or `LIVE_TOOLS_PTY` override), recording its path and SHA-256.
No Rust sources are changed. The harness needs free loopback ports 18680,
18681, 15673, 49681, and 49682. Local launchers refuse conflicting listeners.

The fresh Hub and enrolled Bridge use their own DB/config/credentials/data.
Only those named local services are restarted/stopped. Enrollment's installed
service commands are scoped no-op shims from the existing local launcher.
No production deployment, live service restart, shared-checkout edits, or
historical data deletion occurs.

## Evidence and requirement trace

Each run prints its evidence directory. `manifest.json` records every command
and outcome, exact source commit, REST snapshots, chain roster, SQL counts,
historical rows, shell log, permission decision, and individual assertions.
Owner and foreign-owner WebSocket payloads are saved as JSONL.
`verification.json` records builds/test counts and evidence/binary checksums;
`verify.log`, individual Odin logs, `ui.log`, and `ui-build.log` retain output.

| Requirement | Direct evidence |
| --- | --- |
| REQ-LIVE-1: running state before completion | Real CLI canonical ingest → Bridge → owner WS start before any end/chat fetch; one-shot REST confirms active; two concurrent calls in A and one in B stay separate |
| REQ-LIVE-2: completion and one last duration | End removes the call; final 1→0 empties active; duplicate end and delayed original start cannot resurrect; real shell run completion/kill follows the same path |
| REQ-LIVE-3: no conversation writes/history damage | SQL counts before/after/final show zero new `tool_activity`/`shell_run`; two preseeded historical rows remain exactly unchanged; authenticated legacy POST returns `persisted:false`; UI tests hide markers and preserve raw-page cursors |
| REQ-LIVE-4: chain/UI/operations | Real two-member chain snapshot and captured actual payloads render in React/JSDOM; delayed initial snapshot loses to newer live completion; collapsible groups/final removal/one last duration; shell log and kill, separate Activity/file/subagent projections and waiting permission-hook allow all work |
| REQ-LIVE-7/9: Bridge authority, relay-only Hub | Hub restart during an active call recovers it from Bridge memory and does not replay completed tools/shells; recovered call then completes; Bridge process restart starts empty; actual agent stop fences UI and relaunch emits explicit resync |
| Bounds/security/no polling | Scoped Odin tests exercise binding/run/epoch rejection, unsolicited/late replies, pending caps/deadlines, bounded chain pages, source memory/wire caps, and relay sequence/rate limits; live foreign-owner WS and REST checks reject tool content; UI fake-clock test proves zero recurring reads across ten idle minutes |

## Scope and qualifications

Provider events are **injected canonical `ham.ext.v1` events**, delivered by the
real built CLI to the actual Bridge. A synthetic idle provider process is
launched through normal Hub/Bridge launch/bootstrap/token flow; this run claims
no new provider-native Claude/Codex callback evidence and uses no model quota.
The permission scenario uses synthetic native-shaped hook input through the
real hook adapter and waiting transport. Shell commands and output are real.

The UI integration uses actual recorded REST/WS payloads with the production
component/reducer in JSDOM. It is not a newly paired browser or visual screenshot
run. Existing focused DOM tests additionally verify raw pagination and shell
navigation. Native provider behavior was covered by approved preceding work;
broader provider releases, hosted tools, and real-browser visual acceptance are
not asserted here.

Stopped instances can return the documented `bridge_offline` 409 once their
source identity is retired. The stop check waits for terminal status and an
owner WS unavailable fence; it does not treat an unavailable source as a ready
snapshot. Successful relaunch must emit resync and return a fresh empty snapshot.
