package http

import "core:fmt"
import "core:crypto"
import "core:mem/virtual"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import dbt "odin_test:hub/platform/dbtelemetry"
import metrics "odin_test:lib/metrics"
import ws "odin_test:lib/ws"

// Allow 50 MiB artifact payloads plus multipart/base64 framing overhead.
MAX_HTTP_REQUEST_BYTES :: 80 * 1024 * 1024

Server_Config :: struct {
	bind_host: string,
	port: int,
	preview_origin: string,
	ui_origin: string,
	preview_ctx: rawptr,
	preview_handler: Upgrade_Handler_Proc,
}

Server_State :: struct {
	router: ^Router,
	config: Server_Config,
}

serve :: proc(router: ^Router, config: Server_Config) -> bool {
	address := net.IP4_Loopback
	if config.bind_host != "127.0.0.1" {
		if parsed, ok := net.parse_ip4_address(config.bind_host); ok do address = parsed
	}
	listener, err := net.listen_tcp({address, config.port})
	if err != nil {
		fmt.eprintln("ham-hub listen failed", config.bind_host, config.port, err)
		return false
	}
	defer net.close(listener)
	fmt.println("ham-hub listening", config.bind_host, config.port)
	state := Server_State{router = router, config = config}
	for {
		client, source, accept_err := net.accept_tcp(listener)
		if accept_err != nil {
			// Count it, then yield briefly: on EMFILE accept() fails immediately
			// and this loop would otherwise spin a core until an fd frees up.
			metrics.counter_inc(http_metrics.accept_errors)
			time.sleep(10 * time.Millisecond)
			continue
		}
		// thread-spawn: startup (caller's allocator is the process heap)
		thread.run_with_poly_data3(client, source, &state, handle_client_thread)
	}
}

handle_client_thread :: proc(client: net.TCP_Socket, source: net.Endpoint, state: ^Server_State) { handle_client(client, source, state.router, state.config) }

handle_client :: proc(client: net.TCP_Socket, source: net.Endpoint, router: ^Router, config: Server_Config = {}) {
	defer net.close(client)
	// Per-request arena. Every allocation this request makes — the parsed request
	// strings, handler JSON builders, the response body, and the repository row
	// clones threaded up through the services — is drawn from one arena and freed
	// together after the response is written. This structurally reclaims the
	// per-request working set that previously leaked on the process-wide heap (see
	// the MEM-2 RCA: server.odin request clones, envelope response bodies, handler
	// builders, and user/task repository clones). If the arena cannot be created we
	// fall back to the heap (correct, just not reclaimed) rather than fail the request.
	heap := context.allocator
	arena: virtual.Arena
	arena_ok := virtual.arena_init_growing(&arena, 256 * 1024) == nil
	defer if arena_ok do virtual.arena_destroy(&arena)
	// Assign context.allocator at THIS (proc-body) scope — never inside a nested
	// `if ... {}`/`do`. Odin saves and restores `context` at every block boundary,
	// so a conditional assignment made in a nested scope silently reverts when that
	// scope exits (which would leave dispatch running on the heap and the arena
	// unused). Compute the allocator into a local, then assign once here.
	req_allocator := heap
	if arena_ok do req_allocator = virtual.arena_allocator(&arena)
	context.allocator = req_allocator

	request, ok := read_http_request(client)
	if !ok do return
	method, target := request_method_target(request)
	path, query := split_target_query(target)
	body := request_body(request)
	headers := parse_headers(request)
	defer free_request_headers(headers)
	request_id := header_value(headers, "X-Request-Id")
	if request_id == "" do request_id = "req_local"
	req_obj := Request{
		method = method,
		path = path,
		query = query,
		raw_target = target,
		body = body,
		request_id = request_id,
		remote_addr = net.address_to_string_allocator(source.address),
		headers = headers,
	}
	// The preview origin is a separate security boundary. Dispatch it before
	// OPTIONS and every router path so no Hub API can ever be reached by Host.
	if config.preview_origin != "" && preview_origin_host_matches(header_value(headers, "Host"), config.preview_origin) {
		context.allocator = heap
		if config.preview_handler != nil do config.preview_handler(config.preview_ctx, req_obj, client)
		return
	}
	is_upgrade := ascii_equal_fold(header_value(headers, "Upgrade"), "websocket")
	if allowed, reason := csrf_decide(method, headers, config.ui_origin, is_upgrade); !allowed {
		write_http_response(client, Response{status = 403, content_type = "application/json", body = csrf_rejected_body(reason)})
		return
	}
	if method == "OPTIONS" {
		write_http_response(client, Response{status = 204, content_type = "text/plain", body = ""})
		return
	}
	if is_upgrade {
		// Upgraded connections are long-lived, so the WS read loop and everything it
		// allocates over the connection's lifetime must run on the persistent heap,
		// NOT this request arena (which is freed only at disconnect). Assigning
		// context.allocator here applies for the duration of the upgrade call; if the
		// request is not actually an upgrade route, control falls through and this
		// block's boundary restores the arena allocator for the normal dispatch below
		// (the registry / event-bus / ticket stores clone what they retain, so the
		// small parse-time arena is safe to free at disconnect).
		context.allocator = heap
		if router_dispatch_upgrade(router, req_obj, client) do return
	}
	// Raw-socket routes (raw=true in the router) handle ALL request methods — they must
	// also serve plain HTTP GET/POST, not just WebSocket upgrades.  Set context.allocator
	// to the persistent heap before dispatching: these handlers are long-lived and make
	// per-chunk allocations that must outlive the per-request arena.  Explicitly restore
	// req_allocator afterwards so normal router_dispatch runs on the arena as designed.
	context.allocator = heap
	if router_dispatch_raw_upgrade(router, req_obj, client) do return
	context.allocator = req_allocator
	// HTTP metrics cover ONLY this plain-dispatch path: the timer starts after the
	// request was fully read and the upgrade/raw paths above have been ruled out,
	// so long-lived WebSocket connections never land in the latency histogram.
	metrics.gauge_inc(http_metrics.in_flight)
	defer metrics.gauge_dec(http_metrics.in_flight)
	dbt.scope_begin(.Http)
	started := time.tick_now()
	resp, route := router_dispatch_matched(router, req_obj)
	elapsed := time.tick_since(started)
	http_metrics_observe(route, method, resp.status, elapsed)
	http_request_db_observe(route, method, resp.status, elapsed, req_obj.request_id)
	write_http_response(client, resp)
}

