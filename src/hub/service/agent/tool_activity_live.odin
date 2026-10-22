package agent

// Relay-only Hub: no tool strings, snapshots, completions or tombstones survive
// a request. This fixed table is transient correlation state, not a tool cache.
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import project_service "odin_test:hub/service/project"
import events "odin_test:hub/service/events"
import live "odin_test:lib/tool_live"

TOOL_LIVE_MAX_PENDING :: 8
TOOL_LIVE_PER_OWNER_PENDING :: 2
TOOL_LIVE_TIMEOUT :: 5 * time.Second
Tool_Live_Pending :: struct {
    used, done, cancelled: bool,
    request_id, owner, bridge_id, instance_id, reply: string,
    generation, run_count: int,
    deadline: time.Time,
}
Tool_Live_Store :: struct {
    mutex: sync.Mutex,
    cond: sync.Cond,
    nonce: u64,
    pending: [TOOL_LIVE_MAX_PENDING]Tool_Live_Pending,
    chain_owners: [2]string,
}
tool_live_init :: proc(s: ^Tool_Live_Store) {}
tool_live_text :: proc(o: json.Object, key: string) -> string {
    v, _ := o[key].(json.String); return string(v)
}
tool_live_instance :: proc(service: ^Agent_Service, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
    context.allocator = context.temp_allocator
    if service.agents != nil && service.agents.get_tool_instance != nil do return service.agents.get_tool_instance(service.agents.ctx, id)
    return iface.agent_get_instance(service.agents, id)
}
tool_live_publish :: proc(service: ^Agent_Service, owner, body: string) {
    if service.event_bus != nil do events.publish_raw_to_user(service.event_bus, owner, body)
}
tool_live_pending_free :: proc(p: ^Tool_Live_Pending) {
    heap := runtime.heap_allocator()
    delete(p.request_id, heap); delete(p.owner, heap); delete(p.bridge_id, heap)
    delete(p.instance_id, heap); delete(p.reply, heap)
    p^ = {}
}
tool_live_destroy :: proc(s: ^Tool_Live_Store) {
    sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
    for &p in s.pending do tool_live_pending_free(&p)
    for owner in s.chain_owners do delete(owner, runtime.heap_allocator())
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
    last := obj["last_completion"]
    if _, null := last.(json.Null); !null {
        c, is_obj := last.(json.Object)
        if !is_obj do return false
        for k, field in c {
            switch k {
            case "call_id", "source", "tool_name", "status":
                str, is_str := field.(json.String)
                limit := live.MAX_KEY_BYTES if k == "call_id" else live.TOOL_LIVE_NAME_MAX
                if !is_str || len(str) > limit do return false
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
    for key in ([]string{"epoch", "generation", "revision", "active", "last_completion"}) { obj[key] = snap[key] }
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
// Called only from an authenticated current Bridge connection. source_epoch is
// immutable connection metadata established by the process-epoch handshake.
tool_live_apply_bridge :: proc(service: ^Agent_Service, bridge_id: string, connection_generation: int, source_epoch, raw: string) -> bool {
    if service == nil || source_epoch == "" || !live.wire_shape_ok(raw) do return false
    value, err := json.parse_string(raw, .JSON, true, context.temp_allocator)
    if err != .None do return false
    root, is_obj := value.(json.Object)
    if !is_obj || tool_live_text(root, "epoch") != source_epoch do return false
    snap, snap_ok := root["snapshot"].(json.Object)
    if !snap_ok || !tool_live_valid_snapshot(snap) || tool_live_text(snap, "epoch") != source_epoch do return false
    id := tool_live_text(snap, "instance_id")
    inst, found, _ := tool_live_instance(service, id)
    run, run_ok := root["run_count"].(json.Integer)
    if !found || inst.bridge_id != bridge_id || !run_ok || int(run) != inst.run_count do return false
    kind := tool_live_text(root, "type")
    if kind == "tool_activity_live_reply" {
        request_id := tool_live_text(root, "request_id")
        if len(request_id) > 128 do return false
        s := &service.tool_live
        sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
        for &p in s.pending {
            if !p.used || p.done || p.request_id != request_id || p.bridge_id != bridge_id ||
                p.generation != connection_generation || p.instance_id != id || p.owner != string(inst.owner_user_id) ||
                p.run_count != inst.run_count || time.diff(time.now(), p.deadline) <= 0 { continue }
            context.allocator = runtime.heap_allocator()
            p.reply = tool_live_normalize(inst, snap)
            p.done = true; sync.cond_broadcast(&s.cond)
            return true
        }
        return false // unsolicited/late replies are never cached
    }
    if kind != "tool_activity_live_snapshot" || instance_runtime_is_terminal(inst.runtime_status) do return false
    body := tool_live_normalize(inst, snap); defer delete(body)
    tool_live_publish(service, string(inst.owner_user_id), body)
    return true
}
tool_live_cancel :: proc(service: ^Agent_Service, instance_id, bridge_id: string) {
    s := &service.tool_live
    sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
    for &p in s.pending {
        if p.used && ((instance_id != "" && p.instance_id == instance_id) || (bridge_id != "" && p.bridge_id == bridge_id)) {
            p.cancelled = true; p.done = true
        }
    }
    sync.cond_broadcast(&s.cond)
}
tool_live_clear :: proc(service: ^Agent_Service, instance_id: string) {
    if service == nil do return
    tool_live_cancel(service, instance_id, "")
    inst, found, _ := tool_live_instance(service, instance_id)
    if !found do return
    frame := struct {type, instance_id, availability: string}{"tool_activity_live_unavailable", instance_id, "offline" if inst.runtime_status == "unreachable" else "unknown"}
    data, _ := json.marshal(frame, allocator = context.temp_allocator)
    tool_live_publish(service, string(inst.owner_user_id), string(data))
}
tool_live_clear_bridge :: proc(service: ^Agent_Service, bridge_id: string) {
    if service != nil do tool_live_cancel(service, "", bridge_id)
}
tool_live_request_snapshot :: proc(service: ^Agent_Service, inst: domain.Agent_Instance, timeout: time.Duration = TOOL_LIVE_TIMEOUT) -> (string, bool, domain.Domain_Error) {
    if timeout <= 0 do return "", false, domain.domain_error(.Bridge_Offline, "live snapshot deadline exceeded")
    if service == nil || len(inst.agent_instance_id) > 64 || len(inst.bridge_id) > 64 || len(string(inst.owner_user_id)) > 512 do return "", false, domain.domain_error(.Validation_Failed, "live tool identity exceeds bounds")
    s := &service.tool_live
    sync.mutex_lock(&s.mutex)
    index := -1; own_count := 0
    for p, i in s.pending {
        if !p.used { if index < 0 do index = i; continue }
        if p.owner == string(inst.owner_user_id) do own_count += 1
    }
    if index < 0 || own_count >= TOOL_LIVE_PER_OWNER_PENDING {
        sync.mutex_unlock(&s.mutex)
        return "", false, domain.domain_error(.Bridge_Busy, "live snapshot request capacity exceeded")
    }
    s.nonce += 1
    generation := project_service.bridge_runtime_registry_generation(service.bridge_runtime_registry, inst.bridge_id)
    heap := runtime.heap_allocator()
    p := &s.pending[index]
    p^ = {used = true, request_id = strings.clone(fmt.tprintf("tl_%d_%d", time.to_unix_nanoseconds(time.now()), s.nonce), heap),
        owner = strings.clone(string(inst.owner_user_id), heap), bridge_id = strings.clone(inst.bridge_id, heap),
        instance_id = strings.clone(inst.agent_instance_id, heap), generation = generation, run_count = inst.run_count,
        deadline = time.time_add(time.now(), min(timeout, TOOL_LIVE_TIMEOUT))}
    request_id := p.request_id
    sync.mutex_unlock(&s.mutex)
    defer {
        sync.mutex_lock(&s.mutex); tool_live_pending_free(p); sync.mutex_unlock(&s.mutex)
    }
    command := struct {type, request_id, instance_id: string, timeout_ms: int}{"tool_activity_live_request", request_id, inst.agent_instance_id, 5000}
    data, _ := json.marshal(command, allocator = context.temp_allocator)
    sent, send_err := project_service.bridge_command_send_runtime(service.bridge_command_sink,
        project_service.Runtime_Command{bridge_id = inst.bridge_id, body_json = string(data)})
    if !sent do return "", false, send_err
    sync.mutex_lock(&s.mutex)
    for !p.done {
        remaining := time.diff(time.now(), p.deadline)
        if remaining <= 0 do break
        _ = sync.cond_wait_with_timeout(&s.cond, &s.mutex, remaining)
    }
    success := p.done && !p.cancelled && p.reply != ""
    reply: string
    if success do reply = strings.clone(p.reply)
    sync.mutex_unlock(&s.mutex)
    if !success do return "", false, domain.domain_error(.Bridge_Offline, "live snapshot unavailable or deadline exceeded")
    fresh, found, _ := tool_live_instance(service, inst.agent_instance_id)
    if !found || fresh.run_count != inst.run_count || fresh.bridge_id != inst.bridge_id || fresh.owner_user_id != inst.owner_user_id {
        delete(reply)
        return "", false, domain.domain_error(.Bridge_Offline, "instance changed during live snapshot request")
    }
    return reply, true, {}
}

// At most two chain-page assemblies globally and one per owner. Each page is
// eight <=256 KiB snapshots (<=2 MiB), with one absolute five-second deadline.
tool_live_chain_admit :: proc(s:^Tool_Live_Store, owner:string) -> int {
    if owner == "" || len(owner)>512 do return -1
    sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
    slot := -1
    for existing,i in s.chain_owners {
        if existing == owner do return -1
        if existing == "" do slot=i
    }
    if slot>=0 do s.chain_owners[slot]=strings.clone(owner,runtime.heap_allocator())
    return slot
}
tool_live_chain_release :: proc(s:^Tool_Live_Store, slot:int) {
    sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
    delete(s.chain_owners[slot],runtime.heap_allocator()); s.chain_owners[slot]=""
}
