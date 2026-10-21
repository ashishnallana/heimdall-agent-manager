package http

// REQ-TB-2 wire contract: the optional per-task `bridge_id` pin over BOTH transports.
//
// The unit tests pin the shared parse helper and the emitted JSON key. The two
// handler-level tests drive the REAL create/patch/agent-action handlers against a
// real sqlite-backed service stack with real auth (a trusted-proxy user for the
// cookie API; an enrolled bridge plus its instance assertion for the agent-action
// API), so "persisted", "cleared", and "rejected with nothing persisted" are
// asserted against the database instead of a fake, and both transports are proven
// to reach the same TB-1 service inputs.

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

// ---------------------------------------------------------------- unit: parse

@(test)
test_task_bridge_id_from_body_absent_present_empty :: proc(t: ^testing.T) {
	absent, absent_present := task_bridge_id_from_body(`{"title":"probe"}`)
	testing.expect_value(t, absent, "")
	testing.expect(t, !absent_present, "absent bridge_id must not claim presence")

	pinned, pinned_present := task_bridge_id_from_body(`{"title":"probe","bridge_id":"brg_x"}`)
	testing.expect_value(t, pinned, "brg_x")
	testing.expect(t, pinned_present, "present bridge_id must be reported present")

	// Explicitly empty is PRESENT: on PATCH that is the clear-to-inherit signal, so
	// the two cases must not collapse into each other.
	empty, empty_present := task_bridge_id_from_body(`{"title":"probe","bridge_id":""}`)
	testing.expect_value(t, empty, "")
	testing.expect(t, empty_present, "explicitly empty bridge_id must still report present")
}

// --------------------------------------------------------------- unit: emit

@(test)
test_write_task_json_always_emits_bridge_id :: proc(t: ^testing.T) {
	cases := [][2]string{{"brg_pin", `"bridge_id":"brg_pin"`}, {"", `"bridge_id":""`}}
	for c in cases {
		task := domain.Task{
			task_id            = domain.Task_ID("task_wire"),
			chain_id           = domain.Task_Chain_ID("chain_wire"),
			owner_user_id      = domain.User_ID("user_wire"),
			title              = "Wire Task",
			description        = "d",
			publish_state      = .Draft,
			state              = .Ready,
			priority           = .P2,
			bridge_id          = c[0],
		}
		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		write_task_json(&b, task)
		out := strings.to_string(b)
		testing.expectf(t, strings.contains(out, c[1]), "task JSON must carry %s (got %s)", c[1], out)
	}
}

// ------------------------------------------------------ handler-level fixture

wire_fixture :: struct {
	db_path:  string,
	conn:     sqlite.Conn,
	tc_impl:  sqlite.Taskchain_Repo_SQLite,
	ag_impl:  sqlite.Agent_Repo_SQLite,
	br_impl:  sqlite.Bridge_Repo_SQLite,
	us_impl:  sqlite.User_Repo_SQLite,
	tc_repo:  iface.Taskchain_Repository,
	ag_repo:  iface.Agent_Repository,
	br_repo:  iface.Bridge_Repository,
	us_repo:  iface.User_Repository,
	clock:    platform.Clock,
	ids:      platform.ID_Generator,
	ag_svc:   agent_service.Agent_Service,
	tc_svc:   taskchain_service.Taskchain_Service,
	br_svc:   bridge_service.Bridge_Service,
	us_svc:   user_service.User_Service,
	auth_svc: auth_service.Auth_Service,
	th:       Taskchain_Handlers,
	ah:       Agent_Action_Handlers,

	owner:          domain.User_ID,
	chain_id:       domain.Task_Chain_ID,
	bridge_pin:     string, // owner bridge used as the pin / clear / reject baseline
	bridge_alt:     string, // second owner bridge used as the repin target
	bridge_foreign: string,
	bridge_token:   string, // plaintext token of bridge_pin (agent-action auth)
	instance_id:    string,
	// The agent-action headers live in the (heap) fixture so their backing array
	// outlives the request frame, and the two dynamic values are fixture-owned
	// clones of setup scratch strings.
	agent_headers:     [2]contracts.HTTP_Header,
	agent_auth_value:  string,
	agent_relay_value: string,
}

