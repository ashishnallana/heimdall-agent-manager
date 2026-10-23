package agent

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import project_service "odin_test:hub/service/project"

@(private = "file")
Tool_Stream_Test :: struct { svc: Agent_Service, repo: iface.Agent_Repository, a, b: Tool_Stream_Viewer, run: int, bridge: string, registry: project_service.Bridge_Runtime_Registry }
@(private = "file")
tool_stream_test_init :: proc(f: ^Tool_Stream_Test) {
    heap := runtime.heap_allocator()
    f.run = 1; f.bridge = "brg_a"
    f.repo = {ctx = f, get_tool_instance = proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
        f := (^Tool_Stream_Test)(ctx)
        return domain.Agent_Instance{agent_instance_id = id, bridge_id = f.bridge, owner_user_id = "owner" if id == "inst_a" else "foreign",
            run_count = f.run, runtime_status = "running"}, true, {}
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
    for f in w.queue do delete(f.text, runtime.heap_allocator())
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
