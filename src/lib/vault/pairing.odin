package vault

import "core:crypto"
import "core:crypto/hkdf"
import "core:crypto/hmac"
import "core:crypto/pbkdf2"
import "core:encoding/json"
import "core:strings"
import os_random "odin_test:lib/os_random"

// ── Hub-blind device pairing (docs/plans/passwordless-vault.md §1 "Pairing") ──
//
// The new device (browser or bridge) draws a secret pairing code S (14 base32
// symbols, 70 bits) and a public random 16-byte pair_salt. S is SHOWN to the user and
// typed ONCE on an approving device; it is never sent to the hub. pair_salt goes to
// the hub with the registration (it is public); the approver fetches it back.
//
// PAIRING STRETCH (the pairing-code stretch, NOT the deleted password-era KDF): both
// sides first compute
//
//   K = PBKDF2-HMAC-SHA256(password = the 14 canonical symbols as ASCII,
//         salt = "heimdall-pair/v2|<kind>|<user_id>|<hub_origin>|<pair_salt hex>",
//         iterations = PAIR_STRETCH_ITERATIONS, 32 bytes)
//
// and from K (HKDF-SHA256, 32 zero-byte salt, IKM = K):
//
//   lookup  = HKDF(K, info "heimdall-pair/v2|lookup")   hub-side index of the pending request
//   K_mac   = HKDF(K, info "heimdall-pair/v2|mac")      MAC key, never leaves the two devices
//
//   key_mac  = HMAC(K_mac, "heimdall-pair-key/v1|<kind>|<payload>")
//              browser payload: the canonical self-signed register statement
//              bridge  payload: "<identity_pub>|<ecdh_pub>|<code_challenge>"
//   pair_mac = HMAC(K_mac, "heimdall-pair-approve/v1|<approval statement>|<root_sign_pub>|<head_hash>")
//              head_hash = log_entry_hash(approval statement) (the head the approval creates)
//
// <kind> is "browser" or "bridge". <user_id> is the account for a browser; a bridge
// does not know its account before approval, so it is "" there (a bridge binds the
// hub origin through K and its PKCE challenge through the key_mac payload).
// <hub_origin> is the canonical "scheme://host:port" of the hub API (explicit port,
// no path, valid_pair_hub_origin) the NEW device enrolled against. The new device
// DECLARES it publicly next to its pair_salt (pair_hub_origin) and the approver derives
// with that declared origin, but only if it is the approver's own API origin or one
// of the hub's configured aliases (--pairing-hub-origins, served with the salts).
// Guarantee: a code typed on an approver of hub H verifies only for a device that
// bound H's own API origin or an alias H's operator listed, so a device tricked into
// enrolling through a third-party relay (another origin) is refused. A hostile hub
// altering the declared origin only makes the derived lookup / key_mac miss
// (refusal); the secret code is still required either way.
//
// key_mac lets the approver prove the hub did not swap the new device's keys;
// pair_mac lets the new device prove its approval (and, through the approval's
// prev_hash chain, the whole log prefix including genesis/root) came from a device
// the user typed S into. The hub stores pair_salt, lookup and key_mac; without S it
// cannot forge either MAC. Work factor of an offline search over one request (by
// the hub, or anyone holding its pair_salt with lookup or key_mac): 2^70 codes, each
// costing PAIR_STRETCH_ITERATIONS PBKDF2-HMAC-SHA256 iterations (~2^20 iterations,
// 2^21 SHA-256 compressions), so ~2^90 iterations / 2^91 compressions to exhaust and
// half that expected. The random per-request pair_salt makes every request its own
// search: no table or precomputation carries over between requests. After
// PAIR_CODE_TTL_SECONDS the hub purges the pending request and the new device
// refuses to use S.

