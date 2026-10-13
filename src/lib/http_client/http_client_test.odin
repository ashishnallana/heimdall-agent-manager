package http_client

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

// build_http_request must emit exactly one Host header, and honor
// include_port_in_host so the Web Push client can match reference clients
// (RFC 7230: the default :443/:80 port is omitted from the authority).

@(test)
build_http_request_includes_port_by_default :: proc(t: ^testing.T) {
	req := build_http_request("POST", "web.push.apple.com", 443, "/push/v2/abc", "body", nil)
	defer delete(req)
	testing.expect(t, strings.contains(req, "\r\nHost: web.push.apple.com:443\r\n"),
		"default Host header must keep host:port (existing behavior)")
	// Exactly one Host header.
	testing.expect_value(t, strings.count(req, "\r\nHost:"), 1)
}

@(test)
build_http_request_omits_default_port_when_requested :: proc(t: ^testing.T) {
	req := build_http_request("POST", "web.push.apple.com", 443, "/push/v2/abc", "body", nil, false)
	defer delete(req)
	testing.expect(t, strings.contains(req, "\r\nHost: web.push.apple.com\r\n"),
		"Host must be the bare authority when include_port_in_host=false")
	testing.expect(t, !strings.contains(req, "web.push.apple.com:443"),
		"the :443 default port must not appear anywhere")
	testing.expect_value(t, strings.count(req, "\r\nHost:"), 1)
}

@(test)
build_http_request_request_line_and_single_content_type :: proc(t: ^testing.T) {
	// A caller-supplied Content-Type must not be duplicated by the default.
	hdrs := []Header{{name = "Content-Type", value = "application/octet-stream"}}
	req := build_http_request("POST", "web.push.apple.com", 443, "/p", "x", hdrs, false)
	defer delete(req)
	testing.expect(t, strings.has_prefix(req, "POST /p HTTP/1.1\r\n"))
	testing.expect_value(t, strings.count(req, "Content-Type:"), 1)
	testing.expect(t, strings.contains(req, "Content-Length: 1\r\n"))
}

// ---- TLS transport selection (REQ-4/REQ-5: both helpers must be packaged) ----
//
// These pin the SHARED CONTRACT the ham-hub/ham-bridge runtimeInputs are sized
// against: socat is the default and openssl is the s_client fallback, so a package
// that ships only one of them breaks outbound https for one of the two settings.
// They go through the pure tls_client_command_for_backend rather than setting
// HAM_TLS_BACKEND, because the test runner is concurrent and env is process-global.

@(test)
tls_backend_defaults_to_socat :: proc(t: ^testing.T) {
	// Unset/empty, the explicit default, odd casing+spacing, and an unknown value
	// must ALL select socat — only the exact "s_client" may divert.
	backends := [?]string{"", "socat", " SOCAT ", "openssl", "unknown"}
	for backend in backends {
		cmd := tls_client_command_for_backend(backend, "hub.brolabs.ai", 443, "")
		defer delete(cmd)
		testing.expect_value(t, len(cmd), 3)
		testing.expect_value(t, cmd[0], "socat")
		testing.expect_value(t, cmd[1], "STDIO")
		testing.expect_value(t, cmd[2], "OPENSSL-CONNECT:hub.brolabs.ai:443,snihost=hub.brolabs.ai,verify=1,commonname=hub.brolabs.ai")
	}
}

@(test)
tls_backend_s_client_uses_openssl :: proc(t: ^testing.T) {
	backends := [?]string{"s_client", " S_Client "}
	for backend in backends {
		cmd := tls_client_command_for_backend(backend, "hub.brolabs.ai", 443, "/etc/ssl/ca.pem")
		defer delete(cmd)
		testing.expect_value(t, cmd[0], "openssl")
		testing.expect_value(t, cmd[1], "s_client")
		joined := strings.join(cmd, " ")
		defer delete(joined)
		testing.expect(t, strings.contains(joined, "-verify_return_error"), joined)
		testing.expect(t, strings.contains(joined, "-CAfile /etc/ssl/ca.pem"), joined)
		testing.expect(t, strings.has_suffix(joined, "-connect hub.brolabs.ai:443"), joined)
	}
}

// ---- download_to_file (REQ-DIST-4: heimdall update) ----

