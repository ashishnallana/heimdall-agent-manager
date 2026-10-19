package iface

import domain "odin_test:hub/domain"

Insert_Workflow_Run_Proc :: proc(ctx: rawptr, record: domain.Workflow_Run) -> (domain.Workflow_Run, bool, domain.Domain_Error)

taskchain_insert_workflow_run :: proc(repo: ^Taskchain_Repository, record: domain.Workflow_Run) -> (domain.Workflow_Run, bool, domain.Domain_Error) {
	if repo == nil || repo.insert_workflow_run == nil do return domain.Workflow_Run{}, false, domain.domain_error(.Internal_Error, "workflow run repository is not configured")
	return repo.insert_workflow_run(repo.ctx, record)
}

Update_Workflow_Run_Proc :: proc(ctx: rawptr, record: domain.Workflow_Run) -> (domain.Workflow_Run, bool, domain.Domain_Error)

taskchain_update_workflow_run :: proc(repo: ^Taskchain_Repository, record: domain.Workflow_Run) -> (domain.Workflow_Run, bool, domain.Domain_Error) {
	if repo == nil || repo.update_workflow_run == nil do return domain.Workflow_Run{}, false, domain.domain_error(.Internal_Error, "workflow run repository is not configured")
	return repo.update_workflow_run(repo.ctx, record)
}

Get_Workflow_Run_Proc :: proc(ctx: rawptr, run_id: domain.Workflow_Run_ID, owner_user_id: domain.User_ID) -> (domain.Workflow_Run, bool, domain.Domain_Error)

taskchain_get_workflow_run :: proc(repo: ^Taskchain_Repository, run_id: domain.Workflow_Run_ID, owner_user_id: domain.User_ID) -> (domain.Workflow_Run, bool, domain.Domain_Error) {
	if repo == nil || repo.get_workflow_run == nil do return domain.Workflow_Run{}, false, domain.domain_error(.Internal_Error, "workflow run repository is not configured")
	return repo.get_workflow_run(repo.ctx, run_id, owner_user_id)
}

Get_Workflow_Run_By_Request_Proc :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID, request_id: string) -> (domain.Workflow_Run, bool, domain.Domain_Error)

taskchain_get_workflow_run_by_request :: proc(repo: ^Taskchain_Repository, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID, request_id: string) -> (domain.Workflow_Run, bool, domain.Domain_Error) {
	if repo == nil || repo.get_workflow_run_by_request == nil do return domain.Workflow_Run{}, false, domain.domain_error(.Internal_Error, "workflow run repository is not configured")
	return repo.get_workflow_run_by_request(repo.ctx, chain_id, owner_user_id, request_id)
}

List_Workflow_Runs_Proc :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> ([]domain.Workflow_Run, domain.Domain_Error)

