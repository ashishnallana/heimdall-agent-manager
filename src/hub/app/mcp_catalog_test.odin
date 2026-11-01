#+feature dynamic-literals
package app

import "core:testing"
import "core:encoding/json"
import "core:strings"
import "core:fmt"
import "core:thread"
import "base:runtime"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import mcp "odin_test:hub/service/mcp"
import provider "odin_test:hub/service/provider"
import http "odin_test:hub/transport/http"

mcp_catalog_first :: proc(t:^testing.T,h:^http.MCP_Control_Handlers,headers:[]contracts.HTTP_Header,tool:string,args:json.Object)->json.Object {
	data:=mcp_task_test_output(t,mcp_task_test_call(h,headers,tool,args));if data==nil do return nil
	rows,_:=data["records"].(json.Array)
	if !testing.expect(t,len(rows)==1) do return nil
	row,_:=rows[0].(json.Object);return row
}
mcp_catalog_revoke_before_write :: proc(ctx:rawptr,raw:string,view:mcp.Access_View,command:mcp.Catalog_Command)->(string,string) {
	g:=(^App_Graph)(ctx);_ = mcp.delegation_revoke(&g.mcp_delegation,view.owner,view.grant)
	return mcp_mutate_catalog(g,raw,view,command)
}
mcp_catalog_test :: proc(t:^testing.T,g:^App_Graph,h:^http.MCP_Control_Handlers,headers:[]contracts.HTTP_Header,view:mcp.Access_View,raw:string) {
	g.providers=provider.new_provider_service(&g.provider_repo)
	g.agents.clock=&g.clock;g.agents.ids=&g.ids
	owner:=domain.User_ID(view.owner);now:=mcp_task_test_now(nil)
	listed:=http.mcp_control_handler(h,{method="POST",path="/api/v1/mcp",headers=headers,body=strings.clone(`{"jsonrpc":"2.0","id":50,"method":"tools/list"}`,context.temp_allocator)})
	catalog:struct {result:struct {tools:[]struct {name:string}}}
	testing.expect(t,json.unmarshal_string(listed.body,&catalog,.JSON,context.temp_allocator)==nil && len(catalog.result.tools)==21)
	visible:=make(map[string]bool,context.temp_allocator);for tool in catalog.result.tools do visible[tool.name]=true
	for tool in ([]string{"agents.list","agents.get","agents.create","agents.update","agents.archive","bridges.list","providers.list","instances.list","instances.get"}) do testing.expect(t,visible[tool])
	testing.expect(t,!visible["instances.start"] && !visible["agents.delete"] && !visible["messages.send"])
	for bad in ([]struct {tool:string,args:json.Object}{
		{"agents.get",json.Object{"agent_id"=json.String("inst_wrong_kind")}},
		{"instances.get",json.Object{"agent_instance_id"=json.String("agt_wrong_kind")}},
		{"agents.create",json.Object{"request_id"=json.String("invalid"),"name"=json.String("Name"),"environment"=json.Object{}}},
		{"agents.update",json.Object{"agent_id"=json.String("agt_a"),"request_id"=json.String("invalid"),"expected_revision"=json.String("bad"),"state"=json.String("active")}},
		{"providers.list",json.Object{"bridge_id"=json.String("brg_a"),"model_cursor"=json.String("unbound")}},
		{"agents.list",json.Object{"state"=json.String("arbitrary")}},
	}) {_,ok:=http.mcp_arguments(bad.tool,bad.args);testing.expect(t,!ok)}
	// Exercise the complete transport bound, including JSON's sixfold escaping.
	large_body:=strings.repeat("\x01",65536,context.temp_allocator)
	large:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"agents.create",json.Object{"request_id"=json.String("catalog_large"),"name"=json.String("Large definition"),"instructions"=json.String(large_body)}));if large==nil do return
	large_read:=mcp_catalog_first(t,h,headers,"agents.get",json.Object{"agent_id"=large["agent_id"]});if large_read==nil do return
	testing.expect(t,len(large_read["instructions"].(json.String))==65536)
	before,_:=iface.agent_list_instances_by_owner(&g.repos.agents,owner,100)
	args:=json.Object{"request_id"=json.String("catalog_create"),"name"=json.String("Private definition name"),"instructions"=json.String("Private definition instructions"),"permission_mode"=json.String("ask"),"supports"=json.Array{json.Object{"bridge_id"=json.String("brg_placement_a"),"enabled"=json.Boolean(true)},json.Object{"bridge_id"=json.String("brg_placement_b"),"enabled"=json.Boolean(true),"max_instances"=json.Integer(2)}}}
	response:=mcp_task_test_call(h,headers,"agents.create",args)
	result:=mcp_task_test_output(t,response);if result==nil do return
	id,_:=result["agent_id"].(json.String)
	retry:=mcp_task_test_call(h,headers,"agents.create",args)
	if !testing.expectf(t,strings.has_prefix(string(id),"agt_") && result["state"].(json.String)=="active" && response.body==retry.body,"create/retry: %s / %s",response.body,retry.body) do return
	stored,found,_:=iface.agent_get(&g.repos.agents,string(id))
	testing.expect(t,found && strings.has_prefix(stored.name,"vault:v2:") && strings.has_prefix(stored.slug,"vault:v2:") && strings.has_prefix(stored.instructions,"vault:v2:") && stored.permission_mode=="ask")
	after,_:=iface.agent_list_instances_by_owner(&g.repos.agents,owner,100)
	testing.expect(t,len(before)==len(after),"creating a definition never launches")
	args["name"]=json.String("Different same request")
	testing.expect(t,strings.contains(mcp_task_test_call(h,headers,"agents.create",args).body,"idempotency_conflict"))
	row:=mcp_catalog_first(t,h,headers,"agents.get",json.Object{"agent_id"=id});if row==nil do return
	testing.expect(t,row["name"].(json.String)=="Private definition name" && row["instructions"].(json.String)=="Private definition instructions")
	supports,_:=row["supports"].(json.Array);testing.expect(t,len(supports)==2)
	update:=json.Object{"agent_id"=id,"request_id"=json.String("catalog_update"),"expected_revision"=row["revision"],"instructions"=json.String(""),"permission_mode"=json.String("yolo")}
	testing.expect(t,strings.contains(mcp_task_test_call(h,headers,"agents.update",update).body,"permission_escalation_not_allowed"))
	update["permission_mode"]=json.String("ask")
	changed:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"agents.update",update));if changed==nil do return
	row=mcp_catalog_first(t,h,headers,"agents.get",json.Object{"agent_id"=id});if row==nil do return
	testing.expect(t,row["instructions"].(json.String)=="" && row["permission_mode"].(json.String)=="ask")
	update["request_id"]=json.String("catalog_stale")
	testing.expect(t,strings.contains(mcp_task_test_call(h,headers,"agents.update",update).body,"revision_conflict"))
	// Same timestamp native writes must also invalidate the MCP revision.
	stored,_,_=iface.agent_get(&g.repos.agents,string(id));stored.permission_mode="yolo"
	_,_,_=iface.agent_save(&g.repos.agents,stored)
	update["expected_revision"]=row["revision"];update["request_id"]=json.String("catalog_native_stale")
	testing.expect(t,strings.contains(mcp_task_test_call(h,headers,"agents.update",update).body,"revision_conflict"))
	row=mcp_catalog_first(t,h,headers,"agents.get",json.Object{"agent_id"=id});if row==nil do return
	update["expected_revision"]=row["revision"];update["request_id"]=json.String("foreign_support");update["supports"]=json.Array{json.Object{"bridge_id"=json.String("brg_placement_foreign"),"enabled"=json.Boolean(true)}}
	testing.expect(t,strings.contains(mcp_task_test_call(h,headers,"agents.update",update).body,"not_found"))
	_,_,has_receipt,_:=sqlite.mcp_receipt_get(&g.db,view.owner,view.grant,"agents.update","foreign_support")
	testing.expect(t,!has_receipt)
	delete_key(&update,"supports")
	// Foreign durable/runtime identities and bridge catalogs never cross owners.
	_,_,_=iface.agent_save(&g.repos.agents,{agent_id="agt_foreign",owner_user_id="foreign_owner",name="Foreign",slug="foreign",template_id=domain.TEMPLATE_EMPTY_ID,created_at=now,updated_at=now})
	for tool in ([]string{"agents.get","agents.update","agents.archive"}) {
		a:=json.Object{"agent_id"=json.String("agt_foreign")}
		if tool!="agents.get" {a["request_id"]=json.String("foreign_agent");a["expected_revision"]=row["revision"]}
		if tool=="agents.update" do a["name"]=json.String("Never change")
		testing.expect(t,strings.contains(mcp_task_test_call(h,headers,tool,a).body,"not_found"))
	}
	testing.expect(t,strings.contains(mcp_task_test_call(h,headers,"providers.list",json.Object{"bridge_id"=json.String("brg_placement_foreign")}).body,"not_found"))
	// Stable same-timestamp filtering/paging and safe target projection.
	for i in 0..<5 {
		state:domain.Agent_State=.Active;if i%2==0 do state=.Archived
		_,_,_=iface.agent_save(&g.repos.agents,{agent_id=fmt.tprintf("agt_page_%d",i),owner_user_id=owner,name="Paged",slug=fmt.tprintf("page%d",i),template_id=domain.TEMPLATE_EMPTY_ID,state=state,created_at=now,updated_at=now})
	}
	page_args:=json.Object{"state"=json.String("archived"),"limit"=json.Integer(1)}
	count:=0
	for i in 0..<4 {
		page:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"agents.list",page_args));if page==nil do return
		rows,_:=page["records"].(json.Array);count+=len(rows)
		for item in rows {r,_:=item.(json.Object);testing.expect(t,r["instructions"]==nil && r["state"].(json.String)=="archived")}
		next,_:=page["next_cursor"].(json.String);if next=="" do break
		page_args["cursor"]=next
	}
	testing.expect_value(t,count,3)
	page_args["state"]=json.String("active")
	testing.expect(t,strings.contains(mcp_task_test_call(h,headers,"agents.list",page_args).body,"invalid_arguments"))
	for tool in ([]string{"bridges.list","providers.list","instances.list"}) {
		a:=json.Object{}
		if tool=="providers.list" {a["bridge_id"]=json.String("brg_placement_b");a["agent_id"]=id}
		resp:=mcp_task_test_call(h,headers,tool,a)
		if mcp_task_test_output(t,resp)==nil do return
		for secret in ([]string{"bridge_token_hash","binary_path","base_args_json","environment","provider_transcript_path","launch_epoch","last_error_json"}) do testing.expect(t,!strings.contains(resp.body,secret))
	}
	instance:=mcp_catalog_first(t,h,headers,"instances.get",json.Object{"agent_instance_id"=json.String("inst_placement_a")})
	if instance==nil do return
	testing.expect(t,instance["agent_id"].(json.String)=="agt_placement" && instance["bridge_id"].(json.String)=="brg_placement_a")
	mcp_catalog_targets(t,g,h,headers,view,id,false)
	mcp_catalog_concurrent_retry(t,g,view,raw,string(id))
	row=mcp_catalog_first(t,h,headers,"agents.get",json.Object{"agent_id"=id});if row==nil do return
	archive:=json.Object{"agent_id"=id,"request_id"=json.String("catalog_archive"),"expected_revision"=row["revision"]}
	archived:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"agents.archive",archive));if archived==nil do return
	testing.expect(t,archived["state"].(json.String)=="archived")
	archive["request_id"]=json.String("catalog_archive_noop");archive["expected_revision"]=archived["revision"]
	noop:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"agents.archive",archive));if noop==nil do return
	testing.expect(t,!noop["changed"].(json.Boolean) && noop["status"].(json.String)=="noop" && noop["revision"].(json.String)==archived["revision"].(json.String))
	mcp_catalog_targets(t,g,h,headers,view,id,true)
	after,_=iface.agent_list_instances_by_owner(&g.repos.agents,owner,100);testing.expect(t,len(after)==len(before))
	mcp_catalog_commit_failure(t,g,h,headers,view,id,archived["revision"])
	// Revoke after sealing, immediately before the native final authority check.
	h.mutate_catalog=mcp_catalog_revoke_before_write
	response=mcp_task_test_call(h,headers,"agents.create",json.Object{"request_id"=json.String("catalog_revoked"),"name"=json.String("Never persist revoked")})
	testing.expect(t,response.status==401)
	_,_,has_receipt,_=sqlite.mcp_receipt_get(&g.db,view.owner,view.grant,"agents.create","catalog_revoked")
	testing.expect(t,!has_receipt)
}

