package sqlite

import domain "odin_test:hub/domain"

// Durable mixed-work records. Call mutations inside the task engine UoW.
// In particular run creation and its first execution must commit together.

@(private = "file")
workflow_run_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Workflow_Run {
	return domain.Workflow_Run{
		run_id = domain.Workflow_Run_ID(column_text(stmt, 0)),
		chain_id = domain.Task_Chain_ID(column_text(stmt, 1)),
		owner_user_id = domain.User_ID(column_text(stmt, 2)),
		title = column_text(stmt, 3),
		definition_ref = column_text(stmt, 4),
		spec_json = column_text(stmt, 5),
		inputs_json = column_text(stmt, 6),
		current_execution_no = int(sqlite3_column_int64(stmt, 7)),
		request_id = column_text(stmt, 8),
		request_hash = column_text(stmt, 9),
		created_by_kind = column_text(stmt, 10),
		created_by_id = column_text(stmt, 11),
		created_at = column_text(stmt, 12),
		updated_at = column_text(stmt, 13),
		revision = i64(sqlite3_column_int64(stmt, 14)),
	}
}

insert_workflow_run_sqlite :: proc(ctx: rawptr, record: domain.Workflow_Run) -> (domain.Workflow_Run, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := workflow_run_prepare(impl, "INSERT INTO workflow_runs (run_id, chain_id, owner_user_id, title, definition_ref, spec_json, inputs_json, current_execution_no, request_id, request_hash, created_by_kind, created_by_id, created_at, updated_at, revision) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);", "workflow_run insert")
	if err.code != .None do return domain.Workflow_Run{}, false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(record.run_id))
	bind_text(stmt, 2, string(record.chain_id))
	bind_text(stmt, 3, string(record.owner_user_id))
	bind_text(stmt, 4, record.title)
	bind_text(stmt, 5, record.definition_ref)
	bind_text(stmt, 6, record.spec_json)
	bind_text(stmt, 7, record.inputs_json)
	sqlite3_bind_int64(stmt, 8, i64(record.current_execution_no))
	bind_text(stmt, 9, record.request_id)
	bind_text(stmt, 10, record.request_hash)
	bind_text(stmt, 11, record.created_by_kind)
	bind_text(stmt, 12, record.created_by_id)
	bind_text(stmt, 13, record.created_at)
	bind_text(stmt, 14, record.updated_at)
	sqlite3_bind_int64(stmt, 15, i64(record.revision))
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.Workflow_Run{}, false, domain.domain_error(.Conflict, "workflow_run could not be inserted")
	return record, true, domain.Domain_Error{}
}

update_workflow_run_sqlite :: proc(ctx: rawptr, record: domain.Workflow_Run) -> (domain.Workflow_Run, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := workflow_run_prepare(impl, "UPDATE workflow_runs SET chain_id = ?, owner_user_id = ?, title = ?, definition_ref = ?, spec_json = ?, inputs_json = ?, current_execution_no = ?, request_id = ?, request_hash = ?, created_by_kind = ?, created_by_id = ?, created_at = ?, updated_at = ?, revision = ? WHERE run_id = ? AND owner_user_id = ? AND revision = ?;", "workflow_run update")
	if err.code != .None do return domain.Workflow_Run{}, false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(record.chain_id))
	bind_text(stmt, 2, string(record.owner_user_id))
	bind_text(stmt, 3, record.title)
	bind_text(stmt, 4, record.definition_ref)
	bind_text(stmt, 5, record.spec_json)
	bind_text(stmt, 6, record.inputs_json)
	sqlite3_bind_int64(stmt, 7, i64(record.current_execution_no))
	bind_text(stmt, 8, record.request_id)
	bind_text(stmt, 9, record.request_hash)
	bind_text(stmt, 10, record.created_by_kind)
	bind_text(stmt, 11, record.created_by_id)
	bind_text(stmt, 12, record.created_at)
	bind_text(stmt, 13, record.updated_at)
	sqlite3_bind_int64(stmt, 14, i64(record.revision))
	bind_text(stmt, 15, string(record.run_id))
	bind_text(stmt, 16, string(record.owner_user_id))
	sqlite3_bind_int64(stmt, 17, i64(record.revision - 1))
	rc, changed := step_changes(impl.conn.db, stmt)
	if rc != SQLITE_DONE || changed != 1 do return domain.Workflow_Run{}, false, domain.domain_error(.Conflict, "workflow_run changed or update is invalid")
	return record, true, domain.Domain_Error{}
}

