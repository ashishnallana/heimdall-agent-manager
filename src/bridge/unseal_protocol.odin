package main

import "core:crypto"
import "core:crypto/aes"
import "core:crypto/ecdh"
import "core:crypto/hkdf"
import base64 "core:encoding/base64"
import "core:encoding/hex"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:time"
import jsonx "odin_test:lib/jsonx"

// ── Ephemeral ECDH & Anti-Replay Unseal Protocol (REQ-VAULT-HARDEN-3, REQ-VAULT-HARDEN-8) ──

UNSEAL_NONCE_TTL_MS :: 60_000
UNSEAL_CLOCK_SKEW_MAX_MS :: 30_000
UNSEAL_NONCE_CACHE_CAPACITY :: 512
P256_POINT_SIZE :: 65
P256_COORD_SIZE :: 32
P256_UNCOMPRESSED_PREFIX :: 0x04

g_bridge_ecdh_priv: ecdh.Private_Key
g_bridge_ecdh_pub: ecdh.Public_Key
g_bridge_ecdh_pub_bytes: [P256_POINT_SIZE]byte
g_bridge_ecdh_pub_hex_buf: [P256_POINT_SIZE * 2]byte
g_bridge_ecdh_initialized: bool
g_bridge_ecdh_mu: sync.Mutex

@(private = "file")
HEX_LOWER := "0123456789abcdef"

// Initializes the ephemeral ECDH keypair (SK_bridge, PK_bridge) for this bridge instance.
bridge_unseal_init :: proc() {
	sync.mutex_lock(&g_bridge_ecdh_mu)
	defer sync.mutex_unlock(&g_bridge_ecdh_mu)
	if g_bridge_ecdh_initialized do return

	if !ecdh.private_key_generate(&g_bridge_ecdh_priv, .SECP256R1) {
		fmt.eprintln("ERROR: failed to generate ephemeral bridge ECDH private key")
		return
	}
	ecdh.public_key_set_priv(&g_bridge_ecdh_pub, &g_bridge_ecdh_priv)
	ecdh.public_key_bytes(&g_bridge_ecdh_pub, g_bridge_ecdh_pub_bytes[:])

	for i in 0 ..< P256_POINT_SIZE {
		b := g_bridge_ecdh_pub_bytes[i]
		g_bridge_ecdh_pub_hex_buf[i * 2] = HEX_LOWER[b >> 4]
		g_bridge_ecdh_pub_hex_buf[i * 2 + 1] = HEX_LOWER[b & 0x0f]
	}
	g_bridge_ecdh_initialized = true
}

// Returns the bridge's ephemeral public key advertised in bridge registration metadata.
bridge_get_public_key_hex :: proc() -> string {
	if !g_bridge_ecdh_initialized {
		bridge_unseal_init()
	}
	return string(g_bridge_ecdh_pub_hex_buf[:])
}

// Resets the ephemeral key state (primarily for isolated test assertions).
bridge_unseal_reset_for_test :: proc() {
	sync.mutex_lock(&g_bridge_ecdh_mu)
	defer sync.mutex_unlock(&g_bridge_ecdh_mu)
	if g_bridge_ecdh_initialized {
		ecdh.private_key_clear(&g_bridge_ecdh_priv)
		mem.zero_explicit(&g_bridge_ecdh_pub_hex_buf, size_of(g_bridge_ecdh_pub_hex_buf))
		g_bridge_ecdh_initialized = false
	}
}

// ── Sliding Nonce Deduplication Cache (60s TTL Ring Buffer) ──────────────────

Unseal_Nonce_Entry :: struct {
	nonce_buf: [64]byte,
	nonce_len: int,
	timestamp_ms: i64,
}

Unseal_Nonce_Cache :: struct {
	entries: [UNSEAL_NONCE_CACHE_CAPACITY]Unseal_Nonce_Entry,
	head: int,
	count: int,
	mu: sync.Mutex,
}

g_unseal_nonce_cache: Unseal_Nonce_Cache
g_enrollment_unseal_mu: sync.Mutex
g_enrollment_unseal_received: bool

// Enrollment uses the normal Hub runtime relay, but exits after the key has
// crossed into the secure keystore. These helpers let the enrollment thread
// wait for that concrete event without treating an older keyring entry as proof
// that this approval delivered anything.
bridge_enrollment_unseal_reset :: proc() {
	sync.mutex_lock(&g_enrollment_unseal_mu)
	g_enrollment_unseal_received = false
	sync.mutex_unlock(&g_enrollment_unseal_mu)
}

bridge_enrollment_unseal_mark_received :: proc() {
	sync.mutex_lock(&g_enrollment_unseal_mu)
	g_enrollment_unseal_received = true
	sync.mutex_unlock(&g_enrollment_unseal_mu)
}

