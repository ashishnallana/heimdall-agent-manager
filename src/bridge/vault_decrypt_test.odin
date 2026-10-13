package main

import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import cfg_lib "odin_test:lib/config"

TEST_VAULT_KEY_HEX :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

keystore_test_mutex: sync.Mutex

@(test)
test_bridge_vault_encrypt_decrypt_roundtrip :: proc(t: ^testing.T) {
	plaintext := "Secret Task Title for Agents"
	armored, enc_ok := bridge_encrypt_vault_ciphertext_hex(plaintext, TEST_VAULT_KEY_HEX)
	testing.expect(t, enc_ok, "encryption must succeed")
	defer delete(armored)
	testing.expect(t, strings.has_prefix(armored, "vault:v1:"), "armored string must start with vault:v1:")

	decrypted, dec_ok := bridge_decrypt_vault_ciphertext_hex(armored, TEST_VAULT_KEY_HEX)
	testing.expect(t, dec_ok, "decryption must succeed")
	defer delete(decrypted)
	testing.expect_value(t, decrypted, plaintext)
}

@(test)
test_bridge_vault_decrypt_wrong_key_fails :: proc(t: ^testing.T) {
	plaintext := "Top Secret"
	armored, _ := bridge_encrypt_vault_ciphertext_hex(plaintext, TEST_VAULT_KEY_HEX)
	defer delete(armored)

	wrong_key := "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
	decrypted, ok := bridge_decrypt_vault_ciphertext_hex(armored, wrong_key)
	defer if ok do delete(decrypted)
	testing.expect(t, !ok, "decryption with wrong key must fail")
}

@(test)
test_bridge_vault_decrypt_unarmored_fallback :: proc(t: ^testing.T) {
	raw := "Plain unarmored task title"
	decrypted, ok := bridge_decrypt_vault_ciphertext_hex(raw, TEST_VAULT_KEY_HEX)
	testing.expect(t, ok, "unarmored text must pass through")
	defer delete(decrypted)
	testing.expect_value(t, decrypted, raw)
}

@(test)
test_bridge_vault_embedded_decryption_suite :: proc(t: ^testing.T) {
	// HEIMDALL_VAULT_KEY is a PROCESS-GLOBAL. keystore_test_mutex alone does not
	// serialise this test against the ~29 env-mutating tests that hold
	// bridge_test_config_mutex instead - two disjoint locks exclude nobody, so those
	// two sets raced on one shared value (iss_18db48473fc5cb6d, 2026-10-04).
	// Taken OUTERMOST, before keystore_test_mutex: the acquisition graph stays acyclic.
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	os.set_env("HEIMDALL_VAULT_KEY", TEST_VAULT_KEY_HEX)
	defer os.unset_env("HEIMDALL_VAULT_KEY")

	// 1. Embedded vault tokens in notices
	{
		title_plaintext := "Implement Feature X"
		armored_title, _ := bridge_encrypt_vault_ciphertext_hex(title_plaintext, TEST_VAULT_KEY_HEX)
		defer delete(armored_title)

		comment_plaintext := "All tests green!"
		armored_comment, _ := bridge_encrypt_vault_ciphertext_hex(comment_plaintext, TEST_VAULT_KEY_HEX)
		defer delete(armored_comment)

		notice := strings.concatenate({`[Comment] @Alice commented on "`, armored_title, `" (task_42): "`, armored_comment, `"`})
		defer delete(notice)

		decrypted := bridge_decrypt_embedded_vault_tokens(notice)
		defer delete(decrypted)

		expected := `[Comment] @Alice commented on "Implement Feature X" (task_42): "All tests green!"`
		testing.expect_value(t, decrypted, expected)
	}

	// 2. Corrupted token fallback
	{
		corrupted := `[Review Requested] @coder submitted "vault:v1:invalid_base64_payload==" (task_1)`
		decrypted := bridge_decrypt_embedded_vault_tokens(corrupted)
		defer delete(decrypted)

		expected := `[Review Requested] @coder submitted "[Encrypted]" (task_1)`
		testing.expect_value(t, decrypted, expected)
	}

	// 3. Bootstrap header decryption & coordinator display name
	{
		chain_title := "Confidential Chain"
		armored_title, _ := bridge_encrypt_vault_ciphertext_hex(chain_title, TEST_VAULT_KEY_HEX)
		defer delete(armored_title)

		d := Bridge_Bootstrap_Descriptor{
			instance_id              = "inst_worker_1",
			agent_name               = "heimdall-engineer",
			role                     = "worker",
			chain_id                 = "chain_abc",
			chain_title              = armored_title,
			coordinator_id           = "inst_coord_1",
			coordinator_display_name = "Coordinator Agent #1",
		}

		header := bridge_bootstrap_render_header(d)
		defer delete(header)

		testing.expect(t, strings.contains(header, "Task chain: Confidential Chain (chain_abc)"), "header must have decrypted chain title")
	}
}

