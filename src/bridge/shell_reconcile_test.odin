package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

@(test)
test_shell_reconcile_extract_active_ids_hub_envelope :: proc(t: ^testing.T) {
	json_payload := `{"data":{"ok":true,"sessions":[` +
		`{"session_id":"sh_active_1","status":"running"},` +
		`{"session_id":"sh_active_2","status":"starting"},` +
		`{"session_id":"sh_stopped","status":"stopped"},` +
		`{"session_id":"sh_killed","status":"killed"},` +
		`{"session_id":"sh_failed","status":"failed"},` +
		`{"session_id":"sh_active_1","status":"running"}` + // duplicate test
		`],"next_cursor":"","has_more":false},"meta":{}}`

	active_ids, ok := bridge_shell_extract_active_ids(json_payload)
	testing.expect(t, ok, "extraction should succeed on valid Hub payload")
	defer bridge_shell_delete_active_ids(&active_ids)

	testing.expect(t, "sh_active_1" in active_ids, "sh_active_1 (running) should be active")
	testing.expect(t, "sh_active_2" in active_ids, "sh_active_2 (starting) should be active")
	testing.expect(t, !("sh_stopped" in active_ids), "sh_stopped should not be active")
	testing.expect(t, !("sh_killed" in active_ids), "sh_killed should not be active")
	testing.expect(t, !("sh_failed" in active_ids), "sh_failed should not be active")
	testing.expect(t, len(active_ids) == 2, "expected exactly 2 unique active IDs")
}

@(test)
test_shell_reconcile_extract_active_ids_alternative_envelopes :: proc(t: ^testing.T) {
	// Direct sessions object
	payload_sessions := `{"sessions":[{"session_id":"sh_sess_1","status":"running"}]}`
	ids1, ok1 := bridge_shell_extract_active_ids(payload_sessions)
	testing.expect(t, ok1, "direct sessions envelope should succeed")
	defer bridge_shell_delete_active_ids(&ids1)
	testing.expect(t, "sh_sess_1" in ids1, "sh_sess_1 should be extracted")

	// Direct data array
	payload_data_arr := `{"data":[{"session_id":"sh_data_1","status":"running"}]}`
	ids2, ok2 := bridge_shell_extract_active_ids(payload_data_arr)
	testing.expect(t, ok2, "direct data array should succeed")
	defer bridge_shell_delete_active_ids(&ids2)
	testing.expect(t, "sh_data_1" in ids2, "sh_data_1 should be extracted")

	// Raw array
	payload_raw_arr := `[{"session_id":"sh_raw_1","status":"running"}]`
	ids3, ok3 := bridge_shell_extract_active_ids(payload_raw_arr)
	testing.expect(t, ok3, "raw array should succeed")
	defer bridge_shell_delete_active_ids(&ids3)
	testing.expect(t, "sh_raw_1" in ids3, "sh_raw_1 should be extracted")
}

@(test)
test_shell_reconcile_extract_active_ids_invalid_json :: proc(t: ^testing.T) {
	_, ok1 := bridge_shell_extract_active_ids("not valid json")
	testing.expect(t, !ok1, "invalid json should fail safely")

	_, ok2 := bridge_shell_extract_active_ids(`{"ok":false}`)
	testing.expect(t, !ok2, "missing sessions/data should fail safely")

	_, ok3 := bridge_shell_extract_active_ids(`{"data":"not an array or object"}`)
	testing.expect(t, !ok3, "non-array non-object data should fail safely")
}

