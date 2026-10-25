package taskv2

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// REQ-TV2-3 (T6): reviewer lifecycle (O7), dependency readiness with a pending
// merge (O2) and chain completion errors / merge snapshot at Done (O15).

// O7: a reviewer that approves one task while it still owes another must not
// be stopped, even when the matcher cannot re-grant it right now (its bridge
// dropped); once the owed review is granted and posted it is stopped.
@(test)
test_review_post_keeps_reviewer_that_still_owes :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "t6_o7")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_o7")
	seed_fleet(fx, chain, "agt_w", capacity = 2)
	seed_fleet(fx, chain, "agt_r", roles = `["reviewer"]`)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_w2", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "idle")
	brief := `{"goal":"g","acceptance":["a"],"review_roles":["reviewer"]}`
	_ = publish_task(t, fx, chain, "task_1", brief = brief)
	_ = publish_task(t, fx, chain, "task_2", brief = brief)
	confirm_holder(fx, "inst_w1")
	confirm_holder(fx, "inst_w2")
	_, s1, e1 := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "one", vcs_json = `{"head":"h1","dirty":false}`})
	_, s2, e2 := lease_submit(&fx.svc, inst_auth("inst_w2"), Submit_Input{summary = "two", vcs_json = `{"head":"h2","dirty":false}`})
	if !testing.expect(t, s1 && s2, fmt.tprintf("submits: %s / %s", e1.message, e2.message)) do return
	first, held := lease_of(fx, "inst_r1")
	if !testing.expect(t, held, "the single reviewer holds one review lease") do return
	other := "task_2" if string(first.task_id) == "task_1" else "task_1"
	// the bridge drops: the matcher cannot re-grant the owed review this UoW
	set_bridge_status(fx, "br_1", false)
	wake_log_reset(log)
	res, rok, rerr := review_post(&fx.svc, inst_auth("inst_r1"), Review_Input{verdict = "approve", findings_json = "[]"})
	if !testing.expect(t, rok, fmt.tprintf("review: %s", rerr.message)) do return
	testing.expect_value(t, res.gate, Gate_Result.Approved)
	_, regranted := lease_of(fx, "inst_r1")
	testing.expect(t, !regranted, "nothing granted while the bridge is down")
	testing.expect(t, !wake_log_has_stop(log, "inst_r1"), "a reviewer that still owes a review is not stopped")
	// the bridge returns: the owed review is granted to the same reviewer
	set_bridge_status(fx, "br_1", true)
	fixture_advance(fx, REMATCH_DELAYS_SECONDS[2] + 1)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	next, still := lease_of(fx, "inst_r1")
	if !testing.expect(t, still && string(next.task_id) == other, "the owed review is re-granted") do return
	confirm_holder(fx, "inst_r1")
	// last review: nothing is owed any more, so now it is stopped
	wake_log_reset(log)
	_, lok, lerr := review_post(&fx.svc, inst_auth("inst_r1"), Review_Input{verdict = "approve", findings_json = "[]"})
	testing.expect(t, lok, fmt.tprintf("second review: %s", lerr.message))
	testing.expect(t, wake_log_has_stop(log, "inst_r1"), "a reviewer owing nothing is stopped")
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.Done)
	testing.expect_value(t, get_task(fx, "task_2").state, domain.Task_State.Done)
}

