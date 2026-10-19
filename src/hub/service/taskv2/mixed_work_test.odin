#+private file
package taskv2

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"

// Graph tests seed lifecycle projections directly to isolate the orchestration
// contract. They do not claim coverage of matcher/lease integration (cutover).
graph_fixture :: proc(t: ^testing.T, path := ":memory:") -> (^Fixture, bool) {
	fx := new(Fixture)
	conn, ok, err := sqlite.open(path)
	if !testing.expect(t, ok, err.message) do return fx, false
	fx.conn = conn
	ok, err = sqlite.run_migrations(&fx.conn)
	if !testing.expect(t, ok, err.message) do return fx, false
	fixture_wire(fx)
	chain := seed_chain(t, fx, "mixed_chain", true)
	chain.coordinator_agent_instance_id = "coord_instance"
	_, _, _ = iface.taskchain_save_chain(&fx.repo, chain)
	ids := []string{"ticket_a", "ticket_b", "ticket_c"}
	for id in ids do _ = seed_task(t, fx, chain, id)
	return fx, true
}

graph_ticket :: proc(id: string) -> domain.Work_Item_Ref {
	return domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK, id = id}
}

graph_run :: proc(t: ^testing.T, fx: ^Fixture, id: string) -> domain.Work_Item_Ref {
	u, ok, err := begin_uow(&fx.svc)
	if !testing.expect(t, ok, err.message) do return {}
	now := platform.clock_now(&fx.clock)
	_, rok, rerr := iface.taskchain_insert_workflow_run(&fx.repo, domain.Workflow_Run{
		run_id = domain.Workflow_Run_ID(id), chain_id = "mixed_chain", owner_user_id = "u1",
		title = "Audit", definition_ref = "audit@1", spec_json = `{"name":"audit","stages":[]}`,
		inputs_json = "{}", current_execution_no = 1, request_id = id, request_hash = "hash",
		created_by_kind = "user", created_by_id = "u1", created_at = now, updated_at = now, revision = 1,
	})
	_, eok, eerr := iface.taskchain_insert_workflow_execution(&fx.repo, domain.Workflow_Run_Execution{
		run_id = domain.Workflow_Run_ID(id), execution_no = 1, chain_id = "mixed_chain", owner_user_id = "u1",
		state = domain.WORKFLOW_EXECUTION_PENDING, resolved_inputs_json = "{}", output_manifest_json = "{}", revision = 1,
	})
	_, cerr := end_uow(&fx.svc, &u, rok && eok)
	testing.expect(t, rok && eok && cerr.code == .None, fmt.tprintf("create run: %s / %s / %s", rerr.message, eerr.message, cerr.message))
	return domain.Work_Item_Ref{kind = domain.WORK_ITEM_WORKFLOW_RUN, id = id}
}

graph_set_task_state :: proc(t: ^testing.T, fx: ^Fixture, item: domain.Work_Item_Ref, state: domain.Task_State) {
	task, ok, err := iface.taskchain_get_task(&fx.repo, domain.Task_ID(item.id))
	if !testing.expect(t, ok, err.message) do return
	task.state = state
	if state == .In_Progress || state == .In_Review || state == .Done do task.attempt_no = 1
	_, saved, serr := iface.taskchain_save_task(&fx.repo, task)
	testing.expect(t, saved, serr.message)
	payload := json_begin()
	json_str(&payload, "state", domain.task_state_string(state))
	json_int(&payload, "attempt_no", i64(task.attempt_no))
	json_bool(&payload, "published", true)
	_, recorded, rerr := append_event(&fx.repo, &fx.clock, task, hub_actor(), EV_MIGRATED, json_end(&payload))
	testing.expect(t, recorded, rerr.message)
	if task.attempt_no > 0 {
		_, aok, aerr := iface.taskchain_save_attempt(&fx.repo, domain.Task_Attempt{
			task_id = task.task_id, attempt_no = task.attempt_no, chain_id = task.chain_id,
			owner_user_id = task.owner_user_id, started_at = platform.clock_now(&fx.clock),
		})
		testing.expect(t, aok, aerr.message)
	}
}

graph_run_state :: proc(t: ^testing.T, fx: ^Fixture, item: domain.Work_Item_Ref, state: string) {
	run, _, _ := iface.taskchain_get_workflow_run(&fx.repo, domain.Workflow_Run_ID(item.id), "u1")
	execution, ok, err := iface.taskchain_get_workflow_execution(&fx.repo, run.run_id, run.current_execution_no, "u1")
	if !testing.expect(t, ok, err.message) do return
	execution.state = state
	if state == "running" do execution.started_at = platform.clock_now(&fx.clock)
	if state == "succeeded" {
		execution.output_manifest_json = `{"report":"artifact_a"}`
		execution.ended_at = platform.clock_now(&fx.clock)
	}
	execution.revision += 1
	_, saved, serr := iface.taskchain_update_workflow_execution(&fx.repo, execution)
	testing.expect(t, saved, serr.message)
}

