package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

// ── REQ-VAULT-CHAT-1 CLI Unit Tests ──────────────────────────────────────────

TEST_CHAT_VAULT_KEY :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
ALT_CHAT_VAULT_KEY  :: "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"

@(test)
test_chat_send_encryption_with_vault_key :: proc(t: ^testing.T) {
	orig_to := "inst_coordinator_1"
	orig_body := "Confidential coordination message: all cryptographic primitives operational."

	args := []string{
		"--vault-keyring", tkr_b64(TEST_CHAT_VAULT_KEY),
	}

	out := ctl_agentmode_chat_send_params(orig_to, orig_body, args)

	testing.expect(t, strings.contains(out, `"to":"inst_coordinator_1"`), "to must be preserved in plaintext")
	testing.expect(t, !strings.contains(out, orig_body), "chat body must not leak plaintext")
	testing.expect(t, strings.contains(out, `"body":"vault:v2:`), "chat body must be armored with vault:v2:")

	val, err := json.parse_string(out, parse_integers = true, allocator = context.temp_allocator)
	testing.expect(t, err == .None, "emitted params must be valid JSON")
	obj := val.(json.Object)

	enc_body := string(obj["body"].(json.String))
	dec_body, db_ok := vault_decrypt_text_hex(enc_body, TEST_CHAT_VAULT_KEY, context.temp_allocator)
	testing.expect(t, db_ok, "body must decrypt successfully")
	testing.expect_value(t, dec_body, orig_body)
}

@(test)
test_chat_send_without_vault_key_leaves_plaintext :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("chat-send-without-vault-key-leaves-plaintext")
	defer ctl_vault_test_sandbox_close(&sb)
	orig_to := "user"
	orig_body := "Standard unencrypted status update."

	args := []string{}

	out := ctl_agentmode_chat_send_params(orig_to, orig_body, args)

	testing.expect(t, strings.contains(out, `"to":"user"`), "to must be preserved in plaintext")
	testing.expect(t, strings.contains(out, `"body":"Standard unencrypted status update."`), "chat body must remain plaintext")
	testing.expect(t, !strings.contains(out, "vault:v2:"), "output must not contain vault armor")
}

@(test)
test_chat_set_title_encryption_with_vault_key :: proc(t: ^testing.T) {
	orig_title := "Zero-Knowledge Vault Operations Thread"

	args := []string{
		"--vault-keyring", tkr_b64(TEST_CHAT_VAULT_KEY),
	}

	out := ctl_agentmode_chat_set_title_params(orig_title, args)

	testing.expect(t, !strings.contains(out, orig_title), "title must not leak plaintext")
	testing.expect(t, strings.contains(out, `"title":"vault:v2:`), "title must be armored with vault:v2:")

	val, err := json.parse_string(out, parse_integers = true, allocator = context.temp_allocator)
	testing.expect(t, err == .None, "emitted params must be valid JSON")
	obj := val.(json.Object)

	enc_title := string(obj["title"].(json.String))
	dec_title, dt_ok := vault_decrypt_text_hex(enc_title, TEST_CHAT_VAULT_KEY, context.temp_allocator)
	testing.expect(t, dt_ok, "title must decrypt successfully")
	testing.expect_value(t, dec_title, orig_title)
}

@(test)
test_chat_set_title_without_vault_key_leaves_plaintext :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("chat-set-title-without-vault-key-leaves-plaintext")
	defer ctl_vault_test_sandbox_close(&sb)
	orig_title := "Standard Conversation Title"

	args := []string{}

	out := ctl_agentmode_chat_set_title_params(orig_title, args)

	testing.expect(t, strings.contains(out, `"title":"Standard Conversation Title"`), "title must remain plaintext")
	testing.expect(t, !strings.contains(out, "vault:v2:"), "output must not contain vault armor")
}

