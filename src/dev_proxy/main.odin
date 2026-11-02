package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"

main :: proc() {
	config := default_dev_proxy_config()
	parse_args(&config)
	if len(os.args) > 1 && os.args[1] == "--print-config" {
		fmt.printfln("ham-dev-proxy listen=%s hub_url=%s default_user=%s", config.listen, config.hub_url, config.default_user)
		return
	}
	// DP-1 / DP-5: load the persisted dev-user roster + active selection from
	// the XDG/HEIMDALL_HOME data dir and merge with seed users. The persisted
	// `active` username becomes config.default_user (the select_dev_user
	// fallback); an existing ham_dev_user cookie still wins per request.
	store := new(Dev_Proxy_Store)
	data_dir, store_path, loaded := dev_proxy_store_init(store, &config)
	fmt.println("ham-dev-proxy data_dir", data_dir)
	fmt.printfln("ham-dev-proxy store_path=%s loaded=%v active=%s", store_path, loaded, config.default_user)
	// DP-7: management API/UI (/_dev/*) are served ONLY on a loopback bind.
	// A non-loopback --listen disables management routes (they 404) so the
	// dev-only identity manager is never exposed remotely.
	listen_host, _, _ := split_host_port(config.listen)
	config.management_enabled = is_loopback_host(listen_host)
	if !config.management_enabled {
		fmt.println("ham-dev-proxy: non-loopback bind; management routes disabled")
	}
	run_dev_proxy_server(config, store)
}

parse_args :: proc(config: ^Dev_Proxy_Config) {
	for i := 1; i < len(os.args); i += 1 {
		arg := os.args[i]
		if arg == "--listen" && i + 1 < len(os.args) {
			config.listen = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--hub-url" && i + 1 < len(os.args) {
			config.hub_url = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--default-user" && i + 1 < len(os.args) {
			config.default_user = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--hub-ui-origin" && i + 1 < len(os.args) {
			config.hub_ui_origin = strings.clone(strings.trim_right(os.args[i + 1], "/")); i += 1
		} else if arg == "--trusted-origin" && i + 1 < len(os.args) {
			append(&config.trusted_origins, strings.clone(strings.trim_right(os.args[i + 1], "/"))); i += 1
		}
	}
}

run_dev_proxy_server :: proc(config: Dev_Proxy_Config, store: ^Dev_Proxy_Store) -> bool {
	host, port, ok := split_host_port(config.listen)
	if !ok {
		fmt.eprintln("invalid --listen", config.listen)
		return false
	}
	address := net.IP4_Loopback
	if host != "127.0.0.1" {
		if parsed, parsed_ok := net.parse_ip4_address(host); parsed_ok do address = parsed
	}
	listener, err := net.listen_tcp({address, port})
	if err != nil {
		fmt.eprintln("ham-dev-proxy listen failed", config.listen, err)
		return false
	}
	defer net.close(listener)
	fmt.println("ham-dev-proxy listening", config.listen, "hub_url", config.hub_url)
	// Shared mutable config: one heap instance so management-API mutations
	// (create/delete/set-active) are visible to every connection thread. The
	// task-1 store mutex guards writes to the users slice + active selection.
	shared_config := new(Dev_Proxy_Config)
	shared_config^ = config
	broker := new(Dev_Session_Broker)
	for {
		client, _, accept_err := net.accept_tcp(listener)
		if accept_err != nil do continue
		ctx := new(Dev_Proxy_Client_Context)
		ctx.config = shared_config
		ctx.store = store
		ctx.broker = broker
		ctx.client = client
		thread.run_with_poly_data(ctx, handle_dev_proxy_client)
	}
}

Dev_Proxy_Client_Context :: struct {
	config: ^Dev_Proxy_Config,
	store: ^Dev_Proxy_Store,
	broker: ^Dev_Session_Broker,
	client: net.TCP_Socket,
}