PAIR_CODE_ALPHABET      :: "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
PAIR_CODE_SYMBOLS       :: 14
PAIR_CODE_TTL_SECONDS   :: 600
// Pairing stretch (not the password-era KDF): PBKDF2-HMAC-SHA256 iterations.
// Measured on the Windows x64 dev machine: ~1.1-1.6 s per derivation with the
// default `odin build` optimization the release builds use, ~0.25 s in WebCrypto.
PAIR_STRETCH_ITERATIONS :: 1_000_000
PAIR_STRETCH_PREFIX     :: "heimdall-pair/v2|"
PAIR_SALT_BYTES         :: 16
PAIR_SALT_HEX_CHARS     :: 32
PAIR_HUB_ORIGIN_MAX     :: 255
PAIR_LOOKUP_INFO        :: "heimdall-pair/v2|lookup"
PAIR_MAC_INFO           :: "heimdall-pair/v2|mac"
PAIR_KEY_PREFIX         :: "heimdall-pair-key/v1|"
PAIR_APPROVE_PREFIX     :: "heimdall-pair-approve/v1|"
PAIR_HEX_CHARS          :: 64

// Pair_Keys is what S derives to. Wipe with pair_keys_wipe.
Pair_Keys :: struct {
	lookup:  [32]byte,
	mac_key: [32]byte,
}

// Pair_Context is the public input of the pairing stretch (see the header).
Pair_Context :: struct {
	kind:       string, // "browser" | "bridge"
	user_id:    string, // browser: the account id; bridge: "" (unknown before approval)
	hub_origin: string, // canonical "http(s)://host:port" (valid_pair_hub_origin)
	pair_salt:  string, // PAIR_SALT_HEX_CHARS lowercase hex, random per request
}

pair_keys_wipe :: proc "contextless" (k: ^Pair_Keys) {
	crypto.zero_explicit(k, size_of(Pair_Keys))
}

// pair_code_symbols folds ASCII case and drops spaces/tabs/dashes; anything else, or
// a symbol count other than PAIR_CODE_SYMBOLS, is rejected.
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

