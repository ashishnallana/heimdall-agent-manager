package extension

import json "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

@(private = "file", thread_local)
agy_fake_calls: int
@(private = "file", thread_local)
agy_fake_method: string
@(private = "file", thread_local)
agy_fake_params: string
@(private = "file", thread_local)
agy_fake_timeout_ms: int
@(private = "file", thread_local)
agy_fake_response: string
@(private = "file", thread_local)
agy_fake_ok: bool

@(private = "file")
agy_fake_send :: proc(endpoint, token, method, params: string, timeout_ms: int) -> (string, bool) {
	agy_fake_calls += 1
	agy_fake_method = method
	agy_fake_params = params
	agy_fake_timeout_ms = timeout_ms
	return agy_fake_response, agy_fake_ok
}

@(private = "file")
agy_fake_reset :: proc(response: string, ok: bool) {
	agy_fake_calls = 0
	agy_fake_method = ""
	agy_fake_params = ""
	agy_fake_timeout_ms = 0
	agy_fake_response = response
	agy_fake_ok = ok
}

@(test)
test_antigravity_pre_invocation_maps_hello_session_and_activity :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	raw := #load("testdata/antigravity/pre_invocation.json", string)
	mapped, err := antigravity_map_hook(raw, TS)
	testing.expect_value(t, err, Antigravity_Error.None)
	testing.expect_value(t, mapped.hook, Antigravity_Hook.Pre_Invocation)
	testing.expect_value(t, mapped.is_permission, false)
	testing.expect_value(t, len(mapped.events), 3)
	if len(mapped.events) != 3 do return

	// Event 0: hello
	ev0, err0 := contracts.ext_parse_event(mapped.events[0])
	testing.expect_value(t, err0, contracts.Ext_Error.None)
	testing.expect_value(t, ev0.kind, contracts.Ext_Event_Kind.Hello)
	testing.expect_value(t, ev0.provider, "antigravity")
	testing.expect_value(t, ev0.session_id, "2f93a09c-a72a-41a2-be58-b906858e9794")
	testing.expect_value(t, len(ev0.capabilities), 5)

	// Event 1: session (start)
	ev1, err1 := contracts.ext_parse_event(mapped.events[1])
	testing.expect_value(t, err1, contracts.Ext_Error.None)
	testing.expect_value(t, ev1.kind, contracts.Ext_Event_Kind.Session)
	testing.expect_value(t, ev1.session_phase, "start")
	testing.expect_value(t, ev1.transcript_path, "/home/tanmay/.gemini/antigravity-cli/brain/2f93a09c-a72a-41a2-be58-b906858e9794/.system_generated/logs/transcript.jsonl")

	v1, _ := json.parse_string(mapped.events[1], json.DEFAULT_SPECIFICATION, true)
	o1, _ := v1.(json.Object)
	p1 := json_get_object(o1, "payload")
	testing.expect_value(t, json_get_string(p1, "cwd"), "/home/tanmay/heimdall-agent-manager")
	testing.expect_value(t, json_get_string(p1, "model"), "gemini-3.8-flash-high")

	// Event 2: activity (active)
	ev2, err2 := contracts.ext_parse_event(mapped.events[2])
	testing.expect_value(t, err2, contracts.Ext_Error.None)
	testing.expect_value(t, ev2.kind, contracts.Ext_Event_Kind.Activity)
	testing.expect_value(t, ev2.activity_state, "active")

	v2, _ := json.parse_string(mapped.events[2], json.DEFAULT_SPECIFICATION, true)
	o2, _ := v2.(json.Object)
	p2 := json_get_object(o2, "payload")
	testing.expect_value(t, json_get_string(p2, "reason"), "user_prompt")
}

@(test)
test_antigravity_subsequent_pre_invocation_only_emits_activity :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	raw := `{"hookEventName":"PreInvocation","conversationId":"s1","stepIdx":5,"invocationNum":2}`
	mapped, err := antigravity_map_hook(raw, TS)
	testing.expect_value(t, err, Antigravity_Error.None)
	testing.expect_value(t, len(mapped.events), 1)
	if len(mapped.events) != 1 do return

	ev, e := contracts.ext_parse_event(mapped.events[0])
	testing.expect_value(t, e, contracts.Ext_Error.None)
	testing.expect_value(t, ev.kind, contracts.Ext_Event_Kind.Activity)
	testing.expect_value(t, ev.activity_state, "active")
}

