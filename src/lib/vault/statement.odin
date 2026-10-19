package vault

import "core:crypto"
import "core:crypto/ecdsa"
import "core:crypto/hmac"
import "core:encoding/json"
import jsonx "odin_test:lib/jsonx"
import "core:strconv"
import "core:strings"
import os_random "odin_test:lib/os_random"

// ── Credential agility ──────────────────────────────────────────────────────
// Every signature is a JSON object {"alg":…,"sig":…} and every wrap names its
// "alg". Verification and unwrapping dispatch through ONE allowlist each; an unknown
// id is rejected before any key material is touched. Passkeys / security keys will
// arrive as new ids (webauthn-es256, webauthn-prf-…) added here, nowhere else.

SIGN_ALG_ECDSA_P256_SHA256 :: "ecdsa-p256-sha256"
WRAP_ALG_ECDH_P256_HKDF_AES :: "ecdh-p256-hkdf-sha256-aes256gcm"

Sign_Alg :: enum {
	Unknown,
	Ecdsa_P256_Sha256,
}

Wrap_Alg :: enum {
	Unknown,
	Ecdh_P256_Hkdf_Sha256_Aes256gcm,
}

// sign_alg_from_id is the single sign-algorithm allowlist.
sign_alg_from_id :: proc(id: string) -> Sign_Alg {
	switch id {
	case SIGN_ALG_ECDSA_P256_SHA256:
		return .Ecdsa_P256_Sha256
	}
	return .Unknown
}

// wrap_alg_from_id is the single wrap-algorithm allowlist.
wrap_alg_from_id :: proc(id: string) -> Wrap_Alg {
	switch id {
	case WRAP_ALG_ECDH_P256_HKDF_AES:
		return .Ecdh_P256_Hkdf_Sha256_Aes256gcm
	}
	return .Unknown
}

// ── Device kinds and policy ─────────────────────────────────────────────────

Device_Kind :: enum {
	Unknown,
	Browser,
	Bridge,
	Recovery,
}

device_kind_from_id :: proc(id: string) -> Device_Kind {
	switch id {
	case "browser":  return .Browser
	case "bridge":   return .Bridge
	case "recovery": return .Recovery
	}
	return .Unknown
}

Kind_Policy :: struct {
	can_approve:       bool, // may sign approve/revoke/epoch/wrap statements
	counts_as_approver: bool, // counts toward the last-approver guard
	receives_wrap:     bool, // gets a hub-stored keyring wrap
}

// kind_policy is the ONE place that decides what a device kind may do. Bridges never
// approve anything; an unknown kind may do nothing.
kind_policy :: proc(kind: Device_Kind) -> Kind_Policy {
	switch kind {
	case .Browser:  return {can_approve = true, counts_as_approver = true, receives_wrap = true}
	case .Recovery: return {can_approve = true, counts_as_approver = true, receives_wrap = true}
	case .Bridge:   return {}
	case .Unknown:  return {}
	}
	return {}
}

// ── P-256 primitives ────────────────────────────────────────────────────────

P256_PUBLIC_KEY_BYTES  :: 65
P256_PRIVATE_KEY_BYTES :: 32
P256_SIGNATURE_BYTES   :: 64

// p256_private_key_generate draws a scalar from the OS CSPRNG (never core:crypto's
// panicking source) and fails closed if randomness is unavailable.
p256_private_key_generate :: proc(priv: ^ecdsa.Private_Key, random_source := os_random.DEFAULT_SOURCE) -> bool {
	buf: [P256_PRIVATE_KEY_BYTES]byte
	defer crypto.zero_explicit(&buf, size_of(buf))
	for _ in 0 ..< 8 {
		if !os_random.fill(buf[:], random_source) do return false
		if ecdsa.private_key_set_bytes(priv, .SECP256R1, buf[:]) do return true
	}
	return false
}

p256_public_key_from_hex :: proc(pub_hex: string, pub: ^ecdsa.Public_Key) -> bool {
	if len(pub_hex) != P256_PUBLIC_KEY_BYTES * 2 || !is_lower_hex(pub_hex) do return false
	raw: [P256_PUBLIC_KEY_BYTES]byte
	if !hex_decode_into(raw[:], pub_hex) do return false
	if raw[0] != 0x04 do return false
	return ecdsa.public_key_set_bytes(pub, .SECP256R1, raw[:])
}

is_lower_hex :: proc(s: string) -> bool {
	for i in 0 ..< len(s) {
		switch s[i] {
		case '0' ..= '9', 'a' ..= 'f':
		case:
			return false
		}
	}
	return true
}

@(private)
hex_nibble :: proc(c: byte) -> (u8, bool) {
	switch c {
	case '0' ..= '9': return c - '0', true
	case 'a' ..= 'f': return c - 'a' + 10, true
	case 'A' ..= 'F': return c - 'A' + 10, true
	}
	return 0, false
}

