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
    attach := fmt.tprintf(`{{"type":"tool_stream_attach","instance_id":"%s","subscription_id":"token1","run_count":0}}`,id)
    bridge_tool_live_handle_subscription(&conn,attach)
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
    bridge_tool_last_flush_ns = time.to_unix_nanoseconds(time.now())
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
