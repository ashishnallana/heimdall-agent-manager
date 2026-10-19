#+private file
package sqlite

import "core:fmt"
import "core:os"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// REQ-MW-1/3/9: exercise the actual repository and registered migrations.
mixed_work_db :: proc(t: ^testing.T, path := ":memory:") -> (Conn, bool) {
	conn, ok, err := open(path)
	if !testing.expect(t, ok, err.message) do return conn, false
	ok, err = run_migrations(&conn)
	if !testing.expect(t, ok, err.message) do return conn, false
	ok = exec(&conn, "INSERT INTO task_chains (chain_id, owner_user_id, title, created_at, updated_at) VALUES ('chain_a', 'owner_a', 'Mixed work', '2026-10-19T00:00:00Z', '2026-10-19T00:00:00Z'), ('chain_b', 'owner_b', 'Other work', '2026-10-19T00:00:00Z', '2026-10-19T00:00:00Z');")
	return conn, testing.expect(t, ok, "seed chains")
}

mixed_work_run :: proc(id: domain.Workflow_Run_ID, request_id: string) -> domain.Workflow_Run {
	return domain.Workflow_Run{
		run_id = id, chain_id = "chain_a", owner_user_id = "owner_a",
		title = "Audit", definition_ref = "security_audit@1",
		spec_json = `{"name":"audit","stages":[]}`, inputs_json = `{"target":"src"}`,
		current_execution_no = 1, request_id = request_id, request_hash = "hash_1",
		created_by_kind = "agent", created_by_id = "coordinator",
		created_at = "2026-10-19T00:00:00Z", updated_at = "2026-10-19T00:00:00Z",
		revision = 1,
	}
}

mixed_work_execution :: proc(run: domain.Workflow_Run, no := 1) -> domain.Workflow_Run_Execution {
	return domain.Workflow_Run_Execution{
		run_id = run.run_id, execution_no = no, chain_id = run.chain_id,
		owner_user_id = run.owner_user_id, state = domain.WORKFLOW_EXECUTION_PENDING,
		resolved_inputs_json = run.inputs_json, output_manifest_json = "{}", revision = 1,
	}
}

mixed_work_create :: proc(t: ^testing.T, conn: ^Conn, repo: ^iface.Taskchain_Repository, run: domain.Workflow_Run) -> bool {
	repos := iface.Repositories{taskchains = repo^}
	factory_impl: SQLite_Unit_Of_Work_Factory
	factory := new_unit_of_work_factory(&factory_impl, conn, &repos)
	uow, opened, open_err := iface.unit_of_work_begin(&factory)
	if !testing.expect(t, opened, open_err.message) do return false
	_, rok, rerr := iface.taskchain_insert_workflow_run(repo, run)
	_, eok, eerr := iface.taskchain_insert_workflow_execution(repo, mixed_work_execution(run))
	_, aok, aerr := iface.taskchain_append_workflow_run_event(repo, domain.Workflow_Run_Event{
		run_id = run.run_id, execution_no = 1, chain_id = run.chain_id, owner_user_id = run.owner_user_id,
		ts_ms = 10, actor_kind = "hub", kind = "created", payload_json = `{"first":true}`,
	})
	if !testing.expect(t, rok && eok && aok, fmt.tprintf("creation: %s / %s / %s", rerr.message, eerr.message, aerr.message)) {
		iface.unit_of_work_rollback(&uow)
		return false
	}
	committed, commit_err := iface.unit_of_work_commit(&uow)
	return testing.expect(t, committed, commit_err.message)
}

