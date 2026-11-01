#+feature dynamic-literals
package app

import "core:encoding/json"
import "core:testing"
import "core:strings"
import "core:thread"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import platform "odin_test:hub/platform"
import mcp "odin_test:hub/service/mcp"
import auth "odin_test:hub/service/auth"
import vault "odin_test:lib/vault"
import tc "odin_test:hub/service/taskchain"
import tv2 "odin_test:hub/service/taskv2"
import vd "odin_test:hub/service/vault_directory"
import http "odin_test:hub/transport/http"
import contracts "odin_test:contracts"

MCP_Task_Test_Vector :: struct {
	now_ms:i64,
	request:struct {owner,client,redirect,resource,scope,grant,family:string,revision,expires_ms:i64},
	directory:struct {version,current_epoch:i64,root_device_id,head_hash:string,devices:[]struct {device_id,kind,sign_alg,wrap_alg,sign_public_key,ecdh_public_key:string},log:[]struct {seq:i64,statement:string,signature:struct {alg,sig:string}}},
	hosted:mcp.Consent_Input,
}
mcp_task_test_seed :: proc(tx:iface.MCP_Transaction,ctx:rawptr)->domain.Domain_Error {
	v:=(^MCP_Task_Test_Vector)(ctx)
	if err:=tx.put(tx.ctx,{kind="client",id=v.request.client,redirect=v.request.redirect});err.code!=.None do return err
	return tx.put(tx.ctx,{kind="pending",id=auth.sha256_hex(v.hosted.request),owner=v.request.owner,client=v.request.client,redirect=v.request.redirect,resource=v.request.resource,scope=v.request.scope,grant=v.request.grant,family=v.request.family,revision=1,created_ms=v.now_ms,expires_ms=v.request.expires_ms,challenge=auth.pkce_challenge_s256("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")})
}
mcp_task_test_now :: proc(ctx:rawptr)->string {return "2026-10-31T07:00:00Z"}

mcp_task_test_call :: proc(h:^http.MCP_Control_Handlers,headers:[]contracts.HTTP_Header,tool:string,args:json.Object)->http.Response {
	encoded,_:=json.marshal(struct {jsonrpc:string,id:int,method:string,params:struct {name:string,arguments:json.Object}}{"2.0",1,"tools/call",{tool,args}},allocator=context.temp_allocator)
	return http.mcp_control_handler(h,{method="POST",path="/api/v1/mcp",headers=headers,body=string(encoded)})
}
mcp_task_test_output :: proc(t:^testing.T,response:http.Response)->json.Object {
	outer:struct {result:struct {content:[]struct {text:string},isError:bool}}
	if !testing.expectf(t,json.unmarshal_string(response.body,&outer,.JSON,context.temp_allocator)==nil && !outer.result.isError && len(outer.result.content)==1,"MCP result: %s",response.body) do return nil
	value,err:=json.parse_string(outer.result.content[0].text,parse_integers=true,allocator=context.temp_allocator)
	obj,typed:=value.(json.Object)
	testing.expect(t,err==nil && typed)
	return obj
}

MCP_Task_Comment_Race :: struct {graph:^App_Graph,raw,body:string,view:mcp.Access_View,id:[256]byte,ok:bool}
MCP_Task_Attention_Probe :: struct {factory:^iface.Unit_Of_Work_Factory,notices:int,inside_transaction:bool}
mcp_task_attention_probe :: proc(ctx:rawptr,owner,kind,id:string) {
	p:=(^MCP_Task_Attention_Probe)(ctx)
	uow,ok,_:=iface.unit_of_work_begin(p.factory)
	if !ok {p.inside_transaction=true;return}
	p.inside_transaction=p.inside_transaction || uow.nested
	p.notices+=1
	iface.unit_of_work_rollback(&uow)
}
mcp_task_comment_race :: proc(job:^MCP_Task_Comment_Race) {
	context.allocator=context.temp_allocator
	defer free_all(context.temp_allocator)
	id,err:=mcp_comment_task(job.graph,job.raw,job.view,"task_comment","concurrent_retry","concurrent_digest",job.body)
	job.ok=err=="" && len(id)>0 && len(id)<=len(job.id)
	if job.ok do copy(job.id[:],id)
}
mcp_task_revoke_before_write :: proc(ctx:rawptr,raw:string,view:mcp.Access_View,command:mcp.Control_Task_Command)->(string,string) {
	g:=(^App_Graph)(ctx)
	_ = mcp.delegation_revoke(&g.mcp_delegation,view.owner,view.grant)
	return mcp_mutate_task(g,raw,view,command)
}

