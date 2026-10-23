package tool_live

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

@(private = "file")
live_test_inst :: Instance{agent_instance_id = "live_a", owner_user_id = "owner",
	agent_id = "agent_worker", display_name = "Worker A", chain_id = "chain_a", provider_session_id = "s1", runtime_status = "running"}
@(private = "file")
live_test_service :: proc() -> Tracker {
	s := Tracker{}
	s.tool_live.epoch, _ = tool_live_ns("2026-01-01T00:00:00Z")
	return s
}
@(private = "file")
live_ev :: proc(kind, id: string, sec: int, agent := "", session := "s1", payload := "{}") -> Event {
	return Event{event = kind, ts = fmt.tprintf("2026-01-01T00:00:%02dZ", sec),
	session_id = session, agent_id = agent, tool_use_id = id, tool_name = "Read", payload = payload}
}
@(private = "file")
live_send :: proc(s: ^Tracker, ev: Event) {
	tool_live_extension(s, live_test_inst, []Event{ev})
}
@(private = "file")
live_obj :: proc(s: ^Tracker) -> json.Object {
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
	last := live_last(obj)
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
	tool_live_clear(&s, "live_a")
	live_send(&s, live_ev("tool.start", "delayed", 6, session = "s2"))
	obj := live_obj(&s)
	testing.expect_value(t, len(obj["active"].(json.Array)), 0)
	no_completion := len(obj["completed_since_last"].(json.Array)) == 0
	testing.expect(t, no_completion, "unfinished calls never become completed")
	fresh := Tracker{}
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
	row := Shell{session_id = "sh_1", kind = "run", agent_instance_id = "live_a", owner_user_id = "owner"}
	tool_live_shell(&s, row, true)
	tool_live_shell(&s, row, true)
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 1)
	row.status = "killed"
	tool_live_shell(&s, row, false)
	tool_live_shell(&s, row, false)
	obj := live_obj(&s)
	testing.expect_value(t, len(obj["active"].(json.Array)), 0)
	last := live_last(obj)
	testing.expect_value(t, last["status"].(json.String), "killed")
	tool_live_clear(&s, "live_a")
	tool_live_shell(&s, row, false)
	obj = live_obj(&s)
	testing.expect_value(t, len(obj["active"].(json.Array)), 0)
	null_last := len(obj["completed_since_last"].(json.Array)) == 0
	testing.expect(t, null_last, "late shell exit cannot reconstruct lost activity")
}

