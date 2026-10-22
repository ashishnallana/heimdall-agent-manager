package http

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import platform "odin_test:hub/platform"
import auth_service "odin_test:hub/service/auth"
import user_service "odin_test:hub/service/user"
import agent_service "odin_test:hub/service/agent"
import bridge_service "odin_test:hub/service/bridge"
import content_service "odin_test:hub/service/content"
import project_service "odin_test:hub/service/project"
import jsonx "odin_test:lib/jsonx"
import vault "odin_test:lib/vault"

MQ_HTTP_Base :: struct {
	conn: sqlite.Conn,
	br_impl: sqlite.Bridge_Repo_SQLite,
	us_impl: sqlite.User_Repo_SQLite,
	ag_impl: sqlite.Agent_Repo_SQLite,
	br_repo: iface.Bridge_Repository,
	us_repo: iface.User_Repository,
	ag_repo: iface.Agent_Repository,
	clock: platform.Clock,
	ids: platform.ID_Generator,
	br_svc: bridge_service.Bridge_Service,
	us_svc: user_service.User_Service,
	ag_svc: agent_service.Agent_Service,
	auth_svc: auth_service.Auth_Service,
	proxy_cidrs: [1]string,
	owner_user_id, bridge_id, bridge_token: string,
}

mq_http_base_open :: proc(t: ^testing.T) -> ^MQ_HTTP_Base {
	f := new(MQ_HTTP_Base)
	open_ok: bool
	f.conn, open_ok, _ = sqlite.open(":memory:")
	testing.expect(t, open_ok, "database open")
	migrated, _ := sqlite.run_migrations(&f.conn)
	testing.expect(t, migrated, "migrations")
	f.br_repo = sqlite.new_bridge_repository(&f.br_impl, &f.conn)
	f.us_repo = sqlite.new_user_repository(&f.us_impl, &f.conn)
	f.ag_repo = sqlite.new_agent_repository(&f.ag_impl, &f.conn)
	f.clock = platform.real_clock()
	f.ids = platform.real_id_generator()
	f.br_svc = bridge_service.new_bridge_service(&f.br_repo, &f.clock, &f.ids)
	f.us_svc = user_service.new_user_service_basic(&f.us_repo, &f.clock, &f.ids)
	f.ag_svc = agent_service.new_agent_service(&f.ag_repo, &f.br_repo, &f.clock, &f.ids)
	f.proxy_cidrs = {"127.0.0.1/32"}
	f.auth_svc = auth_service.new_auth_service({username_header = "X-authentik-username", trusted_proxy_cidrs = f.proxy_cidrs[:], auto_provision_users = true}, &f.us_svc)
	f.auth_svc.bridges = &f.br_svc
	f.auth_svc.agents = &f.ag_svc
	f.auth_svc.clock = &f.clock
	f.auth_svc.ids = &f.ids
	user, owner_ok, _ := user_service.ensure_user_from_auth(&f.us_svc, "tanmay", "", "", true)
	testing.expect(t, owner_ok, "owner provisioned")
	f.owner_user_id = strings.clone(string(user.user_id))
	enrolled, enrolled_ok, _ := bridge_service.enroll_bridge_from_device_grant(&f.br_svc, {owner_user_id = f.owner_user_id, bridge_public_key = "04aabb", bridge_key_fingerprint = "aaaa bbbb cccc dddd", machine_hostname = "mq-test"})
	testing.expect(t, enrolled_ok, "bridge enrolled")
	f.bridge_id = strings.clone(enrolled.bridge.bridge_id)
	f.bridge_token = strings.clone(enrolled.bridge_token)
	return f
}

mq_http_base_close :: proc(f: ^MQ_HTTP_Base) {
	sqlite.close(&f.conn)
	delete(f.owner_user_id)
	delete(f.bridge_id)
	delete(f.bridge_token)
	free(f)
}

MQ_HTTP_Fixture :: struct {
	base: ^MQ_HTTP_Base,
	impl: sqlite.Content_Repo_SQLite,
	repo: iface.Content_Repository,
	svc: content_service.Content_Service,
	handlers: Content_Handlers,
	agent_handlers: Agent_Action_Handlers,
	notifications: int,
}

