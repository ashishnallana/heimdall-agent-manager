package mcp

import "core:strings"
import "core:testing"

@(test)
capabilities_legacy_and_explicit_rights :: proc(t:^testing.T) {
	for tool in ([]string{"chains.list","chains.get","chains.create","events.wait"}) do testing.expect(t,scope_allows_tool(DELEGATION_SCOPE,tool))
	for tool in ([]string{"tasks.comment","tasks.review","agents.create","instances.start","memories.approve","artifacts.get","messages.send","lease.next","unknown"}) do testing.expect(t,!scope_allows_tool(DELEGATION_SCOPE,tool),tool)
	scope:="mcp:chains mcp:tasks:read mcp:artifacts:write"
	testing.expect(t,scope_allows_tool(scope,"tasks.get"))
	testing.expect(t,scope_allows_tool(scope,"artifacts.create"))
	testing.expect(t,!scope_allows_tool(scope,"artifacts.get"))
	testing.expect(t,!scope_allows_tool(scope,"tasks.comment"))
	testing.expect(t,!scope_allows_tool(scope,"messages.send"))
	canonical,ok:=canonical_scopes("mcp:artifacts:write mcp:tasks:read mcp:chains")
	testing.expect(t,ok && canonical==scope)
	// An omitted scope requests every capability, DELEGATION_SCOPE first;
	// consent (not the request) decides what the token receives.
	all,all_ok:=canonical_scopes("")
	testing.expect(t,all_ok && all==supported_scope_string())
	testing.expect(t,strings.has_prefix(all,DELEGATION_SCOPE+" "))
	testing.expect_value(t,len(strings.split(all," ",context.temp_allocator)),len(supported_scopes()))
	explicit,explicit_ok:=canonical_scopes(all)
	testing.expect(t,explicit_ok && explicit==all,"the full list is already canonical")
	only,only_ok:=canonical_scopes(DELEGATION_SCOPE)
	testing.expect(t,only_ok && only==DELEGATION_SCOPE,"an explicit subset is honored")
	for bad in ([]string{"mcp:chains mcp:chains","mcp:tasks:read","mcp:chains mcp:messages:write","mcp:chains\tmcp:tasks:read"}) {
		_,valid:=canonical_scopes(bad)
		testing.expect(t,!valid,bad)
	}
}
