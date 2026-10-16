package http

// REQ-LSP-RLY-1 relay tests.
//
// These cover the parts that are wrong-able without a socket: the registry's
// ownership namespacing, WS framing in both directions (including the 64-bit
// length path no other writer in this codebase produces), the wire-id -> client-id
// translation, the experiment gate, and config resolution — specifically that the
// server command comes from the operator's stored config and never from the client.

import "core:net"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// --- registry: ownership is structural --------------------------------------

@(test)
test_lsp_registry_namespaces_session_ids_by_owner :: proc(t: ^testing.T) {
	reg := Lsp_Session_Registry{}
	defer {
		delete(reg.by_wire)
		delete(reg.by_owner)
	}

	// Two DIFFERENT users pick the SAME client session id. Both must succeed and
	// occupy separate entries — this is the whole point of keying by
	// (owner_user_id, session_id) rather than checking an owner field.
	a, a_ok := lsp_registry_claim(&reg, "user_a", "main", "lsp_wire_a", net.TCP_Socket(0))
	testing.expect(t, a_ok, "first user should claim the session id")
	b, b_ok := lsp_registry_claim(&reg, "user_b", "main", "lsp_wire_b", net.TCP_Socket(0))
	testing.expect(t, b_ok, "a different user must be able to use the same session id")
	testing.expect(t, a != b, "same session id for different users must be different entries")
	testing.expect_value(t, len(reg.by_wire), 2)
	testing.expect_value(t, len(reg.by_owner), 2)

	// Neither user's wire id can be reached through the other's identity.
	a_client, a_found := lsp_client_session_id(&reg, "lsp_wire_a")
	testing.expect(t, a_found)
	testing.expect_value(t, a_client, "main")
	delete(a_client)

	lsp_registry_release(&reg, "lsp_wire_a")
	lsp_registry_release(&reg, "lsp_wire_b")
	testing.expect_value(t, len(reg.by_wire), 0)
	testing.expect_value(t, len(reg.by_owner), 0)
}

@(test)
test_lsp_registry_second_socket_for_same_pair_is_refused :: proc(t: ^testing.T) {
	reg := Lsp_Session_Registry{}
	defer {
		delete(reg.by_wire)
		delete(reg.by_owner)
	}

	_, first_ok := lsp_registry_claim(&reg, "user_a", "main", "lsp_wire_1", net.TCP_Socket(0))
	testing.expect(t, first_ok)

	// A duplicate browser tab must NOT silently replace the live session.
	second, second_ok := lsp_registry_claim(&reg, "user_a", "main", "lsp_wire_2", net.TCP_Socket(0))
	testing.expect(t, !second_ok, "a second socket for the same (owner, session) must be refused")
	testing.expect(t, second == nil)
	testing.expect_value(t, len(reg.by_wire), 1) // the refused claim registered nothing
	testing.expect_value(t, len(reg.by_owner), 1)

	// The first session is untouched and still reachable.
	client_id, found := lsp_client_session_id(&reg, "lsp_wire_1")
	testing.expect(t, found, "the original session must survive the refused duplicate")
	delete(client_id)

	lsp_registry_release(&reg, "lsp_wire_1")
	testing.expect_value(t, len(reg.by_wire), 0)
}

@(test)
test_lsp_registry_release_is_idempotent :: proc(t: ^testing.T) {
	reg := Lsp_Session_Registry{}
	defer {
		delete(reg.by_wire)
		delete(reg.by_owner)
	}
	_, ok := lsp_registry_claim(&reg, "user_a", "s1", "lsp_wire_1", net.TCP_Socket(0))
	testing.expect(t, ok)
	lsp_registry_release(&reg, "lsp_wire_1")
	// The deferred release in the handler can run after an explicit "stop" path
	// already released; a second release must be a no-op, not a double free.
	lsp_registry_release(&reg, "lsp_wire_1")
	lsp_registry_release(&reg, "never_existed")
	testing.expect_value(t, len(reg.by_wire), 0)
}

