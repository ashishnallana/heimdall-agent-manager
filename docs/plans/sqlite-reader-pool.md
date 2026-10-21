# SQLite: typed query layer, isolated writers and a reader pool

Status: plan, revision 2 (after review), ready to implement. Branch `perf/sqlite-reader-pool`,
base `e12b9554` (v0.4.21). No code has landed. Findings marked **(found)** come from the code
audit or the reverted first attempt. The "Review response" section at the end maps each review
finding to where this revision addresses it.

## 1. Problem

- **Throughput.** Every query from every request thread runs on ONE shared connection
  (`App_Graph.db`, `repository/sqlite/conn.odin`), and in serialized mode SQLite holds that
  connection's mutex for each `sqlite3_step`. About 99% of statements are reads (prod: ~130–290
  SELECT/s against ~0.15 COMMIT/s). WAL has been on since v0.4.17, but one connection cannot read
  in parallel. Capacity is about 50–60 active users.
- **Correctness (lost write).** An autocommit statement from thread B runs INSIDE thread A's open
  unit of work. It commits or rolls back with A, and B sees A's uncommitted rows. Only taskv2,
  taskchain (`verb_begin`) and `accept_card` open units of work, so almost every write is exposed
  (§9.1).
- **Misuse-prone API.** About 217 `sqlite3_prepare_v2` sites in 28 files, each with a manual
  `defer sqlite3_finalize`, positional `bind_text` calls and rc-integer checks. Any failed step is
  reported as `.Conflict`, so a busy or I/O failure looks like a user conflict.

## 2. Principles

1. Restructure first, change concurrency last. The typed layer and the error model land on
   today's single connection. Write isolation and then readers are switched on later, each behind
   its own kill switch.
2. Callers never choose a connection and never touch statements or handles.
3. No lock that a unit of work can take may be held around an autocommit write (B2). This
   generalises the existing `tx_mutex → state_mutex` rule.
4. Nothing blocks on `tx_mutex` while it holds another tracked lock (B3).

## 3. Architecture (end state)

```
services ──iface.*_Repository (domain structs, Domain_Error)──▶ repositories (SQL constants only)
                                     │ query_one / query_all / query_each / exec_write / with_write_tx / Sql_Builder
                                     ▼
              db.odin   typed layer: Arg binding, struct scan, Db_Result, statement FFI (file-private)
              conn.odin opaque Conn, routing, reader leases, overflow conn, tripwire, connection FFI (file-private)
              tx.odin   unit of work (BEGIN IMMEDIATE on writer), with_write_tx
```

### 3.1 Connections

| Connection | Exists when | Opened as | Used by |
|---|---|---|---|
| `writer` | always | read/write | the unit-of-work owner, `with_write_tx` bodies, migrations at boot; everything when split is off |
| `autocommit` | `HAM_SQLITE_WRITE_SPLIT=1` | read/write | writes outside a unit of work. A write is prepare → step → finalize in one call under that connection's db mutex, never streamed. **Never reads (M3).** |
| `readers` ×N | split on and `HAM_SQLITE_READERS=N>0` | `SQLITE_OPEN_READONLY` | read-only statements outside a unit of work, leased per thread inside one layer call |
| `overflow` | readers on | `SQLITE_OPEN_READONLY`, serialized, shared | reads when a thread has no free lease slot, a reader fails to prepare, or the pool wait exceeds 50 ms (M4) |

- **`:memory:` and dedicated connections.** `:memory:` is always writer-only. The dedicated
  connections pass options: billing, `Bridge_Enroll_Commit_Conn` and `Vault_Directory_Write_Conn`
  use `{split = false, readers = 0}`. The metrics collector uses
  `{split = false, readers = 0, query_only = true, busy_timeout_ms = 1000}`; today it sets those
  pragmas itself (`app/metrics_db_collectors.odin:93-94`).
- **`Conn :: struct { _state: rawptr }`.** **(found)** A field whose type is file-private can
  still be read from other files in Odin, so only an opaque pointer hides the handles. The state
  is heap-allocated, so copying a `Conn` (`graph.db = db`) is safe.
- **Readers require WAL.** `open` checks `PRAGMA journal_mode` and turns readers off if the file
  is not in WAL mode. **(found)** Under a rollback journal, a reader's SHARED lock blocks the same
  thread's next write.

### 3.2 Routing (inside the layer; no API takes a read/write flag)

1. **Owner.** The calling thread owns the unit of work or the `with_write_tx` on this Conn's
   writer (`tx_depth > 0 && owner == me && tx_writer == this writer`): run on `writer`, so it
   reads its own writes. **(found)** `current_thread_id` is a `gettid` syscall, so `tx_depth` is
   loaded first.
2. **Split off.** Run on `writer`; this is today's behaviour.
3. **Read-only.** The leading keyword is `SELECT`, `WITH` or `VALUES` and `sqlite3_stmt_readonly`
   confirms it: run on the thread's leased reader, else on `overflow`.
   **(found)** `stmt_readonly` is also true for BEGIN, COMMIT, SAVEPOINT, RELEASE, ATTACH and most
   PRAGMAs, so the keyword gate runs first. The scanner honours `nByte`, because Odin strings are
   not NUL-terminated.
