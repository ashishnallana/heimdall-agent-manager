#+feature dynamic-literals
package app

import "core:testing"
import "core:encoding/json"
import "core:strings"
import "base:runtime"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import mcp "odin_test:hub/service/mcp"
import agent "odin_test:hub/service/agent"
import provider "odin_test:hub/service/provider"
import project "odin_test:hub/service/project"
import http "odin_test:hub/transport/http"

MCP_Runtime_Test_Sink :: struct {g:^App_Graph,commands:[dynamic]project.Runtime_Command,fail,revoke,inside_transaction:bool,view:mcp.Access_View}
mcp_runtime_test_sink_destroy :: proc(p:^MCP_Runtime_Test_Sink) {
	context.allocator=runtime.heap_allocator()
	for cmd in p.commands {delete(cmd.bridge_id);delete(cmd.command_id);delete(cmd.body_json)}
	delete(p.commands)
}
mcp_runtime_test_send :: proc(ctx:rawptr,cmd:project.Runtime_Command)->(bool,domain.Domain_Error) {
	p:=(^MCP_Runtime_Test_Sink)(ctx)
	uow,ok,_:=iface.unit_of_work_begin(&p.g.uow_factory);if ok {p.inside_transaction=p.inside_transaction || uow.nested;iface.unit_of_work_rollback(&uow)}
	context.allocator=runtime.heap_allocator()
	append(&p.commands,project.Runtime_Command{bridge_id=strings.clone(cmd.bridge_id),command_id=strings.clone(cmd.command_id),body_json=strings.clone(cmd.body_json)})
	if p.fail do return false,domain.domain_error(.Bridge_Offline,"synthetic ambiguous send failure")
	return true,{}
}
mcp_runtime_test_validate :: proc(ctx:rawptr,cmd:project.Validate_Project_Path_Command)->(project.Project_Path_Validation_Result,bool,domain.Domain_Error) {
	p:=(^MCP_Runtime_Test_Sink)(ctx)
	if p.revoke do _=mcp.delegation_revoke(&p.g.mcp_delegation,p.view.owner,p.view.grant)
	return {ok=true},true,{}
}
mcp_runtime_test_revision :: proc(g:^App_Graph,id:string)->json.String {i,_,_:=iface.agent_get_instance(&g.repos.agents,id);return json.String(mcp.runtime_revision(i))}
mcp_runtime_test_poll :: proc(t:^testing.T,h:^http.MCP_Control_Handlers,headers:[]contracts.HTTP_Header,tool,key:string)->json.Object {return mcp_task_test_output(t,mcp_runtime_heap_call(h,headers,"instances.operations",json.Object{"operation_tool"=json.String(tool),"request_id"=json.String(key)}))}

// Native operation getters return owned values which the adapter destroys.
// Heap allocation makes ASan detect accidentally borrowed response strings.
mcp_runtime_heap_call :: proc(h:^http.MCP_Control_Handlers,headers:[]contracts.HTTP_Header,tool:string,args:json.Object)->http.Response {
	context.allocator=runtime.heap_allocator()
	return mcp_task_test_call(h,headers,tool,args)
}

