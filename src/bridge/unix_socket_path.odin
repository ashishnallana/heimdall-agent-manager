package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

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
	return fmt.aprintf("%s/heimdall-%d/%016x.sock", root, posix.geteuid(), hash)
}

// A fallback lives outside the configured run directory, so create an owner-only
// directory and reject pre-existing symlinks or directories owned by another user.
bridge_unix_socket_prepare_parent :: proc(path: string) -> bool {
	slash := strings.last_index_byte(path, '/')
	if slash <= 0 do return false
	dir := path[:slash]
	root := bridge_scratch_root(context.temp_allocator)
	fallback := fmt.aprintf("%s/heimdall-%d", root, posix.geteuid())
	defer delete(fallback)
	if dir != fallback {
		err := bridge_make_directory_all(dir)
		if err != nil && err != .Exist do return false
		cdir := strings.clone_to_cstring(dir)
		defer delete(cdir)
		info: posix.stat_t
		return posix.stat(cdir, &info) == .OK && posix.S_ISDIR(info.st_mode)
	}
	cdir := strings.clone_to_cstring(dir)
	defer delete(cdir)
	_ = posix.mkdir(cdir, posix.mode_t{.IRUSR, .IWUSR, .IXUSR})
	info: posix.stat_t
	if posix.lstat(cdir, &info) != .OK || !posix.S_ISDIR(info.st_mode) || info.st_uid != posix.geteuid() do return false
	return posix.chmod(cdir, posix.mode_t{.IRUSR, .IWUSR, .IXUSR}) == .OK
}
