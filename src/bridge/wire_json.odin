package main

import "core:strings"
import "core:unicode/utf8"
import json "core:encoding/json"

// ---- JSON frames that carry host strings ---------------------------------
//
// File names, paths and git output come straight from the host and are NOT
// guaranteed to be UTF-8 (Linux names are arbitrary bytes). core:encoding/json
// writes a byte that does not decode as UTF-8 as `\xNN`, which is not a JSON
// escape, so one such name made the whole fs_list_dir_result unparseable in the
// browser ("Bad escaped character in JSON").
//
// Two layers handle it:
//   - bridge_utf8_lossy turns a host string into valid UTF-8 (each undecodable
//     byte becomes U+FFFD) and reports whether it changed anything. Listings use
//     it for entry names so they can flag `name_lossy` (see Bridge_Fs_Entry).
//   - bridge_wire_json marshals a result frame and then repairs any `\xNN` the
//     marshaller still produced into `\ufffd`, so every fs/vcs result frame is
//     valid JSON whatever host string reached it.
//
// Valid UTF-8 is never altered: quotes, backslashes, control characters and
// non-BMP runes keep the marshaller's standard JSON escapes and round-trip.

// bridge_utf8_lossy returns `s` as valid UTF-8, replacing every byte that does not
// start a valid encoding with U+FFFD. `lossy` is true when a replacement happened,
// i.e. the result no longer names the same bytes on disk. Always allocates.
bridge_utf8_lossy :: proc(s: string, allocator := context.allocator) -> (out: string, lossy: bool) {
	if utf8.valid_string(s) do return strings.clone(s, allocator), false
	b := strings.builder_make(0, len(s) + 8, allocator)
	for rest := s; len(rest) > 0; {
		r, width := utf8.decode_rune_in_string(rest)
		if r == utf8.RUNE_ERROR && width <= 1 {
			strings.write_rune(&b, utf8.RUNE_ERROR)
			lossy = true
			width = 1
		} else {
			strings.write_string(&b, rest[:width])
		}
		rest = rest[width:]
	}
	return strings.to_string(b), lossy
}

// bridge_json_repair_invalid_utf8 rewrites every `\xNN` escape in marshalled JSON
// to `\ufffd`. It relies on JSON's grammar: outside strings a backslash never
// appears, and inside a string every backslash starts a two-character escape, so
// walking escape pairs finds exactly the marshaller's `\x` escapes and never the
// text of an escaped backslash followed by `x` (`\\x`). Valid JSON is returned
// unchanged. Always allocates.
bridge_json_repair_invalid_utf8 :: proc(data: string, allocator := context.allocator) -> string {
	if !strings.contains(data, `\x`) do return strings.clone(data, allocator)
	b := strings.builder_make(0, len(data) + 16, allocator)
	i := 0
	for i < len(data) {
		c := data[i]
		if c != '\\' || i + 1 >= len(data) {
			strings.write_byte(&b, c)
			i += 1
			continue
		}
		if data[i + 1] == 'x' && i + 3 < len(data) && bridge_is_hex_digit(data[i + 2]) && bridge_is_hex_digit(data[i + 3]) {
			strings.write_string(&b, `\ufffd`)
			i += 4
			continue
		}
		strings.write_byte(&b, c)
		strings.write_byte(&b, data[i + 1])
		i += 2
	}
	return strings.to_string(b)
}

@(private = "file")
bridge_is_hex_digit :: proc(c: byte) -> bool {
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

// bridge_wire_json marshals a result frame into valid JSON (see the header above).
// Returns "" when marshalling fails, matching the callers' existing contract.
bridge_wire_json :: proc(wire: any, allocator := context.allocator) -> string {
	data, err := json.marshal(wire, allocator = context.temp_allocator)
	if err != nil do return ""
	return bridge_json_repair_invalid_utf8(string(data), allocator)
}
