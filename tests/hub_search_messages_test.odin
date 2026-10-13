// MSG-1 coverage: chat MESSAGE bodies are searchable via chat_messages_fts
// (migration 031) through the 'message' search provider. Verifies a body match is
// found through the REAL insert path (content repo save_message => AI trigger),
// carries id=message_id + route=/conversations/<agent_instance_id> +
// sublabel=conversation title + a body preview, is owner-isolated, surfaces by
// DEFAULT (no explicit types filter), and EXCLUDES non-user-visible rows
// (direction=agent_to_agent and non-'text' message_type).
package hub_search_messages_test

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

seed_conversation :: proc(repo: ^iface.Content_Repository, id, owner, inst, title: string) {
	_, ok, err := iface.content_save_conversation(repo, domain.Chat_Conversation{
		conversation_id = id, owner_user_id = domain.User_ID(owner),
		agent_id = "agt", agent_instance_id = inst, title = title,
		created_at = TS, updated_at = TS,
	})
	check(ok, fmt.tprintf("seed conversation %s: %s", id, err.message))
}

seed_message :: proc(repo: ^iface.Content_Repository, id, conv, owner, direction, mtype, body: string) {
	seed_message_at(repo, id, conv, owner, direction, mtype, body, TS)
}

// seed_message_at is seed_message with an explicit created_at, so a test can place
// messages at known chronological positions (incl. deliberate timestamp collisions
// to exercise the (created_at, message_id) tiebreak used by conversation_position).
seed_message_at :: proc(repo: ^iface.Content_Repository, id, conv, owner, direction, mtype, body, created_at: string) {
	_, ok, err := iface.content_save_message(repo, domain.Chat_Message{
		message_id = id, conversation_id = conv, owner_user_id = domain.User_ID(owner),
		direction = direction, message_type = mtype, message_status = "complete",
		body = body, created_at = created_at,
	})
	check(ok, fmt.tprintf("seed message %s: %s", id, err.message))
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

@(test)
test_hub_search_messages_test :: proc(t: ^testing.T) {
	_ = t
	main()
}

main :: proc() {
	db_path := "/tmp/hub_search_messages.db"
	_ = os.remove(db_path); defer _ = os.remove(db_path)
	conn, open_ok, open_err := sqlite.open(db_path)
	check(open_ok, fmt.tprintf("open db: %s", open_err.message))
	defer sqlite.close(&conn)
	check(sqlite.fts5_available(&conn), "FTS5 must be available")
	mig_ok, mig_err := sqlite.run_migrations(&conn, "src/hub/repository/sqlite/migrations")
	check(mig_ok, fmt.tprintf("run_migrations: %s", mig_err.message))
	check(sqlite.sqlite_object_exists(&conn, "chat_messages_fts"), "migration 031 must create chat_messages_fts")

	content_impl: sqlite.Content_Repo_SQLite
	crepo := sqlite.new_content_repository(&content_impl, &conn)

	// Owner u: one visible text message (should match) + two non-visible variants.
	seed_conversation(&crepo, "cid_u", "u", "inst_u", "Deploy chat")
	seed_message(&crepo, "msg_u", "cid_u", "u", "user_to_agent", "text", "please zephyrmatch the deploy runbook")
	seed_message(&crepo, "msg_u_a2a", "cid_u", "u", "agent_to_agent", "text", "zephyrmatch agent-to-agent chatter")
	seed_message(&crepo, "msg_u_status", "cid_u", "u", "agent_to_user", "status_update", "zephyrmatch status update")
	// Owner v: isolation control.
	seed_conversation(&crepo, "cid_v", "v", "inst_v", "Other chat")
	seed_message(&crepo, "msg_v", "cid_v", "v", "user_to_agent", "text", "zephyrmatch foreign body")

	repo_impl: sqlite.Search_Repo_SQLite
	repo := sqlite.new_search_repository(&repo_impl, &conn)

	// (1) body match found with the agreed hit shape (id/route/sublabel/preview).
	res := search(&repo, "u", "zephyrmatch", "message")
	hit, ok := find(res.hits, "msg_u")
	check(ok, "owner u must find their visible text message by body")
	check(hit.resource_type == "message", fmt.tprintf("resource_type must be 'message', got %q", hit.resource_type))
	check(hit.route == "/conversations/inst_u", fmt.tprintf("route must be /conversations/<agent_instance_id>, got %q", hit.route))
	check(hit.sublabel == "Deploy chat", fmt.tprintf("sublabel must be the conversation title, got %q", hit.sublabel))
	check(strings.contains(hit.preview, "zephyrmatch"), fmt.tprintf("preview must include the matched body term, got %q", hit.preview))

	// (2) non-user-visible rows are excluded (agent_to_agent + non-'text').
	_, a2a := find(res.hits, "msg_u_a2a")
	check(!a2a, "agent_to_agent messages must NOT be surfaced")
	_, sys := find(res.hits, "msg_u_status")
	check(!sys, "non-'text' (status_update) messages must NOT be surfaced")

	// (3) owner isolation both ways.
	_, leaked := find(res.hits, "msg_v")
	check(!leaked, "owner u must not see owner v's message")
	res_v := search(&repo, "v", "zephyrmatch", "message")
	_, v_ok := find(res_v.hits, "msg_v")
	check(v_ok, "owner v must find their own message")
	_, u_leak := find(res_v.hits, "msg_u")
	check(!u_leak, "owner v must not see owner u's message")

	// (4) messages surface by DEFAULT (no explicit types filter) — wired into
	// SEARCH_TYPE_ORDER + normalize_search_type so REST/RPC/ctl all include them.
	res_all := search(&repo, "u", "zephyrmatch", "")
	_, default_ok := find(res_all.hits, "msg_u")
	check(default_ok, "message hits must appear in an unfiltered (all-types) search")

	// (5) MSG-2 conversation_position / conversation_total. Seed a conversation with
	// 5 user-visible text messages at known chronological positions — including TWO
	// sharing an identical created_at (pm_3a/pm_3b) so the (created_at, message_id)
	// tiebreak is exercised — plus two NON-visible rows (agent_to_agent + non-'text')
	// that must be excluded from both the results AND the position/total counts.
	seed_conversation(&crepo, "cid_pos", "u", "inst_pos", "Position chat")
	seed_message_at(&crepo, "pm_1",  "cid_pos", "u", "user_to_agent",  "text", "positronix one",   "2026-02-01T00:00:01Z")
	seed_message_at(&crepo, "pm_2",  "cid_pos", "u", "agent_to_user",  "text", "positronix two",   "2026-02-01T00:00:02Z")
	// Identical timestamp: ordered by message_id asc => pm_3a (pos 3) before pm_3b (pos 4).
	seed_message_at(&crepo, "pm_3a", "cid_pos", "u", "user_to_agent",  "text", "positronix three", "2026-02-01T00:00:03Z")
	seed_message_at(&crepo, "pm_3b", "cid_pos", "u", "agent_to_user",  "text", "positronix four",  "2026-02-01T00:00:03Z")
	seed_message_at(&crepo, "pm_5",  "cid_pos", "u", "user_to_agent",  "text", "positronix five",  "2026-02-01T00:00:04Z")
	// Non-visible rows carrying the same token — must not count toward total/position.
	seed_message_at(&crepo, "pm_a2a",    "cid_pos", "u", "agent_to_agent", "text",          "positronix hidden a2a",  "2026-02-01T00:00:00Z")
	seed_message_at(&crepo, "pm_status", "cid_pos", "u", "agent_to_user",  "status_update", "positronix hidden stat", "2026-02-01T00:00:05Z")

	res_pos := search(&repo, "u", "positronix", "message")
	// Expected (created_at, message_id) order: pm_1, pm_2, pm_3a, pm_3b, pm_5.
	expected_ids := [?]string{"pm_1", "pm_2", "pm_3a", "pm_3b", "pm_5"}
	for want_id, i in expected_ids {
		want_pos := i + 1
		hit, found := find(res_pos.hits, want_id)
		check(found, fmt.tprintf("position: %s must be returned", want_id))
		check(hit.conversation_position == want_pos, fmt.tprintf("%s conversation_position must be %d, got %d", want_id, want_pos, hit.conversation_position))
		check(hit.conversation_total == 5, fmt.tprintf("%s conversation_total must be 5 (visible text only), got %d", want_id, hit.conversation_total))
	}
	// Non-visible rows excluded from the results entirely.
	_, has_a2a := find(res_pos.hits, "pm_a2a")
	check(!has_a2a, "agent_to_agent message must not appear in position results")
	_, has_stat := find(res_pos.hits, "pm_status")
	check(!has_stat, "status_update message must not appear in position results")

	// (6) position/total are owner-scoped: owner v's own message is position 1 of 1
	// and owner u's positronix rows never leak into v's search.
	seed_conversation(&crepo, "cid_pos_v", "v", "inst_pos_v", "V position chat")
	seed_message_at(&crepo, "pv_1", "cid_pos_v", "v", "user_to_agent", "text", "positronix v-only", "2026-02-01T00:00:01Z")
	res_pos_v := search(&repo, "v", "positronix", "message")
	pv, pv_ok := find(res_pos_v.hits, "pv_1")
	check(pv_ok, "owner v must find their own positronix message")
	check(pv.conversation_position == 1 && pv.conversation_total == 1, fmt.tprintf("owner v position must be 1 of 1, got %d of %d", pv.conversation_position, pv.conversation_total))
	_, u_pos_leak := find(res_pos_v.hits, "pm_1")
	check(!u_pos_leak, "owner v must not see owner u's positronix messages")

	fmt.println("PASS: hub search messages (body match + shape + visibility filter + owner isolation + default type + conversation_position/total incl. created_at tiebreak)")
}
