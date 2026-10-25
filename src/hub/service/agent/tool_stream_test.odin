package agent

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import project_service "odin_test:hub/service/project"

@(private = "file")
Tool_Stream_Test :: struct { svc: Agent_Service, repo: iface.Agent_Repository, a, b: Tool_Stream_Viewer, run: int, bridge, status: string, registry: project_service.Bridge_Runtime_Registry }
@(private = "file")
tool_stream_test_init :: proc(f: ^Tool_Stream_Test) {
    heap := runtime.heap_allocator()
    f.run = 1; f.bridge = "brg_a"; f.status = "running"
    f.repo = {ctx = f, get_tool_instance = proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
        f := (^Tool_Stream_Test)(ctx)
        return domain.Agent_Instance{agent_instance_id = id, bridge_id = f.bridge, owner_user_id = "owner" if id == "inst_a" else "foreign",
            run_count = f.run, runtime_status = f.status}, true, {}
    }}
    f.svc.agents = &f.repo
    s := &f.svc.tool_live
    s.routes = make(map[string]^Tool_Stream_Route, heap)
    s.viewers = make(map[net.TCP_Socket]^Tool_Stream_Viewer, heap)
    s.controls = make([dynamic]Tool_Stream_Control, heap)
    f.a = {owner = "owner", socket = net.TCP_Socket(-1), ids = make(map[string]bool, heap), queue = make([dynamic]Tool_Stream_Frame, heap)}
    f.b = {owner = "owner", socket = net.TCP_Socket(-2), ids = make(map[string]bool, heap), queue = make([dynamic]Tool_Stream_Frame, heap)}
    s.viewers[f.a.socket] = &f.a; s.viewers[f.b.socket] = &f.b
}
@(private = "file")
tool_stream_test_clear :: proc(w: ^Tool_Stream_Viewer) {
    for f in w.queue { delete(f.text, runtime.heap_allocator()); delete(f.instance_id, runtime.heap_allocator()) }
    clear(&w.queue); w.bytes = 0
}
@(private = "file")
tool_stream_test_free :: proc(f: ^Tool_Stream_Test) {
    for w in ([2]^Tool_Stream_Viewer{&f.a,&f.b}) {
        tool_stream_test_clear(w)
        for key in w.ids do delete(key, runtime.heap_allocator())
        delete(w.ids); delete(w.queue)
    }
    tool_live_destroy(&f.svc.tool_live)
    project_service.bridge_runtime_registry_destroy(&f.registry)
}
@(private = "file")
tool_stream_test_frame :: proc(token: string, run := 1, revision := 1) -> string {
    return fmt.tprintf(`{{"type":"tool_stream_state","epoch":"1000","subscription_id":"%s","baseline":false,"run_count":%d,"snapshot":{{"instance_id":"inst_a","epoch":"1000","generation":1,"revision":%d,"run_count":%d,"active":[],"completed_since_last":[{{"call_id":"x","source":"provider","tool_name":"Bash","summary":"echo hi","summary_truncated":false,"duration_ms":3,"completed_at_ms":1001,"status":"completed"}}]}}}`, token, run, revision, run)
}
@(test)
test_tool_stream_shared_subscription_and_atomic_replace :: proc(t: ^testing.T) {
    f: Tool_Stream_Test; tool_stream_test_init(&f); defer tool_stream_test_free(&f)
    ids := [1]string{"inst_a"}
    testing.expect_value(t, tool_stream_subscribe(&f.svc,&f.a,ids[:]), "")
    r := f.svc.tool_live.routes["inst_a"]
    testing.expect_value(t,r.viewers,1)
    testing.expect_value(t,len(f.svc.tool_live.controls),1)
    testing.expect(t,f.svc.tool_live.controls[0].attach)
    testing.expect_value(t,tool_stream_subscribe(&f.svc,&f.b,ids[:]),"")
    testing.expect(t,r == f.svc.tool_live.routes["inst_a"],"added viewers share one route and producer")
    testing.expect_value(t,r.viewers,2)
    testing.expect_value(t,tool_stream_subscribe(&f.svc,&f.a,ids[:]),"")
    testing.expect_value(t,r.viewers,2)
    bad := [1]string{"inst_foreign"}
    testing.expect_value(t,tool_stream_subscribe(&f.svc,&f.a,bad[:]),"forbidden")
    testing.expect(t,f.a.ids["inst_a"],"rejected replacement preserves previous set")
    testing.expect_value(t,tool_stream_subscribe(&f.svc,&f.a,nil),"")
    testing.expect_value(t,r.viewers,1)
    testing.expect(t,f.svc.tool_live.controls[0].attach,"remaining viewer keeps upstream attached")
    testing.expect_value(t,tool_stream_subscribe(&f.svc,&f.b,nil),"")
    testing.expect_value(t,len(f.svc.tool_live.routes),0)
    testing.expect(t,!f.svc.tool_live.controls[0].attach,"last viewer detaches upstream")
}
@(test)
test_tool_stream_fanout_auth_fences_and_slow_viewer :: proc(t: ^testing.T) {
    f: Tool_Stream_Test; tool_stream_test_init(&f); defer tool_stream_test_free(&f)
    ids := [1]string{"inst_a"}
    _=tool_stream_subscribe(&f.svc,&f.a,ids[:]); _=tool_stream_subscribe(&f.svc,&f.b,ids[:])
    tool_stream_test_clear(&f.a); tool_stream_test_clear(&f.b)
    r:=f.svc.tool_live.routes["inst_a"]
    frame:=tool_stream_test_frame(r.token)
    testing.expect(t,!tool_live_apply_bridge(&f.svc,"wrong_bridge",0,"1000",frame))
    testing.expect(t,!tool_live_apply_bridge(&f.svc,"brg_a",0,"2000",frame))
    testing.expect(t,!tool_live_apply_bridge(&f.svc,"brg_a",9,"1000",frame))
    testing.expect(t,!tool_live_apply_bridge(&f.svc,"brg_a",0,"1000",tool_stream_test_frame("spoof")))
    testing.expect(t,tool_live_apply_bridge(&f.svc,"brg_a",0,"1000",frame))
    testing.expect_value(t,len(f.a.queue),1); testing.expect_value(t,len(f.b.queue),1)
    testing.expect_value(t,f.a.queue[0].text,f.b.queue[0].text)
    testing.expect(t,strings.contains(f.a.queue[0].text,`"completed_since_last":[`))
    tool_stream_test_clear(&f.a); tool_stream_test_clear(&f.b)
    f.a.bytes = TOOL_STREAM_QUEUE_BYTES
    testing.expect(t,tool_live_apply_bridge(&f.svc,"brg_a",0,"1000",tool_stream_test_frame(r.token,revision=2)))
    testing.expect(t,f.a.stopped,"overflow stops only the slow viewer")
    testing.expect_value(t,len(f.b.queue),1)
    testing.expect(t,!tool_live_apply_bridge(&f.svc,"brg_a",0,"1000",frame),"older revision is discarded")
    // Reconnect changes route token and connection fence; old responses cannot apply.
    old_token := strings.clone(r.token); defer delete(old_token)
    tool_stream_bridge_ready(&f.svc,"brg_a",5)
    testing.expect(t,r.token != old_token)
    testing.expect(t,!tool_live_apply_bridge(&f.svc,"brg_a",0,"1000",tool_stream_test_frame(old_token,revision=3)))
    testing.expect(t,tool_live_apply_bridge(&f.svc,"brg_a",5,"1000",tool_stream_test_frame(r.token,revision=1)))
    f.run=2
    testing.expect(t,!tool_live_apply_bridge(&f.svc,"brg_a",5,"1000",tool_stream_test_frame(r.token,run=2,revision=4)))
    testing.expect_value(t,r.run,2)
}
@(test)
test_tool_stream_rejects_raw_payloads_and_oversized_summaries :: proc(t: ^testing.T) {
    raw:=`{"instance_id":"inst_a","generation":1,"revision":1,"active":[{"call_id":"x","input":{"secret":"raw"}}],"completed_since_last":[]}`
    v,_:=json.parse_string(raw,.JSON,true,context.temp_allocator)
    testing.expect(t,!tool_live_valid_snapshot(v.(json.Object)))
    summary:=strings.repeat("x",513,context.temp_allocator)
    raw=fmt.tprintf(`{{"instance_id":"inst_a","generation":1,"revision":1,"active":[{{"call_id":"x","summary":"%s"}}],"completed_since_last":[]}}`,summary)
    v,_=json.parse_string(raw,.JSON,true,context.temp_allocator)
    testing.expect(t,!tool_live_valid_snapshot(v.(json.Object)))
}

