package agent

import "base:runtime"
import "core:net"
import events "odin_test:hub/service/events"
import ws "odin_test:lib/ws"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

@(private = "file")
live_test_inst :: domain.Agent_Instance{agent_instance_id = "live_a", owner_user_id = "owner",
	agent_id = "agent_worker", display_name = "Worker A", chain_id = "chain_a", provider_session_id = "s1", runtime_status = "running"}
@(private = "file")
live_test_service :: proc() -> Agent_Service {
	s := Agent_Service{}
	s.tool_live.epoch, _ = tool_live_ns("2026-01-01T00:00:00Z")
	return s
}
@(private = "file")
live_ev :: proc(kind, id: string, sec: int, agent := "", session := "s1", payload := "{}") -> domain.Agent_Extension_Event {
	return domain.Agent_Extension_Event{event = kind, ts = fmt.tprintf("2026-01-01T00:00:%02dZ", sec),
	session_id = session, agent_id = agent, tool_use_id = id, tool_name = "Read", payload = payload}
}
@(private = "file")
live_send :: proc(s: ^Agent_Service, ev: domain.Agent_Extension_Event) {
	tool_live_extension(s, live_test_inst, []domain.Agent_Extension_Event{ev})
}
@(private = "file")
live_obj :: proc(s: ^Agent_Service) -> json.Object {
	body := tool_live_snapshot(s, live_test_inst)
	defer delete(body)
	v, _ := json.parse_string(body, .JSON, true, context.temp_allocator)
	obj, _ := v.(json.Object)
	return obj
}

@(test)
test_live_parallel_calls_deduplicate_and_final_empty_snapshot :: proc(t: ^testing.T) {
	s := live_test_service()
	defer tool_live_destroy(&s.tool_live)
	live_send(&s, live_ev("tool.start", "x", 1))
	live_send(&s, live_ev("tool.start", "x", 1))
	live_send(&s, live_ev("tool.start", "x", 1, "child"))
	obj := live_obj(&s)
	testing.expect_value(t, len(obj["active"].(json.Array)), 2)
	testing.expect_value(t, obj["revision"].(json.Integer), 2)
	live_send(&s, live_ev("tool.end", "x", 4))
	live_send(&s, live_ev("tool.end", "x", 4))
	obj = live_obj(&s)
	testing.expect_value(t, len(obj["active"].(json.Array)), 1)
	testing.expect_value(t, obj["revision"].(json.Integer), 3)
	live_send(&s, live_ev("tool.end", "x", 5, "child", payload = `{"is_error":true}`))
	obj = live_obj(&s)
	active, array := obj["active"].(json.Array)
	testing.expect(t, array, "final snapshot contains an array")
	testing.expect_value(t, len(active), 0)
	last := obj["last_completion"].(json.Object)
	testing.expect_value(t, last["duration_ms"].(json.Integer), 4000)
	testing.expect_value(t, last["status"].(json.String), "failed")
	live_send(&s, live_ev("tool.start", "x", 1))
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 0)
}

@(test)
test_live_end_before_start_and_stale_end_do_not_leave_phantom :: proc(t: ^testing.T) {
	s := live_test_service()
	defer tool_live_destroy(&s.tool_live)
	live_send(&s, live_ev("tool.end", "late", 4))
	live_send(&s, live_ev("tool.start", "late", 1))
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 0)
	live_send(&s, live_ev("tool.start", "valid", 5))
	live_send(&s, live_ev("tool.end", "valid", 3))
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 1)
	live_send(&s, live_ev("tool.end", "valid", 6))
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 0)
}

@(test)
test_live_session_change_terminal_and_restart_fence_history :: proc(t: ^testing.T) {
	s := live_test_service()
	defer tool_live_destroy(&s.tool_live)
	live_send(&s, live_ev("tool.start", "old", 1))
	live_send(&s, live_ev("session", "", 3, session = "s2"))
	live_send(&s, live_ev("hello", "", 1, session = "s1"))
	live_send(&s, live_ev("tool.start", "old", 2))
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 0)
	live_send(&s, live_ev("tool.start", "new", 4, session = "s2"))
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 1)
	live_send(&s, live_ev("session", "", 5, session = "s2", payload = `{"phase":"end"}`))
	live_send(&s, live_ev("tool.start", "after_end", 6, session = "s2"))
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 0)
	notify_instance_terminal(&s, "live_a")
	live_send(&s, live_ev("tool.start", "delayed", 6, session = "s2"))
	obj := live_obj(&s)
	testing.expect_value(t, len(obj["active"].(json.Array)), 0)
	_, no_completion := obj["last_completion"].(json.Null)
	testing.expect(t, no_completion, "unfinished calls never become completed")
	fresh := Agent_Service{}
	tool_live_init(&fresh.tool_live)
	defer tool_live_destroy(&fresh.tool_live)
	live_send(&fresh, live_ev("tool.start", "historical_outbox", 6))
	testing.expect_value(t, len(live_obj(&fresh)["active"].(json.Array)), 0)
	old_epoch := s.tool_live.epoch
	testing.expect(t, fresh.tool_live.epoch != old_epoch, "new Hub epoch")
}

