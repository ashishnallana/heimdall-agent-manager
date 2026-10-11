package http

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

@(test)
test_preview_request_builder_allowlist_and_forward_context :: proc(t: ^testing.T) {
	headers := []contracts.HTTP_Header{
		{"Origin", "https://app.example"}, {"Authorization", "Basic abc"},
		{"X-CSRF-Token", "csrf-a"}, {"X-CSRFToken", "csrf-b"},
		{"X-XSRF-Token", "xsrf"}, {"X-Requested-With", "fetch"},
		{"If-Match", `"etag"`}, {"If-Unmodified-Since", "yesterday"},
		{"Content-Encoding", "gzip"}, {"User-Agent", "preview-test"},
		{"Referer", "https://hub.example/preview"},
		{"Cookie", "secret=1"}, {"X-Authentik-Username", "admin"},
		{"X-Forwarded-For", "1.2.3.4"}, {"Forwarded", "for=evil"},
		{"X-Custom", "x"},
	}
	ctx := Preview_Forward_Context{
		prefix = "/api/v1/preview/sess_1", host = "hub.example",
		proto = "https", client_addr = "203.0.113.7",
	}
	request := _preview_build_http_request("POST", "/api", "x=1", headers, "body", 3000, ctx)
	defer delete(request)

	expected_headers := []string{
		"Origin: https://app.example\r\n", "Authorization: Basic abc\r\n",
		"X-CSRF-Token: csrf-a\r\n", "X-CSRFToken: csrf-b\r\n",
		"X-XSRF-Token: xsrf\r\n", "X-Requested-With: fetch\r\n",
		"If-Match: \"etag\"\r\n", "If-Unmodified-Since: yesterday\r\n",
		"Content-Encoding: gzip\r\n", "User-Agent: preview-test\r\n",
		"Referer: https://hub.example/preview\r\n",
		"X-Forwarded-Host: hub.example\r\n", "X-Forwarded-Proto: https\r\n",
		"X-Forwarded-Prefix: /api/v1/preview/sess_1\r\n",
		"X-Forwarded-For: 203.0.113.7\r\n",
	}
	for expected in expected_headers {
		testing.expect(t, strings.contains(request, expected), expected)
	}
	forbidden_headers := []string{"Cookie:", "X-Authentik-", "1.2.3.4", "Forwarded: for=evil", "X-Custom:"}
	for forbidden in forbidden_headers {
		testing.expect(t, !strings.contains(request, forbidden), forbidden)
	}
}

@(test)
test_preview_request_builder_empty_forward_context :: proc(t: ^testing.T) {
	request := _preview_build_http_request("GET", "/", "", nil, "", 3000)
	defer delete(request)
	testing.expect(t, !strings.contains(request, "X-Forwarded-"), "empty context omits forwarding headers")
	testing.expect(t, strings.contains(request, "Connection: close\r\n"), "ordinary request keeps connection close")
}

@(test)
test_preview_request_builder_websocket_passthrough :: proc(t: ^testing.T) {
	headers := []contracts.HTTP_Header{
		{"Upgrade", "websocket"}, {"Connection", "Upgrade"},
		{"Sec-WebSocket-Key", "key"}, {"Sec-WebSocket-Version", "13"},
		{"Sec-WebSocket-Protocol", "chat"}, {"Sec-WebSocket-Extensions", "permessage-deflate"},
	}
	request := _preview_build_http_request("GET", "/ws", "", headers, "", 3000, {}, true)
	defer delete(request)
	expected_headers := []string{"Upgrade: websocket\r\n", "Connection: Upgrade\r\n", "Sec-WebSocket-Key: key\r\n", "Sec-WebSocket-Version: 13\r\n", "Sec-WebSocket-Protocol: chat\r\n", "Sec-WebSocket-Extensions: permessage-deflate\r\n"}
	for expected in expected_headers {
		testing.expect(t, strings.contains(request, expected), expected)
	}
	testing.expect(t, !strings.contains(request, "Connection: close\r\n"), "websocket omits connection close")
}

@(test)
test_preview_client_addr_strips_transport_port :: proc(t: ^testing.T) {
	values := []string{"127.0.0.1:4321", "127.0.0.1", "[::1]:4321", "::1"}
	expected := []string{"127.0.0.1", "127.0.0.1", "::1", "::1"}
	for value, index in values {
		actual := _preview_client_addr(value)
		testing.expect_value(t, actual, expected[index])
		delete(actual)
	}
}
