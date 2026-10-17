package http

import "core:fmt"
import "core:time"
import "core:strings"
import "core:strconv"
import "core:unicode/utf8"
import internal_b64 "core:encoding/base64"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import auth_service "odin_test:hub/service/auth"
import agent_service "odin_test:hub/service/agent"
import bridge_service "odin_test:hub/service/bridge"
import content_service "odin_test:hub/service/content"
import taskchain_service "odin_test:hub/service/taskchain"
import search_service "odin_test:hub/service/search"
import events "odin_test:hub/service/events"
import push_service "odin_test:hub/service/push"
import provider_service "odin_test:hub/service/provider"
import card_service "odin_test:hub/service/card"
import taskv2 "odin_test:hub/service/taskv2"
import "core:encoding/json"
import jsonx "odin_test:lib/jsonx"

Agent_Action_Handlers :: struct {
	auth: ^auth_service.Auth_Service,
	agents: ^agent_service.Agent_Service,
	bridges: ^bridge_service.Bridge_Service,
	content: ^content_service.Content_Service,
	taskchains: ^taskchain_service.Taskchain_Service,
	search: ^search_service.Search_Service,
	cards: ^card_service.Card_Service,
	event_bus: ^events.User_Event_Bus,
	// Web Push (WP-SEND): background delivery of OS notifications when the user's
	// PWA is closed/backgrounded. public_app_origin builds the absolute click href.
	push: ^push_service.Push_Service,
	public_app_origin: string,
	providers: ^provider_service.Provider_Service,
	// task_engine: Task System v2 lease verbs + implicit heartbeat on every
	// instance-token call. nil in unit tests that do not exercise leases.
	task_engine: ^taskv2.Service,
}

// Lease_Next_Wire is the `lease.next` response: status ∈ granted|current|none.
Lease_Next_Wire :: struct {
	status: string          `json:"status"`,
	lease:  Maybe(Task_Lease_Wire) `json:"lease"`,
	task:   Maybe(Simple_Task_Wire) `json:"task"`,
	pack:   json.Value      `json:"pack"`,
}

make_lease_wire :: proc(l: domain.Task_Lease) -> Task_Lease_Wire {
	return Task_Lease_Wire{
		lease_id = l.lease_id, kind = l.kind, review_role = l.review_role, holder_instance_id = l.holder_instance_id,
		attempt_no = l.attempt_no, bridge_id = l.bridge_id, granted_at = l.granted_at, confirmed_at = l.confirmed_at,
		expires_at = l.expires_at, hard_deadline_at = l.hard_deadline_at, delivery = l.delivery,
	}
}

// POST /api/v1/agent-actions/lease/next  params: {vcs_base?, peek?}
agent_action_lease_next_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, _, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	if h.task_engine == nil do return respond_error(domain.domain_error(.Internal_Error, "task engine is not configured"), req.request_id)
	params := json_object_raw(req.body, "params")
	peek, _ := jsonx.extract_bool_literal(params, "peek", true)
	res, rok, err := taskv2.lease_next(h.task_engine, auth, taskv2.Lease_Next_Input{vcs_base = json_string(params, "vcs_base"), peek = peek})
	if !rok do return respond_error(err, req.request_id)
	wire := Lease_Next_Wire{status = res.status}
	if res.status != "none" {
		wire.lease = make_lease_wire(res.lease)
		wire.task = make_simple_task_wire(res.task)
		wire.pack = json_value_or_null(res.pack_json)
	}
	data, _ := json.marshal(wire, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	return respond_success(string(data), req.request_id, auth_ctx_server_time(req), 200)
}

// POST /api/v1/agent-actions/lease/heartbeat  params: {lease_id?, note?}
agent_action_lease_heartbeat_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, _, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	if h.task_engine == nil do return respond_error(domain.domain_error(.Internal_Error, "task engine is not configured"), req.request_id)
	params := json_object_raw(req.body, "params")
	lease, hok, err := taskv2.lease_heartbeat(h.task_engine, auth, taskv2.Lease_Heartbeat_Input{lease_id = json_string(params, "lease_id"), note = json_string(params, "note")})
	if !hok do return respond_error(err, req.request_id)
	data, _ := json.marshal(make_lease_wire(lease), JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	return respond_success(fmt.tprintf("{{\"lease\":%s}}", string(data)), req.request_id, auth_ctx_server_time(req), 200)
}

// ---- M2 lease verbs ------------------------------------------------------------------

// POST /api/v1/agent-actions/lease/submit  params: {lease_id?, summary, handoff?, output?, vcs?, verify?, artifacts?, auto?}
agent_action_lease_submit_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	if h.task_engine == nil do return respond_error(domain.domain_error(.Internal_Error, "task engine is not configured"), req.request_id)
	// Facet bodies are stored VERBATIM: slice them out of the raw request
	// (never through a parse → marshal round trip).
	params := verbatim_params(req.body)
	res, sok, err := taskv2.lease_submit(h.task_engine, auth, taskv2.Submit_Input{
		lease_id = json_string(params, "lease_id"), summary = json_string(params, "summary"),
		handoff_json = verbatim_field(params, "handoff"), output_json = verbatim_field(params, "output"),
		vcs_json = verbatim_field(params, "vcs"), verify = json_string(params, "verify"),
		artifacts_json = verbatim_field(params, "artifacts"), auto = jsonx.extract_bool(params, "auto", false, true),
	})
	if !sok do return respond_error(err, req.request_id)
	publish_agent_action(h, inst, "lease_submit", fmt.tprintf("submitted %s (%s)", res.task.task_id, res.outcome))
	publish_task_event(h.event_bus, string(res.task.owner_user_id), string(res.task.task_id), string(res.task.chain_id), "updated")
	data, _ := json.marshal(make_simple_task_wire(res.task), JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	return respond_success(fmt.tprintf("{{\"outcome\":\"%s\",\"task\":%s}}", res.outcome, string(data)), req.request_id, auth_ctx_server_time(req), 200)
}

// POST /api/v1/agent-actions/lease/handoff  params: {lease_id?, summary, handoff?, vcs?}
agent_action_lease_handoff_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	if h.task_engine == nil do return respond_error(domain.domain_error(.Internal_Error, "task engine is not configured"), req.request_id)
	params := verbatim_params(req.body)
	task, hok, err := taskv2.lease_handoff(h.task_engine, auth, taskv2.Handoff_Input{lease_id = json_string(params, "lease_id"), summary = json_string(params, "summary"), handoff_json = verbatim_field(params, "handoff"), vcs_json = verbatim_field(params, "vcs")})
	if !hok do return respond_error(err, req.request_id)
	publish_agent_action(h, inst, "lease_handoff", fmt.tprintf("handed off %s", task.task_id))
	publish_task_event(h.event_bus, string(task.owner_user_id), string(task.task_id), string(task.chain_id), "updated")
	data, _ := json.marshal(make_simple_task_wire(task), JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	return respond_success(fmt.tprintf("{{\"task\":%s}}", string(data)), req.request_id, auth_ctx_server_time(req), 200)
}

// POST /api/v1/agent-actions/lease/block  params: {lease_id?, waiting_on:{kind, ref?, reason}, summary?}
agent_action_lease_block_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	if h.task_engine == nil do return respond_error(domain.domain_error(.Internal_Error, "task engine is not configured"), req.request_id)
	params := verbatim_params(req.body)
	task, bok, err := taskv2.lease_block(h.task_engine, auth, taskv2.Block_Input{lease_id = json_string(params, "lease_id"), waiting_on_json = verbatim_field(params, "waiting_on"), summary = json_string(params, "summary")})
	if !bok do return respond_error(err, req.request_id)
	publish_agent_action(h, inst, "lease_block", fmt.tprintf("blocked %s", task.task_id))
	publish_task_event(h.event_bus, string(task.owner_user_id), string(task.task_id), string(task.chain_id), "updated")
	data, _ := json.marshal(make_simple_task_wire(task), JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	return respond_success(fmt.tprintf("{{\"task\":%s}}", string(data)), req.request_id, auth_ctx_server_time(req), 200)
}

// POST /api/v1/agent-actions/review/post  params: {task_id?, verdict, findings?:[…], on_behalf_of?}
agent_action_review_post_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	if h.task_engine == nil do return respond_error(domain.domain_error(.Internal_Error, "task engine is not configured"), req.request_id)
	params := verbatim_params(req.body)
	res, rok, err := taskv2.review_post(h.task_engine, auth, taskv2.Review_Input{task_id = json_string(params, "task_id"), verdict = json_string(params, "verdict"), findings_json = verbatim_field(params, "findings"), on_behalf_of = json_string(params, "on_behalf_of")})
	if !rok do return respond_error(err, req.request_id)
	publish_agent_action(h, inst, "review_post", fmt.tprintf("reviewed %s: %s", res.task.task_id, json_string(params, "verdict")))
	publish_task_event(h.event_bus, string(res.task.owner_user_id), string(res.task.task_id), string(res.task.chain_id), "updated")
	data, _ := json.marshal(make_simple_task_wire(res.task), JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	return respond_success(fmt.tprintf("{{\"gate\":\"%s\",\"task\":%s}}", gate_label(res.gate), string(data)), req.request_id, auth_ctx_server_time(req), 200)
}

gate_label :: proc(g: taskv2.Gate_Result) -> string {
	switch g {
	case .Approved: return "approved"
	case .Changes_Requested: return "changes_requested"
	case .Waiting: return "waiting"
	}
	return "waiting"
}

// POST /api/v1/agent-actions/task/fetch  params: {task_id, ref}
agent_action_task_fetch_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, _, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	if h.task_engine == nil do return respond_error(domain.domain_error(.Internal_Error, "task engine is not configured"), req.request_id)
	params := json_object_raw(req.body, "params")
	task, tok, terr := taskchain_service.get_task_for_read(h.taskchains, auth, domain.Task_ID(json_string(params, "task_id")))
	if !tok do return respond_error(terr, req.request_id)
	raw, fok, err := taskv2.task_fetch(h.task_engine, task, json_string(params, "ref"))
	if !fok do return respond_error(err, req.request_id)
	return respond_success(raw, req.request_id, auth_ctx_server_time(req), 200)
}