// File-scope so the backing arrays outlive the frames that build requests and
// store the cidrs: a compound literal allocated inside wire_setup dangles once
// setup returns (auth.remote_addr_trusted reads it on every later request).
WIRE_COOKIE_HEADERS := [1]contracts.HTTP_Header{{name = "X-authentik-username", value = "wire_owner"}}
WIRE_TRUSTED_CIDRS := [1]string{"127.0.0.1/32"}

wire_cookie_request :: proc(f: ^wire_fixture, method, path, body: string) -> Request {
	return Request{
		method      = method,
		path        = path,
		body        = body,
		request_id  = "req_wire",
		remote_addr = "127.0.0.1:4444",
		headers     = WIRE_COOKIE_HEADERS[:],
	}
}

wire_agent_request :: proc(f: ^wire_fixture, action, body: string) -> Request {
	return Request{
		method      = "POST",
		path        = fmt.tprintf("/api/v1/agent-actions/tasks/%s", action),
		body        = body,
		request_id  = "req_wire_agent",
		remote_addr = "127.0.0.1:4444",
		headers     = f.agent_headers[:],
	}
}

// wire_body builds a request body on the heap. It must NOT be fmt.tprintf: Odin's
// formatter treats `{`/`}` as directives, so a tprintf'd JSON literal comes back as
// `%!(MISSING CLOSE BRACE)title":...` — a body with NO fields, which the service
// then rejects ("task title is required"). The caller owns the result.
wire_body :: proc(parts: []string) -> string {
	return strings.concatenate(parts)
}

// wire_enroll_bridge provisions a bridge for an owner through the DEVICE-GRANT path,
// the only enrollment there is (REQ-ENROLL-9).
//
// It takes the owner as a plain user id rather than an Auth_Context: the deleted
// create_enrollment derived the owner from an Auth_Context, while
// enroll_bridge_from_device_grant takes the approving user directly — the browser
// approval is what establishes ownership, so there is no request context to read.
// The `wire-host-foreign` case still works, which is what matters here: it is how
// this file builds a bridge owned by SOMEONE ELSE to test cross-owner task scoping.
wire_enroll_bridge :: proc(t: ^testing.T, f: ^wire_fixture, owner_user_id: string, hostname: string, token_out: ^string) -> string {
	enrolled, e_ok, e_err := bridge_service.enroll_bridge_from_device_grant(&f.br_svc, bridge_service.Device_Enroll_Input{
		owner_user_id = owner_user_id,
		bridge_public_key = "04aabb",
		bridge_key_fingerprint = "aaaa bbbb cccc dddd",
		machine_hostname = hostname,
	})
	testing.expectf(t, e_ok, "bridge %s enrolled (%s)", hostname, e_err.message)
	if token_out != nil do token_out^ = enrolled.bridge_token
	return enrolled.bridge.bridge_id
}

wire_count_tasks :: proc(f: ^wire_fixture) -> int {
	tasks, err := iface.taskchain_list_tasks_by_chain(&f.tc_repo, f.chain_id, f.owner)
	if err.code != .None do return -1
	return len(tasks)
}

wire_persisted_pin :: proc(t: ^testing.T, f: ^wire_fixture, task_id: string) -> string {
	row, ok, _ := iface.taskchain_get_task(&f.tc_repo, domain.Task_ID(task_id))
	testing.expect(t, ok, "task row readable")
	return row.bridge_id
}

