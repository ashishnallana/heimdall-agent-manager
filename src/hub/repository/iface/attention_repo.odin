package iface

import domain "odin_test:hub/domain"

// Attention_Repository backs the attention card projector and the attention API
// (attention deck v1). It owns the projector's conditional card writes and the
// indexed source queries the projector and its reconciliation sweep need, so the
// general Card/Taskchain/Content repositories keep their existing contracts.

// Attention_Card_Insert_Proc inserts card only when no row with its card_id
// exists. inserted=false (with no error) means another writer got there first.
Attention_Card_Insert_Proc :: proc(ctx: rawptr, card: domain.Card) -> (inserted: bool, err: domain.Domain_Error)

// Attention_Card_CAS_Proc writes every mutable column of card only if the stored
// row still has expect_status and expect_marker (compare-and-set). changed=false
// means the row moved underneath; the caller re-reads and recomputes.
Attention_Card_CAS_Proc :: proc(ctx: rawptr, card: domain.Card, expect_status, expect_marker: string) -> (changed: bool, err: domain.Domain_Error)

Attention_List_Validation_Task_IDs_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Task_ID, domain.Domain_Error)

// Attention_Latest_Actionable_Message_Proc returns the newest unread
// agent_to_user message sent by instance_id whose metadata.options is a
// non-empty array and that the user has not answered since (no later
// user_to_agent message in its conversation). other_unread counts the
// instance's remaining unread agent_to_user messages.
Attention_Latest_Actionable_Message_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID, agent_instance_id: string) -> (msg: domain.Chat_Message, found: bool, other_unread: int, err: domain.Domain_Error)

Attention_List_Actionable_Instance_IDs_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]string, domain.Domain_Error)

// Attention_List_Live_Cards_Proc lists an owner's cards of provider that are
// still live for the deck (pending or snoozed) -- the reconciliation sweep
// re-projects each one so a stale card is retired.
Attention_List_Live_Cards_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID, provider: string) -> ([]domain.Card, domain.Domain_Error)

Attention_List_Owners_Proc :: proc(ctx: rawptr) -> ([]domain.User_ID, domain.Domain_Error)

// ---- attention API reads ----

// A card is LIVE for the deck when it is pending, or snoozed with a snooze that
// has expired as of now. cutoff is the RFC3339 lower bound on attention_since
// ('' = all time).

// Attention_Counts: live cards per kind with attention_since >= cutoff, plus
// older = live cards (any served kind) older than cutoff, plus snoozed = cards
// (any served kind) whose snooze is still running -- range-independent, and
// never part of the deck's total.
Attention_Counts :: struct {
	message: int,
	task:    int,
	older:   int,
	snoozed: int,
}

// Attention_List_Cards_Proc lists one kind's live cards in range, oldest first
// (attention_since ASC, card_id ASC), at most limit.
Attention_List_Cards_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID, kind, cutoff, now: string, limit: int) -> ([]domain.Card, domain.Domain_Error)
// Attention_List_Snoozed_Cards_Proc lists the served kinds' cards whose snooze is
// still running as of now (snooze_until '' or > now), soonest to wake first.
Attention_List_Snoozed_Cards_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID, now: string, limit: int) -> ([]domain.Card, domain.Domain_Error)
Attention_Count_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID, cutoff, now: string) -> (Attention_Counts, domain.Domain_Error)

// Attention_Context resolves display context in batch (one query per map),
// owner-scoped, so listing N items never costs N queries.
Attention_Context :: struct {
	conversation_chain: map[string]string, // conversation_id -> chain_id
	chain_title:        map[string]string, // chain_id -> title (may be ciphertext)
	instance_name:      map[string]string, // agent_instance_id -> display_name
}
Attention_Resolve_Context_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID, conversation_ids, chain_ids, instance_ids: []string) -> (Attention_Context, domain.Domain_Error)

