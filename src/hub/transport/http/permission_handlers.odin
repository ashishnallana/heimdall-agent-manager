package http

import "core:fmt"
import "core:strings"
import domain "odin_test:hub/domain"
import agent_service "odin_test:hub/service/agent"
import jsonx "odin_test:lib/jsonx"

// Provider permission relay routes (REQ-EXT-PERM-1).
//   Bridge (instance token, agent-actions envelope):
//     POST /api/v1/agent-actions/permission-requests        create a pending request
//     POST /api/v1/agent-actions/permission-requests/close  relay timed out / cancelled
//   UI (user auth, owner-scoped):
//     GET  /api/v1/permission-requests?status=&instance_id=&chain_id=&limit=
//     GET  /api/v1/agent-instances/*/permission-requests?status=
//     POST /api/v1/permission-requests/*/decision           {decision: allow|deny, message?}

// POST /api/v1/agent-actions/permission-requests
agent_action_permission_request_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, _, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	pr, saved, err := agent_service.ingest_permission_request(h.agents, auth, params)
	if !saved do return respond_error(err, req.request_id)
	b := strings.builder_make()
	strings.write_string(&b, "{\"permission_request\":")
	agent_service.write_permission_request_json(&b, pr)
	strings.write_byte(&b, '}')
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

// POST /api/v1/agent-actions/permission-requests/close {request_id, reason: timeout|cancelled}
agent_action_permission_request_close_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, _, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	request_id := jsonx.extract_string(params, "request_id", top_level_only = true)
	reason := jsonx.extract_string(params, "reason", "cancelled", top_level_only = true)
	pr, changed, got, err := agent_service.close_permission_request_from_agent(h.agents, auth, request_id, reason)
	if !got do return respond_error(err, req.request_id)
	b := strings.builder_make()
	strings.write_string(&b, "{\"closed\":"); strings.write_string(&b, "true" if changed else "false")
	strings.write_string(&b, ",\"permission_request\":")
	agent_service.write_permission_request_json(&b, pr)
	strings.write_byte(&b, '}')
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

@(private = "file")
permission_list_response :: proc(rows: []domain.Permission_Request, req: Request) -> Response {
	b := strings.builder_make()
	strings.write_string(&b, "{\"permission_requests\":[")
	pending := 0
	for row, i in rows {
		if i > 0 do strings.write_byte(&b, ',')
		agent_service.write_permission_request_json(&b, row)
		if row.status == agent_service.PERMISSION_STATUS_PENDING do pending += 1
	}
	strings.write_string(&b, fmt.tprintf("],\"pending_count\":%d}}", pending))
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

// GET /api/v1/permission-requests?status=&instance_id=&chain_id=&limit=
permission_requests_list_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	filter := domain.Permission_Request_Filter{
		instance_id = query_value(req.query, "instance_id"),
		chain_id    = query_value(req.query, "chain_id"),
		status      = query_value(req.query, "status"),
		limit       = query_int(req.query, "limit", 0),
	}
	rows, got, err := agent_service.list_permission_requests(h.agents, auth_ctx, filter)
	if !got do return respond_error(err, req.request_id)
	return permission_list_response(rows, req)
}

// GET /api/v1/agent-instances/*/permission-requests?status=
agent_instance_permission_requests_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	instance_id := path_part(req.path, 4)
	if instance_id == "" do return respond_error(domain.domain_error(.Not_Found, "route not found"), req.request_id)
	filter := domain.Permission_Request_Filter{
		instance_id = instance_id,
		status      = query_value(req.query, "status"),
		limit       = query_int(req.query, "limit", 0),
	}
	rows, got, err := agent_service.list_permission_requests(h.agents, auth_ctx, filter)
	if !got do return respond_error(err, req.request_id)
	return permission_list_response(rows, req)
}

// POST /api/v1/permission-requests/*/decision {decision: allow|deny, message?}
permission_request_decision_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	request_id := path_part(req.path, 4)
	if request_id == "" do return respond_error(domain.domain_error(.Not_Found, "route not found"), req.request_id)
	decision := jsonx.extract_string(req.body, "decision", top_level_only = true)
	message := jsonx.extract_string(req.body, "message", top_level_only = true)
	result, decided, err := agent_service.decide_permission_request(h.agents, auth_ctx, request_id, decision, message)
	if !decided do return respond_error(err, req.request_id)
	b := strings.builder_make()
	strings.write_string(&b, "{\"delivered\":"); strings.write_string(&b, "true" if result.delivered else "false")
	strings.write_string(&b, ",\"permission_request\":")
	agent_service.write_permission_request_json(&b, result.request)
	strings.write_byte(&b, '}')
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}
