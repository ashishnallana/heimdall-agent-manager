// SEARCH-10 coverage for FTS5-everywhere (migration 030): field-weighted ranking,
// the secondary/body-match tier, TYPE_PRIORITY tiebreak, multi-word matching,
// owner isolation, and the FTS-absent LIKE fallback.
package hub_search_fts_all_test

import "core:fmt"
import "core:testing"
import "core:os"
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
test_hub_search_fts_all_test :: proc(t: ^testing.T) {
	_ = t
	main()
}

main :: proc() {
	db_path := "/tmp/hub_search_fts_all.db"
	_ = os.remove(db_path); defer _ = os.remove(db_path)
	conn, open_ok, open_err := sqlite.open(db_path)
	check(open_ok, fmt.tprintf("open db: %s", open_err.message))
	defer sqlite.close(&conn)
	check(sqlite.fts5_available(&conn), "FTS5 must be available")
	mig_ok, mig_err := sqlite.run_migrations(&conn, "src/hub/repository/sqlite/migrations")
	check(mig_ok, fmt.tprintf("run_migrations: %s", mig_err.message))
	check(sqlite.sqlite_object_exists(&conn, "tasks_fts") && sqlite.sqlite_object_exists(&conn, "memories_fts"), "migration 030 must create the per-table FTS vtables")

	// Owner u fixtures.
	run(&conn, "INSERT INTO task_chains(chain_id,owner_user_id,title,kind,status,coordinator_agent_instance_id,created_at,updated_at) VALUES('ch1','u','Chain','team','active','','x','x');")
	seed_task(&conn, "t_title", "u", "zephyr alpha", "")            // title match => high tier
	seed_task(&conn, "t_desc",  "u", "beta task",   "the zephyr note") // description-only => secondary tier
	seed_task(&conn, "t_zulu",  "u", "zulu task",   "")
	seed_task(&conn, "t_ml",    "u", "the memory leak fix", "")
	run(&conn, "INSERT INTO projects(project_id,owner_user_id,name,slug,vcs_kind,default_path,created_at,updated_at) VALUES('p_zulu','u','zulu project','zulu','git','/tmp/z','x','x');")
	// Owner v (isolation control).
	run(&conn, "INSERT INTO task_chains(chain_id,owner_user_id,title,kind,status,coordinator_agent_instance_id,created_at,updated_at) VALUES('chv','v','Chain','team','active','','x','x');")
	seed_task(&conn, "t_v", "v", "zephyr foreign", "")

	repo_impl: sqlite.Search_Repo_SQLite
	repo := sqlite.new_search_repository(&repo_impl, &conn)

	field_weight_and_secondary_tier(&repo)
	type_priority_tiebreak(&repo)
	multi_word_matches(&repo)
	owner_isolation_holds(&repo)
	like_fallback_when_fts_absent(&conn, &repo)

	fmt.println("PASS: hub search FTS-everywhere (field weights + secondary tier + type priority + multi-word + fallback)")
}

run :: proc(conn: ^sqlite.Conn, sql: string) {
	check(sqlite.exec(conn, sql), fmt.tprintf("exec failed: %s", sql))
}

seed_task :: proc(conn: ^sqlite.Conn, id, owner, title, desc: string) {
	run(conn, fmt.tprintf("INSERT INTO tasks(task_id,chain_id,owner_user_id,title,description,created_at,updated_at) VALUES('%s','ch1','%s','%s','%s','%s','%s');", id, owner, title, desc, TS, TS))
}

search :: proc(repo: ^iface.Search_Repository, owner, q, types: string) -> iface.Search_Result {
	result, err := iface.search_resources(repo, iface.Search_Query{
		owner_user_id = domain.User_ID(owner), q = q, types_csv = types,
		response_limit = 50, hard_scan_cap = 200,
	})
	check(err.code == .None, fmt.tprintf("search error: %s", err.message))
	return result
}

find :: proc(hits: []iface.Search_Hit, id: string) -> (iface.Search_Hit, bool) {
	for hit in hits do if hit.id == id do return hit, true
	return {}, false
}