@(test)
test_lsp_registry_mark_started_replaces_bridge_id :: proc(t: ^testing.T) {
	reg := Lsp_Session_Registry{}
	defer {
		delete(reg.by_wire)
		delete(reg.by_owner)
	}
	entry, ok := lsp_registry_claim(&reg, "user_a", "s1", "lsp_wire_1", net.TCP_Socket(0))
	testing.expect(t, ok)
	testing.expect_value(t, entry.bridge_id, "")
	testing.expect(t, !entry.started)

	lsp_registry_mark_started(&reg, "lsp_wire_1", "brg_one")
	testing.expect_value(t, entry.bridge_id, "brg_one")
	testing.expect(t, entry.started)

	// Marking again must free the previous clone rather than leak it.
	lsp_registry_mark_started(&reg, "lsp_wire_1", "brg_two")
	testing.expect_value(t, entry.bridge_id, "brg_two")

	lsp_registry_release(&reg, "lsp_wire_1")
}

@(test)
test_lsp_owner_key_cannot_collide_across_pairs :: proc(t: ^testing.T) {
	// Without a separator, ("ab","c") and ("a","bc") would both key as "abc".
	k1 := lsp_owner_key("ab", "c")
	defer delete(k1)
	k2 := lsp_owner_key("a", "bc")
	defer delete(k2)
	testing.expect(t, k1 != k2, "owner/session pairs must not collide into one key")
}

// --- outbound framing: the 64-bit length path -------------------------------

@(test)
test_lsp_ws_frame_header_encodes_each_length_class :: proc(t: ^testing.T) {
	buf: [10]byte

	// Small: length inline, 2-byte header.
	testing.expect_value(t, lsp_ws_frame_header(buf[:2], 5), 2)
	testing.expect_value(t, buf[0], byte(0x81))
	testing.expect_value(t, buf[1], byte(5))

	// 126..65535: 16-bit big-endian extended length.
	testing.expect_value(t, lsp_ws_frame_header(buf[:4], 65535), 4)
	testing.expect_value(t, buf[1], byte(126))
	testing.expect_value(t, buf[2], byte(0xff))
	testing.expect_value(t, buf[3], byte(0xff))

	// >65535: the 64-bit path. Every existing writer in this codebase REFUSES
	// this size, which would silently drop large LSP responses.
	n := 70000
	testing.expect_value(t, lsp_ws_frame_header(buf[:10], n), 10)
	testing.expect_value(t, buf[1], byte(127))
	// 70000 = 0x00011170, big-endian across the 8 length bytes.
	testing.expect_value(t, buf[2], byte(0))
	testing.expect_value(t, buf[3], byte(0))
	testing.expect_value(t, buf[4], byte(0))
	testing.expect_value(t, buf[5], byte(0))
	testing.expect_value(t, buf[6], byte(0))
	testing.expect_value(t, buf[7], byte(0x01))
	testing.expect_value(t, buf[8], byte(0x11))
	testing.expect_value(t, buf[9], byte(0x70))

	// Boundary: exactly 65536 must take the 64-bit path, not wrap to 0 in 16 bits.
	testing.expect_value(t, lsp_ws_header_len(65535), 4)
	testing.expect_value(t, lsp_ws_header_len(65536), 10)
	testing.expect_value(t, lsp_ws_frame_header(buf[:10], 65536), 10)
	testing.expect_value(t, buf[8], byte(0x00))
	testing.expect_value(t, buf[9], byte(0x00))
	testing.expect_value(t, buf[7], byte(0x01))
}

// --- inbound framing ---------------------------------------------------------

@(private = "file")
lsp_make_masked_frame :: proc(text: string, mask: [4]byte) -> [dynamic]byte {
	n := len(text)
	out := make([dynamic]byte)
	append(&out, 0x81)
	switch {
	case n <= 125:
		append(&out, byte(0x80 | n))
	case n <= 65535:
		append(&out, byte(0x80 | 126), byte((n >> 8) & 0xff), byte(n & 0xff))
	case:
		append(&out, byte(0x80 | 127))
		for i in 0 ..< 8 do append(&out, byte((u64(n) >> uint(8 * (7 - i))) & 0xff))
	}
	append(&out, mask[0], mask[1], mask[2], mask[3])
	for i in 0 ..< n do append(&out, text[i] ~ mask[i % 4])
	return out
}

