#+build !windows
package main

// The bridge's POSIX-only process, file and host calls. Each proc here has a twin
// with the same signature in os_platform_windows.odin; everything that calls them
// is shared.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

// Child processes must never inherit the bridge's listeners. In particular,
// ham-pty-host intentionally outlives individual agents; inheriting these fds
// would keep the bridge ports bound after launchd stops the bridge and make the
// replacement process fail with Address_In_Use.
bridge_os_socket_close_on_exec :: proc(socket: i64) -> bool {
	fd := posix.FD(socket)
	flags := posix.fcntl(fd, .GETFD)
	return flags >= 0 && posix.fcntl(fd, .SETFD, flags | i32(posix.FD_CLOEXEC)) != -1
}

// bridge_os_terminate asks pid to exit (SIGTERM).
bridge_os_terminate :: proc(pid: int) -> bool {
	return posix.kill(posix.pid_t(pid), .SIGTERM) == .OK
}

// bridge_os_kill ends pid unconditionally (SIGKILL).
bridge_os_kill :: proc(pid: int) -> bool {
	return posix.kill(posix.pid_t(pid), .SIGKILL) == .OK
}

// bridge_os_pid_alive: only ESRCH proves pid gone; EPERM means it exists under
// another uid. See bridge_shell_pid_alive for why "alive" is the safe answer.
bridge_os_pid_alive :: proc(pid: int) -> bool {
	if posix.kill(posix.pid_t(pid), posix.Signal(0)) == .OK do return true
	return posix.errno() != .ESRCH
}

// bridge_os_process_lstart_and_command returns the start time and command line of
// pid as `ps` reports them. Force C locale and UTC timezone so the lstart format is
// predictable and in UTC on both Linux and macOS.
bridge_os_process_lstart_and_command :: proc(pid: int) -> (start_unix_sec: i64, command: string, ok: bool) {
	ps_cmd := fmt.tprintf("TZ=UTC LC_ALL=C ps -p %d -o lstart=,command= 2>/dev/null", pid)
	c_ps_cmd := strings.clone_to_cstring(ps_cmd)
	defer delete(c_ps_cmd)
	f := posix.popen(c_ps_cmd, "r")
	if f == nil do return 0, "", false
	defer posix.pclose(f)

	buf: [512]byte
	n := posix.fread(&buf, 1, size_of(buf) - 1, f)
	if n == 0 do return 0, "", false
	output := strings.trim_space(string(buf[:n]))
	if len(output) < 25 do return 0, "", false  // at minimum lstart (24) + space + 1 char

	// lstart is fixed 24 chars in C locale ("Www Mmm DD HH:MM:SS YYYY").
	lstart_sec, lstart_ok := bridge_shell_session_parse_lstart(output[:24])
	if !lstart_ok do return 0, "", false
	return lstart_sec, strings.clone(strings.trim_space(output[24:]), context.temp_allocator), true
}

// bridge_os_exe_base reduces a command line to its executable's base name.
bridge_os_exe_base :: proc(command: string) -> string {
	exe := command
	if i := strings.index_byte(exe, ' '); i >= 0 do exe = exe[:i]
	if i := strings.last_index_byte(exe, '/'); i >= 0 do exe = exe[i+1:]
	return exe
}

bridge_os_disk_free :: proc(path: string) -> (free_bytes: i64, ok: bool) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	vfs: posix.statvfs_t
	if posix.statvfs(cpath, &vfs) != .OK do return 0, false
	return i64(vfs.f_bavail) * i64(vfs.f_frsize), true
}

// bridge_os_hostname is gethostname(2), "" on failure.
bridge_os_hostname :: proc(allocator := context.allocator) -> string {
	buf: [256]byte
	if posix.gethostname(cast([^]byte)(&buf[0]), len(buf) - 1) != .OK do return ""
	end := 0
	for end < len(buf) && buf[end] != 0 do end += 1
	name := strings.trim_space(string(buf[:end]))
	if name == "" do return ""
	return strings.clone(name, allocator)
}

