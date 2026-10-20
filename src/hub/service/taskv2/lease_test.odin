package taskv2

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import agent "odin_test:hub/service/agent"
import project "odin_test:hub/service/project"
import jsonx "odin_test:lib/jsonx"
import lockorder "odin_test:lib/lockorder"

// M1 tests: leases, timers, matcher, wake delivery. Everything runs against a
// real sqlite file with the fake clock; timers are driven with fire_due(now).

// ---- fixture extensions ---------------------------------------------------------

Wake_Log :: struct {
	cmds: [dynamic]Wake_Command,
	// The log outlives the engine's scratch scopes (on_bridge_hello runs on a
	// per-call arena), so it owns its copies on the allocator it was created with.
	allocator: runtime.Allocator,
}

wake_log_observe :: proc(ctx: rawptr, cmd: Wake_Command) {
	log := (^Wake_Log)(ctx)
	context.allocator = log.allocator
	append(&log.cmds, Wake_Command{bridge_id = strings.clone(cmd.bridge_id), chain_id = strings.clone(cmd.chain_id), body_json = strings.clone(cmd.body_json)})
}

wake_log_destroy :: proc(log: ^Wake_Log) {
	context.allocator = log.allocator
	for c in log.cmds { delete(c.bridge_id); delete(c.chain_id); delete(c.body_json) }
	delete(log.cmds)
}

wake_log_reset :: proc(log: ^Wake_Log) {
	context.allocator = log.allocator
	for c in log.cmds { delete(c.bridge_id); delete(c.chain_id); delete(c.body_json) }
	clear(&log.cmds)
}

// wake_log_runs_for returns true when any captured wake_agent run[] names inst.
wake_log_has_run :: proc(log: ^Wake_Log, inst: string) -> bool {
	for c in log.cmds {
		if run, ok := jsonx.extract_raw_array(c.body_json, "run", false, context.temp_allocator); ok && strings.contains(run, fmt.tprintf(`"agent_instance_id":"%s"`, inst)) do return true
	}
	return false
}

wake_log_has_stop :: proc(log: ^Wake_Log, inst: string) -> bool {
	for c in log.cmds {
		if stop, ok := jsonx.extract_raw_array(c.body_json, "stop", false, context.temp_allocator); ok && strings.contains(stop, fmt.tprintf(`"%s"`, inst)) do return true
	}
	return false
}

lease_fixture :: proc(t: ^testing.T, tag: string) -> (^Fixture, ^Wake_Log, bool) {
	fx, ok := fixture_open(t, tag)
	log := new(Wake_Log)
	log.allocator = context.allocator
	log.cmds = make([dynamic]Wake_Command)
	fx.svc.wake_observer = wake_log_observe
	fx.svc.wake_observer_ctx = rawptr(log)
	init_task_metrics()
	return fx, log, ok
}

lease_fixture_close :: proc(fx: ^Fixture, log: ^Wake_Log) {
	wake_log_destroy(log)
	free(log)
	fixture_close(fx)
}

seed_bridge :: proc(fx: ^Fixture, id: string, online := true) {
	now := platform.clock_now(&fx.clock)
	_, _, _ = iface.bridge_save_bridge(&fx.bridges, domain.Bridge{bridge_id = id, owner_user_id = "u1", machine_hostname = id, status = .Online if online else .Offline, capabilities_json = `{"capabilities":[{"provider":"claude","models":["claude-fable-5-1","claude-opus-5-5","claude-sonnet-5-5"],"default_model":"claude-opus-5-5"}],"provider":"claude","default_model":"claude-opus-5-5"}`, created_at = now, updated_at = now})
}

set_bridge_status :: proc(fx: ^Fixture, id: string, online: bool) {
	b, ok, _ := iface.bridge_get_bridge(&fx.bridges, id)
	if !ok do return
	b.status = .Online if online else .Offline
	_, _, _ = iface.bridge_save_bridge(&fx.bridges, b)
}

seed_agent :: proc(fx: ^Fixture, id: string) {
	now := platform.clock_now(&fx.clock)
	_, _, _ = iface.agent_save(&fx.agents, domain.Agent{agent_id = id, owner_user_id = "u1", name = id, slug = id, template_id = domain.TEMPLATE_EMPTY_ID, state = .Active, created_at = now, updated_at = now})
}

seed_instance :: proc(fx: ^Fixture, chain: domain.Task_Chain, id, agent_id, bridge_id, runtime_status: string, role := "worker") -> domain.Agent_Instance {
	now := platform.clock_now(&fx.clock)
	inst := domain.Agent_Instance{agent_instance_id = id, owner_user_id = "u1", agent_id = agent_id, bridge_id = bridge_id, display_name = id, provider = "claude", model = "claude-opus-5-5", chain_id = string(chain.chain_id), runtime_status = runtime_status, activity_status = "idle", created_at = now, updated_at = now, last_seen_at = now}
	saved, _, _ := iface.agent_save_instance(&fx.agents, inst)
	_, _, _ = iface.taskchain_save_member(&fx.repo, domain.Task_Chain_Member{chain_id = chain.chain_id, agent_instance_id = id, agent_id = agent_id, owner_user_id = "u1", role = role, created_at = now})
	return saved
}

seed_fleet :: proc(fx: ^Fixture, chain: domain.Task_Chain, agent_id: string, roles := `["worker"]`, capacity := 1, bridge_id := "", idle_ttl := 0) {
	now := platform.clock_now(&fx.clock)
	_, _ = iface.taskchain_upsert_fleet(&fx.repo, domain.Task_Chain_Fleet{task_chain_id = chain.chain_id, agent_id = agent_id, capacity = capacity, idle_ttl_seconds = idle_ttl, roles_json = roles, bridge_id = bridge_id, created_at = now, updated_at = now})
}

seed_directory :: proc(fx: ^Fixture, chain: domain.Task_Chain, id, bridge_id: string, vcs_kind: string = "") {
	now := platform.clock_now(&fx.clock)
	_, _, _ = iface.taskchain_save_directory(&fx.repo, domain.Task_Chain_Directory{directory_id = id, chain_id = chain.chain_id, owner_user_id = "u1", path = fmt.tprintf("/srv/%s", id), bridge_id = bridge_id, vcs_kind = vcs_kind, created_at = now, updated_at = now})
}

// seed_live_chain: Online bridge br_1, coordinator inst_coord (agt_c), the
// chain published+active.
seed_live_chain :: proc(t: ^testing.T, fx: ^Fixture, chain_id: string) -> domain.Task_Chain {
	seed_bridge(fx, "br_1")
	seed_agent(fx, "agt_c")
	seed_agent(fx, "agt_w")
	seed_agent(fx, "agt_r")
	chain := seed_chain(t, fx, chain_id, true)
	chain.coordinator_agent_instance_id = "inst_coord"
	_, _, _ = iface.taskchain_save_chain(&fx.repo, chain)
	seed_instance(fx, chain, "inst_coord", "agt_c", "br_1", "running", "coordinator")
	return chain
}

