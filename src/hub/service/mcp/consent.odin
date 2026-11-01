package mcp

import "core:crypto"
import "core:crypto/ecdh"
import "core:encoding/json"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import auth "odin_test:hub/service/auth"
import vd "odin_test:hub/service/vault_directory"
import vault "odin_test:lib/vault"

// Canonical fixed-order JSON, signed by an already-approved user device. This
// grants no device/directory signing authority. Both runtimes render all fields.
Consent :: vault.Control_Consent
CONSENT_DOMAIN :: "heimdall-mcp-consent/v1\n"
consent_message :: proc(canonical: string) -> string {
	c:Consent
	if json.unmarshal_string(canonical,&c,.JSON,context.temp_allocator)!=nil || c.v!=consent_version(c.scope) || c.v==0 do return ""
	return strings.concatenate({vault.control_consent_domain(c.v),canonical},context.temp_allocator)
}

Consent_Input :: struct {
	request, consent, signature, wrap_json, private_capability: string,
}

// An approved grant is revoked by disconnect, directory reset, client/account
// revocation, or loss of its approving device. Call under the MCP write lock.
delegation_vault_authority :: proc(ctx: rawptr, grant: domain.MCP_Record) -> (bool, domain.Domain_Error) {
	c:Consent
	if json.unmarshal(transmute([]byte)grant.consent,&c,.JSON,context.temp_allocator)!=nil do return false,domain.Domain_Error{}
	if c.v==0 || c.v!=consent_version(c.scope) || c.owner!=grant.owner || c.vault_id!=grant.vault_id || c.client!=grant.client || c.resource!=grant.resource || c.scope!=grant.scope || c.grant!=grant.grant || c.family!=grant.family || c.revision!=grant.revision || c.recipient!=grant.recipient || c.recipient_public_key!=grant.recipient_public_key || c.mode!=grant.mode || c.approver!=grant.approver do return false,domain.Domain_Error{}
	directory := (^vd.Service)(ctx)
	view, err := vd.get_directory(directory, grant.owner)
	if err.code == .Not_Found do return false, domain.Domain_Error{}
	if err.code != .None do return false, err
	vid, ok := vault.vault_id_from_root_sign_pub(view.root_sign_public_key)
	buf: [16]byte
	if !ok || vault.vault_id_hex(vid, buf[:]) != grant.vault_id do return false, domain.Domain_Error{}
	for device in view.devices {
		if device.device_id == grant.approver && device.status == .Approved && domain.vault_kind_policy(device.kind).can_approve {
			return vault.verify(device.sign_alg, device.sign_public_key, transmute([]byte)consent_message(grant.consent), grant.signature), domain.Domain_Error{}
		}
	}
	return false, domain.Domain_Error{}
}

// Verify the scalar corresponds to the signed public recipient before it can be
// packaged in a credential. No root/device private material is accepted here.
consent_capability_ok :: proc(scalar, public_key: string) -> bool {
	if len(scalar) != 64 || !vault.is_lower_hex(scalar) || !vault.valid_p256_public_key(public_key) do return false
	raw: [32]byte
	defer crypto.zero_explicit(&raw, size_of(raw))
	if !vault.hex_decode_into(raw[:], scalar) do return false
	priv: ecdh.Private_Key
	defer ecdh.private_key_clear(&priv)
	if !ecdh.private_key_set_bytes(&priv, .SECP256R1, raw[:]) do return false
	pub: [65]byte
	ecdh.private_key_public_bytes(&priv, pub[:])
	return vault.hex_encode_lower(pub[:], context.temp_allocator) == public_key
}

Consent_Operation :: struct {
	service: ^Delegation_Service,
	vault: ^vd.Service,
	input: Consent_Input,
	owner, signer: string,
	now: i64,
	code, redirect, state: string,
}

