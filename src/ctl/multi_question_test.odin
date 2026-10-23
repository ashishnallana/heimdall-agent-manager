package main

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import contracts "odin_test:contracts"
import jsonx "odin_test:lib/jsonx"

CTL_MQ_GROUP :: `{"version":1,"questions":[{"id":"target","text":"Private target question?","options":[{"id":"stage","label":"Private staging label"}]},{"id":"checks","text":"Private checks question?","selection_mode":"multiple","options":[{"id":"smoke","label":"Private smoke label"}]}]}`

@(test)
test_chat_multi_question_encrypted_roundtrip :: proc(t: ^testing.T) {
	args := []string{"--vault-keyring", tkr_b64(TEST_CHAT_VAULT_KEY), "--actions", "crd_1"}
	out, invalid := ctl_multi_question_send_params("user", "Private grouped questions", CTL_MQ_GROUP, args)
	testing.expect_value(t, invalid, "")
	testing.expect(t, !strings.contains(out, "Private"), "no human plaintext in emitted payload")
	root, ok := jsonx.parse_body(out, context.temp_allocator)
	if !testing.expect(t, ok, "valid JSON") do return
	o := root.(json.Object)
	testing.expect_value(t, string(o["message_type"].(json.String)), "multi_question")
	metadata, _ := jsonx.extract_raw_object(out, "metadata", top_level_only = true, allocator = context.temp_allocator)
	raw, _ := jsonx.extract_raw_object(metadata, "multi_question", top_level_only = true, allocator = context.temp_allocator)
	group, group_error := contracts.multi_question_parse(raw, true)
	testing.expect_value(t, group_error, "")
	testing.expect_value(t, group.questions[0].id, "target")
	testing.expect_value(t, group.questions[0].options[0].id, "stage")
	testing.expect_value(t, group.questions[0].selection_mode, "single")
	testing.expect_value(t, group.questions[1].selection_mode, "multiple")
	testing.expect(t, strings.contains(metadata, "crd_1"), "action attachment preserved")
	opened := ctl_decrypt_json_string(out, tkr(TEST_CHAT_VAULT_KEY), true, context.temp_allocator)
	testing.expect(t, strings.contains(opened, "Private target question?"), "question decrypts on read")
	testing.expect(t, strings.contains(opened, "Private staging label"), "option label decrypts on read")
	testing.expect(t, strings.contains(opened, "Private grouped questions"), "body decrypts on read")
	testing.expect(t, !strings.contains(opened, "vault:v2:"), "structured fields fully opened")
	locked := ctl_decrypt_json_string(out, nil, false, context.temp_allocator)
	testing.expect(t, !strings.contains(locked, "Private"), "locked read never leaks question/label/body")
	testing.expect(t, strings.contains(locked, "[Encrypted:"), "locked fallback remains readable")
	answer, _ := vault_encrypt_text_hex("Private custom answer", TEST_CHAT_VAULT_KEY, context.temp_allocator)
	answer_json := json_object(json_kv("custom_text", answer))
	opened_answer := ctl_decrypt_json_string(answer_json, tkr(TEST_CHAT_VAULT_KEY), true, context.temp_allocator)
	testing.expect(t, strings.contains(opened_answer, "Private custom answer"), "custom answer decrypts in structured inbox")
}

@(test)
test_chat_multi_question_file_and_flags :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("multi-question-file")
	defer ctl_vault_test_sandbox_close(&sb)
	path := strings.concatenate({sb.dir, "/questions.json"}, context.temp_allocator)
	// The sandbox helper's root is private to this test; exercise the actual file path.
	testing.expect(t, os.write_entire_file(path, string(CTL_MQ_GROUP)) == nil, "write input file")
	args := with_kr([]string{"--questions-file", path})
	out := ctl_agentmode_chat_send_params("user", "Questions", args)
	testing.expect(t, strings.contains(out, `"message_type":"multi_question"`), "file selects explicit wire type")
	cmd := command_tokens([]string{"ham-ctl", "chat", "send", "--questions-file", path, "--to", "user", "--body", "Questions"})
	defer delete(cmd)
	testing.expect_value(t, len(cmd), 2)
	testing.expect_value(t, cmd[0], "chat")
	testing.expect_value(t, cmd[1], "send")
}

@(test)
test_chat_multi_question_rejects_invalid_input :: proc(t: ^testing.T) {
	// All these fail before the keyring is read or a request can be sent.
	_, target_error := ctl_multi_question_send_params("inst_other", "Body", CTL_MQ_GROUP, nil)
	testing.expect(t, target_error != "", "user-only")
	_, options_error := ctl_multi_question_send_params("user", "Body", CTL_MQ_GROUP, {"--options", "A,B"})
	testing.expect(t, options_error != "", "flat options cannot be mixed")
	_, invalid_error := ctl_multi_question_send_params("user", "Body", "{", nil)
	testing.expect(t, invalid_error != "", "malformed file rejected")
	_, body_error := ctl_multi_question_send_params("user", "", CTL_MQ_GROUP, nil)
	testing.expect(t, body_error != "", "body required")
}
