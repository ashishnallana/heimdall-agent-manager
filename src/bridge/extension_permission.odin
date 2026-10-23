package main

// agent.extension.permission (REQ-EXT-PERM-1, REQ-EXT-BLK-1..5).
//
// A harness extension's blocking permission hook calls this bridge-local RPC with
// one ham.ext.v1 `permission.request` event carrying a stable blocker_id
// (payload.blocker_id or top-level; generated here when absent). The bridge:
//   1. registers (or, for a known id, refreshes) a `permission` agent blocker in
//      the permission relay's pending registry (extension_blockers.odin), which
//      sends the hub a new agent_blockers snapshot; nothing is persisted;
//   2. marks the instance waiting_user (source "<provider>_extension", rank 80,
//      so the screen-scraper cannot hide it);
//   3. BLOCKS until the hub pushes a `permission_decision` frame (allow|deny),
//      the user answers in the terminal (auto-resolve from later extension
//      events), the extension cancels it, the instance stops, a re-registration
//      of the same id supersedes this call, or the timeout passes.
//
// Reply: {request_id, blocker_id, decision: allow|deny|none, message}. "none" means
// NO decision: the provider then shows (or keeps) its own TUI prompt. Silence is
// never turned into a deny on this path.
//
// agent.extension.permission.cancel {blocker_id} releases one of the caller's
// blockers with "none" (for extensions that know the prompt was answered).
//
// IDENTITY: the instance is always the token-verified rec.agent_instance_id.

import "core:encoding/json"
import "core:os"
import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"

BRIDGE_EXT_PERMISSION_DEFAULT_TIMEOUT_MS :: 300_000
// HEIMDALL_EXT_PERMISSION_TIMEOUT_MS overrides the default wait (ms) bridge-wide;
// a request's own timeout_ms wins over both. Clamped by the relay's min/max.
BRIDGE_EXT_PERMISSION_TIMEOUT_ENV :: "HEIMDALL_EXT_PERMISSION_TIMEOUT_MS"
Bridge_Ext_Permission_Request :: struct {
	provider:    string,
	agent_id:    string,
	tool_name:   string,
	tool_use_id: string,
	input:       string, // JSON object
	suggestions: string, // JSON array
	timeout_ms:  int, // 0 = default
	blocker_id:  string, // "" = generate one
}

Bridge_Ext_Permission_Outcome :: struct {
	request_id: string, // = the blocker_id

	decision:   string, // allow | deny | none
	message:    string,
}

// bridge_ext_permission_default_timeout_ms reads the bridge-wide default.
bridge_ext_permission_default_timeout_ms :: proc() -> int {
	raw := os.get_env(BRIDGE_EXT_PERMISSION_TIMEOUT_ENV, context.temp_allocator)
	if v, ok := strconv.parse_int(strings.trim_space(raw)); ok && v > 0 do return v
	return BRIDGE_EXT_PERMISSION_DEFAULT_TIMEOUT_MS
}

// bridge_ext_permission_parse validates a ham.ext.v1 permission.request event and
// pulls out what the hub stores. Strings are temp-allocated.
bridge_ext_permission_parse :: proc(params: string) -> (req: Bridge_Ext_Permission_Request, err_msg: string, ok: bool) {
	ev, perr := contracts.ext_parse_event(params)
	if perr != .None do return {}, contracts.ext_error_message(perr), false
	defer contracts.ext_event_destroy(&ev)
	if ev.kind != .Permission_Request do return {}, "event must be permission.request", false
	if strings.trim_space(ev.tool_name) == "" do return {}, "tool.name is required", false
	req.provider = strings.clone(ev.provider, context.temp_allocator)
	req.agent_id = strings.clone(ev.agent_id, context.temp_allocator)
	req.tool_name = strings.clone(ev.tool_name, context.temp_allocator)
	req.tool_use_id = strings.clone(ev.tool_use_id, context.temp_allocator)
	req.input = "{}"
	req.suggestions = "[]"

	value, jerr := json.parse_string(params, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if jerr != .None do return req, "", true
	root, _ := value.(json.Object)
	payload, _ := root["payload"].(json.Object)
	if tool, is_tool := root["tool"].(json.Object); is_tool {
		if input, is_obj := tool["input"].(json.Object); is_obj {
			if bytes, merr := json.marshal(input, allocator = context.temp_allocator); merr == nil do req.input = string(bytes)
		}
	}
	// permission_suggestions: payload first, then the event top level.
	sugg, has_sugg := payload["permission_suggestions"]
	if !has_sugg do sugg, has_sugg = root["permission_suggestions"]
	if arr, is_arr := sugg.(json.Array); has_sugg && is_arr {
		if bytes, merr := json.marshal(arr, allocator = context.temp_allocator); merr == nil do req.suggestions = string(bytes)
	}
	blocker, has_blocker := payload["blocker_id"]
	if !has_blocker do blocker, has_blocker = root["blocker_id"]
	if id, is_str := blocker.(json.String); has_blocker && is_str {
		if !bridge_blocker_valid_id(id) do return req, "blocker_id must be 1-64 chars of [A-Za-z0-9_-]", false
		req.blocker_id = strings.clone(id, context.temp_allocator)
	}
	timeout, has_timeout := root["timeout_ms"]
	if !has_timeout do timeout, has_timeout = payload["timeout_ms"]
	if has_timeout {
		#partial switch t in timeout {
		case json.Integer: req.timeout_ms = int(t)
		case json.Float: req.timeout_ms = int(t)
		}
	}
	return req, "", true
}

