package sqlite

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import iface "odin_test:hub/repository/iface"
import dbt "odin_test:hub/platform/dbtelemetry"
import metrics "odin_test:lib/metrics"

// DB latency telemetry (plan §4.3). These tests flip the process-global
// telemetry mode and assert exact counter deltas on shared series, so they
// only run single-threaded in their own binary: verify-db-telemetry.sh passes
// -define:DBT_TESTS=true -define:ODIN_TEST_THREADS=1. In a plain package run
// they are skipped (concurrent tests would move the shared counters).
DBT_TESTS :: #config(DBT_TESTS, false)

@(private = "file")
dbt_enable :: proc() {
	dbt.set_mode(.Basic)
	reg := metrics.init_global()
	sqlite_metrics_init(reg)
	dbt.init(reg)
}

@(private = "file")
dbt_open :: proc(t: ^testing.T, tag: string, kind: Conn_Kind) -> (Conn, string, bool) {
	path := tmpl_tmp_db_path(tag)
	tmpl_remove_db(path)
	conn, ok, _ := open(path, kind)
	testing.expect(t, ok, "open")
	if ok do testing.expect(t, exec(&conn, "CREATE TABLE IF NOT EXISTS p (k INTEGER PRIMARY KEY, v INTEGER);"), "create")
	return conn, path, ok
}

@(private = "file")
dbt_prepare :: proc(conn: ^Conn, sql: string) -> sqlite3_stmt {
	stmt: sqlite3_stmt
	sqlite3_prepare_v2(conn.db, strings.clone_to_cstring(sql, context.temp_allocator), -1, &stmt, nil)
	return stmt
}

@(private = "file")
Holder :: struct {
	db:       sqlite3,
	hold:     time.Duration,
	entered:  bool,
	released: bool,
}

@(private = "file")
holder_proc :: proc(th: ^thread.Thread) {
	h := (^Holder)(th.data)
	m := sqlite3_db_mutex(h.db)
	sqlite3_mutex_enter(m)
	sync.atomic_store(&h.entered, true)
	time.sleep(h.hold)
	sqlite3_mutex_leave(m)
	sync.atomic_store(&h.released, true)
}

@(test)
test_db_conn_wait_split :: proc(t: ^testing.T) {
	if !DBT_TESTS do return
	dbt_enable()
	conn, path, ok := dbt_open(t, "dbt_wait", .Main)
	defer tmpl_remove_db(path)
	if !ok do return
	defer close(&conn)
	stmt := dbt_prepare(&conn, "SELECT count(*) FROM p;")
	defer sqlite3_finalize(stmt)
	waits_before := metrics.histogram_count(dbt.tm.lock_wait[.Conn_Main])
	contended_before := metrics.counter_value(dbt.tm.contended[.Conn_Main])

	h := Holder{db = conn.db, hold = 50 * time.Millisecond}
	th := thread.create(holder_proc)
	th.data = &h
	thread.start(th)
	for !sync.atomic_load(&h.entered) do time.sleep(100 * time.Microsecond)

	dbt.scope_begin(.Other)
	rc := sqlite3_step(stmt)
	totals, closed := dbt.scope_end()
	thread.join(th)
	thread.destroy(th)

	testing.expect_value(t, rc, c.int(SQLITE_ROW))
	testing.expect(t, closed, "scope flushed")
	testing.expectf(t, totals.component[.Conn_Wait] >= i64(40 * time.Millisecond), "conn_wait %d ns, want >= 40ms", totals.component[.Conn_Wait])
	testing.expectf(t, totals.component[.Exec_Excl_Busy] < i64(10 * time.Millisecond), "exec %d ns, want < 10ms", totals.component[.Exec_Excl_Busy])
	testing.expect(t, metrics.histogram_count(dbt.tm.lock_wait[.Conn_Main]) == waits_before + 1, "one conn_main wait observation")
	testing.expect(t, metrics.counter_value(dbt.tm.contended[.Conn_Main]) == contended_before + 1, "contended once")
	testing.expect_value(t, metrics.gauge_value(dbt.tm.waiters[.Conn_Main]), i64(0))
}

