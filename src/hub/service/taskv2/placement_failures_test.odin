package taskv2

import "core:strings"
import "core:fmt"
import "core:os"
import sqlite "odin_test:hub/repository/sqlite"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import jsonx "odin_test:lib/jsonx"

placement_body :: proc(fx: ^Fixture, id: string) -> string {
	task := get_task(fx, id)
	f, ok := get_facet(&fx.svc, task, task.attempt_no, FACET_PLACEMENT)
	return f.body_json if ok else placement_snapshot_json(nil)
}

placement_count :: proc(fx: ^Fixture, id: string) -> int {
	raw, _ := jsonx.extract_raw_array(placement_body(fx, id), "failures", true, context.temp_allocator)
	return len(jsonx_top_level_array_items(raw))
}

@(test)
test_placement_worker_offline_is_durable_idempotent_and_recovers :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "place_worker")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_place_worker")
	seed_fleet(fx, chain, "agt_w", bridge_id = "br_1")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	set_bridge_status(fx, "br_1", false)
	task := publish_task(t, fx, chain, "task_place_worker", bridge_pin = "br_1")
	testing.expect(t, task.state == .Ready && task.blocked_on_json == "", "placement failure leaves business state ready")
	testing.expect_value(t, task.attempt_no, 0)
	testing.expect_value(t, count_events(fx, string(task.task_id), EV_BLOCKED), 0)
	facet, found := get_facet(&fx.svc, task, 0, FACET_PLACEMENT)
	testing.expect(t, found && facet.writer == FACET_WRITER_HUB, "durable hub snapshot at pre-grant attempt")
	for part in ([]string{`"phase":"work"`, `"role":"worker"`, `"agent_id":"agt_w"`, `"bridge_id":"br_1"`, `"source":"task"`, `"reason":"bridge_offline"`, `"fingerprint":`}) {
		testing.expect(t, strings.contains(facet.body_json, part), part)
	}
	fixture_advance(fx, 17) // elapsed time alone cannot change identity or version
	_, rok, _ := task_recheck(&fx.svc, task, actor_from_auth(user_auth()))
	testing.expect(t, rok, "recheck")
	again, _ := get_facet(&fx.svc, task, 0, FACET_PLACEMENT)
	testing.expect_value(t, again.v, facet.v)
	testing.expect_value(t, again.body_json, facet.body_json)
	other_owner, _ := iface.taskchain_list_facets_by_task(&fx.repo, task.task_id, "someone_else")
	testing.expect_value(t, len(other_owner), 0)
	attempts, _ := iface.taskchain_list_attempts_by_task(&fx.repo, task.task_id, "u1")
	testing.expect_value(t, len(attempts), 0)
	set_bridge_status(fx, "br_1", true)
	on_bridge_hello(&fx.svc, "br_1", nil)
	lease, held := lease_of(fx, "inst_w1")
	testing.expect(t, held && lease.attempt_no == 1, "reconnect dispatches once through native matcher")
	testing.expect_value(t, placement_count(fx, string(task.task_id)), 0)
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "placement worker")
}

