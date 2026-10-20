package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

// ── REQ-VAULT-CHAINS-1 Unit Tests for CLI Task Chains Encryption & Decryption ──

TEST_CHAIN_VAULT_KEY :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

@(test)
test_chain_show_transparent_decryption :: proc(t: ^testing.T) {
	orig_title := "Zero-Knowledge Task Chain Integration"
	orig_desc  := "All sensitive chain fields are encrypted with local AES-GCM key."

	enc_title, _ := vault_encrypt_text_hex(orig_title, TEST_CHAIN_VAULT_KEY, context.temp_allocator)
	enc_desc, _  := vault_encrypt_text_hex(orig_desc, TEST_CHAIN_VAULT_KEY, context.temp_allocator)

	raw_json := fmt.tprintf(
		`{{"ok":true,"data":{{"chain_id":"chain_123","title":"%s","description":"%s","status":"active"}}}}`,
		enc_title,
		enc_desc,
	)

	// Decrypt with valid key configured
	decrypted_json := ctl_decrypt_vault_json(raw_json, tkr(TEST_CHAIN_VAULT_KEY), true, context.temp_allocator)
	testing.expect(t, strings.contains(decrypted_json, orig_title), "decrypted json must contain original title")
	testing.expect(t, strings.contains(decrypted_json, orig_desc), "decrypted json must contain original description")
	testing.expect(t, !strings.contains(decrypted_json, "vault:v2:"), "decrypted json must not contain armor prefix")
}

@(test)
test_chain_unconfigured_fallback :: proc(t: ^testing.T) {
	orig_title := "Confidential Security Audit"
	enc_title, _ := vault_encrypt_text_hex(orig_title, TEST_CHAIN_VAULT_KEY, context.temp_allocator)

	raw_json := fmt.tprintf(
		`{{"ok":true,"data":{{"chain_id":"chain_999","title":"%s","status":"active"}}}}`,
		enc_title,
	)

	// Decrypt with key NOT configured (unlocked = false)
	fallback_json := ctl_decrypt_vault_json(raw_json, nil, false, context.temp_allocator)

	expected_fallback := fmt.tprintf("[Encrypted: %s]", enc_title)
	testing.expect(t, strings.contains(fallback_json, expected_fallback), "must format as [Encrypted: vault:v2:...]")
	testing.expect(t, !strings.contains(fallback_json, orig_title), "must not expose plaintext when unconfigured")
}

@(test)
test_chain_list_transparent_decryption :: proc(t: ^testing.T) {
	enc_title1, _ := vault_encrypt_text_hex("Secret Chain Alpha", TEST_CHAIN_VAULT_KEY, context.temp_allocator)
	plain_title2  := "Public Legacy Chain Beta"

	raw_json := fmt.tprintf(
		`{{"ok":true,"data":[{{"chain_id":"c1","title":"%s"}},{{"chain_id":"c2","title":"%s"}}]}}`,
		enc_title1,
		plain_title2,
	)

	// Decrypt list with valid key
	decrypted_json := ctl_decrypt_vault_json(raw_json, tkr(TEST_CHAIN_VAULT_KEY), true, context.temp_allocator)

	testing.expect(t, strings.contains(decrypted_json, "Secret Chain Alpha"), "must decrypt armored chain")
	testing.expect(t, strings.contains(decrypted_json, plain_title2), "must preserve legacy plaintext chain untouched")
}

@(test)
test_chain_archive_destructive_verb :: proc(t: ^testing.T) {
	testing.expect(t, is_destructive_chain_verb("archive"), "archive must be destructive verb requiring explicit chain")
	testing.expect(t, is_destructive_chain_verb("unarchive"), "unarchive must be destructive verb requiring explicit chain")
	testing.expect(t, is_destructive_chain_verb("complete"), "complete must be destructive verb")
	testing.expect(t, is_destructive_chain_verb("publish"), "publish must be destructive verb")
	testing.expect(t, is_destructive_chain_verb("reopen"), "reopen must be destructive verb")
	testing.expect(t, !is_destructive_chain_verb("show"), "show is not destructive")
	testing.expect(t, !is_destructive_chain_verb("list"), "list is not destructive")
}