@(test)
test_step_changes_single_wait :: proc(t: ^testing.T) {
	if !DBT_TESTS do return
	dbt_enable()
	conn, path, ok := dbt_open(t, "dbt_changes", .Main)
	defer tmpl_remove_db(path)
	if !ok do return
	defer close(&conn)
	stmt := dbt_prepare(&conn, "INSERT INTO p (k, v) VALUES (1, 1);")
	defer sqlite3_finalize(stmt)
	before := metrics.histogram_count(dbt.tm.lock_wait[.Conn_Main])
	rc, changes := step_changes(conn.db, stmt)
	testing.expect_value(t, rc, c.int(SQLITE_DONE))
	testing.expect_value(t, changes, 1)
	testing.expect_value(t, metrics.histogram_count(dbt.tm.lock_wait[.Conn_Main]), before + 1)
}

@(private = "file")
tx_count :: proc(kind: Tx_Kind, wrote: bool, o: Tx_Outcome) -> u64 {
	if sqlite_tm.tx_f == nil do return 0
	rw := "write" if wrote else "read"
	return metrics.histogram_count(metrics.with(sqlite_tm.tx_f, "main", TX_KIND_LABELS[kind], rw, TX_OUTCOME_LABELS[o]))
}

@(test)
test_uow_wait_hold_outcomes :: proc(t: ^testing.T) {
	if !DBT_TESTS do return
	dbt_enable()
	conn, path, ok := dbt_open(t, "dbt_uow", .Main)
	defer tmpl_remove_db(path)
	if !ok do return
	defer close(&conn)
	exec(&conn, "CREATE TABLE parent (id INTEGER PRIMARY KEY);")
	exec(&conn, "CREATE TABLE child (pid INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED);")
	factory_impl: SQLite_Unit_Of_Work_Factory
	repos: iface.Repositories
	factory := new_unit_of_work_factory(&factory_impl, &conn, &repos)
	hold_before := metrics.histogram_count(dbt.tm.lock_hold[.Uow_Tx])

	c0, r0 := tx_count(.Uow, true, .Commit), tx_count(.Uow, false, .Rollback)
	uow, b_ok, _ := iface.unit_of_work_begin(&factory)
	testing.expect(t, b_ok, "begin")
	testing.expect_value(t, metrics.gauge_value(dbt.tm.held[.Uow_Tx]), i64(1))
	exec(&conn, "INSERT INTO p (k, v) VALUES (10, 1);")
	committed, _ := iface.unit_of_work_commit(&uow)
	testing.expect(t, committed, "commit")
	testing.expect_value(t, tx_count(.Uow, true, .Commit), c0 + 1)

	uow, b_ok, _ = iface.unit_of_work_begin(&factory)
	iface.unit_of_work_rollback(&uow)
	testing.expect_value(t, tx_count(.Uow, false, .Rollback), r0 + 1)

	// COMMIT failure: a deferred FK violation fails at COMMIT time.
	cf := tx_count(.Uow, true, .Commit_Failed)
	uow, b_ok, _ = iface.unit_of_work_begin(&factory)
	exec(&conn, "INSERT INTO child (pid) VALUES (999);")
	committed, _ = iface.unit_of_work_commit(&uow)
	testing.expect(t, !committed, "commit must fail on deferred FK")
	testing.expect_value(t, tx_count(.Uow, true, .Commit_Failed), cf + 1)

	// BEGIN failure: a transaction is already open on the handle.
	bf := tx_count(.Uow, false, .Begin_Failed)
	exec(&conn, "BEGIN;")
	_, b_ok, _ = iface.unit_of_work_begin(&factory)
	testing.expect(t, !b_ok, "begin must fail inside an open transaction")
	exec(&conn, "ROLLBACK;")
	testing.expect_value(t, tx_count(.Uow, false, .Begin_Failed), bf + 1)

	testing.expect_value(t, metrics.histogram_count(dbt.tm.lock_hold[.Uow_Tx]), hold_before + 4)
	testing.expect_value(t, metrics.gauge_value(dbt.tm.held[.Uow_Tx]), i64(0))
	testing.expect_value(t, metrics.gauge_value(dbt.tm.waiters[.Uow_Tx]), i64(0))
	testing.expect_value(t, uow_oldest_hold_ns(), i64(0))
	testing.expect(t, tx_mutex_try_lock(), "tx_mutex released")
}

