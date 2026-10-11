package main

// REQ-VAULT-HARDEN-6, REQ-VAULT-HARDEN-9, REQ-VAULT-HARDEN-12:
// Automated test suite for keystore container fallback and in-memory resilience.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"

KEYSTORE_SEC_TEST_KEY_1 :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
KEYSTORE_SEC_TEST_KEY_2 :: "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"

@(private = "file")
keystore_test_ids_once: sync.Once
@(private = "file")
keystore_test_ids_buf: [64]u8
@(private = "file")
keystore_test_ids_len: int

// keystore_test_bridge_ids returns this test process's two bridge ids,
// `brg_test_<pid>` and `brg_test_<pid>_b` (REQ-T5-4). Every test that persists a
// vault key uses them: a test build refuses any id without
// KEYSTORE_TEST_BRIDGE_ID_PREFIX, and the pid keeps concurrent test runs on one
// host apart. The strings live for the whole process.
keystore_test_bridge_ids :: proc() -> (a: string, b: string) {
	sync.once_do(&keystore_test_ids_once, proc() {
		s := fmt.bprintf(keystore_test_ids_buf[:], "%s%d_b", KEYSTORE_TEST_BRIDGE_ID_PREFIX, int(posix.getpid()))
		keystore_test_ids_len = len(s)
	})
	b = string(keystore_test_ids_buf[:keystore_test_ids_len])
	return b[:len(b) - 2], b
}

// keystore_test_set_daemon_id points the running bridge (bridge_config.daemon_id,
// which bridge_read_vault_key / bridge_vault_lock resolve) at id and returns the
// previous value for the caller to restore. Hold bridge_test_config_mutex.
keystore_test_set_daemon_id :: proc(id: string) -> (prev: string) {
	prev = bridge_config.daemon_id
	bridge_config.daemon_id = id
	return
}

@(test)
test_keystore_container_fallback_in_memory_resilience :: proc(t: ^testing.T) {
	// HEIMDALL_VAULT_KEY is a PROCESS-GLOBAL. keystore_test_mutex alone does not
	// serialise this test against the ~29 env-mutating tests that hold
	// bridge_test_config_mutex instead - two disjoint locks exclude nobody, so those
	// two sets raced on one shared value (iss_18db48473fc5cb6d, 2026-10-04).
	// Taken OUTERMOST, before keystore_test_mutex: the acquisition graph stays acyclic.
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	id_a, _ := keystore_test_bridge_ids()
	prev_daemon_id := keystore_test_set_daemon_id(id_a)
	defer bridge_config.daemon_id = prev_daemon_id

	keystore_lock_and_purge(id_a)
	defer keystore_lock_and_purge(id_a)

	prev_env, had_env := os.lookup_env("HEIMDALL_VAULT_KEY", context.allocator)
	defer {
		if had_env {
			_ = os.set_env("HEIMDALL_VAULT_KEY", prev_env)
			delete(prev_env)
		} else {
			_ = os.unset_env("HEIMDALL_VAULT_KEY")
		}
	}
	os.unset_env("HEIMDALL_VAULT_KEY")

	// 1. Simulate Docker / Kubernetes seccomp profile blocking keyctl with EPERM (REQ-VAULT-HARDEN-9)
	keystore_set_mock_syscall_error(KEYSTORE_ERR_EPERM)
	defer keystore_set_mock_syscall_error(0)

	keystore_wipe_in_memory_vault_key()

	// Storing key must succeed via in-memory fallback without crashing
	ok_eperm, err_eperm := keystore_store_vault_key(id_a, KEYSTORE_SEC_TEST_KEY_1)
	testing.expect(t, ok_eperm, "keystore_store_vault_key must succeed via in-memory fallback on EPERM")
	testing.expect_value(t, err_eperm, KEYSTORE_ERR_EPERM)

	// In-memory buffer must hold the unsealed key
	mem_key, mem_ok := keystore_read_in_memory_vault_key()
	testing.expect(t, mem_ok, "keystore_read_in_memory_vault_key must return key from JIT memory")
	defer if mem_ok do delete(mem_key)
	testing.expect_value(t, mem_key, KEYSTORE_SEC_TEST_KEY_1)

	// bridge_read_vault_key() must transparently resolve the in-memory key
	bridge_key, bridge_ok := bridge_read_vault_key()
	testing.expect(t, bridge_ok, "bridge_read_vault_key must resolve key from in-memory fallback")
	defer if bridge_ok do delete(bridge_key)
	testing.expect_value(t, bridge_key, KEYSTORE_SEC_TEST_KEY_1)

	// Vault status must report Unlocked
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Unlocked)

	// 2. Simulate environment without CONFIG_KEYS returning ENOSYS
	keystore_set_mock_syscall_error(KEYSTORE_ERR_ENOSYS)
	keystore_wipe_in_memory_vault_key()

	ok_enosys, err_enosys := keystore_store_vault_key(id_a, KEYSTORE_SEC_TEST_KEY_2)
	testing.expect(t, ok_enosys, "keystore_store_vault_key must succeed via in-memory fallback on ENOSYS")
	testing.expect_value(t, err_enosys, KEYSTORE_ERR_ENOSYS)

	bridge_key2, bridge_ok2 := bridge_read_vault_key()
	testing.expect(t, bridge_ok2, "bridge_read_vault_key must resolve second key from in-memory fallback")
	defer if bridge_ok2 do delete(bridge_key2)
	testing.expect_value(t, bridge_key2, KEYSTORE_SEC_TEST_KEY_2)

	// 3. Purging must zero and wipe the in-memory buffer
	keystore_lock_and_purge(id_a)
	_, after_purge_ok := keystore_read_in_memory_vault_key()
	testing.expect(t, !after_purge_ok, "in-memory buffer must be purged after keystore_lock_and_purge")
}