@(test)
test_chat_read_transparent_decryption :: proc(t: ^testing.T) {
	orig_msg_1 := "Message one: initial vault bootstrap."
	orig_msg_2 := "Message two: operational key distribution."
	orig_title := "Encrypted Operations Thread"
	orig_preview := "Preview: initial vault bootstrap."

	enc_msg_1, _ := vault_encrypt_text_hex(orig_msg_1, TEST_CHAT_VAULT_KEY, context.temp_allocator)
	enc_msg_2, _ := vault_encrypt_text_hex(orig_msg_2, TEST_CHAT_VAULT_KEY, context.temp_allocator)
	enc_title, _ := vault_encrypt_text_hex(orig_title, TEST_CHAT_VAULT_KEY, context.temp_allocator)
	enc_preview, _ := vault_encrypt_text_hex(orig_preview, TEST_CHAT_VAULT_KEY, context.temp_allocator)

	raw_json := fmt.tprintf(
		`{{"v":1,"ok":true,"data":{{"conversation":{{"title":"%s","last_message_preview":"%s"}},"messages":[{{"id":"msg_1","body":"%s"}},{{"id":"msg_2","body":"%s"}}]}}}}`,
		enc_title, enc_preview, enc_msg_1, enc_msg_2,
	)

	decrypted := ctl_decrypt_json_string(raw_json, tkr(TEST_CHAT_VAULT_KEY), true, context.temp_allocator)

	testing.expect(t, strings.contains(decrypted, orig_msg_1), "decrypted json must contain msg 1")
	testing.expect(t, strings.contains(decrypted, orig_msg_2), "decrypted json must contain msg 2")
	testing.expect(t, strings.contains(decrypted, orig_title), "decrypted json must contain title")
	testing.expect(t, strings.contains(decrypted, orig_preview), "decrypted json must contain preview")
	testing.expect(t, !strings.contains(decrypted, "vault:v2:"), "decrypted json must not contain vault armor")
}

@(test)
test_chat_read_fallback_when_vault_locked :: proc(t: ^testing.T) {
	orig_msg := "Secret confidential directive."
	enc_msg, _ := vault_encrypt_text_hex(orig_msg, TEST_CHAT_VAULT_KEY, context.temp_allocator)

	raw_json := fmt.tprintf(
		`{{"v":1,"ok":true,"data":{{"messages":[{{"id":"msg_1","body":"%s"}}]}}}}`,
		enc_msg,
	)

	// Vault key not configured (key_ok = false)
	fallback := ctl_decrypt_json_string(raw_json, nil, false, context.temp_allocator)

	testing.expect(t, !strings.contains(fallback, orig_msg), "must not leak plaintext when locked")
	testing.expect(t, strings.contains(fallback, "[Encrypted: vault:v2:"), "must wrap armored body in [Encrypted: vault:v2:...]")
}

@(test)
test_chat_read_unarmored_legacy_messages_pass_through :: proc(t: ^testing.T) {
	legacy_msg := "Legacy unarmored message from before vault encryption."
	raw_json := fmt.tprintf(
		`{{"v":1,"ok":true,"data":{{"messages":[{{"id":"msg_legacy","body":"%s"}}]}}}}`,
		legacy_msg,
	)

	res := ctl_decrypt_json_string(raw_json, tkr(TEST_CHAT_VAULT_KEY), true, context.temp_allocator)
	testing.expect(t, strings.contains(res, legacy_msg), "legacy plaintext message must pass through unaltered")
}

@(test)
test_chat_read_wrong_key_fallback :: proc(t: ^testing.T) {
	orig_msg := "Protected message."
	enc_msg, _ := vault_encrypt_text_hex(orig_msg, TEST_CHAT_VAULT_KEY, context.temp_allocator)

	raw_json := fmt.tprintf(
		`{{"v":1,"ok":true,"data":{{"messages":[{{"id":"msg_1","body":"%s"}}]}}}}`,
		enc_msg,
	)

	// Decrypt with wrong key
	fallback := ctl_decrypt_json_string(raw_json, tkr(ALT_CHAT_VAULT_KEY), true, context.temp_allocator)
	testing.expect(t, !strings.contains(fallback, orig_msg), "must not leak plaintext with wrong key")
	testing.expect(t, strings.contains(fallback, "[Encrypted: vault:v2:"), "must provide fallback on wrong key")
}

@(test)
test_chat_send_with_comma_separated_options :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("chat-send-comma-separated-options")
	defer ctl_vault_test_sandbox_close(&sb)

	orig_to := "user"
	orig_body := "Please choose one of the available deployments."
	args := []string{
		"--options", "Staging,Production,Canary",
	}

	out := ctl_agentmode_chat_send_params(orig_to, orig_body, args)

	testing.expect(t, strings.contains(out, `"to":"user"`), "to must be user")
	testing.expect(t, strings.contains(out, orig_body), "body must be preserved")
	testing.expect(t, strings.contains(out, `"options":["Staging","Production","Canary"]`), "options array must match comma-separated input")

	val, err := json.parse_string(out, allocator = context.temp_allocator)
	testing.expect(t, err == .None, "params must be valid JSON")
	obj := val.(json.Object)
	opts := obj["options"].(json.Array)
	testing.expect_value(t, len(opts), 3)
	testing.expect_value(t, string(opts[0].(json.String)), "Staging")
	testing.expect_value(t, string(opts[1].(json.String)), "Production")
	testing.expect_value(t, string(opts[2].(json.String)), "Canary")
}

