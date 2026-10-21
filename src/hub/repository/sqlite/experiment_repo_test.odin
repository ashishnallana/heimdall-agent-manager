package sqlite

import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(test)
test_experiment_repo_sqlite_lifecycle :: proc(t: ^testing.T) {
	conn, db_path, open_ok := tmpl_clone_migrated_into_file(t, "experiment_repo")
	defer tmpl_remove_db(db_path)
	testing.expect(t, open_ok, "db open ok")
	defer close(&conn)

	testing.expect(t, table_column_exists(&conn, "experiments", "enabled"), "enabled column exists")

	impl := Experiment_Repo_SQLite{}
	repo := new_experiment_repository(&impl, &conn)

	owner_a := "user_exp_a"
	owner_b := "user_exp_b"

	// List returns empty for unknown owner
	list0, err0 := iface.experiment_list_by_owner(&repo, owner_a)
	testing.expect_value(t, err0.code, domain.Error_Code.None)
	testing.expect_value(t, len(list0), 0)
	delete(list0)

	// Set a flag enabled
	exp_lsp := domain.Experiment{owner_user_id = owner_a, key = "lsp", enabled = true, updated_at = "2026-09-22T10:00:00Z"}
	ok1, err1 := iface.experiment_set(&repo, exp_lsp)
	testing.expect(t, ok1, "set lsp ok")
	testing.expect_value(t, err1.code, domain.Error_Code.None)

	// List returns one row
	list1, err1b := iface.experiment_list_by_owner(&repo, owner_a)
	testing.expect_value(t, err1b.code, domain.Error_Code.None)
	testing.expect_value(t, len(list1), 1)
	if len(list1) == 1 {
		testing.expect_value(t, list1[0].key, "lsp")
		testing.expect(t, list1[0].enabled, "lsp enabled")
	}
	for e in list1 { delete(e.owner_user_id); delete(e.key); delete(e.updated_at) }
	delete(list1)

	// Update the flag to disabled
	exp_lsp_off := domain.Experiment{owner_user_id = owner_a, key = "lsp", enabled = false, updated_at = "2026-09-22T11:00:00Z"}
	ok2, err2 := iface.experiment_set(&repo, exp_lsp_off)
	testing.expect(t, ok2, "update lsp to disabled ok")
	testing.expect_value(t, err2.code, domain.Error_Code.None)

	// List reflects the update
	list2, err2b := iface.experiment_list_by_owner(&repo, owner_a)
	testing.expect_value(t, err2b.code, domain.Error_Code.None)
	testing.expect_value(t, len(list2), 1)
	if len(list2) == 1 {
		testing.expect(t, !list2[0].enabled, "lsp now disabled")
		testing.expect_value(t, list2[0].updated_at, "2026-09-22T11:00:00Z")
	}
	for e in list2 { delete(e.owner_user_id); delete(e.key); delete(e.updated_at) }
	delete(list2)

	// Set a second flag for owner_a
	exp_beta := domain.Experiment{owner_user_id = owner_a, key = "beta", enabled = true, updated_at = "2026-09-22T10:00:00Z"}
	ok_beta, err_beta := iface.experiment_set(&repo, exp_beta)
	testing.expect(t, ok_beta, "set beta ok")
	testing.expect_value(t, err_beta.code, domain.Error_Code.None)

	list3, err3 := iface.experiment_list_by_owner(&repo, owner_a)
	testing.expect_value(t, err3.code, domain.Error_Code.None)
	testing.expect_value(t, len(list3), 2)
	for e in list3 { delete(e.owner_user_id); delete(e.key); delete(e.updated_at) }
	delete(list3)

	// owner_b is isolated: sees no flags from owner_a
	exp_b := domain.Experiment{owner_user_id = owner_b, key = "lsp", enabled = true, updated_at = "2026-09-22T10:00:00Z"}
	ok_b, err_b := iface.experiment_set(&repo, exp_b)
	testing.expect(t, ok_b, "set owner_b lsp ok")
	testing.expect_value(t, err_b.code, domain.Error_Code.None)

	list_a, err_la := iface.experiment_list_by_owner(&repo, owner_a)
	list_b, err_lb := iface.experiment_list_by_owner(&repo, owner_b)
	testing.expect_value(t, err_la.code, domain.Error_Code.None)
	testing.expect_value(t, err_lb.code, domain.Error_Code.None)
	testing.expect_value(t, len(list_a), 2)
	testing.expect_value(t, len(list_b), 1)
	for e in list_a { delete(e.owner_user_id); delete(e.key); delete(e.updated_at) }
	for e in list_b { delete(e.owner_user_id); delete(e.key); delete(e.updated_at) }
	delete(list_a)
	delete(list_b)

	// --- Durability: close and reopen the database, re-run migrations ---
	// Proves that flags survive a Hub restart (REQ-EXP-1 acceptance criterion).
	// Also exercises the idempotency guard (043_experiments.sql) on a populated DB.
	close(&conn) // explicit close — defer at line 16 is now a no-op (double-close safe)

	conn2, reopen_ok, _ := open(db_path)
	testing.expect(t, reopen_ok, "db reopen ok")
	defer close(&conn2)

	mig2_ok, _ := run_migrations(&conn2)
	testing.expect(t, mig2_ok, "migrations idempotent on populated db")

	impl2 := Experiment_Repo_SQLite{}
	repo2 := new_experiment_repository(&impl2, &conn2)

	// owner_a must still have 2 flags: lsp (disabled, updated_at 11:00) + beta (enabled)
	persisted_a, perr_a := iface.experiment_list_by_owner(&repo2, owner_a)
	testing.expect_value(t, perr_a.code, domain.Error_Code.None)
	testing.expect_value(t, len(persisted_a), 2)
	if len(persisted_a) == 2 {
		// ORDER BY key ASC: beta < lsp
		testing.expect_value(t, persisted_a[0].key, "beta")
		testing.expect(t, persisted_a[0].enabled, "beta still enabled after reopen")
		testing.expect_value(t, persisted_a[1].key, "lsp")
		testing.expect(t, !persisted_a[1].enabled, "lsp still disabled after reopen")
		testing.expect_value(t, persisted_a[1].updated_at, "2026-09-22T11:00:00Z")
	}
	for e in persisted_a { delete(e.owner_user_id); delete(e.key); delete(e.updated_at) }
	delete(persisted_a)
}

