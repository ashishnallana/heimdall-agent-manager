package card

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import content_service "odin_test:hub/service/content"
import taskchain_service "odin_test:hub/service/taskchain"

// Harness: a real migrated SQLite DB with the repositories the projector reads,
// a card service with the projector wired, and source services whose writes
// notify it (exactly as wiring.odin does).
Projector_Harness :: struct {
	path:           string,
	conn:           sqlite.Conn,
	card_impl:      sqlite.Card_Repo_SQLite,
	attention_impl: sqlite.Attention_Repo_SQLite,
	task_impl:      sqlite.Taskchain_Repo_SQLite,
	content_impl:   sqlite.Content_Repo_SQLite,
	agent_impl:     sqlite.Agent_Repo_SQLite,
	cards:          iface.Card_Repository,
	attention:      iface.Attention_Repository,
	tasks:          iface.Taskchain_Repository,
	content:        iface.Content_Repository,
	agents:         iface.Agent_Repository,
	clock:          platform.Clock,
	ids:            platform.ID_Generator,
	taskchains:     taskchain_service.Taskchain_Service,
	content_svc:    content_service.Content_Service,
	svc:            Card_Service,
	changed_kinds:  [dynamic]string,
}

PH_OWNER :: domain.User_ID("usr_attention")
PH_CHAIN :: domain.Task_Chain_ID("chain_att")

ph_open :: proc(t: ^testing.T, h: ^Projector_Harness, name: string) {
	h.path = fmt.aprintf("%s/.cache/heimdall-tests/%s.db", os.get_env("HOME", context.temp_allocator), name)
	os.remove(h.path)
	conn, ok, err := sqlite.open(h.path)
	testing.expectf(t, ok, "open db: %s", err.message)
	h.conn = conn
	mig_ok, mig_err := sqlite.run_migrations(&h.conn)
	testing.expectf(t, mig_ok, "migrations: %s", mig_err.message)
	h.cards = sqlite.new_card_repository(&h.card_impl, &h.conn)
	h.attention = sqlite.new_attention_repository(&h.attention_impl, &h.conn)
	h.tasks = sqlite.new_taskchain_repository(&h.task_impl, &h.conn)
	h.content = sqlite.new_content_repository(&h.content_impl, &h.conn)
	h.agents = sqlite.new_agent_repository(&h.agent_impl, &h.conn)
	h.clock = platform.real_clock()
	h.ids = platform.real_id_generator()
	h.taskchains = taskchain_service.Taskchain_Service{repo = &h.tasks, agents = &h.agents, clock = &h.clock, ids = &h.ids}
	h.content_svc = content_service.Content_Service{content = &h.content, agents = &h.agents, clock = &h.clock, ids = &h.ids}
	h.svc = new_card_service(cards = &h.cards, projects = nil, taskchains = &h.taskchains, content = &h.content_svc, clock = &h.clock, ids = &h.ids)
	init_attention(&h.svc, &h.attention)
	h.svc.card_changed = Card_Changed_Hook{ctx = rawptr(h), changed = proc(ctx: rawptr, owner, kind: string) {
		hh := (^Projector_Harness)(ctx)
		append(&hh.changed_kinds, strings.clone(kind))
	}}
	taskchain_service.set_attention_notifier(&h.taskchains, &h.svc.attention_notifier)
	content_service.set_attention_notifier(&h.content_svc, &h.svc.attention_notifier)
	_, chain_ok, _ := iface.taskchain_save_chain(&h.tasks, domain.Task_Chain{chain_id = PH_CHAIN, owner_user_id = PH_OWNER, title = "vault:v1:chain-title", status = .Active, publish_state = .Published, created_at = "2026-10-01T00:00:00Z", updated_at = "2026-10-01T00:00:00Z"})
	testing.expect(t, chain_ok, "seed chain")
}

ph_close :: proc(h: ^Projector_Harness) {
	sqlite.close(&h.conn)
	os.remove(h.path)
	delete(h.changed_kinds)
}

