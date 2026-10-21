package sqlite

import "base:runtime"
import "core:c"
import "core:strings"
import "core:sync"
import "core:time"
import dbt "odin_test:hub/platform/dbtelemetry"
import metrics "odin_test:lib/metrics"

// DB latency telemetry, SQLite side (docs/operations/db-telemetry.md).
//
// With HEIMDALL_DB_TELEMETRY=basic every wrapped API call (step, exec,
// prepare_v2, finalize) splits its time into
//   conn_wait - waiting for the connection's own (recursive) mutex, taken here
//               with try-then-enter so contention is visible, and
//   exec      - inside SQLite with that mutex held (VM, IO, WAL append and
//               busy_timeout sleeps).
// The inner SQLite call re-enters the recursive mutex uncontended, so the split
// is exact. A thread that already holds the mutex (step_changes) records no
// second wait. With telemetry off the wrappers are the legacy ones.
//
// No label ever carries SQL text, parameters or ids: `conn`, `op`, `code` are
// fixed enums and `site` is the compile-time "<file>:<procedure>" of the caller.

Conn_Kind :: enum u8 {
	Main,
	Billing,
	Enroll,
	Vault,
	Metrics,
	Other,
}

CONN_LABELS := [Conn_Kind]string {
	.Main    = "main",
	.Billing = "billing",
	.Enroll  = "enroll",
	.Vault   = "vault",
	.Metrics = "metrics",
	.Other   = "other",
}

CONN_LOCKS := [Conn_Kind]dbt.Lock {
	.Main    = .Conn_Main,
	.Billing = .Conn_Billing,
	.Enroll  = .Conn_Enroll,
	.Vault   = .Conn_Vault,
	.Metrics = .Conn_Metrics,
	.Other   = .Conn_Main, // unused: Other never observes lock_wait (see conn_enter)
}

Op :: enum u8 {
	Select,
	Insert,
	Update,
	Delete,
	Begin,
	Commit,
	Rollback,
	Pragma,
	Create,
	Other,
	Prepare,
	Finalize,
}

OP_LABELS := [Op]string {
	.Select   = "select",
	.Insert   = "insert",
	.Update   = "update",
	.Delete   = "delete",
	.Begin    = "begin",
	.Commit   = "commit",
	.Rollback = "rollback",
	.Pragma   = "pragma",
	.Create   = "create",
	.Other    = "other",
	.Prepare  = "prepare",
	.Finalize = "finalize",
}

Err_Code :: enum u8 {
	Busy,
	Busy_Snapshot,
	Locked,
	Constraint,
	Corrupt,
	Ioerr,
	Other,
}

ERR_LABELS := [Err_Code]string {
	.Busy          = "busy",
	.Busy_Snapshot = "busy_snapshot",
	.Locked        = "locked",
	.Constraint    = "constraint",
	.Corrupt       = "corrupt",
	.Ioerr         = "ioerr",
	.Other         = "other",
}

Tx_Kind :: enum u8 {
	Uow,
	Billing,
	Vault,
	Enroll,
	Fts_Repair,
}

TX_KIND_LABELS := [Tx_Kind]string {
	.Uow        = "uow",
	.Billing    = "billing",
	.Vault      = "vault",
	.Enroll     = "enroll",
	.Fts_Repair = "fts_repair",
}

Tx_Outcome :: enum u8 {
	Commit,
	Rollback,
	Commit_Failed,
	Begin_Failed,
}

TX_OUTCOME_LABELS := [Tx_Outcome]string {
	.Commit        = "commit",
	.Rollback      = "rollback",
	.Commit_Failed = "commit_failed",
	.Begin_Failed  = "begin_failed",
}

SQLITE_IOERR :: 10
SQLITE_CONSTRAINT :: 19
SQLITE_BUSY_SNAPSHOT :: SQLITE_BUSY | (2 << 8)

SQLITE_STMTSTATUS_FULLSCAN_STEP :: 1
SQLITE_STMTSTATUS_SORT :: 2
SQLITE_STMTSTATUS_VM_STEP :: 4

SQLITE_DBSTATUS_CACHE_HIT :: 7
SQLITE_DBSTATUS_CACHE_MISS :: 8
SQLITE_DBSTATUS_CACHE_WRITE :: 9
SQLITE_DBSTATUS_CACHE_SPILL :: 12

