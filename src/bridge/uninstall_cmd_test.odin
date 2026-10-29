package main

import "core:testing"

// The hub's remote uninstall frame is a known, queued, exclusive bridge command
// serialized with updates (never run concurrently with one).
@(test)
test_bridge_uninstall_frame_is_registered :: proc(t: ^testing.T) {
	spec, ok := bridge_command_spec("bridge_uninstall")
	testing.expect(t, ok, "bridge_uninstall is a known command")
	testing.expect_value(t, spec.class, Bridge_Command_Class.Exclusive)
	testing.expect(t, spec.requires_id, "needs a command id to ack")
	testing.expect(t, bridge_command_may_spawn_process("bridge_uninstall"), "spawns the detached uninstall")
	key := bridge_command_ordering_key("bridge_uninstall", `{"type":"bridge_uninstall"}`)
	defer delete(key)
	testing.expect_value(t, key, "bridge-update")
}