// hex_decode_into decodes exactly len(dst) bytes. Callers that need the lowercase-only
// wire form check is_lower_hex as well.
hex_decode_into :: proc(dst: []byte, s: string) -> bool {
	if len(s) != len(dst) * 2 do return false
	for i in 0 ..< len(dst) {
		hi, ok1 := hex_nibble(s[2 * i])
		lo, ok2 := hex_nibble(s[2 * i + 1])
		if !ok1 || !ok2 do return false
		dst[i] = (hi << 4) | lo
	}
	return true
}

hex_encode_lower :: proc(src: []byte, allocator := context.allocator) -> string {
	HEX := "0123456789abcdef"
	out := make([]byte, len(src) * 2, allocator)
	for b, i in src {
		out[2 * i] = HEX[b >> 4]
		out[2 * i + 1] = HEX[b & 0x0f]
	}
	return string(out)
}

// ── Signature objects ───────────────────────────────────────────────────────

Signature :: struct {
	alg: Sign_Alg,
	sig: [P256_SIGNATURE_BYTES]byte, // ecdsa-p256-sha256: raw r||s
}

// signature_parse decodes a signature object (exact canonical form only). It dispatches on "alg" through the
// allowlist first; an unknown or missing alg, an unexpected member, or a sig that is
// not exactly 128 lowercase hex characters is rejected.
signature_parse :: proc(object_json: string) -> (sig: Signature, ok: bool) {
	value, parsed := jsonx.parse_body(object_json, context.temp_allocator)
	if !parsed do return {}, false
	defer json.destroy_value(value, context.temp_allocator)
	obj, is_obj := value.(json.Object)
	if !is_obj do return {}, false
	alg_v, has_alg := obj["alg"]
	if !has_alg do return {}, false
	alg_s, alg_is_str := alg_v.(json.String)
	if !alg_is_str do return {}, false
	switch sign_alg_from_id(string(alg_s)) {
	case .Ecdsa_P256_Sha256:
		if len(obj) != 2 do return {}, false
		sig_v, has_sig := obj["sig"]
		if !has_sig do return {}, false
		sig_s, sig_is_str := sig_v.(json.String)
		if !sig_is_str do return {}, false
		if len(sig_s) != P256_SIGNATURE_BYTES * 2 || !is_lower_hex(string(sig_s)) do return {}, false
		if !hex_decode_into(sig.sig[:], string(sig_s)) do return {}, false
		sig.alg = .Ecdsa_P256_Sha256
		// Exactly one spelling is accepted: duplicate members, whitespace or reordering
		// would let two different strings mean the same signature.
		canonical, c_ok := signature_object(&sig, context.temp_allocator)
		if !c_ok || canonical != object_json do return {}, false
		return sig, true
	case .Unknown:
		return {}, false
	}
	return {}, false
}

// signature_object renders {"alg":"ecdsa-p256-sha256","sig":"<hex>"} exactly.
signature_object :: proc(sig: ^Signature, allocator := context.allocator) -> (string, bool) {
	switch sig.alg {
	case .Ecdsa_P256_Sha256:
		h := hex_encode_lower(sig.sig[:], context.temp_allocator)
		return strings.concatenate({`{"alg":"`, SIGN_ALG_ECDSA_P256_SHA256, `","sig":"`, h, `"}`}, allocator), true
	case .Unknown:
	}
	return "", false
}

// verify checks a signature object over msg by a public key of the given sign alg.
// The key's alg and the signature's alg must agree; both go through the allowlist.
verify :: proc(key_alg_id: string, public_key_hex: string, msg: []byte, signature_json: string) -> bool {
	key_alg := sign_alg_from_id(key_alg_id)
	if key_alg == .Unknown do return false
	sig, ok := signature_parse(signature_json)
	if !ok || sig.alg != key_alg do return false
	switch key_alg {
	case .Ecdsa_P256_Sha256:
		pub: ecdsa.Public_Key
		defer ecdsa.public_key_clear(&pub)
		if !p256_public_key_from_hex(public_key_hex, &pub) do return false
		return ecdsa.verify_raw(&pub, .SHA256, msg, sig.sig[:])
	case .Unknown:
	}
	return false
}

// sign_p256 signs msg with RFC 6979 deterministic nonces, so a signature never depends
// on a randomness source at all.
sign_p256 :: proc(priv: ^ecdsa.Private_Key, msg: []byte) -> (sig: Signature, ok: bool) {
	if ecdsa.curve(priv) != .SECP256R1 do return {}, false
	if !ecdsa.sign_raw(priv, .SHA256, msg, sig.sig[:], deterministic = true) do return {}, false
	sig.alg = .Ecdsa_P256_Sha256
	return sig, true
}

// ── Canonical statements ────────────────────────────────────────────────────

