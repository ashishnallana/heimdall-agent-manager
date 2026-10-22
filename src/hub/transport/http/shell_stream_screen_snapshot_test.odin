// Behavioral and edge-case tests for shell stream screen snapshots, ANSI CUP cursor positioning, row trimming, and chunking.
package http

import base64 "core:encoding/base64"
import "core:fmt"
import "core:net"
import platform "odin_test:hub/platform"
import shell_session_svc "odin_test:hub/service/shell_session"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

// --- Consolidated from shell_stream_screen_snapshot_test.odin ---

// REQ-PTY-NET-2: `screen` frames are binary pty_wire viewer frames now. These shims keep
// the assertions below about the REPAINT BYTES unchanged: the base64 the tests inspect is
// the debug rendering of the binary payload, not anything on the wire.
@(private = "file")
_screen_payload_b64 :: proc(pane_output: string, cursor_row: int = -1, cursor_col: int = -1) -> string {
	text := _shell_screen_repaint_text(pane_output, cursor_row, cursor_col)
	defer delete(text)
	return base64.encode(transmute([]byte)text)
}

// _screen_frame_json builds the SCREEN frame for a payload given as base64 (as the old
// JSON builder took it) and renders it back as debug JSON.
@(private = "file")
_screen_frame_json :: proc(data_b64: string, cursor_row: int = -1, cursor_col: int = -1) -> string {
	payload, err := base64.decode(data_b64, allocator = context.temp_allocator)
	if err != nil do payload = transmute([]byte)data_b64
	frame := shell_stream_screen_frame(payload, cursor_row, cursor_col)
	defer delete(frame)
	return contracts.pty_wire_viewer_frame_debug_json(frame)
}

@(test)
test_req29_screen_payload_is_an_absolute_repaint :: proc(t: ^testing.T) {
	payload := _screen_payload_b64("line one\nline two")
	defer delete(payload)

	decoded, err := base64.decode(payload)
	testing.expect(t, err == nil, "payload must be valid base64")
	defer delete(decoded)

	got := string(decoded)
	testing.expect(
		t,
		strings.has_prefix(got, "\x1b[2J\x1b[H"),
		"snapshot must begin with erase-screen + cursor-home so it overwrites whatever the client already drew",
	)
	// REQ-SHELL-30: the row separator is now CRLF, so this assertion changes with the fix
	// rather than being deleted. Its failure against the old bare-LF build is the evidence
	// that the payload actually moved.
	testing.expect(
		t,
		strings.has_suffix(got, "line one\r\nline two"),
		"pane text follows the repaint prefix, rows separated by CRLF",
	)
}

@(test)
test_req29_frame_uses_data_b64_not_the_data_b64_fallback :: proc(t: ^testing.T) {
	frame := _screen_frame_json("QUJD")
	defer delete(frame)

	testing.expect(t, strings.contains(frame, "\"type\":\"screen\""), "frame type must be screen")
	testing.expect(t, strings.contains(frame, "\"data_b64\":\"QUJD\""), "payload must ride on data_b64")
	testing.expect(
		t,
		strings.contains(frame, "\"is_encrypted\":false"),
		"screen and output use the same explicit payload contract",
	)
}

// A terminal session answers get_pane locally with output:"" — there is no screen to
// repaint, and writing an erase-screen to a dead pane would blank real scrollback.
@(test)
test_req29_empty_pane_output_writes_no_frame :: proc(t: ^testing.T) {
	reply := "{\"ok\":true,\"status\":\"exited\",\"unchanged\":true,\"hash\":\"\",\"output\":\"\"}"
	testing.expect(
		t,
		!_shell_stream_write_screen_frame(nil, "", net.TCP_Socket(0), reply),
		"an empty pane must write nothing at all",
	)
}

// What shell_session_attach REPORTS: viewer #1 is not a late join, viewer #2 is. This is a
// fact about the attach and REQ-SHELL-61 did not change it — it only stopped the handlers
// GATING the snapshot on it (see the req61 tests below). Kept because the value is still
// returned, still carried by both handlers, and still read when interpreting the
// REQ-SHELL-41 first-frame diagnostic.
@(test)
test_req29_attach_reports_late_join_only_for_extra_viewers :: proc(t: ^testing.T) {
	ids := http_test_id_generator()
	svc := shell_session_svc.new_shell_session_service(ids = &ids)
	defer shell_session_svc.shell_session_service_free(&svc)

	// An EMPTY bridge_id keeps this test on the gate itself: no bridge command is
	// dispatched, so no command sink is needed and nothing here depends on the
	// attach/detach wire format that other tests already cover.
	session_id := "sh_req29_gate"
	bridge_id := ""
	sock1 := net.TCP_Socket(301)
	sock2 := net.TCP_Socket(302)

	testing.expect(
		t,
		shell_session_svc.shell_session_attach(&svc, session_id, sock1, bridge_id).status == .Attached,
		"0->1 is not a late join: the bridge attach it triggers produces the pty-host catchup",
	)
	testing.expect(
		t,
		shell_session_svc.shell_session_attach(&svc, session_id, sock2, bridge_id).status == .Late_Join,
		"1->2 IS a late join: no bridge attach fires, so nothing repaints this viewer",
	)

	// Re-attaching an ALREADY PRESENT socket still reports late_join, because the session
	// genuinely has viewers — the dedup path must not be mistaken for a first viewer.
	testing.expect(
		t,
		shell_session_svc.shell_session_attach(&svc, session_id, sock2, bridge_id).status == .Late_Join,
		"a duplicate attach on a watched session is still a late join",
	)

	shell_session_svc.shell_session_detach(&svc, session_id, sock1, bridge_id)
	shell_session_svc.shell_session_detach(&svc, session_id, sock2, bridge_id)
	testing.expect_value(t, shell_session_svc.shell_session_viewer_count(&svc, session_id), 0)

	testing.expect(
		t,
		shell_session_svc.shell_session_attach(&svc, session_id, sock1, bridge_id).status == .Attached,
		"once the last viewer leaves, the next one is a first viewer again",
	)
	shell_session_svc.shell_session_detach(&svc, session_id, sock1, bridge_id)
}

