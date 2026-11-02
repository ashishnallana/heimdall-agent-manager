package mcp

import "core:crypto/ecdsa"
import "core:crypto/sha2"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import vault "odin_test:lib/vault"

// Hub-blind transfer tests (docs/plans/mcp-large-artifact-transfers.md §12.1/3/4/6).
// The TEST EXECUTOR below holds a synthetic key; the service under test never does.

TRANSFERS_SOURCE :: #load("transfers.odin", string)

@(test)
test_transfer_service_holds_no_key_structural :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	code := strings.builder_make(context.temp_allocator)
	for line in strings.split_lines(TRANSFERS_SOURCE, context.temp_allocator) {
		if strings.has_prefix(strings.trim_space(line), "//") do continue
		strings.write_string(&code, line); strings.write_byte(&code, '\n')
	}
	src := strings.to_string(code)
	for banned in ([]string{"hosted_with_access", "vault.open", "vault.seal", "Vault_Keyring", "keyring", "control_job", "enqueue", "aes.", "open_payload"}) {
		testing.expectf(t, !strings.contains(src, banned), "transfers.odin references %q", banned)
	}
}

@(private = "file")
@(thread_local) g_now: i64
@(private = "file")
test_now :: proc() -> i64 { return g_now }

@(private = "file")
Xfr_Fixture :: struct {
	conn:    sqlite.Conn,
	impl:    sqlite.Transfer_Repo_SQLite,
	repo:    iface.Transfer_Repository,
	svc:     Transfer_Service,
	dir:     vault.Verified_Directory,
	priv:    ecdsa.Private_Key,
	key:     [32]byte,
	path:    string,
}

@(private = "file")
fixture_dir :: proc(user: rawptr, owner: string) -> (^vault.Verified_Directory, bool) {
	f := (^Xfr_Fixture)(user)
	if owner != "user_a" && owner != "user_b" do return nil, false
	return &f.dir, true
}

@(private = "file")
fixture_open :: proc(t: ^testing.T, f: ^Xfr_Fixture, name: string) -> bool {
	g_now = 1_800_000_000_000
	f.path = fmt.aprintf("%s/.cache/heimdall-tests/xfr_%s_%d.db", os.get_env("HOME", context.temp_allocator), name, os.get_pid())
	os.remove(f.path)
	ok: bool
	f.conn, ok, _ = sqlite.open(f.path)
	if !testing.expect(t, ok, "db open") do return false
	mig, _ := sqlite.run_migrations(&f.conn)
	if !testing.expect(t, mig, "migrations") do return false
	f.repo = sqlite.new_transfer_repository(&f.impl, &f.conn)
	f.svc = Transfer_Service{repo = &f.repo, directory = fixture_dir, directory_ctx = f, now_ms = test_now}
	vid, _ := vault.vault_id_from_hex("0123456789abcdef")
	f.dir.vault_id = vid
	f.dir.current_epoch = 3
	f.dir.trusted = make(map[string]vault.Verified_Directory_Device)
	testing.expect(t, vault.p256_private_key_generate(&f.priv))
	raw: [vault.P256_PUBLIC_KEY_BYTES]byte
	ecdsa.private_key_public_bytes(&f.priv, raw[:])
	f.dir.trusted["dev_a"] = {id = "dev_a", kind = "bridge", sign_alg = vault.SIGN_ALG_ECDSA_P256_SHA256, sign_public_key = vault.hex_encode_lower(raw[:])}
	for i in 0 ..< 32 do f.key[i] = byte(i * 7 + 1)
	return true
}

@(private = "file")
fixture_close :: proc(f: ^Xfr_Fixture) {
	ecdsa.private_key_clear(&f.priv)
	sqlite.close(&f.conn)
	os.remove(f.path)
	delete(f.dir.trusted)
}

// test executor: seal under the synthetic epoch key (test code only).
@(private = "file")
exec_seal :: proc(f: ^Xfr_Fixture, pt: []byte, epoch: u32 = 3) -> string {
	tok, ok := vault.seal_with_key(pt, f.key[:], f.dir.vault_id, epoch, context.temp_allocator)
	assert(ok)
	return tok
}

