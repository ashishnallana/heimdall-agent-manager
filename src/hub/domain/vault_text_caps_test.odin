package domain

import "core:strings"
import "core:testing"

// ── REQ-VCAP-5 regression tests for iss_18d940db15f9accb ─────────────────────
//
// The bug: length caps on vault-encrypted text were enforced against the
// ARMORED value, so a caller whose PLAINTEXT was within the documented limit was
// rejected at roughly 74% of it, with an error naming no number.
//
// Each of the three affected sites is covered by three cases:
//   (a) plaintext exactly at the cap is ACCEPTED
//   (b) an armored value whose plaintext was exactly at the cap is ACCEPTED
//       (this is the reported regression; it fails under the old `len(v) > cap`)
//   (c) an over-cap value is REJECTED and the message carries BOTH numbers.

@(private = "file")
repeat_bytes :: proc(n: int) -> string {
	return strings.repeat("a", n, context.temp_allocator)
}

// fake_armored builds a value with the real wire SHAPE and the exact byte
// length a genuine ciphertext of this plaintext would have. The cap is a pure
// byte-length check, so shape+length is all that matters here; round-tripping
// real AES-GCM is covered by src/lib/vault/vault_test.odin.
@(private = "file")
fake_armored :: proc(plaintext_len: int) -> string {
	payload := 4 * ((plaintext_len + VAULT_HEADER_BYTES + 2) / 3)
	return strings.concatenate(
		{VAULT_ARMOR_PREFIX, "e4294967295:", strings.repeat("A", payload, context.temp_allocator)},
		context.temp_allocator,
	)
}

@(test)
test_vault_armored_max_bytes_matches_wire_overhead :: proc(t: ^testing.T) {
	// Values derived in vault_text_caps.odin (max 10-digit epoch header).
	testing.expect_value(t, vault_armored_max_bytes(4000), 5393)
	testing.expect_value(t, vault_armored_max_bytes(120), 221)
	testing.expect_value(t, vault_armored_max_bytes(0), 21 + 40)
	// A real armored value of an at-cap plaintext must fit the derived budget
	// exactly -- not one byte over, or the cap still rejects a legal value.
	testing.expect_value(t, len(fake_armored(4000)), 5393)
	testing.expect_value(t, len(fake_armored(120)), 221)
}

@(test)
test_is_vault_armored_requires_prefix_not_substring :: proc(t: ^testing.T) {
	testing.expect(t, is_vault_armored("vault:v2:e1:AQID"), "prefix must be detected")
	testing.expect(t, !is_vault_armored("vault:v1:AQID"), "v1 is dead: not armored")
	testing.expect(t, !is_vault_armored(""), "empty is not armored")
	testing.expect(t, !is_vault_armored("plain title"), "plaintext is not armored")
	// A mid-string marker must NOT grant the inflated budget, or any caller
	// could bypass the plaintext cap by embedding the marker.
	testing.expect(
		t,
		!is_vault_armored(strings.concatenate({"prefix ", VAULT_ARMOR_PREFIX, "AQID"}, context.temp_allocator)),
		"a mid-string vault marker must not count as armored",
	)
	testing.expect_value(t, text_cap_limit_bytes("plain", 120), 120)
	testing.expect_value(t, text_cap_limit_bytes("vault:v2:e1:AQID", 120), 221)
}

// ── Site 1: chain description (taskchain_service.odin set_own_chain_description)

@(test)
test_chain_description_plaintext_at_cap_accepted :: proc(t: ^testing.T) {
	err := validate_capped_text("chain description", repeat_bytes(CHAIN_DESCRIPTION_MAX_BYTES), CHAIN_DESCRIPTION_MAX_BYTES)
	testing.expect_value(t, err.code, Error_Code.None)
}

