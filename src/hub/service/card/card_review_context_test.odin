package card

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import taskv2 "odin_test:hub/service/taskv2"

// A card verdict carries the same review context as the task review UI: the
// card's attempt, that attempt's submitted head and the current requirements
// revision. Before, a card sent none of them, so once a task's requirements had
// been amended (revision > 1) every Approve / Request changes from the
// Needs-action card failed with "review context is stale; reload the submitted
// attempt and requirements" (taskv2.requirements_review_guard), while the task UI
// worked. With revision 1 the zeros passed, and a card for an older attempt could
// approve a newer one.

// ctx_review_task saves an in-review task on `attempt` whose requirements were
// amended to `revision` before that attempt was submitted with `head`.
@(private = "file")
ctx_review_task :: proc(t: ^testing.T, h: ^Projector_Harness, id: string, attempt: int, revision: int, head: string) -> domain.Task_ID {
	task := domain.Task{task_id = domain.Task_ID(id), chain_id = PH_CHAIN, owner_user_id = PH_OWNER, title = "vault:v2:task-title", priority = .P1, publish_state = .Published, kind = .Task, state = .In_Review, attempt_no = attempt, requires_user_approval = true, brief_json = `{"goal":"g","review_roles":[]}`, created_at = "2026-10-01T00:00:00Z", updated_at = "2026-10-01T01:00:00Z"}
	_, ok, err := iface.taskchain_save_task(&h.tasks, task)
	testing.expectf(t, ok, "save review task: %s", err.message)
	user := taskv2.Actor{kind = taskv2.ACTOR_USER, id = string(PH_OWNER)}
	a := strings.concatenate({`{"from_status":"in_review","state":"in_review","published":true,"attempt_no":`, itoa(attempt), `}`}, context.temp_allocator)
	_, ev_ok, ev_err := taskv2.append_event(&h.tasks, &h.clock, task, user, taskv2.EV_MIGRATED, a)
	testing.expectf(t, ev_ok, "seed review event: %s", ev_err.message)
	for r in 2 ..= revision {
		_, rq_ok, rq_err := taskv2.append_event(&h.tasks, &h.clock, task, user, taskv2.EV_REQUIREMENTS_CHANGED, strings.concatenate({`{"revision":`, itoa(r), `}`}, context.temp_allocator))
		testing.expectf(t, rq_ok, "seed requirements change: %s", rq_err.message)
	}
	submitted := strings.concatenate({`{"attempt_no":`, itoa(attempt), `,"requirements_revision":`, itoa(revision), `,"head":"`, head, `"}`}, context.temp_allocator)
	_, sb_ok, sb_err := taskv2.append_event(&h.tasks, &h.clock, task, taskv2.Actor{kind = taskv2.ACTOR_AGENT, id = "inst_worker"}, taskv2.EV_SUBMITTED, submitted)
	testing.expectf(t, sb_ok, "seed submission: %s", sb_err.message)
	ph_save_task(t, h, task) // through the service, so the review card is projected
	return task.task_id
}

@(private = "file")
itoa :: proc(n: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_int(&b, n)
	return strings.to_string(b)
}

@(test)
test_card_approve_after_requirements_amended :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_ctx_amended_approve")
	defer ph_close(&h)
	tid := ctx_review_task(t, &h, "task_amended", 1, 3, "abc123")
	card, ok, err := ph_review_card(&h, tid, "")
	if !testing.expectf(t, ok, "create: %v %s", err.code, err.message) do return
	_, acc_ok, acc_err := accept_card(&h.svc, ph_auth(), card.card_id)
	if !testing.expectf(t, acc_ok, "approve from the card after requirements rev 3: %v %s", acc_err.code, acc_err.message) do return
	task, _, _ := iface.taskchain_get_task(&h.tasks, tid)
	testing.expect_value(t, task.state, domain.Task_State.Done)
}

@(test)
test_card_request_changes_after_requirements_amended :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_ctx_amended_reject")
	defer ph_close(&h)
	tid := ctx_review_task(t, &h, "task_amended_rc", 1, 2, "def456")
	cid := attention_task_card_id(tid)
	if _, projected := ph_card(t, &h, cid); !testing.expect(t, projected, "the review card is projected") do return
	_, rej_ok, rej_err := reject_card(&h.svc, ph_auth(), cid, Card_Decision{summary = "rename x"})
	if !testing.expectf(t, rej_ok, "request changes from the card after requirements rev 2: %v %s", rej_err.code, rej_err.message) do return
	task, _, _ := iface.taskchain_get_task(&h.tasks, tid)
	testing.expect_value(t, task.state, domain.Task_State.Ready)
}

@(test)
test_card_for_superseded_attempt_never_approves_the_new_one :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_ctx_superseded")
	defer ph_close(&h)
	// Attempt 2 is in review (requirements never amended); the card was raised for attempt 1.
	tid := ctx_review_task(t, &h, "task_superseded", 2, 1, "new999")
	card, ok, err := ph_review_card(&h, tid, "")
	if !testing.expectf(t, ok, "create: %v %s", err.code, err.message) do return
	_, acc_ok, _ := accept_card(&h.svc, ph_auth(), card.card_id)
	testing.expect(t, !acc_ok, "a card for attempt 1 is refused while attempt 2 is in review")
	task, _, _ := iface.taskchain_get_task(&h.tasks, tid)
	testing.expect_value(t, task.state, domain.Task_State.In_Review)
	reviews, _ := iface.taskchain_list_reviews_by_task(&h.tasks, tid, PH_OWNER)
	testing.expect_value(t, len(reviews), 0)
}
