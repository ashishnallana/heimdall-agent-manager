package http

import "core:crypto/ecdsa"
import "core:crypto/sha2"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import mcp "odin_test:hub/service/mcp"
import vault "odin_test:lib/vault"

// §12.6 data path over the real handler + SQLite. The test executor seals with a
// synthetic key in TEST code; the handler and service never hold one.

@(private = "file")
Xh :: struct {
	conn: sqlite.Conn,
	impl: sqlite.Transfer_Repo_SQLite,
	repo: iface.Transfer_Repository,
	svc:  mcp.Transfer_Service,
	h:    MCP_Transfer_Handlers,
	dir:  vault.Verified_Directory,
	priv: ecdsa.Private_Key,
	key:  [32]byte,
	path: string,
	live: bool,
}

@(private = "file")
xh_dir :: proc(user: rawptr, owner, grant_id: string) -> (^vault.Verified_Directory, bool) {
	return &(^Xh)(user).dir, owner == "user_a"
}
@(private = "file")
xh_live :: proc(ctx: rawptr, x: domain.Mcp_Transfer) -> bool { return (^Xh)(ctx).live }

@(private = "file")
xh_open :: proc(t: ^testing.T, f: ^Xh) -> bool {
	f.path = fmt.aprintf("%s/.cache/heimdall-tests/xfr_http_%d.db", os.get_env("HOME", context.temp_allocator), os.get_pid())
	os.remove(f.path)
	ok: bool
	f.conn, ok, _ = sqlite.open(f.path)
	if !testing.expect(t, ok) do return false
	mig, _ := sqlite.run_migrations(&f.conn)
	if !testing.expect(t, mig) do return false
	f.repo = sqlite.new_transfer_repository(&f.impl, &f.conn)
	f.svc = mcp.Transfer_Service{repo = &f.repo, directory = xh_dir, directory_ctx = f}
	f.live = true
	f.h = MCP_Transfer_Handlers{svc = &f.svc, grant_live = xh_live, grant_ctx = f}
	f.dir.vault_id, _ = vault.vault_id_from_hex("0123456789abcdef")
	f.dir.current_epoch = 3
	f.dir.trusted = make(map[string]vault.Verified_Directory_Device)
	testing.expect(t, vault.p256_private_key_generate(&f.priv))
	raw: [vault.P256_PUBLIC_KEY_BYTES]byte
	ecdsa.private_key_public_bytes(&f.priv, raw[:])
	f.dir.trusted["dev_a"] = {id = "dev_a", kind = "browser", sign_alg = vault.SIGN_ALG_ECDSA_P256_SHA256, sign_public_key = vault.hex_encode_lower(raw[:])}
	for i in 0 ..< 32 do f.key[i] = byte(i + 9)
	return true
}

@(private = "file")
xh_close :: proc(f: ^Xh) {
	mcp.transfer_limits_destroy(&f.svc)
	ecdsa.private_key_clear(&f.priv)
	sqlite.close(&f.conn)
	os.remove(f.path)
	delete(f.dir.trusted)
}

@(private = "file")
call :: proc(f: ^Xh, method, path, token, body: string, extra: ..contracts.HTTP_Header) -> Response {
	hs := make([dynamic]contracts.HTTP_Header, context.temp_allocator)
	if token != "" do append(&hs, contracts.HTTP_Header{"Authorization", strings.concatenate({"Bearer ", token}, context.temp_allocator)})
	for e in extra do append(&hs, e)
	q := ""
	p := path
	if i := strings.index_byte(path, '?'); i >= 0 do p, q = path[:i], path[i + 1:]
	return mcp_transfer_handler(&f.h, Request{method = method, path = p, query = q, body = body, headers = hs[:]})
}

@(private = "file")
hdr :: proc(r: Response, name: string) -> string { return header_value(r.headers, name) }

@(private = "file")
sha :: proc(s: string) -> string {
	d: [32]byte
	c: sha2.Context_256
	sha2.init_256(&c); sha2.update(&c, transmute([]byte)s); sha2.final(&c, d[:])
	return vault.hex_encode_lower(d[:], context.temp_allocator)
}

