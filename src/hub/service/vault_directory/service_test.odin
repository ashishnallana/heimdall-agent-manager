#+private file
// Vault directory service: request signing, statement checks, CAS and revoke rules.
// Hermetic: in-memory SQLite per test, injected clock, fixed key scalars.
package vault_directory

import "core:crypto/ecdsa"
import "core:strconv"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import vault "odin_test:lib/vault"

USER  :: "usr_vault_svc"
OTHER :: "usr_vault_other"
T0    :: "2026-10-19T10:00:00Z"
T0_MS :: i64(1_792_404_000_000)

Fixture :: struct {
	conn:  sqlite.Conn,
	impl:  sqlite.Vault_Directory_Repo_SQLite,
	repo:  iface.Vault_Directory_Repository,
	now:   string,
	clock: platform.Clock,
	svc:   Service,
}

clock_proc :: proc(ctx: rawptr) -> string { return (^string)(ctx)^ }

fixture :: proc(t: ^testing.T) -> ^Fixture {
	f := new(Fixture, context.temp_allocator)
	conn, ok, _ := sqlite.open(":memory:")
	testing.expect(t, ok)
	f.conn = conn
	mig_ok, _ := sqlite.run_migrations(&f.conn)
	testing.expect(t, mig_ok)
	f.repo = sqlite.new_vault_directory_repository(&f.impl, &f.conn)
	f.now = T0
	f.clock = platform.Clock{ctx = rawptr(&f.now), now = clock_proc}
	f.svc = new_service(&f.repo, &f.clock)
	return f
}

fixture_close :: proc(f: ^Fixture) {
	service_free(&f.svc)
	sqlite.close(&f.conn)
}

Dev :: struct {
	priv:     ecdsa.Private_Key,
	sign_pub: string,
	ecdh_pub: string,
	id:       string,
	kind:     string,
}

pub_hex :: proc(priv: ^ecdsa.Private_Key) -> string {
	pub: ecdsa.Public_Key
	ecdsa.public_key_set_priv(&pub, priv)
	raw: [65]byte
	ecdsa.public_key_bytes(&pub, raw[:])
	return vault.hex_encode_lower(raw[:], context.temp_allocator)
}

make_dev :: proc(seed: byte, kind := "browser") -> Dev {
	d := Dev{kind = kind}
	scalar: [32]byte
	scalar[31] = seed
	scalar[0] = 0x11
	_ = ecdsa.private_key_set_bytes(&d.priv, .SECP256R1, scalar[:])
	d.sign_pub = pub_hex(&d.priv)
	if kind != "bridge" {
		other: ecdsa.Private_Key
		scalar[1] = 0x22
		_ = ecdsa.private_key_set_bytes(&other, .SECP256R1, scalar[:])
		d.ecdh_pub = pub_hex(&other)
	}
	d.id, _ = vault.device_id_from_sign_pub(d.sign_pub, context.temp_allocator)
	return d
}

sign :: proc(d: ^Dev, msg: string) -> string {
	sig, _ := vault.sign_p256(&d.priv, transmute([]byte)msg)
	text, _ := vault.signature_object(&sig, context.temp_allocator)
	return text
}

LABEL_B64 :: "TGFwdG9w" // "Laptop"
COMMIT :: "aabe8c0490f1e4d6754740170728a4ef286c80c1c2d180db826f956c3d9bd402"

itoa :: proc(v: i64) -> string {
	buf: [24]byte
	return strings.clone(strconv.write_int(buf[:], v, 10), context.temp_allocator)
}

statement :: proc(type: string, issuer: ^Dev, subject: ^Dev, version, epoch: string, user := USER) -> string {
	st := vault.Statement{type = type, user_id = user, directory_version = version, issuer_device_id = issuer.id, issued_at_ms = "1760868000000", epoch = epoch}
	if subject != nil {
		st.subject_device_id = subject.id
		st.subject_kind = subject.kind
		st.subject_sign_pub = subject.sign_pub
		st.subject_ecdh_pub = subject.ecdh_pub
		st.subject_sign_alg = vault.SIGN_ALG_ECDSA_P256_SHA256
		st.subject_wrap_alg = "" if subject.kind == "bridge" else vault.WRAP_ALG_ECDH_P256_HKDF_AES
		st.subject_label_b64 = LABEL_B64
	}
	if type == "epoch" do st.epoch_commit = COMMIT
	text, ok := vault.statement_canonical(&st, context.temp_allocator)
	assert(ok)
	return text
}

