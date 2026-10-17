package sqlite

import "core:c"
import "core:fmt"
import "core:strconv"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Issue_Repo_SQLite :: struct {
	conn: ^Conn,
}

new_issue_repository :: proc(impl: ^Issue_Repo_SQLite, conn: ^Conn) -> iface.Issue_Repository {
	impl.conn = conn
	return iface.Issue_Repository{
		ctx            = rawptr(impl),
		save           = issue_save_sqlite,
		get            = issue_get_sqlite,
		list           = issue_list_sqlite,
		update         = issue_update_sqlite,
		delete_issue   = issue_delete_sqlite,
		save_comment   = issue_comment_save_sqlite,
		list_comments  = issue_comment_list_sqlite,
		delete_comment = issue_comment_delete_sqlite,
		save_vote      = issue_vote_save_sqlite,
		remove_vote    = issue_vote_remove_sqlite,
		has_voted      = issue_vote_has_sqlite,
		vote_count     = issue_vote_count_sqlite,
		list_votes     = issue_vote_list_sqlite,
	}
}

parse_int_column :: proc(stmt: sqlite3_stmt, index: int) -> int {
	txt := column_text_unowned(stmt, index)
	if txt == "" do return 0
	val, ok := strconv.parse_int(txt)
	if !ok do return 0
	return int(val)
}

issue_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Issue {
	issue: domain.Issue
	issue.issue_id      = domain.Issue_ID(column_text(stmt, 0))
	issue.owner_user_id = domain.User_ID(column_text(stmt, 1))
	issue.title         = column_text(stmt, 2)
	issue.description   = column_text(stmt, 3)
	issue.created_by    = column_text(stmt, 4)
	issue.status        = domain.issue_status_from_string(column_text_unowned(stmt, 5))
	issue.scope_type    = domain.issue_scope_type_from_string(column_text_unowned(stmt, 6))
	issue.target_id     = column_text(stmt, 7)
	issue.chain_id      = column_text(stmt, 8)
	issue.created_at    = column_text(stmt, 9)
	issue.updated_at    = column_text(stmt, 10)
	issue.closed_at     = column_text(stmt, 11)
	issue.vote_count    = parse_int_column(stmt, 12)
	issue.comment_count = parse_int_column(stmt, 13)
	return issue
}

issue_save_sqlite :: proc(ctx: rawptr, issue: domain.Issue) -> (domain.Issue, bool, domain.Domain_Error) {
	impl := (^Issue_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return domain.Issue{}, false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := `INSERT INTO issues (
		issue_id, owner_user_id, title, description, created_by,
		status, scope_type, target_id, chain_id, created_at, updated_at, closed_at
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);`
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return domain.Issue{}, false, domain.domain_error(.Internal_Error, "failed to prepare issue insert")
	}
	defer sqlite3_finalize(stmt)

	bind_text(stmt, 1, string(issue.issue_id))
	bind_text(stmt, 2, string(issue.owner_user_id))
	bind_text(stmt, 3, issue.title)
	bind_text(stmt, 4, issue.description)
	bind_text(stmt, 5, issue.created_by)
	bind_text(stmt, 6, domain.issue_status_string(issue.status))
	bind_text(stmt, 7, domain.issue_scope_type_string(issue.scope_type))
	bind_text(stmt, 8, issue.target_id)
	bind_text(stmt, 9, issue.chain_id)
	bind_text(stmt, 10, issue.created_at)
	bind_text(stmt, 11, issue.updated_at)
	bind_text(stmt, 12, issue.closed_at)

	if sqlite3_step(stmt) != SQLITE_DONE {
		return domain.Issue{}, false, domain.domain_error(.Conflict, "issue could not be saved")
	}
	return issue, true, domain.Domain_Error{}
}

issue_get_sqlite :: proc(ctx: rawptr, issue_id: domain.Issue_ID, owner_user_id: domain.User_ID) -> (domain.Issue, bool, domain.Domain_Error) {
	impl := (^Issue_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return domain.Issue{}, false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := `SELECT 
		i.issue_id, i.owner_user_id, i.title, i.description, i.created_by,
		i.status, i.scope_type, i.target_id, i.chain_id, i.created_at, i.updated_at, i.closed_at,
		(SELECT COUNT(*) FROM issue_votes v WHERE v.issue_id = i.issue_id) AS vote_count,
		(SELECT COUNT(*) FROM issue_comments c WHERE c.issue_id = i.issue_id) AS comment_count
	FROM issues i
	WHERE i.issue_id = ? AND i.owner_user_id = ?;`
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return domain.Issue{}, false, domain.domain_error(.Internal_Error, "failed to prepare issue get")
	}
	defer sqlite3_finalize(stmt)

	bind_text(stmt, 1, string(issue_id))
	bind_text(stmt, 2, string(owner_user_id))

	if sqlite3_step(stmt) != SQLITE_ROW {
		return domain.Issue{}, false, domain.domain_error(.Not_Found, "issue not found")
	}
	return issue_from_stmt(stmt), true, domain.Domain_Error{}
}

