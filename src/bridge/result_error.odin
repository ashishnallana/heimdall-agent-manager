package main

import "core:strings"
import contracts "odin_test:contracts"

// ---- result-frame errors (REQ-ERR-PROTO-A) --------------------------------
//
// Every reply the bridge sends the hub reports failure the same way: "ok":false plus
// the shared wire error object (contracts.Wire_Error):
//
//   "ok":false,"error":{"code":"not_found","class":"fatal","cause":"path_not_found","message":"..."}
//
// cause is the fine-grained reason the bridge already used (fs/vcs/shell/search
// codes); bridge_cause_error_code picks its coarse code, and with it the class and
// HTTP status the hub answers with. Failures that went through the classifier
// (Bridge_Error) use bridge_error_wire so their own class is kept.

// bridge_cause_error_code maps a reply cause to its contract code. Unknown causes
// are Internal_Error, so a new cause still reaches the hub as a typed failure.
bridge_cause_error_code :: proc(cause: string) -> contracts.Error_Code {
	switch cause {
	case "":
		return .None
	case "vault_locked":
		return .Vault_Locked
	case "bridge_busy", "search_not_ready", "host_unavailable", "response_backpressure", "pty_host_unreachable":
		return .Bridge_Busy
	case "deadline_exceeded", "capture_timeout":
		return .Bridge_Timeout
	case "path_not_found", "git_root_not_found", "session_not_found":
		return .Not_Found
	case "path_outside_root", "permission_denied", "cannot_delete_root":
		return .Forbidden
	case "path_exists", "path_exists_not_dir", "dest_exists", "dir_not_empty", "session_not_running":
		return .Conflict
	case "path_not_directory", "path_is_directory", "not_a_file", "unsupported_type", "file_too_large",
	     "invalid_ref", "missing_message", "missing_file", "untracked_file", "no_server_port", "missing_path", "missing_paths", "missing_branch",
	     "invalid_envelope", "limit_exceeded", "query_too_short", "invalid_vault_key", "invalid_command", "invalid_payload",
	     "missing_command_id", "missing_session_id", "command_too_large", "missing_cmd",
	     "invalid_cwd", "missing_fields", "vault_unseal_failed":
		return .Validation_Failed
	case "no_vcs", "batch_write_partial":
		return .Unprocessable_Entity
	case "not_supported", "unsupported_command", "unknown_command", "unsupported_route":
		return .Not_Implemented
	case "shell_output_reclaimed", "output_reclaimed":
		return .Gone
	}
	// fs/vcs actions the bridge understood but could not carry out (commit_failed,
	// write_failed, ...): the same request will fail the same way.
	if strings.has_suffix(cause, "_failed") do return .Unprocessable_Entity
	return .Internal_Error
}

// bridge_cause_wire_error is the wire error for a reply cause (zero value for "").
bridge_cause_wire_error :: proc(cause, message: string, retry_after_ms: i64 = 0, scope := "") -> contracts.Wire_Error {
	if cause == "" do return {}
	return contracts.wire_error(bridge_cause_error_code(cause), cause, message, retry_after_ms, scope)
}

// bridge_error_wire reports a classified Bridge_Error, keeping its class.
bridge_error_wire :: proc(err: Bridge_Error, message := "") -> contracts.Wire_Error {
	return contracts.wire_error_from_bridge(err.code, err.class, message, err.retry_after_ms)
}

// Bridge_Result_Error is the marshal-able form of the wire error for replies built
// with json.marshal (fs/vcs). All fields are "" on success.
Bridge_Result_Error :: struct {
	code:    string `json:"code"`,
	class:   string `json:"class"`,
	cause:   string `json:"cause"`,
	message: string `json:"message"`,
}

bridge_result_error :: proc(cause, message: string) -> Bridge_Result_Error {
	if cause == "" do return {}
	code := bridge_cause_error_code(cause)
	return Bridge_Result_Error{
		code    = contracts.error_code_string(code),
		class   = contracts.bridge_error_class_name(contracts.error_code_class(code)),
		cause   = cause,
		message = message,
	}
}

// bridge_write_failure appends `"ok":false,"error":{...}` (no leading comma).
bridge_write_failure :: proc(b: ^strings.Builder, err: contracts.Wire_Error) {
	strings.write_string(b, "\"ok\":false,\"error\":")
	contracts.write_wire_error(b, err)
}
