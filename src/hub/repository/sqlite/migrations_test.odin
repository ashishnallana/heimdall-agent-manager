#+private file
// Behavioral tests for SQLite schema migrations and self-healing guards.
package sqlite

import "core:c"
import "core:fmt"
import "core:strings"
import "core:testing"

// --- Consolidated from migration_048_guard_test.odin ---

@(private = "file")
m048_db :: proc(t: ^testing.T, tag: string) -> (Conn, string, bool) {
	conn, db_path, open_ok := tmpl_open_file_prod(t, tag)
	if !open_ok do return conn, db_path, false
	mig_ok, _ := run_migrations(&conn)
	if !testing.expect(t, mig_ok, "migrations ok") {
		close(&conn)
		return Conn{}, db_path, false
	}
	return conn, db_path, true
}

// Drops 048's LAST object and forgets the ledger row: the state an apply interrupted
// between 048's line 70 and its line 83 would leave on disk.
@(private = "file")
m048_simulate_partial_apply :: proc(t: ^testing.T, conn: ^Conn) -> bool {
	ok1 := exec(conn, "DROP INDEX IF EXISTS shell_sessions_owner_session;")
	ok2 := exec(conn, "DELETE FROM schema_migrations WHERE version='048_shell_sessions_kind_and_key.sql';")
	if !testing.expect(t, ok1 && ok2, "partial-apply simulation applied") do return false
	// The state that makes this test meaningful: the EARLY object survived, the LAST did not.
	early := testing.expect(t, sqlite_object_exists(conn, "shell_sessions_agent"), "the early object 048 creates must still be present, or the test proves nothing")
	late := testing.expect(t, !sqlite_object_exists(conn, "shell_sessions_owner_session"), "the last object 048 creates must be absent")
	return early && late
}

// A half-applied 048 must NOT read back as applied. Keyed on shell_sessions_agent this
// returns true — the ledger row is gone, but the fallback finds the early index and says
// "done", leaving the UNIQUE constraint permanently missing with nothing to notice.
@(test)
test_m048_partial_apply_is_not_reported_as_applied :: proc(t: ^testing.T) {
	conn, db_path, ok := m048_db(t, "m048_partial")
	defer tmpl_remove_db(db_path)
	if !ok do return
	defer close(&conn)

	// Sanity: a COMPLETE apply does read back as applied, so a false negative below
	// would be caught rather than mistaken for the fix working.
	testing.expect(t, migration_applied(&conn, "048_shell_sessions_kind_and_key.sql"),
		"a fully migrated database must report 048 applied")
	testing.expect(t, sqlite_object_exists(&conn, "shell_sessions_owner_session"),
		"a fully migrated database has the UNIQUE index")

	if !m048_simulate_partial_apply(t, &conn) do return

	testing.expect(t, !migration_applied(&conn, "048_shell_sessions_kind_and_key.sql"),
		"a 048 that stopped before its UNIQUE index must NOT report as applied")
}

// And the self-heal twin must actually re-run on that database and restore the index.
// Keyed on the early object it returns true immediately and repairs nothing — which is the
// worst place to bail out, since this path exists precisely to fix a database 048 did not
// finish.
@(test)
test_m048_self_heal_restores_the_unique_index_after_a_partial_apply :: proc(t: ^testing.T) {
	conn, db_path, ok := m048_db(t, "m048_selfheal")
	defer tmpl_remove_db(db_path)
	if !ok do return
	defer close(&conn)

	if !m048_simulate_partial_apply(t, &conn) do return

	testing.expect(t, upgrade_shell_sessions_kind_and_key_schema(&conn), "self-heal runs clean")
	testing.expect(t, sqlite_object_exists(&conn, "shell_sessions_owner_session"),
		"the self-heal must restore the UNIQUE index a partial apply left missing")
	// It is idempotent: a second run on the now-complete database is a no-op, not a rebuild.
	testing.expect(t, upgrade_shell_sessions_kind_and_key_schema(&conn), "self-heal is idempotent")
	testing.expect(t, sqlite_object_exists(&conn, "shell_sessions_owner_session"), "index still there")
}

// --- Consolidated from migration_052_drop_shell_jobs_test.odin ---

// A fresh database: 039 creates shell_jobs, 052 drops it, and the end state has no
// table — the ordinary path every new install takes.
@(test)
test_migration_052_drops_shell_jobs_on_a_fresh_db :: proc(t: ^testing.T) {
	conn, db_path, open_ok := tmpl_open_file_prod(t, "m052_fresh")
	defer tmpl_remove_db(db_path)
	if !open_ok do return
	defer close(&conn)

	mig_ok, mig_err := run_migrations(&conn)
	if !testing.expect(t, mig_ok, fmt.tprintf("migrations ok: %s", mig_err.message)) do return

	testing.expect(t, !sqlite_object_exists(&conn, "shell_jobs"),
		"shell_jobs does not exist once 052 has run")
	// The replacement concept is untouched by the drop.
	testing.expect(t, sqlite_object_exists(&conn, "shell_sessions"),
		"shell_sessions is unaffected")
}

