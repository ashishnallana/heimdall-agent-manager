// SEARCH-7 owner-isolation coverage for the agent.search RPC. The handler
// (agent_action_search_handler) resolves the caller to an Instance_Token
// Auth_Context (kind=.Instance_Token, user_id=<owner>, agent_instance_id=<inst>)
// via require_instance_action_auth, then delegates to the SAME
// search_service.search_resources the REST endpoint uses. This test drives that
// service boundary with two owners' instance-token contexts and asserts an agent
// can only ever see ITS OWNER's rows — never another owner's — even when it names
// the other owner's typed ids. (The bridge->hub relay transport is covered e2e by
// hub_rte2e_agent_actions_test; the RPC route/shape wiring by the static guard.)
package hub_agent_search_isolation_test

import "core:fmt"
import "core:testing"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import search_service "odin_test:hub/service/search"

check :: proc(ok: bool, msg: string) {
	if ok do return
	fmt.eprintln("FAIL:", msg)
	os.exit(1)
}

TS :: "2026-01-01T00:00:00Z"

@(test)
test_hub_agent_search_isolation_test :: proc(t: ^testing.T) {
	_ = t
	main()
}

main :: proc() {
	db_path := "/tmp/hub_agent_search_isolation.db"
	_ = os.remove(db_path); defer _ = os.remove(db_path)
	conn, open_ok, open_err := sqlite.open(db_path)
	check(open_ok, fmt.tprintf("open db: %s", open_err.message))
	defer sqlite.close(&conn)
	mig_ok, mig_err := sqlite.run_migrations(&conn, "src/hub/repository/sqlite/migrations")
	check(mig_ok, fmt.tprintf("run_migrations: %s", mig_err.message))

	seed_owner(&conn, "alice", "a", "alpha")
	seed_owner(&conn, "bob", "b", "bravo")

	repo_impl: sqlite.Search_Repo_SQLite
	repo := sqlite.new_search_repository(&repo_impl, &conn)
	svc := search_service.new_search_service(&repo)

	// The Auth_Context an instance token resolves to (owner + instance id).
	auth_a := contracts.Auth_Context{kind = .Instance_Token, user_id = "alice", agent_instance_id = "inst_a"}
	auth_b := contracts.Auth_Context{kind = .Instance_Token, user_id = "bob", agent_instance_id = "inst_b"}

	// A's agent searches: sees only A's comment.
	res_a, ok_a, err_a := search_service.search_resources(&svc, auth_a, search_service.Search_Input{q = "zebrafts", types_csv = "comment"})
	check(ok_a, fmt.tprintf("search A: %s", err_a.message))
	check(has_body(res_a.hits, "alpha") && !has_body(res_a.hits, "bravo"), "owner A's agent must see only A's comment")

	// B's agent searches: sees only B's comment.
	res_b, ok_b, _ := search_service.search_resources(&svc, auth_b, search_service.Search_Input{q = "zebrafts", types_csv = "comment"})
	check(ok_b && has_body(res_b.hits, "bravo") && !has_body(res_b.hits, "alpha"), "owner B's agent must see only B's comment")

	// A naming B's chain via a typed filter still yields nothing (owner AND-ed first).
	res_x, ok_x, _ := search_service.search_resources(&svc, auth_a, search_service.Search_Input{q = "zebrafts", types_csv = "comment", chain_ids = "chain_b"})
	check(ok_x && len(res_x.hits) == 0, "an agent cannot read another owner's rows by naming their typed ids")

	fmt.println("PASS: hub agent.search instance-token owner isolation")
}

// seed_owner inserts a chain + task + comment (body carries the owner's distinctive
// word) so the comment provider's owner-scoped task JOIN + FTS index apply.
seed_owner :: proc(conn: ^sqlite.Conn, owner, suffix, word: string) {
	run(conn, fmt.tprintf("INSERT INTO task_chains(chain_id,owner_user_id,title,kind,status,coordinator_agent_instance_id,created_at,updated_at) VALUES('chain_%s','%s','Chain','team','active','','%s','%s');", suffix, owner, TS, TS))
	run(conn, fmt.tprintf("INSERT INTO tasks(task_id,chain_id,owner_user_id,title,created_at,updated_at) VALUES('task_%s','chain_%s','%s','Task','%s','%s');", suffix, suffix, owner, TS, TS))
	run(conn, fmt.tprintf("INSERT INTO task_comments(comment_id,task_id,chain_id,owner_user_id,author_agent_instance_id,body,created_at,updated_at) VALUES('cmt_%s','task_%s','chain_%s','%s','inst_%s','zebrafts %s note','%s','%s');", suffix, suffix, suffix, owner, suffix, word, TS, TS))
}

run :: proc(conn: ^sqlite.Conn, sql: string) {
	check(sqlite.exec(conn, sql), fmt.tprintf("seed insert failed: %s", sql))
}

has_body :: proc(hits: []iface.Search_Hit, word: string) -> bool {
	for hit in hits do if strings.contains(hit.label, word) || strings.contains(hit.preview, word) do return true
	return false
}
