package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import ext "odin_test:ctl/extension"
import live "odin_test:lib/tool_live"
import ws "odin_test:lib/ws"

@(private = "file") live_bridge_test_mu: sync.Mutex
@(private = "file")
live_bridge_cleanup :: proc() {
    live.tool_live_destroy(&bridge_tool_tracker.tool_live)
    bridge_tool_tracker = {}
    for id, sub in bridge_tool_subscriptions {
        delete(id, runtime.heap_allocator()); delete(sub.token, runtime.heap_allocator()); delete(sub.visible, runtime.heap_allocator())
    }
    delete(bridge_tool_subscriptions)
    bridge_tool_subscriptions = nil
    bridge_tool_last_flush_ns = 0
    bridge_tool_wire_seq = 0
}
@(private = "file")
stream_bridge_event :: proc(id, call: string, ending := false) {
    ev := contracts.Ext_Event{kind = .Tool_End if ending else .Tool_Start,
        session_id = "s1", tool_use_id = call, tool_name = "Bash",
        ts = action_scheduler_format_rfc3339_utc(bridge_now_unix_ms()+1000)}
    bridge_tool_live_event(Bridge_Local_Agent_Token_Record{agent_instance_id=id, role=.Agent}, ev,
        `{"tool":{"input":{"command":"echo example","ignored":"not retained"}},"payload":{}}`)
}
@(private = "file")
stream_bridge_read :: proc(t: ^testing.T, peer: net.TCP_Socket, reader: ^ws.Frame_Reader) -> json.Object {
    _, body, got := ws.read_frame(peer, reader, time.Second)
    testing.expect(t, got, "expected stream frame")
    if !got do return nil
    defer delete(body)
    value, err := json.parse_string(body, .JSON, true, context.temp_allocator)
    testing.expect_value(t, err, json.Error.None)
    obj, _ := value.(json.Object)
    return obj
}
@(test)
test_tool_stream_bridge_demand_baseline_batches_and_coalescing :: proc(t: ^testing.T) {
    sync.mutex_lock(&live_bridge_test_mu); defer sync.mutex_unlock(&live_bridge_test_mu)
    bridge_tool_live_init(); defer live_bridge_cleanup()
    id := "inst_stream_bridge"
    bridge_runtime_mark_start_success(id)
    listener, le := net.listen_tcp({address=net.IP4_Loopback, port=0})
    if le != nil do testing.fail_now(t,"listen")
    defer net.close(listener)
    bound,_ := net.bound_endpoint(listener)
    peer, pe := net.dial_tcp(bound)
    if pe != nil do testing.fail_now(t,"dial")
    defer net.close(peer)
    sock,_,ae := net.accept_tcp(listener)
    if ae != nil do testing.fail_now(t,"accept")
    defer net.close(sock)
    conn := ws.Connection{socket=sock,connected=true}
    reader := ws.reader_make(); defer ws.reader_destroy(&reader)
    bridge_tool_live_drain(&conn,true)
    reset := stream_bridge_read(t,peer,&reader)
    testing.expect_value(t,live.tool_live_text(reset,"type"),"tool_stream_reset")
    stream_bridge_event(id,"x")
    bridge_tool_last_flush_ns -= i64(time.Second)
    bridge_tool_live_drain(&conn)
    _,_,unexpected := ws.read_frame(peer,&reader,20*time.Millisecond)
    testing.expect(t,!unexpected,"no snapshot traffic without listeners")
    testing.expect_value(t,len(bridge_tool_tracker.tool_live.entries[id].completed),0)
    attach := fmt.tprintf(`{{"type":"tool_stream_attach","version":2,"lease_ms":15000,"instance_id":"%s","subscription_id":"token1","run_count":0}}`,id)
    bridge_hub_handle_command(&conn, strings.concatenate({`{"type":"tool_stream_batch","controls":[`, attach, "]}"}, context.temp_allocator))
    baseline := stream_bridge_read(t,peer,&reader)
    snap := baseline["snapshot"].(json.Object)
    testing.expect(t,bool(baseline["baseline"].(json.Boolean)))
    active := snap["active"].(json.Array)
    testing.expect_value(t,len(active),1)
    if len(active)>0 do testing.expect_value(t,live.tool_live_text(active[0].(json.Object),"summary"),"echo example")
    testing.expect_value(t,len(snap["completed_since_last"].(json.Array)),0)
    // A revision/notification by itself is not a visible net change, including
    // when active objects have been reparsed into maps with different ordering.
    bridge_tool_live_enqueue(nil,id)
    bridge_tool_last_flush_ns -= i64(time.Second)
    bridge_tool_live_drain(&conn)
    _,_,unexpected = ws.read_frame(peer,&reader,20*time.Millisecond)
    testing.expect(t,!unexpected,"unchanged current state is not resent")
    stream_bridge_event(id,"x",true)
    stream_bridge_event(id,"y"); stream_bridge_event(id,"y",true)
    bridge_tool_last_flush_ns = time.tick_now()._nsec
    bridge_tool_live_drain(&conn)
    _,_,unexpected = ws.read_frame(peer,&reader,20*time.Millisecond)
    testing.expect(t,!unexpected,"changes coalesce until a one-second boundary")
    bridge_tool_last_flush_ns -= i64(time.Second)
    bridge_tool_live_drain(&conn)
    update := stream_bridge_read(t,peer,&reader)
    snap = update["snapshot"].(json.Object)
    testing.expect_value(t,len(snap["active"].(json.Array)),0)
    testing.expect_value(t,len(snap["completed_since_last"].(json.Array)),2)
    testing.expect_value(t,len(bridge_tool_tracker.tool_live.entries[id].completed),0)
    // A new baseline is empty-completion, without consuming the next interval.
    stream_bridge_event(id,"z"); stream_bridge_event(id,"z",true)
    bridge_tool_live_handle_subscription(&conn,attach)
    baseline=stream_bridge_read(t,peer,&reader)
    testing.expect_value(t,len(baseline["snapshot"].(json.Object)["completed_since_last"].(json.Array)),0)
    bridge_tool_last_flush_ns -= i64(time.Second); bridge_tool_live_drain(&conn)
    update=stream_bridge_read(t,peer,&reader)
    testing.expect_value(t,len(update["snapshot"].(json.Object)["completed_since_last"].(json.Array)),1)
    bridge_tool_last_flush_ns -= i64(time.Second); bridge_tool_live_drain(&conn)
    _,_,unexpected = ws.read_frame(peer,&reader,20*time.Millisecond)
    testing.expect(t,!unexpected,"idle does not repeat completed batch or send empty ticks")
    detach := fmt.tprintf(`{{"type":"tool_stream_detach","instance_id":"%s","subscription_id":"token1"}}`,id)
    bridge_tool_live_handle_subscription(&conn,detach)
    testing.expect_value(t,len(bridge_tool_subscriptions),0)
    stream_bridge_event(id,"absent"); stream_bridge_event(id,"absent",true)
    testing.expect_value(t,len(bridge_tool_tracker.tool_live.entries[id].completed),0)
    bridge_tool_last_flush_ns -= i64(time.Second); bridge_tool_live_drain(&conn)
    _,_,unexpected = ws.read_frame(peer,&reader,20*time.Millisecond)
    testing.expect(t,!unexpected,"last detach stops upstream snapshots")
    bridge_tool_live_drain(&conn,true)
    _=stream_bridge_read(t,peer,&reader)
    bridge_tool_live_handle_subscription(&conn,attach)
    baseline=stream_bridge_read(t,peer,&reader)
    snap=baseline["snapshot"].(json.Object)
    testing.expect_value(t,len(snap["active"].(json.Array)),0)
    testing.expect_value(t,len(snap["completed_since_last"].(json.Array)),0)
}
@(test)
test_live_bridge_shell_restart_and_late_exit :: proc(t: ^testing.T) {
    sync.mutex_lock(&live_bridge_test_mu); defer sync.mutex_unlock(&live_bridge_test_mu)
    bridge_tool_live_init(); defer live_bridge_cleanup()
    id := "inst_live_shell"
    bridge_runtime_mark_start_success(id)
    row := Bridge_Shell_Session{session_id="sh_live_restart", agent_instance_id=id, kind=.Run, status=.Running, cmd="printf registered-command"}
    bridge_tool_live_shell(row, true)
    row.run_seq = 1
    bridge_tool_live_shell(row, true, 0)
    old := row; old.run_seq=0; old.status=.Exited; old.exit_code_set=true
    bridge_tool_live_shell(old, false)
    inst, _ := bridge_tool_live_instance(nil,id)
    body := live.tool_live_snapshot(&bridge_tool_tracker, inst)
    value, _ := json.parse_string(body,.JSON,true,context.temp_allocator); delete(body)
    testing.expect_value(t,len(value.(json.Object)["active"].(json.Array)),1)
    active := value.(json.Object)["active"].(json.Array)
    if len(active)>0 do testing.expect_value(t,live.tool_live_text(active[0].(json.Object),"summary"),row.cmd)
    row.status=.Killed; row.exit_code_set=true; row.exit_code=137
    bridge_tool_live_shell(row,false)
    body=live.tool_live_snapshot(&bridge_tool_tracker, inst)
    testing.expect(t,strings.contains(body,`"active":[]`)); delete(body)
    row.run_seq=2; row.status=.Running
    bridge_tool_live_shell(row,true,1)
    body=live.tool_live_snapshot(&bridge_tool_tracker, inst)
    testing.expect(t,strings.contains(body,`"shell_run_seq":2`)); delete(body)
}

