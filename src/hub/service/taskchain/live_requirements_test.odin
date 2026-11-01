package taskchain

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import taskv2 "odin_test:hub/service/taskv2"
import jsonx "odin_test:lib/jsonx"

@(test)
test_live_requirements_history_conflict_noop_and_rollback :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f: Brief_Contract_Fixture
	if !brief_contract_open(t, &f, "live_requirements") do return
	defer brief_contract_close(&f)
	repos := iface.Repositories{taskchains = f.repo, agents = f.agents}
	impl: sqlite.SQLite_Unit_Of_Work_Factory
	factory := sqlite.new_unit_of_work_factory(&impl, &f.conn, &repos)
	set_uow_factory(&f.svc, &factory)
	task, ok, err := create_task(&f.svc, f.owner, {chain_id = f.chain.chain_id,
		title = "live requirements", brief_json = FULL_BRIEF})
	if !testing.expectf(t, ok, "create: %s", err.message) do return
	initial, ierr := taskv2.requirements_read(&f.repo, task)
	testing.expect(t, ierr.code == .None && initial.revision == 1, "legacy baseline needs no migration")
	_, lok, _ := iface.taskchain_save_lease(&f.repo, {
		lease_id = "live_lease", task_id = task.task_id, chain_id = task.chain_id,
		owner_user_id = task.owner_user_id, holder_instance_id = "worker",
		kind = domain.LEASE_KIND_WORK, attempt_no = 1,
		expires_at = "2099-01-01T00:00:00Z", hard_deadline_at = "2099-01-01T01:00:00Z"})
	if !testing.expect(t, lok) do return
	edited, eok, eerr := update_task(&f.svc, f.owner, task.task_id, {
		brief_json = `{"goal":"new objective","acceptance":["a1","Google sign-in"]}`,
		expected_requirements_revision = 1, requirements_reason = "Added provider",
		requirements_request_id = "change-one"})
	if !testing.expectf(t, eok, "live goal and acceptance edit: %s", eerr.message) do return
	state, _ := taskv2.requirements_read(&f.repo, task)
	testing.expect_value(t, state.revision, i64(2))
	events, _ := iface.taskchain_list_events_by_task(&f.repo, task.task_id, task.owner_user_id)
	changes := 0
	for event in events {
		if event.kind != taskv2.EV_REQUIREMENTS_CHANGED do continue
		changes += 1
		testing.expect(t, strings.contains(event.payload_json, "original goal") &&
			strings.contains(event.payload_json, "new objective"), "before/after retained")
		testing.expect(t, !strings.contains(event.payload_json, "agt_rev"), "history includes requirements only")
		testing.expect_value(t, event.actor_id, "owner")
		testing.expect_value(t, jsonx.extract_string(event.payload_json, "reason", "", true, context.temp_allocator), "Added provider")
	}
	testing.expect_value(t, changes, 1)
	_, stale, serr := update_task(&f.svc, f.owner, task.task_id, {
		brief_json = `{"goal":"lost update"}`, expected_requirements_revision = 1})
	testing.expect(t, !stale && serr.code == .Conflict, "stale update rejected")
	_, noop, nerr := update_task(&f.svc, f.owner, task.task_id, {
		brief_json = `{ "goal": "new objective", "acceptance": [ "a1", "Google sign-in" ] }`,
		expected_requirements_revision = 2})
	testing.expect(t, noop && nerr.code == .None, "format-only patch is a no-op")
	state, _ = taskv2.requirements_read(&f.repo, task)
	testing.expect_value(t, state.revision, i64(2))
	// An outer rollback must discard both brief and pending-delivery history.
	outer, begun, _ := iface.unit_of_work_begin(&factory)
	if !testing.expect(t, begun) do return
	_, changed, cerr := update_task(&f.svc, f.owner, task.task_id, {
		brief_json = `{"goal":"rolled back"}`, expected_requirements_revision = 2})
	testing.expect(t, changed && cerr.code == .None)
	iface.unit_of_work_rollback(&outer)
	stored, _, _ := iface.taskchain_get_task(&f.repo, task.task_id)
	testing.expect(t, !taskv2.requirements_differ(stored.brief_json, edited.brief_json), "rollback preserves current requirements")
	state, _ = taskv2.requirements_read(&f.repo, task)
	testing.expect_value(t, state.revision, i64(2))
	leases, _ := iface.taskchain_list_leases_by_task(&f.repo, task.task_id)
	testing.expect(t, len(leases) == 1 && leases[0].lease_id == "live_lease", "update preserves the lease")
	// A failure after saving the row must roll the history back as well.
	_, failed, ferr := update_task(&f.svc, f.owner, task.task_id, {
		brief_json = `{"goal":"must not persist"}`, expected_requirements_revision = 2,
		has_depends_on = true, depends_on = []domain.Task_ID{"missing_task"}})
	testing.expect(t, !failed && ferr.code != .None, "invalid dependency fails the whole update")
	state, _ = taskv2.requirements_read(&f.repo, task)
	testing.expect_value(t, state.revision, i64(2))
	stored, _, _ = iface.taskchain_get_task(&f.repo, task.task_id)
	testing.expect(t, !taskv2.requirements_differ(stored.brief_json, edited.brief_json))
	stored.publish_state = .Published
	_, _, _ = iface.taskchain_save_task(&f.repo, stored)
	_, incomplete, incomplete_err := update_task(&f.svc, f.owner, task.task_id, {
		brief_json = `{"acceptance":[]}`, expected_requirements_revision = 2})
	testing.expect(t, !incomplete && incomplete_err.code == .Validation_Failed, "published requirements cannot be cleared")
	for terminal in ([]domain.Task_State{.Done, .Cancelled}) {
		stored.state = terminal
		_, _, _ = iface.taskchain_save_task(&f.repo, stored)
		_, accepted, terr := update_task(&f.svc, f.owner, task.task_id, {
			brief_json = `{"goal":"silent terminal edit"}`, expected_requirements_revision = 2})
		testing.expect(t, !accepted && terr.code == .Conflict, "terminal task requires explicit reopen")
	}
}

@(test)
test_requirements_snapshot_preserves_vault_envelopes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	before := `{"goal":"vault:v2:old","acceptance":["vault:v2:accept"],"assignee":"secret-placement"}`
	snapshot := taskv2.requirements_snapshot(before)
	testing.expect(t, strings.contains(snapshot, "vault:v2:old") && strings.contains(snapshot, "vault:v2:accept"))
	testing.expect(t, !strings.contains(snapshot, "secret-placement"), "unrelated fields excluded")
	testing.expect(t, !taskv2.requirements_differ(before,
		`{"acceptance": [ "vault:v2:accept" ], "goal": "vault:v2:old"}`), "decoded equality")
}
