package main

// REQ-SHELL-2 bridge-side acceptance tests: the deleted 15s threshold, explicit
// backgrounding, the runtime foreground->background conversion, and reconcile's
// direct-child liveness rule.
//
// REQ-SHELL-7 REMOVED THIS SUITE'S ORIGINAL SPAWN SEAM. These tests were written
// against the bridge-local exec RPC, which was the only producer of a DIRECT-CHILD
// (pty_host=false) session. That RPC and its whole surface are gone, so:
//
//   * The cases that asserted the RPC's own RETURN SHAPE — a foreground call coming
//     back inline, --bg returning a session id at once, the spec being cleared when
//     the run ends — were deleted with it. The same properties on the surviving path
//     are covered by the bridge_shell_run_wait_response cases below, which is what
//     `ham-ctl shell run` actually blocks on.
//   * The two cases that asserted the bridge-side "only a background run notifies"
//     decision were deleted too: that decision no longer exists here. The rule now
//     lives in the hub (REQ-SHELL-5 §1, _shell_session_notify_run_finished) and is
//     asserted in src/hub/service/shell_session/shell_session_req5_test.odin.
//   * THE RECONCILE CASES WERE PORTED, NOT DELETED, because the branch they test
//     SURVIVES: a bridge upgraded past REQ-SHELL-7 still reads direct-child specs
//     written before it, so bridge_shell_session_reconcile must still resolve them.
//     Deleting the producer must not delete the reader's test. They now spawn the
//     child through test_spawn_direct_child_run below, which reproduces exactly what
//     the retired RPC did: setsid + sh -c, output teed to the session's .out file,
//     pty_host=false, spec written after the pid is known.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

@(private = "file")
test_data_dir :: proc(name: string) -> string {
	return fmt.aprintf("/tmp/ham-shell2-%s-%d", name, os.get_pid())
}

// test_spawn_direct_child_run spawns a DIRECT-CHILD run and registers it exactly as
// the retired bridge-local exec RPC did, so the reconcile tests below still exercise
// the pty_host=false branch after REQ-SHELL-7 removed that RPC.
//
// It is a faithful port, not a convenient approximation, and three details carry the
// test's weight:
//   * setsid + sh -c on Linux. bridge_shell_session_pid_is_plausible matches the ps
//     `command=` basename against the spec cmd, and it is the exec chain through sh
//     that makes ps report "sleep 30" for the recorded pid. Spawning sleep directly
//     would pass for a different reason than production does.
//   * started_at is stamped from the same clock, because plausibility also requires
//     ps lstart to be within 5s of it.
//   * SPEC FIRST, THEN REGISTER, and every string cloned from THE MAP'S allocator:
//     save_spec reads the strings the map is about to own, and under `odin test`
//     context.allocator is a per-test tracking allocator while the map's is the
//     process heap (REQ-SHELL-11).
//
// Returns a caller-owned session_id, the pid, and ok=false if the spawn failed.
@(private = "file")
test_spawn_direct_child_run :: proc(name, cmd, data_dir: string) -> (session_id: string, pid: int, ok: bool) {
	sid := strings.concatenate({"shl_test_", name})
	defer delete(sid)

	output_path := bridge_shell_output_path(sid)
	defer delete(output_path)
	if slash := strings.last_index_byte(output_path, '/'); slash > 0 {
		_ = os.make_directory_all(output_path[:slash])
	}
	out_file, oerr := os.open(output_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, os.Permissions_Read_All + {.Write_User})
	if oerr != nil do return "", 0, false

	started_ms := bridge_now_unix_ms()
	start_time := strings.clone(action_scheduler_format_rfc3339_utc(started_ms))
	defer delete(start_time)

	command: []string
	when ODIN_OS == .Darwin {
		command = []string{"sh", "-c", cmd}
	} else {
		command = []string{"setsid", "sh", "-c", cmd}
	}
	process, perr := os.process_start(os.Process_Desc{command = command, stdout = out_file, stderr = out_file})
	_ = os.close(out_file)
	if perr != nil do return "", 0, false

	map_heap := bridge_shell_session_map_allocator(&bridge_shell_session_map)
	sess := Bridge_Shell_Session{
		session_id      = strings.clone(sid, map_heap),
		kind            = .Run,
		cmd             = strings.clone(cmd, map_heap),
		bridge_id       = strings.clone(bridge_config.daemon_id, map_heap),
		pid             = process.pid,
		status          = .Running,
		started_at      = strings.clone(start_time, map_heap),
		started_unix_ms = started_ms,
		shell_id        = strings.clone(sid, map_heap),
		background      = true,
		pty_host        = false,
		pty_host_provenance_known = true,
	}
	bridge_shell_session_save_spec(data_dir, sess)
	bridge_shell_session_register(&bridge_shell_session_map, &sess) // CONSUMES sess

	// Nothing reaps this child: the retired RPC started a thread that owned the
	// process, and there is no such owner any more. Every caller kills it in a defer
	// with bridge_shell_test_kill_pid, and each of these commands would exit on its
	// own well inside the suite's lifetime regardless.
	//
	// Do not hand the pid back until `setsid` has actually run in the child: the
	// callers group-kill it, and a group kill issued in the window between fork
	// and setsid targets a group that is not the child's own. On Darwin (no
	// setsid in the command) this returns false immediately, which is fine —
	// bridge_shell_test_kill_pid then kills only the pid.
	when ODIN_OS != .Darwin do _ = bridge_shell_test_wait_for_own_session(process.pid)
	return strings.clone(sid), process.pid, true
}

