package taskv2

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// Timer_Service (plan §2.3): a min-heap of (due, kind, key, armed_deadline) that
// is purely a CACHE over columns. The columns are the truth —
// task_leases.expires_at / hard_deadline_at / confirmed_at, tasks.ready_since,
// tasks.blocked_on_json.since, agent_instances.last_seen_at — so:
//   * a timer is never cancelled: on fire it re-reads the row and is a no-op when
//     the deadline moved (heartbeat), the row is gone (released) or the state
//     changed (answered);
//   * the heap is rebuilt from the columns on boot (rebuild_timers);
//   * tests drive fire_due(now) with a fake clock; the thread is a thin wrapper.
//
// MEM-4: keys are heap-cloned under the mutex. Request threads arm timers from a
// per-request arena (context.allocator is freed at disconnect), so a key that
// aliased the request body would dangle at the next probe.

Timer_Kind :: enum {
	Lease_TTL,         // key = lease_id,    armed = expires_at
	Lease_Hard_Cap,    // key = lease_id,    armed = hard_deadline_at
	Grant_Unconfirmed, // key = lease_id,    armed = granted_at (+ resend count via events)
	Idle_Grace,        // key = instance_id, armed = lease.last_beat_at
	Idle_TTL,          // key = instance_id, armed = "" (release time)
	Ready_Unclaimed,   // key = task_id,     armed = ready_since
	Blocked_Realert,   // key = task_id,     armed = blocked_on_json
}

Timer :: struct {
	due_ms: i64,
	kind:   Timer_Kind,
	// key and armed are heap-owned copies (runtime.heap_allocator()).
	key:    string,
	armed:  string,
	seq:    u64,
}

Timer_Service :: struct {
	mutex:  sync.Mutex,
	heap:   [dynamic]Timer,
	seq:    u64,
	// stop asks the thin thread to exit (tests never start it).
	stop:   bool,
}

LEASE_TTL_SECONDS           :: 15 * 60
LEASE_HARD_CAP_SECONDS      :: 60 * 60
GRANT_UNCONFIRMED_SECONDS   :: 180
IDLE_GRACE_SECONDS          :: 5 * 60
IDLE_TTL_DEFAULT_SECONDS    :: 600
READY_UNCLAIMED_SECONDS     :: 10 * 60
BLOCKED_REALERT_SECONDS     :: 24 * 60 * 60
CLOCK_JUMP_SEEN_WITHIN_SECONDS :: 120

// timers_arm schedules a fire at due_ms. Thread-safe; O(log n).
timers_arm :: proc(svc: ^Service, kind: Timer_Kind, key: string, due_ms: i64, armed: string) {
	if svc == nil || key == "" do return
	ts := &svc.timers
	sync.mutex_lock(&ts.mutex)
	defer sync.mutex_unlock(&ts.mutex)
	if ts.heap == nil do ts.heap = make([dynamic]Timer, runtime.heap_allocator())
	ts.seq += 1
	t := Timer{
		due_ms = due_ms,
		kind = kind,
		key = strings.clone(key, runtime.heap_allocator()),
		armed = strings.clone(armed, runtime.heap_allocator()),
		seq = ts.seq,
	}
	append(&ts.heap, t)
	heap_up(ts.heap[:], len(ts.heap) - 1)
	timrics_set_armed(len(ts.heap))
}

timers_armed_count :: proc(svc: ^Service) -> int {
	sync.mutex_lock(&svc.timers.mutex)
	defer sync.mutex_unlock(&svc.timers.mutex)
	return len(svc.timers.heap)
}

// timers_pop_due removes and returns every timer with due_ms <= now_ms. The
// caller owns the returned slice and its strings (timer_destroy).
timers_pop_due :: proc(svc: ^Service, now_ms: i64) -> []Timer {
	ts := &svc.timers
	out := make([dynamic]Timer)
	sync.mutex_lock(&ts.mutex)
	defer sync.mutex_unlock(&ts.mutex)
	for len(ts.heap) > 0 && ts.heap[0].due_ms <= now_ms {
		top := ts.heap[0]
		last := len(ts.heap) - 1
		ts.heap[0] = ts.heap[last]
		pop(&ts.heap)
		if len(ts.heap) > 0 do heap_down(ts.heap[:], 0)
		append(&out, top)
	}
	timrics_set_armed(len(ts.heap))
	return out[:]
}

