package sqlite

import domain "odin_test:hub/domain"

// Mixed-work mutations participate in the existing task-engine unit of work.

@(private = "file")
work_dependency_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Work_Dependency {
	return domain.Work_Dependency{
		dependency_id = column_text(stmt, 0),
		chain_id = domain.Task_Chain_ID(column_text(stmt, 1)),
		owner_user_id = domain.User_ID(column_text(stmt, 2)),
		created_by_kind = column_text(stmt, 7),
		created_by_id = column_text(stmt, 8),
		created_at = column_text(stmt, 9),
		removed_at = column_text(stmt, 10),
		removed_by_kind = column_text(stmt, 11),
		removed_by_id = column_text(stmt, 12),
		removal_reason = column_text(stmt, 13),
		dependent = domain.Work_Item_Ref{kind = column_text(stmt, 3), id = column_text(stmt, 4)},
		prerequisite = domain.Work_Item_Ref{kind = column_text(stmt, 5), id = column_text(stmt, 6)},
	}
}

insert_work_dependency_sqlite :: proc(ctx: rawptr, record: domain.Work_Dependency) -> (domain.Work_Dependency, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := mixed_work_prepare(impl, "INSERT INTO work_dependencies (dependency_id, chain_id, owner_user_id, dependent_kind, dependent_id, prerequisite_kind, prerequisite_id, created_by_kind, created_by_id, created_at, removed_at, removed_by_kind, removed_by_id, removal_reason) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);", "work_dependency insert")
	if err.code != .None do return domain.Work_Dependency{}, false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, record.dependency_id)
	bind_text(stmt, 2, string(record.chain_id))
	bind_text(stmt, 3, string(record.owner_user_id))
	bind_text(stmt, 4, record.dependent.kind)
	bind_text(stmt, 5, record.dependent.id)
	bind_text(stmt, 6, record.prerequisite.kind)
	bind_text(stmt, 7, record.prerequisite.id)
	bind_text(stmt, 8, record.created_by_kind)
	bind_text(stmt, 9, record.created_by_id)
	bind_text(stmt, 10, record.created_at)
	bind_text(stmt, 11, record.removed_at)
	bind_text(stmt, 12, record.removed_by_kind)
	bind_text(stmt, 13, record.removed_by_id)
	bind_text(stmt, 14, record.removal_reason)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.Work_Dependency{}, false, domain.domain_error(.Conflict, "work_dependency violates the mixed-work contract")
	return record, true, domain.Domain_Error{}
}

list_work_dependencies_sqlite :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> ([]domain.Work_Dependency, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := mixed_work_prepare(impl, "SELECT dependency_id, chain_id, owner_user_id, dependent_kind, dependent_id, prerequisite_kind, prerequisite_id, created_by_kind, created_by_id, created_at, removed_at, removed_by_kind, removed_by_id, removal_reason FROM work_dependencies WHERE chain_id = ? AND owner_user_id = ? ORDER BY created_at, dependency_id;", "list_work_dependencies")
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(chain_id))
	bind_text(stmt, 2, string(owner_user_id))
	out := make([dynamic]domain.Work_Dependency)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW do return out[:], domain.domain_error(.Internal_Error, "list_work_dependencies failed")
		append(&out, work_dependency_from_stmt(stmt))
	}
	return out[:], domain.Domain_Error{}
}

@(private = "file")
work_input_receipt_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Work_Input_Receipt {
	return domain.Work_Input_Receipt{
		receipt_id = column_text(stmt, 0),
		chain_id = domain.Task_Chain_ID(column_text(stmt, 1)),
		owner_user_id = domain.User_ID(column_text(stmt, 2)),
		dependent_generation = int(sqlite3_column_int64(stmt, 5)),
		prerequisite_generation = int(sqlite3_column_int64(stmt, 8)),
		output_manifest_json = column_text(stmt, 9),
		created_at = column_text(stmt, 10),
		dependent = domain.Work_Item_Ref{kind = column_text(stmt, 3), id = column_text(stmt, 4)},
		prerequisite = domain.Work_Item_Ref{kind = column_text(stmt, 6), id = column_text(stmt, 7)},
	}
}

