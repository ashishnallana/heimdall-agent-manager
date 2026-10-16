package iface

import domain "odin_test:hub/domain"

// Task System v2 repository surface. These procs are fields of
// Taskchain_Repository (one vtable, one sqlite connection) so a unit of work
// covers the legacy task/chain rows and the engine rows alike.

Task_Chain_List_Published_Active_Proc :: proc(ctx: rawptr) -> ([]domain.Task_Chain, domain.Domain_Error)
Task_List_By_State_Proc :: proc(ctx: rawptr, state: domain.Task_State) -> ([]domain.Task, domain.Domain_Error)

Task_Event_Append_Proc :: proc(ctx: rawptr, event: domain.Task_Event) -> (domain.Task_Event, bool, domain.Domain_Error)
Task_Event_List_By_Task_Proc :: proc(ctx: rawptr, task_id: domain.Task_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Event, domain.Domain_Error)
Task_Event_List_By_Chain_Proc :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Event, domain.Domain_Error)

Task_Attempt_Save_Proc :: proc(ctx: rawptr, attempt: domain.Task_Attempt) -> (domain.Task_Attempt, bool, domain.Domain_Error)
Task_Attempt_List_By_Task_Proc :: proc(ctx: rawptr, task_id: domain.Task_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Attempt, domain.Domain_Error)

Task_Attempt_Facet_Save_Proc :: proc(ctx: rawptr, facet: domain.Task_Attempt_Facet) -> (bool, domain.Domain_Error)
Task_Attempt_Facet_List_By_Task_Proc :: proc(ctx: rawptr, task_id: domain.Task_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Attempt_Facet, domain.Domain_Error)

Task_Lease_Save_Proc :: proc(ctx: rawptr, lease: domain.Task_Lease) -> (domain.Task_Lease, bool, domain.Domain_Error)
Task_Lease_Get_Proc :: proc(ctx: rawptr, lease_id: string) -> (domain.Task_Lease, bool, domain.Domain_Error)
Task_Lease_Get_By_Holder_Proc :: proc(ctx: rawptr, holder_instance_id: string) -> (domain.Task_Lease, bool, domain.Domain_Error)
Task_Lease_List_By_Task_Proc :: proc(ctx: rawptr, task_id: domain.Task_ID) -> ([]domain.Task_Lease, domain.Domain_Error)
Task_Lease_List_By_Chain_Proc :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID) -> ([]domain.Task_Lease, domain.Domain_Error)
Task_Lease_List_All_Proc :: proc(ctx: rawptr) -> ([]domain.Task_Lease, domain.Domain_Error)
Task_Lease_Delete_Proc :: proc(ctx: rawptr, lease_id: string) -> (bool, domain.Domain_Error)

Task_Review_Save_Proc :: proc(ctx: rawptr, review: domain.Task_Review) -> (domain.Task_Review, bool, domain.Domain_Error)
Task_Review_List_By_Task_Proc :: proc(ctx: rawptr, task_id: domain.Task_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Review, domain.Domain_Error)

Chain_Summary_Get_Proc :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> (domain.Chain_Summary, bool, domain.Domain_Error)
Chain_Summary_Save_Proc :: proc(ctx: rawptr, summary: domain.Chain_Summary) -> (domain.Chain_Summary, bool, domain.Domain_Error)

Workflow_Definition_Save_Proc :: proc(ctx: rawptr, def: domain.Workflow_Definition) -> (domain.Workflow_Definition, bool, domain.Domain_Error)
Workflow_Definition_Get_Proc :: proc(ctx: rawptr, def_id: string, owner_user_id: domain.User_ID) -> (domain.Workflow_Definition, bool, domain.Domain_Error)
Workflow_Definition_List_By_Owner_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Workflow_Definition, domain.Domain_Error)

@(private = "file")
NOT_CONFIGURED :: "taskchain repository is not configured"

taskchain_list_published_active_chains :: proc(repo: ^Taskchain_Repository) -> ([]domain.Task_Chain, domain.Domain_Error) {
	if repo == nil || repo.list_published_active_chains == nil do return nil, domain.domain_error(.Internal_Error, NOT_CONFIGURED)
	return repo.list_published_active_chains(repo.ctx)
}

