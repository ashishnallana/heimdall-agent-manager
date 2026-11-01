package app

import sqlite "odin_test:hub/repository/sqlite"
import iface "odin_test:hub/repository/iface"
import domain "odin_test:hub/domain"
import mcp "odin_test:hub/service/mcp"
import vd "odin_test:hub/service/vault_directory"
import tc "odin_test:hub/service/taskchain"
import contracts "odin_test:contracts"

MCP_Task_Authority :: struct {conn:^sqlite.Conn,directory:^vd.Service}
mcp_task_authority :: proc(ctx:rawptr,grant:domain.MCP_Record)->(bool,domain.Domain_Error) {
	op:=(^MCP_Task_Authority)(ctx)
	impl:sqlite.User_Repo_SQLite
	repo:=sqlite.new_user_repository(&impl,op.conn)
	user,found,err:=iface.user_get_by_id(&repo,domain.User_ID(grant.owner))
	if err.code!=.None do return false,err
	if !found || user.status!=.Active do return false,{}
	return mcp.delegation_vault_authority(op.directory,grant)
}

mcp_comment_task :: proc(ctx:rawptr,raw:string,view:mcp.Access_View,task_id,request_id,digest,body:string)->(string,string) {
	graph:=(^App_Graph)(ctx)
	uow,begun,err:=iface.unit_of_work_begin(&graph.uow_factory)
	if !begun || err.code!=.None do return "","request_failed"
	committed:=false
	defer if !committed do iface.unit_of_work_rollback(&uow)
	// All authority reads, the native mutation, engine events, and receipt share
	// one connection. Nested task-engine effects run only after outer COMMIT.
	impl:sqlite.Vault_Directory_Repo_SQLite
	repo:=sqlite.new_vault_directory_repository(&impl,&graph.db)
	directory:=vd.Service{repo=&repo,clock=&graph.clock}
	authority:=MCP_Task_Authority{conn=&graph.db,directory=&directory}
	service:=graph.mcp_delegation
	service.authority_ctx=&authority;service.authority=mcp_task_authority
	code:=mcp.control_write_authorized(sqlite.mcp_transaction_view(&graph.db),&service,&directory,raw,view,"tasks.comment")
	if code!="" do return "",code
	prior,result,found,rerr:=sqlite.mcp_receipt_get(&graph.db,view.owner,view.grant,"tasks.comment",request_id)
	if rerr.code!=.None do return "","request_failed"
	if found {
		if prior!=digest do return "","idempotency_conflict"
		return result,""
	}
	chains:=graph.taskchains
	// Native write-through card projection must not run under this outer UOW.
	chains.attention=nil
	comment,_,ok,cerr:=tc.comment_task(&chains,mcp.control_auth(view.owner),{task_id=domain.Task_ID(task_id),body=body})
	if !ok || cerr.code!=.None {
		if cerr.code==.Not_Found || cerr.code==.Forbidden do return "","not_found"
		if cerr.code==.Conflict do return "","conflict"
		return "","request_failed"
	}
	if perr:=sqlite.mcp_receipt_put(&graph.db,view.owner,view.grant,"tasks.comment",request_id,digest,string(comment.comment_id));perr.code!=.None do return "","request_failed"
	if ok,cerr:=iface.unit_of_work_commit(&uow);!ok || cerr.code!=.None do return "","request_failed"
	committed=true
	contracts.attention_notify(graph.taskchains.attention,view.owner,contracts.ATTENTION_SOURCE_TASK,task_id)
	return string(comment.comment_id),""
}
