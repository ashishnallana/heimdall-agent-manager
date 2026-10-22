package content

// REQ-EXT-CONV-1/2 — `tool_activity` conversation messages.
//
// The bridge aggregates an agent's ham.ext.v1 tool calls per turn
// (src/bridge/extension_tool_aggregator.odin) and posts one compact message per
// flush through POST /api/v1/agent-actions/tool-activity. This is the write.
//
// DELIVERY CHOICE. A dedicated agent-actions route rather than the agent's own
// chat/send-to-user path, because that path is the agent SPEAKING to the user:
// it bumps unread_count, moves the conversation preview, raises a toast, an OS
// notification and web push, and feeds the attention projector. A tool_activity
// message is none of those. It is a lean, system-like marker in the shape of
// `pane_capture` and `shell_run` (shell_run_marker.odin): a message_type the UI
// switches on, a small metadata_json and a short body for clients that do not
// know the type. Specifically:
//
//   - written already delivered AND read (delivered_at = read_at = created_at),
//     so no unread counter or "unread agent messages" query ever counts it;
//   - saved with iface.content_save_message directly, NOT save_message: there is
//     nothing for the attention projector to recompute on every flush;
//   - the conversation row is left alone (no unread bump, no preview change), so
//     a burst of tool activity never buries the agent's last real reply;
//   - the realtime frame the handler publishes carries no body_preview and a
//     non-agent_to_user direction, which the UI treats as a silent refetch.
//
// TRUST: the body and metadata come from the bridge (bridge token + bridge-held
// instance token, never the agent's own CLI), are plaintext like the
// agent_extension_events they summarise, and are capped here regardless of the
// bridge's own 4KB budget.

import json "core:encoding/json"
import "core:strings"
import "core:unicode/utf8"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

TOOL_ACTIVITY_MESSAGE_TYPE :: "tool_activity"
// The bridge keeps metadata ≤ 4KB; the hub tolerates up to twice that so a
// slightly newer bridge is not rejected, and refuses anything larger.
TOOL_ACTIVITY_METADATA_MAX_BYTES :: 8 * 1024
TOOL_ACTIVITY_BODY_MAX_BYTES :: 280

// tool_activity_clip_body trims and cuts body to TOOL_ACTIVITY_BODY_MAX_BYTES on
// a UTF-8 boundary. The result aliases body.
tool_activity_clip_body :: proc(body: string) -> string {
	b := strings.trim_space(body)
	if len(b) <= TOOL_ACTIVITY_BODY_MAX_BYTES do return b
	cut := TOOL_ACTIVITY_BODY_MAX_BYTES
	for cut > 0 && !utf8.rune_start(b[cut]) do cut -= 1
	return b[:cut]
}

// tool_activity_metadata_valid reports whether metadata is a JSON object within
// the size cap.
tool_activity_metadata_valid :: proc(metadata: string) -> bool {
	m := strings.trim_space(metadata)
	if m == "" || len(m) > TOOL_ACTIVITY_METADATA_MAX_BYTES || m[0] != '{' do return false
	v, err := json.parse_string(m, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if err != .None do return false
	_, is_obj := v.(json.Object)
	return is_obj
}

// record_tool_activity_message writes one tool_activity message into the
// conversation of the token-verified instance. Returns the saved message and
// its conversation (the handler needs both for the realtime frame).
record_tool_activity_message :: proc(
	s: ^Content_Service,
	auth: contracts.Auth_Context,
	instance_id, body, metadata_json: string,
) -> (domain.Chat_Message, domain.Chat_Conversation, bool, domain.Domain_Error) {
	if s == nil || s.content == nil do return {}, {}, false, domain.domain_error(.Internal_Error, "content repository is not configured")
	if auth.kind != .Instance_Token || auth.agent_instance_id == "" || auth.agent_instance_id != instance_id {
		return {}, {}, false, domain.domain_error(.Forbidden, "instance token is required")
	}
	text := tool_activity_clip_body(body)
	if text == "" do return {}, {}, false, domain.domain_error(.Validation_Failed, "body is required")
	if !tool_activity_metadata_valid(metadata_json) {
		return {}, {}, false, domain.domain_error(.Validation_Failed, "metadata must be a JSON object of at most 8KB")
	}
	c, ok, err := get_conversation_by_instance(s, auth, instance_id)
	if !ok do return {}, {}, false, err

	now := platform.clock_now(s.clock)
	m := domain.Chat_Message{
		message_id               = platform.generate_id(s.ids, "msg_"),
		conversation_id          = c.conversation_id,
		owner_user_id            = c.owner_user_id,
		direction                = "agent_to_user",
		sender_agent_id          = c.agent_id,
		sender_agent_instance_id = c.agent_instance_id,
		body                     = text,
		artifact_ids_json        = "[]",
		message_type             = TOOL_ACTIVITY_MESSAGE_TYPE,
		message_status           = "complete",
		metadata_json            = strings.trim_space(metadata_json),
		created_at               = now,
		delivered_at             = now,
		read_at                  = now,
	}
	saved, save_ok, save_err := iface.content_save_message(s.content, m)
	if !save_ok do return {}, {}, false, save_err
	return saved, c, true, {}
}
