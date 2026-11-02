package extension

import json "core:encoding/json"
import "core:fmt"
import "core:mem"
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
test_antigravity_stop_maps_turn_idle_without_session_end :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	// Stop ends one execution loop (a turn), not the session: agy has no
	// session-termination signal, so a session end would wipe live subagent calls.
	raw := #load("testdata/antigravity/stop.json", string)
	mapped, err := antigravity_map_hook(raw, TS)
	testing.expect_value(t, err, Antigravity_Error.None)
	testing.expect_value(t, len(mapped.events), 1)
	if len(mapped.events) != 1 do return

	ev0, e0 := contracts.ext_parse_event(mapped.events[0])
	testing.expect_value(t, e0, contracts.Ext_Error.None)
	testing.expect_value(t, ev0.kind, contracts.Ext_Event_Kind.Activity)
	testing.expect_value(t, ev0.activity_state, "idle")
	testing.expect_value(t, ev0.agent_id, "")
	v, _ := json.parse_string(mapped.events[0], json.DEFAULT_SPECIFICATION, true)
	p := json_get_object(v.(json.Object), "payload")
	testing.expect_value(t, json_get_string(p, "reason"), "model_stop")

	// No terminationReason value ends the session either.
	for reason in ([]string{"model_stop", "max_steps_exceeded", "error", "user_canceled"}) {
		r := fmt.tprintf(`{{"hookEventName":"Stop","conversationId":"s1","terminationReason":"%s","fullyIdle":true}}`, reason)
		m, merr := antigravity_map_hook(r, TS)
		testing.expect_value(t, merr, Antigravity_Error.None)
		testing.expect_value(t, len(m.events), 1)
		for ev_str in m.events {
			ev, _ := contracts.ext_parse_event(ev_str)
			testing.expectf(t, ev.kind == .Activity, "Stop(%s) emitted %v", reason, ev.kind)
		}
	}
}

@(test)
test_antigravity_child_stop_maps_subagent_stop :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	raw := `{"hookEventName":"Stop","conversationId":"s_parent","agentId":"agt_sub123","agentType":"research","terminationReason":"model_stop","fullyIdle":true}`
	mapped, err := antigravity_map_hook(raw, TS)
	testing.expect_value(t, err, Antigravity_Error.None)
	testing.expect_value(t, len(mapped.events), 1)
	if len(mapped.events) != 1 do return
	ev, e := contracts.ext_parse_event(mapped.events[0])
	testing.expect_value(t, e, contracts.Ext_Error.None)
	testing.expect_value(t, ev.kind, contracts.Ext_Event_Kind.Subagent_Stop)
	testing.expect_value(t, ev.agent_id, "agt_sub123")
	testing.expect_value(t, ev.agent_type, "research")
	testing.expect_value(t, ev.session_id, "s_parent")
}

@(test)
test_antigravity_fixture_background_subagent_session_never_ends :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	// Multi-turn native replay: two main Stops and one child Stop.
	fixture := #load("testdata/antigravity/session_background_subagent.jsonl", string)
	kinds: [dynamic]contracts.Ext_Event_Kind
	for line in strings.split_lines_iterator(&fixture) {
		if strings.trim_space(line) == "" do continue
		mapped, err := antigravity_map_hook(line, TS)
		testing.expect_value(t, err, Antigravity_Error.None)
		for ev_str in mapped.events {
			ev, perr := contracts.ext_parse_event(ev_str)
			testing.expect_value(t, perr, contracts.Ext_Error.None)
			testing.expect_value(t, ev.session_id, "5d0c2a7e-agy-bg")
			if ev.kind == .Session do testing.expect_value(t, ev.session_phase, "start")
			append(&kinds, ev.kind)
		}
	}
	idle, starts, stops := 0, 0, 0
	for k in kinds {
		#partial switch k {
		case .Activity: idle += 1
		case .Session: starts += 1
		case .Subagent_Stop: stops += 1
		}
	}
	testing.expect_value(t, starts, 1)
	testing.expect_value(t, stops, 1)
	testing.expect_value(t, idle, 4) // two PreInvocation active + two main Stop idle
	testing.expect_value(t, kinds[len(kinds)-1], contracts.Ext_Event_Kind.Subagent_Stop)
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
	testing.expect_value(t, antigravity_permission_output("deny", ""), `{"decision":"deny","reason":"Denied in Ninjy"}`)
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
	env.ctl_bin = "/home/tanmay/heimdall-agent-manager/bin/ham-ctl"

	raw := `{"hookEventName":"PreToolUse","conversationId":"s1","permissionMode":"ask","toolCall":{"name":"run_command","args":{"CommandLine":"./bin/ham-ctl chat read","Cwd":"/home/tanmay/heimdall-agent-manager"}}}`
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
	env.ctl_bin = "/home/tanmay/heimdall-agent-manager/bin/ham-ctl"
	env.permission_timeout_ms = 1_000 // Short timeout for test

	raw := `{"hookEventName":"PreToolUse","conversationId":"s1","permissionMode":"ask","toolCall":{"name":"run_command","args":{"CommandLine":"rm -rf /tmp/test","Cwd":"/home/tanmay/heimdall-agent-manager"}}}`
	agy_fake_reset("", false) // Transport failure / disconnect

	out := hook_run("antigravity", raw, env, agy_fake_send)
	testing.expect_value(t, out, `{"decision":"ask"}`)
}

