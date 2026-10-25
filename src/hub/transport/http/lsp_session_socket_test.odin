package http

// REQ-LSP-RLY-1 acceptance tests over a REAL loopback socket.
//
// The pure tests in lsp_session_relay_test.odin cover translation and framing in
// isolation. These cover the two acceptance criteria that are only meaningful
// against an actual fd:
//
//   - a frame sent by the bridge ARRIVES at the browser socket, as bytes, framed
//     the way a browser WebSocket would accept them;
//   - a bridge disconnect mid-session WAKES the relay's parked recv and closes the
//     browser socket cleanly, without the bridge thread ever closing that fd.

import "core:net"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"

// --- loopback helpers --------------------------------------------------------

@(private = "file")
Sock_Pair :: struct {
	listener: net.TCP_Socket,
	browser:  net.TCP_Socket, // the client end, standing in for the browser
	hub:      net.TCP_Socket, // the accepted end the relay writes to
}

@(private = "file")
make_loopback_pair :: proc(t: ^testing.T) -> (Sock_Pair, bool) {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if listen_err != nil {
		testing.fail_now(t, "could not listen on loopback")
	}
	bound, bound_err := net.bound_endpoint(listener)
	if bound_err != nil {
		net.close(listener)
		testing.fail_now(t, "could not read the bound endpoint")
	}
	browser, dial_err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	if dial_err != nil {
		net.close(listener)
		testing.fail_now(t, "could not dial loopback")
	}
	hub, _, accept_err := net.accept_tcp(listener)
	if accept_err != nil {
		net.close(listener)
		net.close(browser)
		testing.fail_now(t, "could not accept on loopback")
	}
	return Sock_Pair{listener = listener, browser = browser, hub = hub}, true
}

@(private = "file")
close_pair :: proc(p: ^Sock_Pair) {
	net.close(p.hub)
	net.close(p.browser)
	net.close(p.listener)
}

// read_server_frame reads one UNMASKED server->client text frame (what the Hub
// writes to a browser) and returns its payload.
@(private = "file")
read_server_frame :: proc(sock: net.TCP_Socket, timeout: time.Duration) -> (string, bool) {
	_ = net.set_option(sock, .Receive_Timeout, timeout)
	buf: [4096]byte
	acc := make([dynamic]byte)
	defer delete(acc)
	for {
		n, err := net.recv_tcp(sock, buf[:])
		if err != nil || n <= 0 do return "", false
		append(&acc, ..buf[:n])
		b := acc[:]
		if len(b) < 2 do continue
		if b[0] != 0x81 do return "", false // FIN + text
		payload_len := int(b[1] & 0x7f)
		header_len := 2
		switch payload_len {
		case 126:
			if len(b) < 4 do continue
			payload_len = int(b[2]) << 8 | int(b[3])
			header_len = 4
		case 127:
			if len(b) < 10 do continue
			length: u64 = 0
			for i in 0 ..< 8 do length = length << 8 | u64(b[2 + i])
			payload_len = int(length)
			header_len = 10
		}
		// A server->client frame is never masked.
		if (b[1] & 0x80) != 0 do return "", false
		if len(b) < header_len + payload_len do continue
		return strings.clone(string(b[header_len:header_len + payload_len])), true
	}
}

// read_upgrade_then_frame consumes the HTTP 101 response the handler writes
// before it starts framing, then returns the first WebSocket frame after it.
// (A real browser does the same: handshake response first, frames after.)
@(private = "file")
read_upgrade_then_frame :: proc(sock: net.TCP_Socket, timeout: time.Duration) -> (string, bool) {
	_ = net.set_option(sock, .Receive_Timeout, timeout)
	buf: [4096]byte
	acc := make([dynamic]byte)
	defer delete(acc)
	header_end := -1
	for {
		n, err := net.recv_tcp(sock, buf[:])
		if err != nil || n <= 0 do return "", false
		append(&acc, ..buf[:n])
		if header_end < 0 {
			b := acc[:]
			for i in 0 ..< max(0, len(b) - 3) {
				if b[i] == '\r' && b[i + 1] == '\n' && b[i + 2] == '\r' && b[i + 3] == '\n' {
					header_end = i + 4
					break
				}
			}
			if header_end < 0 do continue
		}
		body := acc[header_end:]
		if len(body) < 2 do continue
		if body[0] != 0x81 do return "", false
		payload_len := int(body[1] & 0x7f)
		off := 2
		switch payload_len {
		case 126:
			if len(body) < 4 do continue
			payload_len = int(body[2]) << 8 | int(body[3])
			off = 4
		case 127:
			if len(body) < 10 do continue
			length: u64 = 0
			for i in 0 ..< 8 do length = length << 8 | u64(body[2 + i])
			payload_len = int(length)
			off = 10
		}
		if len(body) < off + payload_len do continue
		return strings.clone(string(body[off:off + payload_len])), true
	}
}

