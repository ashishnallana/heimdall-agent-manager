// Cryptographic randomness for the hub's credential paths (REQ-IMPL-1).
//
// WHY THIS EXISTS RATHER THAN core:crypto's rand_bytes: that routine treats an
// entropy-source failure as catastrophic and PANICS. Every caller here must be
// able to FAIL CLOSED instead — deny the enrolment and return an error — so the
// hub never issues a credential it cannot prove is unpredictable, and never
// falls back to a predictable source such as a timestamp.
//
// Modelled on crypto_random_bytes in src/hub/service/device_auth/codes.odin,
// which carries the same fail-closed contract for device/user codes. The two are
// deliberately duplicated for now: device_auth/ is being edited concurrently
// under REQ-IMPL-2, so de-duplicating them is a follow-up, not part of this task.
package platform

import os_random "odin_test:lib/os_random"

// RANDOM_SOURCE is the OS CSPRNG. Reading it blocks only until the kernel pool
// is initialised, which has already happened long before the hub accepts
// requests.
RANDOM_SOURCE :: "/dev/urandom"

HEX_DIGITS :: "0123456789abcdef"

// random_bytes fills dst with cryptographically secure random bytes.
//
// Returns false if the entropy source cannot be opened or returns short. A false
// return means NO usable randomness was produced: callers MUST fail closed and
// must not use any part of dst.
// `source` exists so tests can point at a path that cannot be read and assert
// the fail-closed contract for real. Production callers leave it at the default.
random_bytes :: proc(dst: []byte, source := RANDOM_SOURCE) -> bool {
	return os_random.fill(dst, source)
}

// random_hex returns n_bytes of CSPRNG output, lower-case hex encoded: a string
// of 2*n_bytes chars over [0-9a-f]. Returns ("", false) if entropy is
// unavailable, or if n_bytes is not positive.
//
// Hex (not base64) so the result is safe to carry in a bearer token, a URL and a
// TEXT column without any escaping, matching the device_code convention.
random_hex :: proc(n_bytes: int, allocator := context.allocator, source := RANDOM_SOURCE) -> (string, bool) {
	if n_bytes <= 0 do return "", false
	buf := make([]byte, n_bytes, context.temp_allocator)
	if !random_bytes(buf, source) do return "", false
	return hex_encode(buf, allocator), true
}

// hex_encode lower-case hex-encodes data (charset [0-9a-f]).
hex_encode :: proc(data: []byte, allocator := context.allocator) -> string {
	digits := HEX_DIGITS
	out := make([]byte, len(data) * 2, allocator)
	for b, i in data {
		out[i * 2] = digits[b >> 4 & 0x0f]
		out[i * 2 + 1] = digits[b & 0x0f]
	}
	return string(out)
}
