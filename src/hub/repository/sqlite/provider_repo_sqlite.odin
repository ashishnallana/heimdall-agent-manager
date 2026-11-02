package sqlite

import "core:c"
import "core:strconv"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Provider_Repo_SQLite :: struct { conn: ^Conn }

new_provider_repository :: proc(impl: ^Provider_Repo_SQLite, conn: ^Conn) -> iface.Provider_Repository {
	impl.conn = conn
	return iface.Provider_Repository{
		ctx = rawptr(impl),
		list_profiles = bridge_provider_profiles_list_sqlite,
		reconcile_profiles = bridge_provider_profiles_reconcile_sqlite,
		profile_references = bridge_provider_profile_references_sqlite,
		upsert_models = bridge_provider_models_upsert_sqlite,
		list_models = bridge_provider_models_list_sqlite,
	create_extension_command = provider_extension_command_create_sqlite,
	save_extension_command = provider_extension_command_save_sqlite,
	list_extension_commands = provider_extension_command_list_sqlite,
		list = provider_catalog_list_sqlite,
		get = provider_catalog_get_sqlite,
		get_icon = provider_icon_get_sqlite,
		get_etag = provider_catalog_etag_sqlite,
		upsert_status = bridge_provider_status_upsert_sqlite,
		list_status = bridge_provider_status_list_sqlite,
		upsert_setting = bridge_provider_setting_upsert_sqlite,
		list_settings = bridge_provider_setting_list_sqlite,
	}
}

bridge_provider_status_upsert_sqlite :: proc(ctx: rawptr, value: domain.Bridge_Provider_Status) -> (bool, domain.Domain_Error) {
	impl := (^Provider_Repo_SQLite)(ctx)
	if !provider_repo_ready(impl) do return false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	stmt: sqlite3_stmt = nil
	query := "INSERT INTO bridge_provider_status (bridge_id, provider, binary_path, version_text, state, checked_at, extension_state, extension_version, extension_checked_at, profile_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(bridge_id, profile_id) DO UPDATE SET binary_path=excluded.binary_path, version_text=excluded.version_text, state=excluded.state, checked_at=excluded.checked_at, extension_state=excluded.extension_state, extension_version=excluded.extension_version, extension_checked_at=excluded.extension_checked_at;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return false, domain.domain_error(.Internal_Error, "failed to prepare provider status upsert")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, value.bridge_id); bind_text(stmt, 2, value.provider); bind_text(stmt, 3, value.binary_path)
	bind_text(stmt, 4, value.version_text); bind_text(stmt, 5, value.state); bind_text(stmt, 6, value.checked_at)
	bind_text(stmt, 7, value.extension_state); bind_text(stmt, 8, value.extension_version); bind_text(stmt, 9, value.extension_checked_at); bind_text(stmt,10,domain.profile_effective_id(value.provider,value.profile_id))
	if sqlite3_step(stmt) != SQLITE_DONE do return false, domain.domain_error(.Internal_Error, "failed to upsert provider status")
	return true, {}
}

bridge_provider_status_list_sqlite :: proc(ctx: rawptr, bridge_id: string) -> ([dynamic]domain.Bridge_Provider_Status, domain.Domain_Error) {
	impl := (^Provider_Repo_SQLite)(ctx)
	if !provider_repo_ready(impl) do return nil, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	stmt: sqlite3_stmt = nil
	query := "SELECT bridge_id, provider, binary_path, version_text, state, checked_at, extension_state, extension_version, extension_checked_at, profile_id FROM bridge_provider_status WHERE bridge_id=? ORDER BY provider;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare provider status list")
	defer sqlite3_finalize(stmt); bind_text(stmt, 1, bridge_id)
	items := make([dynamic]domain.Bridge_Provider_Status)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&items, domain.Bridge_Provider_Status{bridge_id=column_text(stmt,0),provider=column_text(stmt,1),binary_path=column_text(stmt,2),version_text=column_text(stmt,3),state=column_text(stmt,4),checked_at=column_text(stmt,5),extension_state=column_text(stmt,6),extension_version=column_text(stmt,7),extension_checked_at=column_text(stmt,8),profile_id=column_text(stmt,9)})
	return items, {}
}

