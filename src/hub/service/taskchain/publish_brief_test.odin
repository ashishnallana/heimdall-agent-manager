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

// M2: publishing validates every brief; a review role without a fleet row, a
// missing goal/acceptance/verify, each name the task and the missing field.
@(test)
test_publish_rejects_review_role_without_fleet_row :: proc(t: ^testing.T) {
	home := os.get_env("HOME", context.temp_allocator)
	db_path := fmt.tprintf("%s/.cache/heimdall-tests/tc_publish_brief_%d.db", home, os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)
	conn, open_ok, _ := sqlite.open(db_path)
	if !testing.expect(t, open_ok, "sqlite open ok") do return
	defer sqlite.close(&conn)
	mig_ok, _ := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	tc_impl := sqlite.Taskchain_Repo_SQLite{conn = &conn}
	tc_repo := sqlite.new_taskchain_repository(&tc_impl, &conn)
	ag_impl := sqlite.Agent_Repo_SQLite{conn = &conn}
	ag_repo := sqlite.new_agent_repository(&ag_impl, &conn)
	clock := platform.real_clock()
	ids := platform.real_id_generator()
	svc := new_taskchain_service(&tc_repo, &ag_repo, &clock, &ids)
	auth := contracts.Auth_Context{kind = .User_Token, user_id = "user_pub"}

	chain, cok, _ := create_chain(&svc, auth, Create_Chain_Input{title = "publish validation"})
	if !testing.expect(t, cok, "chain created") do return
	// a worker fleet row only; no row carries "security"
	now := platform.clock_now(&clock)
	_, _ = iface.taskchain_upsert_fleet(&tc_repo, domain.Task_Chain_Fleet{task_chain_id = chain.chain_id, agent_id = "agt_w", capacity = 1, roles_json = `["worker"]`, created_at = now, updated_at = now})

	complete, ok1, e1 := create_task(&svc, auth, Create_Task_Input{chain_id = chain.chain_id, title = "ok", brief_json = `{"goal":"do it","acceptance":["tests pass"],"verify":"make test","review_roles":[]}`})
	testing.expect(t, ok1, fmt.tprintf("create ok task: %s", e1.message))
	bad_role, ok2, _ := create_task(&svc, auth, Create_Task_Input{chain_id = chain.chain_id, title = "needs security", brief_json = `{"goal":"g","acceptance":["a"],"verify":"true","review_roles":["security"]}`})
	testing.expect(t, ok2, "create task with an uncovered review role (allowed until publish)")
	empty, ok3, _ := create_task(&svc, auth, Create_Task_Input{chain_id = chain.chain_id, title = "bare", description = "just a title"})
	testing.expect(t, ok3, "create bare task")

	// chain publish is atomic: nothing is published, every problem is listed
	_, pok, perr := publish_chain(&svc, auth, chain.chain_id)
	testing.expect(t, !pok, "chain publish refused")
	testing.expect_value(t, perr.code, domain.Error_Code.Validation_Failed)
	testing.expect(t, strings.contains(perr.details_json, `"code":"brief_incomplete"`), "details code")
	testing.expect(t, strings.contains(perr.details_json, fmt.tprintf(`"task_id":"%s"`, bad_role.task_id)) && strings.contains(perr.details_json, `"review_role:security"`), "review role without fleet row named")
	testing.expect(t, strings.contains(perr.details_json, fmt.tprintf(`"task_id":"%s"`, empty.task_id)) && strings.contains(perr.details_json, `"acceptance"`) && strings.contains(perr.details_json, `"verify"`), "bare task missing acceptance + verify")
	testing.expect(t, !strings.contains(perr.details_json, string(complete.task_id)), "complete task not listed")
	persisted, _, _ := iface.taskchain_get_chain(&tc_repo, chain.chain_id)
	testing.expect_value(t, persisted.publish_state, domain.Publish_State.Draft)

	// fix: add the security fleet row, give the bare task a brief → publish succeeds
	_, _ = iface.taskchain_upsert_fleet(&tc_repo, domain.Task_Chain_Fleet{task_chain_id = chain.chain_id, agent_id = "agt_sec", capacity = 1, roles_json = `["security"]`, created_at = now, updated_at = now})
	_, uok, uerr := update_task(&svc, auth, empty.task_id, Update_Task_Input{brief_json = `{"goal":"g","acceptance":["a"],"verify":"true"}`})
	testing.expect(t, uok, fmt.tprintf("update bare task: %s", uerr.message))
	_, pok2, perr2 := publish_chain(&svc, auth, chain.chain_id)
	testing.expect(t, pok2, fmt.tprintf("chain publish: %s %s", perr2.message, perr2.details_json))
	// a task created on the LIVE chain is published at once → validated at create
	long_goal := strings.repeat("g", BRIEF_GOAL_MAX + 1, context.temp_allocator)
	_, ok4, e4 := create_task(&svc, auth, Create_Task_Input{chain_id = chain.chain_id, title = "long", brief_json = fmt.tprintf(`{"goal":"%s","acceptance":["a"],"verify":"true"}`, long_goal)})
	testing.expect(t, !ok4 && e4.code == .Validation_Failed && strings.contains(e4.details_json, `"goal"`), "goal > 2k refused on a live chain")
	_, ok5, e5 := create_task(&svc, auth, Create_Task_Input{chain_id = chain.chain_id, title = "bare live", description = "no brief"})
	testing.expect(t, !ok5 && e5.code == .Validation_Failed && strings.contains(e5.details_json, `"acceptance"`), "bare task refused on a live chain")
	// gates are exempt
	gate, gok, gerr := create_task(&svc, auth, Create_Task_Input{chain_id = chain.chain_id, title = "gate", kind = .Gate})
	testing.expect(t, gok, fmt.tprintf("gate publishes without a brief: %s", gerr.message))
	testing.expect_value(t, gate.publish_state, domain.Publish_State.Published)
}
