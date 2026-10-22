# SQLite index evaluation for full-scan sites (REQ-INDEX)

Task `task_18e0c830fa1871df`, branch `sqlite-index-eval`, base `ae2728d7` (origin/main v0.4.27). Task-1 commits cherry-picked: `a17227e5` → `27e1f10a` and `56c3c313` → `66b55965`.

## Verdict

| Candidate query | Verdict | Index (migration `104_full_scan_indexes.sql`) |
|---|---|---|
| `shell_session_list_live_by_kind` | **ADD** | `idx_shell_sessions_kind_started ON shell_sessions(kind, started_at, session_id)` |
| `shell_session_delete_terminal_before_owners` | **ADD** | `idx_shell_sessions_retention ON shell_sessions(status, COALESCE(NULLIF(finished_at, ''), NULLIF(last_activity_at, ''), started_at))` |
| `taskchain_list_dependencies_by_chain` | **ADD** | `idx_task_dependencies_chain ON task_dependencies(chain_id, owner_user_id, created_at)` |
| `shell_session_list_live_bridge_ids` | **NO CHANGE** | No index removes the scan while the SQL uses `status NOT IN (?,?,?)`. |
| `content_list_conversations_sqlite` | **NO CHANGE** (revisit only with production conversation counts) | Neither candidate pays off unconditionally. |

No repository SQL was changed. Only `CREATE INDEX IF NOT EXISTS` statements were added.

## Method

- Harness: `tests/sqlite_index_eval.odin`, run as `sqlite_index_eval <scratch db> <t1|prod>`. It runs the real migrations into a scratch DB under `$HOME/.cache/heimdall-tests`, then drops the three migration-104 indexes to restore the pre-104 baseline. It seeds data through the real repository procs and calls the real procs. It captures the exact SQL each proc prepares through `sqlite3_trace_v2` and runs `EXPLAIN QUERY PLAN` on that captured text, so no workload SQL is copied. VM, fullscan and sort steps come from the existing `heimdall_sqlite_*` telemetry (`sqlite3_stmt_status`). Page writes are `SQLITE_DBSTATUS_CACHE_WRITE` page-cache writebacks, not device writes.
- **Cold:** the first call after closing and reopening the connection, so SQLite's page cache is cold. The OS cache stays warm, and nothing privileged was dropped. **Warm:** the median of the next 50 calls. Wall times are local-fixture numbers only and say nothing about production latency (host IO saturation confounds production).
- Each variant is measured stat-less, which is how production runs, and again after `ANALYZE` (then `sqlite_stat1` is dropped and the connection reopened).
- Write cost uses the real procs at 200 rows per phase, with one transaction per phase. The shell lifecycle phases are insert `running` → activity upsert → exit upsert → retention DELETE of those 200 rows. The other workloads are conversation save (200 updates), message insert (200) and dependency insert (171 edges inside one workflow execution). Index size is the change in used pages (`page_count - freelist_count`) caused by the `CREATE INDEX`.
- **Semantics guard:** the harness fails unless each call returns byte-identical JSON results, including row order, with and without every candidate index and with and without `ANALYZE`. It also checks that retention RETURNING owners report exactly the 200 deleted rows.
- **Scales.** `t1` is the task-1 fixture shape: 600 shells (30 live, 200 of each kind), 20 bridges, 60×100 messages, 30 chains × 20 tasks. `prod` is production-shaped: 1,800 shells (1% live, 5% servers), 30 bridges, 300 conversations × 60 messages, 90 chains × 20 tasks. The 1.8k shell rows are **inferred**: W40 fullscan steps (263k / 207k) divided by roughly 120–160 reaper and collector calls gives about 1.7k rows per scan. The conversation and dependency counts are assumptions; production was not queried.
- SQLite version is 3.53.3. The Hub never runs `ANALYZE` or `PRAGMA optimize` (`git grep` over `src/hub` finds nothing), and `sqlite_stat1` is absent after migrations.

