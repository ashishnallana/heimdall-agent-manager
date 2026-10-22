package contracts

// ham.ext.v1 — the provider-agnostic contract a harness extension (Claude Code
// hooks, …) speaks to the bridge via `agent.extension.event`, and the bridge
// forwards verbatim (after normalisation) to the hub.
//
//   {schema:"ham.ext.v1", provider, ext_version, event, ts, session_id,
//    transcript_path?, agent:{id?,type?}, tool?:{name,use_id?,input?,response?},
//    payload}
//
// Provider-specific translation lives in the ctl/extension layer; nothing here
// may know about a particular harness.

import json "core:encoding/json"
import "core:strings"

EXT_SCHEMA_V1 :: "ham.ext.v1"
// EXT_EVENT_MAX_BYTES caps ONE normalised event (after diff truncation).
EXT_EVENT_MAX_BYTES :: 256 * 1024
// EXT_DIFF_MAX_BYTES caps payload.diff; longer diffs are cut and marked.
EXT_DIFF_MAX_BYTES :: 64 * 1024
// EXT_BATCH_MAX_BYTES caps a whole agent.extension.event params body so a
// runaway caller cannot make the bridge parse an unbounded document.
EXT_BATCH_MAX_BYTES :: 4 * 1024 * 1024
// EXT_BATCH_MAX_EVENTS caps how many events one call may carry.
EXT_BATCH_MAX_EVENTS :: 500
EXT_TRUNCATED_MARKER :: "\n…[truncated by heimdall]"

Ext_Event_Kind :: enum {
	Hello,
	Session,
	Activity,
	Tool_Start,
	Tool_End,
	Subagent_Start,
	Subagent_Stop,
	File_Edit,
	Permission_Request,
	Notification,
}

Ext_Error :: enum {
	None,
	Too_Large,
	Malformed_Json,
	Bad_Schema,
	Unknown_Event,
	Missing_Provider,
	Too_Many_Events,
}

// Ext_Event is the flattened, validated view of one ham.ext.v1 event. All
// strings are owned (cloned); release with ext_event_destroy.
Ext_Event :: struct {
	kind:              Ext_Event_Kind,
	provider:          string,
	ext_version:       string,
	ts:                string,
	session_id:        string,
	transcript_path:   string,
	agent_id:          string,
	agent_type:        string,
	tool_name:         string,
	tool_use_id:       string,
	file_path:         string, // file.edit only
	activity_state:    string, // activity only (payload.state)
	notification_type: string, // notification only (payload.type | payload.notification_type)
	capabilities:      [dynamic]string, // hello only (payload.capabilities)
}

ext_event_kind_name :: proc(k: Ext_Event_Kind) -> string {
	switch k {
	case .Hello:              return "hello"
	case .Session:            return "session"
	case .Activity:           return "activity"
	case .Tool_Start:         return "tool.start"
	case .Tool_End:           return "tool.end"
	case .Subagent_Start:     return "subagent.start"
	case .Subagent_Stop:      return "subagent.stop"
	case .File_Edit:          return "file.edit"
	case .Permission_Request: return "permission.request"
	case .Notification:       return "notification"
	}
	return ""
}

ext_event_kind_from_string :: proc(s: string) -> (Ext_Event_Kind, bool) {
	for k in Ext_Event_Kind {
		if ext_event_kind_name(k) == s do return k, true
	}
	return .Hello, false
}

ext_error_message :: proc(e: Ext_Error) -> string {
	switch e {
	case .None:             return ""
	case .Too_Large:        return "event exceeds 256KB"
	case .Malformed_Json:   return "event is not a JSON object"
	case .Bad_Schema:       return "schema must be \"ham.ext.v1\""
	case .Unknown_Event:    return "unknown event"
	case .Missing_Provider: return "provider is required"
	case .Too_Many_Events:  return "too many events in one batch"
	}
	return "invalid event"
}

