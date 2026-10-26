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
import iface "odin_test:hub/repository/iface"
import project_service "odin_test:hub/service/project"
import ws "odin_test:lib/ws"
import live "odin_test:lib/tool_live"

TOOL_STREAM_MAX_VIEWERS :: 64
TOOL_STREAM_MAX_ROUTES :: 1024
TOOL_STREAM_QUEUE_BYTES :: 2 * 1024 * 1024
TOOL_STREAM_QUEUE_FRAMES :: 512
TOOL_STREAM_LEASE_NS :: i64(15 * time.Second)
TOOL_STREAM_RENEW_NS :: i64(5 * time.Second)
TOOL_STREAM_GLOBAL_BYTES :: 64 * 1024 * 1024
Tool_Stream_Frame :: struct { text: string, opcode: u8, instance_id: string }
Tool_Stream_Viewer :: struct {
    owner: string,
    socket: net.TCP_Socket,
    ids: map[string]bool,
    scopes: map[string]string, // member -> authorized open parent conversation
    expires_ns: i64,
    external: bool,
    authorize: proc(ctx: rawptr) -> bool,
    authorization_ctx: rawptr,
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
    last_renew_ns: i64,
    suspended: bool, // known route loss; reject in-flight state until a new attach
}
Tool_Stream_Control :: struct { bridge, id, token: string, run: int, attach: bool, renew: bool }
Tool_Live_Store :: struct {
    mutex: sync.Mutex,
    viewers: map[net.TCP_Socket]^Tool_Stream_Viewer,
    routes: map[string]^Tool_Stream_Route,
    controls: [dynamic]Tool_Stream_Control,
    control_cond: sync.Cond,
    control_worker: ^thread.Thread,
    expiry_worker: ^thread.Thread,
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
tool_stream_control_locked :: proc(s: ^Tool_Live_Store, r: ^Tool_Stream_Route, attach: bool, renew := false) {
    heap := runtime.heap_allocator()
    c := Tool_Stream_Control{strings.clone(r.bridge, heap), strings.clone(r.id, heap), strings.clone(r.token, heap), r.run, attach, renew}
    for &old in s.controls {
        if old.bridge == c.bridge && old.id == c.id {
            // A retired producer's detach must precede a replacement token's
            // controls, even if that replacement is removed before attach sends.
            if !old.attach && old.token != c.token do continue
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
    Control_Wire :: struct {type, instance_id, subscription_id: string, run_count, lease_ms, version: int, renew: bool}
    for {
        sync.mutex_lock(&s.mutex)
        for len(s.controls) == 0 && !s.stopped do sync.cond_wait(&s.control_cond, &s.mutex)
        if s.stopped { sync.mutex_unlock(&s.mutex); return }
        bridge := strings.clone(s.controls[0].bridge, context.temp_allocator)
        pending := make([dynamic]Tool_Stream_Control, context.temp_allocator)
        // Batch bounded controls for one bridge, preserving that bridge's order.
        i := 0
        for i < len(s.controls) && len(pending) < 64 {
            if s.controls[i].bridge != bridge { i += 1; continue }
            append(&pending, s.controls[i]); ordered_remove(&s.controls, i)
        }
        frames := make([dynamic]Control_Wire, context.temp_allocator)
        for c in pending {
            r := s.routes[c.id]
            watching := false
            if r != nil do for _, w in s.viewers {
                if w.owner == r.owner && w.ids[r.id] && tool_stream_view_current(svc, w, r.id) { watching = true; break }
            }
            valid := !c.attach || (r != nil && r.token == c.token && !r.suspended && watching)
            if valid do append(&frames, Control_Wire{"tool_stream_attach" if c.attach else "tool_stream_detach", c.id, c.token, c.run, 15_000, 2, c.renew})
        }
        sync.mutex_unlock(&s.mutex)
        sent := true
        if len(frames) > 0 {
            data, _ := json.marshal(struct {type: string, controls: []Control_Wire}{"tool_stream_batch", frames[:]}, allocator = context.temp_allocator)
            sent = len(data) <= 32 * 1024
            if sent do sent, _ = project_service.bridge_command_send_runtime(svc.bridge_command_sink, project_service.Runtime_Command{bridge_id = bridge, body_json = string(data)})
        }
        if !sent {
            sync.mutex_lock(&s.mutex)
            for c in pending do if c.attach {
                if r := s.routes[c.id]; r != nil && r.token == c.token do tool_stream_suspend_locked(s, r, "bridge_offline")
            }
            sync.mutex_unlock(&s.mutex)
        }
        for c in pending do tool_stream_control_free(c)
        free_all(context.temp_allocator)
    }
}
tool_stream_enqueue_locked :: proc(w: ^Tool_Stream_Viewer, text: string, opcode: u8 = 0x1, instance_id := "") -> bool {
    if w.stopped do return false
    frame_bytes := len(text) + len(instance_id)
    global_bytes := 0
    if w.service != nil do for _, other in w.service.tool_live.viewers do global_bytes += other.bytes
    if global_bytes > TOOL_STREAM_GLOBAL_BYTES - frame_bytes || len(w.queue) >= TOOL_STREAM_QUEUE_FRAMES || frame_bytes > TOOL_STREAM_QUEUE_BYTES - w.bytes {
        w.stopped = true
        sync.cond_signal(&w.cond)
        // The HTTP reader owns close. Shutdown only wakes that owner.
        _ = net.shutdown(w.socket, .Both)
        return false
    }
    append(&w.queue, Tool_Stream_Frame{strings.clone(text, runtime.heap_allocator()), opcode, strings.clone(instance_id, runtime.heap_allocator())})
    w.bytes += frame_bytes
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
        allowed := f.instance_id == "" || (w.ids[f.instance_id] && tool_stream_view_current(w.service, w, f.instance_id))
        if !allowed {
            w.bytes -= len(f.text) + len(f.instance_id)
            sync.mutex_unlock(&s.mutex)
            delete(f.text, runtime.heap_allocator()); delete(f.instance_id, runtime.heap_allocator())
            free_all(context.temp_allocator)
            continue
        }
        sync.mutex_unlock(&s.mutex)
        result := ws.write_server_opcode(w.socket, f.opcode, f.text, true)
        sync.mutex_lock(&s.mutex)
        w.bytes -= len(f.text) + len(f.instance_id)
        if result != .Ok {
            w.stopped = true
            _ = net.shutdown(w.socket, .Both)
        }
        sync.mutex_unlock(&s.mutex)
        delete(f.text, runtime.heap_allocator()); delete(f.instance_id, runtime.heap_allocator())
        free_all(context.temp_allocator)
        if result != .Ok do return
    }
}
tool_stream_open :: proc(svc: ^Agent_Service, owner: string, socket: net.TCP_Socket, authorize: proc(ctx: rawptr) -> bool = nil, authorization_ctx: rawptr = nil) -> ^Tool_Stream_Viewer {
    context.allocator = runtime.heap_allocator()
    s := &svc.tool_live
    sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
    if s.stopped || len(s.viewers) >= TOOL_STREAM_MAX_VIEWERS || owner == "" do return nil
    if s.control_worker == nil {
        s.controls = make([dynamic]Tool_Stream_Control)
        s.control_worker = thread.create_and_start_with_data(svc, tool_stream_control_run, self_cleanup = false)
        if s.control_worker == nil do return nil
    }
    if s.expiry_worker == nil do s.expiry_worker = thread.create_and_start_with_data(svc, tool_stream_expiry_run, self_cleanup = false)
    if s.viewers == nil do s.viewers = make(map[net.TCP_Socket]^Tool_Stream_Viewer)
    if s.routes == nil do s.routes = make(map[string]^Tool_Stream_Route)
    w := new(Tool_Stream_Viewer)
    w^ = {owner = strings.clone(owner), socket = socket, service = svc, external = true, authorize = authorize, authorization_ctx = authorization_ctx,
        ids = make(map[string]bool), expires_ns = time.tick_now()._nsec + TOOL_STREAM_LEASE_NS, queue = make([dynamic]Tool_Stream_Frame)}
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
            if !r.suspended do tool_stream_control_locked(s, r, false)
            if w.service != nil do _ = clear_instance_blockers(w.service, id)
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
    for f in w.queue { delete(f.text, heap); delete(f.instance_id, heap) }
    delete(w.queue); delete(w.ids); tool_stream_scopes_free(w.scopes); delete(w.owner, heap); free(w, heap)
}
tool_stream_write :: proc(svc: ^Agent_Service, socket: net.TCP_Socket, text: string, opcode: u8 = 0x1) -> bool {
    s := &svc.tool_live
    sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
    w := s.viewers[socket]
    return w != nil && tool_stream_enqueue_locked(w, text, opcode)
}
tool_stream_unavailable_locked :: proc(s: ^Tool_Live_Store, r: ^Tool_Stream_Route, reason: string) {
    data, _ := json.marshal(struct {type, instance_id, reason: string}{"unavailable", r.id, reason}, allocator = context.temp_allocator)
    for _, w in s.viewers do if w.owner == r.owner && w.ids[r.id] do _ = tool_stream_enqueue_locked(w, string(data), instance_id = r.id)
}
tool_stream_rebind_locked :: proc(svc: ^Agent_Service, r: ^Tool_Stream_Route, inst: domain.Agent_Instance, connection_generation: int) {
    s := &svc.tool_live
    // A Bridge reconnect is transport recovery, not an agent ready transition.
    // Keep the retired producer detached until repository state is active again.
    if !tool_stream_bridge_supported(svc, inst.bridge_id) {
        tool_stream_suspend_locked(s, r, "upgrade_required")
        return
    }
    if !runtime_expected_active(inst.runtime_status) {
        tool_stream_suspend_locked(s, r, "instance_changed")
        return
    }
    if !r.suspended do tool_stream_control_locked(s, r, false)
    delete(r.bridge, runtime.heap_allocator()); delete(r.token, runtime.heap_allocator())
    r.bridge = strings.clone(inst.bridge_id, runtime.heap_allocator())
    r.token = tool_stream_token_locked(s)
    r.run = inst.run_count; r.connection_generation = connection_generation
    r.generation = 0; r.revision = 0
    r.suspended = false
    tool_stream_control_locked(s, r, true)
}
// Resolve the destination generation from its own runtime connection. In
// particular, a reconnect on the former Bridge must never fence the new one.
tool_stream_reconcile_locked :: proc(svc: ^Agent_Service, r: ^Tool_Stream_Route, inst: domain.Agent_Instance) -> bool {
    s := &svc.tool_live
    if string(inst.owner_user_id) != r.owner {
        tool_stream_suspend_locked(s, r, "instance_changed")
        return false
    }
    if !runtime_expected_active(inst.runtime_status) {
        tool_stream_suspend_locked(s, r, "instance_changed")
        return true // Still authorized to listen for a future ready baseline.
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
tool_stream_subscribe :: proc(svc: ^Agent_Service, w: ^Tool_Stream_Viewer, ids: []string, scopes: map[string]string = nil) -> string {
    if len(ids) > live.TOOL_LIVE_MAX_INSTANCES do return "too_many_instances"
    s := &svc.tool_live
    sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
    if w.stopped do return "closed"
    if w.authorize != nil && !w.authorize(w.authorization_ctx) do return "unauthenticated"
    rows := make([]domain.Agent_Instance, len(ids), context.temp_allocator)
    additions := 0
    for id, i in ids {
        if !strings.has_prefix(id, "inst_") || len(id) > live.TOOL_LIVE_ID_MAX do return "invalid_instance_id"
        for earlier in ids[:i] do if earlier == id do return "duplicate_instance_id"
        inst, found, _ := tool_live_instance(svc, id)
        if !found || string(inst.owner_user_id) != w.owner do return "forbidden"
        if w.external && !tool_stream_bridge_supported(svc, inst.bridge_id) do return "upgrade_required"
        rows[i] = inst
        if s.routes[id] == nil do additions += 1
    }
    if len(s.routes) + additions > TOOL_STREAM_MAX_ROUTES do return "capacity"
    if w.external {
        if scopes == nil && len(ids) > 0 do return "upgrade_required"
        old_scopes := w.scopes
        w.scopes = scopes
        w.expires_ns = time.tick_now()._nsec + TOOL_STREAM_LEASE_NS
        tool_stream_scopes_free(old_scopes)
    }
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
        if !runtime_expected_active(inst.runtime_status) {
            tool_stream_suspend_locked(s, r, "instance_changed")
        } else {
            r.suspended = false
            tool_stream_control_locked(s, r, true)
        }
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
        if !found { tool_stream_suspend_locked(s, r, "not_found"); return }
        if tool_stream_reconcile_locked(svc, r, inst) {
            if !runtime_expected_active(inst.runtime_status) {
                tool_stream_suspend_locked(s, r, "instance_changed")
                return
            }
            r.suspended = false
            // A launch may not exist at configuration commit. Its ready event
            // earns another baseline, even when bridge/run did not change.
            tool_stream_control_locked(s, r, true)
        }
    }
}
// Invalidate a producer exactly once per outage: repeated terminal/Bridge
// facts must not overwrite its token-matched detach with a new unused token.
tool_stream_suspend_locked :: proc(s: ^Tool_Live_Store, r: ^Tool_Stream_Route, reason: string) {
    if !r.suspended {
        tool_stream_control_locked(s, r, false)
        delete(r.token, runtime.heap_allocator())
        r.token = tool_stream_token_locked(s)
        r.generation = 0; r.revision = 0
        r.suspended = true
    }
    tool_stream_unavailable_locked(s, r, reason)
}
// Terminal/removal never requests a baseline from the dead instance.
tool_stream_terminal :: proc(svc: ^Agent_Service, instance_id: string) {
    if svc == nil do return
    s := &svc.tool_live
    sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
    if r := s.routes[instance_id]; r != nil do tool_stream_suspend_locked(s, r, "instance_changed")
}
tool_live_clear_bridge :: proc(svc: ^Agent_Service, bridge_id: string) {
    if svc == nil do return
    s := &svc.tool_live
    sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
    for _, r in s.routes do if r.bridge == bridge_id do tool_stream_suspend_locked(s, r, "bridge_offline")
}
// A new authenticated Bridge connection requests exactly the current subscriptions.
tool_stream_bridge_ready :: proc(svc: ^Agent_Service, bridge_id: string, generation: int) {
    s := &svc.tool_live
    sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
    for _, r in s.routes {
        inst, found, _ := tool_live_instance(svc, r.id)
        if !found {
            tool_stream_suspend_locked(s, r, "not_found")
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
    if s.expiry_worker != nil { thread.join(s.expiry_worker); thread.destroy(s.expiry_worker) }
    for c in s.controls do tool_stream_control_free(c)
    delete(s.controls)
    for _, r in s.routes do tool_stream_route_free(r)
    delete(s.routes); delete(s.viewers)
}

// Parent conversation ownership and chain membership are checked on every renewal
// and again before payload fanout. Instance-only legacy requests never reach this.
tool_stream_authorized :: proc(svc: ^Agent_Service, owner, conversation, id: string) -> bool {
    context.allocator = context.temp_allocator
    if svc == nil || conversation == "" || len(conversation) > live.TOOL_LIVE_ID_MAX || len(id) > live.TOOL_LIVE_ID_MAX do return false
    conv, got, _ := iface.content_get_conversation(svc.content, conversation)
    if !got || string(conv.owner_user_id) != owner do return false
    inst, found, _ := tool_live_instance(svc, id)
    if !found || string(inst.owner_user_id) != owner do return false
    if conv.agent_instance_id == id do return true
    parent, parent_ok, _ := tool_live_instance(svc, conv.agent_instance_id)
    if !parent_ok || parent.chain_id == "" || parent.chain_id != inst.chain_id || string(parent.owner_user_id) != owner do return false
    chain, chain_ok, _ := iface.taskchain_get_chain(svc.taskchains, domain.Task_Chain_ID(parent.chain_id))
    if !chain_ok || string(chain.owner_user_id) != owner || chain.coordinator_agent_instance_id != parent.agent_instance_id do return false
    members, err := iface.taskchain_list_members_by_chain(svc.taskchains, chain.chain_id, chain.owner_user_id)
    if err.code != .None do return false
    for member in members do if member.agent_instance_id == id do return true
    return false
}
tool_stream_scopes_free :: proc(scopes: map[string]string) {
    for id, conversation in scopes { delete(id, runtime.heap_allocator()); delete(conversation, runtime.heap_allocator()) }
    delete(scopes)
}
tool_stream_view_current :: proc(svc: ^Agent_Service, w: ^Tool_Stream_Viewer, id: string) -> bool {
    if w.stopped || (w.expires_ns > 0 && time.tick_now()._nsec >= w.expires_ns) do return false
    if w.authorize != nil && !w.authorize(w.authorization_ctx) do return false
    // Only internal tests/direct subscribers have no external scope map.
    if w.scopes == nil do return !w.external
    inst, found, _ := tool_live_instance(svc, id)
    return found && tool_stream_bridge_supported(svc, inst.bridge_id) && tool_stream_authorized(svc, w.owner, w.scopes[id], id)
}
tool_stream_subscribe_views :: proc(svc: ^Agent_Service, w: ^Tool_Stream_Viewer, views: json.Array) -> string {
    if len(views) > live.TOOL_LIVE_MAX_INSTANCES do return "invalid_subscription"
    scopes := make(map[string]string, runtime.heap_allocator())
    defer if scopes != nil do tool_stream_scopes_free(scopes)
    ids := make([dynamic]string, context.temp_allocator)
    total := 0
    for item in views {
        view, ok := item.(json.Object)
        if !ok do return "invalid_subscription"
        conversation := tool_live_text(view, "conversation_id")
        members, array_ok := view["instance_ids"].(json.Array)
        if !array_ok do return "invalid_subscription"
        for m in members {
            total += 1
            if total > 4 * live.TOOL_LIVE_MAX_INSTANCES do return "invalid_subscription"
            id, string_ok := m.(json.String)
            if !string_ok || !tool_stream_authorized(svc, w.owner, conversation, string(id)) do return "forbidden"
            if _, exists := scopes[string(id)]; !exists {
                if len(scopes) >= live.TOOL_LIVE_MAX_INSTANCES do return "invalid_subscription"
                key := strings.clone(string(id), runtime.heap_allocator())
                scopes[key] = strings.clone(conversation, runtime.heap_allocator())
                append(&ids, key)
            }
        }
    }
    // Production's HTTP reader serializes replacements for this viewer.
    code := tool_stream_subscribe(svc, w, ids[:], scopes)
    if code != "" do return code
    if w.external do scopes = nil // ownership transferred under the subscription lock
    return ""
}
tool_stream_expire_at :: proc(svc: ^Agent_Service, now: i64) {
    s := &svc.tool_live
    sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
    for _, w in s.viewers {
        if w.stopped || (w.expires_ns > 0 && now >= w.expires_ns) || (w.authorize != nil && !w.authorize(w.authorization_ctx)) {
            for len(w.ids) > 0 { for id in w.ids { tool_stream_remove_id_locked(s, w, id); break } }
            w.stopped = true; sync.cond_signal(&w.cond)
            _ = net.shutdown(w.socket, .Both)
        }
    }
    for _, r in s.routes {
        if r.viewers > 0 && !r.suspended && now - r.last_renew_ns >= TOOL_STREAM_RENEW_NS {
            r.last_renew_ns = now
            tool_stream_control_locked(s, r, true, true)
        }
    }
}
tool_stream_expiry_run :: proc(raw: rawptr) {
    context = runtime.default_context()
    svc := (^Agent_Service)(raw)
    for {
        time.sleep(time.Second)
        sync.mutex_lock(&svc.tool_live.mutex)
        stopped := svc.tool_live.stopped
        sync.mutex_unlock(&svc.tool_live.mutex)
        if stopped do return
        tool_stream_expire_at(svc, time.tick_now()._nsec)
        free_all(context.temp_allocator)
    }
}

TOOL_STREAM_DEMAND_FEATURE :: "tool_stream_demand_v2"

// tool_stream_feature_supported is the one predicate for expiring-demand support:
// live admission below and the bridge list's `tool_stream_supported` both use it.
tool_stream_feature_supported :: proc(bridge: domain.Bridge) -> bool {
    return bridge_feature_supported(bridge, TOOL_STREAM_DEMAND_FEATURE)
}

// Old bridges do not implement expiring demand controls. Fail closed rather than
// silently enabling a legacy producer. Nil repositories occur only in unit fakes.
tool_stream_bridge_supported :: proc(svc: ^Agent_Service, bridge_id: string) -> bool {
    if svc.bridges == nil do return true
    context.allocator = context.temp_allocator // the row is read-only here, like tool_live_instance
    bridge, found, err := iface.bridge_get_bridge(svc.bridges, bridge_id)
    if !found || err.code != .None do return false
    return tool_stream_feature_supported(bridge)
}
