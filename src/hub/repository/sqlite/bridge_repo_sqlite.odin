package sqlite

import "core:c"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Bridge_Repo_SQLite :: struct {
	conn: ^Conn,
	// The enrollment commit's own connection (REQ-EA-2). nil only where there is no
	// second connection to have (an in-memory database); see bridge_commit_enrollment_sqlite.
	commit: ^Bridge_Enroll_Commit_Conn,
}

// Bridge_Enroll_Commit_Conn isolates the enrollment-commit transaction. `conn` is a
// SHARED connection: a BEGIN on it would let any other request's statement, executed
// on it before the COMMIT, join this transaction and be committed or rolled back with
// it. A dedicated connection gets SQLite's own isolation instead — BEGIN IMMEDIATE
// takes the database write lock, and other connections' writes wait on busy_timeout —
// and the mutex serializes commits that share this connection, as billing does.
Bridge_Enroll_Commit_Conn :: struct {
	conn:  Conn,
	mutex: sync.Mutex,
}

// open_bridge_enroll_commit_conn opens the dedicated connection on the hub database.
open_bridge_enroll_commit_conn :: proc(c: ^Bridge_Enroll_Commit_Conn, path: string) -> (bool, domain.Domain_Error) {
	conn, ok, err := open(path, .Enroll)
	if !ok do return false, err
	c.conn = conn
	if !exec(&c.conn, "PRAGMA busy_timeout = 5000;") {
		close(&c.conn)
		return false, domain.domain_error(.Internal_Error, "failed to configure the enrollment commit connection")
	}
	return true, domain.Domain_Error{}
}

new_bridge_repository :: proc(impl: ^Bridge_Repo_SQLite, conn: ^Conn) -> iface.Bridge_Repository {
	impl.conn = conn
	return iface.Bridge_Repository{
		ctx = rawptr(impl),
		save_bridge = bridge_save_bridge_sqlite,
		update_runtime = bridge_update_runtime_sqlite,
		create_limited = bridge_create_limited_sqlite,
		delete_pending_restoring_sunset = bridge_delete_pending_restoring_sunset_sqlite,
		count_active_by_owner = bridge_count_active_by_owner_sqlite,
		reconcile_plan = bridge_reconcile_plan_sqlite,
		list_owners = bridge_list_owners_sqlite,
		get_bridge = bridge_get_bridge_sqlite,
		list_by_owner = bridge_list_by_owner_sqlite,
		list_pending = bridge_list_pending_sqlite,
		delete_pending = bridge_delete_pending_sqlite,
		// REQ-IMPL-3: bridge_tokens lives in bridge_token_repo_sqlite.odin, same
		// package and same Bridge_Repo_SQLite ctx — one connection, one repository
		// seam, so a service holding a ^Bridge_Repository reaches both tables.
		save_token = bridge_save_token_sqlite,
		get_token = bridge_get_token_sqlite,
		credential_revocation = bridge_credential_revocation_sqlite,
		list_tokens_by_family = bridge_list_tokens_by_family_sqlite,
		revoke_token_family = bridge_revoke_token_family_sqlite,
		revoke_token_family_in_scope = bridge_revoke_token_family_in_scope_sqlite,
		revoke_tokens_for_bridge = bridge_revoke_tokens_for_bridge_sqlite,
		mark_token_rotated = bridge_mark_token_rotated_sqlite,
		mark_token_used = bridge_mark_token_used_sqlite,
		regrant_atomic = bridge_regrant_atomic_sqlite,
		commit_enrollment = bridge_commit_enrollment_sqlite,
		list_live_tokens_by_scope = bridge_list_live_tokens_by_scope_sqlite,
	}
}





bridge_save_bridge_sqlite :: proc(ctx: rawptr, bridge: domain.Bridge) -> (domain.Bridge, bool, domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "INSERT INTO bridges (bridge_id, owner_user_id, label, label_is_user_customized, machine_hostname, machine_os, machine_arch, capabilities_json, hub_url, status, bridge_token_hash, created_at, updated_at, last_seen_at, revoked_at, version, commit_sha, build_timestamp, update_status, update_message, update_progress, update_error, telemetry_enabled, vault_status, enrollment_pending_until, plan_disabled_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(bridge_id) DO UPDATE SET label=excluded.label, label_is_user_customized=excluded.label_is_user_customized, machine_hostname=excluded.machine_hostname, machine_os=excluded.machine_os, machine_arch=excluded.machine_arch, capabilities_json=excluded.capabilities_json, hub_url=excluded.hub_url, status=excluded.status, bridge_token_hash=excluded.bridge_token_hash, updated_at=excluded.updated_at, last_seen_at=excluded.last_seen_at, revoked_at=excluded.revoked_at, version=excluded.version, commit_sha=excluded.commit_sha, build_timestamp=excluded.build_timestamp, update_status=excluded.update_status, update_message=excluded.update_message, update_progress=excluded.update_progress, update_error=excluded.update_error, telemetry_enabled=excluded.telemetry_enabled, vault_status=excluded.vault_status, enrollment_pending_until=excluded.enrollment_pending_until;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Bridge{}, false, domain.domain_error(.Internal_Error, "failed to prepare bridge save")
	defer sqlite3_finalize(stmt)
	bind_bridge(stmt, bridge)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.Bridge{}, false, domain.domain_error(.Conflict, "bridge could not be saved")
	return bridge, true, domain.Domain_Error{}
}

