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
	return iface.User_Repository{resolve_external = user_resolve_external_sqlite, ctx = rawptr(impl), launch_preferences_get = launch_preferences_get_sqlite, launch_preferences_save = launch_preferences_save_sqlite, get_by_id = user_get_by_id_sqlite, save = user_save_sqlite}
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