Attention_Repository :: struct {
	ctx:                           rawptr,
	card_insert_if_absent:         Attention_Card_Insert_Proc,
	card_compare_and_set:          Attention_Card_CAS_Proc,
	list_validation_task_ids:      Attention_List_Validation_Task_IDs_Proc,
	latest_actionable_message:     Attention_Latest_Actionable_Message_Proc,
	list_actionable_instance_ids:  Attention_List_Actionable_Instance_IDs_Proc,
	list_live_cards:               Attention_List_Live_Cards_Proc,
	list_owners:                   Attention_List_Owners_Proc,
	list_cards:                    Attention_List_Cards_Proc,
	list_snoozed_cards:            Attention_List_Snoozed_Cards_Proc,
	count:                         Attention_Count_Proc,
	resolve_context:               Attention_Resolve_Context_Proc,
}

attention_not_configured :: proc() -> domain.Domain_Error {
	return domain.domain_error(.Internal_Error, "attention repository is not configured")
}

attention_card_insert_if_absent :: proc(r: ^Attention_Repository, card: domain.Card) -> (bool, domain.Domain_Error) {
	if r == nil || r.card_insert_if_absent == nil do return false, attention_not_configured()
	return r.card_insert_if_absent(r.ctx, card)
}

attention_card_compare_and_set :: proc(r: ^Attention_Repository, card: domain.Card, expect_status, expect_marker: string) -> (bool, domain.Domain_Error) {
	if r == nil || r.card_compare_and_set == nil do return false, attention_not_configured()
	return r.card_compare_and_set(r.ctx, card, expect_status, expect_marker)
}

attention_list_validation_task_ids :: proc(r: ^Attention_Repository, owner: domain.User_ID) -> ([]domain.Task_ID, domain.Domain_Error) {
	if r == nil || r.list_validation_task_ids == nil do return nil, attention_not_configured()
	return r.list_validation_task_ids(r.ctx, owner)
}

attention_latest_actionable_message :: proc(r: ^Attention_Repository, owner: domain.User_ID, agent_instance_id: string) -> (domain.Chat_Message, bool, int, domain.Domain_Error) {
	if r == nil || r.latest_actionable_message == nil do return {}, false, 0, attention_not_configured()
	return r.latest_actionable_message(r.ctx, owner, agent_instance_id)
}

attention_list_actionable_instance_ids :: proc(r: ^Attention_Repository, owner: domain.User_ID) -> ([]string, domain.Domain_Error) {
	if r == nil || r.list_actionable_instance_ids == nil do return nil, attention_not_configured()
	return r.list_actionable_instance_ids(r.ctx, owner)
}

attention_list_live_cards :: proc(r: ^Attention_Repository, owner: domain.User_ID, provider: string) -> ([]domain.Card, domain.Domain_Error) {
	if r == nil || r.list_live_cards == nil do return nil, attention_not_configured()
	return r.list_live_cards(r.ctx, owner, provider)
}

attention_list_owners :: proc(r: ^Attention_Repository) -> ([]domain.User_ID, domain.Domain_Error) {
	if r == nil || r.list_owners == nil do return nil, attention_not_configured()
	return r.list_owners(r.ctx)
}

attention_list_cards :: proc(r: ^Attention_Repository, owner: domain.User_ID, kind, cutoff, now: string, limit: int) -> ([]domain.Card, domain.Domain_Error) {
	if r == nil || r.list_cards == nil do return nil, attention_not_configured()
	return r.list_cards(r.ctx, owner, kind, cutoff, now, limit)
}

attention_list_snoozed_cards :: proc(r: ^Attention_Repository, owner: domain.User_ID, now: string, limit: int) -> ([]domain.Card, domain.Domain_Error) {
	if r == nil || r.list_snoozed_cards == nil do return nil, attention_not_configured()
	return r.list_snoozed_cards(r.ctx, owner, now, limit)
}

attention_count :: proc(r: ^Attention_Repository, owner: domain.User_ID, cutoff, now: string) -> (Attention_Counts, domain.Domain_Error) {
	if r == nil || r.count == nil do return {}, attention_not_configured()
	return r.count(r.ctx, owner, cutoff, now)
}

attention_resolve_context :: proc(r: ^Attention_Repository, owner: domain.User_ID, conversation_ids, chain_ids, instance_ids: []string) -> (Attention_Context, domain.Domain_Error) {
	if r == nil || r.resolve_context == nil do return {}, attention_not_configured()
	return r.resolve_context(r.ctx, owner, conversation_ids, chain_ids, instance_ids)
}