// ph_save_task writes through the taskchain service's save helper, so the
// projector is notified exactly as in production.
ph_save_task :: proc(t: ^testing.T, h: ^Projector_Harness, task: domain.Task) {
	_, ok, err := taskchain_service.save_task(&h.taskchains, task)
	testing.expectf(t, ok, "save task: %s", err.message)
}

// PH_USER_REVIEWER: the owner as explicit reviewer -- what --require-user-approval
// produces, and the only shape that awaits (and can be voted on by) the user.
PH_USER_REVIEWER :: `[{"type":"user","user_id":"usr_attention"}]`

ph_task :: proc(id: string, status: domain.Task_Status, updated_at: string, reviewers := PH_USER_REVIEWER) -> domain.Task {
	return domain.Task{task_id = domain.Task_ID(id), chain_id = PH_CHAIN, owner_user_id = PH_OWNER, title = "vault:v1:task-title", status = status, priority = .P1, publish_state = .Published, assignee_ref_json = "{}", reviewer_refs_json = reviewers, created_at = "2026-10-01T00:00:00Z", updated_at = updated_at}
}

ph_card :: proc(t: ^testing.T, h: ^Projector_Harness, id: domain.Card_ID) -> (domain.Card, bool) {
	c, ok, _ := iface.card_get(&h.cards, id)
	return c, ok
}

@(test)
test_projector_task_card_lifecycle :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_task_lifecycle")
	defer ph_close(&h)
	cid := attention_task_card_id("task_a")

	// Not in validation: no card.
	ph_save_task(t, &h, ph_task("task_a", .In_Progress, "2026-10-01T01:00:00Z"))
	_, exists := ph_card(t, &h, cid)
	testing.expect(t, !exists, "no card while the task is in progress")

	// Enters validation: a pending card with the attention fields.
	ph_save_task(t, &h, ph_task("task_a", .In_Validation, "2026-10-01T02:00:00Z"))
	c, ok := ph_card(t, &h, cid)
	testing.expect(t, ok, "card created on entering validation")
	testing.expect_value(t, c.status, domain.CARD_STATUS_PENDING)
	testing.expect_value(t, c.kind, domain.CARD_KIND_TASK)
	testing.expect_value(t, c.provider, domain.CARD_PROVIDER_TASK_VALIDATION)
	testing.expect_value(t, c.attention_since, "2026-10-01T02:00:00Z")
	testing.expect_value(t, c.source_marker, "in_validation|2026-10-01T02:00:00Z")
	testing.expect_value(t, c.title, "vault:v1:task-title") // ciphertext verbatim
	testing.expect_value(t, c.action_refs_json, `{"chain_id":"chain_att","task_id":"task_a"}`)
	testing.expect_value(t, c.ttl_at, "")
	testing.expect(t, strings.contains(c.details_json, `"priority":"p1"`), "details carry priority")
	testing.expect(t, strings.contains(c.details_json, `"excerpt":null`), "no comment yet")
	testing.expect(t, strings.contains(c.operations_json, `"op":"task.vote"`), "primary op is the vote")

	// Idempotent: re-projecting the same source writes nothing.
	changes_before := len(h.changed_kinds)
	updated_before := c.updated_at
	proj_ok, _ := project_task_card(&h.svc, PH_OWNER, "task_a")
	testing.expect(t, proj_ok, "re-projection ok")
	c2, _ := ph_card(t, &h, cid)
	testing.expect_value(t, c2.updated_at, updated_before)
	testing.expect_value(t, len(h.changed_kinds), changes_before)

	// A comment refreshes the excerpt without changing the marker.
	_, cm_ok, _ := taskchain_service.save_comment(&h.taskchains, domain.Task_Comment{comment_id = "cmt_1", task_id = "task_a", chain_id = PH_CHAIN, owner_user_id = PH_OWNER, body = "vault:v1:comment", created_at = "2026-10-01T02:30:00Z", updated_at = "2026-10-01T02:30:00Z"})
	testing.expect(t, cm_ok, "save comment")
	c3, _ := ph_card(t, &h, cid)
	testing.expect(t, strings.contains(c3.details_json, `"body":"vault:v1:comment"`), "excerpt is the latest comment, ciphertext verbatim")
	testing.expect_value(t, c3.source_marker, c.source_marker)

	// Leaves validation: retired to resolved.
	ph_save_task(t, &h, ph_task("task_a", .Completed, "2026-10-01T03:00:00Z"))
	c4, _ := ph_card(t, &h, cid)
	testing.expect_value(t, c4.status, domain.CARD_STATUS_RESOLVED)

	// Back in validation (a new review round): reactivated.
	ph_save_task(t, &h, ph_task("task_a", .In_Validation, "2026-10-01T04:00:00Z"))
	c5, _ := ph_card(t, &h, cid)
	testing.expect_value(t, c5.status, domain.CARD_STATUS_PENDING)
	testing.expect_value(t, c5.attention_since, "2026-10-01T04:00:00Z")
}