wire_setup :: proc(t: ^testing.T, tag: string) -> ^wire_fixture {
	f := new(wire_fixture)
	f.db_path = ":memory:"
	

	conn, open_ok, open_err := sqlite.open(f.db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	f.conn = conn

	mig_ok, mig_err := sqlite.run_migrations(&f.conn)
	testing.expect(t, mig_ok, "migrations ok")
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
		trusted_proxy_cidrs  = WIRE_TRUSTED_CIDRS[:],
		auto_provision_users = true,
	}, &f.us_svc)
	f.auth_svc.clock = &f.clock
	f.auth_svc.ids = &f.ids
	f.auth_svc.bridges = &f.br_svc
	f.auth_svc.agents = &f.ag_svc

	f.th = Taskchain_Handlers{auth = &f.auth_svc, taskchains = &f.tc_svc, agents = &f.ag_svc}
	f.ah = Agent_Action_Handlers{auth = &f.auth_svc, agents = &f.ag_svc, bridges = &f.br_svc, taskchains = &f.tc_svc}

	// Resolve the owner through the SAME trusted-proxy path the cookie handlers use
	// (auto-provisioned), so the fixture owner id is exactly what auth will produce.
	owner_ctx, owner_ok, owner_err := auth_service.resolve_auth_any(&f.auth_svc, auth_service.Auth_Request{
		remote_addr = "127.0.0.1:4444",
		headers     = WIRE_COOKIE_HEADERS[:],
	})
	testing.expectf(t, owner_ok, "trusted-proxy owner resolves (%s)", owner_err.message)
	f.owner = domain.User_ID(owner_ctx.user_id)

	f.chain_id = domain.Task_Chain_ID("chain_wire_tb2")
	_, _, _ = iface.taskchain_save_chain(&f.tc_repo, domain.Task_Chain{
		chain_id      = f.chain_id,
		owner_user_id = f.owner,
		title         = "TB-2 Wire Chain",
		publish_state = .Draft,
		status        = .Active,
		kind          = domain.CHAIN_KIND_MIXED_WORK,
		created_at    = "2026-09-25T10:00:00Z",
		updated_at    = "2026-09-25T10:00:00Z",
	})

	owner_auth := contracts.Auth_Context{kind = .User_Token, user_id = string(f.owner)}
	f.bridge_pin = wire_enroll_bridge(t, f, owner_auth.user_id, "wire-host-pin", &f.bridge_token)
	f.bridge_alt = wire_enroll_bridge(t, f, owner_auth.user_id, "wire-host-alt", nil)
	f.bridge_foreign = wire_enroll_bridge(t, f, "wire_foreign_owner", "wire-host-foreign", nil)
	// Enrollment mints its ids/token on the temp allocator; the fixture must own
	// stable copies since they feed later comparisons and request bodies.
	f.bridge_token = strings.clone(f.bridge_token)
	f.bridge_pin = strings.clone(f.bridge_pin)
	f.bridge_alt = strings.clone(f.bridge_alt)
	f.bridge_foreign = strings.clone(f.bridge_foreign)

	f.instance_id = "inst_wire_tb2"
	_, inst_ok, inst_err := iface.agent_save_instance(&f.ag_repo, domain.Agent_Instance{
		agent_instance_id = f.instance_id,
		owner_user_id     = f.owner,
		agent_id          = "agt_wire_tb2",
		bridge_id         = f.bridge_pin,
		display_name      = "wire instance",
		chain_id          = string(f.chain_id),
		runtime_status    = "running",
		startup_status    = "ready",
		created_at        = "2026-09-25T10:00:00Z",
		updated_at        = "2026-09-25T10:00:00Z",
	})
	testing.expectf(t, inst_ok, "instance fixture saved (%s)", inst_err.message)

	// Instance_Token writes are gated on the members table (create: member or
	// coordinator; update: coordinator or assignee), so the fixture instance is
	// seated as the chain's coordinator.
	_, member_ok, member_err := iface.taskchain_save_member(&f.tc_repo, domain.Task_Chain_Member{
		chain_id          = f.chain_id,
		agent_instance_id = f.instance_id,
		agent_id          = "agt_wire_tb2",
		owner_user_id     = f.owner,
		role              = "coordinator",
		created_at        = "2026-09-25T10:00:00Z",
	})
	testing.expectf(t, member_ok, "coordinator member fixture saved (%s)", member_err.message)

	f.agent_auth_value = strings.concatenate({"Bearer ", f.bridge_token})
	f.agent_relay_value = strings.concatenate({"hit_", f.instance_id})
	f.agent_headers[0] = contracts.HTTP_Header{name = "Authorization", value = f.agent_auth_value}
	f.agent_headers[1] = contracts.HTTP_Header{name = "X-Heimdall-Instance-Token", value = f.agent_relay_value}
	return f
}

