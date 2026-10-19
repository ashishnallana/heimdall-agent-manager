package main

// Shared vault test support (passwordless-vault P1): test ids, the env/home sandbox
// and v2 keyring/envelope builders. Everything that used to be scattered across the
// v1 suites (vault_decrypt_test, keystore_test, unseal_security_test) lives here.

import "core:crypto"
import "core:crypto/aes"
import "core:crypto/ecdh"
import "core:crypto/hkdf"
import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import cfg_lib "odin_test:lib/config"
import vault "odin_test:lib/vault"

TEST_VAULT_KEY_HEX :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
TEST_ENC_VAULT_KEY :: "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"
KEYSTORE_SEC_TEST_KEY_1 :: TEST_VAULT_KEY_HEX
KEYSTORE_SEC_TEST_KEY_2 :: "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
TEST_VAULT_USER_ID :: "usr_bridge_test"

keystore_test_mutex: sync.Mutex

@(private = "file")
keystore_test_ids_once: sync.Once
@(private = "file")
keystore_test_ids_buf: [64]u8
@(private = "file")
keystore_test_ids_len: int

// keystore_test_bridge_ids returns this test process's two bridge ids,
// `brg_test_<pid>` and `brg_test_<pid>_b` (REQ-T5-4). A test build refuses any id
// without KEYSTORE_TEST_BRIDGE_ID_PREFIX, and the pid keeps concurrent runs apart.
keystore_test_bridge_ids :: proc() -> (a: string, b: string) {
	sync.once_do(&keystore_test_ids_once, proc() {
		s := fmt.bprintf(keystore_test_ids_buf[:], "%s%d_b", KEYSTORE_TEST_BRIDGE_ID_PREFIX, os.get_pid())
		keystore_test_ids_len = len(s)
	})
	b = string(keystore_test_ids_buf[:keystore_test_ids_len])
	return b[:len(b) - 2], b
}

// keystore_test_set_daemon_id points the running bridge at id and returns the
// previous value for the caller to restore. Hold bridge_test_config_mutex.
keystore_test_set_daemon_id :: proc(id: string) -> (prev: string) {
	prev = bridge_config.daemon_id
	bridge_config.daemon_id = id
	return
}

// ── v2 keyring / envelope builders ──────────────────────────────────────────

test_keyring_from_hex :: proc(key_hex: string, epoch: u32 = 1, user_id: string = TEST_VAULT_USER_ID) -> vault.Vault_Keyring {
	key: [32]byte
	defer crypto.zero_explicit(&key, size_of(key))
	_ = vault.hex_decode_into(key[:], key_hex)
	kr, _ := vault.keyring_from_single_key(user_id, epoch, key[:])
	return kr
}

// test_keyring_two_epochs builds {1: key1, 2: key2} with current epoch 2.
test_keyring_two_epochs :: proc(key1_hex, key2_hex: string) -> vault.Vault_Keyring {
	kr := test_keyring_from_hex(key1_hex, 1)
	_ = vault.hex_decode_into(kr.entries[1].key[:], key2_hex)
	kr.entries[1].epoch = 2
	kr.count = 2
	kr.current_epoch = 2
	return kr
}

test_keyring_bytes :: proc(kr: ^vault.Vault_Keyring) -> []byte {
	out, _ := vault.keyring_serialize(kr, context.temp_allocator)
	return out
}

// test_keyring_env_value is the HEIMDALL_VAULT_KEYRING value for a one-epoch keyring.
test_keyring_env_value :: proc(key_hex: string, epoch: u32 = 1) -> string {
	kr := test_keyring_from_hex(key_hex, epoch)
	defer vault.keyring_wipe(&kr)
	enc, _ := base64.encode(test_keyring_bytes(&kr), allocator = context.temp_allocator)
	return enc
}

