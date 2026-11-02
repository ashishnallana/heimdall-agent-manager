package sqlite

import "core:c"
import "core:strings"
import domain "odin_test:hub/domain"

// Task System v2 engine tables (task_events, task_attempts, task_attempt_facets,
// task_leases, task_reviews, chain_summaries, workflow_definitions) on the same
// connection as the rest of Taskchain_Repo_SQLite. Facet bodies and event
// payloads are stored and returned VERBATIM — never re-marshalled.

@(private = "file")
CHAIN_COLS :: "chain_id, owner_user_id, title, description, publish_state, status, kind, coordinator_agent_instance_id, defaults_json, created_at, updated_at, published_at, completed_at, last_activity_at, last_title_nudge_at, title_source, is_pinned, pinned_at, work_revision, completion_summary"
@(private = "file")
TASK_COLS :: "task_id, chain_id, owner_user_id, title, description, publish_state, state, kind, priority, attempt_no, brief_json, blocked_on_json, requires_user_approval, ready_since, bridge_id, stage_key, stage_index, generated_by_json, created_at, updated_at, published_at, started_at, completed_at, workflow_run_id, workflow_execution_no"
@(private = "file")
EVENT_COLS :: "event_id, task_id, chain_id, owner_user_id, ts_ms, actor_kind, actor_id, kind, payload_json"
@(private = "file")
ATTEMPT_COLS :: "task_id, attempt_no, chain_id, owner_user_id, started_at, ended_at, holder_instance_id, outcome, counts_toward_budget"
@(private = "file")
FACET_COLS :: "task_id, attempt_no, chain_id, owner_user_id, kind, v, body_json, writer, written_at"
@(private = "file")
LEASE_COLS :: "lease_id, task_id, chain_id, owner_user_id, attempt_no, holder_instance_id, kind, review_role, bridge_id, provider, model, granted_at, confirmed_at, expires_at, hard_deadline_at, last_beat_at, delivery, extended_at, provider_profile"
@(private = "file")
REVIEW_COLS :: "task_id, chain_id, owner_user_id, attempt_no, role, reviewer_kind, reviewer_agent_id, reviewer_instance_id, verdict, findings_json, created_at"

@(private = "file")
prepare :: proc(impl: ^Taskchain_Repo_SQLite, query: string, what: string) -> (sqlite3_stmt, domain.Domain_Error) {
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, strings.concatenate({"failed to prepare ", what}, context.temp_allocator))
	}
	return stmt, domain.Domain_Error{}
}

// ---- chains / tasks (v2 queries) -------------------------------------------

