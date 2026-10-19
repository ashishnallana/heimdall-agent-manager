package main

import "core:crypto"
import "core:crypto/ecdh"
import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import jsonx "odin_test:lib/jsonx"
import os_random "odin_test:lib/os_random"
import vault "odin_test:lib/vault"

// ── Bridge unseal v2 (docs/plans/passwordless-vault.md §1) ──────────────────
//
// Two keys, two jobs:
//
//   - The EPHEMERAL ECDH P-256 key (per process, never persisted) receives the
//     keyring: browser ECDH → HKDF("heimdall-bridge-unseal-v2") → AES-256-GCM.
//     Ephemerality keeps every captured unseal ciphertext undecryptable after a
//     restart.
//   - The persistent IDENTITY ECDSA P-256 key (keystore .Identity slot) is created
//     at enrollment, shown to the approving human, and each boot signs
//     "heimdall-bridge-unseal-key/v1\n<bridge_id>\n<ecdh_pub_hex>\n<boot_id>".
//     A browser only encrypts to an ephemeral key that verifies under the identity
//     it trusts, and echoes the signature back so this bridge can tell the browser
//     encrypted to the key it actually holds.
//
// Everything fails closed: no randomness → no key; no identity → no signature →
// no unseal; any mismatch → nothing stored.

UNSEAL_NONCE_TTL_MS :: 60_000
UNSEAL_CLOCK_SKEW_MAX_MS :: 30_000
UNSEAL_NONCE_CACHE_CAPACITY :: 512
P256_POINT_SIZE :: 65
P256_COORD_SIZE :: 32
P256_UNCOMPRESSED_PREFIX :: 0x04
UNSEAL_BOOT_ID_BYTES :: 16

g_bridge_ecdh_priv: ecdh.Private_Key
g_bridge_ecdh_pub_hex_buf: [P256_POINT_SIZE * 2]byte
g_bridge_boot_id_buf: [UNSEAL_BOOT_ID_BYTES * 2]byte
g_bridge_ecdh_initialized: bool
g_bridge_ecdh_mu: sync.Mutex

// Identity state, guarded by g_bridge_identity_mu.
@(private = "file")
g_bridge_identity_mu: sync.Mutex
@(private = "file")
g_bridge_identity_priv: ecdsa.Private_Key
@(private = "file")
g_bridge_identity_pub_hex_buf: [P256_POINT_SIZE * 2]byte
@(private = "file")
g_bridge_identity_loaded: bool
// The bridge id the loaded identity is persisted under; "" while an enrollment
// holds a not-yet-persisted identity in memory.
@(private = "file")
g_bridge_identity_owner_buf: [128]byte
@(private = "file")
g_bridge_identity_owner_len: int
// The enrolled owner's user id from the identity record ("" until committed).
@(private = "file")
g_bridge_identity_user_buf: [vault.KEYRING_MAX_USER_ID]byte
@(private = "file")
g_bridge_identity_user_len: int
// Why the identity is unavailable, for status reporting (finding H1).
@(private = "file")
g_bridge_identity_state: Bridge_Identity_State

// Bridge_Identity_State: .Lost means the bridge is enrolled but its identity record
// is gone; it never regenerates one and must be re-enrolled. .Unreadable means a
// record exists but cannot be read or parsed (also fail closed).
Bridge_Identity_State :: enum {
	Unknown,
	Ready,
	Lost,
	Unreadable,
}
// Cached signature object over the current ephemeral key for one bridge id.
@(private = "file")
g_bridge_unseal_sig_buf: [256]byte
@(private = "file")
g_bridge_unseal_sig_len: int
@(private = "file")
g_bridge_unseal_sig_bridge_buf: [128]byte
@(private = "file")
g_bridge_unseal_sig_bridge_len: int

// bridge_unseal_random_source is the CSPRNG for the ephemeral key, boot id and
// identity key; tests point it at an unreadable path to prove fail-closed behavior.
bridge_unseal_random_source := os_random.DEFAULT_SOURCE

@(private = "file")
HEX_LOWER := "0123456789abcdef"

@(private = "file")
hex_into :: proc(dst: []byte, src: []byte) {
	for b, i in src {
		dst[i * 2] = HEX_LOWER[b >> 4]
		dst[i * 2 + 1] = HEX_LOWER[b & 0x0f]
	}
}

