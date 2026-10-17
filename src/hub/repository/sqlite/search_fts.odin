package sqlite

import "core:fmt"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// SEARCH-10: FTS5-everywhere. Each text-bearing entity provider has a per-table
// external-content FTS5 index (migration 030). One generic builder + a descriptor
// per provider produces the FTS query (vs 8 hand-written constants), so the shape
// stays identical to the LIKE providers: same emitted columns, the SEARCH-8 typed
// scope columns, the cursor ORDER-BY anchor, and snippet()-based preview.
//
// Scoring: a tier CASE on the PRIMARY (title/name) field — exact=100 / prefix=90 /
// word-boundary=80 — with ELSE=40 (FTS_TIER_SECONDARY) as the SECONDARY/BODY-match
// tier (the row matched via FTS in a secondary/body column but not the primary
// field), unified with the skills content-only tier. So title/name matches rank
// above body/description
// matches, and nothing that matched FTS is silently scored 0. Field-weighted bm25
// (primary column weighted highest) orders the per-provider scan-cap selection.
// A static TYPE_PRIORITY addend (applied in the merge) only breaks same-tier ties.
//
// Recency: the existing `updated_at DESC` secondary sort in the anchor IS the
// recency mechanism (deterministic + cursor-safe); recency is NOT blended into the
// score (that would make the cursor key time-dependent).

Fts_Provider :: struct {
	resource_type:         string,
	base:                  string, // base table (aliased c in the query)
	fts:                   string, // external-content FTS5 vtable
	join_sql:              string, // optional extra JOIN (e.g. messages -> chat_conversations as cc) or ''
	where_extra:           string, // optional literal inner-WHERE predicate (no binds), AND-ed after MATCH, or ''
	id_expr:               string, // emitted id column (c.<id>)
	label_expr:            string,
	sublabel_expr:         string,
	route_expr:            string,
	primary_expr:          string, // primary text field for the tier CASE (fts col 0)
	recency_expr:          string, // ORDER-BY/cursor recency column; '' => c.updated_at (chat_messages has only created_at)
	scope_task:            string, // scope_task_id expr or '' (see SEARCH-8)
	scope_chain:           string,
	scope_project:         string,
	scope_conversation:    string,
	bm25_weights:          string, // CSV of bm25 column weights, primary first
	secondary_field:       string, // matched_field label for the ELSE(=40) tier
	// MSG-2: optional scalar SQL exprs (over the base row `c`) for the message
	// provider's in-conversation position/total. Empty => emitted as '0' (the
	// non-message default), so the emitted-column count stays uniform across providers.
	position_expr:         string,
	total_expr:            string,
}

// FTS_WEIGHT_* are the field weights fed to bm25(): the primary title/name column
// ranks highest, secondary name-like fields next, free body/description lowest.
// Canonical tier ladder: exact 100 / id-exact 98 / prefix 90 / word-boundary 80 /
// id-prefix 70 / primary-interior 50 / secondary-or-content 40. A primary match
// (>=50) always outranks a secondary/body-only match (40).
FTS_TIER_SECONDARY :: 40 // a match in a secondary/body column (not the primary field)