@(test)
test_placement_parallel_reviews_preserve_live_lease_and_verdict :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "place_reviews")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_place_reviews")
	seed_bridge(fx, "br_off", false)
	for id in ([]string{"agt_a", "agt_b", "agt_c_review", "agt_d"}) do seed_agent(fx, id)
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_fleet(fx, chain, "agt_a", roles = `["reviewer"]`, bridge_id = "br_1")
	seed_fleet(fx, chain, "agt_b", roles = `["reviewer","security"]`, bridge_id = "br_off")
	seed_fleet(fx, chain, "agt_c_review", roles = `["reviewer"]`, bridge_id = "br_1")
	seed_fleet(fx, chain, "agt_d", roles = `["reviewer"]`, bridge_id = "br_off")
	seed_instance(fx, chain, "inst_a", "agt_a", "br_1", "idle")
	seed_instance(fx, chain, "inst_b", "agt_b", "br_off", "idle")
	seed_instance(fx, chain, "inst_c", "agt_c_review", "br_1", "idle")
	seed_instance(fx, chain, "inst_d", "agt_d", "br_off", "idle")
	task := publish_task(t, fx, chain, "task_place_reviews", brief = `{"goal":"g","review_roles":["reviewer","security"],"reviewers":["agt_b"]}`, bridge_pin = "br_1")
	confirm_holder(fx, "inst_w1")
	_, submitted, _ := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "ready", vcs_json = `{"head":"h","dirty":false}`})
	if !testing.expect(t, submitted, "submit") do return
	lease_a, held := lease_of(fx, "inst_a")
	testing.expect(t, held, "first reviewer active")
	_, reviewed, _ := review_post(&fx.svc, inst_auth("inst_c"), Review_Input{verdict = "approve"})
	if !testing.expect(t, reviewed, "third reviewer approved") do return
	before, _ := iface.taskchain_list_reviews_by_task(&fx.repo, task.task_id, "u1")
	task = get_task(fx, string(task.task_id))
	testing.expect(t, task.state == .In_Review && task.blocked_on_json == "", "parallel failures cannot block review")
	testing.expect_value(t, placement_count(fx, string(task.task_id)), 4) // b: named/reviewer/security, d: reviewer
	body := placement_body(fx, string(task.task_id))
	testing.expect(t, strings.contains(body, `"bridge_id":"br_off"`) && strings.contains(body, `"source":"fleet"`), "review uses fleet bridge, never task pin")
	testing.expect(t, !strings.contains(body, `"agent_id":"agt_a"`) && !strings.contains(body, `"agent_id":"agt_c_review"`), "active and approved targets excluded")
	// Repair only b: d stays offline; a's lease and c's verdict survive.
	fleets, _ := iface.taskchain_list_fleets_by_chain(&fx.repo, chain.chain_id, "u1")
	for &f in fleets {
		if f.agent_id != "agt_b" do continue
		f.bridge_id = "br_1"
		_, _ = iface.taskchain_upsert_fleet(&fx.repo, f)
	}
	seed_instance(fx, chain, "inst_b_fixed", "agt_b", "br_1", "idle")
	testing.expect_value(t, fleet_changed(&fx.svc, chain, "agt_b").code, domain.Error_Code.None)
	testing.expect_value(t, placement_count(fx, string(task.task_id)), 1)
	after_a, held_a := lease_of(fx, "inst_a")
	testing.expect(t, held_a && after_a.lease_id == lease_a.lease_id, "other live review untouched")
	after, _ := iface.taskchain_list_reviews_by_task(&fx.repo, task.task_id, "u1")
	testing.expect(t, len(after) == len(before) && after[0].verdict == before[0].verdict, "completed verdict preserved")
	set_bridge_status(fx, "br_off", true)
	on_bridge_hello(&fx.svc, "br_off", nil)
	testing.expect_value(t, placement_count(fx, string(task.task_id)), 0)
	testing.expect(t, get_task(fx, string(task.task_id)).state == .In_Review, "still in review")
	testing.expect_value(t, get_task(fx, string(task.task_id)).attempt_no, 1)
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "placement review")
}

@(test)
test_placement_missing_workspace_and_configuration_fingerprint :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "place_missing")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_place_missing")
	seed_fleet(fx, chain, "agt_w", bridge_id = "br_missing")
	task := publish_task(t, fx, chain, "task_place_missing")
	testing.expect(t, strings.contains(placement_body(fx, string(task.task_id)), `"reason":"bridge_missing"`), "missing bridge distinct from offline")
	before := placement_body(fx, string(task.task_id))
	seed_bridge(fx, "br_missing")
	seed_directory(fx, chain, "dir_1", "br_1")
	_, rok, _ := task_recheck(&fx.svc, task, actor_from_auth(user_auth()))
	testing.expect(t, rok, "recheck")
	after := placement_body(fx, string(task.task_id))
	testing.expect(t, strings.contains(after, `"reason":"workspace_missing"`) && before != after, "workspace failure and fingerprint change")
	// Facets obey the native transaction rollback boundary.
	u, uok, _ := begin_uow(&fx.svc)
	if !testing.expect(t, uok, "begin") do return
	_, _ = save_facet_verbatim(&fx.svc, task, task.attempt_no, FACET_PLACEMENT, placement_snapshot_json(nil), FACET_WRITER_HUB, &u)
	_, _ = end_uow(&fx.svc, &u, false)
	testing.expect_value(t, placement_body(fx, string(task.task_id)), after)
}