@(test)
test_mixed_work_runs_are_independent_and_owner_scoped :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, ok := mixed_work_db(t)
	if !ok do return
	defer close(&conn)
	impl: Taskchain_Repo_SQLite
	repo := new_taskchain_repository(&impl, &conn)
	run_ids := []string{"run_a", "run_b"}
	for id in run_ids {
		run := mixed_work_run(domain.Workflow_Run_ID(id), id)
		if !mixed_work_create(t, &conn, &repo, run) do return
		_, saved, err := iface.taskchain_insert_workflow_stage_execution(&repo, domain.Workflow_Stage_Execution{
			run_id = run.run_id, execution_no = 1, stage_key = "audit", chain_id = run.chain_id,
			owner_user_id = run.owner_user_id, item_count = 0, expanded_at = run.created_at,
		})
		testing.expect(t, saved && err.code == .None, "identical stage keys in separate runs; empty expansion persists")
	}
	runs, err := iface.taskchain_list_workflow_runs(&repo, "chain_a", "owner_a")
	testing.expect(t, err.code == .None && len(runs) == 2, "two runs in one chain")
	stages, serr := iface.taskchain_list_workflow_stage_executions(&repo, "run_a", 1, "owner_a")
	testing.expect(t, serr.code == .None && len(stages) == 1 && stages[0].item_count == 0, "zero-item fan-out is a durable expansion")
	_, found, denied := iface.taskchain_get_workflow_run(&repo, "run_a", "owner_b")
	testing.expect(t, !found && denied.code == .Not_Found, "owner cannot fetch another owner's run")
	other, _ := iface.taskchain_list_workflow_runs(&repo, "chain_a", "owner_b")
	other_execs, _ := iface.taskchain_list_workflow_executions(&repo, "run_a", "owner_b")
	other_stages, _ := iface.taskchain_list_workflow_stage_executions(&repo, "run_a", 1, "owner_b")
	other_events, _ := iface.taskchain_list_workflow_run_events(&repo, "run_a", "owner_b")
	testing.expect(t, len(other) + len(other_execs) + len(other_stages) + len(other_events) == 0, "all lists are owner-scoped")
	chain, exists, _ := iface.taskchain_get_chain(&repo, "chain_a")
	testing.expect(t, exists && chain.kind == domain.CHAIN_KIND_MIXED_WORK, "run container uses the one mixed-work model")
}

@(test)
test_mixed_work_snapshot_idempotency_and_revision_guards :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, ok := mixed_work_db(t)
	if !ok do return
	defer close(&conn)
	impl: Taskchain_Repo_SQLite
	repo := new_taskchain_repository(&impl, &conn)
	run := mixed_work_run("run_a", "request_a")
	if !mixed_work_create(t, &conn, &repo, run) do return
	lookup, found, _ := iface.taskchain_get_workflow_run_by_request(&repo, "chain_a", "owner_a", "request_a")
	testing.expect(t, found && lookup.run_id == run.run_id && lookup.request_hash == run.request_hash, "idempotency lookup returns original identity and hash")
	duplicate := run
	duplicate.run_id = "run_b"
	_, inserted, err := iface.taskchain_insert_workflow_run(&repo, duplicate)
	testing.expect(t, !inserted && err.code == .Conflict, "same request cannot create a second run")
	run.title = "Security audit"
	run.revision = 2
	_, updated, uerr := iface.taskchain_update_workflow_run(&repo, run)
	testing.expect(t, updated && uerr.code == .None, "current revision can update mutable title")
	_, stale, stale_err := iface.taskchain_update_workflow_run(&repo, run)
	testing.expect(t, !stale && stale_err.code == .Conflict, "stale revision cannot overwrite winner")
	for field in 0..<4 {
		changed := run
		changed.revision = 3
		switch field {
		case 0: changed.spec_json = `{"name":"replacement"}`
		case 1: changed.inputs_json = `{"target":"other"}`
		case 2: changed.chain_id = "chain_b"
		case 3: changed.request_hash = "changed_hash"
		}
		_, accepted, cerr := iface.taskchain_update_workflow_run(&repo, changed)
		testing.expect(t, !accepted && cerr.code == .Conflict, "snapshot, inputs, chain and request hash are immutable")
	}
	saved, _, _ := iface.taskchain_get_workflow_run(&repo, run.run_id, run.owner_user_id)
	testing.expect(t, saved.title == run.title && saved.revision == 2 && saved.spec_json == run.spec_json, "rejected updates leave original snapshot intact")
}