@(test)
split_url_decomposes_authority_and_path :: proc(t: ^testing.T) {
	host, port, secure, path, ok := split_url("https://github.com/o/r/releases/download/v1/x.tar.gz")
	testing.expect(t, ok, "https url parses")
	testing.expect(t, host == "github.com", fmt.tprintf("host: %s", host))
	testing.expect(t, port == 443, fmt.tprintf("default https port: %d", port))
	testing.expect(t, secure, "https is secure")
	testing.expect(t, path == "/o/r/releases/download/v1/x.tar.gz", fmt.tprintf("path kept: %s", path))

	host, port, secure, path, ok = split_url("http://127.0.0.1:8080/SHA256SUMS")
	testing.expect(t, ok, "http url with port parses")
	testing.expect(t, host == "127.0.0.1", fmt.tprintf("host: %s", host))
	testing.expect(t, port == 8080, fmt.tprintf("explicit port: %d", port))
	testing.expect(t, !secure, "http is not secure")
	testing.expect(t, path == "/SHA256SUMS", fmt.tprintf("path: %s", path))

	host, port, secure, path, ok = split_url("http://mirror.example.com")
	testing.expect(t, ok, "bare authority parses")
	testing.expect(t, path == "/", "missing path defaults to /")
	testing.expect(t, port == 80, "default http port")

	_, _, _, _, ok = split_url("ftp://mirror.example.com/x")
	testing.expect(t, !ok, "non-http scheme rejected")
	_, _, _, _, ok = split_url("http://:80/x")
	testing.expect(t, !ok, "empty host rejected")
	_, _, _, _, ok = split_url("http://host:notaport/x")
	testing.expect(t, !ok, "non-numeric port rejected")
	_, _, _, _, ok = split_url("http://host:99999/x")
	testing.expect(t, !ok, "out-of-range port rejected")
}

@(test)
resolve_redirect_url_handles_all_forms :: proc(t: ^testing.T) {
	absolute, ok := resolve_redirect_url("http://127.0.0.1:9/a/b", "https://cdn.example.com/x?sig=1")
	testing.expect(t, ok && absolute == "https://cdn.example.com/x?sig=1", fmt.tprintf("absolute Location kept: %s", absolute))
	defer delete(absolute)

	scheme_relative, ok2 := resolve_redirect_url("https://example.com/a/b", "//cdn.example.com/y")
	testing.expect(t, ok2 && scheme_relative == "https://cdn.example.com/y", fmt.tprintf("scheme-relative Location: %s", scheme_relative))
	defer delete(scheme_relative)

	root_relative, ok3 := resolve_redirect_url("http://127.0.0.1:9/a/b/c", "/final")
	testing.expect(t, ok3 && root_relative == "http://127.0.0.1:9/final", fmt.tprintf("root-relative Location: %s", root_relative))
	defer delete(root_relative)

	path_relative, ok4 := resolve_redirect_url("http://127.0.0.1:9/dist/index.html", "SHA256SUMS")
	testing.expect(t, ok4 && path_relative == "http://127.0.0.1:9/dist/SHA256SUMS", fmt.tprintf("path-relative Location: %s", path_relative))
	defer delete(path_relative)

	_, ok5 := resolve_redirect_url("http://127.0.0.1:9/", "")
	testing.expect(t, !ok5, "empty Location rejected")
}

@(test)
response_status_and_header_parsing :: proc(t: ^testing.T) {
	headers := "HTTP/1.1 302 Found\r\nLocation: http://cdn.example.com/x\r\nContent-Length: 0\r\n\r\n"
	testing.expect(t, response_status(headers) == 302, "status parsed")
	testing.expect(t, response_header_value(headers, "location") == "http://cdn.example.com/x", "header value is case-insensitive")
	testing.expect(t, response_header_value(headers, "Location") == "http://cdn.example.com/x", "exact-case lookup")
	testing.expect(t, response_header_value(headers, "X-Missing") == "", "missing header is empty")
	testing.expect(t, response_status("garbage") == 0, "garbage status line -> 0")
}

// Live download tests against an in-process mock server over real TCP. The
// mock thread performs NO heap allocation: responses are prebuilt in the test
// thread and served in sequence (one per accepted connection).

Http_Test_Mock :: struct {
	listener: net.TCP_Socket,
	responses: []string, // prebuilt full HTTP responses, served in order
	served:   int,
}

