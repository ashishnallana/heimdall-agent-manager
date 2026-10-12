package main

import "core:crypto"
import "core:crypto/aes"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import jsonx "odin_test:lib/jsonx"

// ── Reusable Content Cryptography Library (REQ-VAULT-CONTENT-LIB-1) ──────────
// Implements wire format 'vault:v1:<base64(12B_nonce + 16B_tag + ciphertext)>',
// transparent unarmored fallback, and cross-platform interoperability with WebCrypto.

VAULT_ARMOR_PREFIX :: "vault:v1:"
VAULT_NONCE_BYTES  :: 12
VAULT_TAG_BYTES    :: 16
VAULT_KEY_BYTES    :: 32
VAULT_HEADER_BYTES :: VAULT_NONCE_BYTES + VAULT_TAG_BYTES // 28

// Check if a string has the self-describing vault armor prefix.
is_vault_armored :: proc(text: string) -> bool {
	return strings.has_prefix(text, VAULT_ARMOR_PREFIX)
}

// Encrypt plaintext string using 256-bit AES-GCM and return armored envelope string:
// 'vault:v1:<base64(12B_nonce + 16B_tag + ciphertext)>'
vault_encrypt_text :: proc(plaintext: string, key_bytes: []u8, allocator := context.allocator) -> (armored: string, ok: bool) {
	if len(key_bytes) != VAULT_KEY_BYTES do return "", false

	plaintext_bytes := transmute([]byte)plaintext

	nonce: [VAULT_NONCE_BYTES]byte
	crypto.rand_bytes(nonce[:])

	ciphertext := make([]byte, len(plaintext_bytes), context.temp_allocator)
	tag: [VAULT_TAG_BYTES]byte

	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, key_bytes)
	defer aes.reset_gcm(&gcm)

	aes.seal_gcm(&gcm, ciphertext, tag[:], nonce[:], nil, plaintext_bytes)

	payload_len := VAULT_HEADER_BYTES + len(ciphertext)
	payload := make([]byte, payload_len, context.temp_allocator)
	copy(payload[0:VAULT_NONCE_BYTES], nonce[:])
	copy(payload[VAULT_NONCE_BYTES:VAULT_HEADER_BYTES], tag[:])
	copy(payload[VAULT_HEADER_BYTES:], ciphertext)

	b64, err := base64.encode(payload, allocator = context.temp_allocator)
	if err != nil do return "", false

	res := strings.concatenate({VAULT_ARMOR_PREFIX, b64}, allocator)
	return res, true
}

// Encrypt plaintext using a 64-character hex key string.
vault_encrypt_text_hex :: proc(plaintext: string, key_hex: string, allocator := context.allocator) -> (armored: string, ok: bool) {
	if !is_valid_hex_key(key_hex) do return "", false
	raw_key, hex_ok := hex.decode(transmute([]byte)key_hex, context.temp_allocator)
	if !hex_ok || len(raw_key) != VAULT_KEY_BYTES do return "", false
	return vault_encrypt_text(plaintext, raw_key, allocator)
}

// Decrypt a vault armored string. If the string does not start with 'vault:v1:',
// returns a copy of the input string as-is with ok = true (transparent fallback).
vault_decrypt_text :: proc(armored: string, key_bytes: []u8, allocator := context.allocator) -> (plaintext: string, ok: bool) {
	if !is_vault_armored(armored) {
		return strings.clone(armored, allocator), true
	}

	if len(key_bytes) != VAULT_KEY_BYTES do return "", false

	b64 := strings.trim_space(armored[len(VAULT_ARMOR_PREFIX):])
	if len(b64) == 0 do return "", false

	// Validate base64 alphabet
	for i in 0 ..< len(b64) {
		c := b64[i]
		switch c {
		case 'A'..='Z', 'a'..='z', '0'..='9', '+', '/', '=':
		case:
			return "", false
		}
	}

	payload, err := base64.decode(b64, allocator = context.temp_allocator)
	if err != nil do return "", false

	if len(payload) < VAULT_HEADER_BYTES do return "", false

	nonce := payload[0:VAULT_NONCE_BYTES]
	tag := payload[VAULT_NONCE_BYTES:VAULT_HEADER_BYTES]
	ciphertext := payload[VAULT_HEADER_BYTES:]

	dst := make([]byte, len(ciphertext), allocator)
	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, key_bytes)
	defer aes.reset_gcm(&gcm)

	if !aes.open_gcm(&gcm, dst, nonce, nil, ciphertext, tag) {
		delete(dst, allocator)
		return "", false
	}

	return string(dst), true
}

