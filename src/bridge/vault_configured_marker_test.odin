#+build linux, darwin
package main

// REQ-T3: a bridge that was ever unsealed keeps reporting "locked" (not
// "disabled") after a restart, via a per-bridge marker under
// ~/.config/heimdall/bridges/<bridge_id>/vault_configured (REQ-T3-6).
//
// Every test runs inside bridge_vault_test_sandbox_open (temp HOME and
// HEIMDALL_HOME), so the operator's real config dir is unreachable.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:time"
import vault "odin_test:lib/vault"

// The marker and the keyring/Keychain key share this process's test-only bridge
// id, so no real bridge's state is reachable (REQ-T5-4).
@(private = "file")
vault_marker_test_bridge_id :: proc() -> string {
	id, _ := keystore_test_bridge_ids()
	return id
}

// Process-wide state these tests mutate, captured so close() restores it exactly.
@(private = "file")
Vault_Marker_Test_Env :: struct {
	sb:               Bridge_Vault_Test_Sandbox,
	prev_key:         string,
	had_key:          bool,
	prev_configured:  string,
	had_configured:   bool,
	prev_daemon_id:   string,
	prev_flag:        bool,
}

// Takes the env lock OUTERMOST, then the keystore lock (the order every vault
// test uses), sandboxes HOME, clears both vault env vars and every in-process
// vault signal, and points bridge_config.daemon_id at the test bridge. Callers:
//
//	env, ok := vault_marker_test_open(t, "label")
//	defer vault_marker_test_close(&env)
//	if !ok do return
@(private = "file")
vault_marker_test_open :: proc(t: ^testing.T, label: string) -> (env: Vault_Marker_Test_Env, ok: bool) {
	sync.mutex_lock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)

	env.prev_key, env.had_key = os.lookup_env("HEIMDALL_VAULT_KEYRING", context.allocator)
	env.prev_configured, env.had_configured = os.lookup_env("HEIMDALL_VAULT_CONFIGURED", context.allocator)
	env.prev_daemon_id = bridge_config.daemon_id
	env.prev_flag = bridge_workspace_vault_configured

	os.unset_env("HEIMDALL_VAULT_KEYRING")
	os.unset_env("HEIMDALL_VAULT_CONFIGURED")
	bridge_config.daemon_id = vault_marker_test_bridge_id()
	bridge_workspace_vault_configured = false
	keystore_set_mock_syscall_error(0)
	keystore_lock_and_purge(vault_marker_test_bridge_id())

	env.sb, ok = bridge_vault_test_sandbox_open(t, label)
	return
}

@(private = "file")
vault_marker_test_close :: proc(env: ^Vault_Marker_Test_Env) {
	keystore_lock_and_purge(vault_marker_test_bridge_id())
	bridge_vault_test_sandbox_close(&env.sb)

	bridge_workspace_vault_configured = env.prev_flag
	bridge_config.daemon_id = env.prev_daemon_id
	if env.had_key {
		_ = os.set_env("HEIMDALL_VAULT_KEYRING", env.prev_key)
		delete(env.prev_key)
	} else {
		os.unset_env("HEIMDALL_VAULT_KEYRING")
	}
	if env.had_configured {
		_ = os.set_env("HEIMDALL_VAULT_CONFIGURED", env.prev_configured)
		delete(env.prev_configured)
	} else {
		os.unset_env("HEIMDALL_VAULT_CONFIGURED")
	}

	sync.mutex_unlock(&keystore_test_mutex)
	sync.mutex_unlock(&bridge_test_config_mutex)
}

// Drops every in-process signal, as a restart does; only what is on disk (or in
// the OS key store) survives.
@(private = "file")
vault_marker_test_simulate_restart :: proc() {
	bridge_workspace_vault_configured = false
	keystore_wipe_in_memory_vault_key()
}

