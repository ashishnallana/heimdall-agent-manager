package mcp

import "core:crypto"
import "core:strings"
import "core:testing"
import auth "odin_test:hub/service/auth"

@(test)
test_credential_envelope_authentication :: proc(t: ^testing.T) {
	key := Envelope_Key{id = "test-1"}; key.bytes[0] = 1
	claims := Credential_Claims{kind = "refresh", owner = "alice", client = "claude", private_capability = "private-test-scalar"}
	raw, ok := credential_seal(&key, claims)
	testing.expect(t, ok)
	opened, valid := credential_open([]Envelope_Key{key}, raw, "refresh")
	testing.expect(t, valid && opened.owner == "alice" && opened.private_capability == claims.private_capability)
	credential_claims_wipe(&opened)
	_, wrong_kind := credential_open([]Envelope_Key{key}, raw, "access")
	testing.expect(t, !wrong_kind)
	wrong_key := key; wrong_key.bytes[0] += 1
	_, wrong_secret := credential_open([]Envelope_Key{wrong_key}, raw, "refresh")
	testing.expect(t, !wrong_secret)
	wrong_id_raw, _ := strings.replace_all(raw, "test-1", "test-2", allocator = context.temp_allocator)
	_, wrong_id := credential_open([]Envelope_Key{key}, wrong_id_raw, "refresh")
	testing.expect(t, !wrong_id)
	_, entropy_failure := credential_seal(&key, claims, "/path/that/does/not/exist")
	testing.expect(t, !entropy_failure)
	for i in 0..<len(raw) {
		mutated := strings.clone(raw, context.temp_allocator)
		bytes := transmute([]byte)mutated
		bytes[i] = 'A' if bytes[i] != 'A' else 'B'
		_, accepted := credential_open([]Envelope_Key{key}, mutated, "refresh")
		testing.expect(t, !accepted)
	}
}

@(test)
test_retry_capsule_needs_raw_parent_and_exact_binding :: proc(t: ^testing.T) {
	key := Envelope_Key{id = "k1"}; key.bytes[0] = 4
	raw, ok := credential_seal(&key, Credential_Claims{kind = "refresh", jti = "random-parent"})
	testing.expect(t, ok)
	binding := Retry_Binding{owner = "alice", client = "claude", resource = "https://hub/mcp", grant = "g1", family = "f1", parent_hash = auth.sha256_hex(raw), child_hash = "child", revision = 1, deadline_ms = 30000}
	response := transmute([]byte)string(`{"access_token":"secret-successor","refresh_token":"another-secret"}`)
	capsule, sealed := retry_seal(raw, binding, response)
	testing.expect(t, sealed && !strings.contains(capsule, "secret"))
	plain, opened := retry_open(raw, binding, capsule)
	testing.expect(t, opened && string(plain) == string(response))
	defer crypto.zero_explicit(raw_data(plain), len(plain))
	_, hash_only := retry_open(binding.parent_hash, binding, capsule)
	testing.expect(t, !hash_only)
	other_raw, other_ok := credential_seal(&key, Credential_Claims{kind = "refresh", jti = "other-parent"})
	testing.expect(t, other_ok)
	_, other_parent := retry_open(other_raw, binding, capsule)
	testing.expect(t, !other_parent)
	for field in 0..<9 {
		b := binding
		switch field {
		case 0: b.owner = "bob"
		case 1: b.client = "other"
		case 2: b.resource = "https://other/mcp"
		case 3: b.grant = "g2"
		case 4: b.family = "f2"
		case 5: b.parent_hash = "other-parent-hash"
		case 6: b.child_hash = "other-child-hash"
		case 7: b.revision = 2
		case 8: b.deadline_ms += 1
		}
		_, accepted := retry_open(raw, b, capsule)
		testing.expect(t, !accepted)
	}
	_, entropy_failure := retry_seal(raw, binding, response, "/path/that/does/not/exist")
	testing.expect(t, !entropy_failure)
}