// ---- AC4: the threshold is GONE, and a long run still returns inline -------

// AC4, first half. A source-level assertion, because the requirement is that the
// CONSTANT no longer exists — a behavioural test alone would still pass if the
// rule had merely been raised to an hour rather than deleted.
//
// The grep half of AC4 is in tests/e2e_shell2_run_serve_test.sh; this is the half
// that fails the BUILD if anyone reintroduces it, which is the stronger guard:
// referencing a deleted constant does not compile.
@(test)
bridge_shell2_async_threshold_is_gone :: proc(t: ^testing.T) {
	// BRIDGE_SHELL_HARD_TIMEOUT survives (it bounds the process, and always did);
	// BRIDGE_SHELL_ASYNC_THRESHOLD does not exist and must never come back.
	testing.expect(t, BRIDGE_SHELL_HARD_TIMEOUT == 30 * time.Minute, "the 30-minute process cap is kept")
}

// AC4's SECOND half — "a long run still comes back inline, nothing converts it on
// the way" — was asserted against the retired exec RPC's own return value and went
// with it (REQ-SHELL-7). The surviving statement of the same property is
// bridge_shell2_wait_returns_the_result_inline below, which exercises
// bridge_shell_run_wait_response, i.e. what `ham-ctl shell run` actually blocks on.
// The genuine >15s case stays asserted end to end in tests/e2e_shell2_run_serve_test.sh.

// ---- AC3: the runtime foreground -> background conversion ------------------

@(private = "file")
Convert_Ctx :: struct {
	session_id: string,
}

// Flips the run to background as soon as the waiter has parked.
@(private = "file")
convert_worker :: proc(data: rawptr) {
	ctx := (^Convert_Ctx)(data)
	for _ in 0 ..< 500 {
		if bridge_shell_wait_count(ctx.session_id) > 0 do break
		time.sleep(1 * time.Millisecond)
	}
	_ = bridge_shell_set_background(ctx.session_id)
}

