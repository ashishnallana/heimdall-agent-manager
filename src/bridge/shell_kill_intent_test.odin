#+build !windows
package main

// REQ-SHELL-3 bridge-side tests — the DELIVERY half of durable kill intent:
//   AC3  a kill DELIVERED TWICE is a no-op the second time
//   AC4  a kill whose target already exited signals nothing, including the PID-REUSE
//        case (target exited, pid reassigned: nothing is signalled)
//   §5b  a kill that arrives BEFORE the session exists is recorded, not dropped, and
//        is applied exactly once when the spawn produces a pid
//
// WHAT THESE TESTS DELIBERATELY DO NOT DO: arm a real kill worker. Arming calls
// bridge_pty_host_ensure_daemon, which SPAWNS the pty-host daemon (or attaches to the
// live one on this host) and then signals it — a side effect on the developer's
// machine that a unit test has no business having, and one that would make the
// assertions depend on a daemon's state rather than on this code. Every test below
// therefore asserts the DECISION that precedes arming, which is where all of the new
// logic lives; the arming sequence itself is unchanged code, extracted verbatim into
// bridge_shell_kill_arm.

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

@(private = "file")
// shell_id defaults to session_id, which is what most tests want and what the pre-existing
// callers got. It is a PARAMETER because a test that asserts the resolver arms with the
// correct shell_id cannot do so while the two ids are equal — any mix-up would still
// compare equal. Pass a distinct value there.
intent_session :: proc(session_id: string, status: Bridge_Shell_Session_Status, pid: int, shell_id := "") -> Bridge_Shell_Session {
	return Bridge_Shell_Session{
		session_id = bridge_shell_test_session_str(session_id),
		kind       = .Run,
		cmd        = bridge_shell_test_session_str("sleep 600"),
		status     = status,
		pid        = pid,
		shell_id   = bridge_shell_test_session_str(shell_id if shell_id != "" else session_id),
		started_at = bridge_shell_test_session_str("2026-09-28T09:00:00Z"),
		pty_host   = true,
		pty_host_provenance_known = true,
	}
}

// --- §5b: a kill for a session that does not exist yet -------------------------

// KILL BEFORE START. The hub writes its row and then sends shell_start, so a kill
// accepted in between arrives here for a session that is not in the map: there is no
// pid to signal and no status to mark. This used to `return` silently and the process
// leaked the instant it spawned. The intent must be RECORDED so the spawn applies it.
@(test)
bridge_shell3_kill_before_start_is_recorded_not_dropped :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()

	testing.expect(t, !bridge_shell_kill_intent_pending("sh_unborn"), "nothing pending to begin with")

	bridge_hub_handle_shell_kill(`{"type":"shell_kill","session_id":"sh_unborn"}`)

	testing.expect(t, bridge_shell_kill_intent_pending("sh_unborn"),
		"a kill for an unknown session must be remembered, not dropped on the floor")
	// And it did not invent a session record for it.
	testing.expect(t, !bridge_shell_session_exists(&bridge_shell_session_map, "sh_unborn"),
		"recording an intent does not fabricate a session")
}

// The intent is ONE-SHOT: the spawn path consumes it, so a session cannot be killed
// twice off the back of a single recorded intent, and the entry cannot linger to be
// applied to a later session that reuses the id.
@(test)
bridge_shell3_a_recorded_intent_is_consumed_exactly_once :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()

	bridge_shell_kill_intent_record("sh_1")
	// Recording twice is idempotent — the set holds an intent, not a count.
	bridge_shell_kill_intent_record("sh_1")

	testing.expect(t, bridge_shell_kill_intent_take("sh_1"), "the first take finds the intent")
	testing.expect(t, !bridge_shell_kill_intent_take("sh_1"), "and the second finds nothing — it is one-shot")
	testing.expect(t, !bridge_shell_kill_intent_pending("sh_1"), "so nothing is left pending")
}

