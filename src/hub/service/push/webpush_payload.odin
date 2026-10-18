package push

// WP-SEND-2 payload construction. The plaintext JSON the Hub encrypts mirrors
// the client notify policy in src/ui/api/notificationMapper.ts + the WIRE
// CONTRACT: {title, body, tag, route, category, href}. The service worker reads
// it via event.data.json() and always shows a notification.
//
// Only user-actionable events produce a payload — chat (agent->user messages)
// and attention. Everything else (resource_changed churn, lifecycle, etc.) must
// NOT push, matching the in-page mapper's exclusions.

import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"

// Push_Category is the curated bucket carried in the payload; mirrors the
// client's NotificationCategory ('chat' | 'attention').
Push_Category :: enum {
	Chat,
	Attention,
}

push_category_string :: proc(category: Push_Category) -> string {
	switch category {
	case .Chat:      return "chat"
	case .Attention: return "attention"
	}
	return "attention"
}

// Notification_Content is the resolved, human-facing content for a push. Build
// it from a domain event, then render to JSON with build_push_payload_json.
Notification_Content :: struct {
	title:    string,
	body:     string,
	tag:      string,
	route:    string,
	category: Push_Category,
}

// PUSH_PREVIEW_MAX mirrors the client mapper's 140-rune body/preview cap.
PUSH_PREVIEW_MAX :: 140

// The service worker cannot access the in-page Vault key. Mask armored content
// before applying the preview cap so Web Push never carries a truncated,
// undecryptable ciphertext fragment into operating-system notification history.
PUSH_ENCRYPTED_PLACEHOLDER :: "[🔒 Encrypted notification]"

// build_chat_notification builds the chat-message notification content,
// mirroring planForChatEvent in notificationMapper.ts: title reflects
// nudge/mention/plain, the body is a truncated preview. The deep-link route keys
// on the AGENT INSTANCE id because conversation routing is instance-id-only
// (#/conversations/{agent_instance_id}); the conversation_id is NOT a valid route
// target. The coalescing tag still keys on conversation_id (fallback instance id)
// for dedup only — that is independent of routing.
build_chat_notification :: proc(
	conversation_id: string,
	agent_instance_id: string,
	message_type: string,
	body_preview: string,
) -> Notification_Content {
	// route/tag are ALWAYS heap-allocated (even the fallbacks) so callers can
	// unconditionally free them via free_notification_content without risking a
	// delete() on a static string literal.
	// Conversation routing is instance-id-only, so the route MUST use the agent
	// instance id; when it is empty we fall back to the plain '/conversations'
	// landing route rather than embedding a non-routable conversation_id.
	route := agent_instance_id != "" ? strings.concatenate({"/conversations/", agent_instance_id}) : strings.clone("/conversations")

	tag_id := conversation_id != "" ? conversation_id : agent_instance_id
	if tag_id == "" do tag_id = "unknown"
	tag := strings.concatenate({"heimdall:chat:", tag_id})

	title := "New message"
	switch message_type {
	case "nudge":   title = "Nudge"
	case "mention": title = "You were mentioned"
	}

	return Notification_Content{
		title    = title,
		body     = push_preview(body_preview, PUSH_PREVIEW_MAX),
		tag      = tag,
		route    = route,
		category = .Chat,
	}
}

// free_notification_content frees the heap strings owned by a Notification_Content
// produced by build_chat_notification (tag/route are always allocated; body is
// allocated by push_preview). Keeping the ownership rules in the allocating
// package means callers just `defer free_notification_content(content)`.
free_notification_content :: proc(content: Notification_Content) {
	delete(content.body)
	delete(content.tag)
	delete(content.route)
}

// build_push_payload_json renders the WIRE CONTRACT push payload JSON. `href` is
// the absolute deep-link the service worker opens on click; when app_origin is
// set it is app_origin + "/#" + route, else "".
build_push_payload_json :: proc(content: Notification_Content, app_origin: string) -> string {
	href := ""
	if app_origin != "" {
		href = strings.concatenate({strings.trim_right(app_origin, "/"), "/#", content.route})
	}
	defer if href != "" do delete(href)

	b := strings.builder_make()
	strings.write_string(&b, "{\"title\":\"")
	contracts.write_json_string(&b, content.title)
	strings.write_string(&b, "\",\"body\":\"")
	contracts.write_json_string(&b, content.body)
	strings.write_string(&b, "\",\"tag\":\"")
	contracts.write_json_string(&b, content.tag)
	strings.write_string(&b, "\",\"route\":\"")
	contracts.write_json_string(&b, content.route)
	strings.write_string(&b, "\",\"category\":\"")
	contracts.write_json_string(&b, push_category_string(content.category))
	strings.write_string(&b, "\",\"href\":\"")
	contracts.write_json_string(&b, href)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

// push_preview collapses internal whitespace and truncates to max_len runes,
// appending an ellipsis when clipped. Mirrors the client truncate()/preview.
push_preview :: proc(body: string, max_len: int) -> string {
	trimmed := strings.trim_space(body)
	if trimmed == "" do return ""
	// Fail closed for both standalone armor and sender-prefixed/embedded armor.
	// This check must happen before truncation because truncation destroys the
	// authenticated envelope while leaving a user-visible ciphertext fragment.
	if domain.contains_vault_token(trimmed) {
		return strings.clone(PUSH_ENCRYPTED_PLACEHOLDER)
	}
	fields := strings.fields(trimmed)
	defer delete(fields)
	collapsed := strings.join(fields, " ")
	if len(collapsed) <= max_len {
		return collapsed
	}
	defer delete(collapsed)
	// Truncate on a rune boundary and append a single-char ellipsis.
	end := max_len - 1
	if end < 0 do end = 0
	// Back off to avoid splitting a UTF-8 codepoint.
	for end > 0 && (collapsed[end] & 0xC0) == 0x80 {
		end -= 1
	}
	return strings.concatenate({collapsed[:end], "\u2026"})
}
