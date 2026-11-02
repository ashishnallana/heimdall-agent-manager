package vault

import "core:crypto/ecdsa"
import "core:crypto/sha2"
import "core:encoding/json"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// ── Device directory helpers (plan §1, §2 P2) ───────────────────────────────
// Shared by the hub (which re-verifies every statement as defense in depth) and,
// from P3, by the bridge (which verifies the epoch chain to the pinned root). Every
// parser here is strict: one accepted spelling, unknown ids rejected, fail closed.

DEVICE_ID_PREFIX       :: "dev_"
DEVICE_ID_HEX_CHARS    :: 32
LABEL_MAX_BYTES        :: 128
EPOCH_COMMIT_HEX_CHARS :: 64

// device_id_from_sign_pub = "dev_" + hex(SHA256(sign_pub_raw65))[0:32].
device_id_from_sign_pub :: proc(sign_pub_hex: string, allocator := context.allocator) -> (string, bool) {
	raw: [P256_PUBLIC_KEY_BYTES]byte
	if !valid_p256_public_hex(sign_pub_hex) || !hex_decode_into(raw[:], sign_pub_hex) do return "", false
	digest: [32]byte
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, raw[:])
	sha2.final(&ctx, digest[:])
	h := hex_encode_lower(digest[:DEVICE_ID_HEX_CHARS / 2], context.temp_allocator)
	return strings.concatenate({DEVICE_ID_PREFIX, h}, allocator), true
}

// device_fingerprint = first 8 bytes of SHA256(sign_pub ‖ ecdh_pub) (decoded points;
// ecdh_pub may be empty for a bridge), as four space-separated groups of four hex
// digits, the same style as the bridge key fingerprint.
device_fingerprint :: proc(sign_pub_hex, ecdh_pub_hex: string, allocator := context.allocator) -> (string, bool) {
	sign_raw, ecdh_raw: [P256_PUBLIC_KEY_BYTES]byte
	if !valid_p256_public_hex(sign_pub_hex) || !hex_decode_into(sign_raw[:], sign_pub_hex) do return "", false
	has_ecdh := ecdh_pub_hex != ""
	if has_ecdh && (!valid_p256_public_hex(ecdh_pub_hex) || !hex_decode_into(ecdh_raw[:], ecdh_pub_hex)) do return "", false
	digest: [32]byte
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, sign_raw[:])
	if has_ecdh do sha2.update(&ctx, ecdh_raw[:])
	sha2.final(&ctx, digest[:])
	h := hex_encode_lower(digest[:8], context.temp_allocator)
	return strings.concatenate({h[0:4], " ", h[4:8], " ", h[8:12], " ", h[12:16]}, allocator), true
}

// valid_p256_public_hex is the wire grammar of a P-256 public key: 130 lowercase hex
// characters of an uncompressed point (0x04 prefix). Curve membership is checked
// separately by p256_public_key_from_hex wherever the key is used.
valid_p256_public_hex :: proc(s: string) -> bool {
	return len(s) == P256_PUBLIC_KEY_BYTES * 2 && is_lower_hex(s) && s[0] == '0' && s[1] == '4'
}

// valid_p256_public_key also proves the point is on the curve.
valid_p256_public_key :: proc(s: string) -> bool {
	pub: ecdsa.Public_Key
	defer ecdsa.public_key_clear(&pub)
	return p256_public_key_from_hex(s, &pub)
}

// label_from_b64 decodes an unpadded base64url label and checks it is display-safe:
// 1..128 bytes of valid UTF-8 with no control characters.
label_from_b64 :: proc(b64: string, allocator := context.allocator) -> (string, bool) {
	if b64 == "" || len(b64) > (LABEL_MAX_BYTES * 4 + 2) / 3 + 1 do return "", false
	out := make([dynamic]byte, 0, len(b64) * 3 / 4 + 1, context.temp_allocator)
	acc: u32
	bits: uint
	for i in 0 ..< len(b64) {
		c := b64[i]
		v: u32
		switch c {
		case 'A' ..= 'Z': v = u32(c - 'A')
		case 'a' ..= 'z': v = u32(c - 'a') + 26
		case '0' ..= '9': v = u32(c - '0') + 52
		case '-':         v = 62
		case '_':         v = 63
		case:             return "", false
		}
		acc = (acc << 6) | v
		bits += 6
		if bits >= 8 {
			bits -= 8
			append(&out, byte(acc >> bits))
			acc &= (1 << bits) - 1
		}
	}
	// Leftover bits must be zero padding and fewer than a byte (a length of 4n+1 is impossible).
	if bits >= 6 || acc != 0 do return "", false
	label := string(out[:])
	if !label_valid(label) do return "", false
	return strings.clone(label, allocator), true
}