// REQ-T5-1: the machine-wide ~/.config/heimdall/vault_key is shared by every
// bridge of the OS user, so the bridge ignores it: it is neither a key source
// nor proof that the vault is configured, and nothing is migrated from it into
// this bridge's keyring entry.
@(test)
test_bridge_ignores_legacy_vault_key_file :: proc(t: ^testing.T) {
	// HEIMDALL_VAULT_KEY / HEIMDALL_VAULT_CONFIGURED and HOME are PROCESS-GLOBALS:
	// bridge_test_config_mutex OUTERMOST, then keystore_test_mutex
	// (iss_18db48473fc5cb6d, 2026-10-04).
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	id_a, _ := keystore_test_bridge_ids()
	prev_daemon_id := keystore_test_set_daemon_id(id_a)
	defer bridge_config.daemon_id = prev_daemon_id
	prev_flag := bridge_workspace_vault_configured
	defer bridge_workspace_vault_configured = prev_flag
	bridge_workspace_vault_configured = false

	keystore_set_mock_syscall_error(0)
	keystore_lock_and_purge(id_a)
	defer keystore_lock_and_purge(id_a)

	prev_key, had_key := os.lookup_env("HEIMDALL_VAULT_KEY", context.allocator)
	prev_configured, had_configured := os.lookup_env("HEIMDALL_VAULT_CONFIGURED", context.allocator)
	defer {
		if had_key {
			_ = os.set_env("HEIMDALL_VAULT_KEY", prev_key)
			delete(prev_key)
		} else {
			_ = os.unset_env("HEIMDALL_VAULT_KEY")
		}
		if had_configured {
			_ = os.set_env("HEIMDALL_VAULT_CONFIGURED", prev_configured)
			delete(prev_configured)
		} else {
			_ = os.unset_env("HEIMDALL_VAULT_CONFIGURED")
		}
	}
	os.unset_env("HEIMDALL_VAULT_KEY")
	os.unset_env("HEIMDALL_VAULT_CONFIGURED")

	// The sandbox redirects HOME and HEIMDALL_HOME, so the file written below lives
	// in a temp dir and the operator's real one is unreachable (iss_18db4d8f4b153b62).
	sb, sandbox_ok := bridge_vault_test_sandbox_open(t, "legacy_file_ignored")
	defer bridge_vault_test_sandbox_close(&sb)
	if !sandbox_ok do return

	// Only heap-allocated when expansion actually happened; see the note on the
	// guarded deletes in unseal_security_test.odin.
	key_rel := "~/.config/heimdall/vault_key"
	path := cfg_lib.expand_home(key_rel)
	defer if raw_data(path) != raw_data(key_rel) do delete(path)
	testing.expect(t, strings.has_prefix(path, sb.dir), "the legacy key path must resolve inside the sandbox")

	c_path := strings.clone_to_cstring(path)
	defer delete(c_path)
	fd := posix.open(c_path, posix.O_Flags{.CREAT, .WRONLY, .TRUNC}, posix.mode_t{.IRUSR, .IWUSR})
	testing.expect(t, fd >= 0, "writing the sandboxed legacy key file must succeed")
	if fd < 0 do return
	legacy_key: string = TEST_VAULT_KEY_HEX
	_ = posix.write(fd, raw_data(legacy_key), len(legacy_key))
	_ = posix.close(fd)

	key, ok := bridge_read_vault_key()
	if ok do delete(key)
	testing.expect(t, !ok, "a valid 0600 legacy key file must NOT be read by the bridge")

	persisted, migrated := keystore_read_keyring_vault_key(id_a)
	if migrated do delete(persisted)
	testing.expect(t, !migrated, "the legacy key file must NOT be migrated into this bridge's keyring entry")

	configured, _, key_length := bridge_vault_key_status()
	testing.expect(t, !configured, "vault.status must not report the legacy file as a configured key")
	testing.expect_value(t, key_length, 0)
	testing.expect(t, !bridge_vault_is_workspace_configured(), "the legacy file must not count as configured")
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Disabled)
}

