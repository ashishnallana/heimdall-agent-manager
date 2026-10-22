package agent

import "base:runtime"
import "core:net"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import events "odin_test:hub/service/events"
import project_service "odin_test:hub/service/project"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import live "odin_test:lib/tool_live"
import ws "odin_test:lib/ws"

@(private = "file")
live_test_inst :: domain.Agent_Instance{agent_instance_id = "live_a", owner_user_id = "owner", bridge_id = "bridge_a",
 agent_id = "agent_worker", display_name = "Worker A", chain_id = "chain_a", runtime_status = "running"}
@(private = "file")
Live_Relay_Source :: struct { service: ^Agent_Service, active: bool, calls: int }
@(private = "file")
live_relay_frame :: proc(id, request_id, kind: string, active: bool, rev: int = 1, epoch := "1000") -> string {
 v, _ := json.parse_string(`{"instance_id":"live_a","epoch":"1000","generation":1,"revision":1,"active":[],"last_completion":null}`, .JSON, true, context.temp_allocator)
 snap := v.(json.Object)
 snap["instance_id"] = json.String(id); snap["epoch"] = json.String(epoch); snap["revision"] = json.Integer(rev)
 if active {
  arr, _ := json.parse_string(`[{"call_id":"x","source":"provider","provider_session_id":"s1","agent_id":"","tool_use_id":"x","tool_name":"Read","shell_session_id":"","shell_run_seq":0,"started_at_ms":1000}]`, .JSON, true, context.temp_allocator)
  snap["active"] = arr
 } else {
  last, _ := json.parse_string(`{"call_id":"x","source":"provider","tool_name":"Read","duration_ms":1000,"completed_at_ms":2000,"status":"completed"}`, .JSON, true, context.temp_allocator)
  snap["last_completion"] = last
 }
 frame := struct {type, request_id, epoch: string, run_count: int, snapshot: json.Value}{kind, request_id, epoch, 0, v}
 data, _ := json.marshal(frame, allocator = context.temp_allocator)
 return string(data)
}
@(private = "file")
live_relay_send :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
 f := (^Live_Relay_Source)(ctx); f.calls += 1
 root, _ := json.parse_string(command.body_json, .JSON, true, context.temp_allocator)
 obj := root.(json.Object)
 reply := live_relay_frame(tool_live_text(obj, "instance_id"), tool_live_text(obj, "request_id"), "tool_activity_live_reply", f.active, f.calls)
 ok := tool_live_apply_bridge(f.service, command.bridge_id, 0, "1000", reply)
 return ok, domain.Domain_Error{}
}
// Membership is read from the same repository source used by task dispatch.
@(private = "file")
Live_Chain_Test :: struct { rows: []domain.Agent_Instance, members: []domain.Task_Chain_Member, coordinator_id: string }
@(private = "file")
live_chain_get :: proc(ctx: rawptr, id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	return domain.Task_Chain{chain_id = id, owner_user_id = "owner", coordinator_agent_instance_id = (^Live_Chain_Test)(ctx).coordinator_id}, true, {}
}
@(private = "file")
live_chain_members :: proc(ctx: rawptr, id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task_Chain_Member, domain.Domain_Error) {
	return (^Live_Chain_Test)(ctx).members, {}
}
@(private = "file")
live_chain_instances :: proc(ctx: rawptr, owner: domain.User_ID, chain: string) -> ([]domain.Agent_Instance, domain.Domain_Error) {
	return (^Live_Chain_Test)(ctx).rows, {} // deliberately includes foreign rows: filter must defend
}
@(private = "file")
live_chain_instance :: proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	for inst in (^Live_Chain_Test)(ctx).rows do if inst.agent_instance_id == id do return inst, true, {}
	return {}, false, domain.domain_error(.Not_Found, "not found")
}
@(test)
test_live_chain_isolation_membership_and_reconnect :: proc(t: ^testing.T) {
	s := Agent_Service{}
	defer tool_live_destroy(&s.tool_live)
	rows := [4]domain.Agent_Instance{live_test_inst, live_test_inst, live_test_inst, live_test_inst}
	rows[1].agent_instance_id = "reviewer_a" // same durable identity; separate run
	rows[2].agent_instance_id = "unrelated"; rows[2].chain_id = "chain_b"
	rows[3].agent_instance_id = "foreign"; rows[3].owner_user_id = "other"
	fixture := Live_Chain_Test{rows = rows[:]}
	repo := iface.Agent_Repository{ctx = &fixture, list_instances_by_chain = live_chain_instances, get_instance = live_chain_instance}
	chains := iface.Taskchain_Repository{ctx = &fixture, get_chain = live_chain_get, list_members_by_chain = live_chain_members}
	s.agents = &repo; s.taskchains = &chains
	source := Live_Relay_Source{service = &s, active = true}
	s.bridge_command_sink = project_service.Bridge_Command_Sink{ctx = &source, send_runtime_command = live_relay_send}
	auth := contracts.Auth_Context{kind = .User_Token, user_id = "owner"}
	body, ok, _ := tool_live_chain_snapshot(&s, auth, "chain_a")
	testing.expect(t, ok)
	value, _ := json.parse_string(body, .JSON, true, context.temp_allocator)
	delete(body)
	obj := value.(json.Object)
	members := obj["members"].(json.Array)
	testing.expect_value(t, len(members), 2)
	testing.expect_value(t, members[0].(json.Object)["instance_id"].(json.String), "live_a")
	source.active = false
	body, ok, _ = tool_live_chain_snapshot(&s, auth, "chain_a")
	testing.expect(t, ok)
	value, _ = json.parse_string(body, .JSON, true, context.temp_allocator)
	delete(body)
	members = value.(json.Object)["members"].(json.Array)
	first := members[0].(json.Object)["snapshot"].(json.Object)
	testing.expect_value(t, len(first["active"].(json.Array)), 0)
	testing.expect_value(t, first["last_completion"].(json.Object)["duration_ms"].(json.Integer), 1000)
	rows[1].chain_id = "chain_b"
	body, _, _ = tool_live_chain_snapshot(&s, auth, "chain_a")
	value, _ = json.parse_string(body, .JSON, true, context.temp_allocator); delete(body)
	testing.expect_value(t, len(value.(json.Object)["members"].(json.Array)), 1)
	_, foreign_ok, _ := tool_live_chain_snapshot(&s, contracts.Auth_Context{kind = .User_Token, user_id = "other"}, "chain_a")
	testing.expect(t, !foreign_ok, "foreign owner rejected")
	_, unrelated_ok, _ := tool_live_chain_snapshot(&s, contracts.Auth_Context{kind = .Instance_Token, user_id = "owner", agent_instance_id = "unrelated"}, "chain_a")
	testing.expect(t, !unrelated_ok, "unrelated-chain instance rejected")
	fixture.members = []domain.Task_Chain_Member{{chain_id = "chain_a", owner_user_id = "owner", role = "coordinator", agent_instance_id = "unrelated"}}
	coordinator_auth := contracts.Auth_Context{kind = .Instance_Token, user_id = "owner", agent_instance_id = "unrelated"}
	coordinator_body, coordinator_ok, _ := tool_live_chain_snapshot(&s, coordinator_auth, "chain_a")
	testing.expect(t, coordinator_ok, "explicit coordinator may coordinate multiple chains")
	if coordinator_ok {
		value, _ = json.parse_string(coordinator_body, .JSON, true, context.temp_allocator)
		testing.expect_value(t, len(value.(json.Object)["members"].(json.Array)), 2)
		delete(coordinator_body)
	}
	fixture.members = nil
	_, removed_ok, _ := tool_live_chain_snapshot(&s, coordinator_auth, "chain_a")
	testing.expect(t, !removed_ok, "removing coordinator membership revokes cross-chain access")
	fixture.coordinator_id = "unrelated"
	canonical_body, canonical_ok, _ := tool_live_chain_snapshot(&s, coordinator_auth, "chain_a")
	testing.expect(t, canonical_ok, "canonical chain coordinator field grants access")
	delete(canonical_body)
}



