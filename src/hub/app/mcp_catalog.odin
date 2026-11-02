package app

import "core:encoding/json"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import mcp "odin_test:hub/service/mcp"
import agent "odin_test:hub/service/agent"

mcp_mutate_catalog :: proc(ctx:rawptr,raw:string,view:mcp.Access_View,command:mcp.Catalog_Command)->(string,string) {
	g:=(^App_Graph)(ctx)
	uow,begun,err:=iface.unit_of_work_begin(&g.uow_factory);if !begun || err.code!=.None do return "","request_failed"
	finished:=false;defer if !finished do iface.unit_of_work_rollback(&uow)
	if code:=mcp_task_write_check(g,raw,view,command.tool);code!="" do return "",code
	a:=command.args;principal:=mcp.control_auth(view.owner)
	service:=&g.agents
	control:=mcp.Control_Service{agents=service}
	current:domain.Agent
	if command.tool!="agents.create" {row,found,e:=agent.get_agent(service,principal,a.agent_id);if !found || e.code!=.None do return "","not_found";current=row}
	digest,_,found,rerr:=sqlite.mcp_receipt_get(&g.db,view.owner,view.grant,command.tool,a.request_id)
	if rerr.code!=.None do return "","request_failed"
	if found {if digest!=command.digest do return "","idempotency_conflict";result,ok:=sqlite.mcp_receipt_result(&g.db,view.owner,view.grant,command.tool,a.request_id);if !ok || result=="" do return "","request_failed";return result,""}
	if command.tool!="agents.create" {revision,ok:=mcp.catalog_agent_revision(&control,current);if !ok do return "","request_failed";if revision!=a.expected_revision do return "","revision_conflict"}
	if command.tool=="agents.update" && domain.agent_permission_mode_normalize(current.permission_mode)=="ask" && command.input.permission_mode=="yolo" do return "","permission_escalation_not_allowed"
	if command.tool=="agents.create" || mcp.catalog_present(a,"template_id") {
		template_id:=command.input.template_id;if template_id=="" do template_id=domain.TEMPLATE_EMPTY_ID
		if !agent.agent_template_available(service,domain.User_ID(view.owner),template_id) do return "","not_found"
	}
	// Support updates are configuration only: no launch/stop, no fallback target.
	for support in a.supports {b,owned,e:=iface.bridge_get_bridge(service.bridges,support.bridge_id);if !owned || e.code!=.None || string(b.owner_user_id)!=view.owner do return "","not_found"}
	row:domain.Agent;ok:bool;operation_err:domain.Domain_Error
	switch command.tool {
	case "agents.create":row,ok,operation_err=agent.create_agent(service,principal,command.input)
	case "agents.update":row,ok,operation_err=agent.update_agent(service,principal,a.agent_id,command.input)
	case "agents.archive":
		if current.state==.Archived {row=current;ok=true} else {row,ok,operation_err=agent.archive_agent(service,principal,a.agent_id)}
	case:return "","invalid_arguments"
	}
	if !ok || operation_err.code!=.None {code:=mcp_task_error(operation_err);if code=="" do code="request_failed";return "",code}
	if len(row.agent_id)<=4 || !strings.has_prefix(row.agent_id,"agt_") do return "","request_failed"
	if mcp.catalog_present(a,"supports") {_,saved,e:=agent.replace_supports(service,principal,row.agent_id,a.supports);if !saved || e.code!=.None {code:=mcp_task_error(e);if code=="" do code="request_failed";return "",code}}
	revision,valid:=mcp.catalog_agent_revision(&control,row);if !valid do return "","request_failed"
	applied:=make([dynamic]string,context.temp_allocator)
	for key in mcp.CATALOG_KEYS do if mcp.catalog_present(a,key) && key!="agent_id" && key!="request_id" && key!="expected_revision" do append(&applied,key)
	changed:=command.tool!="agents.archive" || current.state!=.Archived
	result:=mcp.Catalog_Result{resource_id=row.agent_id,agent_id=row.agent_id,state="archived" if row.state==.Archived else "active",revision=revision,status="completed" if changed else "noop",changed=changed,applied_fields=applied[:]}
	encoded,eerr:=json.marshal(result,allocator=context.temp_allocator);if eerr!=nil do return "","request_failed"
	if e:=sqlite.mcp_receipt_put(&g.db,view.owner,view.grant,command.tool,a.request_id,command.digest,row.agent_id,string(encoded));e.code!=.None do return "","request_failed"
	commit_ok,commit_err:=iface.unit_of_work_commit(&uow);finished=true
	if !commit_ok || commit_err.code!=.None do return "","request_failed"
	return string(encoded),""
}
