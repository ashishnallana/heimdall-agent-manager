package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

// ── REQ-VAULT-MEMORIES-1 CLI Unit Tests ──────────────────────────────────────

TEST_MEMORY_VAULT_KEY :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
ALT_MEMORY_VAULT_KEY  :: "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"

@(test)
test_memory_propose_encryption_with_vault_key :: proc(t: ^testing.T) {
	orig_title := "Strict invariant for agent token generation"
	orig_desc := "Tokens must be prefixed with hlat_ and have 128 bits of entropy."
	orig_body := "Ensure all token generation calls crypto/rand and formats with hex encoding."
	orig_evidence := "file://src/bridge/agent_token_store.odin#L42-L55"

	args := []string{
		"--type", "fact",
		"--title", orig_title,
		"--description", orig_desc,
		"--body", orig_body,
		"--evidence", orig_evidence,
		"--agent-ids", "agt_worker_1",
		"--vault-keyring", tkr_b64(TEST_MEMORY_VAULT_KEY),
	}

	out := ctl_agentmode_memory_propose_params(args)

	// Check type is preserved in plaintext
	testing.expect(t, strings.contains(out, `"type":"fact"`), "type must be plaintext")

	// Title must be encrypted
	testing.expect(t, !strings.contains(out, orig_title), "title must not leak plaintext")
	testing.expect(t, strings.contains(out, `"title":"vault:v2:`), "title must be armored with vault:v2:")

	// Description must be encrypted
	testing.expect(t, !strings.contains(out, orig_desc), "description must not leak plaintext")
	testing.expect(t, strings.contains(out, `"description":"vault:v2:`), "description must be armored with vault:v2:")

	// Body must be encrypted
	testing.expect(t, !strings.contains(out, orig_body), "body must not leak plaintext")
	testing.expect(t, strings.contains(out, `"body":"vault:v2:`), "body must be armored with vault:v2:")

	// Evidence must be encrypted
	testing.expect(t, !strings.contains(out, orig_evidence), "evidence must not leak plaintext")
	testing.expect(t, strings.contains(out, `"evidence":"vault:v2:`), "evidence must be armored with vault:v2:")

	// Targeting is preserved
	testing.expect(t, strings.contains(out, `"agent_ids":["agt_worker_1"]`), "agent_ids must be preserved")

	// Parse JSON to extract encrypted fields and test round-trip decryption
	val, err := json.parse_string(out, parse_integers = true, allocator = context.temp_allocator)
	testing.expect(t, err == .None, "emitted params must be valid JSON")
	obj := val.(json.Object)

	enc_title := string(obj["title"].(json.String))
	dec_title, dt_ok := vault_decrypt_text_hex(enc_title, TEST_MEMORY_VAULT_KEY, context.temp_allocator)
	testing.expect(t, dt_ok, "title must decrypt successfully")
	testing.expect_value(t, dec_title, orig_title)

	enc_desc := string(obj["description"].(json.String))
	dec_desc, dd_ok := vault_decrypt_text_hex(enc_desc, TEST_MEMORY_VAULT_KEY, context.temp_allocator)
	testing.expect(t, dd_ok, "description must decrypt successfully")
	testing.expect_value(t, dec_desc, orig_desc)

	enc_body := string(obj["body"].(json.String))
	dec_body, db_ok := vault_decrypt_text_hex(enc_body, TEST_MEMORY_VAULT_KEY, context.temp_allocator)
	testing.expect(t, db_ok, "body must decrypt successfully")
	testing.expect_value(t, dec_body, orig_body)

	enc_ev := string(obj["evidence"].(json.String))
	dec_ev, de_ok := vault_decrypt_text_hex(enc_ev, TEST_MEMORY_VAULT_KEY, context.temp_allocator)
	testing.expect(t, de_ok, "evidence must decrypt successfully")
	testing.expect_value(t, dec_ev, orig_evidence)
}

@(test)
test_memory_propose_without_vault_key_leaves_plaintext :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("memory-propose-without-vault-key-leaves-plaintext")
	defer ctl_vault_test_sandbox_close(&sb)
	orig_title := "Plaintext Memory Title"
	orig_body := "Plaintext Memory Body"

	args := []string{
		"--type", "fact",
		"--title", orig_title,
		"--body", orig_body,
	}

	out := ctl_agentmode_memory_propose_params(args)
	testing.expect(t, strings.contains(out, `"title":"Plaintext Memory Title"`), "title must remain plaintext")
	testing.expect(t, strings.contains(out, `"body":"Plaintext Memory Body"`), "body must remain plaintext")
	testing.expect(t, !strings.contains(out, "vault:v2:"), "must not contain vault armor")
}

