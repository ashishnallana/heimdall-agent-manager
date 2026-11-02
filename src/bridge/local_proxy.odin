package main

// REQ-XM-4 — originating side of the bridge→hub proxy path.
//
// A process on this host talks plain HTTP to the bridge's local endpoint:
//
//     http://127.0.0.1:<local_endpoint_port>/proxy/<target_session_id>/<path...>
//
// The bridge forwards it over the WebSocket it ALREADY holds to the hub (the one
// established at enrollment with its hbr_ token), the hub splices it to the bridge
// that owns <target_session_id>, and that bridge dials 127.0.0.1:<server_port>.
// No inbound port is opened on either machine and no user bearer token or browser
// session appears anywhere in the path — which is the entire point, because the
// hub sits behind Authentik forward auth that rejects machine-originated requests.
//
// This is the preview tunnel pointed the other way: today the hub originates a
// stream toward a bridge (tunnel_open/tunnel_data/tunnel_close); here a bridge
// originates one toward the hub (proxy_open/proxy_data/proxy_close). The frame
// names are deliberately NOT shared with the tunnel_* family: the two directions
// have different lifecycles and overloading the names makes both harder to debug.
//
// AUTH: intentionally permissive, pending REQ-XM-5. Any process that can reach the
// local endpoint acts with this bridge's owner's authority. That is a deliberate,
// user-accepted trade recorded in the task, not an oversight. The bridge performs
// NO authorisation here; the single authorisation decision lives hub-side in
// bridge_proxy_authorise_target so that hardening is one function to change.
// The feature is ENABLED BY DEFAULT (user decision) and disabled by
// --no-local-proxy / [bridge] local_proxy_enabled=false.

import local_socket "odin_test:lib/local_socket"
import "base:runtime"
import base64 "core:encoding/base64"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

// Bridge_Proxy_Stream maps a proxy_id to the LOCAL client socket that originated it.
// The client is whichever local-endpoint transport accepted it, so both the unix
// socket and the loopback TCP listener are represented (same shape as
// Bridge_Wrapper_Push_Conn, which already carries this dual-transport pattern).
Bridge_Proxy_Stream :: struct {
	proxy_id: string,
	kind:     Bridge_Wrapper_Push_Conn_Kind,
	tcp:      net.TCP_Socket,
	unix:     local_socket.Socket,
	closed:   bool,
}

bridge_proxy_streams: map[string]^Bridge_Proxy_Stream
bridge_proxy_mu:      sync.Mutex

// bridge_proxy_init allocates the originating-stream table. Called from
// bridge_hub_runtime_init alongside the tunnel_* tables.
bridge_proxy_init :: proc() {
	bridge_proxy_streams = make(map[string]^Bridge_Proxy_Stream, runtime.heap_allocator())
}

// bridge_proxy_looks_like_http reports whether a first line off the local endpoint is
// an HTTP request line rather than a JSONL command.
//
// The local endpoint speaks a JSONL protocol (wrapper_endpoint.odin): one JSON object
// per line, each carrying its own "token". The two grammars cannot collide — a JSONL
// line is a JSON object and an HTTP request line requires a known method token, a
// target, and the literal " HTTP/1." on the same line — so sniffing the first line is
// an unambiguous demultiplex and leaves the JSONL path byte-for-byte unchanged.
bridge_proxy_looks_like_http :: proc(line: string) -> bool {
	if !strings.contains(line, " HTTP/1.") do return false
	methods := [?]string{"GET ", "POST ", "PUT ", "PATCH ", "DELETE ", "HEAD ", "OPTIONS "}
	for m in methods {
		if strings.has_prefix(line, m) do return true
	}
	return false
}

// Bridge_Proxy_Request is a parsed local HTTP request line + header block.
Bridge_Proxy_Request :: struct {
	method:       string,
	session_id:   string,
	path:         string, // forwarded path, already stripped of /proxy/<session_id>
	query:        string,
	header_block: string, // raw "Name: Value\r\n..." bytes, no trailing blank line
	content_len:  int,
	ok:           bool,
}