wire_teardown :: proc(f: ^wire_fixture) {
	sqlite.close(&f.conn)
	
	delete(f.bridge_token)
	delete(f.bridge_pin)
	delete(f.bridge_alt)
	delete(f.bridge_foreign)
	delete(f.agent_auth_value)
	delete(f.agent_relay_value)
	free(f)
}

// ------------------------------------------------- cookie transport (REQ-TB-2)

@(test)
test_cookie_task_bridge_id_create_and_patch :: proc(t: ^testing.T) {
	f := wire_setup(t, "cookie")
	defer wire_teardown(f)

	list_path := fmt.tprintf("/api/v1/task-chains/%s/tasks", f.chain_id)

	// 1. Create WITH a valid owner bridge: persisted + echoed by the serializer.
	pin_body := wire_body([]string{`{"title":"Pinned via cookie","bridge_id":"`, f.bridge_pin, `"}`})
	defer delete(pin_body)
	pin_resp := create_task_handler(&f.th, wire_cookie_request(f, "POST", list_path, pin_body))
	testing.expect_value(t, pin_resp.status, 201)
	testing.expectf(t, strings.contains(pin_resp.body, fmt.tprintf(`"bridge_id":"%s"`, f.bridge_pin)), "create response must echo the pin: %s", pin_resp.body)
	pinned_id := json_string(pin_resp.body, "task_id")
	testing.expect(t, pinned_id != "", "create response carries the new task id")
	testing.expect_value(t, wire_persisted_pin(t, f, pinned_id), f.bridge_pin)

	// 2. Create WITHOUT the field: inherit — persisted empty, key still emitted.
	inherit_resp := create_task_handler(&f.th, wire_cookie_request(f, "POST", list_path, `{"title":"Inherit via cookie"}`))
	testing.expect_value(t, inherit_resp.status, 201)
	testing.expectf(t, strings.contains(inherit_resp.body, `"bridge_id":""`), "absent bridge_id must still emit the key empty: %s", inherit_resp.body)
	inherit_id := json_string(inherit_resp.body, "task_id")
	testing.expect_value(t, wire_persisted_pin(t, f, inherit_id), "")

	patch_path := fmt.tprintf("%s/%s", list_path, pinned_id)

	// 3. PATCH without the field: pin untouched.
	keep_resp := patch_task_handler(&f.th, wire_cookie_request(f, "PATCH", patch_path, `{"title":"no pin change"}`))
	testing.expect_value(t, keep_resp.status, 200)
	testing.expect_value(t, wire_persisted_pin(t, f, pinned_id), f.bridge_pin)

	// 4. PATCH with "": clears back to inherit.
	clear_resp := patch_task_handler(&f.th, wire_cookie_request(f, "PATCH", patch_path, `{"bridge_id":""}`))
	testing.expect_value(t, clear_resp.status, 200)
	testing.expectf(t, strings.contains(clear_resp.body, `"bridge_id":""`), "cleared patch response must emit the empty pin: %s", clear_resp.body)
	testing.expect_value(t, wire_persisted_pin(t, f, pinned_id), "")

	// 5. PATCH with another owner bridge: repins.
	repin_body := wire_body([]string{`{"bridge_id":"`, f.bridge_alt, `"}`})
	defer delete(repin_body)
	repin_resp := patch_task_handler(&f.th, wire_cookie_request(f, "PATCH", patch_path, repin_body))
	testing.expect_value(t, repin_resp.status, 200)
	testing.expect_value(t, wire_persisted_pin(t, f, pinned_id), f.bridge_alt)

	// 6. Unknown + foreign pins on create: 404 and nothing persisted.
	before := wire_count_tasks(f)
	unknown_resp := create_task_handler(&f.th, wire_cookie_request(f, "POST", list_path, `{"title":"Unknown pin","bridge_id":"brg_wire_missing"}`))
	testing.expect_value(t, unknown_resp.status, 404)
	foreign_body := wire_body([]string{`{"title":"Foreign pin","bridge_id":"`, f.bridge_foreign, `"}`})
	defer delete(foreign_body)
	foreign_resp := create_task_handler(&f.th, wire_cookie_request(f, "POST", list_path, foreign_body))
	testing.expect_value(t, foreign_resp.status, 404)
	testing.expect_value(t, wire_count_tasks(f), before)

	// 7. Rejected PATCH leaves the on-disk pin unchanged.
	bad_patch := patch_task_handler(&f.th, wire_cookie_request(f, "PATCH", patch_path, `{"bridge_id":"brg_wire_missing"}`))
	testing.expect_value(t, bad_patch.status, 404)
	testing.expect_value(t, wire_persisted_pin(t, f, pinned_id), f.bridge_alt)
}

