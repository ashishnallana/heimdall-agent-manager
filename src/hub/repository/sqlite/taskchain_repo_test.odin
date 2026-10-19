#+private file
// Behavioral tests for taskchain SQLite repository (bridge, fleet, pinned, rollup, v2 fields).
package sqlite

import domain "odin_test:hub/domain"
import "core:fmt"
import iface "odin_test:hub/repository/iface"
import "core:os"
import "core:testing"

task_chain_search_changes_destroy_test :: proc(changes: []domain.Task_Chain_Search_Change) {
	for change in changes {
		delete(string(change.chain_id))
		delete(change.operation)
	}
	delete(changes)
}

@(test)
test_task_chain_search_change_feed_is_monotonic_and_owner_scoped :: proc(t: ^testing.T) {
	conn, open_ok, open_err := open(":memory:")
	testing.expect(t, open_ok, "db open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer close(&conn)
	mig_ok, mig_err := run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	impl := Taskchain_Repo_SQLite{conn = &conn}
	repo := new_taskchain_repository(&impl, &conn)
	owner_a := domain.User_ID("user_search_a")
	owner_b := domain.User_ID("user_search_b")
	chain_a := domain.Task_Chain{
		chain_id = "chain_search_a", owner_user_id = owner_a,
		title = "vault:v2:cipher-a", description = "vault:v2:description-a",
		publish_state = .Published, status = .Active, kind = domain.CHAIN_KIND_TICKET,
		created_at = "2026-10-14T00:00:00Z", updated_at = "2026-10-14T00:00:00Z",
	}
	chain_b := domain.Task_Chain{
		chain_id = "chain_search_b", owner_user_id = owner_b,
		title = "vault:v2:cipher-b", publish_state = .Published, status = .Active,
		kind = "team_work", created_at = "2026-10-14T00:00:00Z", updated_at = "2026-10-14T00:00:00Z",
	}
	_, saved_a, _ := iface.taskchain_save_chain(&repo, chain_a)
	_, saved_b, _ := iface.taskchain_save_chain(&repo, chain_b)
	testing.expect(t, saved_a && saved_b, "fixture chains should save")

	first_revision, first_err := iface.taskchain_search_latest_revision(&repo, owner_a)
	testing.expect_value(t, first_err.code, domain.Error_Code.None)
	testing.expect(t, first_revision > 0, "owner snapshot should have a watermark")
	initial, initial_err := iface.taskchain_search_list_changes(&repo, owner_a, 0, 100)
	testing.expect_value(t, initial_err.code, domain.Error_Code.None)
	defer task_chain_search_changes_destroy_test(initial)
	testing.expect_value(t, len(initial), 1)
	if len(initial) == 1 {
		testing.expect_value(t, initial[0].chain_id, domain.Task_Chain_ID("chain_search_a"))
		testing.expect_value(t, initial[0].operation, "upsert")
	}

	chain_a.title = "vault:v2:cipher-a2"
	chain_a.updated_at = "2026-10-14T00:01:00Z"
	_, updated, _ := iface.taskchain_save_chain(&repo, chain_a)
	testing.expect(t, updated, "chain update should save")
	delta, delta_err := iface.taskchain_search_list_changes(&repo, owner_a, first_revision, 100)
	testing.expect_value(t, delta_err.code, domain.Error_Code.None)
	defer task_chain_search_changes_destroy_test(delta)
	testing.expect_value(t, len(delta), 1)
	if len(delta) == 1 do testing.expect_value(t, delta[0].operation, "upsert")

	before_delete, _ := iface.taskchain_search_latest_revision(&repo, owner_a)
	testing.expect(t, exec(&conn, "DELETE FROM task_chains WHERE chain_id = 'chain_search_a';"), "chain delete should succeed")
	tombstones, tombstone_err := iface.taskchain_search_list_changes(&repo, owner_a, before_delete, 100)
	testing.expect_value(t, tombstone_err.code, domain.Error_Code.None)
	defer task_chain_search_changes_destroy_test(tombstones)
	testing.expect_value(t, len(tombstones), 1)
	if len(tombstones) == 1 do testing.expect_value(t, tombstones[0].operation, "delete")

	owner_b_changes, owner_b_err := iface.taskchain_search_list_changes(&repo, owner_b, 0, 100)
	testing.expect_value(t, owner_b_err.code, domain.Error_Code.None)
	defer task_chain_search_changes_destroy_test(owner_b_changes)
	testing.expect_value(t, len(owner_b_changes), 1)
}

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
		state              = .Ready,
		priority           = .P2,
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
		state              = .Ready,
		priority           = .P1,
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
		kind          = domain.CHAIN_KIND_TICKET,
		created_at    = "2026-09-25T10:00:00Z",
		updated_at    = "2026-09-25T10:00:00Z",
	}
	_, s1_ok, _ := iface.taskchain_save_chain(&repo, c1)
	testing.expect(t, s1_ok, "save chain 1 ok")

	// Tasks in chain 1 (Task System v2): the rollup counts `state='done'` as
	// completed and `state='in_review' AND requires_user_approval` as awaiting
	// user validation. Nothing else contributes beyond total_count.
	rollup_task :: proc(id: string, chain: domain.Task_Chain_ID, owner: domain.User_ID, state: domain.Task_State, requires_user_approval: bool) -> domain.Task {
		return domain.Task{
			task_id                = domain.Task_ID(id),
			chain_id               = chain,
			owner_user_id          = owner,
			title                  = id,
			publish_state          = .Published,
			state                  = state,
			kind                   = .Task,
			priority               = .P1,
			brief_json             = `{"goal":"rollup"}`,
			requires_user_approval = requires_user_approval,
			created_at             = "2026-09-25T10:00:00Z",
			updated_at             = "2026-09-25T10:00:00Z",
		}
	}
	// Task 1: done
	iface.taskchain_save_task(&repo, rollup_task("task_r_1", chain1, owner, .Done, false))
	// Task 2: done (also with the user-approval flag — still only "completed")
	iface.taskchain_save_task(&repo, rollup_task("task_r_2", chain1, owner, .Done, true))
	// Task 3: in_review awaiting the user → user_validation
	iface.taskchain_save_task(&repo, rollup_task("task_r_3", chain1, owner, .In_Review, true))
	// Task 4: in_review awaiting the user → user_validation
	iface.taskchain_save_task(&repo, rollup_task("task_r_4", chain1, owner, .In_Review, true))
	// Task 5: in_review by agents only (must NOT count as user_validation)
	iface.taskchain_save_task(&repo, rollup_task("task_r_5", chain1, owner, .In_Review, false))
	// Task 6: in_progress (requires approval later, but not in review yet)
	iface.taskchain_save_task(&repo, rollup_task("task_r_6", chain1, owner, .In_Progress, true))
	// Task 7: other owner task in chain 1 (must NOT be counted)
	iface.taskchain_save_task(&repo, rollup_task("task_r_7", chain1, other_owner, .Done, false))

	// Run rollup query
	rollups, r_err := iface.taskchain_task_counts_by_chain(&repo, owner)
	testing.expect_value(t, r_err.code, domain.Error_Code.None)
	defer delete(rollups)

	testing.expect(t, string(chain1) in rollups, "chain1 present in rollups")
	r1 := rollups[string(chain1)]
	testing.expect_value(t, r1.total_count, 6)
	testing.expect_value(t, r1.completed_count, 2) // t1 + t2 (state = done)
	testing.expect_value(t, r1.user_validation_count, 2) // t3 + t4 (in_review AND requires_user_approval)

	// chain2 has no tasks -> absent from rollup
	testing.expect(t, !(string(chain2) in rollups), "chain2 absent from rollups")
}

