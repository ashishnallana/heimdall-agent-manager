#+feature dynamic-literals
package app

import "core:encoding/json"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import mcp "odin_test:hub/service/mcp"
import events "odin_test:hub/service/events"
import project "odin_test:hub/service/project"
import http "odin_test:hub/transport/http"
import vault "odin_test:lib/vault"

@(test)
test_mcp_chain_create_native_coordinator_atomic_launch :: proc(t:^testing.T) {
	mcp_task_test_fixture(t,#load("../../../tests/fixtures/mcp_runtime_v2.json",string),true,chain_creation=true)
}

mcp_chain_create_test :: proc(t:^testing.T,g:^App_Graph,h:^http.MCP_Control_Handlers,headers:[]contracts.HTTP_Header,view:mcp.Access_View,raw:string) {
	g.agents.clock=&g.clock;g.agents.ids=&g.ids;g.agents.taskchains=&g.repos.taskchains
	g.repos.content=sqlite.new_content_repository(&g.sqlite_content,&g.db);g.agents.content=&g.repos.content
	g.agents.bridge_runtime_registry=&g.bridge_runtime_registry
	defer project.bridge_runtime_registry_destroy(&g.bridge_runtime_registry)
	_,_,live:=project.bridge_runtime_registry_accept_live(&g.bridge_runtime_registry,"brg_placement_a",false,"",view.owner)
	if !testing.expect(t,live) do return
	sink:=MCP_Runtime_Test_Sink{g=g,view=view}
	defer mcp_runtime_test_sink_destroy(&sink)
	g.agents.bridge_command_sink={ctx=&sink,send_runtime_command=mcp_runtime_test_send}
	entry,_,_:=iface.provider_catalog_get(&g.provider_repo,"codex");model:=entry.models[0].model_id
	args:=json.Object{"title"=json.String("Fresh coordinator chain"),"description"=json.String("Private description"),"coordinator_agent_id"=json.String("agt_placement"),"bridge_id"=json.String("brg_placement_a"),"provider"=json.String("codex"),"provider_profile"=json.String("codex"),"model"=json.String(model)}
	owner:=domain.User_ID(view.owner)
	before,_:=iface.taskchain_list_chains_by_owner(&g.repos.taskchains,owner)
	// Every owner-bus publish bumps this hint: rejected or rolled-back creates
	// announce nothing; a committed one must reach the sidebar's live clients.
	hint,attached:=events.poll_attach(&g.event_bus,view.owner)
	if !testing.expect(t,attached) do return
	defer events.poll_detach(&g.event_bus,hint)
	instances_before,_:=iface.agent_list_instances_by_owner(&g.repos.agents,owner,100)
	// Unknown and foreign agents are indistinguishable, and neither creates state.
	_,_,_=iface.agent_save(&g.repos.agents,{agent_id="agt_foreign_coordinator",owner_user_id="foreign_owner",name="Foreign",slug="foreign-coordinator",template_id=domain.TEMPLATE_EMPTY_ID,state=.Active})
	for id in ([]string{"agt_missing","agt_foreign_coordinator"}) {
		args["coordinator_agent_id"]=json.String(id)
		response:=mcp_task_test_call(h,headers,"chains.create",args)
		testing.expectf(t,strings.contains(response.body,"coordinator_not_found"),"lookup: %s",response.body)
	}
	args["coordinator_agent_id"]=json.String("agt_placement")
	for bridge in ([]string{"brg_missing","brg_placement_foreign","brg_placement_offline"}) {
		args["bridge_id"]=json.String(bridge)
		response:=mcp_task_test_call(h,headers,"chains.create",args)
		testing.expect(t,strings.contains(response.body,"bridge_not_found") || strings.contains(response.body,"bridge_offline"))
	}
	args["bridge_id"]=json.String("brg_placement_a")
	after,_:=iface.taskchain_list_chains_by_owner(&g.repos.taskchains,owner)
	testing.expect(t,len(after)==len(before) && len(sink.commands)==0)
	// A failure late in native preparation rolls back chain, instance and chat.
	testing.expect(t,sqlite.exec(&g.db,"CREATE TRIGGER coordinator_fail_chat BEFORE INSERT ON chat_conversations BEGIN SELECT RAISE(ABORT,'synthetic coordinator chat failure'); END;"))
	failed:=mcp_task_test_call(h,headers,"chains.create",args)
	testing.expectf(t,strings.contains(failed.body,"conflict"),"rollback response: %s",failed.body)
	after,_=iface.taskchain_list_chains_by_owner(&g.repos.taskchains,owner)
	instances_after,_:=iface.agent_list_instances_by_owner(&g.repos.agents,owner,100)
	testing.expect(t,len(after)==len(before) && len(instances_after)==len(instances_before) && len(sink.commands)==0)
	sqlite.exec(&g.db,"DROP TRIGGER coordinator_fail_chat;")
	// A deferred constraint fails the actual COMMIT after preparation succeeds.
	testing.expect(t,sqlite.exec(&g.db,"PRAGMA foreign_keys=ON; CREATE TABLE coordinator_commit_parent(id INTEGER PRIMARY KEY); CREATE TABLE coordinator_commit_child(id INTEGER REFERENCES coordinator_commit_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER coordinator_fail_commit AFTER INSERT ON chat_conversations BEGIN INSERT INTO coordinator_commit_child(id) VALUES(999); END;"))
	failed=mcp_task_test_call(h,headers,"chains.create",args)
	testing.expect(t,strings.contains(failed.body,"request_failed"))
	after,_=iface.taskchain_list_chains_by_owner(&g.repos.taskchains,owner)
	instances_after,_=iface.agent_list_instances_by_owner(&g.repos.agents,owner,100)
	testing.expect(t,len(after)==len(before) && len(instances_after)==len(instances_before) && len(sink.commands)==0)
	testing.expect(t,sqlite.exec(&g.db,"DROP TRIGGER coordinator_fail_commit; DROP TABLE coordinator_commit_child; DROP TABLE coordinator_commit_parent;"))
	testing.expect_value(t,events.poll_revision(&g.event_bus,hint),u64(0))
	result:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"chains.create",args));if result==nil do return
	id:=string(result["coordinator_agent_instance_id"].(json.String));chain_id:=domain.Task_Chain_ID(result["chain_id"].(json.String))
	// Instance + conversation + task_chain "created" (as POST /task-chains emits).
	testing.expect_value(t,events.poll_revision(&g.event_bus,hint),u64(3))
	chain_hint,chain_attached:=events.poll_attach(&g.event_bus,view.owner,string(chain_id))
	if testing.expect(t,chain_attached) {
		mcp_chain_create_publish(&g.event_bus,view.owner,{},string(chain_id))
		testing.expect_value(t,events.poll_revision(&g.event_bus,chain_hint),u64(1))
		events.poll_detach(&g.event_bus,chain_hint)
	}
	chain,found,_:=iface.taskchain_get_chain(&g.repos.taskchains,chain_id)
	testing.expect(t,found && chain.publish_state==.Draft && chain.coordinator_agent_instance_id==id && strings.has_prefix(chain.title,"vault:v2:"))
	i,instance_found,_:=iface.agent_get_instance(&g.repos.agents,id)
	testing.expect(t,instance_found && i.agent_id=="agt_placement" && i.chain_id==string(chain_id) && id!="inst_placement_a" && id!="inst_placement_b")
	conv,conversation_found,_:=iface.content_get_conversation(&g.repos.content,i.conversation_id)
	// Native naming: the coordinator keeps "<agent name> #<n>" (instance and its
	// conversation), never the caller's chain title, which stays on the chain.
	testing.expectf(t,conversation_found && strings.has_prefix(i.display_name,"Synthetic placement #") && i.display_name!=chain.title && conv.title==i.display_name,"names: instance=%q conversation=%q",i.display_name,conv.title)
	first_n:=mcp_chain_test_counter(i.display_name)
	testing.expect(t,first_n>0)
	members,_:=iface.taskchain_list_members_by_chain(&g.repos.taskchains,chain_id,owner)
	testing.expect(t,len(members)==1 && members[0].role=="coordinator" && members[0].agent_id=="agt_placement" && members[0].agent_instance_id==id)
	testing.expect(t,len(sink.commands)==1 && !sink.inside_transaction && strings.contains(sink.commands[0].body_json,id))
	// Omitting provider settings reuses native defaults rather than imposing a
	// requirement for an existing/running coordinator instance.
	delete_key(&args,"provider");delete_key(&args,"provider_profile");delete_key(&args,"model")
	default_result:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"chains.create",args));if default_result==nil do return
	testing.expect(t,default_result["coordinator_agent_instance_id"].(json.String)!=json.String(id) && len(sink.commands)==2)
	// The per-agent counter advances for each fresh coordinator.
	second,second_found,_:=iface.agent_get_instance(&g.repos.agents,string(default_result["coordinator_agent_instance_id"].(json.String)))
	testing.expectf(t,second_found && mcp_chain_test_counter(second.display_name)==first_n+1,"counter: %q after #%d",second.display_name,first_n)
	// Ambiguous dispatch returns committed IDs; it must not roll back or retry.
	sink.fail=true
	response:=mcp_task_test_call(h,headers,"chains.create",args)
	testing.expectf(t,strings.contains(response.body,"coordinator_launch_unconfirmed") && strings.contains(response.body,"chain_id") && strings.contains(response.body,"coordinator_agent_instance_id"),"dispatch failure: %s",response.body)
	after,_=iface.taskchain_list_chains_by_owner(&g.repos.taskchains,owner)
	testing.expect(t,len(after)==len(before)+3 && len(sink.commands)==3 && !sink.inside_transaction)
	sink.fail=false
	mcp_chain_create_project_test(t,g,h,headers,view,args,&sink,len(before)+3)
	// Direct callback invocation cannot bypass argument validation or revocation.
	_,_,bad:=mcp_create_chain(g,raw,view,{},chain.title,chain.description)
	testing.expect_value(t,bad,"coordinator_agent_id_and_bridge_id_required")
	_=mcp.delegation_revoke(&g.mcp_delegation,view.owner,view.grant)
	_,_,revoked:=mcp_create_chain(g,raw,view,{coordinator_agent_id="agt_placement",bridge_id="brg_placement_a"},chain.title,chain.description)
	testing.expect(t,revoked!="" && len(sink.commands)==4)
}