@(test)
test_uow_nested_no_double_count :: proc(t: ^testing.T) {
	if !DBT_TESTS do return
	dbt_enable()
	conn, path, ok := dbt_open(t, "dbt_nested", .Main)
	defer tmpl_remove_db(path)
	if !ok do return
	defer close(&conn)
	factory_impl: SQLite_Unit_Of_Work_Factory
	repos: iface.Repositories
	factory := new_unit_of_work_factory(&factory_impl, &conn, &repos)
	hold0 := metrics.histogram_count(dbt.tm.lock_hold[.Uow_Tx])
	wait0 := metrics.histogram_count(dbt.tm.lock_wait[.Uow_Tx])
	nested0 := metrics.counter_value(sqlite_tm.uow_nested)
	c0 := tx_count(.Uow, false, .Commit)

	outer, _, _ := iface.unit_of_work_begin(&factory)
	n1, _, _ := iface.unit_of_work_begin(&factory)
	n2, _, _ := iface.unit_of_work_begin(&factory)
	testing.expect(t, uow_oldest_hold_ns() > 0, "open UoW has an age")
	iface.unit_of_work_commit(&n2)
	iface.unit_of_work_commit(&n1)
	iface.unit_of_work_commit(&outer)

	testing.expect_value(t, tx_count(.Uow, false, .Commit), c0 + 1)
	testing.expect_value(t, metrics.histogram_count(dbt.tm.lock_hold[.Uow_Tx]), hold0 + 1)
	testing.expect_value(t, metrics.histogram_count(dbt.tm.lock_wait[.Uow_Tx]), wait0 + 1)
	testing.expect_value(t, metrics.counter_value(sqlite_tm.uow_nested), nested0 + 2)
}

@(private = "file")
Lock_Worker :: struct {
	mu:   ^sync.Mutex,
	lock: dbt.Lock,
	done: bool,
}

@(private = "file")
lock_worker_proc :: proc(th: ^thread.Thread) {
	w := (^Lock_Worker)(th.data)
	tok := dbt.timed_lock(w.mu, w.lock)
	dbt.timed_unlock(w.mu, w.lock, tok)
	sync.atomic_store(&w.done, true)
}

@(test)
test_dedicated_mutex_timed :: proc(t: ^testing.T) {
	if !DBT_TESTS do return
	dbt_enable()
	// Dedicated repo mutex helper: one contended acquisition, two holds.
	mu: sync.Mutex
	wait0 := metrics.histogram_count(dbt.tm.lock_wait[.Billing])
	hold0 := metrics.histogram_count(dbt.tm.lock_hold[.Billing])
	cont0 := metrics.counter_value(dbt.tm.contended[.Billing])
	tok := dbt.timed_lock(&mu, .Billing)
	w := Lock_Worker{mu = &mu, lock = .Billing}
	th := thread.create(lock_worker_proc)
	th.data = &w
	thread.start(th)
	for metrics.gauge_value(dbt.tm.waiters[.Billing]) == 0 do time.sleep(100 * time.Microsecond)
	time.sleep(5 * time.Millisecond)
	dbt.timed_unlock(&mu, .Billing, tok)
	thread.join(th)
	thread.destroy(th)
	testing.expect_value(t, metrics.histogram_count(dbt.tm.lock_wait[.Billing]), wait0 + 2)
	testing.expect_value(t, metrics.histogram_count(dbt.tm.lock_hold[.Billing]), hold0 + 2)
	testing.expect_value(t, metrics.counter_value(dbt.tm.contended[.Billing]), cont0 + 1)
	testing.expect_value(t, metrics.gauge_value(dbt.tm.held[.Billing]), i64(0))
	testing.expect_value(t, metrics.gauge_value(dbt.tm.waiters[.Billing]), i64(0))

	// Dedicated-connection transaction tracked by the exec wrapper.
	conn, path, ok := dbt_open(t, "dbt_vault", .Vault)
	defer tmpl_remove_db(path)
	if !ok do return
	defer close(&conn)
	series := metrics.with(sqlite_tm.tx_f, "vault", "vault", "write", "commit")
	before := metrics.histogram_count(series)
	exec(&conn, "BEGIN IMMEDIATE;")
	stmt := dbt_prepare(&conn, "INSERT INTO p (k, v) VALUES (7, 7);")
	sqlite3_step(stmt)
	sqlite3_finalize(stmt)
	exec(&conn, "COMMIT;")
	testing.expect_value(t, metrics.histogram_count(series), before + 1)
}