@(test)
test_projector_task_agent_reviewer_retires :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_task_reviewer")
	defer ph_close(&h)
	cid := attention_task_card_id("task_r")
	ph_save_task(t, &h, ph_task("task_r", .In_Validation, "2026-10-01T02:00:00Z"))
	c, _ := ph_card(t, &h, cid)
	testing.expect_value(t, c.status, domain.CARD_STATUS_PENDING)
	ph_save_task(t, &h, ph_task("task_r", .In_Validation, "2026-10-01T02:05:00Z", `[{"type":"agent_instance","agent_instance_id":"inst_rev"}]`))
	c2, _ := ph_card(t, &h, cid)
	testing.expect_value(t, c2.status, domain.CARD_STATUS_RESOLVED)
}

@(test)
test_projector_user_decision_precedence :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_precedence")
	defer ph_close(&h)
	cid := attention_task_card_id("task_p")
	ph_save_task(t, &h, ph_task("task_p", .In_Validation, "2026-10-01T02:00:00Z"))

	// The user discards: an unchanged source does not bring it back.
	_, _ = iface.card_update_status(&h.cards, cid, domain.CARD_STATUS_DISCARDED, "2026-10-01T02:01:00Z")
	_, _ = project_task_card(&h.svc, PH_OWNER, "task_p")
	c, _ := ph_card(t, &h, cid)
	testing.expect_value(t, c.status, domain.CARD_STATUS_DISCARDED)

	// A retire (source stops qualifying) leaves the user's decision alone.
	ph_save_task(t, &h, ph_task("task_p", .Completed, "2026-10-01T02:02:00Z"))
	c2, _ := ph_card(t, &h, cid)
	testing.expect_value(t, c2.status, domain.CARD_STATUS_DISCARDED)

	// A changed source (new review round) reactivates.
	ph_save_task(t, &h, ph_task("task_p", .In_Validation, "2026-10-01T03:00:00Z"))
	c3, _ := ph_card(t, &h, cid)
	testing.expect_value(t, c3.status, domain.CARD_STATUS_PENDING)

	// Snoozed: stays snoozed while the marker is unchanged ...
	_, snooze_ok, _ := snooze_card(&h.svc, contracts.Auth_Context{kind = .User_Token, user_id = string(PH_OWNER)}, cid, "2099-01-01T00:00:00Z")
	testing.expect(t, snooze_ok, "snooze")
	_, _ = project_task_card(&h.svc, PH_OWNER, "task_p")
	c4, _ := ph_card(t, &h, cid)
	testing.expect_value(t, c4.status, domain.CARD_STATUS_SNOOZED)
	testing.expect_value(t, c4.snooze_until, "2099-01-01T00:00:00Z")
	// ... and wakes early when it changes.
	ph_save_task(t, &h, ph_task("task_p", .In_Validation, "2026-10-01T05:00:00Z"))
	c5, _ := ph_card(t, &h, cid)
	testing.expect_value(t, c5.status, domain.CARD_STATUS_PENDING)
	testing.expect_value(t, c5.snooze_until, "")
}

