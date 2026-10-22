# Plan: DB call latency and lock contention telemetry (hub)

- **Task:** `task_18e09a5a0466c12e` (chain `chain_18e07ff905d87912`). Plan only: no code, no production change, no load test.
- **Source pinned to:** `origin/main` = `2a467a5aa9f94fcf1e2515f83521b31a615ed6b1` (tag `v0.4.26`, deployed on Dawnstar per `task_18e098a27772ef68`). All `file:line` citations below are at this commit, read with `git show origin/main:<path>` / `git grep -n … origin/main` (shared checkout not modified; it sits on `fix/install-enroll-before-service-start`, local `main` is the older `244bedbf`).
- **Drift check vs the reader-plan base:** `git diff --stat 244bedbf origin/main -- src/hub/repository/sqlite src/hub/app/metrics_db_collectors.odin` → only `shell_session_repo_sqlite.odin` changed (+28/-8). `docs/plans/sqlite-reader-pool.md` is byte-identical at both commits.
- All paths are relative to `src/hub/` unless they start with `src/` or `docs/`.
- **Revision 2** (review round 1, `changes_requested`): adds the service-mutex audit (§1.5a: `projector_mutex`, `reconfiguration_mutex`, `launch_preferences_mutex`) and the matching `lock` values; disjoint emitted components (`exec_excl_busy` + `busy_wait`); a scrape-reset waiter high-water mark and a contended-acquisition counter; a concrete connection-tagging mechanism; statement counting at the first step of each execution; "select steps/s" wording.
- **Revision 3** (review round 2, `changes_requested`): bounded per-call-site attribution (`site` label on three new counters, `loc` threaded through `step_changes` / `step_write_healing`, per-step `stmt_status` deltas) so R5 is computable with a PromQL `topk` (§2.2a, §4.5, §5.2); S/R thresholds marked provisional and frozen on the normal baseline before busy windows are read (§5.2); `reason=slow|sample` on slow records, S4/R4 use `slow` only (§3); per-call ns figures marked as estimates gated by the §4.3 microbenchmark (§4.1); series arithmetic includes `+Inf`, `_sum` and `_count` (§2.2).

---

## 0. Why this plan exists (what the evidence does and does not show)

- **Dawnstar v0.4.25 → v0.4.26, matched 120 m windows** (`task_18e098a27772ef68`): HTTP −28 %, SQLite selects −41 %, CPU −28 %, HTTP p50/p95/p99 unchanged (bucket-limited), `heimdall_sqlite_busy_total` 0 → 2. Confounders: host write latency ~146 ms episodes and an unclean reboot in the POST window.
- **None of that measures mutex contention.**
  - `heimdall_sqlite_busy_total` counts only calls that *failed* with BUSY/LOCKED after `busy_timeout` gave up (`repository/sqlite/sqlite_metrics.odin:23-25,93-94`). A call that waited 4.9 s and then succeeded is invisible.
  - The step histogram includes the SQLite connection-mutex wait but cannot separate it from execution (§1.3).
  - HTTP buckets start at 10 ms (`transport/http/metrics_http.odin:25`), so a few ms of extra queueing per request cannot show in p50/p95.
- **The prior reader-pool plan** (`docs/plans/sqlite-reader-pool.md`, rev 2) asserts a throughput limit ("~130–290 SELECT/s", "capacity about 50–60 active users", lines 10-14) with no measurement behind it. Its stage 0 adds only `heimdall_sqlite_uow_hold_seconds` (line 339, §10 lines 474-485).
- **The independent review of that plan** (`/home/tanmay/hamwt/sqlite-reader-plan-review-report.md`, at `244bedbf`) found as Finding 1 (High) that the performance case is unproven, and asked for: connection utilisation, mutex wait measured separately, the request-latency share, and a stated go/no-go threshold before stage 5. It also flagged the SQLite WAL-reset bug (≤ 3.51.2) as a gate (Finding 3), the deferred `BEGIN` / `BUSY_SNAPSHOT` hazard (Finding 4) and the missing write-wait metric (Finding 5).
- **Reconciliation:** none of those review findings has landed on `origin/main` (the plan file is unchanged, `tx.odin:99` is still `BEGIN;`, there is no `sqlite3_libversion`, `sqlite3_busy_handler`, `sqlite3_stmt_readonly` or `uow_hold` anywhere in `src/hub`: `git grep` returns nothing). This plan is the measurement half of review Finding 1/5 and replaces stage 0's single `uow_hold_seconds` metric. The lock-hygiene items of stage 0 (B1/B2/M1/M2) are out of scope here.

---

## 1. REQ-DBT-1: Current DB paths at `2a467a5a`

### 1.1 Connections (five handles on one file, all WAL)

| Handle | Opened at | Pragmas | App lock around it |
|---|---|---|---|
| main `App_Graph.db` | `app/wiring.odin:233` (`sqlite.open`) | `busy_timeout = 5000` `:237`, `journal_mode = WAL` `:243`, `synchronous = NORMAL` `:244`, `foreign_keys = ON` (`repository/sqlite/conn.odin:81`) | **none** for autocommit statements; `tx_mutex` for units of work (§1.4) |
| billing | `repository/sqlite/billing_repo_sqlite.odin:43` | `busy_timeout = 5000` `:46` | `impl.mutex` at `:89,108,124,150,157` |
| bridge enrollment commit | `repository/sqlite/bridge_repo_sqlite.odin:31` (via `app/wiring.odin:278`) | `busy_timeout = 5000` `:34` | `impl.commit.mutex` (`bridge_token_repo_sqlite.odin:178`) |
| vault directory | `repository/sqlite/vault_directory_repo_sqlite.odin:35` | `busy_timeout = 5000` `:38` | `impl.mutex` at `:289,364,441,456,498,561,700,732` |
| metrics collector (read) | `app/metrics_db_collectors.odin:91` (attached from `app/wiring.odin:250`) | `query_only = 1` `:93`, `busy_timeout = 1000` `:94` | `db_collectors.mu` `:123-124` (held across the scrape query) |

- Linking: `foreign import sqlite3_lib "system:sqlite3"` (`repository/sqlite/conn.odin:16`), `sqlite3_open` (`:30,76`), so serialized threading mode by default and the library version is whatever the host provides (unknown on Dawnstar; dead end in chain summary).
- `close` ignores `sqlite3_close`'s return code (`conn.odin:89-97`).

### 1.2 FFI wrappers and statement choke points

- `sqlite3_step` and `sqlite3_exec` are bound as `sqlite3_step_raw` / `sqlite3_exec_raw` (`conn.odin:38-42`) and wrapped with same-signature Odin procs (`sqlite_metrics.odin:72-84`). Every repository call goes through them (comment `sqlite_metrics.odin:12-15`).
- **Not wrapped / not timed:** `sqlite3_prepare_v2` (`conn.odin:32`, 202 production call sites across `repository/sqlite/*.odin` by `git grep -c`), `sqlite3_finalize` (`:33`), `sqlite3_reset` (`:40`), all `bind_*` (`:46-50`), all `column_*` (`:44,51-53`). In a serialized build each of these also enters the connection mutex (SQLite source behaviour, `vdbeapi.c`; not stated on sqlite.org), so their mutex waits are completely unmeasured today.
- `exec` helper (`conn.odin:99-112`) → `sqlite3_exec` wrapper; prints SQL to stderr on error (`:106`) — note for the "no raw SQL" rule: that is a log, not a metric, and is pre-existing.
- `step_changes` (`conn.odin:123-130`) takes `sqlite3_db_mutex(db)` with `sqlite3_mutex_enter` (`:124-126`) **outside** the timed wrapper, then calls the wrapped `sqlite3_step` (`:127`). Its mutex wait is therefore **not** in any histogram, while for plain `sqlite3_step` calls the wait **is** inside the step timer. The same metric has two different meanings depending on call site.

### 1.3 Existing DB metrics and their timer boundaries

