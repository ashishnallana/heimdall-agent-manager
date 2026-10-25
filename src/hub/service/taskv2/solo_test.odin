package taskv2

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// Solo mode (REQ-SOLO-*): the chain coordinator is also its worker and the user
// reviews. The coordinator pulls inline, is never woken or stopped, its expiries
// and switches never count, and it can never approve its own work.

// solo_chain: seed_live_chain plus a worker fleet row for the coordinator's own
// agent (agt_c), which is what makes the chain solo (REQ-SOLO-1).
solo_chain :: proc(t: ^testing.T, fx: ^Fixture, chain_id: string) -> domain.Task_Chain {
	chain := seed_live_chain(t, fx, chain_id)
	seed_fleet(fx, chain, "agt_c")
	return chain
}

GREEN_VCS :: `{"head":"abc","dirty":false,"files":[]}`

// publish_solo_task: publish_task with requires_user_approval resolved the way
// the create paths do (brief_user_approval, REQ-SOLO-1a); seed_task writes the
// row directly and would leave it false.
publish_solo_task :: proc(t: ^testing.T, fx: ^Fixture, chain: domain.Task_Chain, id: string, brief := `{"goal":"g","review_roles":[]}`, priority := domain.Task_Priority.P2) -> domain.Task {
	task := seed_task(t, fx, chain, id, brief)
	task.priority = priority
	task.requires_user_approval = brief_user_approval(&fx.svc, chain, brief)
	task.publish_state = .Published
	_, _, _ = iface.taskchain_save_task(&fx.repo, task)
	err := task_created(&fx.svc, task, Actor{kind = ACTOR_USER, id = "u1"})
	testing.expect(t, err.code == .None, fmt.tprintf("task_created %s: %s", id, err.message))
	fresh, _, _ := iface.taskchain_get_task(&fx.repo, task.task_id)
	return fresh
}

@(test)
test_solo_coordinator_pulls_inline_and_is_never_woken_or_stopped :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "solo_pull")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := solo_chain(t, fx, "chain_solo_pull")
	testing.expect(t, chain_is_solo(&fx.svc, chain), "worker row for the coordinator's agent → solo")
	wake_log_reset(log)
	task := publish_solo_task(t, fx, chain, "task_1", brief = `{"goal":"g","review_roles":[]}`)
	testing.expect_value(t, task.state, domain.Task_State.Ready)
	testing.expect(t, !wake_log_has_run(log, "inst_coord"), "the matcher never wake-grants the soloist")
	_, held := lease_of(fx, "inst_coord")
	testing.expect(t, !held, "no lease until the soloist pulls")
	// REQ-SOLO-1a: no requires_user_approval in the brief → the user reviews
	testing.expect(t, get_task(fx, "task_1").requires_user_approval, "solo default: requires_user_approval")
	auth := inst_auth("inst_coord")
	res, nok, nerr := lease_next(&fx.svc, auth, Lease_Next_Input{})
	if !testing.expect(t, nok, fmt.tprintf("lease next: %s", nerr.message)) do return
	testing.expect_value(t, res.status, "granted")
	testing.expect_value(t, res.task.task_id, task.task_id)
	// submit → in_review for the user; the soloist is not stopped
	wake_log_reset(log)
	sub, sok, serr := lease_submit(&fx.svc, auth, Submit_Input{summary = "done", vcs_json = GREEN_VCS})
	if !testing.expect(t, sok, fmt.tprintf("submit: %s", serr.message)) do return
	testing.expect_value(t, sub.outcome, "in_review")
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.In_Review)
	testing.expect(t, !wake_log_has_stop(log, "inst_coord"), "submit never stops the soloist (REQ-SOLO-2a)")
	_, still := lease_of(fx, "inst_coord")
	testing.expect(t, !still, "submitted work releases the lease")
	// an explicit value in the brief wins; only an absent key takes the solo default
	testing.expect(t, !brief_user_approval(&fx.svc, chain, `{"goal":"g","requires_user_approval":false}`), "explicit false wins over the solo default")
	testing.expect(t, brief_user_approval(&fx.svc, chain, `{"goal":"g","requires_user_approval":true}`), "explicit true kept")
}

@(test)
test_solo_coordinator_gets_none_outside_solo_mode :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "solo_off")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_solo_off")
	testing.expect(t, !chain_is_solo(&fx.svc, chain), "no coordinator worker row → not solo")
	_ = publish_task(t, fx, chain, "task_1")
	testing.expect(t, !brief_user_approval(&fx.svc, chain, `{"goal":"g"}`), "non-solo default stays false")
	res, nok, _ := lease_next(&fx.svc, inst_auth("inst_coord"), Lease_Next_Input{})
	testing.expect(t, nok && res.status == "none", "a non-solo coordinator is never granted")
}

