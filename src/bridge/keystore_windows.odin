package main

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import win "core:sys/windows"

KEYSTORE_ERR_EPERM    :: 1
KEYSTORE_ERR_EACCES   :: 13
KEYSTORE_ERR_ENOSYS   :: 38
KEYSTORE_ERR_ENOKEY   :: 126

// The Windows Credential Manager generic credential that carries the unsealed
// vault key across process restarts -- the counterpart of the macOS login-keychain
// item and the Linux @u keyring. Credential Manager encrypts the blob with DPAPI
// under the user's logon secret, so only this Windows user can read it back. The
// in-memory buffer below stays the hot path. There is one credential per bridge:
// the bridge id is part of the target name (REQ-T5-1), so bridges of the same
// user never share or purge each other's key.
//
// A TEST BUILD NEVER NAMES THE PRODUCTION CREDENTIAL. Every suite that stores a
// key (keystore, unseal, vault-decrypt) runs keystore_store_vault_key and
// keystore_lock_and_purge, so on a developer's machine a shared name would
// overwrite and then delete that machine's real enrolled key.
CREDENTIAL_TARGET_VAULT_PREFIX :: "works.earendil.heimdall-bridge.vault.test:" when ODIN_TEST else "works.earendil.heimdall-bridge.vault:"

// Global state for the in-memory JIT unsealed buffer (the hot path) on Windows
g_keystore_in_memory_buffer: Secure_Key
g_keystore_in_memory_set: bool
g_keystore_mu: sync.Mutex

// Testing hooks for simulation: a non-zero value makes every Credential Manager
// call fail with it, the Windows analogue of the Linux restricted-keyring simulation.
_keystore_mock_syscall_errno: int = 0

keystore_set_mock_syscall_error :: proc(errno: int) {
	_keystore_mock_syscall_errno = errno
}

@(private = "file")
credential_target :: proc(bridge_id: string) -> win.wstring {
	return win.utf8_to_wstring(strings.concatenate({CREDENTIAL_TARGET_VAULT_PREFIX, bridge_id}, context.temp_allocator), context.temp_allocator)
}

// Reads bridge_id's credential; the caller CredFrees a returned credential. An id
// that cannot name a credential (keystore_bridge_id_ok) is never found. status is
// 0 on success, else the Win32 error (ERROR_NOT_FOUND when absent).
@(private = "file")
credential_read_vault_item :: proc(bridge_id: string) -> (cred: ^Credential_W, status: int) {
	if _keystore_mock_syscall_errno != 0 do return nil, _keystore_mock_syscall_errno
	if !keystore_bridge_id_ok(bridge_id) do return nil, ERROR_NOT_FOUND
	if !CredReadW(credential_target(bridge_id), CRED_TYPE_GENERIC, 0, &cred) {
		return nil, int(win.GetLastError())
	}
	return cred, 0
}

// Upserts bridge_id's credential. The caller has checked keystore_bridge_id_ok.
@(private = "file")
credential_write_vault_key :: proc(bridge_id: string, key_hex: string) -> int {
	if _keystore_mock_syscall_errno != 0 do return _keystore_mock_syscall_errno
	cred := Credential_W{
		Type               = CRED_TYPE_GENERIC,
		TargetName         = credential_target(bridge_id),
		CredentialBlobSize = u32(len(key_hex)),
		CredentialBlob     = raw_data(key_hex),
		Persist            = CRED_PERSIST_LOCAL_MACHINE,
		UserName           = win.utf8_to_wstring(bridge_id, context.temp_allocator),
	}
	if !CredWriteW(&cred, 0) do return int(win.GetLastError())
	return 0
}

// Stores the unsealed vault key in process-isolated JIT memory (VirtualLock'd buffer)
keystore_store_in_memory_vault_key :: proc(key_hex: string) -> bool {
	sync.mutex_lock(&g_keystore_mu)
	defer sync.mutex_unlock(&g_keystore_mu)

	if !bridge_is_valid_hex_key(key_hex) do return false

	if g_keystore_in_memory_set {
		secure_key_wipe_and_free(&g_keystore_in_memory_buffer)
		g_keystore_in_memory_set = false
	}

	key, ok := secure_key_alloc(len(key_hex))
	if !ok {
		return false
	}

	mem.copy(rawptr(key.ptr), raw_data(key_hex), len(key_hex))
	g_keystore_in_memory_buffer = key
	g_keystore_in_memory_set = true
	return true
}

