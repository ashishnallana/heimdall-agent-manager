package http_client

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import tls "../tls_stream"

DEFAULT_TIMEOUT_MS :: 20000

Response :: struct {
	status: int,
	body: string,
    // Strict requests set this on failure once any request bytes may have left.
    may_have_sent: bool,
}

Header :: struct {
	name: string,
	value: string,
}

get :: proc(base_url, path: string) -> (Response, bool) {
	return request_with_timeout("GET", base_url, path, "", DEFAULT_TIMEOUT_MS)
}

get_with_timeout :: proc(base_url, path: string, timeout_ms: int) -> (Response, bool) {
	return request_with_timeout("GET", base_url, path, "", timeout_ms)
}

post :: proc(base_url, path, body: string) -> (Response, bool) {
	return request_with_timeout("POST", base_url, path, body, DEFAULT_TIMEOUT_MS)
}

post_with_timeout :: proc(base_url, path, body: string, timeout_ms: int) -> (Response, bool) {
	return request_with_timeout("POST", base_url, path, body, timeout_ms)
}

request :: proc(method, base_url, path, body: string) -> (Response, bool) {
	return request_with_timeout(method, base_url, path, body, DEFAULT_TIMEOUT_MS)
}

request_with_timeout :: proc(method, base_url, path, body: string, timeout_ms: int) -> (Response, bool) {
	return request_blocking(method, base_url, path, body, timeout_ms)
}

request_with_headers_timeout :: proc(method, base_url, path, body: string, headers: []Header, timeout_ms: int, omit_default_port := false) -> (Response, bool) {
	return request_blocking_with_headers(method, base_url, path, body, headers, timeout_ms, omit_default_port)
}

request_blocking :: proc(method, base_url, path, body: string, timeout_ms := 0) -> (Response, bool) {
	return request_blocking_with_headers(method, base_url, path, body, nil, timeout_ms)
}

request_blocking_with_headers :: proc(method, base_url, request_path, body: string, extra_headers: []Header, timeout_ms := 0, omit_default_port := false) -> (Response, bool) {
	host, port, secure, ok := parse_base_url(base_url)
	if !ok do return {}, false
	// A base URL may carry a path prefix (a hub behind a reverse proxy under
	// /heimdall, say): every request path is resolved under it.
	path := request_target(base_url, request_path)
	// Drop the port from the Host header only when the caller opted in AND it is the
	// scheme default (443 https / 80 http); a non-default port is always kept.
	include_port_in_host := !(omit_default_port && ((secure && port == 443) || (!secure && port == 80)))
	if secure do return request_tls_with_headers(method, host, port, path, body, extra_headers, timeout_ms, include_port_in_host)

	socket, dial_ok := dial_tcp_with_timeout(host, int(port), timeout_ms)
	if !dial_ok do return {}, false
	defer net.close(socket)
	if timeout_ms > 0 {
		timeout := time.Duration(timeout_ms) * time.Millisecond
		if net.set_option(socket, .Send_Timeout, timeout) != nil do return {}, false
		if net.set_option(socket, .Receive_Timeout, timeout) != nil do return {}, false
	}

	req := build_http_request(method, host, port, path, body, extra_headers, include_port_in_host)
	defer delete(req)
	_, send_err := net.send_tcp(socket, transmute([]byte)req)
	if send_err != nil do return {}, false

	data := make([dynamic]byte, 0, 8192)
	defer delete(data)
	buf: [8192]byte
	for {
		n, recv_err := net.recv_tcp(socket, buf[:])
		if recv_err != nil do return {}, false
		if n == 0 do break
		append(&data, ..buf[:n])
		if response_complete(string(data[:])) do break
	}

	return parse_response_bytes(data[:])
}

