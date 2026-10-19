#+build !windows
package main

import "core:strings"
import "core:sys/posix"

// bridge_instance_lock takes an exclusive, non-blocking advisory lock on `path`
// (created 0600) for the life of the process: a second bridge instance using the
// same config or the same (hub, bridge id) scope refuses to start instead of
// sharing its state. The fd is intentionally never closed (the kernel releases the
// lock when the process exits, also on a crash).
bridge_instance_lock :: proc(path: string) -> bool {
	if strings.trim_space(path) == "" do return false
	fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.CREAT, .RDWR, .CLOEXEC}, {.IRUSR, .IWUSR})
	if fd < 0 do return false
	if posix.lockf(fd, .TLOCK, 0) != .OK {
		posix.close(fd)
		return false
	}
	return true
}
