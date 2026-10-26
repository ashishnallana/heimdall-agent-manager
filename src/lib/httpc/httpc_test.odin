package httpc

import "core:bytes"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(private = "file")
must_init :: proc(t: ^testing.T) -> bool {
	ok, msg := init()
	return testing.expectf(t, ok, "init failed: %s", msg)
}

// ---- URL building --------------------------------------------------------------

@(test)
url_segments_and_query_are_encoded_by_curl :: proc(t: ^testing.T) {
	if !must_init(t) do return
	base, err := parse_url("https://hub.example:8443/heimdall/")
	testing.expect_value(t, err, Error.None)
	got, berr := build_url(base, {"api", "v1", "chains", "a b/c?d#e%f", "é"}, {
		{"q", "a&b=c d+e"},
		{"pct", "100%"},
		{"hash", "#x"},
		{"we&ird name", "v"},
		{"empty", ""},
	}, context.temp_allocator)
	testing.expect_value(t, berr, Error.None)
	// Each segment is one segment: '/', '?', '#', '%' and non-ASCII are escaped.
	testing.expect(t, strings.has_prefix(got, "https://hub.example:8443/heimdall/api/v1/chains/a%20b%2Fc%3Fd%23e%25f/%C3%A9?"), got)
	query := got[strings.index_byte(got, '?') + 1:]
	pairs := strings.split(query, "&", context.temp_allocator)
	testing.expect_value(t, len(pairs), 5)
	// Values can never split into extra pairs or fragments.
	for p in pairs {
		testing.expect(t, strings.count(p, "=") == 1, p)
		testing.expect(t, !strings.contains(p, "#"), p)
		testing.expect(t, !strings.contains(p, " "), p)
	}
	testing.expect(t, pairs[0] == "q=a%26b%3Dc+d%2Be", pairs[0])
	testing.expect(t, pairs[1] == "pct=100%25", pairs[1])
	testing.expect(t, pairs[2] == "hash=%23x", pairs[2])
	testing.expect(t, pairs[3] == "we%26ird+name=v", pairs[3])
	testing.expect(t, pairs[4] == "empty=", pairs[4])
}

@(test)
url_base_without_segments_keeps_its_path_and_query :: proc(t: ^testing.T) {
	if !must_init(t) do return
	base, _ := parse_url("https://idp.example/oauth/userinfo/")
	got, _ := build_url(base, allocator = context.temp_allocator)
	testing.expect_value(t, got, "https://idp.example/oauth/userinfo/")
	withq, _ := parse_url("https://api.example/v1/items?fixed=1")
	got2, _ := build_url(withq, {"x"}, {{"page", "2"}}, context.temp_allocator)
	testing.expect_value(t, got2, "https://api.example/v1/items/x?fixed=1&page=2")
	root, _ := parse_url("http://127.0.0.1:9")
	got3, _ := build_url(root, {"api", "v1"}, allocator = context.temp_allocator)
	testing.expect_value(t, got3, "http://127.0.0.1:9/api/v1")
}

@(test)
url_from_parts_builds_loopback_targets :: proc(t: ^testing.T) {
	if !must_init(t) do return
	u, err := url_from_parts("http", "127.0.0.1", 49324)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, url_string(u), "http://127.0.0.1:49324/")
	v6, err6 := url_from_parts("https", "::1", 8443)
	testing.expect_value(t, err6, Error.None)
	testing.expect_value(t, url_string(v6), "https://[::1]:8443/")
	_, bad_port := url_from_parts("http", "127.0.0.1", 0)
	testing.expect_value(t, bad_port, Error.Invalid_Url)
	_, bad_scheme := url_from_parts("ftp", "127.0.0.1", 21)
	testing.expect_value(t, bad_scheme, Error.Invalid_Url)
	_, bad_host := url_from_parts("http", "a b/c", 80)
	testing.expect_value(t, bad_host, Error.Invalid_Url)
}

