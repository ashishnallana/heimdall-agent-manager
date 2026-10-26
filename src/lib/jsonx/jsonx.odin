package jsonx

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"

WELL_KNOWN_CONTAINERS :: [?]string{"payload", "params", "data", "result", "error"}

// find_value looks up key in a parsed JSON AST.
// Guaranteed properties:
// 1. Root keys always take precedence over nested keys.
// 2. If top_level_only is true, nested objects are not inspected.
// 3. Leaf values (like json.String) are never searched, preventing key spoofing inside string literals.
// 4. Well-known envelopes ("payload", "params", "data", "result", "error") are checked deterministically before other nested objects.
find_value :: proc(root: json.Value, key: string, top_level_only := false) -> (json.Value, bool) {
	root_obj, is_obj := root.(json.Object)
	if !is_obj do return nil, false

	// Top-level key check takes absolute precedence.
	if val, exists := root_obj[key]; exists {
		return val, true
	}

	if top_level_only do return nil, false

	// Check well-known containers first.
	for container_key in WELL_KNOWN_CONTAINERS {
		if container_val, exists := root_obj[container_key]; exists {
			if sub_obj, sub_is_obj := container_val.(json.Object); sub_is_obj {
				if found, found_ok := find_value(sub_obj, key, false); found_ok {
					return found, true
				}
			}
		}
	}

	// Then check any remaining nested json.Objects.
	for k, v in root_obj {
		is_well_known := false
		for container_key in WELL_KNOWN_CONTAINERS {
			if k == container_key {
				is_well_known = true
				break
			}
		}
		if is_well_known do continue

		if sub_obj, sub_is_obj := v.(json.Object); sub_is_obj {
			if found, found_ok := find_value(sub_obj, key, false); found_ok {
				return found, true
			}
		}
	}

	return nil, false
}

// extract_string parses body and retrieves the decoded string value of key.
// Handles string unescaping (quotes, backslashes, controls, unicode escapes, surrogate pairs).
// Supports string coercion for integers/booleans where callers expect scalars.
// Returns an owned cloned string on context.allocator (or specified allocator), or "" / cloned fallback.
extract_string :: proc(body, key: string, fallback := "", top_level_only := false, allocator := context.allocator) -> string {
	res, ok := extract_string_found(body, key, top_level_only, allocator)
	if !ok {
		return strings.clone(fallback, allocator) if fallback != "" else ""
	}
	return res
}

// extract_string_found parses body and returns (cloned_string, true) if key exists and is string/scalar.
extract_string_found :: proc(body, key: string, top_level_only := false, allocator := context.allocator) -> (string, bool) {
	parsed, parse_ok := parse_body(body, allocator)
	if !parse_ok do return "", false
	defer json.destroy_value(parsed, allocator)

	val, ok := find_value(parsed, key, top_level_only)
	if !ok do return "", false
	#partial switch v in val {
	case json.String:
		return strings.clone(string(v), allocator), true
	case json.Integer:
		return fmt.aprintf("%d", v, allocator = allocator), true
	case json.Float:
		return fmt.aprintf("%f", v, allocator = allocator), true
	case json.Boolean:
		return strings.clone("true" if v else "false", allocator), true
	case:
		return "", false
	}
}

// extract_int parses body and retrieves integer value for key, falling back if absent or non-integer.
extract_int :: proc(body, key: string, fallback := 0, top_level_only := false) -> int {
	v, ok := extract_int_found(body, key, top_level_only)
	if !ok do return fallback
	return v
}

// extract_int_found returns (int_val, true) if key exists as Integer, Float, or integer-formatted String.
extract_int_found :: proc(body, key: string, top_level_only := false) -> (int, bool) {
	parsed, parse_ok := parse_body(body, context.allocator)
	if !parse_ok do return 0, false
	defer json.destroy_value(parsed, context.allocator)

	val, ok := find_value(parsed, key, top_level_only)
	if !ok do return 0, false
	#partial switch v in val {
	case json.Integer:
		return int(v), true
	case json.Float:
		return int(v), true
	case json.String:
		if p, pok := strconv.parse_int(string(v)); pok do return int(p), true
		return 0, false
	case:
		return 0, false
	}
}

