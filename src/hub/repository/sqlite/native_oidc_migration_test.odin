#+private file
package sqlite

import "core:testing"
import "core:strings"

@(test)
test_native_oidc_upgrade_preserves_legacy_identity_and_nonce :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, path, ok := tmpl_open_file_prod(t, "native_oidc_upgrade")
	defer tmpl_remove_db(path)
	if !ok do return
	defer close(&conn)
	mig_ok, _ := run_migrations(&conn, stop_before = "113_antigravity_extension.sql")
	if !testing.expect(t, mig_ok, "build deployed native schema through upstream 112") do return
	if !testing.expect(t, exec(&conn, MIGRATION_NATIVE_001_OIDC_IDENTITIES), "apply exact legacy native SQL") do return
	mark_migration_applied(&conn, "113_oidc_identities.sql")
	mark_migration_applied(&conn, "115_oidc_identities.sql")
	testing.expect(t, exec(&conn, "INSERT INTO users(user_id,name,display_name,email,status,created_at,updated_at) VALUES ('native-owner','native-owner','Native Owner','','active','now','now');"), "seed owner")
	testing.expect(t, exec(&conn, "INSERT INTO user_external_identities VALUES ('issuer','subject','native-owner','now'); INSERT INTO vault_request_nonces VALUES ('native-owner','device','nonce',9999999999999);"), "seed identity and replay nonce")
	before115 := native_migration_text(&conn, "SELECT applied_at FROM schema_migrations WHERE version='115_oidc_identities.sql';")
	before := native_migration_text(&conn, "SELECT applied_at FROM schema_migrations WHERE version='113_oidc_identities.sql';")
	for _ in 0..<2 {
		close(&conn)
		reopened: bool
		conn, reopened, _ = open(path)
		if !testing.expect(t, reopened, "reopen old deployed database") do return
		mig_ok, _ = run_migrations(&conn)
		if !testing.expect(t, mig_ok, "upgrade and repeat succeed") do return
		testing.expect_value(t, native_migration_text(&conn, "SELECT applied_at FROM schema_migrations WHERE version='115_oidc_identities.sql';"), before115)
		testing.expect(t, migration_applied(&conn, "115_provider_extension_commands.sql"), "upstream 115 is independent")
		testing.expect(t, table_column_exists(&conn, "provider_extension_commands", "target_commit"), "new provider install schema present")
		testing.expect(t, native_oidc_schema_complete(&conn), "entire schema preserved")
		testing.expect(t, migration_applied(&conn, "113_antigravity_extension.sql"), "upstream 113 applied independently")
		testing.expect(t, migration_applied(&conn, "native_001_oidc_identities.sql"), "native namespace recorded")
		testing.expect_value(t, native_migration_text(&conn, "SELECT applied_at FROM schema_migrations WHERE version='113_oidc_identities.sql';"), before)
		testing.expect_value(t, native_migration_text(&conn, "SELECT subject FROM user_external_identities WHERE user_id='native-owner';"), "subject")
		testing.expect_value(t, native_migration_text(&conn, "SELECT nonce FROM vault_request_nonces;"), "nonce")
	}
}

@(test)
test_native_oidc_partial_schema_fails_closed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	broken_cases := [3]string{
		"CREATE TABLE user_external_identities (issuer TEXT);",
		"CREATE TABLE user_external_identities (issuer TEXT NOT NULL, subject TEXT NOT NULL, user_id TEXT NOT NULL, created_at TEXT NOT NULL, PRIMARY KEY(issuer,subject));",
		MIGRATION_NATIVE_001_OIDC_IDENTITIES + "DROP INDEX vault_request_nonces_expiry;",
	}
	for broken_sql in broken_cases {
		conn, path, ok := tmpl_open_file_prod(t, "native_oidc_partial")
		if !ok do continue
		mig_ok, _ := run_migrations(&conn, stop_before = "113_antigravity_extension.sql")
		testing.expect(t, mig_ok && exec(&conn, broken_sql), "seed incomplete legacy schema")
		mark_migration_applied(&conn, "113_oidc_identities.sql")
		mig_ok, _ = run_migrations(&conn)
		testing.expect(t, !mig_ok, "incomplete native schema rejected")
		testing.expect(t, !migration_applied(&conn, "native_001_oidc_identities.sql"), "never acknowledge incomplete migration")
		close(&conn)
		tmpl_remove_db(path)
	}
}