@(test)
url_rejects_unsafe_input :: proc(t: ^testing.T) {
	if !must_init(t) do return
	bad := []string{
		"ftp://example.com/", "http://user:pw@example.com/", "http://example.com/#frag",
		"example.com", "", "http://exa mple.com/", "http://example.com/\r\nX: y", "file:///etc/passwd",
	}
	for b in bad {
		_, err := parse_url(b)
		testing.expectf(t, err == .Invalid_Url, "%q should be rejected, got %v", b, err)
	}
	base, _ := parse_url("http://example.com")
	bad_segments := []string{"", ".", "..", "a\nb", "a\x00b"}
	for seg in bad_segments {
		_, err := build_url(base, {seg}, allocator = context.temp_allocator)
		testing.expectf(t, err == .Invalid_Url, "segment %q should be rejected", seg)
	}
	_, qerr := build_url(base, nil, {{"", "v"}}, context.temp_allocator)
	testing.expect_value(t, qerr, Error.Invalid_Url)
	_, qeq := build_url(base, nil, {{"a=b", "v"}}, context.temp_allocator)
	testing.expect_value(t, qeq, Error.Invalid_Url)
	_, qerr2 := build_url(base, nil, {{"a", "x\r\ny"}}, context.temp_allocator)
	testing.expect_value(t, qerr2, Error.Invalid_Url)
}

@(test)
build_target_renders_origin_form :: proc(t: ^testing.T) {
	if !must_init(t) do return
	got, err := build_target({"api", "v1", "tasks", "t 1"}, {{"status", "in progress"}}, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect(t, got == "/api/v1/tasks/t%201?status=in+progress" || got == "/api/v1/tasks/t%201?status=in%20progress", got)
	plain, _ := build_target({"health"}, allocator = context.temp_allocator)
	testing.expect_value(t, plain, "/health")
}

@(test)
relay_target_validation :: proc(t: ^testing.T) {
	good := []string{"/api/v1/x", "/api/v1/x?y=1&z=%2F", "/", "/a:b@c!$'()*+,;="}
	for g in good {
		_, _, ok := relay_target_split(g)
		testing.expectf(t, ok, "%q should be accepted", g)
	}
	bad := []string{"", "api", "//evil.example/x", "/a b", "/../x", "/a/./b", "/x#frag", "/x\r\nHost: y", "/%zz", "/%2e%2e/x", "/x%", "/x%4"}
	for b in bad {
		_, _, ok := relay_target_split(b)
		testing.expectf(t, !ok, "%q should be rejected", b)
	}
}

// ---- headers --------------------------------------------------------------------

@(test)
header_validation_rejects_injection :: proc(t: ^testing.T) {
	testing.expect(t, header_valid({"X-Heimdall-Instance-Token", "abc.def"}))
	testing.expect(t, header_valid({"If-None-Match", "\"etag\""}))
	testing.expect(t, header_valid({"X-Empty", ""}))
	testing.expect(t, header_valid({"X-Tab", "a\tb"}))
	bad := []Header{
		{"X-A", "v\r\nInjected: 1"}, {"X-A", "v\nx"}, {"X-A", "v\rx"}, {"X-A", "v\x00x"}, {"X-A", "v\x7f"},
		{"", "v"}, {"X A", "v"}, {"X:A", "v"}, {"X\r\nA", "v"}, {"Ünicode", "v"},
		{"Host", "evil"}, {"content-length", "0"}, {"Transfer-Encoding", "chunked"},
		{"Connection", "keep-alive"}, {"Content-Type", "text/plain"}, {"Expect", "100-continue"},
	}
	for h in bad {
		testing.expectf(t, !header_valid(h), "%q: %q should be rejected", h.name, h.value)
	}
	b := bearer("tok")
	testing.expect_value(t, b.name, "Authorization")
	testing.expect_value(t, b.value, "Bearer tok")
}

@(test)
invalid_header_is_refused_before_any_connection :: proc(t: ^testing.T) {
	if !must_init(t) do return
	s := test_server_start({{chunks = {test_reply(200, "OK", "", "x")}}})
	defer test_server_stop(s)
	resp, err := send({method = .GET, url = test_server_url(s), headers = {{"X-A", "1\r\nX-Injected: 2"}}})
	defer response_destroy(&resp)
	testing.expect_value(t, err, Error.Invalid_Header)
	testing.expect(t, !resp.may_have_sent)
	testing.expect_value(t, sync.atomic_load(&s.accepted), 0)
}

@(test)
oauth_basic_form_encodes_credentials :: proc(t: ^testing.T) {
	if !must_init(t) do return
	h, err := oauth_client_basic("my client", "s:e/c")
	testing.expect_value(t, err, Error.None)
	// base64("my%20client:s%3Ae%2Fc")
	testing.expect_value(t, h.value, "Basic bXklMjBjbGllbnQ6cyUzQWUlMkZj")
}

// ---- request shapes on the wire --------------------------------------------------------

@(test)
json_body_is_marshalled_with_content_type :: proc(t: ^testing.T) {
	if !must_init(t) do return
	s := test_server_start({{chunks = {test_reply(201, "Created", "X-Mixed-Case: one\r\nx-mixed-case: two\r\nSet-Thing: a\r\n", `{"ok":true}`)}}})
	defer test_server_stop(s)
	Payload :: struct {
		title: string `json:"title"`,
		count: int    `json:"count"`,
	}
	p := Payload{title = "quote\" and \\ and \n newline", count = 3}
	resp, err := send({method = .POST, url = test_server_url(s, "/base/"), path = {"api", "v1", "items"}, headers = {bearer("t0k"), accept_json()}, body = json_body(p)})
	defer response_destroy(&resp)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, resp.status, 201)
	testing.expect_value(t, text(resp), `{"ok":true}`)
	v, found := header(resp, "X-MIXED-CASE")
	testing.expect(t, found && v == "two", v)
	_, missing := header(resp, "nope")
	testing.expect(t, !missing)
	testing.expect(t, resp.may_have_sent)
	raw := test_server_request(s, 0)
	testing.expect_value(t, test_request_line(raw), "POST /base/api/v1/items HTTP/1.1")
	ct, _ := test_request_header(raw, "Content-Type")
	testing.expect_value(t, ct, "application/json")
	auth, _ := test_request_header(raw, "Authorization")
	testing.expect_value(t, auth, "Bearer t0k")
	acc, _ := test_request_header(raw, "Accept")
	testing.expect_value(t, acc, "application/json")
	ua, _ := test_request_header(raw, "User-Agent")
	testing.expect_value(t, ua, DEFAULT_USER_AGENT)
	_, expect_sent := test_request_header(raw, "Expect")
	testing.expect(t, !expect_sent)
	testing.expect_value(t, test_request_body(raw), `{"title":"quote\" and \\ and \n newline","count":3}`)
}

