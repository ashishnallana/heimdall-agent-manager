package main

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

// T11: tests share the process-global pty_host_daemon_socket. Assigning a
// temp-allocated (or soon-freed) string to it left a dangling pointer that other
// threads' ensure_daemon / ping then dialled: the suite was observed connecting to
// a LIVE bridge's /tmp/heimdall-<uid>/<hash>.sock. These helpers install an OWNED
// heap clone under the daemon lock, and the fence in pty_host_test_socket_allowed
// makes any such path a refused dial instead of a live request.

Pty_Host_Test_Swap :: struct {
	installed:   string, // heap clone currently in the global
	old_socket:  string,
	old_started: bool,
}

pty_host_test_install_socket :: proc(path: string) -> Pty_Host_Test_Swap {
	sync.mutex_lock(&pty_host_daemon_lock)
	defer sync.mutex_unlock(&pty_host_daemon_lock)
	s := Pty_Host_Test_Swap{installed = strings.clone(path), old_socket = pty_host_daemon_socket, old_started = pty_host_daemon_started}
	pty_host_daemon_socket, pty_host_daemon_started = s.installed, true
	return s
}

pty_host_test_restore_socket :: proc(s: Pty_Host_Test_Swap) {
	sync.mutex_lock(&pty_host_daemon_lock)
	defer sync.mutex_unlock(&pty_host_daemon_lock)
	pty_host_daemon_socket, pty_host_daemon_started = s.old_socket, s.old_started
	delete(s.installed)
}

@(test)
pty_host_test_fence_refuses_live_and_non_temp_paths :: proc(t: ^testing.T) {
	private_dir := bridge_os_private_dir_name()
	live := fmt.tprintf("/tmp/%s/229a79e7825cb2b6.sock", private_dir)
	testing.expect(t, !pty_host_test_socket_allowed(live), "live bridge private socket dir must be refused")
	testing.expect(t, !pty_host_test_socket_allowed("/home/u/.local/share/heimdall/bridges/b/run/pty-host.sock"), "data-dir run dir must be refused")
	testing.expect(t, !pty_host_test_socket_allowed("onfig.toml"), "relative/garbage path must be refused")
	testing.expect(t, !pty_host_test_socket_allowed(""), "empty path must be refused")
	testing.expect(t, pty_host_test_socket_allowed("/tmp/ham-fence-ok.sock"), "plain /tmp test socket allowed")
	testing.expect(t, pty_host_test_socket_allowed("unix:/tmp/ham-fence-ok.sock"), "unix: prefix is stripped")

	// The default path with an unconfigured bridge resolves under the scratch root.
	sync.mutex_lock(&bridge_test_config_mutex)
	saved := bridge_config
	bridge_config = {}
	def := pty_host_socket_path()
	bridge_config = saved
	sync.mutex_unlock(&bridge_test_config_mutex)
	defer delete(def)
	testing.expect(t, pty_host_test_socket_allowed(def), fmt.tprintf("default socket path must be test-safe: %s", def))
}

@(test)
pty_host_test_fence_blocks_dial_and_ensure_daemon :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	live := fmt.aprintf("/tmp/%s/229a79e7825cb2b6.sock", bridge_os_private_dir_name())
	defer delete(live)
	_, dial_ok := pty_host_dial(live)
	testing.expect(t, !dial_ok, "dial to a live private-dir socket must be refused under test")

	swap := pty_host_test_install_socket(live)
	defer pty_host_test_restore_socket(swap)
	sock, ok := bridge_pty_host_ensure_daemon()
	testing.expect(t, !ok && sock == "", "ensure_daemon must not ping/spawn at a live path under test")
}
