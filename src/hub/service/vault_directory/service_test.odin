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

v2_signed_req :: proc(d: ^Dev, method, path, body: string, index := 1, ts := T0_MS, user := USER) -> Signed_Request {
	nonce := strings.concatenate({"00000000-0000-4000-8000-", itoa(100000000000 + i64(index))}, context.temp_allocator)
	ts_s := itoa(ts)
	msg := request_v2_canonical(method, path, user, ts_s, nonce, body, context.temp_allocator)
	return Signed_Request{version = "2", method = method, path = path, body = body, device_id = d.id, ts = ts_s, nonce = nonce, signature = sign(d, msg)}
}

@(test)
test_vault_v2_fields_reads_and_full_replay_window :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_close(f)
	a := make_dev(1)
	do_genesis(t, f, &a)
	for i in 0..<8 {
		original := v2_signed_req(&a, "POST", "/api/v1/x/%2f?q=a%20b&b=2", `{"a":1}`, i)
		changed := original
		switch i {
		case 0: changed.method = "GET"
		case 1: changed.path = "/api/v1/x/%2F?q=a%20b&b=2"
		case 2: changed.path = "/api/v1/x/%2f?b=2&q=a%20b"
		case 3: changed.ts = itoa(T0_MS+1)
		case 4: changed.nonce = "00000000-0000-4000-8000-999999999999"
		case 5: changed.body = `{"a":1} `
		case 6: changed.version = "3"
		case 7: changed.signature = "invalid"
		}
		_, bad := verify_request(&f.svc, USER, changed, .Approved)
		testing.expect(t, bad.code != .None)
		_, good := verify_request(&f.svc, USER, original, .Approved)
		testing.expect_value(t, good.code, domain.Error_Code.None)
	}
	wrong_user := v2_signed_req(&a, "GET", "/api/v1/me", "", 20, user = OTHER)
	_, cross := verify_request(&f.svc, USER, wrong_user, .Approved)
	testing.expect(t, cross.code != .None)
	read := v2_signed_req(&a, "GET", "/api/v1/vault/devices/self", "", 21)
	_, first := verify_request(&f.svc, USER, read, .Self)
	_, replay := verify_request(&f.svc, USER, read, .Self)
	testing.expect_value(t, first.code, domain.Error_Code.None)
	testing.expect_value(t, replay.code, domain.Error_Code.Unauthenticated)
	// Losing the in-memory cache must not allow a captured proof after restart.
	service_free(&f.svc)
	f.svc = new_service(&f.repo, &f.clock)
	_, restart_replay := verify_request(&f.svc, USER, read, .Self)
	testing.expect_value(t, restart_replay.code, domain.Error_Code.Unauthenticated)
	for ts, i in ([]i64{T0_MS-300001, T0_MS+300001}) {
		_, outside := verify_request(&f.svc, USER, v2_signed_req(&a, "GET", "/api/v1/me", "", 30+i, ts), .Approved)
		testing.expect_value(t, outside.code, domain.Error_Code.Unauthenticated)
	}
	future := v2_signed_req(&a, "GET", "/api/v1/me", "", 40, T0_MS+300000)
	_, future_ok := verify_request(&f.svc, USER, future, .Approved)
	testing.expect_value(t, future_ok.code, domain.Error_Code.None)
	f.now = "2026-10-19T10:10:00Z"
	service_free(&f.svc)
	f.svc = new_service(&f.repo, &f.clock)
	_, late_replay := verify_request(&f.svc, USER, future, .Approved)
	testing.expect_value(t, late_replay.code, domain.Error_Code.Unauthenticated)
}