@(test)
test_antigravity_pre_tool_use_maps_tool_start :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	raw := #load("testdata/antigravity/pre_tool_use.json", string)
	mapped, err := antigravity_map_hook(raw, TS)
	testing.expect_value(t, err, Antigravity_Error.None)
	testing.expect_value(t, mapped.is_permission, false)
	testing.expect_value(t, len(mapped.events), 1)
	if len(mapped.events) != 1 do return

	ev, e := contracts.ext_parse_event(mapped.events[0])
	testing.expect_value(t, e, contracts.Ext_Error.None)
	testing.expect_value(t, ev.kind, contracts.Ext_Event_Kind.Tool_Start)
	testing.expect_value(t, ev.tool_name, "view_file")
	testing.expect_value(t, ev.tool_use_id, "step_2")

	v, _ := json.parse_string(mapped.events[0], json.DEFAULT_SPECIFICATION, true)
	o, _ := v.(json.Object)
	tool := json_get_object(o, "tool")
	input := json_get_object(tool, "input")
	testing.expect_value(t, json_get_string(input, "AbsolutePath"), "/home/tanmay/heimdall-agent-manager/README.md")
}

@(test)
test_antigravity_post_tool_use_maps_tool_end :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	raw := #load("testdata/antigravity/post_tool_use.json", string)
	mapped, err := antigravity_map_hook(raw, TS)
	testing.expect_value(t, err, Antigravity_Error.None)
	testing.expect_value(t, len(mapped.events), 1)
	if len(mapped.events) != 1 do return

	ev, e := contracts.ext_parse_event(mapped.events[0])
	testing.expect_value(t, e, contracts.Ext_Error.None)
	testing.expect_value(t, ev.kind, contracts.Ext_Event_Kind.Tool_End)
	testing.expect_value(t, ev.tool_name, "view_file")
	testing.expect_value(t, ev.tool_use_id, "step_2")

	v, _ := json.parse_string(mapped.events[0], json.DEFAULT_SPECIFICATION, true)
	o, _ := v.(json.Object)
	p := json_get_object(o, "payload")
	testing.expect_value(t, json_get_string(p, "status"), "completed")
	testing.expect_value(t, json_get_string(p, "outcome"), "unknown")
	d, _ := json_get_int(p, "duration_ms")
	testing.expect_value(t, d, 42)
}

@(test)
test_antigravity_post_tool_use_error_maps_tool_end_error :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	raw := `{"hookEventName":"PostToolUse","conversationId":"s1","stepIdx":3,"toolCall":{"name":"view_file"},"error":"File not found"}`
	mapped, err := antigravity_map_hook(raw, TS)
	testing.expect_value(t, err, Antigravity_Error.None)
	testing.expect_value(t, len(mapped.events), 1)
	if len(mapped.events) != 1 do return

	ev, e := contracts.ext_parse_event(mapped.events[0])
	testing.expect_value(t, e, contracts.Ext_Error.None)
	testing.expect_value(t, ev.kind, contracts.Ext_Event_Kind.Tool_End)

	v, _ := json.parse_string(mapped.events[0], json.DEFAULT_SPECIFICATION, true)
	o, _ := v.(json.Object)
	p := json_get_object(o, "payload")
	testing.expect_value(t, json_get_string(p, "status"), "error")
	testing.expect_value(t, json_get_string(p, "error"), "File not found")
}

