package ws

import base64 "core:encoding/base64"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
make_test_pair :: proc(t: ^testing.T) -> (client: net.TCP_Socket, server: net.TCP_Socket) {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	testing.expect_value(t, listen_err, nil)
	bound, bound_err := net.bound_endpoint(listener)
	testing.expect_value(t, bound_err, nil)
	c, dial_err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	testing.expect_value(t, dial_err, nil)
	s, _, accept_err := net.accept_tcp(listener)
	testing.expect_value(t, accept_err, nil)
	net.close(listener)
	return c, s
}

@(test)
test_frame_reader_single_and_pipelined :: proc(t: ^testing.T) {
	reader := reader_make()
	defer reader_destroy(&reader)

	// Single frame
	msg1 := `{"type":"hello"}`
	append(&reader.pending, 0x81, byte(len(msg1)))
	append(&reader.pending, ..transmute([]u8)msg1)

	// Second frame pipelined immediately
	msg2 := `{"type":"world"}`
	append(&reader.pending, 0x81, byte(len(msg2)))
	append(&reader.pending, ..transmute([]u8)msg2)

	op1, text1, has1, ok1 := take_frame(&reader)
	testing.expect(t, ok1)
	testing.expect(t, has1)
	testing.expect_value(t, op1, u8(0x1))
	testing.expect_value(t, text1, msg1)
	delete(text1)

	op2, text2, has2, ok2 := take_frame(&reader)
	testing.expect(t, ok2)
	testing.expect(t, has2)
	testing.expect_value(t, op2, u8(0x1))
	testing.expect_value(t, text2, msg2)
	delete(text2)

	// No more frames
	_, _, has3, ok3 := take_frame(&reader)
	testing.expect(t, ok3)
	testing.expect(t, !has3)
}

@(test)
test_frame_reader_continuation_reassembly :: proc(t: ^testing.T) {
	reader := reader_make()
	defer reader_destroy(&reader)

	head := `{"part":1,`
	tail := `"part":2}`
	// Frame 1: text opcode 0x1, FIN = false
	append(&reader.pending, 0x01, byte(len(head)))
	append(&reader.pending, ..transmute([]u8)head)

	// Calling take_frame after frame 1 must wait for continuation
	_, _, has1, ok1 := take_frame(&reader)
	testing.expect(t, ok1)
	testing.expect(t, !has1)
	testing.expect(t, reader.fragmenting)

	// Frame 2: continuation opcode 0x0, FIN = true
	append(&reader.pending, 0x80, byte(len(tail)))
	append(&reader.pending, ..transmute([]u8)tail)

	op, text, has2, ok2 := take_frame(&reader)
	testing.expect(t, ok2)
	testing.expect(t, has2)
	testing.expect_value(t, op, u8(0x1))
	expected := strings.concatenate({head, tail})
	defer delete(expected)
	testing.expect_value(t, text, expected)
	delete(text)
	testing.expect(t, !reader.fragmenting)
}

@(test)
test_frame_reader_control_frame_interleaved :: proc(t: ^testing.T) {
	reader := reader_make()
	defer reader_destroy(&reader)

	head := `fragment-one`
	// Frame 1: text, FIN=false
	append(&reader.pending, 0x01, byte(len(head)))
	append(&reader.pending, ..transmute([]u8)head)

	_, _, has1, ok1 := take_frame(&reader)
	testing.expect(t, ok1)
	testing.expect(t, !has1)
	testing.expect(t, reader.fragmenting)

	// Ping frame interleaved mid-fragmentation: opcode 0x9, FIN=true, payload "ping"
	append(&reader.pending, 0x89, 4, 'p', 'i', 'n', 'g')

	op, ping_payload, has_ping, ok_ping := take_frame(&reader)
	testing.expect(t, ok_ping)
	testing.expect(t, has_ping)
	testing.expect_value(t, op, u8(0x9))
	testing.expect_value(t, ping_payload, "ping")
	delete(ping_payload)
	testing.expect(t, reader.fragmenting, "reader remains fragmenting across control frame")
}

