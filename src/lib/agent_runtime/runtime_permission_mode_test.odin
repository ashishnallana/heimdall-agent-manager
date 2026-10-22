package agent_runtime

import "core:slice"
import "core:testing"

// REQ-EXT-PERM-2: a per-agent permission mode decides whether the catalog yolo
// flags reach the provider command line.

@(private = "file") permission_test_command := [?]string{"/usr/bin/claude"}
@(private = "file") permission_test_base_args := [?]string{"--verbose"}
@(private = "file") permission_test_yolo_flags := [?]string{"--dangerously-skip-permissions"}
@(private = "file") permission_test_prompt_flags := [?]string{"--"}

@(private = "file")
permission_test_profile :: proc() -> Agent_Profile {
	return Agent_Profile{
		command = permission_test_command[:],
		base_args = permission_test_base_args[:],
		yolo_flags = permission_test_yolo_flags[:],
		model_flag = "--model",
		prompt_delivery = "none",
	}
}

@(test)
test_build_agent_command_yolo_mode_keeps_yolo_flags :: proc(t: ^testing.T) {
	argv := build_agent_command(permission_test_profile(), "opus", "", "tok", "inst_1", PERMISSION_MODE_YOLO)
	defer delete(argv)
	testing.expect(t, slice.equal(argv, []string{"/usr/bin/claude", "--verbose", "--dangerously-skip-permissions", "--model", "opus"}), "yolo launch must keep the catalog yolo flags")
}

@(test)
test_build_agent_command_ask_mode_omits_yolo_flags :: proc(t: ^testing.T) {
	argv := build_agent_command(permission_test_profile(), "opus", "", "tok", "inst_1", PERMISSION_MODE_ASK)
	defer delete(argv)
	testing.expect(t, slice.equal(argv, []string{"/usr/bin/claude", "--verbose", "--model", "opus"}), "ask launch must drop only the yolo flags")
}

@(test)
test_build_agent_command_default_and_unknown_modes_stay_yolo :: proc(t: ^testing.T) {
	// Older hubs send no permission_mode: the launch must not change for them.
	modes := []string{"", "  ", "bogus", "ASK"}
	for mode in modes {
		argv := build_agent_command(permission_test_profile(), "opus", "", "tok", "inst_1", mode)
		testing.expectf(t, slice.contains(argv, "--dangerously-skip-permissions"), "mode %q must keep the yolo flags", mode)
		delete(argv)
	}
	argv := build_agent_command(permission_test_profile(), "opus", "", "tok", "inst_1")
	defer delete(argv)
	testing.expect(t, slice.contains(argv, "--dangerously-skip-permissions"), "omitted mode must default to yolo")
}

@(test)
test_build_agent_command_ask_mode_keeps_prompt_injection :: proc(t: ^testing.T) {
	// render_starter_prompt_for_agent builds its string in place; keep it off the tracked heap.
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	profile := permission_test_profile()
	profile.prompt_delivery = "flag-injection"
	profile.prompt_flags = permission_test_prompt_flags[:]
	profile.starter_prompt = "hello"
	argv := build_agent_command(profile, "opus", "", "tok", "inst_1", PERMISSION_MODE_ASK)
	testing.expect(t, !slice.contains(argv, "--dangerously-skip-permissions"), "ask launch must not carry yolo flags")
	testing.expect(t, len(argv) == 6 && argv[4] == "--", "ask launch must still inject the starter prompt")
}
