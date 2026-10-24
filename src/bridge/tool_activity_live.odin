package main

// Bridge owns the reducer. Hooks and shell lifecycle only mark watched instances
// dirty. The runtime writer serializes/coalesces visible changes once per second;
// zero viewers means no snapshot work. Watched active state refreshes every 60s.
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import live "odin_test:lib/tool_live"
import contracts "odin_test:contracts"
import ws "odin_test:lib/ws"

bridge_tool_tracker: live.Tracker
bridge_tool_out_mutex: sync.Mutex
bridge_tool_wire_seq: u64
BRIDGE_TOOL_REFRESH_NS :: i64(60 * time.Second)
Bridge_Tool_Subscription :: struct {
    token: string,
    visible: string,
    dirty, active: bool,
    lease_until_ns: i64,
    last_emit_ns: i64, // monotonic; reset only by a successfully sent state
}
bridge_tool_subscriptions: map[string]Bridge_Tool_Subscription
bridge_tool_last_flush_ns: i64

bridge_tool_live_init :: proc() {
    live.tool_live_init(&bridge_tool_tracker.tool_live)
    bridge_tool_tracker.demand_driven = true
    bridge_tool_tracker.get_instance = bridge_tool_live_instance
    bridge_tool_tracker.changed = bridge_tool_live_enqueue
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
bridge_tool_live_enqueue :: proc(ctx: rawptr, id: string) {
    context.allocator = runtime.heap_allocator()
    sync.mutex_lock(&bridge_tool_out_mutex)
    defer sync.mutex_unlock(&bridge_tool_out_mutex)
    if sub, subscribed := bridge_tool_subscriptions[id]; subscribed {
        sub.dirty = true
        bridge_tool_subscriptions[id] = sub
    }
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
    po, ok_po := obj["payload"].(json.Object)
    if !ok_po do po = make(json.Object, context.temp_allocator)
    tool, _ := obj["tool"].(json.Object)
    po["input"] = tool["input"]
    payload, _ := json.marshal(po, allocator = context.temp_allocator)
    e := live.Event{event = contracts.ext_event_kind_name(ev.kind), ts = ev.ts,
        session_id = ev.session_id, agent_id = ev.agent_id, tool_use_id = ev.tool_use_id,
        tool_name = ev.tool_name, payload = string(payload)}
    live.tool_live_extension(&bridge_tool_tracker, inst, []live.Event{e})
}
bridge_tool_live_shell :: proc(s: Bridge_Shell_Session, starting: bool, replaced_seq: int = -1) {
    if bridge_tool_tracker.get_instance == nil do return
    row := live.Shell{session_id = s.session_id, kind = "run" if s.kind == .Run else "",
        agent_instance_id = s.agent_instance_id, run_seq = s.run_seq, command = s.cmd,
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

// Equality deliberately excludes revision: starting and removing a call within
// an interval may leave only its completion, or no visible change after a reset.
bridge_tool_live_visible :: proc(body: string, active_only := false) -> string {
    v, err := json.parse_string(body, .JSON, true, context.temp_allocator)
    if err != .None do return ""
    obj, ok := v.(json.Object)
    if !ok do return ""
    if active_only do obj["completed_since_last"] = make(json.Array, 0, context.temp_allocator)
    // Struct fields and sorted nested objects make equality independent of
    // the JSON parser's per-map iteration order. Revision is intentionally absent.
    row := struct {active, completed: json.Value, epoch: string, generation, run: json.Value}{
        obj["active"], obj["completed_since_last"], live.tool_live_text(obj,"epoch"), obj["generation"], obj["run_count"]}
    bytes, _ := json.marshal(row, {sort_maps_by_key = true})
    return string(bytes)
}
bridge_tool_live_emit :: proc(conn: ^ws.Connection, id: string, sub: ^Bridge_Tool_Subscription, baseline: bool, refresh := false, now_ns: i64 = 0) -> bool {
    now := now_ns if now_ns != 0 else time.tick_now()._nsec
    if sub.lease_until_ns <= now do return true
    inst, exists := bridge_tool_live_instance(nil, id)
    if !exists {
        sub.active = false
        return bridge_tool_live_unavailable(conn, id, sub.token, "not_found", 0)
    }
    body := live.tool_live_snapshot(&bridge_tool_tracker, inst, consume = !baseline, baseline = baseline)
    defer delete(body)
    visible := bridge_tool_live_visible(body)
    defer delete(visible)
    if !baseline && !refresh && visible == sub.visible do return true
    snap, err := json.parse_string(body, .JSON, true, context.temp_allocator)
    if err != .None do return false
    bridge_tool_wire_seq += 1
    frame := struct {type, epoch, subscription_id: string, seq: u64, run_count: int, baseline, refresh: bool, snapshot: json.Value}{
        "tool_stream_state", fmt.tprintf("%d", bridge_tool_tracker.tool_live.epoch), sub.token,
        bridge_tool_wire_seq, inst.run_count, baseline, refresh, snap}
    data, _ := json.marshal(frame, allocator = context.temp_allocator)
    if len(data) > live.MAX_FRAME_BYTES {
        sub.active = false
        return bridge_tool_live_unavailable(conn, id, sub.token, "state_too_large", inst.run_count)
    }
    if !bridge_hub_send(conn, string(data)) do return false
    sub.last_emit_ns = now_ns if now_ns != 0 else time.tick_now()._nsec
    sub.active = len(snap.(json.Object)["active"].(json.Array)) > 0
    delete(sub.visible)
    // Completed batches are one-shot. Compare next interval with active-only state,
    // so no redundant empty follow-up is emitted just to erase the old batch.
    sub.visible = bridge_tool_live_visible(body, active_only = true)
    return true
}
bridge_tool_live_drain :: proc(conn: ^ws.Connection, reconnect := false) {
    bridge_tool_live_drain_at(conn, time.tick_now()._nsec, reconnect)
}
// Explicit clock keeps scheduling tests deterministic and avoids wall-clock jumps.
bridge_tool_live_drain_at :: proc(conn: ^ws.Connection, now_ns: i64, reconnect := false) {
    if bridge_tool_tracker.get_instance == nil do return
    context.allocator = runtime.heap_allocator()
    sync.mutex_lock(&bridge_tool_out_mutex)
    defer sync.mutex_unlock(&bridge_tool_out_mutex)
    if reconnect {
        bridge_tool_live_unwatch_locked()
        bridge_tool_wire_seq = 0
        bridge_tool_last_flush_ns = now_ns
        frame := struct {type, epoch: string}{"tool_stream_reset", fmt.tprintf("%d", bridge_tool_tracker.tool_live.epoch)}
        data, _ := json.marshal(frame, allocator = context.temp_allocator)
        _ = bridge_hub_send(conn, string(data))
        return
    }
    if len(bridge_tool_subscriptions) == 0 do return
    batch_due := now_ns - bridge_tool_last_flush_ns >= i64(time.Second)
    if batch_due do bridge_tool_last_flush_ns = now_ns
    expired := make([dynamic]string, context.temp_allocator)
    for id, sub in bridge_tool_subscriptions do if now_ns >= sub.lease_until_ns do append(&expired, id)
    for id in expired {
        sub := bridge_tool_subscriptions[id]
        live.tool_live_watch(&bridge_tool_tracker, id, false)
        delete_key(&bridge_tool_subscriptions, id)
        delete(id); delete(sub.token); delete(sub.visible)
    }
    for id, &sub in bridge_tool_subscriptions {
        // A freshness deadline is per instance and is not delayed by the
        // one-second changed-state batch gate. Empty idle state does no work.
        refresh := sub.active && now_ns - sub.last_emit_ns >= BRIDGE_TOOL_REFRESH_NS
        if !refresh && !(batch_due && sub.dirty) do continue
        sub.dirty = false
        if !bridge_tool_live_emit(conn, id, &sub, false, refresh, now_ns) do conn.connected = false
    }
}
bridge_tool_live_handle_subscription :: proc(conn: ^ws.Connection, raw: string) {
    if !live.wire_shape_ok(raw) || len(raw) > 4096 do return
    context.allocator = runtime.heap_allocator()
    id := extract_json_string(raw, "instance_id", ""); defer delete(id)
    token := extract_json_string(raw, "subscription_id", ""); defer delete(token)
    kind := extract_json_string(raw, "type", ""); defer delete(kind)
    if len(id) == 0 || len(id) > live.TOOL_LIVE_ID_MAX || len(token) == 0 || len(token) > 128 do return
    sync.mutex_lock(&bridge_tool_out_mutex)
    defer sync.mutex_unlock(&bridge_tool_out_mutex)
    sub, exists := bridge_tool_subscriptions[id]
    if kind == "tool_stream_detach" {
        if !exists || sub.token != token do return
        live.tool_live_watch(&bridge_tool_tracker, id, false)
        for key in bridge_tool_subscriptions {
            if key == id { delete_key(&bridge_tool_subscriptions, key); delete(key); break }
        }
        delete(sub.token); delete(sub.visible)
        return
    }
    if kind != "tool_stream_attach" do return
    version := extract_json_int(raw, "version", 0)
    lease_ms := extract_json_int(raw, "lease_ms", 0)
    if version != 2 || lease_ms <= 0 || lease_ms > 15_000 do return
    inst, found := bridge_tool_live_instance(nil, id)
    expected_run := extract_json_int(raw, "run_count", -1)
    if !found { _ = bridge_tool_live_unavailable(conn, id, token, "not_found", expected_run); return }
    if expected_run != inst.run_count { _ = bridge_tool_live_unavailable(conn, id, token, "instance_changed", expected_run); return }
    if !exists {
        if len(bridge_tool_subscriptions) >= live.TOOL_LIVE_MAX_INSTANCES { _ = bridge_tool_live_unavailable(conn, id, token, "capacity", expected_run); return }
        if bridge_tool_subscriptions == nil do bridge_tool_subscriptions = make(map[string]Bridge_Tool_Subscription)
        bridge_tool_subscriptions[strings.clone(id)] = {}
        live.tool_live_watch(&bridge_tool_tracker, id, true)
    }
    if sub.token != token {
        // A new logical producer starts with no completion history. Rebaselining
        // the same producer for an additional viewer preserves its pending batch.
        if exists { live.tool_live_watch(&bridge_tool_tracker, id, false); live.tool_live_watch(&bridge_tool_tracker, id, true) }
        delete(sub.token); sub.token = strings.clone(token)
    }
    sub.lease_until_ns = time.tick_now()._nsec + i64(lease_ms) * i64(time.Millisecond)
    renew := strings.contains(raw, `"renew":true`)
    if !renew || !exists || sub.visible == "" {
        if !bridge_tool_live_emit(conn, id, &sub, true) do conn.connected = false
    }
    bridge_tool_subscriptions[id] = sub
    if !renew do bridge_blockers_mark_all_dirty(id)
}
bridge_tool_live_note_launch :: proc(id: string) {
    bridge_tool_live_clear(id)
}
bridge_tool_live_unwatch_locked :: proc() {
    for id, sub in bridge_tool_subscriptions {
        live.tool_live_watch(&bridge_tool_tracker, id, false)
        delete(id, runtime.heap_allocator()); delete(sub.token, runtime.heap_allocator()); delete(sub.visible, runtime.heap_allocator())
    }
    delete(bridge_tool_subscriptions); bridge_tool_subscriptions = nil
}
bridge_tool_live_disconnect :: proc() {
    sync.mutex_lock(&bridge_tool_out_mutex)
    defer sync.mutex_unlock(&bridge_tool_out_mutex)
    bridge_tool_live_unwatch_locked()
}
bridge_tool_live_unavailable :: proc(conn: ^ws.Connection, id, token, reason: string, run: int) -> bool {
    bridge_tool_wire_seq += 1
    frame := struct {type, epoch, subscription_id, instance_id, reason: string, seq: u64, run_count: int}{
        "tool_stream_unavailable", fmt.tprintf("%d", bridge_tool_tracker.tool_live.epoch), token, id, reason, bridge_tool_wire_seq, run}
    data, _ := json.marshal(frame, allocator = context.temp_allocator)
    return bridge_hub_send(conn, string(data))
}

Bridge_Tool_Demand :: struct { id, token: string, run: int }
bridge_tool_live_demands :: proc() -> [dynamic]Bridge_Tool_Demand {
    out := make([dynamic]Bridge_Tool_Demand, context.temp_allocator)
    sync.mutex_lock(&bridge_tool_out_mutex)
    defer sync.mutex_unlock(&bridge_tool_out_mutex)
    now := time.tick_now()._nsec
    for id, sub in bridge_tool_subscriptions {
        if sub.lease_until_ns <= now do continue
        inst, found := bridge_tool_live_instance(nil, id)
        if found do append(&out, Bridge_Tool_Demand{strings.clone(id, context.temp_allocator), strings.clone(sub.token, context.temp_allocator), inst.run_count})
    }
    return out
}


// Frames are authenticated by the hub runtime socket and generation dispatcher.
bridge_tool_live_handle_batch :: proc(conn: ^ws.Connection, raw: string) {
    if len(raw) > 32 * 1024 || !live.wire_shape_ok(raw) do return
    value, err := json.parse_string(raw, .JSON, true, context.temp_allocator)
    root, obj := value.(json.Object)
    if err != .None || !obj do return
    controls, array := root["controls"].(json.Array)
    if !array || len(controls) > 64 do return
    for control in controls {
        data, _ := json.marshal(control, allocator = context.temp_allocator)
        bridge_tool_live_handle_subscription(conn, string(data))
    }
}
