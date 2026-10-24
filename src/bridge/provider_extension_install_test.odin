package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import ws "odin_test:lib/ws"

@(test)
test_provider_extension_install_progress_json_format :: proc(t: ^testing.T) {
	frame_installing := bridge_provider_extension_install_progress_json(
		"cmd_test_1",
		"antigravity",
		"installing",
		25,
		"Downloading assets",
	)
	defer delete(frame_installing)

	testing.expect(t, strings.contains(frame_installing, `"type":"provider_extension_install_progress"`), "type is provider_extension_install_progress")
	testing.expect(t, strings.contains(frame_installing, `"command_id":"cmd_test_1"`), "command_id is correct")
	testing.expect(t, strings.contains(frame_installing, `"provider":"antigravity"`), "provider is correct")
	testing.expect(t, strings.contains(frame_installing, `"stage":"installing"`), "stage is installing")
	testing.expect(t, strings.contains(frame_installing, `"progress_percent":25`), "progress_percent is 25")
	testing.expect(t, strings.contains(frame_installing, `"message":"Downloading assets"`), "message is correct")
	testing.expect(t, !strings.contains(frame_installing, `"error"`), "installing stage does not have error")

	frame_succeeded := bridge_provider_extension_install_progress_json(
		"cmd_test_2",
		"antigravity",
		"succeeded",
		100,
		"Installed",
	)
	defer delete(frame_succeeded)
	testing.expect(t, strings.contains(frame_succeeded, `"stage":"succeeded"`), "stage is succeeded")
	testing.expect(t, strings.contains(frame_succeeded, `"progress_percent":100`), "progress_percent is 100")

	frame_failed := bridge_provider_extension_install_progress_json(
		"cmd_test_3",
		"antigravity",
		"failed",
		0,
		"Binary missing",
	)
	defer delete(frame_failed)
	testing.expect(t, strings.contains(frame_failed, `"stage":"failed"`), "stage is failed")
	testing.expect(t, strings.contains(frame_failed, `"error"`), "failed stage includes error object")
	testing.expect(t, strings.contains(frame_failed, `"Binary missing"`), "error message is preserved")
}

@(test)
test_provider_extension_build_install_args :: proc(t: ^testing.T) {
	// 1. Antigravity
	agy_args := bridge_provider_extension_build_install_args("antigravity", "/bin/agy", "/path/to/extensions/antigravity", context.allocator)
	defer delete(agy_args)
	testing.expect_value(t, len(agy_args), 4)
	if len(agy_args) == 4 {
		testing.expect_value(t, agy_args[0], "/bin/agy")
		testing.expect_value(t, agy_args[1], "plugin")
		testing.expect_value(t, agy_args[2], "install")
		testing.expect_value(t, agy_args[3], "/path/to/extensions/antigravity")
	}

	// 2. Claude with marketplace file
	root := bridge_scratch_root(context.temp_allocator)
	test_dir := fmt.aprintf("%s/test_claude_mp_%d", root, time.to_unix_nanoseconds(time.now()))
	defer {
		_ = os.remove_all(test_dir)
		delete(test_dir)
	}
	mp_dir, _ := filepath.join({test_dir, ".claude-plugin"}, context.temp_allocator)
	testing.expect(t, bridge_make_directory_all(mp_dir) == nil, "mkdir mp_dir")
	mp_file, _ := filepath.join({mp_dir, "marketplace.json"}, context.temp_allocator)
	_ = os.write_entire_file_from_string(mp_file, "{}")
	claude_ext, _ := filepath.join({test_dir, "claude-code"}, context.temp_allocator)
	testing.expect(t, bridge_make_directory_all(claude_ext) == nil, "mkdir claude_ext")

	claude_args := bridge_provider_extension_build_install_args("claude", "/bin/claude", claude_ext, context.allocator)
	defer delete(claude_args)
	testing.expect_value(t, len(claude_args), 7)
	if len(claude_args) == 7 {
		testing.expect_value(t, claude_args[0], "/bin/claude")
		testing.expect_value(t, claude_args[1], "plugin")
		testing.expect_value(t, claude_args[2], "install")
		testing.expect_value(t, claude_args[3], "--marketplace")
		testing.expect_value(t, claude_args[4], test_dir)
		testing.expect_value(t, claude_args[5], "heimdall")
		testing.expect_value(t, claude_args[6], "-y")
	}

	// 3. Codex
	codex_args := bridge_provider_extension_build_install_args("codex", "/bin/codex", "/path/to/extensions/codex", context.allocator)
	defer delete(codex_args)
	testing.expect_value(t, len(codex_args), 4)
	if len(codex_args) == 4 {
		testing.expect_value(t, codex_args[0], "/bin/codex")
		testing.expect_value(t, codex_args[1], "plugin")
		testing.expect_value(t, codex_args[2], "add")
		testing.expect_value(t, codex_args[3], "heimdall@heimdall-codex")
	}
}

