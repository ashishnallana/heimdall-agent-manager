package mcp

import "core:encoding/json"

// A keyset position is not an authorization credential. Every use independently
// checks owner/resource/filter equality and performs an owner-scoped query.
Task_Read_Cursor :: struct {kind,owner,chain_id,task_id,state,assignee_agent_id,created_at,id:string}
task_cursor :: proc(owner,kind:string,args:Control_Arguments,raw:string)->(Task_Read_Cursor,bool) {
	base:=Task_Read_Cursor{kind=kind,owner=owner,chain_id=args.chain_id,task_id=args.task_id,state=args.state,assignee_agent_id=args.assignee_agent_id}
	if raw=="" do return base,true
	c:Task_Read_Cursor
	if len(raw)>2048 || json.unmarshal_string(raw,&c,.JSON,context.temp_allocator)!=nil do return {},false
	canonical,err:=json.marshal(c,allocator=context.temp_allocator)
	if err!=nil || string(canonical)!=raw || c.kind!=base.kind || c.owner!=base.owner || c.chain_id!=base.chain_id || c.task_id!=base.task_id || c.state!=base.state || c.assignee_agent_id!=base.assignee_agent_id || c.id=="" || len(c.id)>256 || c.created_at=="" || len(c.created_at)>64 do return {},false
	return c,true
}
task_cursor_encode :: proc(c:Task_Read_Cursor,created_at,id:string)->string {
	out:=c;out.created_at=created_at;out.id=id
	encoded,err:=json.marshal(out,allocator=context.temp_allocator)
	if err!=nil do return ""
	return string(encoded)
}
task_cursor_after :: proc(c:Task_Read_Cursor,created_at,id:string)->bool {return created_at>c.created_at || created_at==c.created_at && id>c.id}
