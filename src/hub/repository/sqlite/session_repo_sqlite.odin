package sqlite

import "core:c"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Session_Repo_SQLite :: struct {
	conn: ^Conn,
}

new_session_repository :: proc(impl: ^Session_Repo_SQLite, conn: ^Conn) -> iface.Session_Repository {
	impl.conn = conn
	return iface.Session_Repository{
		ctx = rawptr(impl),
		create_session = session_create_sqlite,
		get_session = session_get_sqlite,
		touch_session = session_touch_sqlite,
		delete_session = session_delete_sqlite,
		save_login_state = login_state_save_sqlite,
		take_login_state = login_state_take_sqlite,
		purge_expired = session_purge_expired_sqlite,
	}
}

@(private = "file")
session_err :: proc(msg: string) -> domain.Domain_Error {
	return domain.domain_error(.Internal_Error, msg)
}

@(private = "file")
session_prepare :: proc(impl: ^Session_Repo_SQLite, query: string) -> (sqlite3_stmt, bool) {
	if impl == nil || impl.conn == nil || impl.conn.db == nil do return nil, false
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), c.int(len(query)), &stmt, nil) != SQLITE_OK do return nil, false
	return stmt, true
}

@(private = "file")
session_bind_nullable :: proc(stmt: sqlite3_stmt, index: int, value: string) {
	if value == "" do sqlite3_bind_null(stmt, c.int(index))
	else do bind_text(stmt, index, value)
}

@(private = "file")
session_from_stmt :: proc(stmt: sqlite3_stmt) -> iface.User_Session {
	return iface.User_Session{
		session_id_hash = column_text(stmt, 0),
		user_id = column_text(stmt, 1),
		created_at_ms = sqlite3_column_int64(stmt, 2),
		last_seen_at_ms = sqlite3_column_int64(stmt, 3),
		expires_at_ms = sqlite3_column_int64(stmt, 4),
		idle_expires_at_ms = sqlite3_column_int64(stmt, 5),
		id_token = column_text(stmt, 6),
		user_agent = column_text(stmt, 7),
	}
}

session_create_sqlite :: proc(ctx: rawptr, session: iface.User_Session) -> domain.Domain_Error {
	impl := (^Session_Repo_SQLite)(ctx)
	stmt, ok := session_prepare(impl, "INSERT INTO user_sessions(session_id_hash,user_id,created_at_ms,last_seen_at_ms,expires_at_ms,idle_expires_at_ms,id_token,user_agent) VALUES(?,?,?,?,?,?,?,?);")
	if !ok do return session_err("failed to prepare session insert")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, session.session_id_hash); bind_text(stmt, 2, session.user_id)
	sqlite3_bind_int64(stmt, 3, session.created_at_ms); sqlite3_bind_int64(stmt, 4, session.last_seen_at_ms)
	sqlite3_bind_int64(stmt, 5, session.expires_at_ms); sqlite3_bind_int64(stmt, 6, session.idle_expires_at_ms)
	session_bind_nullable(stmt, 7, session.id_token); session_bind_nullable(stmt, 8, session.user_agent)
	if sqlite3_step(stmt) != SQLITE_DONE do return session_err("failed to create session")
	return {}
}