// An intent is only ever applied to the session it NAMES. This is what makes a
// recorded intent for a session that never starts inert rather than dangerous.
@(test)
bridge_shell3_an_intent_never_applies_to_a_different_session :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()

	bridge_shell_kill_intent_record("sh_wanted_dead")

	testing.expect(t, !bridge_shell_kill_intent_take("sh_innocent"),
		"a different session's spawn must not consume this intent")
	testing.expect(t, bridge_shell_kill_intent_pending("sh_wanted_dead"),
		"and the real target's intent is still waiting for it")
}

// --- AC3: a kill delivered twice is a no-op the second time --------------------

// The hub replays outstanding intents on EVERY reconnect and reconnects can race, so
// a second delivery of the same kill is expected, not exceptional.
//
// The state seeded here is precisely "after the first delivery": the kill path marks
// the session .Killed before its worker starts. The second delivery must change
// nothing — in particular it must not arm a second SIGTERM/SIGKILL pair, because the
// 5s grace window between them is exactly when the OS is free to hand that pid to an
// unrelated process. The observable proof is that the exit bookkeeping the first
// delivery (and the exit that followed it) left behind is untouched: arming rewrites
// exit_code to -1 and clears exit_code_set.
@(test)
bridge_shell3_a_redelivered_kill_is_a_no_op :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()

	sess := intent_session("sh_1", .Killed, 4242)
	sess.exit_code     = 143
	sess.exit_code_set = true
	bridge_shell_session_register(&bridge_shell_session_map, &sess)

	bridge_hub_handle_shell_kill(`{"type":"shell_kill","session_id":"sh_1"}`)

	after, found := bridge_shell_session_scalars(&bridge_shell_session_map, "sh_1")
	testing.expect(t, found, "the session is still there")
	testing.expect(t, after.status == .Killed, "still killed")
	testing.expect_value(t, after.exit_code, 143)
	testing.expect(t, after.exit_code_set, "the recorded exit survives a redelivered kill — nothing was re-armed")
	// It was not mistaken for a kill-before-start either: the session exists, so no
	// intent is recorded for a spawn to pick up later.
	testing.expect(t, !bridge_shell_kill_intent_pending("sh_1"),
		"a redelivered kill for a known session records no pending intent")
}

// --- AC4: an already-exited target signals nothing, pid reuse included ---------

// Every terminal status is a no-op, not just .Killed — a session that exited on its
// own, or failed, is equally gone.
//
// THE PID-REUSE CASE IS THE POINT. Each session below is seeded with a pid that is
// still a perfectly plausible live pid; the guard does NOT consult liveness at all,
// it reads the session's own terminal status. That ordering is what makes pid reuse
// unreachable from this path: nothing is signalled, so it cannot matter whose process
// that pid now belongs to. A guard that had instead asked "is pid still alive?" would
// answer yes for the unrelated process that inherited it and signal that.
@(test)
bridge_shell3_a_kill_for_an_exited_target_signals_nothing :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)

	terminal := [3]Bridge_Shell_Session_Status{.Exited, .Killed, .Failed}
	for status in terminal {
		bridge_shell_test_reset()

		sess := intent_session("sh_gone", status, 4242)
		sess.exit_code     = 0
		sess.exit_code_set = true
		bridge_shell_session_register(&bridge_shell_session_map, &sess)

		bridge_hub_handle_shell_kill(`{"type":"shell_kill","session_id":"sh_gone"}`)

		after, _ := bridge_shell_session_scalars(&bridge_shell_session_map, "sh_gone")
		testing.expect(t, after.status == status, "a terminal session's status is not rewritten by a kill")
		testing.expect(t, after.exit_code_set, "and its exit bookkeeping is left alone — no worker was armed")
		testing.expect_value(t, after.exit_code, 0)
	}
	bridge_shell_test_reset()
}

