package main

// OS-independent half of the bridge keystore (passwordless vault P1).
//
// Two secrets are kept per bridge, each in its own OS item (keystore_os_* in the
// per-OS files, addressed by Keystore_Slot + bridge_id):
//
//   - .Keyring  — the binary HKR2 keyring (lib/vault), at most
//     vault.KEYRING_MAX_BYTES = 2388 bytes, which fits the Windows Credential
//     Manager's 2560-byte blob limit. Lock purges it.
//   - .Identity — the bridge's enrollment record: its persistent ECDSA P-256
//     identity scalar and the enrolled owner's user id (see below). The scalar
//     signs each boot's ephemeral unseal key. Lock KEEPS it (a locked bridge is
//     still the same bridge); vault.reset and an aborted enrollment delete it, so a
//     re-enrolled bridge never reuses an identity a human approved for a previous
//     enrollment.
//
// The hot path is an mlock'd in-memory copy of the keyring tagged with the bridge
// id it belongs to; it is filled on store and on the first persisted read.
//
// Everything fails closed: a blob that does not parse as a valid keyring is "no
// keyring", never a partially applied one.

import "core:crypto"
import "core:fmt"
import "core:mem"
import "core:sync"
import vault "odin_test:lib/vault"

Keystore_Slot :: enum {
	Keyring,
	Identity,
	Epoch_Floor, // highest accepted current epoch + per-epoch key commitments
	// The previous enrollment's .Identity / .Epoch_Floor, kept verbatim while a
	// re-enrollment of the SAME bridge id is not yet committed (reenroll_identity.odin):
	// restored if it rolls back, dropped once it commits.
	Identity_Previous,
	Epoch_Floor_Previous,
}

KEYSTORE_IDENTITY_KEY_BYTES :: vault.P256_PRIVATE_KEY_BYTES

g_keystore_in_memory_buffer: Secure_Key
g_keystore_in_memory_set: bool
g_keystore_mu: sync.Mutex
@(private = "file")
g_keystore_in_memory_owner_buf: [128]u8
@(private = "file")
g_keystore_in_memory_owner_len: int

// Caller holds g_keystore_mu.
@(private = "file")
keystore_wipe_in_memory_locked :: proc() {
	if g_keystore_in_memory_set {
		secure_key_wipe_and_free(&g_keystore_in_memory_buffer)
		g_keystore_in_memory_set = false
	}
	g_keystore_in_memory_owner_len = 0
}

// keystore_store_in_memory_vault_keyring keeps a validated copy of bridge_id's HKR2
// keyring in locked memory.
keystore_store_in_memory_vault_keyring :: proc(bridge_id: string, data: []byte) -> bool {
	kr, ok := vault.keyring_parse(data)
	vault.keyring_wipe(&kr)
	if !ok || len(bridge_id) == 0 || len(bridge_id) > len(g_keystore_in_memory_owner_buf) do return false

	sync.mutex_lock(&g_keystore_mu)
	defer sync.mutex_unlock(&g_keystore_mu)
	keystore_wipe_in_memory_locked()
	key, alloc_ok := secure_key_alloc(len(data))
	if !alloc_ok do return false
	mem.copy(rawptr(key.ptr), raw_data(data), len(data))
	g_keystore_in_memory_buffer = key
	g_keystore_in_memory_set = true
	copy(g_keystore_in_memory_owner_buf[:], bridge_id)
	g_keystore_in_memory_owner_len = len(bridge_id)
	return true
}

// keystore_read_in_memory_vault_keyring returns the cached keyring only when it
// was stored for bridge_id. The caller wipes the result.
keystore_read_in_memory_vault_keyring :: proc(bridge_id: string) -> (kr: vault.Vault_Keyring, ok: bool) {
	sync.mutex_lock(&g_keystore_mu)
	defer sync.mutex_unlock(&g_keystore_mu)
	if !g_keystore_in_memory_set || g_keystore_in_memory_buffer.ptr == nil do return {}, false
	if string(g_keystore_in_memory_owner_buf[:g_keystore_in_memory_owner_len]) != bridge_id do return {}, false
	return vault.keyring_parse(g_keystore_in_memory_buffer.ptr[:g_keystore_in_memory_buffer.len])
}

keystore_wipe_in_memory_vault_key :: proc() {
	sync.mutex_lock(&g_keystore_mu)
	defer sync.mutex_unlock(&g_keystore_mu)
	keystore_wipe_in_memory_locked()
}