// Uses real frames but advances only the scheduling clock; no 60-second sleeps.
@(test)
test_tool_stream_bridge_active_freshness_deadlines :: proc(t: ^testing.T) {
    sync.mutex_lock(&live_bridge_test_mu); defer sync.mutex_unlock(&live_bridge_test_mu)
    bridge_tool_live_init(); defer live_bridge_cleanup()
    id := "inst_stream_freshness"
    bridge_runtime_mark_start_success(id)
    listener, le := net.listen_tcp({address=net.IP4_Loopback, port=0})
    testing.expect(t, le == nil); if le != nil do return
    defer net.close(listener)
    bound,_ := net.bound_endpoint(listener)
    peer, pe := net.dial_tcp(bound)
    testing.expect(t, pe == nil); if pe != nil do return
    defer net.close(peer)
    sock,_,ae := net.accept_tcp(listener)
    testing.expect(t, ae == nil); if ae != nil do return
    defer net.close(sock)
    conn := ws.Connection{socket=sock,connected=true}
    reader := ws.reader_make(); defer ws.reader_destroy(&reader)
    stream_bridge_event(id,"long")
    // An arbitrarily late writer turn with no listeners does not even advance
    // the flush clock; the early return precedes all snapshot construction.
    bridge_tool_live_drain_at(&conn, 10 * BRIDGE_TOOL_REFRESH_NS)
    testing.expect_value(t,bridge_tool_wire_seq,0)
    testing.expect_value(t,bridge_tool_last_flush_ns,0)
    attach := fmt.tprintf(`{{"type":"tool_stream_attach","version":2,"lease_ms":15000,"instance_id":"%s","subscription_id":"fresh","run_count":0}}`,id)
    bridge_tool_live_handle_subscription(&conn,attach)
    baseline := stream_bridge_read(t,peer,&reader)
    testing.expect(t,!bool(baseline["refresh"].(json.Boolean)))
    base := bridge_tool_subscriptions[id].last_emit_ns
    // This test drives a healthy continuously renewed producer with a synthetic clock.
    renewed := bridge_tool_subscriptions[id]
    renewed.lease_until_ns = base + 30 * BRIDGE_TOOL_REFRESH_NS
    bridge_tool_subscriptions[id] = renewed
    original := baseline["snapshot"].(json.Object)
    // A batch turn just before the deadline must not defer the 60s refresh.
    bridge_tool_last_flush_ns = base
    bridge_tool_live_drain_at(&conn,base+BRIDGE_TOOL_REFRESH_NS-1)
    _,_,got := ws.read_frame(peer,&reader,10*time.Millisecond)
    testing.expect(t,!got,"no refresh before 60s")
    for cycle in 1..=2 {
        now := base+i64(cycle)*BRIDGE_TOOL_REFRESH_NS
        bridge_tool_live_drain_at(&conn,now)
        update := stream_bridge_read(t,peer,&reader)
        snap := update["snapshot"].(json.Object)
        testing.expect(t,bool(update["refresh"].(json.Boolean)))
        testing.expect(t,!bool(update["baseline"].(json.Boolean)))
        testing.expect_value(t,snap["revision"].(json.Integer),original["revision"].(json.Integer))
        testing.expect_value(t,len(snap["active"].(json.Array)),1)
        testing.expect_value(t,len(snap["completed_since_last"].(json.Array)),0)
        testing.expect_value(t,bridge_tool_subscriptions[id].last_emit_ns,now)
        testing.expect(t,update["seq"].(json.Integer)>baseline["seq"].(json.Integer))
        bridge_tool_live_drain_at(&conn,now)
        _,_,got = ws.read_frame(peer,&reader,10*time.Millisecond)
        testing.expect(t,!got,"one refresh per deadline")
    }
    // Refresh takes current tracker content, including only newly pending
    // completions. It does not replay the baseline or previous interval bytes.
    stream_bridge_event(id,"long",true)
    stream_bridge_event(id,"next")
    bridge_tool_live_drain_at(&conn,base+3*BRIDGE_TOOL_REFRESH_NS)
    update := stream_bridge_read(t,peer,&reader)
    snap := update["snapshot"].(json.Object)
    testing.expect_value(t,len(snap["active"].(json.Array)),1)
    testing.expect(t,strings.contains(live.tool_live_text(snap["active"].(json.Array)[0].(json.Object),"call_id"),"next"))
    testing.expect_value(t,len(snap["completed_since_last"].(json.Array)),1)
    bridge_tool_live_drain_at(&conn,base+4*BRIDGE_TOOL_REFRESH_NS)
    update=stream_bridge_read(t,peer,&reader)
    testing.expect_value(t,len(update["snapshot"].(json.Object)["completed_since_last"].(json.Array)),0)
    stream_bridge_event(id,"next",true)
    bridge_tool_live_drain_at(&conn,base+4*BRIDGE_TOOL_REFRESH_NS+i64(time.Second))
    update=stream_bridge_read(t,peer,&reader)
    testing.expect_value(t,len(update["snapshot"].(json.Object)["active"].(json.Array)),0)
    idle_seq := bridge_tool_wire_seq
    bridge_tool_live_drain_at(&conn,base+10*BRIDGE_TOOL_REFRESH_NS)
    testing.expect_value(t,bridge_tool_wire_seq,idle_seq)
    _,_,got=ws.read_frame(peer,&reader,10*time.Millisecond)
    testing.expect(t,!got,"idle empty state has no periodic refresh")
    stream_bridge_event(id,"detached")
    bridge_tool_live_drain_at(&conn,base+10*BRIDGE_TOOL_REFRESH_NS+i64(time.Second))
    _=stream_bridge_read(t,peer,&reader)
    detach := fmt.tprintf(`{{"type":"tool_stream_detach","instance_id":"%s","subscription_id":"fresh"}}`,id)
    bridge_tool_live_handle_subscription(&conn,detach)
    testing.expect_value(t,len(bridge_tool_tracker.tool_live.watched),0)
    stopped_seq := bridge_tool_wire_seq
    stream_bridge_event(id,"detached",true)
    testing.expect_value(t,len(bridge_tool_tracker.tool_live.entries[id].completed),0)
    bridge_tool_live_drain_at(&conn,base+20*BRIDGE_TOOL_REFRESH_NS)
    testing.expect_value(t,bridge_tool_wire_seq,stopped_seq)
    _,_,got=ws.read_frame(peer,&reader,10*time.Millisecond)
    testing.expect(t,!got,"last detach stops refresh")
}

