// Tests for `heimdall start/stop/restart/logs` internals (src/manager/service.odin):
// argv construction for both platforms (the platform/loaded state is injected so
// macOS behavior is testable from Linux), systemctl/launchctl output parsers, and
// an opt-in live lifecycle exercise against a sacrificial throwaway user unit.
//
// SAFETY: the live test NEVER touches the real `heimdall-bridge` unit (it hosts
// the agent runtime) — it only operates on MANAGER_TEST_SELFTEST_UNIT and is
// skipped unless HEIMDALL_MANAGER_LIVE_UNIT_TEST=1.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

MANAGER_TEST_SELFTEST_UNIT :: "heimdall-manager-selftest"

@(test)
test_manager_service_verb_argv :: proc(t: ^testing.T) {
	// Linux: plain systemctl --user calls, regardless of loaded state.
	start := manager_service_verb_argv("start", "heimdall-bridge", "", "", .Linux, 0, false)
	testing.expect(t, manager_test_argv_eq(start, []string{"systemctl", "--user", "start", "heimdall-bridge"}), fmt.tprintf("linux start argv: %s", manager_test_argv_string(start)))
	stop := manager_service_verb_argv("stop", "heimdall-bridge", "", "", .Linux, 0, true)
	testing.expect(t, manager_test_argv_eq(stop, []string{"systemctl", "--user", "stop", "heimdall-bridge"}), fmt.tprintf("linux stop argv: %s", manager_test_argv_string(stop)))
	restart := manager_service_verb_argv("restart", "heimdall-bridge", "", "", .Linux, 0, true)
	testing.expect(t, manager_test_argv_eq(restart, []string{"systemctl", "--user", "restart", "heimdall-bridge"}), fmt.tprintf("linux restart argv: %s", manager_test_argv_string(restart)))

	// Darwin: a never-loaded agent is bootstrapped from its plist...
	bootstrap := manager_service_verb_argv("start", "heimdall-bridge", "works.earendil.heimdall-bridge", "/Users/x/Library/LaunchAgents/works.earendil.heimdall-bridge.plist", .Darwin, 501, false)
	expected_bootstrap := []string{"launchctl", "bootstrap", "gui/501", "/Users/x/Library/LaunchAgents/works.earendil.heimdall-bridge.plist"}
	testing.expect(t, manager_test_argv_eq(bootstrap, expected_bootstrap), fmt.tprintf("darwin start-not-loaded bootstraps: %s", manager_test_argv_string(bootstrap)))

	// ...while an already-loaded agent is kickstarted in place.
	kickstart := manager_service_verb_argv("restart", "heimdall-bridge", "works.earendil.heimdall-bridge", "/Users/x/Library/LaunchAgents/works.earendil.heimdall-bridge.plist", .Darwin, 501, true)
	expected_kickstart := []string{"launchctl", "kickstart", "-k", "gui/501/works.earendil.heimdall-bridge"}
	testing.expect(t, manager_test_argv_eq(kickstart, expected_kickstart), fmt.tprintf("darwin restart-loaded kickstarts: %s", manager_test_argv_string(kickstart)))

	bootout := manager_service_verb_argv("stop", "heimdall-bridge", "works.earendil.heimdall-bridge", "", .Darwin, 501, true)
	expected_bootout := []string{"launchctl", "bootout", "gui/501/works.earendil.heimdall-bridge"}
	testing.expect(t, manager_test_argv_eq(bootout, expected_bootout), fmt.tprintf("darwin stop bootouts: %s", manager_test_argv_string(bootout)))

	// Unknown verbs and unsupported platforms produce no command.
	testing.expect(t, len(manager_service_verb_argv("enable", "u", "l", "p", .Linux, 0, false)) == 0, "unknown verb yields no argv")
	testing.expect(t, len(manager_service_verb_argv("start", "u", "l", "p", .Unsupported, 0, false)) == 0, "unsupported platform yields no argv")
}