// Use two real runtime registry entries so destination and source connection
// generations differ; a borrowed source generation must fail these assertions.
@(private = "file")
tool_stream_test_bridges :: proc(f: ^Tool_Stream_Test, t: ^testing.T) -> (int, int) {
    f.svc.bridge_runtime_registry = &f.registry
    _, a, a_ok := project_service.bridge_runtime_registry_accept_live(&f.registry, "brg_a", false, "", "owner")
    _, b, b_ok := project_service.bridge_runtime_registry_accept_live(&f.registry, "brg_b", false, "", "owner")
    testing.expect(t, a_ok && b_ok && a != b)
    return a, b
}
@(private = "file")
tool_stream_test_baseline :: proc(token: string, revision := 1) -> string {
    return fmt.tprintf(`{{"type":"tool_stream_state","epoch":"1000","subscription_id":"%s","baseline":true,"run_count":1,"snapshot":{{"instance_id":"inst_a","epoch":"1000","generation":1,"revision":%d,"run_count":1,"active":[],"completed_since_last":[]}}}`, token, revision)
}
@(test)
test_tool_stream_relocation_follows_committed_configuration :: proc(t: ^testing.T) {
    f: Tool_Stream_Test; tool_stream_test_init(&f); defer tool_stream_test_free(&f)
    a_generation, b_generation := tool_stream_test_bridges(&f, t)
    ids := [1]string{"inst_a"}
    _ = tool_stream_subscribe(&f.svc, &f.a, ids[:])
    r := f.svc.tool_live.routes["inst_a"]
    old_token := strings.clone(r.token); defer delete(old_token)
    testing.expect(t, tool_live_apply_bridge(&f.svc, "brg_a", a_generation, "1000", tool_stream_test_frame(old_token)))
    tool_stream_test_clear(&f.a)
    // This is the notification called after the successful reconfiguration CAS.
    // It must work even without the optional UI resource-event callback.
    f.bridge = "brg_b"
    reconfiguration_notify(&f.svc, domain.Instance_Reconfiguration{agent_instance_id = "inst_a"}, "progress", true)
    testing.expect_value(t, r.bridge, "brg_b")
    testing.expect_value(t, r.connection_generation, b_generation)
    testing.expect(t, old_token != r.token)
    testing.expect_value(t, len(f.svc.tool_live.controls), 2)
    testing.expect(t, !f.svc.tool_live.controls[0].attach && f.svc.tool_live.controls[0].bridge == "brg_a")
    testing.expect_value(t, f.svc.tool_live.controls[0].token, old_token)
    testing.expect(t, f.svc.tool_live.controls[1].attach && f.svc.tool_live.controls[1].bridge == "brg_b")
    testing.expect_value(t, f.svc.tool_live.controls[1].token, r.token)
    tool_stream_test_clear(&f.a)
    testing.expect(t, !tool_live_apply_bridge(&f.svc, "brg_a", a_generation, "1000", tool_stream_test_frame(old_token, revision = 9)))
    testing.expect(t, !tool_live_apply_bridge(&f.svc, "brg_b", a_generation, "1000", tool_stream_test_baseline(r.token)))
    testing.expect(t, tool_live_apply_bridge(&f.svc, "brg_b", b_generation, "1000", tool_stream_test_baseline(r.token)))
    testing.expect_value(t, len(f.a.queue), 1)
    testing.expect(t, strings.contains(f.a.queue[0].text, `"baseline":true`))
    testing.expect(t, strings.contains(f.a.queue[0].text, `"active":[]`))
    testing.expect(t, tool_live_apply_bridge(&f.svc, "brg_b", b_generation, "1000", tool_stream_test_frame(r.token, revision = 2)))
    testing.expect_value(t, len(f.a.queue), 2)
    // Added viewers reuse the destination producer and get its empty baseline.
    _ = tool_stream_subscribe(&f.svc, &f.b, ids[:])
    tool_stream_test_clear(&f.a); tool_stream_test_clear(&f.b)
    testing.expect_value(t, r.viewers, 2)
    testing.expect(t, tool_live_apply_bridge(&f.svc, "brg_b", b_generation, "1000", tool_stream_test_baseline(r.token, revision = 2)))
    testing.expect_value(t, len(f.a.queue), 1); testing.expect_value(t, len(f.b.queue), 1)
    // Last detach, then a new first viewer, still targets B.
    _ = tool_stream_subscribe(&f.svc, &f.a, nil); _ = tool_stream_subscribe(&f.svc, &f.b, nil)
    _ = tool_stream_subscribe(&f.svc, &f.a, ids[:])
    r = f.svc.tool_live.routes["inst_a"]
    testing.expect_value(t, r.bridge, "brg_b")
    testing.expect_value(t, r.connection_generation, b_generation)
}
@(test)
test_tool_stream_relocation_subscription_reconciliation :: proc(t: ^testing.T) {
    // Exercise same-set replacement and additional-viewer attach independently
    // of lifecycle notification, as a defensive reconciliation boundary.
    for additional in ([2]bool{false, true}) {
        f: Tool_Stream_Test; tool_stream_test_init(&f)
        _, b_generation := tool_stream_test_bridges(&f, t)
        ids := [1]string{"inst_a"}
        _ = tool_stream_subscribe(&f.svc, &f.a, ids[:])
        r := f.svc.tool_live.routes["inst_a"]
        f.bridge = "brg_b"
        w := &f.b if additional else &f.a
        testing.expect_value(t, tool_stream_subscribe(&f.svc, w, ids[:]), "")
        testing.expect_value(t, r.bridge, "brg_b")
        testing.expect_value(t, r.connection_generation, b_generation)
        testing.expect_value(t, r.viewers, 2 if additional else 1)
        tool_stream_test_clear(&f.a); tool_stream_test_clear(&f.b)
        testing.expect(t, tool_live_apply_bridge(&f.svc, "brg_b", b_generation, "1000", tool_stream_test_baseline(r.token)))
        testing.expect_value(t, len(f.a.queue), 1)
        testing.expect_value(t, len(f.b.queue), 1 if additional else 0)
        tool_stream_test_free(&f)
    }
}
@(test)
test_tool_stream_relocation_reconnect_and_ready_baseline :: proc(t: ^testing.T) {
    f: Tool_Stream_Test; tool_stream_test_init(&f); defer tool_stream_test_free(&f)
    _, b_generation := tool_stream_test_bridges(&f, t)
    ids := [1]string{"inst_a"}
    _ = tool_stream_subscribe(&f.svc, &f.a, ids[:])
    r := f.svc.tool_live.routes["inst_a"]
    f.bridge = "brg_b"
    // Reconnecting former A also discovers relocation but must use B's epoch.
    _, a_reconnected, a_ok := project_service.bridge_runtime_registry_accept_live(&f.registry, "brg_a", false, "", "owner")
    testing.expect(t, a_ok)
    tool_stream_bridge_ready(&f.svc, "brg_a", a_reconnected)
    testing.expect_value(t, r.bridge, "brg_b")
    testing.expect_value(t, r.connection_generation, b_generation)
    token := strings.clone(r.token); defer delete(token)
    tool_stream_bridge_ready(&f.svc, "brg_a", a_reconnected)
    testing.expect_value(t, r.token, token)
    _, b_reconnected, b_ok := project_service.bridge_runtime_registry_accept_live(&f.registry, "brg_b", false, "", "owner")
    testing.expect(t, b_ok)
    tool_stream_bridge_ready(&f.svc, "brg_b", b_reconnected)
    testing.expect_value(t, r.connection_generation, b_reconnected)
    testing.expect(t, r.token != token)
    tool_stream_test_clear(&f.a)
    testing.expect(t, !tool_live_apply_bridge(&f.svc, "brg_b", b_generation, "1000", tool_stream_test_baseline(token)))
    testing.expect(t, tool_live_apply_bridge(&f.svc, "brg_b", b_reconnected, "1000", tool_stream_test_baseline(r.token)))
    // A delayed old ready callback cannot restore an obsolete connection fence.
    token_after := strings.clone(r.token); defer delete(token_after)
    tool_stream_bridge_ready(&f.svc, "brg_b", b_generation)
    testing.expect_value(t, r.token, token_after)
    testing.expect_value(t, r.connection_generation, b_reconnected)
    // Simulate attach before launch: drain controls, then Ready must request a
    // fresh baseline without needing a new viewer, reconnect, or tool event.
    for c in f.svc.tool_live.controls do tool_stream_control_free(c)
    clear(&f.svc.tool_live.controls)
    reconfiguration_notify(&f.svc, domain.Instance_Reconfiguration{agent_instance_id = "inst_a"}, "succeeded", false)
    testing.expect_value(t, len(f.svc.tool_live.controls), 1)
    testing.expect(t, f.svc.tool_live.controls[0].attach)
    testing.expect_value(t, f.svc.tool_live.controls[0].bridge, "brg_b")
}

