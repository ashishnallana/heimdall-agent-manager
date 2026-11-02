package vault

import "core:crypto"
import "core:crypto/aes"
import "core:crypto/ecdh"
import "core:crypto/hkdf"
import "core:crypto/sha2"
import "core:encoding/base64"
import "core:encoding/endian"
import "core:strconv"
import "core:strings"

// ── Bridge unseal v2 ────────────────────────────────────────────────────────
// ECDH P-256 (browser ephemeral × bridge ephemeral) → HKDF-SHA256(zero salt,
// "heimdall-bridge-unseal-v2") → AES-256-GCM over the HKR2 keyring bytes with
// AAD "heimdall-bridge-unseal-v2|<bridge_id>|<timestamp>|<nonce>|<current_epoch>".
// There is exactly one AAD form and the plaintext must be a valid keyring.

UNSEAL_V2_INFO   :: "heimdall-bridge-unseal-v2"
UNSEAL_V2_FORMAT :: "keyring-v1"

unseal_v2_aad :: proc(bridge_id: string, timestamp_ms: i64, nonce: string, current_epoch: u32, allocator := context.allocator) -> (string, bool) {
	if bridge_id == "" || !valid_id_value(bridge_id) || nonce == "" || !valid_id_value(nonce) || current_epoch == 0 do return "", false
	ts_buf, ep_buf: [24]byte
	return strings.concatenate({UNSEAL_V2_INFO, "|", bridge_id, "|", strconv.write_int(ts_buf[:], timestamp_ms, 10), "|", nonce, "|", strconv.write_uint(ep_buf[:], u64(current_epoch), 10)}, allocator), true
}

// ecdh_hkdf_key derives the 32-byte AES key shared between priv and peer_pub_hex.
@(private)
ecdh_hkdf_key :: proc(priv: ^ecdh.Private_Key, peer_pub_hex: string, info: string, dst: []byte) -> bool {
	if len(peer_pub_hex) != P256_PUBLIC_KEY_BYTES * 2 || !is_lower_hex(peer_pub_hex) do return false
	raw: [P256_PUBLIC_KEY_BYTES]byte
	if !hex_decode_into(raw[:], peer_pub_hex) || raw[0] != 0x04 do return false
	peer: ecdh.Public_Key
	defer ecdh.public_key_clear(&peer)
	if !ecdh.public_key_set_bytes(&peer, .SECP256R1, raw[:]) do return false
	shared: [32]byte
	defer crypto.zero_explicit(&shared, size_of(shared))
	if !ecdh.ecdh(priv, &peer, shared[:]) do return false
	salt: [32]byte
	hkdf.extract_and_expand(.SHA256, salt[:], shared[:], transmute([]byte)info, dst)
	return true
}

Unseal_V2_Error :: enum {
	None,
	Bad_Public_Key,
	Bad_Parameters,
	Auth_Failed,
	Bad_Keyring,
	Epoch_Mismatch,
}

// unseal_v2_open decrypts and validates the keyring. iv/tag/ciphertext are lowercase
// hex; the keyring's current epoch must equal the signed-over current_epoch.
unseal_v2_open :: proc(
	bridge_priv: ^ecdh.Private_Key,
	client_pub_hex, iv_hex, tag_hex, ciphertext_hex: string,
	bridge_id: string, timestamp_ms: i64, nonce: string, current_epoch: u32,
) -> (kr: Vault_Keyring, err: Unseal_V2_Error) {
	aad, aad_ok := unseal_v2_aad(bridge_id, timestamp_ms, nonce, current_epoch, context.temp_allocator)
	if !aad_ok do return {}, .Bad_Parameters
	iv: [NONCE_BYTES]byte
	tag: [TAG_BYTES]byte
	if !hex_decode_into(iv[:], iv_hex) || !is_lower_hex(iv_hex) do return {}, .Bad_Parameters
	if !hex_decode_into(tag[:], tag_hex) || !is_lower_hex(tag_hex) do return {}, .Bad_Parameters
	if len(ciphertext_hex) == 0 || len(ciphertext_hex) % 2 != 0 || len(ciphertext_hex) > KEYRING_MAX_BYTES * 2 || !is_lower_hex(ciphertext_hex) do return {}, .Bad_Parameters
	ct := make([]byte, len(ciphertext_hex) / 2, context.temp_allocator)
	if !hex_decode_into(ct, ciphertext_hex) do return {}, .Bad_Parameters
	key: [32]byte
	defer crypto.zero_explicit(&key, size_of(key))
	if !ecdh_hkdf_key(bridge_priv, client_pub_hex, UNSEAL_V2_INFO, key[:]) do return {}, .Bad_Public_Key
	plain: [KEYRING_MAX_BYTES]byte
	defer crypto.zero_explicit(&plain, size_of(plain))
	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, key[:])
	defer aes.reset_gcm(&gcm)
	if !aes.open_gcm(&gcm, plain[:len(ct)], iv[:], transmute([]byte)aad, ct, tag[:]) do return {}, .Auth_Failed
	parsed, ok := keyring_parse(plain[:len(ct)])
	if !ok do return {}, .Bad_Keyring
	if parsed.current_epoch != current_epoch {
		keyring_wipe(&parsed)
		return {}, .Epoch_Mismatch
	}
	return parsed, .None
}

