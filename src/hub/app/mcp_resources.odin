package app

import "core:encoding/json"
import "core:strings"
import "base:runtime"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import mcp "odin_test:hub/service/mcp"
import content "odin_test:hub/service/content"
import project "odin_test:hub/service/project"
import issue "odin_test:hub/service/issue"

MCP_Resource_Attention :: struct {notifier:^contracts.Attention_Notifier,owner,id:string}
mcp_resource_attention_destroy :: proc(ctx:rawptr) {p:=(^MCP_Resource_Attention)(ctx);context.allocator=runtime.heap_allocator();delete(p.owner);delete(p.id);free(p)}
mcp_resource_attention_run :: proc(ctx:rawptr) {p:=(^MCP_Resource_Attention)(ctx);contracts.attention_notify(p.notifier,p.owner,contracts.ATTENTION_SOURCE_MEMORY,p.id);mcp_resource_attention_destroy(ctx)}
mcp_resource_control :: proc(g:^App_Graph)->mcp.Control_Service {return {content=&g.content,projects=&g.projects,issues=&g.issues,bridges=&g.repos.bridges,resource_ctx=&g.db,resource_page=sqlite.mcp_resource_refs}}
mcp_mutate_resource :: proc(ctx:rawptr,raw:string,view:mcp.Access_View,command:mcp.Resource_Command)->(string,string) {
	g:=(^App_Graph)(ctx);a:=command.args;kind:=mcp.resource_kind(command.tool)
	uow,begun,err:=iface.unit_of_work_begin(&g.uow_factory);if !begun || err.code!=.None do return "","request_failed"
	finished:=false;defer if !finished do iface.unit_of_work_rollback(&uow)
	if code:=mcp_task_write_check(g,raw,view,command.tool);code!="" do return "",code
	digest,_,found,rerr:=sqlite.mcp_receipt_get(&g.db,view.owner,view.grant,command.tool,a.request_id)
	if rerr.code!=.None do return "","request_failed"
	if found {if digest!=command.digest do return "","idempotency_conflict";result,ok:=sqlite.mcp_receipt_result(&g.db,view.owner,view.grant,command.tool,a.request_id);if !ok || result=="" do return "","request_failed";return result,""}
	if command.replay_only do return "","receipt_missing"
	control:=mcp_resource_control(g);current:json.Object;revision:string
	if a.id!="" {
		row,rev,code:=mcp.resource_get(&control,view.owner,kind,a.id,false);if code!="" do return "",code;current=row;revision=rev
		if read_only,_:=row["read_only"].(json.Boolean);bool(read_only) do return "","read_only"
		if revision!=a.expected_revision do return "","revision_conflict"
	}
	id,state,comment_id,code:string;changed:=true
	switch kind {
	case "memory":
		if command.tool=="memories.archive" && mcp.resource_text(current,"status")=="archived" {id=a.id;state="archived";changed=false} else {id,state,code=mcp_resource_memory(g,view,command)}
	case "project":
		if command.tool=="projects.archive" && mcp.resource_text(current,"state")=="archived" {id=a.id;state="archived";changed=false} else {id,state,code=mcp_resource_project(g,view,command)}
	case "issue":id,state,comment_id,code=mcp_resource_issue(g,view,command)
	case:return "","invalid_arguments"
	}
	if code!="" do return "",code
	prefix:="mem_";if kind=="project" do prefix="proj_";if kind=="issue" do prefix="iss_"
	if !strings.has_prefix(id,prefix) || len(id)<=len(prefix) do return "","request_failed"
	if command.tool!="issues.delete" {_,rev,e:=mcp.resource_get(&control,view.owner,kind,id,false);if e!="" do return "",e;revision=rev}
	result:=mcp.Resource_Result{resource_id=id,kind=kind,state=state,revision=revision,comment_id=comment_id,status="completed" if changed else "noop",changed=changed}
	encoded,eerr:=json.marshal(result,allocator=context.temp_allocator);if eerr!=nil do return "","request_failed"
	if perr:=sqlite.mcp_receipt_put(&g.db,view.owner,view.grant,command.tool,a.request_id,command.digest,id,string(encoded));perr.code!=.None do return "","request_failed"
	if kind=="memory" && changed && g.content.attention!=nil {
		hook:=new(MCP_Resource_Attention,runtime.heap_allocator());hook.notifier=g.content.attention;hook.owner=strings.clone(view.owner,runtime.heap_allocator());hook.id=strings.clone(id,runtime.heap_allocator())
		if !iface.unit_of_work_after_commit(&uow,{ctx=hook,run=mcp_resource_attention_run,discard=mcp_resource_attention_destroy}) {mcp_resource_attention_destroy(hook);return "","request_failed"}
	}
	ok,commit_err:=iface.unit_of_work_commit(&uow);finished=true
	if !ok || commit_err.code!=.None do return "","request_failed"
	return string(encoded),""
}
mcp_resource_memory :: proc(g:^App_Graph,view:mcp.Access_View,c:mcp.Resource_Command)->(string,string,string) {
	a:=c.args;auth:=mcp.control_auth(view.owner);s:=g.content;s.attention=nil
	row:domain.Memory;ok:bool;err:domain.Domain_Error
	projects:=make([]domain.Project_ID,len(a.project_ids),context.temp_allocator);for id,i in a.project_ids do projects[i]=domain.Project_ID(id)
	get :: proc(fields:json.Object,key:string)->string {return mcp.resource_text(fields,key)}
	switch c.tool {
	case "memories.create":row,ok,err=content.create_memory(&s,auth,{title=get(c.sealed,"title"),description=get(c.sealed,"description"),body=get(c.sealed,"body"),evidence=get(c.sealed,"evidence"),status="pending",type=domain.memory_type_from_string(a.type),expires_at=a.expires_at,agent_ids=a.agent_ids,project_ids=projects,bridge_ids=a.bridge_ids,template_ids=a.template_ids})
	case "memories.update":row,ok,err=content.update_memory(&s,auth,a.id,{title=get(c.sealed,"title"),description=get(c.sealed,"description"),body=get(c.sealed,"body"),evidence=get(c.sealed,"evidence"),type=domain.memory_type_from_string(a.type),expires_at=a.expires_at,agent_ids=a.agent_ids,project_ids=projects,bridge_ids=a.bridge_ids,template_ids=a.template_ids,has_title=mcp.resource_present(a,"title"),has_description=mcp.resource_present(a,"description"),has_body=mcp.resource_present(a,"body"),has_evidence=mcp.resource_present(a,"evidence"),has_type=mcp.resource_present(a,"type"),has_expires_at=mcp.resource_present(a,"expires_at"),has_agent_ids=mcp.resource_present(a,"agent_ids"),has_project_ids=mcp.resource_present(a,"project_ids"),has_bridge_ids=mcp.resource_present(a,"bridge_ids"),has_template_ids=mcp.resource_present(a,"template_ids")})
	case "memories.archive":row,ok,err=content.archive_memory(&s,auth,a.id)
	}
	if !ok || err.code!=.None do return "","",mcp_resource_error(err)
	return row.memory_id,row.status,""
}
mcp_resource_error :: proc(err:domain.Domain_Error)->string {code:=mcp_task_error(err);if code=="" do code="request_failed";return code}
mcp_resource_project :: proc(g:^App_Graph,view:mcp.Access_View,c:mcp.Resource_Command)->(string,string,string) {
	a:=c.args;auth:=mcp.control_auth(view.owner);row:domain.Project;ok:bool;err:domain.Domain_Error
	slug:=a.slug;if slug=="" && c.tool=="projects.create" {label:=mcp.resource_digest(struct {grant,digest:string}{view.grant,c.digest});slug=strings.concatenate({"project_",label[:16]},context.temp_allocator)}
	switch c.tool {
	case "projects.create":row,ok,err=project.create(&g.projects,auth,{name=mcp.resource_text(c.sealed,"name"),description=mcp.resource_text(c.sealed,"description"),slug=slug,repo_url=a.repo_url,vcs_kind=a.vcs_kind,default_path=a.default_path})
	case "projects.update":row,ok,err=project.update(&g.projects,auth,domain.Project_ID(a.id),{name=mcp.resource_text(c.sealed,"name"),description=mcp.resource_text(c.sealed,"description"),slug=slug,repo_url=a.repo_url,vcs_kind=a.vcs_kind,default_path=a.default_path,has_repo_url=mcp.resource_present(a,"repo_url"),has_vcs_kind=mcp.resource_present(a,"vcs_kind")})
	case "projects.archive":row,ok,err=project.archive_project(&g.projects,auth,domain.Project_ID(a.id))
	}
	if !ok || err.code!=.None do return "","",mcp_resource_error(err)
	for path in a.bridge_paths {
		if path.path=="" {_,err=project.delete_bridge_path(&g.projects,auth,row.project_id,path.bridge_id)} else {_,ok,err=project.set_bridge_path(&g.projects,auth,row.project_id,path.bridge_id,{path=path.path});if !ok do return "","",mcp_resource_error(err)}
		if err.code!=.None do return "","",mcp_resource_error(err)
	}
	return string(row.project_id),domain.project_state_string(row.state),""
}
mcp_resource_issue_target :: proc(g:^App_Graph,owner,scope,target,chain:string)->string {
	if chain!="" {row,found,e:=iface.taskchain_get_chain(&g.repos.taskchains,domain.Task_Chain_ID(chain));if !found || e.code!=.None || string(row.owner_user_id)!=owner do return "not_found"}
	switch scope {
	case "","global":if target!="" do return "invalid_arguments"
	case "project":row,found,e:=iface.project_get(&g.repos.projects,domain.Project_ID(target));if !found || e.code!=.None || string(row.owner_user_id)!=owner do return "not_found"
	case "agent_id":row,found,e:=iface.agent_get(&g.repos.agents,target);if !found || e.code!=.None || string(row.owner_user_id)!=owner do return "not_found"
	case "bridge_id":row,found,e:=iface.bridge_get_bridge(&g.repos.bridges,target);if !found || e.code!=.None || string(row.owner_user_id)!=owner do return "not_found"
	case:return "invalid_arguments"
	}
	return ""
}
mcp_resource_issue :: proc(g:^App_Graph,view:mcp.Access_View,c:mcp.Resource_Command)->(string,string,string,string) {
	a:=c.args;auth:=mcp.control_auth(view.owner);scope,target,chain:=a.scope_type,a.target_id,a.chain_id
	if c.tool!="issues.create" {
		old,found,e:=issue.get_issue(&g.issues,auth,domain.Issue_ID(a.id));if !found || e.code!=.None do return "","","","not_found"
		if !mcp.resource_present(a,"scope_type") do scope=domain.issue_scope_type_string(old.scope_type)
		if !mcp.resource_present(a,"target_id") do target=old.target_id
		if !mcp.resource_present(a,"chain_id") do chain=old.chain_id
	}
	if c.tool=="issues.create" || c.tool=="issues.update" {if code:=mcp_resource_issue_target(g,view.owner,scope,target,chain);code!="" do return "","","",code}
	row:domain.Issue;ok:bool;err:domain.Domain_Error;comment_id:string
	switch c.tool {
	case "issues.create":row,ok,err=issue.create_issue(&g.issues,auth,{title=mcp.resource_text(c.sealed,"title"),description=mcp.resource_text(c.sealed,"description"),created_by=view.owner,scope_type=scope,target_id=target,chain_id=chain})
	case "issues.update":row,ok,err=issue.update_issue(&g.issues,auth,domain.Issue_ID(a.id),{title=mcp.resource_text(c.sealed,"title"),description=mcp.resource_text(c.sealed,"description"),status=a.status,scope_type=scope,target_id=target,chain_id=chain,has_title=mcp.resource_present(a,"title"),has_desc=mcp.resource_present(a,"description"),has_status=mcp.resource_present(a,"status"),has_scope=mcp.resource_present(a,"scope_type"),has_target=mcp.resource_present(a,"target_id"),has_chain=mcp.resource_present(a,"chain_id")})
	case "issues.delete":ok,err=issue.delete_issue(&g.issues,auth,domain.Issue_ID(a.id));if ok && err.code==.None do return a.id,"deleted","",""
	case "issues.comment":
		comment:domain.Issue_Comment;comment,ok,err=issue.add_comment(&g.issues,auth,domain.Issue_ID(a.id),{author_id=view.owner,body=mcp.resource_text(c.sealed,"body")});comment_id=string(comment.comment_id)
		if ok {row,ok,err=issue.get_issue(&g.issues,auth,domain.Issue_ID(a.id));if ok {_,ok,err=iface.issue_update(&g.repos.issues,row)}}
	}
	if !ok || err.code!=.None do return "","","",mcp_resource_error(err)
	return string(row.issue_id),domain.issue_status_string(row.status),comment_id,""
}
