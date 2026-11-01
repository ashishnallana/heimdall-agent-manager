#+feature dynamic-literals
package app

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import mcp "odin_test:hub/service/mcp"
import tc "odin_test:hub/service/taskchain"
import tv2 "odin_test:hub/service/taskv2"
import http "odin_test:hub/transport/http"

// Runs inside the real SQLite/consent/hosted-worker integration fixture, before
// the fixture revokes its grant. Direct repository seeds model legacy history.
mcp_task_test_contract :: proc(t:^testing.T,g:^App_Graph,h:^http.MCP_Control_Handlers,headers:[]contracts.HTTP_Header,view:mcp.Access_View,sealed_body:string) {
	now:=mcp_task_test_now(nil)
	owner:=domain.User_ID(view.owner)
	for tool in ([]string{"tasks.get","tasks.comment","tasks.update","tasks.control"}) {
		_,accepted:=http.mcp_arguments(tool,json.Object{"task_id"=json.String("task_comment"),"request_id"=json.String("missing_chain"),"body"=json.String("Missing chain")})
		testing.expect(t,!accepted)
	}
	for other_owner in ([]bool{false,true}) {
		chain:="chain_other";chain_owner:=owner
		if other_owner {chain="chain_foreign";chain_owner="foreign_owner"}
		_,ok,err:=iface.taskchain_save_chain(&g.repos.taskchains,{chain_id=domain.Task_Chain_ID(chain),owner_user_id=chain_owner,title="Binding fixture",kind="mixed_work",status=.Active,created_at=now,updated_at=now})
		testing.expect(t,ok && err.code==.None)
		for tool in ([]string{"tasks.get","tasks.comment","tasks.update","tasks.control"}) {
			args:=json.Object{"chain_id"=json.String(chain),"task_id"=json.String("task_comment")}
			if tool!="tasks.get" do args["request_id"]=json.String("wrong_binding")
			if tool=="tasks.comment" do args["body"]=json.String("Must not be sealed or persisted")
			if tool=="tasks.update" || tool=="tasks.control" do args["expected_revision"]=json.String("0000000000000000000000000000000000000000000000000000000000000000")
			if tool=="tasks.update" do args["title"]=json.String("Must not change")
			if tool=="tasks.control" do args["action"]=json.String("recheck")
			testing.expectf(t,strings.contains(mcp_task_test_call(h,headers,tool,args).body,"not_found"),"%s must bind the intended chain",tool)
		}
	}
	// Delegation survives reads and retries without posing as an agent/reviewer.
	comment:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"tasks.comment",json.Object{"chain_id"=json.String("chain_comment"),"task_id"=json.String("task_comment"),"request_id"=json.String("attribution"),"body"=json.String("Delegated comment")}))
	if comment==nil do return
	testing.expect(t,comment["author_kind"].(json.String)==json.String("delegated_user") && comment["author_user_id"].(json.String)==json.String(view.owner) && comment["delegated_client_id"].(json.String)==json.String(view.client) && comment["delegated_grant_id"].(json.String)==json.String(view.grant))
	testing.expect(t,comment["created_at"].(json.String)==json.String(now))
	stored,found,err:=g.repos.taskchains.get_comment(g.repos.taskchains.ctx,string(comment["comment_id"].(json.String)),owner)
	testing.expect(t,found && err.code==.None && stored.author_agent_instance_id=="" && stored.delegated_client_id==view.client && stored.delegated_grant_id==view.grant)

	// A long history cannot prevent fetching task metadata and its CAS revision.
	uow,begun,uerr:=iface.unit_of_work_begin(&g.uow_factory)
	if !testing.expect(t,begun && uerr.code==.None) do return
	_,saved,_:=iface.taskchain_save_task(&g.repos.taskchains,{task_id="task_history",chain_id="chain_comment",owner_user_id=owner,title="History",publish_state=.Published,state=.In_Review,attempt_no=2,brief_json=`{"goal":"Approved goal","acceptance":["Criterion"],"inputs":["output:task_ref"],"reviewers":["agt_reviewer"]}`,created_at=now,updated_at=now})
	testing.expect(t,saved)
	for i in 0..<2005 {
		_,ok,e:=iface.taskchain_save_comment(&g.repos.taskchains,{comment_id=fmt.tprintf("history_%04d",i),task_id="task_history",chain_id="chain_comment",owner_user_id=owner,body=sealed_body,created_at=now,updated_at=now})
		testing.expect(t,ok && e.code==.None)
	}
	_,attempt_ok,_:=iface.taskchain_save_attempt(&g.repos.taskchains,{task_id="task_history",chain_id="chain_comment",owner_user_id=owner,attempt_no=2,holder_instance_id="inst_worker",started_at=now,ended_at=now,outcome="submitted"})
	facet,_:=json.marshal(json.Object{"summary"=json.String(sealed_body),"unapproved_field"=json.String("Never project arbitrary facet fields")},allocator=context.temp_allocator)
	facet_ok,_:=iface.taskchain_save_facet(&g.repos.taskchains,{task_id="task_history",chain_id="chain_comment",owner_user_id=owner,attempt_no=2,kind="handoff",v=1,body_json=string(facet),writer="agent",written_at=now})
	_,review_ok,_:=iface.taskchain_save_review(&g.repos.taskchains,{task_id="task_history",chain_id="chain_comment",owner_user_id=owner,attempt_no=2,role="reviewer",reviewer_kind="agent",reviewer_agent_id="agt_reviewer",reviewer_instance_id="inst_reviewer",verdict="approve",findings_json="[]",created_at=now})
	testing.expect(t,attempt_ok && facet_ok && review_ok)
	committed,commit_err:=iface.unit_of_work_commit(&uow)
	testing.expect(t,committed && commit_err.code==.None)
	get_args:=json.Object{"chain_id"=json.String("chain_comment"),"task_id"=json.String("task_history")}
	read:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"tasks.get",get_args))
	if read==nil do return
	tasks,_:=read["tasks"].(json.Array);row,_:=tasks[0].(json.Object)
	comments,_:=read["comments"].(json.Array)
	testing.expect(t,len(comments)==0 && row["revision"]!=nil && row["latest_attempt_no"].(json.Integer)==2 && row["latest_attempt_summary"].(json.String)=="private synthetic comment" && row["latest_attempt_holder_instance_id"].(json.String)=="inst_worker")
	testing.expect(t,!strings.contains(string(mcp_task_test_call(h,headers,"tasks.get",get_args).body),"unapproved_field"))
	reviews,_:=row["reviews"].(json.Array);review,_:=reviews[0].(json.Object)
	testing.expect(t,review["reviewer_agent_id"].(json.String)=="agt_reviewer" && review["reviewer_instance_id"].(json.String)=="inst_reviewer")
	args:=mcp.Control_Arguments{chain_id="chain_comment",task_id="task_history",include_comments=true,comment_limit=100}
	count:=0;last:=""
	for page in 0..<21 {
		data,code:=mcp.control_read_tasks(&h.control,view.owner,"tasks.get",args)
		if !testing.expect(t,code=="") do return
		for item in data.comments {
			id:=string(item["comment_id"].(json.String));testing.expect(t,id>last);last=id;count+=1
		}
		if data.comments_next_cursor=="" do break
		args.comment_cursor=data.comments_next_cursor
	}
	testing.expect_value(t,count,2005)
	args.task_id="task_comment"
	_,wrong_cursor:=mcp.control_read_tasks(&h.control,view.owner,"tasks.get",args)
	testing.expect_value(t,wrong_cursor,"invalid_arguments")
	args.task_id="task_history"
	_,_,cursor_error:=mcp.control_comment_page(&h.control,"foreign_owner",args)
	testing.expect_value(t,cursor_error,"invalid_arguments")

	// Native policy drives action hints, including held/terminal/workflow cases.
	task,_,_:=iface.taskchain_get_task(&g.repos.taskchains,"task_history")
	block,_:=json.marshal(json.Object{"kind"=json.String("dependency"),"ref"=json.String("task_ref"),"reason"=json.String(sealed_body),"since_ms"=json.Integer(123),"hold"=json.Object{"kind"=json.String("hold"),"reason"=json.String(sealed_body),"since_ms"=json.Integer(456),"by"=json.String("user")}},allocator=context.temp_allocator)
	task.blocked_on_json=string(block)
	_,_,_=iface.taskchain_save_task(&g.repos.taskchains,task)
	read=mcp_task_test_output(t,mcp_task_test_call(h,headers,"tasks.get",get_args))
	if read==nil do return
	tasks,_=read["tasks"].(json.Array);row,_=tasks[0].(json.Object)
	testing.expect(t,row["blocked_since_ms"].(json.Integer)==123 && row["hold_since_ms"].(json.Integer)==456 && row["blocked_reason"].(json.String)=="private synthetic comment" && row["hold_reason"].(json.String)=="private synthetic comment" && !row["checkpoint_requested"].(json.Boolean))
	actions,aerr:=tc.task_control_actions(&g.taskchains,mcp.control_auth(view.owner),task)
	testing.expect(t,aerr.code==.None && !mcp_task_test_has(actions,"answer"))
	task.state=.Done
	actions,_=tc.task_control_actions(&g.taskchains,mcp.control_auth(view.owner),task)
	testing.expect(t,!mcp_task_test_has(actions,"hold") && !mcp_task_test_has(actions,"cancel"))
	task.workflow_run_id="run_owned";task.state=.In_Review
	actions,_=tc.task_control_actions(&g.taskchains,mcp.control_auth(view.owner),task)
	testing.expect(t,!mcp_task_test_has(actions,"cancel") && !mcp_task_test_has(actions,"reopen"))
	_,denied:=tc.task_control_actions(&g.taskchains,mcp.control_auth("foreign_owner"),task)
	testing.expect(t,denied.code==.Not_Found)
	// Fold a real infrastructure block arriving after a hold. Releasing through
	// MCP must remove only the hold while retaining the independent blocker.
	task.workflow_run_id="";task.state=.Backlog;task.blocked_on_json=""
	_,_,_=iface.taskchain_save_task(&g.repos.taskchains,task)
	for kind,i in ([]string{tv2.EV_PUBLISHED,tv2.EV_HELD,tv2.EV_BLOCKED}) {
		payload:="{}"
		if kind==tv2.EV_BLOCKED {
			p,_:=json.marshal(json.Object{"infrastructure"=json.Boolean(true),"waiting_on"=json.Object{"kind"=json.String("agent_not_running"),"reason"=json.String(sealed_body),"since_ms"=json.Integer(789)}},allocator=context.temp_allocator)
			payload=string(p)
		}
		if kind==tv2.EV_HELD {p,_:=json.marshal(json.Object{"reason"=json.String(sealed_body)},allocator=context.temp_allocator);payload=string(p)}
		_,event_ok,_:=iface.taskchain_append_event(&g.repos.taskchains,{task_id=task.task_id,chain_id=task.chain_id,owner_user_id=owner,kind=kind,actor_kind="user",actor_id=view.owner,ts_ms=i64(100+i),payload_json=payload})
		testing.expect(t,event_ok)
	}
	u,native_begun,nerr:=tv2.begin_uow(&g.task_engine)
	if !testing.expect(t,native_begun && nerr.code==.None) do return
	fresh,_,fold_ok,_:=tv2.refold_task(&g.task_engine,&u,task,nil,nil)
	_,_=tv2.end_uow(&g.task_engine,&u,fold_ok)
	testing.expect(t,fold_ok && tv2.task_is_held(fresh))
	rev,_:=mcp.control_task_revision(&h.control,fresh)
	released:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"tasks.control",json.Object{"chain_id"=json.String(task.chain_id),"task_id"=json.String(task.task_id),"request_id"=json.String("release_underlying"),"expected_revision"=json.String(rev),"action"=json.String("release")}))
	if released==nil do return
	read=mcp_task_test_output(t,mcp_task_test_call(h,headers,"tasks.get",get_args));if read==nil do return
	tasks,_=read["tasks"].(json.Array);row,_=tasks[0].(json.Object)
	testing.expect(t,row["hold_reason"]==nil && row["blocked_kind"].(json.String)=="agent_not_running" && row["blocked_since_ms"].(json.Integer)==789)
	mcp_task_test_pages(t,g,h,headers,view)
}