@(private="file")
test_mock_runner_executed_args: [dynamic]string
@(private="file")
test_mock_runner_should_succeed: bool

@(private="file")
test_mock_install_runner :: proc(args: []string, timeout: time.Duration) -> (stdout, stderr: string, exit_code: int, ok, timed_out: bool) {
	for arg in args {
		append(&test_mock_runner_executed_args, strings.clone(arg))
	}
	if test_mock_runner_should_succeed {
		return strings.clone("Plugin installed"), strings.clone(""), 0, true, false
	} else {
		return strings.clone(""), strings.clone("Mock installation error"), 1, false, false
	}
}

@(test)
test_bridge_hub_handle_extension_install_success :: proc(t: ^testing.T) {
	orig_runner := bridge_extension_install_runner
	defer {
		bridge_extension_install_runner = orig_runner
		for arg in test_mock_runner_executed_args do delete(arg)
		delete(test_mock_runner_executed_args)
	}
	bridge_extension_install_runner = test_mock_install_runner
	test_mock_runner_should_succeed = true

	conn: ws.Connection
	cmd_id := "cmd_test_inst_ok_123"
	payload := fmt.tprintf(`{"type":"provider_extension_install","command_id":"%s","provider":"antigravity","binary_path":"/bin/agy"}`, cmd_id)

	bridge_hub_handle_extension_install_command(&conn, payload)

	cached, has_cache := bridge_runtime_cached_command(cmd_id)
	testing.expect(t, has_cache, "command result should be cached")
	testing.expect(t, strings.contains(cached, `"status":"succeeded"`), "status should be succeeded")
	testing.expect(t, strings.contains(cached, `"installed"`), "runtime_status should be installed")
	testing.expect(t, len(test_mock_runner_executed_args) >= 4, "installer should have been executed")
}

@(test)
test_bridge_hub_handle_extension_install_failure :: proc(t: ^testing.T) {
	orig_runner := bridge_extension_install_runner
	defer {
		bridge_extension_install_runner = orig_runner
		for arg in test_mock_runner_executed_args do delete(arg)
		delete(test_mock_runner_executed_args)
	}
	bridge_extension_install_runner = test_mock_install_runner
	test_mock_runner_should_succeed = false

	conn: ws.Connection
	cmd_id := "cmd_test_inst_fail_456"
	payload := fmt.tprintf(`{"type":"provider_extension_install","command_id":"%s","provider":"antigravity","binary_path":"/bin/agy"}`, cmd_id)

	bridge_hub_handle_extension_install_command(&conn, payload)

	cached, has_cache := bridge_runtime_cached_command(cmd_id)
	testing.expect(t, has_cache, "failed command result should be cached")
	testing.expect(t, strings.contains(cached, `"status":"failed"`), "status should be failed")
	testing.expect(t, strings.contains(cached, `"Mock installation error"`), "error message matches")
}

@(test)
test_bridge_hub_handle_extension_install_missing_provider :: proc(t: ^testing.T) {
	conn: ws.Connection
	cmd_id := "cmd_test_inst_no_prov_789"
	payload := fmt.tprintf(`{"type":"provider_extension_install","command_id":"%s"}`, cmd_id)

	bridge_hub_handle_extension_install_command(&conn, payload)

	cached, has_cache := bridge_runtime_cached_command(cmd_id)
	testing.expect(t, has_cache, "missing provider command result should be cached")
	testing.expect(t, strings.contains(cached, `"status":"failed"`), "status should be failed")
	testing.expect(t, strings.contains(cached, `"missing_provider"`), "cause is missing_provider")
}

@(test)
test_bridge_hub_handle_extension_install_missing_extension :: proc(t: ^testing.T) {
	conn: ws.Connection
	cmd_id := "cmd_test_inst_no_ext_101"
	payload := fmt.tprintf(`{"type":"provider_extension_install","command_id":"%s","provider":"nonexistent_provider_xyz"}`, cmd_id)

	bridge_hub_handle_extension_install_command(&conn, payload)

	cached, has_cache := bridge_runtime_cached_command(cmd_id)
	testing.expect(t, has_cache, "missing extension command result should be cached")
	testing.expect(t, strings.contains(cached, `"status":"failed"`), "status should be failed")
	testing.expect(t, strings.contains(cached, `"extension_not_found"`), "cause is extension_not_found")
}