// publish_task creates + publishes a task through the engine entry points
// (created → published → match) and returns the fresh row.
publish_task :: proc(t: ^testing.T, fx: ^Fixture, chain: domain.Task_Chain, id: string, brief := `{"goal":"g","review_roles":[]}`, priority := domain.Task_Priority.P2, kind := domain.Task_Kind.Task, bridge_pin := "") -> domain.Task {
	task := seed_task(t, fx, chain, id, brief)
	task.priority = priority
	task.kind = kind
	task.bridge_id = bridge_pin
	task.publish_state = .Published
	_, _, _ = iface.taskchain_save_task(&fx.repo, task)
	err := task_created(&fx.svc, task, Actor{kind = ACTOR_USER, id = "u1"})
	testing.expect(t, err.code == .None, fmt.tprintf("task_created %s: %s", id, err.message))
	fresh, _, _ := iface.taskchain_get_task(&fx.repo, task.task_id)
	return fresh
}

get_task :: proc(fx: ^Fixture, id: string) -> domain.Task {
	task, _, _ := iface.taskchain_get_task(&fx.repo, domain.Task_ID(id))
	return task
}

lease_of :: proc(fx: ^Fixture, inst: string) -> (domain.Task_Lease, bool) {
	l, ok, _ := iface.taskchain_get_lease_by_holder(&fx.repo, inst)
	return l, ok
}

// submit_via_release drives the shared release path the M2 `submit` verb sits
// on (release lease → event → refold → stop holder → match).
submit_via_release :: proc(t: ^testing.T, fx: ^Fixture, lease: domain.Task_Lease) {
	u, ok, _ := begin_uow(&fx.svc)
	if !testing.expect(t, ok, "begin uow") do return
	task, rok, rerr := release_in_uow(&fx.svc, &u, lease, Actor{kind = ACTOR_AGENT, id = lease.holder_instance_id}, EV_SUBMITTED, fmt.tprintf(`{{"lease_id":"%s","attempt_no":%d}}`, lease.lease_id, lease.attempt_no), "submitted")
	testing.expect(t, rok, fmt.tprintf("release: %s", rerr.message))
	if rok do _, _ = after_chain_change(&fx.svc, &u, task.chain_id, task.owner_user_id, .Lease_Released)
	_, _ = end_uow(&fx.svc, &u, rok)
}

count_events :: proc(fx: ^Fixture, task_id, kind: string) -> int {
	evs, _ := iface.taskchain_list_events_by_task(&fx.repo, domain.Task_ID(task_id), "u1")
	n := 0
	for e in evs do if e.kind == kind do n += 1
	return n
}

last_event_payload :: proc(fx: ^Fixture, task_id, kind: string) -> string {
	evs, _ := iface.taskchain_list_events_by_task(&fx.repo, domain.Task_ID(task_id), "u1")
	for i := len(evs) - 1; i >= 0; i -= 1 do if evs[i].kind == kind do return evs[i].payload_json
	return ""
}

// ---- matcher: grants + wake ---------------------------------------------------------

// Ports test_dynamic_fleet_scheduling_and_queuing_lifecycle: an idle warm
// worker gets the lease (wake run[] with lease_id + pack), capacity 1 queues the
// rest, and when the slot frees the P0 task goes first.
@(test)
test_matcher_grants_idle_worker_and_queues_by_priority :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "m_sched")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_s")
	seed_fleet(fx, chain, "agt_w", capacity = 1)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")

	t1 := publish_task(t, fx, chain, "task_1", priority = .P1)
	testing.expect_value(t, t1.state, domain.Task_State.In_Progress)
	testing.expect_value(t, t1.attempt_no, 1)
	lease, held := lease_of(fx, "inst_w1")
	testing.expect(t, held, "inst_w1 holds the lease")
	testing.expect_value(t, lease.task_id, t1.task_id)
	testing.expect_value(t, lease.kind, domain.LEASE_KIND_WORK)
	testing.expect_value(t, lease.bridge_id, "br_1")
	testing.expect_value(t, lease.delivery, domain.LEASE_DELIVERY_WAKE)
	testing.expect(t, lease.confirmed_at == "", "wake lease starts unconfirmed")
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	testing.expect_value(t, inst.current_task_id, "task_1")
	testing.expect_value(t, inst.current_task_role, domain.Current_Task_Role.Work)
	// wake_agent carries the lease + pack, one command for br_1 × chain
	testing.expect(t, wake_log_has_run(log, "inst_w1"), "wake run[] names inst_w1")
	if len(log.cmds) > 0 {
		body := log.cmds[len(log.cmds)-1].body_json
		testing.expect(t, strings.contains(body, fmt.tprintf(`"lease_id":"%s"`, lease.lease_id)), "run entry carries lease_id")
		testing.expect(t, strings.contains(body, `"pack":{"version":1`), "run entry carries the context pack")
		testing.expect(t, strings.contains(body, `"role":"worker"`), "role worker")
		testing.expect(t, strings.contains(body, `"agent_id":"agt_w"`), "enriched descriptor agent_id")
		testing.expect(t, !strings.contains(body, `"agent_instance_id":"inst_coord"`) && !wake_log_has_stop(log, "inst_coord"), "coordinator never in run[]/stop[]")
	}
	// capacity 1 → the next two tasks wait
	t2 := publish_task(t, fx, chain, "task_2", priority = .P2)
	t3 := publish_task(t, fx, chain, "task_3", priority = .P0)
	testing.expect_value(t, t2.state, domain.Task_State.Ready)
	testing.expect_value(t, t3.state, domain.Task_State.Ready)
	testing.expect(t, strings.contains(get_task(fx, "task_1").brief_json, "goal"), "brief kept")
	// submit task_1 → holder stopped, P0 task_3 granted to the same (now free) instance
	wake_log_reset(log)
	submit_via_release(t, fx, lease)
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.Done) // no reviewers, no user approval
	testing.expect_value(t, get_task(fx, "task_3").state, domain.Task_State.In_Progress)
	testing.expect_value(t, get_task(fx, "task_2").state, domain.Task_State.Ready)
	l3, held3 := lease_of(fx, "inst_w1")
	testing.expect(t, held3 && l3.task_id == "task_3", "inst_w1 re-leased on the P0 task")
	testing.expect(t, wake_log_has_run(log, "inst_w1"), "re-wake (fresh context) for the new lease")
	testing.expect(t, !wake_log_has_stop(log, "inst_w1"), "an instance in run[] is never also in stop[]")
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "sched")
}

@(test)
test_gate_never_granted :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "m_gate")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_g")
	seed_fleet(fx, chain, "agt_w")
	inst := seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	gate := publish_task(t, fx, chain, "gate_1", kind = .Gate)
	// The fold never makes a gate `ready` (gates are decided, not worked — M2).
	testing.expect_value(t, gate.state, domain.Task_State.Backlog)
	_, held := lease_of(fx, "inst_w1")
	testing.expect(t, !held, "matcher skips gates")
	// a direct grant is refused even for a (hypothetically) ready gate
	forced := gate
	forced.state = .Ready
	u, _, _ := begin_uow(&fx.svc)
	_, gok, gerr := grant_in_uow(&fx.svc, &u, Grant_Request{chain = chain, task = forced, instance = inst, kind = domain.LEASE_KIND_WORK, placement = Placement{bridge_id = "br_1"}, actor = hub_actor()})
	_, _ = end_uow(&fx.svc, &u, false)
	testing.expect(t, !gok && gerr.code == .Conflict, "grant_in_uow refuses gates")
	// lease.next from the worker: none
	res, nok, _ := lease_next(&fx.svc, contracts.Auth_Context{kind = .Instance_Token, user_id = "u1", agent_instance_id = "inst_w1"}, Lease_Next_Input{})
	testing.expect(t, nok && res.status == "none", "lease.next finds nothing on a gate-only chain")
}

