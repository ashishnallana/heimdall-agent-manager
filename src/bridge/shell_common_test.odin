package main

// Unit tests for the shared shell output helpers in shell_common.odin.
//
// This file was src/bridge/shell_cmd_test.odin. REQ-SHELL-7 deleted the bridge-local
// exec/read RPC surface it also covered — the routing/allowlist assertions for those
// two methods, and their exec+read end-to-end cases — because the methods no longer
// exist. What is KEPT is everything covering bridge_shell_tail and bridge_shell_page,
// which survive as the truncation and paging behind `ham-ctl shell log` and a finished
// run's inline result.

import "core:strings"
import "core:testing"

// ---- pure helpers: tail truncation ---------------------------------------

@(test)
bridge_shell_tail_no_truncation_under_threshold :: proc(t: ^testing.T) {
	out := "a\nb\nc\n"
	tail, truncated := bridge_shell_tail(out, 200, 100)
	testing.expect(t, !truncated, "under threshold must not truncate")
	testing.expect(t, tail == out, "under threshold returns output unchanged")
}

@(test)
bridge_shell_tail_at_threshold_not_truncated :: proc(t: ^testing.T) {
	// exactly `threshold` lines -> not truncated (only > threshold truncates).
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 0 ..< 5 {
		strings.write_string(&b, "line\n")
	}
	out := strings.to_string(b)
	tail, truncated := bridge_shell_tail(out, 5, 2)
	testing.expect(t, !truncated, "exactly threshold lines must not truncate")
	testing.expect(t, tail == out, "output unchanged at threshold")
}

@(test)
bridge_shell_tail_keeps_last_lines :: proc(t: ^testing.T) {
	out := "a\nb\nc\nd\ne\n"
	tail, truncated := bridge_shell_tail(out, 3, 2)
	testing.expect(t, truncated, "over threshold must truncate")
	testing.expect(t, tail == "d\ne\n", "must keep exactly the last 2 lines")
}

@(test)
bridge_shell_tail_keeps_last_lines_no_trailing_newline :: proc(t: ^testing.T) {
	out := "a\nb\nc\nd\ne"
	tail, truncated := bridge_shell_tail(out, 3, 2)
	testing.expect(t, truncated, "over threshold must truncate")
	testing.expect(t, tail == "d\ne", "must keep last 2 lines when no trailing newline")
}

@(test)
bridge_shell_tail_empty :: proc(t: ^testing.T) {
	tail, truncated := bridge_shell_tail("", 200, 100)
	testing.expect(t, !truncated, "empty output not truncated")
	testing.expect(t, tail == "", "empty output unchanged")
}

// ---- pure helpers: paging (REQ-25) ---------------------------------------

@(test)
bridge_shell_page_offset_skips_from_start :: proc(t: ^testing.T) {
	out := "a\nb\nc\nd\ne\n"
	page, truncated := bridge_shell_page(out, 2, 100, "")
	defer delete(page)
	testing.expect(t, page == "c\nd\ne\n", "offset 2 keeps lines 3..5")
	testing.expect(t, truncated, "offset > 0 marks truncated")
}

@(test)
bridge_shell_page_limit_caps_lines :: proc(t: ^testing.T) {
	out := "a\nb\nc\nd\ne\n"
	page, truncated := bridge_shell_page(out, 0, 2, "")
	defer delete(page)
	testing.expect(t, page == "a\nb\n", "limit 2 keeps the first 2 lines from offset 0")
	testing.expect(t, truncated, "more lines remain -> truncated")
}

@(test)
bridge_shell_page_limit_within_bounds_not_truncated :: proc(t: ^testing.T) {
	out := "a\nb\nc\n"
	page, truncated := bridge_shell_page(out, 0, 10, "")
	defer delete(page)
	testing.expect(t, page == "a\nb\nc\n", "limit above line count returns all")
	testing.expect(t, !truncated, "nothing skipped or dropped -> not truncated")
}