handle_dev_proxy_client :: proc(ctx: ^Dev_Proxy_Client_Context) {
	defer free(ctx)
	client := ctx.client
	defer net.close(client)
	request, ok := read_http_request(client)
	if !ok do return
	method, target := request_method_target(request)
	path, query := split_target_query(target)
	if strings.has_prefix(path, "/_dev/") {
		// DP-7: hard loopback boundary for the entire management surface.
		if !ctx.config.management_enabled {
			write_response(client, 404, "Not Found", "text/plain", "management routes disabled on non-loopback bind")
			return
		}
		// Management routes are handled locally and NEVER forwarded (DP-6).
		if handle_dev_api_request(ctx, method, path, request_body(request)) do return
		if handle_dev_ui_request(client, path) do return
		if strings.has_prefix(path, "/_dev/login") {
			user := query_param(query, "user")
			if !dev_user_exists(ctx.config, user) {
				write_response(client, 400, "Bad Request", "text/plain", "unknown dev user")
				return
			}
			write_response_with_headers(client, 204, "No Content", "text/plain", "", []contracts.HTTP_Header{{name = "Set-Cookie", value = login_response_cookie(user)}})
			return
		}
		if path == "/_dev/logout" {
			write_response_with_headers(client, 204, "No Content", "text/plain", "", []contracts.HTTP_Header{{name = "Set-Cookie", value = logout_response_cookie()}})
			return
		}
		write_response(client, 404, "Not Found", "text/plain", "not found")
		return
	}
	forward_request(ctx, request, method, target)
}

forward_request :: proc(ctx: ^Dev_Proxy_Client_Context, request, method, target: string) {
	client := ctx.client
	config := ctx.config
	broker := ctx.broker
	incoming := parse_headers(request)
	defer free_headers(incoming)
	cookie := header_value(incoming, "Cookie")
	rewritten, user, ok := rewrite_headers_for_hub(config, incoming, cookie)
	if !ok {
		write_response(client, 400, "Bad Request", "text/plain", "unknown dev user")
		return
	}
	defer free_headers(rewritten)
	path, query := split_target_query(target)

	// REQ-DEVAUTH-1: sign-in is brokered, not sent through the browser.
	if path == "/api/v1/auth/login" && !broker_is_real_idp(broker) && is_browser_navigation(incoming) {
		if handle_broker_login(client, config, broker, user.username, query) do return
	}

	// WebSocket detection: a client requesting `Connection: Upgrade` +
	// `Upgrade: websocket` needs a persistent bidirectional tunnel, not the
	// one-shot request/response copy.
	is_ws := ascii_equal_fold(header_value(incoming, "Upgrade"), "websocket")
	is_logout := path == "/api/v1/auth/logout"

	// REQ-DEVAUTH-2: attach the dev user's brokered session (signing in first if
	// needed) to trusted browser requests. The sign-in routes themselves are left
	// alone (a script's callback carries its own login cookie), except sign-out,
	// which never triggers a sign-in.
	session := ""
	brokerable := is_logout || !strings.has_prefix(path, "/api/v1/auth/")
	if brokerable && !broker_is_real_idp(broker) && broker_request_trusted(config, incoming) {
		session = broker_cached_session(broker, user.username) if is_logout else broker_session(broker, config, user.username)
	}
	body := request_body(request)
	for attempt in 0 ..< 2 {
		headers := rewritten
		if session != "" do headers = broker_headers_for_hub(rewritten, session, broker_ui_origin(broker, config))
		upstream, sent := send_upstream_request(client, config, method, target, headers, body, is_ws)
		if session != "" do free_headers(headers)
		if !sent do return
		if is_ws {
			proxy_tunnel_bidirectional(client, upstream)
			net.close(upstream)
			return
		}
		if path == "/api/v1/auth/login" {
			// Provider-driven sign-in (a real provider, or a script running the flow
			// itself): apply the dev user as login_hint.
			proxy_copy_login_response(client, upstream, user.username)
			net.close(upstream)
			return
		}
		_ = net.set_option(upstream, .Receive_Timeout, 16 * time.Minute)
		data, head_end, head_ok := read_response_head(upstream)
		if !head_ok {
			delete(data)
			net.close(upstream)
			write_response(client, 502, "Bad Gateway", "text/plain", "hub response incomplete")
			return
		}
		head := string(data[:head_end])
		status := response_status(head)
		// The Hub rejected the brokered session (expired, hub DB reset): sign in
		// again once and replay the request.
		if status == 401 && session != "" && attempt == 0 && !is_logout {
			delete(data)
			net.close(upstream)
			broker_invalidate(broker, user.username, session)
			session = broker_session(broker, config, user.username)
			continue
		}
		if session != "" {
			head = strip_hub_auth_set_cookies(head)
			// REQ-DEVAUTH-3: sign-out ends the brokered session too.
			if is_logout && status < 400 do broker_sign_out(broker, user.username)
		}
		_, _ = net.send_tcp(client, transmute([]byte)head)
		_, _ = net.send_tcp(client, transmute([]byte)string("\r\n\r\n"))
		if len(data) > head_end + 4 do _, _ = net.send_tcp(client, data[head_end + 4:])
		delete(data)
		proxy_copy_response(client, upstream)
		net.close(upstream)
		return
	}
}

