package taskchain

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import agent_service "odin_test:hub/service/agent"
import project_service "odin_test:hub/service/project"

// REQ-ERR-PROTO-A: promotion obeys a failed instance's typed error class, through a
// full reconcile_chain over SQLite. A held failure (backing off, recoverable, fatal)
// keeps its pool slot: no wake, no JIT replacement, no task rebinding. A retriable
// failure whose backoff has elapsed is re-woken in place, never replaced. Pool slots
// are counted per pinned bridge (REQ-TB-HUB-1), so a held instance on another bridge
// does not block provisioning. (An untyped failure is still replaced:
// test_fsm_watchdog_auto_recovery_crashed_worker_respawn.)

@(private = "file")
EP_AGENT :: "agt_ep_worker"

@(private = "file")
Ep_Scenario :: struct {
	tag:             string,
	last_error_json: string,
	failed_at:       string, // the failed instance's stopped_at
	failed_bridge:   string, // the failed instance's bridge
	pin_bridge:      string, // bridge the queued/review tasks are pinned to ("" = unpinned)
	review_task:     bool,   // queue a review that wants an EP_AGENT reviewer
	no_queued_work:  bool,   // skip the queued work task
}

@(private = "file")
Ep_Result :: struct {
	commands:       string,   // every runtime command body, concatenated (temp)
	worker_bridges: []string, // bridge of every EP_AGENT instance (temp)
	running_bound:  string,   // assignee_ref_json of the in-progress task (temp)
}

