package main

import "core:crypto"
import "core:crypto/aes"
import "core:crypto/ecdh"
import "core:crypto/hkdf"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// Package-visible so other suites (vault_configured_marker_test.odin) can drive
// the real hub `bridge_unseal` frame instead of duplicating the sealing code.
test_create_unseal_envelope :: proc(
	bridge_id: string,
	bridge_pub_hex: string,
	vault_key_hex: string,
	timestamp: i64,
	nonce: string,
	tamper_aad: bool = false,
) -> string {
	client_priv: ecdh.Private_Key
	_ = ecdh.private_key_generate(&client_priv, .SECP256R1)
	defer ecdh.private_key_clear(&client_priv)

	client_pub: ecdh.Public_Key
	ecdh.public_key_set_priv(&client_pub, &client_priv)
	client_pub_bytes: [P256_POINT_SIZE]byte
	ecdh.public_key_bytes(&client_pub, client_pub_bytes[:])
	client_pub_hex_bytes, _ := hex.encode(client_pub_bytes[:], context.temp_allocator)
	client_pub_hex := string(client_pub_hex_bytes)

	bridge_pub_bytes, _ := hex.decode(transmute([]byte)bridge_pub_hex, context.temp_allocator)
	bridge_pub: ecdh.Public_Key
	_ = ecdh.public_key_set_bytes(&bridge_pub, .SECP256R1, bridge_pub_bytes)

	shared_secret: [P256_COORD_SIZE]byte
	_ = ecdh.ecdh(&client_priv, &bridge_pub, shared_secret[:])
	defer crypto.zero_explicit(&shared_secret, size_of(shared_secret))

	salt: [32]byte
	info := "heimdall-bridge-unseal-v1"
	aes_key: [32]byte
	defer crypto.zero_explicit(&aes_key, size_of(aes_key))
	hkdf.extract_and_expand(.SHA256, salt[:], shared_secret[:], transmute([]byte)info, aes_key[:])

	iv: [12]byte
	crypto.rand_bytes(iv[:])
	iv_hex_bytes, _ := hex.encode(iv[:], context.temp_allocator)

	aad := fmt.tprintf("%s:%d:%s", bridge_id, timestamp, nonce)
	if tamper_aad {
		aad = fmt.tprintf("%s:%d:%s_tampered", bridge_id, timestamp, nonce)
	}

	plaintext := transmute([]byte)vault_key_hex
	ciphertext := make([]byte, len(plaintext), context.temp_allocator)
	tag: [16]byte

	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, aes_key[:])
	defer aes.reset_gcm(&gcm)
	aes.seal_gcm(&gcm, ciphertext, tag[:], iv[:], transmute([]byte)aad, plaintext)

	ct_hex_bytes, _ := hex.encode(ciphertext, context.temp_allocator)
	tag_hex_bytes, _ := hex.encode(tag[:], context.temp_allocator)

	return fmt.aprintf(
		`{{"type":"bridge_unseal","command_id":"cmd_test","bridge_id":"%s","timestamp":%d,"nonce":"%s","client_public_key":"%s","iv":"%s","tag":"%s","ciphertext":"%s"}}`,
		bridge_id, timestamp, nonce, client_pub_hex, string(iv_hex_bytes), string(tag_hex_bytes), string(ct_hex_bytes),
	)
}

@(test)
test_unseal_protocol_success_and_unlock :: proc(t: ^testing.T) {
	// HEIMDALL_VAULT_KEY is a PROCESS-GLOBAL. keystore_test_mutex alone does not
	// serialise this test against the ~29 env-mutating tests that hold
	// bridge_test_config_mutex instead - two disjoint locks exclude nobody, so those
	// two sets raced on one shared value (iss_18db48473fc5cb6d, 2026-10-04).
	// Taken OUTERMOST, before keystore_test_mutex: the acquisition graph stays acyclic.
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	defer bridge_vault_lock()

	os.unset_env("HEIMDALL_VAULT_KEY")
	defer os.unset_env("HEIMDALL_VAULT_KEY")

	bridge_vault_lock()
	unseal_nonce_cache_clear(&g_unseal_nonce_cache)
	bridge_unseal_init()

	bridge_id := "brg_local_test"
	bridge_pub_hex := bridge_get_public_key_hex()
	test_key := "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"
	now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000

	payload := test_create_unseal_envelope(bridge_id, bridge_pub_hex, test_key, now_ms, "nonce_success_01")
	defer delete(payload)

	ok, err_msg := bridge_unseal_decrypt_and_verify(payload, bridge_id, now_ms)
	testing.expect(t, ok, fmt.tprintf("unseal must succeed: %s", err_msg))

	// Verify that the vault key was stored and bridge is unlocked
	stored_key, read_ok := bridge_read_vault_key()
	testing.expect(t, read_ok, "bridge_read_vault_key must succeed after unseal")
	defer delete(stored_key)
	testing.expect_value(t, stored_key, test_key)

	cfg, perm, keylen := bridge_vault_key_status()
	testing.expect(t, cfg, "vault must be configured")
	testing.expect(t, perm, "permissions must be valid")
	testing.expect_value(t, keylen, 64)
}

