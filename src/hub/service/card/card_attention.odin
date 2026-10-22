package card

import "core:encoding/json"
import "core:slice"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import ownership "odin_test:hub/service/ownership"
import agent_service "odin_test:hub/service/agent"
import "core:strings"

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

// ATTENTION_FILTER_SNOOZED is the deck's Snoozed tab as a kind filter (not a
// card kind): cards whose snooze is still running, any served kind.
ATTENTION_FILTER_SNOOZED :: "snoozed"

ATTENTION_REASON_AWAITING_REVIEW :: "awaiting_review"
ATTENTION_REASON_QUESTION        :: "question"
ATTENTION_REASON_MEMORY_PROPOSAL :: "memory_proposal"
ATTENTION_REASON_PERMISSION       :: "permission"
ATTENTION_REASON_TERMINAL_PROMPT  :: "terminal_prompt"

// ATTENTION_KIND_AGENT_BLOCKER items are live agent blockers. They are NOT
// cards: they are built at read time from the agent service's in-memory map
// (agent_blockers.odin), never written to the cards/attention tables, and
// ignore `since` (a blocker is by definition current).
ATTENTION_KIND_AGENT_BLOCKER :: agent_service.AGENT_BLOCKER_ATTENTION_KIND

// A memory proposal turns warn when it expires within this window.
ATTENTION_MEMORY_WARN_BEFORE_EXPIRY :: 6 * time.Hour

Attention_Item_Context :: struct {
	chain_title:  string, // may be vault ciphertext; the client decrypts
	agent_name:   string,
	project_name: string, // reserved; '' in v1
	// Memory proposals: who/what the memory applies to, by name (names may be
	// vault ciphertext). An empty list means "all" for that dimension; an id
	// that no longer resolves gets a neutral fallback name.
	has_scope:      bool,
	scope_agents:   []string,
	scope_projects: []string,
	scope_bridges:  []string,
	scope_templates: []string,
}

