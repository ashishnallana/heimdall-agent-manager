package iface

import domain "odin_test:hub/domain"

Provider_Catalog_List_Proc :: proc(ctx: rawptr) -> ([dynamic]domain.Provider_Catalog_Entry, domain.Domain_Error)
Provider_Catalog_Get_Proc  :: proc(ctx: rawptr, provider: string) -> (domain.Provider_Catalog_Entry, bool, domain.Domain_Error)
Provider_Icon_Get_Proc     :: proc(ctx: rawptr, provider: string) -> (domain.Provider_Icon, bool, domain.Domain_Error)
Provider_Catalog_Etag_Proc :: proc(ctx: rawptr) -> (string, domain.Domain_Error)
Bridge_Provider_Status_Upsert_Proc :: proc(ctx: rawptr, status: domain.Bridge_Provider_Status) -> (bool, domain.Domain_Error)
Bridge_Provider_Status_List_Proc :: proc(ctx: rawptr, bridge_id: string) -> ([dynamic]domain.Bridge_Provider_Status, domain.Domain_Error)
Bridge_Provider_Setting_Upsert_Proc :: proc(ctx: rawptr, setting: domain.Bridge_Provider_Setting) -> (bool, domain.Domain_Error)
Bridge_Provider_Setting_List_Proc :: proc(ctx: rawptr, bridge_id: string) -> ([dynamic]domain.Bridge_Provider_Setting, domain.Domain_Error)

Provider_Repository :: struct {
	list_profiles: proc(ctx: rawptr, bridge_id: string) -> ([dynamic]domain.Bridge_Provider_Profile, domain.Domain_Error),
	reconcile_profiles: proc(ctx: rawptr, bridge_id: string, profiles: []domain.Bridge_Provider_Profile) -> domain.Domain_Error,
	profile_references: proc(ctx: rawptr, bridge_id, profile_id: string) -> (string, domain.Domain_Error),
	ctx:      rawptr,
	upsert_models: proc(ctx: rawptr, value: domain.Bridge_Provider_Models) -> domain.Domain_Error,
	list_models: proc(ctx: rawptr, bridge_id: string) -> ([dynamic]domain.Bridge_Provider_Models, domain.Domain_Error),
	create_extension_command: Provider_Extension_Command_Create_Proc,
	save_extension_command: Provider_Extension_Command_Save_Proc,
	list_extension_commands: Provider_Extension_Command_List_Proc,
	list:     Provider_Catalog_List_Proc,
	get:      Provider_Catalog_Get_Proc,
	get_icon: Provider_Icon_Get_Proc,
	get_etag: Provider_Catalog_Etag_Proc,
	upsert_status: Bridge_Provider_Status_Upsert_Proc,
	list_status: Bridge_Provider_Status_List_Proc,
	upsert_setting: Bridge_Provider_Setting_Upsert_Proc,
	list_settings: Bridge_Provider_Setting_List_Proc,
}

bridge_provider_status_upsert :: proc(repo: ^Provider_Repository, status: domain.Bridge_Provider_Status) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.upsert_status == nil do return false, domain.domain_error(.Internal_Error, "provider status repository is not configured")
	return repo.upsert_status(repo.ctx, status)
}

bridge_provider_status_list :: proc(repo: ^Provider_Repository, bridge_id: string) -> ([dynamic]domain.Bridge_Provider_Status, domain.Domain_Error) {
	if repo == nil || repo.list_status == nil do return nil, domain.domain_error(.Internal_Error, "provider status repository is not configured")
	return repo.list_status(repo.ctx, bridge_id)
}

bridge_provider_setting_upsert :: proc(repo: ^Provider_Repository, setting: domain.Bridge_Provider_Setting) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.upsert_setting == nil do return false, domain.domain_error(.Internal_Error, "provider setting repository is not configured")
	return repo.upsert_setting(repo.ctx, setting)
}

