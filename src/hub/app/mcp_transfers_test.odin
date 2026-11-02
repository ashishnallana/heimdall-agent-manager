package app

import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import mcp "odin_test:hub/service/mcp"

// Data-path liveness (design §9) must follow the full delegation chain, not only
// the grant row: a revoked family (refresh-theft signal), a revoked client or a
// withdrawn account authority each make every transfer data-path request 401.

@(test)
test_transfer_grant_live_follows_family_client_and_authority :: proc(t: ^testing.T) {
	mcp_task_test_fixture(t, #load("../../../tests/fixtures/mcp_tasks_v2.json", string), false, transfers = true)
}

@(private = "file")
Transfer_Revoke_Op :: struct {kind, id: string, revoked: bool}

@(private = "file")
transfer_set_revoked :: proc(tx: iface.MCP_Transaction, ctx: rawptr) -> domain.Domain_Error {
	op := (^Transfer_Revoke_Op)(ctx)
	row, found, err := tx.get(tx.ctx, op.kind, op.id)
	if err.code != .None do return err
	if !found do return domain.domain_error(.Not_Found, "synthetic record missing")
	row.revoked = op.revoked
	return tx.put(tx.ctx, row)
}

@(private = "file")
transfer_authority_denied :: proc(ctx: rawptr, grant: domain.MCP_Record) -> (bool, domain.Domain_Error) {
	return false, {}
}

mcp_transfer_liveness_test :: proc(t: ^testing.T, g: ^App_Graph, view: mcp.Access_View) {
	x := domain.Mcp_Transfer{owner_user_id = view.owner, grant_id = view.grant, client_id = view.client, family_id = view.family}
	if !testing.expect(t, mcp_transfer_grant_live(g, x), "live delegation must pass") do return
	other := x;other.owner_user_id = "usr_other"
	testing.expect(t, !mcp_transfer_grant_live(g, other), "foreign owner must fail")

	for target in ([]struct {kind, id: string}{{"family", view.family}, {"client", view.client}}) {
		op := Transfer_Revoke_Op{kind = target.kind, id = target.id, revoked = true}
		if !testing.expect(t, iface.mcp_transaction(&g.mcp_repository, transfer_set_revoked, &op).code == .None) do return
		testing.expectf(t, !mcp_transfer_grant_live(g, x), "revoked %s must fail data-path liveness", target.kind)
		op.revoked = false
		if !testing.expect(t, iface.mcp_transaction(&g.mcp_repository, transfer_set_revoked, &op).code == .None) do return
		testing.expectf(t, mcp_transfer_grant_live(g, x), "restored %s is live again", target.kind)
	}

	saved := g.mcp_delegation.authority
	g.mcp_delegation.authority = transfer_authority_denied
	testing.expect(t, !mcp_transfer_grant_live(g, x), "withdrawn account authority must fail")
	g.mcp_delegation.authority = saved
	testing.expect(t, mcp_transfer_grant_live(g, x))

	_ = mcp.delegation_revoke(&g.mcp_delegation, view.owner, view.grant)
	testing.expect(t, !mcp_transfer_grant_live(g, x), "revoked grant must fail")
}