@(test)
test_codex_large_image_completion_reaches_live_inventory :: proc(t: ^testing.T) {
    sync.mutex_lock(&live_bridge_test_mu); defer sync.mutex_unlock(&live_bridge_test_mu)
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)
    bridge_tool_live_init(); defer live_bridge_cleanup()
    bridge_tool_tracker.demand_driven = false
    id := "inst_live_codex_images"
    other := "inst_live_codex_images_other"
    bridge_runtime_mark_start_success(id)
    bridge_runtime_mark_start_success(other)
    value, _ := json.parse_string(#load("../ctl/extension/testdata/codex/image_callbacks.json", string), .JSON, true)
    rows := value.(json.Array)
    start, end: json.Object
    for row in rows {
        root := row.(json.Object)
        if live.tool_live_text(root, "tool_use_id") != "exec-image-4" do continue
        if live.tool_live_text(root, "hook_event_name") == "PreToolUse" do start = root
        if live.tool_live_text(root, "hook_event_name") == "PostToolUse" do end = root
    }
    testing.expect(t, start != nil && end != nil)
    if start == nil || end == nil do return
    response := end["tool_response"].(json.Array)
    image := response[0].(json.Object)
    image["image_url"] = json.String(strings.repeat("A", 2_400_000))
    now := bridge_now_unix_ms()+1000
    for target, i in ([]string{id, id, other}) {
        if i == 1 do start["agent_id"] = json.String("nested-child")
        else do delete_key(&start, "agent_id")
        raw, _ := json.marshal(start)
        mapped, err := ext.codex_map_hook(string(raw), action_scheduler_format_rfc3339_utc(now))
        testing.expect_value(t, err, ext.Codex_Error.None)
        res := bridge_ext_ingest(Bridge_Local_Agent_Token_Record{agent_instance_id=target, role=.Agent},
            ext.event_params(mapped.events[:]), bridge_runtime_now_ms())
        testing.expect_value(t, res.accepted, 1)
        bridge_ext_ingest_result_destroy(&res)
    }
    testing.expect_value(t, len(bridge_tool_tracker.tool_live.entries[id].active), 2)
    raw, _ := json.marshal(end)
    mapped, err := ext.codex_map_hook(string(raw), action_scheduler_format_rfc3339_utc(now+1000))
    testing.expect_value(t, err, ext.Codex_Error.None)
    testing.expect_value(t, len(mapped.events), 1)
    if len(mapped.events) != 1 do return
    for _ in 0..<2 {
        res := bridge_ext_ingest(Bridge_Local_Agent_Token_Record{agent_instance_id=id, role=.Agent},
            ext.event_params(mapped.events[:]), bridge_runtime_now_ms())
        testing.expect_value(t, res.accepted, 1)
        bridge_ext_ingest_result_destroy(&res)
    }
    entry := bridge_tool_tracker.tool_live.entries[id]
    testing.expect_value(t, len(entry.active), 1)
    if len(entry.active) == 1 do testing.expect_value(t, entry.active[0].agent_id, "nested-child")
    testing.expect_value(t, len(bridge_tool_tracker.tool_live.entries[other].active), 1)
    testing.expect_value(t, len(entry.completed), 1)
    if len(entry.completed) == 1 {
        testing.expect_value(t, entry.completed[0].status, "completed")
        testing.expect_value(t, entry.completed[0].duration_ms, 1000)
    }
    inst, _ := bridge_tool_live_instance(nil,id)
    baseline := live.tool_live_snapshot(&bridge_tool_tracker, inst, baseline=true)
    testing.expect(t, strings.contains(baseline, `"completed_since_last":[]`))
    testing.expect(t, !strings.contains(baseline, "image_url"))
    delete(baseline)
    bridge_tool_live_clear(id)
    ev, parse_err := contracts.ext_parse_event(mapped.events[0])
    testing.expect_value(t, parse_err, contracts.Ext_Error.None)
    bridge_tool_live_event(Bridge_Local_Agent_Token_Record{agent_instance_id=id, role=.Agent}, ev, mapped.events[0])
    testing.expect_value(t, len(entry.active), 0)
    testing.expect_value(t, len(entry.completed), 0)
}