@(test)
test_vault_v2_pending_approved_revoked_lifecycle :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_close(f)
	a, b, rk := make_dev(1), make_dev(2), make_dev(3, "recovery")
	do_genesis(t, f, &a)
	do_register(t, f, &b)
	pending, self_err := verify_request(&f.svc, USER, v2_signed_req(&b, "GET", "/api/v1/vault/devices/self", ""), .Self)
	testing.expect(t, self_err.code == .None && pending.status == .Pending)
	_, pending_err := verify_request(&f.svc, USER, v2_signed_req(&b, "GET", "/api/v1/me", "", 2), .Approved)
	testing.expect_value(t, pending_err.code, domain.Error_Code.Forbidden)
	_, aerr := approve_b(t, f, &a, &b, 1)
	testing.expect_value(t, aerr.code, domain.Error_Code.None)
	approved, approved_err := verify_request(&f.svc, USER, v2_signed_req(&b, "GET", "/api/v1/vault/devices/self", "", 3), .Self)
	testing.expect_value(t, approved_err.code, domain.Error_Code.None)
	view, view_err := get_self(&f.svc, USER, approved)
	testing.expect(t, view_err.code == .None && view.has_wrap)
	_, rk_err := add_recovery_by(f, &a, &rk, 2, 1)
	testing.expect_value(t, rk_err.code, domain.Error_Code.None)
	r := statement("revoke", &a, &b, "4", "2", prev = head(f))
	_, rerr := revoke(&f.svc, Revoke_Input{user_id = USER, device_id = b.id, expected_version = 3, revoke_statement = r, signature = sign(&a, r), wraps = {wrap_for(&a, &a, 4, 2), wrap_for(&a, &rk, 4, 2)}, signer = dev_row(f, a.id)})
	testing.expect_value(t, rerr.code, domain.Error_Code.None)
	revoked, revoked_err := verify_request(&f.svc, USER, v2_signed_req(&b, "GET", "/api/v1/vault/devices/self", "", 4), .Self)
	testing.expect(t, revoked_err.code == .None && revoked.status == .Revoked)
	revoked_view, revoked_view_err := get_self(&f.svc, USER, revoked)
	testing.expect(t, revoked_view_err.code == .None && !revoked_view.has_wrap)
	_, protected_err := verify_request(&f.svc, USER, v2_signed_req(&b, "GET", "/api/v1/me", "", 5), .Approved)
	testing.expect_value(t, protected_err.code, domain.Error_Code.Forbidden)
}

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

// seq is the log slot (version + 1 for a mutation, "1" for genesis, "" for register).
statement :: proc(type: string, issuer: ^Dev, subject: ^Dev, seq, epoch: string, user := USER, wrap_sha := "", prev := "") -> string {
	st := vault.Statement{type = type, user_id = user, seq = seq, prev_hash = prev, issuer_device_id = issuer.id, issued_at_ms = "1760868000000", epoch = epoch, wrap_sha256 = wrap_sha}
	if subject != nil {
		st.subject_device_id = subject.id
		st.subject_kind = subject.kind
		st.subject_sign_pub = subject.sign_pub
		st.subject_ecdh_pub = subject.ecdh_pub
		st.subject_sign_alg = vault.SIGN_ALG_ECDSA_P256_SHA256
		st.subject_wrap_alg = "" if subject.kind == "bridge" else vault.WRAP_ALG_ECDH_P256_HKDF_AES
		st.subject_label_b64 = LABEL_B64
	}
	if type != "register" do st.epoch_commit = COMMIT
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
	g := statement("genesis", root, root, "1", "1")
	_, err := genesis(&f.svc, Genesis_Input{user_id = USER, genesis_statement = g, genesis_signature = sign(root, g), wrap = wrap_for(root, root, 1, 1)})
	testing.expect_value(t, err.code, domain.Error_Code.None)
}

// lookup_of stands in for the pairing lookup a device derives from its code.
lookup_of :: proc(d: ^Dev) -> string {
	return vault.log_entry_hash(strings.concatenate({"lookup|", d.id}, context.temp_allocator), context.temp_allocator)
}

PAIR_MAC :: "5555555555555555555555555555555555555555555555555555555555555555"
PAIR_SALT :: "0123456789abcdef0123456789abcdef"
PAIR_ORIGIN :: "https://hub.example.test:443"