graph_add :: proc(t: ^testing.T, fx: ^Fixture, dependent, prerequisite: domain.Work_Item_Ref) -> domain.Work_Dependency {
	edge, ok, err := graph_dependency_add(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, "mixed_chain", dependent, prerequisite)
	testing.expect(t, ok, err.message)
	return edge
}

graph_capture :: proc(t: ^testing.T, fx: ^Fixture, item: domain.Work_Item_Ref) -> (bool, domain.Domain_Error) {
	u, ok, err := begin_uow(&fx.svc)
	if !testing.expect(t, ok, err.message) do return false, err
	if item.kind == domain.WORK_ITEM_TASK do graph_set_task_state(t, fx, item, .In_Progress)
	else do graph_run_state(t, fx, item, "running")
	captured, cerr := work_capture_inputs_in_uow(&fx.svc, "mixed_chain", "u1", item)
	_, commit_err := end_uow(&fx.svc, &u, captured)
	if !captured do return false, cerr
	return commit_err.code == .None, commit_err
}

graph_sql_rejected :: proc(t: ^testing.T, fx: ^Fixture, sql: string) {
	stmt: sqlite.sqlite3_stmt
	c_sql := strings.clone_to_cstring(sql, context.temp_allocator)
	rc := sqlite.sqlite3_prepare_v2(fx.conn.db, c_sql, -1, &stmt, nil)
	if !testing.expect(t, rc == sqlite.SQLITE_OK, "negative test statement must prepare") do return
	defer sqlite.sqlite3_finalize(stmt)
	testing.expect(t, sqlite.sqlite3_step(stmt) != sqlite.SQLITE_DONE, "contract violation must fail")
}

@(test)
test_mixed_graph_typed_edges_cycles_and_idempotency :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fx, ok := graph_fixture(t)
	defer sqlite.close(&fx.conn)
	if !ok do return
	a, b, c := graph_ticket("ticket_a"), graph_ticket("ticket_b"), graph_ticket("ticket_c")
	r1, r2 := graph_run(t, fx, "run_a"), graph_run(t, fx, "run_b")
	first := graph_add(t, fx, a, b) // ticket -> ticket
	_ = graph_add(t, fx, r1, a) // run -> ticket
	_ = graph_add(t, fx, r2, r1) // run -> run
	_ = graph_add(t, fx, c, r2) // ticket -> run
	duplicate := graph_add(t, fx, a, b)
	testing.expect(t, duplicate.dependency_id == first.dependency_id, "duplicate edge returns same identity")
	_, cycle, cerr := graph_dependency_add(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, "mixed_chain", b, c)
	testing.expect(t, !cycle && cerr.code == .Conflict, "transitive mixed cycle rejected")
	_, self, serr := graph_dependency_add(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, "mixed_chain", a, a)
	testing.expect(t, !self && serr.code == .Validation_Failed, "self edge rejected")
	edges, _ := iface.taskchain_list_work_dependencies(&fx.repo, "mixed_chain", "u1")
	testing.expect(t, len(edges) == 4, "failed inserts roll back without corrupting DAG")
	graph_sql_rejected(t, fx, "INSERT INTO work_dependencies (dependency_id,chain_id,owner_user_id,dependent_kind,dependent_id,prerequisite_kind,prerequisite_id,created_by_kind,created_by_id,created_at) VALUES ('bypass','mixed_chain','u1','task','ticket_b','task','ticket_c','hub','','now');")
}

