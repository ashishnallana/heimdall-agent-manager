package http

import "core:strings"
import "core:testing"
import "base:runtime"

PREVIEW_TEST_PREFIX :: "/api/v1/preview/ss_1"
PREVIEW_TEST_PORT :: 5173

@(private = "file")
preview_filter_test_head :: proc(headers: string) -> string {
	return strings.concatenate({"HTTP/1.1 302 Found\r\n", headers, "\r\n"})
}

@(test)
test_preview_filter_response_head_security_headers :: proc(t: ^testing.T) {
	head := preview_filter_test_head(
		"Location: http://127.0.0.1:5173/login?x=1\r\n" +
		"Set-Cookie: sid=a; Domain=example.com; Path=/; HttpOnly\r\n" +
		"Service-Worker-Allowed: /\r\n" +
		"Content-Length: 0\r\n",
	)
	defer delete(head)
	actual := _preview_filter_response_head(head, PREVIEW_TEST_PREFIX, PREVIEW_TEST_PORT)
	defer delete(actual, runtime.heap_allocator())
	expected := "HTTP/1.1 302 Found\r\n" +
		"Location: /api/v1/preview/ss_1/login?x=1\r\n" +
		"Set-Cookie: sid=a; Path=/api/v1/preview/ss_1/; HttpOnly\r\n" +
		"Content-Length: 0\r\n\r\n"
	testing.expect_value(t, actual, expected)
}

@(test)
test_preview_filter_response_head_location_rules :: proc(t: ^testing.T) {
	cases := []struct {
		name:     string,
		location: string,
		expected: string,
	}{
		{"localhost http", "http://localhost:5173/a", PREVIEW_TEST_PREFIX + "/a"},
		{"loopback https", "https://127.0.0.1:5173/b?q=1", PREVIEW_TEST_PREFIX + "/b?q=1"},
		{"case-insensitive authority", "HTTP://LOCALHOST:5173/c", PREVIEW_TEST_PREFIX + "/c"},
		{"root absolute", "/assets/app.js", PREVIEW_TEST_PREFIX + "/assets/app.js"},
		{"different port", "http://127.0.0.1:8080/a", "http://127.0.0.1:8080/a"},
		{"port prefix collision", "http://127.0.0.1:51730/a", "http://127.0.0.1:51730/a"},
		{"external", "https://example.com/a", "https://example.com/a"},
		{"scheme relative", "//example.com/a", "//example.com/a"},
		{"already prefixed", PREVIEW_TEST_PREFIX + "/a", PREVIEW_TEST_PREFIX + "/a"},
		{"relative", "next/page", "next/page"},
	}
	for tc in cases {
		head := preview_filter_test_head(strings.concatenate({"Location: ", tc.location, "\r\n"}, context.temp_allocator))
		actual := _preview_filter_response_head(head, PREVIEW_TEST_PREFIX, PREVIEW_TEST_PORT)
		expected := preview_filter_test_head(strings.concatenate({"Location: ", tc.expected, "\r\n"}, context.temp_allocator))
		testing.expect_value(t, actual, expected)
		delete(expected)
		delete(actual, runtime.heap_allocator())
		delete(head)
	}
}

@(test)
test_preview_filter_response_head_trims_names_and_drops_folding :: proc(t: ^testing.T) {
	cases := []string{
		"HTTP/1.1 200 OK\r\nService-Worker-Allowed : /\r\n\r\n",
		"HTTP/1.1 200 OK\r\nSet-Cookie\t: a=1\r\n\r\n",
		"HTTP/1.1 200 OK\r\n\tSet-Cookie: a=1\r\n\r\n",
	}
	for wire in cases {
		pending := make([dynamic]byte, 0, 128)
		result, complete, rejected := _preview_response_head_feed(&pending, transmute([]byte)wire, PREVIEW_TEST_PREFIX, PREVIEW_TEST_PORT)
		testing.expect_value(t, result, PREVIEW_BAD_GATEWAY_RESPONSE)
		testing.expect(t, !complete)
		testing.expect(t, rejected)
		delete(result, runtime.heap_allocator())
		delete(pending)
	}
}

