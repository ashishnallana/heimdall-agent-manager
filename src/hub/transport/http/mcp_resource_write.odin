package http

import "core:encoding/json"
import "core:crypto"
import "core:time"
import mcp "odin_test:hub/service/mcp"

mcp_resource_write_call :: proc(h:^MCP_Control_Handlers,id:json.Value,raw:string,view:mcp.Access_View,tool:string,a:mcp.Resource_Arguments,handle:mcp.Request_Handle,started:time.Tick)->Response {
	if h.mutate_resource==nil do return mcp_tool_result(id,"request_failed",true)
	digest:=mcp.resource_write_digest(a);args:=a;args.fields=nil
	// Probe before encryption/ownership lookups: destructive issue retries must
	// remain valid after the resource and its comments have been deleted.
	prior,prior_code:=h.mutate_resource(h.create_ctx,raw,view,{tool=tool,digest=digest,args=args,replay_only=true})
	if prior_code=="invalid_token" do return mcp_unauthorized(h)
	if prior_code=="" do return mcp_tool_result(id,prior,false)
	if prior_code!="receipt_missing" do return mcp_tool_result(id,prior_code,true)
	if a.id!="" {
		row,_,code:=mcp.resource_get(&h.control,view.owner,mcp.resource_kind(tool),a.id,false)
		if code!="" do return mcp_tool_result(id,code,true)
		if read_only,_:=row["read_only"].(json.Boolean);bool(read_only) do return mcp_tool_result(id,"read_only",true)
	}
	sealed:=make(json.Object,context.temp_allocator)
	if len(a.fields)>0 {
		op:=mcp.Control_Transform{tool=tool,resource_fields=a.fields};result:mcp.Delegation_Result
		if view.mode=="hosted" {result=mcp.hosted_with_access(h.delegation.service,h.delegation.grant_directory,raw,view.client,mcp.control_hosted_transform,&op)} else {result=mcp_device_transform(h,view,&op,handle,started)}
		defer if result.response!="" do crypto.zero_explicit(raw_data(result.response),len(result.response))
		if result.error=="invalid_token" do return mcp_unauthorized(h)
		if result.error!="" do return mcp_tool_result(id,result.error,true)
		value,err:=json.parse_string(result.response,parse_integers=true,allocator=context.temp_allocator)
		obj,typed:=value.(json.Object);if err!=nil || !typed || !mcp_task_sealed_fields(view,a.fields,obj) do return mcp_tool_result(id,"decryption_unavailable",true)
		sealed=obj
	}
	if time.tick_since(started)>=30*time.Second || mcp.request_cancelled(&h.requests,handle) do return mcp_tool_result(id,"cancelled",true)
	result,code:=h.mutate_resource(h.create_ctx,raw,view,{tool=tool,digest=digest,args=args,sealed=sealed})
	if code=="invalid_token" do return mcp_unauthorized(h)
	if code!="" do return mcp_tool_result(id,code,true)
	return mcp_tool_result(id,result,false)
}