agent_action_chat_send_to_user_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	metadata_json := ""
	options := json_array_optional(params, "options")
	action_ids := json_array_optional(params, "action_ids")
	if action_ids == "" do action_ids = json_array_optional(params, "actions")
	if options != "" && action_ids != "" {
		metadata_json = fmt.tprintf("{{\"options\":%s,\"action_ids\":%s}}", options, action_ids)
	} else if options != "" {
		metadata_json = fmt.tprintf("{{\"options\":%s}}", options)
	} else if action_ids != "" {
		metadata_json = fmt.tprintf("{{\"action_ids\":%s}}", action_ids)
	} else if meta_obj := json_object_raw(params, "metadata"); meta_obj != "" {
		metadata_json = meta_obj
	} else if meta_str := json_string(params, "metadata_json"); meta_str != "" {
		metadata_json = meta_str
	}
	msg, saved, err := content_service.send_agent_message(h.content, auth, inst.agent_instance_id, content_service.Message_Input{body = json_string(params, "body"), artifact_ids_json = json_array_optional(params, "artifact_ids"), metadata_json = metadata_json})
	if !saved do return respond_error(err, req.request_id)
	// Notify the human's UI so it can toast + raise an OS notification. This is a
	// metadata event with a SHORT body preview (<=140 chars) — the full body is
	// still fetched durably via REST (fetch_required). System messages
	// (e.g. start-success banners) are not user-actionable, so skip their preview.
	if h.event_bus != nil && msg.message_type != "system" {
		events.publish_owned(h.event_bus, string(inst.owner_user_id), agent_to_user_chat_event_json(inst, msg))
	}
	// Web Push (WP-SEND-2): also deliver an OS notification for backgrounded/
	// closed PWAs. Mirrors the client notify policy (chat only, never system):
	// same choke-point + preview as the WS chat_event above. Non-blocking so it
	// never stalls the response; a no-op when push is unconfigured.
	if h.push != nil && msg.message_type != "system" {
		content := push_service.build_chat_notification(msg.conversation_id, inst.agent_instance_id, msg.message_type, msg.body)
		defer push_service.free_notification_content(content)
		payload := push_service.build_push_payload_json(content, h.public_app_origin)
		defer delete(payload)
		push_service.send_to_user_async(h.push, inst.owner_user_id, payload)
	}
	// Ephemeral activity bubble (skip non-actionable system banners).
	if msg.message_type != "system" do publish_agent_action(h, inst, "chat_send", "sent a message")
	b := strings.builder_make()
	write_message_json(&b, msg, h.content)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

// agent_to_user_chat_event_json builds the user-WS chat_event for a fresh
// agent->user message. Carries a truncated body_preview for the toast/OS
// notification while keeping the full body behind a durable REST fetch.
agent_to_user_chat_event_json :: proc(inst: domain.Agent_Instance, m: domain.Chat_Message) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"chat_event\",\"event\":\"chat_updated\",\"direction\":\"agent_to_user\",\"conversation_id\":\"")
	write_handler_json_string(&b, m.conversation_id)
	strings.write_string(&b, "\",\"agent_instance_id\":\"")
	write_handler_json_string(&b, inst.agent_instance_id)
	strings.write_string(&b, "\",\"message_id\":\"")
	write_handler_json_string(&b, m.message_id)
	strings.write_string(&b, "\",\"message_type\":\"")
	write_handler_json_string(&b, m.message_type)
	strings.write_string(&b, "\",\"body_preview\":\"")
	write_handler_json_string(&b, chat_event_preview(m.body, 140))
	strings.write_string(&b, "\",\"fetch_required\":true,\"fetch_kind\":\"chat_message\",\"fetch_id\":\"")
	write_handler_json_string(&b, m.message_id)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

// chat_event_preview collapses whitespace and truncates to max_len runes,
// appending an ellipsis when clipped. Rune-safe so we never split a UTF-8
// codepoint mid-preview.
chat_event_preview :: proc(body: string, max_len: int) -> string {
	trimmed := strings.trim_space(body)
	if trimmed == "" do return ""
	// Collapse internal whitespace runs to single spaces.
	fields := strings.fields(trimmed)
	defer delete(fields)
	collapsed := strings.join(fields, " ")
	if strings.contains(trimmed, "vault:v1:") {
		return collapsed
	}
	runes := utf8.rune_count_in_string(collapsed)
	if runes <= max_len {
		return collapsed
	}
	defer delete(collapsed)
	// Take the first (max_len-1) runes then add an ellipsis.
	count := 0
	end := len(collapsed)
	for i := 0; i < len(collapsed); {
		if count >= max_len - 1 { end = i; break }
		_, w := utf8.decode_rune_in_string(collapsed[i:])
		i += w
		count += 1
	}
	return strings.concatenate({collapsed[:end], "…"})
}

agent_action_chat_send_to_agent_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	target := json_string(params, "to_instance")
	if target == "" do target = json_string(params, "target_agent_instance_id")
	metadata_json := ""
	options := json_array_optional(params, "options")
	action_ids := json_array_optional(params, "action_ids")
	if action_ids == "" do action_ids = json_array_optional(params, "actions")
	if options != "" && action_ids != "" {
		metadata_json = fmt.tprintf("{{\"options\":%s,\"action_ids\":%s}}", options, action_ids)
	} else if options != "" {
		metadata_json = fmt.tprintf("{{\"options\":%s}}", options)
	} else if action_ids != "" {
		metadata_json = fmt.tprintf("{{\"action_ids\":%s}}", action_ids)
	} else if meta_obj := json_object_raw(params, "metadata"); meta_obj != "" {
		metadata_json = meta_obj
	} else if meta_str := json_string(params, "metadata_json"); meta_str != "" {
		metadata_json = meta_str
	}
	msg, saved, err := content_service.send_agent_to_agent(h.content, auth, target, content_service.Message_Input{body = json_string(params, "body"), artifact_ids_json = json_array_optional(params, "artifact_ids"), metadata_json = metadata_json})
	if !saved do return respond_error(err, req.request_id)
	// Q3: id-free plain phrase (never resolve the target's name in the emit path).
	publish_agent_action(h, inst, "chat_send_agent", "messaged another agent")
	b := strings.builder_make()
	write_message_json(&b, msg, h.content)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

// agent_action_conversation_set_title_handler lets an agent rename ITS OWN bound
// conversation (T3/REQ-3). Marks title_source="agent" so the nudge engine stops.
agent_action_conversation_set_title_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	c, saved, err := content_service.set_own_conversation_title(h.content, auth, inst.agent_instance_id, json_string(params, "title"))
	if !saved do return respond_error(err, req.request_id)
	publish_agent_action(h, inst, "conversation_title", "renamed the conversation")
	events.publish_resource_changed(h.event_bus, string(c.owner_user_id), "conversation", c.conversation_id, "updated", "{}")
	b := strings.builder_make()
	write_chat_json(&b, c)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

// agent_action_chain_set_title_handler lets an agent rename the task chain it
// belongs to (T3/REQ-3). Marks title_source="agent" so the nudge engine stops.
agent_action_chain_set_title_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	chain_id := json_string(params, "chain_id")
	if strings.trim_space(chain_id) == "" do chain_id = inst.chain_id
	if strings.trim_space(chain_id) == "" do return respond_error(domain.domain_error(.Validation_Failed, "chain_id is required"), req.request_id)
	chain, saved, err := taskchain_service.set_own_chain_title(h.taskchains, auth, chain_id, json_string(params, "title"))
	if !saved do return respond_error(err, req.request_id)
	publish_agent_action(h, inst, "chain_title", "renamed the chain")
	publish_chain_event(h.event_bus, string(chain.owner_user_id), string(chain.chain_id), "updated")
	b := strings.builder_make()
	write_chain_json(&b, chain)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

// agent_action_chain_set_description_handler lets a chain's coordinator set/clear
// the chain description. chain_id defaults to the caller instance's chain.
agent_action_chain_set_description_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	chain_id := json_string(params, "chain_id")
	if strings.trim_space(chain_id) == "" do chain_id = inst.chain_id
	if strings.trim_space(chain_id) == "" do return respond_error(domain.domain_error(.Validation_Failed, "chain_id is required"), req.request_id)
	chain, saved, err := taskchain_service.set_own_chain_description(h.taskchains, auth, chain_id, json_string(params, "description"))
	if !saved do return respond_error(err, req.request_id)
	publish_agent_action(h, inst, "chain_desc", "updated chain description")
	b := strings.builder_make()
	write_chain_json(&b, chain)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

// agent_action_chain_set_status_handler lets a chain coordinator mutate status (REQ-CHAIN-1).
agent_action_chain_set_status_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	chain_id := strings.trim_space(json_string(params, "chain_id"))
	if chain_id == "" do chain_id = inst.chain_id
	if chain_id == "" do return respond_error(domain.domain_error(.Validation_Failed, "chain_id is required"), req.request_id)
	status_str := strings.trim_space(json_string(params, "status"))
	if status_str == "" do return respond_error(domain.domain_error(.Validation_Failed, "status is required"), req.request_id)
	if status_str != "active" && status_str != "completed" && status_str != "cancelled" && status_str != "archived" {
		return respond_error(domain.domain_error(.Validation_Failed, "invalid chain status; must be active, completed, cancelled, or archived"), req.request_id)
	}
	status := taskchain_service.chain_status_from_string(status_str)
	chain, saved, err := taskchain_service.change_chain_status(h.taskchains, auth, domain.Task_Chain_ID(chain_id), status)
	if !saved do return respond_error(err, req.request_id)
	publish_agent_action(h, inst, "chain_status", fmt.tprintf("changed chain status to %s", status_str))
	b := strings.builder_make()
	write_chain_json(&b, chain)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

// agent_action_chain_show_handler returns the full chain (incl. description).
// chain_id is optional: defaults to the caller instance's own chain.
agent_action_chain_show_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	chain_id := strings.trim_space(json_string(params, "chain_id"))
	if chain_id == "" do chain_id = inst.chain_id
	if strings.trim_space(chain_id) == "" do return respond_error(domain.domain_error(.Validation_Failed, "no chain for this instance; pass chain_id"), req.request_id)
	// READ (REQ-SEC-3): owner-scoped; an agent may view any same-owner chain,
	// including one it is not a member of (passing an explicit chain_id).
	chain, got, err := taskchain_service.get_chain_for_read(h.taskchains, auth, domain.Task_Chain_ID(chain_id))
	if !got do return respond_error(err, req.request_id)
	publish_agent_action(h, inst, "chain_show", "viewed the chain")
	b := strings.builder_make()
	write_chain_json(&b, chain)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

