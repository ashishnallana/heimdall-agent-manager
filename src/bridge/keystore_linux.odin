package main

// Linux persistence for this bridge's secrets (keystore_common.odin):
//
//   - .Keyring: a `user` key in the kernel user keyring (@u, KEY_SPEC_USER_KEYRING)
//     described as "heimdall:vault_keyring:<bridge_id>". @u does not survive a
//     reboot, which is acceptable for the keyring (the bridge starts locked).
//   - .Identity: a 0600 file "identity_key" in the bridge's private 0700 directory
//     (bridge_vault_bridge_dir). The identity is created only at enrollment and is
//     never regenerated, so it must survive a reboot (finding H1); @u cannot hold it.
//   - .Epoch_Floor: a 0600 file "epoch_floor" beside it, for the same reason: a
//     reboot must not reset the anti-rollback floor.
//
// Bridge ids name both, so bridges of the same OS user never share or purge each
// other's secrets (REQ-T5-1). Lookups use only KEYCTL_SEARCH rooted at @u
// for that exact description, never request_key(), which walks the
// thread/process/session keyrings a bridge may have inherited from another
// (REQ-T5-6). The mlock'd in-memory buffer is per process, i.e. per bridge.
//
// Under Termux (keystore_android_selected) every public proc below hands off to
// the Android Keystore backend in keystore_android.odin before any keyring
// syscall is made: the keyring is seccomp-blocked there and must not be probed.

import "core:c"
import "core:mem"
import "core:os"
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
IDENTITY_FILE_NAME :: "identity_key"
EPOCH_FLOOR_FILE_NAME :: "epoch_floor"

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
	assert(slot == .Keyring, "only the keyring lives in @u")
	return strings.clone_to_cstring(strings.concatenate({KEY_DESC_KEYRING_PREFIX, bridge_id}, context.temp_allocator), context.temp_allocator)
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
	if slot != .Keyring do return keystore_identity_file_write(slot, bridge_id, data)
	key_type := cstring(KEY_TYPE_USER)
	_, err := sys_add_key(key_type, keystore_key_description(slot, bridge_id), raw_data(data), c.size_t(len(data)), KEY_SPEC_USER_KEYRING)
	if err != 0 do blog_warn(.keystore_unavailable, blog_sym(.reason, .linux_keyring), blog_int(.errno, i64(err)))
	return err
}

keystore_os_read_secret_status :: proc(slot: Keystore_Slot, bridge_id: string, dst: []byte) -> (n: int, status: Keystore_Read_Status) {
	if keystore_android_selected() do return keystore_android_read_secret_status(slot, bridge_id, dst)
	if slot != .Keyring do return keystore_identity_file_read(slot, bridge_id, dst)
	if _keystore_mock_syscall_errno != 0 do return 0, .Error
	key_id, found := keystore_search_key(slot, bridge_id)
	if !found do return 0, .Not_Found
	read_len, r_err := sys_keyctl(
		KEYCTL_READ,
		uintptr(key_id),
		transmute(uintptr)raw_data(dst),
		uintptr(len(dst)),
	)
	// keyctl_read returns the full payload size even when dst is too small.
	if r_err != 0 || read_len <= 0 || read_len > len(dst) do return 0, .Error
	return read_len, .Found
}

// A present @u key is always readable, so only Termux's sealed file can be
// "present but unreadable".
keystore_os_secret_present :: proc(slot: Keystore_Slot, bridge_id: string) -> bool {
	if keystore_android_selected() do return keystore_android_secret_present(slot, bridge_id)
	if slot != .Keyring {
		path, ok := keystore_identity_file_path(slot, bridge_id)
		return ok && os.exists(path)
	}
	return false
}

