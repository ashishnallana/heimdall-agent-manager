package iface

import domain "odin_test:hub/domain"

Issue_Save_Proc :: proc(ctx: rawptr, issue: domain.Issue) -> (domain.Issue, bool, domain.Domain_Error)
Issue_Get_Proc :: proc(ctx: rawptr, issue_id: domain.Issue_ID, owner_user_id: domain.User_ID) -> (domain.Issue, bool, domain.Domain_Error)
Issue_List_Proc :: proc(ctx: rawptr, filter: domain.Issue_Filter) -> ([]domain.Issue, domain.Domain_Error)
Issue_Update_Proc :: proc(ctx: rawptr, issue: domain.Issue) -> (domain.Issue, bool, domain.Domain_Error)
Issue_Delete_Proc :: proc(ctx: rawptr, issue_id: domain.Issue_ID, owner_user_id: domain.User_ID) -> (bool, domain.Domain_Error)

Issue_Comment_Save_Proc :: proc(ctx: rawptr, comment: domain.Issue_Comment) -> (domain.Issue_Comment, bool, domain.Domain_Error)
Issue_Comment_Get_Proc :: proc(ctx:rawptr,id:domain.Issue_Comment_ID,owner:domain.User_ID)->(domain.Issue_Comment,bool,domain.Domain_Error)
Issue_Comment_List_Proc :: proc(ctx: rawptr, issue_id: domain.Issue_ID, owner_user_id: domain.User_ID) -> ([]domain.Issue_Comment, domain.Domain_Error)
Issue_Comment_Delete_Proc :: proc(ctx: rawptr, comment_id: domain.Issue_Comment_ID, owner_user_id: domain.User_ID) -> (bool, domain.Domain_Error)

Issue_Vote_Save_Proc :: proc(ctx: rawptr, vote: domain.Issue_Vote) -> (bool, domain.Domain_Error)
Issue_Vote_Remove_Proc :: proc(ctx: rawptr, issue_id: domain.Issue_ID, voter_id: string, owner_user_id: domain.User_ID) -> (bool, domain.Domain_Error)
Issue_Vote_Has_Proc :: proc(ctx: rawptr, issue_id: domain.Issue_ID, voter_id: string) -> (bool, domain.Domain_Error)
Issue_Vote_Count_Proc :: proc(ctx: rawptr, issue_id: domain.Issue_ID) -> (int, domain.Domain_Error)
Issue_Vote_List_Proc :: proc(ctx: rawptr, issue_id: domain.Issue_ID) -> ([]domain.Issue_Vote, domain.Domain_Error)

Issue_Repository :: struct {
	get_comment:Issue_Comment_Get_Proc,
	ctx:            rawptr,
	save:           Issue_Save_Proc,
	get:            Issue_Get_Proc,
	list:           Issue_List_Proc,
	update:         Issue_Update_Proc,
	delete_issue:   Issue_Delete_Proc,
	save_comment:   Issue_Comment_Save_Proc,
	list_comments:  Issue_Comment_List_Proc,
	delete_comment: Issue_Comment_Delete_Proc,
	save_vote:      Issue_Vote_Save_Proc,
	remove_vote:    Issue_Vote_Remove_Proc,
	has_voted:      Issue_Vote_Has_Proc,
	vote_count:     Issue_Vote_Count_Proc,
	list_votes:     Issue_Vote_List_Proc,
}

issue_save :: proc(repo: ^Issue_Repository, issue: domain.Issue) -> (domain.Issue, bool, domain.Domain_Error) {
	if repo == nil || repo.save == nil do return domain.Issue{}, false, domain.domain_error(.Internal_Error, "issue repository is not configured")
	return repo.save(repo.ctx, issue)
}

issue_get :: proc(repo: ^Issue_Repository, issue_id: domain.Issue_ID, owner_user_id: domain.User_ID) -> (domain.Issue, bool, domain.Domain_Error) {
	if repo == nil || repo.get == nil do return domain.Issue{}, false, domain.domain_error(.Internal_Error, "issue repository is not configured")
	return repo.get(repo.ctx, issue_id, owner_user_id)
}