// bridge_os_user_name reads the passwd database for the real uid, "" on failure.
bridge_os_user_name :: proc(allocator := context.allocator) -> string {
	pw := posix.getpwuid(posix.getuid())
	if pw == nil || pw.pw_name == nil do return ""
	name := strings.trim_space(string(pw.pw_name))
	if name == "" do return ""
	return strings.clone(name, allocator)
}

// bridge_os_release is uname(2)'s release, "" on failure.
bridge_os_release :: proc(allocator := context.allocator) -> string {
	uts: posix.utsname
	if posix.uname(&uts) != 0 do return ""
	end := 0
	for end < len(uts.release) && uts.release[end] != 0 do end += 1
	return strings.clone(strings.trim_space(string(transmute([]byte)(uts.release[:end]))), allocator)
}

bridge_os_uid :: proc() -> int {
	return int(posix.getuid())
}

// bridge_os_make_owner_executable sets mode 0700 (owner rwx).
bridge_os_make_owner_executable :: proc(path: string) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	_ = posix.chmod(cpath, posix.mode_t{.IRUSR, .IWUSR, .IXUSR})
}

bridge_os_remove_file :: proc(path: string) {
	_ = posix.unlink(strings.clone_to_cstring(path, context.temp_allocator))
}

// bridge_os_create_exclusive writes content to a NEW owner-only (0600) file.
// O_EXCL: two racing writers must not interleave, and a file that appeared
// meanwhile reports existed = true.
bridge_os_create_exclusive :: proc(path, content: string) -> (written: bool, existed: bool) {
	c_path := strings.clone_to_cstring(path)
	defer delete(c_path)
	fd := posix.open(c_path, {.WRONLY, .CREAT, .EXCL, .CLOEXEC}, {.IRUSR, .IWUSR})
	if fd < 0 do return false, posix.errno() == .EEXIST
	defer posix.close(fd)
	return posix.write(fd, raw_data(content), uint(len(content))) == len(content), false
}

// bridge_os_socket_file_identity stats a socket path; a daemon that re-created its
// socket shows up as a different identity. ok=false when nothing is there.
bridge_os_socket_file_identity :: proc(path: string) -> (Pty_Host_Daemon_Identity, bool) {
	cpath := strings.clone_to_cstring(path)
	defer delete(cpath)
	st: posix.stat_t
	if posix.stat(cpath, &st) != .OK do return {}, false
	return Pty_Host_Daemon_Identity{
		dev        = u64(st.st_dev),
		ino        = u64(st.st_ino),
		ctime_sec  = i64(st.st_ctim.tv_sec),
		ctime_nsec = i64(st.st_ctim.tv_nsec),
	}, true
}

// bridge_os_private_dir_name is the per-user directory under the scratch root that
// holds sockets whose natural path is too long ("heimdall-<euid>").
bridge_os_private_dir_name :: proc() -> string {
	return fmt.tprintf("heimdall-%d", posix.geteuid())
}

// bridge_os_dir_exists is stat + S_ISDIR (follows symlinks: a configured run dir
// may legitimately be one).
bridge_os_dir_exists :: proc(dir: string) -> bool {
	cdir := strings.clone_to_cstring(dir)
	defer delete(cdir)
	info: posix.stat_t
	return posix.stat(cdir, &info) == .OK && posix.S_ISDIR(info.st_mode)
}

// bridge_os_prepare_private_dir creates dir owner-only (0700) and rejects a
// pre-existing symlink, a non-directory, or a directory owned by another user.
bridge_os_prepare_private_dir :: proc(dir: string) -> bool {
	cdir := strings.clone_to_cstring(dir)
	defer delete(cdir)
	_ = posix.mkdir(cdir, posix.mode_t{.IRUSR, .IWUSR, .IXUSR})
	info: posix.stat_t
	if posix.lstat(cdir, &info) != .OK || !posix.S_ISDIR(info.st_mode) || info.st_uid != posix.geteuid() do return false
	return posix.chmod(cdir, posix.mode_t{.IRUSR, .IWUSR, .IXUSR}) == .OK
}