Attention_Item :: struct {
	card:       domain.Card,
	reason:     string,
	urgency:    string,
	primary_op: string, // '' when the card has no one-tap action (messages)
	snoozed:    bool,   // in the Snoozed tab (snooze still running)
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
// since defaults to 24h; kind ('' | message | task | snoozed) filters items only
// -- counts always cover every kind. Live items (in range) come first in
// urgency order; snoozed items (range-independent) follow, soonest to wake first.
list_attention :: proc(s: ^Card_Service, auth: contracts.Auth_Context, since: string, kind: string, with_items: bool) -> (Attention_Result, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return {}, err
	if s == nil || s.attention_repo == nil do return {}, domain.domain_error(.Internal_Error, "attention is not configured")

	range_label := since if since != "" else "24h"
	window, all_time, range_ok := attention_range_duration(range_label)
	if !range_ok do return {}, domain.domain_error(.Validation_Failed, "since must be one of 6h, 24h, 7d, all")
	if kind != "" && kind != domain.CARD_KIND_MESSAGE && kind != domain.CARD_KIND_TASK && kind != domain.CARD_KIND_MEMORY && kind != ATTENTION_KIND_AGENT_BLOCKER && kind != ATTENTION_FILTER_SNOOZED {
		return {}, domain.domain_error(.Validation_Failed, "kind must be message, task, memory, agent_blocker or snoozed")
	}

	now := platform.clock_now(s.clock)
	now_t, now_ok := platform.parse_rfc3339_utc(now)
	if !now_ok do return {}, domain.domain_error(.Internal_Error, "clock returned an unparseable time")
	cutoff := ""
	if !all_time do cutoff = platform.format_rfc3339_utc(time.time_add(now_t, -window))

	counts, count_err := iface.attention_count(s.attention_repo, owner, cutoff, now)
	if count_err.code != .None do return {}, count_err
	blockers := agent_service.list_owner_blockers(s.agents, string(owner))
	counts.agent_blocker = len(blockers)
	result := Attention_Result{since = range_label, counts = counts}
	if !with_items do return result, domain.Domain_Error{}

	items := make([dynamic]Attention_Item)
	if kind == "" || kind == ATTENTION_KIND_AGENT_BLOCKER {
		for blk in blockers do append(&items, attention_blocker_item(blk))
	}
	for k in ([]string{domain.CARD_KIND_MESSAGE, domain.CARD_KIND_TASK, domain.CARD_KIND_MEMORY}) {
		if kind != "" && kind != k do continue
		cards, list_err := iface.attention_list_cards(s.attention_repo, owner, k, cutoff, now, ATTENTION_ITEMS_PER_KIND)
		if list_err.code != .None do return {}, list_err
		for c in cards do append(&items, attention_item_for(c, now_t))
	}
	slice.sort_by(items[:], attention_item_less)
	if kind == "" || kind == ATTENTION_FILTER_SNOOZED {
		snoozed, snoozed_err := iface.attention_list_snoozed_cards(s.attention_repo, owner, now, ATTENTION_ITEMS_PER_KIND)
		if snoozed_err.code != .None do return {}, snoozed_err
		for c in snoozed {
			item := attention_item_for(c, now_t)
			item.snoozed = true
			append(&items, item)
		}
	}
	attention_attach_context(s, owner, items[:])
	result.items = items[:]
	return result, domain.Domain_Error{}
}

// attention_blocker_item shapes one live agent blocker as an attention item:
// card_id blk:<blocker_id>, details {blocker_kind, tool_name, summary, input,
// agent_id, agent_instance_id, created_at, expires_at}, action_refs
// {agent_instance_id, chain_id, blocker_id}. Allow/Deny go through
// POST /api/v1/agent-instances/{id}/blockers/{blocker_id}/resolve, so there are
// no card operations. All strings live in the temp allocator.
attention_blocker_item :: proc(blk: agent_service.Owner_Blocker) -> Attention_Item {
	obj: json.Object
	if val, err := json.parse_string(blk.json, allocator = context.temp_allocator); err == .None {
		obj, _ = val.(json.Object)
	}
	text :: proc(obj: json.Object, key: string) -> string {
		v, _ := obj[key].(json.String)
		return string(v)
	}
	input := "{}"
	if in_obj, ok := obj["input"].(json.Object); ok {
		if bytes, merr := json.marshal(in_obj, allocator = context.temp_allocator); merr == nil do input = string(bytes)
	}
	tool_name, summary, created_at := text(obj, "tool_name"), text(obj, "summary"), text(obj, "created_at")
	is_permission := blk.kind == agent_service.AGENT_BLOCKER_KIND_PERMISSION

	d := strings.builder_make(context.temp_allocator)
	strings.write_string(&d, `{"blocker_kind":"`); contracts.write_json_string(&d, blk.kind)
	strings.write_string(&d, `","tool_name":"`); contracts.write_json_string(&d, tool_name)
	strings.write_string(&d, `","summary":"`); contracts.write_json_string(&d, summary)
	strings.write_string(&d, `","input":`); strings.write_string(&d, input)
	strings.write_string(&d, `,"agent_id":"`); contracts.write_json_string(&d, text(obj, "agent_id"))
	strings.write_string(&d, `","agent_instance_id":"`); contracts.write_json_string(&d, blk.agent_instance_id)
	strings.write_string(&d, `","created_at":"`); contracts.write_json_string(&d, created_at)
	strings.write_string(&d, `","expires_at":"`); contracts.write_json_string(&d, text(obj, "expires_at"))
	strings.write_string(&d, `"}`)

	r := strings.builder_make(context.temp_allocator)
	strings.write_string(&r, `{"agent_instance_id":"`); contracts.write_json_string(&r, blk.agent_instance_id)
	strings.write_string(&r, `","chain_id":"`); contracts.write_json_string(&r, blk.chain_id)
	strings.write_string(&r, `","blocker_id":"`); contracts.write_json_string(&r, blk.blocker_id)
	strings.write_string(&r, `"}`)

	title := summary
	if title == "" do title = tool_name if is_permission && tool_name != "" else "Waiting for input in the terminal"
	return Attention_Item{
		card = domain.Card{
			card_id = domain.Card_ID(strings.concatenate({"blk:", blk.blocker_id}, context.temp_allocator)),
			kind = ATTENTION_KIND_AGENT_BLOCKER,
			provider = "agent_blocker",
			status = "pending",
			attention_since = created_at,
			title = title,
			rationale = "Needs your permission" if is_permission else "Waiting for input in the agent terminal",
			operations_json = "[]",
			details_json = strings.to_string(d),
			action_refs_json = strings.to_string(r),
		},
		reason = ATTENTION_REASON_PERMISSION if is_permission else ATTENTION_REASON_TERMINAL_PROMPT,
		// The agent is stalled until someone answers: always top of the deck.
		urgency = ATTENTION_URGENCY_ERROR,
	}
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
	case domain.CARD_KIND_MEMORY:
		item.reason = ATTENTION_REASON_MEMORY_PROPOSAL
		item.urgency = ATTENTION_URGENCY_INFO
		if expires, ok := platform.parse_rfc3339_utc(attention_json_field(c.details_json, "expires_at")); ok {
			if time.diff(now, expires) < ATTENTION_MEMORY_WARN_BEFORE_EXPIRY do item.urgency = ATTENTION_URGENCY_WARN
		}
		item.primary_op = attention_first_op(c.operations_json)
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
		case domain.CARD_KIND_MEMORY, ATTENTION_KIND_AGENT_BLOCKER:
			if id := attention_json_field(refs, "chain_id"); id != "" do append(&chain_ids, id)
			if id := attention_json_field(refs, "agent_instance_id"); id != "" do append(&instance_ids, id)
		}
	}
	attention_attach_scope_names(s, owner, items)
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
		case domain.CARD_KIND_MEMORY:
			item.ctx.chain_title = resolved.chain_title[attention_json_field(refs, "chain_id")]
			item.ctx.agent_name = resolved.instance_name[attention_json_field(refs, "agent_instance_id")]
			// The proposer's name is snapshotted too, for a since-deleted instance.
			if item.ctx.agent_name == "" do item.ctx.agent_name = attention_json_field(item.card.details_json, "proposer_name")
		case ATTENTION_KIND_AGENT_BLOCKER:
			item.ctx.chain_title = resolved.chain_title[attention_json_field(refs, "chain_id")]
			item.ctx.agent_name = resolved.instance_name[attention_json_field(refs, "agent_instance_id")]
		}
	}
	delete(resolved.conversation_chain)
	delete(resolved.chain_title)
	delete(resolved.instance_name)
}

