package main

// Tests for the REQ-LSP-BR-1 session manager.
//
// Four framing edge cases against the pure kernel lsp_try_parse_one (no I/O):
// split header, coalesced messages, multibyte UTF-8, and non-conforming stdout.
// Plus one end-to-end test that spawns a real child process and asserts a
// server that dies surfaces as a clean session error rather than a hang.
//
// MEMORY: fmt.tprintf returns TEMP-allocator memory — it must never be
// delete()d (that is a bad free against the context allocator). Each test
// reclaims the temp arena with free_all(context.temp_allocator) instead.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "core:unicode/utf8"

// build_frame formats "Content-Length: N\r\n\r\n<body>" into TEMP memory.
// The result is owned by the temp allocator — do not delete it.
@(private = "file")
build_frame :: proc(body: string) -> string {
	return fmt.tprintf("Content-Length: %d\r\n\r\n%s", len(transmute([]byte)body), body)
}

// concat_bytes concatenates two byte slices into a new heap-allocated slice.
@(private = "file")
concat_bytes :: proc(a, b: []byte) -> []byte {
	out := make([]byte, len(a) + len(b))
	copy(out,        a)
	copy(out[len(a):], b)
	return out
}

// --- edge case 1: split header -----------------------------------------------
//
// The OS may deliver the header bytes and body bytes in separate reads.
// Combined buffer must yield the message; either partial alone must return false.

@(test)
test_lsp_framing_split_header :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	body    :: `{"method":"initialized","params":{}}`
	part_a  :: "Content-Len"                                   // constant prefix of header
	part_b  := fmt.tprintf("gth: %d\r\n\r\n", len(body))      // constant-ish suffix
	full_frame := build_frame(body)

	// Part A alone: no separator found → must return false.
	{
		buf := transmute([]byte)string(part_a)
		_, _, ok := lsp_try_parse_one(buf)
		testing.expect(t, !ok, "split: partial header alone must return false")
	}

	// A+B: header complete but body absent → body not fully arrived.
	{
		ab := concat_bytes(transmute([]byte)string(part_a), transmute([]byte)part_b)
		defer delete(ab)
		_, _, ok := lsp_try_parse_one(ab)
		testing.expect(t, !ok, "split: header without body must return false")
	}

	// Full frame: must parse correctly.
	{
		buf := transmute([]byte)full_frame
		msg, rem, ok := lsp_try_parse_one(buf)
		testing.expect(t, ok,                  "split: full frame must return true")
		testing.expect(t, string(msg) == body,  "split: decoded body must match")
		testing.expect(t, len(rem) == 0,       "split: no remaining bytes expected")
	}
}

// --- edge case 2: coalesced messages -----------------------------------------
//
// A single read may deliver two or more complete messages concatenated.
// First call consumes the first message; second call consumes the second.

@(test)
test_lsp_framing_coalesced :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	body1 :: `{"id":1,"result":null}`
	body2 :: `{"id":2,"result":true}`

	frame1 := build_frame(body1)
	frame2 := build_frame(body2)

	combined := concat_bytes(transmute([]byte)frame1, transmute([]byte)frame2)
	defer delete(combined)

	// First parse.
	msg1, rem1, ok1 := lsp_try_parse_one(combined)
	testing.expect(t, ok1,                  "coalesced: first parse must succeed")
	testing.expect(t, string(msg1) == body1, "coalesced: first body must match")

	// Second parse on the remainder.
	msg2, rem2, ok2 := lsp_try_parse_one(rem1)
	testing.expect(t, ok2,                  "coalesced: second parse must succeed")
	testing.expect(t, string(msg2) == body2, "coalesced: second body must match")
	testing.expect(t, len(rem2) == 0,       "coalesced: no bytes after second message")
}

// --- edge case 3: multibyte UTF-8 content ------------------------------------
//
// Content-Length is a BYTE count, not a rune count.
// "日本語" = 9 UTF-8 bytes but only 3 runes — the byte count must be used.