// label_valid: 1..128 bytes of valid UTF-8 with no control or line-separator characters.
label_valid :: proc(label: string) -> bool {
	if len(label) == 0 || len(label) > LABEL_MAX_BYTES || !utf8.valid_string(label) do return false
	for r in label {
		if r < 0x20 || (r >= 0x7f && r < 0xa0) || r == 0x2028 || r == 0x2029 do return false
	}
	return true
}

// valid_decimal reports a non-empty base-10 number with no sign and no leading zero.
valid_decimal :: proc(s: string) -> bool {
	if s == "" || len(s) > 19 do return false
	if len(s) > 1 && s[0] == '0' do return false
	for i in 0 ..< len(s) do if s[i] < '0' || s[i] > '9' do return false
	return true
}

decimal_u64 :: proc(s: string) -> (u64, bool) {
	if !valid_decimal(s) do return 0, false
	return strconv.parse_u64(s, 10)
}

// statement_parse is the inverse of statement_canonical. Exactly the canonical text
// is accepted: header, every field in order, one '=' each, no trailing newline. The
// parsed statement is re-rendered and compared, so the type/kind/alg allowlists and
// the value grammar apply too. Returned strings alias `text`.
statement_parse :: proc(text: string) -> (st: Statement, ok: bool) {
	FIELD_NAMES :: [?]string{
		"type", "user_id", "seq", "prev_hash", "issuer_device_id", "issued_at_ms",
		"subject_device_id", "subject_kind", "subject_sign_pub", "subject_ecdh_pub",
		"subject_sign_alg", "subject_wrap_alg", "subject_label_b64", "epoch",
		"epoch_commit", "wrap_sha256",
	}
	next_line :: proc(rest: ^string) -> (string, bool) {
		if len(rest^) == 0 && rest^ == "" do return "", false
		nl := strings.index_byte(rest^, '\n')
		if nl < 0 {
			line := rest^
			rest^ = ""
			// The final line has no trailing newline; an empty final line is a trailing '\n'.
			return line, true
		}
		line := rest^[:nl]
		rest^ = rest^[nl + 1:]
		if rest^ == "" do return "", false // trailing newline
		return line, true
	}

	if len(text) > 4096 do return {}, false
	rest := text
	header, h_ok := next_line(&rest)
	if !h_ok || header != STATEMENT_HEADER do return {}, false
	values: [len(FIELD_NAMES)]string
	names := FIELD_NAMES
	for name, i in names {
		line, l_ok := next_line(&rest)
		if !l_ok do return {}, false
		eq := strings.index_byte(line, '=')
		if eq < 0 || line[:eq] != name do return {}, false
		values[i] = line[eq + 1:]
	}
	if rest != "" do return {}, false
	st = Statement{
		type = values[0], user_id = values[1], seq = values[2], prev_hash = values[3],
		issuer_device_id = values[4], issued_at_ms = values[5], subject_device_id = values[6],
		subject_kind = values[7], subject_sign_pub = values[8], subject_ecdh_pub = values[9],
		subject_sign_alg = values[10], subject_wrap_alg = values[11], subject_label_b64 = values[12],
		epoch = values[13], epoch_commit = values[14], wrap_sha256 = values[15],
	}
	canonical, c_ok := statement_canonical(&st, context.temp_allocator)
	if !c_ok || canonical != text do return {}, false
	return st, true
}

// signature_text_from_value accepts a signature given either as its canonical JSON
// text or as a parsed object, and returns the canonical text (allocated with
// `allocator`). Anything signature_parse would reject is rejected.
signature_text_from_value :: proc(v: json.Value, allocator := context.allocator) -> (string, bool) {
	#partial switch s in v {
	case json.String:
		if _, ok := signature_parse(string(s)); !ok do return "", false
		return strings.clone(string(s), allocator), true
	case json.Object:
		alg, alg_ok := s["alg"].(json.String)
		if !alg_ok do return "", false
		switch sign_alg_from_id(string(alg)) {
		case .Ecdsa_P256_Sha256:
			if len(s) != 2 do return "", false
			sig_hex, sig_ok := s["sig"].(json.String)
			if !sig_ok do return "", false
			return signature_text_from_parts(string(alg), string(sig_hex), allocator)
		case .Unknown:
			return "", false
		}
	}
	return "", false
}