// --- a bridge frame reaches the browser socket -------------------------------

@(test)
test_lsp_bridge_frame_arrives_at_the_browser_socket :: proc(t: ^testing.T) {
	pair, ok := make_loopback_pair(t)
	if !ok do return
	defer close_pair(&pair)

	reg := Lsp_Session_Registry{}
	defer {
		delete(reg.by_wire)
		delete(reg.by_owner)
	}
	_, claimed := lsp_registry_claim(&reg, "user_a", "editor-1", "lsp_wire_xyz", pair.hub)
	testing.expect(t, claimed)
	defer lsp_registry_release(&reg, "lsp_wire_xyz")

	// Exactly what the bridge puts on the wire (src/bridge/lsp_session.odin
	// bridge_lsp_data_frame_json), carrying a JSON-RPC response.
	bridge_frame := "{\"type\":\"lsp_data\",\"session_id\":\"lsp_wire_xyz\",\"message\":\"{\\\"jsonrpc\\\":\\\"2.0\\\",\\\"id\\\":7,\\\"result\\\":{\\\"capabilities\\\":{}}}\"}"
	delivered := lsp_forward_bridge_frame(&reg, "lsp_data", bridge_frame)
	testing.expect(t, delivered, "the relay must report the frame as delivered")

	got, read_ok := read_server_frame(pair.browser, 3 * time.Second)
	testing.expect(t, read_ok, "the browser end must actually receive bytes")
	defer delete(got)

	testing.expect(t, strings.contains(got, "\"type\":\"lsp_data\""))
	// The browser sees the id IT chose, never the Hub's internal wire id.
	testing.expect(t, strings.contains(got, "\"session_id\":\"editor-1\""))
	testing.expect(t, !strings.contains(got, "lsp_wire_xyz"))

	// The JSON-RPC payload survives the relay byte-for-byte.
	msg := json_string(got, "message")
	defer delete(msg)
	testing.expect_value(t, msg, "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"capabilities\":{}}}")
}

@(test)
test_lsp_large_frame_arrives_whole :: proc(t: ^testing.T) {
	// A completion list or semantic-token response over 64KB. Every pre-existing
	// writer in this codebase refuses these, so this test is the reason the LSP
	// socket has its own 64-bit-length writer.
	pair, ok := make_loopback_pair(t)
	if !ok do return
	defer close_pair(&pair)

	reg := Lsp_Session_Registry{}
	defer {
		delete(reg.by_wire)
		delete(reg.by_owner)
	}
	_, claimed := lsp_registry_claim(&reg, "user_a", "s1", "w1", pair.hub)
	testing.expect(t, claimed)
	defer lsp_registry_release(&reg, "w1")

	big := strings.repeat("y", 80000)
	defer delete(big)
	bridge_frame := strings.concatenate({"{\"type\":\"lsp_data\",\"session_id\":\"w1\",\"message\":\"", big, "\"}"})
	defer delete(bridge_frame)

	delivered := lsp_forward_bridge_frame(&reg, "lsp_data", bridge_frame)
	testing.expect(t, delivered, "an 80KB frame must be delivered, not dropped")

	got, read_ok := read_server_frame(pair.browser, 5 * time.Second)
	testing.expect(t, read_ok)
	defer delete(got)
	msg := json_string(got, "message")
	defer delete(msg)
	testing.expect_value(t, len(msg), 80000)
}

// --- bridge disconnect wakes the relay and closes cleanly --------------------

@(private = "file")
Park_Data :: struct {
	reader:   Lsp_WS_Reader,
	returned: bool,
	got_ok:   bool,
}

@(private = "file")
park_in_recv :: proc(data: rawptr) {
	d := (^Park_Data)(data)
	// Parks in recv exactly as the relay loop does. shutdown(.Receive) from the
	// other thread is what must wake it.
	_, ok := lsp_read_ws_text_blocking(&d.reader, 30 * time.Second)
	d.got_ok = ok
	d.returned = true
}