// lsp_make_masked_fragment builds one frame of a FRAGMENTED message with the
// opcode and FIN bit chosen explicitly, which lsp_make_masked_frame (always
// 0x81 = FIN + text) cannot express. This is what Chromium actually puts on the
// wire for a large send(): opcode 0x1 with FIN clear, then 0x0 continuations.
@(private = "file")
lsp_make_masked_fragment :: proc(text: string, mask: [4]byte, opcode: byte, fin: bool) -> [dynamic]byte {
	n := len(text)
	out := make([dynamic]byte)
	append(&out, (0x80 if fin else 0x00) | opcode)
	switch {
	case n <= 125:
		append(&out, byte(0x80 | n))
	case n <= 65535:
		append(&out, byte(0x80 | 126), byte((n >> 8) & 0xff), byte(n & 0xff))
	case:
		append(&out, byte(0x80 | 127))
		for i in 0 ..< 8 do append(&out, byte((u64(n) >> uint(8 * (7 - i))) & 0xff))
	}
	append(&out, mask[0], mask[1], mask[2], mask[3])
	for i in 0 ..< n do append(&out, text[i] ~ mask[i % 4])
	return out
}

@(test)
test_lsp_ws_take_frame_reassembles_a_fragmented_message :: proc(t: ^testing.T) {
	// REQ-LSP-RLY-3. THE EXACT SHAPE MEASURED FROM ELECTRON 43.6.0: a first frame
	// with opcode 0x1 and FIN CLEAR, then a 0x0 continuation carrying FIN.
	//
	// Before the fix this did not merely fail, it failed in two stages: frame 1
	// passed the opcode check and was handed back as a COMPLETE message (so
	// truncated JSON went to the bridge), and frame 2 then killed the session.
	reader := Lsp_WS_Reader{}
	defer lsp_ws_reader_destroy(&reader)

	head := "{\"type\":\"send\",\"message\":\"first-half"
	tail := "second-half\"}"
	f1 := lsp_make_masked_fragment(head, {0x0a, 0x0b, 0x0c, 0x0d}, 0x1, false)
	defer delete(f1)
	f2 := lsp_make_masked_fragment(tail, {0x11, 0x22, 0x33, 0x44}, 0x0, true)
	defer delete(f2)

	// Frame 1 alone must yield NOTHING — not a truncated message, and not a fatal.
	append(&reader.pending, ..f1[:])
	_, ok1, fatal1 := lsp_ws_take_frame(&reader)
	testing.expect(t, !ok1, "a FIN-clear first fragment must not be returned as a whole message")
	testing.expect(t, !fatal1, "a fragmented message must not be fatal")

	// The continuation completes it; the two halves must come back JOINED.
	append(&reader.pending, ..f2[:])
	text, ok2, fatal2 := lsp_ws_take_frame(&reader)
	testing.expect(t, ok2, "the FIN continuation must complete the message")
	testing.expect(t, !fatal2)
	expected := strings.concatenate({head, tail})
	defer delete(expected)
	testing.expect_value(t, text, expected)
	delete(text)
	testing.expect_value(t, len(reader.pending), 0)
	testing.expect(t, !reader.assembling, "the reader must be ready for the next message")
}

@(test)
test_lsp_ws_take_frame_reassembles_many_fragments_across_recvs :: proc(t: ^testing.T) {
	// Electron produced 132 frames for a 16MB message, and they do NOT arrive in
	// one recv. Each fragment is appended separately here so the "need more bytes"
	// path runs between every one — the partial must survive across calls.
	reader := Lsp_WS_Reader{}
	defer lsp_ws_reader_destroy(&reader)

	parts := [?]string{"alpha-", "beta-", "gamma-", "delta"}
	for part, i in parts {
		is_last := i == len(parts) - 1
		opcode: byte = 0x1 if i == 0 else 0x0
		f := lsp_make_masked_fragment(part, {byte(i + 1), 2, 3, 4}, opcode, is_last)
		defer delete(f)
		append(&reader.pending, ..f[:])

		text, ok, fatal := lsp_ws_take_frame(&reader)
		testing.expect(t, !fatal, "no fragment may be fatal")
		if is_last {
			testing.expect(t, ok, "the final fragment must complete the message")
			testing.expect_value(t, text, "alpha-beta-gamma-delta")
			delete(text)
		} else {
			testing.expect(t, !ok, "a non-final fragment must yield no message")
		}
	}
	testing.expect_value(t, len(reader.pending), 0)
}

