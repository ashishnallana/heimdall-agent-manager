package sqlite

import "core:slice"
import "core:sync"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// All plan mutations share the enrollment connection and SQLite write lock.
// Production never BEGINs a transaction on the shared request connection.
bridge_create_limited_sqlite :: proc(ctx: rawptr, bridge: domain.Bridge, max_bridges: int, sunset: iface.Bridge_Sunset) -> (domain.Bridge, bool, domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	conn := impl.conn
	if impl.commit != nil {
		sync.mutex_lock(&impl.commit.mutex)
		defer sync.mutex_unlock(&impl.commit.mutex)
		return bridge_create_limited_on(&impl.commit.conn, bridge, max_bridges, sunset)
	}
	return bridge_create_limited_on(conn, bridge, max_bridges, sunset)
}

// bridge_create_limited_on is the admission transaction. With a sunset it is the
// whole "replace one of my bridges" step: retire the sunset bridge (credentials, then
// row, same order as revoke_bridge) and, for a pending replacement, write its durable
// receipt; count; insert — all under one BEGIN IMMEDIATE, so a failure at any point
// (sunset refused, plan still full, insert failed, COMMIT failed) leaves the sunset
// bridge exactly as it was and no receipt behind.
bridge_create_limited_on :: proc(conn: ^Conn, bridge: domain.Bridge, max_bridges: int, sunset: iface.Bridge_Sunset) -> (domain.Bridge, bool, domain.Domain_Error) {
	if !exec(conn, "BEGIN IMMEDIATE;") do return {}, false, domain.domain_error(.Internal_Error, "failed to begin bridge approval")
	committed := false
	defer if !committed do _ = exec(conn, "ROLLBACK;")
	local := Bridge_Repo_SQLite{conn = conn}
	if sunset.bridge_id != "" {
		// The receipt is keyed by the replacement, so only a pending one (which has
		// rollback paths) gets one; a non-pending replacement makes the sunset final.
		receipt_for := bridge.bridge_id if bridge.enrollment_pending_until != "" else ""
		sunset_err := bridge_sunset_on(conn, bridge.owner_user_id, sunset, receipt_for)
		if sunset_err.code != .None do return {}, false, sunset_err
	}
	count, err := bridge_count_active_by_owner_sqlite(&local, bridge.owner_user_id)
	if err.code != .None do return {}, false, err
	if max_bridges >= 0 && count >= max_bridges do return {}, false, domain.plan_limit_error("max_bridges", max_bridges, count, "Current")
	saved, ok, save_err := bridge_save_bridge_sqlite(&local, bridge)
	if !ok do return {}, false, save_err
	if bridge_create_limited_test_hook != nil && !bridge_create_limited_test_hook(bridge.bridge_id) {
		return {}, false, domain.domain_error(.Internal_Error, "failed to commit bridge approval")
	}
	if !exec(conn, "COMMIT;") do return {}, false, domain.domain_error(.Internal_Error, "failed to commit bridge approval")
	committed = true
	return saved, true, {}
}

// bridge_create_limited_test_hook runs inside the admission transaction after the
// insert and before COMMIT; returning false fails the transaction as a failed COMMIT
// would. It receives the bridge being created so a test can fail only its own
// approval while other tests run concurrently. Tests only — nil in production.
bridge_create_limited_test_hook: proc(bridge_id: string) -> bool

// sunset_exec runs one parameterised write and reports the rows it changed.
@(private = "package")
sunset_exec :: proc(conn: ^Conn, sql: string, args: ..string) -> (ok: bool, changes: int) {
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(sql)), -1, &stmt, nil) != SQLITE_OK do return false, 0
	defer sqlite3_finalize(stmt)
	for a, i in args do bind_text(stmt, i + 1, a)
	rc, n := step_changes(conn.db, stmt)
	return rc == SQLITE_DONE, n
}

