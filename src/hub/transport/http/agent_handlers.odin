package http

import "core:fmt"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import dbt "odin_test:hub/platform/dbtelemetry"
import domain "odin_test:hub/domain"
import auth_service "odin_test:hub/service/auth"
import agent_service "odin_test:hub/service/agent"
import events "odin_test:hub/service/events"
import user_service "odin_test:hub/service/user"
import iface "odin_test:hub/repository/iface"
import shell_session_svc "odin_test:hub/service/shell_session"

Agent_Handlers :: struct {
	entitlements: domain.Entitlement_Lookup,
 launch_preferences: ^user_service.User_Service,
	auth:           ^auth_service.Auth_Service,
	agents:         ^agent_service.Agent_Service,
	event_bus:      ^events.User_Event_Bus,
	ws_tickets:     ^User_WS_Ticket_Store,
	shell_sessions: ^shell_session_svc.Shell_Session_Service,
	experiments:    ^iface.Experiment_Repository,
}

list_agents_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	// Accept user tokens AND bridge-relayed instance tokens so a coordinator agent
	// can DISCOVER durable agents it owns (H5). list_agents is same-owner scoped in
	// the service (owner_from_auth), so an instance token only ever sees its owner.
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	limit := query_int(req.query, "limit", 50)
	if limit <= 0 do limit = 50
	if limit > 200 do limit = 200
	cursor := query_value(req.query, "cursor")
	// view=summary (opt-in) omits instructions and the per-row bridge/instance counts:
	// pickers and name lookups read only id/name/slug/template/state. The default stays
	// the full row so existing callers and edit flows are unchanged.
	summary := query_value(req.query, "view") == "summary"
	agents, err := agent_service.list_agents(h.agents, auth_ctx, limit, cursor)
	if err.code != .None do return respond_error(err, req.request_id)
	b := strings.builder_make(); strings.write_byte(&b, '[')
	next_cursor := ""
	for agent, i in agents {
		if i > 0 do strings.write_byte(&b, ',')
		if summary { write_agent_summary_json(&b, agent) } else { write_agent_json(&b, h.agents, agent) }
		next_cursor = agent.created_at
	}
	strings.write_byte(&b, ']')
	has_more := len(agents) >= limit
	return respond_list(strings.to_string(b), contracts.API_Page{limit = limit, next_cursor = next_cursor if has_more else "", has_more = has_more}, req.request_id, auth_ctx_server_time(req))
}

create_agent_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	// Accept user tokens AND bridge-relayed instance tokens so a coordinator agent
	// can CREATE a durable agent under its own owner (H5). create_agent stamps the
	// new agent's owner from owner_from_auth(auth), so an instance token can only
	// create agents for its own owner.
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	if json_bool(req.body, "favorite") && !contracts.is_user_auth(auth_ctx) do return respond_error(domain.domain_error(.Forbidden, "user authentication is required for favorites"), req.request_id)
	if json_bool(req.body, "favorite") {
		if h.launch_preferences == nil do return respond_error(domain.domain_error(.Internal_Error, "launch preferences are not configured"), req.request_id)
		lock_tok := dbt.timed_lock(&h.launch_preferences.launch_preferences_mutex, .Launch_Prefs)
		defer dbt.timed_unlock(&h.launch_preferences.launch_preferences_mutex, .Launch_Prefs, lock_tok)
		prefs, pref_err := user_service.get_launch_preferences(h.launch_preferences, auth_ctx)
		if pref_err.code != .None do return respond_error(pref_err, req.request_id)
		if len(prefs.favorite_agent_ids) >= user_service.MAX_FAVORITE_AGENTS do return respond_error(domain.domain_error(.Conflict, "You can have up to 6 favorite agents. Remove a favorite before creating another."), req.request_id)
	}
	agent, created, err := agent_service.create_agent(h.agents, auth_ctx, agent_input_from_body(req.body))
	if !created do return respond_error(err, req.request_id)
	publish_agent_changed(h.event_bus, string(agent.owner_user_id), agent.agent_id, "created")
	if json_bool(req.body, "favorite") {
		if _, saved, save_err := user_service.set_agent_favorite_locked(h.launch_preferences, auth_ctx, agent.agent_id, true); !saved do return respond_error(save_err, req.request_id)
	}
	b := strings.builder_make(); write_agent_json(&b, h.agents, agent)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