@(test)
test_solo_lease_switch_hands_off_and_grants_atomically :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "solo_switch")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := solo_chain(t, fx, "chain_solo_switch")
	_ = publish_task(t, fx, chain, "task_a", priority = .P1)
	_ = publish_task(t, fx, chain, "task_b", priority = .P2)
	auth := inst_auth("inst_coord")
	res, nok, _ := lease_next(&fx.svc, auth, Lease_Next_Input{})
	if !testing.expect(t, nok && res.status == "granted", "pulled") do return
	testing.expect_value(t, string(res.task.task_id), "task_a")
	a_attempt := res.lease.attempt_no
	// refusals change nothing (one UoW, rolled back)
	_, mok, merr := lease_switch(&fx.svc, auth, Switch_Input{task_id = "task_b"})
	testing.expect(t, !mok && merr.code == .Validation_Failed, "summary required")
	_, sok, serr := lease_switch(&fx.svc, auth, Switch_Input{task_id = "task_a", summary = "s"})
	testing.expect(t, !sok && serr.code == .Conflict, "switching to the held task → 409")
	_, nfok, nferr := lease_switch(&fx.svc, auth, Switch_Input{task_id = "task_nope", summary = "s"})
	testing.expect(t, !nfok && nferr.code == .Not_Found, "unknown task refused")
	still, sh := lease_of(fx, "inst_coord")
	testing.expect(t, sh && still.lease_id == res.lease.lease_id, "a refused switch keeps the current lease")
	testing.expect_value(t, count_events(fx, "task_a", EV_HANDOFF), 0)
	// the switch: handoff A (next steps kept), grant B, no stop
	wake_log_reset(log)
	sw, wok, werr := lease_switch(&fx.svc, auth, Switch_Input{task_id = "task_b", summary = "paused A", handoff_json = `{"next_steps":"finish A"}`})
	if !testing.expect(t, wok, fmt.tprintf("switch: %s", werr.message)) do return
	testing.expect_value(t, string(sw.task.task_id), "task_b")
	testing.expect_value(t, get_task(fx, "task_a").state, domain.Task_State.Ready)
	b_lease, bh := lease_of(fx, "inst_coord")
	testing.expect(t, bh && b_lease.task_id == "task_b", "the soloist now holds B")
	testing.expect(t, strings.contains(last_event_payload(fx, "task_a", EV_HANDOFF), `"switched_to":"task_b"`), "handoff names the next task")
	testing.expect(t, !wake_log_has_stop(log, "inst_coord") && !wake_log_has_run(log, "inst_coord"), "switch never stops or wakes the soloist")
	// back to A: same attempt number (the handoff did not count), handoff in the pack
	_, bsok, bserr := lease_submit(&fx.svc, auth, Submit_Input{summary = "B done", vcs_json = GREEN_VCS})
	if !testing.expect(t, bsok, fmt.tprintf("submit B: %s", bserr.message)) do return
	back, bok, _ := lease_next(&fx.svc, auth, Lease_Next_Input{})
	if !testing.expect(t, bok && back.status == "granted", "pulled A again") do return
	testing.expect_value(t, string(back.task.task_id), "task_a")
	testing.expect_value(t, back.lease.attempt_no, a_attempt)
	testing.expect(t, strings.contains(back.pack_json, "paused A") && strings.contains(back.pack_json, "finish A"), "pack carries the handoff summary and next steps")
	testing.expect(t, strings.contains(back.pack_json, `"why":"handoff"`), "why = handoff")
}

