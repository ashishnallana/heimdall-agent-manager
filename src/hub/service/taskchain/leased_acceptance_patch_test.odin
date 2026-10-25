package taskchain

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import taskv2 "odin_test:hub/service/taskv2"
import jsonx "odin_test:lib/jsonx"

// While a task is leased only an acceptance patch may change its brief. The
// removed verify keys are accepted and dropped (M2): a legacy `task update
// --verify …` is no brief edit at all and never replaces the brief.
@(test)
test_leased_task_acceptance_patch_preserves_scope_and_refreshes_lease :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("%s/.cache/heimdall-tests/leased_acceptance_%d.db", os.get_env("HOME", context.temp_allocator), os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)
	conn, open_ok, _ := sqlite.open(db_path)
	if !testing.expect(t, open_ok, "open database") do return
	defer sqlite.close(&conn)
	_, _ = sqlite.run_migrations(&conn)
	tc_impl: sqlite.Taskchain_Repo_SQLite
	ag_impl: sqlite.Agent_Repo_SQLite
	repo := sqlite.new_taskchain_repository(&tc_impl, &conn)
	agents := sqlite.new_agent_repository(&ag_impl, &conn)
	clock := platform.real_clock()
	ids := platform.real_id_generator()
	svc := new_taskchain_service(&repo, &agents, &clock, &ids)
	owner := contracts.Auth_Context{kind = .User_Token, user_id = "owner"}
	chain, cok, _ := create_chain(&svc, owner, Create_Chain_Input{title = "acceptance corrections"})
	if !testing.expect(t, cok, "create chain") do return
	chain.coordinator_agent_instance_id = "coord"
	_, _, _ = iface.taskchain_save_chain(&repo, chain)
	task, tok, _ := create_task(&svc, owner, Create_Task_Input{chain_id = chain.chain_id, title = "work", brief_json = `{"goal":"keep scope","acceptance":["original"],"verify":"odin test old","review_roles":[],"require_independent_verify":true,"auto_submit":true}`})
	if !testing.expect(t, tok, "create task") do return
	for key in ([]string{`"verify"`, "require_independent_verify", "auto_submit"}) {
		testing.expectf(t, !strings.contains(task.brief_json, key), "legacy key %s dropped at create", key)
	}
	testing.expect_value(t, jsonx.extract_string(task.brief_json, "goal", "", true, context.temp_allocator), "keep scope")
	now := platform.clock_now(&clock)
	for id in ([]string{"holder", "coord"}) {
		_, _, _ = iface.agent_save_instance(&agents, domain.Agent_Instance{agent_instance_id = id, owner_user_id = "owner", agent_id = "worker", chain_id = string(chain.chain_id), created_at = now, updated_at = now})
		_, _, _ = iface.taskchain_save_member(&repo, domain.Task_Chain_Member{chain_id = chain.chain_id, owner_user_id = "owner", agent_instance_id = id, agent_id = "worker", role = "coordinator" if id == "coord" else "worker", created_at = now})
	}
	// Seed the already-held lease; the update under test must neither release nor replace it.
	lease, lok, lerr := iface.taskchain_save_lease(&repo, domain.Task_Lease{lease_id = "lease_held", task_id = task.task_id, chain_id = chain.chain_id, owner_user_id = "owner", holder_instance_id = "holder", attempt_no = 1, kind = domain.LEASE_KIND_WORK, delivery = "inline", granted_at = now, confirmed_at = now, expires_at = "2099-01-01T00:00:00Z", hard_deadline_at = "2099-01-01T01:00:00Z"})
	if !testing.expectf(t, lok, "seed lease: %s", lerr.message) do return
	engine := taskv2.new_service(&repo, &agents, nil, &clock, &ids)
	svc.engine = &engine
	coordinator := contracts.Auth_Context{kind = .Instance_Token, user_id = "owner", agent_instance_id = "coord"}
	// a legacy verify-only patch succeeds and changes nothing
	legacy, lgok, lgerr := update_task(&svc, coordinator, task.task_id, Update_Task_Input{brief_json = `{"verify":"nix develop . --command odin test new"}`})
	if !testing.expectf(t, lgok, "legacy verify patch accepted: %s", lgerr.message) do return
	testing.expect_value(t, legacy.brief_json, task.brief_json)
	updated, uok, uerr := update_task(&svc, coordinator, task.task_id, Update_Task_Input{brief_json = `{"acceptance":["corrected"]}`})
	if !testing.expectf(t, uok, "coordinator can correct acceptance: %s", uerr.message) do return
	testing.expect_value(t, jsonx.extract_string(updated.brief_json, "goal", "", true, context.temp_allocator), "keep scope")
	testing.expect(t, strings.contains(updated.brief_json, "corrected") && !strings.contains(updated.brief_json, "original"), "acceptance replaced")
	// acceptance + a legacy key is still an acceptance patch
	_, aok, aerr := update_task(&svc, owner, task.task_id, Update_Task_Input{brief_json = `{"acceptance":["corrected again"],"verify":"true"}`})
	testing.expectf(t, aok, "owner can correct acceptance: %s", aerr.message)
	for input in ([]Update_Task_Input{
		{brief_json = `{"goal":"changed scope","verify":"true"}`},
		{title = "renamed"}, {has_reviewers = true}, {has_assignee = true},
	}) {
		_, bad_ok, bad_err := update_task(&svc, owner, task.task_id, input)
		testing.expect(t, !bad_ok && bad_err.code == .Conflict, "leased scope/assignment edits still refused")
	}
	_, forbidden, ferr := update_task(&svc, contracts.Auth_Context{kind = .Instance_Token, user_id = "owner", agent_instance_id = "holder"}, task.task_id, Update_Task_Input{brief_json = `{"acceptance":["weaker"]}`})
	testing.expect(t, !forbidden && ferr.code == .Forbidden, "holder cannot weaken its own acceptance")
	_, invalid, ierr := update_task(&svc, owner, task.task_id, Update_Task_Input{brief_json = `{"acceptance":"not a list"}`})
	testing.expect(t, !invalid && ierr.code == .Validation_Failed, "invalid acceptance type rejected")
	peek, pok, perr := taskv2.lease_next(&engine, contracts.Auth_Context{kind = .Instance_Token, user_id = "owner", agent_instance_id = "holder"}, taskv2.Lease_Next_Input{peek = true})
	testing.expectf(t, pok && peek.status == "current", "holder's next lease fetch: %s", perr.message)
	testing.expect_value(t, peek.lease.lease_id, lease.lease_id)
	testing.expect(t, strings.contains(peek.task.brief_json, "corrected again") && !strings.contains(peek.task.brief_json, `"verify"`), "holder sees the corrected acceptance and no verify key")
	evs, _ := iface.taskchain_list_events_by_task(&repo, task.task_id, task.owner_user_id)
	acceptance_events := 0
	for ev in evs {
		if ev.kind != taskv2.EV_UPDATED do continue
		testing.expect(t, !strings.contains(ev.payload_json, "verify"), "no verify audit field")
		if strings.contains(ev.payload_json, "brief.acceptance") do acceptance_events += 1
	}
	testing.expect_value(t, acceptance_events, 2)
}
