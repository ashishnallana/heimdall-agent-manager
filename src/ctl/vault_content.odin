package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import jsonx "odin_test:lib/jsonx"
import vault "odin_test:lib/vault"

// ── Content cryptography (REQ-VAULT-CONTENT-LIB-1, passwordless vault P1) ────
// The wire format lives in src/lib/vault: 'vault:v2:e<epoch>:<b64(nonce|tag|ct)>'
// with AAD 'heimdall-vault-v2|e<epoch>'. ham-ctl seals under the keyring's CURRENT
// epoch and opens by the epoch in the token header. v1 ('vault:v1:'/'ENC:v1:') tokens
// are dead: they are not armored as far as ham-ctl is concerned and are never decoded.

VAULT_ARMOR_PREFIX :: vault.VAULT_V2_PREFIX

// Check if a string has the self-describing v2 vault armor prefix.
is_vault_armored :: proc(text: string) -> bool {
	return vault.is_armored(text)
}

// ctl_vault_seal encrypts plaintext under the keyring's current epoch. ok=false on a
// missing keyring or a CSPRNG failure; nothing is produced in that case.
ctl_vault_seal :: proc(plaintext: string, kr: ^vault.Vault_Keyring, allocator := context.allocator) -> (armored: string, ok: bool) {
	if kr == nil do return "", false
	return vault.seal(transmute([]byte)plaintext, kr, allocator)
}

// ctl_seal_or_exit is the call-site form for fields that MUST be encrypted once a
// keyring is configured: if sealing fails the command aborts instead of sending the
// plaintext (fail closed, never a silent downgrade).
ctl_seal_or_exit :: proc(plaintext: string, kr: ^vault.Vault_Keyring) -> string {
	armored, ok := ctl_vault_seal(plaintext, kr, context.temp_allocator)
	if !ok {
		fmt.println(`{"ok":false,"message":"vault encryption failed; refusing to send plaintext"}`)
		os.exit(1)
	}
	return armored
}

// ctl_vault_open decrypts a v2 token. A value that is not v2-armored (plain text or
// a dead v1 token) is returned unchanged with result .Not_Armored.
ctl_vault_open :: proc(armored: string, kr: ^vault.Vault_Keyring, allocator := context.allocator) -> (plaintext: string, result: vault.Open_Result) {
	if !vault.is_armored(armored) do return strings.clone(armored, allocator), .Not_Armored
	return vault.open(armored, kr, allocator)
}

// Remedy hints appended after the '[Encrypted: ...]' fallback so a reader learns both the
// cause and the next step (REQ-VAULT-3).
VAULT_HINT_NO_KEY   :: "(vault key not configured — see `ham-ctl vault status`)"
VAULT_HINT_LOCKED   :: "(this value uses a vault epoch this keyring does not hold — see `ham-ctl vault status`)"
VAULT_HINT_BAD_KEY  :: "(configured vault key cannot decrypt this value — see `ham-ctl vault status`)"

// Decrypt an armored field, or return '[Encrypted: vault:v2:...] (<remedy hint>)' when it
// cannot be decrypted. The hint distinguishes: no keyring, an epoch the keyring does
// not hold (locked), and a value that fails to parse or authenticate.
ctl_decrypt_or_fallback_armored :: proc(val: string, kr: ^vault.Vault_Keyring, key_configured: bool, allocator := context.allocator) -> string {
	if !is_vault_armored(val) {
		return strings.clone(val, allocator)
	}
	hint := VAULT_HINT_NO_KEY
	if key_configured && kr != nil {
		decrypted, res := vault.open(val, kr, allocator)
		#partial switch res {
		case .Ok:
			return decrypted
		case .Unknown_Epoch:
			hint = VAULT_HINT_LOCKED
		case:
			hint = VAULT_HINT_BAD_KEY
		}
	}
	return fmt.aprintf("[Encrypted: %s] %s", val, hint, allocator = allocator)
}

Json_Field_Update :: struct {
	k: string,
	v: json.Value,
}

ctl_decrypt_json_value :: proc(v: ^json.Value, kr: ^vault.Vault_Keyring, key_configured: bool, allocator := context.allocator) {
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
						new_str := ctl_decrypt_or_fallback_armored(str_val, kr, key_configured, allocator)
						append(&updates, Json_Field_Update{k = k, v = json.String(new_str)})
					}
				}
			case:
				#partial switch _ in sub_v {
				case json.Object, json.Array:
					var := sub_v
					ctl_decrypt_json_value(&var, kr, key_configured, allocator)
					append(&updates, Json_Field_Update{k = k, v = var})
				}
			}
		}
		for u in updates {
			val[u.k] = u.v
		}
	case json.Array:
		for i in 0 ..< len(val) {
			ctl_decrypt_json_value(&val[i], kr, key_configured, allocator)
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
// `vault:v2:` tokens sit in fields that `ctl_decrypt_json_value` decrypts and what each
// one becomes; those substitutions are then spliced into the original text. Anything not
// armored -- binary artifact content above all -- is copied through verbatim, so the
// output is the hub's own JSON with ciphertext swapped for plaintext.
//
// Deliberately NOT changed: the armored-field list (`ctl_decrypt_json_value`, :160) and
// the decrypt/fallback semantics. The two-parse-and-diff below exists precisely so that
// this proc can observe what those do without restating or altering any of it.
ctl_decrypt_json_string :: proc(raw_json: string, kr: ^vault.Vault_Keyring, key_configured: bool, allocator := context.allocator) -> string {
	// Fast path: `vault:v2:` is pure ASCII and contains nothing JSON escaping would
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

	ctl_decrypt_json_value(&decrypted, kr, key_configured, context.temp_allocator)

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

