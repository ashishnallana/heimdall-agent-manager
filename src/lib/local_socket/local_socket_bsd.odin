#+build darwin, freebsd, netbsd, openbsd
package local_socket

import "core:sys/posix"

// No seccomp allowlist concern here; the libc accept is the right call.
accept :: proc(listener: Socket) -> (Socket, bool) {
	fd := posix.accept(listener, nil, nil)
	return fd, fd >= 0
}

// peer_pid returns the pid of the process on the other end of a connected
// socket (macOS LOCAL_PEERPID at level SOL_LOCAL), so the bridge can stop the PTY
// host it reaches on its socket even when an earlier bridge process started it.
// The other BSDs are not supported bridge targets: ok=false.
peer_pid :: proc(s: Socket) -> (int, bool) {
	when ODIN_OS == .Darwin {
		SOL_LOCAL :: 0
		LOCAL_PEERPID :: 0x002
		pid: i32
		size := posix.socklen_t(size_of(pid))
		if posix.getsockopt(s, SOL_LOCAL, posix.Sock_Option(LOCAL_PEERPID), &pid, &size) != .OK do return 0, false
		return int(pid), pid > 0
	} else {
		return 0, false
	}
}
