# Call/write reduction: integrated results and SQLite cache sizing

Task `task_18e0c830ff76a227` (chain `chain_18e0c80041fe135d`), 2026-10-22. **Every number here comes from a local fixture.**
Nothing was deployed, pushed or restarted, and no production DB or config was touched. Production latency is confounded
by host I/O saturation and two unclean reboots (baseline §1, Dawnstar diagnosis), so nothing below is a production
latency claim.

## 1. Integration branch and ancestry

Worktree `/home/tanmay/hamwt/call-reduction-integration`, branch `call-reduction-integration`, base **`ae2728d7`** (v0.4.27).
This is the common base that all four reviewed branches were built and reviewed on.

| Source (reviewed head) | Original commit | Integrated as | Notes |
|---|---|---|---|
| Task 1 baseline (`call-reduction-baseline`) | `ff7507fb`, `cfe5316d` (= `a17227e5`, `56c3c313` as cherry-picked by tasks 2/3) | `d9479824`, `d4225b3a` | clean |
| Task 2 hot-path writes (`hotpath-writes` @ `7a2d5aa4`) | `da60cae2`, `7a2d5aa4` | `16213790`, `f703cee6` | clean |
| Task 3 API fetch dedup (`api-fetch-dedup` @ `a5bb14fb`) | `65419377`, `1b4546e0`, `a5bb14fb` | `24b16625`, `ed2ccadb`, `cc30dddf` | clean |
| Task 4 indexes (`sqlite-index-eval` @ `47c4bb32`) | `0520e022`, `47c4bb32` | `bd3521b4`, `9e7798f4` | the task-1 duplicates `27e1f10a`/`66b55965` were skipped. `0520e022` conflicted only in `migrations.odin` (const, `migration_order` tail, `migration_sql` branch). Resolved to keep both, order `102, 103, 104`, array `[107]`, as task 4 predicted |
| This task | (see `git log`) | | cache pragma, replay timing, matrix harness, report, `verify-integration.sh` |

`verify-integration.sh` checks the ancestry mechanically. Every reviewed commit's `git patch-id --stable` must be present
in `ae2728d7..HEAD`. For the conflicted `0520e022`, its files must be byte-identical to task 4's tip `47c4bb32`, and the
migration order is asserted.

**Main has moved.** Since planning, `origin/main` has advanced to `483f5b43` (15 commits), and it ships its own
`103_plan_enforcement.sql`. That collides with task 2's `103_guard_chat_fts_updates.sql` and task 4's `104_full_scan_indexes.sql`.
Renumbering reviewed migrations is outside this task's scope. **Whoever merges this to main must renumber 103→104 and 104→105
(or later), update `migration_order` and `migration_sql`, and rerun `verify-integration.sh`.** Nothing has been pushed.

## 2. REQ-CACHE: `cache_size` / `mmap_size` matrix

### Method
- **Fixture:** the prod-shaped DB from task 4's harness (`tests/sqlite_index_eval.odin`, `prod` scale: 1,800 shells, 300 conversations ×60 messages, 90 chains). It is 8.8 MB, 2,148 pages of 4 KiB. All runs used copies, so the fixture was never opened.
- **Workload:** the five hottest read statements, using the real repo SQL captured by task 4 with literal parameters (`tools/cache_matrix/`): `content_list_conversations` (limit 200), `live_bridge_ids`, `live_by_kind(server)`, the retention predicate in SELECT form, and `dependencies_by_chain`. Each pass runs every statement 10 times. One connection runs 5 passes.
- **Engine:** the `sqlite3` 3.53.3 CLI (the same library version as the hub). One CLI process is one connection. `.stats` gives page-cache hits and misses per statement, `.timer` gives the time, and `/usr/bin/time` gives max RSS.
- **Warm:** the OS page cache holds the file. Pass 1 starts with an empty connection cache; passes 2–5 are the warm steady state, which is what long-lived hub connections see.
- **Cold:** a fresh copy of the file is fsync'd, then evicted from the OS page cache with `posix_fadvise(POSIX_FADV_DONTNEED)` (no root needed). `fincore` must report 0 resident bytes before the run. `/tmp` is tmpfs, where eviction is a no-op, so the copies live on btrfs/NVMe under `~/.cache/heimdall-tests/cache-matrix`.
- **RSS:** "RSS over idle" is the connection's max RSS minus that of a connection that opens the DB and runs nothing (about 5.3–5.5 MiB). File-backed mmap pages count toward RSS.
- **Repeats:** 3 full runs (`docs/cache-matrix-run{1,2,3}.txt`). The table shows the range across runs.