// REQ-TV2-3a: a waiting gate reports why it did not advance.
@(test)
test_review_post_waiting_lists_unmet :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "t6_unmet")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_unmet")
	seed_agent(fx, "agt_r2")
	seed_fleet(fx, chain, "agt_w")
	seed_fleet(fx, chain, "agt_r", roles = `["reviewer"]`)
	seed_fleet(fx, chain, "agt_r2", roles = `["reviewer"]`)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "idle")
	seed_instance(fx, chain, "inst_r2", "agt_r2", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"review_roles":["reviewer"]}`)
	t_row := get_task(fx, "task_1")
	t_row.requires_user_approval = true
	_, _, _ = iface.taskchain_save_task(&fx.repo, t_row)
	confirm_holder(fx, "inst_w1")
	_, sok, _ := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "v1", vcs_json = `{"head":"h1","dirty":false}`})
	if !testing.expect(t, sok, "submit") do return
	res, rok, rerr := review_post(&fx.svc, inst_auth("inst_r1"), Review_Input{verdict = "approve", findings_json = "[]"})
	if !testing.expect(t, rok, fmt.tprintf("review: %s", rerr.message)) do return
	testing.expect_value(t, res.gate, Gate_Result.Waiting)
	body := gate_unmet_json(res.unmet)
	testing.expect(t, strings.contains(body, `"agent_id":"agt_r2"`) && strings.contains(body, `"role":"reviewer"`), fmt.tprintf("missing r2 vote named: %s", body))
	testing.expect(t, strings.contains(body, `"kind":"user_approval"`), "missing user approval named")
	testing.expect(t, !strings.contains(body, `"agent_id":"agt_r"}`), "the approving reviewer is not unmet")
	// r2 still owes the task: it keeps its lease
	_, r2 := lease_of(fx, "inst_r2")
	testing.expect(t, r2, "the remaining reviewer holds its review lease")
}

// O2 + O15: a Done prerequisite whose merge is pending keeps the dependent
// backlogged; the engine and the wire predicate agree, and chain completion
// names both tickets with their state and merge state.
@(test)
test_pending_merge_readiness_agrees_and_completion_names_tickets :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "t6_o2")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_o2")
	seed_directory(fx, chain, "dir_git", "br_1", "git")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	a := publish_task(t, fx, chain, "task_a")
	b := publish_task(t, fx, chain, "task_b")
	testing.expect_value(t, a.state, domain.Task_State.In_Progress)
	testing.expect_value(t, b.state, domain.Task_State.Ready)
	_, added, aerr := work_dependency_add(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, chain.chain_id,
		domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK, id = "task_b"},
		domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK, id = "task_a"})
	if !testing.expect(t, added, fmt.tprintf("edge b→a: %s", aerr.message)) do return
	testing.expect_value(t, get_task(fx, "task_b").state, domain.Task_State.Backlog)
	confirm_holder(fx, "inst_w1")
	_, sok, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "a", vcs_json = `{"head":"ha","dirty":false}`})
	if !testing.expect(t, sok, fmt.tprintf("submit a: %s", serr.message)) do return
	done_a := get_task(fx, "task_a")
	testing.expect_value(t, done_a.state, domain.Task_State.Done)
	testing.expect_value(t, task_merge_status(&fx.svc, done_a).state, "pending")
	// engine: b stays backlog and is not granted; wire predicate: blocked, and a
	// does not unblock dependents while its merge is pending
	now_b := get_task(fx, "task_b")
	testing.expect_value(t, now_b.state, domain.Task_State.Backlog)
	ready, rerr := task_dependencies_ready(&fx.svc, now_b)
	testing.expect(t, rerr.code == .None && !ready, "wire predicate agrees: b is blocked")
	testing.expect(t, !task_unblocks_dependents(&fx.svc, done_a), "Done with pending merge does not unblock")
	// `task readiness` explains the stall: the edge, the prerequisite's state
	// and merge state, and why it is unsatisfied
	explain, xerr := task_readiness_json(&fx.svc, now_b)
	testing.expect(t, xerr.code == .None && strings.contains(explain, `"ready":false`), fmt.tprintf("readiness: %s", explain))
	testing.expect(t, strings.contains(explain, `"edge":"work_dependency"`) && strings.contains(explain, `"id":"task_a"`) && strings.contains(explain, `"state":"done"`) && strings.contains(explain, `"merge":"pending"`) && strings.contains(explain, `"satisfied":false`) && strings.contains(explain, `"reason":"merge_pending"`), fmt.tprintf("edge explained: %s", explain))
	// bounded delay: b waits only on a's merge → dependency_stalled names a
	testing.expect_value(t, count_events(fx, "task_b", EV_DEPENDENCY_STALLED), 0)
	fixture_advance(fx, DEPENDENCY_STALLED_SECONDS + 1)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect_value(t, count_events(fx, "task_b", EV_DEPENDENCY_STALLED), 1)
	b_evs, _ := iface.taskchain_list_events_by_task(&fx.repo, "task_b", "u1")
	for e in b_evs do if e.kind == EV_DEPENDENCY_STALLED {
		testing.expect(t, strings.contains(e.payload_json, `"prerequisite":"task_a"`) && strings.contains(e.payload_json, `"merge":"pending"`), fmt.tprintf("stall names the prerequisite: %s", e.payload_json))
	}
	// adding another directory requeues the pending merge (as bridge hello does)
	seed_directory(fx, chain, "dir_git2", "br_1", "git")
	dir2, _, _ := iface.taskchain_get_directory(&fx.repo, "dir_git2", chain.chain_id, "u1")
	u, _, _ := begin_uow(&fx.svc)
	added_ok, _ := directory_added_in_uow(&fx.svc, &u, dir2)
	queued := len(u.effects.merges)
	_, _ = end_uow(&fx.svc, &u, false)
	testing.expect(t, added_ok && queued == 1, fmt.tprintf("pending merge requeued on directory add (%d)", queued))
	// the Done-time snapshot is immutable: removing every git directory does
	// not turn the unresolved merge into `none` (no merge-gate bypass)
	_, _ = iface.taskchain_remove_directory(&fx.repo, "dir_git", chain.chain_id, "u1")
	_, _ = iface.taskchain_remove_directory(&fx.repo, "dir_git2", chain.chain_id, "u1")
	testing.expect_value(t, task_merge_status(&fx.svc, get_task(fx, "task_a")).state, "pending")
	// completion names every offending ticket, with state, merge and recovery
	fresh_chain, _, _ := iface.taskchain_get_chain(&fx.repo, chain.chain_id)
	_, completed, cerr := work_chain_complete(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, chain.chain_id, fresh_chain.work_revision, "finish")
	testing.expect(t, !completed && cerr.code == .Conflict, "completion refused")
	testing.expect(t, strings.contains(cerr.message, "task_a") && strings.contains(cerr.message, "task_b"), fmt.tprintf("message names the tickets: %s", cerr.message))
	testing.expect(t, strings.contains(cerr.details_json, `"id":"task_a"`) && strings.contains(cerr.details_json, `"merge":"pending"`) && strings.contains(cerr.details_json, `"reason":"merge_unresolved"`), fmt.tprintf("task_a detail: %s", cerr.details_json))
	testing.expect(t, strings.contains(cerr.details_json, `"id":"task_b"`) && strings.contains(cerr.details_json, `"state":"backlog"`), "task_b detail")
	testing.expect(t, strings.contains(cerr.details_json, `"action":"exclude"`) && strings.contains(cerr.details_json, `"action":"retry_merge"`) && strings.contains(cerr.details_json, `"action":"settle_merge_none"`), "recovery options listed")
	// details_json is a well-formed object (no core:fmt brace corruption)
	testing.expect(t, !strings.contains(cerr.details_json, "%!"), fmt.tprintf("no fmt corruption: %s", cerr.details_json))
	parsed, perr := json.parse_string(cerr.details_json, allocator = context.temp_allocator)
	if !testing.expect(t, perr == .None, fmt.tprintf("details parse: %v %s", perr, cerr.details_json)) do return
	obj, is_obj := parsed.(json.Object)
	if !testing.expect(t, is_obj, "details is an object") do return
	testing.expect_value(t, obj["code"].(json.String) or_else "", "chain_incomplete")
	testing.expect_value(t, len(obj["items"].(json.Array) or_else nil), 2)
	testing.expect_value(t, len(obj["recovery"].(json.Array) or_else nil), 3)
}

// Completion still needs at least one successful included item: an empty
// chain (no blockers, no leases) is refused, not marked completed.
@(test)
test_complete_empty_chain_refused :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "t6_empty")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_empty")
	fresh_chain, _, _ := iface.taskchain_get_chain(&fx.repo, chain.chain_id)
	_, completed, cerr := work_chain_complete(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, chain.chain_id, fresh_chain.work_revision, "finish")
	testing.expect(t, !completed && cerr.code == .Conflict && strings.contains(cerr.message, "at least one successful"), fmt.tprintf("empty chain refused: %v %s", completed, cerr.message))
}

// O15: a git directory added (or switched to git) AFTER a ticket reached Done
// never makes it merge-pending (immutable snapshot at Done), so it stays `none`.
@(test)
test_directory_added_after_done_is_not_pending :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "t6_o15")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_o15")
	seed_directory(fx, chain, "dir_plain", "br_1", "")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_a")
	confirm_holder(fx, "inst_w1")
	_, sok, _ := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "a", vcs_json = `{"head":"ha","dirty":false}`})
	if !testing.expect(t, sok, "submit") do return
	testing.expect_value(t, task_merge_status(&fx.svc, get_task(fx, "task_a")).state, "none")
	// same second as Done: a late git directory and a pre-Done non-git
	// directory switched to git both leave the snapshot (none) unchanged
	seed_directory(fx, chain, "dir_late", "br_1", "git")
	seed_directory(fx, chain, "dir_plain", "br_1", "git")
	done_a := get_task(fx, "task_a")
	testing.expect_value(t, task_merge_status(&fx.svc, done_a).state, "none")
	testing.expect(t, task_unblocks_dependents(&fx.svc, done_a), "still unblocks dependents")
	// the add refolds without queuing a merge for the pre-directory ticket
	late, _, _ := iface.taskchain_get_directory(&fx.repo, "dir_late", chain.chain_id, "u1")
	u, _, _ := begin_uow(&fx.svc)
	added_ok, aerr := directory_added_in_uow(&fx.svc, &u, late)
	queued := len(u.effects.merges)
	_, _ = end_uow(&fx.svc, &u, false)
	testing.expect(t, added_ok, fmt.tprintf("directory_added: %s", aerr.message))
	testing.expect_value(t, queued, 0)
	fresh_chain, _, _ := iface.taskchain_get_chain(&fx.repo, chain.chain_id)
	_, completed, cerr := work_chain_complete(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, chain.chain_id, fresh_chain.work_revision, "finish")
	testing.expect(t, completed, fmt.tprintf("completes: %s %s", cerr.message, cerr.details_json))
}

// REQ-TV2-3a invariant: a gate waiting with no live lease and no owed pair
// raises review_stalled from fire_rematch, and re-arms while it holds. The
// fixture is a legacy review row whose verdict neither approves nor requests
// changes: the pair is no longer owed, yet the gate cannot pass.
@(test)
test_waiting_gate_with_nothing_owed_raises_review_stalled :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "t6_stall")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_stall")
	seed_fleet(fx, chain, "agt_w")
	seed_fleet(fx, chain, "agt_r", roles = `["reviewer"]`)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"review_roles":["reviewer"]}`)
	confirm_holder(fx, "inst_w1")
	_, sok, _ := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "v1", vcs_json = `{"head":"h1","dirty":false}`})
	if !testing.expect(t, sok, "submit") do return
	// the reviewer's lease goes away and a non-deciding row stands in its place
	if rl, held := lease_of(fx, "inst_r1"); held do _, _ = iface.taskchain_delete_lease(&fx.repo, rl.lease_id)
	task := get_task(fx, "task_1")
	_, _, _ = iface.taskchain_save_review(&fx.repo, domain.Task_Review{task_id = task.task_id, chain_id = task.chain_id, owner_user_id = "u1", attempt_no = task.attempt_no, role = "reviewer", reviewer_kind = "agent", reviewer_agent_id = "agt_r", reviewer_instance_id = "inst_r1", verdict = "comment", findings_json = "[]", created_at = task.updated_at})
	fixture_advance(fx, REMATCH_DELAYS_SECONDS[0] + 1)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect_value(t, count_events(fx, "task_1", EV_REVIEW_STALLED), 1)
	evs, _ := iface.taskchain_list_events_by_task(&fx.repo, task.task_id, "u1")
	for e in evs do if e.kind == EV_REVIEW_STALLED {
		testing.expect(t, strings.contains(e.payload_json, `"agent_id":"agt_r"`), fmt.tprintf("alert names the unmet vote: %s", e.payload_json))
	}
	// re-armed while the condition holds
	fixture_advance(fx, REVIEW_STALLED_REALERT_SECONDS + 1)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect(t, count_events(fx, "task_1", EV_REVIEW_STALLED) >= 2, "re-alerts while stalled")
}

