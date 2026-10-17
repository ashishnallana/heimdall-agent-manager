package card

import "core:fmt"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"

ph_ago :: proc(d: time.Duration) -> string {
	return platform.format_rfc3339_utc(time.time_add(time.now(), -d))
}

ph_auth :: proc(user: domain.User_ID = PH_OWNER) -> contracts.Auth_Context {
	return contracts.Auth_Context{kind = .User_Token, user_id = string(user)}
}

// Seeds: tasks aged 2h, 30h and 10d; one question message aged 3h; and another
// owner's task that must never show up.
ph_seed_attention :: proc(t: ^testing.T, h: ^Projector_Harness) {
	ph_save_task(t, h, ph_task("task_2h", .In_Validation, ph_ago(2 * time.Hour)))
	ph_save_task(t, h, ph_task("task_30h", .In_Validation, ph_ago(30 * time.Hour)))
	ph_save_task(t, h, ph_task("task_10d", .In_Validation, ph_ago(10 * 24 * time.Hour)))
	ph_conversation(t, h, "chat_q", "inst_q")
	ph_message(t, h, "msg_q", "chat_q", "inst_q", "agent_to_user", ph_ago(3 * time.Hour), `{"options":["Yes","No"]}`)
	other := ph_task("task_other", .In_Validation, ph_ago(1 * time.Hour), `[{"type":"user","user_id":"usr_other"}]`)
	other.owner_user_id = "usr_other"
	ph_save_task(t, h, other)
}

@(test)
test_attention_ranges_counts_and_order :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_api_ranges")
	defer ph_close(&h)
	ph_seed_attention(t, &h)

	// Default range is 24h: task_2h + the message; task_30h and task_10d are older.
	r, err := list_attention(&h.svc, ph_auth(), "", "", true)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, r.since, "24h")
	testing.expect_value(t, r.counts.task, 1)
	testing.expect_value(t, r.counts.message, 1)
	testing.expect_value(t, r.counts.older, 2)
	testing.expect_value(t, len(r.items), 2)

	// 7d: three items. Order is urgency desc then oldest first: the 30h task is
	// an error (>24h), the 2h task a warn, the 3h message a warn (>1h); among the
	// two warns the older (message, 3h) comes first.
	r7, _ := list_attention(&h.svc, ph_auth(), "7d", "", true)
	testing.expect_value(t, r7.counts.task, 2)
	testing.expect_value(t, r7.counts.older, 1)
	testing.expect_value(t, len(r7.items), 3)
	if len(r7.items) == 3 {
		testing.expect_value(t, string(r7.items[0].card.card_id), "crd_task_task_30h")
		testing.expect_value(t, r7.items[0].urgency, ATTENTION_URGENCY_ERROR)
		testing.expect_value(t, string(r7.items[1].card.card_id), "crd_msg_inst_q")
		testing.expect_value(t, r7.items[1].urgency, ATTENTION_URGENCY_WARN)
		testing.expect_value(t, r7.items[1].reason, ATTENTION_REASON_QUESTION)
		testing.expect_value(t, r7.items[1].primary_op, "")
		testing.expect_value(t, string(r7.items[2].card.card_id), "crd_task_task_2h")
		testing.expect_value(t, r7.items[2].primary_op, "task.answer")
		testing.expect_value(t, r7.items[2].reason, ATTENTION_REASON_AWAITING_REVIEW)
		// Context resolved in batch: the chain title (ciphertext, verbatim).
		testing.expect_value(t, r7.items[2].ctx.chain_title, "vault:v1:chain-title")
		testing.expect_value(t, r7.items[1].ctx.chain_title, "vault:v1:chain-title")
	}

	// All time: everything, nothing older. 6h: only the 2h task and the 3h message.
	ra, _ := list_attention(&h.svc, ph_auth(), "all", "", true)
	testing.expect_value(t, len(ra.items), 4)
	testing.expect_value(t, ra.counts.older, 0)
	r6, _ := list_attention(&h.svc, ph_auth(), "6h", "", true)
	testing.expect_value(t, r6.counts.task + r6.counts.message, 2)

	// The kind filter narrows items, never counts.
	rk, _ := list_attention(&h.svc, ph_auth(), "all", "message", true)
	testing.expect_value(t, len(rk.items), 1)
	testing.expect_value(t, rk.counts.task, 3)

	// Summary: counts only.
	rs, _ := list_attention(&h.svc, ph_auth(), "all", "", false)
	testing.expect_value(t, len(rs.items), 0)
	testing.expect_value(t, rs.counts.task + rs.counts.message, 4)

	// Owner isolation: the other user sees only their own task.
	ro, _ := list_attention(&h.svc, ph_auth("usr_other"), "all", "", true)
	testing.expect_value(t, len(ro.items), 1)
	testing.expect_value(t, ro.counts.message, 0)

	// Validation.
	_, bad := list_attention(&h.svc, ph_auth(), "3h", "", true)
	testing.expect_value(t, bad.code, domain.Error_Code.Validation_Failed)
	_, bad_kind := list_attention(&h.svc, ph_auth(), "24h", "shell", true)
	_, snoozed_ok := list_attention(&h.svc, ph_auth(), "24h", ATTENTION_FILTER_SNOOZED, true)
	testing.expect_value(t, snoozed_ok.code, domain.Error_Code.None)
	testing.expect_value(t, bad_kind.code, domain.Error_Code.Validation_Failed)
}