### Results (local fixture)

| Config | Mode | Pass-1 miss % | Pass-1 ms | Warm miss % (passes 2–5) | Warm ms/pass | RSS over idle (MiB) |
|---|---|---:|---:|---:|---:|---:|
| **default** (`cache_size=-2000`, mmap 0) | warm | 1.50 | 117.0–118.9 | **1.49** (35,072 misses) | **112.3–114.7** | 1.9–2.2 |
| default | cold | 1.50 | 137.1–148.8 | 1.49 | 113.3–114.5 | 1.7–2.1 |
| **`cache_size=-8000` (8 MiB)** | warm | 0.17 | 106.5–112.1 | **0.00** | **103.0–105.7** | 4.1–4.4 |
| `cache_size=-8000` | cold | 0.17 | 125.8–127.9 | 0.00 | 104.0–104.5 | 3.9–4.3 |
| `cache_size=-16000` (16 MiB) | warm | 0.17 | 106.6–109.0 | 0.00 | 104.0–104.2 | 4.2–4.5 |
| `cache_size=-16000` | cold | 0.17 | 126.9–133.9 | 0.00 | 103.2–104.6 | 3.6–4.2 |
| `mmap_size=64 MiB` | warm | n/a (mmap reads bypass the pager) | 105.7–110.2 | 0.00 | 103.8–105.8 | 6.9–7.2 |
| `mmap_size=64 MiB` | cold | n/a | 117.8–120.5 | 0.00 | 104.7–104.8 | 6.5–7.0 |
| 8 MiB cache + 64 MiB mmap | warm | 0.00 | 106.6–107.0 | 0.00 | 103.8–105.6 | 6.6–7.1 |
| 8 MiB cache + 64 MiB mmap | cold | 0.00 | 115.6–122.5 | 0.00 | 102.5–105.5 | 6.2–6.8 |

What this shows:
- On this fixture, the default 2 MiB cache **thrashes**. The working set of these five statements (the conversation list alone touches about 84k pages per 10 calls) exceeds 500 pages, so every warm pass still misses 1.49%. That fits production's 8.4% main-conn miss ratio, which also comes from long-lived connections with defaults, but this does **not** show that production's working set is the same.
- **8 MiB removes all warm misses.** Warm exec time drops about 8% (≈113.6 → ≈104.3 ms/pass) and the cold first pass about 10% (≈141 → ≈127 ms), consistently across 3 runs.
- **16 MiB adds nothing over 8 MiB** on this fixture: the whole 8.8 MB file fits in either.
- **mmap adds nothing over the 8 MiB cache** (warm 104–105 ms either way; cold pass-1 is ~7 ms better) and costs **+2.5–3 MiB more RSS**. It also has a correctness and stability cost on this host: an I/O error on a mapped page raises **SIGBUS** (the process dies) instead of returning `SQLITE_IOERR`. The host has had two unclean reboots and saturated NVMe I/O. **Rejected.**

### RSS budget across hub connections

The hub opens **5** connections to one file: main (`wiring.odin`), metrics collector (`metrics_db_collectors.odin:92`),
enroll commit (`bridge_repo_sqlite.odin:31`), vault write (`vault_directory_repo_sqlite.odin:36`) and billing (`billing_repo_sqlite.odin:44`).
SQLite page caches are per connection, and `cache_size` is a per-connection pragma. `test_main_conn_cache_size_is_per_connection`
asserts that a second connection keeps -2000 and that mmap stays 0.