insert_work_input_receipt_sqlite :: proc(ctx: rawptr, record: domain.Work_Input_Receipt) -> (domain.Work_Input_Receipt, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := mixed_work_prepare(impl, "INSERT INTO work_input_receipts (receipt_id, chain_id, owner_user_id, dependent_kind, dependent_id, dependent_generation, prerequisite_kind, prerequisite_id, prerequisite_generation, output_manifest_json, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);", "work_input_receipt insert")
	if err.code != .None do return domain.Work_Input_Receipt{}, false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, record.receipt_id)
	bind_text(stmt, 2, string(record.chain_id))
	bind_text(stmt, 3, string(record.owner_user_id))
	bind_text(stmt, 4, record.dependent.kind)
	bind_text(stmt, 5, record.dependent.id)
	sqlite3_bind_int64(stmt, 6, i64(record.dependent_generation))
	bind_text(stmt, 7, record.prerequisite.kind)
	bind_text(stmt, 8, record.prerequisite.id)
	sqlite3_bind_int64(stmt, 9, i64(record.prerequisite_generation))
	bind_text(stmt, 10, record.output_manifest_json)
	bind_text(stmt, 11, record.created_at)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.Work_Input_Receipt{}, false, domain.domain_error(.Conflict, "work_input_receipt violates the mixed-work contract")
	return record, true, domain.Domain_Error{}
}

list_work_receipts_by_prerequisite_sqlite :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID, item: domain.Work_Item_Ref) -> ([]domain.Work_Input_Receipt, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := mixed_work_prepare(impl, "SELECT receipt_id, chain_id, owner_user_id, dependent_kind, dependent_id, dependent_generation, prerequisite_kind, prerequisite_id, prerequisite_generation, output_manifest_json, created_at FROM work_input_receipts WHERE chain_id = ? AND owner_user_id = ? AND prerequisite_kind = ? AND prerequisite_id = ? ORDER BY created_at, receipt_id;", "list_work_receipts_by_prerequisite")
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(chain_id))
	bind_text(stmt, 2, string(owner_user_id))
	bind_text(stmt, 3, item.kind)
	bind_text(stmt, 4, item.id)
	out := make([dynamic]domain.Work_Input_Receipt)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW do return out[:], domain.domain_error(.Internal_Error, "list_work_receipts_by_prerequisite failed")
		append(&out, work_input_receipt_from_stmt(stmt))
	}
	return out[:], domain.Domain_Error{}
}

list_work_receipts_by_dependent_sqlite :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID, item: domain.Work_Item_Ref) -> ([]domain.Work_Input_Receipt, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := mixed_work_prepare(impl, "SELECT receipt_id, chain_id, owner_user_id, dependent_kind, dependent_id, dependent_generation, prerequisite_kind, prerequisite_id, prerequisite_generation, output_manifest_json, created_at FROM work_input_receipts WHERE chain_id = ? AND owner_user_id = ? AND dependent_kind = ? AND dependent_id = ? ORDER BY created_at, receipt_id;", "list_work_receipts_by_dependent")
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(chain_id))
	bind_text(stmt, 2, string(owner_user_id))
	bind_text(stmt, 3, item.kind)
	bind_text(stmt, 4, item.id)
	out := make([dynamic]domain.Work_Input_Receipt)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW do return out[:], domain.domain_error(.Internal_Error, "list_work_receipts_by_dependent failed")
		append(&out, work_input_receipt_from_stmt(stmt))
	}
	return out[:], domain.Domain_Error{}
}

@(private = "file")
work_scope_decision_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Work_Scope_Decision {
	return domain.Work_Scope_Decision{
		decision_id = i64(sqlite3_column_int64(stmt, 0)),
		chain_id = domain.Task_Chain_ID(column_text(stmt, 1)),
		owner_user_id = domain.User_ID(column_text(stmt, 2)),
		action = column_text(stmt, 5),
		reason = column_text(stmt, 6),
		actor_kind = column_text(stmt, 7),
		actor_id = column_text(stmt, 8),
		created_at = column_text(stmt, 9),
		item = domain.Work_Item_Ref{kind = column_text(stmt, 3), id = column_text(stmt, 4)},
	}
}