4. **Everything else.** Run on `autocommit`.

### 3.3 Reader leases (scoped inside one layer call, M6)

- **Acquire.** `query_one`, `query_all` and `query_each` take the thread's lease at entry and
  release it before returning. There is no streaming statement, no statement outlives the call,
  and nothing leaks across scopes.
- **Re-entry.** A `query_each` callback that issues another query on the same thread reuses the
  lease (refcount); it never waits on the pool.
- **Pool wait.** Bounded at 50 ms, then the read goes to `overflow`. This breaks any
  `state_mutex` / pool / `tx_mutex` wait cycle (M4).
- **Snapshots (documented).**
  - A nested query inside a `query_each` callback shares the outer statement's read transaction,
    so it sees the same snapshot.
  - Separate top-level calls get separate snapshots, as today.
  - A unit-of-work owner sees its own uncommitted writes.
  - Nobody else sees uncommitted rows. Signal other threads with after-commit hooks.

### 3.4 Write transactions

- **Unit of work.** `BEGIN IMMEDIATE` on `writer`. `tx_mutex`, SAVEPOINT nesting, after-commit
  hooks and the lock-order assert are unchanged.
- **`verb_begin` fails closed (M1).** It currently returns an empty `Verb_Tx` and the verb runs
  without a transaction (`taskchain_service.odin:60-65`). Stage 0 makes it return `.Unavailable`
  instead.
- **`with_write_tx(conn, ctx, body: proc(ctx) -> bool) -> Db_Result`** is the ONLY way to run a
  hand-rolled multi-statement transaction outside a unit of work. It replaces the implicit
  detection of a leading `BEGIN`. It takes the unit-of-work slot (lock-order assert, `tx_mutex`),
  runs `BEGIN IMMEDIATE` on `writer`, runs the body (whose statements route to `writer` as owner),
  then COMMITs, or ROLLBACKs if the body returns false.
  - Users: `bridge_commit_enrollment` and the vault writers when they fall back to the main Conn,
    and the reaper's FTS repair.
  - Billing, enrollment and vault keep their dedicated connections and use
    `with_write_tx` on those Conns, which have split off.
- **FTS self-heal never blocks on `tx_mutex` (B3).**
  - On `SQLITE_CORRUPT` from a write, the layer tries `tx_mutex` with `try_lock`, and only when
    the thread holds no tracked lock (`lockorder` depth 0). If it succeeds, it repairs inline and
    retries once.
  - Otherwise it returns `Corrupt` and sets a repair-pending flag. The reaper (20 s) runs
    `repair_fts_indexes` through `with_write_tx`.
  - Today's 5 healing sites keep that behaviour. Other writes report Corrupt and the reaper
    repairs (Q4).
- **Migrations (one rule).** At boot, before any request thread exists, each migration file runs
  through one `exec` on `writer`. **(found)** 090, 097, 098 and 099 contain `BEGIN … COMMIT`, and
  099 creates a TEMP table, which is per connection. Both are fine because the whole script runs
  on the same connection. If `exec` fails and `get_autocommit(writer) == 0`, the layer issues
  `ROLLBACK` before returning the error.
