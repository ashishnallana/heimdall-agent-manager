package main

import "base:runtime"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"

// REQ-EXT-BLK-1..5: in-memory agent blockers — idempotent re-registration of a
// stable blocker_id (bridge restart rebuild), per-instance snapshots on change,
// clear on stop, terminal-answer auto-resolve and the terminal_prompt fallback.
// Tests run in parallel threads: each uses its own instance id and only ever
// takes snapshots / marks dirty for that id.

// Ext_Blk_Run runs bridge_ext_permission_run on its own thread (it blocks).
Ext_Blk_Run :: struct {
	rec:  Bridge_Local_Agent_Token_Record,
	req:  Bridge_Ext_Permission_Request,
	out:  Bridge_Ext_Permission_Outcome,
	th:   ^thread.Thread,
}

ext_blk_event :: proc(extra: string) -> string {
	return strings.concatenate({`{"schema":"ham.ext.v1","provider":"claude","ext_version":"0.1.0","event":"permission.request","ts":"2026-10-22T06:00:00Z","session_id":"sess-1","agent":{"id":"sub-1","type":"Explore"},"tool":{"name":"Bash","use_id":"tu_9","input":{"command":"rm -rf build"}}`, extra, `}`}, context.temp_allocator)
}

ext_blk_rec :: proc(id: string) -> Bridge_Local_Agent_Token_Record {
	return Bridge_Local_Agent_Token_Record{agent_instance_id = id, instance_token = "tok_test", role = .Agent}
}

ext_blk_req :: proc(t: ^testing.T, extra: string) -> Bridge_Ext_Permission_Request {
	req, msg, ok := bridge_ext_permission_parse(ext_blk_event(extra))
	testing.expectf(t, ok, "parse failed: %s", msg)
	// Keep the strings alive for the runner thread.
	req.provider = strings.clone(req.provider, runtime.heap_allocator())
	req.agent_id = strings.clone(req.agent_id, runtime.heap_allocator())
	req.tool_name = strings.clone(req.tool_name, runtime.heap_allocator())
	req.input = strings.clone(req.input, runtime.heap_allocator())
	req.blocker_id = strings.clone(req.blocker_id, runtime.heap_allocator())
	return req
}

ext_blk_start :: proc(instance_id: string, req: Bridge_Ext_Permission_Request) -> ^Ext_Blk_Run {
	r := new(Ext_Blk_Run, runtime.heap_allocator())
	r.rec = ext_blk_rec(instance_id)
	r.req = req
	r.th = thread.create_and_start_with_data(rawptr(r), proc(data: rawptr) {
		run := (^Ext_Blk_Run)(data)
		run.out = bridge_ext_permission_run(run.rec, run.req)
	})
	return r
}

ext_blk_finish :: proc(r: ^Ext_Blk_Run) -> Bridge_Ext_Permission_Outcome {
	thread.join(r.th)
	thread.destroy(r.th)
	return r.out
}

// ext_blk_wait_count polls until the instance shows want visible blockers.
ext_blk_wait_count :: proc(instance_id: string, want: int, timeout_ms := 3000) -> bool {
	started := time.tick_now()
	for time.duration_milliseconds(time.tick_since(started)) < f64(timeout_ms) {
		if len(bridge_blockers_list(instance_id)) == want do return true
		time.sleep(5 * time.Millisecond)
	}
	return false
}

// ext_blk_wait_blocker polls until blocker_id is visible on the instance.
ext_blk_wait_blocker :: proc(instance_id, blocker_id: string, timeout_ms := 3000) -> bool {
	started := time.tick_now()
	for time.duration_milliseconds(time.tick_since(started)) < f64(timeout_ms) {
		for v in bridge_blockers_list(instance_id) do if v.blocker_id == blocker_id do return true
		time.sleep(5 * time.Millisecond)
	}
	return false
}

