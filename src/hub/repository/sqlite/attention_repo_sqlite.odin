package sqlite

import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// SQLite side of iface.Attention_Repository (attention deck v1).

Attention_Repo_SQLite :: struct {
	conn: ^Conn,
}

new_attention_repository :: proc(impl: ^Attention_Repo_SQLite, conn: ^Conn) -> iface.Attention_Repository {
	impl.conn = conn
	return iface.Attention_Repository{
		ctx                          = rawptr(impl),
		card_insert_if_absent        = attention_card_insert_if_absent_sqlite,
		card_compare_and_set         = attention_card_compare_and_set_sqlite,
		list_validation_task_ids     = attention_list_validation_task_ids_sqlite,
		latest_actionable_message    = attention_latest_actionable_message_sqlite,
		list_actionable_instance_ids = attention_list_actionable_instance_ids_sqlite,
		list_pending_memory_ids      = attention_list_pending_memory_ids_sqlite,
		list_live_cards              = attention_list_live_cards_sqlite,
		list_owners                  = attention_list_owners_sqlite,
		list_cards                   = attention_list_cards_sqlite,
		list_snoozed_cards           = attention_list_snoozed_cards_sqlite,
		count                        = attention_count_sqlite,
		resolve_context              = attention_resolve_context_sqlite,
		resolve_scope_names          = attention_resolve_scope_names_sqlite,
	}
}

@(private="file")
attention_repo_open :: proc(ctx: rawptr) -> (^Attention_Repo_SQLite, bool) {
	impl := (^Attention_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil do return nil, false
	return impl, true
}

@(private="file")
not_open :: proc() -> domain.Domain_Error {
	return domain.domain_error(.Internal_Error, "sqlite repository is not open")
}

// An "actionable" message: incoming, unread, carrying a non-empty options array,
// and not yet answered by a later user message in the same conversation.
@(private="file")
ACTIONABLE_MESSAGE_WHERE :: ` m.direction = 'agent_to_user' AND m.read_at = ''
	AND m.sender_agent_instance_id != ''
	AND json_valid(m.metadata_json)
	AND json_type(m.metadata_json, '$.options') = 'array'
	AND json_array_length(m.metadata_json, '$.options') > 0
	AND NOT EXISTS (
		SELECT 1 FROM chat_messages r
		WHERE r.conversation_id = m.conversation_id AND r.owner_user_id = m.owner_user_id
		  AND r.direction = 'user_to_agent' AND r.created_at > m.created_at
	)`

attention_card_insert_if_absent_sqlite :: proc(ctx: rawptr, card: domain.Card) -> (bool, domain.Domain_Error) {
	impl, ok := attention_repo_open(ctx)
	if !ok do return false, not_open()
	stmt: sqlite3_stmt = nil
	query := `INSERT INTO cards (
		card_id, owner_user_id, project_id, title, rationale, scope,
		provider, confidence, source_refs_json, status, operations_json,
		guard_json, snooze_until, ttl_at, created_at, updated_at,
		kind, attention_since, source_marker, details_json, action_refs_json
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	ON CONFLICT(card_id) DO NOTHING;`
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return false, domain.domain_error(.Internal_Error, "failed to prepare attention card insert")
	}
	defer sqlite3_finalize(stmt)
	bind_card_insert(stmt, card)
	step_rc, row_changes := step_changes(impl.conn.db, stmt)
	if step_rc != SQLITE_DONE {
		return false, domain.domain_error(.Internal_Error, "attention card insert failed")
	}
	return row_changes > 0, domain.Domain_Error{}
}

attention_card_compare_and_set_sqlite :: proc(ctx: rawptr, card: domain.Card, expect_status, expect_marker: string) -> (bool, domain.Domain_Error) {
	impl, ok := attention_repo_open(ctx)
	if !ok do return false, not_open()
	stmt: sqlite3_stmt = nil
	query := `UPDATE cards SET
		title = ?, rationale = ?, scope = ?, provider = ?, confidence = ?,
		source_refs_json = ?, status = ?, operations_json = ?, guard_json = ?,
		snooze_until = ?, ttl_at = ?, updated_at = ?,
		kind = ?, attention_since = ?, source_marker = ?, details_json = ?, action_refs_json = ?
		WHERE card_id = ? AND status = ? AND source_marker = ?;`
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return false, domain.domain_error(.Internal_Error, "failed to prepare attention card update")
	}
	defer sqlite3_finalize(stmt)
	bind_card_update_fields(stmt, card_normalized(card))
	bind_text(stmt, 18, string(card.card_id))
	bind_text(stmt, 19, expect_status)
	bind_text(stmt, 20, expect_marker)
	step_rc, row_changes := step_changes(impl.conn.db, stmt)
	if step_rc != SQLITE_DONE {
		return false, domain.domain_error(.Internal_Error, "attention card update failed")
	}
	return row_changes > 0, domain.Domain_Error{}
}