taskchain_list_tasks_by_state :: proc(repo: ^Taskchain_Repository, state: domain.Task_State) -> ([]domain.Task, domain.Domain_Error) {
	if repo == nil || repo.list_tasks_by_state == nil do return nil, domain.domain_error(.Internal_Error, NOT_CONFIGURED)
	return repo.list_tasks_by_state(repo.ctx, state)
}

taskchain_append_event :: proc(repo: ^Taskchain_Repository, event: domain.Task_Event) -> (domain.Task_Event, bool, domain.Domain_Error) {
	if repo == nil || repo.append_event == nil do return domain.Task_Event{}, false, domain.domain_error(.Internal_Error, NOT_CONFIGURED)
	return repo.append_event(repo.ctx, event)
}

taskchain_list_events_by_task :: proc(repo: ^Taskchain_Repository, task_id: domain.Task_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Event, domain.Domain_Error) {
	if repo == nil || repo.list_events_by_task == nil do return nil, domain.domain_error(.Internal_Error, NOT_CONFIGURED)
	return repo.list_events_by_task(repo.ctx, task_id, owner_user_id)
}

taskchain_list_events_by_chain :: proc(repo: ^Taskchain_Repository, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Event, domain.Domain_Error) {
	if repo == nil || repo.list_events_by_chain == nil do return nil, domain.domain_error(.Internal_Error, NOT_CONFIGURED)
	return repo.list_events_by_chain(repo.ctx, chain_id, owner_user_id)
}

taskchain_save_attempt :: proc(repo: ^Taskchain_Repository, attempt: domain.Task_Attempt) -> (domain.Task_Attempt, bool, domain.Domain_Error) {
	if repo == nil || repo.save_attempt == nil do return domain.Task_Attempt{}, false, domain.domain_error(.Internal_Error, NOT_CONFIGURED)
	return repo.save_attempt(repo.ctx, attempt)
}

taskchain_list_attempts_by_task :: proc(repo: ^Taskchain_Repository, task_id: domain.Task_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Attempt, domain.Domain_Error) {
	if repo == nil || repo.list_attempts_by_task == nil do return nil, domain.domain_error(.Internal_Error, NOT_CONFIGURED)
	return repo.list_attempts_by_task(repo.ctx, task_id, owner_user_id)
}

taskchain_save_facet :: proc(repo: ^Taskchain_Repository, facet: domain.Task_Attempt_Facet) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.save_facet == nil do return false, domain.domain_error(.Internal_Error, NOT_CONFIGURED)
	return repo.save_facet(repo.ctx, facet)
}

taskchain_list_facets_by_task :: proc(repo: ^Taskchain_Repository, task_id: domain.Task_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Attempt_Facet, domain.Domain_Error) {
	if repo == nil || repo.list_facets_by_task == nil do return nil, domain.domain_error(.Internal_Error, NOT_CONFIGURED)
	return repo.list_facets_by_task(repo.ctx, task_id, owner_user_id)
}

taskchain_save_lease :: proc(repo: ^Taskchain_Repository, lease: domain.Task_Lease) -> (domain.Task_Lease, bool, domain.Domain_Error) {
	if repo == nil || repo.save_lease == nil do return domain.Task_Lease{}, false, domain.domain_error(.Internal_Error, NOT_CONFIGURED)
	return repo.save_lease(repo.ctx, lease)
}

taskchain_get_lease :: proc(repo: ^Taskchain_Repository, lease_id: string) -> (domain.Task_Lease, bool, domain.Domain_Error) {
	if repo == nil || repo.get_lease == nil do return domain.Task_Lease{}, false, domain.domain_error(.Internal_Error, NOT_CONFIGURED)
	return repo.get_lease(repo.ctx, lease_id)
}

taskchain_get_lease_by_holder :: proc(repo: ^Taskchain_Repository, holder_instance_id: string) -> (domain.Task_Lease, bool, domain.Domain_Error) {
	if repo == nil || repo.get_lease_by_holder == nil do return domain.Task_Lease{}, false, domain.domain_error(.Internal_Error, NOT_CONFIGURED)
	return repo.get_lease_by_holder(repo.ctx, holder_instance_id)
}

