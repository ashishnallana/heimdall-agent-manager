package main

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:testing"

// REQ-EXT-PERM-1: agent.extension.permission blocks until the hub pushes a user
// decision; timeout / cancellation / hub-down return "none" (never deny), and the
// hub row is closed when nobody decided.

// Per-instance stub of the hub forwarder. Tests run in parallel, so each test
// uses its own instance id and the stub keys everything on it.
Ext_Perm_Stub_Mode :: enum {
	Silent, // accept, never decide (-> timeout)
	Decide, // accept and push a permission_decision frame at once
	Cancel, // accept, then the instance stops
	Hub_Down, // refuse (relay failure)
}

Ext_Perm_Stub :: struct {
	instance_id: string,
	mode:        Ext_Perm_Stub_Mode,
	decision:    string,
	posts:       [dynamic]string, // "<path> <params>"
}

@(private = "file")
ext_perm_stub_mutex: sync.Mutex
@(private = "file")
ext_perm_stubs: [dynamic]^Ext_Perm_Stub

@(private = "file")
ext_perm_stub_register :: proc(instance_id: string, mode: Ext_Perm_Stub_Mode, decision := "") -> ^Ext_Perm_Stub {
	context.allocator = runtime.heap_allocator()
	sync.mutex_lock(&ext_perm_stub_mutex)
	defer sync.mutex_unlock(&ext_perm_stub_mutex)
	s := new(Ext_Perm_Stub)
	s.instance_id = strings.clone(instance_id)
	s.mode = mode
	s.decision = strings.clone(decision)
	append(&ext_perm_stubs, s)
	bridge_ext_permission_forward = ext_perm_stub_forward
	return s
}

@(private = "file")
ext_perm_stub_find :: proc(instance_id: string) -> ^Ext_Perm_Stub {
	sync.mutex_lock(&ext_perm_stub_mutex)
	defer sync.mutex_unlock(&ext_perm_stub_mutex)
	for s in ext_perm_stubs do if s.instance_id == instance_id do return s
	return nil
}

@(private = "file")
ext_perm_stub_posts :: proc(s: ^Ext_Perm_Stub) -> []string {
	sync.mutex_lock(&ext_perm_stub_mutex)
	defer sync.mutex_unlock(&ext_perm_stub_mutex)
	out := make([]string, len(s.posts), context.temp_allocator)
	copy(out, s.posts[:])
	return out
}

ext_perm_stub_forward :: proc(rec: Bridge_Local_Agent_Token_Record, path, params: string) -> bool {
	s := ext_perm_stub_find(rec.agent_instance_id)
	if s == nil do return false
	sync.mutex_lock(&ext_perm_stub_mutex)
	append(&s.posts, strings.concatenate({path, " ", params}, runtime.heap_allocator()))
	sync.mutex_unlock(&ext_perm_stub_mutex)
	if path != BRIDGE_EXT_PERMISSION_HUB_PATH do return true
	switch s.mode {
	case .Silent:
	case .Hub_Down:
		return false
	case .Decide:
		// The pending entry is registered before the hub hears of the request, so
		// even an instant push (before the waiter starts) must resolve it.
		request_id := bridge_local_extract_json_string(params, "request_id", "", context.temp_allocator)
		frame := strings.concatenate({`{"type":"permission_decision","command_id":"cmd_1","agent_instance_id":"`, rec.agent_instance_id, `","request_id":"`, request_id, `","decision":"`, s.decision, `","message":"from test"}`}, context.temp_allocator)
		_ = bridge_ext_permission_handle_decision_frame(frame)
	case .Cancel:
		_ = bridge_permission_cancel_instance(rec.agent_instance_id)
	}
	return true
}

@(private = "file")
ext_perm_event :: proc(extra: string) -> string {
	return strings.concatenate({`{"schema":"ham.ext.v1","provider":"claude","ext_version":"0.1.0","event":"permission.request","ts":"2026-10-22T06:00:00Z","session_id":"sess-1","agent":{"id":"sub-1","type":"Explore"},"tool":{"name":"Bash","use_id":"tu_9","input":{"command":"rm -rf build"}}`, extra, `}`}, context.temp_allocator)
}

@(private = "file")
ext_perm_rec :: proc(id: string) -> Bridge_Local_Agent_Token_Record {
	return Bridge_Local_Agent_Token_Record{agent_instance_id = id, instance_token = "tok_test", role = .Agent}
}

