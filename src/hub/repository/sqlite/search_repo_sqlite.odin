package sqlite

import "core:fmt"
import "core:slice"
import "core:strings"
import base64 "core:encoding/base64"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Skill_Doc is the compiled-in skill data (slug + SKILL.md contents) injected by
// the app composition root. The repository layer must not import the service that
// owns STATIC_SKILLS, so the root maps them into this repo-local shape and passes
// them in. Skills are global (owner-independent), so no owner column is involved.
Skill_Doc :: struct {
	slug: string,
	content: string,
}

Search_Repo_SQLite :: struct {
	conn: ^Conn,
	skills: []Skill_Doc,
}

new_search_repository :: proc(impl: ^Search_Repo_SQLite, conn: ^Conn, skills: []Skill_Doc = nil) -> iface.Search_Repository {
	impl.conn = conn
	impl.skills = skills
	return iface.Search_Repository{ctx = rawptr(impl), search = search_resources_sqlite}
}

search_resources_sqlite :: proc(ctx: rawptr, query: iface.Search_Query) -> (iface.Search_Result, domain.Domain_Error) {
	impl := (^Search_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil do return iface.Search_Result{}, domain.domain_error(.Internal_Error, "sqlite search repository is not open")
	// Typed per-parent id filters. Each maps to a precise single-value scope column
	// per provider and is ALWAYS AND-ed with owner_user_id, so a caller can only
	// ever narrow their own rows. Built once and reused across the SQL providers.
	scope := build_typed_scope(query)
	defer typed_scope_free(&scope)
	scope_clause, scope_values := build_typed_scope_clause(scope)
	defer { delete(scope_clause); delete(scope_values) }
	exclude := strings.trim_space(query.exclude)
	// Comment search uses the FTS5 index when migration 029 created it; otherwise it
	// falls back to the indexed-LIKE path. Probed once per request (cheap).
	comments_fts_ready := sqlite_object_exists(impl.conn, "task_comments_fts")
	entity_fts_ready := sqlite_object_exists(impl.conn, "memories_fts") // proxy for the migration-030 vtable set
	messages_fts_ready := sqlite_object_exists(impl.conn, "chat_messages_fts") // migration 031 (MSG-1)
	all_hits := make([dynamic]iface.Search_Hit)
	defer delete(all_hits)
	for resource_type in domain.SEARCH_TYPE_ORDER {
		if !search_type_enabled(query.types_csv, resource_type) do continue
		rows: []iface.Search_Hit
		err: domain.Domain_Error
		switch resource_type {
		case "comment":
			if comments_fts_ready {
				rows, _, err = run_comment_fts_search(impl, query, scope_clause, scope_values[:])
			} else {
				rows, _, err = run_comment_search(impl, query, scope_clause, scope_values[:])
			}
		case "message":
			// MSG-1: chat message bodies via the fts5 index (migration 031). No LIKE
			// fallback — skip until the index exists (it always does post-migrate).
			if !messages_fts_ready do continue
			if desc, has_fts := fts_provider_for("message"); has_fts {
				rows, _, err = run_fts_search(impl, desc, query, scope_clause, scope_values[:])
			}
		case "skill":
			// Skills are parentless (no task/chain/project/conversation column). Per the
			// approved rule, a POSITIVE typed filter narrows to providers that HAVE the
			// parent, so it excludes skills; a negation-only query still returns them.
			if has_positive_typed_filter(scope) do continue
			rows, _, err = run_skill_search(impl, query)
		case:
			if desc, has_fts := fts_provider_for(resource_type); has_fts && entity_fts_ready {
				rows, _, err = run_fts_search(impl, desc, query, scope_clause, scope_values[:])
			} else {
				rows, _, err = run_type_search(impl, resource_type, query, scope_clause, scope_values[:])
			}
		}
		if err.code != .None do return iface.Search_Result{}, err
		for hit in rows {
			if exclude != "" && hit_excluded(hit, exclude) do continue
			// The emitted hit.score stays the PURE tier (so the ladder is observable);
			// the static TYPE_PRIORITY tiebreak is folded in via effective_score() only
			// for the merge sort + cursor key (see hit_less / encode_search_cursor).
			append(&all_hits, hit)
		}
	}
	// Deterministic TOTAL order so cursor paging can never drop or duplicate rows:
	// score desc, then id asc, then resource_type asc (resource_type disambiguates
	// the conversation/agent_instance case, which share agent_instance_id as id).
	slice.sort_by(all_hits[:], hit_less)
	// Merge-stage cursor: skip everything up to and including the cursor's key, then
	// return one page. next_cursor/has_more reflect the real remaining candidate set.
	start := 0
	if query.cursor != "" {
		if ck, ok := decode_search_cursor(query.cursor); ok {
			for i in 0..<len(all_hits) {
				if hit_after_cursor(ck, all_hits[i]) { start = i; break }
				start = i + 1
			}
		}
	}
	has_more := (len(all_hits) - start) > query.response_limit
	end := start + query.response_limit
	if end > len(all_hits) do end = len(all_hits)
	hits := make([dynamic]iface.Search_Hit)
	for i in start..<end do append(&hits, all_hits[i])
	next_cursor := ""
	if has_more && len(hits) > 0 do next_cursor = encode_search_cursor(hits[len(hits) - 1])
	return iface.Search_Result{hits = hits[:], has_more = has_more, next_cursor = next_cursor}, domain.Domain_Error{}
}

// Search_Cursor is the opaque page key: the sort tuple of the last emitted hit.
Search_Cursor :: struct {
	score: int,
	id: string,
	resource_type: string,
}

// hit_less is the total-order comparator: higher effective_score first (pure tier
// + TYPE_PRIORITY tiebreak), then id ascending, then resource_type ascending as a
// final unique tiebreak. The emitted hit.score stays pure; ordering uses the
// effective score so same-tier cross-type ties resolve by TYPE_PRIORITY.
hit_less :: proc(a, b: iface.Search_Hit) -> bool {
	ea, eb := effective_score(a), effective_score(b)
	if ea != eb do return ea > eb
	if a.id != b.id do return a.id < b.id
	return a.resource_type < b.resource_type
}

// hit_after_cursor reports whether hit sorts strictly after the cursor key. The
// cursor stores the EFFECTIVE score, so compare it directly against the hit's
// effective_score (never rebuild a synthetic hit — that would double-count the
// TYPE_PRIORITY addend).
hit_after_cursor :: proc(ck: Search_Cursor, hit: iface.Search_Hit) -> bool {
	eh := effective_score(hit)
	if ck.score != eh do return eh < ck.score
	if ck.id != hit.id do return hit.id > ck.id
	return hit.resource_type > ck.resource_type
}

// encode_search_cursor / decode_search_cursor round-trip the sort tuple as an
// opaque base64 token "score|id|resource_type". The score field is the EFFECTIVE
// score (tier + TYPE_PRIORITY) so paging matches hit_less exactly. A malformed
// cursor decodes to ok=false and is treated as the first page (fail-open).
encode_search_cursor :: proc(hit: iface.Search_Hit) -> string {
	s := fmt.tprintf("%d|%s|%s", effective_score(hit), hit.id, hit.resource_type)
	return base64.encode(transmute([]byte)s)
}

decode_search_cursor :: proc(cursor: string) -> (Search_Cursor, bool) {
	decoded, err := base64.decode(cursor, allocator = context.temp_allocator)
	if err != nil do return Search_Cursor{}, false
	parts := strings.split(string(decoded), "|")
	defer delete(parts)
	if len(parts) != 3 do return Search_Cursor{}, false
	return Search_Cursor{score = int_v(parts[0]), id = parts[1], resource_type = parts[2]}, true
}

// split_csv_trim splits a comma-separated list, trims each token, and drops blanks.
split_csv_trim :: proc(csv: string) -> [dynamic]string {
	out := make([dynamic]string)
	trimmed := strings.trim_space(csv)
	if trimmed == "" do return out
	parts := strings.split(trimmed, ",")
	defer delete(parts)
	for raw in parts {
		token := strings.trim_space(raw)
		if token != "" do append(&out, token)
	}
	return out
}

// hit_excluded reports whether the exclude substring appears (case-insensitive)
// in the hit's display text (label/sublabel/preview) so exclusion is predictable
// from what the user actually sees.
hit_excluded :: proc(hit: iface.Search_Hit, needle: string) -> bool {
	return ci_contains(hit.label, needle) || ci_contains(hit.sublabel, needle) || ci_contains(hit.preview, needle)
}

ci_contains :: proc(hay, needle: string) -> bool {
	return ci_index(hay, needle) >= 0
}

ascii_lower :: proc(b: byte) -> byte {
	if b >= 'A' && b <= 'Z' do return b + 32
	return b
}

// ci_index returns the byte offset of the first ASCII-case-insensitive occurrence
// of needle in hay, or -1. Unlike lowercasing the whole string, the returned
// offset always aligns with hay's original bytes (safe for slicing a preview).
ci_index :: proc(hay, needle: string) -> int {
	if needle == "" do return -1
	n := len(needle)
	if n > len(hay) do return -1
	for i in 0..=(len(hay) - n) {
		match := true
		for j in 0..<n {
			if ascii_lower(hay[i + j]) != ascii_lower(needle[j]) { match = false; break }
		}
		if match do return i
	}
	return -1
}

// search_preview builds a "…text [match] text…" snippet around the first match of
// q in text: radius of 32 bytes each side, snapped to UTF-8 rune boundaries, with
// interior whitespace collapsed to single spaces. Returns "" when q is absent.
search_preview :: proc(text, q: string) -> string {
	if q == "" || text == "" do return ""
	idx := ci_index(text, q)
	if idx < 0 do return ""
	RADIUS :: 32
	match_len := len(q)
	start := idx - RADIUS
	if start < 0 do start = 0
	end := idx + match_len + RADIUS
	if end > len(text) do end = len(text)
	// Snap off any UTF-8 continuation bytes so we never split a rune.
	for start > 0 && (text[start] & 0xC0) == 0x80 do start -= 1
	for end < len(text) && (text[end] & 0xC0) == 0x80 do end += 1
	b := strings.builder_make()
	if start > 0 do strings.write_string(&b, "…")
	write_collapsed(&b, text[start:idx])
	strings.write_string(&b, "[")
	write_collapsed(&b, text[idx:idx + match_len])
	strings.write_string(&b, "]")
	write_collapsed(&b, text[idx + match_len:end])
	if end < len(text) do strings.write_string(&b, "…")
	return strings.to_string(b)
}

// collapse_ws_string returns s with every run of ASCII whitespace collapsed to a
// single space (used to tidy FTS snippet() output, which carries raw newlines/tabs).
collapse_ws_string :: proc(s: string) -> string {
	b := strings.builder_make()
	write_collapsed(&b, s)
	return strings.to_string(b)
}

// write_collapsed copies s, collapsing every run of ASCII whitespace to one space.
// Multi-byte rune bytes are >0x7f so they are copied verbatim.
write_collapsed :: proc(b: ^strings.Builder, s: string) {
	prev_space := false
	for i in 0..<len(s) {
		ch := s[i]
		if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' {
			if !prev_space { strings.write_byte(b, ' '); prev_space = true }
		} else {
			strings.write_byte(b, ch); prev_space = false
		}
	}
}

