#+feature dynamic-literals
package app

import "core:encoding/json"
import "core:testing"
import "core:strings"
import "core:thread"
import "base:runtime"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import mcp "odin_test:hub/service/mcp"
import http "odin_test:hub/transport/http"

MCP_Resource_Race :: struct {g:^App_Graph,raw:string,view:mcp.Access_View,command:mcp.Resource_Command,result:[2048]byte,len:int,ok:bool}
mcp_resource_race :: proc(job:^MCP_Resource_Race) {
	context.allocator=runtime.heap_allocator();defer free_all(context.temp_allocator)
	result,code:=mcp_mutate_resource(job.g,job.raw,job.view,job.command)
	job.ok=code=="" && len(result)>0 && len(result)<=len(job.result);job.len=len(result)
	if job.ok do copy(job.result[:],result)
}
mcp_resource_security_test :: proc(t:^testing.T,g:^App_Graph,h:^http.MCP_Control_Handlers,headers:[]contracts.HTTP_Header,view:mcp.Access_View,raw:string,memory_id:json.String) {
	_,_,_=iface.project_save(&g.repos.projects,{project_id="proj_resource_foreign",owner_user_id="foreign_owner",name="foreign secret",slug="foreign-project",default_path="/foreign"})
	_,_,_=iface.content_save_memory(&g.repos.content,{memory_id="mem_resource_foreign",owner_user_id="foreign_owner",type=.Fact,status="pending",title="foreign secret",body="foreign secret"})
	_,_,_=iface.issue_save(&g.repos.issues,{issue_id="iss_resource_foreign",owner_user_id="foreign_owner",title="foreign secret",status=.New,scope_type=.Global})
	for resource in ([]struct {family,key,id:string}{
		{"memories","memory_id","mem_resource_foreign"},{"projects","project_id","proj_resource_foreign"},{"issues","issue_id","iss_resource_foreign"},
	}) {
		for action in ([]string{"get","update","archive"}) {
			actual:=action;if resource.family=="issues" && action=="archive" do actual="delete"
			tool:=strings.concatenate({resource.family,".",actual},context.temp_allocator)
			args:=json.Object{resource.key=json.String(resource.id)}
			if action!="get" {args["request_id"]=json.String("resource_foreign_denied");args["expected_revision"]=json.String(strings.repeat("0",64,context.temp_allocator))}
			if action=="update" {key:="title";if resource.family=="projects" do key="name";args[key]=json.String("Never change")}
			response:=mcp_resource_heap_call(h,headers,tool,args)
			testing.expect(t,strings.contains(response.body,"not_found") && !strings.contains(response.body,"foreign secret"))
			_,_,exists,_:=sqlite.mcp_receipt_get(&g.db,view.owner,view.grant,tool,"resource_foreign_denied");testing.expect(t,!exists)
		}
	}
	bad_target:=json.Object{"request_id"=json.String("resource_foreign_target"),"body"=json.String("Do not save"),"project_ids"=json.Array{json.String("proj_resource_foreign")}}
	testing.expect(t,strings.contains(mcp_resource_heap_call(h,headers,"memories.create",bad_target).body,"not_found"))
	// Same-timestamp native edits still conflict, including targeting changes.
	saved,_,_:=iface.content_get_memory(&g.repos.content,string(memory_id));old:=saved
	row:=mcp_resource_first(t,h,headers,"memories.get",json.Object{"memory_id"=memory_id});if row==nil do return
	saved.evidence=saved.body;_,_,_=iface.content_save_memory(&g.repos.content,saved)
	stale:=json.Object{"memory_id"=memory_id,"request_id"=json.String("resource_native_stale"),"expected_revision"=row["revision"],"description"=json.String("No overwrite")}
	testing.expect(t,strings.contains(mcp_resource_heap_call(h,headers,"memories.update",stale).body,"revision_conflict"))
	_,_,_=iface.content_save_memory(&g.repos.content,old)
	// Exercise native receipt concurrency, independently of ingress request-ID
	// throttling and with exactly one post-commit attention notification.
	sealed:=json.Object{"title"=json.String(saved.title),"body"=json.String(saved.body)}
	command:=mcp.Resource_Command{tool="memories.create",digest="resource_concurrency_digest",args={request_id="resource_concurrent",type="fact"},sealed=sealed}
	jobs:[4]MCP_Resource_Race;threads:[4]^thread.Thread
	allocator:=context.allocator;context.allocator=runtime.heap_allocator()
	for i in 0..<len(jobs) {jobs[i]={g=g,raw=raw,view=view,command=command};threads[i]=thread.create_and_start_with_poly_data(&jobs[i],mcp_resource_race)}
	for th in threads {thread.join(th);thread.destroy(th)}
	context.allocator=allocator
	for job in jobs do testing.expect(t,job.ok && job.len==jobs[0].len && job.result==jobs[0].result)
}