native_migration_text :: proc(conn: ^Conn, query: string) -> string {
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(conn.db, strings.clone_to_cstring(query, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return ""
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return ""
	return strings.clone(column_text_unowned(stmt, 0), context.temp_allocator)
}

@(test)
test_native_oidc_fresh_namespace_and_provider_schema_survive_restart :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    conn, path, ok := tmpl_open_file_prod(t, "native_oidc_fresh_restart")
    defer tmpl_remove_db(path)
    if !ok do return
    mig_ok, _ := run_migrations(&conn)
    if !testing.expect(t, mig_ok, "fresh native boot") { close(&conn); return }
    testing.expect(t, native_oidc_schema_complete(&conn), "fresh native schema is complete")
    testing.expect(t, !migration_applied(&conn, "113_oidc_identities.sql") &&
        !migration_applied(&conn, "115_oidc_identities.sql"), "fresh database does not invent historical ledger rows")
    testing.expect(t, migration_applied(&conn, "native_001_oidc_identities.sql"), "fresh namespaced migration")
    testing.expect(t, sqlite_object_exists(&conn, "provider_extension_commands_followup"), "provider followup uniqueness")
    before := native_migration_text(&conn, "SELECT count(*) FROM schema_migrations;")
    close(&conn)
    conn, ok, _ = open(path)
    if !testing.expect(t, ok, "reopen fresh database") do return
    defer close(&conn)
    mig_ok, _ = run_migrations(&conn)
    testing.expect(t, mig_ok && native_oidc_schema_complete(&conn), "restart remains compatible")
    testing.expect_value(t, native_migration_text(&conn, "SELECT count(*) FROM schema_migrations;"), before)
}

// Recreate the locked v0.4.41 native ledger: upstream through 124 followed by
// the native namespace. Upgrade a disk fixture, never a running Hub database.
@(test)
test_current_upgrade_from_v0441_native_preserves_ledger_and_data :: proc(t: ^testing.T) {
    registry := migration_order
    context.allocator = context.temp_allocator
    conn, path, ok := tmpl_open_file_prod(t, "native_v0441_upgrade")
    defer tmpl_remove_db(path)
    if !ok do return
    defer close(&conn)
    mig_ok, _ := run_migrations(&conn, stop_before = "125_transient_extension_signals.sql")
    if !testing.expect(t, mig_ok, "apply upstream v0.4.41 registry") do return
    if !testing.expect(t, exec(&conn, MIGRATION_NATIVE_001_OIDC_IDENTITIES), "apply native namespace") do return
    mark_migration_applied(&conn, "native_001_oidc_identities.sql")
    testing.expect(t, exec(&conn, "INSERT INTO users(user_id,name,display_name,email,status,created_at,updated_at) VALUES ('upgrade-owner','upgrade-owner','Upgrade Owner','','active','now','now'); INSERT INTO user_external_identities VALUES ('issuer','subject','upgrade-owner','now'); INSERT INTO vault_request_nonces VALUES ('upgrade-owner','device','nonce',9999999999999);"))
    old_ledger, captured := native_migration_ledger(&conn)
    if !testing.expect(t, captured, "snapshot exact predecessor identities and timestamps") do return
    old_count := native_migration_text(&conn, "SELECT count(*) FROM schema_migrations;")
    testing.expect_value(t, old_count, "128")
    close(&conn)
    conn, ok, _ = open(path)
    if !testing.expect(t, ok, "reopen predecessor fixture") do return
    for _ in 0..<2 {
        mig_ok, _ = run_migrations(&conn)
        if !testing.expect(t, mig_ok, "current-registry upgrade/repeat") do return
        current, read_ok := native_migration_ledger(&conn)
        testing.expect(t, read_ok && native_ledger_preserves(old_ledger, current), "every captured predecessor identity/timestamp is unchanged")
        testing.expect(t, read_ok && native_ledger_matches_registry(current, registry[:]), "ledger equals unique current registry")
        testing.expect_value(t, native_migration_text(&conn, "SELECT subject FROM user_external_identities WHERE user_id='upgrade-owner';"), "subject")
        testing.expect_value(t, native_migration_text(&conn, "SELECT nonce FROM vault_request_nonces WHERE user_id='upgrade-owner';"), "nonce")
        testing.expect(t, table_column_exists(&conn, "action_schedule_revision", "revision"))
        testing.expect(t, !sqlite_object_exists(&conn, "agent_extension_events_instance_agent"))
    }
}

// Capture rows individually: delimiters in a value cannot hide changed identities
// or timestamps. Query failures must never look like a valid empty ledger.
native_migration_ledger :: proc(conn: ^Conn) -> (map[string]string, bool) {
    rows := make(map[string]string)
    stmt: sqlite3_stmt
    if sqlite3_prepare_v2(conn.db, "SELECT version, applied_at FROM schema_migrations;", -1, &stmt, nil) != SQLITE_OK do return rows, false
    defer sqlite3_finalize(stmt)
    for {
        rc := sqlite3_step(stmt)
        if rc == SQLITE_DONE do return rows, true
        if rc != SQLITE_ROW do return rows, false
        name := strings.clone(column_text_unowned(stmt, 0), context.temp_allocator)
        if _, exists := rows[name]; exists do return rows, false
        rows[name] = strings.clone(column_text_unowned(stmt, 1), context.temp_allocator)
    }
}

native_ledger_preserves :: proc(before, after: map[string]string) -> bool {
    for name, timestamp in before {
        current, exists := after[name]
        if !exists || current != timestamp do return false
    }
    return true
}

native_ledger_matches_registry :: proc(ledger: map[string]string, registry: []string) -> bool {
    unique := make(map[string]bool)
    for name in registry {
        if unique[name] do return false
        unique[name] = true
        if _, exists := ledger[name]; !exists do return false
    }
    return len(ledger) == len(unique)
}

@(test)
test_native_ledger_guards_detect_corruption_and_allow_registry_growth :: proc(t: ^testing.T) {
    registry := migration_order
    context.allocator = context.temp_allocator
    conn, path, ok := tmpl_open_file_prod(t, "native_ledger_guards")
    defer tmpl_remove_db(path)
    if !ok do return
    defer close(&conn)
    mig_ok, _ := run_migrations(&conn)
    if !testing.expect(t, mig_ok, "complete current schema") do return
    before, captured := native_migration_ledger(&conn)
    if !testing.expect(t, captured && native_ledger_matches_registry(before, registry[:]), "valid current ledger") do return
    mutations := [4]string{
        "UPDATE schema_migrations SET applied_at='changed' WHERE version='001_foundation.sql';",
        "DELETE FROM schema_migrations WHERE version='001_foundation.sql';",
        "UPDATE schema_migrations SET version='unexpected_identity.sql' WHERE version='001_foundation.sql';",
        "INSERT INTO schema_migrations(version,applied_at) VALUES('unexpected_identity.sql','now');",
    }
    for mutation in mutations {
        if !testing.expect(t, exec(&conn, "BEGIN;") && exec(&conn, mutation), mutation) do return
        changed, read_ok := native_migration_ledger(&conn)
        testing.expect(t, read_ok, "read mutated ledger")
        // Timestamp corruption retains membership; every other corruption changes it.
        if strings.has_prefix(mutation, "UPDATE schema_migrations SET applied_at") {
            testing.expect(t, !native_ledger_preserves(before, changed), "changed historical timestamp detected")
            testing.expect(t, native_ledger_matches_registry(changed, registry[:]), "timestamp check is independent of membership")
        } else {
            testing.expect(t, !native_ledger_matches_registry(changed, registry[:]), "missing/renamed/extra identity detected")
            if !strings.has_prefix(mutation, "INSERT") do testing.expect(t, !native_ledger_preserves(before, changed), "missing historical identity detected")
        }
        testing.expect(t, exec(&conn, "ROLLBACK;"))
    }
    // A missing or duplicate registry entry also fails, independent of SQL count.
    testing.expect(t, !native_ledger_matches_registry(before, registry[:len(registry)-1]), "missing registry identity detected")
    expanded := make([dynamic]string)
    append(&expanded, ..registry[:])
    append(&expanded, registry[0])
    testing.expect(t, !native_ledger_matches_registry(before, expanded[:]), "duplicate registry identity detected")
    expanded[len(expanded)-1] = "future_fixture.sql"
    testing.expect(t, exec(&conn, "INSERT INTO schema_migrations(version,applied_at) VALUES('future_fixture.sql','future');"))
    added, read_ok := native_migration_ledger(&conn)
    testing.expect(t, read_ok && native_ledger_preserves(before, added), "valid additions preserve historical rows")
    testing.expect(t, native_ledger_matches_registry(added, expanded[:]), "valid registry growth accepted without fixed count or exclusions")
    testing.expect(t, !native_ledger_matches_registry(added, registry[:]), "unregistered addition rejected")
}
