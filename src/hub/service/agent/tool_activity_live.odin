package agent

import "core:encoding/json"
import "core:sync"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import live "odin_test:lib/tool_live"

tool_live_text :: proc(o: json.Object, key: string) -> string {
    v, _ := o[key].(json.String); return string(v)
}
tool_live_instance :: proc(service: ^Agent_Service, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
    context.allocator = context.temp_allocator
    if service.agents != nil && service.agents.get_tool_instance != nil do return service.agents.get_tool_instance(service.agents.ctx, id)
    return iface.agent_get_instance(service.agents, id)
}
tool_live_valid_snapshot :: proc(obj: json.Object) -> bool {
    if len(tool_live_text(obj, "instance_id")) == 0 || len(tool_live_text(obj, "instance_id")) > live.TOOL_LIVE_ID_MAX do return false
    active, ok := obj["active"].(json.Array)
    if !ok || len(active) > live.TOOL_LIVE_MAX_ACTIVE do return false
    for v in active {
        c, is_obj := v.(json.Object)
        if !is_obj do return false
        for k, field in c {
            switch k {
            case "call_id":
                str, is_str := field.(json.String)
                if !is_str || len(str) > live.MAX_KEY_BYTES do return false
            case "summary":
                str, is_str := field.(json.String)
                if !is_str || len(str) > live.TOOL_LIVE_SUMMARY_MAX do return false
            case "summary_truncated":
                if _, is_bool := field.(json.Boolean); !is_bool do return false
            case "tool_name":
                str, is_str := field.(json.String)
                if !is_str || len(str) > live.TOOL_LIVE_NAME_MAX do return false
            case "source", "provider_session_id", "agent_id", "tool_use_id", "shell_session_id":
                str, is_str := field.(json.String)
                if !is_str || len(str) > live.TOOL_LIVE_ID_MAX do return false
            case "shell_run_seq", "started_at_ms":
                n, is_int := field.(json.Integer)
                if !is_int || n < 0 do return false
            case: return false
            }
        }
        if tool_live_text(c, "call_id") == "" do return false
    }
    completed, completed_ok := obj["completed_since_last"].(json.Array)
    if !completed_ok || len(completed) > live.TOOL_LIVE_MAX_ACTIVE do return false
    for item in completed {
        c, is_obj := item.(json.Object)
        if !is_obj do return false
        for k, field in c {
            switch k {
            case "call_id", "source", "tool_name", "status", "summary":
                str, is_str := field.(json.String)
                limit := live.TOOL_LIVE_NAME_MAX
                if k == "call_id" do limit = live.MAX_KEY_BYTES
                if k == "summary" do limit = live.TOOL_LIVE_SUMMARY_MAX
                if !is_str || len(str) > limit do return false
            case "summary_truncated":
                if _, is_bool := field.(json.Boolean); !is_bool do return false
            case "duration_ms", "completed_at_ms":
                n, is_int := field.(json.Integer)
                if !is_int || n < 0 do return false
            case: return false
            }
        }
    }
    rev, rev_ok := obj["revision"].(json.Integer)
    gen, gen_ok := obj["generation"].(json.Integer)
    return rev_ok && gen_ok && rev >= 0 && gen >= 1
}
tool_live_normalize :: proc(inst: domain.Agent_Instance, snap: json.Object) -> string {
    obj := make(json.Object, context.temp_allocator)
    for key in ([]string{"epoch", "generation", "revision", "run_count", "active", "completed_since_last"}) { obj[key] = snap[key] }
    obj["type"] = json.String("tool_activity_live")
    obj["instance_id"] = json.String(inst.agent_instance_id)
    obj["agent_id"] = json.String(inst.agent_id)
    obj["display_name"] = json.String(inst.display_name)
    obj["chain_id"] = json.String(inst.chain_id)
    obj["bridge_id"] = json.String(inst.bridge_id)
    obj["availability"] = json.String("ready")
    data, _ := json.marshal(json.Value(obj))
    if len(data) > live.MAX_FRAME_BYTES { delete(data); return "" }
    return string(data)
}

// Only current authenticated Bridge traffic reaches this boundary. The route
// stores identity/refcount/order metadata, never a snapshot or completion cache.
tool_live_apply_bridge :: proc(svc: ^Agent_Service, bridge_id: string, connection_generation: int, source_epoch, raw: string) -> bool {
    if svc == nil || source_epoch == "" || !live.wire_shape_ok(raw) do return false
    value, err := json.parse_string(raw, .JSON, true, context.temp_allocator)
    if err != .None do return false
    root, ok := value.(json.Object)
    kind := tool_live_text(root, "type")
    if !ok || (kind != "tool_stream_state" && kind != "tool_stream_unavailable") || tool_live_text(root, "epoch") != source_epoch do return false
    snap, snap_ok := root["snapshot"].(json.Object)
    if kind == "tool_stream_state" && (!snap_ok || !tool_live_valid_snapshot(snap) || tool_live_text(snap, "epoch") != source_epoch) do return false
    id := tool_live_text(snap, "instance_id")
    if kind == "tool_stream_unavailable" do id = tool_live_text(root, "instance_id")
    inst, found, _ := tool_live_instance(svc, id)
    run, run_ok := root["run_count"].(json.Integer)
    snap_run, snap_run_ok := snap["run_count"].(json.Integer)
    if !found || inst.bridge_id != bridge_id || !run_ok || int(run) != inst.run_count do return false
    if kind == "tool_stream_state" && (!snap_run_ok || run != snap_run) do return false
    s := &svc.tool_live
    sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
    r := s.routes[id]
    if r == nil || r.bridge != bridge_id || r.owner != string(inst.owner_user_id) || r.token != tool_live_text(root, "subscription_id") do return false
    if r.run != inst.run_count {
        _ = tool_stream_reconcile_locked(svc, r, inst)
        return false
    }
    if r.suspended || r.connection_generation != connection_generation do return false
    if kind == "tool_stream_unavailable" {
        reason := tool_live_text(root, "reason")
        if reason != "not_found" && reason != "instance_changed" && reason != "capacity" && reason != "state_too_large" do return false
        tool_stream_unavailable_locked(s, r, reason)
        return true
    }
    gen, _ := snap["generation"].(json.Integer)
    rev, _ := snap["revision"].(json.Integer)
    if i64(gen) < r.generation || (i64(gen) == r.generation && i64(rev) < r.revision) do return false
    r.generation = i64(gen); r.revision = i64(rev)
    normalized := tool_live_normalize(inst, snap); defer delete(normalized)
    if normalized == "" do return false
    snapshot, _ := json.parse_string(normalized, .JSON, true, context.temp_allocator)
    baseline, _ := root["baseline"].(json.Boolean)
    refresh, _ := root["refresh"].(json.Boolean)
    frame := struct {type, instance_id: string, baseline, refresh: bool, snapshot: json.Value}{"state", id, bool(baseline), bool(refresh), snapshot}
    data, _ := json.marshal(frame, allocator = context.temp_allocator)
    for _, w in s.viewers {
        if w.owner == r.owner && w.ids[id] do _ = tool_stream_enqueue_locked(w, string(data))
    }
    return true
}