mcp_task_test_has :: proc(values:[]string,value:string)->bool {for item in values do if item==value do return true;return false}

mcp_task_test_pages :: proc(t:^testing.T,g:^App_Graph,h:^http.MCP_Control_Handlers,headers:[]contracts.HTTP_Header,view:mcp.Access_View) {
	now:=mcp_task_test_now(nil);owner:=domain.User_ID(view.owner)
	for i in 0..<7 {
		state:domain.Task_State=.Ready;if i%2==0 do state=.Done
		assignee:="agt_filter";if i==3 do assignee="agt_other"
		brief,_:=json.marshal(json.Object{"assignee"=json.String(assignee)},allocator=context.temp_allocator)
		_,ok,_:=iface.taskchain_save_task(&g.repos.taskchains,{task_id=domain.Task_ID(fmt.tprintf("task_filter_%d",i)),chain_id="chain_other",owner_user_id=owner,title="Filtered",state=state,brief_json=string(brief),created_at=now,updated_at=now})
		testing.expect(t,ok)
	}
	args:=json.Object{"chain_id"=json.String("chain_other"),"state"=json.String("ready"),"assignee_agent_id"=json.String("agt_filter"),"limit"=json.Integer(1)}
	page:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"tasks.list",args))
	if page==nil do return
	tasks,_:=page["tasks"].(json.Array);row,_:=tasks[0].(json.Object)
	testing.expect(t,len(tasks)==1 && row["task_id"].(json.String)=="task_filter_1")
	cursor,_:=page["next_cursor"].(json.String);testing.expect(t,cursor!="")
	args["cursor"]=cursor
	page=mcp_task_test_output(t,mcp_task_test_call(h,headers,"tasks.list",args))
	if page==nil do return
	tasks,_=page["tasks"].(json.Array);row,_=tasks[0].(json.Object)
	testing.expect(t,len(tasks)==1 && row["task_id"].(json.String)=="task_filter_5" && page["next_cursor"]==nil)
	args["state"]=json.String("done")
	testing.expect(t,strings.contains(mcp_task_test_call(h,headers,"tasks.list",args).body,"invalid_arguments"))

	_,ok,_:=iface.taskchain_save_task(&g.repos.taskchains,{task_id="task_bytes",chain_id="chain_other",owner_user_id=owner,title="Large history",brief_json="{}",created_at=now,updated_at=now})
	testing.expect(t,ok)
	body:=make([]byte,200*1024,context.temp_allocator);for &b in body do b='x'
	large:=make([]byte,300*1024,context.temp_allocator);for &b in large do b='y'
	for i in 0..<25 {
		text:=string(body);if i==0 do text=string(large)
		_,saved,_:=iface.taskchain_save_comment(&g.repos.taskchains,{comment_id=fmt.tprintf("bytes_%02d",i),chain_id="chain_other",task_id="task_bytes",owner_user_id=owner,body=text,created_at=now,updated_at=now})
		testing.expect(t,saved)
	}
	get:=json.Object{"chain_id"=json.String("chain_other"),"task_id"=json.String("task_bytes")}
	metadata:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"tasks.get",get))
	if metadata==nil do return
	testing.expect(t,metadata["comments"]==nil)
	get["include_comments"]=json.Boolean(true);get["comment_limit"]=json.Integer(100)
	count:=0;oversized:=0
	for i in 0..<8 {
		data:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"tasks.get",get))
		if data==nil do return
		comments,_:=data["comments"].(json.Array);bytes:=0
		for item in comments {
			c,_:=item.(json.Object);count+=1
			if c["body_error"]!=nil {oversized+=1;testing.expect(t,c["body"]==nil && c["body_error"].(json.String)=="comment_too_large")} else {bytes+=len(c["body"].(json.String))}
		}
		testing.expect(t,bytes<=mcp.CONTROL_COMMENT_PAGE_BYTES && len(comments)>0)
		next,_:=data["comments_next_cursor"].(json.String)
		if next=="" do break
		get["comment_cursor"]=next
	}
	testing.expect(t,count==25 && oversized==1)
}