preview_origin_host_matches :: proc(host, preview_origin: string) -> bool {
	if preview_origin == "" do return false
	expected := preview_origin
	if strings.has_prefix(strings.to_lower(expected, context.temp_allocator), "https://") do expected = expected[len("https://"):]
	expected = strings.trim_right(expected, "/")
	actual := strings.trim_space(host)
	if strings.has_suffix(strings.to_lower(expected, context.temp_allocator), ":443") do expected = expected[:len(expected)-4]
	if strings.has_suffix(strings.to_lower(actual, context.temp_allocator), ":443") do actual = actual[:len(actual)-4]
	return strings.equal_fold(actual, expected)
}


read_http_request :: proc(client: net.TCP_Socket) -> (string, bool) {
	buf: [8192]byte
	data := make([dynamic]byte, 0, 8192)
	// `data` is never handed to the caller (a clone is returned instead), and none of the
	// three return paths below freed it: every request leaked its full 8192-byte capacity.
	defer delete(data)
	for {
		n, recv_err := net.recv_tcp(client, buf[:])
		if recv_err != nil || n <= 0 do return "", false
		append(&data, ..buf[:n])
		raw := string(data[:])
		if request_complete(raw) do return strings.clone(raw), true
		if len(data) > MAX_HTTP_REQUEST_BYTES do return "", false
	}
}

request_complete :: proc(raw: string) -> bool {
	idx := strings.index(raw, "\r\n\r\n")
	if idx < 0 do return false
	return len(raw[idx + 4:]) >= content_length(raw[:idx])
}

content_length :: proc(headers: string) -> int {
	text := headers
	for line in strings.split_lines_iterator(&text) {
		if ascii_has_prefix_fold(line, "Content-Length:") {
			if parsed, ok := strconv.parse_int(strings.trim_space(line[len("Content-Length:"):])); ok do return int(parsed)
		}
	}
	return 0
}

request_method_target :: proc(request: string) -> (string, string) {
	line_end := strings.index(request, "\r\n")
	if line_end < 0 do return "", ""
	parts := strings.split(request[:line_end], " ")
	defer delete(parts)
	if len(parts) < 2 do return "", ""
	return strings.clone(parts[0]), strings.clone(parts[1])
}

