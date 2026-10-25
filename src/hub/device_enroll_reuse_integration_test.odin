package main

// REQ-BE end-to-end: re-enrolling a machine as NEW vs REUSING its previous bridge
// identity, through the production device-flow endpoints, the real minter and the
// production commit / reaper rollback (helpers in device_enroll_attach_test.odin).
//
// What "reuse" must preserve is everything keyed by bridge_id that the user built on
// the old bridge: agent instances, task-chain fleet placement and project paths.
// None of those rows is touched by enrollment, so these tests seed them on bridge A
// and assert that, after each outcome, they still name A and A is still the bridge
// they resolve to:
//
//   - reuse + commit: same bridge_id, rows still bound, old hba_/hbf_ credentials
//     rejected, old vault identity retired, the new identity live on A;
//   - hint A but the approver chooses NEW: a different bridge_id, A untouched;
//   - a pending attach onto A that is cancelled, or that the reaper expires: A, its
//     credentials, its vault identity and its rows exactly as before.

import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import api_http "odin_test:hub/transport/http"
import bridge_service "odin_test:hub/service/bridge"

@(private = "file")
REUSE_CHAIN_ID :: "chain_reuse_e2e"
@(private = "file")
REUSE_INSTANCE_ID :: "inst_reuse_e2e"
@(private = "file")
REUSE_AGENT_ID :: "agt_reuse_e2e"
@(private = "file")
REUSE_PROJECT_ID :: "proj_reuse_e2e"
@(private = "file")
REUSE_PROJECT_PATH :: "/home/tester/src/reuse-e2e"
@(private = "file")
REUSE_SEEDED_AT :: "2026-10-20T10:00:00Z"

// reuse_seed_dependents binds an agent instance, a fleet row and a project path to
// bridge_id, as a user who had been working on that bridge would have.
@(private = "file")
reuse_seed_dependents :: proc(t: ^testing.T, graph: ^app.App_Graph, user_id, bridge_id: string) -> bool {
	_, inst_ok, inst_err := iface.agent_save_instance(&graph.repos.agents, domain.Agent_Instance{
		agent_instance_id = REUSE_INSTANCE_ID,
		owner_user_id     = domain.User_ID(user_id),
		agent_id          = REUSE_AGENT_ID,
		bridge_id         = bridge_id,
		display_name      = "reuse e2e instance",
		chain_id          = REUSE_CHAIN_ID,
		runtime_status    = "stopped",
		startup_status    = "ready",
		created_at        = REUSE_SEEDED_AT,
		updated_at        = REUSE_SEEDED_AT,
	})
	testing.expect(t, inst_ok, inst_err.message)

	_, chain_ok, chain_err := iface.taskchain_save_chain(&graph.repos.taskchains, domain.Task_Chain{
		chain_id      = REUSE_CHAIN_ID,
		owner_user_id = domain.User_ID(user_id),
		title         = "reuse e2e chain",
		publish_state = .Draft,
		status        = .Active,
		kind          = domain.CHAIN_KIND_MIXED_WORK,
		created_at    = REUSE_SEEDED_AT,
		updated_at    = REUSE_SEEDED_AT,
	})
	testing.expect(t, chain_ok, chain_err.message)
	_, fleet_err := iface.taskchain_upsert_fleet(&graph.repos.taskchains, domain.Task_Chain_Fleet{
		task_chain_id = REUSE_CHAIN_ID,
		agent_id      = REUSE_AGENT_ID,
		capacity      = 1,
		roles_json    = `["worker"]`,
		bridge_id     = bridge_id,
		created_at    = REUSE_SEEDED_AT,
		updated_at    = REUSE_SEEDED_AT,
	})
	testing.expect(t, fleet_err.code == .None, fleet_err.message)

	_, path_ok, path_err := iface.project_save_bridge_path(&graph.repos.projects, domain.Project_Bridge_Path{
		project_id    = REUSE_PROJECT_ID,
		bridge_id     = bridge_id,
		owner_user_id = domain.User_ID(user_id),
		path          = REUSE_PROJECT_PATH,
		is_validated  = true,
		created_at    = REUSE_SEEDED_AT,
		updated_at    = REUSE_SEEDED_AT,
	})
	testing.expect(t, path_ok, path_err.message)
	return inst_ok && chain_ok && fleet_err.code == .None && path_ok
}

