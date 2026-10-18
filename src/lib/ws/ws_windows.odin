#+build windows
package ws

import "core:net"
import win "core:sys/windows"

// socket_send_once issues ONE OS send. retry reports a transient condition
// (WSAEWOULDBLOCK on a non-blocking socket, or the 50 ms send timeout set by
// send_socket_bytes) the caller should wait out; n <= 0 without retry is fatal.
// Winsock never raises SIGPIPE, so no MSG_NOSIGNAL equivalent is needed.
socket_send_once :: proc(socket: net.TCP_Socket, bytes: []byte) -> (n: int, retry: bool) {
	r := win.send(win.SOCKET(socket), raw_data(bytes), i32(min(len(bytes), int(max(i32)))), 0)
	if r < 0 {
		err := win.WSAGetLastError()
		return 0, err == win.WSAEWOULDBLOCK || err == WSAETIMEDOUT || err == WSAEINTR
	}
	return int(r), false
}

WSAEINTR     :: 10004
WSAETIMEDOUT :: 10060
