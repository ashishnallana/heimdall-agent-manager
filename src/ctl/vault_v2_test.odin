package main

import "core:encoding/base64"
import "core:strings"
import "core:testing"
import jsonx "odin_test:lib/jsonx"
import vault "odin_test:lib/vault"

// ── Test shims ────────────────────────────────────────────────────────────────
// The per-domain *_vault_test.odin suites were written against a single 64-hex key.
// tkr turns such a key into the one-epoch keyring {1: key} the P1 adapter produces, and
// the two *_hex wrappers keep those suites' encrypt/decrypt calls readable.

TEST_V2_USER :: "usr_ctl_test"
TEST_V2_VAULT :: vault.Vault_Id{0x5c, 0x0f, 0x31, 0xa8, 0x77, 0x02, 0xde, 0x90}

tkr :: proc(key_hex: string) -> ^vault.Vault_Keyring {
	raw: [32]byte
	if !vault.hex_decode_into(raw[:], key_hex) do return nil
	kr := new(vault.Vault_Keyring, context.temp_allocator)
	parsed, ok := vault.keyring_from_single_key(TEST_V2_USER, TEST_V2_VAULT, 1, raw[:])
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
	raw.vault_id = TEST_V2_VAULT
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
	prefix_buf: [64]byte
	testing.expect(t, strings.has_prefix(tok, vault.token_prefix(TEST_V2_VAULT, 2, prefix_buf[:])), "ctl seals under the current epoch")
	plain, res := ctl_vault_open(tok, &kr, context.temp_allocator)
	testing.expect(t, res == .Ok && plain == "epoch two secret")

	// Content written under epoch 1 still opens with the two-epoch keyring.
	k1, _ := vault.keyring_key_for_epoch(&kr, 1)
	old, _ := vault.seal_with_key(transmute([]byte)string("epoch one secret"), k1, TEST_V2_VAULT, 1, context.temp_allocator)
	plain1, res1 := ctl_vault_open(old, &kr, context.temp_allocator)
	testing.expect(t, res1 == .Ok && plain1 == "epoch one secret")

	// A keyring without epoch 2 shows the locked hint, never plaintext or ciphertext garbage.
	single := tkr("1111111111111111111111111111111111111111111111111111111111111111")
	fallback := ctl_decrypt_or_fallback_armored(tok, single, true, context.temp_allocator)
	testing.expect(t, strings.contains(fallback, VAULT_HINT_LOCKED))
}

@(test)
test_ctl_dead_format_token_is_opaque :: proc(t: ^testing.T) {
	kr, _ := two_epoch_keyring()
	defer vault.keyring_wipe(&kr)
	v1 := "ENC:v1:zmr6vo8H4Fyfvf4qAX19d6UOkgq88L2eZGD70GhQ/+A/aq6kBz03tyWp"
	testing.expect(t, !is_vault_armored(v1))
	out := ctl_decrypt_or_fallback_armored(v1, &kr, true, context.temp_allocator)
	testing.expect_value(t, out, v1)
	plain, res := ctl_vault_open(v1, &kr, context.temp_allocator)
	testing.expect(t, res == .Not_Armored && plain == v1)
}

// tkr_b64 renders tkr(key_hex) as the base64 HKR2 value --vault-keyring takes.
tkr_b64 :: proc(key_hex: string) -> string {
	kr := tkr(key_hex)
	if kr == nil do return ""
	bytes, ok := vault.keyring_serialize(kr, context.temp_allocator)
	if !ok do return ""
	out, _ := base64.encode(bytes, allocator = context.temp_allocator)
	return out
}

