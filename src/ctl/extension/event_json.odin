package extension

// Provider-neutral bounded event envelope and payload builders.
import json "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"

// Ext_Event_Builder writes one ham.ext.v1 event in a fixed key order.
Ext_Event_Builder :: struct {
	b: strings.Builder,
}

ext_event_begin :: proc(event: string, ts: string, root: json.Object, provider, version: string) -> (eb: Ext_Event_Builder) {
	eb.b = strings.builder_make()
	b := &eb.b
	strings.write_string(b, `{"schema":`); json_write_string(b, contracts.EXT_SCHEMA_V1)
	strings.write_string(b, `,"provider":`); json_write_string(b, provider)
	strings.write_string(b, `,"ext_version":`); json_write_string(b, version)
	strings.write_string(b, `,"event":`); json_write_string(b, event)
	strings.write_string(b, `,"ts":`); json_write_string(b, ts)
	strings.write_string(b, `,"session_id":`); json_write_string(b, json_get_string(root, "session_id"))
	if tp := json_get_string(root, "transcript_path"); tp != "" {
		strings.write_string(b, `,"transcript_path":`); json_write_string(b, tp)
	}
	strings.write_string(b, `,"agent":{`)
	if id := json_get_string(root, "agent_id"); id != "" {
		strings.write_string(b, `"id":`); json_write_string(b, id)
		if t := json_get_string(root, "agent_type"); t != "" {
			strings.write_string(b, `,"type":`); json_write_string(b, t)
		}
	}
	strings.write_byte(b, '}')
	return eb
}

// ext_event_tool writes tool:{name,use_id?,input?,response?}. input/response
// are written only when non-nil.
ext_event_tool :: proc(eb: ^Ext_Event_Builder, root: json.Object, input, response: json.Value) {
	b := &eb.b
	strings.write_string(b, `,"tool":{"name":`); json_write_string(b, json_get_string(root, "tool_name"))
	if id := json_get_string(root, "tool_use_id"); id != "" {
		strings.write_string(b, `,"use_id":`); json_write_string(b, id)
	}
	if input != nil {
		strings.write_string(b, `,"input":`); json_write_value(b, input)
	}
	if response != nil {
		strings.write_string(b, `,"response":`); json_write_value(b, response)
	}
	strings.write_byte(b, '}')
}

// ext_event_end writes payload (a pre-rendered JSON object) and closes.
ext_event_end :: proc(eb: ^Ext_Event_Builder, payload: string) -> string {
	b := &eb.b
	strings.write_string(b, `,"payload":`)
	strings.write_string(b, payload if payload != "" else "{}")
	strings.write_byte(b, '}')
	return strings.to_string(eb.b)
}

// Payload_Builder accumulates a flat JSON object.
Payload_Builder :: struct {
	b: strings.Builder,
	n: int,
}

pb_make :: proc() -> (p: Payload_Builder) {
	p.b = strings.builder_make()
	strings.write_byte(&p.b, '{')
	return p
}

pb_key :: proc(p: ^Payload_Builder, key: string) {
	if p.n > 0 do strings.write_byte(&p.b, ',')
	p.n += 1
	json_write_string(&p.b, key)
	strings.write_byte(&p.b, ':')
}

pb_str :: proc(p: ^Payload_Builder, key, value: string) {
	pb_key(p, key); json_write_string(&p.b, value)
}

// pb_str_nonempty writes key only when value is non-empty.
pb_str_nonempty :: proc(p: ^Payload_Builder, key, value: string) {
	if value != "" do pb_str(p, key, value)
}

pb_int :: proc(p: ^Payload_Builder, key: string, value: int) {
	pb_key(p, key)
	buf: [32]u8
	strings.write_string(&p.b, int_text(buf[:], value))
}

pb_bool :: proc(p: ^Payload_Builder, key: string, value: bool) {
	pb_key(p, key); strings.write_string(&p.b, "true" if value else "false")
}

pb_value :: proc(p: ^Payload_Builder, key: string, value: json.Value) {
	pb_key(p, key); json_write_value(&p.b, value)
}

pb_done :: proc(p: ^Payload_Builder) -> string {
	strings.write_byte(&p.b, '}')
	return strings.to_string(p.b)
}

int_text :: proc(buf: []u8, n: int) -> string {
	i := len(buf)
	neg := n < 0
	u := u64(-n) if neg else u64(n)
	if u == 0 { i -= 1; buf[i] = '0' }
	for u > 0 { i -= 1; buf[i] = u8('0' + u % 10); u /= 10 }
	if neg { i -= 1; buf[i] = '-' }
	return string(buf[i:])
}


// event_params is the agent.extension.event params body for events:
// the single event itself, or {"events":[...]} for several.
event_params :: proc(events: []string) -> string {
	if len(events) == 1 do return events[0]
	b := strings.builder_make()
	strings.write_string(&b, `{"events":[`)
	for e, i in events {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, e)
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}
