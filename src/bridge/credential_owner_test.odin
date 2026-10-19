package main

// Credential file ownership (credential_owner.odin): per-(hub, bridge) default path,
// owner header, and the overwrite / startup refusals. Hermetic: inside the vault sandbox.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_credential_file_is_per_bridge_and_records_its_owner :: proc(t: ^testing.T) {
	sb, ok := bridge_vault_test_sandbox_open(t, "cred-owner")
	if !ok do return
	defer bridge_vault_test_sandbox_close(&sb)
	a, b := keystore_test_bridge_ids()
	hub1, hub2 := "https://hub-one.example.test", "https://hub-two.example.test:8443/x"

	// The default path is per (hub, bridge id) scope, under the private state dir.
	pa1 := bridge_enroll_default_credential_path(hub1, a, context.temp_allocator)
	pb1 := bridge_enroll_default_credential_path(hub1, b, context.temp_allocator)
	pa2 := bridge_enroll_default_credential_path(hub2, a, context.temp_allocator)
	testing.expect(t, pa1 != "" && pa1 != pb1 && pa1 != pa2 && pb1 != pa2, "one default credential path per (hub, bridge)")
	testing.expect(t, strings.has_prefix(pa1, sb.dir) && strings.has_suffix(pa1, "/bridge-token"), pa1)
	testing.expect_value(t, bridge_enroll_default_credential_path(hub1, "local-daemon", context.temp_allocator), "")
	explicit := bridge_enroll_token_file_from_args([]string{"ham-bridge", "enroll", "--bridge-token-file", "/tmp/explicit-cred"}, hub1, a, context.temp_allocator)
	testing.expect_value(t, explicit, "/tmp/explicit-cred")
	testing.expect_value(t, bridge_enroll_token_file_from_args([]string{"ham-bridge", "enroll"}, hub1, a, context.temp_allocator), pa1)
	testing.expect_value(t, bridge_enroll_token_file_from_args([]string{"ham-bridge", "enroll"}, "", "", context.temp_allocator), "")

	// The access-token file names its owner; the token reads back without the header.
	shared := fmt.tprintf("%s/shared-token", sb.dir)
	testing.expect(t, bridge_write_credential_file(shared, hub1, a, "hba_a.secret"), "write A's credential")
	token, read_ok := bridge_read_token_file(shared)
	defer delete(token)
	testing.expect(t, read_ok && token == "hba_a.secret", token)
	testing.expect(t, bridge_credential_file_belongs_to(shared, hub1, a), "owned by (hub1, A)")
	testing.expect(t, !bridge_credential_file_belongs_to(shared, hub2, a) && !bridge_credential_file_belongs_to(shared, hub1, b), "not by another hub or bridge")
	testing.expect(t, !bridge_write_credential_file(shared, hub1, "local-daemon", "hba_x.secret"), "no credential without an enrolled owner")

	// Enrolling bridge B over A's file is refused; re-enrolling the config's own bridge is not.
	_, conflict_b := bridge_enroll_token_file_conflict(shared, hub1, "")
	_, conflict_hub := bridge_enroll_token_file_conflict(shared, hub2, a)
	_, conflict_same := bridge_enroll_token_file_conflict(shared, hub1, a)
	_, conflict_missing := bridge_enroll_token_file_conflict(fmt.tprintf("%s/none", sb.dir), hub1, "")
	testing.expect(t, conflict_b && conflict_hub && !conflict_same && !conflict_missing, "overwrite refused unless it is the same bridge of the same hub")
	bare := fmt.tprintf("%s/bare-token", sb.dir)
	testing.expect(t, bridge_write_secret_file(bare, "hba_bare.secret"), "write a header-less token")
	_, conflict_bare := bridge_enroll_token_file_conflict(bare, hub1, a)
	testing.expect(t, conflict_bare && !bridge_credential_file_belongs_to(bare, hub1, a), "a file without an owner record is never adopted or overwritten")
	_ = os.remove(shared)
	_ = os.remove(bare)
}