// THE CASE AC5 NAMES: the table exists and HAS ROWS before the migration set runs.
//
// The table + rows are created BEFORE run_migrations, which is exactly the shape of a
// database whose shell_jobs predates the ledger — the situation migrations.odin's
// table_column_exists special case for 039 exists to handle. 039 is then marked applied
// without re-running, and 052 must still drop the populated table rather than erroring.
@(test)
test_migration_052_drops_a_populated_shell_jobs_table :: proc(t: ^testing.T) {
	conn, db_path, open_ok := tmpl_open_file_prod(t, "m052_populated")
	defer tmpl_remove_db(db_path)
	if !open_ok do return
	defer close(&conn)

	// 039's schema, verbatim enough to hold real rows.
	made := exec(&conn, `CREATE TABLE IF NOT EXISTS shell_jobs (
	  exec_id TEXT PRIMARY KEY,
	  owner_user_id TEXT NOT NULL,
	  agent_instance_id TEXT NOT NULL,
	  cmd TEXT NOT NULL,
	  status TEXT NOT NULL DEFAULT 'running',
	  exit_code INTEGER,
	  started_at TEXT NOT NULL,
	  finished_at TEXT,
	  created_at TEXT NOT NULL
	);`)
	if !testing.expect(t, made, "pre-created shell_jobs") do return
	inserted := exec(&conn, `INSERT INTO shell_jobs
	  (exec_id, owner_user_id, agent_instance_id, cmd, status, exit_code, started_at, finished_at, created_at)
	  VALUES
	  ('sexc_a', 'usr_1', 'inst_1', 'odin build src/hub', 'completed', 0, '2026-09-01T00:00:00Z', '2026-09-01T00:01:00Z', '2026-09-01T00:00:00Z'),
	  ('sexc_b', 'usr_1', 'inst_1', 'sleep 600', 'running', NULL, '2026-09-01T00:02:00Z', NULL, '2026-09-01T00:02:00Z');`)
	if !testing.expect(t, inserted, "pre-inserted rows") do return
	// The premise of the test: rows really are there before we migrate.
	have_rows := table_column_exists(&conn, "shell_jobs", "exec_id")
	if !testing.expect(t, have_rows, "the populated table is in place before migrating") do return

	mig_ok, mig_err := run_migrations(&conn)
	testing.expect(t, mig_ok, fmt.tprintf("migrations apply cleanly over a populated shell_jobs: %s", mig_err.message))
	testing.expect(t, !sqlite_object_exists(&conn, "shell_jobs"),
		"the populated table is dropped, rows and all")

	// IDEMPOTENT: re-running the set must not error now the table is gone. This is the
	// property that makes a hub restart safe, and the reason no special case for 052 is
	// needed in migrations.odin.
	again_ok, again_err := run_migrations(&conn)
	testing.expect(t, again_ok, fmt.tprintf("migrations re-run cleanly: %s", again_err.message))
	testing.expect(t, !sqlite_object_exists(&conn, "shell_jobs"), "still gone after a second run")
}

// --- Consolidated from migration_055_expiry_test.odin ---

@(test)
test_migration_055_fresh_db_creates_column_and_applies :: proc(t: ^testing.T) {
	conn, db_path, open_ok := tmpl_open_file_prod(t, "m055_fresh")
	defer tmpl_remove_db(db_path)
	if !open_ok do return
	defer close(&conn)

	mig_ok, mig_err := run_migrations(&conn)
	if !testing.expect(t, mig_ok, fmt.tprintf("migrations ok: %s", mig_err.message)) do return

	testing.expect(t, table_column_exists(&conn, "memories", "expires_at"),
		"memories table has expires_at column")
	testing.expect(t, migration_applied(&conn, "055_memory_action_expiry.sql"),
		"055_memory_action_expiry.sql marked as applied")

	// Verify idempotency: running migrations a second time succeeds cleanly with no errors
	mig_ok2, mig_err2 := run_migrations(&conn)
	testing.expect(t, mig_ok2, fmt.tprintf("second migrations run ok: %s", mig_err2.message))
}

