package sqlite

import "core:strings"
import iface "odin_test:hub/repository/iface"
import domain "odin_test:hub/domain"

mcp_resource_refs :: proc(ctx:rawptr,q:iface.Resource_Page_Query)->([]iface.Resource_Ref,domain.Domain_Error) {
	conn:=(^Conn)(ctx)
	if q.limit<1 || q.limit>101 do return nil,domain.domain_error(.Validation_Failed,"invalid resource page limit")
	table,id:string
	switch q.kind {case "artifact":table="artifacts";id="artifact_id";case "memory":table="memories";id="memory_id";case "project":table="projects";id="project_id";case "issue":table="issues";id="issue_id";case "issue_comment":table="issue_comments";id="comment_id";case:return nil,domain.domain_error(.Validation_Failed,"unknown resource")}
	owner_clause:="owner_user_id=?";if q.kind=="memory" do owner_clause="(owner_user_id=? OR owner_user_id='system')"
	query:=strings.concatenate({"SELECT ",id,",created_at FROM ",table," WHERE ",owner_clause," AND (created_at>? OR (created_at=? AND ",id,">?))"},context.temp_allocator)
	values:=make([dynamic]string,context.temp_allocator);append(&values,q.owner,q.after_created,q.after_created,q.after_id)
	if q.kind=="artifact" {
		query=strings.concatenate({query," AND COALESCE(deleted_at,'')='' AND (?='' OR project_id=?) AND (?='' OR chain_id=?) AND (?='' OR task_id=?) AND (?='' OR agent_id=?) AND (?='' OR agent_instance_id=?)"},context.temp_allocator)
		append(&values,q.project_id,q.project_id,q.chain_id,q.chain_id,q.task_id,q.task_id,q.agent_id,q.agent_id,q.agent_instance_id,q.agent_instance_id)
	} else if q.kind=="memory" {
		query=strings.concatenate({query," AND (?='' OR status=?) AND (?='' OR type=?)"},context.temp_allocator);append(&values,q.status,q.status,q.type,q.type)
		for field,i in ([]string{"agent_ids","project_ids","bridge_ids","template_ids"}) {
			filter:=q.agent_id;if i==1 do filter=q.project_id;if i==2 do filter=q.bridge_id;if i==3 do filter=q.template_id
			query=strings.concatenate({query," AND (?='' OR json_array_length(",field,")=0 OR EXISTS(SELECT 1 FROM json_each(",field,") WHERE value=?))"},context.temp_allocator);append(&values,filter,filter)
		}
	} else if q.kind=="project" {query=strings.concatenate({query," AND (?='' OR state=?)"},context.temp_allocator);append(&values,q.status,q.status)} else if q.kind=="issue" {
		query=strings.concatenate({query," AND (?='' OR status=?) AND (?='' OR scope_type=?) AND (?='' OR target_id=?) AND (?='' OR chain_id=?)"},context.temp_allocator)
		append(&values,q.status,q.status,q.scope_type,q.scope_type,q.target_id,q.target_id,q.chain_id,q.chain_id)
	} else {query=strings.concatenate({query," AND issue_id=?"},context.temp_allocator);append(&values,q.issue_id)}
	query=strings.concatenate({query," ORDER BY created_at,",id," LIMIT ?;"},context.temp_allocator)
	stmt:sqlite3_stmt;if sqlite3_prepare_v2(conn.db,strings.clone_to_cstring(query,context.temp_allocator),-1,&stmt,nil)!=SQLITE_OK do return nil,domain.domain_error(.Internal_Error,"cannot prepare resource page")
	defer sqlite3_finalize(stmt)
	for value,i in values do bind_text(stmt,i+1,value)
	sqlite3_bind_int64(stmt,i32(len(values)+1),i64(q.limit))
	rows:=make([dynamic]iface.Resource_Ref,context.temp_allocator)
	for {rc:=sqlite3_step(stmt);if rc==SQLITE_DONE do break;if rc!=SQLITE_ROW do return nil,domain.domain_error(.Internal_Error,"cannot read resource page");append(&rows,iface.Resource_Ref{column_text(stmt,0),column_text(stmt,1)})}
	return rows[:],{}
}

issue_comment_get_sqlite :: proc(ctx:rawptr,id:domain.Issue_Comment_ID,owner:domain.User_ID)->(domain.Issue_Comment,bool,domain.Domain_Error) {
	impl:=(^Issue_Repo_SQLite)(ctx)
	query:="SELECT comment_id,issue_id,owner_user_id,author_id,author_name,body,created_at,updated_at FROM issue_comments WHERE comment_id=? AND owner_user_id=?;"
	stmt:sqlite3_stmt;if sqlite3_prepare_v2(impl.conn.db,strings.clone_to_cstring(query,context.temp_allocator),-1,&stmt,nil)!=SQLITE_OK do return {},false,domain.domain_error(.Internal_Error,"cannot read issue comment")
	defer sqlite3_finalize(stmt);bind_text(stmt,1,string(id));bind_text(stmt,2,string(owner))
	if sqlite3_step(stmt)!=SQLITE_ROW do return {},false,domain.domain_error(.Not_Found,"issue comment not found")
	return domain.Issue_Comment{comment_id=domain.Issue_Comment_ID(column_text(stmt,0)),issue_id=domain.Issue_ID(column_text(stmt,1)),owner_user_id=domain.User_ID(column_text(stmt,2)),author_id=column_text(stmt,3),author_name=column_text(stmt,4),body=column_text(stmt,5),created_at=column_text(stmt,6),updated_at=column_text(stmt,7)},true,{}
}