@(test)
test_one_work_lease_per_directory :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "m_dir")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_d")
	seed_directory(fx, chain, "dir_1", "br_1")
	seed_fleet(fx, chain, "agt_w", capacity = 3)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_w2", "agt_w", "br_1", "idle")
	t1 := publish_task(t, fx, chain, "task_1")
	t2 := publish_task(t, fx, chain, "task_2")
	testing.expect_value(t, t1.state, domain.Task_State.In_Progress)
	testing.expect_value(t, t2.state, domain.Task_State.Ready) // second worker is free but the directory is busy
	leases, _ := iface.taskchain_list_leases_by_chain(&fx.repo, chain.chain_id)
	testing.expect_value(t, len(leases), 1)
	// a second bridge with its own directory gets its own lease
	seed_bridge(fx, "br_2")
	seed_directory(fx, chain, "dir_2", "br_2")
	seed_instance(fx, chain, "inst_w3", "agt_w", "br_2", "idle")
	seed_fleet(fx, chain, "agt_w", capacity = 3) // fleet_changed trigger
	testing.expect(t, fleet_changed(&fx.svc, chain).code == .None, "fleet_changed")
	// task_2 has no pin: placement resolves to fleet bridge "" → first directory (br_1) → still busy.
	testing.expect_value(t, get_task(fx, "task_2").state, domain.Task_State.Ready)
	t3 := publish_task(t, fx, chain, "task_3", bridge_pin = "br_2")
	testing.expect_value(t, t3.state, domain.Task_State.In_Progress)
	l3, held := lease_of(fx, "inst_w3")
	testing.expect(t, held && l3.bridge_id == "br_2", "pinned task placed on br_2's directory")
}

@(test)
test_per_lease_worktrees_lifts_directory_cap :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "m_wt")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_wt")
	// Seed a directory with vcs_kind = "git" (supports per-lease worktrees, M5)
	seed_directory(fx, chain, "dir_git", "br_1", "git")
	seed_fleet(fx, chain, "agt_w", capacity = 4)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_w2", "agt_w", "br_1", "idle")
	t1 := publish_task(t, fx, chain, "task_1")
	t2 := publish_task(t, fx, chain, "task_2")
	// Under per-lease worktrees, BOTH tasks are granted concurrent work leases!
	testing.expect_value(t, t1.state, domain.Task_State.In_Progress)
	testing.expect_value(t, t2.state, domain.Task_State.In_Progress)
	leases, _ := iface.taskchain_list_leases_by_chain(&fx.repo, chain.chain_id)
	testing.expect_value(t, len(leases), 2)
}

// Ports bridge pinning + live-count scope: a task pinned to br_2 is never
// granted to a br_1 instance; an offline placement bridge holds the task until
// hello.
@(test)
test_bridge_pin_and_offline_hold_until_hello :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "m_pin")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_pin")
	seed_bridge(fx, "br_2", online = false)
	seed_fleet(fx, chain, "agt_w", capacity = 2)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_w2", "agt_w", "br_2", "idle")
	task := publish_task(t, fx, chain, "task_pinned", bridge_pin = "br_2")
	testing.expect_value(t, task.state, domain.Task_State.Ready)
	_, h1 := lease_of(fx, "inst_w1")
	testing.expect(t, !h1, "br_1 instance never gets a br_2-pinned task")
	// bridge comes online → hello → match
	set_bridge_status(fx, "br_2", true)
	on_bridge_hello(&fx.svc, "br_2", []string{"inst_w2"})
	testing.expect_value(t, get_task(fx, "task_pinned").state, domain.Task_State.In_Progress)
	l2, h2 := lease_of(fx, "inst_w2")
	testing.expect(t, h2 && l2.bridge_id == "br_2", "granted on hello to the br_2 instance")
}

// ---- timers ---------------------------------------------------------------------------

@(test)
test_expiry_noop_when_heartbeat_moved_deadline :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "t_ttl")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_ttl")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1")
	confirm_holder(fx, "inst_w1")
	lease, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held, "leased") do return
	first_expiry := to_ms(lease.expires_at)
	// 10 min later the agent heartbeats (any instance-token call) → deadline moves
	fixture_advance(fx, 600)
	touch_instance(&fx.svc, "inst_w1")
	moved, _ := lease_of(fx, "inst_w1")
	testing.expect(t, to_ms(moved.expires_at) > first_expiry, "heartbeat extended the TTL")
	// the ORIGINAL timer fires at the original deadline: no-op
	fixture_advance(fx, 300)
	fired := fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect(t, fired >= 1, "original ttl timer popped")
	still, still_held := lease_of(fx, "inst_w1")
	testing.expect(t, still_held && still.lease_id == lease.lease_id, "lease survives the stale timer")
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.In_Progress)
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_EXPIRED), 0)
	// … and the re-armed timer expires it when it is really due
	fixture_advance(fx, 700)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	// (the idle worker is immediately re-granted a NEW lease: attempt 2)
	after, after_held := lease_of(fx, "inst_w1")
	testing.expect(t, !after_held || after.lease_id != lease.lease_id, "expired at the moved deadline")
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_EXPIRED), 1)
	testing.expect(t, strings.contains(last_event_payload(fx, "task_1", EV_LEASE_EXPIRED), `"reason":"ttl"`), "reason ttl")
	testing.expect(t, wake_log_has_stop(log, "inst_w1") || wake_log_has_run(log, "inst_w1"), "holder stopped (or re-granted) after expiry")
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "ttl")
}

@(test)
test_hard_cap_ignores_heartbeat :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "t_cap")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_cap")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1")
	confirm_holder(fx, "inst_w1")
	lease, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held, "leased") do return
	hard := to_ms(lease.hard_deadline_at)
	testing.expect_value(t, hard - to_ms(lease.granted_at), i64(LEASE_HARD_CAP_SECONDS) * 1000)
	// heartbeat every 5 minutes for 65 minutes; TTL never passes the cap
	for i in 0..<13 {
		fixture_advance(fx, 300)
		_, hok, _ := lease_heartbeat(&fx.svc, contracts.Auth_Context{kind = .Instance_Token, user_id = "u1", agent_instance_id = "inst_w1"}, Lease_Heartbeat_Input{})
		if now_ms(&fx.clock) < hard {
			testing.expect(t, hok, fmt.tprintf("heartbeat %d ok", i))
			l, _ := lease_of(fx, "inst_w1")
			testing.expect(t, to_ms(l.expires_at) <= hard, "TTL clamped to the hard cap")
		}
		_ = fire_due(&fx.svc, now_ms(&fx.clock))
	}
	after, after_held := lease_of(fx, "inst_w1")
	testing.expect(t, !after_held || after.lease_id != lease.lease_id, "hard cap expired the lease despite heartbeats")
	testing.expect(t, strings.contains(last_event_payload(fx, "task_1", EV_LEASE_EXPIRED), `"reason":"hard_cap"`), "reason hard_cap")
	// expiry counts: attempt 2 on re-grant
	testing.expect_value(t, get_task(fx, "task_1").attempt_no, 2) // re-granted to the (re-woken) same instance
}

