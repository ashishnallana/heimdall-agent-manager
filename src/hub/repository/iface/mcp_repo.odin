package iface

import domain "odin_test:hub/domain"

// Every operation, including reads, runs in transaction. Implementations supply
// a dedicated connection and serialize BEGIN IMMEDIATE through commit/rollback.
// Callback work is synchronous: no network calls or external effects under it.
MCP_Transaction :: struct {
	ctx: rawptr,
	get: proc(ctx: rawptr, kind, id: string) -> (domain.MCP_Record, bool, domain.Domain_Error),
	put: proc(ctx: rawptr, row: domain.MCP_Record) -> domain.Domain_Error,
	remove: proc(ctx: rawptr, kind, id: string) -> domain.Domain_Error,
	list: proc(ctx: rawptr, kind, owner: string) -> ([]domain.MCP_Record, domain.Domain_Error),
}
MCP_Transaction_Proc :: proc(tx: MCP_Transaction, ctx: rawptr) -> domain.Domain_Error
MCP_Repository :: struct {
	ctx: rawptr,
	transaction: proc(ctx: rawptr, run: MCP_Transaction_Proc, run_ctx: rawptr) -> domain.Domain_Error,
}

mcp_transaction :: proc(repo: ^MCP_Repository, run: MCP_Transaction_Proc, run_ctx: rawptr) -> domain.Domain_Error {
	if repo == nil || repo.transaction == nil do return domain.domain_error(.Internal_Error, "MCP persistence unavailable")
	return repo.transaction(repo.ctx, run, run_ctx)
}
