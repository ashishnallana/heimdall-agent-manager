package main

// Passwordless vault P1 â€” bridge-side security tests (compact by design; the
// format-level vectors and negatives live in src/lib/vault/vault_test.odin).
// None of these spawn a shell, so they run on Windows too:
//   odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_NAMES=main.test_v2_...

import "core:crypto/ecdsa"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import os_random "odin_test:lib/os_random"
import vault "odin_test:lib/vault"

@(private = "file")
V2_KEY_2 :: "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"

@(private = "file")
V2_Fixture :: struct {
	id_a, id_b:     string,
	prev_daemon_id: string,
}

@(private = "file")
v2_open :: proc() -> (f: V2_Fixture) {
	f.id_a, f.id_b = keystore_test_bridge_ids()
	f.prev_daemon_id = keystore_test_set_daemon_id(f.id_a)
	keystore_lock_and_purge(f.id_a)
	_ = keystore_delete_identity_key(f.id_a)
	bridge_unseal_forget_identity()
	unseal_nonce_cache_clear(&g_unseal_nonce_cache)
	bridge_unseal_init()
	_ = test_provision_identity(f.id_a)
	return
}

@(private = "file")
v2_close :: proc(f: ^V2_Fixture) {
	keystore_lock_and_purge(f.id_a)
	_ = keystore_delete_identity_key(f.id_a)
	bridge_unseal_forget_identity()
	unseal_nonce_cache_clear(&g_unseal_nonce_cache)
	bridge_config.daemon_id = f.prev_daemon_id
}

@(private = "file")
v2_now :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}

@(test)
test_v2_keystore_keyring_and_identity_round_trip :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f := v2_open()
	defer v2_close(&f)

	// The largest keyring (64 epochs, 64-byte user id) must fit every backend,
	// including the Windows Credential Manager's 2560-byte blob limit.
	big: vault.Vault_Keyring
	defer vault.keyring_wipe(&big)
	for i in 0 ..< vault.KEYRING_MAX_EPOCHS {
		big.entries[i].epoch = u32(i + 1)
		big.entries[i].key[0] = byte(i)
	}
	copy(big.user_id_buf[:], strings.repeat("u", 64, context.temp_allocator))
	big.user_id_len = 64
	big.count = vault.KEYRING_MAX_EPOCHS
	big.current_epoch = vault.KEYRING_MAX_EPOCHS
	ok, err := keystore_store_vault_keyring(f.id_a, test_keyring_bytes(&big))
	testing.expectf(t, ok && err == 0, "max keyring must persist (err %d)", err)
	keystore_wipe_in_memory_vault_key()
	back, back_ok := keystore_read_persisted_vault_keyring(f.id_a)
	defer vault.keyring_wipe(&back)
	testing.expect(t, back_ok && vault.keyring_equal(&back, &big), "max keyring reads back unchanged")

	// A blob that is not a valid keyring is refused, never stored.
	bad_ok, _ := keystore_store_vault_keyring(f.id_a, transmute([]byte)string(TEST_VAULT_KEY_HEX))
	testing.expect(t, !bad_ok, "a v1 hex key is not a keyring")

	// Another bridge's in-memory cache is never served to this one.
	testing.expect(t, keystore_store_in_memory_vault_keyring(f.id_b, test_keyring_bytes(&big)))
	_, cross := keystore_read_in_memory_vault_keyring(f.id_a)
	testing.expect(t, !cross, "memory cache is per bridge id")
	keystore_wipe_in_memory_vault_key()

	// Identity record: persisted under the bridge id with its owner, survives lock,
	// removed by delete; absence and a read error are told apart.
	scalar: [32]byte
	scalar[31] = 7
	testing.expect(t, keystore_store_identity(f.id_a, scalar[:], "usr_owner"))
	keystore_lock_and_purge(f.id_a)
	rec: Bridge_Identity_Record
	testing.expect_value(t, keystore_read_identity(f.id_a, &rec), Keystore_Read_Status.Found)
	testing.expect(t, rec.scalar == scalar && bridge_identity_record_owner(&rec) == "usr_owner", "lock keeps the identity record")
	keystore_set_mock_syscall_error(KEYSTORE_ERR_EACCES)
	testing.expect_value(t, keystore_read_identity(f.id_a, &rec), Keystore_Read_Status.Error)
	keystore_set_mock_syscall_error(0)
	testing.expect(t, keystore_delete_identity_key(f.id_a))
	testing.expect_value(t, keystore_read_identity(f.id_a, &rec), Keystore_Read_Status.Not_Found)
}