split_target_query :: proc(target: string) -> (string, string) {
	idx := strings.index_byte(target, '?')
	if idx < 0 do return target, ""
	return target[:idx], target[idx + 1:]
}

parse_headers :: proc(request: string) -> []contracts.HTTP_Header {
	out := make([dynamic]contracts.HTTP_Header)
	head_end := strings.index(request, "\r\n\r\n")
	if head_end < 0 do return out[:]
	head := request[:head_end]
	first := true
	for line in strings.split_lines_iterator(&head) {
		if first { first = false; continue }
		colon := strings.index_byte(line, ':')
		if colon <= 0 do continue
		append(&out, contracts.HTTP_Header{name = strings.clone(strings.trim_space(line[:colon])), value = strings.clone(strings.trim_space(line[colon + 1:]))})
	}
	return out[:]
}

free_request_headers :: proc(headers: []contracts.HTTP_Header) {
	for h in headers {
		delete(h.name)
		delete(h.value)
	}
	delete(headers)
}

header_value :: proc(headers: []contracts.HTTP_Header, name: string) -> string {
	for h in headers {
		if ascii_equal_fold(h.name, name) do return strings.trim_space(h.value)
	}
	return ""
}

request_body :: proc(request: string) -> string {
	idx := strings.index(request, "\r\n\r\n")
	if idx < 0 do return ""
	return request[idx + 4:]
}

write_http_response :: proc(client: net.TCP_Socket, resp: Response) {
	body := resp.body
	defer if resp.sensitive && body!="" do crypto.zero_explicit(raw_data(body),len(body))
	content_type := resp.content_type
	if content_type == "" do content_type = "application/json"
	b := strings.builder_make()
	// The builder holds the response headers *and* a copy of the whole body, so leaving
	// it undestroyed leaked roughly one response-size per request.
	defer strings.builder_destroy(&b)
	strings.write_string(&b, fmt.tprintf("HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n", resp.status, status_text(resp.status), content_type, len(body)))
	strings.write_string(&b, "Access-Control-Allow-Origin: *\r\n")
	strings.write_string(&b, "Access-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, OPTIONS\r\n")
	strings.write_string(&b, "Access-Control-Allow-Headers: Authorization, Content-Type, X-Request-Id, X-Heimdall-Instance-Token\r\n")
	strings.write_string(&b, "Access-Control-Max-Age: 600\r\n")
	for h in resp.headers {
		strings.write_string(&b, h.name)
		strings.write_string(&b, ": ")
		strings.write_string(&b, h.value)
		strings.write_string(&b, "\r\n")
	}
	strings.write_string(&b, "\r\n")
	strings.write_string(&b, body)
	raw := strings.to_string(b)
	defer if resp.sensitive && raw!="" do crypto.zero_explicit(raw_data(raw),len(raw))
	if resp.write_timeout_ms>0 {_,_=ws.send_socket_bytes(client,transmute([]byte)raw,time.Duration(resp.write_timeout_ms)*time.Millisecond)} else {_,_=net.send_tcp(client,transmute([]byte)raw)}
}

status_text :: proc(status: int) -> string {
	switch status {
	case 200: return "OK"
	case 201: return "Created"
	case 202: return "Accepted"
	case 204: return "No Content"
	case 301: return "Moved Permanently"
	case 302: return "Found"
	case 304: return "Not Modified"
	case 400: return "Bad Request"
	case 401: return "Unauthorized"
	case 402: return "Payment Required"
	case 403: return "Forbidden"
	case 404: return "Not Found"
	case 409: return "Conflict"
	case 410: return "Gone"
	case 429: return "Too Many Requests"
	case 500: return "Internal Server Error"
	case 503: return "Service Unavailable"
	}
	return "OK"
}

ascii_has_prefix_fold :: proc(value, prefix: string) -> bool {
	if len(value) < len(prefix) do return false
	return ascii_equal_fold(value[:len(prefix)], prefix)
}

ascii_equal_fold :: proc(a, b: string) -> bool {
	if len(a) != len(b) do return false
	for i in 0..<len(a) {
		ca := a[i]
		cb := b[i]
		if ca >= 'A' && ca <= 'Z' do ca += 32
		if cb >= 'A' && cb <= 'Z' do cb += 32
		if ca != cb do return false
	}
	return true
}