@(test)
test_mixed_work_retry_preserves_generation_history :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, ok := mixed_work_db(t)
	if !ok do return
	defer close(&conn)
	impl: Taskchain_Repo_SQLite
	repo := new_taskchain_repository(&impl, &conn)
	run := mixed_work_run("run_a", "request_a")
	if !mixed_work_create(t, &conn, &repo, run) do return
	_, first_expanded, _ := iface.taskchain_insert_workflow_stage_execution(&repo, domain.Workflow_Stage_Execution{
		run_id = run.run_id, execution_no = 1, stage_key = "audit", chain_id = run.chain_id,
		owner_user_id = run.owner_user_id, item_count = 0, expanded_at = run.created_at,
	})
	testing.expect(t, first_expanded, "first generation expansion")
	advanced := run
	advanced.current_execution_no = 2
	advanced.revision = 2
	_, premature, _ := iface.taskchain_update_workflow_run(&repo, advanced)
	testing.expect(t, !premature, "live execution cannot be replaced")
	execution := mixed_work_execution(run)
	execution.state = domain.WORKFLOW_EXECUTION_RUNNING
	execution.started_at = run.created_at
	execution.revision = 2
	_, started, _ := iface.taskchain_update_workflow_execution(&repo, execution)
	testing.expect(t, started, "pending execution starts")
	changed_inputs := execution
	changed_inputs.resolved_inputs_json = `{"target":"other"}`
	changed_inputs.revision = 3
	_, changed, _ := iface.taskchain_update_workflow_execution(&repo, changed_inputs)
	testing.expect(t, !changed, "started execution inputs are frozen")
	execution.state = domain.WORKFLOW_EXECUTION_FAILED
	execution.failure_code = "budget_exhausted"
	execution.ended_at = run.updated_at
	execution.revision = 3
	_, failed, _ := iface.taskchain_update_workflow_execution(&repo, execution)
	testing.expect(t, failed, "running execution can fail")
	testing.expect(t, exec(&conn, "BEGIN;"), "begin retry")
	_, added, _ := iface.taskchain_insert_workflow_execution(&repo, mixed_work_execution(run, 2))
	_, pointed, _ := iface.taskchain_update_workflow_run(&repo, advanced)
	testing.expect(t, added && pointed && exec(&conn, "COMMIT;"), "retry advances to next durable execution")
	_, expanded, _ := iface.taskchain_insert_workflow_stage_execution(&repo, domain.Workflow_Stage_Execution{
		run_id = run.run_id, execution_no = 2, stage_key = "audit", chain_id = run.chain_id,
		owner_user_id = run.owner_user_id, item_count = 2, expanded_at = run.created_at,
	})
	testing.expect(t, expanded, "new generation has its own stage expansion")
	old_stages, _ := iface.taskchain_list_workflow_stage_executions(&repo, run.run_id, 1, run.owner_user_id)
	new_stages, _ := iface.taskchain_list_workflow_stage_executions(&repo, run.run_id, 2, run.owner_user_id)
	testing.expect(t, len(old_stages) == 1 && len(new_stages) == 1, "same stage key may appear in both generations")
	if len(old_stages) == 1 && len(new_stages) == 1 {
		testing.expect(t, old_stages[0].item_count == 0 && new_stages[0].item_count == 2, "generation expansion results remain isolated")
	}
	execution.state = domain.WORKFLOW_EXECUTION_RUNNING
	execution.revision = 4
	_, reopened, _ := iface.taskchain_update_workflow_execution(&repo, execution)
	testing.expect(t, !reopened, "terminal history cannot be reopened in place")
	history, herr := iface.taskchain_list_workflow_executions(&repo, run.run_id, run.owner_user_id)
	testing.expect(t, herr.code == .None && len(history) == 2, "both executions remain addressable")
	if len(history) == 2 {
		testing.expect(t, history[0].state == "failed" && history[0].failure_code == "budget_exhausted" && history[1].state == "pending", "retry preserves old failure and starts fresh")
	}
}

