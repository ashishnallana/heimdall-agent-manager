package sqlite

import "core:fmt"
import "core:os"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(test)
test_issue_sqlite_lifecycle :: proc(t: ^testing.T) {
	db_path := ":memory:"
	conn, open_ok, open_err := open(db_path)
	testing.expect(t, open_ok, "db open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer close(&conn)

	mig_ok, mig_err := run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	// Verify tables exist
	testing.expect(t, sqlite_object_exists(&conn, "issues"), "issues table exists")
	testing.expect(t, sqlite_object_exists(&conn, "issue_comments"), "issue_comments table exists")
	testing.expect(t, sqlite_object_exists(&conn, "issue_votes"), "issue_votes table exists")

	repo_impl := Issue_Repo_SQLite{conn = &conn}
	repo := new_issue_repository(&repo_impl, &conn)

	owner := domain.User_ID("user_issue_tester")

	// 1. Create issue
	iss1 := domain.Issue{
		issue_id      = domain.Issue_ID("iss_test_01"),
		owner_user_id = owner,
		title         = "Test issue title",
		description   = "Markdown description of the problem",
		created_by    = "agent_worker_42",
		status        = .New,
		scope_type    = .Project,
		target_id     = "proj_alpha",
		chain_id      = "chain_123",
		created_at    = "2026-09-22T12:00:00Z",
		updated_at    = "2026-09-22T12:00:00Z",
		closed_at     = "",
	}

	saved, save_ok, save_err := iface.issue_save(&repo, iss1)
	testing.expect(t, save_ok, "save issue ok")
	testing.expect_value(t, save_err.code, domain.Error_Code.None)
	testing.expect_value(t, saved.title, "Test issue title")

	// 2. Get issue
	got, get_ok, get_err := iface.issue_get(&repo, domain.Issue_ID("iss_test_01"), owner)
	testing.expect(t, get_ok, "get issue ok")
	testing.expect_value(t, get_err.code, domain.Error_Code.None)
	testing.expect_value(t, got.title, "Test issue title")
	testing.expect_value(t, got.status, domain.Issue_Status.New)
	testing.expect_value(t, got.scope_type, domain.Issue_Scope_Type.Project)
	testing.expect_value(t, got.vote_count, 0)
	testing.expect_value(t, got.comment_count, 0)

	// 3. List issues with filters
	list, list_err := iface.issue_list(&repo, domain.Issue_Filter{
		owner_user_id = owner,
		status        = "new",
	})
	testing.expect_value(t, list_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(list), 1)

	// Filter by non-matching status
	empty_list, _ := iface.issue_list(&repo, domain.Issue_Filter{
		owner_user_id = owner,
		status        = "fixed",
	})
	testing.expect_value(t, len(empty_list), 0)

	// 4. Update issue status to Fixed
	got.status = .Fixed
	got.closed_at = "2026-09-22T13:00:00Z"
	got.updated_at = "2026-09-22T13:00:00Z"
	updated, update_ok, update_err := iface.issue_update(&repo, got)
	testing.expect(t, update_ok, "update issue ok")
	testing.expect_value(t, update_err.code, domain.Error_Code.None)
	testing.expect_value(t, updated.status, domain.Issue_Status.Fixed)

	// 5. Comments
	cmt1 := domain.Issue_Comment{
		comment_id    = domain.Issue_Comment_ID("icmt_01"),
		issue_id      = domain.Issue_ID("iss_test_01"),
		owner_user_id = owner,
		author_id     = "tanmay",
		author_name   = "Tanmay",
		body          = "First comment on issue",
		created_at    = "2026-09-22T12:05:00Z",
		updated_at    = "2026-09-22T12:05:00Z",
	}
	cmt_saved, cmt_ok, cmt_err := iface.issue_save_comment(&repo, cmt1)
	testing.expect(t, cmt_ok, "save comment ok")
	testing.expect_value(t, cmt_err.code, domain.Error_Code.None)
	_ = cmt_saved

	comments, cmts_err := iface.issue_list_comments(&repo, domain.Issue_ID("iss_test_01"), owner)
	testing.expect_value(t, cmts_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(comments), 1)
	testing.expect_value(t, comments[0].body, "First comment on issue")

	// 6. Voting
	vote1 := domain.Issue_Vote{
		issue_id      = domain.Issue_ID("iss_test_01"),
		voter_id      = "voter_user_1",
		owner_user_id = owner,
		voter_name    = "User One",
		created_at    = "2026-09-22T12:10:00Z",
	}
	vok, verr := iface.issue_save_vote(&repo, vote1)
	testing.expect(t, vok, "first vote ok")
	testing.expect_value(t, verr.code, domain.Error_Code.None)

	// Duplicate vote must fail (enforce unique constraint)
	vok_dup, verr_dup := iface.issue_save_vote(&repo, vote1)
	testing.expect(t, !vok_dup, "duplicate vote rejected")
	testing.expect_value(t, verr_dup.code, domain.Error_Code.Conflict)

	// Add second vote from different voter
	vote2 := domain.Issue_Vote{
		issue_id      = domain.Issue_ID("iss_test_01"),
		voter_id      = "voter_agent_2",
		owner_user_id = owner,
		voter_name    = "Worker 42",
		created_at    = "2026-09-22T12:15:00Z",
	}
	vok2, _ := iface.issue_save_vote(&repo, vote2)
	testing.expect(t, vok2, "second vote ok")

	vc, _ := iface.issue_vote_count(&repo, domain.Issue_ID("iss_test_01"))
	testing.expect_value(t, vc, 2)

	has_v, _ := iface.issue_has_voted(&repo, domain.Issue_ID("iss_test_01"), "voter_user_1")
	testing.expect(t, has_v, "voter_user_1 has voted")

	has_not, _ := iface.issue_has_voted(&repo, domain.Issue_ID("iss_test_01"), "unknown_voter")
	testing.expect(t, !has_not, "unknown_voter has not voted")

	// Remove vote
	unv_ok, _ := iface.issue_remove_vote(&repo, domain.Issue_ID("iss_test_01"), "voter_user_1", owner)
	testing.expect(t, unv_ok, "remove vote ok")

	vc_after, _ := iface.issue_vote_count(&repo, domain.Issue_ID("iss_test_01"))
	testing.expect_value(t, vc_after, 1)

	// 7. Verify comment_count and vote_count rollup on get
	got_counts, _, _ := iface.issue_get(&repo, domain.Issue_ID("iss_test_01"), owner)
	testing.expect_value(t, got_counts.vote_count, 1)
	testing.expect_value(t, got_counts.comment_count, 1)

	// 8. Delete issue and verify CASCADE delete of comments and votes
	del_ok, del_err := iface.issue_delete(&repo, domain.Issue_ID("iss_test_01"), owner)
	testing.expect(t, del_ok, "delete issue ok")
	testing.expect_value(t, del_err.code, domain.Error_Code.None)

	_, found_after_del, _ := iface.issue_get(&repo, domain.Issue_ID("iss_test_01"), owner)
	testing.expect(t, !found_after_del, "issue deleted")

	cmts_after_del, _ := iface.issue_list_comments(&repo, domain.Issue_ID("iss_test_01"), owner)
	testing.expect_value(t, len(cmts_after_del), 0)

	votes_after_del, _ := iface.issue_list_votes(&repo, domain.Issue_ID("iss_test_01"))
	testing.expect_value(t, len(votes_after_del), 0)
}