@(test)
test_memory_show_and_list_transparent_decryption :: proc(t: ^testing.T) {
	orig_title := "Confidential API Architecture"
	orig_desc := "Architectural design for encrypted memory storage"
	orig_body := "All memories are encrypted client-side using AES-GCM-256."
	orig_evidence := "file://tests/ctl_memories_vault_test.odin"

	enc_title, _ := vault_encrypt_text_hex(orig_title, TEST_MEMORY_VAULT_KEY, context.temp_allocator)
	enc_desc, _ := vault_encrypt_text_hex(orig_desc, TEST_MEMORY_VAULT_KEY, context.temp_allocator)
	enc_body, _ := vault_encrypt_text_hex(orig_body, TEST_MEMORY_VAULT_KEY, context.temp_allocator)
	enc_ev, _ := vault_encrypt_text_hex(orig_evidence, TEST_MEMORY_VAULT_KEY, context.temp_allocator)

	raw_json := fmt.tprintf(
		`{{"v":1,"ok":true,"data":{{"data":{{"memory_id":"mem_test_1","title":"%s","description":"%s","body":"%s","evidence":"%s","status":"active","type":"fact"}}}}}}`,
		enc_title, enc_desc, enc_body, enc_ev,
	)

	decrypted := ctl_decrypt_memory_json(raw_json, tkr(TEST_MEMORY_VAULT_KEY), true, context.temp_allocator)
	testing.expect(t, strings.contains(decrypted, orig_title), "decrypted json must contain original title")
	testing.expect(t, strings.contains(decrypted, orig_desc), "decrypted json must contain original description")
	testing.expect(t, strings.contains(decrypted, orig_body), "decrypted json must contain original body")
	testing.expect(t, strings.contains(decrypted, orig_evidence), "decrypted json must contain original evidence")
	testing.expect(t, !strings.contains(decrypted, "vault:v2:"), "decrypted json must not contain vault armor")
}

@(test)
test_memory_unconfigured_fallback :: proc(t: ^testing.T) {
	orig_title := "Top Secret Strategy"
	enc_title, _ := vault_encrypt_text_hex(orig_title, TEST_MEMORY_VAULT_KEY, context.temp_allocator)

	raw_json := fmt.tprintf(
		`{{"v":1,"ok":true,"data":{{"data":{{"memory_id":"mem_test_2","title":"%s","body":"regular body"}}}}}}`,
		enc_title,
	)

	// Key not configured -> fallback
	decrypted := ctl_decrypt_memory_json(raw_json, nil, false, context.temp_allocator)
	testing.expect(t, !strings.contains(decrypted, orig_title), "must not leak plaintext without key")
	expected_fallback := fmt.tprintf(`[Encrypted: %s]`, enc_title)
	testing.expect(t, strings.contains(decrypted, expected_fallback), "must contain [Encrypted: vault:v2:...] fallback")
	testing.expect(t, strings.contains(decrypted, "regular body"), "unencrypted body must remain intact")
}

@(test)
test_memory_wrong_key_fallback :: proc(t: ^testing.T) {
	orig_title := "Top Secret Strategy"
	enc_title, _ := vault_encrypt_text_hex(orig_title, TEST_MEMORY_VAULT_KEY, context.temp_allocator)

	raw_json := fmt.tprintf(
		`{{"v":1,"ok":true,"data":{{"data":{{"memory_id":"mem_test_3","title":"%s"}}}}}}`,
		enc_title,
	)

	// Wrong key -> fallback
	decrypted := ctl_decrypt_memory_json(raw_json, tkr(ALT_MEMORY_VAULT_KEY), true, context.temp_allocator)
	testing.expect(t, !strings.contains(decrypted, orig_title), "must not decrypt with wrong key")
	expected_fallback := fmt.tprintf(`[Encrypted: %s]`, enc_title)
	testing.expect(t, strings.contains(decrypted, expected_fallback), "must contain fallback on decryption failure")
}

