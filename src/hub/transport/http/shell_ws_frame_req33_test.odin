package http

// REQ-SHELL-33 at the transport layer: the two in-scope writers, and the late-join
// screen snapshot that is the one caller able to exceed a length arm.
//
// No PTY and no browser. A loopback pair with enlarged buffers stands in for the
// viewer socket; the frames are read back off the wire and parsed here, because the
// thing that has to be true is a property of the BYTES, not of a return value.

import base64 "core:encoding/base64"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import shell_session_svc "odin_test:hub/service/shell_session"
import ws "odin_test:lib/ws"

@(private = "file")
Pair :: struct {
	listener: net.TCP_Socket,
	peer:     net.TCP_Socket,
	hub:      net.TCP_Socket,
}

@(private = "file")
PAIR_BUFFER_BYTES :: 8 * 1024 * 1024

@(private = "file")
make_pair :: proc(t: ^testing.T) -> Pair {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if listen_err != nil do testing.fail_now(t, "could not listen on loopback")
	bound, bound_err := net.bound_endpoint(listener)
	if bound_err != nil {
		net.close(listener)
		testing.fail_now(t, "could not read the bound endpoint")
	}
	peer, dial_err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	if dial_err != nil {
		net.close(listener)
		testing.fail_now(t, "could not dial loopback")
	}
	hub, _, accept_err := net.accept_tcp(listener)
	if accept_err != nil {
		net.close(listener)
		net.close(peer)
		testing.fail_now(t, "could not accept on loopback")
	}
	_ = net.set_option(hub, .Send_Buffer_Size, PAIR_BUFFER_BYTES)
	_ = net.set_option(peer, .Receive_Buffer_Size, PAIR_BUFFER_BYTES)
	_ = net.set_option(peer, .Receive_Timeout, 500 * time.Millisecond)
	return Pair{listener = listener, peer = peer, hub = hub}
}

@(private = "file")
close_pair :: proc(p: ^Pair) {
	net.close(p.hub)
	net.close(p.peer)
	net.close(p.listener)
}

// drain reads until the peer goes quiet. Caller owns the result.
@(private = "file")
drain :: proc(sock: net.TCP_Socket) -> []byte {
	out := make([dynamic]byte)
	buf: [65536]byte
	for {
		n, err := net.recv_tcp(sock, buf[:])
		if err != nil || n <= 0 do break
		append(&out, ..buf[:n])
	}
	return out[:]
}

// split_text_frames parses unmasked server->client text frames out of a byte stream,
// returning each frame's PAYLOAD. ok=false means the stream was malformed, which is
// itself a failure worth reporting. Payloads alias `raw`; the caller owns nothing.
@(private = "file")
split_text_frames :: proc(raw: []byte) -> (payloads: [dynamic]string, ok: bool) {
	payloads = make([dynamic]string)
	pos := 0
	for pos < len(raw) {
		if len(raw) - pos < 2 do return payloads, false
		if raw[pos] != 0x81 do return payloads, false
		n := int(raw[pos + 1] & 0x7f)
		header := 2
		if n == 126 {
			if len(raw) - pos < 4 do return payloads, false
			n = int(raw[pos + 2]) << 8 | int(raw[pos + 3])
			header = 4
		} else if n == 127 {
			if len(raw) - pos < 10 do return payloads, false
			n = 0
			for i in 0 ..< 8 do n = n << 8 | int(raw[pos + 2 + i])
			header = 10
		}
		if len(raw) - pos - header < n do return payloads, false
		append(&payloads, string(raw[pos + header:pos + header + n]))
		pos += header + n
	}
	return payloads, true
}

// --- the two writers ------------------------------------------------------------

// The bridge control channel keeps its 16-bit bound (our own readers treat a 127
// length as fatal), but the refusal must now be reported rather than silent, and it
// must leave the socket clean — NOT half a frame.
@(test)
test_req33_control_writer_refuses_oversize_and_writes_nothing :: proc(t: ^testing.T) {
	pair := make_pair(t)
	defer close_pair(&pair)
	big := strings.repeat("y", ws.WS_16BIT_MAX_PAYLOAD + 1)
	defer delete(big)
	testing.expect(t, !write_ws_text_frame(pair.hub, big), "an oversized control frame must not report success")

	testing.expect(t, write_ws_text_frame(pair.hub, "ack"), "the socket must still be usable")
	raw := drain(pair.peer)
	defer delete(raw)
	frames, parse_ok := split_text_frames(raw)
	defer delete(frames)
	testing.expect(t, parse_ok, "the stream must be well-formed — a partial frame would desynchronise the peer")
	testing.expect_value(t, len(frames), 1)
	testing.expect_value(t, frames[0], "ack")
}