// bridge_unseal_init creates this process's ephemeral ECDH key and boot id from
// the OS CSPRNG. On a randomness failure nothing is initialized and no public key
// is ever advertised.
bridge_unseal_init :: proc() {
	sync.mutex_lock(&g_bridge_ecdh_mu)
	defer sync.mutex_unlock(&g_bridge_ecdh_mu)
	if g_bridge_ecdh_initialized do return

	scalar: [P256_COORD_SIZE]byte
	defer crypto.zero_explicit(&scalar, size_of(scalar))
	generated := false
	for _ in 0 ..< 8 {
		if !os_random.fill(scalar[:], bridge_unseal_random_source) do break
		if ecdh.private_key_set_bytes(&g_bridge_ecdh_priv, .SECP256R1, scalar[:]) {
			generated = true
			break
		}
	}
	boot: [UNSEAL_BOOT_ID_BYTES]byte
	if !generated || !os_random.fill(boot[:], bridge_unseal_random_source) {
		ecdh.private_key_clear(&g_bridge_ecdh_priv)
		fmt.eprintln("ERROR: OS random source failed; this bridge cannot accept an unseal")
		return
	}
	pub_bytes: [P256_POINT_SIZE]byte
	ecdh.private_key_public_bytes(&g_bridge_ecdh_priv, pub_bytes[:])
	hex_into(g_bridge_ecdh_pub_hex_buf[:], pub_bytes[:])
	hex_into(g_bridge_boot_id_buf[:], boot[:])
	g_bridge_ecdh_initialized = true
}

// Returns the bridge's ephemeral public key ("" when it could not be created).
bridge_get_public_key_hex :: proc() -> string {
	bridge_unseal_init()
	sync.mutex_lock(&g_bridge_ecdh_mu)
	defer sync.mutex_unlock(&g_bridge_ecdh_mu)
	if !g_bridge_ecdh_initialized do return ""
	return string(g_bridge_ecdh_pub_hex_buf[:])
}

bridge_unseal_boot_id :: proc() -> string {
	bridge_unseal_init()
	sync.mutex_lock(&g_bridge_ecdh_mu)
	defer sync.mutex_unlock(&g_bridge_ecdh_mu)
	if !g_bridge_ecdh_initialized do return ""
	return string(g_bridge_boot_id_buf[:])
}

// Resets the ephemeral key and identity state (test isolation only).
bridge_unseal_reset_for_test :: proc() {
	sync.mutex_lock(&g_bridge_ecdh_mu)
	if g_bridge_ecdh_initialized {
		ecdh.private_key_clear(&g_bridge_ecdh_priv)
		mem.zero_explicit(&g_bridge_ecdh_pub_hex_buf, size_of(g_bridge_ecdh_pub_hex_buf))
		g_bridge_ecdh_initialized = false
	}
	sync.mutex_unlock(&g_bridge_ecdh_mu)
	bridge_unseal_forget_identity()
}

// bridge_unseal_forget_identity drops the in-memory identity and cached signature
// (vault.reset, an aborted enrollment, tests). It does not touch the keystore.
bridge_unseal_forget_identity :: proc() {
	sync.mutex_lock(&g_bridge_identity_mu)
	defer sync.mutex_unlock(&g_bridge_identity_mu)
	bridge_unseal_forget_identity_locked()
}

@(private = "file")
bridge_unseal_forget_identity_locked :: proc() {
	ecdsa.private_key_clear(&g_bridge_identity_priv)
	g_bridge_identity_loaded = false
	g_bridge_identity_owner_len = 0
	crypto.zero_explicit(&g_bridge_identity_user_buf, size_of(g_bridge_identity_user_buf))
	g_bridge_identity_user_len = 0
	g_bridge_identity_state = .Unknown
	g_bridge_unseal_sig_len = 0
	g_bridge_unseal_sig_bridge_len = 0
}

@(private = "file")
bridge_unseal_identity_install_locked :: proc(scalar: []byte) -> bool {
	if !ecdsa.private_key_set_bytes(&g_bridge_identity_priv, .SECP256R1, scalar) do return false
	pub: [P256_POINT_SIZE]byte
	ecdsa.private_key_public_bytes(&g_bridge_identity_priv, pub[:])
	hex_into(g_bridge_identity_pub_hex_buf[:], pub[:])
	g_bridge_identity_loaded = true
	g_bridge_unseal_sig_len = 0
	g_bridge_unseal_sig_bridge_len = 0
	return true
}