@(test)
test_lsp_framing_multibyte_utf8 :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	body :: `{"text":"日本語"}`

	body_bytes := transmute([]byte)string(body)
	byte_len   := len(body_bytes)
	rune_len   := utf8.rune_count(body_bytes)

	testing.expect(t, byte_len > rune_len,
		"sanity: multibyte string must have more bytes than runes")

	// Frame with correct BYTE count.
	good_frame := build_frame(body)
	{
		buf := transmute([]byte)good_frame
		msg, rem, ok := lsp_try_parse_one(buf)
		testing.expect(t, ok,                  "multibyte: byte-count frame must parse ok")
		testing.expect(t, string(msg) == body,  "multibyte: decoded body must match original")
		testing.expect(t, len(rem) == 0,       "multibyte: no remaining bytes")
	}

	// Frame with wrong RUNE count — the declared length is too short.
	// Either the parse fails (not enough bytes declared) OR it returns a
	// truncated slice that does NOT equal the full body.
	// All body bytes are present, so the parser MUST return ok=true — and it
	// must hand back exactly rune_len bytes, a truncation of the real body.
	// Asserting the exact slice (not merely "!= body") makes this deterministic.
	bad_frame := fmt.tprintf("Content-Length: %d\r\n\r\n%s", rune_len, body)
	{
		buf := transmute([]byte)bad_frame
		msg, rem, ok := lsp_try_parse_one(buf)
		testing.expect(t, ok, "multibyte: rune-count frame parses (all bytes present)")
		testing.expect(t, len(msg) == rune_len,
			"multibyte: parser must honour the DECLARED byte count, truncating the body")
		testing.expect(t, string(msg) != body,
			"multibyte: rune-count frame must NOT decode to the full body")
		testing.expect(t, len(rem) == byte_len - rune_len,
			"multibyte: the bytes past the declared length remain unconsumed")
	}
}


// --- edge case 4: non-conforming stdout ---------------------------------------
//
// Coordinator gap 1: a real language server (gopls and others, historically)
// writes log lines, banners and stack traces to stdout under error conditions.
// Those bytes never form a valid header. The parser must refuse them rather
// than consume unboundedly, and a malformed or hostile Content-Length must not
// become a huge allocation.

@(test)
test_lsp_framing_non_conforming_stdout :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Plain text with no header at all — even with a \r\n\r\n separator present,
	// there is no Content-Length, so nothing may be consumed.
	{
		garbage :: "panic: runtime error: index out of range\r\n\r\ngoroutine 1 [running]:\r\n"
		msg, rem, ok := lsp_try_parse_one(transmute([]byte)string(garbage))
		testing.expect(t, !ok,          "garbage: text with no Content-Length must not parse")
		testing.expect(t, msg == nil,   "garbage: no message may be returned")
		testing.expect(t, rem == nil,   "garbage: nothing may be consumed")
	}

	// A log line with no separator at all.
	{
		line :: "[info] server starting up, watching 412 files\n"
		_, _, ok := lsp_try_parse_one(transmute([]byte)string(line))
		testing.expect(t, !ok, "garbage: a bare log line must not parse")
	}

	// Non-numeric Content-Length.
	{
		frame :: "Content-Length: abc\r\n\r\n{}"
		_, _, ok := lsp_try_parse_one(transmute([]byte)string(frame))
		testing.expect(t, !ok, "garbage: non-numeric Content-Length must be rejected")
	}

	// Negative Content-Length — must never become a negative slice bound.
	{
		frame :: "Content-Length: -1\r\n\r\n{}"
		_, _, ok := lsp_try_parse_one(transmute([]byte)string(frame))
		testing.expect(t, !ok, "garbage: negative Content-Length must be rejected")
	}

	// Absurd Content-Length above the cap — must not be treated as a pending
	// body the caller keeps buffering toward.
	{
		frame := fmt.tprintf("Content-Length: %d\r\n\r\n{}", LSP_MAX_CONTENT_LENGTH + 1)
		_, _, ok := lsp_try_parse_one(transmute([]byte)frame)
		testing.expect(t, !ok, "garbage: over-cap Content-Length must be rejected")
	}

	// Header bound: garbage with no terminator anywhere must be diagnosable
	// WITHOUT waiting for the accumulator to reach its 16 MiB cap.
	{
		short :: "[info] still starting up\n"
		testing.expect(t, !lsp_header_overrun(transmute([]byte)string(short)),
			"header bound: a short log line is not yet an overrun")

		big := make([]byte, LSP_MAX_HEADER + 1)
		defer delete(big)
		for i in 0 ..< len(big) do big[i] = 'x'
		testing.expect(t, lsp_header_overrun(big),
			"header bound: no terminator within the header window is an overrun")

		// A real frame with a large PENDING body is NOT an overrun — its
		// terminator sits at the front, well inside the window.
		pending := fmt.tprintf("Content-Length: %d\r\n\r\n%s", 1024 * 1024, string(big))
		testing.expect(t, !lsp_header_overrun(transmute([]byte)pending),
			"header bound: a framed message awaiting its body must not be flagged")
	}

	// A legal length just under the cap is NOT garbage: it is a pending body.
	// This is the B6 boundary — the accumulator bound must be large enough to
	// let such a message arrive rather than killing the session mid-body.
	{
		testing.expect(t, LSP_MAX_ACCUM > LSP_MAX_CONTENT_LENGTH,
			"bounds: accumulator cap must exceed the largest legal message")
		frame := fmt.tprintf("Content-Length: %d\r\n\r\n{}", LSP_MAX_CONTENT_LENGTH - 1)
		_, _, ok := lsp_try_parse_one(transmute([]byte)frame)
		testing.expect(t, !ok, "bounds: a legal-but-incomplete body is pending, not parsed")
	}
}

