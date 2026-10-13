package http

import "core:strings"
import "core:testing"
import "core:time"

// REQ-SHELL-41. Two things are under test here, and they are the two that carry the
// task's risk:
//   1. the TEARDOWN REASON is classified correctly — the whole point, since before this
//      every cause collapsed into one indistinguishable `false`;
//   2. the rate limiter actually BOUNDS a reconnect storm while still reporting what it
//      swallowed.

// A local copy of the masked-frame builder: the one in bridge_ws_reader_test.odin is
// @(private="file") and so is not visible here, even in the same package.
@(private = "file")
masked_text_frame :: proc(text: string) -> [dynamic]byte {
	mask := [4]byte{0x11, 0x22, 0x33, 0x44}
	n := len(text)
	out := make([dynamic]byte)
	append(&out, 0x81)
	if n <= 125 {
		append(&out, byte(0x80 | n))
	} else {
		append(&out, byte(0x80 | 126), byte((n >> 8) & 0xff), byte(n & 0xff))
	}
	append(&out, mask[0], mask[1], mask[2], mask[3])
	for i in 0 ..< n do append(&out, text[i] ~ mask[i % 4])
	return out
}

// NOTE (REQ-SHELL-59): there used to be a reset_log_limiter() here that cleared the
// process-wide bridge_ws_log_limiter between tests. It was the BUG, not the isolation:
// the clear took no lock while bridge_ws_log_admit holds one, so at
// ODIN_TEST_THREADS>1 one test's reset landed mid-loop in another's and granted it a
// second burst. Every test below now owns a private Bridge_WS_Log_Limiter and calls the
// *_in variants, so there is no shared table to reset and no reset to race.

// A close frame is an ORDERLY shutdown, and must not be reported as a desync. The
// pre-existing bridge_ws_take_frame_flags_nontext_fatal test pins that a close is still
// fatal (the connection still ends); this pins that it is now fatal for the RIGHT reason.
@(test)
test_bridge_ws_close_frame_reads_as_clean_close :: proc(t: ^testing.T) {
	reader := Bridge_WS_Reader{}
	defer bridge_ws_reader_destroy(&reader)
	append(&reader.pending, 0x88, 0x80, 0x00, 0x00, 0x00, 0x00) // masked, empty close
	_, ok, fatal := bridge_ws_take_frame(&reader)
	testing.expect(t, !ok)
	testing.expect(t, fatal)
	testing.expect_value(t, reader.fatal_reason, Bridge_WS_Disconnect_Reason.Clean_Close)
}

// A 64-bit (127) length on this control channel is a genuine desync, and must be
// distinguishable from the clean close above — these two shared a single `fatal=true`
// return before this change.
@(test)
test_bridge_ws_64bit_length_reads_as_fatal_desync :: proc(t: ^testing.T) {
	reader := Bridge_WS_Reader{}
	defer bridge_ws_reader_destroy(&reader)
	// masked text frame claiming an invalid 64-bit length (high bit set, forbidden by RFC 6455 §5.2)
	append(&reader.pending, 0x81, 0xff, 0x80, 0, 0, 0, 0, 0, 0, 0, 0x00, 0x00, 0x00, 0x00)
	_, ok, fatal := bridge_ws_take_frame(&reader)
	testing.expect(t, !ok)
	testing.expect(t, fatal)
	testing.expect_value(t, reader.fatal_reason, Bridge_WS_Disconnect_Reason.Fatal_Frame)
}

// A partial frame is NOT a teardown — it means "need more bytes". If this regressed into
// a fatal reason, every coalesced/split frame would kill the bridge connection.
@(test)
test_bridge_ws_partial_frame_is_not_a_teardown :: proc(t: ^testing.T) {
	reader := Bridge_WS_Reader{}
	defer bridge_ws_reader_destroy(&reader)
	append(&reader.pending, 0x81, 0x85, 0x00, 0x00, 0x00, 0x00, 'h') // claims 5, has 1
	_, ok, fatal := bridge_ws_take_frame(&reader)
	testing.expect(t, !ok)
	testing.expect(t, !fatal)
	testing.expect_value(t, reader.fatal_reason, Bridge_WS_Disconnect_Reason.None)
}

// A successful read must clear any reason left over from a previous fatal classification
// on the same reader, so a later teardown cannot inherit a stale cause.
@(test)
test_bridge_ws_successful_read_clears_stale_reason :: proc(t: ^testing.T) {
	reader := Bridge_WS_Reader{}
	defer bridge_ws_reader_destroy(&reader)
	reader.fatal_reason = .Fatal_Frame
	frame := masked_text_frame("{\"type\":\"bridge_heartbeat\"}")
	defer delete(frame)
	append(&reader.pending, ..frame[:])
	text, ok, reason := bridge_ws_read_frame(&reader, 1 * time.Second)
	testing.expect(t, ok)
	testing.expect_value(t, reason, Bridge_WS_Disconnect_Reason.None)
	delete(text)
}