@(test)
test_tool_stream_refresh_equal_revision_and_old_state_fence :: proc(t: ^testing.T) {
    f: Tool_Stream_Test; tool_stream_test_init(&f); defer tool_stream_test_free(&f)
    ids := [1]string{"inst_a"}
    _=tool_stream_subscribe(&f.svc,&f.a,ids[:])
    r:=f.svc.tool_live.routes["inst_a"]
    testing.expect(t,tool_live_apply_bridge(&f.svc,"brg_a",0,"1000",tool_stream_test_baseline(r.token,revision=4)))
    tool_stream_test_clear(&f.a)
    refresh,_:=strings.replace_all(tool_stream_test_baseline(r.token,revision=4),`"baseline":true`,`"baseline":false,"refresh":true`)
    defer delete(refresh)
    testing.expect(t,tool_live_apply_bridge(&f.svc,"brg_a",0,"1000",refresh),"equal revision refresh accepted")
    testing.expect_value(t,len(f.a.queue),1)
    if len(f.a.queue)>0 {
        value,_:=json.parse_string(f.a.queue[0].text,.JSON,true,context.temp_allocator)
        testing.expect(t,bool(value.(json.Object)["refresh"].(json.Boolean)),"refresh marker reaches browser")
    }
    testing.expect(t,!tool_live_apply_bridge(&f.svc,"brg_a",0,"1000",tool_stream_test_baseline(r.token,revision=3)),"older state still rejected")
}