@(test)
bridge_shell_page_grep_filters_with_line_numbers :: proc(t: ^testing.T) {
	out := "alpha\nerror one\nbeta\nerror two\ngamma\n"
	page, truncated := bridge_shell_page(out, 0, 100, "error")
	defer delete(page)
	testing.expect(t, page == "2:error one\n4:error two\n", "grep keeps matches with original 1-based line numbers")
	testing.expect(t, !truncated, "all matches returned -> not truncated")
}

@(test)
bridge_shell_page_grep_with_offset_and_limit :: proc(t: ^testing.T) {
	out := "e1\nx\ne2\ne3\ny\ne4\n"
	// matches are lines 1,3,4,6 -> skip 1 match, keep 2.
	page, truncated := bridge_shell_page(out, 1, 2, "e")
	defer delete(page)
	testing.expect(t, page == "3:e2\n4:e3\n", "offset+limit page the grep matches")
	testing.expect(t, truncated, "offset skipped a match -> truncated")
}

@(test)
bridge_shell_page_no_trailing_newline :: proc(t: ^testing.T) {
	out := "a\nb\nc"
	page, truncated := bridge_shell_page(out, 0, 10, "")
	defer delete(page)
	testing.expect(t, page == "a\nb\nc\n", "final line without newline is still emitted")
	testing.expect(t, !truncated, "all lines returned -> not truncated")
}

@(test)
bridge_shell_page_empty_output :: proc(t: ^testing.T) {
	page, truncated := bridge_shell_page("", 0, 100, "")
	defer delete(page)
	testing.expect(t, page == "", "empty output pages to empty")
	testing.expect(t, !truncated, "empty output not truncated")
}

// ---- REQ-SHELL-27: pure output sanitisation ------------------------------

Sanitize_Case :: struct {
	name: string,
	raw:  string,
	want: string,
}

@(test)
bridge_shell_sanitize_output_table :: proc(t: ^testing.T) {
	cases := []Sanitize_Case{
		// --- the thing that motivated the task: colour ---
		{
			name = "sgr colour around a word",
			raw  = "\x1b[0;31merror\x1b[0m: boom\n",
			want = "error: boom\n",
		},
		{
			name = "sgr with no parameters (bare reset)",
			raw  = "a\x1b[mb\n",
			want = "ab\n",
		},
		// --- cursor movement / erase ---
		{
			name = "cursor moves and erase-line",
			raw  = "\x1b[2K\x1b[1Gbuilding\x1b[Hdone\n",
			want = "buildingdone\n",
		},
		// --- OSC title writes ---
		{
			name = "osc title terminated by BEL",
			raw  = "\x1b]0;my title\x07hello\n",
			want = "hello\n",
		},
		{
			name = "osc title terminated by ST (ESC backslash)",
			raw  = "\x1b]2;title\x1b\\hello\n",
			want = "hello\n",
		},
		// --- stray / malformed escapes must not leak a control byte ---
		{
			name = "lone trailing ESC is dropped",
			raw  = "tail\x1b",
			want = "tail",
		},
		{
			name = "two-byte escape (charset select) is dropped",
			raw  = "a\x1b(Bb\n",
			want = "ab\n",
		},
		{
			name = "unterminated CSI at end of text emits nothing",
			raw  = "line\n\x1b[0;32",
			want = "line\n",
		},
		{
			name = "unterminated OSC at end of text emits nothing",
			raw  = "line\n\x1b]0;half a title",
			want = "line\n",
		},
		// --- THE REGRESSION GUARD: brackets that are NOT escapes must survive ---
		{
			name = "plain brackets are ordinary text",
			raw  = "[INFO] arr[0] = {\"k\":[1,2]} // ] and [\n",
			want = "[INFO] arr[0] = {\"k\":[1,2]} // ] and [\n",
		},
		{
			name = "bracket immediately after a stripped sequence still survives",
			raw  = "\x1b[32m[OK]\x1b[0m\n",
			want = "[OK]\n",
		},
		// --- CR handling ---
		{
			name = "crlf becomes lf",
			raw  = "a\r\nb\r\n",
			want = "a\nb\n",
		},
		{
			name = "bare cr progress collapses to the final state",
			raw  = "12%\r45%\r100%\n",
			want = "100%\n",
		},
		{
			name = "bare cr does not eat the PREVIOUS line",
			raw  = "kept\n12%\rdone\n",
			want = "kept\ndone\n",
		},
		{
			name = "bare cr shorter redraw does not leave a tail of the longer one",
			raw  = "Downloading 99%\rDone\n",
			want = "Done\n",
		},
		{
			name = "trailing bare cr leaves the line empty, not the stale text",
			raw  = "a\nstale\r",
			want = "a\n",
		},
		{
			name = "cr after crlf starts from the new line",
			raw  = "one\r\ntwo\rthree\n",
			want = "one\nthree\n",
		},
		// --- combinations + the no-op case ---
		{
			name = "colour and cr in the same progress line",
			raw  = "\x1b[33m 50%\x1b[0m\r\x1b[32m100%\x1b[0m\r\n",
			want = "100%\n",
		},
		{
			name = "clean text is returned unchanged",
			raw  = "nothing to strip here\n",
			want = "nothing to strip here\n",
		},
		{
			name = "empty input",
			raw  = "",
			want = "",
		},
	}

	for c in cases {
		got := bridge_shell_sanitize_output(c.raw)
		defer delete(got)
		testing.expectf(t, got == c.want, "%s: got %q, want %q", c.name, got, c.want)
	}
}