// keystore_store_vault_keyring persists bridge_id's keyring in the OS store and
// caches it in memory. When the OS store refuses, desktop backends keep the
// memory copy (this process stays unsealed, a restart starts locked) and report
// the OS error; the Android backend requires persistence and stores nothing.
keystore_store_vault_keyring :: proc(bridge_id: string, data: []byte) -> (ok: bool, err_code: int) {
	kr, parsed := vault.keyring_parse(data)
	vault.keyring_wipe(&kr)
	if !parsed do return false, -1
	if !keystore_bridge_id_ok(bridge_id) do return false, KEYSTORE_ERR_BAD_BRIDGE_ID

	status := keystore_backend_write(.Keyring, bridge_id, data)
	if status != 0 && keystore_os_requires_persistence() do return false, status
	mem_ok := keystore_store_in_memory_vault_keyring(bridge_id, data)
	if status != 0 {
		fmt.eprintfln(
			"WARN: the OS keystore refused to store the vault keyring (error %d). Falling back to process-isolated memory; the keyring will not survive a restart.",
			status,
		)
		return mem_ok, status
	}
	return mem_ok, 0
}

// keystore_read_persisted_vault_keyring reads the OS store only, bypassing the
// memory cache: it answers "would a restarted bridge find this keyring?".
keystore_read_persisted_vault_keyring :: proc(bridge_id: string) -> (kr: vault.Vault_Keyring, ok: bool) {
	if !keystore_bridge_id_ok(bridge_id) do return {}, false
	buf: [vault.KEYRING_MAX_BYTES]byte
	defer crypto.zero_explicit(&buf, size_of(buf))
	n, read_ok := keystore_backend_read_ok(.Keyring, bridge_id, buf[:])
	if !read_ok do return {}, false
	return vault.keyring_parse(buf[:n])
}

// keystore_read_vault_keyring is the normal read: memory first, then the OS store
// (which then refills the memory cache).
keystore_read_vault_keyring :: proc(bridge_id: string) -> (kr: vault.Vault_Keyring, ok: bool) {
	if cached, hit := keystore_read_in_memory_vault_keyring(bridge_id); hit do return cached, true
	if !keystore_bridge_id_ok(bridge_id) do return {}, false
	buf: [vault.KEYRING_MAX_BYTES]byte
	defer crypto.zero_explicit(&buf, size_of(buf))
	n, read_ok := keystore_backend_read_ok(.Keyring, bridge_id, buf[:])
	if !read_ok do return {}, false
	kr, ok = vault.keyring_parse(buf[:n])
	if ok do _ = keystore_store_in_memory_vault_keyring(bridge_id, buf[:n])
	return
}

// keystore_unlink_vault_key deletes bridge_id's persisted keyring and wipes the
// memory copy. Returns true when no persisted keyring remains.
keystore_unlink_vault_key :: proc(bridge_id: string) -> bool {
	keystore_wipe_in_memory_vault_key()
	if !keystore_bridge_id_ok(bridge_id) do return true
	return keystore_backend_delete(.Keyring, bridge_id)
}

// keystore_lock_and_purge purges the keyring (persisted and in memory). The
// identity key is deliberately kept; see the file header.
keystore_lock_and_purge :: proc(bridge_id: string) {
	_ = keystore_unlink_vault_key(bridge_id)
	keystore_wipe_in_memory_vault_key()
}

// ── Identity record ─────────────────────────────────────────────────────────
//
// The .Identity slot holds this bridge's enrollment record, written once at
// enrollment (bridge_unseal_identity_commit_enrollment) and never regenerated:
//
//   "HBI2" | u8 owner_len | owner_user_id | u8 hub_len | hub_base | scalar[32]
//
// owner_user_id is the account that approved the enrollment; an unseal is only
// accepted for a keyring of that user (plan §1, finding C1). hub_base is the
// canonical base of the hub it was enrolled with: a record whose hub differs from the
// hub this process is bound to is .Error (fail closed), never used. Every backend keeps
// it across a reboot (finding H1): Credential Manager, the login Keychain, a 0600
// file in the bridge's private directory on Linux, the sealed file under Termux.

BRIDGE_IDENTITY_RECORD_MAGIC :: "HBI2"
BRIDGE_IDENTITY_RECORD_MAX_BYTES :: 4 + 1 + vault.KEYRING_MAX_USER_ID + 1 + BRIDGE_HUB_BASE_MAX + KEYSTORE_IDENTITY_KEY_BYTES

Bridge_Identity_Record :: struct {
	scalar:    [KEYSTORE_IDENTITY_KEY_BYTES]byte,
	owner_buf: [vault.KEYRING_MAX_USER_ID]byte,
	owner_len: int,
	hub_buf:   [BRIDGE_HUB_BASE_MAX]byte,
	hub_len:   int,
}

