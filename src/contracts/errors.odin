package contracts

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import jsonx "odin_test:lib/jsonx"

// ---- the shared error contract (REQ-ERR-PROTO-A) -------------------------
//
// Every failure crossing the bridge<->hub boundary (WS result frames, command
// results, status frames, HTTP error envelopes) carries one wire error object:
//
//   "error":{"code":"provider_unavailable","class":"recoverable",
//            "cause":"provider_not_logged_in","message":"...",
//            "retry_after_ms":0,"scope":""}
//
// - code:  coarse, from Error_Code; picks the HTTP status and the default class.
// - class: what the receiver may do (Bridge_Error_Class): retriable -> back off and
//          retry; recoverable -> stop until an outside event (login, unseal, config);
//          fatal -> give up. Set by the side that knows the cause.
// - cause: fine-grained, domain-specific reason (a Bridge_Log_Code name, an fs/vcs
//          reason such as "path_not_found"); for display and diagnostics.
// - message: human text, display only. Behaviour never branches on it.
//
// Only the top-level "error" object of a frame is read, so an error nested inside a
// result payload (a batch item) never fails the whole frame.

Error_Code :: enum {
	None,
	Unauthenticated,
	Forbidden,
	Not_Found,
	Validation_Failed,
	Conflict,
	Bridge_Offline,
	Bridge_Busy,
	Bridge_Timeout,
	Bridge_Revoked,
	Provider_Unavailable,
	Instance_Not_Running,
	Rate_Limited,
	Gone,
	Unprocessable_Entity,
	Not_Implemented,
	Internal_Error,
	Vault_Locked,
	Plan_Limit_Reached,
	Question_Stale,
	Question_Answered,
	Question_Invalid,
}

Error_Code_Info :: struct {
	name:        string,
	class:       Bridge_Error_Class,
	http_status: int,
}

// ERROR_CODE_TABLE is exhaustive: adding an Error_Code without a row fails to compile.
ERROR_CODE_TABLE :: [Error_Code]Error_Code_Info{
	.None                 = {"",                     .fatal,       200},
	.Unauthenticated      = {"unauthenticated",      .recoverable, 401},
	.Forbidden            = {"forbidden",            .recoverable, 403},
	.Not_Found            = {"not_found",            .fatal,       404},
	.Validation_Failed    = {"validation_failed",    .fatal,       400},
	.Conflict             = {"conflict",             .recoverable, 409},
	.Bridge_Offline       = {"bridge_offline",       .retriable,   409},
	.Bridge_Busy          = {"bridge_busy",          .retriable,   503},
	.Bridge_Timeout       = {"bridge_timeout",       .retriable,   504},
	.Bridge_Revoked       = {"bridge_revoked",       .fatal,       403},
	.Provider_Unavailable = {"provider_unavailable", .recoverable, 503},
	.Instance_Not_Running = {"instance_not_running", .recoverable, 409},
	.Rate_Limited         = {"rate_limited",         .retriable,   429},
	.Gone                 = {"gone",                 .fatal,       410},
	.Unprocessable_Entity = {"unprocessable_entity", .fatal,       422},
	.Not_Implemented      = {"not_implemented",      .fatal,       501},
	.Internal_Error       = {"internal_error",       .retriable,   500}, // unknown server fault: bounded backoff
	.Plan_Limit_Reached   = {"plan_limit_reached",   .recoverable, 402},
	.Question_Stale       = {"question_stale",       .recoverable, 409},
	.Question_Answered    = {"question_answered",    .recoverable, 409},
	.Question_Invalid     = {"question_invalid",     .fatal,       400},
	.Vault_Locked         = {"vault_locked",         .recoverable, 423}, // RFC 4918 Locked: retry after unseal
}

error_code_string :: proc(code: Error_Code) -> string {
	table := ERROR_CODE_TABLE
	return table[code].name
}

error_code_class :: proc(code: Error_Code) -> Bridge_Error_Class {
	table := ERROR_CODE_TABLE
	return table[code].class
}

error_code_http_status :: proc(code: Error_Code) -> int {
	table := ERROR_CODE_TABLE
	return table[code].http_status
}

// error_code_parse maps a wire name back to its code; ok is false for "" or an
// unknown name (callers treat that as Internal_Error / a protocol error).
error_code_parse :: proc(name: string) -> (Error_Code, bool) {
	if name == "" do return .None, false
	table := ERROR_CODE_TABLE
	for info, code in table {
		if info.name == name do return code, true
	}
	return .Internal_Error, false
}

error_class_parse :: proc(name: string) -> (Bridge_Error_Class, bool) {
	names := BRIDGE_ERROR_CLASS_NAMES
	for n, class in names {
		if n == name do return class, true
	}
	return .fatal, false
}

