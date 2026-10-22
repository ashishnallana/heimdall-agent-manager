package extension

// Small JSON helpers shared by the provider adapters. Values parsed here borrow
// from the parse tree; everything is allocated with context.allocator, which in
// ham-ctl is a one-shot process arena.

import json "core:encoding/json"
import "core:fmt"
import "core:strings"

EXT_CLIP_MARKER :: "…[truncated by heimdall]"

json_get_string :: proc(obj: json.Object, key: string) -> string {
	if obj == nil do return ""
	if s, ok := obj[key].(json.String); ok do return string(s)
	return ""
}

json_get_object :: proc(obj: json.Object, key: string) -> json.Object {
	if obj == nil do return nil
	if o, ok := obj[key].(json.Object); ok do return o
	return nil
}

json_get_array :: proc(obj: json.Object, key: string) -> json.Array {
	if obj == nil do return nil
	if a, ok := obj[key].(json.Array); ok do return a
	return nil
}

json_get_int :: proc(obj: json.Object, key: string) -> (int, bool) {
	if obj == nil do return 0, false
	#partial switch v in obj[key] {
	case json.Integer: return int(v), true
	case json.Float:   return int(v), true
	}
	return 0, false
}

json_get_bool :: proc(obj: json.Object, key: string) -> bool {
	if obj == nil do return false
	if b, ok := obj[key].(json.Boolean); ok do return bool(b)
	return false
}

json_has :: proc(obj: json.Object, key: string) -> bool {
	if obj == nil do return false
	_, ok := obj[key]
	return ok
}

// json_write_string writes s as a quoted, escaped JSON string.
json_write_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		switch c {
		case '"':  strings.write_string(b, `\"`)
		case '\\': strings.write_string(b, `\\`)
		case '\n': strings.write_string(b, `\n`)
		case '\r': strings.write_string(b, `\r`)
		case '\t': strings.write_string(b, `\t`)
		case:
			if c < 0x20 {
				fmt.sbprintf(b, `\u%04x`, c)
			} else {
				strings.write_byte(b, c)
			}
		}
	}
	strings.write_byte(b, '"')
}

// json_write_value marshals v with sorted keys (deterministic output).
json_write_value :: proc(b: ^strings.Builder, v: json.Value) {
	data, err := json.marshal(v, {sort_maps_by_key = true})
	if err != nil {
		strings.write_string(b, "null")
		return
	}
	strings.write_string(b, string(data))
}

// clip_string cuts s to at most max bytes on a UTF-8 boundary and appends
// EXT_CLIP_MARKER when it was cut.
clip_string :: proc(s: string, max: int) -> string {
	if len(s) <= max do return s
	cut := max
	for cut > 0 && (s[cut] & 0xC0) == 0x80 do cut -= 1
	return strings.concatenate({s[:cut], EXT_CLIP_MARKER})
}

// json_clip returns a copy of v in which every string longer than max_str is
// clipped. Objects listed in drop_keys (top level only) are omitted.
json_clip :: proc(v: json.Value, max_str: int, drop_keys: []string = nil) -> json.Value {
	#partial switch x in v {
	case json.String:
		return json.String(clip_string(string(x), max_str))
	case json.Array:
		out := make(json.Array, len(x))
		for item, i in x do out[i] = json_clip(item, max_str)
		return out
	case json.Object:
		out := make(json.Object)
		outer: for k, item in x {
			for d in drop_keys do if d == k do continue outer
			out[k] = json_clip(item, max_str)
		}
		return out
	}
	return v
}