bridge_identity_record_hub :: proc(rec: ^Bridge_Identity_Record) -> string {
	return string(rec.hub_buf[:rec.hub_len])
}

bridge_identity_record_owner :: proc(rec: ^Bridge_Identity_Record) -> string {
	return string(rec.owner_buf[:rec.owner_len])
}

// Keystore_Read_Status separates "nothing stored" from "stored but unreadable":
// callers must never treat an error as absence (finding H1).
Keystore_Read_Status :: enum {
	Found,
	Not_Found,
	Error,
}

// keystore_backend_read_ok is the boolean view of keystore_backend_read.
keystore_backend_read_ok :: proc(slot: Keystore_Slot, bridge_id: string, dst: []byte) -> (n: int, ok: bool) {
	got, status := keystore_backend_read(slot, bridge_id, dst)
	if status != .Found do return 0, false
	return got, true
}

// keystore_store_identity writes the record for the hub this process is bound to.
keystore_store_identity :: proc(bridge_id: string, scalar: []byte, owner_user_id: string) -> bool {
	if len(scalar) != KEYSTORE_IDENTITY_KEY_BYTES || !keystore_bridge_id_ok(bridge_id) do return false
	if len(owner_user_id) < 1 || len(owner_user_id) > vault.KEYRING_MAX_USER_ID || !vault.valid_id_value(owner_user_id) do return false
	hub := bridge_keystore_hub()
	if hub == "" || len(hub) > BRIDGE_HUB_BASE_MAX do return false
	buf: [BRIDGE_IDENTITY_RECORD_MAX_BYTES]byte
	defer crypto.zero_explicit(&buf, size_of(buf))
	copy(buf[:4], BRIDGE_IDENTITY_RECORD_MAGIC)
	buf[4] = u8(len(owner_user_id))
	copy(buf[5:], owner_user_id)
	off := 5 + len(owner_user_id)
	buf[off] = u8(len(hub))
	copy(buf[off + 1:], hub)
	off += 1 + len(hub)
	copy(buf[off:], scalar)
	return keystore_backend_write(.Identity, bridge_id, buf[:off + KEYSTORE_IDENTITY_KEY_BYTES]) == 0
}

// keystore_read_identity reads the enrollment record. A record that exists but
// does not parse (including a bare scalar from before owners were recorded) is
// .Error, never .Not_Found.
keystore_read_identity :: proc(bridge_id: string, rec: ^Bridge_Identity_Record) -> Keystore_Read_Status {
	rec^ = {}
	if !keystore_bridge_id_ok(bridge_id) do return .Error
	buf: [BRIDGE_IDENTITY_RECORD_MAX_BYTES + 1]byte
	defer crypto.zero_explicit(&buf, size_of(buf))
	n, status := keystore_backend_read(.Identity, bridge_id, buf[:])
	if status != .Found do return status
	if n < 6 || n > BRIDGE_IDENTITY_RECORD_MAX_BYTES || string(buf[:4]) != BRIDGE_IDENTITY_RECORD_MAGIC do return .Error
	owner_len := int(buf[4])
	if owner_len < 1 || owner_len > vault.KEYRING_MAX_USER_ID || n < 5 + owner_len + 1 do return .Error
	owner := string(buf[5:5 + owner_len])
	if !vault.valid_id_value(owner) do return .Error
	hub_off := 5 + owner_len
	hub_len := int(buf[hub_off])
	if hub_len < 1 || n != hub_off + 1 + hub_len + KEYSTORE_IDENTITY_KEY_BYTES do return .Error
	hub := string(buf[hub_off + 1:hub_off + 1 + hub_len])
	// Bound to the hub it was enrolled with: any other hub -> refuse (fail closed).
	if hub != bridge_keystore_hub() do return .Error
	copy(rec.owner_buf[:], owner)
	rec.owner_len = owner_len
	copy(rec.hub_buf[:], hub)
	rec.hub_len = hub_len
	copy(rec.scalar[:], buf[hub_off + 1 + hub_len:n])
	return .Found
}

// keystore_delete_identity_key deletes the enrollment record and its epoch floor
// (they are created together at enrollment and only make sense together).
keystore_delete_identity_key :: proc(bridge_id: string) -> bool {
	if !keystore_bridge_id_ok(bridge_id) do return true
	floor_ok := keystore_delete_epoch_floor(bridge_id)
	return keystore_backend_delete(.Identity, bridge_id) && floor_ok
}

// ── Backend dispatch ────────────────────────────────────────────────────────
//
// Production always uses the OS backend (keystore_os_* in the per-OS files). A test
// build uses an in-process fake by default, so no test reads or writes the real
// Credential Manager / Keychain / kernel keyring / data directory. The fake honors
// keystore_set_mock_syscall_error the way the OS backends do.

