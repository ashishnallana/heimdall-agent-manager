package http

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import auth_service "odin_test:hub/service/auth"
import card_service "odin_test:hub/service/card"
import jsonx "odin_test:lib/jsonx"

Card_Handlers :: struct {
	auth:  ^auth_service.Auth_Service,
	cards: ^card_service.Card_Service,
	clock: ^platform.Clock,
}

write_card_json :: proc(b: ^strings.Builder, c: domain.Card) {
	strings.write_string(b, "{\"card_id\":\"")
	write_handler_json_string(b, string(c.card_id))
	strings.write_string(b, "\",\"action_id\":\"")
	write_handler_json_string(b, string(c.card_id))
	strings.write_string(b, "\",\"owner_user_id\":\"")
	write_handler_json_string(b, string(c.owner_user_id))
	strings.write_string(b, "\",\"project_id\":\"")
	write_handler_json_string(b, string(c.project_id))
	strings.write_string(b, "\",\"title\":\"")
	write_handler_json_string(b, c.title)
	strings.write_string(b, "\",\"rationale\":\"")
	write_handler_json_string(b, c.rationale)
	strings.write_string(b, "\",\"scope\":\"")
	write_handler_json_string(b, c.scope)
	strings.write_string(b, "\",\"provider\":\"")
	write_handler_json_string(b, c.provider)
	strings.write_string(b, fmt.tprintf("\",\"confidence\":%.4f", c.confidence))
	strings.write_string(b, ",\"source_refs\":")
	if c.source_refs_json != "" do strings.write_string(b, c.source_refs_json)
	else do strings.write_string(b, "[]")
	strings.write_string(b, ",\"status\":\"")
	write_handler_json_string(b, c.status)
	strings.write_string(b, "\",\"operations\":")
	if c.operations_json != "" do strings.write_string(b, c.operations_json)
	else do strings.write_string(b, "[]")
	strings.write_string(b, ",\"guard\":")
	if c.guard_json != "" do strings.write_string(b, c.guard_json)
	else do strings.write_string(b, "{}")
	strings.write_string(b, ",\"snooze_until\":\"")
	write_handler_json_string(b, c.snooze_until)
	strings.write_string(b, "\",\"ttl_at\":\"")
	write_handler_json_string(b, c.ttl_at)
	strings.write_string(b, "\",\"created_at\":\"")
	write_handler_json_string(b, c.created_at)
	strings.write_string(b, "\",\"updated_at\":\"")
	write_handler_json_string(b, c.updated_at)
	// Attention fields (migration 087).
	strings.write_string(b, "\",\"kind\":\"")
	write_handler_json_string(b, c.kind)
	strings.write_string(b, "\",\"attention_since\":\"")
	write_handler_json_string(b, c.attention_since)
	strings.write_string(b, "\",\"details\":")
	strings.write_string(b, c.details_json if c.details_json != "" else "{}")
	strings.write_string(b, ",\"action_refs\":")
	strings.write_string(b, c.action_refs_json if c.action_refs_json != "" else "{}")
	strings.write_string(b, "}")
}

json_f32 :: proc(body, key: string, fallback: f32) -> f32 {
	parsed, err := json.parse_string(body, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	defer json.destroy_value(parsed, context.temp_allocator)
	if err != .None do return fallback
	val, ok := jsonx.find_value(parsed, key, false)
	if !ok do return fallback
	#partial switch v in val {
	case json.Float:
		return f32(v)
	case json.Integer:
		return f32(v)
	case json.String:
		if p, pok := strconv.parse_f32(string(v)); pok do return p
		return fallback
	case:
		return fallback
	}
}

json_raw_field :: proc(body, key: string, allocator := context.allocator) -> (string, bool) {
	parsed, err := json.parse_string(body, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	defer json.destroy_value(parsed, context.temp_allocator)
	if err != .None do return "", false
	val, ok := jsonx.find_value(parsed, key, false)
	if !ok do return "", false
	bytes, merr := json.marshal(val, json.Marshal_Options{}, allocator)
	if merr != nil do return "", false
	return string(bytes), true
}

list_cards_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Card_Handlers)(ctx)
	auth, ok, resp := require_auth(h.auth, req)
	if !ok do return resp

	limit := query_int(req.query, "limit", 50)
	if limit <= 0 do limit = 50
	if limit > 200 do limit = 200

	filter := card_service.Card_Filter{
		status     = query_value(req.query, "status"),
		scope      = query_value(req.query, "scope"),
		provider   = query_value(req.query, "provider"),
		project_id = domain.Project_ID(query_value(req.query, "project_id")),
	}

	cards, err := card_service.list_cards(h.cards, auth, filter, limit)
	if err.code != .None do return respond_error(err, req.request_id)
	defer delete(cards)

	b := strings.builder_make()
	strings.write_byte(&b, '[')
	for c, i in cards {
		if i > 0 do strings.write_byte(&b, ',')
		write_card_json(&b, c)
	}
	strings.write_byte(&b, ']')

	return respond_list(strings.to_string(b), contracts.API_Page{limit = limit, has_more = len(cards) >= limit}, req.request_id, auth_ctx_server_time(req))
}

