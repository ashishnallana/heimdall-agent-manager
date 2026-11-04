package main

import "core:fmt"
import "core:os"
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

// Helpers for pty_host_test_socket_allowed (kept in a _test file so non-test and
// Windows builds never reference bridge_os_real_path).
// pty_host_test_path_within is a component-boundary containment check: "/tmpx" is
// not within "/tmp".
pty_host_test_path_within :: proc(path, root: string) -> bool {
	if path == root do return true
	prefix := root if strings.has_suffix(root, "/") else strings.concatenate({root, "/"}, context.temp_allocator)
	return strings.has_prefix(path, prefix)
}

// pty_host_test_resolve_path canonicalises an absolute path: realpath(3) on the
// longest existing prefix (symlinks, "." and ".." resolved by the kernel view), then
// the not-yet-existing tail appended. A tail containing "." or ".." is refused.
// Temp-allocated.
pty_host_test_resolve_path :: proc(path: string) -> (string, bool) {
	trimmed := strings.trim_right(path, "/")
	if trimmed == "" do return "/", true
	prefix := trimmed
	tail := ""
	for {
		if real, ok := bridge_os_real_path(prefix); ok {
			if tail == "" do return real, true
			for part in strings.split(tail, "/", context.temp_allocator) {
				if part == "." || part == ".." do return "", false
			}
			base := strings.trim_right(real, "/")
			parts := make([dynamic]string, context.temp_allocator)
			for part in strings.split(tail, "/", context.temp_allocator) {
				if part != "" do append(&parts, part)
			}
			return strings.concatenate({base, "/", strings.join(parts[:], "/", context.temp_allocator)}, context.temp_allocator), true
		}
		slash := strings.last_index_byte(prefix, '/')
		if slash <= 0 do return "", false
		tail = strings.concatenate({prefix[slash+1:], "/", tail} if tail != "" else {prefix[slash+1:]}, context.temp_allocator)
		prefix = strings.trim_right(prefix[:slash], "/")
		if prefix == "" do prefix = "/"
	}
}

@(test)
pty_host_test_fence_uses_containment_not_prefixes :: proc(t: ^testing.T) {
	private_dir := bridge_os_private_dir_name()
	scratch := bridge_scratch_root(context.temp_allocator)
	bad := []string{
		"/tmp/../run/non-test.sock",
		"/tmp/./../etc/x.sock",
		fmt.tprintf("/tmp/%s/../%s/229a.sock", private_dir, private_dir),
		fmt.tprintf("/tmp//%s//229a.sock", private_dir),
		fmt.tprintf("/tmp/./%s/229a.sock", private_dir),
		fmt.tprintf("%s/../%s/229a.sock", scratch, private_dir),
		"/tmpx/sibling.sock",
		"/home/u/.local/share/heimdall/bridges/b/run/pty-host.sock",
	}
	for p in bad {
		testing.expect(t, !pty_host_test_socket_allowed(p), fmt.tprintf("must be refused: %s", p))
	}
	testing.expect(t, pty_host_test_socket_allowed("/tmp//ham-fence-ok.sock"), "repeated separators inside /tmp stay allowed")
	testing.expect(t, pty_host_test_socket_allowed("/tmp/ham-nonexistent-dir/ham.sock"), "nonexistent tail under /tmp allowed")
}

@(test)
pty_host_test_fence_resolves_symlink_aliases :: proc(t: ^testing.T) {
	// Independent of $HOME: the symlink target is a dedicated directory that is
	// itself outside every allowed root (HOME may be under /tmp in isolated runs).
	target: string
	for base in ([]string{"/var/tmp", "/dev/shm", "/run/user"}) {
		if !os.is_dir(base) do continue
		// Skip a base the fence allows (e.g. TMPDIR=/var/tmp): it would not be "outside".
		if pty_host_test_socket_allowed(fmt.tprintf("%s/ham-fence-probe.sock", base)) do continue
		candidate := fmt.tprintf("%s/ham-fence-target-%d", base, os.get_pid())
		if os.make_directory(candidate) == nil {
			target = candidate
			break
		}
	}
	if target == "" {
		fmt.eprintln("skip: no writable directory outside the fenced roots")
		return
	}
	defer os.remove(target)
	link := fmt.tprintf("/tmp/ham-fence-link-%d", os.get_pid())
	defer os.remove(link)
	if !testing.expect(t, os.symlink(target, link) == nil, "symlink setup") do return
	// A path that is lexically inside /tmp but resolves outside it must be refused.
	testing.expect(t, !pty_host_test_socket_allowed(fmt.tprintf("%s/anything.sock", link)), "symlink escaping /tmp must be refused")
	testing.expect(t, !pty_host_test_socket_allowed(fmt.tprintf("%s/.local/share/heimdall/x.sock", link)), "symlink into a data-dir-shaped path must be refused")

	// Control: a symlink to a real directory inside /tmp stays allowed.
	inside := fmt.tprintf("/tmp/ham-fence-inside-%d", os.get_pid())
	inside_link := fmt.tprintf("/tmp/ham-fence-inside-link-%d", os.get_pid())
	defer os.remove(inside)
	defer os.remove(inside_link)
	if os.make_directory(inside) == nil && os.symlink(inside, inside_link) == nil {
		testing.expect(t, pty_host_test_socket_allowed(fmt.tprintf("%s/ok.sock", inside_link)), "symlink within /tmp is allowed")
	}
}

@(test)
pty_host_test_fence_blocks_deadline_request :: proc(t: ^testing.T) {
	live := fmt.tprintf("/tmp/%s/229a79e7825cb2b6.sock", bridge_os_private_dir_name())
	request := []byte{0}
	_, ok := pty_host_request_deadline(live, request, 50)
	testing.expect(t, !ok, "deadline request to a live private-dir socket must be refused under test")
	_, ok = pty_host_request_deadline("unix:/tmp/../run/x.sock", request, 50)
	testing.expect(t, !ok, "deadline request via dot segments must be refused")
}
