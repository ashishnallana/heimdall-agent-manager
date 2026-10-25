package sqlite

import "core:c"
import "core:strings"
import "core:sync"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

User_Repo_SQLite :: struct {
	identity_mutex: sync.Mutex,
	identity_conn: ^Conn, // Dedicated transaction connection in production.
	conn: ^Conn,
}

new_user_repository :: proc(impl: ^User_Repo_SQLite, conn: ^Conn) -> iface.User_Repository {
	impl.conn = conn
	return iface.User_Repository{resolve_external = user_resolve_external_sqlite, ctx = rawptr(impl), launch_preferences_get = launch_preferences_get_sqlite, launch_preferences_save = launch_preferences_save_sqlite, get_by_id = user_get_by_id_sqlite, save = user_save_sqlite, save_token = user_token_save_sqlite, get_token_by_id = user_token_get_by_id_sqlite, get_token_by_hash = user_token_get_by_hash_sqlite, list_tokens_by_owner = user_token_list_by_owner_sqlite}
}

user_get_by_id_sqlite :: proc(ctx: rawptr, user_id: domain.User_ID) -> (domain.User, bool, domain.Domain_Error) {
	impl := (^User_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return domain.User{}, false, domain.domain_error(.Internal_Error, "sqlite user repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "SELECT user_id, name, display_name, email, status, created_at, updated_at FROM users WHERE user_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return domain.User{}, false, domain.domain_error(.Internal_Error, "failed to prepare user lookup")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(user_id))
	if sqlite3_step(stmt) != SQLITE_ROW {
		return domain.User{}, false, domain.domain_error(.Not_Found, "user not found")
	}
	return user_from_stmt(stmt), true, domain.Domain_Error{}
}

user_save_sqlite :: proc(ctx: rawptr, user: domain.User) -> (domain.User, bool, domain.Domain_Error) {
	impl := (^User_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return domain.User{}, false, domain.domain_error(.Internal_Error, "sqlite user repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "INSERT INTO users (user_id, name, display_name, email, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?);"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return domain.User{}, false, domain.domain_error(.Internal_Error, "failed to prepare user insert")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(user.user_id))
	bind_text(stmt, 2, user.name)
	bind_text(stmt, 3, user.display_name)
	bind_text(stmt, 4, user.email)
	bind_text(stmt, 5, user_status_string(user.status))
	bind_text(stmt, 6, user.created_at)
	bind_text(stmt, 7, user.updated_at)
	if sqlite3_step(stmt) != SQLITE_DONE {
		return domain.User{}, false, domain.domain_error(.Conflict, "user already exists or could not be saved")
	}
	return user, true, domain.Domain_Error{}
}

user_token_save_sqlite :: proc(ctx: rawptr, token: domain.User_API_Token) -> (domain.User_API_Token, bool, domain.Domain_Error) {
	impl := (^User_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil do return domain.User_API_Token{}, false, domain.domain_error(.Internal_Error, "sqlite user token repository is not open")
	stmt: sqlite3_stmt = nil
	query := "INSERT INTO user_api_tokens (token_id, owner_user_id, label, token_hash, created_at, updated_at, last_used_at, expires_at, revoked_at, created_from, device_label) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(token_id) DO UPDATE SET label=excluded.label, updated_at=excluded.updated_at, last_used_at=excluded.last_used_at, expires_at=excluded.expires_at, revoked_at=excluded.revoked_at, created_from=excluded.created_from, device_label=excluded.device_label;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.User_API_Token{}, false, domain.domain_error(.Internal_Error, "failed to prepare user token save")
	defer sqlite3_finalize(stmt)
	bind_token(stmt, token)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.User_API_Token{}, false, domain.domain_error(.Conflict, "user token could not be saved")
	return token, true, domain.Domain_Error{}
}

user_token_get_by_id_sqlite :: proc(ctx: rawptr, token_id: string) -> (domain.User_API_Token, bool, domain.Domain_Error) {
	return user_token_get_by_column(ctx, "token_id", token_id)
}

user_token_get_by_hash_sqlite :: proc(ctx: rawptr, token_hash: string) -> (domain.User_API_Token, bool, domain.Domain_Error) {
	return user_token_get_by_column(ctx, "token_hash", token_hash)
}

user_token_get_by_column :: proc(ctx: rawptr, column, value: string) -> (domain.User_API_Token, bool, domain.Domain_Error) {
	impl := (^User_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil do return domain.User_API_Token{}, false, domain.domain_error(.Internal_Error, "sqlite user token repository is not open")
	stmt: sqlite3_stmt = nil
	query := strings.concatenate({"SELECT token_id, owner_user_id, label, token_hash, created_at, updated_at, last_used_at, expires_at, revoked_at, created_from, device_label FROM user_api_tokens WHERE ", column, " = ?;"})
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.User_API_Token{}, false, domain.domain_error(.Internal_Error, "failed to prepare user token lookup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, value)
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.User_API_Token{}, false, domain.domain_error(.Not_Found, "user token not found")
	return token_from_stmt(stmt), true, domain.Domain_Error{}
}

user_token_list_by_owner_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.User_API_Token, domain.Domain_Error) {
	impl := (^User_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil do return nil, domain.domain_error(.Internal_Error, "sqlite user token repository is not open")
	stmt: sqlite3_stmt = nil
	query := "SELECT token_id, owner_user_id, label, token_hash, created_at, updated_at, last_used_at, expires_at, revoked_at, created_from, device_label FROM user_api_tokens WHERE owner_user_id = ? ORDER BY created_at DESC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare user token list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner_user_id))
	out := make([dynamic]domain.User_API_Token)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, token_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

user_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.User {
	return domain.User{
		user_id = domain.User_ID(column_text(stmt, 0)),
		name = column_text(stmt, 1),
		display_name = column_text(stmt, 2),
		email = column_text(stmt, 3),
		status = user_status_from_string(column_text_unowned(stmt, 4)),
		created_at = column_text(stmt, 5),
		updated_at = column_text(stmt, 6),
	}
}

bind_token :: proc(stmt: sqlite3_stmt, token: domain.User_API_Token) {
	bind_text(stmt, 1, token.token_id)
	bind_text(stmt, 2, string(token.owner_user_id))
	bind_text(stmt, 3, token.label)
	bind_text(stmt, 4, token.token_hash)
	bind_text(stmt, 5, token.created_at)
	bind_text(stmt, 6, token.updated_at)
	bind_text(stmt, 7, token.last_used_at)
	bind_text(stmt, 8, token.expires_at)
	bind_text(stmt, 9, token.revoked_at)
	bind_text(stmt, 10, token.created_from)
	bind_text(stmt, 11, token.device_label)
}

token_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.User_API_Token {
	return domain.User_API_Token{
		token_id = column_text(stmt, 0),
		owner_user_id = domain.User_ID(column_text(stmt, 1)),
		label = column_text(stmt, 2),
		token_hash = column_text(stmt, 3),
		created_at = column_text(stmt, 4),
		updated_at = column_text(stmt, 5),
		last_used_at = column_text(stmt, 6),
		expires_at = column_text(stmt, 7),
		revoked_at = column_text(stmt, 8),
		created_from = column_text(stmt, 9),
		device_label = column_text(stmt, 10),
	}
}

bind_text :: proc(stmt: sqlite3_stmt, index: int, value: string) {
	if value == "" {
		sqlite3_bind_text(stmt, c.int(index), "", 0, SQLITE_TRANSIENT)
		return
	}
	sqlite3_bind_text(stmt, c.int(index), cstring(raw_data(value)), c.int(len(value)), SQLITE_TRANSIENT)
}

column_text_unowned :: proc(stmt: sqlite3_stmt, index: int) -> string {
	ptr := sqlite3_column_text(stmt, c.int(index))
	if ptr == nil do return ""
	n := int(sqlite3_column_bytes(stmt, c.int(index)))
	if n <= 0 do return ""
	bytes := ([^]byte)(rawptr(ptr))[:n]
	return string(bytes)
}

column_text :: proc(stmt: sqlite3_stmt, index: int) -> string {
	ptr := sqlite3_column_text(stmt, c.int(index))
	if ptr == nil do return ""
	n := int(sqlite3_column_bytes(stmt, c.int(index)))
	if n <= 0 do return ""
	bytes := ([^]byte)(rawptr(ptr))[:n]
	return strings.clone(string(bytes))
}

user_status_string :: proc(status: domain.User_Status) -> string {
	switch status {
	case .Active: return "active"
	case .Disabled: return "disabled"
	}
	return "active"
}

user_status_from_string :: proc(status: string) -> domain.User_Status {
	if status == "disabled" do return .Disabled
	return .Active
}
