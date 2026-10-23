package http

import "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import content_service "odin_test:hub/service/content"
import jsonx "odin_test:lib/jsonx"

write_question_answer_state :: proc(b: ^strings.Builder, source: domain.Chat_Message, svc: ^content_service.Content_Service) {
	if svc == nil do return
	_, flat_options := jsonx.extract_raw_array(source.metadata_json, "options", top_level_only = true, allocator = context.temp_allocator)
	if source.message_type != "multi_question" && !flat_options do return
	// A server eligibility hint is independent of pagination, UI grouping, and
	// timestamp ties. Clients still invalidate it immediately on any newer row.
	strings.write_string(b, ",\"is_latest_message\":")
	strings.write_string(b, "true" if content_service.message_is_latest_visible(svc, source) else "false")
	if source.message_type != "multi_question" do return
	strings.write_string(b, ",\"question_answer\":")
	state, err := content_service.question_answer_state(svc, source)
	if err.code != .None || state.answer_message_id == "" {
		strings.write_string(b, "null")
		return
	}
	encoded, _ := json.marshal(state, allocator = context.temp_allocator)
	strings.write_string(b, string(encoded))
}

answer_chat_questions_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Content_Handlers)(ctx)
	auth, ok, resp := require_auth(h.auth, req)
	if !ok do return resp
	input, invalid := contracts.multi_question_parse_submission(req.body)
	if invalid != "" do return respond_error(domain.domain_error(.Question_Invalid, invalid), req.request_id)
	cid, source_id := path_part(req.path, 4), path_part(req.path, 6)
	// Persist before waking/restarting the agent: invalid or stale forms must not
	// start an instance. Normal inbox notification is issued only by the winner.
	m, inserted, err := content_service.answer_questions(h.content, auth, cid, source_id, input)
	if err.code != .None do return respond_error(err, req.request_id)
	if inserted {
		publish_user_message_created(h, auth, cid, m)
		// Wake stopped agents through the same lifecycle path as normal sends.
		// A restart failure must not turn a committed answer into a failed submit;
		// its durable inbox record remains available to the next instance wake.
		_, _ = restart_stopped_conversation_instance(h, auth, cid)
	}
	b := strings.builder_make()
	strings.write_string(&b, "{\"message\":")
	write_message_json(&b, m, h.content)
	strings.write_string(&b, ",\"question_answer\":")
	state, _ := json.marshal(content_service.Question_Answer_State{answer_message_id = m.message_id, answered_at = m.created_at}, allocator = context.temp_allocator)
	strings.write_string(&b, string(state))
	strings.write_string(&b, ",\"replayed\":")
	strings.write_string(&b, "false" if inserted else "true")
	strings.write_byte(&b, '}')
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201 if inserted else 200)
}
