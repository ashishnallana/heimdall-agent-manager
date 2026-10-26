package main

import "core:fmt"
import "core:strings"
import jsonx "odin_test:lib/jsonx"

extract_json_string :: proc(body, key, fallback: string, allocator := context.allocator) -> string {
	return jsonx.extract_string(body, key, fallback, false, allocator)
}

extract_json_string_unescaped :: proc(body, key, fallback: string, allocator := context.allocator) -> string {
	return jsonx.extract_string(body, key, fallback, false, allocator)
}

json_unescape_string :: proc(value: string, allocator := context.allocator) -> string {
	return jsonx.json_unescape_string(value, allocator)
}

// Deprecated: ad-hoc JSON builder allocates on dynamic heap without tracking.
// Callers should prefer typed struct serialization (`json.marshal`) on `context.temp_allocator`.
json_kv :: proc(key, value: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `"`)
	json_write_string(&b, key)
	strings.write_string(&b, `":"`)
	json_write_string(&b, value)
	strings.write_string(&b, `"`)
	return strings.to_string(b)
}

// Deprecated: ad-hoc JSON builder allocates on dynamic heap without tracking.
// Callers should prefer typed struct serialization (`json.marshal`) on `context.temp_allocator`.
json_kv_raw :: proc(key, value_json: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `"`)
	json_write_string(&b, key)
	strings.write_string(&b, `":`)
	strings.write_string(&b, value_json)
	return strings.to_string(b)
}

// Deprecated: ad-hoc JSON builder allocates on dynamic heap without tracking.
// Callers should prefer typed struct serialization (`json.marshal`) on `context.temp_allocator`.
// json_object wraps pre-serialized kv fields into a JSON object using string
// concatenation. (fmt.tprintf mishandles '{'/'}' + '%s' when field values
// contain commas, so avoid it here.)
json_object :: proc(fields: ..string) -> string {
	return strings.concatenate({"{", strings.join(fields, ","), "}"})
}

// Deprecated: ad-hoc JSON builder allocates on dynamic heap without tracking.
// Callers should prefer typed struct serialization (`json.marshal`) on `context.temp_allocator`.
json_object_from_slice :: proc(fields: []string) -> string {
	return strings.concatenate({"{", strings.join(fields, ","), "}"})
}

// ctl_error_json is the CLI's `{"ok":false,"message":…}` envelope; `extra` are
// further pre-serialized fields. Build error output with this (or json_kv), never
// with a printf format holding literal braces: core:fmt reads `{` as a
// placeholder and prints `%!(MISSING CLOSE BRACE)` instead of JSON.
ctl_error_json :: proc(message: string, extra: ..string) -> string {
	fields := make([dynamic]string, 0, 2 + len(extra), context.temp_allocator)
	append(&fields, json_kv_raw("ok", "false"), json_kv("message", message))
	append(&fields, ..extra)
	return json_object_from_slice(fields[:])
}

json_write_string :: proc(builder: ^strings.Builder, value: string) {
	for ch in value {
		switch ch {
		case '\\': strings.write_string(builder, "\\\\")
		case '"': strings.write_string(builder, "\\\"")
		case '\n': strings.write_string(builder, "\\n")
		case '\r': strings.write_string(builder, "\\r")
		case '\t': strings.write_string(builder, "\\t")
		case:
			if ch < 32 {
				strings.write_string(builder, fmt.tprintf("\\u%04x", u32(ch)))
			} else {
				strings.write_rune(builder, ch)
			}
		}
	}
}

// extract_json_object_raw returns the raw text of an OBJECT-valued member,
// braces included, e.g. `{"configured":true}` for key "data". It is string-aware,
// so braces and escaped quotes inside string values do not end the object early.
//
// Returning raw text rather than parsed fields lets a caller forward a nested
// object through verbatim without needing a typed decoder for every field in it.
extract_json_object_raw :: proc(body, key: string, allocator := context.allocator) -> (raw: string, ok: bool) {
	return jsonx.extract_raw_object(body, key, false, allocator)
}
