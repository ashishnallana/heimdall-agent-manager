package agent

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import domain "odin_test:hub/domain"
import project_service "odin_test:hub/service/project"
import ws "odin_test:lib/ws"
import live "odin_test:lib/tool_live"

TOOL_STREAM_MAX_VIEWERS :: 64
TOOL_STREAM_MAX_ROUTES :: 1024
TOOL_STREAM_QUEUE_BYTES :: 2 * 1024 * 1024
TOOL_STREAM_QUEUE_FRAMES :: 512
Tool_Stream_Frame :: struct { text: string, opcode: u8 }
Tool_Stream_Viewer :: struct {
    owner: string,
    socket: net.TCP_Socket,
    ids: map[string]bool,
    queue: [dynamic]Tool_Stream_Frame,
    bytes: int, // includes the writer's in-flight frame
    stopped: bool,
    cond: sync.Cond,
    worker: ^thread.Thread,
    service: ^Agent_Service,
}
Tool_Stream_Route :: struct {
    id, owner, bridge, token: string,
    run, connection_generation, viewers: int,
    generation, revision: i64,
}
Tool_Stream_Control :: struct { bridge, id, token: string, run: int, attach: bool }
Tool_Live_Store :: struct {
    mutex: sync.Mutex,
    viewers: map[net.TCP_Socket]^Tool_Stream_Viewer,
    routes: map[string]^Tool_Stream_Route,
    controls: [dynamic]Tool_Stream_Control,
    control_cond: sync.Cond,
    control_worker: ^thread.Thread,
    stopped: bool,
    nonce: u64,
}

