package sqlite

import "core:c"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Taskchain_Repo_SQLite :: struct {
	conn: ^Conn,
}

new_taskchain_repository :: proc(impl: ^Taskchain_Repo_SQLite, conn: ^Conn) -> iface.Taskchain_Repository {
	impl.conn = conn
	return iface.Taskchain_Repository{
		ctx = rawptr(impl),
		get_chain = taskchain_get_chain_sqlite,
		list_chains_by_owner = taskchain_list_chains_by_owner_sqlite,
		count_pinned_chains = taskchain_count_pinned_chains_sqlite,
		list_pinned_chains = taskchain_list_pinned_chains_sqlite,
		save_chain = taskchain_save_chain_sqlite,
		save_task = task_save_sqlite,
		get_task = task_get_sqlite,
		list_tasks_by_chain = task_list_by_chain_sqlite,
		task_counts_by_chain = task_counts_by_chain_sqlite,
		save_comment = task_comment_save_sqlite,
		list_comments_by_task = task_comment_list_by_task_sqlite,
		comment_summary_by_task = task_comment_summary_sqlite,
		list_recent_comments_by_task = task_comment_list_recent_sqlite,
		save_member = taskchain_save_member_sqlite,
		remove_member = taskchain_remove_member_sqlite,
		list_members_by_chain = taskchain_list_members_by_chain_sqlite,
		list_chains_by_coordinator = taskchain_list_chains_by_coordinator_sqlite,
		save_dependency = taskchain_save_dependency_sqlite,
		remove_dependency = taskchain_remove_dependency_sqlite,
		list_dependencies_by_chain = taskchain_list_dependencies_by_chain_sqlite,
		save_vote = taskchain_save_vote_sqlite,
		list_votes_by_task = taskchain_list_votes_by_task_sqlite,
		delete_votes_by_task = taskchain_delete_votes_by_task_sqlite,
		save_directory = taskchain_save_directory_sqlite,
		get_directory = taskchain_get_directory_sqlite,
		list_directories_by_chain = taskchain_list_directories_by_chain_sqlite,
		remove_directory = taskchain_remove_directory_sqlite,
		upsert_fleet = taskchain_upsert_fleet_sqlite,
		ensure_fleet = taskchain_ensure_fleet_sqlite,
		list_fleets_by_chain = taskchain_list_fleets_by_chain_sqlite,
		delete_fleet = taskchain_delete_fleet_sqlite,
		save_subscription = taskchain_save_subscription_sqlite,
		remove_subscription = taskchain_remove_subscription_sqlite,
		list_subscriptions_by_chain = taskchain_list_subscriptions_by_chain_sqlite,
		list_subscriptions_by_task = taskchain_list_subscriptions_by_task_sqlite,
		list_subscriptions_by_instance = taskchain_list_subscriptions_by_instance_sqlite,
	}
}

taskchain_get_chain_sqlite :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT chain_id, owner_user_id, title, description, publish_state, status, kind, coordinator_agent_instance_id, default_reviewer_refs_json, created_at, updated_at, published_at, completed_at, last_activity_at, last_title_nudge_at, title_source, is_pinned, pinned_at FROM task_chains WHERE chain_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Task_Chain{}, false, domain.domain_error(.Internal_Error, "failed to prepare chain lookup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(chain_id))
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Task_Chain{}, false, domain.domain_error(.Not_Found, "task chain not found")
	return chain_from_stmt(stmt), true, domain.Domain_Error{}
}

taskchain_list_chains_by_owner_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Task_Chain, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT chain_id, owner_user_id, title, description, publish_state, status, kind, coordinator_agent_instance_id, default_reviewer_refs_json, created_at, updated_at, published_at, completed_at, last_activity_at, last_title_nudge_at, title_source, is_pinned, pinned_at FROM task_chains WHERE owner_user_id = ? ORDER BY updated_at DESC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare chain list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner_user_id))
	out := make([dynamic]domain.Task_Chain)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, chain_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

taskchain_save_chain_sqlite :: proc(ctx: rawptr, chain: domain.Task_Chain) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "INSERT INTO task_chains (chain_id, owner_user_id, title, description, publish_state, status, kind, coordinator_agent_instance_id, default_reviewer_refs_json, created_at, updated_at, published_at, completed_at, last_activity_at, last_title_nudge_at, title_source, is_pinned, pinned_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(chain_id) DO UPDATE SET title=excluded.title, description=excluded.description, publish_state=excluded.publish_state, status=excluded.status, kind=excluded.kind, coordinator_agent_instance_id=excluded.coordinator_agent_instance_id, default_reviewer_refs_json=excluded.default_reviewer_refs_json, updated_at=excluded.updated_at, published_at=excluded.published_at, completed_at=excluded.completed_at, last_activity_at=excluded.last_activity_at, last_title_nudge_at=excluded.last_title_nudge_at, title_source=excluded.title_source, is_pinned=excluded.is_pinned, pinned_at=excluded.pinned_at;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Task_Chain{}, false, domain.domain_error(.Internal_Error, "failed to prepare chain save")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(chain.chain_id)); bind_text(stmt, 2, string(chain.owner_user_id)); bind_text(stmt, 3, chain.title); bind_text(stmt, 4, chain.description); bind_text(stmt, 5, publish_state_string(chain.publish_state)); bind_text(stmt, 6, chain_status_string(chain.status)); bind_text(stmt, 7, chain.kind); bind_text(stmt, 8, chain.coordinator_agent_instance_id); bind_text(stmt, 9, json_or_empty_array(chain.default_reviewer_refs_json)); bind_text(stmt, 10, chain.created_at); bind_text(stmt, 11, chain.updated_at); bind_text(stmt, 12, chain.published_at); bind_text(stmt, 13, chain.completed_at); bind_text(stmt, 14, chain.last_activity_at); bind_text(stmt, 15, chain.last_title_nudge_at); bind_text(stmt, 16, normalize_title_source(chain.title_source)); sqlite3_bind_int(stmt, 17, 1 if chain.is_pinned else 0); bind_text(stmt, 18, chain.pinned_at)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.Task_Chain{}, false, domain.domain_error(.Conflict, "task chain could not be saved")
	return chain, true, domain.Domain_Error{}
}