@(private = "file")
bridge_unseal_identity_generate_locked :: proc() -> bool {
	priv: ecdsa.Private_Key
	defer ecdsa.private_key_clear(&priv)
	if !vault.p256_private_key_generate(&priv, bridge_unseal_random_source) do return false
	scalar: [vault.P256_PRIVATE_KEY_BYTES]byte
	defer crypto.zero_explicit(&scalar, size_of(scalar))
	ecdsa.private_key_bytes(&priv, scalar[:])
	return bridge_unseal_identity_install_locked(scalar[:])
}

// bridge_unseal_identity_generate_for_enrollment creates a fresh in-memory identity
// before the bridge id exists (`ham-bridge enroll`). This is the ONLY place an
// identity is ever generated; bridge_unseal_identity_commit_enrollment persists it.
bridge_unseal_identity_generate_for_enrollment :: proc() -> (public_key_hex: string, ok: bool) {
	sync.mutex_lock(&g_bridge_identity_mu)
	defer sync.mutex_unlock(&g_bridge_identity_mu)
	bridge_unseal_forget_identity_locked()
	if !bridge_unseal_identity_generate_locked() do return "", false
	return strings.clone(string(g_bridge_identity_pub_hex_buf[:]), context.temp_allocator), true
}

// bridge_unseal_identity_enrollment_proof signs the /device/authorize proof of
// possession (vault.bridge_enroll_proof_canonical) with the enrollment's in-memory
// identity. Only for a generated-but-uncommitted identity. Temp-allocated.
bridge_unseal_identity_enrollment_proof :: proc(ecdh_pub_hex, code_challenge: string) -> (sig_json: string, ok: bool) {
	sync.mutex_lock(&g_bridge_identity_mu)
	defer sync.mutex_unlock(&g_bridge_identity_mu)
	if !g_bridge_identity_loaded || g_bridge_identity_owner_len != 0 do return "", false
	msg, m_ok := vault.bridge_enroll_proof_canonical(ecdh_pub_hex, code_challenge, context.temp_allocator)
	if !m_ok do return "", false
	sig, s_ok := vault.sign_p256(&g_bridge_identity_priv, transmute([]byte)msg)
	if !s_ok do return "", false
	return vault.signature_object(&sig, context.temp_allocator)
}

// bridge_unseal_identity_commit_enrollment persists the enrollment's in-memory
// identity under the hub-assigned bridge id together with the approving account
// (the enrolled owner). Called once, right after approval and before any unseal.
// Fails closed: no pending identity, an unusable owner, or a persistence failure
// leaves NO identity.
bridge_unseal_identity_commit_enrollment :: proc(bridge_id: string, owner_user_id: string) -> bool {
	sync.mutex_lock(&g_bridge_identity_mu)
	defer sync.mutex_unlock(&g_bridge_identity_mu)
	if !g_bridge_identity_loaded || g_bridge_identity_owner_len != 0 do return false
	if bridge_id == "" || len(bridge_id) > len(g_bridge_identity_owner_buf) do return false
	if len(owner_user_id) < 1 || len(owner_user_id) > len(g_bridge_identity_user_buf) || !vault.valid_id_value(owner_user_id) {
		bridge_unseal_forget_identity_locked()
		return false
	}
	scalar: [vault.P256_PRIVATE_KEY_BYTES]byte
	defer crypto.zero_explicit(&scalar, size_of(scalar))
	ecdsa.private_key_bytes(&g_bridge_identity_priv, scalar[:])
	if !keystore_store_identity(bridge_id, scalar[:], owner_user_id) {
		fmt.eprintln("ERROR: could not persist this bridge's identity key; enrollment cannot complete")
		bridge_unseal_forget_identity_locked()
		return false
	}
	// A fresh enrollment starts an empty anti-rollback floor. From here on a
	// missing floor record is an error, never "start over".
	empty_floor: Epoch_Floor
	if !keystore_store_epoch_floor(bridge_id, &empty_floor) {
		fmt.eprintln("ERROR: could not persist this bridge's epoch floor; enrollment cannot complete")
		_ = keystore_delete_identity_key(bridge_id)
		bridge_unseal_forget_identity_locked()
		return false
	}
	copy(g_bridge_identity_owner_buf[:], bridge_id)
	g_bridge_identity_owner_len = len(bridge_id)
	copy(g_bridge_identity_user_buf[:], owner_user_id)
	g_bridge_identity_user_len = len(owner_user_id)
	g_bridge_identity_state = .Ready
	return true
}