timer_destroy :: proc(t: ^Timer) {
	delete(t.key, runtime.heap_allocator())
	delete(t.armed, runtime.heap_allocator())
}

@(private = "file")
timer_less :: proc(a, b: Timer) -> bool {
	if a.due_ms != b.due_ms do return a.due_ms < b.due_ms
	return a.seq < b.seq
}

@(private = "file")
heap_up :: proc(h: []Timer, i_in: int) {
	i := i_in
	for i > 0 {
		p := (i - 1) / 2
		if !timer_less(h[i], h[p]) do break
		h[i], h[p] = h[p], h[i]
		i = p
	}
}

@(private = "file")
heap_down :: proc(h: []Timer, i_in: int) {
	i := i_in
	n := len(h)
	for {
		l := 2*i + 1
		r := 2*i + 2
		m := i
		if l < n && timer_less(h[l], h[m]) do m = l
		if r < n && timer_less(h[r], h[m]) do m = r
		if m == i do break
		h[i], h[m] = h[m], h[i]
		i = m
	}
}

// ---- deadline helpers --------------------------------------------------------------

add_seconds :: proc(rfc3339: string, seconds: int) -> string {
	out, ok := platform.expires_at_after_seconds_from(rfc3339, seconds)
	if !ok do return rfc3339
	return out
}

to_ms :: proc(rfc3339: string) -> i64 {
	ms, ok := platform.rfc3339_to_unix_ms(rfc3339)
	if !ok do return 0
	return ms
}

// min_rfc3339 returns the earlier of two hub timestamps ("" counts as +inf).
min_rfc3339 :: proc(a, b: string) -> string {
	if a == "" do return b
	if b == "" do return a
	return a if a <= b else b
}

// ---- arming from engine events -------------------------------------------------------

arm_lease_timers :: proc(svc: ^Service, lease: domain.Task_Lease) {
	timers_arm(svc, .Lease_TTL, lease.lease_id, to_ms(lease.expires_at), lease.expires_at)
	timers_arm(svc, .Lease_Hard_Cap, lease.lease_id, to_ms(lease.hard_deadline_at), lease.hard_deadline_at)
	if lease.confirmed_at == "" {
		timers_arm(svc, .Grant_Unconfirmed, lease.lease_id, to_ms(lease.granted_at) + GRANT_UNCONFIRMED_SECONDS * 1000, lease.granted_at)
	}
}

// arm_idle_ttl: `idle_since` (= the release time written to the instance row)
// is the armed stamp; a later release moves it and the older timer is a no-op.
arm_idle_ttl :: proc(svc: ^Service, instance_id: string, idle_ttl_seconds: int, idle_since: string) {
	ttl := idle_ttl_seconds
	if ttl <= 0 do ttl = IDLE_TTL_DEFAULT_SECONDS
	timers_arm(svc, .Idle_TTL, instance_id, to_ms(idle_since) + i64(ttl) * 1000, idle_since)
}

arm_task_timers :: proc(svc: ^Service, task: domain.Task) {
	if task.state == .Ready && task.ready_since != "" {
		timers_arm(svc, .Ready_Unclaimed, string(task.task_id), to_ms(task.ready_since) + READY_UNCLAIMED_SECONDS * 1000, task.ready_since)
	}
	if task.blocked_on_json != "" && strings.contains(task.blocked_on_json, `"human"`) {
		timers_arm(svc, .Blocked_Realert, string(task.task_id), now_ms(svc.clock) + BLOCKED_REALERT_SECONDS * 1000, task.blocked_on_json)
	}
}

