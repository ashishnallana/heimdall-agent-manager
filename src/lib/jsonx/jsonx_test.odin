package jsonx

import "core:strings"
import "core:testing"

@(test)
test_jsonx_escapes :: proc(t: ^testing.T) {
	json_str := `{"text":"hello \"world\" \\ \n \r \t \u0041 \ud83d\ude00"}`
	got := extract_string(json_str, "text")
	defer delete(got)
	expected := "hello \"world\" \\ \n \r \t A \U0001F600"
	testing.expect(t, got == expected, "standard and unicode escapes should match")
}

@(test)
test_jsonx_key_spoofing_immunity :: proc(t: ^testing.T) {
	// Key spoofing attempt: fake keys embedded inside string values
	json_str1 := `{"error":"fake \"kind\":\"validate_project_path_result\"","kind":"real"}`
	got1 := extract_string(json_str1, "kind")
	defer delete(got1)
	testing.expect_value(t, got1, "real")

	json_str2 := `{"data":"\"command_id\":\"spoofed\"","command_id":"real_id"}`
	got2 := extract_string(json_str2, "command_id")
	defer delete(got2)
	testing.expect_value(t, got2, "real_id")
}

@(test)
test_jsonx_top_level_precedence :: proc(t: ^testing.T) {
	json_str := `{"target":"top","payload":{"target":"nested"}}`
	got := extract_string(json_str, "target")
	defer delete(got)
	testing.expect_value(t, got, "top")
}

@(test)
test_jsonx_nested_envelope_lookup :: proc(t: ^testing.T) {
	json_str := `{"v":1,"ok":true,"payload":{"task_id":"task_123","count":42,"active":true}}`
	task_id := extract_string(json_str, "task_id")
	defer delete(task_id)
	testing.expect_value(t, task_id, "task_123")

	count := extract_int(json_str, "count")
	testing.expect_value(t, count, 42)

	active := extract_bool(json_str, "active")
	testing.expect_value(t, active, true)
}

@(test)
test_jsonx_top_level_only_mode :: proc(t: ^testing.T) {
	json_str := `{"payload":{"task_id":"task_123"}}`
	got_nested := extract_string(json_str, "task_id", fallback = "", top_level_only = false)
	defer delete(got_nested)
	testing.expect_value(t, got_nested, "task_123")

	got_top_only := extract_string(json_str, "task_id", fallback = "", top_level_only = true)
	defer delete(got_top_only)
	testing.expect_value(t, got_top_only, "")
}

@(test)
test_jsonx_malformed_json_fallback :: proc(t: ^testing.T) {
	bad_json := `{"unclosed":"string`
	got := extract_string(bad_json, "unclosed", fallback = "default")
	defer delete(got)
	testing.expect_value(t, got, "default")

	got_int := extract_int(bad_json, "key", fallback = -99)
	testing.expect_value(t, got_int, -99)

	got_bool := extract_bool(bad_json, "key", fallback = true)
	testing.expect_value(t, got_bool, true)
}

@(test)
test_jsonx_has_key :: proc(t: ^testing.T) {
	json_str := `{"present":null,"missing_not":1}`
	testing.expect(t, has_key(json_str, "present"), "null key should exist")
	testing.expect(t, has_key(json_str, "missing_not"), "key should exist")
	testing.expect(t, !has_key(json_str, "absent"), "absent key should return false")
}

@(test)
test_jsonx_string_arrays :: proc(t: ^testing.T) {
	json_str := `{"items":["one","two","three"]}`
	arr := extract_string_array(json_str, "items")
	defer {
		for s in arr do delete(s)
		delete(arr)
	}
	testing.expect_value(t, len(arr), 3)
	testing.expect_value(t, arr[0], "one")
	testing.expect_value(t, arr[1], "two")
	testing.expect_value(t, arr[2], "three")

	flat := `["alpha","beta"]`
	decoded := decode_string_array(flat)
	defer {
		for s in decoded do delete(s)
		delete(decoded)
	}
	testing.expect_value(t, len(decoded), 2)
	testing.expect_value(t, decoded[0], "alpha")
	testing.expect_value(t, decoded[1], "beta")
}

@(test)
test_jsonx_raw_object_and_array :: proc(t: ^testing.T) {
	json_str := `{"meta":{"configured":true},"tags":["a","b"]}`
	raw_obj, ok_obj := extract_raw_object(json_str, "meta")
	defer if ok_obj do delete(raw_obj)
	testing.expect(t, ok_obj, "extract_raw_object should succeed")
	testing.expect(t, strings.contains(raw_obj, `"configured":true`), "raw_obj should contain configured field")

	raw_arr, ok_arr := extract_raw_array(json_str, "tags")
	defer if ok_arr do delete(raw_arr)
	testing.expect(t, ok_arr, "extract_raw_array should succeed")
	testing.expect(t, strings.contains(raw_arr, `"a"`), "raw_arr should contain items")
}

