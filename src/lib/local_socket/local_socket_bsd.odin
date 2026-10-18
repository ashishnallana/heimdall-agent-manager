#+build darwin, freebsd, netbsd, openbsd
package local_socket

import "core:sys/posix"

// No seccomp allowlist concern here; the libc accept is the right call.
accept :: proc(listener: Socket) -> (Socket, bool) {
	fd := posix.accept(listener, nil, nil)
	return fd, fd >= 0
}