taskchain_list_published_active_chains_sqlite :: proc(ctx: rawptr) -> ([]domain.Task_Chain, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := prepare(impl, "SELECT " + CHAIN_COLS + " FROM task_chains WHERE publish_state = 'published' AND status = 'active' ORDER BY created_at ASC;", "active chain list")
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	out := make([dynamic]domain.Task_Chain)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, chain_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

task_list_by_state_sqlite :: proc(ctx: rawptr, state: domain.Task_State) -> ([]domain.Task, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := prepare(impl, "SELECT " + TASK_COLS + " FROM tasks WHERE state = ? ORDER BY created_at ASC;", "task list by state")
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, domain.task_state_string(state))
	out := make([dynamic]domain.Task)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, task_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

// taskchain_take_boot_regate_sqlite deletes the taskv2_boot_regate marker row
// (migration 129) and reports whether it was there.
taskchain_take_boot_regate_sqlite :: proc(ctx: rawptr) -> (bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := prepare(impl, "DELETE FROM taskv2_boot_regate WHERE singleton = 1 RETURNING reason;", "boot regate take")
	if err.code != .None do return false, err
	defer sqlite3_finalize(stmt)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_ROW do return true, domain.Domain_Error{}
	if rc != SQLITE_DONE do return false, domain.domain_error(.Internal_Error, "failed to take the boot regate marker")
	return false, domain.Domain_Error{}
}

// ---- events ----------------------------------------------------------------

@(private = "file")
event_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Task_Event {
	return domain.Task_Event{
		event_id = sqlite3_column_int64(stmt, 0),
		task_id = domain.Task_ID(column_text(stmt, 1)),
		chain_id = domain.Task_Chain_ID(column_text(stmt, 2)),
		owner_user_id = domain.User_ID(column_text(stmt, 3)),
		ts_ms = sqlite3_column_int64(stmt, 4),
		actor_kind = column_text(stmt, 5),
		actor_id = column_text(stmt, 6),
		kind = column_text(stmt, 7),
		payload_json = column_text(stmt, 8),
	}
}

task_event_append_sqlite :: proc(ctx: rawptr, event: domain.Task_Event) -> (domain.Task_Event, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := prepare(impl, "INSERT INTO task_events (task_id, chain_id, owner_user_id, ts_ms, actor_kind, actor_id, kind, payload_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?) RETURNING event_id;", "task event append")
	if err.code != .None do return domain.Task_Event{}, false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(event.task_id)); bind_text(stmt, 2, string(event.chain_id)); bind_text(stmt, 3, string(event.owner_user_id))
	sqlite3_bind_int64(stmt, 4, event.ts_ms)
	bind_text(stmt, 5, event.actor_kind if event.actor_kind != "" else "hub"); bind_text(stmt, 6, event.actor_id); bind_text(stmt, 7, event.kind)
	bind_text(stmt, 8, json_or_empty_object(event.payload_json))
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Task_Event{}, false, domain.domain_error(.Internal_Error, "task event could not be appended")
	saved := event
	saved.event_id = sqlite3_column_int64(stmt, 0)
	return saved, true, domain.Domain_Error{}
}

task_event_list_by_task_sqlite :: proc(ctx: rawptr, task_id: domain.Task_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Event, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := prepare(impl, "SELECT " + EVENT_COLS + " FROM task_events WHERE task_id = ? AND owner_user_id = ? ORDER BY event_id ASC;", "task event list")
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(task_id)); bind_text(stmt, 2, string(owner_user_id))
	out := make([dynamic]domain.Task_Event)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, event_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

task_event_list_by_chain_sqlite :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Event, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := prepare(impl, "SELECT " + EVENT_COLS + " FROM task_events WHERE chain_id = ? AND owner_user_id = ? ORDER BY event_id ASC;", "chain event list")
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(chain_id)); bind_text(stmt, 2, string(owner_user_id))
	out := make([dynamic]domain.Task_Event)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, event_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

// ---- attempts --------------------------------------------------------------

@(private = "file")
attempt_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Task_Attempt {
	return domain.Task_Attempt{
		task_id = domain.Task_ID(column_text(stmt, 0)),
		attempt_no = int(sqlite3_column_int64(stmt, 1)),
		chain_id = domain.Task_Chain_ID(column_text(stmt, 2)),
		owner_user_id = domain.User_ID(column_text(stmt, 3)),
		started_at = column_text(stmt, 4),
		ended_at = column_text(stmt, 5),
		holder_instance_id = column_text(stmt, 6),
		outcome = column_text(stmt, 7),
		counts_toward_budget = sqlite3_column_int64(stmt, 8) != 0,
	}
}

task_attempt_save_sqlite :: proc(ctx: rawptr, attempt: domain.Task_Attempt) -> (domain.Task_Attempt, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := prepare(impl, "INSERT INTO task_attempts (" + ATTEMPT_COLS + ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(task_id, attempt_no) DO UPDATE SET ended_at=excluded.ended_at, holder_instance_id=excluded.holder_instance_id, outcome=excluded.outcome, counts_toward_budget=excluded.counts_toward_budget;", "task attempt save")
	if err.code != .None do return domain.Task_Attempt{}, false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(attempt.task_id)); sqlite3_bind_int(stmt, 2, c.int(attempt.attempt_no)); bind_text(stmt, 3, string(attempt.chain_id)); bind_text(stmt, 4, string(attempt.owner_user_id))
	bind_text(stmt, 5, attempt.started_at); bind_text(stmt, 6, attempt.ended_at); bind_text(stmt, 7, attempt.holder_instance_id); bind_text(stmt, 8, attempt.outcome)
	sqlite3_bind_int(stmt, 9, 1 if attempt.counts_toward_budget else 0)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.Task_Attempt{}, false, domain.domain_error(.Conflict, "task attempt could not be saved")
	return attempt, true, domain.Domain_Error{}
}

