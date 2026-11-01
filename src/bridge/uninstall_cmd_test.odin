package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import bridgesvc "odin_test:lib/bridgesvc"

@(test)
test_bridge_uninstall_pty_identity_is_profile_scoped :: proc(t: ^testing.T) {
	first := Bridge_Uninstall{layout = bridgesvc.Layout{data_dir = "/profiles/one"}, pty_sockets = make([dynamic]string, context.temp_allocator)}
	second := Bridge_Uninstall{layout = bridgesvc.Layout{data_dir = "/profiles/two"}, pty_sockets = make([dynamic]string, context.temp_allocator)}
	bridge_uninstall_add_pty_identity(&first, "brg_same")
	bridge_uninstall_add_pty_identity(&second, "brg_same")
	defer { for socket in first.pty_sockets do delete(socket); for socket in second.pty_sockets do delete(socket) }
	bridge_uninstall_add_pty_identity(&first, "")
	testing.expect_value(t, len(first.pty_sockets), 1)
	testing.expect_value(t, first.pty_sockets[0], "/profiles/one/run/pty-host-brg_same.sock")
	testing.expect(t, first.pty_sockets[0] != second.pty_sockets[0], "same bridge identity never targets another profile's daemon")
}

@(test)
test_bridge_uninstall_pty_image_requires_exact_profile :: proc(t: ^testing.T) {
	l := bridgesvc.Layout{data_dir = "/profiles/one", bin_dir = "/profiles/one/bin"}
	owned := []string{"/profiles/one/bin/ham-pty-host.exe", "/profiles/one/bin.bak/ham-pty-host.exe", "/profiles/one/bin.bak-12-34/ham-pty-host.exe"}
	for image in owned {
		testing.expect(t, bridge_uninstall_pty_image_owned(l, image), image)
	}
	unowned := []string{"/profiles/two/bin/ham-pty-host.exe", "/profiles/one-other/bin/ham-pty-host.exe", "/profiles/one/nested/bin.bak-12/ham-pty-host.exe", "/profiles/one/bin/ham-bridge.exe"}
	for image in unowned {
		testing.expect(t, !bridge_uninstall_pty_image_owned(l, image), image)
	}
}

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

// A runtime-status pid is trusted only when it is a ham-bridge process (image
// known) or, when the OS cannot name the image, while the service runs; never our
// own pid or a non-positive one. A reused pid must not be waited on or killed.
@(test)
test_bridge_uninstall_trust_pid :: proc(t: ^testing.T) {
	testing.expect(t, bridge_uninstall_trust_pid(42, 7, false, "ham-bridge", true), "stopped service, live ham-bridge (foreground run)")
	testing.expect(t, bridge_uninstall_trust_pid(42, 7, true, "/Users/u/.local/bin/ham-bridge", true), "macOS ps prints the full path")
	testing.expect(t, bridge_uninstall_trust_pid(42, 7, true, `C:\Users\u\AppData\Local\heimdall\bin\Ham-Bridge.exe`, true), "Windows path, any case")
	testing.expect(t, bridge_uninstall_trust_pid(42, 7, false, "ham-bridge-uninstall-9", true), "a temp copy is still a bridge binary")
	testing.expect(t, !bridge_uninstall_trust_pid(42, 7, true, "firefox", true), "reused pid: never trusted, even with the service running")
	testing.expect(t, !bridge_uninstall_trust_pid(42, 7, false, "", false), "unknown image, service stopped: stale")
	testing.expect(t, bridge_uninstall_trust_pid(42, 7, true, "", false), "unknown image, service running: trusted")
	testing.expect(t, !bridge_uninstall_trust_pid(7, 7, true, "ham-bridge", true), "own pid")
	testing.expect(t, !bridge_uninstall_trust_pid(0, 7, true, "ham-bridge", true), "no pid")
}

@(test)
test_bridge_uninstall_pid_image :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux {
		image, own_known := bridge_uninstall_pid_image(os.get_pid())
		testing.expect(t, own_known && image != "", "own process has an image")
	}
	_, known := bridge_uninstall_pid_image(0)
	testing.expect(t, !known, "pid 0 is never known")
	_, known = bridge_uninstall_pid_image(2147483000)
	testing.expect(t, !known, "a pid that does not exist is unknown")
}

