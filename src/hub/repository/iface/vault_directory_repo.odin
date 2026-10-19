package iface

import domain "odin_test:hub/domain"

// Vault device directory persistence (docs/plans/passwordless-vault.md §2 P2).
// Every directory mutation goes through `commit` (or `create_genesis`), which runs in
// ONE transaction whose first statement is the versioned CAS on vault_directories.

Vault_Get_Directory_Proc :: proc(ctx: rawptr, user_id: string) -> (domain.Vault_Directory, bool, domain.Domain_Error)
Vault_List_Devices_Proc :: proc(ctx: rawptr, user_id: string) -> ([]domain.Vault_Device, domain.Domain_Error)
Vault_List_Epochs_Proc :: proc(ctx: rawptr, user_id: string) -> ([]domain.Vault_Epoch, domain.Domain_Error)
Vault_Get_Wrap_Proc :: proc(ctx: rawptr, user_id, device_id: string) -> (domain.Vault_Wrap_Row, bool, domain.Domain_Error)
Vault_Find_Pending_By_Code_Proc :: proc(ctx: rawptr, user_id, user_code: string) -> (domain.Vault_Device, bool, domain.Domain_Error)
// register_pending inserts a pending device, or returns the existing row for the same
// (user_id, sign_public_key). An existing PENDING row whose code has expired at `now`
// gets `device.user_code` / `device.code_expires_at`. A code collision returns
// Conflict with details reason "code_collision" (the caller retries with a fresh code).
Vault_Register_Pending_Proc :: proc(ctx: rawptr, device: domain.Vault_Device, now: string) -> (domain.Vault_Device, domain.Domain_Error)
Vault_Touch_Last_Seen_Proc :: proc(ctx: rawptr, user_id, device_id, now: string) -> domain.Domain_Error
// create_genesis writes the first directory version; Conflict if one exists.
Vault_Create_Genesis_Proc :: proc(ctx: rawptr, genesis: domain.Vault_Genesis) -> domain.Domain_Error
// commit applies one versioned mutation and returns the new version. A stale
// expected_version (or a guarded row that changed underneath) is a Conflict naming
// the current version; nothing is written.
Vault_Commit_Proc :: proc(ctx: rawptr, c: domain.Vault_Directory_Commit) -> (i64, domain.Domain_Error)

Vault_Directory_Repository :: struct {
	ctx:                  rawptr,
	get_directory:        Vault_Get_Directory_Proc,
	list_devices:         Vault_List_Devices_Proc,
	list_epochs:          Vault_List_Epochs_Proc,
	get_wrap:             Vault_Get_Wrap_Proc,
	find_pending_by_code: Vault_Find_Pending_By_Code_Proc,
	register_pending:     Vault_Register_Pending_Proc,
	touch_last_seen:      Vault_Touch_Last_Seen_Proc,
	create_genesis:       Vault_Create_Genesis_Proc,
	commit:               Vault_Commit_Proc,
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

vault_get_wrap :: proc(repo: ^Vault_Directory_Repository, user_id, device_id: string) -> (domain.Vault_Wrap_Row, bool, domain.Domain_Error) {
	if repo == nil || repo.get_wrap == nil do return {}, false, vault_repo_missing()
	return repo.get_wrap(repo.ctx, user_id, device_id)
}

vault_find_pending_by_code :: proc(repo: ^Vault_Directory_Repository, user_id, user_code: string) -> (domain.Vault_Device, bool, domain.Domain_Error) {
	if repo == nil || repo.find_pending_by_code == nil do return {}, false, vault_repo_missing()
	return repo.find_pending_by_code(repo.ctx, user_id, user_code)
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