@(test)
test_unseal_protocol_anti_replay_rejection :: proc(t: ^testing.T) {
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	defer bridge_vault_lock()

	bridge_vault_lock()
	unseal_nonce_cache_clear(&g_unseal_nonce_cache)
	bridge_unseal_init()

	bridge_id := "brg_local_test"
	bridge_pub_hex := bridge_get_public_key_hex()
	test_key := "11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff"
	now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000

	payload := test_create_unseal_envelope(bridge_id, bridge_pub_hex, test_key, now_ms, "replay_nonce_123")
	defer delete(payload)

	// First attempt succeeds
	ok1, err1 := bridge_unseal_decrypt_and_verify(payload, bridge_id, now_ms)
	testing.expect(t, ok1, fmt.tprintf("first unseal must succeed: %s", err1))

	// Second attempt with exact same payload/nonce MUST be rejected as replay
	ok2, err2 := bridge_unseal_decrypt_and_verify(payload, bridge_id, now_ms + 100)
	testing.expect(t, !ok2, "replayed unseal payload must be rejected")
	testing.expect(t, strings.contains(err2, "replay rejected"), "error must cite replay rejection")
}

@(test)
test_unseal_protocol_clock_skew_expiration :: proc(t: ^testing.T) {
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	defer bridge_vault_lock()

	bridge_vault_lock()
	unseal_nonce_cache_clear(&g_unseal_nonce_cache)
	bridge_unseal_init()

	bridge_id := "brg_local_test"
	bridge_pub_hex := bridge_get_public_key_hex()
	test_key := "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
	now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000

	// 1. Expired in past (> 30s)
	past_ts := now_ms - 35_000
	payload_past := test_create_unseal_envelope(bridge_id, bridge_pub_hex, test_key, past_ts, "skew_past_nonce")
	defer delete(payload_past)
	ok_past, err_past := bridge_unseal_decrypt_and_verify(payload_past, bridge_id, now_ms)
	testing.expect(t, !ok_past, "past clock skew > 30s must be rejected")
	testing.expect(t, strings.contains(err_past, "clock skew"), "error must cite clock skew")

	// 2. Future skew (> 30s)
	future_ts := now_ms + 35_000
	payload_future := test_create_unseal_envelope(bridge_id, bridge_pub_hex, test_key, future_ts, "skew_future_nonce")
	defer delete(payload_future)
	ok_future, err_future := bridge_unseal_decrypt_and_verify(payload_future, bridge_id, now_ms)
	testing.expect(t, !ok_future, "future clock skew > 30s must be rejected")
	testing.expect(t, strings.contains(err_future, "clock skew"), "error must cite clock skew")

	// 3. Valid within 30s window (e.g. 15s in past)
	valid_ts := now_ms - 15_000
	payload_valid := test_create_unseal_envelope(bridge_id, bridge_pub_hex, test_key, valid_ts, "skew_valid_nonce")
	defer delete(payload_valid)
	ok_valid, err_valid := bridge_unseal_decrypt_and_verify(payload_valid, bridge_id, now_ms)
	testing.expect(t, ok_valid, fmt.tprintf("timestamp within 30s must be accepted: %s", err_valid))
}