@(test)
test_tool_stream_lease_expiry_drops_demand_and_pending_completion :: proc(t: ^testing.T) {
    sync.mutex_lock(&live_bridge_test_mu); defer sync.mutex_unlock(&live_bridge_test_mu)
    bridge_tool_live_init(); defer live_bridge_cleanup()
    id := "inst_lease_expiry"
    bridge_runtime_mark_start_success(id)
    // Expired records are removed before any attempt to use the socket.
    live.tool_live_watch(&bridge_tool_tracker, id, true)
    bridge_tool_subscriptions = make(map[string]Bridge_Tool_Subscription, runtime.heap_allocator())
    bridge_tool_subscriptions[strings.clone(id, runtime.heap_allocator())] = {
        token = strings.clone("leased", runtime.heap_allocator()), lease_until_ns = 10, dirty = true,
    }
    conn := ws.Connection{}
    bridge_tool_live_drain_at(&conn, 10)
    testing.expect_value(t, len(bridge_tool_subscriptions), 0)
    testing.expect(t, !bridge_tool_tracker.tool_live.watched[id])
    testing.expect_value(t, bridge_tool_wire_seq, 0)
    legacy := fmt.tprintf(`{{"type":"tool_stream_attach","instance_id":"%s","subscription_id":"legacy","run_count":0}}`, id)
    bridge_tool_live_handle_subscription(&conn, legacy)
    testing.expect(t, len(bridge_tool_subscriptions) == 0, "legacy demand fails closed")
}