agent_detail_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	agent_id := path_part(req.path, 4)
	if strings.contains(agent_id, "/") do return respond_error(domain.domain_error(.Not_Found, "route not found"), req.request_id)
	agent, got, err := agent_service.get_agent(h.agents, auth_ctx, agent_id)
	if !got do return respond_error(err, req.request_id)
	b := strings.builder_make(); write_agent_json(&b, h.agents, agent)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

update_agent_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	agent, updated, err := agent_service.update_agent(h.agents, auth_ctx, path_part(req.path, 4), agent_input_from_body(req.body))
	if !updated do return respond_error(err, req.request_id)
	publish_agent_changed(h.event_bus, string(agent.owner_user_id), agent.agent_id, "updated")
	b := strings.builder_make(); write_agent_json(&b, h.agents, agent)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

archive_agent_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	agent, archived, err := agent_service.archive_agent(h.agents, auth_ctx, path_part(req.path, 4))
	if !archived do return respond_error(err, req.request_id)
	publish_agent_changed(h.event_bus, string(agent.owner_user_id), agent.agent_id, "archived")
	b := strings.builder_make(); write_agent_json(&b, h.agents, agent)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

list_agent_support_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	supports, err := agent_service.list_support(h.agents, auth_ctx, path_part(req.path, 4))
	if err.code != .None do return respond_error(err, req.request_id)
	b := strings.builder_make(); strings.write_byte(&b, '[')
	for support, i in supports { if i > 0 do strings.write_byte(&b, ','); write_support_json(&b, support) }
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

put_agent_support_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	inputs := support_inputs_from_body(req.body)
	supports, saved, err := agent_service.replace_supports(h.agents, auth_ctx, path_part(req.path, 4), inputs)
	if !saved do return respond_error(err, req.request_id)
	publish_agent_changed(h.event_bus, auth_ctx.user_id, path_part(req.path, 4), "support_changed")
	b := strings.builder_make(); strings.write_byte(&b, '[')
	for support, i in supports { if i > 0 do strings.write_byte(&b, ','); write_support_json(&b, support) }
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

patch_agent_support_handler :: proc(ctx: rawptr, req: Request) -> Response {
	return patch_agent_support_common(ctx, req, path_part(req.path, 6))
}

patch_agent_support_common :: proc(ctx: rawptr, req: Request, bridge_id: string) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	input := support_input_from_body(req.body)
	if input.bridge_id == "" do input.bridge_id = bridge_id
	support, saved, err := agent_service.upsert_support(h.agents, auth_ctx, path_part(req.path, 4), input)
	if !saved do return respond_error(err, req.request_id)
	publish_agent_changed(h.event_bus, auth_ctx.user_id, path_part(req.path, 4), "support_changed", input.bridge_id)
	b := strings.builder_make(); write_support_json(&b, support)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

delete_agent_support_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	deleted, err := agent_service.delete_support(h.agents, auth_ctx, path_part(req.path, 4), path_part(req.path, 6))
	if !deleted do return respond_error(err, req.request_id)
	publish_agent_changed(h.event_bus, auth_ctx.user_id, path_part(req.path, 4), "support_changed", path_part(req.path, 6))
	return respond_success("{\"deleted\":true}", req.request_id, auth_ctx_server_time(req))
}