ext_event_destroy :: proc(ev: ^Ext_Event) {
	delete(ev.provider); delete(ev.ext_version); delete(ev.ts); delete(ev.session_id)
	delete(ev.transcript_path); delete(ev.agent_id); delete(ev.agent_type); delete(ev.tool_name)
	delete(ev.tool_use_id); delete(ev.file_path); delete(ev.activity_state); delete(ev.notification_type)
	for c in ev.capabilities do delete(c)
	delete(ev.capabilities)
	ev^ = {}
}

@(private = "file")
ext_obj_string :: proc(obj: json.Object, key: string) -> string {
	if obj == nil do return ""
	v, ok := obj[key]
	if !ok do return ""
	#partial switch x in v {
	case json.String:  return strings.clone(string(x))
	case json.Integer: return strings.clone(json_int_text(i64(x)))
	case json.Float:   return strings.clone(json_int_text(i64(x)))
	}
	return ""
}

@(private = "file")
json_int_text :: proc(n: i64) -> string {
	buf: [32]u8
	i := len(buf)
	neg := n < 0
	u := u64(-n) if neg else u64(n)
	if u == 0 { i -= 1; buf[i] = '0' }
	for u > 0 { i -= 1; buf[i] = u8('0' + u % 10); u /= 10 }
	if neg { i -= 1; buf[i] = '-' }
	return strings.clone_from_bytes(buf[i:], context.temp_allocator)
}

@(private = "file")
ext_obj_object :: proc(obj: json.Object, key: string) -> json.Object {
	if obj == nil do return nil
	v, ok := obj[key]
	if !ok do return nil
	if o, is := v.(json.Object); is do return o
	return nil
}

// ext_parse_event validates one ham.ext.v1 event and flattens the fields the
// bridge and hub index on. raw must be a single JSON object.
ext_parse_event :: proc(raw: string) -> (ev: Ext_Event, err: Ext_Error) {
	if len(raw) > EXT_EVENT_MAX_BYTES do return {}, .Too_Large
	value, perr := json.parse_string(raw, json.DEFAULT_SPECIFICATION, true)
	if perr != .None do return {}, .Malformed_Json
	defer json.destroy_value(value)
	root, is_obj := value.(json.Object)
	if !is_obj do return {}, .Malformed_Json

	schema := ext_obj_string(root, "schema")
	defer delete(schema)
	if schema != EXT_SCHEMA_V1 do return {}, .Bad_Schema
	name := ext_obj_string(root, "event")
	defer delete(name)
	kind, known := ext_event_kind_from_string(name)
	if !known do return {}, .Unknown_Event
	provider := ext_obj_string(root, "provider")
	if strings.trim_space(provider) == "" {
		delete(provider)
		return {}, .Missing_Provider
	}

	ev.kind = kind
	ev.provider = provider
	ev.ext_version = ext_obj_string(root, "ext_version")
	ev.ts = ext_obj_string(root, "ts")
	ev.session_id = ext_obj_string(root, "session_id")
	ev.transcript_path = ext_obj_string(root, "transcript_path")
	agent := ext_obj_object(root, "agent")
	ev.agent_id = ext_obj_string(agent, "id")
	ev.agent_type = ext_obj_string(agent, "type")
	tool := ext_obj_object(root, "tool")
	ev.tool_name = ext_obj_string(tool, "name")
	ev.tool_use_id = ext_obj_string(tool, "use_id")
	payload := ext_obj_object(root, "payload")

	#partial switch kind {
	case .File_Edit:
		ev.file_path = ext_obj_string(payload, "file_path")
		if ev.file_path == "" {
			delete(ev.file_path)
			ev.file_path = ext_obj_string(ext_obj_object(tool, "input"), "file_path")
		}
	case .Activity:
		ev.activity_state = ext_obj_string(payload, "state")
	case .Notification:
		ev.notification_type = ext_obj_string(payload, "type")
		if ev.notification_type == "" {
			delete(ev.notification_type)
			ev.notification_type = ext_obj_string(payload, "notification_type")
		}
	case .Hello:
		if payload != nil {
			if caps, ok := payload["capabilities"].(json.Array); ok {
				for c in caps {
					if s, is := c.(json.String); is do append(&ev.capabilities, strings.clone(string(s)))
				}
			}
		}
	}
	return ev, .None
}