@(test)
test_shell_reconcile_filter_orphans :: proc(t: ^testing.T) {
	active_ids := make(map[string]bool)
	defer delete(active_ids)
	active_ids["sh_active_1"] = true
	active_ids["sh_active_2"] = true

	pty_agents := []Pty_Host_Agent_Info{
		// Agent instance sessions: MUST be ignored even if alive (handled by agent reaper)
		{instance_id = "inst_agent_1", alive = true},
		{instance_id = "inst_worker_42", alive = true},
		// Non-sh prefixes: MUST be ignored
		{instance_id = "sess_custom", alive = true},
		// Dead shell sessions: MUST be ignored
		{instance_id = "sh_dead_orphan", alive = false},
		{instance_id = "sh_dead_active", alive = false},
		// Active shells in Hub: MUST NOT be reaped
		{instance_id = "sh_active_1", alive = true},
		{instance_id = "sh_active_2", alive = true},
		// Orphans (live pty sessions starting with sh_ not in Hub active set): MUST be returned
		{instance_id = "sh_orphan_1", alive = true},
		{instance_id = "sh_orphan_2", alive = true},
	}

	orphans := bridge_shell_find_orphans(pty_agents, active_ids)
	defer {
		for id in orphans do delete(id)
		delete(orphans)
	}

	testing.expect(t, len(orphans) == 2, "expected exactly 2 orphans")

	has_orphan_1 := false
	has_orphan_2 := false
	for o in orphans {
		if o == "sh_orphan_1" do has_orphan_1 = true
		if o == "sh_orphan_2" do has_orphan_2 = true
		testing.expect(t, strings.has_prefix(o, "sh_"), "all orphans must have sh_ prefix")
		testing.expect(t, !strings.has_prefix(o, "inst_"), "orphans must never have inst_ prefix")
	}
	testing.expect(t, has_orphan_1, "sh_orphan_1 must be in orphans")
	testing.expect(t, has_orphan_2, "sh_orphan_2 must be in orphans")
}

@(test)
test_shell_reconcile_empty_active_hub :: proc(t: ^testing.T) {
	active_ids := make(map[string]bool)
	defer delete(active_ids)

	pty_agents := []Pty_Host_Agent_Info{
		{instance_id = "inst_agent_foo", alive = true},
		{instance_id = "sh_reap_orphan", alive = true},
	}

	orphans := bridge_shell_find_orphans(pty_agents, active_ids)
	defer {
		for id in orphans do delete(id)
		delete(orphans)
	}

	testing.expect(t, len(orphans) == 1, "expected 1 orphan when hub active set is empty")
	testing.expect(t, orphans[0] == "sh_reap_orphan", "expected sh_reap_orphan to be reaped")
}

@(test)
test_shell_reconcile_all_active_no_orphans :: proc(t: ^testing.T) {
	active_ids := make(map[string]bool)
	defer delete(active_ids)
	active_ids["sh_1"] = true
	active_ids["sh_2"] = true

	pty_agents := []Pty_Host_Agent_Info{
		{instance_id = "inst_1", alive = true},
		{instance_id = "sh_1", alive = true},
		{instance_id = "sh_2", alive = true},
	}

	orphans := bridge_shell_find_orphans(pty_agents, active_ids)
	defer {
		for id in orphans do delete(id)
		delete(orphans)
	}

	testing.expect(t, len(orphans) == 0, "expected 0 orphans when all shell sessions are active in hub")
}

// ---- REQ-BR-1: the exit sweep (shell_exit_sweep.odin) -------------------------
//
// The incident: the bridge's only event subscription stayed attached to a daemon that
// had been replaced, so ChildExited never arrived and runs stayed "running" on the hub
// forever. These drive the sweep against a FAKE roster and a FAKE pid probe, so they
// depend on neither a live daemon nor which pids exist on this host.

// exit_sweep_session builds a pty-host session the way the shell_start path registers
// one, with every string from the map's allocator (register takes ownership).
exit_sweep_session :: proc(session_id: string, status: Bridge_Shell_Session_Status, pid: int, exit_code := 0, exit_code_set := false) -> Bridge_Shell_Session {
	return Bridge_Shell_Session{
		session_id    = bridge_shell_test_session_str(session_id),
		kind          = .Run,
		cmd           = bridge_shell_test_session_str("sleep 600"),
		status        = status,
		pid           = pid,
		exit_code     = exit_code,
		exit_code_set = exit_code_set,
		run_seq       = 2,
		shell_id      = bridge_shell_test_session_str(session_id),
		started_at    = bridge_shell_test_session_str("2026-10-17T14:00:00Z"),
		pty_host      = true,
		pty_host_provenance_known = true,
	}
}