// --- spawn-based tests --------------------------------------------------------
//
// These exercise the real read thread against a real child process. They are
// the only way to cover acceptance criterion "a killed server surfaces as a
// clean session error, not a bridge crash or hang" — the pure framing tests
// cannot reach that path.

@(private = "file")
LSP_TEST_POLL_TIMEOUT :: 20 * time.Second

// write_test_script writes sh source to a unique path under /tmp and returns it
// (caller owns the string and should os.remove the file). The path contains no
// spaces because lsp_start splits its args on spaces.
@(private = "file")
write_test_script :: proc(name, body: string) -> (path: string, ok: bool) {
	path = fmt.aprintf("/tmp/ham-lsp-test-%s-%d.sh", name, os.get_pid())
	if err := os.write_entire_file(path, transmute([]byte)body); err != nil {
		delete(path)
		return "", false
	}
	return path, true
}

// await_lsp_error polls the outgoing queue until an lsp_error frame for
// session_id appears, or the deadline passes. Returns the frame (caller owns)
// and whether it arrived; the returned frame is owned by lsp_heap() and must be
// freed with it. Frames for other sessions are put back so concurrent tests do
// not consume each other's output.
@(private = "file")
await_lsp_error :: proc(session_id: string) -> (frame: string, ok: bool) {
	start := time.tick_now()
	for time.tick_since(start) < LSP_TEST_POLL_TIMEOUT {
		pending := bridge_lsp_take_outgoing()
		found := ""
		for f in pending {
			if found == "" &&
			   strings.contains(f, "\"type\":\"lsp_error\"") &&
			   strings.contains(f, session_id) {
				found = f
			} else {
				bridge_lsp_enqueue(f) // not ours — put it back
				delete(f, lsp_heap())
			}
		}
		delete(pending)
		if found != "" do return found, true
		time.sleep(20 * time.Millisecond)
	}
	return "", false
}

// SPAWN TESTS MUST NOT RUN CONCURRENTLY WITH EACH OTHER.
//
// bridge_lsp_stop_all is a process-wide teardown: it kills EVERY registered
// session, not just the caller's. With the runner on 4 threads, the stop_all
// test was SIGTERMing the other two tests' servers mid-flight, so they observed
// `{"reason":"exited","exit_code":15}` instead of their own outcome — a ~50%
// flake that looked like a product bug and was purely test interference.
// These three tests share one global session map and one outgoing queue, so
// they take this lock and run one at a time. The pure framing tests need no
// lock; they touch no global state.
@(private = "file")
lsp_spawn_test_mu: sync.Mutex

// drain_frames_for removes this session's queued frames and puts every other
// session's frame back. The outgoing queue is a process-wide global shared by
// all tests in the package, so a drain must never be indiscriminate.
@(private = "file")
drain_frames_for :: proc(session_id: string) {
	pending := bridge_lsp_take_outgoing()
	defer delete(pending)
	for f in pending {
		if !strings.contains(f, session_id) do bridge_lsp_enqueue(f) // not ours
		delete(f, lsp_heap())
	}
}

// await_session_removed polls until the session is gone from the map, which is
// the observable half of the B5 leak fix: the read worker frees the session's
// five clones only via bridge_lsp_session_remove.
@(private = "file")
await_session_removed :: proc(session_id: string) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < LSP_TEST_POLL_TIMEOUT {
		if !bridge_lsp_session_exists(session_id) do return true
		time.sleep(20 * time.Millisecond)
	}
	return false
}

