#+build !windows
package main

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"

// BR-2a tests: the pty-host daemon socket must be BRIDGE-UNIQUE so two bridges on
// one host (even with the DEFAULT run dir) get distinct sockets => distinct
// daemons => disjoint agent sets. These drive pty_host_socket_path/identity by
// mutating bridge_config (restoring it after) — no daemon needed.

// These tests mutate the global bridge_config, so they must not run concurrently
// with each other (the default test runner is multi-threaded). The shared
// bridge_test_config_mutex serializes them; each test also snapshots+restores the fields it touches.

// pty_host_socket_test_save snapshots the config fields these tests mutate.
Pty_Host_Socket_Test_Save :: struct {
	run_dir: string,
	daemon:  string,
	port:    u16,
}

pty_host_socket_test_snapshot :: proc() -> Pty_Host_Socket_Test_Save {
	return {bridge_config.local_endpoint_run_dir, bridge_config.daemon_id, bridge_config.local_endpoint_port}
}
pty_host_socket_test_restore :: proc(s: Pty_Host_Socket_Test_Save) {
	bridge_config.local_endpoint_run_dir = s.run_dir
	bridge_config.daemon_id = s.daemon
	bridge_config.local_endpoint_port = s.port
}

@(test)
pty_host_socket_differs_by_bridge_id_same_run_dir :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	save := pty_host_socket_test_snapshot()
	defer pty_host_socket_test_restore(save)

	// Both bridges use the DEFAULT run dir; only the bridge (daemon) id differs.
	bridge_config.local_endpoint_run_dir = "/tmp/heimdall-bridge-local"
	bridge_config.local_endpoint_port = 0

	bridge_config.daemon_id = "brg_aaa"
	a := pty_host_socket_path()
	defer delete(a)

	bridge_config.daemon_id = "brg_bbb"
	b := pty_host_socket_path()
	defer delete(b)

	testing.expect(t, a != b, "different bridge ids must yield different sockets on the same run dir")
	testing.expect(t, strings.contains(a, "brg_aaa"), "socket embeds bridge id a")
	testing.expect(t, strings.contains(b, "brg_bbb"), "socket embeds bridge id b")
	testing.expect(t, strings.has_suffix(a, ".sock"), "socket path ends .sock")
}

@(test)
pty_host_socket_stable_for_same_bridge_id :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	save := pty_host_socket_test_snapshot()
	defer pty_host_socket_test_restore(save)

	bridge_config.local_endpoint_run_dir = "/tmp/heimdall-bridge-local"
	bridge_config.daemon_id = "brg_stable"
	bridge_config.local_endpoint_port = 0

	a := pty_host_socket_path()
	defer delete(a)
	b := pty_host_socket_path()
	defer delete(b)
	testing.expect_value(t, a, b) // deterministic for the same identity
}

@(test)
pty_host_socket_falls_back_to_port_then_default :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	save := pty_host_socket_test_snapshot()
	defer pty_host_socket_test_restore(save)

	bridge_config.local_endpoint_run_dir = "/tmp/heimdall-bridge-local"

	// No real bridge id (default "local-daemon") + a port => port discriminates,
	// so two default-id bridges on different ports still differ.
	bridge_config.daemon_id = "local-daemon"
	bridge_config.local_endpoint_port = 49324
	p1 := pty_host_socket_path()
	defer delete(p1)
	testing.expect(t, strings.contains(p1, "port-49324"), "falls back to port discriminator")

	bridge_config.local_endpoint_port = 49325
	p2 := pty_host_socket_path()
	defer delete(p2)
	testing.expect(t, p1 != p2, "different ports => different sockets under default id")

	// No id and no port => a stable default (single unconfigured bridge).
	bridge_config.daemon_id = ""
	bridge_config.local_endpoint_port = 0
	d := pty_host_socket_path()
	defer delete(d)
	testing.expect(t, strings.contains(d, "pty-host-default.sock"), "last-resort default socket name")
}

@(test)
pty_host_socket_respects_custom_run_dir :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	save := pty_host_socket_test_snapshot()
	defer pty_host_socket_test_restore(save)

	bridge_config.local_endpoint_run_dir = "/var/run/heimdall-b1/"
	bridge_config.daemon_id = "brg_x"
	bridge_config.local_endpoint_port = 0
	p := pty_host_socket_path()
	defer delete(p)
	testing.expect_value(t, p, "/var/run/heimdall-b1/pty-host-brg_x.sock")
}