// ------------------------------------------- agent-action transport (REQ-TB-2)

@(test)
test_agent_action_task_bridge_id_create_and_update :: proc(t: ^testing.T) {
	f := wire_setup(t, "agent")
	defer wire_teardown(f)

	// 1. Agent creates a task with a valid owner bridge: persisted + echoed.
	create_body := wire_body([]string{`{"params":{"chain_id":"`, string(f.chain_id), `","title":"Agent pinned","bridge_id":"`, f.bridge_alt, `"}}`})
	defer delete(create_body)
	create_resp := agent_action_task_create_handler(&f.ah, wire_agent_request(f, "create", create_body))
	testing.expect_value(t, create_resp.status, 201)
	testing.expectf(t, strings.contains(create_resp.body, fmt.tprintf(`"bridge_id":"%s"`, f.bridge_alt)), "agent create response must echo the pin: %s", create_resp.body)
	created_id := json_string(create_resp.body, "task_id")
	testing.expect(t, created_id != "", "agent create response carries the new task id")
	testing.expect_value(t, wire_persisted_pin(t, f, created_id), f.bridge_alt)

	// 2. Agent create without the field: inherit.
	inherit_body := wire_body([]string{`{"params":{"chain_id":"`, string(f.chain_id), `","title":"Agent inherit"}}`})
	defer delete(inherit_body)
	inherit_resp := agent_action_task_create_handler(&f.ah, wire_agent_request(f, "create", inherit_body))
	testing.expect_value(t, inherit_resp.status, 201)
	inherit_id := json_string(inherit_resp.body, "task_id")
	testing.expect_value(t, wire_persisted_pin(t, f, inherit_id), "")

	// 3. Agent update without the field: pin untouched.
	keep_body := wire_body([]string{`{"params":{"task_id":"`, created_id, `","title":"no pin change"}}`})
	defer delete(keep_body)
	keep_resp := agent_action_task_update_handler(&f.ah, wire_agent_request(f, "update", keep_body))
	testing.expect_value(t, keep_resp.status, 200)
	testing.expect_value(t, wire_persisted_pin(t, f, created_id), f.bridge_alt)

	// 4. Agent update "" clears to inherit; a value repins.
	clear_body := wire_body([]string{`{"params":{"task_id":"`, created_id, `","bridge_id":""}}`})
	defer delete(clear_body)
	clear_resp := agent_action_task_update_handler(&f.ah, wire_agent_request(f, "update", clear_body))
	testing.expect_value(t, clear_resp.status, 200)
	testing.expect_value(t, wire_persisted_pin(t, f, created_id), "")
	agent_repin_body := wire_body([]string{`{"params":{"task_id":"`, created_id, `","bridge_id":"`, f.bridge_pin, `"}}`})
	defer delete(agent_repin_body)
	repin_resp := agent_action_task_update_handler(&f.ah, wire_agent_request(f, "update", agent_repin_body))
	testing.expect_value(t, repin_resp.status, 200)
	testing.expect_value(t, wire_persisted_pin(t, f, created_id), f.bridge_pin)

	// 5. Unknown pin on create: 404, nothing persisted.
	before := wire_count_tasks(f)
	unknown_body := wire_body([]string{`{"params":{"chain_id":"`, string(f.chain_id), `","title":"Agent unknown","bridge_id":"brg_wire_missing"}}`})
	defer delete(unknown_body)
	unknown_resp := agent_action_task_create_handler(&f.ah, wire_agent_request(f, "create", unknown_body))
	testing.expect_value(t, unknown_resp.status, 404)
	testing.expect_value(t, wire_count_tasks(f), before)

	// 6. Foreign pin on update: 404, on-disk pin unchanged.
	agent_foreign_body := wire_body([]string{`{"params":{"task_id":"`, created_id, `","bridge_id":"`, f.bridge_foreign, `"}}`})
	defer delete(agent_foreign_body)
	foreign_resp := agent_action_task_update_handler(&f.ah, wire_agent_request(f, "update", agent_foreign_body))
	testing.expect_value(t, foreign_resp.status, 404)
	testing.expect_value(t, wire_persisted_pin(t, f, created_id), f.bridge_pin)
}

