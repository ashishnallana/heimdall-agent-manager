package http

// REQ-SHELL-54: the preview/tunnel chunk is 48 KiB of RAW bytes, which base64s to
// exactly 65536 characters against a 65535-byte single-frame cap — over by ONE BYTE
// before the JSON wrapper is counted at all.
//
// WHAT WENT WRONG, and why the symptom pointed at the wrong component. Both tunnel
// senders slice the payload at CHUNK_SIZE :: 48 * 1024 and base64 each slice:
//
//     bridge_proxy_relay.odin:409      bridge_proxy_send_tunnel_bytes
//     shell_session_handlers.odin:418  the preview request path
//
// 49152 is divisible by 3, so base64 adds NO padding and the encoding is exactly
// ceil(49152/3)*4 = 65536 chars. _preview_tunnel_data_json then wraps it in ~60 more
// bytes plus the stream_id. Before REQ-SHELL-36 the resulting ~65.6 KiB command was
// handed to a writer that could only emit a 16-bit length, so it was refused, and the
// refusal was reported as Bridge_Offline. A FULL chunk therefore always failed while a
// short final chunk always succeeded: a size cliff at 48 KiB that blamed a healthy
// bridge.
//
// WHAT THESE TESTS ARE FOR. REQ-SHELL-36 made write_ws_command chunk any oversized
// command, and it gates on LENGTH ALONE — nothing keys off the command's "type" — so
// the tunnel frames are carried without either call site being touched. That is the
// claim, and a plausible mechanism is not an observation, so it is asserted here
// against the REAL frame the preview path emits and the REAL writer, over a real
// socket, with the bytes read back off the wire.
//
// THE VERIFICATION BOUNDARY, stated rather than implied. These tests cover the HUB
// half: the frame is built by the production wrapper builder, split by the production
// writer, and the wire bytes are reassembled here to prove nothing was lost. They do
// NOT execute the bridge's reassembler: src/bridge is `package main` and cannot be
// imported. That half is pinned by its own package's tests
// (src/bridge/hub_command_reassembly_test.odin, which includes an interop test for
// this exact emitter's frame shape), and the bridge dispatches on
// hub_command_frame_is_chunk for EVERY inbound frame, so it is no more tunnel-specific
// than the writer is.

import base64 "core:encoding/base64"
import "core:net"
import "core:strings"
import "core:testing"
import "core:time"
import bridge_runtime "odin_test:hub/service/bridge_runtime"
import "odin_test:contracts"
import ws "odin_test:lib/ws"

// PREVIEW_CHUNK_SIZE_AS_SHIPPED mirrors the CHUNK_SIZE local in both tunnel senders.
// It is duplicated rather than imported because both are procedure-local constants.
// That duplication is the POINT: these tests pin the arithmetic of the shipped value,
// so changing either call site without changing this number makes the tests speak
// about a size the product no longer uses, and the mismatch is the signal.
@(private = "file")
PREVIEW_CHUNK_SIZE_AS_SHIPPED :: 48 * 1024

// _req54_pair is a loopback socket pair with buffers large enough that a full chunked
// command cannot block the writer. Same shape as the REQ-SHELL-33 helper in
// shell_ws_frame_req33_test.odin, re-declared because that one is file-private.
@(private = "file")
Req54_Pair :: struct {
	listener: net.TCP_Socket,
	peer:     net.TCP_Socket,
	hub:      net.TCP_Socket,
}

@(private = "file")
REQ54_PAIR_BUFFER_BYTES :: 8 * 1024 * 1024

@(private = "file")
req54_make_pair :: proc(t: ^testing.T) -> Req54_Pair {
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
	// net.accept_tcp returns (socket, source_endpoint, err) — three values.
	hub, _, accept_err := net.accept_tcp(listener)
	if accept_err != nil {
		net.close(listener)
		net.close(peer)
		testing.fail_now(t, "could not accept on loopback")
	}
	_ = net.set_option(hub, .Send_Buffer_Size, REQ54_PAIR_BUFFER_BYTES)
	_ = net.set_option(peer, .Receive_Buffer_Size, REQ54_PAIR_BUFFER_BYTES)
	_ = net.set_option(peer, .Receive_Timeout, 500 * time.Millisecond)
	return Req54_Pair{listener = listener, peer = peer, hub = hub}
}

@(private = "file")
req54_close_pair :: proc(p: ^Req54_Pair) {
	net.close(p.hub)
	net.close(p.peer)
	net.close(p.listener)
}

