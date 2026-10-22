# Hot-path write reduction

Branch `hotpath-writes`, base `ae2728d78e42fc11c172cf93983598354bf784db`.
Dependency commits `a17227e5` and `56c3c313` were cherry-picked as `ff7507fb` and `cfe5316d`.
No production service, configuration, database or durability settings were changed.
This report describes local work counters, not production latency or physical IO.

## Four-site decisions

| Site | Change and correctness boundary |
|---|---|
| Vault touch | One conditional UPDATE on the existing dedicated writer under the existing vault mutex. Presence is approximate within **300 seconds**: first NULL/invalid stored timestamp updates, 299s skips, 300s updates. Canonical hub timestamps have second precision. Incoming malformed timestamps and clock regression retain previous unconditional-update behavior. Owner/device filters remain. No directory version/log, approval, revocation, retirement, token or authentication field is changed. No cache or preflight SELECT. |
| Mark messages read | Suppress only exact repeats with `read_at IS NOT ?1`, including correct NULL handling. Fresh timestamps still replace previous read_at. Return `len(message_ids)` as before, including duplicates and missing/wrong-owner IDs. Empty input and error paths retain their old results. Do not interpret the return as SQLite changed rows. |
| Shell UPSERT | Atomically compare the complete **effective** update tuple using NULL-safe `IS NOT`. The predicate duplicates the existing CASE/MAX rules: background and run_seq monotonic; nonempty conversation/label/cwd/activity/finish and nonzero pid/port preserve old defaults; nullable exit_code assigns directly; every terminal status clears kill intent. Return true for successful no-ops as before. No read/cache/race window. |
| Bridge save | **Unchanged**. Advancing heartbeat last_seen_at/updated_at must remain durable for absence, restart and reaper semantics. The measured equal-value row already produced zero page writes; full-row suppression adds no demonstrated disk-work benefit. Token hash/status/revocation/enrollment/update transitions remain immediate. Existing offline and vault-status service guards remain. |

Migration `103_guard_chat_fts_updates.sql` replaces only conversation/message AFTER UPDATE FTS triggers. It compares title/body **and rowid** with `IS NOT`, so assigning unchanged text does not reindex, and genuine text/identity changes still delete old postings and insert new ones. INSERT/DELETE triggers are untouched; no rebuild is necessary because existing postings are unchanged. Both the file and embedded migration paths are registered. Non-FTS builds skip the migration under the existing FTS availability convention. Independent source review should include this fallback branch; the local SQLite library has FTS5.

The API/domain comments now document approximate vault presence. This is the only nearby documentation cleanup.

## Consumer audit

All paths below are relative to the worktree. The task-1 caller map in `docs/call-reduction-decision-matrix.md` supplies detailed routes/cadences; this section records the implementation conclusions.