// unseal_v2_seal is the browser side, used by Odin tests to drive the bridge.
unseal_v2_seal :: proc(
	client_priv: ^ecdh.Private_Key, bridge_pub_hex: string, iv: []byte, kr: ^Vault_Keyring,
	bridge_id: string, timestamp_ms: i64, nonce: string,
	allocator := context.allocator,
) -> (ciphertext_hex: string, tag_hex: string, ok: bool) {
	if len(iv) != NONCE_BYTES do return
	aad, aad_ok := unseal_v2_aad(bridge_id, timestamp_ms, nonce, kr.current_epoch, context.temp_allocator)
	if !aad_ok do return
	key: [32]byte
	defer crypto.zero_explicit(&key, size_of(key))
	if !ecdh_hkdf_key(client_priv, bridge_pub_hex, UNSEAL_V2_INFO, key[:]) do return
	buf: [KEYRING_MAX_BYTES]byte
	defer crypto.zero_explicit(&buf, size_of(buf))
	plain, s_ok := keyring_serialize_into(kr, buf[:])
	if !s_ok do return
	ct := make([]byte, len(plain), context.temp_allocator)
	tag: [TAG_BYTES]byte
	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, key[:])
	defer aes.reset_gcm(&gcm)
	aes.seal_gcm(&gcm, ct, tag[:], iv, transmute([]byte)aad, plain)
	return hex_encode_lower(ct, allocator), hex_encode_lower(tag[:], allocator), true
}

// ── Keyring wrap (hub-stored, one per recipient) ────────────────────────────

WRAP_INFO :: "heimdall-keyring-wrap-v1"

Keyring_Wrap :: struct {
	alg:                  string,
	recipient_device_id:  string,
	directory_version:    u64,
	current_epoch:        u32,
	ephemeral_public_key: string, // hex
	iv:                   string, // hex
	ciphertext:           string, // hex ct||tag
	wrapped_by_device_id: string,
}

wrap_aad :: proc(user_id, recipient_device_id: string, directory_version: u64, current_epoch: u32, allocator := context.allocator) -> (string, bool) {
	if !valid_id_value(user_id) || user_id == "" || !valid_id_value(recipient_device_id) || recipient_device_id == "" do return "", false
	v_buf, e_buf: [24]byte
	return strings.concatenate({WRAP_INFO, "|", user_id, "|", recipient_device_id, "|", strconv.write_uint(v_buf[:], directory_version, 10), "|", strconv.write_uint(e_buf[:], u64(current_epoch), 10)}, allocator), true
}

// wrap_canonical_json renders the wrap without its signature, in the fixed key order
// that wrap_sha256 is computed over. Every string member is restricted to the
// statement grammar, so no JSON escaping is ever needed.
wrap_canonical_json :: proc(w: ^Keyring_Wrap, allocator := context.allocator) -> (string, bool) {
	if wrap_alg_from_id(w.alg) == .Unknown do return "", false
	for s in ([]string{w.recipient_device_id, w.ephemeral_public_key, w.iv, w.ciphertext, w.wrapped_by_device_id}) {
		if !valid_id_value(s) do return "", false
	}
	v_buf, e_buf: [24]byte
	return strings.concatenate({
		`{"v":1,"alg":"`, w.alg,
		`","recipient_device_id":"`, w.recipient_device_id,
		`","directory_version":`, strconv.write_uint(v_buf[:], w.directory_version, 10),
		`,"current_epoch":`, strconv.write_uint(e_buf[:], u64(w.current_epoch), 10),
		`,"ephemeral_public_key":"`, w.ephemeral_public_key,
		`","iv":"`, w.iv,
		`","ciphertext":"`, w.ciphertext,
		`","wrapped_by_device_id":"`, w.wrapped_by_device_id,
		`"}`,
	}, allocator), true
}