EXEC_BUCKETS := [?]f64{2.5e-5, 5e-5, 1e-4, 2.5e-4, 5e-4, 1e-3, 2.5e-3, 5e-3, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 5}

// ---------------------------------------------------------------------------
// Connection tagging: open(path, kind) registers the handle in a fixed slot
// table; close clears the slot BEFORE sqlite3_close so a reused pointer value
// never inherits the old kind. Hot-path lookup is a scan of <= 16 atomic loads.

CONN_SLOT_COUNT :: 16

Conn_Slot :: struct {
	db:   rawptr, // atomic
	kind: Conn_Kind,
}

conn_slots: [CONN_SLOT_COUNT]Conn_Slot
@(private = "file")
conn_slots_mu: sync.Mutex // cold path: register / unregister / scrape collector

@(thread_local, private = "file")
tl_conn_depth: [CONN_SLOT_COUNT]u16

// Unit-of-work write flag: set by the step wrapper while this thread owns the
// outer UoW, read by tx.odin for the tx `rw` label.
@(thread_local)
tl_uow_active: bool
@(thread_local)
tl_uow_wrote: bool

conn_register :: proc(db: sqlite3, kind: Conn_Kind) {
	if db == nil || !dbt.enabled() do return
	sync.lock(&conn_slots_mu)
	defer sync.unlock(&conn_slots_mu)
	for &s in conn_slots {
		if sync.atomic_load(&s.db) == nil {
			s.kind = kind
			sync.atomic_store(&s.db, rawptr(db))
			return
		}
	}
	// Table full (tests only): the handle stays unregistered -> kind other, exec-only timing.
}

conn_unregister :: proc(db: sqlite3) {
	if db == nil do return
	sync.lock(&conn_slots_mu)
	defer sync.unlock(&conn_slots_mu)
	for &s in conn_slots {
		if sync.atomic_load(&s.db) == rawptr(db) {
			sync.atomic_store(&s.db, nil)
			s.kind = .Other
		}
	}
}

slot_of :: #force_inline proc "contextless" (db: sqlite3) -> int {
	if db == nil do return -1
	for i in 0..<CONN_SLOT_COUNT {
		if sync.atomic_load_explicit(&conn_slots[i].db, .Acquire) == rawptr(db) do return i
	}
	return -1
}

conn_kind_of :: proc "contextless" (db: sqlite3) -> Conn_Kind {
	s := slot_of(db)
	return conn_slots[s].kind if s >= 0 else .Other
}

// ---------------------------------------------------------------------------
// Pre-resolved series.

Sqlite_Telemetry :: struct {
	initialised:   bool,
	// Families; series are resolved lazily on first use (only exercised label
	// sets exist, plan §2.2 cardinality) and cached in the arrays below.
	legacy_query_f: ^metrics.Family,
	exec_f:         ^metrics.Family,
	statements_f:   ^metrics.Family,
	vm_f:           ^metrics.Family,
	fullscan_f:     ^metrics.Family,
	sort_f:         ^metrics.Family,
	errors_f:       ^metrics.Family,
	tx_f:           ^metrics.Family,
	legacy_query:  [Op]^metrics.Series, // heimdall_sqlite_query_duration_seconds{op}
	exec:          [Conn_Kind][Op]^metrics.Series,
	statements:    [Conn_Kind][Op]^metrics.Series,
	vm_steps:      [Conn_Kind][Op]^metrics.Series,
	fullscan:      [Conn_Kind][Op]^metrics.Series,
	sort:          [Conn_Kind][Op]^metrics.Series,
	errors:        [Conn_Kind][Op][Err_Code]^metrics.Series,
	tx_duration:   [Conn_Kind][Tx_Kind][2][Tx_Outcome]^metrics.Series, // [rw: 0 read, 1 write]
	uow_nested:    ^metrics.Series,
	site_exec:     ^metrics.Family,
	site_vm:       ^metrics.Family,
	site_fullscan: ^metrics.Family,
}

sqlite_tm: Sqlite_Telemetry

@(private = "file")
sqlite_tm_mu: sync.Mutex

