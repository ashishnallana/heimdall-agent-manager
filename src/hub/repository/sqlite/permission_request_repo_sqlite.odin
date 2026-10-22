package sqlite

import "core:c"
import "core:strings"
import domain "odin_test:hub/domain"

// Permission relay storage (REQ-EXT-PERM-1). Transitions are compare-and-set on
// status = 'pending' (step_changes), so a user decision racing a timeout or an
// instance stop closes the row exactly once.

PERMISSION_REQUESTS_LIST_DEFAULT :: 100
PERMISSION_REQUESTS_LIST_MAX :: 500

@(private = "file")
PERM_COLUMNS :: "id, owner_user_id, instance_id, chain_id, agent_id, provider, tool_name, tool_use_id, input, suggestions, status, decided_by, message, created_at, expires_at, decided_at"

@(private = "file")
perm_db :: proc(ctx: rawptr) -> (sqlite3, bool) {
	impl := (^Agent_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil do return nil, false
	return impl.conn.db, true
}

@(private = "file")
perm_not_open :: proc() -> domain.Domain_Error {
	return domain.domain_error(.Internal_Error, "sqlite repository is not open")
}

@(private = "file")
perm_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Permission_Request {
	return domain.Permission_Request{
		id            = column_text(stmt, 0),
		owner_user_id = domain.User_ID(column_text(stmt, 1)),
		instance_id   = column_text(stmt, 2),
		chain_id      = column_text(stmt, 3),
		agent_id      = column_text(stmt, 4),
		provider      = column_text(stmt, 5),
		tool_name     = column_text(stmt, 6),
		tool_use_id   = column_text(stmt, 7),
		input         = column_text(stmt, 8),
		suggestions   = column_text(stmt, 9),
		status        = column_text(stmt, 10),
		decided_by    = column_text(stmt, 11),
		message       = column_text(stmt, 12),
		created_at    = column_text(stmt, 13),
		expires_at    = column_text(stmt, 14),
		decided_at    = column_text(stmt, 15),
	}
}

agent_perm_insert_sqlite :: proc(ctx: rawptr, req: domain.Permission_Request) -> domain.Domain_Error {
	db, ok := perm_db(ctx)
	if !ok do return perm_not_open()
	if strings.trim_space(req.id) == "" || strings.trim_space(req.instance_id) == "" do return domain.domain_error(.Validation_Failed, "permission request id and instance_id are required")
	query := "INSERT INTO permission_requests (" + PERM_COLUMNS + ") VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);"
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(db, cstring(raw_data(query)), c.int(len(query)), &stmt, nil) != SQLITE_OK do return domain.domain_error(.Internal_Error, "failed to prepare permission request insert")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, req.id)
	bind_text(stmt, 2, string(req.owner_user_id))
	bind_text(stmt, 3, req.instance_id)
	bind_text(stmt, 4, req.chain_id)
	bind_text(stmt, 5, req.agent_id)
	bind_text(stmt, 6, req.provider)
	bind_text(stmt, 7, req.tool_name)
	bind_text(stmt, 8, req.tool_use_id)
	bind_text(stmt, 9, "{}" if req.input == "" else req.input)
	bind_text(stmt, 10, "[]" if req.suggestions == "" else req.suggestions)
	bind_text(stmt, 11, "pending" if req.status == "" else req.status)
	bind_text(stmt, 12, req.decided_by)
	bind_text(stmt, 13, req.message)
	bind_text(stmt, 14, req.created_at)
	bind_text(stmt, 15, req.expires_at)
	bind_text(stmt, 16, req.decided_at)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.domain_error(.Conflict, "permission request already exists or could not be saved")
	return {}
}