// bridge_unseal_identity_for makes the identity for bridge_id available: already
// loaded for it, or read back from the keystore. It NEVER generates one: an
// enrolled bridge whose record is missing enters .Lost ("identity lost;
// re-enroll"), and one whose record cannot be read enters .Unreadable. Either way
// no signature is advertised and every unseal is refused.
@(private = "file")
bridge_unseal_identity_for_locked :: proc(bridge_id: string) -> bool {
	if bridge_id == "" || len(bridge_id) > len(g_bridge_identity_owner_buf) do return false
	owner := string(g_bridge_identity_owner_buf[:g_bridge_identity_owner_len])
	if g_bridge_identity_loaded && g_bridge_identity_owner_len > 0 && owner == bridge_id do return true
	// An enrollment's identity that was never committed belongs to no bridge yet.
	if g_bridge_identity_loaded && g_bridge_identity_owner_len == 0 do return false

	prev_state := g_bridge_identity_state
	bridge_unseal_forget_identity_locked()
	rec: Bridge_Identity_Record
	defer crypto.zero_explicit(&rec, size_of(rec))
	switch keystore_read_identity(bridge_id, &rec) {
	case .Found:
	case .Not_Found:
		if prev_state != .Lost {
			fmt.eprintln("ERROR: this bridge's identity key is missing (identity lost); unseal is refused. Re-enroll with `ham-bridge enroll`.")
		}
		g_bridge_identity_state = .Lost
		return false
	case .Error:
		if prev_state != .Unreadable {
			fmt.eprintln("ERROR: this bridge's identity record could not be read; unseal is refused. Fix the keystore or re-enroll.")
		}
		g_bridge_identity_state = .Unreadable
		return false
	}
	if !bridge_unseal_identity_install_locked(rec.scalar[:]) {
		g_bridge_identity_state = .Unreadable
		return false
	}
	copy(g_bridge_identity_owner_buf[:], bridge_id)
	g_bridge_identity_owner_len = len(bridge_id)
	copy(g_bridge_identity_user_buf[:], bridge_identity_record_owner(&rec))
	g_bridge_identity_user_len = rec.owner_len
	g_bridge_identity_state = .Ready
	return true
}

bridge_unseal_identity_for :: proc(bridge_id: string) -> bool {
	sync.mutex_lock(&g_bridge_identity_mu)
	defer sync.mutex_unlock(&g_bridge_identity_mu)
	return bridge_unseal_identity_for_locked(bridge_id)
}

// bridge_identity_state reports why bridge_id's identity is or is not available.
bridge_identity_state :: proc(bridge_id: string) -> Bridge_Identity_State {
	sync.mutex_lock(&g_bridge_identity_mu)
	defer sync.mutex_unlock(&g_bridge_identity_mu)
	_ = bridge_unseal_identity_for_locked(bridge_id)
	return g_bridge_identity_state
}

// bridge_enrolled_owner_user_id returns the account bridge_id was enrolled to, or
// "" when the identity record is unavailable. Temp-allocated.
bridge_enrolled_owner_user_id :: proc(bridge_id: string) -> string {
	sync.mutex_lock(&g_bridge_identity_mu)
	defer sync.mutex_unlock(&g_bridge_identity_mu)
	if !bridge_unseal_identity_for_locked(bridge_id) do return ""
	return strings.clone(string(g_bridge_identity_user_buf[:g_bridge_identity_user_len]), context.temp_allocator)
}

// bridge_identity_public_key_hex returns bridge_id's identity public key, or "".
// Temp-allocated.
bridge_identity_public_key_hex :: proc(bridge_id: string) -> string {
	sync.mutex_lock(&g_bridge_identity_mu)
	defer sync.mutex_unlock(&g_bridge_identity_mu)
	if !bridge_unseal_identity_for_locked(bridge_id) do return ""
	return strings.clone(string(g_bridge_identity_pub_hex_buf[:]), context.temp_allocator)
}

