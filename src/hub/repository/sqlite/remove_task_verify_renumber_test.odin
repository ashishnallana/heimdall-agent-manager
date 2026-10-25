#+private file
package sqlite

import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import provider_service "odin_test:hub/service/provider"
import "core:strings"
import "core:testing"

// Release 0.4.43 took migration number 128 after the verify removal had already
// been applied as 128_remove_task_verify.sql on some databases; the removal is
// now 129. Every starting point must end with the 0.4.43 extension sync applied,
// the provider catalog at the current release (later releases append their own
// syncs after 129), and the removal applied exactly once, so the one-shot
// boot-regate marker is never re-created after a boot consumed it.

RTV_SYNC :: "128_extension_version_sync_0_4_43.sql"
RTV_REMOVAL :: "129_remove_task_verify.sql"
RTV_LEGACY_REMOVAL :: "128_remove_task_verify.sql"
RTV_LAST_PRE_RENUMBER_SYNC :: "127_extension_version_sync_0_4_42.sql"

rtv_text :: proc(conn: ^Conn, query: string) -> string {
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(conn.db, strings.clone_to_cstring(query, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return ""
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return ""
	return strings.clone(column_text_unowned(stmt, 0), context.temp_allocator)
}

rtv_min_version :: proc(conn: ^Conn) -> string {
	return rtv_text(conn, "SELECT json_extract(extension, '$.min_version') FROM provider_catalog WHERE provider='claude';")
}

rtv_markers :: proc(conn: ^Conn) -> string {
	if !sqlite_object_exists(conn, "taskv2_boot_regate") do return "no table"
	return rtv_text(conn, "SELECT count(*) FROM taskv2_boot_regate;")
}

rtv_open_migrated :: proc(t: ^testing.T, tag: string) -> (Conn, string, bool) {
	conn, path, ok := tmpl_open_file_prod(t, tag)
	if !ok do return conn, path, false
	mig_ok, err := run_migrations(&conn)
	if !testing.expect(t, mig_ok, err.message) {
		close(&conn)
		return Conn{}, path, false
	}
	return conn, path, true
}

// The catalog etag the Hub derives from the stored provider catalog body.
rtv_derived_etag :: proc(t: ^testing.T, conn: ^Conn) -> string {
	impl := Provider_Repo_SQLite{conn = conn}
	repo := new_provider_repository(&impl, conn)
	service := provider_service.Provider_Service{repo = &repo}
	derived, err := provider_service.catalog_etag(&service)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	return derived
}

// Rewinds the provider catalog and ledger to what 127 (0.4.42) left: every
// later extension sync (0.4.43 and any newer release) is unrecorded.
rtv_rewind_sync :: proc(t: ^testing.T, conn: ^Conn) {
	testing.expect(t, exec(conn, `UPDATE provider_catalog SET extension = json_patch(extension, '{"min_version":"0.4.42"}') WHERE provider IN ('antigravity', 'claude', 'codex');`))
	testing.expect(t, exec(conn, "DELETE FROM provider_catalog_meta; INSERT INTO provider_catalog_meta (catalog_etag) VALUES ('sha256:6819de777a41f381aa6f13134b28cabff713b95647b418a549d6a99375d9c0b3');"))
	after_127 := false
	rewound := 0
	for name in migration_order {
		if after_127 && strings.contains(name, "_extension_version_sync_") {
			testing.expect(t, exec(conn, strings.concatenate({"DELETE FROM schema_migrations WHERE version='", name, "';"}, context.temp_allocator)))
			testing.expectf(t, !migration_applied(conn, name), "%s rewound", name)
			rewound += 1
		}
		if name == RTV_LAST_PRE_RENUMBER_SYNC do after_127 = true
	}
	testing.expect(t, rewound >= 1, "the 0.4.43 sync is among the rewound syncs")
}

rtv_expect_converged :: proc(t: ^testing.T, conn: ^Conn, markers: string, why: string) {
	testing.expectf(t, migration_applied(conn, RTV_SYNC), "%s: 0.4.43 sync recorded", why)
	testing.expectf(t, migration_applied(conn, RTV_REMOVAL), "%s: removal recorded", why)
	for name in migration_order {
		if strings.contains(name, "_extension_version_sync_") do testing.expectf(t, migration_applied(conn, name), "%s: %s recorded", why, name)
	}
	testing.expectf(t, rtv_min_version(conn) == contracts.APP_VERSION, "%s: min_version is %s, want %s", why, rtv_min_version(conn), contracts.APP_VERSION)
	etag := rtv_text(conn, "SELECT catalog_etag FROM provider_catalog_meta;")
	derived := rtv_derived_etag(t, conn)
	testing.expectf(t, etag == derived, "%s: catalog etag %s, want %s", why, etag, derived)
	testing.expectf(t, rtv_markers(conn) == markers, "%s: boot-regate markers %s, want %s", why, rtv_markers(conn), markers)
}

@(test)
test_remove_task_verify_fresh_database :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, path, ok := rtv_open_migrated(t, "rtv_fresh")
	defer tmpl_remove_db(path)
	if !ok do return
	defer close(&conn)
	rtv_expect_converged(t, &conn, "1", "fresh")
	testing.expect(t, !migration_applied(&conn, RTV_LEGACY_REMOVAL), "fresh database never records the legacy name")
	// boot consumes the marker; later starts must not bring it back
	testing.expect(t, exec(&conn, "DELETE FROM taskv2_boot_regate;"))
	mig_ok, err := run_migrations(&conn)
	testing.expect(t, mig_ok, err.message)
	rtv_expect_converged(t, &conn, "0", "fresh restart")
}

@(test)
test_remove_task_verify_upgrade_from_release_0_4_43 :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, path, ok := tmpl_open_file_prod(t, "rtv_upstream")
	defer tmpl_remove_db(path)
	if !ok do return
	defer close(&conn)
	mig_ok, err := run_migrations(&conn, stop_before = RTV_REMOVAL)
	if !testing.expect(t, mig_ok, err.message) do return
	testing.expect(t, migration_applied(&conn, RTV_SYNC), "upstream 0.4.43 database has its sync")
	testing.expect_value(t, rtv_markers(&conn), "no table")
	mig_ok, err = run_migrations(&conn)
	if !testing.expect(t, mig_ok, err.message) do return
	rtv_expect_converged(t, &conn, "1", "upstream upgrade")
	testing.expect(t, exec(&conn, "DELETE FROM taskv2_boot_regate;"))
	mig_ok, err = run_migrations(&conn)
	testing.expect(t, mig_ok, err.message)
	rtv_expect_converged(t, &conn, "0", "upstream restart")
}

