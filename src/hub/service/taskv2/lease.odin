package taskv2

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import jsonx "odin_test:lib/jsonx"

// Leases (plan §2.5). A lease is the ONLY way to work: one instance ⇄ one lease ⇄
// one task. Rows are deleted on release (history is in events/attempts); the two
// DB uniques (holder; task WHERE kind='work') are the backstop against a double
// grant under any bug above them.

// Placement is where a grant lands (plan §4a): task pin → fleet row bridge_id →
// chain directory bridge → coordinator bridge. `directory_id` is the chain
// directory on that bridge (first by created_at), or "" when the chain has no
// directory there — it carries the ≤ 1 live work lease per directory rule.
Placement :: struct {
	bridge_id:    string,
	directory_id: string,
	provider:     string,
	model:        string,
}

Grant_Request :: struct {
	chain:       domain.Task_Chain,
	task:        domain.Task,
	instance:    domain.Agent_Instance,
	kind:        string, // work | review
	review_role: string,
	delivery:    string, // wake | inline
	placement:   Placement,
	actor:       Actor,
	trigger:     Trigger,
}

// grant_in_uow performs every grant check, writes the lease + events + attempt,
// refolds the task, mirrors the pointer onto the instance, arms timers and (for
// wake delivery) queues the wake effect. Errors are 409 Conflict for every
// precondition that is a race rather than a caller bug.
grant_in_uow :: proc(svc: ^Service, u: ^Uow, req: Grant_Request) -> (domain.Task_Lease, bool, domain.Domain_Error) {
	if u == nil || !u.has_tx do return {}, false, domain.domain_error(.Internal_Error, "lease grants require a unit of work")
	// Matcher callers deliberately skip a failed grant and keep their outer
	// transaction. Isolate ALL grant writes, including consumption receipts,
	// so a skipped candidate cannot leave a lease, event or attempt behind.
	nested, nok, nerr := begin_uow(svc)
	if !nok do return {}, false, nerr
	lease, ok, err := grant_attempt_in_uow(svc, &nested, req)
	if !ok {
		_, _ = end_uow(svc, &nested, false)
		return {}, false, err
	}
	committed, cerr := iface.unit_of_work_commit(&nested.tx)
	nested.has_tx = false
	if !committed {
		cancel_reservations(svc, &nested.effects)
		destroy_effects(&nested.effects)
		return {}, false, cerr
	}
	// Transfer ownership directly to the parent, rather than registering a
	// callback whose lifetime could outlast a parent transaction rollback.
	move_effects(&u.effects, &nested.effects)
	return lease, true, domain.Domain_Error{}
}