@(test)
test_placement_capacity_and_pauses_do_not_report_offline :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "place_capacity")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_place_capacity")
	seed_fleet(fx, chain, "agt_w", bridge_id = "br_1")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_place_held")
	set_bridge_status(fx, "br_1", false)
	_ = publish_task(t, fx, chain, "task_place_queued")
	testing.expect_value(t, placement_count(fx, "task_place_queued"), 0)
	fleets, _ := iface.taskchain_list_fleets_by_chain(&fx.repo, chain.chain_id, "u1")
	fleets[0].paused_roles_json = `["worker"]`
	_, _ = iface.taskchain_upsert_fleet(&fx.repo, fleets[0])
	_ = publish_task(t, fx, chain, "task_place_paused")
	testing.expect_value(t, placement_count(fx, "task_place_paused"), 0)
	// An idle bridge event has no terminal instance callback; snapshot it
	// directly without revoking the existing work lease.
	on_bridge_placement_changed(&fx.svc)
	_, held := lease_of(fx, "inst_w1")
	testing.expect(t, held, "disconnect diagnosis preserves lease")
	testing.expect_value(t, placement_count(fx, "task_place_queued"), 0)
}

@(test)
test_placement_missing_named_reviewer_and_requirement_repair :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "place_named")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_place_named")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_fleet(fx, chain, "agt_r", roles = `["named-reviewer"]`, bridge_id = "br_absent")
	task := publish_task(t, fx, chain, "task_place_named", brief = `{"goal":"g","reviewers":["agt_r"]}`)
	confirm_holder(fx, "inst_w1")
	_, submitted, _ := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "ready", vcs_json = `{"head":"h","dirty":false}`})
	if !testing.expect(t, submitted, "submit") do return
	testing.expect_value(t, placement_count(fx, string(task.task_id)), 1)
	_, _ = iface.taskchain_delete_fleet(&fx.repo, chain.chain_id, "agt_r", "u1")
	testing.expect_value(t, fleet_changed(&fx.svc, chain).code, domain.Error_Code.None)
	testing.expect(t, strings.contains(placement_body(fx, string(task.task_id)), `"reason":"reviewer_missing"`), "named identity still owed without a fleet row")
	// Removing this requirement clears only placement; user approval remains owed.
	task = get_task(fx, string(task.task_id))
	task.brief_json = `{"goal":"g","reviewers":[]}`
	task.requires_user_approval = true
	_, _, _ = iface.taskchain_save_task(&fx.repo, task)
	testing.expect_value(t, task_updated(&fx.svc, task, actor_from_auth(user_auth()), []string{"reviewers", "requires_user_approval"}).code, domain.Error_Code.None)
	testing.expect_value(t, placement_count(fx, string(task.task_id)), 0)
	testing.expect(t, get_task(fx, string(task.task_id)).state == .In_Review && get_task(fx, string(task.task_id)).requires_user_approval, "existing user approval survives")
	task = get_task(fx, string(task.task_id))
	task.brief_json = `{"goal":"g","reviewers":["agt_r"]}`
	_, _, _ = iface.taskchain_save_task(&fx.repo, task)
	testing.expect_value(t, task_updated(&fx.svc, task, actor_from_auth(user_auth()), []string{"reviewers"}).code, domain.Error_Code.None)
	testing.expect_value(t, placement_count(fx, string(task.task_id)), 1)
	// Restore the row and placement; the ordinary matcher grants the review.
	seed_fleet(fx, chain, "agt_r", roles = `["named-reviewer"]`, bridge_id = "br_1")
	seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "idle")
	testing.expect_value(t, fleet_changed(&fx.svc, chain).code, domain.Error_Code.None)
	lease, held := lease_of(fx, "inst_r1")
	testing.expect(t, held && lease.kind == domain.LEASE_KIND_REVIEW, "repair grants review")
	testing.expect_value(t, placement_count(fx, string(task.task_id)), 0)
}