@(test)
test_keystore_in_memory_rejection_of_invalid_keys :: proc(t: ^testing.T) {
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	keystore_wipe_in_memory_vault_key()
	defer keystore_wipe_in_memory_vault_key()

	// Short key
	ok_short := keystore_store_in_memory_vault_key("abcd1234")
	testing.expect(t, !ok_short, "short hex key must be rejected from in-memory storage")

	// Non-hex characters
	non_hex := "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
	ok_non_hex := keystore_store_in_memory_vault_key(non_hex)
	testing.expect(t, !ok_non_hex, "non-hex key must be rejected from in-memory storage")

	// Empty key
	ok_empty := keystore_store_in_memory_vault_key("")
	testing.expect(t, !ok_empty, "empty key must be rejected from in-memory storage")
}

@(test)
test_keystore_test_build_refuses_non_test_bridge_ids :: proc(t: ^testing.T) {
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	keystore_set_mock_syscall_error(0)
	keystore_wipe_in_memory_vault_key()
	defer keystore_wipe_in_memory_vault_key()

	// REQ-T5-2 / REQ-T5-4: no id means no key name -- there is no unscoped
	// fallback -- and a test build can never name a real bridge's key.
	for id in ([]string{"", "brg_18dd7ec8c8dec6d0", "../brg_test_x", "brg_test_/x"}) {
		ok, err := keystore_store_vault_key(id, KEYSTORE_SEC_TEST_KEY_1)
		testing.expectf(t, !ok, "store under %q must be refused", id)
		testing.expect_value(t, err, KEYSTORE_ERR_BAD_BRIDGE_ID)
		key, found := keystore_read_keyring_vault_key(id)
		if found do delete(key)
		testing.expectf(t, !found, "read under %q must find nothing", id)
		testing.expectf(t, !keystore_persisted_vault_item_present(id), "%q must have no persisted item", id)
	}
	mem_key, mem_ok := keystore_read_in_memory_vault_key()
	if mem_ok do delete(mem_key)
	testing.expect(t, !mem_ok, "a refused store must not even reach the in-memory buffer")

	id_a, id_b := keystore_test_bridge_ids()
	testing.expect(t, strings.has_prefix(id_a, KEYSTORE_TEST_BRIDGE_ID_PREFIX), "test id A carries the test prefix")
	testing.expect(t, id_a != id_b && strings.has_prefix(id_b, id_a), "test ids A and B are distinct")
	testing.expect(t, keystore_bridge_id_ok(id_a) && keystore_bridge_id_ok(id_b), "the test ids are accepted")
}
