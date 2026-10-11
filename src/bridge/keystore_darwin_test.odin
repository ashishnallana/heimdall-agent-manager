#+build darwin
package main

// REQ-T2-1 / REQ-T2-5: the macOS login-keychain persistence layer. These tests
// talk to the real Keychain of whoever runs them, under the test-only service
// name, so they never touch an enrolled bridge's item.

import "core:strings"
import "core:sync"
import "core:testing"

KEYSTORE_DARWIN_TEST_KEY :: "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

@(test)
test_keystore_darwin_test_build_uses_test_service :: proc(t: ^testing.T) {
	testing.expect(t, strings.has_suffix(KEYCHAIN_SERVICE_VAULT, ".test"), "a test build must never name the production Keychain item")
}

@(test)
test_keystore_darwin_keychain_survives_memory_wipe :: proc(t: ^testing.T) {
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	keystore_set_mock_syscall_error(0)
	keystore_lock_and_purge()
	defer keystore_lock_and_purge()

	ok, err := keystore_store_vault_key(KEYSTORE_DARWIN_TEST_KEY)
	testing.expect(t, ok, "keystore_store_vault_key must succeed")
	testing.expect_value(t, err, 0)

	// A restarted process starts with an empty buffer: only the Keychain remains.
	keystore_wipe_in_memory_vault_key()
	read_key, read_ok := keystore_read_keyring_vault_key()
	testing.expect(t, read_ok, "the Keychain must still hold the key after the memory wipe")
	defer if read_ok do delete(read_key)
	testing.expect_value(t, read_key, KEYSTORE_DARWIN_TEST_KEY)

	// Storing again updates the existing item rather than failing as a duplicate.
	ok2, err2 := keystore_store_vault_key(KEYSTORE_SEC_TEST_KEY_2)
	testing.expect(t, ok2, "re-storing must update the existing Keychain item")
	testing.expect_value(t, err2, 0)
	updated, updated_ok := keystore_read_keyring_vault_key()
	defer if updated_ok do delete(updated)
	testing.expect_value(t, updated, KEYSTORE_SEC_TEST_KEY_2)

	// Purge deletes the item AND wipes memory.
	keystore_lock_and_purge()
	after, after_ok := keystore_read_keyring_vault_key()
	if after_ok do delete(after)
	testing.expect(t, !after_ok, "the Keychain item must be gone after keystore_lock_and_purge")
	mem_after, mem_ok := keystore_read_in_memory_vault_key()
	if mem_ok do delete(mem_after)
	testing.expect(t, !mem_ok, "the in-memory buffer must be wiped after keystore_lock_and_purge")

	// Unlinking with nothing stored is a success: nothing remains.
	testing.expect(t, keystore_unlink_vault_key(), "unlink with no item must report success")
}

@(test)
test_keystore_darwin_keychain_failure_falls_back_to_memory :: proc(t: ^testing.T) {
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	keystore_set_mock_syscall_error(0)
	keystore_lock_and_purge()
	defer keystore_lock_and_purge()

	keystore_set_mock_syscall_error(KEYSTORE_ERR_EACCES)
	defer keystore_set_mock_syscall_error(0)

	ok, err := keystore_store_vault_key(KEYSTORE_DARWIN_TEST_KEY)
	testing.expect(t, ok, "a refused Keychain must fall back to memory, not fail")
	testing.expect_value(t, err, KEYSTORE_ERR_EACCES)

	mem_key, mem_ok := keystore_read_in_memory_vault_key()
	defer if mem_ok do delete(mem_key)
	testing.expect_value(t, mem_key, KEYSTORE_DARWIN_TEST_KEY)

	_, persisted := keystore_read_keyring_vault_key()
	testing.expect(t, !persisted, "nothing is persisted when the Keychain refused")
}