| Metric | Defined | Start | Stop | Includes |
|---|---|---|---|---|
| `heimdall_sqlite_query_duration_seconds{op}` | `sqlite_metrics.odin:59-60`, buckets `:42` (0.5 ms … 1 s) | `time.tick_now()` before `step_raw`/`exec_raw` (`:73,80`) | `tick_since` after (`:75,82`) | conn-mutex wait (serialized mode) + VM execution + page-cache misses/IO + WAL append + **busy_timeout sleeps** for that call. `count` = step calls, not statements (`:18-21`). No connection label: all five handles mix. |
| `heimdall_sqlite_busy_total` | `:61-62`, `:93-94` | — | — | only final BUSY/LOCKED failures |
| `heimdall_sqlite_db_bytes`, `heimdall_sqlite_wal_bytes` | collector `:216-232` | scrape | | file sizes |
| `heimdall_http_request_duration_seconds{route,method}` | `transport/http/metrics_http.odin:31-32`, buckets `:25` (10 ms … 5 s) | `transport/http/server.odin:141` (after request read, after upgrade/raw routes are ruled out `:116-135`) | `:143`, before `write_http_response` `:144` | everything in `router_dispatch_matched` |
| `heimdall_http_in_flight` | `metrics_http.odin:33-34`; inc/dec `server.odin:139-140` | | | |

- `op` classification by first keyword, fixed enum (`sqlite_metrics.odin:100-143`); `with` → `select`, `replace` → `insert`, `end` → `commit`.
- Hot-path cost today: every step calls `metrics.with(family, op)` (`sqlite_metrics.odin:92`), which builds a key and takes a shared `RwLock` per call (`src/lib/metrics/metrics.odin:213-224`), then `observe` scans buckets with two atomics (`:368-375`).

### 1.4 Transactions and the unit-of-work mutex

- `tx_mutex` / `tx_owner_thread` / `tx_depth` / `tx_after_commit` are file-private process globals (`repository/sqlite/tx.odin:39-52`).
- **Acquire:** `sqlite_uow_begin` → `lockorder.assert_tx_mutex_allowed()` (`:97`) → `sync.mutex_lock(&tx_mutex)` (`:98`) → `exec "BEGIN;"` (deferred) (`:99`). BEGIN failure unlocks and returns `.Internal_Error` (`:99-101`).
- **Nested:** same-thread re-entry opens `SAVEPOINT uow_N` without the mutex (`:84-96`).
- **Release:** outer commit `exec "COMMIT;"` (`:162`), on failure `ROLLBACK` (`:163-167`), resets depth/owner (`:173-174`), `sync.mutex_unlock` (`:175`), then runs after-commit hooks outside the lock (`:176-178`). Rollback path `:184-202` (unlock `:201`). Nested commit/rollback are RELEASE / ROLLBACK TO (`:150-160,188-193`).
- **What tx_mutex does NOT cover:** autocommit statements of other threads on the same `App_Graph.db` handle run concurrently and land inside the open transaction (comment `:10-15`; reader plan "lost write"). So `tx_mutex` hold time is *not* the main connection's write-lock hold time.
- **Dedicated-connection transactions** use their own mutex + `BEGIN IMMEDIATE`: billing `billing_repo_sqlite.odin:89-101,124-143,157-188`; enrollment `bridge_token_repo_sqlite.odin:178,198,246`; vault `vault_directory_repo_sqlite.odin:364-434`. FTS repair: `fts_repair.odin:56,70` (`BEGIN IMMEDIATE` on the main handle, no app lock).
- Cross-connection waits for the SQLite **file write lock** (WAL allows one writer) happen inside the busy handler of whichever connection loses: today that is invisible except as a long `begin`/`insert`/`commit` step, or a `busy_total` increment if it exceeds 5 s.

### 1.5 Request context and threads

- Thread-per-connection: `thread.run_with_poly_data3(… handle_client_thread)` (`transport/http/server.odin:53,57`). One plain HTTP request = one thread for its whole dispatch (`:59-145`), so a **thread-local** is a valid per-request scope for plain dispatch.
- There is **no request context object** carried into services/repositories. `Request.request_id` comes from the client `X-Request-Id` or the constant `req_local` (`server.odin:89-90`) — not unique, client-controlled.
- WebSocket and raw-upgrade routes run on the same thread for the connection lifetime (`server.odin:116-135`) and are outside the HTTP timer; their DB calls (e.g. bridge heartbeats) are currently attributable to nothing.
- Background threads touching the DB (non-exhaustive): taskv2 timers `service/taskv2/timers.odin:456`, merge jobs `service/taskv2/merge.odin:102`, bridge-log writer `service/bridge_log/bridge_log_service.odin:185`, shell kill replay `service/shell_session/shell_session_service.odin:1229`, metrics scrape (`app/metrics_db_collectors.odin:122-133`).

### 1.5a Service mutexes held around repository calls (audit)

**Method:** `git grep -n 'mutex_lock\|sync.lock(\|sync.guard(' origin/main -- src/hub/service src/hub/app src/hub/transport` (144 non-test sites in 30 files). A script walked each critical section (to the matching unlock, or to the end of the enclosing block for `defer` unlocks) and flagged direct `iface.*`, `*_repo`, `repository.`, `sqlite.` or UoW calls. Sites without a direct hit were read by hand for helper calls that reach a repository. Three service locks are **held across DB work**; they join the `lock` enum (§2.2):

| `lock` value | Mutex (declared) | Held across DB at | DB work inside | Notes |
|---|---|---|---|---|
| `projector` | `Card_Service.projector_mutex` (`service/card/card_service.odin:292`) | `service/card/card_projector.odin:115-116`, `:367-368`, `:458-459` (all `defer` unlock) | `iface.taskchain_get_task` `:118`, `iface.attention_latest_actionable_message` `:370`, `iface.content_get_memory` `:461`, then compare-and-set card writes (caller holds it, `:562`) | Exists *because* the shared connection cannot give per-thread transactions (`card_projector.odin:31-38`); reader-pool plan B2 names it. One process-wide lock serialises every card projection. |
| `reconfig` | `Agent_Service.reconfiguration_mutex` (`service/agent/agent_service.odin:20`) | `agent_service.odin:773-774` (`stop_instance`), `:1021-1022` (`reconfigure_instance`), `:1040-1041` (`relaunch_instance`); `service/agent/instance_reconfiguration.odin:119-120`, `:209-210`, `:279-280`, `:342-343` | `iface.agent_get_instance` / `agent_save_instance` (`agent_service.odin:788,794,801,1036,1047`), `iface.instance_reconfiguration_get/begin/list` (`instance_reconfiguration.odin:122,133,211,281,347,368`), `iface.bridge_get_bridge` (`agent_service.odin:1053`) | One process-wide lock. Hold also covers a bridge command send in `relaunch_instance_locked` (`bridge_command_send_runtime`, `agent_service.odin:1075`) — non-DB time inside the hold, which is why hold is never added to wait/exec (§2.1). |
| `launch_prefs` | `User_Service.launch_preferences_mutex` (`service/user/user_service.odin:10`) | `service/user/conversation_launch_preferences.odin:52` (`set_launch_selection`), `:88` (`set_agent_favorite`); `user_service.odin:143-145`; `transport/http/agent_handlers.odin:65-66` | `iface.agent_get` / `project_get` / `bridge_get_bridge` (`conversation_launch_preferences.odin:60,68,75,94`), `iface.launch_preferences_save` (`:48`) and the read helper | Per-service (process-wide). Low rate; included because it is cheap and closes the inventory. |

**Excluded (in-memory or released before DB work), with reason:**