ext_blk_take_one :: proc(t: ^testing.T, instance_id: string) -> (frame: Bridge_Blocker_Frame, ok: bool) {
	frames := bridge_blockers_take_snapshots(instance_id, context.temp_allocator)
	testing.expect_value(t, len(frames), 1)
	if len(frames) != 1 do return {}, false
	return frames[0], true
}

ext_blk_decide :: proc(instance_id, blocker_id, decision: string) -> bool {
	frame := strings.concatenate({`{"type":"permission_decision","command_id":"cmd_1","agent_instance_id":"`, instance_id, `","request_id":"`, blocker_id, `","decision":"`, decision, `","message":"from test"}`}, context.temp_allocator)
	return bridge_ext_permission_handle_decision_frame(frame)
}

@(test)
test_ext_blockers_reregistration_is_idempotent_and_supersedes_old_waiter :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	id := "inst_blk_rereg"
	pending := Bridge_Permission_Pending{request_id = strings.clone("blk_rereg"), agent_instance_id = strings.clone(id), tool = "Bash", created_unix_ms = bridge_runtime_now_ms()}
	gen1, refreshed1 := bridge_blockers_register_permission(pending)
	testing.expect_value(t, gen1, 1)
	testing.expect(t, !refreshed1)
	gen2, refreshed2 := bridge_blockers_register_permission(pending)
	testing.expect_value(t, gen2, 2)
	testing.expect(t, refreshed2, "same id + instance refreshes")
	testing.expect_value(t, len(bridge_blockers_list(id)), 1)

	// The older waiter leaves at once; the entry stays for the newer one.
	decision, reason, timed_out := bridge_permission_wait_ex(id, "blk_rereg", 2000, "none", nil, gen1)
	testing.expect_value(t, decision, "none")
	testing.expect(t, strings.contains(reason, "superseded"), reason)
	testing.expect(t, !timed_out)
	testing.expect_value(t, len(bridge_blockers_list(id)), 1)

	testing.expect(t, ext_blk_decide(id, "blk_rereg", "allow"))
	decision, _, _ = bridge_permission_wait_ex(id, "blk_rereg", 2000, "none", nil, gen2)
	testing.expect_value(t, decision, "allow")
	testing.expect_value(t, len(bridge_blockers_list(id)), 0)
}

@(test)
test_ext_blockers_rebuild_after_bridge_restart_with_same_blocker_id :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	id := "inst_blk_restart"
	// First registration: the hook's original call.
	first := ext_blk_start(id, ext_blk_req(t, `,"timeout_ms":1500,"payload":{"blocker_id":"blk_restart_1"}`))
	testing.expect(t, ext_blk_wait_count(id, 1))
	_ = ext_blk_finish(first) // times out (nobody answers)
	testing.expect_value(t, len(bridge_blockers_list(id)), 0)
	_, _ = ext_blk_take_one(t, id)

	// "Bridge restart": the registry is empty and the hook re-registers the SAME id.
	again := ext_blk_start(id, ext_blk_req(t, `,"timeout_ms":5000,"payload":{"blocker_id":"blk_restart_1"}`))
	testing.expect(t, ext_blk_wait_count(id, 1))
	views := bridge_blockers_list(id)
	if len(views) == 1 do testing.expect_value(t, views[0].blocker_id, "blk_restart_1")
	frame, ok := ext_blk_take_one(t, id)
	if ok {
		testing.expect(t, strings.contains(frame.json, `"blocker_id":"blk_restart_1"`), frame.json)
		testing.expect_value(t, frame.count, 1)
	}
	// The hub's decision for that id reaches the re-registered waiter.
	testing.expect(t, ext_blk_decide(id, "blk_restart_1", "deny"))
	out := ext_blk_finish(again)
	testing.expect_value(t, out.decision, "deny")
	testing.expect_value(t, out.request_id, "blk_restart_1")
}