// bridge_sunset_on retires the sunset bridge inside the caller's transaction and, when
// receipt_for names the pending replacement, records the receipt (migration 178):
// the bridge, the revoked_at stamped, and the ids of exactly the tokens this revoked.
// Refusals: absent, owned by someone else, or already revoked -> .Not_Found with the
// same text (revoke_bridge's anti-enumeration shape); the owner's own still-pending
// enrollment -> .Validation_Failed (it is not a bridge yet; cancel it instead, and it
// would otherwise be deleted by the sweep under us).
@(private = "file")
bridge_sunset_on :: proc(conn: ^Conn, owner: domain.User_ID, sunset: iface.Bridge_Sunset, receipt_for: string) -> domain.Domain_Error {
	local := Bridge_Repo_SQLite{conn = conn}
	current, found, _ := bridge_get_bridge_sqlite(&local, sunset.bridge_id)
	defer if found do domain.bridge_destroy(&current)
	not_found := domain.domain_error(.Not_Found, "resource not found")
	if !found || current.owner_user_id != owner do return not_found
	if current.status == .Revoked || current.revoked_at != "" do return not_found
	if current.enrollment_pending_until != "" {
		return domain.domain_error(.Validation_Failed, "a bridge that is still enrolling cannot be sunset; cancel its enrollment instead")
	}
	if receipt_for != "" {
		// Recorded BEFORE the revoke, so "live now" is exactly "revoked by this sunset".
		if ok, _ := sunset_exec(conn, "INSERT INTO bridge_sunset_receipts (replacement_bridge_id, sunset_bridge_id, revoked_at) VALUES (?1, ?2, ?3);", receipt_for, sunset.bridge_id, sunset.revoked_at); !ok {
			return domain.domain_error(.Internal_Error, "failed to record bridge sunset")
		}
		if ok, _ := sunset_exec(conn, "INSERT INTO bridge_sunset_receipt_tokens (replacement_bridge_id, token_id) SELECT ?1, token_id FROM bridge_tokens WHERE bridge_id = ?2 AND revoked_at = '';", receipt_for, sunset.bridge_id); !ok {
			return domain.domain_error(.Internal_Error, "failed to record bridge sunset credentials")
		}
	}
	if _, revoke_ok, revoke_err := bridge_revoke_tokens_for_bridge_on(conn, sunset.bridge_id, sunset.revoked_at); !revoke_ok do return revoke_err
	ok, changed := sunset_exec(conn, "UPDATE bridges SET status = 'revoked', revoked_at = ?2, updated_at = ?2 WHERE bridge_id = ?1 AND status != 'revoked' AND revoked_at = '' AND enrollment_pending_until = '';", sunset.bridge_id, sunset.revoked_at)
	if !ok do return domain.domain_error(.Internal_Error, "failed to sunset bridge")
	// The read above was under the same write lock, so this cannot miss; checked
	// anyway so a schema or guard drift fails closed instead of reporting a sunset
	// that did not happen.
	if changed != 1 do return domain.domain_error(.Internal_Error, "bridge sunset did not apply")
	return {}
}

// bridge_drop_sunset_receipt deletes a replacement's receipt inside the caller's
// transaction. Used by the rollback below and by the enrollment commit, which is the
// moment a sunset becomes final.
bridge_drop_sunset_receipt :: proc(conn: ^Conn, replacement_bridge_id: string) -> bool {
	ok_tokens, _ := sunset_exec(conn, "DELETE FROM bridge_sunset_receipt_tokens WHERE replacement_bridge_id = ?1;", replacement_bridge_id)
	ok_row, _ := sunset_exec(conn, "DELETE FROM bridge_sunset_receipts WHERE replacement_bridge_id = ?1;", replacement_bridge_id)
	return ok_tokens && ok_row
}

bridge_delete_pending_restoring_sunset_sqlite :: proc(ctx: rawptr, bridge_id: string, max_bridges: int, restore_allowed: bool, now: string) -> (iface.Sunset_Rollback_Outcome, domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	if impl.commit != nil {
		sync.mutex_lock(&impl.commit.mutex)
		defer sync.mutex_unlock(&impl.commit.mutex)
		return bridge_delete_pending_restoring_sunset_on(&impl.commit.conn, bridge_id, max_bridges, restore_allowed, now)
	}
	return bridge_delete_pending_restoring_sunset_on(impl.conn, bridge_id, max_bridges, restore_allowed, now)
}

