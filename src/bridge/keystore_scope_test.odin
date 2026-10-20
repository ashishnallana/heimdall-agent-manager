package main

// Multi-bridge isolation: every persisted vault item is scoped to (hub, bridge id),
// the identity record is bound to its hub, and an enrollment never overwrites an
// existing scope. Hermetic: the in-process fake keystore and a HOME sandbox; runs on
// Windows too:
//   odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_NAMES=main.test_scope_...

import "core:crypto"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"
import vault "odin_test:lib/vault"

@(private = "file")
SCOPE_HUB_A :: "https://Hub-A.example.com"
@(private = "file")
SCOPE_HUB_B :: "http://10.0.0.5:8080/heimdall/"

@(private = "file")
scope_clean :: proc(id: string) {
	for hub in ([]string{SCOPE_HUB_A, SCOPE_HUB_B}) {
		_ = bridge_keystore_set_hub(hub)
		keystore_lock_and_purge(id)
		_ = keystore_delete_identity_key(id)
	}
	_ = bridge_keystore_set_hub("")
	bridge_unseal_forget_identity()
}

@(test)
test_scope_canonical_hub_base :: proc(t: ^testing.T) {
	cases := [][2]string{
		{"https://Hub-A.example.com", "https://hub-a.example.com:443"},
		{"https://hub-a.example.com:443/", "https://hub-a.example.com:443"},
		{"http://10.0.0.5:8080/heimdall/", "http://10.0.0.5:8080/heimdall"},
		{"http://[::1]:9000/x", "http://[::1]:9000/x"},
		{"https://hub-a.example.com.:0443", "https://hub-a.example.com:443"},
		{"http://127.0.0.1:08080", "http://127.0.0.1:8080"},
	}
	for c in cases {
		got, ok := bridge_hub_canonical_base(c[0], context.temp_allocator)
		testing.expectf(t, ok && got == c[1], "%s -> %s (want %s)", c[0], got, c[1])
	}
	for bad in ([]string{"ftp://hub", "https://hub/a?x=1", "https://hub/#f", "https://hub/a/../b", "https://", "https://hub:0", "https://hub:65536", "https://hub:99999999999", "http://127.1", "http://2130706433", "http://0x7f.0.0.1", "http://127.000.0.1", "http://256.0.0.1", "https://hub..example.com"}) {
		_, ok := bridge_hub_canonical_base(bad, context.temp_allocator)
		testing.expectf(t, !ok, "%s must be refused", bad)
	}
}

@(test)
test_scope_same_bridge_id_on_two_hubs_never_collides :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	id, _ := keystore_test_bridge_ids()
	scope_clean(id)
	defer scope_clean(id)

	// The hostile-hub case: hub B issues the SAME bridge id hub A already gave this machine.
	testing.expect(t, bridge_keystore_set_hub(SCOPE_HUB_A), "bind hub A")
	name_a, _ := keystore_scope_name(id)
	testing.expect(t, test_provision_identity(id, "usr_alice"), "enroll on hub A")
	identity_a := bridge_identity_public_key_hex(id)
	kr := test_keyring_from_hex(TEST_VAULT_KEY_HEX, 1, "usr_alice")
	defer vault.keyring_wipe(&kr)
	ok, _ := keystore_store_vault_keyring(id, test_keyring_bytes(&kr))
	testing.expect(t, ok, "hub A keyring stored")
	bridge_unseal_forget_identity()
	keystore_wipe_in_memory_vault_key()

	testing.expect(t, bridge_keystore_set_hub(SCOPE_HUB_B), "bind hub B")
	name_b, _ := keystore_scope_name(id)
	testing.expect(t, name_a != name_b, "the two hubs name different keystore items")
	rec: Bridge_Identity_Record
	testing.expect_value(t, keystore_read_identity(id, &rec), Keystore_Read_Status.Not_Found)
	_, has_kr := keystore_read_vault_keyring(id)
	testing.expect(t, !has_kr, "hub B cannot read hub A's keyring")
	testing.expect(t, test_provision_identity(id, "usr_mallory"), "a second bridge with the same id enrolls on hub B")
	testing.expect(t, bridge_identity_public_key_hex(id) != identity_a, "it got its own identity")
	bridge_unseal_forget_identity()

	// Hub A's bridge is untouched: same identity, same owner, its keyring intact.
	testing.expect(t, bridge_keystore_set_hub(SCOPE_HUB_A), "rebind hub A")
	testing.expect_value(t, keystore_read_identity(id, &rec), Keystore_Read_Status.Found)
	testing.expect_value(t, bridge_identity_record_owner(&rec), "usr_alice")
	testing.expect_value(t, bridge_identity_record_hub(&rec), "https://hub-a.example.com:443")
	crypto.zero_explicit(&rec, size_of(rec))
	testing.expect_value(t, bridge_identity_public_key_hex(id), identity_a)
	kr_a, has_a := keystore_read_vault_keyring(id)
	testing.expect(t, has_a, "hub A keyring still there")
	vault.keyring_wipe(&kr_a)
	bridge_unseal_forget_identity()

	// A second enrollment into an EXISTING scope refuses instead of overwriting.
	testing.expect(t, !test_provision_identity(id, "usr_alice"), "re-enrolling an existing (hub, id) scope is refused")
	bridge_unseal_forget_identity()
	testing.expect_value(t, keystore_read_identity(id, &rec), Keystore_Read_Status.Found)
	testing.expect_value(t, bridge_identity_public_key_hex(id), identity_a)
	crypto.zero_explicit(&rec, size_of(rec))
}

