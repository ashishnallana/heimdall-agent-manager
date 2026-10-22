package iface

import domain "odin_test:hub/domain"

// Provider extension (ham.ext.v1) storage on the agent repository.

// ext_insert_events assigns each event the next per-instance seq (ignoring the
// incoming seq), inserts them, trims the instance to its newest `keep` rows and
// returns the stored events (with seq set).
Agent_Ext_Insert_Events_Proc :: proc(ctx: rawptr, instance_id: string, events: []domain.Agent_Extension_Event, keep: int) -> ([]domain.Agent_Extension_Event, domain.Domain_Error)
Agent_Ext_Update_Instance_Proc :: proc(ctx: rawptr, instance_id: string, update: domain.Agent_Extension_Instance_Update) -> (bool, domain.Domain_Error)
// ext_list_events returns events in ascending seq order with seq > after_seq;
// agent_id filters to one subagent ("" = all, "main" = the main agent only).
Agent_Ext_List_Events_Proc :: proc(ctx: rawptr, instance_id: string, agent_id: string, after_seq: int, limit: int) -> ([]domain.Agent_Extension_Event, domain.Domain_Error)
Agent_Ext_List_Subagents_Proc :: proc(ctx: rawptr, instance_id: string) -> ([]domain.Agent_Subagent_Summary, domain.Domain_Error)
Agent_Ext_List_Files_Proc :: proc(ctx: rawptr, instance_id: string) -> ([]domain.Agent_File_Edit_Summary, domain.Domain_Error)

@(private = "file")
ext_not_configured :: proc() -> domain.Domain_Error {
	return domain.domain_error(.Internal_Error, "agent extension repository is not configured")
}

agent_ext_insert_events :: proc(repo: ^Agent_Repository, instance_id: string, events: []domain.Agent_Extension_Event, keep: int) -> ([]domain.Agent_Extension_Event, domain.Domain_Error) {
	if repo == nil || repo.ext_insert_events == nil do return nil, ext_not_configured()
	return repo.ext_insert_events(repo.ctx, instance_id, events, keep)
}

agent_ext_update_instance :: proc(repo: ^Agent_Repository, instance_id: string, update: domain.Agent_Extension_Instance_Update) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.ext_update_instance == nil do return false, ext_not_configured()
	return repo.ext_update_instance(repo.ctx, instance_id, update)
}

agent_ext_list_events :: proc(repo: ^Agent_Repository, instance_id, agent_id: string, after_seq, limit: int) -> ([]domain.Agent_Extension_Event, domain.Domain_Error) {
	if repo == nil || repo.ext_list_events == nil do return nil, ext_not_configured()
	return repo.ext_list_events(repo.ctx, instance_id, agent_id, after_seq, limit)
}

agent_ext_list_subagents :: proc(repo: ^Agent_Repository, instance_id: string) -> ([]domain.Agent_Subagent_Summary, domain.Domain_Error) {
	if repo == nil || repo.ext_list_subagents == nil do return nil, ext_not_configured()
	return repo.ext_list_subagents(repo.ctx, instance_id)
}

agent_ext_list_files :: proc(repo: ^Agent_Repository, instance_id: string) -> ([]domain.Agent_File_Edit_Summary, domain.Domain_Error) {
	if repo == nil || repo.ext_list_files == nil do return nil, ext_not_configured()
	return repo.ext_list_files(repo.ctx, instance_id)
}
