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
		chain_id      = chain_id,
		owner_user_id = domain.User_ID(owner),
		title         = "sync test chain",
		publish_state = .Published,
		status        = initial_status,
		kind          = domain.CHAIN_KIND_MIXED_WORK,
		defaults_json = "{}",
		created_at    = now,
		updated_at    = now,
		published_at  = now,
		completed_at  = completed_at,
	}
	saved, _, _ := iface.taskchain_save_chain(graph.taskchains.repo, chain)
	return saved
}

// Task System v2: the task row's `state` is a cached fold projection; these
// tests seed rows directly with the state they want and exercise the chain
// explicit acceptance boundary (sync never changes chain status).
@(private = "file")
create_sync_test_task :: proc(graph: ^app.App_Graph, owner: string, chain_id: domain.Task_Chain_ID, task_id: domain.Task_ID, state: domain.Task_State) -> domain.Task {
	now := "2026-09-26T00:00:00Z"
	completed_at := now if domain.task_state_is_terminal(state) else ""
	task := domain.Task{
		task_id       = task_id,
		chain_id      = chain_id,
		owner_user_id = domain.User_ID(owner),
		title         = string(task_id),
		publish_state = .Published,
		state         = state,
		kind          = .Task,
		priority      = .P2,
		brief_json    = `{"goal":"sync test"}`,
		created_at    = now,
		updated_at    = now,
		published_at  = now,
		completed_at  = completed_at,
	}
	saved, _, _ := iface.taskchain_save_task(graph.taskchains.repo, task)
	return saved
}

@(private = "file")
set_sync_test_task_state :: proc(graph: ^app.App_Graph, task_id: domain.Task_ID, state: domain.Task_State) {
	task, ok, _ := iface.taskchain_get_task(graph.taskchains.repo, task_id)
	if !ok do return
	task.state = state
	task.completed_at = "2026-09-26T00:01:00Z" if domain.task_state_is_terminal(state) else ""
	_, _, _ = iface.taskchain_save_task(graph.taskchains.repo, task)
}

// REQ-MW-6: completed chains require explicit reopen before adding work.
@(test)
test_chain_status_sync_create_task_requires_explicit_reopen :: proc(t: ^testing.T) {
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
		// a task created on a LIVE chain is published at once → needs a full brief (M2)
		brief_json = `{"goal":"reactivate","acceptance":["chain active again"],"verify":"true","review_roles":[]}`,
	})
	testing.expect(t, !created, "completed chain rejects new work until reopened")

	updated_chain, got, _ := iface.taskchain_get_chain(graph.taskchains.repo, chain_id)
	testing.expect(t, got, "chain should exist")
	testing.expect_value(t, updated_chain.status, domain.Task_Chain_Status.Completed)
	testing.expect(t, updated_chain.completed_at != "", "acceptance date preserved")
}

// 2. The final remaining open task reaching `done` sets the chain to .Completed
@(test)
test_chain_status_sync_complete_final_task_keeps_chain_open :: proc(t: ^testing.T) {
	graph: app.App_Graph
	db_path := open_sync_test_graph(t, &graph, "complete_final")
	defer { app.shutdown_graph(&graph); _ = os.remove(db_path) }

	owner := "alice"
	chain_id := domain.Task_Chain_ID("chain_sync_2")
	_ = create_sync_test_chain(&graph, owner, chain_id, .Active)

	t1 := create_sync_test_task(&graph, owner, chain_id, "task_sync_2_1", .In_Review)
	t2 := create_sync_test_task(&graph, owner, chain_id, "task_sync_2_2", .In_Review)

	// First task done → chain still Active (t2 is still in_review)
	set_sync_test_task_state(&graph, t1.task_id, .Done)
	_, ok1, _ := taskchain_service.sync_chain_status_from_tasks(&graph.taskchains, chain_id, domain.User_ID(owner))
	testing.expect(t, ok1, "sync after t1 done should succeed")
	c1, _, _ := iface.taskchain_get_chain(graph.taskchains.repo, chain_id)
	testing.expect_value(t, c1.status, domain.Task_Chain_Status.Active)

	// Second (and final) task done → chain Completed
	set_sync_test_task_state(&graph, t2.task_id, .Done)
	_, ok2, _ := taskchain_service.sync_chain_status_from_tasks(&graph.taskchains, chain_id, domain.User_ID(owner))
	testing.expect(t, ok2, "sync after t2 done should succeed")
	c2, _, _ := iface.taskchain_get_chain(graph.taskchains.repo, chain_id)
	testing.expect_value(t, c2.status, domain.Task_Chain_Status.Active)
	testing.expect_value(t, c2.completed_at, "")
}

