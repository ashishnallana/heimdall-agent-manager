#+feature dynamic-literals
package mcp

import "core:encoding/json"
import domain "odin_test:hub/domain"

CONTROL_COMMENT_MAX_BYTES :: 256*1024
CONTROL_COMMENT_PAGE_BYTES :: 1024*1024
control_comment :: proc(c:domain.Task_Comment)->json.Object {
	kind:="agent" if c.author_agent_instance_id!="" else "user"
	if c.delegated_client_id!="" do kind="delegated_user"
	return json.Object{"owner_user_id"=json.String(c.owner_user_id),"comment_id"=json.String(c.comment_id),"chain_id"=json.String(c.chain_id),"task_id"=json.String(c.task_id),"body"=json.String(c.body),"created_at"=json.String(c.created_at),"author_kind"=json.String(kind),"author_user_id"=json.String(c.owner_user_id),"author_agent_instance_id"=json.String(c.author_agent_instance_id),"delegated_client_id"=json.String(c.delegated_client_id),"delegated_grant_id"=json.String(c.delegated_grant_id)}
}
control_comment_page :: proc(s:^Control_Service,owner:string,args:Control_Arguments)->([]json.Object,string,string) {
	cursor,valid:=task_cursor(owner,"comments",args,args.comment_cursor)
	if !valid do return nil,"","invalid_arguments"
	limit:=args.comment_limit;if limit==0 do limit=50
	if s.chains.repo.list_comments_page==nil do return nil,"","request_failed"
	rows,err:=s.chains.repo.list_comments_page(s.chains.repo.ctx,domain.Task_ID(args.task_id),domain.User_ID(owner),cursor.created_at,cursor.id,limit+1,CONTROL_COMMENT_MAX_BYTES,CONTROL_COMMENT_PAGE_BYTES)
	if err.code!=.None do return nil,"","request_failed"
	out:=make([dynamic]json.Object,context.temp_allocator)
	bytes:=0;next:string
	for item,i in rows {
		if i>=limit {break}
		c:=item.comment
		if item.body_bytes<=CONTROL_COMMENT_MAX_BYTES && bytes+item.body_bytes>CONTROL_COMMENT_PAGE_BYTES do break
		if string(c.owner_user_id)!=owner || string(c.chain_id)!=args.chain_id || string(c.task_id)!=args.task_id do return nil,"","request_failed"
		row:=control_comment(c)
		if item.body_bytes>CONTROL_COMMENT_MAX_BYTES {delete_key(&row,"body");row["body_error"]=json.String("comment_too_large");row["body_bytes"]=json.Integer(item.body_bytes)} else {bytes+=item.body_bytes}
		append(&out,row)
		next=task_cursor_encode(cursor,c.created_at,c.comment_id)
	}
	if len(out)==len(rows) do next=""
	return out[:],next,""
}