@(test)
test_lsp_ws_take_frame_reads_fragments_coalesced_in_one_recv :: proc(t: ^testing.T) {
	// The opposite arrival pattern: every fragment already sitting in pending.
	// One take must walk them all and return the single joined message.
	reader := Lsp_WS_Reader{}
	defer lsp_ws_reader_destroy(&reader)
	f1 := lsp_make_masked_fragment("one-", {1, 2, 3, 4}, 0x1, false)
	defer delete(f1)
	f2 := lsp_make_masked_fragment("two-", {5, 6, 7, 8}, 0x0, false)
	defer delete(f2)
	f3 := lsp_make_masked_fragment("three", {9, 10, 11, 12}, 0x0, true)
	defer delete(f3)
	append(&reader.pending, ..f1[:])
	append(&reader.pending, ..f2[:])
	append(&reader.pending, ..f3[:])

	text, ok, fatal := lsp_ws_take_frame(&reader)
	testing.expect(t, ok)
	testing.expect(t, !fatal)
	testing.expect_value(t, text, "one-two-three")
	delete(text)
}

@(test)
test_lsp_ws_take_frame_still_reads_an_unfragmented_message :: proc(t: ^testing.T) {
	// The fast path must be untouched: a lone FIN+text frame is still one message,
	// and the reader must not think a fragmented message is open afterwards.
	reader := Lsp_WS_Reader{}
	defer lsp_ws_reader_destroy(&reader)
	f := lsp_make_masked_frame("{\"n\":1}", {1, 2, 3, 4})
	defer delete(f)
	append(&reader.pending, ..f[:])

	text, ok, fatal := lsp_ws_take_frame(&reader)
	testing.expect(t, ok)
	testing.expect(t, !fatal)
	testing.expect_value(t, text, "{\"n\":1}")
	delete(text)
	testing.expect(t, !reader.assembling)
	testing.expect_value(t, len(reader.message), 0)
}

@(test)
test_lsp_ws_take_frame_rejects_a_continuation_with_nothing_to_continue :: proc(t: ^testing.T) {
	// A 0x0 frame outside a fragmented message is a protocol violation. It must be
	// fatal — NOT silently started as if it were a new message.
	reader := Lsp_WS_Reader{}
	defer lsp_ws_reader_destroy(&reader)
	f := lsp_make_masked_fragment("orphan", {1, 2, 3, 4}, 0x0, true)
	defer delete(f)
	append(&reader.pending, ..f[:])

	_, ok, fatal := lsp_ws_take_frame(&reader)
	testing.expect(t, !ok)
	testing.expect(t, fatal, "a continuation with no message open must end the session")
}

@(test)
test_lsp_ws_take_frame_rejects_a_new_text_frame_mid_message :: proc(t: ^testing.T) {
	// Interleaving a fresh text frame into an open fragmented message is illegal.
	// Accepting it would silently discard the half-built message.
	reader := Lsp_WS_Reader{}
	defer lsp_ws_reader_destroy(&reader)
	f1 := lsp_make_masked_fragment("head", {1, 2, 3, 4}, 0x1, false)
	defer delete(f1)
	f2 := lsp_make_masked_fragment("interloper", {5, 6, 7, 8}, 0x1, true)
	defer delete(f2)
	append(&reader.pending, ..f1[:])
	_, ok1, fatal1 := lsp_ws_take_frame(&reader)
	testing.expect(t, !ok1)
	testing.expect(t, !fatal1)

	append(&reader.pending, ..f2[:])
	_, ok2, fatal2 := lsp_ws_take_frame(&reader)
	testing.expect(t, !ok2)
	testing.expect(t, fatal2, "a new text frame during reassembly must end the session")
}