bridge_provider_setting_upsert_sqlite :: proc(ctx: rawptr, value: domain.Bridge_Provider_Setting) -> (bool, domain.Domain_Error) {
	impl := (^Provider_Repo_SQLite)(ctx)
	if !provider_repo_ready(impl) do return false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	stmt: sqlite3_stmt = nil
	query := "INSERT INTO bridge_provider_settings (bridge_id, provider, enabled, updated_at, profile_id) VALUES (?, ?, ?, ?, ?) ON CONFLICT(bridge_id, profile_id) DO UPDATE SET enabled=excluded.enabled, updated_at=excluded.updated_at;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return false, domain.domain_error(.Internal_Error, "failed to prepare provider setting upsert")
	defer sqlite3_finalize(stmt); bind_text(stmt,1,value.bridge_id); bind_text(stmt,2,value.provider); sqlite3_bind_int(stmt,3,1 if value.enabled else 0); bind_text(stmt,4,value.updated_at); bind_text(stmt,5,domain.profile_effective_id(value.provider,value.profile_id))
	if sqlite3_step(stmt) != SQLITE_DONE do return false, domain.domain_error(.Internal_Error, "failed to upsert provider setting")
	return true, {}
}

bridge_provider_setting_list_sqlite :: proc(ctx: rawptr, bridge_id: string) -> ([dynamic]domain.Bridge_Provider_Setting, domain.Domain_Error) {
	impl := (^Provider_Repo_SQLite)(ctx)
	if !provider_repo_ready(impl) do return nil, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	stmt: sqlite3_stmt = nil
	query := "SELECT bridge_id, provider, enabled, updated_at, profile_id FROM bridge_provider_settings WHERE bridge_id=? ORDER BY provider;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare provider setting list")
	defer sqlite3_finalize(stmt); bind_text(stmt,1,bridge_id)
	items := make([dynamic]domain.Bridge_Provider_Setting)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&items, domain.Bridge_Provider_Setting{bridge_id=column_text(stmt,0),provider=column_text(stmt,1),enabled=column_text_unowned(stmt,2)=="1",updated_at=column_text(stmt,3),profile_id=column_text(stmt,4)})
	return items, {}
}

provider_repo_ready :: proc(impl: ^Provider_Repo_SQLite) -> bool {
	return impl != nil && impl.conn != nil && impl.conn.db != nil
}

provider_rank_from_stmt :: proc(stmt: sqlite3_stmt, column: int) -> int {
	if value, ok := strconv.parse_int(column_text_unowned(stmt, column)); ok do return int(value)
	return 0
}

provider_models_for_sqlite :: proc(impl: ^Provider_Repo_SQLite, provider: string) -> ([dynamic]domain.Provider_Model, domain.Domain_Error) {
	items := make([dynamic]domain.Provider_Model)
	stmt: sqlite3_stmt = nil
	query := "SELECT provider, model_id, label, state, rank FROM provider_models WHERE provider = ? ORDER BY rank ASC, model_id ASC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return items, domain.domain_error(.Internal_Error, "failed to prepare provider model list")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, provider)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&items, domain.Provider_Model{
			provider = column_text(stmt, 0),
			model_id = column_text(stmt, 1),
			label = column_text(stmt, 2),
			state = column_text(stmt, 3),
			rank = provider_rank_from_stmt(stmt, 4),
		})
	}
	return items, {}
}

provider_entry_from_stmt :: proc(impl: ^Provider_Repo_SQLite, stmt: sqlite3_stmt) -> (domain.Provider_Catalog_Entry, domain.Domain_Error) {
	entry := domain.Provider_Catalog_Entry{
		provider = column_text(stmt, 0),
		display_name = column_text(stmt, 1),
		icon_url = column_text(stmt, 2),
		binary = column_text(stmt, 3),
		base_args_json = column_text(stmt, 4),
		yolo_args_json = column_text(stmt, 5),
		model_flag = column_text(stmt, 6),
		prompt_args_json = column_text(stmt, 7),
		prompt_delivery = column_text(stmt, 8),
		starter_prompt = column_text(stmt, 9),
		bootstrap_file = column_text(stmt, 10),
		skill_dir = column_text(stmt, 11),
		startup_detection_json = column_text(stmt, 12),
		activity_detection_json = column_text(stmt, 13),
		state = column_text(stmt, 14),
		rank = provider_rank_from_stmt(stmt, 15),
		extension_json = column_text(stmt, 16),
		ask_args_json = column_text(stmt, 17),
	}
	models, err := provider_models_for_sqlite(impl, entry.provider)
	if err.code != .None {
		domain.provider_catalog_entry_destroy(entry)
		return {}, err
	}
	entry.models = models
	return entry, {}
}