@(test)
test_vault_marker_path_is_per_bridge_and_rejects_unsafe_ids :: proc(t: ^testing.T) {
	env, ok := vault_marker_test_open(t, "marker_path")
	defer vault_marker_test_close(&env)
	if !ok do return

	path, path_ok := bridge_vault_configured_marker_path("brg_abc", context.temp_allocator)
	testing.expect(t, path_ok, "a plain bridge id must yield a marker path")
	testing.expect_value(t, path, fmt.tprintf("%s/.config/heimdall/bridges/brg_abc/vault_configured", env.sb.dir))

	dir, dir_ok := bridge_vault_bridge_dir("brg_abc", context.temp_allocator)
	testing.expect(t, dir_ok, "a plain bridge id must yield a bridge dir")
	testing.expect(t, strings.has_prefix(path, dir), "the marker lives inside the bridge dir T5 reuses")

	for bad in ([]string{"", ".", "..", "../brg_abc", "brg/abc", "brg abc", "brg\x00abc"}) {
		_, bad_ok := bridge_vault_configured_marker_path(bad, context.temp_allocator)
		testing.expect(t, !bad_ok, fmt.tprintf("bridge id %q must be rejected", bad))
	}
}

@(test)
test_vault_set_configured_writes_private_timestamp_marker :: proc(t: ^testing.T) {
	env, ok := vault_marker_test_open(t, "marker_write")
	defer vault_marker_test_close(&env)
	if !ok do return

	testing.expect(t, bridge_vault_set_configured(vault_marker_test_bridge_id(), true), "set_configured(true) must persist the marker")
	path, _ := bridge_vault_configured_marker_path(vault_marker_test_bridge_id(), context.temp_allocator)

	st: posix.stat_t
	testing.expect_value(t, posix.stat(strings.clone_to_cstring(path, context.temp_allocator), &st), posix.result.OK)
	all_perms := posix.mode_t{.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH}
	testing.expect_value(t, st.st_mode & all_perms, posix.mode_t{.IRUSR, .IWUSR})

	data, read_err := os.read_entire_file(path, context.allocator)
	testing.expect(t, read_err == nil, "marker must be readable")
	defer delete(data)
	content := strings.trim_space(string(data))
	_, ts_ok := action_scheduler_parse_rfc3339_ms(content)
	testing.expect(t, ts_ok, fmt.tprintf("marker must hold only an ISO-8601 timestamp, got %q", content))

	// A second unseal keeps the first-configured timestamp rather than rewriting it.
	sentinel_ts := "2020-01-01T00:00:00Z\n"
	_ = os.write_entire_file(path, transmute([]byte)sentinel_ts)
	testing.expect(t, bridge_vault_set_configured(vault_marker_test_bridge_id(), true), "repeat set_configured(true) must succeed")
	again, _ := os.read_entire_file(path, context.allocator)
	defer delete(again)
	testing.expect_value(t, strings.trim_space(string(again)), "2020-01-01T00:00:00Z")
}

@(test)
test_vault_restart_with_marker_and_no_key_reports_locked :: proc(t: ^testing.T) {
	env, ok := vault_marker_test_open(t, "marker_locked")
	defer vault_marker_test_close(&env)
	if !ok do return

	// Marker absent + no key -> Disabled.
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Disabled)

	testing.expect(t, bridge_vault_set_configured(vault_marker_test_bridge_id(), true), "marker write must succeed")
	vault_marker_test_simulate_restart()

	// Marker present + no key -> Locked, adopted back into the in-memory flag.
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Locked)
	testing.expect(t, bridge_workspace_vault_configured, "reading the marker must go through bridge_vault_set_configured")

	// REQ-T3-4: the on-connect heartbeat and the immediate vault report carry it.
	vault_marker_test_simulate_restart()
	hb := bridge_hub_heartbeat_json()
	defer delete(hb)
	testing.expect(t, strings.contains(hb, "\"vault_status\":\"locked\""), fmt.tprintf("restarted bridge heartbeat must report locked, got %s", hb))
	report := bridge_vault_status_report_json()
	defer delete(report)
	testing.expect(t, strings.contains(report, "\"vault_status\":\"locked\""), "immediate vault report must say locked")
}