http_test_mock_thread :: proc(data: rawptr) {
	mock := cast(^Http_Test_Mock)data
	for mock.served < len(mock.responses) {
		client, _, aerr := net.accept_tcp(mock.listener)
		if aerr != nil do return
		_ = net.set_option(client, .Receive_Timeout, 3 * time.Second)
		// read the request (headers are enough; GET has no body)
		buf: [4096]byte
		total := 0
		for total < len(buf) {
			n, rerr := net.recv_tcp(client, buf[total:])
			if rerr != nil || n <= 0 do break
			total += n
			if strings.index(string(buf[:total]), "\r\n\r\n") >= 0 do break
		}
		if total > 0 {
			_, _ = net.send_tcp(client, transmute([]byte)mock.responses[mock.served])
			mock.served += 1
		}
		net.close(client)
	}
}

http_test_start_mock :: proc(t: ^testing.T, responses: []string) -> (^Http_Test_Mock, int, ^thread.Thread) {
	listener, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	testing.expect(t, err == nil, "mock listener binds")
	if err != nil do return nil, 0, nil
	bound, berr := net.bound_endpoint(listener)
	testing.expect(t, berr == nil, "mock bound endpoint")
	if berr != nil {
		net.close(listener)
		return nil, 0, nil
	}
	mock := new(Http_Test_Mock)
	mock.listener = listener
	mock.responses = responses
	handle := thread.create_and_start_with_data(mock, http_test_mock_thread)
	testing.expect(t, handle != nil, "mock thread starts")
	if handle == nil {
		net.close(listener)
		free(mock)
		return nil, 0, nil
	}
	return mock, int(bound.port), handle
}

http_test_mock_join :: proc(mock: ^Http_Test_Mock, handle: ^thread.Thread) {
	if handle != nil {
		thread.join(handle)
		thread.destroy(handle)
	}
	net.close(mock.listener)
}

http_test_response :: proc(status: int, reason, headers, body: string) -> string {
	return fmt.tprintf("HTTP/1.1 %d %s\r\n%sContent-Length: %d\r\nConnection: close\r\n\r\n%s", status, reason, headers, len(body), body)
}

@(test)
download_to_file_streams_content_length_body :: proc(t: ^testing.T) {
	body := strings.repeat("abcd", 4096) // 16 KiB, larger than one read buffer
	defer delete(body)
	// NOTE: fmt.tprintf results use the temp allocator — never delete() them.
	responses := make([]string, 1)
	responses[0] = http_test_response(200, "OK", "Content-Type: application/octet-stream\r\n", body)
	defer delete(responses)
	mock, port, handle := http_test_start_mock(t, responses)
	if mock == nil do return
	defer free(mock)

	dest := fmt.tprintf("/tmp/http-client-test-dl-%d.bin", time.to_unix_nanoseconds(time.now()) % 100000000)
	status, ok := download_to_file(fmt.tprintf("http://127.0.0.1:%d/release.tar.gz", port), dest, 5000)
	testing.expect(t, ok && status == 200, fmt.tprintf("download ok: status=%d ok=%v", status, ok))
	http_test_mock_join(mock, handle)
	testing.expect(t, mock.served == 1, "mock served exactly one request")
	data, rerr := os.read_entire_file(dest, context.allocator)
	testing.expect(t, rerr == nil, "dest file readable")
	if rerr == nil {
		testing.expect(t, string(data) == body, "streamed body matches exactly")
		delete(data)
	}
	_ = os.remove(dest)
	_, part_err := os.stat(fmt.tprintf("%s.part", dest), context.allocator)
	testing.expect(t, part_err != nil, "no .part file left behind")
}

@(test)
download_to_file_follows_redirect :: proc(t: ^testing.T) {
	final_body := "final-content"
	responses := make([]string, 2)
	responses[0] = "HTTP/1.1 302 Found\r\nLocation: /final.bin\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
	responses[1] = http_test_response(200, "OK", "", final_body)
	defer delete(responses)
	mock, port, handle := http_test_start_mock(t, responses)
	if mock == nil do return
	defer free(mock)

	dest := fmt.tprintf("/tmp/http-client-test-redir-%d.bin", time.to_unix_nanoseconds(time.now()) % 100000000)
	status, ok := download_to_file(fmt.tprintf("http://127.0.0.1:%d/start.bin", port), dest, 5000)
	testing.expect(t, ok && status == 200, fmt.tprintf("redirect followed to 200: status=%d ok=%v", status, ok))
	http_test_mock_join(mock, handle)
	testing.expect(t, mock.served == 2, "both connections served")
	data, rerr := os.read_entire_file(dest, context.allocator)
	testing.expect(t, rerr == nil, "dest file readable")
	if rerr == nil {
		testing.expect(t, string(data) == final_body, "redirected body matches")
		delete(data)
	}
	_ = os.remove(dest)
}

