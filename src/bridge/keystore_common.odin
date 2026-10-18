package main

// OS-independent half of the bridge keystore (passwordless vault P1).
//
// Two secrets are kept per bridge, each in its own OS item (keystore_os_* in the
// per-OS files, addressed by Keystore_Slot + bridge_id):
//
//   - .Keyring  — the binary HKR1 keyring (lib/vault), at most
//     vault.KEYRING_MAX_BYTES = 2380 bytes, which fits the Windows Credential
//     Manager's 2560-byte blob limit. Lock purges it.
//   - .Identity — the bridge's persistent ECDSA P-256 identity scalar (32 bytes).
//     It signs each boot's ephemeral unseal key. Lock KEEPS it (a locked bridge is
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

// keystore_store_in_memory_vault_keyring keeps a validated copy of bridge_id's HKR1
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

	status := keystore_os_write_secret(.Keyring, bridge_id, data)
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
	n, read_ok := keystore_os_read_secret(.Keyring, bridge_id, buf[:])
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
	n, read_ok := keystore_os_read_secret(.Keyring, bridge_id, buf[:])
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
	return keystore_os_delete_secret(.Keyring, bridge_id)
}

// keystore_lock_and_purge purges the keyring (persisted and in memory). The
// identity key is deliberately kept; see the file header.
keystore_lock_and_purge :: proc(bridge_id: string) {
	_ = keystore_unlink_vault_key(bridge_id)
	keystore_wipe_in_memory_vault_key()
}

keystore_persisted_vault_item_present :: proc(bridge_id: string) -> bool {
	if !keystore_bridge_id_ok(bridge_id) do return false
	return keystore_os_secret_present(.Keyring, bridge_id)
}

// ── Identity key ────────────────────────────────────────────────────────────

keystore_store_identity_key :: proc(bridge_id: string, scalar: []byte) -> bool {
	if len(scalar) != KEYSTORE_IDENTITY_KEY_BYTES || !keystore_bridge_id_ok(bridge_id) do return false
	return keystore_os_write_secret(.Identity, bridge_id, scalar) == 0
}

keystore_read_identity_key :: proc(bridge_id: string, dst: []byte) -> bool {
	if len(dst) != KEYSTORE_IDENTITY_KEY_BYTES || !keystore_bridge_id_ok(bridge_id) do return false
	buf: [64]byte
	defer crypto.zero_explicit(&buf, size_of(buf))
	n, ok := keystore_os_read_secret(.Identity, bridge_id, buf[:])
	if !ok || n != KEYSTORE_IDENTITY_KEY_BYTES do return false
	copy(dst, buf[:n])
	return true
}

keystore_delete_identity_key :: proc(bridge_id: string) -> bool {
	if !keystore_bridge_id_ok(bridge_id) do return true
	return keystore_os_delete_secret(.Identity, bridge_id)
}