@(test)
test_mixed_graph_authority_scope_and_managed_task_boundaries :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fx, ok := graph_fixture(t)
	defer sqlite.close(&fx.conn)
	if !ok do return
	a, b := graph_ticket("ticket_a"), graph_ticket("ticket_b")
	_, worker, werr := graph_dependency_add(&fx.svc, "u1", Actor{kind = ACTOR_AGENT, id = "worker"}, "mixed_chain", a, b)
	testing.expect(t, !worker && werr.code == .Forbidden, "worker cannot edit work DAG")
	_, wrong_user, uerr := graph_dependency_add(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u2"}, "mixed_chain", a, b)
	testing.expect(t, !wrong_user && uerr.code == .Forbidden, "user actor must match owner")
	_, wrong_owner, oerr := graph_dependency_add(&fx.svc, "u2", Actor{kind = ACTOR_USER, id = "u2"}, "mixed_chain", a, b)
	testing.expect(t, !wrong_owner && oerr.code == .Not_Found, "chain existence hidden from another owner")
	_, coord, cerr := graph_dependency_add(&fx.svc, "u1", Actor{kind = ACTOR_COORDINATOR, id = "coord_instance"}, "mixed_chain", a, b)
	testing.expect(t, coord && cerr.code == .None, "same coordinator controls mixed graph")
	other := seed_chain(t, fx, "other_chain", true)
	foreign_task := seed_task(t, fx, other, "foreign_ticket")
	_, cross_chain, ferr := graph_dependency_add(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, "mixed_chain", a, graph_ticket(string(foreign_task.task_id)))
	testing.expect(t, !cross_chain && ferr.code == .Not_Found, "same-owner cross-chain endpoint rejected")
    parent := graph_run(t, fx, "managed_parent")
    graph_run_state(t, fx, parent, "running")
    managed, _, _ := iface.taskchain_get_task(&fx.repo, "ticket_c")
    managed.task_id = "managed_stage_task"
    managed.stage_key = "audit"
    managed.workflow_run_id = domain.Workflow_Run_ID(parent.id)
    managed.workflow_execution_no = 1
    _, saved, save_err := iface.taskchain_save_task(&fx.repo, managed)
    testing.expect(t, saved, save_err.message)
    _, generated, gerr := graph_dependency_add(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, "mixed_chain", a, graph_ticket(string(managed.task_id)))
    testing.expect(t, !generated && gerr.code == .Validation_Failed, "stage task cannot be external dependency")
	_, unknown, kerr := graph_dependency_add(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, "mixed_chain", a, domain.Work_Item_Ref{kind = "stage", id = "audit"})
	testing.expect(t, !unknown && kerr.code == .Validation_Failed, "unknown item kind rejected")
	edges, _ := iface.taskchain_list_work_dependencies(&fx.repo, "mixed_chain", "u2")
	testing.expect(t, len(edges) == 0, "edge list is owner scoped")
	chain, _, _ := iface.taskchain_get_chain(&fx.repo, "mixed_chain")
	chain.status = .Archived
	_, _, _ = iface.taskchain_save_chain(&fx.repo, chain)
	_, closed, _ := graph_dependency_add(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, "mixed_chain", b, a)
	testing.expect(t, !closed, "completed chain rejects new work")
}

@(test)
test_mixed_graph_cancelled_and_excluded_prerequisites_do_not_succeed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fx, ok := graph_fixture(t)
	defer sqlite.close(&fx.conn)
	if !ok do return
	a, b := graph_ticket("ticket_a"), graph_ticket("ticket_b")
	run := graph_run(t, fx, "run_a")
	_ = graph_add(t, fx, a, b)
	_ = graph_add(t, fx, a, run)
	graph_set_task_state(t, fx, b, .Cancelled)
	graph_run_state(t, fx, run, "cancelled")
	ready, err := work_dependencies_ready_in_uow(&fx.svc, "mixed_chain", "u1", a)
	testing.expect(t, !ready && err.code == .None, "cancelled prerequisites block dependent")
	_, excluded, eerr := work_scope_decide(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, "mixed_chain", b, "exclude", "out of scope")
	testing.expect(t, excluded && eerr.code == .None, "cancelled ticket may be excluded")
	_, excluded, _ = work_scope_decide(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, "mixed_chain", run, "exclude", "superseded")
	testing.expect(t, excluded, "cancelled run may be excluded")
	ready, err = work_dependencies_ready_in_uow(&fx.svc, "mixed_chain", "u1", a)
	testing.expect(t, !ready && err.code == .None, "exclusion never fabricates dependency success")
	_, active_exclusion, aerr := work_scope_decide(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, "mixed_chain", a, "exclude", "skip")
	testing.expect(t, !active_exclusion && aerr.code == .Conflict, "active work must be cancelled before exclusion")
}