@(private = "file")
hex_sha :: proc(s: string) -> string {
	d: [32]byte
	c: sha2.Context_256
	sha2.init_256(&c); sha2.update(&c, transmute([]byte)s); sha2.final(&c, d[:])
	return vault.hex_encode_lower(d[:], context.temp_allocator)
}

@(private = "file")
exec_seal_input :: proc(f: ^Xfr_Fixture, x: domain.Mcp_Transfer, token: string, device := "dev_a") -> Seal_Input {
	name := exec_seal(f, transmute([]byte)string("secret-name.zip"))
	desc := exec_seal(f, transmute([]byte)string("secret description"))
	att := exec_seal(f, transmute([]byte)string(`{"v":1}`))
	r := vault.Transfer_Seal_Receipt{owner_user_id = x.owner_user_id, vault_id = "0123456789abcdef", epoch = u32(x.epoch), transfer_id = x.transfer_id,
		artifact_id = x.artifact_id, kind = x.kind, content_type = x.content_type, ciphertext_bytes = i64(len(token)), ciphertext_sha256 = hex_sha(token),
		name_token_sha256 = hex_sha(name), description_token_sha256 = hex_sha(desc), attestation_token_sha256 = hex_sha(att), device_id = device, issued_ms = g_now}
	stmt, _ := vault.transfer_seal_statement(r, context.temp_allocator)
	sig, _ := vault.sign_p256(&f.priv, transmute([]byte)stmt)
	sj, _ := vault.signature_object(&sig, context.temp_allocator)
	return {receipt = stmt, signature = sj, device_id = device, name_token = name, description_token = desc, attestation_token = att}
}

@(private = "file")
query_text :: proc(f: ^Xfr_Fixture, q: string) -> string {
	return sqlite.debug_query_text(&f.conn, q)
}

@(private = "file")
WHO_A :: Transfer_Caller{owner = "user_a", client_id = "cli_a", grant_id = "grant_a", family_id = "fam_a"}
@(private = "file")
WHO_B :: Transfer_Caller{owner = "user_b", client_id = "cli_b", grant_id = "grant_b", family_id = "fam_b"}

@(private = "file")
upload :: proc(t: ^testing.T, f: ^Xfr_Fixture, who: Transfer_Caller, req: string, token: string) -> (domain.Mcp_Transfer, string) {
	x, bearer, bf := transfer_upload_begin(&f.svc, who, {request_id = req, request_digest = "d1", kind = "file", content_type = "application/octet-stream"})
	testing.expect_value(t, bf.reason, "")
	b := transmute([]byte)token
	off: i64 = 0
	for off < i64(len(b)) {
		end := min(off + contracts.ARTIFACT_TRANSFER_CHUNK_MAX_BYTES, i64(len(b)))
		cur, _ := transfer_authenticate(&f.svc, bearer, x.transfer_id)
		n, af := transfer_append(&f.svc, cur, off, b[off:end])
		testing.expect_value(t, af.reason, "")
		off = n
	}
	cur, _ := transfer_authenticate(&f.svc, bearer, x.transfer_id)
	return cur, bearer
}