@(test)
bridge_shell_sanitize_output_escape_split_across_boundary :: proc(t: ^testing.T) {
	head := bridge_shell_sanitize_output("green: \x1b[0;3")
	defer delete(head)
	testing.expectf(t, head == "green: ", "leading half must drop the fragment, got %q", head)

	tail := bridge_shell_sanitize_output("2mok\x1b[0m\n")
	defer delete(tail)
	testing.expectf(t, tail == "2mok\n", "trailing half keeps its text, got %q", tail)

	whole := bridge_shell_sanitize_output("green: \x1b[0;32mok\x1b[0m\n")
	defer delete(whole)
	testing.expectf(t, whole == "green: ok\n", "unsplit input must be clean, got %q", whole)
}

@(test)
bridge_shell_sanitize_output_leaves_no_control_bytes :: proc(t: ^testing.T) {
	raw := "\x1b[31ma\x1b]0;t\x07b\x1b(Bc\x1b[0m\r\nd\x1b"
	got := bridge_shell_sanitize_output(raw)
	defer delete(got)
	testing.expectf(t, got == "abc\nd", "got %q", got)
	for i in 0 ..< len(got) {
		testing.expectf(t, got[i] != 0x1b && got[i] != '\r' && got[i] != 0x07,
			"byte %d (0x%x) is a control byte that must not reach the JSON string", i, got[i])
	}
}

@(test)
bridge_shell_grep_matches_colour_wrapped_text :: proc(t: ^testing.T) {
	raw := "\x1b[32mcompiling foo\x1b[0m\r\n\x1b[0;31merror\x1b[0m: missing semicolon\r\n\x1b[32mcompiling bar\x1b[0m\r\n"

	raw_hit, _ := bridge_shell_page(raw, 0, 0, "error: missing")
	defer delete(raw_hit)
	testing.expect(t, raw_hit == "",
		"precondition: grep on RAW output must miss the colour-wrapped match (if this fails the bug is gone by other means and this test is no longer meaningful)")

	clean := bridge_shell_sanitize_output(raw)
	defer delete(clean)
	hit, truncated := bridge_shell_page(clean, 0, 0, "error: missing")
	defer delete(hit)
	testing.expectf(t, hit == "2:error: missing semicolon\n",
		"grep must match the colour-wrapped line and report its 1-based line number, got %q", hit)
	testing.expect(t, !truncated, "a single full match is not truncated")
}

