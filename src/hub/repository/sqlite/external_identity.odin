package sqlite

import "core:sync"
import domain "odin_test:hub/domain"

OIDC_UNLINKED_EXISTING_USER_MESSAGE :: "this sign-in is not linked to a Heimdall user; ask the operator to link it (ham-hub users link-oidc)"
OIDC_UNKNOWN_USER_MESSAGE :: "no Heimdall user exists for this sign-in and provisioning is disabled; ask the operator to create or link one"

// external_identity_lookup is the hot path: a plain read with no write lock.
@(private = "file")
external_identity_lookup :: proc(conn: ^Conn, issuer, subject: string) -> (string, bool) {
	stmt: sqlite3_stmt
	query := "SELECT user_id FROM user_external_identities WHERE issuer=? AND subject=?;"
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return "", false
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, issuer); bind_text(stmt, 2, subject)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_ROW do return column_text(stmt, 0), true
	return "", rc == SQLITE_DONE
}

@(private = "file")
external_identity_linked_user :: proc(conn: ^Conn, linked_id: string) -> (domain.User, bool, domain.Domain_Error) {
	repo := User_Repo_SQLite{conn = conn}
	user, ok, err := user_get_by_id_sqlite(rawptr(&repo), domain.User_ID(linked_id))
	if !ok do return {}, false, err
	if user.status != .Active do return {}, false, domain.domain_error(.Forbidden, "user is disabled")
	return user, true, {}
}