// ------------------------------------------ v2 state projection on the wire

// Task System v2: the wire carries the five-state `state` projection (plus
// cancelled) and the derived `unblocks_dependents` badge; there is no FSM
// `allowed_transitions` / `next_states` / `allowed_actions` tail any more, and
// the detail wire always carries a `leases` array. Only Done unblocks
// dependents: a cancelled prerequisite keeps them blocked (mixed-work rule).
@(test)
test_write_task_json_and_detail_emit_v2_state :: proc(t: ^testing.T) {
	State_Wire_Case :: struct {
		state:     domain.Task_State,
		wire:      string,
		unblocks:  bool,
	}

	cases := []State_Wire_Case{
		{state = .Backlog, wire = `"state":"backlog"`, unblocks = false},
		{state = .Ready, wire = `"state":"ready"`, unblocks = false},
		{state = .In_Progress, wire = `"state":"in_progress"`, unblocks = false},
		{state = .In_Review, wire = `"state":"in_review"`, unblocks = false},
		{state = .Done, wire = `"state":"done"`, unblocks = true},
		{state = .Cancelled, wire = `"state":"cancelled"`, unblocks = false},
	}

	f := wire_setup(t, "state_wire")
	defer wire_teardown(f)
	owner_auth := contracts.Auth_Context{kind = .User_Token, user_id = string(f.owner)}

	for c in cases {
		task := domain.Task{
			task_id       = domain.Task_ID("task_state_wire"),
			chain_id      = f.chain_id,
			owner_user_id = f.owner,
			title         = "State Wire Task",
			description   = "desc",
			publish_state = .Published,
			state         = c.state,
			kind          = .Task,
			priority      = .P2,
			brief_json    = `{"goal":"g"}`,
			bridge_id     = "",
		}
		unblocks_tail := `"unblocks_dependents":true` if c.unblocks else `"unblocks_dependents":false`

		b1 := strings.builder_make()
		defer strings.builder_destroy(&b1)
		write_task_json(&b1, task)
		out1 := strings.to_string(b1)
		testing.expectf(t, strings.contains(out1, c.wire), "write_task_json(%v) must emit %s (got %s)", c.state, c.wire, out1)
		testing.expectf(t, strings.contains(out1, unblocks_tail), "write_task_json(%v) must emit %s (got %s)", c.state, unblocks_tail, out1)
		testing.expectf(t, !strings.contains(out1, `"allowed_transitions"`), "write_task_json(%v) must not emit the FSM tail (got %s)", c.state, out1)
		testing.expectf(t, !strings.contains(out1, `"status"`), "write_task_json(%v) must not emit status (got %s)", c.state, out1)

		b2 := strings.builder_make()
		defer strings.builder_destroy(&b2)
		write_task_detail_json(&b2, &f.th, owner_auth, task, nil)
		out2 := strings.to_string(b2)
		testing.expectf(t, strings.contains(out2, c.wire), "write_task_detail_json(%v) must emit %s (got %s)", c.state, c.wire, out2)
		testing.expectf(t, strings.contains(out2, unblocks_tail), "write_task_detail_json(%v) must emit %s (got %s)", c.state, unblocks_tail, out2)
		testing.expectf(t, strings.contains(out2, `"leases":[]`), "write_task_detail_json(%v) must emit an empty leases array (got %s)", c.state, out2)
		testing.expectf(t, strings.contains(out2, `"blocked":false`), "write_task_detail_json(%v) with no deps must not be blocked (got %s)", c.state, out2)
		testing.expectf(t, !strings.contains(out2, `"allowed_transitions"`), "write_task_detail_json(%v) must not emit the FSM tail (got %s)", c.state, out2)
		testing.expectf(t, !strings.contains(out2, `"votes"`), "write_task_detail_json(%v) must not emit votes (got %s)", c.state, out2)
	}
}