PROVIDER_SELECT :: "SELECT provider, display_name, icon_url, binary, base_args, yolo_args, model_flag, prompt_args, prompt_delivery, starter_prompt, bootstrap_file, skill_dir, startup_detection, activity_detection, state, rank, COALESCE(extension, ''), ask_args FROM provider_catalog"

provider_catalog_list_sqlite :: proc(ctx: rawptr) -> ([dynamic]domain.Provider_Catalog_Entry, domain.Domain_Error) {
	impl := (^Provider_Repo_SQLite)(ctx)
	if !provider_repo_ready(impl) do return nil, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	stmt: sqlite3_stmt = nil
	query := PROVIDER_SELECT + " ORDER BY rank ASC, provider ASC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare provider catalog list")
	}
	defer sqlite3_finalize(stmt)
	items := make([dynamic]domain.Provider_Catalog_Entry)
	for sqlite3_step(stmt) == SQLITE_ROW {
		entry, err := provider_entry_from_stmt(impl, stmt)
		if err.code != .None {
			domain.provider_catalog_destroy(items)
			return nil, err
		}
		append(&items, entry)
	}
	return items, {}
}

provider_catalog_get_sqlite :: proc(ctx: rawptr, provider: string) -> (domain.Provider_Catalog_Entry, bool, domain.Domain_Error) {
	impl := (^Provider_Repo_SQLite)(ctx)
	if !provider_repo_ready(impl) do return {}, false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	stmt: sqlite3_stmt = nil
	query := PROVIDER_SELECT + " WHERE provider = ? LIMIT 1;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return {}, false, domain.domain_error(.Internal_Error, "failed to prepare provider catalog get")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, provider)
	if sqlite3_step(stmt) != SQLITE_ROW do return {}, false, {}
	entry, err := provider_entry_from_stmt(impl, stmt)
	if err.code != .None do return {}, false, err
	return entry, true, {}
}

provider_icon_get_sqlite :: proc(ctx: rawptr, provider: string) -> (domain.Provider_Icon, bool, domain.Domain_Error) {
	impl := (^Provider_Repo_SQLite)(ctx)
	if !provider_repo_ready(impl) do return {}, false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	stmt: sqlite3_stmt = nil
	query := "SELECT provider, content_type, content FROM provider_icons WHERE provider = ? LIMIT 1;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return {}, false, domain.domain_error(.Internal_Error, "failed to prepare provider icon get")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, provider)
	if sqlite3_step(stmt) != SQLITE_ROW do return {}, false, {}
	return domain.Provider_Icon{provider = column_text(stmt, 0), content_type = column_text(stmt, 1), content = column_text(stmt, 2)}, true, {}
}

provider_catalog_etag_sqlite :: proc(ctx: rawptr) -> (string, domain.Domain_Error) {
	impl := (^Provider_Repo_SQLite)(ctx)
	if !provider_repo_ready(impl) do return "", domain.domain_error(.Internal_Error, "sqlite repository is not open")
	stmt: sqlite3_stmt = nil
	query := "SELECT catalog_etag FROM provider_catalog_meta LIMIT 1;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return "", domain.domain_error(.Internal_Error, "failed to prepare provider catalog etag get")
	}
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return "", domain.domain_error(.Internal_Error, "provider catalog etag is missing")
	return column_text(stmt, 0), {}
}

