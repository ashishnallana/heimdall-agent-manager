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
import agent_service "odin_test:hub/service/agent"
import project_service "odin_test:hub/service/project"

@(test)
test_declarative_actor_refs_normalize :: proc(t: ^testing.T) {
	svc: Taskchain_Service
	chain := domain.Task_Chain{
		chain_id = "chain_test_decl",
		owner_user_id = "user_decl",
	}

	raw_assignee := `{"type":"agent_id","agent_id":"agt_worker"}`
	norm, ok, err := normalize_actor_refs(&svc, chain, raw_assignee)
	testing.expect(t, ok, "normalize_actor_refs should succeed for declarative agent_id")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, norm, raw_assignee)

	agt_id := primary_assignee_agent_id(raw_assignee)
	defer delete(agt_id)
	testing.expect_value(t, agt_id, "agt_worker")

	raw_reviewers := `[{"type":"agent_id","agent_id":"agt_reviewer"}]`
	rev_norm, rev_ok, rev_err := normalize_actor_refs(&svc, chain, raw_reviewers)
	testing.expect(t, rev_ok, "normalize_actor_refs should succeed for declarative reviewer ref array")
	testing.expect_value(t, rev_err.code, domain.Error_Code.None)
	testing.expect_value(t, rev_norm, raw_reviewers)

	rev_ids := extract_agent_ids_from_ref_blob(raw_reviewers)
	defer {
		for r in rev_ids do delete(r)
		delete(rev_ids)
	}
	testing.expect_value(t, len(rev_ids), 1)
	if len(rev_ids) == 1 {
		testing.expect_value(t, rev_ids[0], "agt_reviewer")
	}

	bound_assignee := bind_agent_id_to_instance(raw_assignee, "agt_worker", "inst_worker_42")
	defer delete(bound_assignee)
	testing.expect(t, strings.contains(bound_assignee, `"type":"agent_instance"`), "must replace type with agent_instance")
	testing.expect(t, strings.contains(bound_assignee, `"agent_instance_id":"inst_worker_42"`), "must contain instance id")

	bound_reviewers := bind_agent_id_to_instance(raw_reviewers, "agt_reviewer", "inst_rev_99")
	defer delete(bound_reviewers)
	testing.expect(t, strings.contains(bound_reviewers, `"agent_instance_id":"inst_rev_99"`), "must bind reviewer instance")
}

@(test)
test_actor_refs_json_key_order_and_whitespace :: proc(t: ^testing.T) {
	// 1. Single object with reversed key order: agent_id before type
	reversed_assignee := `{"agent_id":"agt_worker","type":"agent_id"}`
	agt_id := primary_assignee_agent_id(reversed_assignee)
	defer delete(agt_id)
	testing.expect_value(t, agt_id, "agt_worker")

	bound_assignee := bind_agent_id_to_instance(reversed_assignee, "agt_worker", "inst_worker_42")
	defer delete(bound_assignee)
	testing.expect(t, strings.contains(bound_assignee, `"type":"agent_instance"`), "must replace type with agent_instance")
	testing.expect(t, strings.contains(bound_assignee, `"agent_instance_id":"inst_worker_42"`), "must contain instance id")
	testing.expect(t, !strings.contains(bound_assignee, `"agent_id"`), "must not contain agent_id after binding")
	testing.expect(t, strings.has_prefix(bound_assignee, "{"), "must preserve object format")

	// 2. Extra whitespace and newlines
	whitespace_assignee := "  {\n  \"agent_id\": \"agt_worker\" ,\n  \"type\": \"agent_id\" \n}  "
	agt_ws_id := primary_assignee_agent_id(whitespace_assignee)
	defer delete(agt_ws_id)
	testing.expect_value(t, agt_ws_id, "agt_worker")

	bound_ws := bind_agent_id_to_instance(whitespace_assignee, "agt_worker", "inst_worker_42")
	defer delete(bound_ws)
	testing.expect(t, strings.contains(bound_ws, `"agent_instance_id":"inst_worker_42"`), "must bind instance id with whitespace")

	// 3. Array of reviewers with reversed keys and whitespace
	reversed_reviewers := " [ \n {\"agent_id\": \"agt_rev1\", \"type\": \"agent_id\"} ,\n {\"agent_id\": \"agt_rev2\", \"type\": \"agent_id\"} \n ] "
	req_count := count_required_reviewers(reversed_reviewers)
	testing.expect_value(t, req_count, 2)

	rev_ids := extract_agent_ids_from_ref_blob(reversed_reviewers)
	defer {
		for r in rev_ids do delete(r)
		delete(rev_ids)
	}
	testing.expect_value(t, len(rev_ids), 2)
	if len(rev_ids) == 2 {
		testing.expect_value(t, rev_ids[0], "agt_rev1")
		testing.expect_value(t, rev_ids[1], "agt_rev2")
	}

	bound_rev1 := bind_agent_id_to_instance(reversed_reviewers, "agt_rev1", "inst_rev_11")
	defer delete(bound_rev1)
	testing.expect(t, strings.has_prefix(bound_rev1, "["), "must preserve array format")
	testing.expect(t, strings.contains(bound_rev1, `"agent_instance_id":"inst_rev_11"`), "must bind first reviewer")
	testing.expect(t, strings.contains(bound_rev1, `"agent_id":"agt_rev2"`), "second reviewer remains agent_id")

	// 4. Reversed keys for agent_instance extraction
	reversed_inst := `{"agent_instance_id":"inst_test_99","type":"agent_instance"}`
	insts := extract_instances_from_ref_blob(reversed_inst)
	defer delete(insts)
	testing.expect_value(t, len(insts), 1)
	if len(insts) == 1 {
		testing.expect_value(t, insts[0], "inst_test_99")
	}
}

@(test)
test_durable_actor_ids_filter_and_deduplicate :: proc(t: ^testing.T) {
	task := domain.Task{
		assignee_ref_json = `{"type":"agent_id","agent_id":"agt_assignee"}`,
		reviewer_refs_json = `[{"type":"agent_id","agent_id":"agt_reviewer"},{"type":"agent_id","agent_id":"agt_assignee"},{"type":"user","agent_id":"agt_user"},{"type":"agent_instance","agent_id":"agt_instance"},{"type":"agent_id","agent_id":""}]`,
	}
	ids := durable_actor_ids(task)
	defer { for id in ids do delete(id); delete(ids) }
	testing.expect_value(t, len(ids), 2)
	if len(ids) == 2 {
		testing.expect_value(t, ids[0], "agt_assignee")
		testing.expect_value(t, ids[1], "agt_reviewer")
	}
}