taskchain_list_leases_by_task :: proc(repo: ^Taskchain_Repository, task_id: domain.Task_ID) -> ([]domain.Task_Lease, domain.Domain_Error) {
	if repo == nil || repo.list_leases_by_task == nil do return nil, domain.domain_error(.Internal_Error, NOT_CONFIGURED)
	return repo.list_leases_by_task(repo.ctx, task_id)
}

taskchain_list_leases_by_chain :: proc(repo: ^Taskchain_Repository, chain_id: domain.Task_Chain_ID) -> ([]domain.Task_Lease, domain.Domain_Error) {
	if repo == nil || repo.list_leases_by_chain == nil do return nil, domain.domain_error(.Internal_Error, NOT_CONFIGURED)
	return repo.list_leases_by_chain(repo.ctx, chain_id)
}

taskchain_list_all_leases :: proc(repo: ^Taskchain_Repository) -> ([]domain.Task_Lease, domain.Domain_Error) {
	if repo == nil || repo.list_all_leases == nil do return nil, domain.domain_error(.Internal_Error, NOT_CONFIGURED)
	return repo.list_all_leases(repo.ctx)
}

taskchain_delete_lease :: proc(repo: ^Taskchain_Repository, lease_id: string) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.delete_lease == nil do return false, domain.domain_error(.Internal_Error, NOT_CONFIGURED)
	return repo.delete_lease(repo.ctx, lease_id)
}

taskchain_save_review :: proc(repo: ^Taskchain_Repository, review: domain.Task_Review) -> (domain.Task_Review, bool, domain.Domain_Error) {
	if repo == nil || repo.save_review == nil do return domain.Task_Review{}, false, domain.domain_error(.Internal_Error, NOT_CONFIGURED)
	return repo.save_review(repo.ctx, review)
}

taskchain_list_reviews_by_task :: proc(repo: ^Taskchain_Repository, task_id: domain.Task_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Review, domain.Domain_Error) {
	if repo == nil || repo.list_reviews_by_task == nil do return nil, domain.domain_error(.Internal_Error, NOT_CONFIGURED)
	return repo.list_reviews_by_task(repo.ctx, task_id, owner_user_id)
}

taskchain_get_chain_summary :: proc(repo: ^Taskchain_Repository, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> (domain.Chain_Summary, bool, domain.Domain_Error) {
	if repo == nil || repo.get_chain_summary == nil do return domain.Chain_Summary{}, false, domain.domain_error(.Internal_Error, NOT_CONFIGURED)
	return repo.get_chain_summary(repo.ctx, chain_id, owner_user_id)
}

taskchain_save_chain_summary :: proc(repo: ^Taskchain_Repository, summary: domain.Chain_Summary) -> (domain.Chain_Summary, bool, domain.Domain_Error) {
	if repo == nil || repo.save_chain_summary == nil do return domain.Chain_Summary{}, false, domain.domain_error(.Internal_Error, NOT_CONFIGURED)
	return repo.save_chain_summary(repo.ctx, summary)
}

taskchain_save_workflow_definition :: proc(repo: ^Taskchain_Repository, def: domain.Workflow_Definition) -> (domain.Workflow_Definition, bool, domain.Domain_Error) {
	if repo == nil || repo.save_workflow_definition == nil do return domain.Workflow_Definition{}, false, domain.domain_error(.Internal_Error, NOT_CONFIGURED)
	return repo.save_workflow_definition(repo.ctx, def)
}

taskchain_get_workflow_definition :: proc(repo: ^Taskchain_Repository, def_id: string, owner_user_id: domain.User_ID) -> (domain.Workflow_Definition, bool, domain.Domain_Error) {
	if repo == nil || repo.get_workflow_definition == nil do return domain.Workflow_Definition{}, false, domain.domain_error(.Internal_Error, NOT_CONFIGURED)
	return repo.get_workflow_definition(repo.ctx, def_id, owner_user_id)
}

taskchain_list_workflow_definitions_by_owner :: proc(repo: ^Taskchain_Repository, owner_user_id: domain.User_ID) -> ([]domain.Workflow_Definition, domain.Domain_Error) {
	if repo == nil || repo.list_workflow_definitions_by_owner == nil do return nil, domain.domain_error(.Internal_Error, NOT_CONFIGURED)
	return repo.list_workflow_definitions_by_owner(repo.ctx, owner_user_id)
}