@(test)
test_v2_unseal_accepts_signed_payload_and_rejects_negatives :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f := v2_open()
	defer v2_close(&f)

	// v2_open enrolled an identity; its signed unseal key is advertised.
	sig, sig_ok := bridge_unseal_key_signature_json(f.id_a)
	testing.expect(t, sig_ok, "signed unseal key available")
	identity := bridge_identity_public_key_hex(f.id_a)
	canonical, _ := vault.bridge_unseal_key_canonical(f.id_a, bridge_get_public_key_hex(), bridge_unseal_boot_id(), context.temp_allocator)
	testing.expect(t, vault.verify(vault.SIGN_ALG_ECDSA_P256_SHA256, identity, transmute([]byte)canonical, sig), "advertised signature verifies")

	kr := test_keyring_two_epochs(TEST_VAULT_KEY_HEX, V2_KEY_2)
	defer vault.keyring_wipe(&kr)
	now := v2_now()

	expect_reject :: proc(t: ^testing.T, payload: string, local_id: string, now: i64, why: string) {
		ok, msg := bridge_unseal_decrypt_and_verify(payload, local_id, now)
		testing.expectf(t, !ok, "%s must be rejected", why)
		testing.expectf(t, msg != "", "%s must say why", why)
		delete(payload)
	}

	// Wrong target bridge.
	expect_reject(t, test_create_unseal_v2_payload(f.id_b, &kr, now, "n_wrong_bridge"), f.id_a, now, "wrong bridge_id")
	// Clock skew beyond 30 s, both directions.
	expect_reject(t, test_create_unseal_v2_payload(f.id_a, &kr, now - 31_000, "n_skew_past"), f.id_a, now, "stale timestamp")
	expect_reject(t, test_create_unseal_v2_payload(f.id_a, &kr, now + 31_000, "n_skew_future"), f.id_a, now, "future timestamp")
	// The deleted v1 AAD form and v1 plaintexts.
	expect_reject(t, test_create_unseal_v2_payload(f.id_a, &kr, now, "n_v1_aad", {v1_aad = true}), f.id_a, now, "v1 AAD")
	expect_reject(t, test_create_unseal_v2_payload(f.id_a, &kr, now, "n_raw32", {raw_plaintext = "0123456789abcdef0123456789abcdef"}), f.id_a, now, "32-byte plaintext")
	expect_reject(t, test_create_unseal_v2_payload(f.id_a, &kr, now, "n_hex64", {raw_plaintext = TEST_VAULT_KEY_HEX}), f.id_a, now, "64-hex plaintext")
	expect_reject(t, test_create_unseal_v2_payload(f.id_a, &kr, now, "n_tamper", {tamper_aad = true}), f.id_a, now, "tampered AAD")
	expect_reject(t, test_create_unseal_v2_payload(f.id_a, &kr, now, "n_format", {format_override = "raw-key-v1"}), f.id_a, now, "unknown format")
	// Ephemeral key signed by a different identity key.
	other: ecdsa.Private_Key
	defer ecdsa.private_key_clear(&other)
	testing.expect(t, vault.p256_private_key_generate(&other))
	other_sig, _ := vault.sign_p256(&other, transmute([]byte)canonical)
	other_obj, _ := vault.signature_object(&other_sig, context.temp_allocator)
	expect_reject(t, test_create_unseal_v2_payload(f.id_a, &kr, now, "n_other_sig", {signature_override = other_obj}), f.id_a, now, "signature by another identity")
	// Unsigned ephemeral key, and an unknown signature algorithm.
	expect_reject(t, test_create_unseal_v2_payload(f.id_a, &kr, now, "n_unsigned", {signature_override = "null"}), f.id_a, now, "unsigned key")
	unknown_alg, _ := strings.replace(sig, vault.SIGN_ALG_ECDSA_P256_SHA256, "webauthn-es256", 1, context.temp_allocator)
	expect_reject(t, test_create_unseal_v2_payload(f.id_a, &kr, now, "n_alg", {signature_override = unknown_alg}), f.id_a, now, "unknown signature alg")
	// Identity-key mismatch: the payload names a different identity.
	other_pub: [65]byte
	ecdsa.private_key_public_bytes(&other, other_pub[:])
	expect_reject(t, test_create_unseal_v2_payload(f.id_a, &kr, now, "n_identity", {identity_override = vault.hex_encode_lower(other_pub[:], context.temp_allocator)}), f.id_a, now, "identity mismatch")
	_, still_locked := bridge_read_vault_keyring()
	testing.expect(t, !still_locked, "no rejected payload stored anything")

	// The genuine payload succeeds once; its replay is refused.
	good := test_create_unseal_v2_payload(f.id_a, &kr, now, "n_good")
	defer delete(good)
	ok, msg := bridge_unseal_decrypt_and_verify(good, f.id_a, now)
	testing.expectf(t, ok, "genuine payload accepted: %s", msg)
	got, got_ok := bridge_read_vault_keyring()
	defer vault.keyring_wipe(&got)
	testing.expect(t, got_ok && vault.keyring_equal(&got, &kr), "keyring installed exactly")
	replay_ok, _ := bridge_unseal_decrypt_and_verify(good, f.id_a, now + 10)
	testing.expect(t, !replay_ok, "replayed nonce rejected")

	// A keyring for a different user never replaces the installed one.
	foreign_kr := test_keyring_from_hex(V2_KEY_2, 1, "usr_someone_else")
	defer vault.keyring_wipe(&foreign_kr)
	expect_reject(t, test_create_unseal_v2_payload(f.id_a, &foreign_kr, now, "n_foreign"), f.id_a, now, "different user keyring")
}

@(test)
test_v2_command_epoch_floor_enc_spec_and_search :: proc(t: ^testing.T) {
	kr := test_keyring_two_epochs(TEST_VAULT_KEY_HEX, V2_KEY_2)
	defer vault.keyring_wipe(&kr)

	// enc_spec: only the current epoch opens, even though epoch 1 is still held.
	old := test_vault_seal(`{"cmd":"true"}`, TEST_VAULT_KEY_HEX, 1)
	defer delete(old)
	cur := test_vault_seal(`{"cmd":"true"}`, V2_KEY_2, 2)
	defer delete(cur)
	_, old_ok := bridge_open_current_epoch_token(old, &kr)
	testing.expect(t, !old_ok, "enc_spec under a non-current epoch is rejected")
	plain, cur_ok := bridge_open_current_epoch_token(cur, &kr)
	defer if cur_ok do delete(plain)
	testing.expect(t, cur_ok && plain == `{"cmd":"true"}`, "enc_spec under the current epoch opens")
	_, plain_ok := bridge_open_current_epoch_token(`{"cmd":"true"}`, &kr)
	testing.expect(t, !plain_ok, "a plaintext enc_spec is never accepted")
	// Content fields still read history.
	hist, hist_ok := bridge_vault_decrypt_field(old, &kr)
	defer if hist_ok do delete(hist)
	testing.expect(t, hist_ok, "content under an older held epoch still decrypts")

	// Search RPC: epoch-1 request refused; epoch-2 accepted once; replay refused.
	expires := v2_now() + 4_000
	seal_req :: proc(kr: ^vault.Vault_Keyring, epoch: u32, expires: i64) -> string {
		env, _ := task_chain_search_seal(`{"request_id":"r1","query":"deploy","limit":5}`, kr, epoch, "usr_bridge_test", "brg_x", "r1", "request", expires)
		return env
	}
	env1 := seal_req(&kr, 1, expires)
	defer delete(env1)
	env2 := seal_req(&kr, 2, expires)
	defer delete(env2)
	testing.expect(t, strings.has_prefix(env1, "search:v2:e1:") && strings.has_prefix(env2, "search:v2:e2:"))
	_, _, ok1 := task_chain_search_open(env1, &kr, "usr_bridge_test", "brg_x", "r1", "request", expires)
	testing.expect(t, !ok1, "search request under a non-current epoch is rejected")
	p2, e2, ok2 := task_chain_search_open(env2, &kr, "usr_bridge_test", "brg_x", "r1", "request", expires)
	defer if ok2 do delete(p2)
	testing.expect(t, ok2 && e2 == 2, "current-epoch search request opens")
	_, _, ok3 := task_chain_search_open(env2, &kr, "usr_bridge_test", "brg_x", "r1", "request", expires)
	testing.expect(t, !ok3, "replayed search nonce rejected")
	_, _, ok4 := task_chain_search_open(env2, &kr, "usr_bridge_test", "brg_x", "r1", "response", expires)
	testing.expect(t, !ok4, "AAD binds direction")
}

