package vault

// Verify the signed capability at the decrypting endpoint as well as ingress.
control_job_scope_ok :: proc(scope,tool,operation:string)->bool {
	if !control_scopes_valid(scope) do return false
	if tool=="" do return operation=="read" || operation=="seal"
	switch tool {
	case "artifacts.list","artifacts.get":return operation=="read" && control_scope_has(scope,"mcp:artifacts:read")
	case "artifacts.create","artifacts.update":return operation=="seal_resource" && control_scope_has(scope,"mcp:artifacts:write")
	case "memories.list","memories.get":return operation=="read" && control_scope_has(scope,"mcp:memories:read")
	case "projects.list","projects.get":return operation=="read" && control_scope_has(scope,"mcp:projects:read")
	case "issues.list","issues.get":return operation=="read" && control_scope_has(scope,"mcp:issues:read")
	case "memories.create","memories.update":return operation=="seal_resource" && control_scope_has(scope,"mcp:memories:write")
	case "projects.create","projects.update":return operation=="seal_resource" && control_scope_has(scope,"mcp:projects:write")
	case "issues.create","issues.update","issues.comment":return operation=="seal_resource" && control_scope_has(scope,"mcp:issues:write")
	case "agents.list","agents.get":return operation=="read" && control_scope_has(scope,"mcp:agents:read")
	case "instances.list","instances.get","bridges.list","providers.list":return operation=="read" && control_scope_has(scope,"mcp:instances:read")
	case "agents.create","agents.update","agents.archive":return operation=="seal_agent" && control_scope_has(scope,"mcp:agents:write")
	case "chains.list","chains.get","events.wait":return operation=="read"
	case "chains.create":return operation=="seal"
	case "tasks.list","tasks.get":return operation=="read" && control_scope_has(scope,"mcp:tasks:read")
	case "chains.message":return operation=="seal_message" && control_scope_has(scope,"mcp:chains:message")
	case "tasks.comment":return operation=="seal_comment" && control_scope_has(scope,"mcp:tasks:write")
	case "tasks.create","tasks.update","tasks.control":return operation=="seal_task" && control_scope_has(scope,"mcp:tasks:write")
	}
	return false
}
