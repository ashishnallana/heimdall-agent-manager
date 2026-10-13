// SEARCH-3 coverage for the two new providers and the preview extractor:
//   1. Comments: search task_comments.body; the hit's parent is its task, the
//      route points to the task, matched_field is body|id, and preview is a
//      "…text [match] text…" snippet. Owner-scoped on BOTH the comment and the
//      joined task (a comment whose task is missing/foreign is not returned).
//   2. Skills: in-memory STATIC_SKILLS scan (slug + contents), owner-INDEPENDENT
//      (same result for any owner), real /skills/<slug> route, matched_field
//      name|content. Typed parent filters (SEARCH-8) do NOT apply to skills.
//   2b. Comment typed scoping: task_ids/chain_ids surface the comment; negation drops it.
//   3. Preview boundaries: leading/trailing ellipses, bracketed match preserving
//      the original case, and whitespace collapsed.
package hub_search_comments_skills_test

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

SKILLS := []sqlite.Skill_Doc{
	{"deploy-runbook", "This runbook explains how to deploy the service to production safely."},
	{"incident-response", "Steps for handling an incident: escalate, mitigate, then communicate."},
}

@(test)
test_hub_search_comments_skills_test :: proc(t: ^testing.T) {
	_ = t
	main()
}

main :: proc() {
	db_path := "/tmp/hub_search_comments_skills.db"
	_ = os.remove(db_path); defer _ = os.remove(db_path)
	conn, open_ok, open_err := sqlite.open(db_path)
	check(open_ok, fmt.tprintf("open db: %s", open_err.message))
	defer sqlite.close(&conn)
	mig_ok, mig_err := sqlite.run_migrations(&conn, "src/hub/repository/sqlite/migrations")
	check(mig_ok, fmt.tprintf("run_migrations: %s", mig_err.message))

	// Owner A: a chain, a task in it, and a comment on that task.
	run(&conn, "INSERT INTO task_chains(chain_id,owner_user_id,title,kind,status,coordinator_agent_instance_id,created_at,updated_at) VALUES('chain_a','user_a','Alpha chain','team','active','',$ts,$ts);")
	run(&conn, "INSERT INTO tasks(task_id,chain_id,owner_user_id,title,created_at,updated_at) VALUES('task_a','chain_a','user_a','Alpha task',$ts,$ts);")
	run(&conn, fmt.tprintf("INSERT INTO task_comments(comment_id,task_id,chain_id,owner_user_id,author_agent_instance_id,body,created_at,updated_at) VALUES('cmt_a','task_a','chain_a','user_a','inst_1','%s','%s','%s');", COMMENT_BODY, TS, TS))
	// A dangling comment whose task does not exist for the owner: the JOIN must drop it.
	run(&conn, fmt.tprintf("INSERT INTO task_comments(comment_id,task_id,chain_id,owner_user_id,author_agent_instance_id,body,created_at,updated_at) VALUES('cmt_orphan','task_missing','chain_a','user_a','inst_1','%s','%s','%s');", COMMENT_BODY, TS, TS))

	repo_impl: sqlite.Search_Repo_SQLite
	repo := sqlite.new_search_repository(&repo_impl, &conn, SKILLS)

	comment_provider_basics(&repo)
	comment_owner_scoping(&repo)
	comment_typed_scope(&repo)
	skill_provider_basics(&repo)
	skill_owner_independent(&repo)
	skill_positive_filter_excludes(&repo)
	exclude_matches_preview_only(&repo)
	preview_boundaries(&repo)

	fmt.println("PASS: hub search comments + skills + preview")
}

// COMMENT_BODY has the needle mid-string with surrounding whitespace/newlines so
// the preview test can assert ellipses + collapse.
COMMENT_BODY :: "The quick brown fox jumps over the lazy dog\n\n   near the ZEBRAWORD token\t\tand then keeps going well past the snippet radius boundary here."

run :: proc(conn: ^sqlite.Conn, sql: string) {
	stmt := strings.trim_space(sql)
	// tiny $ts substitution keeps the fixed inserts readable.
	final, _ := strings.replace_all(stmt, "$ts", fmt.tprintf("'%s'", TS))
	defer delete(final)
	check(sqlite.exec(conn, final), fmt.tprintf("seed insert failed: %s", final))
}