attention_list_validation_task_ids_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Task_ID, domain.Domain_Error) {
	impl, ok := attention_repo_open(ctx)
	if !ok do return nil, not_open()
	stmt: sqlite3_stmt = nil
	// Candidates only: taskv2.user_attention makes the final call (agent reviews
	// done, user not yet decided, block not agent-to-agent). In review awaiting
	// the user (incl. every gate), or blocked on something other than a task or
	// an operator's own hold (REQ-TV2-5) — minus the v2 backfill of legacy
	// paused tasks.
	query := "SELECT task_id FROM tasks WHERE owner_user_id = ? AND state NOT IN ('done','cancelled') AND (" +
		"(state = 'in_review' AND (requires_user_approval = 1 OR kind = 'gate')) OR " +
		"(blocked_on_json <> '' AND COALESCE(json_extract(blocked_on_json, '$.kind'), '') NOT IN ('task', 'hold') " +
		"AND COALESCE(json_extract(blocked_on_json, '$.reason'), '') <> 'paused_before_v2')" +
		") ORDER BY updated_at ASC, task_id ASC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare validation task list")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner_user_id))
	out := make([dynamic]domain.Task_ID)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, domain.Task_ID(column_text(stmt, 0)))
	return out[:], domain.Domain_Error{}
}

attention_latest_actionable_message_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID, agent_instance_id: string) -> (domain.Chat_Message, bool, int, domain.Domain_Error) {
	impl, ok := attention_repo_open(ctx)
	if !ok do return {}, false, 0, not_open()
	stmt: sqlite3_stmt = nil
	query := "SELECT " + CHAT_MESSAGE_SELECT_M + " FROM chat_messages m WHERE m.owner_user_id = ? AND m.sender_agent_instance_id = ? AND" + ACTIONABLE_MESSAGE_WHERE + " ORDER BY m.created_at DESC, m.message_id DESC LIMIT 1;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return {}, false, 0, domain.domain_error(.Internal_Error, "failed to prepare actionable message lookup")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner_user_id))
	bind_text(stmt, 2, agent_instance_id)
	if sqlite3_step(stmt) != SQLITE_ROW do return {}, false, 0, domain.Domain_Error{}
	msg := message_from_stmt(stmt)

	count_stmt: sqlite3_stmt = nil
	count_query := "SELECT COUNT(*) FROM chat_messages WHERE owner_user_id = ? AND sender_agent_instance_id = ? AND direction = 'agent_to_user' AND read_at = '';"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(count_query)), -1, &count_stmt, nil) != SQLITE_OK {
		return msg, true, 0, domain.domain_error(.Internal_Error, "failed to prepare unread count")
	}
	defer sqlite3_finalize(count_stmt)
	bind_text(count_stmt, 1, string(owner_user_id))
	bind_text(count_stmt, 2, agent_instance_id)
	unread := 0
	if sqlite3_step(count_stmt) == SQLITE_ROW do unread = int(sqlite3_column_int64(count_stmt, 0))
	other := unread - 1
	if other < 0 do other = 0
	return msg, true, other, domain.Domain_Error{}
}

attention_list_actionable_instance_ids_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]string, domain.Domain_Error) {
	impl, ok := attention_repo_open(ctx)
	if !ok do return nil, not_open()
	stmt: sqlite3_stmt = nil
	query := "SELECT DISTINCT m.sender_agent_instance_id FROM chat_messages m WHERE m.owner_user_id = ? AND" + ACTIONABLE_MESSAGE_WHERE + " ORDER BY 1;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare actionable instance list")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner_user_id))
	out := make([dynamic]string)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, column_text(stmt, 0))
	return out[:], domain.Domain_Error{}
}

attention_list_pending_memory_ids_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]string, domain.Domain_Error) {
	impl, ok := attention_repo_open(ctx)
	if !ok do return nil, not_open()
	stmt: sqlite3_stmt = nil
	query := "SELECT memory_id FROM memories WHERE owner_user_id = ? AND status = 'pending' ORDER BY 1;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare pending memory list")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner_user_id))
	out := make([dynamic]string)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, column_text(stmt, 0))
	return out[:], domain.Domain_Error{}
}

attention_list_live_cards_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID, provider: string) -> ([]domain.Card, domain.Domain_Error) {
	impl, ok := attention_repo_open(ctx)
	if !ok do return nil, not_open()
	stmt: sqlite3_stmt = nil
	query := "SELECT " + CARD_COLUMNS + " FROM cards WHERE owner_user_id = ? AND provider = ? AND status IN ('pending', 'snoozed') ORDER BY card_id;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare live card list")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner_user_id))
	bind_text(stmt, 2, provider)
	out := make([dynamic]domain.Card)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, card_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