@(test)
test_jsonx_complex_array_with_nested_objects :: proc(t: ^testing.T) {
	complex_json := `{"default_provider":"claude","providers":[{"name":"claude","enabled":true,"command":["/bin/cli"],"models":{"flag":"--model","smart":"argon-sum"},"activity_detection":{"enabled":true,"sample_line_count":20}},{"name":"codex","command":["/usr/bin/codex"]}]}`
	raw_arr, ok_arr := extract_raw_array(complex_json, "providers")
	defer if ok_arr do delete(raw_arr)
	testing.expect(t, ok_arr, "extract_raw_array on complex providers should succeed")
	testing.expect(t, strings.contains(raw_arr, `"name":"claude"`), "should contain claude")
	testing.expect(t, strings.contains(raw_arr, `"name":"codex"`), "should contain codex")
}

@(test)
test_jsonx_unescape_string :: proc(t: ^testing.T) {
	unescaped, ok := unescape_string(`"test \"value\" \n"`)
	defer if ok do delete(unescaped)
	testing.expect(t, ok, "unescape_string should succeed")
	testing.expect_value(t, unescaped, "test \"value\" \n")
}

@(test)
test_jsonx_json_unescape_string_binary_and_surrogates :: proc(t: ^testing.T) {
	// Test surrogate pair \ud83d\ude00
	surrogate := json_unescape_string(`\ud83d\ude00`)
	defer delete(surrogate)
	testing.expect_value(t, surrogate, "\U0001F600")

	// Test malformed unicode escapes left alone
	bad_hex := json_unescape_string(`\u00zzTAIL`)
	defer delete(bad_hex)
	testing.expect_value(t, bad_hex, "u00zzTAIL")

	// Test raw binary byte >= 0x80 preservation
	raw_bytes := [?]byte{0x89, 'P', 'N', 'G'}
	raw_byte_str := string(raw_bytes[:])
	decoded := json_unescape_string(raw_byte_str)
	defer delete(decoded)
	testing.expect_value(t, decoded, raw_byte_str)
}


// ---------------------------------------------------------------------------
// F1 / REQ-JSONX-1..2: invalid UTF-8 in a response string must not panic.
//
// core:encoding/json's `unquote_string` sizes its output buffer from the
// ESCAPED token: `len(s) + 2*utf8.UTF_MAX`, i.e. len+8 of slack. Its pre-scan
// loop bails out the moment it meets invalid UTF-8, forcing the slow decode
// path, which re-encodes every invalid byte as U+FFFD: `decode_rune_in_string`
// returns (RUNE_ERROR, width=1) so 1 input byte is consumed, while
// `encode_rune(RUNE_ERROR)` emits 3. The guarding `assert(buf_width <= width)`
// is deliberately skipped for RUNE_ERROR, so each invalid byte nets +2 output
// bytes. The overflow condition is therefore
//
//     decoded_len + 2*invalid_bytes  >  len(escaped_token) + 8
//
// NOT simply "five invalid bytes". Five is the boundary only when nothing in
// the token is escaped, because escapes BUY slack: the Hub emits control bytes
// as `\u00XX`, six source characters that decode to one, so every control byte
// in the payload offsets five bytes of U+FFFD expansion. That is exactly why
// the defect looked content-dependent rather than size-dependent -- a 188K PNG
// survived while a 68.7K PNG died.
//
// Measured on the two artifacts from the user report, against the shipped
// toolchain (odin dev-2026-07a, share/core/encoding/json/parser.odin):
//
//   68.7K png : escaped 111820 -> buffer 111828, output 125937  = +14109 OVERFLOW
//   1.89M jpeg: escaped 3078215 -> buffer 3078223, output 3511710 = +433487 OVERFLOW
//
// and those buffer sizes are verbatim the bounds in the user's panics
// ("0..<111828" at :507 and "Index 3078223" at :494).
//
// The three PNGs that did NOT panic were not unaffected: they came back with
// 38728 / 52960 / 66906 U+FFFD substitutions and were no longer valid PNGs at
// all. Surviving the buffer and decoding correctly are different things, which
// is why these tests assert on the BYTES, not just on the absence of a crash.
//
// This reaches every ham-ctl response, because extract_string_found calls
// json.parse_string on all of them -- binary artifact content is merely the
// easiest way to get five bad bytes into a string.

// invalid_utf8_run builds `n` bytes that can never begin a valid UTF-8
// sequence. 0xFF is a continuation-less lead byte, so decode_rune_in_string
// returns (RUNE_ERROR, 1) for each one individually.
invalid_utf8_run :: proc(n: int, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for _ in 0 ..< n do strings.write_byte(&b, 0xFF)
	return strings.to_string(b)
}