// POST /api/v1/agent-actions/chain/summary  params: {chain_id?, summary}
agent_action_chain_summary_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	if h.task_engine == nil do return respond_error(domain.domain_error(.Internal_Error, "task engine is not configured"), req.request_id)
	params := verbatim_params(req.body)
	chain_id := strings.trim_space(json_string(params, "chain_id"))
	if chain_id == "" do chain_id = inst.chain_id
	if chain_id == "" do return respond_error(domain.domain_error(.Validation_Failed, "chain_id is required"), req.request_id)
	body_str := json_string(params, "summary")
	if body_str == "" do body_str = json_string(params, "body")
	row, sok, err := taskv2.chain_summary_set(h.task_engine, auth, domain.Task_Chain_ID(chain_id), body_str)
	if !sok do return respond_error(err, req.request_id)
	publish_agent_action(h, inst, "chain_summary", "updated chain summary")
	publish_chain_event(h.event_bus, string(inst.owner_user_id), string(row.chain_id), "updated")
	o := taskv2.json_begin()
	taskv2.json_str(&o, "chain_id", string(row.chain_id))
	taskv2.json_str(&o, "summary", row.body)
	taskv2.json_str(&o, "body", row.body)
	taskv2.json_int(&o, "line_count", i64(row.line_count))
	taskv2.json_int(&o, "version", i64(row.version))
	taskv2.json_str(&o, "updated_at", row.updated_at)
	return respond_success(taskv2.json_end(&o), req.request_id, auth_ctx_server_time(req), 200)
}

// POST /api/v1/agent-actions/chain/propose  params: {chain_id?, tasks?:[...], kind?, rationale?, alternative?, auto_approve?, summary?}
agent_action_chain_propose_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	if h.task_engine == nil do return respond_error(domain.domain_error(.Internal_Error, "task engine is not configured"), req.request_id)
	params := verbatim_params(req.body)
	chain_id := strings.trim_space(json_string(params, "chain_id"))
	if chain_id == "" do chain_id = inst.chain_id
	if chain_id == "" do return respond_error(domain.domain_error(.Validation_Failed, "chain_id is required"), req.request_id)
	tasks_json := verbatim_field(params, "tasks")
	kind := json_string(params, "kind")
	rationale := json_string(params, "rationale")
	if rationale == "" do rationale = json_string(params, "summary")
	alternative := json_string(params, "alternative")
	auto_approve := jsonx.extract_bool(params, "auto_approve", false, true)
	wf_ref := json_string(params, "workflow")
	if wf_ref == "" do wf_ref = json_string(params, "template")
	if wf_ref == "" do wf_ref = json_string(params, "workflow_ref")
	wf_inputs, _ := jsonx.extract_raw_object(params, "inputs", true, context.temp_allocator)
	updated_chain, pok, err := taskv2.chain_propose(h.task_engine, domain.Task_Chain_ID(chain_id), inst.owner_user_id, taskv2.actor_from_auth(auth), taskv2.Propose_Input{
		chain_id             = chain_id,
		tasks_json           = tasks_json,
		kind                 = kind,
		rationale            = rationale,
		alternative          = alternative,
		auto_approve         = auto_approve,
		workflow_ref         = wf_ref,
		workflow_inputs_json = wf_inputs,
	})
	if !pok do return respond_error(err, req.request_id)
	publish_agent_action(h, inst, "chain_propose", "proposed task chain plan")
	publish_chain_event(h.event_bus, string(inst.owner_user_id), chain_id, "updated")
	prop_json := taskv2.chain_proposal_json(updated_chain)
	if prop_json == "" do prop_json = "{}"
	pub_state := "published" if updated_chain.publish_state == .Published else "draft"
	return respond_success(fmt.tprintf("{{\"chain_id\":\"%s\",\"publish_state\":\"%s\",\"proposal\":%s}}", updated_chain.chain_id, pub_state, prop_json), req.request_id, auth_ctx_server_time(req), 200)
}

agent_action_chat_fetch_handler :: proc(ctx: rawptr, req: Request) -> Response {
	return process_agent_chat_fetch_or_read(ctx, req, false)
}

agent_action_chat_read_handler :: proc(ctx: rawptr, req: Request) -> Response {
	return process_agent_chat_fetch_or_read(ctx, req, true)
}

process_agent_chat_fetch_or_read :: proc(ctx: rawptr, req: Request, default_mark_read: bool) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	limit := json_int(params, "limit", 50)
	cursor := json_string(params, "cursor")
	// Optional cross-agent read: a curator (same owner user) may read another
	// agent's conversation by passing target_instance_id. get_conversation_by_instance
	// scopes by auth.user_id, so cross-user access is blocked automatically — no extra
	// ownership check is needed. Absent target_id falls back to the caller's own inbox.
	target_id := json_string(params, "target_instance_id")
	effective_instance_id := target_id != "" ? target_id : inst.agent_instance_id
	conv, conv_ok, conv_err := content_service.get_conversation_by_instance(h.content, auth, effective_instance_id)
	if !conv_ok do return respond_error(conv_err, req.request_id)
	
	unread_only := !strings.contains(params, "\"unread_only\":false") && !strings.contains(params, "\"unread_only\": false")
	receiver_only := !strings.contains(params, "\"receiver_only\":false") && !strings.contains(params, "\"receiver_only\": false")
	include_outgoing := strings.contains(params, "\"include_outgoing\":true") || strings.contains(params, "\"include_outgoing\": true")
	include_debug := strings.contains(params, "\"include_debug\":true") || strings.contains(params, "\"include_debug\": true")
	mark_read := default_mark_read ? (!strings.contains(params, "\"mark_read\":false") && !strings.contains(params, "\"mark_read\": false")) : (strings.contains(params, "\"mark_read\":true") || strings.contains(params, "\"mark_read\": true"))

	filter := content_service.Agent_Inbox_Filter{
		agent_instance_id=effective_instance_id,
		unread_only=unread_only, 
		receiver_only=receiver_only, 
		include_outgoing=include_outgoing, 
		include_debug=include_debug, 
		limit=limit, 
		cursor=cursor,
	}

	rows, err := content_service.list_agent_inbox_messages(h.content, auth, filter)
	if err.code != .None do return respond_error(err, req.request_id)
	
	unread_count_before := 0
	for row in rows { if row.read_at == "" do unread_count_before += 1 }

	marked_count := 0
	through_message_id := ""
	through_created_at := ""
	
	if mark_read && len(rows) > 0 && unread_count_before > 0 {
		ids := make([dynamic]string)
		defer delete(ids)
		for row in rows { if row.read_at == "" do append(&ids, row.message_id) }
		marked_count, _ = content_service.mark_messages_read_by_ids(h.content, auth, ids[:])
		through_message_id = rows[len(rows)-1].message_id
		through_created_at = rows[len(rows)-1].created_at
		// Notify the conversation owner (the human) that their agent read these
		// messages, so the UI can show read receipts on the user's sent bubbles.
		if marked_count > 0 {
			publish_agent_messages_read(h, string(conv.owner_user_id), conv, ids[:], inst.agent_instance_id)
		}
	}

	b := strings.builder_make()
	mode_str := unread_only ? "inbox_unread" : "history"
	
	fmt.sbprintf(&b, "{{\"conversation\":{{\"conversation_id\":\"%s\",\"agent_instance_id\":\"%s\",\"unread_count_before\":%d,\"unread_count_after\":%d}},\"mode\":\"%s\",\"filters\":{{\"receiver_agent_instance_id\":\"%s\",\"unread_only\":%t,\"receiver_only\":%t,\"include_outgoing\":%t,\"include_debug\":%t,\"mark_read\":%t}},\"messages\":[",
		conv.conversation_id, effective_instance_id, unread_count_before, unread_count_before - marked_count, mode_str,
		effective_instance_id, unread_only, receiver_only, include_outgoing, include_debug, mark_read)

	next := ""
	for msg, i in rows { if i > 0 do strings.write_byte(&b, ','); write_message_json(&b, msg, h.content); next = msg.created_at }
	
	fmt.sbprintf(&b, "],\"page\":{{\"limit\":%d,\"next_cursor\":\"%s\",\"has_more\":%t}}", limit, next, len(rows) >= limit)
	
	fmt.sbprintf(&b, ",\"read\":{{\"marked\":%t,\"marked_count\":%d,\"through_message_id\":\"%s\",\"through_created_at\":\"%s\"}}}}",
	    mark_read, marked_count, through_message_id, through_created_at)

	// Human-readable activity bubble: 'read inbox (N new)' vs 'checked messages'.
	if default_mark_read {
		act := target_id != "" ? fmt.tprintf("read inbox of %s (%d new)", target_id, unread_count_before) : fmt.tprintf("read inbox (%d new)", unread_count_before)
		publish_agent_action(h, inst, "chat_read", act)
	} else {
		act := target_id != "" ? fmt.tprintf("checked messages of %s", target_id) : "checked messages"
		publish_agent_action(h, inst, "chat_fetch", act)
	}
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

// Publish a `messages_read` event when an AGENT reads the user's messages, so
// the human's UI can show read receipts. Reuses messages_read_event_json from
// content_handlers (same package). No-op without an event bus (test wiring).
publish_agent_messages_read :: proc(h:^Agent_Action_Handlers, owner_user_id:string, c:domain.Chat_Conversation, message_ids:[]string, reader_instance_id:string){
	if h==nil || h.event_bus==nil || owner_user_id=="" || len(message_ids)==0 do return
	events.publish_owned(h.event_bus, owner_user_id, messages_read_event_json(c, message_ids, reader_instance_id))
}

// publish_current_task_changed emits a live resource_changed event on an agent
// instance's current task pointer so the dashboard updates its work-vs-review
// banner without a manual refresh (CT-9). Fire-and-forget; no-op without a bus.
publish_current_task_changed :: proc(h: ^Agent_Action_Handlers, owner_user_id, agent_instance_id, current_task_id, current_task_role: string) {
	if h == nil || h.event_bus == nil || owner_user_id == "" do return
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, `{"agent_instance_id":"`); write_handler_json_string(&b, agent_instance_id)
	strings.write_string(&b, `","current_task_id":"`); write_handler_json_string(&b, current_task_id)
	strings.write_string(&b, `","current_task_role":"`); write_handler_json_string(&b, current_task_role)
	strings.write_string(&b, `"}`)
	events.publish_resource_changed(h.event_bus, owner_user_id, "agent_instance", agent_instance_id, "current_task_changed", strings.to_string(b))
}

