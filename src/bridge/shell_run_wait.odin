package main

// REQ-SHELL-2: the bridge-local wait that makes a FOREGROUND run block.
//
// WHY THIS IS BRIDGE-LOCAL AND NOT A LONG HUB REQUEST (coordinator ruling on
// item 0). The description asked for a foreground run to block its caller until
// the run reaches a terminal status. The transport cannot carry that as one HTTP
// request: ham-ctl -> bridge local endpoint -> hub all use
// httpc.DEFAULT_TIMEOUT_MS = 20_000 (src/lib/httpc/httpc.odin), so a
// 30-minute blocking POST is cut at 20s at two hops, and holding it hub-side
// would pin a hub request thread for the length of the run. Polling is forbidden
// outright by the chain.
//
// So the create stays fast over the existing endpoint, and the BLOCK is a second,
// purely local call — `agent.shell.wait` — served by the bridge that owns the
// process. The bridge already receives the exit event, so the wait is a condvar
// signalled by that event with no hub round trip and no poller anywhere.
//
// FOUR CONSTRAINTS this file exists to satisfy, all of them required:
//
//   W1  The long timeout is on THAT ONE CALL. Nothing here changes
//       DEFAULT_TIMEOUT_MS or any shared client path — a wait is bounded by the
//       timeout_ms the caller passes, capped at BRIDGE_SHELL_WAIT_MAX_MS.
//
//   W2  THE WAIT IS A CONVENIENCE, NEVER THE SOURCE OF TRUTH. Every piece of
//       state a run has lives in the session map and its on-disk spec. A waiter
//       owns nothing: if ham-ctl dies, is Ctrl-C'd, or the local call times out,
//       the run keeps running, stays in the map, keeps its spec, stays killable
//       by id and stays reapable by reconcile. Dropping a waiter is invisible to
//       the process. This is why the registry below is keyed by session id and
//       holds no process handle — there is deliberately nothing here to lose.
//
//   W3  ONE EXIT EVENT, TWO CONSUMERS. Signalling a waiter must never consume or
//       starve the hub notification path (T4/T5). bridge_shell_wait_signal_exit
//       is therefore purely ADDITIVE at every call site: it is called alongside
//       the existing bridge_shell_exited_enqueue, never instead of it, and it
//       returns nothing the caller branches on. A run with no waiter at all
//       behaves exactly as it did before this file existed.
//
//   W4  The 30-minute hard cap (BRIDGE_SHELL_HARD_TIMEOUT) is enforced on the
//       PROCESS, not here. A waiter timing out does not kill anything, and a
//       dropped waiter neither extends nor shortens the cap.

import "base:runtime"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// Ceiling on a single wait call. Slightly above BRIDGE_SHELL_HARD_TIMEOUT so a
// foreground caller that asks for "as long as it takes" outlives the process cap
// and always gets a real terminal answer rather than a wait timeout — the cap
// kills the process, the exit signal wakes the waiter, and the caller learns it
// was killed. It is a ceiling on the CALL only (W1/W4); it bounds nothing about
// the process.
BRIDGE_SHELL_WAIT_MAX_MS :: 31 * 60 * 1000
BRIDGE_SHELL_WAIT_DEFAULT_MS :: BRIDGE_SHELL_WAIT_MAX_MS

// How a wait ended. The caller renders these; nothing in the lifecycle branches
// on them.
Bridge_Shell_Wait_Outcome :: enum {
	Exited,       // the run reached a terminal status
	Backgrounded, // converted to background mid-flight; release the caller with the id
	Timed_Out,    // the wait call's own ceiling elapsed. The run is UNAFFECTED (W2/W4).
	Unknown,      // no such live session to wait on
}

// Bridge_Shell_Waiter is one blocked caller. Heap-allocated so the waiting thread
// keeps a valid pointer after the registry lock is released, and freed by that
// same waiting thread on its way out — the signaller never frees a waiter, so a
// signal racing a caller that has already walked away cannot free under it.
Bridge_Shell_Waiter :: struct {
	mu:           sync.Mutex,
	cond:         sync.Cond,
	done:         bool,
	outcome:      Bridge_Shell_Wait_Outcome,
	status:       Bridge_Shell_Session_Status,
	exit_code:    int,
	exit_code_set: bool,
}