do_register :: proc(t: ^testing.T, f: ^Fixture, d: ^Dev) -> domain.Vault_Device {
	s := statement("register", d, d, "", "")
	res, err := register(&f.svc, USER, s, sign(d, s), lookup_of(d), vault.log_entry_hash(strings.concatenate({"mac|", d.id}, context.temp_allocator), context.temp_allocator), PAIR_SALT, PAIR_ORIGIN)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	return res.device
}

signed_req :: proc(d: ^Dev, method, path, body: string, nonce := "nonce-0000000000000001", ts := T0_MS, user := USER) -> Signed_Request {
	ts_s := itoa(ts)
	msg := request_canonical(method, path, user, ts_s, nonce, body, context.temp_allocator)
	return Signed_Request{method = method, path = path, body = body, device_id = d.id, ts = ts_s, nonce = nonce, signature = sign(d, msg)}
}

head :: proc(f: ^Fixture) -> string {
	dir, _, _ := iface.vault_get_directory(&f.repo, USER)
	return dir.head_hash
}

dev_row :: proc(f: ^Fixture, id: string) -> domain.Vault_Device {
	devices, _ := iface.vault_list_devices(&f.repo, USER)
	d, _ := find_device(devices, id)
	return d
}

wrap_sha :: proc(w: Wrap_Input) -> string {
	digest: [32]byte
	ww := w.wrap
	_ = vault.wrap_sha256(&ww, digest[:])
	return vault.hex_encode_lower(digest[:], context.temp_allocator)
}

approve_b :: proc(t: ^testing.T, f: ^Fixture, a, b: ^Dev, version: i64) -> (i64, domain.Domain_Error) {
	row := dev_row(f, b.id)
	w := wrap_for(a, b, version + 1, 1)
	st := statement("approve", a, b, itoa(version + 1), "1", wrap_sha = wrap_sha(w), prev = head(f))
	return approve(&f.svc, Approve_Input{
		user_id = USER, device_id = b.id, pair_lookup = row.pair_lookup, pair_mac = PAIR_MAC, expected_version = version,
		statement = st, signature = sign(a, st), wrap = w, signer = dev_row(f, a.id),
	})
}

BLOB :: `{"v":1,"alg":"bip39-hkdf-sha256-aes256gcm","iv":"bc20a2fb46127e3a719bdb68","ciphertext":"00112233445566778899aabbccddeeff00112233"}`

// add_recovery_by signs the approval of recovery credential r by `by` at `version`.
add_recovery_by :: proc(f: ^Fixture, by, r: ^Dev, version, epoch: i64, blob := BLOB) -> (i64, domain.Domain_Error) {
	w := wrap_for(by, r, version + 1, epoch)
	st := statement("approve", by, r, itoa(version + 1), itoa(epoch), wrap_sha = wrap_sha(w), prev = head(f))
	v, _, err := add_recovery(&f.svc, Recovery_Input{
		user_id = USER, expected_version = version, statement = st, signature = sign(by, st), wrap = w,
		recovery_blob = blob, signer = dev_row(f, by.id),
	})
	return v, err
}