@(private = "file")
ext_perm_req :: proc(t: ^testing.T, extra: string) -> Bridge_Ext_Permission_Request {
	req, msg, ok := bridge_ext_permission_parse(ext_perm_event(extra))
	testing.expectf(t, ok, "parse failed: %s", msg)
	return req
}

@(private = "file")
ext_perm_pending_count :: proc(instance_id: string) -> int {
	sync.mutex_lock(&bridge_permission_mutex)
	defer sync.mutex_unlock(&bridge_permission_mutex)
	n := 0
	for p in bridge_permission_pending do if p.agent_instance_id == instance_id do n += 1
	return n
}

@(test)
test_ext_permission_parse_extracts_tool_and_suggestions :: proc(t: ^testing.T) {
	req, msg, ok := bridge_ext_permission_parse(ext_perm_event(`,"timeout_ms":4500,"payload":{"permission_suggestions":[{"type":"addRules","behavior":"allow"}]}`))
	testing.expectf(t, ok, "parse failed: %s", msg)
	testing.expect_value(t, req.provider, "claude")
	testing.expect_value(t, req.agent_id, "sub-1")
	testing.expect_value(t, req.tool_name, "Bash")
	testing.expect_value(t, req.tool_use_id, "tu_9")
	testing.expect_value(t, req.timeout_ms, 4500)
	testing.expect(t, strings.contains(req.input, `"command":"rm -rf build"`), req.input)
	testing.expect(t, strings.contains(req.suggestions, `"addRules"`), req.suggestions)

	// payload.timeout_ms works too; absent suggestions default to [].
	req2, _, ok2 := bridge_ext_permission_parse(ext_perm_event(`,"payload":{"timeout_ms":2000}`))
	testing.expect(t, ok2)
	testing.expect_value(t, req2.timeout_ms, 2000)
	testing.expect_value(t, req2.suggestions, "[]")

	// The params the hub ingests carry the bridge request id and the clamped timeout.
	params := bridge_ext_permission_hub_params("perm_abc", req, 4500)
	testing.expect(t, strings.contains(params, `"request_id":"perm_abc"`), params)
	testing.expect(t, strings.contains(params, `"timeout_ms":4500`), params)
	testing.expect(t, strings.contains(params, `"permission_suggestions":[`), params)
}

@(test)
test_ext_permission_parse_rejects_other_events :: proc(t: ^testing.T) {
	bad := `{"schema":"ham.ext.v1","provider":"claude","event":"tool.start","tool":{"name":"Bash"}}`
	_, msg, ok := bridge_ext_permission_parse(bad)
	testing.expect(t, !ok)
	testing.expect_value(t, msg, "event must be permission.request")
	_, _, ok2 := bridge_ext_permission_parse(`{"schema":"ham.ext.v1","provider":"claude","event":"permission.request"}`)
	testing.expect(t, !ok2, "tool.name is required")
	_, _, ok3 := bridge_ext_permission_parse(`not json`)
	testing.expect(t, !ok3)
}

@(test)
test_ext_permission_timeout_returns_none_and_closes_hub_row :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	id := "inst_extperm_timeout"
	stub := ext_perm_stub_register(id, .Silent)
	req := ext_perm_req(t, `,"timeout_ms":1000`)
	out := bridge_ext_permission_run(ext_perm_rec(id), req)
	testing.expect_value(t, out.decision, "none") // never "deny"
	testing.expect(t, strings.has_prefix(out.request_id, "perm_"), out.request_id)
	posts := ext_perm_stub_posts(stub)
	testing.expect_value(t, len(posts), 2)
	if len(posts) == 2 {
		testing.expect(t, strings.has_prefix(posts[0], BRIDGE_EXT_PERMISSION_HUB_PATH + " "), posts[0])
		testing.expect(t, strings.contains(posts[0], out.request_id), posts[0])
		testing.expect(t, strings.has_prefix(posts[1], BRIDGE_EXT_PERMISSION_CLOSE_PATH + " "), posts[1])
		testing.expect(t, strings.contains(posts[1], `"reason":"timeout"`), posts[1])
	}
	testing.expect_value(t, ext_perm_pending_count(id), 0)
}

@(test)
test_ext_permission_reply_allow :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	id := "inst_extperm_allow"
	stub := ext_perm_stub_register(id, .Decide, "allow")
	out := bridge_ext_permission_run(ext_perm_rec(id), ext_perm_req(t, `,"timeout_ms":5000`))
	testing.expect_value(t, out.decision, "allow")
	testing.expect_value(t, out.message, "from test")
	// A real decision needs no close call.
	testing.expect_value(t, len(ext_perm_stub_posts(stub)), 1)
	testing.expect_value(t, ext_perm_pending_count(id), 0)
	if inst, ok := bridge_runtime_instance_snapshot(id); ok {
		testing.expect_value(t, inst.activity_source, "claude_extension")
	}
}

