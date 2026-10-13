package shell_session

import "core:strings"
import "core:testing"

// --- _json_array_raw tests (REQ-JSON-1..5) ---

@(test)
test_json_array_raw_lone_close_bracket_in_line_preserves_span :: proc(t: ^testing.T) {
	body := `{"ok":true,"lines":["a ] b","plain","tail"],"truncated":false,"total_lines":3}`
	got := _json_array_raw(body, "lines")
	defer delete(got)
	testing.expect_value(t, got, `["a ] b","plain","tail"]`)
}

@(test)
test_json_array_raw_lone_open_bracket_in_line_preserves_span :: proc(t: ^testing.T) {
	body := `{"ok":true,"lines":["c [ d","tail"],"truncated":false,"total_lines":2}`
	got := _json_array_raw(body, "lines")
	defer delete(got)
	testing.expect_value(t, got, `["c [ d","tail"]`)
}

@(test)
test_json_array_raw_escaped_quote_does_not_end_string :: proc(t: ^testing.T) {
	body := `{"ok":true,"lines":["say \"hi\" ] then [ bye","tail"],"truncated":false}`
	got := _json_array_raw(body, "lines")
	defer delete(got)
	testing.expect_value(t, got, `["say \"hi\" ] then [ bye","tail"]`)
}

@(test)
test_json_array_raw_lines_decoy_before_real_key_is_ignored :: proc(t: ^testing.T) {
	body := `{"ok":true,"cmd":"echo \"lines\":[999] > f","lines":["real","tail"],"truncated":false}`
	got := _json_array_raw(body, "lines")
	defer delete(got)
	testing.expect_value(t, got, `["real","tail"]`)
}

@(test)
test_json_array_raw_escaped_lines_decoy_inside_value_is_ignored :: proc(t: ^testing.T) {
	body := `{"ok":true,"lines":["not a \"lines\": decoy","tail"],"truncated":false}`
	got := _json_array_raw(body, "lines")
	defer delete(got)
	testing.expect_value(t, got, `["not a \"lines\": decoy","tail"]`)
}

@(test)
test_json_array_raw_fallbacks_return_empty_array :: proc(t: ^testing.T) {
	absent := _json_array_raw(`{"ok":true,"truncated":false,"total_lines":0}`, "lines")
	defer delete(absent)
	testing.expect_value(t, absent, "[]")

	not_an_array := _json_array_raw(`{"ok":true,"lines":"nope","truncated":false}`, "lines")
	defer delete(not_an_array)
	testing.expect_value(t, not_an_array, "[]")

	unterminated := _json_array_raw(`{"ok":true,"lines":["a","b"`, "lines")
	defer delete(unterminated)
	testing.expect_value(t, unterminated, "[]")
}

// --- _json_str unicode and escape tests (REQ-SHELL-60) ---

@(test)
test_json_str_decodes_unicode_escape_to_one_esc_byte :: proc(t: ^testing.T) {
	got := _json_str(`{"content":"\u001b"}`, "content")
	defer delete(got)

	testing.expectf(t, len(got) == 1, "expected exactly 1 byte, got %d (%q)", len(got), got)
	testing.expectf(
		t,
		len(got) == 1 && got[0] == 0x1b,
		"expected the single byte 0x1b, got %q",
		got,
	)
	testing.expectf(t, got != "u001b", "got the pre-fix literal text `u001b` back: %q", got)
}

@(test)
test_json_str_decodes_full_colour_sequence :: proc(t: ^testing.T) {
	got := _json_str(`{"content":"\u001b[31mREDTEXT\u001b[0m\r\n"}`, "content")
	defer delete(got)

	testing.expectf(
		t,
		got == "\x1b[31mREDTEXT\x1b[0m\r\n",
		"decoded payload is wrong: %q",
		got,
	)
	testing.expectf(
		t,
		strings.count(got, "u001b") == 0,
		"found literal `u001b` in the decoded payload: %q",
		got,
	)
	testing.expectf(
		t,
		strings.count(got, "\x1b") == 2,
		"expected 2 real ESC bytes, got %d: %q",
		strings.count(got, "\x1b"),
		got,
	)
}

@(test)
test_json_str_decodes_escapes_in_error_string :: proc(t: ^testing.T) {
	got := _json_str(`{"ok":false,"error":"spawn failed: \u001b[1mbad\u001b[0m"}`, "error")
	defer delete(got)

	testing.expectf(
		t,
		got == "spawn failed: \x1b[1mbad\x1b[0m",
		"decoded error string is wrong: %q",
		got,
	)
}

@(test)
test_json_str_decodes_non_ascii_escape_as_rune :: proc(t: ^testing.T) {
	got := _json_str(`{"content":"caf\u00e9"}`, "content")
	defer delete(got)

	testing.expectf(t, got == "café", "expected `café`, got %q", got)
}

@(test)
test_json_str_still_decodes_simple_escapes :: proc(t: ^testing.T) {
	got := _json_str(`{"content":"a\nb\tc\"d\\e\rf"}`, "content")
	defer delete(got)

	testing.expectf(t, got == "a\nb\tc\"d\\e\rf", "simple escapes regressed: %q", got)
}

@(test)
test_json_str_falls_back_on_malformed_unicode_escape :: proc(t: ^testing.T) {
	// 'zz' are not hex digits, so jsonx.json_unescape_string falls back to literal 'u' and continues.
	bad_hex := _json_str(`{"content":"\u00zzTAIL"}`, "content")
	defer delete(bad_hex)
	testing.expectf(t, bad_hex == "u00zzTAIL", "bad-hex fallback is wrong: %q", bad_hex)

	// A short escape falls back through jsonx.json_unescape_string by writing literal 'u' and continuing.
	truncated := _json_str(`{"content":"\u01"}`, "content")
	defer delete(truncated)
	testing.expectf(t, truncated == "u01", "truncated fallback is wrong: %q", truncated)
}
