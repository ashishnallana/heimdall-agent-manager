package ws

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import httpc "odin_test:lib/httpc"
import tls "../tls_stream"

WS_KEY :: "dGhlIHNhbXBsZSBub25jZQ=="

Connection :: struct {
	socket: net.TCP_Socket,
	secure: bool,
	// Production wss:// uses the pinned libcurl WebSocket/TLS stack. tls remains
	// only as a compatibility seam for focused transport tests that construct a
	// Connection directly; connect() never selects the subprocess relay.
	curl_secure: bool,
	curl_ws: httpc.WebSocket,
	tls: tls.Stream,
	connected: bool,
	// Optional owner-level outbound fence. Atomic and monotonic for this connection.
	// A writer already in transport I/O may finish; queued writers must refuse.
	send_disabled: ^bool,
	pending_texts: [dynamic]string,
	// Opcode (0x1 text / 0x2 binary) of each pending_texts entry, same index.
	pending_opcodes: [dynamic]u8,
	pending_bytes: [dynamic]byte,
	fragmented:    [dynamic]byte,
	fragmenting:   bool,
	fragmented_opcode: u8,
	curl_message: [dynamic]byte,
	curl_message_opcode: u8,

	// REQ-SHELL-32: serialises WRITES on this connection. It lives here, with the
	// socket it protects, rather than at a caller, because caller-side discipline is
	// exactly what failed: the bridge added a send mutex inside bridge_hub_send
	// (src/bridge/main.odin) for its background PTY stream threads, but the
	// hub-runtime loop thread kept calling send_text directly
	// (hub_runtime_client.odin:252/281/3391/3412). A lock only one party takes
	// serialises nothing, so a loop-thread heartbeat could land its bytes inside a
	// stream worker's half-written frame and desync the peer's WS reader.
	//
	// Guarding the write here cannot be bypassed by a future caller. Note the mutex
	// is zero-valued and Connection is returned BY VALUE from connect() — copying an
	// unlocked mutex is fine; do not copy a Connection once writers are running.
	send_mu: sync.Mutex,
}

connect :: proc(ws_url: string) -> (Connection, bool) {
	return connect_with_bearer(ws_url, "")
}

connect_with_bearer :: proc(ws_url, bearer_token: string) -> (Connection, bool) {
	host, port, path, secure, ok := parse_ws_url(ws_url)
	if !ok do return {}, false
	if secure do return connect_tls_with_bearer(ws_url, bearer_token)

	socket, err := net.dial_tcp_from_hostname_with_port_override(host, int(port))
	if err != nil do return {}, false

	auth_header := ""
	if strings.trim_space(bearer_token) != "" {
		auth_header = fmt.tprintf("Authorization: Bearer %s\r\n", bearer_token)
	}
	request := fmt.tprintf(
		"GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n%s\r\n",
		path,
		host,
		port,
		WS_KEY,
		auth_header,
	)
	_, send_err := net.send_tcp(socket, transmute([]byte)request)
	if send_err != nil {
		net.close(socket)
		return {}, false
	}

	buf: [4096]byte
	n, recv_err := net.recv_tcp(socket, buf[:])
	if recv_err != nil || n <= 0 {
		net.close(socket)
		return {}, false
	}

	response := string(buf[:n])
	if !(strings.has_prefix(response, "HTTP/1.1 101") || strings.has_prefix(response, "HTTP/1.0 101")) {
		net.close(socket)
		return {}, false
	}

	pending_bytes := make([dynamic]byte)
	if header_end := strings.index(response, "\r\n\r\n"); header_end >= 0 {
		extra_start := header_end + 4
		if extra_start < n do append(&pending_bytes, ..buf[extra_start:n])
	}
	_ = net.set_blocking(socket, false)
	return Connection{socket = socket, secure = false, connected = true, pending_texts = make([dynamic]string), pending_bytes = pending_bytes}, true
}

// WS_HANDSHAKE_DEADLINE_DEFAULT bounds the whole TLS WebSocket connect: socat
// spawn, DNS, TCP, TLS handshake and the HTTP 101 reply. It used to be a
// hard-coded 5 s while plain HTTP requests get 20 s (httpc
// DEFAULT_TIMEOUT_MS); on a phone network that gap made enrollment succeed and
// the follow-on WebSocket fail every time. Override: HAM_WS_HANDSHAKE_TIMEOUT_MS.
WS_HANDSHAKE_DEADLINE_DEFAULT :: 20 * time.Second