// bridge_update_runtime_sqlite is the narrow runtime write (see iface.Bridge_Runtime_Write).
// Parameters: ?1 bridge_id, ?2 now, ?3 value, ?4 expected. Every statement touches only
// its own columns plus updated_at, and the WHERE clause carries the fence, so a revoked
// row is never resurrected and a concurrent writer's columns are never reverted.
bridge_update_runtime_sqlite :: proc(ctx: rawptr, kind: iface.Bridge_Runtime_Write, bridge_id, now, value, expected: string) -> (bool, domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	query: string
	switch kind {
	case .Liveness:
		query = "UPDATE bridges SET status = 'online', last_seen_at = ?2, updated_at = ?2 WHERE bridge_id = ?1 AND status != 'revoked';"
	case .Capabilities:
		query = "UPDATE bridges SET capabilities_json = ?3, updated_at = ?2 WHERE bridge_id = ?1 AND status != 'revoked' AND capabilities_json = ?4 AND capabilities_json != ?3;"
	case .Vault_Status:
		query = "UPDATE bridges SET vault_status = ?3, updated_at = ?2 WHERE bridge_id = ?1 AND status != 'revoked' AND vault_status != ?3;"
	case .Offline:
		query = "UPDATE bridges SET status = 'offline', updated_at = ?2 WHERE bridge_id = ?1 AND status = 'online';"
	}
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return false, domain.domain_error(.Internal_Error, "failed to prepare bridge runtime update")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, bridge_id)
	bind_text(stmt, 2, now)
	if kind == .Capabilities || kind == .Vault_Status do bind_text(stmt, 3, value)
	if kind == .Capabilities do bind_text(stmt, 4, expected)
	step_rc, row_changes := step_changes(impl.conn.db, stmt)
	if step_rc != SQLITE_DONE do return false, domain.domain_error(.Internal_Error, "bridge runtime update failed")
	return row_changes > 0, domain.Domain_Error{}
}

bridge_get_bridge_sqlite :: proc(ctx: rawptr, bridge_id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	return bridge_get_by_column(ctx, "bridge_id", bridge_id)
}


bridge_get_by_column :: proc(ctx: rawptr, column, value: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := fmt.tprintf("SELECT bridge_id, owner_user_id, label, label_is_user_customized, machine_hostname, machine_os, machine_arch, capabilities_json, hub_url, status, bridge_token_hash, created_at, updated_at, last_seen_at, revoked_at, version, commit_sha, build_timestamp, update_status, update_message, update_progress, update_error, telemetry_enabled, vault_status, enrollment_pending_until, plan_disabled_at FROM bridges WHERE %s = ?;", column)
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Bridge{}, false, domain.domain_error(.Internal_Error, "failed to prepare bridge lookup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, value)
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Bridge{}, false, domain.domain_error(.Not_Found, "bridge not found")
	return bridge_from_stmt(stmt), true, domain.Domain_Error{}
}

// bridge_list_by_owner_sqlite lists an owner's ENROLLED bridges only. A pending
// enrollment (REQ-EA-1) is excluded here, at the source, because callers pick from
// this list without asking — taskchain promotion takes the most recently updated
// bridge as a default — and a pending bridge is the most recently updated of all.
// The one view that shows pending rows (GET /bridges, as "Enrolling…") asks for
// them separately with list_pending.
bridge_list_by_owner_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Bridge, domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT bridge_id, owner_user_id, label, label_is_user_customized, machine_hostname, machine_os, machine_arch, capabilities_json, hub_url, status, bridge_token_hash, created_at, updated_at, last_seen_at, revoked_at, version, commit_sha, build_timestamp, update_status, update_message, update_progress, update_error, telemetry_enabled, vault_status, enrollment_pending_until, plan_disabled_at FROM bridges WHERE owner_user_id = ? AND enrollment_pending_until = '' ORDER BY updated_at DESC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare bridge list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner_user_id))
	out := make([dynamic]domain.Bridge)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, bridge_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

// bridge_list_pending_sqlite returns every bridge still awaiting its vault key
// (REQ-EA-3). The deadline is compared by the caller after parsing, not here as a
// string, so the sweep does not depend on every writer using one timestamp format.
bridge_list_pending_sqlite :: proc(ctx: rawptr) -> ([]domain.Bridge, domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT bridge_id, owner_user_id, label, label_is_user_customized, machine_hostname, machine_os, machine_arch, capabilities_json, hub_url, status, bridge_token_hash, created_at, updated_at, last_seen_at, revoked_at, version, commit_sha, build_timestamp, update_status, update_message, update_progress, update_error, telemetry_enabled, vault_status, enrollment_pending_until, plan_disabled_at FROM bridges WHERE enrollment_pending_until != '';"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare pending bridge list")
	defer sqlite3_finalize(stmt)
	out := make([dynamic]domain.Bridge)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, bridge_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

