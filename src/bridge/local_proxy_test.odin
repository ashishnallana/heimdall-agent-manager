#+build !windows
package main

// REQ-XM-4 — hermetic tests for the local proxy's pure parsing layer.
//
// These cover the two pieces that decide whether a local connection is treated as
// HTTP at all, and how its request line is split. Both are pure string functions, so
// they need no sockets, no hub and no bridge runtime.

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sys/posix"
import "core:testing"

// ---- protocol sniff ------------------------------------------------------

@(test)
bridge_proxy_sniff_accepts_http_request_lines :: proc(t: ^testing.T) {
	lines := [?]string{
		"GET /proxy/sh_1/ HTTP/1.1",
		"POST /proxy/sh_1/api/x HTTP/1.1",
		"HEAD /proxy/sh_1/ HTTP/1.0",
		"DELETE /proxy/sh_1/a HTTP/1.1",
	}
	for line in lines {
		testing.expect(t, bridge_proxy_looks_like_http(line), "must sniff as HTTP")
	}
}

@(test)
bridge_proxy_sniff_rejects_jsonl_lines :: proc(t: ^testing.T) {
	// The JSONL protocol must keep working byte-for-byte, so no JSONL line may ever
	// be mistaken for HTTP — including one that mentions HTTP inside a string value.
	lines := [?]string{
		`{"v":1,"id":"a","token":"x","method":"agent.ping","params":{}}`,
		`{"v":1,"method":"wrapper.notifications.subscribe"}`,
		`{"v":1,"method":"agent.log","params":{"msg":"GET / HTTP/1.1"}}`,
		"",
		"GET /proxy/sh_1/",          // no HTTP version token
		"NOTAMETHOD /x HTTP/1.1",    // unknown method
	}
	for line in lines {
		testing.expect(t, !bridge_proxy_looks_like_http(line), "must NOT sniff as HTTP")
	}
}

// ---- request parsing -----------------------------------------------------

@(test)
bridge_proxy_parse_splits_session_and_path :: proc(t: ^testing.T) {
	heap := runtime.heap_allocator()
	head := "GET /proxy/sh_abc/api/items HTTP/1.1\r\nHost: 127.0.0.1:49324\r\nAccept: */*\r\n\r\n"
	req := bridge_proxy_parse_request(head, heap)
	testing.expect(t, req.ok, "must parse")
	testing.expect_value(t, req.method, "GET")
	testing.expect_value(t, req.session_id, "sh_abc")
	testing.expect_value(t, req.path, "/api/items")
	testing.expect_value(t, req.query, "")
	testing.expect(t, strings.contains(req.header_block, "Accept: */*"), "headers preserved")
	testing.expect_value(t, req.content_len, 0)
}

@(test)
bridge_proxy_parse_extracts_query :: proc(t: ^testing.T) {
	heap := runtime.heap_allocator()
	head := "GET /proxy/sh_1/search?q=a&b=2 HTTP/1.1\r\nHost: x\r\n\r\n"
	req := bridge_proxy_parse_request(head, heap)
	testing.expect(t, req.ok, "must parse")
	testing.expect_value(t, req.path, "/search")
	testing.expect_value(t, req.query, "q=a&b=2")
}

@(test)
bridge_proxy_parse_bare_session_root_path :: proc(t: ^testing.T) {
	// /proxy/<session_id> with no trailing slash must still forward as "/".
	heap := runtime.heap_allocator()
	head := "GET /proxy/sh_1 HTTP/1.1\r\nHost: x\r\n\r\n"
	req := bridge_proxy_parse_request(head, heap)
	testing.expect(t, req.ok, "must parse")
	testing.expect_value(t, req.session_id, "sh_1")
	testing.expect_value(t, req.path, "/")
}

@(test)
bridge_proxy_parse_reads_content_length :: proc(t: ^testing.T) {
	heap := runtime.heap_allocator()
	head := "POST /proxy/sh_1/submit HTTP/1.1\r\nHost: x\r\nContent-Length: 17\r\n\r\n"
	req := bridge_proxy_parse_request(head, heap)
	testing.expect(t, req.ok, "must parse")
	testing.expect_value(t, req.content_len, 17)
	// The header block is re-derived after the Content-Length scan consumes it;
	// this guards that recompute, which is easy to drop and silently sends no headers.
	testing.expect(t, strings.contains(req.header_block, "Content-Length: 17"), "header block intact after scan")
}

@(test)
bridge_proxy_parse_rejects_non_proxy_paths :: proc(t: ^testing.T) {
	heap := runtime.heap_allocator()
	bad := [?]string{
		"GET /other/sh_1/ HTTP/1.1\r\n\r\n", // not under /proxy/
		"GET /proxy/ HTTP/1.1\r\n\r\n",      // no session id
		"GET\r\n\r\n",                       // no target at all
	}
	for head in bad {
		req := bridge_proxy_parse_request(head, heap)
		testing.expect(t, !req.ok, "must reject")
	}
}

// ---- preview dial loopback -----------------------------------------------

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
	_ = posix.shutdown(posix.FD(listener), .RDWR)
	net.close(listener)

	conn, connected := bridge_preview_dial_loopback(bound.port)
	testing.expect(t, !connected, "closed IPv4 and IPv6 loopback port must report failure")
	if connected {
		net.close(conn)
	}
}
