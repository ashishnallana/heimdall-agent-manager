package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

// ── REQ-VAULT-TASKS-1 CLI Unit Tests ─────────────────────────────────────────

TEST_TASK_VAULT_KEY :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
ALT_TASK_VAULT_KEY  :: "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"

@(test)
test_task_user_approval_flags_serialize :: proc(t: ^testing.T) {
	created := ctl_agentmode_task_create_params([]string{"--title", "Review me", "--require-user-approval"})
	defer delete(created)
	testing.expect(t, strings.contains(created, `"requires_user_approval":true`), "create must serialize the positive flag")
	updated := ctl_agentmode_task_update_params("task_1", []string{"--no-require-user-approval"})
	defer delete(updated)
	testing.expect(t, strings.contains(updated, `"requires_user_approval":false`), "update must serialize the negative flag")
	testing.expect(t, !ctl_task_reviewer_flags_valid([]string{"--require-user-approval", "--no-require-user-approval"}, true), "conflicting flags must fail")
	testing.expect(t, !ctl_task_reviewer_flags_valid([]string{"--reviewer", "user"}, true), "legacy user reviewer alias must fail")
	testing.expect(t, ctl_task_reviewer_flags_valid([]string{"--reviewer", "reviewer@chain"}, true), "agent reviewer IDs containing @ must remain valid")
}

@(test)
test_task_create_encryption_with_vault_key :: proc(t: ^testing.T) {
	orig_title := "Deploy Zero-Knowledge User Vault Secrets Engine"
	orig_desc := "Configure cloud hardware security module and distribute master keys."

	args := []string{
		"--title", orig_title,
		"--description", orig_desc,
		"--chain", "chain_vault_001",
		"--priority", "p1",
		"--assignee", "agt_worker_1",
		"--reviewer", "agt_reviewer_1,agt_reviewer_2",
		"--depends-on", "task_dep_alpha",
		"--vault-key", TEST_TASK_VAULT_KEY,
	}

	out := ctl_agentmode_task_create_params(args)

	// Check metadata and workflow fields are preserved in plaintext
	testing.expect(t, strings.contains(out, `"chain_id":"chain_vault_001"`), "chain_id must be plaintext")
	testing.expect(t, strings.contains(out, `"priority":"p1"`), "priority must be plaintext")
	testing.expect(t, strings.contains(out, `"assignee":"agt_worker_1"`), "assignee must be preserved (v2 plain agent_id)")
	testing.expect(t, strings.contains(out, `"reviewers":["agt_reviewer_1","agt_reviewer_2"]`), "reviewers must be preserved (v2 agent_id array)")
	testing.expect(t, strings.contains(out, `"depends_on":["task_dep_alpha"]`), "depends_on must be preserved")

	// Title must be encrypted
	testing.expect(t, !strings.contains(out, orig_title), "title must not leak plaintext")
	testing.expect(t, strings.contains(out, `"title":"vault:v1:`), "title must be armored with vault:v1:")

	// Description must be encrypted
	testing.expect(t, !strings.contains(out, orig_desc), "description must not leak plaintext")
	testing.expect(t, strings.contains(out, `"description":"vault:v1:`), "description must be armored with vault:v1:")

	// Parse JSON to extract encrypted fields and test round-trip decryption
	val, err := json.parse_string(out, parse_integers = true, allocator = context.temp_allocator)
	testing.expect(t, err == .None, "emitted params must be valid JSON")
	obj := val.(json.Object)

	enc_title := string(obj["title"].(json.String))
	dec_title, dt_ok := vault_decrypt_text_hex(enc_title, TEST_TASK_VAULT_KEY, context.temp_allocator)
	testing.expect(t, dt_ok, "title must decrypt successfully")
	testing.expect_value(t, dec_title, orig_title)

	enc_desc := string(obj["description"].(json.String))
	dec_desc, dd_ok := vault_decrypt_text_hex(enc_desc, TEST_TASK_VAULT_KEY, context.temp_allocator)
	testing.expect(t, dd_ok, "description must decrypt successfully")
	testing.expect_value(t, dec_desc, orig_desc)
}

