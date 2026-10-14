package http

import "core:testing"

@(test)
task_chain_search_relay_command_preserves_opaque_envelope_and_correlation :: proc(t: ^testing.T) {
	envelope := `search:v1:AA+/opaque==`
	body := task_chain_search_command_json("cmd_one", "brg_one", "usr_one", "req_one", 1900000000000, envelope)
	defer delete(body)
	testing.expect_value(t, json_string(body, "type", context.temp_allocator), "task_chain_search")
	testing.expect_value(t, json_string(body, "command_id", context.temp_allocator), "cmd_one")
	testing.expect_value(t, json_string(body, "bridge_id", context.temp_allocator), "brg_one")
	testing.expect_value(t, json_string(body, "owner_user_id", context.temp_allocator), "usr_one")
	testing.expect_value(t, json_string(body, "request_id", context.temp_allocator), "req_one")
	testing.expect_value(t, json_string(body, "envelope", context.temp_allocator), envelope)
	testing.expect_value(t, json_int(body, "expires_at_ms", 0), 1900000000000)
}