// A server that EXITS on its own must surface as a clean session error carrying
// its exit code — not a crash, not a hang.
@(test)
test_lsp_dying_server_reports_error :: proc(t: ^testing.T) {
	sync.mutex_lock(&lsp_spawn_test_mu)
	defer sync.mutex_unlock(&lsp_spawn_test_mu)
	defer free_all(context.temp_allocator)
	bridge_lsp_init_once()

	script, wrote := write_test_script("dying", "exit 7\n")
	if !testing.expect(t, wrote, "dying: could not write test script") do return
	defer { os.remove(script); delete(script) }

	session_id := "lsp_test_dying"
	start := fmt.tprintf(
		`{{"type":"lsp_start","session_id":"%s","cmd":"/bin/sh","args":"%s"}}`,
		session_id, script,
	)
	bridge_lsp_handle_start(nil, start)

	frame, got := await_lsp_error(session_id)
	if !testing.expect(t, got, "dying: no lsp_error frame arrived before the deadline") do return
	defer delete(frame, lsp_heap())

	testing.expect(t, strings.contains(frame, `"exit_code":7`),
		"dying: lsp_error must carry the child's real exit code")

	// NB3: asserting the transient status here would be vacuous — the worker
	// sets it and removes the session within microseconds, so a poll from
	// outside always arrives after removal and `!present` short-circuits the
	// check. The frame above carries the real contract; what IS observable, and
	// what the B5 leak actually was, is that the session gets removed at all.
	testing.expect(t, await_session_removed(session_id),
		"dying: session must be removed from the map (its clones are freed there)")
}

// B1 REGRESSION. A server that writes garbage and KEEPS RUNNING must still
// produce an lsp_error. With the bug present (process_wait with no timeout on a
// live child) the read thread parks forever, no frame is ever enqueued, and
// this test fails on the deadline — which is precisely what makes it a
// regression test rather than a restatement of the dying-server case.
@(test)
test_lsp_garbage_stdout_live_child_does_not_hang :: proc(t: ^testing.T) {
	sync.mutex_lock(&lsp_spawn_test_mu)
	defer sync.mutex_unlock(&lsp_spawn_test_mu)
	defer free_all(context.temp_allocator)
	bridge_lsp_init_once()

	// Write past LSP_MAX_HEADER of non-conforming bytes, then STAY ALIVE.
	// /dev/zero emits nothing resembling a header, and the header bound means
	// only ~8 KiB is needed to trip it.
	// `exec sleep` matters: a bare `sleep 600` is a CHILD of the shell, so
	// killing the session's process leaves that child orphaned AND holding the
	// stdout write end (one stray process per run — I found five after five
	// suite runs). `exec` replaces the shell, keeping the session a single
	// process that the reap path can actually kill. This is the NB2 shape in
	// miniature; the test deliberately stays out of it.
	body := fmt.tprintf(
		"dd if=/dev/zero bs=1024 count=%d 2>/dev/null\nexec sleep 600\n",
		(LSP_MAX_HEADER / 1024) + 4,
	)
	script, wrote := write_test_script("garbage", body)
	if !testing.expect(t, wrote, "garbage: could not write test script") do return
	defer { os.remove(script); delete(script) }

	session_id := "lsp_test_garbage"
	start := fmt.tprintf(
		`{{"type":"lsp_start","session_id":"%s","cmd":"/bin/sh","args":"%s"}}`,
		session_id, script,
	)
	bridge_lsp_handle_start(nil, start)

	frame, got := await_lsp_error(session_id)
	testing.expect(t, got,
		"B1: a live child writing garbage must produce lsp_error, not a parked thread")
	if !got {
		// Do not leave the child running for the rest of the suite.
		bridge_lsp_handle_stop(nil, fmt.tprintf(`{{"session_id":"%s"}}`, session_id))
		return
	}
	defer delete(frame, lsp_heap())

	testing.expect(t, strings.contains(frame, `"reason":"framing_error"`),
		"B1: the error must name the framing breach that caused it")

	// NB3: same reasoning as the dying-server test — the status is not
	// observable from outside, the frame is. Assert the removal instead.
	testing.expect(t, await_session_removed(session_id),
		"B1: session must be removed from the map after a framing error")
}


