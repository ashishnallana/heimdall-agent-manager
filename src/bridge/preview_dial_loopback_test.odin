package main

import "core:fmt"
import "core:net"
import "core:testing"

@(test)
test_preview_dial_loopback_ipv4 :: proc(t: ^testing.T) {
	listener, listen_err := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	if listen_err != nil {
		testing.fail_now(t, "could not bind IPv4 loopback listener")
	}
	defer net.close(listener)

	bound, endpoint_err := net.bound_endpoint(listener)
	if endpoint_err != nil {
		testing.fail_now(t, "could not read IPv4 loopback listener endpoint")
	}

	conn, connected := bridge_preview_dial_loopback(bound.port)
	testing.expect(t, connected, "IPv4 loopback listener must be reached")
	if connected {
		net.close(conn)
	}
}

@(test)
test_preview_dial_loopback_ipv6_fallback :: proc(t: ^testing.T) {
	listener, listen_err := net.listen_tcp({address = net.IP6_Loopback, port = 0})
	if listen_err != nil {
		fmt.println("SKIP: host cannot bind ::1; IPv6 fallback test not supported")
		return
	}
	defer net.close(listener)

	bound, endpoint_err := net.bound_endpoint(listener)
	if endpoint_err != nil {
		testing.fail_now(t, "could not read IPv6 loopback listener endpoint")
	}

	conn, connected := bridge_preview_dial_loopback(bound.port)
	testing.expect(t, connected, "IPv6-only loopback listener must be reached by fallback")
	if connected {
		net.close(conn)
	}
}

@(test)
test_preview_dial_loopback_reports_failure :: proc(t: ^testing.T) {
	listener, listen_err := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	if listen_err != nil {
		testing.fail_now(t, "could not reserve an unused loopback port")
	}
	bound, endpoint_err := net.bound_endpoint(listener)
	if endpoint_err != nil {
		net.close(listener)
		testing.fail_now(t, "could not read reserved loopback endpoint")
	}
	net.close(listener)

	conn, connected := bridge_preview_dial_loopback(bound.port)
	testing.expect(t, !connected, "closed IPv4 and IPv6 loopback port must report failure")
	if connected {
		net.close(conn)
	}
}
