package sqlite

import "core:c"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Action_Repo_SQLite :: struct {
	conn: ^Conn,
}

Scheduled_Prompt_Repo_SQLite :: Action_Repo_SQLite

new_action_repository :: proc(impl: ^Action_Repo_SQLite, conn: ^Conn) -> iface.Action_Repository {
	impl.conn = conn
	return iface.Action_Repository{
		ctx = rawptr(impl),
		save = action_save_sqlite,
		get = action_get_sqlite,
		delete_action = action_delete_sqlite,
		delete_prompt = action_delete_sqlite,
		list = action_list_sqlite,
		list_by_instance = action_list_by_instance_sqlite,
		list_by_bridge = action_list_by_bridge_sqlite,
		cas_lease = action_cas_lease_sqlite,
		max_updated_at_for_bridge = action_max_updated_at_for_bridge_sqlite,
	}
}

new_scheduled_prompt_repository :: new_action_repository

action_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Action {
	action: domain.Action
	action.id = domain.Action_ID(column_text(stmt, 0))
	action.owner_user_id = domain.User_ID(column_text(stmt, 1))
	action.target_instance_id = domain.Agent_Instance_ID(column_text(stmt, 2))
	action.prompt_text = column_text(stmt, 3)
	action.cron_expr = column_text(stmt, 4)
	action.timezone = column_text(stmt, 5)
	if action.timezone == "" do action.timezone = "UTC"
	action.blackout_dates = column_text(stmt, 6)
	if action.blackout_dates == "" do action.blackout_dates = "[]"
	action.active_from = column_text(stmt, 7)
	action.active_until = column_text(stmt, 8)
	action.target_run_at = column_text(stmt, 9)
	action.interval = column_text(stmt, 10)

	state_str := column_text(stmt, 11)
	switch state_str {
	case "in_flight": action.state = .In_Flight
	case "completed": action.state = .Completed
	case: action.state = .Active
	}

	action.in_flight = column_text(stmt, 12) == "1"
	action.leased_at = column_text(stmt, 13)
	action.deleted_at = column_text(stmt, 14)
	action.created_at = column_text(stmt, 15)
	action.updated_at = column_text(stmt, 16)
	action.target_agent_id = domain.Agent_ID(column_text(stmt, 17))
	action.target_bridge_id = domain.Bridge_ID(column_text(stmt, 18))
	action.target_provider = column_text(stmt, 19)
	action.target_model = column_text(stmt, 20)
	action.target_project_id = domain.Project_ID(column_text(stmt, 21))
	action.instance_strategy = column_text(stmt, 22)
	if action.instance_strategy == "" do action.instance_strategy = "reuse"
	action.last_spawned_instance_id = domain.Agent_Instance_ID(column_text(stmt, 23))
	return action
}