task_attempt_list_by_task_sqlite :: proc(ctx: rawptr, task_id: domain.Task_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Attempt, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := prepare(impl, "SELECT " + ATTEMPT_COLS + " FROM task_attempts WHERE task_id = ? AND owner_user_id = ? ORDER BY attempt_no ASC;", "task attempt list")
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(task_id)); bind_text(stmt, 2, string(owner_user_id))
	out := make([dynamic]domain.Task_Attempt)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, attempt_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

// ---- facets ----------------------------------------------------------------

@(private = "file")
facet_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Task_Attempt_Facet {
	return domain.Task_Attempt_Facet{
		task_id = domain.Task_ID(column_text(stmt, 0)),
		attempt_no = int(sqlite3_column_int64(stmt, 1)),
		chain_id = domain.Task_Chain_ID(column_text(stmt, 2)),
		owner_user_id = domain.User_ID(column_text(stmt, 3)),
		kind = column_text(stmt, 4),
		v = int(sqlite3_column_int64(stmt, 5)),
		body_json = column_text(stmt, 6),
		writer = column_text(stmt, 7),
		written_at = column_text(stmt, 8),
	}
}

task_attempt_facet_save_sqlite :: proc(ctx: rawptr, facet: domain.Task_Attempt_Facet) -> (bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := prepare(impl, "INSERT INTO task_attempt_facets (" + FACET_COLS + ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(task_id, attempt_no, kind) DO UPDATE SET v=excluded.v, body_json=excluded.body_json, writer=excluded.writer, written_at=excluded.written_at;", "task facet save")
	if err.code != .None do return false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(facet.task_id)); sqlite3_bind_int(stmt, 2, c.int(facet.attempt_no)); bind_text(stmt, 3, string(facet.chain_id)); bind_text(stmt, 4, string(facet.owner_user_id))
	bind_text(stmt, 5, facet.kind); sqlite3_bind_int(stmt, 6, c.int(facet.v if facet.v > 0 else 1)); bind_text(stmt, 7, facet.body_json); bind_text(stmt, 8, facet.writer); bind_text(stmt, 9, facet.written_at)
	if sqlite3_step(stmt) != SQLITE_DONE do return false, domain.domain_error(.Conflict, "task facet could not be saved")
	return true, domain.Domain_Error{}
}

task_attempt_facet_list_by_task_sqlite :: proc(ctx: rawptr, task_id: domain.Task_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Attempt_Facet, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := prepare(impl, "SELECT " + FACET_COLS + " FROM task_attempt_facets WHERE task_id = ? AND owner_user_id = ? ORDER BY attempt_no ASC, kind ASC;", "task facet list")
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(task_id)); bind_text(stmt, 2, string(owner_user_id))
	out := make([dynamic]domain.Task_Attempt_Facet)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, facet_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

// ---- leases ----------------------------------------------------------------

@(private = "file")
lease_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Task_Lease {
	return domain.Task_Lease{
		lease_id = column_text(stmt, 0),
		task_id = domain.Task_ID(column_text(stmt, 1)),
		chain_id = domain.Task_Chain_ID(column_text(stmt, 2)),
		owner_user_id = domain.User_ID(column_text(stmt, 3)),
		attempt_no = int(sqlite3_column_int64(stmt, 4)),
		holder_instance_id = column_text(stmt, 5),
		kind = column_text(stmt, 6),
		review_role = column_text(stmt, 7),
		bridge_id = column_text(stmt, 8),
		provider = column_text(stmt, 9),provider_profile=column_text(stmt,18),
		model = column_text(stmt, 10),
		granted_at = column_text(stmt, 11),
		confirmed_at = column_text(stmt, 12),
		expires_at = column_text(stmt, 13),
		hard_deadline_at = column_text(stmt, 14),
		last_beat_at = column_text(stmt, 15),
		delivery = column_text(stmt, 16),
		extended_at = column_text(stmt, 17),
	}
}

