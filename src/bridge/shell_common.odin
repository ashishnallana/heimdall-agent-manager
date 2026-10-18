package main

// Shared bridge-side shell-session state and output helpers.
//
// WHAT THIS FILE IS, now that it is not what its old name said. It used to be
// src/bridge/shell_cmd.odin, the home of the `agent.shell_cmd.exec` /
// `agent.shell_cmd.read` RPCs and the direct-child run path behind them.
// REQ-SHELL-7 DELETED that surface outright — the CLI group, the two RPCs, the
// hub's /agent-actions/shell-cmd/{report,list} routes and the whole shell_jobs
// stack they reported into. What survived is everything the REPLACEMENT path calls,
// which turned out to be over half the file, so the file was renamed rather than
// deleted:
//
//   * bridge_shell_session_map        — the one process-wide session map, shared by
//                                      every kind (run, shell, server).
//   * bridge_shell_run_wait_response  — the foreground block behind
//                                      `agent.shell.wait`, i.e. `ham-ctl shell run`.
//   * bridge_shell_data_dir           — the expanded data dir, owned by the caller.
//   * bridge_shell_tail / _page       — output truncation and paging, called by the
//                                      hub-driven log handler and the wait response.
//   * bridge_shell_output_dir / _path — where a session's captured stdout lives.
//   * bridge_shell_write_session_json — the session result shape.
//   * the bridge_shell_test_* seams   — used across the bridge shell suites.
//
// WHERE A RUN IS SPAWNED NOW: bridge_hub_handle_shell_start
// (src/bridge/hub_runtime_client.odin), through the pty-host daemon, for all three
// kinds. `ham-ctl shell run` reaches it by creating the session on the hub
// (POST /api/v1/bridges/{id}/shells) and then blocking on agent.shell.wait; there is
// no bridge-local exec RPC any more.
//
// THE RULES THE DELETED PATH USED TO CARRY, and who carries them now:
//   * capturing stdout = the child's stdout+stderr are redirected into
//     <data_dir>/shell_sessions/<session_id>.out at spawn time and that file is
//     streamed on demand. UNCHANGED — pty-host is handed the same tee path
//     (bridge_shell_output_path), under REQ-SHELL-8's retention window. Output is
//     never stored in the hub.
//   * backgrounding is EXPLICIT. The caller asks with `--bg`, or converts a live run
//     from the UI; there is no duration at which a foreground run silently becomes
//     something else. The 15s BRIDGE_SHELL_ASYNC_THRESHOLD rule was deleted by
//     REQ-SHELL-2 and is not coming back.
//   * ONLY a background run notifies. That decision now lives in the HUB
//     (REQ-SHELL-5 §1, shell_session_service.odin -> _shell_session_notify_run_finished)
//     rather than in a bridge-side reaper, because the hub is the side that owns a
//     session's background flag and the agent's conversation.

import "core:strings"
import "core:time"

// Hard cap for a run measured from spawn; exceeded -> SIGKILL the process group +
// status failed/killed. It bounds the PROCESS, not any call waiting on it, so a
// dropped waiter neither extends nor shortens it, and it applies equally to a
// foreground and a background run.
//
// It does NOT apply to kind=server sessions. A server is long-running by
// definition — capping it at 30 minutes would kill every dev server half an hour
// in. That is enforced by ARMING the watchdog for kind=Run only rather than by
// exempting servers: see bridge_shell_run_cap_start (src/bridge/shell_run_wait.odin),
// which is where the cap moved when the direct-child reaper that used to hold it was
// deleted, and whose arming decision is asserted directly in shell_run_wait_test.odin.
BRIDGE_SHELL_HARD_TIMEOUT :: 30 * time.Minute
// Output truncation: > THRESHOLD lines -> keep only the last KEEP lines.
BRIDGE_SHELL_TAIL_THRESHOLD :: 200
BRIDGE_SHELL_TAIL_KEEP :: 100

// Package-level session map. EVERY kind registers here — run, shell and server
// alike — and it is the bridge's only in-memory session state.
bridge_shell_session_map: Bridge_Shell_Session_Map