request_tls_with_headers :: proc(method, host: string, port: u16, path, body: string, extra_headers: []Header, timeout_ms := 0, include_port_in_host := true) -> (Response, bool) {
	budget := time.Duration(timeout_ms if timeout_ms > 0 else DEFAULT_TIMEOUT_MS) * time.Millisecond
	stream, dial_ok := tls.dial(host, port, budget)
	if !dial_ok do return {}, false
	// Keep the request side OPEN until we are done reading. Half-closing the Unix
	// relay right after the request gives the other side only socat's default
	// 0.5 s grace (-t) before exiting, so any Hub whose first byte takes longer
	// than that to arrive (a Cloudflare-fronted Hub from a phone, for instance)
	// produced "no HTTP response" although the request had been sent. The request
	// carries Connection: close and response_complete() ends the read, so nothing
	// waits on EOF.
	defer tls.close(&stream)

	req := build_http_request(method, host, port, path, body, extra_headers, include_port_in_host)
	defer delete(req)
	if tls.write_all(&stream, transmute([]byte)req) != .Ok do return {}, false

	deadline := time.to_unix_nanoseconds(time.now()) + i64(budget)
	data := make([dynamic]byte, 0, 8192)
	defer delete(data)
	buf: [8192]byte
	for time.to_unix_nanoseconds(time.now()) < deadline {
		if ready, has_ok := tls.has_data(&stream); !has_ok {
			break
		} else if ready {
			n, read_ok := tls.read(&stream, buf[:])
			if !read_ok || n <= 0 do break
			append(&data, ..buf[:n])
			if response_complete(string(data[:])) do break
		} else {
			if tls.relay_exited(&stream) do break
			time.sleep(10 * time.Millisecond)
		}
	}
	if len(data) == 0 do return {}, false
	return parse_response_bytes(data[:])
}

build_http_request :: proc(method, host: string, port: u16, path, body: string, extra_headers: []Header, include_port_in_host := true) -> string {
	req_b := strings.builder_make()
	// The Host header is the request authority. Per RFC 7230 the port is omitted
	// when it is the scheme default; browsers and reference push libraries (e.g.
	// web-push) send a bare "Host: <host>". Callers that must match that wire form
	// (the Web Push client, whose endpoints are strict) pass include_port_in_host
	// = false; everyone else keeps the historical "host:port" form unchanged.
	host_header := fmt.tprintf("%s:%d", host, port) if include_port_in_host else host
	strings.write_string(&req_b, fmt.tprintf("%s %s HTTP/1.1\r\nHost: %s\r\n", method, path, host_header))
	// Default to JSON unless the caller supplies its own Content-Type (e.g. Web
	// Push sends a binary aes128gcm body). This keeps existing JSON callers
	// unchanged while allowing binary/other content types.
	if !has_header(extra_headers, "Content-Type") {
		strings.write_string(&req_b, "Content-Type: application/json\r\n")
	}
	for h in extra_headers {
		if strings.trim_space(h.name) == "" do continue
		strings.write_string(&req_b, h.name)
		strings.write_string(&req_b, ": ")
		strings.write_string(&req_b, h.value)
		strings.write_string(&req_b, "\r\n")
	}
	strings.write_string(&req_b, fmt.tprintf("Content-Length: %d\r\nConnection: close\r\n\r\n%s", len(body), body))
	return strings.to_string(req_b)
}

// has_header reports whether extra_headers contains a header with the given
// name (case-insensitive).
has_header :: proc(extra_headers: []Header, name: string) -> bool {
	for h in extra_headers {
		if strings.equal_fold(strings.trim_space(h.name), name) do return true
	}
	return false
}