// rebuild_timers (boot): arm from the columns — every lease, every ready task,
// every blocked-on-human task. Nothing else is persisted; nothing else is needed.
rebuild_timers :: proc(svc: ^Service) {
	leases, lerr := iface.taskchain_list_all_leases(svc.repo)
	if lerr.code == .None {
		for l in leases do arm_lease_timers(svc, l)
	}
	ready, rerr := iface.taskchain_list_tasks_by_state(svc.repo, .Ready)
	if rerr.code == .None {
		for t in ready do arm_task_timers(svc, t)
	}
	backlog, berr := iface.taskchain_list_tasks_by_state(svc.repo, .Backlog)
	if berr.code == .None {
		for t in backlog do arm_task_timers(svc, t)
	}
	// Idle_TTL from agent_instances.idle_since (live, lease-free instances).
	if insts, ierr := iface.agent_list_active_runtime_instances(svc.agents); ierr.code == .None {
		for inst in insts {
			if inst.idle_since == "" || inst.chain_id == "" do continue
			if _, held, _ := iface.taskchain_get_lease_by_holder(svc.repo, inst.agent_instance_id); held do continue
			arm_idle_ttl(svc, inst.agent_instance_id, fleet_idle_ttl(svc, domain.Task_Chain_ID(inst.chain_id), inst.owner_user_id, inst.agent_id), inst.idle_since)
		}
	}
}

// ---- firing -----------------------------------------------------------------------

// Fire_Result: Noop (deadline moved / row gone / state changed), Acted, or
// Failed — a partial write that must be rolled back, never committed (S2).
Fire_Result :: enum { Noop, Acted, Failed }

// fire_due pops every timer due at now_ms and fires it: ONE unit of work per
// timer, each re-reading its column before acting. Returns the number fired.
// `jump_detected` is the timer thread's "now − last tick > TTL" signal (plan
// §2.4 clock-jump rule); tests pass it explicitly.
fire_due :: proc(svc: ^Service, now_ms: i64, jump_detected := false) -> int {
	due := timers_pop_due(svc, now_ms)
	defer delete(due)
	fired := 0
	for &t in due {
		fire_timer(svc, t, now_ms, jump_detected)
		timer_destroy(&t)
		fired += 1
	}
	return fired
}

@(private = "file")
fire_timer :: proc(svc: ^Service, t: Timer, now_ms: i64, jump_detected: bool) {
	u, ok, _ := begin_uow(svc)
	if !ok do return
	r := Fire_Result.Noop
	switch t.kind {
	case .Lease_TTL:        r = fire_lease_ttl(svc, &u, t, now_ms, jump_detected)
	case .Lease_Hard_Cap:   r = fire_lease_hard_cap(svc, &u, t)
	case .Grant_Unconfirmed: r = fire_grant_unconfirmed(svc, &u, t)
	case .Idle_Grace:       r = fire_idle_grace(svc, &u, t)
	case .Idle_TTL:         r = fire_idle_ttl(svc, &u, t)
	case .Ready_Unclaimed:  r = fire_ready_unclaimed(svc, &u, t)
	case .Blocked_Realert:  r = fire_blocked_realert(svc, &u, t)
	}
	if r == .Failed {
		fmt.eprintfln("[taskv2] timer %v for %s failed; rolled back", t.kind, t.key)
		// Re-arm so the condition is re-evaluated next tick instead of being lost.
		timers_arm(svc, t.kind, t.key, now_ms + 1000, t.armed)
	}
	_, _ = end_uow(svc, &u, r != .Failed)
}

@(private = "file")
expire_result_to_fire :: proc(r: Expire_Result) -> Fire_Result {
	switch r {
	case .Expired: return .Acted
	case .Gone: return .Noop
	case .Failed: return .Failed
	}
	return .Noop
}

@(private = "file")
fire_lease_ttl :: proc(svc: ^Service, u: ^Uow, t: Timer, now_ms: i64, jump_detected: bool) -> Fire_Result {
	lease, ok, _ := iface.taskchain_get_lease(svc.repo, t.key)
	if !ok do return .Noop                                  // released meanwhile
	if lease.expires_at != t.armed do return .Noop         // heartbeat moved it; the newer timer owns it
	// Clock-jump rule (plan §2.4): ONLY when the timer thread detected a jump
	// (hub suspended / clock stepped), a holder that is demonstrably alive
	// (busy, seen in the last 2 min) gets ONE extension instead of a
	// mass-expiry restart. Recorded on the lease row (extended_at), S5.
	if jump_detected && lease.extended_at == "" {
		if inst, iok, _ := iface.agent_get_instance(svc.agents, lease.holder_instance_id); iok {
			if inst.activity_status == "busy" && now_ms - to_ms(inst.last_seen_at) <= CLOCK_JUMP_SEEN_WITHIN_SECONDS * 1000 {
				now := platform.clock_now(svc.clock)
				lease.expires_at = min_rfc3339(add_seconds(now, LEASE_TTL_SECONDS), lease.hard_deadline_at)
				lease.last_beat_at = now
				lease.extended_at = now
				if _, sok, _ := iface.taskchain_save_lease(svc.repo, lease); !sok do return .Failed
				if task, tok, _ := iface.taskchain_get_task(svc.repo, lease.task_id); tok {
					p := json_begin()
					json_str(&p, "lease_id", lease.lease_id)
					json_str(&p, "reason", "hub_resume")
					_, _, _ = append_event(svc.repo, svc.clock, task, hub_actor(), EV_LEASE_EXTENDED, json_end(&p))
				}
				timers_arm(svc, .Lease_TTL, lease.lease_id, to_ms(lease.expires_at), lease.expires_at)
				return .Acted
			}
		}
	}
	return expire_then_match(svc, u, lease, EXPIRE_TTL)
}

