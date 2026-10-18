package http

import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import auth_service "odin_test:hub/service/auth"
import issue_service "odin_test:hub/service/issue"

Issue_Handlers :: struct {
	auth:   ^auth_service.Auth_Service,
	issues: ^issue_service.Issue_Service,
	clock:  ^platform.Clock,
}

issue_description_preview :: proc(desc: string, max_len: int = 160) -> string {
	trimmed := strings.trim_space(desc)
	if trimmed == "" do return ""
	if domain.contains_vault_token(trimmed) {
		return strings.clone(trimmed)
	}
	fields := strings.fields(trimmed)
	defer delete(fields)
	if len(fields) == 0 do return ""

	b := strings.builder_make()
	count := 0
	first := true
	for f in fields {
		clean := f
		if strings.has_prefix(clean, "#") {
			clean = strings.trim_left(clean, "#")
		}
		if clean == "-" || clean == "*" || clean == ">" {
			continue
		}
		if len(clean) == 0 do continue

		if !first {
			if count + 1 > max_len do break
			strings.write_byte(&b, ' ')
			count += 1
		}

		for r in clean {
			if count >= max_len do break
			strings.write_rune(&b, r)
			count += 1
		}
		first = false
		if count >= max_len do break
	}

	return strings.to_string(b)
}

write_issue_lean_json :: proc(b: ^strings.Builder, iss: domain.Issue) {
	strings.write_string(b, "{\"issue_id\":\"")
	write_handler_json_string(b, string(iss.issue_id))
	strings.write_string(b, "\",\"owner_user_id\":\"")
	write_handler_json_string(b, string(iss.owner_user_id))
	strings.write_string(b, "\",\"title\":\"")
	write_handler_json_string(b, iss.title)
	preview := issue_description_preview(iss.description, 160)
	defer if len(preview) > 0 do delete(preview)
	strings.write_string(b, "\",\"description_preview\":\"")
	write_handler_json_string(b, preview)
	strings.write_string(b, "\",\"created_by\":\"")
	write_handler_json_string(b, iss.created_by)
	strings.write_string(b, "\",\"status\":\"")
	write_handler_json_string(b, domain.issue_status_string(iss.status))
	strings.write_string(b, "\",\"scope_type\":\"")
	write_handler_json_string(b, domain.issue_scope_type_string(iss.scope_type))
	strings.write_string(b, "\",\"target_id\":\"")
	write_handler_json_string(b, iss.target_id)
	strings.write_string(b, "\",\"chain_id\":\"")
	write_handler_json_string(b, iss.chain_id)
	strings.write_string(b, "\",\"created_at\":\"")
	write_handler_json_string(b, iss.created_at)
	strings.write_string(b, "\",\"updated_at\":\"")
	write_handler_json_string(b, iss.updated_at)
	strings.write_string(b, "\",\"closed_at\":\"")
	write_handler_json_string(b, iss.closed_at)
	strings.write_string(b, fmt.tprintf("\",\"vote_count\":%d", iss.vote_count))
	strings.write_string(b, fmt.tprintf(",\"comment_count\":%d", iss.comment_count))
	strings.write_string(b, fmt.tprintf(",\"has_voted\":%s", iss.has_voted ? "true" : "false"))
	strings.write_string(b, "}")
}

write_issue_detail_json :: proc(b: ^strings.Builder, iss: domain.Issue, comments: []domain.Issue_Comment) {
	strings.write_string(b, "{\"issue_id\":\"")
	write_handler_json_string(b, string(iss.issue_id))
	strings.write_string(b, "\",\"owner_user_id\":\"")
	write_handler_json_string(b, string(iss.owner_user_id))
	strings.write_string(b, "\",\"title\":\"")
	write_handler_json_string(b, iss.title)
	strings.write_string(b, "\",\"description\":\"")
	write_handler_json_string(b, iss.description)
	strings.write_string(b, "\",\"created_by\":\"")
	write_handler_json_string(b, iss.created_by)
	strings.write_string(b, "\",\"status\":\"")
	write_handler_json_string(b, domain.issue_status_string(iss.status))
	strings.write_string(b, "\",\"scope_type\":\"")
	write_handler_json_string(b, domain.issue_scope_type_string(iss.scope_type))
	strings.write_string(b, "\",\"target_id\":\"")
	write_handler_json_string(b, iss.target_id)
	strings.write_string(b, "\",\"chain_id\":\"")
	write_handler_json_string(b, iss.chain_id)
	strings.write_string(b, "\",\"created_at\":\"")
	write_handler_json_string(b, iss.created_at)
	strings.write_string(b, "\",\"updated_at\":\"")
	write_handler_json_string(b, iss.updated_at)
	strings.write_string(b, "\",\"closed_at\":\"")
	write_handler_json_string(b, iss.closed_at)
	strings.write_string(b, fmt.tprintf("\",\"vote_count\":%d", iss.vote_count))
	strings.write_string(b, fmt.tprintf(",\"comment_count\":%d", iss.comment_count))
	strings.write_string(b, fmt.tprintf(",\"has_voted\":%s", iss.has_voted ? "true" : "false"))
	strings.write_string(b, ",\"comments\":[")
	for c, i in comments {
		if i > 0 do strings.write_byte(b, ',')
		write_issue_comment_json(b, c)
	}
	strings.write_string(b, "]}")
}

