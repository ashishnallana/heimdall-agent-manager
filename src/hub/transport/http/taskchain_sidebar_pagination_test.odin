package http

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(test)
test_flat_chain_cursor_ties_and_projects :: proc(t: ^testing.T) {
	items := []Chain_List_Item{
		{chain_id = "z", updated_at = "2026-10-01", created_at = "2026-01-01", project_id = "p1"},
		{chain_id = "b", updated_at = "2026-10-03", created_at = "2026-01-02", project_id = "p2"},
		{chain_id = "a", updated_at = "2026-10-03", created_at = "2026-01-03", project_id = ""},
		{chain_id = "c", updated_at = "2026-10-02", created_at = "2026-01-04", project_id = "p1"},
	}
	want := []string{"a", "b", "c", "z"}
	cursor := ""
	for id, i in want {
		page := paginate_flat_chains(items, 1, cursor)
		defer delete(page.chains)
		defer if page.next_cursor != "" do delete(page.next_cursor)
		if !testing.expect_value(t, len(page.chains), 1) do return
		testing.expect_value(t, page.chains[0].chain_id, id)
		testing.expect_value(t, page.has_more, i < len(want) - 1)
		if page.has_more do testing.expect(t, page.next_cursor != cursor && page.next_cursor != "", "cursor advances even on timestamp ties")
		cursor = strings.clone(page.next_cursor, context.temp_allocator)
	}
	empty := paginate_flat_chains(nil, 20, "")
	defer delete(empty.chains)
	testing.expect_value(t, len(empty.chains), 0)
	testing.expect(t, !empty.has_more && empty.next_cursor == "", "empty is exhausted")
	last := paginate_flat_chains(items, 20, "2026-10-01|z")
	defer delete(last.chains)
	testing.expect(t, len(last.chains) == 0 && !last.has_more && last.next_cursor == "", "past final cursor is exhausted")
	// Shared project helpers keep their original created_at descending order.
	project := paginate_project_chains(items, "p1", 1, "")
	defer delete(project.chains)
	defer if project.next_cursor != "" do delete(project.next_cursor)
	testing.expect_value(t, project.chains[0].chain_id, "c")
}

@(test)
test_flat_chain_handler_paging_and_legacy :: proc(t: ^testing.T) {
	f := wire_setup(t, "sidebar_pages")
	defer wire_teardown(f)
	for i in 0..<7 {
		id := fmt.aprintf("chain_sidebar_%02d", i)
		defer delete(id)
		_, _, _ = iface.taskchain_save_chain(&f.tc_repo, domain.Task_Chain{
			chain_id = domain.Task_Chain_ID(id), owner_user_id = f.owner,
			title = "vault:v2:7e57000000000001:e1:opaque", status = .Active,
			kind = domain.CHAIN_KIND_MIXED_WORK, publish_state = .Draft,
			created_at = "2026-01-01T00:00:00Z", updated_at = "2026-10-01T00:00:00Z",
		})
	}
	_, _, _ = iface.taskchain_save_chain(&f.tc_repo, domain.Task_Chain{
		chain_id = "chain_foreign", owner_user_id = "other_owner", title = "foreign",
		status = .Active, kind = domain.CHAIN_KIND_MIXED_WORK, publish_state = .Draft,
		created_at = "2026-01-01", updated_at = "2026-10-01",
	})
	_, _, _ = iface.taskchain_save_chain(&f.tc_repo, domain.Task_Chain{
		chain_id = "chain_archived", owner_user_id = f.owner, title = "archived",
		status = .Archived, kind = domain.CHAIN_KIND_MIXED_WORK, publish_state = .Draft,
		created_at = "2026-01-01", updated_at = "2026-10-01",
	})
	Envelope :: struct {
		data: []struct {chain_id: string, title: string},
		page: struct {limit: int, next_cursor: string, has_more: bool},
	}
	cursor := ""
	seen := make(map[string]bool)
	defer delete(seen)
	pages := 0
	for {
		req := wire_cookie_request(f, "GET", "/api/v1/task-chains", "")
		req.query = fmt.tprintf("flat=1&limit=2&cursor=%s", cursor)
		res := list_task_chains_handler(&f.th, req)
		if !testing.expect_value(t, res.status, 200) do return
		envelope: Envelope
		err := json.unmarshal_string(res.body, &envelope, allocator = context.temp_allocator)
		if !testing.expect_value(t, err, nil) do return
		testing.expect_value(t, envelope.page.limit, 2)
		testing.expect(t, len(envelope.data) <= 2, "bounded response")
		for row in envelope.data {
			testing.expect(t, !seen[row.chain_id], "every chain once")
			testing.expect(t, row.chain_id != "chain_foreign" && row.chain_id != "chain_archived", "owner/archive filters preserved")
			if strings.has_prefix(row.chain_id, "chain_sidebar_") do testing.expect_value(t, row.title, "vault:v2:7e57000000000001:e1:opaque")
			seen[strings.clone(row.chain_id, context.temp_allocator)] = true
		}
		pages += 1
		if !envelope.page.has_more do break
		if !testing.expect(t, pages < 10 && envelope.page.next_cursor != "", "paging terminates") do return
		cursor = strings.clone(envelope.page.next_cursor, context.temp_allocator)
	}
	testing.expect_value(t, len(seen), 8) // seven rows plus the fixture's chain
	testing.expect_value(t, pages, 4)
	req := wire_cookie_request(f, "GET", "/api/v1/task-chains", "")
	req.query = "flat=1"
	legacy := list_task_chains_handler(&f.th, req)
	testing.expect_value(t, legacy.status, 200)
	testing.expect(t, !strings.contains(legacy.body, `"page":`), "unparameterized flat response unchanged")
	testing.expect(t, strings.contains(legacy.body, "chain_sidebar_06"), "legacy flat is not preview capped")
	req.query = "flat=1&limit=10000"
	capped := list_task_chains_handler(&f.th, req)
	testing.expect(t, strings.contains(capped.body, fmt.tprintf(`"limit":%d`, TASK_CHAINS_PAGE_MAX)), "page cap enforced")
	req.query = "flat=1&limit=0"
	defaulted := list_task_chains_handler(&f.th, req)
	testing.expect(t, strings.contains(defaulted.body, fmt.tprintf(`"limit":%d`, TASK_CHAINS_PAGE_DEFAULT)), "invalid limit gets default")
	req.query = "flat=1&limit=2&has_tasks=1"
	filtered := list_task_chains_handler(&f.th, req)
	testing.expect(t, !strings.contains(filtered.body, "chain_sidebar_"), "task filter still applied before paging")
	unauthorized := list_task_chains_handler(&f.th, Request{method = "GET", path = "/api/v1/task-chains", query = "flat=1&limit=2"})
	testing.expect_value(t, unauthorized.status, 401)
}
