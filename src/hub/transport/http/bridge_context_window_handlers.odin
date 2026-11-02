package http

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"
import domain "odin_test:hub/domain"
import bridge_service "odin_test:hub/service/bridge"
import bridge_runtime_service "odin_test:hub/service/bridge_runtime"
import project_service "odin_test:hub/service/project"

// Context-window settings (chain "Estimate agent tokens via extensions", T9).
//
// The bridge owns the shipped context-window config and the user overrides
// (src/bridge/context_window.odin). The hub only RELAYS a context_window_op
// frame to the live, owner-checked bridge and returns its reply; nothing is
// stored hub-side.
//
//   GET    /api/v1/bridges/{id}/context-windows   -> op=list
//   PUT    /api/v1/bridges/{id}/context-windows   -> op=set   body {provider, model, context_window}
//   DELETE /api/v1/bridges/{id}/context-windows   -> op=clear provider/model in the query or the body
//
// Every success carries the bridge's full list state, so the UI re-renders
// from the reply. A bridge rejection (ok:false) becomes an API error whose
// details_json.bridge_error holds the bridge's code (below_minimum, ...).

// Must match BRIDGE_CONTEXT_WINDOW_MIN / _MAX in src/bridge/context_window.odin;
// the hub checks first so a bad value never reaches the bridge.
HUB_CONTEXT_WINDOW_MIN :: 100_000
HUB_CONTEXT_WINDOW_MAX :: 100_000_000

HUB_CONTEXT_WINDOW_RELAY_TIMEOUT_MS :: 10000

Context_Window_Request :: struct {
	op:             string,
	provider:       string,
	model:          string,
	context_window: i64,
}

// context_window_request_parse validates the request side of a relay. Pure so
// tests can pin the server-side rules without a live bridge.
context_window_request_parse :: proc(method, query, body: string) -> (r: Context_Window_Request, err: domain.Domain_Error, ok: bool) {
	switch method {
	case "GET":
		r.op = "list"
		return r, {}, true
	case "PUT":
		r.op = "set"
		r.provider = strings.trim_space(json_string(body, "provider", context.temp_allocator))
		r.model = strings.trim_space(json_string(body, "model", context.temp_allocator))
		value, valid := context_window_json_integer(body, "context_window")
		if !valid do return r, domain.domain_error(.Validation_Failed, "context_window must be a whole number of tokens", `{"bridge_error":"invalid_value"}`), false
		r.context_window = value
	case "DELETE":
		r.op = "clear"
		r.provider = strings.trim_space(query_value(query, "provider"))
		r.model = strings.trim_space(query_value(query, "model"))
		if r.provider == "" do r.provider = strings.trim_space(json_string(body, "provider", context.temp_allocator))
		if r.model == "" do r.model = strings.trim_space(json_string(body, "model", context.temp_allocator))
	case:
		return r, domain.domain_error(.Validation_Failed, "unsupported method"), false
	}
	if r.provider == "" do return r, domain.domain_error(.Validation_Failed, "provider is required", `{"bridge_error":"invalid_provider"}`), false
	if r.model == "" do return r, domain.domain_error(.Validation_Failed, "model is required", `{"bridge_error":"invalid_model"}`), false
	if r.op == "set" {
		if r.context_window < HUB_CONTEXT_WINDOW_MIN do return r, domain.domain_error(.Validation_Failed, fmt.tprintf("context_window must be at least %d tokens", HUB_CONTEXT_WINDOW_MIN), `{"bridge_error":"below_minimum"}`), false
		if r.context_window > HUB_CONTEXT_WINDOW_MAX do return r, domain.domain_error(.Validation_Failed, fmt.tprintf("context_window must be at most %d tokens", HUB_CONTEXT_WINDOW_MAX), `{"bridge_error":"above_maximum"}`), false
	}
	return r, {}, true
}

