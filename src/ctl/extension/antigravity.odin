package extension

// Antigravity adapter (REQ-EXT-AGY-2): native hook JSON on stdin → ham.ext.v1.
//
//   PreInvocation   (inv_num <= 1) → hello (capabilities) + session {phase:start} + activity {state:active}
//   PreInvocation   (inv_num > 1)  → activity {state:active}
//   PostInvocation                 → no events (empty stdout)
//   PreToolUse      (normal)       → tool.start
//   PreToolUse      (permission)   → permission.request (sent with agent.extension.permission)
//   PostToolUse                    → tool.end
//   Stop                           → activity {state:idle} + session {phase:end}

import json "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"

ANTIGRAVITY_PROVIDER :: "antigravity"
ANTIGRAVITY_EXT_VERSION :: "0.1.0"
ANTIGRAVITY_HOOK_INPUT_MAX :: 16 * 1024 * 1024
ANTIGRAVITY_TOOL_STRING_MAX :: 4 * 1024
ANTIGRAVITY_MESSAGE_MAX :: 2 * 1024
ANTIGRAVITY_CAPABILITIES :: [?]string{"activity", "subagents", "permissions", "file_edits", "session_id"}
ANTIGRAVITY_DENY_DEFAULT_MESSAGE :: "Denied in Heimdall"

Antigravity_Hook :: enum {
	Unknown,
	Pre_Invocation,
	Post_Invocation,
	Pre_Tool_Use,
	Post_Tool_Use,
	Stop,
	Permission_Request,
}

Antigravity_Error :: enum {
	None,
	Too_Large,
	Malformed_Json,
}

Antigravity_Mapped :: struct {
	hook:          Antigravity_Hook,
	events:        [dynamic]string,
	is_permission: bool,
}

antigravity_hook_from_name :: proc(name: string) -> Antigravity_Hook {
	switch name {
	case "PreInvocation", "pre_invocation", "preInvocation":
		return .Pre_Invocation
	case "PostInvocation", "post_invocation", "postInvocation":
		return .Post_Invocation
	case "PreToolUse", "pre_tool_use", "preToolUse":
		return .Pre_Tool_Use
	case "PostToolUse", "post_tool_use", "postToolUse":
		return .Post_Tool_Use
	case "Stop", "stop":
		return .Stop
	case "PermissionRequest", "permission_request", "permissionRequest":
		return .Permission_Request
	}
	return .Unknown
}

antigravity_is_destructive :: proc(tool_name: string) -> bool {
	switch tool_name {
	case "run_command", "write_to_file", "replace_file_content", "runCommand", "writeToFile", "replaceFileContent":
		return true
	}
	return false
}

Antigravity_Subagent_Target :: struct {
	role:  string,
	type:  string,
	model: string,
}

antigravity_extract_subagents :: proc(args_val: json.Value) -> []Antigravity_Subagent_Target {
	if args_val == nil do return nil
	out := make([dynamic]Antigravity_Subagent_Target)
	#partial switch v in args_val {
	case json.Object:
		sub_arr := json_get_array(v, "Subagents")
		if sub_arr == nil do sub_arr = json_get_array(v, "subagents")
		if sub_arr != nil {
			for item in sub_arr {
				if item_obj, ok := item.(json.Object); ok {
					role := json_get_string(item_obj, "Role")
					if role == "" do role = json_get_string(item_obj, "role")
					type_name := json_get_string(item_obj, "TypeName")
					if type_name == "" do type_name = json_get_string(item_obj, "typeName")
					if type_name == "" do type_name = json_get_string(item_obj, "type_name")
					if type_name == "" do type_name = json_get_string(item_obj, "type")
					model := json_get_string(item_obj, "Model")
					if model == "" do model = json_get_string(item_obj, "model")
					append(&out, Antigravity_Subagent_Target{role = role, type = type_name, model = model})
				}
			}
		} else {
			role := json_get_string(v, "Role")
			if role == "" do role = json_get_string(v, "role")
			type_name := json_get_string(v, "TypeName")
			if type_name == "" do type_name = json_get_string(v, "typeName")
			if type_name == "" do type_name = json_get_string(v, "type_name")
			if type_name == "" do type_name = json_get_string(v, "type")
			model := json_get_string(v, "Model")
			if model == "" do model = json_get_string(v, "model")
			if role != "" || type_name != "" || model != "" {
				append(&out, Antigravity_Subagent_Target{role = role, type = type_name, model = model})
			}
		}
	case json.Array:
		for item in v {
			if item_obj, ok := item.(json.Object); ok {
				role := json_get_string(item_obj, "Role")
				if role == "" do role = json_get_string(item_obj, "role")
				type_name := json_get_string(item_obj, "TypeName")
				if type_name == "" do type_name = json_get_string(item_obj, "typeName")
				if type_name == "" do type_name = json_get_string(item_obj, "type_name")
				if type_name == "" do type_name = json_get_string(item_obj, "type")
				model := json_get_string(item_obj, "Model")
				if model == "" do model = json_get_string(item_obj, "model")
				append(&out, Antigravity_Subagent_Target{role = role, type = type_name, model = model})
			}
		}
	}
	return out[:]
}