@(private = "file")
grant_attempt_in_uow :: proc(svc: ^Service, u: ^Uow, req: Grant_Request) -> (domain.Task_Lease, bool, domain.Domain_Error) {
	task := req.task
	if task.workflow_run_id != "" {
		wf, ok, err := workflow_context(svc, task.workflow_run_id, task.owner_user_id)
		if !ok do return {}, false, err
		if wf.execution.execution_no != task.workflow_execution_no || wf.execution.state != "running" {
			return {}, false, domain.domain_error(.Conflict, "workflow execution is no longer running")
		}
	}
	inst := req.instance
	if task.kind == .Gate do return {}, false, domain.domain_error(.Conflict, "gates are never granted")
	if req.kind == domain.LEASE_KIND_WORK && task.state != .Ready do return {}, false, domain.domain_error(.Conflict, "task is not ready")
	if req.kind == domain.LEASE_KIND_WORK && task.stage_key == "" {
		ready, err := work_dependencies_ready_in_uow(svc, task.chain_id, task.owner_user_id, domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK, id = string(task.task_id)})
		if err.code != .None do return {}, false, err
		if !ready do return {}, false, domain.domain_error(.Conflict, "work prerequisites have not succeeded", `{"code":"prerequisite_unsatisfied"}`)
	}
	if req.kind == domain.LEASE_KIND_REVIEW && task.state != .In_Review do return {}, false, domain.domain_error(.Conflict, "task is not in review")
	if !instance_in_chain(svc, req.chain, inst) do return {}, false, domain.domain_error(.Conflict, "instance is not a member of the task's chain")
	// The coordinator works only in a solo chain, and only by pulling
	// (`lease next`, inline): the hub never wakes, restarts or stops it.
	if is_coordinator(svc, req.chain, inst.agent_instance_id) && !(req.delivery == domain.LEASE_DELIVERY_INLINE && chain_is_solo(svc, req.chain)) {
		return {}, false, domain.domain_error(.Conflict, "the chain coordinator is never granted a lease (outside solo mode)")
	}
	if _, held, _ := iface.taskchain_get_lease_by_holder(svc.repo, inst.agent_instance_id); held do return {}, false, domain.domain_error(.Conflict, "instance already holds a lease")
	if !bridge_online(svc, req.placement.bridge_id) do return {}, false, domain.domain_error(.Bridge_Offline, "placement bridge is offline")
	if req.kind == domain.LEASE_KIND_WORK && req.placement.directory_id != "" {
		if directory_has_work_lease(svc, req.chain, req.placement.directory_id) do return {}, false, domain.domain_error(.Conflict, "another work lease is live on this chain directory")
	}
	now := platform.clock_now(svc.clock)
	ttl := LEASE_TTL_SECONDS
	hard := brief_budget_seconds(task.brief_json, "hard_deadline", LEASE_HARD_CAP_SECONDS)
	lease := domain.Task_Lease{
		lease_id = platform.generate_id(svc.ids, "lease_"),
		task_id = task.task_id,
		chain_id = task.chain_id,
		owner_user_id = task.owner_user_id,
		holder_instance_id = inst.agent_instance_id,
		kind = req.kind,
		review_role = req.review_role,
		bridge_id = req.placement.bridge_id,
		provider = req.placement.provider,
		model = req.placement.model,
		granted_at = now,
		confirmed_at = now if req.delivery == domain.LEASE_DELIVERY_INLINE else "",
		expires_at = add_seconds(now, ttl),
		hard_deadline_at = add_seconds(now, hard),
		last_beat_at = now,
		delivery = req.delivery if req.delivery != "" else domain.LEASE_DELIVERY_WAKE,
	}
	// attempt_no is what the fold will say AFTER the grant event; compute it by
	// folding once (cheap) so the lease and attempt rows carry the right number.
	evs, eerr := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
	if eerr.code != .None do return {}, false, eerr
	pre := fold_task(evs, fold_input_for_task(task, true))
	if req.kind == domain.LEASE_KIND_WORK && !budget_allows_grant(pre, brief_max_attempts(task.brief_json)) {
		return {}, false, domain.domain_error(.Conflict, "attempt budget exhausted; the task waits for a human")
	}
	attempt_no := pre.attempt_no
	if req.kind == domain.LEASE_KIND_WORK && pre.last_release != .Handoff do attempt_no += 1
	lease.attempt_no = attempt_no

	saved, ok, err := iface.taskchain_save_lease(svc.repo, lease)
	if !ok do return {}, false, err
	p := json_begin()
	json_str(&p, "lease_id", saved.lease_id)
	json_str(&p, "kind", saved.kind)
	json_str(&p, "instance_id", saved.holder_instance_id)
	json_int(&p, "attempt_no", i64(saved.attempt_no))
	json_str(&p, "bridge_id", saved.bridge_id)
	json_str(&p, "provider", saved.provider)
	json_str(&p, "model", saved.model)
	json_str(&p, "delivery", saved.delivery)
	if saved.review_role != "" do json_str(&p, "review_role", saved.review_role)
	json_str(&p, "agent_id", inst.agent_id)
	refolded, view, rok, rerr := record_event(svc, u, task, req.actor, EV_LEASE_GRANTED, json_end(&p))
	if !rok do return {}, false, rerr
	if req.kind == domain.LEASE_KIND_WORK {
		counts := true
		#partial switch pre.last_release {
		case .Replaced, .Dep_Added, .Reopened, .User_Stopped, .Released_Noncounting: counts = false
		}
		if pre.last_release != .Handoff {
			_, aok, aerr := iface.taskchain_save_attempt(svc.repo, domain.Task_Attempt{
				task_id = task.task_id, attempt_no = view.attempt_no, chain_id = task.chain_id, owner_user_id = task.owner_user_id,
				started_at = now, holder_instance_id = inst.agent_instance_id, counts_toward_budget = counts,
			})
			if !aok do return {}, false, aerr
		} else if attempts, aerr := iface.taskchain_list_attempts_by_task(svc.repo, task.task_id, task.owner_user_id); aerr.code == .None {
			// handoff continuation: the attempt row stays open, new holder recorded
			for a in attempts {
				if a.attempt_no == view.attempt_no {
					cont := a
					cont.holder_instance_id = inst.agent_instance_id
					cont.ended_at = ""
					cont.outcome = ""
					_, _, _ = iface.taskchain_save_attempt(svc.repo, cont)
				}
			}
		}
		if task.stage_key == "" {
			captured, cerr := work_capture_inputs_in_uow(svc, task.chain_id, task.owner_user_id, domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK, id = string(task.task_id)})
			if !captured do return {}, false, cerr
		}
		rt := json_begin()
		json_str(&rt, "bridge_id", saved.bridge_id if saved.bridge_id != "" else inst.bridge_id)
		json_str(&rt, "provider", saved.provider if saved.provider != "" else inst.provider)
		json_str(&rt, "model", saved.model if saved.model != "" else inst.model)
		json_str(&rt, "started_at", now)
		json_str(&rt, "ended_at", "")
		_, _ = save_facet_verbatim(svc, refolded, view.attempt_no, FACET_RUNTIME, json_end(&rt), FACET_WRITER_HUB)
	}
	set_instance_pointer(svc, inst.agent_instance_id, string(task.task_id), .Work if req.kind == domain.LEASE_KIND_WORK else .Review)
	arm_lease_timers(svc, saved)
	metric_lease_granted(saved.kind)
	if saved.delivery == domain.LEASE_DELIVERY_WAKE do effect_wake_lease(svc, u, saved, refolded)
	return saved, true, domain.Domain_Error{}
}

// release_in_uow is the SHARED release path for submit / block / handoff (M2 adds
// the verbs on top): delete the lease, append `event_kind`, refold, close the
// attempt row, clear the pointer, stop the holder (fresh context per attempt),
// arm idle_ttl for the released instance. Callers then run match_chain.
release_in_uow :: proc(svc: ^Service, u: ^Uow, lease: domain.Task_Lease, actor: Actor, event_kind: string, payload_json: string, outcome: string, stop_holder := true) -> (domain.Task, bool, domain.Domain_Error) {
	task, tok, terr := iface.taskchain_get_task(svc.repo, lease.task_id)
	if !tok do return {}, false, terr
	if deleted, derr := iface.taskchain_delete_lease(svc.repo, lease.lease_id); !deleted {
		if derr.code != .None do return {}, false, derr
		return {}, false, domain.domain_error(.Conflict, "lease_lost")
	}
	metric_lease_released(lease.kind)
	refolded, _, rok, rerr := record_event(svc, u, task, actor, event_kind, payload_json)
	if !rok do return {}, false, rerr
	close_attempt(svc, lease, outcome)
	now := platform.clock_now(svc.clock)
	mark_instance_idle(svc, lease.holder_instance_id, now)
	if inst, iok, _ := iface.agent_get_instance(svc.agents, lease.holder_instance_id); iok {
		// The lease system never stops (or idles out) a chain coordinator — a
		// solo coordinator keeps its process and pulls its next task (REQ-SOLO-2a).
		if holder_is_coordinator(svc, task.chain_id, lease.holder_instance_id) do return refolded, true, domain.Domain_Error{}
		// Fresh context per attempt: the holder is stopped (the next grant, even
		// to the same instance, re-bootstraps it). stop_holder=false is for a
		// caller that continues the same process inline.
		if stop_holder {
			effect_stop(u, inst.bridge_id, string(task.chain_id), inst.agent_instance_id)
		}
		arm_idle_ttl(svc, inst.agent_instance_id, fleet_idle_ttl(svc, task.chain_id, task.owner_user_id, inst.agent_id), now)
	}
	return refolded, true, domain.Domain_Error{}
}