@(test)
test_mixed_graph_run_consumption_blocks_retry_after_edge_removal :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fx, ok := graph_fixture(t)
	defer sqlite.close(&fx.conn)
	if !ok do return
	consumer := graph_ticket("ticket_a")
	provider := graph_run(t, fx, "run_a")
	edge := graph_add(t, fx, consumer, provider)
	graph_run_state(t, fx, provider, "running")
	graph_run_state(t, fx, provider, "succeeded")
	ready, rerr := work_dependencies_ready_in_uow(&fx.svc, "mixed_chain", "u1", consumer)
	testing.expect(t, ready && rerr.code == .None, "successful run releases dependent readiness")
	captured, cerr := graph_capture(t, fx, consumer)
	testing.expect(t, captured && cerr.code == .None, "consumer records source execution")
	u, _, _ := begin_uow(&fx.svc)
	again, aerr := work_capture_inputs_in_uow(&fx.svc, "mixed_chain", "u1", consumer)
	_, _ = end_uow(&fx.svc, &u, again)
	testing.expect(t, again && aerr.code == .None, "capture retry is idempotent")
	receipts, _ := iface.taskchain_list_work_receipts_by_prerequisite(&fx.repo, "mixed_chain", "u1", provider)
	testing.expect(t, len(receipts) == 1, "exactly one durable receipt")
	if len(receipts) == 1 {
		testing.expect(t, receipts[0].prerequisite_generation == 1 && receipts[0].dependent_generation == 1 && receipts[0].output_manifest_json == `{"report":"artifact_a"}`, "receipt freezes exact generations and manifest")
	}
	removed, merr := graph_dependency_remove(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, "mixed_chain", edge.dependency_id, "replacement no longer needed")
	testing.expect(t, removed && merr.code == .None, "edge removal is explicit")
	graph_set_task_state(t, fx, consumer, .Done)
	guard := work_require_unconsumed_in_uow(&fx.svc, "mixed_chain", "u1", provider)
	testing.expect(t, guard.code == .Conflict && strings.contains(guard.details_json, "output_already_consumed") && strings.contains(guard.details_json, consumer.id), "completed consumer remains a retry blocker after edge removal")
	graph_sql_rejected(t, fx, "UPDATE workflow_runs SET current_execution_no = 2, revision = revision + 1 WHERE run_id = 'run_a';")
	graph_sql_rejected(t, fx, "DELETE FROM work_input_receipts WHERE prerequisite_id = 'run_a';")
	graph_sql_rejected(t, fx, "UPDATE work_input_receipts SET prerequisite_generation = 2 WHERE prerequisite_id = 'run_a';")
}

@(test)
test_mixed_graph_ticket_consumption_blocks_reopen_and_output_rewrite :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fx, ok := graph_fixture(t)
	defer sqlite.close(&fx.conn)
	if !ok do return
	provider := graph_ticket("ticket_a")
	consumer := graph_run(t, fx, "run_a")
	_ = graph_add(t, fx, consumer, provider)
	graph_set_task_state(t, fx, provider, .Done)
	facet_ok, _ := iface.taskchain_save_facet(&fx.repo, domain.Task_Attempt_Facet{
		task_id = "ticket_a", attempt_no = 1, chain_id = "mixed_chain", owner_user_id = "u1",
		kind = "output", v = 1, body_json = `{"findings":[]}`, writer = "agent", written_at = platform.clock_now(&fx.clock),
	})
	testing.expect(t, facet_ok, "provider output exists")
	captured, err := graph_capture(t, fx, consumer)
	testing.expect(t, captured && err.code == .None, "run consumes successful ticket attempt")
	guard := work_require_unconsumed_in_uow(&fx.svc, "mixed_chain", "u1", provider)
	testing.expect(t, guard.code == .Conflict, "consumed ticket cannot reopen")
	task, _, _ := iface.taskchain_get_task(&fx.repo, "ticket_a")
	before_events, _ := iface.taskchain_list_events_by_task(&fx.repo, task.task_id, "u1")
	_, reopened, reopen_err := task_reopen(&fx.svc, task, Actor{kind = ACTOR_USER, id = "u1"})
	testing.expect(t, !reopened && reopen_err.code == .Conflict && strings.contains(reopen_err.details_json, "output_already_consumed"), "real reopen API returns actionable consumption guard")
	after_events, _ := iface.taskchain_list_events_by_task(&fx.repo, task.task_id, "u1")
	testing.expect(t, len(before_events) == len(after_events), "rejected reopen adds no audit event")
	graph_sql_rejected(t, fx, "UPDATE tasks SET state = 'backlog', attempt_no = 2 WHERE task_id = 'ticket_a';")
	graph_sql_rejected(t, fx, "UPDATE task_attempt_facets SET body_json = '{}' WHERE task_id = 'ticket_a' AND kind = 'output';")
	graph_sql_rejected(t, fx, "DELETE FROM task_attempt_facets WHERE task_id = 'ticket_a' AND kind = 'output';")
}