bridge_enrollment_unseal_was_received :: proc() -> bool {
	sync.mutex_lock(&g_enrollment_unseal_mu)
	defer sync.mutex_unlock(&g_enrollment_unseal_mu)
	return g_enrollment_unseal_received
}

unseal_nonce_cache_check_and_insert :: proc(cache: ^Unseal_Nonce_Cache, nonce: string, now_ms: i64) -> bool {
	if nonce == "" do return false
	sync.mutex_lock(&cache.mu)
	defer sync.mutex_unlock(&cache.mu)

	// Check if nonce is currently active in the cache within 60s TTL
	for i in 0 ..< cache.count {
		entry := &cache.entries[i]
		if entry.nonce_len == len(nonce) && (now_ms - entry.timestamp_ms) <= UNSEAL_NONCE_TTL_MS {
			if string(entry.nonce_buf[:entry.nonce_len]) == nonce {
				return false // Replay detected!
			}
		}
	}

	// Insert at head (ring buffer) without dynamic allocation
	entry := &cache.entries[cache.head]
	n_len := min(len(nonce), len(entry.nonce_buf))
	mem.copy(raw_data(entry.nonce_buf[:]), raw_data(nonce), n_len)
	entry.nonce_len = n_len
	entry.timestamp_ms = now_ms

	cache.head = (cache.head + 1) % UNSEAL_NONCE_CACHE_CAPACITY
	if cache.count < UNSEAL_NONCE_CACHE_CAPACITY {
		cache.count += 1
	}
	return true
}

unseal_nonce_cache_clear :: proc(cache: ^Unseal_Nonce_Cache) {
	sync.mutex_lock(&cache.mu)
	defer sync.mutex_unlock(&cache.mu)
	for i in 0 ..< UNSEAL_NONCE_CACHE_CAPACITY {
		cache.entries[i].nonce_len = 0
		cache.entries[i].timestamp_ms = 0
	}
	cache.head = 0
	cache.count = 0
}

// ── Decoding and Decryption Utilities ────────────────────────────────────────

decode_bytes_flexible :: proc(str: string, allocator := context.temp_allocator) -> ([]byte, bool) {
	trimmed := strings.trim_space(str)
	if len(trimmed) == 0 do return nil, false

	// If valid hex string of even length
	if len(trimmed) % 2 == 0 {
		all_hex := true
		for b in transmute([]byte)trimmed {
			switch b {
			case '0'..='9', 'a'..='f', 'A'..='F':
			case: all_hex = false; break
			}
		}
		if all_hex {
			if out, hex_ok := hex.decode(transmute([]byte)trimmed, allocator); hex_ok {
				return out, true
			}
		}
	}

	// Try standard base64 decoding
	if out, err := base64.decode(trimmed, allocator = allocator); err == nil {
		return out, true
	}
	return nil, false
}