// bridge_proxy_parse_request parses the request line and headers of a local proxy
// request. `head` is everything up to and including the CRLFCRLF terminator.
//
// The forwarded path is computed by stripping the "/proxy/<session_id>" prefix, the
// same way the hub's preview route strips "/api/v1/preview/<session_id>" — mirroring
// that logic rather than inventing a second one.
bridge_proxy_parse_request :: proc(head: string, allocator := context.allocator) -> Bridge_Proxy_Request {
	req := Bridge_Proxy_Request{}

	line_end := strings.index(head, "\r\n")
	if line_end < 0 do return req
	request_line := head[:line_end]

	sp1 := strings.index_byte(request_line, ' ')
	if sp1 < 0 do return req
	method := request_line[:sp1]
	rest := request_line[sp1 + 1:]
	sp2 := strings.index_byte(rest, ' ')
	if sp2 < 0 do return req
	target := rest[:sp2]

	// Split off the query string before prefix matching.
	query := ""
	if q := strings.index_byte(target, '?'); q >= 0 {
		query = target[q + 1:]
		target = target[:q]
	}

	if !strings.has_prefix(target, "/proxy/") do return req
	after := target[len("/proxy/"):]
	if after == "" do return req
	session_id := after
	forwarded := "/"
	if slash := strings.index_byte(after, '/'); slash >= 0 {
		session_id = after[:slash]
		forwarded = after[slash:]
	}
	if session_id == "" do return req

	// Header block: between the request line and the terminating blank line.
	header_block := ""
	if head_end := strings.index(head, "\r\n\r\n"); head_end >= 0 {
		header_block = head[line_end + 2:head_end + 2]
	}

	// Content-Length drives how much body to read; absent means no body.
	content_len := 0
	for line in strings.split_lines_iterator(&header_block) {
		colon := strings.index_byte(line, ':')
		if colon < 0 do continue
		name := strings.to_lower(strings.trim_space(line[:colon]), allocator)
		defer delete(name, allocator)
		if name == "content-length" {
			if n, parsed := strconv.parse_int(strings.trim_space(line[colon + 1:])); parsed && n > 0 {
				content_len = n
			}
		}
	}
	// split_lines_iterator consumes header_block; recompute it for the caller.
	if head_end := strings.index(head, "\r\n\r\n"); head_end >= 0 {
		header_block = head[line_end + 2:head_end + 2]
	}

	req.method = strings.clone(method, allocator)
	req.session_id = strings.clone(session_id, allocator)
	req.path = strings.clone(forwarded, allocator)
	req.query = strings.clone(query, allocator)
	req.header_block = strings.clone(header_block, allocator)
	req.content_len = content_len
	req.ok = true
	return req
}

