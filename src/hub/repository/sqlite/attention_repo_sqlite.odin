package sqlite

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
		list_live_cards              = attention_list_live_cards_sqlite,
		list_owners                  = attention_list_owners_sqlite,
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
	if sqlite3_step(stmt) != SQLITE_DONE {
		return false, domain.domain_error(.Internal_Error, "attention card insert failed")
	}
	return sqlite3_changes(impl.conn.db) > 0, domain.Domain_Error{}
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
	if sqlite3_step(stmt) != SQLITE_DONE {
		return false, domain.domain_error(.Internal_Error, "attention card update failed")
	}
	return sqlite3_changes(impl.conn.db) > 0, domain.Domain_Error{}
}

attention_list_validation_task_ids_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Task_ID, domain.Domain_Error) {
	impl, ok := attention_repo_open(ctx)
	if !ok do return nil, not_open()
	stmt: sqlite3_stmt = nil
	query := "SELECT task_id FROM tasks WHERE owner_user_id = ? AND status = 'in_validation' ORDER BY updated_at ASC, task_id ASC;"
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
	query := "SELECT owner_user_id FROM tasks UNION SELECT owner_user_id FROM chat_conversations UNION SELECT owner_user_id FROM cards ORDER BY 1;"
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