// bridge_shell_run_wait_response blocks on a live run and renders the result the
// FOREGROUND caller gets back. Reached through the agent.shell.wait local RPC, which
// is how `ham-ctl shell run` blocks on a hub-created run.
//
// Three shapes come out of it, and they are distinguishable by the caller:
//   finished      -> the full session result with exit_code and output.
//   backgrounded  -> {background:true, session_id}, byte-identical to what a
//                    background start returns, because that is exactly what the
//                    run now is.
//   timeout       -> the wait call's own ceiling elapsed. THE RUN IS UNAFFECTED
//                    (W2/W4): it keeps running, and the id in the response is how
//                    the caller re-reads or kills it.
bridge_shell_run_wait_response :: proc(request_id, session_id: string, timeout_ms := BRIDGE_SHELL_WAIT_DEFAULT_MS) -> string {
	w := bridge_shell_wait_register(session_id)
	// Unregistered on EVERY exit path by the waiting thread itself, which is what
	// leaves nothing behind when a caller walks away.
	defer bridge_shell_wait_unregister(session_id, w)

	outcome, _, _, _ := bridge_shell_wait_block(w, timeout_ms)

	if outcome == .Backgrounded {
		b := strings.builder_make()
		strings.write_string(&b, "{\"exec_id\":\"")
		bridge_local_write_json_string(&b, session_id)
		strings.write_string(&b, "\",\"session_id\":\"")
		bridge_local_write_json_string(&b, session_id)
		strings.write_string(&b, "\",\"status\":\"running\",\"background\":true,\"message\":\"Run was moved to the background; you will be notified when it finishes.\"}")
		return bridge_local_response_data(request_id, strings.to_string(b))
	}

	if outcome == .Timed_Out {
		b := strings.builder_make()
		strings.write_string(&b, "{\"exec_id\":\"")
		bridge_local_write_json_string(&b, session_id)
		strings.write_string(&b, "\",\"session_id\":\"")
		bridge_local_write_json_string(&b, session_id)
		strings.write_string(&b, "\",\"status\":\"running\",\"timed_out\":true,\"message\":\"Still running; the wait timed out but the run was not affected.\"}")
		return bridge_local_response_data(request_id, strings.to_string(b))
	}

	// Terminal. Read the final record back from the map rather than trusting the
	// values carried on the signal, so the response reflects what was actually
	// recorded (the reaper writes status/exit_code/timing under the map lock).
	snap, ok := bridge_shell_session_snapshot(&bridge_shell_session_map, session_id)
	if !ok do return bridge_local_response_error(request_id, "not_found", strings.concatenate({"no shell session with id ", session_id}))
	defer bridge_shell_session_snapshot_destroy(&bridge_shell_session_map, snap)

	// A run that has only just reached a terminal status cannot have been reclaimed
	// (retention needs five days), so .Available is the expected state here — but it
	// is still read through the one three-state reader rather than open-coding
	// "missing means empty", which is the behaviour REQ-SHELL-8 removes. A zero-byte
	// file is .Available and reports an honest empty log.
	output_str, out_state := bridge_shell_output_read(session_id)
	defer if out_state == .Available do delete(output_str)
	if out_state == .Reclaimed do return bridge_local_response_error(request_id, BRIDGE_SHELL_OUTPUT_RECLAIMED_CODE, BRIDGE_SHELL_OUTPUT_RECLAIMED_MESSAGE)

	// SANITISE BEFORE MEASURING AND BEFORE TAILING (REQ-SHELL-27). This is the
	// inline output of a FOREGROUND run — the default, and the most-read output
	// surface there is — so it carries the same PTY escapes and CRLF endings the
	// log path does. Read-time only; the tee file keeps the raw bytes.
	//
	// Before tailing, for the same reason grep is stripped before matching: the
	// 200-line threshold and the 100-line keep must count the lines a human sees
	// (CRLF and bare-\r redraws resolved), and a tail boundary must not be able to
	// land in the middle of an escape sequence and emit a `[0;32m` fragment.
	//
	// output_size_bytes is therefore the SANITISED length. The decision, since
	// either was defensible: that field sits in the same JSON object as the output
	// it describes, and its only consumer is whoever reads that response — grep
	// shows no comparison against a retention or truncation threshold anywhere, so
	// nothing depends on it matching the file on disk. A size that did not describe
	// the text actually delivered would be a wrong answer to the only question the
	// field is asked. Its contract is unchanged: full output vs. a truncated tail.
	sanitized := bridge_shell_sanitize_output(output_str)
	defer delete(sanitized)
	output_size := len(sanitized)
	tail, truncated := bridge_shell_tail(sanitized, BRIDGE_SHELL_TAIL_THRESHOLD, BRIDGE_SHELL_TAIL_KEEP)

	b := strings.builder_make()
	bridge_shell_write_session_json(&b, &snap, tail, truncated, output_size, true)
	return bridge_local_response_data(request_id, strings.to_string(b))
}

