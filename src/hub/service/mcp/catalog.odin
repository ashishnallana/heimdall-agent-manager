package mcp

import "core:encoding/json"
import "core:crypto"
import "core:slice"
import auth "odin_test:hub/service/auth"
import agent "odin_test:hub/service/agent"
import iface "odin_test:hub/repository/iface"
import domain "odin_test:hub/domain"

CATALOG_KEYS :: [?]string{"agent_id","agent_instance_id","bridge_id","state","cursor","limit","request_id","expected_revision","name","slug","instructions","template_id","permission_mode","supports","provider_profile","model_limit","model_cursor"}
Catalog_Arguments :: struct {
	agent_id,agent_instance_id,bridge_id,state,cursor,request_id,expected_revision,name,slug,instructions,template_id,permission_mode:string,
	limit:int,
	supports:[]agent.Support_Input,
	present:u64,
	provider_profile,model_cursor:string,
	model_limit:int,
}
catalog_present :: proc(a:Catalog_Arguments,key:string)->bool {for k,i in CATALOG_KEYS do if key==k do return a.present & (u64(1)<<u64(i))!=0;return false}
catalog_tool :: proc(tool:string)->bool {switch tool {case "agents.list","agents.get","agents.create","agents.update","agents.archive","bridges.list","providers.list","instances.list","instances.get":return true};return false}
catalog_write :: proc(tool:string)->bool {return tool=="agents.create" || tool=="agents.update" || tool=="agents.archive"}
catalog_write_digest :: proc(a:Catalog_Arguments)->(string,bool) {
	// Read/runtime argument additions must not change successful agent retries.
	binding:=struct {v:int,agent_id,request_id,expected_revision,name,slug,instructions,template_id,permission_mode:string,supports:[]agent.Support_Input,present:u64}{1,a.agent_id,a.request_id,a.expected_revision,a.name,a.slug,a.instructions,a.template_id,a.permission_mode,a.supports,a.present}
	encoded,err:=json.marshal(binding,allocator=context.temp_allocator)
	defer if len(encoded)>0 do crypto.zero_explicit(raw_data(encoded),len(encoded))
	if err!=nil do return "",false
	return auth.sha256_hex(string(encoded)),true
}
catalog_agent_revision :: proc(s:^Control_Service,a:domain.Agent)->(string,bool) {
	supports,err:=agent.list_support(s.agents,control_auth(string(a.owner_user_id)),a.agent_id)
	if err.code!=.None do return "",false
	slice.sort_by(supports,proc(a,b:domain.Agent_Bridge_Support)->bool {return a.bridge_id<b.bridge_id})
	encoded,eerr:=json.marshal(struct {agent:domain.Agent,supports:[]domain.Agent_Bridge_Support}{a,supports},allocator=context.temp_allocator)
	defer if len(encoded)>0 do crypto.zero_explicit(raw_data(encoded),len(encoded))
	return auth.sha256_hex(string(encoded)),eerr==nil
}
Catalog_Command :: struct {tool,digest:string,args:Catalog_Arguments,input:agent.Create_Agent_Input}
Catalog_Mutate_Proc :: proc(ctx:rawptr,raw:string,view:Access_View,command:Catalog_Command)->(string,string)
Catalog_Result :: struct {resource_id,agent_id,state,revision,status:string,changed:bool,applied_fields:[]string}
Catalog_Cursor :: struct {owner,tool,agent_id,bridge_id,state,created_at,id,provider_profile:string}
catalog_cursor :: proc(owner,tool:string,a:Catalog_Arguments)->(Catalog_Cursor,bool) {
	c:=Catalog_Cursor{owner=owner,tool=tool,agent_id=a.agent_id,bridge_id=a.bridge_id,state=a.state,provider_profile=a.provider_profile}
	if a.cursor=="" do return c,true
	parsed:Catalog_Cursor
	if json.unmarshal_string(a.cursor,&parsed,.JSON,context.temp_allocator)!=nil do return {},false
	encoded,err:=json.marshal(parsed,allocator=context.temp_allocator)
	if err!=nil || string(encoded)!=a.cursor || parsed.owner!=owner || parsed.tool!=tool || parsed.agent_id!=a.agent_id || parsed.bridge_id!=a.bridge_id || parsed.state!=a.state || parsed.provider_profile!=a.provider_profile || parsed.id=="" || parsed.created_at=="" || len(parsed.id)>512 || len(parsed.created_at)>64 do return {},false
	return parsed,true
}
catalog_next :: proc(c:Catalog_Cursor,created_at,id:string)->string {next:=c;next.created_at=created_at;next.id=id;encoded,_:=json.marshal(next,allocator=context.temp_allocator);return string(encoded)}
catalog_ref_after :: proc(c:Catalog_Cursor,created_at,id:string)->bool {return created_at>c.created_at || created_at==c.created_at && id>c.id}
catalog_query :: proc(owner:string,c:Catalog_Cursor,limit:int)->iface.Agent_Catalog_Query {return {owner=domain.User_ID(owner),after_created=c.created_at,after_id=c.id,state=c.state,agent_id=c.agent_id,bridge_id=c.bridge_id,limit=limit+1}}
