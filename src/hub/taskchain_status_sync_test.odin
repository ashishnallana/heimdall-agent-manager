package main

import "core:fmt"
import "core:os"
import "core:testing"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import repo_sqlite "odin_test:hub/repository/sqlite"
import taskchain_service "odin_test:hub/service/taskchain"
import hub_http "odin_test:hub/transport/http"

@(private = "file")
open_sync_test_graph :: proc(t: ^testing.T, graph: ^app.App_Graph, tag: string) -> string {
	db_path := fmt.tprintf("/tmp/heimdall-hub-test-sync-%s-%d.db", tag, os.get_pid())
	_ = os.remove(db_path)
	cidrs := [?]string{"127.0.0.1/32"}
	ok, msg := app.build_graph(graph, app.Hub_Config{
		database_path        = db_path,
		migrations_dir       = "src/hub/repository/sqlite/migrations",
		username_header      = "X-authentik-username",
		display_name_header  = "X-authentik-name",
		email_header         = "X-authentik-email",
		trusted_proxy_cidrs  = cidrs[:],
		auto_provision_users = true,
		logout_url           = "/_dev/logout",
		paddle_environment   = "sandbox",
	})
	testing.expect(t, ok, msg)
	return db_path
}

@(private = "file")
create_sync_test_chain :: proc(graph: ^app.App_Graph, owner: string, chain_id: domain.Task_Chain_ID, initial_status: domain.Task_Chain_Status) -> domain.Task_Chain {
	now := "2026-09-26T00:00:00Z"
	completed_at := now if initial_status == .Completed else ""
	chain := domain.Task_Chain{
		chain_id                   = chain_id,
		owner_user_id              = domain.User_ID(owner),
		title                      = "sync test chain",
		publish_state              = .Published,
		status                     = initial_status,
		default_reviewer_refs_json = "[]",
		created_at                 = now,
		updated_at                 = now,
		published_at               = now,
		completed_at               = completed_at,
	}
	saved, _, _ := iface.taskchain_save_chain(graph.taskchains.repo, chain)
	return saved
}

@(private = "file")
create_sync_test_task :: proc(graph: ^app.App_Graph, owner: string, chain_id: domain.Task_Chain_ID, task_id: domain.Task_ID, status: domain.Task_Status, reviewer_json: string = "[]") -> domain.Task {
	now := "2026-09-26T00:00:00Z"
	completed_at := now if status == .Completed || status == .Cancelled else ""
	assignee := fmt.tprintf(`{{"type":"user_id","user_id":"%s"}}`, owner)
	task := domain.Task{
		task_id            = task_id,
		chain_id           = chain_id,
		owner_user_id      = domain.User_ID(owner),
		title              = string(task_id),
		publish_state      = .Published,
		status             = status,
		priority           = .P2,
		assignee_ref_json  = assignee,
		reviewer_refs_json = reviewer_json,
		created_at         = now,
		updated_at         = now,
		published_at       = now,
		completed_at       = completed_at,
	}
	saved, _, _ := iface.taskchain_save_task(graph.taskchains.repo, task)
	return saved
}

// 1. Creating a task in a completed chain reactivates the chain to .Active
@(test)
test_chain_status_sync_create_task_reactivates_completed_chain :: proc(t: ^testing.T) {
	graph: app.App_Graph
	db_path := open_sync_test_graph(t, &graph, "create_reactivates")
	defer { app.shutdown_graph(&graph); _ = os.remove(db_path) }

	owner := "alice"
	chain_id := domain.Task_Chain_ID("chain_sync_1")
	chain := create_sync_test_chain(&graph, owner, chain_id, .Completed)
	testing.expect_value(t, chain.status, domain.Task_Chain_Status.Completed)

	auth := contracts.Auth_Context{kind = .User_Token, user_id = owner}
	_, created, _ := taskchain_service.create_task(&graph.taskchains, auth, taskchain_service.Create_Task_Input{
		chain_id = chain_id,
		title = "New Reactivating Task",
		owner_user_id = owner,
	})
	testing.expect(t, created, "create_task should succeed")

	updated_chain, got, _ := iface.taskchain_get_chain(graph.taskchains.repo, chain_id)
	testing.expect(t, got, "chain should exist")
	testing.expect_value(t, updated_chain.status, domain.Task_Chain_Status.Active)
	testing.expect_value(t, updated_chain.completed_at, "")
}