- **Existing bug (corrected statement).** Today `repair_fts_indexes` runs `BEGIN IMMEDIATE …
  COMMIT` on the shared handle without `tx_mutex` (`fts_repair.odin:56-71`), reached at runtime
  from `step_write_healing` on the per-heartbeat instance save path. While its transaction is open:
  - a unit-of-work `BEGIN` on another thread fails ("cannot start a transaction within a
    transaction")
  - other threads' autocommit writes join the repair transaction and commit or roll back with it

  Conversely, if a unit of work is open, the repair's BEGIN fails and its error-path `ROLLBACK`
  (`:65`) rolls back that unit of work. `with_write_tx` plus reaper-only repair closes all three.

### 3.5 Pragmas: single source in `open()`

**(found)** Today these are set in `app/wiring.odin:192-199`, and duplicated in
`bridge_repo_sqlite.odin:34`, `vault_directory_repo_sqlite.odin:38`, `billing_repo_sqlite.odin:46`
and the `tmpl_open_file_prod` test fixture.

| | foreign_keys | busy_timeout | journal | synchronous | other |
|---|---|---|---|---|---|
| writer | ON | 5000 | WAL (file DBs) + `journal_size_limit=64MB` | NORMAL | |
| autocommit | ON | 5000 | file-level | NORMAL | |
| readers / overflow | ON | 5000 | file-level | — | `query_only`, `cache_size=-4000`, mmap off (Q5) |

- **WAL growth.** Long readers delay checkpoints. The reaper runs `wal_checkpoint(PASSIVE)` each
  pass, and `TRUNCATE` when `heimdall_sqlite_wal_bytes` exceeds 256 MB.
- **Global malloc mutex (found).** `SQLITE_CONFIG_MEMSTATUS` is on by default, which puts one
  global mutex on every SQLite malloc. The test fixture already turns it off after an RCA showed
  it serialized parallel tests. Parallel readers would hit the same mutex, so conn.odin turns it
  off in `@(init)` for all builds; nothing reads SQLite memory statistics.

## 4. Typed query layer (`repository/sqlite/db.odin`)

```odin
Null :: struct {}
Arg  :: union { string, i64, int, f64, bool, Null }   // bool binds TEXT "1"/"0" (today's storage); nil binds NULL
opt_text :: proc(s: string) -> Arg                     // "" -> NULL (vault's bind_opt behaviour)

Db_Error_Kind :: enum { None, Unique_Violation, Foreign_Key_Violation, Constraint_Violation,
                        Busy, Read_Only, Corrupt, Io, Internal }          // no Not_Found (M9)
Db_Result :: struct { kind: Db_Error_Kind, ext: i32, message: string }     // message: sqlite3_errmsg, logs only

query_one  :: proc(conn: ^Conn, $T: typeid, sql: string, args: ..Arg) -> (row: T, found: bool, res: Db_Result)
query_all  :: proc(conn: ^Conn, $T: typeid, sql: string, args: ..Arg) -> ([]T, Db_Result)          // context.allocator
query_each :: proc(conn: ^Conn, $T: typeid, sql: string, ctx: rawptr, each: proc(ctx: rawptr, row: ^T) -> bool, args: ..Arg) -> Db_Result
exec_write :: proc(conn: ^Conn, sql: string, args: ..Arg) -> (changes: int, res: Db_Result)
exec_script:: proc(conn: ^Conn, sql: string) -> Db_Result                 // DDL / migrations only (guard-test restricted)
with_write_tx :: proc(conn: ^Conn, ctx: rawptr, body: proc(ctx: rawptr) -> bool) -> Db_Result
```

- **Struct scanning.** Columns map to fields by the `db:"col"` tag, falling back to the field
  name. Supported field types:
  - `string` (cloned into `context.allocator`, as `column_text` does today)
  - `Maybe(string)` (NULL → nil)
  - `i64`, `int`, `i32`, `f64`
  - `bool` (`"1"` text or integer 1)
  - distinct string ids
  - enums through `register_enum_text($E, from_string)`, because enums are stored as text

  Behaviour:
  - Fields tagged `db:"-"` are skipped.
  - Domain structs with derived or JSON fields use a flat `*_Row` struct plus a converter.
  - The column-to-field plan is validated once per `(typeid, sql data pointer)` and kept in a
    GLOBAL heap cache behind an RW mutex (not thread-local), so the per-row cost is typed column
    reads only.
  - Missing columns, unmatched fields and unsupported types are programmer errors: tests and
    debug panic; release returns `.Internal` and logs.
- **Binding preserves storage types (found).** Repos bind most integers as TEXT
  (`bind_text(i, int_s(x))`). The migration binds exactly what was bound before: a `string` Arg
  for those, and `bool` as `"1"`/`"0"`. Native types are a follow-up.
- **`exec_write`.** `changes` is read under the statement's own connection mutex (today's
  `step_changes`, now with `sqlite3_db_handle(stmt)`). A statement that returns rows is a misuse
  and returns `.Internal`; use `query_one` for `RETURNING`.
- **Dynamic SQL: `Sql_Builder` (M8).** **(found)** Today dynamic SQL is built with
  `strings.Builder`:
  - `content_repo_sqlite.odin:246-259`, including `ORDER BY` from `sort_col`/`sort_dir`
  - `issue_repo_sqlite.odin` (10 `write_string`)
  - `shell_session_repo_sqlite.odin` (48 `write_string`, 9 builders)
  - `bridge_log_repo_sqlite.odin:53` (batch VALUES)

  Replacement:
  ```odin
  sb := sql_builder(context.temp_allocator)
  sql_frag(&sb, "SELECT … FROM artifacts WHERE owner_user_id = ?")   // $frag: string — compile-time constant only
  sql_arg(&sb, string(owner))
  if kind != "" { sql_frag(&sb, " AND kind = ?"); sql_arg(&sb, kind) }
  sql_order_by(&sb, Artifact_Sort.Created_At, .Desc)                 // identifiers only via enums with a fixed SQL spelling
  sql_in(&sb, " AND bridge_id IN ", ids)                             // emits (?, ?, …) + args
  rows, res := query_all_built(impl.conn, Artifact_Row, &sb)
  ```
  Because `sql_frag` takes `$frag: string`, a runtime string cannot be passed. Values only ever
  enter as args. The guard test flags `strings.builder*`, `write_string`, `fmt.*printf` and
  `concatenate` in repository files. Constant fragments become compile-time constants
  (`Q :: "SELECT " + COLS + " FROM …"`).
- **Performance.** Args are a stack slice, and scanning allocates only the string clones repos
  make today. `query_each` with a `^T` scratch row avoids the slice for hot loops. The plan cache
  makes reflection a one-time cost.

### Before / after

