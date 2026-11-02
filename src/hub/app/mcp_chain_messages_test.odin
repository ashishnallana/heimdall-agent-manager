#+feature dynamic-literals
package app

import "core:encoding/json"
import "core:strings"
import "core:testing"
import "core:thread"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import mcp "odin_test:hub/service/mcp"
import content "odin_test:hub/service/content"
import project "odin_test:hub/service/project"
import http "odin_test:hub/transport/http"
import vault "odin_test:lib/vault"

@(test)
test_mcp_chain_messages_hosted_user_delivery_atomic_replay :: proc(t:^testing.T) {
	mcp_task_test_fixture(t,#load("../../../tests/fixtures/mcp_messages_v2.json",string),false,false,false,false,true)
}
@(test)
test_mcp_chain_messages_device_user_delivery_atomic_replay :: proc(t:^testing.T) {
	mcp_task_test_fixture(t,#load("../../../tests/fixtures/mcp_messages_v2.json",string),false,false,false,false,true,true)
}

MCP_Message_Test_Worker :: struct {kr:vault.Vault_Keyring,device,owner,resource:string,now:i64,verified:int}
MCP_Message_Test_Race :: struct {g:^App_Graph,raw,body:string,view:mcp.Access_View,id:[256]byte,ok:bool}
mcp_message_test_race :: proc(ctx:rawptr) {
	p:=(^MCP_Message_Test_Race)(ctx)
	context.allocator=context.temp_allocator
	defer free_all(context.temp_allocator)
	result,err:=mcp_send_chain_message(p.g,p.raw,p.view,"chain_comment","message_concurrent","stable_digest",p.body)
	output:MCP_Message_Result
	p.ok=err=="" && json.unmarshal_string(result,&output,.JSON,context.temp_allocator)==nil && output.message_id!="" && len(output.message_id)<=len(p.id)
	if p.ok do copy(p.id[:],output.message_id)
}
mcp_message_test_transform :: proc(ctx:rawptr,job:vault.Control_Job)->(string,bool) {
	p:=(^MCP_Message_Test_Worker)(ctx)
	if !vault.control_job_verify(job,p.owner,p.resource,p.device,&p.kr,p.now) do return "",false
	p.verified+=1
	return vault.control_job_transform(job,&p.kr)
}

mcp_chain_message_test :: proc(t:^testing.T,g:^App_Graph,h:^http.MCP_Control_Handlers,headers:[]contracts.HTTP_Header,view:mcp.Access_View,raw:string) {
	owner:=domain.User_ID(view.owner);now:=mcp_task_test_now(nil)
	g.repos.agents=sqlite.new_agent_repository(&g.sqlite_agents,&g.db)
	g.repos.bridges=sqlite.new_bridge_repository(&g.sqlite_bridges,&g.db)
	g.repos.content=sqlite.new_content_repository(&g.sqlite_content,&g.db)
	g.provider_repo=sqlite.new_provider_repository(&g.sqlite_providers,&g.db)
	g.agents.agents=&g.repos.agents;g.agents.bridges=&g.repos.bridges;g.agents.providers=&g.provider_repo;g.agents.clock=&g.clock;g.agents.ids=&g.ids;g.agents.taskchains=&g.repos.taskchains
	g.agents.bridge_runtime_registry=&g.bridge_runtime_registry
	defer project.bridge_runtime_registry_destroy(&g.bridge_runtime_registry)
	sink:=MCP_Runtime_Test_Sink{g=g};defer mcp_runtime_test_sink_destroy(&sink)
	g.agents.bridge_command_sink={ctx=&sink,send_runtime_command=mcp_runtime_test_send}
	g.content=content.new_content_service_with_runtime(&g.repos.content,&g.repos.agents,&g.repos.bridges,nil,&g.repos.taskchains,g.agents.bridge_command_sink,&g.clock,&g.ids)
	g.content.title_nudge_cooldown_seconds=3600
	attention_probe:=MCP_Task_Attention_Probe{factory=&g.uow_factory}
	attention:=contracts.Attention_Notifier{ctx=&attention_probe,notify=mcp_task_attention_probe};g.content.attention=&attention
	g.content_handlers={content=&g.content,agents=&g.agents,event_bus=&g.event_bus}
	_,_,_=iface.agent_save(&g.repos.agents,{agent_id="agt_message",owner_user_id=owner,name="Synthetic coordinator",slug="synthetic-coordinator",template_id=domain.TEMPLATE_EMPTY_ID,state=.Active})
	_,_,_=iface.bridge_save_bridge(&g.repos.bridges,{bridge_id="brg_message",owner_user_id=owner,label="Synthetic",status=.Online})
	_,_,_=project.bridge_runtime_registry_accept_live(&g.bridge_runtime_registry,"brg_message",false,"",view.owner)
	iface.bridge_provider_status_upsert(&g.provider_repo,{bridge_id="brg_message",provider="codex",state="present"})
	iface.bridge_provider_setting_upsert(&g.provider_repo,{bridge_id="brg_message",provider="codex",enabled=true})
	entry,_,_:=iface.provider_catalog_get(&g.provider_repo,"codex");model:=entry.models[0].model_id
	for pair in ([]struct {instance,chat:string}{{"inst_message_a","chat_message_a"},{"inst_message_b","chat_message_b"}}) {
		_,ok,_:=iface.agent_save_instance(&g.repos.agents,{agent_instance_id=pair.instance,owner_user_id=owner,agent_id="agt_message",bridge_id="brg_message",provider="codex",model=model,kind="agent",runtime_status="running",conversation_id=pair.chat,chain_id="chain_another",created_at=now,updated_at=now})
		testing.expect(t,ok)
		_,ok,_=iface.content_save_conversation(&g.repos.content,{conversation_id=pair.chat,owner_user_id=owner,agent_id="agt_message",agent_instance_id=pair.instance,title="Synthetic",created_at=now,updated_at=now,last_title_nudge_at=now})
		testing.expect(t,ok)
	}
	chain,_,_:=iface.taskchain_get_chain(&g.repos.taskchains,"chain_comment");chain.coordinator_agent_instance_id="inst_message_b";_,_,_=iface.taskchain_save_chain(&g.repos.taskchains,chain)
	_,_,_=iface.taskchain_save_member(&g.repos.taskchains,{chain_id=chain.chain_id,owner_user_id=owner,agent_instance_id="inst_message_a",agent_id="agt_message",role="coordinator",created_at=now})
	vector:struct {worker_keyring_hex:string,now_ms:i64,directory:struct {root_device_id:string}}
	json.unmarshal_string(#load("../../../tests/fixtures/mcp_messages_v2.json",string),&vector,.JSON,context.temp_allocator)
	bytes:=make([]byte,len(vector.worker_keyring_hex)/2,context.temp_allocator);testing.expect(t,vault.hex_decode_into(bytes,vector.worker_keyring_hex))
	kr,valid:=vault.keyring_parse(bytes,view.owner);if !testing.expect(t,valid) do return
	defer vault.keyring_wipe(&kr)
	worker:=MCP_Message_Test_Worker{kr=kr,device=vector.directory.root_device_id,owner=view.owner,resource=g.mcp_delegation.resource,now=vector.now_ms}
	if view.mode=="device" {h.bridge_ctx=&worker;h.bridge_transform=mcp_message_test_transform}
	args:=json.Object{"chain_id"=json.String("chain_comment"),"request_id"=json.String("message_once"),"body"=json.String("Private coordinator message")}
	_,_,_=iface.user_save(&g.repos.users,{user_id="foreign_message_owner",name="Foreign",status=.Active})
	_,_,_=iface.taskchain_save_chain(&g.repos.taskchains,{chain_id="chain_message_foreign",owner_user_id="foreign_message_owner",title="Foreign",kind="mixed_work",status=.Active})
	for target in ([]string{"chain_missing","chain_message_foreign"}) {
		args["chain_id"]=json.String(target)
		testing.expect(t,strings.contains(mcp_task_test_call(h,headers,"chains.message",args).body,"not_found"))
	}
	args["chain_id"]=json.String("chain_comment")
	_,_,_=iface.taskchain_save_member(&g.repos.taskchains,{chain_id=chain.chain_id,owner_user_id=owner,agent_instance_id="inst_message_a",agent_id="agt_message",role="worker",created_at=now})
	testing.expect(t,strings.contains(mcp_task_test_call(h,headers,"chains.message",args).body,"coordinator_missing"),"stale mirror must not be a fallback")
	_,_,_=iface.taskchain_save_member(&g.repos.taskchains,{chain_id=chain.chain_id,owner_user_id=owner,agent_instance_id="inst_message_a",agent_id="agt_message",role="coordinator",created_at=now})
	foreign_repo:=g.repos.content
    foreign_repo.get_conversation=proc(ctx:rawptr,id:string)->(domain.Chat_Conversation,bool,domain.Domain_Error) {
      return {conversation_id="foreign_chat",owner_user_id="foreign_message_owner",agent_instance_id="inst_message_a"},true,{}
    }
    foreign_repo.list_conversations=proc(ctx:rawptr,owner:domain.User_ID,limit:int,cursor:string)->([]domain.Chat_Conversation,domain.Domain_Error) {
      rows:=make([]domain.Chat_Conversation,1,context.temp_allocator)
      rows[0]={conversation_id="foreign_chat",owner_user_id="foreign_message_owner",agent_instance_id="inst_message_a"}
      return rows,{}
    }
    g.content.content=&foreign_repo
    testing.expect(t,strings.contains(mcp_task_test_call(h,headers,"chains.message",args).body,"coordinator_unavailable"))
    g.content.content=&g.repos.content
	broken_repo:=g.repos.taskchains
	broken_repo.list_members_by_chain=proc(ctx:rawptr,id:domain.Task_Chain_ID,owner:domain.User_ID)->([]domain.Task_Chain_Member,domain.Domain_Error) {return nil,domain.domain_error(.Internal_Error,"synthetic canonical read failure")}
	g.taskchains.repo=&broken_repo
	testing.expect(t,strings.contains(mcp_task_test_call(h,headers,"chains.message",args).body,"request_failed"))
	g.taskchains.repo=&g.repos.taskchains
	original_agents:=g.repos.agents
	g.repos.agents.get_instance=proc(ctx:rawptr,id:string)->(domain.Agent_Instance,bool,domain.Domain_Error) {return {agent_instance_id=id,owner_user_id="foreign_message_owner",kind="agent"},true,{}}
	testing.expect(t,strings.contains(mcp_task_test_call(h,headers,"chains.message",args).body,"coordinator_unavailable"))
	g.repos.agents=original_agents
	testing.expect(t,len(sink.commands)==0 && attention_probe.notices==0)
	first:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"chains.message",args));if first==nil do return
	testing.expect(t,first["coordinator_agent_instance_id"].(json.String)=="inst_message_a" && first["conversation_id"].(json.String)=="chat_message_a" && first["status"].(json.String)=="accepted")
	rows,_:=iface.content_list_messages(&g.repos.content,"chat_message_a",owner,100,"")
	if !testing.expect(t,len(rows)==1) do return
	testing.expect(t,rows[0].direction=="user_to_agent" && rows[0].message_type=="text" && strings.has_prefix(rows[0].body,"vault:v2:") && !strings.contains(rows[0].metadata_json,"Private"))
	opened,open_status:=vault.open(rows[0].body,&kr,context.temp_allocator)
	testing.expect(t,open_status==.Ok && opened=="Private coordinator message")
	c,_,_:=iface.content_get_conversation(&g.repos.content,"chat_message_a");testing.expect(t,c.last_message_preview==rows[0].body)
	testing.expect(t,len(sink.commands)==1 && strings.contains(sink.commands[0].body_json,"notify_agent_message") && strings.contains(sink.commands[0].body_json,`"sender":"user"`) && !sink.inside_transaction && attention_probe.notices==1 && !attention_probe.inside_transaction)
	retry:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"chains.message",args));if retry==nil do return
	testing.expect(t,retry["message_id"].(json.String)==first["message_id"].(json.String) && len(sink.commands)==1 && attention_probe.notices==1)
	args["body"]=json.String("Changed content")
	testing.expect(t,strings.contains(mcp_task_test_call(h,headers,"chains.message",args).body,"idempotency_conflict"))
	args["body"]=json.String("Private coordinator message")
	// Reassignment does not redirect an already committed replay.
	_,_,_=iface.taskchain_save_member(&g.repos.taskchains,{chain_id=chain.chain_id,owner_user_id=owner,agent_instance_id="inst_message_a",agent_id="agt_message",role="worker",created_at=now})
	_,_,_=iface.taskchain_save_member(&g.repos.taskchains,{chain_id=chain.chain_id,owner_user_id=owner,agent_instance_id="inst_message_b",agent_id="agt_message",role="coordinator",created_at=now})
	retry=mcp_task_test_output(t,mcp_task_test_call(h,headers,"chains.message",args));if retry==nil do return
	testing.expect(t,retry["message_id"].(json.String)==first["message_id"].(json.String) && retry["coordinator_agent_instance_id"].(json.String)==first["coordinator_agent_instance_id"].(json.String) && len(sink.commands)==1)
	// Receipt insertion failure must roll back message and conversation preview.
	testing.expect(t,sqlite.exec(&g.db,"CREATE TRIGGER message_receipt_fail BEFORE INSERT ON mcp_mutation_receipts WHEN NEW.request_id='message_fail' BEGIN SELECT RAISE(ABORT,'synthetic'); END;"))
	args["request_id"]=json.String("message_fail")
	testing.expect(t,strings.contains(mcp_task_test_call(h,headers,"chains.message",args).body,"request_failed"))
	other,_:=iface.content_list_messages(&g.repos.content,"chat_message_b",owner,100,"")
	testing.expect(t,len(other)==0 && len(sink.commands)==1 && attention_probe.notices==1)
	sqlite.exec(&g.db,"DROP TRIGGER message_receipt_fail;")
	// Exercise a real failed COMMIT, after message and receipt writes succeeded.
	testing.expect(t,sqlite.exec(&g.db,"PRAGMA foreign_keys=ON; CREATE TABLE message_commit_parent(id INTEGER PRIMARY KEY); CREATE TABLE message_commit_child(id INTEGER REFERENCES message_commit_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER message_fail_commit AFTER INSERT ON mcp_mutation_receipts WHEN NEW.request_id='message_commit' BEGIN INSERT INTO message_commit_child(id) VALUES(999); END;"))
	args["request_id"]=json.String("message_commit")
	testing.expect(t,strings.contains(mcp_task_test_call(h,headers,"chains.message",args).body,"request_failed"))
	other,_=iface.content_list_messages(&g.repos.content,"chat_message_b",owner,100,"")
	testing.expect(t,len(other)==0 && len(sink.commands)==1 && attention_probe.notices==1)
	testing.expect(t,sqlite.exec(&g.db,"DROP TRIGGER message_fail_commit; DROP TABLE message_commit_child; DROP TABLE message_commit_parent;"))
	// A stopped coordinator uses the native restart before the user notice.
	inst,_,_:=iface.agent_get_instance(&g.repos.agents,"inst_message_b");inst.runtime_status="stopped";_,_,_=iface.agent_save_instance(&g.repos.agents,inst)
	args["request_id"]=json.String("message_stopped")
	stopped:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"chains.message",args));if stopped==nil do return
	testing.expect(t,stopped["status"].(json.String)=="accepted" && len(sink.commands)>=3 && !sink.inside_transaction)
	// Runtime send failure remains accepted with saved IDs and no duplicate retry.
	sink.fail=true;args["request_id"]=json.String("message_offline")
	offline:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"chains.message",args));if offline==nil do return
	testing.expect(t,offline["delivery_warning"].(json.String)=="bridge_offline" && offline["message_id"]!=nil)
	count:=len(sink.commands);mcp_task_test_output(t,mcp_task_test_call(h,headers,"chains.message",args));testing.expect(t,len(sink.commands)==count)
	if view.mode=="device" do testing.expect(t,worker.verified>0)
	// Concurrent identical retries share the native UOW and persist/deliver once.
	sink.fail=false
	races:=[2]MCP_Message_Test_Race{{g=g,raw=raw,body=rows[0].body,view=view},{g=g,raw=raw,body=rows[0].body,view=view}}
	threads:=[2]^thread.Thread{}
	for &race,j in races {threads[j]=thread.create_and_start_with_data(&race,mcp_message_test_race)}
	for th in threads {thread.join(th);thread.destroy(th)}
	testing.expect(t,races[0].ok && races[1].ok && races[0].id==races[1].id && len(sink.commands)==count+1)
	count=len(sink.commands)
	// Reauthorization inside the transaction rejects stale authority and envelopes.
	_,bad_envelope:=mcp_send_chain_message(g,raw,view,"chain_comment","wrong_epoch","digest","plaintext forbidden")
	testing.expect_value(t,bad_envelope,"decryption_unavailable")
	_=mcp.delegation_revoke(&g.mcp_delegation,view.owner,view.grant)
	_,revoked:=mcp_send_chain_message(g,raw,view,"chain_comment","revoked","digest",rows[0].body)
	testing.expect(t,revoked!="" && len(sink.commands)==count)
}