@(test)
test_mixed_graph_failed_start_rolls_back_partial_receipts_and_consumer :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fx, ok := graph_fixture(t)
	defer sqlite.close(&fx.conn)
	if !ok do return
	consumer, provider_a, provider_b := graph_ticket("ticket_a"), graph_ticket("ticket_b"), graph_ticket("ticket_c")
	_ = graph_add(t, fx, consumer, provider_a)
	fixture_advance(fx, 2)
	_ = graph_add(t, fx, consumer, provider_b)
	graph_set_task_state(t, fx, provider_a, .Done)
	captured, err := graph_capture(t, fx, consumer)
	testing.expect(t, !captured && err.code == .Conflict, "one unsatisfied input prevents start")
	receipts, _ := iface.taskchain_list_work_receipts_by_dependent(&fx.repo, "mixed_chain", "u1", consumer)
	testing.expect(t, len(receipts) == 0, "receipt written for first input rolls back when next input fails")
	task, _, _ := iface.taskchain_get_task(&fx.repo, "ticket_a")
	testing.expect(t, task.state == .Backlog && task.attempt_no == 0, "consumer start rolls back with receipts")
	attempts, _ := iface.taskchain_list_attempts_by_task(&fx.repo, task.task_id, "u1")
	testing.expect(t, len(attempts) == 0, "no orphaned attempt from rejected start")
}

@(test)
test_mixed_graph_removed_edges_preserve_audit_and_allow_replanning :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fx, ok := graph_fixture(t)
	defer sqlite.close(&fx.conn)
	if !ok do return
	a, b := graph_ticket("ticket_a"), graph_ticket("ticket_b")
	edge := graph_add(t, fx, a, b)
	removed, err := graph_dependency_remove(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, "mixed_chain", edge.dependency_id, "")
	testing.expect(t, !removed && err.code == .Validation_Failed, "removal must explain change")
	removed, err = graph_dependency_remove(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, "mixed_chain", edge.dependency_id, "changed approach")
	testing.expect(t, removed && err.code == .None, "remove active edge")
	removed, _ = graph_dependency_remove(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, "mixed_chain", edge.dependency_id, "duplicate request")
	testing.expect(t, removed, "removal is idempotent")
	readded := graph_add(t, fx, a, b)
	testing.expect(t, readded.dependency_id != edge.dependency_id, "re-added edge has new identity")
	edges, _ := iface.taskchain_list_work_dependencies(&fx.repo, "mixed_chain", "u1")
	testing.expect(t, len(edges) == 2, "both edge lifetimes preserved")
	for e in edges {
		if e.dependency_id == edge.dependency_id {
			testing.expect(t, e.removal_reason == "changed approach" && e.removed_by_id == "u1" && e.removed_at != "", "duplicate removal does not rewrite audit")
		}
	}
	graph_set_task_state(t, fx, a, .In_Progress)
	_, changed, cerr := graph_dependency_add(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, "mixed_chain", a, graph_ticket("ticket_c"))
	testing.expect(t, !changed && cerr.code == .Conflict, "started consumer cannot acquire a new prerequisite")
	graph_sql_rejected(t, fx, "UPDATE work_dependencies SET prerequisite_id = 'ticket_c' WHERE removed_at = '';")
	graph_sql_rejected(t, fx, "DELETE FROM work_dependencies;")
	graph_sql_rejected(t, fx, "UPDATE tasks SET stage_key = 'generated' WHERE task_id = 'ticket_a';")
	graph_sql_rejected(t, fx, "DELETE FROM tasks WHERE task_id = 'ticket_a';")
}

@(test)
test_mixed_graph_scope_decisions_are_ordered_owner_scoped_and_append_only :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fx, ok := graph_fixture(t)
	defer sqlite.close(&fx.conn)
	if !ok do return
	item := graph_ticket("ticket_a")
	graph_set_task_state(t, fx, item, .Cancelled)
	first, saved, err := work_scope_decide(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, "mixed_chain", item, "exclude", "superseded")
	testing.expect(t, saved && err.code == .None, "exclude cancelled work")
	last, last_saved, last_err := work_scope_decide(&fx.svc, "u1", Actor{kind = ACTOR_COORDINATOR, id = "coord_instance"}, "mixed_chain", item, "include", "goal expanded")
	testing.expect(t, last_saved && last_err.code == .None && last.decision_id > first.decision_id, "reinclusion appends a later decision")
	_, unknown, _ := work_scope_decide(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, "mixed_chain", item, "ignore", "why")
	_, empty, _ := work_scope_decide(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, "mixed_chain", item, "include", " ")
	testing.expect(t, !unknown && !empty, "unknown actions and empty reasons rejected")
	decisions, _ := iface.taskchain_list_work_scope_decisions(&fx.repo, "mixed_chain", "u1")
	other, _ := iface.taskchain_list_work_scope_decisions(&fx.repo, "mixed_chain", "u2")
	testing.expect(t, len(decisions) == 2 && len(other) == 0, "ordered scope history is owner scoped")
	graph_sql_rejected(t, fx, "UPDATE work_scope_decisions SET action = 'exclude';")
	graph_sql_rejected(t, fx, "DELETE FROM work_scope_decisions;")
}

