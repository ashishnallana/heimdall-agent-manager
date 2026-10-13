package push_repo_test

import "core:fmt"
import "core:os"
import "core:testing"
import domain "odin_test:hub/domain"
import sqlite "odin_test:hub/repository/sqlite"

@(test)
test_push_repo :: proc(t: ^testing.T) {
	_ = t
	main()
}

check :: proc(ok: bool, msg: string) {
	if ok do return
	fmt.eprintln("FAIL:", msg)
	os.exit(1)
}

main :: proc() {
	db_path := "/tmp/push_repo_test.db"
	_ = os.remove(db_path)
	defer _ = os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	check(open_ok, fmt.tprintf("open db: %s", open_err.message))
	defer sqlite.close(&conn)

	// Full migration run (includes 024_push_subscriptions) + idempotency.
	mig_ok, mig_err := sqlite.run_migrations(&conn, "src/hub/repository/sqlite/migrations")
	check(mig_ok, fmt.tprintf("run_migrations: %s", mig_err.message))
	mig_ok2, mig_err2 := sqlite.run_migrations(&conn, "src/hub/repository/sqlite/migrations")
	check(mig_ok2, fmt.tprintf("run_migrations 2nd run: %s", mig_err2.message))
	check(sqlite.upgrade_push_subscriptions_schema(&conn), "upgrade_push_subscriptions_schema should be idempotent")

	repo_impl: sqlite.Push_Repo_SQLite
	repo := sqlite.new_push_repository(&repo_impl, &conn)

	// Test 1: create (insert) a subscription.
	sub := domain.Push_Subscription{
		id            = domain.Push_Subscription_ID("psub_1"),
		owner_user_id = domain.User_ID("usr_1"),
		endpoint      = "https://web.push.apple.com/aaa",
		p256dh        = "p256dh_aaa",
		auth          = "auth_aaa",
		created_at    = "2026-09-01T10:00:00Z",
		updated_at    = "2026-09-01T10:00:00Z",
	}
	saved, ok_save, err_save := repo.upsert_by_endpoint(repo.ctx, sub)
	check(ok_save, fmt.tprintf("upsert insert: %s", err_save.message))
	check(saved.id == domain.Push_Subscription_ID("psub_1"), "saved id mismatch")

	// Test 2: list_by_owner returns the row with the right fields.
	list1, err_list1 := repo.list_by_owner(repo.ctx, domain.User_ID("usr_1"))
	check(err_list1.code == .None, "list_by_owner err")
	check(len(list1) == 1, fmt.tprintf("expected 1 sub, got %d", len(list1)))
	check(list1[0].endpoint == "https://web.push.apple.com/aaa", "endpoint mismatch")
	check(list1[0].p256dh == "p256dh_aaa", "p256dh mismatch")
	check(list1[0].auth == "auth_aaa", "auth mismatch")

	// Test 3: upsert-by-endpoint replaces keys, keeps the original id, no dup.
	sub_upd := sub
	sub_upd.id = domain.Push_Subscription_ID("psub_DIFFERENT")
	sub_upd.p256dh = "p256dh_new"
	sub_upd.auth = "auth_new"
	sub_upd.updated_at = "2026-09-02T10:00:00Z"
	upserted, ok_up, err_up := repo.upsert_by_endpoint(repo.ctx, sub_upd)
	check(ok_up, fmt.tprintf("upsert update: %s", err_up.message))
	// The persisted id must be the ORIGINAL row's id, not the new one.
	check(upserted.id == domain.Push_Subscription_ID("psub_1"), "upsert must preserve original id")

	list2, _ := repo.list_by_owner(repo.ctx, domain.User_ID("usr_1"))
	check(len(list2) == 1, fmt.tprintf("upsert must not duplicate; got %d", len(list2)))
	check(list2[0].p256dh == "p256dh_new", "upsert must replace p256dh")
	check(list2[0].auth == "auth_new", "upsert must replace auth")
	check(list2[0].owner_user_id == domain.User_ID("usr_1"), "owner must be unchanged")

	// Test 4: a second endpoint for the same owner lists both.
	sub2 := domain.Push_Subscription{
		id            = domain.Push_Subscription_ID("psub_2"),
		owner_user_id = domain.User_ID("usr_1"),
		endpoint      = "https://fcm.googleapis.com/bbb",
		p256dh        = "p256dh_bbb",
		auth          = "auth_bbb",
		created_at    = "2026-09-03T10:00:00Z",
		updated_at    = "2026-09-03T10:00:00Z",
	}
	_, ok_save2, _ := repo.upsert_by_endpoint(repo.ctx, sub2)
	check(ok_save2, "insert second endpoint")
	list3, _ := repo.list_by_owner(repo.ctx, domain.User_ID("usr_1"))
	check(len(list3) == 2, fmt.tprintf("expected 2 subs, got %d", len(list3)))

	// Test 5: delete_by_endpoint is owner-scoped.
	// Wrong owner must not delete.
	del_wrong, _ := repo.delete_by_endpoint(repo.ctx, domain.User_ID("usr_other"), "https://fcm.googleapis.com/bbb")
	check(!del_wrong, "delete_by_endpoint must not delete another user's endpoint")
	// Correct owner deletes.
	del_ok, err_del := repo.delete_by_endpoint(repo.ctx, domain.User_ID("usr_1"), "https://fcm.googleapis.com/bbb")
	check(del_ok, fmt.tprintf("delete_by_endpoint: %s", err_del.message))
	list4, _ := repo.list_by_owner(repo.ctx, domain.User_ID("usr_1"))
	check(len(list4) == 1, fmt.tprintf("expected 1 sub after delete, got %d", len(list4)))

	// Test 6: delete_by_id prunes the remaining subscription (WP-SEND 410 path).
	del_id_ok, err_del_id := repo.delete_by_id(repo.ctx, domain.Push_Subscription_ID("psub_1"))
	check(del_id_ok, fmt.tprintf("delete_by_id: %s", err_del_id.message))
	list5, _ := repo.list_by_owner(repo.ctx, domain.User_ID("usr_1"))
	check(len(list5) == 0, fmt.tprintf("expected 0 subs after delete_by_id, got %d", len(list5)))

	// Test 7: deleting a non-existent row returns false (no error).
	del_missing, err_missing := repo.delete_by_id(repo.ctx, domain.Push_Subscription_ID("psub_missing"))
	check(!del_missing && err_missing.code == .None, "delete_by_id of missing row returns false")

	// Test 8: owner-immutable trigger blocks changing owner_user_id.
	_, ok_reinsert, _ := repo.upsert_by_endpoint(repo.ctx, sub)
	check(ok_reinsert, "re-insert for trigger test")
	moved := sqlite.exec(&conn, "UPDATE push_subscriptions SET owner_user_id = 'usr_hacker' WHERE id = 'psub_1';")
	check(!moved, "owner_user_id must be immutable (trigger should ABORT the update)")

	fmt.println("ALL PUSH REPO TESTS PASSED")
}