@(test)
test_preview_filter_response_head_mixed_case_and_multiple_cookies :: proc(t: ^testing.T) {
	head := preview_filter_test_head(
		"sErViCe-WoRkEr-AlLoWeD: /\r\n" +
		"sEt-CoOkIe: a=1; Secure\r\n" +
		"SET-COOKIE: b=2; domain=example.com; path=/old; SameSite=Lax\r\n" +
		"lOcAtIoN: /login\r\n",
	)
	defer delete(head)
	actual := _preview_filter_response_head(head, PREVIEW_TEST_PREFIX, PREVIEW_TEST_PORT)
	defer delete(actual, runtime.heap_allocator())
	testing.expect(t, !strings.contains(strings.to_lower(actual, context.temp_allocator), "service-worker-allowed"))
	testing.expect(t, strings.contains(actual, "sEt-CoOkIe: a=1; Secure; Path=/api/v1/preview/ss_1/\r\n"))
	testing.expect(t, strings.contains(actual, "SET-COOKIE: b=2; Path=/api/v1/preview/ss_1/; SameSite=Lax\r\n"))
	testing.expect(t, strings.contains(actual, "lOcAtIoN: /api/v1/preview/ss_1/login\r\n"))
}

@(test)
test_preview_response_head_feed_split_preserves_body :: proc(t: ^testing.T) {
	pending := make([dynamic]byte, 0, 64)
	defer delete(pending)
	first_text := "HTTP/1.1 200 OK\r\nSet-Cookie: sid=a; Dom"
	first := transmute([]byte)first_text
	result, complete, overflow := _preview_response_head_feed(&pending, first, PREVIEW_TEST_PREFIX, PREVIEW_TEST_PORT)
	testing.expect(t, !complete)
	testing.expect(t, !overflow)
	testing.expect_value(t, result, "")

	second_text := "ain=example.com\r\nContent-Length: 4\r\n\r\nB\x00DY"
	second := transmute([]byte)second_text
	result, complete, overflow = _preview_response_head_feed(&pending, second, PREVIEW_TEST_PREFIX, PREVIEW_TEST_PORT)
	defer delete(result, runtime.heap_allocator())
	testing.expect(t, complete)
	testing.expect(t, !overflow)
	expected := "HTTP/1.1 200 OK\r\nSet-Cookie: sid=a; Path=/api/v1/preview/ss_1/\r\nContent-Length: 4\r\n\r\nB\x00DY"
	testing.expect_value(t, result, expected)
	testing.expect_value(t, len(pending), 0)
}

@(test)
test_preview_response_head_feed_overflow :: proc(t: ^testing.T) {
	pending := make([dynamic]byte, 0, PREVIEW_RESPONSE_HEAD_MAX + 8)
	defer delete(pending)
	oversized := make([]byte, PREVIEW_RESPONSE_HEAD_MAX + 1)
	defer delete(oversized)
	for &b in oversized do b = 'a'
	result, complete, overflow := _preview_response_head_feed(&pending, oversized, PREVIEW_TEST_PREFIX, PREVIEW_TEST_PORT)
	testing.expect_value(t, result, PREVIEW_BAD_GATEWAY_RESPONSE)
	testing.expect(t, !complete)
	testing.expect(t, overflow)
	delete(result, runtime.heap_allocator())

	// A terminator in the same chunk must not make an oversized head acceptable.
	clear(&pending)
	complete_head := make([dynamic]byte, 0, PREVIEW_RESPONSE_HEAD_MAX + 4)
	defer delete(complete_head)
	append(&complete_head, "HTTP/1.1 200 OK\r\nX-Fill: ")
	for len(complete_head) < PREVIEW_RESPONSE_HEAD_MAX do append(&complete_head, 'a')
	append(&complete_head, "\r\n\r\n")
	result, complete, overflow = _preview_response_head_feed(&pending, complete_head[:], PREVIEW_TEST_PREFIX, PREVIEW_TEST_PORT)
	testing.expect_value(t, result, PREVIEW_BAD_GATEWAY_RESPONSE)
	testing.expect(t, !complete)
	testing.expect(t, overflow)
	delete(result, runtime.heap_allocator())

	// The cap is cumulative across interim and final heads, not reset after a 1xx.
	clear(&pending)
	interim_chain := make([dynamic]byte, 0, PREVIEW_RESPONSE_HEAD_MAX + 64)
	defer delete(interim_chain)
	append(&interim_chain, "HTTP/1.1 103 Early Hints\r\nX-Fill: ")
	for len(interim_chain) < PREVIEW_RESPONSE_HEAD_MAX-24 do append(&interim_chain, 'a')
	append(&interim_chain, "\r\n\r\nHTTP/1.1 200 OK\r\nX: y\r\n\r\n")
	result, complete, overflow = _preview_response_head_feed(&pending, interim_chain[:], PREVIEW_TEST_PREFIX, PREVIEW_TEST_PORT)
	testing.expect_value(t, result, PREVIEW_BAD_GATEWAY_RESPONSE)
	testing.expect(t, !complete)
	testing.expect(t, overflow)
	delete(result, runtime.heap_allocator())
}

