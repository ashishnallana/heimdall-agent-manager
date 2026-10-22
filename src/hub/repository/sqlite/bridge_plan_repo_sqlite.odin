package sqlite

import "core:slice"
import "core:sync"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// All plan mutations share the enrollment connection and SQLite write lock.
// Production never BEGINs a transaction on the shared request connection.
bridge_create_limited_sqlite :: proc(ctx: rawptr, bridge: domain.Bridge, max_bridges: int) -> (domain.Bridge, bool, domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	conn := impl.conn
	if impl.commit != nil {
		sync.mutex_lock(&impl.commit.mutex)
		defer sync.mutex_unlock(&impl.commit.mutex)
		return bridge_create_limited_on(&impl.commit.conn, bridge, max_bridges)
	}
	return bridge_create_limited_on(conn, bridge, max_bridges)
}

bridge_create_limited_on :: proc(conn: ^Conn, bridge: domain.Bridge, max_bridges: int) -> (domain.Bridge, bool, domain.Domain_Error) {
	if !exec(conn, "BEGIN IMMEDIATE;") do return {}, false, domain.domain_error(.Internal_Error, "failed to begin bridge approval")
	committed := false
	defer if !committed do _ = exec(conn, "ROLLBACK;")
	local := Bridge_Repo_SQLite{conn = conn}
	count, err := bridge_count_active_by_owner_sqlite(&local, bridge.owner_user_id)
	if err.code != .None do return {}, false, err
	if max_bridges >= 0 && count >= max_bridges do return {}, false, domain.plan_limit_error("max_bridges", max_bridges, count, "Current")
	saved, ok, save_err := bridge_save_bridge_sqlite(&local, bridge)
	if !ok do return {}, false, save_err
	if !exec(conn, "COMMIT;") do return {}, false, domain.domain_error(.Internal_Error, "failed to commit bridge approval")
	committed = true
	return saved, true, {}
}

bridge_count_active_by_owner_sqlite :: proc(ctx: rawptr, owner: domain.User_ID) -> (int, domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt
	query := "SELECT COUNT(*) FROM bridges WHERE owner_user_id = ? AND status != 'revoked' AND revoked_at = '';"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return 0, domain.domain_error(.Internal_Error, "failed to prepare bridge count")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner))
	if sqlite3_step(stmt) != SQLITE_ROW do return 0, domain.domain_error(.Internal_Error, "failed to count bridges")
	return int(sqlite3_column_int64(stmt, 0)), {}
}

bridge_list_owners_sqlite :: proc(ctx: rawptr) -> ([]string, domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt
	query := "SELECT DISTINCT owner_user_id FROM bridges ORDER BY owner_user_id;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare bridge owners")
	defer sqlite3_finalize(stmt)
	out := make([dynamic]string)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW {
			for owner in out do delete(owner)
			delete(out)
			return nil, domain.domain_error(.Internal_Error, "failed to list bridge owners")
		}
		append(&out, column_text(stmt, 0))
	}
	return out[:], {}
}

bridge_reconcile_plan_sqlite :: proc(ctx: rawptr, owner: domain.User_ID, max_bridges: int, now: string, before: iface.Bridge_Plan_Rank_Proc) -> domain.Domain_Error {
	impl := (^Bridge_Repo_SQLite)(ctx)
	if impl.commit != nil {
		sync.mutex_lock(&impl.commit.mutex)
		defer sync.mutex_unlock(&impl.commit.mutex)
		return bridge_reconcile_plan_on(&impl.commit.conn, owner, max_bridges, now, before)
	}
	return bridge_reconcile_plan_on(impl.conn, owner, max_bridges, now, before)
}

bridge_reconcile_plan_on :: proc(conn: ^Conn, owner: domain.User_ID, max_bridges: int, now: string, before: iface.Bridge_Plan_Rank_Proc) -> domain.Domain_Error {
	if !exec(conn, "BEGIN IMMEDIATE;") do return domain.domain_error(.Internal_Error, "failed to begin bridge plan reconciliation")
	committed := false
	defer if !committed do _ = exec(conn, "ROLLBACK;")
	// Read pending rows too; they reserve slots during approval.
	stmt: sqlite3_stmt
	query := "SELECT bridge_id, owner_user_id, label, label_is_user_customized, machine_hostname, machine_os, machine_arch, capabilities_json, hub_url, status, bridge_token_hash, created_at, updated_at, last_seen_at, revoked_at, version, commit_sha, build_timestamp, update_status, update_message, update_progress, update_error, telemetry_enabled, vault_status, enrollment_pending_until, plan_disabled_at FROM bridges WHERE owner_user_id = ? AND status != 'revoked' AND revoked_at = '';"
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.domain_error(.Internal_Error, "failed to prepare bridge reconciliation")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner))
	rows := make([dynamic]domain.Bridge)
	defer {
		for &row in rows do domain.bridge_destroy(&row)
		delete(rows)
	}
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW do return domain.domain_error(.Internal_Error, "failed to read bridge reconciliation rows")
		append(&rows, bridge_from_stmt(stmt))
	}
	slice.sort_by(rows[:], before)
	update: sqlite3_stmt
	update_sql := "UPDATE bridges SET plan_disabled_at = ? WHERE bridge_id = ?;"
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(update_sql)), -1, &update, nil) != SQLITE_OK do return domain.domain_error(.Internal_Error, "failed to prepare bridge suspension")
	defer sqlite3_finalize(update)
	for row, i in rows {
		disabled := max_bridges >= 0 && i >= max_bridges
		if disabled == (row.plan_disabled_at != "") do continue
		_ = sqlite3_reset(update)
		bind_text(update, 1, now if disabled else "")
		bind_text(update, 2, row.bridge_id)
		if sqlite3_step(update) != SQLITE_DONE do return domain.domain_error(.Internal_Error, "failed to update bridge suspension")
	}
	if !exec(conn, "COMMIT;") do return domain.domain_error(.Internal_Error, "failed to commit bridge plan reconciliation")
	committed = true
	return {}
}