@(test)
test_mcp_task_comment_native_atomic_retry_and_revocation :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	g:=new(App_Graph,context.temp_allocator)
	v:MCP_Task_Test_Vector
	if !testing.expect(t,json.unmarshal_string(#load("../../../tests/fixtures/mcp_tasks_v2.json",string),&v,.JSON,context.temp_allocator)==nil) do return
	repo,rerr:=sqlite.open_mcp_repository(&g.mcp_repository_impl,":memory:")
	if !testing.expect(t,rerr.code==.None) do return
	defer sqlite.close(&g.mcp_repository_impl.conn)
	g.mcp_repository=repo;g.db=g.mcp_repository_impl.conn
	upgraded,uerr:=sqlite.run_migrations(&g.db)
	if !testing.expect(t,upgraded && uerr.code==.None) do return
	g.clock={now=mcp_task_test_now};g.ids=platform.real_id_generator()
	ui:sqlite.User_Repo_SQLite
	ur:=sqlite.new_user_repository(&ui,&g.db)
	g.repos.users=ur
	_,saved,_:=iface.user_save(&ur,{user_id=domain.User_ID(v.request.owner),status=.Active,name="Synthetic MCP task test"})
	testing.expect(t,saved)
	vi:sqlite.Vault_Directory_Repo_SQLite
	vr:=sqlite.new_vault_directory_repository(&vi,&g.db)
	root:=v.directory.devices[0];log:=v.directory.log[0]
	sig,_:=vault.signature_text_from_parts(log.signature.alg,log.signature.sig,context.temp_allocator)
	now:=mcp_task_test_now(nil)
	genesis:=domain.Vault_Genesis{
		directory={user_id=v.request.owner,version=1,current_epoch=1,root_device_id=root.device_id,head_hash=v.directory.head_hash,genesis_statement=log.statement,genesis_signature=sig,created_at=now,updated_at=now},
		device={user_id=v.request.owner,device_id=root.device_id,kind=root.kind,sign_alg=root.sign_alg,wrap_alg=root.wrap_alg,sign_public_key=root.sign_public_key,ecdh_public_key=root.ecdh_public_key,status=.Approved,created_at=now,approved_at=now},
		epoch={user_id=v.request.owner,epoch=1,statement=log.statement,signature=sig,created_at=now},
		log={user_id=v.request.owner,seq=1,statement=log.statement,signature=sig,entry_hash=v.directory.head_hash,created_at=now},
		wrap={user_id=v.request.owner,device_id=root.device_id,directory_version=1,current_epoch=1,wrap_json="{}",updated_at=now},
	}
	if !testing.expect(t,iface.vault_create_genesis(&vr,genesis).code==.None) do return
	directory:=vd.Service{repo=&vr,clock=&g.clock}
	authority:=MCP_Task_Authority{conn=&g.db,directory=&directory}
	keys:[1]mcp.Envelope_Key;keys[0].id="synthetic";keys[0].bytes[0]=7
	g.mcp_delegation={repo=&g.mcp_repository,keys=keys[:],clock=&g.clock,issuer="https://hub.example",resource=v.request.resource,authority=mcp_task_authority,authority_ctx=&authority}
	testing.expect(t,iface.mcp_transaction(&g.mcp_repository,mcp_task_test_seed,&v).code==.None)
	code,_,_,cerr:=mcp.delegation_consent(&g.mcp_delegation,&directory,v.request.owner,root.device_id,v.hosted,v.now_ms)
	if !testing.expectf(t,cerr.code==.None,"consent: %s",cerr.message) do return
	tokens:=mcp.delegation_redeem(&g.mcp_delegation,code,"code",v.request.client,v.request.redirect,"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",v.now_ms)
	var_tokens:mcp.Tokens
	if !testing.expect(t,tokens.error=="" && json.unmarshal_string(tokens.response,&var_tokens,.JSON,context.temp_allocator)==nil) do return
	view,live:=mcp.access_view(&g.mcp_delegation,&directory,var_tokens.access_token)
	if !testing.expect(t,live) do return
	g.repos.taskchains=sqlite.new_taskchain_repository(&g.sqlite_taskchains,&g.db)
	g.taskchains=tc.new_taskchain_service(&g.repos.taskchains,nil,&g.clock,&g.ids)
	g.uow_factory=sqlite.new_unit_of_work_factory(&g.sqlite_uow_factory,&g.db,&g.repos)
	g.taskchains.uow_factory=&g.uow_factory
	g.task_engine=tv2.new_service(&g.repos.taskchains,nil,nil,&g.clock,&g.ids)
	g.task_engine.uow_factory=&g.uow_factory;g.taskchains.engine=&g.task_engine
	attention_probe:=MCP_Task_Attention_Probe{factory=&g.uow_factory}
	attention:=contracts.Attention_Notifier{ctx=&attention_probe,notify=mcp_task_attention_probe}
	g.taskchains.attention=&attention
	_,cok,_:=iface.taskchain_save_chain(&g.repos.taskchains,{chain_id="chain_comment",owner_user_id=domain.User_ID(v.request.owner),title="Synthetic",kind="mixed_work",status=.Active,created_at=now,updated_at=now})
	_,tok,_:=iface.taskchain_save_task(&g.repos.taskchains,{task_id="task_comment",chain_id="chain_comment",owner_user_id=domain.User_ID(v.request.owner),title="Synthetic",publish_state=.Published,state=.In_Review,brief_json="{}",created_at=now,updated_at=now})
	if !testing.expect(t,cok && tok) do return
	op:=mcp.Control_Transform{tool="tasks.comment",body="private synthetic comment"}
	sealed:=mcp.hosted_with_access(&g.mcp_delegation,&directory,var_tokens.access_token,view.client,mcp.control_hosted_transform,&op)
	input:struct {body:string}
	if !testing.expect(t,sealed.error=="" && json.unmarshal_string(sealed.response,&input,.JSON,context.temp_allocator)==nil) do return
	first,first_err:=mcp_comment_task(g,var_tokens.access_token,view,"task_comment","retry_a","digest_a",input.body)
	testing.expectf(t,first_err=="" && first!="","comment: %s",first_err)
	testing.expect(t,attention_probe.notices==1 && !attention_probe.inside_transaction)
	second,second_err:=mcp_comment_task(g,var_tokens.access_token,view,"task_comment","retry_a","digest_a",input.body)
	testing.expect(t,second_err=="" && second==first)
	_,conflict:=mcp_comment_task(g,var_tokens.access_token,view,"task_comment","retry_a","different",input.body)
	testing.expect(t,conflict=="idempotency_conflict")
	testing.expect(t,sqlite.exec(&g.db,"CREATE TRIGGER fail_comment_receipt BEFORE INSERT ON mcp_mutation_receipts WHEN NEW.request_id='fail_comment_receipt' BEGIN SELECT RAISE(ABORT,'synthetic receipt failure'); END;"))
	_,failed_receipt:=mcp_comment_task(g,var_tokens.access_token,view,"task_comment","fail_comment_receipt","digest_failed",input.body)
	testing.expect(t,failed_receipt=="request_failed")
	testing.expect(t,attention_probe.notices==1 && !attention_probe.inside_transaction,"failed mutation must not publish an attention refresh")
	testing.expect(t,sqlite.exec(&g.db,"DROP TRIGGER fail_comment_receipt;"))
	rows,_:=iface.taskchain_list_comments_by_task(&g.repos.taskchains,"task_comment",domain.User_ID(v.request.owner))
	testing.expect(t,len(rows)==1 && rows[0].body==input.body && !strings.contains(rows[0].body,"private synthetic comment"))
	events,_:=iface.taskchain_list_events_by_task(&g.repos.taskchains,"task_comment",domain.User_ID(v.request.owner))
	testing.expect(t,len(events)==1 && events[0].kind=="comment")
	_,missing:=mcp_comment_task(g,var_tokens.access_token,view,"task_missing","retry_b","digest_b",input.body)
	testing.expect(t,missing=="not_found")
	_,_,receipt,_:=sqlite.mcp_receipt_get(&g.db,view.owner,view.grant,"tasks.comment","retry_b")
	testing.expect(t,!receipt)
	delegation:=http.MCP_Delegation_Handlers{service=&g.mcp_delegation,directory=&directory,grant_directory=&directory,origin=g.mcp_delegation.issuer}
	h:=http.MCP_Control_Handlers{delegation=&delegation,control={chains=&g.taskchains},create_ctx=g,comment=mcp_comment_task,mutate_task=mcp_mutate_task}
	headers:=[]contracts.HTTP_Header{{"Authorization",strings.concatenate({"Bearer ",var_tokens.access_token},context.temp_allocator)},{"Content-Type","application/json"}}
	call:=`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"tasks.comment","arguments":{"task_id":"task_comment","request_id":"http_retry","body":"HTTP private comment"}}}`
	response:=http.mcp_control_handler(&h,{method="POST",path="/api/v1/mcp",headers=headers,body=strings.clone(call,context.temp_allocator)})
	retry:=http.mcp_control_handler(&h,{method="POST",path="/api/v1/mcp",headers=headers,body=strings.clone(call,context.temp_allocator)})
	testing.expectf(t,response.status==200 && response.sensitive && strings.contains(response.body,"comment_id") && response.body==retry.body,"HTTP comment/retry: %s",response.body)
	get:=http.mcp_control_handler(&h,{method="POST",path="/api/v1/mcp",headers=headers,body=strings.clone(`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"tasks.get","arguments":{"task_id":"task_comment"}}}`,context.temp_allocator)})
	testing.expectf(t,get.status==200 && get.sensitive && strings.contains(get.body,"HTTP private comment") && !strings.contains(get.body,"vault:v2:"),"task get: %s",get.body)
	rows,_=iface.taskchain_list_comments_by_task(&g.repos.taskchains,"task_comment",domain.User_ID(v.request.owner))
	testing.expect(t,len(rows)==2)
	mcp_task_test_mutations(t,g,&h,headers,view)
	mcp_task_test_placement(t,g,&h,headers,view)
	jobs:[4]MCP_Task_Comment_Race
	threads:[4]^thread.Thread
	for i in 0..<len(jobs) {
		jobs[i]={graph=g,raw=var_tokens.access_token,body=input.body,view=view}
		threads[i]=thread.create_and_start_with_poly_data(&jobs[i],mcp_task_comment_race)
	}
	for th in threads {thread.join(th);thread.destroy(th)}
	for job in jobs do testing.expect(t,job.ok && job.id==jobs[0].id)
	rows,_=iface.taskchain_list_comments_by_task(&g.repos.taskchains,"task_comment",domain.User_ID(v.request.owner))
	testing.expect(t,len(rows)==3)
	h.mutate_task=mcp_task_revoke_before_write
	revocation_race:=mcp_task_test_call(&h,headers,"tasks.create",json.Object{"chain_id"=json.String("chain_mutation"),"request_id"=json.String("revoked_before_commit"),"title"=json.String("Never commit"),"goal"=json.String("Never commit"),"acceptance"=json.Array{json.String("Never commit")}})
	testing.expect(t,revocation_race.status==401)
	_,_,revoked_receipt,_:=sqlite.mcp_receipt_get(&g.db,view.owner,view.grant,"tasks.create","revoked_before_commit")
	testing.expect(t,!revoked_receipt)
	testing.expect(t,mcp.delegation_revoke(&g.mcp_delegation,view.owner,view.grant).code==.None)
	_,revoked:=mcp_comment_task(g,var_tokens.access_token,view,"task_comment","retry_a","digest_a",input.body)
	testing.expect(t,revoked=="invalid_token")
}

// This is a real repository/engine lease match on synthetic machines. The
// separate acceptance task still must prove execution on actual bridges.
mcp_task_test_placement :: proc(t:^testing.T,g:^App_Graph,h:^http.MCP_Control_Handlers,headers:[]contracts.HTTP_Header,view:mcp.Access_View) {
	now:=mcp_task_test_now(nil)
	g.repos.agents=sqlite.new_agent_repository(&g.sqlite_agents,&g.db)
	g.repos.bridges=sqlite.new_bridge_repository(&g.sqlite_bridges,&g.db)
	g.provider_repo=sqlite.new_provider_repository(&g.sqlite_providers,&g.db)
	g.agents.agents=&g.repos.agents;g.agents.bridges=&g.repos.bridges;g.agents.providers=&g.provider_repo
	g.taskchains.agents=&g.repos.agents;g.taskchains.agent_service=&g.agents
	g.task_engine.agents=&g.repos.agents;g.task_engine.bridges=&g.repos.bridges
	owner:=domain.User_ID(view.owner)
	_,ok,_:=iface.agent_save(&g.repos.agents,{agent_id="agt_placement",owner_user_id=owner,name="Synthetic placement",slug="synthetic-placement",template_id=domain.TEMPLATE_EMPTY_ID,state=.Active,created_at=now,updated_at=now})
	if !testing.expect(t,ok) do return
	entry,known,err:=iface.provider_catalog_get(&g.provider_repo,"codex")
	if !testing.expect(t,known && err.code==.None && len(entry.models)>0) do return
	defer domain.provider_catalog_entry_destroy(entry)
	model:=entry.models[0].model_id
	for bridge in ([]string{"brg_placement_a","brg_placement_b","brg_placement_offline"}) {
		status:=domain.Bridge_Status.Online;if bridge=="brg_placement_offline" do status=.Offline
		_,saved,_:=iface.bridge_save_bridge(&g.repos.bridges,{bridge_id=bridge,owner_user_id=owner,label=bridge,status=status,created_at=now,updated_at=now})
		testing.expect(t,saved)
		status_ok,_:=iface.bridge_provider_status_upsert(&g.provider_repo,{bridge_id=bridge,provider="codex",state="present",checked_at=now})
		setting_ok,_:=iface.bridge_provider_setting_upsert(&g.provider_repo,{bridge_id=bridge,provider="codex",enabled=true,updated_at=now})
		testing.expect(t,status_ok && setting_ok)
	}
	_,saved,_:=iface.taskchain_save_chain(&g.repos.taskchains,{chain_id="chain_placement",owner_user_id=owner,title="Synthetic placement",kind="mixed_work",status=.Active,created_at=now,updated_at=now})
	if !testing.expect(t,saved) do return
	service:=mcp.Control_Service{chains=&g.taskchains}
	chain,_,_:=iface.taskchain_get_chain(&g.repos.taskchains,"chain_placement")
	revision,_,_:=mcp.control_configuration(&service,chain)
	fleet:=json.Object{"chain_id"=json.String(chain.chain_id),"request_id"=json.String("fleet_b"),"expected_revision"=json.String(revision),"action"=json.String("fleet"),"agent_id"=json.String("agt_placement"),"bridge_id"=json.String("brg_placement_b"),"provider"=json.String("codex"),"model"=json.String(model)}
	if mcp_task_test_output(t,mcp_task_test_call(h,headers,"chains.configure",fleet))==nil do return
	testing.expect_value(t,mcp_task_target(g,owner,chain.chain_id,"agt_placement","brg_placement_b"),"")
	testing.expect_value(t,mcp_task_target(g,owner,chain.chain_id,"agt_placement","brg_placement_a"),"placement_configuration_required")
	testing.expect_value(t,mcp_task_target(g,owner,chain.chain_id,"agt_placement","brg_placement_offline"),"bridge_offline")
	testing.expect_value(t,mcp_task_target(g,owner,chain.chain_id,"agt_missing","brg_placement_b"),"not_found")
	foreign_owner:=domain.User_ID("foreign_owner")
	_,user_ok,_:=iface.user_save(&g.repos.users,{user_id=foreign_owner,name="Synthetic foreign owner",status=.Active})
	testing.expect(t,user_ok)
	_,foreign_saved,_:=iface.bridge_save_bridge(&g.repos.bridges,{bridge_id="brg_placement_foreign",owner_user_id=foreign_owner,label="Synthetic foreign bridge",status=.Online,created_at=now,updated_at=now})
	testing.expect(t,foreign_saved)
	testing.expect_value(t,mcp_task_target(g,owner,chain.chain_id,"agt_placement","brg_placement_foreign"),"not_found")
	for bridge in ([]string{"brg_placement_a","brg_placement_b"}) {
		instance:="inst_placement_a";if bridge=="brg_placement_b" do instance="inst_placement_b"
		_,instance_ok,_:=iface.agent_save_instance(&g.repos.agents,{agent_instance_id=instance,owner_user_id=owner,agent_id="agt_placement",bridge_id=bridge,display_name=instance,provider="codex",model=model,chain_id=string(chain.chain_id),runtime_status="running",activity_status="idle",created_at=now,updated_at=now,last_seen_at=now})
		testing.expect(t,instance_ok)
		_,member_ok,_:=iface.taskchain_save_member(&g.repos.taskchains,{chain_id=chain.chain_id,agent_instance_id=instance,agent_id="agt_placement",owner_user_id=owner,role="worker",created_at=now})
		testing.expect(t,member_ok)
	}
	create:=json.Object{"chain_id"=json.String(chain.chain_id),"request_id"=json.String("placed_create"),"title"=json.String("Selected-machine work"),"goal"=json.String("Synthetic placement proof"),"acceptance"=json.Array{json.String("Selected machine receives the lease")},"assignee_agent_id"=json.String("agt_placement"),"bridge_id"=json.String("brg_placement_b")}
	result:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"tasks.create",create))
	if result==nil do return
	id,_:=result["resource_id"].(json.String)
	chain,_,_=iface.taskchain_get_chain(&g.repos.taskchains,chain.chain_id)
	revision,_,_=mcp.control_configuration(&service,chain)
	publish:=json.Object{"chain_id"=json.String(chain.chain_id),"request_id"=json.String("placed_publish"),"expected_revision"=json.String(revision),"action"=json.String("publish")}
	if mcp_task_test_output(t,mcp_task_test_call(h,headers,"chains.configure",publish))==nil do return
	lease,leased,lerr:=g.repos.taskchains.get_lease_by_holder(g.repos.taskchains.ctx,"inst_placement_b")
	testing.expectf(t,leased && lerr.code==.None && string(lease.task_id)==string(id),"selected machine lease: %s",lerr.message)
	_,wrong_machine,_:=g.repos.taskchains.get_lease_by_holder(g.repos.taskchains.ctx,"inst_placement_a")
	testing.expect(t,!wrong_machine)
	current,_,_:=iface.taskchain_get_task(&g.repos.taskchains,domain.Task_ID(id))
	task_revision,_:=mcp.control_task_revision(&service,current)
	edit:=json.Object{"task_id"=id,"request_id"=json.String("leased_goal"),"expected_revision"=json.String(task_revision),"goal"=json.String("Cannot replace in-flight goal")}
	testing.expect(t,strings.contains(mcp_task_test_call(h,headers,"tasks.update",edit).body,"conflict"))
	delete_key(&edit,"goal");edit["acceptance"]=json.Array{json.String("Allowed acceptance refinement")};edit["request_id"]=json.String("leased_acceptance")
	if mcp_task_test_output(t,mcp_task_test_call(h,headers,"tasks.update",edit))==nil do return
	create["request_id"]=json.String("wrong_machine_create");create["bridge_id"]=json.String("brg_placement_a")
	testing.expect(t,strings.contains(mcp_task_test_call(h,headers,"tasks.create",create).body,"placement_configuration_required"))
	create["request_id"]=json.String("offline_create");create["bridge_id"]=json.String("brg_placement_offline")
	testing.expect(t,strings.contains(mcp_task_test_call(h,headers,"tasks.create",create).body,"bridge_offline"))
	create["request_id"]=json.String("foreign_create");create["bridge_id"]=json.String("brg_placement_foreign")
	testing.expect(t,strings.contains(mcp_task_test_call(h,headers,"tasks.create",create).body,"not_found"))
	chain,_,_=iface.taskchain_get_chain(&g.repos.taskchains,chain.chain_id)
	revision,_,_=mcp.control_configuration(&service,chain)
	fleet["expected_revision"]=json.String(revision);fleet["request_id"]=json.String("unsupported_fleet");fleet["model"]=json.String("unsupported-synthetic-model")
	testing.expect(t,strings.contains(mcp_task_test_call(h,headers,"chains.configure",fleet).body,"provider_unavailable"))
	remaining,_:=tc.list_tasks(&g.taskchains,mcp.control_auth(view.owner),chain.chain_id)
	testing.expect(t,len(remaining)==1)
	// Configure a second provider/machine without losing B's pinned selection.
	legacy_fleet,_:=iface.taskchain_list_fleets_by_chain(&g.repos.taskchains,chain.chain_id,owner)
	if !testing.expect(t,len(legacy_fleet)==1) do return
	legacy_fleet[0].bridge_models_json="" // existing native rows need no overrides
	_,legacy_err:=iface.taskchain_upsert_fleet(&g.repos.taskchains,legacy_fleet[0])
	testing.expect(t,legacy_err.code==.None)
	second_entry,second_known,second_err:=iface.provider_catalog_get(&g.provider_repo,"claude")
	if !testing.expect(t,second_known && second_err.code==.None && len(second_entry.models)>0) do return
	defer domain.provider_catalog_entry_destroy(second_entry)
	second_model:string
	for candidate in second_entry.models do if candidate.state=="active" {second_model=candidate.model_id;break}
	if !testing.expect(t,second_model!="") do return
	_,_=iface.bridge_provider_status_upsert(&g.provider_repo,{bridge_id="brg_placement_a",provider="claude",state="present",checked_at=now})
	_,_=iface.bridge_provider_setting_upsert(&g.provider_repo,{bridge_id="brg_placement_a",provider="claude",enabled=true,updated_at=now})
	_,support_ok,_:=iface.agent_save_support(&g.repos.agents,{agent_id="agt_placement",bridge_id="brg_placement_a",owner_user_id=owner,enabled=false,created_at=now,updated_at=now})
	testing.expect(t,support_ok)
	chain,_,_=iface.taskchain_get_chain(&g.repos.taskchains,chain.chain_id)
	revision,_,_=mcp.control_configuration(&service,chain)
	fleet["request_id"]=json.String("disabled_fleet");fleet["expected_revision"]=json.String(revision);fleet["bridge_id"]=json.String("brg_placement_a");fleet["provider"]=json.String("claude");fleet["model"]=json.String(second_model);fleet["capacity"]=json.Integer(2)
	testing.expect(t,strings.contains(mcp_task_test_call(h,headers,"chains.configure",fleet).body,"provider_unavailable"))
	_,support_ok,_=iface.agent_save_support(&g.repos.agents,{agent_id="agt_placement",bridge_id="brg_placement_a",owner_user_id=owner,enabled=true,created_at=now,updated_at=now})
	testing.expect(t,support_ok)
	fleet["request_id"]=json.String("fleet_a")
	if mcp_task_test_output(t,mcp_task_test_call(h,headers,"chains.configure",fleet))==nil do return
	testing.expect_value(t,mcp_task_target(g,owner,chain.chain_id,"agt_placement","brg_placement_b"),"")
	create["request_id"]=json.String("placed_create_a");create["bridge_id"]=json.String("brg_placement_a")
	second:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"tasks.create",create))
	if second==nil do return
	second_id,_:=second["resource_id"].(json.String)
	lease_a,leased_a,_:=iface.taskchain_get_lease_by_holder(&g.repos.taskchains,"inst_placement_a")
	lease_b,leased_b,_:=iface.taskchain_get_lease_by_holder(&g.repos.taskchains,"inst_placement_b")
	testing.expect(t,leased_a && leased_b && string(lease_a.task_id)==string(second_id) && string(lease_b.task_id)==string(id))
	testing.expect(t,lease_a.provider=="claude" && lease_a.model==second_model && lease_b.provider=="codex" && lease_b.model==model)
}