// 3. Cancelling all remaining open tasks in an active chain with >=1 done task sets the chain to .Completed
@(test)
test_chain_status_sync_cancel_remaining_tasks_keeps_chain_open :: proc(t: ^testing.T) {
	graph: app.App_Graph
	db_path := open_sync_test_graph(t, &graph, "cancel_remaining")
	defer { app.shutdown_graph(&graph); _ = os.remove(db_path) }

	owner := "alice"
	chain_id := domain.Task_Chain_ID("chain_sync_3")
	_ = create_sync_test_chain(&graph, owner, chain_id, .Active)

	_ = create_sync_test_task(&graph, owner, chain_id, "task_sync_3_1", .Done)
	t2 := create_sync_test_task(&graph, owner, chain_id, "task_sync_3_2", .Ready)

	// Still open → still Active
	_, _, _ = taskchain_service.sync_chain_status_from_tasks(&graph.taskchains, chain_id, domain.User_ID(owner))
	c0, _, _ := iface.taskchain_get_chain(graph.taskchains.repo, chain_id)
	testing.expect_value(t, c0.status, domain.Task_Chain_Status.Active)

	// Cancel the remaining open task
	set_sync_test_task_state(&graph, t2.task_id, .Cancelled)
	_, ok, _ := taskchain_service.sync_chain_status_from_tasks(&graph.taskchains, chain_id, domain.User_ID(owner))
	testing.expect(t, ok, "sync after cancel should succeed")

	// non_terminal == 0 and completed == 1 → Completed
	c, _, _ := iface.taskchain_get_chain(graph.taskchains.repo, chain_id)
	testing.expect_value(t, c.status, domain.Task_Chain_Status.Active)
	testing.expect_value(t, c.completed_at, "")
}

// 3b. All tasks cancelled and none done → chain stays Active (nothing was accomplished)
@(test)
test_chain_status_sync_all_cancelled_without_done_keeps_active :: proc(t: ^testing.T) {
	graph: app.App_Graph
	db_path := open_sync_test_graph(t, &graph, "all_cancelled")
	defer { app.shutdown_graph(&graph); _ = os.remove(db_path) }

	owner := "alice"
	chain_id := domain.Task_Chain_ID("chain_sync_3b")
	_ = create_sync_test_chain(&graph, owner, chain_id, .Active)
	_ = create_sync_test_task(&graph, owner, chain_id, "task_sync_3b_1", .Cancelled)

	_, ok, _ := taskchain_service.sync_chain_status_from_tasks(&graph.taskchains, chain_id, domain.User_ID(owner))
	testing.expect(t, ok, "sync should succeed")
	c, _, _ := iface.taskchain_get_chain(graph.taskchains.repo, chain_id)
	testing.expect_value(t, c.status, domain.Task_Chain_Status.Active)
}