@(test)
test_task_create_without_vault_key_leaves_plaintext :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("task-create-without-vault-key-leaves-plaintext")
	defer ctl_vault_test_sandbox_close(&sb)
	orig_title := "Plaintext Task Title"
	orig_desc := "Plaintext Task Description"

	args := []string{
		"--title", orig_title,
		"--description", orig_desc,
		"--chain", "chain_123",
		"--priority", "p2",
	}

	out := ctl_agentmode_task_create_params(args)
	testing.expect(t, strings.contains(out, `"title":"Plaintext Task Title"`), "title must remain plaintext")
	testing.expect(t, strings.contains(out, `"description":"Plaintext Task Description"`), "description must remain plaintext")
	testing.expect(t, !strings.contains(out, "vault:v1:"), "must not contain vault armor")
}

@(test)
test_task_comment_encryption_with_vault_key :: proc(t: ^testing.T) {
	orig_body := "Investigated root cause: private key rotation failed on node 4. Remediation in progress."

	args := []string{
		"--notify", "agt_lead,agt_worker_2",
		"--vault-key", TEST_TASK_VAULT_KEY,
	}

	out := ctl_agentmode_task_comment_params("task_abc_1", orig_body, args)

	testing.expect(t, strings.contains(out, `"task_id":"task_abc_1"`), "task_id must remain plaintext")
	testing.expect(t, strings.contains(out, `"notify":["agt_lead","agt_worker_2"]`), "notify must remain plaintext")

	testing.expect(t, !strings.contains(out, orig_body), "comment body must not leak plaintext")
	testing.expect(t, strings.contains(out, `"body":"vault:v1:`), "comment body must be armored with vault:v1:")

	val, err := json.parse_string(out, parse_integers = true, allocator = context.temp_allocator)
	testing.expect(t, err == .None, "emitted params must be valid JSON")
	obj := val.(json.Object)

	enc_body := string(obj["body"].(json.String))
	dec_body, db_ok := vault_decrypt_text_hex(enc_body, TEST_TASK_VAULT_KEY, context.temp_allocator)
	testing.expect(t, db_ok, "comment body must decrypt successfully")
	testing.expect_value(t, dec_body, orig_body)
}

@(test)
test_task_comment_without_vault_key_leaves_plaintext :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("task-comment-without-vault-key-leaves-plaintext")
	defer ctl_vault_test_sandbox_close(&sb)
	orig_body := "Regular plaintext comment body with no vault key."
	args := []string{}

	out := ctl_agentmode_task_comment_params("task_xyz_2", orig_body, args)
	testing.expect(t, strings.contains(out, `"body":"Regular plaintext comment body with no vault key."`), "body must remain plaintext")
	testing.expect(t, !strings.contains(out, "vault:v1:"), "must not contain vault armor")
}

@(test)
test_task_update_encryption_with_vault_key :: proc(t: ^testing.T) {
	orig_title := "Updated Secret Task Title"
	orig_desc := "Updated Secret Task Description with confidential rollout steps."

	args := []string{
		"--title", orig_title,
		"--description", orig_desc,
		"--priority", "p0",
		"--vault-key", TEST_TASK_VAULT_KEY,
	}

	out := ctl_agentmode_task_update_params("task_upd_3", args)

	testing.expect(t, strings.contains(out, `"task_id":"task_upd_3"`), "task_id must remain plaintext")
	testing.expect(t, strings.contains(out, `"priority":"p0"`), "priority must remain plaintext")
	testing.expect(t, !strings.contains(out, orig_title), "title must not leak plaintext")
	testing.expect(t, !strings.contains(out, orig_desc), "description must not leak plaintext")
	testing.expect(t, strings.contains(out, `"title":"vault:v1:`), "title must be armored")
	testing.expect(t, strings.contains(out, `"description":"vault:v1:`), "description must be armored")

	val, err := json.parse_string(out, parse_integers = true, allocator = context.temp_allocator)
	testing.expect(t, err == .None, "emitted params must be valid JSON")
	obj := val.(json.Object)

	enc_title := string(obj["title"].(json.String))
	dec_title, dt_ok := vault_decrypt_text_hex(enc_title, TEST_TASK_VAULT_KEY, context.temp_allocator)
	testing.expect(t, dt_ok, "title must decrypt successfully")
	testing.expect_value(t, dec_title, orig_title)

	enc_desc := string(obj["description"].(json.String))
	dec_desc, dd_ok := vault_decrypt_text_hex(enc_desc, TEST_TASK_VAULT_KEY, context.temp_allocator)
	testing.expect(t, dd_ok, "description must decrypt successfully")
	testing.expect_value(t, dec_desc, orig_desc)
}

