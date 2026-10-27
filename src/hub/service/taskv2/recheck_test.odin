package taskv2

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// Task re-check: recompute gate, readiness, dispatch and merge for one task
// without touching a live lease; a repeat call is a no-op.

recheck_reasons_contain :: proc(res: Recheck_Result, needle: string) -> bool {
	for r in res.reasons do if strings.contains(r, needle) do return true
	return false
}

// Motivating incident 1: user approval was turned off after every agent
// review was in, but nothing re-ran the gate. Re-check decides it.
@(test)
test_recheck_stale_gate_after_user_approval_removed_is_done :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "recheck_gate")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_rc_gate")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	task := seed_task(t, fx, chain, "task_1", `{"goal":"g","acceptance":["a"],"review_roles":[]}`)
	task.requires_user_approval = true
	_, _, _ = iface.taskchain_save_task(&fx.repo, task)
	task = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"review_roles":[]}`)
	lease, leased := lease_of(fx, "inst_w1")
	if !testing.expect(t, leased, "task_1 granted") do return
	row := get_task(fx, "task_1")
	row.requires_user_approval = true
	_, _, _ = iface.taskchain_save_task(&fx.repo, row)
	submit_via_release(t, fx, lease)
	row = get_task(fx, "task_1")
	if !testing.expect_value(t, row.state, domain.Task_State.In_Review) do return

	// The flag is dropped without a gate re-run (a stale projection).
	row.requires_user_approval = false
	_, _, _ = iface.taskchain_save_task(&fx.repo, row)
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.In_Review)

	owner := actor_from_auth(user_auth())
	res, rok, rerr := task_recheck(&fx.svc, get_task(fx, "task_1"), owner)
	if !testing.expect(t, rok, fmt.tprintf("recheck: %s", rerr.message)) do return
	testing.expect(t, res.changed, "re-check changed the task")
	testing.expect_value(t, res.task.state, domain.Task_State.Done)
	testing.expect(t, strings.contains(res.message, "in_review → done"), res.message)
	testing.expect_value(t, count_events(fx, "task_1", EV_APPROVED), 1)
	testing.expect_value(t, count_reviews(fx, "task_1"), 0)

	// Repeat: nothing left to do, nothing recorded.
	events := count_all_events(fx, "task_1")
	again, aok, _ := task_recheck(&fx.svc, get_task(fx, "task_1"), owner)
	testing.expect(t, aok && !again.changed, "repeat re-check is a no-op")
	testing.expect_value(t, count_all_events(fx, "task_1"), events)
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "recheck gate")
}

// The root cause of incident 1: task_updated now re-gates on the flag.
@(test)
test_task_updated_requires_user_approval_off_regates :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "recheck_rua_update")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_rc_rua")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	task := seed_task(t, fx, chain, "task_1", `{"goal":"g","acceptance":["a"],"review_roles":[]}`)
	task.requires_user_approval = true
	_, _, _ = iface.taskchain_save_task(&fx.repo, task)
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"review_roles":[]}`)
	row := get_task(fx, "task_1")
	row.requires_user_approval = true
	_, _, _ = iface.taskchain_save_task(&fx.repo, row)
	lease, _ := lease_of(fx, "inst_w1")
	submit_via_release(t, fx, lease)
	if !testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.In_Review) do return
	row = get_task(fx, "task_1")
	row.requires_user_approval = false
	_, _, _ = iface.taskchain_save_task(&fx.repo, row)
	err := task_updated(&fx.svc, row, actor_from_auth(user_auth()), []string{"requires_user_approval"})
	testing.expect(t, err.code == .None, err.message)
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.Done)
}

// Motivating incident 2: a ready task sat unclaimed with free fleet capacity
// because no trigger re-ran the matcher. Re-check dispatches it.
@(test)
test_recheck_ready_unclaimed_with_capacity_dispatches :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "recheck_dispatch")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_rc_disp")
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"review_roles":[]}`)
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.Ready)
	owner := actor_from_auth(user_auth())

	// No worker row yet: the reason says so and nothing changes.
	none, nok, _ := task_recheck(&fx.svc, get_task(fx, "task_1"), owner)
	testing.expect(t, nok && !none.changed, "no fleet: no change")
	testing.expect(t, recheck_reasons_contain(none, "no fleet row holds the worker role"), fmt.tprintf("%v", none.reasons))

	// A row and an instance appear without a fleet trigger (missed event).
	now := platform.clock_now(&fx.clock)
	_, _ = iface.taskchain_upsert_fleet(&fx.repo, domain.Task_Chain_Fleet{task_chain_id = chain.chain_id, agent_id = "agt_w", capacity = 2, roles_json = `["worker"]`, created_at = now, updated_at = now})
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_, leased := lease_of(fx, "inst_w1")
	testing.expect(t, !leased, "nothing re-ran the matcher yet")

	res, rok, rerr := task_recheck(&fx.svc, get_task(fx, "task_1"), owner)
	if !testing.expect(t, rok, fmt.tprintf("recheck: %s", rerr.message)) do return
	testing.expect(t, res.changed, "re-check dispatched")
	testing.expect_value(t, res.task.state, domain.Task_State.In_Progress)
	l, leased2 := lease_of(fx, "inst_w1")
	testing.expect(t, leased2 && l.task_id == "task_1", "inst_w1 holds task_1")
	testing.expect(t, strings.contains(res.message, "dispatched: work lease"), res.message)
	testing.expect(t, wake_log_has_run(log, "inst_w1"), "wake sent after commit")
}

// A full fleet row is reported with its counts; the ready task is untouched.
@(test)
test_recheck_reports_fleet_full :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "recheck_full")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_rc_full")
	seed_fleet(fx, chain, "agt_w", capacity = 1)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"review_roles":[]}`)
	_ = publish_task(t, fx, chain, "task_2", brief = `{"goal":"g","acceptance":["a"],"review_roles":[]}`)
	testing.expect_value(t, get_task(fx, "task_2").state, domain.Task_State.Ready)
	res, rok, _ := task_recheck(&fx.svc, get_task(fx, "task_2"), actor_from_auth(user_auth()))
	testing.expect(t, rok && !res.changed, "full fleet: no change")
	testing.expect(t, recheck_reasons_contain(res, "agt_w: fleet full 1/1 on bridge br_1"), fmt.tprintf("%v", res.reasons))
}