// wrap_from_value parses a hub-submitted keyring wrap object: exactly the members
// v (=1), alg, recipient_device_id, directory_version, current_epoch,
// ephemeral_public_key, iv, ciphertext, wrapped_by_device_id and signature. Types and
// grammar are checked here; the signature itself is verified by the caller against
// wrap_statement. Strings are cloned with `allocator`.
wrap_from_value :: proc(v: json.Value, allocator := context.allocator) -> (w: Keyring_Wrap, signature: string, ok: bool) {
	return wrap_from_value_bound(v, "", allocator)
}

// Delegated recipients are not directory devices. The caller must already have
// validated a signed grant for this EXACT recipient; no device authorization
// follows from this parser. Native directory endpoints keep wrap_from_value,
// which still requires a dev_ identity. All other grammar checks are shared.
wrap_from_value_for_recipient :: proc(v: json.Value, recipient: string, allocator := context.allocator) -> (Keyring_Wrap, string, bool) {
	if recipient == "" || len(recipient) > 256 || !valid_id_value(recipient) do return {}, "", false
	return wrap_from_value_bound(v, recipient, allocator)
}

@(private = "file")
wrap_from_value_bound :: proc(v: json.Value, recipient: string, allocator: mem.Allocator) -> (w: Keyring_Wrap, signature: string, ok: bool) {
	obj, is_obj := v.(json.Object)
	if !is_obj || len(obj) != 10 do return {}, "", false
	ver, ver_ok := obj["v"].(json.Integer)
	if !ver_ok || ver != 1 do return {}, "", false
	get_str :: proc(obj: json.Object, key: string) -> (string, bool) {
		s, ok := obj[key].(json.String)
		return string(s), ok
	}
	alg, a_ok := get_str(obj, "alg")
	rid, r_ok := get_str(obj, "recipient_device_id")
	eph, e_ok := get_str(obj, "ephemeral_public_key")
	iv, i_ok := get_str(obj, "iv")
	ct, c_ok := get_str(obj, "ciphertext")
	by, b_ok := get_str(obj, "wrapped_by_device_id")
	if !(a_ok && r_ok && e_ok && i_ok && c_ok && b_ok) do return {}, "", false
	dv, dv_ok := obj["directory_version"].(json.Integer)
	ce, ce_ok := obj["current_epoch"].(json.Integer)
	if !dv_ok || !ce_ok || dv < 0 || ce < 1 || ce > i64(max(u32)) do return {}, "", false
	switch wrap_alg_from_id(alg) {
	case .Ecdh_P256_Hkdf_Sha256_Aes256gcm:
		if !valid_p256_public_hex(eph) do return {}, "", false
		if len(iv) != NONCE_BYTES * 2 || !is_lower_hex(iv) do return {}, "", false
		if len(ct) % 2 != 0 || len(ct) < TAG_BYTES * 2 || len(ct) > (KEYRING_MAX_BYTES + TAG_BYTES) * 2 || !is_lower_hex(ct) do return {}, "", false
	case .Unknown:
		return {}, "", false
	}
	if !valid_device_id(by) do return {}, "", false
	if recipient == "" {
		if !valid_device_id(rid) do return {}, "", false
	} else if rid != recipient do return {}, "", false
	sig_v, has_sig := obj["signature"]
	if !has_sig do return {}, "", false
	sig_text, s_ok := signature_text_from_value(sig_v, allocator)
	if !s_ok do return {}, "", false
	w = Keyring_Wrap{
		alg = strings.clone(alg, allocator),
		recipient_device_id = strings.clone(rid, allocator),
		directory_version = u64(dv),
		current_epoch = u32(ce),
		ephemeral_public_key = strings.clone(eph, allocator),
		iv = strings.clone(iv, allocator),
		ciphertext = strings.clone(ct, allocator),
		wrapped_by_device_id = strings.clone(by, allocator),
	}
	return w, sig_text, true
}

// valid_device_id: "dev_" + 32 lowercase hex.
valid_device_id :: proc(s: string) -> bool {
	return len(s) == len(DEVICE_ID_PREFIX) + DEVICE_ID_HEX_CHARS && strings.has_prefix(s, DEVICE_ID_PREFIX) && is_lower_hex(s[len(DEVICE_ID_PREFIX):])
}

