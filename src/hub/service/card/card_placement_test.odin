package card

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import taskv2 "odin_test:hub/service/taskv2"

@(test)
test_placement_card_groups_preserves_attention_and_reconciles :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "placement_card_groups")
	defer ph_close(&h)
	task := ph_task("task_place_card", .In_Validation, "2026-10-22T09:00:00Z")
	task.attempt_no = 2
	ph_save_task(t, &h, task)
	question, qfound, _ := iface.card_get(&h.cards, attention_task_card_id(task.task_id))
	if !testing.expect(t, qfound, "existing question card") do return
	body := `{"schema_version":1,"failures":[{"phase":"review","agent_id":"agt_a","role":"named","bridge_id":"br_off","source":"fleet","reason":"bridge_offline","message":"offline reviewer A","configuration":"config_a","fingerprint":"fp_a"},{"phase":"review","agent_id":"agt_b","role":"security","bridge_id":"br_missing","source":"fleet","reason":"bridge_missing","message":"missing reviewer B","configuration":"config_b","fingerprint":"fp_b"}]}`
	_, _ = taskv2.save_facet_verbatim(&h.engine, task, task.attempt_no, taskv2.FACET_PLACEMENT, body, taskv2.FACET_WRITER_HUB)
	projected, err := project_task_card(&h.svc, PH_OWNER, task.task_id)
	if !testing.expect(t, projected, err.message) do return
	id := attention_placement_card_id(task)
	card, found, _ := iface.card_get(&h.cards, id)
	if !testing.expect(t, found, "separate placement card") do return
	testing.expect_value(t, string(id), "crd_placement_task_place_card_2")
	testing.expect_value(t, placement_task_id_from_card(id), task.task_id)
	testing.expect_value(t, card.operations_json, "[]")
	for part in ([]string{"agt_a", "agt_b", "br_off", "br_missing", "security", "fp_a", "fp_b", "All tickets using this fleet", "change_reviewer", "configure_fleet"}) {
		testing.expect(t, strings.contains(card.details_json, part), part)
	}
	still_question, _, _ := iface.card_get(&h.cards, question.card_id)
	testing.expect_value(t, still_question.source_marker, question.source_marker)
	testing.expect_value(t, still_question.status, question.status)
	result, aerr := list_attention(&h.svc, ph_auth(), "all", "task", true)
	testing.expect_value(t, aerr.code, domain.Error_Code.None)
	testing.expect_value(t, result.counts.task, 2)
	testing.expect_value(t, attention_item_for(card, {}).reason, "placement")
	// Snooze is stable across identical projection; a changed group wakes it.
	_, _, _ = update_card(&h.svc, ph_auth(), id, Card_Update_Input{has_status = true, status = domain.CARD_STATUS_SNOOZED, has_snooze_until = true, snooze_until = "2099-01-01T00:00:00Z"})
	_, _ = project_task_card(&h.svc, PH_OWNER, task.task_id)
	snoozed, _, _ := iface.card_get(&h.cards, id)
	testing.expect_value(t, snoozed.status, domain.CARD_STATUS_SNOOZED)
	changed_body, _ := strings.replace_all(body, "fp_b", "fp_new", context.temp_allocator)
	_, _ = taskv2.save_facet_verbatim(&h.engine, task, task.attempt_no, taskv2.FACET_PLACEMENT, changed_body, taskv2.FACET_WRITER_HUB)
	_, _ = project_task_card(&h.svc, PH_OWNER, task.task_id)
	changed, _, _ := iface.card_get(&h.cards, id)
	testing.expect_value(t, changed.status, domain.CARD_STATUS_PENDING)
	valid, _ := evaluate_guard(&h.svc, PH_OWNER, card)
	testing.expect(t, !valid, "old group guard invalidated")
	_, _, uerr := update_card(&h.svc, ph_auth(), id, Card_Update_Input{has_operations = true, operations_json = `[{"op":"task.answer","args":{"task_id":"forged"}}]`})
	testing.expect_value(t, uerr.code, domain.Error_Code.Conflict)
	// Attempt advance retires the old group even when it still has history.
	task.attempt_no += 1
	ph_save_task(t, &h, task)
	retired, _, _ := iface.card_get(&h.cards, id)
	testing.expect_value(t, retired.status, domain.CARD_STATUS_RESOLVED)
	_, _ = taskv2.save_facet_verbatim(&h.engine, task, task.attempt_no, taskv2.FACET_PLACEMENT, body, taskv2.FACET_WRITER_HUB)
	_, _ = project_task_card(&h.svc, PH_OWNER, task.task_id)
	next_id := attention_placement_card_id(task)
	next, next_found, _ := iface.card_get(&h.cards, next_id)
	testing.expect(t, next_found && next.status == domain.CARD_STATUS_PENDING, "new attempt gets its own card")
	_, _ = taskv2.save_facet_verbatim(&h.engine, task, task.attempt_no, taskv2.FACET_PLACEMENT, `{"schema_version":1,"failures":[]}`, taskv2.FACET_WRITER_HUB)
	_, _ = project_task_card(&h.svc, PH_OWNER, task.task_id)
	next, _, _ = iface.card_get(&h.cards, next_id)
	testing.expect_value(t, next.status, domain.CARD_STATUS_RESOLVED)
	still_question, _, _ = iface.card_get(&h.cards, question.card_id)
	testing.expect_value(t, still_question.status, domain.CARD_STATUS_PENDING)
}

@(test)
test_placement_card_reconciliation_discovers_ready_worker :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "placement_card_repair")
	defer ph_close(&h)
	task := ph_task("task_ready_place", .In_Progress, "2026-10-22T09:00:00Z")
	task.state = .Ready
	ph_save_task(t, &h, task)
	_, _ = taskv2.save_facet_verbatim(&h.engine, task, 0, taskv2.FACET_PLACEMENT, `{"schema_version":1,"failures":[{"phase":"work","role":"worker","agent_id":"agt_w","bridge_id":"br_off","reason":"bridge_offline","fingerprint":"fp","configuration":"cfg"}]}`, taskv2.FACET_WRITER_HUB)
	stats := reconcile_attention(&h.svc)
	testing.expect_value(t, stats.failed, 0)
	card, found, _ := iface.card_get(&h.cards, attention_placement_card_id(task))
	testing.expect(t, found && strings.contains(card.details_json, "This ticket"), "periodic reconciliation discovers unnotified worker failure")
	_, question_found, _ := iface.card_get(&h.cards, attention_task_card_id(task.task_id))
	testing.expect(t, !question_found, "placement does not invent a question")
}