handshake_deadline :: proc() -> time.Duration {
	raw := strings.trim_space(os.get_env("HAM_WS_HANDSHAKE_TIMEOUT_MS", context.temp_allocator))
	return handshake_deadline_from(raw)
}

handshake_deadline_from :: proc(raw: string) -> time.Duration {
	if raw == "" do return WS_HANDSHAKE_DEADLINE_DEFAULT
	ms, ok := strconv.parse_int(raw)
	if !ok || ms <= 0 do return WS_HANDSHAKE_DEADLINE_DEFAULT
	return time.Duration(ms) * time.Millisecond
}

// last_connect_error is the reason the most recent TLS connect failed, for the
// caller's log line: "timed out" and "rejected: <status line>" are different
// problems and the generic "cannot connect" message hid which one it was.
_last_connect_error: string
_last_connect_error_mu: sync.Mutex

set_last_connect_error :: proc(reason: string) {
	sync.mutex_lock(&_last_connect_error_mu)
	defer sync.mutex_unlock(&_last_connect_error_mu)
	if len(_last_connect_error) > 0 do delete(_last_connect_error)
	_last_connect_error = strings.clone(reason)
}

last_connect_error :: proc(allocator := context.temp_allocator) -> string {
	sync.mutex_lock(&_last_connect_error_mu)
	defer sync.mutex_unlock(&_last_connect_error_mu)
	return strings.clone(_last_connect_error, allocator)
}

handshake_failure_reason :: proc(response: string, timed_out: bool, deadline: time.Duration, host: string, port: u16, allocator := context.temp_allocator) -> string {
	if len(strings.trim_space(response)) == 0 {
		if timed_out do return fmt.aprintf("handshake timed out after %v with no response from %s:%d (DNS, TCP, TLS or upgrade did not complete; raise HAM_WS_HANDSHAKE_TIMEOUT_MS if the link is slow)", deadline, host, port, allocator = allocator)
		return fmt.aprintf("TLS relay closed before any handshake response from %s:%d (TLS verification or connection failure)", host, port, allocator = allocator)
	}
	line := response
	if nl := strings.index(line, "\r\n"); nl >= 0 do line = line[:nl]
	if len(line) > 120 do line = line[:120]
	return fmt.aprintf("handshake rejected by %s:%d: %s", host, port, line, allocator = allocator)
}

connect_tls_with_bearer :: proc(ws_url, bearer_token: string) -> (Connection, bool) {
	budget := handshake_deadline()
	stream, err, detail := httpc.websocket_connect(ws_url, strings.trim_space(bearer_token), int(budget / time.Millisecond))
	if err != .None {
		set_last_connect_error(fmt.tprintf("libcurl WebSocket %s: %s", httpc.error_string(err), detail))
		return {}, false
	}
	return Connection{
		secure = true,
		curl_secure = true,
		curl_ws = stream,
		connected = true,
		pending_texts = make([dynamic]string),
		pending_bytes = make([dynamic]byte),
		curl_message = make([dynamic]byte),
	}, true
}

close :: proc(conn: ^Connection) {
	sync.mutex_lock(&conn.send_mu)
	defer sync.mutex_unlock(&conn.send_mu)
	for s in conn.pending_texts do delete(s)
	delete(conn.pending_texts)
	conn.pending_texts = nil
	delete(conn.pending_opcodes)
	conn.pending_opcodes = nil
	delete(conn.pending_bytes)
	conn.pending_bytes = nil
	delete(conn.fragmented)
	conn.fragmented = nil
	conn.fragmenting = false
	delete(conn.curl_message)
	conn.curl_message = nil

	if conn.secure || conn.socket != 0 {
		if conn.secure {
			if conn.curl_secure do httpc.websocket_close(&conn.curl_ws)
			else do tls.close(&conn.tls)
		} else {
			net.close(conn.socket)
		}
		conn.connected = false
		conn.socket = 0
		conn.secure = false
		conn.curl_secure = false
		conn.curl_ws = {}
		conn.tls = {}
	}
}