// task_lease_save_sqlite upserts by lease_id. The two UNIQUE constraints
// (holder_instance_id; task_id WHERE kind='work') are the engine's backstop
// against a double grant: a violation surfaces as Conflict, never as a silent
// overwrite of another holder's lease.
task_lease_save_sqlite :: proc(ctx: rawptr, lease: domain.Task_Lease) -> (domain.Task_Lease, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := prepare(impl, "INSERT INTO task_leases (" + LEASE_COLS + ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(lease_id) DO UPDATE SET confirmed_at=excluded.confirmed_at, extended_at=excluded.extended_at, expires_at=excluded.expires_at, hard_deadline_at=excluded.hard_deadline_at, last_beat_at=excluded.last_beat_at, delivery=excluded.delivery, bridge_id=excluded.bridge_id, provider_profile=excluded.provider_profile, provider=excluded.provider, model=excluded.model;", "task lease save")
	if err.code != .None do return domain.Task_Lease{}, false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, lease.lease_id); bind_text(stmt, 2, string(lease.task_id)); bind_text(stmt, 3, string(lease.chain_id)); bind_text(stmt, 4, string(lease.owner_user_id))
	sqlite3_bind_int(stmt, 5, c.int(lease.attempt_no)); bind_text(stmt, 6, lease.holder_instance_id); bind_text(stmt, 7, lease.kind); bind_text(stmt, 8, lease.review_role)
	bind_text(stmt, 9, lease.bridge_id); bind_text(stmt, 10, lease.provider); bind_text(stmt, 11, lease.model)
	bind_text(stmt, 12, lease.granted_at); bind_text(stmt, 13, lease.confirmed_at); bind_text(stmt, 14, lease.expires_at); bind_text(stmt, 15, lease.hard_deadline_at); bind_text(stmt, 16, lease.last_beat_at)
	bind_text(stmt, 17, lease.delivery if lease.delivery != "" else domain.LEASE_DELIVERY_WAKE)
	bind_text(stmt, 18, lease.extended_at);bind_text(stmt,19,domain.profile_effective_id(lease.provider,lease.provider_profile))
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.Task_Lease{}, false, domain.domain_error(.Conflict, "lease conflicts with an existing lease (holder or task already leased)")
	return lease, true, domain.Domain_Error{}
}

task_lease_get_sqlite :: proc(ctx: rawptr, lease_id: string) -> (domain.Task_Lease, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := prepare(impl, "SELECT " + LEASE_COLS + " FROM task_leases WHERE lease_id = ?;", "lease lookup")
	if err.code != .None do return domain.Task_Lease{}, false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, lease_id)
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Task_Lease{}, false, domain.domain_error(.Not_Found, "lease not found")
	return lease_from_stmt(stmt), true, domain.Domain_Error{}
}

task_lease_get_by_holder_sqlite :: proc(ctx: rawptr, holder_instance_id: string) -> (domain.Task_Lease, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := prepare(impl, "SELECT " + LEASE_COLS + " FROM task_leases WHERE holder_instance_id = ?;", "lease lookup by holder")
	if err.code != .None do return domain.Task_Lease{}, false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, holder_instance_id)
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Task_Lease{}, false, domain.domain_error(.Not_Found, "lease not found")
	return lease_from_stmt(stmt), true, domain.Domain_Error{}
}

@(private = "file")
lease_list :: proc(impl: ^Taskchain_Repo_SQLite, query: string, key: string, what: string) -> ([]domain.Task_Lease, domain.Domain_Error) {
	stmt, err := prepare(impl, query, what)
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	if key != "" do bind_text(stmt, 1, key)
	out := make([dynamic]domain.Task_Lease)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, lease_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

task_lease_list_by_task_sqlite :: proc(ctx: rawptr, task_id: domain.Task_ID) -> ([]domain.Task_Lease, domain.Domain_Error) {
	return lease_list((^Taskchain_Repo_SQLite)(ctx), "SELECT " + LEASE_COLS + " FROM task_leases WHERE task_id = ? ORDER BY granted_at ASC, lease_id ASC;", string(task_id), "lease list by task")
}

task_lease_list_by_chain_sqlite :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID) -> ([]domain.Task_Lease, domain.Domain_Error) {
	return lease_list((^Taskchain_Repo_SQLite)(ctx), "SELECT " + LEASE_COLS + " FROM task_leases WHERE chain_id = ? ORDER BY granted_at ASC, lease_id ASC;", string(chain_id), "lease list by chain")
}