@(test)
test_v2_pty_salt_is_fresh_per_worker_epoch_and_install :: proc(t: ^testing.T) {
	// Two workers for the same session (a restart) never share a salt, so the same
	// (epoch, salt, seq) nonce can never repeat across the restart.
	w1, w2: Bridge_PTY_Stream_Worker
	s1, q1, ok1 := _bridge_pty_stream_next_nonce(&w1, 2)
	s2, q2, ok2 := _bridge_pty_stream_next_nonce(&w2, 2)
	testing.expect(t, ok1 && ok2 && q1 == 1 && q2 == 1)
	testing.expect(t, s1 != s2, "a restarted worker draws a fresh salt")
	sa, qa, _ := _bridge_pty_stream_next_nonce(&w1, 2)
	testing.expect(t, sa == s1 && qa == 2, "seq advances under one salt")
	// Epoch change: new salt.
	se, qe, _ := _bridge_pty_stream_next_nonce(&w1, 3)
	testing.expect(t, se != s1 && qe == 1, "a new epoch draws a fresh salt")
	// Keyring install: new salt even for the same epoch.
	bridge_pty_stream_resalt_all()
	si, _, _ := _bridge_pty_stream_next_nonce(&w1, 3)
	testing.expect(t, si != se, "a keyring install re-salts")
	// Randomness failure: no nonce, nothing sealed.
	sync.mutex_lock(&test_pty_random_source_mu)
	prev := bridge_pty_random_source
	bridge_pty_random_source = "/nonexistent/heimdall-no-random"
	w3: Bridge_PTY_Stream_Worker
	_, _, ok_fail := _bridge_pty_stream_next_nonce(&w3, 2)
	bridge_pty_random_source = prev
	sync.mutex_unlock(&test_pty_random_source_mu)
	testing.expect(t, !ok_fail, "CSPRNG failure must fail closed")

	// A sealed frame carries its epoch and only opens for its session/direction.
	kr := test_keyring_two_epochs(TEST_VAULT_KEY_HEX, V2_KEY_2)
	defer vault.keyring_wipe(&kr)
	frame, sealed := bridge_pty_stream_seal_v2(transmute([]byte)string("hi"), &kr, 2, s1, 1, "sh_v2", context.temp_allocator)
	testing.expect(t, sealed)
	ep, _ := vault.pty_frame_epoch(frame)
	testing.expect_value(t, ep, u32(2))
	_, _, _, wrong_dir := vault.pty_open(frame, &kr, "sh_v2", .In, 2, "", context.temp_allocator)
	testing.expect(t, !wrong_dir, "an output frame is not valid input")
	_, _, _, right := vault.pty_open(frame, &kr, "sh_v2", .Out, 2, "", context.temp_allocator)
	testing.expect(t, right)
	// Two workers (restart) never produce the same (subkey, nonce): the frames differ
	// in their salt and therefore in their key stream even at the same seq.
	frame2, _ := bridge_pty_stream_seal_v2(transmute([]byte)string("hi"), &kr, 2, s2, 1, "sh_v2", context.temp_allocator)
	testing.expect(t, string(frame[4:20]) != string(frame2[4:20]) && string(frame[vault.PTY_V2_HEADER_BYTES:]) != string(frame2[vault.PTY_V2_HEADER_BYTES:]))
}

// test_pty_random_source_mu serializes tests that point bridge_pty_random_source at a
// failing source (a package global shared by parallel tests).
test_pty_random_source_mu: sync.Mutex