@(test)
test_live_bounds_tombstones_and_subagent_cleanup :: proc(t: ^testing.T) {
	s := live_test_service()
	defer tool_live_destroy(&s.tool_live)
	for i in 0..<TOOL_LIVE_MAX_ACTIVE+10 do live_send(&s, live_ev("tool.start", fmt.tprintf("call_%d", i), 1, "child"))
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), TOOL_LIVE_MAX_ACTIVE)
	live_send(&s, live_ev("subagent.stop", "", 3, "child"))
	live_send(&s, live_ev("tool.start", "unseen_delayed", 2, "child"))
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 0)
	for i in 0..<TOOL_LIVE_MAX_TOMBSTONES+20 do live_send(&s, live_ev("tool.end", fmt.tprintf("missing_%d", i), 5))
	e := s.tool_live.entries["live_a"]
	testing.expect_value(t, len(e.tombstones), TOOL_LIVE_MAX_TOMBSTONES)
	live_send(&s, live_ev("tool.start", "call_0", 1, "child"))
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 0)
}

@(test)
test_live_shell_completion_and_no_row_resurrection :: proc(t: ^testing.T) {
	s := live_test_service()
	defer tool_live_destroy(&s.tool_live)
	row := domain.Shell_Session{session_id = "sh_1", kind = "run", agent_instance_id = "live_a", owner_user_id = "owner"}
	tool_live_shell(&s, row, true)
	tool_live_shell(&s, row, true)
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 1)
	row.status = "killed"
	tool_live_shell(&s, row, false)
	tool_live_shell(&s, row, false)
	obj := live_obj(&s)
	testing.expect_value(t, len(obj["active"].(json.Array)), 0)
	last := obj["last_completion"].(json.Object)
	testing.expect_value(t, last["status"].(json.String), "killed")
	notify_instance_terminal(&s, "live_a")
	tool_live_shell(&s, row, false)
	obj = live_obj(&s)
	testing.expect_value(t, len(obj["active"].(json.Array)), 0)
	_, null_last := obj["last_completion"].(json.Null)
	testing.expect(t, null_last, "late shell exit cannot reconstruct lost activity")
}

@(test)
test_live_concurrent_publish_and_snapshot :: proc(t: ^testing.T) {
	s := live_test_service()
	defer tool_live_destroy(&s.tool_live)
	Job :: struct { service: ^Agent_Service, id: int }
	jobs: [8]Job
	threads: [8]^thread.Thread
	for &job, i in jobs {
		job = Job{&s, i}
		threads[i] = thread.create_and_start_with_data(&job, proc(data: rawptr) {
			job := (^Job)(data)
			for i in 0..<10 {
				id := fmt.tprintf("t%d_%d", job.id, i)
				live_send(job.service, live_ev("tool.start", id, 1))
				body := tool_live_snapshot(job.service, live_test_inst); delete(body)
				live_send(job.service, live_ev("tool.end", id, 2))
			}
		})
	}
	for th in threads { thread.join(th); thread.destroy(th) }
	obj := live_obj(&s)
	testing.expect_value(t, len(obj["active"].(json.Array)), 0)
	testing.expect_value(t, obj["revision"].(json.Integer), 160)
}

