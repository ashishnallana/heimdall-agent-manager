// SEARCH-6 coverage for the FTS5 comment index (migration 029):
//   1. Fresh migrated DB has task_comments_fts; migrations are idempotent.
//   2. Insert/update/delete on task_comments keep the FTS index in sync (via the
//      ai/ad/au triggers), so search reflects the current body.
//   3. Multi-word, tokenized matching ("memory leak" ~ "leak in memory") that
//      LIKE '%q%' cannot do; owner scoping + the parent task JOIN still hold.
// (The before/after EXPLAIN QUERY PLAN is captured in the handoff, not here.)
package hub_search_fts_comments_test

import "core:fmt"
import "core:testing"
import "core:os"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"

check :: proc(ok: bool, msg: string) {
	if ok do return
	fmt.eprintln("FAIL:", msg)
	os.exit(1)
}

TS :: "2026-01-01T00:00:00Z"

@(test)
test_hub_search_fts_comments_test :: proc(t: ^testing.T) {
	_ = t
	main()
}

main :: proc() {
	db_path := "/tmp/hub_search_fts_comments.db"
	_ = os.remove(db_path); defer _ = os.remove(db_path)
	conn, open_ok, open_err := sqlite.open(db_path)
	check(open_ok, fmt.tprintf("open db: %s", open_err.message))
	defer sqlite.close(&conn)
	check(sqlite.fts5_available(&conn), "FTS5 must be available in the linked sqlite")

	mig_ok, mig_err := sqlite.run_migrations(&conn, "src/hub/repository/sqlite/migrations")
	check(mig_ok, fmt.tprintf("run_migrations: %s", mig_err.message))
	// Idempotent re-run.
	mig_ok2, mig_err2 := sqlite.run_migrations(&conn, "src/hub/repository/sqlite/migrations")
	check(mig_ok2, fmt.tprintf("run_migrations idempotent: %s", mig_err2.message))
	check(sqlite.sqlite_object_exists(&conn, "task_comments_fts"), "migration 029 must create task_comments_fts")

	// A chain + task so the comment provider's owner-scoped task JOIN passes.
	run(&conn, fmt.tprintf("INSERT INTO task_chains(chain_id,owner_user_id,title,kind,status,coordinator_agent_instance_id,created_at,updated_at) VALUES('chain_1','user_a','Chain','team','active','','%s','%s');", TS, TS))
	run(&conn, fmt.tprintf("INSERT INTO tasks(task_id,chain_id,owner_user_id,title,created_at,updated_at) VALUES('task_1','chain_1','user_a','Task','%s','%s');", TS, TS))

	repo_impl: sqlite.Search_Repo_SQLite
	repo := sqlite.new_search_repository(&repo_impl, &conn)

	insert_is_indexed(&conn, &repo)
	multi_word_matches(&conn, &repo)
	update_keeps_fts_in_sync(&conn, &repo)
	delete_keeps_fts_in_sync(&conn, &repo)

	fmt.println("PASS: hub search FTS comments (index + triggers + multi-word)")
}

run :: proc(conn: ^sqlite.Conn, sql: string) {
	check(sqlite.exec(conn, sql), fmt.tprintf("exec failed: %s", sql))
}

insert_comment :: proc(conn: ^sqlite.Conn, id, body: string) {
	run(conn, fmt.tprintf("INSERT INTO task_comments(comment_id,task_id,chain_id,owner_user_id,author_agent_instance_id,body,created_at,updated_at) VALUES('%s','task_1','chain_1','user_a','inst_1','%s','%s','%s');", id, body, TS, TS))
}

search :: proc(repo: ^iface.Search_Repository, q: string) -> iface.Search_Result {
	result, err := iface.search_resources(repo, iface.Search_Query{
		owner_user_id = domain.User_ID("user_a"), q = q, types_csv = "comment",
		response_limit = 50, hard_scan_cap = 200,
	})
	check(err.code == .None, fmt.tprintf("search error: %s", err.message))
	return result
}

has_id :: proc(hits: []iface.Search_Hit, id: string) -> bool {
	for hit in hits do if hit.id == id do return true
	return false
}

insert_is_indexed :: proc(conn: ^sqlite.Conn, repo: ^iface.Search_Repository) {
	insert_comment(conn, "cmt_ins", "The deployment pipeline failed during the rollout stage")
	res := search(repo, "deployment")
	check(has_id(res.hits, "cmt_ins"), "AFTER INSERT trigger must index the body for FTS MATCH")
}

multi_word_matches :: proc(conn: ^sqlite.Conn, repo: ^iface.Search_Repository) {
	insert_comment(conn, "cmt_multi", "there is a leak in the memory allocator")
	// Tokenized AND in any order — LIKE '%memory leak%' would miss this.
	res := search(repo, "memory leak")
	check(has_id(res.hits, "cmt_multi"), "multi-word FTS must match non-adjacent tokens (\"memory leak\" ~ \"leak in memory\")")
}

update_keeps_fts_in_sync :: proc(conn: ^sqlite.Conn, repo: ^iface.Search_Repository) {
	insert_comment(conn, "cmt_upd", "original widget text")
	check(has_id(search(repo, "widget").hits, "cmt_upd"), "precondition: original body indexed")
	run(conn, fmt.tprintf("UPDATE task_comments SET body='replaced gadget text' WHERE comment_id='cmt_upd';"))
	check(!has_id(search(repo, "widget").hits, "cmt_upd"), "AFTER UPDATE trigger must drop the stale term")
	check(has_id(search(repo, "gadget").hits, "cmt_upd"), "AFTER UPDATE trigger must index the new term")
}

delete_keeps_fts_in_sync :: proc(conn: ^sqlite.Conn, repo: ^iface.Search_Repository) {
	insert_comment(conn, "cmt_del", "ephemeral zeplin token")
	check(has_id(search(repo, "zeplin").hits, "cmt_del"), "precondition: body indexed")
	run(conn, "DELETE FROM task_comments WHERE comment_id='cmt_del';")
	check(!has_id(search(repo, "zeplin").hits, "cmt_del"), "AFTER DELETE trigger must remove the row from FTS")
}
