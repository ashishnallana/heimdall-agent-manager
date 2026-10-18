#+build windows
package local_socket

// Winsock AF_UNIX (Windows 10 1803+). The socket lives at a filesystem path like
// on POSIX; afunix.h's sockaddr_un has the same 108-byte sun_path. core:sys/windows
// does not declare it, so it is declared here. There is no chmod: the socket file
// inherits the ACL of its directory, and the bridge keeps its sockets under the
// user's own profile (%LOCALAPPDATA%), which other standard users cannot open.

import "core:fmt"
import "core:os"
import "core:sync"
import "core:time"
import win "core:sys/windows"

Socket :: win.SOCKET

INVALID_SOCKET :: ~Socket(0)

AF_UNIX :: 1
WSAEINTR :: 10004
WSAETIMEDOUT :: 10060

Sockaddr_Un :: struct {
	sun_family: win.ADDRESS_FAMILY,
	sun_path:   [108]byte,
}

max_path_len :: proc() -> int {
	return len(Sockaddr_Un{}.sun_path) - 1
}

@(private)
make_addr :: proc(path: string) -> Sockaddr_Un {
	addr: Sockaddr_Un
	addr.sun_family = AF_UNIX
	copy(addr.sun_path[:], path)
	return addr
}

@(private)
new_socket :: proc() -> Socket {
	win.ensure_winsock_initialized()
	return win.socket(AF_UNIX, win.SOCK_STREAM, 0)
}

dial :: proc(path: string) -> (Socket, bool) {
	if !path_fits(path) do return INVALID_SOCKET, false
	s := new_socket()
	if s == INVALID_SOCKET do return INVALID_SOCKET, false
	addr := make_addr(path)
	if win.connect(s, (^win.SOCKADDR_STORAGE_LH)(&addr), size_of(addr)) != 0 {
		win.closesocket(s)
		return INVALID_SOCKET, false
	}
	return s, true
}

// listen binds path (removing a stale socket file first) and listens.
listen :: proc(path: string, backlog: int = 16) -> (Socket, bool) {
	if !path_fits(path) do return INVALID_SOCKET, false
	s := new_socket()
	if s == INVALID_SOCKET do return INVALID_SOCKET, false
	_ = os.remove(path)
	addr := make_addr(path)
	if win.bind(s, (^win.SOCKADDR_STORAGE_LH)(&addr), size_of(addr)) != 0 {
		win.closesocket(s)
		return INVALID_SOCKET, false
	}
	if win.listen(s, i32(backlog)) != 0 {
		win.closesocket(s)
		return INVALID_SOCKET, false
	}
	return s, true
}

accept :: proc(listener: Socket) -> (Socket, bool) {
	s := win.accept(listener, nil, nil)
	return s, s != INVALID_SOCKET
}

@(private)
pair_counter: int

// pair emulates socketpair(2), which Winsock lacks for AF_UNIX: listen on a
// unique temporary path, connect, accept, then remove the path.
pair :: proc() -> (a: Socket, b: Socket, ok: bool) {
	tmp, terr := os.temp_dir(context.temp_allocator)
	if terr != nil do return INVALID_SOCKET, INVALID_SOCKET, false
	n := sync.atomic_add(&pair_counter, 1)
	path := fmt.tprintf("%s\\hlsp-%d-%d-%d.sock", tmp, os.get_pid(), time.tick_now()._nsec % 1_000_000_000, n)
	if !path_fits(path) do return INVALID_SOCKET, INVALID_SOCKET, false
	listener, lok := listen(path, 1)
	if !lok do return INVALID_SOCKET, INVALID_SOCKET, false
	defer {
		win.closesocket(listener)
		_ = os.remove(path)
	}
	client, cok := dial(path)
	if !cok do return INVALID_SOCKET, INVALID_SOCKET, false
	server, aok := accept(listener)
	if !aok {
		win.closesocket(client)
		return INVALID_SOCKET, INVALID_SOCKET, false
	}
	return client, server, true
}

send :: proc(s: Socket, bytes: []byte) -> int {
	return int(win.send(s, raw_data(bytes), i32(min(len(bytes), int(max(i32)))), 0))
}

recv :: proc(s: Socket, buf: []byte) -> int {
	return int(win.recv(s, raw_data(buf), i32(min(len(buf), int(max(i32)))), 0))
}

recv_ex :: proc(s: Socket, buf: []byte) -> (int, Error) {
	n := win.recv(s, raw_data(buf), i32(min(len(buf), int(max(i32)))), 0)
	if n >= 0 do return int(n), .None
	switch win.WSAGetLastError() {
	case win.WSAEWOULDBLOCK, WSAETIMEDOUT:
		return -1, .Would_Block
	case WSAEINTR:
		return -1, .Interrupted
	}
	return -1, .Failed
}

poll_readable :: proc(s: Socket, timeout_ms: int) -> (ready: bool, ok: bool) {
	pfd := win.WSA_POLLFD{fd = s, events = win.POLLRDNORM}
	n := win.WSAPoll(&pfd, 1, i32(timeout_ms))
	if n < 0 do return false, false
	return n > 0, true
}

// set_recv_timeout uses SO_RCVTIMEO. Winsock documents the socket as
// indeterminate after a timed-out recv on overlapped I/O; plain blocking AF_UNIX
// sockets keep working, which is what the bridge's periodic-wake loops rely on.
set_recv_timeout :: proc(s: Socket, timeout: time.Duration) -> bool {
	ms := u32(max(time.duration_milliseconds(timeout), 0))
	return win.setsockopt(s, win.SOL_SOCKET, win.SO_RCVTIMEO, &ms, size_of(ms)) == 0
}

// shutdown on Winsock does NOT wake a thread already blocked in recv (POSIX
// shutdown(SHUT_RD) does, and the bridge's teardown relies on it -- see AGENTS.md
// "Socket lifetime across threads"). CancelIoEx aborts that pending recv without
// closing the handle, so the reader still owns the close; the shutdown makes
// every later recv fail at once instead of blocking again.
shutdown :: proc(s: Socket, how: Shutdown_How) -> bool {
	h: i32
	switch how {
	case .Read:  h = 0 // SD_RECEIVE
	case .Write: h = win.SD_SEND
	case .Both:  h = win.SD_BOTH
	}
	ok := win.shutdown(s, h) == 0
	if how != .Write do win.CancelIoEx(win.HANDLE(uintptr(s)), nil)
	return ok
}

close :: proc(s: Socket) {
	win.closesocket(s)
}

// remove_path deletes a socket file left behind by a listener.
remove_path :: proc(path: string) {
	_ = os.remove(path)
}