| Mutex | Sites | Why excluded |
|---|---|---|
| taskv2 `svc.state_mutex` | `service/taskv2/lease.odin:421,434,798,809` | only map updates; `drain_pending_touches` swaps the set out and runs the UoWs **after** unlock (`lease.odin:433-444`, unlock `:437`, UoW loop `:439-442`, comment `:430-432`) |
| taskv2 `timers.mutex` / `ts.mutex` | `service/taskv2/timers.odin:73,90,100` | in-memory heap only |
| bridge-log `svc.mu` | `service/bridge_log/bridge_log_service.odin:71,84,95,105,155,190,205` | queue swap; `bridge_log_insert_batch` (`:119`) and `bridge_log_delete_by_bridge` (`:166`) run after unlock (`:113`, `:165`) |
| `events` bus / write mutexes, attention debouncer | `service/events/event_bus.odin`, `attention_debouncer.odin` | in-memory fan-out / socket writes |
| device-auth `store.mutex` | `service/device_auth/service.odin:159,249,307,528,640`, `grant_store.odin` | in-memory grant store and rate limits |
| vault nonce cache `c.mutex` | `service/vault_directory/service.odin:95,108,130` | in-memory map (the vault *repo* `impl.mutex` is already in §1.1) |
| provider `test_mutex` | `service/provider/provider_service.odin:95,116,126,144,165,182` | in-memory test-run registry, no repo call in any section |
| shell-session / pane-viewer / snapshot / tunnel mutexes | `service/shell_session/*.odin` | in-memory state and stream writes |
| bridge runtime / registry writer, metadata, quota, command mutexes | `service/bridge_runtime/*.odin`, `service/project/runtime_registry.odin`, `runtime_metrics.odin` | socket writes and in-memory registries |
| transport registries (`action_handlers.odin:39,49` bridge versions, `user_handlers.odin:202,219` WS tickets, LSP, proxy, enroll hellos, lifecycle-log limiter, shell controls) | `transport/http/*.odin` | in-memory maps |
| agent bootstrap / hub-fragment caches | `service/agent/agent_service.odin` (`global_*_cache.lock`) | in-memory caches |

- **Audit limit:** the scan is textual. A helper that reaches a repository through more than one indirection could be missed. The safety net is the per-request record (§3): a slow request whose DB components plus app-lock waits are small, yet whose duration is large, flags unmeasured time. The implementation task must re-run the grep at its base commit and update the enum when a new lock appears (enforced by `test_lock_inventory`, §4.3).
- **Side observation (out of scope; routed to the coordinator/user, no change here):** at `transport/http/agent_handlers.odin:65-66` the `defer unlock` sits inside the `if` block, so the lock is released at `:70` before `set_agent_favorite_locked` runs at `:75`. The "≤ 6 favorites" check and the save are therefore not atomic under concurrent creates.

### 1.6 Gaps (what cannot be answered today)

| # | Gap | Consequence |
|---|---|---|
| G1 | Conn-mutex wait and execution share one timer; `step_changes` wait untimed | cannot tell queueing from query cost |
| G2 | No connection label | billing/vault/enroll/metrics steps mix with main |
| G3 | prepare/bind/column/reset/finalize untimed | conn hold time and waits under-counted; prepare cost (no stmt cache) unknown |
| G4 | No `tx_mutex` wait/hold, no dedicated-mutex wait/hold, no service-lock (`projector`, `reconfig`, `launch_prefs`, §1.5a) wait/hold, no tx duration/outcome | writer and projection serialisation invisible |
| G5 | Successful busy waits invisible; BUSY vs BUSY_SNAPSHOT not distinguished | file write-lock contention between the 5 handles invisible below 5 s |
| G6 | No per-request DB accounting, no slow-request record | cannot say what share of a slow request was DB |
| G7 | HTTP buckets start at 10 ms | ms-scale queueing invisible in quantiles |
| G8 | No IO/cache-miss signal per connection | cannot separate IO from CPU inside a step |
| G9 | `sqlite3_libversion()` never logged | WAL-reset bug exposure (review F3) unknown in prod |
| G10 | Per-step `metrics.with` lookup | avoidable overhead that new metrics would multiply |

---

## 2. REQ-DBT-2: Instrumentation design

### 2.1 Definitions (disjoint intervals on one thread)

For one thread, the following intervals never overlap, so their **sums** may be added and compared with the request duration sum:

1. `app_lock_wait` — waiting for an application mutex that guards DB work: `tx_mutex` (outer begin only), billing `impl.mutex`, vault `impl.mutex`, enroll `commit.mutex`, collector `db_collectors.mu`, and the service locks `projector_mutex`, `reconfiguration_mutex`, `launch_preferences_mutex` (§1.5a).
2. `conn_wait` — waiting for the SQLite connection mutex (`sqlite3_db_mutex`) before an API call.
3. `exec` — inside SQLite with the connection mutex held: VM work, page-cache misses (IO), WAL append, and busy-handler sleeps.
   - `busy_wait` ⊂ `exec` (phase 2 only, §2.6).
4. Everything else in the request is non-DB.

**Emitted components are disjoint:** the per-scope / per-route counters (§2.2 `component`) record `app_lock_wait`, `conn_wait`, `exec_excl_busy` and `busy_wait`, where the step wrapper computes `exec_excl_busy = exec − busy_wait` **per call** from the same call's two measurements (a sum of the same event, never a percentile). Until phase 2, `busy_wait` is 0 and `exec_excl_busy` = `exec`. The four may be stacked and summed. The `heimdall_sqlite_exec_seconds` histogram keeps the **total** exec per call (busy included), because it describes calls, not a time budget.

Wait intervals stay disjoint even when locks nest on one thread (for example `reconfig` held while that thread later waits for `conn_main`): a thread waits for one lock at a time, so its waits are sequential.

`hold` metrics (tx hold, app-lock hold) **contain** 2 and 3 of the holder, plus any non-DB work done under the lock (for example the bridge send under `reconfig`, §1.5a). They are reported as separate families and are never added to 1–3.

### 2.2 Metric families (all new; existing families kept unchanged for continuity)

Label enums (fixed, compile-time):
- `conn` ∈ `main, billing, enroll, vault, metrics, other` (`other` = tests / unregistered handle). Derivation in §2.3.0.
- `lock` ∈ `uow_tx, billing, vault, enroll, collector, projector, reconfig, launch_prefs, conn_main, conn_billing, conn_enroll, conn_vault, conn_metrics` (13 values: 8 app locks and 5 connection mutexes).
- `op` = existing `sqlite_op_from_sql` enum (`select insert update delete begin commit rollback pragma create other`) plus `prepare`, `finalize` for the API-call kind.
- `rw` ∈ `read, write, tx, other` derived from `op` (select→read; insert/update/delete→write; begin/commit/rollback→tx; rest→other). For units of work: `rw` ∈ `read, write` = "did this UoW execute any write step" (thread-local flag set by the step wrapper while the thread owns `tx_mutex`).
- `outcome` ∈ `commit, rollback, commit_failed, begin_failed`.
- `scope` ∈ `http, ws, timer, merge, bridge_log, shell, scrape, other`.
- `code` ∈ `busy, busy_snapshot, locked, constraint, corrupt, ioerr, other` (primary/extended code mapped; needs `sqlite3_extended_errcode` FFI).
- `component` ∈ `app_lock_wait, conn_wait, exec_excl_busy, busy_wait` (disjoint, §2.1).

