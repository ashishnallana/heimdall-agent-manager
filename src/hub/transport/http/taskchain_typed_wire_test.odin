// Behavioral tests for taskchain HTTP wire contracts, task creation (priority, depends_on), archive filtering, directories, and pinned serialization.
package http

import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:testing"

// --- Consolidated from taskchain_typed_wire_test.odin ---

@(test)
test_task_wire_escaped_characters_and_markdown :: proc(t: ^testing.T) {
	special_title := "Fix: \"quotes\" & \\backslashes\\ and \n newlines \t tabs <tag> [link](url)"
	special_desc := "Line 1\nLine 2\r\n\"Quoted\" \\back\\ \t tab \b \f \x01 \x1f print(\"code\")"

	task := domain.Task{
		task_id            = domain.Task_ID("task_escape_1"),
		chain_id           = domain.Task_Chain_ID("chain_escape_1"),
		owner_user_id      = domain.User_ID("usr_admin"),
		title              = special_title,
		description        = special_desc,
		publish_state      = .Published,
		status             = .Assigned,
		priority           = .P1,
		bridge_id          = "brg_123",
		assignee_ref_json  = `{"type":"agent_instance","agent_instance_id":"inst_worker_1"}`,
		reviewer_refs_json = `[{"type":"user","user_id":"usr_admin"}]`,
		updated_at         = "2026-10-03T12:00:00Z",
	}

	b := strings.builder_make(context.temp_allocator)
	write_task_json(&b, task)
	payload := strings.to_string(b)

	val, err := json.parse_string(payload, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	testing.expect(t, err == .None, "marshaled task json must parse cleanly")

	#partial switch obj in val {
	case json.Object:
		title_val, ok1 := obj["title"].(json.String)
		testing.expect(t, ok1, "title field must be present as a string")
		testing.expect_value(t, string(title_val), special_title)

		desc_val, ok2 := obj["description"].(json.String)
		testing.expect(t, ok2, "description field must be present as a string")
		testing.expect_value(t, string(desc_val), special_desc)

		bridge_val, ok3 := obj["bridge_id"].(json.String)
		testing.expect(t, ok3, "bridge_id must be present as a string")
		testing.expect_value(t, string(bridge_val), "brg_123")

		requires_approval, ok4 := obj["requires_user_approval"].(json.Boolean)
		testing.expect(t, ok4 && bool(requires_approval), "wire task must derive requires_user_approval")
		reviewers := obj["reviewer_refs"].(json.Array)
		reviewer := reviewers[0].(json.Object)
		username, username_ok := reviewer["username"].(json.String)
		testing.expect(t, username_ok, "user reviewer wire entry must include username")
		testing.expect_value(t, string(username), "usr_admin")
	case:
		testing.fail_now(t, "expected json.Object payload")
	}
}

@(test)
test_task_matches_query_actor_ref_resilience_and_no_substring_false_positives :: proc(t: ^testing.T) {
	// Keys reversed with extra spaces
	task1 := domain.Task{
		task_id            = domain.Task_ID("task_1"),
		assignee_ref_json  = `  { "display_name": "worker #1",  "agent_instance_id": "inst_123", "type": "agent_instance" }  `,
		reviewer_refs_json = ` [ { "user_id": "usr_reviewer_1", "type": "user" }, { "agent_instance_id": "inst_rev_2", "type": "agent_instance" } ] `,
	}

	// 1. Exact match works despite whitespace and key reordering
	testing.expect(t, task_matches_query(task1, "assignee_agent_instance_id=inst_123"), "exact assignee must match")
	testing.expect(t, task_matches_query(task1, "reviewer_agent_instance_id=inst_rev_2"), "exact reviewer agent must match")
	testing.expect(t, task_matches_query(task1, "reviewer_user_id=usr_reviewer_1"), "exact reviewer user must match")

	// 2. Substring matching is strictly rejected (preventing false positives)
	testing.expect(t, !task_matches_query(task1, "assignee_agent_instance_id=inst_12"), "prefix substring must NOT match")
	testing.expect(t, !task_matches_query(task1, "assignee_agent_instance_id=23"), "suffix substring must NOT match")
	testing.expect(t, !task_matches_query(task1, "reviewer_agent_instance_id=inst_rev"), "reviewer prefix substring must NOT match")
	testing.expect(t, !task_matches_query(task1, "reviewer_user_id=usr_rev"), "reviewer user prefix substring must NOT match")

	// 3. Different ID does not match
	testing.expect(t, !task_matches_query(task1, "assignee_agent_instance_id=inst_other"), "different assignee must not match")
	testing.expect(t, !task_matches_query(task1, "reviewer_agent_instance_id=inst_other"), "different reviewer agent must not match")
	testing.expect(t, !task_matches_query(task1, "reviewer_user_id=usr_other"), "different reviewer user must not match")

	// 4. Combined queries require both to match
	testing.expect(t, task_matches_query(task1, "reviewer_user_id=usr_reviewer_1&reviewer_agent_instance_id=inst_rev_2"), "both matching reviewer query params must match")
	testing.expect(t, !task_matches_query(task1, "reviewer_user_id=usr_reviewer_1&reviewer_agent_instance_id=inst_other"), "mismatched reviewer agent in combined query must fail")
}