task_lease_list_all_sqlite :: proc(ctx: rawptr) -> ([]domain.Task_Lease, domain.Domain_Error) {
	return lease_list((^Taskchain_Repo_SQLite)(ctx), "SELECT " + LEASE_COLS + " FROM task_leases ORDER BY granted_at ASC, lease_id ASC;", "", "lease list")
}

task_lease_delete_sqlite :: proc(ctx: rawptr, lease_id: string) -> (bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := prepare(impl, "DELETE FROM task_leases WHERE lease_id = ?;", "lease delete")
	if err.code != .None do return false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, lease_id)
	step_rc, row_changes := step_changes(impl.conn.db, stmt)
	if step_rc != SQLITE_DONE do return false, domain.domain_error(.Internal_Error, "failed to delete lease")
	return row_changes > 0, domain.Domain_Error{}
}

// ---- reviews ---------------------------------------------------------------

@(private = "file")
review_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Task_Review {
	return domain.Task_Review{
		task_id = domain.Task_ID(column_text(stmt, 0)),
		chain_id = domain.Task_Chain_ID(column_text(stmt, 1)),
		owner_user_id = domain.User_ID(column_text(stmt, 2)),
		attempt_no = int(sqlite3_column_int64(stmt, 3)),
		role = column_text(stmt, 4),
		reviewer_kind = column_text(stmt, 5),
		reviewer_agent_id = column_text(stmt, 6),
		reviewer_instance_id = column_text(stmt, 7),
		verdict = column_text(stmt, 8),
		findings_json = column_text(stmt, 9),
		created_at = column_text(stmt, 10),
	}
}

task_review_save_sqlite :: proc(ctx: rawptr, review: domain.Task_Review) -> (domain.Task_Review, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := prepare(impl, "INSERT INTO task_reviews (" + REVIEW_COLS + ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(task_id, attempt_no, role, reviewer_agent_id) DO UPDATE SET reviewer_instance_id=excluded.reviewer_instance_id, verdict=excluded.verdict, findings_json=excluded.findings_json, created_at=excluded.created_at;", "task review save")
	if err.code != .None do return domain.Task_Review{}, false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(review.task_id)); bind_text(stmt, 2, string(review.chain_id)); bind_text(stmt, 3, string(review.owner_user_id)); sqlite3_bind_int(stmt, 4, c.int(review.attempt_no))
	bind_text(stmt, 5, review.role); bind_text(stmt, 6, review.reviewer_kind); bind_text(stmt, 7, review.reviewer_agent_id); bind_text(stmt, 8, review.reviewer_instance_id)
	bind_text(stmt, 9, review.verdict); bind_text(stmt, 10, json_or_empty_array(review.findings_json)); bind_text(stmt, 11, review.created_at)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.Task_Review{}, false, domain.domain_error(.Conflict, "task review could not be saved")
	return review, true, domain.Domain_Error{}
}

task_review_list_by_task_sqlite :: proc(ctx: rawptr, task_id: domain.Task_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Review, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := prepare(impl, "SELECT " + REVIEW_COLS + " FROM task_reviews WHERE task_id = ? AND owner_user_id = ? ORDER BY attempt_no ASC, created_at ASC;", "task review list")
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(task_id)); bind_text(stmt, 2, string(owner_user_id))
	out := make([dynamic]domain.Task_Review)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, review_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

// ---- chain summaries -------------------------------------------------------

