package http

import "core:encoding/json"
import "core:fmt"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import project_service "odin_test:hub/service/project"
import jsonx "odin_test:lib/jsonx"
import metrics "odin_test:lib/metrics"

Response :: struct {
	status:       int,
	content_type: string,
	body:         string,
	headers:      []contracts.HTTP_Header,
	// Request-owned MCP plaintext: wipe body and writer copy after forwarding.
	sensitive:    bool,
	// Optional bounded send budget for MCP; other transports retain their policy.
	write_timeout_ms: int,
}

respond_success :: proc(data_json: string, request_id, server_time: string, status := 200) -> Response {
	return Response{
		status = status,
		content_type = "application/json",
		body = contracts.api_success_json(data_json, contracts.api_meta(request_id, server_time)),
	}
}

// respond_success_typed marshals `value` with json.marshal as the envelope's data.
// Use it for every reply that carries a credential (tokens, tickets, session ids):
// such a reply is never assembled by string concatenation. A marshal failure is an
// internal error, never a malformed 200.
respond_success_typed :: proc(value: $T, request_id, server_time: string, status := 200) -> Response {
	data, err := json.marshal(value, allocator = context.temp_allocator)
	if err != nil do return respond_error(domain.domain_error(.Internal_Error, "failed to encode the response"), request_id)
	return respond_success(string(data), request_id, server_time, status)
}

respond_list :: proc(data_json: string, page: contracts.API_Page, request_id, server_time: string) -> Response {
	return Response{
		status = 200,
		content_type = "application/json",
		body = contracts.api_list_json(data_json, page, contracts.api_meta(request_id, server_time)),
	}
}

respond_error :: proc(err: domain.Domain_Error, request_id: string) -> Response {
	status := status_for_error(err.code)
	class := contracts.bridge_error_class_name(domain.domain_error_class(err))
	metrics.counter_inc(metrics.with(project_service.fleet_metrics.errors, domain.error_code_string(err.code), class))
	retry_after_ms := i64(jsonx.extract_int(err.details_json, "retry_after_ms", 0)) if err.details_json != "" else 0
	resp := Response{
		status = status,
		content_type = "application/json",
		body = contracts.api_error_json(
			contracts.API_Error{
				code = domain.error_code_string(err.code),
				message = err.message,
				details_json = err.details_json,
				class = class,
				cause = err.cause,
				retry_after_ms = retry_after_ms,
			},
			contracts.api_meta(request_id, ""),
		),
	}
	// REQ-ERR-PROTO-B: overload answers say when to come back (RFC 9110 Retry-After,
	// whole seconds, at least 1); the body carries the exact retry_after_ms.
	if status == 429 || status == 503 {
		seconds := max((retry_after_ms + 999) / 1000, 1)
		resp.headers = make([]contracts.HTTP_Header, 1, context.temp_allocator) // value is temp too; written before the request ends
		resp.headers[0] = contracts.HTTP_Header{name = "Retry-After", value = fmt.tprintf("%d", seconds)}
	}
	return resp
}

// status_for_error is the code's HTTP status from the shared contract table.
status_for_error :: proc(code: domain.Error_Code) -> int {
	return contracts.error_code_http_status(code)
}