// extract_i64 parses body and retrieves i64 value for key, falling back if absent or non-integer.
extract_i64 :: proc(body, key: string, fallback: i64 = 0, top_level_only := false) -> i64 {
	v, ok := extract_i64_found(body, key, top_level_only)
	if !ok do return fallback
	return v
}

// extract_i64_found returns (i64_val, true) if key exists as Integer, Float, or integer-formatted String.
extract_i64_found :: proc(body, key: string, top_level_only := false) -> (i64, bool) {
	parsed, parse_ok := parse_body(body, context.allocator)
	if !parse_ok do return 0, false
	defer json.destroy_value(parsed, context.allocator)

	val, ok := find_value(parsed, key, top_level_only)
	if !ok do return 0, false
	#partial switch v in val {
	case json.Integer:
		return i64(v), true
	case json.Float:
		return i64(v), true
	case json.String:
		if p, pok := strconv.parse_i64(string(v)); pok do return p, true
		return 0, false
	case:
		return 0, false
	}
}

// extract_bool parses body and retrieves boolean value for key, falling back if absent or non-boolean.
extract_bool :: proc(body, key: string, fallback := false, top_level_only := false) -> bool {
	v, ok := extract_bool_found(body, key, top_level_only)
	if !ok do return fallback
	return v
}

// extract_bool_found returns (bool_val, true) if key exists as Boolean or boolean String ("true"/"false").
extract_bool_found :: proc(body, key: string, top_level_only := false) -> (bool, bool) {
	parsed, parse_ok := parse_body(body, context.allocator)
	if !parse_ok do return false, false
	defer json.destroy_value(parsed, context.allocator)

	val, ok := find_value(parsed, key, top_level_only)
	if !ok do return false, false
	#partial switch v in val {
	case json.Boolean:
		return bool(v), true
	case json.String:
		if string(v) == "true" do return true, true
		if string(v) == "false" do return false, true
		return false, false
	case json.Integer:
		return v != 0, true
	case:
		return false, false
	}
}

// extract_bool_literal requires the field to be present and strictly a JSON boolean literal (true or false).
extract_bool_literal :: proc(body, key: string, top_level_only := false) -> (value: bool, ok: bool) {
	parsed, parse_ok := parse_body(body, context.allocator)
	if !parse_ok do return false, false
	defer json.destroy_value(parsed, context.allocator)

	val, found := find_value(parsed, key, top_level_only)
	if !found do return false, false
	#partial switch v in val {
	case json.Boolean:
		return bool(v), true
	case:
		return false, false
	}
}

// has_key returns true if key exists in the parsed JSON object (even if value is json.Null).
has_key :: proc(body, key: string, top_level_only := false) -> bool {
	parsed, parse_ok := parse_body(body, context.allocator)
	if !parse_ok do return false
	defer json.destroy_value(parsed, context.allocator)

	_, ok := find_value(parsed, key, top_level_only)
	return ok
}

// extract_string_array parses body and returns cloned strings in a dynamic array.
extract_string_array :: proc(body, key: string, top_level_only := false, allocator := context.allocator) -> [dynamic]string {
	out := make([dynamic]string, allocator)
	parsed, parse_ok := parse_body(body, allocator)
	if !parse_ok do return out
	defer json.destroy_value(parsed, allocator)

	val, ok := find_value(parsed, key, top_level_only)
	if !ok do return out
	if arr, is_arr := val.(json.Array); is_arr {
		for elem in arr {
			if str, is_str := elem.(json.String); is_str {
				append(&out, strings.clone(string(str), allocator))
			}
		}
	}
	return out
}

// decode_string_array parses a flat JSON array directly (e.g. `["a","b"]`) into cloned strings.
decode_string_array :: proc(text: string, allocator := context.allocator) -> [dynamic]string {
	out := make([dynamic]string, allocator)
	parsed, parse_ok := parse_body(text, allocator)
	if !parse_ok do return out
	defer json.destroy_value(parsed, allocator)

	if arr, is_arr := parsed.(json.Array); is_arr {
		for elem in arr {
			if str, is_str := elem.(json.String); is_str {
				append(&out, strings.clone(string(str), allocator))
			}
		}
	}
	return out
}