@(private = "file")
req54_drain :: proc(sock: net.TCP_Socket) -> []byte {
	out := make([dynamic]byte)
	buf: [65536]byte
	for {
		n, err := net.recv_tcp(sock, buf[:])
		if err != nil || n <= 0 do break
		append(&out, ..buf[:n])
	}
	return out[:]
}

// req54_split_text_frames parses unmasked FIN+text frames out of a byte stream and
// returns each PAYLOAD. Payloads alias `raw`. ok=false means the stream was malformed,
// which is itself a failure worth reporting — a half-written frame would desynchronise
// the peer, so "did it parse" is part of what is being asserted.
@(private = "file")
req54_split_text_frames :: proc(raw: []byte) -> (payloads: [dynamic]string, ok: bool) {
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
			// A 127 length must never appear on this channel: our own readers treat it
			// as fatal, which is exactly why REQ-SHELL-36 chunks instead of widening
			// the length field. Parsing it here so that emitting one shows up as a
			// frame OVER THE CAP below rather than as a parse failure.
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

@(private = "file")
req54_frame_string :: proc(frame, key: string) -> string {
	needle := strings.concatenate({"\"", key, "\":\""})
	defer delete(needle)
	i := strings.index(frame, needle)
	if i < 0 do return ""
	rest := frame[i + len(needle):]
	end := strings.index_byte(rest, '"')
	if end < 0 do return ""
	return strings.clone(rest[:end])
}

@(private = "file")
req54_frame_int :: proc(frame, key: string) -> int {
	needle := strings.concatenate({"\"", key, "\":"})
	defer delete(needle)
	i := strings.index(frame, needle)
	if i < 0 do return -1
	rest := frame[i + len(needle):]
	n := 0
	digits := 0
	for j in 0 ..< len(rest) {
		if rest[j] < '0' || rest[j] > '9' do break
		n = n * 10 + int(rest[j] - '0')
		digits += 1
	}
	if digits == 0 do return -1
	return n
}

// req54_build_preview_data_frame builds the frame a tunnel sender ACTUALLY emits for
// one full chunk: PREVIEW_CHUNK_SIZE_AS_SHIPPED raw bytes, base64 encoded by the same
// core:encoding/base64 the senders call, wrapped by the production
// _preview_tunnel_data_json. Nothing here is a stand-in for the real thing.
@(private = "file")
req54_build_preview_data_frame :: proc(stream_id: string) -> (frame: string, b64_len: int) {
	raw := make([]byte, PREVIEW_CHUNK_SIZE_AS_SHIPPED)
	defer delete(raw)
	// Content is irrelevant to the size — base64 expansion is fixed by LENGTH — but a
	// varying byte pattern makes a truncated or mis-ordered reassembly show up as a
	// content mismatch rather than accidentally comparing equal.
	for i in 0 ..< len(raw) do raw[i] = byte('A' + (i % 26))
	encoded := base64.encode(raw)
	defer delete(encoded)
	return _preview_tunnel_data_json(stream_id, string(encoded), 0, false), len(encoded)
}

// THE ARITHMETIC, pinned as executable fact rather than as a comment. This is the
// measurement the shipped 48 KiB was chosen without: 48 KiB of raw bytes cannot be
// carried in one 16-bit WS frame, and it misses by ONE BYTE on the base64 alone.
@(test)
test_req54_a_full_preview_chunk_overflows_a_single_ws_frame :: proc(t: ^testing.T) {
	frame, b64_len := req54_build_preview_data_frame("stream-abc")
	defer delete(frame)

	// 49152 % 3 == 0, so there is NO padding and the encoding is exact, not approximate.
	testing.expect_value(t, PREVIEW_CHUNK_SIZE_AS_SHIPPED, 49152)
	testing.expect_value(t, PREVIEW_CHUNK_SIZE_AS_SHIPPED % 3, 0)
	testing.expect_value(t, b64_len, 65536)

	// Over by exactly one byte BEFORE the wrapper — the whole defect in one assertion.
	testing.expect_value(t, b64_len - ws.WS_16BIT_MAX_PAYLOAD, 1)

	// And the wrapper is not free: the real frame is ~65.6 KiB, not 65536.
	testing.expect(
		t,
		len(frame) > b64_len,
		"the tunnel_data JSON wrapper must add bytes on top of the base64 — if it does not, the builder changed",
	)
	testing.expect(
		t,
		len(frame) > ws.WS_16BIT_MAX_PAYLOAD,
		"a full preview chunk must not fit a single 16-bit WS frame — that is the premise of this task",
	)

	// The pre-REQ-SHELL-36 world, reproduced on a real socket: the single-frame writer
	// refuses the frame outright. This arm does NOT distinguish the two worlds (the
	// writer refuses in both) — it documents the DROP that got misreported as
	// Bridge_Offline. The arm that distinguishes them is the next test.
	pair := req54_make_pair(t)
	defer req54_close_pair(&pair)
	testing.expect(
		t,
		!bridge_runtime.write_ws_text_frame(pair.hub, frame),
		"the single-frame writer must refuse a full preview chunk — if it accepts one, the cap moved",
	)
}

// AC1/AC2: the END-TO-END observation. The real preview frame goes through the real
// write_ws_command over a real socket; the bytes are read back off the wire and
// reassembled. This is the arm that FAILS on pre-REQ-SHELL-36 behaviour — revert
// write_ws_command to a single write_ws_text_frame and it returns .Send_Failed here
// instead of .Ok, because the frame is over the cap.
@(test)
test_req54_write_ws_command_carries_a_full_preview_chunk :: proc(t: ^testing.T) {
	frame, _ := req54_build_preview_data_frame("stream-abc")
	defer delete(frame)

	pair := req54_make_pair(t)
	defer req54_close_pair(&pair)

	// .Ok, not .Too_Large and not .Send_Failed. Pre-36 this was .Send_Failed, which
	// send_runtime_command mapped to Bridge_Offline.
	testing.expect_value(
		t,
		bridge_runtime.write_ws_command(pair.hub, frame),
		bridge_runtime.Command_Write_Result.Ok,
	)

	raw := req54_drain(pair.peer)
	defer delete(raw)
	frames, parse_ok := req54_split_text_frames(raw)
	defer delete(frames)
	testing.expect(t, parse_ok, "the wire stream must be well-formed — a partial frame would desynchronise the bridge")

	// It was SPLIT, not sent whole: more than one frame on the wire.
	testing.expect(
		t,
		len(frames) > 1,
		"an over-cap command must reach the wire as several chunk frames, not one",
	)

	// EVERY frame is inside the cap. This is the property the defect violated.
	for f, i in frames {
		if len(f) > ws.WS_16BIT_MAX_PAYLOAD {
			testing.expectf(
				t,
				false,
				"chunk frame %d is %d bytes, over the %d cap",
				i,
				len(f),
				ws.WS_16BIT_MAX_PAYLOAD,
			)
		}
	}

	// The chunk count is the one the shared constant implies, so this test would notice
	// a silent change to the hub->bridge payload size rather than papering over it.
	expected_chunks := bridge_runtime.hub_command_chunk_count(
		len(frame),
		contracts.BRIDGE_WS_HUB_TO_BRIDGE_CHUNK_PAYLOAD_BYTES,
	)
	testing.expect_value(t, len(frames), expected_chunks)

	// ROUND TRIP, byte-for-byte. Read each frame's DECLARED chunk_index rather than
	// trusting wire order, so a chunker that emitted frames out of order could not pass
	// by accident.
	parts := make([]string, len(frames))
	defer {
		for p in parts do delete(p)
		delete(parts)
	}
	for f in frames {
		idx := req54_frame_int(f, "chunk_index")
		if idx < 0 || idx >= len(parts) {
			testing.expectf(t, false, "chunk frame carried an unusable chunk_index %d", idx)
			return
		}
		frag := req54_frame_string(f, "payload_fragment")
		defer delete(frag)
		decoded, err := base64.decode(frag)
		if err != nil {
			testing.expectf(t, false, "chunk %d had an undecodable payload_fragment", idx)
			return
		}
		defer delete(decoded)
		parts[idx] = strings.clone(string(decoded))
	}
	rebuilt := strings.concatenate(parts)
	defer delete(rebuilt)
	testing.expect_value(t, len(rebuilt), len(frame))
	testing.expect(
		t,
		rebuilt == frame,
		"the reassembled command must equal the original tunnel_data frame byte-for-byte",
	)
}

// AC4: the THIRD site that looks like the other two is safe, and this pins WHY rather
// than asserting it in prose. shell_session_handlers.odin:741 (the client->bridge
// WebSocket pump) reads into `buf: [4096]byte` and wraps at most that much, so its
// frames are an order of magnitude under the cap. It is deliberately NOT changed by
// this task, and this test is what would object if someone enlarged that buffer past
// the point where the same overflow returns.
@(test)
test_req54_the_4096_byte_pump_frame_fits_one_ws_frame :: proc(t: ^testing.T) {
	PUMP_BUF_BYTES :: 4096 // mirrors the `buf: [4096]byte` at shell_session_handlers.odin:741
	raw := make([]byte, PUMP_BUF_BYTES)
	defer delete(raw)
	for i in 0 ..< len(raw) do raw[i] = byte('A' + (i % 26))
	encoded := base64.encode(raw)
	defer delete(encoded)
	// 4096 % 3 == 1, so base64 pads: ceil(4096/3)*4 = 5464.
	testing.expect_value(t, len(encoded), 5464)

	frame := _preview_tunnel_data_json("stream-abc", string(encoded), 0, false)
	defer delete(frame)
	testing.expect(
		t,
		len(frame) <= ws.WS_16BIT_MAX_PAYLOAD,
		"the pump's 4096-byte frame must fit one WS frame — it is why this site needed no change",
	)

	// Comfortably under, not marginally: it fits whole and never reaches the chunker.
	testing.expect(
		t,
		len(frame) <= contracts.BRIDGE_WS_HUB_TO_BRIDGE_CHUNK_PAYLOAD_BYTES * 2,
		"the pump frame should be a small multiple of one chunk payload, not near the frame cap",
	)
}

// AC3, AND THIS IS THE PROPERTY THAT ACTUALLY MAKES 48 KiB SAFE -- asked for explicitly
// by the coordinator, and it is a stronger statement than the arithmetic above. The
// arithmetic says "this one size overflows". What matters is the INVARIANT: no size can
// put an over-cap frame on the wire, so CHUNK_SIZE can be anything without being fatal.
//
// The invariant rests on two facts that are checked by CONSTRUCTION elsewhere and driven
// here:
//   1. write_ws_command is the ONLY route to the bridge command socket. The socket is
//      fetched at exactly two places, bridge_runtime.odin:18 (send_runtime_command) and
//      :31 (send_runtime_command_wait), and both hand the text to write_ws_command.
//   2. write_ws_text_frame -- the writer that can emit an over-cap frame -- has exactly
//      two callers, bridge_runtime.odin:210 and :231, and BOTH are inside
//      write_ws_command, on opposite sides of its size gate.
// So there is no path that reaches the wire around the gate. What remains to be shown is
// that the gate itself never lets an over-cap frame through, at ANY input size, which is
// what this test drives.
//
// It gates on LENGTH ALONE -- nothing reads the command's "type" -- which is why the
// tunnel frames are carried without either call site being touched, and why this test
// deliberately mixes tunnel_data frames with plain text.
@(test)
test_req54_no_input_size_can_put_an_over_cap_frame_on_the_wire :: proc(t: ^testing.T) {
	payload := contracts.BRIDGE_WS_HUB_TO_BRIDGE_CHUNK_PAYLOAD_BYTES

	// Sizes chosen at the boundaries where an off-by-one would hide: either side of the
	// chunk payload, either side of the frame cap, and the real preview frame size.
	sizes := []int {
		1,
		payload - 1,
		payload, // fits whole, exactly
		payload + 1, // first size that must chunk
		ws.WS_16BIT_MAX_PAYLOAD - 1,
		ws.WS_16BIT_MAX_PAYLOAD, // the largest single frame that is legal
		ws.WS_16BIT_MAX_PAYLOAD + 1, // the first that is not
		PREVIEW_CHUNK_SIZE_AS_SHIPPED, // the raw slice size the tunnel senders use
		4 * PREVIEW_CHUNK_SIZE_AS_SHIPPED,
	}

	for size in sizes {
		text := strings.repeat("z", size)
		defer delete(text)

		pair := req54_make_pair(t)
		defer req54_close_pair(&pair)

		result := bridge_runtime.write_ws_command(pair.hub, text)
		if result != .Ok {
			testing.expectf(t, false, "write_ws_command refused a %d-byte command with %v", size, result)
			continue
		}

		raw := req54_drain(pair.peer)
		defer delete(raw)
		frames, parse_ok := req54_split_text_frames(raw)
		defer delete(frames)
		if !parse_ok {
			testing.expectf(t, false, "a %d-byte command produced a malformed wire stream", size)
			continue
		}

		// THE INVARIANT.
		for f, i in frames {
			if len(f) > ws.WS_16BIT_MAX_PAYLOAD {
				testing.expectf(
					t,
					false,
					"a %d-byte command put frame %d on the wire at %d bytes, over the %d cap",
					size,
					i,
					len(f),
					ws.WS_16BIT_MAX_PAYLOAD,
				)
			}
		}

		// And the split is the expected one: whole below the gate, chunked above it.
		if size <= payload {
			testing.expectf(t, len(frames) == 1, "a %d-byte command should be sent whole, got %d frames", size, len(frames))
		} else {
			testing.expectf(t, len(frames) > 1, "a %d-byte command should have been chunked, got %d frames", size, len(frames))
		}
	}
}