// The search-type vocabulary moved to package domain so the service layer can
// validate against it too (REQ-CLI-5); the repository must not import the
// service, and the service cannot import this package. One list, shared.

search_type_enabled :: proc(types_csv, resource_type: string) -> bool {
	trimmed := strings.trim_space(types_csv)
	if trimmed == "" do return true
	parts := strings.split(trimmed, ",")
	defer delete(parts)
	for raw in parts {
		candidate := strings.trim_space(raw)
		if candidate == "all" do return true
		if domain.normalize_search_type(candidate) == resource_type do return true
	}
	return false
}

// SCOPE_SQL_ANCHOR is the exact tail shared by every per-type query. The scope
// filter is spliced in immediately before it so the scope placeholders bind
// after the existing q/owner params and before the trailing LIMIT.
SCOPE_SQL_ANCHOR :: "ORDER BY score DESC, updated_at DESC, id ASC LIMIT ?"

// Typed_Scope holds the parsed typed per-parent id filters (SEARCH-8). Tokens are
// subslices of the query's CSV strings (no clones); the [dynamic] containers are
// freed by typed_scope_free.
Typed_Scope :: struct {
	task_in, chain_in, project_in, conversation_in: [dynamic]string,
	task_not, chain_not, project_not, conversation_not: [dynamic]string,
}