// Decrypt a vault armored string using a 64-character hex key string.
vault_decrypt_text_hex :: proc(armored: string, key_hex: string, allocator := context.allocator) -> (plaintext: string, ok: bool) {
	if !is_vault_armored(armored) {
		return strings.clone(armored, allocator), true
	}
	if !is_valid_hex_key(key_hex) do return "", false
	raw_key, hex_ok := hex.decode(transmute([]byte)key_hex, context.temp_allocator)
	if !hex_ok || len(raw_key) != VAULT_KEY_BYTES do return "", false
	return vault_decrypt_text(armored, raw_key, allocator)
}

// Remedy hints appended after the '[Encrypted: ...]' fallback so a reader learns both the
// cause and the next step (REQ-VAULT-3). They are additive: everything up to and including
// the closing bracket keeps the exact historical shape '[Encrypted: <armored>]'.
VAULT_HINT_NO_KEY   :: "(vault key not configured — see `ham-ctl vault status`)"
VAULT_HINT_BAD_KEY  :: "(configured vault key cannot decrypt this value — see `ham-ctl vault status`)"

// Decrypt an armored field if key is configured, or return fallback formatted string:
// '[Encrypted: vault:v1:...] (<remedy hint>)' if key is unconfigured or decryption fails.
// The hint distinguishes the two causes: an unconfigured key needs the bridge unsealed, whereas a
// configured-but-wrong key would be actively misdiagnosed by a "not configured" message.
ctl_decrypt_or_fallback_armored :: proc(val: string, key_hex: string, key_configured: bool, allocator := context.allocator) -> string {
	if !is_vault_armored(val) {
		return strings.clone(val, allocator)
	}
	if key_configured {
		decrypted, ok := vault_decrypt_text_hex(val, key_hex, allocator)
		if ok {
			return decrypted
		}
	}
	// Missing key or decryption failure (e.g. wrong key, truncated preview or tampered):
	// graceful fallback that names the cause and the remedy.
	hint := key_configured ? VAULT_HINT_BAD_KEY : VAULT_HINT_NO_KEY
	return fmt.aprintf("[Encrypted: %s] %s", val, hint, allocator = allocator)
}

Json_Field_Update :: struct {
	k: string,
	v: json.Value,
}

ctl_decrypt_json_value :: proc(v: ^json.Value, key_hex: string, key_configured: bool, allocator := context.allocator) {
	if v == nil do return
	#partial switch &val in v^ {
	case json.Object:
		updates: [dynamic]Json_Field_Update
		defer delete(updates)
		for k, sub_v in val {
			switch k {
			case "title", "description", "description_preview", "body", "evidence", "last_comment_preview", "last_message_preview", "name", "content":
				if s, is_str := sub_v.(json.String); is_str {
					str_val := string(s)
					if is_vault_armored(str_val) {
						new_str := ctl_decrypt_or_fallback_armored(str_val, key_hex, key_configured, allocator)
						append(&updates, Json_Field_Update{k = k, v = json.String(new_str)})
					}
				}
			case:
				#partial switch _ in sub_v {
				case json.Object, json.Array:
					var := sub_v
					ctl_decrypt_json_value(&var, key_hex, key_configured, allocator)
					append(&updates, Json_Field_Update{k = k, v = var})
				}
			}
		}
		for u in updates {
			val[u.k] = u.v
		}
	case json.Array:
		for i in 0 ..< len(val) {
			ctl_decrypt_json_value(&val[i], key_hex, key_configured, allocator)
		}
	}
}

