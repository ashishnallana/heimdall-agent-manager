# Codex 0.162.0 release gate

Base: published main `90e287c288fb03820018a0bc43811422639ec394`; isolated worktree `/home/tanmay/hamwt/ext-codex`. Native executable: `/nix/store/qid6zisr24g7cw5ibmh74chjrm0xzpv3-codex-0.162.0/bin/codex`. Official references checked: [Hooks](https://learn.chatgpt.com/docs/hooks), [Package your plugin](https://developers.openai.com/plugins/build/plugins).

## Actual callbacks

The committed `src/ctl/extension/testdata/codex/callbacks.json` contains **80 actual callbacks**, captured on 2026-10-22. Native identifiers are consistently anonymized; scratch paths become `/workspace`; prompt/transcript text and child instructions are omitted/redacted. The first capture pass retained known metadata; later captures also retained unexpected metadata. The repeated nonzero shell callback in the latter pass still had only stdout, with no exit-status field.

| Capability | Actual evidence | Limit |
| --- | --- | --- |
| Session identity | startup, clear, resume, fork SessionStart; SessionEnd | Manual compact did not emit SessionStart(compact) |
| Activity | prompt, tool calls, Stop, Interrupt | Parent idle does not establish child completion |
| Tools | correlated Pre/Post Bash success, exit7, long-running poll; apply_patch | Bash outcome unknown; failed patch omitted PostToolUse |
| File edits | confirmed create/update/move/delete patch callbacks | No deleted preimage or update offsets; partial snippets only |
| Children | lifecycle and child Bash callbacks share parent session, carry child ID/type | No claim of complete hosted-tool coverage |
| Permissions | parent and two concurrent child requests with distinct child identity | No native permission tool-use ID; relay generates stable blocker IDs |
| Notifications | no native generic hook | Unsupported |

Actual callback sessions: `sh_c9c04a08a30ae3d2b17fd87f85c8400b`, `sh_999a32f685db8d5c3887bf0835088d81`, `sh_477c0125640b783ec24571e06d7abe25`, `sh_6028c361bdda3e5eac3f3e3805f1dbf7`.

## Packaging and trust

Native marketplace/add/list confirmed `heimdall@heimdall-codex`, version `0.1.0`, enabled. Root portable manifest variants produced **No plugin hooks**; source/cache bytes matched and fresh native processes were used. Compatibility-only `.codex-plugin/plugin.json` exposed all ten hooks as **untrusted**, without a bypass. Coordinator approved that release-specific layout in `msg_18e0d4173a56b7ac`. Native inventory proof: `sh_594771b830b5c030cd47ab85c072039f`.

Normal native `/hooks` review/trust then activated them. A temporary change to the installed SessionStart command was reported as **modified**; exact installed bytes were restored. Local marketplace upgrade was rejected as Git-only; remove/add refreshed the local package.

## Installed native-to-bridge test

This is compositional evidence, **not a continuous deployed hub/UI E2E**. An opt-in loopback test listener executed real bridge ingest, tool aggregation, and permission reducers, with two distinct synthetic issued-instance mappings. It did not forward to a Hub or use production configuration.

Two simultaneous genuine Codex sessions loaded the installed package and invoked the built ctl:
- Instance one: 14 events, provider `codex`, native hello/session, tool calls and a confirmed file edit. A real pending blocker resolved allow and the native command printed `fixture-live-allow`. Deny yielded **Blocked by hook** and the command was not retried.
- Instance two: 6 events with a different native session ID. A 5000ms no-decision timeout returned the native approval UI. A subsequent one-time terminal approval executed `fixture-timeout`.
- Both final blocker lists were empty. No event drops. Native activity source was `codex_extension`; the existing shared runtime projects blocked activity as idle, with permission waiting represented by its blocker.
- Listener `sh_cde3d2e05e0a103f62b1486efb1214cf` exited successfully: **1/1**, 2m35.7s. Outcome evidence: `sh_3e12419ea70d818f1b92937625059a0c`.

Private raw native/E2E reports remain under `~/.cache/heimdall-codex-fixtures`; no credential data is included in repository artifacts. All scratch Codex processes stopped. Cleanup `sh_7979c8d22a12c281d1b0677939132f86` confirmed original auth/config checksums unchanged and removed the authorized temporary auth copy.

## Automated checks and remaining integration

Focused runs passed adapter/patch/re-registration (6 tests), detector/aggregator (23 at that milestone), bridge native replay (2), hub native hello/auth ingestion (4), SQLite descriptor/canonical etag (8), UI badge/timeline/tool activity (35 at that milestone), and TypeScript build. Subsequent regression additions are included in the required final task verification; its facet is the authoritative final counts/head/result.

Use the repository's Node loader: `node --import ./tests/helpers/vaultEndpointHarness.ts --test ...`. Direct Node import fails through an existing extensionless dependency; no unrelated source workaround was added. The unchanged Claude transport-failure regression deliberately takes approximately 300 seconds.

The coordinator explicitly deferred continuous startup+Codex+Hub/UI validation until the branches are reviewed and integrated (`msg_18e0d39b34e08e16`). REQ-CODEX-START-1 uses this adapter's genuine hello/session(start) with the startup branch's generation/identity validation and fallback engine; no duplicate readiness implementation was added. Migration112 merges extension JSON keys and preserves111 metadata; integration must recompute the canonical catalog etag after combining both branches.
