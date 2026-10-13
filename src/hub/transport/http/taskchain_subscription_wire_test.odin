package http

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import agent_service "odin_test:hub/service/agent"
import auth_service "odin_test:hub/service/auth"
import bridge_service "odin_test:hub/service/bridge"
import taskchain_service "odin_test:hub/service/taskchain"
import user_service "odin_test:hub/service/user"

@test
test_write_subscription_json :: proc(t: ^testing.T) {
	sub := domain.Task_Subscription{
		subscription_id              = "sub_12345",
		owner_user_id                = domain.User_ID("user_tanmay"),
		subscriber_agent_instance_id = "inst_agent_1",
		chain_id                     = domain.Task_Chain_ID("chain_abc"),
		task_id                      = domain.Task_ID("task_xyz"),
		event_type                   = "all",
		created_at                   = "2026-09-28T10:00:00Z",
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_subscription_json(&b, sub)
	out := strings.to_string(b)

	testing.expect(t, strings.contains(out, `"subscription_id":"sub_12345"`), "must contain subscription_id")
	testing.expect(t, strings.contains(out, `"owner_user_id":"user_tanmay"`), "must contain owner_user_id")
	testing.expect(t, strings.contains(out, `"subscriber_agent_instance_id":"inst_agent_1"`), "must contain subscriber_agent_instance_id")
	testing.expect(t, strings.contains(out, `"chain_id":"chain_abc"`), "must contain chain_id")
	testing.expect(t, strings.contains(out, `"task_id":"task_xyz"`), "must contain task_id")
	testing.expect(t, strings.contains(out, `"event_type":"all"`), "must contain event_type")
	testing.expect(t, strings.contains(out, `"created_at":"2026-09-28T10:00:00Z"`), "must contain created_at")
}

sub_wire_fixture :: struct {
	db_path:       string,
	conn:          sqlite.Conn,
	tc_impl:       sqlite.Taskchain_Repo_SQLite,
	ag_impl:       sqlite.Agent_Repo_SQLite,
	br_impl:       sqlite.Bridge_Repo_SQLite,
	us_impl:       sqlite.User_Repo_SQLite,
	tc_repo:       iface.Taskchain_Repository,
	ag_repo:       iface.Agent_Repository,
	br_repo:       iface.Bridge_Repository,
	us_repo:       iface.User_Repository,
	clock:         platform.Clock,
	ids:           platform.ID_Generator,
	ag_svc:        agent_service.Agent_Service,
	tc_svc:        taskchain_service.Taskchain_Service,
	br_svc:        bridge_service.Bridge_Service,
	us_svc:        user_service.User_Service,
	auth_svc:      auth_service.Auth_Service,
	th:            Taskchain_Handlers,
	ah:            Agent_Action_Handlers,
	owner:         domain.User_ID,
	chain_id:      domain.Task_Chain_ID,
	task_id:       domain.Task_ID,
	bridge_id:     string,
	bridge_token:  string,
	instance_id:   string,
	agent_headers: [2]contracts.HTTP_Header,
}

SUB_WIRE_USER_HEADERS := [1]contracts.HTTP_Header{{name = "X-authentik-username", value = "sub_owner"}}
SUB_WIRE_TRUSTED_CIDRS := [1]string{"127.0.0.1/32"}

sub_wire_setup :: proc(t: ^testing.T, tag: string) -> ^sub_wire_fixture {
	f := new(sub_wire_fixture)
	f.db_path = ":memory:"
	

	conn, open_ok, open_err := sqlite.open(f.db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	f.conn = conn

	mig_ok, mig_err := sqlite.run_migrations(&f.conn)
	testing.expectf(t, mig_ok, "migrations ok: %s (%v)", mig_err.message, mig_err.code)
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	f.tc_repo = sqlite.new_taskchain_repository(&f.tc_impl, &f.conn)
	f.ag_repo = sqlite.new_agent_repository(&f.ag_impl, &f.conn)
	f.br_repo = sqlite.new_bridge_repository(&f.br_impl, &f.conn)
	f.us_repo = sqlite.new_user_repository(&f.us_impl, &f.conn)

	f.clock = platform.real_clock()
	f.ids = http_test_id_generator()

	f.ag_svc = agent_service.new_agent_service(&f.ag_repo, &f.br_repo, &f.clock, &f.ids)
	f.tc_svc = taskchain_service.new_taskchain_service(&f.tc_repo, &f.ag_repo, &f.clock, &f.ids)
	f.tc_svc.agent_service = &f.ag_svc
	f.br_svc = bridge_service.new_bridge_service(&f.br_repo, &f.clock, &f.ids)
	f.us_svc = user_service.new_user_service_basic(&f.us_repo, &f.clock, &f.ids)

	f.auth_svc = auth_service.new_auth_service(auth_service.Trusted_Proxy_Config{
		username_header      = "X-authentik-username",
		trusted_proxy_cidrs  = SUB_WIRE_TRUSTED_CIDRS[:],
		auto_provision_users = true,
	}, &f.us_svc)
	f.auth_svc.clock = &f.clock
	f.auth_svc.ids = &f.ids
	f.auth_svc.bridges = &f.br_svc
	f.auth_svc.agents = &f.ag_svc

	f.th = Taskchain_Handlers{
		auth       = &f.auth_svc,
		taskchains = &f.tc_svc,
		agents     = &f.ag_svc,
	}
	f.ah = Agent_Action_Handlers{
		auth       = &f.auth_svc,
		agents     = &f.ag_svc,
		bridges    = &f.br_svc,
		taskchains = &f.tc_svc,
	}

	owner_ctx, owner_ok, _ := auth_service.resolve_auth_any(&f.auth_svc, auth_service.Auth_Request{
		remote_addr = "127.0.0.1:4444",
		headers     = SUB_WIRE_USER_HEADERS[:],
	})
	testing.expect(t, owner_ok, "owner resolved")
	f.owner = domain.User_ID(owner_ctx.user_id)
	f.chain_id = domain.Task_Chain_ID("chain_sub_test")
	f.task_id = domain.Task_ID("task_sub_test")

	_, _, _ = iface.taskchain_save_chain(&f.tc_repo, domain.Task_Chain{
		chain_id      = f.chain_id,
		owner_user_id = f.owner,
		title         = "Subscription Wire Test Chain",
		publish_state = .Published,
		status        = .Active,
		kind          = "sub_wire",
		created_at    = "2026-09-28T10:00:00Z",
		updated_at    = "2026-09-28T10:00:00Z",
	})

	_, _, _ = iface.taskchain_save_task(&f.tc_repo, domain.Task{
		task_id            = f.task_id,
		chain_id           = f.chain_id,
		owner_user_id      = f.owner,
		title              = "Subscription Wire Test Task",
		description        = "task description",
		publish_state      = .Published,
		status             = .In_Progress,
		priority           = .P2,
		assignee_ref_json  = "",
		reviewer_refs_json = "",
	})

	owner_auth := contracts.Auth_Context{kind = .User_Token, user_id = string(f.owner)}
	// Provisioned through the DEVICE-GRANT path, the only enrollment there is
	// (REQ-ENROLL-9). This replaced a create_enrollment + enroll_bridge pair; the
	// bridge and its credential are what this fixture needs, and how the credential
	// was approved is not what these tests are about.
	enrolled, e_ok, _ := bridge_service.enroll_bridge_from_device_grant(&f.br_svc, bridge_service.Device_Enroll_Input{
		owner_user_id = string(f.owner),
		bridge_public_key = "04aabb",
		bridge_key_fingerprint = "aaaa bbbb cccc dddd",
		machine_hostname = "sub-host",
	})
	testing.expect(t, e_ok, "bridge enrolled ok")
	f.bridge_id = strings.clone(enrolled.bridge.bridge_id)
	f.bridge_token = strings.clone(enrolled.bridge_token)

	f.instance_id = "inst_sub_test"
	_, inst_ok, _ := iface.agent_save_instance(&f.ag_repo, domain.Agent_Instance{
		agent_instance_id = f.instance_id,
		owner_user_id     = f.owner,
		agent_id          = "agt_sub_test",
		bridge_id         = f.bridge_id,
		display_name      = "subscriber instance",
		chain_id          = string(f.chain_id),
		runtime_status    = "running",
		startup_status    = "ready",
		created_at        = "2026-09-28T10:00:00Z",
		updated_at        = "2026-09-28T10:00:00Z",
	})
	testing.expect(t, inst_ok, "agent instance saved")

	f.agent_headers[0] = contracts.HTTP_Header{name = "Authorization", value = fmt.tprintf("Bearer %s", f.bridge_token)}
	f.agent_headers[1] = contracts.HTTP_Header{name = "X-Heimdall-Instance-Token", value = fmt.tprintf("hit_%s", f.instance_id)}

	return f
}

sub_wire_teardown :: proc(f: ^sub_wire_fixture) {
	if f == nil do return
	sqlite.close(&f.conn)
	
	delete(f.bridge_id)
	delete(f.bridge_token)
	free(f)
}

@test
test_rest_taskchain_and_task_subscription_handlers :: proc(t: ^testing.T) {
	f := sub_wire_setup(t, "rest")
	defer sub_wire_teardown(f)

	chain_sub_path := fmt.tprintf("/api/v1/task-chains/%s/subscriptions", f.chain_id)
	task_sub_path := fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/subscriptions", f.chain_id, f.task_id)

	// 1. POST chain subscription via REST
	post_chain_req := Request{
		method      = "POST",
		path        = chain_sub_path,
		body        = fmt.tprintf(`{{"subscriber_agent_instance_id":"%s","events":"chain_status"}}`, f.instance_id),
		request_id  = "req_sub_1",
		remote_addr = "127.0.0.1:4444",
		headers     = SUB_WIRE_USER_HEADERS[:],
	}
	resp1 := task_chain_subscribe_handler(&f.th, post_chain_req)
	testing.expect_value(t, resp1.status, 201)
	testing.expect(t, strings.contains(resp1.body, `"subscription_id":`), "response must contain subscription_id")
	testing.expect(t, strings.contains(resp1.body, `"event_type":"chain_status"`), "response must contain event_type")
	testing.expect(t, strings.contains(resp1.body, fmt.tprintf(`"subscriber_agent_instance_id":"%s"`, f.instance_id)), "response must contain subscriber_id")

	// 2. DELETE chain subscription via REST
	del_chain_req := Request{
		method      = "DELETE",
		path        = chain_sub_path,
		body        = fmt.tprintf(`{{"subscriber_agent_instance_id":"%s","events":"chain_status"}}`, f.instance_id),
		request_id  = "req_sub_2",
		remote_addr = "127.0.0.1:4444",
		headers     = SUB_WIRE_USER_HEADERS[:],
	}
	resp2 := task_chain_unsubscribe_handler(&f.th, del_chain_req)
	testing.expect_value(t, resp2.status, 200)
	testing.expect(t, strings.contains(resp2.body, `"removed":true`), "delete must report removed:true")

	// 3. POST task subscription via REST
	post_task_req := Request{
		method      = "POST",
		path        = task_sub_path,
		body        = fmt.tprintf(`{{"subscriber_agent_instance_id":"%s","events":"task_status"}}`, f.instance_id),
		request_id  = "req_sub_3",
		remote_addr = "127.0.0.1:4444",
		headers     = SUB_WIRE_USER_HEADERS[:],
	}
	resp3 := task_subscribe_handler(&f.th, post_task_req)
	testing.expect_value(t, resp3.status, 201)
	testing.expect(t, strings.contains(resp3.body, `"subscription_id":`), "response must contain subscription_id")
	testing.expect(t, strings.contains(resp3.body, `"event_type":"task_status"`), "response must contain event_type")
	testing.expect(t, strings.contains(resp3.body, fmt.tprintf(`"task_id":"%s"`, f.task_id)), "response must contain task_id")

	// 4. DELETE task subscription via REST
	del_task_req := Request{
		method      = "DELETE",
		path        = task_sub_path,
		body        = fmt.tprintf(`{{"subscriber_agent_instance_id":"%s","events":"task_status"}}`, f.instance_id),
		request_id  = "req_sub_4",
		remote_addr = "127.0.0.1:4444",
		headers     = SUB_WIRE_USER_HEADERS[:],
	}
	resp4 := task_unsubscribe_handler(&f.th, del_task_req)
	testing.expect_value(t, resp4.status, 200)
	testing.expect(t, strings.contains(resp4.body, `"removed":true`), "delete must report removed:true")
}

@test
test_agent_action_subscription_handlers :: proc(t: ^testing.T) {
	f := sub_wire_setup(t, "agent_action")
	defer sub_wire_teardown(f)

	// 1. Agent action chain subscribe
	chain_sub_req := Request{
		method      = "POST",
		path        = "/api/v1/agent-actions/chain/subscribe",
		body        = fmt.tprintf(`{{"params":{{"chain_id":"%s","events":"all"}}}}`, f.chain_id),
		request_id  = "req_act_1",
		remote_addr = "127.0.0.1:4444",
		headers     = f.agent_headers[:],
	}
	resp1 := agent_action_chain_subscribe_handler(&f.ah, chain_sub_req)
	testing.expect_value(t, resp1.status, 200)
	testing.expect(t, strings.contains(resp1.body, `"subscription_id":`), "action must return subscription_id")
	testing.expect(t, strings.contains(resp1.body, `"event_type":"all"`), "action must return event_type")

	// 2. Agent action chain unsubscribe
	chain_unsub_req := Request{
		method      = "POST",
		path        = "/api/v1/agent-actions/chain/unsubscribe",
		body        = fmt.tprintf(`{{"params":{{"chain_id":"%s"}}}}`, f.chain_id),
		request_id  = "req_act_2",
		remote_addr = "127.0.0.1:4444",
		headers     = f.agent_headers[:],
	}
	resp2 := agent_action_chain_unsubscribe_handler(&f.ah, chain_unsub_req)
	testing.expect_value(t, resp2.status, 200)
	testing.expect(t, strings.contains(resp2.body, `"removed":true`), "action must report removed:true")

	// 3. Agent action task subscribe
	task_sub_req := Request{
		method      = "POST",
		path        = "/api/v1/agent-actions/task/subscribe",
		body        = fmt.tprintf(`{{"params":{{"task_id":"%s","events":"task_status"}}}}`, f.task_id),
		request_id  = "req_act_3",
		remote_addr = "127.0.0.1:4444",
		headers     = f.agent_headers[:],
	}
	resp3 := agent_action_task_subscribe_handler(&f.ah, task_sub_req)
	testing.expect_value(t, resp3.status, 200)
	testing.expect(t, strings.contains(resp3.body, `"subscription_id":`), "action must return subscription_id")
	testing.expect(t, strings.contains(resp3.body, fmt.tprintf(`"task_id":"%s"`, f.task_id)), "action must return task_id")

	// 4. Agent action task unsubscribe
	task_unsub_req := Request{
		method      = "POST",
		path        = "/api/v1/agent-actions/task/unsubscribe",
		body        = fmt.tprintf(`{{"params":{{"task_id":"%s"}}}}`, f.task_id),
		request_id  = "req_act_4",
		remote_addr = "127.0.0.1:4444",
		headers     = f.agent_headers[:],
	}
	resp4 := agent_action_task_unsubscribe_handler(&f.ah, task_unsub_req)
	testing.expect_value(t, resp4.status, 200)
	testing.expect(t, strings.contains(resp4.body, `"removed":true`), "action must report removed:true")
}

@test
test_subscription_route_matching :: proc(t: ^testing.T) {
	testing.expect(t, route_matches("/api/v1/task-chains/*/subscriptions", "/api/v1/task-chains/chain_123/subscriptions"), "chain subscription route matches")
	testing.expect(t, route_matches("/api/v1/task-chains/*/tasks/*/subscriptions", "/api/v1/task-chains/chain_123/tasks/task_456/subscriptions"), "task subscription route matches")
	testing.expect(t, route_matches("/api/v1/tasks/*/subscriptions", "/api/v1/tasks/task_456/subscriptions"), "tasks subscription route matches")
	testing.expect(t, route_matches("/api/v1/agent-actions/chain/subscribe", "/api/v1/agent-actions/chain/subscribe"), "agent action chain subscribe route matches")
	testing.expect(t, route_matches("/api/v1/agent-actions/chain/unsubscribe", "/api/v1/agent-actions/chain/unsubscribe"), "agent action chain unsubscribe route matches")
	testing.expect(t, route_matches("/api/v1/agent-actions/task/subscribe", "/api/v1/agent-actions/task/subscribe"), "agent action task subscribe route matches")
	testing.expect(t, route_matches("/api/v1/agent-actions/task/unsubscribe", "/api/v1/agent-actions/task/unsubscribe"), "agent action task unsubscribe route matches")
}