@(test)
test_experiment_repo_streaming_terminal_pane :: proc(t: ^testing.T) {
	conn, open_ok := tmpl_clone_migrated(t)
	testing.expect(t, open_ok, "db open ok")
	defer close(&conn)

	impl := Experiment_Repo_SQLite{}
	repo := new_experiment_repository(&impl, &conn)

	user := "user_stream_test"

	// Initially absent
	list0, err0 := iface.experiment_list_by_owner(&repo, user)
	testing.expect_value(t, err0.code, domain.Error_Code.None)
	testing.expect_value(t, len(list0), 0)
	delete(list0)

	// Set streaming_terminal_pane = true
	exp := domain.Experiment{
		owner_user_id = user,
		key           = domain.STREAMING_TERMINAL_PANE_EXPERIMENT_KEY,
		enabled       = true,
		updated_at    = "2026-09-27T01:00:00Z",
	}
	ok, err := iface.experiment_set(&repo, exp)
	testing.expect(t, ok, "set streaming_terminal_pane ok")
	testing.expect_value(t, err.code, domain.Error_Code.None)

	list1, err1 := iface.experiment_list_by_owner(&repo, user)
	testing.expect_value(t, err1.code, domain.Error_Code.None)
	testing.expect_value(t, len(list1), 1)
	if len(list1) == 1 {
		testing.expect_value(t, list1[0].key, "streaming_terminal_pane")
		testing.expect(t, list1[0].enabled, "streaming_terminal_pane must be enabled")
	}
	for e in list1 { delete(e.owner_user_id); delete(e.key); delete(e.updated_at) }
	delete(list1)
}
