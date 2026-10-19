package taskchain

import "core:fmt"
import "core:os"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import agent_service "odin_test:hub/service/agent"

@(test)
test_valid_chain_transitions_with_archived :: proc(t: ^testing.T) {
	// Active transitions
	testing.expect(t, valid_chain_transition(.Active, .Archived), "Active -> Archived must be valid")
	testing.expect(t, valid_chain_transition(.Active, .Completed), "Active -> Completed must be valid")
	testing.expect(t, valid_chain_transition(.Active, .Cancelled), "Active -> Cancelled must be valid")
	testing.expect(t, valid_chain_transition(.Active, .Active), "Active -> Active must be valid")

	// Completed transitions
	testing.expect(t, valid_chain_transition(.Completed, .Archived), "Completed -> Archived must be valid")
	testing.expect(t, valid_chain_transition(.Completed, .Active), "Completed -> Active must be valid")
	testing.expect(t, valid_chain_transition(.Completed, .Completed), "Completed -> Completed must be valid")
	testing.expect(t, !valid_chain_transition(.Completed, .Cancelled), "Completed -> Cancelled must be invalid")

	// Cancelled transitions
	testing.expect(t, valid_chain_transition(.Cancelled, .Archived), "Cancelled -> Archived must be valid")
	testing.expect(t, valid_chain_transition(.Cancelled, .Cancelled), "Cancelled -> Cancelled must be valid")
	testing.expect(t, !valid_chain_transition(.Cancelled, .Active), "Cancelled -> Active must be invalid")
	testing.expect(t, !valid_chain_transition(.Cancelled, .Completed), "Cancelled -> Completed must be invalid")

	// Archived transitions
	testing.expect(t, valid_chain_transition(.Archived, .Active), "Archived -> Active (restore) must be valid")
	testing.expect(t, valid_chain_transition(.Archived, .Archived), "Archived -> Archived must be valid")
	testing.expect(t, !valid_chain_transition(.Archived, .Completed), "Archived -> Completed must be invalid")
	testing.expect(t, !valid_chain_transition(.Archived, .Cancelled), "Archived -> Cancelled must be invalid")
}

@(test)
test_chain_status_from_string_archived :: proc(t: ^testing.T) {
	testing.expect_value(t, chain_status_from_string("archived"), domain.Task_Chain_Status.Archived)
	testing.expect_value(t, chain_status_from_string("active"), domain.Task_Chain_Status.Active)
	testing.expect_value(t, chain_status_from_string("completed"), domain.Task_Chain_Status.Completed)
	testing.expect_value(t, chain_status_from_string("cancelled"), domain.Task_Chain_Status.Cancelled)
	testing.expect_value(t, chain_status_from_string("unknown"), domain.Task_Chain_Status.Active)
}

// Task System v2 §0: chain kind vocabulary is {ticket, workflow}. The pre-v2
// default "team_work" is accepted as an alias for ticket at create time only;
// "" means ticket; anything else is a validation failure.
@(test)
test_all_chain_creations_use_mixed_work :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_chain_kind_alias_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, _ := sqlite.open(db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	defer sqlite.close(&conn)
	mig_ok, _ := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")

	tc_impl := sqlite.Taskchain_Repo_SQLite{conn = &conn}
	tc_repo := sqlite.new_taskchain_repository(&tc_impl, &conn)
	ag_impl := sqlite.Agent_Repo_SQLite{conn = &conn}
	ag_repo := sqlite.new_agent_repository(&ag_impl, &conn)
	clock := platform.real_clock()
	ids := platform.real_id_generator()
	svc := new_taskchain_service(&tc_repo, &ag_repo, &clock, &ids)

	auth := contracts.Auth_Context{kind = .User_Token, user_id = "user_kind_alias"}

	Case :: struct { input, want: string }
	cases := [?]Case{
		{"mixed_work", domain.CHAIN_KIND_MIXED_WORK},
		{"", domain.CHAIN_KIND_MIXED_WORK},
	}
	for c in cases {
		chain, ok, err := create_chain(&svc, auth, Create_Chain_Input{title = "kind alias", kind = c.input})
		testing.expectf(t, ok, "create_chain(kind=%q) must succeed: %v", c.input, err.message)
		testing.expectf(t, chain.kind == c.want, "kind %q: stored %q, want %q", c.input, chain.kind, c.want)
		persisted, got, _ := iface.taskchain_get_chain(&tc_repo, chain.chain_id)
		testing.expect(t, got, "chain must be persisted")
		testing.expectf(t, persisted.kind == c.want, "kind %q: persisted %q, want %q", c.input, persisted.kind, c.want)
	}

	_, bad_ok, bad_err := create_chain(&svc, auth, Create_Chain_Input{title = "kind alias", kind = "swarm"})
	testing.expect(t, !bad_ok, "unknown chain kind must be rejected")
	testing.expect_value(t, bad_err.code, domain.Error_Code.Validation_Failed)
}