| | Per-conn cache cap | 5-conn cap | Measured on fixture |
|---|---:|---:|---|
| Before (all default) | 2 MiB | 10 MiB | ≈2.0 MiB per busy conn |
| After (main 8 MiB, others default) | main 8 MiB, others 2 MiB | **16 MiB (+6 MiB)** | main ≈4.3 MiB (+2.3 MiB) on an 8.8 MB DB |

**Stated budget: at most +6 MiB hub RSS**, a hard cap because `cache_size` is an upper bound. Write and metrics connections
are left alone: they run point writes and small aggregates. RSS was measured per connection in CLI processes and summed;
the hub process itself was not booted for this measurement.

### Decision: adopt `PRAGMA cache_size = -8000` on the main connection only
- `src/hub/repository/sqlite/conn.odin`: the `MAIN_CONN_CACHE_SIZE_PRAGMA` constant, with its rationale.
- `src/hub/app/wiring.odin`: it is applied right after the existing `synchronous` pragma. Startup fails the same way when the pragma fails, as the neighbouring pragmas do.
- `src/hub/repository/sqlite/main_cache_size_test.odin`: tests that the pragma takes effect, is per connection, and leaves mmap at 0.
- **Unchanged:** `journal_mode`, `synchronous`, `busy_timeout`, `wal_autocheckpoint` and every checkpoint setting. There is no durability change.
- **Confidence: medium.** The benefit is clear and repeatable on the fixture. Production's working set and DB size are unknown (baseline caveat C7), so production gain is unverified. Watch the miss-ratio metric in §5.

## 3. Before/after: calls, statements, writes, local tails

### 3.1 DB work per scenario (task-1 real-procedure replay)
`tests/call_reduction_baseline.odin` was extended with one `Timing [...] wall_us=` line per scenario (snapshot → show). The tables
it prints are unchanged. The **same** timing patch was applied to the baseline harness at `d4225b3a` in a throwaway detached worktree
(`~/.cache/heimdall-tests/cri-timing/base`, not committed). Both sides were built and run 15 times each, interleaved, with a fresh
fixture DB each run (`tools/cache_matrix/replay_timing.sh`, `replay_compare.py`). Counts are deterministic and identical across runs.
p50/p95/p99 are taken over the 15 per-scenario wall times (each one is N calls, e.g. ×30). The replay opens connections with
`sqlite.open` (default cache), so **the cache pragma does not affect this table**; it measures tasks 2–4 only. b = baseline, i = integrated.
Full table: `docs/call-reduction-integrated-replay-compare.md`.