// Membership is read from the same repository source used by task dispatch.
@(private = "file")
Live_Chain_Test :: struct { rows: []domain.Agent_Instance, members: []domain.Task_Chain_Member, coordinator_id: string }
@(private = "file")
live_chain_get :: proc(ctx: rawptr, id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	return domain.Task_Chain{chain_id = id, owner_user_id = "owner", coordinator_agent_instance_id = (^Live_Chain_Test)(ctx).coordinator_id}, true, {}
}
@(private = "file")
live_chain_members :: proc(ctx: rawptr, id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task_Chain_Member, domain.Domain_Error) {
	return (^Live_Chain_Test)(ctx).members, {}
}
@(private = "file")
live_chain_instances :: proc(ctx: rawptr, owner: domain.User_ID, chain: string) -> ([]domain.Agent_Instance, domain.Domain_Error) {
	return (^Live_Chain_Test)(ctx).rows, {} // deliberately includes foreign rows: filter must defend
}
@(private = "file")
live_chain_instance :: proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	for inst in (^Live_Chain_Test)(ctx).rows do if inst.agent_instance_id == id do return inst, true, {}
	return {}, false, domain.domain_error(.Not_Found, "not found")
}
@(test)
test_live_chain_isolation_membership_and_reconnect :: proc(t: ^testing.T) {
	s := live_test_service()
	defer tool_live_destroy(&s.tool_live)
	rows := [4]domain.Agent_Instance{live_test_inst, live_test_inst, live_test_inst, live_test_inst}
	rows[1].agent_instance_id = "reviewer_a" // same durable identity; separate run
	rows[2].agent_instance_id = "unrelated"; rows[2].chain_id = "chain_b"
	rows[3].agent_instance_id = "foreign"; rows[3].owner_user_id = "other"
	fixture := Live_Chain_Test{rows = rows[:]}
	repo := iface.Agent_Repository{ctx = &fixture, list_instances_by_chain = live_chain_instances, get_instance = live_chain_instance}
	chains := iface.Taskchain_Repository{ctx = &fixture, get_chain = live_chain_get, list_members_by_chain = live_chain_members}
	s.agents = &repo; s.taskchains = &chains
	live_send(&s, live_ev("tool.start", "chain_tool", 1))
	auth := contracts.Auth_Context{kind = .User_Token, user_id = "owner"}
	body, ok, _ := tool_live_chain_snapshot(&s, auth, "chain_a")
	testing.expect(t, ok)
	value, _ := json.parse_string(body, .JSON, true, context.temp_allocator)
	delete(body)
	obj := value.(json.Object)
	members := obj["members"].(json.Array)
	testing.expect_value(t, len(members), 2)
	testing.expect_value(t, members[0].(json.Object)["instance_id"].(json.String), "live_a")
	live_send(&s, live_ev("tool.end", "chain_tool", 2))
	body, ok, _ = tool_live_chain_snapshot(&s, auth, "chain_a")
	testing.expect(t, ok)
	value, _ = json.parse_string(body, .JSON, true, context.temp_allocator)
	delete(body)
	members = value.(json.Object)["members"].(json.Array)
	first := members[0].(json.Object)["snapshot"].(json.Object)
	testing.expect_value(t, len(first["active"].(json.Array)), 0)
	testing.expect_value(t, first["last_completion"].(json.Object)["duration_ms"].(json.Integer), 1000)
	rows[1].chain_id = "chain_b"
	body, _, _ = tool_live_chain_snapshot(&s, auth, "chain_a")
	value, _ = json.parse_string(body, .JSON, true, context.temp_allocator); delete(body)
	testing.expect_value(t, len(value.(json.Object)["members"].(json.Array)), 1)
	_, foreign_ok, _ := tool_live_chain_snapshot(&s, contracts.Auth_Context{kind = .User_Token, user_id = "other"}, "chain_a")
	testing.expect(t, !foreign_ok, "foreign owner rejected")
	_, unrelated_ok, _ := tool_live_chain_snapshot(&s, contracts.Auth_Context{kind = .Instance_Token, user_id = "owner", agent_instance_id = "unrelated"}, "chain_a")
	testing.expect(t, !unrelated_ok, "unrelated-chain instance rejected")
	fixture.members = []domain.Task_Chain_Member{{chain_id = "chain_a", owner_user_id = "owner", role = "coordinator", agent_instance_id = "unrelated"}}
	coordinator_auth := contracts.Auth_Context{kind = .Instance_Token, user_id = "owner", agent_instance_id = "unrelated"}
	coordinator_body, coordinator_ok, _ := tool_live_chain_snapshot(&s, coordinator_auth, "chain_a")
	testing.expect(t, coordinator_ok, "explicit coordinator may coordinate multiple chains")
	if coordinator_ok {
		value, _ = json.parse_string(coordinator_body, .JSON, true, context.temp_allocator)
		testing.expect_value(t, len(value.(json.Object)["members"].(json.Array)), 2)
		delete(coordinator_body)
	}
	fixture.members = nil
	_, removed_ok, _ := tool_live_chain_snapshot(&s, coordinator_auth, "chain_a")
	testing.expect(t, !removed_ok, "removing coordinator membership revokes cross-chain access")
	fixture.coordinator_id = "unrelated"
	canonical_body, canonical_ok, _ := tool_live_chain_snapshot(&s, coordinator_auth, "chain_a")
	testing.expect(t, canonical_ok, "canonical chain coordinator field grants access")
	delete(canonical_body)
}


