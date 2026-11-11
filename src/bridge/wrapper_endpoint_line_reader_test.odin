package main

// Tests for the Bridge's receive buffers (wrapper_endpoint.odin Bridge_Line_Reader and
// main.odin read_http_request).
//
// Both used to do `x = strings.concatenate({x, chunk})` per read and never free the old
// copy: a 20 MiB ham-ctl line copied and leaked ~22 GiB. These tests pin the fix:
//   1. A multi-MiB line fed in 8 KiB reads parses intact, with total allocation linear
//      in the line size and nothing left behind.
//   2. Lines split across reads, several lines per read, and the HTTP first-line peek
//      behave exactly as the old string slicing did.
//   3. The wrapper TCP loop end to end: a multi-MiB JSONL line and the line after it
//      both get answered.
//   4. read_http_request reassembles a fragmented head + body and frees cleanly.

import "core:mem"
import "core:net"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

@(private = "file")
LINE_READER_BIG_LINE_BYTES :: 4 * 1024 * 1024

@(private = "file")
line_reader_feed :: proc(r: ^Bridge_Line_Reader, data: string, chunk: int) -> bool {
	for off := 0; off < len(data); off += chunk {
		if !bridge_line_reader_append(r, transmute([]u8)data[off:min(off + chunk, len(data))]) do return false
	}
	return true
}

@(test)
line_reader_multi_mib_line_is_linear_and_leak_free :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	// Built outside the tracked region so only the reader's own allocations count.
	payload := strings.repeat("x", LINE_READER_BIG_LINE_BYTES)
	defer delete(payload)
	data := strings.concatenate({`{"id":"big","pad":"`, payload, `"}`, "\n", `{"id":"next"}`, "\n", "partial"})
	defer delete(data)

	{
		context.allocator = mem.tracking_allocator(&track)
		r: Bridge_Line_Reader
		lines := 0
		for off := 0; off < len(data); off += 8192 {
			testing.expect(t, bridge_line_reader_append(&r, transmute([]u8)data[off:min(off + 8192, len(data))]))
			for line in bridge_line_reader_next(&r) {
				switch lines {
				case 0:
					testing.expect_value(t, len(line), LINE_READER_BIG_LINE_BYTES + len(`{"id":"big","pad":""}`))
					testing.expect(t, strings.has_prefix(line, `{"id":"big","pad":"xxx`))
					testing.expect(t, strings.has_suffix(line, `xxx"}`))
				case 1:
					testing.expect_value(t, line, `{"id":"next"}`)
				}
				lines += 1
			}
		}
		testing.expect_value(t, lines, 2)
		testing.expect_value(t, bridge_line_reader_pending(&r), "partial")
		bridge_line_reader_destroy(&r)
	}

	// Amortized growth: the old loop allocated ~n^2/16 KiB (~1 GiB for 4 MiB) and
	// held every copy. Doubling growth totals < 2n, and the peak is old + new buffer.
	testing.expectf(t, track.total_memory_allocated < 4 * LINE_READER_BIG_LINE_BYTES, "total allocated %d", track.total_memory_allocated)
	testing.expectf(t, track.peak_memory_allocated < 4 * LINE_READER_BIG_LINE_BYTES, "peak %d", track.peak_memory_allocated)
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

@(test)
line_reader_splits_and_peek_match_string_slicing :: proc(t: ^testing.T) {
	r: Bridge_Line_Reader
	defer bridge_line_reader_destroy(&r)

	// The HTTP sniff peeks the first line without consuming it; the proxy then gets
	// every unconsumed byte, first line included.
	testing.expect(t, line_reader_feed(&r, "GET /proxy/s1/ HTTP/1.1\r", 5))
	_, ok := bridge_line_reader_peek(&r)
	testing.expect(t, !ok)
	testing.expect(t, line_reader_feed(&r, "\nHost: x\r\n", 3))
	first, first_ok := bridge_line_reader_peek(&r)
	testing.expect(t, first_ok)
	testing.expect_value(t, strings.trim_space(first), "GET /proxy/s1/ HTTP/1.1")
	testing.expect_value(t, bridge_line_reader_pending(&r), "GET /proxy/s1/ HTTP/1.1\r\nHost: x\r\n")

	// Peek then next yields the same line once; several lines in one read; empty lines.
	line, line_ok := bridge_line_reader_next(&r)
	testing.expect(t, line_ok)
	testing.expect_value(t, line, "GET /proxy/s1/ HTTP/1.1\r")
	testing.expect(t, bridge_line_reader_append(&r, transmute([]u8)string("a\n\nb\nc")))
	got: [dynamic]string
	defer delete(got)
	for l in bridge_line_reader_next(&r) do append(&got, strings.clone(l, context.temp_allocator))
	testing.expect_value(t, len(got), 4)
	if len(got) == 4 {
		testing.expect_value(t, got[0], "Host: x\r")
		testing.expect_value(t, got[1], "a")
		testing.expect_value(t, got[2], "")
		testing.expect_value(t, got[3], "b")
	}
	// The unconsumed tail survives compaction on the next append.
	testing.expect(t, bridge_line_reader_append(&r, transmute([]u8)string("d\n")))
	testing.expect_value(t, r.start, 0)
	tail, tail_ok := bridge_line_reader_next(&r)
	testing.expect(t, tail_ok)
	testing.expect_value(t, tail, "cd")
	testing.expect_value(t, bridge_line_reader_pending(&r), "")
}