// §12.2 (Hub side) + §12.6: a 15 MiB non-UTF-8 payload with plaintext markers goes
// through begin -> 3 PATCH-sized appends -> seal -> commit; the stored artifact is
// exactly the uploaded token; no marker, name or plaintext digest is in the DB; a
// download transfer serves it back in <= 1 MiB windows and the test executor opens it.
@(test)
test_transfer_hub_blind_15_mib_round_trip :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f: Xfr_Fixture
	if !fixture_open(t, &f, "roundtrip") do return
	defer fixture_close(&f)
	MARKER :: "PLAINTEXT-MARKER-7f3a"
	pt := make([]byte, contracts.ARTIFACT_MAX_CONTENT_BYTES)
	defer delete(pt)
	for i in 0 ..< len(pt) do pt[i] = byte((i * 131 + 17) ~ (i >> 9))
	pt[0] = 0xff
	for k in 0 ..< 8 do copy(pt[k * 1_000_000 + 5:], MARKER)
	token := exec_seal(&f, pt)
	testing.expect_value(t, len(token), 20_971_589)
	x, bearer := upload(t, &f, WHO_A, "req_1", token)
	testing.expect_value(t, x.received_bytes, i64(len(token)))
	chunks := query_text(&f, "SELECT COUNT(*)||':'||MAX(length(bytes)) FROM mcp_transfer_chunks;")
	testing.expect_value(t, chunks, "21:1048576") // PUT/PATCH land as <= 1 MiB rows

	// Commit before seal: retryable not_sealed, nothing created.
	_, nf := transfer_commit(&f.svc, WHO_A, x.transfer_id, {})
	testing.expect_value(t, nf.reason, "not_sealed")
	testing.expect(t, nf.retryable)

	sealed, sf := transfer_seal(&f.svc, x, exec_seal_input(&f, x, token))
	testing.expect_value(t, sf.reason, "")
	testing.expect_value(t, sealed.state, domain.MCP_TRANSFER_SEALED)
	// Duplicate seal with the identical receipt is idempotent.
	again, _ := transfer_authenticate(&f.svc, bearer, x.transfer_id)
	_, sf2 := transfer_seal(&f.svc, again, Seal_Input{receipt = again.seal_statement, signature = again.seal_signature})
	testing.expect_value(t, sf2.reason, "")

	done, cf := transfer_commit(&f.svc, WHO_A, x.transfer_id, {})
	testing.expect_value(t, cf.reason, "")
	testing.expect_value(t, done.state, domain.MCP_TRANSFER_COMMITTED)
	// Replayed commit returns the same committed transfer; no second artifact.
	_, cf2 := transfer_commit(&f.svc, WHO_A, x.transfer_id, {})
	testing.expect_value(t, cf2.reason, "")
	testing.expect_value(t, query_text(&f, "SELECT COUNT(*) FROM artifacts WHERE origin_kind='mcp_transfer';"), "1")
	testing.expect_value(t, query_text(&f, strings.concatenate({"SELECT length(content)||':'||(sha256='')||':'||(name LIKE 'vault:v2:%') FROM artifacts WHERE artifact_id='", x.artifact_id, "';"}, context.temp_allocator)), "20971589:1:1")
	testing.expect_value(t, query_text(&f, "SELECT COUNT(*) FROM mcp_transfer_chunks;"), "0")
	testing.expect_value(t, query_text(&f, "SELECT COUNT(*) FROM artifact_transfer_receipts;"), "1")
	// Plaintext marker / name / plaintext digest scan over every transfer table.
	pt_sha := hex_sha(string(pt))
	for needle in ([]string{MARKER, "secret-name", "secret description", pt_sha}) {
		q := strings.concatenate({"SELECT (SELECT COUNT(*) FROM artifacts WHERE instr(CAST(content AS BLOB),CAST('", needle, "' AS BLOB))>0 OR instr(name,'", needle, "')>0 OR instr(sha256,'", needle, "')>0)+(SELECT COUNT(*) FROM mcp_transfers WHERE instr(seal_statement||name_token||description_token||attestation_token||ciphertext_sha256,'", needle, "')>0)+(SELECT COUNT(*) FROM artifact_transfer_receipts WHERE instr(statement||attestation_token||ciphertext_sha256,'", needle, "')>0);"}, context.temp_allocator)
		testing.expectf(t, query_text(&f, q) == "0", "plaintext %q found in hub DB", needle[:min(len(needle), 16)])
	}

	// Download: bound to the stored ciphertext digest; windows reassemble byte-exactly.
	d, dbearer, df := transfer_download_begin(&f.svc, WHO_A, "req_dl", "dd", x.artifact_id)
	testing.expect_value(t, df.reason, "")
	testing.expect_value(t, d.ciphertext_sha256, hex_sha(token))
	cur, af := transfer_authenticate(&f.svc, dbearer, d.transfer_id)
	testing.expect_value(t, af.reason, "")
	testing.expect_value(t, transfer_fetch_begin(&f.svc, cur).reason, "")
	got := make([]byte, len(token))
	defer delete(got)
	window := make([]byte, contracts.ARTIFACT_TRANSFER_CHUNK_MAX_BYTES) // ask for more than allowed
	defer delete(window)
	off := 0
	for off < len(token) {
		n, rf := transfer_read_window(&f.svc, cur, i64(off), window)
		testing.expect_value(t, rf.reason, "")
		testing.expect(t, n <= contracts.ARTIFACT_TRANSFER_STORE_CHUNK_BYTES)
		if n == 0 do break
		copy(got[off:], window[:n])
		off += n
	}
	testing.expect(t, string(got) == token, "download is byte-exact ciphertext")
	_, _, payload, pres := vault.envelope_parse(string(got), context.temp_allocator)
	testing.expect_value(t, pres, vault.Open_Result.Ok)
	plain, pok := vault.open_payload_with_key(payload, f.key[:], f.dir.vault_id, 3, context.temp_allocator)
	testing.expect(t, pok && string(plain) == string(pt), "test executor opens byte-exact plaintext")

	// Open receipt: verified flag comes only from the signed statement.
	o := vault.Transfer_Open_Receipt{owner_user_id = "user_a", vault_id = "0123456789abcdef", epoch = 3, transfer_id = d.transfer_id, artifact_id = x.artifact_id,
		verified = false, ciphertext_bytes = d.ciphertext_bytes, ciphertext_sha256 = d.ciphertext_sha256, device_id = "dev_a", issued_ms = g_now}
	ostmt, _ := vault.transfer_open_statement(o, context.temp_allocator)
	osig, _ := vault.sign_p256(&f.priv, transmute([]byte)ostmt)
	osj, _ := vault.signature_object(&osig, context.temp_allocator)
	upgraded, _ := strings.replace(ostmt, "\nunverified\n", "\nverified\n", 1, context.temp_allocator)
	_, uf := transfer_opened(&f.svc, cur, upgraded, osj, "dev_a")
	testing.expect_value(t, uf.reason, "receipt_invalid") // Hub/attacker cannot upgrade
	del, of := transfer_opened(&f.svc, cur, ostmt, osj, "dev_a")
	testing.expect_value(t, of.reason, "")
	testing.expect_value(t, del.state, domain.MCP_TRANSFER_DELIVERED)
	testing.expect(t, !del.open_verified)
}