// --- Task System v2 column round-trips ---

@(test)
test_task_v2_fields_sqlite_roundtrip :: proc(t: ^testing.T) {
	conn, open_ok, _ := open(":memory:")
	testing.expect(t, open_ok, "db open ok")
	defer close(&conn)
	mig_ok, mig_err := run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	for col in ([?]string{"state", "kind", "attempt_no", "brief_json", "blocked_on_json", "requires_user_approval", "ready_since", "stage_key", "stage_index", "generated_by_json"}) {
		testing.expectf(t, table_column_exists(&conn, "tasks", col), "tasks.%s column exists", col)
	}
	testing.expect(t, table_column_exists(&conn, "task_chain_fleets", "roles_json"), "task_chain_fleets.roles_json column exists")
	testing.expect(t, table_column_exists(&conn, "task_chain_fleets", "bridge_id"), "task_chain_fleets.bridge_id column exists")
	testing.expect(t, table_column_exists(&conn, "task_chains", "workflow_def_ref"), "task_chains.workflow_def_ref column exists")
	testing.expect(t, table_column_exists(&conn, "task_chains", "defaults_json"), "task_chains.defaults_json column exists")

	repo_impl := Taskchain_Repo_SQLite{conn = &conn}
	repo := new_taskchain_repository(&repo_impl, &conn)

	owner := domain.User_ID("user_v2_fields")
	cid := domain.Task_Chain_ID("chain_v2_fields")

	chain := domain.Task_Chain{
		chain_id               = cid,
		owner_user_id          = owner,
		title                  = "V2 Fields Chain",
		publish_state          = .Published,
		status                 = .Active,
		kind                   = domain.CHAIN_KIND_WORKFLOW,
		workflow_def_ref       = "wf_def_1@3",
		workflow_snapshot_json = `{"def_id":"wf_def_1","version":3,"inputs":{"repo":"x"}}`,
		defaults_json          = `{"auto_submit":true}`,
		created_at             = "2026-10-01T10:00:00Z",
		updated_at             = "2026-10-01T10:00:00Z",
		published_at           = "2026-10-01T10:00:00Z",
	}
	_, sc_ok, sc_err := iface.taskchain_save_chain(&repo, chain)
	testing.expect(t, sc_ok, "save chain ok")
	testing.expect_value(t, sc_err.code, domain.Error_Code.None)
	got_chain, gc_ok, _ := iface.taskchain_get_chain(&repo, cid)
	testing.expect(t, gc_ok, "get chain ok")
	testing.expect_value(t, got_chain.kind, domain.CHAIN_KIND_WORKFLOW)
	testing.expect_value(t, got_chain.workflow_def_ref, "wf_def_1@3")
	testing.expect_value(t, got_chain.workflow_snapshot_json, `{"def_id":"wf_def_1","version":3,"inputs":{"repo":"x"}}`)
	testing.expect_value(t, got_chain.defaults_json, `{"auto_submit":true}`)

	// Every Task_State / Task_Kind value survives the string mapping.
	for state in domain.Task_State {
		back, ok := domain.task_state_from_string(domain.task_state_string(state))
		testing.expectf(t, ok && back == state, "task state %v must round-trip through its string", state)
	}

	task := domain.Task{
		task_id                = "task_v2_fields",
		chain_id               = cid,
		owner_user_id          = owner,
		title                  = "V2 Task",
		description            = "desc",
		publish_state          = .Published,
		state                  = .In_Review,
		kind                   = .Gate,
		priority               = .P0,
		attempt_no             = 3,
		brief_json             = `{"goal":"ship it","acceptance":["a"],"verify":"make test","inputs":[],"review_roles":["reviewer"],"assignee":"agt_w","budget":{"max_attempts":2}}`,
		blocked_on_json        = `{"kind":"human","reason":"needs decision","since":"2026-10-01T10:05:00Z"}`,
		requires_user_approval = true,
		ready_since            = "2026-10-01T10:02:00Z",
		bridge_id              = "brg_v2",
		stage_key              = "stage.review",
		stage_index            = 4,
		generated_by_json      = `{"kind":"workflow","stage":"review"}`,
		created_at             = "2026-10-01T10:01:00Z",
		updated_at             = "2026-10-01T10:01:00Z",
		published_at           = "2026-10-01T10:01:00Z",
		started_at             = "2026-10-01T10:03:00Z",
	}
	_, st_ok, st_err := iface.taskchain_save_task(&repo, task)
	testing.expect(t, st_ok, "save task ok")
	testing.expect_value(t, st_err.code, domain.Error_Code.None)

	check_task :: proc(t: ^testing.T, got: domain.Task, label: string) {
		testing.expectf(t, got.state == .In_Review, "%s: state %v", label, got.state)
		testing.expectf(t, got.kind == .Gate, "%s: kind %v", label, got.kind)
		testing.expectf(t, got.priority == .P0, "%s: priority %v", label, got.priority)
		testing.expectf(t, got.attempt_no == 3, "%s: attempt_no %d", label, got.attempt_no)
		testing.expectf(t, got.brief_json == `{"goal":"ship it","acceptance":["a"],"verify":"make test","inputs":[],"review_roles":["reviewer"],"assignee":"agt_w","budget":{"max_attempts":2}}`, "%s: brief_json %s", label, got.brief_json)
		testing.expectf(t, got.blocked_on_json == `{"kind":"human","reason":"needs decision","since":"2026-10-01T10:05:00Z"}`, "%s: blocked_on_json %s", label, got.blocked_on_json)
		testing.expectf(t, got.requires_user_approval, "%s: requires_user_approval", label)
		testing.expectf(t, got.ready_since == "2026-10-01T10:02:00Z", "%s: ready_since %s", label, got.ready_since)
		testing.expectf(t, got.bridge_id == "brg_v2", "%s: bridge_id %s", label, got.bridge_id)
		testing.expectf(t, got.stage_key == "stage.review", "%s: stage_key %s", label, got.stage_key)
		testing.expectf(t, got.stage_index == 4, "%s: stage_index %d", label, got.stage_index)
		testing.expectf(t, got.generated_by_json == `{"kind":"workflow","stage":"review"}`, "%s: generated_by_json %s", label, got.generated_by_json)
		testing.expectf(t, got.started_at == "2026-10-01T10:03:00Z", "%s: started_at %s", label, got.started_at)
	}
	got, g_ok, _ := iface.taskchain_get_task(&repo, "task_v2_fields")
	testing.expect(t, g_ok, "get task ok")
	check_task(t, got, "get")
	listed, l_err := iface.taskchain_list_tasks_by_chain(&repo, cid, owner)
	defer delete(listed)
	testing.expect_value(t, l_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(listed), 1)
	if len(listed) == 1 do check_task(t, listed[0], "list")

	// UPSERT path: every v2 column is updated, not just inserted.
	got.state = .Done
	got.kind = .Task
	got.attempt_no = 4
	got.blocked_on_json = ""
	got.requires_user_approval = false
	got.ready_since = ""
	got.stage_key = "stage.done"
	got.stage_index = 5
	got.completed_at = "2026-10-01T11:00:00Z"
	_, u_ok, _ := iface.taskchain_save_task(&repo, got)
	testing.expect(t, u_ok, "re-save task ok")
	again, a_ok, _ := iface.taskchain_get_task(&repo, "task_v2_fields")
	testing.expect(t, a_ok, "get task after upsert ok")
	testing.expect_value(t, again.state, domain.Task_State.Done)
	testing.expect_value(t, again.kind, domain.Task_Kind.Task)
	testing.expect_value(t, again.attempt_no, 4)
	testing.expect_value(t, again.blocked_on_json, "")
	testing.expect(t, !again.requires_user_approval, "requires_user_approval cleared")
	testing.expect_value(t, again.ready_since, "")
	testing.expect_value(t, again.stage_key, "stage.done")
	testing.expect_value(t, again.stage_index, 5)
	testing.expect_value(t, again.completed_at, "2026-10-01T11:00:00Z")

	// Fleet: roles_json + bridge_id round-trip through upsert, ensure and list.
	_, f_err := iface.taskchain_upsert_fleet(&repo, domain.Task_Chain_Fleet{
		task_chain_id    = cid,
		agent_id         = "agt_reviewer",
		capacity         = 2,
		min_warm         = 0,
		idle_ttl_seconds = 120,
		roles_json       = `["worker","reviewer"]`,
		bridge_id        = "brg_fleet",
		created_at       = "2026-10-01T10:00:00Z",
		updated_at       = "2026-10-01T10:00:00Z",
	})
	testing.expect_value(t, f_err.code, domain.Error_Code.None)
	// ensure with an empty roles_json: the default ["worker"] is stored.
	e_err := iface.taskchain_ensure_fleet(&repo, domain.Task_Chain_Fleet{
		task_chain_id    = cid,
		agent_id         = "agt_default",
		capacity         = 1,
		idle_ttl_seconds = 600,
		created_at       = "2026-10-01T10:00:01Z",
		updated_at       = "2026-10-01T10:00:01Z",
	})
	testing.expect_value(t, e_err.code, domain.Error_Code.None)
	fleets, fl_err := iface.taskchain_list_fleets_by_chain(&repo, cid, owner)
	defer delete(fleets)
	testing.expect_value(t, fl_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(fleets), 2)
	for f in fleets {
		switch f.agent_id {
		case "agt_reviewer":
			testing.expect_value(t, f.roles_json, `["worker","reviewer"]`)
			testing.expect_value(t, f.bridge_id, "brg_fleet")
		case "agt_default":
			testing.expect_value(t, f.roles_json, domain.FLEET_ROLES_DEFAULT_JSON)
			testing.expect_value(t, f.bridge_id, "")
		case:
			testing.expectf(t, false, "unexpected fleet row %s", f.agent_id)
		}
	}
	// Upsert updates roles_json/bridge_id on the existing row.
	_, f2_err := iface.taskchain_upsert_fleet(&repo, domain.Task_Chain_Fleet{
		task_chain_id    = cid,
		agent_id         = "agt_reviewer",
		capacity         = 2,
		idle_ttl_seconds = 120,
		roles_json       = `["reviewer"]`,
		bridge_id        = "",
		created_at       = "2026-10-01T10:00:00Z",
		updated_at       = "2026-10-01T10:10:00Z",
	})
	testing.expect_value(t, f2_err.code, domain.Error_Code.None)
	fleets2, _ := iface.taskchain_list_fleets_by_chain(&repo, cid, owner)
	defer delete(fleets2)
	for f in fleets2 do if f.agent_id == "agt_reviewer" {
		testing.expect_value(t, f.roles_json, `["reviewer"]`)
		testing.expect_value(t, f.bridge_id, "")
	}
}
