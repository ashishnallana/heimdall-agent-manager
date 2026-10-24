package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

test_ctl_install_mu: sync.Mutex
test_ctl_install_calls: [dynamic][]string
test_ctl_install_failure: string
test_ctl_install_already: bool
test_ctl_install_fail_step: int

test_ctl_install_binary :: proc(name: string) -> (string, bool) {
	return strings.clone(fmt.tprintf("/fake/%s", name)), true
}

test_ctl_install_runner :: proc(args: []string, timeout: time.Duration, allocator := context.temp_allocator) -> (stdout, stderr: string, exit_code: int, ok: bool) {
	copied := make([]string, len(args), context.temp_allocator)
	for arg, i in args do copied[i] = strings.clone(arg, context.temp_allocator)
	append(&test_ctl_install_calls, copied)
	if timeout <= 0 || timeout > 25 * time.Second do return "", "invalid timeout", 1, false
	if test_ctl_install_fail_step == len(test_ctl_install_calls) do return "", test_ctl_install_failure, 1, false
	if test_ctl_install_already && args[2] == "install" do return "ALREADY INSTALLED", "", 0, true
	return "Installed", "", 0, true
}

test_ctl_install_fixture :: proc(t: ^testing.T) -> string {
	root := fmt.tprintf("%s/heimdall-ctl-install-%p-%d", os.get_env("HOME", context.temp_allocator), t, time.to_unix_nanoseconds(time.now()))
	err := os.make_directory(root)
	testing.expect(t, err == nil)
	for directory in ([]string{"codex", "antigravity", "claude-code", ".agents", ".agents/plugins", ".claude-plugin"}) {
		mkdir_err := os.make_directory(test_ctl_install_path({root, directory}))
		testing.expect(t, mkdir_err == nil)
	}
	testing.expect(t, os.write_entire_file_from_string(test_ctl_install_path({root, ".agents/plugins/marketplace.json"}), "{}") == nil)
	testing.expect(t, os.write_entire_file_from_string(test_ctl_install_path({root, ".claude-plugin/marketplace.json"}), "{}") == nil)
	return root
}

@(test)
test_ctl_extension_install_provider_steps :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_ctl_install_mu)
	defer sync.mutex_unlock(&test_ctl_install_mu)
	original_runner := ctl_extension_install_runner
	original_binary := ctl_extension_install_resolve_binary
	defer {
		ctl_extension_install_runner = original_runner
		ctl_extension_install_resolve_binary = original_binary
	}
	ctl_extension_install_runner = test_ctl_install_runner
	ctl_extension_install_resolve_binary = test_ctl_install_binary
	root := test_ctl_install_fixture(t)
	defer _ = os.remove_all(root)

	for provider in ([]string{"antigravity", "claude", "claude-code", "codex"}) {
		test_ctl_install_calls = make([dynamic][]string, context.temp_allocator)
		test_ctl_install_fail_step = 0
		test_ctl_install_already = false
		variant := "claude-code" if provider == "claude" else provider
		custom := test_ctl_install_path({root, variant})
		ok, message := ctl_extension_install_local(provider, custom)
		testing.expectf(t, ok, "%s: %s", provider, message)
		if provider == "codex" {
			testing.expect_value(t, len(test_ctl_install_calls), 2)
			if len(test_ctl_install_calls) == 2 {
				testing.expect_value(t, test_ctl_install_calls[0][2], "marketplace")
				testing.expect_value(t, test_ctl_install_calls[0][4], root)
				testing.expect_value(t, test_ctl_install_calls[1][2], "add")
			}
		} else {
			testing.expect_value(t, len(test_ctl_install_calls), 1)
			if len(test_ctl_install_calls) != 1 do continue
			args := test_ctl_install_calls[0]
			testing.expect_value(t, args[2], "install")
			if provider == "antigravity" do testing.expect_value(t, args[3], custom)
			else do testing.expect_value(t, args[4], root)
		}
	}
	// A root override is used directly, not replaced by a bundled marketplace.
	test_ctl_install_calls = make([dynamic][]string, context.temp_allocator)
	ok, _ := ctl_extension_install_local("codex", root)
	testing.expect(t, ok)
	if len(test_ctl_install_calls) > 0 do testing.expect_value(t, test_ctl_install_calls[0][4], root)

	// Missing custom metadata must fail without falling back to the repo.
	test_ctl_install_calls = make([dynamic][]string, context.temp_allocator)
	_ = os.remove(test_ctl_install_path({root, ".agents/plugins/marketplace.json"}))
	ok, _ = ctl_extension_install_local("codex", root)
	testing.expect(t, !ok)
	testing.expect_value(t, len(test_ctl_install_calls), 0)
}