// expire_then_match: a timer-driven expiry followed by exactly one matcher run
// for the lease's chain (review B3: the matcher never runs inside expire).
@(private = "file")
expire_then_match :: proc(svc: ^Service, u: ^Uow, lease: domain.Task_Lease, reason: string) -> Fire_Result {
	r := expire_result_to_fire(expire_lease_in_uow(svc, u, lease, reason, hub_actor()))
	if r != .Acted do return r
	if ok, _ := after_chain_change(svc, u, lease.chain_id, lease.owner_user_id, .Lease_Expired); !ok do return .Failed
	return .Acted
}

@(private = "file")
fire_lease_hard_cap :: proc(svc: ^Service, u: ^Uow, t: Timer) -> Fire_Result {
	lease, ok, _ := iface.taskchain_get_lease(svc.repo, t.key)
	if !ok do return .Noop
	if lease.hard_deadline_at != t.armed do return .Noop
	return expire_then_match(svc, u, lease, EXPIRE_HARD_CAP)
}

@(private = "file")
fire_grant_unconfirmed :: proc(svc: ^Service, u: ^Uow, t: Timer) -> Fire_Result {
	lease, ok, _ := iface.taskchain_get_lease(svc.repo, t.key)
	if !ok do return .Noop
	if lease.confirmed_at != "" do return .Noop
	if lease.granted_at != t.armed do return .Noop
	task, tok, _ := iface.taskchain_get_task(svc.repo, lease.task_id)
	if !tok do return .Noop
	if !lease_resent(svc, lease) {
		// Re-send the wake ONCE (the bridge may have dropped the frame), then
		// give it another window.
		p := json_begin()
		json_str(&p, "lease_id", lease.lease_id)
		if _, aok, _ := append_event(svc.repo, svc.clock, task, hub_actor(), EV_LEASE_RESENT, json_end(&p)); !aok do return .Failed
		effect_wake_lease(svc, u, lease, task)
		timers_arm(svc, .Grant_Unconfirmed, lease.lease_id, now_ms(svc.clock) + GRANT_UNCONFIRMED_SECONDS * 1000, lease.granted_at)
		return .Acted
	}
	return expire_then_match(svc, u, lease, EXPIRE_UNCONFIRMED)
}

@(private = "file")
lease_resent :: proc(svc: ^Service, lease: domain.Task_Lease) -> bool {
	evs, err := iface.taskchain_list_events_by_task(svc.repo, lease.task_id, lease.owner_user_id)
	if err.code != .None do return false
	for e in evs {
		if e.kind == EV_LEASE_RESENT && strings.contains(e.payload_json, lease.lease_id) do return true
	}
	return false
}

@(private = "file")
fire_idle_grace :: proc(svc: ^Service, u: ^Uow, t: Timer) -> Fire_Result {
	lease, ok, _ := iface.taskchain_get_lease_by_holder(svc.repo, t.key)
	if !ok do return .Noop
	if lease.last_beat_at != t.armed do return .Noop       // a heartbeat happened; idle grace restarted elsewhere
	inst, iok, _ := iface.agent_get_instance(svc.agents, t.key)
	if !iok do return .Noop
	if inst.activity_status != "idle" do return .Noop      // busy again
	return expire_then_match(svc, u, lease, EXPIRE_IDLE)
}