@(test)
test_placement_holds_dependencies_and_backoff_exclude_failures :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "place_waits")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_place_waits")
	seed_fleet(fx, chain, "agt_w", bridge_id = "br_1")
	set_bridge_status(fx, "br_1", false)
	task := publish_task(t, fx, chain, "task_place_waits")
	testing.expect_value(t, placement_count(fx, string(task.task_id)), 1)
	_, held, _ := task_hold(&fx.svc, task, actor_from_auth(user_auth()), "intentional hold")
	testing.expect(t, held, "hold")
	testing.expect_value(t, placement_count(fx, string(task.task_id)), 0)
	_, released, _ := task_release(&fx.svc, get_task(fx, string(task.task_id)), actor_from_auth(user_auth()))
	testing.expect(t, released, "release")
	testing.expect_value(t, placement_count(fx, string(task.task_id)), 1)
	inst := seed_instance(fx, chain, "inst_retry", "agt_w", "br_1", "failed")
	inst.stopped_at = platform.clock_now(&fx.clock)
	inst.last_error_json = `{"code":"bridge_busy","class":"retriable","message":"retry","retry_after_ms":900000,"attempt":1}`
	_, _, _ = iface.agent_save_instance(&fx.agents, inst)
	on_bridge_placement_changed(&fx.svc)
	testing.expect_value(t, placement_count(fx, string(task.task_id)), 0)
	_, has_lease := lease_of(fx, "inst_retry")
	testing.expect(t, !has_lease && get_task(fx, string(task.task_id)).attempt_no == 0, "read-only diagnosis never starts retry")
	// A separate worker lacks a placement, but dependencies are the first wait.
	seed_agent(fx, "agt_other")
	seed_fleet(fx, chain, "agt_other", bridge_id = "br_absent")
	dependent := publish_task(t, fx, chain, "task_place_dep", brief = `{"goal":"g","assignee":"agt_other"}`)
	_, added, err := work_dependency_add(&fx.svc, "u1", actor_from_auth(user_auth()), chain.chain_id, domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK, id = string(dependent.task_id)}, domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK, id = string(task.task_id)})
	testing.expect(t, added && err.code == .None, "add dependency")
	testing.expect_value(t, placement_count(fx, string(dependent.task_id)), 0)
}

