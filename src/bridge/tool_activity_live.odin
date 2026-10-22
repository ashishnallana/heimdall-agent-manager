package main

// Bridge owns the live reducer. Hooks and observed shell lifecycle enqueue only
// the latest full snapshot per instance. The existing runtime writer drains
// changes; an idle connection sends nothing and makes no state requests.
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import live "odin_test:lib/tool_live"
import contracts "odin_test:contracts"
import ws "odin_test:lib/ws"

bridge_tool_tracker: live.Tracker
bridge_tool_out_mutex: sync.Mutex
bridge_tool_dirty: map[string]string
bridge_tool_resync: bool
bridge_tool_wire_seq: u64
bridge_tool_dirty_bytes: int

bridge_tool_live_init :: proc() {
    live.tool_live_init(&bridge_tool_tracker.tool_live)
    bridge_tool_tracker.get_instance = bridge_tool_live_instance
    bridge_tool_tracker.publish = bridge_tool_live_enqueue
}
bridge_tool_live_instance :: proc(ctx: rawptr, id: string) -> (live.Instance, bool) {
    inst, ok := bridge_runtime_instance_snapshot(id)
    if !ok do return {}, false
    run := 0
    sync.mutex_lock(&bridge_local_token_mutex)
    for rec in bridge_local_token_records {
        if rec.agent_instance_id == id && rec.invalidated_at_unix_ms == 0 do run = max(run, rec.run_count)
    }
    sync.mutex_unlock(&bridge_local_token_mutex)
    // launch tick is a plain value copied under the runtime mutex.
    launch, launched := bridge_runtime_get_launch(id)
    return live.Instance{agent_instance_id = id, run_count = run, runtime_status = inst.runtime_status,
        launch_epoch = fmt.tprintf("%d", launch.launched_at_ns if launched else 0)}, true
}
bridge_tool_live_enqueue :: proc(ctx: rawptr, body: string) {
    context.allocator = runtime.heap_allocator()
    if !live.wire_shape_ok(body) do return
    v, err := json.parse_string(body, .JSON, true, context.temp_allocator)
    if err != .None do return
    obj := v.(json.Object)
    id := live.tool_live_text(obj, "instance_id")
    rev, _ := obj["revision"].(json.Integer)
    sync.mutex_lock(&bridge_tool_out_mutex)
    defer sync.mutex_unlock(&bridge_tool_out_mutex)
    if bridge_tool_resync do return
    if old, exists := bridge_tool_dirty[id]; exists {
        old_v, _ := json.parse_string(old, .JSON, true, context.temp_allocator)
        old_rev, _ := old_v.(json.Object)["revision"].(json.Integer)
        if rev <= old_rev do return
        if bridge_tool_dirty_bytes - len(old) + len(body) > live.MAX_DIRTY_BYTES {
            for key, val in bridge_tool_dirty { delete(key); delete(val) }
            delete(bridge_tool_dirty); bridge_tool_dirty = nil
            bridge_tool_resync = true; bridge_tool_dirty_bytes = 0
            return
        }
        bridge_tool_dirty_bytes -= len(old)
        delete(old)
        bridge_tool_dirty_bytes += len(body)
        bridge_tool_dirty[id] = strings.clone(body)
        return
    }
    if len(bridge_tool_dirty) >= live.TOOL_LIVE_MAX_INSTANCES || bridge_tool_dirty_bytes + len(body) > live.MAX_DIRTY_BYTES {
        for key, val in bridge_tool_dirty { delete(key); delete(val) }
        delete(bridge_tool_dirty); bridge_tool_dirty = nil
        bridge_tool_resync = true; bridge_tool_dirty_bytes = 0
        return
    }
    if bridge_tool_dirty == nil do bridge_tool_dirty = make(map[string]string)
    bridge_tool_dirty_bytes += len(body)
    bridge_tool_dirty[strings.clone(id)] = strings.clone(body)
}
bridge_tool_live_clear :: proc(id: string) {
    if bridge_tool_tracker.get_instance == nil do return
    live.tool_live_clear(&bridge_tool_tracker, id)
}
bridge_tool_live_event :: proc(rec: Bridge_Local_Agent_Token_Record, ev: contracts.Ext_Event, raw: string) {
    if bridge_tool_tracker.get_instance == nil do return
    inst, ok := bridge_tool_live_instance(nil, rec.agent_instance_id)
    if !ok || inst.run_count != rec.run_count do return
    inst.provider_session_id = ev.session_id
    value, err := json.parse_string(raw, .JSON, true, context.temp_allocator)
    if err != .None do return
    obj := value.(json.Object)
    payload, _ := json.marshal(obj["payload"], allocator = context.temp_allocator)
    e := live.Event{event = contracts.ext_event_kind_name(ev.kind), ts = ev.ts,
        session_id = ev.session_id, agent_id = ev.agent_id, tool_use_id = ev.tool_use_id,
        tool_name = ev.tool_name, payload = string(payload)}
    live.tool_live_extension(&bridge_tool_tracker, inst, []live.Event{e})
}
bridge_tool_live_shell :: proc(s: Bridge_Shell_Session, starting: bool, replaced_seq: int = -1) {
    if bridge_tool_tracker.get_instance == nil do return
    row := live.Shell{session_id = s.session_id, kind = "run" if s.kind == .Run else "",
        agent_instance_id = s.agent_instance_id, run_seq = s.run_seq,
        started_at_ms = s.started_unix_ms, finished_at_ms = s.finished_unix_ms,
        status = bridge_shell_session_status_str(s.status), exit_code = s.exit_code, exit_code_set = s.exit_code_set}
    if starting && replaced_seq >= 0 { row.started_at_ms = 0; row.finished_at_ms = 0 }
    live.tool_live_shell(&bridge_tool_tracker, row, starting, replaced_seq)
    // A very short process may exit between local registration and the start
    // snapshot. The terminal row is an observed lifecycle fact, not inventory.
    if starting && bridge_shell_session_status_is_terminal(s.status) do live.tool_live_shell(&bridge_tool_tracker,row,false)
}
bridge_tool_live_shell_exit :: proc(raw: string) {
    if bridge_tool_tracker.get_instance == nil do return
    id := extract_json_string(raw, "session_id", ""); defer delete(id)
    session, ok := bridge_shell_session_snapshot(&bridge_shell_session_map, id)
    if !ok do return
    defer bridge_shell_session_snapshot_destroy(&bridge_shell_session_map, session)
    seq := extract_json_int(raw, "run_seq", 0)
    // A late previous-run exit must not target a restarted process.
    if seq != session.run_seq do return
    session.exit_code = extract_json_int(raw, "exit_code", session.exit_code)
    session.exit_code_set = true
    status := extract_json_string(raw, "status", "exited"); defer delete(status)
    switch status {
    case "killed": session.status = .Killed
    case "failed": session.status = .Failed
    case: session.status = .Exited
    }
    bridge_tool_live_shell(session, false)
}
bridge_tool_live_send_snapshot :: proc(conn: ^ws.Connection, body: string) -> bool {
    snapshot, err := json.parse_string(body, .JSON, true, context.temp_allocator)
    if err != .None do return false
    obj := snapshot.(json.Object)
    run, _ := obj["run_count"].(json.Integer)
    bridge_tool_wire_seq += 1
    frame := struct {type, epoch: string, seq: u64, run_count: int, snapshot: json.Value}{
        type = "tool_activity_live_snapshot", epoch = fmt.tprintf("%d", bridge_tool_tracker.tool_live.epoch),
        seq = bridge_tool_wire_seq, run_count = int(run), snapshot = snapshot}
    data, _ := json.marshal(frame, allocator = context.temp_allocator)
    return bridge_hub_send(conn, string(data))
}
bridge_tool_live_drain :: proc(conn: ^ws.Connection, reconnect := false) {
    if bridge_tool_tracker.get_instance == nil do return
    context.allocator = runtime.heap_allocator()
    sync.mutex_lock(&bridge_tool_out_mutex)
    full := reconnect || bridge_tool_resync
    dirty := bridge_tool_dirty
    bridge_tool_dirty = nil; bridge_tool_resync = false; bridge_tool_dirty_bytes = 0
    sync.mutex_unlock(&bridge_tool_out_mutex)
    defer {
        for key, val in dirty { delete(key); delete(val) }
        delete(dirty)
    }
    if !full && len(dirty) == 0 do return
    if reconnect do bridge_tool_wire_seq = 0
    success := true
    if full {
        bridge_tool_wire_seq += 1
        frame := struct {type, epoch: string, seq: u64}{
            type = "tool_activity_live_reset", epoch = fmt.tprintf("%d", bridge_tool_tracker.tool_live.epoch), seq = bridge_tool_wire_seq}
        data, _ := json.marshal(frame, allocator = context.temp_allocator)
        success = bridge_hub_send(conn, string(data))
        // Overflow/reconnect recovery is explicitly requested by clients, rather
        // than broadcasting every instance or polling idle state.
        if success do success = bridge_hub_send(conn, `{"type":"tool_activity_live_resync"}`)
    }
    for _, body in dirty do if success do success = bridge_tool_live_send_snapshot(conn, body)
    if !success {
        sync.mutex_lock(&bridge_tool_out_mutex); bridge_tool_resync = true; sync.mutex_unlock(&bridge_tool_out_mutex)
        conn.connected = false
    }
}