// The guard the two tests above rest on, asserted directly and exhaustively: a new
// status added to the enum has to be classified here, and the compiler's exhaustive
// switch is what forces that rather than it silently defaulting to "live".
@(test)
bridge_shell3_terminal_status_classification :: proc(t: ^testing.T) {
	testing.expect(t, bridge_shell_session_status_is_terminal(.Exited), "exited is terminal")
	testing.expect(t, bridge_shell_session_status_is_terminal(.Killed), "killed is terminal")
	testing.expect(t, bridge_shell_session_status_is_terminal(.Failed), "failed is terminal")
	testing.expect(t, !bridge_shell_session_status_is_terminal(.Running), "running is live")
	testing.expect(t, !bridge_shell_session_status_is_terminal(.Starting), "starting is live")
}

// A malformed kill frame is ignored rather than recording an intent under an empty
// key — an entry no spawn could ever consume, and one that would make
// bridge_shell_kill_intent_pending("") true forever.
@(test)
bridge_shell3_a_kill_without_a_session_id_records_nothing :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()

	bridge_hub_handle_shell_kill(`{"type":"shell_kill"}`)
	testing.expect(t, !bridge_shell_kill_intent_pending(""), "no intent under an empty key")
}

// --- REQ-SHELL-23: reconcile is the intent's SECOND consumer --------------------
//
// THE DEFECT THESE PIN DOWN. A kill accepted while the bridge was offline is redelivered
// by the hub on reconnect, and it arrives BEFORE reconcile has rebuilt the session map
// from the surviving pty-host daemon's roster. It therefore always found an empty map,
// took the kill-before-start branch above, and was parked as an intent — which nothing
// ever consumed, because the only consumer was the spawn path and a bridge that restarts
// does not SPAWN the sessions it inherits, it ADOPTS them. The process outlived a kill the
// hub had already promised the user, and no log on the host said so.
//
// WHY THEY FAIL BEFORE THE FIX. Not by a changed assertion but by a missing mechanism:
// before REQ-SHELL-23 nothing outside bridge_hub_handle_shell_start consumed an intent at
// all, so "the adopted, still-live session is armed from its parked intent" was unreachable
// by any path. The pre-existing §5b tests above still pass unchanged and are still right —
// they are simply about the other reason a session can be missing from the map, and that
// difference is the whole point of the age gate below.
@(private = "file")
// Both values are recorded, not just the session id. A resolver that armed the right
// session with the WRONG shell_id passed every test in this file while `shell_ids` did not
// exist — arm_record simply dropped its second parameter (REQ-SHELL-13 follow-up).
Arm_Recorder :: struct {
	calls:     [dynamic]string,
	shell_ids: [dynamic]string,
}

@(private = "file")
arm_rec: Arm_Recorder

@(private = "file")
arm_record :: proc(session_id: string, shell_id: string) {
	append(&arm_rec.calls, strings.clone(session_id))
	append(&arm_rec.shell_ids, strings.clone(shell_id))
}

@(private = "file")
arm_rec_reset :: proc() {
	for c in arm_rec.calls do delete(c)
	if arm_rec.calls == nil { arm_rec.calls = make([dynamic]string) } else { clear(&arm_rec.calls) }
	for c in arm_rec.shell_ids do delete(c)
	if arm_rec.shell_ids == nil { arm_rec.shell_ids = make([dynamic]string) } else { clear(&arm_rec.shell_ids) }
}