@(test)
form_body_is_percent_encoded_by_curl :: proc(t: ^testing.T) {
	if !must_init(t) do return
	s := test_server_start({{chunks = {test_reply(200, "OK", "", "{}")}}})
	defer test_server_stop(s)
	fields := []Form_Field{{"grant_type", "authorization_code"}, {"code", "a b&c=d+e"}, {"redirect_uri", "https://h.example/cb?x=1"}}
	resp, err := send({method = .POST, url = test_server_url(s), body = form_body(fields)})
	defer response_destroy(&resp)
	testing.expect_value(t, err, Error.None)
	raw := test_server_request(s, 0)
	ct, _ := test_request_header(raw, "Content-Type")
	testing.expect_value(t, ct, "application/x-www-form-urlencoded")
	testing.expect_value(t, test_request_body(raw), "grant_type=authorization_code&code=a%20b%26c%3Dd%2Be&redirect_uri=https%3A%2F%2Fh.example%2Fcb%3Fx%3D1")
}

@(test)
methods_and_empty_bodies :: proc(t: ^testing.T) {
	if !must_init(t) do return
	s := test_server_start({
		{chunks = {test_reply(200, "OK", "", "")}},
		{chunks = {test_reply(204, "No Content", "", "")}},
		{chunks = {"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n"}},
		{chunks = {test_reply(200, "OK", "", "")}},
	})
	defer test_server_stop(s)
	r1, e1 := send({method = .PUT, url = test_server_url(s), path = {"x"}})
	response_destroy(&r1)
	r2, e2 := send({method = .DELETE, url = test_server_url(s), path = {"x"}})
	response_destroy(&r2)
	r3, e3 := send({method = .HEAD, url = test_server_url(s), path = {"x"}})
	response_destroy(&r3)
	r4, e4 := send({method = .POST, url = test_server_url(s), path = {"x"}})
	response_destroy(&r4)
	testing.expect(t, e1 == .None && e2 == .None && e3 == .None && e4 == .None, fmt.tprint(e1, e2, e3, e4))
	put := test_server_request(s, 0)
	testing.expect_value(t, test_request_line(put), "PUT /x HTTP/1.1")
	cl, _ := test_request_header(put, "Content-Length")
	testing.expect_value(t, cl, "0")
	_, put_ct := test_request_header(put, "Content-Type")
	testing.expect(t, !put_ct, "a body-less request carries no Content-Type")
	testing.expect_value(t, test_request_line(test_server_request(s, 1)), "DELETE /x HTTP/1.1")
	testing.expect_value(t, test_request_line(test_server_request(s, 2)), "HEAD /x HTTP/1.1")
	post := test_server_request(s, 3)
	_, post_ct := test_request_header(post, "Content-Type")
	testing.expect(t, !post_ct, "a body-less POST is not labelled as a form")
	_, get_body := send({method = .GET, url = test_server_url(s), body = json_body(1)})
	testing.expect_value(t, get_body, Error.Invalid_Body)
}

