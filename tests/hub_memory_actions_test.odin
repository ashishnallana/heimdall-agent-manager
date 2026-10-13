package hub_memory_actions_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import bridge "odin_test:bridge"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import content_service "odin_test:hub/service/content"
import api_http "odin_test:hub/transport/http"
import bridge_service "odin_test:hub/service/bridge"

PORT :: 49679

check :: proc(ok: bool, message: string) {
	if ok do return
	fmt.eprintln("FAIL:", message)
	os.exit(1)
}

extract_json_string :: proc(body, key: string) -> string {
	needle := strings.concatenate({"\"", key, "\":\""})
	defer delete(needle)
	idx := strings.index(body, needle)
	if idx < 0 do return ""
	rest := body[idx + len(needle):]
	end := strings.index_byte(rest, '"')
	if end < 0 do return ""
	return rest[:end]
}

request :: proc(graph: ^app.App_Graph, method, path, body: string, headers: []contracts.HTTP_Header) -> api_http.Response {
	bare := path
	query := ""
	if q := strings.index_byte(path, '?'); q >= 0 {
		bare = path[:q]
		query = path[q + 1:]
	}
	return api_http.router_dispatch(&graph.router, api_http.Request{
		method = method,
		path = bare,
		query = query,
		body = body,
		headers = headers,
		remote_addr = "127.0.0.1",
		request_id = "req_test",
	})
}

enroll_bridge :: proc(graph: ^app.App_Graph, headers: []contracts.HTTP_Header) -> (string, string) {
	// ===== PROVISIONED THROUGH THE REAL DEVICE FLOW (REQ-ENROLL-9) =====
	//
	// This used to POST /api/v1/bridge-enrollments for a one-time token and then
	// exchange it at POST /api/v1/bridges/enroll. Both are deleted. These tests are
	// not about enrollment — they need a bridge and a credential — so the helper was
	// migrated rather than the tests dropped.
	//
	// It drives the PRODUCTION endpoints rather than calling the service directly,
	// which keeps this helper HTTP-only and means every suite below now covers the
	// real enrollment path as a side effect.
	//
	// PKCE is MANDATORY for a bridge grant and S256-only — `plain` and a missing
	// method are both refused, so the pair below is a precomputed
	// BASE64URL(SHA256(verifier)). Hardcoded rather than derived so this helper
	// needs no crypto; the verifier is replayed at the token call.
	//
	// No bridge_key_fingerprint is sent: the Hub DERIVES it from the key, and a
	// body-supplied one that disagrees is rejected (bridge_grant.odin) — a
	// requester-chosen fingerprint would defeat the point of the human comparing it.
	//
	// `device_label` is what becomes the bridge's hostname and therefore its label
	// (wiring.odin maps device_label -> machine_hostname), so label assertions in
	// these suites keep working unchanged.
	authorized := request(graph, "POST", "/api/v1/device/authorize", strings.concatenate({"{\"client\":\"ham-bridge\",\"device_label\":\"", "Test Bridge", "\",\"os\":\"linux\",\"bridge_public_key\":\"040102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40\",\"os_user\":\"tester\",\"code_challenge\":\"J6jJRRlTiLmCVJAjMgzOjMLRQ-xSS_tovxAjutN8JWI\",\"code_challenge_method\":\"S256\"}"}), nil)
	check(authorized.status == 200, authorized.body)
	device_code := extract_json_string(authorized.body, "device_code")
	user_code := extract_json_string(authorized.body, "user_code")

	// The human approves, authenticated by the same trusted-proxy headers the
	// caller passed. Ownership comes from that Auth_Context, never from the body.
	approved := request(graph, "POST", "/api/v1/device/approve", strings.concatenate({"{\"user_code\":\"", user_code, "\",\"approve\":true}"}), headers)
	check(approved.status == 200, approved.body)

	// The bridge collects its credential. Single-use: the grant is spent here.
	issued := request(graph, "POST", "/api/v1/device/token", strings.concatenate({"{\"device_code\":\"", device_code, "\",\"code_verifier\":\"heimdall-req-impl-6-test-code-verifier-aaaa\"}"}), nil)
	check(issued.status == 200, issued.body)

	// ===== CAPABILITIES ARE REPORTED, NOT ENROLLED =====
	//
	// The deleted enroll endpoint took a `capabilities` array in its body, so the
	// old helper declared the bridge's providers AT ENROLLMENT. The device flow has
	// no such field by design: what the Hub records at enrollment is only what the
	// approving human confirmed (the key, its fingerprint, the OS user). A real
	// bridge reports its providers when it CONNECTS, over the runtime WS, which the
	// Hub handles with update_runtime_capabilities.
	//
	// No bridge connects in these tests, so this calls the same service proc the WS
	// handler does. Without it the bridge has no declared providers and anything
	// that matches an agent to a provider/model fails — which is a real difference
	// between the two flows, not a test artifact.
	//
	// NOTE it also marks the bridge Online (as a connect would), where the deleted
	// enroll path left it Offline.
	_, _, _ = bridge_service.update_runtime_capabilities(&graph.bridges, extract_json_string(issued.body, "bridge_id"), "{\"capabilities\":[{\"provider\":\"claude\",\"models\":[\"normal\",\"smart\"],\"default_model\":\"normal\"}]}")

	return extract_json_string(issued.body, "bridge_id"), extract_json_string(issued.body, "access_token")
}