| Scenario | Stmts b→i | DML stmts | VM steps b→i | Fullscan b→i | Cache page writes b→i | p50 µs b→i | p95 µs b→i | p99 µs b→i |
|---|---|---:|---|---|---|---|---|---|
| vault advancing clock 4s ×30 (dedicated conn) | 30 UPDATE | 30 | 1562→1172 | 0 | **30→0** | 45274→2916 | 48323→2987 | 48447→2988 |
| vault identical touch ×30 | 30 UPDATE | 30 | 1560→1170 | 0 | 0→0 | 429→572 | 447→589 | 452→590 |
| shell identical registration ×92 | 92 INSERT/upsert | 92 | 13708→13248 | 0 | **92→0** | 10648→14744 | 10714→15395 | 10721→15570 |
| conversation read ×21 | 42 SEL, 21 INS, 1 UPD | 22 | 27071→25578 | 0 | **104→34** | 4485→3131 | 5021→3220 | 5302→3221 |
| conversation already read ×20 | 40 SEL, 20 INS | 20 | 17380→17100 | 0 | **80→20** | 3278→2264 | 3403→2379 | 3465→2429 |
| … with changing clock ×20 | same | 20 | 17380→17100 | 0 | **100→40** | 3436→2514 | 3661→2576 | 3723→2601 |
| mark read same 10 ids ×21 | 21 UPDATE | 21 | **17522→3423** | 0 | **133→5** | 3345→1470 | 3828→1523 | 4108→1536 |
| agent already read ×20 | 20 UPDATE | 20 | **16640→2660** | 0 | **141→0** | 3193→1290 | 3562→1367 | 3879→1432 |
| empty search delta enrichment ×10 | **20→0 SELECT** | 0 | **642440→0** | 0 | 0 | 32312→3 | 33059→3 | 33133→3 |
| live by kind ×10 | 10 SELECT | 0 | **43230→28640** | **5990→0** | 0 | 2076→1943 | 2160→2026 | 2176→2027 |
| chain dependencies ×10 | 10 SELECT | 0 | **20460→1850** | **5690→0** | 0 | 892→458 | 947→511 | 952→577 |
| retention, no expired rows ×10 | 10 DELETE | 10 | **70860→680** | **5990→0** | 0 | 2269→313 | 2500→326 | 2513→331 |
| bridge heartbeat same state ×120 | 120 SEL, 120 INS | 120 | 18480 | 0 | 0 | 8667→8612 | 9651→9416 | 9859→9986 |
| bridge heartbeat advancing 45s ×120 | 120 SEL, 120 INS | 120 | 18480 | 0 | 120→120 | 13087→13013 | 13758→13814 | 13871→14005 |
| task comments ×30 | 30 SEL, 60 INS | 60 | 4710 | 0 | 300→300 | 6505→6539 | 6936→6697 | 7566→6702 |
| conversations list ×10 | 10 SELECT | 0 | 487370 | 0 | 0 | 27497→26971 | 28147→28431 | 28225→28920 |
| live bridge ids ×10 | 10 SELECT | 0 | 88440 | 5990 | 0 | 2916→2916 | 3101→3056 | 3216→3194 |