// Targeting: the frame reaches the ONE socket it was handed. This is what makes a late-join
// repaint possible without disturbing viewers that are already painted correctly.
@(test)
test_req29_screen_frame_is_written_to_the_given_socket :: proc(t: ^testing.T) {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if listen_err != nil {
		testing.fail_now(t, "could not listen on loopback")
	}
	defer net.close(listener)
	endpoint, ep_err := net.bound_endpoint(listener)
	if ep_err != nil {
		testing.fail_now(t, "could not read bound endpoint")
	}
	client, dial_err := net.dial_tcp(endpoint)
	if dial_err != nil {
		testing.fail_now(t, "could not dial loopback")
	}
	defer net.close(client)
	hub, _, accept_err := net.accept_tcp(listener)
	if accept_err != nil {
		testing.fail_now(t, "could not accept loopback")
	}
	defer net.close(hub)

	reply := "{\"ok\":true,\"unchanged\":false,\"hash\":\"abc\",\"output\":\"hello pane\"}"
	testing.expect(t, _shell_stream_write_screen_frame(nil, "", hub, reply), "write must succeed on a live socket")

	buf: [512]byte
	n, recv_err := net.recv_tcp(client, buf[:])
	testing.expect(t, recv_err == nil && n > 0, "client must receive the screen frame")

	got := pty_test_first_server_frame_json(buf[:n])
	testing.expect(t, strings.contains(got, "\"type\":\"screen\""), "received frame is a screen frame")

	// Decode the payload actually delivered and prove the repaint prefix survived the wire.
	key := "\"data_b64\":\""
	idx := strings.index(got, key)
	testing.expect(t, idx >= 0, "delivered frame carries data_b64")
	if idx < 0 do return
	rest := got[idx + len(key):]
	end := strings.index_byte(rest, '"')
	testing.expect(t, end > 0, "data_b64 is terminated")
	if end <= 0 do return

	decoded, dec_err := base64.decode(rest[:end])
	testing.expect(t, dec_err == nil, "delivered payload is valid base64")
	defer delete(decoded)
	testing.expect_value(t, string(decoded), "\x1b[2J\x1b[Hhello pane")
}

// ---------------------------------------------------------------------------
// REQ-SHELL-30: the snapshot repaint staircased because pane rows were joined with a
// bare LF. A VT drops one row on LF and KEEPS the column, so every row began where the
// previous one ended.
//
// WHAT THESE TESTS PROVE, STATED EXACTLY: that the payload builder emits exactly one
// "\r\n" per row boundary, never "\r\n\r\n", and never a trailing separator after the
// last row. WHAT THEY DO NOT PROVE: xterm.js's deferred-wrap cancellation — that writing
// the cols-th character sets a pending wrap which a following CR cancels, so CRLF after a
// genuinely full-width row yields one newline rather than two. That is terminal-emulator
// behaviour, it cannot be executed from an Odin unit test, and it is the USER'S re-check.
// It is not measured here and must not be reported as if it were.
//
// BOTH PANES ARE COVERED BY THESE TESTS AND THERE IS DELIBERATELY NO AGENT TWIN. The shell
// and agent snapshot senders (shell_stream_send_shell_screen_snapshot :77,
// shell_stream_send_agent_screen_snapshot :94) both funnel through
// _shell_stream_write_screen_frame :66, whose only payload source is
// shell_stream_screen_payload_b64. Testing the builder tests both paths; a duplicated agent
// test would assert the same function twice and imply two fixes where there is one.

// _req30_decoded_payload returns the decoded screen payload for pane text. Caller owns it.
@(private = "file")
_req30_decoded_payload :: proc(t: ^testing.T, pane_output: string) -> string {
	payload := _screen_payload_b64(pane_output)
	defer delete(payload)
	decoded, err := base64.decode(payload)
	if err != nil {
		testing.fail_now(t, "payload must be valid base64")
	}
	return string(decoded)
}

@(test)
test_req30_rows_are_joined_with_crlf_not_bare_lf :: proc(t: ^testing.T) {
	// Three rows as the bridge delivers them: one string per grid row, bare LF between.
	got := _req30_decoded_payload(t, "row one\nrow two\nrow three")
	defer delete(got)

	testing.expect(
		t,
		strings.has_prefix(got, SHELL_SCREEN_REPAINT_PREFIX),
		"the repaint prefix must still come FIRST — the CRLF translation must not displace it",
	)
	testing.expect_value(t, got, "\x1b[2J\x1b[Hrow one\r\nrow two\r\nrow three")

	// Three rows means exactly two boundaries. Counting is what catches both failure
	// directions at once: a missed CR staircases, an extra one double-spaces.
	testing.expect_value(t, strings.count(got, "\r\n"), 2)
	testing.expect_value(t, strings.count(got, "\n"), 2) // every LF is part of a CRLF
}

