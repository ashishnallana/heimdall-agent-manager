package mcp

import "core:crypto"
import "core:encoding/json"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import auth "odin_test:hub/service/auth"
import platform "odin_test:hub/platform"

DELEGATION_SCOPE :: "mcp:chains"
REFRESH_RETRY_MS :: 30_000
REFRESH_DUPLICATES :: 3

Delegation_Service :: struct {
	repo: ^iface.MCP_Repository,
	keys: []Envelope_Key, // current key first, explicitly supported prior keys after
	issuer, resource: string,
	clock: ^platform.Clock,
	authority_ctx: rawptr,
	authority: proc(ctx: rawptr, grant: domain.MCP_Record) -> (bool, domain.Domain_Error),
}

Delegation_Result :: struct {
	response: string, // exact serialized token response, request-owned; never log
	error: string,
	claims: Credential_Claims,
}

delegation_binding :: proc(c: Credential_Claims, row: domain.MCP_Record) -> bool {
	return c.owner == row.owner && c.client == row.client && c.resource == row.resource && c.scope == row.scope && c.grant == row.grant && c.family == row.family && c.vault_id == row.vault_id && c.recipient == row.recipient && c.revision == row.revision
}

credential_metadata :: proc(c: Credential_Claims, raw: string) -> domain.MCP_Record {
	return {kind = c.kind, id = auth.sha256_hex(raw), owner = c.owner, client = c.client, resource = c.resource, scope = c.scope, grant = c.grant, family = c.family, vault_id = c.vault_id, recipient = c.recipient, revision = c.revision, created_ms = c.issued_ms, expires_ms = c.expires_ms, redirect = c.redirect, challenge = c.challenge}
}

delegation_claims_ok :: proc(s: ^Delegation_Service, c: Credential_Claims, client: string, now: i64) -> bool {
	return s != nil && len(s.keys) > 0 && c.issuer == s.issuer && c.client == client && c.resource == s.resource && scopes_valid(c.scope) && c.owner != "" && c.vault_id != "" && c.grant != "" && c.family != "" && c.revision > 0 && c.jti != "" && c.issued_ms <= now && c.issued_ms > 0
}

// Caller runs under the repository transaction. Envelope authentication has
// already succeeded; invalid inputs cannot choose a victim family to revoke.
delegation_live :: proc(s: ^Delegation_Service, tx: iface.MCP_Transaction, c: Credential_Claims) -> (bool, domain.Domain_Error) {
	g, gf, ge := tx.get(tx.ctx, "grant", c.grant)
	if ge.code != .None do return false, ge
	f, ff, fe := tx.get(tx.ctx, "family", c.family)
	if fe.code != .None do return false, fe
	client, cf, ce := tx.get(tx.ctx, "client", c.client)
	if ce.code != .None do return false, ce
	if !cf || client.revoked do return false, domain.Domain_Error{}
	if !gf || !ff || g.revoked || f.revoked || !delegation_binding(c, g) || !delegation_binding(c, f) || s.authority == nil do return false, domain.Domain_Error{}
	return s.authority(s.authority_ctx, g)
}

Token_Operation :: struct {
	service: ^Delegation_Service,
	raw, client, redirect, verifier: string,
	now: i64,
	claims: Credential_Claims,
	result: Delegation_Result,
}

// token_response prepares both envelopes and their metadata before changing any
// durable rows. Transaction rollback includes every partial write on failure.
delegation_issue :: proc(tx: iface.MCP_Transaction, s: ^Delegation_Service, parent: Credential_Claims, now: i64) -> (string, string, domain.Domain_Error) {
	c := parent
	c.issued_ms = now; c.redirect = ""; c.challenge = ""
	at_jti, aok := auth.random_token()
	rt_jti, rok := auth.random_token()
	if !aok || !rok do return "", "", domain.domain_error(.Internal_Error, "MCP entropy unavailable")
	c.kind = "access"; c.jti = at_jti; c.expires_ms = now + ACCESS_TTL
	at, at_ok := credential_seal(&s.keys[0], c)
	if !at_ok do return "", "", domain.domain_error(.Internal_Error, "MCP sealing unavailable")
	at_row := credential_metadata(c, at)
	c.kind = "refresh"; c.jti = rt_jti; c.expires_ms = 0 // explicit-revocation lifetime
	rt, rt_ok := credential_seal(&s.keys[0], c)
	if !rt_ok do return "", "", domain.domain_error(.Internal_Error, "MCP sealing unavailable")
	rt_row := credential_metadata(c, rt)
	encoded, enc_err := json.marshal(Tokens{at, rt, "Bearer", int(ACCESS_TTL/1000), parent.scope}, allocator = context.temp_allocator)
	if enc_err != nil do return "", "", domain.domain_error(.Internal_Error, "MCP response encoding unavailable")
	if err := tx.put(tx.ctx, at_row); err.code != .None do return "", "", err
	if err := tx.put(tx.ctx, rt_row); err.code != .None do return "", "", err
	return string(encoded), rt_row.id, domain.Domain_Error{}
}

retry_binding :: proc(row: domain.MCP_Record) -> Retry_Binding {
	return {row.owner, row.client, row.resource, row.grant, row.family, row.id, row.child_hash, row.revision, row.retry_deadline_ms}
}

