package vault

import "core:crypto"
import "core:crypto/sha2"
import "core:encoding/endian"

// HKR2 keyring (docs/plans/passwordless-vault.md §1):
//   "HKR2" | u16be uid_len | user_id | vault_id[8] | u32be current_epoch | u16be count |
//   count × (u32be epoch | key[32])        entries strictly ascending
//
// vault_id names the account's vault: the first 8 bytes of SHA-256 of the root's
// raw signing key (vault_id_from_root_sign_pub). A reset creates a new root and so a
// new vault id; content tokens carry it, so content from a previous vault is shown as
// such and never tried with the new keys.
//
// The struct is a fixed-size value with no heap references, so one
// keyring_wipe zeroes every byte of key material it ever held.

KEYRING_MAGIC         :: "HKR2"
KEYRING_MAX_EPOCHS    :: 64
KEYRING_MAX_USER_ID   :: 64
VAULT_ID_BYTES        :: 8
VAULT_ID_HEX_CHARS    :: VAULT_ID_BYTES * 2
KEYRING_ENTRY_BYTES   :: 4 + KEY_BYTES
KEYRING_MAX_BYTES     :: 4 + 2 + KEYRING_MAX_USER_ID + VAULT_ID_BYTES + 4 + 2 + KEYRING_MAX_EPOCHS * KEYRING_ENTRY_BYTES // 2388

Vault_Id :: [VAULT_ID_BYTES]byte

// vault_id_from_root_sign_pub = SHA-256(root_sign_pub_raw65)[0:8].
vault_id_from_root_sign_pub :: proc(root_sign_pub_hex: string) -> (id: Vault_Id, ok: bool) {
	raw: [65]byte
	if len(root_sign_pub_hex) != 130 || !is_lower_hex(root_sign_pub_hex) || !hex_decode_into(raw[:], root_sign_pub_hex) || raw[0] != 0x04 do return {}, false
	digest: [32]byte
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, raw[:])
	sha2.final(&ctx, digest[:])
	copy(id[:], digest[:VAULT_ID_BYTES])
	return id, true
}

// vault_id_hex renders the 16 lowercase hex characters used in tokens and AADs.
vault_id_hex :: proc(id: Vault_Id, buf: []byte) -> string {
	HEX := "0123456789abcdef"
	assert(len(buf) >= VAULT_ID_HEX_CHARS)
	for b, i in id {
		buf[2 * i] = HEX[b >> 4]
		buf[2 * i + 1] = HEX[b & 0x0f]
	}
	return string(buf[:VAULT_ID_HEX_CHARS])
}

// vault_id_from_hex parses exactly 16 lowercase hex characters.
vault_id_from_hex :: proc(s: string) -> (id: Vault_Id, ok: bool) {
	if len(s) != VAULT_ID_HEX_CHARS || !is_lower_hex(s) do return {}, false
	if !hex_decode_into(id[:], s) do return {}, false
	return id, true
}

Keyring_Entry :: struct {
	epoch: u32,
	key:   [KEY_BYTES]byte,
}

Vault_Keyring :: struct {
	user_id_buf:   [KEYRING_MAX_USER_ID]byte,
	user_id_len:   int,
	vault_id:      Vault_Id,
	current_epoch: u32,
	entries:       [KEYRING_MAX_EPOCHS]Keyring_Entry,
	count:         int,
}

// valid_id_value is the statement value grammar [A-Za-z0-9_.:-]; user ids must satisfy
// it because they appear verbatim inside canonical statements and AADs.
valid_id_value :: proc(s: string) -> bool {
	for i in 0 ..< len(s) {
		switch s[i] {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '_', '.', ':', '-':
		case:
			return false
		}
	}
	return true
}

keyring_user_id :: proc(kr: ^Vault_Keyring) -> string {
	return string(kr.user_id_buf[:kr.user_id_len])
}

// keyring_wipe zeroes all key material and metadata.
keyring_wipe :: proc "contextless" (kr: ^Vault_Keyring) {
	if kr == nil do return
	crypto.zero_explicit(kr, size_of(Vault_Keyring))
}