@(test)
test_antigravity_permission_request_timeout_clamping_and_stable_blocker :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	raw := `{"hookEventName":"PreToolUse","conversationId":"s1","permissionMode":"ask","toolCall":{"name":"run_command","args":{"CommandLine":"rm -rf /tmp"}}}`

	// 1. Timeout > 300s is clamped to 300s (300,000ms)
	mapped_large, err_large := antigravity_map_hook(raw, TS, 500_000, "blk_custom")
	testing.expect_value(t, err_large, Antigravity_Error.None)
	testing.expect_value(t, mapped_large.is_permission, true)
	if len(mapped_large.events) == 1 {
		v, _ := json.parse_string(mapped_large.events[0], json.DEFAULT_SPECIFICATION, true)
		p := json_get_object(v.(json.Object), "payload")
		timeout, _ := json_get_int(p, "timeout_ms")
		testing.expect_value(t, timeout, 300_000)
		testing.expect_value(t, json_get_string(p, "blocker_id"), "blk_custom")
	}

	// 2. Timeout <= 0 defaults to 300s (300,000ms)
	mapped_zero, err_zero := antigravity_map_hook(raw, TS, 0, "blk_custom2")
	testing.expect_value(t, err_zero, Antigravity_Error.None)
	if len(mapped_zero.events) == 1 {
		v, _ := json.parse_string(mapped_zero.events[0], json.DEFAULT_SPECIFICATION, true)
		p := json_get_object(v.(json.Object), "payload")
		timeout, _ := json_get_int(p, "timeout_ms")
		testing.expect_value(t, timeout, 300_000)
		testing.expect_value(t, json_get_string(p, "blocker_id"), "blk_custom2")
	}

	// 3. Empty blocker_id generates a stable blocker_id starting with blk_
	mapped_gen, err_gen := antigravity_map_hook(raw, TS, 10_000, "")
	testing.expect_value(t, err_gen, Antigravity_Error.None)
	if len(mapped_gen.events) == 1 {
		v, _ := json.parse_string(mapped_gen.events[0], json.DEFAULT_SPECIFICATION, true)
		p := json_get_object(v.(json.Object), "payload")
		bid := json_get_string(p, "blocker_id")
		testing.expect(t, strings.has_prefix(bid, "blk_"))
	}
}

@(test)
test_antigravity_destructive_tools_trigger_permission_in_ask_mode :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	// write_to_file in ask mode triggers permission
	raw_write := `{"hookEventName":"PreToolUse","conversationId":"s1","permissionMode":"ask","stepIdx":3,"toolCall":{"name":"write_to_file","args":{"TargetFile":"/repo/test.txt","CodeContent":"hello"}}}`
	mapped_w, err_w := antigravity_map_hook(raw_write, TS)
	testing.expect_value(t, err_w, Antigravity_Error.None)
	testing.expect_value(t, mapped_w.is_permission, true)
	if len(mapped_w.events) == 1 {
		ev, _ := contracts.ext_parse_event(mapped_w.events[0])
		testing.expect_value(t, ev.kind, contracts.Ext_Event_Kind.Permission_Request)
		testing.expect_value(t, ev.tool_name, "write_to_file")
	}

	// replace_file_content in ask mode triggers permission
	raw_replace := `{"hookEventName":"PreToolUse","conversationId":"s1","permissionMode":"ask","stepIdx":4,"toolCall":{"name":"replace_file_content","args":{"TargetFile":"/repo/test.txt","TargetContent":"a","ReplacementContent":"b"}}}`
	mapped_r, err_r := antigravity_map_hook(raw_replace, TS)
	testing.expect_value(t, err_r, Antigravity_Error.None)
	testing.expect_value(t, mapped_r.is_permission, true)
	if len(mapped_r.events) == 1 {
		ev, _ := contracts.ext_parse_event(mapped_r.events[0])
		testing.expect_value(t, ev.kind, contracts.Ext_Event_Kind.Permission_Request)
		testing.expect_value(t, ev.tool_name, "replace_file_content")
	}

	// Non-destructive view_file in ask mode does NOT trigger permission (emits tool.start)
	raw_view := `{"hookEventName":"PreToolUse","conversationId":"s1","permissionMode":"ask","stepIdx":5,"toolCall":{"name":"view_file","args":{"AbsolutePath":"/repo/test.txt"}}}`
	mapped_v, err_v := antigravity_map_hook(raw_view, TS)
	testing.expect_value(t, err_v, Antigravity_Error.None)
	testing.expect_value(t, mapped_v.is_permission, false)
	if len(mapped_v.events) == 1 {
		ev, _ := contracts.ext_parse_event(mapped_v.events[0])
		testing.expect_value(t, ev.kind, contracts.Ext_Event_Kind.Tool_Start)
		testing.expect_value(t, ev.tool_name, "view_file")
	}

	// Destructive write_to_file when permissionMode is not ask (e.g. empty or allow) does NOT trigger permission
	raw_write_noask := `{"hookEventName":"PreToolUse","conversationId":"s1","permissionMode":"allow","stepIdx":6,"toolCall":{"name":"write_to_file","args":{"TargetFile":"/repo/test.txt","CodeContent":"hello"}}}`
	mapped_wna, err_wna := antigravity_map_hook(raw_write_noask, TS)
	testing.expect_value(t, err_wna, Antigravity_Error.None)
	testing.expect_value(t, mapped_wna.is_permission, false)
	if len(mapped_wna.events) == 1 {
		ev, _ := contracts.ext_parse_event(mapped_wna.events[0])
		testing.expect_value(t, ev.kind, contracts.Ext_Event_Kind.Tool_Start)
	}
}

