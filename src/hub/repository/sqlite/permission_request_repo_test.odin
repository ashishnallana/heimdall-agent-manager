package sqlite

import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// REQ-EXT-PERM-1: permission_requests storage — insert/get/list filters, the
// pending-only compare-and-set, and bulk close by instance or by deadline.

@(private = "file")
perm_repo_setup :: proc(t: ^testing.T, conn: ^Conn, impl: ^Agent_Repo_SQLite) -> (iface.Agent_Repository, bool) {
	opened, ok := tmpl_clone_migrated(t)
	conn^ = opened
	if !ok do return {}, false
	return new_agent_repository(impl, conn), true
}

@(private = "file")
perm_row :: proc(id, instance_id: string, expires_at := "2026-10-22T10:05:00Z", owner := "owner") -> domain.Permission_Request {
	return domain.Permission_Request{id = id, owner_user_id = domain.User_ID(owner), instance_id = instance_id, chain_id = "chain_1", tool_name = "Bash", input = `{"command":"ls"}`, suggestions = "[]", status = "pending", created_at = "2026-10-22T10:00:00Z", expires_at = expires_at}
}

@(test)
test_permission_request_repo_cas_and_filters :: proc(t: ^testing.T) {
	conn: Conn
	impl: Agent_Repo_SQLite
	repo, ok := perm_repo_setup(t, &conn, &impl)
	defer close(&conn)
	if !ok do return

	testing.expect_value(t, iface.agent_perm_insert(&repo, perm_row("perm_a", "inst_1")).code, domain.Error_Code.None)
	testing.expect_value(t, iface.agent_perm_insert(&repo, perm_row("perm_b", "inst_1")).code, domain.Error_Code.None)
	testing.expect_value(t, iface.agent_perm_insert(&repo, perm_row("perm_c", "inst_2", owner = "other")).code, domain.Error_Code.None)
	testing.expect_value(t, iface.agent_perm_insert(&repo, perm_row("perm_a", "inst_1")).code, domain.Error_Code.Conflict)

	got, found, _ := iface.agent_perm_get(&repo, "perm_a")
	testing.expect(t, found)
	testing.expect_value(t, got.input, `{"command":"ls"}`)
	testing.expect_value(t, got.status, "pending")

	mine, _ := iface.agent_perm_list(&repo, domain.Permission_Request_Filter{owner_user_id = "owner", status = "pending"})
	testing.expect_value(t, len(mine), 2)
	by_chain, _ := iface.agent_perm_list(&repo, domain.Permission_Request_Filter{owner_user_id = "owner", chain_id = "chain_1", instance_id = "inst_1"})
	testing.expect_value(t, len(by_chain), 2)

	// CAS: the first close wins, the second changes nothing.
	changed, err := iface.agent_perm_close(&repo, "perm_a", "allowed", "owner", "ok", "2026-10-22T10:01:00Z")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect(t, changed)
	changed2, _ := iface.agent_perm_close(&repo, "perm_a", "denied", "owner", "", "2026-10-22T10:01:01Z")
	testing.expect(t, !changed2)
	got2, _, _ := iface.agent_perm_get(&repo, "perm_a")
	testing.expect_value(t, got2.status, "allowed")
	testing.expect_value(t, got2.decided_by, "owner")
}

@(test)
test_permission_request_repo_close_pending :: proc(t: ^testing.T) {
	conn: Conn
	impl: Agent_Repo_SQLite
	repo, ok := perm_repo_setup(t, &conn, &impl)
	defer close(&conn)
	if !ok do return
	_ = iface.agent_perm_insert(&repo, perm_row("perm_due", "inst_1", expires_at = "2026-10-22T10:01:00Z"))
	_ = iface.agent_perm_insert(&repo, perm_row("perm_later", "inst_1", expires_at = "2026-10-22T10:30:00Z"))
	_ = iface.agent_perm_insert(&repo, perm_row("perm_other", "inst_2", expires_at = "2026-10-22T10:30:00Z"))

	expired, err := iface.agent_perm_close_pending(&repo, "", "2026-10-22T10:02:00Z", "expired", "2026-10-22T10:02:00Z")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, len(expired), 1)
	if len(expired) == 1 {
		testing.expect_value(t, expired[0].id, "perm_due")
		testing.expect_value(t, expired[0].status, "expired")
	}
	cancelled, _ := iface.agent_perm_close_pending(&repo, "inst_1", "", "cancelled", "2026-10-22T10:03:00Z")
	testing.expect_value(t, len(cancelled), 1)
	if len(cancelled) == 1 do testing.expect_value(t, cancelled[0].id, "perm_later")
	other, _, _ := iface.agent_perm_get(&repo, "perm_other")
	testing.expect_value(t, other.status, "pending")
	// Already-closed rows are never reopened or re-reported.
	again, _ := iface.agent_perm_close_pending(&repo, "inst_1", "", "cancelled", "2026-10-22T10:04:00Z")
	testing.expect_value(t, len(again), 0)
}
