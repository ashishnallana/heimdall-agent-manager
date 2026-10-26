package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

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

test_install_mu: sync.Mutex
test_install_calls: [dynamic][]string
test_install_failure_step: int
test_install_already: bool
test_install_probe_state: string
test_install_probe_version: string
test_install_probe_count: int
// The discovery before any installer step sees the pre-install registration.
test_install_pre_state: string
test_install_pre_version: string
test_install_command_id: string
test_install_test: ^testing.T

test_install_runner :: proc(args: []string, timeout: time.Duration) -> (stdout, stderr: string, exit_code: int, ok, timed_out: bool) {
	copied := make([]string, len(args), context.temp_allocator)
	for arg, i in args do copied[i] = strings.clone(arg, context.temp_allocator)
	append(&test_install_calls, copied)
	testing.expect(test_install_test, timeout > 0 && timeout <= 25 * time.Second)
	if len(test_install_calls) == test_install_failure_step {
		return strings.clone(""), strings.clone("Mock installation error"), 1, false, false
	}
	if test_install_already && args[2] == "install" {
		return strings.clone("ALREADY INSTALLED"), strings.clone(""), 0, true, false
	}
	return strings.clone("Installed"), strings.clone(""), 0, true, false
}

test_install_discover :: proc(filter: []string) -> [dynamic]Bridge_Provider_Path {
	test_install_probe_count += 1
	cached, _ := bridge_runtime_cached_command(test_install_command_id)
	testing.expect(test_install_test, !strings.contains(cached, `"status":"succeeded"`), "success must not be cached before verification")
	pre_install := test_install_probe_count == 1
	results := make([dynamic]Bridge_Provider_Path)
	append(&results, Bridge_Provider_Path{
		provider = strings.clone(filter[0]),
		state = strings.clone("present"),
		extension_state = strings.clone(test_install_pre_state if pre_install else test_install_probe_state),
		extension_version = strings.clone(test_install_pre_version if pre_install else test_install_probe_version),
	})
	return results
}

test_install_fixture :: proc(t: ^testing.T) -> string {
	root := fmt.tprintf("%s/test-install-%p-%d", bridge_scratch_root(context.temp_allocator), t, time.to_unix_nanoseconds(time.now()))
	for dir in ([]string{"", "codex", "codex/.codex-plugin", "antigravity", "claude-code", "claude-code/.claude-plugin", ".agents/plugins", ".claude-plugin"}) {
		testing.expect(t, bridge_make_directory_all(test_install_path({root, dir})) == nil)
	}
	for file in ([]string{"codex/.codex-plugin/plugin.json", "claude-code/.claude-plugin/plugin.json", "antigravity/plugin.json"}) {
		testing.expect(t, os.write_entire_file_from_string(test_install_path({root, file}), `{"version":"0.4.31"}`) == nil)
	}
	for file in ([]string{".agents/plugins/marketplace.json", ".claude-plugin/marketplace.json"}) {
		testing.expect(t, os.write_entire_file_from_string(test_install_path({root, file}), "{}") == nil)
	}
	return root
}

test_install_reset :: proc(t: ^testing.T, name: string) {
	test_install_test = t
	test_install_command_id = fmt.tprintf("install-%s-%p-%d", name, t, time.to_unix_nanoseconds(time.now()))
	test_install_calls = make([dynamic][]string, context.temp_allocator)
	test_install_failure_step = 0
	test_install_already = false
	test_install_probe_state = "present"
	test_install_probe_version = "0.4.31"
	test_install_probe_count = 0
	test_install_pre_state = "absent"
	test_install_pre_version = ""
}

test_install_run :: proc(provider, path: string) -> string {
	payload := fmt.tprintf(`{{"type":"provider_extension_install","command_id":"%s","provider":"%s","binary_path":"/fake/provider","extension_path":"%s"}}`, test_install_command_id, provider, path)
	bridge_hub_handle_extension_install_command(nil, payload)
	result, ok := bridge_runtime_cached_command(test_install_command_id)
	testing.expect(test_install_test, ok)
	return strings.clone(result)
}

