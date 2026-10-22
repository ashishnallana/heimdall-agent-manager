package http

import domain "odin_test:hub/domain"
import agent_service "odin_test:hub/service/agent"
import jsonx "odin_test:lib/jsonx"

// Agent blocker routes (REQ-EXT-BLK-3), user auth, owner-checked. The list is
// in memory only (agent_service/agent_blockers.odin).
//   GET  /api/v1/agent-instances/*/blockers
//   POST /api/v1/agent-instances/*/blockers/*/resolve {decision: allow|deny, message?}

// GET /api/v1/agent-instances/*/blockers
agent_instance_blockers_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	instance_id := path_part(req.path, 4)
	if instance_id == "" do return respond_error(domain.domain_error(.Not_Found, "route not found"), req.request_id)
	body, listed, err := agent_service.list_instance_blockers(h.agents, auth_ctx, instance_id)
	if !listed do return respond_error(err, req.request_id)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

// POST /api/v1/agent-instances/*/blockers/*/resolve
agent_instance_blocker_resolve_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	instance_id := path_part(req.path, 4)
	blocker_id := path_part(req.path, 6)
	if instance_id == "" || blocker_id == "" do return respond_error(domain.domain_error(.Not_Found, "route not found"), req.request_id)
	decision := jsonx.extract_string(req.body, "decision", top_level_only = true)
	message := jsonx.extract_string(req.body, "message", top_level_only = true)
	body, resolved, err := agent_service.resolve_instance_blocker(h.agents, auth_ctx, instance_id, blocker_id, decision, message)
	if !resolved do return respond_error(err, req.request_id)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}