write_issue_json :: proc(b: ^strings.Builder, iss: domain.Issue) {
	write_issue_detail_json(b, iss, nil)
}

write_issue_comment_json :: proc(b: ^strings.Builder, c: domain.Issue_Comment) {
	strings.write_string(b, "{\"comment_id\":\"")
	write_handler_json_string(b, string(c.comment_id))
	strings.write_string(b, "\",\"issue_id\":\"")
	write_handler_json_string(b, string(c.issue_id))
	strings.write_string(b, "\",\"owner_user_id\":\"")
	write_handler_json_string(b, string(c.owner_user_id))
	strings.write_string(b, "\",\"author_id\":\"")
	write_handler_json_string(b, c.author_id)
	strings.write_string(b, "\",\"author_name\":\"")
	write_handler_json_string(b, c.author_name)
	strings.write_string(b, "\",\"body\":\"")
	write_handler_json_string(b, c.body)
	strings.write_string(b, "\",\"created_at\":\"")
	write_handler_json_string(b, c.created_at)
	strings.write_string(b, "\",\"updated_at\":\"")
	write_handler_json_string(b, c.updated_at)
	strings.write_string(b, "\"}")
}

write_issue_vote_json :: proc(b: ^strings.Builder, v: domain.Issue_Vote) {
	strings.write_string(b, "{\"issue_id\":\"")
	write_handler_json_string(b, string(v.issue_id))
	strings.write_string(b, "\",\"voter_id\":\"")
	write_handler_json_string(b, v.voter_id)
	strings.write_string(b, "\",\"owner_user_id\":\"")
	write_handler_json_string(b, string(v.owner_user_id))
	strings.write_string(b, "\",\"voter_name\":\"")
	write_handler_json_string(b, v.voter_name)
	strings.write_string(b, "\",\"created_at\":\"")
	write_handler_json_string(b, v.created_at)
	strings.write_string(b, "\"}")
}

list_issues_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Issue_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	limit := query_int(req.query, "limit", contracts.API_DEFAULT_PAGE_LIMIT)
	if limit <= 0 do limit = contracts.API_DEFAULT_PAGE_LIMIT
	if limit > contracts.API_MAX_PAGE_LIMIT do limit = contracts.API_MAX_PAGE_LIMIT
	offset := query_int(req.query, "offset", 0)
	if offset < 0 do offset = 0

	scope := query_value(req.query, "scope")
	if scope == "" do scope = query_value(req.query, "scope_type")

	q := query_value(req.query, "q")
	if q == "" do q = query_value(req.query, "query")

	voter_id := query_value(req.query, "voter_id")
	if voter_id == "" && auth_ctx.kind == .Instance_Token && auth_ctx.agent_instance_id != "" {
		voter_id = auth_ctx.agent_instance_id
	}
	if voter_id == "" && auth_ctx.user_id != "" {
		voter_id = auth_ctx.user_id
	}

	filter := issue_service.Issue_Filter_Input{
		status     = query_value(req.query, "status"),
		scope_type = scope,
		target_id  = query_value(req.query, "target_id"),
		chain_id   = query_value(req.query, "chain_id"),
		query      = q,
		voter_id   = voter_id,
		limit      = limit,
		offset     = offset,
	}

	issues, err := issue_service.list_issues(h.issues, auth_ctx, filter)
	if err.code != .None do return respond_error(err, req.request_id)
	defer delete(issues)

	b := strings.builder_make()
	strings.write_byte(&b, '[')
	for iss, i in issues {
		if i > 0 do strings.write_byte(&b, ',')
		write_issue_lean_json(&b, iss)
	}
	strings.write_byte(&b, ']')

	return respond_list(strings.to_string(b), contracts.API_Page{limit = limit, has_more = len(issues) >= limit}, req.request_id, auth_ctx_server_time(req))
}

