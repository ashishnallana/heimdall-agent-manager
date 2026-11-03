package http

import "core:encoding/json"
import "core:fmt"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import taskv2 "odin_test:hub/service/taskv2"
import card_service "odin_test:hub/service/card"

@(test)
test_placement_recovery_http_authority_guards_and_scope :: proc(t: ^testing.T) {
	f := wire_setup(t, "placement_recovery_http")
	defer wire_teardown(f)
	engine := taskv2.new_service(&f.tc_repo, &f.ag_repo, &f.br_repo, &f.clock, &f.ids)
	repos := iface.Repositories{taskchains = f.tc_repo, agents = f.ag_repo, bridges = f.br_repo}
	uow_impl: sqlite.SQLite_Unit_Of_Work_Factory
	uow := sqlite.new_unit_of_work_factory(&uow_impl, &f.conn, &repos)
	engine.uow_factory = &uow
	f.tc_svc.engine, f.th.task_engine = &engine, &engine
	chain, _, _ := iface.taskchain_get_chain(&f.tc_repo, f.chain_id)
	chain.publish_state = .Published
	_, _, _ = iface.taskchain_save_chain(&f.tc_repo, chain)
	_, saved_agent, _ := iface.agent_save(&f.ag_repo, domain.Agent{agent_id = "agt_repair", owner_user_id = f.owner, name = "Repair", slug = "repair", template_id = domain.TEMPLATE_EMPTY_ID})
	testing.expect(t, saved_agent, "owned durable identity")
	bridge, _, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_pin)
	bridge.status = .Offline
	_, _, _ = iface.bridge_save_bridge(&f.br_repo, bridge)
	alt, _, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_alt)
	alt.status = .Online
	_, _, _ = iface.bridge_save_bridge(&f.br_repo, alt)
	_, _ = iface.taskchain_upsert_fleet(&f.tc_repo, domain.Task_Chain_Fleet{task_chain_id = f.chain_id, agent_id = "agt_repair", bridge_id = f.bridge_pin, roles_json = `["worker"]`, capacity = 1})
	task := domain.Task{task_id = "task_http_repair", chain_id = f.chain_id, owner_user_id = f.owner, title = "Repair placement", state = .Backlog, publish_state = .Published, kind = .Task, brief_json = `{"goal":"g","assignee":"agt_repair","review_roles":[]}`}
	_, _, _ = iface.taskchain_save_task(&f.tc_repo, task)
	testing.expect_value(t, taskv2.task_created(&engine, task, taskv2.hub_actor()).code, domain.Error_Code.None)
	task, _, _ = iface.taskchain_get_task(&f.tc_repo, task.task_id)
	failures, ferr := taskv2.placement_failures(&engine, task)
	if !testing.expect(t, ferr.code == .None && len(failures) == 1, "current failed target") do return
	failure := failures[0]
	input := taskv2.Placement_Recovery_Input{expected_attempt = 0, phase = failure.phase, agent_id = failure.agent_id, role = failure.role, fingerprint = failure.fingerprint, configuration = failure.configuration, expected_assignment = "agt_repair", action = "change_bridge", bridge_id = f.bridge_alt, scope = "ticket"}
	body, _ := json.marshal(input, allocator = context.temp_allocator)
	path := fmt.tprintf("/api/v1/tasks/%s/placement-recovery", task.task_id)
	malformed := recover_task_placement_handler(&f.th, wire_cookie_request(f, "POST", path, `{}`))
	testing.expect_value(t, malformed.status, 400)
	req := wire_cookie_request(f, "POST", path, string(body))
	req.headers = f.agent_headers[:]
	denied := recover_task_placement_handler(&f.th, req)
	testing.expect_value(t, denied.status, 403)
	wrong_path := fmt.tprintf("/api/v1/task-chains/chain_other/tasks/%s/placement-recovery", task.task_id)
	wrong := recover_task_placement_handler(&f.th, wire_cookie_request(f, "POST", wrong_path, string(body)))
	testing.expect_value(t, wrong.status, 404)
	input.bridge_id = f.bridge_foreign
	foreign_body, _ := json.marshal(input, allocator = context.temp_allocator)
	foreign_response := recover_task_placement_handler(&f.th, wire_cookie_request(f, "POST", path, string(foreign_body)))
	testing.expect_value(t, foreign_response.status, 400)
	input.bridge_id = f.bridge_alt
	input.fingerprint = "forged"
	forged_body, _ := json.marshal(input, allocator = context.temp_allocator)
	forged := recover_task_placement_handler(&f.th, wire_cookie_request(f, "POST", path, string(forged_body)))
	testing.expect_value(t, forged.status, 409)
	// The card endpoint delegates to exactly the same native guards.
	card_impl: sqlite.Card_Repo_SQLite
	card_repo := sqlite.new_card_repository(&card_impl, &f.conn)
	attention_impl: sqlite.Attention_Repo_SQLite
	attention_repo := sqlite.new_attention_repository(&attention_impl, &f.conn)
	cards := card_service.new_card_service(cards = &card_repo, projects = nil, taskchains = &f.tc_svc, clock = &f.clock, ids = &f.ids)
	card_service.init_attention(&cards, &attention_repo)
	_, _ = card_service.project_task_card(&cards, f.owner, task.task_id)
	ch := Card_Handlers{auth = &f.auth_svc, cards = &cards, clock = &f.clock}
	card_path := fmt.tprintf("/api/v1/cards/crd_placement_%s_0/placement-recovery", task.task_id)
	card_forged := recover_card_placement_handler(&ch, wire_cookie_request(f, "POST", card_path, string(forged_body)))
	testing.expect_value(t, card_forged.status, 409)
	response := recover_card_placement_handler(&ch, wire_cookie_request(f, "POST", card_path, string(body)))
	testing.expectf(t, response.status == 200, "%s", response.body)
	duplicate := recover_task_placement_handler(&f.th, wire_cookie_request(f, "POST", path, string(body)))
	testing.expect_value(t, duplicate.status, 409)
}