@(test)
test_antigravity_ham_ctl_allowlist_coverage_and_security :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	env := ENV
	env.ctl_bin = "/issued/ham-ctl"

	// All these allowlisted coordination commands must be approved locally (0 bridge calls)
	allowlisted := []string{
		"$HEIMDALL_CTL_BIN chat send --to user --body 'update'",
		"$HEIMDALL_CTL_BIN lease heartbeat --note progress",
		"$HEIMDALL_CTL_BIN lease next",
		"$HEIMDALL_CTL_BIN lease submit --summary done",
		"$HEIMDALL_CTL_BIN task comment t4_permission --body working",
		"$HEIMDALL_CTL_BIN task show t4_permission",
		"$HEIMDALL_CTL_BIN task list",
		"$HEIMDALL_CTL_BIN agent start-success",
		"$HEIMDALL_CTL_BIN memory propose --scope project --title fact --content test",
	}

	for cmd in allowlisted {
		agy_fake_reset(`{"ok":true,"data":{"decision":"deny"}}`, true)
		raw := fmt.tprintf(`{{"hookEventName":"PreToolUse","conversationId":"s1","permissionMode":"ask","toolCall":{{"name":"run_command","args":{{"CommandLine":"%s","Cwd":"/repo"}}}}}}`, cmd)
		out := hook_run("antigravity", raw, env, agy_fake_send)
		testing.expectf(t, out == `{"decision":"allow"}`, "expected auto-approval for %s, got %s", cmd, out)
		testing.expect_value(t, agy_fake_calls, 0)
	}

	// Commands that MUST NOT be auto-approved (they must go to the bridge relay)
	rejected := []string{
		"$HEIMDALL_CTL_BIN shell run --cmd 'ls'",
		"$HEIMDALL_CTL_BIN shell serve --port 8080",
		"$HEIMDALL_CTL_BIN review post --on-behalf-of user",
		"$HEIMDALL_CTL_BIN task update t1 --verify 'evil'",
		"$HEIMDALL_CTL_BIN task create --title bad",
		"$HEIMDALL_CTL_BIN chat read && rm -rf /",
		"$HEIMDALL_CTL_BIN chat read; ls",
		"$HEIMDALL_CTL_BIN chat read | grep foo",
		"$HEIMDALL_CTL_BIN chat read --agent-token evil_token",
		"$HEIMDALL_CTL_BIN chat read --bridge-endpoint tcp:evil:1234",
	}

	for cmd in rejected {
		agy_fake_reset(`{"ok":true,"data":{"decision":"allow"}}`, true)
		raw := fmt.tprintf(`{{"hookEventName":"PreToolUse","conversationId":"s1","permissionMode":"ask","toolCall":{{"name":"run_command","args":{{"CommandLine":"%s","Cwd":"/repo"}}}}}}`, cmd)
		out := hook_run("antigravity", raw, env, agy_fake_send)
		testing.expectf(t, agy_fake_calls == 1, "expected bridge call for rejected command %s, calls=%d", cmd, agy_fake_calls)
		testing.expect_value(t, agy_fake_method, "agent.extension.permission")
		testing.expect_value(t, out, `{"decision":"allow"}`)
	}

	// Destructive file tools in ask mode are also NOT auto-approved (they go to the bridge relay)
	raw_file := `{"hookEventName":"PreToolUse","conversationId":"s1","permissionMode":"ask","toolCall":{"name":"write_to_file","args":{"TargetFile":"/repo/file.txt","CodeContent":"data"}}}`
	agy_fake_reset(`{"ok":true,"data":{"decision":"deny","message":"cannot touch file"}}`, true)
	out_file := hook_run("antigravity", raw_file, env, agy_fake_send)
	testing.expect_value(t, agy_fake_calls, 1)
	testing.expect_value(t, out_file, `{"decision":"deny","reason":"cannot touch file"}`)
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