// expire_lease_in_uow ends a lease the holder did not release: TTL, hard cap,
// idle, instance lost, grant unconfirmed, replaced, dep_added, chain closed.
// Work expiries are what the budget counts (fold rule); review expiries just
// free the reviewer. The holder is stopped unless it is already gone.
// Result: Gone = the lease row no longer exists (someone released it first —
// the timer-vs-verb race, a no-op for the caller), Failed = a write failed and
// the caller must ROLL BACK (review S2: never commit "lease gone, no event").
Expire_Result :: enum { Expired, Gone, Failed }

expire_lease_in_uow :: proc(svc: ^Service, u: ^Uow, lease: domain.Task_Lease, reason: string, actor: Actor) -> Expire_Result {
	task, tok, terr := iface.taskchain_get_task(svc.repo, lease.task_id)
	if !tok do return .Gone if terr.code == .Not_Found || terr.code == .None else .Failed
	// Event FIRST, then the row: an interrupted sequence leaves an event whose
	// fold says "no lease" and a row the next boot/TTL fire reclaims — never
	// the reverse (a row-less in_progress task).
	p := json_begin()
	json_str(&p, "lease_id", lease.lease_id)
	json_str(&p, "kind", lease.kind)
	json_int(&p, "attempt_no", i64(lease.attempt_no))
	json_str(&p, "reason", reason)
	json_str(&p, "instance_id", lease.holder_instance_id)
	// A solo coordinator's lapse is not a failed attempt: it is never stopped
	// and simply pulls again (REQ-SOLO-6). Recorded in the event so the pure
	// fold can tell (it never sees the holder).
	coordinator := holder_is_coordinator(svc, task.chain_id, lease.holder_instance_id)
	if coordinator && lease.kind == domain.LEASE_KIND_WORK do json_bool(&p, "counting", false)
	if _, still, _ := iface.taskchain_get_lease(svc.repo, lease.lease_id); !still do return .Gone
	if _, _, rok, _ := record_event(svc, u, task, actor, EV_LEASE_EXPIRED, json_end(&p)); !rok do return .Failed
	if deleted, derr := iface.taskchain_delete_lease(svc.repo, lease.lease_id); !deleted {
		if derr.code != .None do return .Failed
		return .Failed // vanished between the check and the delete: roll back, the other writer owns it
	}
	metric_lease_released(lease.kind)
	metric_lease_expired(reason)
	if lease.kind == domain.LEASE_KIND_WORK do close_attempt(svc, lease, fmt.tprintf("expired:%s", reason))
	now := platform.clock_now(svc.clock)
	mark_instance_idle(svc, lease.holder_instance_id, now)
	if coordinator do return .Expired // never stopped, may re-pull at once (no recent-expiry window)
	note_recent_expiry(svc, lease.holder_instance_id, to_ms(now))
	if inst, iok, _ := iface.agent_get_instance(svc.agents, lease.holder_instance_id); iok {
		if reason != EXPIRE_INSTANCE_LOST && instance_is_live(inst) {
			effect_stop(u, inst.bridge_id, string(task.chain_id), inst.agent_instance_id)
		}
		arm_idle_ttl(svc, inst.agent_instance_id, fleet_idle_ttl(svc, task.chain_id, task.owner_user_id, inst.agent_id), now)
	}
	// NOTE: no match_chain here (review B3). Every caller runs
	// after_chain_change exactly once at the end of its own UoW, after all of
	// its writes, so the matcher never acts on an intermediate state.
	return .Expired
}

// heartbeat_in_uow extends the TTL (never past the hard cap). An event is
// appended only with a note (plan C9).
heartbeat_in_uow :: proc(svc: ^Service, u: ^Uow, lease: domain.Task_Lease, actor: Actor, note: string) -> (domain.Task_Lease, bool, domain.Domain_Error) {
	now := platform.clock_now(svc.clock)
	next := lease
	next.last_beat_at = now
	next.expires_at = min_rfc3339(add_seconds(now, LEASE_TTL_SECONDS), lease.hard_deadline_at)
	saved, ok, err := iface.taskchain_save_lease(svc.repo, next)
	if !ok do return lease, false, err
	timers_arm(svc, .Lease_TTL, saved.lease_id, to_ms(saved.expires_at), saved.expires_at)
	if strings.trim_space(note) != "" {
		if task, tok, _ := iface.taskchain_get_task(svc.repo, lease.task_id); tok {
			p := json_begin()
			json_str(&p, "lease_id", lease.lease_id)
			json_str(&p, "note", note)
			_, _, _ = append_event(svc.repo, svc.clock, task, actor, EV_HEARTBEAT, json_end(&p))
			effect_publish_task(u, task, "heartbeat")
		}
	}
	return saved, true, domain.Domain_Error{}
}

// confirm_in_uow marks a wake-delivered lease confirmed (the holder's own
// start-success arrived). Idempotent.
confirm_in_uow :: proc(svc: ^Service, u: ^Uow, lease: domain.Task_Lease) -> bool {
	if lease.confirmed_at != "" do return true
	now := platform.clock_now(svc.clock)
	next := lease
	next.confirmed_at = now
	next.last_beat_at = now
	next.expires_at = min_rfc3339(add_seconds(now, LEASE_TTL_SECONDS), lease.hard_deadline_at)
	if _, ok, _ := iface.taskchain_save_lease(svc.repo, next); !ok do return false
	timers_arm(svc, .Lease_TTL, next.lease_id, to_ms(next.expires_at), next.expires_at)
	if task, tok, _ := iface.taskchain_get_task(svc.repo, lease.task_id); tok {
		p := json_begin()
		json_str(&p, "lease_id", lease.lease_id)
		_, _, _ = append_event(svc.repo, svc.clock, task, Actor{kind = ACTOR_AGENT, id = lease.holder_instance_id}, EV_LEASE_CONFIRMED, json_end(&p))
		effect_publish_task(u, task, "lease_confirmed")
	}
	return true
}

