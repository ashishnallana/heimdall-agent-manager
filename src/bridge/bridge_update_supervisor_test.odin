#+build !windows
package main

// REQ-UPD-COMPAT-2: the apply path runs only the staged bundle's supervisor,
// passes the versioned interface to both invocations, and starts the detached
// supervisor in a session of its own. Every script here is a recording fake in
// an isolated temp dir: nothing stops a real PTY host or touches a real install.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"

// Records each invocation's argv (one per line) and, for the detached apply,
// its pid, process group and session. stdio is /dev/null, so it writes files;
// the ids file is renamed into place last, so its presence means all is written.
BRIDGE_UPDATE_TEST_FAKE_SUPERVISOR :: `#!/usr/bin/env bash
out="$(dirname "$0")/../record"
mode=apply
for a in "$@"; do [ "$a" = --stop-pty-hosts-only ] && mode=stop; done
mkdir -p "$out"
printf '%s\n' "$@" > "$out/$mode.args"
if [ "$mode" = apply ]; then
  pgid=$(ps -o pgid= -p $$ | tr -d '[:space:]')
  sid=$(ps -o sid= -p $$ 2>/dev/null | tr -d '[:space:]')
  echo "$$ $pgid ${sid:-?}" > "$out/apply.ids.tmp"
  mv "$out/apply.ids.tmp" "$out/apply.ids"
fi
exit 0
`

// A script anywhere but the staged bundle must never run; this one says so.
BRIDGE_UPDATE_TEST_STALE_SUPERVISOR :: `#!/usr/bin/env bash
echo ran > "$(dirname "$0")/STALE_SUPERVISOR_RAN"
exit 0
`

bridge_update_test_write_exec :: proc(path, content: string) -> bool {
	if os.write_entire_file(path, transmute([]byte)content) != nil do return false
	return os.chmod(path, os.Permissions{.Read_User, .Write_User, .Execute_User}) == nil
}

bridge_update_test_read :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return ""
	return string(data)
}

// bridge_update_test_bundle tars bundle_dir's contents into a .tar.gz next to it.
bridge_update_test_bundle :: proc(bundle_dir, tarball: string) -> bool {
	state, stdout, stderr, err := os.process_exec(os.Process_Desc{command = []string{"tar", "-czf", tarball, "-C", bundle_dir, "."}}, context.temp_allocator)
	_ = stdout; _ = stderr
	return err == nil && state.success
}

// Reap a child the test spawned through bridge_os_spawn_new_session.
bridge_update_test_reap :: proc(pid: int) {
	if pid <= 0 do return
	status: i32
	for posix.waitpid(posix.pid_t(pid), &status, {}) == -1 && posix.errno() == .EINTR {}
}

// The detached process is the leader of its own session and process group.
bridge_update_test_expect_session_leader :: proc(t: ^testing.T, ids: string) -> int {
	fields := strings.fields(strings.trim_space(ids), context.temp_allocator)
	testing.expectf(t, len(fields) == 3, "ids line %q has pid, pgid and sid", ids)
	if len(fields) != 3 do return 0
	pid, _ := strconv.parse_int(fields[0])
	testing.expectf(t, fields[1] == fields[0], "pgid %s == pid %s: the child leads its own process group", fields[1], fields[0])
	when ODIN_OS == .Linux {
		testing.expectf(t, fields[2] == fields[0], "sid %s == pid %s: the child leads its own session", fields[2], fields[0])
	}
	testing.expect(t, posix.getpgrp() != posix.pid_t(pid), "the child is not in the test runner's process group")
	return pid
}

bridge_update_test_wait_file :: proc(path: string, timeout: time.Duration) -> bool {
	deadline := time.tick_now()
	for time.tick_since(deadline) < timeout {
		if os.exists(path) do return true
		time.sleep(20 * time.Millisecond)
	}
	return os.exists(path)
}