@(test)
test_lsp_bridge_disconnect_wakes_the_parked_relay :: proc(t: ^testing.T) {
	pair, ok := make_loopback_pair(t)
	if !ok do return
	defer close_pair(&pair)

	reg := Lsp_Session_Registry{}
	defer {
		delete(reg.by_wire)
		delete(reg.by_owner)
	}
	_, claimed := lsp_registry_claim(&reg, "user_a", "editor-1", "w1", pair.hub)
	testing.expect(t, claimed)
	lsp_registry_mark_started(&reg, "w1", "brg_gone")

	// A relay thread parked in recv on the browser socket, as in production.
	d := new(Park_Data)
	defer free(d)
	d.reader = lsp_ws_reader_make(pair.hub)
	defer lsp_ws_reader_destroy(&d.reader)
	th := thread.create_and_start_with_data(rawptr(d), park_in_recv)
	defer thread.destroy(th)
	time.sleep(20 * time.Millisecond) // let it actually park

	testing.expect(t, !d.returned, "the relay should still be parked before the disconnect")

	// The bridge drops. This must wake the parked reader WITHOUT closing its fd.
	woken := lsp_registry_wake_bridge_sessions(&reg, "brg_gone")
	testing.expect_value(t, woken, 1)
	testing.expect(t, lsp_session_closing(&reg, "w1"), "the session must be marked closing")

	// The parked recv must return promptly (AGENTS.md measures shutdown as waking
	// it in tens of microseconds; a second is a generous bound).
	deadline := time.now()
	for !d.returned && time.duration_seconds(time.since(deadline)) < 5.0 {
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, d.returned, "shutdown(.Receive) must wake the parked relay read")
	testing.expect(t, !d.got_ok, "the woken read must report failure so the relay unwinds")

	thread.join(th)
	// The relay's own unwind releases the entry — the bridge thread never did.
	lsp_registry_release(&reg, "w1")
	testing.expect_value(t, len(reg.by_wire), 0)
}

@(test)
test_lsp_disconnect_only_touches_sessions_on_that_bridge :: proc(t: ^testing.T) {
	pair_a, ok_a := make_loopback_pair(t)
	if !ok_a do return
	defer close_pair(&pair_a)
	pair_b, ok_b := make_loopback_pair(t)
	if !ok_b do return
	defer close_pair(&pair_b)

	reg := Lsp_Session_Registry{}
	defer {
		delete(reg.by_wire)
		delete(reg.by_owner)
	}
	_, _ = lsp_registry_claim(&reg, "user_a", "s_a", "w_a", pair_a.hub)
	lsp_registry_mark_started(&reg, "w_a", "brg_one")
	_, _ = lsp_registry_claim(&reg, "user_a", "s_b", "w_b", pair_b.hub)
	lsp_registry_mark_started(&reg, "w_b", "brg_two")
	defer lsp_registry_release(&reg, "w_a")
	defer lsp_registry_release(&reg, "w_b")

	woken := lsp_registry_wake_bridge_sessions(&reg, "brg_one")
	testing.expect_value(t, woken, 1)
	testing.expect(t, lsp_session_closing(&reg, "w_a"))
	testing.expect(t, !lsp_session_closing(&reg, "w_b"), "a session on another bridge must be untouched")

	// The surviving session's socket is still usable.
	still_live := lsp_forward_bridge_frame(&reg, "lsp_stopped", "{\"session_id\":\"w_b\"}")
	testing.expect(t, still_live, "the other bridge's session must still be writable")
}

@(test)
test_lsp_disconnect_tells_the_browser_why :: proc(t: ^testing.T) {
	// The browser must learn the session died rather than just seeing silence.
	pair, ok := make_loopback_pair(t)
	if !ok do return
	defer close_pair(&pair)

	reg := Lsp_Session_Registry{}
	defer {
		delete(reg.by_wire)
		delete(reg.by_owner)
	}
	_, claimed := lsp_registry_claim(&reg, "user_a", "editor-1", "w1", pair.hub)
	testing.expect(t, claimed)
	lsp_registry_mark_started(&reg, "w1", "brg_gone")
	defer lsp_registry_release(&reg, "w1")

	lsp_registry_wake_bridge_sessions(&reg, "brg_gone")

	got, read_ok := read_server_frame(pair.browser, 3 * time.Second)
	testing.expect(t, read_ok, "the browser must receive a final frame")
	defer delete(got)
	testing.expect(t, strings.contains(got, "\"type\":\"lsp_error\""))
	testing.expect(t, strings.contains(got, "bridge disconnected"))
	testing.expect(t, strings.contains(got, "\"session_id\":\"editor-1\""))
}