// Every backend call names the item by its SCOPE (keystore_scope.odin): bridge id +
// the hub this process is bound to. No scope -> nothing is written, read or deleted.

keystore_backend_write :: proc(slot: Keystore_Slot, bridge_id: string, data: []byte) -> int {
	name, scoped := keystore_scope_name(bridge_id)
	if !scoped do return KEYSTORE_ERR_BAD_BRIDGE_ID
	when ODIN_TEST {
		if g_keystore_use_fake do return keystore_fake_write(slot, name, data)
	}
	return keystore_os_write_secret(slot, name, data)
}

keystore_backend_read :: proc(slot: Keystore_Slot, bridge_id: string, dst: []byte) -> (n: int, status: Keystore_Read_Status) {
	name, scoped := keystore_scope_name(bridge_id)
	if !scoped do return 0, .Error
	when ODIN_TEST {
		if g_keystore_use_fake do return keystore_fake_read(slot, name, dst)
	}
	return keystore_os_read_secret_status(slot, name, dst)
}

keystore_backend_delete :: proc(slot: Keystore_Slot, bridge_id: string) -> bool {
	name, scoped := keystore_scope_name(bridge_id)
	if !scoped do return false
	when ODIN_TEST {
		if g_keystore_use_fake do return keystore_fake_delete(slot, name)
	}
	return keystore_os_delete_secret(slot, name)
}

when ODIN_TEST {
	// Tests that exercise a real OS backend set this to false (and restore it).
	g_keystore_use_fake := true

	KEYSTORE_FAKE_SLOTS     :: 32
	KEYSTORE_FAKE_MAX_BYTES :: 2560

	Keystore_Fake_Item :: struct {
		used:      bool,
		slot:      Keystore_Slot,
		id_buf:    [128]byte,
		id_len:    int,
		data:      [KEYSTORE_FAKE_MAX_BYTES]byte,
		data_len:  int,
	}

	@(private = "file")
	g_keystore_fake_mu: sync.Mutex
	@(private = "file")
	g_keystore_fake_items: [KEYSTORE_FAKE_SLOTS]Keystore_Fake_Item

	@(private = "file")
	keystore_fake_find_locked :: proc(slot: Keystore_Slot, bridge_id: string) -> ^Keystore_Fake_Item {
		for &it in g_keystore_fake_items {
			if it.used && it.slot == slot && string(it.id_buf[:it.id_len]) == bridge_id do return &it
		}
		return nil
	}

	keystore_fake_write :: proc(slot: Keystore_Slot, bridge_id: string, data: []byte) -> int {
		if _keystore_mock_syscall_errno != 0 do return _keystore_mock_syscall_errno
		if len(data) == 0 || len(data) > KEYSTORE_FAKE_MAX_BYTES || len(bridge_id) == 0 || len(bridge_id) > 128 do return -1
		sync.mutex_lock(&g_keystore_fake_mu)
		defer sync.mutex_unlock(&g_keystore_fake_mu)
		it := keystore_fake_find_locked(slot, bridge_id)
		if it == nil {
			for &cand in g_keystore_fake_items {
				if !cand.used {
					it = &cand
					break
				}
			}
		}
		if it == nil do return -1
		crypto.zero_explicit(it, size_of(it^))
		it.used, it.slot = true, slot
		copy(it.id_buf[:], bridge_id)
		it.id_len = len(bridge_id)
		copy(it.data[:], data)
		it.data_len = len(data)
		return 0
	}

	keystore_fake_read :: proc(slot: Keystore_Slot, bridge_id: string, dst: []byte) -> (n: int, status: Keystore_Read_Status) {
		if _keystore_mock_syscall_errno != 0 do return 0, .Error
		sync.mutex_lock(&g_keystore_fake_mu)
		defer sync.mutex_unlock(&g_keystore_fake_mu)
		it := keystore_fake_find_locked(slot, bridge_id)
		if it == nil do return 0, .Not_Found
		if it.data_len > len(dst) do return 0, .Error
		copy(dst, it.data[:it.data_len])
		return it.data_len, .Found
	}

	keystore_fake_delete :: proc(slot: Keystore_Slot, bridge_id: string) -> bool {
		if _keystore_mock_syscall_errno != 0 do return false
		sync.mutex_lock(&g_keystore_fake_mu)
		defer sync.mutex_unlock(&g_keystore_fake_mu)
		if it := keystore_fake_find_locked(slot, bridge_id); it != nil do crypto.zero_explicit(it, size_of(it^))
		return true
	}
}
