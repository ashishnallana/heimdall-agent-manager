#+build !windows
package main

import "core:strings"
import "core:sync"
import "core:sys/posix"

@(private = "file")
g_instance_lock_mu: sync.Mutex
@(private = "file")
g_instance_locks: map[string]posix.FD

// bridge_instance_lock takes an exclusive, non-blocking advisory lock on `path`
// (created 0600) for the life of the process (or until bridge_instance_unlock): a
// second bridge instance using the same config or the same (hub, bridge id) scope
// refuses to start instead of sharing its state. The kernel releases the lock when
// the process exits, also on a crash.
bridge_instance_lock :: proc(path: string) -> bool {
	if strings.trim_space(path) == "" do return false
	fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.CREAT, .RDWR, .CLOEXEC}, {.IRUSR, .IWUSR})
	if fd < 0 do return false
	if posix.lockf(fd, .TLOCK, 0) != .OK {
		posix.close(fd)
		return false
	}
	sync.mutex_lock(&g_instance_lock_mu)
	defer sync.mutex_unlock(&g_instance_lock_mu)
	g_instance_locks[strings.clone(path)] = fd
	return true
}

// bridge_instance_unlock releases a lock this process took (no-op otherwise).
bridge_instance_unlock :: proc(path: string) {
	sync.mutex_lock(&g_instance_lock_mu)
	defer sync.mutex_unlock(&g_instance_lock_mu)
	if path not_in g_instance_locks do return
	key, fd := delete_key(&g_instance_locks, path)
	posix.close(fd)
	delete(key)
}

// bridge_os_real_path resolves an EXISTING file or directory with realpath(3)
// (symlinks, "." and ".." resolved). Temp-allocated.
bridge_os_real_path :: proc(path: string) -> (string, bool) {
	resolved := posix.realpath(strings.clone_to_cstring(path, context.temp_allocator))
	if resolved == nil do return "", false
	defer posix.free(rawptr(resolved))
	return strings.clone(string(resolved), context.temp_allocator), true
}
