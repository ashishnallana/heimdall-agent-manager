package sqlite

import "core:testing"

// REQ-CACHE: the main-connection cache pragma takes effect on a file database and is
// per connection, so a second connection to the same file (vault/enroll/billing/
// metrics in production) keeps SQLite's default and the RSS budget stays bounded.
@(test)
test_main_conn_cache_size_is_per_connection :: proc(t: ^testing.T) {
	db_path := tmpl_tmp_db_path("main_cache_size")
	tmpl_remove_db(db_path)
	defer tmpl_remove_db(db_path)

	main_conn, main_ok, _ := open(db_path, .Main)
	testing.expect(t, main_ok, "main open")
	defer close(&main_conn)
	other, other_ok, _ := open(db_path)
	testing.expect(t, other_ok, "second open")
	defer close(&other)

	testing.expect(t, exec(&main_conn, MAIN_CONN_CACHE_SIZE_PRAGMA), "cache_size pragma")
	testing.expect_value(t, mcs_cache_size(&main_conn), -8000)
	testing.expect_value(t, mcs_cache_size(&other), -2000)
	testing.expect_value(t, mcs_mmap_size(&main_conn), 0)
}

@(private = "file")
mcs_pragma_i64 :: proc(conn: ^Conn, sql: cstring) -> i64 {
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(conn.db, sql, -1, &stmt, nil) != SQLITE_OK do return min(i64)
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return min(i64)
	return sqlite3_column_int64(stmt, 0)
}

@(private = "file")
mcs_cache_size :: proc(conn: ^Conn) -> i64 { return mcs_pragma_i64(conn, "PRAGMA cache_size;") }

@(private = "file")
mcs_mmap_size :: proc(conn: ^Conn) -> i64 { return mcs_pragma_i64(conn, "PRAGMA mmap_size;") }
