# SQLite reader pool, isolated writers and a typed query layer

Status: plan, ready to implement (branch `perf/sqlite-reader-pool`, base `e12b9554` v0.4.21).
No code has landed yet. A first attempt at stage 1 was reverted so the scope could be widened.
Its findings are folded in below, marked **(found)**.

## 1. Problem

- **Throughput.** Every query from every request thread runs on ONE shared connection
  (`App_Graph.db`, `repository/sqlite/conn.odin`). In serialized mode SQLite holds that
  connection's mutex for each `sqlite3_step`, so request threads take turns. About 99% of
  statements are reads (prod: ~130–290 SELECT/s against ~0.15 COMMIT/s). WAL has been on since
  v0.4.17, but one connection cannot read in parallel. Capacity is about 50–60 active users.
- **Correctness (lost write).** An autocommit statement from thread B, run while thread A
  holds a unit of work (`tx.odin`), executes INSIDE A's transaction. It is committed or rolled
  back with A, and B reads A's uncommitted rows. Only taskv2, taskchain and card open units of
  work (`service/{taskv2/service,taskchain/taskchain_service,card/card_service}.odin`). Every
  other write is autocommit and exposed to this.
- **Misuse-prone API.** 28 repository files call the FFI directly: about 217
  `sqlite3_prepare_v2` sites, a manual `defer sqlite3_finalize` at each one, positional
  `bind_text`, and rc-integer checks. Any step failure is mapped to `.Conflict` ("could not be
  saved"), so a busy or I/O failure looks like a conflict to the user.

## 2. Target architecture

```
services ──iface.*_Repository (typed domain structs, Domain_Error)──▶ repositories (SQL text only)
                                                                         │ query_one / query_all / query / exec_write
                                                                         ▼
                                                   db.odin  (typed query layer: Arg, scanning, Db_Result)
                                                                         │ stmt_prepare / stmt_step / stmt_finalize
                                                                         ▼
                                    conn.odin (opaque Conn, routing, reader pool, tripwires, ALL conn FFI)
                                    tx.odin   (unit of work, BEGIN IMMEDIATE on writer)
```

### 2.1 Connections behind one opaque `Conn`

| Connection | Count | Opened as | Used by |
|---|---|---|---|
| `writer` | 1 | read/write | the thread that owns the unit of work (BEGIN IMMEDIATE … COMMIT), manual transactions (§2.3), migrations |
| `autocommit` | 1 | read/write | write statements outside a unit of work |
| `readers` | N (default 4, `HAM_SQLITE_READERS`, max 32, 0 = off) | `SQLITE_OPEN_READONLY` | read-only statements outside a unit of work, leased per thread |

- **Readers are off** (only `writer` exists; exactly today's behaviour) for `:memory:`, for
  `HAM_SQLITE_READERS=0` (the production kill-switch), and for the dedicated connections:
  billing, `Bridge_Enroll_Commit_Conn`, `Vault_Directory_Write_Conn` and the metrics
  collector's read-only connection. These open with `open(path, readers = 0)`.
- **Readers also turn off if the file is not in WAL mode (found).** Under a rollback journal, a
  reader's open statement holds a SHARED lock. That lock blocks every writer, including the same
  thread's next write inside its own step loop, which then stalls for busy_timeout. `open`
  checks `PRAGMA journal_mode` after enabling WAL.
- `Conn :: struct { _state: rawptr }`. **(found)** A field whose type is `@(private="file")` can
  still be read from other files in Odin, so only a `rawptr` hides the handles. `Conn_State`
  (handles, pool, path) is heap-allocated, so copying a `Conn` by value (`graph.db = db`) is
  safe.

### 2.2 Routing (one place: `stmt_prepare` in conn.odin; callers never choose)

1. The calling thread owns the unit of work (or a manual transaction) on this Conn's writer:
   prepare on `writer`, so it reads its own uncommitted writes. Ownership is
   `tx_depth > 0 && tx_owner_thread == me && tx_writer == this writer`. The writer check matters
   because tests open several Conns. **(found)** `sync.current_thread_id()` is a `gettid`
   syscall on Linux, so `tx_depth` is loaded first and the common path costs one atomic load.
2. Readers off: prepare on `writer`.
3. The leading keyword is `SELECT`, `WITH` or `VALUES` and `sqlite3_stmt_readonly` confirms it:
   prepare on this thread's leased reader. **(found)** `sqlite3_stmt_readonly` is also true for
   BEGIN, COMMIT, SAVEPOINT, RELEASE, ATTACH and most PRAGMAs. Without the keyword gate those
   would run on, and change the state of, a pooled reader. The gate also saves writes a second
   prepare. The keyword scanner honours `nByte`, because Odin strings are not NUL-terminated.
   If the reader fails to prepare (or the statement is not read-only), the lease is returned
   and the statement falls through to step 4.
4. Everything else: `autocommit`.

`exec(conn, sql)` (DDL, PRAGMA, multi-statement scripts) runs on `writer` for the owner,
otherwise on `autocommit`, with one exception, the manual transaction in §2.3.

### 2.3 Unit of work (`tx.odin`)

- `BEGIN IMMEDIATE` on `writer`, never a deferred `BEGIN`. With a second write connection, a
  deferred transaction that reads and then writes can fail with `SQLITE_BUSY_SNAPSHOT` without
  retrying. IMMEDIATE takes the write lock up front and waits on busy_timeout.
- `tx_mutex`, SAVEPOINT nesting, after-commit hooks, the lock order (`tx_mutex` →
  `state_mutex`) and `lockorder.assert_tx_mutex_allowed` are unchanged. All tx SQL goes through
  `exec_writer`.
- **Manual transactions (found).** `fts_repair.repair_fts_indexes` runs `BEGIN IMMEDIATE …
  COMMIT` through `exec` on the SHARED connection, both at boot and at runtime from
  `step_write_healing`. Its later statements must see that transaction. The
  enrollment-commit and vault fallbacks do the same on the main Conn when they have no
  dedicated connection. Fix: when `exec` sees a leading `BEGIN` from a non-owner on a Conn with
  readers, it takes the unit-of-work slot (`tx_manual_begin`: lock-order assert,
  `tx_mutex`, owner = me, depth = 1). The whole transaction then runs on `writer`. The slot is
  released (`tx_manual_settle`) once `sqlite3_get_autocommit(writer) != 0`, that is after
  COMMIT, after ROLLBACK, or after a failed BEGIN. Today any thread's statement can join the
  repair's transaction; this closes that hole too.
- Migration files 090, 097, 098 and 099 contain `BEGIN … COMMIT` inside ONE `exec` script, so
  they need no change.

### 2.4 Reader leasing

- The lease is thread-local and reference-counted per statement. A thread's first reader
  statement takes a reader from the pool, waiting on a condition variable if none is free.
  Later statements on that thread reuse the same reader (count + 1), so a read prepared inside
  another read's step loop cannot deadlock the pool. The finalize that brings the count to 0
  returns the reader. The statement is finalized first, so its read transaction has ended
  before another thread can take the reader.
- There are 4 lease slots per thread, because tests open several Conns. If all 4 are taken,
  the read falls back to `autocommit`: correct, but not parallel.
- The pool tracks each slot's `leased_at` time and the first 200 bytes of the SQL that took the
  lease, for the stale-lease report (§3.4).
- **Deadlock audit.** The unit-of-work owner never needs a reader, so `tx_mutex` holders never
  wait on the pool. A lease holder can block on `tx_mutex` (finite), on busy_timeout (5 s), or
  on `state_mutex` (see the §8 inventory). A pool waiter is never the `tx_mutex` holder.

### 2.5 Pragmas: single source in `open()` (found: today they live in `app/wiring.odin:192-199`)

| | foreign_keys | busy_timeout | journal_mode | synchronous | other |
|---|---|---|---|---|---|
| writer | ON | 5000 | WAL (persistent; file DBs) | NORMAL | |
| autocommit | ON | 5000 | (file-level) | NORMAL | |
| readers | ON | 5000 | (file-level) | — | `query_only`, `mmap_size=256MB`, `cache_size=-16000` |

- Remove the pragmas from `wiring.odin` and from the dedicated-connection openers
  (`bridge_repo_sqlite.odin:34`, `vault_directory_repo_sqlite.odin:38`,
  `billing_repo_sqlite.odin:46`), and remove the duplicates in the
  `tmpl_open_file_prod` test fixture.
- Setting `synchronous=NORMAL` on the dedicated connections is a small change from today. It is
  safe in WAL mode.
- **(found)** `SQLITE_CONFIG_MEMSTATUS` is on by default, so every SQLite malloc takes ONE
  global mutex. The test fixture already turns it off (in a measured RCA it serialized parallel
  tests). Parallel readers would hit the same mutex in production. Turn it off in conn.odin
  `@(init)` for all builds; nothing reads SQLite memory statistics.
- `PRAGMA` statements sent through `exec` reach ONE connection. Connection state belongs in
  `open()`; this is documented in AGENTS.md.

## 3. Guardrails

1. **No raw handles.** `Conn` is opaque. All connection-level FFI is `@(private="file")` in
   conn.odin under `ffi_*` names: open, open_v2, close, prepare_v2, finalize, exec, errmsg,
   extended_errcode, db_handle, next_stmt, stmt_readonly, get_autocommit, changes, db_mutex,
   mutex_enter/leave, free, and backup_*. Statement-level FFI (bind, column, step, reset, sql)
   is `@(private="file")` in db.odin. Each file declares only what it needs; duplicate
   file-private foreign declarations are fine.
2. **Automatic finalize.** Statements never leave db.odin. `query_one`, `query_all` and
   `exec_write` finalize before they return. The streaming `query` returns a `Rows` value
   marked `@(deferred_out = rows_close)`, so it is finalized at the end of the CALLER's scope on
   every exit path. It is also finalized as soon as `rows_next` reaches the end or an error.
   - **(found)** I verified `deferred_out` semantics on our Odin build. It works with `:=` and
     with `=` assignment, it runs once per loop iteration, and when the call is in an `if`
     header it runs at the end of the `if`. A deferred proc receives the results BY VALUE, so
     "finalize at end of iteration" plus "finalize at scope end" needs a guard against
     finalizing twice. Each `Rows` carries a per-thread generation id held in a thread-local
     live-statement table of 32 entries. `rows_close` finalizes only if the id is still live,
     so a recycled `sqlite3_stmt` address cannot be finalized twice. If the table is full, the
     `Rows` is untracked: the end of iteration only resets it, and the scope end finalizes it.
3. **Routing is never the caller's decision.** Ownership plus `sqlite3_stmt_readonly` decide.
   No API takes a read/write flag.
4. **Runtime tripwires.**
   - (a) `lockorder.assert_db_thread_clean(site)` is a hook that sqlite installs from
     `@(init)`, so transport and services need not import sqlite. Call sites:
     - the end of `handle_client` (`transport/http/server.odin:58`)
     - each WS frame (bridge WS and user WS)
     - each reaper pass (`app/app.odin` `reaper_loop`)
     - each taskv2 timer tick (`service/taskv2/timers.odin:452`)
     - each merge job (`service/taskv2/merge.odin:102`)
     - each webpush send (`service/push/webpush_send.odin:93`)
     - each bridge_log writer batch, each attention-debouncer flush, and each shell-session
       worker iteration

     The exact iteration points are in §8.

     A thread that still holds a reader lease or an open unit of work is a violation. It is
     logged with the SQL of the live statements (`next_stmt` on its own reader is safe) and
     counted in `heimdall_sqlite_thread_leak_total{kind}`. Tests and debug builds panic. Release
     builds then reset the leaked statements and return the reader, so one leak cannot drain
     the pool; a later finalize of such a statement is still safe.
   - (b) A lease held longer than 5 s is logged once, with the SQL that took it. The log comes
     from pool waiters (1 s `cond_wait_with_timeout`) and from the metrics scrape.
5. **Source-guard test** (`repository/sqlite/api_guard_test.odin`). It scans `src/hub/**.odin`
   with `//` comments stripped and fails, with a "use X instead" message, on any of:
   - an `sqlite3_`, `ffi_`, `stmt_prepare`, `stmt_step` or `stmt_finalize` identifier, or
     `._state`, `._stmt` or `foreign import`, outside conn.odin, db.odin and tx.odin
   - an import of `hub/repository/sqlite` outside `repository/sqlite`, `app/wiring.odin`,
     `app/metrics_listener.odin`, `app/metrics_db_collectors.odin` and `*_test.odin`
   - `fmt.tprintf`, `fmt.aprintf` or `strings.concatenate` on a line containing SQL keywords
     (`SELECT|INSERT|UPDATE|DELETE|FROM|WHERE|VALUES`) in `repository/sqlite`, unless that line
     or the previous one carries `// sql-dynamic: <reason>`. Expected opt-outs: fts_repair
     (table names), search (fts MATCH builders), bridge_log batch VALUES, and migrations'
     `PRAGMA table_info(%s)`.
   - **(found)** Constant SQL fragments (`strings.concatenate({"SELECT ", CHAT_MESSAGE_SELECT,
     …})` in content_repo) become compile-time constants: `Q :: "SELECT " + COLS + " FROM …"`.
6. **Docs.** A header comment in conn.odin and db.odin, and an AGENTS.md section "Database
   access rules" (§10).

## 4. Typed query layer (`repository/sqlite/db.odin`)

```odin
Null :: struct {}
Arg  :: union { string, i64, int, f64, bool, Null }   // nil union binds NULL too
opt_text :: proc(s: string) -> Arg                     // "" -> NULL (nullable columns, e.g. vault pair_lookup)
in_list  :: proc(n: int) -> string                     // "?, ?, ?" for a dynamic IN (...); the ONLY sanctioned SQL building helper

Db_Error_Kind :: enum { None, Not_Found, Unique_Violation, Foreign_Key_Violation,
                        Constraint_Violation, Busy, Read_Only, Corrupt, Io, Internal }
Db_Result :: struct {
	kind:    Db_Error_Kind,
	ext:     i32,     // sqlite3_extended_errcode, for logs
	detail:  string,  // e.g. "projects.slug" parsed from the constraint message (temp allocator)
	message: string,  // sqlite3_errmsg (temp allocator), for logs only
}

query_one :: proc(conn: ^Conn, $T: typeid, sql: string, args: ..Arg) -> (T, Db_Result)       // Not_Found when no row
query_all :: proc(conn: ^Conn, $T: typeid, sql: string, args: ..Arg) -> ([]T, Db_Result)     // context.allocator
@(deferred_out = rows_close)
query     :: proc(conn: ^Conn, sql: string, args: ..Arg) -> Rows                              // streaming
rows_next :: proc(rows: ^Rows) -> bool
rows_scan :: proc(rows: ^Rows, out: ^$T)                     // struct scan of the current row
rows_result :: proc(rows: ^Rows) -> Db_Result                // after the loop
col_text / col_view / col_i64 / col_int / col_f64 / col_bool / col_opt_text / col_is_null  // escape hatch, by index
exec_write :: proc(conn: ^Conn, sql: string, args: ..Arg) -> (changes: int, res: Db_Result)
```

- **Struct scanning.** Columns map to fields by the `db:"col"` tag (falling back to the field
  name), using `core:reflect`. The column-to-field plan is validated once per `(typeid, sql
  pointer)` and cached in a small per-thread table, so the per-row cost is one typed column read
  per field with no lookups. Supported field types:
  - `string` (cloned into `context.allocator`, as `column_text` does today)
  - `Maybe(string)` (NULL → nil)
  - `i64`, `int`, `i32`, `f64`
  - `bool` (stored as `"1"`/`"0"` text or as an integer)
  - distinct strings (`domain.User_ID`, `Project_ID`, …)
  - enums through a per-type converter registered with `register_enum_text($E, from_string)`,
    because the codebase stores enums as text (`project_state_from_string`, …)

  A missing column, an unmatched field or an unsupported type is a programmer error: it panics
  in tests and debug, and returns `Db_Result{kind = .Internal}` with a logged message in
  release. Fields tagged `db:"-"` are skipped. Domain structs with derived or JSON fields
  (Memory's `agent_ids` list and similar) use a flat `*_Row` struct plus a converter in the
  repository.
- **Binding preserves today's storage types (found).** The repos bind most integers as TEXT
  (`bind_text(stmt, i, int_s(x))`) and read them back as text. If the migration switched those to
  integer binds, comparisons and stored values in columns without INTEGER affinity would
  change. Rule for the migration: bind exactly the type that was bound before; switching to
  native types is a follow-up.
- **`exec_write`** steps under the statement's own connection mutex, so `changes` cannot be
  overwritten by another thread's write on the shared `autocommit`. This is today's
  `step_changes`, now with `sqlite3_db_handle(stmt)`. A statement that returns rows is an
  `.Internal` misuse; use `query_*` for `RETURNING`.
- **FTS self-heal moves into the layer.** On `SQLITE_CORRUPT` from a write (including `RETURNING`
  through `query_*`), the layer runs `repair_fts_indexes` and retries once (today's
  `step_write_healing`). Inside a unit of work the repair is a no-op, as today. This replaces 5
  explicit call sites and covers every write.
- **Performance.** Args are a stack slice. Scanning adds no allocation beyond the string
  clones that repos already make. `col_view` returns a borrowed view for parse-only columns
  (today's `column_text_unowned`). The plan cache makes reflection a one-time cost.

### Before / after (representative)

```odin
// GET — before (project_repo_sqlite.odin)
impl := (^Project_Repo_SQLite)(ctx); stmt: sqlite3_stmt = nil
q := "SELECT project_id, ... FROM projects WHERE project_id = ?;"
if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return {}, false, domain.domain_error(.Internal_Error, "failed to prepare project lookup")
defer sqlite3_finalize(stmt); bind_text(stmt, 1, string(project_id))
if sqlite3_step(stmt) != SQLITE_ROW do return {}, false, domain.domain_error(.Not_Found, "project not found")
return project_from_stmt(stmt), true, {}

// GET — after
Project_Row :: struct { project_id: domain.Project_ID, owner_user_id: domain.User_ID, name, slug, description, repo_url, vcs_kind, default_path: string,
                        state: domain.Project_State `db:"state"`, created_at, updated_at: string }
row, res := query_one(impl.conn, Project_Row, "SELECT project_id, ... FROM projects WHERE project_id = ?;", string(project_id))
if res.kind == .Not_Found do return {}, false, {}                        // convention §5 (see open question Q1)
if res.kind != .None do return {}, false, db_result_to_domain_error(res, "project lookup")
return project_from_row(row), true, {}

// LIST — after
rows, res := query_all(impl.conn, Project_Row, PROJECT_LIST_SQL, string(owner), i32_to_string_sqlite(limit))
if res.kind != .None do return nil, db_result_to_domain_error(res, "project list")

// SAVE with a unique conflict — after
_, res := exec_write(impl.conn, PROJECT_UPSERT_SQL, ..project_args(project)[:])   // project_args -> [11]Arg on the stack
if res.kind != .None do return {}, false, db_result_to_domain_error(res, "project could not be saved")
// Unique_Violation -> .Conflict "project could not be saved"; Busy -> .Unavailable; Io -> .Internal_Error.
```

## 5. Error model

- **`Db_Error_Kind` comes from `sqlite3_extended_errcode`:**

  | Extended code(s) | Kind |
  |---|---|
  | `CONSTRAINT_UNIQUE`, `CONSTRAINT_PRIMARYKEY` | Unique_Violation |
  | `CONSTRAINT_FOREIGNKEY` | Foreign_Key_Violation |
  | `CONSTRAINT_NOTNULL`, `CHECK`, `TRIGGER` (RAISE(ABORT)) | Constraint_Violation |
  | `BUSY*`, `LOCKED*` (busy_timeout expired) | Busy |
  | `READONLY*` | Read_Only (a routing bug: logged loudly, counted, `.Internal` to callers) |
  | `CORRUPT*` | Corrupt |
  | `IOERR*`, `FULL`, `CANTOPEN` | Io |
  | anything else | Internal |

  `query_one` with no row returns Not_Found. `detail` is the `table.column` parsed from the
  "UNIQUE constraint failed: t.c" message; nothing branches on message text beyond this one
  parser.
- **One central mapper:** `db_result_to_domain_error(res, ctx_msg) -> domain.Domain_Error`.

  | Kind | Domain code | Notes |
  |---|---|---|
  | Unique_Violation | `.Conflict` | |
  | Foreign_Key_Violation, Constraint_Violation | `.Validation_Failed` | or `.Conflict` where tests pin it; see Q2 |
  | Not_Found | `.Not_Found` | |
  | Busy | NEW `.Unavailable` | `{"unavailable", .retriable, 503}` |
  | Read_Only, Corrupt, Io, Internal | `.Internal_Error` | |

  - **`.Unavailable` is new.** None of the existing codes fit: `Bridge_Busy` is about bridges,
    and `Internal_Error` is not distinguishable from it. Add it to `contracts.Error_Code` and
    `ERROR_CODE_TABLE` (the table is exhaustive and compile-checked). Then build `src/bridge`
    and `src/ctl`, because they share contracts, and check the UI's error-code handling for
    unknown names.
  - **The message keeps the existing user-facing text** (`ctx_msg`), which keeps the tests
    that assert messages working.
  - **`cause` gets a short stable token** (`sqlite_busy`, `sqlite_unique:projects.slug`),
    never the raw SQLite message. **(found)** `Domain_Error.cause` is relayed on the wire in
    the error envelope (`contracts/errors.odin`), so raw text there would leak schema
    details. The full message is logged server-side.
- **Repository convention** (documented in iface, applied in the migration):
  - get-style: `(T, found: bool, Domain_Error)`. Not found is `found = false`,
    `err.code == .None`. A DB failure is `err.code != .None`.
  - save/delete-style: `(…, ok, Domain_Error)` with `ok == (err.code == .None)`.
  - **(found)** Today's get procs return `found = false` together with a `.Not_Found` error
    (e.g. `project_get_sqlite`), and handlers often forward `err` straight to HTTP as a 404.
    See Q1 before changing this.
- **Drops the blanket "any step failure → `.Conflict`".** With the mapper, a busy or I/O
  failure no longer looks like a user conflict.

## 6. Tests (new; temp-file DBs under TMPDIR, removed with -wal/-shm)

- **`conn_pool_test.odin`:**
  - thread B reading during thread A's open unit of work, which holds an uncommitted insert,
    does not see the row and does not block on `tx_mutex`
  - an autocommit write from B survives A's rollback (lost-write regression)
  - read-your-writes inside a unit of work, including nested savepoints
  - a nested query inside a step loop reuses one lease (count 2 → 0)
  - N+3 threads reading at once all finish (pool exhaustion, no deadlock)
  - `exec_write` changes are per statement under concurrent writers (the existing
    `step_changes_test` scenario, ported)
  - `HAM_SQLITE_READERS=0` and `:memory:` behave as today
  - a manual `BEGIN` through `exec` sees its own writes and releases the slot after COMMIT and
    after ROLLBACK
  - routing of `BEGIN`, `SAVEPOINT`, `PRAGMA` and `WITH … INSERT` never lands on a reader
  - the tripwire panics on a leaked lease and on an open unit of work, and does not fire on a
    clean thread
  - the stale-lease report fires after 5 s (the threshold is a test seam)
- **`db_errors_test.odin`:**
  - unique, FK, NOT NULL and CHECK violations map to their kinds
  - Busy: a second Conn holds `BEGIN IMMEDIATE` and the first runs with a short busy_timeout
    (test seam). **(found)** `test_sqlite_busy_counter_on_lock_contention` relies on the second
    connection having NO busy_timeout; it needs the same seam or it will take 5 s.
  - Not_Found
  - every kind round-trips through `db_result_to_domain_error`
- **`db_scan_test.odin`:**
  - tags and field-name fallback
  - `Maybe(string)` with NULL
  - bool from `"1"` text and from the integer 1
  - enum converter
  - a missing column and a wrong type panic (programmer error), and the plan cache is hit on
    the second call
- **`api_guard_test.odin`** (§3.5), plus a self-test on fixtures that MUST trip each rule.
- **`db_bench_test.odin`** (test-only microbenchmark): agent list (about 30 columns × 200 rows),
  measured before (raw API on the base commit) and after (`query_all` scan), single-threaded
  and with 4 threads. Report ns/row and allocations per row. Target: within 10%
  single-threaded, and parallel throughput at or above 3× with 4 readers.
- **Suites, run one at a time with `-define:ODIN_TEST_THREADS=2`:**
  - `src/hub/repository/sqlite`
  - `src/hub/service/taskv2`
  - `src/hub/service/bridge`
  - `src/hub/transport/http`
  - `src/hub/app`
  - `src/contracts` (new error code)
  - plus a build of `src/hub`, `src/bridge` and `src/ctl`

  Any failure is compared against `origin/main` in a separate `git worktree`.

## 7. Staged commits and effort

Each commit builds and passes the suites. Effort is focused engineering time.

| # | Commit | Content | Effort |
|---|---|---|---|
| 0 | state_mutex DB writes out of the lock | the three §8.2 sites return facts and write after `connection_state_unlock`, with a test that a heartbeat during an open unit of work does not stall | 0.5–1 d |
| 1 | pool + routing + layer | conn.odin (opaque Conn, pool, routing, manual tx, tripwire hook, pragmas, memstatus), tx.odin (IMMEDIATE, ownership), db.odin (Arg, scan, Db_Result, mapper), sqlite_metrics (lease gauge/wait histogram, stale counter, thread-leak counter), wiring/dedicated conns `readers=0`, new tests from §6 except guard. **A TRANSITIONAL shim** keeps the old surface compiling: `Conn.db` as an opaque `Legacy_Db`, public `sqlite3_prepare_v2/finalize/errmsg/step/bind/column` and `step_changes(db, stmt)` forwarding to the router. So repos are untouched and the old code paths already get pooled reads. | 1.5–2 d |
| 2 | error code | `contracts.Error_Code.Unavailable` + table + bridge/ctl/UI check | 0.5 d |
| 3a–3e | migrate repos in batches (file groups below), mapping errors through `db_result_to_domain_error` | about 217 prepare sites, 43 `step_changes`, 5 healing sites, all test helpers that used the raw API, plus `app/metrics_db_collectors.odin` and `service/taskv2/mixed_work_test.odin` (**found**: both use `conn.db`, contradicting "no code outside repository/sqlite touches conn.db") | 4–6 d |
| 4 | lock down | delete the shim, make all FFI file-private, guard test, tripwires wired at all §8 iteration points, the template fixture via `conn_copy_database`, docs (AGENTS.md + this plan) | 1–1.5 d |
| 5 | benchmark + report | numbers in this doc | 0.5 d |

**Batches:**

| Batch | Files |
|---|---|
| 3a | user, project, provider, lsp_server_config, experiment, push, conversation_launch_preferences |
| 3b | agent, content, card, attention, issue |
| 3c | taskchain, taskv2, mixed_work, workflow_run, action, instance_reconfiguration |
| 3d | bridge, bridge_token, bridge_log, shell_session, vault_directory, billing |
| 3e | search, search_fts, fts_repair, migrations, test fixtures |

Batches can run in parallel in separate git worktrees on top of commit 1, because the shim
keeps unmigrated files compiling. Compiles are serialized with `flock` to protect the
production host.

Total: about 9–12 days.

## 8. Inventories (from the code audit)

### 8.1 Autocommit write paths (now isolated on `autocommit`; they wait on busy_timeout while a unit of work holds the write lock)

Units of work exist only in `card_service.odin:912` (`accept_card`), `taskv2/service.odin:229` (`begin_uow`, including the timer thread and merge jobs) and `taskchain_service.odin:62` (`verb_begin`). **Every other repository write is autocommit**, and today each one can be swallowed by another thread's open transaction. Paths below are under `src/hub`; HB = bridge heartbeat (45 s).

| Area | Representative callers → repo proc | Thread | Frequency |
|---|---|---|---|
| Bridge row | `bridge_service.odin:274` `update_runtime_capabilities`, `:405` vault status, `:230` connect, `:251` offline, `:971` update progress → `bridge_save_bridge` | WS reader | per HB with capabilities; per connect/disconnect/frame |
| Agent instances | `agent_service.odin:1232/1256` `reconcile_bridge_heartbeat`, `:1103/1161` status report, `:1379` `reap_stale_instances`, `:1325` unreachable; `instance_failure.odin:109`; `instance_reconfiguration.odin:133/142/391` → `agent_save_instance` (with healing) | WS reader, reaper (20 s), HTTP | **per HB × active instances** |
| Bridge logs | `bridge_log_service.odin:119` `insert_batch`, `:132` cap; `:145` prune; `:166` delete | bridge_log writer (1 s or 512 rows), reaper (15 min), HTTP | continuous |
| Push | `push_service.odin:82/103`; `webpush_send.odin:216` `delete_by_id` | HTTP, push worker | per subscribe / dead endpoint |
| Shell sessions | `shell_session_inventory.odin:479/542/579`, `shell_session_service.odin:1879/2258/1058`, retention `:59` | WS reader, reaper, HTTP | per inventory frame / exit; 20 s |
| Chat / content | `content_service.odin:213-216` save_message + save_conversation + title nudge + attention notify; `:244/249` pane capture | HTTP, WS reader | per message |
| Cards / attention | `card_projector.odin:588/598` (synchronous on the source-writer thread, and the reaper's reconcile); `card_service.odin:430/477/654/696` (**writes on list/GET**) | HTTP, WS, reaper (10 min) | per event / per list |
| Taskchain (outside `verb_begin`) | `taskchain_service.odin:465/479/583/1496/1527/1661/1795/1824/1834`, comments `:1260/1405` | HTTP | per action |
| Auth | `auth_service.odin:457` `verify_user_api_token` → `user_token_save` (`last_used`, **not throttled**) | HTTP | **every `hut_` bearer request** |
| Bridge tokens / enrollment | `bridge_token_service.odin:205/222/443/462/483`; `bridge_device_enroll.odin:144-240`; `bridge_enroll_pending.odin:115/149/164`; reaper `sweep_expired_enrollments` | HTTP, reaper | per enroll/refresh |
| Other HTTP CRUD | users, launch prefs (healing), projects, issues, providers, experiments, LSP config, actions | HTTP | per request |
| Boot | `lease.odin:508` `grant_boot_lease_grace` | main | once |
| Own connection (unchanged) | billing (`get_account` also writes), `bridge_commit_enrollment`, every vault write (incl. `touch_last_seen` per signed GET) | — | — |

**Existing bug, closed by §2.3:** `fts_repair.repair_fts_indexes` runs `BEGIN IMMEDIATE … COMMIT` on the shared handle without `tx_mutex`. It runs at boot and, at runtime, from `step_write_healing` on the per-HB `agent_save_instance` path. If a unit of work is open, the heal's BEGIN fails, and the `ROLLBACK` on its error path (`fts_repair.odin:65`) **rolls back the other thread's unit of work**.

**Follow-up candidates** (not required here; noted for the busy-wait budget): throttle `user_token_save` `last_used`, and batch the per-HB instance `last_seen_at` writes into one statement.

### 8.2 DB access while holding `Bridge_Runtime_Connection.state_mutex`

All three sites below lock through `connection_state_lock` (`service/project/runtime_registry.odin:709`). All run on the bridge WS thread and use autocommit repository calls. None begins a unit of work, so the lock order holds today.

| Site (lock) | DB calls under the lock | Frequency |
|---|---|---|
| Handshake `bridge_ws_upgrade_handler` (`transport/http/bridge_handlers.odin:1688`) | **Read:** token verify, `bridge_get_bridge`. **Write:** `bridge_save_bridge` (`service/bridge/bridge_service.odin:229`). | per connect |
| Disconnect `bridge_disconnect_persist` (`bridge_handlers.odin:1803`) | `mark_bridge_offline` (get + `save_bridge`). `mark_bridge_instances_unreachable`: list + one `agent_save_instance` per active instance (`service/agent/agent_service.odin:1304/1323`). | per disconnect |
| Status `bridge_apply_validated_status` (`bridge_handlers.odin:2444`) | `apply_bridge_status_report`: `agent_get_instance` + `agent_save_instance` (`agent_service.odin:1074/1103/1165`). | **every heartbeat / status frame** |

**This is a NEW hazard and must be fixed before stage 1 ships.** The matcher's JIT path (`agent_service.odin:276` → `bridge_runtime_instance_apply`) holds a unit of work, and with it the SQLite write lock (BEGIN IMMEDIATE), and then waits for `state_mutex`. Meanwhile the WS thread holds `state_mutex` and its autocommit write waits for the write lock. Neither can proceed until busy_timeout (5 s) fails the WS thread's write with Busy.

Today there is no wait: the WS thread's write silently joins the other thread's transaction (the lost-write bug).

**Fix (stage 0, below):** the three sites follow the existing rule for `state_mutex` code. They decide under the lock, return the facts, and write after the unlock (as `notify_facts` / `notify_instances_terminal` already do). Reads under the lock run on readers and are harmless.

### 8.3 Long-lived thread iteration points for the tripwire

| Thread | Check point |
|---|---|
| HTTP | `transport/http/server.odin` `handle_client` end (after `write_http_response`, :144; the upgrade exits at :126/:134 hand off to the WS loops) |
| Bridge WS | `transport/http/bridge_handlers.odin:1935` loop, after `bridge_ws_process_frame` (:1963) and on the binary `continue` (:1952) |
| User WS | `transport/http/user_handlers.odin:157` loop (after :166) |
| Agent pane WS | `agent_instance_handlers.odin:228` |
| Shell pane WS | `shell_session_handlers.odin:198` |
| Reaper | `app/reaper.odin:118` (after `reaper_with_scratch`) |
| taskv2 timer | `service/taskv2/timers.odin:471` (at `free_all(temp)`, :481) |
| Merge job | `service/taskv2/merge.odin:107` (defer block :109-113) |
| Webpush | `service/push/webpush_send.odin:97` (after :101) |
| bridge_log writer | `service/bridge_log/bridge_log_service.odin:203` (after `flush_once`, :212) |
| Attention debouncer | `service/events/attention_debouncer.odin:79` |
| Shell kill replay | `service/shell_session/shell_session_service.odin:1174` (end :1197) |
| Pane viewer writer | `service/shell_session/pane_viewer_writer.odin:72` (:104) |

The proxy relay (`bridge_proxy_relay.odin:316`) and the preview pump (`shell_session_handlers.odin:1250`) do no DB work. Give them a check only if a later change adds DB access.

## 9. Rollout, kill-switch, metrics

- **Ship with readers ON.** `HAM_SQLITE_READERS=0` in the nix service env is an instant
  rollback without a rebuild: there is only `writer`, as today, and the typed layer and error
  model are unaffected.
- **New metrics:**
  - `heimdall_sqlite_reader_leased` (gauge)
  - `heimdall_sqlite_reader_wait_seconds` (histogram)
  - `heimdall_sqlite_reader_lease_stale_total`
  - `heimdall_sqlite_thread_leak_total{kind}`
  - `heimdall_sqlite_read_only_violation_total`

  **(found)** Existing families use the `heimdall_` prefix, not the `ham_` prefix the first
  draft used.
- **Watch:** `heimdall_sqlite_busy_total`, the reader wait p99, request p99, the 503 rate
  (`.Unavailable`), `heimdall_sqlite_wal_bytes` (long readers delay checkpoints), and RSS.
  Readers add up to 4 × 16 MB of page cache plus mmap'd file pages, which count as shared RSS.

## 10. AGENTS.md "Database access rules" (draft, about 15 lines)

- Repositories call `query_one`, `query_all`, `query` + `rows_next` + `rows_scan`, and
  `exec_write` in `repository/sqlite/db.odin` with bound `Arg`s. Never format values into SQL.
  Use `in_list(n)` for IN lists, and mark a genuinely dynamic identifier with
  `// sql-dynamic: <reason>`.
- Do not use `sqlite3_*`, handles or `defer finalize`; the layer owns statements.
  `api_guard_test` enforces this.
- Routing is automatic. Inside a unit of work you read your own writes. Outside one, writes
  autocommit on their own connection and reads come from a pooled snapshot, so you never see
  another thread's uncommitted rows. Use after-commit hooks to signal other threads.
- Never hold a unit of work across network I/O. Never begin one while holding a `state_mutex`.
- Errors: branch on `Db_Result.kind`, convert with `db_result_to_domain_error`, follow the
  found/ok convention.
- New repository method: write the SQL constant, define a `*_Row` struct with `db` tags (or
  reuse the domain struct), call the layer, map errors, add a test against a temp-file DB.

## 11. Gotchas found in the code (keep in mind while implementing)

- **`step_changes` must use the statement's own handle.** `sqlite3_changes` is per connection,
  and `autocommit` is shared by every request thread.
- **`bind_text("")` binds an empty string, not NULL.** Only vault's `bind_opt` binds NULL. Keep
  both behaviours (`Arg` string vs `opt_text`).
- **`column_text` clones and `column_text_unowned` borrows.** Map them to scanned `string` and
  to `col_view`.
- **Billing is a separate Conn with its own `BEGIN IMMEDIATE` transactions.** It runs with
  readers off, and its statements go through the same layer.
- **A unit-of-work owner that writes through a DIFFERENT Conn on the same file** (billing,
  enrollment or vault connections) waits up to 5 s on its own write lock and then fails Busy.
  This already happens today when the unit of work has written. The audit found no such path;
  re-check in §8.
- **Statements are finalized on the thread that prepared them.** The layer guarantees it. A
  `Rows` must not be handed to another thread; this is documented.
- **`HAM_SQLITE_READERS` parse errors fall back to 4 with a warning.**

## 12. Open questions / risks

- **Q1 — Not-found convention.** Most get-procs return `.Not_Found` as an error today, and
  handlers forward it as a 404. Switching to `found=false, err=None` everywhere means auditing
  every caller (about 100 get sites) so a 404 is not silently lost. Proposal: adopt the
  convention in iface docs and in new code. Migrate per batch only where every caller is
  checked, or keep `.Not_Found` errors from the get-procs that already return them and record
  the exception. Needs a decision.
- **Q2 — FK/constraint mapping.** Several tests may pin `.Conflict` for constraint failures
  (for example the RAISE(ABORT) triggers on immutable owner columns). Map to
  `.Validation_Failed` by default, keep `.Conflict` where a test or a client contract pins it,
  and list those sites.
- **Q3 — `.Unavailable`.** It is a new wire code. Bridges and UIs on older versions will see an
  unknown code name (the parser maps it to Internal_Error). Acceptable?
- **Q4 — Universal FTS self-heal.** Every write that hits `SQLITE_CORRUPT` would take
  `tx_mutex` and rebuild all fts indexes. That is correct but heavy. Today only 5 sites do it.
  OK to make it universal?
- **Q5 — Reader cache and mmap sizes.** 16 MB of cache and 256 MB of mmap per reader come from
  the original plan. On a memory-sensitive host (this worktree is the memleak investigation),
  start with `cache_size=-4000` and `mmap_size=64MB`?
- **Q6 — Lease-leak recovery in release.** Resetting leaked statements and returning the reader
  keeps the hub alive, but it lets two threads share one reader (serialized mode keeps that
  safe). Alternative: log only and let the pool shrink. Recommend recovery.
- **Q7 — Reflection-based scanning.** The plan cache is keyed by `(typeid, sql data pointer)`.
  SQL built at runtime (`sql-dynamic`) misses the cache and pays a validation per call. That is
  acceptable for the few dynamic sites, or they can use the index getters.
- **Risk — migration size.** About 217 sites. The behaviour-preserving rule (same bind types,
  same user-facing messages) plus per-batch suite runs keep it reviewable. Store-type
  normalisation stays out of scope.
- **Risk — readers break on a non-WAL filesystem.** `open` detects this and turns readers off.

## Out of scope (follow-ups)

- A prepared-statement cache per connection. The layer makes it easy: the cache key is the SQL
  pointer.
- Native integer binding and storage normalisation.
- Snapshot/ETag responses for UI polling endpoints; shorter unit-of-work sections (cached
  workflow spec parsing).
