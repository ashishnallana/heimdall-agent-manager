#+private file
// Behavioral tests for taskchain SQLite repository (bridge, fleet, pinned, rollup, subscription).
package sqlite

import domain "odin_test:hub/domain"
import "core:fmt"
import iface "odin_test:hub/repository/iface"
import "core:os"
import "core:testing"

// --- Consolidated from taskchain_bridge_repo_test.odin ---

@(test)
test_task_bridge_id_sqlite_roundtrip :: proc(t: ^testing.T) {
	db_path := ":memory:"
	conn, open_ok, open_err := open(db_path)
	testing.expect(t, open_ok, "db open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer close(&conn)

	mig_ok, mig_err := run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	// The migration must have added the column.
	testing.expect(t, table_column_exists(&conn, "tasks", "bridge_id"), "tasks.bridge_id column exists")

	repo_impl := Taskchain_Repo_SQLite{conn = &conn}
	repo := new_taskchain_repository(&repo_impl, &conn)

	owner := domain.User_ID("user_tb_repo")
	cid := domain.Task_Chain_ID("chain_tb_repo")

	chain := domain.Task_Chain{
		chain_id      = cid,
		owner_user_id = owner,
		title         = "Task Bridge Chain",
		publish_state = .Draft,
		status        = .Active,
		kind          = "tb_test",
		created_at    = "2026-09-25T10:00:00Z",
		updated_at    = "2026-09-25T10:00:00Z",
	}
	_, save_chain_ok, save_chain_err := iface.taskchain_save_chain(&repo, chain)
	testing.expect(t, save_chain_ok, "save chain ok")
	testing.expect_value(t, save_chain_err.code, domain.Error_Code.None)

	// 1. Save with an empty bridge_id (inherit) — reads back empty.
	task_empty := domain.Task{
		task_id            = "task_tb_empty",
		chain_id           = cid,
		owner_user_id      = owner,
		title              = "Inherit Task",
		publish_state      = .Draft,
		status             = .Assigned,
		priority           = .P2,
		assignee_ref_json  = `{}`,
		reviewer_refs_json = `[]`,
		bridge_id          = "",
		created_at         = "2026-09-25T10:01:00Z",
		updated_at         = "2026-09-25T10:01:00Z",
	}
	_, e_ok, e_err := iface.taskchain_save_task(&repo, task_empty)
	testing.expect(t, e_ok, "save inherit task ok")
	testing.expect_value(t, e_err.code, domain.Error_Code.None)

	got_empty, g_ok, g_err := iface.taskchain_get_task(&repo, "task_tb_empty")
	testing.expect(t, g_ok, "get inherit task ok")
	testing.expect_value(t, g_err.code, domain.Error_Code.None)
	testing.expect_value(t, got_empty.bridge_id, "")

	// 2. Save with a preset bridge pin — roundtrips through save AND list.
	task_pinned := domain.Task{
		task_id            = "task_tb_pinned",
		chain_id           = cid,
		owner_user_id      = owner,
		title              = "Pinned Task",
		publish_state      = .Draft,
		status             = .Assigned,
		priority           = .P1,
		assignee_ref_json  = `{}`,
		reviewer_refs_json = `[]`,
		bridge_id          = "brg_pin",
		created_at         = "2026-09-25T10:02:00Z",
		updated_at         = "2026-09-25T10:02:00Z",
	}
	_, p_ok, p_err := iface.taskchain_save_task(&repo, task_pinned)
	testing.expect(t, p_ok, "save pinned task ok")
	testing.expect_value(t, p_err.code, domain.Error_Code.None)

	got_pinned, pg_ok, _ := iface.taskchain_get_task(&repo, "task_tb_pinned")
	testing.expect(t, pg_ok, "get pinned task ok")
	testing.expect_value(t, got_pinned.bridge_id, "brg_pin")

	listed, l_err := iface.taskchain_list_tasks_by_chain(&repo, cid, owner)
	testing.expect_value(t, l_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(listed), 2)
	for task in listed {
		if string(task.task_id) == "task_tb_pinned" do testing.expect_value(t, task.bridge_id, "brg_pin")
		if string(task.task_id) == "task_tb_empty" do testing.expect_value(t, task.bridge_id, "")
	}

	// 3. Clear via re-save (UPSERT path) — pin drops back to inherit.
	got_pinned.bridge_id = ""
	got_pinned.updated_at = "2026-09-25T10:03:00Z"
	_, c_ok, c_err := iface.taskchain_save_task(&repo, got_pinned)
	testing.expect(t, c_ok, "re-save cleared task ok")
	testing.expect_value(t, c_err.code, domain.Error_Code.None)
	got_cleared, cg_ok, _ := iface.taskchain_get_task(&repo, "task_tb_pinned")
	testing.expect(t, cg_ok, "get cleared task ok")
	testing.expect_value(t, got_cleared.bridge_id, "")

	// Restore the pin for the migration checks below.
	got_cleared.bridge_id = "brg_pin"
	got_cleared.updated_at = "2026-09-25T10:04:00Z"
	_, _, _ = iface.taskchain_save_task(&repo, got_cleared)

	// 4. Populated-DB safety, the migrations.odin:735-752 way: re-running
	// migrations on a populated DB succeeds and preserves the data.
	mig_again_ok, mig_again_err := run_migrations(&conn)
	testing.expect(t, mig_again_ok, "re-run migrations ok")
	testing.expect_value(t, mig_again_err.code, domain.Error_Code.None)
	got_after, ga_ok, _ := iface.taskchain_get_task(&repo, "task_tb_pinned")
	testing.expect(t, ga_ok, "get task after re-migration ok")
	testing.expect_value(t, got_after.bridge_id, "brg_pin")

	// 5. Stronger populated-DB check: simulate a pre-upgrade DB by dropping the
	// column with rows present, then re-migrate — the guarded ALTER must re-add
	// it and the surviving rows must keep their data.
	if exec(&conn, "ALTER TABLE tasks DROP COLUMN bridge_id;") {
		testing.expect(t, !table_column_exists(&conn, "tasks", "bridge_id"), "column dropped for pre-upgrade simulation")
		mig_upgrade_ok, mig_upgrade_err := run_migrations(&conn)
		testing.expect(t, mig_upgrade_ok, "re-migrate pre-upgrade populated db ok")
		testing.expect_value(t, mig_upgrade_err.code, domain.Error_Code.None)
		testing.expect(t, table_column_exists(&conn, "tasks", "bridge_id"), "column re-added by upgrade")
		got_upgraded, gu_ok, _ := iface.taskchain_get_task(&repo, "task_tb_pinned")
		testing.expect(t, gu_ok, "get task after column upgrade ok")
		testing.expect_value(t, got_upgraded.bridge_id, "")
	} else {
	}
}

// --- Consolidated from taskchain_fleet_repo_test.odin ---

@(test)
test_taskchain_fleet_sqlite_lifecycle :: proc(t: ^testing.T) {
	db_path := ":memory:"
	conn, open_ok, open_err := open(db_path)
	testing.expect(t, open_ok, "db open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer close(&conn)

	mig_ok, mig_err := run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	// Verify table exists
	testing.expect(t, sqlite_object_exists(&conn, "task_chain_fleets"), "task_chain_fleets table exists")

	repo_impl := Taskchain_Repo_SQLite{conn = &conn}
	repo := new_taskchain_repository(&repo_impl, &conn)

	owner := domain.User_ID("user_fleet_tester")
	cid := domain.Task_Chain_ID("chain_fleet_test")

	// Create parent task chain for foreign key
	chain := domain.Task_Chain{
		chain_id                      = cid,
		owner_user_id                 = owner,
		title                         = "Fleet Test Chain",
		description                   = "desc",
		publish_state                 = .Published,
		status                        = .Active,
		kind                          = "fleet_testing",
		coordinator_agent_instance_id = "inst_c",
		default_reviewer_refs_json    = "[]",
		created_at                    = "2026-09-23T10:00:00Z",
		updated_at                    = "2026-09-23T10:00:00Z",
	}
	_, save_ok, save_err := iface.taskchain_save_chain(&repo, chain)
	testing.expect(t, save_ok, "save chain ok")
	testing.expect_value(t, save_err.code, domain.Error_Code.None)

	// 1. Initial list is empty
	fleets0, f_err0 := iface.taskchain_list_fleets_by_chain(&repo, cid, owner)
	testing.expect_value(t, f_err0.code, domain.Error_Code.None)
	testing.expect_value(t, len(fleets0), 0)

	// 2. Upsert fleet with provider/model (REQ-FLEET-PT-1)
	fleet1 := domain.Task_Chain_Fleet{
		bridge_models_json = `{"brg_one":{"provider":"codex","model":"model-one"}}`,
		task_chain_id    = cid,
		agent_id         = "agt_worker",
		capacity         = 3,
		min_warm         = 1,
		idle_ttl_seconds = 300,
		provider         = "claude",
		model             = "smart",
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:00:00Z",
	}
	saved1, s_err1 := iface.taskchain_upsert_fleet(&repo, fleet1)
	testing.expect_value(t, s_err1.code, domain.Error_Code.None)
	testing.expect_value(t, saved1.capacity, 3)
	testing.expect_value(t, saved1.min_warm, 1)
	testing.expect_value(t, saved1.provider, "claude")
	testing.expect_value(t, saved1.model, "smart")

	// 3. List fleets
	fleets1, f_err1 := iface.taskchain_list_fleets_by_chain(&repo, cid, owner)
	testing.expect_value(t, f_err1.code, domain.Error_Code.None)
	testing.expect_value(t, len(fleets1), 1)
	if len(fleets1) == 1 {
		testing.expect_value(t, string(fleets1[0].task_chain_id), string(cid))
		testing.expect_value(t, fleets1[0].agent_id, "agt_worker")
		testing.expect_value(t, fleets1[0].capacity, 3)
		testing.expect_value(t, fleets1[0].min_warm, 1)
		testing.expect_value(t, fleets1[0].idle_ttl_seconds, 300)
		testing.expect_value(t, fleets1[0].provider, "claude")
		testing.expect_value(t, fleets1[0].model, "smart")
		testing.expect_value(t, fleets1[0].bridge_models_json, fleet1.bridge_models_json)
	}

	// 3b. Re-running migrations on a populated DB must succeed without data loss
	// (the provider/model column upgrade is guarded and idempotent).
	mig_again_ok, mig_again_err := run_migrations(&conn)
	testing.expect(t, mig_again_ok, "re-run migrations ok")
	testing.expect_value(t, mig_again_err.code, domain.Error_Code.None)
	fleets1b, f_err1b := iface.taskchain_list_fleets_by_chain(&repo, cid, owner)
	testing.expect_value(t, f_err1b.code, domain.Error_Code.None)
	testing.expect_value(t, len(fleets1b), 1)
	if len(fleets1b) == 1 {
		testing.expect_value(t, fleets1b[0].provider, "claude")
		testing.expect_value(t, fleets1b[0].model, "smart")
	}

	// 3c. A fleet upserted without provider/model reads back as "" (inherit).
	fleet_reviewer := domain.Task_Chain_Fleet{
		task_chain_id    = cid,
		agent_id         = "agt_reviewer",
		capacity         = 1,
		min_warm         = 0,
		idle_ttl_seconds = 600,
		created_at       = "2026-09-23T10:01:00Z",
		updated_at       = "2026-09-23T10:01:00Z",
	}
	saved_rev, s_rev_err := iface.taskchain_upsert_fleet(&repo, fleet_reviewer)
	testing.expect_value(t, s_rev_err.code, domain.Error_Code.None)
	testing.expect_value(t, saved_rev.provider, "")
	testing.expect_value(t, saved_rev.model, "")
	fleets1c, f_err1c := iface.taskchain_list_fleets_by_chain(&repo, cid, owner)
	testing.expect_value(t, f_err1c.code, domain.Error_Code.None)
	testing.expect_value(t, len(fleets1c), 2)
	for f in fleets1c {
		if f.agent_id == "agt_reviewer" {
			testing.expect_value(t, f.provider, "")
			testing.expect_value(t, f.model, "")
		}
	}
	del_rev_ok, del_rev_err := iface.taskchain_delete_fleet(&repo, cid, "agt_reviewer", owner)
	testing.expect(t, del_rev_ok, "reviewer fleet deleted")
	testing.expect_value(t, del_rev_err.code, domain.Error_Code.None)

	// 4. Upsert (update) existing fleet — provider/model must be replaced on conflict
	fleet1_updated := domain.Task_Chain_Fleet{
		task_chain_id    = cid,
		agent_id         = "agt_worker",
		capacity         = 5,
		min_warm         = 2,
		idle_ttl_seconds = 900,
		provider         = "qoder",
		model             = "max",
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:10:00Z",
	}
	saved_up, sup_err := iface.taskchain_upsert_fleet(&repo, fleet1_updated)
	testing.expect_value(t, sup_err.code, domain.Error_Code.None)
	testing.expect_value(t, saved_up.capacity, 5)
	testing.expect_value(t, saved_up.provider, "qoder")
	testing.expect_value(t, saved_up.model, "max")

	fleets2, f_err2 := iface.taskchain_list_fleets_by_chain(&repo, cid, owner)
	testing.expect_value(t, f_err2.code, domain.Error_Code.None)
	testing.expect_value(t, len(fleets2), 1)
	if len(fleets2) == 1 {
		testing.expect_value(t, fleets2[0].capacity, 5)
		testing.expect_value(t, fleets2[0].min_warm, 2)
		testing.expect_value(t, fleets2[0].idle_ttl_seconds, 900)
		testing.expect_value(t, fleets2[0].provider, "qoder")
		testing.expect_value(t, fleets2[0].model, "max")
	}

	// 5. Delete fleet
	del_ok, del_err := iface.taskchain_delete_fleet(&repo, cid, "agt_worker", owner)
	testing.expect_value(t, del_err.code, domain.Error_Code.None)
	testing.expect(t, del_ok, "fleet deleted")

	// 6. List fleets is now empty
	fleets3, f_err3 := iface.taskchain_list_fleets_by_chain(&repo, cid, owner)
	testing.expect_value(t, f_err3.code, domain.Error_Code.None)
	testing.expect_value(t, len(fleets3), 0)

	// 7. Ensure inserts only a missing default Fleet row.
	ensured := domain.Task_Chain_Fleet{
		task_chain_id    = cid,
		agent_id         = "agt_ensured",
		capacity         = 1,
		min_warm         = 0,
		idle_ttl_seconds = 600,
		created_at       = "2026-09-23T10:20:00Z",
		updated_at       = "2026-09-23T10:20:00Z",
	}
	ensure_err := iface.taskchain_ensure_fleet(&repo, ensured)
	testing.expect_value(t, ensure_err.code, domain.Error_Code.None)
	ensured_rows, ensured_list_err := iface.taskchain_list_fleets_by_chain(&repo, cid, owner)
	testing.expect_value(t, ensured_list_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(ensured_rows), 1)
	if len(ensured_rows) == 1 {
		testing.expect_value(t, ensured_rows[0].capacity, 1)
		testing.expect_value(t, ensured_rows[0].min_warm, 0)
		testing.expect_value(t, ensured_rows[0].idle_ttl_seconds, 600)
		testing.expect_value(t, ensured_rows[0].provider, "")
		testing.expect_value(t, ensured_rows[0].model, "")
	}

	// 8. Ensure preserves an existing configured row, including provider and model.
	configured := ensured
	configured.capacity = 7
	configured.min_warm = 3
	configured.idle_ttl_seconds = 901
	configured.provider = "codex"
	configured.model = "max"
	configured.updated_at = "2026-09-23T10:21:00Z"
	_, configured_err := iface.taskchain_upsert_fleet(&repo, configured)
	testing.expect_value(t, configured_err.code, domain.Error_Code.None)
	reensure_err := iface.taskchain_ensure_fleet(&repo, ensured)
	testing.expect_value(t, reensure_err.code, domain.Error_Code.None)
	preserved_rows, preserved_list_err := iface.taskchain_list_fleets_by_chain(&repo, cid, owner)
	testing.expect_value(t, preserved_list_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(preserved_rows), 1)
	if len(preserved_rows) == 1 {
		testing.expect_value(t, preserved_rows[0].capacity, 7)
		testing.expect_value(t, preserved_rows[0].min_warm, 3)
		testing.expect_value(t, preserved_rows[0].idle_ttl_seconds, 901)
		testing.expect_value(t, preserved_rows[0].provider, "codex")
		testing.expect_value(t, preserved_rows[0].model, "max")
	}

	// 9. Delete non-existent fleet returns false
	del_ok2, del_err2 := iface.taskchain_delete_fleet(&repo, cid, "agt_worker", owner)
	testing.expect_value(t, del_err2.code, domain.Error_Code.None)
	testing.expect(t, !del_ok2, "non-existent fleet returns false")
}

// --- Consolidated from taskchain_pinned_repo_test.odin ---

@(test)
test_taskchain_pinned_sqlite_lifecycle :: proc(t: ^testing.T) {
	db_path := ":memory:"
	conn, open_ok, open_err := open(db_path)
	testing.expect(t, open_ok, "db open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer close(&conn)

	mig_ok, mig_err := run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	// Verify columns exist
	testing.expect(t, table_column_exists(&conn, "task_chains", "is_pinned"), "is_pinned column exists")
	testing.expect(t, table_column_exists(&conn, "task_chains", "pinned_at"), "pinned_at column exists")

	repo_impl := Taskchain_Repo_SQLite{conn = &conn}
	repo := new_taskchain_repository(&repo_impl, &conn)

	owner := domain.User_ID("user_pin_tester")

	// Initially count of pinned is 0
	count0, c_err0 := iface.taskchain_count_pinned_chains(&repo, owner)
	testing.expect_value(t, c_err0.code, domain.Error_Code.None)
	testing.expect_value(t, count0, 0)

	// Create and pin 10 chains
	for i in 1..=10 {
		cid := fmt.tprintf("chain_test_%02d", i)
		c := domain.Task_Chain{
			chain_id                      = domain.Task_Chain_ID(cid),
			owner_user_id                 = owner,
			title                         = fmt.tprintf("Chain %d", i),
			description                   = "desc",
			publish_state                 = .Published,
			status                        = .Active,
			kind                          = "team_work",
			coordinator_agent_instance_id = "inst_c",
			default_reviewer_refs_json    = "[]",
			created_at                    = fmt.tprintf("2026-09-21T10:%02d:00Z", i),
			updated_at                    = fmt.tprintf("2026-09-21T10:%02d:00Z", i),
			is_pinned                     = true,
			pinned_at                     = fmt.tprintf("2026-09-21T10:%02d:00Z", i),
		}
		saved, sok, serr := iface.taskchain_save_chain(&repo, c)
		testing.expect(t, sok, "save chain ok")
		testing.expect_value(t, serr.code, domain.Error_Code.None)
		testing.expect(t, saved.is_pinned, "is_pinned saved as true")
	}

	// Verify count is 10
	count10, c_err10 := iface.taskchain_count_pinned_chains(&repo, owner)
	testing.expect_value(t, c_err10.code, domain.Error_Code.None)
	testing.expect_value(t, count10, 10)

	// List pinned chains, verify count 10 and ordered pinned_at DESC (10 down to 1)
	pinned_list, l_err := iface.taskchain_list_pinned_chains(&repo, owner)
	defer delete(pinned_list)
	testing.expect_value(t, l_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(pinned_list), 10)
	if len(pinned_list) == 10 {
		testing.expect_value(t, string(pinned_list[0].chain_id), "chain_test_10")
		testing.expect_value(t, string(pinned_list[9].chain_id), "chain_test_01")
	}

	// Unpin chain 10
	c10, got10, g_err10 := iface.taskchain_get_chain(&repo, domain.Task_Chain_ID("chain_test_10"))
	testing.expect(t, got10, "got chain 10")
	testing.expect_value(t, g_err10.code, domain.Error_Code.None)
	c10.is_pinned = false
	c10.pinned_at = ""
	_, u_ok, u_err := iface.taskchain_save_chain(&repo, c10)
	testing.expect(t, u_ok, "unpin save ok")
	testing.expect_value(t, u_err.code, domain.Error_Code.None)

	// Verify count dropped to 9
	count9, c_err9 := iface.taskchain_count_pinned_chains(&repo, owner)
	testing.expect_value(t, c_err9.code, domain.Error_Code.None)
	testing.expect_value(t, count9, 9)

	// List pinned chains again
	pinned_list9, l_err9 := iface.taskchain_list_pinned_chains(&repo, owner)
	defer delete(pinned_list9)
	testing.expect_value(t, l_err9.code, domain.Error_Code.None)
	testing.expect_value(t, len(pinned_list9), 9)
	if len(pinned_list9) == 9 {
		testing.expect_value(t, string(pinned_list9[0].chain_id), "chain_test_09")
	}
}

// --- Consolidated from taskchain_rollup_repo_test.odin ---

@(test)
test_taskchain_rollup_counts :: proc(t: ^testing.T) {
	db_path := ":memory:"
	conn, open_ok, open_err := open(db_path)
	testing.expect(t, open_ok, "db open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer close(&conn)

	mig_ok, mig_err := run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	repo_impl := Taskchain_Repo_SQLite{conn = &conn}
	repo := new_taskchain_repository(&repo_impl, &conn)

	owner := domain.User_ID("user_rollup_test")
	other_owner := domain.User_ID("user_rollup_other")

	chain1 := domain.Task_Chain_ID("chain_rollup_1")
	chain2 := domain.Task_Chain_ID("chain_rollup_2")

	// Save chain 1
	c1 := domain.Task_Chain{
		chain_id      = chain1,
		owner_user_id = owner,
		title         = "Chain 1",
		publish_state = .Published,
		status        = .Active,
		kind          = "team_work",
		created_at    = "2026-09-25T10:00:00Z",
		updated_at    = "2026-09-25T10:00:00Z",
	}
	_, s1_ok, _ := iface.taskchain_save_chain(&repo, c1)
	testing.expect(t, s1_ok, "save chain 1 ok")

	// Tasks in chain 1:
	// Task 1: completed
	t1 := domain.Task{
		task_id            = domain.Task_ID("task_r_1"),
		chain_id           = chain1,
		owner_user_id      = owner,
		title              = "Task 1",
		publish_state      = .Published,
		status             = .Completed,
		priority           = .P1,
		reviewer_refs_json = `[{"type":"agent_id","agent_id":"agt_1"}]`,
		created_at         = "2026-09-25T10:00:00Z",
		updated_at         = "2026-09-25T10:00:00Z",
	}
	iface.taskchain_save_task(&repo, t1)

	// Task 2: validated_good
	t2 := domain.Task{
		task_id            = domain.Task_ID("task_r_2"),
		chain_id           = chain1,
		owner_user_id      = owner,
		title              = "Task 2",
		publish_state      = .Published,
		status             = .Validated_Good,
		priority           = .P1,
		reviewer_refs_json = `[]`,
		created_at         = "2026-09-25T10:00:00Z",
		updated_at         = "2026-09-25T10:00:00Z",
	}
	iface.taskchain_save_task(&repo, t2)

	// Task 3: in_validation with empty reviewer_refs_json "[]" (defaults to user validation)
	t3 := domain.Task{
		task_id            = domain.Task_ID("task_r_3"),
		chain_id           = chain1,
		owner_user_id      = owner,
		title              = "Task 3",
		publish_state      = .Published,
		status             = .In_Validation,
		priority           = .P1,
		reviewer_refs_json = `[]`,
		created_at         = "2026-09-25T10:00:00Z",
		updated_at         = "2026-09-25T10:00:00Z",
	}
	iface.taskchain_save_task(&repo, t3)

	// Task 4: in_validation with reviewer_refs_json containing user
	t4 := domain.Task{
		task_id            = domain.Task_ID("task_r_4"),
		chain_id           = chain1,
		owner_user_id      = owner,
		title              = "Task 4",
		publish_state      = .Published,
		status             = .In_Validation,
		priority           = .P1,
		reviewer_refs_json = `[{"type":"user"}]`,
		created_at         = "2026-09-25T10:00:00Z",
		updated_at         = "2026-09-25T10:00:00Z",
	}
	iface.taskchain_save_task(&repo, t4)

	// Task 5: in_validation with agent-only reviewer (should NOT count as user_validation)
	t5 := domain.Task{
		task_id            = domain.Task_ID("task_r_5"),
		chain_id           = chain1,
		owner_user_id      = owner,
		title              = "Task 5",
		publish_state      = .Published,
		status             = .In_Validation,
		priority           = .P1,
		reviewer_refs_json = `[{"type":"agent_id","agent_id":"agt_reviewer"}]`,
		created_at         = "2026-09-25T10:00:00Z",
		updated_at         = "2026-09-25T10:00:00Z",
	}
	iface.taskchain_save_task(&repo, t5)

	// Task 6: in_progress
	t6 := domain.Task{
		task_id            = domain.Task_ID("task_r_6"),
		chain_id           = chain1,
		owner_user_id      = owner,
		title              = "Task 6",
		publish_state      = .Published,
		status             = .In_Progress,
		priority           = .P1,
		reviewer_refs_json = `[]`,
		created_at         = "2026-09-25T10:00:00Z",
		updated_at         = "2026-09-25T10:00:00Z",
	}
	iface.taskchain_save_task(&repo, t6)

	// Task 7: other owner task in chain 1 (must NOT be counted)
	t7 := domain.Task{
		task_id            = domain.Task_ID("task_r_7"),
		chain_id           = chain1,
		owner_user_id      = other_owner,
		title              = "Task 7 Other",
		publish_state      = .Published,
		status             = .Completed,
		priority           = .P1,
		reviewer_refs_json = `[]`,
		created_at         = "2026-09-25T10:00:00Z",
		updated_at         = "2026-09-25T10:00:00Z",
	}
	iface.taskchain_save_task(&repo, t7)

	// Run rollup query
	rollups, r_err := iface.taskchain_task_counts_by_chain(&repo, owner)
	testing.expect_value(t, r_err.code, domain.Error_Code.None)
	defer delete(rollups)

	testing.expect(t, string(chain1) in rollups, "chain1 present in rollups")
	r1 := rollups[string(chain1)]
	testing.expect_value(t, r1.total_count, 6)
	testing.expect_value(t, r1.completed_count, 2) // t1 (.Completed) + t2 (.Validated_Good)
	testing.expect_value(t, r1.user_validation_count, 2) // t3 (empty []) + t4 ("type":"user")

	// chain2 has no tasks -> absent from rollup
	testing.expect(t, !(string(chain2) in rollups), "chain2 absent from rollups")
}

// --- Consolidated from taskchain_subscription_repo_test.odin ---

free_subscription :: proc(sub: ^domain.Task_Subscription) {
	delete(sub.subscription_id)
	delete(string(sub.owner_user_id))
	delete(sub.subscriber_agent_instance_id)
	delete(string(sub.chain_id))
	delete(string(sub.task_id))
	delete(sub.event_type)
	delete(sub.created_at)
}

free_subscriptions :: proc(subs: []domain.Task_Subscription) {
	for &sub in subs {
		free_subscription(&sub)
	}
	delete(subs)
}

@(test)
test_taskchain_subscription_sqlite_lifecycle :: proc(t: ^testing.T) {
	db_path := ":memory:"
	conn, open_ok, open_err := open(db_path)
	testing.expect(t, open_ok, "db open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer close(&conn)

	mig_ok, mig_err := run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	// Verify table and indexes exist
	testing.expect(t, sqlite_object_exists(&conn, "task_subscriptions"), "task_subscriptions table exists")
	testing.expect(t, sqlite_object_exists(&conn, "idx_task_sub_chain"), "idx_task_sub_chain index exists")
	testing.expect(t, sqlite_object_exists(&conn, "idx_task_sub_task"), "idx_task_sub_task index exists")

	repo_impl := Taskchain_Repo_SQLite{conn = &conn}
	repo := new_taskchain_repository(&repo_impl, &conn)

	owner := domain.User_ID("user_sub_tester")
	cid := domain.Task_Chain_ID("chain_sub_test")
	tid1 := domain.Task_ID("task_sub_test_1")
	tid2 := domain.Task_ID("task_sub_test_2")
	inst1 := "inst_worker_1"
	inst2 := "inst_worker_2"

	// 1. Initial list queries return empty slices
	subs0, err0 := iface.taskchain_list_subscriptions_by_chain(&repo, cid, owner)
	testing.expect_value(t, err0.code, domain.Error_Code.None)
	testing.expect_value(t, len(subs0), 0)
	free_subscriptions(subs0)

	subs_task0, err_task0 := iface.taskchain_list_subscriptions_by_task(&repo, tid1, owner)
	testing.expect_value(t, err_task0.code, domain.Error_Code.None)
	testing.expect_value(t, len(subs_task0), 0)
	free_subscriptions(subs_task0)

	subs_inst0, err_inst0 := iface.taskchain_list_subscriptions_by_instance(&repo, inst1, owner)
	testing.expect_value(t, err_inst0.code, domain.Error_Code.None)
	testing.expect_value(t, len(subs_inst0), 0)
	free_subscriptions(subs_inst0)

	// 2. Save chain-level subscription
	sub1 := domain.Task_Subscription{
		subscription_id              = "sub_1",
		owner_user_id                = owner,
		subscriber_agent_instance_id = inst1,
		chain_id                     = cid,
		task_id                      = "",
		event_type                   = "chain_status_changed",
		created_at                   = "2026-09-28T10:00:00Z",
	}
	saved1, ok1, s_err1 := iface.taskchain_save_subscription(&repo, sub1)
	testing.expect(t, ok1, "save sub1 ok")
	testing.expect_value(t, s_err1.code, domain.Error_Code.None)
	testing.expect_value(t, saved1.subscription_id, "sub_1")

	// 3. Save task-level subscription for same instance
	sub2 := domain.Task_Subscription{
		subscription_id              = "sub_2",
		owner_user_id                = owner,
		subscriber_agent_instance_id = inst1,
		chain_id                     = cid,
		task_id                      = tid1,
		event_type                   = "task_status_changed",
		created_at                   = "2026-09-28T10:01:00Z",
	}
	saved2, ok2, s_err2 := iface.taskchain_save_subscription(&repo, sub2)
	testing.expect(t, ok2, "save sub2 ok")
	testing.expect_value(t, s_err2.code, domain.Error_Code.None)
	testing.expect_value(t, saved2.subscription_id, "sub_2")

	// 4. Save task-level subscription for different instance (inst2) on task2
	sub3 := domain.Task_Subscription{
		subscription_id              = "sub_3",
		owner_user_id                = owner,
		subscriber_agent_instance_id = inst2,
		chain_id                     = cid,
		task_id                      = tid2,
		event_type                   = "task_status_changed",
		created_at                   = "2026-09-28T10:02:00Z",
	}
	saved3, ok3, s_err3 := iface.taskchain_save_subscription(&repo, sub3)
	testing.expect(t, ok3, "save sub3 ok")
	testing.expect_value(t, s_err3.code, domain.Error_Code.None)
	testing.expect_value(t, saved3.subscription_id, "sub_3")

	// 5. Query list by chain: should return all 3 subscriptions for chain cid
	chain_subs, c_err := iface.taskchain_list_subscriptions_by_chain(&repo, cid, owner)
	testing.expect_value(t, c_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(chain_subs), 3)
	if len(chain_subs) == 3 {
		testing.expect_value(t, chain_subs[0].subscription_id, "sub_1")
		testing.expect_value(t, chain_subs[1].subscription_id, "sub_2")
		testing.expect_value(t, chain_subs[2].subscription_id, "sub_3")
	}
	free_subscriptions(chain_subs)

	// 6. Query list by task
	task1_subs, t_err1 := iface.taskchain_list_subscriptions_by_task(&repo, tid1, owner)
	testing.expect_value(t, t_err1.code, domain.Error_Code.None)
	testing.expect_value(t, len(task1_subs), 1)
	if len(task1_subs) == 1 {
		testing.expect_value(t, task1_subs[0].subscription_id, "sub_2")
		testing.expect_value(t, task1_subs[0].subscriber_agent_instance_id, inst1)
		testing.expect_value(t, string(task1_subs[0].task_id), string(tid1))
	}
	free_subscriptions(task1_subs)

	task2_subs, t_err2 := iface.taskchain_list_subscriptions_by_task(&repo, tid2, owner)
	testing.expect_value(t, t_err2.code, domain.Error_Code.None)
	testing.expect_value(t, len(task2_subs), 1)
	if len(task2_subs) == 1 {
		testing.expect_value(t, task2_subs[0].subscription_id, "sub_3")
		testing.expect_value(t, task2_subs[0].subscriber_agent_instance_id, inst2)
		testing.expect_value(t, string(task2_subs[0].task_id), string(tid2))
	}
	free_subscriptions(task2_subs)

	// 7. Query list by instance
	inst1_subs, i_err1 := iface.taskchain_list_subscriptions_by_instance(&repo, inst1, owner)
	testing.expect_value(t, i_err1.code, domain.Error_Code.None)
	testing.expect_value(t, len(inst1_subs), 2)
	if len(inst1_subs) == 2 {
		testing.expect_value(t, inst1_subs[0].subscription_id, "sub_1")
		testing.expect_value(t, inst1_subs[1].subscription_id, "sub_2")
	}
	free_subscriptions(inst1_subs)

	inst2_subs, i_err2 := iface.taskchain_list_subscriptions_by_instance(&repo, inst2, owner)
	testing.expect_value(t, i_err2.code, domain.Error_Code.None)
	testing.expect_value(t, len(inst2_subs), 1)
	if len(inst2_subs) == 1 {
		testing.expect_value(t, inst2_subs[0].subscription_id, "sub_3")
	}
	free_subscriptions(inst2_subs)

	// 8. Test owner isolation: other user query returns empty
	other_owner := domain.User_ID("user_other")
	other_subs, o_err := iface.taskchain_list_subscriptions_by_chain(&repo, cid, other_owner)
	testing.expect_value(t, o_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(other_subs), 0)
	free_subscriptions(other_subs)

	// 9. Upsert on conflict: duplicate subscriber + chain + task + event_type updates subscription_id and created_at
	sub1_dup := domain.Task_Subscription{
		subscription_id              = "sub_1_updated",
		owner_user_id                = owner,
		subscriber_agent_instance_id = inst1,
		chain_id                     = cid,
		task_id                      = "",
		event_type                   = "chain_status_changed",
		created_at                   = "2026-09-28T10:05:00Z",
	}
	_, ok_dup, dup_err := iface.taskchain_save_subscription(&repo, sub1_dup)
	testing.expect(t, ok_dup, "save sub1_dup ok")
	testing.expect_value(t, dup_err.code, domain.Error_Code.None)

	// Total count for chain cid should still be 3 (not 4)
	chain_subs_after, c_err_after := iface.taskchain_list_subscriptions_by_chain(&repo, cid, owner)
	testing.expect_value(t, c_err_after.code, domain.Error_Code.None)
	testing.expect_value(t, len(chain_subs_after), 3)
	free_subscriptions(chain_subs_after)

	// 10. Remove subscription
	rem_ok, rem_err := iface.taskchain_remove_subscription(&repo, "sub_2", owner)
	testing.expect(t, rem_ok, "remove sub_2 ok")
	testing.expect_value(t, rem_err.code, domain.Error_Code.None)

	// Verify sub_2 removed from task1
	task1_subs_rem, _ := iface.taskchain_list_subscriptions_by_task(&repo, tid1, owner)
	testing.expect_value(t, len(task1_subs_rem), 0)
	free_subscriptions(task1_subs_rem)

	// Verify inst1 now only has 1 subscription
	inst1_subs_rem, _ := iface.taskchain_list_subscriptions_by_instance(&repo, inst1, owner)
	testing.expect_value(t, len(inst1_subs_rem), 1)
	free_subscriptions(inst1_subs_rem)

	// Removing non-existent returns false
	rem_fake_ok, rem_fake_err := iface.taskchain_remove_subscription(&repo, "non_existent_sub", owner)
	testing.expect(t, !rem_fake_ok, "remove non-existent returns false")
	testing.expect_value(t, rem_fake_err.code, domain.Error_Code.None)

	// Removing with wrong owner returns false
	rem_wrong_ok, rem_wrong_err := iface.taskchain_remove_subscription(&repo, "sub_3", other_owner)
	testing.expect(t, !rem_wrong_ok, "remove with wrong owner returns false")
	testing.expect_value(t, rem_wrong_err.code, domain.Error_Code.None)
}