// exit_sweep_take_events removes every queued shell_exited frame for session_id from
// the outgoing queue (and its durable outbox file) and returns the frames, owned by
// the caller. Tests then assert on exactly what the hub would have been sent.
exit_sweep_take_events :: proc(session_id: string) -> [dynamic]string {
	out := make([dynamic]string)
	needle := fmt.aprintf(`"session_id":"%s"`, session_id)
	defer delete(needle)
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	i := 0
	for i < len(bridge_shell_exited_outgoing) {
		item := bridge_shell_exited_outgoing[i]
		if !strings.contains(item.event_json, needle) {
			i += 1
			continue
		}
		append(&out, item.event_json)
		if item.outbox_path != "" {
			_ = os.remove(item.outbox_path)
			delete(item.outbox_path)
		}
		ordered_remove(&bridge_shell_exited_outgoing, i)
	}
	return out
}

// exit_sweep_queue_init gives the process-global exit queue a HEAP backing before a
// test appends to it. Left nil (it is only made in bridge_hub_runtime_start), the first
// append would allocate it from this test's tracking allocator — reported as a leak
// here, and a bad free in whichever later test grows it.
exit_sweep_queue_init :: proc() {
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	if bridge_shell_exited_outgoing == nil {
		bridge_shell_exited_outgoing = make([dynamic]Bridge_Shell_Exited_Outgoing, runtime.heap_allocator())
	}
}

exit_sweep_events_delete :: proc(events: [dynamic]string) {
	for e in events do delete(e)
	delete(events)
}

exit_sweep_pid_dead :: proc(pid: int) -> bool { return false }
exit_sweep_pid_alive :: proc(pid: int) -> bool { return true }

@(private = "file")
exit_sweep_spec_path :: proc(dir, session_id: string) -> string {
	return strings.concatenate({dir, "/shell_sessions/", session_id, ".json"})
}

// A run the daemon reports EXITED, whose ChildExited never reached the bridge: the
// sweep finalizes it with the daemon's exit code through the ChildExited path — map
// terminal, spec gone, exactly one shell_exited enqueued — and a second sweep, or the
// late ChildExited itself, reports nothing more.
@(test)
bridge_br1_sweep_finalizes_a_run_the_daemon_reports_exited :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := fmt.aprintf("/tmp/ham-br1-exited-%d", os.get_pid())
	defer delete(dir)
	bridge_config.data_dir = dir
	exit_sweep_queue_init()

	sid := "sh_br1_exited"
	sess := exit_sweep_session(sid, .Running, 4_000_001)
	bridge_shell_session_save_spec(dir, sess)
	bridge_shell_session_register(&bridge_shell_session_map, &sess)
	spec := exit_sweep_spec_path(dir, sid)
	defer delete(spec)
	testing.expect(t, os.exists(spec), "precondition: the running session has a spec")

	roster := []Pty_Host_Agent_Info{
		{instance_id = "sh_someone_else", pid = 77, alive = true},
		{instance_id = sid, pid = 4_000_001, alive = false, has_exit_code = true, exit_code = 3},
	}
	exited, lost := bridge_shell_session_sweep(&bridge_shell_session_map, roster, dir, exit_sweep_pid_alive)
	testing.expect_value(t, exited, 1)
	testing.expect_value(t, lost, 0)

	sc, found := bridge_shell_session_scalars(&bridge_shell_session_map, sid)
	testing.expect(t, found, "the session is still known")
	testing.expect_value(t, sc.status, Bridge_Shell_Session_Status.Exited)
	testing.expect_value(t, sc.exit_code, 3)
	testing.expect(t, sc.exit_code_set, "the daemon's exit code is recorded")
	testing.expect(t, !os.exists(spec), "the spec is cleared, as ChildExited does")

	events := exit_sweep_take_events(sid)
	defer exit_sweep_events_delete(events)
	testing.expect_value(t, len(events), 1)
	if len(events) == 1 {
		testing.expect(t, strings.contains(events[0], `"exit_code":3`), "the hub is told the real exit code")
		testing.expect(t, strings.contains(events[0], `"status":"exited"`), "status exited")
		testing.expect(t, strings.contains(events[0], `"run_seq":2`), "for the session's current run")
	}

	// Idempotent: a second sweep and the late ChildExited both report nothing more.
	exited, lost = bridge_shell_session_sweep(&bridge_shell_session_map, roster, dir, exit_sweep_pid_alive)
	testing.expect_value(t, exited + lost, 0)
	testing.expect(t, !bridge_shell_session_finalize_exit(&bridge_shell_session_map, sid, 3, true, dir), "a late ChildExited is a no-op")
	again := exit_sweep_take_events(sid)
	defer exit_sweep_events_delete(again)
	testing.expect_value(t, len(again), 0)
}