// on_dep_added_in_uow: a dependency added to a LEASED task expires its work
// lease first (reason dep_added, non-counting), so the holder is not left working
// on a task whose prerequisites just changed.
on_dep_added_in_uow :: proc(svc: ^Service, u: ^Uow, task: domain.Task, actor: Actor) -> (bool, domain.Domain_Error) {
	leases, err := iface.taskchain_list_leases_by_task(svc.repo, task.task_id)
	if err.code != .None do return false, err
	for l in leases {
		if l.kind != domain.LEASE_KIND_WORK do continue
		if expire_lease_in_uow(svc, u, l, EXPIRE_DEP_ADDED, actor) == .Failed do return false, domain.domain_error(.Internal_Error, "failed to expire lease on dep_added")
	}
	return true, domain.Domain_Error{}
}

// ---- chokepoints ---------------------------------------------------------------------

// on_instance_terminal is the ONE chokepoint for every instance-death path
// (runtime status stopped|unreachable|failed, reaper, bridge disconnect, delete,
// member removal): expire(instance_lost) → match_chain. Safe to call for an
// instance holding nothing (no-op, no UoW).
on_instance_terminal :: proc(svc: ^Service, instance_id: string) {
	if svc == nil || svc.repo == nil || instance_id == "" do return
	if _, held, _ := iface.taskchain_get_lease_by_holder(svc.repo, instance_id); !held do return
	// Bridge ABSENCE is not instance death (review B2): an instance marked
	// `unreachable` because its bridge disconnected keeps its lease; the TTL
	// expires it if the bridge stays away, and the hello-time heartbeat
	// reconcile reports real deaths as not-active (→ this chokepoint again,
	// with the bridge Online). stopped|failed always expire at once.
	if inst, iok, _ := iface.agent_get_instance(svc.agents, instance_id); iok {
		if inst.runtime_status == "unreachable" && !bridge_online(svc, inst.bridge_id) do return
	}
	u, ok, _ := begin_uow(svc)
	if !ok do return
	acted := false
	chain_id := domain.Task_Chain_ID("")
	owner := domain.User_ID("")
	if lease, held, _ := iface.taskchain_get_lease_by_holder(svc.repo, instance_id); held {
		acted = expire_lease_in_uow(svc, &u, lease, EXPIRE_INSTANCE_LOST, hub_actor()) == .Expired
		chain_id, owner = lease.chain_id, lease.owner_user_id
	}
	if acted do acted, _ = after_chain_change(svc, &u, chain_id, owner, .Instance_Terminal)
	_, _ = end_uow(svc, &u, acted)
}

// on_instance_user_stopped (F4): a person stopped the holder. Called by the
// agent service after it persisted stopped_by="user" and BEFORE it sends the
// stop, so the lease ends as user_stopped (non-counting) and the matcher —
// which never picks a user-stopped instance — hands the task to another
// instance. The later terminal report finds no lease (no-op).
on_instance_user_stopped :: proc(svc: ^Service, instance_id: string) {
	if svc == nil || svc.repo == nil || instance_id == "" do return
	lease, held, _ := iface.taskchain_get_lease_by_holder(svc.repo, instance_id)
	if !held do return
	u, ok, _ := begin_uow(svc)
	if !ok do return
	acted := expire_lease_in_uow(svc, &u, lease, EXPIRE_USER_STOPPED, Actor{kind = ACTOR_USER}) == .Expired
	if acted do acted, _ = after_chain_change(svc, &u, lease.chain_id, lease.owner_user_id, .Instance_Terminal)
	_, _ = end_uow(svc, &u, acted)
}

// on_instance_activity: `busy` is an implicit heartbeat and cancels idle grace
// (by moving last_beat_at); `idle` arms idle_grace for a lease holder.
on_instance_activity :: proc(svc: ^Service, instance_id, activity_status: string) {
	if svc == nil || svc.repo == nil || instance_id == "" do return
	lease, held, _ := iface.taskchain_get_lease_by_holder(svc.repo, instance_id)
	if !held do return
	switch activity_status {
	case "busy":
		touch_lease(svc, lease)
	case "idle":
		timers_arm(svc, .Idle_Grace, instance_id, now_ms(svc.clock) + IDLE_GRACE_SECONDS * 1000, lease.last_beat_at)
	}
}

// touch_instance is the implicit heartbeat for ANY instance-token API call.
// Cheap when the instance holds nothing (one read, no UoW).
touch_instance :: proc(svc: ^Service, instance_id: string) {
	if svc == nil || svc.repo == nil || instance_id == "" do return
	lease, held, _ := iface.taskchain_get_lease_by_holder(svc.repo, instance_id)
	if !held do return
	touch_lease(svc, lease)
}

// IMPLICIT_HEARTBEAT_MIN_SECONDS throttles implicit heartbeats (review S3): a
// chatty agent would otherwise write a row and arm a heap timer per call.
IMPLICIT_HEARTBEAT_MIN_SECONDS :: 30

@(private = "file")
touch_lease :: proc(svc: ^Service, lease: domain.Task_Lease) {
	if now_ms(svc.clock) - to_ms(lease.last_beat_at) < IMPLICIT_HEARTBEAT_MIN_SECONDS * 1000 do return
	u, ok, _ := begin_uow(svc)
	if !ok do return
	fresh, still, _ := iface.taskchain_get_lease(svc.repo, lease.lease_id)
	acted := false
	if still {
		_, acted, _ = heartbeat_in_uow(svc, &u, fresh, Actor{kind = ACTOR_AGENT, id = lease.holder_instance_id}, "")
	}
	_, _ = end_uow(svc, &u, acted)
}

// on_start_success (the holder's own `ham-ctl agent start-success`): confirm a
// pending wake lease; an instance with no lease triggers match_chain so a fresh
// worker that came up idle gets work (pull).
on_start_success :: proc(svc: ^Service, inst: domain.Agent_Instance) {
	if svc == nil || svc.repo == nil do return
	u, ok, _ := begin_uow(svc)
	if !ok do return
	acted := true
	if lease, held, _ := iface.taskchain_get_lease_by_holder(svc.repo, inst.agent_instance_id); held {
		acted = confirm_in_uow(svc, &u, lease)
	} else if inst.chain_id != "" {
		if chain, cok, _ := iface.taskchain_get_chain(svc.repo, domain.Task_Chain_ID(inst.chain_id)); cok {
			acted, _ = match_chain_in_uow(svc, &u, chain, .Start_Success)
		}
	}
	_, _ = end_uow(svc, &u, acted)
}

