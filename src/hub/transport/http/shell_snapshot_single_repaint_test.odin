package http

// REQ-PTY-NET-4 — single repaint on attach, at the policy level.
//
// Drives shell_stream_serve_screen_snapshot with a counting fake capture and a real
// viewer socket, and counts the repaint frames that actually reach the viewer.

import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import shell_session_svc "odin_test:hub/service/shell_session"

@(private = "file")
Counting_Capture :: struct {
	calls: int,
	reply: string,
}

@(private = "file")
_counting_capture_call :: proc(raw: rawptr, cols, rows: int) -> (string, bool) {
	c := (^Counting_Capture)(raw)
	c.calls += 1
	return strings.clone(c.reply), true
}

@(private = "file")
P4_Pair :: struct { listener, client, hub: net.TCP_Socket }

@(private = "file")
p4_pair :: proc(t: ^testing.T) -> P4_Pair {
	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if lerr != nil do testing.fail_now(t, "listen")
	bound, _ := net.bound_endpoint(listener)
	client, derr := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	if derr != nil do testing.fail_now(t, "dial")
	hub, _, aerr := net.accept_tcp(listener)
	if aerr != nil do testing.fail_now(t, "accept")
	return P4_Pair{listener, client, hub}
}

@(private = "file")
p4_close :: proc(p: ^P4_Pair) { net.close(p.hub); net.close(p.client); net.close(p.listener) }

// p4_repaints counts the binary SNAPSHOT frames (catch-up OUTPUT or hub SCREEN) that
// arrived on `sock` within `wait`.
@(private = "file")
p4_repaints :: proc(sock: net.TCP_Socket, wait: time.Duration) -> (repaint_sequences, frames: int) {
	_ = net.set_option(sock, .Receive_Timeout, wait)
	acc := make([dynamic]byte, context.temp_allocator)
	buf: [65536]byte
	started := time.tick_now()
	for time.tick_since(started) < wait {
		n, err := net.recv_tcp(sock, buf[:])
		if err != nil || n <= 0 do break
		append(&acc, ..buf[:n])
	}
	payloads, _ := pty_test_split_server_frames(acc[:], context.temp_allocator)
	prev_snapshot := false
	for p in payloads {
		is_snap := strings.contains(p, "\"is_snapshot\":true")
		if is_snap {
			frames += 1
			if !prev_snapshot do repaint_sequences += 1
		}
		prev_snapshot = is_snap
	}
	return
}

@(private = "file")
Catchup_Later :: struct {
	svc:        ^shell_session_svc.Shell_Session_Service,
	session_id: string,
	delay:      time.Duration,
}

@(private = "file")
_catchup_later :: proc(raw: rawptr) {
	c := (^Catchup_Later)(raw)
	time.sleep(c.delay)
	screen := "\x1b[2J\x1b[Hpty-host catch-up: a full screen worth of text\r\nsecond row\r\n"
	shell_session_svc.shell_session_broadcast_output(c.svc, c.session_id, transmute([]byte)screen, false, true)
}

@(test)
test_p4_viewer_one_gets_exactly_one_repaint_from_the_catchup :: proc(t: ^testing.T) {
	pair := p4_pair(t)
	defer p4_close(&pair)
	svc := shell_session_svc.new_shell_session_service()
	defer shell_session_svc.shell_session_service_free(&svc)
	late_join := shell_session_svc.shell_session_attach(&svc, "sh_p4_first", pair.hub, "brg")
	testing.expect(t, !late_join, "this viewer triggers the 0->1 attach")

	// The catch-up lands 60 ms after the viewer's first resize — inside the grace.
	later := Catchup_Later{svc = &svc, session_id = "sh_p4_first", delay = 60 * time.Millisecond}
	th := thread.create_and_start_with_data(&later, _catchup_later)
	defer { thread.join(th); thread.destroy(th) }

	capture := Counting_Capture{reply = "{\"output\":\"hub capture\",\"cursor_row\":0,\"cursor_col\":0}"}
	ok := shell_stream_serve_screen_snapshot(&svc, "sh_p4_first", pair.hub, 24, 80, late_join, Shell_Screen_Capture{ctx = rawptr(&capture), call = _counting_capture_call})
	testing.expect(t, ok, "the viewer ends up with a full screen")
	testing.expect_value(t, capture.calls, 0) // no shell_get_pane round-trip

	sequences, frames := p4_repaints(pair.client, 300 * time.Millisecond)
	testing.expect_value(t, sequences, 1)
	testing.expect_value(t, frames, 1)
}