@(test)
test_antigravity_stop_maps_idle_and_session_end :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	raw := #load("testdata/antigravity/stop.json", string)
	mapped, err := antigravity_map_hook(raw, TS)
	testing.expect_value(t, err, Antigravity_Error.None)
	testing.expect_value(t, len(mapped.events), 2)
	if len(mapped.events) != 2 do return

	ev0, e0 := contracts.ext_parse_event(mapped.events[0])
	testing.expect_value(t, e0, contracts.Ext_Error.None)
	testing.expect_value(t, ev0.kind, contracts.Ext_Event_Kind.Activity)
	testing.expect_value(t, ev0.activity_state, "idle")

	ev1, e1 := contracts.ext_parse_event(mapped.events[1])
	testing.expect_value(t, e1, contracts.Ext_Error.None)
	testing.expect_value(t, ev1.kind, contracts.Ext_Event_Kind.Session)
	testing.expect_value(t, ev1.session_phase, "end")
}

@(test)
test_antigravity_permission_request_in_ask_mode :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	raw := #load("testdata/antigravity/permission_request.json", string)
	mapped, err := antigravity_map_hook(raw, TS, 10_000, "blk_agy_test")
	testing.expect_value(t, err, Antigravity_Error.None)
	testing.expect_value(t, mapped.is_permission, true)
	testing.expect_value(t, len(mapped.events), 1)
	if len(mapped.events) != 1 do return

	ev, e := contracts.ext_parse_event(mapped.events[0])
	testing.expect_value(t, e, contracts.Ext_Error.None)
	testing.expect_value(t, ev.kind, contracts.Ext_Event_Kind.Permission_Request)
	testing.expect_value(t, ev.tool_name, "run_command")

	v, _ := json.parse_string(mapped.events[0], json.DEFAULT_SPECIFICATION, true)
	o, _ := v.(json.Object)
	p := json_get_object(o, "payload")
	testing.expect_value(t, json_get_string(p, "blocker_id"), "blk_agy_test")
	timeout, _ := json_get_int(p, "timeout_ms")
	testing.expect_value(t, timeout, 10_000)
}

@(test)
test_antigravity_permission_output_formats :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	testing.expect_value(t, antigravity_permission_output("allow", ""), `{"decision":"allow"}`)
	testing.expect_value(t, antigravity_permission_output("deny", ""), `{"decision":"deny","reason":"Denied in Heimdall"}`)
	testing.expect_value(t, antigravity_permission_output("deny", "Blocked by safety policy"), `{"decision":"deny","reason":"Blocked by safety policy"}`)
	testing.expect_value(t, antigravity_permission_output("ask", ""), `{"decision":"ask"}`)

	// from bridge response
	testing.expect_value(t, antigravity_permission_output_from_response(`{"ok":true,"data":{"decision":"allow"}}`), `{"decision":"allow"}`)
	testing.expect_value(t, antigravity_permission_output_from_response(`{"ok":true,"data":{"decision":"deny","message":"Nope"}}`), `{"decision":"deny","reason":"Nope"}`)
	testing.expect_value(t, antigravity_permission_output_from_response(`{"ok":true,"data":{"data":{"decision":"allow"}}}`), `{"decision":"allow"}`)
	testing.expect_value(t, antigravity_permission_output_from_response(`{"ok":true,"data":{"decision":"none"}}`), `{"decision":"ask"}`)
	testing.expect_value(t, antigravity_permission_output_from_response(`{"ok":false}`), `{"decision":"ask"}`)
	testing.expect_value(t, antigravity_permission_output_from_response(""), `{"decision":"ask"}`)
}

@(test)
test_hook_run_antigravity_auto_approves_ham_ctl :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	env := ENV
	env.ctl_bin = "/home/tanmay/heimdall-agent-manager/.heimdall/bin/ham-ctl"

	raw := `{"hookEventName":"PreToolUse","conversationId":"s1","permissionMode":"ask","toolCall":{"name":"run_command","args":{"CommandLine":"./.heimdall/bin/ham-ctl chat read","Cwd":"/home/tanmay/heimdall-agent-manager"}}}`
	agy_fake_reset(`{"ok":true,"data":{"decision":"deny"}}`, true)

	out := hook_run("antigravity", raw, env, agy_fake_send)
	testing.expect_value(t, out, `{"decision":"allow"}`)
	testing.expect_value(t, agy_fake_calls, 0) // Auto-approved locally without hitting bridge!

	// Arbitrary command is not auto-approved and goes to bridge relay
	raw_other := `{"hookEventName":"PreToolUse","conversationId":"s1","permissionMode":"ask","toolCall":{"name":"run_command","args":{"CommandLine":"rm -rf /tmp/test","Cwd":"/home/tanmay/heimdall-agent-manager"}}}`
	agy_fake_reset(`{"ok":true,"data":{"decision":"allow"}}`, true)
	out = hook_run("antigravity", raw_other, env, agy_fake_send)
	testing.expect_value(t, agy_fake_calls, 1)
	testing.expect_value(t, agy_fake_method, "agent.extension.permission")
	testing.expect_value(t, out, `{"decision":"allow"}`)
}