// L7: the approval must commit to the wrap (wrap_sha256) and the current epoch_commit.
@(test)
test_vault_approve_binds_wrap_and_epoch_commit :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_close(f)
	a, b := make_dev(1), make_dev(2)
	do_genesis(t, f, &a)
	do_register(t, f, &b)
	row := dev_row(f, b.id)
	w := wrap_for(&a, &b, 2, 1)
	h := head(f)
	try :: proc(f: ^Fixture, a, b: ^Dev, code: string, w: Wrap_Input, st: string) -> domain.Error_Code {
		_, err := approve(&f.svc, Approve_Input{user_id = USER, device_id = b.id, pair_lookup = code, pair_mac = PAIR_MAC, expected_version = 1, statement = st, signature = sign(a, st), wrap = w, signer = dev_row(f, a.id)})
		return err.code
	}
	no_sha := statement("approve", &a, &b, "2", "1", prev = h)
	other_sha := statement("approve", &a, &b, "2", "1", wrap_sha = wrap_sha(wrap_for(&a, &a, 2, 1)), prev = h)
	unlinked := statement("approve", &a, &b, "2", "1", wrap_sha = wrap_sha(w), prev = strings.repeat("0", 64, context.temp_allocator))
	testing.expect_value(t, try(f, &a, &b, row.pair_lookup, w, unlinked), domain.Error_Code.Conflict)
	testing.expect_value(t, try(f, &a, &b, row.pair_lookup, w, no_sha), domain.Error_Code.Validation_Failed)
	testing.expect_value(t, try(f, &a, &b, row.pair_lookup, w, other_sha), domain.Error_Code.Validation_Failed)
	bad_commit := vault.Statement{type = "approve", user_id = USER, seq = "2", prev_hash = h, issuer_device_id = a.id, issued_at_ms = "1760868000000", epoch = "1",
		subject_device_id = b.id, subject_kind = "browser", subject_sign_pub = b.sign_pub, subject_ecdh_pub = b.ecdh_pub,
		subject_sign_alg = vault.SIGN_ALG_ECDSA_P256_SHA256, subject_wrap_alg = vault.WRAP_ALG_ECDH_P256_HKDF_AES, subject_label_b64 = LABEL_B64,
		epoch_commit = strings.repeat("0", 64, context.temp_allocator), wrap_sha256 = wrap_sha(w)}
	bad_text, _ := vault.statement_canonical(&bad_commit, context.temp_allocator)
	testing.expect_value(t, try(f, &a, &b, row.pair_lookup, w, bad_text), domain.Error_Code.Validation_Failed)
	testing.expect_value(t, try(f, &a, &b, row.pair_lookup, w, statement("approve", &a, &b, "2", "1", wrap_sha = wrap_sha(w), prev = h)), domain.Error_Code.None)
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
	testing.expect_value(t, pending.pair_lookup, lookup_of(&b))

	// The pairing lookup resolves for this user only; malformed lookups never do.
	got, rerr := resolve_pending_lookup(&f.svc, USER, pending.pair_lookup)
	testing.expect(t, rerr.code == .None && got.device_id == b.id && got.register_statement != "")
	_, other_user := resolve_pending_lookup(&f.svc, OTHER, pending.pair_lookup)
	_, short := resolve_pending_lookup(&f.svc, USER, pending.pair_lookup[:63])
	testing.expect(t, other_user.code == .Not_Found && short.code == .Not_Found)

	// A replayed (not newer) register body cannot take over the live request.
	replay := statement("register", &b, &b, "", "")
	_, rp := register(&f.svc, USER, replay, sign(&b, replay), lookup_of(&a), PAIR_MAC, PAIR_SALT, PAIR_ORIGIN)
	testing.expect_value(t, rp.code, domain.Error_Code.Conflict)
	testing.expect_value(t, dev_row(f, b.id).pair_lookup, lookup_of(&b))

	// Approving needs the request's own lookup (the approver derived it from the code).
	wrong := Approve_Input{user_id = USER, device_id = b.id, pair_lookup = lookup_of(&a), pair_mac = PAIR_MAC, expected_version = 1}
	_, wl := approve(&f.svc, wrong)
	testing.expect_value(t, wl.code, domain.Error_Code.Not_Found)

	// Second genesis is rejected.
	g := statement("genesis", &b, &b, "1", "1")
	_, gerr := genesis(&f.svc, Genesis_Input{user_id = USER, genesis_statement = g, genesis_signature = sign(&b, g), wrap = wrap_for(&b, &b, 1, 1)})
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
	approved := dev_row(f, b.id)
	testing.expect(t, approved.pair_mac == PAIR_MAC && approved.pair_lookup == "" && approved.pair_key_mac == "", "pair_mac stored, pending pairing fields cleared")

	// Revoke rules.
	signer := dev_row(f, a.id)
	h2 := head(f)
	revoke_in :: proc(a, target: ^Dev, signer: domain.Vault_Device, version, epoch: i64, wraps: []Wrap_Input, prev: string) -> Revoke_Input {
		r := statement("revoke", a, target, itoa(version + 1), itoa(epoch), prev = prev)
		return Revoke_Input{user_id = USER, device_id = target.id, expected_version = version, revoke_statement = r, signature = sign(a, r), wraps = wraps, signer = signer}
	}
	_, self := revoke(&f.svc, revoke_in(&a, &a, signer, 2, 2, {wrap_for(&a, &b, 3, 2)}, h2))
	testing.expect_value(t, self.code, domain.Error_Code.Conflict)
	testing.expect_value(t, self.details_json, `{"reason":"self_revoke"}`)
	// Last-approver guard: B is the only approver besides the signer and there is no
	// recovery key, so revoking it would leave A as the single approver. Refused.
	_, last := revoke(&f.svc, revoke_in(&a, &b, signer, 2, 2, {wrap_for(&a, &a, 3, 2)}, h2))
	testing.expect_value(t, last.code, domain.Error_Code.Conflict)
	testing.expect_value(t, last.details_json, `{"reason":"last_approver"}`)
	// With a recovery key the revoke is allowed (the recovery key counts as an approver).
	r := make_dev(3, "recovery")
	rv, rerr2 := add_recovery_by(f, &a, &r, 2, 1)
	testing.expect_value(t, rerr2.code, domain.Error_Code.None)
	testing.expect_value(t, rv, i64(3))
	testing.expect_value(t, dev_row(f, r.id).recovery_blob, BLOB)
	h3 := head(f)
	_, missing := revoke(&f.svc, revoke_in(&a, &b, signer, 3, 2, {wrap_for(&a, &a, 4, 2)}, h3))
	_, extra := revoke(&f.svc, revoke_in(&a, &b, signer, 3, 2, {wrap_for(&a, &a, 4, 2), wrap_for(&a, &r, 4, 2), wrap_for(&a, &b, 4, 2)}, h3))
	_, bad_epoch := revoke(&f.svc, revoke_in(&a, &b, signer, 3, 3, {wrap_for(&a, &a, 4, 3), wrap_for(&a, &r, 4, 3)}, h3))
	testing.expect(t, missing.code == .Validation_Failed && extra.code == .Validation_Failed && bad_epoch.code == .Validation_Failed)
	res, ok_err := revoke(&f.svc, revoke_in(&a, &b, signer, 3, 2, {wrap_for(&a, &a, 4, 2), wrap_for(&a, &r, 4, 2)}, h3))
	testing.expect_value(t, ok_err.code, domain.Error_Code.None)
	testing.expect_value(t, res.version, i64(4))
	dir, _, _ := iface.vault_get_directory(&f.repo, USER)
	testing.expect_value(t, dir.current_epoch, i64(2))
	_, b_wrap, _ := iface.vault_get_wrap(&f.repo, USER, b.id)
	testing.expect(t, !b_wrap, "the revoked device's wrap is gone")
	_, r_wrap, _ := iface.vault_get_wrap(&f.repo, USER, r.id)
	testing.expect(t, r_wrap, "the recovery key receives the new epoch's wrap")
	// Now A and R remain: revoking R (the only other approver) is refused too.
	_, last_r := revoke(&f.svc, revoke_in(&a, &r, signer, 4, 3, {wrap_for(&a, &a, 5, 3)}, head(f)))
	testing.expect_value(t, last_r.details_json, `{"reason":"last_approver"}`)
}