// handle_broker_login answers /api/v1/auth/login by signing the dev user in to
// the Hub and redirecting to the (local, relative) return_to, so the redirect
// stays inside a preview prefix. Returns false when the provider is real and the
// request should take the browser-driven path instead.
handle_broker_login :: proc(client: net.TCP_Socket, config: ^Dev_Proxy_Config, broker: ^Dev_Session_Broker, username, query: string) -> bool {
	_, err := broker_login(broker, config, username, true)
	if err == .Real_Idp do return false
	if err != .None {
		message := broker_login_error_message(err)
		fmt.eprintln(message)
		write_response(client, 502, "Bad Gateway", "text/plain", message)
		return true
	}
	location := safe_return_to(query_param(query, "return_to"))
	write_response_with_headers(client, 302, "Found", "text/plain", "", []contracts.HTTP_Header{
		{name = "Location", value = location},
		{name = "Set-Cookie", value = EXPIRED_HUB_SESSION_COOKIE},
		{name = "Cache-Control", value = "no-store"},
	})
	return true
}

// send_upstream_request dials the Hub and writes the request. On failure it has
// already answered the client with a 502.
send_upstream_request :: proc(client: net.TCP_Socket, config: ^Dev_Proxy_Config, method, target: string, headers: []contracts.HTTP_Header, body: string, is_ws: bool) -> (net.TCP_Socket, bool) {
	hub_host, hub_port, hub_ok := parse_base_url(config.hub_url)
	if !hub_ok {
		write_response(client, 502, "Bad Gateway", "text/plain", "invalid hub_url")
		return {}, false
	}
	upstream, dial_err := net.dial_tcp_from_hostname_with_port_override(hub_host, hub_port)
	if dial_err != nil {
		write_response(client, 502, "Bad Gateway", "text/plain", "hub unavailable")
		return {}, false
	}
	// For WS we must FORWARD the upgrade headers to the hub (unlike normal
	// requests, where Connection is stripped and forced to close), relay the
	// `101`, then pump both directions with no read timeout.
	out := strings.builder_make(context.temp_allocator)
	strings.write_string(&out, method); strings.write_string(&out, " "); strings.write_string(&out, target); strings.write_string(&out, " HTTP/1.1\r\n")
	strings.write_string(&out, "Host: "); strings.write_string(&out, hub_host); strings.write_string(&out, ":"); strings.write_string(&out, fmt.tprintf("%d", hub_port)); strings.write_string(&out, "\r\n")
	for h in headers {
		if ascii_equal_fold(h.name, "Host") || ascii_equal_fold(h.name, "Content-Length") || ascii_equal_fold(h.name, "Connection") do continue
		// For non-WS requests we drop any client-supplied Upgrade; for WS we keep
		// the Sec-WebSocket-* headers and add our own Connection/Upgrade line.
		if is_ws && ascii_equal_fold(h.name, "Upgrade") do continue
		strings.write_string(&out, h.name); strings.write_string(&out, ": "); strings.write_string(&out, h.value); strings.write_string(&out, "\r\n")
	}
	if is_ws {
		strings.write_string(&out, "Connection: Upgrade\r\nUpgrade: websocket\r\n\r\n")
	} else {
		strings.write_string(&out, fmt.tprintf("Content-Length: %d\r\nConnection: close\r\n\r\n", len(body)))
		strings.write_string(&out, body)
	}
	out_req := strings.to_string(out)
	if _, send_err := net.send_tcp(upstream, transmute([]byte)out_req); send_err != nil {
		net.close(upstream)
		write_response(client, 502, "Bad Gateway", "text/plain", "hub send failed")
		return {}, false
	}
	return upstream, true
}