wrap_sha256 :: proc(w: ^Keyring_Wrap, dst: []byte) -> bool {
	if len(dst) != 32 do return false
	canonical, ok := wrap_canonical_json(w, context.temp_allocator)
	if !ok do return false
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]byte)canonical)
	sha2.final(&ctx, dst)
	return true
}

// wrap_open unwraps with the recipient's key, dispatching on w.alg through the wrap
// allowlist. The unwrapped keyring must belong to user_id and match current_epoch.
wrap_open :: proc(w: ^Keyring_Wrap, user_id: string, recipient_ecdh_priv: ^ecdh.Private_Key) -> (kr: Vault_Keyring, ok: bool) {
	switch wrap_alg_from_id(w.alg) {
	case .Ecdh_P256_Hkdf_Sha256_Aes256gcm:
		aad, aad_ok := wrap_aad(user_id, w.recipient_device_id, w.directory_version, w.current_epoch, context.temp_allocator)
		if !aad_ok do return {}, false
		iv: [NONCE_BYTES]byte
		if !is_lower_hex(w.iv) || !hex_decode_into(iv[:], w.iv) do return {}, false
		if len(w.ciphertext) % 2 != 0 || len(w.ciphertext) < TAG_BYTES * 2 || len(w.ciphertext) > (KEYRING_MAX_BYTES + TAG_BYTES) * 2 || !is_lower_hex(w.ciphertext) do return {}, false
		raw := make([]byte, len(w.ciphertext) / 2, context.temp_allocator)
		if !hex_decode_into(raw, w.ciphertext) do return {}, false
		ct, tag := raw[:len(raw) - TAG_BYTES], raw[len(raw) - TAG_BYTES:]
		key: [32]byte
		defer crypto.zero_explicit(&key, size_of(key))
		if !ecdh_hkdf_key(recipient_ecdh_priv, w.ephemeral_public_key, WRAP_INFO, key[:]) do return {}, false
		plain: [KEYRING_MAX_BYTES]byte
		defer crypto.zero_explicit(&plain, size_of(plain))
		gcm: aes.Context_GCM
		aes.init_gcm(&gcm, key[:])
		defer aes.reset_gcm(&gcm)
		if !aes.open_gcm(&gcm, plain[:len(ct)], iv[:], transmute([]byte)aad, ct, tag) do return {}, false
		parsed, p_ok := keyring_parse(plain[:len(ct)], user_id)
		defer keyring_wipe(&parsed)
		if !p_ok do return {}, false
		if parsed.current_epoch != w.current_epoch {
			keyring_wipe(&parsed)
			return {}, false
		}
		return parsed, true
	case .Unknown:
		return {}, false
	}
	return {}, false
}

// ── PTY payload v2 ──────────────────────────────────────────────────────────
// Frame: u32be epoch | salt16 | nonce12 | tag16 | ct.
// Per-stream, per-direction subkey:
//   HKDF-SHA256(ikm = epoch key, salt = salt16, info = "heimdall-pty-v2|<session_id>|<out|in>").
// The nonce is u32be(0) | u64be(counter) under that subkey; the counter starts at 1
// and never repeats under one salt, and every stream (or epoch change) draws a fresh
// CSPRNG salt, so a (subkey, nonce) pair is never reused.
// AAD: "heimdall-pty-v2|e<epoch>|<session_id>|out" for output, and
//      "heimdall-pty-v2|e<epoch>|<session_id>|in|<counter>|<boot_id>" for input, so the
// receiver can enforce a strictly increasing per-session input counter (replay
// defence) and, through its unseal boot_id, refuse any frame captured before it last
// restarted (its in-memory counter state is gone then).

PTY_V2_INFO         :: "heimdall-pty-v2"
PTY_V2_SALT_BYTES   :: 16
PTY_V2_HEADER_BYTES :: 4 + PTY_V2_SALT_BYTES + HEADER_BYTES // 48

Pty_Direction :: enum {
	Out,
	In,
}

