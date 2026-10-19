#+private file
// Vault directory repository: the versioned CAS (plan §2 P2). Hermetic: in-memory DB
// per test, fixed timestamps, no network.
package sqlite

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import "core:sync"
import "core:testing"
import "core:thread"

VD_USER :: "usr_vault_repo"
VD_NOW  :: "2026-10-19T10:00:00Z"
VD_LATER :: "2026-10-19T10:20:00Z"

Vd_Fixture :: struct {
	conn: Conn,
	impl: Vault_Directory_Repo_SQLite,
	repo: iface.Vault_Directory_Repository,
}

vd_open :: proc(t: ^testing.T, f: ^Vd_Fixture) -> bool {
	conn, ok, _ := open(":memory:")
	if !ok do return false
	f.conn = conn
	mig_ok, _ := run_migrations(&f.conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect(t, sqlite_object_exists(&f.conn, "vault_wrapped_keyrings"), "092 applied")
	f.repo = new_vault_directory_repository(&f.impl, &f.conn)
	return mig_ok
}

vd_device :: proc(id, key: string, status: domain.Vault_Device_Status, code := "") -> domain.Vault_Device {
	return domain.Vault_Device{
		device_id = id, user_id = VD_USER, kind = "browser", label = id,
		sign_alg = "ecdsa-p256-sha256", wrap_alg = "ecdh-p256-hkdf-sha256-aes256gcm",
		sign_public_key = key, ecdh_public_key = key, fingerprint = "0000 0000 0000 0000",
		status = status, pair_lookup = code, pair_key_mac = "m" if code != "" else "", register_statement = "r" if code != "" else "", code_expires_at = VD_LATER if code != "" else "",
		created_at = VD_NOW,
	}
}

vd_genesis :: proc(t: ^testing.T, f: ^Vd_Fixture) {
	err := iface.vault_create_genesis(&f.repo, domain.Vault_Genesis{
		directory = {user_id = VD_USER, version = 1, current_epoch = 1, root_device_id = "dev_root", head_hash = "h1", genesis_statement = "g", genesis_signature = "s", created_at = VD_NOW, updated_at = VD_NOW},
		log = {user_id = VD_USER, seq = 1, statement = "g", signature = "s", entry_hash = "h1", created_at = VD_NOW},
		device = vd_device("dev_root", "k_root", .Approved),
		epoch = {user_id = VD_USER, epoch = 1, statement = "e1", signature = "s1", created_at = VD_NOW},
		wrap = {user_id = VD_USER, device_id = "dev_root", directory_version = 0, current_epoch = 1, wrap_json = "{}", updated_at = VD_NOW},
	})
	testing.expect_value(t, err.code, domain.Error_Code.None)
}

@(test)
test_vault_repo_second_genesis_rejected :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f: Vd_Fixture
	if !vd_open(t, &f) do return
	defer close(&f.conn)
	vd_genesis(t, &f)
	err := iface.vault_create_genesis(&f.repo, domain.Vault_Genesis{
		directory = {user_id = VD_USER, version = 1, current_epoch = 1, root_device_id = "dev_other", head_hash = "h9", genesis_statement = "g2", genesis_signature = "s2", created_at = VD_NOW, updated_at = VD_NOW},
		log = {user_id = VD_USER, seq = 1, statement = "g2", signature = "s2", entry_hash = "h9", created_at = VD_NOW},
		device = vd_device("dev_other", "k_other", .Approved),
		epoch = {user_id = VD_USER, epoch = 1, statement = "x", signature = "x", created_at = VD_NOW},
		wrap = {user_id = VD_USER, device_id = "dev_other", wrap_json = "{}", updated_at = VD_NOW},
	})
	testing.expect_value(t, err.code, domain.Error_Code.Conflict)
	dir, _, _ := iface.vault_get_directory(&f.repo, VD_USER)
	testing.expect_value(t, dir.root_device_id, "dev_root")
	devices, _ := iface.vault_list_devices(&f.repo, VD_USER)
	testing.expect_value(t, len(devices), 1)
}

