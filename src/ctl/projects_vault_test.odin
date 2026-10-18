package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// ── REQ-VAULT-PROJECTS-1 Unit Tests for CLI Projects Encryption & Decryption ──

TEST_PROJECT_VAULT_KEY :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
ALT_PROJECT_VAULT_KEY  :: "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"

@(test)
test_project_show_transparent_decryption :: proc(t: ^testing.T) {
	orig_name := "Classified Security Hardening"
	orig_desc := "All project credentials, endpoints, and architecture notes are encrypted."

	enc_name, _ := vault_encrypt_text_hex(orig_name, TEST_PROJECT_VAULT_KEY, context.temp_allocator)
	enc_desc, _ := vault_encrypt_text_hex(orig_desc, TEST_PROJECT_VAULT_KEY, context.temp_allocator)

	raw_json := fmt.tprintf(
		`{{"ok":true,"data":{{"project_id":"proj_123","name":"%s","description":"%s","slug":"classified-security"}}}}`,
		enc_name,
		enc_desc,
	)

	// Decrypt with valid key configured
	decrypted_json := ctl_decrypt_vault_json(raw_json, tkr(TEST_PROJECT_VAULT_KEY), true, context.temp_allocator)
	testing.expect(t, strings.contains(decrypted_json, orig_name), "decrypted json must contain original name")
	testing.expect(t, strings.contains(decrypted_json, orig_desc), "decrypted json must contain original description")
	testing.expect(t, !strings.contains(decrypted_json, "vault:v2:"), "decrypted json must not contain armor prefix")
}

@(test)
test_project_unconfigured_fallback :: proc(t: ^testing.T) {
	orig_name := "Secret Enclave Cluster"
	enc_name, _ := vault_encrypt_text_hex(orig_name, TEST_PROJECT_VAULT_KEY, context.temp_allocator)

	raw_json := fmt.tprintf(
		`{{"ok":true,"data":{{"project_id":"proj_999","name":"%s","slug":"secret-enclave"}}}}`,
		enc_name,
	)

	// Decrypt with key NOT configured (unlocked = false)
	fallback_json := ctl_decrypt_vault_json(raw_json, nil, false, context.temp_allocator)

	expected_fallback := fmt.tprintf("[Encrypted: %s]", enc_name)
	testing.expect(t, strings.contains(fallback_json, expected_fallback), "must format as [Encrypted: vault:v2:...]")
	testing.expect(t, !strings.contains(fallback_json, orig_name), "must not expose plaintext when unconfigured")
}

@(test)
test_project_list_transparent_decryption :: proc(t: ^testing.T) {
	enc_name1, _ := vault_encrypt_text_hex("Secret Project Alpha", TEST_PROJECT_VAULT_KEY, context.temp_allocator)
	enc_desc1, _ := vault_encrypt_text_hex("Secret Desc Alpha", TEST_PROJECT_VAULT_KEY, context.temp_allocator)
	plain_name2  := "Public Open Source Project Beta"
	plain_desc2  := "Public description"

	raw_json := fmt.tprintf(
		`{{"ok":true,"data":[{{"project_id":"p1","name":"%s","description":"%s"}},{{"project_id":"p2","name":"%s","description":"%s"}}]}}`,
		enc_name1,
		enc_desc1,
		plain_name2,
		plain_desc2,
	)

	// Decrypt list with valid key
	decrypted_json := ctl_decrypt_vault_json(raw_json, tkr(TEST_PROJECT_VAULT_KEY), true, context.temp_allocator)

	testing.expect(t, strings.contains(decrypted_json, "Secret Project Alpha"), "must decrypt armored project name")
	testing.expect(t, strings.contains(decrypted_json, "Secret Desc Alpha"), "must decrypt armored project desc")
	testing.expect(t, strings.contains(decrypted_json, plain_name2), "must preserve legacy plaintext project name untouched")
	testing.expect(t, strings.contains(decrypted_json, plain_desc2), "must preserve legacy plaintext project desc untouched")
}