@(test)
relay_target_is_forwarded_under_the_base_prefix :: proc(t: ^testing.T) {
	if !must_init(t) do return
	s := test_server_start({{chunks = {test_reply(200, "OK", "", "{}")}}})
	defer test_server_stop(s)
	resp, err := send({method = .POST, url = test_server_url(s, "/heimdall"), relay_target = "/api/v1/tasks?limit=5&cursor=a%2Fb", body = relay_json_body(`{"a":1}`)})
	defer response_destroy(&resp)
	testing.expect_value(t, err, Error.None)
	raw := test_server_request(s, 0)
	testing.expect_value(t, test_request_line(raw), "POST /heimdall/api/v1/tasks?limit=5&cursor=a%2Fb HTTP/1.1")
	testing.expect_value(t, test_request_body(raw), `{"a":1}`)
	_, bad := send({method = .GET, url = test_server_url(s), relay_target = "//evil/x"})
	testing.expect_value(t, bad, Error.Invalid_Url)
	_, mixed := send({method = .GET, url = test_server_url(s), relay_target = "/x", path = {"y"}})
	testing.expect_value(t, mixed, Error.Invalid_Url)
}

@(test)
environment_proxies_are_ignored :: proc(t: ^testing.T) {
	if !must_init(t) do return
	s := test_server_start({{chunks = {test_reply(200, "OK", "", "direct")}}})
	defer test_server_stop(s)
	// A proxy that does not exist: honouring it would fail the request.
	os.set_env("http_proxy", "http://127.0.0.1:1")
	os.set_env("ALL_PROXY", "http://127.0.0.1:1")
	defer {
		os.unset_env("http_proxy")
		os.unset_env("ALL_PROXY")
	}
	resp, err := send({method = .GET, url = test_server_url(s)})
	defer response_destroy(&resp)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, text(resp), "direct")
}

// ---- framing regressions (ported from src/lib/http_client) ---------------------------

// A hub reply of 256+ bytes is gzipped by the origin nginx and re-chunked by
// Cloudflare (bridge credential refresh incident, 2026-10-25). Both framings must
// end the read without waiting for the peer to close.
@(test)
chunked_reply_completes_without_waiting_for_close :: proc(t: ^testing.T) {
	if !must_init(t) do return
	s := test_server_start({{chunks = {"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"}, hold = 1500 * time.Millisecond}})
	defer test_server_stop(s)
	started := time.tick_now()
	resp, err := send({method = .POST, url = test_server_url(s), body = json_body(struct{}{}), timeout_ms = 1000})
	defer response_destroy(&resp)
	testing.expectf(t, err == .None && resp.status == 200 && text(resp) == "hello", "err=%v status=%d body=%q", err, resp.status, text(resp))
	testing.expect(t, time.tick_since(started) < 900 * time.Millisecond, "read stopped at the terminating chunk")
}

@(test)
content_length_reply_completes_without_close_and_any_header_case :: proc(t: ^testing.T) {
	if !must_init(t) do return
	s := test_server_start({{chunks = {"HTTP/1.1 200 OK\r\nCONTENT-LENGTH: 2\r\n\r\nok"}, hold = 1500 * time.Millisecond}})
	defer test_server_stop(s)
	resp, err := send({method = .GET, url = test_server_url(s), timeout_ms = 1000})
	defer response_destroy(&resp)
	testing.expect(t, err == .None && text(resp) == "ok")
}

