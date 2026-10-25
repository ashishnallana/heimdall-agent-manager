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

@(private = "file")
auth_test_service :: proc(repo: ^iface.User_Repository, users: ^user_service.User_Service, clock: ^platform.Clock) -> Auth_Service {
	users^ = user_service.new_user_service_basic(repo, clock, nil)
	return new_auth_service(Auth_Config{}, users, clock)
}

// Users authenticate only with an OIDC bearer or the Hub session cookie. A Hub
// user token (hut_) and identity headers from a proxy are never accepted.
@(test)
test_resolve_auth_session_cookie_and_removed_credentials :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	repo := iface.User_Repository{get_by_id = auth_test_get_user}
	clock := platform.real_clock()
	users: user_service.User_Service
	service := auth_test_service(&repo, &users, &clock)
	store := use_memory_sessions(&service)
	defer release_memory_sessions(&service, store)
	defer oidc_free(&service)

	raw, minted := mint_session(&service, "alice")
	testing.expect(t, minted)
	ctx, ok, _ := resolve_auth(&service, Auth_Request{headers = []contracts.HTTP_Header{session_cookie_request_header(raw)}})
	testing.expect(t, ok && ctx.kind == .Session && ctx.user_id == "alice" && ctx.session_id != "")

	// hut_ bearer: explicit 401 naming the removal.
	_, hut_ok, hut_err := resolve_auth(&service, Auth_Request{headers = []contracts.HTTP_Header{{"Authorization", "Bearer hut_legacy"}}})
	testing.expect(t, !hut_ok && hut_err.code == .Unauthenticated)
	testing.expect_value(t, hut_err.message, USER_TOKENS_REMOVED_MESSAGE)

	// No credential at all, or only proxy identity headers: 401.
	_, none_ok, none_err := resolve_auth(&service, Auth_Request{remote_addr = "127.0.0.1"})
	testing.expect(t, !none_ok && none_err.code == .Unauthenticated)
	_, proxy_ok, proxy_err := resolve_auth(&service, Auth_Request{remote_addr = "127.0.0.1", headers = []contracts.HTTP_Header{{"X-authentik-username", "alice"}}})
	testing.expect(t, !proxy_ok && proxy_err.code == .Unauthenticated, "proxy identity headers are ignored")

	// An invalid session cookie is a 401 (no fallthrough to any other identity).
	_, bad_ok, bad_err := resolve_auth(&service, Auth_Request{remote_addr = "127.0.0.1", headers = []contracts.HTTP_Header{
		{"Cookie", "__Host-heimdall_session=not-a-real-session-id-0123456789abcdef"},
		{"X-authentik-username", "alice"},
	}})
	testing.expect(t, !bad_ok && bad_err.code == .Unauthenticated)

	// Bridge credentials keep their explicit 403.
	_, bridge_ok, bridge_err := resolve_auth(&service, Auth_Request{headers = []contracts.HTTP_Header{{"Authorization", "Bearer hba_x"}}})
	testing.expect(t, !bridge_ok && bridge_err.code == .Forbidden)
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
Live_Auth_Test :: struct { disabled: bool }

// live_user_authorized: Session must still exist (logout deletes it); OIDC is
// bounded by its token expiry; the user must be active; other kinds never pass.
@(test)
test_live_user_authorization_rechecks_session_and_token_expiry :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f: Live_Auth_Test
	repo := iface.User_Repository{ctx = &f,
		get_by_id = proc(ctx: rawptr, id: domain.User_ID) -> (domain.User, bool, domain.Domain_Error) {
			f := (^Live_Auth_Test)(ctx)
			return domain.User{user_id = id, status = .Disabled if f.disabled else .Active}, id == "alice", {}
		}}
	clock := platform.real_clock()
	users: user_service.User_Service
	service := auth_test_service(&repo, &users, &clock)
	store := use_memory_sessions(&service)
	defer release_memory_sessions(&service, store)
	defer oidc_free(&service)
	raw, minted := mint_session(&service, "alice")
	testing.expect(t, minted)
	session, ok, _ := resolve_auth(&service, Auth_Request{headers = []contracts.HTTP_Header{session_cookie_request_header(raw)}})
	testing.expect(t, ok)
	testing.expect(t, live_user_authorized(&service, session))
	now, _ := now_unix_ms(&service)
	bearer := contracts.Auth_Context{kind = .OIDC, user_id = "alice", expires_ms = now + 60_000}
	testing.expect(t, live_user_authorized(&service, bearer))
	bearer.expires_ms = now - 1
	testing.expect(t, !live_user_authorized(&service, bearer))
	bearer.expires_ms = 0
	testing.expect(t, !live_user_authorized(&service, bearer), "an OIDC principal without an expiry never passes")
	testing.expect(t, !live_user_authorized(&service, contracts.Auth_Context{kind = .Instance_Token, user_id = "alice"}))
	f.disabled = true
	testing.expect(t, !live_user_authorized(&service, session))
	f.disabled = false
	_ = web_logout(&service, []contracts.HTTP_Header{session_cookie_request_header(raw)})
	testing.expect(t, !live_user_authorized(&service, session), "logout ends the session")
}
