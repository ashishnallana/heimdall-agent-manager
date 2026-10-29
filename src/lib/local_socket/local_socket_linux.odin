#+build linux
package local_socket

import "core:sys/linux"

// accept goes through accept4(2) with no flags -- identical blocking semantics to
// accept(2), but the syscall Android's app seccomp policy actually allows: bionic
// implements accept() as accept4(), so plain accept (arm64 nr 202) is not on the
// allowlist and every bridge launch on a phone died with SIGSYS the moment a
// client connected. core:net's TCP accept already uses accept4 the same way.
accept :: proc(listener: Socket) -> (Socket, bool) {
	addr: linux.Sock_Addr_Un
	fd, errno := linux.accept(linux.Fd(listener), &addr)
	if errno != .NONE do return INVALID_SOCKET, false
	return Socket(fd), true
}

// peer_pid returns the pid of the process on the other end of a connected
// socket (SO_PEERCRED), so the bridge can stop the PTY host it reaches on its
// socket even when an earlier bridge process started it.
peer_pid :: proc(s: Socket) -> (int, bool) {
	cred: struct {pid: i32, uid: u32, gid: u32}
	if _, err := linux.getsockopt_base(linux.Fd(s), int(linux.SOL_SOCKET), linux.Socket_Option.PEERCRED, &cred); err != .NONE do return 0, false
	return int(cred.pid), cred.pid > 0
}
