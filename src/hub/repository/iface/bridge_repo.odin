package iface

import domain "odin_test:hub/domain"

Bridge_Save_Proc :: proc(ctx: rawptr, bridge: domain.Bridge) -> (domain.Bridge, bool, domain.Domain_Error)
Bridge_Get_Proc :: proc(ctx: rawptr, bridge_id: string) -> (domain.Bridge, bool, domain.Domain_Error)
Bridge_List_By_Owner_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Bridge, domain.Domain_Error)
// REQ-EA-3: pending enrollments and their rollback. delete_pending removes ONLY a
// row that is still pending and reports whether one was removed.
Bridge_List_Pending_Proc :: proc(ctx: rawptr) -> ([]domain.Bridge, domain.Domain_Error)
Bridge_Delete_Pending_Proc :: proc(ctx: rawptr, bridge_id: string) -> (bool, domain.Domain_Error)

// REQ-IMPL-3: the expiring credential pair and its rotation lineage.
//
// THERE IS DELIBERATELY NO `get_token_by_hash`. The row is found by its PUBLIC
// token_id (settled 6) and the secret is then verified in constant time, which is
// what allows a per-token random salt; a by-hash lookup would force the stored
// value back to being a deterministic function of the secret. The two existing
// by-token-hash procs above are the unsalted design this replaces and are already
// uncalled — REQ-IMPL-6 deletes them.
Bridge_Save_Token_Proc :: proc(ctx: rawptr, token: domain.Bridge_Token) -> (domain.Bridge_Token, bool, domain.Domain_Error)
Bridge_Get_Token_Proc :: proc(ctx: rawptr, token_id: string) -> (domain.Bridge_Token, bool, domain.Domain_Error)
Bridge_List_Tokens_By_Family_Proc :: proc(ctx: rawptr, family_id: string) -> ([]domain.Bridge_Token, domain.Domain_Error)
// Both revoke procs stamp revoked_at on every matching row that does not already
// carry one, and return how many rows they changed. The count is not cosmetic: the
// reuse-detection path asserts it is non-zero, because "revoked the family" that
// silently matched nothing is the failure mode that turns theft detection into a
// no-op.
Bridge_Revoke_Token_Family_Proc :: proc(ctx: rawptr, family_id, revoked_at: string) -> (int, bool, domain.Domain_Error)
Bridge_Revoke_Tokens_For_Bridge_Proc :: proc(ctx: rawptr, bridge_id, revoked_at: string) -> (int, bool, domain.Domain_Error)
Bridge_Mark_Token_Rotated_Proc :: proc(ctx: rawptr, token_id, rotated_at: string) -> (bool, domain.Domain_Error)
// REQ-EA-2/3/8: the pending-enrollment credential lifecycle. promote is a
// compare-and-set on scope; revoke_other_families keeps exactly one family alive.
Bridge_Promote_Token_Family_Proc :: proc(ctx: rawptr, family_id, from_scope, to_scope: string) -> (int, bool, domain.Domain_Error)
Bridge_Revoke_Other_Families_Proc :: proc(ctx: rawptr, bridge_id, keep_family_id, revoked_at: string) -> (int, bool, domain.Domain_Error)
Bridge_List_Live_Tokens_By_Scope_Proc :: proc(ctx: rawptr, scope: string) -> ([]domain.Bridge_Token, domain.Domain_Error)

Bridge_Repository :: struct {
	ctx: rawptr,
	save_bridge: Bridge_Save_Proc,
	get_bridge: Bridge_Get_Proc,
	list_by_owner: Bridge_List_By_Owner_Proc,
	list_pending: Bridge_List_Pending_Proc,
	delete_pending: Bridge_Delete_Pending_Proc,
	save_token: Bridge_Save_Token_Proc,
	get_token: Bridge_Get_Token_Proc,
	list_tokens_by_family: Bridge_List_Tokens_By_Family_Proc,
	revoke_token_family: Bridge_Revoke_Token_Family_Proc,
	revoke_tokens_for_bridge: Bridge_Revoke_Tokens_For_Bridge_Proc,
	mark_token_rotated: Bridge_Mark_Token_Rotated_Proc,
	promote_token_family: Bridge_Promote_Token_Family_Proc,
	revoke_other_families: Bridge_Revoke_Other_Families_Proc,
	list_live_tokens_by_scope: Bridge_List_Live_Tokens_By_Scope_Proc,
}





bridge_save_bridge :: proc(repo: ^Bridge_Repository, bridge: domain.Bridge) -> (domain.Bridge, bool, domain.Domain_Error) {
	if repo == nil || repo.save_bridge == nil do return domain.Bridge{}, false, domain.domain_error(.Internal_Error, "bridge repository is not configured")
	return repo.save_bridge(repo.ctx, bridge)
}

