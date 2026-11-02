package mcp

import "core:testing"

@(test)
capabilities_legacy_and_explicit_rights :: proc(t:^testing.T) {
	for tool in ([]string{"chains.list","chains.get","events.wait"}) do testing.expect(t,scope_allows_tool(DELEGATION_SCOPE,tool))
	for tool in ([]string{"chains.create","tasks.comment","tasks.review","agents.create","instances.start","memories.approve","artifacts.get","messages.send","lease.next","unknown"}) do testing.expect(t,!scope_allows_tool(DELEGATION_SCOPE,tool),tool)
	testing.expect(t,scope_allows_tool("mcp:chains mcp:instances:control","chains.create"))
	scope:="mcp:chains mcp:tasks:read mcp:artifacts:write"
	testing.expect(t,scope_allows_tool(scope,"tasks.get"))
	testing.expect(t,scope_allows_tool(scope,"artifacts.create"))
	testing.expect(t,!scope_allows_tool(scope,"artifacts.get"))
	testing.expect(t,!scope_allows_tool(scope,"tasks.comment"))
	testing.expect(t,!scope_allows_tool(scope,"messages.send"))
	canonical,ok:=canonical_scopes("mcp:artifacts:write mcp:tasks:read mcp:chains")
	testing.expect(t,ok && canonical==scope)
	for bad in ([]string{"mcp:chains mcp:chains","mcp:tasks:read","mcp:chains mcp:messages:write","mcp:chains\tmcp:tasks:read"}) {
		_,valid:=canonical_scopes(bad)
		testing.expect(t,!valid,bad)
	}
}