@(test)
test_tool_stream_terminal_unavailable_fences_late_producer :: proc(t: ^testing.T) {
    f: Tool_Stream_Test; tool_stream_test_init(&f); defer tool_stream_test_free(&f)
    ids := [1]string{"inst_a"}
    _=tool_stream_subscribe(&f.svc,&f.a,ids[:])
    _=tool_stream_subscribe(&f.svc,&f.b,ids[:])
    r:=f.svc.tool_live.routes["inst_a"]
    late:=strings.clone(tool_stream_test_frame(r.token,revision=9)); defer delete(late)
    tool_stream_test_clear(&f.a); tool_stream_test_clear(&f.b)
    f.status = "stopped"
    notify_instance_terminal(&f.svc,"inst_a")
    detached_token:=strings.clone(f.svc.tool_live.controls[len(f.svc.tool_live.controls)-1].token)
    defer delete(detached_token)
    notify_instance_terminal(&f.svc,"inst_a")
    testing.expect(t,f.svc.tool_live.controls[len(f.svc.tool_live.controls)-1].token == detached_token,"repeated terminal fact preserves original detach token")
    for w in ([2]^Tool_Stream_Viewer{&f.a,&f.b}) {
        testing.expect_value(t,len(w.queue),2)
        if len(w.queue)>0 {
            testing.expect(t,strings.contains(w.queue[0].text,`"type":"unavailable"`))
            testing.expect(t,strings.contains(w.queue[0].text,`"instance_id":"inst_a"`))
        }
    }
    testing.expect(t,!f.svc.tool_live.controls[len(f.svc.tool_live.controls)-1].attach,"terminal detaches without reattaching")
    testing.expect(t,!tool_live_apply_bridge(&f.svc,"brg_a",0,"1000",late),"late producer cannot restore terminal state")
    tool_stream_test_clear(&f.a); tool_stream_test_clear(&f.b)
    notify_instance_terminal(&f.svc,"inst_unrelated")
    testing.expect_value(t,len(f.a.queue),0)
    testing.expect_value(t,len(f.b.queue),0)
    f.status = "running"
    tool_live_clear(&f.svc,"inst_a")
    testing.expect(t,f.svc.tool_live.controls[len(f.svc.tool_live.controls)-1].attach,"existing ready path requests new baseline")
    testing.expect(t,tool_live_apply_bridge(&f.svc,"brg_a",0,"1000",tool_stream_test_baseline(r.token)))
}

