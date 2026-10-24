package auth

import "core:mem"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import user_service "odin_test:hub/service/user"

auth_test_get_user :: proc(ctx: rawptr, user_id: domain.User_ID) -> (domain.User, bool, domain.Domain_Error) {
	if string(user_id) != "alice" do return domain.User{}, false, domain.domain_error(.Not_Found, "user not found")
	return domain.User{user_id = user_id, name = "alice", display_name = "Alice", status = .Active}, true, domain.Domain_Error{}
}

@(test)
test_resolve_trusted_proxy_auth_ignores_application_bearer :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	repo := iface.User_Repository{get_by_id = auth_test_get_user}
	clock := platform.real_clock()
	users := user_service.new_user_service_basic(&repo, &clock, nil)
	cidrs := []string{"127.0.0.1/32"}
	service := new_auth_service(Trusted_Proxy_Config{
		username_header = "X-authentik-username",
		trusted_proxy_cidrs = cidrs,
	}, &users)
	headers := []contracts.HTTP_Header{
		{name = "X-authentik-username", value = "alice"},
		{name = "Authorization", value = "Bearer app-jwt"},
	}
	ctx, ok, _ := resolve_trusted_proxy_auth(&service, Auth_Request{remote_addr = "127.0.0.1", headers = headers})
	testing.expect(t, ok)
	testing.expect_value(t, ctx.user_id, "alice")
	_, hub_ok, _ := resolve_auth(&service, Auth_Request{remote_addr = "127.0.0.1", headers = headers})
	testing.expect(t, !hub_ok)
	_, untrusted_ok, _ := resolve_trusted_proxy_auth(&service, Auth_Request{remote_addr = "10.0.0.1", headers = headers})
	testing.expect(t, !untrusted_ok)
	_, missing_ok, _ := resolve_trusted_proxy_auth(&service, Auth_Request{remote_addr = "127.0.0.1"})
	testing.expect(t, !missing_ok)
}

@(test)
test_extract_body_instance_id_basic :: proc(t: ^testing.T) {
	id := extract_body_instance_id(`{"agent_instance_id":"inst_123"}`)
	testing.expect_value(t, id, "inst_123")
}

@(test)
test_extract_body_instance_id_key_ordering :: proc(t: ^testing.T) {
	// Keys in reversed or arbitrary order
	id1 := extract_body_instance_id(`{"extra":"value","agent_instance_id":"inst_rev","first":"alpha"}`)
	testing.expect_value(t, id1, "inst_rev")

	id2 := extract_body_instance_id(`{"z":999,"y":"test","agent_instance_id":"inst_order"}`)
	testing.expect_value(t, id2, "inst_order")
}

@(test)
test_extract_body_instance_id_whitespace_tolerance :: proc(t: ^testing.T) {
	// Extra whitespace, newlines, and tabs
	body := "{\n\t\"foo\" :  123 ,\n\t\"agent_instance_id\"  :  \t\n\"inst_whitespace\"\n}"
	id := extract_body_instance_id(body)
	testing.expect_value(t, id, "inst_whitespace")
}

@(test)
test_extract_body_instance_id_nested_spoof_resistance :: proc(t: ^testing.T) {
	// 1. Escaped JSON string containing agent_instance_id in another field before the real key
	spoof1 := `{"payload":"{\"agent_instance_id\":\"inst_fake\"}","agent_instance_id":"inst_real"}`
	id1 := extract_body_instance_id(spoof1)
	testing.expect_value(t, id1, "inst_real")

	// 2. Nested object containing agent_instance_id
	spoof2 := `{"metadata":{"agent_instance_id":"inst_nested_fake"},"agent_instance_id":"inst_real_2"}`
	id2 := extract_body_instance_id(spoof2)
	testing.expect_value(t, id2, "inst_real_2")

	// 3. Nested only - no top-level agent_instance_id
	spoof3 := `{"metadata":{"agent_instance_id":"inst_nested_fake"}}`
	id3 := extract_body_instance_id(spoof3)
	testing.expect_value(t, id3, "")

	// 4. Nested in array
	spoof4 := `{"items":[{"agent_instance_id":"inst_fake_arr"}],"agent_instance_id":"inst_arr_real"}`
	id4 := extract_body_instance_id(spoof4)
	testing.expect_value(t, id4, "inst_arr_real")
}

