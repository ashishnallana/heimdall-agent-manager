package http

import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import auth_service "odin_test:hub/service/auth"
import project_service "odin_test:hub/service/project"

Project_Handlers :: struct { auth: ^auth_service.Auth_Service, projects: ^project_service.Project_Service }

list_projects_handler :: proc(ctx: rawptr, req: Request) -> Response {
	// Accept user tokens AND bridge-relayed instance tokens so a coordinator agent
	// can DISCOVER projects it owns (H5); list is same-owner scoped in the service.
	h := (^Project_Handlers)(ctx); auth_ctx, ok, auth_resp := require_auth_any(h.auth, req); if !ok do return auth_resp
	limit := query_int(req.query, "limit", 50)
	if limit <= 0 do limit = 50
	if limit > 200 do limit = 200
	cursor := query_value(req.query, "cursor")
	projects, err := project_service.list(h.projects, auth_ctx, limit, cursor); if err.code != .None do return respond_error(err, req.request_id)
	b := strings.builder_make(); strings.write_byte(&b, '[')
	next_cursor := ""
	for p, i in projects { if i > 0 do strings.write_byte(&b, ','); write_project_json(&b, p); next_cursor = p.created_at }
	strings.write_byte(&b, ']')
	has_more := len(projects) >= limit
	return respond_list(strings.to_string(b), contracts.API_Page{limit = limit, next_cursor = next_cursor if has_more else "", has_more = has_more}, req.request_id, auth_ctx_server_time(req))
}

create_project_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Project_Handlers)(ctx); auth_ctx, ok, auth_resp := require_auth(h.auth, req); if !ok do return auth_resp
	p, created, err := project_service.create(h.projects, auth_ctx, project_input(req.body)); if !created do return respond_error(err, req.request_id)
	b := strings.builder_make(); write_project_json(&b, p); return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

project_detail_handler :: proc(ctx: rawptr, req: Request) -> Response {
	if strings.contains(suffix_after(req.path, "/api/v1/projects/"), "/") do return respond_error(domain.domain_error(.Not_Found, "route not found"), req.request_id)
	h := (^Project_Handlers)(ctx); auth_ctx, ok, auth_resp := require_auth(h.auth, req); if !ok do return auth_resp
	p, got, err := project_service.get(h.projects, auth_ctx, domain.Project_ID(path_part(req.path, 4))); if !got do return respond_error(err, req.request_id)
	paths, _ := project_service.list_bridge_paths(h.projects, auth_ctx, p.project_id)
	b := strings.builder_make(); write_project_detail_json(&b, p, paths); return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

update_project_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Project_Handlers)(ctx); auth_ctx, ok, auth_resp := require_auth(h.auth, req); if !ok do return auth_resp
	p, updated, err := project_service.update(h.projects, auth_ctx, domain.Project_ID(path_part(req.path, 4)), update_input(req.body)); if !updated do return respond_error(err, req.request_id)
	b := strings.builder_make(); write_project_json(&b, p); return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

archive_project_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Project_Handlers)(ctx); auth_ctx, ok, auth_resp := require_auth(h.auth, req); if !ok do return auth_resp
	p, archived, err := project_service.archive_project(h.projects, auth_ctx, domain.Project_ID(path_part(req.path, 4))); if !archived do return respond_error(err, req.request_id)
	b := strings.builder_make(); write_project_json(&b, p); return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

unarchive_project_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Project_Handlers)(ctx); auth_ctx, ok, auth_resp := require_auth(h.auth, req); if !ok do return auth_resp
	p, restored, err := project_service.unarchive_project(h.projects, auth_ctx, domain.Project_ID(path_part(req.path, 4))); if !restored do return respond_error(err, req.request_id)
	b := strings.builder_make(); write_project_json(&b, p); return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

put_project_bridge_path_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Project_Handlers)(ctx); auth_ctx, ok, auth_resp := require_auth(h.auth, req); if !ok do return auth_resp
	path, saved, err := project_service.set_bridge_path(h.projects, auth_ctx, domain.Project_ID(path_part(req.path, 4)), path_part(req.path, 6), project_service.Bridge_Path_Input{path = json_string(req.body, "path")}); if !saved do return respond_error(err, req.request_id)
	b := strings.builder_make(); write_path_json(&b, path); return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

delete_project_bridge_path_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Project_Handlers)(ctx); auth_ctx, ok, auth_resp := require_auth(h.auth, req); if !ok do return auth_resp
	deleted, err := project_service.delete_bridge_path(h.projects, auth_ctx, domain.Project_ID(path_part(req.path, 4)), path_part(req.path, 6)); if !deleted do return respond_error(err, req.request_id)
	return respond_success("{\"deleted\":true}", req.request_id, auth_ctx_server_time(req))
}

validate_project_bridge_path_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Project_Handlers)(ctx); auth_ctx, ok, auth_resp := require_auth(h.auth, req); if !ok do return auth_resp
	result, validated, err := project_service.validate_bridge_path(h.projects, auth_ctx, domain.Project_ID(path_part(req.path, 4)), path_part(req.path, 6)); if !validated do return respond_error(err, req.request_id)
	b := strings.builder_make(); write_path_json(&b, result.path); return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

