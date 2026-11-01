package vault

// Verify the signed capability at the decrypting endpoint as well as ingress.
control_job_scope_ok :: proc(scope,tool,operation:string)->bool {
	if !control_scopes_valid(scope) do return false
	if tool=="" do return operation=="read" || operation=="seal"
	switch tool {
	case "chains.list","chains.get","events.wait":return operation=="read"
	case "chains.create":return operation=="seal"
	case "tasks.list","tasks.get":return operation=="read" && control_scope_has(scope,"mcp:tasks:read")
	case "tasks.comment":return operation=="seal_comment" && control_scope_has(scope,"mcp:tasks:write")
	case "tasks.create","tasks.update","tasks.control":return operation=="seal_task" && control_scope_has(scope,"mcp:tasks:write")
	}
	return false
}