MCP_Catalog_Race :: struct {g:^App_Graph,view:mcp.Access_View,raw:string,command:mcp.Catalog_Command,reply:[2048]byte,ok:bool}
mcp_catalog_race_call :: proc(job:^MCP_Catalog_Race) {
	context.allocator=context.temp_allocator;defer free_all(context.temp_allocator)
	result,code:=mcp_mutate_catalog(job.g,job.raw,job.view,job.command)
	job.ok=code=="" && len(result)>0 && len(result)<len(job.reply)
	if job.ok do copy(job.reply[:],result)
}
mcp_catalog_concurrent_retry :: proc(t:^testing.T,g:^App_Graph,view:mcp.Access_View,raw,id:string) {
	context.allocator=runtime.heap_allocator()
	stored,_,_:=iface.agent_get(&g.repos.agents,id)
	revision,ok:=mcp.catalog_agent_revision(&mcp.Control_Service{agents=&g.agents},stored);if !testing.expect(t,ok) do return
	command:=mcp.Catalog_Command{tool="agents.update",digest="catalog_concurrent_digest",args={agent_id=id,request_id="catalog_concurrent_retry",expected_revision=revision},input={instructions=stored.name}}
	for key,i in mcp.CATALOG_KEYS do if key=="instructions" do command.args.present|=u64(1)<<u64(i)
	jobs:[4]MCP_Catalog_Race;threads:[4]^thread.Thread
	for i in 0..<4 {jobs[i]={g=g,view=view,raw=raw,command=command};threads[i]=thread.create_and_start_with_poly_data(&jobs[i],mcp_catalog_race_call)}
	for th in threads {thread.join(th);thread.destroy(th)}
	for job in jobs do testing.expect(t,job.ok && job.reply==jobs[0].reply)
	digest,_,found,err:=sqlite.mcp_receipt_get(&g.db,view.owner,view.grant,"agents.update","catalog_concurrent_retry")
	testing.expect(t,found && err.code==.None && digest=="catalog_concurrent_digest")
}

