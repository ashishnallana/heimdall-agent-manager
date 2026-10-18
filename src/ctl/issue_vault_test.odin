package main

import "core:fmt"
import "core:strings"
import "core:testing"

// ── REQ-VAULT-ISSUES-CLI-1 Unit Tests ────────────────────────────────────────

TEST_ISSUE_VAULT_KEY :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
ALT_ISSUE_VAULT_KEY  :: "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"

@(test)
test_issue_show_transparent_decryption :: proc(t: ^testing.T) {
	orig_title := "Zero-Knowledge Task Vault"
	orig_desc  := "All sensitive fields are encrypted with local AES-GCM key."
	orig_body  := "First comment with encrypted content."

	enc_title, _ := vault_encrypt_text_hex(orig_title, TEST_ISSUE_VAULT_KEY, context.temp_allocator)
	enc_desc, _  := vault_encrypt_text_hex(orig_desc, TEST_ISSUE_VAULT_KEY, context.temp_allocator)
	enc_body, _  := vault_encrypt_text_hex(orig_body, TEST_ISSUE_VAULT_KEY, context.temp_allocator)

	// User-mode response envelope
	user_json := fmt.tprintf(
		`{{"ok":true,"data":{{"issue_id":"iss_test_1","title":"%s","description":"%s","comments":[{{"comment_id":"cmt_1","body":"%s"}}]}}}}`,
		enc_title, enc_desc, enc_body,
	)

	dec_user := ctl_decrypt_issues_json(user_json, tkr(TEST_ISSUE_VAULT_KEY), true, context.temp_allocator)
	testing.expect(t, strings.contains(dec_user, orig_title), "user-mode response contains decrypted title")
	testing.expect(t, strings.contains(dec_user, orig_desc), "user-mode response contains decrypted description")
	testing.expect(t, strings.contains(dec_user, orig_body), "user-mode response contains decrypted comment body")
	testing.expect(t, !strings.contains(dec_user, "vault:v2:"), "user-mode response contains no raw armored strings")

	// Agent-mode response envelope (wrapped in {"v":1,"id":"ham-ctl-agent","ok":true,"data":{"data":...}})
	agent_json := fmt.tprintf(
		`{{"v":1,"id":"ham-ctl-agent","ok":true,"data":{{"data":{{"issue_id":"iss_test_1","title":"%s","description":"%s","comments":[{{"comment_id":"cmt_1","body":"%s"}}]}},"meta":{{"request_id":"req_1"}}}}}}`,
		enc_title, enc_desc, enc_body,
	)

	dec_agent := ctl_decrypt_issues_json(agent_json, tkr(TEST_ISSUE_VAULT_KEY), true, context.temp_allocator)
	testing.expect(t, strings.contains(dec_agent, orig_title), "agent-mode response contains decrypted title")
	testing.expect(t, strings.contains(dec_agent, orig_desc), "agent-mode response contains decrypted description")
	testing.expect(t, strings.contains(dec_agent, orig_body), "agent-mode response contains decrypted comment body")
	testing.expect(t, !strings.contains(dec_agent, "vault:v2:"), "agent-mode response contains no raw armored strings")
}

