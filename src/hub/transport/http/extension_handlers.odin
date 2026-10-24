package http
import domain "odin_test:hub/domain"
import agent_service "odin_test:hub/service/agent"

// Authenticated retirement endpoint: old bridges cannot persist or broadcast events.
agent_action_extension_events_handler :: proc(ctx: rawptr, req: Request) -> Response {
    h := (^Agent_Action_Handlers)(ctx)
    _, _, ok, resp := require_instance_action_auth(h, req)
    if !ok do return resp
    return respond_success(`{"accepted":0,"dropped":true,"persisted":false,"upgrade_required":true}`, req.request_id, auth_ctx_server_time(req), 200)
}
agent_action_tool_activity_handler :: proc(ctx: rawptr, req: Request) -> Response {
    h := (^Agent_Action_Handlers)(ctx)
    _, _, ok, resp := require_instance_action_auth(h, req)
    if !ok do return resp
    return respond_success(`{"accepted":true,"persisted":false}`, req.request_id, auth_ctx_server_time(req), 200)
}
agent_instance_extension_events_handler :: proc(ctx: rawptr, req: Request) -> Response {
    h := (^Agent_Handlers)(ctx)
    auth, ok, resp := require_auth(h.auth, req)
    if !ok do return resp
    id := path_part(req.path, 4)
    _, found, err := agent_service.get_instance(h.agents, auth, id)
    if !found do return respond_error(err, req.request_id)
    return respond_error(domain.domain_error(.Gone, "Extension history is retired. Open the conversation with an updated client for live activity."), req.request_id)
}
agent_instance_extension_subagents_handler :: agent_instance_extension_events_handler
agent_instance_extension_files_handler :: agent_instance_extension_events_handler