task_save_sqlite :: proc(ctx: rawptr, task: domain.Task) -> (domain.Task, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "INSERT INTO tasks (task_id, chain_id, owner_user_id, title, description, publish_state, status, priority, assignee_ref_json, reviewer_refs_json, created_at, updated_at, published_at, started_at, completed_at, bridge_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(task_id) DO UPDATE SET title=excluded.title, description=excluded.description, publish_state=excluded.publish_state, status=excluded.status, priority=excluded.priority, assignee_ref_json=excluded.assignee_ref_json, reviewer_refs_json=excluded.reviewer_refs_json, updated_at=excluded.updated_at, published_at=excluded.published_at, started_at=excluded.started_at, completed_at=excluded.completed_at, bridge_id=excluded.bridge_id;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Task{}, false, domain.domain_error(.Internal_Error, "failed to prepare task save")
	defer sqlite3_finalize(stmt)
	bind_task(stmt, task)
	// UPSERT: the DO UPDATE branch fires the tasks_fts AFTER UPDATE trigger, which
	// can hit SQLITE_CORRUPT if the fts index drifted (see fts_repair.odin).
	// step_write_healing re-syncs the index and retries once; report an accurate
	// error rather than a misleading save conflict if it still fails.
	rc := step_write_healing(impl.conn, stmt)
	if rc != SQLITE_DONE {
		if rc == SQLITE_CORRUPT do return domain.Task{}, false, domain.domain_error(.Internal_Error, "task save failed: search index drift (SQLITE_CORRUPT) — run the FTS reconcile/repair")
		return domain.Task{}, false, domain.domain_error(.Conflict, "task could not be saved")
	}
	return task, true, domain.Domain_Error{}
}

task_get_sqlite :: proc(ctx: rawptr, task_id: domain.Task_ID) -> (domain.Task, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT task_id, chain_id, owner_user_id, title, description, publish_state, status, priority, assignee_ref_json, reviewer_refs_json, created_at, updated_at, published_at, started_at, completed_at, bridge_id FROM tasks WHERE task_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Task{}, false, domain.domain_error(.Internal_Error, "failed to prepare task lookup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(task_id))
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Task{}, false, domain.domain_error(.Not_Found, "task not found")
	return task_from_stmt(stmt), true, domain.Domain_Error{}
}

task_list_by_chain_sqlite :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> ([]domain.Task, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT task_id, chain_id, owner_user_id, title, description, publish_state, status, priority, assignee_ref_json, reviewer_refs_json, created_at, updated_at, published_at, started_at, completed_at, bridge_id FROM tasks WHERE chain_id = ? AND owner_user_id = ? ORDER BY created_at ASC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare task list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(chain_id)); bind_text(stmt, 2, string(owner_user_id))
	out := make([dynamic]domain.Task)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, task_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

task_comment_save_sqlite :: proc(ctx: rawptr, comment: domain.Task_Comment) -> (domain.Task_Comment, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "INSERT INTO task_comments (comment_id, task_id, chain_id, owner_user_id, author_agent_instance_id, body, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(comment_id) DO UPDATE SET body=excluded.body, updated_at=excluded.updated_at;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Task_Comment{}, false, domain.domain_error(.Internal_Error, "failed to prepare task comment save")
	defer sqlite3_finalize(stmt)
	bind_comment(stmt, comment)
	// Editing an existing comment takes the DO UPDATE branch (task_comments_fts AU
	// trigger); self-heal fts drift + retry once, else surface an accurate error.
	rc := step_write_healing(impl.conn, stmt)
	if rc != SQLITE_DONE {
		if rc == SQLITE_CORRUPT do return domain.Task_Comment{}, false, domain.domain_error(.Internal_Error, "task comment save failed: search index drift (SQLITE_CORRUPT) — run the FTS reconcile/repair")
		return domain.Task_Comment{}, false, domain.domain_error(.Conflict, "task comment could not be saved")
	}
	return comment, true, domain.Domain_Error{}
}

task_comment_list_by_task_sqlite :: proc(ctx: rawptr, task_id: domain.Task_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Comment, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT comment_id, task_id, chain_id, owner_user_id, author_agent_instance_id, body, created_at, updated_at FROM task_comments WHERE task_id = ? AND owner_user_id = ? ORDER BY created_at ASC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare task comment list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(task_id)); bind_text(stmt, 2, string(owner_user_id))
	out := make([dynamic]domain.Task_Comment)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, task_comment_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

// task_counts_by_chain_sqlite rolls up every chain's task counts (total,
// completed, and user validation) for one owner in a single grouped query,
// backed by idx_tasks_chain_owner (migration 025). Chains with no tasks are
// simply absent from the map; callers read a missing key as 0.
task_counts_by_chain_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> (map[string]iface.Chain_Task_Rollup, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	out := make(map[string]iface.Chain_Task_Rollup)
	stmt: sqlite3_stmt = nil
	q := "SELECT chain_id, COUNT(*), SUM(CASE WHEN status IN ('completed', 'validated_good') THEN 1 ELSE 0 END), SUM(CASE WHEN status = 'in_validation' AND (reviewer_refs_json LIKE '%\"type\":\"user\"%' OR reviewer_refs_json = '[]' OR reviewer_refs_json LIKE '%user%') THEN 1 ELSE 0 END) FROM tasks WHERE owner_user_id = ? GROUP BY chain_id;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return out, domain.domain_error(.Internal_Error, "failed to prepare task count rollup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner_user_id))
	for sqlite3_step(stmt) == SQLITE_ROW {
		cid := strings.clone(column_text(stmt, 0))
		out[cid] = iface.Chain_Task_Rollup{
			total_count = int_v(column_text(stmt, 1)),
			completed_count = int_v(column_text(stmt, 2)),
			user_validation_count = int_v(column_text(stmt, 3)),
		}
	}
	return out, domain.Domain_Error{}
}