// index_of returns the position of a hit id in the (already sorted) result set,
// used to assert relative ordering when the emitted (pure-tier) scores are equal.
index_of :: proc(hits: []iface.Search_Hit, id: string) -> (int, bool) {
	for hit, i in hits do if hit.id == id do return i, true
	return -1, false
}

field_weight_and_secondary_tier :: proc(repo: ^iface.Search_Repository) {
	res := search(repo, "u", "zephyr", "task")
	title_hit, t_ok := find(res.hits, "t_title")
	desc_hit, d_ok := find(res.hits, "t_desc")
	check(t_ok && d_ok, "both the title-match and description-only task must be found via FTS")
	// A title/name match outranks a body/description-only match (field weighting).
	check(title_hit.score > desc_hit.score, fmt.tprintf("title match (%d) must outrank description-only (%d)", title_hit.score, desc_hit.score))
	check(title_hit.matched_field == "label", fmt.tprintf("title match => matched_field=label, got %q", title_hit.matched_field))
	// REQUIRED (canonical ladder): a description-only match is still FOUND, with
	// matched_field=description and the CONCRETE secondary/content tier score 40
	// (FTS_TIER_SECONDARY) — never silently 0 and never the 60 the coordinator
	// overruled. The `zephyr` title hit is a prefix (primary-field) match, so this
	// also pins the invariant: any primary-field match (>=50) strictly outranks a
	// secondary/body-only match (=40).
	check(desc_hit.matched_field == "description", fmt.tprintf("description-only match => matched_field=description, got %q", desc_hit.matched_field))
	check(desc_hit.score == 40, fmt.tprintf("description-only match must score exactly 40 (secondary/content tier), got %d", desc_hit.score))
	check(title_hit.score >= 50, fmt.tprintf("primary-field match must be >=50 (strictly above secondary 40), got %d", title_hit.score))
}

type_priority_tiebreak :: proc(repo: ^iface.Search_Repository) {
	// Both are a primary prefix match, so their emitted (pure-tier) scores are EQUAL
	// (90). TYPE_PRIORITY is folded in only for ordering (effective_score), so the
	// task's higher priority must rank it ABOVE the project in the sorted results.
	res := search(repo, "u", "zulu", "task,project")
	task_hit, t_ok := find(res.hits, "t_zulu")
	proj_hit, p_ok := find(res.hits, "p_zulu")
	check(t_ok && p_ok, "both zulu task + project must be found")
	check(task_hit.score == proj_hit.score, fmt.tprintf("same primary tier => equal pure scores, got task=%d project=%d", task_hit.score, proj_hit.score))
	t_idx, _ := index_of(res.hits, "t_zulu")
	p_idx, _ := index_of(res.hits, "p_zulu")
	check(t_idx < p_idx, fmt.tprintf("TYPE_PRIORITY: task (idx %d) must sort above same-tier project (idx %d)", t_idx, p_idx))
}

multi_word_matches :: proc(repo: ^iface.Search_Repository) {
	// Tokenized AND in any order — "leak memory" matches "the memory leak fix".
	res := search(repo, "u", "leak memory", "task")
	_, ok := find(res.hits, "t_ml")
	check(ok, "multi-word FTS must match non-adjacent title tokens")
}

owner_isolation_holds :: proc(repo: ^iface.Search_Repository) {
	res := search(repo, "u", "zephyr", "task")
	_, leaked := find(res.hits, "t_v")
	check(!leaked, "owner u must not see owner v's task via FTS")
}

like_fallback_when_fts_absent :: proc(conn: ^sqlite.Conn, repo: ^iface.Search_Repository) {
	// Drop the FTS proxy vtable so the repo falls back to the indexed-LIKE path;
	// results must still be returned (owner-scoped).
	run(conn, "DROP TABLE IF EXISTS memories_fts;")
	check(!sqlite.sqlite_object_exists(conn, "memories_fts"), "precondition: memories_fts dropped")
	res := search(repo, "u", "zephyr", "task")
	_, ok := find(res.hits, "t_title")
	check(ok, "LIKE fallback must still return the title match when FTS is absent")
	_, leaked := find(res.hits, "t_v")
	check(!leaked, "LIKE fallback must still enforce owner isolation")
}