// antigravity_map_hook maps one Antigravity hook payload to ham.ext.v1 events.
antigravity_map_hook :: proc(raw: string, ts: string, permission_timeout_ms := 0, permission_blocker_id := "") -> (out: Antigravity_Mapped, err: Antigravity_Error) {
	if len(raw) > ANTIGRAVITY_HOOK_INPUT_MAX do return out, .Too_Large
	value, perr := json.parse_string(raw, json.DEFAULT_SPECIFICATION, true)
	if perr != .None do return out, .Malformed_Json
	root, is_obj := value.(json.Object)
	if !is_obj do return out, .Malformed_Json

	// Extract conversationId (camelCase), fallback to conversation_id, session_id
	conv_id := json_get_string(root, "conversationId")
	if conv_id == "" do conv_id = json_get_string(root, "conversation_id")
	if conv_id == "" do conv_id = json_get_string(root, "session_id")
	if conv_id == "" do return out, .Malformed_Json
	root["session_id"] = json.String(conv_id)

	// Extract workspacePaths (camelCase array), fallback to workspace_paths
	cwd := json_get_string(root, "cwd")
	if cwd == "" {
		if ws := json_get_array(root, "workspacePaths"); len(ws) > 0 {
			if s, is_s := ws[0].(json.String); is_s do cwd = string(s)
		} else if ws2 := json_get_array(root, "workspace_paths"); len(ws2) > 0 {
			if s, is_s := ws2[0].(json.String); is_s do cwd = string(s)
		}
	}
	if cwd != "" do root["cwd"] = json.String(cwd)

	// Extract transcriptPath (camelCase), fallback to transcript_path
	transcript_path := json_get_string(root, "transcriptPath")
	if transcript_path == "" do transcript_path = json_get_string(root, "transcript_path")
	if transcript_path != "" do root["transcript_path"] = json.String(transcript_path)

	// Extract modelName (camelCase), fallback to model_name, model
	model := json_get_string(root, "modelName")
	if model == "" do model = json_get_string(root, "model_name")
	if model == "" do model = json_get_string(root, "model")
	if model != "" do root["model"] = json.String(model)

	// Extract stepIdx and invocationNum
	step_idx := 0
	if v, ok := json_get_int(root, "stepIdx"); ok do step_idx = v
	else if v, ok := json_get_int(root, "step_idx"); ok do step_idx = v

	inv_num := 0
	if v, ok := json_get_int(root, "invocationNum"); ok do inv_num = v
	else if v, ok := json_get_int(root, "invocation_num"); ok do inv_num = v

	// Extract agentId and agentType if present
	if aid := json_get_string(root, "agentId"); aid != "" do root["agent_id"] = json.String(aid)
	if atype := json_get_string(root, "agentType"); atype != "" do root["agent_type"] = json.String(atype)

	// Extract hook name
	hook_name := json_get_string(root, "hookEventName")
	if hook_name == "" do hook_name = json_get_string(root, "hook_event_name")
	out.hook = antigravity_hook_from_name(hook_name)

	// Extract tool details if present
	tool_name := ""
	tool_args: json.Value = nil
	tool_call := json_get_object(root, "toolCall")
	if tool_call == nil do tool_call = json_get_object(root, "tool_call")
	if tool_call != nil {
		tool_name = json_get_string(tool_call, "name")
		tool_args = tool_call["args"]
	}
	if tool_name == "" do tool_name = json_get_string(root, "tool_name")
	if tool_name == "" do tool_name = json_get_string(root, "toolName")
	if tool_args == nil do tool_args = root["tool_input"]
	if tool_args == nil do tool_args = root["toolInput"]
	if tool_args == nil do tool_args = root["args"]

	tool_use_id := json_get_string(root, "tool_use_id")
	if tool_use_id == "" do tool_use_id = json_get_string(root, "toolUseId")
	if tool_use_id == "" {
		tool_use_id = fmt.tprintf("step_%d", step_idx)
	}

	if tool_name != "" do root["tool_name"] = json.String(tool_name)
	if tool_use_id != "" do root["tool_use_id"] = json.String(tool_use_id)

	switch out.hook {
	case .Unknown:
		// Unknown hook maps to no events

	case .Pre_Invocation:
		if inv_num <= 1 {
			// First invocation: emit hello and session (phase: start)
			caps := ANTIGRAVITY_CAPABILITIES
			h := pb_make()
			pb_key(&h, "capabilities")
			strings.write_byte(&h.b, '[')
			for c, i in caps {
				if i > 0 do strings.write_byte(&h.b, ',')
				json_write_string(&h.b, c)
			}
			strings.write_byte(&h.b, ']')
			pb_str_nonempty(&h, "source", json_get_string(root, "source"))
			eb := ext_event_begin("hello", ts, root, ANTIGRAVITY_PROVIDER, ANTIGRAVITY_EXT_VERSION)
			append(&out.events, ext_event_end(&eb, pb_done(&h)))

			s := pb_make()
			pb_str(&s, "phase", "start")
			pb_str_nonempty(&s, "source", json_get_string(root, "source"))
			pb_str_nonempty(&s, "cwd", cwd)
			pb_str_nonempty(&s, "model", model)
			pb_str_nonempty(&s, "transcript_path", transcript_path)
			eb2 := ext_event_begin("session", ts, root, ANTIGRAVITY_PROVIDER, ANTIGRAVITY_EXT_VERSION)
			append(&out.events, ext_event_end(&eb2, pb_done(&s)))
		}

		// Emit activity (state: active, reason: user_prompt)
		a := pb_make()
		pb_str(&a, "state", "active")
		pb_str(&a, "reason", "user_prompt")
		if inv_num > 0 do pb_int(&a, "invocation_num", inv_num)
		if step_idx > 0 do pb_int(&a, "step_idx", step_idx)
		eb3 := ext_event_begin("activity", ts, root, ANTIGRAVITY_PROVIDER, ANTIGRAVITY_EXT_VERSION)
		append(&out.events, ext_event_end(&eb3, pb_done(&a)))

	case .Post_Invocation:
		// Hook stdout is empty, no events emitted

	case .Pre_Tool_Use:
		perm_mode := json_get_string(root, "permissionMode")
		if perm_mode == "" do perm_mode = json_get_string(root, "permission_mode")
		is_destructive := antigravity_is_destructive(tool_name)
		if perm_mode == "ask" && is_destructive {
			out.is_permission = true
			input := json_clip(tool_args, ANTIGRAVITY_TOOL_STRING_MAX)
			if input == nil do input = json.Object{}
			p := pb_make()
			pb_str(&p, "permission_mode", "ask")
			timeout := permission_timeout_ms
			if timeout <= 0 do timeout = PERMISSION_RELAY_TIMEOUT_MS
			else do timeout = min(timeout, PERMISSION_RELAY_TIMEOUT_MS)
			pb_int(&p, "timeout_ms", timeout)
			blocker_id := permission_blocker_id
			if blocker_id == "" do blocker_id = new_blocker_id()
			pb_str(&p, "blocker_id", blocker_id)
			eb := ext_event_begin("permission.request", ts, root, ANTIGRAVITY_PROVIDER, ANTIGRAVITY_EXT_VERSION)
			ext_event_tool(&eb, root, input, nil)
			append(&out.events, ext_event_end(&eb, pb_done(&p)))
		} else {
			input := json_clip(tool_args, ANTIGRAVITY_TOOL_STRING_MAX)
			p := pb_make()
			pb_str_nonempty(&p, "permission_mode", perm_mode)
			if step_idx > 0 do pb_int(&p, "step_idx", step_idx)
			eb := ext_event_begin("tool.start", ts, root, ANTIGRAVITY_PROVIDER, ANTIGRAVITY_EXT_VERSION)
			ext_event_tool(&eb, root, input, nil)
			append(&out.events, ext_event_end(&eb, pb_done(&p)))

			if tool_name == "invoke_subagent" || tool_name == "invokeSubagent" || tool_name == "InvokeSubagent" {
				subagents := antigravity_extract_subagents(tool_args)
				for sub in subagents {
					sub_p := pb_make()
					pb_str_nonempty(&sub_p, "role", sub.role)
					pb_str_nonempty(&sub_p, "target_role", sub.role)
					pb_str_nonempty(&sub_p, "type", sub.type)
					pb_str_nonempty(&sub_p, "target_type", sub.type)
					pb_str_nonempty(&sub_p, "model", sub.model)
					pb_str_nonempty(&sub_p, "target_model", sub.model)
					pb_str_nonempty(&sub_p, "description", sub.role)
					sub_eb := ext_event_begin("subagent.start", ts, root, ANTIGRAVITY_PROVIDER, ANTIGRAVITY_EXT_VERSION)
					append(&out.events, ext_event_end(&sub_eb, pb_done(&sub_p)))
				}
			}
		}

	case .Permission_Request:
		out.is_permission = true
		input := json_clip(tool_args, ANTIGRAVITY_TOOL_STRING_MAX)
		if input == nil do input = json.Object{}
		p := pb_make()
		perm_mode := json_get_string(root, "permissionMode")
		if perm_mode == "" do perm_mode = json_get_string(root, "permission_mode")
		if perm_mode == "" do perm_mode = "ask"
		pb_str(&p, "permission_mode", perm_mode)
		timeout := permission_timeout_ms
		if timeout <= 0 do timeout = PERMISSION_RELAY_TIMEOUT_MS
		else do timeout = min(timeout, PERMISSION_RELAY_TIMEOUT_MS)
		pb_int(&p, "timeout_ms", timeout)
		blocker_id := permission_blocker_id
		if blocker_id == "" do blocker_id = new_blocker_id()
		pb_str(&p, "blocker_id", blocker_id)
		eb := ext_event_begin("permission.request", ts, root, ANTIGRAVITY_PROVIDER, ANTIGRAVITY_EXT_VERSION)
		ext_event_tool(&eb, root, input, nil)
		append(&out.events, ext_event_end(&eb, pb_done(&p)))

	case .Post_Tool_Use:
		tool_resp := root["toolResult"]
		if tool_resp == nil do tool_resp = root["toolResponse"]
		if tool_resp == nil do tool_resp = root["tool_response"]
		if tool_resp == nil do tool_resp = root["tool_result"]

		input := json_clip(tool_args, ANTIGRAVITY_TOOL_STRING_MAX)
		response := json_clip(tool_resp, ANTIGRAVITY_TOOL_STRING_MAX)

		p := pb_make()
		err_str := json_get_string(root, "error")
		if err_str == "" && tool_resp != nil {
			if tro, ok := tool_resp.(json.Object); ok do err_str = json_get_string(tro, "error")
		}

		status_str := ""
		if err_str != "" {
			status_str = "error"
		} else if tool_resp != nil {
			if tro, ok := tool_resp.(json.Object); ok {
				if s := json_get_string(tro, "status"); s != "" {
					if strings.equal_fold(s, "error") || strings.equal_fold(s, "failed") {
						status_str = "error"
					}
				}
			}
		}
		if status_str == "" do status_str = "completed"

		pb_str(&p, "status", status_str)
		if status_str == "error" {
			pb_str_nonempty(&p, "error", clip_string(err_str, ANTIGRAVITY_MESSAGE_MAX))
		} else {
			pb_str(&p, "outcome", "unknown")
		}
		if d, ok := json_get_int(root, "durationMs"); ok do pb_int(&p, "duration_ms", d)
		else if d, ok := json_get_int(root, "duration_ms"); ok do pb_int(&p, "duration_ms", d)
		eb := ext_event_begin("tool.end", ts, root, ANTIGRAVITY_PROVIDER, ANTIGRAVITY_EXT_VERSION)
		ext_event_tool(&eb, root, input, response)
		append(&out.events, ext_event_end(&eb, pb_done(&p)))

		if status_str != "error" {
			if ev, ok := antigravity_file_edit_event(root, ts); ok {
				append(&out.events, ev)
			}
		}

	case .Stop:
		term_reason := json_get_string(root, "terminationReason")
		if term_reason == "" do term_reason = json_get_string(root, "termination_reason")
		if term_reason == "" do term_reason = json_get_string(root, "reason")
		if term_reason == "" do term_reason = "stop"

		// 1. activity: idle
		a := pb_make()
		pb_str(&a, "state", "idle")
		pb_str(&a, "reason", term_reason)
		eb := ext_event_begin("activity", ts, root, ANTIGRAVITY_PROVIDER, ANTIGRAVITY_EXT_VERSION)
		append(&out.events, ext_event_end(&eb, pb_done(&a)))

		// 2. session: end
		s := pb_make()
		pb_str(&s, "phase", "end")
		pb_str(&s, "reason", term_reason)
		eb2 := ext_event_begin("session", ts, root, ANTIGRAVITY_PROVIDER, ANTIGRAVITY_EXT_VERSION)
		append(&out.events, ext_event_end(&eb2, pb_done(&s)))
	}

	// Bound aggregate-shaped inputs, not just individual strings.
	total := 0
	for ev in out.events {
		total += len(ev)
		if len(ev) > contracts.EXT_EVENT_MAX_BYTES || total > contracts.EXT_BATCH_MAX_BYTES - 1024 {
			return Antigravity_Mapped{}, .Too_Large
		}
	}
	return out, .None
}