// sqlite_telemetry_init registers the new families (basic mode only) and
// pre-resolves every (conn, op) series so the hot path never calls metrics.with.
sqlite_telemetry_init :: proc(reg: ^metrics.Registry) {
	if reg == nil || !dbt.enabled() do return
	sync.lock(&sqlite_tm_mu)
	defer sync.unlock(&sqlite_tm_mu)
	if sqlite_tm.initialised do return
	m := &sqlite_tm
	m.legacy_query_f = sqlite_metrics.query_duration
	m.exec_f = metrics.new_histogram_seconds(reg, "heimdall_sqlite_exec_seconds",
		"Time inside SQLite with the connection mutex held, per wrapped API call (excludes conn mutex wait).", {"conn", "op"}, EXEC_BUCKETS[:])
	m.statements_f = metrics.new_counter(reg, "heimdall_sqlite_statements_total",
		"Statement executions (first step of each execution; one per sqlite3_exec call).", {"conn", "op"})
	m.vm_f = metrics.new_counter(reg, "heimdall_sqlite_vm_steps_total", "SQLite VM steps (sqlite3_stmt_status VM_STEP deltas).", {"conn", "op"})
	m.fullscan_f = metrics.new_counter(reg, "heimdall_sqlite_fullscan_steps_total", "Full-scan steps (sqlite3_stmt_status FULLSCAN_STEP deltas).", {"conn", "op"})
	m.sort_f = metrics.new_counter(reg, "heimdall_sqlite_sort_total", "Sort operations (sqlite3_stmt_status SORT deltas).", {"conn", "op"})
	m.errors_f = metrics.new_counter(reg, "heimdall_sqlite_errors_total",
		"Wrapped API calls that returned an error, by mapped primary/extended code.", {"conn", "op", "code"})
	m.tx_f = metrics.new_histogram_seconds(reg, "heimdall_db_tx_duration_seconds",
		"Outer transaction duration, BEGIN start to COMMIT/ROLLBACK return (excludes after-commit hooks).",
		{"conn", "kind", "rw", "outcome"}, dbt.HOLD_BUCKETS[:])
	m.uow_nested = metrics.with(metrics.new_counter(reg, "heimdall_db_uow_nested_total", "Nested units of work (savepoints); never a second tx observation."))
	m.site_exec = metrics.new_counter(reg, "heimdall_sqlite_site_exec_seconds_total",
		"Step exec time by calling procedure (<file>:<procedure>).", {"conn", "site"}, 9)
	m.site_vm = metrics.new_counter(reg, "heimdall_sqlite_site_vm_steps_total", "VM steps by calling procedure.", {"conn", "site"})
	m.site_fullscan = metrics.new_counter(reg, "heimdall_sqlite_site_fullscan_steps_total", "Full-scan steps by calling procedure.", {"conn", "site"})
	lib := metrics.new_gauge(reg, "heimdall_sqlite_library_info", "Linked SQLite library version (value is always 1).", {"version"})
	metrics.gauge_set(metrics.with(lib, string(sqlite3_libversion())), 1)
	metrics.registry_add_collector(reg, nil, sqlite_telemetry_collect)
	m.initialised = true
}

// Lazy series resolution: one atomic load on the hot path; metrics.with (which
// is idempotent and thread-safe) only on the first use of a label set.
@(private = "file")
lazy2 :: #force_inline proc(slot: ^^metrics.Series, f: ^metrics.Family, a, b: string) -> ^metrics.Series {
	s := sync.atomic_load_explicit(slot, .Acquire)
	if s == nil && f != nil {
		s = metrics.with(f, a, b)
		sync.atomic_store_explicit(slot, s, .Release)
	}
	return s
}

conn_op_series :: #force_inline proc(arr: ^[Conn_Kind][Op]^metrics.Series, f: ^metrics.Family, k: Conn_Kind, op: Op) -> ^metrics.Series {
	return lazy2(&arr[k][op], f, CONN_LABELS[k], OP_LABELS[op])
}

@(private = "file")
legacy_series :: proc(op: Op) -> ^metrics.Series {
	s := sync.atomic_load_explicit(&sqlite_tm.legacy_query[op], .Acquire)
	if s == nil && sqlite_tm.legacy_query_f != nil {
		s = metrics.with(sqlite_tm.legacy_query_f, OP_LABELS[op])
		sync.atomic_store_explicit(&sqlite_tm.legacy_query[op], s, .Release)
	}
	return s
}

@(private = "file")
error_series :: proc(k: Conn_Kind, op: Op, e: Err_Code) -> ^metrics.Series {
	slot := &sqlite_tm.errors[k][op][e]
	s := sync.atomic_load_explicit(slot, .Acquire)
	if s == nil && sqlite_tm.errors_f != nil {
		s = metrics.with(sqlite_tm.errors_f, CONN_LABELS[k], OP_LABELS[op], ERR_LABELS[e])
		sync.atomic_store_explicit(slot, s, .Release)
	}
	return s
}