@(private = "file")
Live_Pair :: struct { listener, peer, hub: net.TCP_Socket }
@(private = "file")
live_pair :: proc(t: ^testing.T) -> Live_Pair {
	listener, le := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if le != nil do testing.fail_now(t, "listen failed")
	bound, be := net.bound_endpoint(listener)
	if be != nil { net.close(listener); testing.fail_now(t, "bound endpoint failed") }
	peer, de := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	if de != nil { net.close(listener); testing.fail_now(t, "dial failed") }
	hub, _, ae := net.accept_tcp(listener)
	if ae != nil { net.close(listener); net.close(peer); testing.fail_now(t, "accept failed") }
	return Live_Pair{listener, peer, hub}
}
@(private = "file")
live_close_pair :: proc(p: Live_Pair) {
	net.close(p.hub); net.close(p.peer); net.close(p.listener)
}

@(test)
test_live_relay_snapshot_is_on_demand_and_retains_no_content :: proc(t: ^testing.T) {
 rows := [1]domain.Agent_Instance{live_test_inst}
 f := Live_Chain_Test{rows = rows[:]}
 repo := iface.Agent_Repository{ctx = &f, get_instance = live_chain_instance}
 s := Agent_Service{agents = &repo}; defer tool_live_destroy(&s.tool_live)
 source := Live_Relay_Source{service = &s, active = true}
 s.bridge_command_sink = {ctx = &source, send_runtime_command = live_relay_send}
 body, ok, err := tool_live_request_snapshot(&s, rows[0])
 testing.expect(t, ok, err.message)
 testing.expect(t, strings.contains(body, `"call_id":"x"`)); delete(body)
 source.active = false
 body, ok, err = tool_live_request_snapshot(&s, rows[0])
 testing.expect(t, ok, err.message)
 testing.expect(t, strings.contains(body, `"active":[]`))
 testing.expect(t, strings.contains(body, `"duration_ms":1000`)); delete(body)
 testing.expect_value(t, source.calls, 2)
 for p in s.tool_live.pending do testing.expect(t, !p.used && p.reply == "" && p.instance_id == "")
 // No request/timer runs between explicit calls.
 testing.expect_value(t, source.calls, 2)
}
@(test)
test_live_relay_owner_socket_isolation_and_final_empty_push :: proc(t: ^testing.T) {
 rows := [1]domain.Agent_Instance{live_test_inst}
 f := Live_Chain_Test{rows = rows[:]}
 repo := iface.Agent_Repository{ctx = &f, get_instance = live_chain_instance}
 s := Agent_Service{agents = &repo}; defer tool_live_destroy(&s.tool_live)
 bus: events.User_Event_Bus; s.event_bus = &bus
 mine := live_pair(t); defer live_close_pair(mine)
 other := live_pair(t); defer live_close_pair(other)
 mh, _ := events.user_ws_attach(&bus, "owner", mine.hub); defer events.user_ws_detach(&bus, mh)
 oh, _ := events.user_ws_attach(&bus, "other", other.hub); defer events.user_ws_detach(&bus, oh)
 mr := ws.reader_make(); defer ws.reader_destroy(&mr)
 or := ws.reader_make(); defer ws.reader_destroy(&or)
 _, ready, _ := ws.read_frame(mine.peer, &mr, time.Second); delete(ready)
 _, ready, _ = ws.read_frame(other.peer, &or, time.Second); delete(ready)
 for active, i in ([2]bool{true,false}) {
  accepted := tool_live_apply_bridge(&s, "bridge_a", 1, "1000", live_relay_frame("live_a", "", "tool_activity_live_snapshot", active, i+1))
  testing.expect(t, accepted)
  _, frame, got := ws.read_frame(mine.peer, &mr, time.Second)
  testing.expect(t, got)
  if i == 1 do testing.expect(t, strings.contains(frame, `"active":[]`))
  delete(frame)
 }
 _, _, leaked := ws.read_frame(other.peer, &or, 30*time.Millisecond)
 testing.expect(t, !leaked)
 for p in s.tool_live.pending do testing.expect(t, !p.used)
}
@(test)
test_live_relay_rejects_binding_launch_epoch_and_unsolicited_reply :: proc(t: ^testing.T) {
 rows := [1]domain.Agent_Instance{live_test_inst}
 f := Live_Chain_Test{rows = rows[:]}
 repo := iface.Agent_Repository{ctx = &f, get_instance = live_chain_instance}
 s := Agent_Service{agents = &repo}; defer tool_live_destroy(&s.tool_live)
 raw := live_relay_frame("live_a", "", "tool_activity_live_snapshot", true)
 testing.expect(t, !tool_live_apply_bridge(&s, "foreign_bridge", 1, "1000", raw))
 testing.expect(t, !tool_live_apply_bridge(&s, "bridge_a", 1, "2000", raw))
 rows[0].run_count = 1
 testing.expect(t, !tool_live_apply_bridge(&s, "bridge_a", 1, "1000", raw))
 rows[0].run_count = 0; rows[0].runtime_status = "stopped"
 testing.expect(t, !tool_live_apply_bridge(&s, "bridge_a", 1, "1000", raw))
 rows[0].runtime_status = "running"
 late := live_relay_frame("live_a", "expired", "tool_activity_live_reply", true)
 testing.expect(t, !tool_live_apply_bridge(&s, "bridge_a", 1, "1000", late))
 for p in s.tool_live.pending do testing.expect(t, p.reply == "")
}
@(test)
test_live_relay_pending_caps_and_terminal_cancellation :: proc(t: ^testing.T) {
 s := Agent_Service{}; defer tool_live_destroy(&s.tool_live)
 heap := runtime.heap_allocator()
 for i in 0..<TOOL_LIVE_PER_OWNER_PENDING {
  s.tool_live.pending[i] = {used = true, owner = strings.clone("owner", heap), instance_id = strings.clone("live_a", heap)}
 }
 _, ok, err := tool_live_request_snapshot(&s, live_test_inst)
 testing.expect(t, !ok && err.code == .Bridge_Busy)
 tool_live_cancel(&s, "live_a", "")
 for p in s.tool_live.pending[:2] do testing.expect(t, p.done && p.cancelled)
 for &p, i in s.tool_live.pending {
  tool_live_pending_free(&p)
  p = {used = true, owner = strings.clone(fmt.tprintf("owner_%d", i), heap)}
 }
 _, ok, err = tool_live_request_snapshot(&s, live_test_inst)
 testing.expect(t, !ok && err.code == .Bridge_Busy)
 testing.expect(t, !live.wire_shape_ok(strings.repeat("[", 9, context.temp_allocator)))
 testing.expect(t, !live.wire_shape_ok(strings.repeat("a", live.MAX_FRAME_BYTES+1, context.temp_allocator)))
}