// task_comment_summary_sqlite computes the compact rollup cheaply: COUNT(*) plus
// the newest comment's author + body (for the preview) in a single indexed pass.
// No full comment bodies are loaded for the count.
task_comment_summary_sqlite :: proc(ctx: rawptr, task_id: domain.Task_ID, owner_user_id: domain.User_ID) -> (domain.Task_Comment_Summary, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	out := domain.Task_Comment_Summary{}
	// count
	{
		stmt: sqlite3_stmt = nil
		q := "SELECT COUNT(*) FROM task_comments WHERE task_id = ? AND owner_user_id = ?;"
		if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return out, domain.domain_error(.Internal_Error, "failed to prepare comment count")
		defer sqlite3_finalize(stmt)
		bind_text(stmt, 1, string(task_id)); bind_text(stmt, 2, string(owner_user_id))
		if sqlite3_step(stmt) == SQLITE_ROW do out.count = int_v(column_text(stmt, 0))
	}
	if out.count == 0 do return out, domain.Domain_Error{}
	// newest comment: author + created_at + body (for preview)
	{
		stmt: sqlite3_stmt = nil
		q := "SELECT author_agent_instance_id, body, created_at FROM task_comments WHERE task_id = ? AND owner_user_id = ? ORDER BY created_at DESC, comment_id DESC LIMIT 1;"
		if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return out, domain.domain_error(.Internal_Error, "failed to prepare comment last row")
		defer sqlite3_finalize(stmt)
		bind_text(stmt, 1, string(task_id)); bind_text(stmt, 2, string(owner_user_id))
		if sqlite3_step(stmt) == SQLITE_ROW {
			out.last_comment_author = column_text(stmt, 0)
			body := column_text(stmt, 1)
			out.last_comment_at = column_text(stmt, 2)
			out.last_comment_preview = comment_preview(body)
		}
	}
	return out, domain.Domain_Error{}
}

// comment_preview truncates to TASK_COMMENT_PREVIEW_MAX runes, appending an
// ellipsis when the body was longer. Rune-safe so multibyte text is not cut.
comment_preview :: proc(body: string) -> string {
	trimmed := strings.trim_space(body)
	if strings.contains(trimmed, "vault:v1:") {
		return strings.clone(trimmed)
	}
	runes := 0
	for _, i in trimmed {
		runes += 1
		if runes > domain.TASK_COMMENT_PREVIEW_MAX {
			return strings.concatenate({trimmed[:i], "\u2026"})
		}
	}
	return trimmed
}

// task_comment_list_recent_sqlite returns the newest `last` comments in ascending
// order (or all when last <= 0). Uses a bounded subquery so only N rows are read.
task_comment_list_recent_sqlite :: proc(ctx: rawptr, task_id: domain.Task_ID, owner_user_id: domain.User_ID, last: int) -> ([]domain.Task_Comment, domain.Domain_Error) {
	if last <= 0 do return task_comment_list_by_task_sqlite(ctx, task_id, owner_user_id)
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	// newest N by created_at, then re-sort ascending so the caller sees chrono
	// order. LIMIT is a validated non-negative int (int_s), safe to inline.
	query := strings.concatenate({"SELECT comment_id, task_id, chain_id, owner_user_id, author_agent_instance_id, body, created_at, updated_at FROM (SELECT * FROM task_comments WHERE task_id = ? AND owner_user_id = ? ORDER BY created_at DESC, comment_id DESC LIMIT ", int_s(last), ") ORDER BY created_at ASC, comment_id ASC;"})
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare recent comment list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(task_id)); bind_text(stmt, 2, string(owner_user_id))
	out := make([dynamic]domain.Task_Comment)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, task_comment_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

taskchain_save_member_sqlite :: proc(ctx: rawptr, member: domain.Task_Chain_Member) -> (domain.Task_Chain_Member, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "INSERT INTO task_chain_members (chain_id, agent_instance_id, agent_id, owner_user_id, role, created_at) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(chain_id, agent_instance_id) DO UPDATE SET role=excluded.role, agent_id=excluded.agent_id;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Task_Chain_Member{}, false, domain.domain_error(.Internal_Error, "failed to prepare member save")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(member.chain_id)); bind_text(stmt, 2, member.agent_instance_id); bind_text(stmt, 3, member.agent_id); bind_text(stmt, 4, string(member.owner_user_id)); bind_text(stmt, 5, member.role); bind_text(stmt, 6, member.created_at)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.Task_Chain_Member{}, false, domain.domain_error(.Conflict, "member could not be saved")
	return member, true, domain.Domain_Error{}
}

