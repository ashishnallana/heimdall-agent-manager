package mcp

import iface "odin_test:hub/repository/iface"
import vd "odin_test:hub/service/vault_directory"
import tc "odin_test:hub/service/taskchain"
import domain "odin_test:hub/domain"
import "core:encoding/json"
import auth "odin_test:hub/service/auth"
import "core:crypto"

// Used only INSIDE the native task transaction, with authority and directory
// readers on that same connection. Replays also require a live original grant.
control_write_authorized :: proc(tx:iface.MCP_Transaction,s:^Delegation_Service,directory:^vd.Service,raw:string,expected:Access_View,tool:string)->string {
	c,opened:=credential_open(s.keys,raw,"access")
	defer credential_claims_wipe(&c)
	if !opened do return "invalid_token"
	op:=Access_Check{service=s,directory=directory,raw=raw,claims=c}
	if err:=access_transaction(tx,&op);err.code!=.None do return "request_failed"
	if !op.ok do return "invalid_token"
	if !access_same(expected,op.view) do return "decryption_unavailable"
	if !scope_allows_tool(op.view.scope,tool) do return "scope_missing"
	return ""
}
Control_Comment_Proc :: proc(ctx:rawptr,raw:string,view:Access_View,task_id,request_id,digest,body:string)->(comment_id,error:string)

Control_Task_Command :: struct {
	tool,request_id,digest,expected_revision,action,reason:string,
	chain_id:domain.Task_Chain_ID,
	task_id:domain.Task_ID,
	create:tc.Create_Task_Input,
	update:tc.Update_Task_Input,
	fleet:tc.Upsert_Fleet_Input,
}
Control_Task_Mutate_Proc :: proc(ctx:rawptr,raw:string,view:Access_View,command:Control_Task_Command)->(result_id,error:string)

// An opaque content revision covers native edits too, including same-timestamp
// updates. Checking only updated_at or the chain's topology revision loses edits.
control_task_revision :: proc(s:^Control_Service,task:domain.Task)->(string,bool) {
	deps,err:=iface.taskchain_list_dependencies_by_chain(s.chains.repo,task.chain_id,task.owner_user_id)
	if err.code!=.None do return "",false
	fleet,ferr:=iface.taskchain_list_fleets_by_chain(s.chains.repo,task.chain_id,task.owner_user_id)
	if ferr.code!=.None do return "",false
	encoded,eerr:=json.marshal(struct {task:domain.Task,dependencies:[]domain.Task_Dependency,fleet:[]domain.Task_Chain_Fleet}{task,deps,fleet},allocator=context.temp_allocator)
	defer if len(encoded)>0 do crypto.zero_explicit(raw_data(encoded),len(encoded))
	if eerr!=nil do return "",false
	return auth.sha256_hex(string(encoded)),true
}
