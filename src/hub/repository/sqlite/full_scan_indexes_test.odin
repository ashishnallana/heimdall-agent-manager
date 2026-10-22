#+private file
// Migration 104 (full-scan indexes): fresh-DB, upgrade, idempotence and query-plan
// tests. Plans are taken from the SQL the REAL repository procs prepare, captured
// through sqlite3_trace_v2, so an edit to that SQL that stops matching an index
// fails here instead of silently reverting to a full scan. No ANALYZE is run:
// production never runs it, so these are the plans production gets.
package sqlite

import "base:runtime"
import "core:c"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"

when ODIN_OS == .Windows {
	foreign import fsi_sqlite3_lib "system:sqlite3.lib"
} else {
	foreign import fsi_sqlite3_lib "system:sqlite3"
}

@(default_calling_convention = "c")
foreign fsi_sqlite3_lib {
	@(link_name = "sqlite3_trace_v2")
	fsi_trace_v2 :: proc(db: sqlite3, mask: c.uint, cb: proc "c" (c.uint, rawptr, rawptr, rawptr) -> c.int, ctx: rawptr) -> c.int ---
}

FSI_TRACE_STMT :: 0x01
FSI_MIGRATION :: "104_full_scan_indexes.sql"
FSI_INDEXES :: [3]string{"idx_shell_sessions_kind_started", "idx_shell_sessions_retention", "idx_task_dependencies_chain"}
FSI_OWNER :: "m104-owner"
FSI_NOW :: "2026-10-22T00:00:00Z"

// Strings are cloned with the callback's heap allocator; fsi_capture_free releases them.
Fsi_Capture :: struct {
	sql: [dynamic]string,
}

fsi_trace :: proc "c" (mask: c.uint, ctx, p, x: rawptr) -> c.int {
	context = runtime.default_context()
	capture := (^Fsi_Capture)(ctx)
	if mask == FSI_TRACE_STMT do append(&capture.sql, strings.clone(string(sqlite3_sql(sqlite3_stmt(p)))))
	return 0
}

fsi_capture_free :: proc(capture: ^Fsi_Capture) {
	for s in capture.sql do delete(s, runtime.heap_allocator())
	delete(capture.sql)
}

