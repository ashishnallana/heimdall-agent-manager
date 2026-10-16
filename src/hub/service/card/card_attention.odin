package card

import "core:encoding/json"
import "core:slice"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import ownership "odin_test:hub/service/ownership"

// Attention API (attention deck v1): reads the source-backed cards the projector
// maintains and shapes them for the deck. Read-only; every action goes through
// the existing card / task / chat endpoints using the item's action_refs.

// ATTENTION_ITEMS_PER_KIND caps each kind's items; counts stay exact.
ATTENTION_ITEMS_PER_KIND :: 50

// Urgency escalation thresholds (age = now - attention_since).
ATTENTION_TASK_ERROR_AFTER    :: 24 * time.Hour
ATTENTION_MESSAGE_WARN_AFTER  :: 1 * time.Hour

ATTENTION_URGENCY_ERROR :: "error"
ATTENTION_URGENCY_WARN  :: "warn"
ATTENTION_URGENCY_INFO  :: "info"

ATTENTION_REASON_AWAITING_REVIEW :: "awaiting_review"
ATTENTION_REASON_QUESTION        :: "question"

Attention_Item_Context :: struct {
	chain_title:  string, // may be vault ciphertext; the client decrypts
	agent_name:   string,
	project_name: string, // reserved; '' in v1
}

Attention_Item :: struct {
	card:       domain.Card,
	reason:     string,
	urgency:    string,
	primary_op: string, // '' when the card has no one-tap action (messages)
	ctx:        Attention_Item_Context,
}

Attention_Result :: struct {
	since:  string,
	counts: iface.Attention_Counts,
	items:  []Attention_Item,
}

// attention_range_duration parses the deck's time range. ok=false for anything
// other than 6h / 24h / 7d / all; all=true means no lower bound.
attention_range_duration :: proc(since: string) -> (d: time.Duration, all: bool, ok: bool) {
	switch since {
	case "6h":  return 6 * time.Hour, false, true
	case "24h": return 24 * time.Hour, false, true
	case "7d":  return 7 * 24 * time.Hour, false, true
	case "all": return 0, true, true
	}
	return 0, false, false
}

// list_attention returns the deck's counts and, when with_items, its items.
// since defaults to 24h; kind ('' | message | task) filters items only -- counts
// always cover every kind in the range.
list_attention :: proc(s: ^Card_Service, auth: contracts.Auth_Context, since: string, kind: string, with_items: bool) -> (Attention_Result, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return {}, err
	if s == nil || s.attention_repo == nil do return {}, domain.domain_error(.Internal_Error, "attention is not configured")

	range_label := since if since != "" else "24h"
	window, all_time, range_ok := attention_range_duration(range_label)
	if !range_ok do return {}, domain.domain_error(.Validation_Failed, "since must be one of 6h, 24h, 7d, all")
	if kind != "" && kind != domain.CARD_KIND_MESSAGE && kind != domain.CARD_KIND_TASK {
		return {}, domain.domain_error(.Validation_Failed, "kind must be message or task")
	}

	now := platform.clock_now(s.clock)
	now_t, now_ok := platform.parse_rfc3339_utc(now)
	if !now_ok do return {}, domain.domain_error(.Internal_Error, "clock returned an unparseable time")
	cutoff := ""
	if !all_time do cutoff = platform.format_rfc3339_utc(time.time_add(now_t, -window))

	counts, count_err := iface.attention_count(s.attention_repo, owner, cutoff, now)
	if count_err.code != .None do return {}, count_err
	result := Attention_Result{since = range_label, counts = counts}
	if !with_items do return result, domain.Domain_Error{}

	items := make([dynamic]Attention_Item)
	for k in ([]string{domain.CARD_KIND_MESSAGE, domain.CARD_KIND_TASK}) {
		if kind != "" && kind != k do continue
		cards, list_err := iface.attention_list_cards(s.attention_repo, owner, k, cutoff, now, ATTENTION_ITEMS_PER_KIND)
		if list_err.code != .None do return {}, list_err
		for c in cards do append(&items, attention_item_for(c, now_t))
	}
	attention_attach_context(s, owner, items[:])
	slice.sort_by(items[:], attention_item_less)
	result.items = items[:]
	return result, domain.Domain_Error{}
}