@(test)
test_memory_content_transparent_decryption :: proc(t: ^testing.T) {
	orig_body := "Pure body text for agent consumption."
	enc_body, _ := vault_encrypt_text_hex(orig_body, TEST_MEMORY_VAULT_KEY, context.temp_allocator)

	// 1. With configured key
	decrypted := ctl_decrypt_or_fallback_armored(enc_body, tkr(TEST_MEMORY_VAULT_KEY), true, context.temp_allocator)
	testing.expect_value(t, decrypted, orig_body)

	// 2. Unconfigured key.
	// As of REQ-VAULT-3 the fallback is intentionally `[Encrypted: <armored>] <remedy hint>`: the
	// bracketed part keeps its exact historical shape and a hint naming `ham-ctl vault status`
	// follows it. Do NOT "restore" the bare bracketed form — the hint is the point of REQ-VAULT-3
	// (an agent was hard-blocked because nothing in the CLI named the cause or the remedy).
	// The hint is spelled out literally rather than referencing VAULT_HINT_NO_KEY so that an
	// accidental edit of that constant fails here instead of silently agreeing with itself.
	fallback := ctl_decrypt_or_fallback_armored(enc_body, nil, false, context.temp_allocator)
	expected_prefix := fmt.tprintf(`[Encrypted: %s]`, enc_body)
	expected_fallback := fmt.tprintf(
		"%s (vault key not configured — see `ham-ctl vault status`)",
		expected_prefix,
	)
	// Equality still pins the whole string; the two expects below say which half broke.
	testing.expect_value(t, fallback, expected_fallback)
	testing.expect(
		t,
		strings.has_prefix(fallback, expected_prefix),
		"bracketed `[Encrypted: <armored>]` prefix must keep its historical shape",
	)
	testing.expect(
		t,
		strings.contains(fallback, "see `ham-ctl vault status`"),
		"fallback must name the `ham-ctl vault status` remedy",
	)

	// 3. Plaintext passthrough
	plain_body := "Legacy plaintext body"
	passthrough := ctl_decrypt_or_fallback_armored(plain_body, tkr(TEST_MEMORY_VAULT_KEY), true, context.temp_allocator)
	testing.expect_value(t, passthrough, plain_body)
}

@(test)
test_legacy_plaintext_memories_unaltered :: proc(t: ^testing.T) {
	raw_json := `{"v":1,"ok":true,"data":{"data":[{"memory_id":"mem_legacy","title":"Plain Title","description":"Plain Desc","body":"Plain Body","evidence":"Plain Evidence"}]}}`
	decrypted := ctl_decrypt_memory_json(raw_json, tkr(TEST_MEMORY_VAULT_KEY), true, context.temp_allocator)
	testing.expect(t, strings.contains(decrypted, `"title":"Plain Title"`), "title preserved")
	testing.expect(t, strings.contains(decrypted, `"description":"Plain Desc"`), "description preserved")
	testing.expect(t, strings.contains(decrypted, `"body":"Plain Body"`), "body preserved")
	testing.expect(t, strings.contains(decrypted, `"evidence":"Plain Evidence"`), "evidence preserved")
}

// ── Unit coverage for pure memory-propose & memory-list param-builders ──

@(test)
test_memory_params_zero_ids_omits_target_arrays :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("memory-params-zero-ids-omits-target-arrays")
	defer ctl_vault_test_sandbox_close(&sb)
	args := []string{"--type", "fact", "--title", "T", "--body", "B"}
	out := ctl_agentmode_memory_propose_params(args)
	testing.expect(t, strings.contains(out, `"type":"fact"`), "type present")
	testing.expect(t, strings.contains(out, `"title":"T"`), "title present")
	testing.expect(t, strings.contains(out, `"body":"B"`), "body present")
	testing.expect(t, !strings.contains(out, "agent_ids"), "agent_ids omitted when no ids")
	testing.expect(t, !strings.contains(out, "project_ids"), "project_ids omitted when no ids")
	testing.expect(t, !strings.contains(out, "bridge_ids"), "bridge_ids omitted when no ids")
	testing.expect(t, !strings.contains(out, "template_ids"), "template_ids omitted when no ids")
	testing.expect(t, !strings.contains(out, "evidence"), "evidence omitted when blank")
}

