package httpc

// End to end over real TLS for the libcurl WebSocket transport every wss://
// connection uses (src/lib/ws): socat terminates TLS with a throwaway
// certificate for localhost and forwards to a small in-process WebSocket echo
// server. Trust goes in through _test_ca_file (tests run in parallel and must not
// set HAM_TLS_CA_FILE). Fails when openssl/socat are not on PATH (they are in
// `nix develop`).

import "base:runtime"
import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

WS_TEST_GUID :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

Ws_Echo_Server :: struct {
	listener:  net.TCP_Socket,
	port:      int,
	worker:    ^thread.Thread,
	stopping:  bool,
	mu:        sync.Mutex,
	// The upgrade request target and Authorization header of the last client
	// (runtime heap).
	target:    string,
	auth:      string,
}

Wss_Fixture :: struct {
	dir:    string,
	cert:   string,
	port:   int, // TLS port (socat)
	socat:  os.Process,
	echo:   ^Ws_Echo_Server,
}

@(private = "file")
ws_test_must_init :: proc(t: ^testing.T) -> bool {
	ok, msg := init()
	return testing.expectf(t, ok, "init failed: %s", msg)
}

@(private = "file")
ws_test_tool_present :: proc(name: string) -> bool {
	state, _, _, err := os.process_exec(os.Process_Desc{command = []string{"sh", "-c", fmt.tprintf("command -v %s", name)}}, context.temp_allocator)
	return err == nil && state.exited && state.success
}

@(private = "file")
ws_test_tmp_dir :: proc(name: string) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	dir := fmt.aprintf("%s/.cache/heimdall-tests/httpc-%s-%d", home, name, time.to_unix_nanoseconds(time.now()), allocator = runtime.heap_allocator())
	_ = os.make_directory_all(dir)
	return dir
}

ws_test_read_exact :: proc(sock: net.TCP_Socket, out: []byte) -> bool {
	got := 0
	for got < len(out) {
		n, err := net.recv_tcp(sock, out[got:])
		if err != nil || n <= 0 do return false
		got += n
	}
	return true
}

ws_test_write_frame :: proc(sock: net.TCP_Socket, fin: bool, opcode: u8, payload: []byte) -> bool {
	header: [10]byte
	header[0] = (0x80 if fin else 0) | opcode
	n := 2
	switch {
	case len(payload) < 126:
		header[1] = u8(len(payload))
	case len(payload) <= 0xFFFF:
		header[1] = 126
		header[2] = u8(len(payload) >> 8)
		header[3] = u8(len(payload))
		n = 4
	case:
		header[1] = 127
		for i in 0..<8 do header[2+i] = u8(u64(len(payload)) >> uint(56 - 8*i))
		n = 10
	}
	if _, err := net.send_tcp(sock, header[:n]); err != nil do return false
	if len(payload) > 0 {
		if _, err := net.send_tcp(sock, payload); err != nil do return false
	}
	return true
}

// ws_test_serve handles one client: the HTTP upgrade, then echoes each message
// with its opcode. The message "FRAG" is answered as one text message split
// into three frames ("ab", "cd", "ef"), to exercise continuation frames.
ws_test_serve :: proc(s: ^Ws_Echo_Server, sock: net.TCP_Socket) {
	context.allocator = runtime.heap_allocator()
	request := make([dynamic]byte)
	defer delete(request)
	buf: [4096]byte
	for !strings.contains(string(request[:]), "\r\n\r\n") {
		n, err := net.recv_tcp(sock, buf[:])
		if err != nil || n <= 0 do return
		append(&request, ..buf[:n])
	}
	key, target, auth: string
	head := string(request[:])
	for line, i in strings.split_lines(head, context.temp_allocator) {
		if i == 0 {
			parts := strings.split(line, " ", context.temp_allocator)
			if len(parts) >= 2 do target = parts[1]
			continue
		}
		colon := strings.index(line, ":")
		if colon < 0 do continue
		name := strings.to_lower(strings.trim_space(line[:colon]), context.temp_allocator)
		value := strings.trim_space(line[colon+1:])
		switch name {
		case "sec-websocket-key": key = value
		case "authorization": auth = value
		}
	}
	sync.mutex_lock(&s.mu)
	delete(s.target); delete(s.auth)
	s.target = strings.clone(target)
	s.auth = strings.clone(auth)
	sync.mutex_unlock(&s.mu)

	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]byte)strings.concatenate({key, WS_TEST_GUID}, context.temp_allocator))
	digest: [sha1.DIGEST_SIZE]byte
	sha1.final(&ctx, digest[:])
	accept := base64.encode(digest[:], allocator = context.temp_allocator)
	reply := fmt.tprintf("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", accept)
	if _, err := net.send_tcp(sock, transmute([]byte)reply); err != nil do return

	message := make([dynamic]byte)
	defer delete(message)
	message_opcode: u8
	for {
		hdr: [2]byte
		if !ws_test_read_exact(sock, hdr[:]) do return
		fin := hdr[0] & 0x80 != 0
		opcode := hdr[0] & 0x0F
		length := u64(hdr[1] & 0x7F)
		if length == 126 {
			ext: [2]byte
			if !ws_test_read_exact(sock, ext[:]) do return
			length = u64(ext[0]) << 8 | u64(ext[1])
		} else if length == 127 {
			ext: [8]byte
			if !ws_test_read_exact(sock, ext[:]) do return
			length = 0
			for b in ext do length = length << 8 | u64(b)
		}
		mask: [4]byte
		if hdr[1] & 0x80 == 0 || !ws_test_read_exact(sock, mask[:]) do return // clients must mask
		payload := make([]byte, int(length))
		defer delete(payload)
		if !ws_test_read_exact(sock, payload) do return
		for i in 0..<len(payload) do payload[i] ~= mask[i % 4]
		switch opcode {
		case 0x8:
			_ = ws_test_write_frame(sock, true, 0x8, payload)
			return
		case 0x9:
			_ = ws_test_write_frame(sock, true, 0xA, payload)
			continue
		case 0xA:
			continue
		case 0x1, 0x2:
			clear(&message)
			message_opcode = opcode
		}
		append(&message, ..payload)
		if !fin do continue
		if message_opcode == 0x1 && string(message[:]) == "FRAG" {
			if !ws_test_write_frame(sock, false, 0x1, transmute([]byte)string("ab")) do return
			if !ws_test_write_frame(sock, false, 0x0, transmute([]byte)string("cd")) do return
			if !ws_test_write_frame(sock, true, 0x0, transmute([]byte)string("ef")) do return
		} else if !ws_test_write_frame(sock, true, message_opcode, message[:]) {
			return
		}
	}
}