@(test)
test_dynamic_fleet_scheduling_and_queuing_lifecycle :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_fleet_dispatch_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer sqlite.close(&conn)

	mig_ok, mig_err := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	tc_impl := sqlite.Taskchain_Repo_SQLite{conn = &conn}
	tc_repo := sqlite.new_taskchain_repository(&tc_impl, &conn)

	ag_impl := sqlite.Agent_Repo_SQLite{conn = &conn}
	ag_repo := sqlite.new_agent_repository(&ag_impl, &conn)

	clock := platform.real_clock()
	ids := platform.real_id_generator()
	svc := new_taskchain_service(&tc_repo, &ag_repo, &clock, &ids)

	owner := domain.User_ID("user_dispatcher")
	chain_id := domain.Task_Chain_ID("chain_dispatcher_test")

	// 1. Create chain
	chain := domain.Task_Chain{
		chain_id                      = chain_id,
		owner_user_id                 = owner,
		title                         = "Fleet Dispatcher Chain",
		description                   = "Fleet test",
		publish_state                 = .Published,
		status                        = .Active,
		kind                          = "test",
		coordinator_agent_instance_id = "inst_coord",
		default_reviewer_refs_json    = "[]",
		created_at                    = "2026-09-23T10:00:00Z",
		updated_at                    = "2026-09-23T10:00:00Z",
	}
	_, c_ok, c_err := iface.taskchain_save_chain(&tc_repo, chain)
	testing.expect(t, c_ok, "save chain ok")
	testing.expect_value(t, c_err.code, domain.Error_Code.None)

	// Coordinator instance
	coord_inst := domain.Agent_Instance{
		agent_instance_id = "inst_coord",
		owner_user_id     = owner,
		agent_id          = "agt_coordinator",
		bridge_id         = "brg_local",
		display_name      = "coordinator #1",
		runtime_status    = "running",
		chain_id          = string(chain_id),
		created_at        = "2026-09-23T10:00:00Z",
		updated_at        = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, coord_inst)

	// 2. Set fleet capacity = 1 for agt_worker
	fleet1 := domain.Task_Chain_Fleet{
		task_chain_id    = chain_id,
		agent_id         = "agt_worker",
		capacity         = 1,
		min_warm         = 1,
		idle_ttl_seconds = 300,
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:00:00Z",
	}
	_, _ = iface.taskchain_upsert_fleet(&tc_repo, fleet1)

	// 3. Create one idle worker instance inst_w1 in warm pool
	w1_inst := domain.Agent_Instance{
		agent_instance_id = "inst_w1",
		owner_user_id     = owner,
		agent_id          = "agt_worker",
		bridge_id         = "brg_local",
		display_name      = "worker #1",
		runtime_status    = "idle",
		chain_id          = string(chain_id),
		created_at        = "2026-09-23T10:00:00Z",
		updated_at        = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, w1_inst)
	w1_member := domain.Task_Chain_Member{
		chain_id          = chain_id,
		agent_instance_id = "inst_w1",
		agent_id          = "agt_worker",
		owner_user_id     = owner,
		role              = "worker",
		created_at        = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.taskchain_save_member(&tc_repo, w1_member)

	// 4. Create Task 1 targeting agt_worker
	t1 := domain.Task{
		task_id            = "task_w1",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "Task 1",
		publish_state      = .Published,
		status             = .Assigned,
		priority           = .P1,
		assignee_ref_json  = `{"type":"agent_id","agent_id":"agt_worker"}`,
		reviewer_refs_json = "[]",
		created_at         = "2026-09-23T10:01:00Z",
		updated_at         = "2026-09-23T10:01:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, t1)

	// Reconcile pass 1: Task 1 should be bound to idle warm pool instance inst_w1 and promoted to In_Progress
	promoted1 := reconcile_chain(&svc, chain)
	testing.expect_value(t, promoted1, 1)

	saved_t1, t1_ok, _ := iface.taskchain_get_task(&tc_repo, "task_w1")
	testing.expect(t, t1_ok, "get task 1 ok")
	testing.expect_value(t, saved_t1.status, domain.Task_Status.In_Progress)
	testing.expect(t, strings.contains(saved_t1.assignee_ref_json, "inst_w1"), "task 1 must be bound to inst_w1")

	saved_w1, _, _ := iface.agent_get_instance(&ag_repo, "inst_w1")
	testing.expect_value(t, saved_w1.current_task_id, "task_w1")
	testing.expect_value(t, saved_w1.current_task_role, domain.Current_Task_Role.Work)

	// 5. Create Task 2 (P2) and Task 3 (P0) while inst_w1 is busy on Task 1
	t2 := domain.Task{
		task_id            = "task_w2",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "Task 2 (Low Priority)",
		publish_state      = .Published,
		status             = .Assigned,
		priority           = .P2,
		assignee_ref_json  = `{"type":"agent_id","agent_id":"agt_worker"}`,
		reviewer_refs_json = "[]",
		created_at         = "2026-09-23T10:02:00Z",
		updated_at         = "2026-09-23T10:02:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, t2)

	t3 := domain.Task{
		task_id            = "task_w3",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "Task 3 (High Priority P0)",
		publish_state      = .Published,
		status             = .Assigned,
		priority           = .P0,
		assignee_ref_json  = `{"type":"agent_id","agent_id":"agt_worker"}`,
		reviewer_refs_json = "[]",
		created_at         = "2026-09-23T10:03:00Z",
		updated_at         = "2026-09-23T10:03:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, t3)

	// Reconcile pass 2: capacity = 1 and inst_w1 is busy, so tasks 2 and 3 must remain Queued
	promoted2 := reconcile_chain(&svc, chain)
	testing.expect_value(t, promoted2, 0)

	saved_t2, _, _ := iface.taskchain_get_task(&tc_repo, "task_w2")
	testing.expect_value(t, saved_t2.status, domain.Task_Status.Queued)

	saved_t3, _, _ := iface.taskchain_get_task(&tc_repo, "task_w3")
	testing.expect_value(t, saved_t3.status, domain.Task_Status.Queued)

	// 6. Free slot: Complete Task 1
	saved_t1.status = .Completed
	saved_t1.completed_at = "2026-09-23T10:05:00Z"
	_, _, _ = iface.taskchain_save_task(&tc_repo, saved_t1)

	// Reconcile pass 3: inst_w1 is now idle. Higher priority P0 task (Task 3) must be dispatched immediately
	promoted3 := reconcile_chain(&svc, chain)
	testing.expect_value(t, promoted3, 1)

	saved_t3_after, _, _ := iface.taskchain_get_task(&tc_repo, "task_w3")
	testing.expect_value(t, saved_t3_after.status, domain.Task_Status.In_Progress)
	testing.expect(t, strings.contains(saved_t3_after.assignee_ref_json, "inst_w1"), "task 3 must be bound to inst_w1")

	// Task 2 should still be Queued awaiting the next free slot
	saved_t2_after, _, _ := iface.taskchain_get_task(&tc_repo, "task_w2")
	testing.expect_value(t, saved_t2_after.status, domain.Task_Status.Queued)

	saved_w1_after, _, _ := iface.agent_get_instance(&ag_repo, "inst_w1")
	testing.expect_value(t, saved_w1_after.current_task_id, "task_w3")
}

@(test)
test_dynamic_fleet_jit_provisioning :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_fleet_jit_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	defer sqlite.close(&conn)

	mig_ok, mig_err := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")

	tc_impl := sqlite.Taskchain_Repo_SQLite{conn = &conn}
	tc_repo := sqlite.new_taskchain_repository(&tc_impl, &conn)

	ag_impl := sqlite.Agent_Repo_SQLite{conn = &conn}
	ag_repo := sqlite.new_agent_repository(&ag_impl, &conn)

	br_impl := sqlite.Bridge_Repo_SQLite{conn = &conn}
	br_repo := sqlite.new_bridge_repository(&br_impl, &conn)

	pr_impl := sqlite.Project_Repo_SQLite{conn = &conn}
	pr_repo := sqlite.new_project_repository(&pr_impl, &conn)

	co_impl := sqlite.Content_Repo_SQLite{conn = &conn}
	co_repo := sqlite.new_content_repository(&co_impl, &conn)

	provider_impl := sqlite.Provider_Repo_SQLite{conn = &conn}
	providers := sqlite.new_provider_repository(&provider_impl, &conn)

	clock := platform.real_clock()
	ids := platform.real_id_generator()

	owner := domain.User_ID("user_jit")
	chain_id := domain.Task_Chain_ID("chain_jit_test")

	// Set up Bridge in repo
	bridge := domain.Bridge{
		bridge_id         = "brg_jit",
		owner_user_id     = owner,
		machine_hostname  = "localhost",
		status            = .Online,
		capabilities_json = `{"capabilities":[{"provider":"claude","models":["claude-fable-5-1","claude-opus-5-5","claude-sonnet-5-5"],"default_model":"claude-opus-5-5"}],"provider":"claude","default_model":"claude-opus-5-5"}`,
		created_at        = "2026-09-23T10:00:00Z",
		updated_at        = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.bridge_save_bridge(&br_repo, bridge)
	override_bridge := bridge
	override_bridge.bridge_id = "brg_jit_task_override"
	_, _, _ = iface.bridge_save_bridge(&br_repo, override_bridge)
	_, _ = iface.bridge_provider_status_upsert(&providers, domain.Bridge_Provider_Status{bridge_id = "brg_jit", provider = "claude", state = "present"})
	_, _ = iface.bridge_provider_setting_upsert(&providers, domain.Bridge_Provider_Setting{bridge_id = "brg_jit", provider = "claude", enabled = true})
	_, _ = iface.bridge_provider_status_upsert(&providers, domain.Bridge_Provider_Status{bridge_id = override_bridge.bridge_id, provider = "claude", state = "present"})
	_, _ = iface.bridge_provider_setting_upsert(&providers, domain.Bridge_Provider_Setting{bridge_id = override_bridge.bridge_id, provider = "claude", enabled = true})

	// REQ-TB-3 regression fixture: a project with distinct per-bridge paths so a
	// task-level bridge pin keeps the inherited project context (from the
	// coordinator instance) while resolving project_path on the pinned bridge.
	jit_project := domain.Project{
		project_id    = domain.Project_ID("prj_jit"),
		owner_user_id = owner,
		name          = "JIT Project",
		slug          = "jit-project",
		default_path  = "/srv/jit/default",
		state         = .Active,
		created_at    = "2026-09-23T10:00:00Z",
		updated_at    = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.project_save(&pr_repo, jit_project)
	_, _, _ = iface.project_save_bridge_path(&pr_repo, domain.Project_Bridge_Path{
		project_id    = jit_project.project_id,
		bridge_id     = "brg_jit",
		owner_user_id = owner,
		path          = "/srv/jit/primary",
		created_at    = "2026-09-23T10:00:00Z",
		updated_at    = "2026-09-23T10:00:00Z",
	})
	_, _, _ = iface.project_save_bridge_path(&pr_repo, domain.Project_Bridge_Path{
		project_id    = jit_project.project_id,
		bridge_id     = override_bridge.bridge_id,
		owner_user_id = owner,
		path          = "/srv/jit/override",
		created_at    = "2026-09-23T10:00:00Z",
		updated_at    = "2026-09-23T10:00:00Z",
	})

	// Set up Agent in repo
	worker_agent := domain.Agent{
		agent_id         = "agt_jit_worker",
		owner_user_id    = owner,
		name             = "JIT Worker",
		slug             = "jit-worker",
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.agent_save(&ag_repo, worker_agent)

	// Set up Agent Bridge Support
	support := domain.Agent_Bridge_Support{
		agent_id      = "agt_jit_worker",
		bridge_id     = "brg_jit",
		owner_user_id = owner,
		enabled       = true,
	}
	_, _, _ = iface.agent_save_support(&ag_repo, support)
	override_support := support
	override_support.bridge_id = override_bridge.bridge_id
	_, _, _ = iface.agent_save_support(&ag_repo, override_support)

	// Set up bridge runtime registry and agent service
	registry := project_service.Bridge_Runtime_Registry{}
	project_service.bridge_runtime_registry_mark_live(&registry, "brg_jit", false, "")
	project_service.bridge_runtime_registry_mark_live(&registry, override_bridge.bridge_id, false, "")

	captured_cmds := make([dynamic]project_service.Runtime_Command)
	defer {
		for cmd in captured_cmds do delete(cmd.body_json)
		delete(captured_cmds)
	}
	sink := project_service.Bridge_Command_Sink{
		ctx = rawptr(&captured_cmds),
		send_runtime_command = proc(ctx: rawptr, cmd: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
			commands := (^[dynamic]project_service.Runtime_Command)(ctx)
			captured := cmd
			captured.body_json = strings.clone(cmd.body_json)
			append(commands, captured)
			return true, domain.Domain_Error{}
		},
	}

	svc := new_taskchain_service_with_runtime(&tc_repo, &ag_repo, sink, &clock, &ids)
	ag_service := agent_service.new_agent_service_with_runtime(&ag_repo, &br_repo, &pr_repo, &co_repo, &tc_repo, sink, &registry, &clock, &ids)
	ag_service.providers = &providers
	svc.agent_service = &ag_service

	// Create chain
	chain := domain.Task_Chain{
		chain_id                      = chain_id,
		owner_user_id                 = owner,
		title                         = "JIT Fleet Chain",
		publish_state                 = .Published,
		status                        = .Active,
		kind                          = "test",
		coordinator_agent_instance_id = "inst_coord_jit",
		created_at                    = "2026-09-23T10:00:00Z",
		updated_at                    = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.taskchain_save_chain(&tc_repo, chain)

	coord_inst := domain.Agent_Instance{
		agent_instance_id = "inst_coord_jit",
		owner_user_id     = owner,
		agent_id          = "agt_coordinator",
		bridge_id         = "brg_jit",
		project_id        = domain.Project_ID("prj_jit"),
		display_name      = "coordinator #1",
		runtime_status    = "running",
		chain_id          = string(chain_id),
		created_at        = "2026-09-23T10:00:00Z",
		updated_at        = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, coord_inst)

	// Set fleet capacity = 2 for agt_jit_worker with a per-role provider/model
	// (model "claude-fable-5-1" differs from the catalog default "claude-opus-5-5" so the assertions
	// below prove the fleet selection wins).
	fleet := domain.Task_Chain_Fleet{
		task_chain_id    = chain_id,
		agent_id         = "agt_jit_worker",
		capacity         = 2,
		min_warm         = 0,
		idle_ttl_seconds = 300,
		provider         = "claude",
		model             = "claude-fable-5-1",
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:00:00Z",
	}
	_, _ = iface.taskchain_upsert_fleet(&tc_repo, fleet)

	// Create Task 1 targeting agt_jit_worker
	task1 := domain.Task{
		task_id            = "task_jit_1",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "JIT Task 1",
		publish_state      = .Published,
		status             = .Assigned,
		priority           = .P1,
		assignee_ref_json  = `{"type":"agent_id","agent_id":"agt_jit_worker"}`,
		reviewer_refs_json = "[]",
		bridge_id          = override_bridge.bridge_id,
		created_at         = "2026-09-23T10:01:00Z",
		updated_at         = "2026-09-23T10:01:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, task1)

	// Reconcile: 0 instances exist, count < capacity (0 < 2) -> JIT provision instance 1!
	promoted := reconcile_chain(&svc, chain)
	testing.expect_value(t, promoted, 1)

	saved_t1, _, _ := iface.taskchain_get_task(&tc_repo, "task_jit_1")
	testing.expect_value(t, saved_t1.status, domain.Task_Status.In_Progress)
	spawned_id := primary_assignee_instance(saved_t1.assignee_ref_json)
	defer delete(spawned_id)
	testing.expect(t, strings.has_prefix(spawned_id, "inst_"), "must have spawned a concrete instance")

	// Check instance exists in ag_repo and has focus
	spawned_inst, inst_ok, _ := iface.agent_get_instance(&ag_repo, spawned_id)
	testing.expect(t, inst_ok, "spawned instance must exist in repository")
	testing.expect_value(t, spawned_inst.agent_id, "agt_jit_worker")
	testing.expect_value(t, spawned_inst.chain_id, string(chain_id))
	testing.expect_value(t, spawned_inst.current_task_id, "task_jit_1")
	testing.expect_value(t, spawned_inst.current_task_role, domain.Current_Task_Role.Work)
	testing.expect_value(t, spawned_inst.bridge_id, override_bridge.bridge_id)
	// REQ-TB-3: the pinned bridge overrides only the bridge; the coordinator's
	// project context is inherited and project_path resolves on the pinned bridge.
	testing.expect_value(t, string(spawned_inst.project_id), "prj_jit")
	testing.expect_value(t, spawned_inst.project_path, "/srv/jit/override")

	// REQ-FLEET-PT-2: the fleet row's provider/model must reach the JIT-provisioned
	// instance (worker call site).
	testing.expect_value(t, spawned_inst.provider, "claude")
	testing.expect_value(t, spawned_inst.model, "claude-fable-5-1")

	// Check instance is enrolled as chain member
	is_member := is_instance_member_or_coordinator(&svc, chain, spawned_id)
	testing.expect(t, is_member, "spawned instance must be enrolled as chain member")

	// Fleet provider/model cleared back to "" -> inherit. The next JIT instance must
	// fall back to the standard resolution order (catalog default claude/claude-opus-5-5).
	cleared := fleet
	cleared.provider = ""
	cleared.model = ""
	_, _ = iface.taskchain_upsert_fleet(&tc_repo, cleared)

	task2 := domain.Task{
		task_id            = "task_jit_2",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "JIT Task 2",
		publish_state      = .Published,
		status             = .Assigned,
		priority           = .P1,
		assignee_ref_json  = `{"type":"agent_id","agent_id":"agt_jit_worker"}`,
		reviewer_refs_json = "[]",
		created_at         = "2026-09-23T10:02:00Z",
		updated_at         = "2026-09-23T10:02:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, task2)

	promoted2 := reconcile_chain(&svc, chain)
	testing.expect_value(t, promoted2, 1)

	saved_t2, t2_ok, _ := iface.taskchain_get_task(&tc_repo, "task_jit_2")
	testing.expect(t, t2_ok, "get task 2 ok")
	testing.expect_value(t, saved_t2.status, domain.Task_Status.In_Progress)
	spawned2_id := primary_assignee_instance(saved_t2.assignee_ref_json)
	defer delete(spawned2_id)
	testing.expect(t, spawned2_id != spawned_id, "second JIT spawn must be a distinct instance")

	inherited_inst, inherited_ok, _ := iface.agent_get_instance(&ag_repo, spawned2_id)
	testing.expect(t, inherited_ok, "second spawned instance must exist in repository")
	testing.expect_value(t, inherited_inst.bridge_id, "brg_jit")
	testing.expect_value(t, inherited_inst.provider, "claude")
	testing.expect_value(t, inherited_inst.model, "claude-opus-5-5")
	// REQ-TB-3: with no task pin the same inherited project context resolves its
	// path on the fallback bridge (coordinator bridge), not the override bridge.
	testing.expect_value(t, string(inherited_inst.project_id), "prj_jit")
	testing.expect_value(t, inherited_inst.project_path, "/srv/jit/primary")

	// Reviewer call site: a fleet row for the reviewer agent must reach the
	// reviewer JIT provision in the REVIEWER DISPATCH PASS (model "claude-sonnet-5-5" differs
	// from the catalog default "claude-opus-5-5").
	reviewer_agent := domain.Agent{
		agent_id         = "agt_jit_reviewer",
		owner_user_id    = owner,
		name             = "JIT Reviewer",
		slug             = "jit-reviewer",
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.agent_save(&ag_repo, reviewer_agent)

	reviewer_support := domain.Agent_Bridge_Support{
		agent_id      = "agt_jit_reviewer",
		bridge_id     = "brg_jit",
		owner_user_id = owner,
		enabled       = true,
	}
	_, _, _ = iface.agent_save_support(&ag_repo, reviewer_support)
	reviewer_override_support := reviewer_support
	reviewer_override_support.bridge_id = override_bridge.bridge_id
	_, _, _ = iface.agent_save_support(&ag_repo, reviewer_override_support)

	reviewer_fleet := domain.Task_Chain_Fleet{
		task_chain_id    = chain_id,
		agent_id         = "agt_jit_reviewer",
		capacity         = 1,
		min_warm         = 0,
		idle_ttl_seconds = 300,
		provider         = "claude",
		model             = "claude-sonnet-5-5",
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:00:00Z",
	}
	_, _ = iface.taskchain_upsert_fleet(&tc_repo, reviewer_fleet)

	review_task := domain.Task{
		task_id            = "task_jit_review",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "JIT Review Task",
		publish_state      = .Published,
		status             = .In_Validation,
		priority           = .P1,
		assignee_ref_json  = `{"type":"agent_id","agent_id":"agt_jit_worker"}`,
		reviewer_refs_json = `[{"type":"agent_id","agent_id":"agt_jit_reviewer"}]`,
		bridge_id          = override_bridge.bridge_id,
		created_at         = "2026-09-23T10:03:00Z",
		updated_at         = "2026-09-23T10:03:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, review_task)

	_ = reconcile_chain(&svc, chain)

	saved_rev_task, rev_task_ok, _ := iface.taskchain_get_task(&tc_repo, "task_jit_review")
	testing.expect(t, rev_task_ok, "review task must exist")
	// extract_instances_from_ref_blob returns interior subslices of the blob —
	// only the array itself is deletable.
	rev_instances := extract_instances_from_ref_blob(saved_rev_task.reviewer_refs_json)
	defer delete(rev_instances)
	testing.expect_value(t, len(rev_instances), 1)
	if len(rev_instances) == 1 {
		testing.expect(t, rev_instances[0] != spawned_id, "reviewer instance must differ from the worker instance")
		rev_inst, rev_ok, _ := iface.agent_get_instance(&ag_repo, rev_instances[0])
		testing.expect(t, rev_ok, "reviewer JIT instance must exist in repository")
		testing.expect_value(t, rev_inst.agent_id, "agt_jit_reviewer")
		testing.expect_value(t, rev_inst.bridge_id, override_bridge.bridge_id)
		testing.expect_value(t, rev_inst.provider, "claude")
		testing.expect_value(t, rev_inst.model, "claude-sonnet-5-5")
		testing.expect_value(t, rev_inst.current_task_id, "task_jit_review")
		testing.expect_value(t, rev_inst.current_task_role, domain.Current_Task_Role.Review)
		// REQ-TB-3: reviewer JIT spawn keeps the inherited project context and
		// resolves its path on the task-pinned bridge, same as the worker spawn.
		testing.expect_value(t, string(rev_inst.project_id), "prj_jit")
		testing.expect_value(t, rev_inst.project_path, "/srv/jit/override")
	}

	saved_t1.status = .Completed
	_, _, _ = iface.taskchain_save_task(&tc_repo, saved_t1)
	saved_t2.status = .Completed
	_, _, _ = iface.taskchain_save_task(&tc_repo, saved_t2)
	saved_rev_task.status = .Completed
	_, _, _ = iface.taskchain_save_task(&tc_repo, saved_rev_task)
	_ = reconcile_chain(&svc, chain)

	offline_bridge := bridge
	offline_bridge.bridge_id = "brg_jit_offline"
	offline_bridge.status = .Offline
	_, _, _ = iface.bridge_save_bridge(&br_repo, offline_bridge)
	_, _ = iface.bridge_provider_status_upsert(&providers, domain.Bridge_Provider_Status{bridge_id = offline_bridge.bridge_id, provider = "claude", state = "present"})
	_, _ = iface.bridge_provider_setting_upsert(&providers, domain.Bridge_Provider_Setting{bridge_id = offline_bridge.bridge_id, provider = "claude", enabled = true})
	offline_agent := domain.Agent{
		agent_id         = "agt_jit_offline",
		owner_user_id    = owner,
		name             = "Offline JIT Worker",
		slug             = "offline-jit-worker",
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.agent_save(&ag_repo, offline_agent)
	offline_support := domain.Agent_Bridge_Support{
		agent_id      = offline_agent.agent_id,
		bridge_id     = offline_bridge.bridge_id,
		owner_user_id = owner,
		enabled       = true,
	}
	_, _, _ = iface.agent_save_support(&ag_repo, offline_support)
	offline_fleet := domain.Task_Chain_Fleet{
		task_chain_id    = chain_id,
		agent_id         = offline_agent.agent_id,
		capacity         = 1,
		min_warm         = 0,
		idle_ttl_seconds = 300,
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:00:00Z",
	}
	_, _ = iface.taskchain_upsert_fleet(&tc_repo, offline_fleet)
	offline_task := domain.Task{
		task_id            = "task_jit_offline",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "Offline JIT Task",
		publish_state      = .Published,
		status             = .Assigned,
		priority           = .P1,
		assignee_ref_json  = `{"type":"agent_id","agent_id":"agt_jit_offline"}`,
		reviewer_refs_json = "[]",
		bridge_id          = offline_bridge.bridge_id,
		created_at         = "2026-09-23T10:04:00Z",
		updated_at         = "2026-09-23T10:04:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, offline_task)

	commands_before_hold := len(captured_cmds)
	promoted_while_offline := reconcile_chain(&svc, chain)
	testing.expect_value(t, promoted_while_offline, 0)
	held_task, held_ok, _ := iface.taskchain_get_task(&tc_repo, offline_task.task_id)
	testing.expect(t, held_ok, "offline task must exist")
	testing.expect_value(t, held_task.status, domain.Task_Status.Assigned)
	testing.expect_value(t, held_task.updated_at, offline_task.updated_at)
	held_assignee := primary_assignee_instance(held_task.assignee_ref_json)
	testing.expect_value(t, held_assignee, "")
	testing.expect_value(t, len(captured_cmds), commands_before_hold)

	offline_bridge.status = .Online
	_, _, _ = iface.bridge_save_bridge(&br_repo, offline_bridge)
	project_service.bridge_runtime_registry_mark_live(&registry, offline_bridge.bridge_id, false, "")
	promoted_after_resume := reconcile_chain(&svc, chain)
	testing.expect_value(t, promoted_after_resume, 1)
	resumed_task, resumed_ok, _ := iface.taskchain_get_task(&tc_repo, offline_task.task_id)
	testing.expect(t, resumed_ok, "resumed task must exist")
	testing.expect_value(t, resumed_task.status, domain.Task_Status.In_Progress)
	resumed_assignee := primary_assignee_instance(resumed_task.assignee_ref_json)
	defer delete(resumed_assignee)
	resumed_inst, resumed_inst_ok, _ := iface.agent_get_instance(&ag_repo, resumed_assignee)
	testing.expect(t, resumed_inst_ok, "offline task must JIT provision once its bridge returns")
	testing.expect_value(t, resumed_inst.bridge_id, offline_bridge.bridge_id)
	testing.expect(t, len(captured_cmds) > commands_before_hold, "resumed task must enqueue a wake command")
}

@(test)
test_stopped_warm_instance_reuse_and_auto_start :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_fleet_stopped_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, _ := sqlite.open(db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	defer sqlite.close(&conn)

	mig_ok, _ := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")

	tc_impl := sqlite.Taskchain_Repo_SQLite{conn = &conn}
	tc_repo := sqlite.new_taskchain_repository(&tc_impl, &conn)

	ag_impl := sqlite.Agent_Repo_SQLite{conn = &conn}
	ag_repo := sqlite.new_agent_repository(&ag_impl, &conn)

	br_impl := sqlite.Bridge_Repo_SQLite{conn = &conn}
	br_repo := sqlite.new_bridge_repository(&br_impl, &conn)

	clock := platform.real_clock()
	ids := platform.real_id_generator()

	captured_cmds := make([dynamic]project_service.Runtime_Command)
	defer {
		for c in captured_cmds {
			delete(c.body_json)
		}
		delete(captured_cmds)
	}

	sink := project_service.Bridge_Command_Sink{
		ctx = rawptr(&captured_cmds),
		send_runtime_command = proc(ctx: rawptr, cmd: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
			list := (^[dynamic]project_service.Runtime_Command)(ctx)
			c_copy := cmd
			c_copy.body_json = strings.clone(cmd.body_json)
			append(list, c_copy)
			return true, domain.Domain_Error{}
		},
	}

	svc := new_taskchain_service_with_runtime(&tc_repo, &ag_repo, sink, &clock, &ids)

	owner := domain.User_ID("user_stopped_test")
	chain_id := domain.Task_Chain_ID("chain_stopped_test")

	// Set up Bridge in repo
	bridge := domain.Bridge{
		bridge_id         = "brg_stopped_test",
		owner_user_id     = owner,
		machine_hostname  = "localhost",
		status            = .Online,
		created_at        = "2026-09-23T10:00:00Z",
		updated_at        = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.bridge_save_bridge(&br_repo, bridge)

	// Set up Agents in repo
	worker_agent := domain.Agent{
		agent_id         = "agt_w",
		owner_user_id    = owner,
		name             = "Worker Agent",
		slug             = "worker-agent",
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.agent_save(&ag_repo, worker_agent)

	reviewer_agent := domain.Agent{
		agent_id         = "agt_r",
		owner_user_id    = owner,
		name             = "Reviewer Agent",
		slug             = "reviewer-agent",
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.agent_save(&ag_repo, reviewer_agent)

	// Create chain
	chain := domain.Task_Chain{
		chain_id                      = chain_id,
		owner_user_id                 = owner,
		title                         = "Stopped Warm Pool Chain",
		publish_state                 = .Published,
		status                        = .Active,
		kind                          = "test",
		coordinator_agent_instance_id = "inst_coord_test",
		created_at                    = "2026-09-23T10:00:00Z",
		updated_at                    = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.taskchain_save_chain(&tc_repo, chain)

	coord_inst := domain.Agent_Instance{
		agent_instance_id = "inst_coord_test",
		owner_user_id     = owner,
		agent_id          = "agt_coordinator",
		bridge_id         = "brg_stopped_test",
		display_name      = "coordinator",
		runtime_status    = "running",
		chain_id          = string(chain_id),
		created_at        = "2026-09-23T10:00:00Z",
		updated_at        = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, coord_inst)

	// Pre-create a STOPPED warm instance for agt_w
	w_inst := domain.Agent_Instance{
		agent_instance_id = "inst_w_stopped",
		owner_user_id     = owner,
		agent_id          = "agt_w",
		bridge_id         = "brg_stopped_test",
		display_name      = "stopped worker",
		runtime_status    = "stopped",
		chain_id          = string(chain_id),
		created_at        = "2026-09-23T10:00:00Z",
		updated_at        = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, w_inst)
	w_member := domain.Task_Chain_Member{
		chain_id          = chain_id,
		agent_instance_id = "inst_w_stopped",
		agent_id          = "agt_w",
		owner_user_id     = owner,
		role              = "worker",
		created_at        = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.taskchain_save_member(&tc_repo, w_member)

	// Pre-create a STOPPED warm instance for agt_r
	r_inst := domain.Agent_Instance{
		agent_instance_id = "inst_r_stopped",
		owner_user_id     = owner,
		agent_id          = "agt_r",
		bridge_id         = "brg_stopped_test",
		display_name      = "stopped reviewer",
		runtime_status    = "stopped",
		chain_id          = string(chain_id),
		created_at        = "2026-09-23T10:00:00Z",
		updated_at        = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, r_inst)
	r_member := domain.Task_Chain_Member{
		chain_id          = chain_id,
		agent_instance_id = "inst_r_stopped",
		agent_id          = "agt_r",
		owner_user_id     = owner,
		role              = "reviewer",
		created_at        = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.taskchain_save_member(&tc_repo, r_member)

	// Fleet capacity = 1 for agt_w and agt_r
	_, _ = iface.taskchain_upsert_fleet(&tc_repo, domain.Task_Chain_Fleet{
		task_chain_id = chain_id,
		agent_id      = "agt_w",
		capacity      = 1,
	})
	_, _ = iface.taskchain_upsert_fleet(&tc_repo, domain.Task_Chain_Fleet{
		task_chain_id = chain_id,
		agent_id      = "agt_r",
		capacity      = 1,
	})

	// Task 1: work task targeting agt_w
	task1 := domain.Task{
		task_id            = "task_work_1",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "Work Task 1",
		publish_state      = .Published,
		status             = .Assigned,
		priority           = .P1,
		assignee_ref_json  = `{"type":"agent_id","agent_id":"agt_w"}`,
		reviewer_refs_json = "[]",
		created_at         = "2026-09-23T10:01:00Z",
		updated_at         = "2026-09-23T10:01:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, task1)

	// Task 2: review task in In_Validation targeting agt_r
	task2 := domain.Task{
		task_id            = "task_rev_1",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "Review Task 1",
		publish_state      = .Published,
		status             = .In_Validation,
		priority           = .P1,
		assignee_ref_json  = `{"type":"agent_instance","agent_instance_id":"inst_other"}`,
		reviewer_refs_json = `[{"type":"agent_id","agent_id":"agt_r"}]`,
		created_at         = "2026-09-23T10:01:00Z",
		updated_at         = "2026-09-23T10:01:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, task2)

	// Reconcile
	promoted := reconcile_chain(&svc, chain)
	testing.expect_value(t, promoted, 1)

	// 1. Verify Task 1 bound to inst_w_stopped (reused warm stopped instance, NOT new instance)
	saved_t1, _, _ := iface.taskchain_get_task(&tc_repo, "task_work_1")
	testing.expect_value(t, saved_t1.status, domain.Task_Status.In_Progress)
	testing.expect(t, strings.contains(saved_t1.assignee_ref_json, "inst_w_stopped"), "task_work_1 must be bound to inst_w_stopped")

	// 2. Verify Task 2 bound to inst_r_stopped (reused warm stopped instance)
	saved_t2, _, _ := iface.taskchain_get_task(&tc_repo, "task_rev_1")
	testing.expect(t, strings.contains(saved_t2.reviewer_refs_json, "inst_r_stopped"), "task_rev_1 must be bound to inst_r_stopped")

	// 3. Verify wake commands emitted for both stopped instances and NO stops
	wake_w_found := false
	wake_r_found := false
	stop_w_found := false
	stop_r_found := false

	for cmd in captured_cmds {
		if strings.contains(cmd.body_json, `"type":"wake_agent"`) {
			if strings.contains(cmd.body_json, "inst_w_stopped") && strings.contains(cmd.body_json, "task_work_1") {
				wake_w_found = true
			}
			if strings.contains(cmd.body_json, "inst_r_stopped") && strings.contains(cmd.body_json, "task_rev_1") {
				wake_r_found = true
			}
			if strings.contains(cmd.body_json, `"stops":[`) {
				if strings.contains(cmd.body_json, `"inst_w_stopped"`) {
					stop_w_found = true
				}
				if strings.contains(cmd.body_json, `"inst_r_stopped"`) {
					stop_r_found = true
				}
			}
		}
	}

	testing.expect(t, wake_w_found, "wake_agent must be emitted for stopped worker instance inst_w_stopped")
	testing.expect(t, wake_r_found, "wake_agent must be emitted for stopped reviewer instance inst_r_stopped")
	testing.expect(t, !stop_w_found, "inst_w_stopped must NEVER appear in stops")
	testing.expect(t, !stop_r_found, "inst_r_stopped must NEVER appear in stops")

	// 4. Verify instances have focus updated in repo
	saved_w_inst, _, _ := iface.agent_get_instance(&ag_repo, "inst_w_stopped")
	testing.expect_value(t, saved_w_inst.current_task_id, "task_work_1")
	testing.expect_value(t, saved_w_inst.current_task_role, domain.Current_Task_Role.Work)

	saved_r_inst, _, _ := iface.agent_get_instance(&ag_repo, "inst_r_stopped")
	testing.expect_value(t, saved_r_inst.current_task_id, "task_rev_1")
	testing.expect_value(t, saved_r_inst.current_task_role, domain.Current_Task_Role.Review)
}

@(test)
test_dynamic_fleet_schedule_bridge_pinning_and_live_count_scope :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_fleet_bridge_pinning_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, _ := sqlite.open(db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	defer sqlite.close(&conn)

	mig_ok, _ := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")

	tc_impl := sqlite.Taskchain_Repo_SQLite{conn = &conn}
	tc_repo := sqlite.new_taskchain_repository(&tc_impl, &conn)

	ag_impl := sqlite.Agent_Repo_SQLite{conn = &conn}
	ag_repo := sqlite.new_agent_repository(&ag_impl, &conn)

	br_impl := sqlite.Bridge_Repo_SQLite{conn = &conn}
	br_repo := sqlite.new_bridge_repository(&br_impl, &conn)

	pr_impl := sqlite.Project_Repo_SQLite{conn = &conn}
	pr_repo := sqlite.new_project_repository(&pr_impl, &conn)

	co_impl := sqlite.Content_Repo_SQLite{conn = &conn}
	co_repo := sqlite.new_content_repository(&co_impl, &conn)

	provider_impl := sqlite.Provider_Repo_SQLite{conn = &conn}
	providers := sqlite.new_provider_repository(&provider_impl, &conn)

	clock := platform.real_clock()
	ids := platform.real_id_generator()

	owner := domain.User_ID("user_pin_test")
	chain_id := domain.Task_Chain_ID("chain_pin_test")

	// Set up two online bridges
	brg_dawnstar := domain.Bridge{
		bridge_id         = "brg_dawnstar",
		owner_user_id     = owner,
		machine_hostname  = "dawnstar-host",
		status            = .Online,
		capabilities_json = `{"capabilities":[{"provider":"claude","models":["claude-fable-5-1","claude-opus-5-5","claude-sonnet-5-5"],"default_model":"claude-sonnet-5-5"}],"provider":"claude","default_model":"claude-sonnet-5-5"}`,
		created_at        = "2026-09-23T10:00:00Z",
		updated_at        = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.bridge_save_bridge(&br_repo, brg_dawnstar)

	brg_riverwood := domain.Bridge{
		bridge_id         = "brg_riverwood",
		owner_user_id     = owner,
		machine_hostname  = "riverwood-host",
		status            = .Online,
		capabilities_json = `{"capabilities":[{"provider":"claude","models":["claude-fable-5-1","claude-opus-5-5","claude-sonnet-5-5"],"default_model":"claude-sonnet-5-5"}],"provider":"claude","default_model":"claude-sonnet-5-5"}`,
		created_at        = "2026-09-23T10:00:00Z",
		updated_at        = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.bridge_save_bridge(&br_repo, brg_riverwood)
	_, _ = iface.bridge_provider_status_upsert(&providers, domain.Bridge_Provider_Status{bridge_id = "brg_dawnstar", provider = "claude", state = "present"})
	_, _ = iface.bridge_provider_setting_upsert(&providers, domain.Bridge_Provider_Setting{bridge_id = "brg_dawnstar", provider = "claude", enabled = true})
	_, _ = iface.bridge_provider_status_upsert(&providers, domain.Bridge_Provider_Status{bridge_id = "brg_riverwood", provider = "claude", state = "present"})
	_, _ = iface.bridge_provider_setting_upsert(&providers, domain.Bridge_Provider_Setting{bridge_id = "brg_riverwood", provider = "claude", enabled = true})

	// Set up Project
	pin_project := domain.Project{
		project_id    = domain.Project_ID("prj_pin"),
		owner_user_id = owner,
		name          = "Pin Project",
		slug          = "pin-project",
		default_path  = "/srv/pin/default",
		state         = .Active,
		created_at    = "2026-09-23T10:00:00Z",
		updated_at    = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.project_save(&pr_repo, pin_project)
	_, _, _ = iface.project_save_bridge_path(&pr_repo, domain.Project_Bridge_Path{
		project_id    = pin_project.project_id,
		bridge_id     = "brg_dawnstar",
		owner_user_id = owner,
		path          = "/srv/pin/dawnstar",
		created_at    = "2026-09-23T10:00:00Z",
		updated_at    = "2026-09-23T10:00:00Z",
	})
	_, _, _ = iface.project_save_bridge_path(&pr_repo, domain.Project_Bridge_Path{
		project_id    = pin_project.project_id,
		bridge_id     = "brg_riverwood",
		owner_user_id = owner,
		path          = "/srv/pin/riverwood",
		created_at    = "2026-09-23T10:00:00Z",
		updated_at    = "2026-09-23T10:00:00Z",
	})

	// Set up Agent in repo
	worker_agent := domain.Agent{
		agent_id         = "agt_pinned_worker",
		owner_user_id    = owner,
		name             = "Pinned Worker",
		slug             = "pinned-worker",
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.agent_save(&ag_repo, worker_agent)

	// Set up Agent Bridge Support for both bridges
	_, _, _ = iface.agent_save_support(&ag_repo, domain.Agent_Bridge_Support{
		agent_id      = "agt_pinned_worker",
		bridge_id     = "brg_dawnstar",
		owner_user_id = owner,
		enabled       = true,
	})
	_, _, _ = iface.agent_save_support(&ag_repo, domain.Agent_Bridge_Support{
		agent_id      = "agt_pinned_worker",
		bridge_id     = "brg_riverwood",
		owner_user_id = owner,
		enabled       = true,
	})

	registry := project_service.Bridge_Runtime_Registry{}
	project_service.bridge_runtime_registry_mark_live(&registry, "brg_dawnstar", false, "")
	project_service.bridge_runtime_registry_mark_live(&registry, "brg_riverwood", false, "")

	captured_cmds := make([dynamic]project_service.Runtime_Command)
	defer {
		for cmd in captured_cmds do delete(cmd.body_json)
		delete(captured_cmds)
	}
	sink := project_service.Bridge_Command_Sink{
		ctx = rawptr(&captured_cmds),
		send_runtime_command = proc(ctx: rawptr, cmd: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
			commands := (^[dynamic]project_service.Runtime_Command)(ctx)
			captured := cmd
			captured.body_json = strings.clone(cmd.body_json)
			append(commands, captured)
			return true, domain.Domain_Error{}
		},
	}

	svc := new_taskchain_service_with_runtime(&tc_repo, &ag_repo, sink, &clock, &ids)
	ag_service := agent_service.new_agent_service_with_runtime(&ag_repo, &br_repo, &pr_repo, &co_repo, &tc_repo, sink, &registry, &clock, &ids)
	ag_service.providers = &providers
	svc.agent_service = &ag_service

	// Create chain with coordinator on brg_dawnstar
	chain := domain.Task_Chain{
		chain_id                      = chain_id,
		owner_user_id                 = owner,
		title                         = "Bridge Pinning Chain",
		publish_state                 = .Published,
		status                        = .Active,
		kind                          = "test",
		coordinator_agent_instance_id = "inst_coord_pin",
		created_at                    = "2026-09-23T10:00:00Z",
		updated_at                    = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.taskchain_save_chain(&tc_repo, chain)

	coord_inst := domain.Agent_Instance{
		agent_instance_id = "inst_coord_pin",
		owner_user_id     = owner,
		agent_id          = "agt_coordinator",
		bridge_id         = "brg_dawnstar",
		project_id        = domain.Project_ID("prj_pin"),
		display_name      = "coordinator",
		runtime_status    = "running",
		chain_id          = string(chain_id),
		created_at        = "2026-09-23T10:00:00Z",
		updated_at        = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, coord_inst)

	// Pre-create an IDLE instance on brg_dawnstar of agt_pinned_worker
	dawnstar_inst := domain.Agent_Instance{
		agent_instance_id = "inst_worker_dawnstar",
		owner_user_id     = owner,
		agent_id          = "agt_pinned_worker",
		bridge_id         = "brg_dawnstar",
		project_id        = domain.Project_ID("prj_pin"),
		display_name      = "dawnstar worker",
		runtime_status    = "idle",
		chain_id          = string(chain_id),
		created_at        = "2026-09-23T10:00:00Z",
		updated_at        = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, dawnstar_inst)
	_, _, _ = iface.taskchain_save_member(&tc_repo, domain.Task_Chain_Member{
		chain_id          = chain_id,
		agent_instance_id = "inst_worker_dawnstar",
		agent_id          = "agt_pinned_worker",
		owner_user_id     = owner,
		role              = "worker",
		created_at        = "2026-09-23T10:00:00Z",
	})

	// Fleet capacity = 1 for agt_pinned_worker.
	// Note: inst_worker_dawnstar already exists, so if capacity were global, capacity=1 would be reached.
	// But because the task is pinned to brg_riverwood, live_count is scoped to brg_riverwood (which is 0),
	// allowing JIT provisioning on brg_riverwood.
	fleet := domain.Task_Chain_Fleet{
		task_chain_id    = chain_id,
		agent_id         = "agt_pinned_worker",
		capacity         = 1,
		min_warm         = 0,
		idle_ttl_seconds = 300,
		provider         = "claude",
		model             = "claude-sonnet-5-5",
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:00:00Z",
	}
	_, _ = iface.taskchain_upsert_fleet(&tc_repo, fleet)

	// Create Task pinned to brg_riverwood
	task1 := domain.Task{
		task_id            = "task_riverwood_1",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "Riverwood Task",
		publish_state      = .Published,
		status             = .Assigned,
		priority           = .P1,
		assignee_ref_json  = `{"type":"agent_id","agent_id":"agt_pinned_worker"}`,
		reviewer_refs_json = "[]",
		bridge_id          = "brg_riverwood",
		created_at         = "2026-09-23T10:01:00Z",
		updated_at         = "2026-09-23T10:01:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, task1)

	// Run reconcile_chain
	promoted := reconcile_chain(&svc, chain)
	testing.expect_value(t, promoted, 1)

	// Verify Task 1 was NOT assigned to inst_worker_dawnstar (which was idle on brg_dawnstar)
	saved_t1, _, _ := iface.taskchain_get_task(&tc_repo, "task_riverwood_1")
	testing.expect(t, !strings.contains(saved_t1.assignee_ref_json, "inst_worker_dawnstar"), "pinned task must NOT be assigned to idle instance on wrong bridge")

	// Verify Task 1 was assigned to a JIT provisioned instance on brg_riverwood
	assignee_id := primary_assignee_instance(saved_t1.assignee_ref_json)
	defer delete(assignee_id)
	testing.expect(t, assignee_id != "", "task must have an assignee instance")
	testing.expect(t, assignee_id != "inst_worker_dawnstar", "assignee must be the newly provisioned instance")

	jit_inst, j_ok, _ := iface.agent_get_instance(&ag_repo, assignee_id)
	testing.expect(t, j_ok, "JIT instance must exist in agent repo")
	testing.expect_value(t, jit_inst.bridge_id, "brg_riverwood")

	// Verify inst_worker_dawnstar current task remains empty
	dawnstar_check, _, _ := iface.agent_get_instance(&ag_repo, "inst_worker_dawnstar")
	testing.expect_value(t, dawnstar_check.current_task_id, "")
}

@(test)
test_reconcile_chain_focus_selection_skips_mismatched_bridge :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_fleet_focus_bridge_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, _ := sqlite.open(db_path)
	testing.expect(t, open_ok, "sqlite open ok")
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

	owner := domain.User_ID("user_focus_test")
	chain_id := domain.Task_Chain_ID("chain_focus_test")

	chain := domain.Task_Chain{
		chain_id      = chain_id,
		owner_user_id = owner,
		title         = "Focus Bridge Chain",
		publish_state = .Published,
		status        = .Active,
		kind          = "test",
		created_at    = "2026-09-23T10:00:00Z",
		updated_at    = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.taskchain_save_chain(&tc_repo, chain)

	// Instance on brg_dawnstar
	inst := domain.Agent_Instance{
		agent_instance_id = "inst_on_dawnstar",
		owner_user_id     = owner,
		agent_id          = "agt_worker",
		bridge_id         = "brg_dawnstar",
		display_name      = "worker",
		runtime_status    = "idle",
		chain_id          = string(chain_id),
		created_at        = "2026-09-23T10:00:00Z",
		updated_at        = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, inst)
	_, _, _ = iface.taskchain_save_member(&tc_repo, domain.Task_Chain_Member{
		chain_id          = chain_id,
		agent_instance_id = "inst_on_dawnstar",
		agent_id          = "agt_worker",
		owner_user_id     = owner,
		role              = "worker",
		created_at        = "2026-09-23T10:00:00Z",
	})

	// Task 1: assigned to inst_on_dawnstar, but pinned to brg_riverwood!
	// It is In_Progress.
	t1 := domain.Task{
		task_id           = "task_pinned_riverwood",
		chain_id          = chain_id,
		owner_user_id     = owner,
		title             = "Pinned Task",
		publish_state     = .Published,
		status            = .In_Progress,
		priority          = .P0,
		assignee_ref_json = `{"type":"agent_instance","agent_instance_id":"inst_on_dawnstar"}`,
		bridge_id         = "brg_riverwood",
		created_at        = "2026-09-23T10:00:00Z",
		updated_at        = "2026-09-23T10:00:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, t1)

	// Task 2: assigned to inst_on_dawnstar, unpinned (bridge_id = "")
	// It is Assigned.
	t2 := domain.Task{
		task_id           = "task_unpinned_local",
		chain_id          = chain_id,
		owner_user_id     = owner,
		title             = "Unpinned Task",
		publish_state     = .Published,
		status            = .Assigned,
		priority          = .P1,
		assignee_ref_json = `{"type":"agent_instance","agent_instance_id":"inst_on_dawnstar"}`,
		bridge_id         = "",
		created_at        = "2026-09-23T10:01:00Z",
		updated_at        = "2026-09-23T10:01:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, t2)

	_ = reconcile_chain(&svc, chain)

	// 1. Task 1 (pinned to brg_riverwood) must NOT be selected as focus for inst_on_dawnstar
	// and must be demoted to Queued because it's not the chosen work task.
	saved_t1, _, _ := iface.taskchain_get_task(&tc_repo, "task_pinned_riverwood")
	testing.expect_value(t, saved_t1.status, domain.Task_Status.Queued)

	// 2. Task 2 (unpinned) is selected and promoted to In_Progress.
	saved_t2, _, _ := iface.taskchain_get_task(&tc_repo, "task_unpinned_local")
	testing.expect_value(t, saved_t2.status, domain.Task_Status.In_Progress)

	// 3. inst_on_dawnstar focus is Task 2.
	saved_inst, _, _ := iface.agent_get_instance(&ag_repo, "inst_on_dawnstar")
	testing.expect_value(t, saved_inst.current_task_id, "task_unpinned_local")
	testing.expect_value(t, saved_inst.current_task_role, domain.Current_Task_Role.Work)
}

@(test)
test_create_and_update_task_rejects_mismatched_agent_instance_bridge :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_fleet_crud_bridge_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, _ := sqlite.open(db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	defer sqlite.close(&conn)

	mig_ok, _ := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")

	tc_impl := sqlite.Taskchain_Repo_SQLite{conn = &conn}
	tc_repo := sqlite.new_taskchain_repository(&tc_impl, &conn)

	ag_impl := sqlite.Agent_Repo_SQLite{conn = &conn}
	ag_repo := sqlite.new_agent_repository(&ag_impl, &conn)

	br_impl := sqlite.Bridge_Repo_SQLite{conn = &conn}
	br_repo := sqlite.new_bridge_repository(&br_impl, &conn)

	clock := platform.real_clock()
	ids := platform.real_id_generator()

	ag_svc := agent_service.new_agent_service(&ag_repo, &br_repo, &clock, &ids)
	svc := new_taskchain_service(&tc_repo, &ag_repo, &clock, &ids)
	svc.agent_service = &ag_svc

	owner := domain.User_ID("user_crud_bridge")
	cid := domain.Task_Chain_ID("chain_crud_bridge")

	// Bridges
	_, _, _ = iface.bridge_save_bridge(&br_repo, domain.Bridge{
		bridge_id        = "brg_dawnstar",
		owner_user_id    = owner,
		machine_hostname = "dawnstar",
		status           = .Online,
		created_at       = "2026-09-25T10:00:00Z",
		updated_at       = "2026-09-25T10:00:00Z",
	})
	_, _, _ = iface.bridge_save_bridge(&br_repo, domain.Bridge{
		bridge_id        = "brg_riverwood",
		owner_user_id    = owner,
		machine_hostname = "riverwood",
		status           = .Online,
		created_at       = "2026-09-25T10:00:00Z",
		updated_at       = "2026-09-25T10:00:00Z",
	})

	// Chain
	_, _, _ = iface.taskchain_save_chain(&tc_repo, domain.Task_Chain{
		chain_id      = cid,
		owner_user_id = owner,
		title         = "CRUD Bridge Chain",
		publish_state = .Published,
		status        = .Active,
		kind          = "test",
		created_at    = "2026-09-25T10:00:00Z",
		updated_at    = "2026-09-25T10:00:00Z",
	})

	// Instances
	inst_dawnstar := domain.Agent_Instance{
		agent_instance_id = "inst_dawnstar_1",
		owner_user_id     = owner,
		agent_id          = "agt_worker",
		bridge_id         = "brg_dawnstar",
		chain_id          = string(cid),
		created_at        = "2026-09-25T10:00:00Z",
		updated_at        = "2026-09-25T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, inst_dawnstar)
	_, _, _ = iface.taskchain_save_member(&tc_repo, domain.Task_Chain_Member{
		chain_id          = cid,
		agent_instance_id = "inst_dawnstar_1",
		agent_id          = "agt_worker",
		owner_user_id     = owner,
		role              = "worker",
		created_at        = "2026-09-25T10:00:00Z",
	})

	inst_riverwood := domain.Agent_Instance{
		agent_instance_id = "inst_riverwood_1",
		owner_user_id     = owner,
		agent_id          = "agt_worker",
		bridge_id         = "brg_riverwood",
		chain_id          = string(cid),
		created_at        = "2026-09-25T10:00:00Z",
		updated_at        = "2026-09-25T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, inst_riverwood)
	_, _, _ = iface.taskchain_save_member(&tc_repo, domain.Task_Chain_Member{
		chain_id          = cid,
		agent_instance_id = "inst_riverwood_1",
		agent_id          = "agt_worker",
		owner_user_id     = owner,
		role              = "worker",
		created_at        = "2026-09-25T10:00:00Z",
	})

	auth := contracts.Auth_Context{kind = .User_Token, user_id = string(owner)}

	// 1. Create task with bridge_id="brg_riverwood" and assignee="inst_dawnstar_1": REJECT with Conflict
	_, c_err_ok, c_err := create_task(&svc, auth, Create_Task_Input{
		chain_id          = cid,
		title             = "Mismatched Task",
		bridge_id         = "brg_riverwood",
		assignee_ref_json = `{"type":"agent_instance","agent_instance_id":"inst_dawnstar_1"}`,
	})
	testing.expect(t, !c_err_ok, "create_task with mismatched bridge must fail")
	testing.expect_value(t, c_err.code, domain.Error_Code.Conflict)

	// 2. Create task with bridge_id="brg_riverwood" and matching assignee="inst_riverwood_1": SUCCESS
	task_created, c_ok, _ := create_task(&svc, auth, Create_Task_Input{
		chain_id          = cid,
		title             = "Matching Task",
		bridge_id         = "brg_riverwood",
		assignee_ref_json = `{"type":"agent_instance","agent_instance_id":"inst_riverwood_1"}`,
	})
	testing.expect(t, c_ok, "create_task with matching bridge must succeed")
	testing.expect_value(t, task_created.bridge_id, "brg_riverwood")

	// 3. Update task to reassign to inst_dawnstar_1 (bridge mismatch): REJECT with Conflict
	_, u_err_ok, u_err := update_task(&svc, auth, task_created.task_id, Update_Task_Input{
		assignee_ref_json = `{"type":"agent_instance","agent_instance_id":"inst_dawnstar_1"}`,
	})
	testing.expect(t, !u_err_ok, "update_task reassigning to mismatched bridge instance must fail")
	testing.expect_value(t, u_err.code, domain.Error_Code.Conflict)

	// 4. Update task to repin bridge to "brg_dawnstar" (while assignee is inst_riverwood_1): REJECT with Conflict
	repin_dawnstar := "brg_dawnstar"
	_, u_repin_ok, u_repin_err := update_task(&svc, auth, task_created.task_id, Update_Task_Input{
		bridge_id = &repin_dawnstar,
	})
	testing.expect(t, !u_repin_ok, "update_task repinning to mismatched bridge must fail")
	testing.expect_value(t, u_repin_err.code, domain.Error_Code.Conflict)

	// 5. Update task to clear bridge pin (bridge_id = ""): SUCCESS
	clear_bridge := ""
	cleared_task, u_clear_ok, _ := update_task(&svc, auth, task_created.task_id, Update_Task_Input{
		bridge_id = &clear_bridge,
	})
	testing.expect(t, u_clear_ok, "update_task clearing bridge pin must succeed")
	testing.expect_value(t, cleared_task.bridge_id, "")
}

@(test)
test_fsm_unified_atomic_start_and_jit_instance_binding :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_fsm_atomic_start_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer sqlite.close(&conn)

	mig_ok, mig_err := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	tc_impl := sqlite.Taskchain_Repo_SQLite{conn = &conn}
	tc_repo := sqlite.new_taskchain_repository(&tc_impl, &conn)

	ag_impl := sqlite.Agent_Repo_SQLite{conn = &conn}
	ag_repo := sqlite.new_agent_repository(&ag_impl, &conn)

	br_impl := sqlite.Bridge_Repo_SQLite{conn = &conn}
	br_repo := sqlite.new_bridge_repository(&br_impl, &conn)

	pr_impl := sqlite.Project_Repo_SQLite{conn = &conn}
	pr_repo := sqlite.new_project_repository(&pr_impl, &conn)

	co_impl := sqlite.Content_Repo_SQLite{conn = &conn}
	co_repo := sqlite.new_content_repository(&co_impl, &conn)

	provider_impl := sqlite.Provider_Repo_SQLite{conn = &conn}
	providers := sqlite.new_provider_repository(&provider_impl, &conn)

	clock := platform.real_clock()
	ids := platform.real_id_generator()

	owner := domain.User_ID("user_fsm_atomic")
	chain_id := domain.Task_Chain_ID("chain_fsm_atomic_test")

	// Set up Bridge in repo
	bridge := domain.Bridge{
		bridge_id         = "brg_atomic",
		owner_user_id     = owner,
		machine_hostname  = "localhost",
		status            = .Online,
		capabilities_json = `{"capabilities":[{"provider":"claude","models":["claude-fable-5-1","claude-opus-5-5","claude-sonnet-5-5"],"default_model":"claude-sonnet-5-5"}],"provider":"claude","default_model":"claude-sonnet-5-5"}`,
		created_at        = "2026-10-01T10:00:00Z",
		updated_at        = "2026-10-01T10:00:00Z",
	}
	_, _, _ = iface.bridge_save_bridge(&br_repo, bridge)
	_, _ = iface.bridge_provider_status_upsert(&providers, domain.Bridge_Provider_Status{bridge_id = "brg_atomic", provider = "claude", state = "present"})
	_, _ = iface.bridge_provider_setting_upsert(&providers, domain.Bridge_Provider_Setting{bridge_id = "brg_atomic", provider = "claude", enabled = true})

	project := domain.Project{
		project_id    = domain.Project_ID("prj_atomic"),
		owner_user_id = owner,
		name          = "Atomic Project",
		slug          = "atomic-project",
		default_path  = "/srv/atomic/default",
		state         = .Active,
		created_at    = "2026-10-01T10:00:00Z",
		updated_at    = "2026-10-01T10:00:00Z",
	}
	_, _, _ = iface.project_save(&pr_repo, project)
	_, _, _ = iface.project_save_bridge_path(&pr_repo, domain.Project_Bridge_Path{
		project_id    = project.project_id,
		bridge_id     = "brg_atomic",
		owner_user_id = owner,
		path          = "/srv/atomic/primary",
		created_at    = "2026-10-01T10:00:00Z",
		updated_at    = "2026-10-01T10:00:00Z",
	})

	// Set up Agent in repo
	worker_agent := domain.Agent{
		agent_id         = "agt_fsm_worker",
		owner_user_id    = owner,
		name             = "Atomic Worker",
		slug             = "atomic-worker",
		created_at       = "2026-10-01T10:00:00Z",
		updated_at       = "2026-10-01T10:00:00Z",
	}
	_, _, _ = iface.agent_save(&ag_repo, worker_agent)

	support := domain.Agent_Bridge_Support{
		agent_id      = "agt_fsm_worker",
		bridge_id     = "brg_atomic",
		owner_user_id = owner,
		enabled       = true,
	}
	_, _, _ = iface.agent_save_support(&ag_repo, support)

	registry := project_service.Bridge_Runtime_Registry{}
	project_service.bridge_runtime_registry_mark_live(&registry, "brg_atomic", false, "")

	captured_cmds := make([dynamic]project_service.Runtime_Command)
	defer {
		for cmd in captured_cmds do delete(cmd.body_json)
		delete(captured_cmds)
	}
	sink := project_service.Bridge_Command_Sink{
		ctx = rawptr(&captured_cmds),
		send_runtime_command = proc(ctx: rawptr, cmd: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
			commands := (^[dynamic]project_service.Runtime_Command)(ctx)
			captured := cmd
			captured.body_json = strings.clone(cmd.body_json)
			append(commands, captured)
			return true, domain.Domain_Error{}
		},
	}

	svc := new_taskchain_service_with_runtime(&tc_repo, &ag_repo, sink, &clock, &ids)
	ag_service := agent_service.new_agent_service_with_runtime(&ag_repo, &br_repo, &pr_repo, &co_repo, &tc_repo, sink, &registry, &clock, &ids)
	ag_service.providers = &providers
	svc.agent_service = &ag_service

	// Create chain
	chain := domain.Task_Chain{
		chain_id                      = chain_id,
		owner_user_id                 = owner,
		title                         = "Atomic Start Chain",
		publish_state                 = .Published,
		status                        = .Active,
		kind                          = "test",
		coordinator_agent_instance_id = "inst_coord_atomic",
		created_at                    = "2026-10-01T10:00:00Z",
		updated_at                    = "2026-10-01T10:00:00Z",
	}
	_, _, _ = iface.taskchain_save_chain(&tc_repo, chain)

	coord_inst := domain.Agent_Instance{
		agent_instance_id = "inst_coord_atomic",
		owner_user_id     = owner,
		agent_id          = "agt_coordinator",
		bridge_id         = "brg_atomic",
		project_id        = domain.Project_ID("prj_atomic"),
		display_name      = "coordinator #1",
		runtime_status    = "running",
		chain_id          = string(chain_id),
		created_at        = "2026-10-01T10:00:00Z",
		updated_at        = "2026-10-01T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, coord_inst)

	// Fleet capacity = 2
	fleet := domain.Task_Chain_Fleet{
		task_chain_id    = chain_id,
		agent_id         = "agt_fsm_worker",
		capacity         = 2,
		min_warm         = 1,
		idle_ttl_seconds = 300,
		provider         = "claude",
		model             = "claude-sonnet-5-5",
		created_at       = "2026-10-01T10:00:00Z",
		updated_at       = "2026-10-01T10:00:00Z",
	}
	_, _ = iface.taskchain_upsert_fleet(&tc_repo, fleet)

	// Create an idle worker instance in warm pool
	w1_inst := domain.Agent_Instance{
		agent_instance_id = "inst_worker_idle",
		owner_user_id     = owner,
		agent_id          = "agt_fsm_worker",
		bridge_id         = "brg_atomic",
		display_name      = "idle worker",
		runtime_status    = "idle",
		chain_id          = string(chain_id),
		created_at        = "2026-10-01T10:00:00Z",
		updated_at        = "2026-10-01T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, w1_inst)
	w1_member := domain.Task_Chain_Member{
		chain_id          = chain_id,
		agent_instance_id = "inst_worker_idle",
		agent_id          = "agt_fsm_worker",
		owner_user_id     = owner,
		role              = "worker",
		created_at        = "2026-10-01T10:00:00Z",
	}
	_, _, _ = iface.taskchain_save_member(&tc_repo, w1_member)

	auth_user := contracts.Auth_Context{kind = .User_Token, user_id = string(owner)}

	// 1. Create task targeting declarative agent_id
	t1 := domain.Task{
		task_id            = "task_role_1",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "Role Task 1",
		publish_state      = .Published,
		status             = .Assigned,
		priority           = .P1,
		assignee_ref_json  = `{"type":"agent_id","agent_id":"agt_fsm_worker"}`,
		reviewer_refs_json = "[]",
		created_at         = "2026-10-01T10:01:00Z",
		updated_at         = "2026-10-01T10:01:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, t1)

	// Transition t1 to .In_Progress via change_task_status
	// Acceptance Criterion:
	// - Automatically allocates idle warm pool instance and binds it to assignee_ref
	// - Returned task row contains bound agent_instance_id
	// - No manual reconcile required for instance to be bound and started
	ret1, ok1, err1 := change_task_status(&svc, auth_user, "task_role_1", .In_Progress)
	testing.expect(t, ok1, "change_task_status to In_Progress must succeed")
	testing.expect_value(t, err1.code, domain.Error_Code.None)
	testing.expect_value(t, ret1.status, domain.Task_Status.In_Progress)

	bound_inst1 := primary_assignee_instance(ret1.assignee_ref_json)
	defer delete(bound_inst1)
	testing.expect_value(t, bound_inst1, "inst_worker_idle")

	// Persisted row verification
	persisted1, p1_ok, _ := iface.taskchain_get_task(&tc_repo, "task_role_1")
	testing.expect(t, p1_ok, "task 1 must be persisted")
	testing.expect_value(t, persisted1.status, domain.Task_Status.In_Progress)
	db_inst1 := primary_assignee_instance(persisted1.assignee_ref_json)
	defer delete(db_inst1)
	testing.expect_value(t, db_inst1, "inst_worker_idle")

	// Verify inst_worker_idle focus was automatically updated to task_role_1 without manual reconcile
	updated_w1, _, _ := iface.agent_get_instance(&ag_repo, "inst_worker_idle")
	testing.expect_value(t, updated_w1.current_task_id, "task_role_1")
	testing.expect_value(t, updated_w1.current_task_role, domain.Current_Task_Role.Work)

	// 2. Create second task targeting declarative agent_id while inst_worker_idle is busy
	t2 := domain.Task{
		task_id            = "task_role_2",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "Role Task 2 (JIT)",
		publish_state      = .Published,
		status             = .Assigned,
		priority           = .P1,
		assignee_ref_json  = `{"type":"agent_id","agent_id":"agt_fsm_worker"}`,
		reviewer_refs_json = "[]",
		created_at         = "2026-10-01T10:02:00Z",
		updated_at         = "2026-10-01T10:02:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, t2)

	// Transition t2 to .In_Progress via change_task_status
	// Acceptance Criterion:
	// - Since inst_worker_idle is busy, JIT-provisions new instance (live_count 1 < capacity 2)
	// - Binds newly provisioned instance to task row and returns it
	ret2, ok2, err2 := change_task_status(&svc, auth_user, "task_role_2", .In_Progress)
	testing.expect(t, ok2, "change_task_status for JIT task must succeed")
	testing.expect_value(t, err2.code, domain.Error_Code.None)
	testing.expect_value(t, ret2.status, domain.Task_Status.In_Progress)

	bound_inst2 := primary_assignee_instance(ret2.assignee_ref_json)
	defer delete(bound_inst2)
	testing.expect(t, bound_inst2 != "", "must bind a provisioned instance")
	testing.expect(t, bound_inst2 != "inst_worker_idle", "must provision a distinct instance from busy worker")

	persisted2, p2_ok, _ := iface.taskchain_get_task(&tc_repo, "task_role_2")
	testing.expect(t, p2_ok, "task 2 must be persisted")
	db_inst2 := primary_assignee_instance(persisted2.assignee_ref_json)
	defer delete(db_inst2)
	testing.expect_value(t, db_inst2, bound_inst2)

	jit_inst, j_ok, _ := iface.agent_get_instance(&ag_repo, bound_inst2)
	testing.expect(t, j_ok, "provisioned JIT instance must exist in agent repository")
	testing.expect_value(t, jit_inst.current_task_id, "task_role_2")
	testing.expect_value(t, jit_inst.current_task_role, domain.Current_Task_Role.Work)

	// 3. Dynamic fleet schedule healing test
	// Create task directly in .In_Progress missing an instance
	t3 := domain.Task{
		task_id            = "task_role_3_healed",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "Role Task 3 (Orphan Healed)",
		publish_state      = .Published,
		status             = .In_Progress,
		priority           = .P0,
		assignee_ref_json  = `{"type":"agent_id","agent_id":"agt_fsm_worker"}`,
		reviewer_refs_json = "[]",
		created_at         = "2026-10-01T10:03:00Z",
		updated_at         = "2026-10-01T10:03:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, t3)

	// Free inst_worker_idle by completing task 1
	ret1.status = .Completed
	ret1.completed_at = "2026-10-01T10:04:00Z"
	_, _, _ = iface.taskchain_save_task(&tc_repo, ret1)

	// Now dynamic_fleet_schedule should heal task_role_3_healed by binding it to inst_worker_idle
	tasks_all, _ := iface.taskchain_list_tasks_by_chain(&tc_repo, chain_id, owner)
	defer delete(tasks_all)
	deps_all, _ := iface.taskchain_list_dependencies_by_chain(&tc_repo, chain_id, owner)
	defer delete(deps_all)
	offline_map := make(map[domain.Task_ID]bool)
	defer delete(offline_map)

	modified := dynamic_fleet_schedule(&svc, chain, tasks_all[:], deps_all[:], offline_map)
	testing.expect(t, modified, "dynamic_fleet_schedule must heal In_Progress task missing instance")

	persisted3, p3_ok, _ := iface.taskchain_get_task(&tc_repo, "task_role_3_healed")
	testing.expect(t, p3_ok, "task 3 must exist")
	testing.expect_value(t, persisted3.status, domain.Task_Status.In_Progress)
	db_inst3 := primary_assignee_instance(persisted3.assignee_ref_json)
	defer delete(db_inst3)
	testing.expect_value(t, db_inst3, "inst_worker_idle")
}

@(test)
test_fsm_recovery_matrix_no_dead_ends :: proc(t: ^testing.T) {
	// Verify that every Task_Status value provides valid allowed_actions and allowed_transitions
	// ("No Dead-Ends" invariant).
	all_statuses := []domain.Task_Status{
		.Assigned,
		.Queued,
		.In_Progress,
		.In_Validation,
		.Finishing,
		.Pausing,
		.Validated_Good,
		.Validated_Not_Good,
		.Paused,
		.Completed,
		.Cancelled,
	}

	for status in all_statuses {
		actions := domain.task_allowed_actions(status)
		testing.expect(t, len(actions) > 0, fmt.tprintf("allowed_actions must never be empty for status %v", status))

		transitions := domain.task_allowed_transitions(status)
		testing.expect(t, len(transitions) > 0, fmt.tprintf("allowed_transitions must never be empty for status %v", status))

		recovery := domain.task_recovery_actions(status)
		testing.expect(t, len(recovery) > 0, fmt.tprintf("recovery_actions must never be empty for status %v", status))
	}

	// Invariant test: degraded / unknown condition must also return non-empty recovery actions & transitions
	degraded_status := cast(domain.Task_Status)99
	degraded_actions := domain.task_allowed_actions(degraded_status)
	testing.expect(t, len(degraded_actions) > 0, "degraded status must have allowed_actions")
	testing.expect(t, len(degraded_actions) >= 3, "degraded status must offer multiple recovery actions")

	has_restart := false
	has_reset := false
	has_cancel := false
	for act in degraded_actions {
		if act == "restart" || act == "restart_worker" do has_restart = true
		if act == "reset_to_assigned" do has_reset = true
		if act == "cancel" do has_cancel = true
	}
	testing.expect(t, has_restart, "degraded actions must include restart/restart_worker")
	testing.expect(t, has_reset, "degraded actions must include reset_to_assigned")
	testing.expect(t, has_cancel, "degraded actions must include cancel")

	degraded_transitions := domain.task_allowed_transitions(degraded_status)
	testing.expect(t, len(degraded_transitions) > 0, "degraded status must have allowed_transitions")

	direct_degraded_actions := domain.task_degraded_recovery_actions()
	testing.expect(t, len(direct_degraded_actions) > 0, "task_degraded_recovery_actions must not be empty")

	direct_degraded_transitions := domain.task_degraded_recovery_transitions()
	testing.expect(t, len(direct_degraded_transitions) > 0, "task_degraded_recovery_transitions must not be empty")
}

@(test)
test_fsm_watchdog_auto_recovery_crashed_worker_respawn :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_fleet_crashed_respawn_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer sqlite.close(&conn)

	mig_ok, mig_err := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	tc_impl := sqlite.Taskchain_Repo_SQLite{conn = &conn}
	tc_repo := sqlite.new_taskchain_repository(&tc_impl, &conn)

	ag_impl := sqlite.Agent_Repo_SQLite{conn = &conn}
	ag_repo := sqlite.new_agent_repository(&ag_impl, &conn)

	br_impl := sqlite.Bridge_Repo_SQLite{conn = &conn}
	br_repo := sqlite.new_bridge_repository(&br_impl, &conn)

	pr_impl := sqlite.Project_Repo_SQLite{conn = &conn}
	pr_repo := sqlite.new_project_repository(&pr_impl, &conn)

	co_impl := sqlite.Content_Repo_SQLite{conn = &conn}
	co_repo := sqlite.new_content_repository(&co_impl, &conn)

	provider_impl := sqlite.Provider_Repo_SQLite{conn = &conn}
	providers := sqlite.new_provider_repository(&provider_impl, &conn)

	clock := platform.real_clock()
	ids := platform.real_id_generator()

	owner := domain.User_ID("user_fsm_recovery")
	chain_id := domain.Task_Chain_ID("chain_fsm_recovery")

	bridge := domain.Bridge{
		bridge_id         = "brg_recovery",
		owner_user_id     = owner,
		machine_hostname  = "localhost",
		status            = .Online,
		capabilities_json = `{"capabilities":[{"provider":"claude","models":["claude-fable-5-1","claude-opus-5-5","claude-sonnet-5-5"],"default_model":"claude-sonnet-5-5"}],"provider":"claude","default_model":"claude-sonnet-5-5"}`,
		created_at        = "2026-10-01T10:00:00Z",
		updated_at        = "2026-10-01T10:00:00Z",
	}
	_, _, _ = iface.bridge_save_bridge(&br_repo, bridge)
	_, _ = iface.bridge_provider_status_upsert(&providers, domain.Bridge_Provider_Status{bridge_id = "brg_recovery", provider = "claude", state = "present"})
	_, _ = iface.bridge_provider_setting_upsert(&providers, domain.Bridge_Provider_Setting{bridge_id = "brg_recovery", provider = "claude", enabled = true})

	project := domain.Project{
		project_id    = domain.Project_ID("prj_recovery"),
		owner_user_id = owner,
		name          = "Recovery Project",
		slug          = "recovery-project",
		default_path  = "/srv/recovery/default",
		state         = .Active,
		created_at    = "2026-10-01T10:00:00Z",
		updated_at    = "2026-10-01T10:00:00Z",
	}
	_, _, _ = iface.project_save(&pr_repo, project)
	_, _, _ = iface.project_save_bridge_path(&pr_repo, domain.Project_Bridge_Path{
		project_id    = project.project_id,
		bridge_id     = "brg_recovery",
		owner_user_id = owner,
		path          = "/srv/recovery/primary",
		created_at    = "2026-10-01T10:00:00Z",
		updated_at    = "2026-10-01T10:00:00Z",
	})

	worker_agent := domain.Agent{
		agent_id         = "agt_fsm_worker",
		owner_user_id    = owner,
		name             = "Recovery Worker",
		slug             = "recovery-worker",
		created_at       = "2026-10-01T10:00:00Z",
		updated_at       = "2026-10-01T10:00:00Z",
	}
	_, _, _ = iface.agent_save(&ag_repo, worker_agent)

	support := domain.Agent_Bridge_Support{
		agent_id      = "agt_fsm_worker",
		bridge_id     = "brg_recovery",
		owner_user_id = owner,
		enabled       = true,
	}
	_, _, _ = iface.agent_save_support(&ag_repo, support)

	registry := project_service.Bridge_Runtime_Registry{}
	project_service.bridge_runtime_registry_mark_live(&registry, "brg_recovery", false, "")

	captured_cmds := make([dynamic]project_service.Runtime_Command)
	defer {
		for cmd in captured_cmds do delete(cmd.body_json)
		delete(captured_cmds)
	}
	sink := project_service.Bridge_Command_Sink{
		ctx = rawptr(&captured_cmds),
		send_runtime_command = proc(ctx: rawptr, cmd: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
			commands := (^[dynamic]project_service.Runtime_Command)(ctx)
			captured := cmd
			captured.body_json = strings.clone(cmd.body_json)
			append(commands, captured)
			return true, domain.Domain_Error{}
		},
	}

	svc := new_taskchain_service_with_runtime(&tc_repo, &ag_repo, sink, &clock, &ids)
	ag_service := agent_service.new_agent_service_with_runtime(&ag_repo, &br_repo, &pr_repo, &co_repo, &tc_repo, sink, &registry, &clock, &ids)
	ag_service.providers = &providers
	svc.agent_service = &ag_service

	chain := domain.Task_Chain{
		chain_id                      = chain_id,
		owner_user_id                 = owner,
		title                         = "Watchdog Recovery Chain",
		publish_state                 = .Published,
		status                        = .Active,
		kind                          = "test",
		coordinator_agent_instance_id = "inst_coord_rec",
		created_at                    = "2026-10-01T10:00:00Z",
		updated_at                    = "2026-10-01T10:00:00Z",
	}
	_, _, _ = iface.taskchain_save_chain(&tc_repo, chain)

	coord_inst := domain.Agent_Instance{
		agent_instance_id = "inst_coord_rec",
		owner_user_id     = owner,
		agent_id          = "agt_coordinator",
		bridge_id         = "brg_recovery",
		project_id        = domain.Project_ID("prj_recovery"),
		display_name      = "coordinator",
		runtime_status    = "running",
		chain_id          = string(chain_id),
		created_at        = "2026-10-01T10:00:00Z",
		updated_at        = "2026-10-01T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, coord_inst)

	// Fleet capacity = 2, so when 1 crashes, another can be JIT provisioned
	fleet := domain.Task_Chain_Fleet{
		task_chain_id    = chain_id,
		agent_id         = "agt_fsm_worker",
		capacity         = 2,
		min_warm         = 1,
		idle_ttl_seconds = 300,
		provider         = "claude",
		model             = "claude-sonnet-5-5",
		created_at       = "2026-10-01T10:00:00Z",
		updated_at       = "2026-10-01T10:00:00Z",
	}
	_, _ = iface.taskchain_upsert_fleet(&tc_repo, fleet)

	// Create crashed worker instance
	crashed_inst := domain.Agent_Instance{
		agent_instance_id = "inst_worker_crashed",
		owner_user_id     = owner,
		agent_id          = "agt_fsm_worker",
		bridge_id         = "brg_recovery",
		project_id        = domain.Project_ID("prj_recovery"),
		display_name      = "crashed worker",
		runtime_status    = "failed",
		chain_id          = string(chain_id),
		created_at        = "2026-10-01T10:00:00Z",
		updated_at        = "2026-10-01T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, crashed_inst)

	// Create an In_Progress task bound to the crashed worker
	task := domain.Task{
		task_id            = "task_crashed_recovery",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "In Progress Task on Dead Worker",
		publish_state      = .Published,
		status             = .In_Progress,
		priority           = .P1,
		assignee_ref_json  = `{"type":"agent_instance","agent_instance_id":"inst_worker_crashed"}`,
		reviewer_refs_json = "[]",
		created_at         = "2026-10-01T10:01:00Z",
		updated_at         = "2026-10-01T10:01:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, task)

	tasks_all, _ := iface.taskchain_list_tasks_by_chain(&tc_repo, chain_id, owner)
	defer delete(tasks_all)
	deps_all, _ := iface.taskchain_list_dependencies_by_chain(&tc_repo, chain_id, owner)
	defer delete(deps_all)
	offline_map := make(map[domain.Task_ID]bool)
	defer delete(offline_map)

	// Run dynamic_fleet_schedule
	modified := dynamic_fleet_schedule(&svc, chain, tasks_all[:], deps_all[:], offline_map)
	testing.expect(t, modified, "watchdog must auto-heal In_Progress task on crashed worker")

	// Task must remain In_Progress but be rebound to a new healthy JIT provisioned instance
	persisted, p_ok, _ := iface.taskchain_get_task(&tc_repo, "task_crashed_recovery")
	testing.expect(t, p_ok, "task must exist")
	testing.expect_value(t, persisted.status, domain.Task_Status.In_Progress)

	new_inst_id := primary_assignee_instance(persisted.assignee_ref_json)
	defer delete(new_inst_id)
	testing.expect(t, new_inst_id != "", "task must have a new instance assigned")
	testing.expect(t, new_inst_id != "inst_worker_crashed", "task must NOT be assigned to crashed instance")

	// Verify the new instance is registered in the agent repository
	jit_inst, j_ok, _ := iface.agent_get_instance(&ag_repo, new_inst_id)
	testing.expect(t, j_ok, "newly provisioned instance must exist in agent repository")
	testing.expect(t, jit_inst.runtime_status == "running" || jit_inst.runtime_status == "launching", "newly provisioned instance must be running or launching")
}

@(test)
test_fsm_watchdog_auto_recovery_rebind_to_idle_worker :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_fleet_crashed_idle_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer sqlite.close(&conn)

	mig_ok, mig_err := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	tc_impl := sqlite.Taskchain_Repo_SQLite{conn = &conn}
	tc_repo := sqlite.new_taskchain_repository(&tc_impl, &conn)

	ag_impl := sqlite.Agent_Repo_SQLite{conn = &conn}
	ag_repo := sqlite.new_agent_repository(&ag_impl, &conn)

	clock := platform.real_clock()
	ids := platform.real_id_generator()
	svc := new_taskchain_service(&tc_repo, &ag_repo, &clock, &ids)

	owner := domain.User_ID("user_fsm_idle_rec")
	chain_id := domain.Task_Chain_ID("chain_fsm_idle_rec")

	chain := domain.Task_Chain{
		chain_id                      = chain_id,
		owner_user_id                 = owner,
		title                         = "Watchdog Rebind Chain",
		publish_state                 = .Published,
		status                        = .Active,
		kind                          = "test",
		coordinator_agent_instance_id = "inst_coord_idle",
		created_at                    = "2026-10-01T10:00:00Z",
		updated_at                    = "2026-10-01T10:00:00Z",
	}
	_, _, _ = iface.taskchain_save_chain(&tc_repo, chain)

	fleet := domain.Task_Chain_Fleet{
		task_chain_id    = chain_id,
		agent_id         = "agt_fsm_worker",
		capacity         = 2,
		min_warm         = 1,
		idle_ttl_seconds = 300,
		created_at       = "2026-10-01T10:00:00Z",
		updated_at       = "2026-10-01T10:00:00Z",
	}
	_, _ = iface.taskchain_upsert_fleet(&tc_repo, fleet)

	// Idle worker in warm pool
	idle_inst := domain.Agent_Instance{
		agent_instance_id = "inst_worker_healthy",
		owner_user_id     = owner,
		agent_id          = "agt_fsm_worker",
		bridge_id         = "brg_local",
		display_name      = "healthy worker",
		runtime_status    = "idle",
		chain_id          = string(chain_id),
		created_at        = "2026-10-01T10:00:00Z",
		updated_at        = "2026-10-01T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, idle_inst)

	// Crashed worker instance
	crashed_inst := domain.Agent_Instance{
		agent_instance_id = "inst_worker_dead",
		owner_user_id     = owner,
		agent_id          = "agt_fsm_worker",
		bridge_id         = "brg_local",
		display_name      = "dead worker",
		runtime_status    = "terminated",
		chain_id          = string(chain_id),
		created_at        = "2026-10-01T10:00:00Z",
		updated_at        = "2026-10-01T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, crashed_inst)

	// In_Progress task pointing to dead worker
	task := domain.Task{
		task_id            = "task_dead_rebind",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "In Progress Task on Terminated Worker",
		publish_state      = .Published,
		status             = .In_Progress,
		priority           = .P0,
		assignee_ref_json  = `{"type":"agent_instance","agent_instance_id":"inst_worker_dead"}`,
		reviewer_refs_json = "[]",
		created_at         = "2026-10-01T10:01:00Z",
		updated_at         = "2026-10-01T10:01:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, task)

	tasks_all, _ := iface.taskchain_list_tasks_by_chain(&tc_repo, chain_id, owner)
	defer delete(tasks_all)
	deps_all, _ := iface.taskchain_list_dependencies_by_chain(&tc_repo, chain_id, owner)
	defer delete(deps_all)
	offline_map := make(map[domain.Task_ID]bool)
	defer delete(offline_map)

	modified := dynamic_fleet_schedule(&svc, chain, tasks_all[:], deps_all[:], offline_map)
	testing.expect(t, modified, "watchdog must rebind task from dead worker to healthy worker")

	persisted, _, _ := iface.taskchain_get_task(&tc_repo, "task_dead_rebind")
	testing.expect_value(t, persisted.status, domain.Task_Status.In_Progress)
	rebound_inst := primary_assignee_instance(persisted.assignee_ref_json)
	defer delete(rebound_inst)
	testing.expect_value(t, rebound_inst, "inst_worker_healthy")
}

@(test)
test_fsm_watchdog_degraded_capacity_exhausted_surfaces_actionable_recovery :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_fleet_crashed_saturated_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer sqlite.close(&conn)

	mig_ok, mig_err := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	tc_impl := sqlite.Taskchain_Repo_SQLite{conn = &conn}
	tc_repo := sqlite.new_taskchain_repository(&tc_impl, &conn)

	ag_impl := sqlite.Agent_Repo_SQLite{conn = &conn}
	ag_repo := sqlite.new_agent_repository(&ag_impl, &conn)

	clock := platform.real_clock()
	ids := platform.real_id_generator()
	svc := new_taskchain_service(&tc_repo, &ag_repo, &clock, &ids)

	owner := domain.User_ID("user_fsm_sat")
	chain_id := domain.Task_Chain_ID("chain_fsm_sat")

	chain := domain.Task_Chain{
		chain_id                      = chain_id,
		owner_user_id                 = owner,
		title                         = "Watchdog Saturated Recovery Chain",
		publish_state                 = .Published,
		status                        = .Active,
		kind                          = "test",
		coordinator_agent_instance_id = "inst_coord_sat",
		created_at                    = "2026-10-01T10:00:00Z",
		updated_at                    = "2026-10-01T10:00:00Z",
	}
	_, _, _ = iface.taskchain_save_chain(&tc_repo, chain)

	// Capacity is 1, and the only slot is dead, and no JIT provider service configured
	fleet := domain.Task_Chain_Fleet{
		task_chain_id    = chain_id,
		agent_id         = "agt_fsm_worker",
		capacity         = 1,
		min_warm         = 1,
		idle_ttl_seconds = 300,
		created_at       = "2026-10-01T10:00:00Z",
		updated_at       = "2026-10-01T10:00:00Z",
	}
	_, _ = iface.taskchain_upsert_fleet(&tc_repo, fleet)

	crashed_inst := domain.Agent_Instance{
		agent_instance_id = "inst_worker_failed",
		owner_user_id     = owner,
		agent_id          = "agt_fsm_worker",
		bridge_id         = "brg_local",
		display_name      = "failed worker",
		runtime_status    = "failed",
		chain_id          = string(chain_id),
		created_at        = "2026-10-01T10:00:00Z",
		updated_at        = "2026-10-01T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, crashed_inst)

	task := domain.Task{
		task_id            = "task_sat_recovery",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "In Progress Task Needing Recovery",
		publish_state      = .Published,
		status             = .In_Progress,
		priority           = .P1,
		assignee_ref_json  = `{"type":"agent_instance","agent_instance_id":"inst_worker_failed"}`,
		reviewer_refs_json = "[]",
		created_at         = "2026-10-01T10:01:00Z",
		updated_at         = "2026-10-01T10:01:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, task)

	tasks_all, _ := iface.taskchain_list_tasks_by_chain(&tc_repo, chain_id, owner)
	defer delete(tasks_all)
	deps_all, _ := iface.taskchain_list_dependencies_by_chain(&tc_repo, chain_id, owner)
	defer delete(deps_all)
	offline_map := make(map[domain.Task_ID]bool)
	defer delete(offline_map)

	modified := dynamic_fleet_schedule(&svc, chain, tasks_all[:], deps_all[:], offline_map)
	testing.expect(t, modified, "watchdog must surface actionable recovery status")

	// Task must be demoted to Queued (actionable recovery status, not stuck in In_Progress on dead worker)
	persisted, _, _ := iface.taskchain_get_task(&tc_repo, "task_sat_recovery")
	testing.expect_value(t, persisted.status, domain.Task_Status.Queued)
	// Allowed actions for Queued are non-empty and actionable
	actions := domain.task_allowed_actions(persisted.status)
	testing.expect(t, len(actions) > 0, "queued status must have allowed actions")
}

@(test)
test_finishing_state_and_coordinator_notifications :: proc(t: ^testing.T) {
	testing.expect(t, valid_task_transition(.In_Validation, .Finishing), "in_validation -> finishing must be valid")
	testing.expect(t, valid_task_transition(.Finishing, .Completed), "finishing -> completed must be valid")
	testing.expect(t, work_status_is_actionable(.Finishing), "finishing must be an actionable work status")

	db_path := fmt.tprintf("/tmp/test_finishing_state_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer sqlite.close(&conn)

	mig_ok, mig_err := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	tc_impl := sqlite.Taskchain_Repo_SQLite{conn = &conn}
	tc_repo := sqlite.new_taskchain_repository(&tc_impl, &conn)

	ag_impl := sqlite.Agent_Repo_SQLite{conn = &conn}
	ag_repo := sqlite.new_agent_repository(&ag_impl, &conn)

	clock := platform.real_clock()
	ids := platform.real_id_generator()

	captured_cmds := make([dynamic]project_service.Runtime_Command)
	defer {
		for cmd in captured_cmds do delete(cmd.body_json)
		delete(captured_cmds)
	}
	sink := project_service.Bridge_Command_Sink{
		ctx = rawptr(&captured_cmds),
		send_runtime_command = proc(ctx: rawptr, cmd: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
			commands := (^[dynamic]project_service.Runtime_Command)(ctx)
			captured := cmd
			captured.body_json = strings.clone(cmd.body_json)
			append(commands, captured)
			return true, domain.Domain_Error{}
		},
	}

	svc := new_taskchain_service_with_runtime(&tc_repo, &ag_repo, sink, &clock, &ids)

	owner := domain.User_ID("user_finishing_test")
	chain_id := domain.Task_Chain_ID("chain_finishing_test")

	chain := domain.Task_Chain{
		chain_id                      = chain_id,
		owner_user_id                 = owner,
		title                         = "Finishing Chain",
		description                   = "Testing finishing state",
		publish_state                 = .Published,
		status                        = .Active,
		kind                          = "test",
		coordinator_agent_instance_id = "inst_coord",
		default_reviewer_refs_json    = "[]",
		created_at                    = "2026-10-02T10:00:00Z",
		updated_at                    = "2026-10-02T10:00:00Z",
	}
	_, _, _ = iface.taskchain_save_chain(&tc_repo, chain)

	coord_inst := domain.Agent_Instance{
		agent_instance_id = "inst_coord",
		owner_user_id     = owner,
		agent_id          = "agt_coord",
		bridge_id         = "brg_test",
		display_name      = "coordinator",
		runtime_status    = "running",
		chain_id          = string(chain_id),
		created_at        = "2026-10-02T10:00:00Z",
		updated_at        = "2026-10-02T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, coord_inst)

	worker_inst := domain.Agent_Instance{
		agent_instance_id = "inst_worker",
		owner_user_id     = owner,
		agent_id          = "agt_worker",
		bridge_id         = "brg_test",
		display_name      = "worker",
		runtime_status    = "running",
		chain_id          = string(chain_id),
		created_at        = "2026-10-02T10:00:00Z",
		updated_at        = "2026-10-02T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, worker_inst)

	reviewer_inst := domain.Agent_Instance{
		agent_instance_id = "inst_reviewer",
		owner_user_id     = owner,
		agent_id          = "agt_reviewer",
		bridge_id         = "brg_test",
		display_name      = "reviewer",
		runtime_status    = "running",
		chain_id          = string(chain_id),
		created_at        = "2026-10-02T10:00:00Z",
		updated_at        = "2026-10-02T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, reviewer_inst)
	_, _, _ = iface.taskchain_save_member(&tc_repo, domain.Task_Chain_Member{
		chain_id          = chain_id,
		agent_instance_id = "inst_coord",
		agent_id          = "agt_coord",
		owner_user_id     = owner,
		role              = "coordinator",
		created_at        = "2026-10-02T10:00:00Z",
	})
	_, _, _ = iface.taskchain_save_member(&tc_repo, domain.Task_Chain_Member{
		chain_id          = chain_id,
		agent_instance_id = "inst_worker",
		agent_id          = "agt_worker",
		owner_user_id     = owner,
		role              = "worker",
		created_at        = "2026-10-02T10:00:00Z",
	})
	_, _, _ = iface.taskchain_save_member(&tc_repo, domain.Task_Chain_Member{
		chain_id          = chain_id,
		agent_instance_id = "inst_reviewer",
		agent_id          = "agt_reviewer",
		owner_user_id     = owner,
		role              = "reviewer",
		created_at        = "2026-10-02T10:00:00Z",
	})

	task := domain.Task{
		task_id            = "task_finish_1",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "Finishing Feature Task",
		description        = "Finish me",
		publish_state      = .Published,
		status             = .In_Validation,
		priority           = .P1,
		assignee_ref_json  = `{"type":"agent_instance","agent_instance_id":"inst_worker"}`,
		reviewer_refs_json = `[{"type":"agent_instance","agent_instance_id":"inst_reviewer"}]`,
		created_at         = "2026-10-02T10:01:00Z",
		updated_at         = "2026-10-02T10:01:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, task)

	auth_rev := contracts.Auth_Context{kind = .Instance_Token, user_id = string(owner), agent_instance_id = "inst_reviewer"}
	vote_res, vote_ok, vote_err := record_task_vote(&svc, auth_rev, Vote_Input{
		task_id = "task_finish_1",
		vote    = "lgtm",
		comment = "all tests passed",
	})
	testing.expect(t, vote_ok, "record_task_vote lgtm must succeed")
	testing.expect_value(t, vote_err.code, domain.Error_Code.None)

	persisted, get_ok, _ := iface.taskchain_get_task(&tc_repo, "task_finish_1")
	testing.expect(t, get_ok, "task must exist")
	testing.expect_value(t, persisted.status, domain.Task_Status.Finishing)
	testing.expect_value(t, persisted.completed_at, "")

	found_assignee_finishing := false
	found_coord_finishing := false
	for cmd in captured_cmds {
		if strings.contains(cmd.body_json, `"agent_instance_id":"inst_worker"`) &&
		   strings.contains(cmd.body_json, `"action":"finishing"`) &&
		   strings.contains(cmd.body_json, `"interrupt":true`) &&
		   strings.contains(cmd.body_json, "is approved — please wrap up and complete") &&
		   strings.contains(cmd.body_json, "wrap up, commit/push changes, then run './.heimdall/bin/ham-ctl task status task_finish_1 --status completed'") {
			found_assignee_finishing = true
		}
		if strings.contains(cmd.body_json, `"agent_instance_id":"inst_coord"`) &&
		   strings.contains(cmd.body_json, `"interrupt":true`) &&
		   strings.contains(cmd.body_json, "entered finishing state") {
			found_coord_finishing = true
		}
	}
	testing.expect(t, found_assignee_finishing, "assignee must receive notification with action finishing")
	testing.expect(t, found_coord_finishing, "coordinator must receive notification for task entering finishing")

	// Now complete the task from Finishing -> Completed
	for cmd in captured_cmds do delete(cmd.body_json)
	clear(&captured_cmds)

	auth_worker := contracts.Auth_Context{kind = .Instance_Token, user_id = string(owner), agent_instance_id = "inst_worker"}
	completed_task, comp_ok, comp_err := change_task_status(&svc, auth_worker, "task_finish_1", .Completed)
	testing.expect(t, comp_ok, "change_task_status to Completed must succeed")
	testing.expect_value(t, comp_err.code, domain.Error_Code.None)
	testing.expect_value(t, completed_task.status, domain.Task_Status.Completed)
	testing.expect(t, completed_task.completed_at != "", "completed_at must be set upon Completed")

	found_coord_completed := false
	for cmd in captured_cmds {
		if strings.contains(cmd.body_json, `"agent_instance_id":"inst_coord"`) &&
		   strings.contains(cmd.body_json, "Task Completed") &&
		   strings.contains(cmd.body_json, "has completed") {
			found_coord_completed = true
		}
	}
	testing.expect(t, found_coord_completed, "coordinator must be notified upon task completion")
}

@(test)
test_comment_task_coordinator_notify_filter :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_comment_filter_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer sqlite.close(&conn)

	mig_ok, mig_err := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	tc_impl := sqlite.Taskchain_Repo_SQLite{conn = &conn}
	tc_repo := sqlite.new_taskchain_repository(&tc_impl, &conn)

	ag_impl := sqlite.Agent_Repo_SQLite{conn = &conn}
	ag_repo := sqlite.new_agent_repository(&ag_impl, &conn)

	clock := platform.real_clock()
	ids := platform.real_id_generator()

	captured_cmds := make([dynamic]project_service.Runtime_Command)
	defer {
		for cmd in captured_cmds do delete(cmd.body_json)
		delete(captured_cmds)
	}
	sink := project_service.Bridge_Command_Sink{
		ctx = rawptr(&captured_cmds),
		send_runtime_command = proc(ctx: rawptr, cmd: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
			commands := (^[dynamic]project_service.Runtime_Command)(ctx)
			captured := cmd
			captured.body_json = strings.clone(cmd.body_json)
			append(commands, captured)
			return true, domain.Domain_Error{}
		},
	}

	svc := new_taskchain_service_with_runtime(&tc_repo, &ag_repo, sink, &clock, &ids)

	owner := domain.User_ID("user_comment_filter_test")
	chain_id := domain.Task_Chain_ID("chain_comment_filter_test")

	chain := domain.Task_Chain{
		chain_id                      = chain_id,
		owner_user_id                 = owner,
		title                         = "Comment Filter Chain",
		description                   = "Testing comment filter",
		publish_state                 = .Published,
		status                        = .Active,
		kind                          = "test",
		coordinator_agent_instance_id = "inst_coord",
		default_reviewer_refs_json    = "[]",
		created_at                    = "2026-10-02T10:00:00Z",
		updated_at                    = "2026-10-02T10:00:00Z",
	}
	_, _, _ = iface.taskchain_save_chain(&tc_repo, chain)

	coord_inst := domain.Agent_Instance{
		agent_instance_id = "inst_coord",
		owner_user_id     = owner,
		agent_id          = "agt_coord",
		bridge_id         = "brg_test",
		display_name      = "coordinator",
		runtime_status    = "running",
		chain_id          = string(chain_id),
		created_at        = "2026-10-02T10:00:00Z",
		updated_at        = "2026-10-02T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, coord_inst)

	worker_inst := domain.Agent_Instance{
		agent_instance_id = "inst_worker",
		owner_user_id     = owner,
		agent_id          = "agt_worker",
		bridge_id         = "brg_test",
		display_name      = "worker",
		runtime_status    = "running",
		chain_id          = string(chain_id),
		created_at        = "2026-10-02T10:00:00Z",
		updated_at        = "2026-10-02T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, worker_inst)
	_, _, _ = iface.taskchain_save_member(&tc_repo, domain.Task_Chain_Member{
		chain_id          = chain_id,
		agent_instance_id = "inst_coord",
		agent_id          = "agt_coord",
		owner_user_id     = owner,
		role              = "coordinator",
		created_at        = "2026-10-02T10:00:00Z",
	})
	_, _, _ = iface.taskchain_save_member(&tc_repo, domain.Task_Chain_Member{
		chain_id          = chain_id,
		agent_instance_id = "inst_worker",
		agent_id          = "agt_worker",
		owner_user_id     = owner,
		role              = "worker",
		created_at        = "2026-10-02T10:00:00Z",
	})

	task := domain.Task{
		task_id            = "task_comment_filter_1",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "Comment Filter Task",
		description        = "Comment filter test",
		publish_state      = .Published,
		status             = .In_Progress,
		priority           = .P1,
		assignee_ref_json  = `{"type":"agent_instance","agent_instance_id":"inst_worker"}`,
		reviewer_refs_json = "[]",
		created_at         = "2026-10-02T10:01:00Z",
		updated_at         = "2026-10-02T10:01:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, task)

	auth_worker := contracts.Auth_Context{kind = .Instance_Token, user_id = string(owner), agent_instance_id = "inst_worker"}

	// 1. Comment without coordinator in notify -> coordinator must NOT be notified
	_, _, ok1, err1 := comment_task(&svc, auth_worker, Task_Comment_Input{
		task_id = "task_comment_filter_1",
		body    = "assignee update without notifying coord",
	})
	testing.expect(t, ok1, "comment_task without notify should succeed")
	testing.expect_value(t, err1.code, domain.Error_Code.None)

	coord_notified := false
	for cmd in captured_cmds {
		if strings.contains(cmd.body_json, `"agent_instance_id":"inst_coord"`) {
			coord_notified = true
		}
	}
	testing.expect(t, !coord_notified, "coordinator must NOT be notified when not specified in notify")

	// 2. Comment with coordinator in notify -> coordinator MUST be notified
	for cmd in captured_cmds do delete(cmd.body_json)
	clear(&captured_cmds)

	notify_targets := [1]string{"inst_coord"}
	_, _, ok2, err2 := comment_task(&svc, auth_worker, Task_Comment_Input{
		task_id = "task_comment_filter_1",
		body    = "assignee update explicitly notifying coord",
		notify  = notify_targets[:],
	})
	testing.expect(t, ok2, "comment_task with notify coord should succeed")
	testing.expect_value(t, err2.code, domain.Error_Code.None)

	coord_notified_2 := false
	for cmd in captured_cmds {
		if strings.contains(cmd.body_json, `"agent_instance_id":"inst_coord"`) {
			coord_notified_2 = true
		}
	}
	testing.expect(t, coord_notified_2, "coordinator MUST be notified when explicitly specified in notify")
}

@(test)
test_task_pausing_state_and_workflow :: proc(t: ^testing.T) {
	// Acceptance criteria verification:
	// 1. Task_Status.Pausing added to domain and serialized as "pausing".
	testing.expect_value(t, task_status_string(.Pausing), "pausing")
	testing.expect_value(t, sqlite.task_status_string(.Pausing), "pausing")
	testing.expect_value(t, sqlite.task_status_from_string("pausing"), domain.Task_Status.Pausing)

	// 2. TASK_TRANSITIONS_PAUSING, TASK_ACTIONS_PAUSING, and recovery actions defined and wired in domain.
	pausing_trans := domain.task_allowed_transitions(.Pausing)
	testing.expect(t, len(pausing_trans) == 4, "pausing must have 4 allowed transitions")
	testing.expect_value(t, pausing_trans[0], domain.Task_Status.Paused)
	testing.expect_value(t, pausing_trans[1], domain.Task_Status.In_Progress)
	testing.expect_value(t, pausing_trans[2], domain.Task_Status.Cancelled)
	testing.expect_value(t, pausing_trans[3], domain.Task_Status.Assigned)

	pausing_actions := domain.task_allowed_actions(.Pausing)
	testing.expect(t, len(pausing_actions) == 4, "pausing must have 4 allowed actions")
	testing.expect_value(t, pausing_actions[0], "pause")
	testing.expect_value(t, pausing_actions[1], "start")
	testing.expect_value(t, pausing_actions[2], "cancel")
	testing.expect_value(t, pausing_actions[3], "nudge")

	pausing_recovery := domain.task_recovery_actions(.Pausing)
	testing.expect(t, len(pausing_recovery) == 5, "pausing must have 5 recovery actions")

	// 3. In_Progress -> Pausing allowed, Pausing -> Paused allowed, Finishing -> Pausing allowed.
	testing.expect(t, valid_task_transition(.In_Progress, .Pausing), "In_Progress -> Pausing must be valid")
	testing.expect(t, valid_task_transition(.Pausing, .Paused), "Pausing -> Paused must be valid")
	testing.expect(t, valid_task_transition(.Pausing, .In_Progress), "Pausing -> In_Progress must be valid")
	testing.expect(t, valid_task_transition(.Pausing, .Cancelled), "Pausing -> Cancelled must be valid")
	testing.expect(t, valid_task_transition(.Finishing, .Pausing), "Finishing -> Pausing must be valid")

	// 4. work_status_is_actionable treats .Pausing as an actionable assignee work status.
	testing.expect(t, work_status_is_actionable(.Pausing), ".Pausing must be actionable")
	testing.expect(t, !work_status_is_actionable(.Paused), ".Paused must NOT be actionable")

	// 5. Database and Service workflow
	db_path := fmt.tprintf("/tmp/test_pausing_workflow_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer sqlite.close(&conn)

	mig_ok, mig_err := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	tc_impl := sqlite.Taskchain_Repo_SQLite{conn = &conn}
	tc_repo := sqlite.new_taskchain_repository(&tc_impl, &conn)

	ag_impl := sqlite.Agent_Repo_SQLite{conn = &conn}
	ag_repo := sqlite.new_agent_repository(&ag_impl, &conn)

	clock := platform.real_clock()
	ids := platform.real_id_generator()

	captured_cmds := make([dynamic]project_service.Runtime_Command)
	defer {
		for cmd in captured_cmds do delete(cmd.body_json)
		delete(captured_cmds)
	}
	sink := project_service.Bridge_Command_Sink{
		ctx = rawptr(&captured_cmds),
		send_runtime_command = proc(ctx: rawptr, cmd: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
			commands := (^[dynamic]project_service.Runtime_Command)(ctx)
			captured := cmd
			captured.body_json = strings.clone(cmd.body_json)
			append(commands, captured)
			return true, domain.Domain_Error{}
		},
	}

	svc := new_taskchain_service_with_runtime(&tc_repo, &ag_repo, sink, &clock, &ids)

	owner := domain.User_ID("user_pausing_test")
	chain_id := domain.Task_Chain_ID("chain_pausing_test")

	chain := domain.Task_Chain{
		chain_id                      = chain_id,
		owner_user_id                 = owner,
		title                         = "Pausing Workflow Chain",
		description                   = "Testing pausing workflow",
		publish_state                 = .Published,
		status                        = .Active,
		kind                          = "test",
		coordinator_agent_instance_id = "inst_coord",
		default_reviewer_refs_json    = "[]",
		created_at                    = "2026-10-02T10:00:00Z",
		updated_at                    = "2026-10-02T10:00:00Z",
	}
	_, _, _ = iface.taskchain_save_chain(&tc_repo, chain)

	coord_inst := domain.Agent_Instance{
		agent_instance_id = "inst_coord",
		owner_user_id     = owner,
		agent_id          = "agt_coord",
		bridge_id         = "brg_test",
		display_name      = "coordinator",
		runtime_status    = "running",
		chain_id          = string(chain_id),
		created_at        = "2026-10-02T10:00:00Z",
		updated_at        = "2026-10-02T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, coord_inst)

	worker_inst := domain.Agent_Instance{
		agent_instance_id = "inst_worker",
		owner_user_id     = owner,
		agent_id          = "agt_worker",
		bridge_id         = "brg_test",
		display_name      = "worker",
		runtime_status    = "running",
		chain_id          = string(chain_id),
		created_at        = "2026-10-02T10:00:00Z",
		updated_at        = "2026-10-02T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, worker_inst)

	_, _, _ = iface.taskchain_save_member(&tc_repo, domain.Task_Chain_Member{
		chain_id          = chain_id,
		agent_instance_id = "inst_coord",
		agent_id          = "agt_coord",
		owner_user_id     = owner,
		role              = "coordinator",
		created_at        = "2026-10-02T10:00:00Z",
	})
	_, _, _ = iface.taskchain_save_member(&tc_repo, domain.Task_Chain_Member{
		chain_id          = chain_id,
		agent_instance_id = "inst_worker",
		agent_id          = "agt_worker",
		owner_user_id     = owner,
		role              = "worker",
		created_at        = "2026-10-02T10:00:00Z",
	})

	task := domain.Task{
		task_id            = "task_pause_1",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "Pausing Feature Task",
		description        = "Pause me",
		publish_state      = .Published,
		status             = .In_Progress,
		priority           = .P1,
		assignee_ref_json  = `{"type":"agent_instance","agent_instance_id":"inst_worker"}`,
		reviewer_refs_json = "[]",
		created_at         = "2026-10-02T10:01:00Z",
		updated_at         = "2026-10-02T10:01:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, task)

	auth_user := contracts.Auth_Context{kind = .User_Token, user_id = string(owner)}

	// Step 1: Request pause on active In_Progress task -> enters Pausing
	_, pause_ok, pause_err := change_task_status(&svc, auth_user, "task_pause_1", .Paused)
	testing.expect(t, pause_ok, "change_task_status to Paused on In_Progress task must succeed")
	testing.expect_value(t, pause_err.code, domain.Error_Code.None)

	persisted, get_ok, _ := iface.taskchain_get_task(&tc_repo, "task_pause_1")
	testing.expect(t, get_ok, "task must exist")
	testing.expect_value(t, persisted.status, domain.Task_Status.Pausing)
	testing.expect(t, work_status_is_actionable(persisted.status), "Pausing state must remain actionable for assignee")

	found_assignee_pausing := false
	found_coord_pausing := false
	for cmd in captured_cmds {
		if strings.contains(cmd.body_json, `"agent_instance_id":"inst_worker"`) &&
		   strings.contains(cmd.body_json, `"action":"pausing"`) &&
		   strings.contains(cmd.body_json, `"interrupt":true`) &&
		   strings.contains(cmd.body_json, "Task Pausing") &&
		   strings.contains(cmd.body_json, "wrap up, post handoff comment, stash/commit changes, then run './.heimdall/bin/ham-ctl task status task_pause_1 --status paused'") {
			found_assignee_pausing = true
		}
		if strings.contains(cmd.body_json, `"agent_instance_id":"inst_coord"`) &&
		   strings.contains(cmd.body_json, `"action":"pausing"`) &&
		   strings.contains(cmd.body_json, `"interrupt":true`) &&
		   strings.contains(cmd.body_json, "Task Pausing") &&
		   strings.contains(cmd.body_json, "entered pausing state") {
			found_coord_pausing = true
		}
	}
	testing.expect(t, found_assignee_pausing, "assignee must receive notification with handoff instructions and action pausing")
	testing.expect(t, found_coord_pausing, "coordinator must receive notification for task entering pausing")

	// Step 2: Worker confirms ready-to-pause -> transitions from Pausing to Paused
	for cmd in captured_cmds do delete(cmd.body_json)
	clear(&captured_cmds)

	auth_worker := contracts.Auth_Context{kind = .Instance_Token, user_id = string(owner), agent_instance_id = "inst_worker"}
	_, final_ok, final_err := change_task_status(&svc, auth_worker, "task_pause_1", .Paused)
	testing.expect(t, final_ok, "change_task_status to Paused from Pausing must succeed")
	testing.expect_value(t, final_err.code, domain.Error_Code.None)

	persisted_final, get_final_ok, _ := iface.taskchain_get_task(&tc_repo, "task_pause_1")
	testing.expect(t, get_final_ok, "task must exist")
	testing.expect_value(t, persisted_final.status, domain.Task_Status.Paused)
	testing.expect(t, !work_status_is_actionable(persisted_final.status), "Paused state must release actionable work status")

	found_coord_paused := false
	for cmd in captured_cmds {
		if strings.contains(cmd.body_json, `"agent_instance_id":"inst_coord"`) &&
		   strings.contains(cmd.body_json, "Task Paused") &&
		   strings.contains(cmd.body_json, "paused") {
			found_coord_paused = true
		}
	}
	testing.expect(t, found_coord_paused, "coordinator must be notified upon task paused by worker")

	// Step 3: Test task_action("pause") on Finishing state
	task_fin := domain.Task{
		task_id            = "task_pause_fin",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "Finishing To Pausing Task",
		description        = "Finish then pause",
		publish_state      = .Published,
		status             = .Finishing,
		priority           = .P1,
		assignee_ref_json  = `{"type":"agent_instance","agent_instance_id":"inst_worker"}`,
		reviewer_refs_json = "[]",
		created_at         = "2026-10-02T10:02:00Z",
		updated_at         = "2026-10-02T10:02:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, task_fin)
	auth_coord := contracts.Auth_Context{kind = .Instance_Token, user_id = string(owner), agent_instance_id = "inst_coord"}
	act_task, act_ok, act_err := task_action(&svc, auth_coord, "task_pause_fin", "pause")
	testing.expect(t, act_ok, "task_action pause on Finishing must succeed")
	testing.expect_value(t, act_err.code, domain.Error_Code.None)

	persisted_fin, _, _ := iface.taskchain_get_task(&tc_repo, "task_pause_fin")
	testing.expect_value(t, persisted_fin.status, domain.Task_Status.Pausing)

	// Step 4: task_action("pause") from Pausing -> Paused by coordinator notifies assignee
	for cmd in captured_cmds do delete(cmd.body_json)
	clear(&captured_cmds)

	act_final, act_final_ok, _ := task_action(&svc, auth_coord, "task_pause_fin", "pause")
	testing.expect(t, act_final_ok, "task_action pause on Pausing must succeed")
	testing.expect_value(t, act_final.status, domain.Task_Status.Paused)

	found_assignee_paused := false
	for cmd in captured_cmds {
		if strings.contains(cmd.body_json, `"agent_instance_id":"inst_worker"`) &&
		   strings.contains(cmd.body_json, "Task Paused") &&
		   strings.contains(cmd.body_json, "paused") {
			found_assignee_paused = true
		}
	}
	testing.expect(t, found_assignee_paused, "assignee must be notified upon task paused by coordinator")
}

@(test)
test_ensure_durable_actor_fleets_filters_nonexistent_agents :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_fleet_filter_nonexistent_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer sqlite.close(&conn)

	mig_ok, mig_err := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	tc_impl := sqlite.Taskchain_Repo_SQLite{conn = &conn}
	tc_repo := sqlite.new_taskchain_repository(&tc_impl, &conn)

	ag_impl := sqlite.Agent_Repo_SQLite{conn = &conn}
	ag_repo := sqlite.new_agent_repository(&ag_impl, &conn)

	clock := platform.real_clock()
	ids := platform.real_id_generator()
	svc := new_taskchain_service(&tc_repo, &ag_repo, &clock, &ids)

	owner := domain.User_ID("tanmay")
	chain_id := domain.Task_Chain_ID("chain_filter_test")
	chain := domain.Task_Chain{
		chain_id      = chain_id,
		owner_user_id = owner,
		title         = "Filter Test Chain",
		publish_state = .Published,
		status        = .Active,
		created_at    = "2026-10-02T10:00:00Z",
		updated_at    = "2026-10-02T10:00:00Z",
	}
	_, _, _ = iface.taskchain_save_chain(&tc_repo, chain)

	// Save valid agent in ag_repo
	valid_agent := domain.Agent{
		agent_id      = "agt_valid_agent",
		owner_user_id = owner,
		name          = "Valid Agent",
		created_at    = "2026-10-02T10:00:00Z",
		updated_at    = "2026-10-02T10:00:00Z",
	}
	_, _, _ = iface.agent_save(&ag_repo, valid_agent)

	// Task referencing both an existing agent and a non-existent agent
	task := domain.Task{
		task_id            = "task_filter_test",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "Test Task",
		publish_state      = .Published,
		status             = .Assigned,
		assignee_ref_json  = `{"type":"agent_id","agent_id":"agt_valid_agent"}`,
		reviewer_refs_json = `[{"type":"agent_id","agent_id":"agt_nonexistent_123"}]`,
		created_at         = "2026-10-02T10:00:00Z",
		updated_at         = "2026-10-02T10:00:00Z",
	}

	err := ensure_durable_actor_fleets(&svc, task)
	testing.expect_value(t, err.code, domain.Error_Code.None)

	fleets, ferr := iface.taskchain_list_fleets_by_chain(&tc_repo, chain_id, owner)
	testing.expect_value(t, ferr.code, domain.Error_Code.None)
	defer delete(fleets)

	testing.expect_value(t, len(fleets), 1)
	if len(fleets) == 1 {
		testing.expect_value(t, fleets[0].agent_id, "agt_valid_agent")
	}
}

@(test)
test_task_wake_interrupt_and_command_suffix_pausing_and_finishing :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_interrupt_suffix_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer sqlite.close(&conn)

	mig_ok, mig_err := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	tc_impl := sqlite.Taskchain_Repo_SQLite{conn = &conn}
	tc_repo := sqlite.new_taskchain_repository(&tc_impl, &conn)

	ag_impl := sqlite.Agent_Repo_SQLite{conn = &conn}
	ag_repo := sqlite.new_agent_repository(&ag_impl, &conn)

	clock := platform.real_clock()
	ids := platform.real_id_generator()

	captured_cmds := make([dynamic]project_service.Runtime_Command)
	defer {
		for cmd in captured_cmds do delete(cmd.body_json)
		delete(captured_cmds)
	}
	sink := project_service.Bridge_Command_Sink{
		ctx = rawptr(&captured_cmds),
		send_runtime_command = proc(ctx: rawptr, cmd: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
			commands := (^[dynamic]project_service.Runtime_Command)(ctx)
			captured := cmd
			captured.body_json = strings.clone(cmd.body_json)
			append(commands, captured)
			return true, domain.Domain_Error{}
		},
	}

	svc := new_taskchain_service_with_runtime(&tc_repo, &ag_repo, sink, &clock, &ids)

	owner := domain.User_ID("user_interrupt_test")
	chain_id := domain.Task_Chain_ID("chain_interrupt_test")

	chain := domain.Task_Chain{
		chain_id                      = chain_id,
		owner_user_id                 = owner,
		title                         = "Interrupt Test Chain",
		description                   = "Testing interrupt and command suffix",
		publish_state                 = .Published,
		status                        = .Active,
		kind                          = "test",
		coordinator_agent_instance_id = "inst_coord",
		default_reviewer_refs_json    = "[]",
		created_at                    = "2026-10-02T10:00:00Z",
		updated_at                    = "2026-10-02T10:00:00Z",
	}
	_, _, _ = iface.taskchain_save_chain(&tc_repo, chain)

	coord_inst := domain.Agent_Instance{
		agent_instance_id = "inst_coord",
		owner_user_id     = owner,
		agent_id          = "agt_coord",
		bridge_id         = "brg_test",
		display_name      = "coordinator",
		runtime_status    = "running",
		chain_id          = string(chain_id),
		created_at        = "2026-10-02T10:00:00Z",
		updated_at        = "2026-10-02T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, coord_inst)

	worker_inst := domain.Agent_Instance{
		agent_instance_id = "inst_worker",
		owner_user_id     = owner,
		agent_id          = "agt_worker",
		bridge_id         = "brg_test",
		display_name      = "worker",
		runtime_status    = "running",
		chain_id          = string(chain_id),
		created_at        = "2026-10-02T10:00:00Z",
		updated_at        = "2026-10-02T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, worker_inst)

	reviewer_inst := domain.Agent_Instance{
		agent_instance_id = "inst_reviewer",
		owner_user_id     = owner,
		agent_id          = "agt_reviewer",
		bridge_id         = "brg_test",
		display_name      = "reviewer",
		runtime_status    = "running",
		chain_id          = string(chain_id),
		created_at        = "2026-10-02T10:00:00Z",
		updated_at        = "2026-10-02T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, reviewer_inst)

	_, _, _ = iface.taskchain_save_member(&tc_repo, domain.Task_Chain_Member{
		chain_id          = chain_id,
		agent_instance_id = "inst_coord",
		agent_id          = "agt_coord",
		owner_user_id     = owner,
		role              = "coordinator",
		created_at        = "2026-10-02T10:00:00Z",
	})
	_, _, _ = iface.taskchain_save_member(&tc_repo, domain.Task_Chain_Member{
		chain_id          = chain_id,
		agent_instance_id = "inst_worker",
		agent_id          = "agt_worker",
		owner_user_id     = owner,
		role              = "worker",
		created_at        = "2026-10-02T10:00:00Z",
	})
	_, _, _ = iface.taskchain_save_member(&tc_repo, domain.Task_Chain_Member{
		chain_id          = chain_id,
		agent_instance_id = "inst_reviewer",
		agent_id          = "agt_reviewer",
		owner_user_id     = owner,
		role              = "reviewer",
		created_at        = "2026-10-02T10:00:00Z",
	})

	// 1. Test Pausing wake: notify_status_policy
	pause_task := domain.Task{
		task_id           = "task_wake_pause_1",
		chain_id          = chain_id,
		owner_user_id     = owner,
		title             = "Pausing Wake Task",
		status            = .Pausing,
		assignee_ref_json = `{"type":"agent_instance","agent_instance_id":"inst_worker"}`,
		created_at        = "2026-10-02T10:00:00Z",
		updated_at        = "2026-10-02T10:00:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, pause_task)

	auth := contracts.Auth_Context{kind = .User_Token, user_id = string(owner)}
	notify_status_policy(&svc, auth, pause_task, chain)

	found_pausing_wake := false
	for cmd in captured_cmds {
		if strings.contains(cmd.body_json, `"agent_instance_id":"inst_worker"`) &&
		   strings.contains(cmd.body_json, `"action":"pausing"`) &&
		   strings.contains(cmd.body_json, `"interrupt":true`) &&
		   strings.contains(cmd.body_json, "wrap up, post handoff comment, stash/commit changes, then run './.heimdall/bin/ham-ctl task status task_wake_pause_1 --status paused'") {
			found_pausing_wake = true
		}
	}
	testing.expect(t, found_pausing_wake, "Pausing wake must contain interrupt:true and command suffix")

	for cmd in captured_cmds do delete(cmd.body_json)
	clear(&captured_cmds)

	// 2. Test Finishing wake: evaluate_task_quorum / vote
	finish_task := domain.Task{
		task_id            = "task_wake_finish_1",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "Finishing Wake Task",
		description        = "Finish wake test",
		publish_state      = .Published,
		status             = .In_Validation,
		priority           = .P1,
		assignee_ref_json  = `{"type":"agent_instance","agent_instance_id":"inst_worker"}`,
		reviewer_refs_json = `[{"type":"agent_instance","agent_instance_id":"inst_reviewer"}]`,
		created_at         = "2026-10-02T10:00:00Z",
		updated_at         = "2026-10-02T10:00:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, finish_task)

	auth_rev := contracts.Auth_Context{kind = .Instance_Token, user_id = string(owner), agent_instance_id = "inst_reviewer"}
	_, vote_ok, vote_err := record_task_vote(&svc, auth_rev, Vote_Input{
		task_id = "task_wake_finish_1",
		vote    = "lgtm",
		comment = "all clear",
	})
	testing.expect(t, vote_ok, "record_task_vote must succeed")

	found_finishing_wake := false
	for cmd in captured_cmds {
		if strings.contains(cmd.body_json, `"agent_instance_id":"inst_worker"`) &&
		   strings.contains(cmd.body_json, `"action":"finishing"`) &&
		   strings.contains(cmd.body_json, `"interrupt":true`) &&
		   strings.contains(cmd.body_json, "wrap up, commit/push changes, then run './.heimdall/bin/ham-ctl task status task_wake_finish_1 --status completed'") {
			found_finishing_wake = true
		}
	}
	testing.expect(t, found_finishing_wake, "Finishing wake must contain interrupt:true and command suffix")

	for cmd in captured_cmds do delete(cmd.body_json)
	clear(&captured_cmds)
}

@(test)
test_fsm_reviewer_auto_binding_and_jit_on_in_validation :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_fsm_rev_dispatch_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer sqlite.close(&conn)

	mig_ok, mig_err := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	tc_impl := sqlite.Taskchain_Repo_SQLite{conn = &conn}
	tc_repo := sqlite.new_taskchain_repository(&tc_impl, &conn)

	ag_impl := sqlite.Agent_Repo_SQLite{conn = &conn}
	ag_repo := sqlite.new_agent_repository(&ag_impl, &conn)

	br_impl := sqlite.Bridge_Repo_SQLite{conn = &conn}
	br_repo := sqlite.new_bridge_repository(&br_impl, &conn)

	pr_impl := sqlite.Project_Repo_SQLite{conn = &conn}
	pr_repo := sqlite.new_project_repository(&pr_impl, &conn)

	co_impl := sqlite.Content_Repo_SQLite{conn = &conn}
	co_repo := sqlite.new_content_repository(&co_impl, &conn)

	provider_impl := sqlite.Provider_Repo_SQLite{conn = &conn}
	providers := sqlite.new_provider_repository(&provider_impl, &conn)

	clock := platform.real_clock()
	ids := platform.real_id_generator()

	owner := domain.User_ID("user_fsm_rev")
	chain_id := domain.Task_Chain_ID("chain_fsm_rev_test")
	auth_user := contracts.Auth_Context{kind = .User_Token, user_id = string(owner)}

	// Set up Bridge in repo
	bridge := domain.Bridge{
		bridge_id         = "brg_fsm_rev",
		owner_user_id     = owner,
		machine_hostname  = "localhost",
		status            = .Online,
		capabilities_json = `{"capabilities":[{"provider":"claude","models":["claude-fable-5-1","claude-opus-5-5","claude-sonnet-5-5"],"default_model":"claude-opus-5-5"}],"provider":"claude","default_model":"claude-opus-5-5"}`,
		created_at        = "2026-10-01T10:00:00Z",
		updated_at        = "2026-10-01T10:00:00Z",
	}
	_, _, _ = iface.bridge_save_bridge(&br_repo, bridge)
	_, _ = iface.bridge_provider_status_upsert(&providers, domain.Bridge_Provider_Status{bridge_id = "brg_fsm_rev", provider = "claude", state = "present"})
	_, _ = iface.bridge_provider_setting_upsert(&providers, domain.Bridge_Provider_Setting{bridge_id = "brg_fsm_rev", provider = "claude", enabled = true})

	project := domain.Project{
		project_id    = domain.Project_ID("prj_rev"),
		owner_user_id = owner,
		name          = "Rev Project",
		slug          = "rev-project",
		default_path  = "/srv/rev/default",
		state         = .Active,
		created_at    = "2026-10-01T10:00:00Z",
		updated_at    = "2026-10-01T10:00:00Z",
	}
	_, _, _ = iface.project_save(&pr_repo, project)
	_, _, _ = iface.project_save_bridge_path(&pr_repo, domain.Project_Bridge_Path{
		project_id    = project.project_id,
		bridge_id     = "brg_fsm_rev",
		owner_user_id = owner,
		path          = "/srv/rev/primary",
		created_at    = "2026-10-01T10:00:00Z",
		updated_at    = "2026-10-01T10:00:00Z",
	})

	// Agents: worker and reviewer
	worker_agent := domain.Agent{
		agent_id         = "agt_fsm_rev_worker",
		owner_user_id    = owner,
		name             = "Worker Agent",
		slug             = "worker-agent",
		created_at       = "2026-10-01T10:00:00Z",
		updated_at       = "2026-10-01T10:00:00Z",
	}
	_, _, _ = iface.agent_save(&ag_repo, worker_agent)

	reviewer_agent := domain.Agent{
		agent_id         = "agt_fsm_reviewer",
		owner_user_id    = owner,
		name             = "Reviewer Agent",
		slug             = "reviewer-agent",
		created_at       = "2026-10-01T10:00:00Z",
		updated_at       = "2026-10-01T10:00:00Z",
	}
	_, _, _ = iface.agent_save(&ag_repo, reviewer_agent)

	worker_support := domain.Agent_Bridge_Support{
		agent_id      = "agt_fsm_rev_worker",
		bridge_id     = "brg_fsm_rev",
		owner_user_id = owner,
		enabled       = true,
	}
	_, _, _ = iface.agent_save_support(&ag_repo, worker_support)

	rev_support := domain.Agent_Bridge_Support{
		agent_id      = "agt_fsm_reviewer",
		bridge_id     = "brg_fsm_rev",
		owner_user_id = owner,
		enabled       = true,
	}
	_, _, _ = iface.agent_save_support(&ag_repo, rev_support)

	registry := project_service.Bridge_Runtime_Registry{}
	project_service.bridge_runtime_registry_mark_live(&registry, "brg_fsm_rev", false, "")

	captured_cmds := make([dynamic]project_service.Runtime_Command)
	defer {
		for cmd in captured_cmds do delete(cmd.body_json)
		delete(captured_cmds)
	}
	sink := project_service.Bridge_Command_Sink{
		ctx = rawptr(&captured_cmds),
		send_runtime_command = proc(ctx: rawptr, cmd: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
			commands := (^[dynamic]project_service.Runtime_Command)(ctx)
			captured := cmd
			captured.body_json = strings.clone(cmd.body_json)
			append(commands, captured)
			return true, domain.Domain_Error{}
		},
	}

	svc := new_taskchain_service_with_runtime(&tc_repo, &ag_repo, sink, &clock, &ids)
	ag_service := agent_service.new_agent_service_with_runtime(&ag_repo, &br_repo, &pr_repo, &co_repo, &tc_repo, sink, &registry, &clock, &ids)
	ag_service.providers = &providers
	svc.agent_service = &ag_service

	// Create chain
	chain := domain.Task_Chain{
		chain_id                      = chain_id,
		owner_user_id                 = owner,
		title                         = "FSM Rev Chain",
		publish_state                 = .Published,
		status                        = .Active,
		kind                          = "test",
		coordinator_agent_instance_id = "inst_coord_rev",
		default_reviewer_refs_json    = "[]",
		created_at                    = "2026-10-01T10:00:00Z",
		updated_at                    = "2026-10-01T10:00:00Z",
	}
	_, _, _ = iface.taskchain_save_chain(&tc_repo, chain)

	coord_inst := domain.Agent_Instance{
		agent_instance_id = "inst_coord_rev",
		owner_user_id     = owner,
		agent_id          = "agt_coordinator",
		bridge_id         = "brg_fsm_rev",
		project_id        = domain.Project_ID("prj_rev"),
		display_name      = "coordinator #1",
		runtime_status    = "running",
		chain_id          = string(chain_id),
		created_at        = "2026-10-01T10:00:00Z",
		updated_at        = "2026-10-01T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, coord_inst)

	// Reviewer fleet capacity = 2, provider = "claude", model = "claude-sonnet-5-5"
	rev_fleet := domain.Task_Chain_Fleet{
		task_chain_id    = chain_id,
		agent_id         = "agt_fsm_reviewer",
		capacity         = 2,
		min_warm         = 1,
		idle_ttl_seconds = 300,
		provider         = "claude",
		model             = "claude-sonnet-5-5",
		created_at       = "2026-10-01T10:00:00Z",
		updated_at       = "2026-10-01T10:00:00Z",
	}
	_, _ = iface.taskchain_upsert_fleet(&tc_repo, rev_fleet)

	// Worker instance
	worker_inst := domain.Agent_Instance{
		agent_instance_id = "inst_worker_1",
		owner_user_id     = owner,
		agent_id          = "agt_fsm_rev_worker",
		bridge_id         = "brg_fsm_rev",
		display_name      = "worker 1",
		runtime_status    = "running",
		chain_id          = string(chain_id),
		created_at        = "2026-10-01T10:00:00Z",
		updated_at        = "2026-10-01T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, worker_inst)

	// Idle reviewer instance in warm pool
	rev1_inst := domain.Agent_Instance{
		agent_instance_id = "inst_rev_idle",
		owner_user_id     = owner,
		agent_id          = "agt_fsm_reviewer",
		bridge_id         = "brg_fsm_rev",
		display_name      = "idle reviewer",
		runtime_status    = "idle",
		chain_id          = string(chain_id),
		created_at        = "2026-10-01T10:00:00Z",
		updated_at        = "2026-10-01T10:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(&ag_repo, rev1_inst)
	rev1_member := domain.Task_Chain_Member{
		chain_id          = chain_id,
		agent_instance_id = "inst_rev_idle",
		agent_id          = "agt_fsm_reviewer",
		owner_user_id     = owner,
		role              = "reviewer",
		created_at        = "2026-10-01T10:00:00Z",
	}
	_, _, _ = iface.taskchain_save_member(&tc_repo, rev1_member)

	// =========================================================================
	// REQ-FSM-REV-1: Idle instance auto-binding on in_validation
	// =========================================================================
	t1 := domain.Task{
		task_id            = "task_fsm_rev_1",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "FSM Reviewer Task 1",
		publish_state      = .Published,
		status             = .In_Progress,
		priority           = .P1,
		assignee_ref_json  = `{"type":"agent_instance","agent_instance_id":"inst_worker_1"}`,
		reviewer_refs_json = `[{"type":"agent_id","agent_id":"agt_fsm_reviewer"}]`,
		bridge_id          = "brg_fsm_rev",
		created_at         = "2026-10-01T10:01:00Z",
		updated_at         = "2026-10-01T10:01:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, t1)

	// Transition t1 to .In_Validation via change_task_status
	ret1, ok1, err1 := change_task_status(&svc, auth_user, "task_fsm_rev_1", .In_Validation)
	testing.expect(t, ok1, "change_task_status to In_Validation must succeed")
	testing.expect_value(t, err1.code, domain.Error_Code.None)
	testing.expect_value(t, ret1.status, domain.Task_Status.In_Validation)

	// Acceptance criteria:
	// - Idle warm pool instance inst_rev_idle auto-bound to reviewer_refs_json
	rev_insts1 := extract_instances_from_ref_blob(ret1.reviewer_refs_json)
	defer delete(rev_insts1)
	testing.expect_value(t, len(rev_insts1), 1)
	if len(rev_insts1) == 1 {
		testing.expect_value(t, rev_insts1[0], "inst_rev_idle")
	}

	// Persisted row has reviewer bound
	persisted1, p1_ok, _ := iface.taskchain_get_task(&tc_repo, "task_fsm_rev_1")
	testing.expect(t, p1_ok, "task 1 must exist")
	p_rev_insts1 := extract_instances_from_ref_blob(persisted1.reviewer_refs_json)
	defer delete(p_rev_insts1)
	testing.expect_value(t, len(p_rev_insts1), 1)
	if len(p_rev_insts1) == 1 {
		testing.expect_value(t, p_rev_insts1[0], "inst_rev_idle")
	}

	// Reviewer instance focus was automatically updated to task_fsm_rev_1 with role .Review
	updated_r1, _, _ := iface.agent_get_instance(&ag_repo, "inst_rev_idle")
	testing.expect_value(t, updated_r1.current_task_id, "task_fsm_rev_1")
	testing.expect_value(t, updated_r1.current_task_role, domain.Current_Task_Role.Review)

	// Reviewer received status changed notification with action "review"
	found_r1_notify := false
	for cmd in captured_cmds {
		if strings.contains(cmd.body_json, `"type":"task_status_changed_notify"`) &&
		   strings.contains(cmd.body_json, `"task_id":"task_fsm_rev_1"`) &&
		   strings.contains(cmd.body_json, `"action":"review"`) &&
		   strings.contains(cmd.body_json, `"reviewer_instance_ids":["inst_rev_idle"]`) {
			found_r1_notify = true
		}
	}
	testing.expect(t, found_r1_notify, "inst_rev_idle must receive task_status_changed_notify review wake")

	for cmd in captured_cmds do delete(cmd.body_json)
	clear(&captured_cmds)

	// =========================================================================
	// REQ-FSM-REV-2: JIT provisioning reviewer when under capacity
	// =========================================================================
	// inst_rev_idle is now busy reviewing task_fsm_rev_1.
	// Create second task with declarative agt_fsm_reviewer ref.
	t2 := domain.Task{
		task_id            = "task_fsm_rev_2",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "FSM Reviewer Task 2 (JIT)",
		publish_state      = .Published,
		status             = .In_Progress,
		priority           = .P1,
		assignee_ref_json  = `{"type":"agent_instance","agent_instance_id":"inst_worker_1"}`,
		reviewer_refs_json = `[{"type":"agent_id","agent_id":"agt_fsm_reviewer"}]`,
		bridge_id          = "brg_fsm_rev",
		created_at         = "2026-10-01T10:02:00Z",
		updated_at         = "2026-10-01T10:02:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, t2)

	// Transition t2 to .In_Validation via change_task_status
	ret2, ok2, err2 := change_task_status(&svc, auth_user, "task_fsm_rev_2", .In_Validation)
	testing.expect(t, ok2, "change_task_status for JIT reviewer task must succeed")
	testing.expect_value(t, err2.code, domain.Error_Code.None)
	testing.expect_value(t, ret2.status, domain.Task_Status.In_Validation)

	// Acceptance criteria:
	// - Since inst_rev_idle is busy reviewing t1, and live_count (1) < capacity (2), JIT provisions a new instance
	rev_insts2 := extract_instances_from_ref_blob(ret2.reviewer_refs_json)
	defer delete(rev_insts2)
	testing.expect_value(t, len(rev_insts2), 1)
	jit_rev_id := ""
	if len(rev_insts2) == 1 {
		jit_rev_id = rev_insts2[0]
		testing.expect(t, jit_rev_id != "", "must bind provisioned reviewer instance")
		testing.expect(t, jit_rev_id != "inst_rev_idle", "must provision a distinct reviewer instance")
		testing.expect(t, jit_rev_id != "inst_worker_1", "reviewer instance must not be worker instance")
	}

	// Persisted row verification
	persisted2, p2_ok, _ := iface.taskchain_get_task(&tc_repo, "task_fsm_rev_2")
	testing.expect(t, p2_ok, "task 2 must exist")
	p_rev_insts2 := extract_instances_from_ref_blob(persisted2.reviewer_refs_json)
	defer delete(p_rev_insts2)
	testing.expect_value(t, len(p_rev_insts2), 1)
	if len(p_rev_insts2) == 1 {
		testing.expect_value(t, p_rev_insts2[0], jit_rev_id)
	}

	// JIT reviewer instance was created in ag_repo with role .Review
	if jit_rev_id != "" {
		jit_rev_inst, j_ok, _ := iface.agent_get_instance(&ag_repo, jit_rev_id)
		testing.expect(t, j_ok, "provisioned JIT reviewer instance must exist in agent repository")
		testing.expect_value(t, jit_rev_inst.agent_id, "agt_fsm_reviewer")
		testing.expect_value(t, jit_rev_inst.model, "claude-sonnet-5-5")
		testing.expect_value(t, jit_rev_inst.current_task_id, "task_fsm_rev_2")
		testing.expect_value(t, jit_rev_inst.current_task_role, domain.Current_Task_Role.Review)
	}

	// REQ-FSM-REV-3: JIT reviewer received review notification
	found_r2_notify := false
	for cmd in captured_cmds {
		if strings.contains(cmd.body_json, `"type":"task_status_changed_notify"`) &&
		   strings.contains(cmd.body_json, `"task_id":"task_fsm_rev_2"`) &&
		   strings.contains(cmd.body_json, `"action":"review"`) &&
		   strings.contains(cmd.body_json, jit_rev_id) {
			found_r2_notify = true
		}
	}
	testing.expect(t, found_r2_notify, "newly JIT-provisioned reviewer must receive task_status_changed_notify review wake")

	for cmd in captured_cmds do delete(cmd.body_json)
	clear(&captured_cmds)

	// =========================================================================
	// Part 3: Fallback to chain.default_reviewer_refs_json on in_validation
	// =========================================================================
	chain.default_reviewer_refs_json = `[{"type":"agent_id","agent_id":"agt_fsm_reviewer"}]`
	_, _, _ = iface.taskchain_save_chain(&tc_repo, chain)

	rev_fleet.capacity = 3
	_, _ = iface.taskchain_upsert_fleet(&tc_repo, rev_fleet)

	t3 := domain.Task{
		task_id            = "task_fsm_rev_3",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "FSM Reviewer Task 3 (Default Fallback)",
		publish_state      = .Published,
		status             = .In_Progress,
		priority           = .P1,
		assignee_ref_json  = `{"type":"agent_instance","agent_instance_id":"inst_worker_1"}`,
		reviewer_refs_json = "[]",
		bridge_id          = "brg_fsm_rev",
		created_at         = "2026-10-01T10:03:00Z",
		updated_at         = "2026-10-01T10:03:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, t3)

	ret3, ok3, err3 := change_task_status(&svc, auth_user, "task_fsm_rev_3", .In_Validation)
	testing.expect(t, ok3, "change_task_status with default reviewer fallback must succeed")
	testing.expect_value(t, err3.code, domain.Error_Code.None)
	testing.expect_value(t, ret3.status, domain.Task_Status.In_Validation)

	rev_insts3 := extract_instances_from_ref_blob(ret3.reviewer_refs_json)
	defer delete(rev_insts3)
	testing.expect_value(t, len(rev_insts3), 1)
	jit_rev_id3 := ""
	if len(rev_insts3) == 1 {
		jit_rev_id3 = rev_insts3[0]
		testing.expect(t, jit_rev_id3 != "", "must bind provisioned reviewer instance from default refs")
		testing.expect(t, jit_rev_id3 != "inst_rev_idle", "must be distinct from inst_rev_idle")
		testing.expect(t, jit_rev_id3 != jit_rev_id, "must be distinct from jit_rev_id")
	}

	for cmd in captured_cmds do delete(cmd.body_json)
	clear(&captured_cmds)

	// =========================================================================
	// Part 4: Reconcile pass parity when capacity was saturated
	// =========================================================================
	// Currently all 3 reviewer instances are busy (inst_rev_idle on t1, jit_rev_id on t2, jit_rev_id3 on t3).
	// Creating task 4 with capacity = 3 means it cannot bind immediately on transition.
	t4 := domain.Task{
		task_id            = "task_fsm_rev_4",
		chain_id           = chain_id,
		owner_user_id      = owner,
		title              = "FSM Reviewer Task 4 (Saturated Queued)",
		publish_state      = .Published,
		status             = .In_Progress,
		priority           = .P1,
		assignee_ref_json  = `{"type":"agent_instance","agent_instance_id":"inst_worker_1"}`,
		reviewer_refs_json = `[{"type":"agent_id","agent_id":"agt_fsm_reviewer"}]`,
		bridge_id          = "brg_fsm_rev",
		created_at         = "2026-10-01T10:04:00Z",
		updated_at         = "2026-10-01T10:04:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&tc_repo, t4)

	ret4, ok4, _ := change_task_status(&svc, auth_user, "task_fsm_rev_4", .In_Validation)
	testing.expect(t, ok4, "change_task_status to In_Validation must succeed even when saturated")
	// Reviewer ref should remain declarative since all instances are busy and at capacity
	testing.expect(t, strings.contains(ret4.reviewer_refs_json, `"type":"agent_id"`), "reviewer refs must remain declarative when saturated")

	// Complete task 1 to free up inst_rev_idle
	_, _, _ = change_task_status(&svc, auth_user, "task_fsm_rev_1", .Completed)

	// Now run reconcile pass
	_ = reconcile_chain(&svc, chain)

	// Task 4 should now have inst_rev_idle bound by the reconcile pass in promotion.odin!
	persisted4, p4_ok, _ := iface.taskchain_get_task(&tc_repo, "task_fsm_rev_4")
	testing.expect(t, p4_ok, "task 4 must exist")
	p_rev_insts4 := extract_instances_from_ref_blob(persisted4.reviewer_refs_json)
	defer delete(p_rev_insts4)
	testing.expect_value(t, len(p_rev_insts4), 1)
	if len(p_rev_insts4) == 1 {
		testing.expect_value(t, p_rev_insts4[0], "inst_rev_idle")
	}

	for cmd in captured_cmds do delete(cmd.body_json)
	clear(&captured_cmds)

	// Clean up
	ret2.status = .Completed
	_, _, _ = iface.taskchain_save_task(&tc_repo, ret2)
	ret3.status = .Completed
	_, _, _ = iface.taskchain_save_task(&tc_repo, ret3)
	persisted4.status = .Completed
	_, _, _ = iface.taskchain_save_task(&tc_repo, persisted4)
}





@(test)
test_fleet_reconcile_resolves_bridge_models_without_manual_configuration :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/fleet_launch_defaults_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)
	conn, opened, _ := sqlite.open(db_path)
	if !testing.expect(t, opened) do return
	defer sqlite.close(&conn)
	migrated, _ := sqlite.run_migrations(&conn)
	if !testing.expect(t, migrated) do return
	tc_impl: sqlite.Taskchain_Repo_SQLite
	tc_repo := sqlite.new_taskchain_repository(&tc_impl, &conn)
	ag_impl: sqlite.Agent_Repo_SQLite
	ag_repo := sqlite.new_agent_repository(&ag_impl, &conn)
	br_impl: sqlite.Bridge_Repo_SQLite
	br_repo := sqlite.new_bridge_repository(&br_impl, &conn)
	co_impl: sqlite.Content_Repo_SQLite
	co_repo := sqlite.new_content_repository(&co_impl, &conn)
	provider_impl: sqlite.Provider_Repo_SQLite
	providers := sqlite.new_provider_repository(&provider_impl, &conn)
	owner := domain.User_ID("fleet_defaults_owner")
	chain := domain.Task_Chain{chain_id="fleet_defaults_chain",owner_user_id=owner,title="Defaults",publish_state=.Published,status=.Active}
	_, _, _ = iface.taskchain_save_chain(&tc_repo, chain)
	_, _, _ = iface.bridge_save_bridge(&br_repo, domain.Bridge{bridge_id="fleet_defaults_bridge",owner_user_id=owner,status=.Online})
	_, _, _ = iface.agent_save(&ag_repo, domain.Agent{agent_id="fleet_defaults_worker",owner_user_id=owner,name="Worker",slug="worker"})
	_, _ = iface.bridge_provider_status_upsert(&providers, domain.Bridge_Provider_Status{bridge_id="fleet_defaults_bridge",provider="codex",state="present"})
	_, _ = iface.bridge_provider_setting_upsert(&providers, domain.Bridge_Provider_Setting{bridge_id="fleet_defaults_bridge",provider="codex",enabled=true})
	registry: project_service.Bridge_Runtime_Registry
	project_service.bridge_runtime_registry_mark_live(&registry, "fleet_defaults_bridge", false, "")
	sink := project_service.Bridge_Command_Sink{send_runtime_command=proc(ctx: rawptr, cmd: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {return true, {}}}
	clock := platform.real_clock()
	ids := platform.real_id_generator()
	ag_service := agent_service.new_agent_service_with_runtime(&ag_repo, &br_repo, nil, &co_repo, &tc_repo, sink, &registry, &clock, &ids)
	ag_service.providers = &providers
	svc := new_taskchain_service_with_runtime(&tc_repo, &ag_repo, sink, &clock, &ids)
	svc.agent_service = &ag_service
	task := domain.Task{task_id="fleet_defaults_task",chain_id=chain.chain_id,owner_user_id=owner,title="Work",status=.Queued,publish_state=.Published,assignee_ref_json=`{"type":"agent_id","agent_id":"fleet_defaults_worker"}`,reviewer_refs_json="[]",bridge_id="fleet_defaults_bridge"}
	_, _, _ = iface.taskchain_save_task(&tc_repo, task)
	_ = reconcile_chain(&svc, chain)
	saved, found, _ := iface.taskchain_get_task(&tc_repo, task.task_id)
	if !testing.expect(t, found) do return
	iid := primary_assignee_instance(saved.assignee_ref_json)
	defer delete(iid)
	if !testing.expect(t, iid != "", "reconcile binds a concrete instance without a provider/model edit") do return
	inst, exists, _ := iface.agent_get_instance(&ag_repo, iid)
	testing.expect(t, exists)
	testing.expect_value(t, inst.provider, "codex")
	testing.expect_value(t, inst.model, "gpt-5.6-sol")
	testing.expect_value(t, inst.bridge_id, "fleet_defaults_bridge")
	fleet := domain.Task_Chain_Fleet{task_chain_id=chain.chain_id,agent_id="fleet_defaults_worker",capacity=2,bridge_models_json=`{"fleet_defaults_bridge":{"provider":"codex","model":"gpt-5.6-terra"}}`}
	auth := contracts.Auth_Context{user_id=string(owner),kind=.User_Token}
	_, save_err := upsert_fleet(&svc, auth, Upsert_Fleet_Input{chain_id=chain.chain_id,agent_id=fleet.agent_id,capacity=2,bridge_models_json=fleet.bridge_models_json})
	testing.expect_value(t, save_err.code, domain.Error_Code.None)
	preserved, preserve_err := upsert_fleet(&svc, auth, Upsert_Fleet_Input{chain_id=chain.chain_id,agent_id=fleet.agent_id,capacity=3})
	testing.expect_value(t, preserve_err.code, domain.Error_Code.None)
	testing.expect_value(t, preserved.bridge_models_json, fleet.bridge_models_json)
	_, invalid_err := upsert_fleet(&svc, auth, Upsert_Fleet_Input{chain_id=chain.chain_id,agent_id=fleet.agent_id,capacity=2,bridge_models_json=`{"fleet_defaults_bridge":{"provider":"codex","model":"unknown"}}`})
	testing.expect_value(t, invalid_err.code, domain.Error_Code.Unprocessable_Entity)
	second_task := task
	second_task.task_id = "fleet_defaults_second_task"
	_, _, _ = iface.taskchain_save_task(&tc_repo, second_task)
	_ = reconcile_chain(&svc, chain)
	second_saved, _, _ := iface.taskchain_get_task(&tc_repo, second_task.task_id)
	second := primary_assignee_instance(second_saved.assignee_ref_json)
	defer delete(second)
	if !testing.expect(t, second != "", "bridge-specific selection provisions") do return
	second_inst, _, _ := iface.agent_get_instance(&ag_repo, second)
	testing.expect_value(t, second_inst.model, "gpt-5.6-terra")
	p, m := resolve_fleet_launch_model(&svc, "fleet_defaults_bridge", "claude", "pinned")
	defer delete(p)
	defer delete(m)
	testing.expect_value(t, p, "claude")
	testing.expect_value(t, m, "pinned")
}
