package iface

import domain "odin_test:hub/domain"

Insert_Work_Dependency_Proc :: proc(ctx: rawptr, record: domain.Work_Dependency) -> (domain.Work_Dependency, bool, domain.Domain_Error)

taskchain_insert_work_dependency :: proc(repo: ^Taskchain_Repository, record: domain.Work_Dependency) -> (domain.Work_Dependency, bool, domain.Domain_Error) {
	if repo == nil || repo.insert_work_dependency == nil do return domain.Work_Dependency{}, false, domain.domain_error(.Internal_Error, "mixed-work repository is not configured")
	return repo.insert_work_dependency(repo.ctx, record)
}

List_Work_Dependencies_Proc :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> ([]domain.Work_Dependency, domain.Domain_Error)

taskchain_list_work_dependencies :: proc(repo: ^Taskchain_Repository, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> ([]domain.Work_Dependency, domain.Domain_Error) {
	if repo == nil || repo.list_work_dependencies == nil do return nil, domain.domain_error(.Internal_Error, "mixed-work repository is not configured")
	return repo.list_work_dependencies(repo.ctx, chain_id, owner_user_id)
}

Insert_Work_Input_Receipt_Proc :: proc(ctx: rawptr, record: domain.Work_Input_Receipt) -> (domain.Work_Input_Receipt, bool, domain.Domain_Error)

taskchain_insert_work_input_receipt :: proc(repo: ^Taskchain_Repository, record: domain.Work_Input_Receipt) -> (domain.Work_Input_Receipt, bool, domain.Domain_Error) {
	if repo == nil || repo.insert_work_input_receipt == nil do return domain.Work_Input_Receipt{}, false, domain.domain_error(.Internal_Error, "mixed-work repository is not configured")
	return repo.insert_work_input_receipt(repo.ctx, record)
}

List_Work_Receipts_By_Prerequisite_Proc :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID, item: domain.Work_Item_Ref) -> ([]domain.Work_Input_Receipt, domain.Domain_Error)

taskchain_list_work_receipts_by_prerequisite :: proc(repo: ^Taskchain_Repository, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID, item: domain.Work_Item_Ref) -> ([]domain.Work_Input_Receipt, domain.Domain_Error) {
	if repo == nil || repo.list_work_receipts_by_prerequisite == nil do return nil, domain.domain_error(.Internal_Error, "mixed-work repository is not configured")
	return repo.list_work_receipts_by_prerequisite(repo.ctx, chain_id, owner_user_id, item)
}

List_Work_Receipts_By_Dependent_Proc :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID, item: domain.Work_Item_Ref) -> ([]domain.Work_Input_Receipt, domain.Domain_Error)

taskchain_list_work_receipts_by_dependent :: proc(repo: ^Taskchain_Repository, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID, item: domain.Work_Item_Ref) -> ([]domain.Work_Input_Receipt, domain.Domain_Error) {
	if repo == nil || repo.list_work_receipts_by_dependent == nil do return nil, domain.domain_error(.Internal_Error, "mixed-work repository is not configured")
	return repo.list_work_receipts_by_dependent(repo.ctx, chain_id, owner_user_id, item)
}

Append_Work_Scope_Decision_Proc :: proc(ctx: rawptr, record: domain.Work_Scope_Decision) -> (domain.Work_Scope_Decision, bool, domain.Domain_Error)

taskchain_append_work_scope_decision :: proc(repo: ^Taskchain_Repository, record: domain.Work_Scope_Decision) -> (domain.Work_Scope_Decision, bool, domain.Domain_Error) {
	if repo == nil || repo.append_work_scope_decision == nil do return domain.Work_Scope_Decision{}, false, domain.domain_error(.Internal_Error, "mixed-work repository is not configured")
	return repo.append_work_scope_decision(repo.ctx, record)
}

List_Work_Scope_Decisions_Proc :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> ([]domain.Work_Scope_Decision, domain.Domain_Error)

taskchain_list_work_scope_decisions :: proc(repo: ^Taskchain_Repository, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> ([]domain.Work_Scope_Decision, domain.Domain_Error) {
	if repo == nil || repo.list_work_scope_decisions == nil do return nil, domain.domain_error(.Internal_Error, "mixed-work repository is not configured")
	return repo.list_work_scope_decisions(repo.ctx, chain_id, owner_user_id)
}

Remove_Work_Dependency_Proc :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID, dependency_id: string, removed_at: string, actor_kind: string, actor_id: string, reason: string) -> (bool, domain.Domain_Error)

taskchain_remove_work_dependency :: proc(repo: ^Taskchain_Repository, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID, dependency_id: string, removed_at: string, actor_kind: string, actor_id: string, reason: string) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.remove_work_dependency == nil do return false, domain.domain_error(.Internal_Error, "mixed-work repository is not configured")
	return repo.remove_work_dependency(repo.ctx, chain_id, owner_user_id, dependency_id, removed_at, actor_kind, actor_id, reason)
}

Complete_Work_Chain_Proc :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID, expected_revision: i64, summary, completed_at: string) -> (bool, domain.Domain_Error)
taskchain_complete_work_chain :: proc(repo: ^Taskchain_Repository, chain_id: domain.Task_Chain_ID, owner: domain.User_ID, expected_revision: i64, summary, completed_at: string) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.complete_work_chain == nil do return false, domain.domain_error(.Internal_Error, "mixed-work repository not configured")
	return repo.complete_work_chain(repo.ctx, chain_id, owner, expected_revision, summary, completed_at)
}