parse_response_bytes :: proc(data: []byte) -> (Response, bool) {
	raw := string(data)
	response_body := raw
	body_is_owned := false
	if idx := strings.index(raw, "\r\n\r\n"); idx >= 0 {
		headers := raw[:idx]
		response_body = raw[idx + 4:]
		if response_transfer_chunked(headers) {
			// response_decode_chunked_body allocates a fresh string.
			response_body = response_decode_chunked_body(response_body)
			body_is_owned = true
		} else {
			content_length := response_content_length(headers)
			if content_length >= 0 {
				if len(response_body) < content_length do return {}, false
				if len(response_body) > content_length do response_body = response_body[:content_length]
			}
		}
	}

	status := 0
	if len(raw) >= 12 && (strings.has_prefix(raw, "HTTP/1.1 ") || strings.has_prefix(raw, "HTTP/1.0 ")) {
		if parsed_status, status_ok := strconv.parse_int(raw[9:12]); status_ok {
			status = int(parsed_status)
		}
	}

	// Response.body must be an independently-heap-allocated string so callers can
	// safely `delete(resp.body)`. In the non-chunked path response_body is a slice
	// into the transient `data` buffer (its pointer lands mid-buffer, right after
	// the \r\n\r\n header terminator); returning that slice caused callers that
	// free the body to hit an invalid-free (SIGABRT). Clone it here so ownership is
	// unambiguous.
	if !body_is_owned {
		response_body = strings.clone(response_body)
	}

	return Response{status = status, body = response_body}, true
}

response_complete :: proc(raw: string) -> bool {
	idx := strings.index(raw, "\r\n\r\n")
	if idx < 0 do return false
	content_length := response_content_length(raw[:idx])
	if content_length < 0 do return false
	return len(raw[idx + 4:]) >= content_length
}

response_content_length :: proc(headers: string) -> int {
	header_text := headers
	for line in strings.split_lines_iterator(&header_text) {
		if strings.has_prefix(line, "Content-Length:") || strings.has_prefix(line, "content-length:") {
			value := strings.trim_space(line[len("Content-Length:"):])
			if parsed, ok := strconv.parse_int(value); ok do return int(parsed)
		}
	}
	return -1
}

// header_contains_fold reports whether haystack contains needle,
// ASCII-case-insensitively, without allocating (strings.to_lower would leak
// on every response carrying the header).
header_contains_fold :: proc(haystack, needle: string) -> bool {
	if len(needle) == 0 do return true
	if len(needle) > len(haystack) do return false
	for i in 0..=(len(haystack) - len(needle)) {
		match := true
		for j in 0..<len(needle) {
			a := haystack[i+j]
			b := needle[j]
			if a >= 'A' && a <= 'Z' do a += 32
			if b >= 'A' && b <= 'Z' do b += 32
			if a != b {
				match = false
				break
			}
		}
		if match do return true
	}
	return false
}

response_transfer_chunked :: proc(headers: string) -> bool {
	header_text := headers
	for line in strings.split_lines_iterator(&header_text) {
		if strings.has_prefix(line, "Transfer-Encoding:") || strings.has_prefix(line, "transfer-encoding:") {
			return header_contains_fold(line, "chunked")
		}
	}
	return false
}

response_decode_chunked_body :: proc(body: string) -> string {
	b := strings.builder_make()
	pos := 0
	for pos < len(body) {
		line_end := strings.index(body[pos:], "\r\n")
		if line_end < 0 do break
		size_line := strings.trim_space(body[pos:pos + line_end])
		if semi := strings.index(size_line, ";"); semi >= 0 do size_line = size_line[:semi]
		size, ok := parse_hex_size(size_line)
		if !ok do break
		pos += line_end + 2
		if size == 0 do break
		if pos + size > len(body) do break
		strings.write_string(&b, body[pos:pos + size])
		pos += size
		if pos + 2 <= len(body) && body[pos:pos + 2] == "\r\n" do pos += 2
	}
	return strings.to_string(b)
}

parse_hex_size :: proc(text: string) -> (int, bool) {
	trimmed := strings.trim_space(text)
	if trimmed == "" do return 0, false
	value := 0
	for i in 0..<len(trimmed) {
		ch := trimmed[i]
		digit := -1
		if ch >= '0' && ch <= '9' {
			digit = int(ch - '0')
		} else if ch >= 'a' && ch <= 'f' {
			digit = int(ch - 'a') + 10
		} else if ch >= 'A' && ch <= 'F' {
			digit = int(ch - 'A') + 10
		} else {
			return 0, false
		}
		value = value * 16 + digit
	}
	return value, true
}

