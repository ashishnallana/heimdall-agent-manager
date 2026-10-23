package agent

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(private = "file")
Tool_Stream_Test :: struct { svc: Agent_Service, repo: iface.Agent_Repository, a, b: Tool_Stream_Viewer, run: int }
@(private = "file")
tool_stream_test_init :: proc(f: ^Tool_Stream_Test) {
    heap := runtime.heap_allocator()
    f.run = 1
    f.repo = {ctx = f, get_tool_instance = proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
        f := (^Tool_Stream_Test)(ctx)
        return domain.Agent_Instance{agent_instance_id = id, bridge_id = "brg_a", owner_user_id = "owner" if id == "inst_a" else "foreign",
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
