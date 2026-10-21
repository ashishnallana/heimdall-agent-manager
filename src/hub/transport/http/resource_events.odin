package http

import "core:fmt"
import "core:strings"

import domain "odin_test:hub/domain"
import events "odin_test:hub/service/events"

// Targeted resource-change hints for event-driven UI refresh (REQ-2, chain
// chain_18e07ff905d87912 task refresh_producers). Every helper here is called
// only AFTER the write it describes has returned success, and every payload is
// ids + metadata only: message bodies, previews and vault material never go on
// the bus. Events are hints; the UI refetches durable state behind them.
//
// Contract (stable names; additive fields only):
//   chat_event  event=message_created  {conversation_id, agent_instance_id,
//       message_id, direction, message_type, created_at, last_message_at,
//       unread_count, fetch_required:true, fetch_kind:"chat_message", fetch_id}
//   resource_changed resource=conversation change=created|updated
//       summary {agent_instance_id, chain_id, title, last_message_at,
//       unread_count, updated_at}

// chat_message_created_event_json describes a message that was just persisted
// in conversation c (c is the post-write conversation row).
chat_message_created_event_json :: proc(c: domain.Chat_Conversation, m: domain.Chat_Message) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"chat_event\",\"event\":\"message_created\",\"conversation_id\":\"")
	write_handler_json_string(&b, c.conversation_id)
	strings.write_string(&b, "\",\"agent_instance_id\":\"")
	write_handler_json_string(&b, c.agent_instance_id)
	strings.write_string(&b, "\",\"message_id\":\"")
	write_handler_json_string(&b, m.message_id)
	strings.write_string(&b, "\",\"direction\":\"")
	write_handler_json_string(&b, m.direction)
	strings.write_string(&b, "\",\"message_type\":\"")
	write_handler_json_string(&b, m.message_type)
	strings.write_string(&b, "\",\"created_at\":\"")
	write_handler_json_string(&b, m.created_at)
	strings.write_string(&b, "\",\"last_message_at\":\"")
	write_handler_json_string(&b, c.last_message_at)
	fmt.sbprintf(&b, "\",\"unread_count\":%d", c.unread_count)
	strings.write_string(&b, ",\"fetch_required\":true,\"fetch_kind\":\"chat_message\",\"fetch_id\":\"")
	write_handler_json_string(&b, m.message_id)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

publish_chat_message_created :: proc(bus: ^events.User_Event_Bus, c: domain.Chat_Conversation, m: domain.Chat_Message) {
	if bus == nil || c.owner_user_id == "" do return
	events.publish_owned(bus, string(c.owner_user_id), chat_message_created_event_json(c, m))
}

conversation_summary_json :: proc(c: domain.Chat_Conversation) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"agent_instance_id\":\"")
	write_handler_json_string(&b, c.agent_instance_id)
	strings.write_string(&b, "\",\"chain_id\":\"")
	write_handler_json_string(&b, c.chain_id)
	strings.write_string(&b, "\",\"title\":\"")
	write_handler_json_string(&b, c.title)
	strings.write_string(&b, "\",\"last_message_at\":\"")
	write_handler_json_string(&b, c.last_message_at)
	fmt.sbprintf(&b, "\",\"unread_count\":%d,\"updated_at\":\"", c.unread_count)
	write_handler_json_string(&b, c.updated_at)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

// publish_conversation_changed emits resource_changed/conversation with the
// sidebar-relevant summary. change is "created" or "updated".
publish_conversation_changed :: proc(bus: ^events.User_Event_Bus, c: domain.Chat_Conversation, change: string) {
	if bus == nil || c.owner_user_id == "" || c.conversation_id == "" do return
	summary := conversation_summary_json(c)
	defer delete(summary)
	events.publish_resource_changed(bus, string(c.owner_user_id), "conversation", c.conversation_id, change, summary)
}

//   resource_changed resource=agent_instance_reconfiguration
//       resource_id=<agent_instance_id> change=created|progress|error|succeeded|failed
//       summary {reconfiguration_id, phase, revision, error_code}
//   resource_changed resource=agent_instance change=<caller's change>
//       summary = instance_changed_summary_json (status fields + display_name,
//       bridge_id, provider, model, configuration_revision, run_count,
//       started_at, current_task_id, current_task_role, chain_id, updated_at)
reconfiguration_summary_json :: proc(op: domain.Instance_Reconfiguration) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"reconfiguration_id\":\"")
	write_handler_json_string(&b, op.operation_id)
	strings.write_string(&b, "\",\"phase\":\"")
	write_handler_json_string(&b, domain.instance_reconfiguration_phase_string(op.phase))
	fmt.sbprintf(&b, "\",\"revision\":%d,\"error_code\":\"", op.revision)
	write_handler_json_string(&b, op.failure_code)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

publish_reconfiguration_changed :: proc(bus: ^events.User_Event_Bus, op: domain.Instance_Reconfiguration, change: string) {
	if bus == nil || op.owner_user_id == "" || op.agent_instance_id == "" do return
	summary := reconfiguration_summary_json(op)
	defer delete(summary)
	events.publish_resource_changed(bus, op.owner_user_id, "agent_instance_reconfiguration", op.agent_instance_id, change, summary)
}