// P4 recovery key: shape, kind, binding; a revoked recovery credential cannot approve.
@(test)
test_vault_recovery_key_add_and_revoked_cannot_approve :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_close(f)
	a, b, r := make_dev(1), make_dev(2), make_dev(3, "recovery")
	do_genesis(t, f, &a)
	// Malformed blobs and a non-recovery subject are refused; nothing changes.
	_, bad_blob := add_recovery_by(f, &a, &r, 1, 1, `{"v":1,"alg":"bip39-hkdf-sha256-aes256gcm","iv":"bc20a2fb46127e3a719bdb68","ciphertext":"00112233445566778899aabbccddeeff00112233","x":1}`)
	_, no_blob := add_recovery_by(f, &a, &r, 1, 1, "")
	testing.expect(t, bad_blob.code == .Validation_Failed && no_blob.code == .Validation_Failed)
	bb := make_dev(9)
	_, not_rec := add_recovery_by(f, &a, &bb, 1, 1)
	testing.expect_value(t, not_rec.code, domain.Error_Code.Validation_Failed)
	// The recovery key can never be the root.
	g := statement("genesis", &r, &r, "1", "1", user = OTHER)
	_, root_err := genesis(&f.svc, Genesis_Input{user_id = OTHER, genesis_statement = g, genesis_signature = sign(&r, g), wrap = wrap_for(&r, &r, 1, 1, OTHER)})
	testing.expect_value(t, root_err.code, domain.Error_Code.Validation_Failed)
	v, err := add_recovery_by(f, &a, &r, 1, 1)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	// The recovery credential approves a new browser (the restore path) and signs requests.
	do_register(t, f, &b)
	_, rapprove := approve_b(t, f, &r, &b, v)
	testing.expect_value(t, rapprove.code, domain.Error_Code.None)
	_, req_ok := verify_request(&f.svc, USER, signed_req(&r, "POST", "/x", "{}", "nonce-recovery-0000001"), .Approver)
	testing.expect_value(t, req_ok.code, domain.Error_Code.None)
	// B revokes the recovery key (A remains besides B): afterwards R cannot sign.
	rs := statement("revoke", &b, &r, "4", "2", prev = head(f))
	_, rev_err := revoke(&f.svc, Revoke_Input{user_id = USER, device_id = r.id, expected_version = 3, revoke_statement = rs, signature = sign(&b, rs), wraps = {wrap_for(&b, &a, 4, 2), wrap_for(&b, &b, 4, 2)}, signer = dev_row(f, b.id)})
	testing.expect_value(t, rev_err.code, domain.Error_Code.None)
	_, revoked_req := verify_request(&f.svc, USER, signed_req(&r, "POST", "/x", "{}", "nonce-recovery-0000002"), .Approver)
	testing.expect_value(t, revoked_req.code, domain.Error_Code.Forbidden)
}