// ext_activity_for_event maps an event onto the bridge activity vocabulary.
// ok=false means the event says nothing about activity.
ext_activity_for_event :: proc(ev: Ext_Event) -> (status: string, ok: bool) {
	#partial switch ev.kind {
	case .Tool_Start, .Subagent_Start:
		return "active", true
	case .Activity:
		s := strings.to_lower(strings.trim_space(ev.activity_state), context.temp_allocator)
		if s == "active" || s == "working" || s == "busy" do return "active", true
		if s == "idle" do return "idle", true
		if s == "waiting_user" do return "waiting_user", true
	case .Notification:
		if ev.notification_type == "permission_prompt" do return "waiting_user", true
	case .Permission_Request:
		return "waiting_user", true
	}
	return "", false
}

// ext_truncate_diff caps a diff at EXT_DIFF_MAX_BYTES (cut on a UTF-8 boundary)
// and appends EXT_TRUNCATED_MARKER. Returns s unchanged (not a copy) when short.
ext_truncate_diff :: proc(s: string) -> (out: string, truncated: bool) {
	if len(s) <= EXT_DIFF_MAX_BYTES do return s, false
	cut := EXT_DIFF_MAX_BYTES
	for cut > 0 && (s[cut] & 0xC0) == 0x80 do cut -= 1
	return strings.concatenate({s[:cut], EXT_TRUNCATED_MARKER}), true
}

// ext_split_events accepts either one event object or {"events":[...]} and
// returns each event as normalised JSON text (payload.diff truncated, with
// payload.diff_truncated=true). Elements that are not objects are returned as
// their marshalled text so ext_parse_event rejects them individually. The
// caller owns the returned strings (ext_split_events_destroy).
ext_split_events :: proc(params: string) -> (events: [dynamic]string, err: Ext_Error) {
	if len(params) > EXT_BATCH_MAX_BYTES do return nil, .Too_Large
	value, perr := json.parse_string(params, json.DEFAULT_SPECIFICATION, true)
	if perr != .None do return nil, .Malformed_Json
	defer json.destroy_value(value)
	root, is_obj := value.(json.Object)
	if !is_obj do return nil, .Malformed_Json

	if arr_v, has := root["events"]; has {
		arr, is_arr := arr_v.(json.Array)
		if !is_arr do return nil, .Malformed_Json
		if len(arr) > EXT_BATCH_MAX_EVENTS do return nil, .Too_Many_Events
		for &item in arr do append(&events, ext_normalize_value(&item))
		return events, .None
	}
	append(&events, ext_normalize_value(&value))
	return events, .None
}

ext_split_events_destroy :: proc(events: [dynamic]string) {
	for e in events do delete(e)
	delete(events)
}

@(private = "file")
ext_normalize_value :: proc(v: ^json.Value) -> string {
	if obj, ok := v.(json.Object); ok {
		if payload, pok := obj["payload"].(json.Object); pok {
			if diff, dok := payload["diff"].(json.String); dok {
				cut, truncated := ext_truncate_diff(string(diff))
				if truncated {
					delete(string(diff))
					payload["diff"] = json.String(cut)
					// Map keys are owned by the value tree; allocate ours so
					// json.destroy_value frees it like the rest.
					payload[strings.clone("diff_truncated")] = json.Boolean(true)
					obj["payload"] = payload
				}
			}
		}
	}
	data, merr := json.marshal(v^)
	if merr != nil do return strings.clone("null")
	return string(data)
}
