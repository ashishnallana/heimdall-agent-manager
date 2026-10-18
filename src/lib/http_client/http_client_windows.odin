#+build windows
package http_client

import "core:net"
import win "core:sys/windows"

// connect_with_timeout connects a non-blocking socket, waiting at most timeout_ms
// (<= 0 waits indefinitely) for the handshake to complete.
connect_with_timeout :: proc(socket: net.TCP_Socket, endpoint: net.Endpoint, timeout_ms: int) -> bool {
	sockaddr, addr_len := endpoint_to_sockaddr(endpoint)
	if addr_len == 0 do return false
	if win.connect(win.SOCKET(socket), &sockaddr, addr_len) == 0 do return true
	if win.WSAGetLastError() != win.WSAEWOULDBLOCK do return false
	poll_fd := win.WSA_POLLFD{fd = win.SOCKET(socket), events = win.POLLWRNORM}
	ready := win.WSAPoll(&poll_fd, 1, -1 if timeout_ms <= 0 else i32(timeout_ms))
	if ready <= 0 do return false
	so_error: i32
	size := i32(size_of(so_error))
	if win.getsockopt(win.SOCKET(socket), win.SOL_SOCKET, win.SO_ERROR, ([^]u8)(&so_error), &size) != 0 do return false
	return so_error == 0
}

endpoint_to_sockaddr :: proc(ep: net.Endpoint) -> (sockaddr: win.SOCKADDR_STORAGE_LH, addr_len: i32) {
	switch a in ep.address {
	case net.IP4_Address:
		(^win.sockaddr_in)(&sockaddr)^ = win.sockaddr_in{
			sin_family = win.ADDRESS_FAMILY(win.AF_INET),
			sin_port = u16be(ep.port),
			sin_addr = transmute(win.in_addr)a,
		}
		addr_len = size_of(win.sockaddr_in)
	case net.IP6_Address:
		(^win.sockaddr_in6)(&sockaddr)^ = win.sockaddr_in6{
			sin6_family = win.ADDRESS_FAMILY(win.AF_INET6),
			sin6_port = u16be(ep.port),
			sin6_addr = transmute(win.in6_addr)a,
		}
		addr_len = size_of(win.sockaddr_in6)
	}
	return
}