@(private = "file")
tx_series :: proc(k: Conn_Kind, tk: Tx_Kind, wrote: bool, o: Tx_Outcome) -> ^metrics.Series {
	rw := 1 if wrote else 0
	slot := &sqlite_tm.tx_duration[k][tk][rw][o]
	s := sync.atomic_load_explicit(slot, .Acquire)
	if s == nil && sqlite_tm.tx_f != nil {
		rw_labels := [2]string{"read", "write"}
		s = metrics.with(sqlite_tm.tx_f, CONN_LABELS[k], TX_KIND_LABELS[tk], rw_labels[rw], TX_OUTCOME_LABELS[o])
		sync.atomic_store_explicit(slot, s, .Release)
	}
	return s
}

op_of :: proc "contextless" (sql: cstring) -> Op {
	switch sqlite_op_from_sql(sql) {
	case "select":   return .Select
	case "insert":   return .Insert
	case "update":   return .Update
	case "delete":   return .Delete
	case "begin":    return .Begin
	case "commit":   return .Commit
	case "rollback": return .Rollback
	case "pragma":   return .Pragma
	case "create":   return .Create
	}
	return .Other
}

err_code_of :: proc "contextless" (rc: c.int, extended: c.int) -> Err_Code {
	if extended == SQLITE_BUSY_SNAPSHOT do return .Busy_Snapshot
	switch rc & 0xff {
	case SQLITE_BUSY:       return .Busy
	case SQLITE_LOCKED:     return .Locked
	case SQLITE_CONSTRAINT: return .Constraint
	case SQLITE_CORRUPT:    return .Corrupt
	case SQLITE_IOERR:      return .Ioerr
	}
	return .Other
}

is_error_rc :: #force_inline proc "contextless" (rc: c.int) -> bool {
	return rc != SQLITE_OK && rc != SQLITE_ROW && rc != SQLITE_DONE
}

// ---------------------------------------------------------------------------
// Connection mutex: timed acquisition.

Conn_Enter :: struct {
	slot:    int,
	kind:    Conn_Kind,
	mutex:   rawptr,
	entered: bool, // this call took the mutex and must leave it
	wait_ns: i64,
}

conn_enter :: proc "contextless" (db: sqlite3) -> (ce: Conn_Enter) {
	ce.slot = slot_of(db)
	ce.kind = .Other
	if ce.slot < 0 do return // unregistered: exec-only timing, no wait split
	ce.kind = conn_slots[ce.slot].kind
	if tl_conn_depth[ce.slot] == 0 {
		ce.mutex = sqlite3_db_mutex(db)
		if ce.mutex != nil {
			observe_lock := ce.kind != .Other
			lock := CONN_LOCKS[ce.kind]
			t0 := time.tick_now()
			if sqlite3_mutex_try(ce.mutex) != SQLITE_OK {
				if observe_lock do dbt.begin_wait(lock)
				sqlite3_mutex_enter(ce.mutex)
				if observe_lock do dbt.end_wait(lock)
			}
			ce.wait_ns = i64(time.tick_since(t0))
			ce.entered = true
			if observe_lock do dbt.observe_ns(dbt.tm.lock_wait[lock], ce.wait_ns)
			dbt.add_component(.Conn_Wait, ce.wait_ns)
		}
	}
	tl_conn_depth[ce.slot] += 1
	return
}

conn_leave :: #force_inline proc "contextless" (ce: Conn_Enter) {
	if ce.slot < 0 do return
	tl_conn_depth[ce.slot] -= 1
	if ce.entered do sqlite3_mutex_leave(ce.mutex)
}

