package http

// T5: previous_context rollover handoff. The bridge forwards an agent's handoff
// to POST /api/v1/agent-actions/chat/previous-context; the hub stores it inbound
// and unread in the agent's own conversation, never notifies the agent, shows it
// in the user's message list and returns it from the default `chat read`.
// Runs against the real SQLite repository (fixture from multi_question_test).

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import content_service "odin_test:hub/service/content"
import jsonx "odin_test:lib/jsonx"

pctx_post :: proc(f: ^MQ_HTTP_Fixture, body: string) -> Response {
	req := mq_http_req(f.base, "/api/v1/agent-actions/chat/previous-context", body)
	req.headers = {{name = "Authorization", value = fmt.tprintf("Bearer %s", f.base.bridge_token)}}
	return agent_action_chat_previous_context_handler(&f.agent_handlers, req)
}

pctx_body :: proc(request_id, sealed: string) -> string {
	return fmt.tprintf(`{{"agent_instance_id":"inst_mq","params":{{"request_id":"%s","body":"%s","metadata":{{"context_pct":82,"context_window":200000}}}}}}`, request_id, sealed)
}

pctx_count :: proc(t: ^testing.T, f: ^MQ_HTTP_Fixture) -> int {
	rows, err := iface.content_list_messages(&f.repo, "chat_mq", domain.User_ID(f.base.owner_user_id), 200, "")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	n := 0
	for m in rows do if m.message_type == content_service.MESSAGE_TYPE_PREVIOUS_CONTEXT do n += 1
	return n
}

@(test)
test_previous_context_store_ack_visible_and_chat_read :: proc(t: ^testing.T) {
	f: MQ_HTTP_Fixture
	mq_http_open(t, &f, "pctx_store")
	defer mq_http_base_close(f.base)
	sealed := mq_http_seal("Goal: ship T5. State: tests green. Next: submit.")

	resp := pctx_post(&f, pctx_body("rq_roll_1", sealed))
	if !testing.expect_value(t, resp.status, 201) { fmt.println(resp.body); return }
	testing.expect(t, strings.contains(resp.body, `"created":true`), "first store is created")
	testing.expect(t, strings.contains(resp.body, `"conversation_id":"chat_mq"`), "ack names the instance's own conversation")
	id := jsonx.extract_string(resp.body, "message_id", allocator = context.temp_allocator)
	testing.expect(t, strings.has_prefix(id, "msg_pctx_"), "ack carries the deterministic message_id")

	// Store: inbound, unread, typed, body and metadata verbatim.
	m, ok, _ := iface.content_get_message(&f.repo, id)
	testing.expect(t, ok, "row stored")
	testing.expect_value(t, m.conversation_id, "chat_mq")
	testing.expect_value(t, m.direction, "user_to_agent")
	testing.expect_value(t, m.sender_agent_instance_id, "inst_mq")
	testing.expect_value(t, m.message_type, "previous_context")
	testing.expect_value(t, m.read_at, "")
	testing.expect_value(t, m.body, sealed)
	testing.expect(t, strings.contains(m.metadata_json, `"context_pct":82`), "metadata kept")

	// No live notification to the agent.
	testing.expect_value(t, sync.atomic_load(&f.notifications), 0)

	// Visible in the user message list (API + repository query).
	listed := list_chat_messages_handler(&f.handlers, mq_http_req(f.base, "/api/v1/chats/chat_mq/messages", ""))
	testing.expect_value(t, listed.status, 200)
	testing.expect(t, strings.contains(listed.body, id), "user message list shows previous_context")
	visible, _ := iface.content_list_user_visible_messages(&f.repo, "chat_mq", domain.User_ID(f.base.owner_user_id), 50, "")
	found_visible := false
	for v in visible do if v.message_id == id do found_visible = true
	testing.expect(t, found_visible, "repository user-visible query includes it")

	// Repository: the default agent inbox filter (unread, receiver_only) returns it.
	inbox, inbox_err := iface.content_list_agent_inbox_messages(&f.repo, "chat_mq", domain.User_ID(f.base.owner_user_id), "inst_mq", true, true, false, false, 50, "")
	testing.expect_value(t, inbox_err.code, domain.Error_Code.None)
	found_inbox := false
	for v in inbox do if v.message_id == id do found_inbox = true
	testing.expect(t, found_inbox, "default inbox query includes it")

	// Default `ham-ctl chat read` (params {}) returns it and marks it read.
	read_req := mq_http_req(f.base, "/api/v1/agent-actions/chat/read", `{"agent_instance_id":"inst_mq","params":{}}`)
	read_req.headers = {{name = "Authorization", value = fmt.tprintf("Bearer %s", f.base.bridge_token)}}
	read := agent_action_chat_read_handler(&f.agent_handlers, read_req)
	if !testing.expect_value(t, read.status, 200) { fmt.println(read.body); return }
	testing.expect(t, strings.contains(read.body, id), "default chat read returns previous_context")
	testing.expect(t, strings.contains(read.body, sealed), "chat read returns the sealed body unchanged")
	after, _, _ := iface.content_get_message(&f.repo, id)
	testing.expect(t, after.read_at != "", "chat read marks it read")
	testing.expect_value(t, sync.atomic_load(&f.notifications), 0)
}

