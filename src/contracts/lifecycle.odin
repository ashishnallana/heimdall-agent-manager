package contracts

Register_Request :: struct {
	protocol_version: int,
	wrapper_instance_id: Wrapper_Instance_ID,
	agent_class: Agent_Class,
	agent_instance_id: Agent_Instance_ID,
	display_name: string,
	kind: Client_Kind,
	requested_access_mode: Client_Access_Mode,
	cwd: string,
	argv: []string,
	capabilities: []Client_Capability,
	metadata: map[string]string,
}
