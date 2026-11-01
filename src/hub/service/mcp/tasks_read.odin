#+feature dynamic-literals
package mcp

import "core:encoding/json"
import "core:strconv"
import "core:fmt"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import tc "odin_test:hub/service/taskchain"

control_read_tasks :: proc(s:^Control_Service,owner,name:string,args:Control_Arguments)->(Control_Data,string) {
	principal:=control_auth(owner)
	rows:[]domain.Task
	out:Control_Data
	if name=="tasks.get" {
		task,found,err:=tc.get_task_for_read(s.chains,principal,domain.Task_ID(args.task_id))
		if !found || err.code!=.None do return {},"not_found"
		rows=[]domain.Task{task}
	} else {
		chain,found,err:=tc.get_chain_for_read(s.chains,principal,domain.Task_Chain_ID(args.chain_id))
		if !found || err.code!=.None do return {},"not_found"
		all,terr:=tc.list_tasks(s.chains,principal,chain.chain_id)
		if terr.code!=.None do return {},"request_failed"
		start:=0
		if args.cursor!="" {n,ok:=strconv.parse_int(args.cursor);if !ok || n<0 || n>len(all) do return {},"invalid_arguments";start=n}
		limit:=args.limit;if limit==0 do limit=50
		end:=min(len(all),start+limit)
		rows=all[start:end]
		if end<len(all) do out.next_cursor=fmt.tprintf("%d",end)
	}
	out.tasks=make([]json.Object,len(rows),context.temp_allocator)
	comments:=make([dynamic]json.Object,context.temp_allocator)
	for task,i in rows {
		if string(task.owner_user_id)!=owner do return {},"request_failed"
		brief,err:=json.parse_string(task.brief_json if task.brief_json!="" else "{}",parse_integers=true,allocator=context.temp_allocator)
		obj,typed:=brief.(json.Object)
		if err!=nil || !typed do return {},"request_failed"
		reviews,rerr:=iface.taskchain_list_reviews_by_task(s.chains.repo,task.task_id,task.owner_user_id)
		if rerr.code!=.None do return {},"request_failed"
		r:=make(json.Array,0,len(reviews),context.temp_allocator)
		for review in reviews do if review.attempt_no==task.attempt_no do append(&r,json.Object{"verdict"=json.String(review.verdict),"role"=json.String(review.role),"reviewer_kind"=json.String(review.reviewer_kind)})
		deps,derr:=iface.taskchain_list_dependencies_by_chain(s.chains.repo,task.chain_id,task.owner_user_id)
		if derr.code!=.None do return {},"request_failed"
		d:=make(json.Array,0,len(deps),context.temp_allocator)
		for dep in deps do if dep.task_id==task.task_id do append(&d,json.String(dep.depends_on_task_id))
		row:=json.Object{"owner_user_id"=json.String(owner),"task_id"=json.String(task.task_id),"chain_id"=json.String(task.chain_id),"title"=json.String(task.title),"description"=json.String(task.description),"state"=json.String(domain.task_state_string(task.state)),"kind"=json.String(domain.task_kind_string(task.kind)),"attempt_no"=json.Integer(task.attempt_no),"requires_user_approval"=json.Boolean(task.requires_user_approval),"reviews"=r,"bridge_id"=json.String(task.bridge_id),"depends_on"=d,"publish_state"=json.String("published" if task.publish_state==.Published else "draft"),"priority"=json.String(domain.task_priority_string(task.priority)),"updated_at"=json.String(task.updated_at)}
		for key in ([]string{"goal","acceptance"}) do if value,present:=obj[key];present && value!=nil do row[key]=value
		if task.blocked_on_json!="" {
			value,berr:=json.parse_string(task.blocked_on_json,parse_integers=true,allocator=context.temp_allocator)
			block,typed:=value.(json.Object)
			if berr!=nil || !typed do return {},"request_failed"
			projected:=[]string{"blocked_kind","blocked_ref","blocked_reason","blocked_since"}
			for key,i in ([]string{"kind","ref","reason","since"}) do if text,is_text:=block[key].(json.String);is_text do row[projected[i]]=text
		}
		if assignee,valid:=obj["assignee"].(json.String);valid do row["assignee_agent_id"]=assignee
		out.tasks[i]=row
		revision,revision_ok:=control_task_revision(s,task)
		if !revision_ok do return {},"request_failed"
		row["revision"]=json.String(revision)
		if name=="tasks.get" {
			all,cerr:=tc.list_comments(s.chains,principal,task.task_id)
			if cerr.code!=.None || len(all)>2000 do return {},"result_too_large"
			for comment in all do append(&comments,json.Object{"owner_user_id"=json.String(owner),"comment_id"=json.String(comment.comment_id),"body"=json.String(comment.body),"created_at"=json.String(comment.created_at)})
		}
	}
	out.comments=comments[:]
	return out,""
}
