package http

import "core:crypto/ecdsa"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import auth_service "odin_test:hub/service/auth"
import mcp "odin_test:hub/service/mcp"
import user_service "odin_test:hub/service/user"
import vd "odin_test:hub/service/vault_directory"
import sqlite "odin_test:hub/repository/sqlite"
import vault "odin_test:lib/vault"

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

@(private = "file")
Browser_Pos :: struct {
	devices: [2]domain.Vault_Device,
	keys:    [2]ecdsa.Private_Key,
	dir:     vault.Verified_Directory,
	next:    int,
}

@(private = "file")
pos_devices :: proc(ctx: rawptr, user: string) -> ([]domain.Vault_Device, domain.Domain_Error) {
	p := (^Browser_Pos)(ctx)
	for d in p.devices {
		if d.user_id != user do continue
		out := make([]domain.Vault_Device, 1, context.temp_allocator)
		out[0] = d
		return out, {}
	}
	return nil, {}
}

@(private = "file")
pos_dir :: proc(user: rawptr, owner, grant_id: string) -> (^vault.Verified_Directory, bool) {
	return &(^Browser_Pos)(user).dir, owner == "user_a" || owner == "user_b"
}

// pos_sign adds an approved-device v2 request proof (as the browser executor does)
// for device i over the request's method, target and body.
@(private = "file")
pos_sign :: proc(p: ^Browser_Pos, i: int, req: Request, signed_body := "") -> Request {
	out := req
	p.next += 1
	ts := fmt.tprintf("%d", time.time_to_unix_nano(time.now()) / 1_000_000)
	nonce := fmt.tprintf("00000000-0000-4000-8000-%012d", p.next)
	msg := vd.request_v2_canonical(req.method, request_signature_target(req), p.devices[i].user_id, ts, nonce, signed_body, context.temp_allocator)
	sig, _ := vault.sign_p256(&p.keys[i], transmute([]byte)msg)
	text, _ := vault.signature_object(&sig, context.temp_allocator)
	hs := make([dynamic]contracts.HTTP_Header, context.temp_allocator)
	append(&hs, ..req.headers)
	append(&hs, contracts.HTTP_Header{"X-Heimdall-Device-Sig-Version", "2"}, contracts.HTTP_Header{"X-Heimdall-Device-Id", p.devices[i].device_id},
		contracts.HTTP_Header{"X-Heimdall-Device-Ts", ts}, contracts.HTTP_Header{"X-Heimdall-Device-Nonce", nonce}, contracts.HTTP_Header{"X-Heimdall-Device-Sig", text})
	out.headers = hs[:]
	return out
}