// Finding M1: a replayed input frame is refused; a new salt (new stream) starts a new
// counter sequence but cannot replay an evicted stream below the floor.
@(test)
test_v2_pty_input_replay_is_rejected :: proc(t: ^testing.T) {
	// Fixed counters: start from (and leave) an empty replay table, under the lock the
	// other PTY tests hold, so no other test's state or floor can leak in.
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_pty_input_replay_reset()
	defer bridge_pty_input_replay_reset()
	kr := test_keyring_two_epochs(TEST_VAULT_KEY_HEX, V2_KEY_2)
	defer vault.keyring_wipe(&kr)
	sid := "sh_replay_test"
	BOOT :: "00112233445566778899aabbccddeeff"
	salt_a: [vault.PTY_V2_SALT_BYTES]byte
	salt_a[0] = 0xa1
	f1, _ := test_pty_input_payload_with("a", V2_KEY_2, 2, sid, salt_a, 1000, BOOT)
	f2, _ := test_pty_input_payload_with("b", V2_KEY_2, 2, sid, salt_a, 1001, BOOT)
	p1, ok1 := bridge_pty_open_input(f1, &kr, sid, BOOT)
	testing.expect(t, ok1 && p1 == "a")
	_, replay := bridge_pty_open_input(f1, &kr, sid, BOOT)
	testing.expect(t, !replay, "the same frame twice is a replay")
	_, ok2 := bridge_pty_open_input(f2, &kr, sid, BOOT)
	testing.expect(t, ok2)
	_, stale := bridge_pty_open_input(f1, &kr, sid, BOOT)
	testing.expect(t, !stale, "an older counter under the same salt is refused")
	// Another session id: the AAD and subkey differ, so the frame does not authenticate.
	_, cross := bridge_pty_open_input(f2, &kr, "sh_replay_other", BOOT)
	testing.expect(t, !cross)
	// Bridge restart: a new boot_id. A frame sealed for the previous process does not
	// authenticate, whatever its counter -- the lost replay state cannot be exploited.
	salt_r: [vault.PTY_V2_SALT_BYTES]byte
	salt_r[0] = 0xc3
	fr, _ := test_pty_input_payload_with("r", V2_KEY_2, 2, "sh_replay_restart", salt_r, 9000, BOOT)
	_, after_restart := bridge_pty_open_input(fr, &kr, "sh_replay_restart", "ffeeddccbbaa99887766554433221100")
	testing.expect(t, !after_restart, "a frame bound to an old boot_id is refused")
	_, no_boot := bridge_pty_open_input(fr, &kr, "sh_replay_restart", "")
	testing.expect(t, !no_boot, "no boot_id, no input")
	// A new stream (new salt) may start its own sequence.
	salt_b: [vault.PTY_V2_SALT_BYTES]byte
	salt_b[0] = 0xb2
	f3, _ := test_pty_input_payload_with("c", V2_KEY_2, 2, sid, salt_b, 5000, BOOT)
	_, ok3 := bridge_pty_open_input(f3, &kr, sid, BOOT)
	testing.expect(t, ok3)
	// Non-current epoch input is refused (command epoch floor).
	f4, _ := test_pty_input_payload_with("d", TEST_VAULT_KEY_HEX, 1, sid, salt_b, 5001, BOOT)
	_, old_epoch := bridge_pty_open_input(f4, &kr, sid, BOOT)
	testing.expect(t, !old_epoch)

	// The replay table itself: eviction raises the floor so evicted salts stay dead.
	r: vault.Pty_Input_Replay
	for i in 0 ..< vault.PTY_REPLAY_SALTS {
		s: [vault.PTY_V2_SALT_BYTES]byte
		s[0] = u8(i + 1)
		testing.expect(t, vault.pty_replay_accept(&r, s, u64(100 + i)))
	}
	s_new: [vault.PTY_V2_SALT_BYTES]byte
	s_new[0] = 0xff
	testing.expect(t, vault.pty_replay_accept(&r, s_new, 1000), "a new stream evicts the oldest")
	s_old: [vault.PTY_V2_SALT_BYTES]byte
	s_old[0] = 1
	testing.expect(t, !vault.pty_replay_accept(&r, s_old, 100), "an evicted salt cannot be replayed")
	testing.expect(t, vault.pty_replay_accept(&r, s_old, 101), "a live evicted stream may continue above the floor")
}

// The pane reply never carries plaintext on a configured vault. Hermetic: the vault
// state and keyring are passed to the sealing core; no env, no keystore.
@(test)
test_v2_pane_capture_is_sealed :: proc(t: ^testing.T) {
	kr := test_keyring_from_hex(TEST_ENC_VAULT_KEY)
	defer vault.keyring_wipe(&kr)

	output, res := bridge_pane_output_seal_with(.Unlocked, &kr, "top secret screen", "sh_pane", os_random.DEFAULT_SOURCE)
	defer delete(output)
	testing.expect(t, res == .Sealed)
	reply := bridge_pane_reply_from_seal("cmd_pane_seal", false, "h1", output, res, 1, false)
	defer delete(reply)
	testing.expect(t, !strings.contains(reply, "top secret"), "no plaintext in the reply")
	prefix_buf: [64]byte
	testing.expect(t, strings.has_prefix(output, vault.token_prefix(kr.vault_id, 1, prefix_buf[:])), output)
	vid, epoch, body, pres := vault.envelope_parse(output, context.temp_allocator)
	testing.expect(t, pres == .Ok && epoch == 1 && vid == kr.vault_id)
	frame := make([]byte, 4 + len(body), context.temp_allocator)
	frame[3] = 1
	copy(frame[4:], body)
	plain, _, _, ok := vault.pty_open(frame, &kr, "sh_pane", .Out, 0, "", context.temp_allocator)
	testing.expect(t, ok && string(plain) == "top secret screen")

	// Randomness failure and a locked vault: an error, never plaintext.
	_, fres := bridge_pane_output_seal_with(.Unlocked, &kr, "top secret screen", "sh_pane", "/nonexistent/heimdall-no-random")
	failed := bridge_pane_reply_from_seal("cmd_pane_seal_fail", false, "h1", "", fres, 1, false)
	defer delete(failed)
	testing.expect(t, !strings.contains(failed, "top secret") && strings.contains(failed, "encryption_failed"), failed)
	_, lres := bridge_pane_output_seal_with(.Locked, nil, "top secret screen", "sh_pane", os_random.DEFAULT_SOURCE)
	locked := bridge_pane_reply_from_seal("cmd_pane_seal_locked", false, "h1", "", lres, 1, false)
	defer delete(locked)
	testing.expect(t, !strings.contains(locked, "top secret") && strings.contains(locked, "vault_locked"), locked)
	// Not enrolled refuses exactly like locked: there is no plaintext mode.
	_, nres := bridge_pane_output_seal_with(.Not_Enrolled, nil, "plain screen", "sh_pane", os_random.DEFAULT_SOURCE)
	testing.expect(t, nres == .Locked)
}