@(test)
test_task_show_and_list_transparent_decryption :: proc(t: ^testing.T) {
	orig_title := "Confidential Microservice Migration"
	orig_desc := "Migrate payment authentication subsystem to zero-trust architecture."
	orig_preview := "Last comment: migration stage 1 completed smoothly."

	enc_title, _ := vault_encrypt_text_hex(orig_title, TEST_TASK_VAULT_KEY, context.temp_allocator)
	enc_desc, _ := vault_encrypt_text_hex(orig_desc, TEST_TASK_VAULT_KEY, context.temp_allocator)
	enc_preview, _ := vault_encrypt_text_hex(orig_preview, TEST_TASK_VAULT_KEY, context.temp_allocator)

	raw_json := fmt.tprintf(
		`{{"v":1,"ok":true,"data":{{"data":{{"task_id":"task_test_show_1","title":"%s","description":"%s","priority":"p1","state":"in_progress","comment_summary":{{"count":3,"last_comment_preview":"%s"}}}}}}}}`,
		enc_title, enc_desc, enc_preview,
	)

	decrypted := ctl_decrypt_json_string(raw_json, TEST_TASK_VAULT_KEY, true, context.temp_allocator)
	testing.expect(t, strings.contains(decrypted, orig_title), "decrypted json must contain original title")
	testing.expect(t, strings.contains(decrypted, orig_desc), "decrypted json must contain original description")
	testing.expect(t, strings.contains(decrypted, orig_preview), "decrypted json must contain original comment preview")
	testing.expect(t, strings.contains(decrypted, `"priority":"p1"`), "priority must be preserved")
	testing.expect(t, !strings.contains(decrypted, "vault:v1:"), "decrypted json must not contain vault armor")
}

@(test)
test_task_comments_list_transparent_decryption :: proc(t: ^testing.T) {
	orig_body_1 := "Detailed review: cryptographic primitives align with FIPS 140-3."
	orig_body_2 := "Second review comment: all unit tests passing with zero regressions."

	enc_body_1, _ := vault_encrypt_text_hex(orig_body_1, TEST_TASK_VAULT_KEY, context.temp_allocator)
	enc_body_2, _ := vault_encrypt_text_hex(orig_body_2, TEST_TASK_VAULT_KEY, context.temp_allocator)

	raw_json := fmt.tprintf(
		`{{"v":1,"ok":true,"data":[{{"comment_id":"cmt_1","task_id":"task_1","body":"%s"}},{{"comment_id":"cmt_2","task_id":"task_1","body":"%s"}}]}}`,
		enc_body_1, enc_body_2,
	)

	decrypted := ctl_decrypt_json_string(raw_json, TEST_TASK_VAULT_KEY, true, context.temp_allocator)
	testing.expect(t, strings.contains(decrypted, orig_body_1), "decrypted comments must contain first body")
	testing.expect(t, strings.contains(decrypted, orig_body_2), "decrypted comments must contain second body")
	testing.expect(t, !strings.contains(decrypted, "vault:v1:"), "decrypted comments must not contain vault armor")
}

@(test)
test_task_unconfigured_fallback :: proc(t: ^testing.T) {
	orig_title := "Secret High-Priority Objective"
	enc_title, _ := vault_encrypt_text_hex(orig_title, TEST_TASK_VAULT_KEY, context.temp_allocator)

	raw_json := fmt.tprintf(
		`{{"v":1,"ok":true,"data":{{"task_id":"task_unconfigured","title":"%s","state":"backlog"}}}}`,
		enc_title,
	)

	// Key not configured -> fallback [Encrypted: vault:v1:...]
	decrypted := ctl_decrypt_json_string(raw_json, "", false, context.temp_allocator)
	testing.expect(t, !strings.contains(decrypted, orig_title), "must not leak plaintext without key")
	expected_fallback := fmt.tprintf(`[Encrypted: %s]`, enc_title)
	testing.expect(t, strings.contains(decrypted, expected_fallback), "must contain [Encrypted: vault:v1:...] fallback")
	testing.expect(t, strings.contains(decrypted, `"state":"backlog"`), "unencrypted fields remain intact")
}

