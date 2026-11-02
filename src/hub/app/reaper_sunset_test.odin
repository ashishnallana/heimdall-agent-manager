package app

import "core:testing"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import bridge_service "odin_test:hub/service/bridge"

@(private = "file")
Reset_Sunset_Fixture :: struct {
	// Repository callbacks receive &impl, also the address of this fixture.
	impl: sqlite.Bridge_Repo_SQLite,
	repo: iface.Bridge_Repository,
	graph: App_Graph,
	replacement: bridge_service.Enroll_Bridge_Result,
	list_pending: iface.Bridge_List_Pending_Proc,
	rollback_ok: bool,
}

@(private = "file")
reset_sunset_rollback_between_passes :: proc(ctx: rawptr) -> ([]domain.Bridge, domain.Domain_Error) {
	f := (^Reset_Sunset_Fixture)(ctx)
	_, removed, err := bridge_service.rollback_pending_enrollment(&f.graph.bridges, f.replacement.bridge.bridge_id, f.replacement.family_id)
	f.rollback_ok = removed && err.code == .None
	return f.list_pending(ctx)
}

// Deterministically cancel the replacement after the enrolled-row snapshot, but
// before reset lists pending enrollments. Reset must have killed rollback authority.
@(test)
test_vault_reset_invalidates_sunset_receipt_before_pending_pass :: proc(t: ^testing.T) {
	conn, opened, _ := sqlite.open(":memory:")
	if !testing.expect(t, opened) do return
	defer sqlite.close(&conn)
	migrated, _ := sqlite.run_migrations(&conn)
	if !testing.expect(t, migrated) do return
	f := new(Reset_Sunset_Fixture)
	defer free(f)
	f.repo = sqlite.new_bridge_repository(&f.impl, &conn)
	clock := platform.real_clock()
	ids := platform.real_id_generator()
	f.graph.bridges = bridge_service.new_bridge_service(&f.repo, &clock, &ids)
	old, old_ok, old_err := bridge_service.enroll_bridge_from_device_grant(&f.graph.bridges, {
		owner_user_id = "reset_owner", bridge_public_key = "04aabb",
	})
	if !testing.expect(t, old_ok, old_err.message) do return
	replacement, enrolled, enroll_err := bridge_service.enroll_bridge_from_device_grant(&f.graph.bridges, {
		owner_user_id = "reset_owner", bridge_public_key = "04ccdd",
		pending = true, sunset_bridge_id = old.bridge.bridge_id,
	})
	if !testing.expect(t, enrolled, enroll_err.message) do return
	f.replacement = replacement
	f.list_pending = f.repo.list_pending
	f.repo.list_pending = reset_sunset_rollback_between_passes
	testing.expect(t, reaper_revoke_all_bridges(&f.graph, "reset_owner"))
	testing.expect(t, f.rollback_ok, "replacement rolled back between reset passes")
	b, found, err := iface.bridge_get_bridge(&f.repo, old.bridge.bridge_id)
	if !testing.expect(t, found && err.code == .None) do return
	defer domain.bridge_destroy(&b)
	testing.expect(t, b.status == .Revoked, "reset bridge cannot be restored by concurrent cancellation")
	_, access_ok, access_err := bridge_service.verify_bridge_token(&f.graph.bridges, old.bridge_token)
	testing.expect(t, !access_ok && access_err.code == .Forbidden)
	_, refresh_ok, refresh_err := bridge_service.refresh_bridge_token(&f.graph.bridges, old.refresh_token)
	testing.expect(t, !refresh_ok && refresh_err.code == .Unauthenticated)
}
