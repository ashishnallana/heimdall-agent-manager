#+private file
// Behavioral tests for the provider catalog state produced by the migrations.
package sqlite

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import provider_service "odin_test:hub/service/provider"
import "core:strings"
import "core:testing"

// Migration 086: Heimdall launches claude with --dangerously-skip-permissions,
// so the "Bypass Permissions mode" warning must be auto-accepted (Down selects
// "Yes, I accept"; the default is "No, exit").
@(test)
test_claude_catalog_auto_accepts_bypass_permissions_warning :: proc(t: ^testing.T) {
	conn, open_ok, _ := open(":memory:")
	testing.expect(t, open_ok, "db open ok")
	defer close(&conn)
	mig_ok, _ := run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")

	impl := Provider_Repo_SQLite{conn = &conn}
	repo := new_provider_repository(&impl, &conn)
	entry, found, err := iface.provider_catalog_get(&repo, "claude")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect(t, found, "claude catalog entry exists")
	defer domain.provider_catalog_entry_destroy(entry)
	testing.expect(
		t,
		strings.contains(entry.startup_detection_json, `"Yes, I trust this folder","Bypass Permissions mode"]`),
		"bypass warning is an auto-enter pattern after folder trust",
	)
	testing.expect(
		t,
		strings.contains(entry.startup_detection_json, `"auto_enter_pre_keys":["Up","Up","Down"]`),
		"bypass warning pre-key is Down, parallel to its pattern",
	)
}

// provider_catalog_meta is audit metadata, but it should match the etag the
// Hub derives from the canonical body so operators inspecting the DB see truth.
@(test)
test_provider_catalog_meta_etag_matches_canonical_body :: proc(t: ^testing.T) {
	conn, open_ok, _ := open(":memory:")
	testing.expect(t, open_ok, "db open ok")
	defer close(&conn)
	mig_ok, _ := run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")

	impl := Provider_Repo_SQLite{conn = &conn}
	repo := new_provider_repository(&impl, &conn)
	stored, err := iface.provider_catalog_etag(&repo)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	defer delete(stored)
	service := provider_service.Provider_Service{repo = &repo}
	derived, derive_err := provider_service.catalog_etag(&service)
	testing.expect_value(t, derive_err.code, domain.Error_Code.None)
	defer delete(derived)
	testing.expect_value(t, stored, derived)
}