get_workflow_run_sqlite :: proc(ctx: rawptr, run_id: domain.Workflow_Run_ID, owner_user_id: domain.User_ID) -> (domain.Workflow_Run, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := workflow_run_prepare(impl, "SELECT run_id, chain_id, owner_user_id, title, definition_ref, spec_json, inputs_json, current_execution_no, request_id, request_hash, created_by_kind, created_by_id, created_at, updated_at, revision FROM workflow_runs WHERE run_id = ? AND owner_user_id = ? ORDER BY run_id;", "get_workflow_run")
	if err.code != .None do return domain.Workflow_Run{}, false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(run_id))
	bind_text(stmt, 2, string(owner_user_id))
	rc := sqlite3_step(stmt)
	if rc == SQLITE_DONE do return domain.Workflow_Run{}, false, domain.domain_error(.Not_Found, "workflow record not found")
	if rc != SQLITE_ROW do return domain.Workflow_Run{}, false, domain.domain_error(.Internal_Error, "get_workflow_run failed")
	return workflow_run_from_stmt(stmt), true, domain.Domain_Error{}
}

get_workflow_run_by_request_sqlite :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID, request_id: string) -> (domain.Workflow_Run, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := workflow_run_prepare(impl, "SELECT run_id, chain_id, owner_user_id, title, definition_ref, spec_json, inputs_json, current_execution_no, request_id, request_hash, created_by_kind, created_by_id, created_at, updated_at, revision FROM workflow_runs WHERE chain_id = ? AND owner_user_id = ? AND request_id = ? ORDER BY run_id;", "get_workflow_run_by_request")
	if err.code != .None do return domain.Workflow_Run{}, false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(chain_id))
	bind_text(stmt, 2, string(owner_user_id))
	bind_text(stmt, 3, request_id)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_DONE do return domain.Workflow_Run{}, false, domain.domain_error(.Not_Found, "workflow record not found")
	if rc != SQLITE_ROW do return domain.Workflow_Run{}, false, domain.domain_error(.Internal_Error, "get_workflow_run_by_request failed")
	return workflow_run_from_stmt(stmt), true, domain.Domain_Error{}
}

list_workflow_runs_sqlite :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> ([]domain.Workflow_Run, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := workflow_run_prepare(impl, "SELECT run_id, chain_id, owner_user_id, title, definition_ref, spec_json, inputs_json, current_execution_no, request_id, request_hash, created_by_kind, created_by_id, created_at, updated_at, revision FROM workflow_runs WHERE chain_id = ? AND owner_user_id = ? ORDER BY created_at, run_id;", "list_workflow_runs")
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(chain_id))
	bind_text(stmt, 2, string(owner_user_id))
	out := make([dynamic]domain.Workflow_Run)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW do return out[:], domain.domain_error(.Internal_Error, "list_workflow_runs failed")
		append(&out, workflow_run_from_stmt(stmt))
	}
	return out[:], domain.Domain_Error{}
}

@(private = "file")
workflow_execution_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Workflow_Run_Execution {
	return domain.Workflow_Run_Execution{
		run_id = domain.Workflow_Run_ID(column_text(stmt, 0)),
		execution_no = int(sqlite3_column_int64(stmt, 1)),
		chain_id = domain.Task_Chain_ID(column_text(stmt, 2)),
		owner_user_id = domain.User_ID(column_text(stmt, 3)),
		state = column_text(stmt, 4),
		resolved_inputs_json = column_text(stmt, 5),
		started_at = column_text(stmt, 6),
		ended_at = column_text(stmt, 7),
		failure_code = column_text(stmt, 8),
		failure_detail = column_text(stmt, 9),
		output_manifest_json = column_text(stmt, 10),
		revision = i64(sqlite3_column_int64(stmt, 11)),
	}
}

insert_workflow_execution_sqlite :: proc(ctx: rawptr, record: domain.Workflow_Run_Execution) -> (domain.Workflow_Run_Execution, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := workflow_run_prepare(impl, "INSERT INTO workflow_run_executions (run_id, execution_no, chain_id, owner_user_id, state, resolved_inputs_json, started_at, ended_at, failure_code, failure_detail, output_manifest_json, revision) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);", "workflow_execution insert")
	if err.code != .None do return domain.Workflow_Run_Execution{}, false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(record.run_id))
	sqlite3_bind_int64(stmt, 2, i64(record.execution_no))
	bind_text(stmt, 3, string(record.chain_id))
	bind_text(stmt, 4, string(record.owner_user_id))
	bind_text(stmt, 5, record.state)
	bind_text(stmt, 6, record.resolved_inputs_json)
	bind_text(stmt, 7, record.started_at)
	bind_text(stmt, 8, record.ended_at)
	bind_text(stmt, 9, record.failure_code)
	bind_text(stmt, 10, record.failure_detail)
	bind_text(stmt, 11, record.output_manifest_json)
	sqlite3_bind_int64(stmt, 12, i64(record.revision))
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.Workflow_Run_Execution{}, false, domain.domain_error(.Conflict, "workflow_execution could not be inserted")
	return record, true, domain.Domain_Error{}
}