// bridge_delete_pending_sqlite HARD-deletes a bridge row, and only one that is still
// pending (REQ-EA-3). The enrollment_pending_until guard is in the statement itself so
// no caller can reach an enrolled bridge through this path: revocation of an enrolled
// bridge stays the soft revoke_bridge, which keeps the row for audit.
bridge_delete_pending_sqlite :: proc(ctx: rawptr, bridge_id: string) -> (bool, domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "DELETE FROM bridges WHERE bridge_id = ? AND enrollment_pending_until != '';"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return false, domain.domain_error(.Internal_Error, "failed to prepare pending bridge delete")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, bridge_id)
	step_rc, row_changes := step_changes(impl.conn.db, stmt)
	if step_rc != SQLITE_DONE do return false, domain.domain_error(.Internal_Error, "failed to delete pending bridge")
	return row_changes > 0, domain.Domain_Error{}
}

bind_bridge :: proc(stmt: sqlite3_stmt, bridge: domain.Bridge) {
	bind_text(stmt, 1, bridge.bridge_id)
	bind_text(stmt, 2, string(bridge.owner_user_id))
	bind_text(stmt, 3, bridge.label)
	bind_text(stmt, 4, "1" if bridge.label_is_user_customized else "0")
	bind_text(stmt, 5, bridge.machine_hostname)
	bind_text(stmt, 6, bridge.machine_os)
	bind_text(stmt, 7, bridge.machine_arch)
	bind_text(stmt, 8, bridge.capabilities_json)
	bind_text(stmt, 9, bridge.hub_url)
	bind_text(stmt, 10, domain.bridge_status_string(bridge.status))
	bind_text(stmt, 11, bridge.bridge_token_hash)
	bind_text(stmt, 12, bridge.created_at)
	bind_text(stmt, 13, bridge.updated_at)
	bind_text(stmt, 14, bridge.last_seen_at)
	bind_text(stmt, 15, bridge.revoked_at)
	bind_text(stmt, 16, bridge.version)
	bind_text(stmt, 17, bridge.commit_sha)
	bind_text(stmt, 18, bridge.build_timestamp)
	bind_text(stmt, 19, bridge.update_status if bridge.update_status != "" else "idle")
	bind_text(stmt, 20, bridge.update_message)
	sqlite3_bind_int(stmt, 21, c.int(bridge.update_progress))
	bind_text(stmt, 22, bridge.update_error)
	bind_text(stmt, 23, bridge.telemetry_enabled if bridge.telemetry_enabled != "" else "inherit")
	// No "" -> default substitution here, unlike telemetry_enabled above: "" IS the
	// meaningful value for a bridge that has never reported (REQ-BVS-2).
	bind_text(stmt, 24, bridge.vault_status)
	bind_text(stmt, 25, bridge.enrollment_pending_until)
	bind_text(stmt, 26, bridge.plan_disabled_at)
}


bridge_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Bridge {
	te := column_text(stmt, 22)
	if len(te) == 0 do te = strings.clone("inherit")
	update_progress := 0
	if parsed, ok := strconv.parse_int(column_text_unowned(stmt, 20)); ok do update_progress = int(parsed)
	return domain.Bridge{
		bridge_id = column_text(stmt, 0),
		owner_user_id = domain.User_ID(column_text(stmt, 1)),
		label = column_text(stmt, 2),
		label_is_user_customized = column_text_unowned(stmt, 3) == "1",
		machine_hostname = column_text(stmt, 4),
		machine_os = column_text(stmt, 5),
		machine_arch = column_text(stmt, 6),
		capabilities_json = column_text(stmt, 7),
		hub_url = column_text(stmt, 8),
		status = bridge_status_from_string(column_text_unowned(stmt, 9)),
		bridge_token_hash = column_text(stmt, 10),
		created_at = column_text(stmt, 11),
		updated_at = column_text(stmt, 12),
		last_seen_at = column_text(stmt, 13),
		revoked_at = column_text(stmt, 14),
		version = column_text(stmt, 15),
		commit_sha = column_text(stmt, 16),
		build_timestamp = column_text(stmt, 17),
		update_status = column_text(stmt, 18),
		update_message = column_text(stmt, 19),
		update_progress = update_progress,
		update_error = column_text(stmt, 21),
		telemetry_enabled = te,
		vault_status = column_text(stmt, 23),
		enrollment_pending_until = column_text(stmt, 24),
		plan_disabled_at = column_text(stmt, 25),
	}
}

bridge_status_from_string :: proc(status: string) -> domain.Bridge_Status {
	if status == "online" do return .Online
	if status == "revoked" do return .Revoked
	return .Offline
}
