package content

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"

// REQ-EXT-CONV-1/2: tool_activity messages land in the instance's conversation
// already read, without touching the conversation's unread count or preview.

TA_OWNER :: domain.User_ID("u_tool_activity")

@(test)
test_tool_activity_message_is_silent_and_scoped :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("%s/.cache/heimdall-tests/tool_activity_%d.db", os.get_env("HOME", context.temp_allocator), os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)
	conn, ok, _ := sqlite.open(db_path)
	if !testing.expect(t, ok, "db open") do return
	defer sqlite.close(&conn)
	mig_ok, _ := sqlite.run_migrations(&conn)
	if !testing.expect(t, mig_ok, "migrations") do return
	content_impl := sqlite.Content_Repo_SQLite{conn = &conn}
	agent_impl := sqlite.Agent_Repo_SQLite{conn = &conn}
	content_repo := sqlite.new_content_repository(&content_impl, &conn)
	agent_repo := sqlite.new_agent_repository(&agent_impl, &conn)
	clock := platform.real_clock()
	ids := platform.real_id_generator()
	svc := new_content_service(&content_repo, &agent_repo, nil, nil, nil, &clock, &ids)

	_, conv_ok, _ := iface.content_save_conversation(&content_repo, domain.Chat_Conversation{
		conversation_id = "chat_ta", owner_user_id = TA_OWNER, agent_id = "agt_ta", agent_instance_id = "inst_ta",
		title = "t", unread_count = 2, last_message_preview = "real reply",
		created_at = "2026-10-22T06:00:00Z", updated_at = "2026-10-22T06:00:00Z",
	})
	if !testing.expect(t, conv_ok, "save conversation") do return
	auth := contracts.Auth_Context{kind = .Instance_Token, user_id = string(TA_OWNER), agent_instance_id = "inst_ta", bridge_id = "brg_ta"}
	meta := `{"v":1,"calls":[{"tool":"Bash","summary":"ls","status":"ok","duration_ms":3}],"subagents":[],"counts":{"total":1}}`

	m, c, saved, err := record_tool_activity_message(&svc, auth, "inst_ta", "  Ran 1 command  ", meta)
	testing.expect(t, saved, err.message)
	testing.expect_value(t, c.conversation_id, "chat_ta")
	testing.expect_value(t, m.message_type, TOOL_ACTIVITY_MESSAGE_TYPE)
	testing.expect_value(t, m.direction, "agent_to_user")
	testing.expect_value(t, m.body, "Ran 1 command")
	testing.expect_value(t, m.sender_agent_instance_id, "inst_ta")
	testing.expect(t, m.read_at != "" && m.read_at == m.delivered_at, "written already read")

	// Persisted as written; the conversation row is untouched.
	rows, _ := iface.content_list_user_visible_messages(&content_repo, "chat_ta", TA_OWNER, 10, "")
	testing.expect_value(t, len(rows), 1)
	if len(rows) == 1 {
		testing.expect_value(t, rows[0].message_type, "tool_activity")
		testing.expect_value(t, rows[0].metadata_json, meta)
		testing.expect(t, rows[0].read_at != "", "read_at persisted")
	}
	// The agent's own inbox history never echoes tool_activity back to it; only a
	// debug read (include_debug) sees the row.
	inbox, _ := iface.content_list_agent_inbox_messages(&content_repo, "chat_ta", TA_OWNER, "inst_ta", false, false, true, false, 10, "")
	testing.expect_value(t, len(inbox), 0)
	debug_inbox, _ := iface.content_list_agent_inbox_messages(&content_repo, "chat_ta", TA_OWNER, "inst_ta", false, false, true, true, 10, "")
	testing.expect_value(t, len(debug_inbox), 1)
	if len(debug_inbox) == 1 do testing.expect_value(t, debug_inbox[0].message_type, "tool_activity")

	after, _, _ := iface.content_get_conversation(&content_repo, "chat_ta")
	testing.expect_value(t, after.unread_count, 2)
	testing.expect_value(t, after.last_message_preview, "real reply")

	// Another instance's token cannot write here; bad input is refused.
	other := auth
	other.agent_instance_id = "inst_other"
	_, _, ok1, e1 := record_tool_activity_message(&svc, other, "inst_ta", "x", meta)
	testing.expect(t, !ok1, "foreign instance refused")
	testing.expect_value(t, e1.code, domain.Error_Code.Forbidden)
	user_auth := contracts.Auth_Context{kind = .User_Token, user_id = string(TA_OWNER)}
	_, _, ok2, _ := record_tool_activity_message(&svc, user_auth, "inst_ta", "x", meta)
	testing.expect(t, !ok2, "user session refused")
	_, _, ok3, e3 := record_tool_activity_message(&svc, auth, "inst_ta", "x", `[1,2]`)
	testing.expect(t, !ok3, "non-object metadata refused")
	testing.expect_value(t, e3.code, domain.Error_Code.Validation_Failed)
	big := strings.concatenate({`{"pad":"`, strings.repeat("x", TOOL_ACTIVITY_METADATA_MAX_BYTES, context.temp_allocator), `"}`}, context.temp_allocator)
	_, _, ok4, _ := record_tool_activity_message(&svc, auth, "inst_ta", "x", big)
	testing.expect(t, !ok4, "oversized metadata refused")
	_, _, ok5, _ := record_tool_activity_message(&svc, auth, "inst_ta", "   ", meta)
	testing.expect(t, !ok5, "empty body refused")

	// Long bodies are clipped on a UTF-8 boundary.
	long := strings.repeat("é", TOOL_ACTIVITY_BODY_MAX_BYTES, context.temp_allocator)
	clipped := tool_activity_clip_body(long)
	testing.expect(t, len(clipped) <= TOOL_ACTIVITY_BODY_MAX_BYTES, "clipped")
	testing.expect_value(t, len(clipped) % 2, 0)
}
