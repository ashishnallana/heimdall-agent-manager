package agent

import "core:strings"
import "core:testing"

// REQ-37: wake_agent_command_json must serialize the enriched descriptor fields so
// the bridge's wake path forms the full (agent_id, role, provider, project) bootstrap
// key and renders the complete template instead of the header-only fallback.

@(test)
wake_agent_command_json_includes_enriched_descriptor :: proc(t: ^testing.T) {
	run := []Wake_Agent_Run_Entry{
		{
			agent_instance_id = "inst_1",
			task_id           = "task_1",
			role              = "worker",
			provider          = "pi",
			model              = "smart",
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
wake_agent_command_json_omits_empty_enriched_fields :: proc(t: ^testing.T) {
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
wake_agent_command_json_carries_command_id :: proc(t: ^testing.T) {
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