// FULL-WIDTH ROWS ARE COMMON, NOT EXOTIC: vt.rs trims trailing blanks and REQ-SHELL-29
// captures at the VIEWER'S OWN cols, so any horizontal rule, box border or progress bar
// produces one. This is the case where a staircase fix turns into a double-spacing bug.
//
// The rule here is 80 box-drawing characters — 80 display columns but 240 BYTES, because
// U+2500 is three bytes in UTF-8. That is deliberate: it proves the builder adds exactly
// one separator regardless of byte length, so nothing in it can be computing a width.
@(test)
test_req30_full_width_row_does_not_double_space :: proc(t: ^testing.T) {
	rule := strings.repeat("\u2500", 80)
	defer delete(rule)
	testing.expect_value(t, len(rule), 240) // 80 columns, 240 bytes — width is NOT length

	pane := strings.concatenate({"header", "\n", rule, "\n", "footer"})
	defer delete(pane)

	got := _req30_decoded_payload(t, pane)
	defer delete(got)

	expected := strings.concatenate({SHELL_SCREEN_REPAINT_PREFIX, "header\r\n", rule, "\r\nfooter"})
	defer delete(expected)
	testing.expect_value(t, got, expected)

	// The three properties that constitute "does not double-space", asserted directly.
	testing.expect_value(t, strings.count(got, "\r\n"), 2)
	testing.expect(t, !strings.contains(got, "\r\n\r\n"), "a full-width row must not produce a blank line between rows")
	testing.expect(
		t,
		!strings.has_suffix(got, "\r\n"),
		"no trailing separator after the last row — that would push an extra blank line on every repaint",
	)
}

// vt.rs capture() writes SGR runs INLINE into each row, so a row's byte length exceeds its
// display width. Nothing may derive a line count or a separator decision from length.
@(test)
test_req30_inline_sgr_row_gets_exactly_one_separator :: proc(t: ^testing.T) {
	// A bold-red row, exactly as capture() emits it: escapes embedded in the row text.
	sgr_row := "\x1b[1m\x1b[31mERROR\x1b[0m failed to connect"
	pane := strings.concatenate({"before\n", sgr_row, "\nafter"})
	defer delete(pane)

	got := _req30_decoded_payload(t, pane)
	defer delete(got)

	testing.expect_value(t, strings.count(got, "\r\n"), 2)
	testing.expect(t, strings.contains(got, sgr_row), "SGR runs pass through untouched")
	testing.expect(
		t,
		!strings.contains(got, "\r\n\r\n"),
		"an SGR-bearing row is still ONE row however many bytes it carries",
	)
}

// Defensive: if a pane source ever starts sending CRLF itself, the builder must not turn it
// into "\r\r\n". Cheap to guarantee, and the obvious way this fix goes wrong later.
@(test)
test_req30_an_existing_cr_is_not_doubled :: proc(t: ^testing.T) {
	got := _req30_decoded_payload(t, "already\r\ncrlf")
	defer delete(got)

	testing.expect_value(t, got, "\x1b[2J\x1b[Halready\r\ncrlf")
	testing.expect(t, !strings.contains(got, "\r\r"), "a CR already present must not be doubled")
}

// An empty pane must stay empty: the builder is called only behind the output == "" guard in
// _shell_stream_write_screen_frame, but it must not invent a separator if that guard moves.
@(test)
test_req30_empty_pane_text_adds_no_separator :: proc(t: ^testing.T) {
	got := _req30_decoded_payload(t, "")
	defer delete(got)
	testing.expect_value(t, got, SHELL_SCREEN_REPAINT_PREFIX)
}

// ---------------------------------------------------------------------------
// REQ-SHELL-61: THE FIRST VIEWER OF A STREAM NEVER GOT A SCREEN SNAPSHOT.
//
// Both stream handlers gated the snapshot on `late_join && !screen_sent`, so viewer #1 was
// skipped and left to the bridge's 0->1 pty-host catchup. When that catchup paints little
// or nothing — it is skipped outright when the bridge already holds a live stream worker
// for the session — viewer #1 had NO screen source and the pane came up BLANK. That is the
// reported neovim defect, and it is why a re-render or a tab switch appeared to fix it:
// either one made the viewer a late joiner, where the snapshot did fire.
//
// WHAT THESE TESTS PROVE: the gate in shell_stream_should_send_screen_snapshot answers YES
// for a first viewer, stays once-per-stream, and requires real geometry.
//
// WHAT THEY DO NOT PROVE, stated so it is not read as more than it is: that a browser
// actually paints. These execute the hub-side decision and, through the existing targeting
// test above, the frame that decision produces. No browser is driven here. The
// experiment-ON retest is the user's.
//
// MUTATION-VALIDATED. Restoring the old gate — `if !late_join do return false` as the first
// line of shell_stream_should_send_screen_snapshot — makes
// test_req61_first_viewer_must_be_offered_a_snapshot FAIL and the other two pass, which is
// exactly the defect this task fixes. A new test that has never failed proves nothing.