@(private)
pty_dir_name :: proc(dir: Pty_Direction) -> string {
	return "out" if dir == .Out else "in"
}

// pty_session_id_valid: a PTY session id is a non-empty statement-grammar value, so it
// can never smuggle a '|' into the AAD or HKDF info.
pty_session_id_valid :: proc(session_id: string) -> bool {
	return session_id != "" && len(session_id) <= 256 && valid_id_value(session_id)
}

// pty_aad builds the frame AAD. Input frames require counter >= 1 and the receiving
// bridge's unseal boot_id (non-empty, id grammar) and bind both; output frames ignore
// them.
pty_aad :: proc(epoch: u32, session_id: string, dir: Pty_Direction, counter: u64 = 0, boot_id: string = "", allocator := context.allocator) -> (aad: string, ok: bool) {
	if epoch == 0 || !pty_session_id_valid(session_id) do return "", false
	e_buf, c_buf: [24]byte
	if dir == .In {
		if counter == 0 || !pty_session_id_valid(boot_id) do return "", false
		return strings.concatenate({PTY_V2_INFO, "|e", strconv.write_uint(e_buf[:], u64(epoch), 10), "|", session_id, "|in|", strconv.write_uint(c_buf[:], counter, 10), "|", boot_id}, allocator), true
	}
	return strings.concatenate({PTY_V2_INFO, "|e", strconv.write_uint(e_buf[:], u64(epoch), 10), "|", session_id, "|out"}, allocator), true
}

// pty_subkey_derive writes the per-stream subkey for (epoch key, salt, session, dir).
pty_subkey_derive :: proc(epoch_key: []byte, salt: []byte, session_id: string, dir: Pty_Direction, dst: []byte) -> bool {
	if len(epoch_key) != KEY_BYTES || len(salt) != PTY_V2_SALT_BYTES || len(dst) != KEY_BYTES do return false
	if !pty_session_id_valid(session_id) do return false
	info := strings.concatenate({PTY_V2_INFO, "|", session_id, "|", pty_dir_name(dir)}, context.temp_allocator)
	hkdf.extract_and_expand(.SHA256, salt, epoch_key, transmute([]byte)info, dst)
	return true
}

// pty_nonce_from_counter renders the 12-byte nonce u32be(0) | u64be(counter).
pty_nonce_from_counter :: proc(counter: u64) -> (nonce: [NONCE_BYTES]byte) {
	endian.unchecked_put_u64be(nonce[4:], counter)
	return
}

PTY_V2_NONCE_OFFSET :: 4 + PTY_V2_SALT_BYTES

// pty_seal writes a v2 frame under the subkey derived from epoch_key and salt. The
// caller owns counter uniqueness: one salt, strictly increasing counters from 1.
pty_seal :: proc(plaintext: []byte, epoch_key: []byte, epoch: u32, salt: []byte, counter: u64, session_id: string, dir: Pty_Direction, boot_id: string = "", allocator := context.allocator) -> (frame: []byte, ok: bool) {
	if counter == 0 || len(salt) != PTY_V2_SALT_BYTES do return nil, false
	aad, aad_ok := pty_aad(epoch, session_id, dir, counter, boot_id, context.temp_allocator)
	if !aad_ok do return nil, false
	subkey: [KEY_BYTES]byte
	defer crypto.zero_explicit(&subkey, size_of(subkey))
	if !pty_subkey_derive(epoch_key, salt, session_id, dir, subkey[:]) do return nil, false
	nonce := pty_nonce_from_counter(counter)
	frame = make([]byte, PTY_V2_HEADER_BYTES + len(plaintext), allocator)
	endian.unchecked_put_u32be(frame[:4], epoch)
	copy(frame[4:PTY_V2_NONCE_OFFSET], salt)
	copy(frame[PTY_V2_NONCE_OFFSET:PTY_V2_NONCE_OFFSET + NONCE_BYTES], nonce[:])
	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, subkey[:])
	defer aes.reset_gcm(&gcm)
	aes.seal_gcm(&gcm, frame[PTY_V2_HEADER_BYTES:], frame[PTY_V2_NONCE_OFFSET + NONCE_BYTES:PTY_V2_HEADER_BYTES], nonce[:], transmute([]byte)aad, plaintext)
	return frame, true
}