bridge_get_bridge :: proc(repo: ^Bridge_Repository, bridge_id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	if repo == nil || repo.get_bridge == nil do return domain.Bridge{}, false, domain.domain_error(.Internal_Error, "bridge repository is not configured")
	return repo.get_bridge(repo.ctx, bridge_id)
}


bridge_list_by_owner :: proc(repo: ^Bridge_Repository, owner_user_id: domain.User_ID) -> ([]domain.Bridge, domain.Domain_Error) {
	if repo == nil || repo.list_by_owner == nil do return nil, domain.domain_error(.Internal_Error, "bridge repository is not configured")
	return repo.list_by_owner(repo.ctx, owner_user_id)
}

bridge_list_pending :: proc(repo: ^Bridge_Repository) -> ([]domain.Bridge, domain.Domain_Error) {
	if repo == nil || repo.list_pending == nil do return nil, domain.domain_error(.Internal_Error, "bridge repository is not configured")
	return repo.list_pending(repo.ctx)
}

bridge_delete_pending :: proc(repo: ^Bridge_Repository, bridge_id: string) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.delete_pending == nil do return false, domain.domain_error(.Internal_Error, "bridge repository is not configured")
	return repo.delete_pending(repo.ctx, bridge_id)
}

bridge_save_token :: proc(repo: ^Bridge_Repository, token: domain.Bridge_Token) -> (domain.Bridge_Token, bool, domain.Domain_Error) {
	if repo == nil || repo.save_token == nil do return domain.Bridge_Token{}, false, domain.domain_error(.Internal_Error, "bridge repository is not configured")
	return repo.save_token(repo.ctx, token)
}

bridge_get_token :: proc(repo: ^Bridge_Repository, token_id: string) -> (domain.Bridge_Token, bool, domain.Domain_Error) {
	if repo == nil || repo.get_token == nil do return domain.Bridge_Token{}, false, domain.domain_error(.Internal_Error, "bridge repository is not configured")
	return repo.get_token(repo.ctx, token_id)
}

bridge_list_tokens_by_family :: proc(repo: ^Bridge_Repository, family_id: string) -> ([]domain.Bridge_Token, domain.Domain_Error) {
	if repo == nil || repo.list_tokens_by_family == nil do return nil, domain.domain_error(.Internal_Error, "bridge repository is not configured")
	return repo.list_tokens_by_family(repo.ctx, family_id)
}

bridge_revoke_token_family :: proc(repo: ^Bridge_Repository, family_id, revoked_at: string) -> (int, bool, domain.Domain_Error) {
	if repo == nil || repo.revoke_token_family == nil do return 0, false, domain.domain_error(.Internal_Error, "bridge repository is not configured")
	return repo.revoke_token_family(repo.ctx, family_id, revoked_at)
}

bridge_revoke_tokens_for_bridge :: proc(repo: ^Bridge_Repository, bridge_id, revoked_at: string) -> (int, bool, domain.Domain_Error) {
	if repo == nil || repo.revoke_tokens_for_bridge == nil do return 0, false, domain.domain_error(.Internal_Error, "bridge repository is not configured")
	return repo.revoke_tokens_for_bridge(repo.ctx, bridge_id, revoked_at)
}

bridge_mark_token_rotated :: proc(repo: ^Bridge_Repository, token_id, rotated_at: string) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.mark_token_rotated == nil do return false, domain.domain_error(.Internal_Error, "bridge repository is not configured")
	return repo.mark_token_rotated(repo.ctx, token_id, rotated_at)
}

bridge_promote_token_family :: proc(repo: ^Bridge_Repository, family_id, from_scope, to_scope: string) -> (int, bool, domain.Domain_Error) {
	if repo == nil || repo.promote_token_family == nil do return 0, false, domain.domain_error(.Internal_Error, "bridge repository is not configured")
	return repo.promote_token_family(repo.ctx, family_id, from_scope, to_scope)
}

bridge_revoke_other_families :: proc(repo: ^Bridge_Repository, bridge_id, keep_family_id, revoked_at: string) -> (int, bool, domain.Domain_Error) {
	if repo == nil || repo.revoke_other_families == nil do return 0, false, domain.domain_error(.Internal_Error, "bridge repository is not configured")
	return repo.revoke_other_families(repo.ctx, bridge_id, keep_family_id, revoked_at)
}

bridge_list_live_tokens_by_scope :: proc(repo: ^Bridge_Repository, scope: string) -> ([]domain.Bridge_Token, domain.Domain_Error) {
	if repo == nil || repo.list_live_tokens_by_scope == nil do return nil, domain.domain_error(.Internal_Error, "bridge repository is not configured")
	return repo.list_live_tokens_by_scope(repo.ctx, scope)
}
