#+feature dynamic-literals
package mcp

import "core:testing"
import "core:encoding/json"

@(test)
test_resource_scopes_never_imply_read_write_or_approval :: proc(t:^testing.T) {
	for resource in ([]struct {read_scope,write_scope:string,reads,writes:[]string}{
		{"mcp:chains mcp:memories:read","mcp:chains mcp:memories:write",([]string{"memories.list","memories.get"}),([]string{"memories.create","memories.update","memories.archive"})},
		{"mcp:chains mcp:projects:read","mcp:chains mcp:projects:write",([]string{"projects.list","projects.get"}),([]string{"projects.create","projects.update","projects.archive"})},
		{"mcp:chains mcp:issues:read","mcp:chains mcp:issues:write",([]string{"issues.list","issues.get"}),([]string{"issues.create","issues.update","issues.delete","issues.comment"})},
	}) {
		for tool in resource.reads {testing.expect(t,scope_allows_tool(resource.read_scope,tool));testing.expect(t,!scope_allows_tool(resource.write_scope,tool))}
		for tool in resource.writes {testing.expect(t,scope_allows_tool(resource.write_scope,tool));testing.expect(t,!scope_allows_tool(resource.read_scope,tool));testing.expect(t,!scope_allows_tool(DELEGATION_SCOPE,tool))}
		testing.expect(t,!scope_allows_tool(resource.write_scope,"memories.approve"))
	}
}

@(test)
test_resource_digest_is_key_order_independent_and_reads_do_not_change_retries :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	a:=Resource_Arguments{request_id="request",fields=json.Object{"title"=json.String("Title"),"body"=json.String("Body")}}
	digest:=resource_write_digest(a)
	a.fields=json.Object{"body"=json.String("Body"),"title"=json.String("Title")};a.cursor="unrelated paging";a.limit=100
	testing.expect_value(t,resource_write_digest(a),digest)
	a.fields["body"]=json.String("Different");testing.expect(t,resource_write_digest(a)!=digest)
}

@(test)
test_resource_device_results_bind_nested_issue_comments_and_project_paths :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	comment:=json.Object{"comment_id"=json.String("icmt_a"),"issue_id"=json.String("iss_a"),"body"=json.String("sealed"),"author_id"=json.String("owner")}
	row:=json.Object{"issue_id"=json.String("iss_a"),"title"=json.String("sealed"),"comments"=json.Array{comment},"comments_next_cursor"=json.String("cursor")}
	data:=Control_Data{records_kind="issue",records=[]json.Object{row}}
	encoded,_:=json.marshal(data,allocator=context.temp_allocator);value,_:=json.parse_string(string(encoded),parse_integers=true,allocator=context.temp_allocator)
	root,_:=value.(json.Object);rows,_:=root["records"].(json.Array);actual,_:=rows[0].(json.Object);comments,_:=actual["comments"].(json.Array);actual_comment,_:=comments[0].(json.Object)
	actual["title"]=json.String("Readable");actual_comment["body"]=json.String("Readable comment")
	valid,_:=json.marshal(root,allocator=context.temp_allocator);testing.expect(t,control_result_ok(data,string(valid)))
	actual_comment["author_id"]=json.String("forged_author");bad,_:=json.marshal(root,allocator=context.temp_allocator);testing.expect(t,!control_result_ok(data,string(bad)))
	actual_comment["author_id"]=json.String("owner");actual["comments_next_cursor"]=json.String("forged_cursor");bad,_=json.marshal(root,allocator=context.temp_allocator);testing.expect(t,!control_result_ok(data,string(bad)))
	path:=json.Object{"bridge_id"=json.String("brg_a"),"path"=json.String("/owned"),"is_validated"=json.Boolean(false),"last_validated_at"=json.String(""),"updated_at"=json.String("")}
	project_row:=json.Object{"project_id"=json.String("proj_a"),"name"=json.String("sealed"),"bridge_paths"=json.Array{path}}
	project_data:=Control_Data{records_kind="project",records=[]json.Object{project_row}}
	encoded,_=json.marshal(project_data,allocator=context.temp_allocator);value,_=json.parse_string(string(encoded),parse_integers=true,allocator=context.temp_allocator)
	root,_=value.(json.Object);rows,_=root["records"].(json.Array);actual,_=rows[0].(json.Object);actual["name"]=json.String("Readable project")
	valid,_=json.marshal(root,allocator=context.temp_allocator);testing.expect(t,control_result_ok(project_data,string(valid)))
	paths,_:=actual["bridge_paths"].(json.Array);forged,_:=paths[0].(json.Object);forged["path"]=json.String("/forged")
	bad,_=json.marshal(root,allocator=context.temp_allocator);testing.expect(t,!control_result_ok(project_data,string(bad)))
}
