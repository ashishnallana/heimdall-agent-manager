package vault

import "core:crypto/ecdsa"
import "core:strings"
import "core:testing"

@(private = "file")
TEST_KEY :: [32]byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32}

@(private = "file")
test_vid :: proc() -> Vault_Id {
	id, _ := vault_id_from_hex("0123456789abcdef")
	return id
}

@(private = "file")
seal_n :: proc(n: int, epoch: u32 = 7) -> string {
	pt := make([]byte, n, context.temp_allocator)
	for i in 0 ..< n do pt[i] = byte(i * 31 + 7)
	key := TEST_KEY
	nonce: [NONCE_BYTES]byte
	tok, ok := seal_with_nonce(pt, key[:], test_vid(), epoch, nonce[:], context.temp_allocator)
	assert(ok)
	return tok
}

// Feeding in odd-sized chunks must agree with the one-shot check and with the
// keyed parser's notion of a canonical token.
@(test)
test_blind_token_check_streams_and_counts_plaintext :: proc(t: ^testing.T) {
	for n in ([]int{0, 1, 2, 3, 4, 100, 4097}) {
		tok := seal_n(n)
		c: Blind_Token_Check
		b := transmute([]byte)tok
		for off := 0; off < len(b); off += 7 do blind_token_check_update(&c, b[off:min(off + 7, len(b))])
		info, ok := blind_token_check_finish(&c)
		testing.expectf(t, ok, "n=%d", n)
		testing.expect_value(t, info.plaintext_bytes, n)
		testing.expect_value(t, info.epoch, u32(7))
		testing.expect_value(t, info.vault_id, test_vid())
		testing.expect_value(t, info.token_bytes, len(tok))
		_, _, payload, res := envelope_parse(tok, context.temp_allocator)
		testing.expect_value(t, res, Open_Result.Ok)
		testing.expect_value(t, len(payload), info.payload_bytes)
	}
}

@(test)
test_blind_token_check_rejects_non_canonical :: proc(t: ^testing.T) {
	good := seal_n(10)
	cases := []string{
		"",
		"vault:v2:",
		"plain text",
		strings.concatenate({good, good}, context.temp_allocator),       // two tokens
		strings.concatenate({good, "\n"}, context.temp_allocator),       // trailing byte
		strings.concatenate({good[:len(good) - 1]}, context.temp_allocator), // truncated
		"vault:v2:0123456789ABCDEF:e7:AAAA",                             // upper-case vault id
		"vault:v2:0123456789abcdef:e0:AAAA",                             // epoch 0
		"vault:v2:0123456789abcdef:e07:AAAA",                            // leading zero
		"vault:v2:0123456789abcdef:e12345678901:AAAA",                   // 11 epoch digits
		"vault:v2:0123456789abcdef:e9999999999:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", // epoch > u32
		"vault:v2:0123456789abcdef:e7:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA-_", // url-safe alphabet
		"vault:v2:0123456789abcdef:e7:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB==", // non-zero pad bits
		"vault:v2:0123456789abcdef:e7:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=A=", // misplaced pad
		"vault:v2:0123456789abcdef:e7:AAAA",                             // payload < nonce+tag
	}
	for s, i in cases {
		_, ok := blind_token_check_string(s)
		testing.expectf(t, !ok, "case %d accepted: %q", i, s)
	}
}

// The 15 MiB blind limit is exact: one byte over changes the arithmetic result.
@(test)
test_blind_plaintext_length_arithmetic_at_15_mib :: proc(t: ^testing.T) {
	LIMIT :: 15 * 1024 * 1024
	for n in ([]int{LIMIT - 1, LIMIT, LIMIT + 1}) {
		header := "vault:v2:0123456789abcdef:e7:"
		chars := 4 * ((n + HEADER_BYTES + 2) / 3)
		pad := (3 - (n + HEADER_BYTES) % 3) % 3
		c: Blind_Token_Check
		blind_token_check_update(&c, transmute([]byte)header)
		chunk: [4096]byte
		for i in 0 ..< len(chunk) do chunk[i] = 'A'
		left := chars - pad
		for left > 0 {
			k := min(left, len(chunk))
			blind_token_check_update(&c, chunk[:k])
			left -= k
		}
		for _ in 0 ..< pad do blind_token_check_update(&c, transmute([]byte)string("="))
		info, ok := blind_token_check_finish(&c)
		testing.expectf(t, ok, "n=%d", n)
		testing.expect_value(t, info.plaintext_bytes, n)
		testing.expect_value(t, info.token_bytes, blind_armored_len(n, len(header)))
	}
	// The design's 15 MiB overhead numbers (§7).
	testing.expect_value(t, blind_armored_len(LIMIT, BLIND_MAX_HEADER_LEN), 20_971_598)
	testing.expect_value(t, blind_armored_len(LIMIT, len("vault:v2:0123456789abcdef:e7:")), 20_971_589)
}

@(private = "file")
rep :: proc(s, old, new: string) -> string {
	out, _ := strings.replace(s, old, new, 1, context.temp_allocator)
	return out
}