// poll_text returns the next complete TEXT or BINARY message as a string. Use poll_frame
// when the opcode matters (the bridge's hub loop does: binary frames are PTY input).
poll_text :: proc(conn: ^Connection) -> (text: string, ok: bool) {
	text, _, ok = poll_frame(conn)
	return text, ok
}

// poll_frame returns the next complete data message and its opcode (0x1 text, 0x2 binary).
// Binary payloads are returned as a string over the raw bytes — the caller transmutes.
poll_frame :: proc(conn: ^Connection) -> (text: string, opcode: u8, ok: bool) {
	if conn.send_disabled != nil && sync.atomic_load(conn.send_disabled) do return "", 0, false
	if !conn.connected do return "", 0, false
	if len(conn.pending_texts) > 0 {
		text = conn.pending_texts[0]
		opcode = conn.pending_opcodes[0] if len(conn.pending_opcodes) > 0 else 0x1
		ordered_remove(&conn.pending_texts, 0)
		if len(conn.pending_opcodes) > 0 do ordered_remove(&conn.pending_opcodes, 0)
		return text, opcode, true
	}

	buf: [131072]byte
	n := 0
	if conn.curl_secure {
		for control_count := 0; control_count < 16; control_count += 1 {
			if conn.send_disabled != nil && sync.atomic_load(conn.send_disabled) do return "", 0, false
			read_n, chunk, read_ok := httpc.websocket_receive(&conn.curl_ws, buf[:])
			if !read_ok {
				conn.connected = false
				return "", 0, false
			}
			if chunk.kind == .Again do return "", 0, false
			if chunk.kind == .Close {
				conn.connected = false
				return "", 0, false
			}
			if chunk.kind == .Ping || chunk.kind == .Pong do continue
			if len(conn.curl_message) + read_n > WS_CONTINUATION_DEFAULT_MAX_BYTES {
				conn.connected = false
				return "", 0, false
			}
			op := u8(0x2) if chunk.kind == .Binary else u8(0x1)
			if len(conn.curl_message) == 0 do conn.curl_message_opcode = op
			else if conn.curl_message_opcode != op {
				conn.connected = false
				return "", 0, false
			}
			if read_n > 0 do append(&conn.curl_message, ..buf[:read_n])
			if chunk.bytes_left > 0 || chunk.continuation do return "", 0, false
			result := strings.clone(string(conn.curl_message[:]))
			result_opcode := conn.curl_message_opcode
			clear(&conn.curl_message)
			conn.curl_message_opcode = 0
			return result, result_opcode, true
		}
		return "", 0, false
	} else if conn.secure {
		if ready, has_ok := tls.has_data(&conn.tls); !has_ok {
			conn.connected = false
			return "", 0, false
		} else if !ready {
			return "", 0, false
		}
		read_n, read_ok := tls.read(&conn.tls, buf[:])
		if !read_ok || read_n <= 0 {
			conn.connected = false
			return "", 0, false
		}
		n = read_n
	} else {
		read_n, err := net.recv_tcp(conn.socket, buf[:])
		if err != nil {
			if err == .Would_Block do return "", 0, false
			conn.connected = false
			return "", 0, false
		}
		if read_n == 0 {
			conn.connected = false
			return "", 0, false
		}
		n = read_n
	}
	append(&conn.pending_bytes, ..buf[:n])

	first_text := ""
	first_opcode: u8 = 0x1
	for {
		opcode, fin, payload, has_frame, ok := take_one_frame_from_pending(
			&conn.pending_bytes,
			allow_64bit = true,
			max_buffer_bytes = WS_READER_DEFAULT_MAX_BUFFER_BYTES,
		)
		if !ok {
			if first_text != "" do delete(first_text)
			conn.connected = false
			return "", 0, false
		}
		if !has_frame do break

		// Control frames ((opcode & 0x08) != 0)
		if (opcode & 0x08) != 0 {
			if !fin || len(payload) > 125 {
				delete(payload)
				if first_text != "" do delete(first_text)
				conn.connected = false
				return "", 0, false
			}
			if opcode == 0x8 {
				delete(payload)
				conn.connected = false
				return "", 0, false
			}
			if opcode == 0x9 {
				_ = send_frame(conn, 0xA, payload)
				delete(payload)
				continue
			}
			if opcode == 0xA {
				delete(payload)
				continue
			}
			delete(payload)
			if first_text != "" do delete(first_text)
			conn.connected = false
			return "", 0, false
		}

		switch opcode {
		case 0x1, 0x2:
			if conn.fragmenting {
				delete(payload)
				if first_text != "" do delete(first_text)
				conn.connected = false
				return "", 0, false
			}
			if fin {
				if first_text == "" {
					first_text = payload
					first_opcode = opcode
				} else {
					append(&conn.pending_texts, payload)
					append(&conn.pending_opcodes, opcode)
				}
			} else {
				conn.fragmenting = true
				conn.fragmented_opcode = opcode
				clear(&conn.fragmented)
				append(&conn.fragmented, ..transmute([]byte)payload)
				delete(payload)
			}
		case 0x0:
			if !conn.fragmenting {
				delete(payload)
				if first_text != "" do delete(first_text)
				conn.connected = false
				return "", 0, false
			}
			if len(conn.fragmented) + len(payload) > WS_CONTINUATION_DEFAULT_MAX_BYTES {
				delete(payload)
				if first_text != "" do delete(first_text)
				conn.connected = false
				return "", 0, false
			}
			append(&conn.fragmented, ..transmute([]byte)payload)
			delete(payload)
			if fin {
				conn.fragmenting = false
				assembled := strings.clone(string(conn.fragmented[:]))
				clear(&conn.fragmented)
				if first_text == "" {
					first_text = assembled
					first_opcode = conn.fragmented_opcode
				} else {
					append(&conn.pending_texts, assembled)
					append(&conn.pending_opcodes, conn.fragmented_opcode)
				}
			}
		case:
			delete(payload)
			if first_text != "" do delete(first_text)
			conn.connected = false
			return "", 0, false
		}
	}

	if first_text == "" do return "", 0, false
	return first_text, first_opcode, true
}