@(test)
test_scope_record_bound_to_its_hub :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	id, _ := keystore_test_bridge_ids()
	scope_clean(id)
	defer scope_clean(id)

	// A hub-A record copied into hub B's item (a hostile copy) is refused on load.
	testing.expect(t, bridge_keystore_set_hub(SCOPE_HUB_A), "bind hub A")
	testing.expect(t, test_provision_identity(id), "enroll on hub A")
	bridge_unseal_forget_identity()
	raw: [BRIDGE_IDENTITY_RECORD_MAX_BYTES + 1]byte
	defer crypto.zero_explicit(&raw, size_of(raw))
	n, st := keystore_backend_read(.Identity, id, raw[:])
	testing.expect(t, st == .Found && n > 0, "raw record read")
	testing.expect(t, bridge_keystore_set_hub(SCOPE_HUB_B), "bind hub B")
	testing.expect_value(t, keystore_backend_write(.Identity, id, raw[:n]), 0)
	rec: Bridge_Identity_Record
	testing.expect_value(t, keystore_read_identity(id, &rec), Keystore_Read_Status.Error)
	testing.expect(t, bridge_identity_public_key_hex(id) == "", "no identity is used across hubs")
	// No hub bound: nothing is persisted (production) — tests get a fixed test hub.
	testing.expect(t, !bridge_keystore_set_hub("ftp://nope"), "an unusable hub URL binds nothing")
}

@(test)
test_scope_enroll_refuses_another_hubs_config :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sb, ok := bridge_vault_test_sandbox_open(t, "scope-config")
	if !ok do return
	defer bridge_vault_test_sandbox_close(&sb)
	path := fmt.tprintf("%s/.config/heimdall/config.toml", sb.dir)
	id, _ := keystore_test_bridge_ids()
	toml := fmt.tprintf("[wrapper]\ndaemon_url = \"%s\"\n\n[daemon]\ndaemon_id = \"%s\"\n", SCOPE_HUB_A, id)
	testing.expect(t, os.write_entire_file(path, transmute([]byte)toml) == nil, "config written")
	other, conflict := bridge_enroll_config_conflict(path, SCOPE_HUB_B)
	testing.expectf(t, conflict && other == "https://hub-a.example.com:443", "a config of hub A is refused for hub B (%s)", other)
	_, same := bridge_enroll_config_conflict(path, "https://hub-a.example.com:443/")
	testing.expect(t, !same, "re-enrolling the same hub's config is allowed")
	_, none := bridge_enroll_config_conflict(fmt.tprintf("%s/absent.toml", sb.dir), SCOPE_HUB_B)
	testing.expect(t, !none, "a fresh config path is free")
	// A second instance on the same lock file refuses.
	lock := fmt.tprintf("%s/.config/heimdall/config.toml.lock", sb.dir)
	testing.expect(t, bridge_instance_lock(lock), "first instance takes the lock")
	bridge_instance_unlock(lock)
}

// The previous-enrollment backup (reenroll_identity.odin) lives in the same (hub,
// bridge id) scope as the record it keeps: another hub never sees or restores it.
@(test)
test_scope_identity_backup_is_scoped_and_restores_verbatim :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	id, _ := keystore_test_bridge_ids()
	scope_clean(id)
	defer {
		for hub in ([]string{SCOPE_HUB_A, SCOPE_HUB_B}) {
			_ = bridge_keystore_set_hub(hub)
			_ = keystore_identity_backup_drop(id)
		}
		scope_clean(id)
	}

	testing.expect(t, bridge_keystore_set_hub(SCOPE_HUB_A), "bind hub A")
	testing.expect(t, !keystore_identity_backup_create(id), "nothing to back up before an enrollment")
	testing.expect(t, test_provision_identity(id), "enroll on hub A")
	bridge_unseal_forget_identity()
	before := bridge_identity_public_key_hex(id)
	testing.expect(t, keystore_identity_backup_create(id), "back up hub A's enrollment")
	testing.expect_value(t, keystore_identity_backup_status(id), Keystore_Read_Status.Found)
	testing.expect(t, !keystore_identity_backup_create(id), "an existing backup is never overwritten")

	testing.expect(t, bridge_keystore_set_hub(SCOPE_HUB_B), "bind hub B")
	testing.expect_value(t, keystore_identity_backup_status(id), Keystore_Read_Status.Not_Found)
	testing.expect(t, keystore_identity_backup_restore(id), "restoring with no backup is a no-op")
	rec: Bridge_Identity_Record
	testing.expect_value(t, keystore_read_identity(id, &rec), Keystore_Read_Status.Not_Found)
	crypto.zero_explicit(&rec, size_of(rec))

	// Replace hub A's record (as a re-enrollment does), then restore it.
	testing.expect(t, bridge_keystore_set_hub(SCOPE_HUB_A), "bind hub A again")
	_ = keystore_delete_identity_key(id)
	bridge_unseal_forget_identity()
	testing.expect(t, test_provision_identity(id), "the new enrollment's identity")
	bridge_unseal_forget_identity()
	testing.expect(t, bridge_identity_public_key_hex(id) != before, "a new identity replaced the record")
	testing.expect(t, keystore_identity_backup_restore(id), "restore")
	bridge_unseal_forget_identity()
	testing.expect_value(t, bridge_identity_public_key_hex(id), before)
	_, floor_st := keystore_read_epoch_floor(id)
	testing.expect_value(t, floor_st, Keystore_Read_Status.Found)
	testing.expect_value(t, keystore_identity_backup_status(id), Keystore_Read_Status.Not_Found)
}