```odin
// GET — before (project_repo_sqlite.odin)
if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return {}, false, domain.domain_error(.Internal_Error, "failed to prepare project lookup")
defer sqlite3_finalize(stmt); bind_text(stmt, 1, string(project_id))
if sqlite3_step(stmt) != SQLITE_ROW do return {}, false, domain.domain_error(.Not_Found, "project not found")
return project_from_stmt(stmt), true, {}

// GET — after (per-method not-found behaviour kept: this method returned .Not_Found, so it still does)
row, found, res := query_one(impl.conn, Project_Row, PROJECT_GET_SQL, string(project_id))
if res.kind != .None do return {}, false, db_error(res, "project lookup", .Internal_Error)
if !found do return {}, false, domain.domain_error(.Not_Found, "project not found")
return project_from_row(row), true, {}

// LIST
rows, res := query_all(impl.conn, Project_Row, PROJECT_LIST_SQL, string(owner), i32_to_string_sqlite(limit))
if res.kind != .None do return nil, db_error(res, "project list", .Internal_Error)

// SAVE (unique conflict)
args := project_args(project)                                        // [11]Arg on the stack
_, res := exec_write(impl.conn, PROJECT_UPSERT_SQL, ..args[:])
if res.kind != .None do return {}, false, db_error(res, "project could not be saved", .Conflict)
// Unique_Violation -> .Conflict (kept); Busy -> .Unavailable; Io/Corrupt -> .Internal_Error.
```

## 5. Error model

- **`Db_Error_Kind` from `sqlite3_extended_errcode`:**

  | Extended code(s) | Kind |
  |---|---|
  | `CONSTRAINT_UNIQUE`, `CONSTRAINT_PRIMARYKEY` | Unique_Violation |
  | `CONSTRAINT_FOREIGNKEY` | Foreign_Key_Violation |
  | `CONSTRAINT_NOTNULL`, `CHECK`, `TRIGGER` | Constraint_Violation |
  | `BUSY*`, `LOCKED*` | Busy |
  | `READONLY*` | Read_Only (a routing bug: logged, counted, `.Internal` to callers) |
  | `CORRUPT*` | Corrupt |
  | `IOERR*`, `FULL`, `CANTOPEN` | Io |
  | anything else | Internal |

  Nothing branches on message text.
