package mcp

import "core:encoding/json"
import "core:strings"
import "core:crypto"
import auth "odin_test:hub/service/auth"

// Append-only: persisted write digests bind these field-presence bit positions.
RESOURCE_KEYS :: [?]string{"memory_id","project_id","issue_id","request_id","expected_revision","title","description","body","evidence","type","expires_at","agent_ids","project_ids","bridge_ids","template_ids","name","slug","repo_url","vcs_kind","default_path","bridge_paths","status","state","scope_type","target_id","chain_id","agent_id","bridge_id","template_id","cursor","limit","include_comments","comment_limit","comment_cursor"}
Resource_Bridge_Path :: struct {bridge_id,path:string}
Resource_Arguments :: struct {
	id,request_id,expected_revision,status,type,expires_at,slug,repo_url,vcs_kind,default_path,scope_type,target_id,chain_id,agent_id,project_id,bridge_id,template_id,cursor,comment_cursor:string,
	agent_ids,project_ids,bridge_ids,template_ids:[]string,
	bridge_paths:[]Resource_Bridge_Path,
	fields:json.Object,
	present:u64,
	limit,comment_limit:int,
	include_comments:bool,
}
resource_present :: proc(a:Resource_Arguments,key:string)->bool {for k,i in RESOURCE_KEYS do if k==key do return a.present & (u64(1)<<u64(i))!=0;return false}
resource_kind :: proc(tool:string)->string {if strings.has_prefix(tool,"memories.") do return "memory";if strings.has_prefix(tool,"projects.") do return "project";if strings.has_prefix(tool,"issues.") do return "issue";return ""}
resource_tool :: proc(tool:string)->bool {switch tool {case "memories.list","memories.get","memories.create","memories.update","memories.archive","projects.list","projects.get","projects.create","projects.update","projects.archive","issues.list","issues.get","issues.create","issues.update","issues.delete","issues.comment":return true};return false}
resource_write :: proc(tool:string)->bool {return resource_tool(tool) && !strings.has_suffix(tool,".list") && !strings.has_suffix(tool,".get")}
Resource_Command :: struct {tool,digest:string,args:Resource_Arguments,sealed:json.Object,replay_only:bool}
Resource_Mutate_Proc :: proc(ctx:rawptr,raw:string,view:Access_View,command:Resource_Command)->(string,string)
Resource_Result :: struct {resource_id,kind,status,state,revision,comment_id:string,changed:bool}
Resource_Cursor :: struct {owner,tool,status,type,agent_id,project_id,bridge_id,template_id,scope_type,target_id,chain_id,parent_id,created_at,id:string}
resource_cursor :: proc(owner,tool:string,a:Resource_Arguments,text,parent:string)->(Resource_Cursor,bool) {
	c:=Resource_Cursor{owner=owner,tool=tool,status=a.status,type=a.type,agent_id=a.agent_id,project_id=a.project_id,bridge_id=a.bridge_id,template_id=a.template_id,scope_type=a.scope_type,target_id=a.target_id,chain_id=a.chain_id,parent_id=parent}
	if text=="" do return c,true
	p:Resource_Cursor;if json.unmarshal_string(text,&p,.JSON,context.temp_allocator)!=nil do return {},false
	created,id:=p.created_at,p.id;p.created_at="";p.id=""
	if p!=c || id=="" || len(id)>256 || created=="" || len(created)>64 do return {},false
	p.created_at=created;p.id=id;encoded,_:=json.marshal(p,allocator=context.temp_allocator)
	return p,string(encoded)==text
}
resource_next :: proc(c:Resource_Cursor,created,id:string)->string {next:=c;next.created_at=created;next.id=id;encoded,_:=json.marshal(next,allocator=context.temp_allocator);return string(encoded)}
resource_digest :: proc(value:$T)->string {encoded,_:=json.marshal(value,allocator=context.temp_allocator);defer if len(encoded)>0 do crypto.zero_explicit(raw_data(encoded),len(encoded));return auth.sha256_hex(string(encoded))}
resource_write_digest :: proc(a:Resource_Arguments)->string {
	// Keep read/filter additions outside the versioned write digest.
	text:=struct {title,description,body,evidence,name:string}{resource_text(a.fields,"title"),resource_text(a.fields,"description"),resource_text(a.fields,"body"),resource_text(a.fields,"evidence"),resource_text(a.fields,"name")}
	return resource_digest(struct {v:int,id,request_id,expected_revision,status,type,expires_at,slug,repo_url,vcs_kind,default_path,scope_type,target_id,chain_id:string,agent_ids,project_ids,bridge_ids,template_ids:[]string,bridge_paths:[]Resource_Bridge_Path,fields:type_of(text),present:u64}{1,a.id,a.request_id,a.expected_revision,a.status,a.type,a.expires_at,a.slug,a.repo_url,a.vcs_kind,a.default_path,a.scope_type,a.target_id,a.chain_id,a.agent_ids,a.project_ids,a.bridge_ids,a.template_ids,a.bridge_paths,text,a.present})
}
resource_text :: proc(fields:json.Object,key:string)->string {value,_:=fields[key].(json.String);return string(value)}