proxy_copy_login_response :: proc(client, upstream: net.TCP_Socket, username: string) {
	_ = net.set_option(upstream, .Receive_Timeout, 30 * time.Second)
	data := make([dynamic]byte, 0, 4096)
	defer delete(data)
	buf: [8192]byte
	for {
		n, recv_err := net.recv_tcp(upstream, buf[:])
		if recv_err != nil || n <= 0 do break
		append(&data, ..buf[:n])
		if len(data) > 1024 * 1024 do break
	}
	out := rewrite_login_location(string(data[:]), username)
	_, _ = net.send_tcp(client, transmute([]byte)out)
}

// proxy_tunnel_bidirectional pumps raw bytes in both directions between the
// browser and the hub after a WebSocket upgrade. The hub's `101 Switching
// Protocols` response (and all subsequent frames) flow through the
// upstream->client direction; browser frames flow client->upstream. No receive
// timeout: the tunnel stays open until either side closes/errs, then both are
// torn down. This is what the one-shot `proxy_copy_response` (5s timeout) could
// not do, which caused the user-ws to drop every 5s and the UI to reconnect and
// refetch in a loop.
Proxy_Tunnel_Half :: struct { src: net.TCP_Socket, dst: net.TCP_Socket }

proxy_tunnel_bidirectional :: proc(client, upstream: net.TCP_Socket) {
	// No read timeouts on either socket for the life of the tunnel. A zero
	// Duration disables the timeout; the value must be a time.Duration (a bare
	// literal 0 panics set_option).
	_ = net.set_option(client, .Receive_Timeout, time.Duration(0))
	_ = net.set_option(upstream, .Receive_Timeout, time.Duration(0))
	// Pump upstream -> client on a joinable thread (self_cleanup=false so we
	// can join it here). The callers own the fd lifecycle: forward_request has
	// `defer net.close(upstream)` and handle_dev_proxy_client has
	// `defer net.close(client)`. This proc only shuts down the receive sides to
	// wake both pumps, then joins — it does NOT close the fds. Closing here would
	// double-close: an fd freed by a first close can be reused before the second
	// close arrives, landing on an unrelated connection (the original fd-reuse bug
	// class). Fire-and-forget (run_with_poly_data) caused the same hazard; joining
	// before the caller's defer fires is what makes single-close safe here.
	half := new(Proxy_Tunnel_Half)
	half.src = upstream; half.dst = client
	pump := thread.create_and_start_with_data(rawptr(half), proxy_tunnel_pump, self_cleanup = false)
	// Pump client -> upstream on this thread until either side closes.
	proxy_tunnel_copy(client, upstream)
	// Wake the pump if it is still blocked on recv(upstream). shutdown(SHUT_RD)
	// is required; close(fd) from another thread does not unblock recv(fd) on Linux.
	net.shutdown(upstream, .Receive)
	thread.join(pump)
	thread.destroy(pump)
	// Both fds are closed by the callers' defers after this proc returns.
}

proxy_tunnel_pump :: proc(data: rawptr) {
	half := (^Proxy_Tunnel_Half)(data)
	src := half.src  // upstream
	dst := half.dst  // client
	free(half)
	proxy_tunnel_copy(src, dst)
	// Wake the main thread if it is still blocked on recv(client).
	net.shutdown(dst, .Receive)
}

proxy_tunnel_copy :: proc(src, dst: net.TCP_Socket) {
	buf: [8192]byte
	for {
		n, recv_err := net.recv_tcp(src, buf[:])
		if recv_err != nil || n <= 0 do break
		_, send_err := net.send_tcp(dst, buf[:n])
		if send_err != nil do break
	}
	// Copy loop only; the caller owns socket teardown.
}