| Family | Type | Labels | Buckets (s) | Observed at |
|---|---|---|---|---|
| `heimdall_db_lock_wait_seconds` | histogram | `lock` | W: 1e-6, 1e-5, 5e-5, 1e-4, 2.5e-4, 5e-4, 1e-3, 2.5e-3, 5e-3, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5 | after each timed acquisition (incl. failed `BEGIN` after `tx_mutex`) |
| `heimdall_db_lock_hold_seconds` | histogram | `lock` (app locks + `uow_tx`; conn locks use `exec`) | H: 1e-4, 5e-4, 1e-3, 2.5e-3, 5e-3, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30 | at release (defer) |
| `heimdall_db_lock_waiters` | gauge | `lock` | — | `+1` before acquire, `−1` after (instantaneous; **sampled** at scrape) |
| `heimdall_db_lock_waiters_max` | gauge (scrape collector) | `lock` | — | high-water mark of `waiters` since the previous scrape: after each `+1` a CAS loop raises a per-lock atomic max; the collector reads it with `atomic_exchange(…, current waiters)`, so it resets to the current depth on every scrape |
| `heimdall_db_lock_contended_total` | counter | `lock` | — | acquisitions whose try-lock failed (the lock was held by another thread), §2.3.1; the share of contended acquisitions does not depend on scrape timing |
| `heimdall_db_lock_held` | gauge | `lock` (app locks) | — | 1 while held |
| `heimdall_db_uow_oldest_hold_seconds` | gauge (scrape collector) | — | — | `now − acquired_at` of the open outer UoW, 0 if none (catches a stuck UoW whose hold never gets observed) |
| `heimdall_sqlite_exec_seconds` | histogram | `conn, op` | E: 2.5e-5, 5e-5, 1e-4, 2.5e-4, 5e-4, 1e-3, 2.5e-3, 5e-3, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 5 | each wrapped API call, mutex held |
| `heimdall_sqlite_statements_total` | counter | `conn, op` | — | at the **first step of each execution**: the step wrapper increments it when `sqlite3_stmt_busy(stmt) == 0` before `step_raw`, which is true right after prepare, after `sqlite3_reset`, and after a previous run returned `SQLITE_DONE` (auto-reset). Reused statements (`fts_repair.odin:124` reset + re-step) therefore count once per execution. Each `sqlite3_exec` call counts 1 under its first-keyword `op`. Existing `query_duration_count` keeps counting step calls. |
| `heimdall_sqlite_vm_steps_total`, `heimdall_sqlite_fullscan_steps_total`, `heimdall_sqlite_sort_total` | counters | `conn, op` | — | `sqlite3_stmt_status(…, reset=1)` read in the step wrapper right after each `step_raw`, while the conn mutex is still held: the delta of that step. Query **cost** independent of waits/IO. Reading per step (not at finalize) puts the cost on the same call as its `exec` time and its `site` (§2.2a), and stays correct across `sqlite3_reset` and reuse. |
| `heimdall_sqlite_site_exec_seconds_total`, `heimdall_sqlite_site_vm_steps_total`, `heimdall_sqlite_site_fullscan_steps_total` | counters | `conn, site` | — | step wrapper, per step call: the call's total exec time and the same `stmt_status` deltas as the row above. See §2.2a. |
| `heimdall_sqlite_errors_total` | counter | `conn, op, code` | — | non-OK/ROW/DONE rc |
| `heimdall_db_tx_duration_seconds` | histogram | `conn, kind (uow, billing, vault, enroll, fts_repair), rw, outcome` | H | outer BEGIN start → COMMIT/ROLLBACK return (excludes after-commit hooks, `tx.odin:176-178`) |
| `heimdall_sqlite_cache_events_total` | counter (scrape collector) | `conn, kind (hit, miss, write, spill)` | — | `sqlite3_db_status(SQLITE_DBSTATUS_CACHE_*, reset=0)` per handle at scrape → IO proxy |
| `heimdall_db_scope_seconds_total` | counter | `scope, component` | — | thread-local scope totals flushed at scope end |
| `heimdall_http_request_db_seconds_total` | counter | `route, component` | — | flushed at `server.odin:143` next to `http_metrics_observe` |
| `heimdall_db_slow_log_dropped_total` | counter | `reason` (`slow, sample`) | — | slow/sample records dropped by the §3 token bucket |
| `heimdall_sqlite_library_info` | gauge=1 | `version` (one value per process) | — | boot (`sqlite3_libversion`) — closes G9 |

- **Cardinality** (series are created lazily). A histogram labelset exposes its buckets plus `+Inf`, `_sum` and `_count`, so W (18 buckets) = 21 series, H (16) = 19, E (16) = 19:
  - wait: 13 locks × 21 = 273
  - hold: 8 app locks (`uow_tx` *is* `tx_mutex`) × 19 = 152
  - waiters / waiters_max / contended: 3 × 13 = 39; held 8; oldest-hold 1
  - exec: 6 conn × 12 op × 19 = 1 368 worst; ~40 live `(conn,op)` pairs × 19 ≈ 760
  - tx: 5 kinds × 2 rw × 4 outcome × 19 = 760 worst; ~8 live labelsets × 19 ≈ 150
  - `(conn,op)` and `(scope,component)` counters (statements, vm/fullscan/sort, errors, cache, scope): < 300
  - `http_request_db`: routes (~150 patterns, already bounded by `metrics_http.odin:14`) × 4 components ≈ 600
  - site counters (§2.2a): 3 families × ≤ 261 sites ≈ 783 worst; only exercised sites appear
  - **Total:** ≈ 3 100 realistic, ≈ 4 500 worst case. Budget: ≤ 5 000 new series, checked by the post-deploy `curl … | grep -c` (§4.3).
- No SQL text, parameter, path, user, task or request id is ever a label value. `site` is a compile-time source location (§2.2a), not query text.
- **Buckets:** lock wait starts at 1 µs because an uncontended mutex is ~50–200 ns and the question is "how often > 1 ms"; tops at 5 s = `busy_timeout`. Exec starts at 25 µs (most indexed point reads), resolves the 1–10 ms band the HTTP histogram cannot. Hold/tx reach 30 s to catch pathological units of work.
- **HTTP buckets (G7):** add `0.001, 0.0025, 0.005` to `HTTP_DURATION_BUCKETS` in the same release. Adding `le` series is additive, but `histogram_quantile` must not span the deploy boundary (state this on the dashboard).

### 2.2a Statement attribution without query ids (`site` label)

R5 (§5.2) asks which statements dominate main-connection time. `{conn,op}` cannot answer that, and the slow-request record is sampled. So step calls also carry a bounded **call-site** label.

- **Value:** `site = "<file basename>:<procedure>"` of the code that called the step, e.g. `task_repo_sqlite.odin:task_get_by_id`. It comes from `loc := #caller_location` (Odin `runtime.Source_Code_Location`: `file_path`, `procedure`, `line`). The value is source code identity, never SQL text, parameters or ids.
  - Procedure rather than line: line numbers move with every edit, which would churn series across releases and break before/after comparisons. Several statements in one procedure share a site. The slow-request record (§3) still carries `file:line` for the finer split.
- **Bound:** the set of call sites is fixed at compile time. At `2a467a5a`, `git grep -nP` over non-test `repository/sqlite/*.odin` finds 217 `sqlite3_step(` calls (3 of them inside the two helpers below), 41 `step_changes(` calls and 6 `step_write_healing(` calls. That gives ≤ 261 attributed sites, fewer once grouped by procedure. A further 8 `sqlite3_step(`/`exec(` calls sit outside the package (collector and others).
- **Only step calls carry a site.** The 160 `exec(`/`sqlite3_exec` calls are BEGIN/COMMIT/ROLLBACK/SAVEPOINT, pragmas and DDL. All of them go through the one `exec` helper (`conn.odin:99-112`), so the site would collapse to `conn.odin:exec` anyway. Their cost stays visible under `op`.
- **Helper collapse (must be fixed, or the helpers swallow 47 sites):** `step_changes` (`conn.odin:123-130`, step at `:127`) and `step_write_healing` (`fts_repair.odin:120-128`, steps at `:121` and `:125`) call the wrapper themselves. Without changes their `#caller_location` would be the helper's own line. Both gain a trailing `loc := #caller_location` parameter and pass it explicitly to `sqlite3_step(stmt, loc)`. Their callers do not change, and the retry step in `step_write_healing` is charged to the same caller site.
- **Mechanism:** the step wrapper becomes `sqlite3_step :: proc(pStmt, loc := #caller_location)`. No call site changes, since no code uses `sqlite3_step` as a proc value; the only non-call references are the `link_name` at `conn.odin:38` and comments. It resolves `loc` to a series slot through a fixed 512-entry open-addressed table keyed by `(raw_data(loc.file_path), loc.procedure data pointer)`. Both are static strings with stable addresses.
  - Lookup: lock-free atomic loads. Insert: once per site, under a cold mutex, and builds the label string then.
  - If the table fills (impossible with ≤ 261 sites), the call goes to `site="overflow"`. A test asserts that production never produces it.
- **Per step:** add the call's total exec ns to `site_exec_seconds_total{conn,site}` and the `VM_STEP` / `FULLSCAN_STEP` deltas (`sqlite3_stmt_status(…, reset=1)`, read inside the held mutex) to the site counters and to the `{conn,op}` counters.
- **What it answers:** the share of main step time taken by the top-k sites (`topk` query, §4.5). It also gives sites ranked by full-scan steps, and mean cost per site.
  - The site counters cover **step calls only**, so R5 uses their own sum as denominator, not `exec_seconds_sum`, which also contains prepare/finalize/exec.
  - Counters, not histograms: R5 needs time shares (ratios of sums), not per-site quantiles. That keeps the series count at 3 per site.

