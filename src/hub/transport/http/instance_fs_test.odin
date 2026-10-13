package http

// Unit tests for the agent run-dir (instance-scoped) FS command wire contract.
// instance_fs_command_json is pure, so these lock the JSON the hub relays to the
// bridge without needing a live bridge/registry. The owner/online guards in
// instance_fs_relay reuse the same primitives as project_fs_relay
// (agent_service.get_instance = same-owner scoped; bridge_service.get_bridge =
// owner-scoped; bridge_runtime_registry_has_live for online), which are covered by
// the agent/bridge service tests.

import "core:strings"
import "core:testing"

@(test)
test_instance_fs_list_command_json_contract :: proc(t: ^testing.T) {
	cmd := Instance_Fs_Command{
		command_type = "agent_run_dir_list",
		path = "skills",
		include_hidden = true, send_include_hidden = true,
		cursor = "abc",
		limit = 200, send_limit = true,
	}
	out := instance_fs_command_json(cmd, "cmd_ifs_1", "inst_123")
	testing.expect(t, strings.contains(out, "\"type\":\"agent_run_dir_list\""), "type present")
	testing.expect(t, strings.contains(out, "\"command_id\":\"cmd_ifs_1\""), "command_id present")
	testing.expect(t, strings.contains(out, "\"instance_id\":\"inst_123\""), "instance_id present")
	testing.expect(t, strings.contains(out, "\"path\":\"skills\""), "path present")
	testing.expect(t, strings.contains(out, "\"include_hidden\":true"), "include_hidden emitted")
	testing.expect(t, strings.contains(out, "\"cursor\":\"abc\""), "cursor present")
	testing.expect(t, strings.contains(out, "\"limit\":200"), "limit present")
}

@(test)
test_instance_fs_read_command_json_contract :: proc(t: ^testing.T) {
	cmd := Instance_Fs_Command{
		command_type = "agent_run_dir_read",
		path = "AGENTS.md",
		offset = 16000, send_offset = true,
		read_limit = 16000, send_read_limit = true,
	}
	out := instance_fs_command_json(cmd, "cmd_ifs_2", "inst_456")
	testing.expect(t, strings.contains(out, "\"type\":\"agent_run_dir_read\""), "type present")
	testing.expect(t, strings.contains(out, "\"instance_id\":\"inst_456\""), "instance_id present")
	testing.expect(t, strings.contains(out, "\"path\":\"AGENTS.md\""), "path present")
	testing.expect(t, strings.contains(out, "\"offset\":16000"), "offset present")
	testing.expect(t, strings.contains(out, "\"limit\":16000"), "read limit present")
	// A read command must not emit list-only keys.
	testing.expect(t, !strings.contains(out, "\"include_hidden\""), "no include_hidden on read")
	testing.expect(t, !strings.contains(out, "\"cursor\""), "no cursor on read")
}

@(test)
test_instance_fs_list_command_json_omits_unset_optionals :: proc(t: ^testing.T) {
	// Zero-value list command (no hidden/cursor/limit): only the always-on fields.
	cmd := Instance_Fs_Command{command_type = "agent_run_dir_list"}
	out := instance_fs_command_json(cmd, "cmd_ifs_3", "inst_789")
	testing.expect(t, strings.contains(out, "\"path\":\"\""), "empty path still emitted")
	testing.expect(t, !strings.contains(out, "\"include_hidden\""), "omit include_hidden when unset")
	testing.expect(t, !strings.contains(out, "\"cursor\""), "omit cursor when empty")
	testing.expect(t, !strings.contains(out, "\"limit\""), "omit limit when unset")
}