@(private = "file")
run_failed_worker_scenario :: proc(t: ^testing.T, sc: Ep_Scenario) -> Ep_Result {
	db_path := fmt.tprintf("/tmp/test_err_proto_held_%s_%d.db", sc.tag, os.get_pid())
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

	owner := domain.User_ID("user_err_proto")
	chain_id := domain.Task_Chain_ID("chain_err_proto")
	now := "2026-10-01T10:00:00Z"

	registry := project_service.Bridge_Runtime_Registry{}
	defer project_service.bridge_runtime_registry_destroy(&registry)
	_, _, _ = iface.project_save(&pr_repo, domain.Project{project_id = "prj_ep", owner_user_id = owner, name = "EP", slug = "ep", default_path = "/srv/ep", state = .Active, created_at = now, updated_at = now})
	_, _, _ = iface.agent_save(&ag_repo, domain.Agent{agent_id = EP_AGENT, owner_user_id = owner, name = "EP Worker", slug = "ep-worker", created_at = now, updated_at = now})
	for bridge_id in ([]string{"brg_ep_a", "brg_ep_b"}) {
		_, _, _ = iface.bridge_save_bridge(&br_repo, domain.Bridge{
			bridge_id = bridge_id, owner_user_id = owner, machine_hostname = "localhost", status = .Online,
			capabilities_json = `{"capabilities":[{"provider":"claude","models":["claude-sonnet-5-5"],"default_model":"claude-sonnet-5-5"}],"provider":"claude","default_model":"claude-sonnet-5-5"}`,
			created_at = now, updated_at = now,
		})
		_, _ = iface.bridge_provider_status_upsert(&providers, domain.Bridge_Provider_Status{bridge_id = bridge_id, provider = "claude", state = "present"})
		_, _ = iface.bridge_provider_setting_upsert(&providers, domain.Bridge_Provider_Setting{bridge_id = bridge_id, provider = "claude", enabled = true})
		_, _, _ = iface.project_save_bridge_path(&pr_repo, domain.Project_Bridge_Path{project_id = "prj_ep", bridge_id = bridge_id, owner_user_id = owner, path = "/srv/ep", created_at = now, updated_at = now})
		_, _, _ = iface.agent_save_support(&ag_repo, domain.Agent_Bridge_Support{agent_id = EP_AGENT, bridge_id = bridge_id, owner_user_id = owner, enabled = true})
		project_service.bridge_runtime_registry_mark_live(&registry, bridge_id, false, "")
	}

	captured_cmds := make([dynamic]project_service.Runtime_Command)
	defer {
		for cmd in captured_cmds do delete(cmd.body_json)
		delete(captured_cmds)
	}
	sink := project_service.Bridge_Command_Sink{
		ctx = rawptr(&captured_cmds),
		send_runtime_command = proc(ctx: rawptr, cmd: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
			captured := cmd
			captured.body_json = strings.clone(cmd.body_json)
			append((^[dynamic]project_service.Runtime_Command)(ctx), captured)
			return true, domain.Domain_Error{}
		},
	}
	svc := new_taskchain_service_with_runtime(&tc_repo, &ag_repo, sink, &clock, &ids)
	ag_service := agent_service.new_agent_service_with_runtime(&ag_repo, &br_repo, &pr_repo, &co_repo, &tc_repo, sink, &registry, &clock, &ids)
	ag_service.providers = &providers
	svc.agent_service = &ag_service

	chain := domain.Task_Chain{chain_id = chain_id, owner_user_id = owner, title = "EP", publish_state = .Published, status = .Active, kind = "test", coordinator_agent_instance_id = "inst_ep_coord", created_at = now, updated_at = now}
	_, _, _ = iface.taskchain_save_chain(&tc_repo, chain)
	_, _, _ = iface.agent_save_instance(&ag_repo, domain.Agent_Instance{agent_instance_id = "inst_ep_coord", owner_user_id = owner, agent_id = "agt_coordinator", bridge_id = "brg_ep_a", project_id = "prj_ep", runtime_status = "running", chain_id = string(chain_id), created_at = now, updated_at = now})
	_, _ = iface.taskchain_upsert_fleet(&tc_repo, domain.Task_Chain_Fleet{task_chain_id = chain_id, agent_id = EP_AGENT, capacity = 1, min_warm = 1, idle_ttl_seconds = 300, provider = "claude", model = "claude-sonnet-5-5", created_at = now, updated_at = now})

	_, _, _ = iface.agent_save_instance(&ag_repo, domain.Agent_Instance{
		agent_instance_id = "inst_ep_failed", owner_user_id = owner, agent_id = EP_AGENT, bridge_id = sc.failed_bridge, project_id = "prj_ep",
		provider = "claude", model = "claude-sonnet-5-5",
		runtime_status = "failed", stopped_at = sc.failed_at, last_error_json = sc.last_error_json, chain_id = string(chain_id), created_at = now, updated_at = now,
	})
	// One task in progress on the failed worker, one queued for the same agent.
	_, _, _ = iface.taskchain_save_task(&tc_repo, domain.Task{task_id = "task_ep_running", chain_id = chain_id, owner_user_id = owner, title = "running", publish_state = .Published, status = .In_Progress, priority = .P1,
		assignee_ref_json = `{"type":"agent_instance","agent_instance_id":"inst_ep_failed"}`, reviewer_refs_json = "[]", created_at = now, updated_at = now})
	if !sc.no_queued_work do _, _, _ = iface.taskchain_save_task(&tc_repo, domain.Task{task_id = "task_ep_queued", chain_id = chain_id, owner_user_id = owner, title = "queued", publish_state = .Published, status = .Queued, priority = .P1,
		bridge_id = sc.pin_bridge, assignee_ref_json = `{"type":"agent_id","agent_id":"agt_ep_worker"}`, reviewer_refs_json = "[]", created_at = now, updated_at = now})
	if sc.review_task {
		_, _, _ = iface.taskchain_save_task(&tc_repo, domain.Task{task_id = "task_ep_review", chain_id = chain_id, owner_user_id = owner, title = "review", publish_state = .Published, status = .In_Validation, priority = .P1,
			bridge_id = sc.pin_bridge, assignee_ref_json = `{"type":"agent_instance","agent_instance_id":"inst_ep_coord"}`,
			reviewer_refs_json = `[{"type":"agent_id","agent_id":"agt_ep_worker"}]`, created_at = now, updated_at = now})
	}

	_ = reconcile_chain(&svc, chain)

	res: Ep_Result
	b := strings.builder_make(context.temp_allocator)
	for cmd in captured_cmds do strings.write_string(&b, cmd.body_json)
	res.commands = strings.to_string(b)
	instances, _ := iface.agent_list_instances_by_owner(&ag_repo, owner, 100)
	bridges := make([dynamic]string, context.temp_allocator)
	for &inst in instances {
		if inst.agent_id == EP_AGENT do append(&bridges, strings.clone(inst.bridge_id, context.temp_allocator))
		domain.agent_instance_destroy(&inst)
	}
	delete(instances)
	res.worker_bridges = bridges[:]
	if persisted, ok, _ := iface.taskchain_get_task(&tc_repo, "task_ep_running"); ok {
		res.running_bound = strings.clone(persisted.assignee_ref_json, context.temp_allocator)
	}
	return res
}