@(test)
pty_host_socket_bridge_directory_avoids_duplicate_identity :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	save := pty_host_socket_test_snapshot()
	defer pty_host_socket_test_restore(save)

	bridge_config.daemon_id = "brg_18d03379a7d6d47b"
	bridge_config.local_endpoint_run_dir = "/home/tanmay/.local/share/heimdall/bridges/brg_18d03379a7d6d47b/run/"
	p := pty_host_socket_path()
	defer delete(p)
	testing.expect_value(t, p, "/home/tanmay/.local/share/heimdall/bridges/brg_18d03379a7d6d47b/run/pty-host.sock")
	testing.expect(t, len(p) < 104, "installed socket must fit Linux and macOS limits")

	bridge_config.daemon_id = "brg_other"
	other := pty_host_socket_path()
	defer delete(other)
	testing.expect(t, other != p, "another bridge cannot adopt this directory's daemon")
}

@(test)
bridge_unix_socket_long_paths_bind_and_stay_distinct :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	save := pty_host_socket_test_snapshot()
	defer pty_host_socket_test_restore(save)

	base := strings.repeat("/very-long-runtime-directory", 8)
	defer delete(base)
	bridge_config.local_endpoint_run_dir = base
	bridge_config.daemon_id = "brg_one"
	pty := pty_host_socket_path()
	defer delete(pty)
	endpoint := bridge_local_endpoint_config_default(base, 49325)
	defer delete(endpoint.unix_socket_path)
	testing.expect(t, len(pty) <= 103 && len(endpoint.unix_socket_path) <= 103)
	testing.expect(t, pty != endpoint.unix_socket_path, "socket roles must remain distinct")
	bridge_config.daemon_id = "brg_two"
	other := pty_host_socket_path()
	defer delete(other)
	testing.expect(t, pty != other, "bridges sharing a directory must remain distinct")

	paths := []string{pty, endpoint.unix_socket_path}
	for path in paths {
		testing.expect(t, bridge_unix_socket_prepare_parent(path))
		fd := posix.socket(.UNIX, .STREAM)
		testing.expect(t, fd >= 0)
		if fd < 0 do continue
		addr: posix.sockaddr_un
		when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .NetBSD || ODIN_OS == .OpenBSD {
			addr.sun_len = c.uchar(size_of(addr))
		}
		addr.sun_family = .UNIX
		for i in 0..<len(path) do addr.sun_path[i] = c.char(path[i])
		cpath := strings.clone_to_cstring(path)
		_ = posix.unlink(cpath)
		testing.expect(t, posix.bind(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) == .OK)
		_ = posix.close(fd)
		_ = posix.unlink(cpath)
		delete(cpath)
	}
}

@(test)
bridge_unix_socket_byte_limit_and_shared_hash_vector :: proc(t: ^testing.T) {
	boundary := strings.repeat("a", 103)
	defer delete(boundary)
	short := bridge_unix_socket_bounded_path(boundary)
	defer delete(short)
	testing.expect_value(t, short, boundary)
	unicode := strings.repeat("é", 52)
	defer delete(unicode)
	p := bridge_unix_socket_bounded_path(unicode)
	defer delete(p)
	testing.expect(t, len(p) <= 103 && strings.has_prefix(p, "/tmp/heimdall-"), "limit counts UTF-8 bytes")
	long := strings.repeat("a", 104)
	defer delete(long)
	vector := bridge_unix_socket_bounded_path(long)
	defer delete(vector)
	expected := fmt.aprintf("/tmp/heimdall-%d/ddf64bd8caea7ded.sock", posix.geteuid())
	defer delete(expected)
	testing.expect_value(t, vector, expected)
}

@(test)
bridge_unix_socket_existing_parent_is_ready :: proc(t: ^testing.T) {
	testing.expect(t, bridge_unix_socket_prepare_parent("/tmp/bridge-parent-regression.sock"))
	testing.expect(t, bridge_unix_socket_prepare_parent("/tmp/bridge-parent-regression.sock"))
}
