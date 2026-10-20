package iface

import domain "odin_test:hub/domain"

Card_Create_Proc :: proc(ctx: rawptr, card: domain.Card) -> (domain.Card, bool, domain.Domain_Error)
Card_Get_Proc :: proc(ctx: rawptr, id: domain.Card_ID) -> (domain.Card, bool, domain.Domain_Error)
Card_List_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Card, domain.Domain_Error)
Card_List_By_Project_Proc :: proc(ctx: rawptr, project_id: domain.Project_ID) -> ([]domain.Card, domain.Domain_Error)
Card_Update_Status_Proc :: proc(ctx: rawptr, id: domain.Card_ID, status: string, updated_at: string) -> (bool, domain.Domain_Error)
Card_Update_Proc :: proc(ctx: rawptr, card: domain.Card) -> (domain.Card, bool, domain.Domain_Error)
Card_Delete_Proc :: proc(ctx: rawptr, id: domain.Card_ID) -> (bool, domain.Domain_Error)

Card_Repository :: struct {
	ctx: rawptr,
	create: Card_Create_Proc,
	get: Card_Get_Proc,
	list: Card_List_Proc,
	list_by_project: Card_List_By_Project_Proc,
	update_status: Card_Update_Status_Proc,
	update: Card_Update_Proc,
	delete_card: Card_Delete_Proc,
}

card_create :: proc(repo: ^Card_Repository, card: domain.Card) -> (domain.Card, bool, domain.Domain_Error) {
	if repo == nil || repo.create == nil do return domain.Card{}, false, domain.domain_error(.Internal_Error, "card repository is not configured")
	return repo.create(repo.ctx, card)
}

card_get :: proc(repo: ^Card_Repository, id: domain.Card_ID) -> (domain.Card, bool, domain.Domain_Error) {
	if repo == nil || repo.get == nil do return domain.Card{}, false, domain.domain_error(.Internal_Error, "card repository is not configured")
	return repo.get(repo.ctx, id)
}

card_list :: proc(repo: ^Card_Repository, owner_user_id: domain.User_ID) -> ([]domain.Card, domain.Domain_Error) {
	if repo == nil || repo.list == nil do return nil, domain.domain_error(.Internal_Error, "card repository is not configured")
	return repo.list(repo.ctx, owner_user_id)
}

card_update_status :: proc(repo: ^Card_Repository, id: domain.Card_ID, status: string, updated_at: string) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.update_status == nil do return false, domain.domain_error(.Internal_Error, "card repository is not configured")
	return repo.update_status(repo.ctx, id, status, updated_at)
}

card_update :: proc(repo: ^Card_Repository, card: domain.Card) -> (domain.Card, bool, domain.Domain_Error) {
	if repo == nil || repo.update == nil do return domain.Card{}, false, domain.domain_error(.Internal_Error, "card repository is not configured")
	return repo.update(repo.ctx, card)
}

card_delete :: proc(repo: ^Card_Repository, id: domain.Card_ID) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.delete_card == nil do return false, domain.domain_error(.Internal_Error, "card repository is not configured")
	return repo.delete_card(repo.ctx, id)
}