// test_vault_seal seals plaintext as a v2 token under key_hex at epoch.
test_vault_seal :: proc(plaintext: string, key_hex: string, epoch: u32 = 1, allocator := context.allocator) -> string {
	key: [32]byte
	defer crypto.zero_explicit(&key, size_of(key))
	_ = vault.hex_decode_into(key[:], key_hex)
	tok, _ := vault.seal_with_key(transmute([]byte)plaintext, key[:], epoch, allocator)
	return tok
}

// test_store_keyring persists a one-epoch keyring for bridge_id (keystore + memory).
test_store_keyring :: proc(bridge_id: string, key_hex: string, epoch: u32 = 1) -> bool {
	kr := test_keyring_from_hex(key_hex, epoch)
	defer vault.keyring_wipe(&kr)
	ok, _ := keystore_store_vault_keyring(bridge_id, test_keyring_bytes(&kr))
	return ok
}

// test_provision_identity runs the enrollment half of the identity lifecycle for
// bridge_id: generate in memory, then commit with owner as the enrolled owner.
test_provision_identity :: proc(bridge_id: string, owner: string = TEST_VAULT_USER_ID) -> bool {
	if _, ok := bridge_unseal_identity_generate_for_enrollment(); !ok do return false
	return bridge_unseal_identity_commit_enrollment(bridge_id, owner)
}

// ── unseal v2 payload builder (the browser side) ────────────────────────────

Test_Unseal_Options :: struct {
	tamper_aad:          bool,   // seal with a different AAD than the payload claims
	v1_aad:              bool,   // seal with the deleted v1 AAD form
	raw_plaintext:       string, // seal these bytes instead of the keyring
	signature_override:  string, // echo this signature object instead of the bridge's
	identity_override:   string, // echo this identity key instead of the bridge's
	format_override:     string,
}

// test_create_unseal_v2_payload builds a bridge_unseal v2 payload for this
// process's bridge (ephemeral key + identity for bridge_id), sealing kr.
test_create_unseal_v2_payload :: proc(bridge_id: string, kr: ^vault.Vault_Keyring, timestamp: i64, nonce: string, opts: Test_Unseal_Options = {}) -> string {
	client: ecdh.Private_Key
	defer ecdh.private_key_clear(&client)
	_ = ecdh.private_key_generate(&client, .SECP256R1)
	client_pub: [P256_POINT_SIZE]byte
	ecdh.private_key_public_bytes(&client, client_pub[:])
	iv: [12]byte
	crypto.rand_bytes(iv[:])

	ct_hex, tag_hex: string
	if opts.raw_plaintext != "" || opts.tamper_aad || opts.v1_aad {
		// Hand-rolled seal for the negative cases.
		plain := opts.raw_plaintext if opts.raw_plaintext != "" else string(test_keyring_bytes(kr))
		aad, _ := vault.unseal_v2_aad(bridge_id, timestamp, nonce, kr.current_epoch, context.temp_allocator)
		if opts.tamper_aad do aad = strings.concatenate({aad, "x"}, context.temp_allocator)
		if opts.v1_aad do aad = fmt.tprintf("%s:%d:%s", bridge_id, timestamp, nonce)
		ct_hex, tag_hex = test_unseal_seal_raw(&client, bridge_get_public_key_hex(), iv[:], aad, transmute([]byte)plain)
	} else {
		ct_hex, tag_hex, _ = vault.unseal_v2_seal(&client, bridge_get_public_key_hex(), iv[:], kr, bridge_id, timestamp, nonce, context.temp_allocator)
	}
	sig := opts.signature_override
	if sig == "" do sig, _ = bridge_unseal_key_signature_json(bridge_id)
	identity := opts.identity_override
	if identity == "" do identity = bridge_identity_public_key_hex(bridge_id)
	format := opts.format_override if opts.format_override != "" else vault.UNSEAL_V2_FORMAT
	return fmt.aprintf(
		`{{"type":"bridge_unseal","command_id":"cmd_test","bridge_id":"%s","timestamp":%d,"nonce":"%s","client_public_key":"%s","iv":"%s","tag":"%s","ciphertext":"%s","format":"%s","current_epoch":%d,"unseal_key_signature":%s,"bridge_identity_public_key":"%s"}}`,
		bridge_id, timestamp, nonce, vault.hex_encode_lower(client_pub[:], context.temp_allocator), vault.hex_encode_lower(iv[:], context.temp_allocator),
		tag_hex, ct_hex, format, kr.current_epoch, sig if sig != "" else "null", identity,
	)
}