@(test)
cloudflare_gzip_rechunked_reply_is_decoded :: proc(t: ^testing.T) {
	if !must_init(t) do return
	payload := strings.repeat(`{"access_token":"hat_x","refresh_token":"hrt_y"}`, 10, context.temp_allocator)
	gz := gzip_bytes(payload)
	defer delete(gz)
	reply := fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n\r\n%x\r\n%s\r\n%x\r\n%s\r\n0\r\n\r\n",
		len(gz) / 2, string(gz[:len(gz) / 2]), len(gz) - len(gz) / 2, string(gz[len(gz) / 2:]))
	s := test_server_start({{chunks = {reply}, hold = 500 * time.Millisecond}})
	defer test_server_stop(s)
	resp, err := send({method = .POST, url = test_server_url(s), body = json_body(struct{}{})})
	defer response_destroy(&resp)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, text(resp), payload)
	raw := test_server_request(s, 0)
	ae, has_ae := test_request_header(raw, "Accept-Encoding")
	testing.expect(t, has_ae && strings.contains(ae, "gzip"), ae)
}

@(private = "file")
gzip_bytes :: proc(s: string) -> []byte {
	// core:compress has no gzip writer; this is a stored (uncompressed) deflate
	// stream in a gzip wrapper, which every inflater accepts.
	out: bytes.Buffer
	bytes.buffer_init_allocator(&out, 0, len(s) + 64)
	bytes.buffer_write(&out, {0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff})
	data := transmute([]byte)s
	pos := 0
	for {
		n := min(len(data) - pos, 65535)
		final: byte = 1 if pos + n == len(data) else 0
		bytes.buffer_write(&out, {final, byte(n), byte(n >> 8), byte(~n), byte(~n >> 8)})
		bytes.buffer_write(&out, data[pos:pos + n])
		pos += n
		if final == 1 do break
	}
	crc := gzip_crc32(data)
	size := u32(len(data))
	bytes.buffer_write(&out, {byte(crc), byte(crc >> 8), byte(crc >> 16), byte(crc >> 24), byte(size), byte(size >> 8), byte(size >> 16), byte(size >> 24)})
	result := make([]byte, bytes.buffer_length(&out))
	copy(result, bytes.buffer_to_bytes(&out))
	bytes.buffer_destroy(&out)
	return result
}

@(private = "file")
gzip_crc32 :: proc(data: []byte) -> u32 {
	crc: u32 = 0xffffffff
	for b in data {
		crc ~= u32(b)
		for _ in 0..<8 {
			crc = (crc >> 1) ~ (0xedb88320 & (0 - (crc & 1)))
		}
	}
	return ~crc
}

// ---- limits, timeouts, errors, may_have_sent ----------------------------------------

@(test)
response_size_limit_is_enforced :: proc(t: ^testing.T) {
	if !must_init(t) do return
	big := strings.repeat("x", 4000, context.temp_allocator)
	chunked := fmt.tprintf("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n%x\r\n%s\r\n0\r\n\r\n", len(big), big)
	s := test_server_start({{chunks = {test_reply(200, "OK", "", big)}}, {chunks = {chunked}}, {chunks = {test_reply(200, "OK", "", big)}}})
	defer test_server_stop(s)
	r1, e1 := send({method = .GET, url = test_server_url(s), max_response_bytes = 1000})
	defer response_destroy(&r1)
	testing.expect_value(t, e1, Error.Too_Large)
	r2, e2 := send({method = .GET, url = test_server_url(s), max_response_bytes = 1000})
	defer response_destroy(&r2)
	testing.expect_value(t, e2, Error.Too_Large)
	r3, e3 := send({method = .GET, url = test_server_url(s), max_response_bytes = 4000})
	defer response_destroy(&r3)
	testing.expect(t, e3 == .None && len(r3.body) == 4000)
}

// The deadline is one cumulative budget over connect, send and every read: a
// server trickling one byte every 20 ms cannot stretch an 80 ms request.
@(test)
timeout_bounds_a_slow_trickle :: proc(t: ^testing.T) {
	if !must_init(t) do return
	trickle := make([]string, 13, context.temp_allocator)
	trickle[0] = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n"
	for i in 1..<len(trickle) do trickle[i] = "x"
	s := test_server_start({{chunks = trickle, pause = 20 * time.Millisecond}})
	defer test_server_stop(s)
	started := time.tick_now()
	resp, err := send({method = .POST, url = test_server_url(s), body = json_body(struct{}{}), timeout_ms = 80})
	defer response_destroy(&resp)
	elapsed := time.tick_since(started)
	testing.expect_value(t, err, Error.Timeout)
	testing.expect(t, resp.may_have_sent, "a lost/truncated response fences unsafe POST replay")
	testing.expect_value(t, resp.status, 0)
	testing.expectf(t, elapsed >= 50 * time.Millisecond && elapsed < 400 * time.Millisecond, "elapsed %v", elapsed)
}

