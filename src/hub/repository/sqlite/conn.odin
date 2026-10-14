package sqlite

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import domain "odin_test:hub/domain"

// SQLite FFI lives only in hub/repository/sqlite. Higher layers receive Conn through
// repository interfaces and never import this package except from the app composition root.
foreign import sqlite3_lib "system:sqlite3"

sqlite3 :: distinct rawptr
sqlite3_stmt :: distinct rawptr

SQLITE_OK :: 0
SQLITE_CORRUPT :: 11 // "database disk image is malformed" — e.g. an external-content fts5 sync trigger's 'delete' op against a row missing from its index (see fts_repair.odin).
SQLITE_ROW :: 100
SQLITE_DONE :: 101
SQLITE_TRANSIENT :: rawptr(~uintptr(0))

@(default_calling_convention="c")
foreign sqlite3_lib {
	sqlite3_open :: proc(filename: cstring, ppDb: [^]sqlite3) -> c.int ---
	sqlite3_close :: proc(db: sqlite3) -> c.int ---
	sqlite3_prepare_v2 :: proc(db: sqlite3, zSql: cstring, nByte: c.int, ppStmt: [^]sqlite3_stmt, pzTail: [^]cstring) -> c.int ---
	sqlite3_finalize :: proc(pStmt: sqlite3_stmt) -> c.int ---
	// step/exec are the two choke points every query in this package passes
	// through, so they are bound under *_raw names and wrapped below with the
	// timing + busy accounting (sqlite_metrics.odin). Callers keep using the
	// plain names, which resolve to the wrappers.
	@(link_name="sqlite3_step")
	sqlite3_step_raw :: proc(pStmt: sqlite3_stmt) -> c.int ---
	sqlite3_reset :: proc(pStmt: sqlite3_stmt) -> c.int ---
	@(link_name="sqlite3_exec")
	sqlite3_exec_raw :: proc(db: sqlite3, sql: cstring, callback: rawptr, arg: rawptr, errmsg: [^]cstring) -> c.int ---
	sqlite3_sql :: proc(pStmt: sqlite3_stmt) -> cstring ---
	sqlite3_column_int64 :: proc(pStmt: sqlite3_stmt, iCol: c.int) -> i64 ---
	sqlite3_errmsg :: proc(db: sqlite3) -> cstring ---
	sqlite3_bind_text :: proc(pStmt: sqlite3_stmt, index: c.int, value: cstring, n: c.int, destructor: rawptr) -> c.int ---
	sqlite3_bind_double :: proc(pStmt: sqlite3_stmt, index: c.int, value: c.double) -> c.int ---
	sqlite3_bind_int :: proc(pStmt: sqlite3_stmt, index: c.int, value: c.int) -> c.int ---
	sqlite3_bind_null :: proc(pStmt: sqlite3_stmt, index: c.int) -> c.int ---
	sqlite3_column_text :: proc(pStmt: sqlite3_stmt, iCol: c.int) -> cstring ---
	sqlite3_column_double :: proc(pStmt: sqlite3_stmt, iCol: c.int) -> c.double ---
	sqlite3_column_bytes :: proc(pStmt: sqlite3_stmt, iCol: c.int) -> c.int ---
	sqlite3_changes :: proc(db: sqlite3) -> c.int ---
	sqlite3_free :: proc(p: rawptr) ---
}

Conn :: struct {
	db: sqlite3,
	path: string,
}

open :: proc(path: string) -> (Conn, bool, domain.Domain_Error) {
	if path == "" do return Conn{}, false, domain.domain_error(.Validation_Failed, "database path is required")
	parent := path_dir(path)
	if parent != "" do os.make_directory(parent)
	conn := Conn{path = strings.clone(path)}
	// Odin strings are not NUL-terminated, so raw_data(path) cannot be cast straight to
	// cstring — SQLite would read past the end of the allocation. Same idiom as exec().
	c_path := strings.clone_to_cstring(path, context.temp_allocator)
	rc := sqlite3_open(c_path, &conn.db)
	if rc != SQLITE_OK {
		close(&conn)
		return Conn{}, false, domain.domain_error(.Internal_Error, fmt.tprintf("sqlite open failed: %d", rc))
	}
	if !exec(&conn, "PRAGMA foreign_keys = ON;") {
		close(&conn)
		return Conn{}, false, domain.domain_error(.Internal_Error, "failed to enable foreign_keys")
	}
	sqlite_metrics_track_path(path)
	return conn, true, domain.Domain_Error{}
}

close :: proc(conn: ^Conn) {
	if conn == nil do return
	if conn.db != nil do sqlite3_close(conn.db)
	conn.db = nil
	if conn.path != "" {
		sqlite_metrics_untrack_path(conn.path)
		delete(conn.path); conn.path = ""
	}
}

exec :: proc(conn: ^Conn, query: string) -> bool {
	if conn == nil || conn.db == nil do return false
	errmsg: cstring = nil
	c_query := strings.clone_to_cstring(query, context.temp_allocator)
	rc := sqlite3_exec(conn.db, c_query, nil, nil, &errmsg)
	if rc != SQLITE_OK {
		if errmsg != nil {
			fmt.eprintln("SQLITE EXEC ERROR:", string(errmsg), "FOR QUERY:\n", query)
			sqlite3_free(rawptr(errmsg))
		}
		return false
	}
	return true
}

path_dir :: proc(path: string) -> string {
	idx := -1
	for i in 0..<len(path) {
		if path[i] == '/' do idx = i
	}
	if idx <= 0 do return ""
	return path[:idx]
}
