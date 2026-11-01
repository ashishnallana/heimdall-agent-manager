#+feature dynamic-literals
package mcp

import "core:encoding/json"
import "core:slice"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import tc "odin_test:hub/service/taskchain"
import tv2 "odin_test:hub/service/taskv2"

control_read_tasks :: proc(s:^Control_Service,owner,name:string,args:Control_Arguments)->(Control_Data,string) {
	principal:=control_auth(owner)
	rows:[]domain.Task
	out:Control_Data
	if name=="tasks.get" {
		task,found,err:=tc.get_task_for_read(s.chains,principal,domain.Task_ID(args.task_id))
		if !found || err.code!=.None || string(task.chain_id)!=args.chain_id do return {},"not_found"
		rows=[]domain.Task{task}
	} else {
		chain,found,err:=tc.get_chain_for_read(s.chains,principal,domain.Task_Chain_ID(args.chain_id))
		if !found || err.code!=.None do return {},"not_found"
		all,terr:=tc.list_tasks(s.chains,principal,chain.chain_id)
		if terr.code!=.None do return {},"request_failed"
		cursor,valid:=task_cursor(owner,"tasks",args,args.cursor)
		if !valid do return {},"invalid_arguments"
		slice.sort_by(all,proc(a,b:domain.Task)->bool {if a.created_at!=b.created_at do return a.created_at<b.created_at;return string(a.task_id)<string(b.task_id)})
		limit:=args.limit;if limit==0 do limit=50
		selected:=make([dynamic]domain.Task,context.temp_allocator)
		for task in all {
			if args.state!="" && domain.task_state_string(task.state)!=args.state || args.assignee_agent_id!="" && tv2.brief_assignee(task.brief_json)!=args.assignee_agent_id do continue
			if !task_cursor_after(cursor,task.created_at,string(task.task_id)) do continue
			if len(selected)==limit {last:=selected[len(selected)-1];out.next_cursor=task_cursor_encode(cursor,last.created_at,string(last.task_id));break}
			append(&selected,task)
		}
		rows=selected[:]
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
		for review in reviews do if review.attempt_no==task.attempt_no do append(&r,json.Object{"verdict"=json.String(review.verdict),"role"=json.String(review.role),"reviewer_kind"=json.String(review.reviewer_kind),"reviewer_agent_id"=json.String(review.reviewer_agent_id),"reviewer_instance_id"=json.String(review.reviewer_instance_id),"created_at"=json.String(review.created_at),"attempt_no"=json.Integer(review.attempt_no)})
		deps,derr:=iface.taskchain_list_dependencies_by_chain(s.chains.repo,task.chain_id,task.owner_user_id)
		if derr.code!=.None do return {},"request_failed"
		d:=make(json.Array,0,len(deps),context.temp_allocator)
		for dep in deps do if dep.task_id==task.task_id do append(&d,json.String(dep.depends_on_task_id))
		row:=json.Object{"owner_user_id"=json.String(owner),"task_id"=json.String(task.task_id),"chain_id"=json.String(task.chain_id),"title"=json.String(task.title),"description"=json.String(task.description),"state"=json.String(domain.task_state_string(task.state)),"kind"=json.String(domain.task_kind_string(task.kind)),"attempt_no"=json.Integer(task.attempt_no),"requires_user_approval"=json.Boolean(task.requires_user_approval),"reviews"=r,"bridge_id"=json.String(task.bridge_id),"depends_on"=d,"publish_state"=json.String("published" if task.publish_state==.Published else "draft"),"priority"=json.String(domain.task_priority_string(task.priority)),"updated_at"=json.String(task.updated_at)}
		if name=="tasks.get" {
			for key in ([]string{"goal","acceptance","inputs","review_roles","reviewers"}) do if value,present:=obj[key];present && value!=nil do row[key]=value
			if code:=control_task_attempt(s,task,&row);code!="" do return {},code
		}
		if task.blocked_on_json!="" {
			value,berr:=json.parse_string(task.blocked_on_json,parse_integers=true,allocator=context.temp_allocator)
			block,typed:=value.(json.Object)
			if berr!=nil || !typed do return {},"request_failed"
			projected:=[]string{"blocked_kind","blocked_ref","blocked_reason","blocked_since"}
			for key,i in ([]string{"kind","ref","reason","since"}) do if text,is_text:=block[key].(json.String);is_text do row[projected[i]]=text
			if since,typed:=block["since_ms"].(json.Integer);typed do row["blocked_since_ms"]=since
			if hold_raw,held:=tv2.task_hold_object(task.blocked_on_json);held {
				value,herr:=json.parse_string(hold_raw,parse_integers=true,allocator=context.temp_allocator)
				hold,typed:=value.(json.Object);if herr!=nil || !typed do return {},"request_failed"
				if reason,typed:=hold["reason"].(json.String);typed do row["hold_reason"]=reason
				if since,typed:=hold["since_ms"].(json.Integer);typed do row["hold_since_ms"]=since
				if by,typed:=hold["by"].(json.String);typed do row["hold_by"]=by
				leases,lerr:=iface.taskchain_list_leases_by_task(s.chains.repo,task.task_id)
				if lerr.code!=.None do return {},"request_failed"
				row["checkpoint_requested"]=json.Boolean(len(leases)>0)
			}
		}
		if assignee,valid:=obj["assignee"].(json.String);valid do row["assignee_agent_id"]=assignee
		revision,revision_ok:=control_task_revision(s,task)
		if !revision_ok do return {},"request_failed"
		row["revision"]=json.String(revision)
		if name=="tasks.get" {
			actions,aerr:=tc.task_control_actions(s.chains,principal,task)
			if aerr.code!=.None do return {},"request_failed"
			values:=make(json.Array,0,len(actions),context.temp_allocator)
			for action in actions do append(&values,json.String(action))
			row["allowed_actions"]=values
		}
		if name=="tasks.get" && args.include_comments {
			page,next,code:=control_comment_page(s,owner,args)
			if code!="" do return {},code
			append(&comments,..page)
			out.comments_next_cursor=next
		}
		out.tasks[i]=row
	}
	out.comments=comments[:]
	return out,""
}
