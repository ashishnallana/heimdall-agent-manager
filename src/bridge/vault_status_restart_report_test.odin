#+build linux, darwin
package main

// REQ-T2-3: after `ham-bridge enroll` restarts the service, the hub must learn the
// vault state from the NEW process, read back from the OS key store, and never
// from the enroll process that is about to exit.

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import cfg_lib "odin_test:lib/config"

@(test)
test_on_connect_heartbeat_reports_persisted_vault_after_restart :: proc(t: ^testing.T) {
	// Same lock order as keystore_test.odin: env lock OUTERMOST, then keystore.
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

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

	keystore_set_mock_syscall_error(0)
	keystore_lock_and_purge()
	defer keystore_lock_and_purge()

	ok, err := keystore_store_vault_key(KEYSTORE_SEC_TEST_KEY_1)
	testing.expect(t, ok, "store must succeed")
	testing.expect_value(t, err, 0)

	// Simulate the restart: the new process has an empty in-memory buffer, so the
	// only copy left is the persisted one, and it must be exactly what was stored.
	keystore_wipe_in_memory_vault_key()
	persisted, persisted_ok := keystore_read_keyring_vault_key()
	testing.expect(t, persisted_ok, "the OS store must still hold the key after the memory wipe")
	defer if persisted_ok do delete(persisted)
	testing.expect_value(t, persisted, KEYSTORE_SEC_TEST_KEY_1)

	// The frame bridge_hub_runtime_loop sends immediately on connect.
	hb := bridge_hub_heartbeat_json()
	defer delete(hb)
	testing.expect(t, strings.contains(hb, "\"vault_status\":\"unlocked\""), "on-connect heartbeat must report the key read back from the OS store")

	// A host with the deprecated ~/.config/heimdall/vault_key file stays unlocked
	// after a purge by design (bridge_read_vault_key falls back to it), so the
	// negative half only holds where that file is absent.
	if !vault_restart_test_legacy_key_file_present() {
		keystore_lock_and_purge()
		hb_after := bridge_hub_heartbeat_json()
		defer delete(hb_after)
		testing.expect(t, !strings.contains(hb_after, "\"vault_status\":\"unlocked\""), "after purge the on-connect heartbeat must not report unlocked")
	}
}

@(private = "file")
vault_restart_test_legacy_key_file_present :: proc() -> bool {
	path := cfg_lib.expand_home("~/.config/heimdall/vault_key")
	defer delete(path)
	return os.exists(path)
}

@(test)
test_enroll_only_runtime_never_reports_unlocked :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

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

	keystore_wipe_in_memory_vault_key()
	defer keystore_wipe_in_memory_vault_key()
	testing.expect(t, keystore_store_in_memory_vault_key(KEYSTORE_SEC_TEST_KEY_1), "in-memory store must succeed")

	// The enroll process holds the delivered key, yet reports locked: the restarted
	// service's on-connect heartbeat is the only report allowed to say unlocked.
	testing.expect_value(t, bridge_vault_status_reported(true), Vault_Status.Locked)
	testing.expect_value(t, bridge_vault_status_reported(false), Vault_Status.Unlocked)
}