@(test)
test_taskchain_typed_wire_tracking_allocator_clean :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	context.allocator = mem.tracking_allocator(&track)

	// Perform operations that serialize wire models using temp_allocator or local scopes
	for _ in 0..<10 {
		b := strings.builder_make(context.temp_allocator)
		task := domain.Task{
			task_id            = domain.Task_ID("task_leak_check"),
			chain_id           = domain.Task_Chain_ID("chain_leak_check"),
			title              = "Leak check task",
			description        = "Verifying zero heap leaks",
			publish_state      = .Published,
			status             = .Assigned,
			priority           = .P0,
			assignee_ref_json  = `{"type":"agent_instance","agent_instance_id":"inst_leak"}`,
			reviewer_refs_json = `[]`,
			updated_at         = "2026-10-03T12:00:00Z",
		}
		write_task_json(&b, task)

		matched := task_matches_query(task, "assignee_agent_instance_id=inst_leak")
		testing.expect(t, matched, "task should match")
	}

	testing.expect_value(t, len(track.allocation_map), 0)
	if len(track.allocation_map) > 0 {
		testing.fail_now(t, "Memory leak detected in taskchain typed wire operations")
	}
}

@(test)
test_task_comment_and_vote_wire_serialization :: proc(t: ^testing.T) {
	vote := domain.Task_Vote{
		task_id                   = domain.Task_ID("task_v1"),
		chain_id                  = domain.Task_Chain_ID("chain_v1"),
		owner_user_id             = domain.User_ID("usr_v1"),
		reviewer_agent_instance_id = "inst_rev_1",
		vote                      = "lgtm",
		comment                   = "Looks great! \"Special quotes\" and \nnewlines.",
		created_at                = "2026-10-03T12:00:00Z",
	}

	b := strings.builder_make(context.temp_allocator)
	write_task_vote_json(&b, vote)
	vote_payload := strings.to_string(b)

	val, err := json.parse_string(vote_payload, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	testing.expect(t, err == .None, "vote json must parse cleanly")
	#partial switch obj in val {
	case json.Object:
		testing.expect_value(t, string(obj["vote"].(json.String)), "lgtm")
		testing.expect_value(t, string(obj["comment"].(json.String)), vote.comment)
		testing.expect_value(t, string(obj["reviewer_agent_instance_id"].(json.String)), "inst_rev_1")
	case:
		testing.fail_now(t, "expected json.Object payload for vote")
	}

	comment := domain.Task_Comment{
		comment_id               = "cmt_1",
		task_id                  = domain.Task_ID("task_c1"),
		chain_id                 = domain.Task_Chain_ID("chain_c1"),
		author_agent_instance_id = "inst_c1",
		owner_user_id            = domain.User_ID("usr_c1"),
		body                     = "Comment body with *markdown* and \\slashes",
		created_at               = "2026-10-03T12:01:00Z",
	}

	b2 := strings.builder_make(context.temp_allocator)
	write_task_comment_json(&b2, comment, "Agent Worker Alpha")
	cmt_payload := strings.to_string(b2)

	val2, err2 := json.parse_string(cmt_payload, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	testing.expect(t, err2 == .None, "comment json must parse cleanly")
	#partial switch obj2 in val2 {
	case json.Object:
		testing.expect_value(t, string(obj2["author_display_name"].(json.String)), "Agent Worker Alpha")
		testing.expect_value(t, string(obj2["body"].(json.String)), comment.body)
		testing.expect_value(t, string(obj2["author_user_id"].(json.String)), "usr_c1")
	case:
		testing.fail_now(t, "expected json.Object payload for comment")
	}
}

