package sqlite

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

// Test-only seam shared by the sqlite package tests: a process-global, once-migrated
// :memory: template that tests clone instead of re-running every migration, plus
// TMPDIR-based file-DB helpers. This is a *_test.odin file, so none of it is linked
// into the production binary.

when ODIN_OS == .Windows {
	foreign import tmpl_sqlite3_lib "system:sqlite3.lib"
} else {
	foreign import tmpl_sqlite3_lib "system:sqlite3"
}

TMPL_SQLITE_CONFIG_MEMSTATUS :: 9

@(default_calling_convention = "c")
foreign tmpl_sqlite3_lib {
	@(link_name = "sqlite3_config")
	tmpl_sqlite3_config :: proc(op: c.int, #c_vararg args: ..any) -> c.int ---
	@(link_name = "sqlite3_backup_init")
	tmpl_sqlite3_backup_init :: proc(dst: sqlite3, dname: cstring, src: sqlite3, sname: cstring) -> rawptr ---
	@(link_name = "sqlite3_backup_step")
	tmpl_sqlite3_backup_step :: proc(b: rawptr, n: c.int) -> c.int ---
	@(link_name = "sqlite3_backup_finish")
	tmpl_sqlite3_backup_finish :: proc(b: rawptr) -> c.int ---
}

// Disable SQLite's global malloc-statistics tracking before any connection opens.
// With it on, every allocation takes one global mutex, which serialized parallel
// tests (RCA: 4 concurrent migrations took 1.99s each vs 0.33s alone). Nothing in
// src reads sqlite memory stats, and this lives in a *_test.odin file so it only
// affects the test binary.
@(init)
tmpl_disable_memstatus :: proc "contextless" () {
	rc := tmpl_sqlite3_config(TMPL_SQLITE_CONFIG_MEMSTATUS, c.int(0))
	if rc != 0 do runtime.panic_contextless("sqlite3_config(SQLITE_CONFIG_MEMSTATUS, 0) failed")
}

// Process-global template: the REAL migrations run once; never closed.
tmpl_once:  sync.Once
tmpl_conn:  Conn
tmpl_ok:    bool
tmpl_err:   string
tmpl_mutex: sync.Mutex
tmpl_seq:   int

tmpl_build :: proc() {
	context.allocator = runtime.heap_allocator()
	conn, ok, err := open(":memory:")
	if !ok {
		tmpl_err = fmt.aprintf("open: %s", err.message)
		return
	}
	tmpl_conn = conn
	mig_ok, mig_err := run_migrations(&tmpl_conn)
	if !mig_ok {
		tmpl_err = fmt.aprintf("%s", mig_err.message)
		return
	}
	tmpl_ok = true
}

// tmpl_copy_into backs the migrated template up into an open `dst`.
tmpl_copy_into :: proc(t: ^testing.T, dst: ^Conn) -> bool {
	sync.once_do(&tmpl_once, tmpl_build)
	if !testing.expect(t, tmpl_ok, fmt.tprintf("template migrations: %s", tmpl_err)) do return false
	sync.mutex_guard(&tmpl_mutex)
	b := tmpl_sqlite3_backup_init(dst.db, "main", tmpl_conn.db, "main")
	if !testing.expect(t, b != nil, "backup init") do return false
	step_rc := tmpl_sqlite3_backup_step(b, -1)
	fin_rc := tmpl_sqlite3_backup_finish(b)
	ok := testing.expect(t, step_rc == SQLITE_DONE, "backup step")
	ok = testing.expect(t, fin_rc == SQLITE_OK, "backup finish") && ok
	return ok
}

// tmpl_clone_migrated returns a private :memory: copy of the migrated template.
tmpl_clone_migrated :: proc(t: ^testing.T) -> (Conn, bool) {
	conn, ok, err := open(":memory:")
	if !testing.expect(t, ok, fmt.tprintf("open: %s", err.message)) do return conn, false
	if !tmpl_copy_into(t, &conn) {
		close(&conn)
		return Conn{}, false
	}
	return conn, true
}

// tmpl_tmp_db_path returns a unique <TMPDIR>/ham_sqlite_<tag>_<pid>_<n>.db path.
// With TMPDIR unset it falls back to the OS temp directory, never a literal path.
tmpl_tmp_db_path :: proc(tag: string) -> string {
	dir := os.get_env("TMPDIR", context.temp_allocator)
	if dir == "" {
		d, err := os.temp_directory(context.temp_allocator)
		if err == nil do dir = d
	}
	n := sync.atomic_add(&tmpl_seq, 1)
	name := fmt.tprintf("ham_sqlite_%s_%d_%d.db", tag, os.get_pid(), n)
	if dir == "" do return name
	return fmt.tprintf("%s/%s", strings.trim_right(dir, "/"), name)
}

// tmpl_remove_db removes a database file and its -wal, -shm and -journal siblings.
tmpl_remove_db :: proc(path: string) {
	_ = os.remove(path)
	_ = os.remove(fmt.tprintf("%s-wal", path))
	_ = os.remove(fmt.tprintf("%s-shm", path))
	_ = os.remove(fmt.tprintf("%s-journal", path))
}

// tmpl_open_file_prod opens an empty TMPDIR file DB with the production pragmas
// (same order as hub/app/wiring.odin). Callers must tmpl_remove_db(path).
tmpl_open_file_prod :: proc(t: ^testing.T, tag: string) -> (Conn, string, bool) {
	path := tmpl_tmp_db_path(tag)
	tmpl_remove_db(path)
	conn, ok, err := open(path)
	if !testing.expect(t, ok, fmt.tprintf("open %s: %s", path, err.message)) do return conn, path, false
	ok = testing.expect(t, exec(&conn, "PRAGMA journal_mode = WAL;"), "pragma journal_mode")
	ok = testing.expect(t, exec(&conn, "PRAGMA synchronous = NORMAL;"), "pragma synchronous") && ok
	if !ok {
		close(&conn)
		return Conn{}, path, false
	}
	return conn, path, true
}

// tmpl_clone_migrated_into_file is tmpl_open_file_prod plus the migrated template.
tmpl_clone_migrated_into_file :: proc(t: ^testing.T, tag: string) -> (Conn, string, bool) {
	conn, path, ok := tmpl_open_file_prod(t, tag)
	if !ok do return conn, path, false
	if !tmpl_copy_into(t, &conn) {
		close(&conn)
		return Conn{}, path, false
	}
	return conn, path, true
}