// record_call: shared tail for every wrapped API call. Must run while the
// connection mutex is still held (extended errcode is per connection).
@(private = "file")
record_call :: proc(db: sqlite3, ce: Conn_Enter, op: Op, rc: c.int, exec_ns: i64, loc: runtime.Source_Code_Location) {
	m := &sqlite_tm
	dbt.observe_ns(conn_op_series(&m.exec, m.exec_f, ce.kind, op), exec_ns)
	dbt.add_component(.Exec_Excl_Busy, exec_ns) // busy_wait is 0 until phase 2
	if is_error_rc(rc) {
		ext: c.int = 0
		if db != nil do ext = sqlite3_extended_errcode(db)
		code := err_code_of(rc, ext)
		dbt.counter_add(error_series(ce.kind, op, code), 1)
		if code == .Busy || code == .Busy_Snapshot || code == .Locked do dbt.note_busy_error()
	}
	dbt.note_call(CONN_LABELS[ce.kind], OP_LABELS[op], exec_ns, ce.wait_ns, file_basename(loc.file_path), loc.line)
	// Legacy family keeps its meaning: wall time of one step/exec call
	// including the connection-mutex wait (prepare/finalize were never in it).
	if op != .Prepare && op != .Finalize {
		dbt.observe_ns(legacy_series(op), exec_ns + ce.wait_ns)
		code := rc & 0xff
		if code == SQLITE_BUSY || code == SQLITE_LOCKED do metrics.counter_inc(sqlite_metrics.busy_total)
	}
}

file_basename :: proc "contextless" (path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' || path[i] == '\\' do return path[i + 1:]
	}
	return path
}

telemetry_step :: proc(stmt: sqlite3_stmt, loc: runtime.Source_Code_Location) -> c.int {
	db := sqlite3_db_handle(stmt)
	ce := conn_enter(db)
	defer conn_leave(ce)
	op := op_of(sqlite3_sql(stmt))
	first := sqlite3_stmt_busy(stmt) == 0
	t1 := time.tick_now()
	rc := sqlite3_step_raw(stmt)
	exec_ns := i64(time.tick_since(t1))
	vm := u64(sqlite3_stmt_status(stmt, SQLITE_STMTSTATUS_VM_STEP, 1))
	fs := u64(sqlite3_stmt_status(stmt, SQLITE_STMTSTATUS_FULLSCAN_STEP, 1))
	srt := u64(sqlite3_stmt_status(stmt, SQLITE_STMTSTATUS_SORT, 1))
	m := &sqlite_tm
	if first do dbt.counter_add(conn_op_series(&m.statements, m.statements_f, ce.kind, op), 1)
	dbt.note_step(first)
	if vm > 0 do dbt.counter_add(conn_op_series(&m.vm_steps, m.vm_f, ce.kind, op), vm)
	if fs > 0 do dbt.counter_add(conn_op_series(&m.fullscan, m.fullscan_f, ce.kind, op), fs)
	if srt > 0 do dbt.counter_add(conn_op_series(&m.sort, m.sort_f, ce.kind, op), srt)
	if tl_uow_active && (op == .Insert || op == .Update || op == .Delete) do tl_uow_wrote = true
	dedicated_tx_note_write(ce, op)
	site := site_slot(loc)
	site_series_add(site, ce.kind, u64(exec_ns if exec_ns > 0 else 0), vm, fs)
	record_call(db, ce, op, rc, exec_ns, loc)
	return rc
}

telemetry_exec :: proc(db: sqlite3, sql: cstring, callback: rawptr, arg: rawptr, errmsg: [^]cstring, loc: runtime.Source_Code_Location) -> c.int {
	ce := conn_enter(db)
	defer conn_leave(ce)
	op := op_of(sql)
	t1 := time.tick_now()
	rc := sqlite3_exec_raw(db, sql, callback, arg, errmsg)
	exec_ns := i64(time.tick_since(t1))
	dbt.counter_add(conn_op_series(&sqlite_tm.statements, sqlite_tm.statements_f, ce.kind, op), 1)
	dbt.note_step(true)
	if tl_uow_active && (op == .Insert || op == .Update || op == .Delete) do tl_uow_wrote = true
	dedicated_tx_track(ce, op, rc, t1)
	record_call(db, ce, op, rc, exec_ns, loc)
	return rc
}

// Dedicated connections (billing / enroll / vault) run every transaction as
// exec("BEGIN IMMEDIATE;") ... exec("COMMIT;"|"ROLLBACK;") under their own repo
// mutex, so the exec wrapper tracks them per slot on the owning thread instead
// of touching each commit path. The main connection's transactions are the UoW
// (tx.odin) and fts repair (fts_repair.odin), observed there.
@(thread_local, private = "file")
tl_dedicated_tx: [CONN_SLOT_COUNT]struct{open: bool, wrote: bool, start: time.Tick}

@(private = "file")
dedicated_tx_kind :: proc "contextless" (k: Conn_Kind) -> (Tx_Kind, bool) {
	#partial switch k {
	case .Billing: return .Billing, true
	case .Enroll:  return .Enroll, true
	case .Vault:   return .Vault, true
	}
	return .Uow, false
}