Raw outputs: [`sqlite-index-eval-t1.txt`](sqlite-index-eval-t1.txt) and [`sqlite-index-eval-prod.txt`](sqlite-index-eval-prod.txt). These copy the harness output verbatim and contain the full plans.

## Per-query evidence

All values are per call. Warm/cold times are in µs, measured on the local fixture.

### 1. `shell_session_list_live_by_kind` — ADD `(kind, started_at, session_id)`

SQL: `SELECT <22 cols> FROM shell_sessions WHERE kind = ? AND status NOT IN (?, ?, ?) ORDER BY started_at ASC, session_id ASC LIMIT ?;`

| Scale | Variant | VM | Fullscan | Sort | Cold | Warm | Plan |
|---|---|---:|---:|---:|---:|---:|---|
| t1 | before | 4,323 | 599 | 1 | 265 | 209 | `SCAN shell_sessions ; USE TEMP B-TREE FOR ORDER BY` |
| t1 | after | 2,863 | 0 | 0 | 375 | 208 | `SEARCH shell_sessions USING INDEX … (kind=?)` |
| prod | before | 7,223 | 1,799 | 1 | 456 | 340 | `SCAN shell_sessions ; USE TEMP B-TREE FOR ORDER BY` |
| prod | after | **1,626** | **0** | 0 | 294 | 187 | `SEARCH shell_sessions USING INDEX … (kind=?)` |

With `ANALYZE` the plans and VM counts are identical. A variant that also includes `status` (`kind, started_at, session_id, status`) reads the same VM, because the result columns need the table row anyway. It costs more on writes, though: the shell upsert assigns `status` on every UPDATE, so that variant adds +14 VM per activity or exit upsert. The shipped variant adds **+1 VM** per upsert. **status is therefore excluded on purpose.** The tie-break column `session_id` matches the ORDER BY, so ordering is unchanged.

### 2. `shell_session_delete_terminal_before_owners` — ADD `(status, <retention expr>)`

SQL: `DELETE FROM shell_sessions WHERE status IN (?, ?, ?) AND COALESCE(NULLIF(finished_at, ''), NULLIF(last_activity_at, ''), started_at) < ? RETURNING owner_user_id;`

| Scale | Variant | VM | Fullscan | Cold | Warm | Plan |
|---|---|---:|---:|---:|---:|---|
| t1 | before | 7,086 | 599 | 327 | 255 | `SCAN shell_sessions` |
| t1 | after | 67 | 0 | 53 | 27 | `SEARCH … USING INDEX … (status=? AND <expr><?)` |
| prod | before | 21,546 | 1,799 | 790 | 646 | `SCAN shell_sessions` |
| prod | after | **67** | **0** | 58 | 28 | `SEARCH … USING INDEX … (status=? AND <expr><?)` |

The measured case is the steady state, where nothing is expired. With 200 expired rows, the DELETE drops from 35,346 to 13,667 VM (prod). This is the only write-path statement that gets cheaper, and it shortens the time the retention sweep holds the writer lock (local: 646 µs → 28 µs). The index expression is byte-identical to the repository SQL. A test asserts the plan through the real proc, so any drift in that SQL breaks the test instead of silently falling back to a scan.

### 3. `taskchain_list_dependencies_by_chain` — ADD `(chain_id, owner_user_id, created_at)`

SQL: `SELECT task_id, depends_on_task_id, chain_id, owner_user_id, created_at FROM task_dependencies WHERE chain_id = ? AND owner_user_id = ? ORDER BY created_at ASC;`

| Scale | Variant | VM | Fullscan | Sort | Cold | Warm | Plan |
|---|---|---:|---:|---:|---:|---:|---|
| t1 | before | 2,046 | 569 | 1 | 256 | 225 | `SCAN task_dependencies ; USE TEMP B-TREE FOR ORDER BY` |
| t1 | after | 185 | 0 | 0 | 196 | 176 | `SEARCH … USING INDEX … (chain_id=? AND owner_user_id=?)` |
| prod | before | 5,466 | 1,709 | 1 | 365 | 309 | `SCAN task_dependencies ; USE TEMP B-TREE FOR ORDER BY` |
| prod | after | **185** | **0** | 0 | 194 | 174 | same |

