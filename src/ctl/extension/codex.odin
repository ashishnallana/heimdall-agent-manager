package extension

// Codex 0.162.0 callbacks, captured by extensions/codex/fixtures.
// Native tool/child/session identifiers are preserved; instance identity is
// always supplied by the issued transport token, never by stdin.
// Bash PostToolUse supplies stdout without an exit code. Completion is therefore
// "completed" (unknown outcome), not inferred success. Only confirmed apply_patch
// responses can produce file edits. Hosted tools and notifications are uncovered.

import json "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"

CODEX_PROVIDER :: "codex"
CODEX_EXT_VERSION :: "0.1.0"
// Native view_image PostToolUse includes a base64 image, often several MiB.
// Match the bounded CLI stdin reader; output remains capped independently below.
CODEX_HOOK_INPUT_MAX :: HOOK_INPUT_MAX
CODEX_CAPABILITIES :: [?]string{"activity", "subagents", "permissions", "file_edits", "session_id"}

Codex_Error :: enum { None, Too_Large, Malformed_Json }
Codex_Mapped :: struct {
	events: [dynamic]string,
	is_permission: bool,
}

codex_map_hook :: proc(raw, ts: string, permission_timeout_ms := 0, permission_blocker_id := "") -> (out: Codex_Mapped, err: Codex_Error) {
	if len(raw) > CODEX_HOOK_INPUT_MAX do return out, .Too_Large
	value, parse_err := json.parse_string(raw, json.DEFAULT_SPECIFICATION, true)
	if parse_err != .None do return out, .Malformed_Json
	root, ok := value.(json.Object)
	if !ok || json_get_string(root, "session_id") == "" do return out, .Malformed_Json
	name := json_get_string(root, "hook_event_name")
	event := ""
	p := pb_make()
	pb_str_nonempty(&p, "turn_id", json_get_string(root, "turn_id"))
	tool_input, tool_response: json.Value
	switch name {
	case "SessionStart":
		hello := pb_make()
		pb_key(&hello, "capabilities")
		strings.write_byte(&hello.b, '[')
		for cap, i in CODEX_CAPABILITIES {
			if i > 0 do strings.write_byte(&hello.b, ',')
			json_write_string(&hello.b, cap)
		}
		strings.write_byte(&hello.b, ']')
		pb_str_nonempty(&hello, "source", json_get_string(root, "source"))
		eb := ext_event_begin("hello", ts, root, CODEX_PROVIDER, CODEX_EXT_VERSION)
		append(&out.events, ext_event_end(&eb, pb_done(&hello)))
		event = "session"
		pb_str(&p, "phase", "start")
		pb_str_nonempty(&p, "source", json_get_string(root, "source"))
		pb_str_nonempty(&p, "cwd", json_get_string(root, "cwd"))
		pb_str_nonempty(&p, "model", json_get_string(root, "model"))
	case "SessionEnd":
		event = "session"
		pb_str(&p, "phase", "end")
		pb_str_nonempty(&p, "reason", json_get_string(root, "reason"))
	case "UserPromptSubmit":
		event = "activity"
		pb_str(&p, "state", "active")
		pb_str(&p, "reason", "user_prompt")
	case "Stop", "Interrupt":
		event = "activity"
		pb_str(&p, "state", "idle")
		pb_str(&p, "reason", "interrupt" if name == "Interrupt" else "stop")
		// No background_running:0: a main turn ending does not end its children.
	case "SubagentStart", "SubagentStop":
		if json_get_string(root, "agent_id") == "" do return out, .Malformed_Json
		event = "subagent.start" if name == "SubagentStart" else "subagent.stop"
	case "PreToolUse", "PostToolUse":
		if json_get_string(root, "tool_use_id") == "" || json_get_string(root, "tool_name") == "" do return out, .Malformed_Json
		event = "tool.start" if name == "PreToolUse" else "tool.end"
		// Never forward prompts or encrypted child instructions.
		tool_input = json_clip(root["tool_input"], 4096, {"message", "prompt"})
		if name == "PostToolUse" {
			// Image bytes are not activity metadata. Do not clone, clip, or forward
			// the native data URL; the paired tool identity is sufficient.
			if json_get_string(root, "tool_name") != "view_image" {
				tool_response = json_clip(root["tool_response"], 4096)
			}
			pb_str(&p, "status", "completed")
			pb_str(&p, "outcome", "unknown")
		}
	case "PermissionRequest":
		if json_get_string(root, "tool_name") == "" do return out, .Malformed_Json
		event = "permission.request"
		out.is_permission = true
		tool_input = json_clip(root["tool_input"], 4096, {"message", "prompt"})
		if tool_input == nil do tool_input = json.Object{}
		if permission_timeout_ms > 0 do pb_int(&p, "timeout_ms", permission_timeout_ms)
		pb_str_nonempty(&p, "blocker_id", permission_blocker_id)
		pb_str_nonempty(&p, "permission_mode", json_get_string(root, "permission_mode"))
	case:
		// Compact callbacks do not imply an activity transition.
		return out, .None
	}
	eb := ext_event_begin(event, ts, root, CODEX_PROVIDER, CODEX_EXT_VERSION)
	if name == "PreToolUse" || name == "PostToolUse" || name == "PermissionRequest" {
		// Identity must survive even when no input/response metadata is retained.
		ext_event_tool(&eb, root, tool_input, tool_response)
	}
	append(&out.events, ext_event_end(&eb, pb_done(&p)))
	if name == "PostToolUse" && json_get_string(root, "tool_name") == "apply_patch" {
		for edit in codex_patch_events(root, ts) do append(&out.events, edit)
	}
	// Bound aggregate-shaped inputs, not just individual strings.
	total := 0
	for ev in out.events {
		total += len(ev)
		if len(ev) > contracts.EXT_EVENT_MAX_BYTES || total > contracts.EXT_BATCH_MAX_BYTES - 1024 {
			return Codex_Mapped{}, .Too_Large
		}
	}
	return out, .None
}

codex_build_permission :: proc(remaining_ms: int, blocker_id, raw, ts: string) -> (string, bool) {
	mapped, err := codex_map_hook(raw, ts, remaining_ms, blocker_id)
	if err != .None || !mapped.is_permission || len(mapped.events) != 1 do return "", false
	return mapped.events[0], true
}

// Kept provider-local: future Codex output schema changes cannot affect Claude.
codex_permission_output :: proc(decision, message: string) -> string {
	b := strings.builder_make()
	switch decision {
	case "allow":
		return `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`
	case "deny":
		strings.write_string(&b, `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":`)
		json_write_string(&b, clip_string(message if strings.trim_space(message) != "" else "Denied in Ninjy", 2048))
		strings.write_string(&b, `}}}`)
		return strings.to_string(b)
	}
	return ""
}

codex_permission_output_from_response :: proc(response: string) -> string {
	value, err := json.parse_string(strings.trim_space(response), json.DEFAULT_SPECIFICATION, true)
	if err != .None do return ""
	root, ok := value.(json.Object)
	if !ok || !json_get_bool(root, "ok") do return ""
	data := json_get_object(root, "data")
	if inner := json_get_object(data, "data"); inner != nil && !json_has(data, "decision") do data = inner
	return codex_permission_output(json_get_string(data, "decision"), json_get_string(data, "message"))
}