@(test)
test_solo_expiry_is_noncounting_and_repull_is_immediate :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "solo_expire")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := solo_chain(t, fx, "chain_solo_expire")
	_ = publish_task(t, fx, chain, "task_1")
	auth := inst_auth("inst_coord")
	res, nok, _ := lease_next(&fx.svc, auth, Lease_Next_Input{})
	if !testing.expect(t, nok && res.status == "granted", "pulled") do return
	// busy chatting with the user: no heartbeat past the TTL
	wake_log_reset(log)
	fixture_advance(fx, 3600)
	// Runtime evidence is fresh even though the lease heartbeat was missed.
	coord, _, _ := iface.agent_get_instance(&fx.agents, "inst_coord")
	coord.last_seen_at = platform.clock_now(&fx.clock)
	_, _, _ = iface.agent_save_instance(&fx.agents, coord)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect_value(t, count_events(fx, "task_1", EV_LEASE_EXPIRED), 1)
	testing.expect(t, strings.contains(last_event_payload(fx, "task_1", EV_LEASE_EXPIRED), `"counting":false`), "coordinator expiry is non-counting")
	testing.expect(t, !wake_log_has_stop(log, "inst_coord"), "expiry never stops the soloist")
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.Ready)
	// no recent-expiry lockout: the soloist re-pulls at once (a new attempt that
	// does not count toward the budget)
	again, aok, aerr := lease_next(&fx.svc, auth, Lease_Next_Input{})
	if !testing.expect(t, aok, fmt.tprintf("re-pull: %s", aerr.message)) do return
	testing.expect_value(t, again.status, "granted")
	testing.expect_value(t, again.lease.attempt_no, res.lease.attempt_no + 1)
	// many idle expiries never exhaust the budget
	for _ in 0 ..< 6 {
		fixture_advance(fx, 3600)
		coord.last_seen_at = platform.clock_now(&fx.clock)
		_, _, _ = iface.agent_save_instance(&fx.agents, coord)
		_ = fire_due(&fx.svc, now_ms(&fx.clock))
		_, _, _ = lease_next(&fx.svc, auth, Lease_Next_Input{})
	}
	final := get_task(fx, "task_1")
	testing.expect(t, final.state == .Ready || final.state == .In_Progress, fmt.tprintf("non-counting expiries never park the task (state %v)", final.state))
}

@(test)
test_solo_self_review_refused_and_request_changes_needs_reason :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "solo_review")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := solo_chain(t, fx, "chain_solo_review")
	_ = publish_solo_task(t, fx, chain, "task_1", brief = `{"goal":"g","review_roles":[]}`)
	auth := inst_auth("inst_coord")
	res, nok, _ := lease_next(&fx.svc, auth, Lease_Next_Input{})
	if !testing.expect(t, nok && res.status == "granted", "pulled") do return
	_, sok, serr := lease_submit(&fx.svc, auth, Submit_Input{summary = "done", vcs_json = GREEN_VCS})
	if !testing.expect(t, sok, fmt.tprintf("submit: %s", serr.message)) do return
	// the soloist cannot approve on the user's behalf (REQ-SOLO-5)
	_, rok, rerr := review_post(&fx.svc, auth, Review_Input{task_id = "task_1", verdict = "approve", on_behalf_of = "user"})
	testing.expect(t, !rok && rerr.code == .Forbidden && strings.contains(rerr.details_json, "solo_self_review"), "solo self-review → 403")
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.In_Review)
	// REQ-SOLO-8: request_changes needs a summary or findings (agent and user)
	_, aok, aerr := review_post(&fx.svc, auth, Review_Input{task_id = "task_1", verdict = "request_changes"})
	testing.expect(t, !aok && aerr.code == .Validation_Failed, "agent request_changes without a reason → 400")
	_, uok, uerr := user_review(&fx.svc, user_auth(), "task_1", Review_Input{verdict = "request_changes", findings_json = "[]"})
	testing.expect(t, !uok && uerr.code == .Validation_Failed, "user request_changes without a reason → 400")
	// with a reason the task goes back to ready for the next pull
	_, cok, cerr := user_review(&fx.svc, user_auth(), "task_1", Review_Input{verdict = "request_changes", summary = "rename x"})
	testing.expect(t, cok, fmt.tprintf("request changes: %s", cerr.message))
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.Ready)
}

@(test)
test_implicit_solo_worker_row :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "solo_implicit")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_solo_implicit")
	// agt_c is an ordinary agent: no implicit row
	_, has := implicit_solo_worker(&fx.svc, chain, nil)
	testing.expect(t, !has, "an ordinary coordinator has no implicit row")
	// make agt_c the built-in Soloist
	ag, aok, _ := iface.agent_get(&fx.agents, "agt_c")
	if !testing.expect(t, aok, "agent") do return
	ag.slug = SOLOIST_AGENT_SLUG
	ag.updated_at = platform.clock_now(&fx.clock)
	_, _, _ = iface.agent_save(&fx.agents, ag)
	testing.expect(t, chain_is_solo(&fx.svc, chain), "the Soloist coordinator is solo without a fleet row")
	row, implicit := implicit_solo_worker(&fx.svc, chain, nil)
	testing.expect(t, implicit && row.agent_id == "agt_c" && fleet_row_has_role(row, domain.FLEET_ROLE_WORKER), "implicit worker row for the Soloist")
	// a stored row for its agent replaces the implicit one
	stored := []domain.Task_Chain_Fleet{{task_chain_id = chain.chain_id, agent_id = "agt_c", roles_json = `["worker","reviewer"]`}}
	_, dup := implicit_solo_worker(&fx.svc, chain, stored)
	testing.expect(t, !dup, "no implicit row when the agent has a stored row")
	_, nilsvc := implicit_solo_worker(nil, chain, nil)
	testing.expect(t, !nilsvc, "nil service → none")
}