// Failure injection for the Done-time merge snapshot (thread-local: tests run
// in parallel threads, each with its own fixture repository).
@(thread_local) snap_inject_orig_append: iface.Task_Event_Append_Proc
@(thread_local) snap_inject_fail_dirs: bool
@(thread_local) snap_inject_fail_write: bool
@(thread_local) snap_inject_orig_dirs: iface.Task_Chain_Directory_List_By_Chain_Proc

snap_inject_dirs :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Chain_Directory, domain.Domain_Error) {
	if snap_inject_fail_dirs do return nil, domain.domain_error(.Internal_Error, "injected directory read failure")
	return snap_inject_orig_dirs(ctx, chain_id, owner_user_id)
}

snap_inject_append :: proc(ctx: rawptr, event: domain.Task_Event) -> (domain.Task_Event, bool, domain.Domain_Error) {
	if snap_inject_fail_write && event.kind == EV_MERGE_SNAPSHOT do return domain.Task_Event{}, false, domain.domain_error(.Internal_Error, "injected snapshot write failure")
	return snap_inject_orig_append(ctx, event)
}

// The Done-time snapshot fails closed: when the chain's directories cannot be
// read, or the snapshot event cannot be written, the submit that would make
// the task Done is rolled back (no Done without a snapshot, and never a
// snapshot of `none` for a git-backed task). Once the repository recovers the
// same submit commits Done with a pending merge.
@(test)
test_done_merge_snapshot_fails_closed :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "t6_snapfail")
	defer lease_fixture_close(fx, log)
	if !ok do return
	snap_inject_orig_dirs = fx.repo.list_directories_by_chain
	snap_inject_orig_append = fx.repo.append_event
	fx.repo.list_directories_by_chain = snap_inject_dirs
	fx.repo.append_event = snap_inject_append
	defer {
		snap_inject_fail_dirs, snap_inject_fail_write = false, false
		fx.repo.list_directories_by_chain = snap_inject_orig_dirs
		fx.repo.append_event = snap_inject_orig_append
	}
	chain := seed_live_chain(t, fx, "chain_snapfail")
	seed_directory(fx, chain, "dir_git", "br_1", "git")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_a")
	confirm_holder(fx, "inst_w1")
	submit :: proc(fx: ^Fixture) -> (bool, domain.Domain_Error) {
		_, sok, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "a", vcs_json = `{"head":"ha","dirty":false}`})
		return sok, serr
	}
	for mode in ([]string{"dirs", "write"}) {
		snap_inject_fail_dirs, snap_inject_fail_write = mode == "dirs", mode == "write"
		sok, serr := submit(fx)
		testing.expect(t, !sok && serr.code != .None, fmt.tprintf("%s failure refuses the submit: %v", mode, sok))
		testing.expect(t, get_task(fx, "task_a").state != .Done, fmt.tprintf("%s failure: Done rolled back", mode))
		testing.expect_value(t, count_events(fx, "task_a", EV_MERGE_SNAPSHOT), 0)
		testing.expect_value(t, count_events(fx, "task_a", EV_SUBMITTED), 0)
	}
	snap_inject_fail_dirs, snap_inject_fail_write = false, false
	sok, serr := submit(fx)
	if !testing.expect(t, sok, fmt.tprintf("submit after recovery: %s", serr.message)) do return
	done_a := get_task(fx, "task_a")
	testing.expect_value(t, done_a.state, domain.Task_State.Done)
	testing.expect_value(t, count_events(fx, "task_a", EV_MERGE_SNAPSHOT), 1)
	testing.expect_value(t, task_merge_status(&fx.svc, done_a).state, "pending")
	// boot backfill of a legacy Done history (snapshot stripped) reports a
	// failed read and records nothing, so the next boot retries
	evs, _ := iface.taskchain_list_events_by_task(&fx.repo, "task_a", "u1")
	legacy := make([dynamic]domain.Task_Event, context.temp_allocator)
	for e in evs do if e.kind != EV_MERGE_SNAPSHOT do append(&legacy, e)
	snap_inject_fail_dirs = true
	berr := backfill_merge_snapshot(&fx.svc, done_a, legacy[:])
	testing.expect(t, berr.code != .None, "backfill reports the failed read")
	testing.expect_value(t, count_events(fx, "task_a", EV_MERGE_SNAPSHOT), 1)
}
