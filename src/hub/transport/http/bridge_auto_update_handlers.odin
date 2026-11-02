package http

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import bridge_service "odin_test:hub/service/bridge"
import bridge_runtime_service "odin_test:hub/service/bridge_runtime"
import project_service "odin_test:hub/service/project"

// Bridge credentials resolve only their own target; no user session is needed.
bridge_auto_update_catalog_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	token, token_ok := bearer_token(req)
	if !token_ok do return respond_error(domain.domain_error(.Unauthenticated, "bridge bearer token is required"), req.request_id)
	auth, ok, err := bridge_service.verify_bridge_token(h.bridges, token)
	if !ok do return respond_error(err, req.request_id)
	bridge, found, lookup_err := iface.bridge_get_bridge(h.bridges.repo, auth.bridge_id)
	if lookup_err.code != .None do return respond_error(lookup_err, req.request_id)
	if !found do return respond_error(domain.domain_error(.Not_Found, "bridge is not registered"), req.request_id)
	defer domain.bridge_destroy(&bridge)
	info := bridge_service.resolve_bridge_update_info(h.bridges.catalog, bridge)
	data, jerr := json.marshal(struct {latest_version: string, artifact_available: bool}{info.latest_version, info.artifact_available}, allocator = context.temp_allocator)
	if jerr != nil do return respond_error(domain.domain_error(.Internal_Error, "cannot encode update catalog"), req.request_id)
	return respond_success(string(data), req.request_id, auth_ctx_server_time(req))
}

// GET/PUT is relayed to the live owner-checked bridge. The config file remains
// authoritative and edits take effect without restarting any profile.
bridge_auto_update_config_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	auth, authenticated, auth_response := require_auth(h.auth, req)
	if !authenticated do return auth_response
	id := strings.trim_suffix(suffix_after(req.path, "/api/v1/bridges/"), "/auto-update")
	bridge, found, err := bridge_service.get_bridge(h.bridges, auth, id)
	if !found do return respond_error(err, req.request_id)
	defer domain.bridge_destroy(&bridge)
	write := req.method == "PUT"
	enabled := true
	if write {
		value, valid := json_bool_literal(req.body, "enabled")
		if !valid do return respond_error(domain.domain_error(.Validation_Failed, "enabled must be a JSON boolean"), req.request_id)
		enabled = value
	}
	command_id := fmt.tprintf("auto_update_%d", time.to_unix_nanoseconds(time.now()))
	command, _ := json.marshal(struct {type, command_id: string, write, enabled: bool}{"auto_update_config", command_id, write, enabled}, allocator = context.temp_allocator)
	reply, received, relay_err := bridge_runtime_service.send_runtime_command_wait(h.bridge_runtime_registry, project_service.Runtime_Command{bridge_id = id, command_id = command_id, body_json = string(command)}, 10000)
	if !received do return respond_error(relay_err, req.request_id)
	defer delete(reply)
	result: struct {type, command_id: string, ok, enabled: bool}
	if json.unmarshal_string(reply, &result, allocator = context.temp_allocator) != nil || result.command_id != command_id || result.type != "auto_update_config_result" || !result.ok do return respond_error(domain.domain_error(.Internal_Error, "bridge could not read or save automatic update settings"), req.request_id)
	return respond_success(reply, req.request_id, auth_ctx_server_time(req))
}