// The relocated copy is told everything it cannot ask for: confirmation already
// given, the profile by service name, and the parent pid to wait for.
@(test)
test_bridge_uninstall_relocated_argv :: proc(t: ^testing.T) {
	argv := bridge_uninstall_relocated_argv(`C:\T\ham-bridge-uninstall-5.exe`, {`C:\bin\ham-bridge.exe`, "uninstall", "--purge", "--hub", "https://h"}, "heimdall-bridge-h", 5)
	joined := strings.join(argv, " ", context.temp_allocator)
	testing.expect_value(t, joined, `C:\T\ham-bridge-uninstall-5.exe uninstall --purge --hub https://h --service heimdall-bridge-h --yes --relocated --wait-pid 5`)
	argv = bridge_uninstall_relocated_argv("c", {"x", "uninstall", "--yes", "--service", "s"}, "other", 9)
	joined = strings.join(argv, " ", context.temp_allocator)
	testing.expect_value(t, joined, "c uninstall --yes --service s --relocated --wait-pid 9")
	pid, ok := bridge_uninstall_wait_pid_arg(argv)
	testing.expect(t, ok && pid == 9, "the copy reads the parent pid back")
	_, ok = bridge_uninstall_wait_pid_arg({"x", "uninstall", "--wait-pid", "abc"})
	testing.expect(t, !ok, "a non-numeric pid is ignored")
}

@(private = "file")
wait_pid_test_calls: int

// The copy runs only after the parent is gone; a parent that never exits is
// reported after the timeout instead of hanging the uninstall.
@(test)
test_bridge_uninstall_wait_pid_exit :: proc(t: ^testing.T) {
	wait_pid_test_calls = 0
	exits_after_three := proc(pid: int) -> bool {
		wait_pid_test_calls += 1
		return wait_pid_test_calls <= 3
	}
	testing.expect(t, bridge_uninstall_wait_pid_exit(5, exits_after_three, 5 * time.Second, time.Millisecond), "waits for the exit")
	testing.expect_value(t, wait_pid_test_calls, 4)
	never_exits := proc(pid: int) -> bool {return true}
	testing.expect(t, !bridge_uninstall_wait_pid_exit(5, never_exits, 20 * time.Millisecond, time.Millisecond), "gives up at the timeout")
}

@(test)
test_bridge_uninstall_delayed_delete_argv :: proc(t: ^testing.T) {
	argv := bridge_uninstall_delayed_delete_argv(`C:\Users\O'Neil\Temp\ham-bridge-uninstall-3.exe`)
	testing.expect_value(t, len(argv), 7)
	testing.expect_value(t, argv[5], "-Command")
	testing.expect_value(t, argv[6], `Start-Sleep -Seconds 3; Remove-Item -LiteralPath 'C:\Users\O''Neil\Temp\ham-bridge-uninstall-3.exe' -Force -ErrorAction SilentlyContinue`)
}

@(test)
test_bridge_service_name_safe :: proc(t: ^testing.T) {
	testing.expect(t, bridge_service_name_safe("heimdall-bridge-hub-example-com"))
	testing.expect(t, bridge_service_name_safe("heimdall-bridge-127-0-0-1-8081_work"))
	// Legacy names, path components and an empty suffix are refused.
	for bad in ([?]string{"heimdall-bridge", "heimdall-bridge-", "ham-bridge", "works.earendil.heimdall-bridge", "heimdall-bridge-x/../../..", "heimdall-bridge-x\\..\\..", "heimdall-bridge-A"}) {
		testing.expectf(t, !bridge_service_name_safe(bad), "%q must be refused", bad)
	}
}

// Unregister removes a single file (a launchd plist or systemd unit) as well as a
// directory: core:os remove_all on darwin cannot unlink a regular file.
@(test)
test_bridge_uninstall_remove_file_and_dir :: proc(t: ^testing.T) {
	tmp, _ := os.temp_directory(context.allocator)
	defer delete(tmp)
	root := fmt.tprintf("%s/heimdall-uninstall-remove-%d", tmp, time.to_unix_nanoseconds(time.now()))
	dir := strings.concatenate({root, "/svc.d"}, context.temp_allocator)
	file := strings.concatenate({root, "/svc.plist"}, context.temp_allocator)
	testing.expect(t, os.make_directory_all(strings.concatenate({dir, "/sub"}, context.temp_allocator)) == nil, "fixture dir")
	testing.expect(t, os.write_entire_file(strings.concatenate({dir, "/sub/x"}, context.temp_allocator), "x") == nil, "fixture dir file")
	testing.expect(t, os.write_entire_file(file, "<plist/>") == nil, "fixture file")
	defer os.remove_all(root)

	removed, busy, left := bridge_uninstall_remove(nil, {file, dir, strings.concatenate({root, "/missing"}, context.temp_allocator)})
	testing.expect_value(t, removed, 2)
	testing.expect(t, !busy, left)
	testing.expect(t, !os.exists(file), "the plist file is gone")
	testing.expect(t, !os.exists(dir), "the directory is gone")
}