// Native hook replay: an interrupted or permission-rejected call gets PreToolUse
// but never PostToolUse/PostToolUseFailure. The turn boundary must close it.
@(private = "file")
orphan_replay :: proc(t: ^testing.T, id, provider, raw: string, ts_ms: i64) {
    // RFC 3339 here has whole-second precision: callers space steps >= 1s apart.
    context.allocator = context.temp_allocator
    ts := action_scheduler_format_rfc3339_utc(ts_ms)
    events: [dynamic]string
    switch provider {
    case "claude":
        m, err := ext.claude_map_hook(raw, ts)
        testing.expect_value(t, err, ext.Claude_Error.None)
        events = m.events
    case "codex":
        m, err := ext.codex_map_hook(raw, ts)
        testing.expect_value(t, err, ext.Codex_Error.None)
        events = m.events
    case "antigravity":
        m, err := ext.antigravity_map_hook(raw, ts)
        testing.expect_value(t, err, ext.Antigravity_Error.None)
        events = m.events
    }
    if len(events) == 0 do return
    res := bridge_ext_ingest(Bridge_Local_Agent_Token_Record{agent_instance_id=id, role=.Agent},
        ext.event_params(events[:]), bridge_runtime_now_ms())
    testing.expect_value(t, res.accepted, len(events))
    bridge_ext_ingest_result_destroy(&res)
}
@(private = "file")
orphan_active :: proc(id: string) -> (main_calls, sub_calls: int) {
    e := bridge_tool_tracker.tool_live.entries[id]
    if e == nil do return
    for c in e.active {
        if c.agent_id == "" do main_calls += 1
        else do sub_calls += 1
    }
    return
}
@(private = "file")
orphan_last_status :: proc(id: string) -> string {
    e := bridge_tool_tracker.tool_live.entries[id]
    if e == nil || len(e.completed) == 0 do return ""
    return e.completed[len(e.completed)-1].status
}