@(test)
test_chat_send_with_repeated_option_flags :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("chat-send-repeated-option-flags")
	defer ctl_vault_test_sandbox_close(&sb)

	orig_to := "user"
	orig_body := "Select an action."
	args := []string{
		"--option", "Approve",
		"--option", "Reject",
	}

	out := ctl_agentmode_chat_send_params(orig_to, orig_body, args)

	testing.expect(t, strings.contains(out, `"options":["Approve","Reject"]`), "options array must collect repeated --option flags")

	val, err := json.parse_string(out, allocator = context.temp_allocator)
	testing.expect(t, err == .None, "params must be valid JSON")
	obj := val.(json.Object)
	opts := obj["options"].(json.Array)
	testing.expect_value(t, len(opts), 2)
	testing.expect_value(t, string(opts[0].(json.String)), "Approve")
	testing.expect_value(t, string(opts[1].(json.String)), "Reject")
}

@(test)
test_chat_send_with_expected_answers_and_choices_aliases :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("chat-send-aliases")
	defer ctl_vault_test_sandbox_close(&sb)

	orig_to := "user"
	orig_body := "Proceed with migration?"
	args := []string{
		"--expected-answers", "Yes,No",
		"--choices", "Postpone",
	}

	out := ctl_agentmode_chat_send_params(orig_to, orig_body, args)

	testing.expect(t, strings.contains(out, `"options":["Yes","No","Postpone"]`), "options array must include aliases")

	val, err := json.parse_string(out, allocator = context.temp_allocator)
	testing.expect(t, err == .None, "params must be valid JSON")
	obj := val.(json.Object)
	opts := obj["options"].(json.Array)
	testing.expect_value(t, len(opts), 3)
}

@(test)
test_chat_send_without_options_omits_options_key :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("chat-send-no-options")
	defer ctl_vault_test_sandbox_close(&sb)

	orig_to := "user"
	orig_body := "Plain text question with no suggested options."
	args := []string{}

	out := ctl_agentmode_chat_send_params(orig_to, orig_body, args)

	testing.expect(t, strings.contains(out, `"to":"user"`), "to must be user")
	testing.expect(t, strings.contains(out, orig_body), "body must be preserved")
	testing.expect(t, !strings.contains(out, `"options"`), "options field must not exist in output when omitted")
}

@(test)
test_chat_send_with_comma_separated_actions :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("chat-send-comma-separated-actions")
	defer ctl_vault_test_sandbox_close(&sb)

	orig_to := "user"
	orig_body := "Please review these action cards."
	args := []string{
		"--actions", "crd_act_1,crd_act_2",
	}

	out := ctl_agentmode_chat_send_params(orig_to, orig_body, args)

	testing.expect(t, strings.contains(out, `"to":"user"`), "to must be user")
	testing.expect(t, strings.contains(out, orig_body), "body must be preserved")
	testing.expect(t, strings.contains(out, `"action_ids":["crd_act_1","crd_act_2"]`), "action_ids array must match comma-separated input")

	val, err := json.parse_string(out, allocator = context.temp_allocator)
	testing.expect(t, err == .None, "params must be valid JSON")
	obj := val.(json.Object)
	acts := obj["action_ids"].(json.Array)
	testing.expect_value(t, len(acts), 2)
	testing.expect_value(t, string(acts[0].(json.String)), "crd_act_1")
	testing.expect_value(t, string(acts[1].(json.String)), "crd_act_2")
}

@(test)
test_chat_send_with_repeated_action_flags :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("chat-send-repeated-action-flags")
	defer ctl_vault_test_sandbox_close(&sb)

	orig_to := "user"
	orig_body := "Linked action."
	args := []string{
		"--action", "crd_act_alpha",
		"--action", "crd_act_beta",
	}

	out := ctl_agentmode_chat_send_params(orig_to, orig_body, args)

	testing.expect(t, strings.contains(out, `"action_ids":["crd_act_alpha","crd_act_beta"]`), "action_ids array must collect repeated --action flags")

	val, err := json.parse_string(out, allocator = context.temp_allocator)
	testing.expect(t, err == .None, "params must be valid JSON")
	obj := val.(json.Object)
	acts := obj["action_ids"].(json.Array)
	testing.expect_value(t, len(acts), 2)
	testing.expect_value(t, string(acts[0].(json.String)), "crd_act_alpha")
	testing.expect_value(t, string(acts[1].(json.String)), "crd_act_beta")
}

