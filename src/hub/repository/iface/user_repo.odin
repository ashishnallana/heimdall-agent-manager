package iface

import domain "odin_test:hub/domain"

User_Get_By_ID_Proc :: proc(ctx: rawptr, user_id: domain.User_ID) -> (domain.User, bool, domain.Domain_Error)
User_Save_Proc :: proc(ctx: rawptr, user: domain.User) -> (domain.User, bool, domain.Domain_Error)

User_Repository :: struct {
	resolve_external: proc(ctx: rawptr, issuer, subject, username, display_name, email, now: string, provision, claim_existing: bool) -> (domain.User, bool, domain.Domain_Error),
 launch_preferences_get: Launch_Preferences_Get_Proc,
 launch_preferences_save: Launch_Preferences_Save_Proc,
	ctx: rawptr,
	get_by_id: User_Get_By_ID_Proc,
	save: User_Save_Proc,
}

user_get_by_id :: proc(repo: ^User_Repository, user_id: domain.User_ID) -> (domain.User, bool, domain.Domain_Error) {
	if repo == nil || repo.get_by_id == nil {
		return domain.User{}, false, domain.domain_error(.Internal_Error, "user repository is not configured")
	}
	return repo.get_by_id(repo.ctx, user_id)
}

user_save :: proc(repo: ^User_Repository, user: domain.User) -> (domain.User, bool, domain.Domain_Error) {
	if repo == nil || repo.save == nil {
		return domain.User{}, false, domain.domain_error(.Internal_Error, "user repository is not configured")
	}
	return repo.save(repo.ctx, user)
}




