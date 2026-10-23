package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:testing"
import "core:time"
import live "odin_test:lib/tool_live"
import ws "odin_test:lib/ws"

@(private = "file")
live_bridge_cleanup :: proc() {
    live.tool_live_destroy(&bridge_tool_tracker.tool_live)
    bridge_tool_tracker = {}
    for key, val in bridge_tool_dirty { delete(key, runtime.heap_allocator()); delete(val, runtime.heap_allocator()) }
    delete(bridge_tool_dirty)
    bridge_tool_dirty = nil; bridge_tool_dirty_bytes = 0; bridge_tool_resync = false
}
@(test)
test_live_bridge_push_snapshot_idle_and_reconnect :: proc(t: ^testing.T) {
    bridge_tool_live_init(); defer live_bridge_cleanup()
    id := "inst_live_bridge"
    bridge_runtime_mark_start_success(id)
    listener, le := net.listen_tcp({address = net.IP4_Loopback, port = 0})
    if le != nil do testing.fail_now(t, "listen")
    defer net.close(listener)
    bound, _ := net.bound_endpoint(listener)
    peer, pe := net.dial_tcp(bound)
    if pe != nil do testing.fail_now(t, "dial")
    defer net.close(peer)
    sock, _, ae := net.accept_tcp(listener)
    if ae != nil do testing.fail_now(t, "accept")
    defer net.close(sock)
    conn := ws.Connection{socket = sock, connected = true}
    reader := ws.reader_make(); defer ws.reader_destroy(&reader)
    bridge_tool_live_drain(&conn, true)
    for _ in 0..<2 { _, frame, got := ws.read_frame(peer, &reader, time.Second); testing.expect(t, got); delete(frame) }
    bridge_tool_live_drain(&conn)
    _, _, unexpected := ws.read_frame(peer, &reader, 30*time.Millisecond)
    testing.expect(t, !unexpected, "idle connected path emits no tool-state traffic")
    ts := action_scheduler_format_rfc3339_utc(bridge_now_unix_ms()+1000)
    raw := fmt.tprintf(`{{"schema":"ham.ext.v1","provider":"claude","event":"tool.start","ts":"%s","session_id":"s1","tool":{{"name":"Read","use_id":"x"}},"payload":{{}}}`, ts)
    result := bridge_ext_ingest(Bridge_Local_Agent_Token_Record{agent_instance_id=id, role=.Agent}, raw, bridge_now_unix_ms()); bridge_ext_ingest_result_destroy(&result)
    bridge_tool_live_drain(&conn)
    _, frame, got := ws.read_frame(peer, &reader, time.Second)
    testing.expect(t, got && strings.contains(frame, "tool_activity_live_snapshot"))
    testing.expect(t, strings.contains(frame, `"tool_use_id":"x"`)); delete(frame)
    request := fmt.tprintf(`{{"type":"tool_activity_live_request","request_id":"snap_1","instance_id":"%s"}}`,id)
    bridge_tool_live_handle_request(&conn, request)
    _, frame, got = ws.read_frame(peer, &reader, time.Second)
    testing.expect(t, got && strings.contains(frame, "tool_activity_live_reply"))
    testing.expect(t, strings.contains(frame, `"tool_use_id":"x"`)); delete(frame)
    raw, _ = strings.replace(raw, "tool.start", "tool.end", 1, allocator = context.temp_allocator)
    result = bridge_ext_ingest(Bridge_Local_Agent_Token_Record{agent_instance_id=id, role=.Agent}, raw, bridge_now_unix_ms()); bridge_ext_ingest_result_destroy(&result)
    bridge_tool_live_drain(&conn)
    _, frame, got = ws.read_frame(peer, &reader, time.Second)
    testing.expect(t, got && strings.contains(frame, `"active":[]`))
    testing.expect(t, strings.contains(frame, "last_completion")); delete(frame)
    // Hub restart/reconnect does not replay completed calls: snapshot stays empty.
    bridge_tool_live_drain(&conn, true)
    for _ in 0..<2 { _, reset, received := ws.read_frame(peer, &reader, time.Second); testing.expect(t, received); delete(reset) }
    bridge_tool_live_handle_request(&conn, request)
    _, frame, got = ws.read_frame(peer, &reader, time.Second)
    testing.expect(t, got && strings.contains(frame, `"active":[]`)); delete(frame)
    testing.expect_value(t, bridge_tool_dirty_bytes, 0)
    // Actual launch/relaunch produces an explicit ready/resync hint even on
    // an otherwise unchanged live socket; UI can release its unavailable fence.
    bridge_runtime_record_launch(Bridge_Runtime_Launch{agent_instance_id=id})
    bridge_tool_live_drain(&conn)
    _, reset, reset_ok := ws.read_frame(peer,&reader,time.Second); delete(reset)
    _, hint, hint_ok := ws.read_frame(peer,&reader,time.Second)
    testing.expect(t,reset_ok && hint_ok && strings.contains(hint,"tool_activity_live_resync")); delete(hint)
}
@(test)
test_live_bridge_shell_restart_and_late_exit :: proc(t: ^testing.T) {
    bridge_tool_live_init(); defer live_bridge_cleanup()
    id := "inst_live_shell"
    bridge_runtime_mark_start_success(id)
    row := Bridge_Shell_Session{session_id="sh_live_restart", agent_instance_id=id, kind=.Run, status=.Running}
    bridge_tool_live_shell(row, true)
    row.run_seq = 1
    bridge_tool_live_shell(row, true, 0)
    old := row; old.run_seq=0; old.status=.Exited; old.exit_code_set=true
    bridge_tool_live_shell(old, false)
    inst, _ := bridge_tool_live_instance(nil,id)
    body := live.tool_live_snapshot(&bridge_tool_tracker, inst)
    value, _ := json.parse_string(body,.JSON,true,context.temp_allocator); delete(body)
    testing.expect_value(t,len(value.(json.Object)["active"].(json.Array)),1)
    row.status=.Killed; row.exit_code_set=true; row.exit_code=137
    bridge_tool_live_shell(row,false)
    body=live.tool_live_snapshot(&bridge_tool_tracker, inst)
    testing.expect(t,strings.contains(body,`"active":[]`)); delete(body)
    row.run_seq=2; row.status=.Running
    bridge_tool_live_shell(row,true,1)
    body=live.tool_live_snapshot(&bridge_tool_tracker, inst)
    testing.expect(t,strings.contains(body,`"shell_run_seq":2`)); delete(body)
}
