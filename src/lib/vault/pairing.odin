package vault

import "core:crypto"
import "core:crypto/hkdf"
import "core:crypto/hmac"
import "core:strings"
import os_random "odin_test:lib/os_random"

// ── Hub-blind device pairing (docs/plans/passwordless-vault.md §1 "Pairing") ──
//
// The new device (browser or bridge) draws a secret pairing code S: 12 base32
// symbols, 60 bits. S is SHOWN to the user and typed ONCE on an approving device; it
// is never sent to the hub. From S both sides derive (HKDF-SHA256, 32 zero-byte salt,
// IKM = the 12 canonical symbols as ASCII, no dashes):
//
//   lookup  = HKDF(S, info "heimdall-pair/v1|lookup")   hub-side index of the pending request
//   K_mac   = HKDF(S, info "heimdall-pair/v1|mac")      MAC key, never leaves the two devices
//
//   key_mac  = HMAC(K_mac, "heimdall-pair-key/v1|<kind>|<payload>")
//              browser payload: the canonical self-signed register statement
//              bridge  payload: "<identity_pub>|<ecdh_pub>|<code_challenge>"
//   pair_mac = HMAC(K_mac, "heimdall-pair-approve/v1|<approval statement>|<root_sign_pub>|<head_hash>")
//              head_hash = log_entry_hash(approval statement) (the head the approval creates)
//
// key_mac lets the approver prove the hub did not swap the new device's keys;
// pair_mac lets the new device prove its approval (and, through the approval's
// prev_hash chain, the whole log prefix including genesis/root) came from a device
// the user typed S into. The hub stores lookup + key_mac only; without S it cannot
// forge either MAC. S has 60 bits: offline search over lookup/key_mac is infeasible
// within the code lifetime (PAIR_CODE_TTL_SECONDS), after which the hub purges the
// pending request and the new device refuses to use S.

PAIR_CODE_ALPHABET     :: "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
PAIR_CODE_SYMBOLS      :: 12
PAIR_CODE_TTL_SECONDS  :: 600
PAIR_LOOKUP_INFO       :: "heimdall-pair/v1|lookup"
PAIR_MAC_INFO          :: "heimdall-pair/v1|mac"
PAIR_KEY_PREFIX        :: "heimdall-pair-key/v1|"
PAIR_APPROVE_PREFIX    :: "heimdall-pair-approve/v1|"
PAIR_HEX_CHARS         :: 64

// Pair_Keys is what S derives to. Wipe with pair_keys_wipe.
Pair_Keys :: struct {
	lookup:  [32]byte,
	mac_key: [32]byte,
}

pair_keys_wipe :: proc "contextless" (k: ^Pair_Keys) {
	crypto.zero_explicit(k, size_of(Pair_Keys))
}

// pair_code_symbols folds case and drops spaces/tabs/dashes; anything else, or a
// symbol count other than 12, is rejected. Returns the 12 canonical symbols.
pair_code_symbols :: proc(raw: string) -> (symbols: [PAIR_CODE_SYMBOLS]u8, ok: bool) {
	if len(raw) > 64 do return {}, false
	count := 0
	for i := 0; i < len(raw); i += 1 {
		c := raw[i]
		switch c {
		case ' ', '\t', '-':
			continue
		case 'a' ..= 'z':
			c -= 'a' - 'A'
		}
		if strings.index_byte(PAIR_CODE_ALPHABET, c) < 0 do return {}, false
		if count == PAIR_CODE_SYMBOLS do return {}, false
		symbols[count] = c
		count += 1
	}
	return symbols, count == PAIR_CODE_SYMBOLS
}

// pair_code_normalize renders the canonical display form "XXXX-XXXX-XXXX".
pair_code_normalize :: proc(raw: string, allocator := context.allocator) -> (string, bool) {
	s, ok := pair_code_symbols(raw)
	if !ok do return "", false
	return strings.concatenate({string(s[0:4]), "-", string(s[4:8]), "-", string(s[8:12])}, allocator), true
}