@(test)
test_frame_reader_read_text_blocking_handles_ping :: proc(t: ^testing.T) {
	client, server := make_test_pair(t)
	defer {
		net.close(client)
		net.close(server)
	}

	reader := reader_make()
	defer reader_destroy(&reader)

	// Server sends ping frame
	ping_frame := [6]u8{0x89, 4, 't', 'e', 's', 't'}
	_, _ = net.send_tcp(server, ping_frame[:])

	// Server sends text frame
	text_msg := `{"msg":"after ping"}`
	text_frame := make([]u8, 2 + len(text_msg))
	defer delete(text_frame)
	text_frame[0] = 0x81
	text_frame[1] = byte(len(text_msg))
	copy(text_frame[2:], transmute([]u8)text_msg)
	_, _ = net.send_tcp(server, text_frame[:])

	received, ok := read_text_blocking(client, &reader, 2 * time.Second)
	testing.expect(t, ok)
	testing.expect_value(t, received, text_msg)
	delete(received)

	// Verify server received pong frame (opcode 0x8A)
	pong_buf: [2]u8
	n, err := net.recv_tcp(server, pong_buf[:])
	testing.expect_value(t, err, nil)
	testing.expect_value(t, n, 2)
	testing.expect_value(t, pong_buf[0], u8(0x8A))
	testing.expect_value(t, pong_buf[1], u8(0x00))
}

@(test)
test_chunk_frames_and_reassembly_round_trip :: proc(t: ^testing.T) {
	large_data := strings.repeat("large-payload-content-1234567890\n", 2500) // ~82.5 KB
	defer delete(large_data)

	payload_size := 16 * 1024
	frames := chunk_frames(large_data, payload_size, "test_chunk_seq")
	testing.expect(t, frames != nil)
	defer {
		for f in frames do delete(f)
		delete(frames)
	}

	testing.expect(t, len(frames) > 1)
	for f in frames {
		testing.expect(t, frame_is_chunk(f))
	}

	reassemblies := make([dynamic]Chunk_Reassembly)
	defer chunk_reassemblies_free(&reassemblies)

	// Ingest all frames up to second-to-last
	for i in 0 ..< len(frames) - 1 {
		outcome, full := reassemble_chunk_outcome(&reassemblies, frames[i])
		testing.expect_value(t, outcome, Chunk_Outcome.Absorbed)
		testing.expect_value(t, full, "")
	}

	// Ingest last frame
	outcome, full := reassemble_chunk_outcome(&reassemblies, frames[len(frames) - 1])
	testing.expect_value(t, outcome, Chunk_Outcome.Completed)
	defer delete(full)
	testing.expect_value(t, full, large_data)
}

@(test)
test_send_text_accepts_64bit_length_and_rejects_over_max_payload :: proc(t: ^testing.T) {
	client, server := make_test_pair(t)
	defer {
		net.close(client)
		net.close(server)
	}

	conn := Connection{
		socket    = client,
		secure    = false,
		connected = true,
	}

	payload_70k := make([]byte, 70_000)
	defer delete(payload_70k)
	for i in 0 ..< len(payload_70k) {
		payload_70k[i] = 'a'
	}

	sent := send_text(&conn, string(payload_70k))
	testing.expect(t, sent, "ws.send_text must accept a 70,000-byte payload using 64-bit extended length")

	oversized := strings.repeat("x", WS_MAX_SERVER_PAYLOAD + 1)
	defer delete(oversized)
	sent_oversized := send_text(&conn, oversized)
	testing.expect(t, !sent_oversized, "ws.send_text must reject a payload exceeding WS_MAX_SERVER_PAYLOAD")
}