@(test)
test_lsp_ws_take_frame_caps_the_reassembled_size :: proc(t: ^testing.T) {
	// The DoS bound. A client that sends continuations and never sets FIN must not
	// be able to grow reader.message without limit: trading a silent session death
	// for memory exhaustion would be a worse bug than the one being fixed.
	//
	// The cap is checked against the ACCUMULATED total, so this drives the reader
	// with frames that are individually legal and collectively over the line.
	reader := Lsp_WS_Reader{}
	defer lsp_ws_reader_destroy(&reader)

	chunk := strings.repeat("x", 1024 * 1024)
	defer delete(chunk)

	// First fragment opens the message.
	f0 := lsp_make_masked_fragment(chunk, {1, 2, 3, 4}, 0x1, false)
	defer delete(f0)
	append(&reader.pending, ..f0[:])
	_, ok0, fatal0 := lsp_ws_take_frame(&reader)
	testing.expect(t, !ok0)
	testing.expect(t, !fatal0)

	// Feed continuations until the cap trips. It MUST trip, and before the loop
	// runs away: LSP_MAX_MESSAGE_BYTES / 1MiB is 32, so ~32 iterations.
	tripped := false
	for _ in 0 ..< (LSP_MAX_MESSAGE_BYTES / len(chunk)) + 2 {
		f := lsp_make_masked_fragment(chunk, {5, 6, 7, 8}, 0x0, false)
		defer delete(f)
		append(&reader.pending, ..f[:])
		_, ok, fatal := lsp_ws_take_frame(&reader)
		if fatal {
			tripped = true
			break
		}
		testing.expect(t, !ok, "an unterminated fragment must not yield a message")
	}
	testing.expect(t, tripped, "an unbounded fragmented message must be refused, not buffered forever")
}

@(test)
test_lsp_ws_take_frame_reads_a_64bit_length_frame :: proc(t: ^testing.T) {
	// A textDocument/didOpen carrying a large file is exactly this frame. The
	// SHARED reader (bridge_ws_take_frame) treats a 127 length as FATAL, which is
	// why this socket has its own reader.
	big := strings.repeat("x", 70000)
	defer delete(big)
	payload := strings.concatenate({"{\"type\":\"send\",\"message\":\"", big, "\"}"})
	defer delete(payload)

	reader := Lsp_WS_Reader{}
	defer lsp_ws_reader_destroy(&reader)
	frame := lsp_make_masked_frame(payload, {0x0a, 0x0b, 0x0c, 0x0d})
	defer delete(frame)
	append(&reader.pending, ..frame[:])

	text, ok, fatal := lsp_ws_take_frame(&reader)
	testing.expect(t, ok, "a 64-bit length frame must be readable on the lsp socket")
	testing.expect(t, !fatal)
	testing.expect_value(t, len(text), len(payload))
	testing.expect(t, text == payload)
	delete(text)
	testing.expect_value(t, len(reader.pending), 0)
}

@(test)
test_lsp_ws_take_frame_waits_for_a_split_header :: proc(t: ^testing.T) {
	// One recv can end mid-header; that is "need more bytes", never a fatal error.
	reader := Lsp_WS_Reader{}
	defer lsp_ws_reader_destroy(&reader)
	frame := lsp_make_masked_frame("{\"type\":\"ping\"}", {1, 2, 3, 4})
	defer delete(frame)

	append(&reader.pending, frame[0])
	_, ok, fatal := lsp_ws_take_frame(&reader)
	testing.expect(t, !ok, "a one-byte buffer cannot yield a frame")
	testing.expect(t, !fatal, "a split header must not be fatal")

	// Header present but payload still missing.
	append(&reader.pending, ..frame[1:4])
	_, ok2, fatal2 := lsp_ws_take_frame(&reader)
	testing.expect(t, !ok2)
	testing.expect(t, !fatal2)

	// Remainder arrives; now it parses.
	append(&reader.pending, ..frame[4:])
	text, ok3, fatal3 := lsp_ws_take_frame(&reader)
	testing.expect(t, ok3)
	testing.expect(t, !fatal3)
	testing.expect_value(t, text, "{\"type\":\"ping\"}")
	delete(text)
}

@(test)
test_lsp_ws_take_frame_splits_coalesced_frames :: proc(t: ^testing.T) {
	// One recv can carry several messages; each take must return exactly one and
	// leave the rest intact.
	reader := Lsp_WS_Reader{}
	defer lsp_ws_reader_destroy(&reader)
	f1 := lsp_make_masked_frame("{\"n\":1}", {1, 2, 3, 4})
	defer delete(f1)
	f2 := lsp_make_masked_frame("{\"n\":2}", {5, 6, 7, 8})
	defer delete(f2)
	append(&reader.pending, ..f1[:])
	append(&reader.pending, ..f2[:])

	t1, ok1, _ := lsp_ws_take_frame(&reader)
	testing.expect(t, ok1)
	testing.expect_value(t, t1, "{\"n\":1}")
	delete(t1)

	t2, ok2, _ := lsp_ws_take_frame(&reader)
	testing.expect(t, ok2)
	testing.expect_value(t, t2, "{\"n\":2}")
	delete(t2)
	testing.expect_value(t, len(reader.pending), 0)
}

