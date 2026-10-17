package main

// REQ-BR-1 / REQ-BR-2: never leave a pty-host run "running" after its process is gone.
//
// The ONLY thing that used to move a pty-host session to a terminal status was the
// daemon's ChildExited event, delivered on the bridge's single WatchEvents connection.
// When that connection silently stopped receiving (it stayed attached to a daemon whose
// listener had died while a replacement daemon took over the socket), every exit was
// lost: the session stayed Running in the map, no shell_exited reached the hub, and the
// UI showed the run with a spinner and Background/Kill forever. A kill could not help
// either — the daemon refused to signal a pid it had already reaped, and that refusal
// was only logged.
//
// This file is the safety net. One entry point, bridge_shell_session_sweep_one, decides
// whether a single session's process is gone, and every caller goes through it:
//
//   periodic sweep    — bridge_shell_session_sweep_now, every SHELL_EXIT_SWEEP_INTERVAL
//   hub reconnect     — bridge_shell_session_reconcile_now, before its spec pass
//   events re-dial    — after the event watcher follows a replaced daemon (REQ-BR-3)
//   refused kill      — bridge_shell_kill_resolve_refused (REQ-BR-2)
//
// and every finalization goes through bridge_shell_session_finalize_exit, the same path
// ChildExited takes, so the hub sees exactly what it would have seen had the event
// arrived. The exit claim inside it (Bridge_Shell_Session.exit_reported) makes all of
// these safe to race the real event: the first reports, the rest no-op.

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

SHELL_EXIT_SWEEP_INTERVAL :: 30 * time.Second

// Bridge_Shell_Sweep_Outcome says what bridge_shell_session_sweep_one did.
Bridge_Shell_Sweep_Outcome :: enum {
	Untouched, // alive, not a candidate, already reported, or not provably dead
	Exited,    // the daemon reported it exited; finalized with the daemon's exit code
	Lost,      // the daemon does not know it and its pid is gone; finalized without a code
}

// Bridge_Shell_Pid_Alive_Proc is the liveness seam for the "daemon does not know it"
// branch. Production uses bridge_shell_pid_alive; tests pass a fake so they never
// depend on which pids happen to exist on the host.
Bridge_Shell_Pid_Alive_Proc :: #type proc(pid: int) -> bool

// bridge_shell_pid_alive reports whether pid may still be a live process. Only ESRCH
// proves it gone: EPERM means it exists under another uid, and a pid we do not know
// (<= 0) proves nothing — both answer "alive", because finalizing a live run is the
// worse mistake (the next sweep gets another chance at a dead one).
bridge_shell_pid_alive :: proc(pid: int) -> bool {
	if pid <= 0 do return true
	if posix.kill(posix.pid_t(pid), posix.Signal(0)) == .OK do return true
	return posix.errno() != .ESRCH
}

// bridge_shell_session_is_sweep_candidate: a pty-host session whose exit the hub has
// not been told about yet. That is a live status, or .Killed with no exit code — the
// state bridge_shell_kill_arm leaves while it waits for ChildExited to report the kill.
// Every path that has already reported an exit leaves exit_code_set=true or
// exit_reported=true, so a reported session is never picked up again.
//
// Direct-child (pty_host=false) sessions are excluded: they are never in the daemon's
// roster, and bridge_shell_session_reconcile_direct_child owns them.
bridge_shell_session_is_sweep_candidate :: proc(sc: Bridge_Shell_Session_Scalars) -> bool {
	if !sc.pty_host || sc.exit_reported do return false
	switch sc.status {
	case .Starting, .Running: return true
	case .Killed:             return !sc.exit_code_set
	case .Exited, .Failed:    return false
	}
	return false
}

// bridge_shell_session_claim_exit atomically moves a session to its terminal status
// and marks its exit reported. ok=false means there is nothing to report: the session
// is gone, or another path (ChildExited, a sweep, a refused kill) already claimed this
// run's exit. A session the kill path marked .Killed stays .Killed so the exit is
// reported as a kill; anything else becomes .Exited — the ChildExited mapping.
bridge_shell_session_claim_exit :: proc(m: ^Bridge_Shell_Session_Map, session_id: string, exit_code: int, exit_code_set: bool) -> (final_status: Bridge_Shell_Session_Status, run_seq: int, ok: bool) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	s, found := &m.sessions[session_id]
	if !found || s.exit_reported do return {}, 0, false
	final_status = .Killed if s.status == .Killed else .Exited
	s.status = final_status
	s.exit_code = exit_code
	s.exit_code_set = exit_code_set
	s.exit_reported = true
	if s.finished_unix_ms == 0 do s.finished_unix_ms = bridge_now_unix_ms()
	return final_status, s.run_seq, true
}

