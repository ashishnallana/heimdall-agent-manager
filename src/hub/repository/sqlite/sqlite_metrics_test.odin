package sqlite

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import metrics "odin_test:lib/metrics"

// heimdall_sqlite_* families: every statement is observed through the
// sqlite3_step / sqlite3_exec wrappers, labelled by a fixed op enum.

@(test)
test_sqlite_op_from_sql_enum :: proc(t: ^testing.T) {
	cases := []struct{ sql: cstring, want: string }{
		{"SELECT 1;", "select"},
		{"  \n\tselect * from users", "select"},
		{"-- comment\nINSERT INTO t VALUES (1);", "insert"},
		{"/* block */ UPDATE t SET a = 1;", "update"},
		{"DELETE FROM t;", "delete"},
		{"BEGIN;", "begin"},
		{"COMMIT;", "commit"},
		{"END;", "commit"},
		{"ROLLBACK;", "rollback"},
		{"PRAGMA foreign_keys = ON;", "pragma"},
		{"CREATE TABLE IF NOT EXISTS t(a);", "create"},
		{"WITH x AS (SELECT 1) SELECT * FROM x;", "select"},
		{"REPLACE INTO t VALUES (1);", "insert"},
		{"DROP TABLE t;", "other"},
		{"ALTER TABLE t ADD COLUMN b;", "other"},
		{"", "other"},
		{"   ", "other"},
		{"'; DROP TABLE users; --", "other"},
	}
	for tc in cases {
		got := sqlite_op_from_sql(tc.sql)
		testing.expectf(t, got == tc.want, "op(%q) = %q, want %q", string(tc.sql), got, tc.want)
	}
	testing.expect_value(t, sqlite_op_from_sql(nil), "other")
}

@(test)
test_sqlite_metrics_observe_step_and_exec :: proc(t: ^testing.T) {
	sqlite_metrics_init(metrics.init_global())
	db_path := fmt.tprintf("/tmp/test_sqlite_metrics_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	create_before := metrics.histogram_count(metrics.with(sqlite_metrics.query_duration, "create"))
	insert_before := metrics.histogram_count(metrics.with(sqlite_metrics.query_duration, "insert"))
	select_before := metrics.histogram_count(metrics.with(sqlite_metrics.query_duration, "select"))
	pragma_before := metrics.histogram_count(metrics.with(sqlite_metrics.query_duration, "pragma"))

	conn, open_ok, _ := open(db_path)
	testing.expect(t, open_ok, "open")
	defer close(&conn)
	// open() itself runs PRAGMA foreign_keys through exec.
	testing.expect(t, metrics.histogram_count(metrics.with(sqlite_metrics.query_duration, "pragma")) >= pragma_before + 1, "pragma observed via exec")

	testing.expect(t, exec(&conn, "CREATE TABLE m(a INTEGER);"), "create")
	testing.expect(t, exec(&conn, "INSERT INTO m VALUES (1); INSERT INTO m VALUES (2);"), "insert")

	// prepare + step path: 2 rows -> 3 step calls (ROW, ROW, DONE).
	stmt: sqlite3_stmt
	query := "SELECT a FROM m ORDER BY a;"
	testing.expect(t, sqlite3_prepare_v2(conn.db, strings.clone_to_cstring(query, context.temp_allocator), -1, &stmt, nil) == SQLITE_OK, "prepare")
	steps := 0
	for sqlite3_step(stmt) == SQLITE_ROW do steps += 1
	sqlite3_finalize(stmt)
	testing.expect_value(t, steps, 2)

	// Tests run concurrently against one global registry, so assert lower bounds.
	testing.expect(t, metrics.histogram_count(metrics.with(sqlite_metrics.query_duration, "create")) - create_before >= 1, "create observed")
	testing.expect(t, metrics.histogram_count(metrics.with(sqlite_metrics.query_duration, "insert")) - insert_before >= 1, "insert observed (one exec = one observation)")
	testing.expect(t, metrics.histogram_count(metrics.with(sqlite_metrics.query_duration, "select")) - select_before >= 3, "three step calls observed")
}

@(test)
test_sqlite_busy_counter_on_lock_contention :: proc(t: ^testing.T) {
	sqlite_metrics_init(metrics.init_global())
	db_path := fmt.tprintf("/tmp/test_sqlite_busy_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	writer, ok1, _ := open(db_path)
	testing.expect(t, ok1, "open writer")
	defer close(&writer)
	testing.expect(t, exec(&writer, "CREATE TABLE b(a INTEGER);"), "create")

	other, ok2, _ := open(db_path)
	testing.expect(t, ok2, "open second connection")
	defer close(&other)
	// No busy_timeout on `other`, so a write against a held RESERVED lock fails
	// immediately with SQLITE_BUSY instead of waiting.
	testing.expect(t, exec(&writer, "BEGIN IMMEDIATE;"), "writer holds the write lock")
	busy_before := metrics.counter_value(sqlite_metrics.busy_total)
	testing.expect(t, !exec(&other, "INSERT INTO b VALUES (1);"), "second writer is refused")
	testing.expect(t, exec(&writer, "ROLLBACK;"), "release")
	testing.expect(t, metrics.counter_value(sqlite_metrics.busy_total) - busy_before >= 1, "SQLITE_BUSY counted")
}

@(test)
test_sqlite_size_collector_tracks_open_path :: proc(t: ^testing.T) {
	reg := metrics.init_global()
	sqlite_metrics_init(reg)
	db_path := fmt.tprintf("/tmp/test_sqlite_size_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	conn, ok, _ := open(db_path)
	testing.expect(t, ok, "open")
	defer close(&conn)
	testing.expect(t, exec(&conn, "CREATE TABLE s(a INTEGER); INSERT INTO s VALUES (1);"), "write something")

	size, size_ok := sqlite_file_size(db_path)
	testing.expect(t, size_ok && size > 0, "db file has a size")
	_, missing_ok := sqlite_file_size("/tmp/definitely/not/here.db")
	testing.expect(t, !missing_ok, "missing file reports !ok")

	// Tests in this package open many databases concurrently, so pin the
	// tracked file explicitly rather than relying on open()'s first-wins rule.
	sqlite_metrics_set_db_path(db_path)
	defer sqlite_metrics_set_db_path("")
	buf: [4096]u8
	testing.expect_value(t, sqlite_metrics_tracked_path(buf[:]), db_path)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	metrics.gather(reg, &b)
	out := strings.to_string(b)
	testing.expect(t, strings.contains(out, fmt.tprintf("heimdall_sqlite_db_bytes %d\n", size)), "db_bytes exposes the file size")
	testing.expect(t, strings.contains(out, "heimdall_sqlite_wal_bytes 0\n"), "wal_bytes exposes 0 when no -wal file exists")
}