@(test)
test_chain_description_armored_at_cap_accepted :: proc(t: ^testing.T) {
	// THE REPORTED REGRESSION: 4000 bytes of plaintext arrive as 5393 armored
	// bytes and were rejected against a cap of 4000.
	armored := fake_armored(CHAIN_DESCRIPTION_MAX_BYTES)
	testing.expect(t, len(armored) > CHAIN_DESCRIPTION_MAX_BYTES, "armored value must exceed the plaintext cap (else the test proves nothing)")
	err := validate_capped_text("chain description", armored, CHAIN_DESCRIPTION_MAX_BYTES)
	testing.expect_value(t, err.code, Error_Code.None)
}

@(test)
test_chain_description_over_cap_rejected_with_numbers :: proc(t: ^testing.T) {
	// Plaintext one byte over.
	plain := repeat_bytes(CHAIN_DESCRIPTION_MAX_BYTES + 1)
	err := validate_capped_text("chain description", plain, CHAIN_DESCRIPTION_MAX_BYTES)
	testing.expect_value(t, err.code, Error_Code.Validation_Failed)
	testing.expect(t, strings.contains(err.message, "4001"), "message must name the actual length")
	testing.expect(t, strings.contains(err.message, "4000"), "message must name the effective limit")

	// Armored one byte over its inflated budget.
	over := strings.concatenate({fake_armored(CHAIN_DESCRIPTION_MAX_BYTES), "A"}, context.temp_allocator)
	armored_err := validate_capped_text("chain description", over, CHAIN_DESCRIPTION_MAX_BYTES)
	testing.expect_value(t, armored_err.code, Error_Code.Validation_Failed)
	testing.expect(t, strings.contains(armored_err.message, "5394"), "message must name the actual armored length")
	testing.expect(t, strings.contains(armored_err.message, "5393"), "message must name the effective armored limit")
	testing.expect(t, strings.contains(armored_err.message, "4000"), "message must name the plaintext budget")
	testing.expect(t, strings.contains(armored_err.message, "encrypted"), "message must say the value is encrypted")
}

// ── Site 2: chain title (taskchain_service.odin set_own_chain_title) ─────────

@(test)
test_chain_title_plaintext_at_cap_accepted :: proc(t: ^testing.T) {
	err := validate_capped_text("chain title", repeat_bytes(CHAIN_TITLE_MAX_BYTES), CHAIN_TITLE_MAX_BYTES)
	testing.expect_value(t, err.code, Error_Code.None)
}

@(test)
test_chain_title_armored_at_cap_accepted :: proc(t: ^testing.T) {
	// Latent-but-real before the fix: any chain title over ~83 plaintext bytes
	// was already rejected, because armored_len(84) == 125 > 120.
	short := fake_armored(84)
	testing.expect(t, len(short) > CHAIN_TITLE_MAX_BYTES, "an 84-byte plaintext title must already exceed the raw cap once armored")
	testing.expect_value(t, validate_capped_text("chain title", short, CHAIN_TITLE_MAX_BYTES).code, Error_Code.None)

	err := validate_capped_text("chain title", fake_armored(CHAIN_TITLE_MAX_BYTES), CHAIN_TITLE_MAX_BYTES)
	testing.expect_value(t, err.code, Error_Code.None)
}

@(test)
test_chain_title_over_cap_rejected_with_numbers :: proc(t: ^testing.T) {
	err := validate_capped_text("chain title", repeat_bytes(CHAIN_TITLE_MAX_BYTES + 30), CHAIN_TITLE_MAX_BYTES)
	testing.expect_value(t, err.code, Error_Code.Validation_Failed)
	testing.expect(t, strings.contains(err.message, "150"), "message must name the actual length")
	testing.expect(t, strings.contains(err.message, "120"), "message must name the effective limit")

	over := strings.concatenate({fake_armored(CHAIN_TITLE_MAX_BYTES), "A"}, context.temp_allocator)
	armored_err := validate_capped_text("chain title", over, CHAIN_TITLE_MAX_BYTES)
	testing.expect_value(t, armored_err.code, Error_Code.Validation_Failed)
	testing.expect(t, strings.contains(armored_err.message, "222"), "message must name the actual armored length")
	testing.expect(t, strings.contains(armored_err.message, "221"), "message must name the effective armored limit")
	testing.expect(t, strings.contains(armored_err.message, "120"), "message must name the plaintext budget")
}