@(test)
test_live_concurrent_publish_and_snapshot :: proc(t: ^testing.T) {
	s := live_test_service()
	defer tool_live_destroy(&s.tool_live)
	Job :: struct { service: ^Tracker, id: int }
	jobs: [8]Job
	threads: [8]^thread.Thread
	for &job, i in jobs {
		job = Job{&s, i}
		threads[i] = thread.create_and_start_with_data(&job, proc(data: rawptr) {
			job := (^Job)(data)
			for i in 0..<3 {
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
	testing.expect_value(t, obj["revision"].(json.Integer), 48)
}

@(test)
test_live_explicit_shell_correlation_and_unrelated_calls :: proc(t: ^testing.T) {
	s := live_test_service()
	defer tool_live_destroy(&s.tool_live)
	row := Shell{session_id = "sh_link", kind = "run", agent_instance_id = "live_a", owner_user_id = "owner", exit_code_set = true}
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
	last := live_last(live_obj(&s))
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
		evicted: Tool_Live_Publication
		e := tool_live_entry_locked(&s, fmt.tprintf("bounded_%d", i), "owner", &evicted)
		testing.expect(t, e != nil, "inactive capacity is reclaimable")
		tool_live_publish_eviction(&s, evicted)
	}
	testing.expect_value(t, len(s.tool_live.entries), TOOL_LIVE_MAX_INSTANCES)
}


@(test)
test_live_churn_reclaims_inactive_preserves_revisions_and_replay_fences :: proc(t: ^testing.T) {
	s := live_test_service()
	defer tool_live_destroy(&s.tool_live)
	live_send(&s, live_ev("tool.start", "finished", 1))
	live_send(&s, live_ev("tool.end", "finished", 2))
	old := live_obj(&s)
	old_revision := old["revision"].(json.Integer)
	// Keep one unrelated active instance throughout reclamation.
	pinned := live_test_inst; pinned.agent_instance_id = "pinned"
	tool_live_extension(&s, pinned, []Event{live_ev("tool.start", "running", 1)})
	for i in 0..<TOOL_LIVE_MAX_INSTANCES+20 {
		inst := live_test_inst; inst.agent_instance_id = fmt.tprintf("churn_%d", i)
		tool_live_extension(&s, inst, []Event{live_ev("hello", "", 1)})
	}
	testing.expect_value(t, len(s.tool_live.entries), TOOL_LIVE_MAX_INSTANCES)
	testing.expect_value(t, len(s.tool_live.entries["pinned"].active), 1)
	_, retained := s.tool_live.entries["live_a"]
	testing.expect(t, !retained, "old inactive entry was reclaimed")
	empty := live_obj(&s)
	testing.expect(t, empty["revision"].(json.Integer) > old_revision, "reconnect snapshot fences old buffered revisions")
	live_send(&s, live_ev("hello", "", 1))
	live_send(&s, live_ev("tool.start", "forgotten_retry", 3))
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 0)
	ev := live_ev("tool.start", "admitted_after_churn", 4)
	ev.ts = live_future_ts()
	live_send(&s, ev)
	current := live_obj(&s)
	testing.expect_value(t, len(current["active"].(json.Array)), 1)
	testing.expect(t, current["revision"].(json.Integer) > empty["revision"].(json.Integer))
	testing.expect_value(t, len(s.tool_live.entries), TOOL_LIVE_MAX_INSTANCES)
}

@(test)
test_live_all_active_capacity_recovers_and_retains_unseen_cutoff :: proc(t: ^testing.T) {
	s := live_test_service()
	defer tool_live_destroy(&s.tool_live)
	// Fill with genuinely active entries; pressure must not evict a running call.
	for i in 0..<TOOL_LIVE_MAX_INSTANCES {
		inst := live_test_inst; inst.agent_instance_id = fmt.tprintf("busy_%d", i)
		tool_live_extension(&s, inst, []Event{live_ev("tool.start", "running", 1)})
	}
	tool_live_clear(&s, "live_a")
	live_send(&s, live_ev("tool.start", "refused_at_capacity", 2))
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 0)
	// One completion makes room. The unseen instance's previous launch is fenced.
	inst := live_test_inst; inst.agent_instance_id = "busy_0"
	tool_live_extension(&s, inst, []Event{live_ev("tool.end", "running", 3)})
	live_send(&s, live_ev("tool.start", "buffered_old_launch", 2))
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 0)
	ev := live_ev("tool.start", "new_launch", 4)
	ev.ts = live_future_ts()
	live_send(&s, ev)
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 1)
	testing.expect_value(t, len(s.tool_live.entries), TOOL_LIVE_MAX_INSTANCES)
}

