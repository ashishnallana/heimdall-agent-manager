package http

import "base:runtime"
import "core:encoding/json"
import "core:mem/virtual"
import "core:net"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import platform "odin_test:hub/platform"
import auth "odin_test:hub/service/auth"
import events "odin_test:hub/service/events"
import mcp "odin_test:hub/service/mcp"
import tc "odin_test:hub/service/taskchain"
import vd "odin_test:hub/service/vault_directory"
import vault "odin_test:lib/vault"

MCP_Control_Fixture :: struct {
	base:^MCP_Test_Fixture,
	state:MCP_HTTP_State,
	impl:sqlite.MCP_Repo_SQLite,
	repo:iface.MCP_Repository,
	keys:[1]mcp.Envelope_Key,
	service:mcp.Delegation_Service,
	vrepo:iface.Vault_Directory_Repository,
	directory:vd.Service,
	timpl:sqlite.Taskchain_Repo_SQLite,
	trepo:iface.Taskchain_Repository,
	chains:tc.Taskchain_Service,
	ids:platform.ID_Generator,
	delegation:MCP_Delegation_Handlers,
	h:MCP_Control_Handlers,
	bus:events.User_Event_Bus,
	token:string,
}
mcp_control_fixture :: proc(t:^testing.T,use_device:=false)->^MCP_Control_Fixture {
	f:=new(MCP_Control_Fixture,context.temp_allocator)
	f.base=mcp_test_fixture(t)
	vectors:struct {alice:struct {initial:MCP_HTTP_Vector,content:json.Object}}
	testing.expect(t,json.unmarshal_string(#load("../../../../tests/fixtures/mcp_hosted_v1.json",string),&vectors,.JSON,context.temp_allocator)==nil)
	f.state.vector=vectors.alice.initial
	if use_device {
		device:struct {initial:MCP_HTTP_Vector,job:vault.Control_Job}
		testing.expect(t,json.unmarshal_string(#load("../../../../tests/fixtures/mcp_worker_v1.json",string),&device,.JSON,context.temp_allocator)==nil)
		f.state.vector=device.initial
		payload:mcp.Control_Data
		testing.expect(t,json.unmarshal_string(device.job.payload,&payload,.JSON,context.temp_allocator)==nil)
		vectors.alice.content=payload.chain
	}
	v:=&f.state.vector
	_,saved,_:=iface.user_save(&f.base.user_repo,domain.User{user_id=domain.User_ID(v.request.owner),name=v.request.owner,status=.Active,created_at=mcp_test_now(nil),updated_at=mcp_test_now(nil)})
	testing.expect(t,saved)
	repo,err:=sqlite.open_mcp_repository(&f.impl,":memory:");f.repo=repo
	testing.expect(t,err.code==.None)
	migrated,_:=sqlite.run_migrations(&f.impl.conn);testing.expect(t,migrated)
	ui:sqlite.User_Repo_SQLite
	ur:=sqlite.new_user_repository(&ui,&f.impl.conn)
	for owner in ([]string{v.request.owner,"alice"}) {
		_,user_ok,_:=iface.user_save(&ur,{user_id=domain.User_ID(owner),name=owner,status=.Active,created_at=mcp_test_now(nil),updated_at=mcp_test_now(nil)})
		testing.expect(t,user_ok)
	}
	testing.expect(t,iface.mcp_transaction(&f.repo,mcp_http_seed,&f.state).code==.None)
	f.keys[0].id="control-test";f.keys[0].bytes[0]=7
	f.service={repo=&f.repo,keys=f.keys[:],issuer="https://hub.example",resource=v.request.resource,clock=&f.base.clock,authority=proc(ctx:rawptr,g:domain.MCP_Record)->(bool,domain.Domain_Error){return true,{}}}
	f.vrepo={ctx=&f.state,get_directory=mcp_http_directory,list_devices=mcp_http_devices,list_log=mcp_http_log}
	f.directory=vd.new_service(&f.vrepo,&f.base.clock)
	f.delegation={auth=&f.base.auth,directory=&f.directory,grant_directory=&f.directory,service=&f.service,origin=f.service.issuer}
	code,_,_,cerr:=mcp.delegation_consent(&f.service,&f.directory,v.request.owner,v.directory.root_device_id,v.hosted,v.now_ms)
	testing.expect(t,cerr.code==.None)
	token_result:=mcp.delegation_redeem(&f.service,code,"code",v.request.client,v.request.redirect,"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",v.now_ms)
	tokens:mcp.Tokens
	testing.expect(t,token_result.error=="" && json.unmarshal_string(token_result.response,&tokens,.JSON,context.temp_allocator)==nil)
	f.token=tokens.access_token
	f.trepo=sqlite.new_taskchain_repository(&f.timpl,&f.impl.conn)
	f.ids=platform.real_id_generator()
	f.chains=tc.new_taskchain_service(&f.trepo,nil,&f.base.clock,&f.ids)
	f.h={delegation=&f.delegation,control={chains=&f.chains},bus=&f.bus,create_ctx=f,create=mcp_control_test_create}
	title,_:=vectors.alice.content["title"].(json.String);description,_:=vectors.alice.content["description"].(json.String)
	_,chain_ok,chain_err:=iface.taskchain_save_chain(&f.trepo,{chain_id="chain_fixture",owner_user_id=domain.User_ID(v.request.owner),title=string(title),description=string(description),status=.Active,kind="mixed_work",defaults_json="{}",created_at=mcp_test_now(nil),updated_at=mcp_test_now(nil)})
	testing.expectf(t,chain_ok && chain_err.code==.None,"seed chain: %s",chain_err.message)
	_,task_ok,task_err:=iface.taskchain_save_task(&f.trepo,{task_id="task_fixture",chain_id="chain_fixture",owner_user_id=domain.User_ID(v.request.owner),title=string(title),description=string(description),state=.In_Review,brief_json=`{"goal":"never disclose this private nested brief"}`,created_at=mcp_test_now(nil),updated_at=mcp_test_now(nil)})
	testing.expectf(t,task_ok && task_err.code==.None,"seed task: %s",task_err.message)
	_,comment_ok,comment_err:=iface.taskchain_save_comment(&f.trepo,{comment_id="cmt_fixture",task_id="task_fixture",chain_id="chain_fixture",owner_user_id=domain.User_ID(v.request.owner),body=string(title),created_at=mcp_test_now(nil),updated_at=mcp_test_now(nil)})
	testing.expectf(t,comment_ok && comment_err.code==.None,"seed comment: %s",comment_err.message)
	return f
}
mcp_control_test_create :: proc(ctx:rawptr,owner,title,description:string)->(string,bool) {
	f:=(^MCP_Control_Fixture)(ctx)
	c,ok,err:=tc.create_chain(&f.chains,mcp.control_auth(owner),{title=title,description=description})
	return string(c.chain_id),ok && err.code==.None
}
mcp_control_test_fail_create :: proc(ctx:rawptr,owner,title,description:string)->(string,bool) {
	id,_:=mcp_control_test_create(ctx,owner,title,description)
	return id,false
}
mcp_control_close :: proc(f:^MCP_Control_Fixture) {mcp.worker_registrations_free(&f.h.registrations);vd.service_free(&f.directory);sqlite.close(&f.impl.conn);sqlite.close(&f.base.conn)}
mcp_control_request :: proc(h:^MCP_Control_Handlers,token,body:string)->Response {
	headers:=[]contracts.HTTP_Header{{"Authorization",mcp_join("Bearer ",token)},{"Content-Type","application/json"}}
	return mcp_control_handler(h,{method="POST",path=MCP_PATH,body=strings.clone(body,context.temp_allocator),headers=headers})
}
@(test)
test_mcp_control_hosted_four_tools_ownership_creation_and_stateless_restart :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	f:=mcp_control_fixture(t);defer mcp_control_close(f)
	init:=mcp_control_request(&f.h,f.token,`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}`)
	testing.expect(t,init.status==200 && strings.contains(init.body,"2025-06-18"))
	list:=mcp_control_request(&f.h,f.token,`{"jsonrpc":"2.0","id":2,"method":"tools/list"}`)
	testing.expect(t,strings.contains(list.body,"chains.list") && strings.contains(list.body,"chains.get") && strings.contains(list.body,"chains.create") && strings.contains(list.body,"events.wait") && !strings.contains(list.body,"lease.next"))
	testing.expect(t,!strings.contains(list.body,"tasks.get") && !strings.contains(list.body,"tasks.create") && !strings.contains(list.body,"chains.configure"))
	for call in ([]string{
		`{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"tasks.get","arguments":{"chain_id":"chain_fixture","task_id":"task_fixture"}}}`,
		`{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"tasks.comment","arguments":{"chain_id":"chain_fixture","task_id":"task_fixture","request_id":"legacy_denied","body":"Never write"}}}`,
		`{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"tasks.create","arguments":{"chain_id":"chain_fixture","request_id":"legacy_denied","title":"Never write","goal":"Never write","acceptance":["Never write"]}}}`,
	}) {
		testing.expect(t,strings.contains(mcp_control_request(&f.h,f.token,call).body,"scope_missing"))
	}
	read:=mcp_control_request(&f.h,f.token,`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"chains.get","arguments":{"chain_id":"chain_fixture"}}}`)
	testing.expectf(t,read.status==200 && strings.contains(read.body,"usr_alice_fixture secret") && strings.contains(read.body,"embedded secret") && strings.contains(read.body,"comments") && !strings.contains(read.body,"vault:v2:") && !strings.contains(read.body,"private nested brief"),"read response: %s",read.body)
	// Real foreign-owner row exists: still indistinguishable from missing.
	_,_,_=iface.taskchain_save_chain(&f.trepo,{chain_id="chain_foreign",owner_user_id="alice",title="other owner secret",description="",kind="mixed_work",defaults_json="{}",created_at=mcp_test_now(nil),updated_at=mcp_test_now(nil)})
	other_owner:=mcp_control_request(&f.h,f.token,`{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"chains.get","arguments":{"chain_id":"chain_foreign"}}}`)
	testing.expect(t,strings.contains(other_owner.body,"not_found") && !strings.contains(other_owner.body,"other owner secret"))
	listing:=mcp_control_request(&f.h,f.token,`{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"chains.list","arguments":{"limit":1}}}`)
	testing.expect(t,strings.contains(listing.body,"chain_fixture") && !strings.contains(listing.body,"other owner secret"))
	created:=mcp_control_request(&f.h,f.token,`{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"chains.create","arguments":{"title":"new private chain","description":"private description"}}}`)
	testing.expectf(t,created.status==200 && strings.contains(created.body,"new private chain"),"create response: %s",created.body)
	rows,rerr:=iface.taskchain_list_chains_by_owner(&f.trepo,domain.User_ID(f.state.vector.request.owner))
	testing.expect(t,rerr.code==.None && len(rows)==2)
	for c in rows do if c.chain_id!="chain_fixture" {testing.expect(t,vault.is_armored(c.title) && vault.is_armored(c.description));testing.expect(t,c.coordinator_agent_instance_id=="" && c.publish_state==.Draft)}
	f.h.create=mcp_control_test_fail_create
	failed:=mcp_control_request(&f.h,f.token,`{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"chains.create","arguments":{"title":"rolled back private chain"}}}`)
	testing.expect(t,strings.contains(failed.body,"request_failed"))
	rolled_back,_:=iface.taskchain_list_chains_by_owner(&f.trepo,domain.User_ID(f.state.vector.request.owner))
	testing.expect(t,len(rolled_back)==2,"creation and grant check share one rollback boundary")
	f.h.create=mcp_control_test_create
	// Fresh handler process state requires neither pairing nor an initialize/session cache.
	restarted:=MCP_Control_Handlers{delegation=&f.delegation,control={chains=&f.chains},bus=&f.bus}
	again:=mcp_control_request(&restarted,f.token,`{"jsonrpc":"2.0","id":"new-conversation","method":"tools/call","params":{"name":"chains.get","arguments":{"chain_id":"chain_fixture"}}}`)
	testing.expect(t,strings.contains(again.body,"usr_alice_fixture secret"))
	unauthorized:=mcp_control_request(&f.h,"hut_wrong",`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
	testing.expect(t,unauthorized.status==401 && strings.contains(header_value(unauthorized.headers,"WWW-Authenticate"),"resource_metadata"))
}
MCP_Wait_Run :: struct {h:^MCP_Control_Handlers,token,body,result:string,status:int}
mcp_wait_run :: proc(ctx:rawptr) {
	op:=(^MCP_Wait_Run)(ctx)
	arena:virtual.Arena
	if virtual.arena_init_growing(&arena,256*1024)!=nil do return
	defer virtual.arena_destroy(&arena)
	context.allocator=virtual.arena_allocator(&arena);context.temp_allocator=context.allocator
	resp:=mcp_control_request(op.h,op.token,op.body)
	op.result=strings.clone(resp.body,runtime.heap_allocator());op.status=resp.status
}
mcp_wait_attached :: proc(h:^MCP_Control_Handlers)->bool {
	started:=time.tick_now()
	for time.tick_since(started)<2*time.Second {
		sync.mutex_lock(&h.bus.poll_mutex)
		attached:=false
		for slot in h.bus.poll_slots do if slot.active do attached=true
		sync.mutex_unlock(&h.bus.poll_mutex)
		if attached do return true
		time.sleep(time.Millisecond)
	}
	return false
}
@(test)
test_mcp_control_wait_hint_cancel_and_revocation :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	f:=mcp_control_fixture(t);defer mcp_control_close(f)
	body:=`{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"events.wait","arguments":{"chain_id":"chain_fixture","timeout_ms":1000}}}`
	for mode in 0..<3 {
		op:=MCP_Wait_Run{h=&f.h,token=f.token,body=body}
		worker:=thread.create_and_start_with_data(&op,mcp_wait_run)
		testing.expect(t,mcp_wait_attached(&f.h))
		if mode==0 {
			c,_,_:=iface.taskchain_get_chain(&f.trepo,"chain_fixture");c.updated_at="2026-10-31T07:00:01Z";_,_,_=iface.taskchain_save_chain(&f.trepo,c)
			events.publish_resource_changed(&f.bus,f.state.vector.request.owner,"task_chain","chain_fixture","updated","")
		} else if mode==1 {
			cancel:=mcp_control_request(&f.h,f.token,`{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":42}}`)
			testing.expect_value(t,cancel.status,202)
		} else {
			testing.expect(t,mcp.delegation_revoke(&f.service,f.state.vector.request.owner,f.state.vector.request.grant).code==.None)
			events.publish_resource_changed(&f.bus,f.state.vector.request.owner,"task_chain","chain_fixture","updated","")
		}
		thread.join(worker);thread.destroy(worker)
		if mode==0 do testing.expect(t,op.status==200 && strings.contains(op.result,"07:00:01Z") && strings.contains(op.result,"usr_alice_fixture secret"))
		if mode==1 do testing.expect(t,strings.contains(op.result,"cancelled"))
		if mode==2 do testing.expect_value(t,op.status,401)
		delete(op.result,runtime.heap_allocator())
		for slot in f.bus.poll_slots do testing.expect(t,!slot.active)
		for slot in f.h.requests.slots do testing.expect(t,!slot.active)
	}
}
@(test)
test_mcp_control_rpc_grammar_and_device_reply_binding :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	for raw in ([]string{
		`{"chain_id":"chain_a","request_id":"r","title":"x","goal":"g","acceptance":[{}]}`,
		`{"chain_id":"chain_a","request_id":"r","title":"x","goal":"g","acceptance":["a"],"owner_user_id":"foreign"}`,
		`{"chain_id":"chain_a","title":"x","goal":"g","acceptance":["a"]}`,
	}) {
		value,err:=json.parse_string(raw,parse_integers=true,allocator=context.temp_allocator)
		testing.expect(t,err==nil)
		_,valid:=mcp_arguments("tasks.create",value)
		testing.expect(t,!valid)
	}
	for raw in ([]string{
		`{"chain_id":"chain_a","task_id":"task_a","request_id":"r","expected_revision":"old","goal":"g"}`,
		`{"chain_id":"chain_a","task_id":"task_a","request_id":"r","expected_revision":"0000000000000000000000000000000000000000000000000000000000000000","state":"done"}`,
	}) {
		value,_:=json.parse_string(raw,parse_integers=true,allocator=context.temp_allocator)
		_,valid:=mcp_arguments("tasks.update",value)
		testing.expect(t,!valid)
	}
	disabled:MCP_Control_Handlers
	mcp_bridge_result(&Bridge_Handlers{mcp_control=&disabled},"brg_disabled",strings.clone("{}",context.temp_allocator),1)
	f:=mcp_control_fixture(t);defer mcp_control_close(f)
	for body in ([]string{`[]`,`{"jsonrpc":"2.0","id":true,"method":"tools/list"}`,`{"jsonrpc":"2.0","id":1,"method":"tools/list"} trailing`,`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"events.wait","arguments":{"chain_id":"chain_fixture","timeout_ms":25001}}}`,`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chains.create","arguments":{"title":"x","owner":"bob"}}}`}) {
		resp:=mcp_control_request(&f.h,f.token,body);testing.expect(t,strings.contains(resp.body,"error"))
	}
	v:struct {now_ms:i64,device_id,bridge_device_id:string,job:vault.Control_Job,reply,bridge_reply:vault.Control_Reply}
	testing.expect(t,json.unmarshal_string(#load("../../../../tests/fixtures/mcp_worker_v1.json",string),&v,.JSON,context.temp_allocator)==nil)
	testing.expect(t,mcp_verify_reply(v.job,v.reply,v.device_id,v.now_ms))
	testing.expect(t,mcp_verify_reply(v.job,v.bridge_reply,v.bridge_device_id,v.now_ms))
	bad:=v.reply;bad.result="tampered";testing.expect(t,!mcp_verify_reply(v.job,bad,v.device_id,v.now_ms))
	bad=v.reply;bad.generation="late";testing.expect(t,!mcp_verify_reply(v.job,bad,v.device_id,v.now_ms))
	testing.expect(t,!mcp_verify_reply(v.job,v.reply,v.bridge_device_id,v.now_ms))
	testing.expect(t,!mcp_verify_reply(v.job,v.reply,v.device_id,v.job.deadline_ms))
}

MCP_Device_Test :: struct {keyring:vault.Vault_Keyring,device_id:string,calls:int,revoke:^mcp.Delegation_Service,tamper:bool}
mcp_device_test_transform :: proc(ctx:rawptr,job:vault.Control_Job)->(string,bool) {
	op:=(^MCP_Device_Test)(ctx);op.calls+=1
	if !vault.control_job_verify(job,"usr_mcp_worker_fixture","https://hub.example/api/v1/mcp",op.device_id,&op.keyring,1793430000000) do return "",false
	result,ok:=vault.control_job_transform(job,&op.keyring)
	if op.revoke!=nil do _=mcp.delegation_revoke(op.revoke,job.owner,job.grant)
	if op.tamper do result=strings.concatenate({result," trailing private data"},context.temp_allocator)
	return result,ok
}
@(test)
test_mcp_control_default_worker_route_unavailable_and_revoke :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	f:=mcp_control_fixture(t,true);defer mcp_control_close(f)
	v:struct {keyring_hex,bridge_device_id:string}
	testing.expect(t,json.unmarshal_string(#load("../../../../tests/fixtures/mcp_worker_v1.json",string),&v,.JSON,context.temp_allocator)==nil)
	bytes:=make([]byte,len(v.keyring_hex)/2,context.temp_allocator);testing.expect(t,vault.hex_decode_into(bytes,v.keyring_hex))
	kr,ok:=vault.keyring_parse(bytes,f.state.vector.request.owner);testing.expect(t,ok);defer vault.keyring_wipe(&kr)
	op:=MCP_Device_Test{keyring=kr,device_id=v.bridge_device_id};defer vault.keyring_wipe(&op.keyring)
	f.h.bridge_ctx=&op;f.h.bridge_transform=mcp_device_test_transform
	body:=`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chains.get","arguments":{"chain_id":"chain_fixture"}}}`
	read:=mcp_control_request(&f.h,f.token,body)
	testing.expectf(t,op.calls==1 && strings.contains(read.body,"worker secret title") && !strings.contains(read.body,"vault:v2:"),"default read: %s",read.body)
	op.tamper=true
	tampered:=mcp_control_request(&f.h,f.token,body)
	testing.expect(t,strings.contains(tampered.body,"decryption_unavailable") && !strings.contains(tampered.body,"trailing private data"))
	op.tamper=false
	f.h.bridge_transform=nil
	started:=time.tick_now()
	missing:=mcp_control_request(&f.h,f.token,body)
	testing.expect(t,strings.contains(missing.body,"decryption_unavailable") && !strings.contains(missing.body,"pairing") && time.tick_since(started)<5*time.Second)
	for slot in f.h.workers.slots do testing.expect(t,!slot.active && slot.job=="" && slot.result=="")
	f.h.bridge_transform=mcp_device_test_transform;op.revoke=&f.service
	revoked:=mcp_control_request(&f.h,f.token,body)
	testing.expect(t,revoked.status==401 && !strings.contains(revoked.body,"worker secret title"))
}
@(test)
test_mcp_control_browser_worker_requires_signed_device_and_bound_reply :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	f:=mcp_control_fixture(t,true);defer mcp_control_close(f)
	v:struct {job:vault.Control_Job,reply:vault.Control_Reply,get_jobs_headers,post_jobs_headers:map[string]string,post_body:string}
	testing.expect(t,json.unmarshal_string(#load("../../../../tests/fixtures/mcp_worker_v1.json",string),&v,.JSON,context.temp_allocator)==nil)
	testing.expect(t,mcp.worker_begin(&f.h.workers,v.job));defer mcp.worker_end(&f.h.workers,v.job.request_id,v.job.generation)
	cookie:=http_test_login_cookie(t,&f.base.auth,v.job.owner)
	testing.expect(t,mcp.worker_register(&f.h.registrations,v.job.owner,v.reply.device_id,"tab_fixture",true,v.job.deadline_ms+1000,1793430000000))
	unsigned:=mcp_worker_handler(&f.h,{method="GET",path=MCP_OAUTH+"/jobs",headers=mcp_http_headers(cookie,nil,f.delegation.origin)})
	testing.expect(t,unsigned.status!=200)
	get:=mcp_worker_handler(&f.h,{method="GET",path=MCP_OAUTH+"/jobs",query="generation=tab_fixture",headers=mcp_http_headers(cookie,v.get_jobs_headers,f.delegation.origin)})
	testing.expect(t,get.status==200 && get.sensitive && strings.contains(get.body,v.job.request_id) && !strings.contains(get.body,"private_capability") && !strings.contains(get.body,"mcp1."))
	post:=mcp_worker_handler(&f.h,{method="POST",path=MCP_OAUTH+"/jobs",query="generation=tab_fixture",body=strings.clone(v.post_body,context.temp_allocator),headers=mcp_http_headers(cookie,v.post_jobs_headers,f.delegation.origin)})
	testing.expectf(t,post.status==200,"signed worker reply status %d",post.status)
	result,done:=mcp.worker_result(&f.h.workers,v.job.request_id,v.job.generation)
	testing.expect(t,done && strings.contains(result,"worker secret title"))
	testing.expect(t,mcp.public_job_live(&f.service,&f.directory,v.job))
	testing.expect(t,mcp.delegation_revoke(&f.service,v.job.owner,v.job.grant).code==.None)
	testing.expect(t,!mcp.public_job_live(&f.service,&f.directory,v.job))
}

MCP_Socket_Run :: struct {socket:net.TCP_Socket,router:^Router}
mcp_socket_run :: proc(ctx:rawptr) {
	op:=(^MCP_Socket_Run)(ctx)
	handle_client(op.socket,net.Endpoint{address=net.IP4_Loopback},op.router,{ui_origin="https://hub.example"})
}
@(test)
test_mcp_control_url_only_http_forwarding_and_sensitive_response :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	f:=mcp_control_fixture(t);defer mcp_control_close(f)
	r:=new_router();defer router_free(&r)
	mcp_control_register_routes(&r,&f.h);mcp_delegation_register_routes(&r,&f.delegation)
	listener,lerr:=net.listen_tcp({address=net.IP4_Loopback,port=0});testing.expect(t,lerr==nil);defer net.close(listener)
	bound,berr:=net.bound_endpoint(listener);testing.expect(t,berr==nil)
	peer,perr:=net.dial_tcp(net.Endpoint{address=net.IP4_Loopback,port=bound.port});testing.expect(t,perr==nil);defer net.close(peer)
	_ = net.set_option(peer,.Receive_Timeout,5*time.Second)
	server,_,serr:=net.accept_tcp(listener);testing.expect(t,serr==nil)
	op:=MCP_Socket_Run{socket=server,router=&r}
	worker:=thread.create_and_start_with_data(&op,mcp_socket_run)
	body:=`{"jsonrpc":"2.0","id":"real-http","method":"tools/call","params":{"name":"chains.get","arguments":{"chain_id":"chain_fixture"}}}`
	request:=fmt.tprintf("POST /api/v1/mcp HTTP/1.1\r\nHost: hub.example\r\nAuthorization: Bearer %s\r\nContent-Type: application/json\r\nAccept: application/json, text/event-stream\r\nContent-Length: %d\r\n\r\n%s",f.token,len(body),body)
	_,send_err:=net.send_tcp(peer,transmute([]byte)request);testing.expect(t,send_err==nil)
	response:strings.Builder;strings.builder_init(&response,context.temp_allocator)
	buffer:[8192]byte
	for {count,err:=net.recv_tcp(peer,buffer[:]);if count>0 do strings.write_string(&response,string(buffer[:count]));if err!=nil || count<=0 do break}
	thread.join(worker);thread.destroy(worker)
	wire:=strings.to_string(response)
	testing.expect(t,strings.has_prefix(wire,"HTTP/1.1 200") && strings.contains(wire,"Cache-Control: no-store") && strings.contains(wire,"usr_alice_fixture secret") && !strings.contains(wire,"vault:v2:"))
}
