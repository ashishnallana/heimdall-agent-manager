package agent

import base64 "core:encoding/base64"
import "core:strings"
import "core:testing"
import jsonx "odin_test:lib/jsonx"

@(test)
test_agent_pty_input_command_json_formats_payload :: proc(t: ^testing.T) {
	original := "\x03\x1b[A\"hello\\world\"\n"
	got := agent_pty_input_command_json("cmd_123", "inst_456", original)
	defer delete(got)
	data := jsonx.extract_string(got, "data_b64")
	defer delete(data)
	decoded, err := base64.decode(data)
	defer delete(decoded)
	testing.expect(t, err == nil)
	testing.expect_value(t, string(decoded), original)
	testing.expect(t, strings.contains(got, "\"is_encrypted\":false"))
	testing.expect(t, strings.contains(got, "\"shell_id\":\"inst_456\""))
	testing.expect(t, !strings.contains(got, "agent_instance_id"), "REQ-PTY-NET-3: no duplicated agent_instance_id")
	testing.expect(t, !strings.contains(got, "enc_b64"))
}

@(test)
test_agent_pty_input_command_json_relays_one_ciphertext :: proc(t: ^testing.T) {
	got := agent_pty_input_command_json("cmd_enc", "inst_enc", "", "QUJDREVG")
	defer delete(got)
	testing.expect(t, strings.contains(got, "\"data_b64\":\"QUJDREVG\""))
	testing.expect(t, strings.contains(got, "\"is_encrypted\":true"))
	testing.expect(t, !strings.contains(got, "enc_b64"))
	testing.expect(t, !strings.contains(got, "vault:v1:"))
	testing.expect(t, !strings.contains(got, "\"data\":"))
}

@(test)
test_agent_pty_resize_command_json_formats_payload :: proc(t: ^testing.T) {
	got := agent_pty_resize_command_json("cmd_resize_123", "inst_456", 25, 110)
	defer delete(got)

	testing.expect(t, strings.contains(got, "\"type\":\"shell_pty_resize\"") || strings.contains(got, "\"type\":\"agent_pty_resize\""), "type field must be shell_pty_resize or agent_pty_resize")
	testing.expect(t, strings.contains(got, "\"command_id\":\"cmd_resize_123\""), "command_id must match")
	testing.expect(t, strings.contains(got, "\"shell_id\":\"inst_456\""), "shell_id must match")
	testing.expect(t, strings.contains(got, "\"agent_instance_id\":\"inst_456\""), "agent_instance_id must match")
	testing.expect(t, strings.contains(got, "\"rows\":25"), "rows field must match")
	testing.expect(t, strings.contains(got, "\"cols\":110"), "cols field must match")
}

@(test)
test_agent_pty_resize_command_json_handles_special_characters :: proc(t: ^testing.T) {
	got := agent_pty_resize_command_json("cmd_resize_\"special\"", "inst_\"quoted\"", 30, 80)
	defer delete(got)

	testing.expect(t, strings.contains(got, "\"command_id\":\"cmd_resize_\\\"special\\\"\""), "quotes in command_id must be escaped")
	testing.expect(t, strings.contains(got, "\"agent_instance_id\":\"inst_\\\"quoted\\\"\""), "quotes in instance_id must be escaped")
	testing.expect(t, strings.contains(got, "\"rows\":30"), "rows field must match")
	testing.expect(t, strings.contains(got, "\"cols\":80"), "cols field must match")
}

// REQ-37: wake_agent_command_json must serialize the enriched descriptor fields so
// the bridge's wake path forms the full (agent_id, role, provider, project) bootstrap
// key and renders the complete template instead of the header-only fallback.

@(test)
test_wake_agent_command_json_includes_enriched_descriptor :: proc(t: ^testing.T) {
	run := []Wake_Agent_Run_Entry{
		{
			agent_instance_id = "inst_1",
			task_id           = "task_1",
			role              = "worker",
			provider          = "pi",
			model             = "smart",
			agent_id          = "agt_1",
			agent_name        = "coder",
			chain_id          = "chain_1",
			chain_title       = "My Chain",
			coordinator_id    = "inst_coord",
			project_id        = "proj_1",
			project_path      = "/home/x/proj",
		},
	}
	got := wake_agent_command_json("cmd_x", "chain_1", run, nil)
	defer delete(got)

	for needle in ([]string{
		"\"agent_id\":\"agt_1\"",
		"\"agent_name\":\"coder\"",
		"\"chain_id\":\"chain_1\"",
		"\"chain_title\":\"My Chain\"",
		"\"coordinator_agent_instance_id\":\"inst_coord\"",
		"\"project_id\":\"proj_1\"",
		"\"project_path\":\"/home/x/proj\"",
		"\"agent_instance_id\":\"inst_1\"",
		"\"task_id\":\"task_1\"",
		"\"role\":\"worker\"",
	}) {
		testing.expectf(t, strings.contains(got, needle), "expected wake payload to contain %s; got %s", needle, got)
	}
}

@(test)
test_wake_agent_command_json_omits_empty_enriched_fields :: proc(t: ^testing.T) {
	// Empty enriched fields are omitted (old-bridge compatibility); a bare entry still
	// serializes the required routing keys.
	run := []Wake_Agent_Run_Entry{
		{agent_instance_id = "inst_2", task_id = "task_2", role = "reviewer"},
	}
	got := wake_agent_command_json("cmd_y", "chain_2", run, nil)
	defer delete(got)
	testing.expect(t, strings.contains(got, "\"agent_instance_id\":\"inst_2\""))
	testing.expect(t, strings.contains(got, "\"role\":\"reviewer\""))
	testing.expect(t, !strings.contains(got, "\"agent_id\""))
	testing.expect(t, !strings.contains(got, "\"chain_title\""))
}

@(test)
test_wake_agent_command_json_carries_command_id :: proc(t: ^testing.T) {
	// wake_agent is a queued, id-required command on the bridge; a body without a
	// top-level command_id is rejected with missing_command_id and auto start/stop
	// silently stops working (regression from 551b0ba6).
	got := wake_agent_command_json("cmd_x", "chain_3", nil, []string{"inst_9"})
	defer delete(got)
	testing.expectf(t, strings.has_prefix(got, "{\"type\":\"wake_agent\",\"protocol_version\":1,\"command_id\":\"cmd_x\""), "unexpected wake header: %s", got)
	testing.expect(t, strings.contains(got, "\"command_id\":\"cmd_x\""))
	testing.expect(t, strings.contains(got, "\"protocol_version\":1"))
	testing.expect(t, strings.contains(got, "\"chain_id\":\"chain_3\""))
	testing.expect(t, strings.contains(got, "\"stop\":[\"inst_9\"]"))
}
