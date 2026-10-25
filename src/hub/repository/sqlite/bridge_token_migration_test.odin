#+private file
package sqlite

import "core:testing"

// Migrations 138-140 (bridge refresh retry). 140's unique index is a backstop; a
// database whose rows already break it (only the pre-fix grace race could produce
// that) must still start: the index is skipped and logged, not fatal.

BTM_INDEX :: "bridge_tokens_family_kind_generation"

@(test)
test_bridge_token_retry_migrations_fresh_and_with_duplicates :: proc(t: ^testing.T) {
	fresh, fresh_path, fresh_ok := tmpl_open_file_prod(t, "btm_fresh")
	if !fresh_ok do return
	defer tmpl_remove_db(fresh_path)
	defer close(&fresh)
	ok, err := run_migrations(&fresh)
	if !testing.expect(t, ok, err.message) do return
	testing.expect(t, table_column_exists(&fresh, "bridge_tokens", "rotation_request_hash"))
	testing.expect(t, table_column_exists(&fresh, "bridge_tokens", "first_used_at"))
	testing.expect(t, table_column_exists(&fresh, "bridge_tokens", "regrant_claim"))
	testing.expect(t, sqlite_object_exists(&fresh, BTM_INDEX), "a clean database gets the unique index")
	testing.expect(t, exec(&fresh, "INSERT INTO bridge_tokens (token_id, bridge_id, kind, token_hash, family_id, generation, scope, issued_at, expires_at, family_expires_at, rotated_at, revoked_at) VALUES ('a', 'b', 'refresh', 'h', 'f', 1, 's', '', '', '', '', '');"))
	testing.expect(t, !exec(&fresh, "INSERT INTO bridge_tokens (token_id, bridge_id, kind, token_hash, family_id, generation, scope, issued_at, expires_at, family_expires_at, rotated_at, revoked_at) VALUES ('b', 'b', 'refresh', 'h', 'f', 1, 's', '', '', '', '', '');"), "a second row of one generation is refused")

	dup, dup_path, dup_ok := tmpl_open_file_prod(t, "btm_dup")
	if !dup_ok do return
	defer tmpl_remove_db(dup_path)
	defer close(&dup)
	ok, err = run_migrations(&dup, stop_before = "140_bridge_tokens_unique_generation.sql")
	if !testing.expect(t, ok, err.message) do return
	testing.expect(t, exec(&dup, "INSERT INTO bridge_tokens (token_id, bridge_id, kind, token_hash, family_id, generation, scope, issued_at, expires_at, family_expires_at, rotated_at, revoked_at) VALUES ('d1', 'b', 'refresh', 'h', 'f', 1, 's', '', '', '', '', '');"))
	testing.expect(t, exec(&dup, "INSERT INTO bridge_tokens (token_id, bridge_id, kind, token_hash, family_id, generation, scope, issued_at, expires_at, family_expires_at, rotated_at, revoked_at) VALUES ('d2', 'b', 'refresh', 'h', 'f', 1, 's', '', '', '', '', '');"))
	ok, err = run_migrations(&dup)
	testing.expect(t, ok, "a database with pre-existing duplicates still starts")
	testing.expect(t, !sqlite_object_exists(&dup, BTM_INDEX), "the backstop index is skipped there")
	testing.expect(t, migration_applied(&dup, "140_bridge_tokens_unique_generation.sql"))
}