| Stored values / consumers | Why behavior remains correct |
|---|---|
| `vault_devices.last_seen_at`: SQLite `DEVICE_COLUMNS`, `device_from_stmt`, device insert binding; `vault_list_devices_sqlite`/`vault_get_device_sqlite` feed service `get_directory`/`get_device`; `src/hub/transport/http/vault_directory_handlers.odin` device wire projection; UI `src/ui/utils/vaultDirectoryVerify.ts` type, `devicesPanelModel.ts` normalization, `src/ui/components/settings/DevicesPanel.tsx` last-seen display and revoke-confirmation hint. Genesis sets the initial timestamp. | Consumers receive a timestamp from a valid signed request, at most 299 canonical seconds behind the latest accepted touch in a monotonic clock interval. An inactive device can naturally be much older. First touch, restart and exact boundary are tested. Last seen is not part of signed directory/log verification and is not used by vault approval, code expiry, reset deadlines, retirement, revocation or authentication decisions. The display/revoke hint becomes explicitly approximate. There is no vault stale-device pruning consumer. Bridge/agent tables' similarly named columns are separate and unchanged. |
| `chat_messages.read_at`: `src/hub/repository/sqlite/content_repo_sqlite.odin` message projections, unread-only message filtering, unread-ID enumeration and user-visible message lists; attention unread selection in `attention_repo_sqlite.odin`; `src/hub/service/content/content_service.odin` mark-by-ID / mark-with-receipts and attention projection; `src/hub/transport/http/content_handlers.odin` message JSON and `messages_read` events; `agent_action_handlers.odin` inbox/read responses and `resource_events.odin` event projection; client receipt/unread consumers in `src/ui/api/conversationMessageEvents.ts`, `src/ui/api/wsInvalidation.ts`, `src/ui/api/endpoints/chats.ts`, `src/ui/store/chatSlice.ts` and `src/ui/components/workbench/AgentChatPane.tsx`. | Exact repeats leave identical persisted state; different clocks still write the latest read timestamp. Existing owner scope, batching, input-count return, attention notification and receipt publication are untouched. Already-read UI conversations still save fresh updated_at, including fallback ordering/receipt timestamps. No event is suppressed based on the guarded SQL result. Baseline service replay validates 100 receipts on first UI read and zero thereafter, and all existing service assertions still pass. |
| Conversation title and message body / rowid: `chat_conversations_fts`, `chat_messages_fts`; search providers in `src/hub/repository/sqlite/search_repo_sqlite.odin`; FTS recovery in `fts_repair.odin`. | No stored title/body/rowid behavior changes. Real title/body edits remove old matches and create new matches; metadata changes skip only unnecessary index work. Migration upgrade on pre-103 data, rerun idempotence, same-text assignments, body/title edits and repair are tested. Full rebuild still uses canonical FTS rebuild and preserves the guarded triggers. |
| Shell status/exit_code/pid/server_port/background/run_seq/kill_requested_at/conversation_id/label/cwd/finished_at/last_activity_at: SQLite owner/list/filter/live/retention queries in `shell_session_repo_sqlite.odin`; `src/hub/service/shell_session/shell_session_service.odin` create/event/restart/signal/kill/background/port/list; `shell_session_reap.odin`, `shell_session_retention.odin`, `shell_metrics.odin`; `src/hub/app/reaper.odin`; shell HTTP handlers and JSON projections; bridge runtime notifications; UI shell endpoint, detail/log/list and `ShellRunIndicator.tsx`; ctl shell command output/exit handling. | The effective stored tuple is byte-for-byte the same as the original UPSERT for every call. Status changes and all nullable/nonempty/nonzero assignments are tested individually. Monotonic merges and pending kill preservation survive concurrent stale defaults. All domain terminal statuses clear kill intent. Start requests, events, run restart counters, retention clocks, reapers, metrics, logs and notifications continue through the existing service paths. No durable audit record or event is suppressed. There are no product shell UPDATE triggers with independent side effects to preserve. |
| Bridge last_seen_at/updated_at/security and state fields: bridge service connect/offline/heartbeat/vault-status/revoke/update/progress, device/pending enrollment; `bridge_absence_marker`, `app/reaper.odin` absence/session reaping; `app/metrics_db_collectors.odin` active-owner accounting; bridge/device-auth HTTP projections; UI bridge settings and bridge status; restart reload and token authentication. | Site and all callers unchanged. Scoped tests additionally assert fresh heartbeat timestamps and same-clock token-hash/status/revocation changes persist immediately. Advancing-heartbeat replay retains 120 WAL frames, deliberately. |

The unchanged-value guards remove no service-layer audit operation. Task comment insertion plus taskv2 audit-event insertion and their transactions are untouched. No lock order or dedicated-connection selection changed. A changed write still exposes prepare/step errors and rolls back atomically on injected aborts. A skipped redundant update does not execute its UPDATE triggers; this is the intended optimization, and the affected product triggers are only the redundant FTS work above.