@(private = "file")
expect_held :: proc(t: ^testing.T, tag, last_error_json: string) {
	res := run_failed_worker_scenario(t, {tag = tag, last_error_json = last_error_json, failed_at = "2026-10-01T10:00:00Z", failed_bridge = "brg_ep_a"})
	testing.expectf(t, !strings.contains(res.commands, "inst_ep_failed"), "%s: held instance must not be woken: %s", tag, res.commands)
	testing.expectf(t, !strings.contains(res.commands, "launch_agent"), "%s: no replacement launch: %s", tag, res.commands)
	testing.expectf(t, len(res.worker_bridges) == 1, "%s: no replacement instance provisioned (%v)", tag, res.worker_bridges)
	testing.expectf(t, strings.contains(res.running_bound, "inst_ep_failed"), "%s: in-progress task stays bound: %s", tag, res.running_bound)
}

@(test)
test_err_proto_fatal_failure_is_neither_woken_nor_replaced :: proc(t: ^testing.T) {
	expect_held(t, "fatal", `{"code":"unprocessable_entity","class":"fatal","cause":"agent_bootstrap_invalid","message":"","attempt":1}`)
}

@(test)
test_err_proto_recoverable_failure_is_neither_woken_nor_replaced :: proc(t: ^testing.T) {
	expect_held(t, "recoverable", `{"code":"provider_unavailable","class":"recoverable","cause":"provider_not_logged_in","message":"","attempt":1}`)
}

@(test)
test_err_proto_retriable_in_backoff_is_neither_woken_nor_replaced :: proc(t: ^testing.T) {
	// Failed "now" (wall clock), attempt 1: the 60s backoff has not elapsed.
	res := run_failed_worker_scenario(t, {tag = "backoff", failed_at = platform.real_clock_now(nil),
		last_error_json = `{"code":"bridge_busy","class":"retriable","cause":"pty_host_unreachable","message":"","attempt":1}`, failed_bridge = "brg_ep_a"})
	testing.expectf(t, !strings.contains(res.commands, "inst_ep_failed"), "backing off: no wake yet: %s", res.commands)
	testing.expectf(t, !strings.contains(res.commands, "launch_agent"), "backing off: no replacement: %s", res.commands)
	testing.expectf(t, len(res.worker_bridges) == 1, "backing off: one instance (%v)", res.worker_bridges)
}

@(test)
test_err_proto_due_retriable_failure_is_rewoken_not_replaced :: proc(t: ^testing.T) {
	// Failed long ago, attempt 1: the backoff has elapsed, so the hub re-dispatches it.
	res := run_failed_worker_scenario(t, {tag = "retry", failed_at = "2026-10-01T10:00:00Z",
		last_error_json = `{"code":"bridge_busy","class":"retriable","cause":"pty_host_unreachable","message":"","attempt":1}`, failed_bridge = "brg_ep_a"})
	testing.expectf(t, strings.contains(res.commands, `"type":"wake_agent"`) && strings.contains(res.commands, "inst_ep_failed"), "the original instance is re-woken: %s", res.commands)
	testing.expectf(t, !strings.contains(res.commands, "launch_agent"), "no replacement launch: %s", res.commands)
	testing.expectf(t, len(res.worker_bridges) == 1, "one instance (%v)", res.worker_bridges)
	testing.expectf(t, strings.contains(res.running_bound, "inst_ep_failed"), "in-progress task stays bound: %s", res.running_bound)
}

@(private = "file")
expect_provisioned_on_pinned_bridge :: proc(t: ^testing.T, tag: string, review: bool) {
	// The held instance is on bridge A; the new work (or review) is pinned to B.
	res := run_failed_worker_scenario(t, {tag = tag, failed_at = "2026-10-01T10:00:00Z", failed_bridge = "brg_ep_a", pin_bridge = "brg_ep_b",
		review_task = review, no_queued_work = review,
		last_error_json = `{"code":"provider_unavailable","class":"recoverable","cause":"provider_missing","message":"","attempt":1}`})
	on_b := 0
	for b in res.worker_bridges do if b == "brg_ep_b" do on_b += 1
	testing.expectf(t, on_b == 1, "%s: one instance is provisioned on the pinned bridge despite the held one on A (%v)", tag, res.worker_bridges)
	testing.expectf(t, !strings.contains(res.commands, "inst_ep_failed"), "%s: the held instance is still not woken: %s", tag, res.commands)
}

@(test)
test_err_proto_held_failure_on_other_bridge_does_not_block_pinned_worker :: proc(t: ^testing.T) {
	expect_provisioned_on_pinned_bridge(t, "pinned_worker", false)
}

@(test)
test_err_proto_held_failure_on_other_bridge_does_not_block_pinned_reviewer :: proc(t: ^testing.T) {
	expect_provisioned_on_pinned_bridge(t, "pinned_reviewer", true)
}
