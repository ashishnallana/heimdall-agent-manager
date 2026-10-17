package sqlite

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Lsp_Server_Config_Repo_SQLite :: struct {
	conn: ^Conn,
}

new_lsp_server_config_repository :: proc(impl: ^Lsp_Server_Config_Repo_SQLite, conn: ^Conn) -> iface.Lsp_Server_Config_Repository {
	impl.conn = conn
	return iface.Lsp_Server_Config_Repository{
		ctx            = rawptr(impl),
		upsert         = lsp_server_config_upsert_sqlite,
		get            = lsp_server_config_get_sqlite,
		list_by_bridge = lsp_server_config_list_by_bridge_sqlite,
		delete         = lsp_server_config_delete_sqlite,
	}
}

// Column order for SELECT queries (used by lsp_server_config_from_stmt):
// 0:config_id 1:owner_user_id 2:bridge_id 3:language 4:cmd 5:args
// 6:file_extensions 7:root_markers 8:dir_prefix 9:dir_pattern 10:created_at 11:updated_at
lsp_server_config_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Lsp_Server_Config {
	c: domain.Lsp_Server_Config
	c.config_id       = column_text(stmt, 0)
	c.owner_user_id   = column_text(stmt, 1)
	c.bridge_id       = column_text(stmt, 2)
	c.language        = column_text(stmt, 3)
	c.cmd             = column_text(stmt, 4)
	c.args            = column_text(stmt, 5)
	c.file_extensions = column_text(stmt, 6)
	c.root_markers    = column_text(stmt, 7)
	c.dir_prefix      = column_text(stmt, 8)
	c.dir_pattern     = column_text(stmt, 9)
	c.created_at      = column_text(stmt, 10)
	c.updated_at      = column_text(stmt, 11)
	return c
}

lsp_server_config_upsert_sqlite :: proc(ctx: rawptr, cfg: domain.Lsp_Server_Config) -> (bool, domain.Domain_Error) {
	impl := (^Lsp_Server_Config_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := `INSERT INTO lsp_server_configs (
		config_id, owner_user_id, bridge_id, language, cmd, args,
		file_extensions, root_markers, dir_prefix, dir_pattern, created_at, updated_at
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	ON CONFLICT(owner_user_id, bridge_id, language, dir_prefix) DO UPDATE SET
		config_id       = excluded.config_id,
		cmd             = excluded.cmd,
		args            = excluded.args,
		file_extensions = excluded.file_extensions,
		root_markers    = excluded.root_markers,
		dir_pattern     = excluded.dir_pattern,
		updated_at      = excluded.updated_at;`
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return false, domain.domain_error(.Internal_Error, "failed to prepare lsp server config upsert")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1,  cfg.config_id)
	bind_text(stmt, 2,  cfg.owner_user_id)
	bind_text(stmt, 3,  cfg.bridge_id)
	bind_text(stmt, 4,  cfg.language)
	bind_text(stmt, 5,  cfg.cmd)
	bind_text(stmt, 6,  cfg.args)
	bind_text(stmt, 7,  cfg.file_extensions)
	bind_text(stmt, 8,  cfg.root_markers)
	bind_text(stmt, 9,  cfg.dir_prefix)
	bind_text(stmt, 10, cfg.dir_pattern)
	bind_text(stmt, 11, cfg.created_at)
	bind_text(stmt, 12, cfg.updated_at)
	if sqlite3_step(stmt) != SQLITE_DONE {
		return false, domain.domain_error(.Internal_Error, "failed to upsert lsp server config")
	}
	return true, domain.Domain_Error{}
}

lsp_server_config_get_sqlite :: proc(ctx: rawptr, owner_user_id, config_id: string) -> (domain.Lsp_Server_Config, bool, domain.Domain_Error) {
	impl := (^Lsp_Server_Config_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return domain.Lsp_Server_Config{}, false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "SELECT config_id, owner_user_id, bridge_id, language, cmd, args, file_extensions, root_markers, dir_prefix, dir_pattern, created_at, updated_at FROM lsp_server_configs WHERE owner_user_id = ? AND config_id = ? LIMIT 1;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return domain.Lsp_Server_Config{}, false, domain.domain_error(.Internal_Error, "failed to prepare lsp server config get")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, owner_user_id)
	bind_text(stmt, 2, config_id)
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Lsp_Server_Config{}, false, domain.Domain_Error{}
	return lsp_server_config_from_stmt(stmt), true, domain.Domain_Error{}
}

lsp_server_config_list_by_bridge_sqlite :: proc(ctx: rawptr, owner_user_id, bridge_id: string) -> ([dynamic]domain.Lsp_Server_Config, domain.Domain_Error) {
	impl := (^Lsp_Server_Config_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return nil, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "SELECT config_id, owner_user_id, bridge_id, language, cmd, args, file_extensions, root_markers, dir_prefix, dir_pattern, created_at, updated_at FROM lsp_server_configs WHERE owner_user_id = ? AND bridge_id = ? ORDER BY language ASC, dir_prefix ASC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare lsp server config list")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, owner_user_id)
	bind_text(stmt, 2, bridge_id)
	items := make([dynamic]domain.Lsp_Server_Config)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&items, lsp_server_config_from_stmt(stmt))
	}
	return items, domain.Domain_Error{}
}

lsp_server_config_delete_sqlite :: proc(ctx: rawptr, owner_user_id, config_id: string) -> (bool, domain.Domain_Error) {
	impl := (^Lsp_Server_Config_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "DELETE FROM lsp_server_configs WHERE owner_user_id = ? AND config_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return false, domain.domain_error(.Internal_Error, "failed to prepare lsp server config delete")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, owner_user_id)
	bind_text(stmt, 2, config_id)
	step_rc, row_changes := step_changes(impl.conn.db, stmt)
	if step_rc != SQLITE_DONE {
		return false, domain.domain_error(.Internal_Error, "failed to delete lsp server config")
	}
	return row_changes > 0, domain.Domain_Error{}
}