wrap_for :: proc(signer, recipient: ^Dev, version, epoch: i64, user := USER) -> Wrap_Input {
	w := vault.Keyring_Wrap{
		alg = vault.WRAP_ALG_ECDH_P256_HKDF_AES, recipient_device_id = recipient.id,
		directory_version = u64(version), current_epoch = u32(epoch),
		ephemeral_public_key = recipient.ecdh_pub, iv = "bc20a2fb46127e3a719bdb68",
		ciphertext = "00112233445566778899aabbccddeeff00112233", wrapped_by_device_id = signer.id,
	}
	stmt, _ := vault.wrap_statement(&w, user, context.temp_allocator)
	return Wrap_Input{wrap = w, signature = sign(signer, stmt)}
}

do_genesis :: proc(t: ^testing.T, f: ^Fixture, root: ^Dev) {
	g := statement("genesis", root, root, "0", "1")
	e := statement("epoch", root, nil, "0", "1")
	_, err := genesis(&f.svc, Genesis_Input{user_id = USER, genesis_statement = g, genesis_signature = sign(root, g), epoch_statement = e, epoch_signature = sign(root, e), wrap = wrap_for(root, root, 0, 1)})
	testing.expect_value(t, err.code, domain.Error_Code.None)
}

do_register :: proc(t: ^testing.T, f: ^Fixture, d: ^Dev) -> domain.Vault_Device {
	s := statement("register", d, d, "", "")
	res, err := register(&f.svc, USER, s, sign(d, s))
	testing.expect_value(t, err.code, domain.Error_Code.None)
	return res.device
}

signed_req :: proc(d: ^Dev, method, path, body: string, nonce := "nonce-0000000000000001", ts := T0_MS, user := USER) -> Signed_Request {
	ts_s := itoa(ts)
	msg := request_canonical(method, path, user, ts_s, nonce, body, context.temp_allocator)
	return Signed_Request{method = method, path = path, body = body, device_id = d.id, ts = ts_s, nonce = nonce, signature = sign(d, msg)}
}

dev_row :: proc(f: ^Fixture, id: string) -> domain.Vault_Device {
	devices, _ := iface.vault_list_devices(&f.repo, USER)
	d, _ := find_device(devices, id)
	return d
}

approve_b :: proc(t: ^testing.T, f: ^Fixture, a, b: ^Dev, version: i64) -> (i64, domain.Domain_Error) {
	row := dev_row(f, b.id)
	st := statement("approve", a, b, itoa(version), "1")
	return approve(&f.svc, Approve_Input{
		user_id = USER, device_id = b.id, user_code = row.user_code, expected_version = version,
		statement = st, signature = sign(a, st), wrap = wrap_for(a, b, version, 1), signer = dev_row(f, a.id),
	})
}