@(test)
test_bridge_update_spawn_new_session_leads_its_own_session :: proc(t: ^testing.T) {
	dir := fmt.aprintf("/tmp/ham-upd-session-%d-%d", os.get_pid(), time.now()._nsec)
	defer delete(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)
	defer _ = os.remove_all(dir)
	ids_path := fmt.tprintf("%s/ids", dir)

	// argv[0] without a slash resolves through PATH, like the real "bash".
	script := fmt.tprintf(`echo "$$ $(ps -o pgid= -p $$ | tr -d '[:space:]') $(ps -o sid= -p $$ 2>/dev/null | tr -d '[:space:]')" > '%s.tmp' && mv '%s.tmp' '%s'`, ids_path, ids_path, ids_path)
	testing.expect(t, bridge_os_spawn_new_session([]string{"sh", "-c", script}), "spawn through PATH succeeds")
	testing.expect(t, bridge_update_test_wait_file(ids_path, 10 * time.Second), "the detached child ran")
	pid := bridge_update_test_expect_session_leader(t, bridge_update_test_read(ids_path))
	bridge_update_test_reap(pid)

	// A missing executable is reported, not silently "started".
	testing.expect(t, !bridge_os_spawn_new_session([]string{"/nonexistent/ham-update-supervisor"}), "absolute missing path fails")
	testing.expect(t, !bridge_os_spawn_new_session([]string{"ham-no-such-command-for-update-test"}), "PATH miss fails")
	testing.expect(t, !bridge_os_spawn_new_session([]string{}), "empty argv fails")
}

@(test)
test_bridge_update_stage_supervisor_takes_only_the_staged_bundle :: proc(t: ^testing.T) {
	dir := fmt.aprintf("/tmp/ham-upd-stage-%d-%d", os.get_pid(), time.now()._nsec)
	defer delete(dir)
	stage := fmt.tprintf("%s/stage", dir)
	target := fmt.tprintf("%s/updates/%s", dir, BRIDGE_UPDATE_SUPERVISOR_NAME)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/scripts", stage)) == nil)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/updates", dir)) == nil)
	defer _ = os.remove_all(dir)

	// Bundle root is accepted when scripts/ has none.
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", stage, BRIDGE_UPDATE_SUPERVISOR_NAME), transmute([]byte)string("root")) == nil)
	ok, detail := bridge_update_stage_supervisor(stage, target)
	testing.expect(t, ok, detail)
	testing.expect_value(t, bridge_update_test_read(target), "root")
	testing.expect(t, bridge_os_is_executable(target), "the copied supervisor is executable")

	// scripts/<name> wins over the bundle root.
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/scripts/%s", stage, BRIDGE_UPDATE_SUPERVISOR_NAME), transmute([]byte)string("scripts")) == nil)
	ok, detail = bridge_update_stage_supervisor(stage, target)
	testing.expect(t, ok, detail)
	testing.expect_value(t, bridge_update_test_read(target), "scripts")

	// No script in the bundle: refused, and the copy an earlier update left at
	// target is removed rather than reused.
	_ = os.remove(fmt.tprintf("%s/scripts/%s", stage, BRIDGE_UPDATE_SUPERVISOR_NAME))
	_ = os.remove(fmt.tprintf("%s/%s", stage, BRIDGE_UPDATE_SUPERVISOR_NAME))
	ok, detail = bridge_update_stage_supervisor(stage, target)
	testing.expect(t, !ok, "a bundle without the supervisor is refused")
	testing.expect(t, strings.contains(detail, "not found in the staged bundle"), detail)
	testing.expect(t, !os.exists(target), "the stale installed copy is gone")
}

