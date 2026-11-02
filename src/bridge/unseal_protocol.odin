package main

import "core:crypto"
import "core:crypto/ecdh"
import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
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

// ── Hub-blind pairing (plan §1 "Pairing") ──────────────────────────────────
// `ham-bridge enroll` draws a secret pairing code, prints it for the operator and
// keeps only the derived keys, in memory, for the life of the enrollment. The FIRST
// unseal (no root pinned yet) is accepted only with a pair_mac under that code over
// this bridge's approval and the account root: the hub never sees the code, so it
// cannot race the approver with its own root. Wiped after the first pin and when the
// enrollment ends; a process without armed pairing keys never pins a root.

@(private = "file")
g_bridge_pair_mu: sync.Mutex
@(private = "file")
g_bridge_pair_keys: vault.Pair_Keys
@(private = "file")
g_bridge_pair_armed: bool
// Unix ms after which the armed keys are useless: the pairing code's own lifetime
// (vault.PAIR_CODE_TTL_SECONDS from when it was drawn), whatever the hub says.
@(private = "file")
g_bridge_pair_deadline_ms: i64

// bridge_pairing_arm keeps the pairing keys until deadline_ms (unix ms), the end of
// the pairing code's lifetime; after it they are wiped and never used.
bridge_pairing_arm :: proc(keys: ^vault.Pair_Keys, deadline_ms: i64) {
	sync.mutex_lock(&g_bridge_pair_mu)
	defer sync.mutex_unlock(&g_bridge_pair_mu)
	g_bridge_pair_keys = keys^
	g_bridge_pair_deadline_ms = deadline_ms
	g_bridge_pair_armed = true
}

bridge_pairing_disarm :: proc() {
	sync.mutex_lock(&g_bridge_pair_mu)
	defer sync.mutex_unlock(&g_bridge_pair_mu)
	vault.pair_keys_wipe(&g_bridge_pair_keys)
	g_bridge_pair_armed = false
	g_bridge_pair_deadline_ms = 0
}

// bridge_pairing_is_armed: this process holds live pairing keys (an enrollment in progress).
bridge_pairing_is_armed :: proc() -> bool {
	sync.mutex_lock(&g_bridge_pair_mu)
	defer sync.mutex_unlock(&g_bridge_pair_mu)
	return g_bridge_pair_armed && bridge_now_unix_ms() <= g_bridge_pair_deadline_ms
}