@(test)
test_tool_stream_terminal_stays_suspended_across_transport_recovery :: proc(t: ^testing.T) {
    for status in ([3]string{"stopped", "failed", "unreachable"}) {
        // Both reconnect and changed-generation same-set subscribe previously
        // reattached a terminal producer before an agent ready transition.
        for reconnect in ([2]bool{true, false}) {
            f: Tool_Stream_Test; tool_stream_test_init(&f)
            a_generation, _ := tool_stream_test_bridges(&f, t)
            ids := [1]string{"inst_a"}
            _ = tool_stream_subscribe(&f.svc, &f.a, ids[:])
            r := f.svc.tool_live.routes["inst_a"]
            old_token := strings.clone(r.token)
            testing.expect(t, tool_live_apply_bridge(&f.svc, "brg_a", a_generation, "1000", tool_stream_test_baseline(old_token)))
            f.status = status
            notify_instance_terminal(&f.svc, "inst_a")
            suspended_token := strings.clone(r.token)
            tool_stream_test_clear(&f.a)
            _, generation, accepted := project_service.bridge_runtime_registry_accept_live(&f.registry, "brg_a", false, "", "owner")
            testing.expect(t, accepted && generation != a_generation)
            if reconnect {
                tool_stream_bridge_ready(&f.svc, "brg_a", generation)
            } else {
                testing.expect_value(t, tool_stream_subscribe(&f.svc, &f.a, ids[:]), "")
            }
            testing.expect(t, r.suspended)
            testing.expect_value(t, r.token, suspended_token)
            testing.expect_value(t, r.connection_generation, a_generation)
            testing.expect_value(t, r.viewers, 1)
            testing.expect_value(t, len(f.svc.tool_live.controls), 1)
            testing.expect(t, !f.svc.tool_live.controls[0].attach)
            testing.expect_value(t, f.svc.tool_live.controls[0].token, old_token)
            testing.expect_value(t, len(f.a.queue), 1 if reconnect else 2)
            if !reconnect && len(f.a.queue) > 0 do testing.expect(t, strings.contains(f.a.queue[0].text, `"type":"subscribed"`))
            if len(f.a.queue) > 0 do testing.expect(t, strings.contains(f.a.queue[len(f.a.queue)-1].text, `"type":"unavailable"`))
            tool_stream_test_clear(&f.a)
            testing.expect(t, !tool_live_apply_bridge(&f.svc, "brg_a", generation, "1000", tool_stream_test_baseline(r.token)))
            testing.expect(t, !tool_live_apply_bridge(&f.svc, "brg_a", a_generation, "1000", tool_stream_test_baseline(old_token)))
            testing.expect_value(t, len(f.a.queue), 0)
            // A genuine active/ready transition may now bind the current route.
            f.status = "running"
            tool_live_clear(&f.svc, "inst_a")
            testing.expect(t, !r.suspended)
            testing.expect_value(t, r.connection_generation, generation)
            testing.expect_value(t, len(f.svc.tool_live.controls), 2)
            testing.expect(t, !f.svc.tool_live.controls[0].attach && f.svc.tool_live.controls[1].attach)
            testing.expect_value(t, f.svc.tool_live.controls[0].token, old_token)
            testing.expect_value(t, f.svc.tool_live.controls[1].token, r.token)
            tool_stream_test_clear(&f.a)
            testing.expect(t, tool_live_apply_bridge(&f.svc, "brg_a", generation, "1000", tool_stream_test_baseline(r.token)))
            testing.expect_value(t, len(f.a.queue), 1)
            if len(f.a.queue) > 0 do testing.expect(t, strings.contains(f.a.queue[0].text, `"availability":"ready"`))
            delete(old_token); delete(suspended_token)
            tool_stream_test_free(&f)
        }
    }
}

