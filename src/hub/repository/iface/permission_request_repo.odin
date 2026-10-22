package iface

import domain "odin_test:hub/domain"

// Permission relay storage (REQ-EXT-PERM-1) on the agent repository.

// perm_insert stores a new pending request; a duplicate id is a Conflict.
Agent_Perm_Insert_Proc :: proc(ctx: rawptr, req: domain.Permission_Request) -> domain.Domain_Error
Agent_Perm_Get_Proc :: proc(ctx: rawptr, id: string) -> (domain.Permission_Request, bool, domain.Domain_Error)
// perm_list returns matching rows, newest first.
Agent_Perm_List_Proc :: proc(ctx: rawptr, filter: domain.Permission_Request_Filter) -> ([]domain.Permission_Request, domain.Domain_Error)
// perm_close moves ONE row from pending to status (compare-and-set). changed is
// false when the row is missing or already closed.
Agent_Perm_Close_Proc :: proc(ctx: rawptr, id, status, decided_by, message, decided_at: string) -> (bool, domain.Domain_Error)
// perm_close_pending closes every pending row of instance_id (when non-empty)
// or every pending row whose expires_at <= expired_by (when instance_id is "").
// Returns the rows it closed, with their new status.
Agent_Perm_Close_Pending_Proc :: proc(ctx: rawptr, instance_id, expired_by, status, decided_at: string) -> ([]domain.Permission_Request, domain.Domain_Error)

@(private = "file")
perm_not_configured :: proc() -> domain.Domain_Error {
	return domain.domain_error(.Internal_Error, "permission request repository is not configured")
}

agent_perm_insert :: proc(repo: ^Agent_Repository, req: domain.Permission_Request) -> domain.Domain_Error {
	if repo == nil || repo.perm_insert == nil do return perm_not_configured()
	return repo.perm_insert(repo.ctx, req)
}

agent_perm_get :: proc(repo: ^Agent_Repository, id: string) -> (domain.Permission_Request, bool, domain.Domain_Error) {
	if repo == nil || repo.perm_get == nil do return {}, false, perm_not_configured()
	return repo.perm_get(repo.ctx, id)
}

agent_perm_list :: proc(repo: ^Agent_Repository, filter: domain.Permission_Request_Filter) -> ([]domain.Permission_Request, domain.Domain_Error) {
	if repo == nil || repo.perm_list == nil do return nil, perm_not_configured()
	return repo.perm_list(repo.ctx, filter)
}

agent_perm_close :: proc(repo: ^Agent_Repository, id, status, decided_by, message, decided_at: string) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.perm_close == nil do return false, perm_not_configured()
	return repo.perm_close(repo.ctx, id, status, decided_by, message, decided_at)
}

agent_perm_close_pending :: proc(repo: ^Agent_Repository, instance_id, expired_by, status, decided_at: string) -> ([]domain.Permission_Request, domain.Domain_Error) {
	if repo == nil || repo.perm_close_pending == nil do return nil, perm_not_configured()
	return repo.perm_close_pending(repo.ctx, instance_id, expired_by, status, decided_at)
}