// C1 REGRESSION / coverage gap. bridge_lsp_stop_all had NO test at all — its
// only production caller is the hub-WS-disconnect path — which is why a bad
// free on its id cleanup survived a green suite. This test puts that path under
// the tracking allocator so a mismatched delete() there shows up as
// "+++ bad free @ ... bridge_lsp_stop_all()" instead of shipping.
//
// `exec sleep 600` replaces the shell, so the session is a SINGLE process and
// its stdout reaches EOF when it is signalled (see NB2: a server that leaves a
// grandchild holding stdout is a separate, unresolved case).
@(test)
test_lsp_stop_all_terminates_and_frees :: proc(t: ^testing.T) {
	sync.mutex_lock(&lsp_spawn_test_mu)
	defer sync.mutex_unlock(&lsp_spawn_test_mu)
	defer free_all(context.temp_allocator)
	bridge_lsp_init_once()

	script, wrote := write_test_script("stopall", "exec sleep 600\n")
	if !testing.expect(t, wrote, "stop_all: could not write test script") do return
	defer { os.remove(script); delete(script) }

	session_id := "lsp_test_stopall"
	start := fmt.tprintf(
		`{{"type":"lsp_start","session_id":"%s","cmd":"/bin/sh","args":"%s"}}`,
		session_id, script,
	)
	bridge_lsp_handle_start(nil, start)

	_, present := bridge_lsp_session_status(session_id)
	if !testing.expect(t, present, "stop_all: session must be registered before teardown") do return

	// The path under test. A bare delete() on the cloned ids inside this call
	// is reported by the tracking allocator against this test.
	bridge_lsp_stop_all()

	testing.expect(t, await_session_removed(session_id),
		"stop_all: every session must be torn down and removed")

	// Drain only OUR frames. The outgoing queue is a process-wide global and the
	// other spawn tests run concurrently on it — deleting everything here stole
	// their frames and made their assertions fail intermittently.
	drain_frames_for(session_id)
}

// --- root marker detection (REQ-LSP-ROOT-MARKERS-1) --------------------------

@(test)
test_lsp_find_root_dir_empty_and_invalid :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Empty markers -> returns ""
	{
		res := bridge_lsp_find_root_dir("/some/file.ts", "/some", "")
		defer delete(res)
		testing.expect_value(t, res, "")
	}

	// Whitespace-only markers -> returns ""
	{
		res := bridge_lsp_find_root_dir("/some/file.ts", "/some", "   ,   ")
		defer delete(res)
		testing.expect_value(t, res, "")
	}

	// Empty path and cwd -> returns ""
	{
		res := bridge_lsp_find_root_dir("", "", "package.json")
		defer delete(res)
		testing.expect_value(t, res, "")
	}
}

@(test)
test_lsp_find_root_dir_upward_traversal :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Create test tree:
	// /tmp/ham-lsp-root-<pid>/
	//   repo/
	//     package.json
	//     .git/
	//     src/
	//       tsconfig.json
	//       ui/
	//         components/
	//           HomePage.tsx
	base := fmt.aprintf("/tmp/ham-lsp-root-%d", os.get_pid())
	defer {
		_ = os.remove_all(base)
		delete(base)
	}

	repo_dir       := fmt.tprintf("%s/repo", base)
	src_dir        := fmt.tprintf("%s/src", repo_dir)
	components_dir := fmt.tprintf("%s/ui/components", src_dir)

	_ = os.make_directory_all(components_dir)
	_ = os.make_directory_all(fmt.tprintf("%s/.git", repo_dir))
	_ = os.write_entire_file(fmt.tprintf("%s/package.json", repo_dir), transmute([]byte)string("{}"))
	_ = os.write_entire_file(fmt.tprintf("%s/tsconfig.json", src_dir), transmute([]byte)string("{}"))
	file_path := fmt.tprintf("%s/HomePage.tsx", components_dir)
	_ = os.write_entire_file(file_path, transmute([]byte)string("export const x = 1;"))

	// 1. Walk up from nested file to tsconfig.json in src_dir (nearest marker)
	{
		res := bridge_lsp_find_root_dir(file_path, "", "tsconfig.json")
		defer delete(res)
		testing.expect_value(t, res, src_dir)
	}

	// 2. Walk up beyond src_dir to package.json in repo_dir
	{
		res := bridge_lsp_find_root_dir(file_path, "", "package.json")
		defer delete(res)
		testing.expect_value(t, res, repo_dir)
	}

	// 3. Comma-separated markers with whitespace: "go.mod, package.json"
	{
		res := bridge_lsp_find_root_dir(file_path, "", "go.mod, package.json")
		defer delete(res)
		testing.expect_value(t, res, repo_dir)
	}

	// 4. Directory marker (.git)
	{
		res := bridge_lsp_find_root_dir(file_path, "", ".git")
		defer delete(res)
		testing.expect_value(t, res, repo_dir)
	}

	// 5. Upward walk starting from cwd when file_path is empty
	{
		res := bridge_lsp_find_root_dir("", components_dir, "package.json")
		defer delete(res)
		testing.expect_value(t, res, repo_dir)
	}

	// 6. Relative file_path resolved against cwd
	{
		res := bridge_lsp_find_root_dir("ui/components/HomePage.tsx", src_dir, "package.json")
		defer delete(res)
		testing.expect_value(t, res, repo_dir)
	}

	// 7. Non-existent marker returns empty string
	{
		res := bridge_lsp_find_root_dir(file_path, "", "nonexistent.json, Cargo.toml")
		defer delete(res)
		testing.expect_value(t, res, "")
	}
}

