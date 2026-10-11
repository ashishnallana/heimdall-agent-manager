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
			contracts.API_Error{code = domain.error_code_string(err.code), message = err.message, details_json = err.details_json},
			contracts.api_meta(request_id, ""),
		),
	}
}

status_for_error :: proc(code: domain.Error_Code) -> int {
	switch code {
	case .Unauthenticated: return 401
	case .Forbidden: return 403
	case .Not_Found: return 404
	case .Validation_Failed: return 400
	case .Conflict: return 409
	case .Gone: return 410
	case .Unprocessable_Entity: return 422
	case .Bridge_Offline: return 409
	case .Bridge_Busy: return 503
	case .Bridge_Timeout: return 504
	case .Provider_Unavailable: return 503
	case .Bridge_Revoked: return 403
	case .Instance_Not_Running: return 409
	case .Rate_Limited: return 429
	case .Not_Implemented: return 501
	case .Internal_Error: return 500
	case .Vault_Locked: return 423 // RFC 4918 Locked: retryable once the bridge is unsealed
	case .None: return 200
	}
	return 500
}
