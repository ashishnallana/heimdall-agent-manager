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

@(private = "file")
preview_signed_headers := [?]contracts.HTTP_Header{
	{"X-Heimdall-Device-Id", "dev_1"}, {"X-Heimdall-Device-Ts", "1700000000000"},
	{"X-Heimdall-Device-Nonce", "nonce_1"}, {"X-Heimdall-Device-Sig", "sig_1"},
	{"Cookie", "app=1; authentik_proxy_x=hub-session"}, {"X-Authentik-Username", "admin"},
	{"Authorization", "Bearer hlut_hub_token"},
}

@(test)
test_preview_request_builder_dedicated_origin_forwards_device_signature :: proc(t: ^testing.T) {
	ctx := preview_forward_context(.Dedicated_Origin, "/p/sh_1", "preview.example", "203.0.113.7")
	request := _preview_build_http_request("POST", "/api/v1/vault/devices/register", "", preview_signed_headers[:], "{}", 3000, ctx)
	defer delete(request)
	expected_headers := []string{
		"X-Heimdall-Device-Id: dev_1\r\n", "X-Heimdall-Device-Ts: 1700000000000\r\n",
		"X-Heimdall-Device-Nonce: nonce_1\r\n", "X-Heimdall-Device-Sig: sig_1\r\n",
		// The signed path is the upstream path: the prefix is stripped, not re-signed.
		"POST /api/v1/vault/devices/register HTTP/1.1\r\n",
		// Preview-host identity is the Hub preview cookie only, so Authorization is the app's own.
		"Authorization: Bearer hlut_hub_token\r\n",
		"Cookie: app=1\r\n",
	}
	for expected in expected_headers {
		testing.expect(t, strings.contains(request, expected), expected)
	}
	forbidden_headers := []string{"authentik_proxy_x", "X-Authentik-", "hub-session"}
	for forbidden in forbidden_headers {
		testing.expect(t, !strings.contains(request, forbidden), forbidden)
	}
}

@(test)
test_preview_request_builder_legacy_drops_device_signature_cookie_and_bearer :: proc(t: ^testing.T) {
	ctx := preview_forward_context(.Legacy_Same_Origin, "/api/v1/preview/sh_1", "hub.example", "203.0.113.7")
	testing.expect(t, !ctx.forward_cookies && !ctx.add_referrer_policy && !ctx.forward_device_signature)
	testing.expect(t, ctx.strip_bearer_authorization)
	request := _preview_build_http_request("POST", "/api/v1/vault/devices/register", "", preview_signed_headers[:], "{}", 3000, ctx)
	defer delete(request)
	forbidden_headers := []string{"X-Heimdall-Device-", "Cookie:", "X-Authentik-", "Authorization:", "hlut_hub_token"}
	for forbidden in forbidden_headers {
		testing.expect(t, !strings.contains(request, forbidden), forbidden)
	}
	// The zero context (callers that predate transports) is the legacy shape for signatures.
	zero := _preview_build_http_request("GET", "/", "", preview_signed_headers[:], "", 3000)
	defer delete(zero)
	testing.expect(t, !strings.contains(zero, "X-Heimdall-Device-"), "zero context never forwards signatures")
}

@(test)
test_preview_request_builder_legacy_authorization_audit :: proc(t: ^testing.T) {
	ctx := preview_forward_context(.Legacy_Same_Origin, "/api/v1/preview/sh_1", "hub.example", "")
	cases := []struct{value: string, forwarded: bool}{
		{"Basic dXNlcjpwYXNz", true},
		{"Digest username=\"u\"", true},
		{"Bearer hlut_x", false},
		{"bearer hlut_x", false},
		{"BEARER\thlut_x", false},
		{"  Bearer hlut_x", false},
		{"Bearer", false},
		{"Bearerish token", true},
	}
	for c in cases {
		request := _preview_build_http_request("GET", "/", "", []contracts.HTTP_Header{{"Authorization", c.value}}, "", 3000, ctx)
		testing.expect_value(t, strings.contains(request, "Authorization:"), c.forwarded)
		delete(request)
	}
}
