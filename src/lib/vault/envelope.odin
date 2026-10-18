// Package vault is the single Odin implementation of the passwordless-vault wire
// formats (docs/plans/passwordless-vault.md §1): the v2 content envelope, the HKR1
// keyring, canonical signed statements and their algorithm allowlist, the bridge
// unseal v2 cipher, PTY v2 frames and the v2 search key. The bridge, ham-ctl and the
// hub all use it, so each format exists in exactly one Odin place; the TypeScript
// mirror lives in src/ui/utils/vault*.ts and both are pinned by the shared vectors in
// tests/fixtures/vault_v2_vectors.json.
//
// Everything here FAILS CLOSED: a parse that is not exactly canonical is rejected, an
// unknown algorithm id is rejected, a randomness failure aborts the seal, and there is
// no plaintext fallback for anything that claims to be armored.
package vault

import "core:crypto"
import "core:crypto/aes"
import "core:encoding/base64"
import "core:strconv"
import "core:strings"
import os_random "odin_test:lib/os_random"

VAULT_V2_PREFIX     :: "vault:v2:"
NONCE_BYTES         :: 12
TAG_BYTES           :: 16
KEY_BYTES           :: 32
HEADER_BYTES        :: NONCE_BYTES + TAG_BYTES // 28
MAX_EPOCH           :: u32(4294967295)
// MAX_PAYLOAD_BYTES bounds the decoded nonce|tag|ct of one envelope. It sits below the
// hub's 80 MiB request cap; anything larger is rejected before it is decoded.
MAX_PAYLOAD_BYTES   :: 64 * 1024 * 1024
MAX_B64_LEN         :: ((MAX_PAYLOAD_BYTES + 2) / 3) * 4
ENVELOPE_AAD_PREFIX :: "heimdall-vault-v2|e"

// LOCKED_MARKER is what a token becomes when its epoch key is not held (no keyring,
// or an epoch this keyring does not contain). FAILED_MARKER is a token that names a
// held epoch but does not authenticate.
LOCKED_MARKER :: "[encrypted: vault key unavailable]"
FAILED_MARKER :: "[Encrypted]"

Open_Result :: enum {
	Ok,
	Not_Armored,   // not a v2 token at all (plain text, or a dead v1 token)
	Malformed,     // claims to be v2 but is not exactly canonical
	Unknown_Epoch, // well formed, but the keyring holds no key for its epoch
	Auth_Failed,   // the key for its epoch does not authenticate it
	No_Keyring,    // well formed, but no keyring was supplied
}

// is_armored reports whether s starts with the v2 prefix. It is the cheap
// classification test; open() decides whether the token is actually valid.
is_armored :: proc(s: string) -> bool {
	return strings.has_prefix(s, VAULT_V2_PREFIX)
}

// contains_token reports whether s contains at least one complete v2 token.
contains_token :: proc(s: string) -> bool {
	start, _ := next_token(s, 0)
	return start >= 0
}

// parse_epoch accepts exactly the decimal grammar [1-9][0-9]{0,9} with value <= MAX_EPOCH.
parse_epoch :: proc(digits: string) -> (epoch: u32, ok: bool) {
	if len(digits) == 0 || len(digits) > 10 do return 0, false
	if digits[0] < '1' || digits[0] > '9' do return 0, false
	v: u64 = 0
	for i in 0 ..< len(digits) {
		c := digits[i]
		if c < '0' || c > '9' do return 0, false
		v = v * 10 + u64(c - '0')
	}
	if v == 0 || v > u64(MAX_EPOCH) do return 0, false
	return u32(v), true
}

// write_epoch_aad renders "heimdall-vault-v2|e<epoch>" into buf.
envelope_aad :: proc(epoch: u32, buf: []byte) -> []byte {
	n := copy(buf, ENVELOPE_AAD_PREFIX)
	digits := strconv.write_uint(buf[n:], u64(epoch), 10)
	return buf[:n + len(digits)]
}

@(private)
is_b64_char :: #force_inline proc(c: byte) -> bool {
	switch c {
	case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '+', '/':
		return true
	}
	return false
}

@(private)
b64_value :: proc(c: byte) -> u8 {
	switch c {
	case 'A' ..= 'Z': return c - 'A'
	case 'a' ..= 'z': return c - 'a' + 26
	case '0' ..= '9': return c - '0' + 52
	case '+':         return 62
	case '/':         return 63
	}
	return 0xff
}