@(test)
test_vault_genesis_register_approve_revoke_flow :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_close(f)
	a, b := make_dev(1), make_dev(2)
	do_genesis(t, f, &a)
	pending := do_register(t, f, &b)
	testing.expect_value(t, pending.status, domain.Vault_Device_Status.Pending)
	testing.expect_value(t, len(pending.user_code), 14)

	// The 12-symbol code resolves for this user only; an 8-symbol (bridge) code never does.
	got, rerr := resolve_pending_code(&f.svc, USER, strings.to_lower(pending.user_code, context.temp_allocator))
	testing.expect(t, rerr.code == .None && got.device_id == b.id)
	_, other_user := resolve_pending_code(&f.svc, OTHER, pending.user_code)
	_, short := resolve_pending_code(&f.svc, USER, pending.user_code[:9])
	testing.expect(t, other_user.code == .Not_Found && short.code == .Not_Found)

	// Second genesis is rejected.
	g := statement("genesis", &b, &b, "0", "1")
	e := statement("epoch", &b, nil, "0", "1")
	_, gerr := genesis(&f.svc, Genesis_Input{user_id = USER, genesis_statement = g, genesis_signature = sign(&b, g), epoch_statement = e, epoch_signature = sign(&b, e), wrap = wrap_for(&b, &b, 0, 1)})
	testing.expect_value(t, gerr.code, domain.Error_Code.Conflict)

	// Stale expected_version -> 409 naming the current version; nothing changes.
	_, stale := approve_b(t, f, &a, &b, 5)
	testing.expect_value(t, stale.code, domain.Error_Code.Conflict)
	testing.expect_value(t, stale.details_json, `{"reason":"version_conflict","current_version":1}`)
	testing.expect_value(t, dev_row(f, b.id).status, domain.Vault_Device_Status.Pending)

	v, aerr := approve_b(t, f, &a, &b, 1)
	testing.expect_value(t, aerr.code, domain.Error_Code.None)
	testing.expect_value(t, v, i64(2))
	_, has_wrap, _ := iface.vault_get_wrap(&f.repo, USER, b.id)
	testing.expect(t, has_wrap)

	// Revoke rules.
	signer := dev_row(f, a.id)
	revoke_in :: proc(a, target: ^Dev, signer: domain.Vault_Device, version, epoch: i64, wraps: []Wrap_Input) -> Revoke_Input {
		r := statement("revoke", a, target, itoa(version), itoa(epoch))
		e := statement("epoch", a, nil, itoa(version), itoa(epoch))
		return Revoke_Input{user_id = USER, device_id = target.id, expected_version = version, revoke_statement = r, signature = sign(a, r), epoch_statement = e, epoch_signature = sign(a, e), wraps = wraps, signer = signer}
	}
	_, self := revoke(&f.svc, revoke_in(&a, &a, signer, 2, 2, {wrap_for(&a, &b, 2, 2)}))
	testing.expect_value(t, self.code, domain.Error_Code.Conflict)
	testing.expect_value(t, self.details_json, `{"reason":"self_revoke"}`)
	_, missing := revoke(&f.svc, revoke_in(&a, &b, signer, 2, 2, {}))
	_, extra := revoke(&f.svc, revoke_in(&a, &b, signer, 2, 2, {wrap_for(&a, &a, 2, 2), wrap_for(&a, &b, 2, 2)}))
	_, bad_epoch := revoke(&f.svc, revoke_in(&a, &b, signer, 2, 3, {wrap_for(&a, &a, 2, 3)}))
	testing.expect(t, missing.code == .Validation_Failed && extra.code == .Validation_Failed && bad_epoch.code == .Validation_Failed)
	res, ok_err := revoke(&f.svc, revoke_in(&a, &b, signer, 2, 2, {wrap_for(&a, &a, 2, 2)}))
	testing.expect_value(t, ok_err.code, domain.Error_Code.None)
	testing.expect_value(t, res.version, i64(3))
	dir, _, _ := iface.vault_get_directory(&f.repo, USER)
	testing.expect_value(t, dir.current_epoch, i64(2))
	_, b_wrap, _ := iface.vault_get_wrap(&f.repo, USER, b.id)
	testing.expect(t, !b_wrap, "the revoked device's wrap is gone")
	// The only approver left cannot revoke itself (the last-approver path).
	_, last := revoke(&f.svc, revoke_in(&a, &a, signer, 3, 3, {}))
	testing.expect_value(t, last.code, domain.Error_Code.Conflict)
}

@(test)
test_vault_register_rejects_mismatched_proof :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_close(f)
	a, b := make_dev(1), make_dev(2)
	s := statement("register", &b, &b, "", "")
	_, err := register(&f.svc, USER, s, sign(&a, s))
	testing.expect_value(t, err.code, domain.Error_Code.Unauthenticated)
	_, cross := register(&f.svc, OTHER, s, sign(&b, s))
	testing.expect_value(t, cross.code, domain.Error_Code.Forbidden)
}

