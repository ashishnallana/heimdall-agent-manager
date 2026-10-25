package taskv2

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// REQ-TV2-5: task hold / release and fleet pause.

@(test)
test_hold_leased_task_handoff_parks_until_release :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "hold_checkpoint")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_hold")
	seed_fleet(fx, chain, "agt_w", capacity = 2)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_w2", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"review_roles":[]}`)
	confirm_holder(fx, "inst_w1")
	l1, leased := lease_of(fx, "inst_w1")
	if !testing.expect(t, leased, "task_1 granted to inst_w1") do return
	owner := actor_from_auth(user_auth())

	// Hold while leased: the lease is kept, a checkpoint is requested.
	hr, hok, herr := task_hold(&fx.svc, get_task(fx, "task_1"), owner, "repair the brief")
	if !testing.expect(t, hok, fmt.tprintf("hold: %s", herr.message)) do return
	testing.expect(t, hr.changed && hr.checkpoint_requested, "hold on a leased task requests a checkpoint")
	row := get_task(fx, "task_1")
	testing.expect_value(t, row.state, domain.Task_State.In_Progress)
	testing.expect(t, task_is_held(row) && strings.contains(row.blocked_on_json, `"checkpoint_requested":true`), "held badge with checkpoint request")
	_, still := lease_of(fx, "inst_w1")
	testing.expect(t, still, "hold never revokes the lease")
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	pack := build_pack_json(&fx.svc, chain, row, l1, inst)
	testing.expect(t, strings.contains(pack, `"checkpoint":{"reason":"repair the brief"}`), "pack carries the checkpoint request")
	// A second hold is a no-op.
	again, aok, _ := task_hold(&fx.svc, row, owner, "again")
	testing.expect(t, aok && !again.changed, "hold on a held task is a no-op")

	// The holder hands off: the task parks instead of being re-dispatched.
	_, dok, derr := lease_handoff(&fx.svc, inst_auth("inst_w1"), Handoff_Input{summary = "checkpointed"})
	if !testing.expect(t, dok, fmt.tprintf("handoff: %s", derr.message)) do return
	row = get_task(fx, "task_1")
	testing.expect_value(t, row.state, domain.Task_State.Backlog)
	testing.expect(t, task_is_held(row) && !strings.contains(row.blocked_on_json, "checkpoint_requested"), "parked as blocked_on {kind: hold}")
	_, w1 := lease_of(fx, "inst_w1")
	_, w2 := lease_of(fx, "inst_w2")
	testing.expect(t, !w1 && !w2, "a held task gets no new lease after handoff")
	// The matcher re-running (e.g. a fleet change) still grants nothing; a
	// hold is not cleared by answer.
	testing.expect(t, fleet_changed(&fx.svc, chain).code == .None, "fleet_changed")
	_, w1 = lease_of(fx, "inst_w1")
	_, w2 = lease_of(fx, "inst_w2")
	testing.expect(t, !w1 && !w2, "no dispatch race while held")
	_, ansok, anserr := task_answer(&fx.svc, row, owner, "")
	testing.expect(t, !ansok && anserr.code == .Conflict, "answer does not clear a hold")

	// Release: the task dispatches again as the same (handoff) attempt.
	rr, rok, rerr := task_release(&fx.svc, row, owner)
	if !testing.expect(t, rok, fmt.tprintf("release: %s", rerr.message)) do return
	testing.expect(t, rr.changed, "release changed the task")
	row = get_task(fx, "task_1")
	testing.expect(t, !task_is_held(row), "hold cleared")
	holder := ""
	if l, h := lease_of(fx, "inst_w1"); h { holder = "inst_w1"; testing.expect_value(t, l.attempt_no, 1) }
	if l, h := lease_of(fx, "inst_w2"); h { holder = "inst_w2"; testing.expect_value(t, l.attempt_no, 1) }
	testing.expect(t, holder != "", "released task is dispatched")
	testing.expect_value(t, row.state, domain.Task_State.In_Progress)

	// Releasing an unheld task is a no-op with a message.
	nr, nok, _ := task_release(&fx.svc, row, owner)
	testing.expect(t, nok && !nr.changed && strings.contains(nr.message, "not held"), "release of an unheld task is a no-op")
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "hold/release")
}

