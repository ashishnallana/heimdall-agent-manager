package taskchain_grouping_test

// TC-API: unit tests for the project-grouped / per-project task-chains list
// helpers (group_chains_by_project, paginate_project_chains) and the wire
// serializer. These are the pure core of GET /api/v1/task-chains; the handler is
// a thin adapter that enriches chains with their project then calls these. Covers:
//   G1. grouping buckets by project, previews <=5 newest, reports chain_total +
//       has_more + next_cursor, and labels the empty-project bucket "Unassigned".
//   G2. groups are ordered by most-recent chain activity (newest chain first).
//   P1. per-project pagination returns `limit` newest, sets has_more/next_cursor.
//   P2. walking the created_at cursor to exhaustion yields every chain once, in
//       order, with no duplicates and a clean final page.
//   P3. the Unassigned bucket is pageable via project_id="".
//   S1. the chain serializer emits exactly the contractual field set.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import http "odin_test:hub/transport/http"

@(test)
test_taskchain_grouping :: proc(t: ^testing.T) {
	_ = t
	main()
}

mk :: proc(chain_id, updated_at, project_id, project_name: string) -> http.Chain_List_Item {
	return http.Chain_List_Item{
		chain_id = chain_id,
		title = strings.concatenate({"title-", chain_id}),
		status = "active",
		created_at = updated_at,
		updated_at = updated_at,
		coordinator_agent_instance_id = strings.concatenate({"inst-", chain_id}),
		project_id = project_id,
		project_name = project_name,
	}
}

find_group :: proc(groups: []http.Chain_Project_Group, project_id: string) -> (http.Chain_Project_Group, bool) {
	for g in groups { if g.project_id == project_id do return g, true }
	return {}, false
}