@(test)
test_req61_first_viewer_must_be_offered_a_snapshot :: proc(t: ^testing.T) {
	testing.expect(
		t,
		shell_stream_should_send_screen_snapshot(false, false, 50, 200),
		"the FIRST viewer (late_join=false) must be offered a screen snapshot: the bridge catchup is not a reliable paint for it, and without this it has no screen source at all",
	)
	// The late joiner keeps the behaviour REQ-SHELL-29 gave it. The fix ADDS viewer #1; it
	// does not trade one viewer for the other.
	testing.expect(
		t,
		shell_stream_should_send_screen_snapshot(true, false, 50, 200),
		"a late joiner must still be offered a snapshot",
	)
}

@(test)
test_req61_snapshot_is_offered_once_per_stream :: proc(t: ^testing.T) {
	// `screen_sent` is the only thing that closes the gate now, so it carries the whole
	// once-only property for BOTH viewer positions. A viewer resizes repeatedly — every
	// later resize must cost no pane capture.
	testing.expect(
		t,
		!shell_stream_should_send_screen_snapshot(false, true, 50, 200),
		"a first viewer that already received its snapshot must not earn another on a later resize",
	)
	testing.expect(
		t,
		!shell_stream_should_send_screen_snapshot(true, true, 50, 200),
		"a late joiner that already received its snapshot must not earn another either",
	)
}

// The trap, pinned deliberately rather than left implicit: the snapshot is only ever
// produced from a resize frame carrying real geometry, because capturing at a guessed 80
// columns would re-wrap the screen. So a client that sends no resize, or sends 0/0, gets
// NO snapshot — and since REQ-SHELL-61 made this the first viewer's screen source, that is
// now a blank first paint rather than a missing repaint. Asserted so that anyone who
// loosens the geometry rule has to come here and say why.
@(test)
test_req61_snapshot_requires_real_geometry :: proc(t: ^testing.T) {
	testing.expect(
		t,
		!shell_stream_should_send_screen_snapshot(false, false, 0, 0),
		"a 0x0 resize must not trigger a capture: the rendered width would be a guess",
	)
	testing.expect(
		t,
		!shell_stream_should_send_screen_snapshot(false, false, 50, 0),
		"zero columns is not real geometry",
	)
	testing.expect(
		t,
		!shell_stream_should_send_screen_snapshot(false, false, 0, 200),
		"zero rows is not real geometry",
	)
}

// ---------------------------------------------------------------------------
// Milestone M1: Trailing blank row trimming, trailing prompt space preservation,
// ANSI CUP cursor repositioning, and JSON frame cursor propagation.
// ---------------------------------------------------------------------------

// TEST M1.1: Trimming 23 trailing blank rows from single-line prompt screen.
@(test)
test_m1_trailing_blank_rows_are_trimmed_from_prompt_screen :: proc(t: ^testing.T) {
	lines := make([dynamic]string, context.temp_allocator)
	append(&lines, "sh-5.2$ ")
	for _ in 0 ..< 23 {
		append(&lines, "")
	}
	pane := strings.join(lines[:], "\n")
	defer delete(pane)

	got := _req30_decoded_payload(t, pane)
	defer delete(got)

	testing.expect(
		t,
		strings.has_prefix(got, SHELL_SCREEN_REPAINT_PREFIX),
		"snapshot must begin with erase-screen + cursor-home",
	)

	expected := strings.concatenate({SHELL_SCREEN_REPAINT_PREFIX, "sh-5.2$ "})
	defer delete(expected)
	testing.expect_value(t, got, expected)

	// Invariant: zero CRLFs. All 23 empty lines must be trimmed.
	testing.expect_value(t, strings.count(got, "\r\n"), 0)
	testing.expect_value(t, strings.count(got, "\n"), 0)
	testing.expect(
		t,
		!strings.has_suffix(got, "\r\n"),
		"must have no trailing CRLF separator",
	)
}

// TEST M1.2: Trimming trailing whitespace-only rows while preserving trailing prompt space.
@(test)
test_m1_trimming_preserves_prompt_trailing_space_and_whitespace_rows :: proc(t: ^testing.T) {
	pane := "user@host:~$ \n   \n\t\t\n  \t  "
	got := _req30_decoded_payload(t, pane)
	defer delete(got)

	expected := strings.concatenate({SHELL_SCREEN_REPAINT_PREFIX, "user@host:~$ "})
	defer delete(expected)
	testing.expect_value(t, got, expected)

	testing.expect(
		t,
		strings.has_suffix(got, "user@host:~$ "),
		"trailing space on the prompt line must NOT be stripped by whitespace row trimming",
	)
	testing.expect_value(t, strings.count(got, "\r\n"), 0)
}

