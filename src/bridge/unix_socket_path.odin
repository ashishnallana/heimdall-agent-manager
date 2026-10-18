package main

import "core:fmt"
import "core:os"
import "core:strings"

// Darwin has 104 sun_path bytes including NUL; Linux has 108. Keep generated
// paths portable. Hash the entire intended path so bridges and socket roles stay
// distinct even when their runtime directories share a long prefix.
BRIDGE_UNIX_SOCKET_MAX_BYTES :: 103

bridge_unix_socket_bounded_path :: proc(path: string) -> string {
	if len(path) <= BRIDGE_UNIX_SOCKET_MAX_BYTES do return strings.clone(path)
	hash: u64 = 14695981039346656037
	for b in transmute([]byte)path {
		hash = (hash ~ u64(b)) * 1099511628211
	}
	root := bridge_scratch_root(context.temp_allocator)
	return fmt.aprintf("%s/%s/%016x.sock", root, bridge_os_private_dir_name(), hash)
}

// A fallback lives outside the configured run directory, so create an owner-only
// directory and reject pre-existing symlinks or directories owned by another user.
bridge_unix_socket_prepare_parent :: proc(path: string) -> bool {
	slash := strings.last_index_byte(path, '/')
	if slash <= 0 do return false
	dir := path[:slash]
	root := bridge_scratch_root(context.temp_allocator)
	fallback := fmt.aprintf("%s/%s", root, bridge_os_private_dir_name())
	defer delete(fallback)
	if dir != fallback {
		err := bridge_make_directory_all(dir)
		if err != nil && err != .Exist do return false
		return bridge_os_dir_exists(dir)
	}
	return bridge_os_prepare_private_dir(dir)
}