// --- Consolidated from task_create_depends_on_test.odin ---

@(test)
test_create_depends_on_absent_is_empty_not_error :: proc(t: ^testing.T) {
	deps := json_array_of_strings(`{"title":"probe"}`, "depends_on")
	testing.expect(t, len(deps) == 0, "absent depends_on must yield no dependencies")
	empty := json_array_of_strings(`{"title":"probe","depends_on":[]}`, "depends_on")
	testing.expect(t, len(empty) == 0, "explicit empty list must yield no dependencies")
}

@(test)
test_create_depends_on_single_round_trips :: proc(t: ^testing.T) {
	deps := json_array_of_strings(`{"title":"probe","depends_on":["task_abc123"]}`, "depends_on")
	testing.expect(t, len(deps) == 1, "one dependency must survive the parse")
	if len(deps) == 1 do testing.expect_value(t, deps[0], domain.Task_ID("task_abc123"))
}

// The CLI turns a comma-separated --depends-on into a JSON array, so multiple
// dependencies must round-trip in order.
@(test)
test_create_depends_on_multiple_round_trip_in_order :: proc(t: ^testing.T) {
	body := `{"title":"probe","depends_on":["task_one","task_two","task_three"]}`
	deps := json_array_of_strings(body, "depends_on")
	testing.expect(t, len(deps) == 3, "all three dependencies must survive the parse")
	if len(deps) != 3 do return
	want := []string{"task_one", "task_two", "task_three"}
	for w, i in want do testing.expect_value(t, deps[i], domain.Task_ID(w))
}

// depends_on must not be confused with a neighbouring field, and an unrelated body
// must not conjure dependencies out of nothing.
@(test)
test_create_depends_on_does_not_bleed_from_other_fields :: proc(t: ^testing.T) {
	body := `{"title":"probe","reviewer_refs":["inst_xyz"],"depends_on":["task_real"]}`
	deps := json_array_of_strings(body, "depends_on")
	testing.expect(t, len(deps) == 1, "depends_on must not pick up reviewer_refs")
	if len(deps) == 1 do testing.expect_value(t, deps[0], domain.Task_ID("task_real"))
	none := json_array_of_strings(`{"title":"probe","reviewer_refs":["inst_xyz"]}`, "depends_on")
	testing.expect(t, len(none) == 0, "a body without depends_on must yield none")
}

// The agent-mode create body is built by the ctl; pin that the shape it actually
// sends is the shape the handler parses.
@(test)
test_create_depends_on_parses_ctl_shaped_body :: proc(t: ^testing.T) {
	body := strings.concatenate({`{"chain_id":"chain_1","title":"t","depends_on":["`, "task_dep1", `","`, "task_dep2", `"]}`})
	defer delete(body)
	deps := json_array_of_strings(body, "depends_on")
	testing.expect(t, len(deps) == 2, "ctl-shaped create body must parse both dependencies")
}

// --- Consolidated from task_create_priority_test.odin ---

@(test)
test_create_priority_absent_leaves_default :: proc(t: ^testing.T) {
	priority, has, ok, _ := create_priority_from_body(`{"title":"probe"}`)
	testing.expect(t, ok, "absent priority must not be an error")
	testing.expect(t, !has, "absent priority must not claim an explicit value")
	testing.expect_value(t, priority, domain.Task_Priority.P2)
}

@(test)
test_create_priority_round_trips_each_level :: proc(t: ^testing.T) {
	cases := [][2]string{{"p0", "P0"}, {"p1", "P1"}, {"p2", "P2"}}
	want := []domain.Task_Priority{.P0, .P1, .P2}
	for c, i in cases {
		for raw in c {
			body := concat_priority_body(raw)
			defer delete(body)
			priority, has, ok, _ := create_priority_from_body(body)
			testing.expect(t, ok, "valid priority must parse")
			testing.expect(t, has, "valid priority must be marked explicit")
			testing.expect_value(t, priority, want[i])
		}
	}
}

