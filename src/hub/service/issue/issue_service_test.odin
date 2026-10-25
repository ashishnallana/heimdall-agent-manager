package issue

import "core:os"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"

@(test)
test_issue_service_lifecycle :: proc(t: ^testing.T) {
	db_path := "/tmp/test_issue_service.db"
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer sqlite.close(&conn)

	mig_ok, mig_err := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	repo_impl := sqlite.Issue_Repo_SQLite{conn = &conn}
	repo := sqlite.new_issue_repository(&repo_impl, &conn)

	clock := platform.real_clock()
	ids := platform.real_id_generator()
	svc := new_issue_service(&repo, &clock, &ids)

	auth := contracts.Auth_Context{
		kind    = .Session,
		user_id = "user_service_tester",
	}
	other_auth := contracts.Auth_Context{
		kind    = .Session,
		user_id = "other_user",
	}

	// 1. Validation: unauthenticated
	no_auth := contracts.Auth_Context{}
	_, na_ok, na_err := create_issue(&svc, no_auth, Issue_Create_Input{title = "Title"})
	testing.expect(t, !na_ok, "unauthenticated create fails")
	testing.expect_value(t, na_err.code, domain.Error_Code.Unauthenticated)

	// 2. Validation: empty title
	_, et_ok, et_err := create_issue(&svc, auth, Issue_Create_Input{title = "   "})
	testing.expect(t, !et_ok, "empty title fails")
	testing.expect_value(t, et_err.code, domain.Error_Code.Validation_Failed)

	// 3. Create issue
	created, cr_ok, cr_err := create_issue(&svc, auth, Issue_Create_Input{
		title       = "Backend memory leak in worker",
		description = "Memory increases on long chains",
		created_by  = "worker_42",
		scope_type  = "project",
		target_id   = "proj_beta",
		chain_id    = "chain_xyz",
	})
	testing.expect(t, cr_ok, "create issue ok")
	testing.expect_value(t, cr_err.code, domain.Error_Code.None)
	testing.expect_value(t, created.title, "Backend memory leak in worker")
	testing.expect_value(t, created.status, domain.Issue_Status.New)
	testing.expect_value(t, created.scope_type, domain.Issue_Scope_Type.Project)
	testing.expect_value(t, created.closed_at, "")
	testing.expect(t, created.created_at != "", "created_at is set")
	testing.expect(t, created.updated_at != "", "updated_at is set")

	issue_id := created.issue_id

	// 4. Owner scoping: other user cannot get
	_, og_ok, og_err := get_issue(&svc, other_auth, issue_id)
	testing.expect(t, !og_ok, "other user cannot get issue")
	testing.expect_value(t, og_err.code, domain.Error_Code.Not_Found)

	// 5. Get issue with voter check
	got, g_ok, g_err := get_issue(&svc, auth, issue_id, "voter_1")
	testing.expect(t, g_ok, "owner get issue ok")
	testing.expect_value(t, g_err.code, domain.Error_Code.None)
	testing.expect_value(t, got.has_voted, false)

	// 6. Comments
	// Empty comment fails
	_, ec_ok, ec_err := add_comment(&svc, auth, issue_id, Issue_Comment_Input{body = "  "})
	testing.expect(t, !ec_ok, "empty comment body fails")
	testing.expect_value(t, ec_err.code, domain.Error_Code.Validation_Failed)

	cmt, c_ok, c_err := add_comment(&svc, auth, issue_id, Issue_Comment_Input{
		author_id   = "voter_1",
		author_name = "Agent 1",
		body        = "I observed this leak too on chain_xyz",
	})
	testing.expect(t, c_ok, "add comment ok")
	testing.expect_value(t, c_err.code, domain.Error_Code.None)
	_ = cmt

	cmts, cmts_err := list_comments(&svc, auth, issue_id)
	testing.expect_value(t, cmts_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(cmts), 1)

	// 7. Voting & Unvoting
	v_ok, v_err := vote_issue(&svc, auth, issue_id, "voter_1", "Agent 1")
	testing.expect(t, v_ok, "vote issue ok")
	testing.expect_value(t, v_err.code, domain.Error_Code.None)

	// Duplicate vote should fail
	v_dup_ok, v_dup_err := vote_issue(&svc, auth, issue_id, "voter_1", "Agent 1")
	testing.expect(t, !v_dup_ok, "duplicate vote rejected")
	testing.expect_value(t, v_dup_err.code, domain.Error_Code.Conflict)

	// Check has_voted
	got_voted, _, _ := get_issue(&svc, auth, issue_id, "voter_1")
	testing.expect_value(t, got_voted.has_voted, true)
	testing.expect_value(t, got_voted.vote_count, 1)

	// Unvote
	unv_ok, unv_err := unvote_issue(&svc, auth, issue_id, "voter_1")
	testing.expect(t, unv_ok, "unvote issue ok")
	testing.expect_value(t, unv_err.code, domain.Error_Code.None)

	got_unvoted, _, _ := get_issue(&svc, auth, issue_id, "voter_1")
	testing.expect_value(t, got_unvoted.has_voted, false)
	testing.expect_value(t, got_unvoted.vote_count, 0)

	// 8. Status transitions & closed_at management
	// Transition to fixed -> closed_at set
	up1, up1_ok, _ := update_issue(&svc, auth, issue_id, Issue_Update_Input{
		has_status = true,
		status     = "fixed",
	})
	testing.expect(t, up1_ok, "update to fixed ok")
	testing.expect_value(t, up1.status, domain.Issue_Status.Fixed)
	testing.expect(t, up1.closed_at != "", "closed_at is set when fixed")

	// Transition back to new -> closed_at cleared
	up2, up2_ok, _ := update_issue(&svc, auth, issue_id, Issue_Update_Input{
		has_status = true,
		status     = "new",
	})
	testing.expect(t, up2_ok, "update to new ok")
	testing.expect_value(t, up2.status, domain.Issue_Status.New)
	testing.expect_value(t, up2.closed_at, "")

	// 9. List with search query
	search_list, s_err := list_issues(&svc, auth, Issue_Filter_Input{query = "memory leak"})
	testing.expect_value(t, s_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(search_list), 1)

	no_match, _ := list_issues(&svc, auth, Issue_Filter_Input{query = "nonexistent problem"})
	testing.expect_value(t, len(no_match), 0)

	// 10. Delete issue
	del_ok, del_err := delete_issue(&svc, auth, issue_id)
	testing.expect(t, del_ok, "delete issue ok")
	testing.expect_value(t, del_err.code, domain.Error_Code.None)

	_, found_after_del, _ := get_issue(&svc, auth, issue_id)
	testing.expect(t, !found_after_del, "issue not found after deletion")
}
