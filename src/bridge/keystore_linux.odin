package main

// Linux persistence for the unsealed vault key: one `user` key per bridge in the
// kernel user keyring (@u, KEY_SPEC_USER_KEYRING), described as
// "heimdall:vault_key:<bridge_id>" so bridges of the same OS user never share or
// purge each other's key (REQ-T5-1). Lookups use only KEYCTL_SEARCH rooted at @u
// for that exact description, never request_key(), which walks the
// thread/process/session keyrings a bridge may have inherited from another
// (REQ-T5-6). The mlock'd in-memory buffer is per process, i.e. per bridge.

import "core:c"
import "core:encoding/hex"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
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
KEY_DESC_VAULT_PREFIX :: "heimdall:vault_key:"

KEYSTORE_ERR_EPERM    :: 1
KEYSTORE_ERR_EACCES   :: 13
KEYSTORE_ERR_ENOSYS   :: 38
KEYSTORE_ERR_ENOKEY   :: 126

// Global state for in-memory JIT unsealed buffer fallback
g_keystore_in_memory_buffer: Secure_Key
g_keystore_in_memory_set: bool
g_keystore_mu: sync.Mutex

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

// Stores the unsealed vault key in process-isolated JIT memory (mlock'd buffer with MADV_DONTDUMP)
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

// The @u description of bridge_id's vault key (temp-allocated); ok is false for
// an id that cannot name one (keystore_bridge_id_ok).
@(private="file")
keystore_key_description :: proc(bridge_id: string) -> (desc: cstring, ok: bool) {
	if !keystore_bridge_id_ok(bridge_id) do return nil, false
	return strings.clone_to_cstring(strings.concatenate({KEY_DESC_VAULT_PREFIX, bridge_id}, context.temp_allocator), context.temp_allocator), true
}

// Finds bridge_id's vault key in @u (and keyrings linked under it) by exact
// description. Deliberately not request_key(): see the file header.
@(private="file")
keystore_search_vault_key :: proc(bridge_id: string) -> (key_id: int, ok: bool) {
	key_desc := keystore_key_description(bridge_id) or_return
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

// Stores bridge_id's vault key in the Linux kernel user keyring (@u / KEY_SPEC_USER_KEYRING).
// If syscall returns EPERM, ENOSYS, or EACCES (container/sandbox restriction), logs a warning
// and falls back gracefully to process-isolated JIT memory (mlock'd buffer) without failing startup (REQ-VAULT-HARDEN-9).
// An id that cannot name a key stores nothing anywhere (KEYSTORE_ERR_BAD_BRIDGE_ID).
keystore_store_vault_key :: proc(bridge_id: string, key_hex: string) -> (ok: bool, err_code: int) {
	if !bridge_is_valid_hex_key(key_hex) {
		return false, -1
	}
	key_desc, desc_ok := keystore_key_description(bridge_id)
	if !desc_ok do return false, KEYSTORE_ERR_BAD_BRIDGE_ID

	key_type := cstring(KEY_TYPE_USER)
	payload := transmute([]u8)key_hex

	_, err := sys_add_key(key_type, key_desc, raw_data(payload), c.size_t(len(payload)), KEY_SPEC_USER_KEYRING)
	if err != 0 {
		if err == KEYSTORE_ERR_EPERM || err == KEYSTORE_ERR_EACCES || err == KEYSTORE_ERR_ENOSYS {
			fmt.eprintfln(
				"WARN: Linux kernel keyring restricted (errno %d). Falling back gracefully to process-isolated JIT memory (REQ-VAULT-HARDEN-9).",
				err,
			)
			mem_ok := keystore_store_in_memory_vault_key(key_hex)
			return mem_ok, err
		}
		// Other error: store in memory buffer as safety net, return error code
		_ = keystore_store_in_memory_vault_key(key_hex)
		return false, err
	}

	// Also sync to process-isolated memory buffer for quick access
	keystore_store_in_memory_vault_key(key_hex)
	return true, 0
}

// Retrieves bridge_id's vault key from the Linux kernel user keyring (@u) via KEYCTL_SEARCH / keyctl_read.
keystore_read_keyring_vault_key :: proc(bridge_id: string, allocator := context.allocator) -> (key_hex: string, ok: bool) {
	key_id := keystore_search_vault_key(bridge_id) or_return

	buf: [128]u8
	read_len, r_err := sys_keyctl(
		KEYCTL_READ,
		uintptr(key_id),
		transmute(uintptr)raw_data(buf[:]),
		uintptr(len(buf)),
	)
	if r_err != 0 || read_len <= 0 {
		return "", false
	}

	if read_len == 64 {
		hex_candidate := string(buf[:64])
		if bridge_is_valid_hex_key(hex_candidate) {
			return strings.clone(hex_candidate, allocator), true
		}
	}

	if read_len == 32 {
		encoded, enc_err := hex.encode(buf[:32], allocator)
		if enc_err == nil && bridge_is_valid_hex_key(string(encoded)) {
			return string(encoded), true
		}
	}

	return "", false
}

// Revokes and unlinks bridge_id's vault key from KEY_SPEC_USER_KEYRING via keyctl_unlink.
// Another bridge's key is never found, so never touched.
keystore_unlink_vault_key :: proc(bridge_id: string) -> bool {
	key_id := keystore_search_vault_key(bridge_id) or_return

	// Revoke to immediately invalidate
	_, _ = sys_keyctl(KEYCTL_REVOKE, uintptr(key_id))

	// Unlink from KEY_SPEC_USER_KEYRING
	res, u_err := sys_keyctl(KEYCTL_UNLINK, uintptr(key_id), transmute(uintptr)int(KEY_SPEC_USER_KEYRING))
	return u_err == 0 && res == 0
}

// The Darwin Keychain item can exist yet be unreadable; a present @u key is always
// readable and already reports Unlocked, so there is nothing extra to detect here.
keystore_persisted_vault_item_present :: proc(bridge_id: string) -> bool {
	return false
}

// Purges bridge_id's kernel keyring entry and wipes all in-memory unsealed buffers on bridge lock / shutdown.
keystore_lock_and_purge :: proc(bridge_id: string) {
	_ = keystore_unlink_vault_key(bridge_id)
	keystore_wipe_in_memory_vault_key()
}