@(test)
test_vault_register_rejects_mismatched_proof :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_close(f)
	a, b := make_dev(1), make_dev(2)
	s := statement("register", &b, &b, "", "")
	_, err := register(&f.svc, USER, s, sign(&a, s), lookup_of(&a), PAIR_MAC, PAIR_SALT, PAIR_ORIGIN)
	testing.expect_value(t, err.code, domain.Error_Code.Unauthenticated)
	_, cross := register(&f.svc, OTHER, s, sign(&b, s), lookup_of(&b), PAIR_MAC, PAIR_SALT, PAIR_ORIGIN)
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
	st := statement("approve", &a, &br, "2", "1", prev = head(f))
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
	// (A recovery key first: revoking B must not leave A as the single approver.)
	rk := make_dev(3, "recovery")
	_, rk_err := add_recovery_by(f, &a, &rk, 3, 1)
	testing.expect_value(t, rk_err.code, domain.Error_Code.None)
	r := statement("revoke", &a, &b, "5", "2", prev = head(f))
	_, rerr := revoke(&f.svc, Revoke_Input{user_id = USER, device_id = b.id, expected_version = 4, revoke_statement = r, signature = sign(&a, r), wraps = {wrap_for(&a, &a, 5, 2), wrap_for(&a, &rk, 5, 2)}, signer = dev_row(f, a.id)})
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
	st := statement("approve", a, br, itoa(version + 1), "1", prev = head(f))
	bin := Bridge_Approval_Input{user_id = USER, expected_version = version, statement = st, signature = sign(a, st), bridge_identity_public_key = br.sign_pub}
	row, cerr := check_bridge_approval(&f.svc, bin)
	if cerr.code != .None do return cerr
	_, err := commit_bridge_approval(&f.svc, bin, row, bridge_id)
	return err
}