build_typed_scope :: proc(q: iface.Search_Query) -> Typed_Scope {
	return Typed_Scope{
		task_in = split_csv_trim(q.task_ids), chain_in = split_csv_trim(q.chain_ids),
		project_in = split_csv_trim(q.project_ids), conversation_in = split_csv_trim(q.conversation_ids),
		task_not = split_csv_trim(q.not_in_task_ids), chain_not = split_csv_trim(q.not_in_chain_ids),
		project_not = split_csv_trim(q.not_in_project_ids), conversation_not = split_csv_trim(q.not_in_conversation_ids),
	}
}

// has_positive_typed_filter reports whether any positive typed parent filter is
// set (negations don't count). Used to exclude parentless providers like skills.
has_positive_typed_filter :: proc(s: Typed_Scope) -> bool {
	return len(s.task_in) > 0 || len(s.chain_in) > 0 || len(s.project_in) > 0 || len(s.conversation_in) > 0
}

typed_scope_free :: proc(s: ^Typed_Scope) {
	delete(s.task_in); delete(s.chain_in); delete(s.project_in); delete(s.conversation_in)
	delete(s.task_not); delete(s.chain_not); delete(s.project_not); delete(s.conversation_not)
}

// build_typed_scope_clause returns the owner-safe SQL fragment (a chain of AND
// scope_<parent> [NOT] IN (?...)) plus the values to bind in order. A positive
// filter keeps only rows whose scope column is in the set; providers that expose
// '' for that column are therefore excluded. A negation keeps rows whose column
// is not in the set (''-columns pass). Callers splice the clause before the
// ORDER BY anchor and bind the values after q/owner and before LIMIT.
build_typed_scope_clause :: proc(s: Typed_Scope) -> (clause: string, values: [dynamic]string) {
	values = make([dynamic]string)
	b := strings.builder_make()
	append_in_clause(&b, &values, "scope_task_id", s.task_in[:], false)
	append_in_clause(&b, &values, "scope_chain_id", s.chain_in[:], false)
	append_in_clause(&b, &values, "scope_project_id", s.project_in[:], false)
	append_in_clause(&b, &values, "scope_conversation_id", s.conversation_in[:], false)
	append_in_clause(&b, &values, "scope_task_id", s.task_not[:], true)
	append_in_clause(&b, &values, "scope_chain_id", s.chain_not[:], true)
	append_in_clause(&b, &values, "scope_project_id", s.project_not[:], true)
	append_in_clause(&b, &values, "scope_conversation_id", s.conversation_not[:], true)
	clause = strings.to_string(b)
	return
}

append_in_clause :: proc(b: ^strings.Builder, values: ^[dynamic]string, column: string, ids: []string, negate: bool) {
	if len(ids) == 0 do return
	strings.write_string(b, " AND ")
	strings.write_string(b, column)
	strings.write_string(b, negate ? " NOT IN (" : " IN (")
	for id, i in ids {
		if i > 0 do strings.write_byte(b, ',')
		strings.write_byte(b, '?')
		append(values, id)
	}
	strings.write_byte(b, ')')
}

// SCOPE_SQL_ANCHOR is the exact tail shared by every per-type query; the typed
// scope clause is spliced immediately before it so its placeholders bind after
// the existing q/owner params and before the trailing LIMIT.

// build_scoped_sql splices a prebuilt scope clause before the ORDER BY anchor.
build_scoped_sql :: proc(base: string, scope_clause: string) -> (sql: string, needs_free: bool, ok: bool) {
	if scope_clause == "" do return base, false, true
	anchor_at := strings.index(base, SCOPE_SQL_ANCHOR)
	if anchor_at < 0 do return "", false, false
	return strings.concatenate({base[:anchor_at], scope_clause, "\n", base[anchor_at:]}), true, true
}