mq_http_seal :: proc(plain: string) -> string {
	key: [32]byte
	for &b, i in key do b = byte(i)
	kr, _ := vault.keyring_from_single_key("tanmay", {1,2,3,4,5,6,7,8}, 1, key[:])
	defer vault.keyring_wipe(&kr)
	sealed, _ := vault.seal(transmute([]byte)plain, &kr, context.temp_allocator)
	return sealed
}

mq_http_notification :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	f := (^MQ_HTTP_Fixture)(ctx)
	if strings.contains(command.body_json, "notify_agent_message") do sync.atomic_add(&f.notifications, 1)
	return true, {}
}

mq_http_open :: proc(t: ^testing.T, f: ^MQ_HTTP_Fixture, tag: string) {
	f.base = mq_http_base_open(t)
	f.repo = sqlite.new_content_repository(&f.impl, &f.base.conn)
	f.svc = content_service.new_content_service(&f.repo, &f.base.ag_repo, nil, nil, nil, &f.base.clock, &f.base.ids)
	f.svc.bridge_command_sink = {ctx = f, send_runtime_command = mq_http_notification}
	f.handlers = {auth = &f.base.auth_svc, agents = &f.base.ag_svc, content = &f.svc}
	f.agent_handlers = {auth = &f.base.auth_svc, agents = &f.base.ag_svc, content = &f.svc}
	_, ok, err := iface.agent_save_instance(&f.base.ag_repo, domain.Agent_Instance{
		agent_instance_id = "inst_mq", owner_user_id = domain.User_ID(f.base.owner_user_id),
		bridge_id = f.base.bridge_id, runtime_status = "running",
	})
	testing.expect(t, ok, err.message)
	for cid in ([]string{"chat_mq", "chat_other"}) {
		_, saved, e := iface.content_save_conversation(&f.repo, domain.Chat_Conversation{
			conversation_id = cid, owner_user_id = domain.User_ID(f.base.owner_user_id),
			agent_instance_id = "inst_mq" if cid == "chat_mq" else "inst_other",
			created_at = "2026-10-22T10:00:00Z", updated_at = "2026-10-22T10:00:00Z",
		})
		testing.expect(t, saved, e.message)
	}
}

mq_http_req :: proc(path, body: string, owner := "tanmay") -> Request {
	headers := make([]contracts.HTTP_Header, 1, context.temp_allocator)
	headers[0] = {name = "X-authentik-username", value = owner}
	return Request{method = "POST", path = path, body = body, request_id = "req_mq", remote_addr = "127.0.0.1:4444", headers = headers}
}

mq_http_source :: proc(t: ^testing.T, f: ^MQ_HTTP_Fixture) -> domain.Chat_Message {
	group := contracts.Multi_Question_Group{version = 1, questions = {
		{id = "target", text = mq_http_seal("Where?"), selection_mode = "single", options = {{id = "stage", label = mq_http_seal("Staging")}, {id = "prod", label = mq_http_seal("Production")}}},
		{id = "checks", text = mq_http_seal("Which checks?"), selection_mode = "multiple", options = {{id = "smoke", label = mq_http_seal("Smoke")}, {id = "integration", label = mq_http_seal("Integration")}}},
	}}
	params := struct {
		agent_instance_id: string,
		params: struct {
			body, message_type: string,
			metadata: struct {multi_question: contracts.Multi_Question_Group},
		},
	}{}
	params.agent_instance_id = "inst_mq"
	params.params.body = mq_http_seal("Choose release settings")
	params.params.message_type = "multi_question"
	params.params.metadata.multi_question = group
	raw, _ := json.marshal(params, allocator = context.temp_allocator)
	req := mq_http_req("/api/v1/agent-actions/chat/send-to-user", string(raw))
	req.headers = {{name = "Authorization", value = fmt.tprintf("Bearer %s", f.base.bridge_token)}}
	response := agent_action_chat_send_to_user_handler(&f.agent_handlers, req)
	if !testing.expect_value(t, response.status, 201) { fmt.println(response.body); return {} }
	id := jsonx.extract_string(response.body, "message_id", allocator = context.temp_allocator)
	m, ok, _ := iface.content_get_message(&f.repo, id)
	testing.expect(t, ok, "source stored")
	testing.expect_value(t, m.message_type, "multi_question")
	testing.expect(t, !strings.contains(m.metadata_json, "Staging"), "labels are never stored plaintext")
	return m
}

