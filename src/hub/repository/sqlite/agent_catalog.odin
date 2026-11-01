package sqlite

import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

agent_catalog_refs :: proc(ctx:rawptr,q:iface.Agent_Catalog_Query,instances:bool)->([]iface.Agent_Catalog_Ref,domain.Domain_Error) {
	impl:=(^Agent_Repo_SQLite)(ctx)
	if q.limit<1 || q.limit>101 do return nil,domain.domain_error(.Validation_Failed,"invalid page limit")
	table:="agents";id:="agent_id"
	if instances {table="agent_instances";id="agent_instance_id"}
	query:=strings.concatenate({"SELECT ",id,",created_at FROM ",table," WHERE owner_user_id=? AND (created_at>? OR (created_at=? AND ",id,">?))"},context.temp_allocator)
	if instances {query=strings.concatenate({query," AND kind='agent' AND (?='' OR runtime_status=?) AND (?='' OR agent_id=?) AND (?='' OR bridge_id=?)"},context.temp_allocator)} else {query=strings.concatenate({query," AND (?='' OR state=?)"},context.temp_allocator)}
	query=strings.concatenate({query," ORDER BY created_at,",id," LIMIT ?;"},context.temp_allocator)
	stmt:sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db,strings.clone_to_cstring(query,context.temp_allocator),-1,&stmt,nil)!=SQLITE_OK do return nil,domain.domain_error(.Internal_Error,"cannot prepare catalog page")
	defer sqlite3_finalize(stmt)
	bind_text(stmt,1,string(q.owner));bind_text(stmt,2,q.after_created);bind_text(stmt,3,q.after_created);bind_text(stmt,4,q.after_id);bind_text(stmt,5,q.state);bind_text(stmt,6,q.state)
	index:=7
	if instances {bind_text(stmt,7,q.agent_id);bind_text(stmt,8,q.agent_id);bind_text(stmt,9,q.bridge_id);bind_text(stmt,10,q.bridge_id);index=11}
	sqlite3_bind_int64(stmt,i32(index),i64(q.limit))
	rows:=make([dynamic]iface.Agent_Catalog_Ref,context.temp_allocator)
	for {rc:=sqlite3_step(stmt);if rc==SQLITE_DONE do break;if rc!=SQLITE_ROW do return nil,domain.domain_error(.Internal_Error,"cannot read catalog page");append(&rows,iface.Agent_Catalog_Ref{column_text(stmt,0),column_text(stmt,1)})}
	return rows[:],{}
}
agent_catalog_agents :: proc(ctx:rawptr,q:iface.Agent_Catalog_Query)->([]iface.Agent_Catalog_Ref,domain.Domain_Error) {return agent_catalog_refs(ctx,q,false)}
agent_catalog_instances :: proc(ctx:rawptr,q:iface.Agent_Catalog_Query)->([]iface.Agent_Catalog_Ref,domain.Domain_Error) {return agent_catalog_refs(ctx,q,true)}