// attention_list_owners: every user who can own an attention source (a task or
// a conversation), for the reconciliation sweep.
attention_list_owners_sqlite :: proc(ctx: rawptr) -> ([]domain.User_ID, domain.Domain_Error) {
	impl, ok := attention_repo_open(ctx)
	if !ok do return nil, not_open()
	stmt: sqlite3_stmt = nil
	query := "SELECT owner_user_id FROM tasks UNION SELECT owner_user_id FROM chat_conversations UNION SELECT owner_user_id FROM cards UNION SELECT owner_user_id FROM memories WHERE status = 'pending' AND owner_user_id != 'system' ORDER BY 1;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare attention owner list")
	}
	defer sqlite3_finalize(stmt)
	out := make([dynamic]domain.User_ID)
	for sqlite3_step(stmt) == SQLITE_ROW {
		owner := column_text(stmt, 0)
		if owner != "" do append(&out, domain.User_ID(owner))
	}
	return out[:], domain.Domain_Error{}
}

// ---- attention API reads ----

// LIVE_CARD_WHERE: pending, or snoozed with a snooze that expired by now (the
// last bound parameter). Only the kinds the deck serves are ever counted.
@(private="file")
LIVE_CARD_WHERE :: ` (status = 'pending' OR (status = 'snoozed' AND snooze_until != '' AND snooze_until <= ?))`

// SNOOZED_CARD_WHERE: a snooze that is still running as of now (the last bound
// parameter); an open-ended snooze ('') never wakes on its own.
@(private="file")
SNOOZED_CARD_WHERE :: ` status = 'snoozed' AND (snooze_until = '' OR snooze_until > ?)`

attention_list_snoozed_cards_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID, now: string, limit: int) -> ([]domain.Card, domain.Domain_Error) {
	impl, ok := attention_repo_open(ctx)
	if !ok do return nil, not_open()
	stmt: sqlite3_stmt = nil
	query := "SELECT " + CARD_COLUMNS + " FROM cards WHERE owner_user_id = ? AND kind IN ('message', 'task', 'memory') AND" + SNOOZED_CARD_WHERE + " ORDER BY snooze_until = '' ASC, snooze_until ASC, card_id ASC LIMIT ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare snoozed attention card list")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner_user_id))
	bind_text(stmt, 2, now)
	sqlite3_bind_int64(stmt, 3, i64(limit))
	out := make([dynamic]domain.Card)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, card_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

attention_list_cards_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID, kind, cutoff, now: string, limit: int) -> ([]domain.Card, domain.Domain_Error) {
	impl, ok := attention_repo_open(ctx)
	if !ok do return nil, not_open()
	stmt: sqlite3_stmt = nil
	query := "SELECT " + CARD_COLUMNS + " FROM cards WHERE owner_user_id = ? AND kind = ? AND attention_since >= ? AND" + LIVE_CARD_WHERE + " ORDER BY attention_since ASC, card_id ASC LIMIT ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare attention card list")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner_user_id))
	bind_text(stmt, 2, kind)
	bind_text(stmt, 3, cutoff)
	bind_text(stmt, 4, now)
	sqlite3_bind_int64(stmt, 5, i64(limit))
	out := make([dynamic]domain.Card)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, card_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

attention_count_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID, cutoff, now: string) -> (iface.Attention_Counts, domain.Domain_Error) {
	impl, ok := attention_repo_open(ctx)
	if !ok do return {}, not_open()
	stmt: sqlite3_stmt = nil
	query := "SELECT kind, SUM(CASE WHEN attention_since >= ? THEN 1 ELSE 0 END), SUM(CASE WHEN attention_since < ? THEN 1 ELSE 0 END) FROM cards WHERE owner_user_id = ? AND kind IN ('message', 'task', 'memory') AND" + LIVE_CARD_WHERE + " GROUP BY kind;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return {}, domain.domain_error(.Internal_Error, "failed to prepare attention count")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, cutoff)
	bind_text(stmt, 2, cutoff)
	bind_text(stmt, 3, string(owner_user_id))
	bind_text(stmt, 4, now)
	counts: iface.Attention_Counts
	for sqlite3_step(stmt) == SQLITE_ROW {
		kind := column_text_unowned(stmt, 0)
		in_range := int(sqlite3_column_int64(stmt, 1))
		counts.older += int(sqlite3_column_int64(stmt, 2))
		switch kind {
		case domain.CARD_KIND_MESSAGE: counts.message = in_range
		case domain.CARD_KIND_TASK:    counts.task = in_range
		case domain.CARD_KIND_MEMORY:  counts.memory = in_range
		}
	}
	if err := attention_count_snoozed(impl, owner_user_id, now, &counts); err.code != .None do return {}, err
	return counts, domain.Domain_Error{}
}