// b64_decode_strict decodes standard padded base64 and rejects anything that is not
// the unique canonical encoding: wrong length, misplaced or excess padding, foreign
// characters (including the URL-safe alphabet) and non-zero trailing bits.
b64_decode_strict :: proc(s: string, allocator := context.allocator) -> (out: []byte, ok: bool) {
	if len(s) == 0 || len(s) % 4 != 0 do return nil, false
	pad := 0
	if s[len(s) - 1] == '=' do pad += 1
	if len(s) >= 2 && s[len(s) - 2] == '=' do pad += 1
	body := s[:len(s) - pad]
	for i in 0 ..< len(body) {
		if !is_b64_char(body[i]) do return nil, false
	}
	// Non-zero bits under the padding make a second spelling of the same bytes.
	if pad == 2 && b64_value(body[len(body) - 1]) & 0x0f != 0 do return nil, false
	if pad == 1 && b64_value(body[len(body) - 1]) & 0x03 != 0 do return nil, false
	decoded, err := base64.decode(s, allocator = allocator)
	if err != nil do return nil, false
	if len(decoded) != (len(s) / 4) * 3 - pad {
		delete(decoded, allocator)
		return nil, false
	}
	return decoded, true
}

// token_end returns the end of the token grammar match that starts at text[start]
// (which must begin with VAULT_V2_PREFIX), or -1. It reproduces the TS regex
// /vault:v2:e[1-9][0-9]{0,9}:[A-Za-z0-9+/]+={0,2}/ exactly, including greediness.
@(private)
token_end :: proc(text: string, start: int) -> int {
	i := start + len(VAULT_V2_PREFIX)
	if i >= len(text) || text[i] != 'e' do return -1
	i += 1
	if i >= len(text) || text[i] < '1' || text[i] > '9' do return -1
	digits := 1
	i += 1
	for i < len(text) && text[i] >= '0' && text[i] <= '9' {
		digits += 1
		if digits > 10 do return -1
		i += 1
	}
	if i >= len(text) || text[i] != ':' do return -1
	i += 1
	body_start := i
	for i < len(text) && is_b64_char(text[i]) do i += 1
	if i == body_start do return -1
	pads := 0
	for i < len(text) && text[i] == '=' && pads < 2 {
		i += 1
		pads += 1
	}
	return i
}

// next_token finds the leftmost complete v2 token at or after from. It returns
// (-1, -1) when there is none. A bare "vault:v2:" (prose mentioning the prefix) is
// not a token.
next_token :: proc(text: string, from: int) -> (start: int, end: int) {
	pos := from
	for pos < len(text) {
		rel := strings.index(text[pos:], VAULT_V2_PREFIX)
		if rel < 0 do return -1, -1
		s := pos + rel
		if e := token_end(text, s); e > 0 do return s, e
		pos = s + 1
	}
	return -1, -1
}

// envelope_parse splits a complete token (and nothing else) into its epoch and decoded
// payload. The payload is allocated with allocator.
envelope_parse :: proc(token: string, allocator := context.allocator) -> (epoch: u32, payload: []byte, result: Open_Result) {
	if !is_armored(token) do return 0, nil, .Not_Armored
	if token_end(token, 0) != len(token) do return 0, nil, .Malformed
	rest := token[len(VAULT_V2_PREFIX) + 1:] // past "e"
	colon := strings.index_byte(rest, ':')
	if colon < 0 do return 0, nil, .Malformed
	ep, ep_ok := parse_epoch(rest[:colon])
	if !ep_ok do return 0, nil, .Malformed
	b64 := rest[colon + 1:]
	if len(b64) > MAX_B64_LEN do return 0, nil, .Malformed
	decoded, dec_ok := b64_decode_strict(b64, allocator)
	if !dec_ok do return 0, nil, .Malformed
	if len(decoded) < HEADER_BYTES || len(decoded) > MAX_PAYLOAD_BYTES {
		crypto.zero_explicit(raw_data(decoded), len(decoded))
		delete(decoded, allocator)
		return 0, nil, .Malformed
	}
	return ep, decoded, .Ok
}

// seal_with_nonce is the deterministic core of seal. Production callers use seal or
// seal_with_key, which draw the nonce from the OS CSPRNG; this exists for vectors.
seal_with_nonce :: proc(plaintext: []byte, key: []byte, epoch: u32, nonce: []byte, allocator := context.allocator) -> (token: string, ok: bool) {
	if len(key) != KEY_BYTES || len(nonce) != NONCE_BYTES || epoch == 0 do return "", false
	if len(plaintext) > MAX_PAYLOAD_BYTES - HEADER_BYTES do return "", false
	payload := make([]byte, HEADER_BYTES + len(plaintext), context.temp_allocator)
	defer crypto.zero_explicit(raw_data(payload), len(payload))
	copy(payload[:NONCE_BYTES], nonce)
	aad_buf: [64]byte
	aad := envelope_aad(epoch, aad_buf[:])
	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, key)
	defer aes.reset_gcm(&gcm)
	aes.seal_gcm(&gcm, payload[HEADER_BYTES:], payload[NONCE_BYTES:HEADER_BYTES], nonce, aad, plaintext)
	b64, err := base64.encode(payload, allocator = context.temp_allocator)
	if err != nil do return "", false
	epoch_buf: [16]byte
	epoch_str := strconv.write_uint(epoch_buf[:], u64(epoch), 10)
	return strings.concatenate({VAULT_V2_PREFIX, "e", epoch_str, ":", b64}, allocator), true
}