@(test)
test_bridge_extension_install_provider_steps :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_install_mu)
	defer sync.mutex_unlock(&test_install_mu)
	runner, discover := bridge_extension_install_runner, bridge_extension_discover
	defer { bridge_extension_install_runner = runner; bridge_extension_discover = discover }
	bridge_extension_install_runner = test_install_runner
	bridge_extension_discover = test_install_discover
	root := test_install_fixture(t)
	defer _ = os.remove_all(root)
	for provider in ([]string{"antigravity", "claude", "claude-code", "codex"}) {
		test_install_reset(t, provider)
		variant := "claude-code" if provider == "claude" else provider
		result := test_install_run(provider, test_install_path({root, variant}))
		testing.expectf(t, strings.contains(result, `"status":"succeeded"`), "%s: %s", provider, result)
		delete(result)
		testing.expect_value(t, test_install_probe_count, 2)
		if provider == "codex" {
			testing.expect_value(t, len(test_install_calls), 2)
			if len(test_install_calls) == 2 {
				testing.expect_value(t, test_install_calls[0][2], "marketplace")
				testing.expect_value(t, test_install_calls[0][4], root)
				testing.expect_value(t, test_install_calls[1][2], "add")
			}
		} else {
			testing.expect_value(t, len(test_install_calls), 1)
		}
	}
}

@(test)
test_bridge_extension_install_rejects_unverified_results :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_install_mu)
	defer sync.mutex_unlock(&test_install_mu)
	runner, discover := bridge_extension_install_runner, bridge_extension_discover
	defer { bridge_extension_install_runner = runner; bridge_extension_discover = discover }
	bridge_extension_install_runner = test_install_runner
	bridge_extension_discover = test_install_discover
	root := test_install_fixture(t)
	defer _ = os.remove_all(root)
	for state in ([]string{"absent", "disabled", "outdated", "error", "unsupported", "present"}) {
		test_install_reset(t, state)
		test_install_probe_state = state
		test_install_probe_version = "0.1.0" if state == "present" else "0.4.31"
		result := test_install_run("antigravity", test_install_path({root, "antigravity"}))
		testing.expect(t, strings.contains(result, `"status":"failed"`))
		testing.expect(t, strings.contains(result, "verify_failed"))
		delete(result)
	}
	test_install_reset(t, "unknown-version")
	test_install_probe_version = ""
	result := test_install_run("antigravity", test_install_path({root, "antigravity"}))
	testing.expect(t, strings.contains(result, "verify_failed"))
	delete(result)
}

@(test)
test_bridge_extension_install_claude_update_and_errors :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_install_mu)
	defer sync.mutex_unlock(&test_install_mu)
	runner, discover := bridge_extension_install_runner, bridge_extension_discover
	defer { bridge_extension_install_runner = runner; bridge_extension_discover = discover }
	bridge_extension_install_runner = test_install_runner
	bridge_extension_discover = test_install_discover
	root := test_install_fixture(t)
	defer _ = os.remove_all(root)
	for failed_step in 0..=2 {
		test_install_reset(t, fmt.tprintf("claude-%d", failed_step))
		test_install_already = true
		test_install_failure_step = failed_step
		result := test_install_run("claude", test_install_path({root, "claude-code"}))
		if failed_step == 0 {
			testing.expect(t, strings.contains(result, `"status":"succeeded"`))
			testing.expect_value(t, test_install_probe_count, 2)
		} else {
			testing.expect(t, strings.contains(result, "Mock installation error"))
			testing.expect_value(t, test_install_probe_count, 1)
		}
		delete(result)
		if failed_step != 1 && len(test_install_calls) == 2 {
			testing.expect_value(t, test_install_calls[1][2], "update")
		}
	}
	for failed_step in 1..=2 {
		test_install_reset(t, fmt.tprintf("codex-%d", failed_step))
		test_install_failure_step = failed_step
		result := test_install_run("codex", test_install_path({root, "codex"}))
		testing.expect(t, strings.contains(result, "Mock installation error"))
		testing.expect_value(t, len(test_install_calls), failed_step)
		testing.expect_value(t, test_install_probe_count, 1)
		delete(result)
	}
}

