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

@(test)
test_bridge_taskv2_render_task_md_vault_decryption_and_field_safe_cap :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	os.set_env("HEIMDALL_VAULT_KEY", TEST_VAULT_KEY_HEX)
	defer os.unset_env("HEIMDALL_VAULT_KEY")

	armored_title, _ := bridge_encrypt_vault_ciphertext_hex("Secret Feature Task", TEST_VAULT_KEY_HEX)
	defer delete(armored_title)
	// Also test ENC:v1: prefix
	enc_goal_vault, _ := bridge_encrypt_vault_ciphertext_hex("Deliver decrypted goal", TEST_VAULT_KEY_HEX)
	defer delete(enc_goal_vault)
	enc_goal := strings.concatenate({"ENC:v1:", enc_goal_vault[len(VAULT_ARMOR_PREFIX):]})
	defer delete(enc_goal)

	pack := strings.concatenate({
		`{"version":1,"lease_id":"lease_1","task_id":"task_1","attempt_no":2,"max_attempts":3,"review_rounds":1,`,
		`"expires_at":"2026-10-16T18:00:00Z","hard_deadline_at":"2026-10-16T20:00:00Z","why":"changes_requested",`,
		`"placement":{"bridge_id":"br_1","directory_id":"dir_1","provider":"claude","model":"sonnet"},`,
		`"task":{"task_id":"task_1","title":"`, armored_title, `","description":"desc"},`,
		`"brief":{"goal":"`, enc_goal, `","acceptance":["acc 1"],"verify":"npm test"},`,
		`"chain":{"chain_id":"ch_1","title":"Chain","summary":"# Chain ch_1\n- [x] task_0: done"},`,
		`"inputs":[{"ref":"#ev_1","resolved":true,"data":"LARGE_INPUT_BODY_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}],`,
		`"where_you_are":{"head":"abc1234","dirty":false,"files":[]},`,
		`"previous_attempt":{"attempt_no":1,"outcome":"changes_requested","last_heartbeat_note":"hb note",`,
		`"handoff":{"summary":"PREV_HANDOFF_SUMMARY_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB","dead_ends":["NEVER_DROP_DEAD_END_1"]},`,
		`"verify":{"cmd":"npm test","exit_code":0,"head":"abc1234","tail":"PREV_VERIFY_TAIL_CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"}},`,
		`"findings":[{"path":"src/a.odin","line":42,"severity":"blocker","text":"NEVER_DROP_FINDING_1"}],`,
		`"protocol":{"rules":["1. Rule one"]}}`,
	})
	defer delete(pack)

	// 1. Uncapped render decrypts both vault:v1: and ENC:v1: and includes all fields
	full_md := bridge_taskv2_render_task_md(pack, 32_000)
	defer delete(full_md)
	testing.expect(t, strings.contains(full_md, "# Task task_1: Secret Feature Task (worker, attempt #2)"), "decrypted title in header")
	testing.expect(t, strings.contains(full_md, "**Goal**: Deliver decrypted goal"), "decrypted ENC:v1: goal in brief")
	testing.expect(t, strings.contains(full_md, "LARGE_INPUT_BODY_"), "uncapped includes resolved input body")
	testing.expect(t, strings.contains(full_md, "PREV_VERIFY_TAIL_"), "uncapped includes verify tail")
	testing.expect(t, strings.contains(full_md, "PREV_HANDOFF_SUMMARY_"), "uncapped includes handoff summary")
	testing.expect(t, strings.contains(full_md, "NEVER_DROP_DEAD_END_1"), "dead_ends present")
	testing.expect(t, strings.contains(full_md, "NEVER_DROP_FINDING_1"), "findings present")

	// 2. Step-by-step field-safe cap verification:
	// Step 1: budget drops resolved input body first, while preserving verify tail AND handoff summary
	step1_budget := len(full_md) - 10
	step1_md := bridge_taskv2_render_task_md(pack, step1_budget)
	defer delete(step1_md)
	testing.expect(t, !strings.contains(step1_md, "LARGE_INPUT_BODY_"), "step 1: resolved input body dropped first")
	testing.expect(t, strings.contains(step1_md, "ham-ctl task fetch task_1 #ev_1"), "step 1: replaced with fetch pointer for input")
	testing.expect(t, strings.contains(step1_md, "PREV_VERIFY_TAIL_"), "step 1: verify tail still preserved")
	testing.expect(t, strings.contains(step1_md, "PREV_HANDOFF_SUMMARY_"), "step 1: handoff summary still preserved")

	// Step 2: tighter budget drops inputs + verify tail, while preserving handoff summary
	step2_budget := len(step1_md) - 10
	step2_md := bridge_taskv2_render_task_md(pack, step2_budget)
	defer delete(step2_md)
	testing.expect(t, !strings.contains(step2_md, "LARGE_INPUT_BODY_"), "step 2: input body dropped")
	testing.expect(t, !strings.contains(step2_md, "PREV_VERIFY_TAIL_"), "step 2: verify tail dropped second")
	testing.expect(t, strings.contains(step2_md, "ham-ctl task fetch task_1 facet:task_1:1:verify"), "step 2: replaced with fetch pointer for verify")
	testing.expect(t, strings.contains(step2_md, "PREV_HANDOFF_SUMMARY_"), "step 2: handoff summary still preserved")

	// Step 3: tightest budget drops inputs + verify tail + handoff summary, while keeping brief, dead_ends, findings
	capped_md := bridge_taskv2_render_task_md(pack, 600)
	defer delete(capped_md)
	testing.expect(t, !strings.contains(capped_md, "LARGE_INPUT_BODY_"), "step 3: resolved input body dropped")
	testing.expect(t, strings.contains(capped_md, "ham-ctl task fetch task_1 #ev_1"), "step 3: replaced with fetch pointer for input")
	testing.expect(t, !strings.contains(capped_md, "PREV_VERIFY_TAIL_"), "step 3: verify tail dropped")
	testing.expect(t, strings.contains(capped_md, "ham-ctl task fetch task_1 facet:task_1:1:verify"), "step 3: replaced with fetch pointer for verify")
	testing.expect(t, !strings.contains(capped_md, "PREV_HANDOFF_SUMMARY_"), "step 3: handoff summary dropped third")
	testing.expect(t, strings.contains(capped_md, "ham-ctl task fetch task_1 facet:task_1:1:handoff"), "step 3: replaced with fetch pointer for handoff")
	testing.expect(t, strings.contains(capped_md, "**Goal**: Deliver decrypted goal"), "brief goal preserved under cap")
	testing.expect(t, strings.contains(capped_md, "NEVER_DROP_DEAD_END_1"), "dead_ends preserved under cap")
	testing.expect(t, strings.contains(capped_md, "NEVER_DROP_FINDING_1"), "open findings preserved under cap")

	// 3. Materialise <run_dir>/TASK.md on disk and verify file contents
	home := os.get_env("HOME", context.temp_allocator)
	run_dir := strings.concatenate({home, "/.cache/heimdall-tests/task-md-unit-test"}, context.temp_allocator)
	_ = os.make_directory(run_dir)
	task_md_path := strings.concatenate({run_dir, "/TASK.md"}, context.temp_allocator)
	defer _ = os.remove(task_md_path)
	defer _ = os.remove(run_dir)
	wrote := bridge_taskv2_materialize_task_md(run_dir, pack)
	testing.expect(t, wrote, "bridge_taskv2_materialize_task_md wrote <run_dir>/TASK.md")
	disk_bytes, rerr := os.read_entire_file(task_md_path, context.temp_allocator)
	testing.expect(t, rerr == nil && strings.contains(string(disk_bytes), "# Task task_1: Secret Feature Task (worker, attempt #2)"), "TASK.md on disk contains decrypted header")
	testing.expect(t, rerr == nil && strings.contains(string(disk_bytes), "**Goal**: Deliver decrypted goal"), "TASK.md on disk contains decrypted ENC:v1: goal")
}

@(test)
test_bridge_agent_route_m3_chain_summary_and_propose :: proc(t: ^testing.T) {
	r1 := bridge_agent_route("agent.task_chain.set_summary", `{"body":"# Summary"}`)
	testing.expect_value(t, r1.kind, Bridge_Agent_Route_Kind.Envelope)
	testing.expect_value(t, r1.path, "/api/v1/agent-actions/chain/summary")
	testing.expect(t, bridge_agent_method_allowed("agent.task_chain.set_summary"), "set_summary allowed")

	r2 := bridge_agent_route("agent.task_chain.propose", `{"tasks":[]}`)
	testing.expect_value(t, r2.kind, Bridge_Agent_Route_Kind.Envelope)
	testing.expect_value(t, r2.path, "/api/v1/agent-actions/chain/propose")
	testing.expect(t, bridge_agent_method_allowed("agent.task_chain.propose"), "propose allowed")
}

