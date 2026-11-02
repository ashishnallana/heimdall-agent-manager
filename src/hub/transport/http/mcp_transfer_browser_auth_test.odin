package http

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import auth_service "odin_test:hub/service/auth"
import mcp "odin_test:hub/service/mcp"
import user_service "odin_test:hub/service/user"
import vd "odin_test:hub/service/vault_directory"

// Browser executor auth (§5.2) refusal paths: a Hub session alone is not enough —
// mutations need the same Origin and every request needs an approved-device v2
// proof; no session at all, or a foreign bearer, is 401. None of these reach the
// transfer store (the service here has no repository).
@(test)
test_transfer_browser_auth_requires_session_origin_and_device_proof :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	user_repo := iface.User_Repository{get_by_id = proc(ctx: rawptr, id: domain.User_ID) -> (domain.User, bool, domain.Domain_Error) {
		return {user_id = id, name = string(id), status = .Active}, true, {}
	}}
	clock := platform.real_clock()
	ids := http_test_id_generator()
	users := user_service.new_user_service_basic(&user_repo, &clock, &ids)
	auth := auth_service.new_auth_service(auth_service.Auth_Config{}, &users)
	defer auth_service.oidc_free(&auth)
	session := http_test_login(t, &auth, "user_a")
	vrepo := iface.Vault_Directory_Repository{}
	directory := vd.new_service(&vrepo, &clock)
	defer vd.service_free(&directory)
	delegation := MCP_Delegation_Handlers{auth = &auth, directory = &directory, origin = "https://hub.example"}
	svc := mcp.Transfer_Service{}
	h := MCP_Transfer_Handlers{svc = &svc, delegation = &delegation}
	base :: MCP_TRANSFERS_PATH + "/xfr_a"
	with :: proc(hs: []contracts.HTTP_Header, extra: ..contracts.HTTP_Header) -> []contracts.HTTP_Header {
		out := make([dynamic]contracts.HTTP_Header, context.temp_allocator)
		append(&out, ..hs); append(&out, ..extra)
		return out[:]
	}

	// No credentials at all -> 401.
	r := mcp_transfer_handler(&h, Request{method = "GET", path = base})
	testing.expect_value(t, r.status, 401)
	testing.expect(t, strings.contains(r.body, "unauthenticated"))
	// A non-transfer bearer is never a browser session -> 401.
	r = mcp_transfer_handler(&h, Request{method = "GET", path = base, headers = with(session, {"Authorization", "Bearer mcp_at_x"})})
	testing.expect_value(t, r.status, 401)
	// Session, cross-origin mutation -> 403 before any proof is considered.
	r = mcp_transfer_handler(&h, Request{method = "PATCH", path = base + "/ciphertext", body = "x", headers = with(session, {"Origin", "https://evil.example"}, {"Upload-Offset", "0"})})
	testing.expect_value(t, r.status, 403)
	testing.expect(t, strings.contains(r.body, "origin_required"))
	// Session + same origin but no approved-device request proof -> 401.
	r = mcp_transfer_handler(&h, Request{method = "GET", path = base, headers = session})
	testing.expect_value(t, r.status, 401)
	testing.expect(t, strings.contains(r.body, "device_proof_required"))
	r = mcp_transfer_handler(&h, Request{method = "DELETE", path = base, headers = with(session, {"Origin", "https://hub.example"})})
	testing.expect_value(t, r.status, 401)
	testing.expect_value(t, sync_in_flight(&svc), i64(0))
}

@(private = "file")
sync_in_flight :: proc(s: ^mcp.Transfer_Service) -> i64 { return s.data_path_in_flight }