// An offline bridge is a reason, not a silent wait; when the bridge is back
// the re-check clears the bridge_offline block and dispatches.
@(test)
test_recheck_offline_bridge_reason_then_dispatch :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "recheck_offline")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_rc_off")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	set_bridge_status(fx, "br_1", false)
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"review_roles":[]}`)
	owner := actor_from_auth(user_auth())
	res, rok, rerr := task_recheck(&fx.svc, get_task(fx, "task_1"), owner)
	if !testing.expect(t, rok, fmt.tprintf("recheck: %s", rerr.message)) do return
	testing.expect(t, !res.changed, "offline: nothing to change")
	testing.expect(t, recheck_reasons_contain(res, "offline"), fmt.tprintf("%v", res.reasons))
	testing.expect(t, strings.contains(res.message, "offline"), res.message)

	// The bridge returns but its hello was missed: re-check answers the block.
	set_bridge_status(fx, "br_1", true)
	back, bok, berr := task_recheck(&fx.svc, get_task(fx, "task_1"), owner)
	if !testing.expect(t, bok, fmt.tprintf("recheck: %s", berr.message)) do return
	testing.expect(t, back.changed, "bridge back: re-check acted")
	_, leased := lease_of(fx, "inst_w1")
	testing.expect(t, leased, "dispatched once the bridge is online")
	testing.expect(t, strings.contains(back.message, "block cleared"), back.message)
}

// A leased task is left to its holder: no event, no lease change, no attempt.
@(test)
test_recheck_leaves_leased_task_untouched :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "recheck_leased")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_rc_leased")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"review_roles":[]}`)
	confirm_holder(fx, "inst_w1")
	before, leased := lease_of(fx, "inst_w1")
	if !testing.expect(t, leased, "task_1 granted") do return
	events := count_all_events(fx, "task_1")
	row := get_task(fx, "task_1")
	wake_log_reset(log)
	res, rok, rerr := task_recheck(&fx.svc, row, actor_from_auth(user_auth()))
	if !testing.expect(t, rok, fmt.tprintf("recheck: %s", rerr.message)) do return
	testing.expect(t, !res.changed, "leased: no change")
	testing.expect(t, recheck_reasons_contain(res, before.lease_id), fmt.tprintf("%v", res.reasons))
	after, still := lease_of(fx, "inst_w1")
	testing.expect(t, still && after.lease_id == before.lease_id && after.expires_at == before.expires_at, "lease untouched")
	testing.expect_value(t, count_all_events(fx, "task_1"), events)
	testing.expect_value(t, get_task(fx, "task_1").attempt_no, row.attempt_no)
	testing.expect(t, len(log.cmds) == 0, "no wake or stop sent")
}

// Only the chain owner or its coordinator may re-check.
@(test)
test_recheck_requires_owner_or_coordinator :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "recheck_authz")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_rc_authz")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	task := publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"review_roles":[]}`)
	_, wok, werr := task_recheck(&fx.svc, task, Actor{kind = ACTOR_AGENT, id = "inst_w1"})
	testing.expect(t, !wok && werr.code == .Forbidden, "a worker may not re-check")
	_, cok, cerr := task_recheck(&fx.svc, task, Actor{kind = ACTOR_AGENT, id = "inst_coord"})
	testing.expect(t, cok, fmt.tprintf("the coordinator may re-check: %s", cerr.message))
}

// Done with no git directory: merge none is explained (motivating incident 3).
@(test)
test_recheck_explains_merge_none_without_git_directory :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "recheck_merge_none")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_rc_merge")
	seed_directory(fx, chain, "dir_plain", "br_1", "")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"review_roles":[]}`)
	lease, leased := lease_of(fx, "inst_w1")
	if !testing.expect(t, leased, "task_1 granted") do return
	submit_via_release(t, fx, lease)
	if !testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.Done) do return
	res, rok, rerr := task_recheck(&fx.svc, get_task(fx, "task_1"), actor_from_auth(user_auth()))
	if !testing.expect(t, rok, fmt.tprintf("recheck: %s", rerr.message)) do return
	testing.expect(t, !res.changed, "done: nothing to change")
	testing.expect(t, recheck_reasons_contain(res, `dir_plain has vcs_kind ""`), fmt.tprintf("%v", res.reasons))
}

count_all_events :: proc(fx: ^Fixture, task_id: string) -> int {
	evs, _ := iface.taskchain_list_events_by_task(&fx.repo, domain.Task_ID(task_id), "u1")
	return len(evs)
}

count_reviews :: proc(fx: ^Fixture, task_id: string) -> int {
	reviews, _ := iface.taskchain_list_reviews_by_task(&fx.repo, domain.Task_ID(task_id), "u1")
	return len(reviews)
}
