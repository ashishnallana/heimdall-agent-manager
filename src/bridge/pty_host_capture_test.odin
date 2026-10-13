package main

import "core:strings"
import "core:testing"

// BR-4 tests: the UI capture proxy's screen->pane-text conversion (tail + limit +
// truncation) and the capture-result JSON shape. The live host.capture round-trip
// is covered by the client codec tests + the daemon's own HOST-1 tests; here we
// lock in the proxy's pure conversion + result assembly.

@(test)
pty_host_screen_to_output_joins_all_when_under_limit :: proc(t: ^testing.T) {
	lines := []string{"a", "b", "c"}
	out, count, trunc := bridge_pty_host_screen_to_output(lines, 120)
	defer delete(out)
	testing.expect_value(t, out, "a\nb\nc")
	testing.expect_value(t, count, 3)
	testing.expect_value(t, trunc, false)
}

@(test)
pty_host_screen_to_output_keeps_tail_when_over_limit :: proc(t: ^testing.T) {
	lines := []string{"l1", "l2", "l3", "l4", "l5"}
	out, count, trunc := bridge_pty_host_screen_to_output(lines, 2)
	defer delete(out)
	// keeps the LAST 2 lines (the tail), matching tmux capture semantics
	testing.expect_value(t, out, "l4\nl5")
	testing.expect_value(t, count, 2)
	testing.expect_value(t, trunc, true)
}

@(test)
pty_host_screen_to_output_zero_limit_keeps_all :: proc(t: ^testing.T) {
	lines := []string{"x", "y"}
	out, count, trunc := bridge_pty_host_screen_to_output(lines, 0)
	defer delete(out)
	testing.expect_value(t, out, "x\ny")
	testing.expect_value(t, count, 2)
	testing.expect_value(t, trunc, false)
}

@(test)
pty_host_capture_result_json_shape_ok :: proc(t: ^testing.T) {
	pending := Bridge_Pane_Capture_Pending{
		command_id              = "cmd_1",
		pane_capture_request_id = "pcr_1",
		agent_instance_id       = "inst_a",
		width                   = 80,
	}
	// Success shape carries output + line_count + ok:true.
	ok_json := bridge_pane_capture_result_json(pending, true, "", "", "hello\nworld", 2, false)
	defer delete(ok_json)
	testing.expect(t, strings.contains(ok_json, "\"type\":\"pane_capture_result\""), "type present")
	testing.expect(t, strings.contains(ok_json, "\"ok\":true"), "ok true")
	testing.expect(t, strings.contains(ok_json, "\"command_id\":\"cmd_1\""), "command id")
	testing.expect(t, strings.contains(ok_json, "\"pane_capture_request_id\":\"pcr_1\""), "request id")
	testing.expect(t, strings.contains(ok_json, "\"output\":\"hello\\nworld\""), "output escaped + present")
	testing.expect(t, strings.contains(ok_json, "\"line_count\":2"), "line count")

	// Failure shape carries error_code + message, no output.
	fail_json := bridge_pane_capture_result_json(pending, false, "host_unavailable", "The ham-pty-host daemon is not available.", "", 0, false)
	defer delete(fail_json)
	testing.expect(t, strings.contains(fail_json, "\"ok\":false"), "ok false")
	testing.expect(t, strings.contains(fail_json, "\"error_code\":\"host_unavailable\""), "error code")
	testing.expect(t, !strings.contains(fail_json, "\"output\":"), "no output on failure")
}

