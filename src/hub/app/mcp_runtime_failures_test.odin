#+feature dynamic-literals
package app

import "core:testing"
import "core:encoding/json"
import "core:strings"
import "core:thread"
import "base:runtime"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import mcp "odin_test:hub/service/mcp"
import agent "odin_test:hub/service/agent"
import http "odin_test:hub/transport/http"

MCP_Runtime_Race :: struct {g:^App_Graph,view:mcp.Access_View,raw:string,args:mcp.Runtime_Arguments,code:string,ok:bool}
mcp_runtime_race :: proc(job:^MCP_Runtime_Race) {
	context.allocator=runtime.heap_allocator()
	defer free_all(context.temp_allocator)
	text,code:=mcp_runtime_call(job.g,job.raw,job.view,"instances.create",job.args)
	job.code=code;job.ok=code=="" && strings.contains(text,"agent_instance_id")
}
mcp_runtime_cancel_after_prepare :: proc(ctx:rawptr)->bool {calls:=(^int)(ctx);calls^+=1;return calls^>=2}
mcp_runtime_timeout_now :: proc(ctx:rawptr)->string {return "2026-10-31T07:03:01Z"}

mcp_runtime_failures_test :: proc(t:^testing.T,g:^App_Graph,h:^http.MCP_Control_Handlers,headers:[]contracts.HTTP_Header,view:mcp.Access_View,raw:string,sink:^MCP_Runtime_Test_Sink,sample:json.Object) {
	a:=make(json.Object,context.temp_allocator);for key,value in sample do a[key]=value
	count:=len(sink.commands)
	for bad in ([]struct {key,value,code:string}{
		{"bridge_id","brg_placement_offline","bridge_offline"},
		{"bridge_id","brg_placement_foreign","not_found"},
		{"model","unsupported_model","invalid_arguments"},
	}) {
		original:=a[bad.key];a[bad.key]=json.String(bad.value);a["request_id"]=json.String("runtime_invalid_target")
		testing.expectf(t,strings.contains(mcp_runtime_heap_call(h,headers,"instances.create",a).body,bad.code),"target %s",bad.value)
		a[bad.key]=original
	}
	testing.expect_value(t,len(sink.commands),count)
	// A failed COMMIT consumes the UOW, rolls back all prepared rows and frees
	// reservations. Exercise this with the real heap allocator under ASan.
	testing.expect(t,sqlite.exec(&g.db,"PRAGMA foreign_keys=ON; CREATE TABLE runtime_parent(id INTEGER PRIMARY KEY); CREATE TABLE runtime_child(id INTEGER REFERENCES runtime_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER runtime_failed_commit AFTER INSERT ON mcp_mutation_receipts WHEN NEW.request_id='runtime_commit_failure' BEGIN INSERT INTO runtime_child(id) VALUES(999); END;"))
	before,_:=iface.agent_list_instances_by_owner(&g.repos.agents,domain.User_ID(view.owner),100)
	a["request_id"]=json.String("runtime_commit_failure")
	testing.expect(t,strings.contains(mcp_runtime_heap_call(h,headers,"instances.create",a).body,"request_failed"))
	after,_:=iface.agent_list_instances_by_owner(&g.repos.agents,domain.User_ID(view.owner),100)
	testing.expect(t,len(after)==len(before) && len(sink.commands)==count)
	_,_,found,_:=sqlite.mcp_receipt_get(&g.db,view.owner,view.grant,"instances.create","runtime_commit_failure");testing.expect(t,!found)
	testing.expect(t,sqlite.exec(&g.db,"DROP TRIGGER runtime_failed_commit; DROP TABLE runtime_child; DROP TABLE runtime_parent;"))
	result:=mcp_task_test_output(t,mcp_runtime_heap_call(h,headers,"instances.create",a));if result==nil do return
	testing.expect_value(t,len(sink.commands),count+1)
	// Cancelling after the intent commits sends no launch and leaves a sticky
	// native user-stop, so releasing the intent cannot let matching launch it.
	a["request_id"]=json.String("runtime_cancel_after_prepare");parsed,valid:=http.mcp_arguments("instances.create",a);if !testing.expect(t,valid) do return
	calls:=0;_,code:=mcp_runtime_call(g,raw,view,"instances.create",parsed.runtime,&calls,mcp_runtime_cancel_after_prepare)
	testing.expect_value(t,code,"cancelled");testing.expect_value(t,len(sink.commands),count+1)
	stored,exists:=sqlite.mcp_receipt_result(&g.db,view.owner,view.grant,"instances.create",parsed.runtime.request_id);state:MCP_Runtime_State
	if !testing.expect(t,exists && json.unmarshal_string(stored,&state,.JSON,context.temp_allocator)==nil) do return
	i,_,_:=iface.agent_get_instance(&g.repos.agents,state.result.agent_instance_id)
	testing.expect(t,state.result.phase=="not_dispatched" && i.runtime_status=="stopped" && i.stopped_by==agent.STOPPED_BY_USER)
	result=mcp_task_test_output(t,mcp_runtime_heap_call(h,headers,"instances.create",a));if result==nil do return;testing.expect(t,result["status"].(json.String)=="failed" && len(sink.commands)==count+1)
	// A send followed by failure to save progress must not look completed or
	// become retryable. The original prepared intent remains fail-closed.
	testing.expect(t,sqlite.exec(&g.db,"CREATE TRIGGER runtime_fail_progress BEFORE UPDATE ON mcp_mutation_receipts WHEN NEW.request_id='runtime_progress_failure' BEGIN SELECT RAISE(ABORT,'synthetic progress failure'); END;"))
	a["request_id"]=json.String("runtime_progress_failure")
	result=mcp_task_test_output(t,mcp_runtime_heap_call(h,headers,"instances.create",a));if result==nil do return
	testing.expect(t,result["status"].(json.String)=="repair_required" && result["phase"].(json.String)=="progress_unconfirmed" && len(sink.commands)==count+2)
	result=mcp_task_test_output(t,mcp_runtime_heap_call(h,headers,"instances.create",a));if result==nil do return
	testing.expect(t,result["phase"].(json.String)=="dispatch_unconfirmed" && len(sink.commands)==count+2)
	id:=string(result["agent_instance_id"].(json.String));busy,busy_err:=iface.agent_runtime_busy(&g.repos.agents,id);testing.expect(t,busy && busy_err.code==.None)
	testing.expect(t,sqlite.exec(&g.db,"DROP TRIGGER runtime_fail_progress;"))
	// Explicit native/operator reconciliation in this fixture; polling itself
	// never performs this write or resends the ambiguous command.
	stored,_=sqlite.mcp_receipt_result(&g.db,view.owner,view.grant,"instances.create","runtime_progress_failure");json.unmarshal_string(stored,&state,.JSON,context.temp_allocator)
	state.result.phase="awaiting_runtime";testing.expect(t,mcp_runtime_store(g,view,state))
	original_clock:=g.clock;g.clock.now=mcp_runtime_timeout_now
	result=mcp_runtime_test_poll(t,h,headers,"instances.create","runtime_progress_failure")
	g.clock=original_clock
	if result==nil do return
	testing.expect(t,result["status"].(json.String)=="repair_required" && result["phase"].(json.String)=="confirmation_timeout" && len(sink.commands)==count+2)
	// Concurrent identical calls may report busy, but only one native instance
	// and launch may exist. Later successful replays observe the same intent.
	a["request_id"]=json.String("runtime_concurrent");parsed,valid=http.mcp_arguments("instances.create",a);if !testing.expect(t,valid) do return
	jobs:[4]MCP_Runtime_Race;threads:[4]^thread.Thread
	previous_allocator:=context.allocator;context.allocator=runtime.heap_allocator()
	for j in 0..<len(jobs) {jobs[j]={g=g,view=view,raw=raw,args=parsed.runtime};threads[j]=thread.create_and_start_with_poly_data(&jobs[j],mcp_runtime_race)}
	for th in threads {thread.join(th);thread.destroy(th)}
	context.allocator=previous_allocator
	successes:=0;for job in jobs {if job.ok do successes+=1;testing.expect(t,job.ok || job.code=="busy")}
	testing.expect(t,successes>=1 && len(sink.commands)==count+3)
	result=mcp_task_test_output(t,mcp_runtime_heap_call(h,headers,"instances.create",a));testing.expect(t,result!=nil && len(sink.commands)==count+3)
	// An ambiguous transport failure stays guarded, even if a later inventory
	// could show a running process. Replaying this intent never sends again.
	a["request_id"]=json.String("runtime_ambiguous_send");sink.fail=true
	result=mcp_task_test_output(t,mcp_runtime_heap_call(h,headers,"instances.create",a));sink.fail=false
	if result==nil do return
	testing.expect(t,result["status"].(json.String)=="repair_required" && len(sink.commands)==count+4)
	id=string(result["agent_instance_id"].(json.String));busy,_=iface.agent_runtime_busy(&g.repos.agents,id);testing.expect(t,busy)
	result=mcp_task_test_output(t,mcp_runtime_heap_call(h,headers,"instances.create",a));testing.expect(t,result!=nil && len(sink.commands)==count+4)
}