@(test)
test_grant_unconfirmed_resends_once_then_blocks_dispatch :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "t_unconf")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_unconf")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1")
	lease, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held, "leased") do return
	testing.expect_value(t, len(log.cmds), 1)
	wake_log_reset(log)
	// 180 s: no start-success → re-send once
	fixture_advance(fx, GRANT_UNCONFIRMED_SECONDS + 1)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect(t, wake_log_has_run(log, "inst_w1"), "wake re-sent once")
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_RESENT), 1)
	l, still := lease_of(fx, "inst_w1")
	testing.expect(t, still && l.lease_id == lease.lease_id, "lease kept after resend")
	// another 180 s: still unconfirmed → dispatch block, without spending work budget
	fixture_advance(fx, GRANT_UNCONFIRMED_SECONDS + 1)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	blocked := get_task(fx, "task_1")
	testing.expect_value(t, blocked.state, domain.Task_State.Backlog)
	testing.expect(t, strings.contains(blocked.blocked_on_json, `"kind":"dispatch"`) && strings.contains(blocked.blocked_on_json, "startup was not confirmed"), "unconfirmed delivery blocks with a reason")
	_, held_after_timeout := lease_of(fx, "inst_w1")
	testing.expect(t, !held_after_timeout, "no automatic retry after failed startup")
	attempts, _ := iface.taskchain_list_attempts_by_task(&fx.repo, blocked.task_id, "u1")
	testing.expect(t, len(attempts) == 1 && !attempts[0].counts_toward_budget, "unconfirmed startup is non-counting")
	// Explicit retry grants again; start-success confirms it and stops the clock.
	_, answered, _ := task_answer(&fx.svc, blocked, Actor{kind = ACTOR_USER, id = "u1"}, "fixed startup")
	testing.expect(t, answered, "explicit retry unblocks")
	l2, held2 := lease_of(fx, "inst_w1")
	if testing.expect(t, held2 && l2.lease_id != lease.lease_id, "re-granted a new lease") {
		inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
		on_start_success(&fx.svc, inst)
		l3, _ := lease_of(fx, "inst_w1")
		testing.expect(t, l3.confirmed_at != "", "confirmed by start-success")
		fixture_advance(fx, GRANT_UNCONFIRMED_SECONDS * 2 + 2)
		_ = fire_due(&fx.svc, now_ms(&fx.clock))
		l4, held4 := lease_of(fx, "inst_w1")
		testing.expect(t, held4 && l4.lease_id == l3.lease_id, "confirmed lease is not expired by the unconfirmed timers")
	}
}

@(test)
test_idle_ttl_stops_stranded_instance :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "t_idle")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_idle")
	seed_fleet(fx, chain, "agt_w", idle_ttl = 120)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1")
	lease, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held, "leased") do return
	// submit: holder stopped for fresh context; the stop is in the release wake
	wake_log_reset(log)
	submit_via_release(t, fx, lease)
	testing.expect(t, wake_log_has_stop(log, "inst_w1"), "submit stops the holder")
	// Simulate the bridge not honouring it (instance still live) → idle_ttl fires a stop again.
	wake_log_reset(log)
	fixture_advance(fx, 121)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect(t, wake_log_has_stop(log, "inst_w1"), "idle_ttl stop[] for a stranded live instance")
	// never the coordinator
	testing.expect(t, !wake_log_has_stop(log, "inst_coord"), "coordinator exempt")
	// an instance that picked up a new lease meanwhile is left alone
	wake_log_reset(log)
	_ = publish_task(t, fx, chain, "task_2")
	_, held2 := lease_of(fx, "inst_w1")
	testing.expect(t, held2, "re-leased")
	fixture_advance(fx, 121)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect(t, !wake_log_has_stop(log, "inst_w1"), "idle_ttl is a no-op for a lease holder")
}

@(test)
test_ready_unclaimed_alert_and_blocked_realert :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "t_alerts")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_alerts")
	// no fleet → nobody can take it
	_ = publish_task(t, fx, chain, "task_1")
	fixture_advance(fx, READY_UNCLAIMED_SECONDS + 1)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect_value(t, count_events(fx, "task_1", EV_READY_UNCLAIMED), 1)
	// blocked on human (block event) → 24 h re-alert, re-armed
	task := get_task(fx, "task_1")
	u, _, _ := begin_uow(&fx.svc)
	_, _, _, _ = record_event(&fx.svc, &u, task, hub_actor(), EV_BLOCKED, `{"attempt_no":0,"waiting_on":{"kind":"human","reason":"need a decision"}}`)
	_, _ = end_uow(&fx.svc, &u, true)
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.Backlog)
	fixture_advance(fx, BLOCKED_REALERT_SECONDS + 1)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect_value(t, count_events(fx, "task_1", EV_BLOCKED_REALERT), 1)
	fixture_advance(fx, BLOCKED_REALERT_SECONDS + 1)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect_value(t, count_events(fx, "task_1", EV_BLOCKED_REALERT), 2)
}

// ---- chokepoints ------------------------------------------------------------------------

// Ports test_fsm_watchdog_auto_recovery_crashed_worker_respawn: the instance
// dies → on_instance_terminal expires (instance_lost) → the matcher re-grants to
// the same (now stopped, warm) instance → wake re-bootstraps it.
@(test)
test_instance_terminal_expires_and_respawns_warm_instance :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "c_term")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_term")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1")
	lease, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held, "leased") do return
	// the bridge reports the instance stopped
	confirm_holder(fx, "inst_w1")
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	inst.runtime_status = "stopped"
	_, _, _ = iface.agent_save_instance(&fx.agents, inst)
	wake_log_reset(log)
	on_instance_terminal(&fx.svc, "inst_w1")
	testing.expect(t, strings.contains(last_event_payload(fx, "task_1", EV_LEASE_EXPIRED), `"reason":"instance_lost"`), "instance_lost")
	l2, held2 := lease_of(fx, "inst_w1")
	testing.expect(t, held2 && l2.lease_id != lease.lease_id, "re-granted to the warm stopped instance")
	testing.expect_value(t, l2.attempt_no, 2)
	testing.expect(t, wake_log_has_run(log, "inst_w1"), "wake re-bootstraps the same instance id")
	testing.expect(t, !wake_log_has_stop(log, "inst_w1"), "a dead instance is not stopped again")
	testing.expect_value(t, get_task(fx, "task_1").attempt_no, 2)
	// no-op for an instance holding nothing
	on_instance_terminal(&fx.svc, "inst_coord")
	on_instance_terminal(&fx.svc, "inst_unknown")
	// budget: after 5 counting expiries the task parks in backlog blocked on human
	for i in 0..<4 {
		confirm_holder(fx, "inst_w1")
		on_instance_terminal(&fx.svc, "inst_w1")
	}
	parked := get_task(fx, "task_1")
	testing.expect_value(t, parked.state, domain.Task_State.Backlog)
	testing.expect(t, strings.contains(parked.blocked_on_json, `"human"`), "budget exhausted → blocked on human")
	_, held5 := lease_of(fx, "inst_w1")
	testing.expect(t, !held5, "no grant after the budget")
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "term")
}