@(private = "file")
_bridge_shell_waiters: map[string][dynamic]^Bridge_Shell_Waiter
@(private = "file")
_bridge_shell_waiters_mu: sync.Mutex

// bridge_shell_wait_register adds a waiter for session_id and returns it. A
// session may have several waiters (nothing forbids two callers waiting on the
// same id), so the registry holds a LIST per id and a signal wakes all of them —
// waking only the first would leave the others blocked until their own ceiling
// with no way to learn the run had finished.
// EVERY allocation the registry owns uses runtime.default_allocator(), never
// context.allocator, and this is load-bearing rather than stylistic.
//
// A waiter is registered on the thread serving the local RPC and can be freed on
// a different one; the registry itself is a package global outliving both. Under
// context.allocator the map, its keys and the waiter structs would be allocated
// from whichever thread happened to touch them first and freed against whichever
// allocator the freeing thread carries — which in the test runner is a per-thread
// tracking allocator, i.e. a genuine invalid free rather than a theoretical one.
// The session map states the same rule as a type: Bridge_Shell_Session_Map carries
// the allocator every entry is cloned from and freed through (REQ-SHELL-11), for
// exactly this reason. The waiter registry pins the heap directly instead, because
// it is a package global with no handle for a caller to pass.
bridge_shell_wait_register :: proc(session_id: string) -> ^Bridge_Shell_Waiter {
	if session_id == "" do return nil
	heap := runtime.default_allocator()
	w := new(Bridge_Shell_Waiter, heap)
	sync.mutex_lock(&_bridge_shell_waiters_mu)
	defer sync.mutex_unlock(&_bridge_shell_waiters_mu)
	if _bridge_shell_waiters == nil do _bridge_shell_waiters = make(map[string][dynamic]^Bridge_Shell_Waiter, allocator = heap)
	if _, ok := _bridge_shell_waiters[session_id]; !ok {
		_bridge_shell_waiters[strings.clone(session_id, heap)] = make([dynamic]^Bridge_Shell_Waiter, heap)
	}
	list := &_bridge_shell_waiters[session_id]
	append(list, w)
	return w
}

// bridge_shell_wait_unregister removes one waiter and frees it. Called by the
// waiting thread itself, always, on every exit path — including the timeout path,
// which is how a Ctrl-C'd or timed-out caller leaves nothing behind (W2).
bridge_shell_wait_unregister :: proc(session_id: string, w: ^Bridge_Shell_Waiter) {
	if session_id == "" || w == nil do return
	sync.mutex_lock(&_bridge_shell_waiters_mu)

	// Resolve the STORED key first, read-only. The map owns a clone of the id (see
	// register), and delete_key does not free it — so the clone has to be freed
	// here or a long-lived bridge accumulates one key per run it ever waited on.
	// Finding it before any mutation matters: looking it up by iterating AFTER a
	// delete_key would be iterating a map that is being modified, and the `list`
	// pointer below points into the map's own storage, so it is only valid until
	// the map is touched.
	stored_key := ""
	have_key := false
	for k in _bridge_shell_waiters {
		if k == session_id {
			stored_key = k
			have_key = true
			break
		}
	}

	now_empty := false
	if list, ok := &_bridge_shell_waiters[session_id]; ok {
		for entry, i in list {
			if entry == w {
				ordered_remove(list, i)
				break
			}
		}
		now_empty = len(list) == 0
		// Free the backing array while the pointer is still valid, before the map is
		// mutated below.
		if now_empty do delete(list^)
	}
	if now_empty && have_key {
		delete_key(&_bridge_shell_waiters, stored_key)
		delete(stored_key, runtime.default_allocator())
	}
	sync.mutex_unlock(&_bridge_shell_waiters_mu)
	free(w, runtime.default_allocator())
}