// The browser writer gets the 64-bit arm, and reports the typed result so its callers
// can tell "could not encode" from "peer is gone".
@(test)
test_req33_browser_writer_sends_over_65535 :: proc(t: ^testing.T) {
	pair := make_pair(t)
	defer close_pair(&pair)
	big := strings.repeat("z", 80_000)
	defer delete(big)
	testing.expect_value(t, write_ws_text_frame_browser(pair.hub, big), ws.Text_Write_Result.Ok)
	raw := drain(pair.peer)
	defer delete(raw)
	frames, parse_ok := split_text_frames(raw)
	defer delete(frames)
	testing.expect(t, parse_ok)
	testing.expect_value(t, len(frames), 1)
	testing.expect_value(t, len(frames[0]), 80_000)
}

// --- the screen snapshot ---------------------------------------------------------

// Builds a pane reply whose repaint is several chunks long: wide rows, as a colourful
// TUI produces once vt.rs has written its SGR runs inline.
@(private = "file")
wide_pane_reply :: proc(rows, cols: int) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"output\":\"")
	for r in 0 ..< rows {
		if r > 0 do strings.write_string(&b, "\\n")
		for _ in 0 ..< cols do strings.write_byte(&b, 'w')
	}
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

// THE USER-VISIBLE BUG. A wide, colourful pane used to exceed 65535 in one frame, get
// dropped on a `false` nobody inspected, and paint NOTHING — a blank pane on switch.
// It must now arrive, in ordered chunks, byte-identical to the one-shot repaint.
@(test)
test_req33_wide_snapshot_paints_in_ordered_chunks :: proc(t: ^testing.T) {
	pair := make_pair(t)
	defer close_pair(&pair)

	reply := wide_pane_reply(220, 900)
	defer delete(reply)
	pane := json_string(reply, "output")
	defer delete(pane)
	expected := _shell_screen_repaint_text(pane)
	defer delete(expected)
	testing.expect(
		t,
		len(expected) > ws.WS_16BIT_MAX_PAYLOAD,
		"the fixture must exceed the 16-bit length or it does not exercise the defect",
	)

	testing.expect(t, _shell_stream_write_screen_frame(nil, "", pair.hub, reply), "the snapshot must be delivered")

	raw := drain(pair.peer)
	defer delete(raw)
	frames, parse_ok := split_text_frames(raw)
	defer delete(frames)
	testing.expect(t, parse_ok, "every chunk must be a well-formed frame")
	testing.expect(t, len(frames) > 1, "an oversized repaint must be chunked, not sent as one frame")

	rebuilt := strings.builder_make()
	defer strings.builder_destroy(&rebuilt)
	for frame, i in frames {
		// Each frame must stand alone: its own JSON, its own decodable base64.
		b64 := json_string(frame, "data_b64")
		defer delete(b64)
		testing.expect(t, b64 != "", "every chunk carries data_b64")
		chunk, decode_err := base64.decode(b64)
		testing.expect(t, decode_err == nil, "every chunk must decode on its own")
		defer delete(chunk)
		// The repaint prefix leads the FIRST chunk only — re-erasing mid-sequence
		// would wipe the part already painted.
		has_prefix := strings.has_prefix(string(chunk), SHELL_SCREEN_REPAINT_PREFIX)
		if i == 0 {
			testing.expect(t, has_prefix, "the first chunk must erase and home")
		} else {
			testing.expect(t, !has_prefix, "a later chunk must not re-erase the screen")
		}
		strings.write_string(&rebuilt, string(chunk))
	}
	testing.expect_value(t, strings.to_string(rebuilt), expected)
}

// A pane that fits is still one frame: chunking must not change the common case.
@(test)
test_req33_small_snapshot_is_still_one_frame :: proc(t: ^testing.T) {
	pair := make_pair(t)
	defer close_pair(&pair)
	testing.expect(t, _shell_stream_write_screen_frame(nil, "", pair.hub, "{\"output\":\"hello\\nworld\"}"))
	raw := drain(pair.peer)
	defer delete(raw)
	frames, parse_ok := split_text_frames(raw)
	defer delete(frames)
	testing.expect(t, parse_ok)
	testing.expect_value(t, len(frames), 1)
}