// All frames, including pong, share the connection writer and deadline.
send_text :: proc(conn: ^Connection, text: string) -> bool {
	return send_frame(conn, 0x1, text)
}

send_text_with_deadline :: proc(conn: ^Connection, text: string, timeout: time.Duration) -> bool {
	return send_frame(conn, 0x1, text, timeout)
}

// send_binary writes one BINARY (opcode 0x2) frame under the same writer lock and
// deadline as text. REQ-PTY-NET-2: pty output/input frames.
send_binary :: proc(conn: ^Connection, payload: []byte) -> bool {
	return send_frame(conn, 0x2, string(payload))
}

@(private)
send_frame :: proc(conn: ^Connection, opcode: u8, text: string, timeout: time.Duration = WRITE_DEADLINE) -> bool {
	if conn.send_disabled != nil && sync.atomic_load(conn.send_disabled) do return false
	if !conn.connected do return false
	n := len(text)
	if n > WS_MAX_SERVER_PAYLOAD do return false
	sync.mutex_lock(&conn.send_mu)
	defer sync.mutex_unlock(&conn.send_mu)
	if conn.send_disabled != nil && sync.atomic_load(conn.send_disabled) do return false
	// Re-check under the lock: a writer that blocked here may have been waiting on a
	// peer another writer has since found dead.
	if !conn.connected do return false
	if conn.curl_secure {
		ok := httpc.websocket_send(&conn.curl_ws, transmute([]byte)text, opcode == 0x2, timeout)
		if !ok {
			httpc.websocket_abort(&conn.curl_ws)
			conn.connected = false
		}
		return ok
	}
	header: [WS_MAX_HEADER_BYTES]byte
	header_len := server_frame_header_with_opcode(header[:], opcode, n)
	frame := make([]byte, header_len + n)
	// REQ-SHELL-52A: send_all_tcp/send_all_tls BORROW this slice and free nothing on any
	// exit, so without this every frame leaked header_len+len(text) bytes on the heap.
	defer delete(frame)
	copy(frame[:header_len], header[:header_len])
	copy(frame[header_len:], transmute([]byte)text)
	ok := false
	if conn.secure {
		ok = send_all_tls(&conn.tls, frame, timeout)
	} else {
		ok = send_all_tcp(conn.socket, frame, timeout)
	}
	if !ok {
		if conn.secure do tls.abort(&conn.tls)
		else do _ = net.shutdown(conn.socket, .Both)
		conn.connected = false
	}
	return ok
}