mcp_catalog_targets :: proc(t:^testing.T,g:^App_Graph,h:^http.MCP_Control_Handlers,headers:[]contracts.HTTP_Header,view:mcp.Access_View,id:json.Value,archived:bool) {
	context.allocator=runtime.heap_allocator()
	if !archived {
		stored,_,_:=iface.agent_get(&g.repos.agents,string(id.(json.String)))
		err:=provider.apply_profiles_report(&g.providers,"brg_placement_b",[]domain.Bridge_Provider_Profile{{profile_id="codex",provider="codex",enabled=true,state="ok"},{profile_id="work",provider="codex",enabled=true,state="ok",label_enc=stored.name}})
		testing.expect(t,err.code==.None)
		_,_=iface.bridge_provider_status_upsert(&g.provider_repo,{bridge_id="brg_placement_b",profile_id="work",provider="codex",state="present",checked_at=mcp_task_test_now(nil)})
	}
	profiles:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"providers.list",json.Object{"bridge_id"=json.String("brg_placement_b"),"agent_id"=id}));if profiles==nil do return
	rows,_:=profiles["records"].(json.Array)
	any_eligible:=false;custom_seen:=false
	for value in rows {
		row,_:=value.(json.Object)
		if row["eligible"].(json.Boolean) do any_eligible=true
		if row["provider_profile"].(json.String)=="work" {custom_seen=true;testing.expect(t,row["provider"].(json.String)=="codex" && row["label"].(json.String)=="Private definition name")}
		models,_:=row["models"].(json.Array)
		for item in models {model,_:=item.(json.Object);if model["eligible"].(json.Boolean) do testing.expect(t,model["state"].(json.String)=="active")}
	}
	testing.expect(t,any_eligible!=archived && custom_seen)
	offline:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"providers.list",json.Object{"bridge_id"=json.String("brg_placement_offline"),"agent_id"=id}));if offline==nil do return
	rows,_=offline["records"].(json.Array)
	for value in rows {row,_:=value.(json.Object);testing.expect(t,!row["eligible"].(json.Boolean))}
	if archived do return
	model_args:=json.Object{"bridge_id"=json.String("brg_placement_b"),"agent_id"=id,"provider_profile"=json.String("work"),"model_limit"=json.Integer(1)}
	model_first:=mcp_catalog_first(t,h,headers,"providers.list",model_args);if model_first==nil do return
	models,_:=model_first["models"].(json.Array);if !testing.expect(t,len(models)==1 && model_first["models_next_cursor"]!=nil) do return
	first_model,_:=models[0].(json.Object)
	model_args["model_cursor"]=model_first["models_next_cursor"]
	model_second:=mcp_catalog_first(t,h,headers,"providers.list",model_args);if model_second==nil do return
	models,_=model_second["models"].(json.Array);if !testing.expect(t,len(models)==1) do return
	second_model,_:=models[0].(json.Object)
	testing.expect(t,first_model["model_id"].(json.String)!=second_model["model_id"].(json.String))
	model_args["provider_profile"]=json.String("codex")
	testing.expect(t,strings.contains(mcp_task_test_call(h,headers,"providers.list",model_args).body,"invalid_arguments"))
	page_args:=json.Object{"agent_id"=json.String("agt_placement"),"limit"=json.Integer(1)}
	first:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"instances.list",page_args));if first==nil do return
	rows,_=first["records"].(json.Array);if !testing.expect(t,len(rows)==1) do return;r,_:=rows[0].(json.Object)
	testing.expect(t,len(rows)==1 && r["agent_instance_id"].(json.String)=="inst_placement_a")
	page_args["cursor"]=first["next_cursor"]
	second:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"instances.list",page_args));if second==nil do return
	rows,_=second["records"].(json.Array);if !testing.expect(t,len(rows)==1) do return;r,_=rows[0].(json.Object)
	testing.expect(t,len(rows)==1 && r["agent_instance_id"].(json.String)=="inst_placement_b" && second["next_cursor"]==nil)
	page_args["agent_id"]=id
	testing.expect(t,strings.contains(mcp_task_test_call(h,headers,"instances.list",page_args).body,"invalid_arguments"))
	_,_,_=iface.agent_save_instance(&g.repos.agents,{agent_instance_id="inst_catalog_foreign",agent_id="agt_foreign",bridge_id="brg_placement_foreign",owner_user_id="foreign_owner",kind="agent",display_name="Foreign session",created_at=mcp_task_test_now(nil),updated_at=mcp_task_test_now(nil)})
	testing.expect(t,strings.contains(mcp_task_test_call(h,headers,"instances.get",json.Object{"agent_instance_id"=json.String("inst_catalog_foreign")}).body,"not_found"))
	// A disabled native support row must invalidate model eligibility immediately.
	_,_,_=iface.agent_save_support(&g.repos.agents,{agent_id=string(id.(json.String)),bridge_id="brg_placement_b",owner_user_id=domain.User_ID(view.owner),enabled=false,created_at=mcp_task_test_now(nil),updated_at=mcp_task_test_now(nil)})
	denied:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"providers.list",json.Object{"bridge_id"=json.String("brg_placement_b"),"agent_id"=id}));if denied==nil do return
	rows,_=denied["records"].(json.Array);for value in rows {row,_:=value.(json.Object);testing.expect(t,!row["eligible"].(json.Boolean))}
	_,_,_=iface.agent_save_support(&g.repos.agents,{agent_id=string(id.(json.String)),bridge_id="brg_placement_b",owner_user_id=domain.User_ID(view.owner),enabled=true,max_instances=2,created_at=mcp_task_test_now(nil),updated_at=mcp_task_test_now(nil)})
}