// A run the daemon does not know at all — what a run spawned on a REPLACED daemon
// looks like — is finalized only when its pid is provably gone, as "exited" with NO
// exit_code key (nobody observed one; the hub keys exit_code_set on the key's
// presence). With the pid alive it is left running: absence alone proves nothing.
@(test)
bridge_br1_sweep_finalizes_an_unknown_run_only_when_its_pid_is_gone :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := fmt.aprintf("/tmp/ham-br1-lost-%d", os.get_pid())
	defer delete(dir)
	bridge_config.data_dir = dir
	exit_sweep_queue_init()

	sid := "sh_br1_lost"
	sess := exit_sweep_session(sid, .Running, 4_000_002)
	bridge_shell_session_save_spec(dir, sess)
	bridge_shell_session_register(&bridge_shell_session_map, &sess)
	spec := exit_sweep_spec_path(dir, sid)
	defer delete(spec)

	roster := []Pty_Host_Agent_Info{{instance_id = "sh_other", pid = 5, alive = true}}

	// pid alive: untouched.
	exited, lost := bridge_shell_session_sweep(&bridge_shell_session_map, roster, dir, exit_sweep_pid_alive)
	testing.expect_value(t, exited + lost, 0)
	sc, _ := bridge_shell_session_scalars(&bridge_shell_session_map, sid)
	testing.expect_value(t, sc.status, Bridge_Shell_Session_Status.Running)
	none := exit_sweep_take_events(sid)
	testing.expect_value(t, len(none), 0)
	exit_sweep_events_delete(none)

	// pid gone: finalized as lost.
	exited, lost = bridge_shell_session_sweep(&bridge_shell_session_map, roster, dir, exit_sweep_pid_dead)
	testing.expect_value(t, exited, 0)
	testing.expect_value(t, lost, 1)
	sc, _ = bridge_shell_session_scalars(&bridge_shell_session_map, sid)
	testing.expect_value(t, sc.status, Bridge_Shell_Session_Status.Exited)
	testing.expect(t, !sc.exit_code_set, "no exit code was observed, so none is recorded")
	testing.expect(t, !os.exists(spec), "the spec is cleared")

	events := exit_sweep_take_events(sid)
	defer exit_sweep_events_delete(events)
	testing.expect_value(t, len(events), 1)
	if len(events) == 1 {
		testing.expect(t, strings.contains(events[0], `"status":"exited"`), "status exited")
		testing.expect(t, !strings.contains(events[0], `"exit_code":`), "no exit_code key, so the hub does not record a clean exit")
	}
}

// Only sessions whose exit is still unreported are swept: terminal ones, direct
// children (never in the roster) and a run whose exit was already reported are left
// alone, so the sweep can never double-report or touch what it cannot judge.
@(test)
bridge_br1_sweep_skips_what_it_must_not_touch :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := fmt.aprintf("/tmp/ham-br1-skip-%d", os.get_pid())
	defer delete(dir)
	bridge_config.data_dir = dir
	exit_sweep_queue_init()

	failed := exit_sweep_session("sh_br1_failed", .Failed, 4_000_003, 1, true)
	bridge_shell_session_register(&bridge_shell_session_map, &failed)
	direct := exit_sweep_session("sh_br1_direct", .Running, 4_000_004)
	direct.pty_host = false
	bridge_shell_session_register(&bridge_shell_session_map, &direct)
	reported := exit_sweep_session("sh_br1_killed_done", .Killed, 4_000_005, 137, true)
	bridge_shell_session_register(&bridge_shell_session_map, &reported)

	exited, lost := bridge_shell_session_sweep(&bridge_shell_session_map, nil, dir, exit_sweep_pid_dead)
	testing.expect_value(t, exited + lost, 0)
	for sid in ([]string{"sh_br1_failed", "sh_br1_direct", "sh_br1_killed_done"}) {
		events := exit_sweep_take_events(sid)
		testing.expectf(t, len(events) == 0, "%s must not be reported", sid)
		exit_sweep_events_delete(events)
	}
}
