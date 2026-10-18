package http

import "core:strings"
import jsonx "odin_test:lib/jsonx"
import vault "odin_test:lib/vault"
import project_service "odin_test:hub/service/project"

// ── Passwordless vault P1: relay of the bridge's signed unseal key ─────────────
//
// A bridge_hello carries, next to its ephemeral ECDH "public_key":
//   "unseal_boot_id":        lowercase hex
//   "unseal_key_signature":  {"alg":"ecdsa-p256-sha256","sig":"<r||s hex>"} (object)
//   "identity_public_key":   130 lowercase hex (persistent ECDSA P-256 identity)
//   "identity_sign_alg":     "ecdsa-p256-sha256"
//
// The hub is not trusted with these: browsers verify the signature (and, from P3,
// pin the identity key through the device directory). The hub only shape-checks so
// it never relays junk, and stores all five together so a signature can never be
// served beside a different key. Anything malformed drops the signed fields — a
// client then sees no signature and refuses to unseal (fail closed).

bridge_hello_unseal_identity :: proc(hello_text: string, allocator := context.allocator) -> project_service.Bridge_Unseal_Identity {
	u: project_service.Bridge_Unseal_Identity
	u.public_key = jsonx.extract_string(hello_text, "public_key", "", true, allocator)
	boot := jsonx.extract_string(hello_text, "unseal_boot_id", "", true, context.temp_allocator)
	// The object is rebuilt in canonical member order from its two members (a JSON
	// round-trip does not preserve order), then strictly re-parsed below.
	sig_obj, has_sig := jsonx.extract_raw_object(hello_text, "unseal_key_signature", true, context.temp_allocator)
	sig := ""
	if has_sig {
		sig = strings.concatenate({
			`{"alg":"`, jsonx.extract_string(sig_obj, "alg", "", true, context.temp_allocator),
			`","sig":"`, jsonx.extract_string(sig_obj, "sig", "", true, context.temp_allocator), `"}`,
		}, context.temp_allocator)
	}
	identity := jsonx.extract_string(hello_text, "identity_public_key", "", true, context.temp_allocator)
	alg := jsonx.extract_string(hello_text, "identity_sign_alg", "", true, context.temp_allocator)

	valid := has_sig && boot != "" && len(boot) <= 64 && vault.is_lower_hex(boot) &&
		len(identity) == vault.P256_PUBLIC_KEY_BYTES * 2 && vault.is_lower_hex(identity) &&
		vault.sign_alg_from_id(alg) != .Unknown
	if valid {
		parsed, sig_ok := vault.signature_parse(sig)
		valid = sig_ok && vault.sign_alg_from_id(alg) == parsed.alg
	}
	if valid {
		u.unseal_boot_id = strings.clone(boot, allocator)
		u.unseal_key_signature = strings.clone(sig, allocator)
		u.identity_public_key = strings.clone(identity, allocator)
		u.identity_sign_alg = strings.clone(alg, allocator)
	}
	return u
}

// write_bridge_unseal_identity_fields appends
// ,"unseal_boot_id":"…","unseal_key_signature":{…}|null,"bridge_identity_public_key":"…","bridge_identity_sign_alg":"…"
write_bridge_unseal_identity_fields :: proc(b: ^strings.Builder, u: project_service.Bridge_Unseal_Identity) {
	strings.write_string(b, `,"unseal_boot_id":"`); write_handler_json_string(b, u.unseal_boot_id)
	strings.write_string(b, `","unseal_key_signature":`)
	// Stored only after vault.signature_parse accepted it, i.e. it is the exact
	// canonical object, so it is safe to emit raw.
	if u.unseal_key_signature != "" do strings.write_string(b, u.unseal_key_signature)
	else do strings.write_string(b, "null")
	strings.write_string(b, `,"bridge_identity_public_key":"`); write_handler_json_string(b, u.identity_public_key)
	strings.write_string(b, `","bridge_identity_sign_alg":"`); write_handler_json_string(b, u.identity_sign_alg)
	strings.write_string(b, `"`)
}
