package card

import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import content_service "odin_test:hub/service/content"
import taskv2 "odin_test:hub/service/taskv2"

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

// A blocked card pins the block it shows: once the agent blocks again (a new
// question in the same attempt), the old card's guard and a client Answer that
// names the old block are refused (review of task_18df5257ac412b52, finding 1).
@(test)
test_review_fix_blocked_card_pins_the_block :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_fix_pin_block")
	defer ph_close(&h)
	task := ph_task("task_q", .In_Validation, "2026-10-01T02:00:00Z")
	ph_save_task(t, &h, task)
	cid := attention_task_card_id("task_q")
	old_card, ok := ph_card(t, &h, cid)
	testing.expect(t, ok, "question card projected")
	old_block := attention_block_id(task.blocked_on_json)

	// The agent asks something newer in the same attempt.
	task.blocked_on_json = `{"kind":"human","reason":"And which port?","since_ms":2}`
	task.updated_at = "2026-10-01T03:00:00Z"
	_, _, _ = iface.taskchain_save_task(&h.tasks, task) // no notify: the deck still holds the old card
	guard_ok, _ := evaluate_guard(&h.svc, PH_OWNER, old_card)
	testing.expect(t, !guard_ok, "the old card's guard refuses the newer block")

	ph_save_task(t, &h, task) // re-projected for the new question
	_, acc_ok, acc_err := accept_card(&h.svc, contracts.Auth_Context{kind = .User_Token, user_id = string(PH_OWNER)}, cid, Card_Decision{note = "answer to the old question", expected_block = old_block})
	testing.expect(t, !acc_ok, "an Answer written for the old block is refused")
	testing.expect_value(t, acc_err.code, domain.Error_Code.Conflict)
}

// ---- task.review verdict on an agent-made card (G2) ---------------------------
// Accepting a task.review card used to always approve; it now honours
// args.verdict / summary / findings (default approve).

// ph_review_task saves a task awaiting the user's verdict (in_review, user
// approval required, no agent review roles) and returns its id.
ph_review_task :: proc(t: ^testing.T, h: ^Projector_Harness, id: string) -> domain.Task_ID {
	task := domain.Task{task_id = domain.Task_ID(id), chain_id = PH_CHAIN, owner_user_id = PH_OWNER, title = "vault:v2:task-title", priority = .P1, publish_state = .Published, kind = .Task, state = .In_Review, attempt_no = 1, requires_user_approval = true, brief_json = `{"goal":"g","review_roles":[]}`, created_at = "2026-10-01T00:00:00Z", updated_at = "2026-10-01T01:00:00Z"}
	_, ok, err := iface.taskchain_save_task(&h.tasks, task)
	testing.expectf(t, ok, "save review task: %s", err.message)
	// The engine folds state from events: seed one that puts attempt 1 in review.
	_, ev_ok, ev_err := taskv2.append_event(&h.tasks, &h.clock, task, taskv2.Actor{kind = taskv2.ACTOR_USER, id = string(PH_OWNER)}, taskv2.EV_MIGRATED, `{"from_status":"in_review","state":"in_review","published":true,"attempt_no":1}`)
	testing.expectf(t, ev_ok, "seed review event: %s", ev_err.message)
	return task.task_id
}

// ph_review_card creates an agent card carrying one task.review op whose args
// are `extra_args` (a JSON fragment, may be empty) plus task_id / attempt_no.
ph_review_card :: proc(h: ^Projector_Harness, task_id: domain.Task_ID, extra_args: string) -> (domain.Card, bool, domain.Domain_Error) {
	sep := "," if extra_args != "" else ""
	// strings.concatenate, not fmt: fmt reads `{` as an argument-index brace.
	ops := strings.concatenate({`[{"op":"task.review","label":"Review","args":{"task_id":"`, string(task_id), `","attempt_no":1`, sep, extra_args, `}}]`}, context.temp_allocator)
	return create_card(&h.svc, ph_auth(), Card_Input{title = "Review it", provider = "agent", operations_json = ops})
}