// The accept <-> projector race, in both orders. accept_card executes the vote
// (which moves the task out of validation and notifies the projector) and then
// marks the card accepted; the projector may run before or after that write.
@(test)
test_projector_accept_interleaving :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_accept_race")
	defer ph_close(&h)

	// Order 1: projector retires first, then the accept lands -> accepted.
	cid1 := attention_task_card_id("task_x")
	ph_save_task(t, &h, ph_task("task_x", .In_Validation, "2026-10-01T02:00:00Z"))
	card1, _ := ph_card(t, &h, cid1)
	ph_save_task(t, &h, ph_task("task_x", .Completed, "2026-10-01T02:01:00Z"))
	mid, _ := ph_card(t, &h, cid1)
	testing.expect_value(t, mid.status, domain.CARD_STATUS_RESOLVED)
	acc, acc_ok, _ := mark_card_accepted(&h.svc, card1)
	testing.expect(t, acc_ok, "accept write")
	testing.expect_value(t, acc.status, domain.CARD_STATUS_ACCEPTED)
	// The accept did not clobber the projector's newer fields.
	testing.expect_value(t, acc.source_marker, mid.source_marker)

	// Order 2: the accept lands first, then the projector runs -> stays accepted.
	cid2 := attention_task_card_id("task_y")
	ph_save_task(t, &h, ph_task("task_y", .In_Validation, "2026-10-01T02:00:00Z"))
	card2, _ := ph_card(t, &h, cid2)
	_, _, _ = mark_card_accepted(&h.svc, card2)
	ph_save_task(t, &h, ph_task("task_y", .Completed, "2026-10-01T02:01:00Z"))
	after, _ := ph_card(t, &h, cid2)
	testing.expect_value(t, after.status, domain.CARD_STATUS_ACCEPTED)
}

// A stale writer cannot overwrite a row that moved underneath it.
@(test)
test_projector_compare_and_set_rejects_stale :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_cas")
	defer ph_close(&h)
	cid := attention_task_card_id("task_c")
	ph_save_task(t, &h, ph_task("task_c", .In_Validation, "2026-10-01T02:00:00Z"))
	stale, _ := ph_card(t, &h, cid)
	// Someone else moves the row (a newer projection).
	ph_save_task(t, &h, ph_task("task_c", .In_Validation, "2026-10-01T03:00:00Z"))
	write := stale
	write.title = "stale"
	changed, err := iface.attention_card_compare_and_set(&h.attention, write, stale.status, stale.source_marker)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect(t, !changed, "CAS with stale expectations must not write")
	now, _ := ph_card(t, &h, cid)
	testing.expect_value(t, now.source_marker, "in_validation|2026-10-01T03:00:00Z")

	// An out-of-order notification (old state) re-reads the source, so the
	// card still reflects the current task.
	_, _ = project_task_card(&h.svc, PH_OWNER, "task_c")
	again, _ := ph_card(t, &h, cid)
	testing.expect_value(t, again.source_marker, "in_validation|2026-10-01T03:00:00Z")
}

ph_conversation :: proc(t: ^testing.T, h: ^Projector_Harness, conv_id, instance_id: string) {
	_, ok, _ := iface.content_save_conversation(&h.content, domain.Chat_Conversation{conversation_id = conv_id, owner_user_id = PH_OWNER, agent_instance_id = instance_id, chain_id = string(PH_CHAIN), created_at = "2026-10-01T00:00:00Z", updated_at = "2026-10-01T00:00:00Z"})
	testing.expect(t, ok, "seed conversation")
}

ph_message :: proc(t: ^testing.T, h: ^Projector_Harness, id, conv_id, instance_id, direction, created_at, metadata: string) {
	_, ok, err := content_service.save_message(&h.content_svc, domain.Chat_Message{message_id = id, conversation_id = conv_id, owner_user_id = PH_OWNER, direction = direction, sender_agent_instance_id = instance_id, body = fmt.tprintf("vault:v1:%s", id), metadata_json = metadata, created_at = created_at})
	testing.expectf(t, ok, "save message: %s", err.message)
}

