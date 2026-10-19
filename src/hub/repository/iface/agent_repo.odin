package iface

import domain "odin_test:hub/domain"

Agent_Save_Proc :: proc(ctx: rawptr, agent: domain.Agent) -> (domain.Agent, bool, domain.Domain_Error)
Agent_Get_Proc :: proc(ctx: rawptr, agent_id: string) -> (domain.Agent, bool, domain.Domain_Error)
Agent_List_By_Owner_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID, limit: int, cursor: string) -> ([]domain.Agent, domain.Domain_Error)
Agent_Save_Support_Proc :: proc(ctx: rawptr, support: domain.Agent_Bridge_Support) -> (domain.Agent_Bridge_Support, bool, domain.Domain_Error)
Agent_Get_Support_Proc :: proc(ctx: rawptr, agent_id, bridge_id: string) -> (domain.Agent_Bridge_Support, bool, domain.Domain_Error)
Agent_List_Support_Proc :: proc(ctx: rawptr, agent_id: string, owner_user_id: domain.User_ID) -> ([]domain.Agent_Bridge_Support, domain.Domain_Error)
Agent_Delete_Support_Proc :: proc(ctx: rawptr, agent_id, bridge_id: string, owner_user_id: domain.User_ID) -> (bool, domain.Domain_Error)
Agent_Save_Instance_Proc :: proc(ctx: rawptr, instance: domain.Agent_Instance) -> (domain.Agent_Instance, bool, domain.Domain_Error)
Agent_Get_Instance_Proc :: proc(ctx: rawptr, instance_id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error)
Agent_Delete_Instance_Proc :: proc(ctx: rawptr, instance_id: string) -> (bool, domain.Domain_Error)
Agent_List_Instances_By_Owner_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID, limit: int, cursor: string) -> ([]domain.Agent_Instance, domain.Domain_Error)
Agent_List_Instances_By_Bridge_Proc :: proc(ctx: rawptr, bridge_id: string) -> ([]domain.Agent_Instance, domain.Domain_Error)
// Lists the owner's instances bound to one chain (agent_instances.chain_id) — the
// matcher's chain-scoped read, so it never loads the owner's whole instance history.
Agent_List_Instances_By_Chain_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID, chain_id: string) -> ([]domain.Agent_Instance, domain.Domain_Error)
// Lists instances still in an active runtime state (running/idle/busy/launching/
// starting/stopping) across all owners — used by the staleness reaper.
Agent_List_Active_Runtime_Instances_Proc :: proc(ctx: rawptr) -> ([]domain.Agent_Instance, domain.Domain_Error)
// Atomically increments and returns the per-agent global title counter. The
// counter survives daemon restarts (persisted in agent_title_counters) and is
// used to mint default per-run titles "<agent-name> #<n>".
Agent_Next_Title_Counter_Proc :: proc(ctx: rawptr, agent_id: string, owner_user_id: domain.User_ID, now: string) -> (int, bool, domain.Domain_Error)

Agent_Repository :: struct {
	ctx: rawptr,
	reconfiguration_begin: Instance_Reconfiguration_Begin_Proc,
	reconfiguration_get: Instance_Reconfiguration_Get_Proc,
	reconfiguration_advance: Instance_Reconfiguration_Advance_Proc,
	reconfiguration_list: Instance_Reconfiguration_List_Proc,
	save: Agent_Save_Proc,
	get: Agent_Get_Proc,
	list_by_owner: Agent_List_By_Owner_Proc,
	save_support: Agent_Save_Support_Proc,
	get_support: Agent_Get_Support_Proc,
	list_support: Agent_List_Support_Proc,
	delete_support: Agent_Delete_Support_Proc,
	save_instance: Agent_Save_Instance_Proc,
	get_instance: Agent_Get_Instance_Proc,
	delete_instance: Agent_Delete_Instance_Proc,
	list_instances_by_owner: Agent_List_Instances_By_Owner_Proc,
	list_instances_by_bridge: Agent_List_Instances_By_Bridge_Proc,
	list_instances_by_chain: Agent_List_Instances_By_Chain_Proc,
	list_active_runtime_instances: Agent_List_Active_Runtime_Instances_Proc,
	next_title_counter: Agent_Next_Title_Counter_Proc,
}

