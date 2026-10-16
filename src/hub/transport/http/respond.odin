package http

import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"

Response :: struct {
	status:       int,
	content_type: string,
	body:         string,
	headers:      []contracts.HTTP_Header,
}

respond_success :: proc(data_json: string, request_id, server_time: string, status := 200) -> Response {
	return Response{
		status = status,
		content_type = "application/json",
		body = contracts.api_success_json(data_json, contracts.api_meta(request_id, server_time)),
	}
}

respond_list :: proc(data_json: string, page: contracts.API_Page, request_id, server_time: string) -> Response {
	return Response{
		status = 200,
		content_type = "application/json",
		body = contracts.api_list_json(data_json, page, contracts.api_meta(request_id, server_time)),
	}
}

respond_error :: proc(err: domain.Domain_Error, request_id: string) -> Response {
	return Response{
		status = status_for_error(err.code),
		content_type = "application/json",
		body = contracts.api_error_json(
			contracts.API_Error{
				code = domain.error_code_string(err.code),
				message = err.message,
				details_json = err.details_json,
				class = contracts.bridge_error_class_name(domain.domain_error_class(err)),
				cause = err.cause,
			},
			contracts.api_meta(request_id, ""),
		),
	}
}

// status_for_error is the code's HTTP status from the shared contract table.
status_for_error :: proc(code: domain.Error_Code) -> int {
	return contracts.error_code_http_status(code)
}
