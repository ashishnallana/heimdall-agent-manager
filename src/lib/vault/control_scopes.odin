package vault

import "core:strings"

CONTROL_SCOPE_BASE :: "mcp:chains"
// Fixed order is part of the signed v2 consent. No wildcard or implication:
// write does not silently add read, runtime control or approval authority.
CONTROL_SCOPE_CAPABILITIES :: [15]string{
	"mcp:tasks:read", "mcp:tasks:write",
	"mcp:agents:read", "mcp:agents:write",
	"mcp:instances:read", "mcp:instances:control",
	"mcp:memories:read", "mcp:memories:write",
	"mcp:projects:read", "mcp:projects:write",
	"mcp:issues:read", "mcp:issues:write",
	"mcp:artifacts:read", "mcp:artifacts:write",
	"mcp:chains:message",
}
control_scopes_valid :: proc(scope:string)->bool {
	if scope==CONTROL_SCOPE_BASE do return true
	if len(scope)>1024 || !strings.has_prefix(scope,CONTROL_SCOPE_BASE+" ") do return false
	parts:=strings.split(scope," ",context.temp_allocator)
	if len(parts)<2 || len(parts)>len(CONTROL_SCOPE_CAPABILITIES)+1 do return false
	previous:=-1
	for part in parts[1:] {
		index:=-1
		for known,i in CONTROL_SCOPE_CAPABILITIES do if part==known do index=i
		if index<=previous do return false
		previous=index
	}
	return true
}
control_scope_has :: proc(scope,capability:string)->bool {
	if !control_scopes_valid(scope) do return false
	if capability==CONTROL_SCOPE_BASE do return true
	for part in strings.split(scope," ",context.temp_allocator) do if part==capability do return true
	return false
}
control_scope_subset :: proc(selected,requested:string)->bool {
	if !control_scopes_valid(selected) || !control_scopes_valid(requested) do return false
	for part in strings.split(selected," ",context.temp_allocator) do if !control_scope_has(requested,part) do return false
	return true
}
control_consent_version :: proc(scope:string)->int {
	if !control_scopes_valid(scope) do return 0
	return 1 if scope==CONTROL_SCOPE_BASE else 2
}
control_consent_domain :: proc(version:int)->string {
	if version==1 do return "heimdall-mcp-consent/v1\n"
	if version==2 do return "heimdall-mcp-consent/v2\n"
	return ""
}