run_type_search :: proc(impl: ^Search_Repo_SQLite, resource_type: string, query: iface.Search_Query, scope_clause: string, scope_values: []string) -> ([]iface.Search_Hit, bool, domain.Domain_Error) {
	base := search_sql_for_type(resource_type)
	if base == "" do return nil, false, domain.Domain_Error{}
	sql_str, needs_free, ok := build_scoped_sql(base, scope_clause)
	if !ok do return nil, false, domain.domain_error(.Internal_Error, "search query is missing its order-by anchor")
	sql_c := needs_free ? strings.clone_to_cstring(sql_str) : cstring(raw_data(sql_str))
	defer if needs_free { delete(sql_str); delete(sql_c) }

	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(impl.conn.db, sql_c, -1, &stmt, nil) != SQLITE_OK do return nil, false, domain.domain_error(.Internal_Error, fmt.tprintf("failed to prepare search query (%s): %s", resource_type, string(sqlite3_errmsg(impl.conn.db))))
	defer sqlite3_finalize(stmt)
	for i in 1..=7 do bind_text(stmt, i, query.q)
	bind_text(stmt, 8, string(query.owner_user_id))
	for i in 9..=11 do bind_text(stmt, i, query.q)
	next_param := 12
	for value in scope_values {
		bind_text(stmt, next_param, value); next_param += 1
	}
	bind_text(stmt, next_param, int_s(query.hard_scan_cap))
	raw_rows := make([dynamic]iface.Search_Hit)
	for sqlite3_step(stmt) == SQLITE_ROW {
		hit := search_hit_from_stmt(stmt)
		// matched_field is derived from the score tier (which predicate fired) with a
		// substring fallback for the interior tier; parent/preview stay empty for
		// these top-level entity providers.
		hit.matched_field = derive_matched_field(hit.score, hit.label, hit.id, query.q)
		append(&raw_rows, hit)
	}
	return raw_rows[:], len(raw_rows) >= query.hard_scan_cap, domain.Domain_Error{}
}

// run_comment_search searches task_comments.body. The task JOIN enforces the same
// owner on BOTH the comment and its task, and yields the parent task for the hit
// (parent = {task_id, "task"}) and the route to that task. preview is a snippet of
// the matched body; matched_field is "id" for a comment-id match else "body".
run_comment_search :: proc(impl: ^Search_Repo_SQLite, query: iface.Search_Query, scope_clause: string, scope_values: []string) -> ([]iface.Search_Hit, bool, domain.Domain_Error) {
	sql_str, needs_free, ok := build_scoped_sql(SEARCH_SQL_COMMENTS, scope_clause)
	if !ok do return nil, false, domain.domain_error(.Internal_Error, "comment search query is missing its order-by anchor")
	sql_c := needs_free ? strings.clone_to_cstring(sql_str) : cstring(raw_data(sql_str))
	defer if needs_free { delete(sql_str); delete(sql_c) }

	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(impl.conn.db, sql_c, -1, &stmt, nil) != SQLITE_OK do return nil, false, domain.domain_error(.Internal_Error, "failed to prepare comment search query")
	defer sqlite3_finalize(stmt)
	// CASE has 6 q placeholders, then owner, then 2 q (WHERE id/body), then scope, then LIMIT.
	for i in 1..=6 do bind_text(stmt, i, query.q)
	bind_text(stmt, 7, string(query.owner_user_id))
	for i in 8..=9 do bind_text(stmt, i, query.q)
	next_param := 10
	for value in scope_values {
		bind_text(stmt, next_param, value); next_param += 1
	}
	bind_text(stmt, next_param, int_s(query.hard_scan_cap))
	raw_rows := make([dynamic]iface.Search_Hit)
	for sqlite3_step(stmt) == SQLITE_ROW {
		hit := search_hit_from_stmt(stmt)
		hit.parent_id = column_text(stmt, 6)
		hit.parent_type = column_text(stmt, 7)
		match_text := column_text(stmt, 8)
		hit.preview = search_preview(match_text, query.q)
		hit.matched_field = (hit.score == 98 || hit.score == 70) ? "id" : "body"
		append(&raw_rows, hit)
	}
	return raw_rows[:], len(raw_rows) >= query.hard_scan_cap, domain.Domain_Error{}
}

// run_comment_fts_search is the FTS5 variant of run_comment_search (used when the
// task_comments_fts index exists). Param order: CASE q (1-6), owner on the JOIN
// (7), the FTS MATCH term (8), inner bm25 LIMIT (9), owner on the outer WHERE
// (10), then the typed-scope values, then the outer LIMIT. preview comes straight
// from snippet() (already bracketed).
run_comment_fts_search :: proc(impl: ^Search_Repo_SQLite, query: iface.Search_Query, scope_clause: string, scope_values: []string) -> ([]iface.Search_Hit, bool, domain.Domain_Error) {
	match_term := fts_match_query(query.q)
	defer delete(match_term)
	if match_term == "" do return nil, false, domain.Domain_Error{}
	sql_str, needs_free, ok := build_scoped_sql(SEARCH_SQL_COMMENTS_FTS, scope_clause)
	if !ok do return nil, false, domain.domain_error(.Internal_Error, "comment FTS query is missing its order-by anchor")
	sql_c := needs_free ? strings.clone_to_cstring(sql_str) : cstring(raw_data(sql_str))
	defer if needs_free { delete(sql_str); delete(sql_c) }

	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(impl.conn.db, sql_c, -1, &stmt, nil) != SQLITE_OK do return nil, false, domain.domain_error(.Internal_Error, "failed to prepare comment FTS query")
	defer sqlite3_finalize(stmt)
	for i in 1..=6 do bind_text(stmt, i, query.q)
	bind_text(stmt, 7, string(query.owner_user_id))
	bind_text(stmt, 8, match_term)
	bind_text(stmt, 9, int_s(query.hard_scan_cap))
	bind_text(stmt, 10, string(query.owner_user_id))
	next_param := 11
	for value in scope_values {
		bind_text(stmt, next_param, value); next_param += 1
	}
	bind_text(stmt, next_param, int_s(query.hard_scan_cap))
	raw_rows := make([dynamic]iface.Search_Hit)
	for sqlite3_step(stmt) == SQLITE_ROW {
		hit := search_hit_from_stmt(stmt)
		hit.parent_id = column_text(stmt, 6)
		hit.parent_type = column_text(stmt, 7)
		hit.preview = collapse_ws_string(column_text(stmt, 8)) // snippet() output ([match]-bracketed); collapse raw whitespace
		hit.matched_field = (hit.score == 98 || hit.score == 70) ? "id" : "body"
		append(&raw_rows, hit)
	}
	return raw_rows[:], len(raw_rows) >= query.hard_scan_cap, domain.Domain_Error{}
}