// Every reason must render as a distinct, non-empty, allocation-free token — a log line
// whose reasons collide would defeat the task.
@(test)
test_bridge_ws_reason_strings_are_distinct :: proc(t: ^testing.T) {
	reasons := []Bridge_WS_Disconnect_Reason{
		.None, .Clean_Close, .Read_Deadline, .Fatal_Frame,
		.Recv_Error, .Connection_Replaced, .Frame_Rejected, .Write_Failed,
	}
	seen := make([dynamic]string)
	defer delete(seen)
	for r in reasons {
		s := bridge_ws_reason_string(r)
		testing.expect(t, len(s) > 0)
		testing.expect(t, !strings.contains(s, " "), "reasons must be single greppable tokens")
		for prior in seen {
			testing.expect(t, prior != s, "two reasons render identically")
		}
		append(&seen, s)
	}
}

// AC5. The burst is allowed, everything after it in the same window is suppressed, and
// the suppressed COUNT survives to the next window — a storm is bounded but never
// silent.
@(test)
test_bridge_ws_log_limiter_bounds_a_reconnect_storm :: proc(t: ^testing.T) {
	// Private to this test: nothing else can clear or age it mid-loop.
	lim := Bridge_WS_Log_Limiter{}
	now := i64(1_000_000_000_000)

	allowed := 0
	for i in 0 ..< 200 {
		// A storm inside a single window: every event at the same instant.
		if allow, _ := bridge_ws_log_admit_in(&lim, "brg_storm", now); allow do allowed += 1
	}
	testing.expect_value(t, allowed, BRIDGE_WS_LOG_BURST)

	// Next window: the first event is allowed again AND reports the backlog.
	allow, suppressed := bridge_ws_log_admit_in(&lim, "brg_storm", now + i64(BRIDGE_WS_LOG_WINDOW))
	testing.expect(t, allow)
	testing.expect_value(t, suppressed, 200 - BRIDGE_WS_LOG_BURST)

	// ...and the backlog is not double-reported.
	_, again := bridge_ws_log_admit_in(&lim, "brg_storm", now + i64(BRIDGE_WS_LOG_WINDOW))
	testing.expect_value(t, again, 0)
}

// One flapping bridge must not consume another bridge's budget — per-bridge windows,
// not one global one.
@(test)
test_bridge_ws_log_limiter_budgets_are_per_bridge :: proc(t: ^testing.T) {
	lim := Bridge_WS_Log_Limiter{}
	now := i64(2_000_000_000_000)
	for i in 0 ..< 50 {
		_, _ = bridge_ws_log_admit_in(&lim, "brg_noisy", now)
	}
	// A different bridge's first line is still admitted.
	allow, suppressed := bridge_ws_log_admit_in(&lim, "brg_quiet", now)
	testing.expect(t, allow)
	testing.expect_value(t, suppressed, 0)
}

// More concurrent bridges than there are slots must degrade by EVICTION, never by
// refusing to log or by running off the end of the table.
@(test)
test_bridge_ws_log_limiter_survives_more_bridges_than_slots :: proc(t: ^testing.T) {
	lim := Bridge_WS_Log_Limiter{}
	now := i64(3_000_000_000_000)
	ids := make([dynamic]string)
	defer { for s in ids do delete(s); delete(ids) }
	for i in 0 ..< BRIDGE_WS_LOG_SLOTS * 3 {
		// Distinct ids, increasing timestamps so eviction has an "oldest" to pick.
		num := fmt_int_for_test(i)
		id := strings.concatenate({"brg_", num})
		delete(num)
		append(&ids, id)
		allow, _ := bridge_ws_log_admit_in(&lim, id, now + i64(i) * i64(time.Millisecond))
		testing.expect(t, allow, "a bridge's FIRST lifecycle line must never be suppressed")
	}
}

@(private = "file")
fmt_int_for_test :: proc(n: int) -> string {
	// Small local helper so the test does not pull core:fmt in just for this.
	digits := "0123456789"
	// Must CLONE even this arm: returning the literal made the caller's delete() a
	// free of non-heap memory, which the test allocator correctly reported as
	// "+++ bad free". Every return here is owned by the caller.
	if n == 0 do return strings.clone("0")
	buf: [20]byte
	i := len(buf)
	v := n
	for v > 0 {
		i -= 1
		buf[i] = digits[v % 10]
		v /= 10
	}
	return strings.clone(string(buf[i:]))
}