@(test)
test_jsonx_four_invalid_utf8_bytes_fit_in_the_slack :: proc(t: ^testing.T) {
	// The boundary from below: 4 bad bytes net +8, exactly the slack available.
	// This case passes even against the unfixed core path, which is precisely
	// why the defect went unnoticed -- it is the FIFTH byte that kills.
	run := invalid_utf8_run(4)
	defer delete(run)
	body := strings.concatenate({`{"content":"`, run, `"}`})
	defer delete(body)

	got := extract_string(body, "content")
	defer delete(got)
	testing.expect(t, len(got) > 0, "4 invalid bytes must still decode to something")
}

@(test)
test_jsonx_invalid_utf8_does_not_panic :: proc(t: ^testing.T) {
	// REQ-JSONX-1: the minimal reproduction. Five invalid bytes overflow the
	// len+8 buffer by 2. Against HEAD this does not fail the assertion -- it
	// takes the whole test binary down inside core:encoding/json.
	run := invalid_utf8_run(5)
	defer delete(run)
	body := strings.concatenate({`{"content":"`, run, `"}`})
	defer delete(body)

	got := extract_string(body, "content")
	defer delete(got)
	testing.expect(t, len(got) > 0, "5 invalid bytes must decode without panicking")
}

@(test)
test_jsonx_binary_payload_does_not_panic :: proc(t: ^testing.T) {
	// The user's actual shape: a response string carrying raw binary. The Hub
	// escaper passes every byte >= 0x20 through verbatim, so a jpeg/png body
	// arrives as thousands of invalid UTF-8 bytes.
	blob := strings.builder_make()
	defer strings.builder_destroy(&blob)
	// 0x80..0xFF repeated: all continuation/invalid lead bytes, no escaping needed.
	for _ in 0 ..< 64 {
		for v in 0x80 ..< 0x100 do strings.write_byte(&blob, u8(v))
	}
	body := strings.concatenate({`{"content":"`, strings.to_string(blob), `"}`})
	defer delete(body)

	got := extract_string(body, "content")
	defer delete(got)
	testing.expect(t, len(got) > 0, "a binary response body must decode without panicking")
}

@(test)
test_jsonx_invalid_utf8_preserves_the_original_bytes :: proc(t: ^testing.T) {
	// REQ-JSONX-2: not panicking is not enough -- `artifact download` has to
	// write the file back byte-for-byte, so the bytes must survive verbatim
	// rather than being replaced by U+FFFD.
	raw := "\x89PNG\xff\xfe\xfd\xfc\xfb\xfa head"
	body := strings.concatenate({`{"content":"`, raw, `"}`})
	defer delete(body)

	got := extract_string(body, "content")
	defer delete(got)
	testing.expectf(t, got == raw, "binary bytes must round-trip verbatim, got %d bytes: %x", len(got), transmute([]byte)got)
}

@(test)
test_jsonx_escaped_controls_mixed_with_invalid_bytes_round_trip :: proc(t: ^testing.T) {
	// The real artifact shape, and the case the "five bytes" rule misses: a
	// payload where `\u00XX`-escaped control bytes sit alongside raw invalid
	// bytes. Here the escapes make the token far LONGER than the decoded
	// output, so core's buffer is nowhere near overflowing -- and core still
	// returns the wrong bytes, substituting U+FFFD for every high byte. Binary
	// artifacts are mostly this, so round-tripping it verbatim is what makes a
	// byte-complete `artifact download` possible.
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	expected := strings.builder_make()
	defer strings.builder_destroy(&expected)
	for i in 0 ..< 64 {
		// One escaped control byte (6 source chars -> 1 byte) ...
		strings.write_string(&b, "\\u0001")
		strings.write_byte(&expected, 0x01)
		// ... and one raw invalid lead byte (1 source char -> 1 byte).
		strings.write_byte(&b, 0xC3)
		strings.write_byte(&expected, 0xC3)
	}
	body := strings.concatenate({`{"content":"`, strings.to_string(b), `"}`})
	defer delete(body)

	got := extract_string(body, "content")
	defer delete(got)
	want := strings.to_string(expected)
	testing.expectf(
		t,
		got == want,
		"escaped controls + invalid bytes must round-trip verbatim: got %d bytes %x, want %d bytes %x",
		len(got),
		transmute([]byte)got,
		len(want),
		transmute([]byte)want,
	)
}

@(test)
test_jsonx_valid_utf8_and_escapes_still_decode :: proc(t: ^testing.T) {
	// Guard against the fix regressing the paths that already worked --
	// notably vault-armored content, which is pure-ASCII base64 and currently
	// takes core's fast clone_string path.
	armored := `vault:v1:YWJjZGVmZ2hpamtsbW5vcA==`
	body := strings.concatenate({`{"content":"`, armored, `"}`})
	defer delete(body)
	got := extract_string(body, "content")
	defer delete(got)
	testing.expect(t, got == armored, "armored ASCII content must be unchanged")

	esc := extract_string(`{"content":"a\"b\\c\nd\tz \u0041 é 😀"}`, "content")
	defer delete(esc)
	testing.expect(t, esc == "a\"b\\c\nd\tz A é \U0001F600", esc)
}
