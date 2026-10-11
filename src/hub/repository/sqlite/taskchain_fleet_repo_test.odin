package sqlite

import "core:fmt"
import "core:os"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(test)
test_taskchain_fleet_sqlite_lifecycle :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_taskchain_fleet_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, open_err := open(db_path)
	testing.expect(t, open_ok, "db open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer close(&conn)

	mig_ok, mig_err := run_migrations(&conn)
	if !mig_ok do fmt.println("MIG ERR:", mig_err.message)
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