@(test)
test_antigravity_pre_tool_use_step_idx_generates_tool_use_id :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	raw := `{"hookEventName":"PreToolUse","conversationId":"s1","stepIdx":7,"toolCall":{"name":"run_command","args":{"CommandLine":"ls -la"}}}`
	mapped, err := antigravity_map_hook(raw, TS)
	testing.expect_value(t, err, Antigravity_Error.None)
	testing.expect_value(t, len(mapped.events), 1)
	if len(mapped.events) != 1 do return

	ev, e := contracts.ext_parse_event(mapped.events[0])
	testing.expect_value(t, e, contracts.Ext_Error.None)
	testing.expect_value(t, ev.kind, contracts.Ext_Event_Kind.Tool_Start)
	testing.expect_value(t, ev.tool_name, "run_command")
	testing.expect_value(t, ev.tool_use_id, "step_7")

	// Test step_idx = 0
	raw0 := `{"hookEventName":"PreToolUse","conversationId":"s1","stepIdx":0,"toolCall":{"name":"view_file"}}`
	mapped0, err0 := antigravity_map_hook(raw0, TS)
	testing.expect_value(t, err0, Antigravity_Error.None)
	if len(mapped0.events) == 1 {
		ev0, _ := contracts.ext_parse_event(mapped0.events[0])
		testing.expect_value(t, ev0.tool_use_id, "step_0")
	}
}

@(test)
test_antigravity_invoke_subagent_emits_subagent_start :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	raw := `{"hookEventName":"PreToolUse","conversationId":"s1","stepIdx":3,"toolCall":{"name":"invoke_subagent","args":{"Subagents":[{"Role":"Codebase Researcher","TypeName":"research","Model":"flash","Prompt":"Search code"}]}}}`
	mapped, err := antigravity_map_hook(raw, TS)
	testing.expect_value(t, err, Antigravity_Error.None)
	testing.expect_value(t, len(mapped.events), 2)
	if len(mapped.events) != 2 do return

	// First event: tool.start for invoke_subagent
	ev0, e0 := contracts.ext_parse_event(mapped.events[0])
	testing.expect_value(t, e0, contracts.Ext_Error.None)
	testing.expect_value(t, ev0.kind, contracts.Ext_Event_Kind.Tool_Start)
	testing.expect_value(t, ev0.tool_name, "invoke_subagent")
	testing.expect_value(t, ev0.tool_use_id, "step_3")

	// Second event: subagent.start with target role, type, and model
	ev1, e1 := contracts.ext_parse_event(mapped.events[1])
	testing.expect_value(t, e1, contracts.Ext_Error.None)
	testing.expect_value(t, ev1.kind, contracts.Ext_Event_Kind.Subagent_Start)

	v1, _ := json.parse_string(mapped.events[1], json.DEFAULT_SPECIFICATION, true)
	o1, _ := v1.(json.Object)
	p1 := json_get_object(o1, "payload")
	testing.expect_value(t, json_get_string(p1, "role"), "Codebase Researcher")
	testing.expect_value(t, json_get_string(p1, "type"), "research")
	testing.expect_value(t, json_get_string(p1, "model"), "flash")

	// Multiple subagents in one call
	raw_multi := `{"hookEventName":"PreToolUse","conversationId":"s1","stepIdx":4,"toolCall":{"name":"invoke_subagent","args":{"subagents":[{"role":"Worker A","type":"worker","model":"pro"},{"role":"Worker B","type":"tester","model":"flash_lite"}]}}}`
	mapped_m, err_m := antigravity_map_hook(raw_multi, TS)
	testing.expect_value(t, err_m, Antigravity_Error.None)
	testing.expect_value(t, len(mapped_m.events), 3) // tool.start + 2 subagent.start
	if len(mapped_m.events) == 3 {
		ev_sub1, _ := contracts.ext_parse_event(mapped_m.events[1])
		ev_sub2, _ := contracts.ext_parse_event(mapped_m.events[2])
		testing.expect_value(t, ev_sub1.kind, contracts.Ext_Event_Kind.Subagent_Start)
		testing.expect_value(t, ev_sub2.kind, contracts.Ext_Event_Kind.Subagent_Start)

		vm1, _ := json.parse_string(mapped_m.events[1], json.DEFAULT_SPECIFICATION, true)
		pm1 := json_get_object(vm1.(json.Object), "payload")
		testing.expect_value(t, json_get_string(pm1, "role"), "Worker A")
		testing.expect_value(t, json_get_string(pm1, "type"), "worker")
		testing.expect_value(t, json_get_string(pm1, "model"), "pro")

		vm2, _ := json.parse_string(mapped_m.events[2], json.DEFAULT_SPECIFICATION, true)
		pm2 := json_get_object(vm2.(json.Object), "payload")
		testing.expect_value(t, json_get_string(pm2, "role"), "Worker B")
		testing.expect_value(t, json_get_string(pm2, "type"), "tester")
		testing.expect_value(t, json_get_string(pm2, "model"), "flash_lite")
	}
}