@(test)
test_projector_message_card_per_instance :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_messages")
	defer ph_close(&h)
	ph_conversation(t, &h, "chat_a", "inst_a")
	ph_conversation(t, &h, "chat_b", "inst_b")
	OPTS :: `{"options":["Yes","No"]}`

	// inst_a: two option messages, then a plain one -> one card, the LATEST
	// option message, the rest counted.
	ph_message(t, &h, "msg_a1", "chat_a", "inst_a", "agent_to_user", "2026-10-01T01:00:00Z", OPTS)
	ph_message(t, &h, "msg_a2", "chat_a", "inst_a", "agent_to_user", "2026-10-01T01:05:00Z", `{"options":["Keep it","Skip it"]}`)
	ph_message(t, &h, "msg_a3", "chat_a", "inst_a", "agent_to_user", "2026-10-01T01:10:00Z", "{}")
	// inst_b: only messages without options -> no card.
	ph_message(t, &h, "msg_b1", "chat_b", "inst_b", "agent_to_user", "2026-10-01T01:00:00Z", "{}")
	ph_message(t, &h, "msg_b2", "chat_b", "inst_b", "agent_to_user", "2026-10-01T01:01:00Z", `{"options":[]}`)

	a, a_ok := ph_card(t, &h, attention_message_card_id("inst_a"))
	testing.expect(t, a_ok, "card for inst_a")
	testing.expect_value(t, a.status, domain.CARD_STATUS_PENDING)
	testing.expect_value(t, a.kind, domain.CARD_KIND_MESSAGE)
	testing.expect_value(t, a.source_marker, "msg_a2")
	testing.expect_value(t, a.attention_since, "2026-10-01T01:05:00Z")
	testing.expect_value(t, a.title, "vault:v1:msg_a2")
	testing.expect(t, strings.contains(a.details_json, `"options":["Keep it","Skip it"]`), "options of the latest option message")
	testing.expect(t, strings.contains(a.details_json, `"other_unread":2`), "other unread counted")
	testing.expect_value(t, a.action_refs_json, `{"conversation_id":"chat_a","agent_instance_id":"inst_a","message_id":"msg_a2"}`)
	_, b_ok := ph_card(t, &h, attention_message_card_id("inst_b"))
	testing.expect(t, !b_ok, "no card without options")

	// A message card cannot be accepted.
	_, acc_ok, acc_err := accept_card(&h.svc, contracts.Auth_Context{kind = .User_Token, user_id = string(PH_OWNER)}, a.card_id)
	testing.expect(t, !acc_ok, "message card accept refused")
	testing.expect_value(t, acc_err.code, domain.Error_Code.Conflict)

	// The user replies -> answered -> resolved.
	ph_message(t, &h, "msg_u1", "chat_a", "inst_a", "user_to_agent", "2026-10-01T01:20:00Z", "{}")
	a2, _ := ph_card(t, &h, attention_message_card_id("inst_a"))
	testing.expect_value(t, a2.status, domain.CARD_STATUS_RESOLVED)

	// A new question -> pending again with the new marker.
	ph_message(t, &h, "msg_a4", "chat_a", "inst_a", "agent_to_user", "2026-10-01T01:30:00Z", OPTS)
	a3, _ := ph_card(t, &h, attention_message_card_id("inst_a"))
	testing.expect_value(t, a3.status, domain.CARD_STATUS_PENDING)
	testing.expect_value(t, a3.source_marker, "msg_a4")

	// Reading the conversation retires it.
	_, read_ok, read_err := content_service.mark_read(&h.content_svc, contracts.Auth_Context{kind = .User_Token, user_id = string(PH_OWNER)}, "chat_a")
	testing.expectf(t, read_ok, "mark read: %s", read_err.message)
	a4, _ := ph_card(t, &h, attention_message_card_id("inst_a"))
	testing.expect_value(t, a4.status, domain.CARD_STATUS_RESOLVED)
}