create_issue_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Issue_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	created_by := json_string(req.body, "created_by")
	if created_by == "" && auth_ctx.kind == .Instance_Token && auth_ctx.agent_instance_id != "" {
		created_by = auth_ctx.agent_instance_id
	}
	if created_by == "" do created_by = auth_ctx.user_id

	scope_type := json_string(req.body, "scope_type")
	if scope_type == "" do scope_type = json_string(req.body, "scope")

	input := issue_service.Issue_Create_Input{
		title       = json_string(req.body, "title"),
		description = json_string(req.body, "description"),
		created_by  = created_by,
		scope_type  = scope_type,
		target_id   = json_string(req.body, "target_id"),
		chain_id    = json_string(req.body, "chain_id"),
	}

	issue, saved, err := issue_service.create_issue(h.issues, auth_ctx, input)
	if !saved do return respond_error(err, req.request_id)

	b := strings.builder_make()
	write_issue_detail_json(&b, issue, nil)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

get_issue_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Issue_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	id := domain.Issue_ID(path_part(req.path, 4))
	voter_id := query_value(req.query, "voter_id")
	if voter_id == "" && auth_ctx.kind == .Instance_Token && auth_ctx.agent_instance_id != "" {
		voter_id = auth_ctx.agent_instance_id
	}
	if voter_id == "" && auth_ctx.user_id != "" {
		voter_id = auth_ctx.user_id
	}

	issue, got, err := issue_service.get_issue(h.issues, auth_ctx, id, voter_id)
	if !got do return respond_error(err, req.request_id)

	comments, _ := issue_service.list_comments(h.issues, auth_ctx, id)
	defer delete(comments)

	b := strings.builder_make()
	write_issue_detail_json(&b, issue, comments)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

patch_issue_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Issue_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	id := domain.Issue_ID(path_part(req.path, 4))

	scope_type := json_string(req.body, "scope_type")
	has_scope := json_key_present(req.body, "scope_type")
	if !has_scope && json_key_present(req.body, "scope") {
		scope_type = json_string(req.body, "scope")
		has_scope = true
	}

	input := issue_service.Issue_Update_Input{
		has_title   = json_key_present(req.body, "title"),
		title       = json_string(req.body, "title"),
		has_desc    = json_key_present(req.body, "description"),
		description = json_string(req.body, "description"),
		has_status  = json_key_present(req.body, "status"),
		status      = json_string(req.body, "status"),
		has_scope   = has_scope,
		scope_type  = scope_type,
		has_target  = json_key_present(req.body, "target_id"),
		target_id   = json_string(req.body, "target_id"),
		has_chain   = json_key_present(req.body, "chain_id"),
		chain_id    = json_string(req.body, "chain_id"),
	}

	issue, updated, err := issue_service.update_issue(h.issues, auth_ctx, id, input)
	if !updated do return respond_error(err, req.request_id)

	voter_id := query_value(req.query, "voter_id")
	if voter_id == "" && auth_ctx.kind == .Instance_Token && auth_ctx.agent_instance_id != "" {
		voter_id = auth_ctx.agent_instance_id
	}
	if voter_id == "" && auth_ctx.user_id != "" {
		voter_id = auth_ctx.user_id
	}
	if full_iss, got, _ := issue_service.get_issue(h.issues, auth_ctx, id, voter_id); got {
		issue = full_iss
	}

	comments, _ := issue_service.list_comments(h.issues, auth_ctx, id)
	defer delete(comments)

	b := strings.builder_make()
	write_issue_detail_json(&b, issue, comments)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

delete_issue_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Issue_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	id := domain.Issue_ID(path_part(req.path, 4))
	deleted, err := issue_service.delete_issue(h.issues, auth_ctx, id)
	if !deleted {
		if err.code != .None do return respond_error(err, req.request_id)
		return respond_error(domain.domain_error(.Not_Found, "issue not found"), req.request_id)
	}

	return respond_success("{\"deleted\":true}", req.request_id, auth_ctx_server_time(req))
}

