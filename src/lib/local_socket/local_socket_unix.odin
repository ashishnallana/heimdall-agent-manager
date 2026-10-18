#+build !windows
package local_socket

import "core:c"
import "core:sys/posix"

Socket :: posix.FD

INVALID_SOCKET :: Socket(-1)

max_path_len :: proc() -> int {
	return len(posix.sockaddr_un{}.sun_path) - 1
}

dial :: proc(path: string) -> (Socket, bool) {
	if !path_fits(path) do return INVALID_SOCKET, false
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return INVALID_SOCKET, false
	addr: posix.sockaddr_un
	when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .NetBSD || ODIN_OS == .OpenBSD {
		addr.sun_len = c.uchar(size_of(addr))
	}
	addr.sun_family = .UNIX
	for i in 0..<len(path) do addr.sun_path[i] = c.char(path[i])
	addr.sun_path[len(path)] = 0
	if posix.connect(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK {
		posix.close(fd)
		return INVALID_SOCKET, false
	}
	return fd, true
}

send :: proc(s: Socket, bytes: []byte) -> int {
	return int(posix.send(s, raw_data(bytes), c.size_t(len(bytes)), {}))
}

recv :: proc(s: Socket, buf: []byte) -> int {
	return int(posix.recv(s, raw_data(buf), c.size_t(len(buf)), {}))
}

close :: proc(s: Socket) {
	posix.close(s)
}