@(test)
bridge_shell_grep_line_numbers_count_visible_lines :: proc(t: ^testing.T) {
	raw := "a\r\nb\r\n1%\rdone\r\nc\r\n"
	clean := bridge_shell_sanitize_output(raw)
	defer delete(clean)
	hit, _ := bridge_shell_page(clean, 0, 0, "done")
	defer delete(hit)
	testing.expectf(t, hit == "3:done\n", "expected the redrawn line to be line 3, got %q", hit)
}

@(test)
bridge_shell_paging_applies_to_stripped_lines :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 0 ..< 5 {
		strings.write_string(&b, "\x1b]0;build\x07\x1b[36m")
		strings.write_string(&b, "wait\rline")
		strings.write_int(&b, i)
		strings.write_string(&b, "\x1b[0m\r\n")
	}
	raw := strings.to_string(b)

	clean := bridge_shell_sanitize_output(raw)
	defer delete(clean)
	testing.expectf(t, clean == "line0\nline1\nline2\nline3\nline4\n", "sanitised form, got %q", clean)

	page, truncated := bridge_shell_page(clean, 1, 2, "")
	defer delete(page)
	testing.expectf(t, page == "line1\nline2\n", "offset=1 limit=2 over stripped lines, got %q", page)
	testing.expect(t, truncated, "lines were skipped by the offset and remain beyond the limit")

	total := 0
	for i in 0 ..< len(clean) { if clean[i] == '\n' do total += 1 }
	testing.expectf(t, total == 5, "total_lines over stripped text must be 5, got %d", total)

	last, _ := bridge_shell_page(clean, 4, 1, "")
	defer delete(last)
	testing.expectf(t, last == "line4\n", "last page, got %q", last)
}

@(test)
bridge_shell_tail_over_sanitized_counts_visible_lines :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 0 ..< 5 {
		strings.write_string(&b, "\x1b[36mline")
		strings.write_int(&b, i)
		strings.write_string(&b, "\x1b[0m\r\n")
	}
	raw := strings.to_string(b)

	clean := bridge_shell_sanitize_output(raw)
	defer delete(clean)

	testing.expectf(t, len(clean) == len("line0\nline1\nline2\nline3\nline4\n"),
		"output_size must describe the delivered text, got %d", len(clean))
	testing.expect(t, len(clean) < len(raw), "stripping shrinks it; the raw file is larger and unchanged")

	whole, trunc_none := bridge_shell_tail(clean, 5, 2)
	testing.expect(t, !trunc_none, "5 visible lines at a threshold of 5 must not truncate")
	testing.expect(t, whole == clean, "untruncated tail returns the sanitised text unchanged")

	tail, truncated := bridge_shell_tail(clean, 4, 2)
	testing.expect(t, truncated, "5 visible lines over a threshold of 4 must truncate")
	testing.expectf(t, tail == "line3\nline4\n", "tail must be the last 2 VISIBLE lines, got %q", tail)

	for i in 0 ..< len(tail) {
		testing.expectf(t, tail[i] != 0x1b, "tail byte %d is a raw ESC", i)
	}
}

@(test)
bridge_shell_tail_over_sanitized_collapses_progress_redraws :: proc(t: ^testing.T) {
	clean := bridge_shell_sanitize_output("a\r\n1%\r50%\r100%\r\nb\r\n")
	defer delete(clean)
	testing.expectf(t, clean == "a\n100%\nb\n", "got %q", clean)

	tail, truncated := bridge_shell_tail(clean, 2, 1)
	testing.expect(t, truncated, "3 visible lines over a threshold of 2 truncates")
	testing.expectf(t, tail == "b\n", "got %q", tail)
}
