package main

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"

KEYSTORE_ERR_EPERM    :: 1
KEYSTORE_ERR_EACCES   :: 13
KEYSTORE_ERR_ENOSYS   :: 38
KEYSTORE_ERR_ENOKEY   :: 126

// The login-keychain generic-password item that carries the unsealed vault key
// across process restarts. The in-memory buffer below stays the hot path; the
// Keychain is only the persistence layer, the macOS counterpart of the Linux @u
// keyring.
//
// A TEST BUILD NEVER NAMES THE PRODUCTION ITEM. Every suite that stores a key
// (keystore, unseal, vault-decrypt) runs keystore_store_vault_key and
// keystore_lock_and_purge, so on a developer's Mac a shared name would overwrite
// and then delete that machine's real enrolled key.
KEYCHAIN_SERVICE_VAULT :: "works.earendil.heimdall-bridge.vault.test" when ODIN_TEST else "works.earendil.heimdall-bridge.vault"
KEYCHAIN_ACCOUNT_VAULT :: "vault_key"

// OSStatus values from <Security/SecBase.h>.
KEYCHAIN_ERR_SEC_SUCCESS        :: 0
KEYCHAIN_ERR_SEC_ITEM_NOT_FOUND :: -25300

// The generic-password API takes plain C buffers, so persisting the key needs no
// CFDictionary plumbing and, unlike `/usr/bin/security add-generic-password -w`,
// never places the key in a process argv where `ps` can read it.
foreign import security_framework "system:Security.framework"
foreign import core_foundation "system:CoreFoundation.framework"

@(default_calling_convention = "c")
foreign security_framework {
	SecKeychainFindGenericPassword :: proc(keychainOrArray: rawptr, serviceNameLength: u32, serviceName: cstring, accountNameLength: u32, accountName: cstring, passwordLength: ^u32, passwordData: ^rawptr, itemRef: ^rawptr) -> i32 ---
	SecKeychainAddGenericPassword :: proc(keychain: rawptr, serviceNameLength: u32, serviceName: cstring, accountNameLength: u32, accountName: cstring, passwordLength: u32, passwordData: rawptr, itemRef: ^rawptr) -> i32 ---
	SecKeychainItemModifyAttributesAndData :: proc(itemRef: rawptr, attrList: rawptr, length: u32, data: rawptr) -> i32 ---
	SecKeychainItemDelete :: proc(itemRef: rawptr) -> i32 ---
	SecKeychainItemFreeContent :: proc(attrList: rawptr, data: rawptr) -> i32 ---
}

@(default_calling_convention = "c")
foreign core_foundation {
	CFRelease :: proc(cf: rawptr) ---
}

// Global state for the in-memory JIT unsealed buffer (the hot path) on Darwin / macOS
g_keystore_in_memory_buffer: Secure_Key
g_keystore_in_memory_set: bool
g_keystore_mu: sync.Mutex

// Testing hooks for simulation: a non-zero value makes every Keychain call fail
// with it, the Darwin analogue of the Linux restricted-keyring simulation.
_keystore_mock_syscall_errno: int = 0

keystore_set_mock_syscall_error :: proc(errno: int) {
	_keystore_mock_syscall_errno = errno
}

// Looks up the vault item. A nil `item` is a valid out: the lookup then only tests
// for existence. The caller CFReleases a returned item.
@(private = "file")
keychain_find_vault_item :: proc(item: ^rawptr, password_len: ^u32 = nil, password_data: ^rawptr = nil) -> i32 {
	if _keystore_mock_syscall_errno != 0 do return i32(_keystore_mock_syscall_errno)
	return SecKeychainFindGenericPassword(
		nil,
		u32(len(KEYCHAIN_SERVICE_VAULT)), KEYCHAIN_SERVICE_VAULT,
		u32(len(KEYCHAIN_ACCOUNT_VAULT)), KEYCHAIN_ACCOUNT_VAULT,
		password_len, password_data, item,
	)
}