@(test)
test_hub_memory_actions :: proc(t: ^testing.T) {
	_ = t
	main()
}

main :: proc() {
	db_path := "/tmp/heimdall-hub-memory-actions-test.db"
	_ = os.remove(db_path)
	cidrs := [?]string{"127.0.0.1/32"}
	graph: app.App_Graph
	ok, message := app.build_graph(&graph, app.Hub_Config{
		database_path = db_path,
		migrations_dir = "src/hub/repository/sqlite/migrations",
		bind_host = "127.0.0.1",
		port = PORT,
		username_header = "X-authentik-username",
		display_name_header = "X-authentik-name",
		email_header = "X-authentik-email",
		trusted_proxy_cidrs = cidrs[:],
		auto_provision_users = true,
		logout_url = "/_dev/logout",
		paddle_environment = "sandbox",
	})
	check(ok, message)

	user_headers := [?]contracts.HTTP_Header{
		{name = "X-authentik-username", value = "alice"},
		{name = "X-authentik-name", value = "Alice User"},
		{name = "X-authentik-email", value = "alice@example.com"},
	}
	bridge_id, bridge_token := enroll_bridge(&graph, user_headers[:])

	owner := domain.User_ID("alice")
	now := "2026-07-23T00:00:00Z"
	agent_id := "agent_memory_test"
	instance_id := "inst_memory_test"

	_, agent_saved, agent_err := iface.agent_save(&graph.repos.agents, domain.Agent{
		agent_id = agent_id,
		owner_user_id = owner,
		name = "Memory Test Agent",
		slug = "mem-agent",
		state = .Active,
		created_at = now,
		updated_at = now,
	})
	check(agent_saved, agent_err.message)

	_, inst_saved, inst_err := iface.agent_save_instance(&graph.repos.agents, domain.Agent_Instance{
		agent_instance_id = instance_id,
		owner_user_id = owner,
		agent_id = agent_id,
		bridge_id = bridge_id,
		provider = "claude",
		model = "normal",
		chain_id = "chain_test",
		runtime_status = "live",
		startup_status = "ready",
		activity_status = "idle",
		created_at = now,
		updated_at = now,
		started_at = now,
		last_seen_at = now,
	})
	check(inst_saved, inst_err.message)

	auth := contracts.Auth_Context{kind = .Trusted_Proxy, user_id = string(owner), name = string(owner)}

	// Create two test memories
	// Memory 1: Fact, scoped to agent_id
	mem1, saved1, err1 := content_service.create_memory(&graph.content, auth, content_service.Memory_Input{
		agent_ids = []string{agent_id},
		type = .Fact,
		status = "active",
		title = "Build Command",
		description = "How to build Heimdall",
		body = "odin check src/hub",
		evidence = "verified in nix develop shell",
	})
	check(saved1, err1.message)

	// Memory 2: Habit, global
	mem2, saved2, err2 := content_service.create_memory(&graph.content, auth, content_service.Memory_Input{
		type = .Habit,
		status = "active",
		title = "Review Checklist",
		description = "Run tests before voting LGTM",
		body = "Always verify tests pass before approving",
		evidence = "reviewed by team",
	})
	check(saved2, err2.message)

	thread.run_with_poly_data(&graph.router, serve_hub)
	bridge.bridge_agent_token_store_init()
	bridge.bridge_config.daemon_url = fmt.tprintf("http://127.0.0.1:%d", PORT)
	bridge.bridge_config.bridge_token = bridge_token
	issued := bridge.bridge_agent_token_issue(instance_id, strings.concatenate({"hit_", instance_id}), .Agent)

	// Test 1: agent.memory.list returns metadata-only
	list_line := strings.concatenate({
		"{\"v\":1,\"id\":\"list_all\",\"token\":\"", issued.plaintext_token,
		"\",\"method\":\"agent.memory.list\",\"params\":{}}"
	})
	list_resp := ""
	for attempt in 0..<25 {
		_ = attempt
		list_resp = bridge.bridge_local_endpoint_handle_jsonl_line(list_line)
		if strings.contains(list_resp, "\"ok\":true") do break
	}
	check(strings.contains(list_resp, "\"ok\":true"), fmt.tprintf("memory.list failed: %s", list_resp))
	check(strings.contains(list_resp, mem1.memory_id), "memory 1 id present")
	check(strings.contains(list_resp, mem2.memory_id), "memory 2 id present")
	check(strings.contains(list_resp, "Build Command"), "memory 1 title present")
	check(strings.contains(list_resp, "How to build Heimdall"), "memory 1 description present")
	check(strings.contains(list_resp, "Review Checklist"), "memory 2 title present")
	// Metadata only: must NOT contain body or evidence!
	check(!strings.contains(list_resp, "odin check src/hub"), "memory body must be omitted from memory.list")
	check(!strings.contains(list_resp, "verified in nix develop shell"), "evidence must be omitted from memory.list")
	check(!strings.contains(list_resp, "\"body\":"), "no body key in list response")
	check(!strings.contains(list_resp, "\"evidence\":"), "no evidence key in list response")

	// Test 2: agent.memory.list with filter type=habit
	list_habit_line := strings.concatenate({
		"{\"v\":1,\"id\":\"list_habit\",\"token\":\"", issued.plaintext_token,
		"\",\"method\":\"agent.memory.list\",\"params\":{\"type\":\"habit\"}}"
	})
	list_habit_resp := bridge.bridge_local_endpoint_handle_jsonl_line(list_habit_line)
	check(strings.contains(list_habit_resp, "\"ok\":true"), list_habit_resp)
	check(strings.contains(list_habit_resp, mem2.memory_id), "habit memory present")
	check(!strings.contains(list_habit_resp, mem1.memory_id), "fact memory filtered out")

	// Test 3: agent.memory.show returns full memory JSON including body and evidence
	show_line := strings.concatenate({
		"{\"v\":1,\"id\":\"show_mem\",\"token\":\"", issued.plaintext_token,
		"\",\"method\":\"agent.memory.show\",\"params\":{\"memory_id\":\"", mem1.memory_id, "\"}}"
	})
	show_resp := bridge.bridge_local_endpoint_handle_jsonl_line(show_line)
	check(strings.contains(show_resp, "\"ok\":true"), show_resp)
	check(strings.contains(show_resp, mem1.memory_id), "show has memory_id")
	check(strings.contains(show_resp, "Build Command"), "show has title")
	check(strings.contains(show_resp, "odin check src/hub"), "show has body")
	check(strings.contains(show_resp, "verified in nix develop shell"), "show has evidence")

	// Test 4: agent.memory.content returns content payload {"content": m.body}
	content_line := strings.concatenate({
		"{\"v\":1,\"id\":\"content_mem\",\"token\":\"", issued.plaintext_token,
		"\",\"method\":\"agent.memory.content\",\"params\":{\"memory_id\":\"", mem1.memory_id, "\"}}"
	})
	content_resp := bridge.bridge_local_endpoint_handle_jsonl_line(content_line)
	check(strings.contains(content_resp, "\"ok\":true"), content_resp)
	check(strings.contains(content_resp, "\"content\":\"odin check src/hub\""), "content response has raw body as content")

	// Test 5: User-mode GET /api/v1/memories?type=habit
	user_list := request(&graph, "GET", "/api/v1/memories?type=habit", "", user_headers[:])
	check(user_list.status == 200, "user list memories status 200")
	check(strings.contains(user_list.body, mem2.memory_id), "user list has mem2")
	check(!strings.contains(user_list.body, mem1.memory_id), "user list filtered out mem1")

	// Test 6: User-mode GET /api/v1/memories/:id (as used by ctl_hub_memories show and content)
	user_show := request(&graph, "GET", fmt.tprintf("/api/v1/memories/%s", mem1.memory_id), "", user_headers[:])
	check(user_show.status == 200, "user show memory status 200")
	check(strings.contains(user_show.body, "odin check src/hub"), "user show has body")

	// --- MEM-PATCH-1: PATCH /api/v1/memories/{id} (memory scope edits) ---
	// Regression guard: before the PATCH route was registered in wiring.odin this
	// 404'd with "route not found". These assert the route is wired to
	// patch_memory_handler AND the update semantics/guards behave: owner-only;
	// key-present = replace that dimension, empty array = applies to all; an
	// omitted dimension is left unchanged.

	// A second owner-owned agent to use as a replacement scope target.
	agent_id2 := "agent_memory_test_2"
	_, agent2_saved, agent2_err := iface.agent_save(&graph.repos.agents, domain.Agent{
		agent_id = agent_id2,
		owner_user_id = owner,
		name = "Memory Test Agent 2",
		slug = "mem-agent-2",
		state = .Active,
		created_at = now,
		updated_at = now,
	})
	check(agent2_saved, agent2_err.message)

	// Test 7: route is registered (NOT 404) + an omitted dimension is unchanged.
	patch_title := request(&graph, "PATCH", fmt.tprintf("/api/v1/memories/%s", mem1.memory_id), "{\"title\":\"Build Command v2\"}", user_headers[:])
	check(patch_title.status == 200, fmt.tprintf("PATCH memory (route registered?) expected 200, got %d: %s", patch_title.status, patch_title.body))
	check(strings.contains(patch_title.body, "\"title\":\"Build Command v2\""), "PATCH updated the title")
	check(strings.contains(patch_title.body, "\"agent_ids\":[\"agent_memory_test\"]"), "omitted agent_ids dimension left unchanged")

	// Test 8: scope replace — agent_ids set to exactly the new agent.
	patch_replace := request(&graph, "PATCH", fmt.tprintf("/api/v1/memories/%s", mem1.memory_id), strings.concatenate({"{\"agent_ids\":[\"", agent_id2, "\"]}"}), user_headers[:])
	check(patch_replace.status == 200, patch_replace.body)
	check(strings.contains(patch_replace.body, strings.concatenate({"\"agent_ids\":[\"", agent_id2, "\"]"})), "agent scope replaced with the new agent")

	// Test 9: empty array clears the dimension (applies to all).
	patch_clear := request(&graph, "PATCH", fmt.tprintf("/api/v1/memories/%s", mem1.memory_id), "{\"agent_ids\":[]}", user_headers[:])
	check(patch_clear.status == 200, patch_clear.body)
	check(strings.contains(patch_clear.body, "\"agent_ids\":[]"), "empty agent_ids array clears the agent scope")

	// Test 10: a foreign/unknown referenced agent id is rejected (not saved).
	patch_foreign := request(&graph, "PATCH", fmt.tprintf("/api/v1/memories/%s", mem1.memory_id), "{\"agent_ids\":[\"nonexistent_agent_zzz\"]}", user_headers[:])
	check(patch_foreign.status != 200, fmt.tprintf("PATCH with unknown agent id must be rejected, got %d", patch_foreign.status))
	check(strings.contains(patch_foreign.body, "agent not found"), "unknown agent id rejected with a clear error")

	// Test 11: a non-owner cannot patch someone else's memory. Ownership guards
	// return Not_Found (404, anti-enumeration — see ownership.require_owner), the
	// same treatment approve/archive/detail use, not 403.
	bob_headers := [?]contracts.HTTP_Header{
		{name = "X-authentik-username", value = "bob"},
		{name = "X-authentik-name", value = "Bob User"},
		{name = "X-authentik-email", value = "bob@example.com"},
	}
	patch_bob := request(&graph, "PATCH", fmt.tprintf("/api/v1/memories/%s", mem1.memory_id), "{\"title\":\"hijacked\"}", bob_headers[:])
	check(patch_bob.status == 404, fmt.tprintf("non-owner PATCH must be rejected as Not_Found (404), got %d: %s", patch_bob.status, patch_bob.body))
	// And the owner's memory is untouched by the rejected non-owner PATCH.
	owner_recheck := request(&graph, "GET", fmt.tprintf("/api/v1/memories/%s", mem1.memory_id), "", user_headers[:])
	check(owner_recheck.status == 200 && !strings.contains(owner_recheck.body, "hijacked"), "non-owner PATCH did not mutate the memory")

	// Test 12: only pending|active memories can be patched — an archived one is rejected.
	mem3, saved3, err3 := content_service.create_memory(&graph.content, auth, content_service.Memory_Input{
		type = .Fact,
		status = "active",
		title = "Archived Fact",
		description = "to be archived",
		body = "archive me",
		evidence = "e",
	})
	check(saved3, err3.message)
	archived := request(&graph, "POST", fmt.tprintf("/api/v1/memories/%s/archive", mem3.memory_id), "", user_headers[:])
	check(archived.status == 200, fmt.tprintf("archive memory expected 200, got %d: %s", archived.status, archived.body))
	patch_archived := request(&graph, "PATCH", fmt.tprintf("/api/v1/memories/%s", mem3.memory_id), "{\"title\":\"nope\"}", user_headers[:])
	check(patch_archived.status != 200, fmt.tprintf("PATCH on archived memory must be rejected, got %d", patch_archived.status))
	check(strings.contains(patch_archived.body, "only pending or active"), "archived memory patch rejected with the status-guard message")

	fmt.println("PASS: hub memory actions (list metadata-only, show, content, PATCH scope edits)")
	app.shutdown_graph(&graph)
	_ = os.remove(db_path)
	os.exit(0)
}

serve_hub :: proc(router: ^api_http.Router) {
	_ = api_http.serve(router, api_http.Server_Config{bind_host = "127.0.0.1", port = PORT})
}
