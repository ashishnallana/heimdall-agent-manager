package sqlite

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// REQ-CONN-2: scalar_count and fts_rebuild_one must NUL-terminate their query
// strings before passing them to SQLite. Odin strings are not NUL-terminated, so
// cstring(raw_data(q)) with nByte=-1 lets SQLite scan past the allocation. The fix
// uses strings.clone_to_cstring into context.temp_allocator, exactly as conn.odin:55.

// Discriminating test for scalar_count: uses a query WITHOUT a trailing semicolon so
// that the overrun bytes are inside what SQLite parses as the SQL text. A pre-filled
// 'X' buffer guarantees those bytes are non-zero, making the failure deterministic
// (not reliant on heap luck). Without the fix: cstring(raw_data) gives SQLite
// "SELECT count(*) FROM fts_probe_countXXXXXX..." — unknown table, SQLITE_ERROR.
// With fix: clone_to_cstring appends a NUL, SQLite sees the exact table name, succeeds.
@(test)
test_scalar_count_uses_exact_query :: proc(t: ^testing.T) {
	db_path := ":memory:"
	conn, ok, _ := open(db_path)
	testing.expect(t, ok, "db open ok")
	defer close(&conn)

	testing.expect(t, exec(&conn, "CREATE TABLE fts_probe_count(x INTEGER);"), "create probe table")
	testing.expect(t, exec(&conn, "INSERT INTO fts_probe_count VALUES(1),(2),(3);"), "insert 3 rows")

	// Build query WITHOUT trailing semicolon so overrun bytes land inside the SQL text,
	// not after a statement terminator where they would be harmlessly ignored.
	intended := "SELECT count(*) FROM fts_probe_count"
	buf := make([]byte, len(intended) + 64)
	defer delete(buf)
	for i in 0 ..< len(buf) do buf[i] = 'X'
	copy(buf, transmute([]byte)intended)
	query_slice := string(buf[:len(intended)]) // no NUL terminator at position len(intended)

	n, count_ok := scalar_count(&conn, query_slice)
	testing.expect(t, count_ok, "scalar_count succeeds with non-terminated runtime query")
	testing.expect_value(t, n, 3)
}

// Functional correctness test for fts_rebuild_one with a runtime-built table name.
// Skips gracefully when FTS5 is not compiled in. The 'rebuild' op on an empty
// external-content FTS table is a no-op that must still return SQLITE_DONE (success).
// Note: the query fts_rebuild_one builds ends with ';', so the overrun bytes from a
// buggy cstring(raw_data) land after the statement terminator and are not parsed by
// SQLite's SQL engine — making a pre-filled-buffer discrimination infeasible. A
// functional correctness test is the correct bar for this site.
@(test)
test_fts_rebuild_one_runtime_name :: proc(t: ^testing.T) {
	db_path := ":memory:"
	conn, ok, _ := open(db_path)
	testing.expect(t, ok, "db open ok")
	defer close(&conn)

	if !fts5_available(&conn) {
		return // FTS5 not compiled in; skip gracefully
	}

	// Create minimal external-content FTS table with a runtime-built name.
	testing.expect(t, exec(&conn, "CREATE TABLE fts_base(id INTEGER PRIMARY KEY, txt TEXT);"), "create base table")
	testing.expect(t, exec(&conn, "CREATE VIRTUAL TABLE fts_vtbl USING fts5(content='fts_base', content_rowid='id', txt);"), "create fts vtable")

	// Build the FTS table name as a runtime string (heap-allocated, not a literal).
	fts_name := strings.concatenate({"fts", "_vtbl"})
	defer delete(fts_name)

	result := fts_rebuild_one(&conn, fts_name)
	testing.expect(t, result, "fts_rebuild_one succeeds for runtime-built table name")
}