// bridge_unseal_key_signature_json returns the signature object over this boot's
// ephemeral key for bridge_id, signing on first use per bridge id. ok=false means
// there is nothing to advertise (no identity, no ephemeral key). Temp-allocated.
bridge_unseal_key_signature_json :: proc(bridge_id: string) -> (sig_json: string, ok: bool) {
	pub_hex := bridge_get_public_key_hex()
	boot_id := bridge_unseal_boot_id()
	if pub_hex == "" || boot_id == "" do return "", false
	sync.mutex_lock(&g_bridge_identity_mu)
	defer sync.mutex_unlock(&g_bridge_identity_mu)
	if !bridge_unseal_identity_for_locked(bridge_id) do return "", false
	if g_bridge_unseal_sig_len > 0 && string(g_bridge_unseal_sig_bridge_buf[:g_bridge_unseal_sig_bridge_len]) == bridge_id {
		return strings.clone(string(g_bridge_unseal_sig_buf[:g_bridge_unseal_sig_len]), context.temp_allocator), true
	}
	canonical, c_ok := vault.bridge_unseal_key_canonical(bridge_id, pub_hex, boot_id, context.temp_allocator)
	if !c_ok do return "", false
	sig, s_ok := vault.sign_p256(&g_bridge_identity_priv, transmute([]byte)canonical)
	if !s_ok do return "", false
	obj, o_ok := vault.signature_object(&sig, context.temp_allocator)
	if !o_ok || len(obj) > len(g_bridge_unseal_sig_buf) || len(bridge_id) > len(g_bridge_unseal_sig_bridge_buf) do return "", false
	copy(g_bridge_unseal_sig_buf[:], obj)
	g_bridge_unseal_sig_len = len(obj)
	copy(g_bridge_unseal_sig_bridge_buf[:], bridge_id)
	g_bridge_unseal_sig_bridge_len = len(bridge_id)
	return obj, true
}

// bridge_unseal_write_hello_fields appends the unseal-key advertisement to a hello
// JSON object under construction (leading comma included). Nothing is written when
// there is no signed key: an unsigned key is never advertised as unsealable.
bridge_unseal_write_hello_fields :: proc(b: ^strings.Builder, bridge_id: string) {
	// An unenrolled bridge (no `brg_` id) has nowhere to keep an identity.
	if !keystore_bridge_id_ok(bridge_id) do return
	sig_json, ok := bridge_unseal_key_signature_json(bridge_id)
	if !ok {
		// Tell the hub (and so the UI) why this bridge cannot be unsealed.
		#partial switch bridge_identity_state(bridge_id) {
		case .Lost:
			strings.write_string(b, ",\"identity_state\":\"lost\"")
		case .Unreadable:
			strings.write_string(b, ",\"identity_state\":\"unreadable\"")
		}
		return
	}
	identity := bridge_identity_public_key_hex(bridge_id)
	if identity == "" do return
	strings.write_string(b, ",\"unseal_boot_id\":\"")
	strings.write_string(b, bridge_unseal_boot_id())
	strings.write_string(b, "\",\"unseal_key_signature\":")
	strings.write_string(b, sig_json)
	strings.write_string(b, ",\"identity_public_key\":\"")
	strings.write_string(b, identity)
	strings.write_string(b, "\",\"identity_sign_alg\":\"")
	strings.write_string(b, vault.SIGN_ALG_ECDSA_P256_SHA256)
	strings.write_string(b, "\"")
}

// ── Nonce replay cache ──────────────────────────────────────────────────────
//
// A fixed-capacity set of nonces, each live until its own expiry. A nonce is
// recorded only after its message has authenticated (finding L1), so garbage
// cannot fill the cache; and when every slot still holds a live nonce the insert
// is REFUSED rather than evicting one, since an evicted nonce could be replayed
// inside its window. Shared by bridge_unseal (60 s) and enc_spec (finding M1).

Nonce_Cache_Entry :: struct {
	nonce_buf:  [64]byte,
	nonce_len:  int,
	expires_ms: i64,
}

Nonce_Replay_Cache :: struct {
	entries: [UNSEAL_NONCE_CACHE_CAPACITY]Nonce_Cache_Entry,
	mu:      sync.Mutex,
}

Unseal_Nonce_Cache :: Nonce_Replay_Cache

Nonce_Cache_Result :: enum {
	Inserted,
	Replay,
	Full,
	Invalid,
}

