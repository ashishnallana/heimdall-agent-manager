package extension

// Claude Code adapter (REQ-EXT-CLAUDE-1): native hook JSON on stdin → ham.ext.v1.
//
//   SessionStart        → hello (capabilities) + session {phase:start}
//   SessionEnd          → session {phase:end}
//   UserPromptSubmit    → activity {state:active}
//   PreToolUse          → tool.start
//   PostToolUse         → tool.end (+ file.edit for Edit / MultiEdit / Write)
//   PostToolUseFailure  → tool.end {status:error}
//   SubagentStart/Stop  → subagent.start / subagent.stop
//   Stop                → activity {state:idle}
//   Notification        → notification
//   PermissionRequest   → permission.request (sent with agent.extension.permission)
//
// Payload facts come from the T1 spike against Claude Code 2.1.295: every hook
// fired inside a subagent carries top-level agent_id/agent_type; SubagentStart
// has no tool_use_id, so PreToolUse(Agent) and PostToolUse(Agent) expose the
// description and the authoritative tool_response.agentId for pairing;
// PermissionRequest has no tool_use_id. This file is the only place in the
// product that knows Claude's hook vocabulary.

import json "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"

CLAUDE_PROVIDER :: "claude"
CLAUDE_EXT_VERSION :: "0.1.0"
CLAUDE_CAPABILITIES :: [?]string{"activity", "subagents", "permissions", "file_edits", "session_id"}

// Strings inside tool input / response are clipped so one event stays well
// under contracts.EXT_EVENT_MAX_BYTES (256KB) even with a 64KB diff.
CLAUDE_TOOL_STRING_MAX :: 4 * 1024
CLAUDE_MESSAGE_MAX :: 2 * 1024
// Hook stdin larger than this is ignored (Write payloads carry whole files).
CLAUDE_HOOK_INPUT_MAX :: 16 * 1024 * 1024

Claude_Hook :: enum {
	Unknown,
	Session_Start,
	Session_End,
	User_Prompt_Submit,
	Pre_Tool_Use,
	Post_Tool_Use,
	Post_Tool_Use_Failure,
	Subagent_Start,
	Subagent_Stop,
	Stop,
	Notification,
	Permission_Request,
}

claude_hook_from_name :: proc(name: string) -> Claude_Hook {
	switch name {
	case "SessionStart":       return .Session_Start
	case "SessionEnd":         return .Session_End
	case "UserPromptSubmit":   return .User_Prompt_Submit
	case "PreToolUse":         return .Pre_Tool_Use
	case "PostToolUse":        return .Post_Tool_Use
	case "PostToolUseFailure": return .Post_Tool_Use_Failure
	case "SubagentStart":      return .Subagent_Start
	case "SubagentStop":       return .Subagent_Stop
	case "Stop":               return .Stop
	case "Notification":       return .Notification
	case "PermissionRequest":  return .Permission_Request
	}
	return .Unknown
}

// Claude_Mapped is the result of mapping one hook invocation. events are
// complete ham.ext.v1 JSON documents in send order. For a PermissionRequest the
// single event must go to agent.extension.permission; everything else goes to
// agent.extension.event (claude_event_params).
Claude_Mapped :: struct {
	hook:          Claude_Hook,
	events:        [dynamic]string,
	is_permission: bool,
}

Claude_Error :: enum {
	None,
	Too_Large,
	Malformed_Json,
}

// Ext_Event_Builder writes one ham.ext.v1 event in a fixed key order.
@(private = "file")
Ext_Event_Builder :: struct {
	b: strings.Builder,
}