// A real published ticket and instance, using production task-created/refold
// paths. The run's lifecycle remains seeded until run-engine extraction.
graph_grant_fixture :: proc(t: ^testing.T) -> (^Fixture, domain.Task_Chain, domain.Task, domain.Agent_Instance, bool) {
	fx, ok := graph_fixture(t)
	if !ok do return fx, {}, {}, {}, false
	chain, _, _ := iface.taskchain_get_chain(&fx.repo, "mixed_chain")
	provider := graph_run(t, fx, "run_a")
	_ = graph_add(t, fx, graph_ticket("ticket_a"), provider)
	task, _, _ := iface.taskchain_get_task(&fx.repo, "ticket_a")
	err := task_created(&fx.svc, task, Actor{kind = ACTOR_USER, id = "u1"})
	if !testing.expect(t, err.code == .None, err.message) do return fx, chain, task, {}, false
	blocked, _, _ := iface.taskchain_get_task(&fx.repo, "ticket_a")
	testing.expect(t, blocked.state == .Backlog, "published ticket waits for pending workflow")
	graph_run_state(t, fx, provider, "running")
	graph_run_state(t, fx, provider, "succeeded")
	u, _, _ := begin_uow(&fx.svc)
	refolded, _, rok, rerr := refold_task(&fx.svc, &u, blocked)
	_, cerr := end_uow(&fx.svc, &u, rok)
	testing.expect(t, rok && rerr.code == .None && cerr.code == .None && refolded.state == .Ready, "successful workflow releases ticket fold")
	seed_bridge(fx, "br_1")
	seed_agent(fx, "agt_w")
	inst := seed_instance(fx, chain, "inst_worker", "agt_w", "br_1", "idle")
	return fx, chain, refolded, inst, true
}

@(test)
test_mixed_graph_real_grant_consumes_inputs_atomically :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fx, chain, task, inst, ok := graph_grant_fixture(t)
	defer sqlite.close(&fx.conn)
	if !ok do return
	u, _, _ := begin_uow(&fx.svc)
	lease, granted, err := grant_in_uow(&fx.svc, &u, Grant_Request{
		chain = chain, task = task, instance = inst, kind = domain.LEASE_KIND_WORK,
		delivery = domain.LEASE_DELIVERY_INLINE, placement = Placement{bridge_id = "br_1"}, actor = hub_actor(),
	})
	_, cerr := end_uow(&fx.svc, &u, granted)
	testing.expect(t, granted && err.code == .None && cerr.code == .None, "real grant succeeds")
	receipts, _ := iface.taskchain_list_work_receipts_by_dependent(&fx.repo, "mixed_chain", "u1", graph_ticket("ticket_a"))
	fresh, _, _ := iface.taskchain_get_task(&fx.repo, task.task_id)
	testing.expect(t, fresh.state == .In_Progress && len(receipts) == 1 && fresh.attempt_no == lease.attempt_no, "lease, projection and consumption commit together")
	if len(receipts) == 1 {
		testing.expect(t, receipts[0].dependent_generation == lease.attempt_no && receipts[0].prerequisite_generation == 1, "receipt identifies leased attempt and source execution")
	}
	before, _ := iface.taskchain_list_workflow_executions(&fx.repo, "run_a", "u1")
	testing.expect(t, len(before) == 1, "provider execution remains unchanged")
}

@(test)
test_mixed_graph_rejected_grant_savepoint_does_not_leak_partial_start :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fx, chain, task, inst, ok := graph_grant_fixture(t)
	defer sqlite.close(&fx.conn)
	if !ok do return
	testing.expect(t, sqlite.exec(&fx.conn, "CREATE TRIGGER injected_receipt_failure BEFORE INSERT ON work_input_receipts BEGIN SELECT RAISE(ABORT, 'injected storage failure'); END;"), "install receipt failure injection")
	u, _, _ := begin_uow(&fx.svc)
	_, granted, err := grant_in_uow(&fx.svc, &u, Grant_Request{
		chain = chain, task = task, instance = inst, kind = domain.LEASE_KIND_WORK,
		delivery = domain.LEASE_DELIVERY_INLINE, placement = Placement{bridge_id = "br_1"}, actor = hub_actor(),
	})
	testing.expect(t, !granted && err.code == .Conflict, "receipt failure rejects whole grant")
	// Matchers skip a failed candidate and COMMIT their other work. Deliberately
	// do that here; safety must not depend on the caller rolling back everything.
	_, cerr := end_uow(&fx.svc, &u, true)
	testing.expect(t, cerr.code == .None, "outer transaction can still commit")
	leases, _ := iface.taskchain_list_leases_by_task(&fx.repo, task.task_id)
	attempts, _ := iface.taskchain_list_attempts_by_task(&fx.repo, task.task_id, "u1")
	receipts, _ := iface.taskchain_list_work_receipts_by_dependent(&fx.repo, "mixed_chain", "u1", graph_ticket("ticket_a"))
	testing.expect(t, len(leases) + len(attempts) + len(receipts) == 0, "skipped grant leaves no durable partial state")
	fresh, _, _ := iface.taskchain_get_task(&fx.repo, task.task_id)
	testing.expect(t, fresh.state == .Ready && fresh.attempt_no == 0, "task remains available")
	events, _ := iface.taskchain_list_events_by_task(&fx.repo, task.task_id, "u1")
	for event in events do testing.expect(t, event.kind != EV_LEASE_GRANTED, "failed grant event rolled back")
	instance, _, _ := iface.agent_get_instance(&fx.agents, inst.agent_instance_id)
	testing.expect(t, instance.current_task_id == "", "failed grant does not assign instance")
}