// pair_code_normalize renders the canonical display form "XXXX-XXXX-XXXX-XX".
pair_code_normalize :: proc(raw: string, allocator := context.allocator) -> (string, bool) {
	s, ok := pair_code_symbols(raw)
	defer crypto.zero_explicit(&s, size_of(s))
	if !ok do return "", false
	return strings.concatenate({string(s[0:4]), "-", string(s[4:8]), "-", string(s[8:12]), "-", string(s[12:14])}, allocator), true
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

// pair_salt_generate draws a fresh public pair_salt (lowercase hex). Fails closed.
pair_salt_generate :: proc(allocator := context.allocator, random_source := os_random.DEFAULT_SOURCE) -> (string, bool) {
	raw: [PAIR_SALT_BYTES]byte
	if !os_random.fill(raw[:], random_source) do return "", false
	return hex_encode_lower(raw[:], allocator), true
}

// valid_pair_salt_hex: a pair_salt on the wire (32 lowercase hex).
valid_pair_salt_hex :: proc(s: string) -> bool {
	return len(s) == PAIR_SALT_HEX_CHARS && is_lower_hex(s)
}

// valid_pair_hub_origin accepts only the canonical form both sides compute:
// "http://" or "https://", a lowercase host (a DNS name or dotted IPv4 without a
// trailing dot, or a bracketed IPv6 literal), ":" and a decimal port 1..65535 with no
// leading zero. No path, query, userinfo or "|".
valid_pair_hub_origin :: proc(s: string) -> bool {
	if len(s) == 0 || len(s) > PAIR_HUB_ORIGIN_MAX do return false
	rest: string
	switch {
	case strings.has_prefix(s, "https://"):
		rest = s[len("https://"):]
	case strings.has_prefix(s, "http://"):
		rest = s[len("http://"):]
	case:
		return false
	}
	colon := strings.last_index_byte(rest, ':')
	if colon <= 0 do return false
	host, port := rest[:colon], rest[colon + 1:]
	if len(port) == 0 || len(port) > 5 || port[0] == '0' do return false
	n := 0
	for i in 0 ..< len(port) {
		if port[i] < '0' || port[i] > '9' do return false
		n = n * 10 + int(port[i] - '0')
	}
	if n > 65535 do return false
	if host[0] == '[' {
		if len(host) < 4 || host[len(host) - 1] != ']' do return false
		for i in 1 ..< len(host) - 1 {
			switch host[i] {
			case '0' ..= '9', 'a' ..= 'f', ':', '.':
			case:
				return false
			}
		}
		return true
	}
	if host[0] == '.' || host[len(host) - 1] == '.' || strings.contains(host, "..") do return false
	for i in 0 ..< len(host) {
		switch host[i] {
		case 'a' ..= 'z', '0' ..= '9', '.', '-':
		case:
			return false
		}
	}
	return true
}

// pair_stretch_salt is the PBKDF2 salt string for c, or false when c is malformed
// (unknown kind, a browser without / a bridge with a user id, a user id that is not a
// vault id value, a non-canonical origin, a malformed pair_salt).
pair_stretch_salt :: proc(c: Pair_Context, allocator := context.allocator) -> (string, bool) {
	switch c.kind {
	case "browser":
		if c.user_id == "" || len(c.user_id) > 128 || !valid_id_value(c.user_id) do return "", false
	case "bridge":
		if c.user_id != "" do return "", false
	case:
		return "", false
	}
	if !valid_pair_hub_origin(c.hub_origin) || !valid_pair_salt_hex(c.pair_salt) do return "", false
	return strings.concatenate({PAIR_STRETCH_PREFIX, c.kind, "|", c.user_id, "|", c.hub_origin, "|", c.pair_salt}, allocator), true
}

// pair_keys_from_stretched derives lookup and K_mac from the stretched key K.
pair_keys_from_stretched :: proc(k: []byte) -> (keys: Pair_Keys) {
	salt: [32]byte
	hkdf.extract_and_expand(.SHA256, salt[:], k, transmute([]byte)string(PAIR_LOOKUP_INFO), keys.lookup[:])
	hkdf.extract_and_expand(.SHA256, salt[:], k, transmute([]byte)string(PAIR_MAC_INFO), keys.mac_key[:])
	return keys
}

// pair_keys_derive runs the pairing stretch over a (raw or canonical) code for
// context c, then derives lookup and K_mac. Costs PAIR_STRETCH_ITERATIONS iterations.
pair_keys_derive :: proc(code: string, c: Pair_Context) -> (keys: Pair_Keys, ok: bool) {
	s, s_ok := pair_code_symbols(code)
	defer crypto.zero_explicit(&s, size_of(s))
	if !s_ok do return {}, false
	salt, salt_ok := pair_stretch_salt(c, context.temp_allocator)
	if !salt_ok do return {}, false
	k: [32]byte
	defer crypto.zero_explicit(&k, size_of(k))
	// Pairing stretch (not password-era): PBKDF2-HMAC-SHA256 over the pairing code.
	pbkdf2.derive(.SHA256, s[:], transmute([]byte)salt, PAIR_STRETCH_ITERATIONS, k[:])
	return pair_keys_from_stretched(k[:]), true
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

// pair_verify_bridge_first_pin checks the pair_mac of a bridge's FIRST unseal (no
// pinned root yet): HMAC under the bridge's pairing code over its own approval
// statement (proof.subject_approval) and the proof's root key. Call it only after
// bridge_chain_verify accepted `proof_value` (which checked the approval names this
// bridge and chains to that root). The hub lacks the code, so it cannot race the
// approver with its own root.
pair_verify_bridge_first_pin :: proc(keys: ^Pair_Keys, proof_value: json.Value, pair_mac: string) -> bool {
	p, p_ok := proof_value.(json.Object)
	if !p_ok do return false
	sa, sa_ok := p["subject_approval"].(json.Object)
	if !sa_ok do return false
	statement, st_ok := sa["statement"].(json.String)
	root, r_ok := p["root_sign_pub"].(json.String)
	if !st_ok || !r_ok do return false
	want, ok := pair_approve_mac_hex(keys, string(statement), string(root), context.temp_allocator)
	return ok && pair_mac_equal(want, pair_mac)
}