@(test)
test_mixed_work_ownership_constraints_and_atomic_creation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, ok := mixed_work_db(t)
	if !ok do return
	defer close(&conn)
	impl: Taskchain_Repo_SQLite
	repo := new_taskchain_repository(&impl, &conn)
	run := mixed_work_run("run_a", "request_a")
	wrong := run
	wrong.owner_user_id = "owner_b"
	_, accepted, _ := iface.taskchain_insert_workflow_run(&repo, wrong)
	testing.expect(t, !accepted, "run owner must match chain owner")
	testing.expect(t, exec(&conn, "BEGIN;"), "begin incomplete creation")
	_, inserted, _ := iface.taskchain_insert_workflow_run(&repo, run)
	testing.expect(t, inserted, "deferred reference allows run before execution in same UoW")
	// An omitted first execution must fail at COMMIT, never leave a dangling run.
	stmt: sqlite3_stmt
	sqlite3_prepare_v2(conn.db, "COMMIT;", -1, &stmt, nil)
	testing.expect(t, sqlite3_step(stmt) != SQLITE_DONE, "missing current execution prevents commit")
	sqlite3_finalize(stmt)
	testing.expect(t, exec(&conn, "ROLLBACK;"), "rollback incomplete run")
	_, found, _ := iface.taskchain_get_workflow_run(&repo, run.run_id, run.owner_user_id)
	testing.expect(t, !found, "failed transaction leaves no run")
	if !mixed_work_create(t, &conn, &repo, run) do return
	bad_execution := mixed_work_execution(run, 2)
	bad_execution.chain_id = "chain_b"
	_, cross_chain, _ := iface.taskchain_insert_workflow_execution(&repo, bad_execution)
	testing.expect(t, !cross_chain, "execution cannot move to another chain")
	bad_execution = mixed_work_execution(run, 2)
	bad_execution.owner_user_id = "owner_b"
	_, cross_owner, _ := iface.taskchain_insert_workflow_execution(&repo, bad_execution)
	testing.expect(t, !cross_owner, "execution cannot borrow another owner")
	_, bad_event, _ := iface.taskchain_append_workflow_run_event(&repo, domain.Workflow_Run_Event{
		run_id = run.run_id, execution_no = 1, chain_id = "chain_b", owner_user_id = "owner_b",
		actor_kind = "hub", kind = "created", payload_json = "{}",
	})
	testing.expect(t, !bad_event, "event identity must match the execution")
}

@(test)
test_mixed_work_events_and_expansions_are_append_only :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, ok := mixed_work_db(t)
	if !ok do return
	defer close(&conn)
	impl: Taskchain_Repo_SQLite
	repo := new_taskchain_repository(&impl, &conn)
	run := mixed_work_run("run_a", "request_a")
	if !mixed_work_create(t, &conn, &repo, run) do return
	_, added, _ := iface.taskchain_append_workflow_run_event(&repo, domain.Workflow_Run_Event{
		run_id = run.run_id, execution_no = 1, chain_id = run.chain_id, owner_user_id = run.owner_user_id,
		ts_ms = 5, actor_kind = "hub", kind = "started", payload_json = "{  \"verbatim\": true }",
	})
	testing.expect(t, added, "append second event")
	events, _ := iface.taskchain_list_workflow_run_events(&repo, run.run_id, run.owner_user_id)
	testing.expect(t, len(events) == 2, "all events returned")
	if len(events) == 2 {
		testing.expect(t, events[1].event_id > events[0].event_id && events[1].ts_ms < events[0].ts_ms, "sequence ordering does not depend on clock order")
		testing.expect(t, events[1].payload_json == "{  \"verbatim\": true }", "event JSON is returned verbatim")
	}
	_, added, _ = iface.taskchain_insert_workflow_stage_execution(&repo, domain.Workflow_Stage_Execution{
		run_id = run.run_id, execution_no = 1, stage_key = "audit", chain_id = run.chain_id,
		owner_user_id = run.owner_user_id, item_count = 0, expanded_at = run.created_at,
	})
	testing.expect(t, added, "record expansion")
	history_mutations := []string{
		"UPDATE workflow_run_events SET payload_json = '{}' WHERE run_id = 'run_a';",
		"DELETE FROM workflow_run_events WHERE run_id = 'run_a';",
		"UPDATE workflow_stage_executions SET item_count = 1 WHERE run_id = 'run_a';",
		"DELETE FROM workflow_stage_executions WHERE run_id = 'run_a';",
		"DELETE FROM workflow_run_executions WHERE run_id = 'run_a';",
	}
	for sql in history_mutations {
		stmt: sqlite3_stmt
		sqlite3_prepare_v2(conn.db, cstring(raw_data(sql)), -1, &stmt, nil)
		testing.expect(t, sqlite3_step(stmt) != SQLITE_DONE, "history rewrite is rejected")
		sqlite3_finalize(stmt)
	}
}