list_agent_instances_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	// Accept user tokens, bridge-relayed instance tokens, and bare bridge tokens
	// (for the action scheduler). When called with a bare bridge token, instances
	// are strictly scoped to the calling bridge.
	auth_ctx, ok, auth_resp := require_auth_or_bridge_token(h.auth, req)
	if !ok do return auth_resp
	limit := query_int(req.query, "limit", 50)
	if limit <= 0 do limit = 50
	if limit > 200 do limit = 200
	cursor := query_value(req.query, "cursor")
	filter := agent_service.List_Instances_Filter{agent_id = query_value(req.query, "agent_id"), bridge_id = query_value(req.query, "bridge_id"), runtime_status = query_value(req.query, "runtime_status"), project_id = query_value(req.query, "project_id")}
	if auth_ctx.kind == .Bridge_Token {
		req_bridge := query_value(req.query, "bridge_id")
		cross := req_bridge != "" && req_bridge != auth_ctx.bridge_id
		if cross {
			// CROSS-BRIDGE ACCESS IS REFUSED (REQ-ENROLL-15). Log the denial, then
			// deny: until REQ-IMPL-6 this check was skipped whenever the deleted
			// bridge-auth mode was permissive — its zero value and shipped default —
			// so bridge A really could enumerate bridge B's instances in a default
			// deployment, and the audit line was the only trace. The line is kept
			// BECAUSE the behaviour changed: it now records a rejection.
			auth_service.log_bridge_auth_denied("cross_bridge_list", req.method, req.path, auth_ctx.bridge_id, auth_ctx.user_id, req_bridge, req.request_id)
			return respond_error(domain.domain_error(.Forbidden, "bridge cannot list instances of another bridge"), req.request_id)
		}
		// A bare bridge token sees ONLY its own instances. Assigning rather than
		// trusting the query is what makes an omitted bridge_id safe too.
		filter.bridge_id = auth_ctx.bridge_id
	}
	instances, err := agent_service.list_instances_filtered(h.agents, auth_ctx, filter, limit, cursor)
	if err.code != .None do return respond_error(err, req.request_id)
	b := strings.builder_make(); strings.write_byte(&b, '[')
	next_cursor := ""
	for inst, i in instances { if i > 0 do strings.write_byte(&b, ','); write_agent_instance_json(&b, inst); next_cursor = inst.created_at }
	strings.write_byte(&b, ']')
	has_more := len(instances) >= limit
	return respond_list(strings.to_string(b), contracts.API_Page{limit = limit, next_cursor = next_cursor if has_more else "", has_more = has_more}, req.request_id, auth_ctx_server_time(req))
}

create_agent_instance_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	// Accept human user tokens, bridge-relayed instance tokens, and bare bridge tokens
	// (for the action scheduler). When called with a bare bridge token, the instance
	// MUST be created on that calling bridge.
	auth_ctx, ok, auth_resp := require_auth_or_bridge_token(h.auth, req)
	if !ok do return auth_resp
	input := instance_input_from_body(req.body)
	if auth_ctx.kind == .Bridge_Token {
		cross := input.bridge_id != "" && input.bridge_id != auth_ctx.bridge_id
		if cross {
			// Same refusal as the list path, and the more serious of the two: under
			// the old permissive default a bridge could CREATE an agent instance on
			// another bridge, which is remote code execution on a machine it does
			// not own. Log the denial, then deny.
			auth_service.log_bridge_auth_denied("cross_bridge_create", req.method, req.path, auth_ctx.bridge_id, auth_ctx.user_id, input.bridge_id, req.request_id)
			return respond_error(domain.domain_error(.Forbidden, "bridge cannot create instances on another bridge"), req.request_id)
		}
		input.bridge_id = auth_ctx.bridge_id
	}
	inst, created, err := agent_service.create_instance(h.agents, auth_ctx, input)
	if !created do return respond_error(err, req.request_id)
	publish_instance_created(h.event_bus, inst)
	b := strings.builder_make(); write_agent_instance_json(&b, inst)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

agent_instance_detail_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	instance_id := path_part(req.path, 4)
	if strings.contains(instance_id, "/") do return respond_error(domain.domain_error(.Not_Found, "route not found"), req.request_id)
	inst, got, err := agent_service.get_instance(h.agents, auth_ctx, instance_id)
	if !got do return respond_error(err, req.request_id)
	b := strings.builder_make(); write_agent_instance_json(&b, inst)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

get_agent_instance_pane_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	instance_id := path_part(req.path, 4)
	if strings.contains(instance_id, "/") do return respond_error(domain.domain_error(.Not_Found, "route not found"), req.request_id)
	since_hash := query_value(req.query, "since_hash")
	width := query_int(req.query, "width", 80)
	if width <= 0 do width = 80
	line_limit := query_int(req.query, "line_limit", 120)
	if line_limit <= 0 do line_limit = 120

	inst, got, err := agent_service.get_instance(h.agents, auth_ctx, instance_id)
	if !got do return respond_error(err, req.request_id)

	if inst.runtime_status == "stopped" || inst.runtime_status == "failed" {
		b := strings.builder_make()
		strings.write_string(&b, "{\"ok\":true,\"status\":\"")
		write_handler_json_string(&b, inst.runtime_status)
		strings.write_string(&b, "\",\"unchanged\":true,\"hash\":\"\",\"output\":\"\"}")
		return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
	}

	if poll_err := shell_session_svc.shell_session_admit_pane_poll(h.shell_sessions, auth_ctx); poll_err.code != .None {
		return respond_error(poll_err, req.request_id)
	}

	reply, reply_ok, reply_err := agent_service.get_instance_pane(h.agents, auth_ctx, instance_id, since_hash, width, line_limit)
	if !reply_ok do return respond_error(reply_err, req.request_id)
	return respond_success(reply, req.request_id, auth_ctx_server_time(req))
}