@(private = "file")
claude_event_begin :: proc(event: string, ts: string, root: json.Object) -> (eb: Ext_Event_Builder) {
	eb.b = strings.builder_make()
	b := &eb.b
	strings.write_string(b, `{"schema":`); json_write_string(b, contracts.EXT_SCHEMA_V1)
	strings.write_string(b, `,"provider":`); json_write_string(b, CLAUDE_PROVIDER)
	strings.write_string(b, `,"ext_version":`); json_write_string(b, CLAUDE_EXT_VERSION)
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

// claude_event_tool writes tool:{name,use_id?,input?,response?}. input/response
// are written only when non-nil.
@(private = "file")
claude_event_tool :: proc(eb: ^Ext_Event_Builder, root: json.Object, input, response: json.Value) {
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

// claude_event_end writes payload (a pre-rendered JSON object) and closes.
@(private = "file")
claude_event_end :: proc(eb: ^Ext_Event_Builder, payload: string) -> string {
	b := &eb.b
	strings.write_string(b, `,"payload":`)
	strings.write_string(b, payload if payload != "" else "{}")
	strings.write_byte(b, '}')
	return strings.to_string(eb.b)
}

// Payload_Builder accumulates a flat JSON object.
@(private = "file")
Payload_Builder :: struct {
	b: strings.Builder,
	n: int,
}

@(private = "file")
pb_make :: proc() -> (p: Payload_Builder) {
	p.b = strings.builder_make()
	strings.write_byte(&p.b, '{')
	return p
}

@(private = "file")
pb_key :: proc(p: ^Payload_Builder, key: string) {
	if p.n > 0 do strings.write_byte(&p.b, ',')
	p.n += 1
	json_write_string(&p.b, key)
	strings.write_byte(&p.b, ':')
}

@(private = "file")
pb_str :: proc(p: ^Payload_Builder, key, value: string) {
	pb_key(p, key); json_write_string(&p.b, value)
}

// pb_str_nonempty writes key only when value is non-empty.
@(private = "file")
pb_str_nonempty :: proc(p: ^Payload_Builder, key, value: string) {
	if value != "" do pb_str(p, key, value)
}

@(private = "file")
pb_int :: proc(p: ^Payload_Builder, key: string, value: int) {
	pb_key(p, key)
	buf: [32]u8
	strings.write_string(&p.b, int_text(buf[:], value))
}

@(private = "file")
pb_bool :: proc(p: ^Payload_Builder, key: string, value: bool) {
	pb_key(p, key); strings.write_string(&p.b, "true" if value else "false")
}

@(private = "file")
pb_value :: proc(p: ^Payload_Builder, key: string, value: json.Value) {
	pb_key(p, key); json_write_value(&p.b, value)
}

@(private = "file")
pb_done :: proc(p: ^Payload_Builder) -> string {
	strings.write_byte(&p.b, '}')
	return strings.to_string(p.b)
}

@(private = "file")
int_text :: proc(buf: []u8, n: int) -> string {
	i := len(buf)
	neg := n < 0
	u := u64(-n) if neg else u64(n)
	if u == 0 { i -= 1; buf[i] = '0' }
	for u > 0 { i -= 1; buf[i] = u8('0' + u % 10); u /= 10 }
	if neg { i -= 1; buf[i] = '-' }
	return string(buf[i:])
}

// claude_map_hook maps one Claude hook payload. ts is the RFC 3339 event time
// (injected so tests are deterministic). An unknown hook maps to no events.
// permission_timeout_ms > 0 is sent as payload.timeout_ms on permission.request
// so the relay always gives up before the plugin's hook timeout, and a non-empty
// permission_blocker_id as payload.blocker_id (stable across re-registrations).
claude_map_hook :: proc(raw: string, ts: string, permission_timeout_ms := 0, permission_blocker_id := "") -> (out: Claude_Mapped, err: Claude_Error) {
	if len(raw) > CLAUDE_HOOK_INPUT_MAX do return out, .Too_Large
	value, perr := json.parse_string(raw, json.DEFAULT_SPECIFICATION, true)
	if perr != .None do return out, .Malformed_Json
	root, is_obj := value.(json.Object)
	if !is_obj do return out, .Malformed_Json

	out.hook = claude_hook_from_name(json_get_string(root, "hook_event_name"))
	switch out.hook {
	case .Unknown:
	case .Session_Start:
		caps := CLAUDE_CAPABILITIES
		p := pb_make()
		pb_key(&p, "capabilities")
		strings.write_byte(&p.b, '[')
		for c, i in caps {
			if i > 0 do strings.write_byte(&p.b, ',')
			json_write_string(&p.b, c)
		}
		strings.write_byte(&p.b, ']')
		pb_str_nonempty(&p, "source", json_get_string(root, "source"))
		eb := claude_event_begin("hello", ts, root)
		append(&out.events, claude_event_end(&eb, pb_done(&p)))

		s := pb_make()
		pb_str(&s, "phase", "start")
		pb_str_nonempty(&s, "source", json_get_string(root, "source"))
		pb_str_nonempty(&s, "cwd", json_get_string(root, "cwd"))
		pb_str_nonempty(&s, "model", json_get_string(root, "model"))
		eb2 := claude_event_begin("session", ts, root)
		append(&out.events, claude_event_end(&eb2, pb_done(&s)))

	case .Session_End:
		p := pb_make()
		pb_str(&p, "phase", "end")
		pb_str_nonempty(&p, "reason", json_get_string(root, "reason"))
		eb := claude_event_begin("session", ts, root)
		append(&out.events, claude_event_end(&eb, pb_done(&p)))

	case .User_Prompt_Submit:
		p := pb_make()
		pb_str(&p, "state", "active")
		pb_str(&p, "reason", "user_prompt")
		pb_str_nonempty(&p, "prompt_id", json_get_string(root, "prompt_id"))
		eb := claude_event_begin("activity", ts, root)
		append(&out.events, claude_event_end(&eb, pb_done(&p)))

	case .Stop:
		p := pb_make()
		pb_str(&p, "state", "idle")
		pb_str(&p, "reason", "stop")
		// Stop can fire while background subagents still run; they stay
		// active until their own subagent.stop.
		running := 0
		for t in json_get_array(root, "background_tasks") {
			if obj, ok := t.(json.Object); ok && json_get_string(obj, "status") == "running" do running += 1
		}
		pb_int(&p, "background_running", running)
		eb := claude_event_begin("activity", ts, root)
		append(&out.events, claude_event_end(&eb, pb_done(&p)))

	case .Pre_Tool_Use:
		input := json_clip(root["tool_input"], CLAUDE_TOOL_STRING_MAX)
		p := pb_make()
		pb_str_nonempty(&p, "permission_mode", json_get_string(root, "permission_mode"))
		if json_get_string(root, "tool_name") == "Agent" || json_get_string(root, "tool_name") == "Task" {
			ti := json_get_object(root, "tool_input")
			pb_str_nonempty(&p, "description", json_get_string(ti, "description"))
			pb_str_nonempty(&p, "subagent_type", json_get_string(ti, "subagent_type"))
			pb_bool(&p, "run_in_background", json_get_bool(ti, "run_in_background"))
		}
		eb := claude_event_begin("tool.start", ts, root)
		claude_event_tool(&eb, root, input, nil)
		append(&out.events, claude_event_end(&eb, pb_done(&p)))

	case .Post_Tool_Use:
		tool := json_get_string(root, "tool_name")
		input := json_clip(root["tool_input"], CLAUDE_TOOL_STRING_MAX)
		// Whole-file fields duplicate the diff; drop them from tool.response.
		response := json_clip(root["tool_response"], CLAUDE_TOOL_STRING_MAX,
			{"originalFile", "content", "structuredPatch", "prompt", "usage"})
		p := pb_make()
		pb_str(&p, "status", "ok")
		if d, ok := json_get_int(root, "duration_ms"); ok do pb_int(&p, "duration_ms", d)
		if tool == "Agent" || tool == "Task" {
			tr := json_get_object(root, "tool_response")
			pb_str_nonempty(&p, "subagent_id", json_get_string(tr, "agentId"))
			pb_str_nonempty(&p, "subagent_status", json_get_string(tr, "status"))
			pb_str_nonempty(&p, "description", json_get_string(json_get_object(root, "tool_input"), "description"))
		}
		eb := claude_event_begin("tool.end", ts, root)
		claude_event_tool(&eb, root, input, response)
		append(&out.events, claude_event_end(&eb, pb_done(&p)))
		if ev, ok := claude_file_edit_event(root, ts); ok do append(&out.events, ev)

	case .Post_Tool_Use_Failure:
		input := json_clip(root["tool_input"], CLAUDE_TOOL_STRING_MAX)
		p := pb_make()
		pb_str(&p, "status", "error")
		pb_str_nonempty(&p, "error", clip_string(json_get_string(root, "error"), CLAUDE_MESSAGE_MAX))
		if json_get_bool(root, "is_interrupt") do pb_bool(&p, "is_interrupt", true)
		eb := claude_event_begin("tool.end", ts, root)
		claude_event_tool(&eb, root, input, nil)
		append(&out.events, claude_event_end(&eb, pb_done(&p)))

	case .Subagent_Start:
		eb := claude_event_begin("subagent.start", ts, root)
		append(&out.events, claude_event_end(&eb, "{}"))

	case .Subagent_Stop:
		p := pb_make()
		pb_str_nonempty(&p, "agent_transcript_path", json_get_string(root, "agent_transcript_path"))
		pb_str_nonempty(&p, "last_assistant_message", clip_string(json_get_string(root, "last_assistant_message"), CLAUDE_MESSAGE_MAX))
		eb := claude_event_begin("subagent.stop", ts, root)
		append(&out.events, claude_event_end(&eb, pb_done(&p)))

	case .Notification:
		ntype := json_get_string(root, "notification_type")
		p := pb_make()
		pb_str_nonempty(&p, "type", ntype)
		pb_str_nonempty(&p, "notification_type", ntype)
		pb_str_nonempty(&p, "title", clip_string(json_get_string(root, "title"), CLAUDE_MESSAGE_MAX))
		pb_str_nonempty(&p, "message", clip_string(json_get_string(root, "message"), CLAUDE_MESSAGE_MAX))
		eb := claude_event_begin("notification", ts, root)
		append(&out.events, claude_event_end(&eb, pb_done(&p)))

	case .Permission_Request:
		input := json_clip(root["tool_input"], CLAUDE_TOOL_STRING_MAX)
		p := pb_make()
		pb_str_nonempty(&p, "permission_mode", json_get_string(root, "permission_mode"))
		if permission_timeout_ms > 0 do pb_int(&p, "timeout_ms", permission_timeout_ms)
		pb_str_nonempty(&p, "blocker_id", permission_blocker_id)
		if sugg := json_get_array(root, "permission_suggestions"); sugg != nil {
			pb_value(&p, "permission_suggestions", json_clip(sugg, CLAUDE_TOOL_STRING_MAX))
		}
		eb := claude_event_begin("permission.request", ts, root)
		if input == nil do input = json.Object{}
		claude_event_tool(&eb, root, input, nil)
		append(&out.events, claude_event_end(&eb, pb_done(&p)))
		out.is_permission = true
	}
	return out, .None
}

// claude_file_edit_event builds file.edit for Edit / MultiEdit / Write.
@(private = "file")
claude_file_edit_event :: proc(root: json.Object, ts: string) -> (string, bool) {
	tool := json_get_string(root, "tool_name")
	if tool != "Edit" && tool != "MultiEdit" && tool != "Write" do return "", false
	input := json_get_object(root, "tool_input")
	resp := json_get_object(root, "tool_response")
	path := json_get_string(input, "file_path")
	if path == "" do path = json_get_string(resp, "filePath")
	if path == "" do return "", false
	cwd := json_get_string(root, "cwd")

	operation := "edit"
	if tool == "MultiEdit" do operation = "multi_edit"
	original := json_get_string(resp, "originalFile")
	has_original := false
	if resp != nil {
		_, has_original = resp["originalFile"].(json.String)
	}
	if tool == "Write" {
		t := json_get_string(resp, "type")
		operation = "create" if t == "create" || (t == "" && !has_original) else "update"
	}

	res: Diff_Result
	source := ""
	hunks := claude_structured_patch(json_get_array(resp, "structuredPatch"))
	switch {
	case len(hunks) > 0:
		res = diff_structured(path, cwd, hunks)
		source = "structured_patch"
	case operation == "create":
		content := json_get_string(input, "content")
		if content == "" do content = json_get_string(resp, "content")
		res = diff_create(path, cwd, content)
		source = "content"
	case tool == "Write":
		content := json_get_string(input, "content")
		if content == "" do content = json_get_string(resp, "content")
		res = diff_replace_whole(path, cwd, original, content)
		source = "original_file"
	case:
		edits := make([dynamic]Diff_String_Edit)
		if tool == "MultiEdit" {
			for e in json_get_array(input, "edits") {
				if eo, ok := e.(json.Object); ok {
					append(&edits, Diff_String_Edit{json_get_string(eo, "old_string"), json_get_string(eo, "new_string")})
				}
			}
		} else {
			append(&edits, Diff_String_Edit{json_get_string(input, "old_string"), json_get_string(input, "new_string")})
		}
		res = diff_string_edits(path, cwd, original, edits[:])
		source = "strings"
	}

	p := pb_make()
	pb_str(&p, "file_path", path)
	pb_str(&p, "operation", operation)
	pb_str(&p, "diff", res.diff)
	pb_str(&p, "diff_source", source)
	pb_int(&p, "additions", res.additions)
	pb_int(&p, "deletions", res.deletions)
	if res.truncated do pb_bool(&p, "diff_truncated", true)
	if res.binary do pb_bool(&p, "binary", true)
	if json_get_bool(resp, "userModified") do pb_bool(&p, "user_modified", true)
	eb := claude_event_begin("file.edit", ts, root)
	claude_event_tool(&eb, root, nil, nil)
	return claude_event_end(&eb, pb_done(&p)), true
}

// claude_structured_patch converts tool_response.structuredPatch to hunks.
claude_structured_patch :: proc(arr: json.Array) -> []Diff_Hunk {
	if len(arr) == 0 do return nil
	hunks := make([dynamic]Diff_Hunk)
	for item in arr {
		obj, ok := item.(json.Object)
		if !ok do continue
		h: Diff_Hunk
		h.old_start, _ = json_get_int(obj, "oldStart")
		h.old_lines, _ = json_get_int(obj, "oldLines")
		h.new_start, _ = json_get_int(obj, "newStart")
		h.new_lines, _ = json_get_int(obj, "newLines")
		lines := make([dynamic]string)
		for l in json_get_array(obj, "lines") {
			if s, is := l.(json.String); is do append(&lines, string(s))
		}
		h.lines = lines[:]
		append(&hunks, h)
	}
	return hunks[:]
}

// claude_event_params is the agent.extension.event params body for events:
// the single event itself, or {"events":[...]} for several.
claude_event_params :: proc(events: []string) -> string {
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

CLAUDE_DENY_DEFAULT_MESSAGE :: "Denied in Heimdall"

// claude_permission_output renders Claude's PermissionRequest hook decision.
// "none" (or anything else) yields "" — print nothing so the TUI prompt stays.
claude_permission_output :: proc(decision, message: string) -> string {
	b := strings.builder_make()
	switch decision {
	case "allow":
		strings.write_string(&b, `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`)
	case "deny":
		msg := message if strings.trim_space(message) != "" else CLAUDE_DENY_DEFAULT_MESSAGE
		strings.write_string(&b, `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":`)
		json_write_string(&b, msg)
		strings.write_string(&b, `}}}`)
	case:
		return ""
	}
	return strings.to_string(b)
}

// claude_permission_output_from_response reads an agent.extension.permission
// bridge response ({ok, data:{decision, message}}) and renders the hook output.
// Errors, unreachable bridges and "none" all yield "".
claude_permission_output_from_response :: proc(response: string) -> string {
	value, err := json.parse_string(strings.trim_space(response), json.DEFAULT_SPECIFICATION, true)
	if err != .None do return ""
	root, ok := value.(json.Object)
	if !ok || !json_get_bool(root, "ok") do return ""
	data := json_get_object(root, "data")
	// Tolerate one extra {data:{data:…}} envelope level.
	if inner := json_get_object(data, "data"); inner != nil && !json_has(data, "decision") do data = inner
	return claude_permission_output(json_get_string(data, "decision"), json_get_string(data, "message"))
}