mq_http_submission :: proc(key: string, custom := false) -> string {
	s := contracts.Multi_Question_Submission{version = 1, idempotency_key = key, body = mq_http_seal("Where? Staging; Which checks? Smoke and Integration"), answers = {
		{question_id = "target", option_ids = {"stage"}},
		{question_id = "checks", option_ids = {"smoke", "integration"}},
	}}
	if custom do s.answers[1] = {question_id = "checks", custom_text = mq_http_seal("Use my custom checks")}
	raw, _ := json.marshal(s, allocator = context.temp_allocator)
	return string(raw)
}

mq_http_answer :: proc(f: ^MQ_HTTP_Fixture, source_id, body: string, owner := "tanmay", cid := "chat_mq") -> Response {
	return answer_chat_questions_handler(&f.handlers, mq_http_req(fmt.tprintf("/api/v1/chats/%s/messages/%s/answers", cid, source_id), body, owner))
}

@(test)
test_multi_question_http_roundtrip_and_replay :: proc(t: ^testing.T) {
	f: MQ_HTTP_Fixture
	mq_http_open(t, &f, "mq_roundtrip")
	defer mq_http_base_close(f.base)
	source := mq_http_source(t, &f)
	before := list_chat_messages_handler(&f.handlers, mq_http_req("/api/v1/chats/chat_mq/messages", ""))
	testing.expect(t, strings.contains(before.body, `"question_answer":null`), "unanswered source read model")
	testing.expect(t, strings.contains(before.body, `"is_latest_message":true`), "latest hint supplied on source")
	raw := mq_http_submission("request_1", true)
	response := mq_http_answer(&f, source.message_id, raw)
	testing.expect_value(t, response.status, 201)
	testing.expect(t, strings.contains(response.body, `"replayed":false`), "first request reports inserted")
	testing.expect(t, strings.contains(response.body, `"message_type":"multi_question_answer"`), "answer delivered with explicit type")
	testing.expect_value(t, sync.atomic_load(&f.notifications), 1)
	auth := contracts.Auth_Context{kind = .User_Token, user_id = f.base.owner_user_id}
	inbox, e := content_service.list_agent_inbox_messages(&f.svc, auth, {agent_instance_id = "inst_mq", unread_only = true, receiver_only = true})
	testing.expect_value(t, e.code, domain.Error_Code.None)
	if testing.expect_value(t, len(inbox), 1) {
		testing.expect_value(t, inbox[0].direction, "user_to_agent")
		testing.expect(t, strings.contains(inbox[0].metadata_json, source.message_id), "source linkage present in agent inbox")
		testing.expect(t, !strings.contains(inbox[0].metadata_json, "Use my custom checks"), "custom text encrypted in storage")
	}
	after := list_chat_messages_handler(&f.handlers, mq_http_req("/api/v1/chats/chat_mq/messages", ""))
	testing.expect(t, strings.contains(after.body, `"answer_message_id":"msg_answer_`), "answered state projects on source after reload")
	testing.expect(t, strings.contains(after.body, `"is_latest_message":false`), "answer expires source controls")
	unchanged, _, _ := iface.content_get_message(&f.repo, source.message_id)
	testing.expect_value(t, unchanged.body, source.body)
	testing.expect_value(t, unchanged.metadata_json, source.metadata_json)
	// A newer durable message cannot break recovery of a committed answer.
	_, _, _ = iface.content_save_message(&f.repo, domain.Chat_Message{message_id = "msg_new", conversation_id = "chat_mq", owner_user_id = source.owner_user_id, direction = "agent_to_user", body = "Newer", created_at = source.created_at})
	replay := mq_http_answer(&f, source.message_id, raw)
	testing.expect_value(t, replay.status, 200)
	testing.expect(t, strings.contains(replay.body, `"replayed":true`), "same-key replay succeeds after newer message")
	testing.expect_value(t, sync.atomic_load(&f.notifications), 1)
	conflict := mq_http_answer(&f, source.message_id, mq_http_submission("another_device"))
	testing.expect_value(t, conflict.status, 409)
	testing.expect(t, strings.contains(conflict.body, "question_answered"), "another key cannot answer twice")
}

