#+private file
// Behavioral tests for bridge vault status and version/update SQLite persistence.
package sqlite

import domain "odin_test:hub/domain"
import "core:fmt"
import iface "odin_test:hub/repository/iface"
import "core:os"
import "core:strings"
import "core:testing"

// --- Consolidated from bridge_vault_status_repo_test.odin ---

@(test)
test_bridge_vault_status_repo_roundtrip :: proc(t: ^testing.T) {
	conn, mig_ok := tmpl_clone_migrated(t)
	testing.expect(t, mig_ok, "migrated template clone ok")
	defer close(&conn)
	testing.expect(t, table_column_exists(&conn, "bridges", "vault_status"), "migration 056 created bridges.vault_status")

	repo_impl := Bridge_Repo_SQLite{conn = &conn}
	repo := new_bridge_repository(&repo_impl, &conn)

	base := domain.Bridge{
		bridge_id = "brg_vault_status_repo",
		owner_user_id = domain.User_ID("user_bvs_repo"),
		label = "Vault Status Bridge",
		machine_hostname = "test-box",
		machine_os = "linux",
		machine_arch = "amd64",
		capabilities_json = "{}",
		hub_url = "http://127.0.0.1:8080",
		status = .Online,
		bridge_token_hash = "token_hash_bvs",
		created_at = "2026-10-04T10:00:00Z",
		updated_at = "2026-10-04T10:00:00Z",
		last_seen_at = "2026-10-04T10:00:00Z",
	}

	// 1. Unreported stays unreported across a save/load cycle.
	_, save_ok, save_err := iface.bridge_save_bridge(&repo, base)
	testing.expect(t, save_ok, "unreported bridge saved")
	testing.expect_value(t, save_err.code, domain.Error_Code.None)

	loaded, get_ok, _ := iface.bridge_get_bridge(&repo, base.bridge_id)
	defer { b := loaded; domain.bridge_destroy(&b) }
	testing.expect(t, get_ok, "unreported bridge loaded")
	testing.expect_value(t, loaded.vault_status, "")

	// 2. Each legal value round-trips verbatim.
	for value in ([2]string{"unlocked", "locked"}) {
		updated := base
		updated.vault_status = value
		_, ok, _ := iface.bridge_save_bridge(&repo, updated)
		testing.expect(t, ok, fmt.tprintf("bridge saved with vault_status=%s", value))

		back, back_ok, _ := iface.bridge_get_bridge(&repo, base.bridge_id)
		defer { b := back; domain.bridge_destroy(&b) }
		testing.expect(t, back_ok, "bridge loaded")
		testing.expect_value(t, back.vault_status, value)
	}

	// 3. The listing path reads the same column (it has its own SELECT list, which is
	// exactly how a new column gets added to one query and forgotten in the other).
	listed, list_err := iface.bridge_list_by_owner(&repo, base.owner_user_id)
	defer {
		for br in listed {
			b := br; domain.bridge_destroy(&b)
		}
		delete(listed)
	}
	testing.expect_value(t, list_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(listed), 1)
	if len(listed) == 1 {
		testing.expect_value(t, listed[0].vault_status, "locked")
	}
}

// --- Consolidated from bridge_version_updates_repo_test.odin ---

@(test)
test_bridge_version_and_updates_roundtrip :: proc(t: ^testing.T) {
	conn, mig_ok := tmpl_clone_migrated(t)
	testing.expect(t, mig_ok, "migrated template clone ok")
	defer close(&conn)

	// Check table columns created by migration 054
	testing.expect(t, table_column_exists(&conn, "bridges", "version"), "bridges.version column exists")
	testing.expect(t, table_column_exists(&conn, "bridges", "commit_sha"), "bridges.commit_sha column exists")
	testing.expect(t, table_column_exists(&conn, "bridges", "build_timestamp"), "bridges.build_timestamp column exists")
	testing.expect(t, table_column_exists(&conn, "bridges", "update_status"), "bridges.update_status column exists")
	testing.expect(t, table_column_exists(&conn, "bridges", "update_error"), "bridges.update_error column exists")
	testing.expect(t, table_column_exists(&conn, "bridges", "update_message"), "bridges.update_message column exists")
	testing.expect(t, table_column_exists(&conn, "bridges", "update_progress"), "bridges.update_progress column exists")

	repo_impl := Bridge_Repo_SQLite{conn = &conn}
	repo := new_bridge_repository(&repo_impl, &conn)

	owner := domain.User_ID("user_bupd_repo")
	bridge_id := "brg_bupd_test"

	bridge := domain.Bridge{
		bridge_id = bridge_id,
		owner_user_id = owner,
		label = "Test Bridge",
		label_is_user_customized = false,
		machine_hostname = "cloudtop-worker",
		machine_os = "linux",
		machine_arch = "amd64",
		capabilities_json = "{}",
		hub_url = "http://127.0.0.1:8080",
		status = .Online,
		bridge_token_hash = "token_hash_123",
		created_at = "2026-10-01T10:00:00Z",
		updated_at = "2026-10-01T10:00:00Z",
		last_seen_at = "2026-10-01T10:00:00Z",
		revoked_at = "",
		version = "0.1.0",
		commit_sha = "a57c83d9",
		build_timestamp = "2026-10-01T10:13:00Z",
		update_status = "downloading",
		update_message = "Downloading update tarball...",
		update_progress = 20,
		update_error = "",
	}

	saved, save_ok, save_err := iface.bridge_save_bridge(&repo, bridge)
	testing.expect(t, save_ok, "save bridge ok")
	testing.expect_value(t, save_err.code, domain.Error_Code.None)
	testing.expect_value(t, saved.version, "0.1.0")

	// Read by id
	got, get_ok, get_err := iface.bridge_get_bridge(&repo, bridge_id)
	testing.expect(t, get_ok, "get bridge ok")
	testing.expect_value(t, get_err.code, domain.Error_Code.None)
	testing.expect_value(t, got.bridge_id, bridge_id)
	testing.expect_value(t, got.version, "0.1.0")
	testing.expect_value(t, got.commit_sha, "a57c83d9")
	testing.expect_value(t, got.build_timestamp, "2026-10-01T10:13:00Z")
	testing.expect_value(t, got.update_status, "downloading")
	testing.expect_value(t, got.update_message, "Downloading update tarball...")
	testing.expect_value(t, got.update_progress, 20)
	testing.expect_value(t, got.update_error, "")

	// Update with new status/error
	delete(got.update_status)
	got.update_status = strings.clone("failed")
	delete(got.update_message)
	got.update_message = strings.clone("tarball download failed")
	got.update_progress = 20
	delete(got.update_error)
	got.update_error = strings.clone("network timeout")
	_, update_ok, update_err := iface.bridge_save_bridge(&repo, got)
	testing.expect(t, update_ok, "update bridge ok")
	testing.expect_value(t, update_err.code, domain.Error_Code.None)

	// List by owner
	list, list_err := iface.bridge_list_by_owner(&repo, owner)
	testing.expect_value(t, list_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(list), 1)
	if len(list) > 0 {
		testing.expect_value(t, list[0].update_status, "failed")
		testing.expect_value(t, list[0].update_message, "tarball download failed")
		testing.expect_value(t, list[0].update_progress, 20)
		testing.expect_value(t, list[0].update_error, "network timeout")
	}

	// Clean up domain bridge
	domain.bridge_destroy(&got)
	for i in 0..<len(list) {
		domain.bridge_destroy(&list[i])
	}
	delete(list)
}