// TEST M1.3: Interior blank lines are preserved while trailing blank rows are stripped.
@(test)
test_m1_interior_blank_rows_preserved_while_trailing_trimmed :: proc(t: ^testing.T) {
	pane := "Welcome to Shell\n\nType 'help' for info\n\n\n\n"
	got := _req30_decoded_payload(t, pane)
	defer delete(got)

	expected := strings.concatenate({
		SHELL_SCREEN_REPAINT_PREFIX,
		"Welcome to Shell\r\n\r\nType 'help' for info",
	})
	defer delete(expected)
	testing.expect_value(t, got, expected)

	testing.expect_value(t, strings.count(got, "\r\n"), 2)
	testing.expect(
		t,
		!strings.has_suffix(got, "\r\n"),
		"no trailing CRLF after the last content line",
	)
}

// TEST M1.4: Repaint payload with ANSI CUP cursor repositioning sequence.
@(test)
test_m1_screen_payload_with_cursor_repositioning_ansi_cup :: proc(t: ^testing.T) {
	// Scenario A: Single prompt at row 0, col 8 ("sh-5.2$ ") -> ANSI 1-indexed: row 1, col 9 (\x1b[1;9H)
	payload_a := _screen_payload_b64("sh-5.2$ \n\n\n", 0, 8)
	defer delete(payload_a)
	decoded_a, err_a := base64.decode(payload_a)
	testing.expect(t, err_a == nil, "valid base64")
	defer delete(decoded_a)
	got_a := string(decoded_a)

	expected_a := strings.concatenate({
		SHELL_SCREEN_REPAINT_PREFIX,
		"sh-5.2$ \x1b[1;9H",
	})
	defer delete(expected_a)
	testing.expect_value(t, got_a, expected_a)
	testing.expect(t, strings.has_suffix(got_a, "\x1b[1;9H"), "payload ends with ANSI CUP sequence")

	// Scenario B: Multiline output with cursor at row 2, col 5 -> \x1b[3;6H
	payload_b := _screen_payload_b64("row0\nrow1\nrow2\n\n\n", 2, 5)
	defer delete(payload_b)
	decoded_b, err_b := base64.decode(payload_b)
	testing.expect(t, err_b == nil, "valid base64")
	defer delete(decoded_b)
	got_b := string(decoded_b)

	expected_b := strings.concatenate({
		SHELL_SCREEN_REPAINT_PREFIX,
		"row0\r\nrow1\r\nrow2\x1b[3;6H",
	})
	defer delete(expected_b)
	testing.expect_value(t, got_b, expected_b)

	// Scenario C: Omitted / negative cursor coordinates (-1) must NOT append CUP
	payload_c := _screen_payload_b64("prompt$ ", -1, -1)
	defer delete(payload_c)
	decoded_c, _ := base64.decode(payload_c)
	defer delete(decoded_c)
	got_c := string(decoded_c)

	expected_c := strings.concatenate({SHELL_SCREEN_REPAINT_PREFIX, "prompt$ "})
	defer delete(expected_c)
	testing.expect_value(t, got_c, expected_c)
	testing.expect(
		t,
		!strings.contains(got_c[len(SHELL_SCREEN_REPAINT_PREFIX):], "\x1b["),
		"negative cursor coordinates must not append CUP sequence",
	)
}

// TEST M1.5: Frame JSON contains cursor coordinates when present, omits when negative.
@(test)
test_m1_frame_json_contains_cursor_coordinates :: proc(t: ^testing.T) {
	// Case 1: Coordinates present (row=0, col=8)
	frame1 := _screen_frame_json("QUJD", 0, 8)
	defer delete(frame1)

	testing.expect(t, strings.contains(frame1, "\"type\":\"screen\""), "type is screen")
	testing.expect(t, strings.contains(frame1, "\"data_b64\":\"QUJD\""), "payload is data_b64")
	testing.expect(t, strings.contains(frame1, "\"cursor_row\":0"), "cursor_row is 0")
	testing.expect(t, strings.contains(frame1, "\"cursor_col\":8"), "cursor_col is 8")

	// Case 2: Negative/unspecified coordinates (-1, -1)
	frame2 := _screen_frame_json("QUJD", -1, -1)
	defer delete(frame2)

	testing.expect(t, strings.contains(frame2, "\"type\":\"screen\""), "type is screen")
	testing.expect(t, strings.contains(frame2, "\"data_b64\":\"QUJD\""), "payload is data_b64")
	testing.expect(t, !strings.contains(frame2, "cursor_row"), "cursor_row omitted when negative")
	testing.expect(t, !strings.contains(frame2, "cursor_col"), "cursor_col omitted when negative")

	// Case 3: Default argument invocation
	frame3 := _screen_frame_json("QUJD")
	defer delete(frame3)
	testing.expect_value(t, frame3, "{\"type\":\"screen\",\"data_b64\":\"QUJD\",\"is_encrypted\":false,\"is_snapshot\":true}")
}