@(test)
test_bridge_hello_stops_orphan_without_lease :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "c_hello")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_hello")
	seed_fleet(fx, chain, "agt_w", capacity = 2)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_w2", "agt_w", "br_1", "running")
	_ = publish_task(t, fx, chain, "task_1")
	confirm_holder(fx, "inst_w1")
	lease, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held, "w1 leased") do return
	// Bridge disconnects: instances go `unreachable`, the bridge Offline. That is
	// absence, not death — the lease stays (B2).
	bridge_disconnect(fx, "br_1")
	l_after, still := lease_of(fx, "inst_w1")
	testing.expect(t, still && l_after.lease_id == lease.lease_id, "disconnect alone keeps the lease")
	// Away > TTL: the TTL fires → expired(ttl); the task is HELD (bridge offline), nobody re-granted.
	fixture_advance(fx, LEASE_TTL_SECONDS + 1)
	wake_log_reset(log)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect(t, strings.contains(last_event_payload(fx, "task_1", EV_LEASE_EXPIRED), `"reason":"ttl"`), "ttl expiry while away")
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.Ready)
	leases_mid, _ := iface.taskchain_list_leases_by_chain(&fx.repo, chain.chain_id)
	testing.expect_value(t, len(leases_mid), 0)
	testing.expect_value(t, len(log.cmds), 0) // nothing can be sent to an offline bridge
	// Reconnect: both workers still report active (the orphan w1 kept running).
	wake_log_reset(log)
	bridge_reconnect(fx, "br_1", []string{"inst_coord", "inst_w1", "inst_w2"})
	on_bridge_hello(&fx.svc, "br_1", []string{"inst_coord", "inst_w1", "inst_w2"})
	// exactly one holder, the other stopped; never the coordinator
	holder := ""
	if l, h := lease_of(fx, "inst_w1"); h && l.task_id == "task_1" do holder = "inst_w1"
	if l, h := lease_of(fx, "inst_w2"); h && l.task_id == "task_1" do holder = "inst_w2"
	testing.expect(t, holder != "", "task re-granted on hello")
	leases_end, _ := iface.taskchain_list_leases_by_chain(&fx.repo, chain.chain_id)
	testing.expect_value(t, len(leases_end), 1)
	other := "inst_w2" if holder == "inst_w1" else "inst_w1"
	testing.expect(t, wake_log_has_run(log, holder), "new grant delivered on hello")
	testing.expect(t, wake_log_has_stop(log, other), "lease-less live worker stopped on hello")
	testing.expect(t, !wake_log_has_stop(log, "inst_coord"), "coordinator never stopped")
}

// bridge_disconnect mirrors bridge_ws_disconnect: bridge Offline, every active
// instance `unreachable`, then the terminal chokepoint for each (after unlock).
bridge_disconnect :: proc(fx: ^Fixture, bridge_id: string) {
	set_bridge_status(fx, bridge_id, false)
	insts, _ := iface.agent_list_instances_by_bridge(&fx.agents, bridge_id)
	for inst in insts {
		if inst.runtime_status != "running" && inst.runtime_status != "idle" && inst.runtime_status != "busy" do continue
		row := inst
		row.runtime_status = "unreachable"
		row.updated_at = platform.clock_now(&fx.clock)
		_, _, _ = iface.agent_save_instance(&fx.agents, row)
		on_instance_terminal(&fx.svc, inst.agent_instance_id)
	}
}

// bridge_reconnect mirrors the hello path before on_bridge_hello: bridge
// Online, reported-active instances back to running.
bridge_reconnect :: proc(fx: ^Fixture, bridge_id: string, active: []string) {
	set_bridge_status(fx, bridge_id, true)
	for id in active {
		inst, ok, _ := iface.agent_get_instance(&fx.agents, id)
		if !ok do continue
		inst.runtime_status = "running"
		inst.last_seen_at = platform.clock_now(&fx.clock)
		_, _, _ = iface.agent_save_instance(&fx.agents, inst)
	}
}

// B2: a WS blip under the TTL is invisible to the lease system.
@(test)
test_bridge_blip_under_ttl_keeps_lease :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "c_blip")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_blip")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1")
	confirm_holder(fx, "inst_w1")
	lease, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held, "leased") do return
	wake_log_reset(log)
	bridge_disconnect(fx, "br_1")
	fixture_advance(fx, 60)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	bridge_reconnect(fx, "br_1", []string{"inst_coord", "inst_w1"})
	on_bridge_hello(&fx.svc, "br_1", []string{"inst_coord", "inst_w1"})
	same, still := lease_of(fx, "inst_w1")
	testing.expect(t, still && same.lease_id == lease.lease_id, "same lease after the blip")
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_EXPIRED), 0)
	testing.expect_value(t, get_task(fx, "task_1").attempt_no, 1)
	testing.expect(t, !wake_log_has_stop(log, "inst_w1") && !wake_log_has_run(log, "inst_w1"), "holder neither stopped nor restarted")
	// A REAL death reported while the bridge is Online still expires at once.
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	inst.runtime_status = "unreachable" // heartbeat reconcile shape (bridge Online, instance gone)
	_, _, _ = iface.agent_save_instance(&fx.agents, inst)
	on_instance_terminal(&fx.svc, "inst_w1")
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_EXPIRED), 1)
	testing.expect(t, strings.contains(last_event_payload(fx, "task_1", EV_LEASE_EXPIRED), `"reason":"instance_lost"`), "instance_lost when the bridge is online")
}

// B3: cancelling a leased task reclaims the lease and never re-grants it.
@(test)
test_cancel_leased_task_leaves_no_lease_and_stops_holder :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "c_cancel_leased")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_cl")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	task := publish_task(t, fx, chain, "task_1")
	confirm_holder(fx, "inst_w1")
	_, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held, "leased") do return
	wake_log_reset(log)
	testing.expect(t, cancel_task(&fx.svc, get_task(fx, "task_1"), Actor{kind = ACTOR_USER, id = "u1"}, "scope cut").code == .None, "cancel")
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.Cancelled)
	leases, _ := iface.taskchain_list_leases_by_task(&fx.repo, task.task_id)
	testing.expect_value(t, len(leases), 0)
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_EXPIRED), 1)
	testing.expect(t, strings.contains(last_event_payload(fx, "task_1", EV_LEASE_EXPIRED), `"reason":"cancelled"`), "reason cancelled")
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_GRANTED), 1)
	testing.expect(t, wake_log_has_stop(log, "inst_w1"), "holder stopped")
	testing.expect(t, !wake_log_has_run(log, "inst_w1"), "holder NOT re-woken")
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	testing.expect(t, inst.current_task_id == "", "pointer cleared")
	attempts, _ := iface.taskchain_list_attempts_by_task(&fx.repo, task.task_id, "u1")
	testing.expect(t, len(attempts) == 1 && attempts[0].ended_at != "", "single attempt, closed")
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "cancel leased")
}