action_save_sqlite :: proc(ctx: rawptr, action: domain.Action) -> (domain.Action, bool, domain.Domain_Error) {
	impl := (^Action_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return domain.Action{}, false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := `INSERT INTO actions (
		id, owner_user_id, target_instance_id, prompt_text,
		cron_expr, timezone, blackout_dates, active_from, active_until,
		target_run_at, interval, state, in_flight, leased_at, deleted_at,
		created_at, updated_at, target_agent_id, target_bridge_id,
		target_provider, target_model, target_project_id,
		instance_strategy, last_spawned_instance_id
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	ON CONFLICT(id) DO UPDATE SET
		target_instance_id=excluded.target_instance_id,
		prompt_text=excluded.prompt_text,
		cron_expr=excluded.cron_expr,
		timezone=excluded.timezone,
		blackout_dates=excluded.blackout_dates,
		active_from=excluded.active_from,
		active_until=excluded.active_until,
		target_run_at=excluded.target_run_at,
		interval=excluded.interval,
		state=excluded.state,
		in_flight=excluded.in_flight,
		leased_at=excluded.leased_at,
		deleted_at=excluded.deleted_at,
		updated_at=excluded.updated_at,
		target_agent_id=excluded.target_agent_id,
		target_bridge_id=excluded.target_bridge_id,
		target_provider=excluded.target_provider,
		target_model=excluded.target_model,
		target_project_id=excluded.target_project_id,
		instance_strategy=excluded.instance_strategy,
		last_spawned_instance_id=excluded.last_spawned_instance_id;`
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return domain.Action{}, false, domain.domain_error(.Internal_Error, "failed to prepare action save")
	}
	defer sqlite3_finalize(stmt)

	state_str := "active"
	switch action.state {
	case .In_Flight: state_str = "in_flight"
	case .Completed: state_str = "completed"
	case .Active: state_str = "active"
	}

	tz := action.timezone
	if tz == "" do tz = "UTC"

	blackout := action.blackout_dates
	if blackout == "" do blackout = "[]"

	bind_text(stmt, 1, string(action.id))
	bind_text(stmt, 2, string(action.owner_user_id))
	bind_text(stmt, 3, string(action.target_instance_id))
	bind_text(stmt, 4, action.prompt_text)
	bind_text(stmt, 5, action.cron_expr)
	bind_text(stmt, 6, tz)
	bind_text(stmt, 7, blackout)
	bind_text(stmt, 8, action.active_from)
	bind_text(stmt, 9, action.active_until)
	bind_text(stmt, 10, action.target_run_at)
	bind_text(stmt, 11, action.interval)
	bind_text(stmt, 12, state_str)
	bind_text(stmt, 13, "1" if action.in_flight else "0")
	bind_text(stmt, 14, action.leased_at)
	bind_text(stmt, 15, action.deleted_at)
	bind_text(stmt, 16, action.created_at)
	bind_text(stmt, 17, action.updated_at)
	bind_text(stmt, 18, string(action.target_agent_id))
	bind_text(stmt, 19, string(action.target_bridge_id))
	bind_text(stmt, 20, action.target_provider)
	bind_text(stmt, 21, action.target_model)
	bind_text(stmt, 22, string(action.target_project_id))
	strategy := action.instance_strategy
	if strategy == "" do strategy = "reuse"
	bind_text(stmt, 23, strategy)
	bind_text(stmt, 24, string(action.last_spawned_instance_id))

	if sqlite3_step(stmt) != SQLITE_DONE {
		return domain.Action{}, false, domain.domain_error(.Conflict, "action could not be saved")
	}
	saved := action
	saved.timezone = tz
	saved.blackout_dates = blackout
	saved.instance_strategy = strategy
	return saved, true, domain.Domain_Error{}
}

action_get_sqlite :: proc(ctx: rawptr, id: domain.Action_ID) -> (domain.Action, bool, domain.Domain_Error) {
	impl := (^Action_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return domain.Action{}, false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "SELECT id, owner_user_id, target_instance_id, prompt_text, cron_expr, timezone, blackout_dates, active_from, active_until, target_run_at, interval, state, in_flight, leased_at, deleted_at, created_at, updated_at, target_agent_id, target_bridge_id, target_provider, target_model, target_project_id, instance_strategy, last_spawned_instance_id FROM actions WHERE id = ? AND deleted_at = '';"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return domain.Action{}, false, domain.domain_error(.Internal_Error, "failed to prepare action lookup")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(id))
	if sqlite3_step(stmt) != SQLITE_ROW {
		return domain.Action{}, false, domain.domain_error(.Not_Found, "action not found")
	}
	return action_from_stmt(stmt), true, domain.Domain_Error{}
}

action_delete_sqlite :: proc(ctx: rawptr, id: domain.Action_ID) -> (bool, domain.Domain_Error) {
	impl := (^Action_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "UPDATE actions SET deleted_at = datetime('now'), updated_at = datetime('now') WHERE id = ? AND deleted_at = '';"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return false, domain.domain_error(.Internal_Error, "failed to prepare action delete")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(id))
	step_rc, row_changes := step_changes(impl.conn.db, stmt)
	if step_rc != SQLITE_DONE {
		return false, domain.domain_error(.Internal_Error, "failed to delete action")
	}
	return row_changes > 0, domain.Domain_Error{}
}