FTS_PROVIDERS := []Fts_Provider{
		{
			resource_type = "conversation", base = "chat_conversations", fts = "chat_conversations_fts",
			id_expr = "c.agent_instance_id",
			label_expr = "CASE WHEN c.title != '' THEN c.title ELSE c.agent_id END",
			sublabel_expr = "c.agent_id || ' \u00b7 chain ' || c.chain_id",
			route_expr = "'/conversations/' || c.agent_instance_id",
			primary_expr = "c.title",
			scope_chain = "c.chain_id", scope_project = "c.project_id", scope_conversation = "c.conversation_id",
			bm25_weights = "10.0", secondary_field = "title",
		},
		{
			resource_type = "agent", base = "agents", fts = "agents_fts",
			id_expr = "c.agent_id", label_expr = "c.name",
			sublabel_expr = "'slug ' || c.slug || ' \u00b7 ' || c.state",
			route_expr = "'/agents/' || c.agent_id", primary_expr = "c.name",
			bm25_weights = "10.0, 2.0, 1.0", secondary_field = "slug",
		},
		{
			resource_type = "agent_instance", base = "agent_instances", fts = "agent_instances_fts",
			id_expr = "c.agent_instance_id", label_expr = "c.agent_id",
			sublabel_expr = "c.runtime_status || ' \u00b7 ' || c.provider || '/' || c.model",
			route_expr = "CASE WHEN c.agent_instance_id != '' THEN '/conversations/' || c.agent_instance_id ELSE '/agents/' || c.agent_id END",
			primary_expr = "c.display_name",
			scope_chain = "c.chain_id", scope_project = "c.project_id", scope_conversation = "c.conversation_id",
			bm25_weights = "5.0, 1.0", secondary_field = "agent_id",
		},
		{
			resource_type = "task-chain", base = "task_chains", fts = "task_chains_fts",
			id_expr = "c.chain_id", label_expr = "c.title",
			sublabel_expr = "c.kind || ' \u00b7 ' || c.status",
			route_expr = "'/chains/' || c.chain_id", primary_expr = "c.title",
			scope_chain = "c.chain_id", bm25_weights = "10.0, 1.0", secondary_field = "description",
		},
		{
			resource_type = "task", base = "tasks", fts = "tasks_fts",
			id_expr = "c.task_id", label_expr = "c.title",
			sublabel_expr = "'chain ' || c.chain_id || ' \u00b7 ' || c.state",
			route_expr = "'/chains/' || c.chain_id || '/tasks/' || c.task_id", primary_expr = "c.title",
			scope_task = "c.task_id", scope_chain = "c.chain_id", bm25_weights = "10.0, 1.0", secondary_field = "description",
		},
		{
			resource_type = "project", base = "projects", fts = "projects_fts",
			id_expr = "c.project_id", label_expr = "c.name",
			sublabel_expr = "c.slug || ' \u00b7 ' || c.vcs_kind",
			route_expr = "'/settings/projects/' || c.project_id", primary_expr = "c.name",
			scope_project = "c.project_id", bm25_weights = "10.0, 2.0, 1.0", secondary_field = "description",
		},
		{
			resource_type = "artifact", base = "artifacts", fts = "artifacts_fts",
			id_expr = "c.artifact_id", label_expr = "c.name",
			sublabel_expr = "c.kind || ' \u00b7 ' || c.content_type",
			route_expr = "'/library/artifacts/' || c.artifact_id", primary_expr = "c.name",
			scope_task = "c.task_id", scope_chain = "c.chain_id", scope_project = "c.project_id",
			bm25_weights = "10.0, 1.0", secondary_field = "description",
		},
		{
			resource_type = "memory", base = "memories", fts = "memories_fts",
			id_expr = "c.memory_id",
			label_expr = "CASE WHEN c.title != '' THEN c.title ELSE c.type END",
			sublabel_expr = "c.type || ' \u00b7 ' || c.status",
			route_expr = "'/settings/memory?memory_id=' || c.memory_id", primary_expr = "c.title",
			bm25_weights = "10.0, 1.0", secondary_field = "body",
		},
		{
			// MSG-1: chat message bodies. Joins chat_conversations (cc) for the route
			// (instance-id-only conversation route) + the conversation title sublabel.
			// Only user-visible text messages are surfaced (agent-to-agent + system/pane
			// messages are excluded), mirroring list_user_visible_messages semantics.
			resource_type = "message", base = "chat_messages", fts = "chat_messages_fts",
			join_sql = "JOIN chat_conversations cc ON cc.conversation_id = c.conversation_id AND cc.owner_user_id = c.owner_user_id",
			where_extra = "c.direction != 'agent_to_agent' AND c.message_type = 'text'",
			id_expr = "c.message_id",
			label_expr = "substr(c.body, 1, 140)",
			sublabel_expr = "CASE WHEN cc.title != '' THEN cc.title ELSE cc.agent_id END",
			route_expr = "'/conversations/' || cc.agent_instance_id", primary_expr = "c.body",
			recency_expr = "c.created_at", // chat_messages has no updated_at column
			scope_chain = "cc.chain_id", scope_project = "cc.project_id", scope_conversation = "c.conversation_id",
			bm25_weights = "10.0", secondary_field = "body",
			// MSG-2: 1-based index of this message within its conversation's user-visible
			// timeline, and the total size of that set. The predicate mirrors where_extra
			// (this provider's own visibility filter) so position is consistent with the
			// rows this provider surfaces; ordering by (created_at, message_id) is
			// deterministic even when timestamps collide. Correlated over the base row `c`.
			position_expr = "(SELECT COUNT(*) FROM chat_messages mp WHERE mp.conversation_id = c.conversation_id AND mp.owner_user_id = c.owner_user_id AND mp.direction != 'agent_to_agent' AND mp.message_type = 'text' AND (mp.created_at < c.created_at OR (mp.created_at = c.created_at AND mp.message_id <= c.message_id)))",
			total_expr = "(SELECT COUNT(*) FROM chat_messages mp WHERE mp.conversation_id = c.conversation_id AND mp.owner_user_id = c.owner_user_id AND mp.direction != 'agent_to_agent' AND mp.message_type = 'text')",
		},
}