mcp_catalog_commit_failure :: proc(t:^testing.T,g:^App_Graph,h:^http.MCP_Control_Handlers,headers:[]contracts.HTTP_Header,view:mcp.Access_View,id,revision:json.Value) {
	context.allocator=runtime.heap_allocator()
	testing.expect(t,sqlite.exec(&g.db,"PRAGMA foreign_keys=ON; CREATE TABLE catalog_parent(id INTEGER PRIMARY KEY); CREATE TABLE catalog_child(id INTEGER REFERENCES catalog_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER catalog_fail_commit AFTER INSERT ON mcp_mutation_receipts WHEN NEW.request_id='catalog_commit_fail' BEGIN INSERT INTO catalog_child(id) VALUES(999); END;"))
	args:=json.Object{"agent_id"=id,"request_id"=json.String("catalog_commit_fail"),"expected_revision"=revision,"name"=json.String("Failed commit name")}
	response:=mcp_task_test_call(h,headers,"agents.update",args)
	testing.expect(t,strings.contains(response.body,"request_failed"))
	_,_,found,_:=sqlite.mcp_receipt_get(&g.db,view.owner,view.grant,"agents.update","catalog_commit_fail");testing.expect(t,!found)
	row:=mcp_catalog_first(t,h,headers,"agents.get",json.Object{"agent_id"=id});if row==nil do return
	testing.expect(t,row["revision"].(json.String)==revision.(json.String))
	testing.expect(t,sqlite.exec(&g.db,"INSERT INTO catalog_parent(id) VALUES(999);"))
	if mcp_task_test_output(t,mcp_task_test_call(h,headers,"agents.update",args))==nil do return
	testing.expect(t,sqlite.exec(&g.db,"DROP TRIGGER catalog_fail_commit; DROP TABLE catalog_child; DROP TABLE catalog_parent;"))
}