@(private = "file")
Lsp_Budget_Writer :: struct {
	session_id: string,
	frame:      string,
	queued:     bool,
	returned:   bool, // atomic
}

// REQ-ERR-PROTO-C: once BRIDGE_LSP_OUTGOING_MAX_BYTES are queued, a running session's
// data frame waits (back-pressure on the server) instead of growing the queue; it is
// queued as soon as the hub drains, and dropped only when the session has ended.
@(test)
test_lsp_outgoing_queue_is_bounded_and_backpressures :: proc(t: ^testing.T) {
	sync.mutex_lock(&lsp_spawn_test_mu)
	defer sync.mutex_unlock(&lsp_spawn_test_mu)
	bridge_lsp_init_once()
	// Start from an empty queue; put back anything another test left.
	leftover := bridge_lsp_take_outgoing()
	defer {
		for f in leftover {
			bridge_lsp_enqueue(f)
			delete(f, lsp_heap())
		}
		delete(leftover)
	}

	session_id := "lsp_budget_test"
	bridge_lsp_session_register(Bridge_Lsp_Session{
		session_id = strings.clone(session_id, lsp_heap()), language = strings.clone("x", lsp_heap()),
		cmd = strings.clone("x", lsp_heap()), cwd = strings.clone("/", lsp_heap()), owner_user_id = strings.clone("u", lsp_heap()),
		status = .Running,
	})
	defer bridge_lsp_session_remove(session_id)

	filler := strings.repeat("f", 512 * 1024, context.temp_allocator)
	for bridge_lsp_outgoing_queued_bytes() + len(filler) <= BRIDGE_LSP_OUTGOING_MAX_BYTES {
		testing.expect(t, bridge_lsp_enqueue_data(session_id, filler))
	}
	full := bridge_lsp_outgoing_queued_bytes()

	w := Lsp_Budget_Writer{session_id = session_id, frame = filler}
	th := thread.create_and_start_with_data(rawptr(&w), proc(data: rawptr) {
		w := (^Lsp_Budget_Writer)(data)
		w.queued = bridge_lsp_enqueue_data(w.session_id, w.frame)
		sync.atomic_store(&w.returned, true)
	})
	time.sleep(300 * time.Millisecond)
	testing.expect(t, !sync.atomic_load(&w.returned), "a data frame over the budget waits instead of queueing")
	testing.expect_value(t, bridge_lsp_outgoing_queued_bytes(), full)

	// The hub drains: the waiting frame goes in, and the queue never exceeded the cap.
	drained := bridge_lsp_take_outgoing()
	for f in drained do delete(f, lsp_heap())
	delete(drained)
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, w.queued, "queued once there was room")
	testing.expect(t, bridge_lsp_outgoing_queued_bytes() <= BRIDGE_LSP_OUTGOING_MAX_BYTES)

	// A session that has ended does not wait: its frame is dropped.
	for bridge_lsp_outgoing_queued_bytes() + len(filler) <= BRIDGE_LSP_OUTGOING_MAX_BYTES do bridge_lsp_enqueue(filler)
	bridge_lsp_session_set_status(session_id, .Failed)
	started := time.tick_now()
	testing.expect(t, !bridge_lsp_enqueue_data(session_id, filler), "an ended session's frame is dropped, not waited on")
	testing.expect(t, time.tick_since(started) < 50 * time.Millisecond)

	rest := bridge_lsp_take_outgoing()
	for f in rest do delete(f, lsp_heap())
	delete(rest)
}