// M3 / REQ-EA-8: an attach does NOT supersede the bridge's old identity at approval
// (the attach is still pending and may roll back); the commit does, via
// retire_bridge_attach_predecessors. A rolled-back enrollment retires only the
// identity approved with it; a bridge revoke retires every live one.
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
	// Pending attach: both identities live, the old one untouched.
	testing.expect_value(t, dev_row(f, old_id.id).retired_at, "")
	testing.expect_value(t, dev_row(f, new_id.id).retired_at, "")
	other, _ := other_approved_for_bridge(&f.svc, USER, "brg_1", new_id.id)
	testing.expect(t, other, "the old identity stays live while the attach is pending")
	// A second concurrent attach onto the same bridge is refused.
	third := make_dev(22, "bridge")
	testing.expect_value(t, bridge_commit(t, f, &a, &third, 3, "brg_1").code, domain.Error_Code.Conflict)

	// Commit: the predecessor is HINTED retired (still approved in the signed log).
	retired, err := retire_bridge_attach_predecessors(&f.svc, USER, "brg_1")
	testing.expect(t, err.code == .None && len(retired) == 1 && retired[0] == old_id.id)
	testing.expect_value(t, dev_row(f, old_id.id).status, domain.Vault_Device_Status.Approved)
	testing.expect(t, dev_row(f, old_id.id).retired_at != "")
	testing.expect_value(t, dev_row(f, new_id.id).retired_at, "")
	again, _ := retire_bridge_attach_predecessors(&f.svc, USER, "brg_1")
	testing.expect_value(t, len(again), 0)
	other, _ = other_approved_for_bridge(&f.svc, USER, "brg_1", new_id.id)
	testing.expect(t, !other, "exactly one live identity per bridge after the commit")

	// Rollback / settings revoke: a hint, once, and it never consumes a version.
	gone, rerr := retire_bridge_entry(&f.svc, USER, "brg_1")
	testing.expect(t, rerr.code == .None && gone == new_id.id)
	testing.expect_value(t, dev_row(f, new_id.id).status, domain.Vault_Device_Status.Approved)
	twice, _ := retire_bridge_entry(&f.svc, USER, "brg_1")
	testing.expect_value(t, twice, "")
	dir, _, _ := iface.vault_get_directory(&f.repo, USER)
	testing.expect_value(t, dir.version, i64(3))
	view, _ := get_directory(&f.svc, USER)
	testing.expect_value(t, len(view.retired_hints), 2)
	testing.expect_value(t, len(view.log), 3)
}

// A rolled-back attach retires only the identity approved with it: the bridge's
// previous identity is left exactly as the attach found it. A bridge revoke during a
// pending attach retires both.
@(test)
test_vault_bridge_attach_rollback_keeps_old_identity :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_close(f)
	a := make_dev(1)
	do_genesis(t, f, &a)
	old_id, new_id := make_dev(30, "bridge"), make_dev(31, "bridge")
	testing.expect_value(t, bridge_commit(t, f, &a, &old_id, 1, "brg_2").code, domain.Error_Code.None)
	testing.expect_value(t, bridge_commit(t, f, &a, &new_id, 2, "brg_2").code, domain.Error_Code.None)
	gone, err := retire_bridge_entry(&f.svc, USER, "brg_2")
	testing.expect(t, err.code == .None && gone == new_id.id, "rollback retires the NEW identity")
	testing.expect_value(t, dev_row(f, old_id.id).retired_at, "")
	testing.expect_value(t, dev_row(f, old_id.id).status, domain.Vault_Device_Status.Approved)

	// Revoke during a pending attach: every live identity of the bridge.
	other_old, other_new := make_dev(32, "bridge"), make_dev(33, "bridge")
	testing.expect_value(t, bridge_commit(t, f, &a, &other_old, 3, "brg_3").code, domain.Error_Code.None)
	testing.expect_value(t, bridge_commit(t, f, &a, &other_new, 4, "brg_3").code, domain.Error_Code.None)
	all, aerr := retire_bridge_identities(&f.svc, USER, "brg_3", .All)
	testing.expect(t, aerr.code == .None && len(all) == 2)
	testing.expect(t, dev_row(f, other_old.id).retired_at != "" && dev_row(f, other_new.id).retired_at != "")
}

