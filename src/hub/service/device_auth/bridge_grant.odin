// Bridge-enrollment extensions to the device-authorization grant (REQ-IMPL-2).
//
// The RFC 8628 device grant in this package was built for the Electron app
// (ELDA). REQ-IMPL-2 reuses it for bridge enrollment rather than standing up a
// parallel flow, which means one grant type now serves two clients:
//
//   - an ELDA grant carries no bridge_public_key and is approved into a USER
//     API token, exactly as before;
//   - a BRIDGE grant carries a bridge_public_key and is approved into a
//     per-machine, bridge-scoped credential (`brg_`).
//
// WHICH ONE A GRANT IS, IS DECIDED ONCE AND THEN PERSISTED as `Grant.grant_kind`,
// and from then on the ENUM is the discriminator — never the key field.
//
// The DERIVATION, applied in exactly one place (`grant_kind_for_input`, called once
// at authorize), asks whether the request contributed a bridge_public_key: the key
// is the thing the credential is bound to, so a request carrying one is a machine
// enrollment by construction and cannot be talked out of it by the rest of the body.
// That derivation is a one-time INPUT CLASSIFICATION. It is not how later code
// decides what a grant is: every later branch reads the stored enum via
// `is_bridge_grant`, and `bridge_public_key != ""` appears nowhere as a test of
// kind. The distinction is the whole point of the paragraph below — a comment that
// described the key's presence as "the rule" would invite someone to reintroduce the
// emptiness test that this file exists to keep out.
//
// DO NOT "SIMPLIFY" `is_bridge_grant` BACK TO `bridge_public_key != ""`. The two
// kinds mint different identities, so a single empty-string test that went wrong
// in one branch would silently mint the WRONG KIND of credential — a privilege
// confusion, not a cosmetic bug. This chain already carries F4 ("empty token =>
// loopback authorizes all", src/bridge/main.odin) as the same bug class.
//
// Three properties this file exists to enforce:
//
//  1. THE FINGERPRINT IS HUB-COMPUTED, NEVER HOST-ASSERTED. The approval page
//     shows it so a human can compare it against the bridge's own terminal
//     (design §5.4.4, §6.2). A fingerprint the requester chose would make that
//     comparison meaningless — an attacker substituting a key would simply
//     submit the victim's fingerprint alongside it. So the Hub derives it from
//     the submitted key, and a body-supplied fingerprint that disagrees is
//     surfaced as an error rather than silently preferred either way.
//  2. PKCE IS S256-ONLY. RFC 7636 permits `plain`; this flow does not. A
//     missing or non-S256 method is rejected rather than defaulted, so a
//     downgrade needs a Hub change and not just a different request body.
//  3. A BRIDGE GRANT WITHOUT PKCE IS REFUSED. The code_challenge is what makes
//     the redemption provable (only the process that started the flow can
//     finish it); without it a leaked device_code is bearer-redeemable.
//
// The fingerprint hashes the DECODED 65-byte point, not its hex text, so the
// bridge (hex, bridge_get_public_key_hex in src/bridge/unseal_protocol.odin) and the browser (base64url
// in the approval-link fragment, design §5.4.2) compute the same value from the
// same key without agreeing on a transport encoding first.

package device_auth

import "core:crypto"
import "core:crypto/hash"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:strings"
import vault "odin_test:lib/vault"
import domain "odin_test:hub/domain"

// P256_UNCOMPRESSED_HEX_LEN is the hex length of an uncompressed SECP256R1
// point: 1 prefix byte + two 32-byte coordinates = 65 bytes = 130 hex chars.
// Matches bridge_get_public_key_hex() in src/bridge/unseal_protocol.odin.
P256_UNCOMPRESSED_HEX_LEN :: 130

// PKCE_S256 is the only accepted code_challenge_method (RFC 7636 §4.2).
PKCE_S256 :: "S256"

// PKCE_S256_CHALLENGE_LEN is the length of BASE64URL(SHA256(verifier)) with
// padding stripped: 32 bytes -> 43 chars.
PKCE_S256_CHALLENGE_LEN :: 43

// PKCE_VERIFIER_MIN_LEN / _MAX_LEN are RFC 7636 §4.1's bounds on code_verifier.
PKCE_VERIFIER_MIN_LEN :: 43
PKCE_VERIFIER_MAX_LEN :: 128