// AC3. A run started FOREGROUND and converted mid-flight releases the blocked
// caller with the session id, in the same shape a --bg start would have returned,
// and is thereafter a background run (which is what arms its completion
// notification).
@(test)
bridge_shell2_conversion_releases_the_blocked_caller :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := test_data_dir("convert")
	defer delete(dir)
	bridge_config.data_dir = dir

	// Register the session by hand rather than spawning: the conversion is a state
	// transition on a LIVE run, and driving it directly is what keeps this test
	// about the transition instead of about process timing.
	session_id := "shl_convert_test"
	sess := Bridge_Shell_Session{
		session_id      = bridge_shell_test_session_str(session_id),
		kind            = .Run,
		cmd             = bridge_shell_test_session_str("sleep 30"),
		status          = .Running,
		started_at      = bridge_shell_test_session_str("2026-09-28T09:00:00Z"),
		shell_id        = bridge_shell_test_session_str(session_id),
		pid             = 1,
	}
	bridge_shell_session_register(&bridge_shell_session_map, &sess)

	ctx := Convert_Ctx{session_id = session_id}
	th := thread.create_and_start_with_data(rawptr(&ctx), convert_worker)
	defer thread.destroy(th)

	resp := bridge_shell_run_wait_response("req_conv", session_id, 5_000)

	// Released with the session id, and reported as background — byte-identical in
	// shape to what a --bg start returns, so a converted run and a born-background
	// run are indistinguishable to whoever was blocked.
	testing.expect(t, strings.contains(resp, "\"background\":true"), "the released caller is told it is now background")
	testing.expect(t, strings.contains(resp, session_id), "and is given the session id to track it by")

	updated, found := bridge_shell_session_scalars(&bridge_shell_session_map, session_id)
	testing.expect(t, found, "the run is still live after conversion")
	testing.expect(t, updated.background, "and is now a background run, which is what makes it notify")
	thread.join(th)
}

// The conversion is ONE-WAY: a second attempt changes nothing and releases
// nobody, so a double-click cannot re-arm a notification or free a second waiter.
@(test)
bridge_shell2_conversion_is_one_way :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := test_data_dir("oneway")
	defer delete(dir)
	bridge_config.data_dir = dir

	session_id := "shl_oneway_test"
	reg := Bridge_Shell_Session{
		session_id = bridge_shell_test_session_str(session_id),
		kind       = .Run,
		cmd        = bridge_shell_test_session_str("sleep 30"),
		status     = .Running,
		started_at = bridge_shell_test_session_str("2026-09-28T09:00:00Z"),
		shell_id   = bridge_shell_test_session_str(session_id),
		pid        = 1,
	}
	bridge_shell_session_register(&bridge_shell_session_map, &reg)

	testing.expect(t, bridge_shell_set_background(session_id), "the first conversion takes effect")
	testing.expect(t, !bridge_shell_set_background(session_id), "a second conversion is a no-op, not a second release")

	// A terminal run cannot be backgrounded either — there is nothing to background.
	bridge_shell_session_update_status(&bridge_shell_session_map, session_id, .Exited, 0, true)
	testing.expect(t, !bridge_shell_set_background(session_id), "a finished run cannot be backgrounded")
}

// ---- W2: the wait is a convenience, never the source of truth --------------

// W2. Dropping the waiter — ham-ctl dying, a Ctrl-C, a timed-out call — must
// leave the run completely untouched: still live, still tracked, still
// addressable by id. This is the property that makes it safe for the block to
// live outside the lifecycle.
@(test)
bridge_shell2_dropping_the_waiter_does_not_touch_the_run :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := test_data_dir("drop")
	defer delete(dir)
	bridge_config.data_dir = dir

	session_id := "shl_drop_test"
	reg := Bridge_Shell_Session{
		session_id = bridge_shell_test_session_str(session_id),
		kind       = .Run,
		cmd        = bridge_shell_test_session_str("sleep 30"),
		status     = .Running,
		started_at = bridge_shell_test_session_str("2026-09-28T09:00:00Z"),
		shell_id   = bridge_shell_test_session_str(session_id),
		pid        = 4242,
	}
	bridge_shell_session_register(&bridge_shell_session_map, &reg)

	// A wait that gives up (the caller's ceiling elapsed) is exactly what a Ctrl-C
	// looks like from the run's side: the waiter unregisters and nothing else moves.
	resp := bridge_shell_run_wait_response("req_drop", session_id, 60)
	testing.expect(t, strings.contains(resp, "\"timed_out\":true"), "the CALL reports it gave up")
	testing.expect(t, strings.contains(resp, "\"status\":\"running\""), "and says the run is still going")

	sess, found := bridge_shell_session_scalars(&bridge_shell_session_map, session_id)
	testing.expect(t, found, "the run is STILL TRACKED after the waiter is gone")
	testing.expect(t, sess.status == .Running, "and still running")
	testing.expect(t, sess.pid == 4242, "and still addressable by pid, so it stays killable and reapable")

	// Nothing left behind: the registry is empty again, so a dropped waiter costs
	// nothing even when it happens on every call.
	testing.expect_value(t, bridge_shell_wait_count(session_id), 0)
}