main :: proc() {
	// Deliberately unsorted input mixing three projects. Timestamps are chosen so
	// group activity order (P2 newest=09, Unassigned=07, P1 newest=06) differs from
	// first-seen order, and P1 has 6 chains to exercise the 5-preview cap.
	items := []http.Chain_List_Item{
		mk("a3", "2026-09-06T10:00:03Z", "p1", "Alpha"),
		mk("a6", "2026-09-06T10:00:06Z", "p1", "Alpha"),
		mk("a1", "2026-09-06T10:00:01Z", "p1", "Alpha"),
		mk("b9", "2026-09-06T10:00:09Z", "p2", "Beta"),
		mk("a4", "2026-09-06T10:00:04Z", "p1", "Alpha"),
		mk("u7", "2026-09-06T10:00:07Z", "", ""),          // no project -> Unassigned
		mk("a2", "2026-09-06T10:00:02Z", "p1", "Alpha"),
		mk("b8", "2026-09-06T10:00:08Z", "p2", "Beta"),
		mk("a5", "2026-09-06T10:00:05Z", "p1", "Alpha"),
	}

	// --- G1/G2: grouping ---
	groups := http.group_chains_by_project(items, 5)
	defer http.free_chain_project_groups(groups)
	check(len(groups) == 3, fmt.tprintf("G1: expected 3 project groups, got %d", len(groups)))

	// G2: ordered by most-recent chain activity: p2(09) > unassigned(07) > p1(06).
	check(groups[0].project_id == "p2", fmt.tprintf("G2: first group must be p2, got %q", groups[0].project_id))
	check(groups[1].project_id == "", fmt.tprintf("G2: second group must be Unassigned, got %q", groups[1].project_id))
	check(groups[2].project_id == "p1", fmt.tprintf("G2: third group must be p1, got %q", groups[2].project_id))

	p1, p1_ok := find_group(groups, "p1")
	check(p1_ok, "G1: p1 group must exist")
	check(p1.chain_total == 6, fmt.tprintf("G1: p1 chain_total must be 6, got %d", p1.chain_total))
	check(len(p1.chains) == 5, fmt.tprintf("G1: p1 preview must cap at 5, got %d", len(p1.chains)))
	check(p1.has_more, "G1: p1 has_more must be true (6 > 5)")
	// Preview is newest-first: a6,a5,a4,a3,a2; next_cursor is the last previewed.
	check(p1.chains[0].chain_id == "a6", fmt.tprintf("G1: p1 newest must be a6, got %q", p1.chains[0].chain_id))
	check(p1.chains[4].chain_id == "a2", fmt.tprintf("G1: p1 5th must be a2, got %q", p1.chains[4].chain_id))
	// next_cursor is the COMPOSITE (created_at|chain_id) of the last previewed chain.
	check(p1.next_cursor == "2026-09-06T10:00:02Z|a2", fmt.tprintf("G1: p1 next_cursor must be a2's composite cursor, got %q", p1.next_cursor))
	check(p1.project_name == "Alpha", fmt.tprintf("G1: p1 name must be Alpha, got %q", p1.project_name))

	p2, _ := find_group(groups, "p2")
	check(p2.chain_total == 2 && !p2.has_more && p2.next_cursor == "", "G1: p2 (2 chains) must have has_more=false, empty next_cursor")
	check(p2.chains[0].chain_id == "b9" && p2.chains[1].chain_id == "b8", "G1: p2 chains must be newest-first (b9,b8)")

	un, un_ok := find_group(groups, "")
	check(un_ok, "G1: Unassigned group must exist")
	check(un.project_name == "Unassigned", fmt.tprintf("G1: empty-project bucket must be labeled Unassigned, got %q", un.project_name))
	check(un.chain_total == 1 && len(un.chains) == 1, "G1: Unassigned must hold its single chain")

	// --- P1/P2: per-project cursor pagination over p1 (6 chains), limit 2 ---
	seen := make([dynamic]string); defer delete(seen)
	cursor := ""
	pages := 0
	for {
		page := http.paginate_project_chains(items, "p1", 2, cursor)
		defer delete(page.chains)
		pages += 1
		check(pages <= 10, "P2: pagination did not terminate")
		check(page.project_id == "p1" && page.project_name == "Alpha", "P1: page must carry project id+name")
		// chain_total is the full project match count, independent of limit/cursor.
		check(page.chain_total == 6, fmt.tprintf("P1: page chain_total must be 6 on every page, got %d", page.chain_total))
		check(len(page.chains) <= 2, fmt.tprintf("P1: page must respect limit 2, got %d", len(page.chains)))
		for c in page.chains do append(&seen, c.chain_id)
		// Each page item sorts strictly after the previous (composite) cursor.
		if cursor != "" {
			cur_at, _ := http.chain_cursor_decode(cursor)
			for c in page.chains do check(c.created_at <= cur_at, "P2: page item must be at/older than the cursor timestamp")
		}
		if !page.has_more { check(page.next_cursor == "", "P2: final page must have empty next_cursor"); break }
		check(page.next_cursor != "", "P2: non-final page must expose a next_cursor")
		cursor = page.next_cursor
	}
	check(len(seen) == 6, fmt.tprintf("P2: must see all 6 p1 chains across pages, got %d", len(seen)))
	// Newest-first, no duplicates, exact order.
	want := []string{"a6", "a5", "a4", "a3", "a2", "a1"}
	for w, i in want do check(seen[i] == w, fmt.tprintf("P2: chain %d must be %q, got %q", i, w, seen[i]))

	// --- P3: Unassigned pageable via project_id="" ---
	un_page := http.paginate_project_chains(items, "", 20, "")
	defer delete(un_page.chains)
	check(un_page.project_name == "Unassigned", "P3: empty project_id page must be labeled Unassigned")
	check(len(un_page.chains) == 1 && un_page.chains[0].chain_id == "u7" && !un_page.has_more, "P3: Unassigned page must hold u7 only")
	check(un_page.chain_total == 1, fmt.tprintf("P3: Unassigned chain_total must be 1, got %d", un_page.chain_total))

	// --- P4: TIED created_at straddling the page boundary must not drop a chain ---
	// Reviewer's repro: one project, (T2,'tb'),(T2,'ta'),(T1,'tc'), limit=1. A
	// pure-created_at cursor would skip the second T2 row forever; the composite
	// (created_at,chain_id) cursor returns all three exactly once, newest-first.
	tied := []http.Chain_List_Item{
		mk("tb", "2026-09-06T11:00:02Z", "pt", "Tied"),
		mk("tc", "2026-09-06T11:00:01Z", "pt", "Tied"),
		mk("ta", "2026-09-06T11:00:02Z", "pt", "Tied"),
	}
	tied_seen := make([dynamic]string); defer delete(tied_seen)
	tied_cursor := ""
	tied_pages := 0
	for {
		page := http.paginate_project_chains(tied, "pt", 1, tied_cursor)
		defer delete(page.chains)
		// NB: next_cursor is reused as the next iteration's cursor, so it must not be
		// freed here; it's a short-lived per-page string in this test.
		tied_pages += 1
		check(tied_pages <= 10, "P4: tied pagination did not terminate")
		check(page.chain_total == 3, fmt.tprintf("P4: chain_total must be 3 on every page, got %d", page.chain_total))
		for c in page.chains do append(&tied_seen, c.chain_id)
		if !page.has_more do break
		tied_cursor = page.next_cursor
	}
	check(len(tied_seen) == 3, fmt.tprintf("P4: must see all 3 tied chains, got %d", len(tied_seen)))
	tied_want := []string{"tb", "ta", "tc"} // T2/tb, T2/ta (chain_id desc tie-break), then T1/tc
	for w, i in tied_want do check(tied_seen[i] == w, fmt.tprintf("P4: tied chain %d must be %q, got %q", i, w, tied_seen[i]))

	// --- S1: serializer emits exactly the contractual field set ---
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	http.write_chain_list_item_json(&b, http.Chain_List_Item{
		chain_id = "c1", title = "t1", status = "active", updated_at = "2026-09-06T10:00:06Z",
		coordinator_agent_instance_id = "inst_x", project_id = "p1", project_name = "Alpha",
	})
	got := strings.to_string(b)
	want_json := `{"chain_id":"c1","title":"t1","status":"active","updated_at":"2026-09-06T10:00:06Z","coordinator_agent_instance_id":"inst_x","project_id":"p1","project_name":"Alpha","task_count":0,"completed_task_count":0,"user_validation_count":0,"is_pinned":false,"pinned_at":""}`
	check(got == want_json, fmt.tprintf("S1: serializer mismatch\n got: %s\nwant: %s", got, want_json))

	fmt.println("PASS: TC-API task-chain grouping + per-project pagination")
}

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln(message); os.exit(1) }
