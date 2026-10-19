package main

// Passwordless vault P1 â€” bridge-side security tests (compact by design; the
// format-level vectors and negatives live in src/lib/vault/vault_test.odin).
// None of these spawn a shell, so they run on Windows too:
//   odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_NAMES=main.test_v2_...

import "core:crypto/ecdsa"
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

	// Identity: persisted under the bridge id, survives lock, removed by delete.
	scalar: [32]byte
	scalar[31] = 7
	testing.expect(t, keystore_store_identity_key(f.id_a, scalar[:]))
	keystore_lock_and_purge(f.id_a)
	got: [32]byte
	testing.expect(t, keystore_read_identity_key(f.id_a, got[:]) && got == scalar, "lock keeps the identity key")
	testing.expect(t, keystore_delete_identity_key(f.id_a))
	testing.expect(t, !keystore_read_identity_key(f.id_a, got[:]), "identity deleted")
}

@(test)
test_v2_unseal_accepts_signed_payload_and_rejects_negatives :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f := v2_open()
	defer v2_close(&f)

	// Nothing is advertised or accepted before the identity exists; once asked for,
	// it is created and persisted.
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
	_, _, _, wrong_dir := vault.pty_open(frame, &kr, "sh_v2", .In, 2, context.temp_allocator)
	testing.expect(t, !wrong_dir, "an output frame is not valid input")
	_, _, _, right := vault.pty_open(frame, &kr, "sh_v2", .Out, 2, context.temp_allocator)
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
	kr := test_keyring_two_epochs(TEST_VAULT_KEY_HEX, V2_KEY_2)
	defer vault.keyring_wipe(&kr)
	sid := "sh_replay_test"
	salt_a: [vault.PTY_V2_SALT_BYTES]byte
	salt_a[0] = 0xa1
	f1, _ := test_pty_input_payload_with("a", V2_KEY_2, 2, sid, salt_a, 1000)
	f2, _ := test_pty_input_payload_with("b", V2_KEY_2, 2, sid, salt_a, 1001)
	p1, ok1 := bridge_pty_open_input(f1, &kr, sid)
	testing.expect(t, ok1 && p1 == "a")
	_, replay := bridge_pty_open_input(f1, &kr, sid)
	testing.expect(t, !replay, "the same frame twice is a replay")
	_, ok2 := bridge_pty_open_input(f2, &kr, sid)
	testing.expect(t, ok2)
	_, stale := bridge_pty_open_input(f1, &kr, sid)
	testing.expect(t, !stale, "an older counter under the same salt is refused")
	// Another session id: the AAD and subkey differ, so the frame does not authenticate.
	_, cross := bridge_pty_open_input(f2, &kr, "sh_replay_other")
	testing.expect(t, !cross)
	// A new stream (new salt) may start its own sequence.
	salt_b: [vault.PTY_V2_SALT_BYTES]byte
	salt_b[0] = 0xb2
	f3, _ := test_pty_input_payload_with("c", V2_KEY_2, 2, sid, salt_b, 5000)
	_, ok3 := bridge_pty_open_input(f3, &kr, sid)
	testing.expect(t, ok3)
	// Non-current epoch input is refused (command epoch floor).
	f4, _ := test_pty_input_payload_with("d", TEST_VAULT_KEY_HEX, 1, sid, salt_b, 5001)
	_, old_epoch := bridge_pty_open_input(f4, &kr, sid)
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
	testing.expect(t, strings.has_prefix(output, "vault:v2:e1:"), output)
	epoch, body, pres := vault.envelope_parse(output, context.temp_allocator)
	testing.expect(t, pres == .Ok && epoch == 1)
	frame := make([]byte, 4 + len(body), context.temp_allocator)
	frame[3] = 1
	copy(frame[4:], body)
	plain, _, _, ok := vault.pty_open(frame, &kr, "sh_pane", .Out, 0, context.temp_allocator)
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
	// Never configured: the capture goes out as is.
	plain_out, dres := bridge_pane_output_seal_with(.Disabled, nil, "plain screen", "sh_pane", os_random.DEFAULT_SOURCE)
	defer delete(plain_out)
	testing.expect(t, dres == .Plain && plain_out == "plain screen")
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
	disabled := bridge_pane_capture_result_sealed_json(pending, .Disabled, nil, "plain pane", 1, false, os_random.DEFAULT_SOURCE)
	defer delete(disabled)
	testing.expect(t, strings.contains(disabled, `"output":"plain pane"`), disabled)

	// An oversized capture keeps its tail from a line start, fits the hub cap, is marked truncated.
	big := strings.concatenate({strings.repeat("x", BRIDGE_PANE_CAPTURE_SEAL_MAX_PLAIN, context.temp_allocator), "\nlast line"}, context.temp_allocator)
	tok, bres, cut := bridge_pane_capture_seal_with(.Unlocked, &kr, big, os_random.DEFAULT_SOURCE)
	defer delete(tok)
	testing.expect(t, bres == .Sealed && cut && len(tok) <= 48000)
	tail, _ := vault.open(tok, &kr, context.temp_allocator)
	testing.expect_value(t, tail, "last line")
}