@(test)
test_preview_response_head_feed_filters_interim_and_final_heads :: proc(t: ^testing.T) {
	pending := make([dynamic]byte, 0, 256)
	defer delete(pending)
	wire := "HTTP/1.1 103 Early Hints\r\nLink: </style.css>; rel=preload\r\n\r\n" +
		"HTTP/1.1 302 Found\r\nService-Worker-Allowed: /\r\nSet-Cookie: s=x; Domain=example.com; Path=/\r\nLocation: /x\r\nContent-Length: 1\r\n\r\nB"
	result, complete, overflow := _preview_response_head_feed(&pending, transmute([]byte)wire, PREVIEW_TEST_PREFIX, PREVIEW_TEST_PORT)
	defer delete(result, runtime.heap_allocator())
	testing.expect(t, complete)
	testing.expect(t, !overflow)
	testing.expect(t, strings.has_prefix(result, "HTTP/1.1 103 Early Hints\r\nLink: </style.css>; rel=preload\r\n\r\nHTTP/1.1 302 Found\r\n"))
	testing.expect(t, !strings.contains(strings.to_lower(result, context.temp_allocator), "service-worker-allowed"))
	testing.expect(t, strings.contains(result, "Set-Cookie: s=x; Path=/api/v1/preview/ss_1/\r\n"))
	testing.expect(t, strings.contains(result, "Location: /api/v1/preview/ss_1/x\r\n"))
	testing.expect(t, strings.has_suffix(result, "\r\n\r\nB"))
}

@(test)
test_preview_response_head_feed_split_after_interim :: proc(t: ^testing.T) {
	pending := make([dynamic]byte, 0, 128)
	defer delete(pending)
	first_text := "HTTP/1.1 103 Early Hints\r\n\r\nHTTP/1.1 302 Found\r\nSet-Cookie: a=1; Dom"
	result, complete, overflow := _preview_response_head_feed(&pending, transmute([]byte)first_text, PREVIEW_TEST_PREFIX, PREVIEW_TEST_PORT)
	testing.expect_value(t, result, "")
	testing.expect(t, !complete)
	testing.expect(t, !overflow)
	second_text := "ain=example.com\r\nLocation: /next\r\n\r\nbody"
	result, complete, overflow = _preview_response_head_feed(&pending, transmute([]byte)second_text, PREVIEW_TEST_PREFIX, PREVIEW_TEST_PORT)
	defer delete(result, runtime.heap_allocator())
	testing.expect(t, complete)
	testing.expect(t, !overflow)
	testing.expect(t, strings.contains(result, "HTTP/1.1 103 Early Hints\r\n\r\nHTTP/1.1 302 Found\r\n"))
	testing.expect(t, strings.contains(result, "Set-Cookie: a=1; Path=/api/v1/preview/ss_1/\r\n"))
	testing.expect(t, strings.has_suffix(result, "\r\n\r\nbody"))
}