@(test)
test_unseal_protocol_tamper_rejection :: proc(t: ^testing.T) {
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	defer bridge_vault_lock()

	bridge_vault_lock()
	unseal_nonce_cache_clear(&g_unseal_nonce_cache)
	bridge_unseal_init()

	bridge_id := "brg_local_test"
	bridge_pub_hex := bridge_get_public_key_hex()
	test_key := "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
	now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000

	// 1. AAD mismatch (tampering with AAD during encryption)
	payload_aad_tamper := test_create_unseal_envelope(bridge_id, bridge_pub_hex, test_key, now_ms, "tamper_aad_01", true)
	defer delete(payload_aad_tamper)
	ok_aad, err_aad := bridge_unseal_decrypt_and_verify(payload_aad_tamper, bridge_id, now_ms)
	testing.expect(t, !ok_aad, "AAD tampering must cause AEAD verification failure")
	testing.expect(t, strings.contains(err_aad, "AEAD tag verification failed"), "must cite AEAD tag verification failure")

	// 2. Tampered ciphertext
	payload_valid := test_create_unseal_envelope(bridge_id, bridge_pub_hex, test_key, now_ms, "tamper_ct_01")
	defer delete(payload_valid)
	// Mutate ciphertext character
	tampered_ct, _ := strings.replace(payload_valid, `"ciphertext":"`, `"ciphertext":"ffff`, 1)
	defer delete(tampered_ct)
	ok_ct, err_ct := bridge_unseal_decrypt_and_verify(tampered_ct, bridge_id, now_ms)
	testing.expect(t, !ok_ct, "ciphertext tampering must cause AEAD verification failure")
	testing.expect(t, strings.contains(err_ct, "AEAD tag verification failed"), "must cite AEAD tag failure")

	// 3. Tampered tag (flip first hex character of tag, keeping 32-hex length intact)
	payload_tag_valid := test_create_unseal_envelope(bridge_id, bridge_pub_hex, test_key, now_ms, "tamper_tag_01")
	defer delete(payload_tag_valid)
	tampered_tag_bytes := transmute([]byte)strings.clone(payload_tag_valid)
	defer delete(tampered_tag_bytes)
	tag_idx := strings.index(payload_tag_valid, `"tag":"`)
	if tag_idx != -1 {
		char_idx := tag_idx + len(`"tag":"`)
		if tampered_tag_bytes[char_idx] == 'a' {
			tampered_tag_bytes[char_idx] = 'b'
		} else {
			tampered_tag_bytes[char_idx] = 'a'
		}
	}
	tampered_tag := string(tampered_tag_bytes)
	ok_tag, err_tag := bridge_unseal_decrypt_and_verify(tampered_tag, bridge_id, now_ms)
	testing.expect(t, !ok_tag, "tag tampering must cause AEAD verification failure")
	testing.expect(t, strings.contains(err_tag, "AEAD tag verification failed"), fmt.tprintf("must cite AEAD tag failure: got %s", err_tag))
}

@(test)
test_unseal_protocol_cross_bridge_target_rejection :: proc(t: ^testing.T) {
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	defer bridge_vault_lock()

	bridge_vault_lock()
	unseal_nonce_cache_clear(&g_unseal_nonce_cache)
	bridge_unseal_init()

	bridge_pub_hex := bridge_get_public_key_hex()
	test_key := "99887766554433221100ffeeddccbbaa99887766554433221100ffeeddccbbaa"
	now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000

	// Payload targeted to bridge_A
	payload_a := test_create_unseal_envelope("brg_alpha", bridge_pub_hex, test_key, now_ms, "cross_bridge_nonce")
	defer delete(payload_a)

	// Submitting payload targeting "brg_alpha" at "brg_beta" MUST fail
	ok, err := bridge_unseal_decrypt_and_verify(payload_a, "brg_beta", now_ms)
	testing.expect(t, !ok, "payload targeting bridge A sent to bridge B must be rejected")
	testing.expect(t, strings.contains(err, "cross-bridge replay rejected"), "error must cite cross-bridge target mismatch")
}

@(test)
test_unseal_protocol_sliding_nonce_cache :: proc(t: ^testing.T) {
	cache: Unseal_Nonce_Cache
	unseal_nonce_cache_clear(&cache)

	now: i64 = 1_000_000

	// Insert nonce 1
	testing.expect(t, unseal_nonce_cache_check_and_insert(&cache, "nonce_1", now), "first insert of nonce_1 must succeed")
	// Replay nonce 1
	testing.expect(t, !unseal_nonce_cache_check_and_insert(&cache, "nonce_1", now + 1000), "replay of nonce_1 must fail")

	// Insert nonce 2
	testing.expect(t, unseal_nonce_cache_check_and_insert(&cache, "nonce_2", now + 2000), "insert of nonce_2 must succeed")

	// Nonce 1 after TTL (> 60s) can be re-inserted because old entry expired
	testing.expect(t, unseal_nonce_cache_check_and_insert(&cache, "nonce_1", now + UNSEAL_NONCE_TTL_MS + 1000), "nonce_1 after TTL expiry should succeed")

	unseal_nonce_cache_clear(&cache)
}