// BOOT_LEASE_GRACE_SECONDS: after a hub restart every lease gets at least this
// long before its TTL fires, so an outage longer than the TTL does not expire
// (and count) attempts before the bridges are back to say their agents live.
BOOT_LEASE_GRACE_SECONDS :: 300

// grant_boot_lease_grace (boot, F2): extend leases that would expire within the
// grace window to now + grace (never past the hard cap). Audited as
// lease_extended{reason:hub_restart_grace}; extended_at is NOT set, so the
// lease keeps its one-shot clock-jump extension.
grant_boot_lease_grace :: proc(svc: ^Service) {
	leases, lerr := iface.taskchain_list_all_leases(svc.repo)
	if lerr.code != .None do return
	now := platform.clock_now(svc.clock)
	grace_until := add_seconds(now, BOOT_LEASE_GRACE_SECONDS)
	for l in leases {
		if to_ms(l.expires_at) >= to_ms(grace_until) do continue
		next := l
		next.expires_at = min_rfc3339(grace_until, l.hard_deadline_at)
		if next.expires_at == l.expires_at do continue
		if _, sok, _ := iface.taskchain_save_lease(svc.repo, next); !sok do continue
		if task, tok, _ := iface.taskchain_get_task(svc.repo, l.task_id); tok {
			p := json_begin()
			json_str(&p, "lease_id", l.lease_id)
			json_str(&p, "reason", "hub_restart_grace")
			_, _, _ = append_event(svc.repo, svc.clock, task, hub_actor(), EV_LEASE_EXTENDED, json_end(&p))
		}
	}
}

// on_bridge_hello (plan §2.4): re-send unconfirmed grants on that bridge; stop
// live non-coordinator instances that hold no lease (orphans whose lease expired
// while the bridge was away); re-plan every chain with a held task.
on_bridge_hello :: proc(svc: ^Service, bridge_id: string, active_instance_ids: []string) {
	if svc == nil || svc.repo == nil || bridge_id == "" do return
	u, ok, _ := begin_uow(svc)
	if !ok do return
	leases, lerr := iface.taskchain_list_all_leases(svc.repo)
	if lerr.code == .None {
		for l in leases {
			if l.bridge_id != bridge_id do continue
			if l.confirmed_at == "" {
				if l.delivery != domain.LEASE_DELIVERY_WAKE do continue
				if task, tok, _ := iface.taskchain_get_task(svc.repo, l.task_id); tok do effect_wake_lease(svc, &u, l, task)
				continue
			}
			// F2: a confirmed holder that is still alive may have given up on a
			// ham-ctl call while the hub/bridge link was down. Count the outage
			// as presence (hub-side heartbeat) and tell it to carry on.
			live := false
			for id in active_instance_ids do if id == l.holder_instance_id { live = true; break }
			if !live do continue
			if _, hok, _ := heartbeat_in_uow(svc, &u, l, hub_actor(), "bridge_hello"); !hok do continue
			if task, tok, _ := iface.taskchain_get_task(svc.repo, l.task_id); tok {
				effect_nudge_instance(&u, l.holder_instance_id, bridge_id, fmt.tprintf("[taskv2] Hub connection restored: continue lease %s on '%s'. Re-run the ham-ctl command that failed (ham-ctl lease next shows your lease).", l.lease_id, task.title))
			}
		}
	}
	// Orphans: ONLY instances the lease system itself would have launched —
	// on THIS bridge, members of an Active ticket/workflow chain, whose
	// template has a fleet row (worker/reviewer) in that chain — and that hold
	// no lease. Human-chat members, coordinators, private conversations and
	// other bridges' instances are never touched (review S8).
	for id in active_instance_ids {
		if strings.trim_space(id) == "" do continue
		if _, held, _ := iface.taskchain_get_lease_by_holder(svc.repo, id); held do continue
		inst, iok, _ := iface.agent_get_instance(svc.agents, id)
		if !iok || inst.chain_id == "" || inst.bridge_id != bridge_id do continue
		chain, cok, _ := iface.taskchain_get_chain(svc.repo, domain.Task_Chain_ID(inst.chain_id))
		if !cok || chain.status != .Active || chain.publish_state != .Published do continue
		if chain.kind != domain.CHAIN_KIND_MIXED_WORK do continue
		if is_coordinator(svc, chain, id) do continue
		if !instance_is_fleet_member(svc, chain, inst) do continue
		effect_stop(&u, inst.bridge_id, inst.chain_id, id)
	}
	ok_all := true
	chains, cerr := iface.taskchain_list_published_active_chains(svc.repo)
	requeue_pending_merges(svc, &u, bridge_id)
	if cerr.code == .None {
		for c in chains {
			if chain_has_held_task(svc, c) {
				if mok, _ := match_chain_in_uow(svc, &u, c, .Bridge_Hello); !mok do ok_all = false
			}
		}
	}
	_, _ = end_uow(svc, &u, ok_all)
}

// instance_is_fleet_member: the instance's template has a fleet row in the
// chain with any role — worker or a review role (the only kind of instance the
// matcher ever grants to or launches).
instance_is_fleet_member :: proc(svc: ^Service, chain: domain.Task_Chain, inst: domain.Agent_Instance) -> bool {
	fleets, err := iface.taskchain_list_fleets_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	if err.code != .None do return false
	for f in fleets {
		if f.agent_id != inst.agent_id do continue
		return true // upsert_fleet rejects an empty role list; a missing one defaults to worker
	}
	return false
}

@(private = "file")
chain_has_held_task :: proc(svc: ^Service, chain: domain.Task_Chain) -> bool {
	tasks, err := iface.taskchain_list_tasks_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	if err.code != .None do return false
	for t in tasks do if t.state == .Ready || t.state == .In_Review do return true
	return false
}