chain_summary_get_sqlite :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> (domain.Chain_Summary, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := prepare(impl, "SELECT chain_id, owner_user_id, body, line_count, version, updated_at FROM chain_summaries WHERE chain_id = ? AND owner_user_id = ?;", "chain summary lookup")
	if err.code != .None do return domain.Chain_Summary{}, false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(chain_id)); bind_text(stmt, 2, string(owner_user_id))
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Chain_Summary{}, false, domain.domain_error(.Not_Found, "chain summary not found")
	return domain.Chain_Summary{
		chain_id = domain.Task_Chain_ID(column_text(stmt, 0)),
		owner_user_id = domain.User_ID(column_text(stmt, 1)),
		body = column_text(stmt, 2),
		line_count = int(sqlite3_column_int64(stmt, 3)),
		version = int(sqlite3_column_int64(stmt, 4)),
		updated_at = column_text(stmt, 5),
	}, true, domain.Domain_Error{}
}

chain_summary_save_sqlite :: proc(ctx: rawptr, summary: domain.Chain_Summary) -> (domain.Chain_Summary, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := prepare(impl, "INSERT INTO chain_summaries (chain_id, owner_user_id, body, line_count, version, updated_at) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(chain_id) DO UPDATE SET body=excluded.body, line_count=excluded.line_count, version=excluded.version, updated_at=excluded.updated_at;", "chain summary save")
	if err.code != .None do return domain.Chain_Summary{}, false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(summary.chain_id)); bind_text(stmt, 2, string(summary.owner_user_id)); bind_text(stmt, 3, summary.body)
	sqlite3_bind_int(stmt, 4, c.int(summary.line_count)); sqlite3_bind_int(stmt, 5, c.int(summary.version)); bind_text(stmt, 6, summary.updated_at)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.Chain_Summary{}, false, domain.domain_error(.Conflict, "chain summary could not be saved")
	return summary, true, domain.Domain_Error{}
}

// ---- workflow definitions (append-only) ------------------------------------

@(private = "file")
workflow_definition_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Workflow_Definition {
	return domain.Workflow_Definition{
		def_id = column_text(stmt, 0),
		owner_user_id = domain.User_ID(column_text(stmt, 1)),
		name = column_text(stmt, 2),
		version = int(sqlite3_column_int64(stmt, 3)),
		body_json = column_text(stmt, 4),
		created_at = column_text(stmt, 5),
	}
}

workflow_definition_save_sqlite :: proc(ctx: rawptr, def: domain.Workflow_Definition) -> (domain.Workflow_Definition, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := prepare(impl, "INSERT INTO workflow_definitions (def_id, owner_user_id, name, version, body_json, created_at) VALUES (?, ?, ?, ?, ?, ?);", "workflow definition save")
	if err.code != .None do return domain.Workflow_Definition{}, false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, def.def_id); bind_text(stmt, 2, string(def.owner_user_id)); bind_text(stmt, 3, def.name)
	sqlite3_bind_int(stmt, 4, c.int(def.version)); bind_text(stmt, 5, def.body_json); bind_text(stmt, 6, def.created_at)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.Workflow_Definition{}, false, domain.domain_error(.Conflict, "workflow definition version already exists")
	return def, true, domain.Domain_Error{}
}

workflow_definition_get_sqlite :: proc(ctx: rawptr, def_id: string, owner_user_id: domain.User_ID) -> (domain.Workflow_Definition, bool, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := prepare(impl, "SELECT def_id, owner_user_id, name, version, body_json, created_at FROM workflow_definitions WHERE def_id = ? AND owner_user_id = ?;", "workflow definition lookup")
	if err.code != .None do return domain.Workflow_Definition{}, false, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, def_id); bind_text(stmt, 2, string(owner_user_id))
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Workflow_Definition{}, false, domain.domain_error(.Not_Found, "workflow definition not found")
	return workflow_definition_from_stmt(stmt), true, domain.Domain_Error{}
}

workflow_definition_list_by_owner_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Workflow_Definition, domain.Domain_Error) {
	impl := (^Taskchain_Repo_SQLite)(ctx)
	stmt, err := prepare(impl, "SELECT def_id, owner_user_id, name, version, body_json, created_at FROM workflow_definitions WHERE owner_user_id = ? ORDER BY name ASC, version ASC;", "workflow definition list")
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner_user_id))
	out := make([dynamic]domain.Workflow_Definition)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, workflow_definition_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}