@(test)
test_lsp_ws_take_frame_treats_close_as_fatal :: proc(t: ^testing.T) {
	// The browser closing its tab must end the relay loop (which is what tears the
	// session down and stops the language server), not look like a short read.
	reader := Lsp_WS_Reader{}
	defer lsp_ws_reader_destroy(&reader)
	append(&reader.pending, 0x88, 0x80, 0, 0, 0, 0) // masked close frame
	_, ok, fatal := lsp_ws_take_frame(&reader)
	testing.expect(t, !ok)
	testing.expect(t, fatal, "a close frame must end the session")
}

// --- bridge -> browser translation -------------------------------------------

@(test)
test_lsp_bridge_frame_translates_wire_id_to_client_id :: proc(t: ^testing.T) {
	// The bridge frame carries the Hub's opaque wire id; the browser only knows
	// the id it chose, so the field must be rewritten, not passed through.
	bridge_frame := "{\"type\":\"lsp_data\",\"session_id\":\"lsp_wire_abc\",\"message\":\"{\\\"id\\\":1}\"}"
	out := lsp_bridge_frame_for_client("lsp_data", bridge_frame, "main")
	defer delete(out)

	testing.expect(t, strings.contains(out, "\"type\":\"lsp_data\""))
	testing.expect(t, strings.contains(out, "\"session_id\":\"main\""), "client must see its own session id")
	testing.expect(t, !strings.contains(out, "lsp_wire_abc"), "the internal wire id must never reach the browser")
	// The JSON-RPC payload survives the round trip re-escaped.
	msg := json_string(out, "message")
	defer delete(msg)
	testing.expect_value(t, msg, "{\"id\":1}")
}

@(test)
test_lsp_bridge_frame_carries_each_type_payload :: proc(t: ^testing.T) {
	err_in := "{\"type\":\"lsp_error\",\"session_id\":\"w1\",\"reason\":\"server exited\",\"exit_code\":3}"
	err_out := lsp_bridge_frame_for_client("lsp_error", err_in, "s1")
	defer delete(err_out)
	testing.expect(t, strings.contains(err_out, "\"reason\":\"server exited\""))
	testing.expect(t, strings.contains(err_out, "\"exit_code\":3"))

	started_ok := lsp_bridge_frame_for_client("lsp_started", "{\"type\":\"lsp_started\",\"session_id\":\"w1\",\"ok\":true}", "s1")
	defer delete(started_ok)
	testing.expect(t, strings.contains(started_ok, "\"ok\":true"))

	started_root := lsp_bridge_frame_for_client("lsp_started", "{\"type\":\"lsp_started\",\"session_id\":\"w1\",\"ok\":true,\"root_path\":\"/workspace/myproject\"}", "s1")
	defer delete(started_root)
	testing.expect(t, strings.contains(started_root, "\"ok\":true"))
	testing.expect(t, strings.contains(started_root, "\"root_path\":\"/workspace/myproject\""))

	started_bad := lsp_bridge_frame_for_client("lsp_started", "{\"type\":\"lsp_started\",\"session_id\":\"w1\",\"ok\":false,\"error\":{\"code\":\"internal_error\",\"class\":\"retriable\",\"cause\":\"lsp_start_failed\",\"message\":\"process_start failed\"}}", "s1")
	defer delete(started_bad)
	testing.expect(t, strings.contains(started_bad, "\"ok\":false"))
	testing.expect(t, strings.contains(started_bad, "\"cause\":\"lsp_start_failed\""))
	testing.expect(t, strings.contains(started_bad, "\"message\":\"process_start failed\""))

	stopped := lsp_bridge_frame_for_client("lsp_stopped", "{\"type\":\"lsp_stopped\",\"session_id\":\"w1\"}", "s1")
	defer delete(stopped)
	testing.expect(t, strings.contains(stopped, "\"type\":\"lsp_stopped\""))
	testing.expect(t, strings.contains(stopped, "\"session_id\":\"s1\""))
}