// bridge_shell_wait_block parks until the waiter is signalled or timeout_ms
// elapses.
//
// sync.cond_wait_with_timeout can wake spuriously, so the `done` flag — not the
// return of the wait — is what decides the outcome: we loop until done is set or
// the deadline has genuinely passed. Without that, a spurious wake would return
// Timed_Out on a run that was still going perfectly well, and the caller would be
// told its foreground run timed out seconds after starting it.
bridge_shell_wait_block :: proc(w: ^Bridge_Shell_Waiter, timeout_ms: int) -> (Bridge_Shell_Wait_Outcome, Bridge_Shell_Session_Status, int, bool) {
	if w == nil do return .Unknown, .Failed, 0, false
	ms := timeout_ms
	if ms <= 0 do ms = BRIDGE_SHELL_WAIT_DEFAULT_MS
	if ms > BRIDGE_SHELL_WAIT_MAX_MS do ms = BRIDGE_SHELL_WAIT_MAX_MS
	deadline := time.time_add(time.now(), time.Duration(ms) * time.Millisecond)

	sync.mutex_lock(&w.mu)
	defer sync.mutex_unlock(&w.mu)
	for !w.done {
		remaining := time.diff(time.now(), deadline)
		if remaining <= 0 do break
		_ = sync.cond_wait_with_timeout(&w.cond, &w.mu, remaining)
	}
	if !w.done do return .Timed_Out, .Running, 0, false
	return w.outcome, w.status, w.exit_code, w.exit_code_set
}

// bridge_shell_wait_signal is the one place a waiter is woken. Wakes EVERY waiter
// on the session and leaves the registry untouched — each waiting thread removes
// its own entry (see bridge_shell_wait_unregister), so a signal never frees a
// struct another thread is still parked on.
//
// Idempotent per waiter: `done` is set once and a second signal for the same
// session is a no-op for a waiter already marked done. That matters because a run
// killed by the hard cap is both killed and exited, and both paths signal.
@(private = "file")
bridge_shell_wait_signal :: proc(session_id: string, outcome: Bridge_Shell_Wait_Outcome, status: Bridge_Shell_Session_Status, exit_code: int, exit_code_set: bool) {
	if session_id == "" do return
	sync.mutex_lock(&_bridge_shell_waiters_mu)
	list, ok := _bridge_shell_waiters[session_id]
	// Snapshot the pointers under the registry lock: taking each waiter's own lock
	// while holding the registry lock would invert the order a waiter itself takes
	// them in and deadlock. The pointers stay valid because only the waiting thread
	// frees a waiter, and it does so after removing itself from this list.
	snapshot: [dynamic]^Bridge_Shell_Waiter
	if ok {
		snapshot = make([dynamic]^Bridge_Shell_Waiter, context.temp_allocator)
		for w in list do append(&snapshot, w)
	}
	sync.mutex_unlock(&_bridge_shell_waiters_mu)
	if !ok do return

	for w in snapshot {
		sync.mutex_lock(&w.mu)
		if !w.done {
			w.done          = true
			w.outcome       = outcome
			w.status        = status
			w.exit_code     = exit_code
			w.exit_code_set = exit_code_set
		}
		sync.cond_broadcast(&w.cond)
		sync.mutex_unlock(&w.mu)
	}
}

// bridge_shell_wait_signal_exit releases foreground callers because the run is
// over.
//
// ADDITIVE AT EVERY CALL SITE (W3). Call it ALONGSIDE the existing
// bridge_shell_exited_enqueue, never instead of it: the hub notification path and
// the local waiter are two independent consumers of one exit, and a run with no
// waiter must behave exactly as it did before waiters existed. It returns nothing
// precisely so no caller can start branching on whether somebody was waiting.
bridge_shell_wait_signal_exit :: proc(session_id: string, status: Bridge_Shell_Session_Status, exit_code: int, exit_code_set: bool) {
	bridge_shell_wait_signal(session_id, .Exited, status, exit_code, exit_code_set)
}