@(test)
test_mixed_graph_parent_rollback_discards_successful_grant_and_receipts :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fx, chain, task, inst, ok := graph_grant_fixture(t)
	defer sqlite.close(&fx.conn)
	if !ok do return
	u, _, _ := begin_uow(&fx.svc)
	_, granted, err := grant_in_uow(&fx.svc, &u, Grant_Request{
		chain = chain, task = task, instance = inst, kind = domain.LEASE_KIND_WORK,
		delivery = domain.LEASE_DELIVERY_WAKE, placement = Placement{bridge_id = "br_1"}, actor = hub_actor(),
	})
	testing.expect(t, granted && err.code == .None, "grant savepoint releases")
	testing.expect(t, len(u.effects.publishes) > 0 && len(u.effects.runs) > 0, "effects transfer to parent instead of being delivered early")
	_, _ = end_uow(&fx.svc, &u, false)
	leases, _ := iface.taskchain_list_leases_by_task(&fx.repo, task.task_id)
	receipts, _ := iface.taskchain_list_work_receipts_by_dependent(&fx.repo, "mixed_chain", "u1", graph_ticket("ticket_a"))
	fresh, _, _ := iface.taskchain_get_task(&fx.repo, task.task_id)
	testing.expect(t, len(leases) == 0 && len(receipts) == 0 && fresh.state == .Ready && fresh.attempt_no == 0, "parent rollback removes grant and consumption together")
}

@(test)
test_mixed_graph_grant_rechecks_stale_ready_projection :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fx, ok := graph_fixture(t)
	defer sqlite.close(&fx.conn)
	if !ok do return
	chain, _, _ := iface.taskchain_get_chain(&fx.repo, "mixed_chain")
	provider := graph_run(t, fx, "run_a")
	_ = graph_add(t, fx, graph_ticket("ticket_a"), provider)
	task, _, _ := iface.taskchain_get_task(&fx.repo, "ticket_a")
	task.state = .Ready // Deliberately stale; run is still pending.
	_, _, _ = iface.taskchain_save_task(&fx.repo, task)
	seed_bridge(fx, "br_1")
	seed_agent(fx, "agt_w")
	inst := seed_instance(fx, chain, "inst_worker", "agt_w", "br_1", "idle")
	u, _, _ := begin_uow(&fx.svc)
	_, granted, err := grant_in_uow(&fx.svc, &u, Grant_Request{
		chain = chain, task = task, instance = inst, kind = domain.LEASE_KIND_WORK,
		delivery = domain.LEASE_DELIVERY_INLINE, placement = Placement{bridge_id = "br_1"}, actor = hub_actor(),
	})
	_, _ = end_uow(&fx.svc, &u, true)
	testing.expect(t, !granted && err.code == .Conflict && strings.contains(err.details_json, "prerequisite_unsatisfied"), "grant trusts current prerequisites over cached readiness")
	leases, _ := iface.taskchain_list_leases_by_task(&fx.repo, task.task_id)
	testing.expect(t, len(leases) == 0, "unsatisfied run cannot leak a work lease")
}