@(test)
test_issue_list_transparent_decryption :: proc(t: ^testing.T) {
	orig_title1 := "First Encrypted Issue"
	orig_preview1 := "Preview snippet of first issue"
	orig_title2 := "Second Encrypted Issue"
	orig_preview2 := "Preview snippet of second issue"

	enc_title1, _ := vault_encrypt_text_hex(orig_title1, TEST_ISSUE_VAULT_KEY, context.temp_allocator)
	enc_preview1, _ := vault_encrypt_text_hex(orig_preview1, TEST_ISSUE_VAULT_KEY, context.temp_allocator)
	enc_title2, _ := vault_encrypt_text_hex(orig_title2, TEST_ISSUE_VAULT_KEY, context.temp_allocator)
	enc_preview2, _ := vault_encrypt_text_hex(orig_preview2, TEST_ISSUE_VAULT_KEY, context.temp_allocator)

	list_json := fmt.tprintf(
		`{{"v":1,"id":"ham-ctl-agent","ok":true,"data":{{"data":[{{"issue_id":"iss_1","title":"%s","description_preview":"%s"}},{{"issue_id":"iss_2","title":"%s","description_preview":"%s"}}],"page":{{"limit":50,"has_more":false}}}}}}`,
		enc_title1, enc_preview1, enc_title2, enc_preview2,
	)

	dec_list := ctl_decrypt_issues_json(list_json, tkr(TEST_ISSUE_VAULT_KEY), true, context.temp_allocator)
	testing.expect(t, strings.contains(dec_list, orig_title1), "list contains decrypted title 1")
	testing.expect(t, strings.contains(dec_list, orig_preview1), "list contains decrypted preview 1")
	testing.expect(t, strings.contains(dec_list, orig_title2), "list contains decrypted title 2")
	testing.expect(t, strings.contains(dec_list, orig_preview2), "list contains decrypted preview 2")
	testing.expect(t, !strings.contains(dec_list, "vault:v2:"), "list contains no raw armored strings")
}

@(test)
test_issue_unconfigured_fallback :: proc(t: ^testing.T) {
	enc_title, _ := vault_encrypt_text_hex("Secret Title", TEST_ISSUE_VAULT_KEY, context.temp_allocator)
	enc_desc, _  := vault_encrypt_text_hex("Secret Description", TEST_ISSUE_VAULT_KEY, context.temp_allocator)

	raw_json := fmt.tprintf(
		`{{"ok":true,"data":{{"issue_id":"iss_unconfigured","title":"%s","description":"%s","status":"new"}}}}`,
		enc_title, enc_desc,
	)

	// Decrypt without vault key (key_configured = false)
	fallback_json := ctl_decrypt_issues_json(raw_json, nil, false, context.temp_allocator)

	// Fallback should format as [Encrypted: vault:v2:...] without crashing
	expected_title_fallback := fmt.tprintf("[Encrypted: %s]", enc_title)
	expected_desc_fallback  := fmt.tprintf("[Encrypted: %s]", enc_desc)

	testing.expect(t, strings.contains(fallback_json, expected_title_fallback), "fallback contains [Encrypted: vault:v2:...] title")
	testing.expect(t, strings.contains(fallback_json, expected_desc_fallback), "fallback contains [Encrypted: vault:v2:...] description")
	testing.expect(t, strings.contains(fallback_json, `"status":"new"`), "non-armored metadata preserved")
}

@(test)
test_issue_tampered_or_wrong_key_fallback :: proc(t: ^testing.T) {
	enc_title, _ := vault_encrypt_text_hex("Tamper Test Title", TEST_ISSUE_VAULT_KEY, context.temp_allocator)
	raw_json := fmt.tprintf(`{{"ok":true,"data":{{"issue_id":"iss_tamper","title":"%s"}}}}`, enc_title)

	// Decrypt with a completely different vault key
	fallback_wrong_key := ctl_decrypt_issues_json(raw_json, tkr(ALT_ISSUE_VAULT_KEY), true, context.temp_allocator)

	expected_fallback := fmt.tprintf("[Encrypted: %s]", enc_title)
	testing.expect(t, strings.contains(fallback_wrong_key, expected_fallback), "wrong key falls back to [Encrypted: vault:v2:...]")

	// Decrypt with truncated armored string
	truncated_armored := enc_title[:20]
	trunc_json := fmt.tprintf(`{{"ok":true,"data":{{"issue_id":"iss_trunc","title":"%s"}}}}`, truncated_armored)
	fallback_trunc := ctl_decrypt_issues_json(trunc_json, tkr(TEST_ISSUE_VAULT_KEY), true, context.temp_allocator)

	expected_trunc_fallback := fmt.tprintf("[Encrypted: %s]", truncated_armored)
	testing.expect(t, strings.contains(fallback_trunc, expected_trunc_fallback), "truncated payload falls back to [Encrypted: vault:v2:...]")
}