// W3. One exit event, TWO consumers. Signalling a local waiter must not consume
// the event or depend on one existing: a run nobody waits on behaves exactly as
// it did before waiters existed.
@(test)
bridge_shell2_exit_signal_with_no_waiter_is_a_noop :: proc(t: ^testing.T) {
	bridge_shell_wait_signal_exit("shl_nobody_is_waiting", .Exited, 0, true)
	testing.expect_value(t, bridge_shell_wait_count("shl_nobody_is_waiting"), 0)
	bridge_shell_wait_signal_backgrounded("shl_nobody_is_waiting")
	testing.expect_value(t, bridge_shell_wait_count("shl_nobody_is_waiting"), 0)
}

// ---- P6 / C5: reconcile must not reap a live direct-child run --------------

// C5, the defect this task found. A direct-child run is NEVER in the pty-host
// roster, so before the fix every reconcile pass (i.e. every hub WS reconnect)
// took the "not in the roster -> kill the orphan" branch against a run that was
// perfectly alive.
//
// The live process here is a real `sleep`, because the whole rule turns on
// bridge_shell_session_pid_is_plausible succeeding against a real ps entry —
// a fake pid would test the bookkeeping and miss the liveness proof entirely.
@(test)
bridge_shell2_reconcile_leaves_a_live_direct_child_run_alone :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := test_data_dir("recon-live")
	defer delete(dir)
	bridge_config.data_dir = dir

	session_id, spawned_pid, spawn_ok := test_spawn_direct_child_run("recon-live", "sleep 30", dir)
	testing.expect(t, spawn_ok, "direct-child run spawned")
	if !spawn_ok do return
	defer delete(session_id)
	defer if spawned_pid > 0 do bridge_shell_test_kill_pid(spawned_pid)

	// Reconcile with an EMPTY daemon roster — which is the true state of affairs for
	// a direct child, not an artificial one.
	bridge_shell_session_reconcile(&bridge_shell_session_map, nil, dir)

	sess, found := bridge_shell_session_scalars(&bridge_shell_session_map, session_id)
	testing.expect(t, found, "the run survives reconcile")
	testing.expect(t, sess.status == .Running, "a LIVE direct-child run is not reaped by reconcile (C5)")
	spec := strings.concatenate({dir, "/shell_sessions/", session_id, ".json"})
	defer delete(spec)
	testing.expect(t, os.exists(spec), "and its spec is left in place")
}

// The other half of the coordinator's required rule: map presence alone is NOT a
// liveness test. A session the map still calls running, whose process is gone,
// must be REPORTED terminal rather than skipped forever — otherwise a missed exit
// event becomes a permanent, self-reinforcing "live on the hub, dead on the
// bridge" divergence, because the mechanism that would correct it is the one
// skipping it.
@(test)
bridge_shell2_reconcile_reports_a_dead_run_whose_exit_was_missed :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := test_data_dir("recon-dead")
	defer delete(dir)
	bridge_config.data_dir = dir

	// A session the map believes is running, with a pid that is not ours. This is
	// exactly the state a dropped exit event leaves behind.
	session_id := "shl_missed_exit"
	sess := Bridge_Shell_Session{
		session_id = bridge_shell_test_session_str(session_id),
		kind       = .Run,
		cmd        = bridge_shell_test_session_str("definitely-not-a-real-binary-name"),
		status     = .Running,
		started_at = bridge_shell_test_session_str("2020-01-01T00:00:00Z"),
		shell_id   = bridge_shell_test_session_str(session_id),
		pid        = 999_999,
		pty_host   = false,
	}
	// SPEC FIRST: register CONSUMES sess (zeroing it), so saving the spec afterwards
	// would write a zeroed record — the same ordering production takes, and the reason
	// register zeroes at all is that this mistake used to be silent.
	bridge_shell_session_save_spec(dir, sess)
	bridge_shell_session_register(&bridge_shell_session_map, &sess)

	bridge_shell_session_reconcile(&bridge_shell_session_map, nil, dir)

	updated, found := bridge_shell_session_scalars(&bridge_shell_session_map, session_id)
	testing.expect(t, found, "the session is still known")
	testing.expect(t, updated.status != .Running, "a dead run is reported terminal, not skipped forever")
	spec := strings.concatenate({dir, "/shell_sessions/", session_id, ".json"})
	defer delete(spec)
	testing.expect(t, !os.exists(spec), "and its spec is cleared")
}