@(test)
test_extract_body_instance_id_invalid_or_empty :: proc(t: ^testing.T) {
	testing.expect_value(t, extract_body_instance_id(""), "")
	testing.expect_value(t, extract_body_instance_id("   "), "")
	testing.expect_value(t, extract_body_instance_id("{"), "")
	testing.expect_value(t, extract_body_instance_id("null"), "")
	testing.expect_value(t, extract_body_instance_id(`not a json`), "")
	testing.expect_value(t, extract_body_instance_id(`[1, 2, 3]`), "")
	testing.expect_value(t, extract_body_instance_id(`{"other":"value"}`), "")
}

@(test)
test_extract_body_instance_id_tracking_allocator :: proc(t: ^testing.T) {
	// Zero memory leaks under Odin tracking allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	context.allocator = mem.tracking_allocator(&track)

	for _ in 0..<10 {
		id := extract_body_instance_id(`{"payload":"{\"agent_instance_id\":\"inst_fake\"}","agent_instance_id":"inst_real"}`)
		testing.expect_value(t, id, "inst_real")
	}

	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

@(private = "file")
Live_Auth_Test :: struct { token: domain.User_API_Token, disabled: bool, writes: int }
@(test)
test_live_user_authorization_rechecks_identity_expiry_revocation_without_writes :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    f := Live_Auth_Test{token = {token_id = "utok_a", owner_user_id = "alice", expires_at = "2999-01-01T00:00:00Z"}}
    repo := iface.User_Repository{ctx = &f,
        get_by_id = proc(ctx: rawptr, id: domain.User_ID) -> (domain.User, bool, domain.Domain_Error) {
            f := (^Live_Auth_Test)(ctx)
            return domain.User{user_id = id, status = .Disabled if f.disabled else .Active}, id == "alice", {}
        },
        get_token_by_id = proc(ctx: rawptr, id: string) -> (domain.User_API_Token, bool, domain.Domain_Error) {
            f := (^Live_Auth_Test)(ctx)
            return f.token, id == f.token.token_id, {}
        },
        save_token = proc(ctx: rawptr, token: domain.User_API_Token) -> (domain.User_API_Token, bool, domain.Domain_Error) {
            (^Live_Auth_Test)(ctx).writes += 1
            return token, true, {}
        }}
    clock := platform.real_clock()
    users := user_service.new_user_service_basic(&repo, &clock, nil)
    service := new_auth_service_with_tokens({}, &users, &repo, &clock, nil)
    auth := contracts.Auth_Context{kind = .User_Token, user_id = "alice", user_token_id = "utok_a"}
    testing.expect(t, live_user_authorized(&service, auth))
    f.token.revoked_at = "2026-01-01T00:00:00Z"
    testing.expect(t, !live_user_authorized(&service, auth))
    f.token.revoked_at = ""
    f.token.expires_at = "2000-01-01T00:00:00Z"
    testing.expect(t, !live_user_authorized(&service, auth))
    f.token.expires_at = ""
    f.token.owner_user_id = "foreign"
    testing.expect(t, !live_user_authorized(&service, auth))
    f.token.owner_user_id = "alice"
    auth.user_token_id = ""
    testing.expect(t, !live_user_authorized(&service, auth))
    auth.kind = .Trusted_Proxy
    testing.expect(t, live_user_authorized(&service, auth))
    f.disabled = true
    testing.expect(t, !live_user_authorized(&service, auth))
    testing.expect_value(t, f.writes, 0)
}
