#+feature dynamic-literals
package mcp

import "core:encoding/json"
import "core:slice"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import content "odin_test:hub/service/content"
import project "odin_test:hub/service/project"
import issue "odin_test:hub/service/issue"

resource_project_revision :: proc(s:^Control_Service,p:domain.Project)->(string,[]domain.Project_Bridge_Path,string) {
	paths,err:=project.list_bridge_paths(s.projects,control_auth(string(p.owner_user_id)),p.project_id)
	if err.code!=.None do return "",nil,"request_failed"
	if len(paths)>100 do return "",nil,"result_too_large"
	slice.sort_by(paths,proc(a,b:domain.Project_Bridge_Path)->bool {return a.bridge_id<b.bridge_id})
	return resource_digest(struct {project:domain.Project,paths:[]domain.Project_Bridge_Path}{p,paths}),paths,""
}
resource_get :: proc(s:^Control_Service,owner,kind,id:string,detail:bool)->(json.Object,string,string) {
	if s==nil || kind=="memory" && (s.content==nil || s.content.content==nil) || kind=="project" && (s.projects==nil || s.projects.projects==nil) || kind=="issue" && (s.issues==nil || s.issues.issues==nil) do return nil,"","request_failed"
	auth:=control_auth(owner)
	row:=make(json.Object,context.temp_allocator)
	revision:string
	switch kind {
	case "artifact":return resource_artifact_get(s,owner,id,detail)
	case "memory":
		m,found,err:=content.get_memory(s.content,auth,id);if !found || err.code!=.None do return nil,"","not_found"
		if len(m.agent_ids)>100 || len(m.project_ids)>100 || len(m.bridge_ids)>100 || len(m.template_ids)>100 do return nil,"","result_too_large"
		revision=resource_digest(m)
		row=json.Object{"owner_user_id"=json.String(m.owner_user_id),"memory_id"=json.String(m.memory_id),"read_only"=json.Boolean(m.owner_user_id=="system"),"title"=json.String(m.title),"description"=json.String(m.description),"type"=json.String(domain.memory_type_string(m.type)),"status"=json.String(m.status),"expires_at"=json.String(m.expires_at),"agent_ids"=resource_strings(m.agent_ids),"project_ids"=resource_project_ids(m.project_ids),"bridge_ids"=resource_strings(m.bridge_ids),"template_ids"=resource_strings(m.template_ids),"proposed_by_instance_id"=json.String(m.proposed_by_instance_id),"proposed_in_chain_id"=json.String(m.proposed_in_chain_id),"created_at"=json.String(m.created_at),"updated_at"=json.String(m.updated_at)}
		if detail {row["body"]=json.String(m.body);row["evidence"]=json.String(m.evidence)}
	case "project":
		p,found,err:=project.get(s.projects,auth,domain.Project_ID(id));if !found || err.code!=.None do return nil,"","not_found"
		paths:[]domain.Project_Bridge_Path;code:string
		revision,paths,code=resource_project_revision(s,p);if code!="" do return nil,"",code
		row=json.Object{"owner_user_id"=json.String(p.owner_user_id),"project_id"=json.String(p.project_id),"name"=json.String(p.name),"slug"=json.String(p.slug),"description"=json.String(p.description),"repo_url"=json.String(p.repo_url),"vcs_kind"=json.String(p.vcs_kind),"default_path"=json.String(p.default_path),"state"=json.String(domain.project_state_string(p.state)),"created_at"=json.String(p.created_at),"updated_at"=json.String(p.updated_at)}
		if detail {
			items:=make(json.Array,0,len(paths),context.temp_allocator)
			for path in paths {b,found,e:=iface.bridge_get_bridge(s.bridges,path.bridge_id);if !found || e.code!=.None || string(b.owner_user_id)!=owner do return nil,"","not_found";append(&items,json.Object{"bridge_id"=json.String(path.bridge_id),"path"=json.String(path.path),"is_validated"=json.Boolean(path.is_validated),"last_validated_at"=json.String(path.last_validated_at),"updated_at"=json.String(path.updated_at)})}
			row["bridge_paths"]=items
		}
	case "issue":
		i,found,err:=issue.get_issue(s.issues,auth,domain.Issue_ID(id));if !found || err.code!=.None do return nil,"","not_found"
		revision=resource_digest(i)
		row=json.Object{"owner_user_id"=json.String(i.owner_user_id),"issue_id"=json.String(i.issue_id),"title"=json.String(i.title),"description"=json.String(i.description),"created_by"=json.String(i.created_by),"status"=json.String(domain.issue_status_string(i.status)),"scope_type"=json.String(domain.issue_scope_type_string(i.scope_type)),"target_id"=json.String(i.target_id),"chain_id"=json.String(i.chain_id),"vote_count"=json.Integer(i.vote_count),"comment_count"=json.Integer(i.comment_count),"created_at"=json.String(i.created_at),"updated_at"=json.String(i.updated_at),"closed_at"=json.String(i.closed_at)}
		if !detail do row["description_limit"]=json.Integer(512)
	case:return nil,"","invalid_arguments"
	}
	row["revision"]=json.String(revision)
	// Legacy oversized prose remains identifiable without unbounded decrypt jobs.
	for key in ([]string{"name","title","description","body","evidence"}) {if text,typed:=row[key].(json.String);typed {cap:=48*1024;if key=="body" do cap=128*1024;if len(text)>cap {delete_key(&row,key);row[strings.concatenate({key,"_error"},context.temp_allocator)]=json.String("field_too_large")}}}
	return row,revision,""
}
resource_strings :: proc(values:[]string)->json.Array {out:=make(json.Array,0,len(values),context.temp_allocator);for value in values do append(&out,json.String(value));return out}
resource_project_ids :: proc(values:[]domain.Project_ID)->json.Array {out:=make(json.Array,0,len(values),context.temp_allocator);for value in values do append(&out,json.String(value));return out}
resource_read :: proc(s:^Control_Service,owner,tool:string,a:Resource_Arguments)->(Control_Data,string) {
	kind:=resource_kind(tool);out:=Control_Data{records_kind=kind}
	if s.content==nil || s.projects==nil || s.issues==nil || s.resource_page==nil do return {},"request_failed"
	if kind=="artifact" && a.id=="" {if ok,err:=content.artifact_context_owned(s.content,domain.User_ID(owner),{project_id=domain.Project_ID(a.project_id),chain_id=a.chain_id,task_id=a.task_id,agent_id=a.agent_id,agent_instance_id=a.agent_instance_id});!ok || err.code!=.None do return {},"not_found"}
	if a.id!="" {
		row,_,code:=resource_get(s,owner,kind,a.id,kind!="artifact" || a.include_content);if code!="" do return {},code
		if tool=="issues.get" && a.include_comments {comments,next,err:=resource_issue_comments(s,owner,a);if err!="" do return {},err;row["comments"]=comments;row["comments_next_cursor"]=json.String(next)}
		out.records=make([]json.Object,1,context.temp_allocator);out.records[0]=row;return out,""
	}
	cursor,valid:=resource_cursor(owner,tool,a,a.cursor,"");if !valid do return {},"invalid_arguments"
	limit:=a.limit;if limit==0 do limit=50
	refs,err:=s.resource_page(s.resource_ctx,{kind=kind,owner=owner,after_created=cursor.created_at,after_id=cursor.id,status=a.status,type=a.type,agent_id=a.agent_id,project_id=a.project_id,bridge_id=a.bridge_id,template_id=a.template_id,scope_type=a.scope_type,target_id=a.target_id,chain_id=a.chain_id,task_id=a.task_id,agent_instance_id=a.agent_instance_id,limit=limit+1})
	if err.code!=.None do return {},"request_failed"
	rows:=make([dynamic]json.Object,context.temp_allocator);bytes:=0
	for ref,i in refs {
		if i==limit {prev:=refs[i-1];out.next_cursor=resource_next(cursor,prev.created_at,prev.id);break}
		row,_,code:=resource_get(s,owner,kind,ref.id,false);if code!="" do return {},code
		encoded,_:=json.marshal(row,allocator=context.temp_allocator)
		if bytes+len(encoded)>1024*1024 && i>0 {prev:=refs[i-1];out.next_cursor=resource_next(cursor,prev.created_at,prev.id);break}
		bytes+=len(encoded);append(&rows,row)
	}
	out.records=rows[:];return out,""
}
resource_issue_comments :: proc(s:^Control_Service,owner:string,a:Resource_Arguments)->(json.Array,string,string) {
	cursor,ok:=resource_cursor(owner,"issues.comments",a,a.comment_cursor,a.id);if !ok do return nil,"","invalid_arguments"
	limit:=a.comment_limit;if limit==0 do limit=50
	refs,err:=s.resource_page(s.resource_ctx,{kind="issue_comment",owner=owner,issue_id=a.id,after_created=cursor.created_at,after_id=cursor.id,limit=limit+1});if err.code!=.None do return nil,"","request_failed"
	items:=make(json.Array,0,min(limit,len(refs)),context.temp_allocator);next:string;bytes:=0
	for ref,i in refs {
		if i==limit {previous:=refs[i-1];next=resource_next(cursor,previous.created_at,previous.id);break}
		if s.issues.issues.get_comment==nil do return nil,"","request_failed"
		c,found,e:=s.issues.issues.get_comment(s.issues.issues.ctx,domain.Issue_Comment_ID(ref.id),domain.User_ID(owner));if !found || e.code!=.None || string(c.issue_id)!=a.id do return nil,"","not_found"
		if i>0 && bytes+len(c.body)>1024*1024 {previous:=refs[i-1];next=resource_next(cursor,previous.created_at,previous.id);break}
		row:=json.Object{"owner_user_id"=json.String(c.owner_user_id),"comment_id"=json.String(c.comment_id),"issue_id"=json.String(c.issue_id),"author_id"=json.String(c.author_id),"author_name"=json.String(c.author_name),"created_at"=json.String(c.created_at),"updated_at"=json.String(c.updated_at)}
		if len(c.body)>128*1024 {row["body_error"]=json.String("field_too_large")} else {row["body"]=json.String(c.body);bytes+=len(c.body)}
		append(&items,row)
	}
	return items,next,""
}