// seal_with_key seals under an explicit epoch key with a fresh CSPRNG nonce. A
// randomness failure returns ok=false and nothing is produced.
seal_with_key :: proc(plaintext: []byte, key: []byte, epoch: u32, allocator := context.allocator, random_source := os_random.DEFAULT_SOURCE) -> (token: string, ok: bool) {
	nonce: [NONCE_BYTES]byte
	if !os_random.fill(nonce[:], random_source) do return "", false
	return seal_with_nonce(plaintext, key, epoch, nonce[:], allocator)
}

// seal encrypts under the keyring's CURRENT epoch; encryption never uses an older one.
seal :: proc(plaintext: []byte, kr: ^Vault_Keyring, allocator := context.allocator, random_source := os_random.DEFAULT_SOURCE) -> (token: string, ok: bool) {
	if kr == nil do return "", false
	key, key_ok := keyring_key_for_epoch(kr, kr.current_epoch)
	if !key_ok do return "", false
	return seal_with_key(plaintext, key, kr.current_epoch, allocator, random_source)
}

seal_string :: proc(plaintext: string, kr: ^Vault_Keyring, allocator := context.allocator) -> (token: string, ok: bool) {
	return seal(transmute([]byte)plaintext, kr, allocator)
}

// open_with_key authenticates payload (nonce|tag|ct) for epoch under key.
open_payload_with_key :: proc(payload: []byte, key: []byte, epoch: u32, allocator := context.allocator) -> (plaintext: []byte, ok: bool) {
	if len(key) != KEY_BYTES || len(payload) < HEADER_BYTES do return nil, false
	aad_buf: [64]byte
	aad := envelope_aad(epoch, aad_buf[:])
	ct := payload[HEADER_BYTES:]
	dst := make([]byte, len(ct), allocator)
	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, key)
	defer aes.reset_gcm(&gcm)
	if !aes.open_gcm(&gcm, dst, payload[:NONCE_BYTES], aad, ct, payload[NONCE_BYTES:HEADER_BYTES]) {
		delete(dst, allocator)
		return nil, false
	}
	return dst, true
}

// open decrypts a complete token with the key for the epoch in its header. The
// returned plaintext is allocated with allocator and is set only when result == .Ok.
open :: proc(token: string, kr: ^Vault_Keyring, allocator := context.allocator) -> (plaintext: string, result: Open_Result) {
	epoch, payload, parse_result := envelope_parse(token, context.temp_allocator)
	if parse_result != .Ok do return "", parse_result
	defer crypto.zero_explicit(raw_data(payload), len(payload))
	if kr == nil do return "", .No_Keyring
	key, key_ok := keyring_key_for_epoch(kr, epoch)
	if !key_ok do return "", .Unknown_Epoch
	plain, ok := open_payload_with_key(payload, key, epoch, allocator)
	if !ok do return "", .Auth_Failed
	return string(plain), .Ok
}

// replace_embedded_tokens rewrites every v2 token inside text:
//   - decrypted to its plaintext when it opens;
//   - locked_marker when there is no keyring or its epoch is not held (an empty
//     locked_marker keeps the token verbatim);
//   - failed_marker when it names a held epoch but is malformed or does not
//     authenticate.
// Dead v1 tokens are not v2 tokens and stay verbatim; they are never decrypted.
// Caller owns the result.
replace_embedded_tokens :: proc(text: string, kr: ^Vault_Keyring, locked_marker: string = LOCKED_MARKER, failed_marker: string = FAILED_MARKER, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	pos := 0
	for pos < len(text) {
		s, e := next_token(text, pos)
		if s < 0 do break
		strings.write_string(&b, text[pos:s])
		token := text[s:e]
		plain, res := open(token, kr, context.temp_allocator)
		switch res {
		case .Ok:
			strings.write_string(&b, plain)
			crypto.zero_explicit(raw_data(plain), len(plain))
		case .No_Keyring, .Unknown_Epoch:
			strings.write_string(&b, locked_marker if locked_marker != "" else token)
		case .Malformed, .Auth_Failed, .Not_Armored:
			strings.write_string(&b, failed_marker)
		}
		pos = e
	}
	strings.write_string(&b, text[pos:])
	return strings.to_string(b)
}