update_workflow_execution_sqlite :: proc(ctx: rawptr, record: domain.Workflow_Run_Execution) -> (domain.Workflow_Run_Execution, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := workflow_run_prepare(impl, "UPDATE workflow_run_executions SET chain_id = ?, owner_user_id = ?, state = ?, resolved_inputs_json = ?, started_at = ?, ended_at = ?, failure_code = ?, failure_detail = ?, output_manifest_json = ?, revision = ? WHERE run_id = ? AND execution_no = ? AND owner_user_id = ? AND revision = ?;", "workflow_execution update")
	if err.code != .None do return domain.Workflow_Run_Execution{}, false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(record.chain_id))
	bind_text(stmt, 2, string(record.owner_user_id))
	bind_text(stmt, 3, record.state)
	bind_text(stmt, 4, record.resolved_inputs_json)
	bind_text(stmt, 5, record.started_at)
	bind_text(stmt, 6, record.ended_at)
	bind_text(stmt, 7, record.failure_code)
	bind_text(stmt, 8, record.failure_detail)
	bind_text(stmt, 9, record.output_manifest_json)
	sqlite3_bind_int64(stmt, 10, i64(record.revision))
	bind_text(stmt, 11, string(record.run_id))
	sqlite3_bind_int64(stmt, 12, i64(record.execution_no))
	bind_text(stmt, 13, string(record.owner_user_id))
	sqlite3_bind_int64(stmt, 14, i64(record.revision - 1))
	rc, changed := step_changes(impl.conn.db, stmt)
	if rc != SQLITE_DONE || changed != 1 do return domain.Workflow_Run_Execution{}, false, domain.domain_error(.Conflict, "workflow_execution changed or update is invalid")
	return record, true, domain.Domain_Error{}
}

get_workflow_execution_sqlite :: proc(ctx: rawptr, run_id: domain.Workflow_Run_ID, execution_no: int, owner_user_id: domain.User_ID) -> (domain.Workflow_Run_Execution, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := workflow_run_prepare(impl, "SELECT run_id, execution_no, chain_id, owner_user_id, state, resolved_inputs_json, started_at, ended_at, failure_code, failure_detail, output_manifest_json, revision FROM workflow_run_executions WHERE run_id = ? AND execution_no = ? AND owner_user_id = ? ORDER BY execution_no;", "get_workflow_execution")
	if err.code != .None do return domain.Workflow_Run_Execution{}, false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(run_id))
	sqlite3_bind_int64(stmt, 2, i64(execution_no))
	bind_text(stmt, 3, string(owner_user_id))
	rc := sqlite3_step(stmt)
	if rc == SQLITE_DONE do return domain.Workflow_Run_Execution{}, false, domain.domain_error(.Not_Found, "workflow record not found")
	if rc != SQLITE_ROW do return domain.Workflow_Run_Execution{}, false, domain.domain_error(.Internal_Error, "get_workflow_execution failed")
	return workflow_execution_from_stmt(stmt), true, domain.Domain_Error{}
}

list_workflow_executions_sqlite :: proc(ctx: rawptr, run_id: domain.Workflow_Run_ID, owner_user_id: domain.User_ID) -> ([]domain.Workflow_Run_Execution, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := workflow_run_prepare(impl, "SELECT run_id, execution_no, chain_id, owner_user_id, state, resolved_inputs_json, started_at, ended_at, failure_code, failure_detail, output_manifest_json, revision FROM workflow_run_executions WHERE run_id = ? AND owner_user_id = ? ORDER BY execution_no;", "list_workflow_executions")
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(run_id))
	bind_text(stmt, 2, string(owner_user_id))
	out := make([dynamic]domain.Workflow_Run_Execution)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW do return out[:], domain.domain_error(.Internal_Error, "list_workflow_executions failed")
		append(&out, workflow_execution_from_stmt(stmt))
	}
	return out[:], domain.Domain_Error{}
}

@(private = "file")
workflow_stage_execution_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Workflow_Stage_Execution {
	return domain.Workflow_Stage_Execution{
		run_id = domain.Workflow_Run_ID(column_text(stmt, 0)),
		execution_no = int(sqlite3_column_int64(stmt, 1)),
		stage_key = column_text(stmt, 2),
		chain_id = domain.Task_Chain_ID(column_text(stmt, 3)),
		owner_user_id = domain.User_ID(column_text(stmt, 4)),
		item_count = int(sqlite3_column_int64(stmt, 5)),
		expanded_at = column_text(stmt, 6),
	}
}