@(private = "file")
small_token :: proc(f: ^Xfr_Fixture, n := 1000, epoch: u32 = 3) -> string {
	pt := make([]byte, n, context.temp_allocator)
	for i in 0 ..< n do pt[i] = byte(i)
	return exec_seal(f, pt, epoch)
}

// §12.3/§12.4/§12.6: blind rejection, receipts, offsets, ownership, expiry, cancel,
// replay, quotas and the global semaphores.
@(test)
test_transfer_rejections_and_limits :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f: Xfr_Fixture
	if !fixture_open(t, &f, "limits") do return
	defer fixture_close(&f)
	tok := small_token(&f)

	// Malformed begin input.
	_, _, bk := transfer_upload_begin(&f.svc, WHO_A, {request_id = "r", kind = "exe", content_type = "x/y"})
	testing.expect_value(t, bk.reason, "invalid_kind")
	_, _, bz := transfer_upload_begin(&f.svc, WHO_A, {request_id = "r", kind = "html-bundle", content_type = "text/html"})
	testing.expect_value(t, bz.reason, "invalid_content_type")

	// Replay rotates the token; the old one stops working; changed digest -> conflict.
	x, t1, _ := transfer_upload_begin(&f.svc, WHO_A, {request_id = "r1", request_digest = "d", kind = "file", content_type = "application/octet-stream"})
	x2, t2, _ := transfer_upload_begin(&f.svc, WHO_A, {request_id = "r1", request_digest = "d", kind = "file", content_type = "application/octet-stream"})
	testing.expect_value(t, x2.transfer_id, x.transfer_id)
	testing.expect(t, t1 != t2)
	_, old := transfer_authenticate(&f.svc, t1, x.transfer_id)
	testing.expect_value(t, old.reason, "not_found")
	_, _, cd := transfer_upload_begin(&f.svc, WHO_A, {request_id = "r1", request_digest = "other", kind = "file", content_type = "application/octet-stream"})
	testing.expect_value(t, cd.reason, "conflict")
	_, bad := transfer_authenticate(&f.svc, "hxt_short", x.transfer_id)
	testing.expect_value(t, bad.reason, "unauthenticated")

	// Ownership isolation: B cannot address or commit A's transfer.
	_, ob := transfer_get_owned(&f.svc, "user_b", x.transfer_id)
	testing.expect_value(t, ob.reason, "not_found")
	_, oc := transfer_commit(&f.svc, WHO_B, x.transfer_id, {})
	testing.expect_value(t, oc.reason, "not_found")

	// Offsets: wrong offset -> conflict with current offset; overrun -> failed.
	cur, _ := transfer_authenticate(&f.svc, t2, x.transfer_id)
	b := transmute([]byte)tok
	n, _ := transfer_append(&f.svc, cur, 0, b[:100])
	testing.expect_value(t, n, i64(100))
	cur, _ = transfer_authenticate(&f.svc, t2, x.transfer_id)
	_, wo := transfer_append(&f.svc, cur, 0, b[:100])
	testing.expect_value(t, wo.reason, "offset_mismatch")
	testing.expect_value(t, wo.offset, i64(100))
	n, _ = transfer_append(&f.svc, cur, 100, b[100:])
	testing.expect_value(t, n, i64(len(b)))

	// Receipt checks: field mismatch, untrusted signer, digest mismatch -> receipt_invalid (transfer failed, staging wiped).
	cur, _ = transfer_authenticate(&f.svc, t2, x.transfer_id)
	in_ := exec_seal_input(&f, cur, tok)
	wrong := in_; wrong.device_id = "dev_x"
	_, rf := transfer_seal(&f.svc, cur, wrong)
	testing.expect_value(t, rf.reason, "receipt_invalid")
	testing.expect_value(t, query_text(&f, "SELECT COUNT(*) FROM mcp_transfer_chunks;"), "0")
	_, after := transfer_authenticate(&f.svc, t2, x.transfer_id)
	testing.expect_value(t, after.reason, "")

	// Blind ciphertext checks (fresh transfers).
	cases := []struct {data, want: string}{
		{strings.concatenate({tok, tok}, context.temp_allocator), "ciphertext_invalid"},     // two tokens
		{tok[:len(tok) - 2], "ciphertext_invalid"},                                          // truncated
		{small_token(&f, 1000, 2), "stale_epoch"},                                            // old epoch
		{strings.concatenate({"vault:v2:fedcba9876543210", tok[25:]}, context.temp_allocator), "ciphertext_invalid"}, // other vault
	}
	for c, i in cases {
		req := fmt.tprintf("blind_%d", i)
		y, bearer, _ := transfer_upload_begin(&f.svc, WHO_B, {request_id = req, request_digest = "d", kind = "file", content_type = "application/octet-stream"})
		yb, _ := transfer_authenticate(&f.svc, bearer, y.transfer_id)
		transfer_append(&f.svc, yb, 0, transmute([]byte)c.data)
		yb, _ = transfer_authenticate(&f.svc, bearer, y.transfer_id)
		_, cf := transfer_seal(&f.svc, yb, exec_seal_input(&f, yb, c.data))
		testing.expectf(t, cf.reason == c.want, "blind case %d: %s", i, cf.reason)
		transfer_cancel(&f.svc, yb)
	}

	// Overrun of the 15 MiB ciphertext bound is refused before writing.
	y, yt, _ := transfer_upload_begin(&f.svc, WHO_B, {request_id = "over", request_digest = "d", kind = "file", content_type = "application/octet-stream"})
	yb, _ := transfer_authenticate(&f.svc, yt, y.transfer_id)
	big := make([]byte, contracts.ARTIFACT_TRANSFER_CIPHERTEXT_MAX_BYTES + 1)
	defer delete(big)
	_, of := transfer_append(&f.svc, yb, 0, big)
	testing.expect_value(t, of.reason, "ciphertext_too_large")

	// Quota: at most 2 active uploads per owner.
	_, _, q1 := transfer_upload_begin(&f.svc, WHO_A, {request_id = "q1", request_digest = "d", kind = "file", content_type = "application/octet-stream"})
	testing.expect_value(t, q1.reason, "")
	_, _, q2 := transfer_upload_begin(&f.svc, WHO_A, {request_id = "q2", request_digest = "d", kind = "file", content_type = "application/octet-stream"})
	testing.expect_value(t, q2.reason, "")
	_, _, q3 := transfer_upload_begin(&f.svc, WHO_A, {request_id = "q3", request_digest = "d", kind = "file", content_type = "application/octet-stream"})
	testing.expect_value(t, q3.reason, "quota_exceeded")
	testing.expect(t, q3.retryable)

	// Global semaphores: full -> busy, nothing touched.
	f.svc.data_path_max = 1
	testing.expect(t, transfer_data_path_acquire(&f.svc))
	testing.expect(t, !transfer_data_path_acquire(&f.svc))
	transfer_data_path_release(&f.svc)
	testing.expect(t, transfer_data_path_acquire(&f.svc))
	transfer_data_path_release(&f.svc)

	// Expiry: idle TTL -> Gone; janitor wipes; terminal rows purged after 24 h.
	g_now += contracts.ARTIFACT_TRANSFER_IDLE_TTL_MS + 1
	expired, _ := transfer_janitor(&f.svc)
	testing.expect(t, expired >= 2)
	_, ef := transfer_authenticate(&f.svc, t2, x.transfer_id)
	testing.expect_value(t, ef.reason, "")
	g_now += contracts.ARTIFACT_TRANSFER_TERMINAL_KEEP_MS + 1
	_, purged := transfer_janitor(&f.svc)
	testing.expect(t, purged >= 1)
	testing.expect_value(t, query_text(&f, "SELECT COUNT(*) FROM mcp_transfers;"), "0")
}

