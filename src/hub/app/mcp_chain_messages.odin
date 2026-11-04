package app

import "core:encoding/json"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import mcp "odin_test:hub/service/mcp"
import tc "odin_test:hub/service/taskchain"
import content "odin_test:hub/service/content"
import http "odin_test:hub/transport/http"
import vault "odin_test:lib/vault"

MCP_Message_Result :: struct {chain_id,coordinator_agent_instance_id,conversation_id,message_id,status,delivery_warning:string}

mcp_send_chain_message :: proc(ctx:rawptr,raw:string,view:mcp.Access_View,chain_id,request_id,digest,body:string)->(string,string) {
	g:=(^App_Graph)(ctx)
	vid,epoch,_,parsed:=vault.envelope_parse(body,context.temp_allocator);buf:[16]byte
	if parsed!=.Ok || epoch!=view.epoch || vault.vault_id_hex(vid,buf[:])!=view.vault_id do return "","decryption_unavailable"
	uow,begun,err:=iface.unit_of_work_begin(&g.uow_factory)
	if !begun || err.code!=.None do return "","request_failed"
	finished:=false;defer if !finished do iface.unit_of_work_rollback(&uow)
	if code:=mcp_task_write_check(g,raw,view,"chains.message");code!="" do return "",code
	principal:=mcp.control_auth(view.owner)
	chain,owned,cerr:=tc.get_chain_for_read(&g.taskchains,principal,domain.Task_Chain_ID(chain_id))
	if cerr.code!=.None && cerr.code!=.Not_Found && cerr.code!=.Forbidden do return "","request_failed"
	if !owned || cerr.code!=.None do return "","not_found"
	prior,_,found,rerr:=sqlite.mcp_receipt_get(&g.db,view.owner,view.grant,"chains.message",request_id)
	if rerr.code!=.None do return "","request_failed"
	if found {
		if prior!=digest do return "","idempotency_conflict"
		output,stored:=sqlite.mcp_receipt_result(&g.db,view.owner,view.grant,"chains.message",request_id)
		if !stored do return "","request_failed"
		return output,""
	}
	instance_id,ierr:=tc.coordinator_primary_instance_checked(&g.taskchains,chain.chain_id,chain.owner_user_id)
	if ierr.code!=.None do return "","request_failed"
	if instance_id=="" do return "","coordinator_missing"
	i,valid,verr:=iface.agent_get_instance(&g.repos.agents,instance_id)
	if !valid || verr.code!=.None || string(i.owner_user_id)!=view.owner || i.kind!="agent" do return "","coordinator_unavailable"
	// Prefer the instance's durable conversation binding. The general list-based
	// by-instance helper is bounded and can omit an old coordinator conversation.
	c:domain.Chat_Conversation;exists:bool;conv_err:domain.Domain_Error
	if i.conversation_id!="" {c,exists,conv_err=content.get_conversation(&g.content,principal,i.conversation_id)} else {c,exists,conv_err=content.get_conversation_by_instance(&g.content,principal,instance_id)}
	if !exists || conv_err.code!=.None || string(c.owner_user_id)!=view.owner || c.agent_instance_id!=instance_id do return "","coordinator_unavailable"
	metadata,_:=json.marshal(struct {source,delegated_client_id,delegated_grant_id:string}{"mcp",view.client,view.grant},allocator=context.temp_allocator)
	m,saved,merr:=content.persist_user_message(&g.content,principal,c.conversation_id,{body=body,message_type="text",metadata_json=string(metadata)})
	if !saved || merr.code!=.None do return "",mcp_task_error(merr)
	result:=MCP_Message_Result{chain_id=chain_id,coordinator_agent_instance_id=instance_id,conversation_id=c.conversation_id,message_id=m.message_id,status="accepted"}
	encoded,eerr:=json.marshal(result,allocator=context.temp_allocator)
	if eerr!=nil do return "","request_failed"
	if e:=sqlite.mcp_receipt_put(&g.db,view.owner,view.grant,"chains.message",request_id,digest,m.message_id,string(encoded));e.code!=.None do return "","request_failed"
	ok,commit_err:=iface.unit_of_work_commit(&uow);finished=true
	if !ok || commit_err.code!=.None do return "","request_failed"
	// Visibility and all Bridge effects happen after commit. A failed wake never
	// changes accepted persistence into an error that encourages duplicate sends.
	http.publish_user_message_created(&g.content_handlers,principal,c.conversation_id,m)
	restarted,restart_err:=http.restart_stopped_conversation_instance(&g.content_handlers,principal,c.conversation_id)
	delivered,delivery_err:=content.deliver_user_message(&g.content,principal,c.conversation_id,m)
	if !restarted || !delivered {
		result.delivery_warning="delivery_unavailable"
		if restart_err.code==.Bridge_Offline || delivery_err.code==.Bridge_Offline do result.delivery_warning="bridge_offline"
	}
	encoded,_=json.marshal(result,allocator=context.temp_allocator)
	return string(encoded),""
}