@(test)
test_ext_blockers_snapshot_on_change :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	id := "inst_blk_snapshot"
	run := ext_blk_start(id, ext_blk_req(t, `,"timeout_ms":5000,"payload":{"blocker_id":"blk_snap_1"}`))
	testing.expect(t, ext_blk_wait_count(id, 1))
	frame, ok := ext_blk_take_one(t, id)
	first_rev := frame.revision
	if ok {
		for want in ([]string{`"type":"agent_blockers"`, `"agent_instance_id":"inst_blk_snapshot"`, `"blocker_id":"blk_snap_1"`, `"kind":"permission"`, `"provider":"claude"`, `"agent_id":"sub-1"`, `"tool_name":"Bash"`, `"summary":"Bash: rm -rf build"`, `"input":{"command":"rm -rf build"}`, `"expires_at":"20`}) {
			testing.expectf(t, strings.contains(frame.json, want), "missing %s in %s", want, frame.json)
		}
		bridge_blockers_ack(frame, true)
	}
	// Nothing changed: nothing to send until a heartbeat/reconnect resync.
	testing.expect_value(t, len(bridge_blockers_take_snapshots(id, context.temp_allocator)), 0)
	bridge_blockers_mark_all_dirty(id)
	resync, rok := ext_blk_take_one(t, id)
	if rok {
		testing.expect_value(t, resync.revision, first_rev)
		bridge_blockers_ack(resync, true)
	}

	testing.expect(t, ext_blk_decide(id, "blk_snap_1", "allow"))
	out := ext_blk_finish(run)
	testing.expect_value(t, out.decision, "allow")
	empty, eok := ext_blk_take_one(t, id)
	if eok {
		testing.expect(t, empty.revision > first_rev, "revision grows")
		testing.expect_value(t, empty.count, 0)
		testing.expect(t, strings.contains(empty.json, `"blockers":[]`), empty.json)
		// A failed send is retried; a delivered empty snapshot forgets the instance.
		bridge_blockers_ack(empty, false)
		retry, rok2 := ext_blk_take_one(t, id)
		if rok2 do bridge_blockers_ack(retry, true)
	}
	bridge_blockers_mark_all_dirty(id)
	testing.expect_value(t, len(bridge_blockers_take_snapshots(id, context.temp_allocator)), 0)
}

@(test)
test_ext_blockers_cleared_on_stop :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	id := "inst_blk_stop"
	run := ext_blk_start(id, ext_blk_req(t, `,"timeout_ms":5000`))
	testing.expect(t, ext_blk_wait_count(id, 1))
	bridge_blockers_note_pane_activity("inst_blk_stop_pane", "waiting_user")
	testing.expect_value(t, len(bridge_blockers_list("inst_blk_stop_pane")), 1)

	_ = bridge_permission_cancel_instance(id)
	_ = bridge_permission_cancel_instance("inst_blk_stop_pane")
	out := ext_blk_finish(run)
	testing.expect_value(t, out.decision, "none")
	testing.expect_value(t, out.message, "agent instance stopped")
	testing.expect(t, strings.has_prefix(out.request_id, "blk_"), out.request_id)
	testing.expect_value(t, len(out.request_id), 4 + 24)
	testing.expect_value(t, len(bridge_blockers_list(id)), 0)
	testing.expect_value(t, len(bridge_blockers_list("inst_blk_stop_pane")), 0)
	for inst in ([]string{id, "inst_blk_stop_pane"}) {
		frames := bridge_blockers_take_snapshots(inst, context.temp_allocator)
		testing.expect_value(t, len(frames), 1)
		if len(frames) == 1 do testing.expect_value(t, frames[0].count, 0)
	}
}