// WRITE_DEADLINE caps ONE send_text call, and therefore caps how long one stuck
// writer can hold send_mu. See the note on send_text for why an unbounded retry here
// would trade a byte-interleaving bug for a heartbeat-starvation bug.
WRITE_DEADLINE :: 5 * time.Second

// Write deadline expirations, including TLS subprocess pipes.
@(private)
_send_timeouts: u64

send_timeouts :: proc() -> u64 { return sync.atomic_load(&_send_timeouts) }

// @(private): send_text is the ONLY door to this socket, and F1's whole thesis is
// that a second unlocked door is what produced REQ-SHELL-32. Unexported so the
// bypass is unrepresentable rather than merely absent today — anything reaching a
// Connection's fd without taking send_mu reintroduces the byte-interleaving bug.
@(private)
send_all_tcp :: proc(socket: net.TCP_Socket, bytes: []byte, timeout: time.Duration = WRITE_DEADLINE) -> bool {
	_, ok := send_socket_bytes(socket, bytes, timeout)
	return ok
}

// One OS send per iteration: core:net send_tcp loops internally, which can
// extend SO_SNDTIMEO indefinitely when a peer makes tiny amounts of progress.
send_socket_bytes :: proc(socket: net.TCP_Socket, bytes: []byte, timeout: time.Duration = WRITE_DEADLINE) -> (sent: int, ok: bool) {
	if net.set_option(socket, .Send_Timeout, 50 * time.Millisecond) != nil do return 0, false
	started := time.tick_now()
	for sent < len(bytes) {
		if time.tick_since(started) >= timeout { sync.atomic_add(&_send_timeouts, 1); return sent, false }
		n, retry := socket_send_once(socket, bytes[sent:])
		if retry { time.sleep(time.Millisecond); continue }
		if n <= 0 do return sent, false
		sent += n
	}
	return sent, true
}

// A stalled TLS transport must obey the same deadline as TCP; a partial frame is
// fatal to this connection.
@(private)
send_all_tls :: proc(stream: ^tls.Stream, bytes: []byte, timeout: time.Duration = WRITE_DEADLINE) -> bool {
	switch tls.write_all(stream, bytes, timeout) {
	case .Ok:
		return true
	case .Timed_Out:
		sync.atomic_add(&_send_timeouts, 1)
	case .Failed:
	}
	return false
}

// Wake the transport reader without closing a descriptor it may still use.
abort :: proc(conn: ^Connection) {
	sync.mutex_lock(&conn.send_mu)
	defer sync.mutex_unlock(&conn.send_mu)
	if conn.curl_secure do httpc.websocket_abort(&conn.curl_ws)
	else if conn.secure do tls.abort(&conn.tls)
	else do _ = net.shutdown(conn.socket, .Both)
	conn.connected = false
}

parse_ws_url :: proc(ws_url: string) -> (host: string, port: u16, path: string, secure: bool, ok: bool) {
	url := ws_url
	default_port: u16 = 80
	if strings.has_prefix(url, "wss://") {
		url = url[len("wss://"):]
		default_port = 443
		secure = true
	} else if strings.has_prefix(url, "ws://") {
		url = url[len("ws://"):]
		default_port = 80
	}

	slash := strings.index_byte(url, '/')
	if slash < 0 do return "", 0, "", false, false

	host_port := url[:slash]
	path = url[slash:]
	colon := strings.last_index_byte(host_port, ':')
	if colon < 0 {
		host = host_port
		return host, default_port, path, secure, strings.trim_space(host) != ""
	}

	host = host_port[:colon]
	port_s := host_port[colon + 1:]
	port_i, port_ok := strconv.parse_int(port_s)
	if !port_ok do return "", 0, "", false, false

	return host, u16(port_i), path, secure, true
}
