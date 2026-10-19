package main

// Shared vault test support (passwordless-vault P1): test ids, the env/home sandbox
// and v2 keyring/envelope builders. Everything that used to be scattered across the
// v1 suites (vault_decrypt_test, keystore_test, unseal_security_test) lives here.

import "core:crypto"
import "core:crypto/aes"
import "core:crypto/ecdh"
import "core:crypto/ecdsa"
import "core:crypto/hkdf"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
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
	// An enrollment arms its pairing keys (ham-bridge enroll does the same).
	keys := test_pair_keys()
	bridge_pairing_arm(&keys, bridge_now_unix_ms() + i64(vault.PAIR_CODE_TTL_SECONDS) * 1000)
	vault.pair_keys_wipe(&keys)
	return bridge_unseal_identity_commit_enrollment(bridge_id, owner)
}

// The stretched pairing key of a test enrollment (hub-blind pairing). Tests skip the
// PBKDF2 stretch itself (pinned by the vault vectors) and start from its output.
TEST_PAIR_STRETCHED_KEY :: "7e57000000000000000000000000000000000000000000000000000000007e57"

test_pair_keys :: proc() -> vault.Pair_Keys {
	k: [32]byte
	_ = vault.hex_decode_into(k[:], TEST_PAIR_STRETCHED_KEY)
	return vault.pair_keys_from_stretched(k[:])
}

// test_pair_mac is the approver's pair_mac for a chain proof (under test_pair_keys).
test_pair_mac :: proc(proof_json: string) -> string {
	Proof :: struct {
		root_sign_pub:    string,
		subject_approval: struct {
			statement: string,
		},
	}
	p: Proof
	if json.unmarshal_string(proof_json, &p, json.Specification.JSON, context.temp_allocator) != nil do return ""
	keys := test_pair_keys()
	defer vault.pair_keys_wipe(&keys)
	mac, _ := vault.pair_approve_mac_hex(&keys, p.subject_approval.statement, p.root_sign_pub, context.temp_allocator)
	return mac
}

// ── unseal v2 payload builder (the browser side) ────────────────────────────

Test_Unseal_Options :: struct {
	tamper_aad:          bool,   // seal with a different AAD than the payload claims
	v1_aad:              bool,   // seal with the deleted v1 AAD form
	raw_plaintext:       string, // seal these bytes instead of the keyring
	signature_override:  string, // echo this signature object instead of the bridge's
	identity_override:   string, // echo this identity key instead of the bridge's
	format_override:     string,
	proof_override:      string, // send this chain_proof JSON instead of a valid one
	pair_mac_override:   string, // send this pair_mac instead of the approver's
	no_pair_mac:         bool,   // send no pair_mac (a first unseal not from the approver)
	root_scalar:         string, // sign the default proof under this account root (hex scalar)
}

// ── chain proof builder (the approving device's side) ───────────────────────

// The test account root: a fixed P-256 scalar, so a proof built in one call chains to
// the root pinned by an earlier one. TEST_ACCOUNT_ROOT_OTHER is a different account root.
TEST_ACCOUNT_ROOT_SCALAR :: "0707070707070707070707070707070707070707070707070707070707070707"
TEST_ACCOUNT_ROOT_OTHER  :: "0808080808080808080808080808080808080808080808080808080808080808"

@(private = "file")
test_sign_statement :: proc(priv: ^ecdsa.Private_Key, st: ^vault.Statement) -> (text: string, sig_json: string) {
	text, _ = vault.statement_canonical(st, context.temp_allocator)
	sig, _ := vault.sign_p256(priv, transmute([]byte)text)
	sig_json, _ = vault.signature_object(&sig, context.temp_allocator)
	return
}

// Typed chain_proof v2 (json.marshal); signatures travel as their canonical text.
@(private = "file")
Test_Proof_Signed :: struct {
	statement: string,
	signature: string,
}

@(private = "file")
Test_Proof_Chained :: struct {
	statement:    string,
	signature:    string,
	issuer_chain: []Test_Proof_Signed,
}

@(private = "file")
Test_Proof_Epoch :: struct {
	epoch:        u32,
	statement:    string,
	signature:    string,
	issuer_chain: []Test_Proof_Signed,
}