agent_next_title_counter :: proc(repo: ^Agent_Repository, agent_id: string, owner_user_id: domain.User_ID, now: string) -> (int, bool, domain.Domain_Error) {
	if repo == nil || repo.next_title_counter == nil do return 0, false, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.next_title_counter(repo.ctx, agent_id, owner_user_id, now)
}

agent_save :: proc(repo: ^Agent_Repository, agent: domain.Agent) -> (domain.Agent, bool, domain.Domain_Error) {
	if repo == nil || repo.save == nil do return domain.Agent{}, false, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.save(repo.ctx, agent)
}

agent_get :: proc(repo: ^Agent_Repository, agent_id: string) -> (domain.Agent, bool, domain.Domain_Error) {
	if repo == nil || repo.get == nil do return domain.Agent{}, false, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.get(repo.ctx, agent_id)
}

agent_list_by_owner :: proc(repo: ^Agent_Repository, owner_user_id: domain.User_ID, limit: int = 50, cursor: string = "") -> ([]domain.Agent, domain.Domain_Error) {
	if repo == nil || repo.list_by_owner == nil do return nil, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.list_by_owner(repo.ctx, owner_user_id, limit, cursor)
}

agent_save_support :: proc(repo: ^Agent_Repository, support: domain.Agent_Bridge_Support) -> (domain.Agent_Bridge_Support, bool, domain.Domain_Error) {
	if repo == nil || repo.save_support == nil do return domain.Agent_Bridge_Support{}, false, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.save_support(repo.ctx, support)
}

agent_get_support :: proc(repo: ^Agent_Repository, agent_id, bridge_id: string) -> (domain.Agent_Bridge_Support, bool, domain.Domain_Error) {
	if repo == nil || repo.get_support == nil do return domain.Agent_Bridge_Support{}, false, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.get_support(repo.ctx, agent_id, bridge_id)
}

agent_list_support :: proc(repo: ^Agent_Repository, agent_id: string, owner_user_id: domain.User_ID) -> ([]domain.Agent_Bridge_Support, domain.Domain_Error) {
	if repo == nil || repo.list_support == nil do return nil, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.list_support(repo.ctx, agent_id, owner_user_id)
}

agent_delete_support :: proc(repo: ^Agent_Repository, agent_id, bridge_id: string, owner_user_id: domain.User_ID) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.delete_support == nil do return false, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.delete_support(repo.ctx, agent_id, bridge_id, owner_user_id)
}

agent_save_instance :: proc(repo: ^Agent_Repository, instance: domain.Agent_Instance) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	if repo == nil || repo.save_instance == nil do return domain.Agent_Instance{}, false, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.save_instance(repo.ctx, instance)
}

agent_get_instance :: proc(repo: ^Agent_Repository, instance_id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	if repo == nil || repo.get_instance == nil do return domain.Agent_Instance{}, false, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.get_instance(repo.ctx, instance_id)
}

agent_delete_instance :: proc(repo: ^Agent_Repository, instance_id: string) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.delete_instance == nil do return false, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.delete_instance(repo.ctx, instance_id)
}

agent_list_instances_by_owner :: proc(repo: ^Agent_Repository, owner_user_id: domain.User_ID, limit: int = 50, cursor: string = "") -> ([]domain.Agent_Instance, domain.Domain_Error) {
	if repo == nil || repo.list_instances_by_owner == nil do return nil, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.list_instances_by_owner(repo.ctx, owner_user_id, limit, cursor)
}

agent_list_active_runtime_instances :: proc(repo: ^Agent_Repository) -> ([]domain.Agent_Instance, domain.Domain_Error) {
	if repo == nil || repo.list_active_runtime_instances == nil do return nil, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.list_active_runtime_instances(repo.ctx)
}

agent_list_instances_by_bridge :: proc(repo: ^Agent_Repository, bridge_id: string) -> ([]domain.Agent_Instance, domain.Domain_Error) {
	if repo == nil || repo.list_instances_by_bridge == nil do return nil, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.list_instances_by_bridge(repo.ctx, bridge_id)
}

agent_list_instances_by_chain :: proc(repo: ^Agent_Repository, owner_user_id: domain.User_ID, chain_id: string) -> ([]domain.Agent_Instance, domain.Domain_Error) {
	if repo == nil || repo.list_instances_by_chain == nil do return nil, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.list_instances_by_chain(repo.ctx, owner_user_id, chain_id)
}