@(test)
test_preview_response_head_feed_unsolicited_continue :: proc(t: ^testing.T) {
	pending := make([dynamic]byte, 0, 128)
	defer delete(pending)
	wire := "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nSet-Cookie: a=1\r\n\r\n"
	result, complete, overflow := _preview_response_head_feed(&pending, transmute([]byte)wire, PREVIEW_TEST_PREFIX, PREVIEW_TEST_PORT)
	defer delete(result, runtime.heap_allocator())
	testing.expect(t, complete)
	testing.expect(t, !overflow)
	testing.expect(t, strings.contains(result, "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.contains(result, "Set-Cookie: a=1; Path=/api/v1/preview/ss_1/\r\n"))
}

@(test)
test_preview_response_head_feed_websocket_101_passthrough :: proc(t: ^testing.T) {
	pending := make([dynamic]byte, 0, 64)
	defer delete(pending)
	wire := "HTTP/1.1 101 Switching Protocols\r\nService-Worker-Allowed: /\r\nSet-Cookie: raw=1; Path=/\r\nLocation: /raw\r\n\r\n\x81\x02ok"
	result, complete, overflow := _preview_response_head_feed(&pending, transmute([]byte)wire, PREVIEW_TEST_PREFIX, PREVIEW_TEST_PORT, true)
	defer delete(result, runtime.heap_allocator())
	testing.expect(t, complete)
	testing.expect(t, !overflow)
	testing.expect_value(t, result, wire)
	testing.expect_value(t, len(pending), 0)
}

@(test)
test_preview_response_head_feed_accepts_browser_line_endings :: proc(t: ^testing.T) {
	cases := []struct {
		name: string,
		wire: string,
	}{
		{"lf only", "HTTP/1.1 200 OK\nService-Worker-Allowed: /\nSet-Cookie: s=x; Path=/\nLocation: /x\n\nbody"},
		{"mixed", "HTTP/1.1 200 OK\r\nService-Worker-Allowed: /\nSet-Cookie: s=x; Path=/\r\nLocation: /x\n\r\nbody"},
		{"body contains crlf terminator", "HTTP/1.1 200 OK\nService-Worker-Allowed: /\nSet-Cookie: s=x; Path=/\nLocation: /x\n\nbody\r\n\r\ntail"},
	}
	for tc in cases {
		pending := make([dynamic]byte, 0, 128)
		result, complete, overflow := _preview_response_head_feed(&pending, transmute([]byte)tc.wire, PREVIEW_TEST_PREFIX, PREVIEW_TEST_PORT)
		testing.expect(t, complete)
		testing.expect(t, !overflow)
		testing.expect(t, strings.has_prefix(result, "HTTP/1.1 200 OK\r\n"))
		testing.expect(t, !strings.contains(strings.to_lower(result, context.temp_allocator), "service-worker-allowed"))
		testing.expect(t, strings.contains(result, "Set-Cookie: s=x; Path=/api/v1/preview/ss_1/\r\n"))
		testing.expect(t, strings.contains(result, "Location: /api/v1/preview/ss_1/x\r\n"))
		delete(result, runtime.heap_allocator())
		delete(pending)
	}
}

@(test)
test_preview_response_head_feed_lf_head_split_across_chunks :: proc(t: ^testing.T) {
	pending := make([dynamic]byte, 0, 128)
	defer delete(pending)
	first := "HTTP/1.1 200 OK\nSet-Cookie: s=x; Path=/\nLocation: /x\n"
	result, complete, overflow := _preview_response_head_feed(&pending, transmute([]byte)first, PREVIEW_TEST_PREFIX, PREVIEW_TEST_PORT)
	testing.expect_value(t, result, "")
	testing.expect(t, !complete)
	testing.expect(t, !overflow)
	second := "\nbody"
	result, complete, overflow = _preview_response_head_feed(&pending, transmute([]byte)second, PREVIEW_TEST_PREFIX, PREVIEW_TEST_PORT)
	defer delete(result, runtime.heap_allocator())
	testing.expect(t, complete)
	testing.expect(t, !overflow)
	testing.expect(t, strings.contains(result, "Set-Cookie: s=x; Path=/api/v1/preview/ss_1/\r\n"))
	testing.expect(t, strings.has_suffix(result, "\r\n\r\nbody"))
}

@(test)
test_preview_response_head_eof_rejects_incomplete_head :: proc(t: ^testing.T) {
	pending_text := "HTTP/1.1 200 OK\r\nSet-Cookie: s=x; Path=/\r\n"
	result := _preview_response_head_eof(transmute([]byte)pending_text)
	defer delete(result, runtime.heap_allocator())
	testing.expect_value(t, result, PREVIEW_BAD_GATEWAY_RESPONSE)
	testing.expect(t, !strings.contains(strings.to_lower(result, context.temp_allocator), "set-cookie"))
	testing.expect_value(t, _preview_response_head_eof(nil), "")
}

@(test)
test_preview_response_head_feed_rejects_invalid_framing :: proc(t: ^testing.T) {
	cases := []string{
		"  HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nSet-Cookie: s=x\r\n\r\n",
		"\nHTTP/1.1 103 Early Hints\r\n\r\nHTTP/1.1 200 OK\r\n\r\n",
		"NOTHTTP 200 OK\r\nSet-Cookie: s=x\r\n\r\n",
		"HTTP/1.1 200 OK\r\nX-A: a\rSet-Cookie: s=x\r\n\r\n",
		"HTTP/1.1\r200 OK\r\nSet-Cookie: s=x\r\n\r\n",
		"HTTP/1.1 200 OK\r\nX-Nul: a\x00b\r\n\r\n",
		"HTTP/1.1 200 OK\r\nNo Colon Here\r\n\r\n",
		"http/1.1 200 OK\r\nSet-Cookie: s=x\r\n\r\n",
	}
	for wire in cases {
		pending := make([dynamic]byte, 0, 128)
		result, complete, rejected := _preview_response_head_feed(&pending, transmute([]byte)wire, PREVIEW_TEST_PREFIX, PREVIEW_TEST_PORT)
		testing.expect_value(t, result, PREVIEW_BAD_GATEWAY_RESPONSE)
		testing.expect(t, !complete)
		testing.expect(t, rejected)
		delete(result, runtime.heap_allocator())
		delete(pending)
	}
}

@(test)
test_preview_response_head_feed_limits_interim_heads :: proc(t: ^testing.T) {
	pending := make([dynamic]byte, 0, 256)
	defer delete(pending)
	wire := "HTTP/1.1 100 Continue\r\n\r\n" +
		"HTTP/1.1 102 Processing\r\n\r\n" +
		"HTTP/1.1 103 Early Hints\r\n\r\n" +
		"HTTP/1.1 100 Continue\r\n\r\n" +
		"HTTP/1.1 102 Processing\r\n\r\n" +
		"HTTP/1.1 103 Early Hints\r\n\r\n" +
		"HTTP/1.1 200 OK\r\n\r\n"
	result, complete, rejected := _preview_response_head_feed(&pending, transmute([]byte)wire, PREVIEW_TEST_PREFIX, PREVIEW_TEST_PORT)
	defer delete(result, runtime.heap_allocator())
	testing.expect_value(t, result, PREVIEW_BAD_GATEWAY_RESPONSE)
	testing.expect(t, !complete)
	testing.expect(t, rejected)
}

@(test)
test_preview_response_head_feed_accepts_obs_text_reason :: proc(t: ^testing.T) {
	pending := make([dynamic]byte, 0, 64)
	defer delete(pending)
	wire := "HTTP/1.1 200 O\xffK\r\nSet-Cookie: s=x\r\n\r\n"
	result, complete, rejected := _preview_response_head_feed(&pending, transmute([]byte)wire, PREVIEW_TEST_PREFIX, PREVIEW_TEST_PORT)
	defer delete(result, runtime.heap_allocator())
	testing.expect(t, complete)
	testing.expect(t, !rejected)
	testing.expect(t, strings.has_prefix(result, "HTTP/1.1 200 O\xffK\r\n"))
	testing.expect(t, strings.contains(result, "Set-Cookie: s=x; Path=/api/v1/preview/ss_1/\r\n"))
}