@(private = "file")
test_seal_receipt :: proc() -> Transfer_Seal_Receipt {
	h := strings.repeat("a", 64, context.temp_allocator)
	return {owner_user_id = "user_1", vault_id = "0123456789abcdef", epoch = 7, transfer_id = "xfr_1", artifact_id = "art_1",
		kind = "html-bundle", content_type = "application/zip", ciphertext_bytes = 20971589, ciphertext_sha256 = h,
		name_token_sha256 = h, description_token_sha256 = h, attestation_token_sha256 = h, device_id = "dev_a", issued_ms = 1700000000000}
}

@(test)
test_transfer_receipt_round_trip_and_canonical_only :: proc(t: ^testing.T) {
	r := test_seal_receipt()
	text, ok := transfer_seal_statement(r, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect(t, strings.has_prefix(text, "heimdall-artifact-transfer-receipt/v1\nseal\nuser_1\n0123456789abcdef\ne7\nxfr_1\nart_1\n"))
	back, pok := transfer_seal_receipt_parse(text)
	testing.expect(t, pok)
	testing.expect_value(t, back, r)
	// Non-canonical spellings and smuggled lines are refused.
	_, bad0 := transfer_seal_receipt_parse(strings.concatenate({text, "\n"}, context.temp_allocator))
	testing.expect(t, !bad0)
	_, bad1 := transfer_seal_receipt_parse(rep(text, "\ne7\n", "\ne07\n"))
	testing.expect(t, !bad1)
	_, bad2 := transfer_seal_receipt_parse(rep(text, "\nseal\n", "\nopen\n"))
	testing.expect(t, !bad2)
	r2 := r; r2.kind = "html bundle"
	_, bad3 := transfer_seal_statement(r2, context.temp_allocator)
	testing.expect(t, !bad3)
	r3 := r; r3.ciphertext_sha256 = strings.repeat("A", 64, context.temp_allocator)
	_, bad4 := transfer_seal_statement(r3, context.temp_allocator)
	testing.expect(t, !bad4)

	o := Transfer_Open_Receipt{owner_user_id = "user_1", vault_id = "0123456789abcdef", epoch = 7, transfer_id = "xfr_2", artifact_id = "art_1",
		verified = false, ciphertext_bytes = 99, ciphertext_sha256 = r.ciphertext_sha256, device_id = "dev_b", issued_ms = 5}
	otext, ook := transfer_open_statement(o, context.temp_allocator)
	testing.expect(t, ook)
	testing.expect(t, strings.contains(otext, "\nunverified\n"))
	oback, opk := transfer_open_receipt_parse(otext)
	testing.expect(t, opk)
	testing.expect_value(t, oback, o)
	_, obad := transfer_open_receipt_parse(rep(otext, "\nunverified\n", "\nmaybe\n"))
	testing.expect(t, !obad)
}

@(test)
test_transfer_receipt_verify_requires_current_trusted_sealer :: proc(t: ^testing.T) {
	priv: ecdsa.Private_Key
	defer ecdsa.private_key_clear(&priv)
	testing.expect(t, p256_private_key_generate(&priv))
	raw: [P256_PUBLIC_KEY_BYTES]byte
	ecdsa.private_key_public_bytes(&priv, raw[:])
	pub_hex := hex_encode_lower(raw[:], context.temp_allocator)

	text, _ := transfer_seal_statement(test_seal_receipt(), context.temp_allocator)
	sig, sok := sign_p256(&priv, transmute([]byte)text)
	testing.expect(t, sok)
	sig_json, _ := signature_object(&sig, context.temp_allocator)

	dir: Verified_Directory
	dir.trusted = make(map[string]Verified_Directory_Device, context.temp_allocator)
	dir.trusted["dev_a"] = {id = "dev_a", kind = "bridge", sign_alg = SIGN_ALG_ECDSA_P256_SHA256, sign_public_key = pub_hex}
	dir.trusted["dev_r"] = {id = "dev_r", kind = "recovery", sign_alg = SIGN_ALG_ECDSA_P256_SHA256, sign_public_key = pub_hex}
	testing.expect_value(t, transfer_receipt_verify(&dir, "dev_a", text, sig_json), Transfer_Receipt_Error.None)
	// Tampered statement, unknown/revoked device, wrong kind.
	tampered := rep(text, "art_1", "art_2")
	testing.expect_value(t, transfer_receipt_verify(&dir, "dev_a", tampered, sig_json), Transfer_Receipt_Error.Bad_Signature)
	testing.expect_value(t, transfer_receipt_verify(&dir, "dev_x", text, sig_json), Transfer_Receipt_Error.Untrusted_Device)
	testing.expect_value(t, transfer_receipt_verify(&dir, "dev_r", text, sig_json), Transfer_Receipt_Error.Kind_Not_Allowed)
	delete_key(&dir.trusted, "dev_a")
	testing.expect_value(t, transfer_receipt_verify(&dir, "dev_a", text, sig_json), Transfer_Receipt_Error.Untrusted_Device)
	testing.expect_value(t, transfer_receipt_verify(nil, "dev_a", text, sig_json), Transfer_Receipt_Error.Malformed)
}