list_issue_comments_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Issue_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	id := domain.Issue_ID(path_part(req.path, 4))
	comments, err := issue_service.list_comments(h.issues, auth_ctx, id)
	if err.code != .None do return respond_error(err, req.request_id)
	defer delete(comments)

	b := strings.builder_make()
	strings.write_byte(&b, '[')
	for c, i in comments {
		if i > 0 do strings.write_byte(&b, ',')
		write_issue_comment_json(&b, c)
	}
	strings.write_byte(&b, ']')

	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

create_issue_comment_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Issue_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	id := domain.Issue_ID(path_part(req.path, 4))

	author_id := json_string(req.body, "author_id")
	if author_id == "" && auth_ctx.kind == .Instance_Token && auth_ctx.agent_instance_id != "" {
		author_id = auth_ctx.agent_instance_id
	}
	if author_id == "" do author_id = auth_ctx.user_id

	author_name := json_string(req.body, "author_name")
	if author_name == "" && auth_ctx.display_name != "" {
		author_name = auth_ctx.display_name
	} else if author_name == "" && auth_ctx.name != "" {
		author_name = auth_ctx.name
	}

	input := issue_service.Issue_Comment_Input{
		author_id   = author_id,
		author_name = author_name,
		body        = json_string(req.body, "body"),
	}

	comment, saved, err := issue_service.add_comment(h.issues, auth_ctx, id, input)
	if !saved do return respond_error(err, req.request_id)

	b := strings.builder_make()
	write_issue_comment_json(&b, comment)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

delete_issue_comment_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Issue_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	comment_id := domain.Issue_Comment_ID(path_part(req.path, 6))
	deleted, err := issue_service.delete_comment(h.issues, auth_ctx, comment_id)
	if !deleted {
		if err.code != .None do return respond_error(err, req.request_id)
		return respond_error(domain.domain_error(.Not_Found, "comment not found"), req.request_id)
	}

	return respond_success("{\"deleted\":true}", req.request_id, auth_ctx_server_time(req))
}

list_issue_votes_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Issue_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	id := domain.Issue_ID(path_part(req.path, 4))
	votes, err := issue_service.list_votes(h.issues, auth_ctx, id)
	if err.code != .None do return respond_error(err, req.request_id)
	defer delete(votes)

	b := strings.builder_make()
	strings.write_byte(&b, '[')
	for v, i in votes {
		if i > 0 do strings.write_byte(&b, ',')
		write_issue_vote_json(&b, v)
	}
	strings.write_byte(&b, ']')

	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

vote_issue_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Issue_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	id := domain.Issue_ID(path_part(req.path, 4))

	voter_id := json_string(req.body, "voter_id")
	if voter_id == "" && auth_ctx.kind == .Instance_Token && auth_ctx.agent_instance_id != "" {
		voter_id = auth_ctx.agent_instance_id
	}
	if voter_id == "" do voter_id = auth_ctx.user_id

	voter_name := json_string(req.body, "voter_name")
	if voter_name == "" && auth_ctx.display_name != "" {
		voter_name = auth_ctx.display_name
	} else if voter_name == "" && auth_ctx.name != "" {
		voter_name = auth_ctx.name
	}

	voted, err := issue_service.vote_issue(h.issues, auth_ctx, id, voter_id, voter_name)
	if !voted do return respond_error(err, req.request_id)

	return respond_success("{\"voted\":true}", req.request_id, auth_ctx_server_time(req), 200)
}

unvote_issue_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Issue_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	id := domain.Issue_ID(path_part(req.path, 4))

	voter_id := json_string(req.body, "voter_id")
	if voter_id == "" do voter_id = query_value(req.query, "voter_id")
	if voter_id == "" && auth_ctx.kind == .Instance_Token && auth_ctx.agent_instance_id != "" {
		voter_id = auth_ctx.agent_instance_id
	}
	if voter_id == "" do voter_id = auth_ctx.user_id

	unvoted, err := issue_service.unvote_issue(h.issues, auth_ctx, id, voter_id)
	if !unvoted {
		if err.code != .None do return respond_error(err, req.request_id)
		return respond_error(domain.domain_error(.Not_Found, "vote not found"), req.request_id)
	}

	return respond_success("{\"unvoted\":true}", req.request_id, auth_ctx_server_time(req), 200)
}