@(test)
silent_server_times_out_after_sending :: proc(t: ^testing.T) {
	if !must_init(t) do return
	s := test_server_start({{hold = 600 * time.Millisecond}})
	defer test_server_stop(s)
	resp, err := send({method = .POST, url = test_server_url(s), body = json_body(struct{}{}), timeout_ms = 200})
	defer response_destroy(&resp)
	testing.expect_value(t, err, Error.Timeout)
	testing.expect(t, resp.may_have_sent)
}

@(test)
server_closing_without_reply_is_protocol_error_after_send :: proc(t: ^testing.T) {
	if !must_init(t) do return
	s := test_server_start({{close_early = true}, {chunks = {"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort"}}})
	defer test_server_stop(s)
	r1, e1 := send({method = .POST, url = test_server_url(s), body = json_body(struct{}{})})
	defer response_destroy(&r1)
	testing.expect_value(t, e1, Error.Protocol)
	testing.expect(t, r1.may_have_sent)
	// A truncated Content-Length body is a failure, never a short success.
	r2, e2 := send({method = .GET, url = test_server_url(s)})
	defer response_destroy(&r2)
	testing.expect(t, e2 == .Protocol || e2 == .Recv, fmt.tprint(e2))
	testing.expect_value(t, len(r2.body), 0)
}

@(test)
connect_refused_never_sent :: proc(t: ^testing.T) {
	if !must_init(t) do return
	// Bind then close: nothing listens on this port.
	l, _ := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	ep, _ := net.bound_endpoint(l)
	net.close(l)
	u, _ := parse_url(fmt.tprintf("http://127.0.0.1:%d", ep.port))
	resp, err := send({method = .POST, url = u, body = json_body(struct{}{})})
	defer response_destroy(&resp)
	testing.expect_value(t, err, Error.Connect)
	testing.expect(t, !resp.may_have_sent, "the server cannot have seen the request")
	testing.expect(t, resp.detail != "")
}

@(test)
dns_failure_never_sent :: proc(t: ^testing.T) {
	if !must_init(t) do return
	u, _ := parse_url("http://heimdall-no-such-host.invalid/")
	resp, err := send({method = .POST, url = u, body = json_body(struct{}{}), timeout_ms = 5000})
	defer response_destroy(&resp)
	testing.expect_value(t, err, Error.Dns)
	testing.expect(t, !resp.may_have_sent)
}

@(test)
negative_budget_fails_without_io :: proc(t: ^testing.T) {
	if !must_init(t) do return
	u, _ := parse_url("http://127.0.0.1:9")
	resp, err := send({method = .GET, url = u, timeout_ms = -1})
	defer response_destroy(&resp)
	testing.expect_value(t, err, Error.Timeout)
	testing.expect(t, !resp.may_have_sent)
	_, uerr := send({method = .GET})
	testing.expect_value(t, uerr, Error.Invalid_Url)
}

@(test)
cancel_flag_aborts :: proc(t: ^testing.T) {
	if !must_init(t) do return
	s := test_server_start({{hold = 1500 * time.Millisecond}})
	defer test_server_stop(s)
	cancel := false
	canceller := thread.create_and_start_with_data(&cancel, proc(p: rawptr) {
		time.sleep(100 * time.Millisecond)
		sync.atomic_store((^bool)(p), true)
	})
	defer {
		thread.join(canceller)
		thread.destroy(canceller)
	}
	resp, err := send({method = .GET, url = test_server_url(s), timeout_ms = 3000, cancel = &cancel})
	defer response_destroy(&resp)
	testing.expect_value(t, err, Error.Aborted)
}

@(test)
redirects_are_not_followed_unless_asked :: proc(t: ^testing.T) {
	if !must_init(t) do return
	s := test_server_start({
		{chunks = {test_reply(302, "Found", "Location: /final\r\n", "")}},
		{chunks = {test_reply(302, "Found", "Location: /final\r\n", "")}},
		{chunks = {test_reply(200, "OK", "", "landed")}},
	})
	defer test_server_stop(s)
	r1, e1 := send({method = .GET, url = test_server_url(s), path = {"start"}})
	defer response_destroy(&r1)
	testing.expect(t, e1 == .None && r1.status == 302)
	loc, _ := header(r1, "location")
	testing.expect_value(t, loc, "/final")
	r2, e2 := send({method = .GET, url = test_server_url(s), path = {"start"}, max_redirects = 2})
	defer response_destroy(&r2)
	testing.expect(t, e2 == .None && r2.status == 200 && text(r2) == "landed")
	testing.expect_value(t, test_request_line(test_server_request(s, 2)), "GET /final HTTP/1.1")
}

