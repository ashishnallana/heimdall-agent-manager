package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

// ── REQ-VAULT-ARTIFACTS-1 CLI Unit Tests ────────────────────────────────────

TEST_ARTIFACT_VAULT_KEY :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
ALT_ARTIFACT_VAULT_KEY  :: "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"

@(test)
test_artifact_create_encryption_with_vault_key :: proc(t: ^testing.T) {
	orig_name := "security-incident-audit-2026.md"
	orig_desc := "Confidential security breach report and remediation log"
	orig_content := "# Confidential Audit\nAll database credentials were rotated."

	args := []string{
		"--name", orig_name,
		"--description", orig_desc,
		"--content", orig_content,
		"--kind", "markdown",
		"--project", "proj_security_99",
		"--vault-keyring", tkr_b64(TEST_ARTIFACT_VAULT_KEY),
	}

	out := ctl_agentmode_artifact_create_params(args)

	// Kind and project must be preserved in plaintext
	testing.expect(t, strings.contains(out, `"kind":"markdown"`), "kind must be plaintext")
	testing.expect(t, strings.contains(out, `"project_id":"proj_security_99"`), "project_id must be plaintext")

	// Name must be encrypted
	testing.expect(t, !strings.contains(out, orig_name), "name must not leak plaintext")
	testing.expect(t, strings.contains(out, `"name":"vault:v2:`), "name must be armored with vault:v2:")

	// Description must be encrypted
	testing.expect(t, !strings.contains(out, orig_desc), "description must not leak plaintext")
	testing.expect(t, strings.contains(out, `"description":"vault:v2:`), "description must be armored with vault:v2:")

	// Content must be encrypted
	testing.expect(t, !strings.contains(out, orig_content), "content must not leak plaintext")
	testing.expect(t, strings.contains(out, `"content":"vault:v2:`), "content must be armored with vault:v2:")

	// Round-trip decryption check
	val, err := json.parse_string(out, parse_integers = true, allocator = context.temp_allocator)
	testing.expect(t, err == .None, "emitted params must be valid JSON")
	obj := val.(json.Object)

	enc_name := string(obj["name"].(json.String))
	dec_name, dn_ok := vault_decrypt_text_hex(enc_name, TEST_ARTIFACT_VAULT_KEY, context.temp_allocator)
	testing.expect(t, dn_ok, "name must decrypt successfully")
	testing.expect_value(t, dec_name, orig_name)

	enc_desc := string(obj["description"].(json.String))
	dec_desc, dd_ok := vault_decrypt_text_hex(enc_desc, TEST_ARTIFACT_VAULT_KEY, context.temp_allocator)
	testing.expect(t, dd_ok, "description must decrypt successfully")
	testing.expect_value(t, dec_desc, orig_desc)

	enc_content := string(obj["content"].(json.String))
	dec_content, dc_ok := vault_decrypt_text_hex(enc_content, TEST_ARTIFACT_VAULT_KEY, context.temp_allocator)
	testing.expect(t, dc_ok, "content must decrypt successfully")
	testing.expect_value(t, dec_content, orig_content)
}


@(test)
test_artifact_show_and_list_transparent_decryption :: proc(t: ^testing.T) {
	orig_name := "database-credentials.env"
	orig_desc := "Production credentials for core storage cluster"
	orig_content := "PASSWORD=very_secret_pass"

	enc_name, _ := vault_encrypt_text_hex(orig_name, TEST_ARTIFACT_VAULT_KEY, context.temp_allocator)
	enc_desc, _ := vault_encrypt_text_hex(orig_desc, TEST_ARTIFACT_VAULT_KEY, context.temp_allocator)
	enc_content, _ := vault_encrypt_text_hex(orig_content, TEST_ARTIFACT_VAULT_KEY, context.temp_allocator)

	raw_json := fmt.tprintf(
		`{{"ok":true,"data":{{"artifact_id":"art_vault_123","name":"%s","description":"%s","content":"%s","kind":"text","size_bytes":100}}}}`,
		enc_name, enc_desc, enc_content,
	)

	// Decrypt with correct key
	decrypted := ctl_decrypt_json_string(raw_json, tkr(TEST_ARTIFACT_VAULT_KEY), true, context.temp_allocator)
	testing.expect(t, strings.contains(decrypted, orig_name), "decrypted JSON must contain orig name")
	testing.expect(t, strings.contains(decrypted, orig_desc), "decrypted JSON must contain orig description")
	testing.expect(t, strings.contains(decrypted, orig_content), "decrypted JSON must contain orig content")
	testing.expect(t, !strings.contains(decrypted, "vault:v2:"), "decrypted JSON must have zero vault armor")
}

@(test)
test_artifact_show_and_list_unconfigured_key_fallback :: proc(t: ^testing.T) {
	enc_name, _ := vault_encrypt_text_hex("Secret Artifact", TEST_ARTIFACT_VAULT_KEY, context.temp_allocator)

	raw_json := fmt.tprintf(`{{"ok":true,"data":{{"artifact_id":"art_1","name":"%s"}}}}`, enc_name)

	// Decrypt without configured key (fallback expected)
	fallback := ctl_decrypt_json_string(raw_json, nil, false, context.temp_allocator)
	testing.expect(t, strings.contains(fallback, "[Encrypted: vault:v2:"), "unconfigured key must yield [Encrypted: vault:v2:...]")
}

@(test)
test_artifact_content_decryption_and_fallbacks :: proc(t: ^testing.T) {
	orig_content := "# Sensitive Architecture Document\nZero-knowledge is active."
	enc_content, enc_ok := vault_encrypt_text_hex(orig_content, TEST_ARTIFACT_VAULT_KEY, context.temp_allocator)
	testing.expect(t, enc_ok, "encrypt must succeed")

	// 1. Correct key decrypts cleanly
	dec := ctl_decrypt_or_fallback_armored(enc_content, tkr(TEST_ARTIFACT_VAULT_KEY), true, context.temp_allocator)
	testing.expect_value(t, dec, orig_content)

	// 2. Unconfigured key returns fallback
	fallback_unconf := ctl_decrypt_or_fallback_armored(enc_content, nil, false, context.temp_allocator)
	testing.expect(t, strings.has_prefix(fallback_unconf, "[Encrypted: vault:v2:"), "unconfigured must return fallback")

	// 3. Wrong key returns fallback
	fallback_wrong := ctl_decrypt_or_fallback_armored(enc_content, tkr(ALT_ARTIFACT_VAULT_KEY), true, context.temp_allocator)
	testing.expect(t, strings.has_prefix(fallback_wrong, "[Encrypted: vault:v2:"), "wrong key must return fallback")

	// 4. Legacy plaintext returns as-is
	legacy := "Plaintext unencrypted legacy content"
	dec_legacy := ctl_decrypt_or_fallback_armored(legacy, tkr(TEST_ARTIFACT_VAULT_KEY), true, context.temp_allocator)
	testing.expect_value(t, dec_legacy, legacy)
}