// bridge_proxy_open_frame builds the proxy_open frame.
//
// Headers travel as one base64 blob rather than a JSON array so the wire stays a flat
// set of string fields (the bridge and hub both use hand-rolled JSON here, and neither
// has an array-of-objects parser). The hub decodes the blob, splits it into headers and
// feeds them to the SAME _preview_build_http_request the preview path uses, so the
// request that reaches the target server — allowlist included — is built by exactly one
// piece of code for both paths.
bridge_proxy_open_frame :: proc(proxy_id: string, req: Bridge_Proxy_Request) -> string {
	heap := runtime.heap_allocator()
	encoded := base64.encode(transmute([]byte)req.header_block, base64.ENC_TABLE, heap)
	defer delete(encoded, heap)
	b := strings.builder_make(heap)
	strings.write_string(&b, "{\"type\":\"proxy_open\",\"proxy_id\":\"")
	bridge_runtime_write_json_string(&b, proxy_id)
	strings.write_string(&b, "\",\"target_session_id\":\"")
	bridge_runtime_write_json_string(&b, req.session_id)
	strings.write_string(&b, "\",\"method\":\"")
	bridge_runtime_write_json_string(&b, req.method)
	strings.write_string(&b, "\",\"path\":\"")
	bridge_runtime_write_json_string(&b, req.path)
	strings.write_string(&b, "\",\"query\":\"")
	bridge_runtime_write_json_string(&b, req.query)
	strings.write_string(&b, "\",\"headers_b64\":\"")
	bridge_runtime_write_json_string(&b, string(encoded))
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

bridge_proxy_data_frame :: proc(proxy_id: string, payload: []byte, last: bool) -> string {
	heap := runtime.heap_allocator()
	encoded := base64.encode(payload, base64.ENC_TABLE, heap)
	defer delete(encoded, heap)
	b := strings.builder_make(heap)
	strings.write_string(&b, "{\"type\":\"proxy_data\",\"proxy_id\":\"")
	bridge_runtime_write_json_string(&b, proxy_id)
	strings.write_string(&b, "\",\"data_b64\":\"")
	bridge_runtime_write_json_string(&b, string(encoded))
	strings.write_string(&b, "\",\"last\":")
	strings.write_string(&b, last ? "true" : "false")
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

bridge_proxy_close_frame :: proc(proxy_id, reason: string) -> string {
	heap := runtime.heap_allocator()
	b := strings.builder_make(heap)
	strings.write_string(&b, "{\"type\":\"proxy_close\",\"proxy_id\":\"")
	bridge_runtime_write_json_string(&b, proxy_id)
	strings.write_string(&b, "\",\"reason\":\"")
	bridge_runtime_write_json_string(&b, reason)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

// bridge_proxy_enqueue hands a frame to the runtime loop that owns the WS connection.
// Reuses the tunnel_* outgoing queue: it is a queue of pre-built frame JSON with no
// tunnel-specific behaviour, and it is already drained by the runtime loop on every
// tick, so proxy frames need no second drain site and cannot race a different writer.
bridge_proxy_enqueue :: proc(frame_json: string) {
	if sync.atomic_load(&bridge_hub_traffic_stopped) {
		delete(frame_json, runtime.heap_allocator())
		return
	}
	sync.mutex_lock(&bridge_runtime_mutex)
	append(&bridge_tunnel_data_outgoing, Bridge_Tunnel_Data_Outgoing{json = frame_json})
	sync.mutex_unlock(&bridge_runtime_mutex)
}

// bridge_proxy_send_to_client writes response bytes to the originating local socket.
bridge_proxy_send_to_client :: proc(stream: ^Bridge_Proxy_Stream, payload: []byte) {
	if stream.closed || len(payload) == 0 do return
	switch stream.kind {
	case .TCP:
		_, _ = net.send_tcp(stream.tcp, payload)
	case .Unix:
		_ = local_socket.send(stream.unix, payload)
	}
}

// bridge_proxy_wake_client wakes the local client's reader out of its blocking recv.
// It deliberately does NOT close the socket.
//
// The fd belongs to whichever bridge_local_proxy_serve_* invocation accepted it — that
// proc is the reader and the sole closer, on every exit path.  This proc can be called
// from the WS-reader thread (bridge_hub_handle_proxy_close), where closing would pull the
// fd out from under a thread parked in recv on it; shutting down the receive side instead
// makes that recv return (0/-1) at once so the owner can run its own teardown and close.
// See AGENTS.md, "Socket lifetime across threads".
//
// Only the RECEIVE side is shut down: response bytes still in flight must remain writable.
bridge_proxy_wake_client :: proc(stream: ^Bridge_Proxy_Stream) {
	switch stream.kind {
	case .TCP:
		// Same call as net.shutdown(.Receive) on Unix; on Windows it also cancels the
		// parked recv, which Winsock's shutdown alone does not wake.
		_ = local_socket.shutdown(local_socket.Socket(stream.tcp), .Read)
	case .Unix:
		_ = local_socket.shutdown(stream.unix, .Read)
	}
}

// bridge_proxy_register adds a stream to the table.
bridge_proxy_register :: proc(stream: ^Bridge_Proxy_Stream) {
	heap := runtime.heap_allocator()
	sync.mutex_lock(&bridge_proxy_mu)
	bridge_proxy_streams[strings.clone(stream.proxy_id, heap)] = stream
	sync.mutex_unlock(&bridge_proxy_mu)
}

// bridge_proxy_take removes a stream from the table and reports whether THIS caller is
// the one that removed it.
//
// Same independent-key probe the tunnel path uses: the local reader goroutine and the
// hub's proxy_close can both decide a stream is finished, and whoever removes the key
// owns the free. The loser finds the key absent and must not dereference the pointer.
bridge_proxy_take :: proc(proxy_id: string) -> (^Bridge_Proxy_Stream, bool) {
	heap := runtime.heap_allocator()
	sync.mutex_lock(&bridge_proxy_mu)
	defer sync.mutex_unlock(&bridge_proxy_mu)
	stream, ok := bridge_proxy_streams[proxy_id]
	if !ok do return nil, false
	for k in bridge_proxy_streams {
		if k == proxy_id {
			delete_key(&bridge_proxy_streams, k)
			delete(k, heap)
			break
		}
	}
	return stream, true
}

// BRIDGE_PROXY_RECV_TIMEOUT is the local reader's periodic wake — a backstop only, since
// shutting the receive side down wakes a parked recv immediately.  Both transports use the
// same period; the unix one needs it in seconds because it sets SO_RCVTIMEO itself.
BRIDGE_PROXY_RECV_TIMEOUT_SECS :: 5
BRIDGE_PROXY_RECV_TIMEOUT      :: BRIDGE_PROXY_RECV_TIMEOUT_SECS * time.Second

// bridge_proxy_stream_registered reports whether a proxy_id is still in the table.
//
// A local reader calls this on a timeout wake to ask "has teardown already happened?"
// without dereferencing its ^Bridge_Proxy_Stream, which the hub's proxy_close may already
// have freed.  Same reason the probe in bridge_proxy_take compares keys: the key belongs to
// the table, the struct does not.
bridge_proxy_stream_registered :: proc(proxy_id: string) -> bool {
	sync.mutex_lock(&bridge_proxy_mu)
	defer sync.mutex_unlock(&bridge_proxy_mu)
	for k in bridge_proxy_streams {
		if k == proxy_id do return true
	}
	return false
}

bridge_proxy_free :: proc(stream: ^Bridge_Proxy_Stream) {
	heap := runtime.heap_allocator()
	delete(stream.proxy_id, heap)
	free(stream, heap)
}

// ---- hub→bridge frame handlers (originating side) ----

// bridge_hub_handle_proxy_data writes response bytes from the hub to the local client.
//
// Written straight through to the socket with no accumulation: this is the near end
// that XM-1 rewrote to stream, and buffering a whole response here would reintroduce
// exactly the stall XM-1 removed. The mutex is held across the send so a concurrent
// proxy_close cannot free the struct between lookup and use — the same discipline
// bridge_hub_handle_tunnel_data uses.
bridge_hub_handle_proxy_data :: proc(text: string) {
	proxy_id := extract_json_string(text, "proxy_id", "")
	data_b64 := extract_json_string(text, "data_b64", "")
	defer { delete(proxy_id); delete(data_b64) }
	if proxy_id == "" || data_b64 == "" do return

	decoded, decode_err := base64.decode(data_b64)
	if decode_err != nil || len(decoded) == 0 {
		delete(decoded)
		return
	}
	defer delete(decoded)

	sync.mutex_lock(&bridge_proxy_mu)
	if stream, ok := bridge_proxy_streams[proxy_id]; ok {
		bridge_proxy_send_to_client(stream, decoded)
	}
	sync.mutex_unlock(&bridge_proxy_mu)
}

// bridge_hub_handle_proxy_close tears the local client connection down.
bridge_hub_handle_proxy_close :: proc(text: string) {
	proxy_id := extract_json_string(text, "proxy_id", "")
	defer delete(proxy_id)
	if proxy_id == "" do return

	stream, removed := bridge_proxy_take(proxy_id)
	// If !removed the local reader already finished and freed it.
	if !removed do return
	// Wake the local reader so it can close its own fd; free only the struct here.
	bridge_proxy_wake_client(stream)
	bridge_proxy_free(stream)
}

// ---- local client entry point ----

// bridge_proxy_serve_client owns a local socket whose first line was an HTTP request.
//
// `head` is everything already read off the socket. recv_more reads further bytes for
// request bodies that had not fully arrived; it is transport-specific, so the caller
// supplies it and this proc stays common to both listeners.
//
// After the request is on the wire this returns. The socket is NOT closed here: it
// stays registered so proxy_data can stream the response to it, and teardown happens on
// proxy_close (or when the caller's reader sees the client vanish).
bridge_proxy_serve_client :: proc(
	head: string,
	kind: Bridge_Wrapper_Push_Conn_Kind,
	tcp: net.TCP_Socket,
	unix: local_socket.Socket,
	recv_more: proc(rawptr, []byte) -> int,
	recv_ctx: rawptr,
) -> (string, bool) {
	heap := runtime.heap_allocator()

	req := bridge_proxy_parse_request(head, heap)
	defer if req.ok {
		delete(req.method, heap); delete(req.session_id, heap); delete(req.path, heap)
		delete(req.query, heap); delete(req.header_block, heap)
	}
	if !req.ok {
		bridge_proxy_write_local_error(kind, tcp, unix, 400, "bad proxy request line")
		return "", false
	}

	proxy_id := bridge_proxy_new_id()

	stream := new(Bridge_Proxy_Stream, heap)
	stream.proxy_id = strings.clone(proxy_id, heap)
	stream.kind = kind
	stream.tcp = tcp
	stream.unix = unix
	stream.closed = false
	bridge_proxy_register(stream)

	bridge_proxy_enqueue(bridge_proxy_open_frame(proxy_id, req))

	// Forward the request body, if any. Whatever arrived with the head is already in
	// hand; the rest is read up to Content-Length.
	if req.content_len > 0 {
		body_start := 0
		if he := strings.index(head, "\r\n\r\n"); he >= 0 do body_start = he + 4
		have := head[body_start:]
		sent := 0
		if len(have) > 0 {
			chunk := transmute([]byte)have
			if len(chunk) > req.content_len do chunk = chunk[:req.content_len]
			sent = len(chunk)
			bridge_proxy_enqueue(bridge_proxy_data_frame(proxy_id, chunk, sent >= req.content_len))
		}
		buf: [8192]byte
		for sent < req.content_len {
			n := recv_more(recv_ctx, buf[:])
			if n <= 0 do break
			take := n
			if sent + take > req.content_len do take = req.content_len - sent
			sent += take
			bridge_proxy_enqueue(bridge_proxy_data_frame(proxy_id, buf[:take], sent >= req.content_len))
		}
	}

	return strings.clone(proxy_id, heap), true
}

// bridge_proxy_write_local_error answers the local caller directly. Used only for
// requests the bridge rejects before anything reaches the hub.
bridge_proxy_write_local_error :: proc(kind: Bridge_Wrapper_Push_Conn_Kind, tcp: net.TCP_Socket, unix: local_socket.Socket, status: int, message: string) {
	heap := runtime.heap_allocator()
	b := strings.builder_make(heap)
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "HTTP/1.1 ")
	strings.write_int(&b, status)
	strings.write_string(&b, " ")
	strings.write_string(&b, status == 400 ? "Bad Request" : "Forbidden")
	strings.write_string(&b, "\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: ")
	body := strings.concatenate({"{\"error\":\"", message, "\"}"}, heap)
	defer delete(body, heap)
	strings.write_int(&b, len(body))
	strings.write_string(&b, "\r\n\r\n")
	strings.write_string(&b, body)
	payload := transmute([]byte)strings.to_string(b)
	switch kind {
	case .TCP:
		_, _ = net.send_tcp(tcp, payload)
	case .Unix:
		_ = local_socket.send(unix, payload)
	}
}

// bridge_proxy_seq disambiguates ids allocated within the same nanosecond. The hub's
// preview path derives stream ids from the clock alone, which is safe there because a
// single hub allocates them; here several local callers can hit one bridge at once, so
// the clock alone is not sufficiently unique.
bridge_proxy_seq: u64

bridge_proxy_new_id :: proc() -> string {
	heap := runtime.heap_allocator()
	n := sync.atomic_add(&bridge_proxy_seq, 1)
	b := strings.builder_make(heap)
	strings.write_string(&b, "px_")
	strings.write_int(&b, int(time.to_unix_nanoseconds(time.now())), 16)
	strings.write_string(&b, "_")
	strings.write_u64(&b, n, 16)
	return strings.to_string(b)
}

// ---- transport-specific entry points ----
//
// Each wrapper serves the request, then stays on the socket as the client→hub
// direction: when the local client goes away the whole chain must come down
// (proxy_close → hub → tunnel_close → target bridge closes its loopback TCP), so a
// disconnected client cannot leak a stream on the hub or a socket on the far bridge.

// BRIDGE_PROXY_MAX_HEAD caps how much request head the bridge will buffer while
// looking for the CRLFCRLF terminator, so a local caller that never sends one cannot
// grow this buffer without bound.
BRIDGE_PROXY_MAX_HEAD :: 64 * 1024

// bridge_proxy_read_head keeps reading until the full request head (request line +
// headers + blank line) is in hand.
//
// The HTTP sniff fires as soon as the FIRST line is complete, but headers can arrive
// across several reads — so parsing at sniff time would silently drop headers, and with
// them Content-Length, whenever the request fragmented. Loopback requests usually land
// in one segment, which is exactly why this would have been an intermittent bug rather
// than an obvious one. The returned string is heap-owned by the caller.
bridge_proxy_read_head :: proc(initial: string, recv_more: proc(rawptr, []byte) -> int, recv_ctx: rawptr) -> (string, bool) {
	heap := runtime.heap_allocator()
	acc := strings.clone(initial, heap)
	for strings.index(acc, "\r\n\r\n") < 0 {
		if len(acc) > BRIDGE_PROXY_MAX_HEAD {
			delete(acc, heap)
			return "", false
		}
		buf: [4096]byte
		n := recv_more(recv_ctx, buf[:])
		if n <= 0 {
			delete(acc, heap)
			return "", false
		}
		grown := strings.concatenate({acc, string(buf[:n])}, heap)
		delete(acc, heap)
		acc = grown
	}
	return acc, true
}

Bridge_Proxy_Tcp_Ctx :: struct { sock: net.TCP_Socket }
Bridge_Proxy_Unix_Ctx :: struct { fd: local_socket.Socket }

bridge_proxy_recv_tcp :: proc(ctx: rawptr, buf: []byte) -> int {
	c := (^Bridge_Proxy_Tcp_Ctx)(ctx)
	n, err := net.recv_tcp(c.sock, buf)
	if err != nil do return -1
	return n
}

bridge_proxy_recv_unix :: proc(ctx: rawptr, buf: []byte) -> int {
	c := (^Bridge_Proxy_Unix_Ctx)(ctx)
	n := local_socket.recv(c.fd, buf)
	if n <= 0 do return -1
	return n
}

bridge_local_proxy_serve_tcp :: proc(client: net.TCP_Socket, head_in: string) {
	heap := runtime.heap_allocator()
	ctx := Bridge_Proxy_Tcp_Ctx{sock = client}
	head, head_ok := bridge_proxy_read_head(head_in, bridge_proxy_recv_tcp, rawptr(&ctx))
	defer delete(head, heap)
	if !head_ok {
		bridge_proxy_write_local_error(.TCP, client, local_socket.INVALID_SOCKET, 400, "incomplete or oversized request head")
		net.close(client)
		return
	}
	proxy_id, ok := bridge_proxy_serve_client(head, .TCP, client, local_socket.INVALID_SOCKET, bridge_proxy_recv_tcp, rawptr(&ctx))
	if !ok {
		net.close(client)
		return
	}
	defer delete(proxy_id, heap)

	// THE FD: this proc owns `client` and is its only closer, on every path.  Registered
	// above, so bridge_hub_handle_proxy_close may now wake us at any moment — it shuts the
	// receive side down and never closes, so the recv below cannot be reading a freed fd.
	defer net.close(client)

	// Backstop wake, for a teardown path that ever forgets the shutdown.
	_ = net.set_option(client, .Receive_Timeout, BRIDGE_PROXY_RECV_TIMEOUT)

	// Client→hub watch: block until the local caller disconnects.
	buf: [4096]byte
	for {
		if sync.atomic_load(&bridge_hub_traffic_stopped) do break
		n, err := net.recv_tcp(client, buf[:])
		// A timeout is a periodic wake, not a disconnect: core:net reports a graceful
		// close as (0, nil), so `n <= 0` alone cannot tell them apart.
		if err == .Timeout || err == .Would_Block {
			if !bridge_proxy_stream_registered(proxy_id) do break
			continue
		}
		if err != nil || n <= 0 do break
	}
	bridge_proxy_finish_local(proxy_id)
}

bridge_local_proxy_serve_unix :: proc(client: local_socket.Socket, head_in: string) {
	heap := runtime.heap_allocator()
	ctx := Bridge_Proxy_Unix_Ctx{fd = client}
	head, head_ok := bridge_proxy_read_head(head_in, bridge_proxy_recv_unix, rawptr(&ctx))
	defer delete(head, heap)
	if !head_ok {
		bridge_proxy_write_local_error(.Unix, net.TCP_Socket(0), client, 400, "incomplete or oversized request head")
		local_socket.close(client)
		return
	}
	proxy_id, ok := bridge_proxy_serve_client(head, .Unix, net.TCP_Socket(0), client, bridge_proxy_recv_unix, rawptr(&ctx))
	if !ok {
		local_socket.close(client)
		return
	}
	defer delete(proxy_id, heap)

	// THE FD: same rule as the TCP transport above — this proc is the only closer.
	defer local_socket.close(client)

	// Backstop wake: a timeout surfaces as .Would_Block, which the loop must not read
	// as a close.
	_ = local_socket.set_recv_timeout(client, BRIDGE_PROXY_RECV_TIMEOUT)

	buf: [4096]byte
	for {
		if sync.atomic_load(&bridge_hub_traffic_stopped) do break
		n, err := local_socket.recv_ex(client, buf[:])
		if err == .Would_Block {
			if !bridge_proxy_stream_registered(proxy_id) do break
			continue
		}
		if err == .Interrupted do continue
		if err != .None || n == 0 do break
	}
	bridge_proxy_finish_local(proxy_id)
}

// bridge_proxy_finish_local runs when the LOCAL client end is done. If this caller is
// the one that removed the stream it tells the hub to tear the far end down; if the
// hub's proxy_close got there first the stream is already gone and there is nothing
// to announce.
//
// It does NOT touch the fd, in either branch.  The caller owns the client socket and
// closes it unconditionally after this returns — precisely because this proc returns
// early when it loses the key race, and an fd closed only on the winning branch is an
// fd leaked on the losing one.
bridge_proxy_finish_local :: proc(proxy_id: string) {
	stream, removed := bridge_proxy_take(proxy_id)
	if !removed do return
	bridge_proxy_enqueue(bridge_proxy_close_frame(proxy_id, "client_disconnect"))
	bridge_proxy_free(stream)
}