// capture_agent_pane (chat pane capture) is sealed as a v2 content envelope the UI
// decrypts like any vault chat body; locked / seal failure never leak the screen.
@(test)
test_v2_chat_pane_capture_result_is_sealed :: proc(t: ^testing.T) {
	kr := test_keyring_from_hex(TEST_ENC_VAULT_KEY)
	defer vault.keyring_wipe(&kr)
	pending := Bridge_Pane_Capture_Pending{command_id = "cmd_cap", pane_capture_request_id = "pcr_cap", agent_instance_id = "inst_cap", width = 80}

	sealed := bridge_pane_capture_result_sealed_json(pending, .Unlocked, &kr, "secret pane\nline 2", 2, false, os_random.DEFAULT_SOURCE)
	defer delete(sealed)
	testing.expect(t, strings.contains(sealed, `"ok":true`) && !strings.contains(sealed, "secret pane"), sealed)
	token := extract_json_string(sealed, "output", "", context.temp_allocator)
	plain, opened := vault.open(token, &kr, context.temp_allocator)
	testing.expect(t, opened == .Ok && plain == "secret pane\nline 2", token)

	locked := bridge_pane_capture_result_sealed_json(pending, .Locked, nil, "secret pane", 1, false, os_random.DEFAULT_SOURCE)
	defer delete(locked)
	testing.expect(t, strings.contains(locked, `"cause":"vault_locked"`) && !strings.contains(locked, "secret pane"), locked)
	failed := bridge_pane_capture_result_sealed_json(pending, .Unlocked, &kr, "secret pane", 1, false, "/nonexistent/heimdall-no-random")
	defer delete(failed)
	testing.expect(t, strings.contains(failed, `"cause":"encryption_failed"`) && !strings.contains(failed, "secret pane"), failed)
	unenrolled := bridge_pane_capture_result_sealed_json(pending, .Not_Enrolled, nil, "plain pane", 1, false, os_random.DEFAULT_SOURCE)
	defer delete(unenrolled)
	testing.expect(t, strings.contains(unenrolled, `"cause":"vault_locked"`) && !strings.contains(unenrolled, "plain pane"), unenrolled)

	// An oversized capture keeps its tail from a line start, fits the hub cap, is marked truncated.
	big := strings.concatenate({strings.repeat("x", BRIDGE_PANE_CAPTURE_SEAL_MAX_PLAIN, context.temp_allocator), "\nlast line"}, context.temp_allocator)
	tok, bres, cut := bridge_pane_capture_seal_with(.Unlocked, &kr, big, os_random.DEFAULT_SOURCE)
	defer delete(tok)
	testing.expect(t, bres == .Sealed && cut && len(tok) <= 48000)
	tail, _ := vault.open(tok, &kr, context.temp_allocator)
	testing.expect_value(t, tail, "last line")
}

// The viewer learns the bridge's unseal boot id from stream_ready (PTY v2 input AAD).
@(test)
test_v2_stream_ready_carries_boot_id :: proc(t: ^testing.T) {
	with_boot := bridge_pty_stream_format_lifecycle_event("shell_pty_stream_ready", "sh_b", "sh_b", false, 0, context.temp_allocator, "00112233445566778899aabbccddeeff")
	testing.expect(t, strings.contains(with_boot, `"bridge_boot_id":"00112233445566778899aabbccddeeff"`), with_boot)
	closed := bridge_pty_stream_format_lifecycle_event("shell_pty_stream_closed", "sh_b", "sh_b", false, 0, context.temp_allocator)
	testing.expect(t, !strings.contains(closed, "bridge_boot_id"), closed)
}

@(test)
test_v2_identity_is_never_regenerated :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f := v2_open()
	defer v2_close(&f)

	enrolled := bridge_identity_public_key_hex(f.id_a)
	testing.expect(t, enrolled != "", "enrollment committed an identity")
	testing.expect_value(t, bridge_enrolled_owner_user_id(f.id_a), TEST_VAULT_USER_ID)

	// A restart reads the same identity back.
	bridge_unseal_forget_identity()
	testing.expect_value(t, bridge_identity_public_key_hex(f.id_a), enrolled)

	// A keystore read error is not absence, and never mints a new identity.
	bridge_unseal_forget_identity()
	keystore_set_mock_syscall_error(KEYSTORE_ERR_EACCES)
	testing.expect_value(t, bridge_identity_public_key_hex(f.id_a), "")
	testing.expect_value(t, bridge_identity_state(f.id_a), Bridge_Identity_State.Unreadable)
	keystore_set_mock_syscall_error(0)
	testing.expect_value(t, bridge_identity_public_key_hex(f.id_a), enrolled)

	// A lost record puts the bridge in "identity lost; re-enroll": no identity,
	// no signed key, no hello advertisement, and nothing regenerated.
	testing.expect(t, keystore_delete_identity_key(f.id_a))
	bridge_unseal_forget_identity()
	testing.expect_value(t, bridge_identity_public_key_hex(f.id_a), "")
	testing.expect_value(t, bridge_identity_state(f.id_a), Bridge_Identity_State.Lost)
	_, sig_ok := bridge_unseal_key_signature_json(f.id_a)
	testing.expect(t, !sig_ok, "no signed unseal key without an identity")
	b := strings.builder_make(context.temp_allocator)
	bridge_unseal_write_hello_fields(&b, f.id_a)
	testing.expect(t, strings.contains(strings.to_string(b), `"identity_state":"lost"`), "hello reports the lost identity")
	testing.expect(t, !strings.contains(strings.to_string(b), "unseal_key_signature"), "hello advertises no unseal key")
	rec: Bridge_Identity_Record
	testing.expect_value(t, keystore_read_identity(f.id_a, &rec), Keystore_Read_Status.Not_Found)

	// Committing requires an enrollment's pending identity and a valid owner.
	testing.expect(t, !bridge_unseal_identity_commit_enrollment(f.id_a, TEST_VAULT_USER_ID), "no pending identity to commit")
	_, gen_ok := bridge_unseal_identity_generate_for_enrollment()
	testing.expect(t, gen_ok)
	testing.expect(t, !bridge_unseal_identity_commit_enrollment(f.id_a, ""), "an unknown owner cannot be pinned")
}