// nonce_cache_seen reports whether nonce is recorded and still live at now_ms.
nonce_cache_seen :: proc(cache: ^Nonce_Replay_Cache, nonce: string, now_ms: i64) -> bool {
	if nonce == "" || len(nonce) > 64 do return false
	sync.mutex_lock(&cache.mu)
	defer sync.mutex_unlock(&cache.mu)
	for &e in cache.entries {
		if e.nonce_len == len(nonce) && now_ms <= e.expires_ms && string(e.nonce_buf[:e.nonce_len]) == nonce do return true
	}
	return false
}

// nonce_cache_insert records nonce until now_ms + ttl_ms. Atomic with the replay
// check, so two concurrent deliveries of one nonce cannot both be inserted.
nonce_cache_insert :: proc(cache: ^Nonce_Replay_Cache, nonce: string, now_ms: i64, ttl_ms: i64) -> Nonce_Cache_Result {
	if nonce == "" || len(nonce) > 64 || ttl_ms <= 0 do return .Invalid
	sync.mutex_lock(&cache.mu)
	defer sync.mutex_unlock(&cache.mu)
	free: ^Nonce_Cache_Entry
	for &e in cache.entries {
		live := e.nonce_len > 0 && now_ms <= e.expires_ms
		if live {
			if e.nonce_len == len(nonce) && string(e.nonce_buf[:e.nonce_len]) == nonce do return .Replay
		} else if free == nil {
			free = &e
		}
	}
	if free == nil do return .Full
	copy(free.nonce_buf[:], nonce)
	free.nonce_len = len(nonce)
	free.expires_ms = now_ms + ttl_ms
	return .Inserted
}

g_unseal_nonce_cache: Unseal_Nonce_Cache
g_enrollment_unseal_mu: sync.Mutex
g_enrollment_unseal_received: bool

// Enrollment uses the normal Hub runtime relay, but exits after the keyring has
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

unseal_nonce_cache_clear :: proc(cache: ^Unseal_Nonce_Cache) {
	sync.mutex_lock(&cache.mu)
	defer sync.mutex_unlock(&cache.mu)
	for &e in cache.entries do e = {}
}

// bridge_unseal_signature_echo reads the payload's unseal_key_signature object and
// renders it canonically. A missing, non-object or oddly typed member is "" (no echo).
@(private = "file")
bridge_unseal_signature_echo :: proc(payload_json: string) -> string {
	parsed, ok := jsonx.parse_body(payload_json, context.temp_allocator)
	if !ok do return ""
	root, is_obj := parsed.(json.Object)
	if !is_obj do return ""
	sig_v, has := root["unseal_key_signature"]
	if !has do return ""
	sig_obj, sig_is_obj := sig_v.(json.Object)
	if !sig_is_obj || len(sig_obj) != 2 do return ""
	alg, alg_ok := sig_obj["alg"].(json.String)
	sig, sig_ok := sig_obj["sig"].(json.String)
	if !alg_ok || !sig_ok do return ""
	return strings.concatenate({`{"alg":"`, string(alg), `","sig":"`, string(sig), `"}`}, context.temp_allocator)
}