// ctl_decrypt_json_string returns `raw_json` with every armored value in a listed
// field replaced by its decrypted text, and EVERY OTHER BYTE untouched.
//
// WHY IT NO LONGER PARSES-AND-RE-MARSHALS (F1 / REQ-JSONX-2) -- this proc sits on the
// artifact, task, issue and generic agent-mode response paths, and it used to do
// `json.parse_string` -> walk -> `json.marshal` on the WHOLE response. Both halves of
// that round-trip are unsafe for a response that carries arbitrary bytes:
//
//   * `json.parse_string` aborts the process. Its `unquote_string` sizes the output
//     buffer from the escaped token (len+8) and re-encodes each invalid UTF-8 byte as
//     U+FFFD -- 1 byte in, 3 out -- so it overruns when
//     `decoded + 2*invalid > len(escaped_token) + 8`. This is what made
//     `artifact show --with-content` die at parser.odin:494/:507 on both artifacts in
//     the user report, long after `artifact content` had been fixed.
//   * `json.marshal` cannot write the bytes back even once they are parsed safely: for
//     invalid UTF-8 it emits `\xNN`, which is not a JSON escape. So a byte-preserving
//     round-trip through core is not available in either direction.
//
// WHAT WE DO INSTEAD -- we never re-serialize. The tree is only ever used to LEARN which
// `vault:v1:` tokens sit in fields that `ctl_decrypt_json_value` decrypts and what each
// one becomes; those substitutions are then spliced into the original text. Anything not
// armored -- binary artifact content above all -- is copied through verbatim, so the
// output is the hub's own JSON with ciphertext swapped for plaintext.
//
// Deliberately NOT changed: the armored-field list (`ctl_decrypt_json_value`, :160) and
// the decrypt/fallback semantics. The two-parse-and-diff below exists precisely so that
// this proc can observe what those do without restating or altering any of it.
ctl_decrypt_json_string :: proc(raw_json: string, key_hex: string, key_configured: bool, allocator := context.allocator) -> string {
	// Fast path: `vault:v1:` is pure ASCII and contains nothing JSON escaping would
	// alter, so an armored value's prefix ALWAYS appears verbatim in the raw response.
	// Its absence therefore proves no field is armored -- no false negatives -- and
	// there is nothing to do but hand the bytes back.
	if !strings.contains(raw_json, VAULT_ARMOR_PREFIX) {
		return strings.clone(raw_json, allocator)
	}

	// `jsonx.parse_body`, never `json.parse_string`: this path is reached precisely when
	// armor and arbitrary bytes can share one response, which is the case that aborts.
	original, original_ok := jsonx.parse_body(raw_json, context.temp_allocator)
	if !original_ok {
		return strings.clone(raw_json, allocator)
	}
	defer json.destroy_value(original, context.temp_allocator)

	decrypted, decrypted_ok := jsonx.parse_body(raw_json, context.temp_allocator)
	if !decrypted_ok {
		return strings.clone(raw_json, allocator)
	}
	defer json.destroy_value(decrypted, context.temp_allocator)

	ctl_decrypt_json_value(&decrypted, key_hex, key_configured, context.temp_allocator)

	pairs := make([dynamic][2]string, context.temp_allocator)
	ctl_collect_decrypted_pairs(original, decrypted, &pairs)
	if len(pairs) == 0 {
		return strings.clone(raw_json, allocator)
	}

	out := strings.clone(raw_json, context.temp_allocator)
	for pair in pairs {
		armored, plaintext := pair[0], pair[1]
		// The armored token is raw base64 in the source, but the plaintext replacing it
		// sits inside a JSON string literal and so has to be escaped.
		escaped := ctl_json_escape_bytes(plaintext, context.temp_allocator)
		out = strings.replace_all(out, armored, escaped, context.temp_allocator) or_else out
	}
	return strings.clone(out, allocator)
}

// ctl_collect_decrypted_pairs walks a tree beside its decrypted copy and records every
// (armored, plaintext) string pair that `ctl_decrypt_json_value` actually produced.
//
// Diffing the two trees is what keeps the armored-field list in ONE place. Restating the
// list here -- or teaching the decrypt walk to report what it changed -- would be a
// second source of truth for which fields are sensitive, and the two would drift.
ctl_collect_decrypted_pairs :: proc(before, after: json.Value, pairs: ^[dynamic][2]string) {
	// #partial: only objects, arrays and strings can hold or be armor; scalars cannot.
	#partial switch b in before {
	case json.Object:
		a, a_ok := after.(json.Object)
		if !a_ok do return
		for key, b_val in b {
			a_val, exists := a[key]
			if !exists do continue
			ctl_collect_decrypted_pairs(b_val, a_val, pairs)
		}
	case json.Array:
		a, a_ok := after.(json.Array)
		if !a_ok do return
		for i in 0 ..< min(len(b), len(a)) {
			ctl_collect_decrypted_pairs(b[i], a[i], pairs)
		}
	case json.String:
		a, a_ok := after.(json.String)
		if !a_ok do return
		b_str, a_str := string(b), string(a)
		// Only an armored value can have been rewritten, and an unchanged one means the
		// field was not in the list (or decryption fell back to the armored text itself).
		if b_str != a_str && is_vault_armored(b_str) {
			append(pairs, [2]string{b_str, a_str})
		}
	}
}

// ctl_json_escape_bytes escapes a JSON string body BYTE-WISE, so bytes >= 0x20 -- including
// 0x80..0xFF -- pass through unchanged. It is the inverse of `jsonx.json_unescape_string`.
//
// `json_write_string` is not usable here: it iterates RUNES, so decrypted content that is
// not valid UTF-8 would come back as U+FFFD, reintroducing on the write side exactly the
// corruption this whole change removes from the read side.
ctl_json_escape_bytes :: proc(value: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for i in 0 ..< len(value) {
		switch ch := value[i]; ch {
		case '"':  strings.write_string(&b, "\\\"")
		case '\\': strings.write_string(&b, "\\\\")
		case '\n': strings.write_string(&b, "\\n")
		case '\r': strings.write_string(&b, "\\r")
		case '\t': strings.write_string(&b, "\\t")
		case 0x08: strings.write_string(&b, "\\b")
		case 0x0c: strings.write_string(&b, "\\f")
		case:
			if ch < 0x20 {
				strings.write_string(&b, fmt.tprintf("\\u%04x", u32(ch)))
			} else {
				strings.write_byte(&b, ch)
			}
		}
	}
	return strings.to_string(b)
}