@(test)
test_ext_permission_reply_deny :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	id := "inst_extperm_deny"
	_ = ext_perm_stub_register(id, .Decide, "deny")
	out := bridge_ext_permission_run(ext_perm_rec(id), ext_perm_req(t, `,"timeout_ms":5000`))
	testing.expect_value(t, out.decision, "deny")
	testing.expect_value(t, ext_perm_pending_count(id), 0)
	json := bridge_ext_permission_outcome_json(out)
	testing.expect(t, strings.contains(json, `"decision":"deny"`), json)
}

@(test)
test_ext_permission_cancellation_returns_none :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	id := "inst_extperm_cancel"
	stub := ext_perm_stub_register(id, .Cancel)
	out := bridge_ext_permission_run(ext_perm_rec(id), ext_perm_req(t, `,"timeout_ms":5000`))
	testing.expect_value(t, out.decision, "none")
	testing.expect_value(t, out.message, "agent instance stopped")
	posts := ext_perm_stub_posts(stub)
	testing.expect_value(t, len(posts), 2)
	if len(posts) == 2 do testing.expect(t, strings.contains(posts[1], `"reason":"cancelled"`), posts[1])
	testing.expect_value(t, ext_perm_pending_count(id), 0)
}

@(test)
test_ext_permission_hub_down_returns_none_immediately :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	id := "inst_extperm_hubdown"
	_ = ext_perm_stub_register(id, .Hub_Down)
	start := bridge_runtime_now_ms()
	out := bridge_ext_permission_run(ext_perm_rec(id), ext_perm_req(t, `,"timeout_ms":60000`))
	testing.expect_value(t, out.decision, "none")
	testing.expect(t, bridge_runtime_now_ms() - start < 5000, "must not wait for the timeout when the hub is unreachable")
	testing.expect_value(t, ext_perm_pending_count(id), 0)
}

@(test)
test_ext_permission_decision_frame_validation :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	id := "inst_extperm_frame"
	testing.expect(t, bridge_permission_register(Bridge_Permission_Pending{request_id = strings.clone("perm_f1"), agent_instance_id = strings.clone(id)}))
	// Unknown decisions, other instances and unknown ids never resolve a waiter.
	testing.expect(t, !bridge_ext_permission_handle_decision_frame(`{"type":"permission_decision","agent_instance_id":"inst_extperm_frame","request_id":"perm_f1","decision":"none"}`))
	testing.expect(t, !bridge_ext_permission_handle_decision_frame(`{"type":"permission_decision","agent_instance_id":"inst_other","request_id":"perm_f1","decision":"allow"}`))
	testing.expect(t, !bridge_ext_permission_handle_decision_frame(`{"type":"permission_decision","agent_instance_id":"inst_extperm_frame","request_id":"perm_nope","decision":"allow"}`))
	testing.expect(t, bridge_ext_permission_handle_decision_frame(`{"type":"permission_decision","agent_instance_id":"inst_extperm_frame","request_id":"perm_f1","decision":"DENY"}`))
	decision, _, timed_out := bridge_permission_wait_ex(id, "perm_f1", 1000, "none", nil)
	testing.expect_value(t, decision, "deny")
	testing.expect(t, !timed_out)
	spec, known := bridge_command_spec("permission_decision")
	testing.expect(t, known && !spec.queued, "permission_decision is an inline control frame")
}

@(test)
test_ext_permission_legacy_relay_keeps_deny_on_timeout :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	testing.expect_value(t, bridge_permission_normalize_decision("none"), "none")
	testing.expect_value(t, bridge_permission_normalize_decision("garbage"), "deny")
	id := "inst_extperm_legacy"
	testing.expect(t, bridge_permission_register(Bridge_Permission_Pending{request_id = strings.clone("r_legacy"), agent_instance_id = strings.clone(id)}))
	testing.expect_value(t, bridge_permission_cancel_instance(id), 1)
	// The relay reports "none"; bridge_permission_handle_request (the legacy
	// agent.permission.request contract) maps it back to its fail-safe deny.
	decision, _ := bridge_permission_wait(id, "r_legacy", 1000)
	testing.expect_value(t, decision, "none")
}