// OS_USER_MAX_LEN caps the host-asserted OS user. It is attacker-controlled
// (design §6.2) and ends up on the approval page, so bound it at the door; the
// longest plausible real value is far shorter.
OS_USER_MAX_LEN :: 64

// is_bridge_grant reports whether this grant is a bridge enrollment (and must
// therefore be approved into a bridge-scoped credential, not a user token).
//
// It reads the PERSISTED Grant_Kind, never `bridge_public_key != ""`. The
// emptiness test is the derivation rule and lives in exactly one place —
// grant_kind_for_input, called once at authorize.
is_bridge_grant :: proc(grant: Grant) -> bool {
	switch grant.grant_kind {
	case .Bridge_Enrollment: return true
	case .User_Token:        return false
	}
	return false
}

// grant_kind_for_input is the ONE place the discriminator rule lives: a request
// that contributes a bridge public key is a machine enrollment. The Electron
// client sends none, so it keeps the pre-existing user-token path untouched.
grant_kind_for_input :: proc(input: Authorize_Input) -> Grant_Kind {
	return .Bridge_Enrollment if input.bridge_public_key != "" else .User_Token
}

// valid_bridge_public_key checks the submitted key is a plausible uncompressed
// SECP256R1 point in lowercase hex. This is a WELL-FORMEDNESS check, not a
// curve-membership check: the Hub never does arithmetic with this key — it
// stores it, fingerprints it, and shows it — so a point that is syntactically
// valid but not on the curve harms only the bridge that submitted it, and
// AEAD verification on the unseal payload catches it there (design §5.4.4).
valid_bridge_public_key :: proc(key: string) -> bool {
	if len(key) != P256_UNCOMPRESSED_HEX_LEN do return false
	if key[0] != '0' || key[1] != '4' do return false // uncompressed-point prefix
	for i in 0 ..< len(key) {
		c := key[i]
		is_hex := (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
		if !is_hex do return false
	}
	return true
}

// is_base64url_unpadded reports whether every byte is in the RFC 4648 §5
// URL-safe alphabet with no padding. Used for both the PKCE challenge and the
// verifier charset (RFC 7636 §4.1 allows `-._~` too; see valid_pkce_verifier).
is_base64url_unpadded :: proc(s: string) -> bool {
	if s == "" do return false
	for i in 0 ..< len(s) {
		c := s[i]
		ok := (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_'
		if !ok do return false
	}
	return true
}

// valid_pkce_challenge accepts only a well-formed S256 challenge: exactly
// BASE64URL(SHA256(...)) unpadded.
valid_pkce_challenge :: proc(challenge: string) -> bool {
	if len(challenge) != PKCE_S256_CHALLENGE_LEN do return false
	return is_base64url_unpadded(challenge)
}

// valid_pkce_verifier enforces RFC 7636 §4.1: 43..128 chars from the unreserved
// set [A-Za-z0-9-._~].
valid_pkce_verifier :: proc(verifier: string) -> bool {
	if len(verifier) < PKCE_VERIFIER_MIN_LEN || len(verifier) > PKCE_VERIFIER_MAX_LEN do return false
	for i in 0 ..< len(verifier) {
		c := verifier[i]
		ok := (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
			c == '-' || c == '.' || c == '_' || c == '~'
		if !ok do return false
	}
	return true
}

// valid_os_user bounds the host-asserted OS user: non-empty values must be
// within OS_USER_MAX_LEN and free of control characters, so the value cannot
// break a log line or smuggle C0 bytes into the approval page. Bidi and
// confusable sanitisation for DISPLAY is REQ-ENROLL-6 / REQ-IMPL-5's job on the
// UI side; this is only the storage-layer floor.
valid_os_user :: proc(os_user: string) -> bool {
	if os_user == "" do return true // optional field
	if len(os_user) > OS_USER_MAX_LEN do return false
	for i in 0 ..< len(os_user) {
		c := os_user[i]
		if c < 0x20 || c == 0x7f do return false
	}
	return true
}

// base64url_unpadded encodes `data` with the URL-safe alphabet and strips the
// '=' padding, which is the encoding PKCE (RFC 7636 §4.2) specifies.
base64url_unpadded :: proc(data: []byte, allocator := context.allocator) -> string {
	padded, _ := base64.encode(data, base64.ENC_URL_TABLE, allocator)
	trimmed := strings.trim_right(padded, "=")
	if len(trimmed) == len(padded) do return padded
	out := strings.clone(trimmed, allocator)
	delete(padded, allocator)
	return out
}

// bridge_key_fingerprint_for derives the human-comparable fingerprint of a
// bridge public key: SHA-256 over the DECODED point, truncated to the leading
// 64 bits, rendered as four space-separated hex quads ("a1b2 c3d4 e5f6 0718")
// per design §2.2 step 5. Returns ("", false) if the key is not well-formed —
// callers MUST fail the request rather than store an empty fingerprint, since
// an empty fingerprint would display as "nothing to compare".
bridge_key_fingerprint_for :: proc(public_key_hex: string, allocator := context.allocator) -> (string, bool) {
	if !valid_bridge_public_key(public_key_hex) do return "", false
	raw, ok := hex.decode(transmute([]byte)(public_key_hex), context.temp_allocator)
	if !ok do return "", false
	digest: [32]byte
	hash.hash_bytes_to_buffer(.SHA256, raw, digest[:])
	// 8 bytes -> 16 hex chars in 4 groups of 4, separated by single spaces.
	hex_digits := HEX_DIGITS // a constant string cannot be indexed by a variable
	out := strings.builder_make(allocator)
	for i in 0 ..< 8 {
		if i > 0 && i % 2 == 0 do strings.write_byte(&out, ' ')
		b := digest[i]
		strings.write_byte(&out, hex_digits[b >> 4 & 0x0f])
		strings.write_byte(&out, hex_digits[b & 0x0f])
	}
	return strings.to_string(out), true
}

// pkce_verifier_matches checks a presented code_verifier against the stored
// S256 challenge (RFC 7636 §4.6). The comparison is constant-time: the
// challenge is not a secret, but the verifier is, and a byte-at-a-time compare
// on attacker-supplied input is the kind of thing that is cheap to avoid and
// awkward to explain later. A malformed verifier fails rather than erroring, so
// the caller has exactly one rejection path.
pkce_verifier_matches :: proc(challenge, verifier: string) -> bool {
	if challenge == "" || verifier == "" do return false
	if !valid_pkce_verifier(verifier) do return false
	digest: [32]byte
	hash.hash_string_to_buffer(.SHA256, verifier, digest[:])
	computed := base64url_unpadded(digest[:], context.temp_allocator)
	if len(computed) != len(challenge) do return false
	return crypto.compare_constant_time(transmute([]byte)(computed), transmute([]byte)(challenge)) == 1
}

// validate_bridge_authorize_input enforces the REQ-IMPL-2 rules on an
// /device/authorize body and returns the HUB-COMPUTED fingerprint for the grant
// (empty for a non-bridge grant). Called by authorize() before the rate-limit
// bucket is spent.
//
// The rules, and why each one is a rejection rather than a default:
//   - PKCE method must be exactly "S256". RFC 7636 §4.2 also defines `plain`,
//     and an empty method means `plain` per the RFC — both are refused here, so
//     a downgrade requires changing the Hub rather than the request body.
//   - A bridge grant MUST carry a code_challenge. Without it the device_code is
//     a bare bearer secret and redemption proves nothing (design §2.4, §3.6).
//   - A body-supplied bridge_key_fingerprint that disagrees with the computed
//     one is an error. Scope item 5's rule — a mismatch is an attack signal, to
//     be surfaced rather than silently resolved in either direction — applied at
//     the only point where the Hub sees both values.
//   - A code_challenge WITHOUT a bridge_public_key is accepted and stored: PKCE
//     is not bridge-specific, and the poll path enforces it for any grant that
//     has one.
validate_bridge_authorize_input :: proc(input: Authorize_Input, allocator := context.allocator) -> (string, Grant_Kind, bool, domain.Domain_Error) {
	kind := grant_kind_for_input(input)
	if input.code_challenge != "" {
		if input.code_challenge_method != PKCE_S256 {
			return "", kind, false, domain.domain_error(.Validation_Failed, "code_challenge_method must be S256")
		}
		if !valid_pkce_challenge(input.code_challenge) {
			return "", kind, false, domain.domain_error(.Validation_Failed, "code_challenge must be base64url(SHA-256) with no padding")
		}
	} else if input.code_challenge_method != "" {
		return "", kind, false, domain.domain_error(.Validation_Failed, "code_challenge_method requires code_challenge")
	}
	if !valid_os_user(input.os_user) {
		return "", kind, false, domain.domain_error(.Validation_Failed, "os_user is too long or contains control characters")
	}
	if kind == .User_Token {
		// Not a bridge enrollment. A fingerprint submitted without a key has
		// nothing to be checked against, so it is refused rather than stored
		// unverified — a stored-but-underived fingerprint is the one thing the
		// approval page must never display.
		if input.bridge_key_fingerprint != "" {
			return "", kind, false, domain.domain_error(.Validation_Failed, "bridge_key_fingerprint requires bridge_public_key")
		}
		if input.bridge_identity_public_key != "" || input.bridge_identity_proof != "" {
			return "", kind, false, domain.domain_error(.Validation_Failed, "bridge_identity_public_key requires bridge_public_key")
		}
		if input.pair_lookup != "" || input.pair_key_mac != "" || input.pair_salt != "" || input.pair_hub_origin != "" {
			return "", kind, false, domain.domain_error(.Validation_Failed, "pair_lookup requires bridge_public_key")
		}
		return "", kind, true, domain.Domain_Error{}
	}
	if !valid_bridge_public_key(input.bridge_public_key) {
		return "", kind, false, domain.domain_error(.Validation_Failed, "bridge_public_key must be a 130-char lowercase-hex uncompressed P-256 point")
	}
	if input.code_challenge == "" {
		return "", kind, false, domain.domain_error(.Validation_Failed, "bridge enrollment requires a PKCE code_challenge")
	}
	// Passwordless vault: the persistent identity key is what the approving device
	// signs into the directory. Required (no compat path), and distinct from the
	// per-process ECDH key so the two roles can never be confused.
	if !valid_bridge_public_key(input.bridge_identity_public_key) {
		return "", kind, false, domain.domain_error(.Validation_Failed, "bridge_identity_public_key must be a 130-char lowercase-hex uncompressed P-256 point")
	}
	if input.bridge_identity_public_key == input.bridge_public_key {
		return "", kind, false, domain.domain_error(.Validation_Failed, "bridge_identity_public_key must differ from bridge_public_key")
	}
	// Proof of possession: the identity key signs this grant's ECDH key and PKCE
	// challenge. Without it a host could enroll under an identity key it does not hold.
	proof_msg, pm_ok := vault.bridge_enroll_proof_canonical(input.bridge_public_key, input.code_challenge, context.temp_allocator)
	if !pm_ok || !vault.verify(vault.SIGN_ALG_ECDSA_P256_SHA256, input.bridge_identity_public_key, transmute([]byte)proof_msg, input.bridge_identity_proof) {
		return "", kind, false, domain.domain_error(.Validation_Failed, "bridge_identity_proof does not verify under bridge_identity_public_key")
	}
	// Hub-blind pairing (plan §1 "Pairing"): the bridge derived both from a secret code
	// it shows its operator. The hub can check only their shape; the approver checks
	// pair_key_mac with the code the operator types. pair_salt is the public salt of
	// the pairing stretch (vault.Pair_Context), random per request; pair_hub_origin the
	// canonical hub origin the bridge bound into it (the approver derives with it).
	if !vault.valid_pair_hex(input.pair_lookup) || !vault.valid_pair_hex(input.pair_key_mac) || !vault.valid_pair_salt_hex(input.pair_salt) {
		return "", kind, false, domain.domain_error(.Validation_Failed, "bridge enrollment requires pair_lookup, pair_key_mac (64 lowercase hex) and pair_salt (32 lowercase hex); update ham-bridge")
	}
	if !vault.valid_pair_hub_origin(input.pair_hub_origin) {
		return "", kind, false, domain.domain_error(.Validation_Failed, "bridge enrollment requires pair_hub_origin (canonical scheme://host:port); update ham-bridge")
	}
	fingerprint, fok := bridge_key_fingerprint_for(input.bridge_public_key, allocator)
	if !fok {
		return "", kind, false, domain.domain_error(.Validation_Failed, "could not derive a fingerprint for bridge_public_key")
	}
	if input.bridge_key_fingerprint != "" && input.bridge_key_fingerprint != fingerprint {
		delete(fingerprint, allocator)
		return "", kind, false, domain.domain_error(.Validation_Failed, "bridge_key_fingerprint does not match bridge_public_key")
	}
	return fingerprint, kind, true, domain.Domain_Error{}
}