delegation_token_transaction :: proc(tx: iface.MCP_Transaction, ctx: rawptr) -> domain.Domain_Error {
	op := (^Token_Operation)(ctx)
	c := op.claims
	op.result.error = "invalid_grant"
	row, found, err := tx.get(tx.ctx, c.kind, auth.sha256_hex(op.raw))
	if err.code != .None do return err
	if !found || !delegation_binding(c, row) do return {}
	live, live_err := delegation_live(op.service, tx, c)
	if live_err.code != .None do return live_err
	if !live do return {}
	if c.kind == "access" {
		if c.expires_ms <= op.now || row.expires_ms != c.expires_ms do return {}
		op.result = {claims = c}
		return {}
	}
	if c.kind == "code" {
		if row.consumed || c.expires_ms <= op.now || c.redirect != op.redirect || c.challenge != auth.pkce_challenge_s256(op.verifier) || row.redirect != c.redirect || row.challenge != c.challenge do return {}
	} else if row.consumed {
		if op.now >= row.retry_deadline_ms {
			// Valid authenticated consumed refresh after grace revokes only this
			// family. Commit the revocation while returning OAuth invalid_grant.
			family, _, ferr := tx.get(tx.ctx, "family", c.family)
			if ferr.code != .None do return ferr
			family.revoked = true
			if re := tx.put(tx.ctx, family); re.code != .None do return re
			return delegation_clear_capsules(tx, c.owner, c.family, "")
		}
		if row.retry_count >= REFRESH_DUPLICATES {
			op.result.error = "temporarily_unavailable"
			return {}
		}
		plain, opened := retry_open(op.raw, retry_binding(row), row.retry_capsule)
		if !opened {
			op.result.error = "temporarily_unavailable"
			return {}
		}
		// The request owns this decrypted response through transmission.
		row.retry_count += 1
		if re := tx.put(tx.ctx, row); re.code != .None do return re
		op.result = {response = string(plain)}
		return {}
	}
	response, child, issue_err := delegation_issue(tx, op.service, c, op.now)
	if issue_err.code != .None do return issue_err
	row.consumed = true
	if c.kind == "refresh" {
		row.child_hash = child
		row.retry_deadline_ms = op.now + REFRESH_RETRY_MS
		capsule, sealed := retry_seal(op.raw, retry_binding(row), transmute([]byte)response)
		if !sealed do return domain.domain_error(.Internal_Error, "MCP retry sealing unavailable")
		row.retry_capsule = capsule
	}
	if re := tx.put(tx.ctx, row); re.code != .None do return re
	op.result = {response = response}
	return {}
}

// Remove response ciphertexts on revocation, or after their deadline during
// maintenance. Consumed parent hashes remain tombstones for replay detection.
delegation_clear_capsules :: proc(tx: iface.MCP_Transaction, owner, family, grant: string, expired_before: i64 = 0) -> domain.Domain_Error {
	rows, err := tx.list(tx.ctx, "refresh", owner)
	if err.code != .None do return err
	for row in rows {
		if row.retry_capsule == "" do continue
		if (family != "" && row.family != family) || (grant != "" && row.grant != grant) do continue
		if expired_before > 0 && row.retry_deadline_ms > expired_before do continue
		r := row; r.retry_capsule = ""
		if re := tx.put(tx.ctx, r); re.code != .None do return re
	}
	return {}
}

delegation_redeem :: proc(s: ^Delegation_Service, raw, kind, client, redirect, verifier: string, now: i64) -> Delegation_Result {
	if s == nil || len(s.keys) == 0 do return {error = "temporarily_unavailable"}
	c, opened := credential_open(s.keys, raw, kind)
	if !opened do return {error = "invalid_grant"}
	defer credential_claims_wipe(&c)
	if !delegation_claims_ok(s, c, client, now) do return {error = "invalid_grant"}
	if kind == "code" && (len(verifier) < 43 || len(verifier) > 128) do return {error = "invalid_grant"}
	op := Token_Operation{service = s, raw = raw, client = client, redirect = redirect, verifier = verifier, now = now, claims = c}
	err := iface.mcp_transaction(s.repo, delegation_token_transaction, &op)
	if err.code != .None do return {error = "temporarily_unavailable"}
	// Access validation must return request-owned capability without wiping it
	// through c's deferred cleanup; other calls only return response envelopes.
	if kind == "access" && op.result.error == "" {
		c.private_capability = ""
	}
	return op.result
}

Revoke_Operation :: struct {owner, grant: string}
delegation_revoke_transaction :: proc(tx: iface.MCP_Transaction, ctx: rawptr) -> domain.Domain_Error {
	op := (^Revoke_Operation)(ctx)
	grant, found, err := tx.get(tx.ctx, "grant", op.grant)
	if err.code != .None do return err
	if !found || grant.owner != op.owner do return domain.domain_error(.Not_Found, "connector not found")
	grant.revoked = true
	if re := tx.put(tx.ctx, grant); re.code != .None do return re
	return delegation_clear_capsules(tx, op.owner, "", op.grant)
}
delegation_revoke :: proc(s: ^Delegation_Service, owner, grant: string) -> domain.Domain_Error {
	op := Revoke_Operation{owner, grant}
	return iface.mcp_transaction(s.repo, delegation_revoke_transaction, &op)
}

delegation_response_wipe :: proc(result: ^Delegation_Result) {
	if result.response != "" do crypto.zero_explicit(raw_data(result.response), len(result.response))
	credential_claims_wipe(&result.claims)
	result.response = ""
}