// bridge_shell_wait_signal_backgrounded releases foreground callers because the
// run was converted to background mid-flight (REQ-SHELL-2 §3) — by the user from
// the UI, or by the agent-liveness hook.
//
// The caller is released with the session id, which is byte-identical to what a
// `--bg` start would have returned, so a converted run and a born-background run
// are indistinguishable to whoever was blocked. The run itself is untouched: it
// keeps running and now notifies on completion.
bridge_shell_wait_signal_backgrounded :: proc(session_id: string) {
	bridge_shell_wait_signal(session_id, .Backgrounded, .Running, 0, false)
}

// bridge_shell_wait_count is a test seam: how many waiters are parked on a
// session. Used to assert that a dropped waiter actually leaves nothing behind
// (W2) rather than trusting that it does.
bridge_shell_wait_count :: proc(session_id: string) -> int {
	sync.mutex_lock(&_bridge_shell_waiters_mu)
	defer sync.mutex_unlock(&_bridge_shell_waiters_mu)
	if list, ok := _bridge_shell_waiters[session_id]; ok do return len(list)
	return 0
}

// ---- agent.shell.wait local RPC ------------------------------------------

// bridge_shell_wait_rpc serves `agent.shell.wait {session_id}` — the block that
// makes a foreground `ham-ctl shell run` foreground.
//
// The run itself was created over the hub's normal create endpoint, so by the
// time this is called the hub row exists, the bridge has spawned the process and
// registered the session, and the spec is on disk. All this call does is park
// until that session ends, and render the same response shape a finished run
// returns inline. It CREATES NOTHING and OWNS NOTHING (W2).
//
// AUTHORIZATION: a caller may only wait on a session its own agent instance
// triggered. Without that check any agent on the bridge could park on — and read
// the output of — another agent's run, and runs are agent-scoped precisely so
// that cannot happen. Scope is enforced here in the same terms the hub uses
// (agent_instance_id), not by trusting the caller to ask about its own session.
bridge_shell_wait_rpc :: proc(request_id, params: string, rec: Bridge_Local_Agent_Token_Record) -> string {
	session_id := strings.trim_space(bridge_local_extract_json_string(params, "session_id", ""))
	if session_id == "" do session_id = strings.trim_space(bridge_local_extract_json_string(params, "exec_id", ""))
	if session_id == "" do return bridge_local_response_error(request_id, "bad_request", "shell wait requires <session_id>")

	timeout_ms := bridge_local_extract_json_int(params, "timeout_ms", BRIDGE_SHELL_WAIT_DEFAULT_MS)

	sess, found := bridge_shell_session_snapshot(&bridge_shell_session_map, session_id)
	if !found {
		return bridge_local_response_error(request_id, "not_found", strings.concatenate({"no shell session with id ", session_id}))
	}
	defer bridge_shell_session_snapshot_destroy(&bridge_shell_session_map, sess)
	if sess.agent_instance_id != "" && rec.agent_instance_id != "" && sess.agent_instance_id != rec.agent_instance_id {
		return bridge_local_response_error(request_id, "forbidden", "shell wait: that run belongs to a different agent instance")
	}

	// Already over, or already background. Answer immediately rather than parking
	// on a signal that has been and gone — a waiter registered after the exit would
	// sit until its own ceiling on a run that finished before it asked.
	switch sess.status {
	case .Exited, .Killed, .Failed:
		// A wait against an ALREADY-terminal run is the one place in this file that
		// can meet reclaimed output: the run may have finished days ago and the
		// caller is only now asking. Read it through the three-state reader so that
		// case is refused explicitly instead of answering with an empty log
		// (REQ-SHELL-8 AC3).
		b := strings.builder_make()
		output_str, out_state := bridge_shell_output_read(session_id)
		defer if out_state == .Available do delete(output_str)
		if out_state == .Reclaimed do return bridge_local_response_error(request_id, BRIDGE_SHELL_OUTPUT_RECLAIMED_CODE, BRIDGE_SHELL_OUTPUT_RECLAIMED_MESSAGE)
		// Sanitised before measuring and before tailing, identically to the live
		// path in bridge_shell_run_wait_response — see the full reasoning there.
		// Both render the same response shape for the same caller, so they must
		// agree byte for byte on what a finished run's output looks like; a wait
		// that arrived a second late must not return different text from one that
		// arrived a second early (REQ-SHELL-27).
		sanitized := bridge_shell_sanitize_output(output_str)
		defer delete(sanitized)
		output_size := len(sanitized)
		tail, truncated := bridge_shell_tail(sanitized, BRIDGE_SHELL_TAIL_THRESHOLD, BRIDGE_SHELL_TAIL_KEEP)
		bridge_shell_write_session_json(&b, &sess, tail, truncated, output_size, true)
		return bridge_local_response_data(request_id, strings.to_string(b))
	case .Running, .Starting:
		if sess.background {
			b := strings.builder_make()
			strings.write_string(&b, "{\"exec_id\":\"")
			bridge_local_write_json_string(&b, session_id)
			strings.write_string(&b, "\",\"session_id\":\"")
			bridge_local_write_json_string(&b, session_id)
			strings.write_string(&b, "\",\"status\":\"running\",\"background\":true,\"message\":\"Run is in the background; you will be notified when it finishes.\"}")
			return bridge_local_response_data(request_id, strings.to_string(b))
		}
	}

	return bridge_shell_run_wait_response(request_id, session_id, timeout_ms)
}