// A database migrated by the pre-renumber binary: 127, then the removal recorded
// as 128_remove_task_verify.sql, and no 0.4.43 sync.
@(test)
test_remove_task_verify_upgrade_after_legacy_128_removal :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	for consumed in ([]bool{true, false}) {
		conn, path, ok := rtv_open_migrated(t, consumed ? "rtv_legacy_booted" : "rtv_legacy_unbooted")
		defer tmpl_remove_db(path)
		if !ok do return
		defer close(&conn)
		rtv_rewind_sync(t, &conn)
		testing.expect(t, exec(&conn, "DELETE FROM schema_migrations WHERE version='" + RTV_REMOVAL + "'; INSERT INTO schema_migrations (version) VALUES ('" + RTV_LEGACY_REMOVAL + "');"))
		if consumed do testing.expect(t, exec(&conn, "DELETE FROM taskv2_boot_regate;"))
		testing.expect_value(t, rtv_min_version(&conn), "0.4.42")
		testing.expect(t, migration_applied(&conn, RTV_REMOVAL), "the legacy ledger row counts as the removal")

		mig_ok, err := run_migrations(&conn)
		if !testing.expect(t, mig_ok, err.message) do return
		// the sync runs; the removal does not, so a consumed marker stays consumed
		// and an unconsumed one is still taken exactly once by the next boot
		rtv_expect_converged(t, &conn, consumed ? "0" : "1", consumed ? "legacy booted" : "legacy unbooted")
		testing.expect(t, migration_applied(&conn, RTV_LEGACY_REMOVAL), "legacy ledger row kept as history")
		mig_ok, err = run_migrations(&conn)
		testing.expect(t, mig_ok, err.message)
		rtv_expect_converged(t, &conn, consumed ? "0" : "1", "legacy restart")
	}
}
