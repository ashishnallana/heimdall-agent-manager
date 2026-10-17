package sqlite

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Push_Repo_SQLite :: struct {
	conn: ^Conn,
}

new_push_repository :: proc(impl: ^Push_Repo_SQLite, conn: ^Conn) -> iface.Push_Repository {
	impl.conn = conn
	return iface.Push_Repository{
		ctx = rawptr(impl),
		upsert_by_endpoint = push_upsert_by_endpoint_sqlite,
		list_by_owner = push_list_by_owner_sqlite,
		delete_by_endpoint = push_delete_by_endpoint_sqlite,
		delete_by_id = push_delete_by_id_sqlite,
	}
}

push_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Push_Subscription {
	sub: domain.Push_Subscription
	sub.id = domain.Push_Subscription_ID(column_text(stmt, 0))
	sub.owner_user_id = domain.User_ID(column_text(stmt, 1))
	sub.endpoint = column_text(stmt, 2)
	sub.p256dh = column_text(stmt, 3)
	sub.auth = column_text(stmt, 4)
	sub.created_at = column_text(stmt, 5)
	sub.updated_at = column_text(stmt, 6)
	return sub
}

// push_upsert_by_endpoint_sqlite inserts a subscription, or replaces the keys of
// the existing row with the same endpoint. The ON CONFLICT clause deliberately
// does NOT update owner_user_id — that column is immutable (enforced by a
// trigger); a re-subscribe by a different user simply rebinds the keys under the
// original owner. The persisted id (the pre-existing one on conflict) is read
// back so callers always learn the row's real id.
push_upsert_by_endpoint_sqlite :: proc(ctx: rawptr, sub: domain.Push_Subscription) -> (domain.Push_Subscription, bool, domain.Domain_Error) {
	impl := (^Push_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return domain.Push_Subscription{}, false, domain.domain_error(.Internal_Error, "sqlite push repository is not open")
	}

	stmt: sqlite3_stmt = nil
	query := `INSERT INTO push_subscriptions (
		id, owner_user_id, endpoint, p256dh, auth, created_at, updated_at
	) VALUES (?, ?, ?, ?, ?, ?, ?)
	ON CONFLICT(endpoint) DO UPDATE SET
		p256dh=excluded.p256dh,
		auth=excluded.auth,
		updated_at=excluded.updated_at;`
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return domain.Push_Subscription{}, false, domain.domain_error(.Internal_Error, "failed to prepare push subscription upsert")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(sub.id))
	bind_text(stmt, 2, string(sub.owner_user_id))
	bind_text(stmt, 3, sub.endpoint)
	bind_text(stmt, 4, sub.p256dh)
	bind_text(stmt, 5, sub.auth)
	bind_text(stmt, 6, sub.created_at)
	bind_text(stmt, 7, sub.updated_at)
	if sqlite3_step(stmt) != SQLITE_DONE {
		return domain.Push_Subscription{}, false, domain.domain_error(.Conflict, "push subscription could not be saved")
	}

	// Read back the persisted row so the returned id/owner reflect the stored
	// values (on conflict the id stays that of the pre-existing row).
	stored, found, err := push_get_by_endpoint_sqlite(impl, sub.endpoint)
	if err.code != .None {
		return domain.Push_Subscription{}, false, err
	}
	if !found {
		return domain.Push_Subscription{}, false, domain.domain_error(.Internal_Error, "push subscription vanished after upsert")
	}
	return stored, true, domain.Domain_Error{}
}

@(private = "file")
push_get_by_endpoint_sqlite :: proc(impl: ^Push_Repo_SQLite, endpoint: string) -> (domain.Push_Subscription, bool, domain.Domain_Error) {
	stmt: sqlite3_stmt = nil
	query := "SELECT id, owner_user_id, endpoint, p256dh, auth, created_at, updated_at FROM push_subscriptions WHERE endpoint = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return domain.Push_Subscription{}, false, domain.domain_error(.Internal_Error, "failed to prepare push subscription lookup")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, endpoint)
	if sqlite3_step(stmt) != SQLITE_ROW {
		return domain.Push_Subscription{}, false, domain.Domain_Error{}
	}
	return push_from_stmt(stmt), true, domain.Domain_Error{}
}

push_list_by_owner_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Push_Subscription, domain.Domain_Error) {
	impl := (^Push_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return nil, domain.domain_error(.Internal_Error, "sqlite push repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "SELECT id, owner_user_id, endpoint, p256dh, auth, created_at, updated_at FROM push_subscriptions WHERE owner_user_id = ? ORDER BY created_at ASC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare push subscription list")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner_user_id))

	items := make([dynamic]domain.Push_Subscription)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&items, push_from_stmt(stmt))
	}
	return items[:], domain.Domain_Error{}
}

// push_delete_by_endpoint_sqlite removes a subscription owned by owner_user_id.
// Scoping the delete to the owner prevents one user from unsubscribing another
// user's endpoint. It returns true when a row was actually removed.
push_delete_by_endpoint_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID, endpoint: string) -> (bool, domain.Domain_Error) {
	impl := (^Push_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "sqlite push repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "DELETE FROM push_subscriptions WHERE owner_user_id = ? AND endpoint = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return false, domain.domain_error(.Internal_Error, "failed to prepare push subscription delete")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner_user_id))
	bind_text(stmt, 2, endpoint)
	step_rc, row_changes := step_changes(impl.conn.db, stmt)
	if step_rc != SQLITE_DONE {
		return false, domain.domain_error(.Internal_Error, "failed to delete push subscription")
	}
	return row_changes > 0, domain.Domain_Error{}
}

// push_delete_by_id_sqlite removes a subscription by id. This is the pruning
// path used when a push endpoint reports 404/410 Gone (WP-SEND); it is not
// owner-scoped because the caller already resolved the row from a send failure.
push_delete_by_id_sqlite :: proc(ctx: rawptr, id: domain.Push_Subscription_ID) -> (bool, domain.Domain_Error) {
	impl := (^Push_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "sqlite push repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "DELETE FROM push_subscriptions WHERE id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return false, domain.domain_error(.Internal_Error, "failed to prepare push subscription delete by id")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(id))
	step_rc, row_changes := step_changes(impl.conn.db, stmt)
	if step_rc != SQLITE_DONE {
		return false, domain.domain_error(.Internal_Error, "failed to delete push subscription by id")
	}
	return row_changes > 0, domain.Domain_Error{}
}
