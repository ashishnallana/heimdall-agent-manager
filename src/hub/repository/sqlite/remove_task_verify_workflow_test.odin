#+private file
package sqlite

import "core:strings"
import "core:testing"

// Production regression (Mundus, v0.4.45 deploy): 129's brief rewrite hit a
// workflow-generated task (workflow_run_id != '') whose brief still carried a
// removed verify key; 099's tasks_workflow_definition_immutable trigger aborted
// the whole migration and the hub could not start. 129 must lift that guard for
// its own one-shot rewrite and restore it byte-identical to 099.

RTVW_TRIGGER :: "tasks_workflow_definition_immutable"

rtvw_text :: proc(conn: ^Conn, query: string) -> string {
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(conn.db, strings.clone_to_cstring(query, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return ""
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return ""
	return strings.clone(column_text_unowned(stmt, 0), context.temp_allocator)
}

// 099's trigger text exactly as sqlite_master stores it (CREATE TRIGGER … END).
rtvw_099_trigger_sql :: proc() -> string {
	src := MIGRATION_099_MIXED_WORK_EXECUTION
	start := strings.index(src, "CREATE TRIGGER " + RTVW_TRIGGER)
	if start < 0 do return ""
	end := strings.index(src[start:], "END;")
	return src[start:start + end + len("END")]
}

RTVW_SEED :: `
BEGIN;
INSERT INTO users(user_id, name, display_name, status, created_at, updated_at) VALUES ('u1','u1','u1','active','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');
INSERT INTO task_chains(chain_id, owner_user_id, title, created_at, updated_at) VALUES ('chain_wf','u1','Workflow chain','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');
INSERT INTO workflow_runs(run_id, chain_id, owner_user_id, title, definition_ref, spec_json, inputs_json, current_execution_no, request_id, request_hash, created_by_kind, created_by_id, created_at, updated_at, revision)
 VALUES ('run_1','chain_wf','u1','Run','def@1','{}','{}',1,'req_1','hash_1','user','u1','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z',1);
INSERT INTO workflow_run_executions(run_id, execution_no, chain_id, owner_user_id, state, resolved_inputs_json, output_manifest_json, revision)
 VALUES ('run_1',1,'chain_wf','u1','running','{}','{}',1);
INSERT INTO tasks(task_id, chain_id, owner_user_id, title, description, publish_state, state, kind, workflow_run_id, workflow_execution_no, stage_key, stage_index, brief_json, created_at, updated_at)
 VALUES ('t_wf','chain_wf','u1','Generated','','published','backlog','task','run_1',1,'build',0,
  '{"goal":"g","verify":["make test"],"auto_submit":true,"require_independent_verify":true}','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');
INSERT INTO tasks(task_id, chain_id, owner_user_id, title, description, publish_state, state, kind, brief_json, created_at, updated_at)
 VALUES ('t_review','chain_wf','u1','Plain in review','','published','in_review','task',
  '{"goal":"g","require_independent_verify":true}','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');
COMMIT;
`

@(test)
test_remove_task_verify_rewrites_workflow_generated_briefs :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, path, ok := tmpl_open_file_prod(t, "rtv_workflow_brief")
	defer tmpl_remove_db(path)
	if !ok do return
	defer close(&conn)
	pre_ok, pre_err := run_migrations(&conn, stop_before = "129_remove_task_verify.sql")
	if !testing.expect(t, pre_ok, pre_err.message) do return
	if !testing.expect(t, exec(&conn, RTVW_SEED), "seed a workflow-generated task with legacy verify keys") do return
	// Precondition: the 099 guard really protects this task's brief.
	testing.expect(t, !exec(&conn, "UPDATE tasks SET brief_json='{}' WHERE task_id='t_wf';"), "099 guard active before 129")

	mig_ok, mig_err := run_migrations(&conn)
	if !testing.expect(t, mig_ok, mig_err.message) do return
	testing.expect(t, migration_applied(&conn, "129_remove_task_verify.sql"), "129 recorded")
	brief := rtvw_text(&conn, "SELECT brief_json FROM tasks WHERE task_id='t_wf';")
	testing.expect_value(t, rtvw_text(&conn, "SELECT json_type(brief_json,'$.verify') IS NULL AND json_type(brief_json,'$.auto_submit') IS NULL AND json_type(brief_json,'$.require_independent_verify') IS NULL FROM tasks WHERE task_id='t_wf';"), "1")
	testing.expect_value(t, rtvw_text(&conn, "SELECT json_extract(brief_json,'$.goal') FROM tasks WHERE task_id='t_wf';"), "g")
	testing.expect(t, !strings.contains(brief, "verify"), brief)
	// D1 path ran for the plain in-review task (no reviewers -> user approval).
	testing.expect_value(t, rtvw_text(&conn, "SELECT requires_user_approval FROM tasks WHERE task_id='t_review';"), "1")
	testing.expect_value(t, rtvw_text(&conn, "SELECT json_type(brief_json,'$.require_independent_verify') IS NULL FROM tasks WHERE task_id='t_review';"), "1")

	// The guard is back, byte-identical to 099, and still enforcing.
	want := rtvw_099_trigger_sql()
	testing.expect(t, want != "", "099 trigger text found")
	testing.expect_value(t, rtvw_text(&conn, "SELECT sql FROM sqlite_master WHERE type='trigger' AND name='tasks_workflow_definition_immutable';"), want)
	testing.expect(t, !exec(&conn, "UPDATE tasks SET brief_json='{\"goal\":\"changed\"}' WHERE task_id='t_wf';"), "workflow task brief still immutable")
	testing.expect_value(t, rtvw_text(&conn, "SELECT json_extract(brief_json,'$.goal') FROM tasks WHERE task_id='t_wf';"), "g")
	// Plain tasks remain editable.
	testing.expect(t, exec(&conn, "UPDATE tasks SET brief_json='{\"goal\":\"edited\"}' WHERE task_id='t_review';"), "plain task brief editable")
}
