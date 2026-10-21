package sqlite

import "core:os"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"

// REQ-CONN-1: open() must NUL-terminate the path before handing it to SQLite.
// Odin strings carry a pointer + length and are not NUL-terminated, so a runtime-built
// path (main.odin builds database_path with strings.clone(os.args[i+1])) has no
// terminator. A literal path is NUL-terminated in the binary and would pass either way,
// so every path below is constructed at runtime.

// Heap-allocated, exactly len bytes — the shape main.odin produces.
@(test)
test_open_with_runtime_concatenated_path :: proc(t: ^testing.T) {
	db_path := strings.concatenate({tmpl_tmp_db_path("conn_concat"), "-rt.db"})
	defer delete(db_path)

	tmpl_remove_db(db_path)
	defer tmpl_remove_db(db_path)

	conn, open_ok, err := open(db_path)
	testing.expect(t, open_ok, "open succeeds for a runtime-concatenated path")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	defer close(&conn)

	testing.expect(t, exec(&conn, "CREATE TABLE conn_probe(a INTEGER);"), "exec creates a table")
	testing.expect(t, os.exists(db_path), "database file exists at the intended path")
}

// Deterministic reproduction: a string whose backing bytes are followed by non-zero
// garbage. Without the fix SQLite reads past len(path) and opens a different file, so
// this test fails against the unfixed open() rather than passing by luck.
@(test)
test_open_with_non_terminated_path :: proc(t: ^testing.T) {
	intended := tmpl_tmp_db_path("conn_noterm")

	buf := make([]byte, len(intended) + 64)
	defer delete(buf)
	for i in 0 ..< len(buf) do buf[i] = 'X'
	copy(buf, transmute([]byte)intended)
	db_path := string(buf[:len(intended)])

	tmpl_remove_db(db_path)
	defer tmpl_remove_db(db_path)

	conn, open_ok, _ := open(db_path)
	testing.expect(t, open_ok, "open succeeds for a non-NUL-terminated path")
	defer close(&conn)

	testing.expect(t, exec(&conn, "CREATE TABLE conn_probe(a INTEGER);"), "exec creates a table")
	testing.expect(t, os.exists(db_path), "database file exists at the intended path, not past its end")

	// The overrun path SQLite would have used if the terminator were missing.
	overrun := string(buf[:])
	testing.expect(t, !os.exists(overrun), "no file created at the overrun path")
	defer tmpl_remove_db(overrun)
}