bridge_provider_setting_list :: proc(repo: ^Provider_Repository, bridge_id: string) -> ([dynamic]domain.Bridge_Provider_Setting, domain.Domain_Error) {
	if repo == nil || repo.list_settings == nil do return nil, domain.domain_error(.Internal_Error, "provider setting repository is not configured")
	return repo.list_settings(repo.ctx, bridge_id)
}

provider_catalog_list :: proc(repo: ^Provider_Repository) -> ([dynamic]domain.Provider_Catalog_Entry, domain.Domain_Error) {
	if repo == nil || repo.list == nil do return nil, domain.domain_error(.Internal_Error, "provider repository is not configured")
	return repo.list(repo.ctx)
}

provider_catalog_get :: proc(repo: ^Provider_Repository, provider: string) -> (domain.Provider_Catalog_Entry, bool, domain.Domain_Error) {
	if repo == nil || repo.get == nil do return {}, false, domain.domain_error(.Internal_Error, "provider repository is not configured")
	return repo.get(repo.ctx, provider)
}

provider_icon_get :: proc(repo: ^Provider_Repository, provider: string) -> (domain.Provider_Icon, bool, domain.Domain_Error) {
	if repo == nil || repo.get_icon == nil do return {}, false, domain.domain_error(.Internal_Error, "provider repository is not configured")
	return repo.get_icon(repo.ctx, provider)
}

provider_catalog_etag :: proc(repo: ^Provider_Repository) -> (string, domain.Domain_Error) {
	if repo == nil || repo.get_etag == nil do return "", domain.domain_error(.Internal_Error, "provider repository is not configured")
	return repo.get_etag(repo.ctx)
}

Provider_Extension_Command_Create_Proc :: proc(
	ctx: rawptr,
	command: domain.Provider_Extension_Command,
) -> (
	bool,
	domain.Domain_Error,
)
Provider_Extension_Command_Save_Proc :: proc(
	ctx: rawptr,
	command: domain.Provider_Extension_Command,
) -> domain.Domain_Error
Provider_Extension_Command_List_Proc :: proc(
	ctx: rawptr,
	bridge_id: string,
) -> (
	[dynamic]domain.Provider_Extension_Command,
	domain.Domain_Error,
)

provider_extension_command_create :: proc(
	repo: ^Provider_Repository,
	command: domain.Provider_Extension_Command,
) -> (
	bool,
	domain.Domain_Error,
) {
	if repo == nil || repo.create_extension_command == nil do return false, domain.domain_error(.Internal_Error, "extension command repository is not configured")
	return repo.create_extension_command(repo.ctx, command)
}
provider_extension_command_save :: proc(
	repo: ^Provider_Repository,
	command: domain.Provider_Extension_Command,
) -> domain.Domain_Error {
	if repo == nil || repo.save_extension_command == nil do return domain.domain_error(.Internal_Error, "extension command repository is not configured")
	return repo.save_extension_command(repo.ctx, command)
}
provider_extension_command_list :: proc(
	repo: ^Provider_Repository,
	bridge_id: string,
) -> (
	[dynamic]domain.Provider_Extension_Command,
	domain.Domain_Error,
) {
	if repo == nil || repo.list_extension_commands == nil do return nil, domain.domain_error(.Internal_Error, "extension command repository is not configured")
	return repo.list_extension_commands(repo.ctx, bridge_id)
}

bridge_provider_models_list :: proc(repo: ^Provider_Repository, bridge_id: string) -> ([dynamic]domain.Bridge_Provider_Models, domain.Domain_Error) {
	if repo == nil do return nil, domain.domain_error(.Internal_Error, "provider repository is not configured")
	// Optional for old repository implementations; no observation means static fallback.
	if repo.list_models == nil do return nil, {}
	return repo.list_models(repo.ctx, bridge_id)
}
bridge_provider_models_upsert :: proc(repo: ^Provider_Repository, value: domain.Bridge_Provider_Models) -> domain.Domain_Error {
	if repo == nil || repo.upsert_models == nil do return domain.domain_error(.Internal_Error, "model repository is not configured")
	return repo.upsert_models(repo.ctx, value)
}
