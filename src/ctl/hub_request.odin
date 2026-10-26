package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import httpc "odin_test:lib/httpc"

// ---- hub REST requests --------------------------------------------------------
//
// Every hub REST call ham-ctl makes is described as a Ctl_Request and encoded by
// src/lib/httpc; callers never build a URL, query string, header or body by
// string interpolation:
//
//   path  : segments, e.g. ctl_api("memories", memory_id). httpc percent-encodes
//           each segment as ONE segment, so an id holding ' ', '/' or '?' cannot
//           change the route.
//   query : only the params that are set (ctl_query_add skips empty values).
//   body  : nil, or httpc.json_body(value) where value is a struct whose optional
//           fields carry `json:"name,omitempty"`. User-supplied raw JSON flags
//           are parsed into json.Value (ctl_parse_json_flag) first.
//
// The same request goes over either transport: User sends it to the hub with
// httpc; Agent renders it into the bridge's agent.rest.request envelope
// ({http_method, path, body}) with httpc.build_target and the marshalled body.

Ctl_Request :: struct {
	method: httpc.Method,
	path:   []string,
	query:  []httpc.Query_Param,
	body:   httpc.Body,
}

CTL_HUB_REQUEST_FAILED :: `{"ok":false,"message":"Hub request failed"}`
CTL_INVALID_HUB_REQUEST :: `{"ok":false,"message":"invalid hub request: an id is empty or is not a valid path segment"}`

// ctl_api returns the path segments of /api/v1/<segments...> (temp-allocated).
ctl_api :: proc(segments: ..string) -> []string {
	out := make([]string, len(segments) + 2, context.temp_allocator)
	out[0] = "api"
	out[1] = "v1"
	copy(out[2:], segments)
	return out
}

// ctl_query_make starts a temp-allocated query parameter list.
ctl_query_make :: proc() -> [dynamic]httpc.Query_Param {
	return make([dynamic]httpc.Query_Param, context.temp_allocator)
}

// ctl_query_add appends name=value only when value is set.
ctl_query_add :: proc(q: ^[dynamic]httpc.Query_Param, name, value: string) {
	if value == "" do return
	append(q, httpc.Query_Param{name = name, value = value})
}

// ctl_request_body_text is the marshalled JSON of a request body ("" for none).
ctl_request_body_text :: proc(body: httpc.Body) -> (string, bool) {
	if body == nil do return "", true
	jb, is_json := body.(httpc.Json_Body)
	if !is_json || jb.failed do return "", false
	return string(jb.encoded), true
}

// ctl_json_text marshals a value for a local (non-HTTP) bridge RPC param object.
ctl_json_text :: proc(value: any, allocator := context.allocator) -> string {
	data, err := json.marshal(value, allocator = allocator)
	if err != nil do return ""
	return string(data)
}

// ctl_parse_json_document parses one complete JSON document (trailing bytes are
// an error, unlike json.parse). Integers stay integers.
ctl_parse_json_document :: proc(text: string, allocator := context.temp_allocator) -> (json.Value, bool) {
	p := json.make_parser_from_string(strings.trim_space(text), json.DEFAULT_SPECIFICATION, true, allocator)
	value, err := json.parse_value(&p)
	if err != nil || p.curr_token.kind != .EOF do return nil, false
	return value, true
}

// ctl_parse_json_flag parses the raw JSON value of `flag`. An invalid value is a
// usage error: it prints the CLI error and exits 1 (the hub would only reject a
// body that is not JSON).
ctl_parse_json_flag :: proc(flag, text: string) -> json.Value {
	value, ok := ctl_parse_json_document(text)
	if !ok do ctl_print_error_exit(fmt.tprintf("%s must be valid JSON", flag))
	return value
}

// ctl_parse_number_flag parses a numeric flag value sent as a JSON number.
ctl_parse_number_flag :: proc(flag, text: string) -> f64 {
	v, ok := strconv.parse_f64(strings.trim_space(text))
	if !ok do ctl_print_error_exit(fmt.tprintf("%s must be a number", flag))
	return v
}

// ctl_parse_int_text parses a decimal integer that a caller already validated.
ctl_parse_int_text :: proc(text: string) -> i64 {
	v, _ := strconv.parse_i64(strings.trim_space(text))
	return v
}

// ---- user transport (direct HTTP) ---------------------------------------------

// Ctl_Hub is the user transport target: the hub base URL parsed once per command
// (a path prefix such as https://host/heimdall is kept; request paths resolve
// under it) and the bearer token.
Ctl_Hub :: struct {
	url:   httpc.Url,
	token: string,
	valid: bool,
}

