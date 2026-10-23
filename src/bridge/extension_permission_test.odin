package main

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:testing"

// REQ-EXT-PERM-1: agent.extension.permission blocks until the hub pushes a user
// decision; timeout and cancellation return "none" (never deny). Nothing is
// posted to the hub per request: the blocker reaches it as an in-memory
// agent_blockers snapshot (extension_blockers_test.odin). Helpers ext_blk_* live
// there.

@(private = "file")
ext_perm_event :: proc(extra: string) -> string {
	return ext_blk_event(extra)
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

	testing.expect_value(t, req2.blocker_id, "")

	// A stable blocker_id rides in payload (or top level) and must be a safe id.
	req3, _, ok3 := bridge_ext_permission_parse(ext_perm_event(`,"payload":{"blocker_id":"blk_00aa"}`))
	testing.expect(t, ok3)
	testing.expect_value(t, req3.blocker_id, "blk_00aa")
	req4, _, ok4 := bridge_ext_permission_parse(ext_perm_event(`,"blocker_id":"blk_top"`))
	testing.expect(t, ok4)
	testing.expect_value(t, req4.blocker_id, "blk_top")
	_, bad_msg, bad_ok := bridge_ext_permission_parse(ext_perm_event(`,"payload":{"blocker_id":"no spaces"}`))
	testing.expect(t, !bad_ok)
	testing.expect(t, strings.contains(bad_msg, "blocker_id"), bad_msg)
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
test_ext_permission_timeout_returns_none :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	id := "inst_extperm_timeout"
	out := bridge_ext_permission_run(ext_blk_rec(id), ext_blk_req(t, `,"timeout_ms":1000`))
	testing.expect_value(t, out.decision, "none") // never "deny"
	testing.expect(t, strings.has_prefix(out.request_id, "blk_"), out.request_id)
	testing.expect_value(t, ext_perm_pending_count(id), 0)
	json := bridge_ext_permission_outcome_json(out)
	testing.expect(t, strings.contains(json, `"blocker_id":"blk_`), json)
}

@(test)
test_ext_permission_reply_allow :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	id := "inst_extperm_allow"
	run := ext_blk_start(id, ext_blk_req(t, `,"timeout_ms":5000,"payload":{"blocker_id":"blk_allow"}`))
	testing.expect(t, ext_blk_wait_count(id, 1))
	testing.expect(t, ext_blk_decide(id, "blk_allow", "allow"))
	out := ext_blk_finish(run)
	testing.expect_value(t, out.decision, "allow")
	testing.expect_value(t, out.message, "from test")
	testing.expect_value(t, ext_perm_pending_count(id), 0)
	if inst, ok := bridge_runtime_instance_snapshot(id); ok {
		testing.expect_value(t, inst.activity_source, "claude_extension")
	}
}

@(test)
test_ext_permission_reply_deny :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	id := "inst_extperm_deny"
	run := ext_blk_start(id, ext_blk_req(t, `,"timeout_ms":5000,"payload":{"blocker_id":"blk_deny"}`))
	testing.expect(t, ext_blk_wait_count(id, 1))
	testing.expect(t, ext_blk_decide(id, "blk_deny", "deny"))
	out := ext_blk_finish(run)
	testing.expect_value(t, out.decision, "deny")
	testing.expect_value(t, ext_perm_pending_count(id), 0)
	json := bridge_ext_permission_outcome_json(out)
	testing.expect(t, strings.contains(json, `"decision":"deny"`), json)
}

@(test)
test_ext_permission_cancellation_returns_none :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	id := "inst_extperm_cancel"
	run := ext_blk_start(id, ext_blk_req(t, `,"timeout_ms":5000`))
	testing.expect(t, ext_blk_wait_count(id, 1))
	testing.expect_value(t, bridge_permission_cancel_instance(id), 1)
	out := ext_blk_finish(run)
	testing.expect_value(t, out.decision, "none")
	testing.expect_value(t, out.message, "agent instance stopped")
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