@(private = "file")
Test_Chain_Proof :: struct {
	v:                int,
	user_id:          string,
	root_device_id:   string,
	root_sign_alg:    string,
	root_sign_pub:    string,
	genesis:          Test_Proof_Signed,
	epochs:           []Test_Proof_Epoch,
	subject_approval: Test_Proof_Chained,
}

// test_chain_proof builds a valid minimal `chain_proof` v2 (the UI's
// buildBridgeChainProof shape) for bridge_id's identity and kr: the root's genesis
// (log seq 1, introducing epoch 1), one root-signed carrier per keyring epoch (the
// genesis for epoch 1, a `rotate` op otherwise) and the root's approval of the bridge;
// every issuer chain is empty. Temp-allocated.
test_chain_proof :: proc(bridge_id: string, kr: ^vault.Vault_Keyring, root_scalar_hex: string = TEST_ACCOUNT_ROOT_SCALAR) -> string {
	scalar: [32]byte
	_ = vault.hex_decode_into(scalar[:], root_scalar_hex)
	root: ecdsa.Private_Key
	defer ecdsa.private_key_clear(&root)
	_ = ecdsa.private_key_set_bytes(&root, .SECP256R1, scalar[:])
	pub: [65]byte
	ecdsa.private_key_public_bytes(&root, pub[:])
	root_pub := vault.hex_encode_lower(pub[:], context.temp_allocator)
	root_id, _ := vault.device_id_from_sign_pub(root_pub, context.temp_allocator)
	owner := vault.keyring_user_id(kr)
	commit_hex :: proc(kr: ^vault.Vault_Keyring, i: int) -> string {
		c: [32]byte
		_ = vault.epoch_commit(kr.entries[i].key[:], vault.keyring_user_id(kr), kr.entries[i].epoch, c[:])
		return vault.hex_encode_lower(c[:], context.temp_allocator)
	}
	seq := 1
	prev := ""
	next_seq :: proc(seq: ^int) -> string {
		s := fmt.tprintf("%d", seq^)
		seq^ += 1
		return s
	}
	genesis := vault.Statement{
		type = "genesis", user_id = owner, seq = next_seq(&seq), prev_hash = prev, issuer_device_id = root_id, issued_at_ms = "1",
		subject_device_id = root_id, subject_kind = "browser", subject_sign_pub = root_pub, subject_ecdh_pub = root_pub,
		subject_sign_alg = vault.SIGN_ALG_ECDSA_P256_SHA256, subject_wrap_alg = vault.WRAP_ALG_ECDH_P256_HKDF_AES,
		subject_label_b64 = "cm9vdA", epoch = "1",
		epoch_commit = commit_hex(kr, 0) if kr.entries[0].epoch == 1 else strings.repeat("0", 64, context.temp_allocator),
	}
	g_text, g_sig := test_sign_statement(&root, &genesis)
	prev = vault.log_entry_hash(g_text, context.temp_allocator)
	carriers := make([dynamic]Test_Proof_Epoch, context.temp_allocator)
	for i in 0 ..< kr.count {
		e := kr.entries[i].epoch
		text, sig := g_text, g_sig
		if e != 1 {
			st := vault.Statement{
				type = "rotate", user_id = owner, seq = next_seq(&seq), prev_hash = prev, issuer_device_id = root_id, issued_at_ms = "2",
				epoch = fmt.tprintf("%d", e), epoch_commit = commit_hex(kr, i),
			}
			text, sig = test_sign_statement(&root, &st)
			prev = vault.log_entry_hash(text, context.temp_allocator)
		}
		append(&carriers, Test_Proof_Epoch{epoch = e, statement = text, signature = sig, issuer_chain = []Test_Proof_Signed{}})
	}
	identity := bridge_identity_public_key_hex(bridge_id)
	bridge_dev, _ := vault.device_id_from_sign_pub(identity, context.temp_allocator)
	approval := vault.Statement{
		type = "approve", user_id = owner, seq = next_seq(&seq), prev_hash = prev, issuer_device_id = root_id, issued_at_ms = "3",
		subject_device_id = bridge_dev, subject_kind = "bridge", subject_sign_pub = identity,
		subject_sign_alg = vault.SIGN_ALG_ECDSA_P256_SHA256, subject_label_b64 = "YnJpZGdl", epoch = "1",
	}
	a_text, a_sig := test_sign_statement(&root, &approval)
	proof, _ := vault.wire_encode(Test_Chain_Proof{
		v = 2, user_id = owner, root_device_id = root_id, root_sign_alg = vault.SIGN_ALG_ECDSA_P256_SHA256, root_sign_pub = root_pub,
		genesis = {statement = g_text, signature = g_sig},
		epochs = carriers[:],
		subject_approval = {statement = a_text, signature = a_sig, issuer_chain = []Test_Proof_Signed{}},
	}, context.temp_allocator)
	return proof
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
	proof := opts.proof_override
	if proof == "" && bridge_identity_public_key_hex(bridge_id) != "" {
		proof = test_chain_proof(bridge_id, kr, opts.root_scalar if opts.root_scalar != "" else TEST_ACCOUNT_ROOT_SCALAR)
	}
	pair_mac := opts.pair_mac_override
	if pair_mac == "" && !opts.no_pair_mac && proof != "" do pair_mac = test_pair_mac(proof)
	as_value :: proc(text: string) -> json.Value {
		if text == "" do return nil
		v, err := json.parse_string(text, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
		return v if err == nil else json.String(text)
	}
	Payload :: struct {
		type:                       string,
		command_id:                 string,
		bridge_id:                  string,
		timestamp:                  i64,
		nonce:                      string,
		client_public_key:          string,
		iv:                         string,
		tag:                        string,
		ciphertext:                 string,
		format:                     string,
		current_epoch:              u32,
		unseal_key_signature:       json.Value,
		bridge_identity_public_key: string,
		chain_proof:                json.Value,
		pair_mac:                   string `json:"pair_mac,omitempty"`,
	}
	data, _ := json.marshal(Payload{
		type = "bridge_unseal", command_id = "cmd_test", bridge_id = bridge_id, timestamp = timestamp, nonce = nonce,
		client_public_key = vault.hex_encode_lower(client_pub[:], context.temp_allocator), iv = vault.hex_encode_lower(iv[:], context.temp_allocator),
		tag = tag_hex, ciphertext = ct_hex, format = format, current_epoch = kr.current_epoch,
		unseal_key_signature = as_value(sig), bridge_identity_public_key = identity, chain_proof = as_value(proof),
		pair_mac = pair_mac,
	})
	return string(data)
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

// test_pty_input_payload seals browser keystrokes as a PTY v2 "in" frame the way the
// UI does: a fresh random salt (a new stream, hence a new subkey) and a wall-clock
// seeded counter, so successive calls are always accepted by the replay check.
// Temp-allocated.
test_pty_input_counter: u64

test_pty_input_payload :: proc(chunk: string, key_hex: string, epoch: u32, session_id: string) -> ([]byte, bool) {
	salt: [vault.PTY_V2_SALT_BYTES]byte
	crypto.rand_bytes(salt[:])
	// The handlers open input under this process's own unseal boot_id.
	return test_pty_input_payload_with(chunk, key_hex, epoch, session_id, salt, test_pty_input_next_counter(), bridge_unseal_boot_id())
}

test_pty_input_next_counter :: proc() -> u64 {
	seed := u64(time.time_to_unix_nano(time.now()) / 1_000_000) * 1000
	for {
		cur := sync.atomic_load(&test_pty_input_counter)
		next := max(cur + 1, seed)
		if _, swapped := sync.atomic_compare_exchange_strong(&test_pty_input_counter, cur, next); swapped do return next
	}
}

test_pty_input_payload_with :: proc(chunk: string, key_hex: string, epoch: u32, session_id: string, salt: [vault.PTY_V2_SALT_BYTES]byte, counter: u64, boot_id: string) -> ([]byte, bool) {
	key: [32]byte
	defer crypto.zero_explicit(&key, size_of(key))
	_ = vault.hex_decode_into(key[:], key_hex)
	salt_copy := salt
	return vault.pty_seal(transmute([]byte)chunk, key[:], epoch, salt_copy[:], counter, session_id, .In, boot_id, context.temp_allocator)
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