// Positive path (§5.2): session + same origin + approved-device v2 proof reaches the
// caller's own transfer; another owner's transfer is 404; a replayed proof or a body
// that differs from the signed one is 401. A streamed browser body is read (<= 1 MiB)
// before the proof is verified, and a larger one is refused.
@(test)
test_transfer_browser_auth_positive_path_and_owner_isolation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	user_repo := iface.User_Repository{get_by_id = proc(ctx: rawptr, id: domain.User_ID) -> (domain.User, bool, domain.Domain_Error) {
		return {user_id = id, name = string(id), status = .Active}, true, {}
	}}
	clock := platform.real_clock()
	ids := http_test_id_generator()
	users := user_service.new_user_service_basic(&user_repo, &clock, &ids)
	auth := auth_service.new_auth_service(auth_service.Auth_Config{}, &users)
	defer auth_service.oidc_free(&auth)
	session_a := http_test_login(t, &auth, "user_a")

	p: Browser_Pos
	for i in 0 ..< 2 {
		testing.expect(t, vault.p256_private_key_generate(&p.keys[i]))
		raw: [vault.P256_PUBLIC_KEY_BYTES]byte
		ecdsa.private_key_public_bytes(&p.keys[i], raw[:])
		pub := vault.hex_encode_lower(raw[:], context.temp_allocator)
		id, _ := vault.device_id_from_sign_pub(pub, context.temp_allocator)
		p.devices[i] = {device_id = id, user_id = i == 0 ? "user_a" : "user_b", kind = "browser", status = .Approved,
			sign_alg = vault.SIGN_ALG_ECDSA_P256_SHA256, sign_public_key = pub}
	}
	defer for i in 0 ..< 2 do ecdsa.private_key_clear(&p.keys[i])
	vrepo := iface.Vault_Directory_Repository{ctx = &p, list_devices = pos_devices}
	directory := vd.new_service(&vrepo, &clock)
	defer vd.service_free(&directory)
	delegation := MCP_Delegation_Handlers{auth = &auth, directory = &directory, origin = "https://hub.example"}

	path := fmt.aprintf("%s/.cache/heimdall-tests/xfr_browser_%d.db", os.get_env("HOME", context.temp_allocator), os.get_pid())
	os.remove(path)
	defer os.remove(path)
	conn, ok, _ := sqlite.open(path)
	if !testing.expect(t, ok) do return
	defer sqlite.close(&conn)
	mig, _ := sqlite.run_migrations(&conn)
	if !testing.expect(t, mig) do return
	impl: sqlite.Transfer_Repo_SQLite
	repo := sqlite.new_transfer_repository(&impl, &conn)
	p.dir.vault_id, _ = vault.vault_id_from_hex("0123456789abcdef")
	p.dir.current_epoch = 3
	svc := mcp.Transfer_Service{repo = &repo, directory = pos_dir, directory_ctx = &p}
	defer mcp.transfer_limits_destroy(&svc)
	h := MCP_Transfer_Handlers{svc = &svc, delegation = &delegation}
	begin := mcp.Upload_Begin_Input{request_id = "r", request_digest = "d", kind = "file", content_type = "application/octet-stream"}
	xa, _, fa := mcp.transfer_upload_begin(&svc, {owner = "user_a", client_id = "c", grant_id = "ga", family_id = "fa"}, begin)
	xb, _, fb := mcp.transfer_upload_begin(&svc, {owner = "user_b", client_id = "c", grant_id = "gb", family_id = "fb"}, begin)
	testing.expect_value(t, fa.reason, "")
	testing.expect_value(t, fb.reason, "")
	base_a := fmt.tprintf("%s/%s", MCP_TRANSFERS_PATH, xa.transfer_id)
	ct_a := fmt.tprintf("%s/ciphertext", base_a)
	same_origin := contracts.HTTP_Header{"Origin", "https://hub.example"}
	with :: proc(hs: []contracts.HTTP_Header, extra: ..contracts.HTTP_Header) -> []contracts.HTTP_Header {
		out := make([dynamic]contracts.HTTP_Header, context.temp_allocator)
		append(&out, ..hs); append(&out, ..extra)
		return out[:]
	}

	// Signed GET of the caller's own descriptor -> 200; the same proof again -> 401.
	g := pos_sign(&p, 0, Request{method = "GET", path = base_a, headers = session_a})
	r := mcp_transfer_handler(&h, g)
	testing.expectf(t, r.status == 200, "own descriptor: %d %s", r.status, r.body)
	testing.expect(t, strings.contains(r.body, xa.transfer_id))
	testing.expect_value(t, mcp_transfer_handler(&h, g).status, 401)
	// Another owner's transfer, with a valid proof -> 404 (no existence oracle).
	r = mcp_transfer_handler(&h, pos_sign(&p, 0, Request{method = "GET", path = fmt.tprintf("%s/%s", MCP_TRANSFERS_PATH, xb.transfer_id), headers = session_a}))
	testing.expect_value(t, r.status, 404)
	// user_b's device cannot sign for user_a's session.
	r = mcp_transfer_handler(&h, pos_sign(&p, 1, Request{method = "GET", path = base_a, headers = session_a}))
	testing.expect_value(t, r.status, 401)

	// Same-origin signed PATCH (buffered body) -> 200.
	chunk := strings.repeat("A", 1000, context.temp_allocator)
	r = mcp_transfer_handler(&h, pos_sign(&p, 0, Request{method = "PATCH", path = ct_a, body = chunk, headers = with(session_a, same_origin, {"Upload-Offset", "0"})}, chunk))
	testing.expectf(t, r.status == 200, "signed PATCH: %d %s", r.status, r.body)
	// Streamed body (as the server hands it): read, then verified against the proof.
	stream := body_stream_from_bytes(transmute([]byte)chunk)
	r = mcp_transfer_handler(&h, pos_sign(&p, 0, Request{method = "PATCH", path = ct_a, body_stream = &stream, headers = with(session_a, same_origin, {"Upload-Offset", "1000"})}, chunk))
	testing.expectf(t, r.status == 200, "signed streamed PATCH: %d %s", r.status, r.body)
	x2, _, _ := repo.get(repo.ctx, xa.transfer_id)
	testing.expect_value(t, x2.received_bytes, i64(2000))
	// Body differs from the signed one -> 401, nothing appended.
	r = mcp_transfer_handler(&h, pos_sign(&p, 0, Request{method = "PATCH", path = ct_a, body = "tampered", headers = with(session_a, same_origin, {"Upload-Offset", "2000"})}, chunk))
	testing.expect_value(t, r.status, 401)
	// A streamed browser body above one window is refused before it is read.
	big := body_stream_from_bytes(make([]byte, contracts.ARTIFACT_TRANSFER_STORE_CHUNK_BYTES + 1, context.temp_allocator))
	r = mcp_transfer_handler(&h, pos_sign(&p, 0, Request{method = "PATCH", path = ct_a, body_stream = &big, headers = with(session_a, same_origin, {"Upload-Offset", "2000"})}))
	testing.expect_value(t, r.status, 413)
	testing.expect(t, strings.contains(r.body, "browser_chunk_size"))
	x3, _, _ := repo.get(repo.ctx, xa.transfer_id)
	testing.expect_value(t, x3.received_bytes, i64(2000))
	testing.expect_value(t, svc.data_path_in_flight, i64(0))

	// Over the real server: session + origin + proof headers, but user_b's transfer.
	// Ownership is decided before the body is read: 404 although no body byte is
	// ever sent and the socket stays open.
	foreign_head := fmt.tprintf("PATCH %s/%s/ciphertext HTTP/1.1\r\nHost: hub.example\r\nCookie: %s\r\nOrigin: https://hub.example\r\nX-Heimdall-Device-Id: %s\r\nX-Heimdall-Device-Sig: x\r\nUpload-Offset: 0\r\nContent-Length: 1000\r\n\r\n",
		MCP_TRANSFERS_PATH, xb.transfer_id, header_value(session_a, "Cookie"), p.devices[0].device_id)
	fr, felapsed := transfer_loopback(t, &h, Pre_Body_Gate{body_idle_timeout = 5 * time.Second}, foreign_head, nil, 0)
	testing.expectf(t, strings.has_prefix(fr, "HTTP/1.1 404"), "foreign transfer before body: %q", fr[:min(len(fr), 200)])
	testing.expect(t, felapsed < 2 * time.Second)
	testing.expect_value(t, svc.data_path_in_flight, i64(0))
}

