package domain

import "core:fmt"
import "core:strings"
import vault "odin_test:lib/vault"

// ── Armor-aware length caps for vault-encrypted text fields (REQ-VCAP-1/2/3) ──
//
// Content encryption in Heimdall is CLIENT-SIDE and the Hub is zero-knowledge:
// ctl encrypts a title/description before sending it, so what reaches a Hub
// length check is the ARMORED envelope, never the plaintext. Comparing len() of
// that envelope against a plaintext cap rejects callers far below the documented
// limit (iss_18d940db15f9accb).
//
// Armor overhead, derived from src/lib/vault/envelope.odin (the single producer):
//
//	armored = "vault:v2:<vault_id>:e<epoch>:" + base64(12B nonce || 16B GCM tag || ciphertext)
//
// AES-GCM is a stream mode, so len(ciphertext) == len(plaintext), and base64 is
// PADDED (4 chars per 3 input bytes, rounded up). The vault id is 16 hex characters
// and the epoch 1..10 decimal digits, so the budget assumes the longest header. For a
// plaintext of n bytes:
//
//	armored_len(n) <= len("vault:v2:") + 16 + len(":e") + 10 + 1 + 4*ceil((n + 28) / 3)
//
// The Hub CANNOT verify the plaintext length of an armored value — that is
// inherent to the zero-knowledge design and is accepted. These caps are a
// STORAGE bound, not a precise character count; ctl enforces the real plaintext
// budget locally before encrypting (REQ-VCAP-4).

// VAULT_ARMOR_PREFIX is the self-describing wire marker for an encrypted value.
// Older formats are dead: the hub treats them as ordinary text.
VAULT_ARMOR_PREFIX :: vault.VAULT_V2_PREFIX

// VAULT_HEADER_BYTES is the per-value nonce+tag overhead inside the base64 payload.
VAULT_HEADER_BYTES :: vault.HEADER_BYTES

// VAULT_MAX_TOKEN_HEADER_LEN is len("vault:v2:" + 16 hex + ":e" + 10 digits + ":").
VAULT_MAX_TOKEN_HEADER_LEN :: len(VAULT_ARMOR_PREFIX) + vault.VAULT_ID_HEX_CHARS + 2 + 10 + 1

// is_vault_armored reports whether a value is a v2 encrypted vault envelope.
//
// has_prefix, deliberately: for a length cap `contains` would let any caller bypass
// the plaintext cap by embedding the marker mid-string. Redaction/preview helpers
// that must fail safe use contains_vault_token instead.
is_vault_armored :: proc(text: string) -> bool {
	return vault.is_armored(text)
}

// vault_token_prefix_len returns the length of the full "vault:v2:<vault_id>:e<N>:"
// header when s starts with a well-formed v2 token, else 0.
vault_token_prefix_len :: proc(s: string) -> int {
	if !vault.is_armored(s) do return 0
	start, end := vault.next_token(s, 0)
	if start != 0 || end <= 0 do return 0
	_, _, body, res := vault.envelope_header(s[:end])
	if res != .Ok do return 0
	return end - len(body)
}

// vault_token_epoch parses the epoch from a value that starts with a v2 token header.
vault_token_epoch :: proc(s: string) -> (epoch: u32, ok: bool) {
	if !vault.is_armored(s) do return 0, false
	start, end := vault.next_token(s, 0)
	if start != 0 || end <= 0 do return 0, false
	_, ep, _, res := vault.envelope_header(s[:end])
	return ep, res == .Ok
}

// contains_vault_token reports whether s carries the v2 armor marker anywhere. It is
// the fail-safe test for redaction/preview paths: a body that merely mentions the
// prefix is treated as armored too, so no ciphertext shape is ever previewed raw.
contains_vault_token :: proc(s: string) -> bool {
	return strings.contains(s, VAULT_ARMOR_PREFIX)
}

// vault_armored_max_bytes returns the storage budget for a vault-armored value
// whose plaintext is capped at plaintext_max bytes (see derivation above).
vault_armored_max_bytes :: proc(plaintext_max: int) -> int {
	if plaintext_max < 0 do return VAULT_MAX_TOKEN_HEADER_LEN
	return VAULT_MAX_TOKEN_HEADER_LEN + 4 * ((plaintext_max + VAULT_HEADER_BYTES + 2) / 3)
}

// text_cap_limit_bytes returns the effective byte limit to enforce against
// value: the inflated armored budget when value is encrypted, else the
// plaintext cap itself.
text_cap_limit_bytes :: proc(value: string, plaintext_max: int) -> int {
	if is_vault_armored(value) do return vault_armored_max_bytes(plaintext_max)
	return plaintext_max
}

// validate_capped_text enforces an armor-aware byte cap on a text field and
// returns a Validation_Failed error naming BOTH the actual length and the
// effective limit (REQ-VCAP-3) — an error without numbers gives the caller no
// hint how much to cut. label is the field phrase, e.g. "chain description".
// Returns a zero Domain_Error (code .None) when the value fits.
//
// The message is built with fmt.tprintf, the established convention for dynamic
// domain error messages in this tree; the string is consumed while rendering the
// current request's response, so temp-allocator lifetime is sufficient.
validate_capped_text :: proc(label: string, value: string, plaintext_max: int) -> Domain_Error {
	limit := text_cap_limit_bytes(value, plaintext_max)
	if len(value) <= limit do return Domain_Error{}
	if is_vault_armored(value) {
		return domain_error(.Validation_Failed, fmt.tprintf(
			"%s is too long: %d bytes, limit %d (encrypted; ~%d plaintext)",
			label, len(value), limit, plaintext_max,
		))
	}
	return domain_error(.Validation_Failed, fmt.tprintf(
		"%s is too long: %d bytes, limit %d", label, len(value), limit,
	))
}

// VAULT_PTY_V2_ARMOR_MIN_BYTES is the smallest armored PTY v2 body: salt16 | nonce | tag.
VAULT_PTY_V2_ARMOR_MIN_BYTES :: vault.PTY_V2_HEADER_BYTES - 4

// vault_pty_v2_payload_from_armor converts a "vault:v2:<vault_id>:e<N>:<b64(salt16|nonce|tag|ct)>"
// token (an armored PTY v2 frame: pane capture, REST input) into the PTY v2 binary
// layout u32be(N) | salt16 | nonce | tag | ct, preserving the epoch the bridge/browser
// must check. The hub never decrypts; it only re-frames, passing salt and nonce through
// unchanged. Returns false for anything that is not exactly one well-formed v2 token
// long enough to hold a PTY v2 header.
vault_pty_v2_payload_from_armor :: proc(armor: string, allocator := context.allocator) -> (payload: []byte, ok: bool) {
	_, epoch, body, res := vault.envelope_parse(armor, context.temp_allocator)
	if res != .Ok || len(body) < VAULT_PTY_V2_ARMOR_MIN_BYTES do return nil, false
	out := make([]byte, 4 + len(body), allocator)
	out[0] = byte(epoch >> 24)
	out[1] = byte(epoch >> 16)
	out[2] = byte(epoch >> 8)
	out[3] = byte(epoch)
	copy(out[4:], body)
	return out, true
}
