package mcp

import "core:encoding/json"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import vd "odin_test:hub/service/vault_directory"
import vault "odin_test:lib/vault"

grant_claim_bindings :: proc(g:domain.MCP_Record)->Credential_Claims {
	return {owner=g.owner,client=g.client,resource=g.resource,scope=g.scope,grant=g.grant,family=g.family,vault_id=g.vault_id,recipient=g.recipient,revision=g.revision}
}
Epoch_Delivery_Input :: struct {grant:string,revision,directory_version:i64,directory_head,wrap_json:string}
Epoch_Delivery_Operation :: struct {
	service:^Delegation_Service,
	directory:^vd.Service,
	owner,signer:string,
	input:Epoch_Delivery_Input,
	recipients:[]domain.MCP_Record,
	listing:bool,
}
epoch_delivery_transaction :: proc(tx:iface.MCP_Transaction,ctx:rawptr)->domain.Domain_Error {
	op:=(^Epoch_Delivery_Operation)(ctx)
	if op.listing {
		grants,err:=tx.list(tx.ctx,"grant",op.owner)
		if err.code!=.None do return err
		out:=make([dynamic]domain.MCP_Record,context.temp_allocator)
		for g in grants {
			if g.revoked || g.mode!="hosted" || g.resource!=op.service.resource || !scopes_valid(g.scope) do continue
			live,lerr:=delegation_live(op.service,tx,grant_claim_bindings(g))
			if lerr.code!=.None do return lerr
			if !live do continue
			_,verified,verr:=verified_grant_directory(op.directory,g)
			if verr.code!=.None do return verr
			if !verified do return domain.domain_error(.Forbidden,"connector grant verification failed")
			append(&out,g)
		}
		op.recipients=out[:];return {}
	}
	g,found,err:=tx.get(tx.ctx,"grant",op.input.grant)
	if err.code!=.None do return err
	if !found || g.owner!=op.owner || g.mode!="hosted" || g.resource!=op.service.resource || !scopes_valid(g.scope) || g.revision!=op.input.revision do return domain.domain_error(.Forbidden,"connector grant unavailable")
	live,lerr:=delegation_live(op.service,tx,grant_claim_bindings(g))
	if lerr.code!=.None do return lerr
	if !live do return domain.domain_error(.Forbidden,"connector grant unavailable")
	dir,verified,verr:=verified_grant_directory(op.directory,g)
	if verr.code!=.None do return verr
	if !verified do return domain.domain_error(.Forbidden,"connector grant verification failed")
	if dir.version!=op.input.directory_version || dir.head_hash!=op.input.directory_head do return domain.domain_error(.Conflict,"vault directory changed; refresh connector delivery")
	value,parse_err:=json.parse_string(op.input.wrap_json,parse_integers=true,allocator=context.temp_allocator)
	if parse_err!=nil do return domain.domain_error(.Validation_Failed,"invalid connector wrap")
	w,ok:=vault.directory_verify_wrap(&dir,g.recipient,value)
	if !ok || w.wrapped_by_device_id!=op.signer || i64(w.directory_version)!=dir.version do return domain.domain_error(.Forbidden,"connector wrap verification failed")
	_,sig,parsed:=vault.wrap_from_value_for_recipient(value,g.recipient,context.temp_allocator)
	if !parsed do return domain.domain_error(.Validation_Failed,"invalid connector wrap")
	canonical,encoded:=vault.wrap_signed_json(&w,sig,context.temp_allocator)
	if !encoded do return domain.domain_error(.Validation_Failed,"invalid connector wrap")
	old,exists,oerr:=tx.get(tx.ctx,"wrap",g.id)
	if oerr.code!=.None do return oerr
	if exists && (old.epoch>i64(dir.current_epoch) || old.directory_version>dir.version) do return domain.domain_error(.Conflict,"connector delivery cannot move backwards")
	row:=g;row.kind="wrap";row.wrap_json=canonical;row.epoch=i64(dir.current_epoch);row.directory_version=dir.version;row.directory_head=dir.head_hash
	row.consent="";row.signature=""
	return tx.put(tx.ctx,row)
}
connector_recipients :: proc(s:^Delegation_Service,directory:^vd.Service,owner:string)->([]domain.MCP_Record,domain.Domain_Error) {
	op:=Epoch_Delivery_Operation{service=s,directory=directory,owner=owner,listing=true}
	err:=iface.mcp_transaction(s.repo,epoch_delivery_transaction,&op)
	return op.recipients,err
}
deliver_connector_epoch :: proc(s:^Delegation_Service,directory:^vd.Service,owner,signer:string,input:Epoch_Delivery_Input)->domain.Domain_Error {
	op:=Epoch_Delivery_Operation{service=s,directory=directory,owner=owner,signer=signer,input=input}
	return iface.mcp_transaction(s.repo,epoch_delivery_transaction,&op)
}