dial_tcp_with_timeout :: proc(host: string, port, timeout_ms: int) -> (net.TCP_Socket, bool) {
	endpoint, endpoint_ok := resolve_host_with_timeout(host, port, timeout_ms)
	if !endpoint_ok do return 0, false

	sock_any, sock_err := net.create_socket(net.family_from_endpoint(endpoint), .TCP)
	if sock_err != nil do return 0, false
	socket := sock_any.(net.TCP_Socket)
	success := false
	defer if !success { net.close(socket) }
	if net.set_blocking(socket, false) != nil do return 0, false

	if !connect_with_timeout(socket, endpoint, timeout_ms) do return 0, false
	if net.set_blocking(socket, true) != nil do return 0, false
	success = true
	return socket, true
}

resolve_host_with_timeout :: proc(host: string, port, timeout_ms: int) -> (net.Endpoint, bool) {
	clean_host := host_trim_brackets(host)
	if endpoint, ok := resolve_host_without_dns(clean_host, port); ok do return endpoint, true
	if timeout_ms > 0 {
		return resolve_host_via_command(clean_host, port, timeout_ms)
	}
	return resolve_host_blocking(clean_host, port)
}

resolve_host_without_dns :: proc(host: string, port: int) -> (net.Endpoint, bool) {
	if host == "localhost" {
		return net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port}, true
	}
	if ip4, ok := net.parse_ip4_address(host); ok {
		return net.Endpoint{address = ip4, port = port}, true
	}
	if ip6, ok := net.parse_ip6_address(host); ok {
		return net.Endpoint{address = ip6, port = port}, true
	}
	return net.Endpoint{}, false
}

resolve_host_blocking :: proc(host: string, port: int) -> (net.Endpoint, bool) {
	ep4, ep6, err := net.resolve(fmt.tprintf("%s:%d", host, port))
	if err != nil do return net.Endpoint{}, false
	endpoint := ep4 if ep4.address != nil else ep6
	if endpoint.address == nil || endpoint.port == 0 do return net.Endpoint{}, false
	return endpoint, true
}

resolve_host_via_command :: proc(host: string, port, timeout_ms: int) -> (net.Endpoint, bool) {
	command: []string
	when ODIN_OS == .Linux {
		command = []string{"getent", "ahosts", host}
	} else when ODIN_OS == .Darwin {
		command = []string{"dscacheutil", "-q", "host", "-a", "name", host}
	} else when ODIN_OS == .Windows {
		// No resolver CLI to bound with a timeout; the system resolver is used directly.
		return resolve_host_blocking(host, port)
	} else {
		return net.Endpoint{}, false
	}
	stdout_r, stdout_w, pipe_err := os.pipe()
	if pipe_err != nil do return net.Endpoint{}, false
	defer os.close(stdout_r)
	process, start_err := os.process_start(os.Process_Desc{
		command = command,
		stdout = stdout_w,
	})
	if start_err != nil {
		_ = os.close(stdout_w)
		return net.Endpoint{}, false
	}
	_ = os.close(stdout_w)
	state, wait_err := os.process_wait(process, time.Duration(timeout_ms) * time.Millisecond)
	if wait_err != nil {
		if os_error_is_timeout(wait_err) {
			_ = os.process_kill(process)
			_, _ = os.process_wait(process)
		}
		return net.Endpoint{}, false
	}
	if !state.success do return net.Endpoint{}, false
	output, read_err := os.read_entire_file(stdout_r, context.temp_allocator)
	if read_err != nil do return net.Endpoint{}, false
	return endpoint_from_resolution_output(string(output), port)
}

endpoint_from_resolution_output :: proc(output: string, port: int) -> (net.Endpoint, bool) {
	text := output
	for field in strings.fields_iterator(&text) {
		token := strings.trim(field, " \t\r\n,[]")
		if strings.has_suffix(token, ":") && strings.count(token, ":") == 1 {
			token = token[:len(token)-1]
		}
		if token == "" do continue
		if endpoint, ok := resolve_host_without_dns(token, port); ok do return endpoint, true
	}
	return net.Endpoint{}, false
}