// bridge_shell_session_finalize_exit is THE exit path for a pty-host session, shared
// by ChildExited (bridge_pty_host_apply_child_exited) and every safety-net caller in
// this file: claim the exit, drop the crash-recovery spec, release a foreground waiter,
// and enqueue shell_exited for the hub. exit_code_set=false is the "lost" case — the
// process is gone and nobody observed its status — and the event then omits exit_code
// rather than inventing one (see bridge_shell_exited_event_json).
//
// Returns false when the exit was already claimed; nothing is emitted then.
bridge_shell_session_finalize_exit :: proc(m: ^Bridge_Shell_Session_Map, session_id: string, exit_code: int, exit_code_set: bool, data_dir: string) -> bool {
	final_status, run_seq, claimed := bridge_shell_session_claim_exit(m, session_id, exit_code, exit_code_set)
	if !claimed do return false
	status_str := "killed" if final_status == .Killed else "exited"
	bridge_shell_session_delete_spec(data_dir, session_id)
	// REQ-SHELL-2 (W3): ONE exit event, TWO independent consumers. This releases a
	// blocked FOREGROUND caller waiting on the session; the enqueue below is the hub
	// notification path and must never be starved or replaced by the local waiter.
	// The map already says terminal (claim above), which the released waiter re-reads.
	bridge_shell_wait_signal_exit(session_id, final_status, exit_code, exit_code_set)
	event := bridge_shell_exited_event_json(session_id, exit_code, exit_code_set, status_str, run_seq)
	defer delete(event)
	bridge_shell_exited_enqueue(event)
	return true
}

// bridge_shell_session_sweep_one decides ONE session against a daemon roster:
//
//   not a candidate                         -> Untouched
//   in the roster, alive                    -> Untouched
//   in the roster, exited                   -> Exited (the daemon's exit code)
//   not in the roster, pid provably gone    -> Lost   (no exit code)
//   not in the roster, pid alive or unknown -> Untouched
//
// The last row is deliberate. "Not in this daemon's roster" is exactly what a run
// spawned on a PREVIOUS daemon looks like while it is still running, so absence alone
// never finalizes anything; only a dead pid does. Status choice for Lost: "exited"
// (or "killed" for a kill already armed) with no exit code — both statuses the hub
// already accepts from shell_exited, so no wire or hub change is needed; "failed" would
// claim a failure nobody observed.
bridge_shell_session_sweep_one :: proc(m: ^Bridge_Shell_Session_Map, session_id: string, daemon_agents: []Pty_Host_Agent_Info, data_dir: string, pid_alive: Bridge_Shell_Pid_Alive_Proc = bridge_shell_pid_alive) -> Bridge_Shell_Sweep_Outcome {
	sc, ok := bridge_shell_session_scalars(m, session_id)
	if !ok || !bridge_shell_session_is_sweep_candidate(sc) do return .Untouched
	key, have_key := bridge_shell_session_shell_id(m, session_id)
	if !have_key do return .Untouched
	defer bridge_shell_session_str_delete(m, key)

	for d in daemon_agents {
		if d.instance_id != key do continue
		if d.alive do return .Untouched
		if bridge_shell_session_finalize_exit(m, session_id, int(d.exit_code), d.has_exit_code, data_dir) {
			fmt.println("bridge shell sweep: finalized", session_id, "— the daemon reports it exited; its ChildExited was never received")
			return .Exited
		}
		return .Untouched
	}
	if pid_alive(sc.pid) do return .Untouched
	if bridge_shell_session_finalize_exit(m, session_id, 0, false, data_dir) {
		fmt.println("bridge shell sweep: finalized", session_id, "as lost — the daemon does not know it and pid", sc.pid, "is gone")
		return .Lost
	}
	return .Untouched
}

// bridge_shell_session_sweep_candidate_ids returns owned clones (context.allocator) of
// every candidate's session_id. The ids are copied out under the lock and decided
// afterwards, so finalizing — which takes the lock itself and does file I/O — never
// runs with the map locked.
bridge_shell_session_sweep_candidate_ids :: proc(m: ^Bridge_Shell_Session_Map) -> [dynamic]string {
	ids := make([dynamic]string)
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	for id, s in m.sessions {
		sc := Bridge_Shell_Session_Scalars{status = s.status, exit_code_set = s.exit_code_set, pty_host = s.pty_host, exit_reported = s.exit_reported}
		if bridge_shell_session_is_sweep_candidate(sc) do append(&ids, strings.clone(id))
	}
	return ids
}