@(test)
test_vault_repo_stale_version_conflicts_and_writes_nothing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f: Vd_Fixture
	if !vd_open(t, &f) do return
	defer close(&f.conn)
	vd_genesis(t, &f)
	_, rerr := iface.vault_register_pending(&f.repo, vd_device("dev_b", "k_b", .Pending, "AAAA-BBBB-CCCC"), VD_NOW)
	testing.expect_value(t, rerr.code, domain.Error_Code.None)

	// Stale: the directory is at version 1.
	_, err := iface.vault_commit(&f.repo, domain.Vault_Directory_Commit{
		user_id = VD_USER, expected_version = 7, now = VD_NOW, expected_head_hash = "h1", log_statement = "op", log_signature = "s", log_entry_hash = "h2",
		approve_device_id = "dev_b", approval_statement = "a", approval_signature = "s", approved_by_device_id = "dev_root",
		wraps = {{user_id = VD_USER, device_id = "dev_b", directory_version = 7, current_epoch = 1, wrap_json = "{}", updated_at = VD_NOW}},
	})
	testing.expect_value(t, err.code, domain.Error_Code.Conflict)
	testing.expect_value(t, err.details_json, `{"reason":"version_conflict","current_version":1}`)
	devices, _ := iface.vault_list_devices(&f.repo, VD_USER)
	for d in devices do if d.device_id == "dev_b" do testing.expect_value(t, d.status, domain.Vault_Device_Status.Pending)
	_, has_wrap, _ := iface.vault_get_wrap(&f.repo, VD_USER, "dev_b")
	testing.expect(t, !has_wrap, "no wrap written on conflict")

	// A guarded row that does not match rolls the CAS back too.
	_, err2 := iface.vault_commit(&f.repo, domain.Vault_Directory_Commit{
		user_id = VD_USER, expected_version = 1, now = VD_NOW, expected_head_hash = "h1", log_statement = "op", log_signature = "s", log_entry_hash = "h2", revoke_device_id = "dev_b", revocation_statement = "r", revocation_signature = "s", revoked_by_device_id = "dev_root",
	})
	testing.expect_value(t, err2.code, domain.Error_Code.Conflict)
	dir, _, _ := iface.vault_get_directory(&f.repo, VD_USER)
	testing.expect_value(t, dir.version, i64(1))

	// Epoch must be current + 1.
	_, err3 := iface.vault_commit(&f.repo, domain.Vault_Directory_Commit{user_id = VD_USER, expected_version = 1, now = VD_NOW, new_epoch = 3, expected_head_hash = "h1", log_statement = "op", log_signature = "s", log_entry_hash = "h2"})
	testing.expect_value(t, err3.code, domain.Error_Code.Conflict)

	v, ok_err := iface.vault_commit(&f.repo, domain.Vault_Directory_Commit{
		user_id = VD_USER, expected_version = 1, now = VD_NOW, expected_head_hash = "h1", log_statement = "op", log_signature = "s", log_entry_hash = "h2",
		approve_device_id = "dev_b", approval_statement = "a", approval_signature = "s", approved_by_device_id = "dev_root",
	})
	testing.expect_value(t, ok_err.code, domain.Error_Code.None)
	testing.expect_value(t, v, i64(2))
	// A stale head hash conflicts even at the right version.
	_, err4 := iface.vault_commit(&f.repo, domain.Vault_Directory_Commit{user_id = VD_USER, expected_version = 2, now = VD_NOW, expected_head_hash = "h1", log_statement = "op2", log_signature = "s", log_entry_hash = "h3"})
	testing.expect_value(t, err4.code, domain.Error_Code.Conflict)
	log, _ := iface.vault_list_log(&f.repo, VD_USER)
	testing.expect_value(t, len(log), 2)
}

Race_Ctx :: struct {
	f:      ^Vd_Fixture,
	device: string,
	start:  ^sync.Barrier,
	err:    domain.Domain_Error,
}

race_approve :: proc(data: rawptr) {
	ctx := (^Race_Ctx)(data)
	sync.barrier_wait(ctx.start)
	_, ctx.err = iface.vault_commit(&ctx.f.repo, domain.Vault_Directory_Commit{
		user_id = VD_USER, expected_version = 1, now = VD_NOW, expected_head_hash = "h1", log_statement = ctx.device, log_signature = "s", log_entry_hash = ctx.device,
		approve_device_id = ctx.device, approval_statement = "a", approval_signature = "s", approved_by_device_id = "dev_root",
	})
}

@(test)
test_vault_repo_concurrent_approvals_exactly_one_wins :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f: Vd_Fixture
	if !vd_open(t, &f) do return
	defer close(&f.conn)
	vd_genesis(t, &f)
	_, e1 := iface.vault_register_pending(&f.repo, vd_device("dev_b", "k_b", .Pending, "AAAA-BBBB-CCCC"), VD_NOW)
	_, e2 := iface.vault_register_pending(&f.repo, vd_device("dev_c", "k_c", .Pending, "DDDD-EEEE-FFFF"), VD_NOW)
	testing.expect(t, e1.code == .None && e2.code == .None)
	barrier: sync.Barrier
	sync.barrier_init(&barrier, 2)
	a := Race_Ctx{f = &f, device = "dev_b", start = &barrier}
	b := Race_Ctx{f = &f, device = "dev_c", start = &barrier}
	ta := thread.create_and_start_with_data(&a, race_approve)
	tb := thread.create_and_start_with_data(&b, race_approve)
	thread.join(ta)
	thread.join(tb)
	thread.destroy(ta)
	thread.destroy(tb)
	wins := 0
	if a.err.code == .None do wins += 1
	if b.err.code == .None do wins += 1
	testing.expect_value(t, wins, 1)
	testing.expect(t, a.err.code == .Conflict || b.err.code == .Conflict, "the loser gets 409")
	approved := 0
	devices, _ := iface.vault_list_devices(&f.repo, VD_USER)
	for d in devices do if d.status == .Approved do approved += 1
	testing.expect_value(t, approved, 2) // root + exactly one of b/c
	dir, _, _ := iface.vault_get_directory(&f.repo, VD_USER)
	testing.expect_value(t, dir.version, i64(2))
}

@(test)
test_vault_repo_register_is_idempotent_per_key :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f: Vd_Fixture
	if !vd_open(t, &f) do return
	defer close(&f.conn)
	first, _ := iface.vault_register_pending(&f.repo, vd_device("dev_b", "k_b", .Pending, "AAAA-BBBB-CCCC"), VD_NOW)
	again, _ := iface.vault_register_pending(&f.repo, vd_device("dev_b", "k_b", .Pending, "GGGG-HHHH-IIII"), VD_NOW)
	testing.expect_value(t, again.pair_lookup, first.pair_lookup) // live lookup kept (no newer register statement)
	refreshed, _ := iface.vault_register_pending(&f.repo, vd_device("dev_b", "k_b", .Pending, "GGGG-HHHH-IIII"), "2026-10-19T11:00:00Z")
	testing.expect_value(t, refreshed.pair_lookup, "GGGG-HHHH-IIII") // expired request replaced
	_, collide := iface.vault_register_pending(&f.repo, vd_device("dev_c", "k_c", .Pending, "GGGG-HHHH-IIII"), VD_NOW)
	testing.expect_value(t, collide.code, domain.Error_Code.Conflict)
}
