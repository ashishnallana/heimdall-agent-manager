package http

import "core:encoding/json"
import "core:crypto"
import "core:time"
import mcp "odin_test:hub/service/mcp"
import agent "odin_test:hub/service/agent"

mcp_catalog_write_call :: proc(h:^MCP_Control_Handlers,id:json.Value,raw:string,view:mcp.Access_View,tool:string,a:mcp.Catalog_Arguments,handle:mcp.Request_Handle,started:time.Tick)->Response {
	if h.mutate_catalog==nil || h.control.agents==nil do return mcp_tool_result(id,"request_failed",true)
	if tool!="agents.create" {_,found,err:=agent.get_agent(h.control.agents,mcp.control_auth(view.owner),a.agent_id);if !found || err.code!=.None do return mcp_tool_result(id,"not_found",true)}
	digest,digest_ok:=mcp.catalog_write_digest(a);if !digest_ok do return mcp_tool_result(id,"request_failed",true)
	fields:=make(json.Object,context.temp_allocator)
	if mcp.catalog_present(a,"name") do fields["name"]=json.String(a.name)
	if mcp.catalog_present(a,"slug") {fields["slug"]=json.String(a.slug)} else if tool=="agents.create" {fields["slug"]=json.String(a.name)}
	if mcp.catalog_present(a,"instructions") do fields["instructions"]=json.String(a.instructions)
	sealed:=make(json.Object,context.temp_allocator)
	if len(fields)>0 {
		op:=mcp.Control_Transform{tool=tool,agent_fields=fields}
		result:mcp.Delegation_Result
		if view.mode=="hosted" {result=mcp.hosted_with_access(h.delegation.service,h.delegation.grant_directory,raw,view.client,mcp.control_hosted_transform,&op)} else {result=mcp_device_transform(h,view,&op,handle,started)}
		defer if result.response!="" do crypto.zero_explicit(raw_data(result.response),len(result.response))
		if result.error=="invalid_token" do return mcp_unauthorized(h)
		if result.error!="" do return mcp_tool_result(id,result.error,true)
		value,perr:=json.parse_string(result.response,parse_integers=true,allocator=context.temp_allocator)
		obj,typed:=value.(json.Object);if perr!=nil || !typed || !mcp_task_sealed_fields(view,fields,obj) do return mcp_tool_result(id,"decryption_unavailable",true)
		sealed=obj
	}
	if time.tick_since(started)>=30*time.Second || mcp.request_cancelled(&h.requests,handle) do return mcp_tool_result(id,"cancelled",true)
	get :: proc(obj:json.Object,key:string)->string {value,_:=obj[key].(json.String);return string(value)}
	input:=agent.Create_Agent_Input{name=get(sealed,"name"),slug=get(sealed,"slug"),instructions=get(sealed,"instructions"),template_id=a.template_id,has_template_id=mcp.catalog_present(a,"template_id"),permission_mode=a.permission_mode}
	args:=a;args.name="";args.slug="";args.instructions=""
	result,code:=h.mutate_catalog(h.create_ctx,raw,view,{tool=tool,digest=digest,args=args,input=input})
	if code=="invalid_token" do return mcp_unauthorized(h)
	if code!="" do return mcp_tool_result(id,code,true)
	return mcp_tool_result(id,result,false)
}