issue_list :: proc(repo: ^Issue_Repository, filter: domain.Issue_Filter) -> ([]domain.Issue, domain.Domain_Error) {
	if repo == nil || repo.list == nil do return nil, domain.domain_error(.Internal_Error, "issue repository is not configured")
	return repo.list(repo.ctx, filter)
}

issue_update :: proc(repo: ^Issue_Repository, issue: domain.Issue) -> (domain.Issue, bool, domain.Domain_Error) {
	if repo == nil || repo.update == nil do return domain.Issue{}, false, domain.domain_error(.Internal_Error, "issue repository is not configured")
	return repo.update(repo.ctx, issue)
}

issue_delete :: proc(repo: ^Issue_Repository, issue_id: domain.Issue_ID, owner_user_id: domain.User_ID) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.delete_issue == nil do return false, domain.domain_error(.Internal_Error, "issue repository is not configured")
	return repo.delete_issue(repo.ctx, issue_id, owner_user_id)
}

issue_save_comment :: proc(repo: ^Issue_Repository, comment: domain.Issue_Comment) -> (domain.Issue_Comment, bool, domain.Domain_Error) {
	if repo == nil || repo.save_comment == nil do return domain.Issue_Comment{}, false, domain.domain_error(.Internal_Error, "issue repository is not configured")
	return repo.save_comment(repo.ctx, comment)
}

issue_list_comments :: proc(repo: ^Issue_Repository, issue_id: domain.Issue_ID, owner_user_id: domain.User_ID) -> ([]domain.Issue_Comment, domain.Domain_Error) {
	if repo == nil || repo.list_comments == nil do return nil, domain.domain_error(.Internal_Error, "issue repository is not configured")
	return repo.list_comments(repo.ctx, issue_id, owner_user_id)
}

issue_delete_comment :: proc(repo: ^Issue_Repository, comment_id: domain.Issue_Comment_ID, owner_user_id: domain.User_ID) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.delete_comment == nil do return false, domain.domain_error(.Internal_Error, "issue repository is not configured")
	return repo.delete_comment(repo.ctx, comment_id, owner_user_id)
}

issue_save_vote :: proc(repo: ^Issue_Repository, vote: domain.Issue_Vote) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.save_vote == nil do return false, domain.domain_error(.Internal_Error, "issue repository is not configured")
	return repo.save_vote(repo.ctx, vote)
}

issue_remove_vote :: proc(repo: ^Issue_Repository, issue_id: domain.Issue_ID, voter_id: string, owner_user_id: domain.User_ID) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.remove_vote == nil do return false, domain.domain_error(.Internal_Error, "issue repository is not configured")
	return repo.remove_vote(repo.ctx, issue_id, voter_id, owner_user_id)
}

issue_has_voted :: proc(repo: ^Issue_Repository, issue_id: domain.Issue_ID, voter_id: string) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.has_voted == nil do return false, domain.domain_error(.Internal_Error, "issue repository is not configured")
	return repo.has_voted(repo.ctx, issue_id, voter_id)
}

issue_vote_count :: proc(repo: ^Issue_Repository, issue_id: domain.Issue_ID) -> (int, domain.Domain_Error) {
	if repo == nil || repo.vote_count == nil do return 0, domain.domain_error(.Internal_Error, "issue repository is not configured")
	return repo.vote_count(repo.ctx, issue_id)
}

issue_list_votes :: proc(repo: ^Issue_Repository, issue_id: domain.Issue_ID) -> ([]domain.Issue_Vote, domain.Domain_Error) {
	if repo == nil || repo.list_votes == nil do return nil, domain.domain_error(.Internal_Error, "issue repository is not configured")
	return repo.list_votes(repo.ctx, issue_id)
}
