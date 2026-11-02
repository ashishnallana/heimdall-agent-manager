package app

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import mcp "odin_test:hub/service/mcp"
import vault "odin_test:lib/vault"

// E2EE artifact transfer wiring (docs/plans/mcp-large-artifact-transfers.md §5.2).
// The transfer service gets PUBLIC directory data only (verified through the
// transfer's grant); no keyring, hosted path or device job is wired to it.

mcp_transfers_init :: proc(graph: ^App_Graph) -> bool {
	conn, ok, _ := sqlite.open(graph.config.database_path, .Other)
	if !ok do return false
	graph.mcp_transfer_conn = conn
	graph.mcp_transfer_repo = sqlite.new_transfer_repository(&graph.mcp_transfer_repo_impl, &graph.mcp_transfer_conn)
	graph.mcp_transfer_service = mcp.Transfer_Service{repo = &graph.mcp_transfer_repo, directory = mcp_transfer_directory, directory_ctx = graph}
	// Browser executor auth reuses the delegation handlers' session auth, origin and
	// vault directory (filled by configure_mcp_delegation; held by pointer).
	graph.mcp_transfer_handlers = {svc = &graph.mcp_transfer_service, grant_live = mcp_transfer_grant_live, grant_ctx = graph, delegation = &graph.mcp_delegation_handlers}
	return true
}

@(private = "file")
Transfer_Directory_Op :: struct {
	graph:    ^App_Graph,
	owner:    string,
	grant_id: string,
	dir:      ^vault.Verified_Directory,
	ok:       bool,
}

@(private = "file")
transfer_directory_tx :: proc(tx: iface.MCP_Transaction, ctx: rawptr) -> domain.Domain_Error {
	op := (^Transfer_Directory_Op)(ctx)
	g, found, err := tx.get(tx.ctx, "grant", op.grant_id)
	if err.code != .None do return err
	if !found || g.owner != op.owner || g.revoked do return {}
	// Full delegation liveness (design §9): the grant's family and client must
	// not be revoked (refresh-theft revokes only the family) and the account
	// authority must still hold, else every data-path request fails 401.
	live, lerr := mcp.delegation_live(&op.graph.mcp_delegation, tx, mcp.grant_claim_bindings(g))
	if lerr.code != .None do return lerr
	if !live do return {}
	dir, verified, verr := mcp.verified_grant_directory(&op.graph.mcp_vault_view, g)
	if verr.code != .None || !verified do return {}
	op.dir = new_clone(dir, context.temp_allocator)
	op.ok = true
	return {}
}

// mcp_transfer_directory verifies the owner's device directory through the
// transfer's grant (a revoked or foreign grant yields nothing).
mcp_transfer_directory :: proc(user: rawptr, owner, grant_id: string) -> (^vault.Verified_Directory, bool) {
	graph := (^App_Graph)(user)
	if graph == nil || owner == "" || grant_id == "" do return nil, false
	op := Transfer_Directory_Op{graph = graph, owner = owner, grant_id = grant_id}
	if err := iface.mcp_transaction(&graph.mcp_repository, transfer_directory_tx, &op); err.code != .None do return nil, false
	return op.dir, op.ok
}

// mcp_transfer_grant_live: the transfer's grant still exists for its owner, its
// grant/family/client are unrevoked, the account authority holds and its
// directory still verifies.
mcp_transfer_grant_live :: proc(ctx: rawptr, x: domain.Mcp_Transfer) -> bool {
	_, ok := mcp_transfer_directory(ctx, x.owner_user_id, x.grant_id)
	return ok
}
