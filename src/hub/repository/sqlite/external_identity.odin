package sqlite

import "core:sync"
import domain "odin_test:hub/domain"

// One transaction prevents concurrent first logins from claiming the same legacy
// username. A second subject cannot claim an already linked user's identifier.
user_resolve_external_sqlite :: proc(
	ctx: rawptr,
	issuer, subject, username, display_name, email, now: string,
	provision: bool,
) -> (
	domain.User,
	bool,
	domain.Domain_Error,
) {
	impl := (^User_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil do return {}, false, domain.domain_error(.Internal_Error, "identity repository unavailable")
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
		user, ok, err := user_get_by_id_sqlite(
			rawptr(&transaction_repo),
			domain.User_ID(linked_id),
		)
		if !ok do return {}, false, err
		if user.status != .Active do return {}, false, domain.domain_error(.Forbidden, "user is disabled")
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
	if count == 0 {
		if !provision do return {}, false, domain.domain_error(.Forbidden, "user provisioning is disabled")
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
