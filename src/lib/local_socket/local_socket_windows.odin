#+build windows
package local_socket

// Winsock AF_UNIX (Windows 10 1803+). The socket lives at a filesystem path like
// on POSIX; afunix.h's sockaddr_un has the same 108-byte sun_path. core:sys/windows
// does not declare it, so it is declared here.

import win "core:sys/windows"

Socket :: win.SOCKET

INVALID_SOCKET :: ~Socket(0)

AF_UNIX :: 1

Sockaddr_Un :: struct {
	sun_family: win.ADDRESS_FAMILY,
	sun_path:   [108]byte,
}

max_path_len :: proc() -> int {
	return len(Sockaddr_Un{}.sun_path) - 1
}

dial :: proc(path: string) -> (Socket, bool) {
	if !path_fits(path) do return INVALID_SOCKET, false
	win.ensure_winsock_initialized()
	s := win.socket(AF_UNIX, win.SOCK_STREAM, 0)
	if s == INVALID_SOCKET do return INVALID_SOCKET, false
	addr: Sockaddr_Un
	addr.sun_family = AF_UNIX
	copy(addr.sun_path[:], path)
	if win.connect(s, (^win.SOCKADDR_STORAGE_LH)(&addr), size_of(addr)) != 0 {
		win.closesocket(s)
		return INVALID_SOCKET, false
	}
	return s, true
}

send :: proc(s: Socket, bytes: []byte) -> int {
	return int(win.send(s, raw_data(bytes), i32(min(len(bytes), int(max(i32)))), 0))
}

recv :: proc(s: Socket, buf: []byte) -> int {
	return int(win.recv(s, raw_data(buf), i32(min(len(buf), int(max(i32)))), 0))
}

close :: proc(s: Socket) {
	win.closesocket(s)
}
