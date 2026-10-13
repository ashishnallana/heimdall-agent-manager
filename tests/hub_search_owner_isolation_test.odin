// SEARCH-8 coverage for TYPED per-parent id filters (+ negation), exclude, cursor
// pagination, and cross-owner isolation of the Hub search repository.
//
//   1. Owner isolation: searching as owner A never returns owner B's rows.
//   2. Typed filters map to precise containment columns: chain_ids surfaces the
//      chain + its task; task_ids surfaces the task; project_ids the project;
//      conversation_ids the conversation. Memory/agent (no containment column)
//      are excluded by a positive typed filter.
//   3. Negation (not_in_*) drops rows under the named parent and keeps the rest
//      (including ''-column providers).
//   4. Typed filters are AND-ed with the owner: owner A naming owner B's ids => 0.
//   5. exclude, type aliases, nested-shape data, and real load-more still hold.
package hub_search_owner_isolation_test

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

// Q bundles the search inputs so each test can set only what it needs.
Q :: struct {
	owner:                   string,
	q:                       string,
	types:                   string,
	exclude:                 string,
	cursor:                  string,
	limit:                   int,
	task_ids:                string,
	chain_ids:               string,
	project_ids:             string,
	conversation_ids:        string,
	not_in_task_ids:         string,
	not_in_chain_ids:        string,
	not_in_project_ids:      string,
	not_in_conversation_ids: string,
}

@(test)
test_hub_search_owner_isolation_test :: proc(t: ^testing.T) {
	_ = t
	main()
}

main :: proc() {
	db_path := "/tmp/hub_search_owner_isolation.db"
	_ = os.remove(db_path); defer _ = os.remove(db_path)
	conn, open_ok, open_err := sqlite.open(db_path)
	check(open_ok, fmt.tprintf("open db: %s", open_err.message))
	defer sqlite.close(&conn)
	mig_ok, mig_err := sqlite.run_migrations(&conn, "src/hub/repository/sqlite/migrations")
	check(mig_ok, fmt.tprintf("run_migrations: %s", mig_err.message))

	seed_owner(&conn, "user_a", "a")
	seed_owner(&conn, "user_b", "b")
	// Owner A gets rows with containment relationships: a task in chain_a_zeta, a
	// conversation, and a second (targeted) memory. These prove typed filtering.
	run(&conn, fmt.tprintf("INSERT INTO tasks(task_id,chain_id,owner_user_id,title,created_at,updated_at) VALUES('task_a_zeta','chain_a_zeta','user_a','zeta task a','%s','%s');", TS, TS))
	run(&conn, fmt.tprintf("INSERT INTO memories(memory_id,owner_user_id,type,status,title,body,agent_ids,created_at,updated_at) VALUES('memsc_a_zeta','user_a','fact','approved','zeta scoped memory a','a body','[\"agt_a_zeta\"]','%s','%s');", TS, TS))
	run(&conn, fmt.tprintf("INSERT INTO chat_conversations(conversation_id,owner_user_id,agent_id,agent_instance_id,project_id,chain_id,title,created_at,updated_at) VALUES('conv_a_zeta','user_a','agt_a_zeta','inst_a_zeta','proj_a_zeta','chain_a_zeta','zeta conversation a','%s','%s');", TS, TS))

	repo_impl: sqlite.Search_Repo_SQLite
	repo := sqlite.new_search_repository(&repo_impl, &conn)

	owner_isolation_holds(&repo)
	typed_scope_matching(&repo)
	negation_excludes_named_parent(&repo)
	typed_scope_cannot_cross_owners(&repo)
	exclude_drops_matching_hits(&repo)
	type_aliases_resolve(&repo)
	nested_shape_fields_populated(&repo)
	load_more_pages_without_dup_or_drop(&repo)

	fmt.println("PASS: hub search isolation + typed filters + negation + cursor paging")
}

