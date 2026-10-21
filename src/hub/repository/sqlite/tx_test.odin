package sqlite

import "core:fmt"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(private = "file")
tx_test_db :: proc(t: ^testing.T, tag: string) -> (Conn, string, bool) {
	conn, db_path, open_ok := tmpl_open_file_prod(t, fmt.tprintf("tx_%s", tag))
	if !open_ok do return conn, "", false
	exec(&conn, "CREATE TABLE IF NOT EXISTS tx_probe (k TEXT PRIMARY KEY, v INTEGER NOT NULL);")
	return conn, db_path, true
}

Tx_Worker :: struct {
	factory:   ^iface.Unit_Of_Work_Factory,
	conn:      ^Conn,
	started:   bool,
	entered_ns: i64,
	done:      bool,
}

@(private = "file")
tx_worker_proc :: proc(t: ^thread.Thread) {
	w := (^Tx_Worker)(t.data)
	sync.atomic_store(&w.started, true)
	uow, ok, _ := iface.unit_of_work_begin(w.factory)
	sync.atomic_store(&w.entered_ns, time.now()._nsec)
	if ok {
		exec(w.conn, "INSERT OR REPLACE INTO tx_probe (k, v) VALUES ('b', 2);")
		_, _ = iface.unit_of_work_commit(&uow)
	}
	sync.atomic_store(&w.done, true)
}

// test_tx_mutex_serializes_uow: a second thread's BEGIN must wait for the first
// unit of work to COMMIT (Task System v2 §2.1). Without the process-wide mutex
// the second BEGIN on the shared handle fails ("cannot start a transaction
// within a transaction") or its writes land inside the first transaction.
@(test)
test_tx_mutex_serializes_uow :: proc(t: ^testing.T) {
	conn, db_path, ok := tx_test_db(t, "serial")
	defer tmpl_remove_db(db_path)
	if !ok do return
	defer close(&conn)
	factory_impl: SQLite_Unit_Of_Work_Factory
	repos: iface.Repositories
	factory := new_unit_of_work_factory(&factory_impl, &conn, &repos)

	// Thread A owns a UoW.
	uow_a, a_ok, _ := iface.unit_of_work_begin(&factory)
	if !testing.expect(t, a_ok, "first begin ok") do return
	testing.expect(t, !tx_mutex_try_lock(), "mutex is held while a UoW is open")
	exec(&conn, "INSERT OR REPLACE INTO tx_probe (k, v) VALUES ('a', 1);")

	// Thread B tries to begin; it must block until A commits.
	w := Tx_Worker{factory = &factory, conn = &conn}
	th := thread.create(tx_worker_proc)
	th.data = &w
	thread.start(th)
	for !sync.atomic_load(&w.started) do time.sleep(time.Millisecond)
	time.sleep(60 * time.Millisecond)
	testing.expect(t, sync.atomic_load(&w.entered_ns) == 0, "second begin must not enter while the first UoW is open")

	released_ns := time.now()._nsec
	committed, _ := iface.unit_of_work_commit(&uow_a)
	testing.expect(t, committed, "first commit ok")
	for !sync.atomic_load(&w.done) do time.sleep(time.Millisecond)
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, sync.atomic_load(&w.entered_ns) >= released_ns, "second begin entered only after the first commit")
	testing.expect(t, tx_mutex_try_lock(), "mutex is free once every UoW is closed")

	// Both writes are durable (B's was not swallowed by A's transaction).
	stmt: sqlite3_stmt
	q := "SELECT COUNT(*) FROM tx_probe;"
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(q)), -1, &stmt, nil) == SQLITE_OK {
		defer sqlite3_finalize(stmt)
		if sqlite3_step(stmt) == SQLITE_ROW do testing.expect_value(t, int(sqlite3_column_int64(stmt, 0)), 2)
	}
}

// test_tx_uow_nested_savepoint: the same thread may begin a second UoW inside
// its own (card accept → chain close → engine). The inner one is a SAVEPOINT:
// an inner rollback undoes only the inner writes; the mutex is released once,
// at the outer commit.
@(test)
test_tx_uow_nested_savepoint :: proc(t: ^testing.T) {
	conn, db_path, ok := tx_test_db(t, "nested")
	defer tmpl_remove_db(db_path)
	if !ok do return
	defer close(&conn)
	factory_impl: SQLite_Unit_Of_Work_Factory
	repos: iface.Repositories
	factory := new_unit_of_work_factory(&factory_impl, &conn, &repos)

	outer, o_ok, _ := iface.unit_of_work_begin(&factory)
	if !testing.expect(t, o_ok, "outer begin ok") do return
	exec(&conn, "INSERT OR REPLACE INTO tx_probe (k, v) VALUES ('outer', 1);")

	inner, i_ok, i_err := iface.unit_of_work_begin(&factory)
	if !testing.expect(t, i_ok, fmt.tprintf("nested begin ok: %s", i_err.message)) do return
	exec(&conn, "INSERT OR REPLACE INTO tx_probe (k, v) VALUES ('inner', 2);")
	iface.unit_of_work_rollback(&inner)
	testing.expect(t, !tx_mutex_try_lock(), "mutex still held after the nested rollback")

	inner2, i2_ok, _ := iface.unit_of_work_begin(&factory)
	if !testing.expect(t, i2_ok, "second nested begin ok") do return
	exec(&conn, "INSERT OR REPLACE INTO tx_probe (k, v) VALUES ('inner2', 3);")
	committed, _ := iface.unit_of_work_commit(&inner2)
	testing.expect(t, committed, "nested commit (RELEASE) ok")
	testing.expect(t, !tx_mutex_try_lock(), "mutex still held after the nested commit")

	outer_committed, _ := iface.unit_of_work_commit(&outer)
	testing.expect(t, outer_committed, "outer commit ok")
	testing.expect(t, tx_mutex_try_lock(), "mutex released at the outer commit")

	count_of :: proc(conn: ^Conn, k: string) -> int {
		stmt: sqlite3_stmt
		q := "SELECT COUNT(*) FROM tx_probe WHERE k = ?;"
		if sqlite3_prepare_v2(conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return -1
		defer sqlite3_finalize(stmt)
		bind_text(stmt, 1, k)
		if sqlite3_step(stmt) == SQLITE_ROW do return int(sqlite3_column_int64(stmt, 0))
		return -1
	}
	testing.expect_value(t, count_of(&conn, "outer"), 1)
	testing.expect_value(t, count_of(&conn, "inner"), 0)
	testing.expect_value(t, count_of(&conn, "inner2"), 1)
	_ = domain.Domain_Error{}
}
