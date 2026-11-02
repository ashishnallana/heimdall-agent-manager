package mcp

import vault "odin_test:lib/vault"
import "core:strings"

scopes_valid :: vault.control_scopes_valid
scope_subset :: vault.control_scope_subset
consent_version :: vault.control_consent_version

// OAuth scope order is immaterial; normalize before putting it in signed data.
canonical_scopes :: proc(raw:string)->(string,bool) {
	if raw=="" do return DELEGATION_SCOPE,true
	if len(raw)>1024 do return "",false
	parts:=strings.split(raw," ",context.temp_allocator)
	seen:=make(map[string]bool,context.temp_allocator)
	for part in parts {
		known:=part==DELEGATION_SCOPE
		for capability in vault.CONTROL_SCOPE_CAPABILITIES do if part==capability do known=true
		if !known || seen[part] do return "",false
		seen[part]=true
	}
	if !seen[DELEGATION_SCOPE] do return "",false
	b:=strings.builder_make(context.temp_allocator)
	strings.write_string(&b,DELEGATION_SCOPE)
	for capability in vault.CONTROL_SCOPE_CAPABILITIES do if seen[capability] {strings.write_byte(&b,' ');strings.write_string(&b,capability)}
	return strings.to_string(b),true
}

supported_scopes :: proc()->[]string {
	out:=make([]string,len(vault.CONTROL_SCOPE_CAPABILITIES)+1,context.temp_allocator)
	out[0]=DELEGATION_SCOPE
	for value,i in vault.CONTROL_SCOPE_CAPABILITIES do out[i+1]=value
	return out
}
// Authorization is independent of the tool catalog: defining a capability
// never advertises or activates an unimplemented operation.
scope_allows_tool :: proc(scope,tool:string)->bool {
	if !scopes_valid(scope) do return false
	capability:string
	switch tool {
	case "chains.list","chains.get","chains.create","events.wait":capability=DELEGATION_SCOPE
	case "chains.message":capability="mcp:chains:message"
	case "tasks.list","tasks.get":capability="mcp:tasks:read"
	case "tasks.create","tasks.update","tasks.comment","tasks.control","chains.configure":capability="mcp:tasks:write"
	case "agents.list","agents.get":capability="mcp:agents:read"
	case "agents.create","agents.update","agents.archive":capability="mcp:agents:write"
	case "instances.list","instances.get","instances.operations","bridges.list","providers.list":capability="mcp:instances:read"
	case "instances.create","instances.start","instances.stop","instances.reconfigure":capability="mcp:instances:control"
	case "memories.list","memories.get":capability="mcp:memories:read"
	case "memories.create","memories.update","memories.archive":capability="mcp:memories:write"
	case "projects.list","projects.get":capability="mcp:projects:read"
	case "projects.create","projects.update","projects.archive":capability="mcp:projects:write"
	case "issues.list","issues.get":capability="mcp:issues:read"
	case "issues.create","issues.update","issues.delete","issues.comment":capability="mcp:issues:write"
	case "artifacts.list","artifacts.get":capability="mcp:artifacts:read"
	case "artifacts.create","artifacts.update","artifacts.delete":capability="mcp:artifacts:write"
	case:return false
	}
	return vault.control_scope_has(scope,capability)
}