attention_item_for :: proc(c: domain.Card, now: time.Time) -> Attention_Item {
	age: time.Duration
	if since_t, ok := platform.parse_rfc3339_utc(c.attention_since); ok do age = time.diff(since_t, now)
	item := Attention_Item{card = c}
	switch c.kind {
	case domain.CARD_KIND_TASK:
		item.reason = ATTENTION_REASON_AWAITING_REVIEW
		item.urgency = ATTENTION_URGENCY_ERROR if age > ATTENTION_TASK_ERROR_AFTER else ATTENTION_URGENCY_WARN
		item.primary_op = attention_first_op(c.operations_json)
	case domain.CARD_KIND_MESSAGE:
		item.reason = ATTENTION_REASON_QUESTION
		item.urgency = ATTENTION_URGENCY_WARN if age > ATTENTION_MESSAGE_WARN_AFTER else ATTENTION_URGENCY_INFO
	}
	return item
}

attention_urgency_rank :: proc(u: string) -> int {
	switch u {
	case ATTENTION_URGENCY_ERROR: return 3
	case ATTENTION_URGENCY_WARN:  return 2
	}
	return 1
}

// Deterministic order: urgency desc, then oldest first, then card_id.
attention_item_less :: proc(a, b: Attention_Item) -> bool {
	ra, rb := attention_urgency_rank(a.urgency), attention_urgency_rank(b.urgency)
	if ra != rb do return ra > rb
	if a.card.attention_since != b.card.attention_since do return a.card.attention_since < b.card.attention_since
	return string(a.card.card_id) < string(b.card.card_id)
}

attention_first_op :: proc(operations_json: string) -> string {
	val, err := json.parse_string(operations_json, allocator = context.temp_allocator)
	if err != .None do return ""
	arr, is_arr := val.(json.Array)
	if !is_arr || len(arr) == 0 do return ""
	obj, is_obj := arr[0].(json.Object)
	if !is_obj do return ""
	op, is_str := obj["op"].(json.String)
	if !is_str do return ""
	return string(op)
}

attention_json_field :: proc(raw: string, key: string) -> string {
	val, err := json.parse_string(raw, allocator = context.temp_allocator)
	if err != .None do return ""
	obj, is_obj := val.(json.Object)
	if !is_obj do return ""
	#partial switch v in obj[key] {
	case json.String: return string(v)
	case json.Object:
		// nested excerpt.author_name
		name, _ := v["author_name"].(json.String)
		return string(name)
	}
	return ""
}

// attention_attach_context resolves chain titles and agent names for every
// item in one batched lookup (no per-item queries).
attention_attach_context :: proc(s: ^Card_Service, owner: domain.User_ID, items: []Attention_Item) {
	conversation_ids := make([dynamic]string, context.temp_allocator)
	chain_ids := make([dynamic]string, context.temp_allocator)
	instance_ids := make([dynamic]string, context.temp_allocator)
	for item in items {
		refs := item.card.action_refs_json
		switch item.card.kind {
		case domain.CARD_KIND_TASK:
			if id := attention_json_field(refs, "chain_id"); id != "" do append(&chain_ids, id)
		case domain.CARD_KIND_MESSAGE:
			if id := attention_json_field(refs, "conversation_id"); id != "" do append(&conversation_ids, id)
			if id := attention_json_field(refs, "agent_instance_id"); id != "" do append(&instance_ids, id)
		}
	}
	resolved, err := iface.attention_resolve_context(s.attention_repo, owner, conversation_ids[:], chain_ids[:], instance_ids[:])
	if err.code != .None {
		delete(resolved.conversation_chain); delete(resolved.chain_title); delete(resolved.instance_name)
		return
	}
	for &item in items {
		refs := item.card.action_refs_json
		switch item.card.kind {
		case domain.CARD_KIND_TASK:
			item.ctx.chain_title = resolved.chain_title[attention_json_field(refs, "chain_id")]
			// The assignee's name is snapshotted into details by the projector.
			item.ctx.agent_name = attention_json_field(item.card.details_json, "assignee_name")
		case domain.CARD_KIND_MESSAGE:
			chain_id := resolved.conversation_chain[attention_json_field(refs, "conversation_id")]
			item.ctx.chain_title = resolved.chain_title[chain_id]
			item.ctx.agent_name = resolved.instance_name[attention_json_field(refs, "agent_instance_id")]
			if item.ctx.agent_name == "" do item.ctx.agent_name = attention_json_field(item.card.details_json, "excerpt")
		}
	}
	delete(resolved.conversation_chain)
	delete(resolved.chain_title)
	delete(resolved.instance_name)
}
