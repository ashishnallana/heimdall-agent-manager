package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

@(private="file")
test_ctl_mock_args: [dynamic]string
@(private="file")
test_ctl_mock_succeed: bool
@(private="file")
test_ctl_mock_error_message: string

@(private="file")
test_ctl_mock_runner :: proc(args: []string, allocator := context.temp_allocator) -> (stdout, stderr: string, exit_code: int, ok: bool) {
	for arg in args {
		append(&test_ctl_mock_args, strings.clone(arg))
	}
	if test_ctl_mock_succeed {
		return "Installed successfully", "", 0, true
	} else {
		return "", test_ctl_mock_error_message, 1, false
	}
}

@(test)
test_ctl_extension_install_antigravity :: proc(t: ^testing.T) {
	orig_runner := ctl_extension_install_runner
	defer {
		ctl_extension_install_runner = orig_runner
		for arg in test_ctl_mock_args do delete(arg)
		delete(test_ctl_mock_args)
	}
	ctl_extension_install_runner = test_ctl_mock_runner
	test_ctl_mock_succeed = true

	ok, msg := ctl_extension_install_local("antigravity", "")
	testing.expect(t, ok, "installation should succeed")
	testing.expect(t, strings.contains(msg, "installed successfully"), "success message")
	testing.expect(t, len(test_ctl_mock_args) >= 4, "arguments were passed to runner")
	if len(test_ctl_mock_args) >= 4 {
		testing.expect(t, strings.has_suffix(test_ctl_mock_args[0], "agy"), "binary is agy")
		testing.expect_value(t, test_ctl_mock_args[1], "plugin")
		testing.expect_value(t, test_ctl_mock_args[2], "install")
		testing.expect(t, strings.contains(test_ctl_mock_args[3], "antigravity"), "extension path contains antigravity")
	}
}

@(test)
test_ctl_extension_install_claude :: proc(t: ^testing.T) {
	orig_runner := ctl_extension_install_runner
	defer {
		ctl_extension_install_runner = orig_runner
		for arg in test_ctl_mock_args do delete(arg)
		delete(test_ctl_mock_args)
	}
	ctl_extension_install_runner = test_ctl_mock_runner
	test_ctl_mock_succeed = true

	ok, msg := ctl_extension_install_local("claude", "")
	testing.expect(t, ok, "installation should succeed")
	testing.expect(t, strings.contains(msg, "installed successfully"), "success message")
	testing.expect(t, len(test_ctl_mock_args) >= 5, "arguments were passed to runner")
	if len(test_ctl_mock_args) >= 5 {
		testing.expect(t, strings.has_suffix(test_ctl_mock_args[0], "claude"), "binary is claude")
		testing.expect_value(t, test_ctl_mock_args[1], "plugin")
		testing.expect_value(t, test_ctl_mock_args[2], "install")
	}
}

@(test)
test_ctl_extension_install_codex :: proc(t: ^testing.T) {
	orig_runner := ctl_extension_install_runner
	defer {
		ctl_extension_install_runner = orig_runner
		for arg in test_ctl_mock_args do delete(arg)
		delete(test_ctl_mock_args)
	}
	ctl_extension_install_runner = test_ctl_mock_runner
	test_ctl_mock_succeed = true

	ok, msg := ctl_extension_install_local("codex", "")
	testing.expect(t, ok, "installation should succeed")
	testing.expect(t, strings.contains(msg, "installed successfully"), "success message")
	testing.expect_value(t, len(test_ctl_mock_args), 4)
	if len(test_ctl_mock_args) == 4 {
		testing.expect(t, strings.has_suffix(test_ctl_mock_args[0], "codex"), "binary is codex")
		testing.expect_value(t, test_ctl_mock_args[1], "plugin")
		testing.expect_value(t, test_ctl_mock_args[2], "add")
		testing.expect_value(t, test_ctl_mock_args[3], "heimdall@heimdall-codex")
	}
}

@(test)
test_ctl_extension_install_custom_path :: proc(t: ^testing.T) {
	orig_runner := ctl_extension_install_runner
	defer {
		ctl_extension_install_runner = orig_runner
		for arg in test_ctl_mock_args do delete(arg)
		delete(test_ctl_mock_args)
	}
	ctl_extension_install_runner = test_ctl_mock_runner
	test_ctl_mock_succeed = true

	// Use existing extensions/antigravity as custom path
	custom_path, _ := filepath.abs("extensions/antigravity", context.temp_allocator)
	ok, msg := ctl_extension_install_local("antigravity", custom_path)
	testing.expect(t, ok, "custom path installation should succeed")
	testing.expect(t, len(test_ctl_mock_args) >= 4, "executed args")
	if len(test_ctl_mock_args) >= 4 {
		testing.expect_value(t, test_ctl_mock_args[3], custom_path)
	}
}

@(test)
test_ctl_extension_install_failure :: proc(t: ^testing.T) {
	orig_runner := ctl_extension_install_runner
	defer {
		ctl_extension_install_runner = orig_runner
		for arg in test_ctl_mock_args do delete(arg)
		delete(test_ctl_mock_args)
	}
	ctl_extension_install_runner = test_ctl_mock_runner
	test_ctl_mock_succeed = false
	test_ctl_mock_error_message = "permission denied writing to config"

	ok, msg := ctl_extension_install_local("antigravity", "")
	testing.expect(t, !ok, "installation should report failure")
	testing.expect(t, strings.contains(msg, "permission denied writing to config"), "error message matches")
}

@(test)
test_ctl_extension_install_unsupported_provider :: proc(t: ^testing.T) {
	ok, msg := ctl_extension_install_local("unsupported_provider_xyz", "")
	testing.expect(t, !ok, "unsupported provider should fail")
	testing.expect(t, strings.contains(msg, "unsupported provider"), "error message mentions unsupported provider")
}