// publish_agent_action emits a lean, ephemeral "agent_action" event to the acting
// instance's OWNER connection so the dashboard can show a transient activity
// bubble of what the agent is doing right now. Best-effort and non-blocking:
// a no-op without an event bus (test wiring) or an owner. The caller composes a
// short, human-readable, id-FREE summary; agent_action_event_json clips it
// (rune-safe) and frames it. Never affects the HTTP response.
publish_agent_action :: proc(h: ^Agent_Action_Handlers, inst: domain.Agent_Instance, action, summary: string) {
	if h == nil || h.event_bus == nil do return
	owner := string(inst.owner_user_id)
	if owner == "" || inst.agent_instance_id == "" do return
	event := agent_action_event_json(inst.agent_instance_id, action, summary)
	defer delete(event)
	events.publish_raw_to_user(h.event_bus, owner, event)
}

// Max runes for an activity-bubble summary (matches the client's ~40-60 char cap).
AGENT_ACTION_SUMMARY_MAX :: 60

// agent_action_event_json builds the ephemeral {"type":"agent_action",...} frame.
// Split out from publish_agent_action so a unit test can assert the payload shape
// and id-free summary without a live event bus. summary is clipped rune-safe to
// AGENT_ACTION_SUMMARY_MAX runes (reusing chat_event_preview) so a long preview
// can't bloat the frame. ts is hub unix-ms (the client uses it for the replay window).
agent_action_event_json :: proc(agent_instance_id, action, summary: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"type":"agent_action","instance_id":"`)
	write_handler_json_string(&b, agent_instance_id)
	strings.write_string(&b, `","action":"`)
	write_handler_json_string(&b, action)
	strings.write_string(&b, `","summary":"`)
	clipped := chat_event_preview(summary, AGENT_ACTION_SUMMARY_MAX)
	defer delete(clipped)
	write_handler_json_string(&b, clipped)
	strings.write_string(&b, `","ts":`)
	strings.write_string(&b, fmt.tprintf("%d", time.to_unix_nanoseconds(time.now()) / 1_000_000))
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

agent_action_agents_live_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	instances, err := agent_service.list_instances_filtered(h.agents, auth, agent_service.List_Instances_Filter{runtime_status = "live"})
	if err.code != .None do return respond_error(err, req.request_id)
	publish_agent_action(h, inst, "agents_live", "listed live agents")
	b := strings.builder_make()
	strings.write_byte(&b, '[')
	for inst, i in instances { if i > 0 do strings.write_byte(&b, ','); write_agent_instance_json(&b, inst) }
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

agent_action_context_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	conv, conv_ok, _ := content_service.get_conversation_by_instance(h.content, auth, inst.agent_instance_id)
	b := strings.builder_make()
	strings.write_string(&b, "{\"agent_instance_id\":\""); write_handler_json_string(&b, inst.agent_instance_id)
	strings.write_string(&b, "\",\"agent_id\":\""); write_handler_json_string(&b, inst.agent_id)
	strings.write_string(&b, "\",\"bridge_id\":\""); write_handler_json_string(&b, inst.bridge_id)
	strings.write_string(&b, "\",\"chain_id\":\""); write_handler_json_string(&b, inst.chain_id)
	strings.write_string(&b, "\",\"conversation_id\":\""); if conv_ok { write_handler_json_string(&b, conv.conversation_id) } else { write_handler_json_string(&b, inst.conversation_id) }
	strings.write_string(&b, "\",\"project_id\":\""); write_handler_json_string(&b, string(inst.project_id))
	strings.write_string(&b, "\",\"runtime\":{\"provider\":\""); write_handler_json_string(&b, inst.provider)
	strings.write_string(&b, "\",\"model\":\""); write_handler_json_string(&b, inst.model)
	strings.write_string(&b, "\",\"runtime_status\":\""); write_handler_json_string(&b, inst.runtime_status)
	strings.write_string(&b, "\",\"startup_status\":\""); write_handler_json_string(&b, inst.startup_status)
	strings.write_string(&b, "\"},\"unread_summary\":{\"conversation_unread_count\":")
	if conv_ok { strings.write_string(&b, fmt.tprintf("%d", conv.unread_count)) } else { strings.write_string(&b, "0") }
	strings.write_string(&b, "},\"current_task\":")
	write_agent_current_task_json(&b, h, auth, inst)
	strings.write_string(&b, ",\"next_cursor\":\""); write_handler_json_string(&b, auth_ctx_server_time(req)); strings.write_string(&b, "\"")
	strings.write_byte(&b, '}')
	publish_agent_action(h, inst, "context", "refreshed context")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

// agent_action_task_show_handler returns slim task detail by task_id ALONE — the
// chain is derived server-side from the task (get_task resolves + authorizes).
// No client chain_id is required (task ids are globally unique). Reuses the
// shared write_task_detail_json via a lightweight Taskchain_Handlers view.
agent_action_task_show_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	task_id := domain.Task_ID(json_string(params, "task_id"))
	if strings.trim_space(string(task_id)) == "" do return respond_error(domain.domain_error(.Validation_Failed, "task_id is required"), req.request_id)
	// READ (REQ-SEC-3): owner-scoped; an agent may open any same-owner task,
	// including one in a chain it is not a member of.
	task, got, err := taskchain_service.get_task_for_read(h.taskchains, auth, task_id)
	if !got do return respond_error(err, req.request_id)
	deps, _ := taskchain_service.list_chain_dependencies(h.taskchains, auth, task.chain_id)
	publish_agent_action(h, inst, "task_show", "opened a task")
	tch := Taskchain_Handlers{auth = h.auth, taskchains = h.taskchains, agents = h.agents, event_bus = h.event_bus}
	b := strings.builder_make()
	write_task_detail_json(&b, &tch, auth, task, deps)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

// agent_action_task_comments_handler returns the newest N comments for a task by
// task_id alone (chain derived server-side). ?last is passed as a param.
agent_action_task_comments_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	task_id := domain.Task_ID(json_string(params, "task_id"))
	if strings.trim_space(string(task_id)) == "" do return respond_error(domain.domain_error(.Validation_Failed, "task_id is required"), req.request_id)
	publish_agent_action(h, inst, "task_comments", "read task comments")
	last := 0
	if v := strings.trim_space(json_string(params, "last")); v != "" { if n, parsed := strconv.parse_int(v); parsed { last = n } }
	if last > TASK_COMMENTS_LAST_MAX do last = TASK_COMMENTS_LAST_MAX
	comments, cerr := taskchain_service.list_recent_task_comments(h.taskchains, auth, task_id, last)
	if cerr.code != .None do return respond_error(cerr, req.request_id)
	// MEM-7: resolve author display name via the same agent repo the member view uses.
	tch := Taskchain_Handlers{auth = h.auth, taskchains = h.taskchains, agents = h.agents, event_bus = h.event_bus}
	b := strings.builder_make(); strings.write_byte(&b, '[')
	for c, i in comments { if i > 0 do strings.write_byte(&b, ','); write_task_comment_json(&b, c, resolve_comment_author_display(&tch, auth, c)) }
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

// agent_action_task_list_handler lists tasks for a chain. chain_id is optional:
// when omitted it defaults to the caller instance's own chain, so agents never
// need to know/pass a chain id.
agent_action_task_list_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	chain_id := strings.trim_space(json_string(params, "chain_id"))
	if chain_id == "" do chain_id = inst.chain_id
	if strings.trim_space(chain_id) == "" do return respond_error(domain.domain_error(.Validation_Failed, "no chain for this instance; pass chain_id"), req.request_id)
	tasks, err := taskchain_service.list_tasks(h.taskchains, auth, domain.Task_Chain_ID(chain_id))
	if err.code != .None do return respond_error(err, req.request_id)
	deps, _ := taskchain_service.list_chain_dependencies(h.taskchains, auth, domain.Task_Chain_ID(chain_id))
	publish_agent_action(h, inst, "task_list", "viewed tasks")
	tch := Taskchain_Handlers{auth = h.auth, taskchains = h.taskchains, agents = h.agents, event_bus = h.event_bus}
	b := strings.builder_make(); strings.write_byte(&b, '[')
	for task, i in tasks { if i > 0 do strings.write_byte(&b, ','); write_task_detail_json(&b, &tch, auth, task, deps, false) }
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

agent_action_task_comment_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	notify := json_array_of_strings_raw(params, "notify")
	comment, notified, saved, err := taskchain_service.comment_task(h.taskchains, auth, taskchain_service.Task_Comment_Input{task_id = domain.Task_ID(json_string(params, "task_id")), body = json_string(params, "body"), notify = notify})
	if !saved do return respond_error(err, req.request_id)
	publish_agent_action(h, inst, "task_comment", fmt.tprintf("commented: %s", json_string(params, "body")))
	publish_task_event(h.event_bus, string(comment.owner_user_id), string(comment.task_id), string(comment.chain_id), "commented")
	tch := Taskchain_Handlers{auth = h.auth, taskchains = h.taskchains, agents = h.agents, event_bus = h.event_bus}
	b := strings.builder_make()
	write_task_comment_response_json(&b, comment, resolve_comment_author_display(&tch, auth, comment), notified)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

agent_action_task_create_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	chain_id := json_string(params, "chain_id")
	if chain_id == "" do chain_id = inst.chain_id
	if chain, chain_ok, _ := taskchain_service.get_chain(h.taskchains, auth, domain.Task_Chain_ID(chain_id)); chain_ok {
		if chain.coordinator_agent_instance_id != "" && chain.coordinator_agent_instance_id != inst.agent_instance_id {
			return respond_error(domain.domain_error(.Forbidden, "only chain coordinator can create tasks"), req.request_id)
		}
	}
	// Agent mode reaches create through THIS handler, not the user-mode POST, so the
	// priority parse has to exist in both places (REQ-CLI-2).
	priority, has_priority, prio_ok, prio_err := create_priority_from_body(params)
	if !prio_ok do return respond_error(prio_err, req.request_id)
	// REQ-CLI-10: --depends-on was sent by the ctl (agent_mode.odin:330) and dropped
	// here, so agent-created tasks silently got an EMPTY dependency list and this
	// chain's dep graph never existed. Same helper and same field as the user-mode
	// create (taskchain_handlers.odin:637) so the two cannot diverge. An unknown or
	// malformed id is REJECTED, not dropped: create_task runs each one through
	// add_task_dependency, which fails the whole call.
	deps := json_array_of_strings(params, "depends_on")
	// Same shared parse as the cookie create (REQ-TB-2): optional bridge_id, absent
	// means inherit. The service applies the identical owner-bridge validation, so an
	// agent gains no privilege by setting it.
	bridge_id, _ := task_bridge_id_from_body(params)
	has_requires_user_approval := json_key_present(params, "requires_user_approval")
	requires_user_approval, valid_requires_user_approval := json_bool_literal(params, "requires_user_approval")
	if has_requires_user_approval && !valid_requires_user_approval do return respond_error(domain.domain_error(.Validation_Failed, "requires_user_approval must be a boolean"), req.request_id)
	assignee, reviewers, review_roles, has_roles, actor_err := task_actor_fields_from_body(params)
	if actor_err.code != .None do return respond_error(actor_err, req.request_id)
	brief_json, _ := jsonx.extract_raw_object(params, "brief", top_level_only = true, allocator = context.temp_allocator)
	task, created, err := taskchain_service.create_task(h.taskchains, auth, taskchain_service.Create_Task_Input{
		chain_id = domain.Task_Chain_ID(chain_id),
		title = json_string(params, "title"),
		description = json_string(params, "description"),
		brief_json = brief_json,
		assignee_agent_id = assignee,
		reviewer_agent_ids = reviewers,
		review_roles = review_roles if has_roles else nil,
		requires_user_approval = requires_user_approval,
		has_requires_user_approval = has_requires_user_approval,
		priority = priority,
		has_priority = has_priority,
		depends_on = deps,
		bridge_id = bridge_id,
	})
	if !created do return respond_error(err, req.request_id)
	publish_agent_action(h, inst, "task_create", fmt.tprintf("created task \"%s\"", task.title))
	publish_task_event(h.event_bus, string(task.owner_user_id), string(task.task_id), string(task.chain_id), "created")
	publish_chain_event(h.event_bus, string(task.owner_user_id), string(task.chain_id), "updated")
	b := strings.builder_make()
	write_task_json(&b, task)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

// agent_action_task_update_handler edits an already-created task: title,
// description, priority, assignee, reviewers, and dependencies. Mirrors the
// user-mode PATCH (update_task) but authed by instance token and gated to the
// chain coordinator (same authority model as create/depend). Only the fields
// present in params are changed; reviewer_refs/depends_on REPLACE the whole list
// when present (has_* flags distinguish "absent" from "cleared").
agent_action_task_update_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	task_id := domain.Task_ID(json_string(params, "task_id"))
	if strings.trim_space(string(task_id)) == "" do return respond_error(domain.domain_error(.Validation_Failed, "task_id is required"), req.request_id)
	// Coordinator-only, matching create/depend: resolve the task's chain and check
	// the caller is its coordinator (when one is set).
	if task, task_ok, _ := taskchain_service.get_task(h.taskchains, auth, task_id); task_ok {
		if chain, chain_ok, _ := taskchain_service.get_chain(h.taskchains, auth, task.chain_id); chain_ok {
			if chain.coordinator_agent_instance_id != "" && chain.coordinator_agent_instance_id != inst.agent_instance_id {
				return respond_error(domain.domain_error(.Forbidden, "only chain coordinator can update tasks"), req.request_id)
			}
		}
	}
	has_deps := strings.contains(params, "\"depends_on\"")
	deps := json_array_of_strings(params, "depends_on")
	has_priority := strings.contains(params, "\"priority\"")
	priority := domain.task_priority_from_string(json_string(params, "priority"))
	// Presence-checked exactly like the cookie PATCH: absent leaves the pin, "" clears
	// it back to inherit, a value repins.
	bridge_id, has_bridge := task_bridge_id_from_body(params)
	bridge_pin: ^string
	if has_bridge do bridge_pin = &bridge_id
	has_requires_user_approval := json_key_present(params, "requires_user_approval")
	requires_user_approval, valid_requires_user_approval := json_bool_literal(params, "requires_user_approval")
	if has_requires_user_approval && !valid_requires_user_approval do return respond_error(domain.domain_error(.Validation_Failed, "requires_user_approval must be a boolean"), req.request_id)
	assignee, reviewers, review_roles, has_roles, actor_err := task_actor_fields_from_body(params)
	if actor_err.code != .None do return respond_error(actor_err, req.request_id)
	brief_json, _ := jsonx.extract_raw_object(params, "brief", top_level_only = true, allocator = context.temp_allocator)
	task, updated, err := taskchain_service.update_task(h.taskchains, auth, task_id, taskchain_service.Update_Task_Input{
		title = json_string(params, "title"),
		description = json_string(params, "description"),
		brief_json = brief_json,
		assignee_agent_id = assignee,
		has_assignee = json_key_present(params, "assignee") || json_key_present(params, "assignee_ref"),
		review_roles = review_roles,
		has_review_roles = has_roles,
		reviewer_agent_ids = reviewers,
		requires_user_approval = requires_user_approval,
		has_requires_user_approval = has_requires_user_approval,
		priority = priority,
		has_priority = has_priority,
		depends_on = deps,
		has_depends_on = has_deps,
		bridge_id = bridge_pin,
	})
	if !updated do return respond_error(err, req.request_id)
	publish_agent_action(h, inst, "task_update", "updated a task")
	publish_task_event(h.event_bus, string(task.owner_user_id), string(task.task_id), string(task.chain_id), "updated")
	publish_chain_event(h.event_bus, string(task.owner_user_id), string(task.chain_id), "updated")
	b := strings.builder_make()
	write_task_json(&b, task)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

agent_action_task_depend_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	task_id := domain.Task_ID(json_string(params, "task_id"))
	depends_on_task_id := domain.Task_ID(json_string(params, "depends_on_task_id"))
	if depends_on_task_id == "" do depends_on_task_id = domain.Task_ID(json_string(params, "on"))
	if task, task_ok, _ := taskchain_service.get_task(h.taskchains, auth, task_id); task_ok {
		if chain, chain_ok, _ := taskchain_service.get_chain(h.taskchains, auth, task.chain_id); chain_ok {
			if chain.coordinator_agent_instance_id != "" && chain.coordinator_agent_instance_id != inst.agent_instance_id {
				return respond_error(domain.domain_error(.Forbidden, "only chain coordinator can add task dependencies"), req.request_id)
			}
		}
	}
	dep, added, err := taskchain_service.add_task_dependency(h.taskchains, auth, task_id, depends_on_task_id)
	if !added do return respond_error(err, req.request_id)
	publish_agent_action(h, inst, "task_depend", "linked a task dependency")
	publish_task_event(h.event_bus, string(inst.owner_user_id), string(dep.task_id), string(inst.chain_id), "updated")
	publish_chain_event(h.event_bus, string(inst.owner_user_id), string(inst.chain_id), "updated")
	b := strings.builder_make()
	strings.write_string(&b, "{\"task_id\":\""); write_handler_json_string(&b, string(dep.task_id)); strings.write_string(&b, "\",\"depends_on_task_id\":\""); write_handler_json_string(&b, string(dep.depends_on_task_id)); strings.write_string(&b, "\"}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}


agent_action_artifact_create_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	content := json_string(params, "content")
	b64 := json_string(params, "content_base64")
	if b64 == "" do b64 = json_string(params, "inline_bytes")
	if b64 != "" {
		dec, _ := internal_b64.decode(b64, allocator = context.temp_allocator)
		if len(dec) > 0 do content = string(dec)
	}
	artifact, saved, err := content_service.create_artifact(h.content, auth, content_service.Artifact_Input{kind = json_string(params, "kind"), name = json_string(params, "name"), description = json_string(params, "description"), content_type = json_string(params, "content_type"), content = content, filename = json_string(params, "filename"), agent_id = inst.agent_id, agent_instance_id = inst.agent_instance_id, chain_id = inst.chain_id, project_id = inst.project_id})
	if !saved do return respond_error(err, req.request_id)
	publish_agent_action(h, inst, "artifact_create", fmt.tprintf("created artifact \"%s\"", artifact.name))
	b := strings.builder_make()
	write_artifact_json(&b, artifact, false)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

agent_action_artifact_list_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp

	params := json_object_raw(req.body, "params")
	if params == "" do params = req.body

	project_id := json_string(params, "project_id")
	agent_instance_id := json_string(params, "agent_instance_id")
	agent_id := json_string(params, "agent_id")
	chain_id := json_string(params, "chain_id")
	task_id := json_string(params, "task_id")
	kind := json_string(params, "kind")
	since := json_string(params, "since")
	until := json_string(params, "until")
	include_deleted := json_bool(params, "include_deleted")
	sort := json_string(params, "sort")
	if sort == "" do sort = json_string(params, "sort_field")
	order := json_string(params, "order")
	if order == "" do order = json_string(params, "sort_order")
	limit := json_int(params, "limit", 50)
	cursor := json_string(params, "cursor")

	filter := domain.Artifact_List_Filter{
		project_id        = domain.Project_ID(project_id),
		agent_instance_id = agent_instance_id,
		agent_id          = agent_id,
		chain_id          = chain_id,
		task_id           = task_id,
		kind              = kind,
		since             = since,
		until             = until,
		include_deleted   = include_deleted,
		sort_field        = sort,
		sort_order        = order,
		limit             = limit,
		cursor            = cursor,
	}

	rows, err := content_service.list_artifacts(h.content, auth, filter)
	if err.code != .None do return respond_error(err, req.request_id)
	defer domain.artifacts_destroy(rows)

	publish_agent_action(h, inst, "artifact_list", "listed artifacts")

	eff_limit := limit
	if eff_limit <= 0 do eff_limit = 50
	if eff_limit > 200 do eff_limit = 200

	has_more := len(rows) > eff_limit
	page_count := len(rows)
	if page_count > eff_limit do page_count = eff_limit

	b := strings.builder_make()
	strings.write_byte(&b, '[')
	for i in 0..<page_count {
		if i > 0 do strings.write_byte(&b, ',')
		write_artifact_json(&b, rows[i], false)
	}
	strings.write_byte(&b, ']')

	next_cursor := ""
	if has_more && page_count > 0 {
		next_cursor = artifact_page_cursor(rows[page_count - 1], filter.sort_field)
	}

	return respond_list(strings.to_string(b), contracts.API_Page{limit = eff_limit, next_cursor = next_cursor, has_more = has_more}, req.request_id, auth_ctx_server_time(req))
}

agent_action_artifact_show_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	artifact_id := json_string(params, "artifact_id")
	if artifact_id == "" do artifact_id = json_string(params, "artifact")
	if artifact_id == "" do return respond_error(domain.domain_error(.Validation_Failed, "artifact_id is required"), req.request_id)
	artifact, got, err := content_service.get_artifact(h.content, auth, artifact_id)
	if !got do return respond_error(err, req.request_id)
	publish_agent_action(h, inst, "artifact_show", "opened an artifact")
	with_content := strings.contains(params, "\"with_content\":true")
	b := strings.builder_make()
	write_artifact_json(&b, artifact, with_content)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

agent_action_artifact_content_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	artifact_id := json_string(params, "artifact_id")
	if artifact_id == "" do artifact_id = json_string(params, "artifact")
	if artifact_id == "" do return respond_error(domain.domain_error(.Validation_Failed, "artifact_id is required"), req.request_id)
	artifact, got, err := content_service.get_artifact(h.content, auth, artifact_id)
	if !got do return respond_error(err, req.request_id)
	publish_agent_action(h, inst, "artifact_content", "read an artifact")
	b := strings.builder_make()
	strings.write_string(&b, "{\"artifact_id\":\""); write_handler_json_string(&b, artifact.artifact_id)
	strings.write_string(&b, "\",\"name\":\""); write_handler_json_string(&b, artifact.name)
	strings.write_string(&b, "\",\"content_type\":\""); write_handler_json_string(&b, artifact.content_type)
	strings.write_string(&b, "\",\"mime\":\""); write_handler_json_string(&b, artifact.mime)
	strings.write_string(&b, "\",\"size_bytes\":"); strings.write_string(&b, fmt.tprintf("%d", artifact.size_bytes))
	strings.write_string(&b, ",\"content\":\""); write_handler_json_string(&b, artifact.content)
	strings.write_string(&b, "\"}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

// agent_action_search_handler is the agent.search RPC (SEARCH-7): the same global
// search as the REST GET /api/v1/search, over an instance token. Owner scoping is
// derived from the instance auth (ownership.owner_from_auth in the service), so an
// agent can only ever search its owner's data. Uses the typed SEARCH-8 contract
// (scopes + task/chain/project/conversation ids + negations + exclude) and returns
// the identical grouped hit shape as REST.
agent_action_search_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	input := search_service.Search_Input{
		q = json_string(params, "query"),
		types_csv = agent_action_csv_field(params, "scopes"),
		limit = json_int(params, "limit", 0),
		cursor = json_string(params, "cursor"),
		task_ids = agent_action_csv_field(params, "task_ids"),
		chain_ids = agent_action_csv_field(params, "chain_ids"),
		project_ids = agent_action_csv_field(params, "project_ids"),
		conversation_ids = agent_action_csv_field(params, "conversation_ids"),
		not_in_task_ids = agent_action_csv_field(params, "not_in_task_ids"),
		not_in_chain_ids = agent_action_csv_field(params, "not_in_chain_ids"),
		not_in_project_ids = agent_action_csv_field(params, "not_in_project_ids"),
		not_in_conversation_ids = agent_action_csv_field(params, "not_in_conversation_ids"),
		exclude = json_string(params, "exclude"),
	}
	result, searched, err := search_service.search_resources(h.search, auth, input)
	if !searched do return respond_error(err, req.request_id)
	publish_agent_action(h, inst, "search", "searched")
	page_limit := input.limit
	if page_limit <= 0 do page_limit = search_service.DEFAULT_SEARCH_LIMIT
	if page_limit > search_service.MAX_SEARCH_LIMIT do page_limit = search_service.MAX_SEARCH_LIMIT
	data_json := search_groups_json(result.hits)
	return respond_search(data_json, contracts.API_Page{limit = page_limit, next_cursor = result.next_cursor, has_more = result.has_more}, req.request_id, auth_ctx_server_time(req))
}

// agent_action_csv_field reads a params field as either a JSON string array
// (joined to CSV) or a plain CSV string, so agents can send arrays naturally
// while the service consumes the same CSV shape as the REST query params.
agent_action_csv_field :: proc(params, key: string) -> string {
	arr := json_string_array(params, key)
	if len(arr) > 0 do return strings.join(arr, ",")
	return json_string(params, key)
}

agent_action_memory_propose_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	// Targeting is read as JSON string arrays agent_ids/project_ids/template_ids/
	// bridge_ids (empty/omitted = applies to all). When the proposer supplies no
	// agent targeting at all, default to its own durable agent so self-proposed
	// memories stay scoped to that agent (matching the prior scalar behavior).
	agent_ids := json_string_array(params, "agent_ids")
	if len(agent_ids) == 0 do agent_ids = []string{inst.agent_id}
	project_ids := json_project_id_array(params, "project_ids")
	template_ids := json_string_array(params, "template_ids")
	bridge_ids := json_string_array(params, "bridge_ids")
	mem, saved, err := content_service.create_memory(h.content, auth, content_service.Memory_Input{agent_ids = agent_ids, project_ids = project_ids, template_ids = template_ids, bridge_ids = bridge_ids, type = domain.memory_type_from_string(json_string(params, "type")), title = json_string(params, "title"), description = json_string(params, "description"), body = json_string(params, "body"), evidence = json_string(params, "evidence"), status = "pending", expires_at = json_string(params, "expires_at")})
	if !saved do return respond_error(err, req.request_id)
	publish_agent_action(h, inst, "memory_propose", fmt.tprintf("proposed memory \"%s\"", mem.title))
	b := strings.builder_make()
	write_memory_json(&b, mem, false)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

write_memory_metadata_json :: proc(b: ^strings.Builder, m: domain.Memory) {
	typ := domain.memory_type_string(m.type)
	strings.write_string(b, "{\"memory_id\":\"")
	write_handler_json_string(b, m.memory_id)
	strings.write_string(b, "\",\"type\":\"")
	write_handler_json_string(b, typ)
	strings.write_string(b, "\",\"status\":\"")
	write_handler_json_string(b, m.status)
	strings.write_string(b, "\",\"title\":\"")
	write_handler_json_string(b, m.title)
	strings.write_string(b, "\",\"description\":\"")
	write_handler_json_string(b, m.description)
	strings.write_string(b, "\",\"agent_ids\":")
	write_memory_id_array(b, m.agent_ids)
	strings.write_string(b, ",\"project_ids\":")
	write_memory_project_array(b, m.project_ids)
	strings.write_string(b, ",\"template_ids\":")
	write_memory_id_array(b, m.template_ids)
	strings.write_string(b, ",\"bridge_ids\":")
	write_memory_id_array(b, m.bridge_ids)
	strings.write_string(b, ",\"expires_at\":\"")
	write_handler_json_string(b, m.expires_at)
	strings.write_string(b, "\",\"created_at\":\"")
	write_handler_json_string(b, m.created_at)
	strings.write_string(b, "\",\"updated_at\":\"")
	write_handler_json_string(b, m.updated_at)
	strings.write_string(b, "\"}")
}

agent_action_memory_filter_value :: proc(params, plural_key, singular_key: string) -> string {
	arr := json_string_array(params, plural_key)
	defer delete(arr)
	for item in arr {
		trimmed := strings.trim_space(item)
		if trimmed != "" do return trimmed
	}
	raw := json_string(params, plural_key)
	if raw == "" do raw = json_string(params, singular_key)
	raw = strings.trim_space(raw)
	if comma := strings.index_byte(raw, ','); comma >= 0 do return strings.trim_space(raw[:comma])
	return raw
}

agent_action_memory_list_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	limit := json_int(params, "limit", 50)
	if limit <= 0 do limit = 50
	if limit > 200 do limit = 200
	status := json_string(params, "status")
	type_str := json_string(params, "type")
	agent_id := agent_action_memory_filter_value(params, "agent_ids", "agent_id")
	project_id := agent_action_memory_filter_value(params, "project_ids", "project_id")
	bridge_id := agent_action_memory_filter_value(params, "bridge_ids", "bridge_id")
	template_id := agent_action_memory_filter_value(params, "template_ids", "template_id")
	filter := content_service.Memory_Filter{
		status      = status,
		type        = type_str,
		agent_id    = agent_id,
		project_id  = domain.Project_ID(project_id),
		bridge_id   = bridge_id,
		template_id = template_id,
	}
	rows, err := content_service.list_memories(h.content, auth, filter, limit)
	if err.code != .None do return respond_error(err, req.request_id)
	defer delete(rows)
	publish_agent_action(h, inst, "memory_list", "listed memories")
	b := strings.builder_make()
	strings.write_byte(&b, '[')
	for mem, i in rows {
		if i > 0 do strings.write_byte(&b, ',')
		write_memory_metadata_json(&b, mem)
	}
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = limit, has_more = len(rows) >= limit}, req.request_id, auth_ctx_server_time(req))
}