@(private = "file")
dedicated_tx_track :: proc(ce: Conn_Enter, op: Op, rc: c.int, start: time.Tick) {
	if ce.slot < 0 do return
	tk, ok := dedicated_tx_kind(ce.kind)
	if !ok do return
	t := &tl_dedicated_tx[ce.slot]
	#partial switch op {
	case .Begin:
		if rc == SQLITE_OK {
			t^ = {open = true, start = start}
		} else {
			tx_observe(ce.kind, tk, false, .Begin_Failed, start)
		}
	case .Commit:
		if !t.open do return
		tx_observe(ce.kind, tk, t.wrote, .Commit if rc == SQLITE_OK else .Commit_Failed, t.start)
		t^ = {}
	case .Rollback:
		if !t.open do return
		tx_observe(ce.kind, tk, t.wrote, .Rollback, t.start)
		t^ = {}
	}
}

@(private = "file")
dedicated_tx_note_write :: #force_inline proc "contextless" (ce: Conn_Enter, op: Op) {
	if ce.slot >= 0 && (op == .Insert || op == .Update || op == .Delete) && tl_dedicated_tx[ce.slot].open do tl_dedicated_tx[ce.slot].wrote = true
}

telemetry_prepare :: proc(db: sqlite3, zSql: cstring, nByte: c.int, ppStmt: [^]sqlite3_stmt, pzTail: [^]cstring, loc: runtime.Source_Code_Location) -> c.int {
	ce := conn_enter(db)
	defer conn_leave(ce)
	t1 := time.tick_now()
	rc := sqlite3_prepare_v2_raw(db, zSql, nByte, ppStmt, pzTail)
	record_call(db, ce, .Prepare, rc, i64(time.tick_since(t1)), loc)
	return rc
}

telemetry_finalize :: proc(stmt: sqlite3_stmt, loc: runtime.Source_Code_Location) -> c.int {
	db := sqlite3_db_handle(stmt)
	ce := conn_enter(db)
	defer conn_leave(ce)
	t1 := time.tick_now()
	rc := sqlite3_finalize_raw(stmt)
	// finalize echoes the statement's last step error, which that step already
	// counted: record time only, never a second error.
	record_call(db, ce, .Finalize, SQLITE_OK, i64(time.tick_since(t1)), loc)
	_ = rc
	return rc
}

// ---------------------------------------------------------------------------
// Call-site table (plan §2.2a): fixed 512-entry open-addressed table keyed by
// the static file_path / procedure string pointers of #caller_location.

SITE_TABLE_SIZE :: 512

Site_Slot :: struct {
	ready:     u32, // atomic; fields below are valid once 1
	file_ptr:  uintptr,
	proc_ptr:  uintptr,
	label:     string,
	exec:      [Conn_Kind]^metrics.Series, // atomic pointers, created lazily per conn
	vm:        [Conn_Kind]^metrics.Series,
	fullscan:  [Conn_Kind]^metrics.Series,
}

site_table: [SITE_TABLE_SIZE]Site_Slot
@(private = "file")
site_mu: sync.Mutex
@(private = "file")
site_overflow: Site_Slot

SITE_OVERFLOW_LABEL :: "overflow"

site_slot :: proc(loc: runtime.Source_Code_Location) -> ^Site_Slot {
	fp := uintptr(raw_data(loc.file_path))
	pp := uintptr(raw_data(loc.procedure))
	h := (u64(fp) * 0x9E3779B97F4A7C15 ~ u64(pp) * 0xC2B2AE3D27D4EB4F) >> 7
	start := int(h % SITE_TABLE_SIZE)
	for probe in 0..<SITE_TABLE_SIZE {
		s := &site_table[(start + probe) % SITE_TABLE_SIZE]
		if sync.atomic_load_explicit(&s.ready, .Acquire) == 0 do return site_insert(loc, fp, pp, start)
		if s.file_ptr == fp && s.proc_ptr == pp do return s
	}
	return site_overflow_slot()
}