fsi_plan :: proc(conn: ^Conn, query: string) -> string {
	stmt: sqlite3_stmt = nil
	full := strings.concatenate({"EXPLAIN QUERY PLAN ", query}, context.temp_allocator)
	if sqlite3_prepare_v2(conn.db, strings.clone_to_cstring(full, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return ""
	defer sqlite3_finalize(stmt)
	b := strings.builder_make(context.temp_allocator)
	for sqlite3_step(stmt) == SQLITE_ROW {
		strings.write_string(&b, column_text_unowned(stmt, 3))
		strings.write_string(&b, "\n")
	}
	return strings.to_string(b)
}

fsi_db :: proc(t: ^testing.T, tag: string, stop_before := "") -> (Conn, string, bool) {
	conn, path, ok := tmpl_open_file_prod(t, tag)
	if !ok do return conn, path, false
	mig_ok, _ := run_migrations(&conn, stop_before = stop_before)
	if !testing.expect(t, mig_ok, "migrations ok") {
		close(&conn)
		return Conn{}, path, false
	}
	return conn, path, true
}

fsi_expect_indexes :: proc(t: ^testing.T, conn: ^Conn, present: bool, why: string) {
	for name in FSI_INDEXES {
		testing.expectf(t, sqlite_object_exists(conn, name) == present, "%s: %s present=%v expected %v", why, name, sqlite_object_exists(conn, name), present)
	}
}

@(test)
test_m104_fresh_database_has_the_indexes :: proc(t: ^testing.T) {
	conn, path, ok := fsi_db(t, "m104_fresh")
	defer tmpl_remove_db(path)
	if !ok do return
	defer close(&conn)
	fsi_expect_indexes(t, &conn, true, "fresh database")
	testing.expect(t, migration_applied(&conn, FSI_MIGRATION), "fresh database records 104 as applied")
}

// Upgrade from the pre-104 schema with rows already present, then prove re-runs and
// a half-applied 104 (ledger row missing, one index missing) converge.
@(test)
test_m104_upgrade_is_idempotent_and_keeps_rows :: proc(t: ^testing.T) {
	conn, path, ok := fsi_db(t, "m104_upgrade", FSI_MIGRATION)
	defer tmpl_remove_db(path)
	if !ok do return
	defer close(&conn)
	fsi_expect_indexes(t, &conn, false, "pre-104 schema")
	testing.expect(t, !migration_applied(&conn, FSI_MIGRATION), "104 not yet applied")

	user_impl: User_Repo_SQLite
	_ = new_user_repository(&user_impl, &conn)
	_, user_ok, _ := user_save_sqlite(&user_impl, domain.User{user_id = FSI_OWNER, name = FSI_OWNER, status = .Active, created_at = FSI_NOW, updated_at = FSI_NOW})
	if !testing.expect(t, user_ok, "seed user") do return
	shell_impl: Shell_Session_Repo_SQLite
	_ = new_shell_session_repository(&shell_impl, &conn)
	saved, _ := shell_session_upsert_sqlite(&shell_impl, domain.Shell_Session{session_id = "sh_m104", owner_user_id = FSI_OWNER,
		bridge_id = "bridge_m104", kind = "server", status = "running", cmd = "true", started_at = FSI_NOW, created_at = FSI_NOW})
	if !testing.expect(t, saved, "seed shell row") do return

	mig_ok, _ := run_migrations(&conn)
	testing.expect(t, mig_ok, "upgrade applies 104")
	fsi_expect_indexes(t, &conn, true, "after upgrade")
	testing.expect(t, migration_applied(&conn, FSI_MIGRATION), "upgrade records 104")
	{
		// The row's strings are owned clones; temp allocator keeps the test leak-free.
		context.allocator = context.temp_allocator
		row, found, _ := shell_session_get_sqlite(&shell_impl, FSI_OWNER, "sh_m104")
		testing.expect(t, found && row.status == "running" && row.kind == "server", "existing row survives the upgrade")
	}

	mig_ok, _ = run_migrations(&conn)
	testing.expect(t, mig_ok, "second run is a no-op")
	testing.expect(t, exec(&conn, MIGRATION_104_FULL_SCAN_INDEXES), "re-executing 104 directly is a no-op (IF NOT EXISTS)")

	testing.expect(t, exec(&conn, "DROP INDEX idx_task_dependencies_chain;"), "simulate partial apply")
	testing.expect(t, exec(&conn, "DELETE FROM schema_migrations WHERE version='104_full_scan_indexes.sql';"), "forget ledger row")
	mig_ok, _ = run_migrations(&conn)
	testing.expect(t, mig_ok, "re-apply after partial apply")
	fsi_expect_indexes(t, &conn, true, "after partial-apply repair")
}

// The three reads 104 exists for must plan onto its indexes, with no full scan and
// no temp B-tree sort, using the SQL the repository actually prepares.
@(test)
test_m104_repository_reads_plan_onto_the_indexes :: proc(t: ^testing.T) {
	conn, path, ok := fsi_db(t, "m104_plan")
	defer tmpl_remove_db(path)
	if !ok do return
	defer close(&conn)
	shell_impl: Shell_Session_Repo_SQLite
	_ = new_shell_session_repository(&shell_impl, &conn)
	task_impl: Taskchain_Repo_SQLite
	_ = new_taskchain_repository(&task_impl, &conn)

	capture: Fsi_Capture
	defer fsi_capture_free(&capture)
	fsi_trace_v2(conn.db, FSI_TRACE_STMT, fsi_trace, &capture)
	rows, e1 := shell_session_list_live_by_kind_sqlite(&shell_impl, "server", 100)
	delete(rows)
	owners, e2 := shell_session_delete_terminal_before_owners_sqlite(&shell_impl, "2026-01-01T00:00:00Z")
	delete(owners)
	deps, e3 := taskchain_list_dependencies_by_chain_sqlite(&task_impl, "chain_m104", FSI_OWNER)
	delete(deps)
	fsi_trace_v2(conn.db, 0, nil, nil)
	testing.expect(t, e1.code == .None && e2.code == .None && e3.code == .None, "repository calls succeed")
	if !testing.expectf(t, len(capture.sql) == 3, "expected 3 captured statements, got %d", len(capture.sql)) do return

	expected := [3]string{
		"SEARCH shell_sessions USING INDEX idx_shell_sessions_kind_started (kind=?)",
		"SEARCH shell_sessions USING INDEX idx_shell_sessions_retention (status=? AND <expr><?)",
		"SEARCH task_dependencies USING INDEX idx_task_dependencies_chain (chain_id=? AND owner_user_id=?)",
	}
	for want, i in expected {
		plan := fsi_plan(&conn, capture.sql[i])
		testing.expectf(t, strings.contains(plan, want), "plan for %q\n= %q\nwant %q", capture.sql[i], plan, want)
		testing.expectf(t, !strings.contains(plan, "SCAN "), "plan must not scan: %q", plan)
		testing.expectf(t, !strings.contains(plan, "TEMP B-TREE"), "plan must not sort: %q", plan)
	}
}