@(private="file")
attention_count_snoozed :: proc(impl: ^Attention_Repo_SQLite, owner_user_id: domain.User_ID, now: string, counts: ^iface.Attention_Counts) -> domain.Domain_Error {
	stmt: sqlite3_stmt = nil
	query := "SELECT COUNT(*) FROM cards WHERE owner_user_id = ? AND kind IN ('message', 'task', 'memory') AND" + SNOOZED_CARD_WHERE + ";"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return domain.domain_error(.Internal_Error, "failed to prepare snoozed attention count")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner_user_id))
	bind_text(stmt, 2, now)
	if sqlite3_step(stmt) == SQLITE_ROW do counts.snoozed = int(sqlite3_column_int64(stmt, 0))
	return domain.Domain_Error{}
}

// attention_lookup_pairs runs "SELECT key, value FROM <from> WHERE owner_user_id
// = ? AND key IN (...)" once and fills out. Empty ids is a no-op.
@(private="file")
attention_lookup_pairs :: proc(impl: ^Attention_Repo_SQLite, select_from: string, owner_user_id: domain.User_ID, ids: []string, out: ^map[string]string) -> domain.Domain_Error {
	if len(ids) == 0 do return domain.Domain_Error{}
	qs := make([dynamic]string, 0, len(ids), context.temp_allocator)
	for _ in ids do append(&qs, "?")
	query := strings.concatenate({select_from, " IN (", strings.join(qs[:], ",", context.temp_allocator), ");"}, context.temp_allocator)
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(impl.conn.db, strings.clone_to_cstring(query, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK {
		return domain.domain_error(.Internal_Error, "failed to prepare attention context lookup")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner_user_id))
	for id, i in ids do bind_text(stmt, 2 + i, id)
	for sqlite3_step(stmt) == SQLITE_ROW do out[column_text(stmt, 0)] = column_text(stmt, 1)
	return domain.Domain_Error{}
}

attention_resolve_context_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID, conversation_ids, chain_ids, instance_ids: []string) -> (iface.Attention_Context, domain.Domain_Error) {
	impl, ok := attention_repo_open(ctx)
	if !ok do return {}, not_open()
	out := iface.Attention_Context{
		conversation_chain = make(map[string]string),
		chain_title        = make(map[string]string),
		instance_name      = make(map[string]string),
	}
	if err := attention_lookup_pairs(impl, "SELECT conversation_id, chain_id FROM chat_conversations WHERE owner_user_id = ? AND conversation_id", owner_user_id, conversation_ids, &out.conversation_chain); err.code != .None do return out, err
	// Chains named directly plus the chains behind the conversations.
	all_chains := make([dynamic]string, 0, len(chain_ids) + len(out.conversation_chain), context.temp_allocator)
	append(&all_chains, ..chain_ids)
	for _, chain_id in out.conversation_chain do if chain_id != "" do append(&all_chains, chain_id)
	if err := attention_lookup_pairs(impl, "SELECT chain_id, title FROM task_chains WHERE owner_user_id = ? AND chain_id", owner_user_id, all_chains[:], &out.chain_title); err.code != .None do return out, err
	if err := attention_lookup_pairs(impl, "SELECT agent_instance_id, display_name FROM agent_instances WHERE owner_user_id = ? AND agent_instance_id", owner_user_id, instance_ids, &out.instance_name); err.code != .None do return out, err
	return out, domain.Domain_Error{}
}

attention_resolve_scope_names_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID, agent_ids, project_ids, bridge_ids, template_ids: []string) -> (iface.Attention_Scope_Names, domain.Domain_Error) {
	impl, ok := attention_repo_open(ctx)
	if !ok do return {}, not_open()
	out := iface.Attention_Scope_Names{
		agents    = make(map[string]string),
		projects  = make(map[string]string),
		bridges   = make(map[string]string),
		templates = make(map[string]string),
	}
	if err := attention_lookup_pairs(impl, "SELECT agent_id, name FROM agents WHERE owner_user_id = ? AND agent_id", owner_user_id, agent_ids, &out.agents); err.code != .None do return out, err
	if err := attention_lookup_pairs(impl, "SELECT project_id, name FROM projects WHERE owner_user_id = ? AND project_id", owner_user_id, project_ids, &out.projects); err.code != .None do return out, err
	if err := attention_lookup_pairs(impl, "SELECT bridge_id, label FROM bridges WHERE owner_user_id = ? AND bridge_id", owner_user_id, bridge_ids, &out.bridges); err.code != .None do return out, err
	// User templates are the owner's; system rows (owner 'system' / is_system) are shared.
	if err := attention_lookup_pairs(impl, "SELECT template_id, name FROM templates WHERE (owner_user_id = ? OR is_system = 1) AND template_id", owner_user_id, template_ids, &out.templates); err.code != .None do return out, err
	return out, domain.Domain_Error{}
}
