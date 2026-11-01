#+feature dynamic-literals
package http

import "core:testing"
import "core:encoding/json"
import "core:strings"

mcp_resource_legacy_assertions :: proc(t:^testing.T,f:^MCP_Control_Fixture) {
	for family in ([]string{"memories","projects","issues"}) {
		for action in ([]string{"list","get","create","update","archive","comment"}) {
			if action=="comment" && family!="issues" do continue
			verb:=action;if family=="issues" && verb=="archive" do verb="delete"
			tool:=strings.concatenate({family,".",verb},context.temp_allocator)
			args:=make(json.Object,context.temp_allocator)
			if action!="list" && action!="create" {key,id:="memory_id","mem_fixture";if family=="projects" {key="project_id";id="proj_fixture"};if family=="issues" {key="issue_id";id="iss_fixture"};args[key]=json.String(id)}
			if action!="list" && action!="get" {args["request_id"]=json.String("legacy_resource_denied");if action!="create" do args["expected_revision"]=json.String(strings.repeat("0",64,context.temp_allocator))}
			if action=="create" || action=="update" {if family=="projects" {args["name"]=json.String("No write");if action=="create" do args["default_path"]=json.String("/none")} else if family=="memories" {args["body"]=json.String("No write")} else {args["title"]=json.String("No write")}}
			if action=="comment" do args["body"]=json.String("No write")
			encoded,_:=json.marshal(struct {jsonrpc:string,id:int,method:string,params:struct {name:string,arguments:json.Object}}{"2.0",100,"tools/call",{tool,args}},allocator=context.temp_allocator)
			response:=mcp_control_request(&f.h,f.token,string(encoded))
			testing.expectf(t,strings.contains(response.body,"scope_missing"),"legacy %s: %s",tool,response.body)
		}
	}
}