@(test)
test_poll_text_decodes_64bit_length_frame :: proc(t: ^testing.T) {
	client, server := make_test_pair(t)
	defer {
		net.close(client)
		net.close(server)
	}

	conn := Connection{
		socket        = client,
		secure        = false,
		connected     = true,
		pending_texts = make([dynamic]string),
		pending_bytes = make([dynamic]byte),
	}
	defer {
		for s in conn.pending_texts do delete(s)
		delete(conn.pending_texts)
		delete(conn.pending_bytes)
		delete(conn.fragmented)
	}

	payload_70k := make([]byte, 70_000)
	defer delete(payload_70k)
	for i in 0 ..< len(payload_70k) {
		payload_70k[i] = 'b'
	}

	append(&conn.pending_bytes, 0x81, 127, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x11, 0x70)
	append(&conn.pending_bytes, ..payload_70k[:69_999])

	last_byte := [1]byte{payload_70k[69_999]}
	_, send_err := net.send_tcp(server, last_byte[:])
	testing.expect_value(t, send_err, nil)

	text, poll_ok := poll_text(&conn)
	defer delete(text)
	testing.expect(t, poll_ok, "ws.poll_text must decode a 70,000-byte 64-bit length frame intact")
	testing.expect_value(t, len(text), 70_000)
	testing.expect_value(t, text, string(payload_70k))
	testing.expect(t, conn.connected, "ws.poll_text must keep conn.connected = true on valid 64-bit frame")
}

@(test)
test_poll_text_reassembles_fragmented_frames :: proc(t: ^testing.T) {
	client, server := make_test_pair(t)
	defer {
		net.close(client)
		net.close(server)
	}
	_ = net.set_blocking(client, false)

	conn := Connection{
		socket        = client,
		secure        = false,
		connected     = true,
		pending_texts = make([dynamic]string),
		pending_bytes = make([dynamic]byte, 0, 64),
	}
	defer {
		for s in conn.pending_texts do delete(s)
		delete(conn.pending_texts)
		delete(conn.pending_bytes)
		delete(conn.fragmented)
	}

	frag1_payload := `{"part":1`
	frag2_payload := `,"part2":2}`

	append(&conn.pending_bytes, 0x01, byte(len(frag1_payload)))
	append(&conn.pending_bytes, ..transmute([]byte)frag1_payload)

	append(&conn.pending_bytes, 0x80, byte(len(frag2_payload)))
	append(&conn.pending_bytes, ..transmute([]byte)frag2_payload[:len(frag2_payload) - 1])

	last_byte := [1]byte{frag2_payload[len(frag2_payload) - 1]}
	_, send_err := net.send_tcp(server, last_byte[:])
	testing.expect_value(t, send_err, nil)

	text1, ok1 := poll_text(&conn)
	defer delete(text1)

	testing.expect(t, ok1, "poll_text must successfully reassemble fragmented frames")
	testing.expect_value(t, text1, `{"part":1,"part2":2}`)
	testing.expect_value(t, len(conn.pending_texts), 0)
	testing.expect_value(t, len(conn.pending_bytes), 0)
}

@(test)
test_poll_text_shifts_pending_bytes_without_leak :: proc(t: ^testing.T) {
	client, server := make_test_pair(t)
	defer {
		net.close(client)
		net.close(server)
	}

	payload := `{"type":"ack","ok":true}`
	frame := make([]byte, 2 + len(payload))
	defer delete(frame)
	frame[0] = 0x81
	frame[1] = byte(len(payload))
	copy(frame[2:], transmute([]byte)payload)

	_, send_err := net.send_tcp(server, frame)
	testing.expect_value(t, send_err, nil)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	{
		context.allocator = mem.tracking_allocator(&track)
		conn := Connection{
			socket    = client,
			secure    = false,
			connected = true,
		}

		text, poll_ok := poll_text(&conn)
		testing.expect(t, poll_ok, "ws.poll_text must decode a valid unmasked text frame")
		testing.expect_value(t, text, payload)

		delete(text)
		close(&conn)
	}

	testing.expect_value(t, len(track.allocation_map), 0)
}
