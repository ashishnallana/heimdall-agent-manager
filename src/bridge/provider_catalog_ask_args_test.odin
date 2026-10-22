package main

import "core:encoding/json"
import "core:slice"
import "core:testing"
import agent_runtime "odin_test:lib/agent_runtime"

// iss_18e0ce7cfaf1d3a3: catalog ask_args (Hub migration 109) must reach the
// launch command for permission_mode 'ask', in place of yolo_args.
@(test)
test_provider_catalog_ask_args_reach_ask_launch :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	claude: Bridge_Catalog_Provider
	err := json.unmarshal_string(
		`{"provider":"claude","binary":"claude","base_args":[],"yolo_args":["--dangerously-skip-permissions"],"ask_args":["--permission-mode","default"],"model_flag":"--model","state":"active"}`,
		&claude,
	)
	testing.expect(t, err == nil)
	testing.expect(t, slice.equal(claude.ask_args, []string{"--permission-mode", "default"}), "ask_args parsed from the catalog")

	profile := bridge_agent_runtime_profile(bridge_provider_profile_from_catalog(claude))
	ask := agent_runtime.build_agent_command(profile, "opus", "", "tok", "inst_1", agent_runtime.PERMISSION_MODE_ASK)
	testing.expect(t, slice.equal(ask, []string{"--permission-mode", "default", "--model", "opus"}), "ask launch carries ask_args and no yolo_args")
	yolo := agent_runtime.build_agent_command(profile, "opus", "", "tok", "inst_1", agent_runtime.PERMISSION_MODE_YOLO)
	testing.expect(t, slice.equal(yolo, []string{"--dangerously-skip-permissions", "--model", "opus"}), "yolo launch carries yolo_args and no ask_args")
}

@(test)
test_provider_catalog_without_ask_args_omits_yolo_only :: proc(t: ^testing.T) {
	// A Hub that predates migration 109 sends no ask_args key.
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	codex: Bridge_Catalog_Provider
	err := json.unmarshal_string(
		`{"provider":"codex","binary":"codex","yolo_args":["--yolo"],"model_flag":"-m","state":"active"}`,
		&codex,
	)
	testing.expect(t, err == nil)
	testing.expect_value(t, len(codex.ask_args), 0)
	profile := bridge_agent_runtime_profile(bridge_provider_profile_from_catalog(codex))
	argv := agent_runtime.build_agent_command(profile, "gpt", "", "tok", "inst_1", agent_runtime.PERMISSION_MODE_ASK)
	testing.expect(t, slice.equal(argv, []string{"-m", "gpt"}), "ask launch without ask_args drops only yolo_args")
}
