package taskv2

import "core:fmt"
import "core:testing"
import domain "odin_test:hub/domain"
import dbt "odin_test:hub/platform/dbtelemetry"
import iface "odin_test:hub/repository/iface"

// F1: after_chain_change reads the chain's fold events once and refolds only
// the dirty set. Equivalence with a full refold over the whole suite is checked
// by building it with -define:TASKV2_FOLD_VERIFY=true (fold_cache.odin).

// Comments are audit only: excluded from the fold read, never refold anything,
// and still listed in the task's history.
@(test)
test_fold_events_exclude_comments :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "f1_comments")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_fc")
	a := publish_task(t, fx, chain, "task_a")
	before := get_task(fx, "task_a")
	actor := Actor{kind = ACTOR_USER, id = "u1"}
	testing.expect(t, task_comment(&fx.svc, a, actor, "cmt_1").code == .None, "comment a")
	after := get_task(fx, "task_a")
	testing.expect(t, after.state == before.state && after.updated_at == before.updated_at, "a comment does not refold the task")
	all, _ := iface.taskchain_list_events_by_task(&fx.repo, a.task_id, "u1")
	fold, ferr := iface.taskchain_list_fold_events_by_chain(&fx.repo, chain.chain_id, "u1")
	testing.expect(t, ferr.code == .None, "fold read")
	has_comment := false
	for e in all do if e.kind == EV_COMMENT do has_comment = true
	testing.expect(t, has_comment, "comment history stays readable")
	for e in fold do testing.expect(t, e.kind != EV_COMMENT, "fold read carries no comments")
	testing.expect_value(t, len(fold), len(all) - 1)
	// the per-task fallback filters them the same way
	evs, _ := task_fold_events(&fx.svc, a)
	testing.expect_value(t, len(evs), len(all) - 1)
}

// While after_chain_change runs, events appended in it are visible to the next
// fold without a re-read, and a rolled-back nested unit drops the cache.
@(test)
test_fold_cache_tracks_appends :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "f1_appends")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_fa")
	a := publish_task(t, fx, chain, "task_a")
	cache: Chain_Fold_Cache
	active, prev := fold_cache_begin(&cache, chain.chain_id, "u1")
	defer fold_cache_end(active, prev)
	evs, _ := task_fold_events(&fx.svc, a)
	n := len(evs)
	testing.expect(t, cache.loaded, "one batched read")
	_, aok, _ := append_event(&fx.repo, &fx.clock, a, hub_actor(), EV_HELD, `{"reason":"x"}`)
	testing.expect(t, aok, "append")
	_, _, _ = append_event(&fx.repo, &fx.clock, a, hub_actor(), EV_COMMENT, `{"comment_id":"c"}`)
	evs, _ = task_fold_events(&fx.svc, a)
	testing.expect_value(t, len(evs), n + 1)
	testing.expect_value(t, evs[len(evs) - 1].kind, EV_HELD)
	fold_cache_invalidate()
	testing.expect(t, !cache.loaded, "invalidated")
	evs, _ = task_fold_events(&fx.svc, a)
	testing.expect_value(t, len(evs), n + 1)
}

// ---- benchmark (opt-in) ----------------------------------------------------------
// Telemetry mode is process-global, so this runs alone:
//   odin build src/hub/service/taskv2 -build-mode:test -collection:odin_test=src \
//     -define:TASKV2_BENCH=true -define:ODIN_TEST_THREADS=1 -out:<bin>
//   <bin> -tests:test_bench_lease_submit_250_task_chain

BENCH :: #config(TASKV2_BENCH, false)
BENCH_TASKS :: 250

@(test)
test_bench_lease_submit_250_task_chain :: proc(t: ^testing.T) {
	when !BENCH do return
	dbt.set_mode(.Basic)
	defer dbt.set_mode(.Off)
	fx, log, ok := lease_fixture(t, "f1_bench")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_bench")
	actor := Actor{kind = ACTOR_USER, id = "u1"}
	// 250 tickets; every fifth depends on the one before it; three comments each.
	for i in 0..<BENCH_TASKS {
		id := fmt.aprintf("task_%03d", i)
		task := publish_task(t, fx, chain, id)
		for c in 0..<3 do _ = task_comment(&fx.svc, task, actor, fmt.tprintf("cmt_%d_%d", i, c))
		if i % 5 == 4 {
			prev := fmt.tprintf("task_%03d", i - 1)
			_, _, _ = work_dependency_add(&fx.svc, "u1", actor, chain.chain_id, domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK, id = id}, domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK, id = prev})
		}
	}
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = fleet_changed(&fx.svc, chain)
	confirm_holder(fx, "inst_w1")
	lease, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held, "leased") do return
	dbt.scope_begin(.Http)
	_, sok, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{lease_id = lease.lease_id, summary = "bench", vcs_json = `{"head":"h","dirty":false}`})
	totals, _ := dbt.scope_end()
	testing.expect(t, sok, fmt.tprintf("submit: %s", serr.message))
	fmt.printf("BENCH lease_submit N=%d statements=%d tx_hold_ns=%d elapsed_ns=%d", BENCH_TASKS, totals.statements, totals.tx_hold_ns, totals.elapsed_ns)
	for p in dbt.Phase {
		pt := totals.phase[p]
		if pt.calls > 0 do fmt.printf(" %s=%d/%dns/x%d", dbt.PHASE_LABELS[p], pt.statements, pt.ns, pt.calls)
	}
	fmt.println()
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "bench")
}
