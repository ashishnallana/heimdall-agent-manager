package content

// REQ-SHELL-5 §2, §3, §4 — the LEAN `shell_run` marker.
//
// A run gets exactly ONE chat message, written at creation, in the conversation of
// whoever triggered it. It is a MARKER, not a report: it names the session and
// nothing else, and the UI resolves the command, the status, the exit code and the
// output live from the session row (and, for output, from the bridge on demand —
// output never reaches this database, see shell_session_get_log).
//
// WHY IT CARRIES NO STATUS, which is the whole design and is easy to undo by
// accident. Status is not in the message because a message that carried status would
// have to be EDITED every time the run changed state, and a run that was later
// converted to background would be indistinguishable from one that was started that
// way. With status left out:
//
//   - the marker is written once and never touched again (REQ-SHELL-5 §4);
//   - a foreground run converted to background mid-flight still has exactly ONE
//     message, because the conversion writes no message at all;
//   - the UI's "pin it above the composer while it is live, collapse it once it is
//     not" is a pure rendering decision off the live row (REQ-SHELL-6 item 2), with
//     no transcript rewrite behind it.
//
// Adding a status, an exit code, output, or the command text to this message breaks
// all three at once. Don't.
//
// THE SHAPE FOLLOWS `pane_capture` (request_pane_capture in content_service.odin),
// which is the established precedent in this codebase for a message the UI renders
// specially rather than as prose: a message_type the renderer switches on, a
// metadata_json carrying the ids it needs, and a short human-readable body for the
// conversation preview and for any client that does not know the type.

import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// SHELL_RUN_MESSAGE_TYPE is the message_type the UI switches on, alongside
// "pane_capture". The column already exists — migration 017_chat_message_types.sql
// added message_type/message_status/metadata_json — so this needs no migration.
SHELL_RUN_MESSAGE_TYPE :: "shell_run"

// SHELL_RUN_MARKER_BODY is the body every marker carries, verbatim.
//
// It is a FIXED string and deliberately not the session id, even though the id is the
// only thing this message is about. metadata_json is the id's carrier (REQ-SHELL-5 §3
// says it carries only the session id); spelling it into the body as well would make
// two fields that must agree forever, which is the duplication this package's comments
// keep warning about. The body exists for the conversation preview and for a client
// that does not know the type, so it reads as a label rather than as an identifier.
SHELL_RUN_MARKER_BODY :: "Shell run"

// record_shell_run_marker writes the single `shell_run` marker for a run.
//
// CONVERSATION SCOPE (REQ-SHELL-5 §2): the marker goes to the ONE conversation named
// by the caller and nowhere else. There is deliberately no chain-wide or user-wide
// fan-out here — not a filtered one, not a second write. A run belongs to the agent
// that triggered it; a server's chain-wide visibility is a different kind with a
// different surface (the chain summary, REQ-SHELL-6).
//
// The caller is the shell_session service, which has already resolved and validated
// the conversation from the agent's own instance rather than from anything the client
// asked for — so this takes a conversation_id it can trust and does not re-derive it.
// It still checks that the conversation exists and that the run's agent owns it,
// because a marker written into somebody else's conversation is exactly the failure
// REQ-SHELL-5 AC5 asks to be impossible, and one guard at the write is cheap.
//
// Returns the saved message and whether it was written. A missing conversation is NOT
// an error worth failing a run over — the run is already spawned and healthy by the
// time this is called — so it reports false and the caller carries on.
record_shell_run_marker :: proc(
	s: ^Content_Service,
	conversation_id, session_id, agent_instance_id: string,
) -> (domain.Chat_Message, bool) {
	if s == nil || s.content == nil do return {}, false
	if strings.trim_space(conversation_id) == "" || strings.trim_space(session_id) == "" do return {}, false

	c, conv_ok, _ := iface.content_get_conversation(s.content, conversation_id)
	if !conv_ok do return {}, false

	// AC5's guard, at the write. The conversation must belong to the agent whose run
	// this is. Unscoped by design elsewhere in this file, but NOT here: the whole
	// point of the marker is that it appears in one conversation and no other.
	if agent_instance_id != "" && c.agent_instance_id != agent_instance_id do return {}, false

	now := platform.clock_now(s.clock)
	m := domain.Chat_Message{
		message_id               = platform.generate_id(s.ids, "msg_"),
		conversation_id          = c.conversation_id,
		owner_user_id            = c.owner_user_id,
		direction                = "agent_to_user",
		sender_agent_id          = c.agent_id,
		sender_agent_instance_id = c.agent_instance_id,
		body                     = SHELL_RUN_MARKER_BODY,
		artifact_ids_json        = "[]",
		message_type             = SHELL_RUN_MESSAGE_TYPE,
		// complete, not pending: unlike a pane_capture — which is a REQUEST awaiting a
		// bridge reply that later rewrites the same row — this message is finished the
		// moment it is written. Nothing ever updates it. The RUN has a lifecycle; the
		// marker does not.
		message_status           = "complete",
		metadata_json            = shell_run_marker_metadata(session_id),
		created_at               = now,
	}
	// STRING OWNERSHIP, stated because it is the kind of thing this chain has already
	// been bitten by twice, in both directions.
	//
	// `m.metadata_json` is TEMP-ALLOCATED (see shell_run_marker_metadata) and is
	// therefore neither freed here nor leaked. Both of the obvious alternatives are
	// wrong, which is why this is spelled out:
	//
	//   delete()ing it would be a bad free at best and a dangling pointer at worst —
	//   the saved message returned below ALIASES it, since a repository returns the
	//   record it was handed and an in-memory one stores that same struct.
	//
	//   heap-allocating and NOT freeing it — which is what request_pane_capture does,
	//   and what this proc did first — is a real per-run leak. The precedent is worth
	//   following for the message SHAPE, not for its allocation.
	//
	// The temp arena is reclaimed per request, and the value is consumed within this
	// request: the sqlite repository copies it when it binds the statement. This is the
	// same contract shell_session_create already documents for its cmd_id.
	//
	// Every other field here is either a literal or owned by `c`.
	saved, save_ok, _ := save_message(s, m)
	if !save_ok do return {}, false

	// Conversation bookkeeping, matching request_pane_capture: move the preview and
	// the activity clock, and deliberately DO NOT touch unread_count. A run the agent
	// started on the user's behalf is not an unread message addressed to the user.
	c.last_message_preview = SHELL_RUN_MARKER_BODY
	c.last_message_at      = now
	c.updated_at           = now
	_, _, _ = iface.content_save_conversation(s.content, c)

	return saved, true
}

// shell_run_marker_metadata builds the marker's metadata_json.
//
// ONE KEY, and REQ-SHELL-5 §3 is explicit that it is one key: {"session_id":"sh_..."}.
// Everything a reader could want besides the id — status, exit code, command, cwd,
// port, timings — lives on the shell_sessions row and is live there, so copying any of
// it here would be a snapshot that silently goes stale the moment the run moves on.
//
// TEMP-ALLOCATED, and the caller does NOT own it — see the ownership note in
// record_shell_run_marker for why neither freeing it nor leaking it is right.
shell_run_marker_metadata :: proc(session_id: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"session_id":"`)
	content_json_write(&b, session_id)
	strings.write_string(&b, `"}`)
	return strings.to_string(b)
}
