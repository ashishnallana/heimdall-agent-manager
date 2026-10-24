package main

import "core:os"
import "core:strings"
import "core:time"

CTL_INSTALL_OUTPUT_LIMIT :: 1024 * 1024

ctl_default_install_runner :: proc(args: []string, timeout: time.Duration, allocator := context.temp_allocator) -> (stdout, stderr: string, exit_code: int, ok: bool) {
	out, err_out, code, success, timed_out := ctl_run_install_process(args, timeout, allocator)
	if timed_out {
		delete(err_out, allocator)
		err_out = strings.clone("extension installation timed out", allocator)
	}
	return out, err_out, code, success
}

ctl_install_drain_pipe :: proc(file: ^os.File, output: ^[dynamic]byte) -> (read_any: bool, open: bool) {
	if file == nil do return false, false
	ready, ready_err := os.pipe_has_data(file)
	if ready_err != nil do return false, false
	if !ready do return false, true
	buf: [8192]byte
	n, read_err := os.read(file, buf[:])
	if read_err != nil || n <= 0 do return false, false
	remaining := CTL_INSTALL_OUTPUT_LIMIT - len(output)
	if remaining > 0 {
		keep := min(n, remaining)
		append(output, ..buf[:keep])
	}
	return true, true
}

// Executes argv without a shell, drains stdout/stderr while it runs, and always
// kills+reaps on deadline. Returned strings belong to context.allocator. An exit
// code of -1 means the child could not be started or did not produce an exit
// status before it was killed.
ctl_run_install_process :: proc(args: []string, timeout: time.Duration, allocator := context.temp_allocator) -> (stdout, stderr: string, exit_code: int, ok, timed_out: bool) {
	exit_code = -1
	if len(args) == 0 || timeout <= 0 do return "", "", exit_code, false, false
	stdout_r, stdout_w, stdout_pipe_err := os.pipe()
	if stdout_pipe_err != nil do return "", "", exit_code, false, false
	defer os.close(stdout_r)
	stderr_r, stderr_w, stderr_pipe_err := os.pipe()
	if stderr_pipe_err != nil {
		_ = os.close(stdout_w)
		return "", "", exit_code, false, false
	}
	defer os.close(stderr_r)

	process, start_err := os.process_start(os.Process_Desc{command = args, stdout = stdout_w, stderr = stderr_w})
	_ = os.close(stdout_w)
	_ = os.close(stderr_w)
	if start_err != nil do return "", "", exit_code, false, false

	out_bytes := make([dynamic]byte, 0, 8192)
	err_bytes := make([dynamic]byte, 0, 4096)
	defer { delete(out_bytes); delete(err_bytes) }
	deadline := time.time_add(time.now(), timeout)
	state: os.Process_State
	exited := false
	for !exited {
		out_read, _ := ctl_install_drain_pipe(stdout_r, &out_bytes)
		err_read, _ := ctl_install_drain_pipe(stderr_r, &err_bytes)
		if current, wait_err := os.process_wait(process, 0); wait_err == nil {
			state = current
			exited = true
			break
		}
		if time.diff(time.now(), deadline) <= 0 {
			timed_out = true
			_ = os.process_kill(process)
			state, _ = os.process_wait(process, 500 * time.Millisecond)
			exited = true
			break
		}
		if !out_read && !err_read do time.sleep(5 * time.Millisecond)
	}
	// Child write ends are closed after exit. Drain any final buffered bytes without
	// blocking; output beyond the cap is deliberately discarded but still drained.
	for {
		out_read, _ := ctl_install_drain_pipe(stdout_r, &out_bytes)
		err_read, _ := ctl_install_drain_pipe(stderr_r, &err_bytes)
		if !out_read && !err_read do break
	}
	stdout = strings.clone(string(out_bytes[:]), allocator)
	stderr = strings.clone(string(err_bytes[:]), allocator)
	if state.exited do exit_code = state.exit_code
	return stdout, stderr, exit_code, !timed_out && state.exited && state.success, timed_out
}