// The chunk boundary prefers a row end so a chunk never splits an SGR escape run or a
// multi-byte rune, and it must always advance — a boundary search that returns `start`
// would spin forever on a row longer than the budget.
@(test)
test_req33_chunk_end_prefers_a_row_boundary_and_always_advances :: proc(t: ^testing.T) {
	rows := strings.repeat("abcdefghi\n", SHELL_SCREEN_CHUNK_DECODED_BYTES / 10 + 16)
	defer delete(rows)
	end := _shell_screen_chunk_end(rows, 0)
	testing.expect(t, end > 0 && end <= SHELL_SCREEN_CHUNK_DECODED_BYTES, "the chunk must fit the budget")
	testing.expect_value(t, rows[end - 1], byte('\n'))

	// One row longer than the whole budget: no boundary exists, so it must fall back
	// to the hard byte bound rather than failing to advance.
	one_row := strings.repeat("q", SHELL_SCREEN_CHUNK_DECODED_BYTES * 2)
	defer delete(one_row)
	testing.expect_value(t, _shell_screen_chunk_end(one_row, 0), SHELL_SCREEN_CHUNK_DECODED_BYTES)

	// A remainder that fits ends the loop exactly at the end of the string.
	testing.expect_value(t, _shell_screen_chunk_end("short", 0), 5)
}

// --- the chunk sequence must be ATOMIC against the fan-out --------------------------

// Chunking is only sound if nothing else writes the socket mid-sequence. The
// bridge-push path (shell_session_broadcast_output) writes the SAME viewer socket from
// another thread; an `output` frame between two chunks moves the cursor and mispositions
// every chunk after it, because those carry no erase+home and no absolute positioning.
//
// This hammers the fan-out from a second thread for the whole duration of a multi-chunk
// snapshot and then asserts that the snapshot's frames arrived CONTIGUOUSLY. The
// assertion cannot fail spuriously: output frames landing entirely before or entirely
// after the sequence both satisfy it, and only an actual interleave breaks it.
@(private = "file")
Hammer :: struct {
	svc:     ^shell_session_svc.Shell_Session_Service,
	stop:    bool,
	written: int,
}

@(private = "file")
hammer_output :: proc(raw: rawptr) {
	h := (^Hammer)(raw)
	for !sync.atomic_load(&h.stop) {
		shell_session_svc.shell_session_broadcast_output(h.svc, "sh_race", "T1VU")
		h.written += 1
		time.sleep(time.Millisecond)
	}
}

@(test)
test_req33_output_cannot_interleave_with_a_chunked_snapshot :: proc(t: ^testing.T) {
	pair := make_pair(t)
	defer close_pair(&pair)

	svc := shell_session_svc.Shell_Session_Service{}
	defer shell_session_svc.shell_session_service_free(&svc)
	shell_session_svc.shell_session_attach(&svc, "sh_race", pair.hub)

	hammer := Hammer{svc = &svc}
	th := thread.create_and_start_with_data(rawptr(&hammer), hammer_output)
	defer {
		thread.join(th)
		thread.destroy(th)
	}
	time.sleep(2 * time.Millisecond)

	reply := wide_pane_reply(220, 900)
	defer delete(reply)
	testing.expect(t, _shell_stream_write_screen_frame(&svc, "sh_race", pair.hub, reply))
	sync.atomic_store(&hammer.stop, true)
	thread.join(th)

	raw := drain(pair.peer)
	defer delete(raw)
	frames, parse_ok := split_text_frames(raw)
	defer delete(frames)
	// A byte-level interleave would corrupt the framing itself, so this is the first
	// thing the test proves.
	testing.expect(t, parse_ok, "concurrent writers must not interleave inside a frame")
	testing.expect(t, hammer.written > 0, "the fan-out must actually have been running")

	first_screen := -1
	last_screen := -1
	screens := 0
	for frame, i in frames {
		if strings.contains(frame, "\"type\":\"screen\"") {
			if first_screen < 0 do first_screen = i
			last_screen = i
			screens += 1
		}
	}
	testing.expect(t, screens > 1, "the fixture must chunk or it proves nothing")
	testing.expect_value(t, last_screen - first_screen + 1, screens)
}
