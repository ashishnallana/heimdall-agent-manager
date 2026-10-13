package hub_actions_repo_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import sqlite "odin_test:hub/repository/sqlite"

@(test)
test_hub_actions_repo :: proc(t: ^testing.T) {
	_ = t
	main()
}

check :: proc(ok: bool, msg: string) {
	if ok do return
	fmt.eprintln("FAIL:", msg)
	os.exit(1)
}

main :: proc() {
	db_path := "/tmp/actions_repo_test.db"
	_ = os.remove(db_path)
	defer _ = os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	check(open_ok, fmt.tprintf("open db: %s", open_err.message))
	defer sqlite.close(&conn)

	// Test 1: Full migration run
	mig_ok, mig_err := sqlite.run_migrations(&conn, "src/hub/repository/sqlite/migrations")
	check(mig_ok, fmt.tprintf("run_migrations: %s", mig_err.message))

	// Test 2: Idempotency of run_migrations
	mig_ok2, mig_err2 := sqlite.run_migrations(&conn, "src/hub/repository/sqlite/migrations")
	check(mig_ok2, fmt.tprintf("run_migrations 2nd run: %s", mig_err2.message))

	// Test 3: Idempotency of upgrade_actions_schema
	up_ok := sqlite.upgrade_actions_schema(&conn)
	check(up_ok, "upgrade_actions_schema should be idempotent")

	// Setup bridge and instance
	check(sqlite.exec(&conn, "INSERT INTO bridges (bridge_id, owner_user_id, status, created_at, updated_at) VALUES ('brg_ac1', 'usr_ac1', 'online', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');"), "bridge insert")
	check(sqlite.exec(&conn, "INSERT INTO agent_instances (agent_instance_id, owner_user_id, agent_id, bridge_id, runtime_status, created_at, updated_at) VALUES ('inst_ac1', 'usr_ac1', 'agt_ac1', 'brg_ac1', 'running', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');"), "agent instance insert")

	repo_impl: sqlite.Action_Repo_SQLite
	repo := sqlite.new_action_repository(&repo_impl, &conn)

	// Test 4: Save and Get action with full schedule spec
	action_sched := domain.Action{
		id = domain.Action_ID("act_sched_1"),
		owner_user_id = domain.User_ID("usr_ac1"),
		target_instance_id = domain.Agent_Instance_ID("inst_ac1"),
		prompt_text = "Daily morning standup sync",
		cron_expr = "0 9 * * 1-5",
		timezone = "America/New_York",
		blackout_dates = "[\"2026-12-25\",\"2027-01-01\"]",
		active_from = "2026-01-01T00:00:00Z",
		active_until = "2026-12-31T23:59:59Z",
		target_run_at = "2026-09-04T09:00:00Z",
		interval = "",
		state = .Active,
		in_flight = false,
		created_at = "2026-09-01T10:00:00Z",
		updated_at = "2026-09-01T10:00:00Z",
	}

	saved, ok_save, err_save := repo.save(repo.ctx, action_sched)
	check(ok_save, fmt.tprintf("save action_sched: %s", err_save.message))
	check(saved.cron_expr == "0 9 * * 1-5", "saved cron_expr mismatch")
	check(saved.timezone == "America/New_York", "saved timezone mismatch")
	check(saved.blackout_dates == "[\"2026-12-25\",\"2027-01-01\"]", "saved blackout_dates mismatch")

	got, ok_get, err_get := repo.get(repo.ctx, domain.Action_ID("act_sched_1"))
	check(ok_get, fmt.tprintf("get action_sched: %s", err_get.message))
	check(got.id == domain.Action_ID("act_sched_1"), "id mismatch")
	check(got.owner_user_id == domain.User_ID("usr_ac1"), "owner mismatch")
	check(got.target_instance_id == domain.Agent_Instance_ID("inst_ac1"), "target_instance mismatch")
	check(got.prompt_text == "Daily morning standup sync", "prompt_text mismatch")
	check(got.cron_expr == "0 9 * * 1-5", "cron_expr mismatch")
	check(got.timezone == "America/New_York", "timezone mismatch")
	check(got.blackout_dates == "[\"2026-12-25\",\"2027-01-01\"]", "blackout_dates mismatch")
	check(got.active_from == "2026-01-01T00:00:00Z", "active_from mismatch")
	check(got.active_until == "2026-12-31T23:59:59Z", "active_until mismatch")
	check(got.target_run_at == "2026-09-04T09:00:00Z", "target_run_at mismatch")
	check(got.state == .Active, "state mismatch")
	check(got.in_flight == false, "in_flight mismatch")

	// Test 5: Run-only action (null/empty schedule fields)
	action_run_only := domain.Action{
		id = domain.Action_ID("act_run_1"),
		owner_user_id = domain.User_ID("usr_ac1"),
		target_instance_id = domain.Agent_Instance_ID("inst_ac1"),
		prompt_text = "Run tests right now",
		cron_expr = "",
		timezone = "",
		blackout_dates = "",
		active_from = "",
		active_until = "",
		target_run_at = "",
		interval = "",
		state = .Active,
		in_flight = false,
		created_at = "2026-09-01T11:00:00Z",
		updated_at = "2026-09-01T11:00:00Z",
	}

	_, ok_save_ro, err_save_ro := repo.save(repo.ctx, action_run_only)
	check(ok_save_ro, fmt.tprintf("save action_run_only: %s", err_save_ro.message))

	got_ro, ok_get_ro, _ := repo.get(repo.ctx, domain.Action_ID("act_run_1"))
	check(ok_get_ro, "get action_run_only")
	check(got_ro.cron_expr == "", "run-only cron_expr should be empty")
	check(got_ro.timezone == "UTC", "run-only timezone defaults to UTC")
	check(got_ro.blackout_dates == "[]", "run-only blackout_dates defaults to []")

	// Test 6: List actions
	list_user, err_list := repo.list(repo.ctx, domain.User_ID("usr_ac1"))
	check(err_list.code == .None, "list by user")
	check(len(list_user) == 2, fmt.tprintf("expected 2 actions, got %d", len(list_user)))

	list_inst, err_list_inst := repo.list_by_instance(repo.ctx, domain.Agent_Instance_ID("inst_ac1"))
	check(err_list_inst.code == .None, "list by instance")
	check(len(list_inst) == 2, fmt.tprintf("expected 2 actions for instance, got %d", len(list_inst)))

	// Test 7: CAS Lease
	// Before target_run_at should fail
	cas_fail_early, _ := repo.cas_lease(repo.ctx, domain.Action_ID("act_sched_1"), "2026-09-04T08:00:00Z", "2026-09-04T08:00:00Z")
	check(!cas_fail_early, "CAS lease should fail before target_run_at")

	// At or after target_run_at should succeed
	cas_ok, _ := repo.cas_lease(repo.ctx, domain.Action_ID("act_sched_1"), "2026-09-04T09:00:00Z", "2026-09-04T09:00:00Z")
	check(cas_ok, "CAS lease should succeed at target_run_at")

	// Already leased should fail
	cas_fail_leased, _ := repo.cas_lease(repo.ctx, domain.Action_ID("act_sched_1"), "2026-09-04T09:01:00Z", "2026-09-04T09:01:00Z")
	check(!cas_fail_leased, "CAS lease should fail if already leased")

	// Verify state in DB
	got_leased, _, _ := repo.get(repo.ctx, domain.Action_ID("act_sched_1"))
	check(got_leased.in_flight == true, "action should be in_flight")
	check(got_leased.state == .In_Flight, "state should be in_flight")
	check(got_leased.leased_at == "2026-09-04T09:00:00Z", "leased_at mismatch")

	// Test 8: Max updated_at for bridge
	max_up, err_max := repo.max_updated_at_for_bridge(repo.ctx, domain.Bridge_ID("brg_ac1"))
	check(err_max.code == .None, "max_updated_at_for_bridge")
	check(max_up == "2026-09-04T09:00:00Z", fmt.tprintf("expected max_updated_at 2026-09-04T09:00:00Z, got %s", max_up))

	// Test 9: Soft delete
	del_ok, err_del := repo.delete_action(repo.ctx, domain.Action_ID("act_sched_1"))
	check(del_ok, fmt.tprintf("delete_action failed: %s", err_del.message))

	// Get should now return not found
	_, ok_after_del, _ := repo.get(repo.ctx, domain.Action_ID("act_sched_1"))
	check(!ok_after_del, "deleted action must not be retrieved by get")

	// List should only return 1 remaining action
	list_after_del, _ := repo.list(repo.ctx, domain.User_ID("usr_ac1"))
	check(len(list_after_del) == 1, fmt.tprintf("expected 1 action after delete, got %d", len(list_after_del)))

	// Bridge max_updated_at should still reflect the soft delete
	max_up_del, _ := repo.max_updated_at_for_bridge(repo.ctx, domain.Bridge_ID("brg_ac1"))
	check(max_up_del != "", "max_updated_at should still reflect soft-deleted action")

	// Test 10: Migration from existing scheduled_prompts table
	// Create a new DB, run migrations up to 022, insert into scheduled_prompts, then run 023
	db_mig_path := "/tmp/actions_mig_test.db"
	_ = os.remove(db_mig_path)
	defer _ = os.remove(db_mig_path)

	conn_mig, _, _ := sqlite.open(db_mig_path)
	defer sqlite.close(&conn_mig)

	// Run migration 022 directly
	check(sqlite.exec(&conn_mig, sqlite.MIGRATION_001_FOUNDATION), "mig 001")
	check(sqlite.exec(&conn_mig, sqlite.MIGRATION_022_SCHEDULED_PROMPTS), "mig 022")
	check(sqlite.exec(&conn_mig, "INSERT INTO scheduled_prompts (id, owner_user_id, target_instance_id, prompt_text, target_run_at, interval, state, in_flight, leased_at, deleted_at, created_at, updated_at) VALUES ('sp_legacy_1', 'usr_leg', 'inst_leg', 'legacy prompt', '2026-05-01T00:00:00Z', '30m', 'active', 0, '', '', '2026-05-01T00:00:00Z', '2026-05-01T00:00:00Z');"), "legacy insert")

	// Now run migration 023, 036, and 038 (the repo SELECTs read the 038 columns).
	check(sqlite.exec(&conn_mig, sqlite.MIGRATION_023_ACTIONS), "mig 023")
	check(sqlite.exec(&conn_mig, sqlite.MIGRATION_036_ACTION_TARGETS), "mig 036")
	check(sqlite.exec(&conn_mig, sqlite.MIGRATION_038_ACTION_INSTANCE_STRATEGY), "mig 038")
	check(sqlite.upgrade_actions_schema(&conn_mig), "upgrade_actions_schema on migrated db")

	repo_mig_impl: sqlite.Action_Repo_SQLite
	repo_mig := sqlite.new_action_repository(&repo_mig_impl, &conn_mig)

	migrated_action, ok_mig, _ := repo_mig.get(repo_mig.ctx, domain.Action_ID("sp_legacy_1"))
	check(ok_mig, "legacy prompt was migrated to actions")
	check(migrated_action.prompt_text == "legacy prompt", "migrated prompt text mismatch")
	check(migrated_action.interval == "30m", "migrated interval mismatch")
	check(migrated_action.cron_expr == "", "migrated cron_expr should be empty")
	check(migrated_action.timezone == "UTC", "migrated timezone should default to UTC")
	check(migrated_action.blackout_dates == "[]", "migrated blackout_dates should default to []")
	check(migrated_action.instance_strategy == "reuse", "migrated instance_strategy should default to reuse")

	// Test 11: Agent-targeted action and list_by_bridge
	action_agent := domain.Action{
		id = domain.Action_ID("act_agent_1"),
		owner_user_id = domain.User_ID("usr_ac1"),
		target_instance_id = "",
		target_agent_id = domain.Agent_ID("agt_curator"),
		target_bridge_id = domain.Bridge_ID("brg_ac1"),
		target_provider = "vertex",
		target_model = "fast",
		target_project_id = domain.Project_ID("prj_main"),
		prompt_text = "Curator scan",
		cron_expr = "0 0 * * *",
		timezone = "UTC",
		blackout_dates = "[]",
		active_from = "",
		active_until = "",
		target_run_at = "2026-10-01T00:00:00Z",
		interval = "",
		state = .Active,
		in_flight = false,
		created_at = "2026-09-01T12:00:00Z",
		updated_at = "2026-09-01T12:00:00Z",
	}
	saved_agt, ok_save_agt, err_save_agt := repo.save(repo.ctx, action_agent)
	check(ok_save_agt, fmt.tprintf("save action_agent: %s", err_save_agt.message))
	check(saved_agt.target_agent_id == "agt_curator", "saved target_agent_id mismatch")
	check(saved_agt.target_bridge_id == "brg_ac1", "saved target_bridge_id mismatch")
	check(saved_agt.target_provider == "vertex", "saved target_provider mismatch")
	check(saved_agt.target_model == "fast", "saved target_model mismatch")
	check(saved_agt.target_project_id == "prj_main", "saved target_project_id mismatch")

	got_agt, ok_get_agt, err_get_agt := repo.get(repo.ctx, domain.Action_ID("act_agent_1"))
	check(ok_get_agt, fmt.tprintf("get action_agent: %s", err_get_agt.message))
	check(got_agt.target_instance_id == "", "target_instance_id should be empty")
	check(got_agt.target_agent_id == "agt_curator", "target_agent_id mismatch")
	check(got_agt.target_bridge_id == "brg_ac1", "target_bridge_id mismatch")
	check(got_agt.target_provider == "vertex", "target_provider mismatch")
	check(got_agt.target_model == "fast", "target_model mismatch")
	check(got_agt.target_project_id == "prj_main", "target_project_id mismatch")
	check(domain.action_target_mode(got_agt) == .Agent, "target_mode should be Agent")

	// Test list_by_bridge: should return both instance-targeted action (act_run_1) and agent-targeted action (act_agent_1)
	bridge_actions, err_brg := repo.list_by_bridge(repo.ctx, domain.Bridge_ID("brg_ac1"))
	check(err_brg.code == .None, "list_by_bridge failed")
	check(len(bridge_actions) == 2, fmt.tprintf("expected 2 actions on bridge brg_ac1, got %d", len(bridge_actions)))

	fmt.println("ALL ACTIONS REPO TESTS PASSED")
}
