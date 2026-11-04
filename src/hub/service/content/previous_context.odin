package content

import "core:crypto/sha2"
import "core:fmt"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// previous_context is the handoff an agent writes for its own next process
// during a context rollover. The bridge intercepts the agent's self-addressed
// chat send and forwards it here on the agent's behalf (T6).
//
// It is stored as an INBOUND (user_to_agent) row in the agent's own
// conversation, because that is the direction every reader already agrees on:
// the user message list shows it (it hides only agent_to_agent), and the
// agent's default `chat read` returns it (receiver_only drops only the caller's
// own agent_to_agent sends). It is never notified to the agent: the process
// that wrote it is about to be restarted, and the restart prompt tells the new
// process to read its messages.
MESSAGE_TYPE_PREVIOUS_CONTEXT :: "previous_context"

Previous_Context_Input :: struct {
	// request_id is chosen by the bridge and is stable across retries.
	request_id:    string,
	// body is stored verbatim (the CLI vault-seals it; the hub never reads it).
	body:          string,
	metadata_json: string,
}

// The persisted row is the deduplication receipt: the id is derived from the
// instance and the bridge's request id, so a retry after a lost ack finds the
// original row instead of writing a second one.
previous_context_message_id :: proc(instance_id, request_id: string) -> string {
	key := fmt.tprintf("%s\n%s", instance_id, request_id)
	digest: [32]byte
	hash: sha2.Context_256
	sha2.init_256(&hash)
	sha2.update(&hash, transmute([]byte)key)
	sha2.final(&hash, digest[:])
	b := strings.builder_make()
	strings.write_string(&b, "msg_pctx_")
	for c in digest do strings.write_string(&b, fmt.tprintf("%02x", c))
	return strings.to_string(b)
}

previous_context_mutex: sync.Mutex

// store_previous_context writes the handoff for the calling instance. created is
// false (with no error) when the request id was already stored; the original row
// is returned unchanged, including its read state.
store_previous_context :: proc(s: ^Content_Service, auth: contracts.Auth_Context, instance_id: string, input: Previous_Context_Input) -> (message: domain.Chat_Message, created: bool, err: domain.Domain_Error) {
	if auth.kind != .Instance_Token || auth.agent_instance_id == "" || auth.agent_instance_id != instance_id do return {}, false, domain.domain_error(.Forbidden, "instance token is required")
	request_id := strings.trim_space(input.request_id)
	if request_id == "" do return {}, false, domain.domain_error(.Validation_Failed, "request_id is required")
	if len(request_id) > 128 do return {}, false, domain.domain_error(.Validation_Failed, "request_id is too long")
	if strings.trim_space(input.body) == "" do return {}, false, domain.domain_error(.Validation_Failed, "message body is required")
	c, conv_ok, conv_err := get_conversation_by_instance(s, auth, instance_id)
	if !conv_ok do return {}, false, conv_err

	id := previous_context_message_id(instance_id, request_id)
	sync.mutex_lock(&previous_context_mutex)
	defer sync.mutex_unlock(&previous_context_mutex)
	if saved, exists, read_err := iface.content_get_message(s.content, id); exists {
		delete(id)
		if saved.conversation_id != c.conversation_id || saved.message_type != MESSAGE_TYPE_PREVIOUS_CONTEXT do return {}, false, domain.domain_error(.Conflict, "request_id was already used for another message")
		return saved, false, {}
	} else if read_err.code != .None && read_err.code != .Not_Found {
		delete(id)
		return {}, false, read_err
	}

	now := platform.clock_now(s.clock)
	m := domain.Chat_Message{
		message_id = id, conversation_id = c.conversation_id, owner_user_id = c.owner_user_id,
		direction = "user_to_agent", sender_agent_id = c.agent_id, sender_agent_instance_id = c.agent_instance_id,
		body = input.body, artifact_ids_json = "[]", message_type = MESSAGE_TYPE_PREVIOUS_CONTEXT,
		metadata_json = input.metadata_json, created_at = now,
	}
	saved, save_ok, save_err := save_message(s, m)
	if !save_ok do return {}, false, save_err
	c.last_message_preview = input.body
	c.last_message_at = now
	c.updated_at = now
	_, _, _ = iface.content_save_conversation(s.content, c)
	// Deliberately no notify_agent_message and no title nudge (see above).
	return saved, true, {}
}
