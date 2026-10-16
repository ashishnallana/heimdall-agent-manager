package contracts

import "core:strings"
import "core:testing"

@(test)
test_error_code_table_names_round_trip :: proc(t: ^testing.T) {
	table := ERROR_CODE_TABLE
	for info, code in table {
		if code == .None {
			testing.expect_value(t, info.name, "")
			continue
		}
		testing.expectf(t, info.name != "", "%v has no wire name", code)
		testing.expectf(t, info.http_status >= 400, "%v http %d", code, info.http_status)
		got, ok := error_code_parse(info.name)
		testing.expectf(t, ok && got == code, "%s parses to %v", info.name, got)
	}
	_, ok := error_code_parse("no_such_code")
	testing.expect(t, !ok)
}

@(test)
test_error_code_table_keeps_existing_http_statuses :: proc(t: ^testing.T) {
	testing.expect_value(t, error_code_http_status(.Vault_Locked), 423)
	testing.expect_value(t, error_code_http_status(.Bridge_Busy), 503)
	testing.expect_value(t, error_code_http_status(.Bridge_Offline), 409)
	testing.expect_value(t, error_code_class(.Bridge_Busy), Bridge_Error_Class.retriable)
	testing.expect_value(t, error_code_class(.Vault_Locked), Bridge_Error_Class.recoverable)
	testing.expect_value(t, error_code_class(.Validation_Failed), Bridge_Error_Class.fatal)
}

@(test)
test_wire_error_round_trip :: proc(t: ^testing.T) {
	w := wire_error_from_bridge(.provider_not_logged_in, .recoverable, "claude: \"login\" required", 1500, "agent")
	body := strings.concatenate({"{\"type\":\"command_result\",\"ok\":false,\"error\":", wire_error_json(w, context.temp_allocator), "}"}, context.temp_allocator)
	got, found := wire_error_parse(body, context.temp_allocator)
	testing.expect(t, found)
	testing.expect_value(t, got.code, Error_Code.Provider_Unavailable)
	testing.expect_value(t, got.class, Bridge_Error_Class.recoverable)
	testing.expect_value(t, got.cause, "provider_not_logged_in")
	testing.expect_value(t, got.message, "claude: \"login\" required")
	testing.expect_value(t, got.retry_after_ms, i64(1500))
	testing.expect_value(t, got.scope, "agent")
}

@(test)
test_wire_error_parse_reads_top_level_only :: proc(t: ^testing.T) {
	// A failed batch item must not fail the whole frame.
	_, found := wire_error_parse(`{"ok":true,"result":{"errors":[{"error":{"code":"bridge_timeout"}}]}}`, context.temp_allocator)
	testing.expect(t, !found)
	_, found = wire_error_parse(`{"ok":true,"error":{"code":""}}`, context.temp_allocator)
	testing.expect(t, !found)
	_, found = wire_error_parse(`not json`, context.temp_allocator)
	testing.expect(t, !found)
}

@(test)
test_wire_error_parse_unknown_code_and_class :: proc(t: ^testing.T) {
	got, found := wire_error_parse(`{"error":{"code":"from_the_future","class":"sideways"}}`, context.temp_allocator)
	testing.expect(t, found)
	testing.expect_value(t, got.code, Error_Code.Internal_Error)
	testing.expect_value(t, got.class, error_code_class(.Internal_Error))
	got, _ = wire_error_parse(`{"error":{"code":"internal_error","class":"fatal"}}`, context.temp_allocator)
	testing.expect_value(t, got.class, Bridge_Error_Class.fatal)
}

@(test)
test_api_error_json_carries_class_and_cause :: proc(t: ^testing.T) {
	body := api_error_json(API_Error{code = "vault_locked", message = "m", class = "recoverable", cause = "vault_locked"}, api_meta("req", ""))
	defer delete(body)
	got, found := wire_error_parse(body, context.temp_allocator)
	testing.expect(t, found)
	testing.expect_value(t, got.code, Error_Code.Vault_Locked)
	testing.expect_value(t, got.class, Bridge_Error_Class.recoverable)
	testing.expect_value(t, got.cause, "vault_locked")
}