// bridge_pairing_first_pin_ok verifies a first unseal's pair_mac (after the chain proof verified).
@(private = "file")
bridge_pairing_first_pin_ok :: proc(proof_value: json.Value, pair_mac: string) -> bool {
	sync.mutex_lock(&g_bridge_pair_mu)
	defer sync.mutex_unlock(&g_bridge_pair_mu)
	if !g_bridge_pair_armed do return false
	if bridge_now_unix_ms() > g_bridge_pair_deadline_ms {
		// Past the code's lifetime: disarm (the approver refuses an expired code too).
		vault.pair_keys_wipe(&g_bridge_pair_keys)
		g_bridge_pair_armed = false
		return false
	}
	return vault.pair_verify_bridge_first_pin(&g_bridge_pair_keys, proof_value, pair_mac)
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
//
// replace_previous is a re-enrollment of the SAME bridge id (the approver reused
// it): the existing record may then be replaced, but only once
// bridge_reenroll_begin has backed it up, and only by the account that enrolled it.
bridge_unseal_identity_commit_enrollment :: proc(bridge_id: string, owner_user_id: string, replace_previous := false) -> bool {
	sync.mutex_lock(&g_bridge_identity_mu)
	defer sync.mutex_unlock(&g_bridge_identity_mu)
	if !g_bridge_identity_loaded || g_bridge_identity_owner_len != 0 do return false
	if bridge_id == "" || len(bridge_id) > len(g_bridge_identity_owner_buf) do return false
	if len(owner_user_id) < 1 || len(owner_user_id) > len(g_bridge_identity_user_buf) || !vault.valid_id_value(owner_user_id) {
		bridge_unseal_forget_identity_locked()
		return false
	}
	// Never overwrite: an enrollment record for this (hub, bridge id) scope that
	// already exists belongs to a bridge enrolled earlier (or a hub re-issuing an id).
	// Refuse rather than replace its identity, keyring or floor.
	{
		existing: Bridge_Identity_Record
		status := keystore_read_identity(bridge_id, &existing)
		same_owner := status == .Found && bridge_identity_record_owner(&existing) == owner_user_id
		crypto.zero_explicit(&existing, size_of(existing))
		if status != .Not_Found && replace_previous {
			// A re-enrollment of this very bridge: the previous record is replaced only
			// with its backup in place (restored on rollback), and never for another
			// account (a hub handing one account's bridge id to another).
			if keystore_identity_backup_status(bridge_id) != .Found {
				fmt.eprintfln("ERROR: the previous enrollment of %s could not be backed up; refusing to replace it.", bridge_id)
				bridge_unseal_forget_identity_locked()
				return false
			}
			if status == .Found && !same_owner {
				fmt.eprintfln("ERROR: %s was enrolled by another account than the one that approved this re-enrollment; refusing to replace it.", bridge_id)
				bridge_unseal_forget_identity_locked()
				return false
			}
		} else if status != .Not_Found {
			fmt.eprintfln("ERROR: this machine already holds an enrollment of %s for this hub (or its record is unreadable); refusing to overwrite it. Remove that enrollment first, or enroll with a separate --config/--bridge-token-file.", bridge_id)
			bridge_unseal_forget_identity_locked()
			return false
		}
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

// Internal caller constructs only the MCP result domain-separated statement.
bridge_mcp_sign_result :: proc(bridge_id,statement:string)->(string,bool) {
	if !strings.has_prefix(statement,"heimdall-mcp-worker-result/v1\n") do return "",false
	sync.mutex_lock(&g_bridge_identity_mu)
	defer sync.mutex_unlock(&g_bridge_identity_mu)
	if !bridge_unseal_identity_for_locked(bridge_id) do return "",false
	sig,ok:=vault.sign_p256(&g_bridge_identity_priv,transmute([]byte)statement)
	if !ok do return "",false
	return vault.signature_object(&sig,context.temp_allocator)
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

// Bridge_Unseal_Hello_Fields is the unseal-key advertisement carried in a
// bridge_hello (flattened into it). Every member is omitted when empty: with no
// signed key nothing is advertised, since an unsigned key is never unsealable, and
// identity_state then says why ("lost" / "unreadable") when it is known.
Bridge_Unseal_Hello_Fields :: struct {
	identity_state:       string `json:"identity_state,omitempty"`,
	unseal_boot_id:       string `json:"unseal_boot_id,omitempty"`,
	unseal_key_signature: Maybe(vault.Signature_Wire) `json:"unseal_key_signature,omitempty"`,
	identity_public_key:  string `json:"identity_public_key,omitempty"`,
	identity_sign_alg:    string `json:"identity_sign_alg,omitempty"`,
}

// bridge_unseal_hello_fields builds the advertisement for bridge_id (temp-allocated).
bridge_unseal_hello_fields :: proc(bridge_id: string) -> (f: Bridge_Unseal_Hello_Fields) {
	// An unenrolled bridge (no `brg_` id) has nowhere to keep an identity.
	if !keystore_bridge_id_ok(bridge_id) do return
	sig_json, ok := bridge_unseal_key_signature_json(bridge_id)
	if !ok {
		// Tell the hub (and so the UI) why this bridge cannot be unsealed.
		#partial switch bridge_identity_state(bridge_id) {
		case .Lost:
			f.identity_state = "lost"
		case .Unreadable:
			f.identity_state = "unreadable"
		}
		return
	}
	identity := bridge_identity_public_key_hex(bridge_id)
	if identity == "" do return
	sig, sig_ok := vault.signature_wire_from_text(sig_json, context.temp_allocator)
	if !sig_ok do return
	f.unseal_boot_id = bridge_unseal_boot_id()
	f.unseal_key_signature = sig
	f.identity_public_key = identity
	f.identity_sign_alg = vault.SIGN_ALG_ECDSA_P256_SHA256
	return
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

// Bridge_Unseal_Payload is the bridge_unseal command (the browser's payload, relayed
// verbatim by the hub with its type and command_id). Integers are Maybe so absence is
// told apart from zero; a member of the wrong type fails the whole decode.
Bridge_Unseal_Payload :: struct {
	bridge_id:                  string,
	timestamp:                  Maybe(i64),
	nonce:                      string,
	client_public_key:          string,
	iv:                         string,
	tag:                        string,
	ciphertext:                 string,
	format:                     string,
	current_epoch:              Maybe(i64),
	// Echo of this boot's signature object over its ephemeral key.
	unseal_key_signature:       Maybe(vault.Signature_Wire),
	bridge_identity_public_key: string,
	// Signed proof to the account root; verified by vault.bridge_chain_verify.
	chain_proof:                json.Value,
	// First unseal only: the approver's MAC under this bridge's pairing code.
	pair_mac:                   string,
}

// bridge_unseal_decrypt_and_verify checks an unseal v2 payload end to end and, only
// when every check passes, stores the keyring. Checks, in order: required fields,
// format, clock skew (±30 s), target bridge id, nonce replay, epoch range, the
// identity-key echo, the signature echo (must equal this boot's signature and
// verify under this bridge's identity key), the AEAD (v2 AAD only), the keyring's
// validity and current epoch, that it belongs to this bridge's enrolled owner, that
// it is a superset of any keyring already stored and passes the persistent epoch
// floor (no substitution, no rollback), and the payload's signed `chain_proof` to the
// pinned account root (vault.bridge_chain_verify). v1 payloads (old AAD forms,
// 32/64-byte plaintexts) and payloads without a valid proof cannot pass.
// g_unseal_install_mu serializes the keyring check → floor store → keyring store of
// bridge_unseal_decrypt_and_verify.
g_unseal_install_mu: sync.Mutex

bridge_unseal_decrypt_and_verify :: proc(
	payload_json: string,
	local_bridge_id: string,
	current_clock_ms: i64,
) -> (ok: bool, err_msg: string) {
	bridge_unseal_init()

	payload: Bridge_Unseal_Payload
	if !vault.wire_decode(payload_json, &payload) do return false, "malformed unseal payload"
	bridge_id := payload.bridge_id
	nonce := payload.nonce
	client_pub := payload.client_public_key
	iv := payload.iv
	tag := payload.tag
	ciphertext := payload.ciphertext
	format := payload.format
	identity_echo := payload.bridge_identity_public_key
	timestamp_int, ts_ok := payload.timestamp.?
	epoch_int, epoch_ok := payload.current_epoch.?

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
	// The echo is re-rendered canonically (one encoder: vault.signature_object), so
	// the byte comparison below cannot be dodged by an equivalent spelling.
	echo := ""
	if echo_wire, has_echo := payload.unseal_key_signature.?; has_echo {
		echo, _ = vault.signature_text_from_wire(echo_wire, context.temp_allocator)
	}
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

	// Check-then-store is one critical section: two concurrent unseals must not both
	// pass the superset/floor checks against the same stored state and then install
	// in either order (a lower keyring could land last). Held through the floor and
	// keyring stores below.
	sync.mutex_lock(&g_unseal_install_mu)
	defer sync.mutex_unlock(&g_unseal_install_mu)

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
		case .Different_Vault:
			return false, "keyring belongs to another vault than the one this bridge holds (the account was reset; re-enroll this bridge)"
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
	case .Missing_Epoch:
		return false, "keyring rejected: it lacks the newest epoch this bridge accepted before"
	}
	//  (c) Signed chain to the account root (plan §1 "Bridge keyring
	//      authentication"; format and rules in lib/vault/bridge_chain.odin). The
	//      payload's `chain_proof` must show: the account genesis — equal to the root pinned in
	//      the floor record, or, on the FIRST unseal after enrollment, the root to
	//      pin now; the signed `epoch` statement for kr.current_epoch whose
	//      epoch_commit matches the delivered key, issued by an approved,
	//      approver-capable (never a bridge) device chained to that root; and this
	//      bridge's own approval by such a device. Statement user_ids prove the owner;
	//      the hub-reported owner pinned at enrollment (a) is only a consistency check
	//      against them. Missing or invalid proof → refuse, nothing installed.
	//  (d) The FIRST unseal (no root pinned yet) also needs the approver's pair_mac
	//      under this bridge's pairing code (bridge_pairing_first_pin_ok): only the
	//      device the operator typed the code into can have made it, so a hub racing
	//      the approver with its own root and keyring is refused.
	proof_value := payload.chain_proof
	if _, proof_ok := proof_value.(json.Object); !proof_ok do return false, vault.chain_error_message(.Malformed)
	root, chain_err := vault.bridge_chain_verify(proof_value, owner, our_identity, &kr, &floor.root)
	if chain_err != .None do return false, vault.chain_error_message(chain_err)
	first_pin := !floor.root.set
	if first_pin {
		if !bridge_pairing_first_pin_ok(proof_value, payload.pair_mac) {
			return false, "first unseal refused: it carries no valid pairing proof from the device this bridge's pairing code was typed into"
		}
	}
	if first_pin do floor.root = root

	raw: [vault.KEYRING_MAX_BYTES]byte
	defer crypto.zero_explicit(&raw, size_of(raw))
	bytes, ser_ok := vault.keyring_serialize_into(&kr, raw[:])
	if !ser_ok do return false, "keyring could not be serialized"
	// Raise the floor BEFORE installing: a keyring is never live without its floor.
	epoch_floor_merge(&floor, local_bridge_id, &kr)
	if !keystore_store_epoch_floor(local_bridge_id, &floor) do return false, "failed to persist the epoch floor; unseal refused"
	if first_pin {
		// The pairing code has done its job; nothing may pin again in this process.
		bridge_pairing_disarm()
		if fp, fp_ok := vault.account_fingerprint(&floor.root, context.temp_allocator); fp_ok {
			fmt.printfln("vault: pinned account root %s (fingerprint %s)", vault.root_pin_device_id(&floor.root), fp)
		}
	}
	store_ok, _ := keystore_store_vault_keyring(local_bridge_id, bytes)
	if !store_ok do return false, "failed to store unsealed vault keyring in secure keystore"

	// A new keyring: rebuild the search index under it and re-salt every PTY stream.
	bridge_task_chain_search_lock()
	bridge_pty_stream_resalt_all()
	bridge_enrollment_unseal_mark_received()
	return true, ""
}