// Upserts the vault item in the default (login) keychain.
@(private = "file")
keychain_write_vault_key :: proc(key_hex: string) -> i32 {
	if _keystore_mock_syscall_errno != 0 do return i32(_keystore_mock_syscall_errno)

	item: rawptr
	status := keychain_find_vault_item(&item)
	if status == KEYCHAIN_ERR_SEC_SUCCESS {
		defer CFRelease(item)
		return SecKeychainItemModifyAttributesAndData(item, nil, u32(len(key_hex)), raw_data(key_hex))
	}
	if status != KEYCHAIN_ERR_SEC_ITEM_NOT_FOUND do return status

	return SecKeychainAddGenericPassword(
		nil,
		u32(len(KEYCHAIN_SERVICE_VAULT)), KEYCHAIN_SERVICE_VAULT,
		u32(len(KEYCHAIN_ACCOUNT_VAULT)), KEYCHAIN_ACCOUNT_VAULT,
		u32(len(key_hex)), raw_data(key_hex),
		nil,
	)
}

// Stores the unsealed vault key in process-isolated JIT memory (mlock'd buffer)
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

// Stores the vault key in the login keychain so the bridge service started by
// `launchctl kickstart -k` after enrollment finds it, and in the in-memory buffer
// for this process. If the Keychain refuses (no login session, locked keychain,
// denied access), logs a warning and falls back to memory only, as the Linux path
// does for a restricted kernel keyring: this process stays unsealed, a restart
// starts locked. err_code is the OSStatus (or mock errno) of the failed call.
keystore_store_vault_key :: proc(key_hex: string) -> (ok: bool, err_code: int) {
	if !bridge_is_valid_hex_key(key_hex) {
		return false, -1
	}

	status := keychain_write_vault_key(key_hex)
	mem_ok := keystore_store_in_memory_vault_key(key_hex)
	if status != KEYCHAIN_ERR_SEC_SUCCESS {
		fmt.eprintfln(
			"WARN: macOS Keychain refused to store the vault key (OSStatus %d). Falling back to process-isolated JIT memory; the key will not survive a restart. After the bridge restarts, unseal it from Settings → Bridges → Unseal.",
			status,
		)
		return mem_ok, int(status)
	}
	return mem_ok, 0
}

// Retrieves the vault key persisted in the login keychain (the Darwin counterpart
// of the Linux @u keyring read), so a freshly restarted service sees it through
// bridge_read_vault_key / bridge_vault_status.
keystore_read_keyring_vault_key :: proc(allocator := context.allocator) -> (key_hex: string, ok: bool) {
	password_len: u32
	password_data: rawptr
	if keychain_find_vault_item(nil, &password_len, &password_data) != KEYCHAIN_ERR_SEC_SUCCESS {
		return "", false
	}
	// The Keychain hands back its own copy; zero it before giving it back so the
	// key does not linger in freed heap.
	defer {
		mem.zero_explicit(password_data, int(password_len))
		SecKeychainItemFreeContent(nil, password_data)
	}

	if password_data == nil || password_len != 64 do return "", false
	candidate := string(([^]u8)(password_data)[:password_len])
	if !bridge_is_valid_hex_key(candidate) do return "", false
	return strings.clone(candidate, allocator), true
}

// Deletes the persisted Keychain item and wipes the in-memory key. Returns true
// when no item remains (deleted now, or there was none).
keystore_unlink_vault_key :: proc() -> bool {
	keystore_wipe_in_memory_vault_key()

	item: rawptr
	status := keychain_find_vault_item(&item)
	if status == KEYCHAIN_ERR_SEC_ITEM_NOT_FOUND do return true
	if status != KEYCHAIN_ERR_SEC_SUCCESS do return false
	defer CFRelease(item)
	return SecKeychainItemDelete(item) == KEYCHAIN_ERR_SEC_SUCCESS
}

// Purges the Keychain item and the in-memory unsealed buffer on bridge lock / shutdown.
keystore_lock_and_purge :: proc() {
	_ = keystore_unlink_vault_key()
	keystore_wipe_in_memory_vault_key()
}
