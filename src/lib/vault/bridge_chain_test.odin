package vault

import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:strings"
import "core:testing"

// Shared vector: tests/fixtures/vault_v2_vectors.json "bridge_chain" — the
// `chain_proof` the UI's buildBridgeChainProof sends (tools/vault_vectors).

@(private = "file")
Chain_Fixture :: struct {
	bc:     json.Object,
	owner:  string,
	bridge: string,
	text:   string,
	kr:     Vault_Keyring,
}

@(private = "file")
cstr :: proc(o: json.Object, k: string) -> string { return string(o[k].(json.String)) }

@(private = "file")
cunhex :: proc(s: string) -> []byte {
	out := make([]byte, len(s) / 2, context.temp_allocator)
	_ = hex_decode_into(out, s)
	return out
}

@(private = "file")
load_chain :: proc(t: ^testing.T) -> Chain_Fixture {
	v, err := json.parse_string(VECTORS_JSON, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	testing.expect(t, err == nil)
	bc := v.(json.Object)["bridge_chain"].(json.Object)
	kr, ok := keyring_parse(cunhex(cstr(bc, "keyring_hex")))
	testing.expect(t, ok)
	return Chain_Fixture{bc = bc, owner = cstr(bc, "user_id"), bridge = cstr(bc, "bridge_identity_public_key"), text = cstr(bc, "proof_json"), kr = kr}
}

@(private = "file")
check :: proc(f: ^Chain_Fixture, text: string, pinned: ^Root_Pin = nil, bridge := "", kr: ^Vault_Keyring = nil) -> Chain_Error {
	v, err := json.parse_string(text, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if err != nil do return .Malformed
	_, e := bridge_chain_verify(v, f.owner, bridge if bridge != "" else f.bridge, kr if kr != nil else &f.kr, pinned)
	return e
}

@(private = "file")
swap :: proc(s, old, new: string) -> string {
	out, _ := strings.replace(s, old, new, 1, context.temp_allocator)
	return out
}

@(private = "file")
json_quote :: proc(s: string) -> string {
	q, _ := strings.replace_all(s, "\n", "\\n", context.temp_allocator)
	q2, _ := strings.replace_all(q, `"`, `\"`, context.temp_allocator)
	return q2
}

@(test)
test_bridge_chain_vector_verifies_and_pins_root :: proc(t: ^testing.T) {
	f := load_chain(t)
	defer keyring_wipe(&f.kr)
	v, _ := json.parse_string(f.text, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	root, err := bridge_chain_verify(v, f.owner, f.bridge, &f.kr, nil)
	testing.expect_value(t, err, Chain_Error.None)
	fp, _ := account_fingerprint(&root, context.temp_allocator)
	testing.expect_value(t, fp, cstr(f.bc, "account_fingerprint"))
	// Pinned: the same root passes, any other root is refused.
	testing.expect_value(t, check(&f, f.text, &root), Chain_Error.None)
	other := root
	other.sign_pub[64] ~= 1
	testing.expect_value(t, check(&f, f.text, &other), Chain_Error.Root_Mismatch)
}

@(test)
test_bridge_chain_rejects_bad_proofs :: proc(t: ^testing.T) {
	f := load_chain(t)
	defer keyring_wipe(&f.kr)
	p := f.bc["proof"].(json.Object)
	// The subject approval's issuer chain [B] as JSON text (statements hold no ']').
	sa_key := `"issuer_chain":[{`
	start := strings.index(f.text, sa_key) + len(`"issuer_chain":`)
	b_arr := f.text[start:start + strings.index(f.text[start:], "]") + 1]

	testing.expect_value(t, check(&f, swap(f.text, `"v":2`, `"v":1`)), Chain_Error.Malformed)
	testing.expect_value(t, check(&f, "{}"), Chain_Error.Malformed)
	// Another account, another bridge, a substituted current key.
	testing.expect_value(t, check(&f, swap(f.text, `"user_id":"usr_0123456789abcdef"`, `"user_id":"usr_other"`)), Chain_Error.Wrong_Account)
	b := f.bridge
	other_bridge := strings.concatenate({b[:len(b) - 2], "00" if b[len(b) - 2:] != "00" else "01"}, context.temp_allocator)
	testing.expect_value(t, check(&f, f.text, nil, other_bridge), Chain_Error.Not_This_Bridge)
	swapped := f.kr
	swapped.entries[swapped.count - 1].key[0] ~= 0xff
	testing.expect_value(t, check(&f, f.text, nil, "", &swapped), Chain_Error.Commit_Mismatch)
	keyring_wipe(&swapped)
	// An OLDER epoch key is attested too: a substituted epoch-1 key is refused.
	old_swapped := f.kr
	old_swapped.entries[0].key[0] ~= 0xff
	testing.expect_value(t, check(&f, f.text, nil, "", &old_swapped), Chain_Error.Commit_Mismatch)
	keyring_wipe(&old_swapped)
	// A keyring whose current epoch is 1: the proof carries two epochs.
	single, _ := keyring_from_single_key(f.owner, 1, f.kr.entries[0].key[:])
	testing.expect_value(t, check(&f, f.text, nil, "", &single), Chain_Error.Epoch_Mismatch)
	keyring_wipe(&single)
	// The bridge approver's chain is dropped: B is not the root.
	testing.expect_value(t, check(&f, swap(f.text, strings.concatenate({`"issuer_chain":`, b_arr}, context.temp_allocator), `"issuer_chain":[]`)), Chain_Error.Link_Invalid)
	// Tampered epoch-2 carrier (the revoke; still canonical): signature fails.
	testing.expect_value(t, check(&f, swap(f.text, "issued_at_ms=1760000004000", "issued_at_ms=1760000004002")), Chain_Error.Bad_Signature)
	// Epoch 2 carried by a rotate signed by B, with no issuer chain for B.
	e2b := f.bc["epoch2_by_b"].(json.Object)
	carriers := p["epochs"].(json.Array)
	ep := carriers[1].(json.Object)
	by_b := swap(f.text, json_quote(cstr(ep, "statement")), json_quote(cstr(e2b, "statement")))
	by_b = swap(by_b, json_quote(cstr(ep, "signature")), json_quote(cstr(e2b, "signature")))
	testing.expect_value(t, check(&f, by_b), Chain_Error.Link_Invalid)
	// …and with B's chain it is accepted (B is an approver).
	e2b_tail := strings.concatenate({json_quote(cstr(e2b, "signature")), `","issuer_chain":[]`}, context.temp_allocator)
	with_chain := swap(by_b, e2b_tail, strings.concatenate({json_quote(cstr(e2b, "signature")), `","issuer_chain":`, b_arr}, context.temp_allocator))
	testing.expect_value(t, check(&f, with_chain), Chain_Error.None)

	// A bridge in the issuer chain may not approve: A approves bridge2, bridge2 signs epoch 2.
	keys := f.bc["private_keys"].(json.Object)
	sign :: proc(t: ^testing.T, priv_hex: string, st: ^Statement) -> (string, string) {
		priv: ecdsa.Private_Key
		defer ecdsa.private_key_clear(&priv)
		testing.expect(t, ecdsa.private_key_set_bytes(&priv, .SECP256R1, cunhex(priv_hex)))
		text, _ := statement_canonical(st, context.temp_allocator)
		sig, _ := sign_p256(&priv, transmute([]byte)text)
		obj, _ := signature_object(&sig, context.temp_allocator)
		return text, obj
	}
	b2_scalar := "0101010101010101010101010101010101010101010101010101010101010101"
	b2: ecdsa.Private_Key
	testing.expect(t, ecdsa.private_key_set_bytes(&b2, .SECP256R1, cunhex(b2_scalar)))
	raw: [P256_PUBLIC_KEY_BYTES]byte
	ecdsa.private_key_public_bytes(&b2, raw[:])
	ecdsa.private_key_clear(&b2)
	b2_pub := hex_encode_lower(raw[:], context.temp_allocator)
	b2_id, _ := device_id_from_sign_pub(b2_pub, context.temp_allocator)
	root_id := cstr(p, "root_device_id")
	ap := Statement{type = "approve", user_id = f.owner, seq = "4", prev_hash = strings.repeat("a", 64, context.temp_allocator), issuer_device_id = root_id, issued_at_ms = "1",
		subject_device_id = b2_id, subject_kind = "bridge", subject_sign_pub = b2_pub, subject_sign_alg = SIGN_ALG_ECDSA_P256_SHA256, subject_label_b64 = "Yg", epoch = "1"}
	ap_text, ap_sig := sign(t, cstr(keys, "root_a"), &ap)
	est, _ := statement_parse(cstr(e2b, "statement"))
	est.issuer_device_id = b2_id
	e_text, e_sig := sign(t, b2_scalar, &est)
	bridge_link := strings.concatenate({`[{"device_id":"`, b2_id, `","kind":"bridge","sign_alg":"ecdsa-p256-sha256","sign_public_key":"`, b2_pub,
		`","approval_statement":"`, json_quote(ap_text), `","approval_signature":"`, json_quote(ap_sig), `"}]`}, context.temp_allocator)
	by_bridge := swap(f.text, json_quote(cstr(ep, "statement")), json_quote(e_text))
	by_bridge = swap(by_bridge, json_quote(cstr(ep, "signature")), json_quote(e_sig))
	by_bridge = swap(by_bridge, strings.concatenate({json_quote(e_sig), `","issuer_chain":[]`}, context.temp_allocator), strings.concatenate({json_quote(e_sig), `","issuer_chain":`, bridge_link}, context.temp_allocator))
	testing.expect_value(t, check(&f, by_bridge), Chain_Error.Link_Invalid)
}

// The directory log vector: contiguous seq from 1, each prev_hash = SHA-256 of the
// previous op's canonical statement, and the head hash.
@(test)
test_directory_log_vector_links :: proc(t: ^testing.T) {
	f := load_chain(t)
	defer keyring_wipe(&f.kr)
	log := f.bc["log"].(json.Array)
	prev := ""
	for e, i in log {
		eo := e.(json.Object)
		text := cstr(eo, "statement")
		st, ok := statement_parse(text)
		testing.expect(t, ok)
		testing.expectf(t, log_link_ok(&st, u64(i + 1), prev), "log entry %d links", i + 1)
		h := log_entry_hash(text, context.temp_allocator)
		testing.expect_value(t, h, cstr(eo, "hash"))
		// The same statement does not fit any other slot.
		testing.expect(t, !log_link_ok(&st, u64(i + 2), prev))
		prev = h
	}
	testing.expect_value(t, prev, cstr(f.bc, "head_hash"))
}