taskchain_remove_member_sqlite :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, agent_instance_id: string, owner_user_id: domain.User_ID) -> (bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "DELETE FROM task_chain_members WHERE chain_id = ? AND agent_instance_id = ? AND owner_user_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return false, domain.domain_error(.Internal_Error, "failed to prepare member removal")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(chain_id)); bind_text(stmt, 2, agent_instance_id); bind_text(stmt, 3, string(owner_user_id))
	if sqlite3_step(stmt) != SQLITE_DONE do return false, domain.domain_error(.Internal_Error, "failed to remove member")
	return true, domain.Domain_Error{}
}

taskchain_list_members_by_chain_sqlite :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Chain_Member, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT chain_id, agent_instance_id, agent_id, owner_user_id, role, created_at FROM task_chain_members WHERE chain_id = ? AND owner_user_id = ? ORDER BY created_at ASC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare member list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(chain_id)); bind_text(stmt, 2, string(owner_user_id))
	out := make([dynamic]domain.Task_Chain_Member)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, member_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

// H9 reverse query: the chains an agent instance coordinates (canonical members
// table, role='coordinator'), owner-scoped. Joins so authority derives from the
// single source, not the derived mirror column.
taskchain_list_chains_by_coordinator_sqlite :: proc(ctx: rawptr, agent_instance_id: string, owner_user_id: domain.User_ID) -> ([]domain.Task_Chain, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT c.chain_id, c.owner_user_id, c.title, c.description, c.publish_state, c.status, c.kind, c.coordinator_agent_instance_id, c.default_reviewer_refs_json, c.created_at, c.updated_at, c.published_at, c.completed_at, c.last_activity_at, c.last_title_nudge_at, c.title_source, c.is_pinned, c.pinned_at FROM task_chains c JOIN task_chain_members m ON m.chain_id = c.chain_id AND m.owner_user_id = c.owner_user_id WHERE m.role = 'coordinator' AND m.agent_instance_id = ? AND c.owner_user_id = ? ORDER BY c.updated_at DESC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare chains-by-coordinator list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, agent_instance_id); bind_text(stmt, 2, string(owner_user_id))
	out := make([dynamic]domain.Task_Chain)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, chain_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

taskchain_save_dependency_sqlite :: proc(ctx: rawptr, dep: domain.Task_Dependency) -> (domain.Task_Dependency, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "INSERT INTO task_dependencies (task_id, depends_on_task_id, chain_id, owner_user_id, created_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT(task_id, depends_on_task_id) DO NOTHING;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Task_Dependency{}, false, domain.domain_error(.Internal_Error, "failed to prepare dependency save")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(dep.task_id)); bind_text(stmt, 2, string(dep.depends_on_task_id)); bind_text(stmt, 3, string(dep.chain_id)); bind_text(stmt, 4, string(dep.owner_user_id)); bind_text(stmt, 5, dep.created_at)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.Task_Dependency{}, false, domain.domain_error(.Conflict, "dependency could not be saved")
	return dep, true, domain.Domain_Error{}
}

taskchain_remove_dependency_sqlite :: proc(ctx: rawptr, task_id: domain.Task_ID, depends_on_task_id: domain.Task_ID, owner_user_id: domain.User_ID) -> (bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "DELETE FROM task_dependencies WHERE task_id = ? AND depends_on_task_id = ? AND owner_user_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return false, domain.domain_error(.Internal_Error, "failed to prepare dependency removal")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(task_id)); bind_text(stmt, 2, string(depends_on_task_id)); bind_text(stmt, 3, string(owner_user_id))
	if sqlite3_step(stmt) != SQLITE_DONE do return false, domain.domain_error(.Internal_Error, "failed to remove dependency")
	return true, domain.Domain_Error{}
}

taskchain_list_dependencies_by_chain_sqlite :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Dependency, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT task_id, depends_on_task_id, chain_id, owner_user_id, created_at FROM task_dependencies WHERE chain_id = ? AND owner_user_id = ? ORDER BY created_at ASC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare dependency list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(chain_id)); bind_text(stmt, 2, string(owner_user_id))
	out := make([dynamic]domain.Task_Dependency)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, dependency_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

taskchain_save_vote_sqlite :: proc(ctx: rawptr, vote: domain.Task_Vote) -> (domain.Task_Vote, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "INSERT INTO task_votes (task_id, reviewer_agent_instance_id, chain_id, owner_user_id, vote, comment, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(task_id, reviewer_agent_instance_id) DO UPDATE SET vote=excluded.vote, comment=excluded.comment, updated_at=excluded.updated_at;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Task_Vote{}, false, domain.domain_error(.Internal_Error, "failed to prepare vote save")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(vote.task_id)); bind_text(stmt, 2, vote.reviewer_agent_instance_id); bind_text(stmt, 3, string(vote.chain_id)); bind_text(stmt, 4, string(vote.owner_user_id)); bind_text(stmt, 5, vote.vote); bind_text(stmt, 6, vote.comment); bind_text(stmt, 7, vote.created_at); bind_text(stmt, 8, vote.updated_at)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.Task_Vote{}, false, domain.domain_error(.Conflict, "vote could not be saved")
	return vote, true, domain.Domain_Error{}
}

taskchain_list_votes_by_task_sqlite :: proc(ctx: rawptr, task_id: domain.Task_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Vote, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT task_id, reviewer_agent_instance_id, chain_id, owner_user_id, vote, comment, created_at, updated_at FROM task_votes WHERE task_id = ? AND owner_user_id = ? ORDER BY created_at ASC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare vote list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(task_id)); bind_text(stmt, 2, string(owner_user_id))
	out := make([dynamic]domain.Task_Vote)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, vote_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

