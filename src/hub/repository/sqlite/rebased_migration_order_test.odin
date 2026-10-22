#+private file
// Migrations 104 (chat FTS update guard) and 105 (full-scan indexes) were renumbered
// to follow main's 103_plan_enforcement.sql. These tests pin that order: a database
// stopped at main's latest migration upgrades through both, a fresh database applies
// every migration, and no number after 102 is shared.
package sqlite

import "core:strconv"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"

RMO_MAIN_TIP :: "103_plan_enforcement.sql"
RMO_GUARD :: "104_guard_chat_fts_updates.sql"
RMO_INDEXES :: "105_full_scan_indexes.sql"
RMO_INDEX_NAMES :: [3]string{"idx_shell_sessions_kind_started", "idx_shell_sessions_retention", "idx_task_dependencies_chain"}
RMO_OWNER :: "rmo-owner"
RMO_NOW :: "2026-10-22T00:00:00Z"

rmo_text :: proc(conn: ^Conn, query: string) -> string {
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(conn.db, strings.clone_to_cstring(query, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return ""
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return ""
	return strings.clone(column_text_unowned(stmt, 0), context.temp_allocator)
}

// 104 replaces both chat FTS update triggers with versions that skip unchanged text.
rmo_guarded :: proc(conn: ^Conn) -> bool {
	conv := rmo_text(conn, "SELECT sql FROM sqlite_master WHERE type='trigger' AND name='chat_conversations_fts_au';")
	msgs := rmo_text(conn, "SELECT sql FROM sqlite_master WHERE type='trigger' AND name='chat_messages_fts_au';")
	return strings.contains(conv, "old.title IS NOT new.title") && strings.contains(msgs, "old.body IS NOT new.body")
}

rmo_expect_after :: proc(t: ^testing.T, conn: ^Conn, why: string) {
	testing.expectf(t, migration_applied(conn, RMO_MAIN_TIP), "%s: %s applied", why, RMO_MAIN_TIP)
	testing.expectf(t, migration_applied(conn, RMO_GUARD), "%s: %s applied", why, RMO_GUARD)
	testing.expectf(t, migration_applied(conn, RMO_INDEXES), "%s: %s applied", why, RMO_INDEXES)
	testing.expectf(t, table_column_exists(conn, "bridges", "plan_disabled_at"), "%s: main's plan column present", why)
	testing.expectf(t, rmo_guarded(conn), "%s: chat FTS update triggers are guarded", why)
	for name in RMO_INDEX_NAMES {
		testing.expectf(t, sqlite_object_exists(conn, name), "%s: index %s present", why, name)
	}
	ledger := rmo_text(conn, "SELECT count(*) FROM schema_migrations;")
	testing.expectf(t, ledger == "108", "%s: ledger holds every migration (got %s, want 108)", why, ledger)
}

@(test)
test_rebased_upgrade_from_main_tip_applies_104_and_105 :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, path, ok := tmpl_open_file_prod(t, "rmo_upgrade")
	defer tmpl_remove_db(path)
	if !ok do return
	defer close(&conn)
	mig_ok, _ := run_migrations(&conn, stop_before = RMO_GUARD)
	if !testing.expect(t, mig_ok, "migrate to main's tip") do return
	testing.expect(t, fts5_available(&conn), "test build has FTS5, so 104 really runs")
	testing.expect(t, migration_applied(&conn, RMO_MAIN_TIP), "main's tip applied")
	testing.expect(t, !migration_applied(&conn, RMO_GUARD) && !migration_applied(&conn, RMO_INDEXES), "ours not yet applied")
	testing.expect(t, !rmo_guarded(&conn), "main's tip has the unguarded triggers")
	for name in RMO_INDEX_NAMES do testing.expectf(t, !sqlite_object_exists(&conn, name), "%s absent at main's tip", name)

	user_impl: User_Repo_SQLite
	_ = new_user_repository(&user_impl, &conn)
	_, user_ok, _ := user_save_sqlite(&user_impl, domain.User{user_id = RMO_OWNER, name = RMO_OWNER, status = .Active, created_at = RMO_NOW, updated_at = RMO_NOW})
	if !testing.expect(t, user_ok, "seed user") do return
	shell_impl: Shell_Session_Repo_SQLite
	_ = new_shell_session_repository(&shell_impl, &conn)
	saved, _ := shell_session_upsert_sqlite(&shell_impl, domain.Shell_Session{session_id = "sh_rmo", owner_user_id = RMO_OWNER,
		bridge_id = "bridge_rmo", kind = "server", status = "running", cmd = "true", started_at = RMO_NOW, created_at = RMO_NOW})
	if !testing.expect(t, saved, "seed shell row") do return

	mig_ok, _ = run_migrations(&conn)
	if !testing.expect(t, mig_ok, "upgrade through 104 and 105") do return
	rmo_expect_after(t, &conn, "upgrade")
	row, found, _ := shell_session_get_sqlite(&shell_impl, RMO_OWNER, "sh_rmo")
	testing.expect(t, found && row.status == "running", "existing row survives the upgrade")
	mig_ok, _ = run_migrations(&conn)
	testing.expect(t, mig_ok, "second run is a no-op")
}

@(test)
test_rebased_fresh_database_applies_every_migration :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, path, ok := tmpl_open_file_prod(t, "rmo_fresh")
	defer tmpl_remove_db(path)
	if !ok do return
	defer close(&conn)
	mig_ok, _ := run_migrations(&conn)
	if !testing.expect(t, mig_ok, "fresh migrate") do return
	for name in migration_order do testing.expectf(t, migration_applied(&conn, name), "fresh database records %s", name)
	rmo_expect_after(t, &conn, "fresh")
}

// Older numbers (043, 044, 048, 072) were shared before this rule; anything after
// 102 must be unique and in ascending order, ending with ours.
@(test)
test_rebased_migration_numbers_after_102_are_unique :: proc(t: ^testing.T) {
	order := migration_order
	tail := order[len(order) - 4:]
	testing.expect(t, tail[0] == "102_drop_bridge_enrollments.sql" && tail[1] == RMO_MAIN_TIP && tail[2] == RMO_GUARD && tail[3] == RMO_INDEXES, "order ends 102, 103 plan, 104 guard, 105 indexes")
	prev := 0
	for name in order {
		n, n_ok := strconv.parse_int(name[:3])
		if !testing.expectf(t, n_ok, "%s has a numeric prefix", name) do continue
		if n > 102 do testing.expectf(t, n > prev, "%s must be numbered after %d", name, prev)
		prev = max(prev, n)
	}
}