@(test)
test_antigravity_write_to_file_generates_file_edit_diff :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	raw := `{"hookEventName":"PostToolUse","conversationId":"s1","stepIdx":5,"cwd":"/home/tanmay/heimdall-agent-manager","toolCall":{"name":"write_to_file","args":{"TargetFile":"/home/tanmay/heimdall-agent-manager/src/hello.odin","CodeContent":"package main\n\nmain :: proc() {}\n"}},"toolResult":{"output":"Created file"}}`
	mapped, err := antigravity_map_hook(raw, TS)
	testing.expect_value(t, err, Antigravity_Error.None)
	testing.expect_value(t, len(mapped.events), 2)
	if len(mapped.events) != 2 do return

	// Event 0: tool.end
	ev0, e0 := contracts.ext_parse_event(mapped.events[0])
	testing.expect_value(t, e0, contracts.Ext_Error.None)
	testing.expect_value(t, ev0.kind, contracts.Ext_Event_Kind.Tool_End)
	testing.expect_value(t, ev0.tool_use_id, "step_5")

	// Event 1: file.edit
	ev1, e1 := contracts.ext_parse_event(mapped.events[1])
	testing.expect_value(t, e1, contracts.Ext_Error.None)
	testing.expect_value(t, ev1.kind, contracts.Ext_Event_Kind.File_Edit)
	testing.expect_value(t, ev1.file_path, "/home/tanmay/heimdall-agent-manager/src/hello.odin")

	v1, _ := json.parse_string(mapped.events[1], json.DEFAULT_SPECIFICATION, true)
	p1 := json_get_object(v1.(json.Object), "payload")
	testing.expect_value(t, json_get_string(p1, "operation"), "create")
	testing.expect_value(t, json_get_string(p1, "diff_source"), "content")
	expected_diff := "--- /dev/null\n+++ b/src/hello.odin\n@@ -0,0 +1,3 @@\n+package main\n+\n+main :: proc() {}\n"
	testing.expect_value(t, json_get_string(p1, "diff"), expected_diff)
	adds, _ := json_get_int(p1, "additions")
	dels, _ := json_get_int(p1, "deletions")
	testing.expect_value(t, adds, 3)
	testing.expect_value(t, dels, 0)

	// Append flag sets operation = "append"
	raw_append := `{"hookEventName":"PostToolUse","conversationId":"s1","stepIdx":6,"cwd":"/home/tanmay/heimdall-agent-manager","toolCall":{"name":"write_to_file","args":{"TargetFile":"/home/tanmay/heimdall-agent-manager/src/hello.odin","CodeContent":"// trailing\n","Append":true}},"toolResult":{"output":"Appended"}}`
	mapped_app, _ := antigravity_map_hook(raw_append, TS)
	if len(mapped_app.events) == 2 {
		v_app, _ := json.parse_string(mapped_app.events[1], json.DEFAULT_SPECIFICATION, true)
		p_app := json_get_object(v_app.(json.Object), "payload")
		testing.expect_value(t, json_get_string(p_app, "operation"), "append")
	}

	// Overwrite flag sets operation = "update"
	raw_ov := `{"hookEventName":"PostToolUse","conversationId":"s1","stepIdx":7,"cwd":"/home/tanmay/heimdall-agent-manager","toolCall":{"name":"write_to_file","args":{"TargetFile":"/home/tanmay/heimdall-agent-manager/src/hello.odin","CodeContent":"package main\n","Overwrite":true}},"toolResult":{"output":"Overwritten"}}`
	mapped_ov, _ := antigravity_map_hook(raw_ov, TS)
	if len(mapped_ov.events) == 2 {
		v_ov, _ := json.parse_string(mapped_ov.events[1], json.DEFAULT_SPECIFICATION, true)
		p_ov := json_get_object(v_ov.(json.Object), "payload")
		testing.expect_value(t, json_get_string(p_ov, "operation"), "update")
	}
}

@(test)
test_antigravity_replace_file_content_generates_file_edit_diff :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	raw := `{"hookEventName":"PostToolUse","conversationId":"s1","stepIdx":8,"cwd":"/home/tanmay/heimdall-agent-manager","toolCall":{"name":"replace_file_content","args":{"TargetFile":"/home/tanmay/heimdall-agent-manager/src/foo.odin","TargetContent":"var count = 0\n","ReplacementContent":"var count = 100\n","StartLine":12,"EndLine":12}},"toolResult":{"output":"Replaced"}}`
	mapped, err := antigravity_map_hook(raw, TS)
	testing.expect_value(t, err, Antigravity_Error.None)
	testing.expect_value(t, len(mapped.events), 2)
	if len(mapped.events) != 2 do return

	ev1, e1 := contracts.ext_parse_event(mapped.events[1])
	testing.expect_value(t, e1, contracts.Ext_Error.None)
	testing.expect_value(t, ev1.kind, contracts.Ext_Event_Kind.File_Edit)
	testing.expect_value(t, ev1.file_path, "/home/tanmay/heimdall-agent-manager/src/foo.odin")

	v1, _ := json.parse_string(mapped.events[1], json.DEFAULT_SPECIFICATION, true)
	p1 := json_get_object(v1.(json.Object), "payload")
	testing.expect_value(t, json_get_string(p1, "operation"), "edit")
	testing.expect_value(t, json_get_string(p1, "diff_source"), "strings")
	expected_diff := "--- a/src/foo.odin\n+++ b/src/foo.odin\n@@ -12,1 +12,1 @@\n-var count = 0\n+var count = 100\n"
	testing.expect_value(t, json_get_string(p1, "diff"), expected_diff)
	adds, _ := json_get_int(p1, "additions")
	dels, _ := json_get_int(p1, "deletions")
	testing.expect_value(t, adds, 1)
	testing.expect_value(t, dels, 1)
}

