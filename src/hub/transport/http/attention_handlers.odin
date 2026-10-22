package http

import "core:strings"
import iface "odin_test:hub/repository/iface"
import card_service "odin_test:hub/service/card"

// Attention deck v1 (REQ-AT-1..3): one read for everything the deck renders in a
// time range, and a counts-only read for the always-visible bar. Served by the
// card service; mounted on Card_Handlers.
//
//   GET /api/v1/attention?since=6h|24h|7d|all&kind=message|task|memory|agent_blocker|snoozed
//
// agent_blocker items are live agent blockers (permission prompts / terminal
// prompts) merged in at read time from the agent service's in-memory map.
//   GET /api/v1/attention/summary?since=...

attention_handler :: proc(ctx: rawptr, req: Request) -> Response {
	return attention_respond(ctx, req, true)
}

attention_summary_handler :: proc(ctx: rawptr, req: Request) -> Response {
	return attention_respond(ctx, req, false)
}

attention_respond :: proc(ctx: rawptr, req: Request, with_items: bool) -> Response {
	h := (^Card_Handlers)(ctx)
	auth, ok, resp := require_auth(h.auth, req)
	if !ok do return resp
	kind := query_value(req.query, "kind") if with_items else ""
	result, err := card_service.list_attention(h.cards, auth, query_value(req.query, "since"), kind, with_items)
	if err.code != .None do return respond_error(err, req.request_id)
	defer delete(result.items)

	b := strings.builder_make()
	strings.write_string(&b, `{"since":"`)
	write_handler_json_string(&b, result.since)
	strings.write_string(&b, `","counts":`)
	write_attention_counts_json(&b, result.counts)
	if with_items {
		strings.write_string(&b, `,"items":[`)
		for item, i in result.items {
			if i > 0 do strings.write_byte(&b, ',')
			write_attention_item_json(&b, item)
		}
		strings.write_byte(&b, ']')
	}
	strings.write_byte(&b, '}')
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

write_attention_counts_json :: proc(b: ^strings.Builder, c: iface.Attention_Counts) {
	// Built piecewise: fmt treats a literal '{' as a format directive.
	strings.write_string(b, `{"total":`)
	strings.write_int(b, c.message + c.task + c.memory + c.agent_blocker)
	strings.write_string(b, `,"older":`)
	strings.write_int(b, c.older)
	strings.write_string(b, `,"message":`)
	strings.write_int(b, c.message)
	strings.write_string(b, `,"task":`)
	strings.write_int(b, c.task)
	strings.write_string(b, `,"memory":`)
	strings.write_int(b, c.memory)
	strings.write_string(b, `,"snoozed":`)
	strings.write_int(b, c.snoozed)
	strings.write_string(b, `,"agent_blocker":`)
	strings.write_int(b, c.agent_blocker)
	strings.write_byte(b, '}')
}

// write_attention_item_json emits only what a card renders and acts on. ids
// appear only in card_id / action_refs (for actions), never in display fields.
write_attention_item_json :: proc(b: ^strings.Builder, item: card_service.Attention_Item) {
	c := item.card
	strings.write_string(b, `{"card_id":"`)
	write_handler_json_string(b, string(c.card_id))
	strings.write_string(b, `","kind":"`)
	write_handler_json_string(b, c.kind)
	strings.write_string(b, `","provider":"`)
	write_handler_json_string(b, c.provider)
	strings.write_string(b, `","reason":"`)
	write_handler_json_string(b, item.reason)
	strings.write_string(b, `","urgency":"`)
	write_handler_json_string(b, item.urgency)
	strings.write_string(b, `","status":"`)
	write_handler_json_string(b, c.status)
	strings.write_string(b, `","snoozed":`)
	strings.write_string(b, "true" if item.snoozed else "false")
	strings.write_string(b, `,"snooze_until":"`)
	write_handler_json_string(b, c.snooze_until if item.snoozed else "")
	strings.write_string(b, `","attention_since":"`)
	write_handler_json_string(b, c.attention_since)
	strings.write_string(b, `","title":"`)
	write_handler_json_string(b, c.title)
	strings.write_string(b, `","rationale":"`)
	write_handler_json_string(b, c.rationale)
	strings.write_string(b, `","primary_op":`)
	if item.primary_op != "" {
		strings.write_byte(b, '"')
		write_handler_json_string(b, item.primary_op)
		strings.write_byte(b, '"')
	} else {
		strings.write_string(b, "null")
	}
	strings.write_string(b, `,"operations":`)
	strings.write_string(b, c.operations_json if c.operations_json != "" else "[]")
	strings.write_string(b, `,"details":`)
	strings.write_string(b, c.details_json if c.details_json != "" else "{}")
	strings.write_string(b, `,"action_refs":`)
	strings.write_string(b, c.action_refs_json if c.action_refs_json != "" else "{}")
	strings.write_string(b, `,"context":{"chain_title":"`)
	write_handler_json_string(b, item.ctx.chain_title)
	strings.write_string(b, `","agent_name":"`)
	write_handler_json_string(b, item.ctx.agent_name)
	strings.write_string(b, `","project_name":"`)
	write_handler_json_string(b, item.ctx.project_name)
	strings.write_byte(b, '"')
	if item.ctx.has_scope {
		// Memory proposals: who/what it applies to, by name; [] = all.
		strings.write_string(b, `,"scope":{"agents":`)
		write_attention_name_list(b, item.ctx.scope_agents)
		strings.write_string(b, `,"projects":`)
		write_attention_name_list(b, item.ctx.scope_projects)
		strings.write_string(b, `,"bridges":`)
		write_attention_name_list(b, item.ctx.scope_bridges)
		strings.write_string(b, `,"templates":`)
		write_attention_name_list(b, item.ctx.scope_templates)
		strings.write_byte(b, '}')
	}
	strings.write_string(b, `}}`)
}

write_attention_name_list :: proc(b: ^strings.Builder, names: []string) {
	strings.write_byte(b, '[')
	for name, i in names {
		if i > 0 do strings.write_byte(b, ',')
		strings.write_byte(b, '"')
		write_handler_json_string(b, name)
		strings.write_byte(b, '"')
	}
	strings.write_byte(b, ']')
}