live_future_ts :: proc() -> string {
	t := time.time_add(time.now(), time.Second)
	y, m, d := time.date(t); h, mi, se := time.clock(t)
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, int(m), d, h, mi, se)
}
@(test)
test_live_unseen_terminal_before_first_batch :: proc(t: ^testing.T) {
	s := live_test_service()
	defer tool_live_destroy(&s.tool_live)
	tool_live_clear(&s, "live_a")
	live_send(&s, live_ev("hello", "", 1))
	live_send(&s, live_ev("tool.start", "buffered_old_launch", 2))
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 0)
	ev := live_ev("tool.start", "fresh", 3); ev.ts = live_future_ts()
	live_send(&s, ev)
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 1)
}
@(test)
test_live_shell_restart_tracks_only_new_run :: proc(t: ^testing.T) {
	s := live_test_service()
	defer tool_live_destroy(&s.tool_live)
	row := Shell{session_id = "sh_restart", kind = "run", agent_instance_id = "live_a", owner_user_id = "owner"}
	tool_live_shell(&s, row, true)
	row.run_seq = 1
	tool_live_shell(&s, row, true, 0)
	obj := live_obj(&s)
	active := obj["active"].(json.Array)
	testing.expect_value(t, len(active), 1)
	if len(active) == 1 do testing.expect_value(t, active[0].(json.Object)["shell_run_seq"].(json.Integer), 1)
	no_inferred_completion := len(obj["completed_since_last"].(json.Array)) == 0
	testing.expect(t, no_inferred_completion)
	old := row; old.run_seq = 0; old.status = "exited"; old.exit_code_set = true
	tool_live_shell(&s, old, false)
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 1)
	row.status = "exited"; row.exit_code_set = true
	tool_live_shell(&s, row, false)
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 0)
	// A completed run may also be restarted.
	row.run_seq = 2
	tool_live_shell(&s, row, true, 1)
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 1)
	old = row; old.run_seq = 1
	tool_live_shell(&s, old, false)
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 1)
	tool_live_shell(&s, row, false)
	testing.expect_value(t, len(live_obj(&s)["active"].(json.Array)), 0)
}

@(test)
test_live_owned_byte_and_wire_budgets :: proc(t:^testing.T) {
 // Conservative string/content + dynamic backing bounds. This intentionally
 // overcounts fields and capacities; allocator bookkeeping/RSS is platform-owned.
 max_call := MAX_KEY_BYTES + 6*TOOL_LIVE_ID_MAX + TOOL_LIVE_NAME_MAX + TOOL_LIVE_SUMMARY_MAX + 16
 max_entry := 2*TOOL_LIVE_MAX_ACTIVE*size_of(Tool_Live_Call) + 2*TOOL_LIVE_MAX_TOMBSTONES*size_of(Tool_Live_Tombstone) +
  TOOL_LIVE_MAX_ACTIVE*max_call + TOOL_LIVE_MAX_TOMBSTONES*MAX_KEY_BYTES +
  2*TOOL_LIVE_MAX_ACTIVE*size_of(Tool_Live_Completion) + TOOL_LIVE_MAX_ACTIVE*(MAX_KEY_BYTES + TOOL_LIVE_NAME_MAX + TOOL_LIVE_SUMMARY_MAX + 128) + 2048
 testing.expect(t,TOOL_LIVE_MAX_INSTANCES*max_entry<80*1024*1024)
 escaped:=strings.repeat("\"",TOOL_LIVE_ID_MAX/2,context.temp_allocator)
 key:=tool_live_key("provider",escaped,escaped,escaped)
 testing.expect(t,len(key)<=MAX_KEY_BYTES)
 s:=live_test_service();defer tool_live_destroy(&s.tool_live)
 for i in 0..<TOOL_LIVE_MAX_ACTIVE {
  id:=fmt.tprintf("%s%02d",escaped[:len(escaped)-2],i)
  inst:=live_test_inst; inst.provider_session_id=escaped
  live_event:=live_ev("tool.start",id,1,escaped,escaped)
  tool_live_extension(&s,inst,[]Event{live_event})
 }
 testing.expect_value(t,len(live_obj(&s)["active"].(json.Array)),TOOL_LIVE_MAX_ACTIVE)
 body:=tool_live_snapshot(&s,live_test_inst);defer delete(body)
 testing.expect(t,len(body)<=MAX_FRAME_BYTES)
 testing.expect(t,wire_shape_ok(body))
}

@(private = "file")
live_last :: proc(obj: json.Object) -> json.Object {
 a := obj["completed_since_last"].(json.Array)
 if len(a) == 0 do return nil
 return a[len(a)-1].(json.Object)
}