bridge_provider_models_upsert_sqlite :: proc(ctx: rawptr, v: domain.Bridge_Provider_Models) -> domain.Domain_Error {
	impl := (^Provider_Repo_SQLite)(ctx)
	if !provider_repo_ready(impl) do return domain.domain_error(.Internal_Error, "sqlite repository is not open")
	stmt: sqlite3_stmt
	// A failed probe updates the outcome but cannot erase the Hub's last good list,
	// even if the Bridge lost its own cache. Successful empty lists replace it.
	query := "INSERT INTO bridge_provider_models (bridge_id,provider,binary_path,version_text,has_snapshot,models_json,models_source,models_checked_at,models_attempted_at,models_state,profile_id,custom_models_json) VALUES (?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(bridge_id,profile_id) DO UPDATE SET binary_path=CASE WHEN (excluded.models_state='success' OR (has_snapshot=0 AND excluded.has_snapshot=1)) THEN excluded.binary_path ELSE binary_path END, version_text=CASE WHEN (excluded.models_state='success' OR (has_snapshot=0 AND excluded.has_snapshot=1)) THEN excluded.version_text ELSE version_text END, has_snapshot=CASE WHEN (excluded.models_state='success' OR (has_snapshot=0 AND excluded.has_snapshot=1)) THEN excluded.has_snapshot ELSE has_snapshot END, models_json=CASE WHEN (excluded.models_state='success' OR (has_snapshot=0 AND excluded.has_snapshot=1)) THEN excluded.models_json ELSE models_json END, models_source=CASE WHEN (excluded.models_state='success' OR (has_snapshot=0 AND excluded.has_snapshot=1)) THEN excluded.models_source ELSE models_source END, models_checked_at=CASE WHEN (excluded.models_state='success' OR (has_snapshot=0 AND excluded.has_snapshot=1)) THEN excluded.models_checked_at ELSE models_checked_at END, models_attempted_at=excluded.models_attempted_at, models_state=excluded.models_state,custom_models_json=CASE WHEN excluded.custom_models_json='' THEN custom_models_json ELSE excluded.custom_models_json END;"
	if sqlite3_prepare_v2(impl.conn.db,cstring(raw_data(query)),-1,&stmt,nil) != SQLITE_OK do return domain.domain_error(.Internal_Error,"failed to prepare model upsert")
	defer sqlite3_finalize(stmt)
	bind_text(stmt,1,v.bridge_id); bind_text(stmt,2,v.provider); bind_text(stmt,3,v.binary_path); bind_text(stmt,4,v.version_text)
	sqlite3_bind_int(stmt,5,1 if v.has_snapshot else 0); bind_text(stmt,6,v.models_json); bind_text(stmt,7,v.models_source)
	bind_text(stmt,8,v.models_checked_at); bind_text(stmt,9,v.models_attempted_at); bind_text(stmt,10,v.models_state); bind_text(stmt,11,domain.profile_effective_id(v.provider,v.profile_id));bind_text(stmt,12,v.custom_models_json)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.domain_error(.Internal_Error,"failed to save model snapshot")
	return {}
}
bridge_provider_models_list_sqlite :: proc(ctx: rawptr, bridge_id: string) -> ([dynamic]domain.Bridge_Provider_Models, domain.Domain_Error) {
	impl := (^Provider_Repo_SQLite)(ctx)
	if !provider_repo_ready(impl) do return nil, domain.domain_error(.Internal_Error,"sqlite repository is not open")
	stmt: sqlite3_stmt
	query := "SELECT bridge_id,provider,binary_path,version_text,has_snapshot,models_json,models_source,models_checked_at,models_attempted_at,models_state,profile_id,custom_models_json FROM bridge_provider_models WHERE bridge_id=? ORDER BY provider;"
	if sqlite3_prepare_v2(impl.conn.db,cstring(raw_data(query)),-1,&stmt,nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error,"failed to prepare model list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt,1,bridge_id)
	out := make([dynamic]domain.Bridge_Provider_Models)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&out, domain.Bridge_Provider_Models{
			bridge_id=column_text(stmt,0),provider=column_text(stmt,1),binary_path=column_text(stmt,2),version_text=column_text(stmt,3),
			has_snapshot=column_text_unowned(stmt,4)=="1",models_json=column_text(stmt,5),models_source=column_text(stmt,6),
			models_checked_at=column_text(stmt,7),models_attempted_at=column_text(stmt,8),models_state=column_text(stmt,9),profile_id=column_text(stmt,10),custom_models_json=column_text(stmt,11),
		})
	}
	return out, {}
}