@(test)
pty_host_pane_hash_sha256_computes_expected :: proc(t: ^testing.T) {
	// Empty string sha256
	h_empty := bridge_pty_host_pane_hash("")
	defer delete(h_empty)
	testing.expect_value(t, h_empty, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

	// Non-empty string
	h_text := bridge_pty_host_pane_hash("hello\nworld")
	defer delete(h_text)
	testing.expect_value(t, len(h_text), 64)
	h_repeat := bridge_pty_host_pane_hash("hello\nworld")
	defer delete(h_repeat)
	testing.expect_value(t, h_text, h_repeat)
}

@(test)
pty_host_evaluate_pane_unchanged_when_since_hash_matches :: proc(t: ^testing.T) {
	lines := []string{"foo", "bar"}
	expected_hash := bridge_pty_host_pane_hash("foo\nbar")
	defer delete(expected_hash)

	unchanged, hash_val, output, line_count, truncated := bridge_pty_host_evaluate_pane(lines, 120, expected_hash)
	defer delete(hash_val)
	testing.expect_value(t, unchanged, true)
	testing.expect_value(t, hash_val, expected_hash)
	testing.expect_value(t, output, "")
	testing.expect_value(t, line_count, 0)
	testing.expect_value(t, truncated, false)
}

@(test)
pty_host_evaluate_pane_changed_when_since_hash_differs :: proc(t: ^testing.T) {
	lines := []string{"foo", "bar"}
	unchanged, hash_val, output, line_count, truncated := bridge_pty_host_evaluate_pane(lines, 120, "old_stale_hash")
	defer delete(hash_val)
	defer delete(output)

	testing.expect_value(t, unchanged, false)
	testing.expect_value(t, output, "foo\nbar")
	testing.expect_value(t, line_count, 2)
	testing.expect_value(t, truncated, false)
	testing.expect(t, hash_val != "old_stale_hash", "hash should be updated")
}

@(test)
pty_host_evaluate_pane_changed_when_since_hash_empty :: proc(t: ^testing.T) {
	lines := []string{"row1", "row2", "row3"}
	unchanged, hash_val, output, line_count, truncated := bridge_pty_host_evaluate_pane(lines, 2, "")
	defer delete(hash_val)
	defer delete(output)

	testing.expect_value(t, unchanged, false)
	testing.expect_value(t, output, "row2\nrow3")
	testing.expect_value(t, line_count, 2)
	testing.expect_value(t, truncated, true)
	testing.expect_value(t, len(hash_val), 64)
}

@(test)
pty_host_get_pane_result_json_unchanged_shape :: proc(t: ^testing.T) {
	json := bridge_get_agent_pane_result_json("cmd_test_1", true, true, "hash_match_123", "", 0, false, 0, 0, "")
	defer delete(json)

	testing.expect(t, strings.contains(json, "\"type\":\"command_result\""), "type command_result")
	testing.expect(t, strings.contains(json, "\"command_id\":\"cmd_test_1\""), "command_id present")
	testing.expect(t, strings.contains(json, "\"ok\":true"), "ok true")
	testing.expect(t, strings.contains(json, "\"unchanged\":true"), "unchanged true")
	testing.expect(t, strings.contains(json, "\"hash\":\"hash_match_123\""), "hash present")
	testing.expect(t, !strings.contains(json, "\"output\""), "output must be omitted when unchanged")
	testing.expect(t, !strings.contains(json, "\"line_count\""), "line_count omitted when unchanged")
}

@(test)
pty_host_get_pane_result_json_changed_shape :: proc(t: ^testing.T) {
	json := bridge_get_agent_pane_result_json("cmd_test_2", true, false, "hash_new_456", "lineA\nlineB", 2, true, 1, 5, "")
	defer delete(json)

	testing.expect(t, strings.contains(json, "\"type\":\"command_result\""), "type command_result")
	testing.expect(t, strings.contains(json, "\"command_id\":\"cmd_test_2\""), "command_id present")
	testing.expect(t, strings.contains(json, "\"ok\":true"), "ok true")
	testing.expect(t, strings.contains(json, "\"unchanged\":false"), "unchanged false")
	testing.expect(t, strings.contains(json, "\"hash\":\"hash_new_456\""), "hash present")
	testing.expect(t, strings.contains(json, "\"output\":\"lineA\\nlineB\""), "output escaped and present")
	testing.expect(t, strings.contains(json, "\"line_count\":2"), "line_count present")
	testing.expect(t, strings.contains(json, "\"truncated\":true"), "truncated true")
	testing.expect(t, strings.contains(json, "\"cursor_row\":1"), "cursor_row present")
	testing.expect(t, strings.contains(json, "\"cursor_col\":5"), "cursor_col present")
}

@(test)
pty_host_get_pane_result_json_failure_shape :: proc(t: ^testing.T) {
	json := bridge_get_agent_pane_result_json("cmd_test_3", false, false, "", "", 0, false, 0, 0, "daemon connection failed")
	defer delete(json)

	testing.expect(t, strings.contains(json, "\"type\":\"command_result\""), "type command_result")
	testing.expect(t, strings.contains(json, "\"command_id\":\"cmd_test_3\""), "command_id present")
	testing.expect(t, strings.contains(json, "\"ok\":false"), "ok false")
	testing.expect(t, strings.contains(json, "\"unchanged\":false"), "unchanged false")
	testing.expect(t, strings.contains(json, "\"error\":\"daemon connection failed\""), "error message present")
	testing.expect(t, !strings.contains(json, "\"output\""), "no output on failure")
}

@(test)
pty_host_get_pane_missing_agent_instance_id :: proc(t: ^testing.T) {
	ok, unchanged, h, output, line_count, truncated, cursor_row, cursor_col, err_msg := bridge_pty_host_get_pane("", "", 120, 80)
	testing.expect_value(t, ok, false)
	testing.expect_value(t, unchanged, false)
	testing.expect_value(t, h, "")
	testing.expect_value(t, output, "")
	testing.expect_value(t, line_count, 0)
	testing.expect_value(t, truncated, false)
	testing.expect_value(t, cursor_row, 0)
	testing.expect_value(t, cursor_col, 0)
	testing.expect_value(t, err_msg, "missing agent_instance_id")
}

@(test)
pty_host_stream_screen_payload_trim_variations :: proc(t: ^testing.T) {
	all_empty := []string{"", "", "", ""}
	got1 := bridge_pty_stream_screen_payload(all_empty, -1, -1)
	defer delete(got1)
	testing.expect_value(t, got1, "")

	whitespace_only := []string{"   ", "\t\t", " \t \t", ""}
	got2 := bridge_pty_stream_screen_payload(whitespace_only, -1, -1)
	defer delete(got2)
	testing.expect_value(t, got2, "")

	lines := make([dynamic]string, context.temp_allocator)
	append(&lines, "admin@box:~#   ")
	for _ in 0 ..< 100 {
		append(&lines, "")
	}
	got3 := bridge_pty_stream_screen_payload(lines[:], -1, -1)
	defer delete(got3)
	testing.expect_value(t, got3, "admin@box:~#   ")
	testing.expect(t, strings.has_suffix(got3, "   "), "trailing spaces preserved")

	lines4 := []string{"First", "", "Second", "   ", "Third", "", ""}
	got4 := bridge_pty_stream_screen_payload(lines4, -1, -1)
	defer delete(got4)
	testing.expect_value(t, got4, "First\r\n\r\nSecond\r\n   \r\nThird")

	lines5 := []string{"already\r", "carriage\r"}
	got5 := bridge_pty_stream_screen_payload(lines5, -1, -1)
	defer delete(got5)
	testing.expect(t, !strings.contains(got5, "\r\r"), "no doubled CR")
}

@(test)
pty_host_get_pane_result_json_coordinate_extremes :: proc(t: ^testing.T) {
	json1 := bridge_get_agent_pane_result_json("cmd_large", true, false, "h1", "out", 1, false, 65535, 65535)
	defer delete(json1)
	testing.expect(t, strings.contains(json1, "\"cursor_row\":65535"), "large cursor_row formatted")
	testing.expect(t, strings.contains(json1, "\"cursor_col\":65535"), "large cursor_col formatted")

	json2 := bridge_get_agent_pane_result_json("cmd_origin", true, false, "h2", "out", 1, false, 0, 0)
	defer delete(json2)
	testing.expect(t, strings.contains(json2, "\"cursor_row\":0"), "cursor_row 0")
	testing.expect(t, strings.contains(json2, "\"cursor_col\":0"), "cursor_col 0")

	json3 := bridge_get_agent_pane_result_json("cmd_unchanged", true, true, "h3", "", 0, false, 5, 10)
	defer delete(json3)
	testing.expect(t, strings.contains(json3, "\"unchanged\":true"), "unchanged true")
	testing.expect(t, !strings.contains(json3, "cursor_row"), "cursor_row omitted when unchanged")
	testing.expect(t, !strings.contains(json3, "cursor_col"), "cursor_col omitted when unchanged")
	testing.expect(t, !strings.contains(json3, "output"), "output omitted when unchanged")

	json4 := bridge_get_agent_pane_result_json("cmd_fail", false, false, "", "", 0, false, 5, 10, "error detail")
	defer delete(json4)
	testing.expect(t, strings.contains(json4, "\"ok\":false"), "ok false")
	testing.expect(t, !strings.contains(json4, "cursor_row"), "cursor_row omitted on failure")
	testing.expect(t, !strings.contains(json4, "cursor_col"), "cursor_col omitted on failure")
}