// fts_match_query turns a free-text query into a safe FTS5 MATCH expression: it
// splits on ANY non-alphanumeric boundary (mirroring the unicode61 tokenizer, so
// hyphenated/punctuated input tokenizes the same way the index did), gives each
// alphanumeric run a trailing `*` (prefix), and space-joins them (FTS5 ANDs them).
// So "memory leak" => `memory* leak*` (matches "leak in memory") and "zulu-secret"
// => `zulu* secret*`. Returns "" when nothing usable, avoiding any FTS injection.
fts_match_query :: proc(q: string) -> string {
	b := strings.builder_make()
	start := -1
	wrote := false
	for i in 0..<len(q) {
		ch := q[i]
		is_alnum := (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')
		if is_alnum {
			if start < 0 do start = i
		} else {
			fts_emit_term(&b, q, start, i, &wrote)
			start = -1
		}
	}
	fts_emit_term(&b, q, start, len(q), &wrote)
	return strings.to_string(b)
}

// alnum_tokens splits q into its alphanumeric runs (the same tokenization the
// unicode61 FTS index uses), for in-memory token-AND matching (skills).
alnum_tokens :: proc(q: string) -> [dynamic]string {
	out := make([dynamic]string)
	start := -1
	for i in 0..<len(q) {
		ch := q[i]
		is_alnum := (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')
		if is_alnum {
			if start < 0 do start = i
		} else if start >= 0 {
			append(&out, q[start:i]); start = -1
		}
	}
	if start >= 0 do append(&out, q[start:len(q)])
	return out
}

fts_emit_term :: proc(b: ^strings.Builder, q: string, start, end: int, wrote: ^bool) {
	if start < 0 do return
	if wrote^ do strings.write_byte(b, ' ')
	strings.write_string(b, q[start:end])
	strings.write_byte(b, '*')
	wrote^ = true
}

// run_skill_search scans the compiled-in STATIC_SKILLS (slug + SKILL.md contents).
// Skills are GLOBAL: no owner filter and typed parent filters do NOT apply (a
// skill has no task/chain/project/conversation containment), so they are matched
// by q only. matched_field is "name" (slug) or "content"; the hit routes to the
// skills viewer (SEARCH-5).
run_skill_search :: proc(impl: ^Search_Repo_SQLite, query: iface.Search_Query) -> ([]iface.Search_Hit, bool, domain.Domain_Error) {
	q := strings.trim_space(query.q)
	if q == "" do return nil, false, domain.Domain_Error{}
	// Token-AND multi-word matching (SEARCH-10), mirroring the FTS scopes: a skill
	// matches when EVERY query token appears in the slug or the content (so
	// "memory leak" ~ "leak in memory"). tokens are the alnum runs of q.
	tokens := alnum_tokens(q)
	defer delete(tokens)
	if len(tokens) == 0 do return nil, false, domain.Domain_Error{}
	raw_rows := make([dynamic]iface.Search_Hit)
	for skill in impl.skills {
		all_in_name := true
		all_present := true
		for tok in tokens {
			in_name := ci_index(skill.slug, tok) >= 0
			in_content := ci_index(skill.content, tok) >= 0
			if !in_name do all_in_name = false
			if !in_name && !in_content do all_present = false
		}
		if !all_present do continue
		// name tiers when every token is in the slug; else a content-only match uses
		// the unified secondary/content tier (40), matching FTS_TIER_SECONDARY so any
		// primary-field match (>=50) outranks a content-only skill hit.
		name_at := ci_index(skill.slug, q)
		score := 40
		matched_field := "content"
		if all_in_name {
			matched_field = "name"
			if ci_equal(skill.slug, q) {
				score = 100
			} else if name_at == 0 {
				score = 90
			} else {
				score = 70
			}
		}
		preview := search_preview(skill.content, q)
		if preview == "" && len(tokens) > 0 do preview = search_preview(skill.content, tokens[0])
		append(&raw_rows, iface.Search_Hit{
			resource_type = "skill",
			id = skill.slug,
			label = skill.slug,
			sublabel = "skill",
			route = strings.concatenate({"/skills/", skill.slug}),
			score = score,
			preview = preview,
			matched_field = matched_field,
		})
	}
	return raw_rows[:], false, domain.Domain_Error{}
}

ci_equal :: proc(a, b: string) -> bool {
	if len(a) != len(b) do return false
	for i in 0..<len(a) do if ascii_lower(a[i]) != ascii_lower(b[i]) do return false
	return true
}

// derive_matched_field maps the deterministic score tier back to the column that
// matched: label (exact/prefix/word-boundary), id (exact/prefix), else the
// interior tier is disambiguated by a case-insensitive substring check.
derive_matched_field :: proc(score: int, label, id, q: string) -> string {
	switch score {
	case 100, 90, 80: return "label"
	case 98, 70: return "id"
	}
	if ci_contains(label, q) do return "label"
	if ci_contains(id, q) do return "id"
	return "aux"
}

search_hit_from_stmt :: proc(stmt: sqlite3_stmt) -> iface.Search_Hit {
	return iface.Search_Hit{resource_type = column_text(stmt, 0), id = column_text(stmt, 1), label = column_text(stmt, 2), sublabel = column_text(stmt, 3), route = column_text(stmt, 4), score = int_v(column_text(stmt, 5))}
}

search_sql_for_type :: proc(resource_type: string) -> string {
	switch resource_type {
	case "conversation":
		return SEARCH_SQL_CONVERSATIONS
	case "agent":
		return SEARCH_SQL_AGENTS
	case "agent_instance":
		return SEARCH_SQL_AGENT_INSTANCES
	case "task-chain":
		return SEARCH_SQL_TASK_CHAINS
	case "task":
		return SEARCH_SQL_TASKS
	case "project":
		return SEARCH_SQL_PROJECTS
	case "artifact":
		return SEARCH_SQL_ARTIFACTS
	case "memory":
		return SEARCH_SQL_MEMORIES
	}
	return ""
}

// Each query selects compact fields only and performs a fixed single statement per resource type.
// Ranking is deterministic: exact > prefix > word-boundary > id prefix > interior, then recency, then id.
SEARCH_SQL_AGENTS :: `SELECT resource_type, id, label, sublabel, route, score FROM (
  SELECT 'agent' AS resource_type, agent_id AS id, name AS label,
         'slug ' || slug || ' · ' || state AS sublabel,
         '/agents/' || agent_id AS route, updated_at, owner_user_id,
		 slug || ' ' || template_id AS aux,
         '' AS scope_task_id, '' AS scope_chain_id, '' AS scope_project_id, '' AS scope_conversation_id,
         CASE
           WHEN lower(name) = lower(?) THEN 100
           WHEN lower(agent_id) = lower(?) THEN 98
           WHEN lower(name) LIKE lower(?) || '%' THEN 90
           WHEN lower(name) LIKE '% ' || lower(?) || '%' OR lower(name) LIKE '%-' || lower(?) || '%' OR lower(name) LIKE '%_' || lower(?) || '%' THEN 80
           WHEN lower(agent_id) LIKE lower(?) || '%' THEN 70
           ELSE 50
         END AS score
  FROM agents
) WHERE owner_user_id = ? AND (lower(label) LIKE '%' || lower(?) || '%' OR lower(id) LIKE '%' || lower(?) || '%' OR lower(aux) LIKE '%' || lower(?) || '%')
ORDER BY score DESC, updated_at DESC, id ASC LIMIT ?;`

SEARCH_SQL_AGENT_INSTANCES :: `SELECT resource_type, id, label, sublabel, route, score FROM (
  SELECT 'agent_instance' AS resource_type, agent_instance_id AS id, agent_id AS label,
		 runtime_status || ' · ' || provider || '/' || model AS sublabel,
         -- Conversation routing is instance-id-only (#/conversations/{instance});
         -- link to the instance itself, not its conversation_id.
         CASE WHEN agent_instance_id != '' THEN '/conversations/' || agent_instance_id ELSE '/agents/' || agent_id END AS route,
         updated_at, owner_user_id, bridge_id || ' ' || chain_id || ' ' || project_id || ' ' || conversation_id AS aux,
         '' AS scope_task_id, chain_id AS scope_chain_id, project_id AS scope_project_id, conversation_id AS scope_conversation_id,
         CASE
           WHEN lower(agent_id) = lower(?) THEN 100
           WHEN lower(agent_instance_id) = lower(?) THEN 98
           WHEN lower(agent_id) LIKE lower(?) || '%' THEN 90
           WHEN lower(agent_id) LIKE '% ' || lower(?) || '%' OR lower(agent_id) LIKE '%-' || lower(?) || '%' OR lower(agent_id) LIKE '%_' || lower(?) || '%' THEN 80
           WHEN lower(agent_instance_id) LIKE lower(?) || '%' THEN 70
           ELSE 50
         END AS score
  FROM agent_instances
) WHERE owner_user_id = ? AND (lower(label) LIKE '%' || lower(?) || '%' OR lower(id) LIKE '%' || lower(?) || '%' OR lower(aux) LIKE '%' || lower(?) || '%')
ORDER BY score DESC, updated_at DESC, id ASC LIMIT ?;`

SEARCH_SQL_CONVERSATIONS :: `SELECT resource_type, id, label, sublabel, route, score FROM (
  -- id + route are the agent_instance_id (conversation routing is instance-id-only,
  -- #/conversations/{instance}); conversation_id stays in aux so a search by it
  -- still surfaces the row.
  SELECT 'conversation' AS resource_type, agent_instance_id AS id,
         CASE WHEN title != '' THEN title ELSE agent_id END AS label,
         agent_id || ' · chain ' || chain_id AS sublabel,
         '/conversations/' || agent_instance_id AS route, updated_at, owner_user_id,
         agent_id || ' ' || agent_instance_id || ' ' || chain_id || ' ' || project_id || ' ' || conversation_id AS aux,
         '' AS scope_task_id, chain_id AS scope_chain_id, project_id AS scope_project_id, conversation_id AS scope_conversation_id,
         CASE
           WHEN lower(CASE WHEN title != '' THEN title ELSE agent_id END) = lower(?) THEN 100
           WHEN lower(conversation_id) = lower(?) THEN 98
           WHEN lower(CASE WHEN title != '' THEN title ELSE agent_id END) LIKE lower(?) || '%' THEN 90
           WHEN lower(CASE WHEN title != '' THEN title ELSE agent_id END) LIKE '% ' || lower(?) || '%' OR lower(CASE WHEN title != '' THEN title ELSE agent_id END) LIKE '%-' || lower(?) || '%' OR lower(CASE WHEN title != '' THEN title ELSE agent_id END) LIKE '%_' || lower(?) || '%' THEN 80
           WHEN lower(conversation_id) LIKE lower(?) || '%' THEN 70
           ELSE 50
         END AS score
  FROM chat_conversations
) WHERE owner_user_id = ? AND (lower(label) LIKE '%' || lower(?) || '%' OR lower(id) LIKE '%' || lower(?) || '%' OR lower(aux) LIKE '%' || lower(?) || '%')
ORDER BY score DESC, updated_at DESC, id ASC LIMIT ?;`

SEARCH_SQL_TASK_CHAINS :: `SELECT resource_type, id, label, sublabel, route, score FROM (
  SELECT 'task-chain' AS resource_type, chain_id AS id, title AS label,
         kind || ' · ' || status AS sublabel,
         '/chains/' || chain_id AS route, updated_at, owner_user_id,
         kind || ' ' || status || ' ' || coordinator_agent_instance_id AS aux,
         '' AS scope_task_id, chain_id AS scope_chain_id, '' AS scope_project_id, '' AS scope_conversation_id,
         CASE
           WHEN lower(title) = lower(?) THEN 100
           WHEN lower(chain_id) = lower(?) THEN 98
           WHEN lower(title) LIKE lower(?) || '%' THEN 90
           WHEN lower(title) LIKE '% ' || lower(?) || '%' OR lower(title) LIKE '%-' || lower(?) || '%' OR lower(title) LIKE '%_' || lower(?) || '%' THEN 80
           WHEN lower(chain_id) LIKE lower(?) || '%' THEN 70
           ELSE 50
         END AS score
  FROM task_chains
) WHERE owner_user_id = ? AND (lower(label) LIKE '%' || lower(?) || '%' OR lower(id) LIKE '%' || lower(?) || '%' OR lower(aux) LIKE '%' || lower(?) || '%')
ORDER BY score DESC, updated_at DESC, id ASC LIMIT ?;`

SEARCH_SQL_TASKS :: `SELECT resource_type, id, label, sublabel, route, score FROM (
  SELECT 'task' AS resource_type, task_id AS id, title AS label,
         'chain ' || chain_id || ' · ' || state AS sublabel,
         '/chains/' || chain_id || '/tasks/' || task_id AS route, updated_at, owner_user_id,
         chain_id || ' ' || state || ' ' || kind AS aux,
         task_id AS scope_task_id, chain_id AS scope_chain_id, '' AS scope_project_id, '' AS scope_conversation_id,
         CASE
           WHEN lower(title) = lower(?) THEN 100
           WHEN lower(task_id) = lower(?) THEN 98
           WHEN lower(title) LIKE lower(?) || '%' THEN 90
           WHEN lower(title) LIKE '% ' || lower(?) || '%' OR lower(title) LIKE '%-' || lower(?) || '%' OR lower(title) LIKE '%_' || lower(?) || '%' THEN 80
           WHEN lower(task_id) LIKE lower(?) || '%' THEN 70
           ELSE 50
         END AS score
  FROM tasks
) WHERE owner_user_id = ? AND (lower(label) LIKE '%' || lower(?) || '%' OR lower(id) LIKE '%' || lower(?) || '%' OR lower(aux) LIKE '%' || lower(?) || '%')
ORDER BY score DESC, updated_at DESC, id ASC LIMIT ?;`

SEARCH_SQL_PROJECTS :: `SELECT resource_type, id, label, sublabel, route, score FROM (
  SELECT 'project' AS resource_type, project_id AS id, name AS label,
         slug || ' · ' || vcs_kind AS sublabel,
         '/settings/projects/' || project_id AS route, updated_at, owner_user_id,
         slug || ' ' || repo_url || ' ' || vcs_kind AS aux,
         '' AS scope_task_id, '' AS scope_chain_id, project_id AS scope_project_id, '' AS scope_conversation_id,
         CASE
           WHEN lower(name) = lower(?) THEN 100
           WHEN lower(project_id) = lower(?) THEN 98
           WHEN lower(name) LIKE lower(?) || '%' THEN 90
           WHEN lower(name) LIKE '% ' || lower(?) || '%' OR lower(name) LIKE '%-' || lower(?) || '%' OR lower(name) LIKE '%_' || lower(?) || '%' THEN 80
           WHEN lower(project_id) LIKE lower(?) || '%' THEN 70
           ELSE 50
         END AS score
  FROM projects
) WHERE owner_user_id = ? AND (lower(label) LIKE '%' || lower(?) || '%' OR lower(id) LIKE '%' || lower(?) || '%' OR lower(aux) LIKE '%' || lower(?) || '%')
ORDER BY score DESC, updated_at DESC, id ASC LIMIT ?;`

SEARCH_SQL_ARTIFACTS :: `SELECT resource_type, id, label, sublabel, route, score FROM (
  SELECT 'artifact' AS resource_type, artifact_id AS id, name AS label,
         kind || ' · ' || content_type AS sublabel,
         '/library/artifacts/' || artifact_id AS route, updated_at, owner_user_id,
         kind || ' ' || content_type || ' ' || agent_id || ' ' || agent_instance_id || ' ' || chain_id || ' ' || task_id || ' ' || project_id AS aux,
         task_id AS scope_task_id, chain_id AS scope_chain_id, project_id AS scope_project_id, '' AS scope_conversation_id,
         CASE
           WHEN lower(name) = lower(?) THEN 100
           WHEN lower(artifact_id) = lower(?) THEN 98
           WHEN lower(name) LIKE lower(?) || '%' THEN 90
           WHEN lower(name) LIKE '% ' || lower(?) || '%' OR lower(name) LIKE '%-' || lower(?) || '%' OR lower(name) LIKE '%_' || lower(?) || '%' THEN 80
           WHEN lower(artifact_id) LIKE lower(?) || '%' THEN 70
           ELSE 50
         END AS score
  FROM artifacts
) WHERE owner_user_id = ? AND (lower(label) LIKE '%' || lower(?) || '%' OR lower(id) LIKE '%' || lower(?) || '%' OR lower(aux) LIKE '%' || lower(?) || '%')
ORDER BY score DESC, updated_at DESC, id ASC LIMIT ?;`

SEARCH_SQL_MEMORIES :: `SELECT resource_type, id, label, sublabel, route, score FROM (
  SELECT 'memory' AS resource_type, memory_id AS id,
         CASE WHEN title != '' THEN title ELSE type END AS label,
         type || ' · ' || status AS sublabel,
         '/settings/memory?memory_id=' || memory_id AS route, updated_at, owner_user_id,
         agent_ids || ' ' || type || ' ' || status AS aux,
         -- Memory has no single-value containment parent (task/chain/project/conversation);
         -- its targeting arrays are NOT containment, so typed parent filters exclude it.
         '' AS scope_task_id, '' AS scope_chain_id, '' AS scope_project_id, '' AS scope_conversation_id,
         CASE
           WHEN lower(CASE WHEN title != '' THEN title ELSE type END) = lower(?) THEN 100
           WHEN lower(memory_id) = lower(?) THEN 98
           WHEN lower(CASE WHEN title != '' THEN title ELSE type END) LIKE lower(?) || '%' THEN 90
           WHEN lower(CASE WHEN title != '' THEN title ELSE type END) LIKE '% ' || lower(?) || '%' OR lower(CASE WHEN title != '' THEN title ELSE type END) LIKE '%-' || lower(?) || '%' OR lower(CASE WHEN title != '' THEN title ELSE type END) LIKE '%_' || lower(?) || '%' THEN 80
           WHEN lower(memory_id) LIKE lower(?) || '%' THEN 70
           ELSE 50
         END AS score
  FROM memories
) WHERE owner_user_id = ? AND (lower(label) LIKE '%' || lower(?) || '%' OR lower(id) LIKE '%' || lower(?) || '%' OR lower(aux) LIKE '%' || lower(?) || '%')
ORDER BY score DESC, updated_at DESC, id ASC LIMIT ?;`

// Comment provider (SEARCH-3): searches task_comments.body. The tasks JOIN enforces
// the SAME owner on both the comment and its parent task and supplies the parent +
// route. match_text is the full body (the WHERE matches the whole body, not the
// truncated label); run_comment_search turns it into a bounded preview snippet.
// (The 'body' column is searched intentionally here; SEARCH-6 moves this to FTS5.)
SEARCH_SQL_COMMENTS :: `SELECT resource_type, id, label, sublabel, route, score, parent_id, parent_type, match_text FROM (
  SELECT 'comment' AS resource_type, c.comment_id AS id,
         substr(c.body, 1, 160) AS label,
         'comment · task ' || c.task_id AS sublabel,
         '/chains/' || c.chain_id || '/tasks/' || c.task_id AS route,
         c.updated_at AS updated_at, c.owner_user_id AS owner_user_id,
         c.task_id AS scope_task_id, c.chain_id AS scope_chain_id, '' AS scope_project_id, '' AS scope_conversation_id,
         c.task_id AS parent_id, 'task' AS parent_type, c.body AS match_text,
         CASE
           WHEN lower(c.comment_id) = lower(?) THEN 98
           WHEN lower(c.body) LIKE lower(?) || '%' THEN 90
           WHEN lower(c.body) LIKE '% ' || lower(?) || '%' OR lower(c.body) LIKE '%-' || lower(?) || '%' OR lower(c.body) LIKE '%_' || lower(?) || '%' THEN 80
           WHEN lower(c.comment_id) LIKE lower(?) || '%' THEN 70
           ELSE 50
         END AS score
  FROM task_comments c
  JOIN tasks t ON t.task_id = c.task_id AND t.owner_user_id = c.owner_user_id
) WHERE owner_user_id = ? AND (lower(id) LIKE '%' || lower(?) || '%' OR lower(match_text) LIKE '%' || lower(?) || '%')
ORDER BY score DESC, updated_at DESC, id ASC LIMIT ?;`

// SEARCH_SQL_COMMENTS_FTS (SEARCH-6) is the FTS5 variant used when the
// task_comments_fts index exists. task_comments_fts MATCH does tokenized,
// multi-word matching (no full scan); the inner ORDER BY bm25 keeps the most
// relevant rows within the scan cap; snippet() yields the bracketed preview. The
// score tier (from the base row) is kept for cross-provider comparability + a
// stable cursor. Owner is AND-ed on the JOIN and again at the outer WHERE (where
// the typed-scope clause splices in).
SEARCH_SQL_COMMENTS_FTS :: `SELECT resource_type, id, label, sublabel, route, score, parent_id, parent_type, match_text FROM (
  SELECT 'comment' AS resource_type, c.comment_id AS id,
         substr(c.body, 1, 160) AS label,
         'comment · task ' || c.task_id AS sublabel,
         '/chains/' || c.chain_id || '/tasks/' || c.task_id AS route,
         c.updated_at AS updated_at, c.owner_user_id AS owner_user_id,
         c.task_id AS scope_task_id, c.chain_id AS scope_chain_id, '' AS scope_project_id, '' AS scope_conversation_id,
         c.task_id AS parent_id, 'task' AS parent_type,
         snippet(task_comments_fts, 0, '[', ']', '…', 12) AS match_text,
         CASE
           WHEN lower(c.comment_id) = lower(?) THEN 98
           WHEN lower(c.body) LIKE lower(?) || '%' THEN 90
           WHEN lower(c.body) LIKE '% ' || lower(?) || '%' OR lower(c.body) LIKE '%-' || lower(?) || '%' OR lower(c.body) LIKE '%_' || lower(?) || '%' THEN 80
           WHEN lower(c.comment_id) LIKE lower(?) || '%' THEN 70
           ELSE 50
         END AS score
  FROM task_comments_fts
  JOIN task_comments c ON c.rowid = task_comments_fts.rowid AND c.owner_user_id = ?
  JOIN tasks t ON t.task_id = c.task_id AND t.owner_user_id = c.owner_user_id
  WHERE task_comments_fts MATCH ?
  ORDER BY bm25(task_comments_fts)
  LIMIT ?
) WHERE owner_user_id = ?
ORDER BY score DESC, updated_at DESC, id ASC LIMIT ?;`