@(test)
test_attention_snoozed_and_resolved_are_hidden :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_api_snooze")
	defer ph_close(&h)
	ph_seed_attention(t, &h)

	_, _, _ = snooze_card(&h.svc, ph_auth(), attention_task_card_id("task_2h"), "2099-01-01T00:00:00Z")
	r, _ := list_attention(&h.svc, ph_auth(), "all", "task", true)
	testing.expect_value(t, r.counts.task, 2)
	testing.expect_value(t, r.counts.snoozed, 1)
	for item in r.items do testing.expect(t, !item.snoozed, "the task filter returns live cards only")

	// The Snoozed tab: range-independent (even 6h shows it), flagged, after live items.
	rs, _ := list_attention(&h.svc, ph_auth(), "6h", ATTENTION_FILTER_SNOOZED, true)
	testing.expect_value(t, rs.counts.snoozed, 1)
	testing.expect_value(t, len(rs.items), 1)
	if len(rs.items) == 1 {
		testing.expect_value(t, string(rs.items[0].card.card_id), "crd_task_task_2h")
		testing.expect(t, rs.items[0].snoozed, "snoozed item is flagged")
		testing.expect_value(t, rs.items[0].card.snooze_until, "2099-01-01T00:00:00Z")
		testing.expect_value(t, rs.items[0].ctx.chain_title, "vault:v1:chain-title")
	}
	rall, _ := list_attention(&h.svc, ph_auth(), "all", "", true)
	testing.expect_value(t, len(rall.items), 4)
	if len(rall.items) == 4 do testing.expect(t, rall.items[3].snoozed, "snoozed items come last")

	// Acting on a snoozed card works in place (no wake step): approving it
	// retires it from the Snoozed tab.
	_, accepted, _ := accept_card(&h.svc, ph_auth(), attention_task_card_id("task_2h"))
	testing.expect(t, accepted, "a snoozed card accepts like a pending one")
	ra2, _ := list_attention(&h.svc, ph_auth(), "all", ATTENTION_FILTER_SNOOZED, true)
	testing.expect_value(t, ra2.counts.snoozed, 0)
	testing.expect_value(t, len(ra2.items), 0)
	// An expired snooze is live again.
	_, _, _ = snooze_card(&h.svc, ph_auth(), attention_task_card_id("task_30h"), "2000-01-01T00:00:00Z")
	r2, _ := list_attention(&h.svc, ph_auth(), "all", "task", true)
	testing.expect_value(t, r2.counts.task, 2)
	// Resolved (task left validation) disappears.
	ph_save_task(t, &h, ph_task("task_10d", .Completed, ph_ago(time.Minute)))
	r3, _ := list_attention(&h.svc, ph_auth(), "all", "task", true)
	testing.expect_value(t, r3.counts.task, 1)
	testing.expect_value(t, len(r3.items), 1)
}

@(test)
test_attention_caps_items_but_not_counts :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_api_cap")
	defer ph_close(&h)
	total := ATTENTION_ITEMS_PER_KIND + 3
	for i in 0 ..< total {
		ph_save_task(t, &h, ph_task(fmt.tprintf("task_%03d", i), .In_Validation, ph_ago(time.Duration(i + 1) * time.Minute)))
	}
	r, _ := list_attention(&h.svc, ph_auth(), "24h", "", true)
	testing.expect_value(t, r.counts.task, total)
	testing.expect_value(t, len(r.items), ATTENTION_ITEMS_PER_KIND)
}

// Every card write path reaches the change hook that drives attention_changed.
@(test)
test_attention_every_card_write_notifies :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_api_events")
	defer ph_close(&h)
	count :: proc(h: ^Projector_Harness) -> int { return len(h.changed_kinds) }

	before := count(&h)
	created, ok, _ := create_card(&h.svc, ph_auth(), Card_Input{title = "Generic approval", provider = "agent", operations_json = "[]"})
	testing.expect(t, ok, "create")
	testing.expect(t, count(&h) > before, "create notifies")
	testing.expect_value(t, h.changed_kinds[len(h.changed_kinds) - 1], domain.CARD_KIND_APPROVAL)

	before = count(&h)
	_, _, _ = update_card(&h.svc, ph_auth(), created.card_id, Card_Update_Input{title = "Renamed", has_title = true})
	testing.expect(t, count(&h) > before, "update notifies")

	before = count(&h)
	_, _, _ = snooze_card(&h.svc, ph_auth(), created.card_id, "2099-01-01T00:00:00Z")
	testing.expect(t, count(&h) > before, "snooze notifies")

	before = count(&h)
	_, _, _ = discard_card(&h.svc, ph_auth(), created.card_id)
	testing.expect(t, count(&h) > before, "discard notifies")

	before = count(&h)
	_, _ = delete_card(&h.svc, ph_auth(), created.card_id)
	testing.expect(t, count(&h) > before, "delete notifies")

	second, _, _ := create_card(&h.svc, ph_auth(), Card_Input{title = "Accept me", provider = "agent", operations_json = "[]"})
	before = count(&h)
	_, acc_ok, _ := accept_card(&h.svc, ph_auth(), second.card_id)
	testing.expect(t, acc_ok, "accept")
	testing.expect(t, count(&h) > before, "accept notifies")

	// Projection writes notify too (task kind).
	before = count(&h)
	ph_save_task(t, &h, ph_task("task_ev", .In_Validation, ph_ago(time.Minute)))
	testing.expect(t, count(&h) > before, "projection notifies")
	testing.expect_value(t, h.changed_kinds[len(h.changed_kinds) - 1], domain.CARD_KIND_TASK)
}