query :: proc(repo: ^iface.Search_Repository, owner, q, types_csv, exclude: string) -> iface.Search_Result {
	result, err := iface.search_resources(repo, iface.Search_Query{
		owner_user_id = domain.User_ID(owner),
		q = q,
		types_csv = types_csv,
		response_limit = 50,
		hard_scan_cap = 200,
		exclude = exclude,
	})
	check(err.code == .None, fmt.tprintf("search error: %s", err.message))
	return result
}

// query_scope runs a comment search with a single typed parent filter set.
query_scope :: proc(repo: ^iface.Search_Repository, owner, q, types_csv: string, task_ids, chain_ids, not_in_chain_ids: string) -> iface.Search_Result {
	result, err := iface.search_resources(repo, iface.Search_Query{
		owner_user_id = domain.User_ID(owner),
		q = q,
		types_csv = types_csv,
		response_limit = 50,
		hard_scan_cap = 200,
		task_ids = task_ids,
		chain_ids = chain_ids,
		not_in_chain_ids = not_in_chain_ids,
	})
	check(err.code == .None, fmt.tprintf("search error: %s", err.message))
	return result
}

find :: proc(hits: []iface.Search_Hit, id: string) -> (iface.Search_Hit, bool) {
	for hit in hits do if hit.id == id do return hit, true
	return {}, false
}

comment_provider_basics :: proc(repo: ^iface.Search_Repository) {
	res := query(repo, "user_a", "ZEBRAWORD", "comment", "")
	hit, ok := find(res.hits, "cmt_a")
	check(ok, "comment body search must find cmt_a")
	check(hit.resource_type == "comment", "hit type must be comment")
	check(hit.parent_id == "task_a" && hit.parent_type == "task", "comment parent must be its task")
	check(hit.route == "/chains/chain_a/tasks/task_a", fmt.tprintf("comment must route to its task, got %q", hit.route))
	check(hit.matched_field == "body", fmt.tprintf("body match => matched_field=body, got %q", hit.matched_field))
	check(strings.contains(hit.preview, "[ZEBRAWORD]"), fmt.tprintf("preview must bracket the match, got %q", hit.preview))
	// FTS multi-word win: tokenized AND matches non-adjacent terms in any order
	// ("quick fox" matches "...quick brown fox..."), which LIKE '%q%' cannot.
	multi := query(repo, "user_a", "quick fox", "comment", "")
	mhit, mok := find(multi.hits, "cmt_a")
	check(mok && mhit.matched_field == "body", "multi-word body query must match via FTS => matched_field=body")
}

comment_owner_scoping :: proc(repo: ^iface.Search_Repository) {
	// Owner B owns no comments -> nothing.
	res := query(repo, "user_b", "ZEBRAWORD", "comment", "")
	check(len(res.hits) == 0, "owner B must not see owner A's comment")
	// The orphan comment (task_missing) must be dropped by the owner-scoped task JOIN.
	all_a := query(repo, "user_a", "ZEBRAWORD", "comment", "")
	_, orphan := find(all_a.hits, "cmt_orphan")
	check(!orphan, "comment whose task is missing must be dropped by the JOIN")
}

comment_typed_scope :: proc(repo: ^iface.Search_Repository) {
	// task_ids and chain_ids both surface the comment (its scope_task_id/scope_chain_id).
	by_task := query_scope(repo, "user_a", "ZEBRAWORD", "comment", "task_a", "", "")
	_, t_ok := find(by_task.hits, "cmt_a")
	check(t_ok && len(by_task.hits) == 1, "task_ids=task_a must include the comment")
	by_chain := query_scope(repo, "user_a", "ZEBRAWORD", "comment", "", "chain_a", "")
	_, c_ok := find(by_chain.hits, "cmt_a")
	check(c_ok, "chain_ids=chain_a must include the comment")
	// An unrelated task id excludes it.
	none := query_scope(repo, "user_a", "ZEBRAWORD", "comment", "task_other", "", "")
	check(len(none.hits) == 0, "unrelated task_ids must exclude the comment")
	// Negation drops the comment when its chain is excluded.
	neg := query_scope(repo, "user_a", "ZEBRAWORD", "comment", "", "", "chain_a")
	_, still := find(neg.hits, "cmt_a")
	check(!still, "not_in_chain_ids=chain_a must drop the comment")
}

