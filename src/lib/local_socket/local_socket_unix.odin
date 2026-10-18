#+build !windows
package local_socket

import "core:c"
import "core:strings"
import "core:sys/posix"
import "core:time"

Socket :: posix.FD

INVALID_SOCKET :: Socket(-1)

max_path_len :: proc() -> int {
	return len(posix.sockaddr_un{}.sun_path) - 1
}

@(private)
make_addr :: proc(path: string) -> posix.sockaddr_un {
	addr: posix.sockaddr_un
	when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .NetBSD || ODIN_OS == .OpenBSD {
		addr.sun_len = c.uchar(size_of(addr))
	}
	addr.sun_family = .UNIX
	for i in 0..<len(path) do addr.sun_path[i] = c.char(path[i])
	addr.sun_path[len(path)] = 0
	return addr
}

dial :: proc(path: string) -> (Socket, bool) {
	if !path_fits(path) do return INVALID_SOCKET, false
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return INVALID_SOCKET, false
	addr := make_addr(path)
	if posix.connect(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK {
		posix.close(fd)
		return INVALID_SOCKET, false
	}
	return fd, true
}

// listen binds path (removing a stale socket file first), makes it 0600
// owner-only, and listens.
listen :: proc(path: string, backlog: int = 16) -> (Socket, bool) {
	if !path_fits(path) do return INVALID_SOCKET, false
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return INVALID_SOCKET, false
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	_ = posix.unlink(cpath)
	addr := make_addr(path)
	if posix.bind(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK {
		posix.close(fd)
		return INVALID_SOCKET, false
	}
	_ = posix.chmod(cpath, posix.mode_t{.IRUSR, .IWUSR}) // 0600 owner-only
	if posix.listen(fd, c.int(backlog)) != .OK {
		posix.close(fd)
		return INVALID_SOCKET, false
	}
	return fd, true
}

pair :: proc() -> (a: Socket, b: Socket, ok: bool) {
	fds: [2]posix.FD
	if posix.socketpair(.UNIX, .STREAM, posix.Protocol(0), &fds) != .OK do return INVALID_SOCKET, INVALID_SOCKET, false
	return fds[0], fds[1], true
}

send :: proc(s: Socket, bytes: []byte) -> int {
	return int(posix.send(s, raw_data(bytes), c.size_t(len(bytes)), {}))
}

recv :: proc(s: Socket, buf: []byte) -> int {
	return int(posix.recv(s, raw_data(buf), c.size_t(len(buf)), {}))
}

recv_ex :: proc(s: Socket, buf: []byte) -> (int, Error) {
	n := posix.recv(s, raw_data(buf), c.size_t(len(buf)), {})
	if n >= 0 do return int(n), .None
	#partial switch posix.errno() {
	case .EAGAIN:
		return -1, .Would_Block
	case .EINTR:
		return -1, .Interrupted
	}
	return -1, .Failed
}

poll_readable :: proc(s: Socket, timeout_ms: int) -> (ready: bool, ok: bool) {
	pfd := posix.pollfd{fd = s, events = {.IN}}
	n := posix.poll(&pfd, 1, c.int(timeout_ms))
	if n < 0 do return false, posix.errno() == .EINTR
	return n > 0, true
}

set_recv_timeout :: proc(s: Socket, timeout: time.Duration) -> bool {
	secs := i64(timeout / time.Second)
	usecs := i64((timeout % time.Second) / time.Microsecond)
	tv := posix.timeval{tv_sec = posix.time_t(secs), tv_usec = posix.suseconds_t(usecs)}
	return posix.setsockopt(s, posix.SOL_SOCKET, .RCVTIMEO, &tv, posix.socklen_t(size_of(tv))) == .OK
}

shutdown :: proc(s: Socket, how: Shutdown_How) -> bool {
	h: posix.Shut
	switch how {
	case .Read:  h = .RD
	case .Write: h = .WR
	case .Both:  h = .RDWR
	}
	return posix.shutdown(s, h) == .OK
}

close :: proc(s: Socket) {
	posix.close(s)
}

// remove_path unlinks a socket file left behind by a listener.
remove_path :: proc(path: string) {
	_ = posix.unlink(strings.clone_to_cstring(path, context.temp_allocator))
}
