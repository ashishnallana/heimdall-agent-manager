package card

import "core:fmt"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import content_service "odin_test:hub/service/content"

// Regressions for the codex-reviewer NGTM on the attention API.

// Finding 1: a projected task card must be able to execute its advertised
// action end to end through accept_card (not just mark_card_accepted), and a
// task the user cannot vote on (no reviewer) must not be projected at all.
@(test)
test_review_fix_task_card_accept_executes_vote :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_fix_accept_vote")
	defer ph_close(&h)

	ph_save_task(t, &h, ph_task("task_noreviewer", .In_Validation, "2026-10-01T02:00:00Z", "[]"))
	_, exists := ph_card(t, &h, attention_task_card_id("task_noreviewer"))
	testing.expect(t, !exists, "no-reviewer task is not awaiting the user (the user cannot vote on it)")

	ph_save_task(t, &h, ph_task("task_user", .In_Validation, "2026-10-01T02:00:00Z"))
	cid := attention_task_card_id("task_user")
	card, ok := ph_card(t, &h, cid)
	testing.expect(t, ok && card.status == domain.CARD_STATUS_PENDING, "user-reviewed task is projected")

	accepted, acc_ok, acc_err := accept_card(&h.svc, contracts.Auth_Context{kind = .User_Token, user_id = string(PH_OWNER)}, cid)
	testing.expectf(t, acc_ok, "accept_card executes task.answer: %v %s", acc_err.code, acc_err.message)
	testing.expect_value(t, accepted.status, domain.CARD_STATUS_ACCEPTED)
	answered, _, _ := iface.taskchain_get_task(&h.tasks, "task_user")
	testing.expect_value(t, answered.blocked_on_json, "")
}

// Finding 2: mark-read must clear EVERY unread incoming message, not the newest
// 200, so an older unread question cannot resurface as a card.
@(test)
test_review_fix_mark_read_clears_more_than_200 :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_fix_mark_read_205")
	defer ph_close(&h)
	ph_conversation(t, &h, "chat_big", "inst_big")
	for i in 0 ..< 205 {
		ph_message(t, &h, fmt.tprintf("msg_%03d", i), "chat_big", "inst_big", "agent_to_user", fmt.tprintf("2026-10-01T01:%02d:%02dZ", i / 60, i % 60), `{"options":["Yes","No"]}`)
	}
	c, _ := ph_card(t, &h, attention_message_card_id("inst_big"))
	testing.expect_value(t, c.status, domain.CARD_STATUS_PENDING)

	_, read_ok, read_err := content_service.mark_read(&h.content_svc, contracts.Auth_Context{kind = .User_Token, user_id = string(PH_OWNER)}, "chat_big")
	testing.expectf(t, read_ok, "mark read: %s", read_err.message)
	c2, _ := ph_card(t, &h, attention_message_card_id("inst_big"))
	testing.expect_value(t, c2.status, domain.CARD_STATUS_RESOLVED)
	_, found, _, _ := iface.attention_latest_actionable_message(&h.attention, PH_OWNER, "inst_big")
	testing.expect(t, !found, "no unread actionable message remains")
}

ph_fail_get_task :: proc(ctx: rawptr, id: domain.Task_ID) -> (domain.Task, bool, domain.Domain_Error) {
	return {}, false, domain.domain_error(.Internal_Error, "injected: database is locked")
}
ph_fail_card_get :: proc(ctx: rawptr, id: domain.Card_ID) -> (domain.Card, bool, domain.Domain_Error) {
	return {}, false, domain.domain_error(.Internal_Error, "injected: database is locked")
}
ph_fail_list_owners :: proc(ctx: rawptr) -> ([]domain.User_ID, domain.Domain_Error) {
	return nil, domain.domain_error(.Internal_Error, "injected: database is locked")
}
ph_fail_list_task_ids :: proc(ctx: rawptr, owner: domain.User_ID) -> ([]domain.Task_ID, domain.Domain_Error) {
	return nil, domain.domain_error(.Internal_Error, "injected: database is locked")
}

// Finding 3: a transient/internal read error must never retire a live card,
// and reconciliation must count (not swallow) query failures.
@(test)
test_review_fix_read_errors_never_retire_cards :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_fix_read_errors")
	defer ph_close(&h)
	ph_save_task(t, &h, ph_task("task_live", .In_Validation, "2026-10-01T02:00:00Z"))
	cid := attention_task_card_id("task_live")

	// Task lookup fails -> error returned, card untouched.
	real_get_task := h.tasks.get_task
	h.tasks.get_task = ph_fail_get_task
	ok, err := project_task_card(&h.svc, PH_OWNER, "task_live")
	h.tasks.get_task = real_get_task
	testing.expect(t, !ok, "projection reports the read failure")
	testing.expect_value(t, err.code, domain.Error_Code.Internal_Error)
	c, _ := ph_card(t, &h, cid)
	testing.expect_value(t, c.status, domain.CARD_STATUS_PENDING)

	// Card lookup fails -> error returned, nothing written.
	real_card_get := h.cards.get
	h.cards.get = ph_fail_card_get
	ok2, err2 := project_task_card(&h.svc, PH_OWNER, "task_live")
	h.cards.get = real_card_get
	testing.expect(t, !ok2, "projection reports the card read failure")
	testing.expect_value(t, err2.code, domain.Error_Code.Internal_Error)
	c2, _ := ph_card(t, &h, cid)
	testing.expect_value(t, c2.status, domain.CARD_STATUS_PENDING)

	// Reconciliation counts query failures instead of reporting success.
	real_owners := h.attention.list_owners
	h.attention.list_owners = ph_fail_list_owners
	stats := reconcile_attention(&h.svc)
	h.attention.list_owners = real_owners
	testing.expect_value(t, stats.failed, 1)
	testing.expect_value(t, stats.last_failure, "list owners")
	testing.expect_value(t, stats.last_failure_code, domain.Error_Code.Internal_Error)

	real_ids := h.attention.list_validation_task_ids
	h.attention.list_validation_task_ids = ph_fail_list_task_ids
	stats2 := reconcile_attention(&h.svc)
	h.attention.list_validation_task_ids = real_ids
	testing.expect(t, stats2.failed >= 1, "failed source query is counted")
	testing.expect_value(t, stats2.last_failure, "list validation tasks")
	c3, c3_ok, c3_err := iface.card_get(&h.cards, cid)
	testing.expectf(t, c3_ok, "card readable after reconcile: %v %s", c3_err.code, c3_err.message)
	testing.expect_value(t, c3.status, domain.CARD_STATUS_PENDING)
}
