package app

import "core:testing"
import "base:runtime"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import mcp "odin_test:hub/service/mcp"

// A real freeing allocator is essential: an arena can hide a second rollback
// through a UOW context already freed by the failed COMMIT. Run under ASan too.
mcp_task_test_failed_commit :: proc(t:^testing.T,g:^App_Graph,raw:string,view:mcp.Access_View,body:string,attention:^MCP_Task_Attention_Probe) {
	context.allocator=runtime.heap_allocator()
	now:=mcp_task_test_now(nil)
	_,saved,_:=iface.taskchain_save_task(&g.repos.taskchains,{task_id="task_commit_failure",chain_id="chain_comment",owner_user_id=domain.User_ID(view.owner),title="Commit failure fixture",publish_state=.Published,state=.In_Review,brief_json="{}",created_at=now,updated_at=now})
	if !testing.expect(t,saved) do return
	if !testing.expect(t,sqlite.exec(&g.db,"PRAGMA foreign_keys=ON; CREATE TABLE mcp_commit_parent(id INTEGER PRIMARY KEY); CREATE TABLE mcp_commit_child(id INTEGER REFERENCES mcp_commit_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER mcp_fail_commit AFTER INSERT ON mcp_mutation_receipts WHEN NEW.request_id IN ('commit_failure_comment','commit_failure_update') BEGIN INSERT INTO mcp_commit_child(id) VALUES(999); END;")) do return
	for tool in ([]string{"tasks.comment","tasks.update"}) {
		task,_,_:=iface.taskchain_get_task(&g.repos.taskchains,"task_commit_failure")
		before_events,_:=iface.taskchain_list_events_by_task(&g.repos.taskchains,task.task_id,task.owner_user_id)
		before_comments,_:=iface.taskchain_list_comments_by_task(&g.repos.taskchains,task.task_id,task.owner_user_id)
		before_notices:=attention.notices
		request:="commit_failure_comment";if tool=="tasks.update" do request="commit_failure_update"
		revision,_:=mcp.control_task_revision(&mcp.Control_Service{chains=&g.taskchains},task)
		command:=mcp.Control_Task_Command{tool=tool,chain_id=task.chain_id,task_id=task.task_id,request_id=request,digest="failed_commit_digest",expected_revision=revision,update={description=body}}
		result,code:string
		if tool=="tasks.comment" {result,code=mcp_comment_task(g,raw,view,string(task.chain_id),string(task.task_id),request,"failed_commit_digest",body)} else {result,code=mcp_mutate_task(g,raw,view,command)}
		testing.expectf(t,result=="" && code=="request_failed","%s must report actual COMMIT failure",tool)
		_,_,receipt,err:=sqlite.mcp_receipt_get(&g.db,view.owner,view.grant,tool,request)
		testing.expect(t,!receipt && err.code==.None)
		after_events,_:=iface.taskchain_list_events_by_task(&g.repos.taskchains,task.task_id,task.owner_user_id)
		after_comments,_:=iface.taskchain_list_comments_by_task(&g.repos.taskchains,task.task_id,task.owner_user_id)
		fresh,_,_:=iface.taskchain_get_task(&g.repos.taskchains,task.task_id)
		fresh_revision,_:=mcp.control_task_revision(&mcp.Control_Service{chains=&g.taskchains},fresh)
		testing.expect(t,len(before_events)==len(after_events) && len(before_comments)==len(after_comments) && fresh_revision==revision)
		testing.expect(t,attention.notices==before_notices && !attention.inside_transaction)
		// Repair the deferred FK, then retry the same arguments/request ID. The
		// failed receipt must not block retry or leave the connection/lock open.
		testing.expect(t,sqlite.exec(&g.db,"INSERT INTO mcp_commit_parent(id) VALUES(999);"))
		if tool=="tasks.comment" {result,code=mcp_comment_task(g,raw,view,string(task.chain_id),string(task.task_id),request,"failed_commit_digest",body)} else {result,code=mcp_mutate_task(g,raw,view,command)}
		testing.expect(t,result!="" && code=="" && attention.notices==before_notices+1)
		_,_,receipt,err=sqlite.mcp_receipt_get(&g.db,view.owner,view.grant,tool,request)
		testing.expect(t,receipt && err.code==.None)
		// Restore the failing condition for the other adapter.
		testing.expect(t,sqlite.exec(&g.db,"DELETE FROM mcp_commit_child; DELETE FROM mcp_commit_parent;"))
	}
	testing.expect(t,sqlite.exec(&g.db,"DROP TRIGGER mcp_fail_commit; DROP TABLE mcp_commit_child; DROP TABLE mcp_commit_parent;"))
}