// A session the roster brought back is STILL LIVE and carries a parked kill: reconcile
// must arm it. This is the production failure, inverted into an assertion.
@(test)
bridge_shell23_reconcile_arms_a_parked_kill_for_an_adopted_session :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	arm_rec_reset()
	defer arm_rec_reset()

	// The kill arrives while the map is empty — exactly the reconnect ordering.
	bridge_hub_handle_shell_kill(`{"type":"shell_kill","session_id":"sh_adopted"}`)
	testing.expect(t, bridge_shell_kill_intent_pending("sh_adopted"), "parked, as the reconnect replay always was")

	// Now reconcile repopulates the map from the roster, as bridge_shell_session_reconcile
	// does for a session the daemon still reports alive.
	// A shell_id DELIBERATELY DIFFERENT from the session_id, so the assertion below can
	// tell the two apart. With the default (shell_id == session_id) a resolver that armed
	// with the wrong one would still compare equal and the check would prove nothing.
	sess := intent_session("sh_adopted", .Running, 4242, shell_id = "shell_abc")
	bridge_shell_session_register(&bridge_shell_session_map, &sess)

	// Resolve against a roster captured AFTER the intent was recorded.
	armed, discarded := bridge_shell_kill_intent_resolve(&bridge_shell_session_map, time.tick_now(), arm_record)

	testing.expect_value(t, armed, 1)
	testing.expect_value(t, discarded, 0)
	testing.expect_value(t, len(arm_rec.calls), 1)
	if len(arm_rec.calls) == 1 do testing.expect_value(t, arm_rec.calls[0], "sh_adopted")
	// The resolver must arm with the session's OWN shell_id, looked up from the roster.
	testing.expect_value(t, len(arm_rec.shell_ids), 1)
	if len(arm_rec.shell_ids) == 1 do testing.expect_value(t, arm_rec.shell_ids[0], "shell_abc")
	testing.expect(t, !bridge_shell_kill_intent_pending("sh_adopted"),
		"the intent is consumed, so a later redelivery goes through the normal kill path")
}

// AC5. The same resolve against an ALREADY-TERMINAL session arms nothing. Re-signalling a
// terminal session is the PID-reuse hazard the kill path refuses outright: its pid may by
// now belong to an unrelated process.
@(test)
bridge_shell23_reconcile_discards_a_parked_kill_for_a_terminal_session :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	arm_rec_reset()
	defer arm_rec_reset()

	bridge_hub_handle_shell_kill(`{"type":"shell_kill","session_id":"sh_dead"}`)
	sess := intent_session("sh_dead", .Exited, 4243)
	bridge_shell_session_register(&bridge_shell_session_map, &sess)

	armed, discarded := bridge_shell_kill_intent_resolve(&bridge_shell_session_map, time.tick_now(), arm_record)

	testing.expect_value(t, armed, 0)
	testing.expect_value(t, discarded, 1)
	testing.expect_value(t, len(arm_rec.calls), 0)
	testing.expect(t, !bridge_shell_kill_intent_pending("sh_dead"), "and the spent intent is retired, not left to leak")
}

// THE GUARD THAT MATTERS MOST, and the one the coordinator caught me getting wrong: a
// YOUNG intent naming a session the roster does not know must be LEFT PARKED. It may be a
// kill-before-start whose spawn is still in flight (REQ-SHELL-3 §5b), and discarding it
// would let that spawn produce a process nothing kills — reintroducing the exact leak 5b
// exists to prevent, by way of a cleanup. Ordering the intent against the roster is NOT
// sufficient grounds; the roster cannot see a future spawn.
@(test)
bridge_shell23_a_young_unknown_intent_is_left_for_the_spawn_path :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	arm_rec_reset()
	defer arm_rec_reset()

	// Recorded now; the session is not in the map and its start has not landed.
	bridge_hub_handle_shell_kill(`{"type":"shell_kill","session_id":"sh_inflight"}`)

	armed, discarded := bridge_shell_kill_intent_resolve(&bridge_shell_session_map, time.tick_now(), arm_record)

	testing.expect_value(t, armed, 0)
	testing.expect_value(t, discarded, 0)
	testing.expect(t, bridge_shell_kill_intent_pending("sh_inflight"),
		"a young unknown intent must survive reconcile so the spawn can still consume it")
}