// keyring_validate checks the invariants every keyring must satisfy, however built.
keyring_validate :: proc(kr: ^Vault_Keyring) -> bool {
	if kr == nil do return false
	if kr.user_id_len < 1 || kr.user_id_len > KEYRING_MAX_USER_ID do return false
	if !valid_id_value(keyring_user_id(kr)) do return false
	if kr.vault_id == (Vault_Id{}) do return false
	if kr.count < 1 || kr.count > KEYRING_MAX_EPOCHS do return false
	prev: u32 = 0
	for i in 0 ..< kr.count {
		e := kr.entries[i].epoch
		if e == 0 || e <= prev do return false // strictly ascending: no duplicates, no reordering
		prev = e
	}
	// The current epoch is the newest entry: rotation appends current+1, and sealing
	// under anything but the newest key would write content a revoked device can read.
	if kr.current_epoch != kr.entries[kr.count - 1].epoch do return false
	return true
}

// keyring_parse decodes HKR2 bytes. With expected_user_id non-empty the keyring must
// belong to that user. On failure the returned keyring is zeroed.
keyring_parse :: proc(data: []byte, expected_user_id: string = "") -> (kr: Vault_Keyring, ok: bool) {
	defer if !ok do keyring_wipe(&kr)
	if len(data) < 4 + 2 || len(data) > KEYRING_MAX_BYTES do return
	if string(data[:4]) != KEYRING_MAGIC do return
	uid_len := int(endian.unchecked_get_u16be(data[4:6]))
	if uid_len < 1 || uid_len > KEYRING_MAX_USER_ID do return
	off := 6
	if len(data) < off + uid_len + VAULT_ID_BYTES + 4 + 2 do return
	copy(kr.user_id_buf[:], data[off:off + uid_len])
	kr.user_id_len = uid_len
	off += uid_len
	copy(kr.vault_id[:], data[off:off + VAULT_ID_BYTES])
	off += VAULT_ID_BYTES
	kr.current_epoch = endian.unchecked_get_u32be(data[off:off + 4])
	off += 4
	count := int(endian.unchecked_get_u16be(data[off:off + 2]))
	off += 2
	if count < 1 || count > KEYRING_MAX_EPOCHS do return
	if len(data) != off + count * KEYRING_ENTRY_BYTES do return // exact: no truncation, no trailing bytes
	for i in 0 ..< count {
		kr.entries[i].epoch = endian.unchecked_get_u32be(data[off:off + 4])
		copy(kr.entries[i].key[:], data[off + 4:off + KEYRING_ENTRY_BYTES])
		off += KEYRING_ENTRY_BYTES
	}
	kr.count = count
	if !keyring_validate(&kr) do return
	if expected_user_id != "" && keyring_user_id(&kr) != expected_user_id do return
	ok = true
	return
}

// keyring_serialize writes HKR2 bytes into dst (at least KEYRING_MAX_BYTES long) and
// returns the used prefix. It refuses a keyring that does not validate.
keyring_serialize_into :: proc(kr: ^Vault_Keyring, dst: []byte) -> (out: []byte, ok: bool) {
	if !keyring_validate(kr) do return nil, false
	need := 4 + 2 + kr.user_id_len + VAULT_ID_BYTES + 4 + 2 + kr.count * KEYRING_ENTRY_BYTES
	if len(dst) < need do return nil, false
	copy(dst[:4], KEYRING_MAGIC)
	endian.unchecked_put_u16be(dst[4:6], u16(kr.user_id_len))
	off := 6
	copy(dst[off:], kr.user_id_buf[:kr.user_id_len])
	off += kr.user_id_len
	copy(dst[off:off + VAULT_ID_BYTES], kr.vault_id[:])
	off += VAULT_ID_BYTES
	endian.unchecked_put_u32be(dst[off:off + 4], kr.current_epoch)
	off += 4
	endian.unchecked_put_u16be(dst[off:off + 2], u16(kr.count))
	off += 2
	for i in 0 ..< kr.count {
		endian.unchecked_put_u32be(dst[off:off + 4], kr.entries[i].epoch)
		copy(dst[off + 4:off + KEYRING_ENTRY_BYTES], kr.entries[i].key[:])
		off += KEYRING_ENTRY_BYTES
	}
	return dst[:off], true
}

