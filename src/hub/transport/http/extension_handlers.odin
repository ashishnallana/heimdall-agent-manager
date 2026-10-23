package http

import "core:fmt"
import "core:strings"
import domain "odin_test:hub/domain"
import agent_service "odin_test:hub/service/agent"
import events "odin_test:hub/service/events"

// Provider extension (ham.ext.v1) routes. Ingest arrives from the bridge as an
// agent-actions envelope (instance token); reads are owner-scoped UI GETs.

// Max events summarised in the realtime frame (the UI refetches for the rest).
EXTENSION_EVENT_FRAME_MAX :: 20

// POST /api/v1/agent-actions/extension-events
agent_action_extension_events_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, _, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	result, saved, err := agent_service.ingest_extension_events(h.agents, auth, params)
	if !saved do return respond_error(err, req.request_id)
	if len(result.stored) > 0 && h.event_bus != nil {
		summary := extension_events_frame_summary_json(result)
		events.publish_resource_changed(h.event_bus, string(result.instance.owner_user_id), "agent_instance", result.instance.agent_instance_id, "extension_events", summary)
		delete(summary)
	}
	b := strings.builder_make()
	strings.write_string(&b, fmt.tprintf("{{\"accepted\":%d,\"rejected\":%d,\"last_seq\":%d", len(result.stored), result.rejected, extension_last_seq(result.stored)))
	strings.write_string(&b, ",\"provider_session_id\":\""); write_handler_json_string(&b, result.instance.provider_session_id)
	strings.write_string(&b, "\",\"session_changed\":"); strings.write_string(&b, "true" if result.session_changed else "false")
	strings.write_byte(&b, '}')
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

// Authenticated compatibility no-op: older bridges cannot create transcript rows.
agent_action_tool_activity_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	_, _, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	return respond_success(`{"accepted":true,"persisted":false}`, req.request_id, auth_ctx_server_time(req), 200)
}

// One-shot authenticated snapshot proxy to Bridge; no Hub tool-content cache.
agent_instance_tool_activity_live_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth, ok, resp := require_auth(h.auth, req)
	if !ok do return resp
	inst, got, err := agent_service.get_instance(h.agents, auth, extension_instance_path_id(req.path))
	if !got do return respond_error(err, req.request_id)
	body, available, snapshot_err := agent_service.tool_live_request_snapshot(h.agents, inst)
	if !available do return respond_error(snapshot_err, req.request_id)
	defer delete(body)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

extension_last_seq :: proc(evs: []domain.Agent_Extension_Event) -> int {
	if len(evs) == 0 do return 0
	return evs[len(evs) - 1].seq
}