// ── Site 3: conversation title (content_service.odin update_conversation_title)

@(test)
test_conversation_title_plaintext_at_cap_accepted :: proc(t: ^testing.T) {
	err := validate_capped_text("conversation title", repeat_bytes(CONVERSATION_TITLE_MAX_BYTES), CONVERSATION_TITLE_MAX_BYTES)
	testing.expect_value(t, err.code, Error_Code.None)
}

@(test)
test_conversation_title_armored_at_cap_accepted :: proc(t: ^testing.T) {
	armored := fake_armored(CONVERSATION_TITLE_MAX_BYTES)
	testing.expect(t, len(armored) > CONVERSATION_TITLE_MAX_BYTES, "armored value must exceed the plaintext cap")
	err := validate_capped_text("conversation title", armored, CONVERSATION_TITLE_MAX_BYTES)
	testing.expect_value(t, err.code, Error_Code.None)
}

@(test)
test_conversation_title_over_cap_rejected_with_numbers :: proc(t: ^testing.T) {
	err := validate_capped_text("conversation title", repeat_bytes(CONVERSATION_TITLE_MAX_BYTES + 1), CONVERSATION_TITLE_MAX_BYTES)
	testing.expect_value(t, err.code, Error_Code.Validation_Failed)
	testing.expect(t, strings.contains(err.message, "121"), "message must name the actual length")
	testing.expect(t, strings.contains(err.message, "120"), "message must name the effective limit")
	testing.expect(t, strings.contains(err.message, "conversation title"), "message must name the field")

	over := strings.concatenate({fake_armored(CONVERSATION_TITLE_MAX_BYTES), "A"}, context.temp_allocator)
	armored_err := validate_capped_text("conversation title", over, CONVERSATION_TITLE_MAX_BYTES)
	testing.expect_value(t, armored_err.code, Error_Code.Validation_Failed)
	testing.expect(t, strings.contains(armored_err.message, "222"), "message must name the actual armored length")
	testing.expect(t, strings.contains(armored_err.message, "221"), "message must name the effective armored limit")
}

// Guard against the OLD predicate silently coming back: for every site, an
// at-cap armored value must be rejected by `len(v) > cap` and accepted by the
// armor-aware check. If this ever passes trivially, the fix has regressed.
@(test)
test_old_raw_length_predicate_would_reject_every_site :: proc(t: ^testing.T) {
	caps := [3]int{CHAIN_DESCRIPTION_MAX_BYTES, CHAIN_TITLE_MAX_BYTES, CONVERSATION_TITLE_MAX_BYTES}
	for cap_bytes, i in caps {
		armored := fake_armored(cap_bytes)
		testing.expectf(t, len(armored) > cap_bytes, "site %d: old predicate len(v) > cap must have rejected this legal value", i)
		testing.expectf(
			t,
			validate_capped_text("field", armored, cap_bytes).code == .None,
			"site %d: armor-aware check must accept an at-cap armored value",
			i,
		)
	}
}

@(test)
test_vault_token_header_helpers :: proc(t: ^testing.T) {
	testing.expect_value(t, vault_token_prefix_len("vault:v2:e12:QUJD"), len("vault:v2:e12:"))
	ep, ok := vault_token_epoch("vault:v2:e12:QUJD")
	testing.expect(t, ok && ep == 12)
	testing.expect_value(t, vault_token_prefix_len("vault:v1:QUJD"), 0)
	testing.expect_value(t, vault_token_prefix_len("ENC:v1:QUJD"), 0)
	testing.expect_value(t, vault_token_prefix_len("vault:v2:e0:QUJD"), 0)
	testing.expect_value(t, vault_token_prefix_len("vault:v2:e01:QUJD"), 0)
	testing.expect_value(t, vault_token_prefix_len("vault:v2:"), 0)
	testing.expect(t, contains_vault_token("x vault:v2:e1:QUJD y"))
	testing.expect(t, !contains_vault_token("x vault:v1:QUJD y"))
}