// 2. Completing the final remaining open task in an active chain automatically sets the chain to .Completed
@(test)
test_chain_status_sync_complete_final_task_completes_chain :: proc(t: ^testing.T) {
	graph: app.App_Graph
	db_path := open_sync_test_graph(t, &graph, "complete_final")
	defer { app.shutdown_graph(&graph); _ = os.remove(db_path) }

	owner := "alice"
	chain_id := domain.Task_Chain_ID("chain_sync_2")
	_ = create_sync_test_chain(&graph, owner, chain_id, .Active)

	t1 := create_sync_test_task(&graph, owner, chain_id, "task_sync_2_1", .In_Validation)
	t2 := create_sync_test_task(&graph, owner, chain_id, "task_sync_2_2", .In_Validation)

	auth := contracts.Auth_Context{kind = .User_Token, user_id = owner}

	// Complete first task
	_, ok1, _ := taskchain_service.change_task_status(&graph.taskchains, auth, t1.task_id, .Completed)
	testing.expect(t, ok1, "completing t1 should succeed")

	// Chain should still be Active (t2 is still In_Validation)
	c1, _, _ := iface.taskchain_get_chain(graph.taskchains.repo, chain_id)
	testing.expect_value(t, c1.status, domain.Task_Chain_Status.Active)

	// Complete second (and final) task
	_, ok2, _ := taskchain_service.change_task_status(&graph.taskchains, auth, t2.task_id, .Completed)
	testing.expect(t, ok2, "completing t2 should succeed")

	// Chain should now automatically transition to Completed
	c2, _, _ := iface.taskchain_get_chain(graph.taskchains.repo, chain_id)
	testing.expect_value(t, c2.status, domain.Task_Chain_Status.Completed)
	testing.expect(t, c2.completed_at != "", "completed_at must be populated on chain")
}

// 3. Cancelling all remaining open tasks in an active chain with >=1 completed task automatically sets the chain to .Completed
@(test)
test_chain_status_sync_cancel_remaining_tasks_completes_chain :: proc(t: ^testing.T) {
	graph: app.App_Graph
	db_path := open_sync_test_graph(t, &graph, "cancel_remaining")
	defer { app.shutdown_graph(&graph); _ = os.remove(db_path) }

	owner := "alice"
	chain_id := domain.Task_Chain_ID("chain_sync_3")
	_ = create_sync_test_chain(&graph, owner, chain_id, .Active)

	t1 := create_sync_test_task(&graph, owner, chain_id, "task_sync_3_1", .Completed)
	t2 := create_sync_test_task(&graph, owner, chain_id, "task_sync_3_2", .Assigned)

	auth := contracts.Auth_Context{kind = .User_Token, user_id = owner}

	// Cancel the remaining open task
	_, ok, _ := taskchain_service.change_task_status(&graph.taskchains, auth, t2.task_id, .Cancelled)
	testing.expect(t, ok, "cancelling t2 should succeed")

	// Chain should automatically transition to Completed because non_terminal == 0 and completed == 1
	c, _, _ := iface.taskchain_get_chain(graph.taskchains.repo, chain_id)
	testing.expect_value(t, c.status, domain.Task_Chain_Status.Completed)
	testing.expect(t, c.completed_at != "", "completed_at must be populated on chain")
}