issue_list_sqlite :: proc(ctx: rawptr, filter: domain.Issue_Filter) -> ([]domain.Issue, domain.Domain_Error) {
	impl := (^Issue_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return nil, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}

	b: strings.Builder
	strings.builder_init(&b)
	defer strings.builder_destroy(&b)

	strings.write_string(&b, `SELECT 
		i.issue_id, i.owner_user_id, i.title, i.description, i.created_by,
		i.status, i.scope_type, i.target_id, i.chain_id, i.created_at, i.updated_at, i.closed_at,
		(SELECT COUNT(*) FROM issue_votes v WHERE v.issue_id = i.issue_id) AS vote_count,
		(SELECT COUNT(*) FROM issue_comments c WHERE c.issue_id = i.issue_id) AS comment_count
	FROM issues i
	WHERE i.owner_user_id = ? `)

	if filter.status != "" {
		strings.write_string(&b, "AND i.status = ? ")
	}
	if filter.scope_type != "" {
		strings.write_string(&b, "AND i.scope_type = ? ")
	}
	if filter.target_id != "" {
		strings.write_string(&b, "AND i.target_id = ? ")
	}
	if filter.chain_id != "" {
		strings.write_string(&b, "AND i.chain_id = ? ")
	}
	if filter.query != "" {
		strings.write_string(&b, "AND (i.title LIKE ? OR i.description LIKE ? OR i.created_by LIKE ?) ")
	}

	strings.write_string(&b, "ORDER BY i.created_at DESC ")

	limit := filter.limit
	if limit <= 0 do limit = 100
	if limit > 500 do limit = 500
	strings.write_string(&b, fmt.tprintf("LIMIT %d ", limit))

	if filter.offset > 0 {
		strings.write_string(&b, fmt.tprintf("OFFSET %d ", filter.offset))
	}
	strings.write_string(&b, ";")

	query_str := strings.to_string(b)
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query_str)), -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare issue list")
	}
	defer sqlite3_finalize(stmt)

	bind_idx := 1
	bind_text(stmt, bind_idx, string(filter.owner_user_id))
	bind_idx += 1

	if filter.status != "" {
		bind_text(stmt, bind_idx, filter.status)
		bind_idx += 1
	}
	if filter.scope_type != "" {
		bind_text(stmt, bind_idx, filter.scope_type)
		bind_idx += 1
	}
	if filter.target_id != "" {
		bind_text(stmt, bind_idx, filter.target_id)
		bind_idx += 1
	}
	if filter.chain_id != "" {
		bind_text(stmt, bind_idx, filter.chain_id)
		bind_idx += 1
	}
	if filter.query != "" {
		pattern := fmt.tprintf("%%%s%%", filter.query)
		bind_text(stmt, bind_idx, pattern)
		bind_idx += 1
		bind_text(stmt, bind_idx, pattern)
		bind_idx += 1
		bind_text(stmt, bind_idx, pattern)
		bind_idx += 1
	}

	out := make([dynamic]domain.Issue)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&out, issue_from_stmt(stmt))
	}
	return out[:], domain.Domain_Error{}
}

issue_update_sqlite :: proc(ctx: rawptr, issue: domain.Issue) -> (domain.Issue, bool, domain.Domain_Error) {
	impl := (^Issue_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return domain.Issue{}, false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := `UPDATE issues SET
		title = ?, description = ?, status = ?, scope_type = ?,
		target_id = ?, chain_id = ?, updated_at = ?, closed_at = ?
	WHERE issue_id = ? AND owner_user_id = ?;`
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return domain.Issue{}, false, domain.domain_error(.Internal_Error, "failed to prepare issue update")
	}
	defer sqlite3_finalize(stmt)

	bind_text(stmt, 1, issue.title)
	bind_text(stmt, 2, issue.description)
	bind_text(stmt, 3, domain.issue_status_string(issue.status))
	bind_text(stmt, 4, domain.issue_scope_type_string(issue.scope_type))
	bind_text(stmt, 5, issue.target_id)
	bind_text(stmt, 6, issue.chain_id)
	bind_text(stmt, 7, issue.updated_at)
	bind_text(stmt, 8, issue.closed_at)
	bind_text(stmt, 9, string(issue.issue_id))
	bind_text(stmt, 10, string(issue.owner_user_id))

	step_rc, row_changes := step_changes(impl.conn.db, stmt)
	if step_rc != SQLITE_DONE {
		return domain.Issue{}, false, domain.domain_error(.Internal_Error, "failed to update issue")
	}
	if row_changes == 0 {
		return domain.Issue{}, false, domain.domain_error(.Not_Found, "issue not found")
	}
	return issue, true, domain.Domain_Error{}
}