@(test)
test_bridge_vault_tri_state_lifecycle :: proc(t: ^testing.T) {
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

	// bridge_vault_status() used to fall back to the operator's REAL
	// ~/.config/heimdall/vault_key and report Unlocked at step 2. The bridge no
	// longer reads that file (REQ-T5-1), but the sandbox stays so the per-bridge
	// vault_configured marker path is a temp dir too. Opened INSIDE
	// bridge_test_config_mutex, which is already held outermost above.
	sb, sandbox_ok := bridge_vault_test_sandbox_open(t, "tri_state")
	defer bridge_vault_test_sandbox_close(&sb)
	if !sandbox_ok do return

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

	// 1. When workspace vault is not configured -> Disabled
	bridge_workspace_vault_configured = false
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Disabled)
	testing.expect_value(t, bridge_vault_status_string(), "disabled")

	// 2. When workspace vault is configured but no key is present -> Locked
	bridge_workspace_vault_configured = true
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Locked)
	testing.expect_value(t, bridge_vault_status_string(), "locked")

	// 3. When unsealed / key is set -> Unlocked
	keystore_store_vault_key(id_a, TEST_VAULT_KEY_HEX)
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Unlocked)
	testing.expect_value(t, bridge_vault_status_string(), "unlocked")

	// 4. When bridge_vault_lock() is called -> key purged, returns to Locked
	bridge_vault_lock()
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Locked)
	testing.expect_value(t, bridge_vault_status_string(), "locked")

	// Reset
	bridge_workspace_vault_configured = false
}

@(test)
test_bridge_fs_rejects_when_vault_locked :: proc(t: ^testing.T) {
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

	// Same reason as test_bridge_vault_tri_state_lifecycle: the Locked assertion
	// below is only true if bridge_read_vault_key() cannot find a key on disk.
	sb, sandbox_ok := bridge_vault_test_sandbox_open(t, "fs_locked")
	defer bridge_vault_test_sandbox_close(&sb)
	if !sandbox_ok do return

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

	bridge_workspace_vault_configured = true
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Locked)

	// fs_management reject check
	read_res := bridge_fs_read_file("test.txt", "/tmp", 0, 100)
	testing.expect(t, !read_res.ok, "read_file must fail when locked")
	testing.expect_value(t, read_res.error_code, "vault_locked")

	write_res := bridge_fs_write_file("test.txt", "content", "/tmp")
	testing.expect(t, !write_res.ok, "write_file must fail when locked")
	testing.expect_value(t, write_res.error_code, "vault_locked")

	grep_res := bridge_fs_grep("pattern", false, 10, "/tmp")
	testing.expect(t, !grep_res.ok, "grep must fail when locked")
	testing.expect_value(t, grep_res.error_code, "vault_locked")

	bridge_workspace_vault_configured = false
}