// The other side of the age gate: an intent that has outlived any plausible start
// round-trip names a session that does not exist on this host, and is retired. This is
// what stops a stale id parking a key for the life of the process — the pre-existing leak
// the old comment accepted as "bounded, cleared by a bridge restart".
@(test)
bridge_shell23_an_old_unknown_intent_is_retired :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	arm_rec_reset()
	defer arm_rec_reset()

	// Recorded well beyond the garbage age, without waiting for it in real time.
	old := time.Tick{_nsec = time.tick_now()._nsec - i64(2 * BRIDGE_SHELL_KILL_INTENT_GARBAGE_AGE)}
	bridge_shell_kill_intent_record_at("sh_stale", old)
	testing.expect(t, bridge_shell_kill_intent_pending("sh_stale"), "seeded")

	armed, discarded := bridge_shell_kill_intent_resolve(&bridge_shell_session_map, time.tick_now(), arm_record)

	testing.expect_value(t, armed, 0)
	testing.expect_value(t, discarded, 1)
	testing.expect(t, !bridge_shell_kill_intent_pending("sh_stale"), "every recorded intent now has an owner that frees it")
}

// A second resolve is a no-op: the take is what makes arming one-shot, so two reconnects
// racing cannot arm the same session twice and start two SIGTERM/SIGKILL pairs against one
// pid — the hazard the redelivery guard in bridge_hub_handle_shell_kill also refuses.
@(test)
bridge_shell23_resolve_is_one_shot :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	arm_rec_reset()
	defer arm_rec_reset()

	bridge_hub_handle_shell_kill(`{"type":"shell_kill","session_id":"sh_once"}`)
	sess := intent_session("sh_once", .Running, 4244)
	bridge_shell_session_register(&bridge_shell_session_map, &sess)

	first_armed, _ := bridge_shell_kill_intent_resolve(&bridge_shell_session_map, time.tick_now(), arm_record)
	second_armed, second_discarded := bridge_shell_kill_intent_resolve(&bridge_shell_session_map, time.tick_now(), arm_record)

	testing.expect_value(t, first_armed, 1)
	testing.expect_value(t, second_armed, 0)
	testing.expect_value(t, second_discarded, 0)
	testing.expect_value(t, len(arm_rec.calls), 1)
}

// --- REQ-BR-2: a REFUSED kill of a run that is already gone ---------------------

// The daemon refuses to signal a pid it has already reaped. That refusal used to be
// only logged: the session stayed .Killed-but-unreported in the bridge and "running" on
// the hub, with a Kill button that could never work. The refusal is now resolved
// against the roster — the state bridge_shell_kill_arm leaves (.Killed, exit -1, no
// code) plus a roster that says the run is gone must end in a "killed" shell_exited.
@(test)
bridge_br2_refused_kill_of_a_gone_run_is_finalized_and_reported :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := fmt.aprintf("/tmp/ham-br2-refused-%d", os.get_pid())
	defer delete(dir)
	bridge_config.data_dir = dir
	exit_sweep_queue_init()

	// (a) the daemon still lists it, exited.
	exited_sid := "sh_br2_exited"
	a := exit_sweep_session(exited_sid, .Killed, 4_100_001, -1, false) // as kill_arm leaves it
	bridge_shell_session_register(&bridge_shell_session_map, &a)
	// (b) the daemon has forgotten it and its pid is gone.
	lost_sid := "sh_br2_lost"
	b := exit_sweep_session(lost_sid, .Killed, 4_100_002, -1, false)
	bridge_shell_session_register(&bridge_shell_session_map, &b)
	// (c) control: the daemon still reports it ALIVE — the refusal was something else,
	// and the kill must stay in flight (nothing reported, escalation proceeds).
	alive_sid := "sh_br2_alive"
	c := exit_sweep_session(alive_sid, .Killed, 4_100_003, -1, false)
	bridge_shell_session_register(&bridge_shell_session_map, &c)

	roster := []Pty_Host_Agent_Info{
		{instance_id = exited_sid, pid = 4_100_001, alive = false, has_exit_code = true, exit_code = 0},
		{instance_id = alive_sid, pid = 4_100_003, alive = true},
	}

	testing.expect(t, bridge_shell_kill_resolve_refused(&bridge_shell_session_map, exited_sid, roster, dir, exit_sweep_pid_dead), "exited-in-roster run is finalized")
	testing.expect(t, bridge_shell_kill_resolve_refused(&bridge_shell_session_map, lost_sid, roster, dir, exit_sweep_pid_dead), "unknown run with a dead pid is finalized")
	testing.expect(t, !bridge_shell_kill_resolve_refused(&bridge_shell_session_map, alive_sid, roster, dir, exit_sweep_pid_dead), "a run the daemon reports alive is left to the escalation")

	for sid in ([]string{exited_sid, lost_sid}) {
		sc, _ := bridge_shell_session_scalars(&bridge_shell_session_map, sid)
		testing.expectf(t, sc.status == .Killed && sc.exit_reported, "%s: still Killed, exit now reported", sid)
		events := exit_sweep_take_events(sid)
		testing.expectf(t, len(events) == 1, "%s: exactly one shell_exited, got %d", sid, len(events))
		if len(events) == 1 do testing.expectf(t, strings.contains(events[0], `"status":"killed"`), "%s: reported as killed: %s", sid, events[0])
		exit_sweep_events_delete(events)
	}
	none := exit_sweep_take_events(alive_sid)
	testing.expect_value(t, len(none), 0)
	exit_sweep_events_delete(none)

	// A redelivered refusal (or the late ChildExited) reports nothing further.
	testing.expect(t, !bridge_shell_kill_resolve_refused(&bridge_shell_session_map, exited_sid, roster, dir, exit_sweep_pid_dead), "second resolution is a no-op")
	again := exit_sweep_take_events(exited_sid)
	testing.expect_value(t, len(again), 0)
	exit_sweep_events_delete(again)
}