@(test)
test_task_chain_create_params_plaintext :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("task-chain-create-params-plaintext")
	defer ctl_vault_test_sandbox_close(&sb)
	args := []string{
		"--title", "Alpha Task Chain",
		"--description", "Autonomous task chain for deployment.",
		"--kind", "team_work",
		"--coordinator", "agt_coord_1",
		"--bridge", "brg_local_1",
		"--project", "proj_alpha",
		"--provider", "claude",
		"--model", "smart",
	}

	params := unseal_out(ctl_agentmode_task_chain_create_params(with_kr(args)))
	defer delete(params)

	testing.expect(t, strings.contains(params, `"title":"Alpha Task Chain"`), "title should remain plaintext")
	testing.expect(t, strings.contains(params, `"description":"Autonomous task chain for deployment."`), "description should remain plaintext")
	testing.expect(t, strings.contains(params, `"kind":"team_work"`), "kind should be team_work")
	testing.expect(t, strings.contains(params, `"coordinator_agent_id":"agt_coord_1"`), "coordinator_agent_id should match")
	testing.expect(t, strings.contains(params, `"bridge_id":"brg_local_1"`), "bridge_id should match")
	testing.expect(t, strings.contains(params, `"project_id":"proj_alpha"`), "project_id should match")
	testing.expect(t, strings.contains(params, `"provider":"claude"`), "provider should match")
	testing.expect(t, strings.contains(params, `"model":"smart"`), "model should match")
	testing.expect(t, !strings.contains(params, "vault:v2:"), "should not be encrypted without vault key")
}

@(test)
test_task_chain_create_params_aliases :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("task-chain-create-params-aliases")
	defer ctl_vault_test_sandbox_close(&sb)
	args := []string{
		"--title", "Beta Chain",
		"--coordinator-agent-id", "agt_coord_2",
		"--bridge-id", "brg_2",
		"--project-id", "proj_2",
	}

	params := unseal_out(ctl_agentmode_task_chain_create_params(with_kr(args)))
	defer delete(params)

	testing.expect(t, strings.contains(params, `"title":"Beta Chain"`), "title should match")
	testing.expect(t, strings.contains(params, `"coordinator_agent_id":"agt_coord_2"`), "coordinator-agent-id alias should work")
	testing.expect(t, strings.contains(params, `"bridge_id":"brg_2"`), "bridge-id alias should work")
	testing.expect(t, strings.contains(params, `"project_id":"proj_2"`), "project-id alias should work")
	testing.expect(t, strings.contains(params, `"kind":"team_work"`), "default kind should be team_work")
}

@(test)
test_task_chain_create_params_positional_title :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("task-chain-create-params-positional-title")
	defer ctl_vault_test_sandbox_close(&sb)
	args := []string{
		"--coordinator", "agt_coord_3",
	}

	params := unseal_out(ctl_agentmode_task_chain_create_params(with_kr(args), "Positional Title Chain"))
	defer delete(params)

	testing.expect(t, strings.contains(params, `"title":"Positional Title Chain"`), "positional title should be used if --title is omitted")
}

@(test)
test_task_chain_create_params_with_vault_encryption :: proc(t: ^testing.T) {
	orig_title := "Confidential Microservice Deployment"
	orig_desc := "Deploy zero-trust proxy and internal tokens."

	args := []string{
		"--title", orig_title,
		"--description", orig_desc,
		"--coordinator", "agt_sec_coord",
		"--bridge", "brg_sec_1",
		"--project", "proj_sec",
		"--vault-keyring", tkr_b64(TEST_CHAIN_VAULT_KEY),
	}

	params := ctl_agentmode_task_chain_create_params(args)
	defer delete(params)

	testing.expect(t, !strings.contains(params, orig_title), "title must not leak in plaintext")
	testing.expect(t, !strings.contains(params, orig_desc), "description must not leak in plaintext")
	testing.expect(t, strings.contains(params, `"title":"vault:v2:`), "title must be vault armored")
	testing.expect(t, strings.contains(params, `"description":"vault:v2:`), "description must be vault armored")
	testing.expect(t, strings.contains(params, `"coordinator_agent_id":"agt_sec_coord"`), "coordinator must remain plaintext")
	testing.expect(t, strings.contains(params, `"bridge_id":"brg_sec_1"`), "bridge must remain plaintext")
	testing.expect(t, strings.contains(params, `"project_id":"proj_sec"`), "project must remain plaintext")

	val, err := json.parse_string(params, parse_integers = true, allocator = context.temp_allocator)
	testing.expect(t, err == .None, "emitted params must be valid JSON")
	obj := val.(json.Object)

	enc_title := string(obj["title"].(json.String))
	dec_title, dt_ok := vault_decrypt_text_hex(enc_title, TEST_CHAIN_VAULT_KEY, context.temp_allocator)
	testing.expect(t, dt_ok, "title must decrypt successfully")
	testing.expect_value(t, dec_title, orig_title)

	enc_desc := string(obj["description"].(json.String))
	dec_desc, dd_ok := vault_decrypt_text_hex(enc_desc, TEST_CHAIN_VAULT_KEY, context.temp_allocator)
	testing.expect(t, dd_ok, "description must decrypt successfully")
	testing.expect_value(t, dec_desc, orig_desc)
}