@(private = "file")
site_insert :: proc(loc: runtime.Source_Code_Location, fp, pp: uintptr, start: int) -> ^Site_Slot {
	sync.lock(&site_mu)
	defer sync.unlock(&site_mu)
	for probe in 0..<SITE_TABLE_SIZE {
		s := &site_table[(start + probe) % SITE_TABLE_SIZE]
		if sync.atomic_load(&s.ready) == 1 {
			if s.file_ptr == fp && s.proc_ptr == pp do return s
			continue
		}
		s.file_ptr = fp
		s.proc_ptr = pp
		s.label = strings.concatenate({file_basename(loc.file_path), ":", loc.procedure}, runtime.heap_allocator())
		sync.atomic_store_explicit(&s.ready, 1, .Release)
		return s
	}
	return site_overflow_slot()
}

@(private = "file")
site_overflow_slot :: proc() -> ^Site_Slot {
	if sync.atomic_load(&site_overflow.ready) == 0 {
		site_overflow.label = SITE_OVERFLOW_LABEL
		sync.atomic_store(&site_overflow.ready, 1)
	}
	return &site_overflow
}

@(private = "file")
site_series_add :: proc(s: ^Site_Slot, kind: Conn_Kind, exec_ns, vm, fs: u64) {
	if s == nil || sqlite_tm.site_exec == nil do return
	ex := sync.atomic_load_explicit(&s.exec[kind], .Acquire)
	if ex == nil {
		sync.lock(&site_mu)
		if s.exec[kind] == nil {
			s.vm[kind] = metrics.with(sqlite_tm.site_vm, CONN_LABELS[kind], s.label)
			s.fullscan[kind] = metrics.with(sqlite_tm.site_fullscan, CONN_LABELS[kind], s.label)
			sync.atomic_store_explicit(&s.exec[kind], metrics.with(sqlite_tm.site_exec, CONN_LABELS[kind], s.label), .Release)
		}
		ex = s.exec[kind]
		sync.unlock(&site_mu)
	}
	dbt.counter_add(ex, exec_ns)
	dbt.counter_add(s.vm[kind], vm)
	dbt.counter_add(s.fullscan[kind], fs)
}

// ---------------------------------------------------------------------------
// Transactions (dedicated-connection BEGIN IMMEDIATE paths and the UoW).

tx_observe :: proc(kind: Conn_Kind, tk: Tx_Kind, wrote: bool, outcome: Tx_Outcome, start: time.Tick) {
	if !dbt.enabled() || !sqlite_tm.initialised do return
	ns := i64(time.tick_since(start))
	dbt.observe_ns(tx_series(kind, tk, wrote, outcome), ns)
	dbt.note_tx(ns)
}

// ---------------------------------------------------------------------------
// Scrape collector: per-connection page-cache counters and the oldest open UoW.

@(private = "file")
sqlite_telemetry_collect :: proc(ctx: rawptr, e: ^metrics.Exposition) {
	names := []string{"conn", "kind"}
	cache_kinds := [4]struct{op: c.int, label: string}{
		{SQLITE_DBSTATUS_CACHE_HIT, "hit"}, {SQLITE_DBSTATUS_CACHE_MISS, "miss"},
		{SQLITE_DBSTATUS_CACHE_WRITE, "write"}, {SQLITE_DBSTATUS_CACHE_SPILL, "spill"},
	}
	totals: [Conn_Kind][4]i64
	{
		// Held across the reads so close() (which unregisters first) cannot free a handle mid-read.
		sync.lock(&conn_slots_mu)
		defer sync.unlock(&conn_slots_mu)
		for &s in conn_slots {
			db := sqlite3(sync.atomic_load(&s.db))
			if db == nil do continue
			for ck, i in cache_kinds {
				cur, hi: c.int
				if sqlite3_db_status(db, ck.op, &cur, &hi, 0) == SQLITE_OK do totals[s.kind][i] += i64(cur)
			}
		}
	}
	metrics.expo_header(e, "heimdall_sqlite_cache_events_total", "Page-cache events per connection kind (sqlite3_db_status, cumulative).", .Counter)
	for k in Conn_Kind {
		if totals[k] == {} do continue
		for ck, i in cache_kinds {
			values := []string{CONN_LABELS[k], ck.label}
			metrics.expo_sample_i64(e, "heimdall_sqlite_cache_events_total", names, values, totals[k][i])
		}
	}
	metrics.expo_header(e, "heimdall_db_uow_oldest_hold_seconds", "Age of the open outer unit of work (0 if none).", .Gauge)
	metrics.expo_sample_i64(e, "heimdall_db_uow_oldest_hold_seconds", nil, nil, uow_oldest_hold_ns(), 9)
}
