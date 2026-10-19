package http

import "core:strings"
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

// Bridge_Hello_Unseal_Wire is the part of a bridge_hello this file reads (typed decode).
Bridge_Hello_Unseal_Wire :: struct {
	public_key:           string,
	unseal_boot_id:       string,
	unseal_key_signature: Maybe(vault.Signature_Wire),
	identity_public_key:  string,
	identity_sign_alg:    string,
}

bridge_hello_unseal_identity :: proc(hello_text: string, allocator := context.allocator) -> project_service.Bridge_Unseal_Identity {
	u: project_service.Bridge_Unseal_Identity
	hello: Bridge_Hello_Unseal_Wire
	if !vault.wire_decode(hello_text, &hello) do return u
	u.public_key = strings.clone(hello.public_key, allocator)
	boot := hello.unseal_boot_id
	identity := hello.identity_public_key
	alg := hello.identity_sign_alg
	// The signature object is re-rendered by the one canonical encoder (and so strictly
	// validated) before it is stored or served.
	sig := ""
	sig_wire, has_sig := hello.unseal_key_signature.?
	if has_sig do sig, has_sig = vault.signature_text_from_wire(sig_wire, context.temp_allocator)

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

// bridge_unseal_identity_fill sets the unseal-key advertisement members of a typed
// response (unseal_boot_id, unseal_key_signature, bridge_identity_public_key,
// bridge_identity_sign_alg). unseal_key_signature stays nil (JSON null) when there
// is none. Temp-allocated.
bridge_unseal_identity_fill :: proc(w: ^$T, u: project_service.Bridge_Unseal_Identity) {
	w.unseal_boot_id = u.unseal_boot_id
	w.bridge_identity_public_key = u.identity_public_key
	w.bridge_identity_sign_alg = u.identity_sign_alg
	if u.unseal_key_signature != "" {
		if sw, ok := vault.signature_wire_from_text(u.unseal_key_signature, context.temp_allocator); ok do w.unseal_key_signature = sw
	}
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