mcp_runtime_test :: proc(t:^testing.T,g:^App_Graph,h:^http.MCP_Control_Handlers,headers:[]contracts.HTTP_Header,view:mcp.Access_View,raw:string) {
	g.agents.clock=&g.clock;g.agents.ids=&g.ids;g.agents.taskchains=&g.repos.taskchains
	g.repos.content=sqlite.new_content_repository(&g.sqlite_content,&g.db);g.agents.content=&g.repos.content
	g.repos.projects=sqlite.new_project_repository(&g.sqlite_projects,&g.db);g.agents.projects=&g.repos.projects
	g.providers=provider.new_provider_service(&g.provider_repo)
	g.agents.bridge_runtime_registry=&g.bridge_runtime_registry
	defer project.bridge_runtime_registry_destroy(&g.bridge_runtime_registry)
	sink:=MCP_Runtime_Test_Sink{g=g,view=view}
	defer mcp_runtime_test_sink_destroy(&sink)
	g.agents.bridge_command_sink={ctx=&sink,send_runtime_command=mcp_runtime_test_send,validate_project_path=mcp_runtime_test_validate}
	for bridge_id in ([]string{"brg_placement_a","brg_placement_b"}) {
		b,_,_:=iface.bridge_get_bridge(&g.repos.bridges,bridge_id);b.capabilities_json=`{"features":["instance_reconfiguration_v1"]}`;_,_,_=iface.bridge_save_bridge(&g.repos.bridges,b)
		_,_,live:=project.bridge_runtime_registry_accept_live(&g.bridge_runtime_registry,bridge_id,false,"",view.owner);testing.expect(t,live)
		iface.bridge_provider_status_upsert(&g.provider_repo,{bridge_id=bridge_id,provider="claude",state="present"})
		iface.bridge_provider_setting_upsert(&g.provider_repo,{bridge_id=bridge_id,provider="claude",enabled=true})
	}
	list:=http.mcp_control_handler(h,{method="POST",path="/api/v1/mcp",headers=headers,body=strings.clone(`{"jsonrpc":"2.0","id":50,"method":"tools/list"}`,context.temp_allocator)})
	tools:struct {result:struct {tools:[]struct {name:string}}};json.unmarshal_string(list.body,&tools,.JSON,context.temp_allocator);testing.expect_value(t,len(tools.result.tools),25)
	for bad in ([]struct {tool:string,args:json.Object}{
		{"instances.start",json.Object{"agent_instance_id"=json.String("agt_wrong"),"request_id"=json.String("x"),"expected_revision"=json.String(strings.repeat("a",64,context.temp_allocator))}},
		{"instances.stop",json.Object{"agent_instance_id"=json.String("inst_a"),"request_id"=json.String("x"),"expected_revision"=json.String(strings.repeat("a",64,context.temp_allocator)),"force"=json.Boolean(true)}},
		{"instances.create",json.Object{"agent_id"=json.String("agt_placement"),"request_id"=json.String("x"),"permission_mode"=json.String("yolo")}},
		{"instances.operations",json.Object{"operation_tool"=json.String("tasks.create"),"request_id"=json.String("x")}},
	}) {_,ok:=http.mcp_arguments(bad.tool,bad.args);testing.expect(t,!ok)}
	created:=mcp_task_test_output(t,mcp_runtime_heap_call(h,headers,"agents.create",json.Object{"request_id"=json.String("runtime_definition"),"name"=json.String("Sealed runtime label"),"permission_mode"=json.String("ask")}));if created==nil do return
	agent_id,_:=created["agent_id"].(json.String)
	entry,_,_:=iface.provider_catalog_get(&g.provider_repo,"codex");model:=entry.models[0].model_id
	claude,_,_:=iface.provider_catalog_get(&g.provider_repo,"claude");claude_model:string;for candidate in claude.models do if candidate.state=="active" {claude_model=candidate.model_id;break}
	create:=json.Object{"agent_id"=agent_id,"chain_id"=json.String("chain_placement"),"bridge_id"=json.String("brg_placement_a"),"project_id"=json.String(""),"provider"=json.String("codex"),"provider_profile"=json.String("codex"),"model"=json.String(model),"request_id"=json.String("runtime_create"),"expected_revision"=created["revision"]}
	result:=mcp_task_test_output(t,mcp_runtime_heap_call(h,headers,"instances.create",create));if result==nil do return
	id,_:=result["agent_instance_id"].(json.String)
	testing.expect(t,len(sink.commands)==1 && result["status"].(json.String)=="pending" && !sink.inside_transaction)
	testing.expect(t,strings.contains(sink.commands[0].body_json,`"permission_mode":"ask"`))
	before,_:=iface.agent_list_instances_by_owner(&g.repos.agents,domain.User_ID(view.owner),100)
	retry:=mcp_task_test_output(t,mcp_runtime_heap_call(h,headers,"instances.create",create));if retry==nil do return
	after,_:=iface.agent_list_instances_by_owner(&g.repos.agents,domain.User_ID(view.owner),100)
	testing.expect(t,retry["agent_instance_id"].(json.String)==id && len(sink.commands)==1 && len(after)==len(before))
	i,_,_:=iface.agent_get_instance(&g.repos.agents,string(id));conversation,_,_:=iface.content_get_conversation(&g.repos.content,i.conversation_id)
	testing.expect(t,strings.has_prefix(i.display_name,"vault:v2:") && i.display_name==conversation.title && i.permission_mode=="" && i.agent_permission_mode=="ask")
	read:=mcp_catalog_first(t,h,headers,"instances.get",json.Object{"agent_instance_id"=id});if read==nil do return
	testing.expect(t,read["display_name"].(json.String)=="Sealed runtime label" && read["revision"]!=nil)
	create["model"]=json.String("wrong_model");testing.expect(t,strings.contains(mcp_runtime_heap_call(h,headers,"instances.create",create).body,"idempotency_conflict"));create["model"]=json.String(model)
	// Failed receipt insertion rolls back prepared instance/conversation and sends nothing.
	testing.expect(t,sqlite.exec(&g.db,"CREATE TRIGGER runtime_fail_receipt BEFORE INSERT ON mcp_mutation_receipts WHEN NEW.request_id='runtime_atomic' BEGIN SELECT RAISE(ABORT,'synthetic'); END;"))
	create["request_id"]=json.String("runtime_atomic")
	testing.expect(t,strings.contains(mcp_runtime_heap_call(h,headers,"instances.create",create).body,"request_failed"))
	after,_=iface.agent_list_instances_by_owner(&g.repos.agents,domain.User_ID(view.owner),100);testing.expect(t,len(after)==len(before) && len(sink.commands)==1)
	sqlite.exec(&g.db,"DROP TRIGGER runtime_fail_receipt;")
	// A stopped instance starts once, preserving inherited ask and its identity.
	i.runtime_status="stopped";i.startup_status="stopped";_,_,_=iface.agent_save_instance(&g.repos.agents,i)
	start:=json.Object{"agent_instance_id"=id,"request_id"=json.String("runtime_start"),"expected_revision"=mcp_runtime_test_revision(g,string(id))}
	result=mcp_task_test_output(t,mcp_runtime_heap_call(h,headers,"instances.start",start));if result==nil do return
	testing.expect(t,len(sink.commands)==2 && result["status"].(json.String)=="pending")
	testing.expect(t,strings.contains(sink.commands[1].body_json,`"permission_mode":"ask"`))
	mcp_task_test_output(t,mcp_runtime_heap_call(h,headers,"instances.start",start));testing.expect_value(t,len(sink.commands),2)
	start["request_id"]=json.String("runtime_stale");testing.expect(t,strings.contains(mcp_runtime_heap_call(h,headers,"instances.start",start).body,"revision_conflict"))
	i,_,_=iface.agent_get_instance(&g.repos.agents,string(id));i.runtime_status="running";i.startup_status="ready";_,_,_=iface.agent_save_instance(&g.repos.agents,i)
	result=mcp_runtime_test_poll(t,h,headers,"instances.start","runtime_start");if result==nil do return;testing.expect(t,result["status"].(json.String)=="completed")
	// Existing placement task holds a real native lease on B: lifecycle cannot
	// silently drop it or its checkpoint. Callers must explicitly hold work first.
	stop_busy:=json.Object{"agent_instance_id"=json.String("inst_placement_b"),"request_id"=json.String("runtime_busy"),"expected_revision"=mcp_runtime_test_revision(g,"inst_placement_b")}
	testing.expect(t,strings.contains(mcp_runtime_heap_call(h,headers,"instances.stop",stop_busy).body,"active_task_lease"));testing.expect_value(t,len(sink.commands),2)
	// Full cross-provider/bridge move: stopping is not completion; only native
	// stop acknowledgement then destination readiness can complete the operation.
	move:=json.Object{"agent_instance_id"=id,"bridge_id"=json.String("brg_placement_b"),"project_id"=json.String(""),"provider"=json.String("claude"),"provider_profile"=json.String("claude"),"model"=json.String(claude_model),"request_id"=json.String("runtime_move"),"expected_revision"=mcp_runtime_test_revision(g,string(id))}
	result=mcp_task_test_output(t,mcp_runtime_heap_call(h,headers,"instances.reconfigure",move));if result==nil do return
	if !testing.expectf(t,len(sink.commands)==3 && result["phase"].(json.String)=="stopping","move: %v commands %d model %s",result,len(sink.commands),claude_model) do return
	mcp_task_test_output(t,mcp_runtime_heap_call(h,headers,"instances.reconfigure",move));testing.expect_value(t,len(sink.commands),3)
	stop_command:=sink.commands[2];sink.fail=true
	agent.apply_reconfiguration_command_result(&g.agents,stop_command.bridge_id,stop_command.command_id,`{"status":"succeeded"}`)
	result=mcp_runtime_test_poll(t,h,headers,"instances.reconfigure","runtime_move");if result==nil do return
	testing.expectf(t,result["status"].(json.String)=="repair_required" && len(sink.commands)==4,"move repair: %v",result)
	i,_,_=iface.agent_get_instance(&g.repos.agents,string(id));testing.expect(t,i.bridge_id=="brg_placement_b" && i.provider=="claude" && i.permission_mode=="" && i.agent_permission_mode=="ask")
	old_epoch:=i.launch_epoch;original_conversation:=i.conversation_id
	sink.fail=false;move["request_id"]=json.String("runtime_move_retry");move["retry_request_id"]=json.String("runtime_move");move["expected_operation_revision"]=result["operation_revision"];move["expected_revision"]=mcp_runtime_test_revision(g,string(id))
	result=mcp_task_test_output(t,mcp_runtime_heap_call(h,headers,"instances.reconfigure",move));if result==nil do return
	testing.expect(t,result["status"].(json.String)=="pending" && len(sink.commands)==5)
	testing.expect(t,sink.commands[4].bridge_id=="brg_placement_b" && strings.contains(sink.commands[4].body_json,`"permission_mode":"ask"`) && strings.contains(sink.commands[4].body_json,`"provider":"claude"`))
	mcp_task_test_output(t,mcp_runtime_heap_call(h,headers,"instances.reconfigure",move));testing.expect_value(t,len(sink.commands),5)
	i,_,_=iface.agent_get_instance(&g.repos.agents,string(id));testing.expect(t,i.launch_epoch==old_epoch && i.conversation_id==original_conversation && i.chain_id=="chain_placement")
	i.runtime_status="running";i.startup_status="ready";_,_,_=iface.agent_save_instance(&g.repos.agents,i);agent.reconcile_active_reconfigurations(&g.agents)
	result=mcp_runtime_test_poll(t,h,headers,"instances.reconfigure","runtime_move_retry");if result==nil do return
	testing.expect(t,result["status"].(json.String)=="completed")
	stop:=json.Object{"agent_instance_id"=id,"request_id"=json.String("runtime_stop"),"expected_revision"=mcp_runtime_test_revision(g,string(id))}
	result=mcp_task_test_output(t,mcp_runtime_heap_call(h,headers,"instances.stop",stop));if result==nil do return
	testing.expect(t,result["status"].(json.String)=="pending" && len(sink.commands)==6)
	mcp_task_test_output(t,mcp_runtime_heap_call(h,headers,"instances.stop",stop));testing.expect_value(t,len(sink.commands),6)
	i,_,_=iface.agent_get_instance(&g.repos.agents,string(id));i.runtime_status="stopped";_,_,_=iface.agent_save_instance(&g.repos.agents,i)
	result=mcp_runtime_test_poll(t,h,headers,"instances.stop","runtime_stop");if result==nil do return;testing.expect(t,result["status"].(json.String)=="completed")
	encoded,_:=json.marshal(result,allocator=context.temp_allocator);for key in ([]string{"launch_epoch","token","project_path","command_id","failure_message"}) do testing.expect(t,!strings.contains(string(encoded),key))
	mcp_runtime_failures_test(t,g,h,headers,view,raw,&sink,create)
	before_revoke:=len(sink.commands)
	// Native guard runs after a remote project-path preflight. Revoke there;
	// no source stop or destination launch may be sent after the revocation.
	_,_,_=iface.project_save(&g.repos.projects,{project_id="proj_runtime",owner_user_id=domain.User_ID(view.owner),name="Project",slug="runtime",state=.Active})
	_,_,_=iface.project_save_bridge_path(&g.repos.projects,{project_id="proj_runtime",bridge_id="brg_placement_a",owner_user_id=domain.User_ID(view.owner),path="/synthetic"})
	delete_key(&move,"retry_request_id");delete_key(&move,"expected_operation_revision");move["request_id"]=json.String("runtime_revoke");move["project_id"]=json.String("proj_runtime");move["bridge_id"]=json.String("brg_placement_a");move["expected_revision"]=mcp_runtime_test_revision(g,string(id))
	sink.revoke=true
	response:=mcp_runtime_heap_call(h,headers,"instances.reconfigure",move)
	testing.expectf(t,response.status==401 && len(sink.commands)==before_revoke,"revoked preflight: %s, commands %d",response.body,len(sink.commands))
	_ = raw
}