// Review finding (§7 admission): with NO Authorization header the browser branch
// must authenticate BEFORE it reads a body byte. A peer that declares a body, sends
// none and keeps the socket open gets 401 at once (well inside the idle timeout),
// and the data-path slot is back, so the next request is admitted. With a single
// slot, a held slot would make the second request 503.
@(test)
test_transfer_unauthenticated_browser_body_never_holds_a_slot :: proc(t: ^testing.T) {
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
	svc := mcp.Transfer_Service{data_path_max = 1}
	defer mcp.transfer_limits_destroy(&svc)
	h := MCP_Transfer_Handlers{svc = &svc, delegation = &delegation}
	gate := Pre_Body_Gate{body_idle_timeout = 5 * time.Second}

	// No credentials: 401 without the body ever being sent.
	noauth := "PATCH " + MCP_TRANSFERS_PATH + "/xfr_a/ciphertext HTTP/1.1\r\nHost: hub.example\r\nUpload-Offset: 0\r\nContent-Length: 1000\r\n\r\n"
	for _ in 0 ..< 3 {
		resp, elapsed := transfer_loopback(t, &h, gate, noauth, nil, 0)
		testing.expectf(t, strings.has_prefix(resp, "HTTP/1.1 401") && strings.contains(resp, "unauthenticated"), "no-auth PATCH: %q", resp[:min(len(resp), 200)])
		testing.expectf(t, elapsed < 2 * time.Second, "answered before any body byte (took %v)", elapsed)
		testing.expect_value(t, svc.data_path_in_flight, i64(0))
	}
	// A session but cross-origin, and a session without proof headers: both refused
	// before the body (no body byte is ever sent here either).
	cookie := header_value(session, "Cookie")
	cross := fmt.tprintf("PATCH %s/xfr_a/ciphertext HTTP/1.1\r\nHost: hub.example\r\nCookie: %s\r\nOrigin: https://evil.example\r\nUpload-Offset: 0\r\nContent-Length: 1000\r\n\r\n", MCP_TRANSFERS_PATH, cookie)
	resp, elapsed := transfer_loopback(t, &h, gate, cross, nil, 0)
	testing.expectf(t, strings.has_prefix(resp, "HTTP/1.1 403"), "cross-origin: %q", resp[:min(len(resp), 200)])
	testing.expect(t, elapsed < 2 * time.Second)
	noproof := fmt.tprintf("PATCH %s/xfr_a/ciphertext HTTP/1.1\r\nHost: hub.example\r\nCookie: %s\r\nOrigin: https://hub.example\r\nUpload-Offset: 0\r\nContent-Length: 1000\r\n\r\n", MCP_TRANSFERS_PATH, cookie)
	resp, elapsed = transfer_loopback(t, &h, gate, noproof, nil, 0)
	testing.expectf(t, strings.has_prefix(resp, "HTTP/1.1 401") && strings.contains(resp, "device_proof_required"), "no proof: %q", resp[:min(len(resp), 200)])
	testing.expect(t, elapsed < 2 * time.Second)
	testing.expect_value(t, svc.data_path_in_flight, i64(0))
}
