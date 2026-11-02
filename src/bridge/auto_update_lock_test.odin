#+build !windows
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

// Child touches only async-signal-safe syscalls after fork. POSIX record locks
// are process-owned, so the child's independent claim proves serialization.
auto_test_child_claim :: proc(path: string) -> bool {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	pid := posix.fork()
	if pid == 0 {
		fd := posix.open(cpath, {.RDWR})
		if fd < 0 do posix._exit(2)
		if posix.lockf(fd, .TLOCK, 0) != .OK do posix._exit(1)
		posix._exit(0)
	}
	if pid < 0 do return false
	status: i32
	for posix.waitpid(pid, &status, {}) == -1 && posix.errno() == .EINTR {}
	return status == 0
}

@(test)
test_auto_update_kernel_serialization :: proc(t: ^testing.T) {
	dir := fmt.tprintf("%s/auto-update-lock-%d", os.temp_dir(context.temp_allocator), time.to_unix_nanoseconds(time.now()))
	_ = bridge_make_directory_all(dir)
	defer os.remove_all(dir)
	lock := fmt.tprintf("%s/user.lock", dir)
	testing.expect(t, bridge_instance_lock(lock))
	testing.expect(t, !auto_test_child_claim(lock), "another profile cannot claim the user's update lock")
	bridge_instance_unlock(lock)
	testing.expect(t, auto_test_child_claim(lock), "the next profile proceeds after release")
	testing.expect(t, auto_test_child_claim(lock), "kernel releases the lock on owner exit")
}