@(test)
test_create_priority_invalid_is_rejected_not_coerced :: proc(t: ^testing.T) {
	invalid := []string{"urgent", "P3", "high", ""}
	for raw in invalid {
		body := concat_priority_body(raw)
		defer delete(body)
		_, has, ok, err := create_priority_from_body(body)
		testing.expect(t, !ok, "invalid priority must be rejected")
		testing.expect(t, !has, "rejected priority must not be forwarded as explicit")
		testing.expect_value(t, err.code, domain.Error_Code.Validation_Failed)
	}
}

@(private = "file")
concat_priority_body :: proc(value: string) -> string {
	return strings.concatenate({`{"title":"probe","priority":"`, value, `"}`})
}

// --- Consolidated from taskchain_archive_filter_test.odin ---

@(test)
test_chain_status_http_archived :: proc(t: ^testing.T) {
	testing.expect_value(t, chain_status_http(.Archived), "archived")
	testing.expect_value(t, chain_status_http(.Active), "active")
	testing.expect_value(t, chain_status_http(.Completed), "completed")
	testing.expect_value(t, chain_status_http(.Cancelled), "cancelled")
}

@(test)
test_enrich_chain_list_items_archive_filter :: proc(t: ^testing.T) {
	h: Taskchain_Handlers
	auth: contracts.Auth_Context
	chains := []domain.Task_Chain{
		domain.Task_Chain{chain_id = "chain_1", title = "Active Chain", status = .Active},
		domain.Task_Chain{chain_id = "chain_2", title = "Archived Chain", status = .Archived},
		domain.Task_Chain{chain_id = "chain_3", title = "Completed Chain", status = .Completed},
	}

	// When include_archived is false (default), Archived chains must be excluded
	items_default := enrich_chain_list_items(&h, auth, chains, false, false)
	defer delete(items_default)
	testing.expect_value(t, len(items_default), 2)
	testing.expect_value(t, items_default[0].chain_id, "chain_1")
	testing.expect_value(t, items_default[1].chain_id, "chain_3")

	// When include_archived is true, Archived chains must be included
	items_all := enrich_chain_list_items(&h, auth, chains, false, true)
	defer delete(items_all)
	testing.expect_value(t, len(items_all), 3)
	testing.expect_value(t, items_all[0].chain_id, "chain_1")
	testing.expect_value(t, items_all[1].chain_id, "chain_2")
	testing.expect_value(t, items_all[1].status, "archived")
	testing.expect_value(t, items_all[2].chain_id, "chain_3")
}

// --- Consolidated from taskchain_directories_test.odin ---