// keyring_serialize allocates the HKR2 bytes. The caller must zero and free them.
keyring_serialize :: proc(kr: ^Vault_Keyring, allocator := context.allocator) -> (out: []byte, ok: bool) {
	buf: [KEYRING_MAX_BYTES]byte
	defer crypto.zero_explicit(&buf, size_of(buf))
	used, s_ok := keyring_serialize_into(kr, buf[:])
	if !s_ok do return nil, false
	out = make([]byte, len(used), allocator)
	copy(out, used)
	return out, true
}

// keyring_key_for_epoch returns a view of the epoch's key inside kr (valid while kr is).
keyring_key_for_epoch :: proc(kr: ^Vault_Keyring, epoch: u32) -> (key: []byte, ok: bool) {
	if kr == nil || epoch == 0 do return nil, false
	for i in 0 ..< kr.count {
		if kr.entries[i].epoch == epoch do return kr.entries[i].key[:], true
	}
	return nil, false
}

keyring_current_key :: proc(kr: ^Vault_Keyring) -> (key: []byte, ok: bool) {
	if kr == nil do return nil, false
	return keyring_key_for_epoch(kr, kr.current_epoch)
}

// keyring_from_single_key builds the one-epoch keyring {epoch: key} of vault `vault_id`.
keyring_from_single_key :: proc(user_id: string, vault_id: Vault_Id, epoch: u32, key: []byte) -> (kr: Vault_Keyring, ok: bool) {
	defer if !ok do keyring_wipe(&kr)
	if len(key) != KEY_BYTES || epoch == 0 do return
	if len(user_id) < 1 || len(user_id) > KEYRING_MAX_USER_ID do return
	copy(kr.user_id_buf[:], user_id)
	kr.user_id_len = len(user_id)
	kr.vault_id = vault_id
	kr.current_epoch = epoch
	kr.entries[0].epoch = epoch
	copy(kr.entries[0].key[:], key)
	kr.count = 1
	ok = keyring_validate(&kr)
	return
}

// keyring_equal compares two keyrings in constant time over their key material.
keyring_equal :: proc(a, b: ^Vault_Keyring) -> bool {
	if a == nil || b == nil do return false
	if a.count != b.count || a.current_epoch != b.current_epoch || keyring_user_id(a) != keyring_user_id(b) || a.vault_id != b.vault_id do return false
	diff := 0
	for i in 0 ..< a.count {
		if a.entries[i].epoch != b.entries[i].epoch do return false
		diff |= 1 - crypto.compare_constant_time(a.entries[i].key[:], b.entries[i].key[:])
	}
	return diff == 0
}

// Keyring_Update_Error says why a newly delivered keyring may not replace the
// stored one (plan §1 "Bridge keyring authentication", finding C1).
Keyring_Update_Error :: enum {
	None,
	Invalid,         // either keyring fails keyring_validate
	Different_User,  // the user ids differ
	Different_Vault, // the vault ids differ (a reset made a new vault)
	Epoch_Rollback,  // incoming.current_epoch < stored.current_epoch
	Missing_Epoch,   // an epoch the stored keyring holds is absent from incoming
	Key_Mismatch,    // an epoch both hold maps to different keys
}

// keyring_check_update accepts incoming only as a superset of stored: same user and
// vault, every stored epoch present with an identical key (compared in constant time),
// and no current-epoch rollback. An identical keyring is accepted.
keyring_check_update :: proc(stored, incoming: ^Vault_Keyring) -> Keyring_Update_Error {
	if !keyring_validate(stored) || !keyring_validate(incoming) do return .Invalid
	a, b := keyring_user_id(stored), keyring_user_id(incoming)
	if len(a) != len(b) || crypto.compare_constant_time(transmute([]byte)a, transmute([]byte)b) != 1 do return .Different_User
	if stored.vault_id != incoming.vault_id do return .Different_Vault
	if incoming.current_epoch < stored.current_epoch do return .Epoch_Rollback
	diff := 0
	for i in 0 ..< stored.count {
		key, ok := keyring_key_for_epoch(incoming, stored.entries[i].epoch)
		if !ok do return .Missing_Epoch
		diff |= 1 - crypto.compare_constant_time(key, stored.entries[i].key[:])
	}
	if diff != 0 do return .Key_Mismatch
	return .None
}