// Pure mapping, not gated: unset means basic (the default), "off" is the
// explicit opt-out, and full / unknown values are rejected.
@(test)
test_parse_mode_default_basic :: proc(t: ^testing.T) {
	m, ok, _ := dbt.parse_mode("")
	testing.expect(t, ok && m == .Basic, "unset defaults to basic")
	m, ok, _ = dbt.parse_mode("basic")
	testing.expect(t, ok && m == .Basic, "basic")
	m, ok, _ = dbt.parse_mode("off")
	testing.expect(t, ok && m == .Off, "explicit off override")
	for bad in ([]string{"full", "on", "Off", " basic", "0"}) {
		_, bad_ok, msg := dbt.parse_mode(bad)
		testing.expectf(t, !bad_ok, "expected rejection for %q", bad)
		testing.expect(t, msg != "", "rejection carries a message")
	}
}

@(test)
test_telemetry_off_is_passthrough :: proc(t: ^testing.T) {
	if !DBT_TESTS do return
	dbt.set_mode(.Off)
	defer dbt_enable()
	reg: metrics.Registry
	metrics.registry_init(&reg, {})
	defer metrics.registry_destroy(&reg)
	dbt.init(&reg)
	for name in ([]string{"heimdall_db_lock_wait_seconds", "heimdall_db_scope_seconds_total", "heimdall_db_slow_log_dropped_total"}) {
		_, found := reg.by_name[name]
		testing.expectf(t, !found, "off must not register %s", name)
	}
	// Off: handles are not tagged and the wrappers never take the conn mutex themselves.
	conn, path, ok := dbt_open(t, "dbt_off", .Main)
	defer tmpl_remove_db(path)
	if !ok do return
	defer close(&conn)
	testing.expect_value(t, slot_of(conn.db), -1)
	waits0 := metrics.histogram_count(dbt.tm.lock_wait[.Conn_Main])
	stmt := dbt_prepare(&conn, "SELECT 1;")
	legacy0 := metrics.histogram_count(metrics.with(sqlite_metrics.query_duration, "select"))
	testing.expect_value(t, sqlite3_step(stmt), c.int(SQLITE_ROW))
	sqlite3_finalize(stmt)
	testing.expect_value(t, metrics.histogram_count(dbt.tm.lock_wait[.Conn_Main]), waits0)
	testing.expect_value(t, metrics.histogram_count(metrics.with(sqlite_metrics.query_duration, "select")), legacy0 + 1)
	_, scope_ok := dbt.scope_end()
	testing.expect(t, !scope_ok, "scopes are inert when off")
	m, mode_ok, _ := dbt.parse_mode("full")
	testing.expect(t, !mode_ok && m == .Off, "full is rejected explicitly")
	_, bogus_ok, _ := dbt.parse_mode("on")
	testing.expect(t, !bogus_ok, "unknown values are rejected")
}