// The TLS relay argv (Unix transport) lives in tls_stream; these names remain for
// the tests that pin the socat / s_client selection rule.
tls_client_command :: tls.relay_command
tls_client_command_for_backend :: tls.relay_command_for_backend

host_trim_brackets :: proc(host: string) -> string {
	if len(host) >= 2 && host[0] == '[' && host[len(host)-1] == ']' {
		return host[1:len(host)-1]
	}
	return host
}

// ---- streaming download to file (REQ-DIST-4: heimdall update) ----
//
// download_to_file streams a GET of `url` into `dest_path` without buffering
// the body in memory, following up to `max_redirects` 3xx redirects. Only a
// final HTTP 200 body reaches `dest_path`, written to a sibling ".part" file
// first and renamed over the destination on completion, so a failed or
// truncated download never leaves a partial file at the final path. On any
// failure (transport error, timeout, too many redirects, non-200 final
// status) ok is false and callers should treat the destination as unchanged.

DOWNLOAD_MAX_REDIRECTS :: 5
DOWNLOAD_MAX_HEADER_BYTES :: 65536

Download_Stream_Read :: proc(ctx: rawptr, out: []byte) -> (n: int, ok: bool) // (0, true) signals EOF

Download_Stream :: struct {
	read:   Download_Stream_Read,
	ctx:    rawptr,
	buf:    [65536]byte,
	filled: int,
	pos:    int,
}

Download_Tls_Ctx :: struct {
	stream:    ^tls.Stream,
	deadline:  i64, // unix nanoseconds
}

// ds_fill ensures at least one buffered byte is available; false at EOF or on
// a transport error/timeout.
ds_fill :: proc(s: ^Download_Stream) -> bool {
	if s.pos < s.filled do return true
	s.pos = 0
	s.filled = 0
	n, ok := s.read(s.ctx, s.buf[:])
	if !ok || n <= 0 do return false
	s.filled = n
	return true
}

// ds_write_to_file copies exactly `n` stream bytes (buffered first) into f.
ds_write_to_file :: proc(s: ^Download_Stream, f: ^os.File, n: int) -> bool {
	remaining := n
	for remaining > 0 {
		if !ds_fill(s) do return false
		avail := s.filled - s.pos
		take := min(avail, remaining)
		written, werr := os.write(f, s.buf[s.pos:s.pos+take])
		if werr != nil || written != take do return false
		s.pos += take
		remaining -= take
	}
	return true
}

// ds_drain_to_file copies the stream into f until EOF (close-delimited body).
ds_drain_to_file :: proc(s: ^Download_Stream, f: ^os.File) -> bool {
	for {
		if !ds_fill(s) do return false
		chunk := s.buf[s.pos:s.filled]
		written, werr := os.write(f, chunk)
		if werr != nil || written != len(chunk) do return false
		s.pos = s.filled
	}
}

// ds_read_line reads through the next '\n' into a small caller buffer and
// returns the line with trailing CR/LF stripped.
ds_read_line :: proc(s: ^Download_Stream, line: []byte) -> (string, bool) {
	length := 0
	for {
		if !ds_fill(s) do return "", false
		b := s.buf[s.pos]
		s.pos += 1
		if b == '\n' {
			text := string(line[:length])
			return strings.trim_right(text, "\r"), true
		}
		if length >= len(line) do return "", false
		line[length] = b
		length += 1
	}
}

// ds_read_headers accumulates the response header block (up to and including
// the blank line) into a freshly allocated string. Bytes read past the header
// terminator stay buffered in the stream (they belong to the body).
ds_read_headers :: proc(s: ^Download_Stream) -> (string, bool) {
	data := make([dynamic]byte, 0, 4096)
	for {
		if !ds_fill(s) {
			delete(data)
			return "", false
		}
		append(&data, ..s.buf[s.pos:s.filled])
		overread := s.filled - s.pos
		s.pos = s.filled
		if len(data) > DOWNLOAD_MAX_HEADER_BYTES {
			delete(data)
			return "", false
		}
		raw := string(data[:])
		if idx := strings.index(raw, "\r\n\r\n"); idx >= 0 {
			consumed := idx + 4
			// rewind: body bytes pulled in by the same read remain buffered
			s.pos -= overread - consumed
			result := strings.clone(raw[:consumed])
			delete(data)
			return result, true
		}
	}
}

