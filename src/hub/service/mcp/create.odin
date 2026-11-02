package mcp

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import vd "odin_test:hub/service/vault_directory"

// Callback MUST write using the same SQLite connection as the MCP transaction.
// No network, external effects or nested transaction may run inside it.
Control_Create_Proc :: proc(ctx:rawptr,owner,title,description:string)->(string,bool)
Control_Create :: struct {check:Access_Check,expected:Access_View,title,description,chain_id,error:string,ctx:rawptr,create:Control_Create_Proc}
control_create_transaction :: proc(tx:iface.MCP_Transaction,ctx:rawptr)->domain.Domain_Error {
	op:=(^Control_Create)(ctx)
	if err:=access_transaction(tx,&op.check);err.code!=.None do return err
	if !op.check.ok {op.error="invalid_token";return {}}
	if !access_same(op.expected,op.check.view) {op.error="decryption_unavailable";return {}}
	id,created:=op.create(op.ctx,op.expected.owner,op.title,op.description)
	if !created || id=="" do return domain.domain_error(.Internal_Error,"MCP chain creation unavailable")
	op.chain_id=id;op.error=""
	return {}
}
control_create :: proc(s:^Delegation_Service,directory:^vd.Service,raw:string,view:Access_View,title,description:string,create:Control_Create_Proc,ctx:rawptr)->(chain_id,error:string) {
	if create==nil do return "","request_failed"
	c,opened:=credential_open(s.keys,raw,"access")
	defer credential_claims_wipe(&c)
	if !opened do return "","invalid_token"
	op:=Control_Create{check={service=s,directory=directory,raw=raw,claims=c},expected=view,title=title,description=description,ctx=ctx,create=create,error="request_failed"}
	if err:=iface.mcp_transaction(s.repo,control_create_transaction,&op);err.code!=.None do return "","request_failed"
	return op.chain_id,op.error
}