fts_provider_for :: proc(resource_type: string) -> (Fts_Provider, bool) {
	for p in FTS_PROVIDERS do if p.resource_type == resource_type do return p, true
	return Fts_Provider{}, false
}

// col_or_empty renders a scope column expr, defaulting to '' when the provider has
// no such containment parent (so a positive typed filter excludes it — SEARCH-8).
@(private = "file")
col_or_empty :: proc(expr: string) -> string {
	return expr == "" ? "''" : expr
}

// build_fts_sql renders the provider's FTS query. The outer WHERE + ORDER-BY anchor
// mirror the LIKE providers so the SEARCH-8 scope clause splices in identically and
// the merge/cursor pipeline is unchanged.
build_fts_sql :: proc(d: Fts_Provider) -> string {
	b := strings.builder_make()
	fmt.sbprintf(&b, "SELECT resource_type, id, label, sublabel, route, score, parent_id, parent_type, match_text, conversation_position, conversation_total FROM (\n")
	recency := d.recency_expr != "" ? d.recency_expr : "c.updated_at"
	// MSG-2 position/total: emitted for every provider (default '0') so the outer
	// column indices stay uniform; only the message provider sets these exprs.
	position := d.position_expr != "" ? d.position_expr : "0"
	total := d.total_expr != "" ? d.total_expr : "0"
	fmt.sbprintf(&b, "  SELECT '%s' AS resource_type, %s AS id, %s AS label, %s AS sublabel, %s AS route, %s AS updated_at, c.owner_user_id AS owner_user_id, %s AS scope_task_id, %s AS scope_chain_id, %s AS scope_project_id, %s AS scope_conversation_id, '' AS parent_id, '' AS parent_type, snippet(%s, -1, '[', ']', '\u2026', 10) AS match_text, %s AS conversation_position, %s AS conversation_total,\n",
		d.resource_type, d.id_expr, d.label_expr, d.sublabel_expr, d.route_expr, recency,
		col_or_empty(d.scope_task), col_or_empty(d.scope_chain), col_or_empty(d.scope_project), col_or_empty(d.scope_conversation), d.fts, position, total)
	// Tier on the primary field: exact 100 / prefix 90 / word-boundary 80 /
	// primary-interior 50; ELSE the row matched FTS only in a secondary/body column
	// => the unified secondary tier (40). (FTS providers don't index ids, so the
	// 98/70 id tiers of the canonical ladder simply don't occur here.)
	fmt.sbprintf(&b, "    CASE WHEN lower(%s) = lower(?) THEN 100 WHEN lower(%s) LIKE lower(?) || '%%' THEN 90 WHEN lower(%s) LIKE '%% ' || lower(?) || '%%' OR lower(%s) LIKE '%%-' || lower(?) || '%%' OR lower(%s) LIKE '%%_' || lower(?) || '%%' THEN 80 WHEN lower(%s) LIKE '%%' || lower(?) || '%%' THEN 50 ELSE %d END AS score\n",
		d.primary_expr, d.primary_expr, d.primary_expr, d.primary_expr, d.primary_expr, d.primary_expr, FTS_TIER_SECONDARY)
	fmt.sbprintf(&b, "  FROM %s JOIN %s c ON c.rowid = %s.rowid AND c.owner_user_id = ?\n", d.fts, d.base, d.fts)
	if d.join_sql != "" do fmt.sbprintf(&b, "  %s\n", d.join_sql)
	fmt.sbprintf(&b, "  WHERE %s MATCH ?", d.fts)
	if d.where_extra != "" do fmt.sbprintf(&b, " AND (%s)", d.where_extra)
	fmt.sbprintf(&b, "\n  ORDER BY bm25(%s, %s)\n  LIMIT ?\n", d.fts, d.bm25_weights)
	fmt.sbprintf(&b, ") WHERE owner_user_id = ?\n%s;", SCOPE_SQL_ANCHOR)
	return strings.to_string(b)
}

