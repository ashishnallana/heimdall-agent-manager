#+feature dynamic-literals
package mcp

import "core:testing"
import "core:encoding/json"
import "core:strings"

@(test)
test_artifact_addition_preserves_existing_resource_cursor_encoding :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	old:=`{"owner":"owner","tool":"memories.list","status":"","type":"","agent_id":"","project_id":"","bridge_id":"","template_id":"","scope_type":"","target_id":"","chain_id":"","parent_id":"","created_at":"2026-10-31T07:00:00Z","id":"mem_a"}`
	_,valid:=resource_cursor("owner","memories.list",{},old,"");testing.expect(t,valid)
	a:=Resource_Arguments{task_id="task_a"};cursor,_:=resource_cursor("owner","artifacts.list",a,"","");next:=resource_next(cursor,"2026-10-31T07:00:00Z","art_a")
	_,valid=resource_cursor("owner","artifacts.list",a,next,"");testing.expect(t,valid)
	a.task_id="task_b";_,valid=resource_cursor("owner","artifacts.list",a,next,"");testing.expect(t,!valid)
}

@(test)
test_artifact_digest_binds_prose_mime_and_task_without_map_order :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	a:=Resource_Arguments{request_id="request",task_id="task_a",content_type="text/plain",fields=json.Object{"name"=json.String("Name"),"content"=json.String("Body")}}
	for key,i in RESOURCE_KEYS do if key=="content" do a.present|=u64(1)<<u64(i)
	digest:=resource_write_digest(a)
	a.fields=json.Object{"content"=json.String("Body"),"name"=json.String("Name")};a.limit=2;a.cursor="read filter"
	testing.expect_value(t,resource_write_digest(a),digest)
	a.task_id="task_b";testing.expect(t,resource_write_digest(a)!=digest);a.task_id="task_a"
	a.content_type="text/markdown";testing.expect(t,resource_write_digest(a)!=digest);a.content_type="text/plain"
	a.fields["content"]=json.String("Changed");testing.expect(t,resource_write_digest(a)!=digest)
}
@(test)
test_artifact_device_content_cannot_forge_task_link_metadata_or_exceed_bound :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	row:=json.Object{"artifact_id"=json.String("art_a"),"name"=json.String("sealed"),"content"=json.String("sealed"),"task_id"=json.String("task_a"),"link"=json.String("artifact://art_a")}
	data:=Control_Data{records_kind="artifact",records=[]json.Object{row}}
	encoded,_:=json.marshal(data,allocator=context.temp_allocator);value,_:=json.parse_string(string(encoded),parse_integers=true,allocator=context.temp_allocator)
	root,_:=value.(json.Object);records,_:=root["records"].(json.Array);actual,_:=records[0].(json.Object);actual["name"]=json.String("Readable");actual["content"]=json.String("Readable body")
	text,_:=json.marshal(root,allocator=context.temp_allocator);testing.expect(t,control_result_ok(data,string(text)))
	for key,bad in (map[string]string{"task_id"="task_foreign","link"="https://forged","content"=strings.repeat("x",65537,context.temp_allocator)}) {
		old:=actual[key];actual[key]=json.String(bad);text,_=json.marshal(root,allocator=context.temp_allocator);testing.expect(t,!control_result_ok(data,string(text)));actual[key]=old
	}
}