@(test)
test_memory_params_single_id_per_dimension :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("memory-params-single-id-per-dimension")
	defer ctl_vault_test_sandbox_close(&sb)
	args := []string{
		"--type", "fact", "--title", "T", "--body", "B",
		"--agent-id", "agt_a", "--project-id", "proj_1",
		"--bridge-id", "brg_1", "--template-id", "tmpl_1",
	}
	out := ctl_agentmode_memory_propose_params(args)
	testing.expect(t, strings.contains(out, `"agent_ids":["agt_a"]`), out)
	testing.expect(t, strings.contains(out, `"project_ids":["proj_1"]`), out)
	testing.expect(t, strings.contains(out, `"bridge_ids":["brg_1"]`), out)
	testing.expect(t, strings.contains(out, `"template_ids":["tmpl_1"]`), out)
}

@(test)
test_memory_params_two_ids_via_csv :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("memory-params-two-ids-via-csv")
	defer ctl_vault_test_sandbox_close(&sb)
	args := []string{"--type", "fact", "--title", "T", "--body", "B", "--agent-ids", "agt_a,agt_b"}
	out := ctl_agentmode_memory_propose_params(args)
	testing.expect(t, strings.contains(out, `"agent_ids":["agt_a","agt_b"]`), out)
}

@(test)
test_memory_params_two_ids_via_repeated_flags :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("memory-params-two-ids-via-repeated-flags")
	defer ctl_vault_test_sandbox_close(&sb)
	args := []string{"--type", "fact", "--title", "T", "--body", "B", "--agent", "agt_a", "--agent", "agt_b"}
	out := ctl_agentmode_memory_propose_params(args)
	testing.expect(t, strings.contains(out, `"agent_ids":["agt_a","agt_b"]`), out)
}

@(test)
test_memory_params_csv_and_repeated_combine_and_trim :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("memory-params-csv-and-repeated-combine-and-trim")
	defer ctl_vault_test_sandbox_close(&sb)
	args := []string{"--type", "fact", "--title", "T", "--body", "B", "--project-ids", "proj_1, proj_2", "--project", "proj_3", "--project-ids", ""}
	out := ctl_agentmode_memory_propose_params(args)
	testing.expect(t, strings.contains(out, `"project_ids":["proj_1","proj_2","proj_3"]`), out)
}

@(test)
test_json_string_array_field_escapes_values :: proc(t: ^testing.T) {
	vals := []string{"a\"b", "c\\d"}
	got := json_string_array_field("agent_ids", vals)
	testing.expect_value(t, got, `"agent_ids":["a\"b","c\\d"]`)
	empty := json_string_array_field("agent_ids", []string{})
	testing.expect_value(t, empty, `"agent_ids":[]`)
}

@(test)
test_memory_params_description_handling :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("memory-params-description-handling")
	defer ctl_vault_test_sandbox_close(&sb)
	args_with := []string{"--type", "fact", "--title", "T", "--description", "Desc text", "--body", "B"}
	out_with := ctl_agentmode_memory_propose_params(args_with)
	testing.expect(t, strings.contains(out_with, `"description":"Desc text"`), out_with)

	args_without := []string{"--type", "fact", "--title", "T", "--body", "B"}
	out_without := ctl_agentmode_memory_propose_params(args_without)
	testing.expect(t, !strings.contains(out_without, `"description"`), out_without)
}

@(test)
test_memory_list_params_defaults :: proc(t: ^testing.T) {
	args := []string{}
	out := ctl_agentmode_memory_list_params(args)
	testing.expect_value(t, out, `{}`)
}

@(test)
test_memory_list_params_status_type_limit :: proc(t: ^testing.T) {
	args := []string{"--status", "active", "--type", "fact", "--limit", "25"}
	out := ctl_agentmode_memory_list_params(args)
	testing.expect(t, strings.contains(out, `"status":"active"`), out)
	testing.expect(t, strings.contains(out, `"type":"fact"`), out)
	testing.expect(t, strings.contains(out, `"limit":25`), out)
}

@(test)
test_memory_list_params_scope_dimensions :: proc(t: ^testing.T) {
	args := []string{
		"--agent-ids", "agt_1,agt_2",
		"--project", "proj_1", "--project-ids", "proj_2",
		"--bridge-id", "brg_1",
		"--template-ids", "tmpl_1",
	}
	out := ctl_agentmode_memory_list_params(args)
	testing.expect(t, strings.contains(out, `"agent_ids":["agt_1","agt_2"]`), out)
	testing.expect(t, strings.contains(out, `"project_ids":["proj_1","proj_2"]`), out)
	testing.expect(t, strings.contains(out, `"bridge_ids":["brg_1"]`), out)
	testing.expect(t, strings.contains(out, `"template_ids":["tmpl_1"]`), out)
}