@(test)
line_reader_refuses_a_line_past_the_cap :: proc(t: ^testing.T) {
	r: Bridge_Line_Reader
	defer bridge_line_reader_destroy(&r)
	chunk := make([]u8, 8 * 1024 * 1024)
	defer delete(chunk)
	for _ in 0 ..< BRIDGE_LOCAL_ENDPOINT_MAX_LINE_BYTES / len(chunk) {
		testing.expect(t, bridge_line_reader_append(&r, chunk))
	}
	testing.expect(t, !bridge_line_reader_append(&r, chunk[:1]), "one byte past the cap must be refused")
	testing.expect_value(t, len(r.buf), BRIDGE_LOCAL_ENDPOINT_MAX_LINE_BYTES)
}

@(private = "file")
Line_Reader_Pair :: struct {
	listener: net.TCP_Socket,
	server:   net.TCP_Socket,
	peer:     net.TCP_Socket,
}

@(private = "file")
line_reader_pair_open :: proc(t: ^testing.T) -> (pair: Line_Reader_Pair) {
	le: net.Network_Error
	pair.listener, le = net.listen_tcp({address = net.IP4_Loopback, port = 0})
	if le != nil do testing.fail_now(t, "listen")
	bound, _ := net.bound_endpoint(pair.listener)
	pe: net.Network_Error
	pair.peer, pe = net.dial_tcp(bound)
	if pe != nil do testing.fail_now(t, "dial")
	ae: net.Network_Error
	pair.server, _, ae = net.accept_tcp(pair.listener)
	if ae != nil do testing.fail_now(t, "accept")
	_ = net.set_option(pair.peer, .Receive_Timeout, 10 * time.Second)
	_ = net.set_option(pair.server, .Receive_Timeout, 10 * time.Second)
	return
}

@(private = "file")
line_reader_read_lines :: proc(sock: net.TCP_Socket, want: int) -> [dynamic]string {
	out: [dynamic]string
	r: Bridge_Line_Reader
	defer bridge_line_reader_destroy(&r)
	buf: [4096]u8
	for len(out) < want {
		n, err := net.recv_tcp(sock, buf[:])
		if err != nil || n <= 0 do break
		if !bridge_line_reader_append(&r, buf[:n]) do break
		for line in bridge_line_reader_next(&r) do append(&out, strings.clone(line, context.temp_allocator))
	}
	return out
}

@(test)
wrapper_tcp_loop_answers_a_multi_mib_line_and_the_next :: proc(t: ^testing.T) {
	pair := line_reader_pair_open(t)
	defer net.close(pair.listener)
	// The client thread owns pair.server and closes it when the peer goes away.
	worker := thread.create_and_start_with_poly_data(pair.server, bridge_local_endpoint_client_thread)
	defer {
		net.close(pair.peer)
		thread.join(worker)
		thread.destroy(worker)
	}

	payload := strings.repeat("y", LINE_READER_BIG_LINE_BYTES)
	defer delete(payload)
	// v:2 is answered with bad_version before any token or method lookup, so the
	// response proves the line arrived whole (its id sits after the payload).
	big := strings.concatenate({`{"v":2,"pad":"`, payload, `","id":"big"}`, "\n", `{"v":2,"id":"next"}`, "\n"})
	defer delete(big)
	testing.expect(t, bridge_tcp_send_all(pair.peer, transmute([]u8)big))

	lines := line_reader_read_lines(pair.peer, 2)
	defer delete(lines)
	testing.expect_value(t, len(lines), 2)
	if len(lines) == 2 {
		testing.expectf(t, strings.contains(lines[0], `"big"`) && strings.contains(lines[0], "bad_version"), "first response: %s", lines[0])
		testing.expectf(t, strings.contains(lines[1], `"next"`) && strings.contains(lines[1], "bad_version"), "second response: %s", lines[1])
	}
}

@(private = "file")
Http_Fragment_Sender :: struct {
	sock:  net.TCP_Socket,
	parts: []string,
}

@(test)
read_http_request_reassembles_fragments_and_frees :: proc(t: ^testing.T) {
	pair := line_reader_pair_open(t)
	defer net.close(pair.listener)
	defer net.close(pair.peer)
	defer net.close(pair.server)

	body := strings.repeat("b", 70000)
	defer delete(body)
	// The CRLFCRLF terminator is split across reads, and the body arrives in pieces.
	sender := Http_Fragment_Sender{sock = pair.peer, parts = []string{
		"POST /api/v1/x HTTP/1.1\r\nContent-Length: 70000\r",
		"\n\r",
		"\n",
		body[:30000],
		body[30000:],
	}}
	worker := thread.create_and_start_with_poly_data(&sender, proc(s: ^Http_Fragment_Sender) {
		for part in s.parts {
			_ = bridge_tcp_send_all(s.sock, transmute([]u8)part)
			time.sleep(20 * time.Millisecond)
		}
	})
	defer {
		thread.join(worker)
		thread.destroy(worker)
	}

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		request, ok := read_http_request(pair.server)
		testing.expect(t, ok)
		testing.expect_value(t, len(request_body(request)), 70000)
		testing.expect(t, strings.has_prefix(request, "POST /api/v1/x HTTP/1.1\r\n"))
		delete(request)
	}
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}
