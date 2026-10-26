package iface

import domain "odin_test:hub/domain"

Bridge_Save_Proc :: proc(ctx: rawptr, bridge: domain.Bridge) -> (domain.Bridge, bool, domain.Domain_Error)
Bridge_Get_Proc :: proc(ctx: rawptr, bridge_id: string) -> (domain.Bridge, bool, domain.Domain_Error)

// Bridge_Runtime_Write names the narrow, single-purpose column writes a Bridge's own
// runtime connection makes (heartbeat liveness, legacy capability metadata, vault
// status, disconnect). Each is one conditional UPDATE of its own columns only, never a
// full-row save: a read-modify-save from the WS reader thread used to revert any
// concurrent label, token rotation, telemetry, enrollment or revocation edit made
// between its read and its write.
//   .Liveness      status='online', last_seen_at=now   WHERE status != 'revoked'
//   .Capabilities  capabilities_json=value             WHERE status != 'revoked' AND capabilities_json = expected (compare-and-set) AND differs
//   .Vault_Status  vault_status=value                  WHERE status != 'revoked' AND differs
//   .Offline       status='offline'                    WHERE status = 'online'
// changed is true only when a row was actually written.
Bridge_Runtime_Write :: enum {
	Liveness,
	Capabilities,
	Vault_Status,
	Offline,
}
Bridge_Update_Runtime_Proc :: proc(ctx: rawptr, kind: Bridge_Runtime_Write, bridge_id, now, value, expected: string) -> (bool, domain.Domain_Error)
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
// REQ-EA-3: revoke a family only while it is still in `scope`, as ONE statement. The
// enrollment rollback uses it so a family the commit promoted a moment earlier is
// never revoked: a separate "is it still pending?" read followed by an unconditional
// revoke would race the commit and kill a just-committed bridge's credential.
Bridge_Revoke_Token_Family_In_Scope_Proc :: proc(ctx: rawptr, family_id, scope, revoked_at: string) -> (int, bool, domain.Domain_Error)
Bridge_Mark_Token_Rotated_Proc :: proc(ctx: rawptr, token_id, rotated_at, request_hash: string) -> (bool, domain.Domain_Error)
// Stamps first_used_at on a token that has none (one write per token, ever).
Bridge_Mark_Token_Used_Proc :: proc(ctx: rawptr, token_id, used_at: string) -> (bool, domain.Domain_Error)
// Bridge_Regrant_Input is one graced re-grant, applied ALL OR NOTHING by
// Bridge_Regrant_Atomic_Proc: claim the spent refresh row (compare-and-set of
// regrant_claim from `expected` to `claim`), revoke every live row of the family
// newer than `generation`, and insert the new refresh and access rows.
Bridge_Regrant_Input :: struct {
	spent_token_id: string,
	family_id:      string,
	generation:     int, // the spent row's generation
	expected:       string,
	claim:          string,
	now:            string,
	refresh_row:    domain.Bridge_Token,
	access_row:     domain.Bridge_Token,
}
Bridge_Regrant_Outcome :: enum {
	Granted, // committed: claim, revocations and both new rows
	Lost,    // another re-grant holds the claim; nothing was written
	Failed,  // an error rolled everything back; nothing was written
}
Bridge_Regrant_Atomic_Proc :: proc(ctx: rawptr, input: Bridge_Regrant_Input) -> (Bridge_Regrant_Outcome, domain.Domain_Error)

// REQ-EA-2/8: the enrollment COMMIT, as ONE transaction. Promote the family from
// from_scope to to_scope (a compare-and-set on scope), then either revoke every other
// family of the bridge (attach) or clear the row's pending deadline (new bridge). A
// failure anywhere rolls all of it back, so no crash or error leaves two live
// credentials, or a live credential on a row the sweep would delete.
Enrollment_Commit_Outcome :: enum {
	Committed,          // this call promoted the family
	Already_Committed,  // the family was promoted earlier (a duplicate result); nothing changed
	Not_Pending,        // the family is revoked or unknown: the enrollment was rolled back
}
Bridge_Commit_Enrollment_Proc :: proc(ctx: rawptr, bridge_id, family_id, from_scope, to_scope: string, attach: bool, now: string) -> (Enrollment_Commit_Outcome, bool, domain.Domain_Error)
Bridge_List_Live_Tokens_By_Scope_Proc :: proc(ctx: rawptr, scope: string) -> ([]domain.Bridge_Token, domain.Domain_Error)

Bridge_Plan_Rank_Proc :: proc(a, b: domain.Bridge) -> bool
Bridge_Create_Limited_Proc :: proc(ctx: rawptr, bridge: domain.Bridge, max_bridges: int) -> (domain.Bridge, bool, domain.Domain_Error)
Bridge_Count_Active_Proc :: proc(ctx: rawptr, owner: domain.User_ID) -> (int, domain.Domain_Error)
Bridge_Reconcile_Plan_Proc :: proc(ctx: rawptr, owner: domain.User_ID, max_bridges: int, now: string, before: Bridge_Plan_Rank_Proc) -> domain.Domain_Error
Bridge_List_Owners_Proc :: proc(ctx: rawptr) -> ([]string, domain.Domain_Error)