@(test)
download_to_file_decodes_chunked_body :: proc(t: ^testing.T) {
	responses := make([]string, 1)
	responses[0] = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n"
	defer delete(responses)
	mock, port, handle := http_test_start_mock(t, responses)
	if mock == nil do return
	defer free(mock)

	dest := fmt.tprintf("/tmp/http-client-test-chunked-%d.bin", time.to_unix_nanoseconds(time.now()) % 100000000)
	status, ok := download_to_file(fmt.tprintf("http://127.0.0.1:%d/chunked", port), dest, 5000)
	testing.expect(t, ok && status == 200, fmt.tprintf("chunked download ok: status=%d ok=%v", status, ok))
	http_test_mock_join(mock, handle)
	testing.expect(t, mock.served == 1, "mock served exactly one request")
	data, rerr := os.read_entire_file(dest, context.allocator)
	testing.expect(t, rerr == nil, "dest file readable")
	if rerr == nil {
		testing.expect(t, string(data) == "Wikipedia", "chunked body reassembled")
		delete(data)
	}
	_ = os.remove(dest)
}

@(test)
download_to_file_non_200_leaves_no_file :: proc(t: ^testing.T) {
	missing := http_test_response(404, "Not Found", "", "nope")
	responses := make([]string, 1)
	responses[0] = missing
	defer delete(responses)
	mock, port, handle := http_test_start_mock(t, responses)
	if mock == nil do return
	defer free(mock)

	dest := fmt.tprintf("/tmp/http-client-test-404-%d.bin", time.to_unix_nanoseconds(time.now()) % 100000000)
	status, ok := download_to_file(fmt.tprintf("http://127.0.0.1:%d/missing", port), dest, 5000)
	testing.expect(t, !ok && status == 404, fmt.tprintf("404 reported: status=%d ok=%v", status, ok))
	http_test_mock_join(mock, handle)
	testing.expect(t, mock.served == 1, "mock served exactly one request")
	_, stat_err := os.stat(dest, context.allocator)
	testing.expect(t, stat_err != nil, "destination not created on non-200")
	_, part_err := os.stat(fmt.tprintf("%s.part", dest), context.allocator)
	testing.expect(t, part_err != nil, "no .part file left behind on non-200")
}

// A fake `socat` on PATH that behaves like the real relay's half-close grace:
// after reading the request headers it waits ~100 ms, and if its stdin has been
// closed by then it exits WITHOUT answering (what real socat does once its
// default grace expires). A client that keeps stdin open until the response is
// complete gets HTTP 200.
FAKE_SOCAT_SCRIPT :: `#!/bin/bash
while IFS= read -r line; do [[ "$line" == "" || "$line" == $'\r' ]] && break; done
sleep 0.1
if read -t 0.05 -r _; then :; else rc=$?; [ "$rc" -gt 128 ] || exit 0; fi
printf 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok'
`

@(test)
tls_request_survives_a_slow_first_byte :: proc(t: ^testing.T) {
	dir := fmt.tprintf("%s/ham-fake-socat-%d", os.temp_dir(context.temp_allocator), time.to_unix_nanoseconds(time.now()))
	testing.expect_value(t, os.make_directory(dir), nil)
	defer os.remove_all(dir)
	script := strings.concatenate({dir, "/socat"}, context.temp_allocator)
	testing.expect_value(t, os.write_entire_file(script, transmute([]byte)string(FAKE_SOCAT_SCRIPT)), nil)
	testing.expect_value(t, os.chmod(script, {.Read_User, .Write_User, .Execute_User}), nil)
	old_path := os.get_env("PATH", context.temp_allocator)
	defer os.set_env("PATH", old_path)
	testing.expect_value(t, os.set_env("PATH", strings.concatenate({dir, ":", old_path}, context.temp_allocator)), nil)
	testing.expect_value(t, os.set_env("HAM_TLS_BACKEND", "socat"), nil)
	defer os.unset_env("HAM_TLS_BACKEND")

	resp, ok := request_with_headers_timeout("GET", "https://hub.invalid:443", "/api/v1/health", "", nil, 5000)
	testing.expect(t, ok, "a response must arrive even when the first byte is delayed")
	testing.expect_value(t, resp.status, 200)
	testing.expect_value(t, resp.body, "ok")
}