@(test)
test_v2_unseal_keyring_owner_and_superset :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f := v2_open()
	defer v2_close(&f)
	now := v2_now()

	try_unseal :: proc(id: string, kr: ^vault.Vault_Keyring, now: i64, nonce: string) -> bool {
		payload := test_create_unseal_v2_payload(id, kr, now, nonce)
		defer delete(payload)
		ok, _ := bridge_unseal_decrypt_and_verify(payload, id, now)
		return ok
	}

	// (a) First unseal: a keyring for anyone but the enrolled owner is refused.
	hostile := test_keyring_from_hex(TEST_VAULT_KEY_HEX, 1, "usr_hostile_hub")
	defer vault.keyring_wipe(&hostile)
	testing.expect(t, !try_unseal(f.id_a, &hostile, now, "n_c1_foreign"), "a non-owner keyring is refused on first unseal")
	_, stored := bridge_read_vault_keyring()
	testing.expect(t, !stored, "nothing stored")

	// The owner's {1} is accepted; the same keyring again is accepted.
	one := test_keyring_from_hex(TEST_VAULT_KEY_HEX, 1)
	defer vault.keyring_wipe(&one)
	testing.expect(t, try_unseal(f.id_a, &one, now, "n_c1_one"), "owner keyring accepted")
	testing.expect(t, try_unseal(f.id_a, &one, now, "n_c1_one_again"), "identical keyring accepted")

	// (b) Substituting epoch 1's key is refused.
	swapped := test_keyring_from_hex(V2_KEY_2, 1)
	defer vault.keyring_wipe(&swapped)
	testing.expect(t, !try_unseal(f.id_a, &swapped, now, "n_c1_swap"), "key substitution refused")

	// A rotation that keeps history is accepted; rolling back to {1} is then refused.
	two := test_keyring_two_epochs(TEST_VAULT_KEY_HEX, V2_KEY_2)
	defer vault.keyring_wipe(&two)
	testing.expect(t, try_unseal(f.id_a, &two, now, "n_c1_two"), "superset accepted")
	testing.expect(t, !try_unseal(f.id_a, &one, now, "n_c1_rollback"), "rollback refused")
	got, got_ok := bridge_read_vault_keyring()
	defer vault.keyring_wipe(&got)
	testing.expect(t, got_ok && vault.keyring_equal(&got, &two), "the superset stays installed")

	// An enrolled bridge with no recorded owner refuses every unseal.
	_ = keystore_delete_identity_key(f.id_a)
	bridge_unseal_forget_identity()
	keystore_lock_and_purge(f.id_a)
	testing.expect(t, !try_unseal(f.id_a, &one, now, "n_c1_no_owner"), "unknown owner refused")
}

@(test)
test_v2_nonce_cache_records_only_authenticated_and_never_evicts_live :: proc(t: ^testing.T) {
	// Pure cache behaviour on a private cache and a fake clock.
	cache := new(Nonce_Replay_Cache)
	defer free(cache)
	testing.expect_value(t, nonce_cache_insert(cache, "n0", 1_000, 60_000), Nonce_Cache_Result.Inserted)
	testing.expect_value(t, nonce_cache_insert(cache, "n0", 61_000, 60_000), Nonce_Cache_Result.Replay)
	testing.expect_value(t, nonce_cache_insert(cache, "n0", 61_001, 60_000), Nonce_Cache_Result.Inserted)
	for i in 1 ..< UNSEAL_NONCE_CACHE_CAPACITY {
		testing.expect_value(t, nonce_cache_insert(cache, fmt.tprintf("n%d", i), 61_001, 60_000), Nonce_Cache_Result.Inserted)
	}
	// Full of live nonces: refuse, and every recorded nonce is still a replay.
	testing.expect_value(t, nonce_cache_insert(cache, "fresh", 61_002, 60_000), Nonce_Cache_Result.Full)
	testing.expect(t, nonce_cache_seen(cache, "n0", 61_002) && nonce_cache_seen(cache, "n1", 61_002), "no live nonce evicted")
	// Once they expire, slots free up again.
	testing.expect_value(t, nonce_cache_insert(cache, "fresh", 121_002, 60_000), Nonce_Cache_Result.Inserted)

	// End to end: a payload that fails the AEAD does not burn its nonce.
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f := v2_open()
	defer v2_close(&f)
	kr := test_keyring_from_hex(TEST_VAULT_KEY_HEX)
	defer vault.keyring_wipe(&kr)
	now := v2_now()
	bad := test_create_unseal_v2_payload(f.id_a, &kr, now, "n_l1_shared", {tamper_aad = true})
	defer delete(bad)
	bad_ok, _ := bridge_unseal_decrypt_and_verify(bad, f.id_a, now)
	testing.expect(t, !bad_ok, "tampered payload rejected")
	good := test_create_unseal_v2_payload(f.id_a, &kr, now, "n_l1_shared")
	defer delete(good)
	good_ok, msg := bridge_unseal_decrypt_and_verify(good, f.id_a, now)
	testing.expectf(t, good_ok, "genuine payload with the same nonce still accepted: %s", msg)
	again, _ := bridge_unseal_decrypt_and_verify(good, f.id_a, now + 1)
	testing.expect(t, !again, "and now the nonce is consumed")
}

@(test)
test_v2_enc_spec_nonce_replay_rejected :: proc(t: ^testing.T) {
	// Fake clock; a nonce unique to this test so the shared cache cannot collide.
	now: i64 = 1_800_000_000_000
	nonce := "m1_enc_spec_nonce_0123456789abcd"
	testing.expect_value(t, bridge_enc_spec_check_fresh(now, nonce, now), "")
	testing.expect(t, bridge_enc_spec_check_fresh(now, nonce, now + 59_000) != "", "replay inside the window rejected")
	testing.expect(t, bridge_enc_spec_check_fresh(now, "m1_other_nonce_0123456789abcdef", now + 61_000) != "", "stale timestamp rejected")
	testing.expect(t, bridge_enc_spec_check_fresh(now, "", now) != "", "a missing nonce is rejected")
	testing.expect(t, bridge_enc_spec_check_fresh(now, "short", now) != "", "a short nonce is rejected")
}

@(test)
test_v2_enc_spec_binding_rejects_mismatch :: proc(t: ^testing.T) {
	spec, ok := bridge_shell_parse_enc_spec(`{"cmd":"true","cwd":"","timestamp":1,"nonce":"n","bridge_id":"brg_a","session_id":"sh_1","kind":"run","boot_id":"b00t"}`)
	testing.expect(t, ok, "spec parses")
	testing.expect_value(t, bridge_enc_spec_check_binding(spec, "brg_a", "sh_1", "run", "b00t"), "")
	testing.expect(t, bridge_enc_spec_check_binding(spec, "brg_b", "sh_1", "run", "b00t") != "", "other bridge rejected")
	testing.expect(t, bridge_enc_spec_check_binding(spec, "brg_a", "sh_2", "run", "b00t") != "", "other session rejected")
	testing.expect(t, bridge_enc_spec_check_binding(spec, "brg_a", "sh_1", "shell", "b00t") != "", "other kind rejected")
	testing.expect(t, bridge_enc_spec_check_binding(spec, "brg_a", "sh_1", "run", "0ther") != "", "spec from before a restart rejected")
	unbound, _ := bridge_shell_parse_enc_spec(`{"cmd":"true","timestamp":1,"nonce":"n"}`)
	testing.expect(t, bridge_enc_spec_check_binding(unbound, "", "", "", "") != "", "an unbound spec is rejected even against empty values")
}

