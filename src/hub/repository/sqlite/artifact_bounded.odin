package sqlite

import "core:strings"
import domain "odin_test:hub/domain"

// Bound allocation before copying any content out of SQLite. Metadata is also
// capped for legacy rows that bypassed API input limits. Never follow blob_ref.
content_get_artifact_bounded_sqlite :: proc(ctx:rawptr,id:string,owner:domain.User_ID,cap:int)->(domain.Artifact,int,bool,domain.Domain_Error) {
	impl:=(^Content_Repo_SQLite)(ctx)
	q:=`SELECT artifact_id,owner_user_id,kind,
 CASE WHEN length(CAST(name AS BLOB))<=49152 THEN name ELSE '' END,
 CASE WHEN length(CAST(description AS BLOB))<=49152 THEN description ELSE '' END,
 content_type,size_bytes,CASE WHEN COALESCE(blob_ref,'')<>'' THEN 'external' ELSE '' END,CASE WHEN length(CAST(content AS BLOB))<=? THEN content ELSE '' END,
 agent_id,agent_instance_id,chain_id,task_id,project_id,mime,ext,sha256,origin_kind,origin_ref,deleted_at,created_at,updated_at,
 length(CAST(content AS BLOB)),length(CAST(name AS BLOB)),length(CAST(description AS BLOB)),
 length(COALESCE(kind,''))+length(COALESCE(content_type,''))+length(COALESCE(mime,''))+length(COALESCE(ext,''))+length(COALESCE(sha256,''))+length(COALESCE(origin_kind,''))+length(COALESCE(origin_ref,''))+length(COALESCE(agent_id,''))+length(COALESCE(agent_instance_id,''))+length(COALESCE(chain_id,''))+length(COALESCE(task_id,''))+length(COALESCE(project_id,''))+length(COALESCE(created_at,''))+length(COALESCE(updated_at,''))
 FROM artifacts WHERE artifact_id=? AND owner_user_id=? AND COALESCE(deleted_at,'')='';`
	stmt:sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db,strings.clone_to_cstring(q,context.temp_allocator),-1,&stmt,nil)!=SQLITE_OK do return {},0,false,domain.domain_error(.Internal_Error,"artifact lookup failed")
	defer sqlite3_finalize(stmt)
	sqlite3_bind_int64(stmt,1,i64(cap));bind_text(stmt,2,id);bind_text(stmt,3,string(owner))
	if sqlite3_step(stmt)!=SQLITE_ROW do return {},0,false,domain.domain_error(.Not_Found,"artifact not found")
	if sqlite3_column_int64(stmt,23)>49152 || sqlite3_column_int64(stmt,24)>49152 || sqlite3_column_int64(stmt,25)>16384 do return {},0,false,domain.domain_error(.Validation_Failed,"artifact metadata too large")
	return artifact_from_stmt(stmt),int(sqlite3_column_int64(stmt,22)),true,{}
}
content_update_artifact_metadata_sqlite :: proc(ctx:rawptr,id:string,owner:domain.User_ID,name,description,updated_at:string)->(bool,domain.Domain_Error) {
	impl:=(^Content_Repo_SQLite)(ctx)
	q:="UPDATE artifacts SET name=CASE WHEN ?='' THEN name ELSE ? END,description=CASE WHEN ?='' THEN description ELSE ? END,updated_at=? WHERE artifact_id=? AND owner_user_id=? AND COALESCE(deleted_at,'')='';"
	stmt:sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db,strings.clone_to_cstring(q,context.temp_allocator),-1,&stmt,nil)!=SQLITE_OK do return false,domain.domain_error(.Internal_Error,"artifact update failed")
	defer sqlite3_finalize(stmt)
	for value,i in ([]string{name,name,description,description,updated_at,id,string(owner)}) do bind_text(stmt,i+1,value)
	rc,changed:=step_changes(impl.conn.db,stmt)
	if rc!=SQLITE_DONE do return false,domain.domain_error(.Internal_Error,"artifact update failed")
	return changed==1,{}
}