// bridge_ext_permission_instance_gone is the relay's cancellation probe: a
// stopped or failed instance can no longer act on a decision.
bridge_ext_permission_instance_gone :: proc(agent_instance_id: string) -> bool {
	inst, ok := bridge_runtime_instance_snapshot(agent_instance_id)
	if !ok do return false
	return inst.runtime_status == "stopped" || inst.runtime_status == "failed" || inst.runtime_status == "stopping"
}

// bridge_ext_permission_run is the blocking core of agent.extension.permission.
bridge_ext_permission_run :: proc(rec: Bridge_Local_Agent_Token_Record, req: Bridge_Ext_Permission_Request) -> Bridge_Ext_Permission_Outcome {
	context.allocator = bridge_blockers_allocator()
	instance_id := rec.agent_instance_id
	timeout_ms := req.timeout_ms
	if timeout_ms <= 0 do timeout_ms = bridge_ext_permission_default_timeout_ms()
	timeout_ms = bridge_permission_clamp_timeout(timeout_ms)
	blocker_id := strings.clone(req.blocker_id) if req.blocker_id != "" else bridge_blocker_new_id()
	out := Bridge_Ext_Permission_Outcome{request_id = blocker_id, decision = "none"}

	now := bridge_runtime_now_ms()
	input := bridge_blocker_cap_input(req.input)
	generation, _ := bridge_blockers_register_permission(Bridge_Permission_Pending{
		request_id = blocker_id,
		agent_instance_id = strings.clone(instance_id),
		tool = strings.clone(req.tool_name),
		risk = "extension",
		provider = strings.clone(req.provider),
		agent_id = strings.clone(req.agent_id),
		summary = bridge_blocker_summary(req.tool_name, req.input),
		input = strings.clone(input),
		created_unix_ms = now,
		deadline_unix_ms = now + i64(timeout_ms),
	})
	source := bridge_ext_activity_source(req.provider)
	bridge_runtime_note_agent_activity(instance_id, "waiting_user", source)

	decision, reason, _ := bridge_permission_wait_ex(instance_id, blocker_id, timeout_ms, "none", bridge_ext_permission_instance_gone, generation)
	out.decision = decision if decision == "allow" || decision == "deny" else "none"
	out.message = reason
	// On "none" the provider shows (or already showed) its own prompt, so the
	// agent stays waiting_user until its next event says otherwise.
	if out.decision != "none" do bridge_runtime_note_agent_activity(instance_id, "active", source)
	return out
}

bridge_ext_permission_outcome_json :: proc(out: Bridge_Ext_Permission_Outcome) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"request_id\":\""); bridge_local_write_json_string(&b, out.request_id)
	strings.write_string(&b, "\",\"blocker_id\":\""); bridge_local_write_json_string(&b, out.request_id)
	strings.write_string(&b, "\",\"decision\":\""); bridge_local_write_json_string(&b, out.decision)
	strings.write_string(&b, "\",\"message\":\""); bridge_local_write_json_string(&b, out.message)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

// bridge_ext_permission_handle_rpc fulfils agent.extension.permission.
bridge_ext_permission_handle_rpc :: proc(request_id, params: string, rec: Bridge_Local_Agent_Token_Record) -> string {
	req, err_msg, ok := bridge_ext_permission_parse(params)
	if !ok do return bridge_local_response_error(request_id, "bad_request", err_msg)
	out := bridge_ext_permission_run(rec, req)
	return bridge_local_response_data(request_id, bridge_ext_permission_outcome_json(out))
}

// bridge_ext_permission_cancel_rpc fulfils agent.extension.permission.cancel
// {blocker_id}: the caller's own blockers only.
bridge_ext_permission_cancel_rpc :: proc(request_id, params: string, rec: Bridge_Local_Agent_Token_Record) -> string {
	blocker_id := bridge_local_extract_json_string(params, "blocker_id", "", context.temp_allocator)
	if !bridge_blocker_valid_id(blocker_id) do return bridge_local_response_error(request_id, "bad_request", "blocker_id is required")
	found := bridge_blockers_cancel(rec.agent_instance_id, blocker_id)
	return bridge_local_response_data(request_id, "{\"cancelled\":true}" if found else "{\"cancelled\":false}")
}

// bridge_ext_permission_handle_decision_frame applies the hub's
// permission_decision frame: {agent_instance_id, request_id (= blocker_id),
// decision, message}.
// Only allow/deny resolve a waiter; anything else is ignored.
bridge_ext_permission_handle_decision_frame :: proc(text: string) -> bool {
	// Runs on the hub reader thread: keep every parse in the temp arena.
	instance_id := bridge_local_extract_json_string(text, "agent_instance_id", "", context.temp_allocator)
	request_id := bridge_local_extract_json_string(text, "request_id", "", context.temp_allocator)
	decision := strings.to_lower(strings.trim_space(bridge_local_extract_json_string(text, "decision", "", context.temp_allocator)), context.temp_allocator)
	message := bridge_local_extract_json_string(text, "message", "", context.temp_allocator)
	if instance_id == "" || request_id == "" do return false
	if decision != "allow" && decision != "deny" do return false
	return bridge_permission_resolve(instance_id, request_id, decision, message)
}