The cost grows with the whole table before the index and with one chain after it.

### 4. `shell_session_list_live_bridge_ids` — NO CHANGE

SQL: `SELECT DISTINCT bridge_id FROM shell_sessions WHERE bridge_id != '' AND status NOT IN (?, ?, ?) ORDER BY bridge_id ASC LIMIT ?;`

| Scale | Variant | Stats | VM | Fullscan | Warm | Plan |
|---|---|---|---:|---:|---:|---|
| prod | before | none | 25,558 | 1,799 | 840 | `SCAN shell_sessions USING INDEX sqlite_autoindex_shell_sessions_1` |
| prod | before | ANALYZE | 17,782 | 1,223 | 605 | same plan |
| prod | `(bridge_id, status)` covering | none | 23,757 | **1,799** | 640 | `SCAN … USING COVERING INDEX` |

The covering index saves 7% VM and leaves the fullscan count unchanged. It also charges every shell upsert, because `status` is assigned on every UPDATE: +10 VM and about +10 page writes per 200 upserts. The scan is structural. `NOT IN` over **bound** parameters cannot drive a seek, and a partial index cannot be matched to bound parameters. Removing the scan would require changing the SQL to a positive set of live statuses, or inlining literals for a partial index. That changes the canonical `SHELL_SESSION_TERMINAL_STATUSES` contract and is outside this task, so it is recorded as a follow-up.

### 5. `content_list_conversations_sqlite` — NO CHANGE

The plan is already index-driven: an owner seek on `idx_search_chat_conversations_owner_lower_title`, then 8 correlated subqueries per conversation, each seeking `idx_chat_messages_conversation_recent`, then a temp B-tree for the ORDER BY. **Fullscan is 0.** The VM cost comes from the subqueries, not from a scan.

| Scale | Variant | VM | Sort | Warm | Size | Write cost |
|---|---|---:|---:|---:|---:|---|
| t1 (60 convs) | before | 46,637 | 1 | 4,734 | — | — |
| t1 | `chat_conversations(owner_user_id, <order expr> DESC, conversation_id DESC)` | 44,774 (−4%) | 0 | 4,591 | 4 KB | conv save +20 VM/save |
| t1 | `chat_messages(conversation_id, owner_user_id, direction, created_at DESC, message_id DESC)` | 40,577 (−13%) | 1 | 3,921 | 549 KB | msg insert +9 VM, page writes 60→112 per 200 |
| prod (300 convs) | before | 173,317 | 1 | 16,802 | — | — |
| prod | order-expression index | 110,814 (−36%) | 0 | 13,610 | 20 KB | conv save +20 VM/save |
| prod | message covering index | 155,017 (−11%) | 1 | 14,608 | 1.4 MB | msg insert page writes 69→121 per 200 |

- **Order-expression index.** It pays off only when an owner has more conversations than the call's LIMIT; only then does ordered index access skip the subqueries for the cut rows. The callers use limits of 200, 256 and 512. The production conversation count is unknown, and at or below the limit the gain is about 4%. The index also adds +20 VM to every conversation save, which happens on every message. With no production cardinality to show that the gain applies, it is not shipped. To revisit, the user can run a read-only `SELECT owner_user_id, COUNT(*) FROM chat_conversations GROUP BY 1` against production. If the count is well above 200, the index is a reasonable follow-up. Task 3's narrower mapping projection removes the subqueries for mapping callers entirely and is the better lever.
- **Message covering index.** It saves 11–13% VM but costs 1.4 MB at the prod shape and nearly doubles page writes on every message insert. Not shipped.
- With `ANALYZE` present, the planner switches the baseline to `SCAN c` (299 fullscan steps at prod). That is another reason not to add `ANALYZE` casually.