// ---- foreground -> background conversion ---------------------------------

// bridge_shell_set_background flips a live run to background (REQ-SHELL-2 §3) and
// releases whoever was blocked on it.
//
// Ordering matters and is not arbitrary: the flag is written to the map and the
// spec FIRST, and only then is the waiter released. A waiter released before the
// flag landed could re-read the session, still see background=false, and report a
// foreground run it had just been told was backgrounded. Persisting first also
// means a bridge restart between the two steps still leaves a backgrounded run,
// which is the state the user asked for.
//
// ONE-WAY, and this is where that is enforced: a run already background is a
// no-op, so a repeated conversion cannot release a second waiter or re-arm a
// notification. Returns whether anything changed.
bridge_shell_set_background :: proc(session_id: string) -> bool {
	if session_id == "" do return false
	sc, found := bridge_shell_session_scalars(&bridge_shell_session_map, session_id)
	if !found do return false
	if sc.background do return false
	switch sc.status {
	case .Exited, .Killed, .Failed:
		return false // nothing to background; it is already over
	case .Running, .Starting:
	}

	// An OWNED snapshot of the updated record, so re-saving the spec cannot read a
	// string the map has meanwhile superseded.
	updated, ok := bridge_shell_session_mark_background(&bridge_shell_session_map, session_id)
	if !ok do return false
	defer bridge_shell_session_snapshot_destroy(&bridge_shell_session_map, updated)

	data_dir := bridge_shell_data_dir()
	defer delete(data_dir)
	bridge_shell_session_save_spec(data_dir, updated)

	bridge_shell_wait_signal_backgrounded(session_id)
	return true
}

// ---- the 30-minute process cap for pty-host-spawned runs -------------------

// Bridge_Shell_Run_Cap_Ctx carries what the watchdog needs to identify the run it
// is capping. It holds the SESSION ID, not a process handle, because the decision
// to kill has to be re-made against the session's CURRENT state half an hour
// later — by then the run has usually finished and there is nothing to do.
Bridge_Shell_Run_Cap_Ctx :: struct {
	session_id: string,
}

