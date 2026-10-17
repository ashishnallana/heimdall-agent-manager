package content

import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Attention write-through (attention deck v1). Every chat-message write in this
// package goes through these helpers, so the card projector hears about each
// change that can alter an instance's "latest unread message with options"
// card: a new or updated agent message, the user reading the conversation, or
// the user replying. The projector re-reads the current state itself, so the
// notification carries only the owner and the agent instance id.

set_attention_notifier :: proc(s: ^Content_Service, n: ^contracts.Attention_Notifier) {
	if s == nil do return
	s.attention = n
}

save_message :: proc(s: ^Content_Service, m: domain.Chat_Message) -> (domain.Chat_Message, bool, domain.Domain_Error) {
	saved, ok, err := iface.content_save_message(s.content, m)
	if ok do notify_message_attention(s, saved)
	return saved, ok, err
}

update_message :: proc(s: ^Content_Service, owner: domain.User_ID, conversation_id, message_id, body, status, metadata_json: string) -> (domain.Chat_Message, bool, domain.Domain_Error) {
	updated, ok, err := iface.content_update_message(s.content, owner, conversation_id, message_id, body, status, metadata_json)
	if ok do notify_message_attention(s, updated)
	return updated, ok, err
}

// notify_message_attention reports a message write. Agent messages are keyed by
// their sender instance; a user reply is keyed by the conversation's instance,
// because replying answers that instance's pending question.
notify_message_attention :: proc(s: ^Content_Service, m: domain.Chat_Message) {
	if s == nil || s.attention == nil do return
	switch m.direction {
	case "agent_to_user":
		contracts.attention_notify(s.attention, string(m.owner_user_id), contracts.ATTENTION_SOURCE_AGENT_MESSAGE, m.sender_agent_instance_id)
	case "user_to_agent":
		c, ok, _ := iface.content_get_conversation(s.content, m.conversation_id)
		if ok do notify_conversation_attention(s, c)
	}
}

// save_memory is the single memory write path in this package: a proposal
// being created, edited, approved, rejected or archived changes whether it
// needs the user, so each write reports it to the projector.
save_memory :: proc(s: ^Content_Service, m: domain.Memory) -> (domain.Memory, bool, domain.Domain_Error) {
	saved, ok, err := iface.content_save_memory(s.content, m)
	if ok && s.attention != nil {
		contracts.attention_notify(s.attention, string(saved.owner_user_id), contracts.ATTENTION_SOURCE_MEMORY, saved.memory_id)
	}
	return saved, ok, err
}

notify_conversation_attention :: proc(s: ^Content_Service, c: domain.Chat_Conversation) {
	if s == nil || s.attention == nil do return
	contracts.attention_notify(s.attention, string(c.owner_user_id), contracts.ATTENTION_SOURCE_AGENT_MESSAGE, c.agent_instance_id)
}
