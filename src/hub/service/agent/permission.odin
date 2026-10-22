package agent

import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import jsonx "odin_test:lib/jsonx"
import ownership "odin_test:hub/service/ownership"
import platform "odin_test:hub/platform"
import project_service "odin_test:hub/service/project"
import events "odin_test:hub/service/events"

// Provider permission relay (REQ-EXT-PERM-1). The bridge forwards a blocking
// permission prompt (agent.extension.permission); the hub stores it as a pending
// permission_requests row, tells the UI, and pushes the user's allow/deny back to
// the bridge as a `permission_decision` frame. A request that nobody answers
// expires (the bridge then returns "none" so the provider shows its own TUI
// prompt): the hub NEVER turns silence into a deny.

PERMISSION_STATUS_PENDING :: "pending"
PERMISSION_STATUS_ALLOWED :: "allowed"
PERMISSION_STATUS_DENIED :: "denied"
PERMISSION_STATUS_EXPIRED :: "expired"
PERMISSION_STATUS_CANCELLED :: "cancelled"

// Hub-side bounds on the bridge-supplied timeout (the bridge clamps the same way).
PERMISSION_TIMEOUT_DEFAULT_MS :: 300_000
PERMISSION_TIMEOUT_MIN_MS :: 1_000
PERMISSION_TIMEOUT_MAX_MS :: 600_000
PERMISSION_REQUEST_ID_MAX :: 128
PERMISSION_MESSAGE_MAX :: 2_000
// Max serialized tool input / suggestions stored per request.
PERMISSION_INPUT_MAX_BYTES :: 64 * 1024

// The resource_changed `change` the UI listens for on resource agent_instance.
PERMISSION_REALTIME_CHANGE :: "permission_requests"

Permission_Decide_Result :: struct {
	request:   domain.Permission_Request,
	// delivered is false when the bridge could not be reached; the decision is
	// stored, but the provider falls back to its TUI prompt when the relay times out.
	delivered: bool,
}

permission_clamp_timeout_ms :: proc(value: int) -> int {
	out := value
	if out <= 0 do out = PERMISSION_TIMEOUT_DEFAULT_MS
	if out < PERMISSION_TIMEOUT_MIN_MS do out = PERMISSION_TIMEOUT_MIN_MS
	if out > PERMISSION_TIMEOUT_MAX_MS do out = PERMISSION_TIMEOUT_MAX_MS
	return out
}

// permission_status_for_decision maps a user decision onto a closed status.
permission_status_for_decision :: proc(decision: string) -> (string, bool) {
	switch strings.to_lower(strings.trim_space(decision), context.temp_allocator) {
	case "allow": return PERMISSION_STATUS_ALLOWED, true
	case "deny": return PERMISSION_STATUS_DENIED, true
	}
	return "", false
}

