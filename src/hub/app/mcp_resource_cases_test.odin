#+feature dynamic-literals
package app

import "core:encoding/json"
import "core:testing"
import "core:strings"
import "core:fmt"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import mcp "odin_test:hub/service/mcp"
import http "odin_test:hub/transport/http"

mcp_resource_issue_test :: proc(t:^testing.T,g:^App_Graph,h:^http.MCP_Control_Handlers,headers:[]contracts.HTTP_Header,view:mcp.Access_View,pid:json.String) {
	create:=json.Object{"request_id"=json.String("resource_issue"),"title"=json.String("Private issue"),"description"=json.String("Private issue description"),"scope_type"=json.String("project"),"target_id"=pid,"chain_id"=json.String("chain_placement")}
	result:=mcp_task_test_output(t,mcp_resource_heap_call(h,headers,"issues.create",create));if result==nil do return
	id:=result["resource_id"].(json.String)
	row:=mcp_resource_first(t,h,headers,"issues.get",json.Object{"issue_id"=id});if row==nil do return
	testing.expect(t,row["title"].(json.String)=="Private issue" && row["created_by"].(json.String)==json.String(view.owner) && row["comments"]==nil)
	edit:=json.Object{"issue_id"=id,"request_id"=json.String("resource_issue_fix"),"expected_revision"=row["revision"],"status"=json.String("fixed"),"description"=json.String("")}
	if mcp_task_test_output(t,mcp_resource_heap_call(h,headers,"issues.update",edit))==nil do return
	row=mcp_resource_first(t,h,headers,"issues.get",json.Object{"issue_id"=id});if row==nil do return
	testing.expect(t,row["status"].(json.String)=="fixed" && row["closed_at"].(json.String)!="" && row["description"].(json.String)=="")
	for i in 0..<3 {
		comment:=json.Object{"issue_id"=id,"request_id"=json.String(fmt.tprintf("resource_comment_%d",i)),"expected_revision"=row["revision"],"body"=json.String(fmt.tprintf("Private comment %d",i))}
		response:=mcp_resource_heap_call(h,headers,"issues.comment",comment)
		if mcp_task_test_output(t,response)==nil do return
		testing.expect(t,response.body==mcp_resource_heap_call(h,headers,"issues.comment",comment).body)
		row=mcp_resource_first(t,h,headers,"issues.get",json.Object{"issue_id"=id});if row==nil do return
	}
	args:=json.Object{"issue_id"=id,"include_comments"=json.Boolean(true),"comment_limit"=json.Integer(1)};count:=0
	for _ in 0..<4 {
		page:=mcp_resource_first(t,h,headers,"issues.get",args);if page==nil do return
		comments,_:=page["comments"].(json.Array);count+=len(comments)
		for value in comments {c,_:=value.(json.Object);testing.expect(t,c["author_id"].(json.String)==json.String(view.owner) && strings.has_prefix(string(c["body"].(json.String)),"Private comment"))}
		next,_:=page["comments_next_cursor"].(json.String);if next=="" do break;args["comment_cursor"]=next
	}
	testing.expect_value(t,count,3)
	// Native add_comment ignores its final issue-update failure. The adapter
	// rechecks that native write so this whole transaction still rolls back.
	testing.expect(t,sqlite.exec(&g.db,"CREATE TRIGGER resource_issue_update_fail BEFORE UPDATE ON issues BEGIN SELECT RAISE(ABORT,'synthetic issue update failure'); END;"))
	bad_comment:=json.Object{"issue_id"=id,"request_id"=json.String("resource_comment_rollback"),"expected_revision"=row["revision"],"body"=json.String("Must roll back")}
	testing.expect(t,strings.contains(mcp_resource_heap_call(h,headers,"issues.comment",bad_comment).body,"request_failed"))
	sqlite.exec(&g.db,"DROP TRIGGER resource_issue_update_fail;")
	i,_,_:=iface.issue_get(&g.repos.issues,domain.Issue_ID(id),domain.User_ID(view.owner));testing.expect_value(t,i.comment_count,3)
	delete_args:=json.Object{"issue_id"=id,"request_id"=json.String("resource_issue_delete"),"expected_revision"=row["revision"]}
	deleted:=mcp_resource_heap_call(h,headers,"issues.delete",delete_args)
	if mcp_task_test_output(t,deleted)==nil do return
	testing.expect(t,deleted.body==mcp_resource_heap_call(h,headers,"issues.delete",delete_args).body,"delete retries survive missing rows")
	_,found,_:=iface.issue_get(&g.repos.issues,domain.Issue_ID(id),domain.User_ID(view.owner));testing.expect(t,!found)
	comments,_:=iface.issue_list_comments(&g.repos.issues,domain.Issue_ID(id),domain.User_ID(view.owner));testing.expect_value(t,len(comments),0)
	// References may never smuggle a foreign owner through issue metadata.
	create["request_id"]=json.String("resource_foreign_scope");create["scope_type"]=json.String("bridge_id");create["target_id"]=json.String("brg_placement_foreign")
	testing.expect(t,strings.contains(mcp_resource_heap_call(h,headers,"issues.create",create).body,"not_found"))
}
mcp_resource_paging_test :: proc(t:^testing.T,g:^App_Graph,h:^http.MCP_Control_Handlers,headers:[]contracts.HTTP_Header,view:mcp.Access_View,pid:json.String) {
	for i in 0..<5 {
		create:=json.Object{"request_id"=json.String(fmt.tprintf("resource_page_%d",i)),"body"=json.String("Paged private body"),"type"=json.String("episode"),"project_ids"=json.Array{pid}}
		if mcp_task_test_output(t,mcp_resource_heap_call(h,headers,"memories.create",create))==nil do return
	}
	a:=json.Object{"status"=json.String("pending"),"type"=json.String("episode"),"project_id"=pid,"limit"=json.Integer(2)};count:=0;previous:="";first_cursor:json.String
	for i in 0..<4 {
		page:=mcp_task_test_output(t,mcp_resource_heap_call(h,headers,"memories.list",a));if page==nil do return
		rows,_:=page["records"].(json.Array);count+=len(rows)
		for value in rows {row,_:=value.(json.Object);id:=string(row["memory_id"].(json.String));testing.expect(t,id>previous && row["body"]==nil && row["evidence"]==nil);previous=id}
		next,_:=page["next_cursor"].(json.String);if next=="" do break;if i==0 do first_cursor=next;a["cursor"]=next
	}
	testing.expect_value(t,count,5)
	a["cursor"]=first_cursor;a["type"]=json.String("fact");testing.expect(t,strings.contains(mcp_resource_heap_call(h,headers,"memories.list",a).body,"invalid_arguments"))
	// Same-timestamp issue/project pages also use IDs, never offset cursors.
	for family in ([]string{"projects","issues"}) {
		for i in 0..<3 {args:=json.Object{"request_id"=json.String(fmt.tprintf("%s_page_%d",family,i))};if family=="projects" {args["name"]=json.String("Paged project");args["default_path"]=json.String("/synthetic")} else {args["title"]=json.String("Paged issue");args["scope_type"]=json.String("project");args["target_id"]=pid};if mcp_task_test_output(t,mcp_resource_heap_call(h,headers,strings.concatenate({family,".create"},context.temp_allocator),args))==nil do return}
		page_args:=json.Object{"limit"=json.Integer(1)};if family=="issues" {page_args["scope_type"]=json.String("project");page_args["target_id"]=pid}
		seen:=make(map[string]bool,context.temp_allocator);n:=0
		for _ in 0..<6 {page:=mcp_task_test_output(t,mcp_resource_heap_call(h,headers,strings.concatenate({family,".list"},context.temp_allocator),page_args));if page==nil do return;rows,_:=page["records"].(json.Array);for value in rows {row,_:=value.(json.Object);key:="project_id";if family=="issues" do key="issue_id";id:=string(row[key].(json.String));testing.expect(t,!seen[id]);seen[id]=true;n+=1};next,_:=page["next_cursor"].(json.String);if next=="" do break;page_args["cursor"]=next}
		testing.expect(t,n>=3)
	}
}
mcp_resource_commit_test :: proc(t:^testing.T,g:^App_Graph,h:^http.MCP_Control_Handlers,headers:[]contracts.HTTP_Header,view:mcp.Access_View,sample:json.Object,probe:^MCP_Task_Attention_Probe) {
	create:=sample
	testing.expect(t,sqlite.exec(&g.db,"PRAGMA foreign_keys=ON; CREATE TABLE resource_parent(id INTEGER PRIMARY KEY); CREATE TABLE resource_child(id INTEGER REFERENCES resource_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER resource_fail_commit AFTER INSERT ON mcp_mutation_receipts WHEN NEW.request_id='resource_commit_failure' BEGIN INSERT INTO resource_child(id) VALUES(999); END;"))
	before:=probe.notices;create["request_id"]=json.String("resource_commit_failure")
	testing.expect(t,strings.contains(mcp_resource_heap_call(h,headers,"memories.create",create).body,"request_failed"))
	testing.expect(t,probe.notices==before && !probe.inside_transaction,"failed COMMIT discards attention hooks")
	_,_,receipt,_:=sqlite.mcp_receipt_get(&g.db,view.owner,view.grant,"memories.create","resource_commit_failure");testing.expect(t,!receipt)
	testing.expect(t,sqlite.exec(&g.db,"DROP TRIGGER resource_fail_commit; DROP TABLE resource_child; DROP TABLE resource_parent;"))
	if mcp_task_test_output(t,mcp_resource_heap_call(h,headers,"memories.create",create))==nil do return
	testing.expect(t,probe.notices==before+1 && !probe.inside_transaction)
}