// chain_closed reclaims every lease of the chain (stop[] holders, coordinator
// exempt) and, when the chain was CANCELLED, cancels its open tasks. Completed/
// archived chains keep their task states; their timers become no-ops.
chain_closed :: proc(svc: ^Service, chain: domain.Task_Chain, actor: Actor, cancel_tasks: bool) -> domain.Domain_Error {
	u, ok, err := begin_uow(svc)
	if !ok do return err
	rok := true
	rerr := domain.Domain_Error{}
	leases, lerr := iface.taskchain_list_leases_by_chain(svc.repo, chain.chain_id)
	if lerr.code == .None {
		for l in leases {
			if expire_lease_in_uow(svc, &u, l, EXPIRE_CHAIN_CLOSED, actor) == .Failed {
				rok = false
				rerr = domain.domain_error(.Internal_Error, "failed to reclaim lease on chain close")
				break
			}
		}
	}
	if rok && cancel_tasks {
		tasks, terr := iface.taskchain_list_tasks_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
		if terr.code != .None {
			rok = false
			rerr = terr
		} else {
			for t in tasks {
				if domain.task_state_is_terminal(t.state) do continue
				payload := json_begin()
				json_str(&payload, "reason", EXPIRE_CHAIN_CLOSED)
				if _, _, eok, eerr := record_event(svc, &u, t, actor, EV_CANCELLED, json_end(&payload)); !eok {
					rok = false
					rerr = eerr
					break
				}
			}
		}
	}
	if rok && cancel_tasks {
		runs, err := iface.taskchain_list_workflow_runs(svc.repo,chain.chain_id,chain.owner_user_id)
		if err.code != .None { rok=false; rerr=err } else {
			for run in runs {
				wf,ok,err := workflow_context(svc,run.run_id,chain.owner_user_id)
				if !ok { rok=false;rerr=err;break }
				if wf.execution.state == "draft" || wf.execution.state == "pending" || wf.execution.state == "running" {
					if err := workflow_set_state(svc,&u,&wf,"cancelled","chain_cancelled"); err.code != .None {rok=false;rerr=err;break}
				}
			}
		}
	}
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return rerr
	return cerr
}

// cancel_task records `cancelled` for one task, reclaims its leases and re-plans
// the chain. Dependents are untouched.
cancel_task :: proc(svc: ^Service, task: domain.Task, actor: Actor, reason: string) -> domain.Domain_Error {
	u, ok, err := begin_uow(svc)
	if !ok do return err
	rok := true
	rerr := domain.Domain_Error{}
	leases, lerr := iface.taskchain_list_leases_by_task(svc.repo, task.task_id)
	if lerr.code == .None {
		for l in leases do if expire_lease_in_uow(svc, &u, l, EXPIRE_CANCELLED, actor) == .Failed { rok = false }
	}
	if rok {
		payload := json_begin()
		json_str(&payload, "reason", reason if reason != "" else "cancelled")
		_, _, rok, rerr = record_event(svc, &u, task, actor, EV_CANCELLED, json_end(&payload))
	}
	if rok do rok, rerr = after_chain_change(svc, &u, task.chain_id, task.owner_user_id, .Task_Cancelled)
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return rerr
	return cerr
}

// boot (hub start): rebuild the timer heap from the columns, heal in_progress rows
// that have no lease row (the migration's in_progress carry-over, or a crash
// between a lease delete and its event), then match_chain once per Active chain
// and re-send any unconfirmed wake whose bridge is online.
boot :: proc(svc: ^Service) {
	if svc == nil || svc.repo == nil do return
	init_task_metrics()
	grant_boot_lease_grace(svc)
	rebuild_timers(svc)
	u, ok, _ := begin_uow(svc)
	if !ok do return
	in_progress, perr := iface.taskchain_list_tasks_by_state(svc.repo, .In_Progress)
	if perr.code == .None {
		for t in in_progress {
			leases, lerr := iface.taskchain_list_leases_by_task(svc.repo, t.task_id)
			if lerr.code != .None do continue
			has_work := false
			for l in leases do if l.kind == domain.LEASE_KIND_WORK do has_work = true
			if has_work do continue
			p := json_begin()
			json_str(&p, "kind", domain.LEASE_KIND_WORK)
			json_int(&p, "attempt_no", i64(t.attempt_no))
			json_str(&p, "reason", EXPIRE_HUB_RESTART)
			_, _, _, _ = record_event(svc, &u, t, hub_actor(), EV_LEASE_EXPIRED, json_end(&p))
			metric_lease_expired(EXPIRE_HUB_RESTART)
		}
	}
	leases, lerr := iface.taskchain_list_all_leases(svc.repo)
	if lerr.code == .None {
		for l in leases {
			if l.confirmed_at != "" || l.delivery != domain.LEASE_DELIVERY_WAKE || !bridge_online(svc, l.bridge_id) do continue
			if task, tok, _ := iface.taskchain_get_task(svc.repo, l.task_id); tok do effect_wake_lease(svc, &u, l, task)
		}
	}
    chains, cerr := iface.taskchain_list_published_active_chains(svc.repo)
    all_ok := cerr.code == .None
    if all_ok {
        for chain in chains {
            if ok, err := after_chain_change(svc, &u, chain.chain_id, chain.owner_user_id, .Boot); !ok {
                fmt.eprintfln("[taskv2] mixed-work recovery failed for %s: %s", chain.chain_id, err.message)
                all_ok = false
                break
            }
        }
    }
	_, _ = end_uow(svc, &u, all_ok)
}

// ---- helpers ---------------------------------------------------------------------------

@(private = "file")
close_attempt :: proc(svc: ^Service, lease: domain.Task_Lease, outcome: string) {
	if lease.kind != domain.LEASE_KIND_WORK do return
	now := platform.clock_now(svc.clock)
	attempts, err := iface.taskchain_list_attempts_by_task(svc.repo, lease.task_id, lease.owner_user_id)
	if err.code != .None do return
	started_at := lease.granted_at
	for a in attempts {
		if a.attempt_no != lease.attempt_no do continue
		closed := a
		if closed.started_at != "" do started_at = closed.started_at
		closed.ended_at = now
		closed.outcome = outcome
		_, _, _ = iface.taskchain_save_attempt(svc.repo, closed)
	}
	if task, tok, _ := iface.taskchain_get_task(svc.repo, lease.task_id); tok {
		provider, model := lease.provider, lease.model
		if inst, iok, _ := iface.agent_get_instance(svc.agents, lease.holder_instance_id); iok {
			if provider == "" do provider = inst.provider
			if model == "" do model = inst.model
		}
		rt := json_begin()
		json_str(&rt, "bridge_id", lease.bridge_id)
		json_str(&rt, "provider", provider)
		json_str(&rt, "model", model)
		json_str(&rt, "started_at", started_at)
		json_str(&rt, "ended_at", now)
		_, _ = save_facet_verbatim(svc, task, lease.attempt_no, FACET_RUNTIME, json_end(&rt), FACET_WRITER_HUB)
	}
}