@(test)
test_manager_logs_argv :: proc(t: ^testing.T) {
	linux := manager_logs_argv("heimdall-bridge", .Linux, 200, false)
	testing.expect(t, manager_test_argv_eq(linux, []string{"journalctl", "--user", "-u", "heimdall-bridge", "-n", "200"}), fmt.tprintf("linux logs argv: %s", manager_test_argv_string(linux)))
	linux_follow := manager_logs_argv("heimdall-bridge", .Linux, 50, true)
	testing.expect(t, manager_test_argv_eq(linux_follow, []string{"journalctl", "--user", "-u", "heimdall-bridge", "-n", "50", "-f"}), fmt.tprintf("linux follow argv: %s", manager_test_argv_string(linux_follow)))

	out_log := manager_macos_log_path("heimdall-bridge", "out")
	err_log := manager_macos_log_path("heimdall-bridge", "err")
	testing.expect(t, out_log == "/tmp/heimdall-logs/heimdall-bridge.out.log", fmt.tprintf("macos out log path: %s", out_log))
	testing.expect(t, err_log == "/tmp/heimdall-logs/heimdall-bridge.err.log", fmt.tprintf("macos err log path: %s", err_log))

	darwin := manager_logs_argv("heimdall-bridge", .Darwin, 200, false)
	testing.expect(t, manager_test_argv_eq(darwin, []string{"tail", "-n", "200", out_log, err_log}), fmt.tprintf("darwin logs argv: %s", manager_test_argv_string(darwin)))
	darwin_follow := manager_logs_argv("heimdall-bridge", .Darwin, 200, true)
	testing.expect(t, manager_test_argv_eq(darwin_follow, []string{"tail", "-n", "200", "-f", out_log, err_log}), fmt.tprintf("darwin follow argv: %s", manager_test_argv_string(darwin_follow)))

	testing.expect(t, len(manager_logs_argv("heimdall-bridge", .Unsupported, 200, false)) == 0, "unsupported platform yields no argv")
}

@(test)
test_manager_launchd_plist_path :: proc(t: ^testing.T) {
	sync.mutex_lock(&manager_test_env_mutex)
	defer sync.mutex_unlock(&manager_test_env_mutex)
	previous := os.get_env("HOME", context.allocator)
	defer {
		if previous != "" do os.set_env("HOME", previous)
	}
	os.set_env("HOME", "/tmp/heimdall-test-home")
	path := manager_launchd_plist_path()
	testing.expect(t, path == "/tmp/heimdall-test-home/Library/LaunchAgents/works.earendil.heimdall-bridge.plist", fmt.tprintf("plist path honors HOME: %s", path))
}

@(test)
test_manager_parse_systemctl_show :: proc(t: ^testing.T) {
	unavailable := manager_parse_systemctl_show("", false)
	testing.expect(t, !unavailable.loaded && !unavailable.active, "failed query is neither loaded nor active")
	testing.expect(t, unavailable.detail == "unavailable", fmt.tprintf("failed query detail: %s", unavailable.detail))

	active_out := strings.concatenate({
		"LoadState=loaded\n",
		"ActiveState=active\n",
		"SubState=running\n",
		"MainPID=1032\n",
		"ActiveEnterTimestamp=Mon 2026-09-22 12:00:00 UTC\n",
	})
	active := manager_parse_systemctl_show(active_out, true)
	testing.expect(t, active.loaded, "active unit is loaded")
	testing.expect(t, active.active, "active unit is active")
	testing.expect(t, active.pid == 1032, fmt.tprintf("active pid parsed (%d)", active.pid))
	testing.expect(t, active.detail == "active", fmt.tprintf("active detail: %s", active.detail))
	testing.expect(t, active.since == "Mon 2026-09-22 12:00:00 UTC", fmt.tprintf("active-since parsed: %s", active.since))

	inactive_out := "LoadState=loaded\nActiveState=inactive\nSubState=dead\nMainPID=0\nActiveEnterTimestamp=\n"
	inactive := manager_parse_systemctl_show(inactive_out, true)
	testing.expect(t, inactive.loaded && !inactive.active, "inactive unit is loaded but not active")
	testing.expect(t, inactive.detail == "inactive", fmt.tprintf("inactive detail: %s", inactive.detail))

	missing := manager_parse_systemctl_show("LoadState=not-found\nActiveState=inactive\nSubState=dead\nMainPID=0\n", true)
	testing.expect(t, !missing.loaded, "not-found unit is not loaded")
}

@(test)
test_manager_parse_launchctl_print :: proc(t: ^testing.T) {
	missing := manager_parse_launchctl_print("", false)
	testing.expect(t, !missing.loaded && !missing.active, "failed launchctl print is not loaded")
	testing.expect(t, missing.detail == "not loaded", fmt.tprintf("failed launchctl print detail: %s", missing.detail))

	running_out := strings.concatenate({
		"gui/501/works.earendil.heimdall-bridge = {\n",
		"\tactive count = 1\n",
		"\tstate = running\n",
		"\tpid = 4242\n",
		"}\n",
	})
	running := manager_parse_launchctl_print(running_out, true)
	testing.expect(t, running.loaded, "printed agent is loaded")
	testing.expect(t, running.active, "running agent is active")
	testing.expect(t, running.pid == 4242, fmt.tprintf("agent pid parsed (%d)", running.pid))
	testing.expect(t, running.detail == "running", fmt.tprintf("running detail: %s", running.detail))

	exited := manager_parse_launchctl_print("state = exited\npid = 0\n", true)
	testing.expect(t, exited.loaded && !exited.active, "exited agent is loaded but not active")
	testing.expect(t, exited.detail == "exited", fmt.tprintf("exited detail: %s", exited.detail))
}

