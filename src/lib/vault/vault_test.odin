package vault

import "core:crypto/aes"
import "core:crypto/ecdh"
import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:strings"
import "core:testing"

VECTORS_JSON :: #load("../../../tests/fixtures/vault_v2_vectors.json", string)

@(private = "file")
load_vectors :: proc(t: ^testing.T) -> json.Object {
	v, err := json.parse_string(VECTORS_JSON, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	testing.expect(t, err == nil, "vectors parse")
	return v.(json.Object)
}

@(private = "file")
obj :: proc(o: json.Object, k: string) -> json.Object { return o[k].(json.Object) }
@(private = "file")
str :: proc(o: json.Object, k: string) -> string { return string(o[k].(json.String)) }
@(private = "file")
num :: proc(o: json.Object, k: string) -> i64 { return i64(o[k].(json.Integer)) }
@(private = "file")
arr :: proc(o: json.Object, k: string) -> json.Array { return o[k].(json.Array) }

@(private = "file")
unhex :: proc(s: string) -> []byte {
	out := make([]byte, len(s) / 2, context.temp_allocator)
	_ = hex_decode_into(out, s)
	return out
}

@(private = "file")
vector_keyring :: proc(t: ^testing.T, root: json.Object) -> Vault_Keyring {
	kr, ok := keyring_parse(unhex(str(obj(root, "keyring"), "hex")))
	testing.expect(t, ok, "vector keyring parses")
	return kr
}

@(test)
test_envelope_vectors_open_and_reseal :: proc(t: ^testing.T) {
	root := load_vectors(t)
	kr := vector_keyring(t, root)
	defer keyring_wipe(&kr)
	for c in arr(obj(root, "envelope"), "cases") {
		co := c.(json.Object)
		token := str(co, "token")
		plain, res := open(token, &kr, context.temp_allocator)
		testing.expectf(t, res == .Ok, "%s opens (got %v)", str(co, "name"), res)
		testing.expect_value(t, plain, str(co, "plaintext"))
		epoch := u32(num(co, "epoch"))
		key, _ := keyring_key_for_epoch(&kr, epoch)
		resealed, ok := seal_with_nonce(transmute([]byte)str(co, "plaintext"), key, epoch, unhex(str(co, "nonce")), context.temp_allocator)
		testing.expect(t, ok)
		testing.expect_value(t, resealed, token)
		aad_buf: [64]byte
		testing.expect_value(t, string(envelope_aad(epoch, aad_buf[:])), str(co, "aad"))
	}
}

@(test)
test_envelope_negative_vectors :: proc(t: ^testing.T) {
	root := load_vectors(t)
	kr := vector_keyring(t, root)
	defer keyring_wipe(&kr)
	for c in arr(obj(root, "envelope"), "negative") {
		co := c.(json.Object)
		name, kind, token := str(co, "name"), str(co, "kind"), str(co, "token")
		_, res := open(token, &kr, context.temp_allocator)
		want: Open_Result
		switch kind {
		case "auth":          want = .Auth_Failed
		case "unknown_epoch": want = .Unknown_Epoch
		case "malformed":     want = .Malformed
		case "not_armored":   want = .Not_Armored
		}
		testing.expectf(t, res == want, "%s: want %v got %v", name, want, res)
	}
}

@(test)
test_envelope_embedded_replace :: proc(t: ^testing.T) {
	root := load_vectors(t)
	kr := vector_keyring(t, root)
	defer keyring_wipe(&kr)
	emb := obj(obj(root, "envelope"), "embedded")
	out := replace_embedded_tokens(str(emb, "text"), &kr, "LOCKED", FAILED_MARKER, context.temp_allocator)
	testing.expect_value(t, out, str(emb, "decrypted_with_locked_marker_LOCKED"))
	// No keyring at all: every v2 token is locked, the v1 token stays opaque.
	locked := replace_embedded_tokens(str(emb, "text"), nil, "LOCKED", FAILED_MARKER, context.temp_allocator)
	testing.expect(t, !strings.contains(locked, "vault:v2:e"))
	testing.expect(t, strings.contains(locked, "vault:v1:"))
	testing.expect(t, strings.contains(locked, "bare vault:v2: end"))
	// Empty locked marker keeps tokens verbatim.
	kept := replace_embedded_tokens(str(emb, "text"), nil, "", FAILED_MARKER, context.temp_allocator)
	testing.expect_value(t, kept, str(emb, "text"))
}

@(test)
test_envelope_round_trip_across_epochs_and_current_epoch_seal :: proc(t: ^testing.T) {
	root := load_vectors(t)
	kr := vector_keyring(t, root)
	defer keyring_wipe(&kr)
	tok, ok := seal_string("cross-epoch", &kr, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect(t, strings.has_prefix(tok, "vault:v2:e2:"), "seals under the current epoch")
	plain, res := open(tok, &kr, context.temp_allocator)
	testing.expect(t, res == .Ok && plain == "cross-epoch")
	// A keyring that only holds epoch 1 shows epoch-2 content as locked, never throws.
	k1, _ := keyring_key_for_epoch(&kr, 1)
	single, s_ok := keyring_from_single_key(keyring_user_id(&kr), 1, k1)
	testing.expect(t, s_ok)
	_, res2 := open(tok, &single, context.temp_allocator)
	testing.expect(t, res2 == .Unknown_Epoch)
	testing.expect_value(t, replace_embedded_tokens(tok, &single, "LOCK", FAILED_MARKER, context.temp_allocator), "LOCK")
}

@(test)
test_envelope_oversized_rejected :: proc(t: ^testing.T) {
	big := strings.concatenate({"vault:v2:e1:", strings.repeat("A", MAX_B64_LEN + 4, context.temp_allocator)}, context.temp_allocator)
	_, _, res := envelope_parse(big, context.temp_allocator)
	testing.expect(t, res == .Malformed)
}

@(test)
test_seal_fails_closed_without_randomness :: proc(t: ^testing.T) {
	root := load_vectors(t)
	kr := vector_keyring(t, root)
	defer keyring_wipe(&kr)
	tok, ok := seal(transmute([]byte)string("secret"), &kr, context.temp_allocator, "/nonexistent/heimdall-no-random")
	testing.expect(t, !ok, "seal must fail when the CSPRNG fails")
	testing.expect_value(t, tok, "")
	priv: ecdsa.Private_Key
	testing.expect(t, !p256_private_key_generate(&priv, "/nonexistent/heimdall-no-random"))
}

@(test)
test_keyring_vectors :: proc(t: ^testing.T) {
	root := load_vectors(t)
	ko := obj(root, "keyring")
	kr := vector_keyring(t, root)
	defer keyring_wipe(&kr)
	testing.expect_value(t, keyring_user_id(&kr), str(ko, "user_id"))
	testing.expect_value(t, kr.current_epoch, u32(num(ko, "current_epoch")))
	testing.expect_value(t, kr.count, 2)
	ser, ok := keyring_serialize(&kr, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, hex_encode_lower(ser, context.temp_allocator), str(ko, "hex"))
	_, uok := keyring_parse(unhex(str(ko, "hex")), str(ko, "user_id"))
	testing.expect(t, uok)
	big, bok := keyring_parse(unhex(str(ko, "max_64_hex")))
	testing.expect(t, bok, "64-epoch keyring is accepted")
	testing.expect(t, int(num(ko, "max_64_len")) <= KEYRING_MAX_BYTES && KEYRING_MAX_BYTES < 2560)
	keyring_wipe(&big)
	testing.expect_value(t, big.count, 0)
	for c in arr(ko, "negative") {
		co := c.(json.Object)
		expected := ""
		if e, has := co["expected_user_id"]; has do expected = string(e.(json.String))
		_, nok := keyring_parse(unhex(str(co, "hex")), expected)
		testing.expectf(t, !nok, "keyring negative %s must be rejected", str(co, "name"))
	}
}

@(test)
test_statement_vectors_and_signature :: proc(t: ^testing.T) {
	root := load_vectors(t)
	so := obj(root, "statement")
	f := obj(so, "fields")
	st := Statement{
		type = str(f, "type"), user_id = str(f, "user_id"), directory_version = str(f, "directory_version"),
		issuer_device_id = str(f, "issuer_device_id"), issued_at_ms = str(f, "issued_at_ms"),
		subject_device_id = str(f, "subject_device_id"), subject_kind = str(f, "subject_kind"),
		subject_sign_pub = str(f, "subject_sign_pub"), subject_ecdh_pub = str(f, "subject_ecdh_pub"),
		subject_sign_alg = str(f, "subject_sign_alg"), subject_wrap_alg = str(f, "subject_wrap_alg"),
		subject_label_b64 = str(f, "subject_label_b64"), epoch = str(f, "epoch"),
		epoch_commit = str(f, "epoch_commit"), wrap_sha256 = str(f, "wrap_sha256"),
	}
	canonical, ok := statement_canonical(&st, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, canonical, str(so, "canonical"))
	testing.expect(t, verify(SIGN_ALG_ECDSA_P256_SHA256, str(so, "issuer_public_key"), transmute([]byte)canonical, str(so, "signature_object")))
	// Odin's RFC 6979 signer reproduces the vector bytes exactly.
	priv: ecdsa.Private_Key
	testing.expect(t, ecdsa.private_key_set_bytes(&priv, .SECP256R1, unhex(str(so, "issuer_private_key"))))
	sig, s_ok := sign_p256(&priv, transmute([]byte)canonical)
	testing.expect(t, s_ok)
	obj_s, _ := signature_object(&sig, context.temp_allocator)
	testing.expect_value(t, obj_s, str(so, "signature_object"))
	// Tampered statement bytes fail.
	tampered := strings.concatenate({canonical, "x"}, context.temp_allocator)
	testing.expect(t, !verify(SIGN_ALG_ECDSA_P256_SHA256, str(so, "issuer_public_key"), transmute([]byte)tampered, str(so, "signature_object")))
	for bad in arr(so, "invalid_signature_objects") {
		testing.expectf(t, !verify(SIGN_ALG_ECDSA_P256_SHA256, str(so, "issuer_public_key"), transmute([]byte)canonical, string(bad.(json.String))), "bad sig object %s", string(bad.(json.String)))
	}
	for c in arr(so, "invalid_values") {
		co := c.(json.Object)
		bad := st
		switch str(co, "field") {
		case "user_id":           bad.user_id = str(co, "value")
		case "issuer_device_id":  bad.issuer_device_id = str(co, "value")
		case "subject_label_b64": bad.subject_label_b64 = str(co, "value")
		case "type":              bad.type = str(co, "value")
		case "subject_kind":      bad.subject_kind = str(co, "value")
		case "subject_sign_alg":  bad.subject_sign_alg = str(co, "value")
		case "subject_wrap_alg":  bad.subject_wrap_alg = str(co, "value")
		case: testing.fail_now(t, "unhandled invalid field")
		}
		_, bok := statement_canonical(&bad, context.temp_allocator)
		testing.expectf(t, !bok, "invalid statement %s must be rejected", str(co, "name"))
	}
}

@(test)
test_algorithm_allowlists_reject_unknown :: proc(t: ^testing.T) {
	root := load_vectors(t)
	algs := obj(root, "algorithms")
	for a in arr(algs, "sign") do testing.expect(t, sign_alg_from_id(string(a.(json.String))) != .Unknown)
	for a in arr(algs, "wrap") do testing.expect(t, wrap_alg_from_id(string(a.(json.String))) != .Unknown)
	so := obj(root, "statement")
	for a in arr(algs, "unknown_sign") {
		id := string(a.(json.String))
		testing.expect(t, sign_alg_from_id(id) == .Unknown)
		testing.expect(t, !verify(id, str(so, "issuer_public_key"), transmute([]byte)str(so, "canonical"), str(so, "signature_object")))
	}
	wo := obj(obj(root, "wrap"), "json")
	for a in arr(algs, "unknown_wrap") {
		id := string(a.(json.String))
		testing.expect(t, wrap_alg_from_id(id) == .Unknown)
		w := wrap_from_json(wo)
		w.alg = id
		_, ok := wrap_canonical_json(&w, context.temp_allocator)
		testing.expect(t, !ok)
		priv: ecdh.Private_Key
		_ = ecdh.private_key_set_bytes(&priv, .SECP256R1, unhex(str(obj(root, "wrap"), "recipient_ecdh_private_key")))
		_, wok := wrap_open(&w, str(obj(root, "wrap"), "user_id"), &priv)
		testing.expect(t, !wok, "unknown wrap alg must not unwrap")
	}
	// Policy by kind is one function: bridges and unknown kinds never approve.
	testing.expect(t, kind_policy(device_kind_from_id("browser")).can_approve)
	testing.expect(t, kind_policy(device_kind_from_id("recovery")).can_approve)
	testing.expect(t, !kind_policy(device_kind_from_id("bridge")).can_approve)
	testing.expect(t, !kind_policy(device_kind_from_id("passkey")).can_approve)
}

@(private = "file")
wrap_from_json :: proc(wo: json.Object) -> Keyring_Wrap {
	return Keyring_Wrap{
		alg = str(wo, "alg"), recipient_device_id = str(wo, "recipient_device_id"),
		directory_version = u64(num(wo, "directory_version")), current_epoch = u32(num(wo, "current_epoch")),
		ephemeral_public_key = str(wo, "ephemeral_public_key"), iv = str(wo, "iv"),
		ciphertext = str(wo, "ciphertext"), wrapped_by_device_id = str(wo, "wrapped_by_device_id"),
	}
}

@(test)
test_wrap_vectors :: proc(t: ^testing.T) {
	root := load_vectors(t)
	wv := obj(root, "wrap")
	w := wrap_from_json(obj(wv, "json"))
	canonical, ok := wrap_canonical_json(&w, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, canonical, str(wv, "canonical_json"))
	digest: [32]byte
	testing.expect(t, wrap_sha256(&w, digest[:]))
	testing.expect_value(t, hex_encode_lower(digest[:], context.temp_allocator), str(wv, "wrap_sha256"))
	aad, _ := wrap_aad(str(wv, "user_id"), w.recipient_device_id, w.directory_version, w.current_epoch, context.temp_allocator)
	testing.expect_value(t, aad, str(wv, "aad"))
	priv: ecdh.Private_Key
	testing.expect(t, ecdh.private_key_set_bytes(&priv, .SECP256R1, unhex(str(wv, "recipient_ecdh_private_key"))))
	kr, wok := wrap_open(&w, str(wv, "user_id"), &priv)
	testing.expect(t, wok)
	ser, _ := keyring_serialize(&kr, context.temp_allocator)
	testing.expect_value(t, hex_encode_lower(ser, context.temp_allocator), str(wv, "keyring_hex"))
	keyring_wipe(&kr)
	// AAD binds recipient, version and user.
	w2 := w
	w2.directory_version += 1
	_, bad1 := wrap_open(&w2, str(wv, "user_id"), &priv)
	w3 := w
	w3.recipient_device_id = "dev_other"
	_, bad2 := wrap_open(&w3, str(wv, "user_id"), &priv)
	_, bad3 := wrap_open(&w, "usr_other", &priv)
	testing.expect(t, !bad1 && !bad2 && !bad3)
}

@(test)
test_epoch_commit_vector :: proc(t: ^testing.T) {
	root := load_vectors(t)
	ec := obj(root, "epoch_commit")
	got: [32]byte
	testing.expect(t, epoch_commit(unhex(str(ec, "key")), str(ec, "user_id"), u32(num(ec, "epoch")), got[:]))
	testing.expect_value(t, hex_encode_lower(got[:], context.temp_allocator), str(ec, "commit"))
	testing.expect(t, epoch_commit_verify(unhex(str(ec, "key")), str(ec, "user_id"), u32(num(ec, "epoch")), unhex(str(ec, "commit"))))
	testing.expect(t, !epoch_commit_verify(unhex(str(ec, "key")), str(ec, "user_id"), 3, unhex(str(ec, "commit"))))
}

@(test)
test_bridge_unseal_key_statement_vector :: proc(t: ^testing.T) {
	root := load_vectors(t)
	bv := obj(root, "bridge_unseal_key")
	canonical, ok := bridge_unseal_key_canonical(str(bv, "bridge_id"), str(bv, "ecdh_public_key"), str(bv, "boot_id"), context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, canonical, str(bv, "canonical"))
	msg := transmute([]byte)canonical
	testing.expect(t, verify(SIGN_ALG_ECDSA_P256_SHA256, str(bv, "identity_public_key"), msg, str(bv, "signature_object")))
	// Signed by a different identity key: rejected under the pinned identity.
	testing.expect(t, !verify(SIGN_ALG_ECDSA_P256_SHA256, str(bv, "identity_public_key"), msg, str(bv, "other_identity_signature_object")))
	// Identity-key mismatch: the right signature checked against another identity.
	testing.expect(t, !verify(SIGN_ALG_ECDSA_P256_SHA256, str(bv, "other_identity_public_key"), msg, str(bv, "signature_object")))
	priv: ecdsa.Private_Key
	testing.expect(t, ecdsa.private_key_set_bytes(&priv, .SECP256R1, unhex(str(bv, "identity_private_key"))))
	sig, _ := sign_p256(&priv, msg)
	o, _ := signature_object(&sig, context.temp_allocator)
	testing.expect_value(t, o, str(bv, "signature_object"))
}

@(test)
test_unseal_v2_vector :: proc(t: ^testing.T) {
	root := load_vectors(t)
	uv := obj(root, "unseal_v2")
	priv: ecdh.Private_Key
	testing.expect(t, ecdh.private_key_set_bytes(&priv, .SECP256R1, unhex(str(uv, "bridge_ecdh_private_key"))))
	aad, _ := unseal_v2_aad(str(uv, "bridge_id"), num(uv, "timestamp"), str(uv, "nonce"), u32(num(uv, "current_epoch")), context.temp_allocator)
	testing.expect_value(t, aad, str(uv, "aad"))
	kr, err := unseal_v2_open(&priv, str(uv, "client_public_key"), str(uv, "iv"), str(uv, "tag"), str(uv, "ciphertext"), str(uv, "bridge_id"), num(uv, "timestamp"), str(uv, "nonce"), u32(num(uv, "current_epoch")))
	testing.expect_value(t, err, Unseal_V2_Error.None)
	ser, _ := keyring_serialize(&kr, context.temp_allocator)
	testing.expect_value(t, hex_encode_lower(ser, context.temp_allocator), str(uv, "keyring_hex"))
	keyring_wipe(&kr)
	// Every AAD component is bound.
	_, e1 := unseal_v2_open(&priv, str(uv, "client_public_key"), str(uv, "iv"), str(uv, "tag"), str(uv, "ciphertext"), "brg_other", num(uv, "timestamp"), str(uv, "nonce"), 2)
	_, e2 := unseal_v2_open(&priv, str(uv, "client_public_key"), str(uv, "iv"), str(uv, "tag"), str(uv, "ciphertext"), str(uv, "bridge_id"), num(uv, "timestamp") + 1, str(uv, "nonce"), 2)
	_, e3 := unseal_v2_open(&priv, str(uv, "client_public_key"), str(uv, "iv"), str(uv, "tag"), str(uv, "ciphertext"), str(uv, "bridge_id"), num(uv, "timestamp"), str(uv, "nonce"), 1)
	testing.expect(t, e1 == .Auth_Failed && e2 == .Auth_Failed && e3 == .Auth_Failed)
	// The v1 AAD form ("bridge_id:ts:nonce") is never accepted, and a raw 32-byte
	// key (the v1 plaintext) is not a keyring even under the correct v2 AAD.
	client: ecdh.Private_Key
	testing.expect(t, ecdh.private_key_set_bytes(&client, .SECP256R1, unhex(str(uv, "client_private_key"))))
	key: [32]byte
	testing.expect(t, ecdh_hkdf_key(&client, str(uv, "bridge_ecdh_public_key"), UNSEAL_V2_INFO, key[:]))
	iv := unhex(str(uv, "iv"))
	seal_raw :: proc(key: []byte, iv: []byte, aad: string, plain: []byte) -> (string, string) {
		ct := make([]byte, len(plain), context.temp_allocator)
		tag: [TAG_BYTES]byte
		gcm: aes.Context_GCM
		aes.init_gcm(&gcm, key)
		defer aes.reset_gcm(&gcm)
		aes.seal_gcm(&gcm, ct, tag[:], iv, transmute([]byte)aad, plain)
		return hex_encode_lower(ct, context.temp_allocator), hex_encode_lower(tag[:], context.temp_allocator)
	}
	krb := unhex(str(uv, "keyring_hex"))
	v1_aad := strings.concatenate({str(uv, "bridge_id"), ":1760000000123:", str(uv, "nonce")}, context.temp_allocator)
	ct1, tag1 := seal_raw(key[:], iv, v1_aad, krb)
	_, ev1 := unseal_v2_open(&priv, str(uv, "client_public_key"), str(uv, "iv"), tag1, ct1, str(uv, "bridge_id"), num(uv, "timestamp"), str(uv, "nonce"), 2)
	testing.expect_value(t, ev1, Unseal_V2_Error.Auth_Failed)
	raw32 := unhex(str(root["epoch_keys"].(json.Object), "1"))
	ct2, tag2 := seal_raw(key[:], iv, aad, raw32)
	_, ev2 := unseal_v2_open(&priv, str(uv, "client_public_key"), str(uv, "iv"), tag2, ct2, str(uv, "bridge_id"), num(uv, "timestamp"), str(uv, "nonce"), 2)
	testing.expect_value(t, ev2, Unseal_V2_Error.Bad_Keyring)
	hex64 := transmute([]byte)str(root["epoch_keys"].(json.Object), "1")
	ct3, tag3 := seal_raw(key[:], iv, aad, hex64)
	_, ev3 := unseal_v2_open(&priv, str(uv, "client_public_key"), str(uv, "iv"), tag3, ct3, str(uv, "bridge_id"), num(uv, "timestamp"), str(uv, "nonce"), 2)
	testing.expect_value(t, ev3, Unseal_V2_Error.Bad_Keyring)
	// Keyring whose current epoch differs from the signed-over current_epoch.
	single := unhex(str(obj(root, "keyring"), "single_epoch_hex"))
	ct4, tag4 := seal_raw(key[:], iv, aad, single)
	_, ev4 := unseal_v2_open(&priv, str(uv, "client_public_key"), str(uv, "iv"), tag4, ct4, str(uv, "bridge_id"), num(uv, "timestamp"), str(uv, "nonce"), 2)
	testing.expect_value(t, ev4, Unseal_V2_Error.Epoch_Mismatch)
	// Uppercase hex is not the wire form.
	_, ev5 := unseal_v2_open(&priv, str(uv, "client_public_key"), strings.to_upper(str(uv, "iv"), context.temp_allocator), str(uv, "tag"), str(uv, "ciphertext"), str(uv, "bridge_id"), num(uv, "timestamp"), str(uv, "nonce"), 2)
	testing.expect_value(t, ev5, Unseal_V2_Error.Bad_Parameters)
}

@(test)
test_pty_v2_vectors :: proc(t: ^testing.T) {
	root := load_vectors(t)
	kr := vector_keyring(t, root)
	defer keyring_wipe(&kr)
	for c in arr(obj(root, "pty"), "cases") {
		co := c.(json.Object)
		dir: Pty_Direction = .Out if str(co, "direction") == "out" else .In
		epoch := u32(num(co, "epoch"))
		key, _ := keyring_key_for_epoch(&kr, epoch)
		testing.expect_value(t, pty_aad(epoch, str(co, "session_id"), dir, context.temp_allocator), str(co, "aad"))
		frame, ok := pty_seal(unhex(str(co, "plaintext_hex")), key, epoch, unhex(str(co, "nonce")), str(co, "session_id"), dir, context.temp_allocator)
		testing.expect(t, ok)
		testing.expect_value(t, hex_encode_lower(frame, context.temp_allocator), str(co, "frame_hex"))
		plain, pok := pty_open(frame, &kr, str(co, "session_id"), dir, 0, context.temp_allocator)
		testing.expect(t, pok)
		testing.expect_value(t, hex_encode_lower(plain, context.temp_allocator), str(co, "plaintext_hex"))
		// Wrong session, wrong direction, flipped epoch, and a non-current floor fail.
		other: Pty_Direction = .In if dir == .Out else .Out
		_, b1 := pty_open(frame, &kr, "shs_other", dir, 0, context.temp_allocator)
		_, b2 := pty_open(frame, &kr, str(co, "session_id"), other, 0, context.temp_allocator)
		_, b3 := pty_open(frame, &kr, str(co, "session_id"), dir, epoch + 1, context.temp_allocator)
		flipped := make([]byte, len(frame), context.temp_allocator)
		copy(flipped, frame)
		flipped[3] ~= 0x03 // epoch 1<->2
		_, b4 := pty_open(flipped, &kr, str(co, "session_id"), dir, 0, context.temp_allocator)
		testing.expect(t, !b1 && !b2 && !b3 && !b4)
	}
}

@(test)
test_search_v2_vector :: proc(t: ^testing.T) {
	root := load_vectors(t)
	sv := obj(root, "search")
	key: [32]byte
	testing.expect(t, search_key_derive(unhex(str(sv, "epoch_key")), u32(num(sv, "epoch")), key[:]))
	testing.expect_value(t, hex_encode_lower(key[:], context.temp_allocator), str(sv, "derived_key"))
	rpc := obj(sv, "rpc")
	aad := search_aad(str(rpc, "owner_user_id"), str(rpc, "bridge_id"), str(rpc, "request_id"), str(rpc, "direction"), num(rpc, "expires_at_ms"), u32(num(sv, "epoch")), context.temp_allocator)
	testing.expect_value(t, aad, str(rpc, "aad"))
	env, ok := search_seal_with_nonce(transmute([]byte)str(rpc, "plaintext"), unhex(str(sv, "epoch_key")), 2, aad, unhex(str(rpc, "nonce")), context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, env, str(rpc, "envelope"))
	epoch, payload, pok := search_envelope_parse(env, context.temp_allocator)
	testing.expect(t, pok && epoch == 2)
	plain, ook := search_open_payload(payload, unhex(str(sv, "epoch_key")), epoch, aad, context.temp_allocator)
	testing.expect(t, ook)
	testing.expect_value(t, string(plain), str(rpc, "plaintext"))
	// The epoch is in the AAD: the same payload under epoch 1 does not open.
	_, b := search_open_payload(payload, unhex(str(sv, "epoch_key")), 1, aad, context.temp_allocator)
	testing.expect(t, !b)
}