agent_action_memory_show_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	memory_id := json_string(params, "memory_id")
	if memory_id == "" do memory_id = json_string(params, "memory")
	if memory_id == "" do memory_id = json_string(params, "id")
	if memory_id == "" do return respond_error(domain.domain_error(.Validation_Failed, "memory_id is required"), req.request_id)
	mem, got, err := content_service.get_memory(h.content, auth, memory_id)
	if !got do return respond_error(err, req.request_id)
	publish_agent_action(h, inst, "memory_show", fmt.tprintf("opened memory \"%s\"", mem.title))
	b := strings.builder_make()
	write_memory_json(&b, mem, false)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

agent_action_memory_content_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := json_object_raw(req.body, "params")
	memory_id := json_string(params, "memory_id")
	if memory_id == "" do memory_id = json_string(params, "memory")
	if memory_id == "" do memory_id = json_string(params, "id")
	if memory_id == "" do return respond_error(domain.domain_error(.Validation_Failed, "memory_id is required"), req.request_id)
	mem, got, err := content_service.get_memory(h.content, auth, memory_id)
	if !got do return respond_error(err, req.request_id)
	publish_agent_action(h, inst, "memory_content", fmt.tprintf("read memory \"%s\"", mem.title))
	b := strings.builder_make()
	strings.write_string(&b, "{\"memory_id\":\""); write_handler_json_string(&b, mem.memory_id)
	strings.write_string(&b, "\",\"content\":\""); write_handler_json_string(&b, mem.body)
	strings.write_string(&b, "\"}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

agent_action_start_success_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, _, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	inst, saved, err := agent_service.mark_instance_start_success(h.agents, auth)
	if !saved do return respond_error(err, req.request_id)
	if inst.kind == "provider_test" {
		if h.providers != nil do provider_service.provider_test_mark_instance_ready(h.providers, inst.agent_instance_id)
		b := strings.builder_make(); strings.write_string(&b, "{\"instance\":"); write_agent_instance_json(&b, inst); strings.write_byte(&b, '}')
		return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
	}
	startup_note, note_saved, _ := content_service.send_agent_message(h.content, auth, inst.agent_instance_id, content_service.Message_Input{body = "Agent has started and is ready.", artifact_ids_json = "[]", message_type = "system"})
	conv, conv_ok, _ := content_service.get_conversation_by_instance(h.content, auth, inst.agent_instance_id)
	if conv_ok {
		// Only re-notify for genuinely unread inbound messages. Scanning all recent
		// messages and notifying for the first user_to_agent row (regardless of read
		// state) produced false "New message from user" notifications on every
		// start-success, even when the inbox was empty/already read.
		inbox_filter := content_service.Agent_Inbox_Filter{
			agent_instance_id = inst.agent_instance_id,
			unread_only       = true,
			receiver_only     = true,
			include_outgoing  = false,
			include_debug     = false,
			limit             = 50,
		}
		unread, unread_err := content_service.list_agent_inbox_messages(h.content, auth, inbox_filter)
		if unread_err.code == .None {
			for msg in unread {
				if msg.direction == "user_to_agent" && msg.read_at == "" {
					content_service.notify_agent_message(h.content, conv, "user_to_agent", "user", msg.message_id)
					break
				}
			}
		}
	}
	b := strings.builder_make()
	strings.write_string(&b, "{\"instance\":")
	write_agent_instance_json(&b, inst)
	strings.write_string(&b, ",\"startup_message\":")
	if note_saved { write_message_json(&b, startup_note, h.content) } else { strings.write_string(&b, "null") }
	strings.write_byte(&b, '}')
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

agent_action_card_create_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp

	params := json_object_raw(req.body, "params")

	project_id := domain.Project_ID(json_string(params, "project_id"))
	if project_id == "" do project_id = domain.Project_ID(inst.project_id)

	provider := json_string(params, "provider")
	if provider == "" do provider = domain.CARD_PROVIDER_CURATOR_LLM

	raw_refs, _ := json_raw_field(params, "source_refs")
	raw_ops, _ := json_raw_field(params, "operations")
	raw_guard, _ := json_raw_field(params, "guard")

	input := card_service.Card_Input{
		project_id       = project_id,
		title            = json_string(params, "title"),
		rationale        = json_string(params, "rationale"),
		scope            = json_string(params, "scope"),
		provider         = provider,
		confidence       = json_f32(params, "confidence", 1.0),
		source_refs_json = raw_refs,
		status           = json_string(params, "status"),
		operations_json  = raw_ops,
		guard_json       = raw_guard,
		snooze_until     = json_string(params, "snooze_until"),
		ttl_at           = json_string(params, "ttl_at"),
	}

	card, saved, err := card_service.create_card(h.cards, auth, input)
	if !saved do return respond_error(err, req.request_id)

	publish_agent_action(h, inst, "card_create", fmt.tprintf("created card \"%s\"", card.title))

	b := strings.builder_make()
	write_card_json(&b, card)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

agent_action_card_list_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp

	params := json_object_raw(req.body, "params")
	limit := json_int(params, "limit", 50)
	if limit <= 0 do limit = 50
	if limit > 200 do limit = 200

	project_id := json_string(params, "project_id")
	filter := card_service.Card_Filter{
		status     = json_string(params, "status"),
		scope      = json_string(params, "scope"),
		provider   = json_string(params, "provider"),
		project_id = domain.Project_ID(project_id),
	}

	cards, err := card_service.list_cards(h.cards, auth, filter, limit)
	if err.code != .None do return respond_error(err, req.request_id)
	defer delete(cards)

	publish_agent_action(h, inst, "card_list", "listed cards")

	b := strings.builder_make()
	strings.write_byte(&b, '[')
	for c, i in cards {
		if i > 0 do strings.write_byte(&b, ',')
		write_card_json(&b, c)
	}
	strings.write_byte(&b, ']')

	return respond_list(strings.to_string(b), contracts.API_Page{limit = limit, has_more = len(cards) >= limit}, req.request_id, auth_ctx_server_time(req))
}

