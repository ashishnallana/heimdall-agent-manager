package http

import "core:crypto"
import "core:encoding/json"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import domain "odin_test:hub/domain"
import auth "odin_test:hub/service/auth"
import mcp "odin_test:hub/service/mcp"
import tc "odin_test:hub/service/taskchain"
import vault "odin_test:lib/vault"

mcp_message_arguments :: proc(value:json.Value)->(mcp.Control_Arguments,bool) {
	obj,ok:=value.(json.Object);if !ok || len(obj)!=3 do return {},false
	args:mcp.Control_Arguments
	for key,v in obj {
		s,typed:=v.(json.String);if !typed do return {},false
		switch key {
		case "chain_id":if !mcp.control_id_ok(string(s)) do return {},false;args.chain_id=string(s)
		case "request_id":if len(s)<1 || len(s)>256 || !vault.valid_id_value(string(s)) do return {},false;args.request_id=string(s)
		case "body":if len(s)<1 || len(s)>20000 || strings.trim_space(string(s))=="" || !utf8.valid_string(string(s)) do return {},false;args.body=string(s)
		case:return {},false
		}
	}
	return args,args.chain_id!="" && args.request_id!="" && args.body!=""
}

mcp_chain_message_call :: proc(h:^MCP_Control_Handlers,id:json.Value,raw:string,view:mcp.Access_View,args:mcp.Control_Arguments,handle:mcp.Request_Handle,started:time.Tick)->Response {
	defer if args.body!="" do crypto.zero_explicit(raw_data(args.body),len(args.body))
	if h.message==nil do return mcp_tool_result(id,"request_failed",true)
	_,owned,err:=tc.get_chain_for_read(h.control.chains,mcp.control_auth(view.owner),domain.Task_Chain_ID(args.chain_id))
	if err.code!=.None && err.code!=.Not_Found && err.code!=.Forbidden do return mcp_tool_result(id,"request_failed",true)
	if !owned || err.code!=.None do return mcp_tool_result(id,"not_found",true)
	encoded,eerr:=json.marshal(struct {chain_id,body:string}{args.chain_id,args.body},allocator=context.temp_allocator)
	if eerr!=nil do return mcp_tool_result(id,"request_failed",true)
	digest:=auth.sha256_hex(string(encoded))
	defer if len(encoded)>0 do crypto.zero_explicit(raw_data(encoded),len(encoded))
	op:=mcp.Control_Transform{tool="chains.message",body=args.body}
	result:mcp.Delegation_Result
	if view.mode=="hosted" {result=mcp.hosted_with_access(h.delegation.service,h.delegation.grant_directory,raw,view.client,mcp.control_hosted_transform,&op)} else {result=mcp_device_transform(h,view,&op,handle,started)}
	defer if result.response!="" do crypto.zero_explicit(raw_data(result.response),len(result.response))
	if result.error=="invalid_token" do return mcp_unauthorized(h)
	if result.error!="" do return mcp_tool_result(id,result.error,true)
	if time.tick_since(started)>=30*time.Second || mcp.request_cancelled(&h.requests,handle) do return mcp_tool_result(id,"cancelled",true)
	obj,parsed:=mcp_parse_object(result.response);body,typed:=obj["body"].(json.String)
	if !parsed || len(obj)!=1 || !typed do return mcp_tool_result(id,"decryption_unavailable",true)
	vid,epoch,_,status:=vault.envelope_parse(string(body),context.temp_allocator);buf:[16]byte
	if status!=.Ok || epoch!=view.epoch || vault.vault_id_hex(vid,buf[:])!=view.vault_id do return mcp_tool_result(id,"decryption_unavailable",true)
	output,code:=h.message(h.create_ctx,raw,view,args.chain_id,args.request_id,digest,string(body))
	if code=="invalid_token" do return mcp_unauthorized(h)
	if code!="" do return mcp_tool_result(id,code,true)
	return mcp_tool_result(id,output,false)
}