@(test)
test_bridge_extension_install_custom_marketplace_and_invalid_input :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_install_mu)
	defer sync.mutex_unlock(&test_install_mu)
	runner, discover := bridge_extension_install_runner, bridge_extension_discover
	defer { bridge_extension_install_runner = runner; bridge_extension_discover = discover }
	bridge_extension_install_runner = test_install_runner
	bridge_extension_discover = test_install_discover
	root := test_install_fixture(t)
	defer _ = os.remove_all(root)
	test_install_reset(t, "codex-root")
	result := test_install_run("codex", root)
	testing.expect(t, strings.contains(result, `"status":"succeeded"`))
	delete(result)
	if len(test_install_calls) > 0 do testing.expect_value(t, test_install_calls[0][4], root)
	_ = os.remove(test_install_path({root, ".agents/plugins/marketplace.json"}))
	test_install_reset(t, "missing-marketplace")
	result = test_install_run("codex", root)
	testing.expect(t, strings.contains(result, "missing_marketplace"))
	testing.expect_value(t, len(test_install_calls), 0)
	delete(result)
	for provider in ([]string{"", "unsupported"}) {
		test_install_reset(t, "invalid")
		result = test_install_run(provider, root)
		testing.expect(t, strings.contains(result, `"status":"failed"`))
		testing.expect_value(t, len(test_install_calls), 0)
		delete(result)
	}
	test_install_reset(t, "expired")
	_, _, ok := bridge_extension_install_step({"/fake/provider"}, time.time_add(time.now(), -time.Second))
	testing.expect(t, !ok)
	testing.expect_value(t, len(test_install_calls), 0)
}

@(test)
test_bridge_extension_install_never_downgrades_registration :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_install_mu)
	defer sync.mutex_unlock(&test_install_mu)
	runner, discover := bridge_extension_install_runner, bridge_extension_discover
	defer { bridge_extension_install_runner = runner; bridge_extension_discover = discover }
	bridge_extension_install_runner = test_install_runner
	bridge_extension_discover = test_install_discover
	root := test_install_fixture(t)
	defer _ = os.remove_all(root)
	// The fixture bundles 0.4.31; another Bridge on the same OS user registered pre_version.
	Case :: struct { pre_version: string, skips: bool }
	cases := []Case{
		{"0.4.31", true}, {"v0.4.31", true}, {"0.4.32", true}, {"0.10.0", true}, {"1.0.0", true},
		{"0.4.30", false}, {"0.4.9", false}, {"0.3.99", false},
	}
	for provider in ([]string{"antigravity", "claude", "claude-code", "codex"}) {
		variant := "claude-code" if provider == "claude" else provider
		for c in cases {
			test_install_reset(t, fmt.tprintf("%s-%s", provider, c.pre_version))
			test_install_pre_state = "present"
			test_install_pre_version = c.pre_version
			result := test_install_run(provider, test_install_path({root, variant}))
			testing.expectf(t, strings.contains(result, `"status":"succeeded"`), "%s %s: %s", provider, c.pre_version, result)
			delete(result)
			if c.skips {
				testing.expectf(t, len(test_install_calls) == 0, "%s %s: registration re-pointed by %d installer calls", provider, c.pre_version, len(test_install_calls))
				testing.expect_value(t, test_install_probe_count, 1)
				continue
			}
			testing.expect_value(t, test_install_probe_count, 2)
			if provider == "codex" {
				testing.expectf(t, len(test_install_calls) == 2 && test_install_calls[0][3] == "add" && test_install_calls[0][4] == root,
					"%s %s: older registration must be re-pointed", provider, c.pre_version)
			} else {
				testing.expectf(t, len(test_install_calls) == 1 && test_install_calls[0][2] == "install",
					"%s %s: older registration must be upgraded", provider, c.pre_version)
			}
		}
	}
	// An unusable registration at a current version is still repaired, and an
	// unknown installed version never counts as current.
	for state in ([]string{"disabled", "outdated", "error", "absent", "unknown-version"}) {
		test_install_reset(t, state)
		test_install_pre_state = "present" if state == "unknown-version" else state
		test_install_pre_version = "" if state == "unknown-version" else "0.5.0"
		result := test_install_run("claude", test_install_path({root, "claude-code"}))
		testing.expectf(t, strings.contains(result, `"status":"succeeded"`), "%s: %s", state, result)
		delete(result)
		testing.expectf(t, len(test_install_calls) == 1, "%s: expected one install call, got %d", state, len(test_install_calls))
		testing.expect_value(t, test_install_probe_count, 2)
	}
	// A failed upgrade of an older registration still reports the failure.
	test_install_reset(t, "older-fails")
	test_install_pre_state = "present"
	test_install_pre_version = "0.4.0"
	test_install_failure_step = 1
	result := test_install_run("antigravity", test_install_path({root, "antigravity"}))
	testing.expect(t, strings.contains(result, "Mock installation error"))
	delete(result)
}

test_install_path :: proc(parts: []string) -> string {
	path, _ := filepath.join(parts, context.temp_allocator)
	return path
}