// 4. Un-cancelling a task in a completed chain automatically sets the chain back to .Active
@(test)
test_chain_status_sync_uncancel_task_reactivates_completed_chain :: proc(t: ^testing.T) {
	graph: app.App_Graph
	db_path := open_sync_test_graph(t, &graph, "uncancel_reactivates")
	defer { app.shutdown_graph(&graph); _ = os.remove(db_path) }

	owner := "alice"
	chain_id := domain.Task_Chain_ID("chain_sync_4")
	_ = create_sync_test_chain(&graph, owner, chain_id, .Completed)

	_ = create_sync_test_task(&graph, owner, chain_id, "task_sync_4_1", .Completed)
	t2 := create_sync_test_task(&graph, owner, chain_id, "task_sync_4_2", .Cancelled)

	auth := contracts.Auth_Context{kind = .User_Token, user_id = owner}

	// Un-cancel task2: .Cancelled -> .Assigned
	_, ok, _ := taskchain_service.change_task_status(&graph.taskchains, auth, t2.task_id, .Assigned)
	testing.expect(t, ok, "un-cancelling t2 should succeed")

	// Chain should automatically reactivate to Active
	c, _, _ := iface.taskchain_get_chain(graph.taskchains.repo, chain_id)
	testing.expect_value(t, c.status, domain.Task_Chain_Status.Active)
	testing.expect_value(t, c.completed_at, "")
}

// 5. Quorum resolution triggers chain status sync to .Completed
@(test)
test_chain_status_sync_quorum_approval_completes_chain :: proc(t: ^testing.T) {
	graph: app.App_Graph
	db_path := open_sync_test_graph(t, &graph, "quorum_sync")
	defer { app.shutdown_graph(&graph); _ = os.remove(db_path) }

	owner := "alice"
	chain_id := domain.Task_Chain_ID("chain_sync_5")
	_ = create_sync_test_chain(&graph, owner, chain_id, .Active)

	// Reviewer agent instance
	reviewer_inst_id := "inst_reviewer_5"
	inst := domain.Agent_Instance{
		agent_instance_id = reviewer_inst_id,
		agent_id          = "agt_reviewer_5",
		owner_user_id     = domain.User_ID(owner),
		runtime_status    = "running",
		activity_status   = "idle",
		created_at        = "2026-09-26T00:00:00Z",
		updated_at        = "2026-09-26T00:00:00Z",
	}
	_, _, _ = iface.agent_save_instance(graph.taskchains.agents, inst)

	// Add reviewer as chain member
	member := domain.Task_Chain_Member{
		chain_id          = chain_id,
		agent_instance_id = reviewer_inst_id,
		owner_user_id     = domain.User_ID(owner),
		role              = "reviewer",
		created_at        = "2026-09-26T00:00:00Z",
	}
	_, _, _ = iface.taskchain_save_member(graph.taskchains.repo, member)

	reviewer_ref := fmt.tprintf(`[{{"type":"agent_instance","agent_instance_id":"%s"}}]`, reviewer_inst_id)
	t1 := create_sync_test_task(&graph, owner, chain_id, "task_sync_5_1", .In_Validation, reviewer_ref)

	// Cast LGTM review vote as reviewer instance
	auth := contracts.Auth_Context{kind = .Instance_Token, agent_instance_id = reviewer_inst_id, user_id = owner}
	_, recorded, _ := taskchain_service.record_task_vote(&graph.taskchains, auth, taskchain_service.Vote_Input{
		task_id = t1.task_id,
		vote = "lgtm",
		comment = "verified LGTM",
	})
	testing.expect(t, recorded, "record_task_vote should succeed")

	// Task enters Finishing state via quorum approval
	task_db, _, _ := iface.taskchain_get_task(graph.taskchains.repo, t1.task_id)
	testing.expect_value(t, task_db.status, domain.Task_Status.Finishing)

	// Worker wraps up and marks task Completed
	auth_owner := contracts.Auth_Context{kind = .User_Token, user_id = owner}
	_, comp_ok, _ := taskchain_service.change_task_status(&graph.taskchains, auth_owner, t1.task_id, .Completed)
	testing.expect(t, comp_ok, "change_task_status to completed should succeed")

	// Chain should now automatically transition to Completed
	c, _, _ := iface.taskchain_get_chain(graph.taskchains.repo, chain_id)
	testing.expect_value(t, c.status, domain.Task_Chain_Status.Completed)
	testing.expect(t, c.completed_at != "", "completed_at must be populated on chain")
}

