package main

// agent.extension.permission (REQ-EXT-PERM-1).
//
// A harness extension's blocking permission hook calls this bridge-local RPC with
// one ham.ext.v1 `permission.request` event. The bridge:
//   1. registers the request in the permission relay's pending registry
//      (permission_relay.odin) under a fresh bridge-generated request_id;
//   2. marks the instance waiting_user (source "<provider>_extension", rank 80,
//      so the screen-scraper cannot hide it);
//   3. forwards it to the hub (POST /api/v1/agent-actions/permission-requests),
//      which stores it and shows it to the user;
//   4. BLOCKS until the hub pushes a `permission_decision` frame (allow|deny),
//      the instance stops, or the timeout passes.
//
// Reply: {request_id, decision: allow|deny|none, message}. "none" means NO
// decision (timeout, cancellation, hub unreachable): the provider then falls back
// to its own TUI prompt. Silence is never turned into a deny on this path.
//
// IDENTITY: the instance is always the token-verified rec.agent_instance_id.

import "core:encoding/json"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"

BRIDGE_EXT_PERMISSION_DEFAULT_TIMEOUT_MS :: 300_000
// HEIMDALL_EXT_PERMISSION_TIMEOUT_MS overrides the default wait (ms) bridge-wide;
// a request's own timeout_ms wins over both. Clamped by the relay's min/max.
BRIDGE_EXT_PERMISSION_TIMEOUT_ENV :: "HEIMDALL_EXT_PERMISSION_TIMEOUT_MS"
BRIDGE_EXT_PERMISSION_HUB_PATH :: "/api/v1/agent-actions/permission-requests"
BRIDGE_EXT_PERMISSION_CLOSE_PATH :: "/api/v1/agent-actions/permission-requests/close"
BRIDGE_EXT_PERMISSION_RELAY_TIMEOUT_MS :: 10_000

// Bridge_Ext_Permission_Forward_Proc posts params to a hub agent-actions path for
// rec and reports whether the hub accepted it (2xx). A seam for tests.
Bridge_Ext_Permission_Forward_Proc :: proc(rec: Bridge_Local_Agent_Token_Record, path, params: string) -> bool

bridge_ext_permission_forward: Bridge_Ext_Permission_Forward_Proc = bridge_ext_permission_forward_hub

bridge_ext_permission_forward_hub :: proc(rec: Bridge_Local_Agent_Token_Record, path, params: string) -> bool {
	if strings.trim_space(rec.instance_token) == "" do return false
	relay := bridge_local_relay_agent_envelope(path, "agent.extension.permission", params, rec, BRIDGE_EXT_PERMISSION_RELAY_TIMEOUT_MS)
	return relay.ok && relay.status >= 200 && relay.status < 300
}

Bridge_Ext_Permission_Request :: struct {
	provider:    string,
	agent_id:    string,
	tool_name:   string,
	tool_use_id: string,
	input:       string, // JSON object
	suggestions: string, // JSON array
	timeout_ms:  int, // 0 = default
}

Bridge_Ext_Permission_Outcome :: struct {
	request_id: string,
	decision:   string, // allow | deny | none
	message:    string,
}

// bridge_ext_permission_default_timeout_ms reads the bridge-wide default.
bridge_ext_permission_default_timeout_ms :: proc() -> int {
	raw := os.get_env(BRIDGE_EXT_PERMISSION_TIMEOUT_ENV, context.temp_allocator)
	if v, ok := strconv.parse_int(strings.trim_space(raw)); ok && v > 0 do return v
	return BRIDGE_EXT_PERMISSION_DEFAULT_TIMEOUT_MS
}

bridge_ext_permission_new_request_id :: proc() -> string {
	return fmt.aprintf("perm_%016x%08x", rand.uint64(), u32(rand.uint32()))
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

// bridge_ext_permission_hub_params is the body the hub's ingest route reads.
bridge_ext_permission_hub_params :: proc(request_id: string, req: Bridge_Ext_Permission_Request, timeout_ms: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{\"request_id\":\""); bridge_local_write_json_string(&b, request_id)
	strings.write_string(&b, fmt.tprintf("\",\"timeout_ms\":%d,\"provider\":\"", timeout_ms)); bridge_local_write_json_string(&b, req.provider)
	strings.write_string(&b, "\",\"agent_id\":\""); bridge_local_write_json_string(&b, req.agent_id)
	strings.write_string(&b, "\",\"tool_name\":\""); bridge_local_write_json_string(&b, req.tool_name)
	strings.write_string(&b, "\",\"tool_use_id\":\""); bridge_local_write_json_string(&b, req.tool_use_id)
	strings.write_string(&b, "\",\"input\":"); strings.write_string(&b, req.input)
	strings.write_string(&b, ",\"permission_suggestions\":"); strings.write_string(&b, req.suggestions)
	strings.write_byte(&b, '}')
	return strings.to_string(b)
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
	instance_id := rec.agent_instance_id
	timeout_ms := req.timeout_ms
	if timeout_ms <= 0 do timeout_ms = bridge_ext_permission_default_timeout_ms()
	timeout_ms = bridge_permission_clamp_timeout(timeout_ms)
	request_id := bridge_ext_permission_new_request_id()
	out := Bridge_Ext_Permission_Outcome{request_id = request_id, decision = "none"}

	now := bridge_runtime_now_ms()
	pending := Bridge_Permission_Pending{
		request_id = strings.clone(request_id),
		agent_instance_id = strings.clone(instance_id),
		tool = strings.clone(req.tool_name),
		risk = strings.clone("extension"),
		created_unix_ms = now,
		deadline_unix_ms = now + i64(timeout_ms),
	}
	// Registered BEFORE the hub hears of it, so an instant decision push cannot
	// arrive ahead of its pending entry.
	if !bridge_permission_register(pending) {
		out.message = "permission request_id already in flight"
		return out
	}
	source := bridge_ext_activity_source(req.provider)
	bridge_runtime_note_agent_activity(instance_id, "waiting_user", source)

	if !bridge_ext_permission_forward(rec, BRIDGE_EXT_PERMISSION_HUB_PATH, bridge_ext_permission_hub_params(request_id, req, timeout_ms)) {
		// Nobody can answer from the UI: let the provider prompt in its TUI now
		// rather than after a pointless wait. The agent stays waiting_user.
		bridge_permission_remove(instance_id, request_id)
		out.message = "hub unavailable; answer in the terminal"
		return out
	}

	decision, reason, timed_out := bridge_permission_wait_ex(instance_id, request_id, timeout_ms, "none", bridge_ext_permission_instance_gone)
	out.decision = decision if decision == "allow" || decision == "deny" else "none"
	out.message = reason
	if out.decision == "none" {
		// Close the hub row so the UI stops offering a decision nobody waits for.
		close_reason := "timeout" if timed_out else "cancelled"
		close_params := fmt.tprintf("{{\"request_id\":\"%s\",\"reason\":\"%s\"}}", request_id, close_reason)
		_ = bridge_ext_permission_forward(rec, BRIDGE_EXT_PERMISSION_CLOSE_PATH, close_params)
		// The provider now shows its own prompt: the agent is still waiting_user.
	} else {
		bridge_runtime_note_agent_activity(instance_id, "active", source)
	}
	return out
}

bridge_ext_permission_outcome_json :: proc(out: Bridge_Ext_Permission_Outcome) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"request_id\":\""); bridge_local_write_json_string(&b, out.request_id)
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

// bridge_ext_permission_handle_decision_frame applies the hub's
// permission_decision frame: {agent_instance_id, request_id, decision, message}.
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