create_card_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Card_Handlers)(ctx)
	auth, ok, resp := require_auth(h.auth, req)
	if !ok do return resp

	raw_refs, _ := json_raw_field(req.body, "source_refs")
	raw_ops, _ := json_raw_field(req.body, "operations")
	raw_guard, _ := json_raw_field(req.body, "guard")

	input := card_service.Card_Input{
		project_id       = domain.Project_ID(json_string(req.body, "project_id")),
		title            = json_string(req.body, "title"),
		rationale        = json_string(req.body, "rationale"),
		scope            = json_string(req.body, "scope"),
		provider         = json_string(req.body, "provider"),
		confidence       = json_f32(req.body, "confidence", 1.0),
		source_refs_json = raw_refs,
		status           = json_string(req.body, "status"),
		operations_json  = raw_ops,
		guard_json       = raw_guard,
		snooze_until     = json_string(req.body, "snooze_until"),
		ttl_at           = json_string(req.body, "ttl_at"),
	}

	card, saved, err := card_service.create_card(h.cards, auth, input)
	if !saved do return respond_error(err, req.request_id)

	b := strings.builder_make()
	write_card_json(&b, card)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

get_card_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Card_Handlers)(ctx)
	auth, ok, resp := require_auth(h.auth, req)
	if !ok do return resp

	id := domain.Card_ID(path_part(req.path, 4))
	card, got, err := card_service.get_card(h.cards, auth, id)
	if !got do return respond_error(err, req.request_id)

	b := strings.builder_make()
	write_card_json(&b, card)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

patch_card_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Card_Handlers)(ctx)
	auth, ok, resp := require_auth(h.auth, req)
	if !ok do return resp

	id := domain.Card_ID(path_part(req.path, 4))

	raw_refs, has_refs := json_raw_field(req.body, "source_refs")
	raw_ops, has_ops := json_raw_field(req.body, "operations")
	raw_guard, has_guard := json_raw_field(req.body, "guard")

	input := card_service.Card_Update_Input{
		has_title        = json_key_present(req.body, "title"),
		title            = json_string(req.body, "title"),
		has_rationale    = json_key_present(req.body, "rationale"),
		rationale        = json_string(req.body, "rationale"),
		has_scope        = json_key_present(req.body, "scope"),
		scope            = json_string(req.body, "scope"),
		has_provider     = json_key_present(req.body, "provider"),
		provider         = json_string(req.body, "provider"),
		has_confidence   = json_key_present(req.body, "confidence"),
		confidence       = json_f32(req.body, "confidence", 1.0),
		has_source_refs  = has_refs,
		source_refs_json = raw_refs,
		has_status       = json_key_present(req.body, "status"),
		status           = json_string(req.body, "status"),
		has_operations   = has_ops,
		operations_json  = raw_ops,
		has_guard        = has_guard,
		guard_json       = raw_guard,
		has_snooze_until = json_key_present(req.body, "snooze_until"),
		snooze_until     = json_string(req.body, "snooze_until"),
		has_ttl_at       = json_key_present(req.body, "ttl_at"),
		ttl_at           = json_string(req.body, "ttl_at"),
	}

	card, updated, err := card_service.update_card(h.cards, auth, id, input)
	if !updated do return respond_error(err, req.request_id)

	b := strings.builder_make()
	write_card_json(&b, card)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

delete_card_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Card_Handlers)(ctx)
	auth, ok, resp := require_auth(h.auth, req)
	if !ok do return resp

	id := domain.Card_ID(path_part(req.path, 4))
	deleted, err := card_service.delete_card(h.cards, auth, id)
	if !deleted do return respond_error(err, req.request_id)

	return respond_success("{\"deleted\":true}", req.request_id, auth_ctx_server_time(req))
}

// card_decision_from_body: the optional words of a task-card decision —
// {note} on accept (Answer), {summary, findings} on reject (Request changes).
card_decision_from_body :: proc(body: string) -> card_service.Card_Decision {
	if strings.trim_space(body) == "" do return {}
	findings, _ := jsonx.extract_raw_array(body, "findings", true, context.temp_allocator)
	return card_service.Card_Decision{
		note          = json_string(body, "note"),
		summary       = json_string(body, "summary"),
		findings_json = findings,
		expected_block = json_string(body, "expected_block"),
	}
}

card_action_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Card_Handlers)(ctx)
	auth, ok, resp := require_auth(h.auth, req)
	if !ok do return resp

	id := domain.Card_ID(path_part(req.path, 4))
	action := path_part(req.path, 5)

	card: domain.Card
	action_ok := false
	err: domain.Domain_Error

	switch action {
	case "discard":
		card, action_ok, err = card_service.discard_card(h.cards, auth, id)
	case "accept":
		card, action_ok, err = card_service.accept_card(h.cards, auth, id, card_decision_from_body(req.body))
	case "reject":
		card, action_ok, err = card_service.reject_card(h.cards, auth, id, card_decision_from_body(req.body))
	case "snooze":
		snooze_until := json_string(req.body, "snooze_until")
		card, action_ok, err = card_service.snooze_card(h.cards, auth, id, snooze_until)
	case:
		return respond_error(domain.domain_error(.Not_Found, "route not found"), req.request_id)
	}

	if !action_ok do return respond_error(err, req.request_id)

	b := strings.builder_make()
	write_card_json(&b, card)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}