// extract_raw_object serializes the sub-object value at key back to valid JSON.
extract_raw_object :: proc(body, key: string, top_level_only := false, allocator := context.allocator) -> (string, bool) {
	parsed, parse_ok := parse_body(body, allocator)
	if !parse_ok do return "", false
	defer json.destroy_value(parsed, allocator)

	val, ok := find_value(parsed, key, top_level_only)
	if !ok do return "", false
	if _, is_obj := val.(json.Object); !is_obj do return "", false
	bytes, merr := json.marshal(val, json.Marshal_Options{}, allocator)
	if merr != nil do return "", false
	return string(bytes), true
}

// extract_raw_array serializes the sub-array value at key back to valid JSON.
// Objects inside the array are re-marshalled from a map, so their key order is
// unspecified unless sort_keys is set; callers that compare or store the result
// (e.g. the Bridge capability record) must pass sort_keys=true to get stable bytes.
extract_raw_array :: proc(body, key: string, top_level_only := false, allocator := context.allocator, sort_keys := false) -> (string, bool) {
	parsed, parse_ok := parse_body(body, allocator)
	if !parse_ok do return "", false
	defer json.destroy_value(parsed, allocator)

	val, ok := find_value(parsed, key, top_level_only)
	if !ok do return "", false
	if _, is_arr := val.(json.Array); !is_arr do return "", false
	bytes, merr := json.marshal(val, json.Marshal_Options{sort_maps_by_key = sort_keys}, allocator)
	if merr != nil do return "", false
	return string(bytes), true
}

// json_unescape_string decodes a JSON string body (the text BETWEEN quotes) back to original bytes.
// Preserves raw bytes >= 0x20 verbatim (including 0x80..0xFF) for binary round-trips,
// and decodes standard escapes (\n, \r, \t, \b, \f, \/, \", \\) and \uXXXX unicode escapes
// (joining surrogate pairs). Malformed escapes are preserved literally.
json_unescape_string :: proc(value: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	i := 0
	for i < len(value) {
		ch := value[i]
		if ch == '\\' && i + 1 < len(value) {
			next := value[i + 1]
			switch next {
			case 'n': strings.write_byte(&b, '\n')
			case 'r': strings.write_byte(&b, '\r')
			case 't': strings.write_byte(&b, '\t')
			case 'b': strings.write_byte(&b, '\b')
			case 'f': strings.write_byte(&b, '\f')
			case '/': strings.write_byte(&b, '/')
			case '"': strings.write_byte(&b, '"')
			case '\\': strings.write_byte(&b, '\\')
			case 'u':
				if cp, width, ok := json_unescape_codepoint(value, i); ok {
					if cp < 0x80 {
						strings.write_byte(&b, u8(cp))
					} else {
						strings.write_rune(&b, rune(cp))
					}
					i += width
					continue
				}
				strings.write_byte(&b, next)
			case: strings.write_byte(&b, next)
			}
			i += 2
			continue
		}
		strings.write_byte(&b, ch)
		i += 1
	}
	return strings.to_string(b)
}

// json_unescape_codepoint reads \uXXXX (and surrogate pairs) starting at index `start`.
json_unescape_codepoint :: proc(value: string, start: int) -> (cp: int, width: int, ok: bool) {
	first, first_ok := json_hex4(value, start + 2)
	if !first_ok do return 0, 0, false
	if first >= 0xD800 && first <= 0xDBFF {
		// High surrogate: check for following low surrogate
		if start + 12 <= len(value) && value[start + 6] == '\\' && value[start + 7] == 'u' {
			if low, low_ok := json_hex4(value, start + 8); low_ok && low >= 0xDC00 && low <= 0xDFFF {
				return 0x10000 + ((first - 0xD800) << 10) + (low - 0xDC00), 12, true
			}
		}
		return 0, 0, false
	}
	if first >= 0xDC00 && first <= 0xDFFF do return 0, 0, false
	return first, 6, true
}

json_hex4 :: proc(value: string, at: int) -> (int, bool) {
	if at + 4 > len(value) do return 0, false
	out := 0
	for i in at ..< at + 4 {
		digit: int
		switch ch := value[i]; ch {
		case '0' ..= '9': digit = int(ch - '0')
		case 'a' ..= 'f': digit = int(ch - 'a') + 10
		case 'A' ..= 'F': digit = int(ch - 'A') + 10
		case: return 0, false
		}
		out = out * 16 + digit
	}
	return out, true
}