@(test)
test_p4_late_joiner_is_served_from_cache_and_miss_captures_once :: proc(t: ^testing.T) {
	first := p4_pair(t)
	defer p4_close(&first)
	second := p4_pair(t)
	defer p4_close(&second)
	third := p4_pair(t)
	defer p4_close(&third)
	svc := shell_session_svc.new_shell_session_service()
	defer shell_session_svc.shell_session_service_free(&svc)
	sid := "sh_p4_late"
	_ = shell_session_svc.shell_session_attach(&svc, sid, first.hub, "brg")

	// Catch-up broadcast already happened for viewer #1.
	screen := "\x1b[2J\x1b[Hcatch-up screen for the first viewer, long enough\r\n"
	shell_session_svc.shell_session_broadcast_output(&svc, sid, transmute([]byte)screen, false, true)

	// Viewer #2 joins: served from the cache, no capture, exactly one repaint.
	late := shell_session_svc.shell_session_attach(&svc, sid, second.hub, "brg")
	testing.expect(t, late)
	capture := Counting_Capture{reply = "{\"output\":\"hub capture for a miss\",\"cursor_row\":0,\"cursor_col\":0}"}
	testing.expect(t, shell_stream_serve_screen_snapshot(&svc, sid, second.hub, 24, 80, late, Shell_Screen_Capture{ctx = rawptr(&capture), call = _counting_capture_call}))
	testing.expect_value(t, capture.calls, 0)
	seq2, frames2 := p4_repaints(second.client, 200 * time.Millisecond)
	testing.expect_value(t, seq2, 1)
	testing.expect_value(t, frames2, 1)
	// Served bytes are the catch-up, not a capture.
	testing.expect(t, shell_session_svc.shell_session_snapshot_cache_has(&svc, sid))

	// Age the cache past freshness; viewer #3 at a new geometry misses -> ONE capture,
	// which is then cached at that geometry.
	sync.mutex_lock(&svc.mu)
	svc.snapshot_cache[sid].at = time.Tick{_nsec = time.tick_now()._nsec - i64(shell_session_svc.SHELL_SNAPSHOT_CACHE_FRESH) - 1}
	sync.mutex_unlock(&svc.mu)
	late3 := shell_session_svc.shell_session_attach(&svc, sid, third.hub, "brg")
	testing.expect(t, shell_stream_serve_screen_snapshot(&svc, sid, third.hub, 40, 120, late3, Shell_Screen_Capture{ctx = rawptr(&capture), call = _counting_capture_call}))
	testing.expect_value(t, capture.calls, 1)
	seq3, _ := p4_repaints(third.client, 200 * time.Millisecond)
	testing.expect_value(t, seq3, 1)
	testing.expect_value(t, shell_session_svc.shell_session_snapshot_cache_decide(&svc, sid, third.hub, 120, 40), shell_session_svc.Shell_Snapshot_Decision.Already_Painted)
	testing.expect_value(t, shell_session_svc.shell_session_snapshot_cache_decide(&svc, sid, second.hub, 120, 40), shell_session_svc.Shell_Snapshot_Decision.Serve)
	// A second resize from viewer #3 (screen_sent gate) never reaches here; but even a
	// direct repeat is a no-op: it is already painted.
	testing.expect(t, shell_stream_serve_screen_snapshot(&svc, sid, third.hub, 40, 120, late3, Shell_Screen_Capture{ctx = rawptr(&capture), call = _counting_capture_call}))
	testing.expect_value(t, capture.calls, 1)
	_ = contracts.PTY_WIRE_KIND_SCREEN
}

@(test)
test_p4_viewer_one_falls_back_to_capture_when_no_catchup_arrives :: proc(t: ^testing.T) {
	pair := p4_pair(t)
	defer p4_close(&pair)
	svc := shell_session_svc.new_shell_session_service()
	defer shell_session_svc.shell_session_service_free(&svc)
	late_join := shell_session_svc.shell_session_attach(&svc, "sh_p4_fallback", pair.hub, "brg")
	capture := Counting_Capture{reply = "{\"output\":\"only the capture can paint this one\",\"cursor_row\":0,\"cursor_col\":0}"}
	// Short grace so the test is quick; REQ-SHELL-61: the viewer still gets a screen.
	ok := shell_stream_serve_screen_snapshot(&svc, "sh_p4_fallback", pair.hub, 24, 80, late_join, Shell_Screen_Capture{ctx = rawptr(&capture), call = _counting_capture_call}, grace = 50 * time.Millisecond)
	testing.expect(t, ok)
	testing.expect_value(t, capture.calls, 1)
	seq, frames := p4_repaints(pair.client, 200 * time.Millisecond)
	testing.expect_value(t, seq, 1)
	testing.expect_value(t, frames, 1)
}

// REQ-PTY-COLOR-1: a capture that leads with the pty-host colour preamble produces SCREEN
// frames whose first bytes are that preamble, then alt prefix (if any), then erase+home.
@(test)
test_screen_frames_carry_the_colour_preamble_first :: proc(t: ^testing.T) {
	pre := "\x1b]11;rgb:1e/1e/2e\x07\x1b]10;#c0caf5\x07"
	reply := strings.concatenate({"{\"output\":\"", "\\u001b]11;rgb:1e/1e/2e\\u0007\\u001b]10;#c0caf5\\u0007\\u001b[?1049h~\\n-- NORMAL --\\n\\n", "\",\"cursor_row\":1,\"cursor_col\":0}"}, context.temp_allocator)
	frames, ok := _shell_stream_screen_frames(reply)
	testing.expect(t, ok)
	defer { for f in frames do delete(f); delete(frames) }
	testing.expect_value(t, len(frames), 1)
	if len(frames) != 1 do return
	kind, flags, payload, _, _, dok := contracts.pty_wire_decode_viewer_frame(frames[0])
	testing.expect(t, dok && kind == contracts.PTY_WIRE_KIND_SCREEN && contracts.pty_wire_is_snapshot(flags))
	testing.expect_value(t, string(payload), strings.concatenate({pre, "\x1b[?1049h", SHELL_SCREEN_REPAINT_PREFIX, "~\r\n-- NORMAL --\x1b[2;1H"}, context.temp_allocator))

	// Without a preamble the repaint is unchanged.
	plain := _shell_screen_repaint_text("hello\n\n", 0, 5)
	defer delete(plain)
	testing.expect_value(t, plain, "\x1b[2J\x1b[Hhello\x1b[1;6H")
}