@(test)
test_antigravity_diff_truncation_capped_at_64kb :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	// Create 70KB text
	line := "abcdefghijklmnopqrstuvwxyz0123456789\\n" // 38 bytes
	repeat_count := (70 * 1024) / len(line) + 1
	huge_content := strings.repeat(line, repeat_count)

	tb := strings.builder_make()
	strings.write_string(&tb, `{"hookEventName":"PostToolUse","conversationId":"s1","stepIdx":9,"cwd":"/home/tanmay/heimdall-agent-manager","toolCall":{"name":"write_to_file","args":{"TargetFile":"/home/tanmay/heimdall-agent-manager/huge.txt","CodeContent":"`)
	strings.write_string(&tb, huge_content)
	strings.write_string(&tb, `"}}}`)

	mapped, err := antigravity_map_hook(strings.to_string(tb), TS)
	testing.expect_value(t, err, Antigravity_Error.None)
	testing.expect_value(t, len(mapped.events), 2)
	if len(mapped.events) != 2 do return

	v1, _ := json.parse_string(mapped.events[1], json.DEFAULT_SPECIFICATION, true)
	p1 := json_get_object(v1.(json.Object), "payload")
	testing.expect_value(t, json_get_bool(p1, "diff_truncated"), true)
	diff_str := json_get_string(p1, "diff")
	testing.expect(t, strings.has_suffix(diff_str, contracts.EXT_TRUNCATED_MARKER))
	testing.expect(t, len(diff_str) <= contracts.EXT_DIFF_MAX_BYTES + len(contracts.EXT_TRUNCATED_MARKER))
}

@(test)
test_antigravity_diff_binary_handling :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	// Binary file with NUL byte
	raw := "{\"hookEventName\":\"PostToolUse\",\"conversationId\":\"s1\",\"stepIdx\":10,\"toolCall\":{\"name\":\"write_to_file\",\"args\":{\"TargetFile\":\"/tmp/bin\",\"CodeContent\":\"hello\\u0000world\"}}}"
	mapped, err := antigravity_map_hook(raw, TS)
	testing.expect_value(t, err, Antigravity_Error.None)
	testing.expect_value(t, len(mapped.events), 2)
	if len(mapped.events) == 2 {
		v, _ := json.parse_string(mapped.events[1], json.DEFAULT_SPECIFICATION, true)
		p := json_get_object(v.(json.Object), "payload")
		testing.expect_value(t, json_get_bool(p, "binary"), true)
		testing.expect_value(t, json_get_string(p, "diff"), "")
	}
}

@(test)
test_antigravity_failed_file_edit_omits_file_edit_event :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	raw := `{"hookEventName":"PostToolUse","conversationId":"s1","stepIdx":11,"toolCall":{"name":"write_to_file","args":{"TargetFile":"/root/forbidden.txt","CodeContent":"secrets"}},"error":"Permission denied"}`
	mapped, err := antigravity_map_hook(raw, TS)
	testing.expect_value(t, err, Antigravity_Error.None)
	testing.expect_value(t, len(mapped.events), 1) // Only tool.end, no file.edit!
	if len(mapped.events) == 1 {
		ev, _ := contracts.ext_parse_event(mapped.events[0])
		testing.expect_value(t, ev.kind, contracts.Ext_Event_Kind.Tool_End)
		v, _ := json.parse_string(mapped.events[0], json.DEFAULT_SPECIFICATION, true)
		p := json_get_object(v.(json.Object), "payload")
		testing.expect_value(t, json_get_string(p, "status"), "error")
	}
}

@(test)
test_antigravity_post_invocation_maps_no_events_and_silent_stdout :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	raw := #load("testdata/antigravity/post_invocation.json", string)
	mapped, err := antigravity_map_hook(raw, TS)
	testing.expect_value(t, err, Antigravity_Error.None)
	testing.expect_value(t, mapped.hook, Antigravity_Hook.Post_Invocation)
	testing.expect_value(t, mapped.is_permission, false)
	testing.expect_value(t, len(mapped.events), 0)

	// hook_run on PostInvocation produces empty stdout and 0 bridge calls
	agy_fake_reset(`{"ok":true}`, true)
	out := hook_run("antigravity", raw, ENV, agy_fake_send)
	testing.expect_value(t, out, "")
	testing.expect_value(t, agy_fake_calls, 0)
}

@(test)
test_antigravity_fixture_pre_tool_use_subagent :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	raw := #load("testdata/antigravity/pre_tool_use_subagent.json", string)
	mapped, err := antigravity_map_hook(raw, TS)
	testing.expect_value(t, err, Antigravity_Error.None)
	testing.expect_value(t, mapped.hook, Antigravity_Hook.Pre_Tool_Use)
	testing.expect_value(t, mapped.is_permission, false)
	testing.expect_value(t, len(mapped.events), 2)
	if len(mapped.events) != 2 do return

	// Event 0: tool.start
	ev0, e0 := contracts.ext_parse_event(mapped.events[0])
	testing.expect_value(t, e0, contracts.Ext_Error.None)
	testing.expect_value(t, ev0.kind, contracts.Ext_Event_Kind.Tool_Start)
	testing.expect_value(t, ev0.tool_name, "invoke_subagent")
	testing.expect_value(t, ev0.tool_use_id, "step_3")

	// Event 1: subagent.start
	ev1, e1 := contracts.ext_parse_event(mapped.events[1])
	testing.expect_value(t, e1, contracts.Ext_Error.None)
	testing.expect_value(t, ev1.kind, contracts.Ext_Event_Kind.Subagent_Start)

	v1, _ := json.parse_string(mapped.events[1], json.DEFAULT_SPECIFICATION, true)
	o1, _ := v1.(json.Object)
	p1 := json_get_object(o1, "payload")
	testing.expect_value(t, json_get_string(p1, "role"), "Codebase Researcher")
	testing.expect_value(t, json_get_string(p1, "type"), "research")
	testing.expect_value(t, json_get_string(p1, "model"), "flash")
}