// Commit re-checks against the CURRENT directory: an epoch rotation or a revoked
// sealer between seal and commit fails the commit and creates nothing.
@(test)
test_transfer_commit_rechecks_epoch_and_device :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f: Xfr_Fixture
	if !fixture_open(t, &f, "recheck") do return
	defer fixture_close(&f)
	saved := f.dir.trusted["dev_a"]
	for scenario in 0 ..< 3 {
		tok := small_token(&f)
		x, _ := upload(t, &f, WHO_A, fmt.tprintf("rc_%d", scenario), tok)
		_, sf := transfer_seal(&f.svc, x, exec_seal_input(&f, x, tok))
		testing.expect_value(t, sf.reason, "")
		want := ""
		switch scenario {
		case 0:
			f.dir.current_epoch = 4; want = "stale_epoch"
		case 1:
			delete_key(&f.dir.trusted, "dev_a"); want = "receipt_invalid"
		case 2:
			want = "busy"; f.svc.commit_max = 1; f.svc.commits_in_flight = 1
		}
		_, cf := transfer_commit(&f.svc, WHO_A, x.transfer_id, {})
		testing.expectf(t, cf.reason == want, "scenario %d: %s", scenario, cf.reason)
		f.dir.current_epoch = 3; f.svc.commits_in_flight = 0; f.svc.commit_max = 0; f.dir.trusted["dev_a"] = saved
		if scenario == 2 {
			_, ok2 := transfer_commit(&f.svc, WHO_A, x.transfer_id, {})
			testing.expect_value(t, ok2.reason, "") // busy is retryable and succeeds later
		} else {
			testing.expect_value(t, query_text(&f, fmt.tprintf("SELECT COUNT(*) FROM artifacts WHERE artifact_id='%s';", x.artifact_id)), "0")
		}
	}
}