stop_agent_instance_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	// Accept user tokens AND bridge-relayed instance tokens so a running agent can
	// stop an instance it owns. stop_instance -> get_instance -> require_owner keeps
	// the same-owner boundary (an instance token for another owner gets Not_Found).
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	inst, stopped, err := agent_service.stop_instance(h.agents, auth_ctx, path_part(req.path, 4), agent_service.Stop_Instance_Input{reason = json_string(req.body, "reason"), force = json_bool(req.body, "force")})
	if !stopped do return respond_error(err, req.request_id)
	publish_instance_changed(h.event_bus, inst, "status_changed")
	b := strings.builder_make(); write_agent_instance_json(&b, inst)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 202)
}

restart_agent_instance_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	// Accept user tokens AND bridge-relayed instance tokens so a running agent can
	// relaunch (launch-by-instance-id) an instance it owns. restart_instance ->
	// get_instance -> require_owner + relaunch_instance's bridge.owner==inst.owner
	// check keep the same-owner boundary.
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	inst, restarted, err := agent_service.restart_instance(h.agents, auth_ctx, path_part(req.path, 4))
	if !restarted do return respond_error(err, req.request_id)
	publish_instance_changed(h.event_bus, inst, "status_changed")
	b := strings.builder_make(); write_agent_instance_json(&b, inst)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 202)
}

// start_agent_instance_handler starts a STOPPED instance. Distinct from restart:
// returns 409 (Conflict, code=already_running) when the instance is already live.
start_agent_instance_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	inst, started, err := agent_service.start_instance(h.agents, auth_ctx, path_part(req.path, 4))
	if !started do return respond_error(err, req.request_id)
	publish_instance_changed(h.event_bus, inst, "status_changed")
	b := strings.builder_make(); write_agent_instance_json(&b, inst)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 202)
}

patch_agent_instance_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	inst, updated, err := agent_service.reconfigure_instance(h.agents, auth_ctx, path_part(req.path, 4), reconfigure_input_from_body(req.body))
	if !updated do return respond_error(err, req.request_id)
	publish_instance_changed(h.event_bus, inst, "status_changed")
	b := strings.builder_make(); write_agent_instance_json(&b, inst)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

agent_input_from_body :: proc(body: string) -> agent_service.Create_Agent_Input {
	return agent_service.Create_Agent_Input{name = json_string(body, "name"), slug = json_string(body, "slug"), template_id = json_string(body, "template_id"), instructions = json_string(body, "instructions"), has_template_id = strings.contains(body, "\"template_id\""), permission_mode = json_string(body, "permission_mode")}
}

instance_input_from_body :: proc(body: string) -> agent_service.Create_Instance_Input {
	return agent_service.Create_Instance_Input{agent_id = json_string(body, "agent_id"), bridge_id = json_string(body, "bridge_id"), provider = json_string(body, "provider"),provider_profile=json_string(body,"provider_profile"), model = json_string(body, "model"), project_id = domain.Project_ID(json_string(body, "project_id")), chain_id = json_string(body, "chain_id"), display_name = json_string(body, "display_name")}
}

reconfigure_input_from_body :: proc(body: string) -> agent_service.Reconfigure_Instance_Input {
	return agent_service.Reconfigure_Instance_Input{provider = json_string(body, "provider"),provider_profile=json_string(body,"provider_profile"), model = json_string(body, "model"), agent_id = json_string(body, "agent_id"), bridge_id = json_string(body, "bridge_id"), chain_id = json_string(body, "chain_id"), conversation_id = json_string(body, "conversation_id"), display_name = json_string(body, "display_name"), project_id = domain.Project_ID(json_string(body, "project_id")), has_agent_id = strings.contains(body, "\"agent_id\""), has_bridge_id = strings.contains(body, "\"bridge_id\""), has_project_id = strings.contains(body, "\"project_id\""), has_chain_id = strings.contains(body, "\"chain_id\""), has_conversation_id = strings.contains(body, "\"conversation_id\""), has_display_name = strings.contains(body, "\"display_name\"")}
}