Bridge_Repository :: struct {
	create_limited: Bridge_Create_Limited_Proc,
	count_active_by_owner: Bridge_Count_Active_Proc,
	reconcile_plan: Bridge_Reconcile_Plan_Proc,
	list_owners: Bridge_List_Owners_Proc,
	ctx: rawptr,
	save_bridge: Bridge_Save_Proc,
	update_runtime: Bridge_Update_Runtime_Proc,
	get_bridge: Bridge_Get_Proc,
	list_by_owner: Bridge_List_By_Owner_Proc,
	list_pending: Bridge_List_Pending_Proc,
	delete_pending: Bridge_Delete_Pending_Proc,
	save_token: Bridge_Save_Token_Proc,
	get_token: Bridge_Get_Token_Proc,
	list_tokens_by_family: Bridge_List_Tokens_By_Family_Proc,
	revoke_token_family: Bridge_Revoke_Token_Family_Proc,
	revoke_tokens_for_bridge: Bridge_Revoke_Tokens_For_Bridge_Proc,
	revoke_token_family_in_scope: Bridge_Revoke_Token_Family_In_Scope_Proc,
	mark_token_rotated: Bridge_Mark_Token_Rotated_Proc,
	mark_token_used: Bridge_Mark_Token_Used_Proc,
	regrant_atomic: Bridge_Regrant_Atomic_Proc,
	commit_enrollment: Bridge_Commit_Enrollment_Proc,
	list_live_tokens_by_scope: Bridge_List_Live_Tokens_By_Scope_Proc,
}





bridge_save_bridge :: proc(repo: ^Bridge_Repository, bridge: domain.Bridge) -> (domain.Bridge, bool, domain.Domain_Error) {
	if repo == nil || repo.save_bridge == nil do return domain.Bridge{}, false, domain.domain_error(.Internal_Error, "bridge repository is not configured")
	return repo.save_bridge(repo.ctx, bridge)
}

bridge_update_runtime :: proc(repo: ^Bridge_Repository, kind: Bridge_Runtime_Write, bridge_id, now: string, value: string = "", expected: string = "") -> (bool, domain.Domain_Error) {
	if repo == nil || repo.update_runtime == nil do return false, domain.domain_error(.Internal_Error, "bridge repository is not configured")
	return repo.update_runtime(repo.ctx, kind, bridge_id, now, value, expected)
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

bridge_revoke_token_family_in_scope :: proc(repo: ^Bridge_Repository, family_id, scope, revoked_at: string) -> (int, bool, domain.Domain_Error) {
	if repo == nil || repo.revoke_token_family_in_scope == nil do return 0, false, domain.domain_error(.Internal_Error, "bridge repository is not configured")
	return repo.revoke_token_family_in_scope(repo.ctx, family_id, scope, revoked_at)
}

// request_hash, when non-empty, records which refresh request spent the token (see
// domain.Bridge_Token.rotation_request_hash).
bridge_mark_token_used :: proc(repo: ^Bridge_Repository, token_id, used_at: string) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.mark_token_used == nil do return false, domain.domain_error(.Internal_Error, "bridge repository is not configured")
	return repo.mark_token_used(repo.ctx, token_id, used_at)
}

bridge_regrant_atomic :: proc(repo: ^Bridge_Repository, input: Bridge_Regrant_Input) -> (Bridge_Regrant_Outcome, domain.Domain_Error) {
	if repo == nil || repo.regrant_atomic == nil do return .Failed, domain.domain_error(.Internal_Error, "bridge repository is not configured")
	return repo.regrant_atomic(repo.ctx, input)
}

bridge_mark_token_rotated :: proc(repo: ^Bridge_Repository, token_id, rotated_at: string, request_hash := "") -> (bool, domain.Domain_Error) {
	if repo == nil || repo.mark_token_rotated == nil do return false, domain.domain_error(.Internal_Error, "bridge repository is not configured")
	return repo.mark_token_rotated(repo.ctx, token_id, rotated_at, request_hash)
}

bridge_commit_enrollment :: proc(repo: ^Bridge_Repository, bridge_id, family_id, from_scope, to_scope: string, attach: bool, now: string) -> (Enrollment_Commit_Outcome, bool, domain.Domain_Error) {
	if repo == nil || repo.commit_enrollment == nil do return .Not_Pending, false, domain.domain_error(.Internal_Error, "bridge repository is not configured")
	return repo.commit_enrollment(repo.ctx, bridge_id, family_id, from_scope, to_scope, attach, now)
}

bridge_list_live_tokens_by_scope :: proc(repo: ^Bridge_Repository, scope: string) -> ([]domain.Bridge_Token, domain.Domain_Error) {
	if repo == nil || repo.list_live_tokens_by_scope == nil do return nil, domain.domain_error(.Internal_Error, "bridge repository is not configured")
	return repo.list_live_tokens_by_scope(repo.ctx, scope)
}


// Count includes pending and plan-disabled rows: neither may bypass the approval cap.
bridge_count_active_by_owner :: proc(repo: ^Bridge_Repository, owner: domain.User_ID) -> (int, domain.Domain_Error) {
	if repo == nil || repo.count_active_by_owner == nil do return 0, domain.domain_error(.Internal_Error, "bridge count is not configured")
	return repo.count_active_by_owner(repo.ctx, owner)
}

bridge_create_limited :: proc(repo: ^Bridge_Repository, bridge: domain.Bridge, max_bridges: int) -> (domain.Bridge, bool, domain.Domain_Error) {
	if max_bridges < 0 do return bridge_save_bridge(repo, bridge)
	if repo == nil || repo.create_limited == nil do return {}, false, domain.domain_error(.Internal_Error, "limited bridge enrollment is not configured")
	return repo.create_limited(repo.ctx, bridge, max_bridges)
}