@(test)
test_action_create_params_memory_approve :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("action-create-memory-approve")
	defer ctl_vault_test_sandbox_close(&sb)

	args := []string{
		"--type", "memory.approve",
		"--memory-id", "mem_proposal_42",
		"--title", "Approve memory proposal 42",
	}

	params, ok := ctl_agentmode_action_create_params(args)
	testing.expect(t, ok, "action create params should succeed")

	val, err := json.parse_string(params, allocator = context.temp_allocator)
	testing.expect(t, err == .None, "params must be valid JSON")
	obj := val.(json.Object)
	testing.expect_value(t, string(obj["title"].(json.String)), "Approve memory proposal 42")

	ops_arr := obj["operations"].(json.Array)
	testing.expect_value(t, len(ops_arr), 1)
	op0 := ops_arr[0].(json.Object)
	testing.expect_value(t, string(op0["op"].(json.String)), "memory.approve")
	testing.expect_value(t, string(op0["memory_id"].(json.String)), "mem_proposal_42")
}

@(test)
test_action_create_params_issue_create :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("action-create-issue-create")
	defer ctl_vault_test_sandbox_close(&sb)

	args := []string{
		"--type", "issue.create",
		"--title", "CLI regression in hub routing",
		"--description", "Path routing drops trailing slash",
		"--scope", "project",
	}

	params, ok := ctl_agentmode_action_create_params(args)
	testing.expect(t, ok, "action create params should succeed")

	val, err := json.parse_string(params, allocator = context.temp_allocator)
	testing.expect(t, err == .None, "params must be valid JSON")
	obj := val.(json.Object)
	testing.expect_value(t, string(obj["title"].(json.String)), "CLI regression in hub routing")

	ops_arr := obj["operations"].(json.Array)
	testing.expect_value(t, len(ops_arr), 1)
	op0 := ops_arr[0].(json.Object)
	testing.expect_value(t, string(op0["op"].(json.String)), "issue.create")
	testing.expect_value(t, string(op0["title"].(json.String)), "CLI regression in hub routing")
	testing.expect_value(t, string(op0["description"].(json.String)), "Path routing drops trailing slash")
	testing.expect_value(t, string(op0["scope"].(json.String)), "project")
}

@(test)
test_action_create_params_custom_operations :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("action-create-custom-operations")
	defer ctl_vault_test_sandbox_close(&sb)

	args := []string{
		"--title", "Custom bulk action",
		"--operations", `[{"op":"task.vote","task_id":"task_123","result":"lgtm"}]`,
	}

	params, ok := ctl_agentmode_action_create_params(args)
	testing.expect(t, ok, "action create params with custom operations should succeed")

	val, err := json.parse_string(params, allocator = context.temp_allocator)
	testing.expect(t, err == .None, "params must be valid JSON")
	obj := val.(json.Object)
	testing.expect_value(t, string(obj["title"].(json.String)), "Custom bulk action")

	ops_arr := obj["operations"].(json.Array)
	testing.expect_value(t, len(ops_arr), 1)
	op0 := ops_arr[0].(json.Object)
	testing.expect_value(t, string(op0["op"].(json.String)), "task.vote")
	testing.expect_value(t, string(op0["task_id"].(json.String)), "task_123")
	testing.expect_value(t, string(op0["result"].(json.String)), "lgtm")
}

@(test)
test_action_create_params_validation_errors :: proc(t: ^testing.T) {
	// Missing title
	args1 := []string{"--type", "memory.approve", "--memory-id", "mem_1"}
	_, ok1 := ctl_agentmode_action_create_params(args1)
	testing.expect(t, !ok1, "missing title should fail")

	// Missing memory-id for memory.approve
	args2 := []string{"--type", "memory.approve", "--title", "T"}
	_, ok2 := ctl_agentmode_action_create_params(args2)
	testing.expect(t, !ok2, "missing memory-id for memory.approve should fail")

	// Missing operations when no type
	args3 := []string{"--title", "T"}
	_, ok3 := ctl_agentmode_action_create_params(args3)
	testing.expect(t, !ok3, "missing operations when no type should fail")
}