agent_action_card_show_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp

	params := json_object_raw(req.body, "params")
	card_id := json_string(params, "card_id")
	if card_id == "" do card_id = json_string(params, "action_id")
	if card_id == "" do card_id = json_string(params, "card")
	if card_id == "" do card_id = json_string(params, "id")
	if card_id == "" do return respond_error(domain.domain_error(.Validation_Failed, "card_id is required"), req.request_id)

	card, got, err := card_service.get_card(h.cards, auth, domain.Card_ID(card_id))
	if !got do return respond_error(err, req.request_id)

	publish_agent_action(h, inst, "card_show", fmt.tprintf("opened card \"%s\"", card.title))

	b := strings.builder_make()
	write_card_json(&b, card)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

agent_action_card_discard_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp

	params := json_object_raw(req.body, "params")
	card_id := json_string(params, "card_id")
	if card_id == "" do card_id = json_string(params, "action_id")
	if card_id == "" do card_id = json_string(params, "card")
	if card_id == "" do card_id = json_string(params, "id")
	if card_id == "" do return respond_error(domain.domain_error(.Validation_Failed, "card_id is required"), req.request_id)

	card, discarded, err := card_service.discard_card(h.cards, auth, domain.Card_ID(card_id))
	if !discarded do return respond_error(err, req.request_id)

	publish_agent_action(h, inst, "card_discard", fmt.tprintf("discarded card \"%s\"", card.title))

	b := strings.builder_make()
	write_card_json(&b, card)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