project_input :: proc(body: string) -> project_service.Create_Project_Input { return project_service.Create_Project_Input{name = json_string(body, "name"), slug = json_string(body, "slug"), description = json_string(body, "description"), repo_url = json_string(body, "repo_url"), vcs_kind = json_string(body, "vcs_kind"), default_path = json_string(body, "default_path"), owner_user_id = json_string(body, "owner_user_id")} }
update_input :: proc(body: string) -> project_service.Update_Project_Input { return project_service.Update_Project_Input{name = json_string(body, "name"), slug = json_string(body, "slug"), description = json_string(body, "description"), repo_url = json_string(body, "repo_url"), vcs_kind = json_string(body, "vcs_kind"), default_path = json_string(body, "default_path"), owner_user_id = json_string(body, "owner_user_id")} }

write_project_json :: proc(b: ^strings.Builder, p: domain.Project) { strings.write_string(b, "{\"project_id\":\""); write_handler_json_string(b, string(p.project_id)); strings.write_string(b, "\",\"name\":\""); write_handler_json_string(b, p.name); strings.write_string(b, "\",\"slug\":\""); write_handler_json_string(b, p.slug); strings.write_string(b, "\",\"description\":\""); write_handler_json_string(b, p.description); strings.write_string(b, "\",\"repo_url\":\""); write_handler_json_string(b, p.repo_url); strings.write_string(b, "\",\"vcs_kind\":\""); write_handler_json_string(b, p.vcs_kind); strings.write_string(b, "\",\"default_path\":\""); write_handler_json_string(b, p.default_path); strings.write_string(b, "\",\"state\":\""); write_handler_json_string(b, domain.project_state_string(p.state)); strings.write_string(b, "\",\"updated_at\":\""); write_handler_json_string(b, p.updated_at); strings.write_string(b, "\"}") }
write_project_detail_json :: proc(b: ^strings.Builder, p: domain.Project, paths: []domain.Project_Bridge_Path) {
	strings.write_string(b, "{\"project_id\":\""); write_handler_json_string(b, string(p.project_id)); strings.write_string(b, "\",\"name\":\""); write_handler_json_string(b, p.name); strings.write_string(b, "\",\"slug\":\""); write_handler_json_string(b, p.slug); strings.write_string(b, "\",\"description\":\""); write_handler_json_string(b, p.description); strings.write_string(b, "\",\"repo_url\":\""); write_handler_json_string(b, p.repo_url); strings.write_string(b, "\",\"vcs_kind\":\""); write_handler_json_string(b, p.vcs_kind); strings.write_string(b, "\",\"default_path\":\""); write_handler_json_string(b, p.default_path); strings.write_string(b, "\",\"state\":\""); write_handler_json_string(b, domain.project_state_string(p.state)); strings.write_string(b, "\",\"bridge_paths\":[")
	for path, i in paths { if i > 0 do strings.write_byte(b, ','); write_path_json(b, path) }
	strings.write_string(b, "],\"updated_at\":\""); write_handler_json_string(b, p.updated_at); strings.write_string(b, "\"}")
}
write_path_json :: proc(b: ^strings.Builder, p: domain.Project_Bridge_Path) { strings.write_string(b, "{\"project_id\":\""); write_handler_json_string(b, string(p.project_id)); strings.write_string(b, "\",\"bridge_id\":\""); write_handler_json_string(b, p.bridge_id); strings.write_string(b, "\",\"path\":\""); write_handler_json_string(b, p.path); strings.write_string(b, "\",\"is_validated\":"); strings.write_string(b, "true" if p.is_validated else "false"); strings.write_string(b, ",\"last_validated_at\":\""); write_handler_json_string(b, p.last_validated_at); strings.write_string(b, "\",\"validation_error\":\""); write_handler_json_string(b, p.validation_error); strings.write_string(b, "\",\"validation_details\":"); strings.write_string(b, p.validation_details_json if p.validation_details_json != "" else "{}"); strings.write_string(b, "}") }

// Project-scoped quick-open file path search
quick_open_project_fs_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	query := query_value(req.query, "query")
	limit := query_int(req.query, "limit", 100)
	result, ok, err := project_fs_relay(h, req, Project_Fs_Command{
		command_type = "fs_find_files",
		query = query,
		send_query = true,
		limit = limit,
		send_limit = limit > 0,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

// Project-scoped text grep search
search_project_fs_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	query := query_value(req.query, "query")
	case_sensitive := query_bool(req.query, "case_sensitive", false)
	limit := query_int(req.query, "limit", 100)
	result, ok, err := project_fs_relay(h, req, Project_Fs_Command{
		command_type = "fs_grep",
		query = query,
		send_query = true,
		case_sensitive = case_sensitive,
		send_case_sensitive = true,
		limit = limit,
		send_limit = limit > 0,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}
