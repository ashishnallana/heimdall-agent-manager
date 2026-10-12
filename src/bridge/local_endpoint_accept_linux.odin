#+build linux
package main

import "core:sys/linux"
import "core:sys/posix"

// bridge_accept_unix accepts on the local Unix endpoint through accept4(2)
// with no flags — identical blocking semantics to accept(2), but the syscall
// Android's app seccomp policy actually allows: bionic implements accept() as
// accept4(), so plain accept (arm64 nr 202) is not on the allowlist and every
// bridge launch on a phone died with SIGSYS the moment a client connected.
// Odin's core:net TCP accept already uses accept4 via core:sys/linux; this
// gives the libc-based Unix listener the same path. Returns -1 on error.
bridge_accept_unix :: proc(listener: posix.FD) -> posix.FD {
	addr: linux.Sock_Addr_Un
	fd, errno := linux.accept(linux.Fd(listener), &addr)
	if errno != .NONE do return -1
	return posix.FD(fd)
}