support_input_from_body :: proc(body: string) -> agent_service.Support_Input {
	return agent_service.Support_Input{bridge_id = json_string(body, "bridge_id"), enabled = !strings.contains(body, "\"enabled\":false"), priority = json_int(body, "priority", 0), max_instances = json_int(body, "max_instances", 0)}
}

support_inputs_from_body :: proc(body: string) -> []agent_service.Support_Input {
	out := make([dynamic]agent_service.Support_Input)
	bridges_array := json_array_optional(body, "bridges")
	if strings.trim_space(bridges_array) != "" && bridges_array != "[]" {
		for obj in support_object_list_from_array(bridges_array) do append(&out, support_input_from_body(obj))
		return out[:]
	}
	if strings.contains(body, "\"bridge_id\"") do append(&out, support_input_from_body(body))
	return out[:]
}

support_object_list_from_array :: proc(array: string) -> []string {
	out := make([dynamic]string)
	depth := 0
	in_string := false
	escaped := false
	start := -1
	for i := 0; i < len(array); i += 1 {
		ch := array[i]
		if in_string {
			if escaped { escaped = false; continue }
			if ch == '\\' { escaped = true; continue }
			if ch == '"' do in_string = false
			continue
		}
		if ch == '"' { in_string = true; continue }
		if ch == '{' { if depth == 0 do start = i; depth += 1; continue }
		if ch == '}' { depth -= 1; if depth == 0 && start >= 0 { append(&out, array[start:i + 1]); start = -1 } }
	}
	return out[:]
}

write_agent_json :: proc(b: ^strings.Builder, service: ^agent_service.Agent_Service, a: domain.Agent) {
	strings.write_string(b, "{\"agent_id\":\""); write_handler_json_string(b, a.agent_id)
	strings.write_string(b, "\",\"name\":\""); write_handler_json_string(b, a.name)
	strings.write_string(b, "\",\"slug\":\""); write_handler_json_string(b, a.slug)
	strings.write_string(b, "\",\"template_id\":\""); write_handler_json_string(b, a.template_id)
	strings.write_string(b, "\",\"instructions\":\""); write_handler_json_string(b, a.instructions)
	strings.write_string(b, "\",\"state\":\""); write_handler_json_string(b, domain.agent_state_string(a.state))
	strings.write_string(b, "\",\"permission_mode\":\""); write_handler_json_string(b, domain.agent_permission_mode_normalize(a.permission_mode))
	strings.write_string(b, "\",\"supported_bridge_count\":"); strings.write_string(b, i32_to_string_http(agent_service.supported_bridge_count_for_agent(service, a)))
	strings.write_string(b, ",\"active_instance_count\":"); strings.write_string(b, i32_to_string_http(agent_service.active_instance_count_for_agent(service, a)))
	strings.write_string(b, ",\"updated_at\":\""); write_handler_json_string(b, a.updated_at)
	strings.write_string(b, "\"}")
}

// write_agent_summary_json is the list_agents view=summary row: the identity fields
// list clients read, without instructions or the per-row count lookups.
write_agent_summary_json :: proc(b: ^strings.Builder, a: domain.Agent) {
	strings.write_string(b, "{\"agent_id\":\""); write_handler_json_string(b, a.agent_id)
	strings.write_string(b, "\",\"name\":\""); write_handler_json_string(b, a.name)
	strings.write_string(b, "\",\"slug\":\""); write_handler_json_string(b, a.slug)
	strings.write_string(b, "\",\"template_id\":\""); write_handler_json_string(b, a.template_id)
	strings.write_string(b, "\",\"state\":\""); write_handler_json_string(b, domain.agent_state_string(a.state))
	strings.write_string(b, "\",\"updated_at\":\""); write_handler_json_string(b, a.updated_at)
	strings.write_string(b, "\"}")
}

// agent_instance_summary_json is the agent_instance event summary; it is the
// single instance_changed_summary_json shape (REQ-2) so every writer agrees.
agent_instance_summary_json :: proc(inst: domain.Agent_Instance) -> string {
	return instance_changed_summary_json(inst)
}

// write_last_error_json appends `,"last_error":{...}` (the bridge's wire error for a
// failed instance, REQ-ERR-PROTO-A) or `,"last_error":null`.
write_last_error_json :: proc(b: ^strings.Builder, last_error_json: string) {
	strings.write_string(b, ",\"last_error\":")
	strings.write_string(b, last_error_json if last_error_json != "" else "null")
}