// B1: the single allowed lock order is tx_mutex → connection state_mutex. A
// unit of work begun while a state_mutex is held is a violation.
@(test)
test_lock_order_uow_under_state_mutex_is_a_violation :: proc(t: ^testing.T) {
	when ODIN_DEBUG {
		// begin would panic by design; only the bookkeeping is checked here.
		lockorder.state_mutex_enter()
		testing.expect(t, lockorder.state_mutex_held(), "held")
		lockorder.state_mutex_leave()
		testing.expect(t, !lockorder.state_mutex_held(), "released")
	} else {
		fx, ok := fixture_open(t, "lockorder")
		defer fixture_close(fx)
		if !ok do return
		before := lockorder.violations
		lockorder.state_mutex_enter()
		u, bok, _ := begin_uow(&fx.svc)
		lockorder.state_mutex_leave()
		if bok do _, _ = end_uow(&fx.svc, &u, false)
		testing.expect_value(t, lockorder.violations, before + 1)
		// the normal order is silent
		u2, bok2, _ := begin_uow(&fx.svc)
		if bok2 do _, _ = end_uow(&fx.svc, &u2, false)
		testing.expect_value(t, lockorder.violations, before + 1)
	}
}

// confirm_holder: the holder's start-success (confirms a wake-delivered lease).
confirm_holder :: proc(fx: ^Fixture, inst_id: string) {
	inst, ok, _ := iface.agent_get_instance(&fx.agents, inst_id)
	if ok do on_start_success(&fx.svc, inst)
}

lease_of_id :: proc(fx: ^Fixture, inst: string) -> string {
	l, ok := lease_of(fx, inst)
	return l.lease_id if ok else ""
}

@(test)
test_chain_cancel_reclaims_leases :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "c_cancel")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_cancel")
	seed_fleet(fx, chain, "agt_w", capacity = 2)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_w2", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1")
	_ = publish_task(t, fx, chain, "task_2", bridge_pin = "br_1")
	leases, _ := iface.taskchain_list_leases_by_chain(&fx.repo, chain.chain_id)
	testing.expect_value(t, len(leases), 2)
	wake_log_reset(log)
	chain.status = .Cancelled
	_, _, _ = iface.taskchain_save_chain(&fx.repo, chain)
	testing.expect(t, chain_closed(&fx.svc, chain, Actor{kind = ACTOR_USER, id = "u1"}, true).code == .None, "chain_closed")
	after, _ := iface.taskchain_list_leases_by_chain(&fx.repo, chain.chain_id)
	testing.expect_value(t, len(after), 0)
	testing.expect(t, wake_log_has_stop(log, "inst_w1") && wake_log_has_stop(log, "inst_w2"), "both holders stopped")
	testing.expect(t, !wake_log_has_stop(log, "inst_coord"), "coordinator exempt")
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.Cancelled)
	testing.expect_value(t, get_task(fx, "task_2").state, domain.Task_State.Cancelled)
	// timers of the closed chain are no-ops
	fixture_advance(fx, LEASE_HARD_CAP_SECONDS + 1)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_EXPIRED), 1) // only chain_closed
	for inst_id in ([]string{"inst_w1", "inst_w2"}) {
		inst, _, _ := iface.agent_get_instance(&fx.agents, inst_id)
		testing.expect(t, inst.current_task_id == "", "pointer cleared")
	}
}

@(test)
test_dep_added_to_started_work_is_rejected_without_releasing_lease :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "c_dep")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_dep")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	a := publish_task(t, fx, chain, "task_a")
	testing.expect_value(t, a.state, domain.Task_State.In_Progress)
	b := publish_task(t, fx, chain, "task_b")
    _, accepted, err := work_dependency_add(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, chain.chain_id,
        domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK, id = string(a.task_id)},
        domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK, id = string(b.task_id)})
    testing.expect(t, !accepted && err.code == .Conflict, "started work input contract is immutable")
    lease, held := lease_of(fx, "inst_w1")
    testing.expect(t, held && lease.task_id == a.task_id, "original lease retained")
    testing.expect_value(t, get_task(fx, "task_a").state, domain.Task_State.In_Progress)
    edges, _ := iface.taskchain_list_work_dependencies(&fx.repo, chain.chain_id, "u1")
    testing.expect(t, len(edges) == 0, "rejection leaves no edge")
    assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "rejected dependency")
}

// ---- reviews ------------------------------------------------------------------------------

// Ports test_fsm_reviewer_auto_binding_and_jit_on_in_validation (warm variant):
// submit with review_roles → in_review → a reviewer-role fleet instance that is
// NOT the author's template gets a review lease.
@(test)
test_review_lease_granted_excluding_author_template :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "r_review")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_rev")
	seed_fleet(fx, chain, "agt_w", roles = `["worker","reviewer"]`, capacity = 2)
	seed_fleet(fx, chain, "agt_r", roles = `["reviewer"]`)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_w2", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "idle")
	task := publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","review_roles":["reviewer"]}`)
	testing.expect_value(t, task.state, domain.Task_State.In_Progress)
	work, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held, "w1 works") do return
	wake_log_reset(log)
	submit_via_release(t, fx, work)
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.In_Review)
	_, w2 := lease_of(fx, "inst_w2")
	testing.expect(t, !w2, "same template as the author never reviews")
	rl, rheld := lease_of(fx, "inst_r1")
	if testing.expect(t, rheld, "reviewer leased") {
		testing.expect_value(t, rl.kind, domain.LEASE_KIND_REVIEW)
		testing.expect_value(t, rl.review_role, "reviewer")
		testing.expect_value(t, rl.task_id, task.task_id)
	}
	testing.expect(t, wake_log_has_run(log, "inst_r1"), "reviewer woken")
	if len(log.cmds) > 0 do testing.expect(t, strings.contains(log.cmds[len(log.cmds)-1].body_json, `"role":"reviewer"`), "role reviewer in run entry")
	inst_r, _, _ := iface.agent_get_instance(&fx.agents, "inst_r1")
	testing.expect_value(t, inst_r.current_task_role, domain.Current_Task_Role.Review)
	// review leases do not block the directory rule and are not counted as work
	leases, _ := iface.taskchain_list_leases_by_task(&fx.repo, task.task_id)
	testing.expect_value(t, len(leases), 1)
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "review")
}

// ---- lease.next / heartbeat verbs ------------------------------------------------------

