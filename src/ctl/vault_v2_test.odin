package main

import "core:encoding/base64"
import "core:strings"
import "core:testing"
import vault "odin_test:lib/vault"

// ── Test shims ────────────────────────────────────────────────────────────────
// The per-domain *_vault_test.odin suites were written against a single 64-hex key.
// tkr turns such a key into the one-epoch keyring {1: key} the P1 adapter produces, and
// the two *_hex wrappers keep those suites' encrypt/decrypt calls readable.

TEST_V2_USER :: "usr_ctl_test"

tkr :: proc(key_hex: string) -> ^vault.Vault_Keyring {
	raw: [32]byte
	if !vault.hex_decode_into(raw[:], key_hex) do return nil
	kr := new(vault.Vault_Keyring, context.temp_allocator)
	parsed, ok := vault.keyring_from_single_key(TEST_V2_USER, 1, raw[:])
	if !ok do return nil
	kr^ = parsed
	return kr
}

vault_encrypt_text_hex :: proc(plaintext, key_hex: string, allocator := context.allocator) -> (string, bool) {
	return ctl_vault_seal(plaintext, tkr(key_hex), allocator)
}

vault_decrypt_text_hex :: proc(armored, key_hex: string, allocator := context.allocator) -> (string, bool) {
	plain, res := ctl_vault_open(armored, tkr(key_hex), allocator)
	return plain, res == .Ok || res == .Not_Armored
}

@(private = "file")
two_epoch_keyring :: proc() -> (vault.Vault_Keyring, string) {
	raw := vault.Vault_Keyring{}
	copy(raw.user_id_buf[:], TEST_V2_USER)
	raw.user_id_len = len(TEST_V2_USER)
	raw.count = 2
	raw.current_epoch = 2
	raw.entries[0].epoch = 1
	raw.entries[0].key = 0x11
	raw.entries[1].epoch = 2
	raw.entries[1].key = 0x22
	bytes, _ := vault.keyring_serialize(&raw, context.temp_allocator)
	b64, _ := base64.encode(bytes, allocator = context.temp_allocator)
	return raw, b64
}

@(test)
test_ctl_keyring_response_parsing :: proc(t: ^testing.T) {
	kr, b64 := two_epoch_keyring()
	defer vault.keyring_wipe(&kr)
	good := strings.concatenate({`{"ok":true,"data":{"keyring_b64":"`, b64, `","current_epoch":2}}`}, context.temp_allocator)
	parsed, ok := ctl_vault_keyring_from_response(good)
	testing.expect(t, ok, "valid agent.vault.get response parses")
	testing.expect(t, vault.keyring_equal(&parsed, &kr))
	vault.keyring_wipe(&parsed)

	bad := []string{
		`{"ok":false,"error":"not_found"}`,
		strings.concatenate({`{"data":{"keyring_b64":"`, b64, `"}}`}, context.temp_allocator),                     // no epoch
		strings.concatenate({`{"data":{"keyring_b64":"`, b64, `","current_epoch":1}}`}, context.temp_allocator),  // epoch mismatch
		strings.concatenate({`{"data":{"keyring_b64":"`, b64[:len(b64) - 4], `","current_epoch":2}}`}, context.temp_allocator), // truncated
		`{"data":{"keyring_b64":"!!!!","current_epoch":2}}`,                                                      // bad base64
		`{"data":{"key":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","key_length":64}}`, // v1 shape
	}
	for r in bad {
		_, bok := ctl_vault_keyring_from_response(r)
		testing.expectf(t, !bok, "must reject: %s", r)
	}
}

@(test)
test_ctl_round_trip_across_epochs :: proc(t: ^testing.T) {
	kr, _ := two_epoch_keyring()
	defer vault.keyring_wipe(&kr)
	tok, ok := ctl_vault_seal("epoch two secret", &kr, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect(t, strings.has_prefix(tok, "vault:v2:e2:"), "ctl seals under the current epoch")
	plain, res := ctl_vault_open(tok, &kr, context.temp_allocator)
	testing.expect(t, res == .Ok && plain == "epoch two secret")

	// Content written under epoch 1 still opens with the two-epoch keyring.
	k1, _ := vault.keyring_key_for_epoch(&kr, 1)
	old, _ := vault.seal_with_key(transmute([]byte)string("epoch one secret"), k1, 1, context.temp_allocator)
	plain1, res1 := ctl_vault_open(old, &kr, context.temp_allocator)
	testing.expect(t, res1 == .Ok && plain1 == "epoch one secret")

	// A keyring without epoch 2 shows the locked hint, never plaintext or ciphertext garbage.
	single := tkr("1111111111111111111111111111111111111111111111111111111111111111")
	fallback := ctl_decrypt_or_fallback_armored(tok, single, true, context.temp_allocator)
	testing.expect(t, strings.contains(fallback, VAULT_HINT_LOCKED))
}

@(test)
test_ctl_v1_token_is_opaque :: proc(t: ^testing.T) {
	kr, _ := two_epoch_keyring()
	defer vault.keyring_wipe(&kr)
	v1 := "vault:v1:zmr6vo8H4Fyfvf4qAX19d6UOkgq88L2eZGD70GhQ/+A/aq6kBz03tyWp"
	testing.expect(t, !is_vault_armored(v1))
	out := ctl_decrypt_or_fallback_armored(v1, &kr, true, context.temp_allocator)
	testing.expect_value(t, out, v1)
	plain, res := ctl_vault_open(v1, &kr, context.temp_allocator)
	testing.expect(t, res == .Not_Armored && plain == v1)
}

// tkr_b64 renders tkr(key_hex) as the base64 HKR1 value --vault-keyring takes.
tkr_b64 :: proc(key_hex: string) -> string {
	kr := tkr(key_hex)
	if kr == nil do return ""
	bytes, ok := vault.keyring_serialize(kr, context.temp_allocator)
	if !ok do return ""
	out, _ := base64.encode(bytes, allocator = context.temp_allocator)
	return out
}