// reuse_expect_dependents_on asserts the seeded rows still name bridge_id and that
// bridge_id is a live (not revoked) bridge of user_id they resolve to.
@(private = "file")
reuse_expect_dependents_on :: proc(t: ^testing.T, graph: ^app.App_Graph, user_id, bridge_id, when_: string) {
	bridge, found, _ := iface.bridge_get_bridge(graph.bridges.repo, bridge_id)
	testing.expectf(t, found, "%s: bridge %s still exists", when_, bridge_id)
	if found {
		testing.expectf(t, bridge.status != .Revoked, "%s: bridge %s is not revoked", when_, bridge_id)
		testing.expectf(t, string(bridge.owner_user_id) == user_id, "%s: bridge %s keeps its owner", when_, bridge_id)
		domain.bridge_destroy(&bridge)
	}

	inst, inst_ok, _ := iface.agent_get_instance(&graph.repos.agents, REUSE_INSTANCE_ID)
	testing.expectf(t, inst_ok && inst.bridge_id == bridge_id, "%s: agent instance still on %s (got %q)", when_, bridge_id, inst.bridge_id)
	on_bridge, _ := iface.agent_list_instances_by_bridge(&graph.repos.agents, bridge_id)
	listed := false
	for i in on_bridge do if i.agent_instance_id == REUSE_INSTANCE_ID do listed = true
	testing.expectf(t, listed, "%s: bridge %s still lists the agent instance", when_, bridge_id)

	fleets, _ := iface.taskchain_list_fleets_by_chain(&graph.repos.taskchains, REUSE_CHAIN_ID, domain.User_ID(user_id))
	testing.expectf(t, len(fleets) == 1 && fleets[0].bridge_id == bridge_id, "%s: fleet row still placed on %s", when_, bridge_id)

	path, path_ok, _ := iface.project_get_bridge_path(&graph.repos.projects, REUSE_PROJECT_ID, bridge_id)
	testing.expectf(t, path_ok && path.path == REUSE_PROJECT_PATH, "%s: project path still bound to %s", when_, bridge_id)
}

// reuse_token_bridge returns the bridge an access token authenticates as, "" if none.
@(private = "file")
reuse_token_bridge :: proc(graph: ^app.App_Graph, token: string) -> string {
	auth, ok, _ := bridge_service.verify_bridge_token(&graph.bridges, token)
	return auth.bridge_id if ok else ""
}

@(private = "file")
reuse_refresh_works :: proc(graph: ^app.App_Graph, refresh_token: string) -> bool {
	_, ok, _ := bridge_service.refresh_bridge_token(&graph.bridges, refresh_token)
	return ok
}

// reuse_far_future is a clock past every pending deadline these tests create.
@(private = "file")
reuse_far_future :: proc(_: rawptr) -> string {
	return "2099-01-01T00:00:00Z"
}

// Bridge A enrolled and committed, with dependents seeded on it.
@(private = "file")
Reuse_Fixture :: struct {
	graph:   app.App_Graph,
	db_path: string,
	user_id: string,
	first:   Attach_Enrollment,
	alice:   [1]contracts.HTTP_Header,
}

@(private = "file")
reuse_fixture_open :: proc(t: ^testing.T, f: ^Reuse_Fixture, user: string, name: string) -> bool {
	db_path, built := attach_test_graph(t, &f.graph, name)
	f.db_path = db_path
	if !built do return false
	f.alice = hub_test_user_headers(&f.graph, user)
	headers := f.alice[:]
	f.user_id = vt_user_id(&f.graph, headers)
	first, first_ok := attach_enroll(&f.graph, headers, "alice-box")
	f.first = first
	if !first_ok || first.approve_status != 200 || !attach_commit(&f.graph, first.bridge_id) {
		testing.expect(t, false, "bridge A enrolls and commits")
		return false
	}
	testing.expect(t, first.refresh_token != "", "the poll returns an hbf_ refresh token")
	return reuse_seed_dependents(t, &f.graph, f.user_id, first.bridge_id)
}

@(private = "file")
reuse_fixture_close :: proc(f: ^Reuse_Fixture, built: bool) {
	if built do app.shutdown_graph(&f.graph)
	_ = os.remove(f.db_path)
}