pty_frame_epoch :: proc(frame: []byte) -> (epoch: u32, ok: bool) {
	if len(frame) < PTY_V2_HEADER_BYTES do return 0, false
	epoch = endian.unchecked_get_u32be(frame[:4])
	return epoch, epoch != 0
}

// pty_frame_salt_counter reads the salt and the nonce counter of a frame. A nonce whose
// leading four bytes are not zero, or whose counter is 0, is not a v2 nonce.
pty_frame_salt_counter :: proc(frame: []byte) -> (salt: [PTY_V2_SALT_BYTES]byte, counter: u64, ok: bool) {
	if len(frame) < PTY_V2_HEADER_BYTES do return
	copy(salt[:], frame[4:PTY_V2_NONCE_OFFSET])
	n := frame[PTY_V2_NONCE_OFFSET:PTY_V2_NONCE_OFFSET + NONCE_BYTES]
	if n[0] != 0 || n[1] != 0 || n[2] != 0 || n[3] != 0 do return
	counter = endian.unchecked_get_u64be(n[4:])
	return salt, counter, counter != 0
}

// pty_open authenticates a v2 frame with the key for the epoch in its header. With
// require_epoch non-zero (the bridge's command floor) any other epoch is rejected
// before decryption. On success it also returns the frame's salt and counter, which
// an input receiver feeds to pty_replay_accept.
pty_open :: proc(frame: []byte, kr: ^Vault_Keyring, session_id: string, dir: Pty_Direction, require_epoch: u32 = 0, boot_id: string = "", allocator := context.allocator) -> (plaintext: []byte, salt: [PTY_V2_SALT_BYTES]byte, counter: u64, ok: bool) {
	epoch, e_ok := pty_frame_epoch(frame)
	if !e_ok || kr == nil do return
	if require_epoch != 0 && epoch != require_epoch do return
	s, c, sc_ok := pty_frame_salt_counter(frame)
	if !sc_ok do return
	key, k_ok := keyring_key_for_epoch(kr, epoch)
	if !k_ok do return
	aad, aad_ok := pty_aad(epoch, session_id, dir, c, boot_id, context.temp_allocator)
	if !aad_ok do return
	subkey: [KEY_BYTES]byte
	defer crypto.zero_explicit(&subkey, size_of(subkey))
	if !pty_subkey_derive(key, s[:], session_id, dir, subkey[:]) do return
	ct := frame[PTY_V2_HEADER_BYTES:]
	dst := make([]byte, len(ct), allocator)
	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, subkey[:])
	defer aes.reset_gcm(&gcm)
	if !aes.open_gcm(&gcm, dst, frame[PTY_V2_NONCE_OFFSET:PTY_V2_NONCE_OFFSET + NONCE_BYTES], transmute([]byte)aad, ct, frame[PTY_V2_NONCE_OFFSET + NONCE_BYTES:PTY_V2_HEADER_BYTES]) {
		delete(dst, allocator)
		return
	}
	return dst, s, c, true
}

// ── PTY input replay window (finding M1) ────────────────────────────────────
// Per session, the receiver remembers the last accepted counter for up to
// PTY_REPLAY_SALTS recent salts. A known salt accepts only a strictly larger counter.
// A new salt (a new sender stream, hence a new subkey) starts fresh, but its counter
// must exceed `floor`, the highest counter of any salt evicted from the table, so an
// evicted stream's frames can never be replayed. Senders seed their counter from the
// wall clock (milliseconds x 1000) so a later stream starts above earlier ones.
// Call only AFTER the frame authenticated, so forged frames cannot move the state.

PTY_REPLAY_SALTS :: 8

Pty_Replay_Entry :: struct {
	salt: [PTY_V2_SALT_BYTES]byte,
	last: u64,
	used: bool,
}

Pty_Input_Replay :: struct {
	entries: [PTY_REPLAY_SALTS]Pty_Replay_Entry,
	floor:   u64,
}

pty_replay_accept :: proc(r: ^Pty_Input_Replay, salt: [PTY_V2_SALT_BYTES]byte, counter: u64) -> bool {
	if r == nil || counter == 0 do return false
	free_slot, oldest := -1, -1
	for i in 0 ..< PTY_REPLAY_SALTS {
		e := &r.entries[i]
		if !e.used {
			if free_slot < 0 do free_slot = i
			continue
		}
		if e.salt == salt {
			if counter <= e.last do return false
			e.last = counter
			return true
		}
		if oldest < 0 || e.last < r.entries[oldest].last do oldest = i
	}
	if counter <= r.floor do return false
	slot := free_slot
	if slot < 0 {
		slot = oldest
		r.floor = max(r.floor, r.entries[oldest].last)
	}
	r.entries[slot] = Pty_Replay_Entry{salt = salt, last = counter, used = true}
	return true
}