// ---- send_json -------------------------------------------------------------------------

@(test)
send_json_decodes_2xx_only :: proc(t: ^testing.T) {
	if !must_init(t) do return
	s := test_server_start({
		{chunks = {test_reply(200, "OK", "Content-Type: application/json\r\n", `{"name":"x","n":7}`)}},
		{chunks = {test_reply(404, "Not Found", "", `{"error":"nope"}`)}},
		{chunks = {test_reply(200, "OK", "", `{"name":`)}},
		{chunks = {test_reply(200, "OK", "", strings.repeat(" ", 2000, context.temp_allocator))}},
	})
	defer test_server_stop(s)
	Out :: struct {
		name: string,
		n:    int,
	}
	out: Out
	meta, err := send_json({method = .GET, url = test_server_url(s)}, &out, context.temp_allocator)
	testing.expect(t, err == .None && meta.status == 200 && out.name == "x" && out.n == 7)
	untouched: Out
	meta2, err2 := send_json({method = .GET, url = test_server_url(s)}, &untouched, context.temp_allocator)
	testing.expect(t, err2 == .None && meta2.status == 404 && untouched.name == "")
	_, err3 := send_json({method = .GET, url = test_server_url(s)}, &untouched, context.temp_allocator)
	testing.expect_value(t, err3, Error.Decode)
	_, err4 := send_json({method = .GET, url = test_server_url(s), max_response_bytes = 100}, &untouched, context.temp_allocator)
	testing.expect_value(t, err4, Error.Too_Large)
}

// ---- download_to_file (ported) ----------------------------------------------------------

@(private = "file")
test_tmp_dir :: proc(name: string) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	dir := fmt.tprintf("%s/.cache/heimdall-tests/httpc-%s-%d", home, name, time.to_unix_nanoseconds(time.now()))
	_ = os.make_directory_all(dir)
	return dir
}

@(test)
download_streams_follows_redirects_and_never_leaves_partials :: proc(t: ^testing.T) {
	if !must_init(t) do return
	dir := test_tmp_dir("download")
	defer _ = os.remove_all(dir)
	s := test_server_start({
		{chunks = {test_reply(200, "OK", "", "content-length body")}},
		{chunks = {test_reply(301, "Moved", "Location: /asset\r\n", "")}},
		{chunks = {"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n3\r\nabc\r\n3\r\ndef\r\n0\r\n\r\n"}},
		{chunks = {test_reply(404, "Not Found", "", "missing")}},
		{chunks = {"HTTP/1.1 200 OK\r\nContent-Length: 50\r\nConnection: close\r\n\r\ntruncated"}},
	})
	defer test_server_stop(s)
	dest := fmt.tprintf("%s/out.bin", dir)
	st1, e1 := download_to_file({method = .GET, url = test_server_url(s)}, dest)
	testing.expect(t, st1 == 200 && e1 == .None)
	got1, _ := os.read_entire_file(dest, context.temp_allocator)
	testing.expect_value(t, string(got1), "content-length body")
	st2, e2 := download_to_file({method = .GET, url = test_server_url(s), max_redirects = 5}, dest)
	testing.expect(t, st2 == 200 && e2 == .None)
	got2, _ := os.read_entire_file(dest, context.temp_allocator)
	testing.expect_value(t, string(got2), "abcdef")
	st3, e3 := download_to_file({method = .GET, url = test_server_url(s)}, dest)
	testing.expect(t, st3 == 404 && e3 == .None)
	st4, e4 := download_to_file({method = .GET, url = test_server_url(s)}, dest)
	testing.expect(t, st4 == 0 && e4 != .None)
	// A failed download leaves the previous good file and no .part behind.
	got3, _ := os.read_entire_file(dest, context.temp_allocator)
	testing.expect_value(t, string(got3), "abcdef")
	testing.expect(t, !os.exists(fmt.tprintf("%s.part", dest)))
}

