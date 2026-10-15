package http

// REQ-PTY-NET-2 — the hub side of binary pty frames on the bridge-ws.
//
// A bridge->hub OUTPUT session frame arrives as WebSocket opcode 0x2, is surfaced by the
// reader with last_opcode == 0x2, and is routed by bridge_ws_process_binary_frame to the
// shell fan-out WITHOUT re-encoding: the viewer receives a binary viewer frame whose payload
// is byte-identical to what the bridge sent.

import "core:net"
import "core:strings"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import shell_session_svc "odin_test:hub/service/shell_session"

@(private = "file")
make_masked_binary_frame :: proc(payload: []byte, mask: [4]byte) -> [dynamic]byte {
	n := len(payload)
	out := make([dynamic]byte)
	append(&out, 0x82)
	if n <= 125 {
		append(&out, byte(0x80 | n))
	} else {
		append(&out, byte(0x80 | 126), byte((n >> 8) & 0xff), byte(n & 0xff))
	}
	append(&out, mask[0], mask[1], mask[2], mask[3])
	for i in 0 ..< n {
		append(&out, payload[i] ~ mask[i % 4])
	}
	return out
}

@(test)
test_pty_wire_session_frame_round_trips :: proc(t: ^testing.T) {
	payload := transmute([]byte)string("\x1b[32mhi λ\x1b[0m\r\n")
	frame := contracts.pty_wire_encode_session_frame(contracts.PTY_WIRE_KIND_OUTPUT, contracts.pty_wire_flags(true, true), "sh_round_trip", payload)
	defer delete(frame)
	testing.expect_value(t, len(frame), contracts.PTY_WIRE_SESSION_HEADER_BYTES + len("sh_round_trip") + len(payload))
	kind, flags, sid, body, ok := contracts.pty_wire_decode_session_frame(frame)
	testing.expect(t, ok)
	testing.expect_value(t, kind, contracts.PTY_WIRE_KIND_OUTPUT)
	testing.expect(t, contracts.pty_wire_is_snapshot(flags))
	testing.expect(t, contracts.pty_wire_is_encrypted(flags))
	testing.expect_value(t, sid, "sh_round_trip")
	testing.expect_value(t, string(body), string(payload))

	// Malformed: header only, zero-length session id, truncated id.
	_, _, _, _, ok0 := contracts.pty_wire_decode_session_frame([]byte{1, 0, 0, 0})
	testing.expect(t, !ok0, "an empty session id is rejected")
	_, _, _, _, ok1 := contracts.pty_wire_decode_session_frame([]byte{1, 0, 0, 5, 'a', 'b'})
	testing.expect(t, !ok1, "a truncated session id is rejected")
	_, _, _, _, ok2 := contracts.pty_wire_decode_session_frame([]byte{1, 0})
	testing.expect(t, !ok2, "a short header is rejected")

	// Viewer frame with and without the cursor block.
	v := contracts.pty_wire_encode_viewer_frame(contracts.PTY_WIRE_KIND_SCREEN, contracts.pty_wire_flags(true, false), payload, 3, 258)
	defer delete(v)
	vk, vf, vp, vr, vc, vok := contracts.pty_wire_decode_viewer_frame(v)
	testing.expect(t, vok)
	testing.expect_value(t, vk, contracts.PTY_WIRE_KIND_SCREEN)
	testing.expect(t, vf & contracts.PTY_WIRE_FLAG_CURSOR != 0)
	testing.expect_value(t, vr, 3)
	testing.expect_value(t, vc, 258)
	testing.expect_value(t, string(vp), string(payload))
	v2 := contracts.pty_wire_encode_viewer_frame(contracts.PTY_WIRE_KIND_OUTPUT, 0, payload)
	defer delete(v2)
	_, _, _, r2, c2, _ := contracts.pty_wire_decode_viewer_frame(v2)
	testing.expect_value(t, r2, -1)
	testing.expect_value(t, c2, -1)
	testing.expect(t, contracts.pty_wire_viewer_frame_is_incremental_output(v2))
	testing.expect(t, !contracts.pty_wire_viewer_frame_is_incremental_output(v))
}