agent_perm_get_sqlite :: proc(ctx: rawptr, id: string) -> (domain.Permission_Request, bool, domain.Domain_Error) {
	db, ok := perm_db(ctx)
	if !ok do return {}, false, perm_not_open()
	query := "SELECT " + PERM_COLUMNS + " FROM permission_requests WHERE id = ?;"
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(db, cstring(raw_data(query)), c.int(len(query)), &stmt, nil) != SQLITE_OK do return {}, false, domain.domain_error(.Internal_Error, "failed to prepare permission request lookup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, id)
	if sqlite3_step(stmt) != SQLITE_ROW do return {}, false, domain.domain_error(.Not_Found, "permission request not found")
	return perm_from_stmt(stmt), true, {}
}

agent_perm_list_sqlite :: proc(ctx: rawptr, filter: domain.Permission_Request_Filter) -> ([]domain.Permission_Request, domain.Domain_Error) {
	db, ok := perm_db(ctx)
	if !ok do return nil, perm_not_open()
	if filter.owner_user_id == "" && filter.instance_id == "" do return nil, domain.domain_error(.Validation_Failed, "owner or instance filter is required")
	limit := filter.limit
	if limit <= 0 do limit = PERMISSION_REQUESTS_LIST_DEFAULT
	if limit > PERMISSION_REQUESTS_LIST_MAX do limit = PERMISSION_REQUESTS_LIST_MAX
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "SELECT " + PERM_COLUMNS + " FROM permission_requests WHERE 1=1")
	if filter.owner_user_id != "" do strings.write_string(&b, " AND owner_user_id = ?")
	if filter.instance_id != "" do strings.write_string(&b, " AND instance_id = ?")
	if filter.chain_id != "" do strings.write_string(&b, " AND chain_id = ?")
	if filter.status != "" do strings.write_string(&b, " AND status = ?")
	strings.write_string(&b, " ORDER BY created_at DESC, id DESC LIMIT ?;")
	query := strings.to_string(b)
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(db, cstring(raw_data(query)), c.int(len(query)), &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare permission request list")
	defer sqlite3_finalize(stmt)
	n := 1
	if filter.owner_user_id != "" { bind_text(stmt, n, string(filter.owner_user_id)); n += 1 }
	if filter.instance_id != "" { bind_text(stmt, n, filter.instance_id); n += 1 }
	if filter.chain_id != "" { bind_text(stmt, n, filter.chain_id); n += 1 }
	if filter.status != "" { bind_text(stmt, n, filter.status); n += 1 }
	sqlite3_bind_int64(stmt, c.int(n), i64(limit))
	out := make([dynamic]domain.Permission_Request)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, perm_from_stmt(stmt))
	return out[:], {}
}

agent_perm_close_sqlite :: proc(ctx: rawptr, id, status, decided_by, message, decided_at: string) -> (bool, domain.Domain_Error) {
	db, ok := perm_db(ctx)
	if !ok do return false, perm_not_open()
	query := "UPDATE permission_requests SET status = ?, decided_by = ?, message = ?, decided_at = ? WHERE id = ? AND status = 'pending';"
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(db, cstring(raw_data(query)), c.int(len(query)), &stmt, nil) != SQLITE_OK do return false, domain.domain_error(.Internal_Error, "failed to prepare permission request update")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, status)
	bind_text(stmt, 2, decided_by)
	bind_text(stmt, 3, message)
	bind_text(stmt, 4, decided_at)
	bind_text(stmt, 5, id)
	rc, changes := step_changes(db, stmt)
	if rc != SQLITE_DONE do return false, domain.domain_error(.Internal_Error, "permission request update failed")
	return changes > 0, {}
}

agent_perm_close_pending_sqlite :: proc(ctx: rawptr, instance_id, expired_by, status, decided_at: string) -> ([]domain.Permission_Request, domain.Domain_Error) {
	db, ok := perm_db(ctx)
	if !ok do return nil, perm_not_open()
	if instance_id == "" && expired_by == "" do return nil, domain.domain_error(.Validation_Failed, "instance_id or expired_by is required")
	query := "SELECT " + PERM_COLUMNS + " FROM permission_requests WHERE status = 'pending' AND instance_id = ?;"
	if instance_id == "" do query = "SELECT " + PERM_COLUMNS + " FROM permission_requests WHERE status = 'pending' AND expires_at != '' AND expires_at <= ?;"
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(db, cstring(raw_data(query)), c.int(len(query)), &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare pending permission request scan")
	candidates := make([dynamic]domain.Permission_Request, context.temp_allocator)
	bind_text(stmt, 1, instance_id if instance_id != "" else expired_by)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&candidates, perm_from_stmt(stmt))
	sqlite3_finalize(stmt)

	// Close each through the CAS so a concurrent decision wins cleanly: rows that
	// were decided between the scan and the update are not reported as closed.
	closed := make([dynamic]domain.Permission_Request)
	for req in candidates {
		changed, err := agent_perm_close_sqlite(ctx, req.id, status, "", "", decided_at)
		if err.code != .None do return closed[:], err
		if !changed do continue
		r := req
		r.status = status
		r.decided_at = decided_at
		append(&closed, r)
	}
	return closed[:], {}
}