@(test)
test_previous_context_idempotent_on_request_id :: proc(t: ^testing.T) {
	f: MQ_HTTP_Fixture
	mq_http_open(t, &f, "pctx_idem")
	defer mq_http_base_close(f.base)
	sealed := mq_http_seal("handoff one")

	first := pctx_post(&f, pctx_body("rq_same", sealed))
	testing.expect_value(t, first.status, 201)
	id := jsonx.extract_string(first.body, "message_id", allocator = context.temp_allocator)
	marked, _ := iface.content_mark_messages_read(&f.repo, domain.User_ID(f.base.owner_user_id), {id}, "2026-11-02T17:00:00Z")
	testing.expect_value(t, marked, 1)

	// A retry after a lost ack (even with a different body) returns the original
	// row and neither duplicates it nor resets its read state.
	retry := pctx_post(&f, pctx_body("rq_same", mq_http_seal("handoff one, resent")))
	if !testing.expect_value(t, retry.status, 200) { fmt.println(retry.body); return }
	testing.expect(t, strings.contains(retry.body, `"created":false`), "retry reports duplicate")
	testing.expect_value(t, jsonx.extract_string(retry.body, "message_id", allocator = context.temp_allocator), id)
	testing.expect_value(t, pctx_count(t, &f), 1)
	kept, _, _ := iface.content_get_message(&f.repo, id)
	testing.expect_value(t, kept.read_at, "2026-11-02T17:00:00Z")
	testing.expect_value(t, kept.body, sealed)

	// A new request id is a new handoff.
	second := pctx_post(&f, pctx_body("rq_next", sealed))
	testing.expect_value(t, second.status, 201)
	testing.expect(t, jsonx.extract_string(second.body, "message_id", allocator = context.temp_allocator) != id, "distinct id")
	testing.expect_value(t, pctx_count(t, &f), 2)
	testing.expect_value(t, sync.atomic_load(&f.notifications), 0)
}

@(test)
test_previous_context_validation :: proc(t: ^testing.T) {
	f: MQ_HTTP_Fixture
	mq_http_open(t, &f, "pctx_valid")
	defer mq_http_base_close(f.base)
	sealed := mq_http_seal("x")
	missing_id := pctx_post(&f, fmt.tprintf(`{{"agent_instance_id":"inst_mq","params":{{"body":"%s"}}}}`, sealed))
	testing.expect_value(t, missing_id.status, 400)
	empty_body := pctx_post(&f, `{"agent_instance_id":"inst_mq","params":{"request_id":"rq_e","body":"  "}}`)
	testing.expect_value(t, empty_body.status, 400)
	// Identity is the verified instance auth: a bare session (no bridge token) is refused.
	unauth := agent_action_chat_previous_context_handler(&f.agent_handlers, mq_http_req(f.base, "/api/v1/agent-actions/chat/previous-context", pctx_body("rq_u", sealed)))
	testing.expect(t, unauth.status == 401 || unauth.status == 403, "requires bridge instance auth")
	testing.expect_value(t, pctx_count(t, &f), 0)
}

// The service refuses any caller that is not the instance itself.
@(test)
test_previous_context_service_requires_own_instance :: proc(t: ^testing.T) {
	f: MQ_HTTP_Fixture
	mq_http_open(t, &f, "pctx_auth")
	defer mq_http_base_close(f.base)
	auth := contracts.Auth_Context{kind = .Instance_Token, user_id = f.base.owner_user_id, agent_instance_id = "inst_other"}
	_, created, err := content_service.store_previous_context(&f.svc, auth, "inst_mq", {request_id = "rq_x", body = "vault:x"})
	testing.expect(t, !created, "not created")
	testing.expect_value(t, err.code, domain.Error_Code.Forbidden)
}
