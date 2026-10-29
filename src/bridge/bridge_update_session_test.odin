#+build !windows
package main

// `ham-bridge update --detach` and the hub-initiated update start the staged
// binary's update in a session of its own (bridge_os_spawn_new_session), so the
// service stop it performs does not take it down; and the hub-initiated update
// stops the PTY host it finds through the socket's peer pid. Nothing here touches
// a real install or a real PTY host.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import local_socket "odin_test:lib/local_socket"

bridge_update_test_read :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return ""
	return string(data)
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
	testing.expect(t, !bridge_os_spawn_new_session([]string{"/nonexistent/ham-bridge-update"}), "absolute missing path fails")
	testing.expect(t, !bridge_os_spawn_new_session([]string{"ham-no-such-command-for-update-test"}), "PATH miss fails")
	testing.expect(t, !bridge_os_spawn_new_session([]string{}), "empty argv fails")
}

// The peer pid identifies the process serving the PTY-host socket; only a
// ham-pty-host image is ever signalled, and a socket nobody serves is a no-op.
@(test)
test_bridge_update_stop_pty_host_identifies_and_guards_the_peer :: proc(t: ^testing.T) {
	a, b, ok := local_socket.pair()
	testing.expect(t, ok, "socket pair")
	defer {local_socket.close(a); local_socket.close(b)}
	pid, has := local_socket.peer_pid(a)
	when ODIN_OS == .Linux || ODIN_OS == .Darwin {
		testing.expect(t, has, "peer pid is available")
		testing.expect_value(t, pid, int(os.get_pid()))
	}
	// The test runner is not ham-pty-host: it must never be signalled.
	testing.expect(t, !bridge_update_pid_is_pty_host(int(os.get_pid())), "the test runner is not taken for ham-pty-host")

	missing := fmt.tprintf("/tmp/ham-upd-nosock-%d-%d.sock", os.get_pid(), time.now()._nsec)
	stopped, detail := bridge_update_stop_pty_host(missing)
	testing.expect(t, stopped, detail)
}

// A bridge that is not a ham-bridge profile install (here: the test runner, no
// registered service) is refused before anything is downloaded, with the one-time
// reinstall that fixes it; so is a hub-initiated downgrade.
@(test)
test_bridge_update_refuses_non_profile_install_with_reinstall_hint :: proc(t: ^testing.T) {
	service, refusal := bridge_update_via_ham_bridge("999.0.0")
	testing.expect_value(t, service, "")
	testing.expect(t, strings.contains(refusal, BRIDGE_REINSTALL_HINT), refusal)
	testing.expect(t, strings.contains(refusal, "-fsSL " + BRIDGE_INSTALLER_HOST + " | bash"), refusal)
	ok, detail := bridge_runtime_apply_update(nil, "cmd_1", "999.0.0", "https://example.invalid/bundle.tar.gz", "", true, 0)
	testing.expect(t, !ok)
	testing.expect_value(t, detail, refusal)
}