// End to end through bridge_runtime_apply_update with a local bundle whose
// supervisor is the recording fake: both invocations carry the versioned
// interface, and the detached one runs in its own session. A bundle without the
// script aborts before any supervisor runs, ignoring data-dir and stale copies.
@(test)
test_bridge_update_apply_runs_only_staged_supervisor_with_versions :: proc(t: ^testing.T) {
	dir := fmt.aprintf("/tmp/ham-upd-apply-%d-%d", os.get_pid(), time.now()._nsec)
	defer delete(dir)
	defer _ = os.remove_all(dir)
	data_dir := fmt.aprintf("%s/data", dir)
	defer delete(data_dir)
	bundle := fmt.aprintf("%s/bundle", dir)
	defer delete(bundle)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/bin", bundle)) == nil)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/scripts", bundle)) == nil)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/scripts", data_dir)) == nil)
	testing.expect(t, bridge_update_test_write_exec(fmt.tprintf("%s/bin/ham-bridge", bundle), "#!/bin/sh\necho 'ham-bridge 9.9.9'\n"))

	saved_data_dir := bridge_config.data_dir
	defer bridge_config.data_dir = saved_data_dir
	bridge_config.data_dir = data_dir

	// 1. Bundle without the supervisor; decoys in the data dir and a stale copy
	// from an earlier update must not be used.
	no_script_tar := fmt.aprintf("%s/no-script.tar.gz", dir)
	defer delete(no_script_tar)
	testing.expect(t, bridge_update_test_bundle(bundle, no_script_tar))
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/updates", data_dir)) == nil)
	stale := fmt.aprintf("%s/updates/%s", data_dir, BRIDGE_UPDATE_SUPERVISOR_NAME)
	defer delete(stale)
	testing.expect(t, bridge_update_test_write_exec(stale, BRIDGE_UPDATE_TEST_STALE_SUPERVISOR))
	testing.expect(t, bridge_update_test_write_exec(fmt.tprintf("%s/scripts/%s", data_dir, BRIDGE_UPDATE_SUPERVISOR_NAME), BRIDGE_UPDATE_TEST_STALE_SUPERVISOR))

	ok, detail := bridge_runtime_apply_update(nil, "", "9.9.9", fmt.tprintf("file://%s", no_script_tar), "", true, 0)
	testing.expect(t, !ok, "a bundle without the supervisor is refused")
	testing.expect(t, strings.contains(detail, "not found in the staged bundle"), detail)
	testing.expect(t, !os.exists(fmt.tprintf("%s/updates/STALE_SUPERVISOR_RAN", data_dir)), "the stale installed copy never ran")
	testing.expect(t, !os.exists(fmt.tprintf("%s/scripts/STALE_SUPERVISOR_RAN", data_dir)), "the data-dir copy never ran")
	testing.expect(t, !os.exists(stale), "the stale installed copy was removed")
	testing.expect(t, !os.exists(fmt.tprintf("%s/updates/stage", data_dir)), "the stage dir was cleaned up")

	// An empty target_version is refused before anything is downloaded.
	ok, detail = bridge_runtime_apply_update(nil, "", "  ", fmt.tprintf("file://%s", no_script_tar), "", true, 0)
	testing.expect(t, !ok)
	testing.expect_value(t, detail, "missing target_version")

	// 2. Bundle with the recording supervisor: the update is handed off.
	testing.expect(t, bridge_update_test_write_exec(fmt.tprintf("%s/scripts/%s", bundle, BRIDGE_UPDATE_SUPERVISOR_NAME), BRIDGE_UPDATE_TEST_FAKE_SUPERVISOR))
	good_tar := fmt.aprintf("%s/good.tar.gz", dir)
	defer delete(good_tar)
	testing.expect(t, bridge_update_test_bundle(bundle, good_tar))
	ok, detail = bridge_runtime_apply_update(nil, "", "9.9.9", fmt.tprintf("file://%s", good_tar), "", true, 0)
	testing.expect(t, ok, detail)

	record := fmt.tprintf("%s/record", data_dir)
	installed := fmt.tprintf("%s/updates/%s", data_dir, BRIDGE_UPDATE_SUPERVISOR_NAME)

	stop_args := strings.split_lines(strings.trim_right(bridge_update_test_read(fmt.tprintf("%s/stop.args", record)), "\n"), context.temp_allocator)
	stop_want := []string{
		"--interface", "2",
		"--from-version", contracts.APP_VERSION,
		"--to-version", "9.9.9",
		"--data-dir", data_dir,
		"--stop-pty-hosts-only",
		"--pty-host-socket",
	}
	testing.expectf(t, len(stop_args) == len(stop_want) + 1, "stop argv: %v", stop_args)
	for want, i in stop_want {
		if i >= len(stop_args) do break
		testing.expectf(t, stop_args[i] == want, "stop argv[%d] = %q, want %q", i, stop_args[i], want)
	}

	ids_path := fmt.tprintf("%s/apply.ids", record)
	testing.expect(t, bridge_update_test_wait_file(ids_path, 10 * time.Second), "the detached supervisor ran")
	pid := bridge_update_test_expect_session_leader(t, bridge_update_test_read(ids_path))
	defer bridge_update_test_reap(pid)

	apply_args := strings.split_lines(strings.trim_right(bridge_update_test_read(fmt.tprintf("%s/apply.args", record)), "\n"), context.temp_allocator)
	apply_head := []string{
		"--interface", "2",
		"--from-version", contracts.APP_VERSION,
		"--to-version", "9.9.9",
		"--data-dir", data_dir,
		"--stage-dir", fmt.tprintf("%s/updates/stage", data_dir),
	}
	testing.expectf(t, len(apply_args) > len(apply_head), "apply argv: %v", apply_args)
	for want, i in apply_head {
		if i >= len(apply_args) do break
		testing.expectf(t, apply_args[i] == want, "apply argv[%d] = %q, want %q", i, apply_args[i], want)
	}
	if len(apply_args) > 0 {
		testing.expect_value(t, apply_args[len(apply_args) - 1], "--already-detached")
	}
	testing.expect(t, os.exists(installed), "the staged supervisor was installed under updates/")
}