@(test)
test_ctl_extension_install_errors_and_update :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_ctl_install_mu)
	defer sync.mutex_unlock(&test_ctl_install_mu)
	original_runner := ctl_extension_install_runner
	original_binary := ctl_extension_install_resolve_binary
	defer {
		ctl_extension_install_runner = original_runner
		ctl_extension_install_resolve_binary = original_binary
	}
	ctl_extension_install_runner = test_ctl_install_runner
	ctl_extension_install_resolve_binary = test_ctl_install_binary
	root := test_ctl_install_fixture(t)
	defer _ = os.remove_all(root)
	test_ctl_install_failure = "failure with \"quotes\"\nand backslash \\"
	test_ctl_install_already = true
	for failed_step in 0..=2 {
		test_ctl_install_calls = make([dynamic][]string, context.temp_allocator)
		test_ctl_install_fail_step = failed_step
		ok, message := ctl_extension_install_local("claude", test_ctl_install_path({root, "claude-code"}))
		testing.expect_value(t, ok, failed_step == 0)
		if failed_step != 0 do testing.expect_value(t, message, test_ctl_install_failure)
		if failed_step != 1 {
			testing.expect_value(t, len(test_ctl_install_calls), 2)
			if len(test_ctl_install_calls) == 2 do testing.expect_value(t, test_ctl_install_calls[1][2], "update")
		}
	}
	for failed_step in 1..=2 {
		test_ctl_install_calls = make([dynamic][]string, context.temp_allocator)
		test_ctl_install_fail_step = failed_step
		ok, message := ctl_extension_install_local("codex", root)
		testing.expect(t, !ok)
		testing.expect_value(t, message, test_ctl_install_failure)
		testing.expect_value(t, len(test_ctl_install_calls), failed_step)
	}
	ok, _ := ctl_extension_install_local("unsupported", root)
	testing.expect(t, !ok)
	test_ctl_install_calls = make([dynamic][]string, context.temp_allocator)
	_, _, ok = ctl_extension_install_step({"/fake/agy"}, time.time_add(time.now(), -time.Second))
	testing.expect(t, !ok)
	testing.expect_value(t, len(test_ctl_install_calls), 0)
}

@(test)
test_ctl_extension_install_json_escapes_diagnostics :: proc(t: ^testing.T) {
	message := "failed \"quoted\"\nline\t\\path"
	wire := ctl_extension_install_result_json("provider\"name", false, message)
	result: struct {ok: bool, provider: string, error: string}
	err := json.unmarshal_string(wire, &result, {}, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, result.error, message)
	testing.expect_value(t, result.provider, "provider\"name")
}

@(test)
test_ctl_extension_install_process_timeout_and_output :: proc(t: ^testing.T) {
	started := time.now()
	_, message, _, ok := ctl_default_install_runner({"/bin/sh", "-c", "while :; do :; done"}, 50 * time.Millisecond)
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(message, "timed out"))
	testing.expect(t, time.diff(started, time.now()) < 2 * time.Second)
	out, err_out, code, success := ctl_default_install_runner({"/bin/sh", "-c", "printf 'hello'; printf 'problem' >&2; exit 7"}, time.Second)
	testing.expect(t, !success)
	testing.expect_value(t, out, "hello")
	testing.expect_value(t, err_out, "problem")
	testing.expect_value(t, code, 7)
}

test_ctl_install_path :: proc(parts: []string) -> string {
	path, _ := filepath.join(parts, context.temp_allocator)
	return path
}
