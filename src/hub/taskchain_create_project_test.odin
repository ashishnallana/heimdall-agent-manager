package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import project_service "odin_test:hub/service/project"
import api_http "odin_test:hub/transport/http"

// POST /api/v1/task-chains (ham-ctl task-chain create --project): a bad,
// foreign or archived project_id, or a project_id with no launched coordinator,
// is rejected before any chain row exists; an owned project lands the chain in
// that project's list bucket; omitting project_id keeps the Unassigned bucket.
@(test)
test_task_chain_create_project_selection :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/heimdall-hub-test-chain-project-%d.db", os.get_pid())
	_ = os.remove(db_path)
	defer _ = os.remove(db_path)
	graph: app.App_Graph
	ok, msg := app.build_graph(&graph, app.Hub_Config{database_path = db_path, migrations_dir = "src/hub/repository/sqlite/migrations", auto_provision_users = true, paddle_environment = "sandbox"})
	if !testing.expect(t, ok, msg) do return
	defer app.shutdown_graph(&graph)
	alice := hub_test_user_headers(&graph, "alice")
	_ = hub_test_user_headers(&graph, "bob")

	bridge_id, _, enroll_ok := device_enroll_test_bridge(&graph, alice[:], "Alice Bridge")
	if !testing.expect(t, enroll_ok, "device-flow bridge provisioning failed") do return
	if b, b_ok, _ := iface.bridge_get_bridge(graph.bridges.repo, bridge_id); b_ok {
		b.status = .Online
		_, _, _ = iface.bridge_save_bridge(graph.bridges.repo, b)
	}
	project_service.bridge_runtime_registry_mark_live(graph.agents.bridge_runtime_registry, bridge_id, false, "")
	_, _ = iface.bridge_provider_status_upsert(graph.agents.providers, domain.Bridge_Provider_Status{bridge_id = bridge_id, provider = "claude", state = "present", checked_at = "2026-10-01T00:00:00Z"})
	_, _ = iface.bridge_provider_setting_upsert(graph.agents.providers, domain.Bridge_Provider_Setting{bridge_id = bridge_id, provider = "claude", enabled = true, updated_at = "2026-10-01T00:00:00Z"})
	graph.agents.bridge_command_sink = project_service.Bridge_Command_Sink{send_runtime_command = proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {return true, domain.Domain_Error{}}}

	call :: proc(graph: ^app.App_Graph, headers: []contracts.HTTP_Header, method, path, query, body: string) -> api_http.Response {
		return api_http.router_dispatch(&graph.router, api_http.Request{method = method, path = path, query = query, body = body, request_id = "req_chain_project", remote_addr = "127.0.0.1", headers = headers})
	}
	agent_res := call(&graph, alice[:], "POST", "/api/v1/agents", "", `{"name":"Coder","slug":"project-coder","default_provider":"claude","default_model":"claude-sonnet-5-5"}`)
	if !testing.expect_value(t, agent_res.status, 201) do return
	agent_id := json_field(agent_res.body, "agent_id")
	call(&graph, alice[:], "PATCH", fmt.tprintf("/api/v1/agents/%s/bridge-support/%s", agent_id, bridge_id), "", `{"enabled":true,"provider":"claude","model":"claude-sonnet-5-5"}`)

	_, s1, _ := iface.project_save(&graph.repos.projects, {project_id = "proj_alice_owned", owner_user_id = "alice", name = "Owned", slug = "owned", default_path = "/srv/owned", state = .Active})
	_, s2, _ := iface.project_save(&graph.repos.projects, {project_id = "proj_bob_foreign", owner_user_id = "bob", name = "Foreign", slug = "foreign", default_path = "/srv/foreign", state = .Active})
	_, s3, _ := iface.project_save(&graph.repos.projects, {project_id = "proj_alice_archived", owner_user_id = "alice", name = "Archived", slug = "archived", default_path = "/srv/archived", state = .Archived})
	if !testing.expect(t, s1 && s2 && s3) do return

	before, _ := iface.taskchain_list_chains_by_owner(&graph.repos.taskchains, "alice")
	rejected := []struct {project, coordinator: string, status: int}{
		{"proj_missing", agent_id, 404},
		{"proj_bob_foreign", agent_id, 404},
		{"proj_alice_archived", agent_id, 409},
		{"proj_alice_owned", "", 400},
	}
	for r in rejected {
		body := fmt.tprintf(`{{"title":"Rejected","coordinator_agent_id":"%s","bridge_id":"%s","provider":"claude","model":"claude-sonnet-5-5","project_id":"%s"}}`, r.coordinator, bridge_id, r.project)
		if r.coordinator == "" do body = fmt.tprintf(`{{"title":"Rejected","project_id":"%s"}}`, r.project)
		res := call(&graph, alice[:], "POST", "/api/v1/task-chains", "", body)
		testing.expectf(t, res.status == r.status, "%s/%q: status %d body %s", r.project, r.coordinator, res.status, res.body)
	}
	after, _ := iface.taskchain_list_chains_by_owner(&graph.repos.taskchains, "alice")
	testing.expectf(t, len(after) == len(before), "rejected creates must leave no chain: %d -> %d", len(before), len(after))
	instances, _ := iface.agent_list_instances_by_owner(&graph.repos.agents, "alice", 100)
	testing.expect_value(t, len(instances), 0)

	created := call(&graph, alice[:], "POST", "/api/v1/task-chains", "", fmt.tprintf(`{{"title":"In project","coordinator_agent_id":"%s","bridge_id":"%s","provider":"claude","model":"claude-sonnet-5-5","project_id":"proj_alice_owned"}}`, agent_id, bridge_id))
	if !testing.expectf(t, created.status == 201, "create in project: %d %s", created.status, created.body) do return
	chain_id := json_field(created.body, "chain_id")
	plain := call(&graph, alice[:], "POST", "/api/v1/task-chains", "", fmt.tprintf(`{{"title":"No project","coordinator_agent_id":"%s","bridge_id":"%s","provider":"claude","model":"claude-sonnet-5-5"}}`, agent_id, bridge_id))
	if !testing.expectf(t, plain.status == 201, "create without project: %d %s", plain.status, plain.body) do return
	plain_id := json_field(plain.body, "chain_id")

	chain, found, _ := iface.taskchain_get_chain(&graph.repos.taskchains, domain.Task_Chain_ID(chain_id))
	inst, inst_found, _ := iface.agent_get_instance(&graph.repos.agents, chain.coordinator_agent_instance_id)
	testing.expect(t, found && inst_found && inst.project_id == "proj_alice_owned" && inst.project_path == "/srv/owned")
	// Project grouping (the UI sidebar bucket query) shows each chain in its bucket.
	in_project := call(&graph, alice[:], "GET", "/api/v1/task-chains", "project_id=proj_alice_owned", "")
	testing.expectf(t, in_project.status == 200 && strings.contains(in_project.body, chain_id) && !strings.contains(in_project.body, plain_id), "project bucket: %s", in_project.body)
	unassigned := call(&graph, alice[:], "GET", "/api/v1/task-chains", "project_id=", "")
	testing.expectf(t, unassigned.status == 200 && strings.contains(unassigned.body, plain_id) && !strings.contains(unassigned.body, chain_id), "unassigned bucket: %s", unassigned.body)
	flat := call(&graph, alice[:], "GET", "/api/v1/task-chains", "flat=1", "")
	testing.expectf(t, strings.contains(flat.body, `"project_id":"proj_alice_owned"`), "flat list carries project_id: %s", flat.body)
}

@(private = "file")
json_field :: proc(body, key: string) -> string {
	marker := fmt.tprintf(`"%s":"`, key)
	idx := strings.index(body, marker)
	if idx < 0 do return ""
	rest := body[idx + len(marker):]
	end := strings.index_byte(rest, '"')
	if end < 0 do return ""
	return rest[:end]
}
