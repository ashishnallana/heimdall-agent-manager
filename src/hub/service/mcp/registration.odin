package mcp

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import auth "odin_test:hub/service/auth"

Public_Operation :: struct {
	action, kind, id, owner: string,
	row: domain.MCP_Record,
	rows: []domain.MCP_Record,
	found: bool,
	now: i64,
}
public_transaction :: proc(tx: iface.MCP_Transaction, ctx: rawptr) -> domain.Domain_Error {
	op := (^Public_Operation)(ctx)
	if op.action == "get" {
		r, found, err := tx.get(tx.ctx, op.kind, op.id)
		op.row = r; op.found = found
		return err
	}
	if op.action == "list" {
		rows, err := tx.list(tx.ctx, op.kind, op.owner)
		op.rows = rows
		return err
	}
	if op.action == "register" {
		rows, err := tx.list(tx.ctx, "client", "")
		if err.code != .None do return err
		if len(rows) >= LIMIT do return domain.domain_error(.Rate_Limited, "MCP client registration capacity reached")
		return tx.put(tx.ctx, op.row)
	}
	if op.action == "pending" {
		client, found, err := tx.get(tx.ctx, "client", op.row.client)
		if err.code != .None do return err
		if !found || client.revoked || client.redirect != op.row.redirect do return domain.domain_error(.Forbidden, "invalid OAuth client binding")
		rows, perr := tx.list(tx.ctx, "pending", op.row.owner)
		if perr.code != .None do return perr
		live := 0
		for row in rows {
			if row.expires_ms <= op.now || row.consumed {
				if re := tx.remove(tx.ctx, "pending", row.id); re.code != .None do return re
			} else {live += 1}
		}
		if live >= 16 do return domain.domain_error(.Rate_Limited, "too many pending connector requests")
		return tx.put(tx.ctx, op.row)
	}
	return domain.domain_error(.Internal_Error, "unknown MCP metadata operation")
}

delegation_read :: proc(s: ^Delegation_Service, kind, id: string) -> (domain.MCP_Record, bool, domain.Domain_Error) {
	op := Public_Operation{action = "get", kind = kind, id = id}
	err := iface.mcp_transaction(s.repo, public_transaction, &op)
	return op.row, op.found, err
}
delegation_grants :: proc(s: ^Delegation_Service, owner: string) -> ([]domain.MCP_Record, domain.Domain_Error) {
	op := Public_Operation{action = "list", kind = "grant", owner = owner}
	err := iface.mcp_transaction(s.repo, public_transaction, &op)
	return op.rows, err
}
delegation_register :: proc(s: ^Delegation_Service, redirect: string) -> (string, domain.Domain_Error) {
	if !redirect_ok(redirect) do return "", domain.domain_error(.Validation_Failed, "HTTPS redirect required")
	id, ok := auth.random_token()
	if !ok do return "", domain.domain_error(.Internal_Error, "MCP entropy unavailable")
	op := Public_Operation{action = "register", row = {kind = "client", id = id, redirect = redirect}}
	err := iface.mcp_transaction(s.repo, public_transaction, &op)
	if err.code != .None do return "", err
	return id, domain.Domain_Error{}
}
delegation_begin :: proc(s: ^Delegation_Service, owner, client, redirect, challenge, state: string, now: i64, scope: string = DELEGATION_SCOPE) -> (string, domain.Domain_Error) {
	if owner == "" || !scopes_valid(scope) || !challenge_ok(challenge) || len(state) > 1024 do return "", domain.domain_error(.Validation_Failed, "invalid OAuth request")
	ticket, tok := auth.random_token()
	grant, gok := auth.random_token()
	family, fok := auth.random_token()
	if !tok || !gok || !fok do return "", domain.domain_error(.Internal_Error, "MCP entropy unavailable")
	p := domain.MCP_Record{kind = "pending", id = auth.sha256_hex(ticket), owner = owner, client = client, redirect = redirect, challenge = challenge, oauth_state = state, resource = s.resource, scope = scope, grant = grant, family = family, revision = 1, created_ms = now, expires_ms = now+300_000}
	op := Public_Operation{action = "pending", row = p, now = now}
	err := iface.mcp_transaction(s.repo, public_transaction, &op)
	if err.code != .None do return "", err
	return ticket, domain.Domain_Error{}
}