@(private = "file")
test_unseal_seal_raw :: proc(client: ^ecdh.Private_Key, bridge_pub_hex: string, iv: []byte, aad: string, plain: []byte) -> (ct_hex: string, tag_hex: string) {
	// Reuse lib/vault's sealer by building a throwaway keyring is not possible for
	// arbitrary bytes, so derive the key the same way here.
	raw: [P256_POINT_SIZE]byte
	_ = vault.hex_decode_into(raw[:], bridge_pub_hex)
	peer: ecdh.Public_Key
	_ = ecdh.public_key_set_bytes(&peer, .SECP256R1, raw[:])
	shared: [32]byte
	defer crypto.zero_explicit(&shared, size_of(shared))
	_ = ecdh.ecdh(client, &peer, shared[:])
	return test_aes_gcm_hkdf_seal(shared[:], vault.UNSEAL_V2_INFO, iv, aad, plain)
}

// ── HOME sandbox ────────────────────────────────────────────────────────────
//
// Redirects HOME and HEIMDALL_HOME into a fresh temp dir so nothing a test writes
// (vault_configured markers, Termux sealed files) can reach the operator's real
// config. os.set_env is process-wide: every caller holds bridge_test_config_mutex
// OUTERMOST, before keystore_test_mutex. ALWAYS pair open with a deferred close,
// and bail when open returns ok=false (it has already torn itself down).
Bridge_Vault_Test_Sandbox :: struct {
	dir:          string,
	prev_home:    string,
	had_home:     bool,
	prev_hd_home: string,
	had_hd_home:  bool,
	redirected:   bool,
	closed:       bool,
}

bridge_vault_test_sandbox_counter: int

bridge_vault_test_sandbox_open :: proc(t: ^testing.T, label: string) -> (sb: Bridge_Vault_Test_Sandbox, ok: bool) {
	n := sync.atomic_add(&bridge_vault_test_sandbox_counter, 1)
	tmp_root := "/tmp"
	when ODIN_OS == .Windows {
		if v, found := os.lookup_env("TEMP", context.temp_allocator); found do tmp_root = v
	}
	sb.dir = fmt.aprintf("%s/heimdall-bridge-vault-test-%s-%d-%d", tmp_root, label, os.get_pid(), n)
	if derr := os.make_directory_all(sb.dir); derr != nil {
		testing.expectf(t, false, "sandbox dir %s could not be created (%v) — refusing to run", sb.dir, derr)
		return sb, false
	}
	cfg_dir := fmt.tprintf("%s/.config/heimdall", sb.dir)
	if derr := os.make_directory_all(cfg_dir); derr != nil {
		testing.expectf(t, false, "sandbox config dir %s could not be created (%v) — refusing to run", cfg_dir, derr)
		return sb, false
	}
	sb.prev_home, sb.had_home = os.lookup_env("HOME", context.allocator)
	sb.prev_hd_home, sb.had_hd_home = os.lookup_env("HEIMDALL_HOME", context.allocator)
	sb.redirected = true
	if os.set_env("HOME", sb.dir) != nil || os.set_env("HEIMDALL_HOME", sb.dir) != nil {
		testing.expect(t, false, "could not redirect HOME/HEIMDALL_HOME — refusing to run")
		bridge_vault_test_sandbox_close(&sb)
		return sb, false
	}
	rel := "~/.config/heimdall/x"
	bridge_path := bridge_expand_home(rel)
	defer if raw_data(bridge_path) != raw_data(rel) do delete(bridge_path)
	cfg_path := cfg_lib.expand_home(rel)
	defer if raw_data(cfg_path) != raw_data(rel) do delete(cfg_path)
	if !strings.has_prefix(bridge_path, sb.dir) || !strings.has_prefix(cfg_path, sb.dir) {
		testing.expectf(t, false, "config path must resolve inside the sandbox %s — refusing to run", sb.dir)
		bridge_vault_test_sandbox_close(&sb)
		return sb, false
	}
	return sb, true
}