@(test)
test_tool_stream_bridge_loss_notifies_affected_listeners :: proc(t: ^testing.T) {
    f: Tool_Stream_Test; tool_stream_test_init(&f); defer tool_stream_test_free(&f)
    ids := [1]string{"inst_a"}
    _=tool_stream_subscribe(&f.svc,&f.a,ids[:])
    tool_stream_test_clear(&f.a)
    tool_live_clear_bridge(&f.svc,"brg_unrelated")
    testing.expect_value(t,len(f.a.queue),0)
    tool_live_clear_bridge(&f.svc,"brg_a")
    testing.expect_value(t,len(f.a.queue),1)
    testing.expect_value(t,len(f.b.queue),0)
    if len(f.a.queue)>0 do testing.expect(t,strings.contains(f.a.queue[0].text,`"reason":"bridge_offline"`))
}

@(test)
test_tool_stream_instance_removal_notifies_subscribers :: proc(t: ^testing.T) {
    f: Tool_Stream_Test; tool_stream_test_init(&f); defer tool_stream_test_free(&f)
    f.repo.get_instance = proc(ctx: rawptr,id:string)->(domain.Agent_Instance,bool,domain.Domain_Error) {
        return domain.Agent_Instance{agent_instance_id=id,owner_user_id="owner",bridge_id="brg_a",kind="provider_test"},true,{}
    }
    f.repo.delete_instance = proc(ctx:rawptr,id:string)->(bool,domain.Domain_Error) {return true,{}}
    ids := [1]string{"inst_a"}
    _=tool_stream_subscribe(&f.svc,&f.a,ids[:])
    tool_stream_test_clear(&f.a)
    err:=cleanup_provider_test_instance(&f.svc,contracts.Auth_Context{kind=.Session,user_id="owner"},"inst_a")
    testing.expect(t,err.code == .None)
    testing.expect_value(t,len(f.a.queue),1)
    if len(f.a.queue)>0 do testing.expect(t,strings.contains(f.a.queue[0].text,`"type":"unavailable"`))
}

