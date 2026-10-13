package http

import "core:testing"

// Build a client->server masked WebSocket text frame (opcode 0x1) the way the
// bridge sends them, so tests exercise the same unmasking path as production.
@(private = "file")
make_masked_text_frame :: proc(text: string, mask: [4]byte) -> [dynamic]byte {
	n := len(text)
	out := make([dynamic]byte)
	append(&out, 0x81)
	if n <= 125 {
		append(&out, byte(0x80 | n))
	} else {
		append(&out, byte(0x80 | 126), byte((n >> 8) & 0xff), byte(n & 0xff))
	}
	append(&out, mask[0], mask[1], mask[2], mask[3])
	for i in 0 ..< n {
		append(&out, text[i] ~ mask[i % 4])
	}
	return out
}

@(test)
test_bridge_ws_take_frame_decodes_single :: proc(t: ^testing.T) {
	reader := Bridge_WS_Reader{}
	defer bridge_ws_reader_destroy(&reader)
	frame := make_masked_text_frame("{\"type\":\"bridge_heartbeat\"}", {0x11, 0x22, 0x33, 0x44})
	defer delete(frame)
	append(&reader.pending, ..frame[:])

	text, ok, fatal := bridge_ws_take_frame(&reader)
	testing.expect(t, ok)
	testing.expect(t, !fatal)
	testing.expect_value(t, text, "{\"type\":\"bridge_heartbeat\"}")
	delete(text)
	// Buffer fully consumed.
	testing.expect_value(t, len(reader.pending), 0)
}

@(test)
test_bridge_ws_take_frame_keeps_coalesced_second_frame :: proc(t: ^testing.T) {
	// THE >16KB REGRESSION: a heartbeat/state frame coalesced in the same recv as an
	// fs_read_file_result. The old per-call reader returned the first and DROPPED the
	// second, so the fs result never reached the cache and the request timed out.
	reader := Bridge_WS_Reader{}
	defer bridge_ws_reader_destroy(&reader)
	f1 := make_masked_text_frame("{\"type\":\"agent_instance_status\"}", {0x01, 0x02, 0x03, 0x04})
	f2 := make_masked_text_frame("{\"type\":\"fs_read_file_result\",\"command_id\":\"cmd_1\"}", {0xaa, 0xbb, 0xcc, 0xdd})
	defer delete(f1); defer delete(f2)
	append(&reader.pending, ..f1[:])
	append(&reader.pending, ..f2[:]) // both delivered in ONE recv

	first, ok1, _ := bridge_ws_take_frame(&reader)
	testing.expect(t, ok1)
	testing.expect_value(t, first, "{\"type\":\"agent_instance_status\"}")
	delete(first)

	// The SECOND frame must still be recoverable — not dropped.
	second, ok2, _ := bridge_ws_take_frame(&reader)
	testing.expect(t, ok2)
	testing.expect_value(t, second, "{\"type\":\"fs_read_file_result\",\"command_id\":\"cmd_1\"}")
	delete(second)

	testing.expect_value(t, len(reader.pending), 0)
}

@(test)
test_bridge_ws_take_frame_waits_for_partial :: proc(t: ^testing.T) {
	// A frame split across two recvs: the header + part of the payload arrive first
	// (incomplete -> ok=false, not fatal, bytes retained), the rest arrives next.
	reader := Bridge_WS_Reader{}
	defer bridge_ws_reader_destroy(&reader)
	full := make_masked_text_frame("hello-bridge", {0x09, 0x08, 0x07, 0x06})
	defer delete(full)
	split := len(full) - 3

	append(&reader.pending, ..full[:split])
	_, ok_partial, fatal_partial := bridge_ws_take_frame(&reader)
	testing.expect(t, !ok_partial)
	testing.expect(t, !fatal_partial)
	testing.expect_value(t, len(reader.pending), split) // retained for next recv

	append(&reader.pending, ..full[split:])
	text, ok, _ := bridge_ws_take_frame(&reader)
	testing.expect(t, ok)
	testing.expect_value(t, text, "hello-bridge")
	delete(text)
	testing.expect_value(t, len(reader.pending), 0)
}

@(test)
test_bridge_ws_take_frame_flags_nontext_fatal :: proc(t: ^testing.T) {
	// A close frame (opcode 0x8) is fatal (as the previous reader treated any
	// non-text frame), so the loop tears the connection down rather than spinning.
	reader := Bridge_WS_Reader{}
	defer bridge_ws_reader_destroy(&reader)
	append(&reader.pending, 0x88, 0x80, 0x00, 0x00, 0x00, 0x00) // masked, empty close
	_, ok, fatal := bridge_ws_take_frame(&reader)
	testing.expect(t, !ok)
	testing.expect(t, fatal)
}