seed_owner :: proc(conn: ^sqlite.Conn, owner, suffix: string) {
	run(conn, fmt.tprintf("INSERT INTO agents(agent_id,owner_user_id,name,slug,state,created_at,updated_at) VALUES('agt_%s_zeta','%s','zeta agent %s','zeta-agent-%s','active','%s','%s');", suffix, owner, suffix, suffix, TS, TS))
	run(conn, fmt.tprintf("INSERT INTO projects(project_id,owner_user_id,name,slug,vcs_kind,repo_url,default_path,created_at,updated_at) VALUES('proj_%s_zeta','%s','zeta project %s','zeta-project-%s','git','','/tmp/zeta','%s','%s');", suffix, owner, suffix, suffix, TS, TS))
	run(conn, fmt.tprintf("INSERT INTO task_chains(chain_id,owner_user_id,title,kind,status,coordinator_agent_instance_id,created_at,updated_at) VALUES('chain_%s_zeta','%s','zeta chain %s','team','active','','%s','%s');", suffix, owner, suffix, TS, TS))
	run(conn, fmt.tprintf("INSERT INTO memories(memory_id,owner_user_id,type,status,title,body,agent_ids,created_at,updated_at) VALUES('mem_%s_zeta','%s','fact','approved','zeta memory %s','a body','[]','%s','%s');", suffix, owner, suffix, TS, TS))
}

run :: proc(conn: ^sqlite.Conn, sql: string) {
	check(sqlite.exec(conn, sql), fmt.tprintf("seed insert failed: %s", sql))
}

do_search :: proc(repo: ^iface.Search_Repository, p: Q) -> iface.Search_Result {
	limit := p.limit == 0 ? 50 : p.limit
	result, err := iface.search_resources(repo, iface.Search_Query{
		owner_user_id = domain.User_ID(p.owner),
		q = p.q,
		types_csv = p.types,
		response_limit = limit,
		hard_scan_cap = 200,
		cursor = p.cursor,
		exclude = p.exclude,
		task_ids = p.task_ids,
		chain_ids = p.chain_ids,
		project_ids = p.project_ids,
		conversation_ids = p.conversation_ids,
		not_in_task_ids = p.not_in_task_ids,
		not_in_chain_ids = p.not_in_chain_ids,
		not_in_project_ids = p.not_in_project_ids,
		not_in_conversation_ids = p.not_in_conversation_ids,
	})
	check(err.code == .None, fmt.tprintf("search error: %s", err.message))
	return result
}

has_id :: proc(hits: []iface.Search_Hit, id: string) -> bool {
	for hit in hits do if hit.id == id do return true
	return false
}

count_type :: proc(hits: []iface.Search_Hit, resource_type: string) -> int {
	n := 0
	for hit in hits do if hit.resource_type == resource_type do n += 1
	return n
}

ids_equal :: proc(hits: []iface.Search_Hit, expected: []string) -> bool {
	if len(hits) != len(expected) do return false
	for id in expected do if !has_id(hits, id) do return false
	return true
}

owner_isolation_holds :: proc(repo: ^iface.Search_Repository) {
	res := do_search(repo, Q{owner = "user_a", q = "zeta"})
	check(len(res.hits) >= 4, "owner A should see its seeded entities")
	for hit in res.hits {
		check(strings.contains(hit.id, "_a_"), fmt.tprintf("owner A leaked a foreign row: %s", hit.id))
		check(!strings.contains(hit.id, "_b_"), fmt.tprintf("owner A must not see owner B row: %s", hit.id))
	}
}

typed_scope_matching :: proc(repo: ^iface.Search_Repository) {
	// chain id => the chain AND the task/conversation whose chain_id references it.
	chain := do_search(repo, Q{owner = "user_a", q = "zeta", chain_ids = "chain_a_zeta"})
	check(has_id(chain.hits, "chain_a_zeta") && has_id(chain.hits, "task_a_zeta"), "chain_ids must surface the chain + its task")
	check(!has_id(chain.hits, "agt_a_zeta") && !has_id(chain.hits, "proj_a_zeta"), "chain_ids must exclude agent/project (no chain containment)")
	check(!has_id(chain.hits, "mem_a_zeta"), "chain_ids must exclude memories (no containment column)")

	// task id => the task only (among the seeded rows).
	task := do_search(repo, Q{owner = "user_a", q = "zeta", task_ids = "task_a_zeta"})
	check(ids_equal(task.hits, []string{"task_a_zeta"}), "task_ids must surface exactly the task")

	// project id => the project + the conversation (conversation has project_id).
	proj := do_search(repo, Q{owner = "user_a", q = "zeta", project_ids = "proj_a_zeta"})
	check(has_id(proj.hits, "proj_a_zeta"), "project_ids must surface the project")
	check(count_type(proj.hits, "agent") == 0 && count_type(proj.hits, "memory") == 0, "project_ids must exclude agent/memory")

	// conversation id => the conversation (hit id is its agent_instance_id).
	conv := do_search(repo, Q{owner = "user_a", q = "zeta", conversation_ids = "conv_a_zeta"})
	check(count_type(conv.hits, "conversation") == 1, "conversation_ids must surface the conversation")
	check(count_type(conv.hits, "agent") == 0, "conversation_ids must exclude non-conversation rows")
}