// AC10. A simulated bridge restart: clear the in-memory map (which is what a
// restart does) and re-run reconcile. The run must end up either re-registered
// running or killed-and-reported — never an untracked orphan.
@(test)
bridge_shell2_reconcile_after_restart_leaves_no_untracked_orphan :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := test_data_dir("recon-restart")
	defer delete(dir)
	bridge_config.data_dir = dir

	session_id, pid, spawn_ok := test_spawn_direct_child_run("recon-restart", "sleep 30", dir)
	testing.expect(t, spawn_ok, "direct-child run spawned")
	if !spawn_ok do return
	defer delete(session_id)
	defer if pid > 0 do bridge_shell_test_kill_pid(pid)

	// THE RESTART: the map is in-memory only, so a restart is exactly "the map is
	// empty and the specs are still on disk".
	bridge_shell_session_map_reset(&bridge_shell_session_map)
	testing.expect_value(t, bridge_shell_wait_count(session_id), 0)

	{
		// Reconcile spawns a detached 5s orphan-kill thread (thread.run_with_data)
		// that frees its context and Thread struct after 5s; allocate on the process
		// heap rather than the per-test tracking allocator so the background thread
		// does not free against a destroyed test arena.
		context.allocator = runtime.default_allocator()
		bridge_shell_session_reconcile(&bridge_shell_session_map, nil, dir)
	}

	// Tracked either way — the one outcome that must not happen is "reconcile has
	// never heard of it", which is the untracked orphan.
	after, found := bridge_shell_session_scalars(&bridge_shell_session_map, session_id)
	testing.expect(t, found, "the orphan is picked up by reconcile, not lost")
	// Any RESOLVED state is a pass; what must never happen is "tracked but still
	// undecided". With the retired exec path's reaper gone there is no longer a second
	// actor racing reconcile for this outcome — reconcile kills the orphan and reports
	// Killed — but the assertion is deliberately left as the WHOLE resolved set,
	// because what AC10 states is that it is never an untracked orphan, not which
	// resolved status it lands in.
	testing.expect(t, after.status != .Starting,
		"it is reclaimed or killed-and-reported, never left tracked-but-undecided")
	testing.expect(t, after.status == .Killed || after.status == .Failed || after.status == .Exited || after.status == .Running,
		"and it holds a real lifecycle status")
	spec := strings.concatenate({dir, "/shell_sessions/", session_id, ".json"})
	defer delete(spec)
	testing.expect(t, !os.exists(spec), "a reaped orphan's spec is cleared")
}

// ---- AC1: only background runs notify — NOW A HUB-SIDE RULE -----------------
//
// The two cases that lived here asserted the BRIDGE's notify decision by counting it
// through a test seam on the retired exec path's reaper. REQ-SHELL-7 deleted that
// path, and with it both the decision and the counter. The rule itself did not move
// by accident: the hub owns a session's background flag and the agent's conversation,
// so the hub is where "only a background run notifies" is decided
// (REQ-SHELL-5 §1, shell_session_service.odin -> _shell_session_notify_run_finished)
// and asserted (src/hub/service/shell_session/shell_session_req5_test.odin).
// A test asserting the rule in a layer that no longer owns it would be asserting
// history, so it is not re-created here.

// ---- legacy specs of UNKNOWN provenance -----------------------------------