// A one-shot bounded request, invoked only by UI attach/reconnect/explicit resync.
bridge_tool_live_handle_request :: proc(conn: ^ws.Connection, raw: string) {
    if !live.wire_shape_ok(raw) || len(raw) > 4096 do return
    id := extract_json_string(raw, "instance_id", ""); defer delete(id)
    request_id := extract_json_string(raw, "request_id", ""); defer delete(request_id)
    if len(id) == 0 || len(id) > live.TOOL_LIVE_ID_MAX || len(request_id) == 0 || len(request_id) > 128 do return
    inst, exists := bridge_tool_live_instance(nil, id)
    if !exists do return
    if live.terminal(inst.runtime_status) do bridge_tool_live_clear(id)
    body := live.tool_live_snapshot(&bridge_tool_tracker, inst); defer delete(body)
    snapshot, err := json.parse_string(body, .JSON, true, context.temp_allocator)
    if err != .None do return
    frame := struct {type, request_id, epoch: string, run_count: int, snapshot: json.Value}{
        type = "tool_activity_live_reply", request_id = request_id,
        epoch = fmt.tprintf("%d", bridge_tool_tracker.tool_live.epoch), run_count = inst.run_count, snapshot = snapshot}
    data, _ := json.marshal(frame, allocator = context.temp_allocator)
    if len(data) <= live.MAX_FRAME_BYTES && conn != nil do _ = bridge_hub_send(conn, string(data))
}

bridge_tool_live_note_launch :: proc(id:string) {
    bridge_tool_live_clear(id)
    if bridge_tool_tracker.get_instance == nil do return
    sync.mutex_lock(&bridge_tool_out_mutex); bridge_tool_resync=true; sync.mutex_unlock(&bridge_tool_out_mutex)
}