@(test)
test_write_directory_json_lean :: proc(t: ^testing.T) {
	dir := domain.Task_Chain_Directory{
		directory_id  = "dir_test123",
		chain_id      = domain.Task_Chain_ID("chain_abc"),
		owner_user_id = domain.User_ID("user_tanmay"),
		path          = "/home/tanmay/repo",
		bridge_id     = "brg_local",
		vcs_kind      = "git",
		vcs_info_json = `{"branch":"main","root":"/home/tanmay/repo"}`,
		created_at    = "2026-09-22T10:00:00Z",
		updated_at    = "2026-09-22T10:05:00Z",
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_directory_json(&b, dir)
	out := strings.to_string(b)

	// Required lean fields must be present
	testing.expect(t, strings.contains(out, `"directory_id":"dir_test123"`), "must contain directory_id")
	testing.expect(t, strings.contains(out, `"path":"/home/tanmay/repo"`), "must contain path")
	testing.expect(t, strings.contains(out, `"bridge_id":"brg_local"`), "must contain bridge_id")
	testing.expect(t, strings.contains(out, `"vcs_kind":"git"`), "must contain vcs_kind")
	testing.expect(t, strings.contains(out, `"vcs":{"branch":"main","root":"/home/tanmay/repo"}`), "must contain vcs object")

	// Lean payload: created_at, updated_at, owner_user_id must NOT be leaked
	testing.expect(t, !strings.contains(out, `"created_at"`), "lean payload must not contain created_at")
	testing.expect(t, !strings.contains(out, `"updated_at"`), "lean payload must not contain updated_at")
	testing.expect(t, !strings.contains(out, `"owner_user_id"`), "lean payload must not contain owner_user_id")
	testing.expect(t, !strings.contains(out, `"chain_id"`), "lean payload must not contain redundant chain_id")
}

@(test)
test_write_directory_json_empty_vcs :: proc(t: ^testing.T) {
	dir := domain.Task_Chain_Directory{
		directory_id  = "dir_empty_vcs",
		chain_id      = domain.Task_Chain_ID("chain_xyz"),
		owner_user_id = domain.User_ID("user_tanmay"),
		path          = "/home/tanmay/docs",
		bridge_id     = "",
		vcs_kind      = "",
		vcs_info_json = "",
		created_at    = "2026-09-22T10:00:00Z",
		updated_at    = "2026-09-22T10:00:00Z",
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_directory_json(&b, dir)
	out := strings.to_string(b)

	testing.expect(t, strings.contains(out, `"directory_id":"dir_empty_vcs"`), "must contain directory_id")
	testing.expect(t, strings.contains(out, `"path":"/home/tanmay/docs"`), "must contain path")
	testing.expect(t, strings.contains(out, `"bridge_id":""`), "must contain empty bridge_id")
	testing.expect(t, strings.contains(out, `"vcs_kind":""`), "must contain empty vcs_kind")
	testing.expect(t, strings.contains(out, `"vcs":{}`), "empty vcs_info_json must serialize as empty object")
}

// --- Consolidated from taskchain_pinned_serialization_test.odin ---

@(test)
test_write_chain_list_item_json_pinned :: proc(t: ^testing.T) {
	item := Chain_List_Item{
		chain_id                      = "chain_123",
		title                         = "Test Chain",
		status                        = "active",
		created_at                    = "2026-09-21T10:00:00Z",
		updated_at                    = "2026-09-21T10:05:00Z",
		coordinator_agent_instance_id = "inst_abc",
		project_id                    = "proj_xyz",
		project_name                  = "Heimdall",
		task_count                    = 5,
		is_pinned                     = true,
		pinned_at                     = "2026-09-21T10:05:00Z",
		completed_task_count          = 3,
		user_validation_count         = 1,
	}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_chain_list_item_json(&b, item)
	out := strings.to_string(b)
	testing.expect(t, strings.contains(out, `"is_pinned":true`), "must serialize is_pinned true")
	testing.expect(t, strings.contains(out, `"pinned_at":"2026-09-21T10:05:00Z"`), "must serialize pinned_at")
	testing.expect(t, strings.contains(out, `"completed_task_count":3`), "must serialize completed_task_count")
	testing.expect(t, strings.contains(out, `"user_validation_count":1`), "must serialize user_validation_count")
}

@(test)
test_write_chain_list_item_json_unpinned :: proc(t: ^testing.T) {
	item := Chain_List_Item{
		chain_id                      = "chain_456",
		title                         = "Unpinned Chain",
		status                        = "active",
		created_at                    = "2026-09-21T10:00:00Z",
		updated_at                    = "2026-09-21T10:05:00Z",
		coordinator_agent_instance_id = "",
		project_id                    = "",
		project_name                  = "",
		task_count                    = 0,
		is_pinned                     = false,
		pinned_at                     = "",
	}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_chain_list_item_json(&b, item)
	out := strings.to_string(b)
	testing.expect(t, strings.contains(out, `"is_pinned":false`), "must serialize is_pinned false")
	testing.expect(t, strings.contains(out, `"pinned_at":""`), "must serialize empty pinned_at")
}

@(test)
test_write_chain_json_pinned :: proc(t: ^testing.T) {
	c := domain.Task_Chain{
		chain_id                      = domain.Task_Chain_ID("chain_pinned_1"),
		owner_user_id                 = domain.User_ID("user_1"),
		title                         = "Pinned Chain Detail",
		description                   = "Description",
		publish_state                 = .Published,
		status                        = .Active,
		kind                          = "team_work",
		coordinator_agent_instance_id = "inst_coord",
		default_reviewer_refs_json    = "[]",
		created_at                    = "2026-09-21T09:00:00Z",
		updated_at                    = "2026-09-21T09:10:00Z",
		is_pinned                     = true,
		pinned_at                     = "2026-09-21T09:10:00Z",
	}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_chain_json(&b, c)
	out := strings.to_string(b)
	testing.expect(t, strings.contains(out, `"is_pinned":true`), "must serialize is_pinned true")
	testing.expect(t, strings.contains(out, `"pinned_at":"2026-09-21T09:10:00Z"`), "must serialize pinned_at")
}