@(test)
test_labels_bounded :: proc(t: ^testing.T) {
	if !DBT_TESTS do return
	dbt_enable()
	prefixes := []cstring{"SELECT", "/* x */ insert", "-- c\nupdate", "WITH", "explain query plan select", "VACUUM", "'; drop", "\x01\x02", "", "ATTACH 'x' AS y"}
	for p in prefixes {
		op := op_of(p)
		testing.expect(t, int(op) >= 0 && int(op) <= int(Op.Other), "op is an enum value")
	}
	// Every exposed (conn, op) label value is from the fixed enums.
	conn_ok := proc(v: string) -> bool { for l in CONN_LABELS do if l == v do return true; return false }
	op_ok := proc(v: string) -> bool { for l in OP_LABELS do if l == v do return true; return false }
	for s in sqlite_tm.exec_f.series {
		testing.expectf(t, conn_ok(s.label_values[0]) && op_ok(s.label_values[1]), "unbounded label %v", s.label_values)
	}
	for s in sqlite_tm.site_exec.series {
		v := s.label_values[1]
		testing.expectf(t, strings.contains(v, ".odin:") && !strings.contains(v, " "), "site label %q is file:procedure", v)
		testing.expectf(t, v != SITE_OVERFLOW_LABEL, "site table overflowed")
	}
}

@(private = "file")
site_value :: proc(f: ^metrics.Family, site: string) -> u64 {
	if f == nil do return 0
	return metrics.counter_value(metrics.with(f, "main", site))
}

@(test)
test_site_attribution :: proc(t: ^testing.T) {
	if !DBT_TESTS do return
	dbt_enable()
	conn, path, ok := dbt_open(t, "dbt_site", .Main)
	defer tmpl_remove_db(path)
	if !ok do return
	defer close(&conn)
	exec(&conn, "CREATE TABLE scan (a INTEGER, b TEXT);")
	for i in 0..<20 do exec(&conn, fmt.tprintf("INSERT INTO scan VALUES (%d, 'x');", i))
	me := "db_telemetry_test.odin:test_site_attribution"
	fs0 := site_value(sqlite_tm.site_fullscan, me)
	vm0 := site_value(sqlite_tm.site_vm, me)
	ex0 := site_value(sqlite_tm.site_exec, me)
	helper_changes0 := site_value(sqlite_tm.site_exec, "conn.odin:step_changes")
	helper_heal0 := site_value(sqlite_tm.site_exec, "fts_repair.odin:step_write_healing")

	// Direct full-scan SELECT, stepped to DONE.
	stmt := dbt_prepare(&conn, "SELECT count(*) FROM scan WHERE b = 'x';")
	for sqlite3_step(stmt) == SQLITE_ROW {}
	sqlite3_finalize(stmt)
	testing.expect(t, site_value(sqlite_tm.site_fullscan, me) > fs0, "full scan charged to the calling procedure")
	testing.expect(t, site_value(sqlite_tm.site_vm, me) > vm0, "vm steps charged")

	// Through step_changes and step_write_healing: still the caller's site.
	ins := dbt_prepare(&conn, "INSERT INTO scan VALUES (100, 'y');")
	step_changes(conn.db, ins)
	sqlite3_finalize(ins)
	heal := dbt_prepare(&conn, "INSERT INTO scan VALUES (101, 'z');")
	step_write_healing(&conn, heal)
	sqlite3_finalize(heal)
	testing.expect(t, site_value(sqlite_tm.site_exec, me) > ex0, "exec time charged to the caller")
	testing.expect_value(t, site_value(sqlite_tm.site_exec, "conn.odin:step_changes"), helper_changes0)
	testing.expect_value(t, site_value(sqlite_tm.site_exec, "fts_repair.odin:step_write_healing"), helper_heal0)
}