antigravity_build_permission :: proc(remaining_ms: int, blocker_id: string, raw: string, ts: string) -> (string, bool) {
	mapped, err := antigravity_map_hook(raw, ts, remaining_ms, blocker_id)
	if err != .None || !mapped.is_permission || len(mapped.events) == 0 do return "", false
	return mapped.events[0], true
}

antigravity_permission_output :: proc(decision, reason: string) -> string {
	switch decision {
	case "allow":
		return `{"decision":"allow"}`
	case "deny":
		b := strings.builder_make()
		r := reason if strings.trim_space(reason) != "" else ANTIGRAVITY_DENY_DEFAULT_MESSAGE
		strings.write_string(&b, `{"decision":"deny","reason":`)
		json_write_string(&b, clip_string(r, ANTIGRAVITY_MESSAGE_MAX))
		strings.write_byte(&b, '}')
		return strings.to_string(b)
	case "ask":
		return `{"decision":"ask"}`
	case:
		return `{"decision":"ask"}`
	}
}

antigravity_permission_output_from_response :: proc(response: string) -> string {
	value, err := json.parse_string(strings.trim_space(response), json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if err != .None do return `{"decision":"ask"}`
	root, ok := value.(json.Object)
	if !ok || !json_get_bool(root, "ok") do return `{"decision":"ask"}`
	data := json_get_object(root, "data")
	if inner := json_get_object(data, "data"); inner != nil && !json_has(data, "decision") do data = inner
	dec := json_get_string(data, "decision")
	if dec == "" || dec == "none" do return `{"decision":"ask"}`
	msg := json_get_string(data, "message")
	return antigravity_permission_output(dec, msg)
}

antigravity_permission_is_ham_ctl :: proc(raw, ctl_bin: string) -> bool {
	value, err := json.parse_string(raw, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if err != .None do return false
	root, ok := value.(json.Object)
	if !ok do return false
	tool_name := ""
	tool_call := json_get_object(root, "toolCall")
	if tool_call == nil do tool_call = json_get_object(root, "tool_call")
	if tool_call != nil {
		tool_name = json_get_string(tool_call, "name")
	}
	if tool_name == "" do tool_name = json_get_string(root, "tool_name")
	if tool_name == "" do tool_name = json_get_string(root, "toolName")
	if tool_name != "run_command" && tool_name != "runCommand" do return false

	args: json.Object
	if tool_call != nil {
		args = json_get_object(tool_call, "args")
		if args == nil do args = json_get_object(tool_call, "input")
	}
	if args == nil do args = json_get_object(root, "tool_input")
	if args == nil do args = json_get_object(root, "toolInput")
	if args == nil do args = json_get_object(root, "args")
	if args == nil do return false

	cmd := json_get_string(args, "CommandLine")
	if cmd == "" do cmd = json_get_string(args, "command")
	if cmd == "" do cmd = json_get_string(args, "command_line")

	cwd := json_get_string(args, "Cwd")
	if cwd == "" do cwd = json_get_string(args, "cwd")
	if cwd == "" do cwd = json_get_string(root, "cwd")
	if cwd == "" {
		if ws := json_get_array(root, "workspacePaths"); len(ws) > 0 {
			if s, is_s := ws[0].(json.String); is_s do cwd = string(s)
		} else if ws2 := json_get_array(root, "workspace_paths"); len(ws2) > 0 {
			if s, is_s := ws2[0].(json.String); is_s do cwd = string(s)
		}
	}
	return is_ham_ctl_command(cmd, ctl_bin, cwd)
}