@(test)
test_lease_next_inline_grant_idempotent_and_coordinator_none :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "v_next")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_next")
	seed_fleet(fx, chain, "agt_w")
	// no instance yet → the published task is held
	task := publish_task(t, fx, chain, "task_1")
	testing.expect_value(t, task.state, domain.Task_State.Ready)
	// a worker appears and pulls
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "running")
	auth := contracts.Auth_Context{kind = .Instance_Token, user_id = "u1", agent_instance_id = "inst_w1"}
	wake_log_reset(log)
	res, nok, nerr := lease_next(&fx.svc, auth, Lease_Next_Input{vcs_base = "abc123"})
	if !testing.expect(t, nok, fmt.tprintf("lease.next: %s", nerr.message)) do return
	testing.expect_value(t, res.status, "granted")
	testing.expect_value(t, res.lease.delivery, domain.LEASE_DELIVERY_INLINE)
	testing.expect(t, res.lease.confirmed_at != "", "inline grant is confirmed at once")
	testing.expect_value(t, res.task.task_id, task.task_id)
	testing.expect(t, strings.contains(res.pack_json, fmt.tprintf(`"lease_id":"%s"`, res.lease.lease_id)) && strings.contains(res.pack_json, `"why":"first_grant"`), "pack built")
	testing.expect(t, !wake_log_has_run(log, "inst_w1"), "the caller is never woken")
	testing.expect(t, strings.contains(last_event_payload(fx, "task_1", EV_ATTEMPT_STARTED), `"vcs_base":"abc123"`), "attempt_started recorded with vcs_base")
	// idempotent: same lease back
	again, aok, _ := lease_next(&fx.svc, auth, Lease_Next_Input{})
	testing.expect(t, aok && again.status == "current" && again.lease.lease_id == res.lease.lease_id, "lease.next returns the held lease")
	testing.expect_value(t, count_events(fx, "task_1", EV_ATTEMPT_STARTED), 1)
	// coordinator → none
	cres, cok, _ := lease_next(&fx.svc, contracts.Auth_Context{kind = .Instance_Token, user_id = "u1", agent_instance_id = "inst_coord"}, Lease_Next_Input{})
	testing.expect(t, cok && cres.status == "none", "coordinator gets none")
	// a user token is refused
	_, uok, uerr := lease_next(&fx.svc, contracts.Auth_Context{kind = .User_Token, user_id = "u1"}, Lease_Next_Input{})
	testing.expect(t, !uok && uerr.code == .Forbidden, "instance token required")
	// an instance on another chain's user: not found
	_, xok, xerr := lease_next(&fx.svc, contracts.Auth_Context{kind = .Instance_Token, user_id = "u2", agent_instance_id = "inst_w1"}, Lease_Next_Input{})
	testing.expect(t, !xok && xerr.code == .Not_Found, "owner mismatch")
}

@(test)
test_lease_heartbeat_lease_lost_409 :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "v_hb")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_hb")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	auth := contracts.Auth_Context{kind = .Instance_Token, user_id = "u1", agent_instance_id = "inst_w1"}
	_, hok, herr := lease_heartbeat(&fx.svc, auth, Lease_Heartbeat_Input{})
	testing.expect(t, !hok && herr.code == .Conflict && strings.contains(herr.message, "lease_lost"), "no lease → 409 lease_lost")
	_ = publish_task(t, fx, chain, "task_1")
	lease, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held, "leased") do return
	fixture_advance(fx, 60)
	saved, ok2, _ := lease_heartbeat(&fx.svc, auth, Lease_Heartbeat_Input{lease_id = lease.lease_id, note = "halfway"})
	testing.expect(t, ok2 && to_ms(saved.expires_at) > to_ms(lease.expires_at), "extended")
	testing.expect_value(t, count_events(fx, "task_1", EV_HEARTBEAT), 1)
	_, bad, berr := lease_heartbeat(&fx.svc, auth, Lease_Heartbeat_Input{lease_id = "lease_other"})
	testing.expect(t, !bad && berr.code == .Conflict, "wrong lease id → lease_lost")
	// after expiry the orphan's heartbeat is 409
	fixture_advance(fx, LEASE_HARD_CAP_SECONDS + 1)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	// (it may have been re-granted a NEW lease; a heartbeat naming the old one is lost)
	_, lost, lerr := lease_heartbeat(&fx.svc, auth, Lease_Heartbeat_Input{lease_id = lease.lease_id})
	testing.expect(t, !lost && lerr.code == .Conflict, "expired lease → 409 lease_lost")
}

// ---- boot --------------------------------------------------------------------------------

@(test)
test_boot_heals_leaseless_in_progress_and_rearms :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "boot")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_boot")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1")
	lease, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held, "leased") do return
	// Simulate a crash between lease delete and event: delete the row only.
	_, _ = iface.taskchain_delete_lease(&fx.repo, lease.lease_id)
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.In_Progress)
	// Fresh service over the same DB (hub restart): empty heap.
	fx.svc.timers = Timer_Service{}
	boot(&fx.svc)
	testing.expect(t, strings.contains(last_event_payload(fx, "task_1", EV_LEASE_EXPIRED), EXPIRE_HUB_RESTART), "healed with hub_restart_no_lease")
	// boot's match_chain re-granted it to the idle worker and armed its timers
	l2, held2 := lease_of(fx, "inst_w1")
	testing.expect(t, held2 && l2.lease_id != lease.lease_id, "re-granted on boot")
	testing.expect(t, timers_armed_count(&fx.svc) >= 3, "ttl + hard cap + unconfirmed armed from columns")
	// second boot over a confirmed lease: no heal, timers rebuilt from columns
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	on_start_success(&fx.svc, inst)
	fx.svc.timers = Timer_Service{}
	boot(&fx.svc)
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_EXPIRED), 1)
	testing.expect(t, timers_armed_count(&fx.svc) >= 2, "ttl + hard cap re-armed")
	l3, held3 := lease_of(fx, "inst_w1")
	testing.expect(t, held3 && l3.lease_id == l2.lease_id, "live lease untouched by boot")
}

// ---- MEM-4: heap keys never alias a request arena -------------------------------------

@(test)
test_timer_heap_keys_not_in_request_arena :: proc(t: ^testing.T) {
	svc := Service{}
	arena: mem.Arena
	backing := make([]byte, 64 * 1024)
	defer delete(backing)
	mem.arena_init(&arena, backing)
	arena_alloc := mem.arena_allocator(&arena)
	{
		context.allocator = arena_alloc
		context.temp_allocator = arena_alloc
		key := strings.clone("lease_request_scoped")
		armed := strings.clone("2026-01-01T00:00:00Z")
		timers_arm(&svc, .Lease_TTL, key, 1000, armed)
		timers_arm(&svc, .Idle_TTL, strings.clone("inst_request_scoped"), 2000, "")
	}
	// Request arena freed: the heap must not reference it.
	mem.arena_free_all(&arena)
	for i in 0..<len(backing) do backing[i] = 0xAA
	ptr_in_arena :: proc(arena: ^mem.Arena, s: string) -> bool {
		if len(s) == 0 do return false
		start := uintptr(raw_data(arena.data))
		end := start + uintptr(len(arena.data))
		p := uintptr(raw_data(s))
		return p >= start && p < end
	}
	due := timers_pop_due(&svc, 5000)
	defer delete(due)
	testing.expect_value(t, len(due), 2)
	for &tm in due {
		testing.expect(t, !ptr_in_arena(&arena, tm.key), "timer key is heap-owned")
		testing.expect(t, !ptr_in_arena(&arena, tm.armed), "timer armed stamp is heap-owned")
		testing.expect(t, tm.key == "lease_request_scoped" || tm.key == "inst_request_scoped", fmt.tprintf("key intact: %q", tm.key))
		timer_destroy(&tm)
	}
	delete(svc.timers.heap)
	_ = runtime.heap_allocator
}