@(test)
test_ctl_armored_means_parseable_envelope :: proc(t: ^testing.T) {
	// "Already armored" means a parseable envelope, not a prefix.
	testing.expect(t, !is_vault_armored("vault:v2:e1:not-really-a-token"), "a bare prefix is not armored")
	kr := tkr("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
	defer vault.keyring_wipe(kr)
	tok, ok := ctl_vault_seal("hello", kr, context.temp_allocator)
	testing.expect(t, ok && is_vault_armored(tok), "a real token is armored")
}

@(test)
test_ctl_seal_if_seals_hub_mode_fields :: proc(t: ^testing.T) {
	kr := tkr("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
	defer vault.keyring_wipe(kr)
	sealed := ctl_seal_if("chain title", kr)
	testing.expect(t, is_vault_armored(sealed), "sealed when a keyring is in hand")
	plain, res := ctl_vault_open(sealed, kr, context.temp_allocator)
	testing.expect(t, res == .Ok && plain == "chain title", "round-trips")
	testing.expect_value(t, ctl_seal_if(sealed, kr), sealed)
	testing.expect_value(t, ctl_seal_if("", kr), "")
	// A fake envelope prefix is sealed, not passed through.
	testing.expect(t, ctl_seal_if("vault:v2:e1:fake", kr) != "vault:v2:e1:fake", "a bare prefix is still sealed")
}

// ── Write builders always seal (finding N2) ─────────────────────────────────
// Shape tests for the param builders inject a keyring and read the output back
// decrypted, so they assert on the same JSON they did before sealing was mandatory.

CTL_TEST_WRITE_KEY :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

// with_kr appends the test-only --vault-keyring flag. Temp-allocated.
with_kr :: proc(args: []string) -> []string {
	out := make([dynamic]string, 0, len(args) + 2, context.temp_allocator)
	append(&out, ..args)
	append(&out, "--vault-keyring", tkr_b64(CTL_TEST_WRITE_KEY))
	return out[:]
}

// unseal_out takes ownership of a builder's output and returns it with every vault
// token decrypted under CTL_TEST_WRITE_KEY.
unseal_out :: proc(s: string) -> string {
	defer delete(s)
	kr := tkr(CTL_TEST_WRITE_KEY)
	defer vault.keyring_wipe(kr)
	return ctl_decrypt_json_string(s, kr, true)
}

@(test)
test_ctl_shell_enc_spec_is_bound_to_bridge_session_kind_boot :: proc(t: ^testing.T) {
	fields := make([dynamic]string, context.temp_allocator)
	args := with_kr([]string{"--bridge-boot-id", "00112233aabbccdd"})
	ctl_shell_attach_enc_spec("", "", "brg_n1", "server", args, "npm start", "/w", &fields)
	body := json_object_from_slice(fields[:])
	defer delete(body)
	session_id := jsonx.extract_string(body, "session_id", "", true, context.temp_allocator)
	testing.expect(t, len(session_id) == 35 && strings.has_prefix(session_id, "sh_"), session_id)
	kr := tkr(CTL_TEST_WRITE_KEY)
	defer vault.keyring_wipe(kr)
	spec, res := ctl_vault_open(jsonx.extract_string(body, "enc_spec", "", true, context.temp_allocator), kr, context.temp_allocator)
	testing.expect(t, res == .Ok, "enc_spec opens under the current epoch")
	testing.expect(t, strings.contains(spec, `"bridge_id":"brg_n1"`), spec)
	testing.expect(t, strings.contains(spec, `"kind":"server"`), spec)
	testing.expect(t, strings.contains(spec, `"boot_id":"00112233aabbccdd"`), spec)
	testing.expect(t, strings.contains(spec, session_id), spec)
	testing.expect(t, strings.contains(spec, `"cmd":"npm start"`), spec)
}

@(test)
test_ctl_card_title_and_rationale_are_sealed :: proc(t: ^testing.T) {
	out, ok := ctl_agentmode_action_create_params(with_kr([]string{"--title", "Secret card", "--rationale", "because secret", "--operations", `[{"op":"task.vote","task_id":"task_1","result":"lgtm"}]`}))
	testing.expect(t, ok, "params built")
	defer delete(out)
	testing.expect(t, !strings.contains(out, "Secret card") && !strings.contains(out, "because secret"), out)
	testing.expect(t, strings.contains(out, `"title":"vault:v2:`) && strings.contains(out, `"rationale":"vault:v2:`), out)
	cards := ctl_agentmode_cards_create_params("Secret card", with_kr([]string{"--rationale", "because secret"}))
	defer delete(cards)
	testing.expect(t, !strings.contains(cards, "Secret card") && !strings.contains(cards, "because secret"), cards)
}
