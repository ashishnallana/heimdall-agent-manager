package sqlite

import "core:fmt"
import "core:strconv"
import "core:strings"
import bootcache "odin_test:hub/bootcache"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Agent_Repo_SQLite :: struct {
	conn: ^Conn,
}

new_agent_repository :: proc(impl: ^Agent_Repo_SQLite, conn: ^Conn) -> iface.Agent_Repository {
	impl.conn = conn
	return iface.Agent_Repository{ctx = rawptr(impl), reconfiguration_begin = instance_reconfiguration_begin_sqlite, reconfiguration_get = instance_reconfiguration_get_sqlite, reconfiguration_advance = instance_reconfiguration_advance_sqlite, reconfiguration_list = instance_reconfiguration_list_sqlite, save = agent_save_sqlite, get = agent_get_sqlite, list_by_owner = agent_list_by_owner_sqlite, save_support = agent_save_support_sqlite, get_support = agent_get_support_sqlite, list_support = agent_list_support_sqlite, delete_support = agent_delete_support_sqlite, save_instance = agent_save_instance_sqlite, get_instance = agent_get_instance_sqlite, delete_instance = agent_delete_instance_sqlite, list_instances_by_owner = agent_list_instances_by_owner_sqlite, list_instances_by_bridge = agent_list_instances_by_bridge_sqlite, list_instances_by_chain = agent_list_instances_by_chain_sqlite, list_active_runtime_instances = agent_list_active_runtime_instances_sqlite, next_title_counter = agent_next_title_counter_sqlite, ext_insert_events = agent_ext_insert_events_sqlite, ext_update_instance = agent_ext_update_instance_sqlite, ext_list_events = agent_ext_list_events_sqlite, ext_list_subagents = agent_ext_list_subagents_sqlite, ext_list_files = agent_ext_list_files_sqlite, perm_insert = agent_perm_insert_sqlite, perm_get = agent_perm_get_sqlite, perm_list = agent_perm_list_sqlite, perm_close = agent_perm_close_sqlite, perm_close_pending = agent_perm_close_pending_sqlite}
}