// Project selection: unknown, foreign, archived and malformed project_id values
// fail before any chain, instance, conversation or launch exists; an owned
// active project is bound to the coordinator instance (and so to the chain's
// project grouping) and returned by create, chains.get and chains.list.
mcp_chain_create_project_test :: proc(t:^testing.T,g:^App_Graph,h:^http.MCP_Control_Handlers,headers:[]contracts.HTTP_Header,view:mcp.Access_View,base:json.Object,sink:^MCP_Runtime_Test_Sink,chains_before:int) {
	g.repos.projects=sqlite.new_project_repository(&g.sqlite_projects,&g.db);g.agents.projects=&g.repos.projects
	owner:=domain.User_ID(view.owner)
	_,saved,_:=iface.project_save(&g.repos.projects,{project_id="proj_mcp_owned",owner_user_id=owner,name="Owned",slug="owned",default_path="/srv/owned",state=.Active})
	_,foreign_saved,_:=iface.project_save(&g.repos.projects,{project_id="proj_mcp_foreign",owner_user_id="foreign_owner",name="Foreign",slug="foreign",default_path="/srv/foreign",state=.Active})
	_,archived_saved,_:=iface.project_save(&g.repos.projects,{project_id="proj_mcp_archived",owner_user_id=owner,name="Archived",slug="archived",default_path="/srv/archived",state=.Archived})
	if !testing.expect(t,saved && foreign_saved && archived_saved) do return
	args:=make(json.Object,context.temp_allocator)
	for k,v in base do args[k]=v
	commands_before:=len(sink.commands)
	instances_before,_:=iface.agent_list_instances_by_owner(&g.repos.agents,owner,100)
	// Unknown and foreign projects are indistinguishable.
	for pid,want in (map[string]string{"proj_mcp_missing"="project_not_found","proj_mcp_foreign"="project_not_found","proj_mcp_archived"="project_archived"}) {
		args["project_id"]=json.String(pid)
		response:=mcp_task_test_call(h,headers,"chains.create",args)
		testing.expectf(t,strings.contains(response.body,want) && strings.contains(response.body,"\"isError\":true"),"%s: %s",pid,response.body)
	}
	// Malformed values are schema errors, never lookups.
	for bad in ([]json.Value{json.String("chain_not_a_project"),json.String("proj_"),json.String(" proj_mcp_owned"),json.Integer(7)}) {
		args["project_id"]=bad
		response:=mcp_task_test_call(h,headers,"chains.create",args)
		testing.expectf(t,strings.contains(response.body,"-32602"),"malformed project_id: %s",response.body)
	}
	chains_after,_:=iface.taskchain_list_chains_by_owner(&g.repos.taskchains,owner)
	instances_after,_:=iface.agent_list_instances_by_owner(&g.repos.agents,owner,100)
	testing.expect(t,len(chains_after)==chains_before && len(instances_after)==len(instances_before) && len(sink.commands)==commands_before)
	// Owned active project: bound atomically with the chain and coordinator.
	args["project_id"]=json.String("proj_mcp_owned")
	result:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"chains.create",args));if result==nil do return
	testing.expect_value(t,result["project_id"].(json.String),json.String("proj_mcp_owned"))
	chain_id:=string(result["chain_id"].(json.String));inst_id:=string(result["coordinator_agent_instance_id"].(json.String))
	i,found,_:=iface.agent_get_instance(&g.repos.agents,inst_id)
	testing.expect(t,found && i.project_id=="proj_mcp_owned" && i.project_path=="/srv/owned" && i.chain_id==chain_id)
	conv,conv_found,_:=iface.content_get_conversation(&g.repos.content,i.conversation_id)
	testing.expect(t,conv_found && conv.project_id=="proj_mcp_owned" && strings.has_prefix(i.display_name,"Synthetic placement #") && conv.title==i.display_name)
	testing.expect(t,len(sink.commands)==commands_before+1 && strings.contains(sink.commands[len(sink.commands)-1].body_json,"/srv/owned"))
	// Read visibility through the same projection chains.get/list relay.
	got,code:=mcp.control_read(&h.control,view.owner,"chains.get",{chain_id=chain_id})
	testing.expectf(t,code=="" && mcp_chain_test_str(got.chain,"project_id")=="proj_mcp_owned","chains.get: %s %v",code,got.chain["project_id"])
	listed,lcode:=mcp.control_read(&h.control,view.owner,"chains.list",{limit=100})
	testing.expect_value(t,lcode,"")
	with_project,without_project:=0,0
	for row in listed.chains {
		if mcp_chain_test_str(row,"chain_id")==chain_id && mcp_chain_test_str(row,"project_id")=="proj_mcp_owned" do with_project+=1
		if p,present:=row["project_id"].(json.String);present && p=="" do without_project+=1
	}
	// Chains created without project_id keep an empty project.
	testing.expectf(t,with_project==1 && without_project>=3,"list: with=%d without=%d",with_project,without_project)
	fields,_:=vault.control_record_fields(.Chain)
	allowed:=false;for f in fields do if f=="project_id" do allowed=true
	testing.expect(t,allowed)
}
mcp_chain_test_str :: proc(row:json.Object,key:string)->string {s,_:=row[key].(json.String);return string(s)}
mcp_chain_test_counter :: proc(name:string)->int {
	hash:=strings.last_index(name," #");if hash<0 do return -1
	n:=0
	for c in name[hash+2:] {if c<'0' || c>'9' do return -1;n=n*10+int(c-'0')}
	return n
}