// attention_json_list reads a JSON string array field of an object (temp).
attention_json_list :: proc(raw: string, key: string) -> []string {
	val, err := json.parse_string(raw, allocator = context.temp_allocator)
	if err != .None do return nil
	obj, is_obj := val.(json.Object)
	if !is_obj do return nil
	arr, is_arr := obj[key].(json.Array)
	if !is_arr do return nil
	out := make([dynamic]string, 0, len(arr), context.temp_allocator)
	for v in arr {
		if str, is_str := v.(json.String); is_str && str != "" do append(&out, string(str))
	}
	return out[:]
}

// attention_attach_scope_names names every memory item's scope (who/what it
// applies to) with one batched lookup per dimension.
attention_attach_scope_names :: proc(s: ^Card_Service, owner: domain.User_ID, items: []Attention_Item) {
	agents := make([dynamic]string, context.temp_allocator)
	projects := make([dynamic]string, context.temp_allocator)
	bridges := make([dynamic]string, context.temp_allocator)
	templates := make([dynamic]string, context.temp_allocator)
	any_memory := false
	for item in items {
		if item.card.kind != domain.CARD_KIND_MEMORY do continue
		any_memory = true
		d := item.card.details_json
		append(&agents, ..attention_json_list(d, "agent_ids"))
		append(&projects, ..attention_json_list(d, "project_ids"))
		append(&bridges, ..attention_json_list(d, "bridge_ids"))
		append(&templates, ..attention_json_list(d, "template_ids"))
	}
	if !any_memory do return
	names, err := iface.attention_resolve_scope_names(s.attention_repo, owner, agents[:], projects[:], bridges[:], templates[:])
	defer {
		delete(names.agents); delete(names.projects); delete(names.bridges); delete(names.templates)
	}
	if err.code != .None do return
	// An id that no longer resolves still counts (dropping it could turn a
	// narrow scope into "all"), under a neutral fallback name.
	name_all :: proc(ids: []string, names: map[string]string, fallback: string, builtin_templates := false) -> []string {
		out := make([dynamic]string, 0, len(ids), context.temp_allocator)
		for id in ids {
			name := names[id]
			if name == "" && builtin_templates {
				if t, ok := domain.builtin_template(id); ok do name = t.name
			}
			append(&out, name if name != "" else fallback)
		}
		return out[:]
	}
	for &item in items {
		if item.card.kind != domain.CARD_KIND_MEMORY do continue
		d := item.card.details_json
		item.ctx.has_scope = true
		item.ctx.scope_agents = name_all(attention_json_list(d, "agent_ids"), names.agents, "an unknown agent")
		item.ctx.scope_projects = name_all(attention_json_list(d, "project_ids"), names.projects, "an unknown project")
		item.ctx.scope_bridges = name_all(attention_json_list(d, "bridge_ids"), names.bridges, "an unknown machine")
		item.ctx.scope_templates = name_all(attention_json_list(d, "template_ids"), names.templates, "an unknown template", true)
	}
}