@(test)
test_ext_blockers_terminal_answer_auto_resolves :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	id := "inst_blk_terminal"
	run := ext_blk_start(id, ext_blk_req(t, `,"timeout_ms":5000`))
	testing.expect(t, ext_blk_wait_count(id, 1))
	now := bridge_runtime_now_ms()

	// The same call's own PreToolUse may land just after registration: ignored.
	start := contracts.Ext_Event{kind = .Tool_Start, provider = "claude", agent_id = "sub-1", tool_name = "Bash"}
	testing.expect_value(t, bridge_blockers_on_extension_event(id, start, now), 0)
	// Another agent's or another tool's end does not match.
	other := contracts.Ext_Event{kind = .Tool_End, provider = "claude", agent_id = "", tool_name = "Bash"}
	testing.expect_value(t, bridge_blockers_on_extension_event(id, other, now), 0)
	other.agent_id = "sub-1"; other.tool_name = "Edit"
	testing.expect_value(t, bridge_blockers_on_extension_event(id, other, now), 0)
	// The permission_prompt notification is the TUI prompt itself, not an answer.
	notif := contracts.Ext_Event{kind = .Notification, provider = "claude", notification_type = "permission_prompt"}
	testing.expect_value(t, bridge_blockers_on_extension_event(id, notif, now), 0)
	testing.expect_value(t, len(bridge_blockers_list(id)), 1)

	// A PostToolUse for the blocked tool arrives through agent.extension.event.
	res := bridge_ext_ingest(ext_blk_rec(id), `{"schema":"ham.ext.v1","provider":"claude","ext_version":"0.1.0","event":"tool.end","ts":"2026-10-22T06:00:01Z","session_id":"sess-1","agent":{"id":"sub-1"},"tool":{"name":"Bash","use_id":"tu_9"}}`, now)
	bridge_ext_ingest_result_destroy(&res)
	out := ext_blk_finish(run)
	testing.expect_value(t, out.decision, "none") // the hook prints nothing
	testing.expect_value(t, out.message, BRIDGE_BLOCKER_TERMINAL_REASON)
	testing.expect_value(t, len(bridge_blockers_list(id)), 0)

	// tool.start after the grace window and an idle (Stop) both release.
	run2 := ext_blk_start(id, ext_blk_req(t, `,"timeout_ms":5000`))
	testing.expect(t, ext_blk_wait_count(id, 1))
	testing.expect_value(t, bridge_blockers_on_extension_event(id, start, bridge_runtime_now_ms() + BRIDGE_BLOCKER_TOOL_START_GRACE_MS), 1)
	testing.expect_value(t, ext_blk_finish(run2).decision, "none")

	run3 := ext_blk_start(id, ext_blk_req(t, `,"timeout_ms":5000`))
	testing.expect(t, ext_blk_wait_count(id, 1))
	idle := contracts.Ext_Event{kind = .Activity, provider = "claude", activity_state = "idle"}
	testing.expect_value(t, bridge_blockers_on_extension_event(id, idle, bridge_runtime_now_ms()), 1)
	testing.expect_value(t, ext_blk_finish(run3).message, BRIDGE_BLOCKER_TERMINAL_REASON)
}

@(test)
test_ext_blockers_cancel_rpc_releases_own_blocker_only :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	id := "inst_blk_cancel"
	run := ext_blk_start(id, ext_blk_req(t, `,"timeout_ms":5000,"blocker_id":"blk_cancel_1"`))
	testing.expect(t, ext_blk_wait_count(id, 1))
	other := bridge_ext_permission_cancel_rpc("r1", `{"blocker_id":"blk_cancel_1"}`, ext_blk_rec("inst_blk_cancel_other"))
	testing.expect(t, strings.contains(other, `"cancelled":false`), other)
	bad := bridge_ext_permission_cancel_rpc("r2", `{"blocker_id":"bad id!"}`, ext_blk_rec(id))
	testing.expect(t, strings.contains(bad, "bad_request"), bad)
	resp := bridge_ext_permission_cancel_rpc("r3", `{"blocker_id":"blk_cancel_1"}`, ext_blk_rec(id))
	testing.expect(t, strings.contains(resp, `"cancelled":true`), resp)
	out := ext_blk_finish(run)
	testing.expect_value(t, out.decision, "none")
	testing.expect_value(t, out.request_id, "blk_cancel_1")
	testing.expect(t, bridge_agent_method_allowed("agent.extension.permission.cancel"))
}