ws_test_accept_loop :: proc(data: rawptr) {
	s := (^Ws_Echo_Server)(data)
	for {
		client, _, err := net.accept_tcp(s.listener)
		if err != nil do return
		// wss_fixture_stop dials in to wake this accept (closing the listener
		// does not interrupt a blocked accept on Linux).
		if sync.atomic_load(&s.stopping) { net.close(client); return }
		ws_test_serve(s, client)
		net.close(client)
	}
}

wss_fixture_start :: proc(t: ^testing.T, name: string) -> (f: Wss_Fixture, ok: bool) {
	if !ws_test_must_init(t) do return
	if !ws_test_tool_present("openssl") || !ws_test_tool_present("socat") {
		testing.fail_now(t, "openssl and socat are required (run inside nix develop)")
	}
	f.dir = ws_test_tmp_dir(name)
	f.cert = fmt.aprintf("%s/cert.pem", f.dir, allocator = runtime.heap_allocator())
	key := fmt.tprintf("%s/key.pem", f.dir)
	gen, _, _, gen_err := os.process_exec(os.Process_Desc{command = []string{
		"openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", f.cert,
		"-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
	}}, context.temp_allocator)
	if !testing.expect(t, gen_err == nil && gen.exited && gen.success, "test certificate generated") do return

	f.echo = new(Ws_Echo_Server, runtime.heap_allocator())
	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if !testing.expect(t, lerr == nil, "echo server listens") do return
	bound, _ := net.bound_endpoint(listener)
	f.echo.listener = listener
	f.echo.port = bound.port
	f.echo.worker = thread.create_and_start_with_data(f.echo, ws_test_accept_loop)

	probe, _ := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	tls_bound, _ := net.bound_endpoint(probe)
	net.close(probe)
	f.port = tls_bound.port
	process, serr := os.process_start(os.Process_Desc{command = []string{
		"socat", fmt.tprintf("OPENSSL-LISTEN:%d,bind=127.0.0.1,reuseaddr,fork,cert=%s,key=%s,verify=0", f.port, f.cert, key),
		fmt.tprintf("TCP:127.0.0.1:%d", f.echo.port),
	}})
	if !testing.expect(t, serr == nil, "socat TLS terminator starts") do return
	f.socat = process
	for _ in 0..<100 {
		sock, derr := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = f.port})
		if derr == nil { net.close(sock); break }
		time.sleep(20 * time.Millisecond)
	}
	return f, true
}

wss_fixture_stop :: proc(f: ^Wss_Fixture) {
	if f.socat.pid != 0 {
		_ = os.process_kill(f.socat)
		_, _ = os.process_wait(f.socat)
	}
	if f.echo != nil {
		sync.atomic_store(&f.echo.stopping, true)
		if sock, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = f.echo.port}); err == nil do net.close(sock)
		if f.echo.worker != nil {
			thread.join(f.echo.worker)
			thread.destroy(f.echo.worker)
		}
		net.close(f.echo.listener)
		delete(f.echo.target, runtime.heap_allocator())
		delete(f.echo.auth, runtime.heap_allocator())
		free(f.echo, runtime.heap_allocator())
	}
	if f.dir != "" do _ = os.remove_all(f.dir)
	delete(f.cert, runtime.heap_allocator())
	delete(f.dir, runtime.heap_allocator())
}

