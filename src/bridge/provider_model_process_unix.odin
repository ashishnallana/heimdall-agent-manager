#+build !windows
package main

import "core:os"
import "core:strings"
import "core:sys/posix"

// Give each metadata probe its own session, so cleanup also terminates CLI
// helpers. Prepare all strings/fds before fork; the child only uses syscalls.
bridge_model_process_start :: proc(desc: os.Process_Desc) -> (os.Process, bool) {
	if len(desc.command) == 0 do return {}, false
	args := make([]cstring, len(desc.command)+1, context.temp_allocator)
	for arg, i in desc.command do args[i] = strings.clone_to_cstring(arg, context.temp_allocator)
	env := make([]cstring, len(desc.env)+1, context.temp_allocator)
	for value, i in desc.env do env[i] = strings.clone_to_cstring(value, context.temp_allocator)
	cwd := strings.clone_to_cstring(desc.working_dir, context.temp_allocator)
	in_fd, out_fd := posix.FD(os.fd(desc.stdin)), posix.FD(os.fd(desc.stdout))
	pid := posix.fork()
	if pid < 0 do return {}, false
	if pid == 0 {
		if posix.setsid() < 0 do posix._exit(127)
		if posix.chdir(cwd) != .OK do posix._exit(127)
		null := posix.open("/dev/null", {.RDWR})
		if null < 0 do posix._exit(127)
		if posix.dup2(in_fd, posix.STDIN_FILENO) < 0 || posix.dup2(out_fd, posix.STDOUT_FILENO) < 0 || posix.dup2(null, posix.STDERR_FILENO) < 0 do posix._exit(127)
		if null > 2 do _ = posix.close(null)
		_ = posix.execve(args[0], raw_data(args), raw_data(env))
		posix._exit(127)
	}
	process, err := os.process_open(int(pid))
	if err != nil {
		_ = posix.kill(pid, .SIGKILL)
		status: i32
		for posix.waitpid(pid, &status, {}) < 0 && posix.errno() == .EINTR {}
		return {}, false
	}
	return process, true
}

bridge_model_process_kill :: proc(process: os.Process) {
	if process.pid <= 0 do return
	// Called before reaping, while this pid still belongs to our child.
	if process.pid > 0 && posix.getpgid(posix.pid_t(process.pid)) == posix.pid_t(process.pid) {
		_ = posix.kill(posix.pid_t(-process.pid), .SIGKILL)
	}
	_ = os.process_kill(process)
}