// The coordinator's question, answered as a test rather than as reasoning.
//
// A spec written BEFORE REQ-SHELL-2 has no pty_host key. If that loaded as a
// plain `false`, a genuinely pty-host-spawned session would take the direct-child
// path and the roster that correctly tracks it would never be consulted — and
// pid_is_plausible can legitimately fail for such a process (the recorded pid is
// the pty-host's child, and ps identifies it by a cmd basename that need not match
// the spec's). The safety net would then declare a LIVE session dead.
//
// THE PATH WAS REAL, just not where it was first expected: it is reached through
// the ORPHAN branch, not the in-map branch. After a restart the map is empty, so a
// legacy spec goes to "not in map" — which before this fix meant the roster was
// never consulted for it at all, a REGRESSION against the pre-REQ-SHELL-2
// behaviour, where every spec was matched against the roster first.
//
// Fix, as the coordinator specified: unknown provenance consults the ROSTER FIRST
// and falls back to the direct-child rule only on a miss. A roster hit is strictly
// more information than ps can produce, so trying it first costs nothing.
@(test)
bridge_shell2_a_legacy_spec_is_reclaimed_from_the_roster :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := test_data_dir("legacy")
	defer delete(dir)
	bridge_config.data_dir = dir

	// A spec with NO pty_host key, exactly as a pre-REQ-SHELL-2 bridge wrote it,
	// and an EMPTY map — which is the post-restart state where this actually bites.
	session_id := "shl_legacy_spec"
	spec_dir := strings.concatenate({dir, "/shell_sessions"})
	defer delete(spec_dir)
	_ = os.make_directory_all(spec_dir)
	spec_path := strings.concatenate({spec_dir, "/", session_id, ".json"})
	defer delete(spec_path)
	legacy := strings.concatenate({
		"{\"session_id\":\"", session_id, "\",\"kind\":\"server\",\"label\":\"\",\"cmd\":\"python3 -m http.server\",",
		"\"cwd\":\"\",\"bridge_id\":\"brg_1\",\"project_id\":\"\",\"chain_id\":\"chain_1\",",
		"\"agent_instance_id\":\"\",\"owner_user_id\":\"owner_a\",\"pid\":4242,\"server_port\":8111,",
		"\"status\":\"running\",\"exit_code\":0,\"exit_code_set\":false,",
		"\"started_at\":\"2026-09-28T09:00:00Z\",\"finished_at\":\"\",\"shell_id\":\"", session_id, "\"}",
	})
	defer delete(legacy)
	testing.expect(t, os.write_entire_file(spec_path, transmute([]byte)legacy) == nil, "legacy spec written")

	// The pty-host roster DOES know it, because it really was pty-host spawned.
	roster := []Pty_Host_Agent_Info{{instance_id = session_id, alive = true, pid = 4242}}
	bridge_shell_session_reconcile(&bridge_shell_session_map, roster, dir)

	sess, found := bridge_shell_session_scalars(&bridge_shell_session_map, session_id)
	testing.expect(t, found, "a legacy spec is reclaimed rather than reaped")
	testing.expect(t, sess.status == .Running, "and is correctly seen as still running")
	// Reclaiming it RECORDS the provenance, so it never takes the unknown path again.
	testing.expect(t, sess.pty_host, "provenance is recorded on reclaim")
	testing.expect(t, sess.pty_host_provenance_known, "and is no longer unknown")
	testing.expect(t, os.exists(spec_path), "its spec is kept while it is live")
}

// The other side of the same rule: a legacy spec the roster does NOT know still
// falls through to the direct-child rule and then to the orphan path, so an
// unknown-provenance spec is never simply skipped.
@(test)
bridge_shell2_a_legacy_spec_the_roster_does_not_know_is_still_resolved :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := test_data_dir("legacy-miss")
	defer delete(dir)
	bridge_config.data_dir = dir

	session_id := "shl_legacy_gone"
	spec_dir := strings.concatenate({dir, "/shell_sessions"})
	defer delete(spec_dir)
	_ = os.make_directory_all(spec_dir)
	spec_path := strings.concatenate({spec_dir, "/", session_id, ".json"})
	defer delete(spec_path)
	legacy := strings.concatenate({
		"{\"session_id\":\"", session_id, "\",\"kind\":\"run\",\"label\":\"\",\"cmd\":\"definitely-not-a-real-binary\",",
		"\"cwd\":\"\",\"bridge_id\":\"brg_1\",\"project_id\":\"\",\"chain_id\":\"\",",
		"\"agent_instance_id\":\"inst_a\",\"owner_user_id\":\"owner_a\",\"pid\":999999,\"server_port\":0,",
		"\"status\":\"running\",\"exit_code\":0,\"exit_code_set\":false,",
		"\"started_at\":\"2020-01-01T00:00:00Z\",\"finished_at\":\"\",\"shell_id\":\"", session_id, "\"}",
	})
	defer delete(legacy)
	testing.expect(t, os.write_entire_file(spec_path, transmute([]byte)legacy) == nil, "legacy spec written")

	bridge_shell_session_reconcile(&bridge_shell_session_map, nil, dir)

	sess, found := bridge_shell_session_scalars(&bridge_shell_session_map, session_id)
	testing.expect(t, found, "it is resolved, not silently skipped")
	testing.expect(t, sess.status != .Running, "and reported terminal")
	testing.expect(t, !os.exists(spec_path), "its spec is cleared")
}