@(test)
test_ext_blockers_terminal_prompt_fallback_from_pane_diff :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	id := "inst_blk_pane"
	// Screen detection says waiting_user and there is no extension blocker.
	bridge_runtime_note_agent_activity(id, "waiting_user", "pane_diff")
	views := bridge_blockers_list(id)
	testing.expect_value(t, len(views), 1)
	if len(views) == 1 {
		testing.expect_value(t, views[0].kind, BRIDGE_BLOCKER_KIND_TERMINAL_PROMPT)
		testing.expect_value(t, views[0].summary, BRIDGE_BLOCKER_TERMINAL_SUMMARY)
		// No remote answer for a terminal prompt.
		testing.expect(t, !ext_blk_decide(id, views[0].blocker_id, "allow"))
	}
	frame, ok := ext_blk_take_one(t, id)
	if ok do testing.expect(t, strings.contains(frame.json, `"kind":"terminal_prompt"`), frame.json)

	// An extension permission blocker replaces it ...
	run := ext_blk_start(id, ext_blk_req(t, `,"timeout_ms":1200,"payload":{"blocker_id":"blk_pane_1"}`))
	testing.expect(t, ext_blk_wait_blocker(id, "blk_pane_1"))
	views = bridge_blockers_list(id)
	if len(views) == 1 do testing.expect_value(t, views[0].kind, BRIDGE_BLOCKER_KIND_PERMISSION)
	bridge_blockers_note_pane_activity(id, "waiting_user")
	testing.expect_value(t, len(bridge_blockers_list(id)), 1)
	// ... and once the hook deadline passes the TUI prompt is what is left.
	_ = ext_blk_finish(run)
	views = bridge_blockers_list(id)
	testing.expect_value(t, len(views), 1)
	if len(views) == 1 do testing.expect_value(t, views[0].kind, BRIDGE_BLOCKER_KIND_TERMINAL_PROMPT)

	// Leaving waiting_user clears it; "unknown" changes nothing.
	bridge_blockers_note_pane_activity(id, "unknown")
	testing.expect_value(t, len(bridge_blockers_list(id)), 1)
	bridge_runtime_note_agent_activity(id, "active", "pane_diff")
	testing.expect_value(t, len(bridge_blockers_list(id)), 0)
}

@(test)
test_ext_blockers_summary_and_input_cap :: proc(t: ^testing.T) {
	testing.expect_value(t, bridge_blocker_summary("Bash", `{"command":"ls\n-la","description":"list"}`, context.temp_allocator), "Bash: ls -la")
	testing.expect_value(t, bridge_blocker_summary("Edit", `{"file_path":"/a/b.go","old_string":"x"}`, context.temp_allocator), "Edit: /a/b.go")
	testing.expect_value(t, bridge_blocker_summary("Mystery", `{"n":1}`, context.temp_allocator), "Mystery")
	long := strings.repeat("é", 300, context.temp_allocator)
	s := bridge_blocker_summary("Bash", strings.concatenate({`{"command":"`, long, `"}`}, context.temp_allocator), context.temp_allocator)
	testing.expect(t, len(s) <= BRIDGE_BLOCKER_SUMMARY_MAX + len("…"), s)
	testing.expect(t, strings.has_suffix(s, "…"), s)
	big := strings.concatenate({`{"content":"`, strings.repeat("x", BRIDGE_BLOCKER_INPUT_MAX, context.temp_allocator), `"}`}, context.temp_allocator)
	testing.expect_value(t, bridge_blocker_cap_input(big), `{"truncated":true}`)
	testing.expect_value(t, bridge_blocker_cap_input(`{"a":1}`), `{"a":1}`)
	testing.expect_value(t, bridge_blocker_cap_input(`[1]`), "{}")
	testing.expect(t, bridge_blocker_valid_id("blk_0123abcd"))
	testing.expect(t, !bridge_blocker_valid_id(""))
	testing.expect(t, !bridge_blocker_valid_id("a b"))
}