download_socket_read :: proc(ctx: rawptr, out: []byte) -> (int, bool) {
	socket := (cast(^net.TCP_Socket)ctx)^
	n, err := net.recv_tcp(socket, out)
	if err != nil do return 0, false
	if n == 0 do return 0, true
	return n, true
}

// download_tls_read mirrors the poll loop of request_tls_with_headers. EOF is
// reported once the stream drains; tls.read delivers data that arrived with the
// end of stream first and reports the EOF on the next call.
download_tls_read :: proc(ctx: rawptr, out: []byte) -> (int, bool) {
	c := cast(^Download_Tls_Ctx)ctx
	for time.to_unix_nanoseconds(time.now()) < c.deadline {
		ready, has_ok := tls.has_data(c.stream)
		if !has_ok do return 0, false
		if ready {
			n, read_ok := tls.read(c.stream, out)
			if !read_ok do return 0, false
			return max(n, 0), true
		}
		if tls.relay_exited(c.stream) {
			n, read_ok := tls.read(c.stream, out)
			if !read_ok || n <= 0 do return 0, true
			return n, true
		}
		time.sleep(10 * time.Millisecond)
	}
	return 0, false
}

// split_url decomposes an absolute http(s) URL into authority + path parts.
// Unlike parse_base_url it keeps the path (and query), which requests need.
split_url :: proc(url: string) -> (host: string, port: u16, secure: bool, path: string, ok: bool) {
	rest := url
	default_port: u16 = 80
	if strings.has_prefix(rest, "https://") {
		rest = rest[len("https://"):]
		secure = true
		default_port = 443
	} else if strings.has_prefix(rest, "http://") {
		rest = rest[len("http://"):]
	} else {
		return "", 0, false, "", false
	}
	authority := rest
	path = "/"
	if slash := strings.index_byte(rest, '/'); slash >= 0 {
		authority = rest[:slash]
		path = rest[slash:]
	}
	host = host_trim_brackets(authority)
	port = default_port
	if colon := strings.last_index_byte(authority, ':'); colon >= 0 {
		parsed, p_ok := strconv.parse_int(authority[colon+1:])
		if !p_ok || parsed <= 0 || parsed > 65535 do return "", 0, false, "", false
		host = host_trim_brackets(authority[:colon])
		port = u16(parsed)
	}
	if strings.trim_space(host) == "" do return "", 0, false, "", false
	return host, port, secure, path, true
}

// resolve_redirect_url resolves a 3xx Location against the request URL,
// handling absolute, scheme-relative, root-relative and path-relative forms.
resolve_redirect_url :: proc(current, location: string) -> (string, bool) {
	loc := strings.trim_space(location)
	if loc == "" do return "", false
	if strings.has_prefix(loc, "http://") || strings.has_prefix(loc, "https://") {
		return strings.clone(loc), true
	}
	scheme := "http"
	rest := current
	if strings.has_prefix(rest, "https://") {
		scheme = "https"
		rest = rest[len("https://"):]
	} else if strings.has_prefix(rest, "http://") {
		rest = rest[len("http://"):]
	} else {
		return "", false
	}
	slash := strings.index_byte(rest, '/')
	authority := rest if slash < 0 else rest[:slash]
	prefix := fmt.tprintf("%s://%s", scheme, authority)
	if strings.has_prefix(loc, "//") {
		return strings.concatenate({scheme, ":", loc}), true
	}
	if strings.has_prefix(loc, "/") {
		return strings.concatenate({prefix, loc}), true
	}
	_, _, _, current_path, path_ok := split_url(current)
	if !path_ok do return "", false
	dir := "/"
	if last := strings.last_index_byte(current_path, '/'); last > 0 do dir = current_path[:last]
	return strings.concatenate({prefix, dir, "/", loc}), true
}

