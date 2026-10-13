package sqlite

import "core:fmt"
import "core:os"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(test)
test_user_vault_repo_sqlite_lifecycle :: proc(t: ^testing.T) {
	db_path := ":memory:"
	conn, open_ok, _ := open(db_path)
	testing.expect(t, open_ok, "db open ok")
	defer close(&conn)

	mig_ok, _ := run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect(t, sqlite_object_exists(&conn, "user_vaults"), "user_vaults table exists")

	impl := User_Vault_Repo_SQLite{}
	repo := new_user_vault_repository(&impl, &conn)

	user_id := domain.User_ID("usr_test_123")

	// 1. Initial get should return found = false
	_, found0, err0 := iface.user_vault_get(&repo, user_id)
	testing.expect_value(t, err0.code, domain.Error_Code.None)
	testing.expect(t, !found0, "initial get returns not found")

	// 2. Save a vault
	vault_input := domain.User_Vault{
		user_id                      = user_id,
		encrypted_vault_key          = "enc_vault_key_b64",
		vault_key_nonce              = "nonce_12b_b64",
		vault_key_tag                = "tag_16b_b64",
		kdf_algorithm                = "PBKDF2-SHA256",
		kdf_salt                     = "salt_16b_b64",
		kdf_iterations               = 100000,
		recovery_encrypted_vault_key = "rec_enc_vault_key_b64",
		recovery_nonce               = "rec_nonce_12b_b64",
		recovery_tag                 = "rec_tag_16b_b64",
		recovery_salt                = "rec_salt_16b_b64",
		created_at                   = "2026-09-25T12:00:00Z",
		updated_at                   = "2026-09-25T12:00:00Z",
	}
	save_ok, save_err := iface.user_vault_save(&repo, vault_input)
	testing.expect(t, save_ok, "save user vault succeeds")
	testing.expect_value(t, save_err.code, domain.Error_Code.None)

	// 3. Get should return found = true and all matching fields
	saved_vault, found1, err1 := iface.user_vault_get(&repo, user_id)
	testing.expect_value(t, err1.code, domain.Error_Code.None)
	testing.expect(t, found1, "get returns found")
	testing.expect_value(t, string(saved_vault.user_id), "usr_test_123")
	testing.expect_value(t, saved_vault.encrypted_vault_key, "enc_vault_key_b64")
	testing.expect_value(t, saved_vault.vault_key_nonce, "nonce_12b_b64")
	testing.expect_value(t, saved_vault.vault_key_tag, "tag_16b_b64")
	testing.expect_value(t, saved_vault.kdf_algorithm, "PBKDF2-SHA256")
	testing.expect_value(t, saved_vault.kdf_salt, "salt_16b_b64")
	testing.expect_value(t, saved_vault.kdf_iterations, 100000)
	testing.expect_value(t, saved_vault.recovery_encrypted_vault_key, "rec_enc_vault_key_b64")
	testing.expect_value(t, saved_vault.recovery_nonce, "rec_nonce_12b_b64")
	testing.expect_value(t, saved_vault.recovery_tag, "rec_tag_16b_b64")
	testing.expect_value(t, saved_vault.recovery_salt, "rec_salt_16b_b64")
	testing.expect_value(t, saved_vault.created_at, "2026-09-25T12:00:00Z")
	testing.expect_value(t, saved_vault.updated_at, "2026-09-25T12:00:00Z")

	// 4. Update the vault (upsert)
	vault_updated := vault_input
	vault_updated.encrypted_vault_key = "new_enc_vault_key_b64"
	vault_updated.updated_at = "2026-09-25T13:00:00Z"
	up_ok, up_err := iface.user_vault_save(&repo, vault_updated)
	testing.expect(t, up_ok, "update user vault succeeds")
	testing.expect_value(t, up_err.code, domain.Error_Code.None)

	saved_vault2, found2, _ := iface.user_vault_get(&repo, user_id)
	testing.expect(t, found2, "get updated returns found")
	testing.expect_value(t, saved_vault2.encrypted_vault_key, "new_enc_vault_key_b64")
	testing.expect_value(t, saved_vault2.created_at, "2026-09-25T12:00:00Z")
	testing.expect_value(t, saved_vault2.updated_at, "2026-09-25T13:00:00Z")
}