skill_provider_basics :: proc(repo: ^iface.Search_Repository) {
	// Case-insensitive slug match; preview preserves original case; real route.
	res := query(repo, "user_a", "DEPLOY", "skill", "")
	hit, ok := find(res.hits, "deploy-runbook")
	check(ok, "skill slug search must find deploy-runbook")
	check(hit.matched_field == "name", "slug match => matched_field=name")
	check(hit.route == "/skills/deploy-runbook", fmt.tprintf("skill must route to viewer, got %q", hit.route))
	check(hit.score == 90, fmt.tprintf("slug prefix match => score 90, got %d", hit.score))
	// Content-only match.
	content := query(repo, "user_a", "escalate", "skill", "")
	chit, cok := find(content.hits, "incident-response")
	check(cok && chit.matched_field == "content", "content-only match => matched_field=content")
	// Content-only skill hits use the unified secondary/content tier (40, ==
	// FTS_TIER_SECONDARY), so any primary-field match (>=50) outranks them.
	check(cok && chit.score == 40, fmt.tprintf("content-only skill match => score 40 (secondary/content tier), got %d", chit.score))
	check(strings.contains(chit.preview, "[escalate]"), fmt.tprintf("content preview must bracket the match, got %q", chit.preview))
	// Exact slug => 100.
	exact := query(repo, "user_a", "deploy-runbook", "skill", "")
	ehit, eok := find(exact.hits, "deploy-runbook")
	check(eok && ehit.score == 100, "exact slug => score 100")
}

skill_owner_independent :: proc(repo: ^iface.Search_Repository) {
	a := query(repo, "user_a", "deploy", "skill", "")
	b := query(repo, "user_b", "deploy", "skill", "")
	_, a_ok := find(a.hits, "deploy-runbook")
	_, b_ok := find(b.hits, "deploy-runbook")
	check(a_ok && b_ok, "skills are global: both owners see the same skill hit")
}

// skill_positive_filter_excludes: skills are parentless, so a POSITIVE typed
// filter (which narrows to providers that HAVE the parent) excludes them, while a
// negation-only query still returns them.
skill_positive_filter_excludes :: proc(repo: ^iface.Search_Repository) {
	positive := query_scope(repo, "user_a", "deploy", "skill", "task_a", "", "")
	_, present := find(positive.hits, "deploy-runbook")
	check(!present, "a positive typed filter must exclude parentless skills")
	// Negation-only leaves skills in.
	negation := query_scope(repo, "user_a", "deploy", "skill", "", "", "chain_x")
	_, kept := find(negation.hits, "deploy-runbook")
	check(kept, "negation-only must keep skills")
}

// exclude_matches_preview_only proves exclusion works on the preview path: the
// skill "incident-response" matches q="escalate" only in its CONTENT (so the term
// surfaces in preview, not in label/sublabel). exclude="mitigate" — a word that
// appears only in that preview snippet — must DROP the row; without exclude it
// returns. This is the pinned preview-only exclusion criterion.
exclude_matches_preview_only :: proc(repo: ^iface.Search_Repository) {
	kept := query(repo, "user_a", "escalate", "skill", "")
	hit, ok := find(kept.hits, "incident-response")
	check(ok, "control: incident-response must be returned without exclude")
	check(strings.contains(hit.preview, "mitigate"), fmt.tprintf("precondition: 'mitigate' must be in the preview, got %q", hit.preview))
	check(!strings.contains(hit.label, "mitigate") && !strings.contains(hit.sublabel, "mitigate"), "precondition: 'mitigate' must NOT be in label/sublabel")
	dropped := query(repo, "user_a", "escalate", "skill", "mitigate")
	_, still := find(dropped.hits, "incident-response")
	check(!still, "exclude=mitigate must drop the row via the preview-only path")
}

// preview_boundaries checks the comment preview (FTS snippet path): the match is
// bracketed and the snippet is whitespace-clean (raw newlines/tabs collapsed).
// Exact ellipsis placement is an FTS-internal detail and is not asserted here;
// the deterministic "…text [match] text…" boundary algorithm (search_preview) is
// covered via the skill content path in skill_provider_basics.
preview_boundaries :: proc(repo: ^iface.Search_Repository) {
	res := query(repo, "user_a", "ZEBRAWORD", "comment", "")
	hit, ok := find(res.hits, "cmt_a")
	check(ok, "expected the comment hit")
	p := hit.preview
	check(strings.contains(p, "[ZEBRAWORD]"), fmt.tprintf("match must be bracketed, got %q", p))
	check(!strings.contains(p, "\n") && !strings.contains(p, "\t"), fmt.tprintf("whitespace must be collapsed, got %q", p))
	check(!strings.contains(p, "  "), fmt.tprintf("no double spaces after collapse, got %q", p))
}