// bridge_shell_data_dir resolves the expanded data dir, defaulting as everywhere
// else in the bridge. The returned string is always owned by the caller (unlike
// bridge_expand_home, which aliases its input when there is no "~" to expand) so
// callers get one unconditional delete instead of a guarded one.
bridge_shell_data_dir :: proc() -> string {
	raw_dir := strings.trim_space(bridge_config.data_dir)
	if raw_dir == "" do raw_dir = "~/.local/share/heimdall"
	expanded := bridge_expand_home(raw_dir)
	if raw_data(expanded) != raw_data(raw_dir) do return expanded
	return strings.clone(expanded)
}

// bridge_shell_test_kill_pid terminates a process a test spawned, so a `sleep`
// left behind by a reconcile test does not outlive the suite. It kills the
// child's PROCESS GROUP only when that group is provably the child's own — the
// child called setsid, so getpgid(pid) == pid — and never a group that is also
// ours. kill(-pid) on anything else is either a no-op (ESRCH) or, if `pid` ever
// names the test runner's own group (a pid reused after the child was reaped,
// or a spawn that never reached setsid on a platform without it), a SIGKILL of
// the whole `odin test` process tree. That is the 137 the full src/bridge suite
// used to die with; the group kill now cannot reach anything but the child.
bridge_shell_test_kill_pid :: proc(pid: int) {
	if pid <= 0 do return
	bridge_os_test_kill_pid(pid)
}

// bridge_shell_test_wait_for_own_session blocks (up to `deadline`) until the
// spawned child has become its own session/process-group leader, i.e. `setsid`
// has run. Returns false if the child died first or never got there (Darwin
// spawns without setsid). Tests that will later group-kill the child wait on
// this so the kill can never precede the setsid.
bridge_shell_test_wait_for_own_session :: proc(pid: int, deadline := 2 * time.Second) -> bool {
	if pid <= 0 do return false
	start := time.tick_now()
	for time.tick_since(start) < deadline {
		leader, found := bridge_os_test_is_own_group_leader(pid)
		if !found do return false // gone (or not ours to query)
		if leader do return true
		time.sleep(2 * time.Millisecond)
	}
	return false
}

// bridge_shell_test_session_str clones a string from THE SESSION MAP'S allocator, for
// a test that builds a Bridge_Shell_Session by hand and hands it to
// bridge_shell_session_register.
//
// It exists because the map frees what it is given (REQ-SHELL-11), and under
// `odin test` context.allocator is a PER-TEST TRACKING ALLOCATOR while the map's is
// the process heap — so a plain strings.clone here would be freed through an
// allocator it never came from, which the tracking allocator reports as a bad free.
bridge_shell_test_session_str :: proc(str: string) -> string {
	return strings.clone(str, bridge_shell_session_map_allocator(&bridge_shell_session_map))
}

// bridge_shell_test_reset clears the session map (for tests).
bridge_shell_test_reset :: proc() {
	bridge_shell_session_map_reset(&bridge_shell_session_map)
	// REQ-SHELL-3: the pending kill-intent set is process-global too, so a test that
	// records one must not leak it into the next test's spawn path — where it would be
	// consumed and turn a healthy start into an immediate kill.
	bridge_shell_kill_intent_reset()
}

// ---- helpers -------------------------------------------------------------

// bridge_shell_write_session_json writes the rich exec-response object for a
// kind=Run session. exit_code and execution_time_ms are omitted while the
// session is still running; output/truncated are included only when
// include_output is set.
bridge_shell_write_session_json :: proc(b: ^strings.Builder, s: ^Bridge_Shell_Session, output_tail: string, truncated: bool, output_size: int, include_output: bool) {
	status_str := bridge_shell_session_exec_status_str(s)
	output_path := bridge_shell_output_path(s.session_id)
	defer delete(output_path)

	strings.write_string(b, "{\"exec_id\":\"")
	bridge_local_write_json_string(b, s.session_id)
	// session_id is the SAME value as exec_id, emitted under both names. `exec_id` is
	// VESTIGIAL: it was the retired exec surface's spelling, and every shell surface
	// that remains (create, kill, log, the wait RPC) speaks session_id. It is kept
	// rather than dropped because REQ-SHELL-7's remit is deleting the surface, not
	// reshaping the response REQ-SHELL-2 shipped and had reviewed — removing a field
	// is a separate, deliberate change. Nothing in src/ctl or src/ui reads it.
	strings.write_string(b, "\",\"session_id\":\"")
	bridge_local_write_json_string(b, s.session_id)
	strings.write_string(b, "\",\"status\":\"")
	bridge_local_write_json_string(b, status_str)
	strings.write_byte(b, '"')
	if s.status != .Running && s.status != .Starting {
		strings.write_string(b, ",\"exit_code\":")
		bridge_agent_write_int(b, s.exit_code)
		if s.finished_unix_ms > 0 {
			strings.write_string(b, ",\"execution_time_ms\":")
			bridge_agent_write_int(b, int(s.finished_unix_ms - s.started_unix_ms))
		}
	}
	strings.write_string(b, ",\"start_time\":\"")
	bridge_local_write_json_string(b, s.started_at)
	strings.write_string(b, "\",\"output_size_bytes\":")
	bridge_agent_write_int(b, output_size)
	strings.write_string(b, ",\"raw_output_location\":\"")
	bridge_local_write_json_string(b, output_path)
	strings.write_byte(b, '"')
	if include_output {
		strings.write_string(b, ",\"output\":\"")
		bridge_local_write_json_string(b, output_tail)
		strings.write_string(b, "\",\"truncated\":")
		if truncated {
			strings.write_string(b, "true")
		} else {
			strings.write_string(b, "false")
		}
	}
	strings.write_byte(b, '}')
}