// REQ-TB-1: create/update carry tasks.bridge_id; a non-empty pin must reference
// an existing bridge owned by the chain owner (unknown/foreign -> error, nothing
// persisted); empty is always accepted (inherit); PATCH absence leaves the pin
// untouched while PATCH "" clears it back to inherit.
@(test)
test_task_bridge_id_create_and_update_validation :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_task_bridge_svc_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer sqlite.close(&conn)

	mig_ok, mig_err := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	tc_impl := sqlite.Taskchain_Repo_SQLite{conn = &conn}
	tc_repo := sqlite.new_taskchain_repository(&tc_impl, &conn)

	ag_impl := sqlite.Agent_Repo_SQLite{conn = &conn}
	ag_repo := sqlite.new_agent_repository(&ag_impl, &conn)

	br_impl := sqlite.Bridge_Repo_SQLite{conn = &conn}
	br_repo := sqlite.new_bridge_repository(&br_impl, &conn)

	clock := platform.real_clock()
	ids := platform.real_id_generator()

	ag_svc := agent_service.new_agent_service(&ag_repo, &br_repo, &clock, &ids)
	svc := new_taskchain_service(&tc_repo, &ag_repo, &clock, &ids)
	svc.agent_service = &ag_svc

	owner := domain.User_ID("user_tb_svc")
	other := domain.User_ID("user_tb_other")
	cid := domain.Task_Chain_ID("chain_tb_svc")

	// Two bridges owned by the chain owner plus one owned by someone else.
	_, _, _ = iface.bridge_save_bridge(&br_repo, domain.Bridge{
		bridge_id        = "brg_tb_own",
		owner_user_id    = owner,
		machine_hostname = "localhost",
		status           = .Online,
		created_at       = "2026-09-25T10:00:00Z",
		updated_at       = "2026-09-25T10:00:00Z",
	})
	_, _, _ = iface.bridge_save_bridge(&br_repo, domain.Bridge{
		bridge_id        = "brg_tb_own2",
		owner_user_id    = owner,
		machine_hostname = "localhost",
		status           = .Online,
		created_at       = "2026-09-25T10:00:00Z",
		updated_at       = "2026-09-25T10:00:00Z",
	})
	_, _, _ = iface.bridge_save_bridge(&br_repo, domain.Bridge{
		bridge_id        = "brg_tb_foreign",
		owner_user_id    = other,
		machine_hostname = "localhost",
		status           = .Online,
		created_at       = "2026-09-25T10:00:00Z",
		updated_at       = "2026-09-25T10:00:00Z",
	})

	// Draft chain keeps the create/update notification paths out of the way;
	// empty assignee defaults to the owner user ref, which validates cleanly.
	_, _, _ = iface.taskchain_save_chain(&tc_repo, domain.Task_Chain{
		chain_id      = cid,
		owner_user_id = owner,
		title         = "Task Bridge Service Chain",
		publish_state = .Draft,
		status        = .Active,
		kind          = "tb_test",
		created_at    = "2026-09-25T10:00:00Z",
		updated_at    = "2026-09-25T10:00:00Z",
	})

	auth := contracts.Auth_Context{kind = .User_Token, user_id = string(owner)}

	count_chain_tasks :: proc(repo: ^iface.Taskchain_Repository, cid: domain.Task_Chain_ID, owner: domain.User_ID) -> int {
		tasks, err := iface.taskchain_list_tasks_by_chain(repo, cid, owner)
		if err.code != .None do return -1
		return len(tasks)
	}

	// 1. Create with a valid owner bridge: persisted.
	created, c_ok, c_err := create_task(&svc, auth, Create_Task_Input{chain_id = cid, title = "Pinned Task", bridge_id = "brg_tb_own"})
	testing.expect(t, c_ok, "create with owner bridge ok")
	testing.expect_value(t, c_err.code, domain.Error_Code.None)
	testing.expect_value(t, created.bridge_id, "brg_tb_own")
	roundtrip, r_ok, _ := iface.taskchain_get_task(&tc_repo, created.task_id)
	testing.expect(t, r_ok, "repo roundtrip of pinned task ok")
	testing.expect_value(t, roundtrip.bridge_id, "brg_tb_own")

	// 2. Create with empty bridge_id: inherit.
	inherited, i_ok, i_err := create_task(&svc, auth, Create_Task_Input{chain_id = cid, title = "Inherit Task"})
	testing.expect(t, i_ok, "create with empty bridge ok")
	testing.expect_value(t, i_err.code, domain.Error_Code.None)
	testing.expect_value(t, inherited.bridge_id, "")
	testing.expect_value(t, count_chain_tasks(&tc_repo, cid, owner), 2)

	// 3. Create with an unknown bridge: rejected, nothing persisted.
	_, u_ok, u_err := create_task(&svc, auth, Create_Task_Input{chain_id = cid, title = "Unknown Bridge Task", bridge_id = "brg_tb_missing"})
	testing.expect(t, !u_ok, "create with unknown bridge rejected")
	testing.expect_value(t, u_err.code, domain.Error_Code.Not_Found)
	testing.expect_value(t, count_chain_tasks(&tc_repo, cid, owner), 2)

	// 4. Create with a foreign bridge: rejected as Not_Found (no existence leak),
	// nothing persisted.
	_, f_ok, f_err := create_task(&svc, auth, Create_Task_Input{chain_id = cid, title = "Foreign Bridge Task", bridge_id = "brg_tb_foreign"})
	testing.expect(t, !f_ok, "create with foreign bridge rejected")
	testing.expect_value(t, f_err.code, domain.Error_Code.Not_Found)
	testing.expect_value(t, count_chain_tasks(&tc_repo, cid, owner), 2)

	// 5. PATCH without the field: pin untouched.
	kept, k_ok, k_err := update_task(&svc, auth, created.task_id, Update_Task_Input{title = "Pinned Task v2"})
	testing.expect(t, k_ok, "patch without bridge_id ok")
	testing.expect_value(t, k_err.code, domain.Error_Code.None)
	testing.expect_value(t, kept.bridge_id, "brg_tb_own")

	// 6. PATCH with empty string: clears to inherit.
	clear_val := ""
	cleared, cl_ok, cl_err := update_task(&svc, auth, created.task_id, Update_Task_Input{title = "Pinned Task v3", bridge_id = &clear_val})
	testing.expect(t, cl_ok, "patch with empty bridge_id ok")
	testing.expect_value(t, cl_err.code, domain.Error_Code.None)
	testing.expect_value(t, cleared.bridge_id, "")

	// 7. PATCH with another valid owner bridge: repins.
	repin_val := "brg_tb_own2"
	repinned, rp_ok, rp_err := update_task(&svc, auth, created.task_id, Update_Task_Input{title = "Pinned Task v4", bridge_id = &repin_val})
	testing.expect(t, rp_ok, "patch with second owner bridge ok")
	testing.expect_value(t, rp_err.code, domain.Error_Code.None)
	testing.expect_value(t, repinned.bridge_id, "brg_tb_own2")

	// 8. PATCH with an unknown bridge: rejected, pin unchanged on disk.
	missing_val := "brg_tb_missing"
	_, pu_ok, pu_err := update_task(&svc, auth, created.task_id, Update_Task_Input{title = "Should Not Save", bridge_id = &missing_val})
	testing.expect(t, !pu_ok, "patch with unknown bridge rejected")
	testing.expect_value(t, pu_err.code, domain.Error_Code.Not_Found)
	after_unknown, au_ok, _ := iface.taskchain_get_task(&tc_repo, created.task_id)
	testing.expect(t, au_ok, "get task after rejected patch ok")
	testing.expect_value(t, after_unknown.bridge_id, "brg_tb_own2")

	// 9. PATCH with a foreign bridge: rejected, pin unchanged on disk.
	foreign_val := "brg_tb_foreign"
	_, pf_ok, pf_err := update_task(&svc, auth, created.task_id, Update_Task_Input{title = "Should Not Save Either", bridge_id = &foreign_val})
	testing.expect(t, !pf_ok, "patch with foreign bridge rejected")
	testing.expect_value(t, pf_err.code, domain.Error_Code.Not_Found)
	after_foreign, af_ok, _ := iface.taskchain_get_task(&tc_repo, created.task_id)
	testing.expect(t, af_ok, "get task after rejected foreign patch ok")
	testing.expect_value(t, after_foreign.bridge_id, "brg_tb_own2")

	// 10. Fail-closed: a non-empty pin cannot be validated without a bridges
	// store (an unwired service), while empty/inherit stays accepted.
	unwired := new_taskchain_service(&tc_repo, &ag_repo, &clock, &ids)
	_, w_ok, w_err := create_task(&unwired, auth, Create_Task_Input{chain_id = cid, title = "Unwired Pin", bridge_id = "brg_tb_own"})
	testing.expect(t, !w_ok, "unwired service rejects non-empty bridge_id")
	testing.expect_value(t, w_err.code, domain.Error_Code.Internal_Error)
	_, we_ok, we_err := create_task(&unwired, auth, Create_Task_Input{chain_id = cid, title = "Unwired Inherit"})
	testing.expect(t, we_ok, "unwired service accepts empty bridge_id")
	testing.expect_value(t, we_err.code, domain.Error_Code.None)
}