STATEMENT_HEADER :: "heimdall-vault-statement/v1"

Statement :: struct {
	type:              string, // genesis|approve|revoke|epoch|wrap|recovery
	user_id:           string,
	directory_version: string,
	issuer_device_id:  string,
	issued_at_ms:      string,
	subject_device_id: string,
	subject_kind:      string,
	subject_sign_pub:  string,
	subject_ecdh_pub:  string,
	subject_sign_alg:  string,
	subject_wrap_alg:  string,
	subject_label_b64: string,
	epoch:             string,
	epoch_commit:      string,
	wrap_sha256:       string,
}

valid_statement_type :: proc(t: string) -> bool {
	switch t {
	case "genesis", "approve", "revoke", "epoch", "wrap", "recovery", "register":
		return true
	}
	return false
}

// statement_canonical renders the fixed-layout canonical bytes. Every value must match
// [A-Za-z0-9_.:-]*; the type, any non-empty kind and any non-empty algorithm id must be
// known. Fields that do not apply are present and empty.
statement_canonical :: proc(st: ^Statement, allocator := context.allocator) -> (string, bool) {
	if !valid_statement_type(st.type) do return "", false
	if st.subject_kind != "" && device_kind_from_id(st.subject_kind) == .Unknown do return "", false
	if st.subject_sign_alg != "" && sign_alg_from_id(st.subject_sign_alg) == .Unknown do return "", false
	if st.subject_wrap_alg != "" && wrap_alg_from_id(st.subject_wrap_alg) == .Unknown do return "", false
	fields := [?][2]string{
		{"type", st.type},
		{"user_id", st.user_id},
		{"directory_version", st.directory_version},
		{"issuer_device_id", st.issuer_device_id},
		{"issued_at_ms", st.issued_at_ms},
		{"subject_device_id", st.subject_device_id},
		{"subject_kind", st.subject_kind},
		{"subject_sign_pub", st.subject_sign_pub},
		{"subject_ecdh_pub", st.subject_ecdh_pub},
		{"subject_sign_alg", st.subject_sign_alg},
		{"subject_wrap_alg", st.subject_wrap_alg},
		{"subject_label_b64", st.subject_label_b64},
		{"epoch", st.epoch},
		{"epoch_commit", st.epoch_commit},
		{"wrap_sha256", st.wrap_sha256},
	}
	b := strings.builder_make(allocator)
	strings.write_string(&b, STATEMENT_HEADER)
	for f in fields {
		if !valid_id_value(f[1]) {
			strings.builder_destroy(&b)
			return "", false
		}
		strings.write_byte(&b, '\n')
		strings.write_string(&b, f[0])
		strings.write_byte(&b, '=')
		strings.write_string(&b, f[1])
	}
	return strings.to_string(b), true
}

// epoch_commit = HMAC-SHA256(epoch_key, "heimdall-epoch-commit|<user_id>|<epoch>").
epoch_commit :: proc(epoch_key: []byte, user_id: string, epoch: u32, dst: []byte) -> bool {
	if len(epoch_key) != KEY_BYTES || len(dst) != 32 do return false
	epoch_buf: [16]byte
	msg := strings.concatenate({"heimdall-epoch-commit|", user_id, "|", strconv.write_uint(epoch_buf[:], u64(epoch), 10)}, context.temp_allocator)
	hmac.sum(.SHA256, dst, transmute([]byte)msg, epoch_key)
	return true
}

// epoch_commit_verify compares in constant time.
epoch_commit_verify :: proc(epoch_key: []byte, user_id: string, epoch: u32, commit: []byte) -> bool {
	got: [32]byte
	defer crypto.zero_explicit(&got, size_of(got))
	if len(commit) != 32 || !epoch_commit(epoch_key, user_id, epoch, got[:]) do return false
	return crypto.compare_constant_time(got[:], commit) == 1
}

// ── Bridge unseal-key statement ─────────────────────────────────────────────

BRIDGE_UNSEAL_KEY_HEADER :: "heimdall-bridge-unseal-key/v1"

// bridge_unseal_key_canonical renders
// "heimdall-bridge-unseal-key/v1\n<bridge_id>\n<ecdh_pub_hex>\n<boot_id>".
bridge_unseal_key_canonical :: proc(bridge_id, ecdh_pub_hex, boot_id: string, allocator := context.allocator) -> (string, bool) {
	if bridge_id == "" || !valid_id_value(bridge_id) do return "", false
	if len(ecdh_pub_hex) != P256_PUBLIC_KEY_BYTES * 2 || !is_lower_hex(ecdh_pub_hex) do return "", false
	if boot_id == "" || !is_lower_hex(boot_id) do return "", false
	return strings.concatenate({BRIDGE_UNSEAL_KEY_HEADER, "\n", bridge_id, "\n", ecdh_pub_hex, "\n", boot_id}, allocator), true
}