session_get_sqlite :: proc(ctx: rawptr, session_id_hash: string) -> (iface.User_Session, bool, domain.Domain_Error) {
	impl := (^Session_Repo_SQLite)(ctx)
	stmt, ok := session_prepare(impl, "SELECT session_id_hash,user_id,created_at_ms,last_seen_at_ms,expires_at_ms,idle_expires_at_ms,id_token,user_agent FROM user_sessions WHERE session_id_hash=?;")
	if !ok do return {}, false, session_err("failed to prepare session lookup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, session_id_hash)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_ROW do return session_from_stmt(stmt), true, {}
	if rc != SQLITE_DONE do return {}, false, session_err("failed to read session")
	return {}, false, {}
}

session_touch_sqlite :: proc(ctx: rawptr, session_id_hash: string, now_ms, idle_expires_at_ms: i64) -> domain.Domain_Error {
	impl := (^Session_Repo_SQLite)(ctx)
	stmt, ok := session_prepare(impl, "UPDATE user_sessions SET last_seen_at_ms=?, idle_expires_at_ms=min(?, expires_at_ms) WHERE session_id_hash=?;")
	if !ok do return session_err("failed to prepare session touch")
	defer sqlite3_finalize(stmt)
	sqlite3_bind_int64(stmt, 1, now_ms); sqlite3_bind_int64(stmt, 2, idle_expires_at_ms); bind_text(stmt, 3, session_id_hash)
	if sqlite3_step(stmt) != SQLITE_DONE do return session_err("failed to touch session")
	return {}
}

session_delete_sqlite :: proc(ctx: rawptr, session_id_hash: string) -> (iface.User_Session, bool, domain.Domain_Error) {
	impl := (^Session_Repo_SQLite)(ctx)
	stmt, ok := session_prepare(impl, "DELETE FROM user_sessions WHERE session_id_hash=? RETURNING session_id_hash,user_id,created_at_ms,last_seen_at_ms,expires_at_ms,idle_expires_at_ms,id_token,user_agent;")
	if !ok do return {}, false, session_err("failed to prepare session delete")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, session_id_hash)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_ROW {
		row := session_from_stmt(stmt)
		for sqlite3_step(stmt) == SQLITE_ROW {}
		return row, true, {}
	}
	if rc != SQLITE_DONE do return {}, false, session_err("failed to delete session")
	return {}, false, {}
}

login_state_save_sqlite :: proc(ctx: rawptr, state_hash: string, state: iface.OIDC_Login_State) -> domain.Domain_Error {
	impl := (^Session_Repo_SQLite)(ctx)
	stmt, ok := session_prepare(impl, "INSERT INTO oidc_login_states(state_hash,nonce,code_verifier,return_to,expires_at_ms) VALUES(?,?,?,?,?);")
	if !ok do return session_err("failed to prepare login state insert")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, state_hash); bind_text(stmt, 2, state.nonce); bind_text(stmt, 3, state.code_verifier)
	bind_text(stmt, 4, state.return_to); sqlite3_bind_int64(stmt, 5, state.expires_at_ms)
	if sqlite3_step(stmt) != SQLITE_DONE do return session_err("failed to save login state")
	return {}
}

login_state_take_sqlite :: proc(ctx: rawptr, state_hash: string) -> (iface.OIDC_Login_State, bool, domain.Domain_Error) {
	impl := (^Session_Repo_SQLite)(ctx)
	stmt, ok := session_prepare(impl, "DELETE FROM oidc_login_states WHERE state_hash=? RETURNING nonce,code_verifier,return_to,expires_at_ms;")
	if !ok do return {}, false, session_err("failed to prepare login state take")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, state_hash)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_ROW {
		row := iface.OIDC_Login_State{nonce = column_text(stmt, 0), code_verifier = column_text(stmt, 1), return_to = column_text(stmt, 2), expires_at_ms = sqlite3_column_int64(stmt, 3)}
		for sqlite3_step(stmt) == SQLITE_ROW {}
		return row, true, {}
	}
	if rc != SQLITE_DONE do return {}, false, session_err("failed to take login state")
	return {}, false, {}
}

session_purge_expired_sqlite :: proc(ctx: rawptr, now_ms: i64) -> (int, domain.Domain_Error) {
	impl := (^Session_Repo_SQLite)(ctx)
	queries := [?]string{
		"DELETE FROM user_sessions WHERE expires_at_ms <= ? OR idle_expires_at_ms <= ?;",
		"DELETE FROM oidc_login_states WHERE expires_at_ms <= ? OR ? < 0;",
		"DELETE FROM vault_request_nonces WHERE expires_ms < ? OR ? < 0;",
	}
	total := 0
	for query in queries {
		stmt, ok := session_prepare(impl, query)
		if !ok do return total, session_err("failed to prepare expiry purge")
		sqlite3_bind_int64(stmt, 1, now_ms); sqlite3_bind_int64(stmt, 2, now_ms)
		rc, changes := step_changes(impl.conn.db, stmt)
		sqlite3_finalize(stmt)
		if rc != SQLITE_DONE do return total, session_err("failed to purge expired rows")
		total += changes
	}
	return total, {}
}