- **One mapper with a per-call default (Q2):** `db_error(res, msg, constraint_default:
  Error_Code) -> domain.Domain_Error`.

  | Kind | Domain code |
  |---|---|
  | Unique_Violation | `.Conflict` |
  | Foreign_Key_Violation, Constraint_Violation | `constraint_default` (the site's established code, so tests and clients keep theirs) |
  | Busy | `.Unavailable` |
  | everything else | `.Internal_Error` |

  - `message` keeps the site's existing user-facing text.
  - `cause` gets a schema-free token (`sqlite_unique`, `sqlite_busy`, `sqlite_io`, …).
    **(found)** `Domain_Error.cause` is relayed on the wire (`contracts/errors.odin`), so no raw
    SQLite text and no table or column names go there. The full message is logged server-side.
  - **Fixed:** a busy or I/O failure no longer reports as `.Conflict`.
- **`.Unavailable`** = `{"unavailable", .retriable, 503}`, APPENDED at the end of
  `contracts.Error_Code` so existing ordinals do not shift.
  - The table is exhaustive and compile-checked.
  - Build `src/bridge` and `src/ctl`, which share contracts.
  - Older peers parse the unknown name as `Internal_Error`.
  - **UI note:** `src/ui/hooks/useShellPaneSubscription.ts:174,268` treats any 503 as "bridge
    unreachable", so a DB-busy 503 on that endpoint would show as unreachable. Acceptable; flagged
    for the UI owner.
- **Not-found stays per method (M9, Q1).** `query_one` reports `found`; there is no Not_Found
  kind. Each migrated method keeps exactly its current contract:
  - methods that returned `.Not_Found` errors keep returning them
  - methods that returned `found = false` with no error keep doing that

  **(found)** Callers branch on this, for example `card_projector.odin:130/472/576` (`!found &&
  code != .Not_Found`), 15 production comparisons and about 88 including tests.
- **Save/delete convention.** `ok == (err.code == .None)`, documented in iface. Signatures do not
  change.

## 6. Guardrails

1. **Hidden handles and private FFI.**
   - Connection FFI is `@(private="file")` in conn.odin under `ffi_*` names.
   - Statement FFI (bind, column, step, reset, sql, extended_errcode) is `@(private="file")` in
     db.odin. Duplicate file-private foreign declarations are allowed.
   - **(found)** Where the FFI that exists outside these two files today goes:
     - `sqlite_metrics.odin`: its `sqlite3_step`/`sqlite3_exec` wrappers move to db.odin and
       conn.odin. It keeps `sqlite_metrics_record` and the collectors.
     - `sqlite_file_size_*.odin`: plain OS stat, no SQLite FFI, unchanged.
     - `migrations.odin` and `fts_repair.odin`: switch to `exec_script`, `query_*`,
       `with_write_tx` and `Sql_Builder` (table names via an enum of the FTS tables).
     - The test template fixture: uses `conn_copy_database` (backup API in conn.odin). Its
       `sqlite3_config` moves into conn.odin's `@(init)`.
2. **No statement escapes a layer call**, so there is nothing to finalize or leak (M6). The
   streaming iterator, the live-statement table, the double-finalize guard and leak recovery from
   revision 1 are dropped.
3. **Routing is never the caller's decision** (§3.2).
4. **Runtime tripwires.**
   - **One assert, `lockorder.assert_db_thread_clean(site)`**, at the end of `handle_client` and
     at the end of each long-lived loop iteration (§9.3). It checks that the thread holds no
     reader lease and no unit of work.
   - **New tracked-lock rule (B2).** `lockorder` tracks `state_mutex`, `projector_mutex` and every
     other lock the §9.2 audit marks. A debug tripwire fires on "autocommit write while holding a
     tracked lock", and on "unit-of-work owner writing through a different Conn on the same file"
     (M2).
   - Release builds log and count violations
     (`heimdall_sqlite_lock_rule_violation_total{rule}`); tests and debug builds panic.
5. **Source-guard test (`api_guard_test.odin`).** It scans `src/hub/**.odin` with comments
   stripped and fails with a "use X instead" message on:
   - `sqlite3_`, `ffi_`, `._state` or `foreign import` outside conn.odin, db.odin and tx.odin
   - an import of the sqlite package outside `repository/sqlite`, `app/wiring.odin`,
     `app/metrics_listener.odin`, `app/metrics_db_collectors.odin` and `*_test.odin`
   - in repository files, `strings.builder`, `write_string`, `fmt.*printf` or `concatenate` on
     anything SQL-like, and `exec_script` outside migrations and fts_repair

   It includes a self-test on fixture snippets that must trip each rule.
6. **Docs.** Header comments in conn.odin and db.odin, and an AGENTS.md "Database access rules"
   section (§12).

## 7. Stages, flags, effort

| # | Stage | Content | Flags / behaviour | Effort |
|---|---|---|---|---|
| 0 | Lock hygiene + measurement (today's single connection) | **B1:** per-connection `persist_mutex` (§9.2). **B2:** projector fix + `lockorder` tracking of `projector_mutex` + audit worklist. **M1:** `verb_begin` fails closed. **M2:** throttle `last_used` writes (`auth_service.odin:454-457`, at most once per 60 s per token); add `heimdall_sqlite_uow_hold_seconds` and collect a week of prod data before stage 4. | none; ships alone | 2–3 d |
| 1 | `db.odin` + error model | layer, scanner, `Sql_Builder`, `with_write_tx`, `db_error`, `.Unavailable` (contracts + bridge/ctl build), metrics collector options, tests §8 (layer, errors, scanner) | single conn, no routing change | 3 d |
| 2 | Migrate repositories in batches (below) | every site to the layer; storage-type parity test per batch; `app/metrics_db_collectors.odin` and `taskv2/mixed_work_test.odin` included. **(found)** Both use `conn.db` directly, contradicting the original plan's "nothing outside the package touches it". | single conn | 4–5 d |
| 3 | Lock down | opaque `Conn`, file-private FFI, guard test, tripwire assert at end of `handle_client` + loops, AGENTS.md | single conn | 1 d |
| 4 | Write split | `autocommit` connection, `BEGIN IMMEDIATE`, FTS heal via try-lock/reaper, pragmas in `open()`, WAL checkpointing, test fixture mode (M7) | `HAM_SQLITE_WRITE_SPLIT` (default on after canary) | 1.5 d |
| 5 | Readers | pool, scoped leases, overflow conn, bounded wait, lease metrics, benchmark | `HAM_SQLITE_READERS=N` (honoured only with split on) | 1.5–2 d |
| 6 | Benchmark report + rollout | numbers in this doc | | 0.5 d |

**Total: about 13–16 days.**

**Stage 2 batches** (each a commit, each followed by the sqlite suite plus the owning service
suite):

| Batch | Files |
|---|---|
| 2a | user, project, provider, lsp_server_config, experiment, push, conversation_launch_preferences |
| 2b | agent, content, card, attention, issue |
| 2c | taskchain, taskv2, mixed_work, workflow_run, action, instance_reconfiguration |
| 2d | bridge, bridge_token, bridge_log, shell_session, vault_directory, billing |
| 2e | search, search_fts, fts_repair, migrations, test fixtures |

The old API stays usable until stage 3, so every commit builds.

**Rollout.**
1. Stage 0 ships alone; read `uow_hold_seconds` for a week.
2. Stage 4 on a canary with `HAM_SQLITE_WRITE_SPLIT=1`, then default on.
3. Stage 5 with `HAM_SQLITE_READERS=4`.

`HAM_SQLITE_READERS=0` turns readers off. `HAM_SQLITE_WRITE_SPLIT=0` turns both off, which is
exactly today's single connection. Neither needs a rebuild.

## 8. Tests

All tests use temp-file DBs under TMPDIR, removed together with `-wal`/`-shm`.

- **Layer (stage 1)**
  - `db_scan_test.odin`:
    - tags and field-name fallback
    - Maybe with NULL
    - bool from `"1"` and from 1
    - enum converter
    - missing column and wrong type panic
    - plan cache hit
    - `Sql_Builder` rejects a non-constant fragment (compile-time; documented, not runtime-tested)
  - `db_errors_test.odin`:
    - unique, FK, NOT NULL and CHECK map to their kinds
    - Busy: a second Conn holds `BEGIN IMMEDIATE`, the first has a short busy_timeout (test
      seam)
    - every kind maps through `db_error`
  - **(found)** `test_sqlite_busy_counter_on_lock_contention` relies on the second connection
    having NO busy_timeout. It needs the same seam, or it will take 5 s once `open()` sets 5000.
- **Stage 0**
  - stale generation after reconnect: an old connection's delayed status frame cannot overwrite
    the new generation's state, and retire waits for in-flight persists (B1)
  - a heartbeat during an open unit of work does not stall
  - projector under a unit of work, with a concurrent non-UoW projection
- **Stage 2:** a storage-type parity test per batch. For each table a batch writes, compare
  `SELECT typeof(col)…` from rows written by the new code with a snapshot captured from the base
  commit.
- **Stage 4/5 (`conn_pool_test.odin`)**
  - lost-write regression: B's autocommit write survives A's rollback
  - B does not see A's uncommitted row and does not block on `tx_mutex`
  - read-your-writes with nested savepoints
  - nested `query_each` re-entry uses one lease
  - N+3 readers finish (overflow after 50 ms)
  - `exec_write` changes are per statement under concurrent writers (ported `step_changes` test)
  - `with_write_tx` commit and rollback
  - BEGIN, SAVEPOINT, PRAGMA and `WITH … INSERT` never land on a reader
  - corrupt-heal with a tracked lock held queues to the reaper instead of blocking
  - flags off equals today's behaviour
- **Fixture mode (M7).** A test define switches the shared fixtures to temp-file DBs with split
  on and 4 readers. Run taskv2, transport/http and app in that mode as well as the default
  `:memory:` mode.
- **Guard** (§6.5) and the **benchmark** (`db_bench_test.odin`): agent list, about 30 columns ×
  200 rows, before (base commit) and after. Measure ns/row and allocations per row,
  single-threaded and with 4 threads.
  - Targets: within 10% single-threaded; parallel throughput at or above 3× with 4 readers.
- **Suites.** Run one at a time with `-define:ODIN_TEST_THREADS=2`: sqlite, taskv2,
  service/bridge, transport/http, app and contracts, plus builds of `src/hub`, `src/bridge` and
  `src/ctl`. Compare any failure against `origin/main` in a separate worktree.

## 9. Inventories (from the code audit)

### 9.1 Autocommit write paths (they wait on busy_timeout behind a unit of work once split is on)

Units of work exist only in `card_service.odin:912` (`accept_card`), `taskv2/service.odin:229`
(`begin_uow`, including the timer thread and merge jobs) and `taskchain_service.odin:62`
(`verb_begin`). Every other repository write is autocommit. HB = bridge heartbeat (45 s).

| Area | Representative callers → repo proc | Thread | Frequency |
|---|---|---|---|
| Bridge row | `bridge_service.odin:274` capabilities, `:405` vault status, `:230` connect, `:251` offline, `:971` update progress → `bridge_save_bridge` | WS reader | per HB with capabilities; per connect, disconnect or frame |
| Agent instances | `agent_service.odin:1232/1256` `reconcile_bridge_heartbeat`, `:1103/1161` status report, `:1379` `reap_stale_instances`, `:1325` unreachable; `instance_failure.odin:109`; `instance_reconfiguration.odin:133/142/391` → `agent_save_instance` (healing) | WS reader, reaper (20 s), HTTP | **per HB × active instances** |
| Bridge logs | `bridge_log_service.odin:119` `insert_batch`, `:132` cap, `:145` prune, `:166` delete | bridge_log writer (1 s or 512 rows), reaper (15 min), HTTP | continuous |
| Push | `push_service.odin:82/103`; `webpush_send.odin:216` | HTTP, push worker | per subscribe or dead endpoint |
| Shell sessions | `shell_session_inventory.odin:479/542/579`, `shell_session_service.odin:1879/2258/1058`, retention `:59` | WS reader, reaper, HTTP | per frame or exit; 20 s |
| Chat / content | `content_service.odin:213-216` (message + conversation + title nudge + attention), `:244/249` pane capture | HTTP, WS | per message |
| Cards / attention | `card_projector.odin:588/598` (synchronous on the source writer's thread; reaper reconcile); `card_service.odin:430/477/654/696` (**writes on list/GET**) | HTTP, WS, reaper (10 min) | per event or list |
| Taskchain (outside `verb_begin`) | `taskchain_service.odin:465/479/583/1496/1527/1661/1795/1824/1834`, comments `:1260/1405` | HTTP | per action |
| Auth | `auth_service.odin:457` `user_token_save` (`last_used`, **unthrottled**; throttled in stage 0) | HTTP | every `hut_` request |
| Bridge tokens / enrollment | `bridge_token_service.odin:205/222/443/462/483`; `bridge_device_enroll.odin:144-240`; `bridge_enroll_pending.odin:115/149/164`; reaper `sweep_expired_enrollments` | HTTP, reaper | per enroll or refresh |
| Other HTTP CRUD | users, launch prefs (healing), projects, issues, providers, experiments, LSP config, actions | HTTP | per request |
| Boot | `lease.odin:508` `grant_boot_lease_grace` | main | once |
| Own connection (unchanged) | billing (`get_account` also writes), `bridge_commit_enrollment`, every vault write (incl. `touch_last_seen` per signed GET) | — | — |

Follow-up candidate: batch the per-HB instance `last_seen_at` writes into one statement.

### 9.2 Locks held around DB writes (B1, B2), and the stage 0 fixes

The rule: no lock that a unit-of-work body can take may be held around an autocommit write.

| Lock | Sites | Why it matters | Fix |
|---|---|---|---|
| `Bridge_Runtime_Connection.state_mutex` (`runtime_registry.odin:709`) | handshake `bridge_handlers.odin:1688` (get + `save_bridge`); disconnect `:1803` (offline + per-instance `agent_save_instance`); status `:2444` (`agent_get/save_instance`, **every HB**) | **(B1, verified)** The lock serialises durable writes with retirement: `bridge_runtime_connection_retire` (`runtime_registry.odin:223-226`) sets `retired` then waits on `connection_state_lock`, and the comment at `bridge_handlers.odin:2440-2442` relies on it, so "write after unlock" would let a stale generation save over a new one. A UoW holder (matcher JIT, `agent_service.odin:276` → `bridge_runtime_instance_apply`) takes `state_mutex` while holding the write lock → 5 s stall then Busy once split is on. | New per-connection **`persist_mutex`**, taken by the three write sites and by retire, never by a UoW. `state_mutex` guards only the in-memory map. Order: `persist_mutex → sqlite write lock` and `persist_mutex → state_mutex`. Writes check `retired` under `persist_mutex`. Test: stale generation after reconnect. |
| `Card_Service.projector_mutex` (`card_projector.odin:124/376/467`) | held across task reads and card `insert_if_absent`/`compare_and_set` | **(B2, verified)** Reached INSIDE units of work (taskchain verbs → `save_task`/`save_comment` → `attention_notify` → `project_task_card`, synchronous) and also on non-UoW threads around autocommit writes. Non-UoW holder waits for the write lock; the UoW waits for `projector_mutex` → 5 s stall then Busy. | Projection inside a unit of work is deferred to an after-commit hook (the notifier enqueues; the hook projects after `tx_mutex` is released). `projector_mutex` joins `lockorder` tracking, so the debug tripwire catches any regression. |
| Audit worklist (stage 0) | `agent_service.reconfiguration_mutex`, `user_service.launch_preferences_mutex`, `taskv2 Service.state_mutex`, `taskv2 timers.mutex`, `vault_directory service.mutex`, `action_handlers` mutex, `shell_session_service` `mu`/`tunnel_mu`/`viewer_write_mu` | not yet audited against the rule | Classify each: (a) never held around DB access, (b) held around autocommit writes but never taken by a UoW body (allowed; document), or (c) violates → fix like `projector_mutex`. Record results here. |

### 9.3 Tripwire points (one assert each)

| Thread | Check point |
|---|---|
| HTTP | `handle_client` end (`transport/http/server.odin`, after `write_http_response` :144) |
| Bridge WS | per frame (`bridge_handlers.odin:1935` loop, after :1963 and on the binary `continue` :1952) |
| User WS | `user_handlers.odin:157` |
| Agent pane WS | `agent_instance_handlers.odin:228` |
| Shell pane WS | `shell_session_handlers.odin:198` |
| Reaper | `app/reaper.odin:118` |
| taskv2 timer | `taskv2/timers.odin:471` |
| Merge job | `taskv2/merge.odin:107` |
| Webpush | `push/webpush_send.odin:97` |
| bridge_log writer | `bridge_log_service.odin:203` |
| Attention debouncer | `events/attention_debouncer.odin:79` |
| Shell kill replay | `shell_session_service.odin:1174` |
| Pane viewer writer | `pane_viewer_writer.odin:72` |

## 10. Metrics

- **Existing families use the `heimdall_` prefix (found).**
- `heimdall_sqlite_query_duration_seconds` gains `{conn = writer|autocommit|reader|overflow}`.
- **New:**
  - `heimdall_sqlite_uow_hold_seconds` (stage 0)
  - `heimdall_sqlite_reader_leased`
  - `heimdall_sqlite_reader_wait_seconds`
  - `heimdall_sqlite_reader_overflow_total`
  - `heimdall_sqlite_lock_rule_violation_total{rule}`
  - `heimdall_sqlite_fts_repair_total{mode = inline|reaper}`
- **Watch:** `busy_total`, `uow_hold_seconds` p99, reader wait p99, the 503 rate, `wal_bytes`,
  and RSS (readers start at 4 MB of cache each, no mmap).

## 11. Gotchas (found)

- **`sqlite3_changes` is per connection.** `exec_write` must use the statement's own handle.
- **`bind_text("")` binds an empty string, not NULL.** Only vault's `bind_opt` binds NULL. Keep
  both (`Arg` string vs `opt_text`).
- **`column_text` clones; `column_text_unowned` borrows.** Scan into `string`; parse-only fields
  use typed columns.
- **A UoW owner writing through a dedicated Conn on the same file** (billing, enrollment, vault)
  waits on its own write lock and then fails Busy. None was found; the stage 3 tripwire catches
  new ones.
- **Odin `deferred_out` semantics** were verified on our build, but are no longer needed (M6).
- **`HAM_SQLITE_READERS` parse errors** fall back to the default with a warning.

## 12. AGENTS.md "Database access rules" (draft)

- Repositories call `query_one`, `query_all`, `query_each`, `exec_write` and `with_write_tx`
  with SQL constants and bound `Arg`s. Build dynamic SQL only with `Sql_Builder`. Never format
  values into SQL.
- Do not use `sqlite3_*`, handles or statements; `api_guard_test` enforces this.
- Routing is automatic:
  - Inside a unit of work you read your own writes.
  - Outside one, writes autocommit on their own connection and reads come from a pooled snapshot.
  - Signal other threads with after-commit hooks.
- Never hold a unit of work across network I/O.
- Never hold a lock that a unit-of-work body can take around a DB write, and never begin a unit
  of work under a tracked lock.
- Errors: branch on `Db_Result.kind` and convert with `db_error(res, msg, default)`. Keep each
  method's not-found contract.
- New repository method:
  1. Write an SQL constant.
  2. Define a `*_Row` struct with `db` tags (or reuse the domain struct).
  3. Call the layer and map errors.
  4. Add a temp-file DB test, including the storage-type parity check.

## 13. Decisions

Decided 2026-10-21.

- **Q1 Not-found: keep each method's current behaviour** (§5). Changing about 100 callers adds
  risk for no throughput gain. New repository methods follow the documented convention
  (`found=false`, no error).
- **Q2 Constraint mapping: per-call default** (`db_error(…, default)`), so each site keeps its
  current code. Normalising error codes is a separate API change, not part of a storage refactor.
- **Q3 `.Unavailable`: add it, appended at the end of the enum.** Return HTTP 503 with a
  `Retry-After: 1` header and a recoverable class; a busy database is a retryable condition, not
  a conflict or an internal error. Older peers decode it as Internal_Error, which is also
  retryable.
- **Q4 FTS heal: no inline universal heal.** Repair inline only if the try-lock succeeds and the
  thread holds no tracked lock; otherwise queue the repair for the reaper. Count corruption
  events in `heimdall_sqlite_fts_corrupt_total`; a corrupt index should page, not heal silently.
- **Q5 Reader memory: `cache_size=-4000`, mmap off at first.** Raise both after measuring RSS
  and reader hit rate in production.
- **Q6 Lease-leak recovery:** moot, because no statement outlives a layer call.
- **Q7 Dynamic-SQL plan cache:** fine. `Sql_Builder` output is keyed by a fragment hash; scans
  of builder SQL validate per call.
- **Q8 Card projection timing: project after commit.** Register the projection with
  `unit_of_work_after_commit` (the outbox/after-commit pattern). Cards are derived state, the
  reaper already reconciles them, and doing side projections inside the writer's critical section
  is what causes the B2 stall. Add a test that a rolled-back verb produces no card.
- **Q9 UI 503 message: tweak the UI** (small, in stage 2). `useShellPaneSubscription.ts:174,268`
  branches on the error `code` in the body, not the bare status. `unavailable` shows "Hub busy,
  retrying" and retries with backoff; other 503s keep "bridge unreachable". Don't overload one
  message with two causes.
- **Q10 Lock audit: mandatory stage-0 exit criterion.** Audit the nine remaining service mutexes
  against the rule "no lock a UoW body can take may be held around an autocommit write". Each
  violation is fixed in stage 0 (or listed with an owner), and every audited mutex is registered
  with `lockorder` so the debug tripwire covers it. Effort is re-estimated after the audit.

## 14. Review response

Each review finding was verified against the code; none was rebutted.

| Finding | Status | Where in this revision |
|---|---|---|
| **B1** | Verified: `retire` waits on `connection_state_lock` (`runtime_registry.odin:223-226`), and the comment at `bridge_handlers.odin:2440-2442` relies on that serialisation. Chose `persist_mutex` over a generation CAS: one lock, no schema change, and a natural home for the retire wait. | §9.2, stage 0, §8 |
| **B2** | Verified: the projector is reached synchronously from verbs via `attention_notify` (`taskchain/attention_notify.odin:19-28`). | §2 principle 3, §9.2 (fix + audit worklist), §6.4 |
| **B3** | Adopted: try-lock or reaper, and the explicit `with_write_tx`. | §3.4 |
| **M1–M9** | Adopted. | §3.4 (M1); stage 0 + §10 (M2); §3.1 (M3); §3.3 (M4); §7 flags and rollout (M5); stage order + §3.3 + §6.2 (M6); §8 fixture mode (M7); §4 `Sql_Builder` (M8); §5 (M9) |
| **Minor** | All adopted. | §3.4 hazard text and migration rule; §4 global plan cache; §3.3 snapshot doc; §5 cause token and appended `.Unavailable` + UI note; §6.1 FFI destinations (the `sqlite_file_size_*` files have no SQLite FFI); §3.1 metrics collector options; §10 `conn` label; §3.5 `journal_size_limit` + checkpoint; §4 bool binding + §8 parity test; §7 effort 13–16 d |

## Out of scope (follow-ups)

- A prepared-statement cache per connection.
- Native integer storage.
- Batching per-heartbeat instance writes.
- Snapshot/ETag for UI polling endpoints.
- Cached workflow-spec parsing.