// 6. WebSocket resource_changed for task_chain is published when chain status updates
@(test)
test_chain_status_sync_publishes_websocket_resource_changed :: proc(t: ^testing.T) {
	graph: app.App_Graph
	db_path := open_sync_test_graph(t, &graph, "ws_sync")
	defer { app.shutdown_graph(&graph); _ = os.remove(db_path) }

	owner := "alice"
	chain_id := domain.Task_Chain_ID("chain_sync_6")
	_ = create_sync_test_chain(&graph, owner, chain_id, .Active)
	t1 := create_sync_test_task(&graph, owner, chain_id, "task_sync_6_1", .In_Validation)

	seq_before := graph.event_bus.event_seq

	auth := contracts.Auth_Context{kind = .User_Token, user_id = owner}
	_, ok, _ := taskchain_service.change_task_status(&graph.taskchains, auth, t1.task_id, .Completed)
	testing.expect(t, ok, "completing task should succeed")

	testing.expect(t, graph.event_bus.event_seq > seq_before, "event bus seq must increment on chain status change")
}

// --- Task Status Persistence & Reconcile Demotion (REQ-HUB-STATUS-1) ---

@(private = "file")
status_fixture :: struct {
	graph:       ^app.App_Graph,
	owner:       string,
	instance_id: string,
	chain_id:    domain.Task_Chain_ID,
	review_task: domain.Task_ID,
	work_task:   domain.Task_ID,
}

@(private = "file")
build_status_fixture :: proc(graph: ^app.App_Graph, owner: string, tag: string) -> status_fixture {
	now := "2026-09-22T00:00:00Z"
	instance_id := fmt.tprintf("inst_%s", tag)

	inst := domain.Agent_Instance{
		agent_instance_id = instance_id,
		agent_id          = fmt.tprintf("agt_%s", tag),
		owner_user_id     = domain.User_ID(owner),
		runtime_status    = "running",
		activity_status   = "idle",
		created_at        = now,
		updated_at        = now,
	}
	_, _, _ = iface.agent_save_instance(graph.taskchains.agents, inst)

	chain_id := domain.Task_Chain_ID(fmt.tprintf("chain_%s", tag))
	chain := domain.Task_Chain{
		chain_id                   = chain_id,
		owner_user_id              = domain.User_ID(owner),
		title                      = "status fixture",
		publish_state              = .Published,
		status                     = .Active,
		default_reviewer_refs_json = "[]",
		created_at                 = now,
		updated_at                 = now,
		published_at               = now,
	}
	_, _, _ = iface.taskchain_save_chain(graph.taskchains.repo, chain)

	assignee := fmt.tprintf(`{{"type":"agent_instance","agent_instance_id":"%s"}}`, instance_id)

	review_id := domain.Task_ID(fmt.tprintf("task_%s_review", tag))
	review := domain.Task{
		task_id            = review_id,
		chain_id           = chain_id,
		owner_user_id      = domain.User_ID(owner),
		title              = "awaiting review",
		publish_state      = .Published,
		status             = .In_Validation,
		priority           = .P1,
		assignee_ref_json  = assignee,
		reviewer_refs_json = "[]",
		created_at         = now,
		updated_at         = now,
		published_at       = now,
	}
	_, _, _ = iface.taskchain_save_task(graph.taskchains.repo, review)

	work_id := domain.Task_ID(fmt.tprintf("task_%s_work", tag))
	work := domain.Task{
		task_id            = work_id,
		chain_id           = chain_id,
		owner_user_id      = domain.User_ID(owner),
		title              = "next work",
		publish_state      = .Published,
		status             = .Assigned,
		priority           = .P2,
		assignee_ref_json  = assignee,
		reviewer_refs_json = "[]",
		created_at         = now,
		updated_at         = now,
		published_at       = now,
	}
	_, _, _ = iface.taskchain_save_task(graph.taskchains.repo, work)

	return status_fixture{graph, owner, instance_id, chain_id, review_id, work_id}
}