### 2.3 Where each timer goes (implementation guidance, not code)

0. **Connection tagging (`conn` label).** All five handles come from one `sqlite.open(path)` (`repository/sqlite/conn.odin:68`), and the step wrapper sees only a statement or db pointer, so the kind must be recorded at open:
   - Add `Conn_Kind :: enum u8 {Main, Billing, Enroll, Vault, Metrics, Other}` and an optional parameter `open :: proc(path: string, kind := Conn_Kind.Other)`. The five production call sites pass their kind: `app/wiring.odin:233` `.Main`, `repository/sqlite/billing_repo_sqlite.odin:43` `.Billing`, `bridge_repo_sqlite.odin:31` `.Enroll`, `vault_directory_repo_sqlite.odin:35` `.Vault`, `app/metrics_db_collectors.odin:91` `.Metrics`. Tests keep the default `.Other`.
   - `open` registers `(db pointer, kind)` in a fixed table `conn_slots: [16]Conn_Slot` (`{db: atomic rawptr, kind: Conn_Kind}`). Registration takes a cold-path mutex and fills a free slot. If the table is full (only possible in tests), the handle stays unregistered and gets `kind = .Other` with no slot. `close` (`conn.odin:89-97`) clears the slot **before** `sqlite3_close`, so a reused pointer value is never mis-tagged.
   - Hot-path lookup: `slot_of(db)` is a linear scan of ≤ 16 atomic pointer loads (≈ 5–10 ns; production holds 5). It needs no map and no lock.
   - Thread-local nesting depth is a fixed array indexed by slot: `tl.conn_depth: [16]u16`. It is not keyed by kind, so two `.Other` test handles never share a counter. An unregistered handle (no slot) gets exec-only timing with no `conn_wait` split, as in the NULL-mutex case below.
1. **Step/exec/prepare/finalize wrapper** (extend `sqlite_metrics.odin:72-84`, bind `prepare_v2`/`finalize` as `*_raw` the same way `conn.odin:38-42` does):
   ```text
   db   := sqlite3_db_handle(stmt)            // new FFI; exec/prepare already have db
   s    := slot_of(db) ; conn := conn_slots[s].kind
   m    := sqlite3_db_mutex(db)
   entered := false
   if m != nil && s valid && tl.conn_depth[s] == 0:      // not already held by this thread (step_changes)
       t0 := tick
       if sqlite3_mutex_try(m) != SQLITE_OK:             // held by another thread
           contended[conn_<conn>]++ ; waiters[conn]++ ; raise waiters_max[conn]
           sqlite3_mutex_enter(m) ; waiters[conn]--
       t1 := tick ; entered = true
       observe lock_wait{conn_<conn>} (t1-t0) ; tl.conn_wait += t1-t0
   if s valid: tl.conn_depth[s]++
   if is_step && sqlite3_stmt_busy(stmt) == 0: statements{conn,op}++   // first step of an execution
   t1' := tick ; rc := step_raw(stmt) ; t2 := tick
   vm := sqlite3_stmt_status(stmt, VM_STEP, 1) ; fs := sqlite3_stmt_status(stmt, FULLSCAN_STEP, 1)   // + SORT for sort_total; step only
   busy := tl.busy_ns_this_call (phase 2, else 0)
   observe exec{conn,op}(t2-t1') ; tl.exec_excl_busy += (t2-t1') - busy ; tl.busy_wait += busy
   site := site_slot(loc)                     // step only, §2.2a
   site_exec[conn,site] += t2-t1' ; site_vm[conn,site] += vm ; site_fs[conn,site] += fs ; vm_steps{conn,op} += vm …
   if s valid: tl.conn_depth[s]-- ; if entered: sqlite3_mutex_leave(m)
   ```
   - SQLite's connection mutex is recursive, so the inner `step_raw` re-enter is uncontended and the measured split is exact.
   - `sqlite3_mutex_try` on the default unix (pthreads) mutex returns `SQLITE_OK` when it acquires the lock. It returns `SQLITE_BUSY` when another thread holds the lock, and on systems that lack try-lock it always returns `SQLITE_BUSY` (sqlite.org `c3ref/mutex_alloc.html`). On such a system `contended_total` would over-count, but the wait timings stay correct. Dawnstar is Linux/pthreads.
   - `step_changes` (`conn.odin:123-130`) becomes the timed acquisition for its pair, using the same try/enter sequence. The inner wrapper sees `conn_depth > 0` and records no second wait (**no double counting**).
   - `sqlite3_db_mutex` returns NULL in non-serialized builds (`conn.odin:121-122`): then skip the wait timer and record exec only.
   - bind/column/reset calls stay unwrapped (one call per column per row would cost more than it tells); their wait is bounded by the step that precedes them. Document this as residual G3.
2. **Units of work** (`tx.odin`): timestamp before `mutex_lock` (`:98`) → wait; `acquired_at` stored in a file-private atomic; hold and tx duration observed at the outer release (`:175` commit, rollback path) **and** on the BEGIN-failure path (`:99-101`, outcome `begin_failed`, hold observed too since the mutex was held). Nested savepoints (`:84-96`) record nothing but a `heimdall_db_uow_nested_total` counter, so a nested UoW is never a second tx observation.
3. **Dedicated repo mutexes and service locks**: a small `timed_lock(&mu, lock_id)` / `timed_unlock` helper (it tries `sync.mutex_try_lock` first, then follows the same contended/waiters/max/wait sequence as above) used at the cited `mutex_lock` sites: §1.1 billing/vault/enroll/collector, and §1.5a `projector` (`card_projector.odin:115,367,458`), `reconfig` (`agent_service.odin:773,1021,1040`, `instance_reconfiguration.odin:119,209,279,342`) and `launch_prefs` (`conversation_launch_preferences.odin:52,88`, `user_service.odin:143`, `agent_handlers.odin:65`). `defer timed_unlock` keeps hold observation on every early return. The helper lives in a small leaf package (e.g. `src/hub/platform/dbtelemetry`) so service packages need not import `repository/sqlite`.
4. **Request scope**: `db_scope_begin(.http)` immediately before `server.odin:141`, `db_scope_end` right after `:143`, then add the four components to `heimdall_http_request_db_seconds_total{route,component}` with the same `route` label as `http_metrics_observe`. WS / raw routes call `db_scope_begin(.ws)` around each received frame's handler; background loops wrap one iteration (`.timer`, `.merge`, `.bridge_log`, `.shell`), and the collector wraps a scrape (`.scrape`). Calls outside any scope accumulate into `scope=other`, so nothing is silently dropped.

### 2.4 Semantics for errors, nesting, cancellation, concurrency

- **Errors:** wait and exec are observed regardless of `rc`; `rc` additionally increments `heimdall_sqlite_errors_total{code}`. A failed `BEGIN`/`COMMIT` produces a tx observation with `begin_failed`/`commit_failed` and its hold.
- **Nested paths:** savepoints (counter only); `step_changes` (single wait); re-entrant scope (`db_scope_begin` while a scope is open increments depth and only the outermost flushes).
- **Cancellation:** the hub has no request cancellation; a client disconnect does not stop the handler, so its DB time is still recorded. Panics abort the process (no partial-state problem). Early returns are covered by `defer`.
- **Background work:** never attributed to HTTP; separate `scope`. After-commit hooks run outside the tx timer (`tx.odin:176-178`) and inside the caller's scope.
- **Concurrency:** histograms and gauges are atomics (`src/lib/metrics/metrics.odin:344-375`); per-request accumulators are thread-local; `acquired_at` for the oldest-hold gauge is one atomic i64 written only by the `tx_mutex` owner.
- **Series lookup:** resolve every `(family, labels)` series pointer once at init into fixed arrays indexed by enum (`[Conn][Op]^Series`), so the hot path never calls `metrics.with` (fixes G10 for both old and new families).

### 2.5 Separating the four causes