@(test)
test_hook_run_antigravity_timeout_falls_back_to_ask :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	env := ENV
	env.ctl_bin = "/home/tanmay/heimdall-agent-manager/.heimdall/bin/ham-ctl"
	env.permission_timeout_ms = 1_000 // Short timeout for test

	raw := `{"hookEventName":"PreToolUse","conversationId":"s1","permissionMode":"ask","toolCall":{"name":"run_command","args":{"CommandLine":"rm -rf /tmp/test","Cwd":"/home/tanmay/heimdall-agent-manager"}}}`
	agy_fake_reset("", false) // Transport failure / disconnect

	out := hook_run("antigravity", raw, env, agy_fake_send)
	testing.expect_value(t, out, `{"decision":"ask"}`)
}

@(test)
test_antigravity_bounds_and_error_handling :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	// Malformed JSON
	_, err := antigravity_map_hook("invalid json", TS)
	testing.expect_value(t, err, Antigravity_Error.Malformed_Json)

	// Missing conversationId
	_, err2 := antigravity_map_hook(`{"hookEventName":"PreInvocation"}`, TS)
	testing.expect_value(t, err2, Antigravity_Error.Malformed_Json)

	// Input exceeding 16MB limit
	too_large := strings.repeat("x", ANTIGRAVITY_HOOK_INPUT_MAX + 1)
	_, err3 := antigravity_map_hook(too_large, TS)
	testing.expect_value(t, err3, Antigravity_Error.Too_Large)

	// Unknown hook produces no events
	unknown, err4 := antigravity_map_hook(`{"conversationId":"s1","hookEventName":"SomeUnknownEvent"}`, TS)
	testing.expect_value(t, err4, Antigravity_Error.None)
	testing.expect_value(t, len(unknown.events), 0)

	// Tool string clipping: strings > 4KB are clipped
	huge_str := strings.repeat("a", ANTIGRAVITY_TOOL_STRING_MAX + 500)
	tb := strings.builder_make()
	strings.write_string(&tb, `{"hookEventName":"PreToolUse","conversationId":"s1","toolCall":{"name":"view_file","args":{"huge":"`)
	strings.write_string(&tb, huge_str)
	strings.write_string(&tb, `"}}}`)
	mapped_tool, err5 := antigravity_map_hook(strings.to_string(tb), TS)
	testing.expect_value(t, err5, Antigravity_Error.None)
	testing.expect_value(t, len(mapped_tool.events), 1)
	if len(mapped_tool.events) == 1 {
		v, _ := json.parse_string(mapped_tool.events[0], json.DEFAULT_SPECIFICATION, true)
		o, _ := v.(json.Object)
		tool := json_get_object(o, "tool")
		input := json_get_object(tool, "input")
		testing.expect(t, strings.has_suffix(json_get_string(input, "huge"), EXT_CLIP_MARKER))
	}
}

@(test)
test_antigravity_fail_open_without_env :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	raw := #load("testdata/antigravity/pre_invocation.json", string)
	empty_env := Hook_Env{}
	agy_fake_reset(`{"ok":true}`, true)

	// When HEIMDALL_BRIDGE_ENDPOINT and HEIMDALL_AGENT_TOKEN are unset, returns "" with 0 network calls
	out := hook_run("antigravity", raw, empty_env, agy_fake_send)
	testing.expect_value(t, out, "")
	testing.expect_value(t, agy_fake_calls, 0)
}
