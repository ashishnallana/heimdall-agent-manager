package iface

import domain "odin_test:hub/domain"

// Vault device directory persistence (docs/plans/passwordless-vault.md §2 P2).
// Every directory mutation goes through `commit` (or `create_genesis`), which runs in
// ONE transaction whose first statement is the versioned CAS on vault_directories.

Vault_Get_Directory_Proc :: proc(ctx: rawptr, user_id: string) -> (domain.Vault_Directory, bool, domain.Domain_Error)
Vault_List_Devices_Proc :: proc(ctx: rawptr, user_id: string) -> ([]domain.Vault_Device, domain.Domain_Error)
Vault_List_Epochs_Proc :: proc(ctx: rawptr, user_id: string) -> ([]domain.Vault_Epoch, domain.Domain_Error)
// list_log returns the signed directory log in seq order (1..version).
Vault_List_Log_Proc :: proc(ctx: rawptr, user_id: string) -> ([]domain.Vault_Log_Entry, domain.Domain_Error)
// mark_retired sets the retirement HINT (retired_at) on the approved, not yet retired
// identity device_id mapped to bridge_id. NOT a directory mutation: no version, no log
// op. False when no such row.
Vault_Mark_Retired_Proc :: proc(ctx: rawptr, user_id, device_id, bridge_id, now: string) -> (bool, domain.Domain_Error)
Vault_Get_Wrap_Proc :: proc(ctx: rawptr, user_id, device_id: string) -> (domain.Vault_Wrap_Row, bool, domain.Domain_Error)
Vault_Find_Pending_By_Lookup_Proc :: proc(ctx: rawptr, user_id, pair_lookup: string) -> (domain.Vault_Device, bool, domain.Domain_Error)
// register_pending first purges the user's expired pending rows, then inserts a
// pending device, or returns the existing row for the same (user_id,
// sign_public_key). A NEW row is refused with Rate_Limited (reason "pending_cap")
// when the user already has VAULT_PENDING_PER_USER_MAX live pending devices. A live
// pending row is re-paired (new lookup/key_mac/register statement/expiry) only when
// domain.vault_register_supersedes says the new register statement is newer. A lookup
// collision returns Conflict with reason "lookup_collision".
Vault_Register_Pending_Proc :: proc(ctx: rawptr, device: domain.Vault_Device, now: string) -> (domain.Vault_Device, domain.Domain_Error)
// delete_pending removes a PENDING device (deny). False when no such pending row.
Vault_Delete_Pending_Proc :: proc(ctx: rawptr, user_id, device_id: string) -> (bool, domain.Domain_Error)
Vault_Touch_Last_Seen_Proc :: proc(ctx: rawptr, user_id, device_id, now: string) -> domain.Domain_Error
// create_genesis writes the first directory version; Conflict if one exists.
Vault_Create_Genesis_Proc :: proc(ctx: rawptr, genesis: domain.Vault_Genesis) -> domain.Domain_Error
// commit applies one versioned mutation and returns the new version. A stale
// expected_version (or a guarded row that changed underneath) is a Conflict naming
// the current version; nothing is written.
Vault_Commit_Proc :: proc(ctx: rawptr, c: domain.Vault_Directory_Commit) -> (i64, domain.Domain_Error)

// Reset scheduling. schedule_reset keeps an existing schedule (idempotent: a second
// request never moves due_at) and returns the stored row plus whether THIS call
// created it. execute_reset deletes the directory, devices, epochs, wraps and the
// reset row in ONE transaction, and only if the reset row is still there with
// due_at <= now (a cancel that landed first wins).
Vault_Get_Reset_Proc :: proc(ctx: rawptr, user_id: string) -> (domain.Vault_Reset, bool, domain.Domain_Error)
Vault_Schedule_Reset_Proc :: proc(ctx: rawptr, reset: domain.Vault_Reset) -> (domain.Vault_Reset, bool, domain.Domain_Error)
Vault_Cancel_Reset_Proc :: proc(ctx: rawptr, user_id: string) -> (bool, domain.Domain_Error)
Vault_List_Due_Resets_Proc :: proc(ctx: rawptr, now: string) -> ([]string, domain.Domain_Error)
Vault_Execute_Reset_Proc :: proc(ctx: rawptr, user_id, now: string) -> (bool, domain.Domain_Error)

Vault_Directory_Repository :: struct {
	consume_request_nonce: proc(ctx: rawptr, user_id, device_id, nonce: string, now_ms, expires_ms: i64) -> (bool, domain.Domain_Error),
	ctx:                  rawptr,
	get_directory:        Vault_Get_Directory_Proc,
	list_devices:         Vault_List_Devices_Proc,
	list_epochs:          Vault_List_Epochs_Proc,
	list_log:             Vault_List_Log_Proc,
	mark_retired:         Vault_Mark_Retired_Proc,
	get_wrap:             Vault_Get_Wrap_Proc,
	find_pending_by_lookup: Vault_Find_Pending_By_Lookup_Proc,
	register_pending:     Vault_Register_Pending_Proc,
	touch_last_seen:      Vault_Touch_Last_Seen_Proc,
	delete_pending:       Vault_Delete_Pending_Proc,
	create_genesis:       Vault_Create_Genesis_Proc,
	commit:               Vault_Commit_Proc,
	get_reset:            Vault_Get_Reset_Proc,
	schedule_reset:       Vault_Schedule_Reset_Proc,
	cancel_reset:         Vault_Cancel_Reset_Proc,
	list_due_resets:      Vault_List_Due_Resets_Proc,
	execute_reset:        Vault_Execute_Reset_Proc,
}

