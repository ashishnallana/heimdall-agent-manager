package extension

// Pre-clip tool-call size metrics (ham.ext.v1 event.metrics).
//
// The adapters clip every string to a few KiB before forwarding, so the bridge
// cannot see how much a tool call really put into the model's context. These
// procs measure the NATIVE tool input/response as compact JSON before json_clip
// runs, without allocating, so a 16 MiB Write payload costs one walk.

import json "core:encoding/json"
import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"

Tool_Metrics :: contracts.Ext_Tool_Metrics

// json_encoded_len is the byte length of v rendered as compact JSON with
// json_write_string's escaping. nil (absent) measures 0, not 4 ("null").
json_encoded_len :: proc(v: json.Value) -> i64 {
	if v == nil do return 0
	return json_value_len(v)
}

@(private = "file")
json_value_len :: proc(v: json.Value) -> i64 {
	switch x in v {
	case json.Null:    return 4
	case json.Boolean: return 4 if bool(x) else 5
	case json.Integer:
		buf: [32]u8
		return i64(len(strconv.write_int(buf[:], i64(x), 10)))
	case json.Float:
		buf: [64]u8
		return i64(len(strconv.write_float(buf[:], f64(x), 'g', -1, 64)))
	case json.String:
		return json_string_len(string(x))
	case json.Array:
		n := i64(2) // []
		for item, i in x {
			if i > 0 do n += 1
			n += json_value_len(item)
		}
		return n
	case json.Object:
		n := i64(2) // {}
		i := 0
		for k, item in x {
			if i > 0 do n += 1
			n += json_string_len(k) + 1 + json_value_len(item)
			i += 1
		}
		return n
	}
	return 4
}

// json_string_len mirrors json_write_string: quotes, two-byte escapes for
// " \ \n \r \t, \u00XX for other control bytes, everything else verbatim.
@(private = "file")
json_string_len :: proc(s: string) -> i64 {
	n := i64(2) + i64(len(s))
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		switch c {
		case '"', '\\', '\n', '\r', '\t': n += 1
		case:
			if c < 0x20 do n += 5
		}
	}
	return n
}

// tool_metrics measures the native input/response before clipping.
tool_metrics :: proc(input, response: json.Value) -> Tool_Metrics {
	m: Tool_Metrics
	m.input_bytes = json_encoded_len(input)
	m.response_bytes = json_encoded_len(response)
	m.est_tokens = contracts.ext_est_tokens(m.input_bytes, m.response_bytes)
	return m
}

// ext_event_metrics writes ,"metrics":{...}. Call after ext_event_tool and
// before ext_event_end.
ext_event_metrics :: proc(eb: ^Ext_Event_Builder, m: Tool_Metrics) {
	b := &eb.b
	buf: [32]u8
	strings.write_string(b, `,"metrics":{"input_bytes":`)
	strings.write_string(b, int_text(buf[:], int(m.input_bytes)))
	strings.write_string(b, `,"response_bytes":`)
	strings.write_string(b, int_text(buf[:], int(m.response_bytes)))
	strings.write_string(b, `,"est_tokens":`)
	strings.write_string(b, int_text(buf[:], int(m.est_tokens)))
	strings.write_byte(b, '}')
}
