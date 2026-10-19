package main

// Passwordless vault P1 — bridge-side security tests (compact by design; the
// format-level vectors and negatives live in src/lib/vault/vault_test.odin).
// None of these spawn a shell, so they run on Windows too:
//   odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_NAMES=main.test_v2_...

import "core:crypto/ecdsa"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
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
	prev := bridge_pty_random_source
	bridge_pty_random_source = "/nonexistent/heimdall-no-random"
	defer bridge_pty_random_source = prev
	w3: Bridge_PTY_Stream_Worker
	_, _, ok_fail := _bridge_pty_stream_next_nonce(&w3, 2)
	testing.expect(t, !ok_fail, "CSPRNG failure must fail closed")

	// A sealed frame carries its epoch and only opens for its session/direction.
	kr := test_keyring_two_epochs(TEST_VAULT_KEY_HEX, V2_KEY_2)
	defer vault.keyring_wipe(&kr)
	frame, sealed := bridge_pty_stream_seal_v2(transmute([]byte)string("hi"), &kr, 2, s1, 1, "sh_v2", context.temp_allocator)
	testing.expect(t, sealed)
	ep, _ := vault.pty_frame_epoch(frame)
	testing.expect_value(t, ep, u32(2))
	_, wrong_dir := vault.pty_open(frame, &kr, "sh_v2", .In, 2, context.temp_allocator)
	testing.expect(t, !wrong_dir, "an output frame is not valid input")
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