@(test)
test_transfer_http_data_path :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f: Xh
	if !xh_open(t, &f) do return
	defer xh_close(&f)
	who := mcp.Transfer_Caller{owner = "user_a", client_id = "c", grant_id = "g", family_id = "fam"}
	x, token, bf := mcp.transfer_upload_begin(&f.svc, who, {request_id = "r", request_digest = "d", kind = "html-bundle", content_type = "application/zip"})
	testing.expect_value(t, bf.reason, "")
	base := strings.concatenate({MCP_TRANSFERS_PATH, "/", x.transfer_id}, context.temp_allocator)
	ct := strings.concatenate({base, "/ciphertext"}, context.temp_allocator)

	pt := make([]byte, 1_800_000) // token > 2 MiB: downloads span several 1 MiB windows
	for i in 0 ..< len(pt) do pt[i] = byte(i * 13)
	tok, _ := vault.seal_with_key(pt, f.key[:], f.dir.vault_id, 3)

	// Auth: no bearer, OAuth-style bearer, ?t= query, other transfer id.
	testing.expect_value(t, call(&f, "GET", base, "", "").status, 401)
	testing.expect_value(t, call(&f, "GET", base, "mcp_at_xyz", "").status, 401)
	testing.expect_value(t, call(&f, "GET", strings.concatenate({base, "?t=", token}), "", "").status, 400)
	testing.expect_value(t, call(&f, "GET", strings.concatenate({MCP_TRANSFERS_PATH, "/xfr_other"}), token, "").status, 404)
	d := call(&f, "GET", base, token, "")
	testing.expect_value(t, d.status, 200)
	testing.expect(t, strings.contains(d.body, `"state":"receiving"`) && strings.contains(d.body, `"current_epoch":3`))
	testing.expect_value(t, hdr(d, "Cache-Control"), "no-store")

	// Global overload: semaphore full -> 503 + Retry-After, nothing written.
	f.svc.data_path_max = 1
	testing.expect(t, mcp.transfer_data_path_acquire(&f.svc))
	busy := call(&f, "PATCH", ct, token, tok[:100], contracts.HTTP_Header{"Upload-Offset", "0"})
	testing.expect_value(t, busy.status, 503)
	testing.expect_value(t, hdr(busy, "Retry-After"), "2")
	testing.expect_value(t, sqlite.debug_query_text(&f.conn, "SELECT COUNT(*) FROM mcp_transfer_chunks;"), "0")
	mcp.transfer_data_path_release(&f.svc)
	f.svc.data_path_max = 0

	// PATCH resume with HEAD probes; wrong offset -> 409 + current offset.
	r1 := call(&f, "PATCH", ct, token, tok[:1000], contracts.HTTP_Header{"Upload-Offset", "0"})
	testing.expect_value(t, r1.status, 200)
	testing.expect_value(t, hdr(call(&f, "HEAD", ct, token, ""), "Upload-Offset"), "1000")
	r2 := call(&f, "PATCH", ct, token, tok[:1000], contracts.HTTP_Header{"Upload-Offset", "0"})
	testing.expect_value(t, r2.status, 409)
	testing.expect_value(t, hdr(r2, "Upload-Offset"), "1000")
	testing.expect_value(t, call(&f, "PATCH", ct, token, tok[1000:], contracts.HTTP_Header{"Upload-Offset", "abc"}).status, 400)
	testing.expect_value(t, call(&f, "PUT", ct, token, tok).status, 409) // PUT only at offset 0
	testing.expect_value(t, call(&f, "PATCH", ct, token, tok[1000:], contracts.HTTP_Header{"Upload-Offset", "1000"}).status, 200)

	// Seal with a signed receipt through the JSON route.
	name, _ := vault.seal_with_key(transmute([]byte)string("site.zip"), f.key[:], f.dir.vault_id, 3)
	att, _ := vault.seal_with_key(transmute([]byte)string(`{"v":1}`), f.key[:], f.dir.vault_id, 3)
	r := vault.Transfer_Seal_Receipt{owner_user_id = "user_a", vault_id = "0123456789abcdef", epoch = 3, transfer_id = x.transfer_id, artifact_id = x.artifact_id,
		kind = "html-bundle", content_type = "application/zip", ciphertext_bytes = i64(len(tok)), ciphertext_sha256 = sha(tok),
		name_token_sha256 = sha(name), description_token_sha256 = sha(""), attestation_token_sha256 = sha(att), device_id = "dev_a",
		issued_ms = mcp_test_now_ms()}
	st, _ := vault.transfer_seal_statement(r)
	sig, _ := vault.sign_p256(&f.priv, transmute([]byte)st)
	sj, _ := vault.signature_object(&sig)
	body, _ := json.marshal(struct {receipt, signature, device_id, name_token, description_token, attestation_token: string}{st, sj, "dev_a", name, "", att})
	testing.expect_value(t, call(&f, "POST", strings.concatenate({base, "/seal"}), token, strings.repeat("x", TRANSFER_JSON_MAX_BYTES + 1)).status, 413)
	sres := call(&f, "POST", strings.concatenate({base, "/seal"}), token, string(body))
	testing.expect_value(t, sres.status, 200)
	testing.expect(t, strings.contains(sres.body, `"state":"sealed"`))
	_, cf := mcp.transfer_commit(&f.svc, who, x.transfer_id, {})
	testing.expect_value(t, cf.reason, "")

	// Download: full GET + Range, headers, max_fetches.
	dx, dtoken, df := mcp.transfer_download_begin(&f.svc, who, "rd", "d", x.artifact_id)
	testing.expect_value(t, df.reason, "")
	dct := strings.concatenate({MCP_TRANSFERS_PATH, "/", dx.transfer_id, "/ciphertext"}, context.temp_allocator)
	// A GET never carries more than one 1 MiB window (§7): the first answer is a
	// 206 for [0, 1 MiB) and the client continues with Range until the end. Only
	// the pass starting at offset 0 counts against max_fetches.
	g := call(&f, "GET", dct, dtoken, "")
	testing.expect_value(t, g.status, 206)
	testing.expect_value(t, len(g.body), int(TRANSFER_GET_WINDOW_BYTES))
	testing.expect_value(t, hdr(g, "Content-Range"), fmt.tprintf("bytes 0-%d/%d", TRANSFER_GET_WINDOW_BYTES - 1, len(tok)))
	got := strings.builder_make(context.temp_allocator)
	strings.write_string(&got, g.body)
	windows := 1
	for strings.builder_len(got) < len(tok) {
		w := call(&f, "GET", dct, dtoken, "", contracts.HTTP_Header{"Range", fmt.tprintf("bytes=%d-", strings.builder_len(got))})
		if !testing.expect_value(t, w.status, 206) do break
		if !testing.expect(t, len(w.body) > 0 && i64(len(w.body)) <= TRANSFER_GET_WINDOW_BYTES) do break
		strings.write_string(&got, w.body)
		windows += 1
	}
	testing.expect(t, strings.to_string(got) == tok, "windowed bytes are the stored token")
	testing.expect_value(t, windows, (len(tok) + int(TRANSFER_GET_WINDOW_BYTES) - 1) / int(TRANSFER_GET_WINDOW_BYTES))
	counted, _, _ := f.repo.get(f.repo.ctx, dx.transfer_id)
	testing.expect_value(t, counted.fetches, i64(1)) // one full pass = one fetch
	testing.expect_value(t, hdr(g, "Content-Disposition"), "attachment")
	testing.expect_value(t, hdr(g, "X-Content-Type-Options"), "nosniff")
	testing.expect_value(t, hdr(g, "Referrer-Policy"), "no-referrer")
	testing.expect(t, strings.has_prefix(hdr(g, "Repr-Digest"), "sha-256=:"))
	part := call(&f, "GET", dct, dtoken, "", contracts.HTTP_Header{"Range", "bytes=10-19"})
	testing.expect_value(t, part.status, 206)
	testing.expect(t, part.body == tok[10:20])
	testing.expect_value(t, call(&f, "GET", dct, dtoken, "", contracts.HTTP_Header{"Range", "bytes=0-1,5-6"}).status, 416)
	testing.expect_value(t, call(&f, "PATCH", dct, dtoken, "x", contracts.HTTP_Header{"Upload-Offset", "0"}).status, 405)
	for _ in 0 ..< contracts.ARTIFACT_TRANSFER_MAX_FETCHES - 1 do testing.expect_value(t, call(&f, "GET", dct, dtoken, "").status, 206)
	testing.expect_value(t, call(&f, "GET", dct, dtoken, "").status, 429)

	// Revoked grant -> 401 and the transfer is failed.
	f.live = false
	testing.expect_value(t, call(&f, "GET", dct, dtoken, "").status, 401)
	f.live = true
	testing.expect_value(t, call(&f, "GET", strings.concatenate({MCP_TRANSFERS_PATH, "/", dx.transfer_id}), dtoken, "").status, 200)
	after, _, _ := f.repo.get(f.repo.ctx, dx.transfer_id)
	testing.expect_value(t, after.state, domain.MCP_TRANSFER_FAILED)

	// Cancel is idempotent via DELETE.
	y, ytoken, _ := mcp.transfer_upload_begin(&f.svc, who, {request_id = "r2", request_digest = "d", kind = "file", content_type = "application/octet-stream"})
	ybase := strings.concatenate({MCP_TRANSFERS_PATH, "/", y.transfer_id}, context.temp_allocator)
	call(&f, "PATCH", strings.concatenate({ybase, "/ciphertext"}), ytoken, tok[:50], contracts.HTTP_Header{"Upload-Offset", "0"})
	testing.expect_value(t, call(&f, "DELETE", ybase, ytoken, "").status, 200)
	testing.expect_value(t, call(&f, "DELETE", ybase, ytoken, "").status, 200)
	testing.expect_value(t, sqlite.debug_query_text(&f.conn, "SELECT COUNT(*) FROM mcp_transfer_chunks;"), "0")
}

@(private = "file")
mcp_test_now_ms :: proc() -> i64 {
	return time.time_to_unix_nano(time.now()) / 1_000_000
}