// Resolve (issuer, subject) to a Hub user. An existing link is a plain read.
// Only creating the FIRST link takes a write transaction, which prevents two
// concurrent first logins from claiming the same user. Policy for an unlinked
// subject:
//   - a user whose name/user_id equals the normalized preferred_username exists:
//     claimed only when claim_existing is set; otherwise 403 (operator links it
//     with `ham-hub users link-oidc`). Email never participates.
//   - no such user: provisioned only when provision is set; otherwise 403.
// A second subject can never claim an already linked user.
user_resolve_external_sqlite :: proc(
	ctx: rawptr,
	issuer, subject, username, display_name, email, now: string,
	provision, claim_existing: bool,
) -> (
	domain.User,
	bool,
	domain.Domain_Error,
) {
	impl := (^User_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil do return {}, false, domain.domain_error(.Internal_Error, "identity repository unavailable")
	if linked, read_ok := external_identity_lookup(impl.conn, issuer, subject); read_ok && linked != "" {
		return external_identity_linked_user(impl.conn, linked)
	}
	sync.mutex_lock(&impl.identity_mutex)
	defer sync.mutex_unlock(&impl.identity_mutex)
	conn := impl.conn
	if impl.identity_conn != nil do conn = impl.identity_conn
	transaction_repo := User_Repo_SQLite {
		conn = conn,
	}
	if !exec(conn, "BEGIN IMMEDIATE;") do return {}, false, domain.domain_error(.Internal_Error, "identity transaction failed")
	committed := false
	defer {if !committed {_ = exec(conn, "ROLLBACK;")}}
	stmt: sqlite3_stmt
	query := "SELECT user_id FROM user_external_identities WHERE issuer=? AND subject=?;"
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return {}, false, domain.domain_error(.Internal_Error, "identity lookup failed")
	bind_text(stmt, 1, issuer); bind_text(stmt, 2, subject)
	linked_id := ""
	if sqlite3_step(stmt) == SQLITE_ROW do linked_id = column_text(stmt, 0)
	sqlite3_finalize(stmt)
	if linked_id != "" {
		// Linked concurrently between the read and the write lock.
		user, ok, err := external_identity_linked_user(conn, linked_id)
		if !ok do return {}, false, err
		if !exec(conn, "COMMIT;") do return {}, false, domain.domain_error(.Internal_Error, "identity commit failed")
		committed = true
		return user, true, {}
	}
	if username == "" do return {}, false, domain.domain_error(.Unauthenticated, "preferred_username is required for first login")
	query = "SELECT user_id, name, display_name, email, status, created_at, updated_at FROM users WHERE name = ? COLLATE NOCASE OR user_id = ? COLLATE NOCASE;"
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return {}, false, domain.domain_error(.Internal_Error, "username lookup failed")
	bind_text(stmt, 1, username); bind_text(stmt, 2, username)
	user: domain.User
	count := 0
	for sqlite3_step(stmt) == SQLITE_ROW {user = user_from_stmt(stmt); count += 1}
	sqlite3_finalize(stmt)
	if count > 1 do return {}, false, domain.domain_error(.Conflict, "ambiguous legacy username")
	if count == 1 && !claim_existing do return {}, false, domain.domain_error(.Forbidden, OIDC_UNLINKED_EXISTING_USER_MESSAGE)
	if count == 0 {
		if !provision do return {}, false, domain.domain_error(.Forbidden, OIDC_UNKNOWN_USER_MESSAGE)
		user = domain.User {
			user_id      = domain.User_ID(username),
			name         = username,
			display_name = display_name,
			email        = email,
			status       = .Active,
			created_at   = now,
			updated_at   = now,
		}
		if saved, ok, err := user_save_sqlite(rawptr(&transaction_repo), user);
		   !ok {return {}, false, err} else {user = saved}
	}
	if user.status != .Active do return {}, false, domain.domain_error(.Forbidden, "user is disabled")
	query = "INSERT INTO user_external_identities(issuer,subject,user_id,created_at) VALUES(?,?,?,?);"
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return {}, false, domain.domain_error(.Internal_Error, "identity insert failed")
	bind_text(
		stmt,
		1,
		issuer,
	); bind_text(stmt, 2, subject); bind_text(stmt, 3, string(user.user_id)); bind_text(stmt, 4, now)
	result := sqlite3_step(stmt)
	sqlite3_finalize(stmt)
	if result != SQLITE_DONE do return {}, false, domain.domain_error(.Conflict, "username is linked to another external identity")
	if !exec(conn, "COMMIT;") do return {}, false, domain.domain_error(.Internal_Error, "identity commit failed")
	committed = true
	return user, true, {}
}

// user_link_external_sqlite is the operator path (`ham-hub users link-oidc`):
// bind (issuer, subject) to an existing active user. Refuses when the user is
// already linked or the identity belongs to another user; re-linking the same
// pair is a no-op success.
user_link_external_sqlite :: proc(conn: ^Conn, user_id, issuer, subject, now: string) -> (bool, domain.Domain_Error) {
	if conn == nil || conn.db == nil do return false, domain.domain_error(.Internal_Error, "identity repository unavailable")
	if user_id == "" || issuer == "" || subject == "" do return false, domain.domain_error(.Validation_Failed, "--user, --issuer and --subject are required")
	if !exec(conn, "BEGIN IMMEDIATE;") do return false, domain.domain_error(.Internal_Error, "identity transaction failed")
	committed := false
	defer {if !committed {_ = exec(conn, "ROLLBACK;")}}
	repo := User_Repo_SQLite{conn = conn}
	user, found, err := user_get_by_id_sqlite(rawptr(&repo), domain.User_ID(user_id))
	if !found {
		if err.code == .None do err = domain.domain_error(.Not_Found, "user not found")
		return false, err
	}
	if user.status != .Active do return false, domain.domain_error(.Forbidden, "user is disabled; only active users can be linked")
	if linked, read_ok := external_identity_lookup(conn, issuer, subject); !read_ok {
		return false, domain.domain_error(.Internal_Error, "identity lookup failed")
	} else if linked != "" {
		if linked != string(user.user_id) do return false, domain.domain_error(.Conflict, "this identity is linked to another user; unlink it first")
		if !exec(conn, "COMMIT;") do return false, domain.domain_error(.Internal_Error, "identity commit failed")
		committed = true
		return true, {}
	}
	stmt: sqlite3_stmt
	query := "INSERT INTO user_external_identities(issuer,subject,user_id,created_at) VALUES(?,?,?,?);"
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return false, domain.domain_error(.Internal_Error, "identity insert failed")
	bind_text(stmt, 1, issuer); bind_text(stmt, 2, subject); bind_text(stmt, 3, string(user.user_id)); bind_text(stmt, 4, now)
	result := sqlite3_step(stmt)
	sqlite3_finalize(stmt)
	if result != SQLITE_DONE do return false, domain.domain_error(.Conflict, "user is already linked to an external identity; unlink it first")
	if !exec(conn, "COMMIT;") do return false, domain.domain_error(.Internal_Error, "identity commit failed")
	committed = true
	return true, {}
}

// user_unlink_external_sqlite removes the user's external identity link (only
// the one for `issuer` when given). Returns the number of links removed.
user_unlink_external_sqlite :: proc(conn: ^Conn, user_id, issuer: string) -> (int, domain.Domain_Error) {
	if conn == nil || conn.db == nil do return 0, domain.domain_error(.Internal_Error, "identity repository unavailable")
	if user_id == "" do return 0, domain.domain_error(.Validation_Failed, "--user is required")
	stmt: sqlite3_stmt
	query := "DELETE FROM user_external_identities WHERE user_id=? AND (?='' OR issuer=?);"
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return 0, domain.domain_error(.Internal_Error, "identity delete failed")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, user_id); bind_text(stmt, 2, issuer); bind_text(stmt, 3, issuer)
	rc, changes := step_changes(conn.db, stmt)
	if rc != SQLITE_DONE do return 0, domain.domain_error(.Internal_Error, "identity delete failed")
	return int(changes), {}
}

// user_set_status_sqlite activates/disables a user (operator CLI).
user_set_status_sqlite :: proc(conn: ^Conn, user_id: string, active: bool, now: string) -> (bool, domain.Domain_Error) {
	if conn == nil || conn.db == nil do return false, domain.domain_error(.Internal_Error, "user repository unavailable")
	stmt: sqlite3_stmt
	query := "UPDATE users SET status=?, updated_at=? WHERE user_id=?;"
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return false, domain.domain_error(.Internal_Error, "user update failed")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, "active" if active else "disabled"); bind_text(stmt, 2, now); bind_text(stmt, 3, user_id)
	rc, changes := step_changes(conn.db, stmt)
	if rc != SQLITE_DONE do return false, domain.domain_error(.Internal_Error, "user update failed")
	return changes == 1, {}
}