@(test)
test_reenroll_reuse_keeps_bridge_id_and_dependents_and_revokes_old_credentials :: proc(t: ^testing.T) {
	f: Reuse_Fixture
	opened := reuse_fixture_open(t, &f, "alice", "reuse-e2e")
	defer reuse_fixture_close(&f, f.db_path != "" && f.user_id != "")
	if !opened do return
	a := f.first.bridge_id
	reuse_expect_dependents_on(t, &f.graph, f.user_id, a, "before re-enroll")

	// The machine re-enrolls hinting A; the approver chooses Reuse (target A).
	again, again_ok := attach_enroll(&f.graph, f.alice[:], "alice-box", target_bridge_id = a, previous_bridge_id = a)
	testing.expect(t, again_ok && again.approve_status == 200, again.approve_body)
	if !again_ok do return
	testing.expect(t, strings.contains(again.verify_body, strings.concatenate({`"previous_bridge_id":"`, a, `"`}, context.temp_allocator)), again.verify_body)
	testing.expect_value(t, again.bridge_id, a)
	testing.expect(t, again.identity_id != f.first.identity_id, "the re-enrolled machine has a fresh vault identity")
	testing.expect(t, attach_commit(&f.graph, a), "the reuse attach commits")

	// Same id; everything the user built on A is still bound to A.
	reuse_expect_dependents_on(t, &f.graph, f.user_id, a, "after reuse commit")
	bridges, _ := bridge_service.list_bridges(&f.graph.bridges, contracts.Auth_Context{user_id = f.user_id})
	testing.expect_value(t, len(bridges), 1)

	// The old machine's credentials are dead; the new ones authenticate as A.
	testing.expect_value(t, reuse_token_bridge(&f.graph, f.first.access_token), "")
	testing.expect(t, !reuse_refresh_works(&f.graph, f.first.refresh_token), "the old hbf_ refresh token is rejected")
	testing.expect_value(t, reuse_token_bridge(&f.graph, again.access_token), a)

	// The old vault device is retired; the new identity is the live one on A.
	old_row, old_found := attach_vault_row(&f.graph, f.user_id, f.first.identity_id)
	testing.expect(t, old_found && old_row.retired_at != "", "the old vault device is retired")
	new_row, new_found := attach_vault_row(&f.graph, f.user_id, again.identity_id)
	testing.expect(t, new_found && new_row.retired_at == "" && new_row.bridge_id == a, "the new vault device is live on A")

	// The rotated credential keeps working as A (refresh is not tied to the old lineage).
	testing.expect(t, reuse_refresh_works(&f.graph, again.refresh_token), "the new hbf_ refresh token works")
}

@(test)
test_reenroll_hint_but_approved_as_new_creates_new_bridge_and_leaves_old_untouched :: proc(t: ^testing.T) {
	f: Reuse_Fixture
	opened := reuse_fixture_open(t, &f, "alice", "reuse-e2e-new")
	defer reuse_fixture_close(&f, f.db_path != "" && f.user_id != "")
	if !opened do return
	a := f.first.bridge_id

	// The hint is offered, but the approver picks New (no target_bridge_id).
	fresh, fresh_ok := attach_enroll(&f.graph, f.alice[:], "alice-box-2", previous_bridge_id = a)
	testing.expect(t, fresh_ok && fresh.approve_status == 200, fresh.approve_body)
	if !fresh_ok do return
	testing.expect(t, strings.contains(fresh.verify_body, strings.concatenate({`"previous_bridge_id":"`, a, `"`}, context.temp_allocator)), "the valid hint is shown to the approver")
	testing.expect(t, fresh.bridge_id != "" && fresh.bridge_id != a, "choosing New mints a different bridge_id")
	testing.expect(t, attach_commit(&f.graph, fresh.bridge_id), "the new bridge commits")

	// A is exactly as it was: credentials, vault identity, dependents.
	testing.expect_value(t, reuse_token_bridge(&f.graph, f.first.access_token), a)
	testing.expect_value(t, reuse_token_bridge(&f.graph, fresh.access_token), fresh.bridge_id)
	old_row, old_found := attach_vault_row(&f.graph, f.user_id, f.first.identity_id)
	testing.expect(t, old_found && old_row.retired_at == "" && old_row.bridge_id == a, "A's vault device is not retired")
	new_row, _ := attach_vault_row(&f.graph, f.user_id, fresh.identity_id)
	testing.expect_value(t, new_row.bridge_id, fresh.bridge_id)
	reuse_expect_dependents_on(t, &f.graph, f.user_id, a, "after new enrollment")
	instances_on_new, _ := iface.agent_list_instances_by_bridge(&f.graph.repos.agents, fresh.bridge_id)
	testing.expect_value(t, len(instances_on_new), 0)
	_, path_on_new, _ := iface.project_get_bridge_path(&f.graph.repos.projects, REUSE_PROJECT_ID, fresh.bridge_id)
	testing.expect(t, !path_on_new, "nothing moved to the new bridge")
	bridges, _ := bridge_service.list_bridges(&f.graph.bridges, contracts.Auth_Context{user_id = f.user_id})
	testing.expect_value(t, len(bridges), 2)
	testing.expect(t, reuse_refresh_works(&f.graph, f.first.refresh_token), "A's hbf_ refresh token still works")
}

