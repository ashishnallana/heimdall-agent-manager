#+feature dynamic-literals
package app

import "core:encoding/json"
import "core:testing"
import "core:strings"
import "core:fmt"
import "base:runtime"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import mcp "odin_test:hub/service/mcp"
import content "odin_test:hub/service/content"
import project "odin_test:hub/service/project"
import issue "odin_test:hub/service/issue"
import http "odin_test:hub/transport/http"

mcp_resource_heap_call :: proc(h:^http.MCP_Control_Handlers,headers:[]contracts.HTTP_Header,tool:string,args:json.Object)->http.Response {context.allocator=runtime.heap_allocator();return mcp_task_test_call(h,headers,tool,args)}
mcp_resource_first :: proc(t:^testing.T,h:^http.MCP_Control_Handlers,headers:[]contracts.HTTP_Header,tool:string,args:json.Object)->json.Object {
	data:=mcp_task_test_output(t,mcp_resource_heap_call(h,headers,tool,args));if data==nil do return nil
	rows,_:=data["records"].(json.Array);if !testing.expect(t,len(rows)==1) do return nil;row,_:=rows[0].(json.Object);return row
}
mcp_resource_revoke :: proc(ctx:rawptr,raw:string,view:mcp.Access_View,c:mcp.Resource_Command)->(string,string) {
	if !c.replay_only do _=mcp.delegation_revoke(&(^App_Graph)(ctx).mcp_delegation,view.owner,view.grant)
	return mcp_mutate_resource(ctx,raw,view,c)
}
mcp_resource_test :: proc(t:^testing.T,g:^App_Graph,h:^http.MCP_Control_Handlers,headers:[]contracts.HTTP_Header,view:mcp.Access_View,raw:string) {
	g.repos.content=sqlite.new_content_repository(&g.sqlite_content,&g.db)
	g.repos.projects=sqlite.new_project_repository(&g.sqlite_projects,&g.db)
	g.repos.issues=sqlite.new_issue_repository(&g.sqlite_issues,&g.db)
	g.content=content.new_content_service(&g.repos.content,&g.repos.agents,&g.repos.bridges,&g.repos.projects,&g.repos.taskchains,&g.clock,&g.ids)
	g.projects=project.new_project_service_with_command_sink(&g.repos.projects,&g.repos.bridges,{},&g.clock,&g.ids)
	g.issues=issue.new_issue_service(&g.repos.issues,&g.clock,&g.ids)
	h.control=mcp_resource_control(g);h.mutate_resource=mcp_mutate_resource
	probe:=MCP_Task_Attention_Probe{factory=&g.uow_factory};notifier:=contracts.Attention_Notifier{ctx=&probe,notify=mcp_task_attention_probe};g.content.attention=&notifier
	listed:=http.mcp_control_handler(h,{method="POST",path="/api/v1/mcp",headers=headers,body=strings.clone(`{"jsonrpc":"2.0","id":50,"method":"tools/list"}`,context.temp_allocator)})
	tools:struct {result:struct {tools:[]struct {name:string}}};json.unmarshal_string(listed.body,&tools,.JSON,context.temp_allocator);testing.expect_value(t,len(tools.result.tools),41)
	testing.expect(t,!strings.contains(listed.body,"memories.approve") && !strings.contains(listed.body,"messages.send"))
	for bad in ([]struct {tool:string,args:json.Object}{
		{"memories.create",json.Object{"request_id"=json.String("bad"),"body"=json.String("Body"),"status"=json.String("active")}},
		{"issues.create",json.Object{"request_id"=json.String("bad"),"title"=json.String("Issue"),"created_by"=json.String("impersonate")}},
		{"issues.list",json.Object{"status"=json.String("unknown")}},
		{"memories.list",json.Object{"type"=json.String("unknown")}},
		{"projects.update",json.Object{"project_id"=json.String("proj_a"),"request_id"=json.String("bad"),"expected_revision"=json.String(strings.repeat("0",64,context.temp_allocator)),"metadata"=json.Object{}}},
	}) {_,valid:=http.mcp_arguments(bad.tool,bad.args);testing.expect(t,!valid)}
	pcreate:=json.Object{"request_id"=json.String("resource_project"),"name"=json.String("Private project"),"description"=json.String("Private description"),"default_path"=json.String("/synthetic/default"),"repo_url"=json.String("https://example.invalid/repo"),"vcs_kind"=json.String("git"),"bridge_paths"=json.Array{json.Object{"bridge_id"=json.String("brg_placement_a"),"path"=json.String("/synthetic/override")}}}
	response:=mcp_resource_heap_call(h,headers,"projects.create",pcreate);created:=mcp_task_test_output(t,response);if created==nil do return
	pid:=created["resource_id"].(json.String)
	testing.expect(t,response.body==mcp_resource_heap_call(h,headers,"projects.create",pcreate).body)
	p,_,_:=iface.project_get(&g.repos.projects,domain.Project_ID(pid));testing.expect(t,strings.has_prefix(p.name,"vault:v2:") && strings.has_prefix(p.description,"vault:v2:") && !strings.has_prefix(p.slug,"vault:"))
	prow:=mcp_resource_first(t,h,headers,"projects.get",json.Object{"project_id"=pid});if prow==nil do return
	paths,_:=prow["bridge_paths"].(json.Array);testing.expect(t,prow["name"].(json.String)=="Private project" && len(paths)==1)
	patch:=json.Object{"project_id"=pid,"request_id"=json.String("resource_project_patch"),"expected_revision"=prow["revision"],"description"=json.String(""),"repo_url"=json.String(""),"vcs_kind"=json.String(""),"bridge_paths"=json.Array{json.Object{"bridge_id"=json.String("brg_placement_a"),"path"=json.String("")}}}
	if mcp_task_test_output(t,mcp_resource_heap_call(h,headers,"projects.update",patch))==nil do return
	prow=mcp_resource_first(t,h,headers,"projects.get",json.Object{"project_id"=pid});if prow==nil do return
	paths,_=prow["bridge_paths"].(json.Array);testing.expect(t,len(paths)==0 && prow["description"].(json.String)=="" && prow["repo_url"].(json.String)=="" && prow["default_path"].(json.String)=="/synthetic/default")
	patch["expected_revision"]=prow["revision"];patch["request_id"]=json.String("resource_foreign_path");patch["bridge_paths"]=json.Array{json.Object{"bridge_id"=json.String("brg_placement_foreign"),"path"=json.String("/no")}}
	testing.expect(t,strings.contains(mcp_resource_heap_call(h,headers,"projects.update",patch).body,"not_found"))
	unchanged:=mcp_resource_first(t,h,headers,"projects.get",json.Object{"project_id"=pid});testing.expect(t,unchanged!=nil && unchanged["revision"].(json.String)==prow["revision"].(json.String))
	mcreate:=json.Object{"request_id"=json.String("resource_memory"),"title"=json.String("Private memory"),"body"=json.String("Private body"),"description"=json.String("Private summary"),"evidence"=json.String("Private evidence"),"type"=json.String("fact"),"agent_ids"=json.Array{json.String("agt_placement")},"project_ids"=json.Array{pid},"bridge_ids"=json.Array{json.String("brg_placement_a")},"template_ids"=json.Array{json.String(domain.TEMPLATE_EMPTY_ID)}}
	memory:=mcp_task_test_output(t,mcp_resource_heap_call(h,headers,"memories.create",mcreate));if memory==nil do return
	mid:=memory["resource_id"].(json.String);testing.expect(t,memory["state"].(json.String)=="pending" && probe.notices==1 && !probe.inside_transaction)
	m,_,_:=iface.content_get_memory(&g.repos.content,string(mid));testing.expect(t,m.status=="pending" && strings.has_prefix(m.body,"vault:v2:") && strings.has_prefix(m.evidence,"vault:v2:") && len(m.project_ids)==1 && m.expires_at!="")
	mrow:=mcp_resource_first(t,h,headers,"memories.get",json.Object{"memory_id"=mid});if mrow==nil do return;testing.expect(t,mrow["body"].(json.String)=="Private body")
	// A human/native approval is distinct from delegated CRUD. Updating the
	// approved row preserves its status under explicit memory-write consent.
	_,approved,_:=content.approve_memory(&g.content,mcp.control_auth(view.owner),string(mid));testing.expect(t,approved)
	mrow=mcp_resource_first(t,h,headers,"memories.get",json.Object{"memory_id"=mid});if mrow==nil do return
	medit:=json.Object{"memory_id"=mid,"request_id"=json.String("resource_memory_patch"),"expected_revision"=mrow["revision"],"body"=json.String("Edited private body"),"description"=json.String(""),"agent_ids"=json.Array{}}
	if mcp_task_test_output(t,mcp_resource_heap_call(h,headers,"memories.update",medit))==nil do return
	mrow=mcp_resource_first(t,h,headers,"memories.get",json.Object{"memory_id"=mid});if mrow==nil do return;testing.expect(t,mrow["status"].(json.String)=="active" && mrow["body"].(json.String)=="Edited private body" && mrow["description"].(json.String)=="")
	medit["request_id"]=json.String("resource_memory_stale");testing.expect(t,strings.contains(mcp_resource_heap_call(h,headers,"memories.update",medit).body,"revision_conflict"))
	_,_,_=iface.content_save_memory(&g.repos.content,{memory_id="mem_resource_system",owner_user_id="system",type=.Fact,status="active",title="System memory",body="Public builtin",created_at=mcp_task_test_now(nil),updated_at=mcp_task_test_now(nil)})
	system:=mcp_resource_first(t,h,headers,"memories.get",json.Object{"memory_id"=json.String("mem_resource_system")});if system==nil do return
	testing.expect(t,system["read_only"].(json.Boolean) && system["body"].(json.String)=="Public builtin")
	testing.expect(t,strings.contains(mcp_resource_heap_call(h,headers,"memories.archive",json.Object{"memory_id"=json.String("mem_resource_system"),"request_id"=json.String("no_system"),"expected_revision"=system["revision"]}).body,"read_only"))
	mcp_resource_issue_test(t,g,h,headers,view,pid)
	mcp_resource_paging_test(t,g,h,headers,view,pid)
	mcp_resource_commit_test(t,g,h,headers,view,mcreate,&probe)
	mcp_resource_security_test(t,g,h,headers,view,raw,mid)
	archive:=json.Object{"memory_id"=mid,"request_id"=json.String("resource_memory_archive"),"expected_revision"=mrow["revision"]}
	if mcp_task_test_output(t,mcp_resource_heap_call(h,headers,"memories.archive",archive))==nil do return
	_,found,_:=iface.content_get_memory(&g.repos.content,string(mid));testing.expect(t,found,"archive retains memory row")
	parchive:=json.Object{"project_id"=pid,"request_id"=json.String("resource_project_archive"),"expected_revision"=prow["revision"]}
	if mcp_task_test_output(t,mcp_resource_heap_call(h,headers,"projects.archive",parchive))==nil do return
	p,found,_=iface.project_get(&g.repos.projects,domain.Project_ID(pid));testing.expect(t,found && p.state==.Archived)
	h.mutate_resource=mcp_resource_revoke
	mcreate["request_id"]=json.String("resource_revoked");revoked:=mcp_resource_heap_call(h,headers,"memories.create",mcreate);testing.expect(t,revoked.status==401)
	_,_,exists,_:=sqlite.mcp_receipt_get(&g.db,view.owner,view.grant,"memories.create","resource_revoked");testing.expect(t,!exists)
	_=raw
}