## Verification

```bash
bash verify-hotpath-writes.sh
```

The script creates uniquely named binaries below `$HOME/.cache/heimdall-tests`, runs the standalone scoped Odin tests, runs the task-1 real-procedure replay, and builds `src/hub`, all Odin invocations through `nix develop -c`. It exits nonzero for any failure. It does not run unrelated known-failing suites or connect to a live Hub.

Five tests passed on 2026-10-22; the complete precommit command exited 0, session `sh_c6396a1440f4476248097ee5485706bc`, log `/home/tanmay/hamwt/hotpath-writes-precommit-verify.log`. The final clean-commit `ham-ctl verify` result is recorded in the task handoff.

Test coverage includes owner/missing-ID boundaries; NULL, repeated, 299s, inclusive 300s, regressing and invalid timestamps; all effective shell assignments and terminal statuses; duplicate/missing IDs and latest-read return/timestamp behavior; FTS upgrade and repair; explicit prepare/step error injection; four simultaneous callers (20 iterations each) sharing the main connection and the vault dedicated writer on a disposable WAL database; closing/reopening both connections and confirming throttle continuity. The tests use audit triggers to observe actual UPDATE execution, rather than trusting connection-global sqlite3_changes.

Initial failed test attempts were test-fixture mistakes (Odin slice literal parentheses, missing created_at seed value, explicit os.get_env allocator); fixed before the passing run. No product implementation approach was abandoned.

## Measurement limits

The raw after replay is `docs/hotpath-writes-after.txt`; baseline is `docs/call-reduction-baseline-results.md`, both SQLite 3.53.3 on the same generated fixture and same replay source. Statement counts include top-level SQL, not trigger internals. Page writebacks and WAL frames are SQLite counters, not fsync/physical-device writes. HTTP trigger counts are modeled and unchanged.

All SQL statement counts and instrumented connection/mutex acquisition counts remain unchanged: these predicates reduce row/index/page work inside statements, not the number of requests or lock acquisitions. In particular, conditional UPDATE still enters the writer path. No production latency improvement is claimed.

The vault advancing scenario begins with genesis last_seen_at at 00:00:00 and makes 30 touches from 00:00:04 through 00:02:00, so none reaches the five-minute boundary: 30→0 frames in that window does not imply zero writes forever. At a sustained four-second cadence one meaningful presence write occurs every 75 calls (tested at 300s); first NULL presence writes immediately.

The report's before/after table below uses only exact scenario matches. Stable/no-change rows make the no-change boundaries explicit.

| Scenario | Top-level statements before → after | DML executions before → after | VM before → after | Page writebacks before → after |
|---|---:|---:|---:|---:|
| shell identical registration x92 | 92 → 92 | 92 → 92 | 13708 → 12512 | 92 → 0 |
| conversation read x21 service | 64 → 64 | 22 → 22 | 27071 → 25578 | 104 → 34 |
| conversation already read x20 service | 60 → 60 | 20 → 20 | 17380 → 17100 | 80 → 20 |
| conversation already read changing clock x20 | 60 → 60 | 20 → 20 | 17380 → 17100 | 100 → 40 |
| mark read same 10 ids x21 service | 21 → 21 | 21 → 21 | 17522 → 3423 | 133 → 5 |
| agent already read same 10 ids x20 service | 20 → 20 | 20 → 20 | 16640 → 2660 | 141 → 0 |
| vault advancing 4s x30 dedicated conn | 30 → 30 | 30 → 30 | 1562 → 1172 | 30 → 0 |
| bridge heartbeat advancing 45s x120 service | 240 → 240 | 120 → 120 | 18480 → 18480 | 120 → 120 |
| task comments x30 service engine no projector | 150 → 150 | 60 → 60 | 4710 → 4710 | 300 → 300 |

Vault WAL frames: 30 → 0. Advancing bridge heartbeat frames: 120 → 120.