@(test)
test_hold_unleased_task_never_dispatches :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "hold_unleased")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_hold2")
	seed_fleet(fx, chain, "agt_w")
	task := seed_task(t, fx, chain, "task_1", `{"goal":"g","acceptance":["a"],"review_roles":[]}`)
	owner := actor_from_auth(user_auth())
	_, hok, herr := task_hold(&fx.svc, task, owner, "fix brief first")
	if !testing.expect(t, hok, fmt.tprintf("hold: %s", herr.message)) do return
	// Publish + a free instance: still no lease while held.
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"review_roles":[]}`)
	row := get_task(fx, "task_1")
	testing.expect_value(t, row.state, domain.Task_State.Backlog)
	testing.expect(t, task_is_held(row), "held badge")
	_, leased := lease_of(fx, "inst_w1")
	testing.expect(t, !leased, "a held task is never granted")
	// Grants are refused at the source too (belt and braces).
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	u, _, _ := begin_uow(&fx.svc)
	_, gok, gerr := grant_in_uow(&fx.svc, &u, Grant_Request{chain = chain, task = row, instance = inst, kind = domain.LEASE_KIND_WORK, delivery = domain.LEASE_DELIVERY_INLINE, placement = Placement{bridge_id = "br_1"}, actor = hub_actor()})
	_, _ = end_uow(&fx.svc, &u, false)
	testing.expect(t, !gok && strings.contains(gerr.message, "held"), "grant_in_uow refuses a held task")
	_, rok, _ := task_release(&fx.svc, row, owner)
	testing.expect(t, rok, "release")
	_, leased = lease_of(fx, "inst_w1")
	testing.expect(t, leased, "released task is dispatched")
}

@(test)
test_fleet_pause_stops_new_grants_keeps_live_work :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "fleet_pause")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_pause")
	seed_fleet(fx, chain, "agt_w", capacity = 2)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_w2", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"review_roles":[]}`)
	confirm_holder(fx, "inst_w1")
	_, live := lease_of(fx, "inst_w1")
	if !testing.expect(t, live, "task_1 granted before the pause") do return

	set_paused :: proc(fx: ^Fixture, chain: domain.Task_Chain, paused: string) {
		now := platform.clock_now(&fx.clock)
		_, _ = iface.taskchain_upsert_fleet(&fx.repo, domain.Task_Chain_Fleet{task_chain_id = chain.chain_id, agent_id = "agt_w", capacity = 2, roles_json = `["worker"]`, paused_roles_json = paused, created_at = now, updated_at = now})
		_ = fleet_changed(&fx.svc, chain)
	}
	set_paused(fx, chain, domain.FLEET_PAUSED_ALL_JSON)
	_ = publish_task(t, fx, chain, "task_2", brief = `{"goal":"g","acceptance":["a"],"review_roles":[]}`)
	testing.expect_value(t, get_task(fx, "task_2").state, domain.Task_State.Ready)
	_, w2 := lease_of(fx, "inst_w2")
	testing.expect(t, !w2, "a paused row gets no new grant")
	_, live = lease_of(fx, "inst_w1")
	testing.expect(t, live, "the existing lease continues")
	// Pull is refused too.
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w2")
	res, nok, _ := lease_next(&fx.svc, inst_auth("inst_w2"), Lease_Next_Input{})
	testing.expect(t, nok && res.status == "none", fmt.tprintf("lease next while paused: %s", res.status))
	_ = inst
	// Pausing only a review role leaves work dispatch alone.
	set_paused(fx, chain, `["reviewer"]`)
	_, w2 = lease_of(fx, "inst_w2")
	testing.expect(t, w2, "resume of the worker role dispatches task_2")
}

@(test)
test_fleet_role_paused_helpers :: proc(t: ^testing.T) {
	f := domain.Task_Chain_Fleet{roles_json = `["worker","security"]`}
	testing.expect(t, !domain.fleet_paused_any(f) && !domain.fleet_role_paused(f, "worker"), "unpaused")
	f.paused_roles_json = `["security"]`
	testing.expect(t, domain.fleet_paused_any(f) && domain.fleet_role_paused(f, "security") && !domain.fleet_role_paused(f, "worker"), "one role paused")
	f.paused_roles_json = domain.FLEET_PAUSED_ALL_JSON
	testing.expect(t, domain.fleet_role_paused(f, "worker") && domain.fleet_role_paused(f, "security"), "all paused")
	kept := unpaused_review_roles(domain.Task_Chain_Fleet{paused_roles_json = `["security"]`}, []string{"security", "style"})
	testing.expect(t, len(kept) == 1 && kept[0] == "style", "paused review roles are not owed")
}