@(test)
test_placement_unresolved_and_ineligible_bridge_clear_on_task_edit :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "place_eligibility")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_chain(t, fx, "chain_place_eligibility", true)
	seed_agent(fx, "agt_w")
	seed_fleet(fx, chain, "agt_w")
	task := publish_task(t, fx, chain, "task_place_eligibility")
	testing.expect(t, strings.contains(placement_body(fx, string(task.task_id)), `"reason":"placement_missing"`), "no fallback placement")
	seed_bridge(fx, "br_1")
	testing.expect(t, exec_ok(t, fx, "UPDATE bridges SET plan_disabled_at = '2026-01-01T00:00:00Z' WHERE bridge_id = 'br_1';"), "fixture disables bridge through plan-owned column")
	task = get_task(fx, string(task.task_id))
	task.bridge_id = "br_1"
	_, _, _ = iface.taskchain_save_task(&fx.repo, task)
	testing.expect_value(t, task_updated(&fx.svc, task, actor_from_auth(user_auth()), []string{"bridge_id"}).code, domain.Error_Code.None)
	testing.expect(t, strings.contains(placement_body(fx, string(task.task_id)), `"reason":"bridge_ineligible"`), "disabled bridge is ineligible")
	testing.expect(t, exec_ok(t, fx, "UPDATE bridges SET plan_disabled_at = '' WHERE bridge_id = 'br_1';"), "fixture repairs plan-owned column")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_, _, _ = iface.agent_save_support(&fx.agents, domain.Agent_Bridge_Support{agent_id = "agt_w", bridge_id = "br_1", owner_user_id = "u1", enabled = false})
	_, checked, _ := task_recheck(&fx.svc, get_task(fx, string(task.task_id)), actor_from_auth(user_auth()))
	testing.expect(t, checked && strings.contains(placement_body(fx, string(task.task_id)), "agent is disabled"), "agent bridge support is a placement eligibility failure")
	_, _, _ = iface.agent_save_support(&fx.agents, domain.Agent_Bridge_Support{agent_id = "agt_w", bridge_id = "br_1", owner_user_id = "u1", enabled = true})
	_, rok, _ := task_recheck(&fx.svc, get_task(fx, string(task.task_id)), actor_from_auth(user_auth()))
	testing.expect(t, rok, "repair recheck")
	testing.expect_value(t, placement_count(fx, string(task.task_id)), 0)
	_, leased := lease_of(fx, "inst_w1")
	testing.expect(t, leased, "valid task placement dispatches")
}

@(test)
test_placement_snapshot_survives_database_and_engine_reload :: proc(t: ^testing.T) {
	dir := os.get_env("TMPDIR", context.temp_allocator)
	if dir == "" do dir = os.get_env("TEMP", context.temp_allocator)
	if !testing.expect(t, dir != "", "scratch directory available") do return
	path := fmt.tprintf("%s/ham_placement_reload_%d.db", dir, os.get_pid())
	defer {
		os.remove(path)
		os.remove(fmt.tprintf("%s-journal", path))
		os.remove(fmt.tprintf("%s-wal", path))
		os.remove(fmt.tprintf("%s-shm", path))
	}
	fx := new(Fixture)
	conn, opened, err := sqlite.open(path)
	if !testing.expect(t, opened, err.message) do return
	fx.conn = conn
	defer fixture_close(fx)
	if !fixture_clone_migrated_into(t, &fx.conn) do return
	fixture_wire(fx)
	chain := seed_live_chain(t, fx, "chain_place_reload")
	seed_fleet(fx, chain, "agt_w", bridge_id = "br_1")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	set_bridge_status(fx, "br_1", false)
	task := publish_task(t, fx, chain, "task_place_reload")
	before, exists := get_facet(&fx.svc, task, 0, FACET_PLACEMENT)
	if !testing.expect(t, exists, "snapshot saved before first attempt") do return
	sqlite.close(&fx.conn)
	reopened, reopen_ok, reopen_err := sqlite.open(path)
	if !testing.expect(t, reopen_ok, reopen_err.message) do return
	fx.conn = reopened
	fixture_wire(fx)
	reloaded := get_task(fx, string(task.task_id))
	after, found := get_facet(&fx.svc, reloaded, 0, FACET_PLACEMENT)
	testing.expect(t, found && after.body_json == before.body_json && after.v == before.v, "durable identity survives new connection and service")
	on_bridge_placement_changed(&fx.svc)
	unchanged, _ := get_facet(&fx.svc, reloaded, 0, FACET_PLACEMENT)
	testing.expect_value(t, unchanged.v, before.v)
	set_bridge_status(fx, "br_1", true)
	on_bridge_hello(&fx.svc, "br_1", nil)
	testing.expect_value(t, placement_count(fx, string(task.task_id)), 0)
	lease, held := lease_of(fx, "inst_w1")
	testing.expect(t, held && lease.attempt_no == 1, "native reconnect recovers after reload")
}
