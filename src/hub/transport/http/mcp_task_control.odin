package http

import "core:crypto"
import "core:encoding/json"
import "core:time"
import domain "odin_test:hub/domain"
import auth "odin_test:hub/service/auth"
import mcp "odin_test:hub/service/mcp"
import tc "odin_test:hub/service/taskchain"
import vault "odin_test:lib/vault"

mcp_task_comment_call :: proc(h:^MCP_Control_Handlers,id:json.Value,raw:string,view:mcp.Access_View,args:mcp.Control_Arguments,handle:mcp.Request_Handle,started:time.Tick)->Response {
	if h.comment==nil do return mcp_tool_result(id,"request_failed",true)
	task,owned,err:=tc.get_task_for_read(h.control.chains,mcp.control_auth(view.owner),domain.Task_ID(args.task_id))
	if !owned || err.code!=.None || string(task.chain_id)!=args.chain_id do return mcp_tool_result(id,"not_found",true)
	// Stable plaintext digest, rather than randomized ciphertext, binds retries.
	encoded,eerr:=json.marshal(struct {chain_id,task_id,body:string}{args.chain_id,args.task_id,args.body},allocator=context.temp_allocator)
	if eerr!=nil do return mcp_tool_result(id,"request_failed",true)
	digest:=auth.sha256_hex(string(encoded))
	defer if len(encoded)>0 do crypto.zero_explicit(raw_data(encoded),len(encoded))
	op:=mcp.Control_Transform{tool="tasks.comment",body=args.body}
	result:mcp.Delegation_Result
	if view.mode=="hosted" {result=mcp.hosted_with_access(h.delegation.service,h.delegation.grant_directory,raw,view.client,mcp.control_hosted_transform,&op)} else {result=mcp_device_transform(h,view,&op,handle,started)}
	defer if result.response!="" do crypto.zero_explicit(raw_data(result.response),len(result.response))
	if result.error=="invalid_token" do return mcp_unauthorized(h)
	if result.error!="" do return mcp_tool_result(id,result.error,true)
	if time.tick_since(started)>=30*time.Second || mcp.request_cancelled(&h.requests,handle) do return mcp_tool_result(id,"cancelled",true)
	obj,parsed:=mcp_parse_object(result.response)
	body,typed:=obj["body"].(json.String)
	if !parsed || len(obj)!=1 || !typed do return mcp_tool_result(id,"decryption_unavailable",true)
	vid,epoch,_,status:=vault.envelope_parse(string(body),context.temp_allocator)
	buf:[16]byte
	if status!=.Ok || epoch!=view.epoch || vault.vault_id_hex(vid,buf[:])!=view.vault_id do return mcp_tool_result(id,"decryption_unavailable",true)
	comment,code:=h.comment(h.create_ctx,raw,view,args.chain_id,args.task_id,args.request_id,digest,string(body))
	if code=="invalid_token" do return mcp_unauthorized(h)
	if code!="" do return mcp_tool_result(id,code,true)
	if h.control.chains.repo.get_comment==nil do return mcp_tool_result(id,"request_failed",true)
	stored,found,serr:=h.control.chains.repo.get_comment(h.control.chains.repo.ctx,comment,domain.User_ID(view.owner))
	if !found || serr.code!=.None || string(stored.chain_id)!=args.chain_id || string(stored.task_id)!=args.task_id || stored.author_agent_instance_id!="" || stored.delegated_client_id!=view.client || stored.delegated_grant_id!=view.grant do return mcp_tool_result(id,"request_failed",true)
	output,_:=json.marshal(struct {chain_id,task_id,comment_id,created_at,author_kind,author_user_id,delegated_client_id,delegated_grant_id:string}{args.chain_id,args.task_id,comment,stored.created_at,"delegated_user",view.owner,stored.delegated_client_id,stored.delegated_grant_id},allocator=context.temp_allocator)
	return mcp_tool_result(id,string(output),false)
}
