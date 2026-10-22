package http

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import auth_service "odin_test:hub/service/auth"
import user_service "odin_test:hub/service/user"

plan_test_paid_lookup :: proc(ctx: rawptr, user_id: string) -> (domain.User_Entitlements, domain.Domain_Error) {
	return domain.unlimited_entitlements(), {}
}

// Shared by the two real-socket stream regression suites.
plan_test_read_only_lookup :: proc(ctx: rawptr, user_id: string) -> (domain.User_Entitlements, domain.Domain_Error) {
	return {terminal_streaming_enabled = true}, {}
}

@(test)
test_terminal_input_policy_auth_kinds_and_lookup_failure :: proc(t: ^testing.T) {
	source := domain.Entitlement_Lookup{lookup = plan_test_read_only_lookup}
	for kind in ([]contracts.Auth_Kind{.User_Token, .Trusted_Proxy}) {
		err := require_terminal_input(source, {kind = kind, user_id = "owner"})
		testing.expect_value(t, err.code, domain.Error_Code.Plan_Limit_Reached)
	}
	for kind in ([]contracts.Auth_Kind{.Instance_Token, .Bridge_Token}) {
		testing.expect_value(t, require_terminal_input(source, {kind = kind}).code, domain.Error_Code.None)
	}
	testing.expect_value(t, require_terminal_input({}, {kind = .User_Token}).code, domain.Error_Code.None)
	failing := domain.Entitlement_Lookup{lookup = proc(ctx: rawptr, user_id: string) -> (domain.User_Entitlements, domain.Domain_Error) {
		return {}, domain.domain_error(.Internal_Error, "billing unavailable")
	}}
	testing.expect_value(t, require_terminal_input(failing, {kind = .User_Token, user_id = "owner"}).code, domain.Error_Code.Internal_Error)
	testing.expect_value(t, require_terminal_input(failing, {kind = .Instance_Token}).code, domain.Error_Code.None)
	paid := domain.Entitlement_Lookup{lookup = proc(ctx: rawptr, user_id: string) -> (domain.User_Entitlements, domain.Domain_Error) {
		return domain.unlimited_entitlements(), {}
	}}
	testing.expect_value(t, require_terminal_input(paid, {kind = .User_Token}).code, domain.Error_Code.None)
}

@(test)
test_terminal_input_plan_gates_all_rest_routes :: proc(t: ^testing.T) {
	user_repo := iface.User_Repository{get_by_id = proc(ctx: rawptr, id: domain.User_ID) -> (domain.User, bool, domain.Domain_Error) {
		return {user_id = id, name = string(id), status = .Active}, true, {}
	}}
	clock := platform.real_clock()
	ids := http_test_id_generator()
	users := user_service.new_user_service_basic(&user_repo, &clock, &ids)
	auth := auth_service.new_auth_service({username_header = "X-User", trusted_proxy_cidrs = []string{"127.0.0.1/32"}}, &users)
	source := domain.Entitlement_Lookup{lookup = plan_test_read_only_lookup}
	agents := Agent_Handlers{auth = &auth, entitlements = source}
	bridges := Bridge_Handlers{auth = &auth, entitlements = source}
	streams := Shell_Session_Stream_Handlers{auth = &auth, entitlements = source}
	shells := Shell_Session_Rest_Handlers{auth = &auth, entitlements = source}
	cases := []struct {
		handler: proc(ctx: rawptr, req: Request) -> Response,
		ctx: rawptr,
		path: string,
	}{
		{agent_instance_input_handler, &agents, "/api/v1/agent-instances/inst/input"},
		{agent_instance_resize_handler, &agents, "/api/v1/agent-instances/inst/resize"},
		{bridge_shell_input_handler, &bridges, "/api/v1/bridges/brg/shells/sh/input"},
		{bridge_shell_resize_handler, &bridges, "/api/v1/bridges/brg/shells/sh/resize"},
		{shell_session_input_handler, &streams, "/api/v1/shells/sh/input"},
		{shell_session_resize_handler, &streams, "/api/v1/shells/sh/resize"},
		{shell_session_signal_handler, &shells, "/api/v1/shells/sh/signal"},
	}
	for c in cases {
		resp := c.handler(c.ctx, Request{method = "POST", path = c.path, remote_addr = "127.0.0.1:1000",
			headers = []contracts.HTTP_Header{{name = "X-User", value = "owner"}},
			body = `{"data":"x","rows":24,"cols":80,"signal":2}`, request_id = "plan-rest"})
		testing.expect_value(t, resp.status, 402)
		testing.expect(t, strings.contains(resp.body, `"code":"plan_limit_reached"`), c.path)
		testing.expect(t, strings.contains(resp.body, `"limit":"terminal_input_enabled"`), c.path)
		testing.expect(t, strings.contains(resp.body, `"upgrade_path":"/settings/account"`), c.path)
		delete(resp.body)
	}
}