// ---- test-only process helpers (see shell_common.odin) ----

// bridge_os_test_kill_pid kills the child's PROCESS GROUP only when that group is
// provably the child's own -- the child called setsid, so getpgid(pid) == pid --
// and never a group that is also ours. kill(-pid) on anything else is either a
// no-op (ESRCH) or, if `pid` ever names the test runner's own group (a pid reused
// after the child was reaped, or a spawn that never reached setsid on a platform
// without it), a SIGKILL of the whole `odin test` process tree.
bridge_os_test_kill_pid :: proc(pid: int) {
	own_pgid := posix.getpgid(0)
	child_pgid := posix.getpgid(posix.pid_t(pid))
	if child_pgid > 0 && int(child_pgid) == pid && child_pgid != own_pgid {
		_ = posix.kill(posix.pid_t(-i32(pid)), .SIGKILL)
	}
	_ = posix.kill(posix.pid_t(pid), .SIGKILL)
}

// bridge_os_test_is_own_group_leader: getpgid(pid) == pid. found=false once the
// process is gone (or not ours to query).
bridge_os_test_is_own_group_leader :: proc(pid: int) -> (leader: bool, found: bool) {
	pgid := posix.getpgid(posix.pid_t(pid))
	if pgid <= 0 do return false, false
	return int(pgid) == pid, true
}


// ---- executables, PATH and the system shell ----

BRIDGE_PATH_LIST_SEPARATOR :: ':'

// bridge_os_executable_names lists the file names `name` may have on disk.
bridge_os_executable_names :: proc(name: string) -> []string {
	names := make([]string, 1, context.temp_allocator)
	names[0] = name
	return names
}

// bridge_os_path_is_explicit: a value naming a file rather than a PATH lookup.
bridge_os_path_is_explicit :: proc(value: string) -> bool {
	return strings.contains(value, "/")
}

// bridge_os_default_shell is the interactive shell: $SHELL, else /bin/sh.
bridge_os_default_shell :: proc() -> string {
	shell_env := os.get_env("SHELL", context.temp_allocator)
	return shell_env if len(shell_env) > 0 else "/bin/sh"
}

// bridge_os_shell_argv runs a command line through the system shell.
bridge_os_shell_argv :: proc(cmd: string) -> []string {
	argv := make([]string, 3, context.temp_allocator)
	argv[0], argv[1], argv[2] = "sh", "-c", cmd
	return argv
}

// bridge_os_ps lists every process as `ps -A -o pid=,ppid=,rss=,<cpu>=,args=`
// rows (rss in KiB; cpu is cputime or %cpu per `cpu`).
bridge_os_ps :: proc(cpu: Bridge_Ps_Cpu_Column, allocator := context.allocator) -> (output: string, ok: bool) {
	cols := "pid=,ppid=,rss=,cputime=,args=" if cpu == .Cputime else "pid=,ppid=,rss=,%cpu=,args="
	cmd := [?]string{"ps", "-A", "-o", cols}
	state, stdout, stderr, err := os.process_exec(os.Process_Desc{command = cmd[:], env = []string{"LC_ALL=C"}}, allocator)
	if len(stderr) > 0 do delete(stderr, allocator)
	if err != nil || !state.success {
		if len(stdout) > 0 do delete(stdout, allocator)
		return "", false
	}
	return string(stdout), true
}

// ---- self-update ----

BRIDGE_EXE_SUFFIX :: ""
BRIDGE_UPDATE_SUPERVISOR_NAME :: "apply-bridge-update.sh"

// bridge_os_supervisor_argv starts the update supervisor script; the caller
// appends the script's --flags.
bridge_os_supervisor_argv :: proc(script: string) -> [dynamic]string {
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, "bash", script)
	return argv
}

// BRIDGE_UPDATE_SPAWN_DETACHES: bridge_os_spawn_new_session puts the child in a
// session of its own, so the supervisor is told --already-detached.
BRIDGE_UPDATE_SPAWN_DETACHES :: true