// bridge_shell_run_cap_start arms the 30-minute hard cap on a pty-host-spawned
// RUN (REQ-SHELL-2 §8).
//
// WHY THIS EXISTS SEPARATELY. The cap used to live in the retired bridge-local exec
// path's reaper, which owned a direct child and could simply bound its wait. A run created through the hub
// path has no such owner: the process belongs to the pty-host daemon, and nothing
// on the bridge was watching the clock for it. So `ham-ctl shell run` would have
// been the one run shape with NO cap at all — the opposite of what §8 asks for.
//
// IT IS ARMED FOR kind=Run ONLY, and that is the whole of the "a server is not
// capped" requirement: a server never gets a watchdog, so there is no 30-minute
// timer to escape. Expressing it as "only runs are armed" rather than "servers are
// exempt" means a future kind is uncapped until someone deliberately caps it,
// which is the safer default for a long-running process.
//
// The cap bounds the PROCESS and nothing else: no waiter is consulted, and a
// dropped or absent waiter neither extends nor shortens it (W4).
bridge_shell_run_cap_start :: proc(session_id: string, kind: Bridge_Shell_Session_Kind) {
	if kind != .Run || session_id == "" do return
	heap := runtime.default_allocator()
	ctx := new(Bridge_Shell_Run_Cap_Ctx, heap)
	ctx.session_id = strings.clone(session_id, heap)
	thread.run_with_data(rawptr(ctx), bridge_shell_run_cap_worker)
}

@(private = "file")
bridge_shell_run_cap_worker :: proc(data: rawptr) {
	ctx := (^Bridge_Shell_Run_Cap_Ctx)(data)
	heap := runtime.default_allocator()
	defer {
		delete(ctx.session_id, heap)
		free(ctx, heap)
		free_all(context.temp_allocator)
	}

	// Wake periodically rather than sleeping the full half hour in one go, so a run
	// that finishes early releases this thread promptly instead of pinning it (and
	// its stack) for thirty minutes after the work is done. The CAP itself is still
	// measured from spawn — the loop only changes how often we check.
	deadline := time.time_add(time.now(), BRIDGE_SHELL_HARD_TIMEOUT)
	for {
		remaining := time.diff(time.now(), deadline)
		if remaining <= 0 do break
		step := 5 * time.Second
		if remaining < step do step = remaining
		time.sleep(step)

		sc, found := bridge_shell_session_scalars(&bridge_shell_session_map, ctx.session_id)
		if !found do return // reconciled away; nothing left to cap
		switch sc.status {
		case .Exited, .Killed, .Failed:
			return // finished on its own, which is the overwhelmingly common case
		case .Running, .Starting:
		}
	}

	// Still live at the cap. Kill it through the SAME path a user's kill takes
	// (bridge_hub_handle_shell_kill's worker), so a capped run is torn down, marked
	// and reported exactly like any other killed run rather than through a private
	// code path with its own subtly different behaviour.
	sc, found := bridge_shell_session_scalars(&bridge_shell_session_map, ctx.session_id)
	if !found do return
	switch sc.status {
	case .Exited, .Killed, .Failed:
		return
	case .Running, .Starting:
	}

	// An OWNED clone of the daemon key (shell_id, or session_id when it was never
	// recorded). The fallback lives in the accessor now, not here.
	shell_id, have_key := bridge_shell_session_shell_id(&bridge_shell_session_map, ctx.session_id)
	if !have_key do return
	defer bridge_shell_session_str_delete(&bridge_shell_session_map, shell_id)
	bridge_shell_session_update_status(&bridge_shell_session_map, ctx.session_id, .Killed, -1, false)
	// context.allocator, NOT runtime.default_allocator(), and that is the deliberate
	// choice rather than an oversight: Bridge_Shell_Kill_Ctx is freed by
	// bridge_shell_kill_worker through the implicit context.allocator, so allocating
	// it from a pinned heap here would pair a pinned alloc with an unpinned free —
	// the exact half-applied shape that makes the mismatch invisible until a context
	// carries a non-default allocator. One allocator per struct, on every path; see
	// the note on Bridge_Shell_Kill_Ctx itself.
	kctx := new(Bridge_Shell_Kill_Ctx)
	kctx.session_id = strings.clone(ctx.session_id)
	kctx.shell_id   = strings.clone(shell_id)
	thread.run_with_data(rawptr(kctx), bridge_shell_kill_worker)
}