taskchain_delete_votes_by_task_sqlite :: proc(ctx: rawptr, task_id: domain.Task_ID, owner_user_id: domain.User_ID) -> (int, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "DELETE FROM task_votes WHERE task_id = ? AND owner_user_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return 0, domain.domain_error(.Internal_Error, "failed to prepare vote deletion")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(task_id)); bind_text(stmt, 2, string(owner_user_id))
	if sqlite3_step(stmt) != SQLITE_DONE do return 0, domain.domain_error(.Internal_Error, "failed to delete task votes")
	changes := int(sqlite3_changes(impl.conn.db))
	return changes, domain.Domain_Error{}
}

taskchain_save_directory_sqlite :: proc(ctx: rawptr, dir: domain.Task_Chain_Directory) -> (domain.Task_Chain_Directory, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "INSERT INTO task_chain_directories (directory_id, chain_id, owner_user_id, path, bridge_id, vcs_kind, vcs_info_json, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(directory_id) DO UPDATE SET path=excluded.path, bridge_id=excluded.bridge_id, vcs_kind=excluded.vcs_kind, vcs_info_json=excluded.vcs_info_json, updated_at=excluded.updated_at;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Task_Chain_Directory{}, false, domain.domain_error(.Internal_Error, "failed to prepare directory save")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, dir.directory_id)
	bind_text(stmt, 2, string(dir.chain_id))
	bind_text(stmt, 3, string(dir.owner_user_id))
	bind_text(stmt, 4, dir.path)
	bind_text(stmt, 5, dir.bridge_id)
	bind_text(stmt, 6, dir.vcs_kind)
	bind_text(stmt, 7, json_or_empty_object(dir.vcs_info_json))
	bind_text(stmt, 8, dir.created_at)
	bind_text(stmt, 9, dir.updated_at)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.Task_Chain_Directory{}, false, domain.domain_error(.Conflict, "directory could not be saved")
	return dir, true, domain.Domain_Error{}
}

taskchain_get_directory_sqlite :: proc(ctx: rawptr, directory_id: string, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> (domain.Task_Chain_Directory, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT directory_id, chain_id, owner_user_id, path, bridge_id, vcs_kind, vcs_info_json, created_at, updated_at FROM task_chain_directories WHERE directory_id = ? AND chain_id = ? AND owner_user_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Task_Chain_Directory{}, false, domain.domain_error(.Internal_Error, "failed to prepare directory lookup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, directory_id)
	bind_text(stmt, 2, string(chain_id))
	bind_text(stmt, 3, string(owner_user_id))
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Task_Chain_Directory{}, false, domain.domain_error(.Not_Found, "directory not found")
	return directory_from_stmt(stmt), true, domain.Domain_Error{}
}

taskchain_list_directories_by_chain_sqlite :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Chain_Directory, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT directory_id, chain_id, owner_user_id, path, bridge_id, vcs_kind, vcs_info_json, created_at, updated_at FROM task_chain_directories WHERE chain_id = ? AND owner_user_id = ? ORDER BY created_at ASC, directory_id ASC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare directory list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(chain_id))
	bind_text(stmt, 2, string(owner_user_id))
	out := make([dynamic]domain.Task_Chain_Directory)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, directory_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

taskchain_remove_directory_sqlite :: proc(ctx: rawptr, directory_id: string, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> (bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "DELETE FROM task_chain_directories WHERE directory_id = ? AND chain_id = ? AND owner_user_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return false, domain.domain_error(.Internal_Error, "failed to prepare directory deletion")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, directory_id)
	bind_text(stmt, 2, string(chain_id))
	bind_text(stmt, 3, string(owner_user_id))
	if sqlite3_step(stmt) != SQLITE_DONE do return false, domain.domain_error(.Internal_Error, "failed to delete directory")
	changes := int(sqlite3_changes(impl.conn.db))
	return changes > 0, domain.Domain_Error{}
}

fleet_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Task_Chain_Fleet {
	return domain.Task_Chain_Fleet{
		task_chain_id    = domain.Task_Chain_ID(column_text(stmt, 0)),
		agent_id         = column_text(stmt, 1),
		capacity         = int_v(column_text_unowned(stmt, 2)),
		min_warm         = int_v(column_text_unowned(stmt, 3)),
		idle_ttl_seconds = int_v(column_text_unowned(stmt, 4)),
		provider         = column_text(stmt, 5),
		model             = column_text(stmt, 6),
		created_at       = column_text(stmt, 7),
		updated_at       = column_text(stmt, 8),
		bridge_models_json = column_text(stmt, 9),
	}
}

taskchain_upsert_fleet_sqlite :: proc(ctx: rawptr, fleet: domain.Task_Chain_Fleet) -> (domain.Task_Chain_Fleet, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "INSERT INTO task_chain_fleets (task_chain_id, agent_id, capacity, min_warm, idle_ttl_seconds, provider, model, created_at, updated_at, bridge_models_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(task_chain_id, agent_id) DO UPDATE SET capacity=excluded.capacity, min_warm=excluded.min_warm, idle_ttl_seconds=excluded.idle_ttl_seconds, provider=excluded.provider, model=excluded.model, updated_at=excluded.updated_at, bridge_models_json=excluded.bridge_models_json;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Task_Chain_Fleet{}, domain.domain_error(.Internal_Error, "failed to prepare fleet upsert")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(fleet.task_chain_id))
	bind_text(stmt, 2, fleet.agent_id)
	sqlite3_bind_int(stmt, 3, c.int(fleet.capacity))
	sqlite3_bind_int(stmt, 4, c.int(fleet.min_warm))
	sqlite3_bind_int(stmt, 5, c.int(fleet.idle_ttl_seconds))
	bind_text(stmt, 6, fleet.provider)
	bind_text(stmt, 7, fleet.model)
	bind_text(stmt, 8, fleet.created_at)
	bind_text(stmt, 9, fleet.updated_at)
	bind_text(stmt, 10, fleet.bridge_models_json if fleet.bridge_models_json != "" else "{}")
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.Task_Chain_Fleet{}, domain.domain_error(.Conflict, "fleet could not be saved")
	return fleet, domain.Domain_Error{}
}

taskchain_ensure_fleet_sqlite :: proc(ctx: rawptr, fleet: domain.Task_Chain_Fleet) -> domain.Domain_Error {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "INSERT INTO task_chain_fleets (task_chain_id, agent_id, capacity, min_warm, idle_ttl_seconds, provider, model, created_at, updated_at, bridge_models_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(task_chain_id, agent_id) DO NOTHING;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.domain_error(.Internal_Error, "failed to prepare fleet ensure")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(fleet.task_chain_id))
	bind_text(stmt, 2, fleet.agent_id)
	sqlite3_bind_int(stmt, 3, c.int(fleet.capacity))
	sqlite3_bind_int(stmt, 4, c.int(fleet.min_warm))
	sqlite3_bind_int(stmt, 5, c.int(fleet.idle_ttl_seconds))
	bind_text(stmt, 6, fleet.provider)
	bind_text(stmt, 7, fleet.model)
	bind_text(stmt, 8, fleet.created_at)
	bind_text(stmt, 9, fleet.updated_at)
	bind_text(stmt, 10, fleet.bridge_models_json if fleet.bridge_models_json != "" else "{}")
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.domain_error(.Conflict, "fleet could not be ensured")
	return domain.Domain_Error{}
}

taskchain_list_fleets_by_chain_sqlite :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Chain_Fleet, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT f.task_chain_id, f.agent_id, f.capacity, f.min_warm, f.idle_ttl_seconds, f.provider, f.model, f.created_at, f.updated_at, f.bridge_models_json FROM task_chain_fleets f JOIN task_chains tc ON f.task_chain_id = tc.chain_id WHERE f.task_chain_id = ? AND (tc.owner_user_id = ? OR ? = '') ORDER BY f.created_at ASC, f.agent_id ASC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare fleet list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(chain_id))
	bind_text(stmt, 2, string(owner_user_id))
	bind_text(stmt, 3, string(owner_user_id))
	out := make([dynamic]domain.Task_Chain_Fleet)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, fleet_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

taskchain_delete_fleet_sqlite :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, agent_id: string, owner_user_id: domain.User_ID) -> (bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "DELETE FROM task_chain_fleets WHERE task_chain_id = ? AND agent_id = ? AND task_chain_id IN (SELECT chain_id FROM task_chains WHERE chain_id = ? AND (owner_user_id = ? OR ? = ''));"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return false, domain.domain_error(.Internal_Error, "failed to prepare fleet deletion")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(chain_id))
	bind_text(stmt, 2, agent_id)
	bind_text(stmt, 3, string(chain_id))
	bind_text(stmt, 4, string(owner_user_id))
	bind_text(stmt, 5, string(owner_user_id))
	if sqlite3_step(stmt) != SQLITE_DONE do return false, domain.domain_error(.Internal_Error, "failed to delete fleet")
	changes := int(sqlite3_changes(impl.conn.db))
	return changes > 0, domain.Domain_Error{}
}