ctl_hub_make :: proc(base_url, token: string) -> Ctl_Hub {
	u, err := httpc.parse_url(base_url)
	return Ctl_Hub{url = u, token = token, valid = err == .None}
}

// ctl_hub_fetch sends one request. ok is false when no HTTP response arrived (or
// the base URL / request was invalid); any HTTP status is returned with its body.
ctl_hub_fetch :: proc(hub: Ctl_Hub, req: Ctl_Request, allocator := context.allocator) -> (body: string, status: int, ok: bool) {
	if !hub.valid do return "", 0, false
	headers: [1]httpc.Header
	n := 0
	if hub.token != "" {
		headers[0] = httpc.bearer(hub.token)
		n = 1
	}
	resp, err := httpc.send(httpc.Request{
		method  = req.method,
		url     = hub.url,
		path    = req.path,
		query   = req.query,
		headers = headers[:n],
		body    = req.body,
		// Responses can be large (artifacts): a stall guard, not a short total,
		// as with the deleted client's per-read timeout.
		timeout_ms         = httpc.LONG_TRANSFER_TIMEOUT_MS,
		connect_timeout_ms = httpc.DEFAULT_TIMEOUT_MS,
		stall_timeout_ms   = httpc.DEFAULT_STALL_TIMEOUT_MS,
	})
	defer httpc.response_destroy(&resp)
	if err != .None do return "", resp.status, false
	return strings.clone(httpc.text(resp), allocator), resp.status, true
}

// ctl_hub_request_string returns the response body, printing the failure envelope
// when the hub could not be reached.
ctl_hub_request_string :: proc(hub: Ctl_Hub, req: Ctl_Request) -> (string, bool) {
	body, _, ok := ctl_hub_fetch(hub, req)
	if !ok {
		fmt.println(CTL_HUB_REQUEST_FAILED)
		return "", false
	}
	return body, true
}

// ctl_hub_request prints the hub's response body.
ctl_hub_request :: proc(hub: Ctl_Hub, req: Ctl_Request) {
	resp, ok := ctl_hub_request_string(hub, req)
	if !ok do return
	fmt.println(resp)
}

// ctl_hub_request_raw writes the response body to stdout byte for byte.
ctl_hub_request_raw :: proc(hub: Ctl_Hub, req: Ctl_Request) {
	resp, ok := ctl_hub_request_string(hub, req)
	if !ok do return
	_, _ = os.write(os.stdout, transmute([]byte)resp)
}

// ---- agent transport (bridge agent.rest.request relay) ------------------------

// ctl_agent_rest_params renders a request as the agent.rest.request params
// {http_method, path, body}: path is the origin-form target (encoded exactly as
// the user transport encodes it), body the marshalled JSON ("" for none).
ctl_agent_rest_params :: proc(req: Ctl_Request) -> (params: string, ok: bool) {
	target, terr := httpc.build_target(req.path, req.query, context.temp_allocator)
	if terr != .None do return "", false
	body, bok := ctl_request_body_text(req.body)
	if !bok do return "", false
	return json_object(json_kv("http_method", httpc.method_name(req.method)), json_kv("path", target), json_kv("body", body)), true
}

// ctl_agent_rest_params_or_exit is ctl_agent_rest_params for callers that
// print-and-exit on an unusable request.
ctl_agent_rest_params_or_exit :: proc(req: Ctl_Request) -> string {
	params, ok := ctl_agent_rest_params(req)
	if !ok {
		fmt.println(CTL_INVALID_HUB_REQUEST)
		os.exit(1)
	}
	return params
}

// ctl_agent_rest prints the relayed response (ctl_agent_call semantics).
ctl_agent_rest :: proc(endpoint, token: string, req: Ctl_Request) {
	ctl_agent_call(endpoint, token, "agent.rest.request", ctl_agent_rest_params_or_exit(req))
}

// ctl_agent_rest_local returns the relayed response (ctl_agent_local_call semantics).
ctl_agent_rest_local :: proc(endpoint, token: string, req: Ctl_Request) -> (string, bool) {
	return ctl_agent_local_call(endpoint, token, "agent.rest.request", ctl_agent_rest_params_or_exit(req))
}

// ---- either transport -----------------------------------------------------------

