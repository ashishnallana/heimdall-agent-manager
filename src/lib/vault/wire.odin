package vault

import "core:encoding/json"

// ── Typed wire shapes (JSON) ────────────────────────────────────────────────
// Every vault JSON that is NOT hashed or signed is encoded with json.marshal and
// decoded with json.unmarshal through these structs (owner rule: no hand-built JSON).
// The byte-exact canonical forms that ARE hashed/signed (statement text, the wrap's
// canonical JSON, the signature object text) stay in their dedicated encoders
// (statement_canonical, wrap_canonical_json, signature_object), pinned by the shared
// TS/Odin vectors. These structs only carry them.

// wire_decode decodes a JSON document into a typed struct (strict JSON, not JSON5).
// Unknown members are ignored; a member of the wrong type, invalid UTF-8 or a
// non-object document is an error. Strings are allocated with `allocator`.
wire_decode :: proc(text: string, out: ^$T, allocator := context.temp_allocator) -> bool {
	return json.unmarshal_string(text, out, json.Specification.JSON, allocator) == nil
}

// wire_encode encodes a typed value with json.marshal.
wire_encode :: proc(value: $T, allocator := context.allocator) -> (string, bool) {
	data, err := json.marshal(value, allocator = allocator)
	if err != nil do return "", false
	return string(data), true
}

// Signature_Wire is a signature object {"alg","sig"} as a JSON value.
Signature_Wire :: struct {
	alg: string,
	sig: string,
}

// signature_wire_from_text decodes a canonical signature object text. Anything
// signature_parse rejects is rejected.
signature_wire_from_text :: proc(text: string, allocator := context.allocator) -> (w: Signature_Wire, ok: bool) {
	if _, parsed := signature_parse(text); !parsed do return {}, false
	if !wire_decode(text, &w, allocator) do return {}, false
	return w, true
}

// signature_text_from_wire re-renders a decoded signature object canonically.
signature_text_from_wire :: proc(w: Signature_Wire, allocator := context.allocator) -> (string, bool) {
	return signature_text_from_parts(w.alg, w.sig, allocator)
}

// Wrap_Wire is a stored/served keyring wrap with its signature object.
Wrap_Wire :: struct {
	v:                    int,
	alg:                  string,
	recipient_device_id:  string,
	directory_version:    u64,
	current_epoch:        u32,
	ephemeral_public_key: string,
	iv:                   string,
	ciphertext:           string,
	wrapped_by_device_id: string,
	signature:            Signature_Wire,
}

// wrap_wire_from_signed_json decodes the stored form (wrap_signed_json) and
// re-validates it through wrap_from_value.
wrap_wire_from_signed_json :: proc(text: string, allocator := context.allocator) -> (w: Wrap_Wire, ok: bool) {
	v: json.Value
	if !wire_decode(text, &v) do return {}, false
	kw, sig_text, valid := wrap_from_value(v, allocator)
	if !valid do return {}, false
	sw, s_ok := signature_wire_from_text(sig_text, allocator)
	if !s_ok do return {}, false
	return Wrap_Wire{
		v = 1, alg = kw.alg, recipient_device_id = kw.recipient_device_id,
		directory_version = kw.directory_version, current_epoch = kw.current_epoch,
		ephemeral_public_key = kw.ephemeral_public_key, iv = kw.iv, ciphertext = kw.ciphertext,
		wrapped_by_device_id = kw.wrapped_by_device_id, signature = sw,
	}, true
}