// run_fts_search executes a provider's FTS query. Binding: CASE q (1-5), owner on
// the JOIN (6), the FTS MATCH term (7), inner bm25 LIMIT (8), owner on the outer
// WHERE (9), the typed-scope values, then the outer LIMIT.
run_fts_search :: proc(impl: ^Search_Repo_SQLite, d: Fts_Provider, query: iface.Search_Query, scope_clause: string, scope_values: []string) -> ([]iface.Search_Hit, bool, domain.Domain_Error) {
	match_term := fts_match_query(query.q)
	defer delete(match_term)
	if match_term == "" do return nil, false, domain.Domain_Error{}
	base_sql := build_fts_sql(d)
	defer delete(base_sql)

	final_sql := base_sql
	if scope_clause != "" {
		anchor_at := strings.index(base_sql, SCOPE_SQL_ANCHOR)
		if anchor_at < 0 do return nil, false, domain.domain_error(.Internal_Error, "fts query is missing its order-by anchor")
		final_sql = strings.concatenate({base_sql[:anchor_at], scope_clause, "\n", base_sql[anchor_at:]})
	}
	defer if final_sql != base_sql do delete(final_sql)
	sql_c := strings.clone_to_cstring(final_sql)
	defer delete(sql_c)

	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(impl.conn.db, sql_c, -1, &stmt, nil) != SQLITE_OK do return nil, false, domain.domain_error(.Internal_Error, fmt.tprintf("failed to prepare fts search query (%s): %s", d.resource_type, string(sqlite3_errmsg(impl.conn.db))))
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
		hit.preview = collapse_ws_string(column_text(stmt, 8))
		// MSG-2: cols 9/10 are the in-conversation position/total (0 for non-message
		// providers, which the JSON writer omits).
		hit.conversation_position = int_v(column_text(stmt, 9))
		hit.conversation_total = int_v(column_text(stmt, 10))
		// Primary-field match (tier >=50) => matched_field=label; the secondary tier
		// (40) means the row matched a secondary/body column via FTS.
		hit.matched_field = hit.score >= 50 ? "label" : d.secondary_field
		append(&raw_rows, hit)
	}
	return raw_rows[:], len(raw_rows) >= query.hard_scan_cap, domain.Domain_Error{}
}

// type_priority is a small static, tunable boost that ONLY disambiguates same-tier
// ties ACROSS resource types (tiers are spaced >=10 apart and this addend is <=4,
// so it can never lift a lower match tier above a higher one). Applied in the merge.
type_priority :: proc(resource_type: string) -> int {
	switch resource_type {
	case "conversation": return 4
	case "message":      return 4 // chat message bodies are high-value; ties with conversation/task, tiebreak only
	case "task":         return 4
	case "task-chain":   return 3
	case "agent":        return 3
	case "agent_instance": return 2
	case "project":      return 2
	case "memory":       return 2
	case "artifact":     return 1
	case "comment":      return 1
	case "skill":        return 0
	}
	return 0
}

// effective_score folds the static TYPE_PRIORITY into the score for ORDERING and
// the cursor key ONLY. The emitted hit.score stays the pure tier (so the ladder is
// observable), while ordering/paging use tier + priority. Deterministic because
// priority is a pure function of resource_type (so the cursor stays stable).
effective_score :: proc(hit: iface.Search_Hit) -> int {
	return hit.score + type_priority(hit.resource_type)
}