// response_header_value extracts one header value (case-insensitive name)
// from a raw header block (status line + headers, no body).
response_header_value :: proc(headers, name: string) -> string {
	colon := strings.index(headers, "\r\n")
	if colon < 0 do return ""
	text := headers[colon+2:]
	for line in strings.split_lines_iterator(&text) {
		idx := strings.index_byte(line, ':')
		if idx <= 0 do continue
		if strings.equal_fold(strings.trim_space(line[:idx]), name) {
			return strings.trim_space(line[idx+1:])
		}
	}
	return ""
}

// response_status parses "HTTP/1.1 <code> ..." from a header block.
response_status :: proc(headers: string) -> int {
	if len(headers) >= 12 && (strings.has_prefix(headers, "HTTP/1.1 ") || strings.has_prefix(headers, "HTTP/1.0 ")) {
		if parsed, ok := strconv.parse_int(headers[9:12]); ok do return int(parsed)
	}
	return 0
}

// download_to_file_once performs a single GET attempt. On a 3xx it returns
// the status and the resolved Location without touching dest_path; on 200 it
// streams the body to dest_path; on any other status it returns the status.
download_to_file_once :: proc(url, dest_path: string, timeout_ms: int) -> (status: int, location: string, ok: bool) {
	host, port, secure, path, split_ok := split_url(url)
	if !split_ok do return 0, "", false

	stream: Download_Stream
	tls_ctx: Download_Tls_Ctx
	socket: net.TCP_Socket
	tls_stream: tls.Stream
	have_socket := false
	have_tls := false
	budget := time.Duration(timeout_ms if timeout_ms > 0 else DEFAULT_TIMEOUT_MS) * time.Millisecond

	if secure {
		dialed, dial_ok := tls.dial(host, port, budget)
		if !dial_ok do return 0, "", false
		tls_stream = dialed
		have_tls = true
	} else {
		dialed, dial_ok := dial_tcp_with_timeout(host, int(port), timeout_ms)
		if !dial_ok do return 0, "", false
		socket = dialed
		have_socket = true
	}

	// Resource teardown is registered at procedure scope: Odin defers run at
	// the end of the enclosing BLOCK, so branch-local defers would release the
	// transport before the response body is read.
	defer if have_socket do net.close(socket)
	defer if have_tls do tls.close(&tls_stream)

	req := build_http_request("GET", host, port, path, "", nil, true)
	defer delete(req)
	if secure {
		write_res := tls.write_all(&tls_stream, transmute([]byte)req)
		tls.close_write(&tls_stream)
		if write_res != .Ok do return 0, "", false
		tls_ctx = Download_Tls_Ctx{
			stream = &tls_stream,
			deadline = time.to_unix_nanoseconds(time.now()) + i64(budget),
		}
		stream = Download_Stream{read = download_tls_read, ctx = &tls_ctx}
	} else {
		if timeout_ms > 0 {
			timeout := time.Duration(timeout_ms) * time.Millisecond
			if net.set_option(socket, .Send_Timeout, timeout) != nil do return 0, "", false
			if net.set_option(socket, .Receive_Timeout, timeout) != nil do return 0, "", false
		}
		_, send_err := net.send_tcp(socket, transmute([]byte)req)
		if send_err != nil do return 0, "", false
		stream = Download_Stream{read = download_socket_read, ctx = &socket}
	}

	headers, headers_ok := ds_read_headers(&stream)
	if !headers_ok do return 0, "", false
	defer delete(headers)

	status = response_status(headers)
	if status >= 300 && status < 400 {
		// clone: the caller owns `location` and may delete it after resolving
		return status, strings.clone(response_header_value(headers, "Location")), true
	}
	if status != 200 do return status, "", true

	part_path := strings.concatenate({dest_path, ".part"})
	defer delete(part_path)
	f, open_err := os.open(part_path, os.File_Flags{.Write, .Create, .Trunc})
	if open_err != nil do return 0, "", false
	success := false
	if response_transfer_chunked(headers) {
		size_line: [128]byte
		for {
			line, line_ok := ds_read_line(&stream, size_line[:])
			if !line_ok do break
			if semi := strings.index(line, ";"); semi >= 0 do line = line[:semi]
			size, size_ok := parse_hex_size(line)
			if !size_ok do break
			if size == 0 {
				success = true
				break
			}
			if !ds_write_to_file(&stream, f, size) do break
			// each chunk is followed by CRLF; consume exactly those two bytes
			end: [2]byte
			crlf_ok := true
			for i := 0; i < 2; i += 1 {
				if !ds_fill(&stream) {
					crlf_ok = false
					break
				}
				end[i] = stream.buf[stream.pos]
				stream.pos += 1
			}
			if !crlf_ok || end[0] != '\r' || end[1] != '\n' do break
		}
	} else if length := response_content_length(headers); length >= 0 {
		success = ds_write_to_file(&stream, f, length)
	} else {
		success = ds_drain_to_file(&stream, f)
	}
	_ = os.close(f)
	if !success {
		_ = os.remove(part_path)
		return 0, "", false
	}
	if os.rename(part_path, dest_path) != nil {
		_ = os.remove(part_path)
		return 0, "", false
	}
	return 200, "", true
}