// context_window_json_integer reads a JSON number that is a whole number; a
// string, a fraction or a missing key is rejected (jsonx.extract_int would
// quietly fall back or truncate).
@(private = "file")
context_window_json_integer :: proc(body, key: string) -> (value: i64, ok: bool) {
	parsed, perr := json.parse_string(body, allocator = context.temp_allocator)
	if perr != nil do return 0, false
	obj, is_obj := parsed.(json.Object)
	if !is_obj do return 0, false
	switch v in obj[key] {
	case json.Integer: return v, true
	case json.Float:
		if v != f64(i64(v)) do return 0, false
		return i64(v), true
	case json.Null, json.Boolean, json.String, json.Array, json.Object:
	}
	return 0, false
}

// context_window_bridge_error maps a bridge error code onto an API error.
context_window_bridge_error :: proc(code: string) -> domain.Domain_Error {
	details := fmt.tprintf(`{{"bridge_error":"%s"}}`, code) if context_window_code_safe(code) else `{"bridge_error":"unknown"}`
	switch code {
	case "below_minimum":      return domain.domain_error(.Validation_Failed, fmt.tprintf("bridge rejected the value: context window must be at least %d tokens", HUB_CONTEXT_WINDOW_MIN), details)
	case "above_maximum":      return domain.domain_error(.Validation_Failed, fmt.tprintf("bridge rejected the value: context window must be at most %d tokens", HUB_CONTEXT_WINDOW_MAX), details)
	case "invalid_provider":   return domain.domain_error(.Validation_Failed, "bridge rejected the provider id", details)
	case "invalid_model":      return domain.domain_error(.Validation_Failed, "bridge rejected the model id", details)
	case "too_many_overrides": return domain.domain_error(.Validation_Failed, "bridge has too many context-window overrides; clear one first", details)
	case "bad_op":             return domain.domain_error(.Validation_Failed, "bridge does not support this context-window operation", details)
	case "persist_failed":     return domain.domain_error(.Internal_Error, "bridge could not save the context-window override", details)
	}
	return domain.domain_error(.Internal_Error, "bridge could not apply the context-window change", details)
}

@(private = "file")
context_window_code_safe :: proc(code: string) -> bool {
	if code == "" || len(code) > 64 do return false
	for c in code {
		if !((c >= 'a' && c <= 'z') || c == '_') do return false
	}
	return true
}

bridge_context_windows_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	auth, authenticated, auth_response := require_auth(h.auth, req)
	if !authenticated do return auth_response
	id := strings.trim_suffix(suffix_after(req.path, "/api/v1/bridges/"), "/context-windows")
	bridge, found, err := bridge_service.get_bridge(h.bridges, auth, id)
	if !found do return respond_error(err, req.request_id)
	defer domain.bridge_destroy(&bridge)
	r, verr, valid := context_window_request_parse(req.method, req.query, req.body)
	if !valid do return respond_error(verr, req.request_id)
	command_id := fmt.tprintf("context_window_%d", time.to_unix_nanoseconds(time.now()))
	command, _ := json.marshal(struct {type, command_id, op, provider, model: string, context_window: i64}{"context_window_op", command_id, r.op, r.provider, r.model, r.context_window}, allocator = context.temp_allocator)
	reply, received, relay_err := bridge_runtime_service.send_runtime_command_wait(h.bridge_runtime_registry, project_service.Runtime_Command{bridge_id = id, command_id = command_id, body_json = string(command)}, HUB_CONTEXT_WINDOW_RELAY_TIMEOUT_MS)
	if !received do return respond_error(relay_err, req.request_id)
	defer delete(reply, runtime.default_allocator()) // the runtime registry allocates command results there
	result: struct {type, command_id, error: string, ok: bool}
	if json.unmarshal_string(reply, &result, allocator = context.temp_allocator) != nil || result.command_id != command_id || result.type != "context_window_op_result" do return respond_error(domain.domain_error(.Internal_Error, "uncorrelated context-window result"), req.request_id)
	if !result.ok do return respond_error(context_window_bridge_error(result.error), req.request_id)
	return respond_success(reply, req.request_id, auth_ctx_server_time(req))
}