// TEST M1.6: End-to-end socket write propagates cursor coordinates and CUP from pane_reply.
@(test)
test_m1_write_screen_frame_propagates_cursor_from_pane_reply :: proc(t: ^testing.T) {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if listen_err != nil do testing.fail_now(t, "could not listen on loopback")
	defer net.close(listener)
	endpoint, ep_err := net.bound_endpoint(listener)
	if ep_err != nil do testing.fail_now(t, "could not read bound endpoint")

	client, dial_err := net.dial_tcp(endpoint)
	if dial_err != nil do testing.fail_now(t, "could not dial loopback")
	defer net.close(client)

	hub, _, accept_err := net.accept_tcp(listener)
	if accept_err != nil do testing.fail_now(t, "could not accept loopback")
	defer net.close(hub)

	// Reply carries cursor_row and cursor_col alongside output
	reply := "{\"ok\":true,\"unchanged\":false,\"hash\":\"abc\",\"output\":\"sh-5.2$ \\n\\n\\n\",\"cursor_row\":0,\"cursor_col\":8}"
	testing.expect(t, _shell_stream_write_screen_frame(nil, "", hub, reply), "write must succeed")

	buf: [1024]byte
	n, recv_err := net.recv_tcp(client, buf[:])
	testing.expect(t, recv_err == nil && n > 0, "client must receive frame")

	got := pty_test_first_server_frame_json(buf[:n])
	testing.expect(t, strings.contains(got, "\"type\":\"screen\""), "type is screen")
	testing.expect(t, strings.contains(got, "\"cursor_row\":0"), "cursor_row propagated")
	testing.expect(t, strings.contains(got, "\"cursor_col\":8"), "cursor_col propagated")

	// Verify decoded data_b64 contains prefix, trimmed prompt, and CUP \x1b[1;9H
	key := "\"data_b64\":\""
	idx := strings.index(got, key)
	testing.expect(t, idx >= 0, "delivered frame carries data_b64")
	if idx < 0 do return
	rest := got[idx + len(key):]
	end := strings.index_byte(rest, '"')
	testing.expect(t, end > 0, "data_b64 is terminated")
	if end <= 0 do return

	decoded, dec_err := base64.decode(rest[:end])
	testing.expect(t, dec_err == nil, "delivered payload is valid base64")
	defer delete(decoded)

	expected_payload := strings.concatenate({SHELL_SCREEN_REPAINT_PREFIX, "sh-5.2$ \x1b[1;9H"})
	defer delete(expected_payload)
	testing.expect_value(t, string(decoded), expected_payload)
}

// --- Consolidated from adversarial_challenge_m1_test.odin ---

@(test)
test_adv_trim_empty_string :: proc(t: ^testing.T) {
	got := _shell_screen_trim_trailing_blank_rows("")
	defer delete(got)
	testing.expect_value(t, got, "")
}

@(test)
test_adv_trim_pure_whitespace_variations :: proc(t: ^testing.T) {
	cases := []string{
		" ",
		"    ",
		"\t",
		"\t\t\t",
		" \t \t ",
		"\r",
		"\r\r\r",
		"\n",
		"\n\n\n",
		"\r\n",
		"\r\n\r\n",
		"   \n   \n   ",
		"\t\t\n  \t  \n\r\n",
		" \r \n \t \r\n",
	}

	for c in cases {
		got := _shell_screen_trim_trailing_blank_rows(c)
		defer delete(got)
		testing.expect_value(t, got, "")
	}
}

@(test)
test_adv_trim_prompt_with_trailing_spaces :: proc(t: ^testing.T) {
	// 1. Single line with spaces at end
	s1 := "user@host:~$ "
	got1 := _shell_screen_trim_trailing_blank_rows(s1)
	defer delete(got1)
	testing.expect_value(t, got1, "user@host:~$ ")

	// 2. Single line with multiple trailing spaces followed by 50 blank rows
	lines := make([dynamic]string, context.temp_allocator)
	append(&lines, "sh-5.2$    ")
	for _ in 0 ..< 50 {
		append(&lines, "")
	}
	s2 := strings.join(lines[:], "\n")
	defer delete(s2)
	got2 := _shell_screen_trim_trailing_blank_rows(s2)
	defer delete(got2)
	testing.expect_value(t, got2, "sh-5.2$    ")

	// 3. Prompt ending with tab
	s3 := "prompt>\t\n\n\n"
	got3 := _shell_screen_trim_trailing_blank_rows(s3)
	defer delete(got3)
	testing.expect_value(t, got3, "prompt>\t")
}

@(test)
test_adv_trim_interior_blank_lines_preservation :: proc(t: ^testing.T) {
	// Multiple consecutive interior blank lines
	input := "Header\n\n\n\nBody line 1\n\nBody line 2\n\n\n"
	got := _shell_screen_trim_trailing_blank_rows(input)
	defer delete(got)
	testing.expect_value(t, got, "Header\n\n\n\nBody line 1\n\nBody line 2")

	// Interior blank lines with spaces and tabs
	input2 := "Header\n   \n\t\t\nBody\n  \n  "
	got2 := _shell_screen_trim_trailing_blank_rows(input2)
	defer delete(got2)
	testing.expect_value(t, got2, "Header\n   \n\t\t\nBody")
}

@(test)
test_adv_trim_crlf_vs_lf_line_endings :: proc(t: ^testing.T) {
	// Pure CRLF input
	input_crlf := "line 1\r\nline 2\r\n\r\n\r\n"
	got_crlf := _shell_screen_trim_trailing_blank_rows(input_crlf)
	defer delete(got_crlf)
	testing.expect_value(t, got_crlf, "line 1\r\nline 2")

	// Mixed LF and CRLF
	input_mixed := "line 1\nline 2\r\nline 3\n\r\n\n"
	got_mixed := _shell_screen_trim_trailing_blank_rows(input_mixed)
	defer delete(got_mixed)
	testing.expect_value(t, got_mixed, "line 1\nline 2\r\nline 3")

	// CR without LF (carriage return within line or before newline)
	input_cr := "overwrite\rprompt> \n\n"
	got_cr := _shell_screen_trim_trailing_blank_rows(input_cr)
	defer delete(got_cr)
	testing.expect_value(t, got_cr, "overwrite\rprompt> ")
}