| Question | Signal |
|---|---|
| App mutex waits (serialisation we impose) | `lock_wait{lock=uow_tx|billing|vault|enroll|collector|projector|reconfig|launch_prefs}` |
| SQLite connection queueing (what a reader pool would remove) | `lock_wait{lock=conn_main}` + `contended_total{conn_main}` / `lock_wait_count` + `waiters_max{conn_main}` + main-conn utilisation `rate(exec_seconds_sum{conn="main"})` |
| SQLite internal busy waiting (file write lock across the 5 handles) | phase 2 `busy_wait`; phase 1 proxy: `exec{op=begin}` on `BEGIN IMMEDIATE` connections and `exec{op=insert|update|delete|commit}` tails on `main` with `errors{code=busy*}` |
| Query cost | `vm_steps_total`, `fullscan_steps_total`, `sort_total` per statement (`/ statements_total`) and `exec{op=select}`; per call site `site_exec_seconds_total`, `site_vm_steps_total`, `site_fullscan_steps_total` (§2.2a) |
| IO | `cache_events{kind=miss|write|spill}` per conn, `exec{op=commit}` (WAL append; `synchronous=NORMAL` → no fsync per commit), `wal_bytes`, host `node_disk_*` |

### 2.6 Busy-handler instrumentation: assessment

- The binding has no `sqlite3_busy_handler` or `sqlite3_sleep` (`conn.odin:28-61`); adding them is a small FFI change.
- sqlite.org `c3ref/busy_handler.html`: a connection has exactly one busy handler, and `PRAGMA busy_timeout` / `sqlite3_busy_timeout` replace it. Installing a counting handler therefore **removes** the default timeout behaviour unless the handler re-implements it (`app/wiring.odin:237`, billing `:46`, enroll `:34`, vault `:38`, collector `:94`).
- Preserving behaviour is possible: the handler is called with the retry count, so it can reproduce SQLite's default schedule (sleeps of 1, 2, 5, 10, 15, 20, 25, 25, 25, 50, 50, 100 ms … capped at the configured total, from `sqliteDefaultBusyCallback` in SQLite source — source behaviour, not documented API) and return 0 once the total reaches the connection's timeout. It must use `sqlite3_sleep`, run without allocating, and be installed **after** the busy_timeout pragma.
- Risk: any divergence changes production wait behaviour (fairness, latency under contention), and the docs allow SQLite to skip the handler on deadlock risk, so counts are a lower bound.
- **Decision:** phase 1 does **not** install a busy handler. Phase 2 (only if phase-1 data shows unexplained write-path `exec` tails or `busy*` errors) adds an opt-in handler behind `HEIMDALL_DB_TELEMETRY=full`, with a unit test that asserts the same total-timeout behaviour as the pragma (two connections, one holding `BEGIN IMMEDIATE`, measured give-up time within ±10 % of the configured timeout). Gap documented: until then, successful busy waits are only visible as `exec` time on write/tx ops.

---

## 3. REQ-DBT-3: Sampled slow-request correlation

- **Per-request record (thread-local, §2.3.4):** `request_ns`, `app_lock_wait_ns` by lock, `conn_wait_ns`, `exec_ns`, `busy_wait_ns` (phase 2), `steps`, `statements`, `tx_count`, `tx_hold_ns` (overlapping, labelled as such), `busy_errors`, and the top 3 slowest API calls as `(conn, op, exec_ns, wait_ns, source location)`.
  - Source location: give the wrappers a trailing `loc := #caller_location` parameter. Call sites are unchanged; the record names `repository/sqlite/<file>.odin:<line>`, never SQL text or parameters.
- **When emitted:** `request_ns ≥ HEIMDALL_DB_SLOW_MS` (default 250 ms) **or** a 1-in-`HEIMDALL_DB_SAMPLE_N` random sample (default 1000) so typical requests have a baseline; rate-limited by a token bucket (≤ 10 lines/s).
  - Each line carries `reason=slow|sample`. A request that is both over the threshold and sampled is `slow`. Criteria about slow requests (S4, R4) use `reason=slow` only. `sample` lines are the unbiased baseline and are never mixed into slow-request shares.
  - The token bucket drops lines under bursts. Each record has a `dropped_since_last` count, and `heimdall_db_slow_log_dropped_total{reason}` counts drops, so any S4/R4 sample states its drop rate.
- **Format:** one structured log line `db_slow_request` with route pattern, method, status class, `reason`, the fields above, and `request_id` truncated to 64 bytes (client-supplied, so it is only a correlation hint, never a metric label). No body, query string, path parameters, user or agent identifiers.
- **Aggregate correlation (metrics, not logs):** `heimdall_http_request_db_seconds_total{route,component}` together with the existing `heimdall_http_request_duration_seconds_sum{route}` gives, per route, the share of request time spent in each component as a **ratio of sums**. Percentiles of components and of request duration are independent distributions and are **never subtracted or added**.
- **Background scopes** get the same slow record (`db_slow_scope`) with threshold 1 s, so a timer pass holding `uow_tx` for seconds is visible even with no HTTP request involved.

---

## 4. REQ-DBT-4: Overhead, disabling, validation, rollout, queries

### 4.1 Overhead budget

- Per wrapped API call in `basic` mode: 3 monotonic ticks, one uncontended recursive mutex enter/leave, two histogram observes with pre-resolved series, thread-local adds. Step calls add 2 `stmt_status` reads (array reads under the mutex this thread already holds), the `site_slot` lookup and 3 atomic counter adds. Target: **≤ 300 ns per call**.
  - **These per-operation figures are estimates, not measurements** from this source or this host. Typical published values: a vDSO clock read ~20–30 ns, an uncontended mutex ~40 ns, an atomic add ~5–20 ns.
  - **The gate is the §4.3 wrapper microbenchmark.** The implementation does not ship `basic` as the default unless that benchmark shows `basic − off` ≤ 300 ns/call for both step and prepare on Dawnstar-class hardware. If it fails, the site counters and `stmt_status` reads move to `full` first.
  - Removing today's per-step `metrics.with` lookup (G10) offsets part of the cost.
- Dawnstar volume (POST window, `task_18e098a27772ef68`): ~467 k `query_duration_count{op="select"}` / 120 min ≈ 65 **select steps/s** (step calls, §1.3, not statements); even at 20 wrapped API calls per step ≈ 1 300 calls/s × 300 ns ≈ 0.4 ms/s = **0.04 % of one core**. Budget: **≤ 0.5 % hub CPU and ≤ 2 MB RSS** for all new families; slow-log ≤ 10 lines/s.
- `stmt_status` reads: 3 per step (VM_STEP, FULLSCAN_STEP, SORT; only the first two feed the site counters). Each is a counter read under an already-held recursive mutex, so the cost is included in the microbenchmark. `sqlite3_stmt_busy` per step and the ≤ 16-slot `slot_of` scan add roughly 10–15 ns per call, within the 300 ns budget. An uncontended try-lock costs the same as the enter it replaces. The `waiters_max` CAS runs only on contended acquisitions. `db_status` reads per scrape: 4 per connection.

### 4.2 Disabling behaviour

- `HEIMDALL_DB_TELEMETRY = off | basic | full` (default `basic` after canary; `off` for the first deploy), read once at boot into a global enum.
  - `off`: wrappers behave exactly as today (no extra mutex enter, no new families registered; existing `query_duration`/`busy_total` unchanged).
  - `basic`: everything in §2 except the busy handler.
  - `full`: adds the phase-2 busy handler.
- `HEIMDALL_DB_SLOW_MS` (0 disables slow log), `HEIMDALL_DB_SAMPLE_N` (0 disables sampling).
- Changing any of these needs a restart; that is a production change the operator schedules, not something this telemetry does.

### 4.3 Validation (for the implementation task; not run in this plan task)

Scoped commands, following the repo convention (tests built inside `nix develop`, binaries under `$HOME/.cache/heimdall-tests`, single tests via `ODIN_TEST_NAMES`):