// test_manager_service_lifecycle_live_sacrificial_unit exercises the real
// start/stop mechanics end-to-end through the parameterized argv builders,
// against a throwaway unit. Opt-in (HEIMDALL_MANAGER_LIVE_UNIT_TEST=1) because
// it writes to ~/.config/systemd/user and talks to the user systemd manager.
@(test)
test_manager_service_lifecycle_live_sacrificial_unit :: proc(t: ^testing.T) {
	if os.get_env("HEIMDALL_MANAGER_LIVE_UNIT_TEST", context.temp_allocator) != "1" {
		fmt.println("  [skip] live sacrificial unit test (set HEIMDALL_MANAGER_LIVE_UNIT_TEST=1 to run)")
		return
	}
	if manager_host_platform() != .Linux {
		fmt.println("  [skip] live sacrificial unit test (Linux only)")
		return
	}
	// Hard guard: this test must never operate on the real bridge unit.
	testing.expect(t, MANAGER_TEST_SELFTEST_UNIT != MANAGER_SERVICE_UNIT, "selftest unit name differs from the real bridge unit")
	if _, found := manager_bin_on_path("systemctl"); !found {
		fmt.println("  [skip] live sacrificial unit test (systemctl not on PATH)")
		return
	}
	if _, _, bus_ok := manager_run_capture({"systemctl", "--user", "daemon-reload"}); !bus_ok {
		fmt.println("  [skip] live sacrificial unit test (user systemd manager not reachable from this environment)")
		return
	}
	sleep_bin, sleep_found := manager_bin_on_path("sleep")
	if !sleep_found {
		fmt.println("  [skip] live sacrificial unit test (sleep not on PATH)")
		return
	}

	home := os.get_env_alloc("HOME", context.temp_allocator)
	unit_dir := fmt.tprintf("%s/.config/systemd/user", home)
	unit_path := fmt.tprintf("%s/%s.service", unit_dir, MANAGER_TEST_SELFTEST_UNIT)
	// The unit dir usually already exists (nix/home-manager manages the real
	// unit there); only create it when missing (make_directory_all errors on
	// an existing final directory).
	if !manager_is_dir(unit_dir) {
		testing.expect(t, os.make_directory_all(unit_dir) == nil, fmt.tprintf("create systemd user unit dir %s", unit_dir))
	}
	unit := fmt.tprintf("[Unit]\nDescription=Heimdall manager selftest (sacrificial; created by odin test)\n\n[Service]\nType=simple\nExecStart=%s infinity\nRestart=no\n", sleep_bin)
	testing.expect(t, os.write_entire_file(unit_path, unit) == nil, "write sacrificial unit file")
	defer {
		_, _, _ = manager_run_capture({"systemctl", "--user", "stop", MANAGER_TEST_SELFTEST_UNIT})
		_, _, _ = manager_run_capture({"systemctl", "--user", "reset-failed", MANAGER_TEST_SELFTEST_UNIT})
		_ = os.remove(unit_path)
		_, _, _ = manager_run_capture({"systemctl", "--user", "daemon-reload"})
	}

	_, _, reload_ok := manager_run_capture({"systemctl", "--user", "daemon-reload"})
	testing.expect(t, reload_ok, "daemon-reload with the sacrificial unit present")

	start_argv := manager_service_verb_argv("start", MANAGER_TEST_SELFTEST_UNIT, "", "", .Linux, 0, false)
	_, start_err, start_ok := manager_run_capture(start_argv)
	testing.expect(t, start_ok, fmt.tprintf("sacrificial unit start succeeded: %s", start_err))

	started := manager_service_state(.Linux, MANAGER_TEST_SELFTEST_UNIT, "", "")
	testing.expect(t, started.loaded, "sacrificial unit loaded after start")
	testing.expect(t, started.active, fmt.tprintf("sacrificial unit active after start (state %s)", started.detail))
	testing.expect(t, started.pid > 0, fmt.tprintf("sacrificial unit has a pid (%d)", started.pid))

	stop_argv := manager_service_verb_argv("stop", MANAGER_TEST_SELFTEST_UNIT, "", "", .Linux, 0, true)
	_, stop_err, stop_ok := manager_run_capture(stop_argv)
	testing.expect(t, stop_ok, fmt.tprintf("sacrificial unit stop succeeded: %s", stop_err))

	stopped := manager_service_state(.Linux, MANAGER_TEST_SELFTEST_UNIT, "", "")
	testing.expect(t, stopped.loaded, "sacrificial unit still loaded after stop")
	testing.expect(t, !stopped.active, fmt.tprintf("sacrificial unit inactive after stop (state %s)", stopped.detail))
}