@(test)
test_tool_stream_suspended_last_detach_preserves_old_producer_control :: proc(t: ^testing.T) {
    f: Tool_Stream_Test; tool_stream_test_init(&f); defer tool_stream_test_free(&f)
    ids := [1]string{"inst_a"}
    _=tool_stream_subscribe(&f.svc,&f.a,ids[:])
    old_token:=strings.clone(f.svc.tool_live.routes["inst_a"].token); defer delete(old_token)
    tool_stream_terminal(&f.svc,"inst_a")
    _=tool_stream_subscribe(&f.svc,&f.a,nil)
    testing.expect_value(t,len(f.svc.tool_live.controls),1)
    testing.expect(t,!f.svc.tool_live.controls[0].attach)
    testing.expect_value(t,f.svc.tool_live.controls[0].token,old_token)
    // A subsequent logical producer must not coalesce away the retired detach.
    _=tool_stream_subscribe(&f.svc,&f.a,ids[:])
    testing.expect_value(t,len(f.svc.tool_live.controls),2)
    _=tool_stream_subscribe(&f.svc,&f.a,nil)
    testing.expect_value(t,len(f.svc.tool_live.controls),2)
    testing.expect(t,!f.svc.tool_live.controls[0].attach && !f.svc.tool_live.controls[1].attach)
    testing.expect_value(t,f.svc.tool_live.controls[0].token,old_token)
}

@(test)
test_tool_stream_expired_viewer_drops_late_frames_without_eof :: proc(t: ^testing.T) {
    f: Tool_Stream_Test; tool_stream_test_init(&f); defer tool_stream_test_free(&f)
    ids := [1]string{"inst_a"}
    _ = tool_stream_subscribe(&f.svc, &f.a, ids[:])
    _ = tool_stream_subscribe(&f.svc, &f.b, ids[:])
    token := strings.clone(f.svc.tool_live.routes["inst_a"].token, context.temp_allocator)
    f.a.expires_ns = 1
    f.b.expires_ns = time.tick_now()._nsec + TOOL_STREAM_LEASE_NS
    tool_stream_expire_at(&f.svc, time.tick_now()._nsec)
    testing.expect(t, f.a.stopped)
    testing.expect_value(t, f.svc.tool_live.routes["inst_a"].viewers, 1)
    tool_stream_test_clear(&f.b)
    testing.expect(t, tool_live_apply_bridge(&f.svc, "brg_a", 0, "1000", tool_stream_test_frame(token)))
    testing.expect_value(t, len(f.b.queue), 1)
    f.b.expires_ns = 1
    tool_stream_expire_at(&f.svc, time.tick_now()._nsec)
    testing.expect_value(t, len(f.svc.tool_live.routes), 0)
    testing.expect(t, !tool_live_apply_bridge(&f.svc, "brg_a", 0, "1000", tool_stream_test_frame(token, revision = 2)))
}

@(test)
test_tool_stream_scoped_replacement_requires_authorized_parent :: proc(t: ^testing.T) {
    f: Tool_Stream_Test; tool_stream_test_init(&f); defer tool_stream_test_free(&f)
    content := iface.Content_Repository{get_conversation = proc(ctx: rawptr, id: string) -> (domain.Chat_Conversation, bool, domain.Domain_Error) {
        return domain.Chat_Conversation{conversation_id = id, owner_user_id = "owner", agent_instance_id = "inst_a"}, id == "chat_a", {}
    }}
    f.svc.content = &content
    f.a.external = true
    testing.expect_value(t, tool_stream_subscribe(&f.svc, &f.a, []string{"inst_a"}), "upgrade_required")
    value, _ := json.parse_string(`[{"conversation_id":"chat_a","instance_ids":["inst_a"]}]`, .JSON, true, context.temp_allocator)
    testing.expect_value(t, tool_stream_subscribe_views(&f.svc, &f.a, value.(json.Array)), "")
    testing.expect(t, f.a.scopes["inst_a"] == "chat_a")
    bad, _ := json.parse_string(`[{"conversation_id":"chat_foreign","instance_ids":["inst_a"]}]`, .JSON, true, context.temp_allocator)
    testing.expect_value(t, tool_stream_subscribe_views(&f.svc, &f.a, bad.(json.Array)), "forbidden")
    testing.expect(t, f.a.ids["inst_a"], "invalid replacement preserves authorized demand")
    foreign_view, _ := json.parse_string(`[{"conversation_id":"chat_a","instance_ids":["inst_foreign"]}]`, .JSON, true, context.temp_allocator)
    testing.expect_value(t, tool_stream_subscribe_views(&f.svc, &f.a, foreign_view.(json.Array)), "forbidden")
    empty, _ := json.parse_string("[]", .JSON, true, context.temp_allocator)
    testing.expect_value(t, tool_stream_subscribe_views(&f.svc, &f.a, empty.(json.Array)), "")
    testing.expect_value(t, len(f.svc.tool_live.routes), 0)
    tool_stream_scopes_free(f.a.scopes); f.a.scopes = nil
}

