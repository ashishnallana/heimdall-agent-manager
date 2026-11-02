#+feature dynamic-literals
package http

import "core:encoding/json"
import "core:strings"
import "core:testing"
import mcp "odin_test:hub/service/mcp"

@(test)
test_mcp_chain_message_arguments_and_scope :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	valid:=json.Object{"chain_id"=json.String("chain_example"),"request_id"=json.String("request_once"),"body"=json.String("Hello coordinator")}
	_,ok:=mcp_arguments("chains.message",valid);testing.expect(t,ok)
	for field in ([]string{"chain_id","request_id","body"}) {
		original:=valid[field]
		for bad in ([]json.Value{nil,json.Integer(1),json.Boolean(true),json.String(""),json.String(" "),json.Array{},json.Object{}}) {
			if bad==nil {delete_key(&valid,field)} else {valid[field]=bad}
			_,accepted:=mcp_arguments("chains.message",valid);testing.expectf(t,!accepted,"reject invalid %s",field)
		}
		valid[field]=original
	}
	for forbidden in ([]string{"owner","conversation_id","coordinator_agent_instance_id","direction","message_type","artifact_ids","actions","options"}) {
		valid[forbidden]=json.String("must reject");_,accepted:=mcp_arguments("chains.message",valid);testing.expect(t,!accepted);delete_key(&valid,forbidden)
	}
	valid["body"]=json.String(strings.repeat("é",10000,context.temp_allocator));_,ok=mcp_arguments("chains.message",valid);testing.expect(t,ok)
	valid["body"]=json.String(strings.repeat("é",10001,context.temp_allocator));_,ok=mcp_arguments("chains.message",valid);testing.expect(t,!ok)
	for scope in ([]string{"mcp:chains","mcp:chains mcp:tasks:write","mcp:chains mcp:instances:control"}) do testing.expect(t,!mcp.scope_allows_tool(scope,"chains.message"))
	testing.expect(t,mcp.scope_allows_tool("mcp:chains mcp:chains:message","chains.message"))
	// Existing read-only grants neither advertise nor accept this new operation.
	f:=mcp_control_fixture(t);defer mcp_control_close(f)
	list:=mcp_control_request(&f.h,f.token,`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
	testing.expect(t,!strings.contains(list.body,"chains.message"))
	call:=mcp_control_request(&f.h,f.token,`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"chains.message","arguments":{"chain_id":"chain_fixture","request_id":"denied","body":"Denied"}}}`)
	testing.expect(t,strings.contains(call.body,"scope_missing"))
}
