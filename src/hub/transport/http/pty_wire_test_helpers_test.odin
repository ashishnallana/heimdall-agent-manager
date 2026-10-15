package http

// Test-only helpers for reading pty_wire BINARY viewer frames (REQ-PTY-NET-2). The hub's
// pane tests were written against the JSON frames this format replaced; rendering a binary
// frame through contracts.pty_wire_viewer_frame_debug_json lets those assertions keep
// saying what they always said about the bytes that reach the viewer.

import contracts "odin_test:contracts"
import "core:strings"

// pty_test_ws_payload_to_json returns a server->client WS payload as the JSON a test can
// inspect: text frames verbatim, binary frames via the debug renderer. Caller owns it.
pty_test_ws_payload_to_json :: proc(opcode: u8, payload: string) -> string {
	if opcode == 0x2 do return contracts.pty_wire_viewer_frame_debug_json(transmute([]byte)payload)
	return strings.clone(payload)
}

// pty_test_split_server_frames parses a run of unmasked server frames (text or binary),
// returning each payload as JSON (see above). ok=false on a malformed run.
pty_test_split_server_frames :: proc(raw: []byte, allocator := context.allocator) -> (payloads: [dynamic]string, ok: bool) {
	payloads = make([dynamic]string, allocator)
	pos := 0
	for pos < len(raw) {
		if len(raw) - pos < 2 do return payloads, false
		if raw[pos] != 0x81 && raw[pos] != 0x82 do return payloads, false
		opcode := raw[pos] & 0x0f
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
		context.allocator = allocator
		append(&payloads, pty_test_ws_payload_to_json(opcode, string(raw[pos + header:pos + header + n])))
		pos += header + n
	}
	return payloads, true
}

// pty_test_first_server_frame_json renders the FIRST frame in a raw server byte run.
pty_test_first_server_frame_json :: proc(raw: []byte) -> string {
	frames, _ := pty_test_split_server_frames(raw, context.temp_allocator)
	if len(frames) == 0 do return ""
	return frames[0]
}
