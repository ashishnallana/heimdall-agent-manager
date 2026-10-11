package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import app "odin_test:hub/app"
import project_service "odin_test:hub/service/project"
import api_http "odin_test:hub/transport/http"

// T10 (REQ-T10-2): a REST keystroke into a pane on a LOCKED bridge answers HTTP 423
// {error:{code:"vault_locked", details:{bridge_id}}} instead of a silent 200; any other
// bridge outcome keeps the pre-T10 200.

@(private = "file")
T10_Route_Sink :: struct {
	reply: string,
	waits: int,
}

@(test)
test_t10_rest_shell_input_on_locked_bridge_is_423 :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/heimdall-hub-test-t10-vault-locked-%d.db", os.get_pid())
	_ = os.remove(db_path)
	defer _ = os.remove(db_path)

	cidrs := [?]string{"127.0.0.1/32"}
	graph: app.App_Graph
	ok, msg := app.build_graph(&graph, app.Hub_Config{
		database_path = db_path,
		migrations_dir = "src/hub/repository/sqlite/migrations",
		username_header = "X-authentik-username",
		display_name_header = "X-authentik-name",
		email_header = "X-authentik-email",
		trusted_proxy_cidrs = cidrs[:],
		auto_provision_users = true,
		logout_url = "/_dev/logout",
		// build_graph requires a Paddle environment; billing is not exercised here.
		paddle_environment = "sandbox",
	})
	testing.expect(t, ok, msg)
	defer app.shutdown_graph(&graph)

	alice := [?]contracts.HTTP_Header{{name = "X-authentik-username", value = "alice"}}
	bridge_id, _, enroll_ok := device_enroll_test_bridge(&graph, alice[:], "Alice Bridge")
	testing.expect(t, enroll_ok, "device-flow bridge provisioning failed")
	if !enroll_ok do return
	if b, b_ok, _ := iface.bridge_get_bridge(graph.bridges.repo, bridge_id); b_ok {
		b.status = .Online
		_, _, _ = iface.bridge_save_bridge(graph.bridges.repo, b)
	}

	state := T10_Route_Sink{reply = `{"type":"command_result","protocol_version":1,"command_id":"x","payload":{"status":"failed","error_code":"vault_locked"}}`}
	graph.bridges.bridge_command_sink = project_service.Bridge_Command_Sink{
		ctx = rawptr(&state),
		send_runtime_command = proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
			return true, {}
		},
		send_runtime_command_wait = proc(ctx: rawptr, command: project_service.Runtime_Command, timeout_ms: int) -> (string, bool, domain.Domain_Error) {
			s := (^T10_Route_Sink)(ctx)
			s.waits += 1
			return strings.clone(s.reply), true, {}
		},
	}

	path := fmt.tprintf("/api/v1/bridges/%s/shells/sh_t10/input", bridge_id)
	locked := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = path, body = `{"enc_b64":"vault:v1:AAAA"}`,
		request_id = "req_t10_locked", remote_addr = "127.0.0.1", headers = alice[:],
	})
	testing.expect_value(t, locked.status, 423)
	testing.expect(t, strings.contains(locked.body, `"code":"vault_locked"`), locked.body)
	testing.expect(t, strings.contains(locked.body, fmt.tprintf(`"bridge_id":"%s"`, bridge_id)), locked.body)
	testing.expect_value(t, state.waits, 1)

	state.reply = `{"type":"command_result","protocol_version":1,"command_id":"x","payload":{"status":"succeeded"}}`
	delivered := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = path, body = `{"enc_b64":"vault:v1:AAAA"}`,
		request_id = "req_t10_ok", remote_addr = "127.0.0.1", headers = alice[:],
	})
	testing.expect_value(t, delivered.status, 200)
}