// ---- JIT ------------------------------------------------------------------------------------

// Ports test_dynamic_fleet_jit_provisioning: with no warm instance and live
// count < capacity the matcher prepares a new instance (no network inside the
// UoW), the fleet row's provider/model win, the task pin overrides the bridge
// and the coordinator's project context is inherited; the launch is the wake.
@(test)
test_matcher_jit_provisions_within_capacity :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "jit")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_jit")
	seed_bridge(fx, "br_2")
	// repos the agent service needs
	pr_impl := sqlite.Project_Repo_SQLite{conn = &fx.conn}
	pr_repo := sqlite.new_project_repository(&pr_impl, &fx.conn)
	co_impl := sqlite.Content_Repo_SQLite{conn = &fx.conn}
	co_repo := sqlite.new_content_repository(&co_impl, &fx.conn)
	pv_impl := sqlite.Provider_Repo_SQLite{conn = &fx.conn}
	pv_repo := sqlite.new_provider_repository(&pv_impl, &fx.conn)
	for b in ([]string{"br_1", "br_2"}) {
		_, _ = iface.bridge_provider_status_upsert(&pv_repo, domain.Bridge_Provider_Status{bridge_id = b, provider = "claude", state = "present"})
		_, _ = iface.bridge_provider_setting_upsert(&pv_repo, domain.Bridge_Provider_Setting{bridge_id = b, provider = "claude", enabled = true})
		_, _, _ = iface.agent_save_support(&fx.agents, domain.Agent_Bridge_Support{agent_id = "agt_w", bridge_id = b, owner_user_id = "u1", enabled = true})
	}
	now := platform.clock_now(&fx.clock)
	_, _, _ = iface.project_save(&pr_repo, domain.Project{project_id = "prj_1", owner_user_id = "u1", name = "P", slug = "p", default_path = "/srv/default", state = .Active, created_at = now, updated_at = now})
	_, _, _ = iface.project_save_bridge_path(&pr_repo, domain.Project_Bridge_Path{project_id = "prj_1", bridge_id = "br_2", owner_user_id = "u1", path = "/srv/override", created_at = now, updated_at = now})
	coord, _, _ := iface.agent_get_instance(&fx.agents, "inst_coord")
	coord.project_id = "prj_1"
	_, _, _ = iface.agent_save_instance(&fx.agents, coord)
	registry := project.Bridge_Runtime_Registry{}
	project.bridge_runtime_registry_mark_live(&registry, "br_1", false, "")
	project.bridge_runtime_registry_mark_live(&registry, "br_2", false, "")
	sent := 0
	sink := project.Bridge_Command_Sink{ctx = rawptr(&sent), send_runtime_command = proc(ctx: rawptr, cmd: project.Runtime_Command) -> (bool, domain.Domain_Error) {
		(^int)(ctx)^ += 1
		return true, domain.Domain_Error{}
	}}
	ag_service := agent.new_agent_service_with_runtime(&fx.agents, &fx.bridges, &pr_repo, &co_repo, &fx.repo, sink, &registry, &fx.clock, &fx.ids)
	ag_service.providers = &pv_repo
	fx.svc.agent_service = &ag_service
	fx.svc.bridge_command_sink = sink

	seed_fleet(fx, chain, "agt_w", capacity = 2)
	f, _ := iface.taskchain_list_fleets_by_chain(&fx.repo, chain.chain_id, "u1")
	f[0].provider = "claude"
	f[0].model = "claude-fable-5-1"
	_, _ = iface.taskchain_upsert_fleet(&fx.repo, f[0])

	task := publish_task(t, fx, chain, "task_jit", bridge_pin = "br_2")
	testing.expect_value(t, task.state, domain.Task_State.In_Progress)
	leases, _ := iface.taskchain_list_leases_by_task(&fx.repo, task.task_id)
	if !testing.expect(t, len(leases) == 1, "one lease") do return
	spawned, iok, _ := iface.agent_get_instance(&fx.agents, leases[0].holder_instance_id)
	if !testing.expect(t, iok, "JIT instance row exists") do return
	testing.expect_value(t, spawned.agent_id, "agt_w")
	testing.expect_value(t, spawned.bridge_id, "br_2")
	testing.expect_value(t, spawned.chain_id, string(chain.chain_id))
	testing.expect_value(t, string(spawned.project_id), "prj_1")
	testing.expect_value(t, spawned.project_path, "/srv/override")
	testing.expect_value(t, spawned.provider, "claude")
	testing.expect_value(t, spawned.model, "claude-fable-5-1")
	testing.expect_value(t, spawned.current_task_id, "task_jit")
	members, _ := iface.taskchain_list_members_by_chain(&fx.repo, chain.chain_id, "u1")
	enrolled := false
	for m in members do if m.agent_instance_id == spawned.agent_instance_id do enrolled = true
	testing.expect(t, enrolled, "JIT instance enrolled as chain member")
	// the launch IS the wake (one send, after commit), not a launch_agent command
	testing.expect_value(t, sent, 1)
	testing.expect(t, wake_log_has_run(log, spawned.agent_instance_id), "wake run[] launches the JIT instance")
	// capacity 2: a second task JITs a second instance; a third waits
	_ = publish_task(t, fx, chain, "task_jit2", bridge_pin = "br_2")
	t3 := publish_task(t, fx, chain, "task_jit3", bridge_pin = "br_2")
	all, _ := iface.taskchain_list_leases_by_chain(&fx.repo, chain.chain_id)
	testing.expect_value(t, len(all), 2)
	testing.expect_value(t, t3.state, domain.Task_State.Ready)
	// fleet provider/model cleared → catalog default on the next JIT
	f2, _ := iface.taskchain_list_fleets_by_chain(&fx.repo, chain.chain_id, "u1")
	f2[0].provider = ""
	f2[0].model = ""
	f2[0].capacity = 3
	_, _ = iface.taskchain_upsert_fleet(&fx.repo, f2[0])
	testing.expect(t, fleet_changed(&fx.svc, chain).code == .None, "fleet_changed")
	all3, _ := iface.taskchain_list_leases_by_chain(&fx.repo, chain.chain_id)
	testing.expect_value(t, len(all3), 3)
	for l in all3 {
		if l.task_id == "task_jit3" {
			third, _, _ := iface.agent_get_instance(&fx.agents, l.holder_instance_id)
			testing.expect_value(t, third.provider, "claude")
			testing.expect_value(t, third.model, "claude-opus-5-5")
		}
	}
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "jit")
}