issue_delete_sqlite :: proc(ctx: rawptr, issue_id: domain.Issue_ID, owner_user_id: domain.User_ID) -> (bool, domain.Domain_Error) {
	impl := (^Issue_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "DELETE FROM issues WHERE issue_id = ? AND owner_user_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return false, domain.domain_error(.Internal_Error, "failed to prepare issue delete")
	}
	defer sqlite3_finalize(stmt)

	bind_text(stmt, 1, string(issue_id))
	bind_text(stmt, 2, string(owner_user_id))

	step_rc, row_changes := step_changes(impl.conn.db, stmt)
	if step_rc != SQLITE_DONE {
		return false, domain.domain_error(.Internal_Error, "failed to delete issue")
	}
	changes := row_changes
	return changes > 0, domain.Domain_Error{}
}

issue_comment_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Issue_Comment {
	return domain.Issue_Comment{
		comment_id    = domain.Issue_Comment_ID(column_text(stmt, 0)),
		issue_id      = domain.Issue_ID(column_text(stmt, 1)),
		owner_user_id = domain.User_ID(column_text(stmt, 2)),
		author_id     = column_text(stmt, 3),
		author_name   = column_text(stmt, 4),
		body          = column_text(stmt, 5),
		created_at    = column_text(stmt, 6),
		updated_at    = column_text(stmt, 7),
	}
}

issue_comment_save_sqlite :: proc(ctx: rawptr, comment: domain.Issue_Comment) -> (domain.Issue_Comment, bool, domain.Domain_Error) {
	impl := (^Issue_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return domain.Issue_Comment{}, false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := `INSERT INTO issue_comments (
		comment_id, issue_id, owner_user_id, author_id, author_name, body, created_at, updated_at
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?);`
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return domain.Issue_Comment{}, false, domain.domain_error(.Internal_Error, "failed to prepare comment insert")
	}
	defer sqlite3_finalize(stmt)

	bind_text(stmt, 1, string(comment.comment_id))
	bind_text(stmt, 2, string(comment.issue_id))
	bind_text(stmt, 3, string(comment.owner_user_id))
	bind_text(stmt, 4, comment.author_id)
	bind_text(stmt, 5, comment.author_name)
	bind_text(stmt, 6, comment.body)
	bind_text(stmt, 7, comment.created_at)
	bind_text(stmt, 8, comment.updated_at)

	if sqlite3_step(stmt) != SQLITE_DONE {
		return domain.Issue_Comment{}, false, domain.domain_error(.Conflict, "comment could not be saved")
	}
	return comment, true, domain.Domain_Error{}
}

issue_comment_list_sqlite :: proc(ctx: rawptr, issue_id: domain.Issue_ID, owner_user_id: domain.User_ID) -> ([]domain.Issue_Comment, domain.Domain_Error) {
	impl := (^Issue_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return nil, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := `SELECT comment_id, issue_id, owner_user_id, author_id, author_name, body, created_at, updated_at
	FROM issue_comments
	WHERE issue_id = ? AND owner_user_id = ?
	ORDER BY created_at ASC;`
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare comments list")
	}
	defer sqlite3_finalize(stmt)

	bind_text(stmt, 1, string(issue_id))
	bind_text(stmt, 2, string(owner_user_id))

	out := make([dynamic]domain.Issue_Comment)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&out, issue_comment_from_stmt(stmt))
	}
	return out[:], domain.Domain_Error{}
}

issue_comment_delete_sqlite :: proc(ctx: rawptr, comment_id: domain.Issue_Comment_ID, owner_user_id: domain.User_ID) -> (bool, domain.Domain_Error) {
	impl := (^Issue_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "DELETE FROM issue_comments WHERE comment_id = ? AND owner_user_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return false, domain.domain_error(.Internal_Error, "failed to prepare comment delete")
	}
	defer sqlite3_finalize(stmt)

	bind_text(stmt, 1, string(comment_id))
	bind_text(stmt, 2, string(owner_user_id))

	step_rc, row_changes := step_changes(impl.conn.db, stmt)
	if step_rc != SQLITE_DONE {
		return false, domain.domain_error(.Internal_Error, "failed to delete comment")
	}
	changes := row_changes
	return changes > 0, domain.Domain_Error{}
}