// ── Search key v2 ───────────────────────────────────────────────────────────

SEARCH_V2_DOMAIN :: "heimdall/task-chain-search-rpc/v2"
SEARCH_V2_PREFIX :: "search:v2:e"

// search_key_derive = HKDF-SHA256(ikm = epoch key, salt = domain, info = domain|e<epoch>).
search_key_derive :: proc(epoch_key: []byte, epoch: u32, dst: []byte) -> bool {
	if len(epoch_key) != KEY_BYTES || len(dst) != 32 || epoch == 0 do return false
	e_buf: [16]byte
	info := strings.concatenate({SEARCH_V2_DOMAIN, "|e", strconv.write_uint(e_buf[:], u64(epoch), 10)}, context.temp_allocator)
	hkdf.extract_and_expand(.SHA256, transmute([]byte)string(SEARCH_V2_DOMAIN), epoch_key, transmute([]byte)info, dst)
	return true
}

// search_aad fails closed unless every identifier is a non-empty statement-grammar
// value (so no '|' can shift fields) and direction is request or response.
search_aad :: proc(owner_user_id, bridge_id, request_id, direction: string, expires_at_ms: i64, epoch: u32, allocator := context.allocator) -> (aad: string, ok: bool) {
	for s in ([]string{owner_user_id, bridge_id, request_id}) {
		if s == "" || len(s) > 256 || !valid_id_value(s) do return "", false
	}
	if direction != "request" && direction != "response" do return "", false
	if epoch == 0 do return "", false
	x_buf, e_buf: [24]byte
	return strings.concatenate({SEARCH_V2_DOMAIN, "|", owner_user_id, "|", bridge_id, "|", request_id, "|", direction, "|", strconv.write_int(x_buf[:], expires_at_ms, 10), "|e", strconv.write_uint(e_buf[:], u64(epoch), 10)}, allocator), true
}

// search_envelope_parse splits "search:v2:e<epoch>:<b64(nonce|tag|ct)>".
search_envelope_parse :: proc(envelope: string, allocator := context.allocator) -> (epoch: u32, payload: []byte, ok: bool) {
	if !strings.has_prefix(envelope, SEARCH_V2_PREFIX) do return 0, nil, false
	rest := envelope[len(SEARCH_V2_PREFIX):]
	colon := strings.index_byte(rest, ':')
	if colon < 0 do return 0, nil, false
	ep, ep_ok := parse_epoch(rest[:colon])
	if !ep_ok do return 0, nil, false
	decoded, d_ok := b64_decode_strict(rest[colon + 1:], allocator)
	if !d_ok do return 0, nil, false
	if len(decoded) < HEADER_BYTES {
		delete(decoded, allocator)
		return 0, nil, false
	}
	return ep, decoded, true
}

// search_seal_with_nonce seals an RPC body under the epoch's search key.
search_seal_with_nonce :: proc(plaintext: []byte, epoch_key: []byte, epoch: u32, aad: string, nonce: []byte, allocator := context.allocator) -> (envelope: string, ok: bool) {
	if len(nonce) != NONCE_BYTES do return "", false
	key: [32]byte
	defer crypto.zero_explicit(&key, size_of(key))
	if !search_key_derive(epoch_key, epoch, key[:]) do return "", false
	payload := make([]byte, HEADER_BYTES + len(plaintext), context.temp_allocator)
	copy(payload[:NONCE_BYTES], nonce)
	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, key[:])
	defer aes.reset_gcm(&gcm)
	aes.seal_gcm(&gcm, payload[HEADER_BYTES:], payload[NONCE_BYTES:HEADER_BYTES], nonce, transmute([]byte)aad, plaintext)
	b64, err := base64.encode(payload, allocator = context.temp_allocator)
	if err != nil do return "", false
	e_buf: [16]byte
	return strings.concatenate({SEARCH_V2_PREFIX, strconv.write_uint(e_buf[:], u64(epoch), 10), ":", b64}, allocator), true
}