// The hub's log is contiguous and hash-linked, and a commit without a signed op is refused.
@(test)
test_vault_log_is_contiguous_and_linked :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_close(f)
	a, b := make_dev(1), make_dev(2)
	do_genesis(t, f, &a)
	do_register(t, f, &b)
	_, aerr := approve_b(t, f, &a, &b, 1)
	testing.expect_value(t, aerr.code, domain.Error_Code.None)
	view, _ := get_directory(&f.svc, USER)
	testing.expect_value(t, len(view.log), 2)
	prev := ""
	for e, i in view.log {
		st, ok := vault.statement_parse(e.statement)
		testing.expect(t, ok && vault.log_link_ok(&st, u64(i + 1), prev))
		prev = vault.log_entry_hash(e.statement, context.temp_allocator)
		testing.expect_value(t, e.entry_hash, prev)
	}
	testing.expect_value(t, view.directory.head_hash, prev)
	// No signed op, no version bump.
	_, err := iface.vault_commit(&f.repo, domain.Vault_Directory_Commit{user_id = USER, expected_version = 2, now = T0, expected_head_hash = prev})
	testing.expect_value(t, err.code, domain.Error_Code.Validation_Failed)
}

// L2: per-user pending cap, purge of expired pending rows, deny, listing.
@(test)
test_vault_pending_cap_purge_and_deny :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_close(f)
	a := make_dev(1)
	do_genesis(t, f, &a)
	for i in 0 ..< domain.VAULT_PENDING_PER_USER_MAX {
		d := make_dev(byte(40 + i))
		do_register(t, f, &d)
	}
	extra := make_dev(80)
	s := statement("register", &extra, &extra, "", "")
	_, capped := register(&f.svc, USER, s, sign(&extra, s), lookup_of(&extra), PAIR_MAC, PAIR_SALT, PAIR_ORIGIN)
	testing.expect_value(t, capped.code, domain.Error_Code.Rate_Limited)

	// Deny frees a slot; denying again (or a non-pending device) is 404.
	first := make_dev(40)
	testing.expect_value(t, deny(&f.svc, USER, first.id).code, domain.Error_Code.None)
	testing.expect_value(t, deny(&f.svc, USER, first.id).code, domain.Error_Code.Not_Found)
	testing.expect_value(t, deny(&f.svc, USER, a.id).code, domain.Error_Code.Not_Found)
	_, ok_err := register(&f.svc, USER, s, sign(&extra, s), lookup_of(&extra), PAIR_MAC, PAIR_SALT, PAIR_ORIGIN)
	testing.expect_value(t, ok_err.code, domain.Error_Code.None)

	// After the codes expire they are hidden from the listing and purged on the next
	// registration, so the cap no longer blocks.
	f.now = "2026-10-19T10:11:00Z"
	view, _ := get_directory(&f.svc, USER)
	testing.expect_value(t, len(view.devices), 1) // only the root
	late := make_dev(81)
	do_register(t, f, &late)
	all, _ := iface.vault_list_devices(&f.repo, USER)
	testing.expect_value(t, len(all), 2)
}

// L8: a recovery key can never be the root.
@(test)
test_vault_genesis_rejects_recovery_root :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_close(f)
	r := make_dev(5, "recovery")
	g := statement("genesis", &r, &r, "1", "1")
	_, err := genesis(&f.svc, Genesis_Input{user_id = USER, genesis_statement = g, genesis_signature = sign(&r, g), wrap = wrap_for(&r, &r, 1, 1)})
	testing.expect_value(t, err.code, domain.Error_Code.Validation_Failed)
	exists, _ := directory_exists(&f.svc, USER)
	testing.expect(t, !exists)
}