// 4. A non-terminal task on a completed chain sets the chain back to .Active
@(test)
test_chain_status_sync_projection_does_not_revoke_final_acceptance :: proc(t: ^testing.T) {
	graph: app.App_Graph
	db_path := open_sync_test_graph(t, &graph, "uncancel_reactivates")
	defer { app.shutdown_graph(&graph); _ = os.remove(db_path) }

	owner := "alice"
	chain_id := domain.Task_Chain_ID("chain_sync_4")
	_ = create_sync_test_chain(&graph, owner, chain_id, .Completed)

	_ = create_sync_test_task(&graph, owner, chain_id, "task_sync_4_1", .Done)
	t2 := create_sync_test_task(&graph, owner, chain_id, "task_sync_4_2", .Cancelled)

	// Both terminal → Completed chain stays Completed
	_, _, _ = taskchain_service.sync_chain_status_from_tasks(&graph.taskchains, chain_id, domain.User_ID(owner))
	c0, _, _ := iface.taskchain_get_chain(graph.taskchains.repo, chain_id)
	testing.expect_value(t, c0.status, domain.Task_Chain_Status.Completed)

	// Un-cancel task2: cancelled → ready
	set_sync_test_task_state(&graph, t2.task_id, .Ready)
	_, ok, _ := taskchain_service.sync_chain_status_from_tasks(&graph.taskchains, chain_id, domain.User_ID(owner))
	testing.expect(t, ok, "sync after un-cancel should succeed")

	c, _, _ := iface.taskchain_get_chain(graph.taskchains.repo, chain_id)
	testing.expect_value(t, c.status, domain.Task_Chain_Status.Completed)
	testing.expect(t, c.completed_at != "", "acceptance is explicit and preserved")
}

// 5. Every non-terminal state (backlog/ready/in_progress/in_review) keeps a chain open
@(test)
test_chain_status_sync_every_non_terminal_state_keeps_chain_active :: proc(t: ^testing.T) {
	graph: app.App_Graph
	db_path := open_sync_test_graph(t, &graph, "non_terminal_states")
	defer { app.shutdown_graph(&graph); _ = os.remove(db_path) }

	owner := "alice"
	states := [?]domain.Task_State{.Backlog, .Ready, .In_Progress, .In_Review}
	for state, i in states {
		chain_id := domain.Task_Chain_ID(fmt.tprintf("chain_sync_5_%d", i))
		_ = create_sync_test_chain(&graph, owner, chain_id, .Active)
		_ = create_sync_test_task(&graph, owner, chain_id, domain.Task_ID(fmt.tprintf("task_sync_5_%d_done", i)), .Done)
		_ = create_sync_test_task(&graph, owner, chain_id, domain.Task_ID(fmt.tprintf("task_sync_5_%d_open", i)), state)
		_, ok, _ := taskchain_service.sync_chain_status_from_tasks(&graph.taskchains, chain_id, domain.User_ID(owner))
		testing.expect(t, ok, "sync should succeed")
		c, _, _ := iface.taskchain_get_chain(graph.taskchains.repo, chain_id)
		testing.expectf(t, c.status == .Active, "state %v must keep the chain Active, got %v", state, c.status)
	}
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
	t1 := create_sync_test_task(&graph, owner, chain_id, "task_sync_6_1", .In_Review)

	seq_before := graph.event_bus.event_seq

	set_sync_test_task_state(&graph, t1.task_id, .Done)
	_, ok, _ := taskchain_service.sync_chain_status_from_tasks(&graph.taskchains, chain_id, domain.User_ID(owner))
	testing.expect(t, ok, "sync should succeed")

    testing.expect_value(t, graph.event_bus.event_seq, seq_before)
    current, _, _ := iface.taskchain_get_chain(graph.taskchains.repo, chain_id)
    accepted, complete, err := taskchain_service.complete_chain(&graph.taskchains, contracts.Auth_Context{kind = .User_Token, user_id = owner}, chain_id, current.work_revision, "All included work accepted")
    testing.expect(t, complete, err.message)
    testing.expect_value(t, accepted.status, domain.Task_Chain_Status.Completed)
    testing.expect(t, graph.event_bus.event_seq > seq_before, "explicit acceptance publishes a chain update")
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