agent_delete_instance_sqlite :: proc(ctx: rawptr, instance_id: string) -> (bool, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "DELETE FROM agent_instances WHERE agent_instance_id = ? AND kind = 'provider_test';"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return false, domain.domain_error(.Internal_Error, "failed to prepare provider-test cleanup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, instance_id)
	if sqlite3_step(stmt) != SQLITE_DONE do return false, domain.domain_error(.Internal_Error, "provider-test instance could not be removed")
	return true, {}
}

// agent_next_title_counter_sqlite atomically bumps the per-agent title counter and
// returns the new value. The UPSERT persists across daemon restarts so per-run
// default titles keep incrementing globally per agent.
agent_next_title_counter_sqlite :: proc(ctx: rawptr, agent_id: string, owner_user_id: domain.User_ID, now: string) -> (int, bool, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	if strings.trim_space(agent_id) == "" do return 0, false, domain.domain_error(.Validation_Failed, "agent_id is required for title counter")
	up: sqlite3_stmt = nil
	uq := "INSERT INTO agent_title_counters (agent_id, owner_user_id, counter, updated_at) VALUES (?, ?, 1, ?) ON CONFLICT(agent_id) DO UPDATE SET counter=counter+1, updated_at=excluded.updated_at;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(uq)), -1, &up, nil) != SQLITE_OK do return 0, false, domain.domain_error(.Internal_Error, "failed to prepare title counter bump")
	bind_text(up, 1, agent_id); bind_text(up, 2, string(owner_user_id)); bind_text(up, 3, now)
	if sqlite3_step(up) != SQLITE_DONE { sqlite3_finalize(up); return 0, false, domain.domain_error(.Conflict, "title counter could not be updated") }
	sqlite3_finalize(up)
	sel: sqlite3_stmt = nil
	sq := "SELECT counter FROM agent_title_counters WHERE agent_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(sq)), -1, &sel, nil) != SQLITE_OK do return 0, false, domain.domain_error(.Internal_Error, "failed to prepare title counter read")
	defer sqlite3_finalize(sel)
	bind_text(sel, 1, agent_id)
	if sqlite3_step(sel) != SQLITE_ROW do return 0, false, domain.domain_error(.Internal_Error, "title counter row missing after bump")
	return string_to_i32(column_text_unowned(sel, 0)), true, domain.Domain_Error{}
}

agent_save_sqlite :: proc(ctx: rawptr, agent: domain.Agent) -> (domain.Agent, bool, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "INSERT INTO agents (agent_id, owner_user_id, name, slug, template_id, instructions, state, created_at, updated_at, permission_mode) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(agent_id) DO UPDATE SET name=excluded.name, slug=excluded.slug, template_id=excluded.template_id, instructions=excluded.instructions, state=excluded.state, updated_at=excluded.updated_at, permission_mode=excluded.permission_mode;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Agent{}, false, domain.domain_error(.Internal_Error, "failed to prepare agent save")
	defer sqlite3_finalize(stmt)
	bind_agent(stmt, agent)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.Agent{}, false, domain.domain_error(.Conflict, "agent slug already exists or could not be saved")
	// An agent write can change its identity fragment (instructions/name) which is
	// part of the rendered bootstrap manifest; invalidate the manifest cache.
	bootcache.bump_content_epoch()
	return agent, true, domain.Domain_Error{}
}

agent_get_sqlite :: proc(ctx: rawptr, agent_id: string) -> (domain.Agent, bool, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT agent_id, owner_user_id, name, slug, template_id, instructions, state, created_at, updated_at, permission_mode FROM agents WHERE agent_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Agent{}, false, domain.domain_error(.Internal_Error, "failed to prepare agent lookup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, agent_id)
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Agent{}, false, domain.domain_error(.Not_Found, "agent not found")
	return agent_from_stmt(stmt), true, domain.Domain_Error{}
}

agent_list_by_owner_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID, limit: int, cursor: string) -> ([]domain.Agent, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	effective_limit := limit; if effective_limit <= 0 do effective_limit = 50
	query := "SELECT agent_id, owner_user_id, name, slug, template_id, instructions, state, created_at, updated_at, permission_mode FROM agents WHERE owner_user_id = ? ORDER BY created_at DESC, agent_id DESC LIMIT ?;"
	if cursor != "" do query = "SELECT agent_id, owner_user_id, name, slug, template_id, instructions, state, created_at, updated_at, permission_mode FROM agents WHERE owner_user_id = ? AND created_at < ? ORDER BY created_at DESC, agent_id DESC LIMIT ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare agent list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner_user_id))
	if cursor != "" {
		bind_text(stmt, 2, cursor)
		bind_text(stmt, 3, i32_to_string(effective_limit))
	} else {
		bind_text(stmt, 2, i32_to_string(effective_limit))
	}
	out := make([dynamic]domain.Agent)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, agent_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

agent_save_support_sqlite :: proc(ctx: rawptr, support: domain.Agent_Bridge_Support) -> (domain.Agent_Bridge_Support, bool, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "INSERT INTO agent_bridge_support (agent_id, bridge_id, owner_user_id, enabled, priority, max_instances, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(agent_id, bridge_id) DO UPDATE SET enabled=excluded.enabled, priority=excluded.priority, max_instances=excluded.max_instances, updated_at=excluded.updated_at;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Agent_Bridge_Support{}, false, domain.domain_error(.Internal_Error, "failed to prepare support save")
	defer sqlite3_finalize(stmt)
	bind_support(stmt, support)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.Agent_Bridge_Support{}, false, domain.domain_error(.Conflict, "support could not be saved")
	return support, true, domain.Domain_Error{}
}

agent_get_support_sqlite :: proc(ctx: rawptr, agent_id, bridge_id: string) -> (domain.Agent_Bridge_Support, bool, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT agent_id, bridge_id, owner_user_id, enabled, priority, max_instances, created_at, updated_at FROM agent_bridge_support WHERE agent_id = ? AND bridge_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Agent_Bridge_Support{}, false, domain.domain_error(.Internal_Error, "failed to prepare support lookup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, agent_id); bind_text(stmt, 2, bridge_id)
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Agent_Bridge_Support{}, false, domain.domain_error(.Not_Found, "support not found")
	return support_from_stmt(stmt), true, domain.Domain_Error{}
}

agent_list_support_sqlite :: proc(ctx: rawptr, agent_id: string, owner_user_id: domain.User_ID) -> ([]domain.Agent_Bridge_Support, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT agent_id, bridge_id, owner_user_id, enabled, priority, max_instances, created_at, updated_at FROM agent_bridge_support WHERE agent_id = ? AND owner_user_id = ? ORDER BY priority ASC, updated_at DESC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare support list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, agent_id); bind_text(stmt, 2, string(owner_user_id))
	out := make([dynamic]domain.Agent_Bridge_Support)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, support_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

agent_delete_support_sqlite :: proc(ctx: rawptr, agent_id, bridge_id: string, owner_user_id: domain.User_ID) -> (bool, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "DELETE FROM agent_bridge_support WHERE agent_id = ? AND bridge_id = ? AND owner_user_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return false, domain.domain_error(.Internal_Error, "failed to prepare support delete")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, agent_id); bind_text(stmt, 2, bridge_id); bind_text(stmt, 3, string(owner_user_id))
	if sqlite3_step(stmt) != SQLITE_DONE do return false, domain.domain_error(.Internal_Error, "support could not be deleted")
	return true, domain.Domain_Error{}
}

agent_save_instance_sqlite :: proc(ctx: rawptr, instance: domain.Agent_Instance) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "INSERT INTO agent_instances (agent_instance_id, owner_user_id, agent_id, bridge_id, display_name, provider, model, project_id, project_path, chain_id, conversation_id, runtime_status, startup_status, activity_status, status_message, last_applied_seq, run_count, current_task_id, current_task_role, created_at, updated_at, started_at, stopped_at, last_seen_at, kind, configuration_revision, launch_epoch, last_error_json, idle_since, stopped_by, permission_mode) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(agent_instance_id) DO UPDATE SET configuration_revision=agent_instances.configuration_revision + CASE WHEN agent_instances.provider != excluded.provider OR agent_instances.model != excluded.model OR agent_instances.project_id != excluded.project_id OR agent_instances.project_path != excluded.project_path THEN 1 ELSE 0 END, display_name=excluded.display_name, provider=excluded.provider, model=excluded.model, project_id=excluded.project_id, project_path=excluded.project_path, runtime_status=excluded.runtime_status, startup_status=excluded.startup_status, activity_status=excluded.activity_status, status_message=excluded.status_message, last_error_json=excluded.last_error_json, last_applied_seq=excluded.last_applied_seq, run_count=excluded.run_count, current_task_id=excluded.current_task_id, current_task_role=excluded.current_task_role, updated_at=excluded.updated_at, started_at=excluded.started_at, stopped_at=excluded.stopped_at, last_seen_at=excluded.last_seen_at, idle_since=excluded.idle_since, stopped_by=excluded.stopped_by, kind=excluded.kind WHERE agent_instances.configuration_revision=excluded.configuration_revision AND agent_instances.launch_epoch=excluded.launch_epoch RETURNING configuration_revision;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Agent_Instance{}, false, domain.domain_error(.Internal_Error, "failed to prepare instance save")
	defer sqlite3_finalize(stmt)
	bind_instance(stmt, instance)
	// Heartbeats/status updates take the DO UPDATE branch, firing the
	// agent_instances_fts AFTER UPDATE trigger which can hit SQLITE_CORRUPT on fts
	// index drift (see fts_repair.odin) — that is what froze last_seen while the
	// runtime looked "running". Self-heal + retry once, else report accurately.
	rc := step_write_healing(impl.conn, stmt)
	if rc != SQLITE_ROW {
		if rc == SQLITE_CORRUPT do return domain.Agent_Instance{}, false, domain.domain_error(.Internal_Error, "agent instance save failed: search index drift (SQLITE_CORRUPT) — run the FTS reconcile/repair")
		return domain.Agent_Instance{}, false, domain.domain_error(.Conflict, "agent instance could not be saved")
	}
	// Preserve existing string ownership while returning the persisted revision.
	saved := instance
	saved.configuration_revision = string_to_i32(column_text_unowned(stmt, 0))
	return saved, true, domain.Domain_Error{}
}

agent_get_instance_sqlite :: proc(ctx: rawptr, instance_id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT agent_instance_id, owner_user_id, agent_id, bridge_id, display_name, provider, model, project_id, project_path, chain_id, conversation_id, runtime_status, startup_status, activity_status, status_message, last_applied_seq, run_count, current_task_id, current_task_role, created_at, updated_at, started_at, stopped_at, last_seen_at, kind, configuration_revision, launch_epoch, last_error_json, idle_since, stopped_by, provider_session_id, provider_transcript_path, extension_provider, extension_version, extension_capabilities, extension_last_seen_at, permission_mode, (SELECT a.permission_mode FROM agents a WHERE a.agent_id = agent_instances.agent_id) FROM agent_instances WHERE agent_instance_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Agent_Instance{}, false, domain.domain_error(.Internal_Error, "failed to prepare instance lookup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, instance_id)
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Agent_Instance{}, false, domain.domain_error(.Not_Found, "agent instance not found")
	return instance_from_stmt(stmt), true, domain.Domain_Error{}
}

agent_list_instances_by_owner_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID, limit: int, cursor: string) -> ([]domain.Agent_Instance, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	effective_limit := limit; if effective_limit <= 0 do effective_limit = 50
	query := "SELECT agent_instance_id, owner_user_id, agent_id, bridge_id, display_name, provider, model, project_id, project_path, chain_id, conversation_id, runtime_status, startup_status, activity_status, status_message, last_applied_seq, run_count, current_task_id, current_task_role, created_at, updated_at, started_at, stopped_at, last_seen_at, kind, configuration_revision, launch_epoch, last_error_json, idle_since, stopped_by, provider_session_id, provider_transcript_path, extension_provider, extension_version, extension_capabilities, extension_last_seen_at, permission_mode, (SELECT a.permission_mode FROM agents a WHERE a.agent_id = agent_instances.agent_id) FROM agent_instances WHERE kind = 'agent' AND owner_user_id = ? ORDER BY created_at DESC, agent_instance_id DESC LIMIT ?;"
	if cursor != "" do query = "SELECT agent_instance_id, owner_user_id, agent_id, bridge_id, display_name, provider, model, project_id, project_path, chain_id, conversation_id, runtime_status, startup_status, activity_status, status_message, last_applied_seq, run_count, current_task_id, current_task_role, created_at, updated_at, started_at, stopped_at, last_seen_at, kind, configuration_revision, launch_epoch, last_error_json, idle_since, stopped_by, provider_session_id, provider_transcript_path, extension_provider, extension_version, extension_capabilities, extension_last_seen_at, permission_mode, (SELECT a.permission_mode FROM agents a WHERE a.agent_id = agent_instances.agent_id) FROM agent_instances WHERE kind = 'agent' AND owner_user_id = ? AND created_at < ? ORDER BY created_at DESC, agent_instance_id DESC LIMIT ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare instance list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner_user_id))
	if cursor != "" {
		bind_text(stmt, 2, cursor)
		bind_text(stmt, 3, i32_to_string(effective_limit))
	} else {
		bind_text(stmt, 2, i32_to_string(effective_limit))
	}
	out := make([dynamic]domain.Agent_Instance)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, instance_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

agent_list_instances_by_bridge_sqlite :: proc(ctx: rawptr, bridge_id: string) -> ([]domain.Agent_Instance, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT agent_instance_id, owner_user_id, agent_id, bridge_id, display_name, provider, model, project_id, project_path, chain_id, conversation_id, runtime_status, startup_status, activity_status, status_message, last_applied_seq, run_count, current_task_id, current_task_role, created_at, updated_at, started_at, stopped_at, last_seen_at, kind, configuration_revision, launch_epoch, last_error_json, idle_since, stopped_by, provider_session_id, provider_transcript_path, extension_provider, extension_version, extension_capabilities, extension_last_seen_at, permission_mode, (SELECT a.permission_mode FROM agents a WHERE a.agent_id = agent_instances.agent_id) FROM agent_instances WHERE kind = 'agent' AND bridge_id = ? ORDER BY updated_at DESC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare bridge instance list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, bridge_id)
	out := make([dynamic]domain.Agent_Instance)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, instance_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

agent_list_instances_by_chain_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID, chain_id: string) -> ([]domain.Agent_Instance, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT agent_instance_id, owner_user_id, agent_id, bridge_id, display_name, provider, model, project_id, project_path, chain_id, conversation_id, runtime_status, startup_status, activity_status, status_message, last_applied_seq, run_count, current_task_id, current_task_role, created_at, updated_at, started_at, stopped_at, last_seen_at, kind, configuration_revision, launch_epoch, last_error_json, idle_since, stopped_by, provider_session_id, provider_transcript_path, extension_provider, extension_version, extension_capabilities, extension_last_seen_at, permission_mode, (SELECT a.permission_mode FROM agents a WHERE a.agent_id = agent_instances.agent_id) FROM agent_instances WHERE kind = 'agent' AND owner_user_id = ? AND chain_id = ? ORDER BY created_at DESC, agent_instance_id DESC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare chain instance list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner_user_id))
	bind_text(stmt, 2, chain_id)
	out := make([dynamic]domain.Agent_Instance)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, instance_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

agent_list_active_runtime_instances_sqlite :: proc(ctx: rawptr) -> ([]domain.Agent_Instance, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT agent_instance_id, owner_user_id, agent_id, bridge_id, display_name, provider, model, project_id, project_path, chain_id, conversation_id, runtime_status, startup_status, activity_status, status_message, last_applied_seq, run_count, current_task_id, current_task_role, created_at, updated_at, started_at, stopped_at, last_seen_at, kind, configuration_revision, launch_epoch, last_error_json, idle_since, stopped_by, provider_session_id, provider_transcript_path, extension_provider, extension_version, extension_capabilities, extension_last_seen_at, permission_mode, (SELECT a.permission_mode FROM agents a WHERE a.agent_id = agent_instances.agent_id) FROM agent_instances WHERE kind = 'agent' AND runtime_status IN ('running','idle','busy','launching','starting','stopping','blocked') ORDER BY last_seen_at ASC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare active runtime instance list")
	defer sqlite3_finalize(stmt)
	out := make([dynamic]domain.Agent_Instance)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, instance_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

bind_agent :: proc(stmt: sqlite3_stmt, agent: domain.Agent) {
	bind_text(stmt, 1, agent.agent_id); bind_text(stmt, 2, string(agent.owner_user_id)); bind_text(stmt, 3, agent.name); bind_text(stmt, 4, agent.slug); bind_text(stmt, 5, agent.template_id); bind_text(stmt, 6, agent.instructions); bind_text(stmt, 7, domain.agent_state_string(agent.state)); bind_text(stmt, 8, agent.created_at); bind_text(stmt, 9, agent.updated_at); bind_text(stmt, 10, domain.agent_permission_mode_normalize(agent.permission_mode))
}

bind_support :: proc(stmt: sqlite3_stmt, s: domain.Agent_Bridge_Support) {
	bind_text(stmt, 1, s.agent_id); bind_text(stmt, 2, s.bridge_id); bind_text(stmt, 3, string(s.owner_user_id)); bind_text(stmt, 4, "1" if s.enabled else "0"); bind_text(stmt, 5, i32_to_string(s.priority)); bind_text(stmt, 6, i32_to_string(s.max_instances)); bind_text(stmt, 7, s.created_at); bind_text(stmt, 8, s.updated_at)
}

agent_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Agent {
	return domain.Agent{agent_id = column_text(stmt, 0), owner_user_id = domain.User_ID(column_text(stmt, 1)), name = column_text(stmt, 2), slug = column_text(stmt, 3), template_id = column_text(stmt, 4), instructions = column_text(stmt, 5), state = agent_state_from_string(column_text_unowned(stmt, 6)), created_at = column_text(stmt, 7), updated_at = column_text(stmt, 8), permission_mode = domain.agent_permission_mode_normalize(column_text_unowned(stmt, 9))}
}

support_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Agent_Bridge_Support {
	return domain.Agent_Bridge_Support{agent_id = column_text(stmt, 0), bridge_id = column_text(stmt, 1), owner_user_id = domain.User_ID(column_text(stmt, 2)), enabled = column_text_unowned(stmt, 3) == "1", priority = string_to_i32(column_text_unowned(stmt, 4)), max_instances = string_to_i32(column_text_unowned(stmt, 5)), created_at = column_text(stmt, 6), updated_at = column_text(stmt, 7)}
}

bind_instance :: proc(stmt: sqlite3_stmt, inst: domain.Agent_Instance) {
	bind_text(stmt, 1, inst.agent_instance_id); bind_text(stmt, 2, string(inst.owner_user_id)); bind_text(stmt, 3, inst.agent_id); bind_text(stmt, 4, inst.bridge_id); bind_text(stmt, 5, inst.display_name); bind_text(stmt, 6, inst.provider); bind_text(stmt, 7, inst.model); bind_text(stmt, 8, string(inst.project_id)); bind_text(stmt, 9, inst.project_path); bind_text(stmt, 10, inst.chain_id); bind_text(stmt, 11, inst.conversation_id); bind_text(stmt, 12, inst.runtime_status); bind_text(stmt, 13, inst.startup_status); bind_text(stmt, 14, inst.activity_status); bind_text(stmt, 15, inst.status_message); bind_text(stmt, 16, i32_to_string(inst.last_applied_seq)); bind_text(stmt, 17, i32_to_string(inst.run_count)); bind_text(stmt, 18, inst.current_task_id); bind_text(stmt, 19, domain.current_task_role_string(inst.current_task_role)); bind_text(stmt, 20, inst.created_at); bind_text(stmt, 21, inst.updated_at); bind_text(stmt, 22, inst.started_at); bind_text(stmt, 23, inst.stopped_at); bind_text(stmt, 24, inst.last_seen_at); bind_text(stmt, 25, "agent" if inst.kind == "" else inst.kind); bind_text(stmt, 26, i32_to_string(inst.configuration_revision)); bind_text(stmt, 27, inst.launch_epoch); bind_text(stmt, 28, inst.last_error_json); bind_text(stmt, 29, inst.idle_since); bind_text(stmt, 30, inst.stopped_by); bind_text(stmt, 31, domain.agent_instance_permission_mode_normalize(inst.permission_mode))
}

instance_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Agent_Instance {
	return domain.Agent_Instance{agent_instance_id = column_text(stmt, 0), owner_user_id = domain.User_ID(column_text(stmt, 1)), agent_id = column_text(stmt, 2), bridge_id = column_text(stmt, 3), display_name = column_text(stmt, 4), provider = column_text(stmt, 5), model = column_text(stmt, 6), project_id = domain.Project_ID(column_text(stmt, 7)), project_path = column_text(stmt, 8), chain_id = column_text(stmt, 9), conversation_id = column_text(stmt, 10), runtime_status = column_text(stmt, 11), startup_status = column_text(stmt, 12), activity_status = column_text(stmt, 13), status_message = column_text(stmt, 14), last_applied_seq = string_to_i32(column_text_unowned(stmt, 15)), run_count = string_to_i32(column_text_unowned(stmt, 16)), current_task_id = column_text(stmt, 17), current_task_role = domain.current_task_role_from_string(column_text_unowned(stmt, 18)), created_at = column_text(stmt, 19), updated_at = column_text(stmt, 20), started_at = column_text(stmt, 21), stopped_at = column_text(stmt, 22), last_seen_at = column_text(stmt, 23), kind = column_text(stmt, 24), configuration_revision = string_to_i32(column_text_unowned(stmt, 25)), launch_epoch = column_text(stmt, 26), last_error_json = column_text(stmt, 27), idle_since = column_text(stmt, 28), stopped_by = column_text(stmt, 29), provider_session_id = column_text(stmt, 30), provider_transcript_path = column_text(stmt, 31), extension_provider = column_text(stmt, 32), extension_version = column_text(stmt, 33), extension_capabilities = column_text(stmt, 34), extension_last_seen_at = column_text(stmt, 35), permission_mode = domain.agent_instance_permission_mode_normalize(column_text_unowned(stmt, 36)), agent_permission_mode = domain.agent_permission_mode_normalize(column_text_unowned(stmt, 37))}
}

agent_state_from_string :: proc(state: string) -> domain.Agent_State { if state == "archived" do return .Archived; return .Active }
i32_to_string :: proc(v: int) -> string { return fmt.tprintf("%d", v) }
string_to_i32 :: proc(v: string) -> int { parsed, ok := strconv.parse_int(v); if !ok do return 0; return int(parsed) }