// search_open_payload authenticates nonce|tag|ct under the epoch's search key.
search_open_payload :: proc(payload: []byte, epoch_key: []byte, epoch: u32, aad: string, allocator := context.allocator) -> (plaintext: []byte, ok: bool) {
	if len(payload) < HEADER_BYTES do return nil, false
	key: [32]byte
	defer crypto.zero_explicit(&key, size_of(key))
	if !search_key_derive(epoch_key, epoch, key[:]) do return nil, false
	ct := payload[HEADER_BYTES:]
	dst := make([]byte, len(ct), allocator)
	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, key[:])
	defer aes.reset_gcm(&gcm)
	if !aes.open_gcm(&gcm, dst, payload[:NONCE_BYTES], transmute([]byte)aad, ct, payload[NONCE_BYTES:HEADER_BYTES]) {
		delete(dst, allocator)
		return nil, false
	}
	return dst, true
}

// ── File write v3 (finding N4, P4 root binding) ─────────────────────────────
// File content the browser sends for a bridge to write uses the v2 token format
// (vault:v2:<vault_id>:e<epoch>:b64(nonce12|tag16|ct)) under the epoch key, but with
// its own AAD
//   "heimdall-fs-write-v3|<vault_id>|e<epoch>|<bridge_id>|<hex sha256(root)>|<hex sha256(path)>"
// so a write is bound to one vault, one bridge, one sandbox ROOT (the canonical root
// directory the bridge resolves for the request, as its fs results report it) and one
// target path (the path string exactly as the request names it). A sealed write
// captured for project A cannot be replayed into project B on the same bridge. A
// content envelope never opens here and vice versa.

FS_WRITE_INFO :: "heimdall-fs-write-v3"

@(private)
sha256_hex :: proc(s: string, allocator := context.temp_allocator) -> string {
	digest: [32]byte
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]byte)s)
	sha2.final(&ctx, digest[:])
	return hex_encode_lower(digest[:], allocator)
}

fs_write_aad :: proc(vault_id: Vault_Id, epoch: u32, bridge_id, root, path: string, allocator := context.allocator) -> (aad: string, ok: bool) {
	if epoch == 0 || vault_id == (Vault_Id{}) || bridge_id == "" || len(bridge_id) > 256 || !valid_id_value(bridge_id) || root == "" || path == "" do return "", false
	e_buf: [16]byte
	v_buf: [VAULT_ID_HEX_CHARS]byte
	return strings.concatenate({FS_WRITE_INFO, "|", vault_id_hex(vault_id, v_buf[:]), "|e", strconv.write_uint(e_buf[:], u64(epoch), 10), "|", bridge_id, "|", sha256_hex(root), "|", sha256_hex(path)}, allocator), true
}

// fs_write_seal_with_nonce is the deterministic core (vectors); production sealing
// happens in the browser.
fs_write_seal_with_nonce :: proc(plaintext: []byte, key: []byte, vault_id: Vault_Id, epoch: u32, bridge_id, root, path: string, nonce: []byte, allocator := context.allocator) -> (token: string, ok: bool) {
	aad, aad_ok := fs_write_aad(vault_id, epoch, bridge_id, root, path, context.temp_allocator)
	if !aad_ok do return "", false
	return seal_with_nonce_aad(plaintext, key, vault_id, epoch, nonce, transmute([]byte)aad, allocator)
}

// fs_write_open authenticates a file-write token for (bridge_id, root, path) in kr's
// vault. With require_epoch non-zero (the bridge's command floor) any other epoch is
// refused.
fs_write_open :: proc(token: string, kr: ^Vault_Keyring, bridge_id, root, path: string, require_epoch: u32 = 0, allocator := context.allocator) -> (plaintext: []byte, ok: bool) {
	if kr == nil do return nil, false
	vault_id, epoch, payload, res := envelope_parse(token, context.temp_allocator)
	if res != .Ok do return nil, false
	defer crypto.zero_explicit(raw_data(payload), len(payload))
	if vault_id != kr.vault_id do return nil, false
	if require_epoch != 0 && epoch != require_epoch do return nil, false
	key, key_ok := keyring_key_for_epoch(kr, epoch)
	if !key_ok do return nil, false
	aad, aad_ok := fs_write_aad(vault_id, epoch, bridge_id, root, path, context.temp_allocator)
	if !aad_ok do return nil, false
	return open_payload_with_key_aad(payload, key, transmute([]byte)aad, allocator)
}