// extension_events_frame_summary_json is the realtime resource_changed summary:
// counts plus a compact tail of the batch (no payloads; the UI fetches those).
extension_events_frame_summary_json :: proc(result: agent_service.Extension_Ingest_Result) -> string {
	b := strings.builder_make()
	strings.write_string(&b, fmt.tprintf("{{\"count\":%d,\"last_seq\":%d", len(result.stored), extension_last_seq(result.stored)))
	strings.write_string(&b, ",\"provider_session_id\":\""); write_handler_json_string(&b, result.instance.provider_session_id)
	strings.write_string(&b, "\",\"session_changed\":"); strings.write_string(&b, "true" if result.session_changed else "false")
	strings.write_string(&b, ",\"events\":[")
	start := max(0, len(result.stored) - EXTENSION_EVENT_FRAME_MAX)
	for ev, i in result.stored[start:] {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, fmt.tprintf("{{\"seq\":%d,\"event\":\"", ev.seq)); write_handler_json_string(&b, ev.event)
		strings.write_string(&b, "\",\"agent_id\":\""); write_handler_json_string(&b, ev.agent_id)
		strings.write_string(&b, "\",\"tool_name\":\""); write_handler_json_string(&b, ev.tool_name)
		strings.write_string(&b, "\",\"file_path\":\""); write_handler_json_string(&b, ev.file_path)
		strings.write_string(&b, "\"}")
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

write_extension_event_json :: proc(b: ^strings.Builder, ev: domain.Agent_Extension_Event) {
	strings.write_string(b, fmt.tprintf("{{\"seq\":%d,\"event\":\"", ev.seq)); write_handler_json_string(b, ev.event)
	strings.write_string(b, "\",\"ts\":\""); write_handler_json_string(b, ev.ts)
	strings.write_string(b, "\",\"session_id\":\""); write_handler_json_string(b, ev.session_id)
	strings.write_string(b, "\",\"agent\":{\"id\":\""); write_handler_json_string(b, ev.agent_id)
	strings.write_string(b, "\",\"type\":\""); write_handler_json_string(b, ev.agent_type)
	strings.write_string(b, "\"},\"tool_name\":\""); write_handler_json_string(b, ev.tool_name)
	strings.write_string(b, "\",\"tool_use_id\":\""); write_handler_json_string(b, ev.tool_use_id)
	strings.write_string(b, "\",\"file_path\":\""); write_handler_json_string(b, ev.file_path)
	strings.write_string(b, "\",\"created_at\":\""); write_handler_json_string(b, ev.created_at)
	strings.write_string(b, "\",\"payload\":")
	// payload is stored as a JSON object the hub itself re-marshalled on ingest.
	strings.write_string(b, ev.payload if strings.trim_space(ev.payload) != "" else "{}")
	strings.write_byte(b, '}')
}

// extension_instance_path_id extracts <id> from /api/v1/agent-instances/<id>/extension/<leaf>.
@(private = "file")
extension_instance_path_id :: proc(path: string) -> string {
	id := path_part(path, 4)
	if strings.contains(id, "/") do return ""
	return id
}

// GET /api/v1/agent-instances/*/extension/events?agent_id=&after_seq=&limit=
// Ascending by seq; page forward with after_seq=<next_after_seq>.
agent_instance_extension_events_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	instance_id := extension_instance_path_id(req.path)
	if instance_id == "" do return respond_error(domain.domain_error(.Not_Found, "route not found"), req.request_id)
	after_seq := query_int(req.query, "after_seq", 0)
	limit := query_int(req.query, "limit", 100)
	evs, got, err := agent_service.list_extension_events(h.agents, auth_ctx, instance_id, query_value(req.query, "agent_id"), after_seq, limit)
	if !got do return respond_error(err, req.request_id)
	b := strings.builder_make()
	strings.write_string(&b, "{\"events\":[")
	for ev, i in evs {
		if i > 0 do strings.write_byte(&b, ',')
		write_extension_event_json(&b, ev)
	}
	next := after_seq
	if len(evs) > 0 do next = evs[len(evs) - 1].seq
	strings.write_string(&b, fmt.tprintf("],\"next_after_seq\":%d}", next))
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

// GET /api/v1/agent-instances/*/extension/subagents
agent_instance_extension_subagents_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	instance_id := extension_instance_path_id(req.path)
	if instance_id == "" do return respond_error(domain.domain_error(.Not_Found, "route not found"), req.request_id)
	subs, got, err := agent_service.list_extension_subagents(h.agents, auth_ctx, instance_id)
	if !got do return respond_error(err, req.request_id)
	b := strings.builder_make()
	strings.write_string(&b, "{\"subagents\":[")
	for s, i in subs {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, "{\"agent_id\":\""); write_handler_json_string(&b, s.agent_id)
		strings.write_string(&b, "\",\"agent_type\":\""); write_handler_json_string(&b, s.agent_type)
		strings.write_string(&b, "\",\"description\":\""); write_handler_json_string(&b, s.description)
		strings.write_string(&b, "\",\"status\":\""); write_handler_json_string(&b, s.status)
		strings.write_string(&b, "\",\"started_at\":\""); write_handler_json_string(&b, s.started_at)
		strings.write_string(&b, "\",\"stopped_at\":\""); write_handler_json_string(&b, s.stopped_at)
		strings.write_string(&b, fmt.tprintf("\",\"event_count\":%d}}", s.event_count))
	}
	strings.write_string(&b, "]}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

// GET /api/v1/agent-instances/*/extension/files
agent_instance_extension_files_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	instance_id := extension_instance_path_id(req.path)
	if instance_id == "" do return respond_error(domain.domain_error(.Not_Found, "route not found"), req.request_id)
	files, got, err := agent_service.list_extension_files(h.agents, auth_ctx, instance_id)
	if !got do return respond_error(err, req.request_id)
	b := strings.builder_make()
	strings.write_string(&b, "{\"files\":[")
	for f, i in files {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, "{\"file_path\":\""); write_handler_json_string(&b, f.file_path)
		strings.write_string(&b, fmt.tprintf("\",\"edit_count\":%d,\"last_seq\":%d,\"last_at\":\"", f.edit_count, f.last_seq)); write_handler_json_string(&b, f.last_at)
		strings.write_string(&b, "\",\"agent_ids\":[")
		first := true
		for aid in strings.split(f.agent_ids, ",", context.temp_allocator) {
			if !first do strings.write_byte(&b, ',')
			first = false
			strings.write_byte(&b, '"'); write_handler_json_string(&b, aid); strings.write_byte(&b, '"')
		}
		strings.write_string(&b, "]}")
	}
	strings.write_string(&b, "]}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

// write_extension_capabilities_json writes the stored capabilities array. The
// value was re-marshalled by the hub on ingest, so it is already valid JSON; an
// empty/legacy value renders as [].
write_extension_capabilities_json :: proc(b: ^strings.Builder, caps: string) {
	trimmed := strings.trim_space(caps)
	if !strings.has_prefix(trimmed, "[") {
		strings.write_string(b, "[]")
		return
	}
	strings.write_string(b, trimmed)
}

// GET /api/v1/task-chains/{id}/tool-activity-live
task_chain_tool_activity_live_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth, ok, resp := require_auth_any(h.auth, req)
	if !ok do return resp
	body, got, err := agent_service.tool_live_chain_snapshot(h.agents, auth, path_part(req.path, 4), query_value(req.query, "cursor"))
	if !got do return respond_error(err, req.request_id)
	defer delete(body)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}