// Revokes and unlinks the slot's key. True when no key remains.
keystore_os_delete_secret :: proc(slot: Keystore_Slot, bridge_id: string) -> bool {
	if keystore_android_selected() do return keystore_android_delete_secret(slot, bridge_id)
	if slot != .Keyring {
		if _keystore_mock_syscall_errno != 0 do return false
		path, ok := keystore_identity_file_path(slot, bridge_id)
		if !ok do return true
		if !os.exists(path) do return true
		return os.remove(path) == nil
	}
	key_id, found := keystore_search_key(slot, bridge_id)
	if !found do return _keystore_mock_syscall_errno == 0
	_, _ = sys_keyctl(KEYCTL_REVOKE, uintptr(key_id))
	res, u_err := sys_keyctl(KEYCTL_UNLINK, uintptr(key_id), transmute(uintptr)int(KEY_SPEC_USER_KEYRING))
	return u_err == 0 && res == 0
}

// ── Identity file (persistent across reboots) ───────────────────────────────

@(private = "file")
keystore_identity_file_path :: proc(slot: Keystore_Slot, bridge_id: string) -> (path: string, ok: bool) {
	if !keystore_bridge_id_ok(bridge_id) do return "", false
	dir := bridge_vault_bridge_dir(bridge_id, context.temp_allocator) or_return
	name := IDENTITY_FILE_NAME if slot == .Identity else EPOCH_FLOOR_FILE_NAME
	return strings.concatenate({dir, name}, context.temp_allocator), true
}

// Writes the record 0600 via an exclusive temp file + fsync + rename inside a
// 0700 directory, so a crash never leaves a truncated record. Returns 0 or -1.
@(private = "file")
keystore_identity_file_write :: proc(slot: Keystore_Slot, bridge_id: string, data: []byte) -> int {
	if _keystore_mock_syscall_errno != 0 do return _keystore_mock_syscall_errno
	path, ok := keystore_identity_file_path(slot, bridge_id)
	if !ok do return KEYSTORE_ERR_BAD_BRIDGE_ID
	dir := path[:strings.last_index_byte(path, '/')]
	if mk_err := bridge_make_directory_all(dir); mk_err != nil && !os.exists(dir) do return -1
	if os.chmod(dir, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil do return -1
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	_ = os.remove(tmp)
	f, open_err := os.open(tmp, {.Write, .Create, .Excl, .Trunc}, {.Read_User, .Write_User})
	if open_err != nil do return -1
	n, write_err := os.write(f, data)
	sync_err := os.sync(f)
	os.close(f)
	if write_err != nil || n != len(data) || sync_err != nil || os.chmod(tmp, os.Permissions{.Read_User, .Write_User}) != nil {
		_ = os.remove(tmp)
		return -1
	}
	if os.rename(tmp, path) != nil {
		_ = os.remove(tmp)
		return -1
	}
	return 0
}

// A missing file is .Not_Found; anything else that keeps the record from being
// trusted (unreadable, wrong type, group/other access, oversized) is .Error.
@(private = "file")
keystore_identity_file_read :: proc(slot: Keystore_Slot, bridge_id: string, dst: []byte) -> (n: int, status: Keystore_Read_Status) {
	if _keystore_mock_syscall_errno != 0 do return 0, .Error
	path, ok := keystore_identity_file_path(slot, bridge_id)
	if !ok do return 0, .Error
	if !os.exists(path) do return 0, .Not_Found
	info, st_err := os.stat(path, context.temp_allocator)
	if st_err != nil || info.type != .Regular do return 0, .Error
	group_other := os.Permissions{.Read_Group, .Write_Group, .Execute_Group, .Read_Other, .Write_Other, .Execute_Other}
	if info.mode & group_other != {} {
		blog_warn(.keystore_unavailable, blog_sym(.reason, .linux_keyring))
		return 0, .Error
	}
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil do return 0, .Error
	defer {
		mem.zero_explicit(raw_data(data), len(data))
		delete(data)
	}
	if len(data) == 0 || len(data) > len(dst) do return 0, .Error
	copy(dst, data)
	return len(data), .Found
}