taskchain_save_subscription_sqlite :: proc(ctx: rawptr, sub: domain.Task_Subscription) -> (domain.Task_Subscription, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "INSERT INTO task_subscriptions (subscription_id, owner_user_id, subscriber_agent_instance_id, chain_id, task_id, event_type, created_at) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(subscriber_agent_instance_id, chain_id, task_id, event_type) DO UPDATE SET subscription_id=excluded.subscription_id, owner_user_id=excluded.owner_user_id, created_at=excluded.created_at;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Task_Subscription{}, false, domain.domain_error(.Internal_Error, "failed to prepare subscription save")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, sub.subscription_id)
	bind_text(stmt, 2, string(sub.owner_user_id))
	bind_text(stmt, 3, sub.subscriber_agent_instance_id)
	bind_text(stmt, 4, string(sub.chain_id))
	bind_text(stmt, 5, string(sub.task_id))
	bind_text(stmt, 6, sub.event_type)
	bind_text(stmt, 7, sub.created_at)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.Task_Subscription{}, false, domain.domain_error(.Conflict, "subscription could not be saved")
	return sub, true, domain.Domain_Error{}
}

taskchain_remove_subscription_sqlite :: proc(ctx: rawptr, subscription_id: string, owner_user_id: domain.User_ID) -> (bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "DELETE FROM task_subscriptions WHERE subscription_id = ? AND (? = '' OR owner_user_id = ?);"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return false, domain.domain_error(.Internal_Error, "failed to prepare subscription deletion")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, subscription_id)
	bind_text(stmt, 2, string(owner_user_id))
	bind_text(stmt, 3, string(owner_user_id))
	if sqlite3_step(stmt) != SQLITE_DONE do return false, domain.domain_error(.Internal_Error, "failed to delete subscription")
	changes := int(sqlite3_changes(impl.conn.db))
	return changes > 0, domain.Domain_Error{}
}

