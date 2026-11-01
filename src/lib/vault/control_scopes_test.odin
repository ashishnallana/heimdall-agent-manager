package vault

import "core:testing"

@(test)
control_scopes_canonical_and_versioned :: proc(t:^testing.T) {
	testing.expect(t,control_consent_version("mcp:chains")==1)
	scope:="mcp:chains mcp:tasks:read mcp:tasks:write mcp:artifacts:read"
	testing.expect(t,control_scopes_valid(scope) && control_consent_version(scope)==2)
	testing.expect(t,control_scope_has(scope,"mcp:tasks:write"))
	testing.expect(t,!control_scope_has(scope,"mcp:instances:control"))
	testing.expect(t,control_scope_subset("mcp:chains mcp:tasks:read",scope))
	testing.expect(t,!control_scope_subset(scope,"mcp:chains"))
	for bad in ([]string{"","mcp:tasks:read","mcp:chains ","mcp:chains  mcp:tasks:read","mcp:chains mcp:tasks:read mcp:tasks:read","mcp:chains mcp:tasks:write mcp:tasks:read","mcp:chains mcp:unknown","mcp:chains mcp:messages:write"}) {
		testing.expect(t,!control_scopes_valid(bad),bad)
		testing.expect(t,control_consent_version(bad)==0,bad)
	}
	testing.expect(t,control_consent_domain(1)!=control_consent_domain(2))
	testing.expect(t,control_consent_domain(3)=="")
}