@(test)
test_change_task_status_reports_the_persisted_status :: proc(t: ^testing.T) {
	graph: app.App_Graph
	db_path := open_sync_test_graph(t, &graph, "reported")
	defer { app.shutdown_graph(&graph); _ = os.remove(db_path) }

	f := build_status_fixture(&graph, "alice", "reported")
	auth := contracts.Auth_Context{kind = .User_Token, user_id = f.owner}

	reported, changed, _ := taskchain_service.change_task_status(&graph.taskchains, auth, f.work_task, .In_Progress)
	testing.expect(t, changed, "change_task_status should succeed")

	persisted, got, _ := iface.taskchain_get_task(graph.taskchains.repo, f.work_task)
	testing.expect(t, got, "task should still exist after the status change")

	testing.expectf(t, reported.status == persisted.status,
		"API REPORTED %v but the row PERSISTED %v - the response is describing a state the database does not hold",
		reported.status, persisted.status)
}

@(test)
test_reconcile_demotes_in_progress_while_instance_awaits_review_by_design :: proc(t: ^testing.T) {
	graph: app.App_Graph
	db_path := open_sync_test_graph(t, &graph, "demote")
	defer { app.shutdown_graph(&graph); _ = os.remove(db_path) }

	f := build_status_fixture(&graph, "alice", "demote")
	auth := contracts.Auth_Context{kind = .User_Token, user_id = f.owner}

	_, changed, _ := taskchain_service.change_task_status(&graph.taskchains, auth, f.work_task, .In_Progress)
	testing.expect(t, changed, "change_task_status should succeed")

	persisted, got, _ := iface.taskchain_get_task(graph.taskchains.repo, f.work_task)
	testing.expect(t, got, "task should still exist")
	testing.expectf(t, persisted.status == .Queued,
		"expected the promotion engine to demote to Queued while the instance awaits review, got %v",
		persisted.status)
}

// --- Archived Chain Transitions and Status Mappings ---

@(test)
test_task_chain_archived_transitions_and_status_mappings :: proc(t: ^testing.T) {
	testing.expect(t, taskchain_service.valid_chain_transition(.Active, .Archived), "Active -> Archived must be valid")
	testing.expect(t, taskchain_service.valid_chain_transition(.Active, .Completed), "Active -> Completed must be valid")
	testing.expect(t, taskchain_service.valid_chain_transition(.Active, .Cancelled), "Active -> Cancelled must be valid")
	testing.expect(t, taskchain_service.valid_chain_transition(.Active, .Active), "Active -> Active must be valid")

	testing.expect(t, taskchain_service.valid_chain_transition(.Completed, .Archived), "Completed -> Archived must be valid")
	testing.expect(t, taskchain_service.valid_chain_transition(.Completed, .Active), "Completed -> Active must be valid")
	testing.expect(t, taskchain_service.valid_chain_transition(.Completed, .Completed), "Completed -> Completed must be valid")
	testing.expect(t, !taskchain_service.valid_chain_transition(.Completed, .Cancelled), "Completed -> Cancelled must be invalid")

	testing.expect(t, taskchain_service.valid_chain_transition(.Cancelled, .Archived), "Cancelled -> Archived must be valid")
	testing.expect(t, taskchain_service.valid_chain_transition(.Cancelled, .Cancelled), "Cancelled -> Cancelled must be valid")
	testing.expect(t, !taskchain_service.valid_chain_transition(.Cancelled, .Active), "Cancelled -> Active must stay invalid")
	testing.expect(t, !taskchain_service.valid_chain_transition(.Cancelled, .Completed), "Cancelled -> Completed must be invalid")

	testing.expect(t, taskchain_service.valid_chain_transition(.Archived, .Active), "Archived -> Active (restore) must be valid")
	testing.expect(t, taskchain_service.valid_chain_transition(.Archived, .Archived), "Archived -> Archived must be valid")
	testing.expect(t, !taskchain_service.valid_chain_transition(.Archived, .Completed), "Archived -> Completed must be invalid")
	testing.expect(t, !taskchain_service.valid_chain_transition(.Archived, .Cancelled), "Archived -> Cancelled must be invalid")

	testing.expect_value(t, taskchain_service.chain_status_from_string("archived"), domain.Task_Chain_Status.Archived)
	testing.expect_value(t, repo_sqlite.chain_status_string(.Archived), "archived")
	testing.expect_value(t, repo_sqlite.chain_status_from_string("archived"), domain.Task_Chain_Status.Archived)
	testing.expect_value(t, hub_http.chain_status_http(.Archived), "archived")
}