// wrap_statement is the statement a wrap's signature covers. It is reconstructible
// from the wrap alone: type=wrap, issuer = wrapped_by_device_id, subject = recipient,
// seq = the wrap's directory_version, epoch from the wrap, wrap_sha256 over the canonical wrap JSON,
// every other field empty (issued_at_ms included, so nothing outside the wrap is needed).
wrap_statement :: proc(w: ^Keyring_Wrap, user_id: string, allocator := context.allocator) -> (string, bool) {
	digest: [32]byte
	if !wrap_sha256(w, digest[:]) do return "", false
	v_buf, e_buf: [24]byte
	st := Statement{
		type = "wrap",
		user_id = user_id,
		seq = strconv.write_uint(v_buf[:], w.directory_version, 10),
		issuer_device_id = w.wrapped_by_device_id,
		subject_device_id = w.recipient_device_id,
		epoch = strconv.write_uint(e_buf[:], u64(w.current_epoch), 10),
		wrap_sha256 = hex_encode_lower(digest[:], context.temp_allocator),
	}
	if user_id == "" do return "", false
	return statement_canonical(&st, allocator)
}

// wrap_signed_json renders the stored form: the wrap's members in canonical order
// with the signature object as the last member, as a typed Wrap_Wire. It is not
// itself hashed or signed; wrap_from_value re-validates it on every read.
wrap_signed_json :: proc(w: ^Keyring_Wrap, signature: string, allocator := context.allocator) -> (string, bool) {
	if _, ok := wrap_canonical_json(w, context.temp_allocator); !ok do return "", false
	sw, s_ok := signature_wire_from_text(signature, context.temp_allocator)
	if !s_ok do return "", false
	return wire_encode(Wrap_Wire{
		v = 1, alg = w.alg, recipient_device_id = w.recipient_device_id,
		directory_version = w.directory_version, current_epoch = w.current_epoch,
		ephemeral_public_key = w.ephemeral_public_key, iv = w.iv, ciphertext = w.ciphertext,
		wrapped_by_device_id = w.wrapped_by_device_id, signature = sw,
	}, allocator)
}

// ── Signed directory log (plan §1 "Directory log") ──────────────────────────
// Every directory mutation is ONE signed log op: genesis (seq 1), approve, revoke
// (which also introduces epoch current+1 and names the revoked subject) or rotate
// (a standalone epoch advance with no subject). seq is the directory version the op
// creates, contiguous from 1; prev_hash is the hex SHA-256 of the previous op's
// canonical statement bytes (empty for genesis). The hash covers the statement only,
// not its signature: an ECDSA signature is malleable ((r,s) and (r,n-s) both verify),
// so hashing it would let anyone holding the log change the chain head without
// changing what was signed.

LOG_HASH_HEX_CHARS :: 64

// is_log_op reports a statement type that occupies a log slot.
is_log_op :: proc(t: string) -> bool {
	switch t {
	case "genesis", "approve", "revoke", "rotate":
		return true
	}
	return false
}

// introduces_epoch reports a log op that sets a new current epoch (its epoch and
// epoch_commit fields): genesis (epoch 1), revoke and rotate (current + 1).
introduces_epoch :: proc(t: string) -> bool {
	switch t {
	case "genesis", "revoke", "rotate":
		return true
	}
	return false
}

// log_entry_hash = lowercase hex SHA-256 of the canonical statement bytes.
log_entry_hash :: proc(statement: string, allocator := context.allocator) -> string {
	digest: [32]byte
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]byte)statement)
	sha2.final(&ctx, digest[:])
	return hex_encode_lower(digest[:], allocator)
}

// log_link_ok checks that st occupies log slot `seq` right after an op whose entry
// hash is prev_hash (seq 1: genesis, prev_hash empty).
log_link_ok :: proc(st: ^Statement, seq: u64, prev_hash: string) -> bool {
	if seq == 0 do return false
	buf: [24]byte
	if st.seq != strconv.write_uint(buf[:], seq, 10) do return false
	if seq == 1 do return st.prev_hash == "" && st.type == "genesis"
	if st.type == "genesis" || !is_log_op(st.type) do return false
	return len(st.prev_hash) == LOG_HASH_HEX_CHARS && is_lower_hex(st.prev_hash) && st.prev_hash == prev_hash
}