@(test)
test_tool_stream_open_chain_explicitly_authorizes_each_current_member :: proc(t: ^testing.T) {
    f: Tool_Stream_Test; tool_stream_test_init(&f); defer tool_stream_test_free(&f)
    f.repo.get_tool_instance = proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
        return domain.Agent_Instance{agent_instance_id = id, owner_user_id = "owner", bridge_id = "brg_a",
            chain_id = "chain_a", run_count = 1, runtime_status = "running"}, true, {}
    }
    content := iface.Content_Repository{get_conversation = proc(ctx: rawptr, id: string) -> (domain.Chat_Conversation, bool, domain.Domain_Error) {
        return domain.Chat_Conversation{conversation_id = id, owner_user_id = "owner", agent_instance_id = "inst_parent"}, id == "chat_chain", {}
    }}
    chains := iface.Taskchain_Repository{ctx = &f,
        get_chain = proc(ctx: rawptr, id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
            return domain.Task_Chain{chain_id = id, owner_user_id = "owner", coordinator_agent_instance_id = "inst_parent"}, true, {}
        },
        list_members_by_chain = proc(ctx: rawptr, id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task_Chain_Member, domain.Domain_Error) {
            f := (^Tool_Stream_Test)(ctx)
            if f.run != 1 do return nil, {}
            members := make([]domain.Task_Chain_Member, 2, context.temp_allocator)
            members[0].agent_instance_id = "inst_a"; members[1].agent_instance_id = "inst_b"
            return members, {}
        },
    }
    f.svc.content = &content; f.svc.taskchains = &chains
    f.a.external = true
    value, _ := json.parse_string(`[{"conversation_id":"chat_chain","instance_ids":["inst_parent","inst_a","inst_b"]}]`, .JSON, true, context.temp_allocator)
    testing.expect_value(t, tool_stream_subscribe_views(&f.svc, &f.a, value.(json.Array)), "")
    testing.expect_value(t, len(f.a.ids), 3)
    testing.expect(t, tool_stream_view_current(&f.svc, &f.a, "inst_b"))
    testing.expect(t, !tool_stream_authorized(&f.svc, "owner", "chat_chain", "inst_unlisted"))
    f.run = 2
    testing.expect(t, !tool_stream_view_current(&f.svc, &f.a, "inst_b"), "membership revocation fences queued and incoming payload")
    tool_stream_scopes_free(f.a.scopes); f.a.scopes = nil
}

@(test)
test_tool_stream_legacy_bridge_requires_upgrade_without_demand :: proc(t: ^testing.T) {
    f: Tool_Stream_Test; tool_stream_test_init(&f); defer tool_stream_test_free(&f)
    bridges := iface.Bridge_Repository{get_bridge = proc(ctx: rawptr, id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
        return domain.Bridge{bridge_id = id, capabilities_json = `{"features":["get_agent_pane"]}`}, true, {}
    }}
    f.svc.bridges = &bridges
    f.a.external = true
    scopes := make(map[string]string, runtime.heap_allocator())
    defer tool_stream_scopes_free(scopes)
    scopes[strings.clone("inst_a", runtime.heap_allocator())] = strings.clone("chat_a", runtime.heap_allocator())
    testing.expect_value(t, tool_stream_subscribe(&f.svc, &f.a, []string{"inst_a"}, scopes), "upgrade_required")
    testing.expect_value(t, len(f.svc.tool_live.routes), 0)
    testing.expect_value(t, len(f.svc.tool_live.controls), 0)
    bridges.get_bridge = proc(ctx: rawptr, id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
        return domain.Bridge{bridge_id = id, capabilities_json = `{"features":["tool_stream_demand_v2"]}`}, true, {}
    }
    testing.expect(t, tool_stream_bridge_supported(&f.svc, "brg_a"))
}

@(test)
test_tool_stream_revoked_credential_stops_demand_and_late_delivery :: proc(t: ^testing.T) {
    f: Tool_Stream_Test; tool_stream_test_init(&f); defer tool_stream_test_free(&f)
    active := true
    f.a.authorization_ctx = &active
    f.a.authorize = proc(ctx: rawptr) -> bool { return (^bool)(ctx)^ }
    testing.expect_value(t, tool_stream_subscribe(&f.svc, &f.a, []string{"inst_a"}), "")
    token := strings.clone(f.svc.tool_live.routes["inst_a"].token, context.temp_allocator)
    tool_stream_test_clear(&f.a)
    active = false
    testing.expect(t, !tool_stream_view_current(&f.svc, &f.a, "inst_a"))
    testing.expect_value(t, tool_stream_subscribe(&f.svc, &f.a, []string{"inst_a"}), "unauthenticated")
    testing.expect(t, !tool_live_apply_bridge(&f.svc, "brg_a", 0, "1000", tool_stream_test_frame(token)))
    tool_stream_expire_at(&f.svc, time.tick_now()._nsec)
    testing.expect_value(t, len(f.svc.tool_live.routes), 0)
    testing.expect(t, f.a.stopped)
}