// The detail wire carries each reviewer's verdict on the CURRENT attempt only.
@(test)
test_write_task_detail_emits_current_attempt_reviews :: proc(t: ^testing.T) {
	f := wire_setup(t, "review_wire")
	defer wire_teardown(f)
	owner_auth := contracts.Auth_Context{kind = .User_Token, user_id = string(f.owner)}
	task := domain.Task{
		task_id = domain.Task_ID("task_review_wire"), chain_id = f.chain_id, owner_user_id = f.owner,
		title = "Review Wire Task", publish_state = .Published, state = .In_Review, kind = .Task, priority = .P2,
		attempt_no = 2, brief_json = `{"goal":"g"}`,
	}
	save :: proc(t: ^testing.T, f: ^wire_fixture, task: domain.Task, attempt: int, kind, agent, role, verdict: string) {
		_, ok, err := iface.taskchain_save_review(&f.tc_repo, domain.Task_Review{
			task_id = task.task_id, chain_id = task.chain_id, owner_user_id = task.owner_user_id, attempt_no = attempt,
			role = role, reviewer_kind = kind, reviewer_agent_id = agent, verdict = verdict, created_at = "2026-10-21T00:00:00Z",
		})
		testing.expectf(t, ok, "save review: %v", err)
	}
	save(t, f, task, 1, "agent", "agt_old", "qa", "request_changes")
	save(t, f, task, 2, "agent", "agt_qa", "qa", "approve")
	save(t, f, task, 2, "agent", "agt_sec", "security", "request_changes")
	save(t, f, task, 2, "user", "", "user", "approve")

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_task_detail_json(&b, &f.th, owner_auth, task, nil)
	out := strings.to_string(b)
	testing.expectf(t, strings.contains(out, `"reviewer":"agt_qa","reviewer_kind":"agent","reviewer_instance_id":"","role":"qa","verdict":"approve"`), "agent approve (got %s)", out)
	testing.expectf(t, strings.contains(out, `"reviewer":"agt_sec","reviewer_kind":"agent","reviewer_instance_id":"","role":"security","verdict":"request_changes"`), "agent changes (got %s)", out)
	testing.expectf(t, strings.contains(out, `"reviewer":"user","reviewer_kind":"user","reviewer_instance_id":"","role":"user","verdict":"approve"`), "user approve (got %s)", out)
	testing.expectf(t, !strings.contains(out, "agt_old"), "earlier attempt's review is omitted (got %s)", out)
}