@(test)
test_live_relay_deadline_reclaims_slot_and_late_reply_is_discarded :: proc(t:^testing.T) {
 rows := [1]domain.Agent_Instance{live_test_inst}
 f := Live_Chain_Test{rows=rows[:]}
 repo := iface.Agent_Repository{ctx=&f,get_instance=live_chain_instance}
 s := Agent_Service{agents=&repo}; defer tool_live_destroy(&s.tool_live)
 s.bridge_command_sink.send_runtime_command = proc(ctx:rawptr,command:project_service.Runtime_Command)->(bool,domain.Domain_Error){return true,{}}
 start := time.now()
 _,ok,_ := tool_live_request_snapshot(&s,rows[0],5*time.Millisecond)
 testing.expect(t,!ok)
 testing.expect(t,time.diff(start,time.now())<time.Second)
 for p in s.tool_live.pending do testing.expect(t,!p.used && p.reply=="")
 late:=live_relay_frame("live_a","expired","tool_activity_live_reply",true)
 testing.expect(t,!tool_live_apply_bridge(&s,"bridge_a",0,"1000",late))
}
@(test)
test_live_chain_pages_are_bounded_and_roster_token_changes :: proc(t:^testing.T) {
 rows:[17]domain.Agent_Instance
 for &row,i in rows {row=live_test_inst;row.agent_instance_id=fmt.tprintf("member_%02d",i)}
 f:=Live_Chain_Test{rows=rows[:]}
 repo:=iface.Agent_Repository{ctx=&f,get_instance=live_chain_instance,list_instances_by_chain=live_chain_instances}
 chains:=iface.Taskchain_Repository{ctx=&f,get_chain=live_chain_get,list_members_by_chain=live_chain_members}
 s:=Agent_Service{agents=&repo,taskchains=&chains};defer tool_live_destroy(&s.tool_live)
 source:=Live_Relay_Source{service=&s}
 s.bridge_command_sink={ctx=&source,send_runtime_command=live_relay_send}
 auth:=contracts.Auth_Context{kind=.User_Token,user_id="owner"}
 cursor:=""; token:=""; count:=0
 for page in 0..<3 {
  body,ok,_:=tool_live_chain_snapshot(&s,auth,"chain_a",cursor);testing.expect(t,ok)
  v,_:=json.parse_string(body,.JSON,true,context.temp_allocator);delete(body)
  obj:=v.(json.Object); members:=obj["members"].(json.Array)
  testing.expect(t,len(members)<=8);count+=len(members)
  if page==0 do token=tool_live_text(obj,"roster_token")
  testing.expect_value(t,tool_live_text(obj,"roster_token"),token)
  cursor=tool_live_text(obj,"next_cursor")
 }
 testing.expect_value(t,count,17);testing.expect_value(t,cursor,"")
 rows[0].chain_id="chain_b"
 body,_,_:=tool_live_chain_snapshot(&s,auth,"chain_a")
 v,_:=json.parse_string(body,.JSON,true,context.temp_allocator);delete(body)
 testing.expect(t,tool_live_text(v.(json.Object),"roster_token")!=token)
}