instance_changed_summary_json :: proc(inst: domain.Agent_Instance) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"runtime_status\":\""); write_handler_json_string(&b, inst.runtime_status)
	strings.write_string(&b, "\",\"startup_status\":\""); write_handler_json_string(&b, inst.startup_status)
	strings.write_string(&b, "\",\"activity_status\":\""); write_handler_json_string(&b, inst.activity_status)
	strings.write_string(&b, "\",\"display_name\":\""); write_handler_json_string(&b, inst.display_name)
	strings.write_string(&b, "\",\"bridge_id\":\""); write_handler_json_string(&b, inst.bridge_id)
	strings.write_string(&b, "\",\"provider\":\""); write_handler_json_string(&b, inst.provider)
	strings.write_string(&b, "\",\"model\":\""); write_handler_json_string(&b, inst.model)
	fmt.sbprintf(&b, "\",\"configuration_revision\":%d,\"run_count\":%d,\"started_at\":\"", inst.configuration_revision, inst.run_count)
	write_handler_json_string(&b, inst.started_at)
	strings.write_string(&b, "\",\"current_task_id\":\""); write_handler_json_string(&b, inst.current_task_id)
	strings.write_string(&b, "\",\"current_task_role\":\""); write_handler_json_string(&b, domain.current_task_role_string(inst.current_task_role))
	strings.write_string(&b, "\",\"chain_id\":\""); write_handler_json_string(&b, inst.chain_id)
	strings.write_string(&b, "\",\"updated_at\":\""); write_handler_json_string(&b, inst.updated_at)
	strings.write_string(&b, "\"")
	write_last_error_json(&b, inst.last_error_json)
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// publish_instance_changed is the one helper for agent_instance hints: callers
// pass the post-write row (re-read it when the writer does not return one).
publish_instance_changed :: proc(bus: ^events.User_Event_Bus, inst: domain.Agent_Instance, change: string) {
	if bus == nil || inst.owner_user_id == "" || inst.agent_instance_id == "" do return
	summary := instance_changed_summary_json(inst)
	defer delete(summary)
	events.publish_resource_changed(bus, string(inst.owner_user_id), "agent_instance", inst.agent_instance_id, change, summary)
}

// publish_instance_created announces a new instance and the conversation that
// create_instance/prepare_instance bound to it (every creation path: POST
// /agent-instances, POST /chats, chain coordinator, action, taskv2 JIT). The
// conversation summary is built from the instance row: its title is the
// default run title, and consumers refetch the list anyway.
publish_instance_created :: proc(bus: ^events.User_Event_Bus, inst: domain.Agent_Instance) {
	publish_instance_changed(bus, inst, "created")
	if inst.conversation_id == "" do return
	publish_conversation_changed(bus, domain.Chat_Conversation{conversation_id = inst.conversation_id, owner_user_id = inst.owner_user_id, agent_instance_id = inst.agent_instance_id, chain_id = inst.chain_id, title = inst.display_name, updated_at = inst.updated_at}, "created")
}

//   resource_changed resource=agent change=created|updated|archived|support_changed
//       summary {agent_id, bridge_id?}
// publish_agent_changed: owner is the authenticated user (agents are owner-scoped
// and require_owner already passed in the service call).
publish_agent_changed :: proc(bus: ^events.User_Event_Bus, owner_user_id, agent_id, change: string, bridge_id := "") {
	if bus == nil || owner_user_id == "" || agent_id == "" do return
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "{\"agent_id\":\"")
	write_handler_json_string(&b, agent_id)
	if bridge_id != "" {
		strings.write_string(&b, "\",\"bridge_id\":\"")
		write_handler_json_string(&b, bridge_id)
	}
	strings.write_string(&b, "\"}")
	events.publish_resource_changed(bus, owner_user_id, "agent", agent_id, change, strings.to_string(b))
}

//   resource_changed resource=bridge change=updated|revoked|capabilities_changed
//       summary {status, version, update_status}
//   resource_changed resource=bridge change=provider_status_changed
//       summary {provider} ("" = every provider of the bridge, e.g. discovery)
publish_bridge_changed :: proc(bus: ^events.User_Event_Bus, bridge: domain.Bridge, change: string) {
	if bus == nil || bridge.owner_user_id == "" || bridge.bridge_id == "" do return
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "{\"status\":\"")
	write_handler_json_string(&b, domain.bridge_status_string(bridge.status))
	strings.write_string(&b, "\",\"version\":\"")
	write_handler_json_string(&b, bridge.version)
	strings.write_string(&b, "\",\"update_status\":\"")
	write_handler_json_string(&b, bridge.update_status)
	strings.write_string(&b, "\"}")
	events.publish_resource_changed(bus, string(bridge.owner_user_id), "bridge", bridge.bridge_id, change, strings.to_string(b))
}

publish_bridge_provider_status_changed :: proc(bus: ^events.User_Event_Bus, owner_user_id, bridge_id, provider: string) {
	if bus == nil || owner_user_id == "" || bridge_id == "" do return
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "{\"provider\":\"")
	write_handler_json_string(&b, provider)
	strings.write_string(&b, "\"}")
	events.publish_resource_changed(bus, owner_user_id, "bridge", bridge_id, "provider_status_changed", strings.to_string(b))
}