How to read it:
- **"DML stmts" is unchanged on purpose.** Task 2 guards in the `WHERE` clause, so the UPDATE still runs but matches 0 rows. The saving shows up as cache page writes (dirtied pages, hence WAL frames). The biggest are vault advancing touch (30→0, the #1 production slow site), mark-read (133→5) and shell upsert (92→0). Bridge heartbeat (120 frames) and task-comment writes are deliberately unchanged (task 1/2 decisions: liveness semantics; comment + audit are both kept).
- **Local tails, which are not production claims:** they improve wherever page writes or full scans go away. **Two regressions** also appear in the local wall time: *shell identical registration* p95 10.7→15.4 ms (+44%) and *vault identical touch* p95 447→589 µs. The likely cause is that the guard's comparison of every column costs more CPU than it saves when the page is already cached and nothing is flushed. Both scenarios now write **0** pages, and on the I/O-bound production host a page write costs far more than that CPU. I did not investigate further, and it is flagged for the reviewer.
- The rows not shown (component reads, candidate-index rows, enroll tokens) are unchanged within noise. A new `conversation project links ×10` scenario exists only in the integrated replay (added by task 3).

### 3.2 HTTP/API calls (task 3, UI real-handler test; re-run by `verify-integration.sh`)
These figures come from the task-3 test `tests/ui_shell_list_invalidation_test.ts` and the baseline the same test measured at `65419377` with `DEDUP_BASELINE=1`.

| Scenario (per tab) | GET /shells before → after |
|---|---|
| own-agent shell run | 9 → 6 |
| other agent's run | 9 → 4 |
| single burst | 6 → 3 |
| chain server | 9 → 6 |
| uncached exit | 3 → 3 |

Task 3 also removes the empty search-delta enrichment: 2 SELECTs and 64,244 VM steps per empty helper call become 0 (§3.1 row).
The production route volumes (POST /bridges/*/shells 92, GET /vault/directory 30, POST tasks/comment 30, POST chats/*/read 21 per 40 min)
are modelled in the replay's "HTTP modeled" column. They are unchanged, because these tasks change work per call, not client call
volume, except for the GET /shells invalidations above.

## 4. Read-pool revisit (baseline §5.4), local-only, production-unverified

**A read pool stays deferred.** The §5.4 revisit trigger is: after levers 1–3, GET-route `conn_wait` ≥ 10% of HTTP time **and** S4
(slow records with conn_wait ≥ 50%) ≥ 30%, in **calibrated** busy windows. None of that is measured yet:
- Lever 1 (host storage/I/O and the unclean reboots) is diagnosed but not fixed (Dawnstar report: shared-NVMe contention, causes of two abrupt boots unproven).
- Lever 2 (write coalescing) and lever 3 (cache) exist only on this unmerged, undeployed branch. Locally they remove the head-of-line writes the pool would route around: vault touch and mark-read page writes go to ~0. That should lower `conn_main` wait, but **only production windows can show it**.
- The §5.1 calibration (≥5 weekdays with no reboot) has not happened. Baseline numbers: GET conn_wait 26.8% (W15), 18.5% (W40), 13.2% (W270); S4 25.8/17.1/23.9%. All exceed the 10% conn_wait line but stay below the S4 30% line, from uncalibrated, reboot-confounded windows.

Local evidence cannot meet or clear the trigger; this replay is single-threaded and has no contention. The decision remains
**no read pool unless the trigger is met after deploy** in calibrated windows.

## 5. Production metrics to watch after a future deploy (plan §4.5 PromQL, Hub `mundus`)

| Expectation | PromQL |
|---|---|
| main-conn miss ratio drops from 8.4% (cache lever) | `sum by (conn,kind)(increase(heimdall_sqlite_cache_events_total{hub="mundus"}[15m]))`, then miss/(hit+miss) for `conn="main"` |
| fewer page writes (`kind="write"`) on main and vault (write coalescing) | same family, `kind="write"`, per conn |
| full scans gone at the reaper/live/dependency sites | `topk(8, sum by (conn,site)(increase(heimdall_sqlite_site_fullscan_steps_total{hub="mundus"}[15m])))` |
| main exec time and its p95 drop | `sum by (conn,op)(increase(heimdall_sqlite_exec_seconds_sum{hub="mundus"}[15m]))`; `quantile_over_time(0.95, (sum(rate(heimdall_sqlite_exec_seconds_sum{hub="mundus",conn="main"}[1m])))[15m:1m])` |
| head-of-line wait drops (pool trigger input) | `sum by (lock)(increase(heimdall_db_lock_wait_seconds_sum{hub="mundus"}[15m]))`; `sum by (route,component)(increase(heimdall_http_request_db_seconds_total{hub="mundus"}[15m]))` (GET-route conn_wait ÷ HTTP time) |
| slow writes (>250 ms) drop | `sum by (conn,op)(increase(heimdall_sqlite_exec_seconds_count{hub="mundus"}[15m])) - sum by (conn,op)(increase(heimdall_sqlite_exec_seconds_bucket{hub="mundus",le="0.25"}[15m]))` |
| top routes' tails (vault/directory, shells, comment, chats read) | `histogram_quantile(0.99, sum by (route,method,le)(rate(heimdall_http_request_duration_seconds_bucket{hub="mundus"}[15m])))` and the >1s count query from §7 |
| GET /shells volume drops (task 3) | `sum by (route,method,status_class)(increase(heimdall_http_requests_total{hub="mundus"}[15m]))` |
| hub RSS stays within +6 MiB | `process_resident_memory_bytes{hub="mundus"}` before/after |
| S4 share for the pool trigger | the VictoriaLogs `db_slow_request` query in baseline §7 |

Compare only like-for-like, calibrated windows with no reboot and similar host I/O pressure (`rate(node_pressure_io_waiting_seconds_total{host="dawnstar"}[15m])`).

## 6. Decisions and dead ends
- The integration base is `ae2728d7`, not the current `origin/main` `483f5b43`. All reviewed work targets `ae2728d7`, and main's new 103 migration needs a renumbering decision (§1).
- Cache: 8 MiB on main only. 16 MiB showed no added benefit; mmap was rejected (SIGBUS, more RSS, no gain); write and metrics conns were left alone.
- Dead end: cold-cache eviction on `/tmp` does nothing (tmpfs). Use a disk-backed path and confirm with `fincore`.
- Dead end: the sqlite3 CLI with `.output /dev/null` also suppresses `.stats` and `.print`. Let the rows print and parse them.
- Dead end: binaries run through `nix develop -c` need a cwd containing `flake.nix`.
- The task-3 Vite build segfaulted once (Node v26, a known flake from task 3) in the first dry run of `verify-integration.sh`. The final verify result is recorded in the handoff.

## 7. Port onto origin/main 483f5b43 (branch `call-reduction-rebased`, 2026-10-22)

The reviewed work above, ported to the latest `origin/main` so it can merge. Nothing was pushed or deployed and the shared checkout was not touched.

- **Worktree:** `/home/tanmay/hamwt/call-reduction-rebased`, branch `call-reduction-rebased`.
- **Base:** `origin/main` = `483f5b43197c9d21f75572fae732f69608fe90e6`. Re-fetched at start; main had not moved since task 5. Main's latest migration is `103_plan_enforcement.sql`.
- **Method:** cherry-picked the ten integration commits `d9479824..448ca6e5` in order, then added three commits.

### 7.1 Commits (oldest first)

| Rebased | From integration | Reviewed origin | How it landed |
|---|---|---|---|
| `b4acc6a1` | `d9479824` | `ff7507fb` | clean, same patch-id |
| `d6fbb942` | `d4225b3a` | `cfe5316d` | clean, same patch-id |
| `664f31ba` | `16213790` | `da60cae2` | conflict in `migrations.odin` (see 7.3) |
| `2afaa126` | `f703cee6` | `7a2d5aa4` | conflict in `migrations.odin` (see 7.3) |
| `fa3a62d7` | `24b16625` | `65419377` | clean, same patch-id |
| `b5393b18` | `ed2ccadb` | `1b4546e0` | clean (auto-merged `shells.ts`), same patch-id |
| `61105139` | `cc30dddf` | `a5bb14fb` | clean, same patch-id |
| `10f0f294` | `bd3521b4` | `0520e022` | auto-merged, but the result was wrong (see 7.3) |
| `96183a34` | `9e7798f4` | `47c4bb32` | clean, same patch-id |
| `7cb4f0b1` | `448ca6e5` | task 5 | clean (auto-merged `wiring.odin`), same patch-id |
| `31a3e633` | — | new | renumber migrations; add upgrade tests |
| `fe10757f` | — | new | user-approved vault `last_seen` throttle, 300 s → 3600 s |
| `b6273f2a` | — | new | `verify-rebased.sh`; remove `verify-integration.sh` |

The last commit on the branch appends this section to the report.

### 7.2 Migration renumbering

| Before (integration) | After (rebased) |
|---|---|
| `103_guard_chat_fts_updates.sql` / `MIGRATION_103_GUARD_CHAT_FTS_UPDATES` | `104_guard_chat_fts_updates.sql` / `MIGRATION_104_GUARD_CHAT_FTS_UPDATES` |
| `104_full_scan_indexes.sql` / `MIGRATION_104_FULL_SCAN_INDEXES` | `105_full_scan_indexes.sql` / `MIGRATION_105_FULL_SCAN_INDEXES` |
| `migration_order :: [107]string` (on ae2728d7) | `migration_order :: [108]string`, ending `102_drop_bridge_enrollments`, `103_plan_enforcement`, `104_guard_chat_fts_updates`, `105_full_scan_indexes` |

- **Where the new numbers are used:**
  - `migration_sql` branches.
  - The `run_migrations` skip guard for 104, which now applies only when both chat FTS vtables exist.
  - `tests/hotpath_writes_test.odin` (`before_104`, `stop_before = "104_guard_chat_fts_updates.sql"`).
  - `full_scan_indexes_test.odin` (`FSI_MIGRATION`, `test_m105_*`).
  - `tests/sqlite_index_eval.odin` (`MIGRATION_105_FULL_SCAN_INDEXES`, the "Shipped migration 105" heading) and `verify-sqlite-index.sh`.
- **Numbers:** no number after 102 is reused. Main's numbers 043, 044, 048 and 072 were already shared before this work.
- **Earlier reports in `docs/`:** the reports from tasks 2 and 4 still say "migration 103/104". Read those as 104/105 on this branch.

New test file: `src/hub/repository/sqlite/rebased_migration_order_test.odin`.
- `test_rebased_upgrade_from_main_tip_applies_104_and_105`: migrates with `stop_before = 104_guard_chat_fts_updates.sql`, which is main's tip. It asserts that 103_plan is applied, that ours are not yet applied, that the triggers are unguarded and that the indexes are absent. It then seeds a user and a shell row, upgrades, and asserts: both migrations applied, `bridges.plan_disabled_at` present, guarded triggers, all 3 indexes, 108 ledger rows, the row survives, and a re-run is a no-op.
- `test_rebased_fresh_database_applies_every_migration`: every `migration_order` name is recorded, plus the same post-conditions.
- `test_rebased_migration_numbers_after_102_are_unique`: checks the tail order and that numbers after 102 are strictly ascending.

The FTS consistency tests (`hotpath_writes_test`) and the index query-plan tests (`test_m105_repository_reads_plan_onto_the_indexes` and the index harness) are re-run by verify.

### 7.3 Conflicts and source drift

| Site | Result | Rationale |
|---|---|---|
| `migrations.odin`: consts, `migration_order`, `migration_sql` (2 conflicts while picking `16213790` and `f703cee6`) | Kept both sides. Main's 103 goes first, then ours. | Main's migration is already numbered and shipped. Ours follow it in their original relative order (FTS guard, then indexes). |
| `migrations.odin` after `bd3521b4` | Git merged it with no conflict but left `[107]` holding 108 entries, which does not compile. Fixed to `[108]` in the renumber commit. | This was a semantic conflict. `verify-rebased.sh` now asserts the declared size equals the entry count. |
| `src/hub/app/wiring.odin` | Auto-merged. Main reworked billing and entitlement wiring and did not touch the pragma block. `MAIN_CONN_CACHE_SIZE_PRAGMA` still runs right after `synchronous = NORMAL` on `graph.db`. | Nothing to change. |
| `src/ui/api/endpoints/shells.ts` | Auto-merged. Main's only change is `customQueryError` in the pane-reply endpoint, which is not one of our `listShells` tags. | Nothing to change. |
| `vault_directory_repo_sqlite` touch_last_seen, `content_repo_sqlite` mark_messages_read, `shell_session_repo_sqlite` upsert, `taskchain_handlers` search-documents early return, `wsInvalidation.ts`, `conn.odin` | Main did not touch these files since ae2728d7. | No drift. |
| Callers of GET /shells | The caller set is unchanged. Line numbers moved: `ShellLaunchPanel.tsx:76→81`, `ShellMainPane.tsx:188→192`, `AppShell.tsx:1531→1533`. | These matter for the docs only. Main's `planLimitReached` tag is separate from `ShellSessions`. |
| `103_plan_enforcement.sql` | It rebuilds `billing_plans` and `account_entitlements` and adds `bridges.plan_disabled_at`. It touches no chat, shell or dependency table. | No interaction with our triggers or indexes. |

No reviewed behaviour changed apart from the approved throttle (7.4).

### 7.4 User-approved change: vault `last_seen` throttle 300 s → 3600 s

- **What changed:**
  - `vault_touch_last_seen_sqlite` now uses the named constant `VAULT_LAST_SEEN_THROTTLE_SECONDS :: 3600` instead of the literal `300`.
  - The constant is bound as `?4` and compared as `unixepoch(?1) - CAST(?4 AS INTEGER)`.
- **What did not change:**
  - It is still one conditional UPDATE on the dedicated vault writer, with no extra read.
  - The NULL/invalid branch and the clock-regression branch (`last_seen_at > now`) are as before.
- **Why it is safe:** `last_seen_at` is read only by Settings → Devices and the revoke confirmation (`DevicesPanel.tsx:66,86`). No auth, expiry or prune logic uses it.
- **Tests:**
  - `vault_boundary_owner_clock_and_errors`: no write at +3599 s, a write at +3600 s (`VAULT_NEXT = NOW + 3600`), no write at +3599 s after that.
  - `concurrent_atomic_guards`, after reopen: no write at NEXT+3599 s, a write at NEXT+3600 s.
  - Its first run failed at the old +300 s step, which confirms the boundary test exercises the constant.
- **Comments:** the "five minutes" comments in `domain/vault_directory.odin:92` and `vault_directory_handlers.odin:241` now say one hour.
- **Expected effect:** each device writes `last_seen` at most once an hour instead of once every five minutes, under steady signed traffic. Only the presence shown in the Devices panel gets coarser.

### 7.5 `verify-rebased.sh`

This is the union of the `verify-integration.sh` checks on the new base. `verify-integration.sh` was removed because it pins base `ae2728d7`, the old migration names and `[107]`.

**Ancestry, adapted:**
- **Patch-id matches:** `ff7507fb cfe5316d 65419377 1b4546e0 a5bb14fb 47c4bb32 448ca6e5`.
- **No patch-id match:** `da60cae2` and `7a2d5aa4` (task 2) and `0520e022` (task 4) hit main's 103 in `migrations.odin`, and the renumber edits their files. They are checked by content instead:
  1. Every file the integration branch changed must equal its content at `448ca6e5` after the scripted renumber rewrite. `docs/` files are compared verbatim. Files touched by the throttle commit are compared at that commit's parent, and the throttle commit may touch only its 4 files.
  2. For files main also changed (`wiring.odin`, `shells.ts`), the added and removed lines must equal the integration's.
  3. `migrations.odin` must add exactly the integration lines, renumbered. The only allowed differences are the `[108]` size line and the new two-line 104 comment.
- **Negative checks:**
  - A one-line edit committed to `content_repo_sqlite.odin` fails with `content drift`.
  - A one-line edit committed to `wiring.odin` fails with `changed-line drift`.
  - Both were reset afterwards.

**Other checks:**
- Numbering: the `102,103,104,105` tail, `[108]` equal to the entry count, no reused number in `migrations/`, and no stale names.
- The throttle constant.
- New tests: the rebased upgrade tests plus main's `billing_repo_test` (103_plan_enforcement upgrade/crash-recovery).
- REQ-CACHE: test, wiring grep, mmap off.
- `verify-sqlite-index.sh`, `verify-hotpath-writes.sh` and `verify-api-fetch-dedup.sh`, each re-run in this worktree.

The task-1 baseline replay runs inside those scripts. It is a pass/fail replay; the before/after counts in §4 were not re-measured on this base.

### 7.6 Result

Pre-submit run of `bash verify-rebased.sh` at `b6273f2a` (`ham-ctl shell run` session `sh_6ac77d0d39b2ce1bd788729ce530d78c`, full log at `/home/tanmay/hamwt/call-reduction-rebased-verify-dryrun.log`): exit 0.
- Ancestry: 7 patch-ids found; 47 files match by content; `migrations.odin` lines match after renumbering. Numbering OK. Throttle OK.
- Rebased upgrade tests plus billing migration tests: 9/9 pass. Cache test OK.
- 56 scoped sqlite tests pass. Index harness passes (t1). Baseline replay passes (×3). Hub build succeeds (×3).
- Hot-path tests: 6/6 pass.
- Fetch-dedup backend passes. Typecheck passes. The Vite build passes on the first try: no Node v26 segfault in this run.
- UI suites: 39/39. Shell-list test 1/1, with GET /shells per tab of 6/4/3/6/3, the same as task 3. REQ-SHELL-6: 5/5.

The final check at the submitted head is recorded in the task handoff.