set_instance_pointer :: proc(svc: ^Service, instance_id, task_id: string, role: domain.Current_Task_Role) {
	inst, ok, _ := iface.agent_get_instance(svc.agents, instance_id)
	if !ok do return
	if inst.current_task_id == task_id && inst.current_task_role == role && inst.idle_since == "" do return
	inst.current_task_id = task_id
	inst.current_task_role = role
	inst.idle_since = "" // holding a lease is not idle
	inst.updated_at = platform.clock_now(svc.clock)
	_, _, _ = iface.agent_save_instance(svc.agents, inst)
}

// mark_instance_idle clears the pointer and stamps idle_since = now (the
// column the Idle_TTL timer keys on; review S4).
mark_instance_idle :: proc(svc: ^Service, instance_id, now: string) {
	inst, ok, _ := iface.agent_get_instance(svc.agents, instance_id)
	if !ok do return
	inst.current_task_id = ""
	inst.current_task_role = .None
	inst.idle_since = now
	inst.updated_at = now
	_, _, _ = iface.agent_save_instance(svc.agents, inst)
}

clear_instance_pointer :: proc(svc: ^Service, instance_id: string) {
	mark_instance_idle(svc, instance_id, platform.clock_now(svc.clock))
}

// ---- recently expired holders (lease.next refusal, review S10) ------------------
// An instance whose lease just expired is being stopped and re-woken; a
// `lease.next` from its old process must not hand it a fresh inline lease.
// In-memory (heap-cloned keys under state_mutex); not durable across restarts
// on purpose — after a restart every process is re-bootstrapped anyway.

note_recent_expiry :: proc(svc: ^Service, instance_id: string, at_ms: i64) {
	if instance_id == "" do return
	sync.mutex_lock(&svc.state_mutex)
	defer sync.mutex_unlock(&svc.state_mutex)
	if svc.recent_expiries == nil do svc.recent_expiries = make(map[string]i64, runtime.heap_allocator())
	if _, has := svc.recent_expiries[instance_id]; has {
		svc.recent_expiries[instance_id] = at_ms
		return
	}
	svc.recent_expiries[strings.clone(instance_id, runtime.heap_allocator())] = at_ms
}

recently_expired :: proc(svc: ^Service, instance_id: string, now_ms: i64) -> bool {
	sync.mutex_lock(&svc.state_mutex)
	defer sync.mutex_unlock(&svc.state_mutex)
	at, has := svc.recent_expiries[instance_id]
	return has && now_ms - at < IDLE_GRACE_SECONDS * 1000
}

instance_is_live :: proc(inst: domain.Agent_Instance) -> bool {
	return inst.runtime_status == "running" || inst.runtime_status == "idle" || inst.runtime_status == "busy"
}

instance_is_pending :: proc(inst: domain.Agent_Instance) -> bool {
	return inst.runtime_status == "launching" || inst.runtime_status == "starting" || inst.runtime_status == "blocked"
}

// holder_is_coordinator resolves the lease's OWN chain (never a caller's) and
// asks whether the holder is its coordinator.
holder_is_coordinator :: proc(svc: ^Service, chain_id: domain.Task_Chain_ID, instance_id: string) -> bool {
	chain, ok, _ := iface.taskchain_get_chain(svc.repo, chain_id)
	return ok && is_coordinator(svc, chain, instance_id)
}

// chain_is_solo: the chain's coordinator also works its tasks (REQ-SOLO-1) —
// the coordinator is the built-in Soloist agent, or its own agent has a fleet
// row with the worker role (opt-in for any coordinator). The coordinator is
// then granted work by pull only (inline), never woken, restarted or stopped.
chain_is_solo :: proc(svc: ^Service, chain: domain.Task_Chain) -> bool {
	coord_agent := chain_coordinator_agent_id(svc, chain)
	if coord_agent == "" do return false
	if ag, aok, _ := iface.agent_get(svc.agents, coord_agent); aok && (ag.slug == SOLOIST_AGENT_SLUG || ag.template_id == domain.TEMPLATE_SOLOIST_ID) do return true
	fleets, err := iface.taskchain_list_fleets_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	if err.code != .None do return false
	for f in fleets do if f.agent_id == coord_agent && fleet_row_has_role(f, domain.FLEET_ROLE_WORKER) do return true
	return false
}

// implicit_solo_worker: the worker row the built-in Soloist coordinator works
// under when the fleet has no row for its agent (puller_fleet_row grants on the
// same shape). Read paths list it so the board can name the soloist.
implicit_solo_worker :: proc(svc: ^Service, chain: domain.Task_Chain, fleets: []domain.Task_Chain_Fleet) -> (domain.Task_Chain_Fleet, bool) {
	if svc == nil do return {}, false
	coord_agent := chain_coordinator_agent_id(svc, chain)
	if coord_agent == "" do return {}, false
	for f in fleets do if f.agent_id == coord_agent do return {}, false
	ag, aok, _ := iface.agent_get(svc.agents, coord_agent)
	if !aok || (ag.slug != SOLOIST_AGENT_SLUG && ag.template_id != domain.TEMPLATE_SOLOIST_ID) do return {}, false
	return domain.Task_Chain_Fleet{task_chain_id = chain.chain_id, agent_id = coord_agent, roles_json = `["worker"]`, capacity = 1}, true
}