mcp_task_test_mutations :: proc(t:^testing.T,g:^App_Graph,h:^http.MCP_Control_Handlers,headers:[]contracts.HTTP_Header,view:mcp.Access_View) {
	now:=mcp_task_test_now(nil)
	_,saved,_:=iface.taskchain_save_chain(&g.repos.taskchains,{chain_id="chain_mutation",owner_user_id=domain.User_ID(view.owner),title="Synthetic mutation",kind="mixed_work",status=.Active,created_at=now,updated_at=now})
	if !testing.expect(t,saved) do return
	args:=json.Object{"chain_id"=json.String("chain_mutation"),"request_id"=json.String("create_retry"),"title"=json.String("Private task title"),"goal"=json.String("Private task goal"),"acceptance"=json.Array{json.String("Private criterion")},"requires_user_approval"=json.Boolean(true)}
	first:=mcp_task_test_call(h,headers,"tasks.create",args)
	output:=mcp_task_test_output(t,first)
	if output==nil do return
	id,typed:=output["resource_id"].(json.String)
	if !testing.expect(t,typed) do return
	retry:=mcp_task_test_call(h,headers,"tasks.create",args)
	testing.expect(t,first.body==retry.body)
	task,found,err:=iface.taskchain_get_task(&g.repos.taskchains,domain.Task_ID(id))
	if !testing.expect(t,found && err.code==.None) do return
	testing.expect(t,strings.has_prefix(task.title,"vault:v2:") && !strings.contains(task.brief_json,"Private task goal") && !strings.contains(task.brief_json,"Private criterion") && task.requires_user_approval)
	read:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"tasks.get",json.Object{"task_id"=id}))
	if read==nil do return
	tasks,_:=read["tasks"].(json.Array);record,_:=tasks[0].(json.Object)
	goal,_:=record["goal"].(json.String)
	testing.expect_value(t,string(goal),"Private task goal")
	revision,_:=record["revision"].(json.String)
	update:=json.Object{"task_id"=id,"request_id"=json.String("update_retry"),"expected_revision"=revision,"goal"=json.String("Updated private goal")}
	changed:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"tasks.update",update))
	if changed==nil do return
	testing.expect(t,mcp_task_test_call(h,headers,"tasks.update",update).body==mcp_task_test_call(h,headers,"tasks.update",update).body)
	update["request_id"]=json.String("stale_update")
	stale:=mcp_task_test_call(h,headers,"tasks.update",update)
	testing.expect(t,strings.contains(stale.body,"revision_conflict"))
	_,_,receipt,_:=sqlite.mcp_receipt_get(&g.db,view.owner,view.grant,"tasks.update","stale_update")
	testing.expect(t,!receipt)
	task,_,_=iface.taskchain_get_task(&g.repos.taskchains,domain.Task_ID(id))
	testing.expect(t,task.requires_user_approval && !strings.contains(task.brief_json,"Updated private goal"))
	chain,_,_:=iface.taskchain_get_chain(&g.repos.taskchains,"chain_mutation")
	service:=mcp.Control_Service{chains=&g.taskchains}
	configuration_revision,_,ok:=mcp.control_configuration(&service,chain)
	if !testing.expect(t,ok) do return
	publish:=json.Object{"chain_id"=json.String("chain_mutation"),"request_id"=json.String("publish_retry"),"expected_revision"=json.String(configuration_revision),"action"=json.String("publish")}
	if mcp_task_test_output(t,mcp_task_test_call(h,headers,"chains.configure",publish))==nil do return
	task,_,_=iface.taskchain_get_task(&g.repos.taskchains,domain.Task_ID(id))
	testing.expect(t,task.publish_state==.Published)
	rev,rev_ok:=mcp.control_task_revision(&service,task)
	if !testing.expect(t,rev_ok) do return
	hold:=json.Object{"task_id"=id,"request_id"=json.String("hold_retry"),"expected_revision"=json.String(rev),"action"=json.String("hold"),"reason"=json.String("Private hold reason")}
	if mcp_task_test_output(t,mcp_task_test_call(h,headers,"tasks.control",hold))==nil do return
	task,_,_=iface.taskchain_get_task(&g.repos.taskchains,domain.Task_ID(id))
	testing.expect(t,!strings.contains(task.blocked_on_json,"Private hold reason"))
	all,_:=tc.list_tasks(&g.taskchains,mcp.control_auth(view.owner),"chain_mutation")
	testing.expect(t,len(all)==1)
}