@(test)
test_tool_stream_claude_orphan_closed_at_turn_boundary :: proc(t: ^testing.T) {
    sync.mutex_lock(&live_bridge_test_mu); defer sync.mutex_unlock(&live_bridge_test_mu)
    bridge_tool_live_init(); defer live_bridge_cleanup()
    id := "inst_orphan_claude"
    bridge_runtime_mark_start_success(id)
    live.tool_live_watch(&bridge_tool_tracker, id, true)
    now := bridge_now_unix_ms()+1000
    orphan_replay(t, id, "claude", `{"hook_event_name":"SessionStart","session_id":"c1","source":"startup"}`, now)
    // Rejected main-thread Bash: PreToolUse, then Stop with no PostToolUse.
    orphan_replay(t, id, "claude", `{"hook_event_name":"PreToolUse","session_id":"c1","tool_name":"Bash","tool_use_id":"toolu_rejected","tool_input":{"command":"python3 -m pytest"}}`, now+1000)
    // A background subagent's call is still running when the main turn stops.
    orphan_replay(t, id, "claude", `{"hook_event_name":"PreToolUse","session_id":"c1","agent_id":"agent_bg","agent_type":"general-purpose","tool_name":"Read","tool_use_id":"toolu_sub","tool_input":{"file_path":"/tmp/x"}}`, now+2000)
    main_calls, sub_calls := orphan_active(id)
    testing.expect_value(t, main_calls, 1)
    testing.expect_value(t, sub_calls, 1)
    orphan_replay(t, id, "claude", `{"hook_event_name":"Stop","session_id":"c1","background_tasks":[{"status":"running"}]}`, now+3000)
    main_calls, sub_calls = orphan_active(id)
    testing.expect_value(t, main_calls, 0)
    testing.expect_value(t, sub_calls, 1)
    testing.expect_value(t, orphan_last_status(id), "interrupted")
    // A late end cannot resurrect or re-complete the closed call.
    orphan_replay(t, id, "claude", `{"hook_event_name":"PostToolUse","session_id":"c1","tool_name":"Bash","tool_use_id":"toolu_rejected","tool_input":{"command":"python3 -m pytest"},"tool_response":{}}`, now+350)
    testing.expect_value(t, len(bridge_tool_tracker.tool_live.entries[id].completed), 1)

    // Interrupted while waiting: the next prompt arrives before any Stop.
    orphan_replay(t, id, "claude", `{"hook_event_name":"PreToolUse","session_id":"c1","tool_name":"Bash","tool_use_id":"toolu_interrupted","tool_input":{"command":"sleep 100"}}`, now+4000)
    main_calls, _ = orphan_active(id)
    testing.expect_value(t, main_calls, 1)
    orphan_replay(t, id, "claude", `{"hook_event_name":"UserPromptSubmit","session_id":"c1","prompt":"new message"}`, now+5000)
    main_calls, sub_calls = orphan_active(id)
    testing.expect_value(t, main_calls, 0)
    testing.expect_value(t, sub_calls, 1)
    testing.expect_value(t, orphan_last_status(id), "interrupted")

    // A main-thread call started in the new turn stays live until its own end.
    orphan_replay(t, id, "claude", `{"hook_event_name":"PreToolUse","session_id":"c1","tool_name":"Bash","tool_use_id":"toolu_live","tool_input":{"command":"ls"}}`, now+6000)
    main_calls, _ = orphan_active(id)
    testing.expect_value(t, main_calls, 1)
    orphan_replay(t, id, "claude", `{"hook_event_name":"PostToolUse","session_id":"c1","tool_name":"Bash","tool_use_id":"toolu_live","tool_input":{"command":"ls"},"tool_response":{}}`, now+7000)
    testing.expect_value(t, orphan_last_status(id), "completed")

    // Only subagent.stop closes the background subagent's calls.
    orphan_replay(t, id, "claude", `{"hook_event_name":"SubagentStop","session_id":"c1","agent_id":"agent_bg","agent_type":"general-purpose"}`, now+8000)
    main_calls, sub_calls = orphan_active(id)
    testing.expect_value(t, main_calls, 0)
    testing.expect_value(t, sub_calls, 0)
}

