package sqlite

import "core:strings"
import domain "odin_test:hub/domain"

task_comment_get_sqlite :: proc(ctx:rawptr,id:string,owner:domain.User_ID)->(domain.Task_Comment,bool,domain.Domain_Error) {
	impl:=(^Taskchain_Repo_SQLite)(ctx)
	query:="SELECT comment_id,task_id,chain_id,owner_user_id,author_agent_instance_id,'',created_at,updated_at,delegated_client_id,delegated_grant_id FROM task_comments WHERE comment_id=? AND owner_user_id=?;"
	stmt:sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db,strings.clone_to_cstring(query,context.temp_allocator),-1,&stmt,nil)!=SQLITE_OK do return {},false,domain.domain_error(.Internal_Error,"cannot read comment attribution")
	defer sqlite3_finalize(stmt)
	bind_text(stmt,1,id);bind_text(stmt,2,string(owner))
	if sqlite3_step(stmt)!=SQLITE_ROW do return {},false,{}
	return task_comment_from_stmt(stmt),true,{}
}

// Read only the selected page, and never materialize an oversized body in RAM.
task_comment_page_sqlite :: proc(ctx:rawptr,task_id:domain.Task_ID,owner:domain.User_ID,after_created,after_id:string,limit,max_body_bytes,max_page_bytes:int)->([]domain.Task_Comment_Page_Item,domain.Domain_Error) {
	impl:=(^Taskchain_Repo_SQLite)(ctx)
	query:="SELECT comment_id,task_id,chain_id,owner_user_id,author_agent_instance_id,CASE WHEN length(CAST(body AS BLOB))<=? THEN body ELSE '' END,created_at,updated_at,delegated_client_id,delegated_grant_id,length(CAST(body AS BLOB)) FROM task_comments WHERE task_id=? AND owner_user_id=? AND (created_at>? OR (created_at=? AND comment_id>?)) ORDER BY created_at,comment_id LIMIT ?;"
	stmt:sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db,strings.clone_to_cstring(query,context.temp_allocator),-1,&stmt,nil)!=SQLITE_OK do return nil,domain.domain_error(.Internal_Error,"cannot prepare comment page")
	defer sqlite3_finalize(stmt)
	sqlite3_bind_int64(stmt,1,i64(max_body_bytes));bind_text(stmt,2,string(task_id));bind_text(stmt,3,string(owner));bind_text(stmt,4,after_created);bind_text(stmt,5,after_created);bind_text(stmt,6,after_id);sqlite3_bind_int64(stmt,7,i64(limit))
	out:=make([dynamic]domain.Task_Comment_Page_Item,context.temp_allocator)
	body_bytes:=0
	for {
		rc:=sqlite3_step(stmt)
		if rc==SQLITE_DONE do break
		if rc!=SQLITE_ROW do return nil,domain.domain_error(.Internal_Error,"cannot read comment page")
		size:=int(sqlite3_column_int64(stmt,10))
		if size<=max_body_bytes && body_bytes+size>max_page_bytes {
			// One metadata-only lookahead preserves has-more without copying the
			// body which belongs to the next page. The projector stops before it.
			append(&out,domain.Task_Comment_Page_Item{comment={comment_id=column_text(stmt,0)},body_bytes=size})
			break
		}
		if size<=max_body_bytes do body_bytes+=size
		append(&out,domain.Task_Comment_Page_Item{comment=task_comment_from_stmt(stmt),body_bytes=size})
	}
	return out[:],{}
}