@(test)
test_vault_marker_of_another_bridge_does_not_count :: proc(t: ^testing.T) {
	env, ok := vault_marker_test_open(t, "marker_other_bridge")
	defer vault_marker_test_close(&env)
	if !ok do return

	testing.expect(t, bridge_vault_set_configured("brg_some_other_bridge", true), "marker write must succeed")
	vault_marker_test_simulate_restart()
	testing.expect(t, !bridge_vault_marker_present(vault_marker_test_bridge_id()), "this bridge has no marker")
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Disabled)

	// An unenrolled bridge (empty id) never sees any marker either.
	bridge_config.daemon_id = ""
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Disabled)
	testing.expect(t, !bridge_vault_set_configured("", true), "an empty bridge id cannot persist a marker")
	testing.expect(t, bridge_vault_set_configured("", false), "clearing an empty bridge id trivially holds")
}

@(test)
test_vault_configured_env_override_beats_marker :: proc(t: ^testing.T) {
	env, ok := vault_marker_test_open(t, "marker_env")
	defer vault_marker_test_close(&env)
	if !ok do return

	testing.expect(t, bridge_vault_set_configured(vault_marker_test_bridge_id(), true), "marker write must succeed")
	vault_marker_test_simulate_restart()
	_ = os.set_env("HEIMDALL_VAULT_CONFIGURED", "false")
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Disabled)

	testing.expect(t, bridge_vault_set_configured(vault_marker_test_bridge_id(), false), "marker removal must succeed")
	vault_marker_test_simulate_restart()
	_ = os.set_env("HEIMDALL_VAULT_CONFIGURED", "true")
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Locked)
}

@(test)
test_vault_lock_keeps_marker_and_reset_removes_it :: proc(t: ^testing.T) {
	env, ok := vault_marker_test_open(t, "marker_lock_reset")
	defer vault_marker_test_close(&env)
	if !ok do return

	testing.expect(t, bridge_vault_set_configured(vault_marker_test_bridge_id(), true), "marker write must succeed")
	stored := test_store_keyring(vault_marker_test_bridge_id(), TEST_VAULT_KEY_HEX)
	testing.expect(t, stored, "key store must succeed")
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Unlocked)

	// Lock (hub bridge_lock and local vault.lock both call this) keeps the marker.
	bridge_vault_lock()
	testing.expect(t, bridge_vault_marker_present(vault_marker_test_bridge_id()), "lock must keep the marker")
	vault_marker_test_simulate_restart()
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Locked)

	// The bridge-local vault.reset op purges the key and removes the marker.
	route := bridge_agent_route("agent.vault.reset", "{}")
	testing.expect_value(t, route.kind, Bridge_Agent_Route_Kind.Local)
	testing.expect_value(t, route.local_op, "vault.reset")
	testing.expect(t, bridge_agent_method_allowed("agent.vault.reset"), "vault.reset must be dispatchable")

	_ = test_store_keyring(vault_marker_test_bridge_id(), TEST_VAULT_KEY_HEX)
	resp := bridge_vault_reset_response("req_t3_reset")
	defer delete(resp)
	testing.expect(t, strings.contains(resp, "\"ok\":true,\"data\":{\"ok\":true,\"status\":\"disabled\""), fmt.tprintf("reset response must report disabled, got %s", resp))
	testing.expect(t, strings.contains(resp, "\"marker_removed\":true"), "reset response must say the marker is gone")
	testing.expect(t, strings.contains(resp, "\"note\":\""), "reset response must document what it did")
	testing.expect(t, !bridge_vault_marker_present(vault_marker_test_bridge_id()), "reset must remove the marker")
	_, key_left := bridge_read_vault_keyring()
	testing.expect(t, !key_left, "reset must purge the key")
	vault_marker_test_simulate_restart()
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Disabled)
}