@(test)
test_projector_reconciliation_repairs_missed_notifications :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_reconcile")
	defer ph_close(&h)
	ph_conversation(t, &h, "chat_r", "inst_r")

	// Sources written straight to the repositories: no notification at all.
	_, _, _ = iface.taskchain_save_task(&h.tasks, ph_task("task_missed", .In_Validation, "2026-10-01T02:00:00Z"))
	_, _, _ = iface.content_save_message(&h.content, domain.Chat_Message{message_id = "msg_r1", conversation_id = "chat_r", owner_user_id = PH_OWNER, direction = "agent_to_user", sender_agent_instance_id = "inst_r", body = "q", metadata_json = `{"options":["A"]}`, created_at = "2026-10-01T02:00:00Z"})
	// A stale live card whose task left validation unnoticed.
	ph_save_task(t, &h, ph_task("task_stale", .In_Validation, "2026-10-01T02:00:00Z"))
	_, _, _ = iface.taskchain_save_task(&h.tasks, ph_task("task_stale", .Completed, "2026-10-01T02:10:00Z"))

	stats := reconcile_attention(&h.svc)
	testing.expect_value(t, stats.failed, 0)
	missed, missed_ok := ph_card(t, &h, attention_task_card_id("task_missed"))
	testing.expect(t, missed_ok && missed.status == domain.CARD_STATUS_PENDING, "missing task card created")
	msg, msg_ok := ph_card(t, &h, attention_message_card_id("inst_r"))
	testing.expect(t, msg_ok && msg.status == domain.CARD_STATUS_PENDING, "missing message card created")
	stale, _ := ph_card(t, &h, attention_task_card_id("task_stale"))
	testing.expect_value(t, stale.status, domain.CARD_STATUS_RESOLVED)

	// Idempotent: a second sweep changes nothing.
	before := len(h.changed_kinds)
	_ = reconcile_attention(&h.svc)
	testing.expect_value(t, len(h.changed_kinds), before)
}

// Another owner's notification cannot touch this owner's card.
@(test)
test_projector_owner_isolation :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_owner")
	defer ph_close(&h)
	ph_save_task(t, &h, ph_task("task_o", .In_Validation, "2026-10-01T02:00:00Z"))
	ok, err := project_task_card(&h.svc, "usr_other", "task_o")
	// The other owner sees "not qualifying" and the existing card is not theirs.
	testing.expect(t, !ok, "foreign projection refused")
	testing.expect_value(t, err.code, domain.Error_Code.Forbidden)
	c, _ := ph_card(t, &h, attention_task_card_id("task_o"))
	testing.expect_value(t, c.status, domain.CARD_STATUS_PENDING)
}

// Third interleaving: the source moves to a NEW state (another review round)
// between the accept's read and its write. The reactivated card must stand --
// the user approved the old state, not the new one.
@(test)
test_projector_accept_does_not_swallow_new_round :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_accept_new_round")
	defer ph_close(&h)
	cid := attention_task_card_id("task_z")
	ph_save_task(t, &h, ph_task("task_z", .In_Validation, "2026-10-01T02:00:00Z"))
	read_by_accept, _ := ph_card(t, &h, cid)
	// Meanwhile: the round ends and a new one starts.
	ph_save_task(t, &h, ph_task("task_z", .Completed, "2026-10-01T02:01:00Z"))
	ph_save_task(t, &h, ph_task("task_z", .In_Validation, "2026-10-01T03:00:00Z"))
	got, ok, _ := mark_card_accepted(&h.svc, read_by_accept)
	testing.expect(t, ok, "accept returns the current card")
	testing.expect_value(t, got.status, domain.CARD_STATUS_PENDING)
	now, _ := ph_card(t, &h, cid)
	testing.expect_value(t, now.status, domain.CARD_STATUS_PENDING)
	testing.expect_value(t, now.source_marker, "in_validation|2026-10-01T03:00:00Z")
}