// reuse_expect_a_intact asserts that the pending attach `pending` onto A left
// nothing behind: A's credential and vault device as before, the attach's dead.
@(private = "file")
reuse_expect_a_intact :: proc(t: ^testing.T, f: ^Reuse_Fixture, pending: Attach_Enrollment, when_: string) {
	a := f.first.bridge_id
	testing.expectf(t, reuse_token_bridge(&f.graph, f.first.access_token) == a, "%s: A's access token still works", when_)
	testing.expectf(t, reuse_token_bridge(&f.graph, pending.access_token) == "", "%s: the attach's access token is dead", when_)
	testing.expectf(t, !reuse_refresh_works(&f.graph, pending.refresh_token), "%s: the attach's refresh token is dead", when_)
	old_row, _ := attach_vault_row(&f.graph, f.user_id, f.first.identity_id)
	testing.expectf(t, old_row.retired_at == "" && old_row.status == .Approved, "%s: A's vault device is not retired", when_)
	new_row, _ := attach_vault_row(&f.graph, f.user_id, pending.identity_id)
	testing.expectf(t, new_row.retired_at != "", "%s: the rolled-back identity is retired", when_)
	_, has_family, _ := bridge_service.pending_enrollment_family(&f.graph.bridges, a)
	testing.expectf(t, !has_family, "%s: nothing is pending on A", when_)
	reuse_expect_dependents_on(t, &f.graph, f.user_id, a, when_)
}

@(test)
test_reenroll_pending_attach_cancel_or_expiry_leaves_old_bridge_intact :: proc(t: ^testing.T) {
	f: Reuse_Fixture
	opened := reuse_fixture_open(t, &f, "alice", "reuse-e2e-rollback")
	defer reuse_fixture_close(&f, f.db_path != "" && f.user_id != "")
	if !opened do return
	a := f.first.bridge_id

	// 1. The owner cancels a pending attach.
	cancelled_attach, c_ok := attach_enroll(&f.graph, f.alice[:], "alice-box", target_bridge_id = a, previous_bridge_id = a)
	testing.expect(t, c_ok && cancelled_attach.bridge_id == a, cancelled_attach.approve_body)
	if !c_ok do return
	cancelled := api_http.router_dispatch(&f.graph.router, api_http.Request{
		method = "POST", path = strings.concatenate({"/api/v1/bridges/", a, "/enrollment/cancel"}, context.temp_allocator),
		request_id = "req_reuse_cancel", remote_addr = "127.0.0.1", headers = f.alice[:],
	})
	testing.expect_value(t, cancelled.status, 200)
	testing.expect(t, strings.contains(cancelled.body, `"row_deleted":false`), cancelled.body)
	reuse_expect_a_intact(t, &f, cancelled_attach, "after cancel")

	// 2. The vault key is never delivered and the reaper expires the attach. The
	// clock jumps only for the sweep: token checks below run on real time.
	expired_attach, e_ok := attach_enroll(&f.graph, f.alice[:], "alice-box", target_bridge_id = a, previous_bridge_id = a)
	testing.expect(t, e_ok && expired_attach.bridge_id == a, expired_attach.approve_body)
	if !e_ok do return
	_, still_pending, _ := bridge_service.pending_enrollment_family(&f.graph.bridges, a)
	testing.expect(t, still_pending, "the second attach is pending")
	real := f.graph.clock
	f.graph.clock = platform.Clock{now = reuse_far_future}
	rolled := app.reaper_sweep_pending_enrollments(&f.graph)
	f.graph.clock = real
	testing.expect_value(t, rolled, 1)
	reuse_expect_a_intact(t, &f, expired_attach, "after expiry")
}