@(private = "file")
vault_repo_missing :: proc() -> domain.Domain_Error {
	return domain.domain_error(.Internal_Error, "vault directory repository is not configured")
}

vault_get_directory :: proc(repo: ^Vault_Directory_Repository, user_id: string) -> (domain.Vault_Directory, bool, domain.Domain_Error) {
	if repo == nil || repo.get_directory == nil do return {}, false, vault_repo_missing()
	return repo.get_directory(repo.ctx, user_id)
}

vault_list_devices :: proc(repo: ^Vault_Directory_Repository, user_id: string) -> ([]domain.Vault_Device, domain.Domain_Error) {
	if repo == nil || repo.list_devices == nil do return nil, vault_repo_missing()
	return repo.list_devices(repo.ctx, user_id)
}

vault_list_epochs :: proc(repo: ^Vault_Directory_Repository, user_id: string) -> ([]domain.Vault_Epoch, domain.Domain_Error) {
	if repo == nil || repo.list_epochs == nil do return nil, vault_repo_missing()
	return repo.list_epochs(repo.ctx, user_id)
}

vault_list_log :: proc(repo: ^Vault_Directory_Repository, user_id: string) -> ([]domain.Vault_Log_Entry, domain.Domain_Error) {
	if repo == nil || repo.list_log == nil do return nil, vault_repo_missing()
	return repo.list_log(repo.ctx, user_id)
}

vault_mark_retired :: proc(repo: ^Vault_Directory_Repository, user_id, device_id, bridge_id, now: string) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.mark_retired == nil do return false, vault_repo_missing()
	return repo.mark_retired(repo.ctx, user_id, device_id, bridge_id, now)
}

vault_get_wrap :: proc(repo: ^Vault_Directory_Repository, user_id, device_id: string) -> (domain.Vault_Wrap_Row, bool, domain.Domain_Error) {
	if repo == nil || repo.get_wrap == nil do return {}, false, vault_repo_missing()
	return repo.get_wrap(repo.ctx, user_id, device_id)
}

vault_find_pending_by_lookup :: proc(repo: ^Vault_Directory_Repository, user_id, pair_lookup: string) -> (domain.Vault_Device, bool, domain.Domain_Error) {
	if repo == nil || repo.find_pending_by_lookup == nil do return {}, false, vault_repo_missing()
	return repo.find_pending_by_lookup(repo.ctx, user_id, pair_lookup)
}

vault_register_pending :: proc(repo: ^Vault_Directory_Repository, device: domain.Vault_Device, now: string) -> (domain.Vault_Device, domain.Domain_Error) {
	if repo == nil || repo.register_pending == nil do return {}, vault_repo_missing()
	return repo.register_pending(repo.ctx, device, now)
}

vault_touch_last_seen :: proc(repo: ^Vault_Directory_Repository, user_id, device_id, now: string) -> domain.Domain_Error {
	if repo == nil || repo.touch_last_seen == nil do return vault_repo_missing()
	return repo.touch_last_seen(repo.ctx, user_id, device_id, now)
}

vault_create_genesis :: proc(repo: ^Vault_Directory_Repository, genesis: domain.Vault_Genesis) -> domain.Domain_Error {
	if repo == nil || repo.create_genesis == nil do return vault_repo_missing()
	return repo.create_genesis(repo.ctx, genesis)
}

vault_commit :: proc(repo: ^Vault_Directory_Repository, c: domain.Vault_Directory_Commit) -> (i64, domain.Domain_Error) {
	if repo == nil || repo.commit == nil do return 0, vault_repo_missing()
	return repo.commit(repo.ctx, c)
}

vault_get_reset :: proc(repo: ^Vault_Directory_Repository, user_id: string) -> (domain.Vault_Reset, bool, domain.Domain_Error) {
	if repo == nil || repo.get_reset == nil do return {}, false, vault_repo_missing()
	return repo.get_reset(repo.ctx, user_id)
}

vault_schedule_reset :: proc(repo: ^Vault_Directory_Repository, reset: domain.Vault_Reset) -> (domain.Vault_Reset, bool, domain.Domain_Error) {
	if repo == nil || repo.schedule_reset == nil do return {}, false, vault_repo_missing()
	return repo.schedule_reset(repo.ctx, reset)
}

vault_cancel_reset :: proc(repo: ^Vault_Directory_Repository, user_id: string) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.cancel_reset == nil do return false, vault_repo_missing()
	return repo.cancel_reset(repo.ctx, user_id)
}

vault_list_due_resets :: proc(repo: ^Vault_Directory_Repository, now: string) -> ([]string, domain.Domain_Error) {
	if repo == nil || repo.list_due_resets == nil do return nil, vault_repo_missing()
	return repo.list_due_resets(repo.ctx, now)
}

vault_execute_reset :: proc(repo: ^Vault_Directory_Repository, user_id, now: string) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.execute_reset == nil do return false, vault_repo_missing()
	return repo.execute_reset(repo.ctx, user_id, now)
}

vault_delete_pending :: proc(repo: ^Vault_Directory_Repository, user_id, device_id: string) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.delete_pending == nil do return false, vault_repo_missing()
	return repo.delete_pending(repo.ctx, user_id, device_id)
}