// bridge_os_reexec replaces this process with argv (argv[0] an absolute path),
// keeping its pid, session and environment (the tray relaunching itself after an
// update). Returns only when execv failed.
bridge_os_reexec :: proc(argv: []string) -> bool {
	if len(argv) == 0 do return false
	c_argv := make([]cstring, len(argv) + 1, context.temp_allocator)
	for arg, i in argv do c_argv[i] = strings.clone_to_cstring(arg, context.temp_allocator)
	posix.execv(c_argv[0], raw_data(c_argv))
	return false
}

// bridge_os_spawn_new_session starts argv (argv[0] resolved through PATH like
// execvp) as the leader of a new session and process group, with stdio on
// /dev/null, and does not wait for it. setsid(2) runs in the forked child, which
// is never a group leader, so it cannot fail with EPERM; this replaces setsid(1),
// which macOS does not ship. Everything the child touches is prepared before
// fork, so the child only calls async-signal-safe functions. Returns false when
// the fork fails or the child cannot setsid/exec (it reports errno through a
// close-on-exec pipe, as core:os process_start does).
bridge_os_spawn_new_session :: proc(argv: []string) -> bool {
	if len(argv) == 0 do return false
	exe := argv[0]
	if strings.index_byte(exe, '/') < 0 {
		found := false
		for dir in strings.split(os.get_env("PATH", context.temp_allocator), ":", context.temp_allocator) {
			if dir == "" do continue
			candidate := fmt.tprintf("%s/%s", dir, exe)
			if bridge_os_is_executable(candidate) && os.is_file(candidate) {
				exe = candidate
				found = true
				break
			}
		}
		if !found do return false
	}
	c_exe := strings.clone_to_cstring(exe, context.temp_allocator)
	c_argv := make([]cstring, len(argv) + 1, context.temp_allocator)
	for arg, i in argv do c_argv[i] = strings.clone_to_cstring(arg, context.temp_allocator)

	READ :: 0
	WRITE :: 1
	report: [2]posix.FD
	if posix.pipe(&report) != .OK do return false
	defer posix.close(report[READ])
	if posix.fcntl(report[READ], .SETFD, i32(posix.FD_CLOEXEC)) == -1 || posix.fcntl(report[WRITE], .SETFD, i32(posix.FD_CLOEXEC)) == -1 {
		posix.close(report[WRITE])
		return false
	}

	pid := posix.fork()
	switch pid {
	case -1:
		posix.close(report[WRITE])
		return false
	case 0:
		fail :: proc(fd: posix.FD) -> ! {
			errno := u8(posix.errno())
			posix.write(fd, &errno, 1)
			posix._exit(127)
		}
		if posix.setsid() == -1 do fail(report[WRITE])
		null := posix.open("/dev/null", {.RDWR})
		if null == -1 do fail(report[WRITE])
		if posix.dup2(null, posix.STDIN_FILENO) == -1 do fail(report[WRITE])
		if posix.dup2(null, posix.STDOUT_FILENO) == -1 do fail(report[WRITE])
		if posix.dup2(null, posix.STDERR_FILENO) == -1 do fail(report[WRITE])
		if null > posix.STDERR_FILENO do posix.close(null)
		posix.execve(c_exe, raw_data(c_argv), posix.environ)
		fail(report[WRITE])
	}

	posix.close(report[WRITE])
	// EOF means execve closed the pipe: the child is running the supervisor.
	child_errno: u8
	for {
		n := posix.read(report[READ], &child_errno, 1)
		if n == -1 && posix.errno() == .EINTR do continue
		if n != 1 do return true
		break
	}
	status: i32
	for posix.waitpid(pid, &status, {}) == -1 && posix.errno() == .EINTR {}
	return false
}

bridge_os_default_data_dir :: proc() -> string {
	return bridge_expand_home("~/.local/share/heimdall")
}

// bridge_os_is_executable is access(2) X_OK.
bridge_os_is_executable :: proc(path: string) -> bool {
	c_path := strings.clone_to_cstring(path, context.temp_allocator)
	return posix.access(c_path, {.X_OK}) == .OK
}
