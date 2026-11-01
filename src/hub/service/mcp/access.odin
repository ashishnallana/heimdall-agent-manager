package mcp

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import auth "odin_test:hub/service/auth"
import platform "odin_test:hub/platform"
import vd "odin_test:hub/service/vault_directory"
import vault "odin_test:lib/vault"

// A request-local public snapshot. No credential/private capability is retained.
Access_View :: struct {owner,client,grant,family,mode,head,vault_id,scope:string,revision,version,expires_ms:i64,epoch:u32,consent,signature:string}
Access_Check :: struct {service:^Delegation_Service,directory:^vd.Service,raw:string,claims:Credential_Claims,view:Access_View,ok:bool}
access_transaction :: proc(tx:iface.MCP_Transaction,ctx:rawptr)->domain.Domain_Error {
	op:=(^Access_Check)(ctx)
	c:=op.claims
	now,clock_ok:=platform.rfc3339_to_unix_ms(platform.clock_now(op.service.clock))
	if !clock_ok || !delegation_claims_ok(op.service,c,c.client,now) || c.kind!="access" || c.expires_ms<=now do return {}
	row,found,err:=tx.get(tx.ctx,"access",auth.sha256_hex(op.raw))
	if err.code!=.None do return err
	if !found || row.expires_ms!=c.expires_ms || !delegation_binding(c,row) do return {}
	live,lerr:=delegation_live(op.service,tx,c)
	if lerr.code!=.None do return lerr
	if !live do return {}
	g,_,gerr:=tx.get(tx.ctx,"grant",c.grant)
	if gerr.code!=.None do return gerr
	dir,verified,verr:=verified_grant_directory(op.directory,g)
	if verr.code!=.None do return verr
	if !verified do return {}
	op.view={owner=c.owner,client=c.client,grant=c.grant,family=c.family,mode=g.mode,scope=c.scope,head=dir.head_hash,vault_id=c.vault_id,revision=c.revision,version=dir.version,expires_ms=c.expires_ms,epoch=dir.current_epoch,consent=g.consent,signature=g.signature}
	op.ok=true
	return {}
}
access_view :: proc(s:^Delegation_Service,directory:^vd.Service,raw:string)->(Access_View,bool) {
	if s==nil || s.clock==nil || directory==nil do return {},false
	c,opened:=credential_open(s.keys,raw,"access")
	defer credential_claims_wipe(&c)
	if !opened do return {},false
	op:=Access_Check{service=s,directory=directory,raw=raw,claims=c}
	err:=iface.mcp_transaction(s.repo,access_transaction,&op)
	return op.view,err.code==.None && op.ok
}
access_same :: proc(a,b:Access_View)->bool {
	return a.owner==b.owner && a.client==b.client && a.grant==b.grant && a.family==b.family && a.revision==b.revision && a.mode==b.mode && a.scope==b.scope && a.head==b.head && a.epoch==b.epoch
}

Public_Job_Check :: struct {service:^Delegation_Service,directory:^vd.Service,job:vault.Control_Job,ok:bool}
public_job_transaction :: proc(tx:iface.MCP_Transaction,ctx:rawptr)->domain.Domain_Error {
	op:=(^Public_Job_Check)(ctx);j:=op.job
	g,found,err:=tx.get(tx.ctx,"grant",j.grant)
	if err.code!=.None do return err
	if !found || g.revoked || g.mode!="device" || g.owner!=j.owner || g.resource!=j.resource || g.revision!=j.revision || g.consent!=j.consent || g.signature!=j.signature do return {}
	if !vault.control_job_scope_ok(g.scope,j.tool,j.operation) do return {}
	c:=Credential_Claims{owner=g.owner,client=g.client,resource=g.resource,scope=g.scope,grant=g.grant,family=g.family,vault_id=g.vault_id,recipient=g.recipient,revision=g.revision}
	live,lerr:=delegation_live(op.service,tx,c)
	if lerr.code!=.None do return lerr
	if !live do return {}
	dir,verified,verr:=verified_grant_directory(op.directory,g)
	if verr.code!=.None do return verr
	op.ok=verified && dir.head_hash==j.head && dir.current_epoch==j.epoch
	return {}
}
// Recheck queued work without ever retaining the caller's OAuth credential in
// a worker broker. These are public grant bindings, not a new credential path.
public_job_live :: proc(s:^Delegation_Service,directory:^vd.Service,job:vault.Control_Job)->bool {
	op:=Public_Job_Check{service=s,directory=directory,job=job}
	err:=iface.mcp_transaction(s.repo,public_job_transaction,&op)
	return err.code==.None && op.ok
}