tool_live_init :: proc(s: ^Tool_Live_Store) {}
tool_stream_token_locked :: proc(s: ^Tool_Live_Store) -> string {
    s.nonce += 1
    return strings.clone(fmt.tprintf("%d_%d", time.to_unix_nanoseconds(time.now()), s.nonce), runtime.heap_allocator())
}
tool_stream_control_free :: proc(c: Tool_Stream_Control) {
    heap := runtime.heap_allocator()
    delete(c.bridge, heap); delete(c.id, heap); delete(c.token, heap)
}
// Coalesce controls per bridge/instance. A sole worker preserves attach/detach
// order without ever writing a socket or waiting on the Bridge reader thread.
tool_stream_control_locked :: proc(s: ^Tool_Live_Store, r: ^Tool_Stream_Route, attach: bool) {
    heap := runtime.heap_allocator()
    c := Tool_Stream_Control{strings.clone(r.bridge, heap), strings.clone(r.id, heap), strings.clone(r.token, heap), r.run, attach}
    for &old in s.controls {
        if old.bridge == c.bridge && old.id == c.id {
            tool_stream_control_free(old); old = c
            sync.cond_signal(&s.control_cond)
            return
        }
    }
    if len(s.controls) >= 2 * TOOL_STREAM_MAX_ROUTES {
        tool_stream_control_free(c)
        return // cosmetic best effort; reconnect/subscription earns a new baseline
    }
    append(&s.controls, c)
    sync.cond_signal(&s.control_cond)
}
tool_stream_control_run :: proc(raw: rawptr) {
    context = runtime.default_context()
    svc := (^Agent_Service)(raw)
    s := &svc.tool_live
    for {
        sync.mutex_lock(&s.mutex)
        for len(s.controls) == 0 && !s.stopped do sync.cond_wait(&s.control_cond, &s.mutex)
        if s.stopped { sync.mutex_unlock(&s.mutex); return }
        c := s.controls[0]; ordered_remove(&s.controls, 0)
        sync.mutex_unlock(&s.mutex)
        frame := struct {type, instance_id, subscription_id: string, run_count: int}{
            "tool_stream_attach" if c.attach else "tool_stream_detach", c.id, c.token, c.run}
        data, _ := json.marshal(frame)
        sent, _ := project_service.bridge_command_send_runtime(svc.bridge_command_sink,
            project_service.Runtime_Command{bridge_id = c.bridge, body_json = string(data)})
        delete(data)
        if !sent && c.attach {
            sync.mutex_lock(&s.mutex)
            if r := s.routes[c.id]; r != nil && r.token == c.token do tool_stream_unavailable_locked(s, r, "bridge_offline")
            sync.mutex_unlock(&s.mutex)
        }
        tool_stream_control_free(c)
        free_all(context.temp_allocator)
    }
}
tool_stream_enqueue_locked :: proc(w: ^Tool_Stream_Viewer, text: string, opcode: u8 = 0x1) -> bool {
    if w.stopped do return false
    if len(w.queue) >= TOOL_STREAM_QUEUE_FRAMES || len(text) > TOOL_STREAM_QUEUE_BYTES - w.bytes {
        w.stopped = true
        sync.cond_signal(&w.cond)
        // The HTTP reader owns close. Shutdown only wakes that owner.
        _ = net.shutdown(w.socket, .Both)
        return false
    }
    append(&w.queue, Tool_Stream_Frame{strings.clone(text, runtime.heap_allocator()), opcode})
    w.bytes += len(text)
    sync.cond_signal(&w.cond)
    return true
}
tool_stream_writer_run :: proc(raw: rawptr) {
    context = runtime.default_context()
    w := (^Tool_Stream_Viewer)(raw)
    s := &w.service.tool_live
    for {
        sync.mutex_lock(&s.mutex)
        for len(w.queue) == 0 && !w.stopped do sync.cond_wait(&w.cond, &s.mutex)
        if w.stopped { sync.mutex_unlock(&s.mutex); return }
        f := w.queue[0]; ordered_remove(&w.queue, 0)
        sync.mutex_unlock(&s.mutex)
        result := ws.write_server_opcode(w.socket, f.opcode, f.text, true)
        sync.mutex_lock(&s.mutex)
        w.bytes -= len(f.text)
        if result != .Ok {
            w.stopped = true
            _ = net.shutdown(w.socket, .Both)
        }
        sync.mutex_unlock(&s.mutex)
        delete(f.text, runtime.heap_allocator())
        if result != .Ok do return
    }
}
tool_stream_open :: proc(svc: ^Agent_Service, owner: string, socket: net.TCP_Socket) -> ^Tool_Stream_Viewer {
    context.allocator = runtime.heap_allocator()
    s := &svc.tool_live
    sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
    if s.stopped || len(s.viewers) >= TOOL_STREAM_MAX_VIEWERS || owner == "" do return nil
    if s.control_worker == nil {
        s.controls = make([dynamic]Tool_Stream_Control)
        s.control_worker = thread.create_and_start_with_data(svc, tool_stream_control_run, self_cleanup = false)
        if s.control_worker == nil do return nil
    }
    if s.viewers == nil do s.viewers = make(map[net.TCP_Socket]^Tool_Stream_Viewer)
    if s.routes == nil do s.routes = make(map[string]^Tool_Stream_Route)
    w := new(Tool_Stream_Viewer)
    w^ = {owner = strings.clone(owner), socket = socket, service = svc,
        ids = make(map[string]bool), queue = make([dynamic]Tool_Stream_Frame)}
    _ = net.set_option(socket, .Send_Timeout, 5 * time.Second)
    w.worker = thread.create_and_start_with_data(w, tool_stream_writer_run, self_cleanup = false)
    if w.worker == nil { delete(w.owner); delete(w.ids); delete(w.queue); free(w); return nil }
    s.viewers[socket] = w
    return w
}
tool_stream_route_free :: proc(r: ^Tool_Stream_Route) {
    heap := runtime.heap_allocator()
    delete(r.id, heap); delete(r.owner, heap); delete(r.bridge, heap); delete(r.token, heap); free(r, heap)
}
tool_stream_remove_id_locked :: proc(s: ^Tool_Live_Store, w: ^Tool_Stream_Viewer, id: string) {
    r := s.routes[id]
    if r != nil {
        r.viewers -= 1
        if r.viewers == 0 {
            tool_stream_control_locked(s, r, false)
            delete_key(&s.routes, r.id)
            tool_stream_route_free(r)
        }
    }
    for key in w.ids {
        if key == id { delete_key(&w.ids, key); delete(key, runtime.heap_allocator()); break }
    }
}
tool_stream_close :: proc(svc: ^Agent_Service, w: ^Tool_Stream_Viewer) {
    s := &svc.tool_live
    sync.mutex_lock(&s.mutex)
    delete_key(&s.viewers, w.socket)
    for len(w.ids) > 0 { for id in w.ids { tool_stream_remove_id_locked(s, w, id); break } }
    w.stopped = true; sync.cond_signal(&w.cond)
    _ = net.shutdown(w.socket, .Both)
    sync.mutex_unlock(&s.mutex)
    thread.join(w.worker); thread.destroy(w.worker)
    heap := runtime.heap_allocator()
    for f in w.queue do delete(f.text, heap)
    delete(w.queue); delete(w.ids); delete(w.owner, heap); free(w, heap)
}
tool_stream_write :: proc(svc: ^Agent_Service, socket: net.TCP_Socket, text: string, opcode: u8 = 0x1) -> bool {
    s := &svc.tool_live
    sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
    w := s.viewers[socket]
    return w != nil && tool_stream_enqueue_locked(w, text, opcode)
}
tool_stream_unavailable_locked :: proc(s: ^Tool_Live_Store, r: ^Tool_Stream_Route, reason: string) {
    data, _ := json.marshal(struct {type, instance_id, reason: string}{"unavailable", r.id, reason}, allocator = context.temp_allocator)
    for _, w in s.viewers do if w.owner == r.owner && w.ids[r.id] do _ = tool_stream_enqueue_locked(w, string(data))
}
tool_stream_rebind_locked :: proc(svc: ^Agent_Service, r: ^Tool_Stream_Route, inst: domain.Agent_Instance, connection_generation: int) {
    s := &svc.tool_live
    tool_stream_control_locked(s, r, false)
    delete(r.bridge, runtime.heap_allocator()); delete(r.token, runtime.heap_allocator())
    r.bridge = strings.clone(inst.bridge_id, runtime.heap_allocator())
    r.token = tool_stream_token_locked(s)
    r.run = inst.run_count; r.connection_generation = connection_generation
    r.generation = 0; r.revision = 0
    tool_stream_control_locked(s, r, true)
}
// Resolve the destination generation from its own runtime connection. In
// particular, a reconnect on the former Bridge must never fence the new one.
tool_stream_reconcile_locked :: proc(svc: ^Agent_Service, r: ^Tool_Stream_Route, inst: domain.Agent_Instance) -> bool {
    s := &svc.tool_live
    if string(inst.owner_user_id) != r.owner {
        tool_stream_control_locked(s, r, false)
        tool_stream_unavailable_locked(s, r, "instance_changed")
        return false
    }
    generation := r.connection_generation
    if svc.bridge_runtime_registry != nil do generation = project_service.bridge_runtime_registry_generation(svc.bridge_runtime_registry, inst.bridge_id)
    if r.bridge != inst.bridge_id || r.run != inst.run_count || (svc.bridge_runtime_registry != nil && r.connection_generation != generation) {
        tool_stream_unavailable_locked(s, r, "instance_changed")
        tool_stream_rebind_locked(svc, r, inst, generation)
    }
    return true
}
// Validation is atomic: a rejected set leaves existing subscriptions intact.
tool_stream_subscribe :: proc(svc: ^Agent_Service, w: ^Tool_Stream_Viewer, ids: []string) -> string {
    if len(ids) > live.TOOL_LIVE_MAX_INSTANCES do return "too_many_instances"
    s := &svc.tool_live
    sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
    if w.stopped do return "closed"
    rows := make([]domain.Agent_Instance, len(ids), context.temp_allocator)
    additions := 0
    for id, i in ids {
        if !strings.has_prefix(id, "inst_") || len(id) > live.TOOL_LIVE_ID_MAX do return "invalid_instance_id"
        for earlier in ids[:i] do if earlier == id do return "duplicate_instance_id"
        inst, found, _ := tool_live_instance(svc, id)
        if !found || string(inst.owner_user_id) != w.owner do return "forbidden"
        rows[i] = inst
        if s.routes[id] == nil do additions += 1
    }
    if len(s.routes) + additions > TOOL_STREAM_MAX_ROUTES do return "capacity"
    // Save IDs to remove before mutating the map being iterated.
    removed := make([dynamic]string, context.temp_allocator)
    for id in w.ids {
        keep := false
        for wanted in ids do if wanted == id do keep = true
        if !keep do append(&removed, id)
    }
    for id in removed do tool_stream_remove_id_locked(s, w, id)
    ack, _ := json.marshal(struct {type: string, instance_ids: []string}{"subscribed", ids}, allocator = context.temp_allocator)
    _ = tool_stream_enqueue_locked(w, string(ack))
    for id, i in ids {
        inst := rows[i]
        r := s.routes[id]
        if r != nil && !tool_stream_reconcile_locked(svc, r, inst) do continue
        if w.ids[id] do continue
        if r == nil {
            heap := runtime.heap_allocator()
            r = new(Tool_Stream_Route, heap)
            r^ = {id = strings.clone(id, heap), owner = strings.clone(w.owner, heap), bridge = strings.clone(inst.bridge_id, heap),
                token = tool_stream_token_locked(s), run = inst.run_count,
                connection_generation = project_service.bridge_runtime_registry_generation(svc.bridge_runtime_registry, inst.bridge_id)}
            s.routes[r.id] = r
        }
        w.ids[strings.clone(id, runtime.heap_allocator())] = true
        r.viewers += 1
        // Additional viewers share the producer but earn a fresh Bridge baseline.
        tool_stream_control_locked(s, r, true)
    }
    return ""
}
tool_live_clear :: proc(svc: ^Agent_Service, instance_id: string) {
    if svc == nil do return
    s := &svc.tool_live
    sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
    if r := s.routes[instance_id]; r != nil {
        tool_stream_unavailable_locked(s, r, "instance_changed")
        inst, found, _ := tool_live_instance(svc, instance_id)
        if !found { tool_stream_control_locked(s, r, false); return }
        if tool_stream_reconcile_locked(svc, r, inst) {
            // A launch may not exist at configuration commit. Its ready event
            // earns another baseline, even when bridge/run did not change.
            tool_stream_control_locked(s, r, true)
        }
    }
}
tool_live_clear_bridge :: proc(svc: ^Agent_Service, bridge_id: string) {
    if svc == nil do return
    s := &svc.tool_live
    sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
    for _, r in s.routes do if r.bridge == bridge_id do tool_stream_unavailable_locked(s, r, "bridge_offline")
}
// A new authenticated Bridge connection requests exactly the current subscriptions.
tool_stream_bridge_ready :: proc(svc: ^Agent_Service, bridge_id: string, generation: int) {
    s := &svc.tool_live
    sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
    for _, r in s.routes {
        inst, found, _ := tool_live_instance(svc, r.id)
        if !found {
            tool_stream_control_locked(s, r, false)
            tool_stream_unavailable_locked(s, r, "instance_changed")
            continue
        }
        if inst.bridge_id == bridge_id && string(inst.owner_user_id) == r.owner {
            current := project_service.bridge_runtime_registry_generation(svc.bridge_runtime_registry, inst.bridge_id)
            if svc.bridge_runtime_registry != nil && current != generation do continue
            // Reconnect/reset replaces the producer even when the connection
            // generation is unchanged (Bridge reducer reset).
            tool_stream_rebind_locked(svc, r, inst, generation)
        } else {
            // The former source reconnecting may discover a move, but only the
            // destination's registry entry supplies the replacement fence.
            _ = tool_stream_reconcile_locked(svc, r, inst)
        }
    }
}
tool_live_destroy :: proc(s: ^Tool_Live_Store) {
    // Request readers must be drained before service destruction.
    sync.mutex_lock(&s.mutex)
    s.stopped = true; sync.cond_signal(&s.control_cond)
    sync.mutex_unlock(&s.mutex)
    if s.control_worker != nil { thread.join(s.control_worker); thread.destroy(s.control_worker) }
    for c in s.controls do tool_stream_control_free(c)
    delete(s.controls)
    for _, r in s.routes do tool_stream_route_free(r)
    delete(s.routes); delete(s.viewers)
}