agent_action_card_accept_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp

	params := json_object_raw(req.body, "params")
	card_id := json_string(params, "card_id")
	if card_id == "" do card_id = json_string(params, "action_id")
	if card_id == "" do card_id = json_string(params, "card")
	if card_id == "" do card_id = json_string(params, "id")
	if card_id == "" do return respond_error(domain.domain_error(.Validation_Failed, "card_id is required"), req.request_id)

	card, accepted, err := card_service.accept_card(h.cards, auth, domain.Card_ID(card_id))
	if !accepted do return respond_error(err, req.request_id)

	publish_agent_action(h, inst, "card_accept", fmt.tprintf("accepted card \"%s\"", card.title))

	b := strings.builder_make()
	write_card_json(&b, card)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

agent_action_accepted_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	b := strings.builder_make()
	_ = auth
	strings.write_string(&b, "{\"accepted\":true,\"agent_instance_id\":\""); write_handler_json_string(&b, inst.agent_instance_id); strings.write_string(&b, "\",\"auth_kind\":\"instance_token\"}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 202)
}

require_instance_action_auth :: proc(h: ^Agent_Action_Handlers, req: Request) -> (contracts.Auth_Context, domain.Agent_Instance, bool, Response) {
	auth, ok, err := auth_service.resolve_bridge_instance_auth(h.auth, auth_service.Auth_Request{
		remote_addr = req.remote_addr,
		query = req.query,
		body = req.body,
		headers = req.headers,
	})
	if !ok do return contracts.Auth_Context{}, domain.Agent_Instance{}, false, respond_error(err, req.request_id)
	inst, inst_ok, inst_err := agent_service.get_instance(h.agents, contracts.Auth_Context{kind = .Bridge_Token, bridge_id = auth.bridge_id, user_id = auth.user_id}, auth.agent_instance_id)
	if !inst_ok do return contracts.Auth_Context{}, domain.Agent_Instance{}, false, respond_error(inst_err, req.request_id)
	// Task System v2: every authenticated instance call is an implicit lease
	// heartbeat (plan §2.3). Cheap when the instance holds nothing.
	taskv2.touch_instance(h.task_engine, auth.agent_instance_id)
	return auth, inst, true, Response{}
}

// write_agent_current_task_json serializes the instance's SERVER-AUTHORITATIVE
// current task: the lease it holds (Task System v2). agent_instances.current_task_*
// is kept in sync by the lease verbs, so the pointer IS the lease; a pointer with
// no matching task resolves to null.
write_agent_current_task_json :: proc(b: ^strings.Builder, h: ^Agent_Action_Handlers, auth: contracts.Auth_Context, inst: domain.Agent_Instance) {
	if h.taskchains == nil || inst.chain_id == "" || inst.current_task_id == "" { strings.write_string(b, "null"); return }
	tasks, err := taskchain_service.list_tasks(h.taskchains, auth, domain.Task_Chain_ID(inst.chain_id))
	if err.code != .None { strings.write_string(b, "null"); return }
	for task in tasks {
		if string(task.task_id) == inst.current_task_id {
			summary, _ := taskchain_service.task_comment_summary(h.taskchains, auth, task.task_id)
			write_current_task_json(b, task, inst.current_task_role, summary)
			return
		}
	}
	strings.write_string(b, "null")
}