append_work_scope_decision_sqlite :: proc(ctx: rawptr, record: domain.Work_Scope_Decision) -> (domain.Work_Scope_Decision, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := mixed_work_prepare(impl, "INSERT INTO work_scope_decisions (chain_id, owner_user_id, item_kind, item_id, action, reason, actor_kind, actor_id, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING decision_id;", "work_scope_decision insert")
	if err.code != .None do return domain.Work_Scope_Decision{}, false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(record.chain_id))
	bind_text(stmt, 2, string(record.owner_user_id))
	bind_text(stmt, 3, record.item.kind)
	bind_text(stmt, 4, record.item.id)
	bind_text(stmt, 5, record.action)
	bind_text(stmt, 6, record.reason)
	bind_text(stmt, 7, record.actor_kind)
	bind_text(stmt, 8, record.actor_id)
	bind_text(stmt, 9, record.created_at)
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Work_Scope_Decision{}, false, domain.domain_error(.Conflict, "scope decision is invalid")
	saved := record
	saved.decision_id = sqlite3_column_int64(stmt, 0)
	return saved, true, domain.Domain_Error{}
}

list_work_scope_decisions_sqlite :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> ([]domain.Work_Scope_Decision, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := mixed_work_prepare(impl, "SELECT decision_id, chain_id, owner_user_id, item_kind, item_id, action, reason, actor_kind, actor_id, created_at FROM work_scope_decisions WHERE chain_id = ? AND owner_user_id = ? ORDER BY decision_id;", "list_work_scope_decisions")
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(chain_id))
	bind_text(stmt, 2, string(owner_user_id))
	out := make([dynamic]domain.Work_Scope_Decision)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW do return out[:], domain.domain_error(.Internal_Error, "list_work_scope_decisions failed")
		append(&out, work_scope_decision_from_stmt(stmt))
	}
	return out[:], domain.Domain_Error{}
}

remove_work_dependency_sqlite :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID, dependency_id: string, removed_at: string, actor_kind: string, actor_id: string, reason: string) -> (bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := mixed_work_prepare(impl, "UPDATE work_dependencies SET removed_at = ?, removed_by_kind = ?, removed_by_id = ?, removal_reason = ? WHERE chain_id = ? AND owner_user_id = ? AND dependency_id = ? AND removed_at = '';", "dependency removal")
	if err.code != .None do return false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, removed_at)
	bind_text(stmt, 2, actor_kind)
	bind_text(stmt, 3, actor_id)
	bind_text(stmt, 4, reason)
	bind_text(stmt, 5, string(chain_id))
	bind_text(stmt, 6, string(owner_user_id))
	bind_text(stmt, 7, dependency_id)
	rc, changed := step_changes(impl.conn.db, stmt)
	if rc != SQLITE_DONE || changed != 1 do return false, domain.domain_error(.Conflict, "dependency is absent, removed or removal is invalid")
	return true, domain.Domain_Error{}
}

@(private = "file")
mixed_work_prepare :: proc(impl: ^Taskchain_Repo_SQLite, query: string, what: string) -> (sqlite3_stmt, domain.Domain_Error) {
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, what)
	}
	return stmt, domain.Domain_Error{}
}

complete_work_chain_sqlite :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID, expected_revision: i64, summary, completed_at: string) -> (bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := mixed_work_prepare(impl, "UPDATE task_chains SET status='completed', completion_summary=?, completed_at=?, updated_at=?, work_revision=work_revision+1 WHERE chain_id=? AND owner_user_id=? AND status='active' AND publish_state='published' AND work_revision=?;", "complete work chain")
	if err.code != .None do return false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt,1,summary); bind_text(stmt,2,completed_at); bind_text(stmt,3,completed_at)
	bind_text(stmt,4,string(chain_id)); bind_text(stmt,5,string(owner)); sqlite3_bind_int64(stmt,6,expected_revision)
	rc, changed := step_changes(impl.conn.db,stmt)
	if rc != SQLITE_DONE || changed != 1 do return false, domain.domain_error(.Conflict,"work changed; refresh before finishing", `{"code":"work_changed"}`)
	return true, domain.Domain_Error{}
}