@(test)
test_antigravity_fixture_post_tool_use_write_create :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	raw := #load("testdata/antigravity/post_tool_use_write_create.json", string)
	mapped, err := antigravity_map_hook(raw, TS)
	testing.expect_value(t, err, Antigravity_Error.None)
	testing.expect_value(t, mapped.hook, Antigravity_Hook.Post_Tool_Use)
	testing.expect_value(t, len(mapped.events), 2)
	if len(mapped.events) != 2 do return

	// Event 0: tool.end
	ev0, e0 := contracts.ext_parse_event(mapped.events[0])
	testing.expect_value(t, e0, contracts.Ext_Error.None)
	testing.expect_value(t, ev0.kind, contracts.Ext_Event_Kind.Tool_End)
	testing.expect_value(t, ev0.tool_name, "write_to_file")
	testing.expect_value(t, ev0.tool_use_id, "step_5")

	// Event 1: file.edit
	ev1, e1 := contracts.ext_parse_event(mapped.events[1])
	testing.expect_value(t, e1, contracts.Ext_Error.None)
	testing.expect_value(t, ev1.kind, contracts.Ext_Event_Kind.File_Edit)
	testing.expect_value(t, ev1.file_path, "/home/tanmay/heimdall-agent-manager/src/hello.odin")

	v1, _ := json.parse_string(mapped.events[1], json.DEFAULT_SPECIFICATION, true)
	o1, _ := v1.(json.Object)
	p1 := json_get_object(o1, "payload")
	testing.expect_value(t, json_get_string(p1, "operation"), "create")
	testing.expect_value(t, json_get_string(p1, "diff_source"), "content")
	adds, _ := json_get_int(p1, "additions")
	dels, _ := json_get_int(p1, "deletions")
	testing.expect_value(t, adds, 3)
	testing.expect_value(t, dels, 0)
	testing.expect(t, strings.contains(json_get_string(p1, "diff"), "+++ b/src/hello.odin"))
}

@(test)
test_antigravity_fixture_post_tool_use_replace_file :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	raw := #load("testdata/antigravity/post_tool_use_replace_file.json", string)
	mapped, err := antigravity_map_hook(raw, TS)
	testing.expect_value(t, err, Antigravity_Error.None)
	testing.expect_value(t, mapped.hook, Antigravity_Hook.Post_Tool_Use)
	testing.expect_value(t, len(mapped.events), 2)
	if len(mapped.events) != 2 do return

	ev0, e0 := contracts.ext_parse_event(mapped.events[0])
	testing.expect_value(t, e0, contracts.Ext_Error.None)
	testing.expect_value(t, ev0.kind, contracts.Ext_Event_Kind.Tool_End)
	testing.expect_value(t, ev0.tool_name, "replace_file_content")
	testing.expect_value(t, ev0.tool_use_id, "step_6")

	ev1, e1 := contracts.ext_parse_event(mapped.events[1])
	testing.expect_value(t, e1, contracts.Ext_Error.None)
	testing.expect_value(t, ev1.kind, contracts.Ext_Event_Kind.File_Edit)
	testing.expect_value(t, ev1.file_path, "/home/tanmay/heimdall-agent-manager/src/hello.odin")

	v1, _ := json.parse_string(mapped.events[1], json.DEFAULT_SPECIFICATION, true)
	o1, _ := v1.(json.Object)
	p1 := json_get_object(o1, "payload")
	testing.expect_value(t, json_get_string(p1, "operation"), "edit")
	testing.expect_value(t, json_get_string(p1, "diff_source"), "strings")
	diff := json_get_string(p1, "diff")
	testing.expect(t, strings.contains(diff, "--- a/src/hello.odin"))
	testing.expect(t, strings.contains(diff, "+++ b/src/hello.odin"))
	testing.expect(t, strings.contains(diff, "-main :: proc() {}"))
	testing.expect(t, strings.contains(diff, "+main :: proc() {"))
}