insert_workflow_stage_execution_sqlite :: proc(ctx: rawptr, record: domain.Workflow_Stage_Execution) -> (domain.Workflow_Stage_Execution, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := workflow_run_prepare(impl, "INSERT INTO workflow_stage_executions (run_id, execution_no, stage_key, chain_id, owner_user_id, item_count, expanded_at) VALUES (?, ?, ?, ?, ?, ?, ?);", "workflow_stage_execution insert")
	if err.code != .None do return domain.Workflow_Stage_Execution{}, false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(record.run_id))
	sqlite3_bind_int64(stmt, 2, i64(record.execution_no))
	bind_text(stmt, 3, record.stage_key)
	bind_text(stmt, 4, string(record.chain_id))
	bind_text(stmt, 5, string(record.owner_user_id))
	sqlite3_bind_int64(stmt, 6, i64(record.item_count))
	bind_text(stmt, 7, record.expanded_at)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.Workflow_Stage_Execution{}, false, domain.domain_error(.Conflict, "workflow_stage_execution could not be inserted")
	return record, true, domain.Domain_Error{}
}

list_workflow_stage_executions_sqlite :: proc(ctx: rawptr, run_id: domain.Workflow_Run_ID, execution_no: int, owner_user_id: domain.User_ID) -> ([]domain.Workflow_Stage_Execution, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := workflow_run_prepare(impl, "SELECT run_id, execution_no, stage_key, chain_id, owner_user_id, item_count, expanded_at FROM workflow_stage_executions WHERE run_id = ? AND execution_no = ? AND owner_user_id = ? ORDER BY stage_key;", "list_workflow_stage_executions")
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(run_id))
	sqlite3_bind_int64(stmt, 2, i64(execution_no))
	bind_text(stmt, 3, string(owner_user_id))
	out := make([dynamic]domain.Workflow_Stage_Execution)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW do return out[:], domain.domain_error(.Internal_Error, "list_workflow_stage_executions failed")
		append(&out, workflow_stage_execution_from_stmt(stmt))
	}
	return out[:], domain.Domain_Error{}
}

@(private = "file")
workflow_run_event_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Workflow_Run_Event {
	return domain.Workflow_Run_Event{
		event_id = i64(sqlite3_column_int64(stmt, 0)),
		run_id = domain.Workflow_Run_ID(column_text(stmt, 1)),
		execution_no = int(sqlite3_column_int64(stmt, 2)),
		chain_id = domain.Task_Chain_ID(column_text(stmt, 3)),
		owner_user_id = domain.User_ID(column_text(stmt, 4)),
		ts_ms = i64(sqlite3_column_int64(stmt, 5)),
		actor_kind = column_text(stmt, 6),
		actor_id = column_text(stmt, 7),
		kind = column_text(stmt, 8),
		payload_json = column_text(stmt, 9),
	}
}

append_workflow_run_event_sqlite :: proc(ctx: rawptr, record: domain.Workflow_Run_Event) -> (domain.Workflow_Run_Event, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := workflow_run_prepare(impl, "INSERT INTO workflow_run_events (run_id, execution_no, chain_id, owner_user_id, ts_ms, actor_kind, actor_id, kind, payload_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING event_id;", "workflow_run_event insert")
	if err.code != .None do return domain.Workflow_Run_Event{}, false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(record.run_id))
	sqlite3_bind_int64(stmt, 2, i64(record.execution_no))
	bind_text(stmt, 3, string(record.chain_id))
	bind_text(stmt, 4, string(record.owner_user_id))
	sqlite3_bind_int64(stmt, 5, i64(record.ts_ms))
	bind_text(stmt, 6, record.actor_kind)
	bind_text(stmt, 7, record.actor_id)
	bind_text(stmt, 8, record.kind)
	bind_text(stmt, 9, record.payload_json)
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Workflow_Run_Event{}, false, domain.domain_error(.Conflict, "workflow event could not be appended")
	saved := record
	saved.event_id = sqlite3_column_int64(stmt, 0)
	return saved, true, domain.Domain_Error{}
}

list_workflow_run_events_sqlite :: proc(ctx: rawptr, run_id: domain.Workflow_Run_ID, owner_user_id: domain.User_ID) -> ([]domain.Workflow_Run_Event, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := workflow_run_prepare(impl, "SELECT event_id, run_id, execution_no, chain_id, owner_user_id, ts_ms, actor_kind, actor_id, kind, payload_json FROM workflow_run_events WHERE run_id = ? AND owner_user_id = ? ORDER BY event_id;", "list_workflow_run_events")
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(run_id))
	bind_text(stmt, 2, string(owner_user_id))
	out := make([dynamic]domain.Workflow_Run_Event)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW do return out[:], domain.domain_error(.Internal_Error, "list_workflow_run_events failed")
		append(&out, workflow_run_event_from_stmt(stmt))
	}
	return out[:], domain.Domain_Error{}
}

@(private = "file")
workflow_run_prepare :: proc(impl: ^Taskchain_Repo_SQLite, query: string, what: string) -> (sqlite3_stmt, domain.Domain_Error) {
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, what)
	}
	return stmt, domain.Domain_Error{}
}