// Retrieves the unsealed vault key from process-isolated JIT memory
keystore_read_in_memory_vault_key :: proc(allocator := context.allocator) -> (key_hex: string, ok: bool) {
	sync.mutex_lock(&g_keystore_mu)
	defer sync.mutex_unlock(&g_keystore_mu)

	if !g_keystore_in_memory_set || g_keystore_in_memory_buffer.ptr == nil {
		return "", false
	}

	bytes := g_keystore_in_memory_buffer.ptr[:g_keystore_in_memory_buffer.len]
	str_val := string(bytes)
	if !bridge_is_valid_hex_key(str_val) {
		return "", false
	}

	return strings.clone(str_val, allocator), true
}

// Explicitly wipes and frees the process-isolated JIT memory buffer
keystore_wipe_in_memory_vault_key :: proc() {
	sync.mutex_lock(&g_keystore_mu)
	defer sync.mutex_unlock(&g_keystore_mu)

	if g_keystore_in_memory_set {
		secure_key_wipe_and_free(&g_keystore_in_memory_buffer)
		g_keystore_in_memory_set = false
	}
}

// Stores the vault key in Credential Manager so a restarted bridge finds it, and
// in the in-memory buffer for this process. If Credential Manager refuses (no
// profile loaded, policy), logs a warning and falls back to memory only, as the
// Linux path does for a restricted kernel keyring: this process stays unsealed, a
// restart starts locked. err_code is the Win32 error (or mock errno) of the
// failed call. An id that cannot name a credential stores nothing anywhere
// (KEYSTORE_ERR_BAD_BRIDGE_ID).
keystore_store_vault_key :: proc(bridge_id: string, key_hex: string) -> (ok: bool, err_code: int) {
	if !bridge_is_valid_hex_key(key_hex) {
		return false, -1
	}
	if !keystore_bridge_id_ok(bridge_id) do return false, KEYSTORE_ERR_BAD_BRIDGE_ID

	status := credential_write_vault_key(bridge_id, key_hex)
	mem_ok := keystore_store_in_memory_vault_key(key_hex)
	if status != 0 {
		blog_warn(.keystore_unavailable, blog_sym(.reason, .windows_credential_manager), blog_int(.errno, i64(status)))
		fmt.eprintfln(
			"WARN: Windows Credential Manager refused to store the vault key (error %d). Falling back to process-isolated JIT memory; the key will not survive a restart. After the bridge restarts, unseal it from Settings → User Vault → Unseal.",
			status,
		)
		return mem_ok, status
	}
	return mem_ok, 0
}

// Retrieves bridge_id's vault key persisted in Credential Manager (the Windows
// counterpart of the Linux @u keyring read), so a freshly restarted bridge sees it
// through bridge_read_vault_key / bridge_vault_status.
keystore_read_keyring_vault_key :: proc(bridge_id: string, allocator := context.allocator) -> (key_hex: string, ok: bool) {
	cred, status := credential_read_vault_item(bridge_id)
	if status != 0 || cred == nil do return "", false
	// Credential Manager hands back its own copy; zero it before giving it back so
	// the key does not linger in freed heap.
	defer {
		if cred.CredentialBlob != nil do mem.zero_explicit(rawptr(cred.CredentialBlob), int(cred.CredentialBlobSize))
		CredFree(cred)
	}

	if cred.CredentialBlob == nil || cred.CredentialBlobSize != 64 do return "", false
	candidate := string(cred.CredentialBlob[:cred.CredentialBlobSize])
	if !bridge_is_valid_hex_key(candidate) do return "", false
	return strings.clone(candidate, allocator), true
}

// Reports whether Credential Manager still holds bridge_id's vault credential.
keystore_persisted_vault_item_present :: proc(bridge_id: string) -> bool {
	cred, status := credential_read_vault_item(bridge_id)
	if status != 0 || cred == nil do return false
	if cred.CredentialBlob != nil do mem.zero_explicit(rawptr(cred.CredentialBlob), int(cred.CredentialBlobSize))
	CredFree(cred)
	return true
}

// Deletes bridge_id's persisted credential and wipes the in-memory key. Returns
// true when no credential remains for it (deleted now, or there was none).
// Another bridge's credential is never touched.
keystore_unlink_vault_key :: proc(bridge_id: string) -> bool {
	keystore_wipe_in_memory_vault_key()

	if _keystore_mock_syscall_errno != 0 do return false
	if !keystore_bridge_id_ok(bridge_id) do return true
	if CredDeleteW(credential_target(bridge_id), CRED_TYPE_GENERIC, 0) do return true
	return win.GetLastError() == ERROR_NOT_FOUND
}

// Purges bridge_id's credential and the in-memory unsealed buffer on bridge lock / shutdown.
keystore_lock_and_purge :: proc(bridge_id: string) {
	_ = keystore_unlink_vault_key(bridge_id)
	keystore_wipe_in_memory_vault_key()
}

// The Android/Termux keystore backend is a Linux-only compilation unit; on
// Windows it is never selected.
keystore_android_selected :: proc() -> bool {
	return false
}
