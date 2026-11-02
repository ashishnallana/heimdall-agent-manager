package mcp

import "core:crypto"
import "core:crypto/ecdh"
import "core:encoding/json"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import auth "odin_test:hub/service/auth"
import vd "odin_test:hub/service/vault_directory"
import vault "odin_test:lib/vault"

// Must be called on the same connection as the surrounding MCP transaction.
verified_grant_directory :: proc(directory:^vd.Service,g:domain.MCP_Record)->(vault.Verified_Directory,bool,domain.Domain_Error) {
	if g.kind!="grant" || g.id!=g.grant do return {},false,domain.Domain_Error{}
	c:Consent
	if json.unmarshal_string(g.consent,&c,.JSON,context.temp_allocator)!=nil do return {},false,domain.Domain_Error{}
	canonical,enc_err:=json.marshal(c,allocator=context.temp_allocator)
	if enc_err!=nil || string(canonical)!=g.consent || c.v==0 || c.v!=consent_version(c.scope) || c.owner!=g.owner || c.vault_id!=g.vault_id || c.client!=g.client || c.resource!=g.resource || c.scope!=g.scope || c.grant!=g.grant || c.family!=g.family || c.revision!=g.revision || c.mode!=g.mode || c.recipient!=g.recipient || c.recipient_public_key!=g.recipient_public_key || c.approver!=g.approver || c.directory_version!=g.directory_version || c.directory_head!=g.directory_head || c.epoch!=g.epoch || g.revoked do return {},false,domain.Domain_Error{}
	view,err:=vd.get_directory(directory,g.owner)
	if err.code!=.None do return {},false,err
	logs:=make([]vault.Directory_Log_Item,len(view.log),context.temp_allocator)
	for entry,i in view.log do logs[i]={entry.seq,entry.statement,entry.signature}
	devices:=make([]vault.Directory_Device_Item,len(view.devices),context.temp_allocator)
	for device,i in view.devices do devices[i]={device.device_id,device.kind,device.sign_alg,device.wrap_alg,device.sign_public_key,device.ecdh_public_key,device.status==.Approved,device.status==.Pending}
	verified,ok:=vault.directory_verify({owner=g.owner,root_device_id=view.directory.root_device_id,head_hash=view.directory.head_hash,version=view.directory.version,current_epoch=view.directory.current_epoch,log=logs,devices=devices,pin_seq=c.directory_version,pin_hash=c.directory_head,vault_id=c.vault_id})
	if !ok do return {},false,domain.Domain_Error{}
	approver,trusted:=verified.trusted[c.approver]
	if !trusted || approver.approval_seq>c.directory_version || !vault.kind_policy(vault.device_kind_from_id(approver.kind)).can_approve || !vault.verify(approver.sign_alg,approver.sign_public_key,transmute([]byte)consent_message(g.consent),g.signature) do return {},false,domain.Domain_Error{}
	if c.mode=="hosted" {
		initial_value,parse_err:=json.parse_string(g.wrap_json,parse_integers=true,allocator=context.temp_allocator)
		if parse_err!=nil do return {},false,domain.Domain_Error{}
		initial,signature,parsed:=vault.wrap_from_value_for_recipient(initial_value,c.recipient,context.temp_allocator)
		digest:[32]byte
		if !parsed || i64(initial.directory_version)!=c.directory_version || i64(initial.current_epoch)!=c.epoch || initial.wrapped_by_device_id!=c.approver || !vault.wrap_sha256(&initial,digest[:]) || vault.hex_encode_lower(digest[:],context.temp_allocator)!=c.wrap_sha256 do return {},false,domain.Domain_Error{}
		statement,statement_ok:=vault.wrap_statement(&initial,c.owner,context.temp_allocator)
		if !statement_ok || !vault.verify(approver.sign_alg,approver.sign_public_key,transmute([]byte)statement,signature) do return {},false,domain.Domain_Error{}
	}
	epoch_at_pin:u32
	for epoch,proof in verified.epochs do if proof.start_seq<=c.directory_version && epoch>epoch_at_pin do epoch_at_pin=epoch
	if i64(epoch_at_pin)!=c.epoch do return {},false,domain.Domain_Error{}
	return verified,true,domain.Domain_Error{}
}