bridge_shell_session_sweep_ids_delete :: proc(ids: [dynamic]string) {
	for id in ids do delete(id)
	delete(ids)
}

// bridge_shell_session_sweep runs sweep_one over every candidate in the map.
bridge_shell_session_sweep :: proc(m: ^Bridge_Shell_Session_Map, daemon_agents: []Pty_Host_Agent_Info, data_dir: string, pid_alive: Bridge_Shell_Pid_Alive_Proc = bridge_shell_pid_alive) -> (exited, lost: int) {
	ids := bridge_shell_session_sweep_candidate_ids(m)
	defer bridge_shell_session_sweep_ids_delete(ids)
	for id in ids {
		switch bridge_shell_session_sweep_one(m, id, daemon_agents, data_dir, pid_alive) {
		case .Exited:    exited += 1
		case .Lost:      lost += 1
		case .Untouched:
		}
	}
	return
}

// bridge_shell_session_sweep_now is the periodic/on-demand entry point: read the
// daemon roster and sweep the live map against it. Shares the reconcile single-flight
// gate. Cheap when idle: with no candidate it returns before touching the daemon, so
// a quiet bridge never starts a daemon just to sweep an empty map.
//
// If the roster cannot be read nothing is touched — without it a live run and a dead
// one look the same, and the pid rule alone cannot tell "exited" from "lost".
bridge_shell_session_sweep_now :: proc() {
	if !bridge_shell_reconcile_try_begin() do return
	defer bridge_shell_reconcile_end()

	ids := bridge_shell_session_sweep_candidate_ids(&bridge_shell_session_map)
	none := len(ids) == 0
	bridge_shell_session_sweep_ids_delete(ids)
	if none do return

	data_dir := bridge_shell_data_dir()
	defer delete(data_dir)
	socket, sock_ok := bridge_pty_host_ensure_daemon()
	if !sock_ok do return
	reply, list_ok := bridge_pty_host_list(socket)
	if !list_ok do return
	defer pty_host_reply_delete(reply)
	if exited, lost := bridge_shell_session_sweep(&bridge_shell_session_map, reply.agents, data_dir); exited + lost > 0 {
		fmt.println("bridge shell sweep: finalized", exited, "exited and", lost, "lost session(s) whose exit was never received")
	}
}

@(private = "file")
_shell_exit_sweep_started: bool
@(private = "file")
_shell_exit_sweep_mu: sync.Mutex

// bridge_shell_session_sweep_ensure_started starts the periodic sweep thread once
// (idempotent). Before this the only safety net was the reconcile on hub reconnect,
// so a bridge with a healthy hub link never noticed a lost exit at all.
bridge_shell_session_sweep_ensure_started :: proc() {
	sync.mutex_lock(&_shell_exit_sweep_mu)
	defer sync.mutex_unlock(&_shell_exit_sweep_mu)
	if _shell_exit_sweep_started do return
	_shell_exit_sweep_started = true
	thread.run(proc() {
		for {
			time.sleep(SHELL_EXIT_SWEEP_INTERVAL)
			bridge_shell_session_sweep_now()
		}
	})
}

// bridge_shell_kill_resolve_refused is REQ-BR-2: the daemon refused to signal a
// session we are killing. The usual reason is that the process is already gone — the
// daemon reaped it and its ChildExited never reached us — and then the kill can never
// complete and nothing else will ever report the session. Decide it against the
// roster exactly like the sweep does; the session is .Killed by now, so a finalized
// session is reported to the hub as "killed". Returns true when it was finalized.
bridge_shell_kill_resolve_refused :: proc(m: ^Bridge_Shell_Session_Map, session_id: string, daemon_agents: []Pty_Host_Agent_Info, data_dir: string, pid_alive: Bridge_Shell_Pid_Alive_Proc = bridge_shell_pid_alive) -> bool {
	outcome := bridge_shell_session_sweep_one(m, session_id, daemon_agents, data_dir, pid_alive)
	if outcome == .Untouched do return false
	fmt.println("bridge shell_kill: refused kill resolved —", session_id, "was already gone; reported as", outcome)
	return true
}