@(test)
test_antigravity_fixture_post_tool_use_failure :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	raw := #load("testdata/antigravity/post_tool_use_failure.json", string)
	mapped, err := antigravity_map_hook(raw, TS)
	testing.expect_value(t, err, Antigravity_Error.None)
	testing.expect_value(t, mapped.hook, Antigravity_Hook.Post_Tool_Use)
	testing.expect_value(t, len(mapped.events), 1)
	if len(mapped.events) != 1 do return

	ev0, e0 := contracts.ext_parse_event(mapped.events[0])
	testing.expect_value(t, e0, contracts.Ext_Error.None)
	testing.expect_value(t, ev0.kind, contracts.Ext_Event_Kind.Tool_End)

	v0, _ := json.parse_string(mapped.events[0], json.DEFAULT_SPECIFICATION, true)
	o0, _ := v0.(json.Object)
	p0 := json_get_object(o0, "payload")
	testing.expect_value(t, json_get_string(p0, "status"), "error")
	testing.expect_value(t, json_get_string(p0, "error"), "File does not exist: /nonexistent/path/missing.txt")
}

@(test)
test_antigravity_child_subagent_events_carry_agent_id_and_type :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	raw := `{"hookEventName":"PreToolUse","conversationId":"s_parent","agentId":"agt_sub123","agentType":"research","stepIdx":2,"toolCall":{"name":"view_file","args":{"AbsolutePath":"/repo/doc.md"}}}`
	mapped, err := antigravity_map_hook(raw, TS)
	testing.expect_value(t, err, Antigravity_Error.None)
	testing.expect_value(t, len(mapped.events), 1)
	if len(mapped.events) == 1 {
		ev, e := contracts.ext_parse_event(mapped.events[0])
		testing.expect_value(t, e, contracts.Ext_Error.None)
		testing.expect_value(t, ev.agent_id, "agt_sub123")
		testing.expect_value(t, ev.agent_type, "research")
		testing.expect_value(t, ev.kind, contracts.Ext_Event_Kind.Tool_Start)
	}
}

@(test)
test_antigravity_all_fixtures_satisfy_contract :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	fixtures := []string{
		#load("testdata/antigravity/pre_invocation.json", string),
		#load("testdata/antigravity/post_invocation.json", string),
		#load("testdata/antigravity/pre_tool_use.json", string),
		#load("testdata/antigravity/pre_tool_use_subagent.json", string),
		#load("testdata/antigravity/post_tool_use.json", string),
		#load("testdata/antigravity/post_tool_use_write_create.json", string),
		#load("testdata/antigravity/post_tool_use_replace_file.json", string),
		#load("testdata/antigravity/post_tool_use_failure.json", string),
		#load("testdata/antigravity/permission_request.json", string),
		#load("testdata/antigravity/stop.json", string),
	}

	event_counts := make(map[string]int)
	total_events := 0

	for raw, idx in fixtures {
		mapped, err := antigravity_map_hook(raw, TS, 10_000, "blk_fixture_all")
		testing.expect_value(t, err, Antigravity_Error.None)

		for event_str in mapped.events {
			total_events += 1
			testing.expect(t, len(event_str) <= contracts.EXT_EVENT_MAX_BYTES, "event stays within 256KB cap")

			ev, perr := contracts.ext_parse_event(event_str)
			testing.expectf(t, perr == .None, "fixture %d event failed schema parse: %v", idx, perr)
			testing.expect_value(t, ev.provider, "antigravity")
			testing.expect_value(t, ev.ext_version, ANTIGRAVITY_EXT_VERSION)
			testing.expect_value(t, ev.session_id, "2f93a09c-a72a-41a2-be58-b906858e9794")

			kind_name := contracts.ext_event_kind_name(ev.kind)
			event_counts[kind_name] += 1
		}
	}

	testing.expect(t, total_events >= 13, "expected at least 13 events across fixtures")
	for required in ([]string{"hello", "session", "activity", "tool.start", "tool.end", "subagent.start", "permission.request", "file.edit"}) {
		testing.expectf(t, event_counts[required] > 0, "expected event kind %s across fixtures, got %d", required, event_counts[required])
	}
}

@(test)
test_antigravity_tracking_allocator_clean :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	baseline_allocs := len(track.allocation_map)

	// Test zero-leak execution of permission formatting
	out_allow := antigravity_permission_output("allow", "")
	testing.expect_value(t, out_allow, `{"decision":"allow"}`)

	out_ask := antigravity_permission_output("ask", "")
	testing.expect_value(t, out_ask, `{"decision":"ask"}`)

	out_deny := antigravity_permission_output("deny", "Access denied")
	testing.expect_value(t, out_deny, `{"decision":"deny","reason":"Access denied"}`)
	delete(out_deny)

	// Test response parsing with temp allocator cleanly
	resp_out := antigravity_permission_output_from_response(`{"ok":true,"data":{"decision":"allow"}}`)
	testing.expect_value(t, resp_out, `{"decision":"allow"}`)

	// Test destructive check
	testing.expect(t, antigravity_is_destructive("run_command"))
	testing.expect(t, antigravity_is_destructive("write_to_file"))
	testing.expect(t, antigravity_is_destructive("replace_file_content"))
	testing.expect(t, !antigravity_is_destructive("view_file"))

	testing.expectf(t, len(track.allocation_map) == baseline_allocs,
		"leak detected under tracking allocator: %d live allocations, expected baseline %d",
		len(track.allocation_map), baseline_allocs)
	testing.expect_value(t, len(track.bad_free_array), 0)
}