@(test)
test_mixed_work_records_survive_reopen_and_migration_reentry :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := os.get_env("TEMP", context.temp_allocator)
	if dir == "" do dir = "/tmp"
	path := fmt.tprintf("%s/ham_mixed_work_%d.db", dir, os.get_pid())
	os.remove(path)
	defer os.remove(path)
	conn, ok := mixed_work_db(t, path)
	if !ok do return
	impl: Taskchain_Repo_SQLite
	repo := new_taskchain_repository(&impl, &conn)
	run := mixed_work_run("run_a", "request_a")
	if !mixed_work_create(t, &conn, &repo, run) {
		close(&conn)
		return
	}
	close(&conn)
	var_ok: bool
	conn, var_ok, _ = open(path)
	if !testing.expect(t, var_ok, "reopen persisted database") do return
	defer close(&conn)
	// Simulate exit after schema COMMIT but before recording the ledger row.
	testing.expect(t, exec(&conn, "DELETE FROM schema_migrations WHERE version = '097_workflow_runs.sql';"), "forget migration ledger entry")
	migrated, err := run_migrations(&conn)
	testing.expect(t, migrated && err.code == .None, "migration reentry preserves records")
	repo = new_taskchain_repository(&impl, &conn)
	saved, found, _ := iface.taskchain_get_workflow_run(&repo, run.run_id, run.owner_user_id)
	testing.expect(t, found && saved.current_execution_no == 1 && saved.inputs_json == run.inputs_json, "run and immutable inputs survive restart")
	executions, _ := iface.taskchain_list_workflow_executions(&repo, run.run_id, run.owner_user_id)
	events, _ := iface.taskchain_list_workflow_run_events(&repo, run.run_id, run.owner_user_id)
	testing.expect(t, len(executions) == 1 && len(events) == 1, "no duplicate history on restart")
}

@(test)
test_mixed_work_invalid_contracts_fail_closed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, ok := mixed_work_db(t)
	if !ok do return
	defer close(&conn)
	impl: Taskchain_Repo_SQLite
	repo := new_taskchain_repository(&impl, &conn)
	run := mixed_work_run("run_a", "request_a")
	for variant in 0..<5 {
		invalid := run
		switch variant {
		case 0: invalid.spec_json = "{"
		case 1: invalid.inputs_json = "[]"
		case 2: invalid.created_by_kind = "unknown"
		case 3: invalid.request_id = ""
		case 4: invalid.current_execution_no = 0
		}
		_, accepted, err := iface.taskchain_insert_workflow_run(&repo, invalid)
		testing.expect(t, !accepted && err.code == .Conflict, "malformed run cannot be persisted")
	}
	if !mixed_work_create(t, &conn, &repo, run) do return
	invalid_execution := mixed_work_execution(run)
	invalid_execution.state = domain.WORKFLOW_EXECUTION_SUCCEEDED
	invalid_execution.revision = 2
	_, skipped, _ := iface.taskchain_update_workflow_execution(&repo, invalid_execution)
	testing.expect(t, !skipped, "pending execution cannot skip running and become successful")
	invalid_execution = mixed_work_execution(run, 2)
	invalid_execution.state = "unknown"
	_, unknown, _ := iface.taskchain_insert_workflow_execution(&repo, invalid_execution)
	testing.expect(t, !unknown, "unknown execution state is rejected")
	_, expanded, _ := iface.taskchain_insert_workflow_stage_execution(&repo, domain.Workflow_Stage_Execution{
		run_id = run.run_id, execution_no = 1, stage_key = "audit", chain_id = "chain_b",
		owner_user_id = "owner_b", item_count = 0, expanded_at = run.created_at,
	})
	testing.expect(t, !expanded, "stage expansion cannot borrow another chain or owner")
}