bridge_vault_test_sandbox_close :: proc(sb: ^Bridge_Vault_Test_Sandbox) {
	if sb.closed do return
	sb.closed = true
	if sb.redirected {
		if sb.had_home do _ = os.set_env("HOME", sb.prev_home)
		else do os.unset_env("HOME")
		delete(sb.prev_home)
		if sb.had_hd_home do _ = os.set_env("HEIMDALL_HOME", sb.prev_hd_home)
		else do os.unset_env("HEIMDALL_HOME")
		delete(sb.prev_hd_home)
		sb.redirected = false
	}
	if sb.dir != "" {
		if rerr := os.remove_all(sb.dir); rerr != nil {
			fmt.eprintfln("WARN: sandbox temp dir %s was not removed: %v", sb.dir, rerr)
		}
		delete(sb.dir)
		sb.dir = ""
	}
}

// test_with_env sets name=value (or unsets it for value == "") and returns a restore proc state.
Test_Env_Restore :: struct {
	name:  string,
	prev:  string,
	had:   bool,
}

test_env_set :: proc(name, value: string) -> (r: Test_Env_Restore) {
	r.name = name
	r.prev, r.had = os.lookup_env(name, context.allocator)
	if value == "" do os.unset_env(name)
	else do _ = os.set_env(name, value)
	return
}

test_env_restore :: proc(r: ^Test_Env_Restore) {
	if r.had do _ = os.set_env(r.name, r.prev)
	else do os.unset_env(r.name)
	delete(r.prev)
	r.prev = ""
}

// test_aes_gcm_hkdf_seal: HKDF-SHA256(zero salt, info) over shared → AES-256-GCM.
test_aes_gcm_hkdf_seal :: proc(shared: []byte, info: string, iv: []byte, aad: string, plain: []byte) -> (ct_hex: string, tag_hex: string) {
	key: [32]byte
	defer crypto.zero_explicit(&key, size_of(key))
	salt: [32]byte
	hkdf.extract_and_expand(.SHA256, salt[:], shared, transmute([]byte)info, key[:])
	ct := make([]byte, len(plain), context.temp_allocator)
	tag: [16]byte
	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, key[:])
	defer aes.reset_gcm(&gcm)
	aes.seal_gcm(&gcm, ct, tag[:], iv, transmute([]byte)aad, plain)
	return vault.hex_encode_lower(ct, context.temp_allocator), vault.hex_encode_lower(tag[:], context.temp_allocator)
}

// test_pty_input_payload seals browser keystrokes as a PTY v2 "in" payload with a
// random nonce, exactly as the UI does. Temp-allocated.
test_pty_input_payload :: proc(chunk: string, key_hex: string, epoch: u32, session_id: string) -> ([]byte, bool) {
	key: [32]byte
	defer crypto.zero_explicit(&key, size_of(key))
	_ = vault.hex_decode_into(key[:], key_hex)
	nonce: [12]byte
	crypto.rand_bytes(nonce[:])
	return vault.pty_seal(transmute([]byte)chunk, key[:], epoch, nonce[:], session_id, .In, context.temp_allocator)
}

// test_encrypt_hex / test_decrypt_hex: one-epoch (epoch 1) keyring helpers for
// suites that think in terms of a single key.
test_encrypt_hex :: proc(plaintext: string, key_hex: string, allocator := context.allocator) -> (string, bool) {
	tok := test_vault_seal(plaintext, key_hex, 1, allocator)
	return tok, tok != ""
}

test_decrypt_hex :: proc(token: string, key_hex: string, allocator := context.allocator) -> (string, bool) {
	kr := test_keyring_from_hex(key_hex)
	defer vault.keyring_wipe(&kr)
	return bridge_vault_decrypt_field(token, &kr, allocator)
}
