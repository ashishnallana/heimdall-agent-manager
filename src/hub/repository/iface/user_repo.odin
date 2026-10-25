package iface

import domain "odin_test:hub/domain"

User_Get_By_ID_Proc :: proc(ctx: rawptr, user_id: domain.User_ID) -> (domain.User, bool, domain.Domain_Error)
User_Save_Proc :: proc(ctx: rawptr, user: domain.User) -> (domain.User, bool, domain.Domain_Error)
User_Token_Save_Proc :: proc(ctx: rawptr, token: domain.User_API_Token) -> (domain.User_API_Token, bool, domain.Domain_Error)
User_Token_Get_By_ID_Proc :: proc(ctx: rawptr, token_id: string) -> (domain.User_API_Token, bool, domain.Domain_Error)
User_Token_Get_By_Hash_Proc :: proc(ctx: rawptr, token_hash: string) -> (domain.User_API_Token, bool, domain.Domain_Error)
User_Token_List_By_Owner_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.User_API_Token, domain.Domain_Error)

User_Repository :: struct {
	resolve_external: proc(ctx: rawptr, issuer, subject, username, display_name, email, now: string, provision: bool) -> (domain.User, bool, domain.Domain_Error),
 launch_preferences_get: Launch_Preferences_Get_Proc,
 launch_preferences_save: Launch_Preferences_Save_Proc,
	ctx: rawptr,
	get_by_id: User_Get_By_ID_Proc,
	save: User_Save_Proc,
	save_token: User_Token_Save_Proc,
	get_token_by_id: User_Token_Get_By_ID_Proc,
	get_token_by_hash: User_Token_Get_By_Hash_Proc,
	list_tokens_by_owner: User_Token_List_By_Owner_Proc,
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

user_token_save :: proc(repo: ^User_Repository, token: domain.User_API_Token) -> (domain.User_API_Token, bool, domain.Domain_Error) {
	if repo == nil || repo.save_token == nil do return domain.User_API_Token{}, false, domain.domain_error(.Internal_Error, "user token repository is not configured")
	return repo.save_token(repo.ctx, token)
}

user_token_get_by_id :: proc(repo: ^User_Repository, token_id: string) -> (domain.User_API_Token, bool, domain.Domain_Error) {
	if repo == nil || repo.get_token_by_id == nil do return domain.User_API_Token{}, false, domain.domain_error(.Internal_Error, "user token repository is not configured")
	return repo.get_token_by_id(repo.ctx, token_id)
}

user_token_get_by_hash :: proc(repo: ^User_Repository, token_hash: string) -> (domain.User_API_Token, bool, domain.Domain_Error) {
	if repo == nil || repo.get_token_by_hash == nil do return domain.User_API_Token{}, false, domain.domain_error(.Internal_Error, "user token repository is not configured")
	return repo.get_token_by_hash(repo.ctx, token_hash)
}

user_token_list_by_owner :: proc(repo: ^User_Repository, owner_user_id: domain.User_ID) -> ([]domain.User_API_Token, domain.Domain_Error) {
	if repo == nil || repo.list_tokens_by_owner == nil do return nil, domain.domain_error(.Internal_Error, "user token repository is not configured")
	return repo.list_tokens_by_owner(repo.ctx, owner_user_id)
}
