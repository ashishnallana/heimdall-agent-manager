package sqlite

import iface "odin_test:hub/repository/iface"
import domain "odin_test:hub/domain"
import "core:strings"

@(private="file")
prepare :: proc(conn:^Conn,query:string)->(sqlite3_stmt,bool) {
	stmt:sqlite3_stmt
	rc:=sqlite3_prepare_v2(conn.db,strings.clone_to_cstring(query,context.temp_allocator),-1,&stmt,nil)
	return stmt,rc==SQLITE_OK
}
@(private="file")
repo_err :: proc(message:string)->domain.Domain_Error {return domain.domain_error(.Internal_Error,message)}

// The caller owns the native outer unit of work. Never begin another connection
// or flush side effects while checking the grant and writing the business row.
mcp_transaction_view :: proc(conn:^Conn)->iface.MCP_Transaction {
	return {ctx=conn,get=mcp_get_sqlite,put=mcp_put_sqlite,remove=mcp_remove_sqlite,list=mcp_list_sqlite}
}
mcp_receipt_get :: proc(conn:^Conn,owner,grant,tool,request_id:string)->(digest,result_id:string,found:bool,err:domain.Domain_Error) {
	stmt,ok:=prepare(conn,"SELECT argument_digest,result_id FROM mcp_mutation_receipts WHERE owner_user_id=? AND grant_id=? AND tool=? AND request_id=?;")
	if !ok do return "","",false,repo_err("cannot read MCP mutation receipt")
	defer sqlite3_finalize(stmt)
	bind_text(stmt,1,owner);bind_text(stmt,2,grant);bind_text(stmt,3,tool);bind_text(stmt,4,request_id)
	rc:=sqlite3_step(stmt)
	if rc==SQLITE_DONE do return "","",false,{}
	if rc!=SQLITE_ROW do return "","",false,repo_err("cannot read MCP mutation receipt")
	return strings.clone(column_text_unowned(stmt,0),context.temp_allocator),strings.clone(column_text_unowned(stmt,1),context.temp_allocator),true,{}
}
mcp_receipt_put :: proc(conn:^Conn,owner,grant,tool,request_id,digest,result_id:string,result_json:string="")->domain.Domain_Error {
	stmt,ok:=prepare(conn,"INSERT INTO mcp_mutation_receipts(owner_user_id,grant_id,tool,request_id,argument_digest,result_id,result_json) VALUES(?,?,?,?,?,?,?);")
	if !ok do return repo_err("cannot prepare MCP mutation receipt")
	defer sqlite3_finalize(stmt)
	bind_text(stmt,1,owner);bind_text(stmt,2,grant);bind_text(stmt,3,tool);bind_text(stmt,4,request_id);bind_text(stmt,5,digest);bind_text(stmt,6,result_id)
	bind_text(stmt,7,result_json)
	if sqlite3_step(stmt)!=SQLITE_DONE do return repo_err("cannot write MCP mutation receipt")
	return {}
}

mcp_receipt_result :: proc(conn:^Conn,owner,grant,tool,request_id:string)->(string,bool) {
	stmt,ok:=prepare(conn,"SELECT result_json FROM mcp_mutation_receipts WHERE owner_user_id=? AND grant_id=? AND tool=? AND request_id=?;")
	if !ok do return "",false
	defer sqlite3_finalize(stmt)
	bind_text(stmt,1,owner);bind_text(stmt,2,grant);bind_text(stmt,3,tool);bind_text(stmt,4,request_id)
	if sqlite3_step(stmt)!=SQLITE_ROW do return "",false
	return strings.clone(column_text_unowned(stmt,0),context.temp_allocator),true
}