@(private = "file")
permission_valid_request_id :: proc(id: string) -> bool {
	if id == "" || len(id) > PERMISSION_REQUEST_ID_MAX do return false
	for ch in id {
		ok := (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '-'
		if !ok do return false
	}
	return true
}

@(private = "file")
permission_require_service :: proc(service: ^Agent_Service) -> (bool, domain.Domain_Error) {
	if service == nil || service.agents == nil do return false, domain.domain_error(.Internal_Error, "agent service is not configured")
	return true, {}
}

// ingest_permission_request stores a pending request for the CALLER's instance
// (identity from the instance token only) and announces it to the UI. A replay
// of an id this instance already created returns the stored row (idempotent).
//
// params (normalised by the bridge):
//   {request_id, timeout_ms, provider, agent_id, tool_name, tool_use_id,
//    input:{...}, permission_suggestions:[...]}
ingest_permission_request :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, params: string) -> (domain.Permission_Request, bool, domain.Domain_Error) {
	if ok, err := permission_require_service(service); !ok do return {}, false, err
	if auth.kind != .Instance_Token || auth.agent_instance_id == "" do return {}, false, domain.domain_error(.Forbidden, "instance token is required")
	inst, got, err := iface.agent_get_instance(service.agents, auth.agent_instance_id)
	if !got do return {}, false, err
	if inst.owner_user_id != domain.User_ID(auth.user_id) do return {}, false, domain.domain_error(.Not_Found, "agent instance not found")

	request_id := jsonx.extract_string(params, "request_id", top_level_only = true)
	if !permission_valid_request_id(request_id) do return {}, false, domain.domain_error(.Validation_Failed, "request_id is required ([A-Za-z0-9_-], at most 128 chars)")
	tool_name := jsonx.extract_string(params, "tool_name", top_level_only = true)
	if strings.trim_space(tool_name) == "" do return {}, false, domain.domain_error(.Validation_Failed, "tool_name is required")
	input, has_input := jsonx.extract_raw_object(params, "input", top_level_only = true)
	if !has_input do input = "{}"
	suggestions, has_sugg := jsonx.extract_raw_array(params, "permission_suggestions", top_level_only = true)
	if !has_sugg do suggestions = "[]"
	if len(input) > PERMISSION_INPUT_MAX_BYTES || len(suggestions) > PERMISSION_INPUT_MAX_BYTES do return {}, false, domain.domain_error(.Validation_Failed, "permission request input is too large")
	timeout_ms := permission_clamp_timeout_ms(jsonx.extract_int(params, "timeout_ms", 0, top_level_only = true))

	now := platform.clock_now(service.clock)
	expires_at, exp_ok := platform.expires_at_after_seconds_from(now, (timeout_ms + 999) / 1000)
	if !exp_ok do expires_at = ""
	req := domain.Permission_Request{
		id            = request_id,
		owner_user_id = inst.owner_user_id,
		instance_id   = inst.agent_instance_id,
		chain_id      = inst.chain_id,
		agent_id      = jsonx.extract_string(params, "agent_id", top_level_only = true),
		provider      = jsonx.extract_string(params, "provider", top_level_only = true),
		tool_name     = tool_name,
		tool_use_id   = jsonx.extract_string(params, "tool_use_id", top_level_only = true),
		input         = input,
		suggestions   = suggestions,
		status        = PERMISSION_STATUS_PENDING,
		created_at    = now,
		expires_at    = expires_at,
	}
	if ins_err := iface.agent_perm_insert(service.agents, req); ins_err.code != .None {
		// The bridge relay retries on transport errors, so a request the hub already
		// stored may arrive again: same id + same instance is the same request.
		if existing, found, _ := iface.agent_perm_get(service.agents, request_id); found && existing.instance_id == inst.agent_instance_id {
			return existing, true, {}
		}
		return {}, false, ins_err
	}
	permission_publish(service, req, "created")
	return req, true, {}
}

// close_permission_request_from_agent lets the bridge close its own pending
// request when the relay gave up (reason "timeout" -> expired, anything else ->
// cancelled). Closing an already-closed request is a no-op (changed=false).
close_permission_request_from_agent :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, request_id, reason: string) -> (domain.Permission_Request, bool, bool, domain.Domain_Error) {
	if ok, err := permission_require_service(service); !ok do return {}, false, false, err
	if auth.kind != .Instance_Token || auth.agent_instance_id == "" do return {}, false, false, domain.domain_error(.Forbidden, "instance token is required")
	req, got, err := iface.agent_perm_get(service.agents, request_id)
	if !got do return {}, false, false, err
	// The caller may only close requests of its own instance.
	if req.instance_id != auth.agent_instance_id do return {}, false, false, domain.domain_error(.Not_Found, "permission request not found")
	status := PERMISSION_STATUS_EXPIRED if reason == "timeout" else PERMISSION_STATUS_CANCELLED
	now := platform.clock_now(service.clock)
	changed, cerr := iface.agent_perm_close(service.agents, req.id, status, "", "", now)
	if cerr.code != .None do return {}, false, false, cerr
	if changed {
		req.status = status
		req.decided_at = now
		permission_publish(service, req, "closed")
	} else if fresh, ok2, _ := iface.agent_perm_get(service.agents, req.id); ok2 {
		req = fresh
	}
	return req, changed, true, {}
}