// --- REQ-BR-2: AlreadyExited (pty-host 52cebd54) -----------------------------

// A daemon that has the kill target's tombstone answers Signal with
// AlreadyExited{instance, code} instead of a generic Error. The bridge must read that
// as "gone, with this code" — not as a refusal — and report the run with that code
// straight away, with no roster round-trip.

@(private = "file")
Already_Exited_Fake_Daemon :: struct {
	listener: posix.FD,
	reply:    []byte, // one reply payload (tag + fields), framed by the fake
	got_tag:  byte,   // the request's tag, as received
}

@(private = "file")
already_exited_listen :: proc(path: string) -> posix.FD {
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return -1
	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	for i in 0..<len(path) do addr.sun_path[i] = c.char(path[i])
	if posix.bind(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK || posix.listen(fd, 4) != .OK {
		posix.close(fd)
		return -1
	}
	return fd
}

// Serves exactly one request: read its frame, answer with fake.reply.
@(private = "file")
already_exited_fake_daemon_serve :: proc(th: ^thread.Thread) {
	fake := (^Already_Exited_Fake_Daemon)(th.data)
	conn := posix.accept(fake.listener, nil, nil)
	if conn < 0 do return
	defer posix.close(conn)
	req, ok := pty_host_read_frame(conn)
	if !ok do return
	if len(req) > 0 do fake.got_tag = req[0]
	delete(req)
	frame := pty_host_frame(fake.reply)
	defer delete(frame)
	_ = pty_host_send_all(conn, frame)
}

@(private = "file")
already_exited_signal_against :: proc(t: ^testing.T, reply: []byte) -> (result: Pty_Host_Signal_Result, code: i32, got_tag: byte) {
	path := fmt.aprintf("/tmp/ham-br2-sig-%d.sock", os.get_pid())
	defer delete(path)
	cpath := strings.clone_to_cstring(path)
	defer delete(cpath)
	_ = posix.unlink(cpath)
	defer posix.unlink(cpath)
	fake := Already_Exited_Fake_Daemon{listener = already_exited_listen(path), reply = reply}
	testing.expect(t, fake.listener >= 0, "fake daemon listening")
	if fake.listener < 0 do return .Refused, 0, 0
	defer posix.close(fake.listener)
	th := thread.create(already_exited_fake_daemon_serve)
	th.data = &fake
	thread.start(th)
	result, code = bridge_pty_host_signal_detailed(&Pty_Host_Client{socket = path}, "sh_br2_sig", 15)
	thread.join(th)
	thread.destroy(th)
	return result, code, fake.got_tag
}

@(test)
bridge_br2_signal_reply_already_exited_is_decoded :: proc(t: ^testing.T) {
	// The frame dproto.rs writes: tag 0xB0, instance (u32-len string), code (i32 BE).
	p := make([dynamic]byte); defer delete(p)
	append(&p, PTY_HOST_T_ALREADY_EXITED)
	pty_host_put_str(&p, "sh_br2_sig")
	pty_host_put_i32(&p, 143)
	r, ok := pty_host_decode_reply(p[:])
	defer pty_host_reply_delete(r)
	testing.expect(t, ok, "AlreadyExited decodes")
	testing.expect_value(t, r.kind, Pty_Host_Reply_Kind.Already_Exited)
	testing.expect_value(t, r.instance, "sh_br2_sig")
	testing.expect_value(t, r.code, i32(143))

	// Over a real socket, the Signal round-trip classifies each reply.
	result, code, tag := already_exited_signal_against(t, p[:])
	testing.expect_value(t, tag, byte(PTY_HOST_T_SIGNAL))
	testing.expect_value(t, result, Pty_Host_Signal_Result.Already_Exited)
	testing.expect_value(t, code, i32(143))

	closed := make([dynamic]byte); defer delete(closed)
	append(&closed, PTY_HOST_T_CLOSED)
	pty_host_put_str(&closed, "sh_br2_sig")
	result, _, _ = already_exited_signal_against(t, closed[:])
	testing.expect_value(t, result, Pty_Host_Signal_Result.Delivered)

	// An older daemon's answer for the same situation stays a refusal (roster fallback).
	e := make([dynamic]byte); defer delete(e)
	append(&e, PTY_HOST_T_ERROR)
	pty_host_put_str(&e, "sh_br2_sig")
	pty_host_put_str(&e, "killpg: ESRCH")
	result, _, _ = already_exited_signal_against(t, e[:])
	testing.expect_value(t, result, Pty_Host_Signal_Result.Refused)
}

@(test)
bridge_br2_already_exited_kill_is_finalized_with_its_code :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	dir := fmt.aprintf("/tmp/ham-br2-already-%d", os.get_pid())
	defer delete(dir)
	exit_sweep_queue_init()

	sid := "sh_br2_already"
	s := exit_sweep_session(sid, .Killed, 4_200_001, -1, false) // as kill_arm leaves it
	bridge_shell_session_register(&bridge_shell_session_map, &s)

	testing.expect(t, bridge_shell_kill_resolve_already_exited(&bridge_shell_session_map, sid, 143, dir), "finalized from the daemon's answer alone")
	sc, _ := bridge_shell_session_scalars(&bridge_shell_session_map, sid)
	testing.expect_value(t, sc.status, Bridge_Shell_Session_Status.Killed)
	testing.expect(t, sc.exit_code_set && sc.exit_code == 143 && sc.exit_reported, "the daemon's code is recorded and the exit claimed")
	events := exit_sweep_take_events(sid)
	testing.expect_value(t, len(events), 1)
	if len(events) == 1 {
		testing.expectf(t, strings.contains(events[0], `"status":"killed"`) && strings.contains(events[0], `"exit_code":143`), "killed with code 143: %s", events[0])
	}
	exit_sweep_events_delete(events)

	// The late ChildExited (or a repeated answer) reports nothing further.
	testing.expect(t, !bridge_shell_kill_resolve_already_exited(&bridge_shell_session_map, sid, 143, dir), "second resolution is a no-op")
	again := exit_sweep_take_events(sid)
	testing.expect_value(t, len(again), 0)
	exit_sweep_events_delete(again)
}
