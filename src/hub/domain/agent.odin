package domain

Agent_State :: enum {
	Active,
	Archived,
}

// Current_Task_Role describes, for an instance's persisted current_task, whether
// the instance is acting on it as the assignee doing work or as a reviewer.
// None means the instance has no active current task.
Current_Task_Role :: enum {
	None,
	Work,
	Review,
}

Agent :: struct {
	agent_id: string,
	owner_user_id: User_ID,
	name: string,
	slug: string,
	template_id: string,
	instructions: string,
	state: Agent_State,
	created_at: string,
	updated_at: string,
}

Agent_Bridge_Support :: struct {
	agent_id: string,
	bridge_id: string,
	owner_user_id: User_ID,
	enabled: bool,
	kind: string,
	priority: int,
	max_instances: int,
	created_at: string,
	updated_at: string,
}

Resolved_Provider_Model :: struct {
	provider: string,
	model: string,
}

Agent_Instance :: struct {
	agent_instance_id: string,
	owner_user_id: User_ID,
	agent_id: string,
	bridge_id: string,
	// display_name is the human-readable title for this instance (defaults to "<agent-name> #<n>").
	display_name: string,
	provider: string,
	model: string,
	kind: string,
	project_id: Project_ID,
	project_path: string,
	chain_id: string,
	conversation_id: string,
	runtime_status: string,
	startup_status: string,
	activity_status: string,
	status_message: string,
	// last_error_json is the wire error object (contracts.Wire_Error) the bridge
	// reported when the instance last went "failed"; "" otherwise (REQ-ERR-PROTO-A).
	last_error_json: string,
	last_applied_seq: int,
	run_count: int,
	configuration_revision: int,
	launch_epoch: string,
	// current_task_id is the single task this instance is actively focused on
	// (either working or reviewing). Empty when the instance has no current task.
	current_task_id: string,
	// current_task_role indicates whether current_task_id is work or review.
	current_task_role: Current_Task_Role,
	created_at: string,
	updated_at: string,
	started_at: string,
	stopped_at: string,
	last_seen_at: string,
}

current_task_role_string :: proc(role: Current_Task_Role) -> string {
	switch role {
	case .Work: return "work"
	case .Review: return "review"
	case .None: return "none"
	}
	return "none"
}

current_task_role_from_string :: proc(value: string) -> Current_Task_Role {
	switch value {
	case "work": return .Work
	case "review": return .Review
	}
	return .None
}

agent_state_string :: proc(state: Agent_State) -> string {
	if state == .Archived do return "archived"
	return "active"
}

agent_instance_destroy :: proc(inst: ^Agent_Instance) {
	if inst == nil do return
	if len(inst.agent_instance_id) > 0 do delete(inst.agent_instance_id)
	if len(string(inst.owner_user_id)) > 0 do delete(string(inst.owner_user_id))
	if len(inst.agent_id) > 0 do delete(inst.agent_id)
	if len(inst.bridge_id) > 0 do delete(inst.bridge_id)
	if len(inst.display_name) > 0 do delete(inst.display_name)
	if len(inst.provider) > 0 do delete(inst.provider)
	if len(inst.model) > 0 do delete(inst.model)
	if len(inst.kind) > 0 do delete(inst.kind)
	if len(string(inst.project_id)) > 0 do delete(string(inst.project_id))
	if len(inst.project_path) > 0 do delete(inst.project_path)
	if len(inst.chain_id) > 0 do delete(inst.chain_id)
	if len(inst.conversation_id) > 0 do delete(inst.conversation_id)
	if len(inst.runtime_status) > 0 do delete(inst.runtime_status)
	if len(inst.startup_status) > 0 do delete(inst.startup_status)
	if len(inst.activity_status) > 0 do delete(inst.activity_status)
	if len(inst.status_message) > 0 do delete(inst.status_message)
	if len(inst.last_error_json) > 0 do delete(inst.last_error_json)
	if len(inst.launch_epoch) > 0 do delete(inst.launch_epoch)
	if len(inst.current_task_id) > 0 do delete(inst.current_task_id)
	if len(inst.created_at) > 0 do delete(inst.created_at)
	if len(inst.updated_at) > 0 do delete(inst.updated_at)
	if len(inst.started_at) > 0 do delete(inst.started_at)
	if len(inst.stopped_at) > 0 do delete(inst.stopped_at)
	if len(inst.last_seen_at) > 0 do delete(inst.last_seen_at)
	inst^ = {}
}

agent_instances_destroy :: proc(instances: []Agent_Instance) {
	for &inst in instances {
		agent_instance_destroy(&inst)
	}
	delete(instances)
}