@(test)
test_live_explicit_shell_correlation_and_unrelated_calls :: proc(t: ^testing.T) {
	s := live_test_service()
	defer tool_live_destroy(&s.tool_live)
	row := domain.Shell_Session{session_id = "sh_link", kind = "run", agent_instance_id = "live_a", owner_user_id = "owner", exit_code_set = true}
	live_send(&s, live_ev("tool.start", "wrapper", 1, payload = `{"shell_session_id":"sh_link","shell_run_seq":0}`))
	tool_live_shell(&s, row, true)
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 1)
	live_send(&s, live_ev("tool.end", "wrapper", 2))
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 1)
	// Same tool name without explicit shell identity remains a distinct call.
	live_send(&s, live_ev("tool.start", "unrelated", 2))
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 2)
	row.status = "exited"
	tool_live_shell(&s, row, false)
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 1)
	live_send(&s, live_ev("tool.end", "unrelated", 3))
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 0)
	// Delayed provider retry cannot resurrect the already-completed explicit shell.
	live_send(&s, live_ev("tool.start", "wrapper", 1, payload = `{"shell_session_id":"sh_link"}`))
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 0)
	row.session_id = "sh_reverse"
	tool_live_shell(&s, row, true)
	live_send(&s, live_ev("tool.start", "reverse", 4, payload = `{"shell_session_id":"sh_reverse"}`))
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 1)
	live_send(&s, live_ev("tool.end", "reverse", 5))
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 1)
	tool_live_shell(&s, row, false)
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 0)
}

@(test)
test_live_provider_duration_and_error_status :: proc(t: ^testing.T) {
	s := live_test_service()
	defer tool_live_destroy(&s.tool_live)
	live_send(&s, live_ev("tool.start", "duration", 1))
	live_send(&s, live_ev("tool.end", "duration", 1, payload = `{"status":"error","duration_ms":57}`))
	last := live_obj(&s)["last_completion"].(json.Object)
	testing.expect_value(t, last["duration_ms"].(json.Integer), 57)
	testing.expect_value(t, last["status"].(json.String), "failed")
}


@(test)
test_live_global_memory_cap :: proc(t: ^testing.T) {
	s := live_test_service()
	defer tool_live_destroy(&s.tool_live)
	// Pin the same store allocator used by production mutation paths.
	context.allocator = runtime.heap_allocator()
	for i in 0..<TOOL_LIVE_MAX_INSTANCES+10 {
		_ = tool_live_entry_locked(&s.tool_live, fmt.tprintf("bounded_%d", i), "owner")
	}
	testing.expect_value(t, len(s.tool_live.entries), TOOL_LIVE_MAX_INSTANCES)
}