## Write amplification of the shipped set (prod shape, 200 rows per phase)

| Workload | No new index VM / page writes | Migration 104 VM / page writes | Per row |
|---|---|---|---|
| Shell insert | 20,000 / 56 | 25,400 / 71 | +27 VM |
| Shell activity upsert | 30,000 / 14 | 36,400 / 18 | +32 VM |
| Shell exit upsert | 30,000 / 15 | 35,400 / 26 | +27 VM |
| Retention DELETE (200 expired) | 35,346 / 54 | 14,668 / 65 | −103 VM |
| Dependency insert (171) | 13,338 / 12 | 14,535 / 20 | +7 VM |
| Conversation save / message insert | unchanged | unchanged | 0 |

Size at the prod shape is 241,664 bytes for all three indexes: 81,920 (kind), 69,632 (retention) and 90,112 (dependencies).

**Read savings against write cost.** The kind and retention reads run on the 20 s reaper timer, 180 calls per hour, and save about 5,600 + 21,500 VM per call. That is roughly **4.9 M VM per hour** at the prod shape. A shell session's three upserts add about 86 VM, so the break-even point is about 56 k shell sessions per hour. Production showed about 140 `POST /bridges/*/shells` per hour (92 in 40 min). Dependency inserts are rare (task publishing) and cost 7 VM per edge.

The page-write deltas are a few pages per 200 rows. They are noisy run to run: unrelated workloads such as message insert vary by ±10 between variants. Treat them as indicative only.

## Shipped migration and tests

- `src/hub/repository/sqlite/migrations/104_full_scan_indexes.sql` contains three `CREATE INDEX IF NOT EXISTS` statements. It is registered in `migrations.odin`: the `MIGRATION_104_FULL_SCAN_INDEXES` constant, the `migration_order` entry (array length 105→106) and the `migration_sql` fallback. Migration **103 is reserved by task 2** (`103_guard_chat_fts_updates.sql`). `migration_order` is a name list, so the number gap is harmless if task 2 lands later. Expect a trivial merge conflict on the array length and the list tail.
- `src/hub/repository/sqlite/full_scan_indexes_test.odin` adds three tests:
  - `test_m104_fresh_database_has_the_indexes`: on a fresh DB, all 3 indexes exist and the ledger records 104.
  - `test_m104_upgrade_is_idempotent_and_keeps_rows`: migrates to the pre-104 schema with `stop_before`, seeds a shell row, upgrades, and checks that the indexes exist and the row survives. A second `run_migrations` and a direct re-exec of the SQL are both no-ops. A simulated partial apply (one index dropped, ledger row deleted) is repaired.
  - `test_m104_repository_reads_plan_onto_the_indexes`: captures the SQL that the real `list_live_by_kind`, retention DELETE and `list_dependencies_by_chain` procs prepare. It asserts `SEARCH … USING INDEX idx_…` and that no plan contains `SCAN` or `TEMP B-TREE`.
- `verify-sqlite-index.sh` runs four steps:
  1. The scoped sqlite package tests: the migration-104 tests, `migrations_test.odin`, `shell_session_repo_test.odin` and `taskchain_repo_test.odin`, 56 tests in total.
  2. The index harness at t1 scale, including its result-equivalence assertions.
  3. Task 1's `verify-baseline.sh`.
  4. The Hub build.

## Boundaries and open items

- Local-fixture numbers only. These results make no claim about production latency.
- The production row counts are inferred (shells) or assumed (conversations, dependencies). Re-run `sqlite_index_eval <db> prod` after changing the `Scale` values in the harness if better counts become available.
- `list_dependencies_by_chain` orders only by `created_at`. Rows with equal `created_at` were unordered by SQL contract before the change and still are. The fixture uses distinct values, so the equality assertion does not cover tie order.
- Task 2's same-row upsert guard only reduces the index-maintenance cost measured here, because skipped writes maintain no index. The two changes do not interact otherwise.
