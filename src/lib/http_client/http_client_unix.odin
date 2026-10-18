#+build !windows
package http_client

import "core:net"
import "core:sys/posix"

// connect_with_timeout connects a non-blocking socket, waiting at most timeout_ms
// (<= 0 waits indefinitely) for the handshake to complete.
connect_with_timeout :: proc(socket: net.TCP_Socket, endpoint: net.Endpoint, timeout_ms: int) -> bool {
	sockaddr, addr_len := endpoint_to_sockaddr(endpoint)
	result := posix.connect(posix.FD(socket), (^posix.sockaddr)(&sockaddr), addr_len)
	if result != .OK {
		errno := posix.errno()
		if errno != .EINPROGRESS do return false
		poll_timeout := i32(-1) if timeout_ms <= 0 else i32(timeout_ms)
		poll_fd := posix.pollfd{fd = posix.FD(socket), events = {.OUT}}
		ready := posix.poll(&poll_fd, 1, poll_timeout)
		if ready <= 0 do return false
		so_error: posix.Errno
		size := posix.socklen_t(size_of(so_error))
		if posix.getsockopt(posix.FD(socket), posix.SOL_SOCKET, .ERROR, &so_error, &size) != .OK do return false
		if so_error != nil do return false
	}
	return true
}

endpoint_to_sockaddr :: proc(ep: net.Endpoint) -> (sockaddr: posix.sockaddr_storage, addr_len: posix.socklen_t) {
	switch a in ep.address {
	case net.IP4_Address:
		when ODIN_OS == .Linux {
			(^posix.sockaddr_in)(&sockaddr)^ = posix.sockaddr_in{
				sin_family = .INET,
				sin_port = u16be(ep.port),
				sin_addr = transmute(posix.in_addr)a,
			}
		} else {
			(^posix.sockaddr_in)(&sockaddr)^ = posix.sockaddr_in{
				sin_len = size_of(posix.sockaddr_in),
				sin_family = .INET,
				sin_port = u16be(ep.port),
				sin_addr = transmute(posix.in_addr)a,
			}
		}
		addr_len = posix.socklen_t(size_of(posix.sockaddr_in))
		return
	case net.IP6_Address:
		when ODIN_OS == .Linux {
			(^posix.sockaddr_in6)(&sockaddr)^ = posix.sockaddr_in6{
				sin6_family = .INET6,
				sin6_port = u16be(ep.port),
				sin6_addr = transmute(posix.in6_addr)a,
			}
		} else {
			(^posix.sockaddr_in6)(&sockaddr)^ = posix.sockaddr_in6{
				sin6_len = size_of(posix.sockaddr_in6),
				sin6_family = .INET6,
				sin6_port = u16be(ep.port),
				sin6_addr = transmute(posix.in6_addr)a,
			}
		}
		addr_len = posix.socklen_t(size_of(posix.sockaddr_in6))
		return
	case:
		return
	}
}
