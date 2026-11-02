#+feature dynamic-literals
package http

import "core:encoding/json"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(test)
test_mcp_chain_create_required_coordinator_schema_and_runtime :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	tools:[]struct {name:string,inputSchema:struct {required:[]string,properties:json.Object}}
	if !testing.expect(t,json.unmarshal_string(#load("mcp_tools.json",string),&tools,.JSON,context.temp_allocator)==nil) do return
	seen:=false
	for tool in tools do if tool.name=="chains.create" {
		seen=true
		for name in ([]string{"title","coordinator_agent_id","bridge_id"}) {
			required:=false;for key in tool.inputSchema.required do if key==name do required=true
			testing.expectf(t,required,"%s must be required",name)
			prop,_:=tool.inputSchema.properties[name].(json.Object)
			testing.expect(t,prop["type"].(json.String)=="string")
		}
	}
	testing.expect(t,seen)
	f:=mcp_control_fixture(t);defer mcp_control_close(f)
	for invalid in ([]json.Value{nil,json.String(""),json.String(" "),json.String("agt_"),json.String("inst_wrong"),json.String("agt_bad value"),json.String("agt_bad/segment"),json.String(strings.repeat("a",257,context.temp_allocator)),json.Integer(12),json.Boolean(true),json.Array{},json.Object{}}) {
		for field in ([]string{"coordinator_agent_id","bridge_id"}) {
			args:=json.Object{"title"=json.String("Must not create"),"coordinator_agent_id"=json.String("agt_fixture"),"bridge_id"=json.String("brg_fixture")}
			if invalid==nil {delete_key(&args,field)} else {args[field]=invalid}
			_,ok:=mcp_arguments("chains.create",args);testing.expectf(t,!ok,"invalid %s must fail",field)
			body,_:=json.marshal(json.Object{"jsonrpc"=json.String("2.0"),"id"=json.Integer(1),"method"=json.String("tools/call"),"params"=json.Object{"name"=json.String("chains.create"),"arguments"=args}},allocator=context.temp_allocator)
			response:=mcp_control_request(&f.h,f.token,string(body))
			testing.expect(t,strings.contains(response.body,"-32602"))
		}
	}
	rows,_:=iface.taskchain_list_chains_by_owner(&f.trepo,domain.User_ID(f.state.vector.request.owner))
	testing.expect_value(t,len(rows),1)
	_,ok:=mcp_arguments("chains.create",json.Object{"title"=json.String("Valid"),"coordinator_agent_id"=json.String("agt_fixture"),"bridge_id"=json.String("brg_fixture"),"provider"=json.String("codex"),"provider_profile"=json.String("codex"),"model"=json.String("default")})
	testing.expect(t,ok)
}