// bridge_shell_tail returns the last `keep` lines of output when it exceeds
// `threshold` lines (truncated=true); otherwise it returns output unchanged
// (truncated=false). The returned string is a slice into `output` (no copy).
bridge_shell_tail :: proc(output: string, threshold, keep: int) -> (string, bool) {
	if keep <= 0 do return output, false
	total := 0
	for i in 0 ..< len(output) {
		if output[i] == '\n' do total += 1
	}
	if len(output) > 0 && output[len(output) - 1] != '\n' do total += 1
	if total <= threshold do return output, false

	// Walk backward, ignoring a single trailing newline, until we have passed
	// `keep` line boundaries; the content after that boundary is the last `keep`
	// lines.
	j := len(output) - 1
	if j >= 0 && output[j] == '\n' do j -= 1
	needed := keep
	for ; j >= 0; j -= 1 {
		if output[j] == '\n' {
			needed -= 1
			if needed == 0 do return output[j + 1:], true
		}
	}
	return output, true
}

// bridge_shell_page produces the output slice for `ham-ctl shell log` when any of the
// paging flags are set (REQ-25): it skips the first `offset` lines of the file,
// optionally keeps only lines containing `grep` (each prefixed with its original
// 1-based line number, grep -n style), and returns at most `limit` lines. A `limit`
// of <= 0 means "no cap". truncated is true when lines were skipped by the offset
// or candidate lines remain beyond the returned slice. The returned string is
// heap-allocated and owned by the caller. A single trailing newline is treated as a
// line terminator (not an extra empty line), matching bridge_shell_tail's counting.
bridge_shell_page :: proc(output: string, offset, limit: int, grep: string) -> (string, bool) {
	off := offset
	if off < 0 do off = 0
	no_limit := limit <= 0

	b := strings.builder_make()
	idx := 0 // index among candidate (post-grep) lines
	emitted := 0
	line_no := 0
	start := 0
	total := len(output)
	for i := 0; i <= total; i += 1 {
		at_end := i == total
		if !at_end && output[i] != '\n' do continue
		// A line spans [start, i). Skip the empty tail produced by a final newline.
		if !(at_end && start == i) {
			line := output[start:i]
			line_no += 1
			if grep == "" || strings.contains(line, grep) {
				if idx >= off && (no_limit || emitted < limit) {
					if grep != "" {
						strings.write_int(&b, line_no)
						strings.write_byte(&b, ':')
					}
					strings.write_string(&b, line)
					strings.write_byte(&b, '\n')
					emitted += 1
				}
				idx += 1
			}
		}
		start = i + 1
	}
	truncated := off > 0 || idx > off + emitted
	return strings.to_string(b), truncated
}

// bridge_shell_output_dir is where a session's captured output lives. It is the
// SAME directory REQ-SHELL-2 already owns for spawn specs — <data_dir>/shell_sessions
// — so one session's two on-disk artifacts (<id>.json and <id>.out) sit together
// under one name, and the retired "shell_jobs" concept is gone from the bridge's
// filesystem layout as well as from its code (REQ-SHELL-7 removes the name
// elsewhere). The two coexist safely: load_specs matches *.json and the retention
// sweep matches *.out, so neither can ever see the other's files.
//
// Sharing bridge_shell_session_spec_dir rather than re-deriving the path is what
// keeps that true — moving the spec directory now moves the output with it instead
// of silently splitting the pair across two locations.
bridge_shell_output_dir :: proc() -> string {
	data_dir := bridge_shell_data_dir()
	defer delete(data_dir)
	return bridge_shell_session_spec_dir(data_dir)
}

bridge_shell_output_path :: proc(session_id: string) -> string {
	dir := bridge_shell_output_dir()
	defer delete(dir)
	return strings.concatenate({dir, "/", session_id, BRIDGE_SHELL_OUTPUT_SUFFIX})
}