@(test)
test_stmt_status_counters :: proc(t: ^testing.T) {
	if !DBT_TESTS do return
	dbt_enable()
	conn, path, ok := dbt_open(t, "dbt_status", .Main)
	defer tmpl_remove_db(path)
	if !ok do return
	defer close(&conn)
	exec(&conn, "CREATE TABLE s (a INTEGER);")
	for i in 0..<10 do exec(&conn, fmt.tprintf("INSERT INTO s VALUES (%d);", 10 - i))
	vm0 := metrics.counter_value(conn_op_series(&sqlite_tm.vm_steps, sqlite_tm.vm_f, .Main, .Select))
	sort0 := metrics.counter_value(conn_op_series(&sqlite_tm.sort, sqlite_tm.sort_f, .Main, .Select))
	stmt := dbt_prepare(&conn, "SELECT a FROM s ORDER BY a;")
	for sqlite3_step(stmt) == SQLITE_ROW {}
	sqlite3_finalize(stmt)
	testing.expect(t, metrics.counter_value(conn_op_series(&sqlite_tm.vm_steps, sqlite_tm.vm_f, .Main, .Select)) > vm0, "vm steps recorded")
	testing.expect_value(t, metrics.counter_value(conn_op_series(&sqlite_tm.sort, sqlite_tm.sort_f, .Main, .Select)), sort0 + 1)
}

@(test)
test_conn_kind_tagging :: proc(t: ^testing.T) {
	if !DBT_TESTS do return
	dbt_enable()
	kinds := []Conn_Kind{.Main, .Billing, .Enroll, .Vault, .Metrics}
	for k in kinds {
		conn, path, ok := dbt_open(t, fmt.tprintf("dbt_kind_%v", k), k)
		if ok {
			testing.expect_value(t, conn_kind_of(conn.db), k)
			db := conn.db
			close(&conn)
			testing.expect_value(t, slot_of(db), -1) // unregistered before close
		}
		tmpl_remove_db(path)
	}
	// Reopen with a different kind: never keeps the old tag.
	conn, path, ok := dbt_open(t, "dbt_kind_reopen", .Other)
	if ok do testing.expect_value(t, conn_kind_of(conn.db), Conn_Kind.Other)
	close(&conn)
	tmpl_remove_db(path)
	// Fill the table: the overflow handles are untagged (.Other, exec-only).
	conns: [CONN_SLOT_COUNT + 1]Conn
	paths: [CONN_SLOT_COUNT + 1]string
	for i in 0..<len(conns) do conns[i], paths[i], _ = dbt_open(t, fmt.tprintf("dbt_fill_%d", i), .Billing)
	last := conns[len(conns) - 1]
	testing.expect_value(t, slot_of(last.db), -1)
	testing.expect_value(t, conn_kind_of(last.db), Conn_Kind.Other)
	stmt := dbt_prepare(&conns[len(conns) - 1], "SELECT 1;")
	testing.expect_value(t, sqlite3_step(stmt), c.int(SQLITE_ROW)) // exec-only timing still works
	sqlite3_finalize(stmt)
	for i in 0..<len(conns) { close(&conns[i]); tmpl_remove_db(paths[i]) }
}

@(test)
test_statement_count_reuse :: proc(t: ^testing.T) {
	if !DBT_TESTS do return
	dbt_enable()
	conn, path, ok := dbt_open(t, "dbt_reuse", .Main)
	defer tmpl_remove_db(path)
	if !ok do return
	defer close(&conn)
	for i in 0..<5 do exec(&conn, fmt.tprintf("INSERT INTO p (k, v) VALUES (%d, %d);", 100 + i, i))
	sel := conn_op_series(&sqlite_tm.statements, sqlite_tm.statements_f, .Main, .Select)
	ins := conn_op_series(&sqlite_tm.statements, sqlite_tm.statements_f, .Main, .Insert)

	s0 := metrics.counter_value(sel)
	stmt := dbt_prepare(&conn, "SELECT v FROM p WHERE k >= 100 ORDER BY k;")
	steps := 0
	for sqlite3_step(stmt) == SQLITE_ROW do steps += 1
	sqlite3_finalize(stmt)
	testing.expect_value(t, steps, 5)
	testing.expect_value(t, metrics.counter_value(sel), s0 + 1) // 6 step calls, one statement

	i0 := metrics.counter_value(ins)
	up := dbt_prepare(&conn, "INSERT OR REPLACE INTO p (k, v) VALUES (200, 1);")
	testing.expect_value(t, sqlite3_step(up), c.int(SQLITE_DONE))
	sqlite3_reset(up)
	testing.expect_value(t, sqlite3_step(up), c.int(SQLITE_DONE))
	sqlite3_finalize(up)
	testing.expect_value(t, metrics.counter_value(ins), i0 + 2)
}