taskchain_list_workflow_runs :: proc(repo: ^Taskchain_Repository, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> ([]domain.Workflow_Run, domain.Domain_Error) {
	if repo == nil || repo.list_workflow_runs == nil do return nil, domain.domain_error(.Internal_Error, "workflow run repository is not configured")
	return repo.list_workflow_runs(repo.ctx, chain_id, owner_user_id)
}

Insert_Workflow_Execution_Proc :: proc(ctx: rawptr, record: domain.Workflow_Run_Execution) -> (domain.Workflow_Run_Execution, bool, domain.Domain_Error)

taskchain_insert_workflow_execution :: proc(repo: ^Taskchain_Repository, record: domain.Workflow_Run_Execution) -> (domain.Workflow_Run_Execution, bool, domain.Domain_Error) {
	if repo == nil || repo.insert_workflow_execution == nil do return domain.Workflow_Run_Execution{}, false, domain.domain_error(.Internal_Error, "workflow run repository is not configured")
	return repo.insert_workflow_execution(repo.ctx, record)
}

Update_Workflow_Execution_Proc :: proc(ctx: rawptr, record: domain.Workflow_Run_Execution) -> (domain.Workflow_Run_Execution, bool, domain.Domain_Error)

taskchain_update_workflow_execution :: proc(repo: ^Taskchain_Repository, record: domain.Workflow_Run_Execution) -> (domain.Workflow_Run_Execution, bool, domain.Domain_Error) {
	if repo == nil || repo.update_workflow_execution == nil do return domain.Workflow_Run_Execution{}, false, domain.domain_error(.Internal_Error, "workflow run repository is not configured")
	return repo.update_workflow_execution(repo.ctx, record)
}

Get_Workflow_Execution_Proc :: proc(ctx: rawptr, run_id: domain.Workflow_Run_ID, execution_no: int, owner_user_id: domain.User_ID) -> (domain.Workflow_Run_Execution, bool, domain.Domain_Error)

taskchain_get_workflow_execution :: proc(repo: ^Taskchain_Repository, run_id: domain.Workflow_Run_ID, execution_no: int, owner_user_id: domain.User_ID) -> (domain.Workflow_Run_Execution, bool, domain.Domain_Error) {
	if repo == nil || repo.get_workflow_execution == nil do return domain.Workflow_Run_Execution{}, false, domain.domain_error(.Internal_Error, "workflow run repository is not configured")
	return repo.get_workflow_execution(repo.ctx, run_id, execution_no, owner_user_id)
}

List_Workflow_Executions_Proc :: proc(ctx: rawptr, run_id: domain.Workflow_Run_ID, owner_user_id: domain.User_ID) -> ([]domain.Workflow_Run_Execution, domain.Domain_Error)

taskchain_list_workflow_executions :: proc(repo: ^Taskchain_Repository, run_id: domain.Workflow_Run_ID, owner_user_id: domain.User_ID) -> ([]domain.Workflow_Run_Execution, domain.Domain_Error) {
	if repo == nil || repo.list_workflow_executions == nil do return nil, domain.domain_error(.Internal_Error, "workflow run repository is not configured")
	return repo.list_workflow_executions(repo.ctx, run_id, owner_user_id)
}

Insert_Workflow_Stage_Execution_Proc :: proc(ctx: rawptr, record: domain.Workflow_Stage_Execution) -> (domain.Workflow_Stage_Execution, bool, domain.Domain_Error)

taskchain_insert_workflow_stage_execution :: proc(repo: ^Taskchain_Repository, record: domain.Workflow_Stage_Execution) -> (domain.Workflow_Stage_Execution, bool, domain.Domain_Error) {
	if repo == nil || repo.insert_workflow_stage_execution == nil do return domain.Workflow_Stage_Execution{}, false, domain.domain_error(.Internal_Error, "workflow run repository is not configured")
	return repo.insert_workflow_stage_execution(repo.ctx, record)
}

List_Workflow_Stage_Executions_Proc :: proc(ctx: rawptr, run_id: domain.Workflow_Run_ID, execution_no: int, owner_user_id: domain.User_ID) -> ([]domain.Workflow_Stage_Execution, domain.Domain_Error)

taskchain_list_workflow_stage_executions :: proc(repo: ^Taskchain_Repository, run_id: domain.Workflow_Run_ID, execution_no: int, owner_user_id: domain.User_ID) -> ([]domain.Workflow_Stage_Execution, domain.Domain_Error) {
	if repo == nil || repo.list_workflow_stage_executions == nil do return nil, domain.domain_error(.Internal_Error, "workflow run repository is not configured")
	return repo.list_workflow_stage_executions(repo.ctx, run_id, execution_no, owner_user_id)
}

Append_Workflow_Run_Event_Proc :: proc(ctx: rawptr, record: domain.Workflow_Run_Event) -> (domain.Workflow_Run_Event, bool, domain.Domain_Error)

taskchain_append_workflow_run_event :: proc(repo: ^Taskchain_Repository, record: domain.Workflow_Run_Event) -> (domain.Workflow_Run_Event, bool, domain.Domain_Error) {
	if repo == nil || repo.append_workflow_run_event == nil do return domain.Workflow_Run_Event{}, false, domain.domain_error(.Internal_Error, "workflow run repository is not configured")
	return repo.append_workflow_run_event(repo.ctx, record)
}

List_Workflow_Run_Events_Proc :: proc(ctx: rawptr, run_id: domain.Workflow_Run_ID, owner_user_id: domain.User_ID) -> ([]domain.Workflow_Run_Event, domain.Domain_Error)

taskchain_list_workflow_run_events :: proc(repo: ^Taskchain_Repository, run_id: domain.Workflow_Run_ID, owner_user_id: domain.User_ID) -> ([]domain.Workflow_Run_Event, domain.Domain_Error) {
	if repo == nil || repo.list_workflow_run_events == nil do return nil, domain.domain_error(.Internal_Error, "workflow run repository is not configured")
	return repo.list_workflow_run_events(repo.ctx, run_id, owner_user_id)
}