// A bare 'vault:v1:' (prose mentioning the prefix) is kept verbatim, and with no
// vault key an opted-in caller gets the locked marker instead of raw ciphertext.
@(test)
test_bridge_vault_embedded_locked_marker_and_bare_prefix :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	armored, _ := bridge_encrypt_vault_ciphertext_hex("Secret", TEST_VAULT_KEY_HEX)
	defer delete(armored)
	text := strings.concatenate({"prefix `vault:v1:` then ", armored, "."})
	defer delete(text)

	os.set_env("HEIMDALL_VAULT_KEY", TEST_VAULT_KEY_HEX)
	{
		got := bridge_decrypt_embedded_vault_tokens(text, locked_marker = VAULT_LOCKED_MARKER)
		defer delete(got)
		testing.expect_value(t, got, "prefix `vault:v1:` then Secret.")
	}

	// An explicitly invalid HEIMDALL_VAULT_KEY makes bridge_read_vault_key fail
	// without falling through to the keyring, so no key is available.
	os.set_env("HEIMDALL_VAULT_KEY", "not-a-key")
	defer os.unset_env("HEIMDALL_VAULT_KEY")
	{
		got := bridge_decrypt_embedded_vault_tokens(text, locked_marker = VAULT_LOCKED_MARKER)
		defer delete(got)
		testing.expect_value(t, got, strings.concatenate({"prefix `vault:v1:` then ", VAULT_LOCKED_MARKER, "."}, context.temp_allocator))
	}
	{
		got := bridge_decrypt_embedded_vault_tokens(text)
		defer delete(got)
		testing.expect_value(t, got, text)
	}
}

@(private = "file")
frame_carries_legal_vault_status :: proc(frame: string) -> bool {
	return strings.contains(frame, "\"vault_status\":\"unlocked\"") ||
	       strings.contains(frame, "\"vault_status\":\"locked\"") ||
	       strings.contains(frame, "\"vault_status\":\"disabled\"")
}

@(test)
heartbeat_frame_carries_vault_status :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	frame := bridge_hub_heartbeat_json()
	defer delete(frame)

	testing.expect(t, strings.contains(frame, "\"type\":\"bridge_heartbeat\""), "frame is still a bridge_heartbeat")
	testing.expect(t, strings.contains(frame, "\"vault_status\":\""), "heartbeat carries a vault_status field")
	testing.expect(t, frame_carries_legal_vault_status(frame), "heartbeat vault_status is one of unlocked|locked|disabled")

	testing.expect(t, strings.contains(frame, "\"protocol_version\":1"), "protocol_version intact")
	testing.expect(t, strings.contains(frame, "\"capabilities\":"), "capabilities intact — the hub's heartbeat arm keys off this")
	testing.expect(t, strings.contains(frame, "\"features\":"), "features intact")
	testing.expect(t, strings.contains(frame, "\"active_instance_ids\":["), "active_instance_ids intact")
	testing.expect(t, strings.contains(frame, "\"instances\":["), "instances intact")
}

@(test)
vault_status_report_frame_is_its_own_type :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	frame := bridge_vault_status_report_json()
	defer delete(frame)

	testing.expect(t, strings.contains(frame, "\"type\":\"bridge_vault_status\""), "report has its own frame type")
	testing.expect(t, strings.contains(frame, "\"protocol_version\":1"), "report carries protocol_version")
	testing.expect(t, frame_carries_legal_vault_status(frame), "report vault_status is one of unlocked|locked|disabled")

	testing.expect(t, !strings.contains(frame, "\"type\":\"bridge_heartbeat\""), "report is not a synthetic heartbeat")
	testing.expect(t, !strings.contains(frame, "\"active_instance_ids\""), "report carries no instance digest")
	testing.expect(t, !strings.contains(frame, "\"instances\""), "report carries no instance list")
}

@(test)
vault_status_report_agrees_with_bridge_vault_status :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	expected := bridge_vault_status_string()
	frame := bridge_vault_status_report_json()
	defer delete(frame)

	needle := strings.concatenate({"\"vault_status\":\"", expected, "\""})
	defer delete(needle)
	testing.expect(t, strings.contains(frame, needle), "the frame reports exactly what bridge_vault_status_string() returns")
}