// BRIDGE_LOG_CODE_ERROR_CODE is the coarse code a bridge-side cause is reported as.
BRIDGE_LOG_CODE_ERROR_CODE :: [Bridge_Log_Code]Error_Code{
	.hub_connect_failed         = .Bridge_Offline,
	.tls_backend_missing        = .Internal_Error,
	.hub_rejected               = .Unauthenticated,
	.hub_ready_timeout          = .Bridge_Timeout,
	.hub_connection_replaced    = .Conflict,
	.hub_ws_closed              = .Bridge_Offline,
	.clock_skew                 = .Validation_Failed,
	.enroll_failed              = .Unauthenticated,
	.token_persist_failed       = .Internal_Error,
	.config_write_failed        = .Internal_Error,
	.vault_locked               = .Vault_Locked,
	.vault_unseal_failed        = .Validation_Failed,
	.keystore_unavailable       = .Internal_Error,
	.outbox_persist_failed      = .Internal_Error,
	.pty_host_spawn_failed      = .Internal_Error,
	.pty_host_unreachable       = .Bridge_Busy,
	.pty_host_exited            = .Bridge_Busy,
	.agent_launch_failed        = .Internal_Error,
	.agent_exited_early         = .Internal_Error,
	.agent_bootstrap_invalid    = .Unprocessable_Entity,
	.provider_missing           = .Provider_Unavailable,
	.provider_not_logged_in     = .Provider_Unavailable,
	.provider_discovery_failed  = .Provider_Unavailable,
	.shell_start_failed         = .Internal_Error,
	.shell_exited_error         = .Internal_Error,
	.lsp_start_failed           = .Internal_Error,
	.lsp_crashed                = .Internal_Error,
	.tunnel_error               = .Bridge_Busy,
	.preview_proxy_error        = .Bridge_Busy,
	.update_download_failed     = .Bridge_Busy,
	.update_apply_failed        = .Internal_Error,
	.update_rollback            = .Internal_Error,
	.telemetry_collector_failed = .Internal_Error,
	.search_index_error         = .Internal_Error,
	.internal                   = .Internal_Error,
}

bridge_log_code_error_code :: proc(code: Bridge_Log_Code) -> Error_Code {
	table := BRIDGE_LOG_CODE_ERROR_CODE
	return table[code]
}

Wire_Error :: struct {
	code:           Error_Code,
	class:          Bridge_Error_Class,
	cause:          string,
	message:        string,
	retry_after_ms: i64,
	scope:          string,
}

// wire_error builds an error whose class defaults to the code's table class.
wire_error :: proc(code: Error_Code, cause := "", message := "", retry_after_ms: i64 = 0, scope := "") -> Wire_Error {
	return Wire_Error{code = code, class = error_code_class(code), cause = cause, message = message, retry_after_ms = retry_after_ms, scope = scope}
}

// wire_error_from_bridge reports a classified bridge-side cause: the code comes from
// BRIDGE_LOG_CODE_ERROR_CODE and the class is the bridge's own classification.
wire_error_from_bridge :: proc(cause: Bridge_Log_Code, class: Bridge_Error_Class, message := "", retry_after_ms: i64 = 0, scope := "") -> Wire_Error {
	return Wire_Error{code = bridge_log_code_error_code(cause), class = class, cause = bridge_log_code_name(cause), message = message, retry_after_ms = retry_after_ms, scope = scope}
}

// Wire_Error_Json is the marshal-able wire error object (json.marshal), with the same
// members as write_wire_error: retry_after_ms and scope only when set.
Wire_Error_Json :: struct {
	code:           string,
	class:          string,
	cause:          string,
	message:        string,
	retry_after_ms: Maybe(i64) `json:"retry_after_ms,omitempty"`,
	scope:          string     `json:"scope,omitempty"`,
}

// wire_error_json_value is err as a Wire_Error_Json.
wire_error_json_value :: proc(err: Wire_Error) -> Wire_Error_Json {
	out := Wire_Error_Json{
		code    = error_code_string(err.code),
		class   = bridge_error_class_name(err.class),
		cause   = err.cause,
		message = err.message,
		scope   = err.scope,
	}
	if err.retry_after_ms > 0 do out.retry_after_ms = err.retry_after_ms
	return out
}

// write_wire_error writes the error object (no key) into b.
write_wire_error :: proc(b: ^strings.Builder, err: Wire_Error) {
	strings.write_string(b, "{\"code\":\"")
	write_json_string(b, error_code_string(err.code))
	strings.write_string(b, "\",\"class\":\"")
	write_json_string(b, bridge_error_class_name(err.class))
	strings.write_string(b, "\",\"cause\":\"")
	write_json_string(b, err.cause)
	strings.write_string(b, "\",\"message\":\"")
	write_json_string(b, err.message)
	strings.write_string(b, "\"")
	if err.retry_after_ms > 0 do fmt.sbprintf(b, ",\"retry_after_ms\":%d", err.retry_after_ms)
	if err.scope != "" {
		strings.write_string(b, ",\"scope\":\"")
		write_json_string(b, err.scope)
		strings.write_string(b, "\"")
	}
	strings.write_string(b, "}")
}

// wire_error_json renders the error object; allocated with `allocator`.
wire_error_json :: proc(err: Wire_Error, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	write_wire_error(&b, err)
	return strings.to_string(b)
}

// wire_error_parse reads the top-level "error" object of a frame or response body.
// found is false when there is no error object (or it has no code); an unknown code
// or class name decodes as Internal_Error / the code's table class. Strings are
// allocated with `allocator`.
wire_error_parse :: proc(body: string, allocator := context.allocator) -> (err: Wire_Error, found: bool) {
	root, ok := jsonx.parse_body(body, context.temp_allocator)
	if !ok do return {}, false
	top, is_obj := root.(json.Object)
	if !is_obj do return {}, false
	obj, has_err := top["error"].(json.Object)
	if !has_err do return {}, false
	name, _ := obj["code"].(json.String)
	if name == "" do return {}, false
	code, _ := error_code_parse(name)
	err.code = code
	err.class = error_code_class(code)
	if class_name, is_str := obj["class"].(json.String); is_str {
		if class, class_ok := error_class_parse(class_name); class_ok do err.class = class
	}
	if s, is_str := obj["cause"].(json.String); is_str do err.cause = strings.clone(s, allocator)
	if s, is_str := obj["message"].(json.String); is_str do err.message = strings.clone(s, allocator)
	if s, is_str := obj["scope"].(json.String); is_str do err.scope = strings.clone(s, allocator)
	#partial switch n in obj["retry_after_ms"] {
	case json.Integer: err.retry_after_ms = i64(n)
	case json.Float:   err.retry_after_ms = i64(n)
	}
	return err, true
}