// --- driving the real handler in-process -------------------------------------
//
// The tests above exercise the relay's pieces. This one runs
// lsp_session_stream_handler itself over a real socket, which is the only way the
// tracking allocator can see what that proc allocates and frees.
//
// It exists because a bad free lived on this exact path and NO test could see it:
// platform.generate_id returns fmt.tprintf memory (temp allocator), and the
// handler freed it with delete(). A suite that never enters the handler reports
// "successful" with that defect present — the failure mode the chain's standing
// allocator rule describes.

@(private = "file")
Handler_Run :: struct {
	h:        ^Lsp_Session_Stream_Handlers,
	req:      Request,
	sock:     net.TCP_Socket,
	finished: bool,
}

@(private = "file")
run_stream_handler :: proc(data: rawptr) {
	r := (^Handler_Run)(data)
	lsp_session_stream_handler(rawptr(r.h), r.req, r.sock)
	r.finished = true
}

@(test)
test_lsp_stream_handler_runs_and_unwinds_cleanly :: proc(t: ^testing.T) {
	pair, ok := make_loopback_pair(t)
	if !ok do return
	defer net.close(pair.listener)
	defer net.close(pair.hub)

	tickets := new_user_ws_ticket_store()
	defer user_ws_ticket_store_free(&tickets)
	user_ws_ticket_store_put(&tickets, "uwst_test_ticket", contracts.Auth_Context{
		kind = .Session, user_id = "user_a", name = "a", display_name = "A", email = "a@x",
	}, 60)

	// Experiment ON so the handler gets past the gate and reaches the id
	// allocation and the upgrade.
	exp := Fake_Experiments_Socket{key = "lsp", enabled = true, present = true}
	exp_repo := iface.Experiment_Repository{ctx = rawptr(&exp), list_by_owner = fake_experiment_list_socket}

	reg := Lsp_Session_Registry{}
	defer {
		delete(reg.by_wire)
		delete(reg.by_owner)
	}
	ids := http_test_id_generator()
	h := Lsp_Session_Stream_Handlers{
		ws_tickets = &tickets,
		sessions   = &reg,
		ids        = &ids,
		experiments = &exp_repo,
	}

	headers := []contracts.HTTP_Header{{name = "Sec-WebSocket-Key", value = "dGhlIHNhbXBsZSBub25jZQ=="}}
	r := new(Handler_Run)
	defer free(r)
	r.h = &h
	r.sock = pair.hub
	r.req = Request{
		method = "GET", path = "/api/v1/lsp/editor-1/stream",
		query = "ticket=uwst_test_ticket", request_id = "req_test", headers = headers,
	}

	th := thread.create_and_start_with_data(rawptr(r), run_stream_handler)
	defer thread.destroy(th)

	// The handler should upgrade and send its ready frame.
	got, read_ok := read_upgrade_then_frame(pair.browser, 5 * time.Second)
	testing.expect(t, read_ok, "the handler must complete the upgrade and send ready")
	if read_ok {
		testing.expect(t, strings.contains(got, "\"type\":\"ready\""))
		testing.expect(t, strings.contains(got, "\"session_id\":\"editor-1\""))
		delete(got)
	}
	// The session is registered while the socket is live.
	testing.expect_value(t, len(reg.by_owner), 1)

	// Browser goes away -> the handler's read fails, it unwinds and releases.
	net.close(pair.browser)
	deadline := time.now()
	for !r.finished && time.duration_seconds(time.since(deadline)) < 10.0 {
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, r.finished, "the handler must unwind when the browser disconnects")
	thread.join(th)

	// Its deferred release ran: no entry, and the (owner, session) pair is free
	// again for a reconnect.
	testing.expect_value(t, len(reg.by_wire), 0)
	testing.expect_value(t, len(reg.by_owner), 0)
}

@(private = "file")
Fake_Experiments_Socket :: struct {
	key:     string,
	enabled: bool,
	present: bool,
}

@(private = "file")
fake_experiment_list_socket :: proc(ctx: rawptr, owner_user_id: string) -> ([dynamic]domain.Experiment, domain.Domain_Error) {
	f := (^Fake_Experiments_Socket)(ctx)
	out := make([dynamic]domain.Experiment)
	if f.present {
		append(&out, domain.Experiment{
			owner_user_id = strings.clone(owner_user_id),
			key           = strings.clone(f.key),
			enabled       = f.enabled,
			updated_at    = strings.clone("2026-01-01T00:00:00Z"),
		})
	}
	return out, domain.Domain_Error{}
}