```bash
cd /home/tanmay/hamwt/<impl-worktree>
nix develop -c odin build src/hub/repository/sqlite -build-mode:test -collection:odin_test=src \
  -define:ODIN_TEST_NAMES=sqlite.test_db_conn_wait_split,sqlite.test_step_changes_single_wait,sqlite.test_uow_wait_hold_outcomes,sqlite.test_uow_nested_no_double_count,sqlite.test_dedicated_mutex_timed,sqlite.test_telemetry_off_is_passthrough,sqlite.test_labels_bounded,sqlite.test_stmt_status_counters,sqlite.test_conn_kind_tagging,sqlite.test_statement_count_reuse,sqlite.test_waiters_max_scrape_reset,sqlite.test_site_attribution \
  -out:$HOME/.cache/heimdall-tests/sqlite_dbt && nix develop -c $HOME/.cache/heimdall-tests/sqlite_dbt
nix develop -c odin build src/hub/service/card -build-mode:test -collection:odin_test=src \
  -define:ODIN_TEST_NAMES=card.test_projector_lock_timed \
  -out:$HOME/.cache/heimdall-tests/card_dbt && nix develop -c $HOME/.cache/heimdall-tests/card_dbt
nix develop -c odin build src/hub/transport/http -build-mode:test -collection:odin_test=src \
  -define:ODIN_TEST_NAMES=http.test_request_db_scope_flush,http.test_slow_request_log_sanitized \
  -out:$HOME/.cache/heimdall-tests/http_dbt && nix develop -c $HOME/.cache/heimdall-tests/http_dbt
```

