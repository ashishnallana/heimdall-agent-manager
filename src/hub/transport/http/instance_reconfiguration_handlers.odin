package http

import "core:encoding/json"
import "core:strings"
import agent_service "odin_test:hub/service/agent"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import jsonx "odin_test:lib/jsonx"

create_instance_reconfiguration_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth, authorized, auth_response := require_auth(h.auth, req)
	if !authorized do return auth_response
	// This is an explicit full destination, unlike the legacy partial PATCH.
	// permission_mode (yolo|ask) is the one optional field: omitted keeps the
	// instance's current override.
	for field in ([]string{"bridge_id", "project_id", "provider", "model", "idempotency_key", "expected_revision"}) {
		if !jsonx.has_key(req.body, field, true) do return respond_error(domain.domain_error(.Validation_Failed, "full destination and expected revision are required"), req.request_id)
	}
	value, parse_err := json.parse_string(req.body, .JSON, allocator = context.temp_allocator)
	object, is_object := value.(json.Object)
	if parse_err != nil || !is_object do return respond_error(domain.domain_error(.Validation_Failed, "request must be a JSON object"), req.request_id)
	for key, _ in object {
		if key != "bridge_id" && key != "project_id" && key != "provider" && key != "model" && key != "idempotency_key" && key != "expected_revision" && key != "permission_mode" && key != "provider_profile" do return respond_error(domain.domain_error(.Validation_Failed, "unknown reconfiguration field"), req.request_id)
	}
	input: agent_service.Reconfigure_Operation_Input
	if json.unmarshal_string(req.body, &input, .JSON, context.temp_allocator) != nil do return respond_error(domain.domain_error(.Validation_Failed, "invalid reconfiguration request"), req.request_id)
	op, accepted, err := agent_service.begin_instance_reconfiguration(h.agents, auth, path_part(req.path, 4), input)
	if !accepted do return respond_error(err, req.request_id)
	defer domain.instance_reconfiguration_destroy(&op)
	data := agent_service.reconfiguration_json(op)
	defer delete(data)
	return respond_success(data, req.request_id, auth_ctx_server_time(req), 202)
}

list_instance_reconfigurations_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth, authorized, auth_response := require_auth(h.auth, req)
	if !authorized do return auth_response
	instance_id := path_part(req.path, 4)
	inst, found, err := agent_service.get_instance(h.agents, auth, instance_id)
	if !found do return respond_error(err, req.request_id)
	defer domain.agent_instance_destroy(&inst)
	// Reads are side-effect free (REQ-2): readiness and timeouts advance on
	// bridge transitions, start-success and the hub reaper, never on this GET.
	ops, list_err := iface.instance_reconfiguration_list(h.agents.agents, string(inst.owner_user_id), instance_id, false)
	if list_err.code != .None do return respond_error(list_err, req.request_id)
	defer { for &op in ops do domain.instance_reconfiguration_destroy(&op); delete(ops) }
	b := strings.builder_make()
	strings.write_string(&b, "{\"operations\":[")
	for op, index in ops {
		if index > 0 do strings.write_byte(&b, ',')
		data := agent_service.reconfiguration_json(op); strings.write_string(&b, data); delete(data)
	}
	strings.write_string(&b, "]}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

retry_instance_reconfiguration_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth, authorized, auth_response := require_auth(h.auth, req)
	if !authorized do return auth_response
	key := json_string(req.body, "idempotency_key")
	defer delete(key)
	op, accepted, err := agent_service.retry_instance_reconfiguration(h.agents, auth, path_part(req.path, 4), key, json_int(req.body, "expected_operation_revision", -1))
	if !accepted do return respond_error(err, req.request_id)
	defer domain.instance_reconfiguration_destroy(&op)
	data := agent_service.reconfiguration_json(op); defer delete(data)
	return respond_success(data, req.request_id, auth_ctx_server_time(req), 202)
}
