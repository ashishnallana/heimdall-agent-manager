package hub_cards_repo_test

import "core:fmt"
import "core:testing"
import "core:math"
import "core:os"
import domain "odin_test:hub/domain"
import sqlite "odin_test:hub/repository/sqlite"

check :: proc(ok: bool, msg: string) {
	if ok do return
	fmt.eprintln("FAIL:", msg)
	os.exit(1)
}

@(test)
test_hub_cards_repo_test :: proc(t: ^testing.T) {
	_ = t
	main()
}

main :: proc() {
	db_path := "/tmp/cards_repo_test.db"
	_ = os.remove(db_path)
	defer _ = os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	check(open_ok, fmt.tprintf("open db: %s", open_err.message))
	defer sqlite.close(&conn)

	// Test 1: Full migration run (includes 034_cards.sql)
	mig_ok, mig_err := sqlite.run_migrations(&conn, "src/hub/repository/sqlite/migrations")
	check(mig_ok, fmt.tprintf("run_migrations: %s", mig_err.message))

	// Test 2: Idempotency of run_migrations
	mig_ok2, mig_err2 := sqlite.run_migrations(&conn, "src/hub/repository/sqlite/migrations")
	check(mig_ok2, fmt.tprintf("run_migrations 2nd run: %s", mig_err2.message))

	// Test 3: Idempotency of upgrade_cards_schema
	up_ok := sqlite.upgrade_cards_schema(&conn)
	check(up_ok, "upgrade_cards_schema should be idempotent")

	repo_impl: sqlite.Card_Repo_SQLite
	repo := sqlite.new_card_repository(&repo_impl, &conn)

	// Test 4: Create and Get card with all fields populated
	card1 := domain.Card{
		card_id = domain.Card_ID("crd_test_1"),
		owner_user_id = domain.User_ID("usr_test_1"),
		project_id = domain.Project_ID("proj_alpha"),
		title = "Merge duplicate memory proposal",
		rationale = "Curator detected identical fact in session history",
		scope = domain.CARD_SCOPE_MEMORY,
		provider = domain.CARD_PROVIDER_MEMORY_PROPOSAL,
		confidence = 0.95,
		source_refs_json = "[\"mem_prop_101\"]",
		status = domain.CARD_STATUS_PENDING,
		operations_json = "[{\"op\":\"memory.create\",\"args\":{\"title\":\"Docker port convention\"}}]",
		guard_json = "{\"memory_proposal_id\":\"mem_prop_101\",\"expected_status\":\"pending\"}",
		snooze_until = "2026-09-16T12:00:00Z",
		ttl_at = "2026-09-20T12:00:00Z",
		created_at = "2026-09-15T00:00:00Z",
		updated_at = "2026-09-15T00:00:00Z",
	}

	saved1, ok_save1, err_save1 := repo.create(repo.ctx, card1)
	check(ok_save1, fmt.tprintf("create card1: %s", err_save1.message))
	check(saved1.card_id == domain.Card_ID("crd_test_1"), "saved1 card_id mismatch")
	check(saved1.title == "Merge duplicate memory proposal", "saved1 title mismatch")

	got1, ok_get1, err_get1 := repo.get(repo.ctx, domain.Card_ID("crd_test_1"))
	check(ok_get1, fmt.tprintf("get card1: %s", err_get1.message))
	check(got1.card_id == domain.Card_ID("crd_test_1"), "id mismatch")
	check(got1.owner_user_id == domain.User_ID("usr_test_1"), "owner mismatch")
	check(got1.project_id == domain.Project_ID("proj_alpha"), "project mismatch")
	check(got1.title == "Merge duplicate memory proposal", "title mismatch")
	check(got1.rationale == "Curator detected identical fact in session history", "rationale mismatch")
	check(got1.scope == "memory", "scope mismatch")
	check(got1.provider == "memory_proposal", "provider mismatch")
	check(math.abs(got1.confidence - 0.95) < 0.001, "confidence mismatch")
	check(got1.source_refs_json == "[\"mem_prop_101\"]", "source_refs_json mismatch")
	check(got1.status == "pending", "status mismatch")
	check(got1.operations_json == "[{\"op\":\"memory.create\",\"args\":{\"title\":\"Docker port convention\"}}]", "operations_json mismatch")
	check(got1.guard_json == "{\"memory_proposal_id\":\"mem_prop_101\",\"expected_status\":\"pending\"}", "guard_json mismatch")
	check(got1.snooze_until == "2026-09-16T12:00:00Z", "snooze_until mismatch")
	check(got1.ttl_at == "2026-09-20T12:00:00Z", "ttl_at mismatch")
	check(got1.created_at == "2026-09-15T00:00:00Z", "created_at mismatch")
	check(got1.updated_at == "2026-09-15T00:00:00Z", "updated_at mismatch")

	// Test 5: Create card with defaults (empty JSON fields and defaults)
	card2 := domain.Card{
		card_id = domain.Card_ID("crd_test_2"),
		owner_user_id = domain.User_ID("usr_test_1"),
		project_id = domain.Project_ID("proj_beta"),
		title = "Prompt worker to run verification suite",
		rationale = "Task in_validation for 2h with no vote",
		scope = "", // should default to "project"
		provider = domain.CARD_PROVIDER_TASK_VALIDATION,
		confidence = 1.0,
		source_refs_json = "", // should default to "[]"
		status = "", // should default to "pending"
		operations_json = "", // should default to "[]"
		guard_json = "", // should default to "{}"
		snooze_until = "",
		ttl_at = "",
		created_at = "2026-09-15T00:10:00Z",
		updated_at = "2026-09-15T00:10:00Z",
	}

	saved2, ok_save2, err_save2 := repo.create(repo.ctx, card2)
	check(ok_save2, fmt.tprintf("create card2: %s", err_save2.message))
	check(saved2.scope == "project", "card2 default scope mismatch")
	check(saved2.status == "pending", "card2 default status mismatch")
	check(saved2.source_refs_json == "[]", "card2 default source_refs mismatch")
	check(saved2.operations_json == "[]", "card2 default ops mismatch")
	check(saved2.guard_json == "{}", "card2 default guard mismatch")

	got2, ok_get2, _ := repo.get(repo.ctx, domain.Card_ID("crd_test_2"))
	check(ok_get2, "get card2 failed")
	check(got2.scope == "project", "got2 scope mismatch")
	check(got2.status == "pending", "got2 status mismatch")
	check(got2.source_refs_json == "[]", "got2 source_refs mismatch")
	check(got2.operations_json == "[]", "got2 ops mismatch")
	check(got2.guard_json == "{}", "got2 guard mismatch")
	// Attention defaults (migration 087): kind derives from provider,
	// attention_since from created_at, the JSON fields default to objects.
	check(saved2.kind == domain.CARD_KIND_TASK, "card2 default kind mismatch")
	check(got2.kind == domain.CARD_KIND_TASK, "got2 kind mismatch")
	check(got2.attention_since == "2026-09-15T00:10:00Z", "got2 attention_since should default to created_at")
	check(got2.details_json == "{}", "got2 details default mismatch")
	check(got2.action_refs_json == "{}", "got2 action_refs default mismatch")
	check(got2.source_marker == "", "got2 source_marker default mismatch")
	check(got1.kind == domain.CARD_KIND_MEMORY, "memory_proposal card should be kind memory")

	// Test 5b: attention fields round-trip through create and update, and
	// source_refs_json is left untouched by them.
	card3 := domain.Card{
		card_id = domain.Card_ID("crd_msg_inst_1"),
		owner_user_id = domain.User_ID("usr_test_1"),
		title = "vault:v1:ciphertext-title",
		provider = domain.CARD_PROVIDER_MESSAGE_OPTIONS,
		source_refs_json = "[\"evidence_1\"]",
		created_at = "2026-09-15T00:20:00Z",
		updated_at = "2026-09-15T00:20:00Z",
		attention_since = "2026-09-15T00:19:00Z",
		source_marker = "msg_9",
		details_json = "{\"options\":[\"Yes\",\"No\"],\"other_unread\":2}",
		action_refs_json = "{\"conversation_id\":\"chat_1\",\"agent_instance_id\":\"inst_1\",\"message_id\":\"msg_9\"}",
	}
	_, ok_save3, err_save3 := repo.create(repo.ctx, card3)
	check(ok_save3, fmt.tprintf("create card3: %s", err_save3.message))
	got3, ok_get3, _ := repo.get(repo.ctx, domain.Card_ID("crd_msg_inst_1"))
	check(ok_get3, "get card3 failed")
	check(got3.kind == domain.CARD_KIND_MESSAGE, "card3 kind mismatch")
	check(got3.attention_since == "2026-09-15T00:19:00Z", "card3 attention_since mismatch")
	check(got3.source_marker == "msg_9", "card3 source_marker mismatch")
	check(got3.details_json == card3.details_json, "card3 details_json mismatch")
	check(got3.action_refs_json == card3.action_refs_json, "card3 action_refs_json mismatch")
	check(got3.title == "vault:v1:ciphertext-title", "card3 ciphertext title must round-trip byte-for-byte")
	got3.source_marker = "msg_10"
	got3.attention_since = "2026-09-15T00:30:00Z"
	got3.details_json = "{\"options\":[\"Ok\"],\"other_unread\":0}"
	got3.status = domain.CARD_STATUS_RESOLVED
	got3.updated_at = "2026-09-15T00:31:00Z"
	_, ok_up3, err_up3 := repo.update(repo.ctx, got3)
	check(ok_up3, fmt.tprintf("update card3: %s", err_up3.message))
	got3b, _, _ := repo.get(repo.ctx, domain.Card_ID("crd_msg_inst_1"))
	check(got3b.source_marker == "msg_10", "card3 marker update not persisted")
	check(got3b.attention_since == "2026-09-15T00:30:00Z", "card3 attention_since update not persisted")
	check(got3b.status == domain.CARD_STATUS_RESOLVED, "card3 resolved status not persisted")
	check(got3b.details_json == "{\"options\":[\"Ok\"],\"other_unread\":0}", "card3 details update not persisted")
	check(got3b.source_refs_json == "[\"evidence_1\"]", "source_refs_json must round-trip unchanged")
	ok_del3, _ := repo.delete_card(repo.ctx, domain.Card_ID("crd_msg_inst_1"))
	check(ok_del3, "delete card3 failed")

	// Test 6: Update card status
	ok_up_status, err_up_status := repo.update_status(repo.ctx, domain.Card_ID("crd_test_1"), domain.CARD_STATUS_ACCEPTED, "2026-09-15T01:00:00Z")
	check(ok_up_status, fmt.tprintf("update_status failed: %s", err_up_status.message))
	got1_after_status, ok_get1_s, _ := repo.get(repo.ctx, domain.Card_ID("crd_test_1"))
	check(ok_get1_s, "get after status update failed")
	check(got1_after_status.status == "accepted", "status was not updated to accepted")
	check(got1_after_status.updated_at == "2026-09-15T01:00:00Z", "updated_at was not updated")

	// Test 7: Full card update
	card1_modified := got1_after_status
	card1_modified.title = "Updated card title"
	card1_modified.rationale = "New rationale description"
	card1_modified.status = domain.CARD_STATUS_SNOOZED
	card1_modified.snooze_until = "2026-09-17T00:00:00Z"
	card1_modified.updated_at = "2026-09-15T01:30:00Z"

	updated1, ok_up1, err_up1 := repo.update(repo.ctx, card1_modified)
	check(ok_up1, fmt.tprintf("update card1: %s", err_up1.message))
	check(updated1.title == "Updated card title", "updated1 title mismatch")
	check(updated1.status == "snoozed", "updated1 status mismatch")

	got1_after_up, _, _ := repo.get(repo.ctx, domain.Card_ID("crd_test_1"))
	check(got1_after_up.title == "Updated card title", "persisted title mismatch")
	check(got1_after_up.rationale == "New rationale description", "persisted rationale mismatch")
	check(got1_after_up.status == "snoozed", "persisted status mismatch")
	check(got1_after_up.snooze_until == "2026-09-17T00:00:00Z", "persisted snooze mismatch")
	check(got1_after_up.updated_at == "2026-09-15T01:30:00Z", "persisted updated_at mismatch")

	// Test 8: List cards by owner
	list_owner, err_list_owner := repo.list(repo.ctx, domain.User_ID("usr_test_1"))
	check(err_list_owner.message == "", fmt.tprintf("list by owner error: %s", err_list_owner.message))
	check(len(list_owner) == 2, fmt.tprintf("expected 2 cards for owner, got %d", len(list_owner)))
	// Ordered by created_at DESC: crd_test_2 (00:10) should be first, crd_test_1 (00:00) second
	check(list_owner[0].card_id == domain.Card_ID("crd_test_2"), "list ordering mismatch [0]")
	check(list_owner[1].card_id == domain.Card_ID("crd_test_1"), "list ordering mismatch [1]")

	// Test 9: List cards by project
	list_proj_alpha, _ := repo.list_by_project(repo.ctx, domain.Project_ID("proj_alpha"))
	check(len(list_proj_alpha) == 1, fmt.tprintf("expected 1 card for proj_alpha, got %d", len(list_proj_alpha)))
	check(list_proj_alpha[0].card_id == domain.Card_ID("crd_test_1"), "proj_alpha card_id mismatch")

	list_proj_beta, _ := repo.list_by_project(repo.ctx, domain.Project_ID("proj_beta"))
	check(len(list_proj_beta) == 1, fmt.tprintf("expected 1 card for proj_beta, got %d", len(list_proj_beta)))
	check(list_proj_beta[0].card_id == domain.Card_ID("crd_test_2"), "proj_beta card_id mismatch")

	list_proj_empty, _ := repo.list_by_project(repo.ctx, domain.Project_ID("proj_gamma"))
	check(len(list_proj_empty) == 0, "expected 0 cards for unused project")

	// Test 10: Delete card
	ok_del, err_del := repo.delete_card(repo.ctx, domain.Card_ID("crd_test_2"))
	check(ok_del, fmt.tprintf("delete card2 failed: %s", err_del.message))

	_, ok_get_deleted, _ := repo.get(repo.ctx, domain.Card_ID("crd_test_2"))
	check(!ok_get_deleted, "deleted card should not be found by get")

	list_after_del, _ := repo.list(repo.ctx, domain.User_ID("usr_test_1"))
	check(len(list_after_del) == 1, fmt.tprintf("expected 1 card after delete, got %d", len(list_after_del)))
	check(list_after_del[0].card_id == domain.Card_ID("crd_test_1"), "remaining card mismatch")

	// Test 11: Owner immutable trigger enforces security
	owner_change_ok := sqlite.exec(&conn, "UPDATE cards SET owner_user_id = 'usr_hacked' WHERE card_id = 'crd_test_1';")
	check(!owner_change_ok, "owner_user_id update should fail due to immutable trigger")

	fmt.println("ALL CARDS REPO TESTS PASSED")
}