@(test)
test_multi_question_http_latest_only_and_ownership :: proc(t: ^testing.T) {
	f: MQ_HTTP_Fixture
	mq_http_open(t, &f, "mq_freshness")
	defer mq_http_base_close(f.base)
	source := mq_http_source(t, &f)
	raw := mq_http_submission("request_1")
	foreign_response := mq_http_answer(&f, source.message_id, raw, "other_user")
	testing.expect_value(t, foreign_response.status, 404)
	wrong_conversation := mq_http_answer(&f, source.message_id, raw, cid = "chat_other")
	testing.expect_value(t, wrong_conversation.status, 404)
	// Agent-to-agent rows are durable but not user-visible; they do not expire it.
	_, _, _ = iface.content_save_message(&f.repo, domain.Chat_Message{message_id = "msg_a2a", conversation_id = "chat_mq", owner_user_id = source.owner_user_id, direction = "agent_to_agent", body = "Internal", created_at = source.created_at})
	good := mq_http_answer(&f, source.message_id, raw)
	testing.expect_value(t, good.status, 201)
	// Exact timestamp tie, and the newer ID sorts BEFORE the source. Both user
	// and agent messages must expire a penultimate source immediately.
	for direction in ([]string{"user_to_agent", "agent_to_user"}) {
		latest := mq_http_source(t, &f)
		_, _, _ = iface.content_save_message(&f.repo, domain.Chat_Message{message_id = fmt.tprintf("aaa_%s", direction), conversation_id = "chat_mq", owner_user_id = source.owner_user_id, direction = direction, body = "Newer", created_at = latest.created_at})
		rows, _ := content_service.list_user_visible_messages(&f.svc, {kind = .User_Token, user_id = f.base.owner_user_id}, "chat_mq", 1, "")
		if testing.expect_value(t, len(rows), 1) do testing.expect_value(t, rows[0].message_id, fmt.tprintf("aaa_%s", direction))
		stale := mq_http_answer(&f, latest.message_id, raw)
		testing.expect_value(t, stale.status, 409)
		testing.expect(t, strings.contains(stale.body, "question_stale"), "penultimate source is stale with just one newer row")
	}
	testing.expect_value(t, sync.atomic_load(&f.notifications), 1)
}

@(test)
test_multi_question_http_invalid_answers :: proc(t: ^testing.T) {
	f: MQ_HTTP_Fixture
	mq_http_open(t, &f, "mq_invalid")
	defer mq_http_base_close(f.base)
	source := mq_http_source(t, &f)
	valid := mq_http_submission("request_1")
	for raw in ([]string{
		"{", `{"version":1}`, mq_test_replace(valid, `"stage"`, `"unknown"`),
		mq_test_replace(valid, `["stage"]`, `["stage","prod"]`),
		mq_test_replace(valid, `"question_id":"checks"`, `"question_id":"unknown"`),
		mq_test_replace(valid, `"question_id":"checks"`, `"question_id":"target"`),
	}) {
		response := mq_http_answer(&f, source.message_id, raw)
		testing.expect_value(t, response.status, 400)
		testing.expect(t, strings.contains(response.body, "question_invalid"), "clear validation code")
	}
	testing.expect_value(t, sync.atomic_load(&f.notifications), 0)
	response := mq_http_answer(&f, source.message_id, valid)
	testing.expect_value(t, response.status, 201)
}