write_agent_instance_json :: proc(b: ^strings.Builder, inst: domain.Agent_Instance) {
	strings.write_string(b, "{\"agent_instance_id\":\""); write_handler_json_string(b, inst.agent_instance_id)
	strings.write_string(b, "\",\"agent_id\":\""); write_handler_json_string(b, inst.agent_id)
	strings.write_string(b, "\",\"bridge_id\":\""); write_handler_json_string(b, inst.bridge_id)
	strings.write_string(b, "\",\"display_name\":\""); write_handler_json_string(b, inst.display_name)
	strings.write_string(b, "\",\"provider\":\""); write_handler_json_string(b, inst.provider)
	strings.write_string(b, "\",\"provider_profile\":\""); write_handler_json_string(b, domain.profile_effective_id(inst.provider,inst.provider_profile))
	strings.write_string(b, "\",\"model\":\""); write_handler_json_string(b, inst.model)
	strings.write_string(b, "\",\"project_id\":\""); write_handler_json_string(b, string(inst.project_id))
	strings.write_string(b, "\",\"project_path\":\""); write_handler_json_string(b, inst.project_path)
	strings.write_string(b, "\",\"chain_id\":\""); write_handler_json_string(b, inst.chain_id)
	strings.write_string(b, "\",\"conversation_id\":\""); write_handler_json_string(b, inst.conversation_id)
	strings.write_string(b, "\",\"runtime_status\":\""); write_handler_json_string(b, inst.runtime_status)
	strings.write_string(b, "\",\"startup_status\":\""); write_handler_json_string(b, inst.startup_status)
	strings.write_string(b, "\",\"activity_status\":\""); write_handler_json_string(b, inst.activity_status)
	strings.write_string(b, "\",\"last_applied_seq\":"); strings.write_string(b, i32_to_string_http(inst.last_applied_seq))
	strings.write_string(b, ",\"configuration_revision\":"); strings.write_string(b, i32_to_string_http(inst.configuration_revision))
	strings.write_string(b, ",\"run_count\":"); strings.write_string(b, i32_to_string_http(inst.run_count))
	strings.write_string(b, ",\"started_at\":\""); write_handler_json_string(b, inst.started_at)
	strings.write_string(b, "\",\"stopped_at\":\""); write_handler_json_string(b, inst.stopped_at)
	strings.write_string(b, "\",\"last_seen_at\":\""); write_handler_json_string(b, inst.last_seen_at)
	strings.write_string(b, "\",\"updated_at\":\""); write_handler_json_string(b, inst.updated_at)
	// CT-9: surface the server-authoritative current task pointer (id + role) so the
	// dashboard can render the work-vs-review banner from persisted state.
	strings.write_string(b, "\",\"current_task_id\":\""); write_handler_json_string(b, inst.current_task_id)
	strings.write_string(b, "\",\"current_task_role\":\""); write_handler_json_string(b, domain.current_task_role_string(inst.current_task_role))
	// permission_mode is the instance override ("" inherits the agent's);
	// effective_permission_mode is what the next launch uses (yolo | ask).
	strings.write_string(b, "\",\"permission_mode\":\""); write_handler_json_string(b, domain.agent_instance_permission_mode_normalize(inst.permission_mode))
	strings.write_string(b, "\",\"effective_permission_mode\":\""); write_handler_json_string(b, domain.agent_instance_effective_permission_mode(inst))
	strings.write_byte(b, 34)
	write_last_error_json(b, inst.last_error_json)
	strings.write_string(b, "}")
}

i32_to_string_http :: proc(v: int) -> string {
	return fmt.tprintf("%d", v)
}

write_support_json :: proc(b: ^strings.Builder, s: domain.Agent_Bridge_Support) {
	strings.write_string(b, "{\"agent_id\":\""); write_handler_json_string(b, s.agent_id)
	strings.write_string(b, "\",\"bridge_id\":\""); write_handler_json_string(b, s.bridge_id)
	strings.write_string(b, "\",\"enabled\":"); strings.write_string(b, "true" if s.enabled else "false")
	strings.write_string(b, ",\"priority\":"); strings.write_string(b, i32_to_string_http(s.priority))
	strings.write_string(b, ",\"max_instances\":"); strings.write_string(b, i32_to_string_http(s.max_instances))
	strings.write_string(b, ",\"updated_at\":\""); write_handler_json_string(b, s.updated_at)
	strings.write_string(b, "\"}")
}