@(test)
test_tool_stream_codex_orphan_closed_at_turn_boundary :: proc(t: ^testing.T) {
    sync.mutex_lock(&live_bridge_test_mu); defer sync.mutex_unlock(&live_bridge_test_mu)
    bridge_tool_live_init(); defer live_bridge_cleanup()
    id := "inst_orphan_codex"
    bridge_runtime_mark_start_success(id)
    live.tool_live_watch(&bridge_tool_tracker, id, true)
    now := bridge_now_unix_ms()+1000
    orphan_replay(t, id, "codex", `{"hook_event_name":"SessionStart","session_id":"x1","source":"startup"}`, now)
    orphan_replay(t, id, "codex", `{"hook_event_name":"PreToolUse","session_id":"x1","turn_id":"t1","tool_name":"exec_command","tool_use_id":"call_main","tool_input":{"cmd":"cargo test"}}`, now+1000)
    orphan_replay(t, id, "codex", `{"hook_event_name":"PreToolUse","session_id":"x1","agent_id":"child_1","turn_id":"t1","tool_name":"exec_command","tool_use_id":"call_child","tool_input":{"cmd":"ls"}}`, now+2000)
    orphan_replay(t, id, "codex", `{"hook_event_name":"Interrupt","session_id":"x1","turn_id":"t1"}`, now+3000)
    main_calls, sub_calls := orphan_active(id)
    testing.expect_value(t, main_calls, 0)
    testing.expect_value(t, sub_calls, 1)
    testing.expect_value(t, orphan_last_status(id), "interrupted")
    orphan_replay(t, id, "codex", `{"hook_event_name":"PreToolUse","session_id":"x1","turn_id":"t1","tool_name":"exec_command","tool_use_id":"call_denied","tool_input":{"cmd":"rm -rf build"}}`, now+4000)
    orphan_replay(t, id, "codex", `{"hook_event_name":"UserPromptSubmit","session_id":"x1","turn_id":"t2","prompt":"continue"}`, now+5000)
    main_calls, sub_calls = orphan_active(id)
    testing.expect_value(t, main_calls, 0)
    testing.expect_value(t, sub_calls, 1)
    orphan_replay(t, id, "codex", `{"hook_event_name":"PreToolUse","session_id":"x1","turn_id":"t2","tool_name":"exec_command","tool_use_id":"call_stop","tool_input":{"cmd":"make"}}`, now+6000)
    orphan_replay(t, id, "codex", `{"hook_event_name":"Stop","session_id":"x1","turn_id":"t2"}`, now+7000)
    main_calls, sub_calls = orphan_active(id)
    testing.expect_value(t, main_calls, 0)
    testing.expect_value(t, sub_calls, 1)
    orphan_replay(t, id, "codex", `{"hook_event_name":"SubagentStop","session_id":"x1","agent_id":"child_1"}`, now+8000)
    _, sub_calls = orphan_active(id)
    testing.expect_value(t, sub_calls, 0)
}