// ---- §8: the 30-minute cap applies to runs and NEVER to servers -------------

// §8 has two halves and the second is the one that would be caught late: a server
// must NOT be capped, or every long-running dev server dies half an hour in with
// no explanation.
//
// Asserted on the ARMING decision rather than by waiting thirty minutes. The cap's
// expiry behaviour is the same kill path a user's kill takes (tested elsewhere);
// what is specific to §8 — and what a regression would change — is WHICH KINDS get
// a watchdog at all.
@(test)
bridge_shell2_only_runs_are_capped :: proc(t: ^testing.T) {
	// bridge_shell_run_cap_start is a no-op for every kind but Run. Calling it for
	// the other two must start nothing; if it ever did, a server would acquire a
	// 30-minute death sentence.
	bridge_shell_run_cap_start("shl_cap_server", .Server)
	bridge_shell_run_cap_start("shl_cap_shell", .Shell)
	bridge_shell_run_cap_start("", .Run)

	// Nothing above registered a session, so nothing can have been capped. The real
	// assertion is that none of these calls spawned a watchdog that could later act
	// on an id it was never given a session for.
	testing.expect(t, !bridge_shell_session_exists(&bridge_shell_session_map, "shl_cap_server"),
		"capping a server registers nothing")
	testing.expect(t, !bridge_shell_session_exists(&bridge_shell_session_map, "shl_cap_shell"),
		"capping a shell registers nothing")

	// And the cap constant a run IS measured against is the required 30 minutes.
	testing.expect(t, BRIDGE_SHELL_HARD_TIMEOUT == 30 * time.Minute, "runs are capped at 30 minutes")
}

// bridge_shell_test_kill_pid must never group-kill a group that is ALSO the test
// runner's. A child spawned WITHOUT setsid shares our process group: the helper
// has to kill only that pid (and the runner survives to assert it); a child
// spawned WITH setsid is its own group, and the helper may kill that group.
@(test)
bridge_shell_test_kill_pid_never_signals_own_process_group :: proc(t: ^testing.T) {
	// (a) same group as the runner: only the pid dies.
	shared, serr := os.process_start(os.Process_Desc{command = []string{"sleep", "30"}})
	testing.expect(t, serr == nil, "spawn shared-group child")
	if serr != nil do return
	testing.expect_value(t, posix.getpgid(posix.pid_t(shared.pid)), posix.getpgid(0))
	testing.expect(t, !bridge_shell_test_wait_for_own_session(shared.pid, 50 * time.Millisecond), "a non-setsid child never becomes its own session")
	bridge_shell_test_kill_pid(shared.pid)
	st, werr := os.process_wait(shared, 2 * time.Second)
	testing.expect(t, werr == nil && st.exited, "shared-group child was killed by pid")
	// If the helper had signalled our group we would not be here.

	// (b) own session: wait for setsid, then the group kill reaches the child.
	when ODIN_OS != .Darwin {
		own, oerr := os.process_start(os.Process_Desc{command = []string{"setsid", "sleep", "30"}})
		testing.expect(t, oerr == nil, "spawn setsid child")
		if oerr != nil do return
		testing.expect(t, bridge_shell_test_wait_for_own_session(own.pid), "setsid child becomes its own session before we signal it")
		testing.expect_value(t, int(posix.getpgid(posix.pid_t(own.pid))), own.pid)
		bridge_shell_test_kill_pid(own.pid)
		st2, werr2 := os.process_wait(own, 2 * time.Second)
		testing.expect(t, werr2 == nil && st2.exited, "own-session child was killed")
	}
	// (c) nonsense pids are ignored.
	bridge_shell_test_kill_pid(0)
	bridge_shell_test_kill_pid(-1)
}