@(test)
test_adv_trim_unicode_and_special_characters :: proc(t: ^testing.T) {
	// Unicode box drawing and emojis
	input := "┌───┐\n│ 😀 │\n└───┘\n\n\n"
	got := _shell_screen_trim_trailing_blank_rows(input)
	defer delete(got)
	testing.expect_value(t, got, "┌───┐\n│ 😀 │\n└───┘")

	// Japanese full-width space U+3000 on trailing line
	// Note: U+3000 is 3 bytes (0xE3, 0x80, 0x80) - treated as non-whitespace by ASCII byte scanner
	input_cjk := "line 1\n\u3000\n"
	got_cjk := _shell_screen_trim_trailing_blank_rows(input_cjk)
	defer delete(got_cjk)
	testing.expect_value(t, got_cjk, "line 1\n\u3000")
}

// ---------------------------------------------------------------------------
// Category 2: ANSI CUP Repaint & Coordinate Edge Cases
// ---------------------------------------------------------------------------

@(test)
test_adv_repaint_origin_coordinate :: proc(t: ^testing.T) {
	// (0, 0) -> ANSI 1-indexed \x1b[1;1H
	got := _shell_screen_repaint_text("hello", 0, 0)
	defer delete(got)
	testing.expect_value(t, got, "\x1b[2J\x1b[Hhello\x1b[1;1H")
}

@(test)
test_adv_repaint_large_and_extreme_coordinates :: proc(t: ^testing.T) {
	// (999, 1999) -> \x1b[1000;2000H
	got1 := _shell_screen_repaint_text("grid", 999, 1999)
	defer delete(got1)
	testing.expect_value(t, got1, "\x1b[2J\x1b[Hgrid\x1b[1000;2000H")

	// Max u16 boundary (65535, 65535) -> \x1b[65536;65536H
	got2 := _shell_screen_repaint_text("grid", 65535, 65535)
	defer delete(got2)
	testing.expect_value(t, got2, "\x1b[2J\x1b[Hgrid\x1b[65536;65536H")
}

@(test)
test_adv_repaint_negative_coordinates :: proc(t: ^testing.T) {
	// Both negative
	got1 := _shell_screen_repaint_text("grid", -1, -1)
	defer delete(got1)
	testing.expect_value(t, got1, "\x1b[2J\x1b[Hgrid")

	// Extremely negative
	got2 := _shell_screen_repaint_text("grid", -9999, -500)
	defer delete(got2)
	testing.expect_value(t, got2, "\x1b[2J\x1b[Hgrid")

	// Mixed: valid row, negative col -> CUP omitted
	got3 := _shell_screen_repaint_text("grid", 5, -1)
	defer delete(got3)
	testing.expect_value(t, got3, "\x1b[2J\x1b[Hgrid")

	// Mixed: negative row, valid col -> CUP omitted
	got4 := _shell_screen_repaint_text("grid", -1, 10)
	defer delete(got4)
	testing.expect_value(t, got4, "\x1b[2J\x1b[Hgrid")
}

@(test)
test_adv_repaint_on_empty_and_whitespace_pane :: proc(t: ^testing.T) {
	// Empty pane with coordinates
	got1 := _shell_screen_repaint_text("", 0, 5)
	defer delete(got1)
	testing.expect_value(t, got1, "\x1b[2J\x1b[H\x1b[1;6H")

	// Whitespace-only pane with coordinates: trimmed to empty body, homes and positions cursor
	got2 := _shell_screen_repaint_text("   \n\n  \t  \n", 0, 0)
	defer delete(got2)
	testing.expect_value(t, got2, "\x1b[2J\x1b[H\x1b[1;1H")
}

// ---------------------------------------------------------------------------
// Category 3: JSON Frame Serialization Extremes
// ---------------------------------------------------------------------------

@(test)
test_adv_frame_json_extreme_coordinates :: proc(t: ^testing.T) {
	// Origin (0, 0)
	frame0 := _screen_frame_json("QUJD", 0, 0)
	defer delete(frame0)
	testing.expect_value(t, frame0, "{\"type\":\"screen\",\"data_b64\":\"QUJD\",\"is_encrypted\":false,\"is_snapshot\":true,\"cursor_row\":0,\"cursor_col\":0}")

	// Large coordinates
	frame_lg := _screen_frame_json("QUJD", 65535, 32768)
	defer delete(frame_lg)
	testing.expect_value(t, frame_lg, "{\"type\":\"screen\",\"data_b64\":\"QUJD\",\"is_encrypted\":false,\"is_snapshot\":true,\"cursor_row\":65535,\"cursor_col\":32768}")

	// Negative coordinates omitted
	frame_neg := _screen_frame_json("QUJD", -10, -20)
	defer delete(frame_neg)
	testing.expect_value(t, frame_neg, "{\"type\":\"screen\",\"data_b64\":\"QUJD\",\"is_encrypted\":false,\"is_snapshot\":true}")
}