@(test)
test_vault_request_signature_rejections :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_close(f)
	a, b, c := make_dev(1), make_dev(2), make_dev(3)
	do_genesis(t, f, &a)
	do_register(t, f, &b)
	PATH :: "/api/v1/vault/devices/x/revoke"
	BODY :: `{"expected_version":1}`

	// Valid.
	dev, ok_err := verify_request(&f.svc, USER, signed_req(&a, "POST", PATH, BODY), .Approver)
	testing.expect(t, ok_err.code == .None && dev.device_id == a.id)
	// Replayed nonce.
	_, replay := verify_request(&f.svc, USER, signed_req(&a, "POST", PATH, BODY), .Approver)
	testing.expect_value(t, replay.code, domain.Error_Code.Unauthenticated)
	// Unsigned.
	_, unsigned := verify_request(&f.svc, USER, Signed_Request{method = "POST", path = PATH, body = BODY}, .Approver)
	testing.expect_value(t, unsigned.code, domain.Error_Code.Unauthenticated)
	// Wrong signer: headers name A, signature by C.
	wrong := signed_req(&c, "POST", PATH, BODY, "nonce-0000000000000002")
	wrong.device_id = a.id
	_, wrong_err := verify_request(&f.svc, USER, wrong, .Approver)
	testing.expect_value(t, wrong_err.code, domain.Error_Code.Unauthenticated)
	// Unknown device and cross-user signer.
	_, unknown := verify_request(&f.svc, USER, signed_req(&c, "POST", PATH, BODY, "nonce-0000000000000003"), .Approver)
	_, cross := verify_request(&f.svc, OTHER, signed_req(&a, "POST", PATH, BODY, "nonce-0000000000000004", user = OTHER), .Approver)
	testing.expect(t, unknown.code == .Forbidden && cross.code == .Forbidden)
	// Pending (not approved) signer.
	_, pending := verify_request(&f.svc, USER, signed_req(&b, "POST", PATH, BODY, "nonce-0000000000000005"), .Approver)
	testing.expect_value(t, pending.code, domain.Error_Code.Forbidden)
	// Expired / future timestamp.
	_, old := verify_request(&f.svc, USER, signed_req(&a, "POST", PATH, BODY, "nonce-0000000000000006", T0_MS - 61_000), .Approver)
	_, future := verify_request(&f.svc, USER, signed_req(&a, "POST", PATH, BODY, "nonce-0000000000000007", T0_MS + 61_000), .Approver)
	testing.expect(t, old.code == .Unauthenticated && future.code == .Unauthenticated)
	// Body tampered after signing.
	tampered := signed_req(&a, "POST", PATH, BODY, "nonce-0000000000000008")
	tampered.body = `{"expected_version":2}`
	_, tamper_err := verify_request(&f.svc, USER, tampered, .Approver)
	testing.expect_value(t, tamper_err.code, domain.Error_Code.Unauthenticated)

	// Bridge signer: insert an approved bridge via the bridge approval path.
	br := make_dev(9, "bridge")
	st := statement("approve", &a, &br, "1", "1")
	bin := Bridge_Approval_Input{user_id = USER, expected_version = 1, statement = st, signature = sign(&a, st), bridge_identity_public_key = br.sign_pub}
	row, cerr := check_bridge_approval(&f.svc, bin)
	testing.expect_value(t, cerr.code, domain.Error_Code.None)
	_, commit_err := commit_bridge_approval(&f.svc, bin, row, "brg_test")
	testing.expect_value(t, commit_err.code, domain.Error_Code.None)
	_, bridge_signer := verify_request(&f.svc, USER, signed_req(&br, "POST", PATH, BODY, "nonce-0000000000000009"), .Approver)
	testing.expect_value(t, bridge_signer.code, domain.Error_Code.Forbidden)
	_, bridge_self := verify_request(&f.svc, USER, signed_req(&br, "GET", "/api/v1/vault/devices/self", "", "nonce-0000000000000010"), .Self)
	testing.expect_value(t, bridge_self.code, domain.Error_Code.Forbidden)

	// Revoked signer: approve B, revoke B (A signs), then B is refused.
	_, aerr := approve_b(t, f, &a, &b, 2)
	testing.expect_value(t, aerr.code, domain.Error_Code.None)
	r := statement("revoke", &a, &b, "3", "2")
	e := statement("epoch", &a, nil, "3", "2")
	_, rerr := revoke(&f.svc, Revoke_Input{user_id = USER, device_id = b.id, expected_version = 3, revoke_statement = r, signature = sign(&a, r), epoch_statement = e, epoch_signature = sign(&a, e), wraps = {wrap_for(&a, &a, 3, 2)}, signer = dev_row(f, a.id)})
	testing.expect_value(t, rerr.code, domain.Error_Code.None)
	_, revoked := verify_request(&f.svc, USER, signed_req(&b, "POST", PATH, BODY, "nonce-0000000000000011"), .Approver)
	testing.expect_value(t, revoked.code, domain.Error_Code.Forbidden)
	// ...but may still learn it is revoked from GET self.
	self_dev, self_err := verify_request(&f.svc, USER, signed_req(&b, "GET", "/api/v1/vault/devices/self", "", "nonce-0000000000000012"), .Self)
	testing.expect(t, self_err.code == .None && self_dev.status == .Revoked)
}