CTL_USER_TRANSPORT_REQUIRED :: `{"ok":false,"message":"user transport requires --hub-url and --user-token (or HAM_HUB_URL/HEIMDALL_HUB_URL and HAM_HUB_USER_TOKEN/HEIMDALL_USER_TOKEN)"}`
CTL_AGENT_TRANSPORT_REQUIRED :: `{"ok":false,"message":"agent transport requires HEIMDALL_BRIDGE_ENDPOINT and HEIMDALL_AGENT_TOKEN (or --bridge-endpoint/--agent-token)"}`

// ctl_transport_fetch sends req over the resolved transport and returns the
// response text; on failure the text is the error envelope to print (or "").
ctl_transport_fetch :: proc(transport: Ctl_Transport, req: Ctl_Request, user_missing := `{"ok":false,"message":"user transport requires --hub-url and --user-token"}`, agent_missing := `{"ok":false,"message":"agent transport requires HEIMDALL_BRIDGE_ENDPOINT and HEIMDALL_AGENT_TOKEN"}`) -> (string, bool) {
	switch transport.kind {
	case .User:
		if transport.user_base_url == "" || transport.user_token == "" do return user_missing, false
		body, _, ok := ctl_hub_fetch(transport.hub, req)
		if !ok do return CTL_HUB_REQUEST_FAILED, false
		return body, true
	case .Agent:
		if transport.agent_endpoint == "" || transport.agent_token == "" do return agent_missing, false
		params, pok := ctl_agent_rest_params(req)
		if !pok do return CTL_INVALID_HUB_REQUEST, false
		return ctl_agent_local_call(transport.agent_endpoint, transport.agent_token, "agent.rest.request", params)
	}
	return "", false
}

// ctl_tasks_request prints the response of req over the resolved transport.
ctl_tasks_request :: proc(transport: Ctl_Transport, req: Ctl_Request) {
	switch transport.kind {
	case .User:
		if transport.user_base_url == "" || transport.user_token == "" {
			fmt.println(CTL_USER_TRANSPORT_REQUIRED)
			return
		}
		ctl_hub_request(transport.hub, req)
	case .Agent:
		if transport.agent_endpoint == "" || transport.agent_token == "" {
			fmt.println(CTL_AGENT_TRANSPORT_REQUIRED)
			return
		}
		ctl_agent_rest(transport.agent_endpoint, transport.agent_token, req)
	}
}

ctl_tasks_request_local :: proc(transport: Ctl_Transport, req: Ctl_Request) -> (string, bool) {
	return ctl_transport_fetch(transport, req)
}

// ctl_print_decrypted prints a response with vault content opened locally.
ctl_print_decrypted :: proc(resp_str: string, args: []string) {
	keyring, key_ok := ctl_read_vault_keyring(args, context.temp_allocator)
	decrypted_json := ctl_decrypt_json_string(resp_str, keyring, key_ok)
	defer delete(decrypted_json)
	fmt.println(decrypted_json)
}

ctl_tasks_request_and_decrypt :: proc(transport: Ctl_Transport, req: Ctl_Request, args: []string = nil) {
	resp_str, ok := ctl_tasks_request_local(transport, req)
	if !ok {
		if resp_str != "" do fmt.println(resp_str)
		return
	}
	ctl_print_decrypted(resp_str, args)
}

// ---- shared body pieces -------------------------------------------------------

// ctl_csv_list splits a comma list into trimmed items (blank items kept as the
// old hand-built arrays kept them; callers that drop blanks use
// collect_multi_values). Temp-allocated.
ctl_csv_list :: proc(csv: string) -> []string {
	parts := strings.split(csv, ",", context.temp_allocator)
	for &p in parts do p = strings.trim_space(p)
	return parts
}

// ctl_multi_values is collect_multi_values (repeated and/or comma-separated
// flag values, blanks dropped) with every allocation on the temp allocator.
ctl_multi_values :: proc(args: []string, names: ..string) -> []string {
	context.allocator = context.temp_allocator
	values := collect_multi_values(args, ..names)
	return values[:]
}

// Small bodies shared by several routes.
Ctl_Empty_Body :: struct {}
Ctl_Task_Note_Body :: struct {
	note: string `json:"note"`,
}
Ctl_Task_Reason_Body :: struct {
	reason: string `json:"reason"`,
}
Ctl_Status_Body :: struct {
	status: string `json:"status"`,
}
Ctl_Pinned_Body :: struct {
	pinned: bool `json:"pinned"`,
}

// ctl_empty_object_body is the `{}` body of an action route that takes none.
ctl_empty_object_body :: proc() -> httpc.Body {
	return httpc.json_body(Ctl_Empty_Body{})
}