// ---------------------------------------------------------------------------
// Category 4: High-Volume & Chunking Stress Test
// ---------------------------------------------------------------------------

@(test)
test_adv_high_volume_blank_lines_stress :: proc(t: ^testing.T) {
	// 5,000 blank lines after a prompt
	lines := make([dynamic]string, context.temp_allocator)
	append(&lines, "fast_prompt$ ")
	for _ in 0 ..< 5000 {
		append(&lines, "")
	}
	huge_pane := strings.join(lines[:], "\n")
	defer delete(huge_pane)

	got := _shell_screen_repaint_text(huge_pane, 0, 13)
	defer delete(got)

	// Must be trimmed cleanly in O(N) without hanging or memory explosion
	testing.expect_value(t, got, "\x1b[2J\x1b[Hfast_prompt$ \x1b[1;14H")
}

@(test)
test_adv_chunked_snapshot_with_cursor_cup :: proc(t: ^testing.T) {
	// Generate a screen payload exceeding SHELL_SCREEN_CHUNK_DECODED_BYTES (32 KiB)
	// Say 500 lines of 100 characters each (~50 KB)
	repeat_x := strings.repeat("x", 85, context.temp_allocator)
	lines := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< 500 {
		append(&lines, fmt.tprintf("Line %04d: %s", i, repeat_x))
	}
	pane := strings.join(lines[:], "\n")
	defer delete(pane)

	cursor_r := 499
	cursor_c := 20
	repaint := _shell_screen_repaint_text(pane, cursor_r, cursor_c)
	defer delete(repaint)

	// Verify repaint is > 32KB
	testing.expect(t, len(repaint) > SHELL_SCREEN_CHUNK_DECODED_BYTES, "repaint must exceed 32KB")

	// Walk chunks using _shell_screen_chunk_end and verify invariants
	chunk_count := 0
	offset := 0
	saw_cup_in_last_chunk := false

	expected_cup := fmt.tprintf("\x1b[%d;%dH", cursor_r + 1, cursor_c + 1)

	for offset < len(repaint) {
		chunk_count += 1
		end := _shell_screen_chunk_end(repaint, offset)
		chunk := repaint[offset:end]

		if chunk_count == 1 {
			// First chunk must lead with repaint prefix
			testing.expect(t, strings.has_prefix(chunk, SHELL_SCREEN_REPAINT_PREFIX), "first chunk has prefix")
		}

		if end == len(repaint) {
			// Final chunk must end with ANSI CUP
			if strings.has_suffix(chunk, expected_cup) {
				saw_cup_in_last_chunk = true
			}
		}

		offset = end
	}

	testing.expect(t, chunk_count >= 2, "must be split into at least 2 chunks")
	testing.expect(t, saw_cup_in_last_chunk, "final chunk must contain the ANSI CUP sequence")
}

// ---------------------------------------------------------------------------
// Category 5: End-to-End Socket Malformed & Adversarial Reply Frame Parsing
// ---------------------------------------------------------------------------

@(test)
test_adv_write_screen_frame_malformed_json_reply :: proc(t: ^testing.T) {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if listen_err != nil do testing.fail_now(t, "could not listen on loopback")
	defer net.close(listener)
	endpoint, _ := net.bound_endpoint(listener)
	client, _ := net.dial_tcp(endpoint)
	defer net.close(client)
	hub, _, _ := net.accept_tcp(listener)
	defer net.close(hub)

	// 1. Reply missing "output" field
	bad_reply1 := "{\"ok\":true,\"unchanged\":false,\"cursor_row\":0,\"cursor_col\":8}"
	testing.expect(t, !_shell_stream_write_screen_frame(nil, "", hub, bad_reply1), "missing output writes nothing")

	// 2. Reply with empty output string
	bad_reply2 := "{\"ok\":true,\"output\":\"\",\"cursor_row\":0,\"cursor_col\":8}"
	testing.expect(t, !_shell_stream_write_screen_frame(nil, "", hub, bad_reply2), "empty output writes nothing")

	// 3. Reply with missing coordinates defaults to -1 (no CUP, no json coords)
	no_coords_reply := "{\"ok\":true,\"output\":\"my prompt> \"}"
	testing.expect(t, _shell_stream_write_screen_frame(nil, "", hub, no_coords_reply), "write succeeds without coords")

	buf: [512]byte
	n, _ := net.recv_tcp(client, buf[:])
	testing.expect(t, n > 0, "client receives frame")
	got_str := string(buf[:n])
	testing.expect(t, !strings.contains(got_str, "cursor_row"), "cursor_row omitted when absent from reply")
	testing.expect(t, !strings.contains(got_str, "cursor_col"), "cursor_col omitted when absent from reply")
}

@(test)
test_alt_screen_repaint_emits_1049h_before_erase_screen_prefix :: proc(t: ^testing.T) {
	// Alternate screen prefix (\x1b[?1049h) must be emitted BEFORE \x1b[2J\x1b[H so xterm.js
	// enters the alternate buffer first and does not erase the normal (primary) buffer.
	got := _shell_screen_repaint_text("\x1b[?1049h\x1b[?25l~\n~\n-- NORMAL --\n", 2, 0)
	defer delete(got)

	testing.expect_value(t, got, "\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H~\r\n~\r\n-- NORMAL --\x1b[3;1H")
}