@(private = "file")
fire_idle_ttl :: proc(svc: ^Service, u: ^Uow, t: Timer) -> Fire_Result {
	if _, held, _ := iface.taskchain_get_lease_by_holder(svc.repo, t.key); held do return .Noop
	inst, iok, _ := iface.agent_get_instance(svc.agents, t.key)
	if !iok do return .Noop
	if inst.idle_since == "" || inst.idle_since != t.armed do return .Noop // re-leased and released again: the newer timer owns it (S4)
	if !instance_is_live(inst) do return .Noop
	if inst.chain_id != "" {
		if chain, cok, _ := iface.taskchain_get_chain(svc.repo, domain.Task_Chain_ID(inst.chain_id)); cok {
			if is_coordinator(svc, chain, inst.agent_instance_id) do return .Noop
		}
	}
	effect_stop(u, inst.bridge_id, inst.chain_id, inst.agent_instance_id)
	return .Acted
}

@(private = "file")
fire_ready_unclaimed :: proc(svc: ^Service, u: ^Uow, t: Timer) -> Fire_Result {
	task, ok, _ := iface.taskchain_get_task(svc.repo, domain.Task_ID(t.key))
	if !ok do return .Noop
	if task.state != .Ready || task.ready_since != t.armed do return .Noop
	p := json_begin()
	json_str(&p, "since", task.ready_since)
	if _, aok, _ := append_event(svc.repo, svc.clock, task, hub_actor(), EV_READY_UNCLAIMED, json_end(&p)); !aok do return .Failed
	effect_publish_task(u, task, "ready_unclaimed")
	effect_notify_coordinator(svc, u, task.chain_id, task.owner_user_id, "ready_unclaimed", fmt.tprintf("[taskv2] ready_unclaimed: task %s (%s) ready since %s", task.task_id, task.title, task.ready_since))
	return .Acted
}

@(private = "file")
fire_blocked_realert :: proc(svc: ^Service, u: ^Uow, t: Timer) -> Fire_Result {
	task, ok, _ := iface.taskchain_get_task(svc.repo, domain.Task_ID(t.key))
	if !ok do return .Noop
	if task.blocked_on_json == "" || task.blocked_on_json != t.armed do return .Noop
	p := json_begin()
	json_raw(&p, "blocked_on", task.blocked_on_json)
	if _, aok, _ := append_event(svc.repo, svc.clock, task, hub_actor(), EV_BLOCKED_REALERT, json_end(&p)); !aok do return .Failed
	effect_publish_task(u, task, "blocked_realert")
	effect_notify_coordinator(svc, u, task.chain_id, task.owner_user_id, "blocked_on human", fmt.tprintf("[taskv2] blocked_on human: task %s (%s) still waiting on human input", task.task_id, task.title))
	timers_arm(svc, .Blocked_Realert, string(task.task_id), now_ms(svc.clock) + BLOCKED_REALERT_SECONDS * 1000, task.blocked_on_json)
	return .Acted
}

// ---- the thin thread -----------------------------------------------------------------

// start_timer_thread runs fire_due once a second against the service clock. It
// is a 1 s check of an in-memory heap, not a table sweep.
start_timer_thread :: proc(svc: ^Service) -> ^thread.Thread {
	t := thread.create(timer_thread_proc)
	t.data = rawptr(svc)
	thread.start(t)
	return t
}

@(private = "file")
timer_thread_proc :: proc(t: ^thread.Thread) {
	svc := (^Service)(t.data)
	// Everything a tick allocates (repository rows, payloads, effects) is
	// scratch: route the thread's allocator to its temp arena and free it per
	// tick. Heap-lived state (timer keys, recent_expiries) names
	// runtime.heap_allocator explicitly.
	context.allocator = context.temp_allocator
	last_tick := now_ms(svc.clock)
	for !sync.atomic_load(&svc.timers.stop) {
		time.sleep(time.Second)
		now := now_ms(svc.clock)
		// Clock jump (plan §2.4): the hub slept/was suspended for longer than
		// a TTL; TTL fires in this tick may grant the one-shot extension.
		jump := now - last_tick > LEASE_TTL_SECONDS * 1000
		last_tick = now
		_ = fire_due(svc, now, jump)
		// Per-tick scratch (wake keys, JSON) lives on the temp allocator.
		free_all(context.temp_allocator)
	}
}

stop_timer_thread :: proc(svc: ^Service) {
	sync.atomic_store(&svc.timers.stop, true)
}
