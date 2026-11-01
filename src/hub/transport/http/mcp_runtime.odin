package http

import "core:encoding/json"
import "core:strings"
import "core:time"
import mcp "odin_test:hub/service/mcp"
import vault "odin_test:lib/vault"

MCP_Runtime_Cancellation :: struct {h:^MCP_Control_Handlers,handle:mcp.Request_Handle,started:time.Tick}
mcp_runtime_cancelled :: proc(ctx:rawptr)->bool {p:=(^MCP_Runtime_Cancellation)(ctx);return time.tick_since(p.started)>=30*time.Second || mcp.request_cancelled(&p.h.requests,p.handle)}

mcp_runtime_arguments :: proc(tool:string,value:json.Value)->(mcp.Control_Arguments,bool) {
	obj,typed:=value.(json.Object);if !typed do return {},false
	a:mcp.Runtime_Arguments
	for key,value in obj {
		if key=="expected_operation_revision" {n,ok:=value.(json.Integer);if tool!="instances.reconfigure" || !ok || n<1 || n>2147483647 do return {},false;a.expected_operation_revision=int(n);continue}
		text,ok:=value.(json.String);if !ok do return {},false
		s:=string(text)
		switch key {
		case "agent_id":if tool!="instances.create" || !mcp_runtime_id(s,"agt_") do return {},false;a.agent_id=s
		case "agent_instance_id":if tool=="instances.create" || !mcp_runtime_id(s,"inst_") do return {},false;a.agent_instance_id=s
		case "bridge_id":if (tool!="instances.create" && tool!="instances.reconfigure") || !mcp_runtime_id(s,"brg_") do return {},false;a.bridge_id=s
		case "project_id":if (tool!="instances.create" && tool!="instances.reconfigure") || s!="" && !mcp_runtime_id(s,"proj_") do return {},false;a.project_id=s
		case "chain_id":if tool!="instances.create" || !mcp.control_id_ok(s) do return {},false;a.chain_id=s
		case "provider","provider_profile","model":
			if tool!="instances.create" && tool!="instances.reconfigure" || len(s)<1 || len(s)>256 || strings.trim_space(s)!=s do return {},false
			if key=="provider_profile" && !catalog_profile_valid(s) do return {},false
			if key=="provider" {a.provider=s} else if key=="provider_profile" {a.provider_profile=s} else {a.model=s}
		case "request_id":if len(s)<1 || len(s)>128 || !vault.valid_id_value(s) do return {},false;a.request_id=s
		case "expected_revision":if tool=="instances.operations" || len(s)!=64 do return {},false;for c in s do if !(c>='0' && c<='9' || c>='a' && c<='f') do return {},false;a.expected_revision=s
		case "operation_tool":if tool!="instances.operations" || !mcp.runtime_write(s) do return {},false;a.operation_tool=s
		case "retry_request_id":if tool!="instances.reconfigure" || len(s)<1 || len(s)>128 || !vault.valid_id_value(s) do return {},false;a.retry_request_id=s
		case:return {},false
		}
	}
	if a.request_id=="" do return {},false
	if (a.retry_request_id=="")!=(a.expected_operation_revision==0) || a.retry_request_id!="" && a.retry_request_id==a.request_id do return {},false
	if tool=="instances.operations" do return mcp.Control_Arguments{runtime=a},a.operation_tool!=""
	if a.expected_revision=="" do return {},false
	if tool=="instances.create" || tool=="instances.reconfigure" {
		_,project_present:=obj["project_id"]
		if !project_present || a.bridge_id=="" || a.provider=="" || a.provider_profile=="" || a.model=="" do return {},false
	}
	if tool=="instances.create" {if a.agent_id=="" || a.chain_id=="" do return {},false} else if a.agent_instance_id=="" do return {},false
	return mcp.Control_Arguments{runtime=a},true
}
mcp_runtime_id :: proc(s,prefix:string)->bool {return len(s)>len(prefix) && len(s)<=256 && strings.has_prefix(s,prefix) && vault.valid_id_value(s)}