@(test)
test_tool_stream_summary_selection_and_utf8_bounds :: proc(t: ^testing.T) {
    cases := [8]struct {name, input, expected: string}{
        {"Bash", `{"command":"echo hi","description":"ignored"}`, "echo hi"},
        {"exec_command", `{"cmd":"rg pattern"}`, "rg pattern"},
        {"Read", `{"file_path":"src/main.odin"}`, "src/main.odin"},
        {"Write", `{"path":"file.txt","content":"never retained"}`, "file.txt"},
        {"Grep", `{"pattern":"needle","path":"not the summary"}`, "needle"},
        {"WebFetch", `{"url":"https://example.test"}`, "https://example.test"},
        {"Agent", `{"description":"check source"}`, "check source"},
        {"Unknown", `{"arbitrary":"not retained"}`, "Unknown"},
    }
    for c in cases {
        value,_:=json.parse_string(c.input,.JSON,true,context.temp_allocator)
        summary,truncated:=tool_live_summary(c.name,value.(json.Object))
        testing.expect_value(t,summary,c.expected)
        testing.expect(t,!truncated)
    }
    text:=strings.concatenate({strings.repeat("x",511,context.temp_allocator),"€tail"},context.temp_allocator)
    summary,truncated:=tool_live_bound_summary(text)
    testing.expect_value(t,len(summary),511)
    testing.expect(t,truncated)
    exact:=strings.repeat("x",512,context.temp_allocator)
    summary,truncated=tool_live_bound_summary(exact)
    testing.expect_value(t,summary,exact);testing.expect(t,!truncated)
}
@(test)
test_tool_stream_completion_batch_drain_bound_and_demand :: proc(t: ^testing.T) {
    s:=live_test_service();defer tool_live_destroy(&s.tool_live)
    s.demand_driven=true
    publications:=0
    s.ctx=&publications
    s.publish=proc(ctx:rawptr,body:string){(^int)(ctx)^ += 1}
    live_send(&s,live_ev("tool.start","unobserved",1))
    live_send(&s,live_ev("tool.end","unobserved",2))
    testing.expect_value(t,publications,0)
    testing.expect_value(t,len(s.tool_live.entries["live_a"].completed),0)
    tool_live_watch(&s,"live_a",true)
    for i in 0..<40 {
        id:=fmt.tprintf("batch_%d",i)
        live_send(&s,live_ev("tool.start",id,3+i,payload=`{"input":{"file_path":"src/test.odin"}}`))
        live_send(&s,live_ev("tool.end",id,4+i))
    }
    body:=tool_live_snapshot(&s,live_test_inst,baseline=true)
    value,_:=json.parse_string(body,.JSON,true,context.temp_allocator);delete(body)
    testing.expect_value(t,len(value.(json.Object)["completed_since_last"].(json.Array)),0)
    testing.expect_value(t,len(s.tool_live.entries["live_a"].completed),32)
    body=tool_live_snapshot(&s,live_test_inst,consume=true)
    value,_=json.parse_string(body,.JSON,true,context.temp_allocator);delete(body)
    batch:=value.(json.Object)["completed_since_last"].(json.Array)
    testing.expect_value(t,len(batch),32)
    if len(batch)>0 {
        testing.expect(t,strings.contains(tool_live_text(batch[0].(json.Object),"call_id"),"batch_8"),"oldest completion dropped on overflow")
        testing.expect_value(t,tool_live_text(batch[0].(json.Object),"summary"),"src/test.odin")
    }
    testing.expect_value(t,len(live_obj(&s)["completed_since_last"].(json.Array)),0)
    tool_live_watch(&s,"live_a",false)
    count:=publications
    live_send(&s,live_ev("tool.start","after_detach",50))
    testing.expect_value(t,publications,count)
    testing.expect_value(t,len(live_obj(&s)["active"].(json.Array)),1)
}
