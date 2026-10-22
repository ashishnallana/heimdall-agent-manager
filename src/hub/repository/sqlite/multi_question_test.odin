package sqlite

import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(test)
test_multi_question_answer_survives_reopen :: proc(t: ^testing.T) {
	conn, path, ok := tmpl_clone_migrated_into_file(t, "mq_durable")
	if !ok do return
	defer tmpl_remove_db(path)
	defer close(&conn)
	impl: Content_Repo_SQLite
	repo := new_content_repository(&impl, &conn)
	_, conv_ok, _ := iface.content_save_conversation(&repo, domain.Chat_Conversation{conversation_id = "chat_mq", owner_user_id = "mq_owner", created_at = "2026-10-22T10:00:00Z", updated_at = "2026-10-22T10:00:00Z"})
	if !testing.expect(t, conv_ok, "conversation saved") do return
	source, source_ok, _ := iface.content_save_message(&repo, domain.Chat_Message{message_id = "msg_source", conversation_id = "chat_mq", owner_user_id = "mq_owner", direction = "agent_to_user", body = "source ciphertext", message_type = "multi_question", metadata_json = "{}", created_at = "2026-10-22T10:00:00Z"})
	if !testing.expect(t, source_ok, "source saved") do return
	answer := domain.Chat_Message{message_id = "msg_answer_msg_source", conversation_id = "chat_mq", owner_user_id = "mq_owner", direction = "user_to_agent", body = "answer ciphertext", message_type = "multi_question_answer", metadata_json = `{"multi_question_answer":{"version":1,"source_message_id":"msg_source","idempotency_key":"key1","answers":[]}}`, created_at = "2026-10-22T10:00:01Z"}
	_, inserted, err := iface.content_answer_question(&repo, source, answer)
	testing.expect(t, inserted, "first answer inserted")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	close(&conn)
	conn, ok, _ = open(path)
	if !testing.expect(t, ok, "database reopens") do return
	// Existing interface points at the reopened connection address.
	reloaded, exists, get_err := iface.content_get_message(&repo, answer.message_id)
	testing.expect(t, exists, "answer durable across process/connection lifetime")
	testing.expect_value(t, get_err.code, domain.Error_Code.None)
	testing.expect_value(t, reloaded.body, answer.body)
	testing.expect_value(t, reloaded.metadata_json, answer.metadata_json)
	_, duplicate, duplicate_err := iface.content_answer_question(&repo, source, answer)
	testing.expect(t, !duplicate, "retry does not insert again")
	testing.expect_value(t, duplicate_err.code, domain.Error_Code.None)
	rows, _ := iface.content_list_messages(&repo, "chat_mq", "mq_owner", 200, "")
	testing.expect_value(t, len(rows), 2)
}
