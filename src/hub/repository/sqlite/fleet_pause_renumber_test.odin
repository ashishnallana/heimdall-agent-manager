#+private file
package sqlite

import "core:strings"
import "core:testing"

// Release 0.4.44 took migration number 130 after fleet pause had already been
// applied as 130_fleet_pause.sql on some databases; fleet pause is now 131. Such
// a database must still run the 0.4.44 extension sync (the ledger is keyed by
// full file name), must not re-run the ALTER TABLE (a hard "duplicate column
// name"), and must keep its paused roles.

FPR_SYNC :: "130_extension_version_sync_0_4_44.sql"
FPR_PAUSE :: "131_fleet_pause.sql"
FPR_LEGACY_PAUSE :: "130_fleet_pause.sql"

fpr_text :: proc(conn: ^Conn, query: string) -> string {
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(conn.db, strings.clone_to_cstring(query, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return ""
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return ""
	return strings.clone(column_text_unowned(stmt, 0), context.temp_allocator)
}

FPR_CATALOG :: "SELECT group_concat(provider || '=' || json_extract(extension, '$.min_version'), ',') FROM (SELECT provider, extension FROM provider_catalog ORDER BY provider);"
FPR_ETAG :: "SELECT catalog_etag FROM provider_catalog_meta;"

@(test)
test_fleet_pause_renumber_after_legacy_130 :: proc(t: ^testing.T) {
	// Reference: what a fresh database converges to.
	fresh, fresh_path, fresh_ok := tmpl_open_file_prod(t, "fpr_fresh")
	if !fresh_ok do return
	defer tmpl_remove_db(fresh_path)
	defer close(&fresh)
	mig_ok, err := run_migrations(&fresh)
	if !testing.expect(t, mig_ok, err.message) do return
	want_catalog := fpr_text(&fresh, FPR_CATALOG)
	want_etag := fpr_text(&fresh, FPR_ETAG)
	testing.expect(t, migration_applied(&fresh, FPR_SYNC) && migration_applied(&fresh, FPR_PAUSE), "fresh: sync and pause recorded")
	testing.expect(t, want_catalog != "" && want_etag != "", "fresh: catalog populated")

	// Legacy: the T8 binary applied 130_fleet_pause.sql, never the 0.4.44 sync.
	conn, path, ok := tmpl_open_file_prod(t, "fpr_legacy")
	if !ok do return
	defer tmpl_remove_db(path)
	defer close(&conn)
	mig_ok, err = run_migrations(&conn, stop_before = FPR_SYNC)
	if !testing.expect(t, mig_ok, err.message) do return
	// The renumbered file's body is exactly what that binary ran as 130.
	legacy_sql := migration_sql(FPR_PAUSE, "")
	defer delete(legacy_sql)
	testing.expect(t, legacy_sql != "" && exec(&conn, legacy_sql), "legacy: 130_fleet_pause applied")
	testing.expect(t, exec(&conn, "INSERT INTO schema_migrations (version) VALUES ('" + FPR_LEGACY_PAUSE + "');"))
	testing.expect(t, exec(&conn, "PRAGMA foreign_keys=OFF;"))
	testing.expect(t, exec(&conn, `INSERT INTO task_chain_fleets (task_chain_id, agent_id, created_at, updated_at, paused_roles_json) VALUES ('chain_fpr', 'agt_fpr', 'now', 'now', '["worker"]');`))
	testing.expect(t, exec(&conn, "PRAGMA foreign_keys=ON;"))
	before_catalog := fpr_text(&conn, FPR_CATALOG)
	testing.expect(t, before_catalog != want_catalog, "legacy: catalog starts behind the 0.4.44 sync")

	for pass in ([]string{"upgrade", "restart"}) {
		mig_ok, err = run_migrations(&conn)
		if !testing.expectf(t, mig_ok, "%s: %s", pass, err.message) do return
		testing.expectf(t, migration_applied(&conn, FPR_SYNC), "%s: 0.4.44 sync recorded", pass)
		testing.expectf(t, migration_applied(&conn, FPR_PAUSE), "%s: fleet pause recorded", pass)
		testing.expectf(t, fpr_text(&conn, FPR_CATALOG) == want_catalog, "%s: catalog %s, want %s", pass, fpr_text(&conn, FPR_CATALOG), want_catalog)
		testing.expectf(t, fpr_text(&conn, FPR_ETAG) == want_etag, "%s: etag %s, want %s", pass, fpr_text(&conn, FPR_ETAG), want_etag)
		testing.expectf(t, fpr_text(&conn, "SELECT paused_roles_json FROM task_chain_fleets WHERE agent_id='agt_fpr';") == `["worker"]`, "%s: paused roles kept", pass)
		testing.expectf(t, fpr_text(&conn, "SELECT count(*) FROM schema_migrations WHERE version='" + FPR_LEGACY_PAUSE + "';") == "1", "%s: legacy ledger row kept", pass)
	}
}