consent_transaction :: proc(tx: iface.MCP_Transaction, ctx: rawptr) -> domain.Domain_Error {
	op := (^Consent_Operation)(ctx)
	p, found, err := tx.get(tx.ctx, "pending", auth.sha256_hex(op.input.request))
	if err.code != .None do return err
	if !found || p.owner != op.owner || p.consumed || p.expires_ms <= op.now do return domain.domain_error(.Forbidden, "consent request expired")
	c: Consent
	if json.unmarshal(transmute([]byte)op.input.consent, &c, .JSON, context.temp_allocator) != nil do return domain.domain_error(.Validation_Failed, "malformed connector consent")
	canonical, enc_err := json.marshal(c, allocator = context.temp_allocator)
	if enc_err != nil || string(canonical) != op.input.consent do return domain.domain_error(.Validation_Failed, "noncanonical connector consent")
	if c.v == 0 || c.v != consent_version(c.scope) || !scope_subset(c.scope,p.scope) || c.owner != op.owner || c.approver != op.signer || c.client != p.client || c.resource != op.service.resource || c.grant != p.grant || c.family != p.family || c.revision != 1 || c.issued_ms > op.now+30_000 || c.issued_ms < op.now-120_000 do return domain.domain_error(.Forbidden, "connector consent binding mismatch")
	// The write lock prevents directory writers from revoking the signer/resetting
	// the vault between this authority read and the consent commit.
	view, verr := vd.get_directory(op.vault, op.owner)
	if verr.code != .None do return verr
	vid, vok := vault.vault_id_from_root_sign_pub(view.root_sign_public_key)
	vid_buf: [16]byte
	if !vok || c.vault_id != vault.vault_id_hex(vid, vid_buf[:]) || c.directory_version != view.directory.version || c.directory_head != view.directory.head_hash || c.epoch != view.directory.current_epoch do return domain.domain_error(.Conflict, "vault directory changed; review consent again")
	signer: domain.Vault_Device
	for device in view.devices do if device.device_id == c.approver do signer = device
	if signer.status != .Approved || signer.device_id == "" || !domain.vault_kind_policy(signer.kind).can_approve || !vault.verify(signer.sign_alg, signer.sign_public_key, transmute([]byte)consent_message(string(canonical)), op.input.signature) do return domain.domain_error(.Forbidden, "approved device consent required")
	if c.mode == "hosted" {
		if c.recipient == "" || len(c.recipient)>256 || !strings.has_prefix(c.recipient, "mcp_") || !vault.valid_id_value(c.recipient) || !consent_capability_ok(op.input.private_capability, c.recipient_public_key) do return domain.domain_error(.Forbidden, "delegated recipient does not match consent")
		for device in view.devices {
			if c.recipient_public_key==device.sign_public_key || c.recipient_public_key==device.ecdh_public_key do return domain.domain_error(.Forbidden,"connector requires a new recipient key")
		}
		grants,grants_err:=tx.list(tx.ctx,"grant",c.owner)
		if grants_err.code!=.None do return grants_err
		for grant in grants do if grant.recipient_public_key==c.recipient_public_key do return domain.domain_error(.Conflict,"connector requires a new recipient key")
		value, parse_err := json.parse_string(op.input.wrap_json,parse_integers=true,allocator=context.temp_allocator)
		if parse_err!=nil do return domain.domain_error(.Validation_Failed,"invalid delegated keyring wrap")
		w,wrap_sig,wrap_ok:=vault.wrap_from_value_for_recipient(value,c.recipient,context.temp_allocator)
		if !wrap_ok || w.recipient_device_id != c.recipient || w.wrapped_by_device_id != c.approver || w.directory_version != u64(c.directory_version) || w.current_epoch != u32(c.epoch) do return domain.domain_error(.Validation_Failed, "invalid delegated keyring wrap")
		digest: [32]byte
		if !vault.wrap_sha256(&w, digest[:]) || vault.hex_encode_lower(digest[:], context.temp_allocator) != c.wrap_sha256 do return domain.domain_error(.Forbidden, "keyring wrap does not match consent")
		wrap_stmt, stmt_ok := vault.wrap_statement(&w, c.owner, context.temp_allocator)
		if !stmt_ok || !vault.verify(signer.sign_alg, signer.sign_public_key, transmute([]byte)wrap_stmt, wrap_sig) do return domain.domain_error(.Forbidden, "delegated wrap signature does not verify")
		// Persist only the allowlisted canonical public wrap, never arbitrary
		// caller JSON members that could accidentally contain private material.
		public_wrap, public_ok:=vault.wrap_signed_json(&w,wrap_sig)
		if !public_ok do return domain.domain_error(.Validation_Failed,"invalid delegated keyring wrap")
		op.input.wrap_json=public_wrap
		// U2 additionally verifies the signed epoch commits before decryption.
	} else if c.mode != "device" || c.recipient != "" || c.recipient_public_key != "" || c.wrap_sha256 != "" || op.input.private_capability != "" || op.input.wrap_json != "" {
		return domain.domain_error(.Validation_Failed, "invalid connector mode")
	}
	_, exists, eerr := tx.get(tx.ctx, "grant", c.grant)
	if eerr.code != .None do return eerr
	if exists do return domain.domain_error(.Conflict, "connector consent already completed")
	g := domain.MCP_Record{kind = "grant", id = c.grant, owner = c.owner, client = c.client, resource = c.resource, scope = c.scope, grant = c.grant, family = c.family, vault_id = c.vault_id, recipient = c.recipient, recipient_public_key = c.recipient_public_key, mode = c.mode, approver = c.approver, consent = op.input.consent, signature = op.input.signature, wrap_json = op.input.wrap_json, revision = c.revision, directory_version = c.directory_version, directory_head = c.directory_head, epoch = c.epoch, created_ms = op.now}
	jti, random_ok := auth.random_token()
	if !random_ok do return domain.domain_error(.Internal_Error, "MCP entropy unavailable")
	claims := Credential_Claims{kind = "code", issuer = op.service.issuer, owner = c.owner, client = c.client, resource = c.resource, scope = c.scope, grant = c.grant, family = c.family, vault_id = c.vault_id, recipient = c.recipient, revision = c.revision, issued_ms = op.now, expires_ms = op.now+CODE_TTL, redirect = p.redirect, challenge = p.challenge, jti = jti, private_capability = op.input.private_capability}
	code, sealed := credential_seal(&op.service.keys[0], claims)
	if !sealed do return domain.domain_error(.Internal_Error, "MCP sealing unavailable")
	if ge := tx.put(tx.ctx, g); ge.code != .None do return ge
	family := g; family.kind = "family"; family.id = c.family; family.consent = ""; family.signature = ""; family.wrap_json = ""
	if fe := tx.put(tx.ctx, family); fe.code != .None do return fe
	if ce := tx.put(tx.ctx, credential_metadata(claims, code)); ce.code != .None do return ce
	p.consumed = true
	if pe := tx.put(tx.ctx, p); pe.code != .None do return pe
	op.code = code; op.redirect = p.redirect; op.state = p.oauth_state
	return {}
}

delegation_consent :: proc(s: ^Delegation_Service, directory: ^vd.Service, owner, signer: string, input: Consent_Input, now: i64) -> (code, redirect, state: string, err: domain.Domain_Error) {
	if s == nil || len(s.keys) == 0 || directory == nil do return "", "", "", domain.domain_error(.Internal_Error, "MCP consent unavailable")
	op := Consent_Operation{service = s, vault = directory, owner = owner, signer = signer, input = input, now = now}
	err = iface.mcp_transaction(s.repo, consent_transaction, &op)
	if err.code != .None do return "", "", "", err
	return op.code, op.redirect, op.state, domain.Domain_Error{}
}