@(test)
test_vault_nonce_cache_is_partitioned_per_device :: proc(t: ^testing.T) {
	c := nonce_cache_make(2)
	defer nonce_cache_free(&c)
	testing.expect_value(t, nonce_cache_insert(&c, "u|a", "n1", 0, 100), Nonce_Result.Inserted)
	testing.expect_value(t, nonce_cache_insert(&c, "u|a", "n2", 0, 100), Nonce_Result.Inserted)
	testing.expect_value(t, nonce_cache_insert(&c, "u|a", "n3", 50, 100), Nonce_Result.Full) // live entries are never evicted
	testing.expect_value(t, nonce_cache_insert(&c, "u|a", "n1", 50, 100), Nonce_Result.Replay)
	// A full bucket does not affect another device or another account.
	testing.expect_value(t, nonce_cache_insert(&c, "u|b", "n1", 50, 100), Nonce_Result.Inserted)
	testing.expect_value(t, nonce_cache_insert(&c, "v|a", "n3", 50, 100), Nonce_Result.Inserted)
	testing.expect_value(t, nonce_cache_insert(&c, "u|a", "n3", 101, 100), Nonce_Result.Inserted) // expired ones are purged
	nonce_cache_sweep(&c, 1_000)
	testing.expect_value(t, len(c.buckets), 0)
}

@(test)
test_vault_reads_do_not_consume_nonces :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_close(f)
	a, b := make_dev(1), make_dev(2)
	do_genesis(t, f, &a)
	do_register(t, f, &b)
	// A pending device polling GET self far beyond any quota never fills a bucket.
	for i in 0 ..< NONCE_DEVICE_QUOTA + 8 {
		nonce := strings.concatenate({"nonce-self-", itoa(i64(100000 + i))}, context.temp_allocator)
		_, err := verify_request(&f.svc, USER, signed_req(&b, "GET", "/api/v1/vault/devices/self", "", nonce), .Self)
		testing.expect_value(t, err.code, domain.Error_Code.None)
	}
	testing.expect_value(t, len(f.svc.nonces.buckets), 0)
	// The approver's mutation still goes through.
	_, err := verify_request(&f.svc, USER, signed_req(&a, "POST", "/api/v1/vault/devices/x/deny", "{}"), .Approver)
	testing.expect_value(t, err.code, domain.Error_Code.None)
}

bridge_commit :: proc(t: ^testing.T, f: ^Fixture, a, br: ^Dev, version: i64, bridge_id: string) -> domain.Domain_Error {
	st := statement("approve", a, br, itoa(version), "1")
	bin := Bridge_Approval_Input{user_id = USER, expected_version = version, statement = st, signature = sign(a, st), bridge_identity_public_key = br.sign_pub}
	row, cerr := check_bridge_approval(&f.svc, bin)
	if cerr.code != .None do return cerr
	_, err := commit_bridge_approval(&f.svc, bin, row, bridge_id)
	return err
}

// M3: an attach supersedes the bridge's old identity in the same CAS; a rolled-back
// enrollment's entry is retired.
@(test)
test_vault_bridge_entry_lifecycle :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_close(f)
	a := make_dev(1)
	do_genesis(t, f, &a)
	old_id, new_id := make_dev(20, "bridge"), make_dev(21, "bridge")
	testing.expect_value(t, bridge_commit(t, f, &a, &old_id, 1, "brg_1").code, domain.Error_Code.None)
	testing.expect_value(t, bridge_commit(t, f, &a, &new_id, 2, "brg_1").code, domain.Error_Code.None)
	testing.expect_value(t, dev_row(f, old_id.id).status, domain.Vault_Device_Status.Revoked)
	testing.expect_value(t, dev_row(f, new_id.id).status, domain.Vault_Device_Status.Approved)
	other, _ := other_approved_for_bridge(&f.svc, USER, "brg_1", new_id.id)
	testing.expect(t, !other, "exactly one approved identity per bridge")

	// Rollback after the directory commit: the approved entry is retired, once.
	retired, err := retire_bridge_entry(&f.svc, USER, "brg_1")
	testing.expect(t, err.code == .None && retired == new_id.id)
	testing.expect_value(t, dev_row(f, new_id.id).status, domain.Vault_Device_Status.Revoked)
	again, _ := retire_bridge_entry(&f.svc, USER, "brg_1")
	testing.expect_value(t, again, "")
	dir, _, _ := iface.vault_get_directory(&f.repo, USER)
	testing.expect_value(t, dir.version, i64(4))
}