@(test)
test_task_wrong_key_fallback :: proc(t: ^testing.T) {
	orig_title := "Top Secret Task"
	enc_title, _ := vault_encrypt_text_hex(orig_title, TEST_TASK_VAULT_KEY, context.temp_allocator)

	raw_json := fmt.tprintf(
		`{{"v":1,"ok":true,"data":{{"task_id":"task_wrong_key","title":"%s"}}}}`,
		enc_title,
	)

	// Wrong key -> fallback
	decrypted := ctl_decrypt_json_string(raw_json, ALT_TASK_VAULT_KEY, true, context.temp_allocator)
	testing.expect(t, !strings.contains(decrypted, orig_title), "must not decrypt with wrong key")
	expected_fallback := fmt.tprintf(`[Encrypted: %s]`, enc_title)
	testing.expect(t, strings.contains(decrypted, expected_fallback), "must contain fallback on decryption failure")
}

@(test)
test_legacy_plaintext_tasks_unaltered :: proc(t: ^testing.T) {
	raw_json := `{"v":1,"ok":true,"data":{"task_id":"task_legacy","title":"Legacy Plain Title","description":"Legacy Plain Description","priority":"p2"}}`
	decrypted := ctl_decrypt_json_string(raw_json, TEST_TASK_VAULT_KEY, true, context.temp_allocator)
	testing.expect(t, strings.contains(decrypted, `"title":"Legacy Plain Title"`), "title preserved")
	testing.expect(t, strings.contains(decrypted, `"description":"Legacy Plain Description"`), "description preserved")
	testing.expect(t, strings.contains(decrypted, `"priority":"p2"`), "priority preserved")
}

@(test)
test_task_create_and_update_bridge_pinning_params :: proc(t: ^testing.T) {
	// 1. Task create with --bridge
	create_args_with_bridge := []string{
		"--title", "Pinned task",
		"--bridge", "brg_18d03379a7d6d47b",
	}
	out_create := ctl_agentmode_task_create_params(create_args_with_bridge)
	testing.expect(t, strings.contains(out_create, `"bridge_id":"brg_18d03379a7d6d47b"`), "create params must serialize bridge_id when --bridge provided")

	// 2. Task create without --bridge
	create_args_no_bridge := []string{
		"--title", "Unpinned task",
	}
	out_create_no_bridge := ctl_agentmode_task_create_params(create_args_no_bridge)
	testing.expect(t, !strings.contains(out_create_no_bridge, `"bridge_id"`), "create params must omit bridge_id when --bridge absent")

	// 3. Task update with --bridge
	update_args_with_bridge := []string{
		"--bridge", "brg_18c67a924477af3b",
	}
	out_update_bridge := ctl_agentmode_task_update_params("task_123", update_args_with_bridge)
	testing.expect(t, strings.contains(out_update_bridge, `"bridge_id":"brg_18c67a924477af3b"`), "update params must serialize bridge_id when --bridge provided")

	// 4. Task update clearing bridge with ""
	update_args_clear_bridge := []string{
		"--bridge", "",
	}
	out_update_clear := ctl_agentmode_task_update_params("task_123", update_args_clear_bridge)
	testing.expect(t, strings.contains(out_update_clear, `"bridge_id":""`), "update params must serialize bridge_id=\"\" when --bridge \"\" provided")

	// 5. Task update without --bridge
	update_args_no_bridge := []string{
		"--title", "Updated title only",
	}
	out_update_no_bridge := ctl_agentmode_task_update_params("task_123", update_args_no_bridge)
	testing.expect(t, !strings.contains(out_update_no_bridge, `"bridge_id"`), "update params must omit bridge_id when --bridge absent")
}