// decide_permission_request records a USER's allow/deny and pushes it to the
// bridge. Only a person who owns the instance may decide: instance and bridge
// tokens are refused, so an agent can never approve its own prompt.
decide_permission_request :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, request_id, decision, message: string) -> (Permission_Decide_Result, bool, domain.Domain_Error) {
	if ok, err := permission_require_service(service); !ok do return {}, false, err
	if auth.kind == .Instance_Token || auth.kind == .Bridge_Token || auth.kind == .Enrollment_Token || auth.kind == .None {
		return {}, false, domain.domain_error(.Forbidden, "a user must decide permission requests")
	}
	status, valid := permission_status_for_decision(decision)
	if !valid do return {}, false, domain.domain_error(.Validation_Failed, "decision must be allow or deny")
	if len(message) > PERMISSION_MESSAGE_MAX do return {}, false, domain.domain_error(.Validation_Failed, "message is too long")
	req, got, err := iface.agent_perm_get(service.agents, request_id)
	if !got do return {}, false, err
	if owner_ok, owner_err := ownership.require_owner(auth, req.owner_user_id); !owner_ok do return {}, false, owner_err

	now := platform.clock_now(service.clock)
	if req.status == PERMISSION_STATUS_PENDING && req.expires_at != "" && req.expires_at <= now {
		// The relay already gave up; record that instead of a decision nobody waits for.
		expire_due_permission_requests(service)
		return {}, false, domain.domain_error(.Conflict, "permission request has expired")
	}
	if req.status != PERMISSION_STATUS_PENDING do return {}, false, domain.domain_error(.Conflict, fmt.tprintf("permission request is already %s", req.status))

	changed, cerr := iface.agent_perm_close(service.agents, req.id, status, auth.user_id, message, now)
	if cerr.code != .None do return {}, false, cerr
	if !changed do return {}, false, domain.domain_error(.Conflict, "permission request is no longer pending")
	req.status = status
	req.decided_by = auth.user_id
	req.message = message
	req.decided_at = now

	result := Permission_Decide_Result{request = req}
	result.delivered = permission_push_decision(service, req)
	permission_publish(service, req, "decided")
	return result, true, {}
}

// permission_push_decision sends the permission_decision frame to the bridge
// running the instance. Fire-and-forget: the bridge resolves the pending relay.
permission_push_decision :: proc(service: ^Agent_Service, req: domain.Permission_Request) -> bool {
	inst, got, _ := iface.agent_get_instance(service.agents, req.instance_id)
	if !got || inst.bridge_id == "" do return false
	decision := "allow" if req.status == PERMISSION_STATUS_ALLOWED else "deny"
	command_id := platform.generate_id(service.ids, "cmd_")
	body := permission_decision_frame_json(command_id, req.instance_id, req.id, decision, req.message)
	sent, _ := project_service.bridge_command_send_runtime(service.bridge_command_sink, project_service.Runtime_Command{bridge_id = inst.bridge_id, command_id = command_id, body_json = body})
	return sent
}

permission_decision_frame_json :: proc(command_id, instance_id, request_id, decision, message: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"permission_decision\",\"protocol_version\":1,\"command_id\":\""); contracts.write_json_string(&b, command_id)
	strings.write_string(&b, "\",\"agent_instance_id\":\""); contracts.write_json_string(&b, instance_id)
	strings.write_string(&b, "\",\"request_id\":\""); contracts.write_json_string(&b, request_id)
	strings.write_string(&b, "\",\"decision\":\""); contracts.write_json_string(&b, decision)
	strings.write_string(&b, "\",\"message\":\""); contracts.write_json_string(&b, message)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

// list_permission_requests returns the caller's requests, newest first. With an
// instance_id the instance must belong to the caller. Due rows are expired first
// so a pending row in the answer is still answerable.
list_permission_requests :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, filter: domain.Permission_Request_Filter) -> ([]domain.Permission_Request, bool, domain.Domain_Error) {
	if ok, err := permission_require_service(service); !ok do return nil, false, err
	owner, owner_ok, owner_err := ownership.owner_from_auth(auth)
	if !owner_ok do return nil, false, owner_err
	f := filter
	f.owner_user_id = owner
	if f.instance_id != "" {
		if _, got, err := get_instance(service, auth, f.instance_id); !got do return nil, false, err
	}
	if f.status != "" {
		switch f.status {
		case PERMISSION_STATUS_PENDING, PERMISSION_STATUS_ALLOWED, PERMISSION_STATUS_DENIED, PERMISSION_STATUS_EXPIRED, PERMISSION_STATUS_CANCELLED:
		case:
			return nil, false, domain.domain_error(.Validation_Failed, "unknown permission request status")
		}
	}
	expire_due_permission_requests(service)
	rows, lerr := iface.agent_perm_list(service.agents, f)
	if lerr.code != .None do return nil, false, lerr
	return rows, true, {}
}