@(private = "file")
Live_Pair :: struct { listener, peer, hub: net.TCP_Socket }
@(private = "file")
live_pair :: proc(t: ^testing.T) -> Live_Pair {
	listener, le := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if le != nil do testing.fail_now(t, "listen failed")
	bound, be := net.bound_endpoint(listener)
	if be != nil { net.close(listener); testing.fail_now(t, "bound endpoint failed") }
	peer, de := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	if de != nil { net.close(listener); testing.fail_now(t, "dial failed") }
	hub, _, ae := net.accept_tcp(listener)
	if ae != nil { net.close(listener); net.close(peer); testing.fail_now(t, "accept failed") }
	return Live_Pair{listener, peer, hub}
}
@(private = "file")
live_close_pair :: proc(p: Live_Pair) {
	net.close(p.hub); net.close(p.peer); net.close(p.listener)
}
@(test)
test_live_owner_ws_empty_transition_and_reconnect_snapshot :: proc(t: ^testing.T) {
	s := live_test_service()
	defer tool_live_destroy(&s.tool_live)
	bus: events.User_Event_Bus
	s.event_bus = &bus
	mine := live_pair(t); defer live_close_pair(mine)
	other := live_pair(t); defer live_close_pair(other)
	my_handle, attached := events.user_ws_attach(&bus, "owner", mine.hub)
	testing.expect_value(t, attached, events.User_WS_Attach_Result.Attached)
	defer events.user_ws_detach(&bus, my_handle)
	other_handle, other_attached := events.user_ws_attach(&bus, "other", other.hub)
	testing.expect_value(t, other_attached, events.User_WS_Attach_Result.Attached)
	defer events.user_ws_detach(&bus, other_handle)
	my_reader := ws.reader_make(); defer ws.reader_destroy(&my_reader)
	other_reader := ws.reader_make(); defer ws.reader_destroy(&other_reader)
	_, ready, ready_ok := ws.read_frame(mine.peer, &my_reader, time.Second)
	testing.expect(t, ready_ok && strings.contains(ready, "user_ws_ready"))
	first_ready := strings.clone(ready); defer delete(first_ready)
	delete(ready)
	_, other_ready, other_ready_ok := ws.read_frame(other.peer, &other_reader, time.Second)
	testing.expect(t, other_ready_ok)
	delete(other_ready)
	live_send(&s, live_ev("tool.start", "ws_1", 1))
	_, frame, frame_ok := ws.read_frame(mine.peer, &my_reader, time.Second)
	testing.expect(t, frame_ok && strings.contains(frame, "tool_activity_live"))
	value, parse_err := json.parse_string(frame, .JSON, true, context.temp_allocator)
	testing.expect_value(t, parse_err, json.Error.None)
	obj := value.(json.Object)
	testing.expect_value(t, len(obj["active"].(json.Array)), 1)
	_, _, leaked := ws.read_frame(other.peer, &other_reader, 30 * time.Millisecond)
	testing.expect(t, !leaked, "other owner's socket receives no tool activity")
	delete(frame)
	live_send(&s, live_ev("tool.end", "ws_1", 2))
	_, frame, frame_ok = ws.read_frame(mine.peer, &my_reader, time.Second)
	testing.expect(t, frame_ok)
	value, _ = json.parse_string(frame, .JSON, true, context.temp_allocator)
	obj = value.(json.Object)
	testing.expect_value(t, len(obj["active"].(json.Array)), 0)
	testing.expect_value(t, obj["revision"].(json.Integer), 2)
	testing.expect_value(t, obj["last_completion"].(json.Object)["duration_ms"].(json.Integer), 1000)
	delete(frame)
	events.user_ws_detach(&bus, my_handle)
	live_send(&s, live_ev("tool.start", "missed_while_offline", 3))
	reconnected := live_pair(t); defer live_close_pair(reconnected)
	handle2, attached2 := events.user_ws_attach(&bus, "owner", reconnected.hub)
	testing.expect_value(t, attached2, events.User_WS_Attach_Result.Attached)
	defer events.user_ws_detach(&bus, handle2)
	reader2 := ws.reader_make(); defer ws.reader_destroy(&reader2)
	_, ready2, ready2_ok := ws.read_frame(reconnected.peer, &reader2, time.Second)
	testing.expect(t, ready2_ok && ready2 != first_ready, "reconnect gets a new stream epoch")
	delete(ready2)
	recovered := live_obj(&s)
	testing.expect_value(t, len(recovered["active"].(json.Array)), 1)
	testing.expect_value(t, recovered["revision"].(json.Integer), 3)
	live_send(&s, live_ev("tool.end", "missed_while_offline", 4))
	_, frame, frame_ok = ws.read_frame(reconnected.peer, &reader2, time.Second)
	testing.expect(t, frame_ok)
	value, _ = json.parse_string(frame, .JSON, true, context.temp_allocator)
	obj = value.(json.Object)
	testing.expect_value(t, len(obj["active"].(json.Array)), 0)
	testing.expect_value(t, obj["revision"].(json.Integer), 4)
	delete(frame)
}



@(test)
test_live_bridge_loss_and_superseded_launch_are_fenced :: proc(t: ^testing.T) {
 rows := [1]domain.Agent_Instance{live_test_inst}
 fixture := Live_Chain_Test{rows = rows[:]}
 repo := iface.Agent_Repository{ctx = &fixture, get_instance = live_chain_instance}
 s := live_test_service()
 s.agents = &repo
 defer tool_live_destroy(&s.tool_live)
 live_send(&s, live_ev("tool.start", "before_bridge_loss", 1))
 rows[0].runtime_status = "unreachable"
 notify_instances_terminal(&s, rows[:])
 live_send(&s, live_ev("tool.start", "delayed_after_bridge_loss", 2))
 testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 0)
 rows[0].runtime_status = "running"
 rows[0].run_count = 1
 rows[0].launch_epoch = "new_launch"
 ev := live_ev("tool.start", "new_launch_call", 3)
 ev.ts = platform.format_rfc3339_utc(time.time_add(time.now(), time.Second))
 // An authenticated old request that waited on the projection mutex cannot
 // insert after a newer configuration/launch overtakes it.
 tool_live_extension(&s, live_test_inst, []domain.Agent_Extension_Event{ev})
 testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 0)
 tool_live_extension(&s, rows[0], []domain.Agent_Extension_Event{ev})
 testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 1)
}