@(test)
test_v2_fs_read_uses_one_vault_snapshot :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f := v2_open()
	defer v2_close(&f)
	env := test_env_set("HEIMDALL_VAULT_KEYRING", "")
	defer test_env_restore(&env)
	testing.expect(t, test_store_keyring(f.id_a, TEST_VAULT_KEY_HEX))

	sb, sb_ok := bridge_vault_test_sandbox_open(t, "l2_snapshot")
	defer bridge_vault_test_sandbox_close(&sb)
	if !sb_ok do return
	root := bridge_fs_canonicalize_existing(sb.dir)
	defer delete(root)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/secret.txt", root), transmute([]byte)string("l2 secret line")) == nil)

	// The vault locks right after the command's snapshot: the content must still
	// leave encrypted under the snapshot's keyring, never in plaintext.
	// Injected per test thread (bridge_fs_test_vault_hook), not a global swap.
	bridge_fs_test_vault_hook = proc() -> (Vault_Status, vault.Vault_Keyring) {
		status, kr := bridge_vault_status_and_key()
		keystore_lock_and_purge(bridge_config.daemon_id)
		return status, kr
	}
	defer bridge_fs_test_vault_hook = nil
	// read_file's per-file path check rejects Windows temp paths (pre-existing,
	// unrelated to L2), so its half runs on unix; grep covers the same snapshot.
	when ODIN_OS != .Windows {
		res := bridge_fs_read_file("secret.txt", root)
		defer delete(res.content)
		testing.expectf(t, res.ok, "read ok: %s %s %s", res.error_code, res.message, root)
		testing.expect(t, strings.has_prefix(res.content, vault.VAULT_V2_PREFIX), "content encrypted under the snapshot keyring")
		testing.expect(t, !strings.contains(res.content, "l2 secret line"), "no plaintext")
		_ = test_store_keyring(f.id_a, TEST_VAULT_KEY_HEX)
	}
	g := bridge_fs_grep("l2 secret", true, 10, root)
	testing.expect(t, g.ok && len(g.matches) == 1, "grep found the line")
	if len(g.matches) == 1 do testing.expect(t, strings.has_prefix(g.matches[0].line, vault.VAULT_V2_PREFIX), "grep line encrypted")
	bridge_fs_grep_result_delete(&g)
}

@(test)
test_v2_keyring_env_override_is_scrubbed_from_children :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f := v2_open()
	defer v2_close(&f)
	env := test_env_set("HEIMDALL_VAULT_KEYRING", test_keyring_env_value(TEST_VAULT_KEY_HEX))
	defer test_env_restore(&env)
	defer bridge_forget_captured_env_keyring()

	testing.expect(t, bridge_capture_keyring_env_override(), "override captured")
	_, still_set := os.lookup_env("HEIMDALL_VAULT_KEYRING", context.temp_allocator)
	testing.expect(t, !still_set, "no child can inherit HEIMDALL_VAULT_KEYRING")
	kr, ok := bridge_read_vault_keyring()
	defer vault.keyring_wipe(&kr)
	want := test_keyring_from_hex(TEST_VAULT_KEY_HEX)
	defer vault.keyring_wipe(&want)
	testing.expect(t, ok && vault.keyring_equal(&kr, &want), "the bridge still uses the captured keyring")
}

@(test)
test_v2_epoch_floor_survives_lock :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f := v2_open()
	defer v2_close(&f)
	now := v2_now()
	unseal :: proc(id: string, kr: ^vault.Vault_Keyring, now: i64, nonce: string) -> bool {
		payload := test_create_unseal_v2_payload(id, kr, now, nonce)
		defer delete(payload)
		ok, _ := bridge_unseal_decrypt_and_verify(payload, id, now)
		return ok
	}

	two := test_keyring_two_epochs(TEST_VAULT_KEY_HEX, V2_KEY_2)
	defer vault.keyring_wipe(&two)
	testing.expect(t, unseal(f.id_a, &two, now, "n_floor_two"), "{1,2} accepted")

	// A lock deletes the keyring; the floor stays.
	keystore_lock_and_purge(f.id_a)
	one := test_keyring_from_hex(TEST_VAULT_KEY_HEX, 1)
	defer vault.keyring_wipe(&one)
	testing.expect(t, !unseal(f.id_a, &one, now, "n_floor_rollback"), "rollback below the floor refused after a lock")

	// Epoch 2 with a substituted key (wrapped in a newer {2', 3}) is refused.
	sub := test_keyring_from_hex(TEST_ENC_VAULT_KEY, 2)
	defer vault.keyring_wipe(&sub)
	sub.entries[1] = sub.entries[0]
	sub.entries[1].epoch = 3
	sub.count, sub.current_epoch = 2, 3
	testing.expect(t, !unseal(f.id_a, &sub, now, "n_floor_swap"), "substituted key for a known epoch refused after a lock")

	// A keyring of only fresh epochs (a hostile hub's own key at 3) is refused: it
	// lacks the newest accepted epoch 2, whose key the hub never held.
	fresh := test_keyring_from_hex(TEST_ENC_VAULT_KEY, 3)
	defer vault.keyring_wipe(&fresh)
	testing.expect(t, !unseal(f.id_a, &fresh, now, "n_floor_fresh_only"), "keyring without the newest accepted epoch refused after a lock")

	// A genuine rotation {1,2,3} is accepted and raises the floor.
	three := two
	defer vault.keyring_wipe(&three)
	three.entries[2] = Keyring_Entry_For_Test(3, 0x33)
	three.count, three.current_epoch = 3, 3
	testing.expect(t, unseal(f.id_a, &three, now, "n_floor_three"), "rotation accepted")
	floor, st := keystore_read_epoch_floor(f.id_a)
	testing.expect(t, st == .Found && floor.floor_epoch == 3 && floor.count == 3, "floor raised to 3 with three commitments")

	// Unreadable or missing floor: refuse.
	keystore_lock_and_purge(f.id_a)
	testing.expect_value(t, keystore_backend_write(.Epoch_Floor, f.id_a, transmute([]byte)string("junk")), 0)
	testing.expect(t, !unseal(f.id_a, &three, now, "n_floor_junk"), "unreadable floor refuses")
	testing.expect(t, keystore_delete_epoch_floor(f.id_a))
	testing.expect(t, !unseal(f.id_a, &three, now, "n_floor_missing"), "missing floor refuses")
}