// ---- TLS -------------------------------------------------------------------------------

// End to end over real TLS against a socat server with a throwaway certificate:
// a chunked 200 followed by the server closing (the shape that stranded the
// bridge), trust via HAM_TLS_CA_FILE, and hostname verification. Skipped when
// openssl/socat are not on PATH (they are in `nix develop`). The only test in
// this package that touches HAM_TLS_CA_FILE.
@(test)
tls_end_to_end_with_test_ca :: proc(t: ^testing.T) {
	if !must_init(t) do return
	if !tool_present("openssl") || !tool_present("socat") {
		testing.fail_now(t, "openssl and socat are required (run inside nix develop)")
	}
	dir := test_tmp_dir("tls")
	defer _ = os.remove_all(dir)
	cert := fmt.tprintf("%s/cert.pem", dir)
	key := fmt.tprintf("%s/key.pem", dir)
	gen, _, _, gen_err := os.process_exec(os.Process_Desc{command = []string{
		"openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
		"-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
	}}, context.temp_allocator)
	if !testing.expect(t, gen_err == nil && gen.exited && gen.success, "test certificate generated") do return
	probe, _ := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	bound, _ := net.bound_endpoint(probe)
	net.close(probe)
	reply_path := fmt.tprintf("%s/reply.http", dir)
	reply := "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n7\r\n{\"a\":1}\r\n0\r\n\r\n"
	if !testing.expect(t, os.write_entire_file(reply_path, transmute([]byte)reply) == nil) do return
	// The responder reads the request head before replying: replying and closing
	// with request bytes still unread would make the kernel answer with RST and
	// the client could lose the reply (a test race, not a client bug).
	script_path := fmt.tprintf("%s/respond.sh", dir)
	script := fmt.tprintf("while IFS= read -r line; do case \"$line\" in ''|$(printf '\\r')) break;; esac; done\ncat %s\n", reply_path)
	if !testing.expect(t, os.write_entire_file(script_path, transmute([]byte)script) == nil) do return
	server, serr := os.process_start(os.Process_Desc{command = []string{
		"socat", fmt.tprintf("OPENSSL-LISTEN:%d,bind=127.0.0.1,reuseaddr,fork,cert=%s,key=%s,verify=0", bound.port, cert, key),
		fmt.tprintf("EXEC:sh %s", script_path),
	}})
	if !testing.expect(t, serr == nil, "socat TLS server starts") do return
	defer {
		_ = os.process_kill(server)
		_, _ = os.process_wait(server)
	}
	for _ in 0..<100 {
		sock, derr := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
		if derr == nil {
			net.close(sock)
			break
		}
		time.sleep(20 * time.Millisecond)
	}
	good, _ := parse_url(fmt.tprintf("https://localhost:%d", bound.port))
	by_ip, _ := parse_url(fmt.tprintf("https://127.0.0.1:%d", bound.port))

	// Not trusted by the system store.
	r0, e0 := send({method = .POST, url = good, path = {"api", "v1", "device", "bridge-refresh"}, body = json_body(struct{}{}), timeout_ms = 5000})
	response_destroy(&r0)
	testing.expectf(t, e0 == .Certificate, "untrusted cert: %v", e0)
	testing.expect(t, !r0.may_have_sent, "a failed handshake sent no request bytes")

	os.set_env("HAM_TLS_CA_FILE", cert)
	defer os.unset_env("HAM_TLS_CA_FILE")
	r1, e1 := send({method = .POST, url = good, path = {"api", "v1", "device", "bridge-refresh"}, body = json_body(struct{}{}), timeout_ms = 5000})
	defer response_destroy(&r1)
	testing.expectf(t, e1 == .None && r1.status == 200 && text(r1) == `{"a":1}`, "err=%v status=%d body=%q detail=%s", e1, r1.status, text(r1), r1.detail)
	// Hostname verification is always on: the certificate names localhost only.
	r2, e2 := send({method = .GET, url = by_ip, timeout_ms = 5000})
	response_destroy(&r2)
	testing.expectf(t, e2 == .Certificate, "IP not in the certificate: %v", e2)
}

@(private = "file")
tool_present :: proc(name: string) -> bool {
	state, _, _, err := os.process_exec(os.Process_Desc{command = []string{"sh", "-c", fmt.tprintf("command -v %s >/dev/null", name)}}, context.temp_allocator)
	return err == nil && state.exited && state.success
}