@(test)
test_lsp_forward_drops_frames_for_unknown_sessions :: proc(t: ^testing.T) {
	// A server can still be talking when its socket has already gone. That frame
	// has nowhere to go and must be dropped, not delivered to some other session.
	reg := Lsp_Session_Registry{}
	defer {
		delete(reg.by_wire)
		delete(reg.by_owner)
	}
	delivered := lsp_forward_bridge_frame(&reg, "lsp_data", "{\"session_id\":\"gone\",\"message\":\"x\"}")
	testing.expect(t, !delivered, "a frame for a released session must be dropped")

	// A frame with no session id at all is also dropped rather than broadcast.
	no_id := lsp_forward_bridge_frame(&reg, "lsp_data", "{\"message\":\"x\"}")
	testing.expect(t, !no_id)
}

// --- experiment gate ---------------------------------------------------------

@(private = "file")
Fake_Experiments :: struct {
	key:     string,
	enabled: bool,
	present: bool,
}

@(private = "file")
fake_experiment_list :: proc(ctx: rawptr, owner_user_id: string) -> ([dynamic]domain.Experiment, domain.Domain_Error) {
	f := (^Fake_Experiments)(ctx)
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

@(private = "file")
fake_experiment_repo :: proc(f: ^Fake_Experiments) -> iface.Experiment_Repository {
	return iface.Experiment_Repository{ctx = rawptr(f), list_by_owner = fake_experiment_list}
}

@(test)
test_lsp_experiment_gate_defaults_closed :: proc(t: ^testing.T) {
	// Flag absent entirely => off. A new user must not get the feature by default.
	absent := Fake_Experiments{present = false}
	repo_absent := fake_experiment_repo(&absent)
	testing.expect(t, !lsp_experiment_enabled(&repo_absent, "user_a"), "absent flag must read as off")

	// Present but disabled => off.
	off := Fake_Experiments{key = "lsp", enabled = false, present = true}
	repo_off := fake_experiment_repo(&off)
	testing.expect(t, !lsp_experiment_enabled(&repo_off, "user_a"))

	// A DIFFERENT enabled experiment must not open the lsp gate.
	other := Fake_Experiments{key = "something_else", enabled = true, present = true}
	repo_other := fake_experiment_repo(&other)
	testing.expect(t, !lsp_experiment_enabled(&repo_other, "user_a"), "another flag must not enable lsp")

	// Present and enabled => on.
	on := Fake_Experiments{key = "lsp", enabled = true, present = true}
	repo_on := fake_experiment_repo(&on)
	testing.expect(t, lsp_experiment_enabled(&repo_on, "user_a"))

	// An unconfigured repository must fail closed rather than crash.
	empty := iface.Experiment_Repository{}
	testing.expect(t, !lsp_experiment_enabled(&empty, "user_a"), "a missing repo must fail closed")
}

// --- config resolution: the client never supplies cmd ------------------------

@(private = "file")
Fake_Configs :: struct {
	rows: [dynamic]domain.Lsp_Server_Config,
}

@(private = "file")
fake_config_list :: proc(ctx: rawptr, owner_user_id, bridge_id: string) -> ([dynamic]domain.Lsp_Server_Config, domain.Domain_Error) {
	f := (^Fake_Configs)(ctx)
	out := make([dynamic]domain.Lsp_Server_Config)
	for r in f.rows {
		if r.bridge_id != bridge_id do continue
		append(&out, lsp_server_config_clone(r))
	}
	return out, domain.Domain_Error{}
}

@(private = "file")
fake_config_repo :: proc(f: ^Fake_Configs) -> iface.Lsp_Server_Config_Repository {
	return iface.Lsp_Server_Config_Repository{ctx = rawptr(f), list_by_bridge = fake_config_list}
}

@(test)
test_lsp_resolve_server_picks_the_longest_matching_prefix :: proc(t: ^testing.T) {
	f := Fake_Configs{rows = make([dynamic]domain.Lsp_Server_Config)}
	defer {
		for r in f.rows do domain.lsp_server_config_destroy(r)
		delete(f.rows)
	}
	append(&f.rows, lsp_server_config_clone(domain.Lsp_Server_Config{
		config_id = "c_default", bridge_id = "brg1", language = "go",
		cmd = "gopls", args = "", dir_prefix = "",
	}))
	append(&f.rows, lsp_server_config_clone(domain.Lsp_Server_Config{
		config_id = "c_scoped", bridge_id = "brg1", language = "go",
		cmd = "gopls-experimental", args = "-rpc.trace", dir_prefix = "/work/exp",
	}))
	// A config for another language must never be chosen for go.
	append(&f.rows, lsp_server_config_clone(domain.Lsp_Server_Config{
		config_id = "c_rust", bridge_id = "brg1", language = "rust",
		cmd = "rust-analyzer", args = "", dir_prefix = "/work/exp",
	}))
	repo := fake_config_repo(&f)

	scoped, ok1 := lsp_resolve_server(&repo, "user_a", "brg1", "go", "/work/exp/main.go")
	testing.expect(t, ok1)
	defer domain.lsp_server_config_destroy(scoped)
	testing.expect_value(t, scoped.cmd, "gopls-experimental")
	testing.expect_value(t, scoped.args, "-rpc.trace")

	// Path-boundary: /work/experiment must NOT match the /work/exp prefix.
	fallback, ok2 := lsp_resolve_server(&repo, "user_a", "brg1", "go", "/work/experiment/main.go")
	testing.expect(t, ok2)
	defer domain.lsp_server_config_destroy(fallback)
	testing.expect_value(t, fallback.cmd, "gopls")

	// No config for the language at all => no start.
	_, ok3 := lsp_resolve_server(&repo, "user_a", "brg1", "python", "/work/exp/main.py")
	testing.expect(t, !ok3, "an unconfigured language must not resolve")

	// A bridge with no configs => no start.
	_, ok4 := lsp_resolve_server(&repo, "user_a", "brg_other", "go", "/work/exp/main.go")
	testing.expect(t, !ok4)
}

@(test)
test_lsp_working_dir_prefers_config_prefix_then_file_dir :: proc(t: ^testing.T) {
	scoped := domain.Lsp_Server_Config{dir_prefix = "/work/exp"}
	d1 := lsp_working_dir(scoped, "/work/exp/pkg/main.go")
	defer delete(d1)
	testing.expect_value(t, d1, "/work/exp")

	// No prefix configured: fall back to the directory holding the file.
	plain := domain.Lsp_Server_Config{dir_prefix = ""}
	d2 := lsp_working_dir(plain, "/work/other/pkg/main.go")
	defer delete(d2)
	testing.expect_value(t, d2, "/work/other/pkg")

	// Root path provided when dir_prefix is empty: uses root_path (e.g. project workspace root).
	d_root := lsp_working_dir(plain, "/work/other/pkg/main.go", "/work/other")
	defer delete(d_root)
	testing.expect_value(t, d_root, "/work/other")

	// Explicit dir_prefix still overrides root_path when configured.
	d_scoped_root := lsp_working_dir(scoped, "/work/exp/pkg/main.go", "/workspace")
	defer delete(d_scoped_root)
	testing.expect_value(t, d_scoped_root, "/work/exp")

	// A bare filename has no directory; must not slice out of bounds.
	d3 := lsp_working_dir(plain, "main.go")
	defer delete(d3)
	testing.expect_value(t, d3, "")

	// A file at the root likewise.
	d4 := lsp_working_dir(plain, "/main.go")
	defer delete(d4)
	testing.expect_value(t, d4, "")
}

@(test)
test_lsp_registry_mark_stopped_clears_started :: proc(t: ^testing.T) {
	// After an explicit client "stop" the entry must no longer look like a live
	// session on that bridge, or a later bridge disconnect would tear down a
	// session the user had already stopped.
	reg := Lsp_Session_Registry{}
	defer {
		delete(reg.by_wire)
		delete(reg.by_owner)
	}
	_, ok := lsp_registry_claim(&reg, "user_a", "s1", "w1", net.TCP_Socket(0))
	testing.expect(t, ok)
	lsp_registry_mark_started(&reg, "w1", "brg_one")

	lsp_registry_mark_stopped(&reg, "w1")
	// A disconnect of that same bridge must now find nothing to wake.
	testing.expect_value(t, lsp_registry_wake_bridge_sessions(&reg, "brg_one"), 0)
	testing.expect(t, !lsp_session_closing(&reg, "w1"))

	lsp_registry_release(&reg, "w1")
}