@(test)
test_bridge_ws_reader_surfaces_binary_opcode :: proc(t: ^testing.T) {
	reader := Bridge_WS_Reader{}
	defer bridge_ws_reader_destroy(&reader)
	payload := contracts.pty_wire_encode_session_frame(contracts.PTY_WIRE_KIND_OUTPUT, 0, "sh_op", transmute([]byte)string("out"))
	defer delete(payload)
	frame := make_masked_binary_frame(payload, {0xde, 0xad, 0xbe, 0xef})
	defer delete(frame)
	append(&reader.pending, ..frame[:])

	text, ok, fatal := bridge_ws_take_frame(&reader)
	testing.expect(t, ok && !fatal, "a binary frame is a data frame, not a fatal one")
	testing.expect_value(t, reader.last_opcode, u8(0x2))
	testing.expect_value(t, text, string(payload))
	delete(text)
}

@(test)
test_bridge_binary_output_frame_reaches_viewer_unchanged :: proc(t: ^testing.T) {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if listen_err != nil do testing.fail_now(t, "could not listen on loopback")
	defer net.close(listener)
	bound, _ := net.bound_endpoint(listener)
	client, dial_err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	if dial_err != nil do testing.fail_now(t, "could not dial loopback")
	defer net.close(client)
	hub, _, accept_err := net.accept_tcp(listener)
	if accept_err != nil do testing.fail_now(t, "could not accept on loopback")
	defer net.close(hub)

	svc := shell_session_svc.new_shell_session_service()
	defer shell_session_svc.shell_session_service_free(&svc)
	session_id := "sh_binary_route"
	shell_session_svc.shell_session_attach(&svc, session_id, hub, "brg_bin")

	bh := Bridge_Handlers{shell_sessions = &svc}
	ciphertext_like := []byte{0x00, 0x01, 0x02, 0xff, 0xfe, 0x80, 0x1b, 0x5b} // not UTF-8, not JSON
	wire := contracts.pty_wire_encode_session_frame(contracts.PTY_WIRE_KIND_OUTPUT, contracts.pty_wire_flags(true, true), session_id, ciphertext_like)
	testing.expect(t, bridge_ws_process_binary_frame(&bh, "brg_bin", 0, string(wire)), "a well-formed output frame is accepted")

	// The viewer gets ONE binary frame: kind OUTPUT, both flags, payload byte-identical.
	_ = net.set_option(client, .Receive_Timeout, 2 * time.Second)
	buf: [256]byte
	n, recv_err := net.recv_tcp(client, buf[:])
	testing.expect(t, recv_err == nil && n > 2, "viewer must receive the frame")
	if n <= 2 do return
	testing.expect_value(t, buf[0], byte(0x82)) // FIN + binary opcode
	body := buf[2:n]
	kind, flags, got, _, _, dok := contracts.pty_wire_decode_viewer_frame(body)
	testing.expect(t, dok)
	testing.expect_value(t, kind, contracts.PTY_WIRE_KIND_OUTPUT)
	testing.expect(t, contracts.pty_wire_is_snapshot(flags) && contracts.pty_wire_is_encrypted(flags))
	testing.expect_value(t, string(got), string(ciphertext_like))

	// A frame from a bridge that does not own the session is dropped (still accepted on
	// the connection), and a frame that is not a pty_wire frame at all is rejected.
	other := contracts.pty_wire_encode_session_frame(contracts.PTY_WIRE_KIND_OUTPUT, 0, session_id, transmute([]byte)string("x"))
	testing.expect(t, bridge_ws_process_binary_frame(&bh, "brg_other", 0, string(other)))
	testing.expect(t, !bridge_ws_process_binary_frame(&bh, "brg_bin", 0, strings.clone("\x01\x00")), "a malformed binary frame is rejected")
	_ = net.set_option(client, .Receive_Timeout, 100 * time.Millisecond)
	n2, _ := net.recv_tcp(client, buf[:])
	testing.expect(t, n2 <= 0, "nothing else reaches the viewer")
}