issue_vote_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Issue_Vote {
	return domain.Issue_Vote{
		issue_id      = domain.Issue_ID(column_text(stmt, 0)),
		voter_id      = column_text(stmt, 1),
		owner_user_id = domain.User_ID(column_text(stmt, 2)),
		voter_name    = column_text(stmt, 3),
		created_at    = column_text(stmt, 4),
	}
}

issue_vote_save_sqlite :: proc(ctx: rawptr, vote: domain.Issue_Vote) -> (bool, domain.Domain_Error) {
	impl := (^Issue_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := `INSERT OR IGNORE INTO issue_votes (
		issue_id, voter_id, owner_user_id, voter_name, created_at
	) VALUES (?, ?, ?, ?, ?);`
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return false, domain.domain_error(.Internal_Error, "failed to prepare vote insert")
	}
	defer sqlite3_finalize(stmt)

	bind_text(stmt, 1, string(vote.issue_id))
	bind_text(stmt, 2, vote.voter_id)
	bind_text(stmt, 3, string(vote.owner_user_id))
	bind_text(stmt, 4, vote.voter_name)
	bind_text(stmt, 5, vote.created_at)

	step_rc, row_changes := step_changes(impl.conn.db, stmt)
	if step_rc != SQLITE_DONE {
		return false, domain.domain_error(.Conflict, "vote could not be recorded")
	}
	changes := row_changes
	if changes == 0 {
		return false, domain.domain_error(.Conflict, "already voted on this issue")
	}
	return true, domain.Domain_Error{}
}

issue_vote_remove_sqlite :: proc(ctx: rawptr, issue_id: domain.Issue_ID, voter_id: string, owner_user_id: domain.User_ID) -> (bool, domain.Domain_Error) {
	impl := (^Issue_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "DELETE FROM issue_votes WHERE issue_id = ? AND voter_id = ? AND owner_user_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return false, domain.domain_error(.Internal_Error, "failed to prepare vote remove")
	}
	defer sqlite3_finalize(stmt)

	bind_text(stmt, 1, string(issue_id))
	bind_text(stmt, 2, voter_id)
	bind_text(stmt, 3, string(owner_user_id))

	step_rc, row_changes := step_changes(impl.conn.db, stmt)
	if step_rc != SQLITE_DONE {
		return false, domain.domain_error(.Internal_Error, "failed to remove vote")
	}
	changes := row_changes
	return changes > 0, domain.Domain_Error{}
}

issue_vote_has_sqlite :: proc(ctx: rawptr, issue_id: domain.Issue_ID, voter_id: string) -> (bool, domain.Domain_Error) {
	impl := (^Issue_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "SELECT 1 FROM issue_votes WHERE issue_id = ? AND voter_id = ? LIMIT 1;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return false, domain.domain_error(.Internal_Error, "failed to prepare has_voted query")
	}
	defer sqlite3_finalize(stmt)

	bind_text(stmt, 1, string(issue_id))
	bind_text(stmt, 2, voter_id)

	has := sqlite3_step(stmt) == SQLITE_ROW
	return has, domain.Domain_Error{}
}

issue_vote_count_sqlite :: proc(ctx: rawptr, issue_id: domain.Issue_ID) -> (int, domain.Domain_Error) {
	impl := (^Issue_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return 0, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "SELECT COUNT(*) FROM issue_votes WHERE issue_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return 0, domain.domain_error(.Internal_Error, "failed to prepare vote count query")
	}
	defer sqlite3_finalize(stmt)

	bind_text(stmt, 1, string(issue_id))

	if sqlite3_step(stmt) != SQLITE_ROW do return 0, domain.Domain_Error{}
	return parse_int_column(stmt, 0), domain.Domain_Error{}
}

issue_vote_list_sqlite :: proc(ctx: rawptr, issue_id: domain.Issue_ID) -> ([]domain.Issue_Vote, domain.Domain_Error) {
	impl := (^Issue_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return nil, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := `SELECT issue_id, voter_id, owner_user_id, voter_name, created_at
	FROM issue_votes
	WHERE issue_id = ?
	ORDER BY created_at ASC;`
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare votes list")
	}
	defer sqlite3_finalize(stmt)

	bind_text(stmt, 1, string(issue_id))

	out := make([dynamic]domain.Issue_Vote)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&out, issue_vote_from_stmt(stmt))
	}
	return out[:], domain.Domain_Error{}
}
