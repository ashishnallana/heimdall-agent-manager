package content

import "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import agent_service "odin_test:hub/service/agent"
import jsonx "odin_test:lib/jsonx"

question_answer_id :: proc(source_id: string) -> string {
	return strings.concatenate({"msg_answer_", source_id}, context.temp_allocator)
}

question_group_from_metadata :: proc(metadata: string) -> (contracts.Multi_Question_Group, string) {
	if len(metadata) > contracts.MULTI_QUESTION_MAX_BYTES do return {}, "questions metadata is too large"
	raw, ok := jsonx.extract_raw_object(metadata, "multi_question", top_level_only = true, allocator = context.temp_allocator)
	if !ok do return {}, "multi_question metadata is required"
	return contracts.multi_question_parse(raw, true)
}

validate_question_message :: proc(input: Message_Input) -> string {
	if input.message_type == "multi_question_answer" do return "use the question answer endpoint"
	if input.message_type == "multi_question" {
		if !contracts.multi_question_valid_text(input.body, true, 65536) do return "question message body must be encrypted"
		_, invalid := question_group_from_metadata(input.metadata_json)
		return invalid
	}
	return ""
}

// This read model is reconstructed from the durable answer, so another device or
// a reload sees the same state without a second mutable source-message flag.
Question_Answer_State :: struct { answer_message_id, answered_at: string }

message_is_latest_visible :: proc(s: ^Content_Service, source: domain.Chat_Message) -> bool {
	latest, found, err := iface.content_latest_user_visible_message(s.content, source.conversation_id, source.owner_user_id)
	return err.code == .None && found && latest.message_id == source.message_id
}

question_answer_state :: proc(s: ^Content_Service, source: domain.Chat_Message) -> (Question_Answer_State, domain.Domain_Error) {
	if source.message_type != "multi_question" do return {}, {}
	answer, found, err := iface.content_get_message(s.content, question_answer_id(source.message_id))
	if !found {
		if err.code == .Not_Found do return {}, {}
		return {}, err
	}
	if answer.owner_user_id != source.owner_user_id || answer.conversation_id != source.conversation_id do return {}, domain.domain_error(.Internal_Error, "question answer linkage is invalid")
	return {answer_message_id = answer.message_id, answered_at = answer.created_at}, {}
}

answer_questions :: proc(s: ^Content_Service, auth: contracts.Auth_Context, cid, source_id: string, submission: contracts.Multi_Question_Submission) -> (answer: domain.Chat_Message, inserted: bool, err: domain.Domain_Error) {
	if !contracts.is_user_auth(auth) do return {}, false, domain.domain_error(.Forbidden, "user authentication is required to answer questions")
	c, found, conv_err := get_conversation(s, auth, cid)
	if !found do return {}, false, conv_err
	source, source_found, source_err := iface.content_get_message(s.content, source_id)
	if !source_found do return {}, false, source_err
	if source.owner_user_id != c.owner_user_id || source.conversation_id != cid do return {}, false, domain.domain_error(.Not_Found, "question message not found")
	if source.direction != "agent_to_user" || source.message_type != "multi_question" do return {}, false, domain.domain_error(.Question_Invalid, "source is not an agent question group")
	// Service callers, as well as HTTP, receive the complete structural validation.
	raw, marshal_err := json.marshal(submission, allocator = context.temp_allocator)
	if marshal_err != nil do return {}, false, domain.domain_error(.Question_Invalid, "invalid answer")
	checked, validation := contracts.multi_question_parse_submission(string(raw))
	if validation != "" do return {}, false, domain.domain_error(.Question_Invalid, validation)
	if previous, exists, lookup_err := iface.content_get_message(s.content, question_answer_id(source_id)); exists {
		return question_retry(previous, c, checked.idempotency_key)
	} else if lookup_err.code != .Not_Found do return {}, false, lookup_err
	group, group_err := question_group_from_metadata(source.metadata_json)
	if group_err != "" do return {}, false, domain.domain_error(.Question_Invalid, group_err)
	if invalid := contracts.multi_question_validate_answers(group, checked); invalid != "" do return {}, false, domain.domain_error(.Question_Invalid, invalid)
	// Match the normal user send path's configuration/reconfiguration gates.
	if s.agent_configuration_service != nil {
		if valid, e := agent_service.validate_instance_message_configuration(s.agent_configuration_service, c.owner_user_id, c.agent_instance_id); !valid do return {}, false, e
	} else if idle, e := agent_service.reconfiguration_require_idle(&agent_service.Agent_Service{agents = s.agents}, c.agent_instance_id); !idle do return {}, false, e
	now := platform.clock_now(s.clock)
	metadata := struct {
		multi_question_answer: struct {
			version: int,
			source_message_id, idempotency_key: string,
			answers: []contracts.Multi_Question_Answer,
		},
	}{}
	metadata.multi_question_answer.version = 1
	metadata.multi_question_answer.source_message_id = source_id
	metadata.multi_question_answer.idempotency_key = checked.idempotency_key
	metadata.multi_question_answer.answers = checked.answers
	encoded, _ := json.marshal(metadata, allocator = context.temp_allocator)
	m := domain.Chat_Message{
		message_id = question_answer_id(source_id), conversation_id = cid, owner_user_id = c.owner_user_id,
		direction = "user_to_agent", sender_agent_id = c.agent_id, sender_agent_instance_id = c.agent_instance_id,
		body = checked.body, artifact_ids_json = "[]", message_type = "multi_question_answer", message_status = "complete",
		metadata_json = string(encoded), created_at = now,
	}
	saved, created, save_err := iface.content_answer_question(s.content, source, m)
	if save_err.code != .None do return {}, false, save_err
	if !created do return question_retry(saved, c, checked.idempotency_key)
	notify_message_attention(s, saved)
	c.last_message_preview = saved.body
	c.last_message_at = now
	c.updated_at = now
	_, _, _ = iface.content_save_conversation(s.content, c)
	notify_agent_message(s, c, "user_to_agent", "user", saved.message_id, "User")
	record_activity_and_maybe_nudge(s, cid, now)
	return saved, true, {}
}

question_retry :: proc(previous: domain.Chat_Message, c: domain.Chat_Conversation, key: string) -> (domain.Chat_Message, bool, domain.Domain_Error) {
	if previous.owner_user_id != c.owner_user_id || previous.conversation_id != c.conversation_id do return {}, false, domain.domain_error(.Not_Found, "question answer not found")
	meta, _ := jsonx.extract_raw_object(previous.metadata_json, "multi_question_answer", top_level_only = true, allocator = context.temp_allocator)
	previous_key := jsonx.extract_string(meta, "idempotency_key", top_level_only = true, allocator = context.temp_allocator)
	if key != previous_key do return {}, false, domain.domain_error(.Question_Answered, "These questions have already been answered.")
	return previous, false, {}
}
