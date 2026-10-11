// Device-authorization code generation (ELDA-1).
//
// Two unlinkable codes per grant:
//   - device_code: high-entropy opaque secret the device polls with (>=128-bit).
//   - user_code:   short, human-typed code shown in the browser ([A-Z2-7], dashed).
//
// The two codes MUST be generated from independent random sources — device_code
// is never derived from user_code (or vice versa), so an attacker who learns the
// short user_code cannot recover the device_code (AC2 unlinkability).
//
// Randomness comes from the OS CSPRNG (/dev/urandom), NOT from math/random or a
// timestamp-based generator: device_code has to be unguessable or an attacker
// could enumerate it to poll for a victim's token.

package device_auth

import "core:os"
import "core:strings"

// DEVICE_CODE_RANDOM_BYTES = 32 bytes => 256 bits of entropy (>= 128-bit required).
// Hex-encoded to a 64-char opaque string with charset [0-9a-f].
DEVICE_CODE_RANDOM_BYTES :: 32

// USER_CODE_ALPHABET is RFC-4648 base32: 26 letters + digits 2..7 = 32 symbols.
// Excludes 0/1/8/9 to keep human transcription unambiguous (no 0/O or 1/I
// confusion at the digit level). 8 symbols => 40 bits of entropy.
USER_CODE_ALPHABET :: "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
USER_CODE_LENGTH :: 8 // two groups of 4 separated by a dash: "ABCD-2345"

// crypto_random_bytes reads `n` cryptographically-secure random bytes from the
// OS CSPRNG (/dev/urandom). Returns (bytes, true) on success; ([], false) if the
// entropy source is unavailable — callers MUST fail closed (deny the request).
crypto_random_bytes :: proc(n: int) -> ([]byte, bool) {
	if n <= 0 do return {}, true
	f, err := os.open("/dev/urandom")
	if err != nil do return {}, false
	defer os.close(f)
	buf := make([]byte, n)
	got := 0
	for got < n {
		r, rerr := os.read(f, buf[got:])
		if rerr != nil || r <= 0 {
			delete(buf)
			return {}, false
		}
		got += r
	}
	return buf, true
}

// generate_device_code returns a fresh, opaque, >=128-bit device code (hex of
// 32 random bytes => 64 chars, charset [0-9a-f]). Returns ("", false) only if
// the OS CSPRNG is unavailable.
generate_device_code :: proc() -> (string, bool) {
	raw, ok := crypto_random_bytes(DEVICE_CODE_RANDOM_BYTES)
	if !ok do return "", false
	defer delete(raw)
	return hex_encode(raw), true
}

// generate_user_code returns a fresh human-typed user code, 8 symbols from
// [A-Z2-7] formatted as "XXXX-XXXX". Returns ("", false) only if the OS CSPRNG
// is unavailable. Independent of generate_device_code.
generate_user_code :: proc() -> (string, bool) {
	raw, ok := crypto_random_bytes(USER_CODE_LENGTH)
	if !ok do return "", false
	defer delete(raw)
	alphabet := USER_CODE_ALPHABET
	out := make([dynamic]u8, 0, USER_CODE_LENGTH + 1)
	for i := 0; i < USER_CODE_LENGTH; i += 1 {
		// Unbiased mapping: 256 % 32 == 0, so every byte value maps cleanly to a
		// base32 symbol with no modulo bias.
		symbol := alphabet[int(raw[i]) % len(alphabet)]
		append(&out, symbol)
		// Insert the single dash between the two 4-symbol halves.
		if i == 3 do append(&out, '-')
	}
	result := strings.clone(string(out[:]))
	delete(out)
	return result, true
}

// hex_encode lower-case hex-encodes a byte slice (charset [0-9a-f]).
hex_encode :: proc(data: []byte) -> string {
	hex_digits := HEX_DIGITS
	out := make([dynamic]u8, 0, len(data) * 2)
	for b in data {
		append(&out, hex_digits[b >> 4 & 0x0f])
		append(&out, hex_digits[b & 0x0f])
	}
	result := strings.clone(string(out[:]))
	delete(out)
	return result
}

HEX_DIGITS :: "0123456789abcdef"

// normalize_user_code canonicalises a human- or URL-supplied user code to the
// stored "XXXX-XXXX" lookup key. Case is folded and whitespace/dashes are
// ignored; every remaining byte must be a USER_CODE_ALPHABET symbol and there
// must be exactly USER_CODE_LENGTH of them. Anything else — including stray
// punctuation, control bytes or an overlong value — is rejected rather than
// stripped, so the result is always rebuilt from validated symbols and never
// carries a byte of the input through. Returns ("", false) when invalid; the
// result is allocated with `allocator`.
normalize_user_code :: proc(raw: string, allocator := context.allocator) -> (string, bool) {
	symbols: [USER_CODE_LENGTH]u8
	count := 0
	for i := 0; i < len(raw); i += 1 {
		c := raw[i]
		switch c {
		case ' ', '\t', '-':
			continue
		case 'a' ..= 'z':
			c -= 'a' - 'A'
		}
		if strings.index_byte(USER_CODE_ALPHABET, c) < 0 do return "", false
		if count == USER_CODE_LENGTH do return "", false
		symbols[count] = c
		count += 1
	}
	if count != USER_CODE_LENGTH do return "", false
	return strings.concatenate({string(symbols[:4]), "-", string(symbols[4:])}, allocator), true
}
