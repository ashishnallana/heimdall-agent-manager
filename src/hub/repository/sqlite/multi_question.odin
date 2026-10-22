package sqlite

import "core:strings"
import domain "odin_test:hub/domain"

// One SQL statement is the freshness check AND insert. The fixed answer primary
// key gives exactly one durable answer under concurrent submit/retry. No separate
// transaction on the shared connection, no check-then-write race, no migration.
content_answer_question_sqlite :: proc(ctx: rawptr, source, answer: domain.Chat_Message) -> (domain.Chat_Message, bool, domain.Domain_Error) {
	impl := (^Content_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt
	q := `INSERT INTO chat_messages
		(message_id, conversation_id, owner_user_id, direction, sender_agent_id, sender_agent_instance_id,
		 body, artifact_ids_json, message_type, message_status, metadata_json, created_at, delivered_at, read_at)
		SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
		FROM chat_messages s
		WHERE s.message_id=? AND s.conversation_id=? AND s.owner_user_id=?
		  AND s.direction='agent_to_user' AND s.message_type='multi_question' AND s.metadata_json=?
		  AND s.rowid=(SELECT rowid FROM chat_messages WHERE conversation_id=s.conversation_id
		                 AND owner_user_id=s.owner_user_id AND direction != 'agent_to_agent' ORDER BY rowid DESC LIMIT 1)
		ON CONFLICT(message_id) DO NOTHING;`
	if sqlite3_prepare_v2(impl.conn.db, strings.clone_to_cstring(q, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return {}, false, domain.domain_error(.Internal_Error, "failed to prepare question answer")
	defer sqlite3_finalize(stmt)
	bind_message(stmt, answer)
	bind_text(stmt, 15, source.message_id)
	bind_text(stmt, 16, source.conversation_id)
	bind_text(stmt, 17, string(source.owner_user_id))
	bind_text(stmt, 18, source.metadata_json)
	rc, changed := step_changes(impl.conn.db, stmt)
	if rc != SQLITE_DONE do return {}, false, domain.domain_error(.Internal_Error, "failed to save question answer")
	if changed == 1 do return normalize_message_defaults(answer), true, {}
	// A concurrent winner may have inserted before this statement. Resolve the
	// original before reporting stale, so a lost response can always be retried.
	if previous, found, err := content_get_message_sqlite(ctx, answer.message_id); found {
		return previous, false, err
	} else if err.code != .Not_Found do return {}, false, err
	return {}, false, domain.domain_error(.Question_Stale, "A newer conversation message has replaced these questions.")
}

// Eligibility follows commit/insertion order, not timestamps allocated before a
// concurrent send commits. Keep this independent of the history cursor contract.
content_latest_user_visible_message_sqlite :: proc(ctx: rawptr, cid: string, owner: domain.User_ID) -> (domain.Chat_Message, bool, domain.Domain_Error) {
	impl := (^Content_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt
	q := strings.concatenate({"SELECT ", CHAT_MESSAGE_SELECT, " FROM chat_messages WHERE conversation_id=? AND owner_user_id=? AND direction != 'agent_to_agent' ORDER BY rowid DESC LIMIT 1;"}, context.temp_allocator)
	if sqlite3_prepare_v2(impl.conn.db, strings.clone_to_cstring(q, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return {}, false, domain.domain_error(.Internal_Error, "failed latest visible message lookup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, cid)
	bind_text(stmt, 2, string(owner))
	if sqlite3_step(stmt) != SQLITE_ROW do return {}, false, domain.domain_error(.Not_Found, "visible message not found")
	return message_from_stmt(stmt), true, {}
}