What each test must prove:
- `conn_wait_split`: thread A holds `sqlite3_db_mutex` for a fixed 50 ms behind a barrier; thread B's step records `conn_wait ≥ 45 ms` and `exec < 10 ms`.
- `step_changes_single_wait`: one `step_changes` → exactly one `lock_wait{conn_main}` observation.
- `uow_wait_hold_outcomes`: commit, rollback, BEGIN failure, COMMIT failure each yield one tx observation with the right `outcome`; `waiters`/`held` gauges return to 0.
- `uow_nested_no_double_count`: outer + 2 savepoints → 1 tx, 1 hold, 2 nested counter.
- `telemetry_off_is_passthrough`: `off` registers no new families and makes no extra mutex call.
- `labels_bounded`: random SQL prefixes and comments only ever produce enum values.
- `conn_kind_tagging`: handles opened with each `Conn_Kind` are labelled correctly; close-then-reopen (same pointer value possible) never keeps the old kind; a 17th handle is `other` and gets exec-only timing.
- `statement_count_reuse`: prepare → step to DONE → reset → step to DONE → finalize gives `statements_total` = 2, and a multi-row SELECT stepped 5 times gives 1; the `step_write_healing` reset path (`fts_repair.odin:120-126`) counts the retry as a second execution.
- `waiters_max_scrape_reset`: 3 threads queued behind a held lock raise `waiters_max` to 3 (with `contended_total` +3), even though `waiters` is back to 0 at scrape time; the next scrape with no contention reads 0.
- `site_attribution`: steps called directly, through `step_changes` and through `step_write_healing` (including the CORRUPT-retry path) are all charged to the **calling** procedure's site, never `conn.odin:step_changes` or `fts_repair.odin:step_write_healing`. A full-scan SELECT on an unindexed table raises `site_fullscan_steps_total` for its site only. Per-step `site_vm_steps` deltas over one execution equal the statement's cumulative `VM_STEP`. No `site="overflow"` appears after exercising every repository test fixture.
- `projector_lock_timed` (card package): two concurrent projections → one `lock_wait{projector}` > 0 and two hold observations; gauges return to 0. The same helper covers `reconfig` / `launch_prefs`, so one package test plus code review of the call sites is enough.
- `test_lock_inventory` (grep-based check in the implementation's verify script, not a unit test): the set of service mutexes whose sections call `iface.*` must equal the `lock` enum's app-lock values; it fails when someone adds a new DB-guarding lock without telemetry.
- `request_db_scope_flush` / `slow_request_log_sanitized`: components sum ≤ request duration; log line has no SQL, query string or body.
- Plus a **wrapper microbenchmark** (`odin run` program, not a load test) reporting ns/call for `off` vs `basic`, separately for step (with site) and prepare. **This is the gate for the 300 ns budget (§4.1).**
- Known flake to keep separate: `test_tx_mutex_serializes_uow` fails under parallel package load on clean bases too (chain dead end `refresh_producers#2`).
- Post-deploy check (read-only): `curl -s localhost:9464/metrics | grep -c '^heimdall_db_\|^heimdall_sqlite_exec'` against the expected series ceiling.

### 4.4 Rollout and rollback

> **Update (task_18e0b0eb96f02802):** by user decision the first published release ships `basic` as the default (unset = basic; `off` opts out), so step 1's off-default parity window was skipped. Overhead is watched after deploy instead; see `docs/reference/db-telemetry.md` §1/§5.

1. Release N with `HEIMDALL_DB_TELEMETRY=off` default: verify parity (CPU, latency, existing families) for 24 h.
2. Enable `basic` on Dawnstar (operator restart). Watch overhead: `rate(process_cpu_seconds_total)` normalised by `rate(heimdall_http_requests_total)` vs the previous 7 days; series count; RSS.
3. Enable slow log (`HEIMDALL_DB_SLOW_MS=250`) after 24 h clean.
4. Collect the §5 windows (≥ 7 days incl. weekday busy periods).
5. Phase 2 (`full`) only if §2.6's trigger is met, canary first.
- **Rollback:** set `HEIMDALL_DB_TELEMETRY=off` and restart (no schema or data change is involved), or roll back the Nix generation. Dashboards keep working on the unchanged legacy families.

### 4.5 Grafana / PromQL (Prometheus 3 on Dawnstar; `le` values print as `"0.01"`, `"1.0"`)

```promql
# Main-connection utilisation (fraction of wall time the conn mutex is held by step/exec/prepare/finalize)
sum by (conn) (rate(heimdall_sqlite_exec_seconds_sum[5m]))

# Conn queueing relative to execution (ratio of sums)
sum(rate(heimdall_db_lock_wait_seconds_sum{lock="conn_main"}[5m]))
  / sum(rate(heimdall_sqlite_exec_seconds_sum{conn="main"}[5m]))

# Share of HTTP time spent in each DB component (ratio of sums; per route drop the outer sum).
# Components are disjoint (app_lock_wait, conn_wait, exec_excl_busy, busy_wait), so stacking/summing is valid.
sum by (component) (rate(heimdall_http_request_db_seconds_total[5m]))
  / scalar(sum(rate(heimdall_http_request_duration_seconds_sum[5m])))

# Lock wait p99 per lock
histogram_quantile(0.99, sum by (le, lock) (rate(heimdall_db_lock_wait_seconds_bucket[5m])))

# Fraction of conn_main acquisitions that waited > 1 ms
1 - sum(rate(heimdall_db_lock_wait_seconds_bucket{lock="conn_main",le="0.001"}[5m]))
      / sum(rate(heimdall_db_lock_wait_seconds_count{lock="conn_main"}[5m]))

# Peak queue depth (true high-water mark between scrapes; the plain waiters gauge is only a scrape-instant sample)
max_over_time(heimdall_db_lock_waiters_max{lock="conn_main"}[5m])

# Share of acquisitions that found the lock held (independent of scrape timing)
sum by (lock) (rate(heimdall_db_lock_contended_total[5m]))
  / sum by (lock) (rate(heimdall_db_lock_wait_seconds_count[5m]))

# Read share of main-conn execution
sum(rate(heimdall_sqlite_exec_seconds_sum{conn="main",op="select"}[5m]))
  / sum(rate(heimdall_sqlite_exec_seconds_sum{conn="main"}[5m]))

# Unit of work: hold p99, rate by outcome, stuck UoW
histogram_quantile(0.99, sum by (le) (rate(heimdall_db_lock_hold_seconds_bucket{lock="uow_tx"}[5m])))
sum by (outcome, rw) (rate(heimdall_db_tx_duration_seconds_count{kind="uow"}[5m]))
max_over_time(heimdall_db_uow_oldest_hold_seconds[5m])

# Mean statement cost and scans
sum by (op) (rate(heimdall_sqlite_vm_steps_total{conn="main"}[5m]))
  / sum by (op) (rate(heimdall_sqlite_statements_total{conn="main"}[5m]))

# R5: share of main-conn step time taken by the top 3 call sites (ratio of sums over one window; same family top and bottom)
sum(topk(3, sum by (site) (increase(heimdall_sqlite_site_exec_seconds_total{conn="main"}[1h]))))
  / sum(increase(heimdall_sqlite_site_exec_seconds_total{conn="main"}[1h]))

# Which sites those are, and which sites scan (rank, then look at vm/fullscan per site)
topk(10, sum by (site) (increase(heimdall_sqlite_site_exec_seconds_total{conn="main"}[1h])))
topk(10, sum by (site) (increase(heimdall_sqlite_site_fullscan_steps_total{conn="main"}[1h])))
sum by (site) (increase(heimdall_sqlite_site_vm_steps_total{conn="main"}[1h]))
  / sum by (site) (increase(heimdall_sqlite_site_exec_seconds_total{conn="main"}[1h]))   # vm steps per exec-second

# Busy/locked errors by code and IO proxy
sum by (conn, code) (rate(heimdall_sqlite_errors_total{code=~"busy.*|locked"}[5m]))
sum by (conn, kind) (rate(heimdall_sqlite_cache_events_total{kind=~"miss|write|spill"}[5m]))
```

- `waiters_max` is reset by each scrape, so it is correct only with a single scraper. A second scraper (for example a manual `curl`) splits the high-water mark between them, which makes it a lower bound. Dawnstar has one Prometheus job on `:9464`. Manual checks should read `contended_total` instead.

Dashboard rows: (1) utilisation, waiter high-water mark (`waiters_max`) and contended share per conn, with the instantaneous `waiters` gauge labelled "sampled depth", (2) wait/hold heatmaps per lock, (3) HTTP DB-share stacked by the disjoint components (`app_lock_wait`, `conn_wait`, `exec_excl_busy`, `busy_wait`), (4) tx rate/outcome/hold, (5) cost and IO, (6) overhead (CPU per request, series count). Annotate deploys; never draw a quantile across a bucket-layout change.

---

## 5. REQ-DBT-5: Observation windows and reader-pool decision criteria

### 5.1 Windows and denominators

- **Normal:** weekday 120 min windows matched to the prior study (e.g. 11:30–13:30Z), ≥ 5 weekdays.
- **Busy:** the top 10 % of 5 min intervals over 7 days ranked by `rate(heimdall_http_requests_total)` **and** separately by `rate(heimdall_sqlite_statements_total{conn="main"})` (agent/task bursts do not always coincide with browser load).
- **Validity:** ≥ 95 % scrape coverage, same release and telemetry mode, counter resets handled by `rate`, exclude windows with host reboots or host disk-latency incidents (the 146 ms write episodes) and report them separately as an IO sensitivity check.
- **Denominators:** per wall second (utilisation), per HTTP request (`http_request_db_seconds_total / http_requests_total`), per statement (`statements_total`), per acquisition (`lock_wait_count`). Every reported ratio states its denominator.

### 5.2 Criteria

Evaluate on the busy windows; the normal windows give the baseline.

**All numeric thresholds below are provisional hypotheses.** No measurement grounds them yet: the telemetry that would do so does not exist. Their starting values are engineering judgement. Before use:
1. Collect the normal windows first.
2. Calibrate each threshold against that baseline. For example, S1/R1 utilisation bounds are set relative to the normal-window p95, and the S2 "> 1 ms" bound stays above the normal-window conn_main p99 wait.
3. Record the final values with their rationale in a task comment, **before any busy-window data is queried**. This avoids fitting thresholds to the outcome.
4. Change values after that only with a recorded reason. Report the decision under both the original and the changed values.

**Supports a reader pool** (all of S1–S4, and S5 satisfied):
- **S1** main-conn utilisation `rate(exec_sum{conn="main"})` ≥ 0.5 at the busy p95 1 min value.
- **S2** `conn_main` wait ≥ 10 % of HTTP request time (ratio of sums, §4.5) **and** > 5 % of `conn_main` acquisitions wait > 1 ms.
- **S3** reads dominate what holds the conn: `op="select"` ≥ 60 % of main-conn exec time (a pool only offloads reads; writes still serialise).
- **S4** threshold-triggered records only (`reason=slow`, `request_ns ≥ HEIMDALL_DB_SLOW_MS`; `sample` lines excluded, drop rate stated) show `conn_wait ≥ 50 %` of request time in ≥ 30 % of records.
- **S5 (gate, not evidence)** `heimdall_sqlite_library_info{version}` ≥ 3.51.3 or a patched backport (3.44.6 / 3.50.7) — review Finding 3; and the review's F2/F4 corrections are in the plan.

**Rejects a reader pool for now** (any one):
- **R1** busy p95 utilisation < 0.2 **and** `conn_main` wait < 2 % of request time → the connection is not the bottleneck.
- **R2** dominant wait is `uow_tx`, a dedicated-conn lock, or a service lock (`projector`, `reconfig`, `launch_prefs`), or busy errors dominate → writer or projection serialisation. Shorten units of work, narrow the service locks (reader-plan B2 for `projector`), or apply review F4/F5 instead. Note: the `projector` lock exists *because* of the shared connection (`card_projector.odin:31-38`), so a reader pool alone does not remove it.
- **R3** main-conn exec dominated by write/commit ops or cache misses/IO (`cache_events{kind=miss}` rate tracks `exec` tail, or host disk latency correlates) → IO/write path fix, not readers.
- **R4** in threshold-triggered records (`reason=slow` only), all DB components together < 20 % of request time → the latency is elsewhere (the Dawnstar > 1 s requests were mostly vault/directory routes).
- **R5** a cheaper fix explains most of S1. The top 3 call sites take > 50 % of main-connection **step** time over the busy windows, by the §4.5 R5 query: `sum(topk(3, site_exec by site)) / sum(site_exec)`. The denominator is the same family, all sites.
  - Those sites also show high `site_fullscan_steps_total` or a high `site_vm_steps / site_exec` ratio. That indicates a scan or a missing index, not plain volume.
  - Then do the index/query fix first and re-measure.
  - Computable from unsampled counters (§2.2a). The attribution unit is the calling procedure, not a single SQL statement, so a hit names the procedure to inspect. The slow-record `file:line` narrows it further.

**Inconclusive** (between thresholds): extend to 14 days or wait for a naturally busy period; do not start stage 5. Load tests are out of scope for this chain and need separate approval.

### 5.3 Reading the existing evidence through these criteria

- v0.4.26 cut selects 41 % with no latency change. That is consistent with **R1/R4** (DB queueing was not the main latency driver at p50–p99) but does not prove it: the 10 ms bucket floor hides ms-scale queueing, and busy counters miss successful waits. These are exactly the gaps §2 closes.
- Note the denominators shifted between windows (writes +13 %, transitions 34 → 50): compare per-request and per-statement ratios, not raw counts.

---

## 6. Explicit non-goals and residual gaps

- No code, config, deploy, restart, load test or Dawnstar write in this task.
- Residual after phase 1: bind/column/reset mutex waits (bounded, unmeasured), busy waits only as exec time until phase 2, cross-process waits (none expected; single hub process), and `BUSY_SNAPSHOT` visibility depends on adding `sqlite3_extended_errcode` FFI (or `sqlite3_extended_result_codes(db,1)`; note that the latter changes rc values seen by existing `rc != SQLITE_OK` checks only in the extended bits, and `sqlite_metrics.odin:93` already masks with `& 0xff`, but other call sites compare to `SQLITE_DONE`/`SQLITE_ROW` exactly — so prefer `sqlite3_extended_errcode`, which changes nothing).
- `site` attribution is per calling procedure and covers step calls only. `exec`-helper statements (tx control, pragmas, DDL) and prepare/finalize stay attributed by `op` only.
- Prior reader-pool plan items B1/B2/M1/M2, the WAL-version gate and `BEGIN IMMEDIATE` are handled by that plan's revision, not here.
- Service-lock inventory is complete for the 2a467a5a scan (§1.5a), within the textual-audit limit stated there. Locks reached only through deep helper chains, if any, show up as unexplained non-DB time in slow-request records.
- Out-of-scope observation routed to the coordinator: the non-atomic favorite cap in `agent_handlers.odin:65-75` (§1.5a).