@(test)
test_tool_stream_antigravity_orphan_closed_and_turn_two_live :: proc(t: ^testing.T) {
    sync.mutex_lock(&live_bridge_test_mu); defer sync.mutex_unlock(&live_bridge_test_mu)
    bridge_tool_live_init(); defer live_bridge_cleanup()
    id := "inst_orphan_agy"
    bridge_runtime_mark_start_success(id)
    live.tool_live_watch(&bridge_tool_tracker, id, true)
    now := bridge_now_unix_ms()+1000
    orphan_replay(t, id, "antigravity", `{"hookEventName":"PreInvocation","conversationId":"g1","invocationNum":1,"stepIdx":0}`, now)
    orphan_replay(t, id, "antigravity", `{"hookEventName":"PreToolUse","conversationId":"g1","stepIdx":1,"toolCall":{"name":"run_command","args":{"CommandLine":"go test ./..."}}}`, now+1000)
    main_calls, _ := orphan_active(id)
    testing.expect_value(t, main_calls, 1)
    // Stop maps to activity idle + session end; no PostToolUse ever arrives.
    orphan_replay(t, id, "antigravity", `{"hookEventName":"Stop","conversationId":"g1","terminationReason":"user_cancel"}`, now+2000)
    main_calls, _ = orphan_active(id)
    testing.expect_value(t, main_calls, 0)
    // Turn 2 (invocationNum > 1) sends no hello/session start; live tools must still work.
    orphan_replay(t, id, "antigravity", `{"hookEventName":"PreInvocation","conversationId":"g1","invocationNum":2,"stepIdx":2}`, now+3000)
    orphan_replay(t, id, "antigravity", `{"hookEventName":"PreToolUse","conversationId":"g1","stepIdx":3,"toolCall":{"name":"run_command","args":{"CommandLine":"ls"}}}`, now+4000)
    main_calls, _ = orphan_active(id)
    testing.expect_value(t, main_calls, 1)
    orphan_replay(t, id, "antigravity", `{"hookEventName":"PostToolUse","conversationId":"g1","stepIdx":3,"toolCall":{"name":"run_command","args":{"CommandLine":"ls"}}}`, now+5000)
    main_calls, _ = orphan_active(id)
    testing.expect_value(t, main_calls, 0)
    testing.expect_value(t, orphan_last_status(id), "completed")
    // Turn 3: a fresh PreInvocation also closes a call orphaned without Stop.
    orphan_replay(t, id, "antigravity", `{"hookEventName":"PreToolUse","conversationId":"g1","stepIdx":4,"toolCall":{"name":"run_command","args":{"CommandLine":"sleep 100"}}}`, now+6000)
    main_calls, _ = orphan_active(id)
    testing.expect_value(t, main_calls, 1)
    orphan_replay(t, id, "antigravity", `{"hookEventName":"PreInvocation","conversationId":"g1","invocationNum":3,"stepIdx":5}`, now+7000)
    main_calls, _ = orphan_active(id)
    testing.expect_value(t, main_calls, 0)
    testing.expect_value(t, orphan_last_status(id), "interrupted")
}