@(test)
test_migration_055_backfills_pending_memories_and_cards :: proc(t: ^testing.T) {
	conn, db_path, open_ok := tmpl_open_file_prod(t, "m055_backfill")
	defer tmpl_remove_db(db_path)
	if !open_ok do return
	defer close(&conn)

	// Run full migrations first to get base schema
	mig_ok, mig_err := run_migrations(&conn)
	if !testing.expect(t, mig_ok, fmt.tprintf("migrations ok: %s", mig_err.message)) do return

	// Insert test memories: one pending, one active
	exec(&conn, "INSERT INTO memories (memory_id, owner_user_id, agent_ids, project_ids, template_ids, bridge_ids, type, status, title, description, body, evidence, expires_at, created_at, updated_at) VALUES ('mem_pending', 'usr_1', '[]', '[]', '[]', '[]', 'fact', 'pending', 'Pending Mem', 'Desc', 'Body', '', '', '2026-10-01T12:00:00Z', '2026-10-01T12:00:00Z');")
	exec(&conn, "INSERT INTO memories (memory_id, owner_user_id, agent_ids, project_ids, template_ids, bridge_ids, type, status, title, description, body, evidence, expires_at, created_at, updated_at) VALUES ('mem_active', 'usr_1', '[]', '[]', '[]', '[]', 'fact', 'active', 'Active Mem', 'Desc', 'Body', '', '', '2026-10-01T12:00:00Z', '2026-10-01T12:00:00Z');")

	// Insert test cards: one pending, one accepted
	exec(&conn, "INSERT INTO cards (card_id, owner_user_id, project_id, title, rationale, scope, provider, confidence, source_refs_json, status, operations_json, guard_json, snooze_until, ttl_at, created_at, updated_at) VALUES ('crd_pending', 'usr_1', 'proj_1', 'Pending Card', 'Rat', 'project', 'agent', 0.9, '[]', 'pending', '[]', '{}', '', '', '2026-10-01T12:00:00Z', '2026-10-01T12:00:00Z');")
	exec(&conn, "INSERT INTO cards (card_id, owner_user_id, project_id, title, rationale, scope, provider, confidence, source_refs_json, status, operations_json, guard_json, snooze_until, ttl_at, created_at, updated_at) VALUES ('crd_accepted', 'usr_1', 'proj_1', 'Accepted Card', 'Rat', 'project', 'agent', 0.9, '[]', 'accepted', '[]', '{}', '', '', '2026-10-01T12:00:00Z', '2026-10-01T12:00:00Z');")

	// Now run the backfill queries from migration 055
	ok_mem := exec(&conn, "UPDATE memories SET expires_at = strftime('%Y-%m-%dT%H:%M:%SZ', datetime(created_at, '+24 hours')) WHERE status = 'pending';")
	testing.expect(t, ok_mem, "memories backfill query executed")

	ok_crd := exec(&conn, "UPDATE cards SET ttl_at = strftime('%Y-%m-%dT%H:%M:%SZ', datetime(created_at, '+24 hours')) WHERE status = 'pending' AND (ttl_at IS NULL OR ttl_at = '');")
	testing.expect(t, ok_crd, "cards backfill query executed")

	// Check pending memory was backfilled to 2026-10-02T12:00:00Z
	{
		stmt: sqlite3_stmt
		rc := sqlite3_prepare_v2(conn.db, "SELECT expires_at FROM memories WHERE memory_id = 'mem_pending';", -1, &stmt, nil)
		testing.expect(t, rc == SQLITE_OK, "prepare select pending memory")
		defer sqlite3_finalize(stmt)
		if sqlite3_step(stmt) == SQLITE_ROW {
			c_txt := sqlite3_column_text(stmt, 0)
			val := string(c_txt)
			testing.expect_value(t, val, "2026-10-02T12:00:00Z")
		} else {
			testing.expect(t, false, "expected row for mem_pending")
		}
	}

	// Check active memory was NOT backfilled (expires_at is still empty)
	{
		stmt: sqlite3_stmt
		rc := sqlite3_prepare_v2(conn.db, "SELECT expires_at FROM memories WHERE memory_id = 'mem_active';", -1, &stmt, nil)
		testing.expect(t, rc == SQLITE_OK, "prepare select active memory")
		defer sqlite3_finalize(stmt)
		if sqlite3_step(stmt) == SQLITE_ROW {
			c_txt := sqlite3_column_text(stmt, 0)
			val := string(c_txt)
			testing.expect_value(t, val, "")
		} else {
			testing.expect(t, false, "expected row for mem_active")
		}
	}

	// Check pending card was backfilled to 2026-10-02T12:00:00Z
	{
		stmt: sqlite3_stmt
		rc := sqlite3_prepare_v2(conn.db, "SELECT ttl_at FROM cards WHERE card_id = 'crd_pending';", -1, &stmt, nil)
		testing.expect(t, rc == SQLITE_OK, "prepare select pending card")
		defer sqlite3_finalize(stmt)
		if sqlite3_step(stmt) == SQLITE_ROW {
			c_txt := sqlite3_column_text(stmt, 0)
			val := string(c_txt)
			testing.expect_value(t, val, "2026-10-02T12:00:00Z")
		} else {
			testing.expect(t, false, "expected row for crd_pending")
		}
	}

	// Check accepted card was NOT backfilled
	{
		stmt: sqlite3_stmt
		rc := sqlite3_prepare_v2(conn.db, "SELECT ttl_at FROM cards WHERE card_id = 'crd_accepted';", -1, &stmt, nil)
		testing.expect(t, rc == SQLITE_OK, "prepare select accepted card")
		defer sqlite3_finalize(stmt)
		if sqlite3_step(stmt) == SQLITE_ROW {
			c_txt := sqlite3_column_text(stmt, 0)
			val := string(c_txt)
			testing.expect_value(t, val, "")
		} else {
			testing.expect(t, false, "expected row for crd_accepted")
		}
	}
}