// bridge_delete_pending_restoring_sunset_on: see iface.Bridge_Delete_Pending_Restoring_Sunset_Proc.
// Any error rolls the whole transaction back: the pending row, the sunset bridge and
// the receipt are then exactly as before, and the next rollback (the sweep) retries.
bridge_delete_pending_restoring_sunset_on :: proc(conn: ^Conn, bridge_id: string, max_bridges: int, restore_allowed: bool, now: string) -> (out: iface.Sunset_Rollback_Outcome, err: domain.Domain_Error) {
	if bridge_id == "" do return {}, domain.domain_error(.Validation_Failed, "bridge_id is required")
	if !exec(conn, "BEGIN IMMEDIATE;") do return {}, domain.domain_error(.Internal_Error, "failed to begin pending bridge rollback")
	committed := false
	defer if !committed do _ = exec(conn, "ROLLBACK;")
	local := Bridge_Repo_SQLite{conn = conn}

	sunset_bridge_id, revoked_at: string
	{
		sel: sqlite3_stmt
		sel_sql := "SELECT sunset_bridge_id, revoked_at FROM bridge_sunset_receipts WHERE replacement_bridge_id = ?;"
		if sqlite3_prepare_v2(conn.db, cstring(raw_data(sel_sql)), -1, &sel, nil) != SQLITE_OK do return {}, domain.domain_error(.Internal_Error, "failed to prepare sunset receipt lookup")
		defer sqlite3_finalize(sel)
		bind_text(sel, 1, bridge_id)
		switch sqlite3_step(sel) {
		case SQLITE_ROW:
			out.had_sunset = true
			sunset_bridge_id = column_text(sel, 0)
			revoked_at = column_text(sel, 1)
		case SQLITE_DONE:
		case:
			return {}, domain.domain_error(.Internal_Error, "failed to read sunset receipt")
		}
	}
	defer delete(sunset_bridge_id)
	defer delete(revoked_at)

	deleted, del_err := bridge_delete_pending_sqlite(&local, bridge_id)
	if del_err.code != .None do return {}, del_err
	out.replacement_deleted = deleted

	if out.had_sunset {
		restore := restore_allowed
		// A replacement row that is still here is not pending (delete_pending would
		// have removed it): it committed and owns the slot. Reviving the sunset bridge
		// too would be two live bridges where the owner approved one.
		if still, found, _ := bridge_get_bridge_sqlite(&local, bridge_id); found {
			domain.bridge_destroy(&still)
			restore = false
		}
		if restore {
			current, found, _ := bridge_get_bridge_sqlite(&local, sunset_bridge_id)
			if !found {
				restore = false
			} else {
				// Explicit bridge revocation consumes this receipt in its write
				// transaction; timestamp equality alone is not a generation guard.
				restore = current.status == .Revoked && current.revoked_at == revoked_at
				if restore && max_bridges >= 0 {
					count, count_err := bridge_count_active_by_owner_sqlite(&local, current.owner_user_id)
					if count_err.code != .None {
						domain.bridge_destroy(&current)
						return {}, count_err
					}
					// The freed slot was taken by another approval meanwhile.
					if count >= max_bridges do restore = false
				}
				domain.bridge_destroy(&current)
			}
		}
		if restore {
			ok, changed := sunset_exec(conn, "UPDATE bridges SET status = 'offline', revoked_at = '', updated_at = ?3 WHERE bridge_id = ?1 AND status = 'revoked' AND revoked_at = ?2;", sunset_bridge_id, revoked_at, now)
			if !ok || changed != 1 do return {}, domain.domain_error(.Internal_Error, "failed to restore sunset bridge")
			// Exactly the receipt's tokens, and only while they still carry the sunset's
			// revoked_at (a later revoke of one of them stamps its own time).
			if ok_tok, _ := sunset_exec(conn, "UPDATE bridge_tokens SET revoked_at = '' WHERE bridge_id = ?2 AND revoked_at = ?3 AND token_id IN (SELECT token_id FROM bridge_sunset_receipt_tokens WHERE replacement_bridge_id = ?1);", bridge_id, sunset_bridge_id, revoked_at); !ok_tok {
				return {}, domain.domain_error(.Internal_Error, "failed to restore sunset bridge credentials")
			}
			out.restored = true
		}
		// Consumed whatever the guards decided: a sunset is restored at most once.
		if !bridge_drop_sunset_receipt(conn, bridge_id) do return {}, domain.domain_error(.Internal_Error, "failed to drop sunset receipt")
	}
	if !exec(conn, "COMMIT;") do return {}, domain.domain_error(.Internal_Error, "failed to commit pending bridge rollback")
	committed = true
	return out, {}
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

// Snapshot of token, bridge and receipt. A caller must verify the secret before
// exposing Pending_Sunset. Query errors are retriable, never terminal revocation.
bridge_credential_revocation_sqlite :: proc(ctx: rawptr, token_id: string) -> (iface.Credential_Revocation, domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt
	query := "SELECT CASE WHEN t.revoked_at = '' AND b.status != 'revoked' AND b.revoked_at = '' THEN 0 WHEN EXISTS (SELECT 1 FROM bridge_sunset_receipts r JOIN bridge_sunset_receipt_tokens rt ON rt.replacement_bridge_id = r.replacement_bridge_id WHERE rt.token_id = t.token_id AND r.sunset_bridge_id = b.bridge_id AND r.revoked_at = t.revoked_at AND r.revoked_at = b.revoked_at) THEN 1 ELSE 2 END FROM bridge_tokens t JOIN bridges b ON b.bridge_id = t.bridge_id WHERE t.token_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return .Final, domain.domain_error(.Internal_Error, "failed to read bridge credential revocation")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, token_id)
	switch sqlite3_step(stmt) {
	case SQLITE_ROW:
		return iface.Credential_Revocation(sqlite3_column_int64(stmt, 0)), {}
	case SQLITE_DONE:
		return .Final, {}
	case:
		return .Final, domain.domain_error(.Internal_Error, "failed to read bridge credential revocation")
	}
}