action_list_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Action, domain.Domain_Error) {
	impl := (^Action_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return nil, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "SELECT id, owner_user_id, target_instance_id, prompt_text, cron_expr, timezone, blackout_dates, active_from, active_until, target_run_at, interval, state, in_flight, leased_at, deleted_at, created_at, updated_at, target_agent_id, target_bridge_id, target_provider, target_model, target_project_id, instance_strategy, last_spawned_instance_id FROM actions WHERE owner_user_id = ? AND deleted_at = '' ORDER BY target_run_at ASC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare action list")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner_user_id))

	items := make([dynamic]domain.Action)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&items, action_from_stmt(stmt))
	}
	return items[:], domain.Domain_Error{}
}

action_list_by_instance_sqlite :: proc(ctx: rawptr, instance_id: domain.Agent_Instance_ID) -> ([]domain.Action, domain.Domain_Error) {
	impl := (^Action_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return nil, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "SELECT id, owner_user_id, target_instance_id, prompt_text, cron_expr, timezone, blackout_dates, active_from, active_until, target_run_at, interval, state, in_flight, leased_at, deleted_at, created_at, updated_at, target_agent_id, target_bridge_id, target_provider, target_model, target_project_id, instance_strategy, last_spawned_instance_id FROM actions WHERE target_instance_id = ? AND deleted_at = '' ORDER BY target_run_at ASC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare action list by instance")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(instance_id))

	items := make([dynamic]domain.Action)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&items, action_from_stmt(stmt))
	}
	return items[:], domain.Domain_Error{}
}

action_list_by_bridge_sqlite :: proc(ctx: rawptr, bridge_id: domain.Bridge_ID) -> ([]domain.Action, domain.Domain_Error) {
	impl := (^Action_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return nil, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := `SELECT id, owner_user_id, target_instance_id, prompt_text, cron_expr, timezone, blackout_dates, active_from, active_until, target_run_at, interval, state, in_flight, leased_at, deleted_at, created_at, updated_at, target_agent_id, target_bridge_id, target_provider, target_model, target_project_id, instance_strategy, last_spawned_instance_id
		FROM actions
		WHERE (target_bridge_id = ? OR target_instance_id IN (SELECT agent_instance_id FROM agent_instances WHERE bridge_id = ?))
		  AND deleted_at = ''
		ORDER BY target_run_at ASC;`
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare action list by bridge")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(bridge_id))
	bind_text(stmt, 2, string(bridge_id))

	items := make([dynamic]domain.Action)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&items, action_from_stmt(stmt))
	}
	return items[:], domain.Domain_Error{}
}

action_cas_lease_sqlite :: proc(ctx: rawptr, id: domain.Action_ID, leased_at: string, now: string) -> (bool, domain.Domain_Error) {
	impl := (^Action_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "UPDATE actions SET in_flight = 1, leased_at = ?, state = 'in_flight', updated_at = ? WHERE id = ? AND in_flight = 0 AND target_run_at <= ? AND deleted_at = '';"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return false, domain.domain_error(.Internal_Error, "failed to prepare action cas lease")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, leased_at)
	bind_text(stmt, 2, leased_at)
	bind_text(stmt, 3, string(id))
	bind_text(stmt, 4, now)

	step_rc, row_changes := step_changes(impl.conn.db, stmt)
	if step_rc != SQLITE_DONE {
		return false, domain.domain_error(.Internal_Error, "failed to execute cas lease")
	}
	return row_changes > 0, domain.Domain_Error{}
}

action_max_updated_at_for_bridge_sqlite :: proc(ctx: rawptr, bridge_id: domain.Bridge_ID) -> (string, domain.Domain_Error) {
	impl := (^Action_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return "", domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := `SELECT COALESCE(MAX(a.updated_at), '')
		FROM actions a
		LEFT JOIN agent_instances ai ON a.target_instance_id = ai.agent_instance_id
		WHERE (ai.bridge_id = ? OR a.target_bridge_id = ?) AND a.deleted_at = '';`
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return "", domain.domain_error(.Internal_Error, "failed to prepare action max updated_at lookup")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(bridge_id))
	bind_text(stmt, 2, string(bridge_id))

	if sqlite3_step(stmt) == SQLITE_ROW {
		return column_text(stmt, 0), domain.Domain_Error{}
	}
	return "", domain.Domain_Error{}
}
