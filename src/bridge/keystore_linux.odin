package main

// Linux persistence for this bridge's secrets (keystore_common.odin): `user` keys
// in the kernel user keyring (@u, KEY_SPEC_USER_KEYRING), described as
// "heimdall:vault_keyring:<bridge_id>" (binary HKR1 keyring) and
// "heimdall:vault_identity:<bridge_id>" (identity scalar), so bridges of the same
// OS user never share or purge each other's secrets (REQ-T5-1). Lookups use only KEYCTL_SEARCH rooted at @u
// for that exact description, never request_key(), which walks the
// thread/process/session keyrings a bridge may have inherited from another
// (REQ-T5-6). The mlock'd in-memory buffer is per process, i.e. per bridge.
//
// Under Termux (keystore_android_selected) every public proc below hands off to
// the Android Keystore backend in keystore_android.odin before any keyring
// syscall is made: the keyring is seccomp-blocked there and must not be probed.

import "core:c"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"

KEY_SPEC_USER_KEYRING :: -4

KEYCTL_GET_KEYRING_ID :: 0
KEYCTL_REVOKE         :: 3
KEYCTL_CLEAR          :: 7
KEYCTL_UNLINK         :: 9
KEYCTL_SEARCH         :: 10
KEYCTL_READ           :: 11
KEYCTL_INVALIDATE     :: 21

KEY_TYPE_USER         :: "user"
KEY_DESC_KEYRING_PREFIX  :: "heimdall:vault_keyring:"
KEY_DESC_IDENTITY_PREFIX :: "heimdall:vault_identity:"

KEYSTORE_ERR_EPERM    :: 1
KEYSTORE_ERR_EACCES   :: 13
KEYSTORE_ERR_ENOSYS   :: 38
KEYSTORE_ERR_ENOKEY   :: 126

// Testing hooks for container / sandbox restriction simulation
_keystore_mock_syscall_errno: int = 0

keystore_set_mock_syscall_error :: proc(errno: int) {
	_keystore_mock_syscall_errno = errno
}

@(private="file")
sys_add_key :: proc "contextless" (type: cstring, description: cstring, payload: rawptr, plen: c.size_t, ringid: i32) -> (int, int) {
	if _keystore_mock_syscall_errno != 0 {
		return -1, _keystore_mock_syscall_errno
	}
	ret := linux.syscall(
		linux.SYS_add_key,
		transmute(uintptr)type,
		transmute(uintptr)description,
		transmute(uintptr)payload,
		uintptr(plen),
		transmute(uintptr)int(ringid),
	)
	if ret < 0 {
		return -1, -ret
	}
	return ret, 0
}

@(private="file")
sys_keyctl :: proc "contextless" (cmd: int, arg2: uintptr = 0, arg3: uintptr = 0, arg4: uintptr = 0, arg5: uintptr = 0) -> (int, int) {
	if _keystore_mock_syscall_errno != 0 {
		return -1, _keystore_mock_syscall_errno
	}
	ret := linux.syscall(
		linux.SYS_keyctl,
		uintptr(cmd),
		arg2,
		arg3,
		arg4,
		arg5,
	)
	if ret < 0 {
		return -1, -ret
	}
	return ret, 0
}

@(private="file")
keystore_key_description :: proc(slot: Keystore_Slot, bridge_id: string) -> cstring {
	prefix := KEY_DESC_KEYRING_PREFIX if slot == .Keyring else KEY_DESC_IDENTITY_PREFIX
	return strings.clone_to_cstring(strings.concatenate({prefix, bridge_id}, context.temp_allocator), context.temp_allocator)
}

// Finds the slot's key in @u (and keyrings linked under it) by exact description.
// Deliberately not request_key(): see the file header.
@(private="file")
keystore_search_key :: proc(slot: Keystore_Slot, bridge_id: string) -> (key_id: int, ok: bool) {
	key_desc := keystore_key_description(slot, bridge_id)
	key_type := cstring(KEY_TYPE_USER)
	found, err := sys_keyctl(
		KEYCTL_SEARCH,
		transmute(uintptr)int(KEY_SPEC_USER_KEYRING),
		transmute(uintptr)key_type,
		transmute(uintptr)key_desc,
		0,
	)
	if err != 0 || found <= 0 do return 0, false
	return found, true
}

// Termux cannot use the keyring at all, so it must persist or fail.
keystore_os_requires_persistence :: proc() -> bool {
	return keystore_android_selected()
}

// keystore_os_write_secret adds (or replaces) the slot's key in @u. Returns 0 or
// the errno; EPERM/EACCES/ENOSYS mean a container/sandbox restriction
// (REQ-VAULT-HARDEN-9), which keystore_common answers with a memory-only copy.
keystore_os_write_secret :: proc(slot: Keystore_Slot, bridge_id: string, data: []byte) -> int {
	if keystore_android_selected() do return keystore_android_write_secret(slot, bridge_id, data)
	if len(data) == 0 do return -1
	key_type := cstring(KEY_TYPE_USER)
	_, err := sys_add_key(key_type, keystore_key_description(slot, bridge_id), raw_data(data), c.size_t(len(data)), KEY_SPEC_USER_KEYRING)
	if err != 0 do blog_warn(.keystore_unavailable, blog_sym(.reason, .linux_keyring), blog_int(.errno, i64(err)))
	return err
}

keystore_os_read_secret :: proc(slot: Keystore_Slot, bridge_id: string, dst: []byte) -> (n: int, ok: bool) {
	if keystore_android_selected() do return keystore_android_read_secret(slot, bridge_id, dst)
	key_id := keystore_search_key(slot, bridge_id) or_return
	read_len, r_err := sys_keyctl(
		KEYCTL_READ,
		uintptr(key_id),
		transmute(uintptr)raw_data(dst),
		uintptr(len(dst)),
	)
	// keyctl_read returns the full payload size even when dst is too small.
	if r_err != 0 || read_len <= 0 || read_len > len(dst) do return 0, false
	return read_len, true
}

// A present @u key is always readable, so only Termux's sealed file can be
// "present but unreadable".
keystore_os_secret_present :: proc(slot: Keystore_Slot, bridge_id: string) -> bool {
	if keystore_android_selected() do return keystore_android_secret_present(slot, bridge_id)
	return false
}

// Revokes and unlinks the slot's key. True when no key remains.
keystore_os_delete_secret :: proc(slot: Keystore_Slot, bridge_id: string) -> bool {
	if keystore_android_selected() do return keystore_android_delete_secret(slot, bridge_id)
	key_id, found := keystore_search_key(slot, bridge_id)
	if !found do return _keystore_mock_syscall_errno == 0
	_, _ = sys_keyctl(KEYCTL_REVOKE, uintptr(key_id))
	res, u_err := sys_keyctl(KEYCTL_UNLINK, uintptr(key_id), transmute(uintptr)int(KEY_SPEC_USER_KEYRING))
	return u_err == 0 && res == 0
}
