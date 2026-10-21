package main

import "core:mem"
import "core:strings"

KEYSTORE_ERR_EPERM    :: 1
KEYSTORE_ERR_EACCES   :: 13
KEYSTORE_ERR_ENOSYS   :: 38
KEYSTORE_ERR_ENOKEY   :: 126

// Login-keychain generic-password items carry this bridge's secrets across
// restarts (keystore_common.odin): one service for the binary HKR2 keyring and one
// for the identity key. The account is the bridge id (REQ-T5-1), so bridges of the
// same macOS user never share or purge each other's secrets.
//
// A TEST BUILD NEVER NAMES A PRODUCTION ITEM: a shared name would let a test
// overwrite and then delete a developer Mac's real enrolled secrets.
KEYCHAIN_SERVICE_KEYRING  :: "works.earendil.heimdall-bridge.vault-keyring.test" when ODIN_TEST else "works.earendil.heimdall-bridge.vault-keyring"
KEYCHAIN_SERVICE_IDENTITY :: "works.earendil.heimdall-bridge.vault-identity.test" when ODIN_TEST else "works.earendil.heimdall-bridge.vault-identity"
KEYCHAIN_SERVICE_FLOOR    :: "works.earendil.heimdall-bridge.vault-epoch-floor.test" when ODIN_TEST else "works.earendil.heimdall-bridge.vault-epoch-floor"
KEYCHAIN_SERVICE_IDENTITY_PREVIOUS :: "works.earendil.heimdall-bridge.vault-identity-previous.test" when ODIN_TEST else "works.earendil.heimdall-bridge.vault-identity-previous"
KEYCHAIN_SERVICE_FLOOR_PREVIOUS    :: "works.earendil.heimdall-bridge.vault-epoch-floor-previous.test" when ODIN_TEST else "works.earendil.heimdall-bridge.vault-epoch-floor-previous"

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

// Testing hooks for simulation: a non-zero value makes every Keychain call fail
// with it, the Darwin analogue of the Linux restricted-keyring simulation.
_keystore_mock_syscall_errno: int = 0

keystore_set_mock_syscall_error :: proc(errno: int) {
	_keystore_mock_syscall_errno = errno
}

@(private = "file")
keychain_service :: proc(slot: Keystore_Slot) -> string {
	switch slot {
	case .Keyring:     return KEYCHAIN_SERVICE_KEYRING
	case .Identity:    return KEYCHAIN_SERVICE_IDENTITY
	case .Epoch_Floor: return KEYCHAIN_SERVICE_FLOOR
	case .Identity_Previous:    return KEYCHAIN_SERVICE_IDENTITY_PREVIOUS
	case .Epoch_Floor_Previous: return KEYCHAIN_SERVICE_FLOOR_PREVIOUS
	}
	return KEYCHAIN_SERVICE_IDENTITY
}

// Looks up the slot's item. A nil `item` is a valid out: the lookup then only
// tests for existence. The caller CFReleases a returned item.
@(private = "file")
keychain_find_item :: proc(slot: Keystore_Slot, bridge_id: string, item: ^rawptr, password_len: ^u32 = nil, password_data: ^rawptr = nil) -> i32 {
	if _keystore_mock_syscall_errno != 0 do return i32(_keystore_mock_syscall_errno)
	service := keychain_service(slot)
	service_c := strings.clone_to_cstring(service, context.temp_allocator)
	account := strings.clone_to_cstring(bridge_id, context.temp_allocator)
	return SecKeychainFindGenericPassword(
		nil,
		u32(len(service)), service_c,
		u32(len(bridge_id)), account,
		password_len, password_data, item,
	)
}

keystore_os_requires_persistence :: proc() -> bool {
	return false
}

// keystore_os_write_secret upserts the slot's item in the login keychain. The
// generic-password API takes plain buffers, so the secret never appears in argv.
keystore_os_write_secret :: proc(slot: Keystore_Slot, bridge_id: string, data: []byte) -> int {
	if _keystore_mock_syscall_errno != 0 do return _keystore_mock_syscall_errno
	if len(data) == 0 do return -1
	item: rawptr
	status := keychain_find_item(slot, bridge_id, &item)
	if status == KEYCHAIN_ERR_SEC_SUCCESS {
		defer CFRelease(item)
		return int(SecKeychainItemModifyAttributesAndData(item, nil, u32(len(data)), raw_data(data)))
	}
	if status != KEYCHAIN_ERR_SEC_ITEM_NOT_FOUND do return int(status)
	service := keychain_service(slot)
	service_c := strings.clone_to_cstring(service, context.temp_allocator)
	account := strings.clone_to_cstring(bridge_id, context.temp_allocator)
	return int(SecKeychainAddGenericPassword(
		nil,
		u32(len(service)), service_c,
		u32(len(bridge_id)), account,
		u32(len(data)), raw_data(data),
		nil,
	))
}

// keystore_os_read_secret_status copies the slot's secret into dst; the
// Keychain's own copy is zeroed before it is freed. Only errSecItemNotFound is
// absence; any other failure (a locked keychain, a denied ACL) is an error.
keystore_os_read_secret_status :: proc(slot: Keystore_Slot, bridge_id: string, dst: []byte) -> (n: int, status: Keystore_Read_Status) {
	password_len: u32
	password_data: rawptr
	found := keychain_find_item(slot, bridge_id, nil, &password_len, &password_data)
	if found == KEYCHAIN_ERR_SEC_ITEM_NOT_FOUND do return 0, .Not_Found
	if found != KEYCHAIN_ERR_SEC_SUCCESS do return 0, .Error
	defer {
		if password_data != nil {
			mem.zero_explicit(password_data, int(password_len))
			SecKeychainItemFreeContent(nil, password_data)
		}
	}
	size := int(password_len)
	if password_data == nil || size == 0 || size > len(dst) do return 0, .Error
	copy(dst, ([^]u8)(password_data)[:size])
	return size, .Found
}

keystore_os_delete_secret :: proc(slot: Keystore_Slot, bridge_id: string) -> bool {
	item: rawptr
	status := keychain_find_item(slot, bridge_id, &item)
	if status == KEYCHAIN_ERR_SEC_ITEM_NOT_FOUND do return true
	if status != KEYCHAIN_ERR_SEC_SUCCESS do return false
	defer CFRelease(item)
	return SecKeychainItemDelete(item) == KEYCHAIN_ERR_SEC_SUCCESS
}

// The Android/Termux keystore backend is a Linux-only compilation unit
// (keystore_android.odin, #+build linux). On macOS it is never selected.
keystore_android_selected :: proc() -> bool {
	return false
}