mcp_task_test_outcomes :: proc(t:^testing.T,g:^App_Graph,h:^http.MCP_Control_Handlers,headers:[]contracts.HTTP_Header,view:mcp.Access_View,id:domain.Task_ID) {
	task,_,_:=iface.taskchain_get_task(&g.repos.taskchains,id)
	revision,_:=mcp.control_task_revision(&h.control,task)
	args:=json.Object{"chain_id"=json.String(task.chain_id),"task_id"=json.String(id),"request_id"=json.String("checkpoint_hold"),"expected_revision"=json.String(revision),"action"=json.String("hold"),"reason"=json.String("Private checkpoint reason")}
	response:=mcp_task_test_call(h,headers,"tasks.control",args)
	result:=mcp_task_test_output(t,response);if result==nil do return
	testing.expect(t,result["status"].(json.String)=="accepted" && result["checkpoint_requested"].(json.Boolean) && result["changed"].(json.Boolean) && result["revision"]!=nil)
	testing.expect(t,response.body==mcp_task_test_call(h,headers,"tasks.control",args).body && !strings.contains(response.body,"Private checkpoint reason"))
	receipt,receipt_ok:=sqlite.mcp_receipt_result(&g.db,view.owner,view.grant,"tasks.control","checkpoint_hold")
	testing.expect(t,receipt_ok && !strings.contains(receipt,"Private checkpoint reason") && !strings.contains(receipt,"vault:v2:"))
	read:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"tasks.get",json.Object{"chain_id"=json.String(task.chain_id),"task_id"=json.String(id)}))
	if read==nil do return
	tasks,_:=read["tasks"].(json.Array);row,_:=tasks[0].(json.Object)
	testing.expect(t,row["checkpoint_requested"].(json.Boolean) && row["hold_reason"].(json.String)=="Private checkpoint reason")
	args["expected_revision"]=row["revision"];args["request_id"]=json.String("held_recheck");args["action"]=json.String("recheck");delete_key(&args,"reason")
	result=mcp_task_test_output(t,mcp_task_test_call(h,headers,"tasks.control",args));if result==nil do return
	testing.expect(t,!result["changed"].(json.Boolean) && result["status"].(json.String)=="noop" && result["reasons"]!=nil)
	args["expected_revision"]=result["revision"];args["request_id"]=json.String("release_checkpoint");args["action"]=json.String("release")
	result=mcp_task_test_output(t,mcp_task_test_call(h,headers,"tasks.control",args));if result==nil do return
	testing.expect(t,result["changed"].(json.Boolean) && !result["checkpoint_requested"].(json.Boolean))
	args["expected_revision"]=result["revision"];args["request_id"]=json.String("release_noop")
	result=mcp_task_test_output(t,mcp_task_test_call(h,headers,"tasks.control",args));if result==nil do return
	testing.expect(t,!result["changed"].(json.Boolean) && result["status"].(json.String)=="noop")
}