@(test)
test_multi_question_http_legacy_metadata_and_types :: proc(t: ^testing.T) {
	f: MQ_HTTP_Fixture
	mq_http_open(t, &f, "mq_legacy")
	defer mq_http_base_close(f.base)
	sealed := mq_http_seal("Legacy choose a target")
	raw := fmt.tprintf(`{{"agent_instance_id":"inst_mq","params":{{"body":"%s","options":["Staging","Production"],"action_ids":["crd_1"]}}}}`, sealed)
	req := mq_http_req("/api/v1/agent-actions/chat/send-to-user", raw)
	req.headers = {{name = "Authorization", value = fmt.tprintf("Bearer %s", f.base.bridge_token)}}
	response := agent_action_chat_send_to_user_handler(&f.agent_handlers, req)
	testing.expect_value(t, response.status, 201)
	testing.expect(t, strings.contains(response.body, `"message_type":"text"`), "legacy default type unchanged")
	testing.expect(t, strings.contains(response.body, `"options":["Staging","Production"]`), "legacy flat options preserved")
	testing.expect(t, strings.contains(response.body, `"action_ids":["crd_1"]`), "legacy action IDs preserved")
	testing.expect(t, strings.contains(response.body, `"is_latest_message":true`), "flat chips get full-conversation latest hint")
	legacy_id := jsonx.extract_string(response.body, "message_id", allocator = context.temp_allocator)
	// Propagate intentional non-text types as well as the new multi_question.
	req.body = fmt.tprintf(`{{"agent_instance_id":"inst_mq","params":{{"body":"%s","message_type":"system"}}}}`, sealed)
	system := agent_action_chat_send_to_user_handler(&f.agent_handlers, req)
	testing.expect_value(t, system.status, 201)
	testing.expect(t, strings.contains(system.body, `"message_type":"system"`), "system type deliberately propagated")
	legacy, _, _ := iface.content_get_message(&f.repo, legacy_id)
	b := strings.builder_make(context.temp_allocator)
	write_message_json(&b, legacy, &f.svc)
	testing.expect(t, strings.contains(strings.to_string(b), `"is_latest_message":false`), "any newer durable visible type expires old chips")
	// New structured human text is never silently accepted in plaintext.
	req.body = fmt.tprintf(`{{"agent_instance_id":"inst_mq","params":{{"body":"%s","message_type":"multi_question","metadata":{{"multi_question":{{"version":1,"questions":[{{"id":"q","text":"unsealed","options":[{{"id":"a","label":"unsealed"}}]}}]}}}}}}}}`, sealed)
	invalid := agent_action_chat_send_to_user_handler(&f.agent_handlers, req)
	testing.expect_value(t, invalid.status, 400)
	testing.expect(t, strings.contains(invalid.body, "question_invalid"), "unsealed grouped payload rejected before persistence")
}

MQ_HTTP_Racer :: struct {
	f: ^MQ_HTTP_Fixture,
	source_id, body: string,
	start: ^bool,
	status: int,
}

mq_http_racer :: proc(t: ^thread.Thread) {
	r := (^MQ_HTTP_Racer)(t.data)
	for !sync.atomic_load(r.start) {}
	response := mq_http_answer(r.f, r.source_id, r.body)
	r.status = response.status
}

@(test)
test_multi_question_http_parallel_duplicates :: proc(t: ^testing.T) {
	f: MQ_HTTP_Fixture
	mq_http_open(t, &f, "mq_parallel")
	defer mq_http_base_close(f.base)
	for same_key in ([]bool{true, false}) {
		source := mq_http_source(t, &f)
		racers: [8]MQ_HTTP_Racer
		threads: [8]^thread.Thread
		start := false
		before := sync.atomic_load(&f.notifications)
		for &r, i in racers {
			key := "same_key" if same_key else fmt.tprintf("key_%d", i)
			r = {f = &f, source_id = source.message_id, body = mq_http_submission(key), start = &start}
			threads[i] = thread.create(mq_http_racer)
			threads[i].data = &r
			thread.start(threads[i])
		}
		sync.atomic_store(&start, true)
		inserted, replayed, refused := 0, 0, 0
		for th, i in threads {
			thread.join(th)
			thread.destroy(th)
			switch racers[i].status {case 201: inserted += 1; case 200: replayed += 1; case 409: refused += 1}
		}
		testing.expect_value(t, inserted, 1)
		testing.expect_value(t, replayed, 7 if same_key else 0)
		testing.expect_value(t, refused, 0 if same_key else 7)
		testing.expect_value(t, sync.atomic_load(&f.notifications) - before, 1)
		rows, _ := iface.content_list_messages(&f.repo, "chat_mq", source.owner_user_id, 200, "")
		count := 0
		for m in rows do if m.message_id == content_service.question_answer_id(source.message_id) do count += 1
		testing.expect_value(t, count, 1)
	}
}

mq_test_replace :: proc(s, old, replacement: string) -> string {
 out, _ := strings.replace_all(s, old, replacement, context.temp_allocator)
 return out
}