// ws_test_receive reads one whole message (all frames), skipping control frames.
ws_test_receive :: proc(ws: ^WebSocket, deadline: time.Duration) -> (kind: WebSocket_Frame_Kind, data: [dynamic]byte, frames: int, ok: bool) {
	data = make([dynamic]byte)
	buf := make([]byte, 65536)
	defer delete(buf)
	started := time.tick_now()
	for time.tick_since(started) < deadline {
		n, chunk, rok := websocket_receive(ws, buf)
		if !rok do return
		switch chunk.kind {
		case .Again:
			time.sleep(time.Millisecond)
			continue
		case .Ping, .Pong:
			continue
		case .Close:
			return
		case .Text, .Binary:
		}
		kind = chunk.kind
		append(&data, ..buf[:n])
		if chunk.bytes_left == 0 {
			frames += 1
			if !chunk.continuation do return kind, data, frames, true
		}
	}
	return
}

@(test)
websocket_wss_echoes_with_bearer_over_verified_tls :: proc(t: ^testing.T) {
	f, ok := wss_fixture_start(t, "wss-echo")
	defer wss_fixture_stop(&f)
	if !ok do return
	ws, err, detail := websocket_connect(fmt.tprintf("wss://localhost:%d/api/v1/bridge/ws?ticket=t1", f.port), "tok-123", 5000, _test_ca_file = f.cert)
	if !testing.expectf(t, err == .None, "connect: %v %s", err, detail) do return
	defer websocket_close(&ws)

	testing.expect(t, websocket_send(&ws, transmute([]byte)string("hello over wss")), "send")
	kind, data, _, rok := ws_test_receive(&ws, 5 * time.Second)
	defer delete(data)
	testing.expect(t, rok, "receive")
	testing.expect_value(t, kind, WebSocket_Frame_Kind.Text)
	testing.expect_value(t, string(data[:]), "hello over wss")

	sync.mutex_lock(&f.echo.mu)
	defer sync.mutex_unlock(&f.echo.mu)
	testing.expect_value(t, f.echo.target, "/api/v1/bridge/ws?ticket=t1")
	testing.expect_value(t, f.echo.auth, "Bearer tok-123")
}

@(test)
websocket_wss_round_trips_a_large_binary_message :: proc(t: ^testing.T) {
	f, ok := wss_fixture_start(t, "wss-large")
	defer wss_fixture_stop(&f)
	if !ok do return
	ws, err, detail := websocket_connect(fmt.tprintf("wss://localhost:%d/ws", f.port), "", 5000, _test_ca_file = f.cert)
	if !testing.expectf(t, err == .None, "connect: %v %s", err, detail) do return
	defer websocket_close(&ws)

	// 1 MiB: many TLS records, so curl_ws_send must make partial progress and
	// curl_ws_recv must report bytes_left across reads.
	payload := make([]byte, 1 << 20)
	defer delete(payload)
	for i in 0..<len(payload) do payload[i] = byte(i * 31 + 7)
	testing.expect(t, websocket_send(&ws, payload, binary = true, timeout = 20 * time.Second), "send 1 MiB")
	kind, data, _, rok := ws_test_receive(&ws, 20 * time.Second)
	defer delete(data)
	testing.expect(t, rok, "receive 1 MiB")
	testing.expect_value(t, kind, WebSocket_Frame_Kind.Binary)
	testing.expect_value(t, len(data), len(payload))
	testing.expect(t, rok && string(data[:]) == string(payload), "payload intact")
}

@(test)
websocket_wss_reassembles_a_fragmented_message :: proc(t: ^testing.T) {
	f, ok := wss_fixture_start(t, "wss-frag")
	defer wss_fixture_stop(&f)
	if !ok do return
	ws, err, detail := websocket_connect(fmt.tprintf("wss://localhost:%d/ws", f.port), "", 5000, _test_ca_file = f.cert)
	if !testing.expectf(t, err == .None, "connect: %v %s", err, detail) do return
	defer websocket_close(&ws)

	testing.expect(t, websocket_send(&ws, transmute([]byte)string("FRAG")), "send")
	kind, data, frames, rok := ws_test_receive(&ws, 5 * time.Second)
	defer delete(data)
	testing.expect(t, rok, "receive")
	// Continuation frames keep the message type, and only the last ends it.
	testing.expect_value(t, kind, WebSocket_Frame_Kind.Text)
	testing.expect_value(t, frames, 3)
	testing.expect_value(t, string(data[:]), "abcdef")
}

@(test)
websocket_wss_refuses_hostname_mismatch_and_untrusted_ca :: proc(t: ^testing.T) {
	f, ok := wss_fixture_start(t, "wss-verify")
	defer wss_fixture_stop(&f)
	if !ok do return
	// The certificate names localhost only.
	ws1, err1, _ := websocket_connect(fmt.tprintf("wss://127.0.0.1:%d/ws", f.port), "", 5000, _test_ca_file = f.cert)
	if err1 == .None do websocket_close(&ws1)
	testing.expectf(t, err1 == .Certificate, "IP not in the certificate: %v", err1)
	// Not in the system trust store.
	ws2, err2, _ := websocket_connect(fmt.tprintf("wss://localhost:%d/ws", f.port), "", 5000)
	if err2 == .None do websocket_close(&ws2)
	testing.expectf(t, err2 == .Certificate, "untrusted certificate: %v", err2)
}
