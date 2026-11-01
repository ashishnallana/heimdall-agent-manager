package sqlite

import domain "odin_test:hub/domain"
import "core:strings"

agent_runtime_busy_sqlite :: proc(ctx:rawptr,instance_id:string)->(bool,domain.Domain_Error) {
	impl:=(^Agent_Repo_SQLite)(ctx)
	query:=`SELECT EXISTS(SELECT 1 FROM instance_reconfigurations WHERE agent_instance_id=? AND blocks_input=1) OR EXISTS(SELECT 1 FROM mcp_mutation_receipts WHERE result_id=? AND tool IN ('instances.create','instances.start','instances.stop','instances.reconfigure') AND (CASE WHEN json_valid(result_json) THEN json_extract(result_json,'$.result.phase') END='prepared' OR CASE WHEN json_valid(result_json) THEN json_extract(result_json,'$.result.status') END='repair_required') AND (tool!='instances.reconfigure' OR NOT EXISTS(SELECT 1 FROM instance_reconfigurations op WHERE op.agent_instance_id=mcp_mutation_receipts.result_id AND op.idempotency_key=CASE WHEN json_valid(result_json) THEN json_extract(result_json,'$.native_key') END)));`
	stmt:sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db,strings.clone_to_cstring(query,context.temp_allocator),-1,&stmt,nil)!=SQLITE_OK do return true,domain.domain_error(.Internal_Error,"cannot check pending runtime action")
	defer sqlite3_finalize(stmt)
	bind_text(stmt,1,instance_id);bind_text(stmt,2,instance_id)
	if sqlite3_step(stmt)!=SQLITE_ROW do return true,domain.domain_error(.Internal_Error,"cannot read pending runtime action")
	return column_text_unowned(stmt,0)=="1",{}
}