@(private = "file")
Keyring_Entry_For_Test :: proc(epoch: u32, fill: byte) -> vault.Keyring_Entry {
	e := vault.Keyring_Entry{epoch = epoch}
	for &b in e.key do b = fill
	return e
}

@(test)
test_v2_epoch_floor_merge_keeps_newest :: proc(t: ^testing.T) {
	f: Epoch_Floor
	kr: vault.Vault_Keyring
	defer vault.keyring_wipe(&kr)
	copy(kr.user_id_buf[:], "usr_x")
	kr.user_id_len = 5
	for i in 0 ..< vault.KEYRING_MAX_EPOCHS {
		kr.entries[i] = Keyring_Entry_For_Test(u32(i + 1), byte(i))
	}
	kr.count, kr.current_epoch = vault.KEYRING_MAX_EPOCHS, vault.KEYRING_MAX_EPOCHS
	epoch_floor_merge(&f, "brg_x", &kr)
	// A later keyring that dropped epoch 1 and added 65.
	for i in 0 ..< vault.KEYRING_MAX_EPOCHS {
		kr.entries[i] = Keyring_Entry_For_Test(u32(i + 2), byte(i + 1))
	}
	kr.current_epoch = vault.KEYRING_MAX_EPOCHS + 1
	testing.expect_value(t, epoch_floor_check(&f, "brg_x", &kr), Epoch_Floor_Error.None)
	epoch_floor_merge(&f, "brg_x", &kr)
	testing.expect(t, f.count == EPOCH_FLOOR_MAX_ENTRIES && f.entries[0].epoch == 2 && f.floor_epoch == vault.KEYRING_MAX_EPOCHS + 1)
	buf: [EPOCH_FLOOR_MAX_BYTES]byte
	out, ok := epoch_floor_serialize(&f, buf[:])
	back, back_ok := epoch_floor_parse(out)
	testing.expect(t, ok && back_ok && back == f, "floor round-trips")
	kr.entries[5].key[0] ~= 1
	testing.expect_value(t, epoch_floor_check(&f, "brg_x", &kr), Epoch_Floor_Error.Key_Mismatch)
}

@(test)
test_v2_unseal_requires_chain_to_pinned_root :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f := v2_open()
	defer v2_close(&f)
	now := v2_now()
	unseal :: proc(id: string, kr: ^vault.Vault_Keyring, now: i64, nonce: string, opts: Test_Unseal_Options = {}) -> (bool, string) {
		payload := test_create_unseal_v2_payload(id, kr, now, nonce, opts)
		defer delete(payload)
		return bridge_unseal_decrypt_and_verify(payload, id, now)
	}
	one := test_keyring_from_hex(TEST_VAULT_KEY_HEX, 1)
	defer vault.keyring_wipe(&one)

	// No proof, or a proof that does not chain: refused, nothing pinned.
	ok, _ := unseal(f.id_a, &one, now, "n_chain_none", {proof_override = `{"v":1}`})
	testing.expect(t, !ok, "a keyring without a chain proof is refused")
	floor0, _ := keystore_read_epoch_floor(f.id_a)
	testing.expect(t, !floor0.root.set, "nothing pinned by a refused unseal")

	// Hub-blind pairing: a valid proof is not enough for the FIRST unseal — it also
	// needs the approver's pair_mac under this bridge's pairing code. A hub racing the
	// approver (no code) gets nothing pinned.
	msg0: string
	ok, msg0 = unseal(f.id_a, &one, now, "n_pair_none", {no_pair_mac = true})
	testing.expectf(t, !ok && strings.contains(msg0, "pairing"), "first unseal without a pair_mac refused: %s", msg0)
	ok, _ = unseal(f.id_a, &one, now, "n_pair_forged", {pair_mac_override = strings.repeat("ab", 32, context.temp_allocator)})
	testing.expect(t, !ok, "first unseal with a forged pair_mac refused")
	ok, _ = unseal(f.id_a, &one, now, "n_pair_other_root", {root_scalar = TEST_ACCOUNT_ROOT_OTHER, pair_mac_override = test_pair_mac(test_chain_proof(f.id_a, &one))})
	testing.expect(t, !ok, "a pair_mac for the real root does not let a hub-substituted root pin")
	floor1, _ := keystore_read_epoch_floor(f.id_a)
	testing.expect(t, !floor1.root.set, "nothing pinned without a valid pair_mac")

	// First verified unseal (with the approver's pair_mac) pins the root.
	ok, _ = unseal(f.id_a, &one, now, "n_chain_first")
	testing.expect(t, ok, "first unseal with a valid proof accepted")
	testing.expect(t, bridge_account_fingerprint(f.id_a) != "", "account root pinned")

	// A different account root (a hostile hub's own genesis) is refused from now on,
	// also after a lock purged the keyring.
	msg: string
	ok, msg = unseal(f.id_a, &one, now, "n_chain_other", {root_scalar = TEST_ACCOUNT_ROOT_OTHER})
	testing.expectf(t, !ok && strings.contains(msg, "root"), "other root refused: %s", msg)
	keystore_lock_and_purge(f.id_a)
	ok, _ = unseal(f.id_a, &one, now, "n_chain_other_locked", {root_scalar = TEST_ACCOUNT_ROOT_OTHER})
	testing.expect(t, !ok, "pin survives a lock")
	two := test_keyring_two_epochs(TEST_VAULT_KEY_HEX, V2_KEY_2)
	defer vault.keyring_wipe(&two)
	ok, msg = unseal(f.id_a, &two, now, "n_chain_two")
	testing.expectf(t, ok, "rotation under the pinned root accepted: %s", msg)
}