Hosted_Operation :: struct {
	service:^Delegation_Service,
	directory:^vd.Service,
	raw:string,
	claims:Credential_Claims,
	keyring:^vault.Vault_Keyring,
	head:string,
	epoch:u32,
	final_check:bool,
	ok:bool,
	error:string,
}
hosted_transaction :: proc(tx:iface.MCP_Transaction,ctx:rawptr)->domain.Domain_Error {
	op:=(^Hosted_Operation)(ctx)
	op.ok=false;op.error="invalid_token"
	now,clock_ok:=platform.rfc3339_to_unix_ms(platform.clock_now(op.service.clock))
	if !clock_ok do return domain.domain_error(.Internal_Error,"MCP clock unavailable")
	c:=op.claims
	if !delegation_claims_ok(op.service,c,c.client,now) || c.kind!="access" || c.expires_ms<=now do return {}
	access,found,err:=tx.get(tx.ctx,"access",auth.sha256_hex(op.raw))
	if err.code!=.None do return err
	if !found || access.expires_ms!=c.expires_ms || !delegation_binding(c,access) do return {}
	live,lerr:=delegation_live(op.service,tx,c)
	if lerr.code!=.None do return lerr
	if !live do return {}
	g,_,gerr:=tx.get(tx.ctx,"grant",c.grant)
	if gerr.code!=.None do return gerr
	if g.mode!="hosted" || c.private_capability=="" {op.error="decryption_unavailable";return {}}
	dir,verified,verr:=verified_grant_directory(op.directory,g)
	if verr.code!=.None do return verr
	if !verified {op.error="decryption_unavailable";return {}}
	if op.final_check {
		if dir.head_hash!=op.head || dir.current_epoch!=op.epoch {op.error="decryption_unavailable";return {}}
		op.ok=true;op.error="";return {}
	}
	if !consent_capability_ok(c.private_capability,g.recipient_public_key) do return {}
	wrap_text:=g.wrap_json
	row,has_wrap,werr:=tx.get(tx.ctx,"wrap",g.id)
	if werr.code!=.None do return werr
	if has_wrap {
		if !delegation_binding(c,row) || row.recipient_public_key!=g.recipient_public_key || row.epoch!=i64(dir.current_epoch) || row.directory_version<1 || row.directory_version>dir.version || dir.log_hashes[row.directory_version-1]!=row.directory_head {op.error="decryption_unavailable";return {}}
		wrap_text=row.wrap_json
	}
	value,parse_err:=json.parse_string(wrap_text,parse_integers=true,allocator=context.temp_allocator)
	if parse_err!=nil {op.error="decryption_unavailable";return {}}
	w,wrap_ok:=vault.directory_verify_wrap(&dir,g.recipient,value)
	if !wrap_ok {op.error="decryption_unavailable";return {}}
	if has_wrap && (i64(w.directory_version)!=row.directory_version || i64(w.current_epoch)!=row.epoch) {op.error="decryption_unavailable";return {}}
	if !has_wrap && i64(w.current_epoch)!=g.epoch {op.error="decryption_unavailable";return {}}
	raw:[32]byte
	defer crypto.zero_explicit(&raw,size_of(raw))
	if !vault.hex_decode_into(raw[:],c.private_capability) do return {}
	priv:ecdh.Private_Key
	defer ecdh.private_key_clear(&priv)
	if !ecdh.private_key_set_bytes(&priv,.SECP256R1,raw[:]) do return {}
	kr,opened:=vault.wrap_open(&w,c.owner,&priv)
	defer vault.keyring_wipe(&kr)
	if !opened || !vault.directory_verify_keyring(&dir,&kr) {op.error="decryption_unavailable";return {}}
	op.keyring^=kr
	op.head=dir.head_hash;op.epoch=dir.current_epoch;op.ok=true;op.error=""
	return {}
}

// The callback may only use the borrowed keyring synchronously; it must not
// retain it or log/cache results. No business/network work occurs under the DB
// lock. Revalidate revocation, expiry and directory freshness before returning.
Hosted_Transform_Proc :: proc(ctx:rawptr,kr:^vault.Vault_Keyring)->(string,bool)
hosted_with_access :: proc(s:^Delegation_Service,directory:^vd.Service,raw,client:string,run:Hosted_Transform_Proc,ctx:rawptr)->Delegation_Result {
	if s==nil || s.clock==nil || directory==nil || run==nil do return {error="decryption_unavailable"}
	c,opened:=credential_open(s.keys,raw,"access")
	defer credential_claims_wipe(&c)
	if !opened || c.client!=client do return {error="invalid_token"}
	kr:vault.Vault_Keyring
	defer vault.keyring_wipe(&kr)
	op:=Hosted_Operation{service=s,directory=directory,raw=raw,claims=c,keyring=&kr}
	if err:=iface.mcp_transaction(s.repo,hosted_transaction,&op);err.code!=.None do return {error="decryption_unavailable"}
	if !op.ok do return {error=op.error}
	response,transformed:=run(ctx,&kr)
	if !transformed {
		if response!="" do crypto.zero_explicit(raw_data(response),len(response))
		return {error="decryption_unavailable"}
	}
	op.final_check=true
	err:=iface.mcp_transaction(s.repo,hosted_transaction,&op)
	if err.code!=.None || !op.ok {
		if response!="" do crypto.zero_explicit(raw_data(response),len(response))
		if err.code==.None do return {error=op.error}
		return {error="decryption_unavailable"}
	}
	return {response=response}
}