// Decrypts unseal payload, verifies AAD, enforces anti-replay, and stores key material.
bridge_unseal_decrypt_and_verify :: proc(
	payload_json: string,
	local_bridge_id: string,
	current_clock_ms: i64,
) -> (ok: bool, err_msg: string) {
	if !g_bridge_ecdh_initialized {
		bridge_unseal_init()
	}

	bridge_id := jsonx.extract_string(payload_json, "bridge_id", "", false, context.temp_allocator)
	nonce := jsonx.extract_string(payload_json, "nonce", "", false, context.temp_allocator)
	client_pub_str := jsonx.extract_string(payload_json, "client_public_key", "", false, context.temp_allocator)
	iv_str := jsonx.extract_string(payload_json, "iv", "", false, context.temp_allocator)
	tag_str := jsonx.extract_string(payload_json, "tag", "", false, context.temp_allocator)
	ciphertext_str := jsonx.extract_string(payload_json, "ciphertext", "", false, context.temp_allocator)

	timestamp_int, ts_ok := jsonx.extract_int_found(payload_json, "timestamp")
	if !ts_ok {
		return false, "missing timestamp in unseal payload"
	}
	timestamp := i64(timestamp_int)

	if bridge_id == "" || nonce == "" || client_pub_str == "" || iv_str == "" || ciphertext_str == "" {
		return false, "missing required unseal parameters"
	}

	// a) Check timestamp within 30,000ms of current bridge clock
	skew := current_clock_ms - timestamp
	if skew < -UNSEAL_CLOCK_SKEW_MAX_MS || skew > UNSEAL_CLOCK_SKEW_MAX_MS {
		return false, "clock skew expired or out of window"
	}

	// b) Check nonce has not been seen; insert nonce into cache
	if !unseal_nonce_cache_check_and_insert(&g_unseal_nonce_cache, nonce, current_clock_ms) {
		return false, "replay rejected: nonce already used"
	}

	// c) Check payload.bridge_id matches local bridge_id
	if bridge_id != local_bridge_id {
		return false, "cross-bridge replay rejected: target bridge_id mismatch"
	}

	// d) Parse client public key
	client_pub_bytes, pub_ok := decode_bytes_flexible(client_pub_str, context.temp_allocator)
	if !pub_ok || len(client_pub_bytes) != P256_POINT_SIZE || client_pub_bytes[0] != P256_UNCOMPRESSED_PREFIX {
		return false, "invalid client public key point"
	}

	client_pub: ecdh.Public_Key
	if !ecdh.public_key_set_bytes(&client_pub, .SECP256R1, client_pub_bytes) {
		return false, "invalid client public key curve point"
	}

	// Compute shared secret via ECDH(SK_bridge, PK_client)
	shared_secret: [P256_COORD_SIZE]byte
	defer crypto.zero_explicit(&shared_secret, size_of(shared_secret))
	if !ecdh.ecdh(&g_bridge_ecdh_priv, &client_pub, shared_secret[:]) {
		return false, "ECDH key agreement failed"
	}

	// Compute AES-256 key via HKDF (RFC 5869)
	salt: [32]byte
	info := "heimdall-bridge-unseal-v1"
	aes_key: [32]byte
	defer crypto.zero_explicit(&aes_key, size_of(aes_key))
	hkdf.extract_and_expand(.SHA256, salt[:], shared_secret[:], transmute([]byte)info, aes_key[:])

	// e) Parse IV, Tag, and Ciphertext
	iv_bytes, iv_ok := decode_bytes_flexible(iv_str, context.temp_allocator)
	if !iv_ok || len(iv_bytes) != 12 {
		return false, "invalid IV length (expected 12 bytes)"
	}

	ciphertext_bytes, ct_ok := decode_bytes_flexible(ciphertext_str, context.temp_allocator)
	if !ct_ok || len(ciphertext_bytes) == 0 {
		return false, "invalid ciphertext"
	}

	tag_bytes: []byte
	ct_data := ciphertext_bytes
	if tag_str != "" {
		t_bytes, t_ok := decode_bytes_flexible(tag_str, context.temp_allocator)
		if !t_ok || len(t_bytes) != 16 {
			return false, "invalid authentication tag length (expected 16 bytes)"
		}
		tag_bytes = t_bytes
	} else {
		if len(ciphertext_bytes) < 16 {
			return false, "ciphertext too short to contain authentication tag"
		}
		ct_data = ciphertext_bytes[:len(ciphertext_bytes) - 16]
		tag_bytes = ciphertext_bytes[len(ciphertext_bytes) - 16:]
	}

	plaintext := make([]byte, len(ct_data), context.temp_allocator)
	defer mem.zero_explicit(raw_data(plaintext), len(plaintext))

	// Canonical AAD bindings
	aad1 := fmt.tprintf("%s:%d:%s", bridge_id, timestamp, nonce)
	aad2 := fmt.tprintf("{\"bridge_id\":\"%s\",\"nonce\":\"%s\",\"timestamp\":%d}", bridge_id, nonce, timestamp)

	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, aes_key[:])
	defer aes.reset_gcm(&gcm)

	dec_ok := aes.open_gcm(&gcm, plaintext, iv_bytes, transmute([]byte)aad1, ct_data, tag_bytes)
	if !dec_ok {
		aes.reset_gcm(&gcm)
		aes.init_gcm(&gcm, aes_key[:])
		dec_ok = aes.open_gcm(&gcm, plaintext, iv_bytes, transmute([]byte)aad2, ct_data, tag_bytes)
	}

	if !dec_ok {
		return false, "AEAD tag verification failed: tamper detected or authentication failure"
	}

	// f) On success: parse key and store in mlock'd memory and kernel keyring @u
	key_hex := ""
	if len(plaintext) == 64 && bridge_is_valid_hex_key(string(plaintext)) {
		key_hex = string(plaintext)
	} else if len(plaintext) == 32 {
		hex_bytes, _ := hex.encode(plaintext, context.temp_allocator)
		key_hex = string(hex_bytes)
	} else {
		return false, "invalid decrypted key format: expected 32 raw bytes or 64 hex chars"
	}

	// Persisted under this bridge's own id (REQ-T5-2); bridge_id == local_bridge_id here.
	store_ok, _ := keystore_store_vault_key(local_bridge_id, key_hex)
	if !store_ok {
		return false, "failed to store unsealed vault key in secure keystore"
	}
	bridge_enrollment_unseal_mark_received()

	return true, ""
}