negation_excludes_named_parent :: proc(repo: ^iface.Search_Repository) {
	res := do_search(repo, Q{owner = "user_a", q = "zeta", not_in_chain_ids = "chain_a_zeta"})
	check(!has_id(res.hits, "chain_a_zeta"), "not_in_chain_ids must drop the chain")
	check(!has_id(res.hits, "task_a_zeta"), "not_in_chain_ids must drop the task in that chain")
	// Providers with no chain column ('') pass the negation and remain.
	check(has_id(res.hits, "agt_a_zeta"), "negation must keep the agent (no chain column)")
	check(has_id(res.hits, "proj_a_zeta"), "negation must keep the project")
	check(has_id(res.hits, "mem_a_zeta"), "negation must keep the memory")
}

typed_scope_cannot_cross_owners :: proc(repo: ^iface.Search_Repository) {
	// Owner A naming owner B's chain: owner_user_id is AND-ed first, so zero rows.
	res := do_search(repo, Q{owner = "user_a", q = "zeta", chain_ids = "chain_b_zeta"})
	check(len(res.hits) == 0, fmt.tprintf("owner A must not read owner B rows via B's ids, got %d", len(res.hits)))
}

exclude_drops_matching_hits :: proc(repo: ^iface.Search_Repository) {
	res := do_search(repo, Q{owner = "user_a", q = "zeta", exclude = "project"})
	check(!has_id(res.hits, "proj_a_zeta"), "exclude=project should drop the project hit")
	check(has_id(res.hits, "agt_a_zeta"), "exclude=project must keep the unrelated agent hit")
}

type_aliases_resolve :: proc(repo: ^iface.Search_Repository) {
	agents := do_search(repo, Q{owner = "user_a", q = "zeta", types = "agents"})
	check(count_type(agents.hits, "agent") == 1 && len(agents.hits) == 1, "types=agents should return only the agent")
	for alias in ([?]string{"chains", "chain", "taskchain", "task_chain"}) {
		chains := do_search(repo, Q{owner = "user_a", q = "zeta", types = alias})
		check(count_type(chains.hits, "task-chain") == 1 && len(chains.hits) == 1, fmt.tprintf("types=%s should return only the task-chain", alias))
	}
}

nested_shape_fields_populated :: proc(repo: ^iface.Search_Repository) {
	// FTS-everywhere (SEARCH-10): a name/title match sets matched_field=label and
	// top-level entities carry no parent. (id lookups are no longer a free-text
	// search hit under FTS — the same delta as comments; ids are handled by routes.)
	res := do_search(repo, Q{owner = "user_a", q = "zeta", types = "agents"})
	check(len(res.hits) == 1, "expected the single agent hit")
	hit := res.hits[0]
	check(hit.matched_field == "label", fmt.tprintf("agent name match => matched_field=label, got %q", hit.matched_field))
	check(hit.parent_id == "" && hit.parent_type == "", "top-level entity must have no parent")
}

load_more_pages_without_dup_or_drop :: proc(repo: ^iface.Search_Repository) {
	full := do_search(repo, Q{owner = "user_a", q = "zeta"})
	total := len(full.hits)
	check(total == 7, fmt.tprintf("owner A should match 7 rows, got %d", total))

	seen := make(map[string]bool); defer delete(seen)
	cursor := ""
	pages := 0
	for {
		page := do_search(repo, Q{owner = "user_a", q = "zeta", limit = 2, cursor = cursor})
		pages += 1
		check(len(page.hits) <= 2, "each page must respect the limit")
		for hit in page.hits {
			check(!seen[hit.id], fmt.tprintf("duplicate hit across pages: %s", hit.id))
			seen[hit.id] = true
		}
		if !page.has_more {
			check(page.next_cursor == "", "no next_cursor once has_more is false")
			break
		}
		check(page.next_cursor != "", "has_more implies a next_cursor")
		cursor = page.next_cursor
		check(pages < 10, "paging must terminate")
	}
	check(len(seen) == total, fmt.tprintf("paged union (%d) must equal the full set (%d)", len(seen), total))
}