download_to_file :: proc(url, dest_path: string, timeout_ms: int, max_redirects := DOWNLOAD_MAX_REDIRECTS) -> (status: int, ok: bool) {
	current := strings.clone(url)
	defer delete(current)
	for redirects := 0; ; redirects += 1 {
		status, location, once_ok := download_to_file_once(current, dest_path, timeout_ms)
		if !once_ok do return status, false
		if status >= 300 && status < 400 {
			if redirects >= max_redirects || strings.trim_space(location) == "" {
				if location != "" do delete(location)
				return status, false
			}
			next, resolved := resolve_redirect_url(current, location)
			delete(location)
			if !resolved do return status, false
			delete(current)
			current = next
			continue
		}
		return status, status == 200
	}
}

os_error_is_timeout :: proc(err: os.Error) -> bool {
	if err == nil do return false
	general, ok := err.(os.General_Error)
	if !ok do return false
	return general == .Timeout
}

// base_url_path_prefix is the path part of a base URL without its trailing slash
// ("" for an origin-only base). Query and fragment are not part of a base URL.
base_url_path_prefix :: proc(base_url: string) -> string {
	url := strings.trim_space(base_url)
	if strings.has_prefix(url, "https://") do url = url[len("https://"):]
	else if strings.has_prefix(url, "http://") do url = url[len("http://"):]
	if cut := strings.index_any(url, "?#"); cut >= 0 do url = url[:cut]
	slash := strings.index_byte(url, '/')
	if slash < 0 do return ""
	return strings.trim_right(url[slash:], "/")
}

// request_target joins a base URL's path prefix and a request path (which starts
// with '/'). Temp-allocated when a prefix applies.
request_target :: proc(base_url, path: string) -> string {
	prefix := base_url_path_prefix(base_url)
	if prefix == "" do return path
	return strings.concatenate({prefix, path}, context.temp_allocator)
}

parse_base_url :: proc(base_url: string) -> (host: string, port: u16, secure: bool, ok: bool) {
	url := base_url
	default_port: u16 = 80
	if strings.has_prefix(url, "https://") {
		url = url[len("https://"):]
		default_port = 443
		secure = true
	} else if strings.has_prefix(url, "http://") {
		url = url[len("http://"):]
		default_port = 80
	}
	url = strings.trim_right(url, "/")
	if slash := strings.index_byte(url, '/'); slash >= 0 do url = url[:slash]

	colon := strings.last_index_byte(url, ':')
	if colon < 0 {
		host = url
		return host, default_port, secure, strings.trim_space(host) != ""
	}

	host = url[:colon]
	port_s := url[colon + 1:]
	port_i, port_ok := strconv.parse_int(port_s)
	if !port_ok do return "", 0, false, false

	return host, u16(port_i), secure, true
}