@(test)
test_card_task_review_request_changes_sends_task_back :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_review_request_changes")
	defer ph_close(&h)
	tid := ph_review_task(t, &h, "task_rc")
	card, ok, err := ph_review_card(&h, tid, `"verdict":"request_changes","summary":"rename x","findings":[{"path":"a.odin","line":1,"severity":"minor","text":"rename x"}]`)
	if !testing.expectf(t, ok, "create: %v %s", err.code, err.message) do return
	accepted, acc_ok, acc_err := accept_card(&h.svc, ph_auth(), card.card_id)
	if !testing.expectf(t, acc_ok, "accept: %v %s", acc_err.code, acc_err.message) do return
	testing.expect_value(t, accepted.status, domain.CARD_STATUS_ACCEPTED)
	task, _, _ := iface.taskchain_get_task(&h.tasks, tid)
	testing.expect_value(t, task.state, domain.Task_State.Ready) // back for rework, not done
	reviews, _ := iface.taskchain_list_reviews_by_task(&h.tasks, tid, PH_OWNER)
	testing.expect_value(t, len(reviews), 1)
	if len(reviews) == 1 {
		testing.expect_value(t, reviews[0].verdict, "request_changes")
		testing.expect(t, strings.contains(reviews[0].findings_json, "a.odin"), "findings reach the review")
	}
}

@(test)
test_card_task_review_without_verdict_approves :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_review_default_approve")
	defer ph_close(&h)
	tid := ph_review_task(t, &h, "task_ok")
	card, ok, err := ph_review_card(&h, tid, "")
	if !testing.expectf(t, ok, "create: %v %s", err.code, err.message) do return
	_, acc_ok, acc_err := accept_card(&h.svc, ph_auth(), card.card_id)
	if !testing.expectf(t, acc_ok, "accept: %v %s", acc_err.code, acc_err.message) do return
	task, _, _ := iface.taskchain_get_task(&h.tasks, tid)
	testing.expect_value(t, task.state, domain.Task_State.Done)
}

@(test)
test_card_task_review_request_changes_needs_summary :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_review_rc_no_summary")
	defer ph_close(&h)
	tid := ph_review_task(t, &h, "task_nosum")
	_, ok, err := ph_review_card(&h, tid, `"verdict":"request_changes","summary":"  "`)
	testing.expect(t, !ok, "create refuses request_changes without a summary")
	testing.expect_value(t, err.code, domain.Error_Code.Validation_Failed)
	testing.expect(t, strings.contains(err.message, "summary"), "the error names the summary")

	// A row that skipped create-time validation is still refused at accept,
	// and the task is untouched.
	bad := domain.Card{card_id = "crd_rc_nosum", owner_user_id = PH_OWNER, title = "Review it", provider = "agent", status = domain.CARD_STATUS_PENDING, scope = "global", source_refs_json = "[]", guard_json = "{}", operations_json = strings.concatenate({`[{"op":"task.review","args":{"task_id":"`, string(tid), `","attempt_no":1,"verdict":"request_changes"}}]`}, context.temp_allocator), created_at = "2026-10-01T01:00:00Z", updated_at = "2026-10-01T01:00:00Z"}
	_, sok, serr := iface.card_create(&h.cards, bad)
	if !testing.expectf(t, sok, "seed card: %s", serr.message) do return
	_, acc_ok, acc_err := accept_card(&h.svc, ph_auth(), bad.card_id)
	testing.expect(t, !acc_ok, "accept refuses request_changes without a summary")
	testing.expect_value(t, acc_err.code, domain.Error_Code.Validation_Failed)
	task, _, _ := iface.taskchain_get_task(&h.tasks, tid)
	testing.expect_value(t, task.state, domain.Task_State.In_Review)
}

@(test)
test_card_task_review_unknown_verdict_rejected :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_review_bad_verdict")
	defer ph_close(&h)
	tid := ph_review_task(t, &h, "task_bad")
	_, ok, err := ph_review_card(&h, tid, `"verdict":"lgtm"`)
	testing.expect(t, !ok, "create refuses an unknown verdict")
	testing.expect_value(t, err.code, domain.Error_Code.Validation_Failed)
	testing.expect(t, strings.contains(err.message, "lgtm"), "the error names the bad verdict")

	ok2, reason2 := validate_card_operations(`[{"op":"task.review","args":{"task_id":"task_bad","attempt_no":1,"verdict":""}}]`)
	testing.expect(t, !ok2 && strings.contains(reason2, "verdict"), "an empty verdict is refused")
	ok3, reason3 := validate_card_operations(`[{"op":"task.review","args":{"task_id":"task_bad","attempt_no":1,"verdict":"approve","findings":"nope"}}]`)
	testing.expect(t, !ok3 && strings.contains(reason3, "findings"), "findings must be a JSON array")
	task, _, _ := iface.taskchain_get_task(&h.tasks, tid)
	testing.expect_value(t, task.state, domain.Task_State.In_Review)
}