@(private = "file")
Queue_Worker :: struct {
	mu: ^sync.Mutex,
}

@(private = "file")
queue_worker_proc :: proc(th: ^thread.Thread) {
	w := (^Queue_Worker)(th.data)
	tok := dbt.timed_lock(w.mu, .Projector)
	dbt.timed_unlock(w.mu, .Projector, tok)
}

@(test)
test_waiters_max_scrape_reset :: proc(t: ^testing.T) {
	if !DBT_TESTS do return
	dbt_enable()
	_ = dbt.waiters_max_take(.Projector)
	cont0 := metrics.counter_value(dbt.tm.contended[.Projector])
	mu: sync.Mutex
	tok := dbt.timed_lock(&mu, .Projector)
	w := Queue_Worker{mu = &mu}
	threads: [3]^thread.Thread
	for i in 0..<3 {
		threads[i] = thread.create(queue_worker_proc)
		threads[i].data = &w
		thread.start(threads[i])
	}
	for metrics.gauge_value(dbt.tm.waiters[.Projector]) < 3 do time.sleep(100 * time.Microsecond)
	dbt.timed_unlock(&mu, .Projector, tok)
	for th in threads { thread.join(th); thread.destroy(th) }
	testing.expect_value(t, metrics.gauge_value(dbt.tm.waiters[.Projector]), i64(0))
	testing.expect_value(t, metrics.counter_value(dbt.tm.contended[.Projector]), cont0 + 3)
	testing.expect_value(t, dbt.waiters_max_take(.Projector), i64(3)) // high-water survives
	testing.expect_value(t, dbt.waiters_max_take(.Projector), i64(0)) // reset by the "scrape"
}

// test_db_telemetry_bench is the §4.1 overhead gate: ns per wrapped call, off
// vs basic, for step (with site) and prepare+finalize. Prints, never asserts
// (timing on shared hosts is noisy); verify-db-telemetry.sh reports the lines.
@(test)
test_db_telemetry_bench :: proc(t: ^testing.T) {
	if !DBT_TESTS do return
	N :: 200_000
	run := proc(t: ^testing.T, mode: dbt.Mode, tag: string) -> (step_ns, prep_ns: f64) {
		dbt.set_mode(mode)
		if mode != .Off do dbt_enable()
		conn, path, ok := dbt_open(t, tag, .Main)
		defer tmpl_remove_db(path)
		if !ok do return
		defer close(&conn)
		stmt := dbt_prepare(&conn, "SELECT 1;")
		start := time.tick_now()
		for _ in 0..<N {
			sqlite3_step(stmt)
			sqlite3_reset(stmt)
		}
		step_ns = f64(time.tick_since(start)) / N
		sqlite3_finalize(stmt)
		start = time.tick_now()
		for _ in 0..<N / 4 {
			s := dbt_prepare(&conn, "SELECT 1;")
			sqlite3_finalize(s)
		}
		prep_ns = f64(time.tick_since(start)) / (N / 4)
		return
	}
	off_step, off_prep := run(t, .Off, "dbt_bench_off")
	on_step, on_prep := run(t, .Basic, "dbt_bench_on")
	fmt.printfln("DBT_BENCH step+reset ns/iter: off=%.1f basic=%.1f delta=%.1f", off_step, on_step, on_step - off_step)
	fmt.printfln("DBT_BENCH prepare+finalize ns/iter: off=%.1f basic=%.1f delta=%.1f (two wrapped calls)", off_prep, on_prep, on_prep - off_prep)
	dbt_enable()
}
