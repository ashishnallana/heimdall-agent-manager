package main

import "core:mem"
import "core:strings"
import win "core:sys/windows"

KEYSTORE_ERR_EPERM    :: 1
KEYSTORE_ERR_EACCES   :: 13
KEYSTORE_ERR_ENOSYS   :: 38
KEYSTORE_ERR_ENOKEY   :: 126

// Windows Credential Manager generic credentials carry this bridge's secrets
// across restarts (keystore_common.odin): one for the binary HKR2 keyring (<= 2388
// bytes, under the 2560-byte CredentialBlob limit) and one for the identity key.
// DPAPI encrypts each blob under the user's logon secret. The bridge id is part of
// the target name (REQ-T5-1), so bridges of the same user never share or purge
// each other's secrets.
//
// A TEST BUILD NEVER NAMES A PRODUCTION CREDENTIAL: a shared name would let a test
// overwrite and then delete a developer machine's real enrolled secrets.
CREDENTIAL_TARGET_KEYRING_PREFIX  :: "works.earendil.heimdall-bridge.vault-keyring.test:" when ODIN_TEST else "works.earendil.heimdall-bridge.vault-keyring:"
CREDENTIAL_TARGET_IDENTITY_PREFIX :: "works.earendil.heimdall-bridge.vault-identity.test:" when ODIN_TEST else "works.earendil.heimdall-bridge.vault-identity:"
CREDENTIAL_TARGET_FLOOR_PREFIX    :: "works.earendil.heimdall-bridge.vault-epoch-floor.test:" when ODIN_TEST else "works.earendil.heimdall-bridge.vault-epoch-floor:"
CREDENTIAL_TARGET_IDENTITY_PREVIOUS_PREFIX :: "works.earendil.heimdall-bridge.vault-identity-previous.test:" when ODIN_TEST else "works.earendil.heimdall-bridge.vault-identity-previous:"
CREDENTIAL_TARGET_FLOOR_PREVIOUS_PREFIX    :: "works.earendil.heimdall-bridge.vault-epoch-floor-previous.test:" when ODIN_TEST else "works.earendil.heimdall-bridge.vault-epoch-floor-previous:"
CREDENTIAL_MAX_BLOB_BYTES         :: 2560

// Testing hooks for simulation: a non-zero value makes every Credential Manager
// call fail with it, the Windows analogue of the Linux restricted-keyring simulation.
_keystore_mock_syscall_errno: int = 0

keystore_set_mock_syscall_error :: proc(errno: int) {
	_keystore_mock_syscall_errno = errno
}

@(private = "file")
credential_target :: proc(slot: Keystore_Slot, bridge_id: string) -> win.wstring {
	prefix: string
	switch slot {
	case .Keyring:     prefix = CREDENTIAL_TARGET_KEYRING_PREFIX
	case .Identity:    prefix = CREDENTIAL_TARGET_IDENTITY_PREFIX
	case .Epoch_Floor: prefix = CREDENTIAL_TARGET_FLOOR_PREFIX
	case .Identity_Previous:    prefix = CREDENTIAL_TARGET_IDENTITY_PREVIOUS_PREFIX
	case .Epoch_Floor_Previous: prefix = CREDENTIAL_TARGET_FLOOR_PREVIOUS_PREFIX
	}
	return win.utf8_to_wstring(strings.concatenate({prefix, bridge_id}, context.temp_allocator), context.temp_allocator)
}

keystore_os_requires_persistence :: proc() -> bool {
	return false
}

// keystore_os_write_secret upserts the slot's credential. Returns 0 or the Win32 error.
keystore_os_write_secret :: proc(slot: Keystore_Slot, bridge_id: string, data: []byte) -> int {
	if _keystore_mock_syscall_errno != 0 do return _keystore_mock_syscall_errno
	if len(data) == 0 || len(data) > CREDENTIAL_MAX_BLOB_BYTES do return -1
	cred := Credential_W{
		Type               = CRED_TYPE_GENERIC,
		TargetName         = credential_target(slot, bridge_id),
		CredentialBlobSize = u32(len(data)),
		CredentialBlob     = raw_data(data),
		Persist            = CRED_PERSIST_LOCAL_MACHINE,
		UserName           = win.utf8_to_wstring(bridge_id, context.temp_allocator),
	}
	if !CredWriteW(&cred, 0) do return int(win.GetLastError())
	return 0
}

// keystore_os_read_secret_status copies the slot's blob into dst. Credential
// Manager's own copy is zeroed before it is freed. Only ERROR_NOT_FOUND is absence.
keystore_os_read_secret_status :: proc(slot: Keystore_Slot, bridge_id: string, dst: []byte) -> (n: int, status: Keystore_Read_Status) {
	if _keystore_mock_syscall_errno != 0 do return 0, .Error
	cred: ^Credential_W
	if !CredReadW(credential_target(slot, bridge_id), CRED_TYPE_GENERIC, 0, &cred) || cred == nil {
		if win.GetLastError() == ERROR_NOT_FOUND do return 0, .Not_Found
		return 0, .Error
	}
	defer {
		if cred.CredentialBlob != nil do mem.zero_explicit(rawptr(cred.CredentialBlob), int(cred.CredentialBlobSize))
		CredFree(cred)
	}
	size := int(cred.CredentialBlobSize)
	if cred.CredentialBlob == nil || size == 0 || size > len(dst) do return 0, .Error
	copy(dst, cred.CredentialBlob[:size])
	return size, .Found
}

// keystore_os_delete_secret returns true when no credential remains for the slot.
keystore_os_delete_secret :: proc(slot: Keystore_Slot, bridge_id: string) -> bool {
	if _keystore_mock_syscall_errno != 0 do return false
	if CredDeleteW(credential_target(slot, bridge_id), CRED_TYPE_GENERIC, 0) do return true
	return win.GetLastError() == ERROR_NOT_FOUND
}

// The Android/Termux keystore backend is a Linux-only compilation unit; on
// Windows it is never selected.
keystore_android_selected :: proc() -> bool {
	return false
}