// expire_due_permission_requests closes every pending request past expires_at.
expire_due_permission_requests :: proc(service: ^Agent_Service) -> int {
	if service == nil || service.agents == nil do return 0
	now := platform.clock_now(service.clock)
	if now == "" do return 0
	closed, _ := iface.agent_perm_close_pending(service.agents, "", now, PERMISSION_STATUS_EXPIRED, now)
	for req in closed do permission_publish(service, req, "closed")
	return len(closed)
}

// cancel_instance_permission_requests closes an instance's pending requests when
// it dies (called from notify_instance_terminal). The bridge-side relay is
// cancelled independently, so nothing is pushed.
cancel_instance_permission_requests :: proc(service: ^Agent_Service, instance_id: string) -> int {
	if service == nil || service.agents == nil || service.agents.perm_close_pending == nil || instance_id == "" do return 0
	now := platform.clock_now(service.clock)
	closed, _ := iface.agent_perm_close_pending(service.agents, instance_id, "", PERMISSION_STATUS_CANCELLED, now)
	for req in closed do permission_publish(service, req, "closed")
	return len(closed)
}

// permission_publish emits resource_changed(agent_instance, <id>, permission_requests).
@(private = "file")
permission_publish :: proc(service: ^Agent_Service, req: domain.Permission_Request, action: string) {
	if service == nil || service.event_bus == nil do return
	summary := permission_realtime_summary_json(req, action)
	events.publish_resource_changed(service.event_bus, string(req.owner_user_id), "agent_instance", req.instance_id, PERMISSION_REALTIME_CHANGE, summary)
	delete(summary)
}

// permission_realtime_summary_json: {action, permission_request:{...}}. action is
// created | decided | closed. The tool input is included so the UI can render
// the card without a refetch.
permission_realtime_summary_json :: proc(req: domain.Permission_Request, action: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"action\":\""); contracts.write_json_string(&b, action)
	strings.write_string(&b, "\",\"permission_request\":")
	write_permission_request_json(&b, req)
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

write_permission_request_json :: proc(b: ^strings.Builder, req: domain.Permission_Request) {
	strings.write_string(b, "{\"id\":\""); contracts.write_json_string(b, req.id)
	strings.write_string(b, "\",\"instance_id\":\""); contracts.write_json_string(b, req.instance_id)
	strings.write_string(b, "\",\"chain_id\":\""); contracts.write_json_string(b, req.chain_id)
	strings.write_string(b, "\",\"agent_id\":\""); contracts.write_json_string(b, req.agent_id)
	strings.write_string(b, "\",\"provider\":\""); contracts.write_json_string(b, req.provider)
	strings.write_string(b, "\",\"tool_name\":\""); contracts.write_json_string(b, req.tool_name)
	strings.write_string(b, "\",\"tool_use_id\":\""); contracts.write_json_string(b, req.tool_use_id)
	strings.write_string(b, "\",\"status\":\""); contracts.write_json_string(b, req.status)
	strings.write_string(b, "\",\"decided_by\":\""); contracts.write_json_string(b, req.decided_by)
	strings.write_string(b, "\",\"message\":\""); contracts.write_json_string(b, req.message)
	strings.write_string(b, "\",\"created_at\":\""); contracts.write_json_string(b, req.created_at)
	strings.write_string(b, "\",\"expires_at\":\""); contracts.write_json_string(b, req.expires_at)
	strings.write_string(b, "\",\"decided_at\":\""); contracts.write_json_string(b, req.decided_at)
	// input / suggestions were re-serialised by jsonx on ingest, so they are valid JSON.
	strings.write_string(b, "\",\"input\":")
	strings.write_string(b, req.input if strings.has_prefix(strings.trim_space(req.input), "{") else "{}")
	strings.write_string(b, ",\"permission_suggestions\":")
	strings.write_string(b, req.suggestions if strings.has_prefix(strings.trim_space(req.suggestions), "[") else "[]")
	strings.write_byte(b, '}')
}