// solo_default_user_approval (REQ-SOLO-1a): an explicit value wins (true or
// false); when the brief/spec says nothing, a solo chain's tasks wait for the
// user's review and other chains' do not.
solo_default_user_approval :: proc(svc: ^Service, chain: domain.Task_Chain, present, value: bool) -> bool {
	if present do return value
	return chain_is_solo(svc, chain)
}

// brief_user_approval: solo_default_user_approval over a brief, telling an
// absent key from an explicit false.
brief_user_approval :: proc(svc: ^Service, chain: domain.Task_Chain, brief_json: string) -> bool {
	v, present := jsonx.extract_bool_literal(brief_json, "requires_user_approval", true)
	return solo_default_user_approval(svc, chain, present, v)
}

// SOLOIST_AGENT_SLUG mirrors user.SOLOIST_AGENT_SLUG (the built-in Soloist).
SOLOIST_AGENT_SLUG :: "soloist"

// chain_coordinator_agent_id: the durable agent behind the chain's coordinator
// instance ("" when the chain has none).
chain_coordinator_agent_id :: proc(svc: ^Service, chain: domain.Task_Chain) -> string {
	coord := chain.coordinator_agent_instance_id
	if coord == "" {
		members, err := iface.taskchain_list_members_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
		if err.code == .None {
			for m in members do if m.role == "coordinator" { coord = m.agent_instance_id; break }
		}
	}
	if coord == "" do return ""
	inst, ok, _ := iface.agent_get_instance(svc.agents, coord)
	return inst.agent_id if ok else ""
}

// is_coordinator: the chain's coordinator is the member with role "coordinator"
// (canonical, H9) or the mirror column; it is never granted and never stopped.
is_coordinator :: proc(svc: ^Service, chain: domain.Task_Chain, instance_id: string) -> bool {
	if instance_id == "" do return false
	if chain.coordinator_agent_instance_id == instance_id do return true
	members, err := iface.taskchain_list_members_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	if err.code != .None do return false
	for m in members do if m.agent_instance_id == instance_id && m.role == "coordinator" do return true
	return false
}

instance_in_chain :: proc(svc: ^Service, chain: domain.Task_Chain, inst: domain.Agent_Instance) -> bool {
	if inst.owner_user_id != chain.owner_user_id do return false
	if inst.chain_id == string(chain.chain_id) do return true
	members, err := iface.taskchain_list_members_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	if err.code != .None do return false
	for m in members do if m.agent_instance_id == inst.agent_instance_id do return true
	return false
}

bridge_online :: proc(svc: ^Service, bridge_id: string) -> bool {
	if bridge_id == "" do return false
	bridge, ok, _ := iface.bridge_get_bridge(svc.bridges, bridge_id)
	if !ok do return false
	return bridge.status == .Online
}

// PER_LEASE_WORKTREES_ENABLED: several work leases may run in one git
// directory, each in its own checkout. A task works in
// `<dir>/.heimdall/worktrees/<task_id>` on branch `heimdall/<task_id>` (the
// pack's placement.workdir/branch; the bridge creates it on lease.next), and
// the branch is merged back into the directory's branch when the task is done
// (merge.odin). A merge conflict blocks the task on a human.
PER_LEASE_WORKTREES_ENABLED :: true

TASK_WORKTREE_DIR :: ".heimdall/worktrees"
TASK_BRANCH_PREFIX :: "heimdall/"

// task_worktree returns the per-task checkout and branch for a task placed in
// directory `dir`, or ("", "") when the directory gets no worktree (not git,
// no path, or the feature is off). Temp-allocated.
task_worktree :: proc(dir: domain.Task_Chain_Directory, task_id: domain.Task_ID) -> (workdir, branch: string) {
	if !PER_LEASE_WORKTREES_ENABLED || dir.vcs_kind != "git" do return "", ""
	root := strings.trim_right(strings.trim_space(dir.path), "/")
	if root == "" || task_id == "" do return "", ""
	return fmt.tprintf("%s/%s/%s", root, TASK_WORKTREE_DIR, task_id), fmt.tprintf("%s%s", TASK_BRANCH_PREFIX, task_id)
}

// directory_has_work_lease: one live work lease per chain directory (VCS
// directories exempt only when PER_LEASE_WORKTREES_ENABLED).
directory_has_work_lease :: proc(svc: ^Service, chain: domain.Task_Chain, directory_id: string) -> bool {
	dirs, derr := iface.taskchain_list_directories_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	if derr.code != .None do return false
	if PER_LEASE_WORKTREES_ENABLED {
		for d in dirs {
			if d.directory_id == directory_id {
				if d.vcs_kind == "git" do return false
			}
		}
	}
	bridge_of_dir := ""
	for d in dirs do if d.directory_id == directory_id { bridge_of_dir = d.bridge_id; break }
	if bridge_of_dir == "" do return false
	leases, lerr := iface.taskchain_list_leases_by_chain(svc.repo, chain.chain_id)
	if lerr.code != .None do return false
	for l in leases {
		if l.kind != domain.LEASE_KIND_WORK do continue
		if resolve_directory_for_bridge(dirs, l.bridge_id) == directory_id do return true
	}
	return false
}

// resolve_directory_for_bridge returns the chain directory on `bridge_id` (first
// by created_at), or "" when the chain has none there.
resolve_directory_for_bridge :: proc(dirs: []domain.Task_Chain_Directory, bridge_id: string) -> string {
	for d in dirs do if d.bridge_id == bridge_id do return d.directory_id
	return ""
}

fleet_idle_ttl :: proc(svc: ^Service, chain_id: domain.Task_Chain_ID, owner: domain.User_ID, agent_id: string) -> int {
	fleets, err := iface.taskchain_list_fleets_by_chain(svc.repo, chain_id, owner)
	if err.code != .None do return IDLE_TTL_DEFAULT_SECONDS
	for f in fleets do if f.agent_id == agent_id && f.idle_ttl_seconds > 0 do return f.idle_ttl_seconds
	return IDLE_TTL_DEFAULT_SECONDS
}

lease_lost_error :: proc() -> domain.Domain_Error {
	return domain.domain_error(.Conflict, "lease_lost: this instance holds no live lease for that task; stop — you will be re-woken with a fresh pack", `{"code":"lease_lost"}`)
}

_ :: fmt