@(test)
test_vault_hub_unseal_frame_persists_marker :: proc(t: ^testing.T) {
	env, ok := vault_marker_test_open(t, "marker_unseal_frame")
	defer vault_marker_test_close(&env)
	if !ok do return

	unseal_nonce_cache_clear(&g_unseal_nonce_cache)
	bridge_unseal_init()
	now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000
	kr := test_keyring_from_hex(TEST_VAULT_KEY_HEX)
	defer vault.keyring_wipe(&kr)
	envelope := test_create_unseal_v2_payload(vault_marker_test_bridge_id(), &kr, now_ms, "nonce_t3_marker_01")
	defer delete(envelope)
	// A command id of its own, so the handler's command cache cannot replay
	// another test's result.
	frame, _ := strings.replace(envelope, "\"cmd_test\"", "\"cmd_t3_marker_unseal\"", 1, context.temp_allocator)

	bridge_hub_handle_command(nil, frame)

	testing.expect_value(t, bridge_vault_status(), Vault_Status.Unlocked)
	testing.expect(t, bridge_vault_marker_present(vault_marker_test_bridge_id()), "a successful hub unseal must persist this bridge's marker")

	// The full scenario: unsealed, then the key is lost on restart -> locked.
	keystore_lock_and_purge(vault_marker_test_bridge_id())
	vault_marker_test_simulate_restart()
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Locked)
}

@(test)
test_on_connect_heartbeat_reports_persisted_vault_after_restart :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	prev_env, had_env := os.lookup_env("HEIMDALL_VAULT_KEYRING", context.allocator)
	defer {
		if had_env {
			_ = os.set_env("HEIMDALL_VAULT_KEYRING", prev_env)
			delete(prev_env)
		} else {
			_ = os.unset_env("HEIMDALL_VAULT_KEYRING")
		}
	}
	os.unset_env("HEIMDALL_VAULT_KEYRING")

	id_a, _ := keystore_test_bridge_ids()
	prev_daemon_id := keystore_test_set_daemon_id(id_a)
	defer bridge_config.daemon_id = prev_daemon_id

	keystore_set_mock_syscall_error(0)
	keystore_lock_and_purge(id_a)
	defer keystore_lock_and_purge(id_a)

	want := test_keyring_from_hex(KEYSTORE_SEC_TEST_KEY_1)
	defer vault.keyring_wipe(&want)
	ok, err := keystore_store_vault_keyring(id_a, test_keyring_bytes(&want))
	testing.expect(t, ok, "store must succeed")
	testing.expect_value(t, err, 0)

	keystore_wipe_in_memory_vault_key()
	persisted, persisted_ok := keystore_read_persisted_vault_keyring(id_a)
	testing.expect(t, persisted_ok, "the OS store must still hold the keyring after the memory wipe")
	defer vault.keyring_wipe(&persisted)
	testing.expect(t, vault.keyring_equal(&persisted, &want), "the persisted keyring must read back unchanged")

	hb := bridge_hub_heartbeat_json()
	defer delete(hb)
	testing.expect(t, strings.contains(hb, "\"vault_status\":\"unlocked\""), "on-connect heartbeat must report the key read back from the OS store")

	keystore_lock_and_purge(id_a)
	hb_after := bridge_hub_heartbeat_json()
	defer delete(hb_after)
	testing.expect(t, !strings.contains(hb_after, "\"vault_status\":\"unlocked\""), "after purge the on-connect heartbeat must not report unlocked")
}

@(test)
test_enroll_only_runtime_never_reports_unlocked :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	prev_env, had_env := os.lookup_env("HEIMDALL_VAULT_KEYRING", context.allocator)
	defer {
		if had_env {
			_ = os.set_env("HEIMDALL_VAULT_KEYRING", prev_env)
			delete(prev_env)
		} else {
			_ = os.unset_env("HEIMDALL_VAULT_KEYRING")
		}
	}
	os.unset_env("HEIMDALL_VAULT_KEYRING")

	id_a, _ := keystore_test_bridge_ids()
	prev_daemon_id := keystore_test_set_daemon_id(id_a)
	defer bridge_config.daemon_id = prev_daemon_id
	keystore_wipe_in_memory_vault_key()
	defer keystore_wipe_in_memory_vault_key()
	kr := test_keyring_from_hex(KEYSTORE_SEC_TEST_KEY_1)
	defer vault.keyring_wipe(&kr)
	testing.expect(t, keystore_store_in_memory_vault_keyring(id_a, test_keyring_bytes(&kr)), "in-memory store must succeed")

	testing.expect_value(t, bridge_vault_status_reported(true), Vault_Status.Locked)
	testing.expect_value(t, bridge_vault_status_reported(false), Vault_Status.Unlocked)
}
