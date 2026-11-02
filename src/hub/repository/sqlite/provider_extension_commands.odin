package sqlite
import domain "odin_test:hub/domain"

provider_extension_command_create_sqlite :: proc(
	ctx: rawptr,
	value: domain.Provider_Extension_Command,
) -> (
	bool,
	domain.Domain_Error,
) {
	impl := (^Provider_Repo_SQLite)(ctx)
	if !provider_repo_ready(impl) do return false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	stmt: sqlite3_stmt
	query := "INSERT INTO provider_extension_commands(command_id,bridge_id,kind,provider,parent_id,state,message,target_version,target_commit,source_version,source_commit,update_extensions,progress,profile_id) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT DO NOTHING;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return false, domain.domain_error(.Internal_Error, "failed to prepare extension command")
	defer sqlite3_finalize(stmt)
	bind_text(
		stmt,
		1,
		value.command_id,
	); bind_text(stmt, 2, value.bridge_id); bind_text(stmt, 3, value.kind)
	bind_text(
		stmt,
		4,
		value.provider,
	); bind_text(stmt, 5, value.parent_id); bind_text(stmt, 6, value.state)
	bind_text(
		stmt,
		7,
		value.message,
	); bind_text(stmt, 8, value.target_version); bind_text(stmt, 9, value.target_commit)
	bind_text(stmt, 10, value.source_version); bind_text(stmt, 11, value.source_commit)
	sqlite3_bind_int(
		stmt,
		12,
		1 if value.update_extensions else 0,
	); sqlite3_bind_int(stmt, 13, i32(value.progress)); bind_text(stmt,14,domain.profile_effective_id(value.provider,value.profile_id) if value.kind=="install" || value.kind=="uninstall" else value.profile_id)
	rc, changed := step_changes(impl.conn.db, stmt)
	if rc != SQLITE_DONE do return false, domain.domain_error(.Internal_Error, "failed to create extension command")
	return changed > 0, {}
}
provider_extension_command_save_sqlite :: proc(
	ctx: rawptr,
	value: domain.Provider_Extension_Command,
) -> domain.Domain_Error {
	impl := (^Provider_Repo_SQLite)(ctx)
	if !provider_repo_ready(impl) do return domain.domain_error(.Internal_Error, "sqlite repository is not open")
	stmt: sqlite3_stmt
	query := "UPDATE provider_extension_commands SET state=?,message=?,progress=? WHERE command_id=? AND bridge_id=?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.domain_error(.Internal_Error, "failed to prepare extension command update")
	defer sqlite3_finalize(stmt)
	bind_text(
		stmt,
		1,
		value.state,
	); bind_text(stmt, 2, value.message); sqlite3_bind_int(stmt, 3, i32(value.progress))
	bind_text(stmt, 4, value.command_id); bind_text(stmt, 5, value.bridge_id)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.domain_error(.Internal_Error, "failed to update extension command")
	return {}
}
provider_extension_command_list_sqlite :: proc(
	ctx: rawptr,
	bridge_id: string,
) -> (
	[dynamic]domain.Provider_Extension_Command,
	domain.Domain_Error,
) {
	impl := (^Provider_Repo_SQLite)(ctx)
	if !provider_repo_ready(impl) do return nil, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	stmt: sqlite3_stmt
	query := "SELECT command_id,bridge_id,kind,provider,parent_id,state,message,target_version,target_commit,source_version,source_commit,update_extensions,progress,profile_id FROM provider_extension_commands WHERE bridge_id=? ORDER BY rowid;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare extension command list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, bridge_id)
	items := make([dynamic]domain.Provider_Extension_Command)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW {
			domain.provider_extension_commands_destroy(items)
			return nil, domain.domain_error(.Internal_Error, "failed to list extension commands")
		}
		append(
			&items,
			domain.Provider_Extension_Command {
				command_id = column_text(stmt, 0),
				bridge_id = column_text(stmt, 1),
				kind = column_text(stmt, 2),
				provider = column_text(stmt, 3),
				parent_id = column_text(stmt, 4),
				state = column_text(stmt, 5),
				message = column_text(stmt, 6),
				target_version = column_text(stmt, 7),
				target_commit = column_text(stmt, 8),
				source_version = column_text(stmt, 9),
				source_commit = column_text(stmt, 10),
				update_extensions = column_text_unowned(stmt, 11) == "1",
				progress = provider_rank_from_stmt(stmt, 12),
				profile_id = column_text(stmt,13),
			},
		)
	}
	return items, {}
}