// pair_code_generate draws a fresh code from the OS CSPRNG (256 % 32 == 0: no bias).
// Fails closed when randomness is unavailable.
pair_code_generate :: proc(allocator := context.allocator, random_source := os_random.DEFAULT_SOURCE) -> (string, bool) {
	raw: [PAIR_CODE_SYMBOLS]byte
	defer crypto.zero_explicit(&raw, size_of(raw))
	if !os_random.fill(raw[:], random_source) do return "", false
	out: [PAIR_CODE_SYMBOLS]u8
	defer crypto.zero_explicit(&out, size_of(out))
	alphabet := PAIR_CODE_ALPHABET
	for i in 0 ..< PAIR_CODE_SYMBOLS do out[i] = alphabet[int(raw[i]) % len(alphabet)]
	return pair_code_normalize(string(out[:]), allocator)
}

// pair_keys_derive derives lookup and K_mac from a (raw or canonical) code.
pair_keys_derive :: proc(code: string) -> (keys: Pair_Keys, ok: bool) {
	s, s_ok := pair_code_symbols(code)
	defer crypto.zero_explicit(&s, size_of(s))
	if !s_ok do return {}, false
	salt: [32]byte
	hkdf.extract_and_expand(.SHA256, salt[:], s[:], transmute([]byte)string(PAIR_LOOKUP_INFO), keys.lookup[:])
	hkdf.extract_and_expand(.SHA256, salt[:], s[:], transmute([]byte)string(PAIR_MAC_INFO), keys.mac_key[:])
	return keys, true
}

pair_lookup_hex :: proc(keys: ^Pair_Keys, allocator := context.allocator) -> string {
	return hex_encode_lower(keys.lookup[:], allocator)
}

// valid_pair_hex: a lookup / key_mac / pair_mac on the wire (64 lowercase hex).
valid_pair_hex :: proc(s: string) -> bool {
	return len(s) == PAIR_HEX_CHARS && is_lower_hex(s)
}

@(private = "file")
pair_hmac_hex :: proc(mac_key: []byte, msg: string, allocator := context.allocator) -> string {
	out: [32]byte
	hmac.sum(.SHA256, out[:], transmute([]byte)msg, mac_key)
	return hex_encode_lower(out[:], allocator)
}

// pair_bridge_payload is the bridge's key_mac payload: identity key, this enrollment's
// ECDH key and PKCE challenge (the values its identity proof also signs).
pair_bridge_payload :: proc(identity_pub_hex, ecdh_pub_hex, code_challenge: string, allocator := context.allocator) -> (string, bool) {
	if !valid_p256_public_hex(identity_pub_hex) || !valid_p256_public_hex(ecdh_pub_hex) do return "", false
	if code_challenge == "" || len(code_challenge) > 128 || !valid_id_value(code_challenge) do return "", false
	return strings.concatenate({identity_pub_hex, "|", ecdh_pub_hex, "|", code_challenge}, allocator), true
}

// pair_key_mac_hex = HMAC(K_mac, "heimdall-pair-key/v1|<kind>|<payload>").
pair_key_mac_hex :: proc(keys: ^Pair_Keys, kind, payload: string, allocator := context.allocator) -> (string, bool) {
	if (kind != "browser" && kind != "bridge") || payload == "" do return "", false
	msg := strings.concatenate({PAIR_KEY_PREFIX, kind, "|", payload}, context.temp_allocator)
	return pair_hmac_hex(keys.mac_key[:], msg, allocator), true
}

// pair_approve_mac_hex = HMAC(K_mac, "heimdall-pair-approve/v1|<approval>|<root_sign_pub>|<head_hash>")
// with head_hash = log_entry_hash(approval).
pair_approve_mac_hex :: proc(keys: ^Pair_Keys, approval_statement, root_sign_pub: string, allocator := context.allocator) -> (string, bool) {
	if approval_statement == "" || !valid_p256_public_hex(root_sign_pub) do return "", false
	head := log_entry_hash(approval_statement, context.temp_allocator)
	msg := strings.concatenate({PAIR_APPROVE_PREFIX, approval_statement, "|", root_sign_pub, "|", head}, context.temp_allocator)
	return pair_hmac_hex(keys.mac_key[:], msg, allocator), true
}

// pair_mac_equal compares two MAC hex strings in constant time (false on any shape error).
pair_mac_equal :: proc(a, b: string) -> bool {
	if !valid_pair_hex(a) || !valid_pair_hex(b) do return false
	return crypto.compare_constant_time(transmute([]byte)a, transmute([]byte)b) == 1
}