// bridge_unseal_decrypt_and_verify checks an unseal v2 payload end to end and, only
// when every check passes, stores the keyring. Checks, in order: required fields,
// format, clock skew (±30 s), target bridge id, nonce replay, epoch range, the
// identity-key echo, the signature echo (must equal this boot's signature and
// verify under this bridge's identity key), the AEAD (v2 AAD only), the keyring's
// validity and current epoch, that it belongs to this bridge's enrolled owner, and
// that it is a superset of any keyring already stored (no substitution, no
// rollback). v1 payloads (old AAD forms, 32/64-byte plaintexts) cannot pass.
bridge_unseal_decrypt_and_verify :: proc(
	payload_json: string,
	local_bridge_id: string,
	current_clock_ms: i64,
) -> (ok: bool, err_msg: string) {
	bridge_unseal_init()

	bridge_id := jsonx.extract_string(payload_json, "bridge_id", "", true, context.temp_allocator)
	nonce := jsonx.extract_string(payload_json, "nonce", "", true, context.temp_allocator)
	client_pub := jsonx.extract_string(payload_json, "client_public_key", "", true, context.temp_allocator)
	iv := jsonx.extract_string(payload_json, "iv", "", true, context.temp_allocator)
	tag := jsonx.extract_string(payload_json, "tag", "", true, context.temp_allocator)
	ciphertext := jsonx.extract_string(payload_json, "ciphertext", "", true, context.temp_allocator)
	format := jsonx.extract_string(payload_json, "format", "", true, context.temp_allocator)
	identity_echo := jsonx.extract_string(payload_json, "bridge_identity_public_key", "", true, context.temp_allocator)
	timestamp_int, ts_ok := jsonx.extract_int_found(payload_json, "timestamp", true)
	epoch_int, epoch_ok := jsonx.extract_int_found(payload_json, "current_epoch", true)

	if !ts_ok do return false, "missing timestamp in unseal payload"
	if bridge_id == "" || nonce == "" || client_pub == "" || iv == "" || tag == "" || ciphertext == "" || identity_echo == "" || !epoch_ok {
		return false, "missing required unseal parameters"
	}
	if format != vault.UNSEAL_V2_FORMAT do return false, "unsupported unseal format (keyring-v1 required)"
	timestamp := i64(timestamp_int)

	skew := current_clock_ms - timestamp
	if skew < -UNSEAL_CLOCK_SKEW_MAX_MS || skew > UNSEAL_CLOCK_SKEW_MAX_MS {
		return false, "clock skew expired or out of window"
	}
	if bridge_id != local_bridge_id {
		return false, "cross-bridge replay rejected: target bridge_id mismatch"
	}
	// Cheap early reject; the nonce is only RECORDED after the AEAD passes below.
	if nonce_cache_seen(&g_unseal_nonce_cache, nonce, current_clock_ms) {
		return false, "replay rejected: nonce already used"
	}
	if epoch_int < 1 || i64(epoch_int) > i64(vault.MAX_EPOCH) {
		return false, "invalid current_epoch"
	}

	// The browser must have encrypted to THIS boot's key, as certified by THIS
	// bridge's identity: both echoes must match what we advertise.
	our_identity := bridge_identity_public_key_hex(local_bridge_id)
	if our_identity == "" do return false, "this bridge has no identity key; unseal unavailable"
	if len(identity_echo) != len(our_identity) || crypto.compare_constant_time(transmute([]byte)identity_echo, transmute([]byte)our_identity) != 1 {
		return false, "identity key mismatch: the payload was prepared for a different bridge identity"
	}
	our_sig, sig_ok := bridge_unseal_key_signature_json(local_bridge_id)
	if !sig_ok do return false, "this bridge has no signed unseal key; unseal unavailable"
	echo := bridge_unseal_signature_echo(payload_json)
	canonical, c_ok := vault.bridge_unseal_key_canonical(local_bridge_id, bridge_get_public_key_hex(), bridge_unseal_boot_id(), context.temp_allocator)
	if !c_ok || echo == "" || !vault.verify(vault.SIGN_ALG_ECDSA_P256_SHA256, our_identity, transmute([]byte)canonical, echo) {
		return false, "unseal key signature does not verify under this bridge's identity"
	}
	if len(echo) != len(our_sig) || crypto.compare_constant_time(transmute([]byte)echo, transmute([]byte)our_sig) != 1 {
		return false, "unseal key signature is not this boot's signature"
	}

	sync.mutex_lock(&g_bridge_ecdh_mu)
	kr, open_err := vault.unseal_v2_open(&g_bridge_ecdh_priv, client_pub, iv, tag, ciphertext, bridge_id, timestamp, nonce, u32(epoch_int))
	sync.mutex_unlock(&g_bridge_ecdh_mu)
	defer vault.keyring_wipe(&kr)
	switch open_err {
	case .None:
	case .Bad_Public_Key:
		return false, "invalid client public key point"
	case .Bad_Parameters:
		return false, "invalid unseal parameters (iv/tag/ciphertext must be lowercase hex)"
	case .Auth_Failed:
		return false, "AEAD tag verification failed: tamper detected or authentication failure"
	case .Bad_Keyring:
		return false, "decrypted payload is not a valid keyring"
	case .Epoch_Mismatch:
		return false, "keyring current epoch does not match the signed current_epoch"
	}

	// Authenticated: consume the nonce now (atomically re-checking for a racing
	// duplicate). A full cache refuses rather than forgetting a live nonce.
	switch nonce_cache_insert(&g_unseal_nonce_cache, nonce, current_clock_ms, UNSEAL_NONCE_TTL_MS) {
	case .Inserted:
	case .Replay:
		return false, "replay rejected: nonce already used"
	case .Full:
		return false, "too many recent unseal attempts; retry shortly"
	case .Invalid:
		return false, "invalid nonce"
	}

	// ── Keyring authentication (plan §1, finding C1) ──────────────────────
	// The ECDH unseal proves only that the sender saw this boot's signed key, not
	// who the sender is: a hostile hub can seal its own keyring to it. So:
	//
	//  (a) the keyring must belong to the account this bridge was enrolled to
	//      (pinned in the identity record at enrollment). Unknown owner → refuse.
	owner := bridge_enrolled_owner_user_id(local_bridge_id)
	if owner == "" do return false, "this bridge's enrolled owner is unknown; re-enroll it"
	kr_user := vault.keyring_user_id(&kr)
	if len(kr_user) != len(owner) || crypto.compare_constant_time(transmute([]byte)kr_user, transmute([]byte)owner) != 1 {
		return false, "keyring does not belong to this bridge's enrolled owner"
	}
	//  (b) once a keyring is stored, a new one is accepted only as a superset of
	//      it: identical keys for every stored epoch and no current-epoch rollback.
	if existing, has := keystore_read_vault_keyring(local_bridge_id); has {
		update_err := vault.keyring_check_update(&existing, &kr)
		vault.keyring_wipe(&existing)
		switch update_err {
		case .None:
		case .Invalid:
			return false, "stored or delivered keyring is invalid"
		case .Different_User:
			return false, "keyring belongs to a different user than the one this bridge holds"
		case .Epoch_Rollback:
			return false, "keyring rollback rejected: current epoch is older than the stored keyring's"
		case .Missing_Epoch:
			return false, "keyring rejected: it drops an epoch this bridge already holds"
		case .Key_Mismatch:
			return false, "keyring rejected: an epoch's key differs from the one this bridge holds"
		}
	}
	//  (b') The persistent floor survives a lock (which deletes the stored keyring):
	//      no current epoch below the highest ever accepted, and no known epoch with
	//      a key other than the one committed. Unreadable or missing → refuse.
	floor, floor_status := keystore_read_epoch_floor(local_bridge_id)
	switch floor_status {
	case .Found:
	case .Not_Found:
		return false, "this bridge's epoch floor record is missing; re-enroll it"
	case .Error:
		return false, "this bridge's epoch floor record could not be read; unseal refused"
	}
	switch epoch_floor_check(&floor, local_bridge_id, &kr) {
	case .None:
	case .Rollback:
		return false, "keyring rollback rejected: current epoch is below this bridge's epoch floor"
	case .Key_Mismatch:
		return false, "keyring rejected: an epoch's key differs from the one this bridge accepted before"
	}
	//  (c) P2/P3 HOOK — signed epoch statement chain (plan §1, required before P3).
	//      This is where the bridge must verify, BEFORE installing anything below:
	//      the `epoch` statement for kr.current_epoch carried in the payload, the
	//      approval chain of its issuer back to the account root_sign_pub pinned at
	//      enrollment, that the issuer is an approved non-bridge device, and that
	//      epoch_commit matches the unwrapped current key. Missing or invalid proof
	//      must return false here. Until then (a) and (b) are the only gates.

	raw: [vault.KEYRING_MAX_BYTES]byte
	defer crypto.zero_explicit(&raw, size_of(raw))
	bytes, ser_ok := vault.keyring_serialize_into(&kr, raw[:])
	if !ser_ok do return false, "keyring could not be serialized"
	// Raise the floor BEFORE installing: a keyring is never live without its floor.
	epoch_floor_merge(&floor, local_bridge_id, &kr)
	if !keystore_store_epoch_floor(local_bridge_id, &floor) do return false, "failed to persist the epoch floor; unseal refused"
	store_ok, _ := keystore_store_vault_keyring(local_bridge_id, bytes)
	if !store_ok do return false, "failed to store unsealed vault keyring in secure keystore"

	// A new keyring: rebuild the search index under it and re-salt every PTY stream.
	bridge_task_chain_search_lock()
	bridge_pty_stream_resalt_all()
	bridge_enrollment_unseal_mark_received()
	return true, ""
}