taskchain_list_subscriptions_by_chain_sqlite :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Subscription, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT subscription_id, owner_user_id, subscriber_agent_instance_id, chain_id, task_id, event_type, created_at FROM task_subscriptions WHERE chain_id = ? AND (? = '' OR owner_user_id = ?) ORDER BY created_at ASC, subscription_id ASC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare subscription list by chain")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(chain_id))
	bind_text(stmt, 2, string(owner_user_id))
	bind_text(stmt, 3, string(owner_user_id))
	out := make([dynamic]domain.Task_Subscription)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&out, subscription_from_stmt(stmt))
	}
	return out[:], domain.Domain_Error{}
}

taskchain_list_subscriptions_by_task_sqlite :: proc(ctx: rawptr, task_id: domain.Task_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Subscription, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT subscription_id, owner_user_id, subscriber_agent_instance_id, chain_id, task_id, event_type, created_at FROM task_subscriptions WHERE task_id = ? AND (? = '' OR owner_user_id = ?) ORDER BY created_at ASC, subscription_id ASC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare subscription list by task")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(task_id))
	bind_text(stmt, 2, string(owner_user_id))
	bind_text(stmt, 3, string(owner_user_id))
	out := make([dynamic]domain.Task_Subscription)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&out, subscription_from_stmt(stmt))
	}
	return out[:], domain.Domain_Error{}
}

taskchain_list_subscriptions_by_instance_sqlite :: proc(ctx: rawptr, subscriber_agent_instance_id: string, owner_user_id: domain.User_ID) -> ([]domain.Task_Subscription, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT subscription_id, owner_user_id, subscriber_agent_instance_id, chain_id, task_id, event_type, created_at FROM task_subscriptions WHERE subscriber_agent_instance_id = ? AND (? = '' OR owner_user_id = ?) ORDER BY created_at ASC, subscription_id ASC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare subscription list by instance")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, subscriber_agent_instance_id)
	bind_text(stmt, 2, string(owner_user_id))
	bind_text(stmt, 3, string(owner_user_id))
	out := make([dynamic]domain.Task_Subscription)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&out, subscription_from_stmt(stmt))
	}
	return out[:], domain.Domain_Error{}
}

subscription_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Task_Subscription {
	return domain.Task_Subscription{
		subscription_id              = strings.clone(column_text_unowned(stmt, 0)),
		owner_user_id                = domain.User_ID(strings.clone(column_text_unowned(stmt, 1))),
		subscriber_agent_instance_id = strings.clone(column_text_unowned(stmt, 2)),
		chain_id                     = domain.Task_Chain_ID(strings.clone(column_text_unowned(stmt, 3))),
		task_id                      = domain.Task_ID(strings.clone(column_text_unowned(stmt, 4))),
		event_type                   = strings.clone(column_text_unowned(stmt, 5)),
		created_at                   = strings.clone(column_text_unowned(stmt, 6)),
	}
}

directory_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Task_Chain_Directory {
	return domain.Task_Chain_Directory{
		directory_id = column_text(stmt, 0),
		chain_id = domain.Task_Chain_ID(column_text(stmt, 1)),
		owner_user_id = domain.User_ID(column_text(stmt, 2)),
		path = column_text(stmt, 3),
		bridge_id = column_text(stmt, 4),
		vcs_kind = column_text(stmt, 5),
		vcs_info_json = column_text(stmt, 6),
		created_at = column_text(stmt, 7),
		updated_at = column_text(stmt, 8),
	}
}

bind_task :: proc(stmt: sqlite3_stmt, task: domain.Task) {
	bind_text(stmt, 1, string(task.task_id)); bind_text(stmt, 2, string(task.chain_id)); bind_text(stmt, 3, string(task.owner_user_id)); bind_text(stmt, 4, task.title); bind_text(stmt, 5, task.description); bind_text(stmt, 6, publish_state_string(task.publish_state)); bind_text(stmt, 7, task_status_string(task.status)); bind_text(stmt, 8, domain.task_priority_string(task.priority)); bind_text(stmt, 9, json_or_empty_object(task.assignee_ref_json)); bind_text(stmt, 10, json_or_empty_array(task.reviewer_refs_json)); bind_text(stmt, 11, task.created_at); bind_text(stmt, 12, task.updated_at); bind_text(stmt, 13, task.published_at); bind_text(stmt, 14, task.started_at); bind_text(stmt, 15, task.completed_at); bind_text(stmt, 16, task.bridge_id)
}

bind_comment :: proc(stmt: sqlite3_stmt, comment: domain.Task_Comment) {
	bind_text(stmt, 1, comment.comment_id); bind_text(stmt, 2, string(comment.task_id)); bind_text(stmt, 3, string(comment.chain_id)); bind_text(stmt, 4, string(comment.owner_user_id)); bind_text(stmt, 5, comment.author_agent_instance_id); bind_text(stmt, 6, comment.body); bind_text(stmt, 7, comment.created_at); bind_text(stmt, 8, comment.updated_at)
}

chain_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Task_Chain {
	return domain.Task_Chain{chain_id = domain.Task_Chain_ID(column_text(stmt, 0)), owner_user_id = domain.User_ID(column_text(stmt, 1)), title = column_text(stmt, 2), description = column_text(stmt, 3), publish_state = publish_state_from_string(column_text(stmt, 4)), status = chain_status_from_string(column_text(stmt, 5)), kind = column_text(stmt, 6), coordinator_agent_instance_id = column_text(stmt, 7), default_reviewer_refs_json = column_text(stmt, 8), created_at = column_text(stmt, 9), updated_at = column_text(stmt, 10), published_at = column_text(stmt, 11), completed_at = column_text(stmt, 12), last_activity_at = column_text(stmt, 13), last_title_nudge_at = column_text(stmt, 14), title_source = normalize_title_source(column_text(stmt, 15)), is_pinned = column_text_unowned(stmt, 16) == "1", pinned_at = column_text(stmt, 17)}
}