// write_current_task_json emits a task with its work-vs-review role + priority so
// the agent/UI can render the current-task banner unambiguously (R8). It also
// carries the comment_summary so the snapshot shows fresh discussion without
// shipping bodies (agents fetch the thread with `task comments <id> --last N`).
write_current_task_json :: proc(b: ^strings.Builder, task: domain.Task, role: domain.Current_Task_Role, summary: domain.Task_Comment_Summary) {
	strings.write_string(b, "{\"task_id\":\""); write_handler_json_string(b, string(task.task_id))
	strings.write_string(b, "\",\"chain_id\":\""); write_handler_json_string(b, string(task.chain_id))
	strings.write_string(b, "\",\"title\":\""); write_handler_json_string(b, task.title)
	strings.write_string(b, "\",\"state\":\""); write_handler_json_string(b, domain.task_state_string(task.state))
	strings.write_string(b, "\",\"priority\":\""); write_handler_json_string(b, domain.task_priority_string(task.priority))
	strings.write_string(b, "\",\"attempt_no\":"); strings.write_string(b, fmt.tprintf("%d", task.attempt_no))
	strings.write_string(b, ",\"role\":\""); write_handler_json_string(b, domain.current_task_role_string(role))
	strings.write_string(b, "\",\"comment_summary\":")
	write_task_comment_summary_json(b, summary)
	strings.write_string(b, "}")
}

// verbatim_params / verbatim_field slice JSON values out of the raw request
// body without re-marshalling (facets are stored byte-for-byte, plan §4b).
verbatim_params :: proc(body: string) -> string {
	if p, ok := taskv2.raw_object_field(body, "params"); ok do return p
	return ""
}

verbatim_field :: proc(obj, key: string) -> string {
	if v, ok := taskv2.raw_value_field(obj, key); ok do return v
	return ""
}

// ---- M3b Workflow Agent-Action Handlers ---------------------------------------------

// POST /api/v1/agent-actions/workflow/templates
agent_action_workflow_templates_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	_, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	if h.task_engine == nil do return respond_error(domain.domain_error(.Internal_Error, "task engine is not configured"), req.request_id)
	publish_agent_action(h, inst, "workflow_templates", "listed workflow templates")
	return respond_success(build_workflow_templates_response_json(h.task_engine, inst.owner_user_id), req.request_id, auth_ctx_server_time(req), 200)
}

// POST /api/v1/agent-actions/workflow/list
agent_action_workflow_list_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	_, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	if h.task_engine == nil do return respond_error(domain.domain_error(.Internal_Error, "task engine is not configured"), req.request_id)
	defs, derr := taskv2.workflow_list_definitions(h.task_engine, inst.owner_user_id)
	if derr.code != .None do return respond_error(derr, req.request_id)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"definitions":[`)
	for d, i in defs {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, `{"def_id":"`); write_handler_json_string(&b, d.def_id)
		strings.write_string(&b, `","name":"`); write_handler_json_string(&b, d.name)
		strings.write_string(&b, fmt.tprintf(`","version":%d,"created_at":"`, d.version))
		write_handler_json_string(&b, d.created_at)
		strings.write_string(&b, `","spec":`)
		strings.write_string(&b, d.body_json)
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, `]}`)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

// POST /api/v1/agent-actions/workflow/define
agent_action_workflow_define_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	_, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	if h.task_engine == nil do return respond_error(domain.domain_error(.Internal_Error, "task engine is not configured"), req.request_id)
	params := verbatim_params(req.body)
	if strings.trim_space(params) == "" do params = req.body
	spec_json, name_ov, ver_ov := extract_workflow_define_spec(params)
	def, dok, derr := taskv2.workflow_define(h.task_engine, inst.owner_user_id, spec_json, name_ov, ver_ov)
	if !dok do return respond_error(derr, req.request_id)
	publish_agent_action(h, inst, "workflow_define", fmt.tprintf("defined workflow %s v%d", def.name, def.version))
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"def_id":"`); write_handler_json_string(&b, def.def_id)
	strings.write_string(&b, `","name":"`); write_handler_json_string(&b, def.name)
	strings.write_string(&b, fmt.tprintf(`","version":%d,"created_at":"`, def.version))
	write_handler_json_string(&b, d_created_or_empty(def.created_at))
	strings.write_string(&b, `","spec":`)
	strings.write_string(&b, def.body_json)
	strings.write_byte(&b, '}')
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

@(private = "file")
d_created_or_empty :: proc(s: string) -> string { return s }

// POST /api/v1/agent-actions/workflow/run
agent_action_workflow_run_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	if h.task_engine == nil do return respond_error(domain.domain_error(.Internal_Error, "task engine is not configured"), req.request_id)
	params := verbatim_params(req.body)
	if strings.trim_space(params) == "" do params = req.body
	run_in := extract_workflow_run_input(params)
	if run_in.coordinator_agent_instance_id == "" do run_in.coordinator_agent_instance_id = inst.agent_instance_id
	if run_in.bridge_id == "" do run_in.bridge_id = inst.bridge_id
	chain, rok, rerr := taskv2.workflow_run(h.task_engine, inst.owner_user_id, taskv2.actor_from_auth(auth), run_in)
	if !rok do return respond_error(rerr, req.request_id)
	publish_agent_action(h, inst, "workflow_run", fmt.tprintf("started workflow %s (%s)", run_in.ref, chain.chain_id))
	publish_chain_event(h.event_bus, string(chain.owner_user_id), string(chain.chain_id), "created")
	status_json, _, _ := taskv2.workflow_status_json(h.task_engine, chain.chain_id, chain.owner_user_id)
	if status_json == "" do status_json = "{}"
	cb := strings.builder_make(context.temp_allocator)
	write_chain_json(&cb, chain)
	return respond_success(fmt.tprintf(`{{"chain_id":"%s","chain":%s,"workflow":%s}}`, chain.chain_id, strings.to_string(cb), status_json), req.request_id, auth_ctx_server_time(req), 200)
}

// POST /api/v1/agent-actions/workflow/status
agent_action_workflow_status_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	_, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	if h.task_engine == nil do return respond_error(domain.domain_error(.Internal_Error, "task engine is not configured"), req.request_id)
	params := json_object_raw(req.body, "params")
	if strings.trim_space(params) == "" do params = req.body
	cid := strings.trim_space(json_string(params, "chain_id"))
	if cid == "" do cid = inst.chain_id
	if cid == "" do return respond_error(domain.domain_error(.Validation_Failed, "chain_id is required"), req.request_id)
	status_json, sok, serr := taskv2.workflow_status_json(h.task_engine, domain.Task_Chain_ID(cid), inst.owner_user_id)
	if !sok do return respond_error(serr, req.request_id)
	return respond_success(status_json, req.request_id, auth_ctx_server_time(req), 200)
}

// POST /api/v1/agent-actions/workflow/output
agent_action_workflow_output_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	_, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	if h.task_engine == nil do return respond_error(domain.domain_error(.Internal_Error, "task engine is not configured"), req.request_id)
	params := json_object_raw(req.body, "params")
	if strings.trim_space(params) == "" do params = req.body
	cid := strings.trim_space(json_string(params, "chain_id"))
	if cid == "" do cid = inst.chain_id
	if cid == "" do return respond_error(domain.domain_error(.Validation_Failed, "chain_id is required"), req.request_id)
	stage_key := strings.trim_space(json_string(params, "stage_key"))
	if stage_key == "" do stage_key = strings.trim_space(json_string(params, "stage"))
	out_json, ook, oerr := taskv2.workflow_stage_output_json(h.task_engine, domain.Task_Chain_ID(cid), inst.owner_user_id, stage_key)
	if !ook do return respond_error(oerr, req.request_id)
	return respond_success(out_json, req.request_id, auth_ctx_server_time(req), 200)
}

// POST /api/v1/agent-actions/workflow/retry
agent_action_workflow_retry_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	if h.task_engine == nil do return respond_error(domain.domain_error(.Internal_Error, "task engine is not configured"), req.request_id)
	params := json_object_raw(req.body, "params")
	if strings.trim_space(params) == "" do params = req.body
	cid := strings.trim_space(json_string(params, "chain_id"))
	if cid == "" do cid = inst.chain_id
	if cid == "" do return respond_error(domain.domain_error(.Validation_Failed, "chain_id is required"), req.request_id)
	stage_key := json_string(params, "stage_key")
	if stage_key == "" do stage_key = json_string(params, "stage")
	task_id := json_string(params, "task_id")
	if stage_key == "" && task_id == "" {
		target := json_string(params, "target")
		if strings.has_prefix(target, "task_") {
			task_id = target
		} else {
			stage_key = target
		}
	}
	cascade := jsonx.extract_bool(params, "cascade", false, true)
	reason := json_string(params, "reason")
	res, rok, rerr := taskv2.workflow_retry(h.task_engine, domain.Task_Chain_ID(cid), inst.owner_user_id, taskv2.actor_from_auth(auth), taskv2.Workflow_Retry_Input{
		stage_key = stage_key,
		task_id   = task_id,
		cascade   = cascade,
		reason    = reason,
	})
	if !rok do return respond_error(rerr, req.request_id)
	publish_agent_action(h, inst, "workflow_retry", fmt.tprintf("retried workflow stage %s", stage_key if stage_key != "" else task_id))
	publish_chain_event(h.event_bus, string(inst.owner_user_id), cid, "updated")
	return respond_success(marshal_workflow_retry_result(domain.Task_Chain_ID(cid), res), req.request_id, auth_ctx_server_time(req), 200)
}

// POST /api/v1/agent-actions/workflow/cancel
agent_action_workflow_cancel_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	if h.task_engine == nil do return respond_error(domain.domain_error(.Internal_Error, "task engine is not configured"), req.request_id)
	params := json_object_raw(req.body, "params")
	if strings.trim_space(params) == "" do params = req.body
	cid := strings.trim_space(json_string(params, "chain_id"))
	if cid == "" do cid = inst.chain_id
	if cid == "" do return respond_error(domain.domain_error(.Validation_Failed, "chain_id is required"), req.request_id)
	reason := json_string(params, "reason")
	saved, cok, cerr := taskv2.workflow_cancel(h.task_engine, domain.Task_Chain_ID(cid), inst.owner_user_id, taskv2.actor_from_auth(auth), reason)
	if !cok do return respond_error(cerr, req.request_id)
	publish_agent_action(h, inst, "workflow_cancel", fmt.tprintf("cancelled workflow %s", cid))
	publish_chain_event(h.event_bus, string(saved.owner_user_id), string(saved.chain_id), "cancelled")
	cb := strings.builder_make(context.temp_allocator)
	write_chain_json(&cb, saved)
	return respond_success(fmt.tprintf(`{{"chain_id":"%s","status":"cancelled","chain":%s}}`, saved.chain_id, strings.to_string(cb)), req.request_id, auth_ctx_server_time(req), 200)
}