proxy_copy_response :: proc(client, upstream: net.TCP_Socket) {
	// The hub sends Connection: close + Content-Length and closes when done, so
	// this read loop terminates on EOF. The timeout is only a backstop against a
	// truly stuck upstream. It must be generous: some endpoints (e.g. the
	// provider test, which may sequentially launch cheap/normal/smart agents and
	// wait for start-success on each model) can take several minutes to respond. A
	// short timeout drops those responses mid-flight, leaving the UI stuck in a
	// Testing state while the Bridge keeps running the tests.
	_ = net.set_option(upstream, .Receive_Timeout, 16 * time.Minute)
	buf: [8192]byte
	for {
		n, recv_err := net.recv_tcp(upstream, buf[:])
		if recv_err != nil || n <= 0 do break
		_, send_err := net.send_tcp(client, buf[:n])
		if send_err != nil do break
	}
}

read_http_request :: proc(client: net.TCP_Socket) -> (string, bool) {
	buf: [8192]byte
	data := make([dynamic]byte, 0, 8192)
	for {
		n, recv_err := net.recv_tcp(client, buf[:])
		if recv_err != nil || n <= 0 do return "", false
		append(&data, ..buf[:n])
		raw := string(data[:])
		if request_complete(raw) do return strings.clone(raw), true
		if len(data) > 1024 * 1024 do return "", false
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

query_param :: proc(query, name: string) -> string {
	pairs := strings.split(query, "&")
	defer delete(pairs)
	for pair in pairs {
		eq := strings.index_byte(pair, '=')
		if eq < 0 do continue
		if pair[:eq] == name do return strings.clone(pair[eq + 1:])
	}
	return ""
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

request_body :: proc(request: string) -> string {
	idx := strings.index(request, "\r\n\r\n")
	if idx < 0 do return ""
	return request[idx + 4:]
}

parse_base_url :: proc(url: string) -> (string, int, bool) {
	trimmed := strings.trim_space(url)
	if strings.has_prefix(trimmed, "http://") do trimmed = trimmed[len("http://"):]
	slash := strings.index_byte(trimmed, '/')
	if slash >= 0 do trimmed = trimmed[:slash]
	colon := strings.last_index_byte(trimmed, ':')
	if colon < 0 do return strings.clone(trimmed), 80, true
	port_i, ok := strconv.parse_int(trimmed[colon + 1:])
	if !ok do return "", 0, false
	return strings.clone(trimmed[:colon]), int(port_i), true
}

// is_loopback_host reports whether a parsed --listen host is loopback
// (127.0.0.1, ::1, localhost, or empty which defaults to loopback binding).
// Used to gate the management API/UI surface (DP-7).
is_loopback_host :: proc(host: string) -> bool {
	return host == "127.0.0.1" || host == "::1" || host == "localhost" || host == ""
}

split_host_port :: proc(value: string) -> (string, int, bool) {
	colon := strings.last_index_byte(value, ':')
	if colon < 0 do return "", 0, false
	port_i, ok := strconv.parse_int(value[colon + 1:])
	if !ok do return "", 0, false
	return strings.clone(value[:colon]), int(port_i), true
}

dev_user_exists :: proc(config: ^Dev_Proxy_Config, username: string) -> bool {
	for user in config.users {
		if user.username == username do return true
	}
	return false
}

write_response :: proc(client: net.TCP_Socket, status: int, status_text, content_type, body: string) {
	write_response_with_headers(client, status, status_text, content_type, body, nil)
}

write_response_with_headers :: proc(client: net.TCP_Socket, status: int, status_text, content_type, body: string, headers: []contracts.HTTP_Header) {
	b := strings.builder_make()
	strings.write_string(&b, fmt.tprintf("HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n", status, status_text, content_type, len(body)))
	for h in headers {
		strings.write_string(&b, h.name); strings.write_string(&b, ": "); strings.write_string(&b, h.value); strings.write_string(&b, "\r\n")
	}
	strings.write_string(&b, "Connection: close\r\n\r\n")
	strings.write_string(&b, body)
	response := strings.to_string(b)
	_, _ = net.send_tcp(client, transmute([]byte)response)
}

ascii_has_prefix_fold :: proc(value, prefix: string) -> bool {
	if len(value) < len(prefix) do return false
	return ascii_equal_fold(value[:len(prefix)], prefix)
}
