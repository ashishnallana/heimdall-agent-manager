package main

import "core:strings"
import "core:testing"

// REQ-EXT-PERM-2: the wake/scheduler synthetic launch forwards the hub's
// permission_mode so bridge_runtime_launch_agent can drop the yolo flags.

@(test)
wake_launch_command_json_forwards_permission_mode :: proc(t: ^testing.T) {
	cmd := bridge_wake_launch_command_json("cmd_1", "inst_a", "task_1", "worker", "claude", "opus", "agt_1", "coder", "chain_1", "C", "", "proj_1", "/p", "", "", "", "ask")
	defer delete(cmd)
	mode := extract_json_string(cmd, "permission_mode", "")
	defer delete(mode)
	testing.expect_value(t, mode, "ask")
}

@(test)
wake_launch_command_json_omits_absent_permission_mode :: proc(t: ^testing.T) {
	// An older hub sends none: the key stays absent and the launch stays yolo.
	cmd := bridge_wake_launch_command_json("cmd_2", "inst_b", "task_2", "worker", "claude", "opus", "agt_1", "coder", "chain_1", "C", "", "proj_1", "/p")
	defer delete(cmd)
	testing.expect(t, !strings.contains(cmd, "permission_mode"), "no permission_mode key without a hub value")
}