@(test)
test_mixed_graph_receipt_generation_and_scope_constraints_fail_closed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fx, ok := graph_fixture(t)
	defer sqlite.close(&fx.conn)
	if !ok do return
	consumer, provider := graph_ticket("ticket_a"), graph_run(t, fx, "run_a")
	_ = graph_add(t, fx, consumer, provider)
	graph_set_task_state(t, fx, consumer, .In_Progress)
	receipt := domain.Work_Input_Receipt{
		receipt_id = "receipt_a", chain_id = "mixed_chain", owner_user_id = "u1",
		dependent = consumer, dependent_generation = 1, prerequisite = provider,
		prerequisite_generation = 1, output_manifest_json = "{}", created_at = platform.clock_now(&fx.clock),
	}
	_, pending, _ := iface.taskchain_insert_work_input_receipt(&fx.repo, receipt)
	testing.expect(t, !pending, "pending provider cannot be consumed")
	graph_run_state(t, fx, provider, "running")
	graph_run_state(t, fx, provider, "succeeded")
	for variant in 0..<5 {
		invalid := receipt
		invalid.output_manifest_json = `{"report":"artifact_a"}`
		switch variant {
		case 0: invalid.prerequisite_generation = 2
		case 1: invalid.dependent_generation = 2
		case 2: invalid.owner_user_id = "u2"
		case 3: invalid.output_manifest_json = `{"report":"invented"}`
		case 4: invalid.dependent = graph_ticket("ticket_b") // no edge or attempt
		}
		_, accepted, _ := iface.taskchain_insert_work_input_receipt(&fx.repo, invalid)
		testing.expect(t, !accepted, "invalid scope, generations, manifests and missing edges rejected")
	}
	receipts, _ := iface.taskchain_list_work_receipts_by_dependent(&fx.repo, "mixed_chain", "u1", consumer)
	testing.expect(t, len(receipts) == 0, "failed receipts leave no consumption history")
}

@(test)
test_mixed_graph_history_survives_restart_and_ledger_recovery :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := os.get_env("TEMP", context.temp_allocator)
	if dir == "" do dir = "/tmp"
	path := fmt.tprintf("%s/ham_mixed_graph_%d.db", dir, os.get_pid())
	os.remove(path)
	defer os.remove(path)
	fx, ok := graph_fixture(t, path)
	defer sqlite.close(&fx.conn)
	if !ok do return
	consumer, provider := graph_ticket("ticket_a"), graph_run(t, fx, "run_a")
	edge := graph_add(t, fx, consumer, provider)
	graph_run_state(t, fx, provider, "running")
	graph_run_state(t, fx, provider, "succeeded")
	captured, err := graph_capture(t, fx, consumer)
	testing.expect(t, captured && err.code == .None, "capture input before restart")
	_, _ = graph_dependency_remove(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, "mixed_chain", edge.dependency_id, "finished consuming")
	graph_set_task_state(t, fx, consumer, .Done)
	_, saved, _ := work_scope_decide(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, "mixed_chain", consumer, "exclude", "replaced in final scope")
	testing.expect(t, saved, "persist scope decision")
	sqlite.close(&fx.conn)
	reopened, reopen_ok, reopen_err := sqlite.open(path)
	if !testing.expect(t, reopen_ok, reopen_err.message) do return
	fx.conn = reopened
	testing.expect(t, sqlite.exec(&fx.conn, "DELETE FROM schema_migrations WHERE version IN ('095_workflow_runs.sql','096_mixed_work_graph.sql');"), "simulate interrupted ledger recording")
	migrated, merr := sqlite.run_migrations(&fx.conn)
	testing.expect(t, migrated && merr.code == .None, "recover migration ledger without rebuilding durable history")
	fixture_wire(fx)
	receipts, _ := iface.taskchain_list_work_receipts_by_prerequisite(&fx.repo, "mixed_chain", "u1", provider)
	edges, _ := iface.taskchain_list_work_dependencies(&fx.repo, "mixed_chain", "u1")
	decisions, _ := iface.taskchain_list_work_scope_decisions(&fx.repo, "mixed_chain", "u1")
	testing.expect(t, len(receipts) == 1 && len(edges) == 1 && len(decisions) == 1, "all provenance survives reopen")
	if len(edges) == 1 do testing.expect(t, edges[0].removed_at != "" && edges[0].removal_reason == "finished consuming", "removed edge history survives")
	guard := work_require_unconsumed_in_uow(&fx.svc, "mixed_chain", "u1", provider)
	testing.expect(t, guard.code == .Conflict, "restart does not erase consumed-output guard")
}

// These repository/graph tests deliberately do not run the workflow engine on
// their synthetic run snapshots. Engine integration lives in m3b_test.odin.
graph_dependency_add :: proc(svc: ^Service, owner: domain.User_ID, actor: Actor, chain_id: domain.Task_Chain_ID, dependent, prerequisite: domain.Work_Item_Ref) -> (domain.Work_Dependency, bool, domain.Domain_Error) {
 return work_dependency_add(svc, owner, actor, chain_id, dependent, prerequisite, reconcile = false)
}
graph_dependency_remove :: proc(svc: ^Service, owner: domain.User_ID, actor: Actor, chain_id: domain.Task_Chain_ID, id, reason: string) -> (bool, domain.Domain_Error) {
 return work_dependency_remove(svc, owner, actor, chain_id, id, reason, reconcile = false)
}
