package http

import "core:encoding/json"
import "core:crypto"
import "core:strings"
import "core:unicode/utf8"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import mcp "odin_test:hub/service/mcp"
import vault "odin_test:lib/vault"

mcp_resource_allowed :: proc(tool,key:string)->bool {
	allowed:string
	switch tool {
	case "artifacts.list":allowed="|project_id|chain_id|task_id|agent_id|agent_instance_id|cursor|limit|"
	case "artifacts.get":allowed="|artifact_id|include_content|"
	case "artifacts.create":allowed="|request_id|name|description|content|content_type|project_id|chain_id|task_id|agent_id|agent_instance_id|"
	case "artifacts.update":allowed="|artifact_id|request_id|expected_revision|name|description|"
	case "artifacts.delete":allowed="|artifact_id|request_id|expected_revision|"
	case "memories.list":allowed="|status|type|agent_id|project_id|bridge_id|template_id|cursor|limit|"
	case "memories.get":allowed="|memory_id|"
	case "memories.create":allowed="|request_id|title|description|body|evidence|type|expires_at|agent_ids|project_ids|bridge_ids|template_ids|"
	case "memories.update":allowed="|memory_id|request_id|expected_revision|title|description|body|evidence|type|expires_at|agent_ids|project_ids|bridge_ids|template_ids|"
	case "memories.archive":allowed="|memory_id|request_id|expected_revision|"
	case "projects.list":allowed="|state|cursor|limit|"
	case "projects.get":allowed="|project_id|"
	case "projects.create":allowed="|request_id|name|description|slug|repo_url|vcs_kind|default_path|bridge_paths|"
	case "projects.update":allowed="|project_id|request_id|expected_revision|name|description|slug|repo_url|vcs_kind|default_path|bridge_paths|"
	case "projects.archive":allowed="|project_id|request_id|expected_revision|"
	case "issues.list":allowed="|status|scope_type|target_id|chain_id|cursor|limit|"
	case "issues.get":allowed="|issue_id|include_comments|comment_limit|comment_cursor|"
	case "issues.create":allowed="|request_id|title|description|scope_type|target_id|chain_id|"
	case "issues.update":allowed="|issue_id|request_id|expected_revision|title|description|status|scope_type|target_id|chain_id|"
	case "issues.delete":allowed="|issue_id|request_id|expected_revision|"
	case "issues.comment":allowed="|issue_id|request_id|expected_revision|body|"
	case:return false
	}
	return strings.contains(allowed,strings.concatenate({"|",key,"|"},context.temp_allocator))
}
mcp_resource_arguments :: proc(tool:string,value:json.Value)->(mcp.Control_Arguments,bool) {
	obj,typed:=value.(json.Object);if value==nil {obj=make(json.Object,context.temp_allocator);typed=true};if !typed do return {},false
	a:=mcp.Resource_Arguments{fields=make(json.Object,context.temp_allocator),include_content=tool=="artifacts.get"}
	for key,value in obj {
		if !mcp_resource_allowed(tool,key) do return {},false
		for known,i in mcp.RESOURCE_KEYS do if known==key do a.present|=u64(1)<<u64(i)
		switch key {
		case "limit","comment_limit":n,ok:=value.(json.Integer);if !ok || n<1 || n>100 do return {},false;if key=="limit" {a.limit=int(n)} else {a.comment_limit=int(n)}
		case "include_content":v,ok:=value.(json.Boolean);if !ok do return {},false;a.include_content=bool(v)
		case "include_comments":v,ok:=value.(json.Boolean);if !ok do return {},false;a.include_comments=bool(v)
		case "bridge_paths":
			items,ok:=value.(json.Array);if !ok || len(items)>20 do return {},false
			paths:=make([dynamic]mcp.Resource_Bridge_Path,context.temp_allocator);seen:=make(map[string]bool,context.temp_allocator)
			for item in items {row,ok:=item.(json.Object);if !ok || len(row)!=2 do return {},false;id,id_ok:=row["bridge_id"].(json.String);path,path_ok:=row["path"].(json.String);if !id_ok || !path_ok || !mcp_runtime_id(string(id),"brg_") || len(path)>4096 || seen[string(id)] do return {},false;seen[string(id)]=true;append(&paths,mcp.Resource_Bridge_Path{string(id),string(path)})};a.bridge_paths=paths[:]
		case "agent_ids","project_ids","bridge_ids","template_ids":
			items,ok:=value.(json.Array);if !ok || len(items)>100 do return {},false
			prefix:="agt_";if key=="project_ids" do prefix="proj_";if key=="bridge_ids" do prefix="brg_";if key=="template_ids" do prefix="tmpl_"
			ids:=make([dynamic]string,context.temp_allocator);seen:=make(map[string]bool,context.temp_allocator)
			for item in items {text,ok:=item.(json.String);if !ok || !mcp_runtime_id(string(text),prefix) || seen[string(text)] do return {},false;seen[string(text)]=true;append(&ids,string(text))}
			if key=="agent_ids" {a.agent_ids=ids[:]} else if key=="project_ids" {a.project_ids=ids[:]} else if key=="bridge_ids" {a.bridge_ids=ids[:]} else {a.template_ids=ids[:]}
		case:
			text,ok:=value.(json.String);if !ok do return {},false;s:=string(text)
			switch key {
			case "name","title","description","body","evidence","content":
				limit:=20000;if key=="name" || key=="title" do limit=500;if key=="body" && mcp.resource_kind(tool)=="memory" do limit=65536
				if key=="content" do limit=65536
				if !utf8.valid_string(s) || strings.contains(s,"\x00") || len(s)>limit || (key=="name" || key=="title" || key=="body") && strings.trim_space(s)=="" do return {},false;a.fields[key]=text
			case "artifact_id":if !mcp_runtime_id(s,"art_") do return {},false;a.id=s
			case "task_id":if !mcp_runtime_id(s,"task_") do return {},false;a.task_id=s
			case "agent_instance_id":if !mcp_runtime_id(s,"inst_") do return {},false;a.agent_instance_id=s
			case "content_type":if s!="text/plain" && s!="text/markdown" && s!="application/json" do return {},false;a.content_type=s
			case "memory_id":if !mcp_runtime_id(s,"mem_") do return {},false;a.id=s
			case "issue_id":if !mcp_runtime_id(s,"iss_") do return {},false;a.id=s
			case "project_id":if !mcp_runtime_id(s,"proj_") do return {},false;if mcp.resource_kind(tool)=="project" {a.id=s} else {a.project_id=s}
			case "agent_id","bridge_id","template_id":prefix:="agt_";if key=="bridge_id" do prefix="brg_";if key=="template_id" do prefix="tmpl_";if !mcp_runtime_id(s,prefix) do return {},false;if key=="agent_id" {a.agent_id=s} else if key=="bridge_id" {a.bridge_id=s} else {a.template_id=s}
			case "request_id":if len(s)<1 || len(s)>128 || !vault.valid_id_value(s) do return {},false;a.request_id=s
			case "expected_revision":if len(s)!=64 do return {},false;for c in s do if !(c>='a' && c<='f' || c>='0' && c<='9') do return {},false;a.expected_revision=s
			case "cursor","comment_cursor":if len(s)>2048 do return {},false;if key=="cursor" {a.cursor=s} else {a.comment_cursor=s}
			case "status","state":
				valid:=false;kind:=mcp.resource_kind(tool)
				if kind=="memory" do valid=s=="pending" || s=="active" || s=="archived" || s=="rejected"
				if kind=="project" do valid=s=="active" || s=="archived"
				if kind=="issue" do valid=s=="new" || s=="fixed" || s=="obsolete"
				if !valid do return {},false;a.status=s
			case "type":t:=domain.memory_type_from_string(s);if t==.Unknown || domain.memory_type_string(t)!=s do return {},false;a.type=s
			case "expires_at":if len(s)>64 do return {},false;if s!="" {_,valid:=platform.parse_rfc3339_utc(s);if !valid do return {},false};a.expires_at=s
			case "slug":if len(s)<1 || len(s)>500 || strings.trim_space(s)=="" do return {},false;a.slug=s
			case "repo_url","default_path":if len(s)>4096 || key=="default_path" && strings.trim_space(s)=="" do return {},false;if key=="repo_url" {a.repo_url=s} else {a.default_path=s}
			case "vcs_kind":if s!="" && s!="git" && s!="jj" && s!="none" do return {},false;a.vcs_kind=s
			case "scope_type":if s!="global" && s!="project" && s!="agent_id" && s!="bridge_id" do return {},false;a.scope_type=s
			case "target_id":if s!="" && (len(s)>256 || !vault.valid_id_value(s)) do return {},false;a.target_id=s
			case "chain_id":if s!="" && !mcp.control_id_ok(s) do return {},false;a.chain_id=s
			case:return {},false
			}
		}
	}
	if strings.has_suffix(tool,".list") do return mcp.Control_Arguments{resource=a},true
	if strings.has_suffix(tool,".get") do return mcp.Control_Arguments{resource=a},a.id!="" && (a.include_comments || a.comment_limit==0 && a.comment_cursor=="")
	if tool=="artifacts.create" {
		if mcp.resource_text(a.fields,"name")=="" || !mcp.resource_present(a,"content") || a.content_type=="" do return {},false
		if a.content_type=="application/json" {
			candidate:=strings.clone(mcp.resource_text(a.fields,"content"),context.temp_allocator)
			defer if len(candidate)>0 do crypto.zero_explicit(raw_data(candidate),len(candidate))
			parser:=json.make_parser_from_string(candidate,.JSON,true,context.temp_allocator);value,e:=json.parse_value(&parser);defer vault.control_wipe_value(value)
			if e!=nil || parser.curr_token.kind!=.EOF do return {},false
		}
	}
	if a.request_id=="" do return {},false
	if !strings.has_suffix(tool,".create") && (a.id=="" || a.expected_revision=="") do return {},false
	if strings.has_suffix(tool,".update") && len(obj)<=3 do return {},false
	if tool=="memories.create" && mcp.resource_text(a.fields,"body")=="" || tool=="issues.create" && mcp.resource_text(a.fields,"title")=="" || tool=="issues.comment" && mcp.resource_text(a.fields,"body")=="" || tool=="projects.create" && (mcp.resource_text(a.fields,"name")=="" || a.default_path=="") do return {},false
	return mcp.Control_Arguments{resource=a},true
}
