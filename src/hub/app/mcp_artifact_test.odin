#+feature dynamic-literals
package app

import "core:encoding/base64"
import "core:encoding/json"
import "core:testing"
import "core:strings"
import "core:thread"
import "base:runtime"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import mcp "odin_test:hub/service/mcp"
import content "odin_test:hub/service/content"
import project "odin_test:hub/service/project"
import issue "odin_test:hub/service/issue"
import http "odin_test:hub/transport/http"

@(test)
test_mcp_artifact_native_content_task_results_and_lifecycle :: proc(t:^testing.T) {
	mcp_task_test_fixture(t,#load("../../../tests/fixtures/mcp_artifacts_v2.json",string),true,false,false,true)
}
mcp_artifact_test :: proc(t:^testing.T,g:^App_Graph,h:^http.MCP_Control_Handlers,headers:[]contracts.HTTP_Header,view:mcp.Access_View,raw:string) {
	g.repos.content=sqlite.new_content_repository(&g.sqlite_content,&g.db)
	g.repos.projects=sqlite.new_project_repository(&g.sqlite_projects,&g.db)
	g.repos.issues=sqlite.new_issue_repository(&g.sqlite_issues,&g.db)
	g.content=content.new_content_service(&g.repos.content,&g.repos.agents,&g.repos.bridges,&g.repos.projects,&g.repos.taskchains,&g.clock,&g.ids)
	g.projects=project.new_project_service_with_command_sink(&g.repos.projects,&g.repos.bridges,{},&g.clock,&g.ids)
	g.issues=issue.new_issue_service(&g.repos.issues,&g.clock,&g.ids)
	h.control=mcp_resource_control(g);h.mutate_resource=mcp_mutate_resource
	listed:=http.mcp_control_handler(h,{method="POST",path="/api/v1/mcp",headers=headers,body=strings.clone(`{"jsonrpc":"2.0","id":50,"method":"tools/list"}`,context.temp_allocator)})
	tools:struct {result:struct {tools:[]struct {name:string}}};json.unmarshal_string(listed.body,&tools,.JSON,context.temp_allocator);testing.expect_value(t,len(tools.result.tools),46)
	create:=json.Object{"request_id"=json.String("artifact_create"),"name"=json.String("Private result.md"),"description"=json.String("Private summary"),"content"=json.String("# Private result\nTask finished."),"content_type"=json.String("text/markdown"),"task_id"=json.String("task_comment"),"agent_id"=json.String("agt_placement")}
	response:=mcp_resource_heap_call(h,headers,"artifacts.create",create);result:=mcp_task_test_output(t,response);if result==nil do return
	id:=result["resource_id"].(json.String);testing.expect(t,result["link"].(json.String)==json.String(strings.concatenate({"artifact://",string(id)},context.temp_allocator)))
	testing.expect(t,response.body==mcp_resource_heap_call(h,headers,"artifacts.create",create).body)
	native,found,_:=iface.content_get_artifact(&g.repos.content,string(id));testing.expect(t,found && strings.has_prefix(native.content,"vault:v2:") && strings.has_prefix(native.name,"vault:v2:") && strings.has_prefix(native.description,"vault:v2:") && native.chain_id=="chain_comment" && native.task_id=="task_comment")
	row:=mcp_resource_first(t,h,headers,"artifacts.get",json.Object{"artifact_id"=id});if row==nil do return
	testing.expect(t,row["content"].(json.String)=="# Private result\nTask finished." && row["name"].(json.String)=="Private result.md" && row["link"].(json.String)==result["link"].(json.String))
	page:=mcp_task_test_output(t,mcp_resource_heap_call(h,headers,"artifacts.list",json.Object{"task_id"=json.String("task_comment"),"chain_id"=json.String("chain_comment")}));if page==nil do return
	records,_:=page["records"].(json.Array);testing.expect_value(t,len(records),1);summary,_:=records[0].(json.Object);_,has_content:=summary["content"];testing.expect(t,!has_content && summary["artifact_id"].(json.String)==id)
	metadata:=mcp_resource_first(t,h,headers,"artifacts.get",json.Object{"artifact_id"=id,"include_content"=json.Boolean(false)});if metadata==nil do return
	_,has_content=metadata["content"];testing.expect(t,!has_content && metadata["revision"].(json.String)==row["revision"].(json.String))
	create["content"]=json.String("Changed retry");testing.expect(t,strings.contains(mcp_resource_heap_call(h,headers,"artifacts.create",create).body,"idempotency_conflict"));create["content"]=json.String("# Private result\nTask finished.")
	patch:=json.Object{"artifact_id"=id,"request_id"=json.String("artifact_patch"),"expected_revision"=row["revision"],"name"=json.String("Renamed.md"),"description"=json.String("")}
	if mcp_task_test_output(t,mcp_resource_heap_call(h,headers,"artifacts.update",patch))==nil do return
	row=mcp_resource_first(t,h,headers,"artifacts.get",json.Object{"artifact_id"=id});if row==nil do return
	testing.expect(t,row["name"].(json.String)=="Renamed.md" && row["description"].(json.String)=="" && row["content"].(json.String)=="# Private result\nTask finished.")
	patch["request_id"]=json.String("artifact_stale");testing.expect(t,strings.contains(mcp_resource_heap_call(h,headers,"artifacts.update",patch).body,"revision_conflict"))
	for key in ([]string{"path","url","content_base64","owner_user_id","origin_ref","filename","kind"}) {bad:=json.Object{"request_id"=json.String("bad"),"name"=json.String("Result"),"content"=json.String("x"),"content_type"=json.String("text/plain"),key=json.String("/etc/passwd")};_,valid:=http.mcp_arguments("artifacts.create",bad);testing.expect(t,!valid)}
	for text in ([]string{"{broken","{} trailing"}) {_,valid:=http.mcp_arguments("artifacts.create",json.Object{"request_id"=json.String("bad_json"),"name"=json.String("Result.json"),"content"=json.String(text),"content_type"=json.String("application/json")});testing.expect(t,!valid)}
	for bad in ([]struct {tool:string,args:json.Object}{
		{"artifacts.create",json.Object{"request_id"=json.String("bad"),"name"=json.String("Result"),"content"=json.String(strings.repeat("x",65537,context.temp_allocator)),"content_type"=json.String("text/plain")}},
		{"artifacts.create",json.Object{"request_id"=json.String("bad"),"name"=json.String("Result"),"content"=json.String("x"),"content_type"=json.String("text/html")}},
		{"artifacts.update",json.Object{"artifact_id"=id,"request_id"=json.String("bad"),"expected_revision"=row["revision"],"content"=json.String("replacement")}},
	}) {_,valid:=http.mcp_arguments(bad.tool,bad.args);testing.expect(t,!valid)}
	mcp_artifact_bounds_test(t,g,h,headers,view)
	json_input:=json.Object{"request_id"=json.String("artifact_json"),"name"=json.String("Result.json"),"content_type"=json.String("application/json"),"content"=json.String(`{"ok":true,"label":"π"}`)}
	json_result:=mcp_task_test_output(t,mcp_resource_heap_call(h,headers,"artifacts.create",json_input));if json_result==nil do return
	json_row:=mcp_resource_first(t,h,headers,"artifacts.get",json.Object{"artifact_id"=json_result["resource_id"]});if json_row!=nil do testing.expect(t,json_row["content"].(json.String)==`{"ok":true,"label":"π"}`)
	mcp_artifact_security_test(t,g,h,headers,view,raw,create)
	mcp_artifact_bundle_test(t,g,h,headers,view)
	del:=json.Object{"artifact_id"=id,"request_id"=json.String("artifact_delete"),"expected_revision"=row["revision"]}
	deleted:=mcp_resource_heap_call(h,headers,"artifacts.delete",del);if mcp_task_test_output(t,deleted)==nil do return
	_,found,_=iface.content_get_artifact(&g.repos.content,string(id));testing.expect(t,!found,"native artifact delete is permanent")
	testing.expect(t,deleted.body==mcp_resource_heap_call(h,headers,"artifacts.delete",del).body,"receipt replay survives deletion")
	testing.expect(t,strings.contains(mcp_resource_heap_call(h,headers,"artifacts.get",json.Object{"artifact_id"=id}).body,"not_found"))
	// A native task-produced result uses the same encrypted content contract.
	produced,ok,_:=content.create_artifact(&g.content,mcp.control_auth(view.owner),{name=native.name,description=native.description,content=native.content,content_type="text/markdown",task_id="task_comment",chain_id="chain_comment"});testing.expect(t,ok)
	result_row:=mcp_resource_first(t,h,headers,"artifacts.get",json.Object{"artifact_id"=json.String(produced.artifact_id)});if result_row!=nil do testing.expect(t,result_row["content"].(json.String)=="# Private result\nTask finished.")
	h.mutate_resource=mcp_resource_revoke;create["request_id"]=json.String("artifact_revoked")
	testing.expect(t,mcp_resource_heap_call(h,headers,"artifacts.create",create).status==401)
	_,_,receipt,_:=sqlite.mcp_receipt_get(&g.db,view.owner,view.grant,"artifacts.create","artifact_revoked");testing.expect(t,!receipt)
}
mcp_artifact_bounds_test :: proc(t:^testing.T,g:^App_Graph,h:^http.MCP_Control_Handlers,headers:[]contracts.HTTP_Header,view:mcp.Access_View) {
	for value in ([]struct {id,mime,body,error:string}{
		{"art_large","text/plain",strings.repeat("x",128*1024+1,context.temp_allocator),"content_too_large"},
		{"art_binary","image/png","\x00PNG","unsupported_content_type"},
	}) {
		_,_,_=iface.content_save_artifact(&g.repos.content,{artifact_id=value.id,owner_user_id=domain.User_ID(view.owner),name="Native result",content=value.body,content_type=value.mime,size_bytes=len(value.body),created_at=mcp_task_test_now(nil),updated_at=mcp_task_test_now(nil)})
		row:=mcp_resource_first(t,h,headers,"artifacts.get",json.Object{"artifact_id"=json.String(value.id)});if row==nil do continue
		_,present:=row["content"];testing.expect(t,!present && row["content_error"].(json.String)==json.String(value.error))
		if mcp_task_test_output(t,mcp_resource_heap_call(h,headers,"artifacts.update",json.Object{"artifact_id"=json.String(value.id),"request_id"=json.String(value.id),"expected_revision"=row["revision"],"name"=json.String("Renamed native result")}))==nil do return
		bounded,size,found,_:=content.get_artifact_bounded(&g.content,mcp.control_auth(view.owner),value.id,0);testing.expect(t,found && bounded.content=="" && size==len(value.body))
		row=mcp_resource_first(t,h,headers,"artifacts.get",json.Object{"artifact_id"=json.String(value.id),"include_content"=json.Boolean(false)});if row==nil do continue
		if mcp_task_test_output(t,mcp_resource_heap_call(h,headers,"artifacts.delete",json.Object{"artifact_id"=json.String(value.id),"request_id"=json.String(value.id),"expected_revision"=row["revision"]}))==nil do return
		_,found,_=iface.content_get_artifact(&g.repos.content,value.id);testing.expect(t,!found)
	}
	_,_,_=iface.content_save_artifact(&g.repos.content,{artifact_id="art_blob",owner_user_id=domain.User_ID(view.owner),name="External blob",blob_ref="/never/read/server/path",content_type="text/plain"})
	blob:=mcp_resource_first(t,h,headers,"artifacts.get",json.Object{"artifact_id"=json.String("art_blob")});if blob!=nil do testing.expect(t,blob["content_error"].(json.String)=="content_unavailable")
	_,_,_=iface.content_save_artifact(&g.repos.content,{artifact_id="art_tombstone",owner_user_id=domain.User_ID(view.owner),name="Deleted",content_type="text/plain",deleted_at=mcp_task_test_now(nil)})
	testing.expect(t,strings.contains(mcp_resource_heap_call(h,headers,"artifacts.get",json.Object{"artifact_id"=json.String("art_tombstone")}).body,"not_found"))
	_,_,_=iface.content_save_artifact(&g.repos.content,{artifact_id="art_legacy_markdown",owner_user_id=domain.User_ID(view.owner),name="Legacy result",kind="markdown",content="Legacy task result"})
	legacy:=mcp_resource_first(t,h,headers,"artifacts.get",json.Object{"artifact_id"=json.String("art_legacy_markdown")});if legacy!=nil do testing.expect(t,legacy["content"].(json.String)=="Legacy task result" && legacy["content_type"].(json.String)=="text/markdown")
	// Stable ties and cursor filter binding; metadata pages never include content.
	now:=mcp_task_test_now(nil)
	for id in ([]string{"art_page_a","art_page_b"}) do _,_,_=iface.content_save_artifact(&g.repos.content,{artifact_id=id,owner_user_id=domain.User_ID(view.owner),name="Page result",task_id="task_comment",content_type="text/plain",content="Page",created_at=now,updated_at=now})
	seen:=make(map[string]bool,context.temp_allocator);cursor:=""
	for _ in 0..<10 {
		args:=json.Object{"task_id"=json.String("task_comment"),"limit"=json.Integer(1)};if cursor!="" do args["cursor"]=json.String(cursor)
		page:=mcp_task_test_output(t,mcp_resource_heap_call(h,headers,"artifacts.list",args));if page==nil do return
		rows,_:=page["records"].(json.Array);for item in rows {row,_:=item.(json.Object);id:=string(row["artifact_id"].(json.String));testing.expect(t,!seen[id]);seen[id]=true}
		cursor=mcp.resource_text(page,"next_cursor");if cursor=="" do break
		if len(seen)==1 {bad:=json.Object{"task_id"=json.String("task_missing"),"limit"=json.Integer(1),"cursor"=json.String(cursor)};testing.expect(t,strings.contains(mcp_resource_heap_call(h,headers,"artifacts.list",bad).body,"not_found"))}
	}
	testing.expect(t,seen["art_page_a"] && seen["art_page_b"])
}
mcp_artifact_security_test :: proc(t:^testing.T,g:^App_Graph,h:^http.MCP_Control_Handlers,headers:[]contracts.HTTP_Header,view:mcp.Access_View,raw:string,create:json.Object) {
	_,_,_=iface.content_save_artifact(&g.repos.content,{artifact_id="art_foreign",owner_user_id="foreign_owner",name="foreign secret",content="foreign content",content_type="text/plain"})
	for action in ([]string{"get","update","delete"}) {
		args:=json.Object{"artifact_id"=json.String("art_foreign")};if action!="get" {args["request_id"]=json.String("foreign");args["expected_revision"]=json.String(strings.repeat("0",64,context.temp_allocator))};if action=="update" do args["name"]=json.String("Never change")
		response:=mcp_resource_heap_call(h,headers,strings.concatenate({"artifacts.",action},context.temp_allocator),args);testing.expect(t,strings.contains(response.body,"not_found") && !strings.contains(response.body,"foreign content"))
	}
	for field,id in (map[string]string{"agent_id"="agt_placement_foreign","project_id"="proj_missing","chain_id"="chain_missing","task_id"="task_missing","agent_instance_id"="inst_missing"}) {
		args:=make(json.Object,context.temp_allocator);for k,v in create do args[k]=v;args[field]=json.String(id);args["request_id"]=json.String(strings.concatenate({"foreign_",field},context.temp_allocator))
		testing.expect(t,strings.contains(mcp_resource_heap_call(h,headers,"artifacts.create",args).body,"not_found"))
	}
	testing.expect(t,sqlite.exec(&g.db,"CREATE TRIGGER artifact_fail_receipt BEFORE INSERT ON mcp_mutation_receipts WHEN NEW.request_id='artifact_rollback' BEGIN SELECT RAISE(ABORT,'synthetic receipt failure'); END;"))
	input:=make(json.Object,context.temp_allocator);for key,value in create do input[key]=value
	input["request_id"]=json.String("artifact_rollback");testing.expect(t,strings.contains(mcp_resource_heap_call(h,headers,"artifacts.create",input).body,"request_failed"))
	_,_,exists,_:=sqlite.mcp_receipt_get(&g.db,view.owner,view.grant,"artifacts.create","artifact_rollback");testing.expect(t,!exists)
	testing.expect(t,sqlite.exec(&g.db,"DROP TRIGGER artifact_fail_receipt;"))
	created:=mcp_task_test_output(t,mcp_resource_heap_call(h,headers,"artifacts.create",input));if created==nil do return
	// Exercise the actual native UOW/receipt boundary without the ingress registry.
	args,valid:=http.mcp_arguments("artifacts.create",input);testing.expect(t,valid);args.resource.request_id="artifact_concurrent"
	sealed,found,_:=iface.content_get_artifact(&g.repos.content,string(created["resource_id"].(json.String)));testing.expect(t,found)
	command:=mcp.Resource_Command{tool="artifacts.create",digest=mcp.resource_write_digest(args.resource),args=args.resource,sealed=json.Object{"name"=json.String(sealed.name),"description"=json.String(sealed.description),"content"=json.String(sealed.content)}}
	jobs:[4]MCP_Resource_Race;threads:[4]^thread.Thread
	allocator:=context.allocator;context.allocator=runtime.heap_allocator()
	for &job,i in jobs {job.g=g;job.raw=raw;job.view=view;job.command=command;threads[i]=thread.create_and_start_with_poly_data(&jobs[i],mcp_resource_race)}
	for th in threads {thread.join(th);thread.destroy(th)}
	context.allocator=allocator
	for job in jobs do testing.expect(t,job.ok && job.len==jobs[0].len && job.result==jobs[0].result)
}

// Claude-style entry/files JSON -> MCP handler -> pack -> relay seal -> vault store.
mcp_artifact_bundle_test :: proc(t:^testing.T,g:^App_Graph,h:^http.MCP_Control_Handlers,headers:[]contracts.HTTP_Header,view:mcp.Access_View) {
	png:=[]byte{0x89,'P','N','G',0x0d,0x0a,0x1a,0x0a,0x00,0xff};png64,_:=base64.encode(png,allocator=context.temp_allocator)
	files:=json.Object{"index.html"=json.Object{"text"=json.String("<!doctype html><link rel=stylesheet href=styles.css><img src=logo.png>")},"styles.css"=json.Object{"text"=json.String("body {color:red}")},"logo.png"=json.Object{"base64"=json.String(png64),"type"=json.String("image/png")}}
	create:=json.Object{"request_id"=json.String("bundle_create"),"name"=json.String("Site"),"description"=json.String("Static site"),"entry"=json.String("index.html"),"files"=files,"task_id"=json.String("task_comment")}
	response:=mcp_resource_heap_call(h,headers,"artifacts.create",create);result:=mcp_task_test_output(t,response);if result==nil do return
	id:=string(result["resource_id"].(json.String))
	testing.expect(t,response.body==mcp_resource_heap_call(h,headers,"artifacts.create",create).body,"bundle create replays its receipt")
	native,found,_:=iface.content_get_artifact(&g.repos.content,id)
	testing.expect(t,found && native.kind=="html-bundle" && native.content_type=="application/zip" && native.ext=="zip" && strings.has_prefix(native.content,"vault:v2:") && strings.has_prefix(native.name,"vault:v2:") && native.chain_id=="chain_comment")
	testing.expect(t,!strings.contains(native.content,"color:red") && !strings.contains(native.content,"doctype"),"stored content is ciphertext only")
	row:=mcp_resource_first(t,h,headers,"artifacts.get",json.Object{"artifact_id"=json.String(id)})
	if row!=nil do testing.expect(t,row["kind"].(json.String)=="html-bundle" && row["name"].(json.String)=="Site")
	// Changed input under the same request_id is a conflict, not a silent replay.
	files["styles.css"]=json.Object{"text"=json.String("body {color:blue}")}
	testing.expect(t,strings.contains(mcp_resource_heap_call(h,headers,"artifacts.create",create).body,"idempotency_conflict"))
	// Validation errors name the reason and store nothing.
	for bad in ([]json.Object{
		json.Object{"../x.html"=json.Object{"text"=json.String("x")}},
		json.Object{"index.html"=json.Object{"text"=json.String("x"),"base64"=json.String("eA==")}},
		json.Object{"index.html"=json.Object{"text"=json.String("x")},"a.png"=json.Object{"base64"=json.String("%%%")}},
		json.Object{"index.html"=json.Object{"text"=json.String("x")},"a.exe"=json.Object{"base64"=json.String("eA==")}},
		json.Object{"other.html"=json.Object{"text"=json.String("x")}},
	}) {
		body:=mcp_resource_heap_call(h,headers,"artifacts.create",json.Object{"request_id"=json.String("bundle_bad"),"name"=json.String("Bad"),"entry"=json.String("index.html"),"files"=bad}).body
		testing.expectf(t,strings.contains(body,"invalid_bundle"),"expected invalid_bundle, got %s",body)
	}
	for bad in ([]json.Object{
		json.Object{"request_id"=json.String("b"),"name"=json.String("B"),"entry"=json.String("index.html")},
		json.Object{"request_id"=json.String("b"),"name"=json.String("B"),"files"=files},
		json.Object{"request_id"=json.String("b"),"name"=json.String("B"),"entry"=json.String("index.html"),"files"=files,"content"=json.String("x"),"content_type"=json.String("text/plain")},
		json.Object{"request_id"=json.String("b"),"name"=json.String("B"),"entry"=json.String("index.html"),"files"=files,"content_type"=json.String("text/plain")},
		json.Object{"request_id"=json.String("b"),"name"=json.String("B"),"content"=json.String("x"),"content_type"=json.String("application/zip")},
		json.Object{"request_id"=json.String("b"),"name"=json.String("B"),"entry"=json.String("index.html"),"files"=json.Array{}},
	}) {_,valid:=http.mcp_arguments("artifacts.create",bad);testing.expect(t,!valid)}
	// Only artifacts.create with files may exceed the 512 KiB control body.
	big:=strings.concatenate({`{"jsonrpc":"2.0","id":77,"method":"tools/call","params":{"name":"memories.list","arguments":{"cursor":"`,strings.repeat("x",600*1024,context.temp_allocator),`"}}}`},context.temp_allocator)
	refused:=http.mcp_control_handler(h,{method="POST",path="/api/v1/mcp",headers=headers,body=big})
	testing.expect(t,strings.contains(refused.body,"request_too_large"))
}