taskchain_count_pinned_chains_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> (int, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT COUNT(*) FROM task_chains WHERE owner_user_id = ? AND is_pinned != 0;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return 0, domain.domain_error(.Internal_Error, "failed to prepare pinned count query")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner_user_id))
	if sqlite3_step(stmt) != SQLITE_ROW do return 0, domain.Domain_Error{}
	return int_v(column_text_unowned(stmt, 0)), domain.Domain_Error{}
}

taskchain_list_pinned_chains_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Task_Chain, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT chain_id, owner_user_id, title, description, publish_state, status, kind, coordinator_agent_instance_id, default_reviewer_refs_json, created_at, updated_at, published_at, completed_at, last_activity_at, last_title_nudge_at, title_source, is_pinned, pinned_at FROM task_chains WHERE owner_user_id = ? AND is_pinned != 0 ORDER BY pinned_at DESC LIMIT 10;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare pinned chain list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner_user_id))
	out := make([dynamic]domain.Task_Chain)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, chain_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

task_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Task {
	return domain.Task{task_id = domain.Task_ID(column_text(stmt, 0)), chain_id = domain.Task_Chain_ID(column_text(stmt, 1)), owner_user_id = domain.User_ID(column_text(stmt, 2)), title = column_text(stmt, 3), description = column_text(stmt, 4), publish_state = publish_state_from_string(column_text(stmt, 5)), status = task_status_from_string(column_text(stmt, 6)), priority = domain.task_priority_from_string(column_text(stmt, 7)), assignee_ref_json = column_text(stmt, 8), reviewer_refs_json = column_text(stmt, 9), created_at = column_text(stmt, 10), updated_at = column_text(stmt, 11), published_at = column_text(stmt, 12), started_at = column_text(stmt, 13), completed_at = column_text(stmt, 14), bridge_id = column_text(stmt, 15)}
}

task_comment_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Task_Comment {
	return domain.Task_Comment{comment_id = column_text(stmt, 0), task_id = domain.Task_ID(column_text(stmt, 1)), chain_id = domain.Task_Chain_ID(column_text(stmt, 2)), owner_user_id = domain.User_ID(column_text(stmt, 3)), author_agent_instance_id = column_text(stmt, 4), body = column_text(stmt, 5), created_at = column_text(stmt, 6), updated_at = column_text(stmt, 7)}
}

member_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Task_Chain_Member {
	return domain.Task_Chain_Member{chain_id = domain.Task_Chain_ID(column_text(stmt, 0)), agent_instance_id = column_text(stmt, 1), agent_id = column_text(stmt, 2), owner_user_id = domain.User_ID(column_text(stmt, 3)), role = column_text(stmt, 4), created_at = column_text(stmt, 5)}
}

dependency_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Task_Dependency {
	return domain.Task_Dependency{task_id = domain.Task_ID(column_text(stmt, 0)), depends_on_task_id = domain.Task_ID(column_text(stmt, 1)), chain_id = domain.Task_Chain_ID(column_text(stmt, 2)), owner_user_id = domain.User_ID(column_text(stmt, 3)), created_at = column_text(stmt, 4)}
}

vote_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Task_Vote {
	return domain.Task_Vote{task_id = domain.Task_ID(column_text(stmt, 0)), reviewer_agent_instance_id = column_text(stmt, 1), chain_id = domain.Task_Chain_ID(column_text(stmt, 2)), owner_user_id = domain.User_ID(column_text(stmt, 3)), vote = column_text(stmt, 4), comment = column_text(stmt, 5), created_at = column_text(stmt, 6), updated_at = column_text(stmt, 7)}
}

publish_state_string :: proc(state: domain.Publish_State) -> string { if state == .Published do return "published"; return "draft" }
publish_state_from_string :: proc(state: string) -> domain.Publish_State { if state == "published" do return .Published; return .Draft }
chain_status_string :: proc(status: domain.Task_Chain_Status) -> string { if status == .Completed do return "completed"; if status == .Cancelled do return "cancelled"; if status == .Archived do return "archived"; return "active" }
chain_status_from_string :: proc(status: string) -> domain.Task_Chain_Status { if status == "completed" do return .Completed; if status == "cancelled" do return .Cancelled; if status == "archived" do return .Archived; return .Active }
task_status_string :: proc(status: domain.Task_Status) -> string { switch status { case .Assigned: return "assigned"; case .Queued: return "queued"; case .In_Progress: return "in_progress"; case .In_Validation: return "in_validation"; case .Finishing: return "finishing"; case .Pausing: return "pausing"; case .Validated_Good: return "validated_good"; case .Validated_Not_Good: return "validated_not_good"; case .Paused: return "paused"; case .Completed: return "completed"; case .Cancelled: return "cancelled" }; return "assigned" }
task_status_from_string :: proc(status: string) -> domain.Task_Status { if status == "queued" do return .Queued; if status == "in_progress" do return .In_Progress; if status == "in_validation" do return .In_Validation; if status == "finishing" do return .Finishing; if status == "pausing" do return .Pausing; if status == "validated_good" do return .Validated_Good; if status == "validated_not_good" do return .Validated_Not_Good; if status == "paused" do return .Paused; if status == "completed" do return .Completed; if status == "cancelled" do return .Cancelled; return .Assigned }
json_or_empty_array :: proc(value: string) -> string { if value == "" do return "[]"; return value }
json_or_empty_object :: proc(value: string) -> string { if value == "" do return "{}"; return value }
