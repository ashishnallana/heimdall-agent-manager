#+feature dynamic-literals
package mcp

import "core:encoding/json"
import "core:crypto"
import "core:fmt"
import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import tc "odin_test:hub/service/taskchain"
import vault "odin_test:lib/vault"
import agent "odin_test:hub/service/agent"
import provider "odin_test:hub/service/provider"
import content "odin_test:hub/service/content"
import project "odin_test:hub/service/project"
import issue "odin_test:hub/service/issue"

Control_Service :: struct {chains:^tc.Taskchain_Service,agents:^agent.Agent_Service,providers:^provider.Provider_Service,bridges:^iface.Bridge_Repository,content:^content.Content_Service,projects:^project.Project_Service,issues:^issue.Issue_Service,resource_ctx:rawptr,resource_page:iface.Resource_Page_Proc}
Control_Arguments :: struct {chain_id,title,description,cursor,task_id,request_id,body,state,assignee_agent_id,comment_cursor:string,coordinator_agent_id,bridge_id,provider,provider_profile,model:string,limit,timeout_ms,comment_limit:int,task_write:Task_Tool_Arguments,catalog:Catalog_Arguments,runtime:Runtime_Arguments,resource:Resource_Arguments,include_configuration,include_comments:bool}
Control_Data :: vault.Control_Data
control_auth :: proc(owner:string)->contracts.Auth_Context {return {kind=.Internal_User,user_id=owner}}
control_chain :: proc(c:domain.Task_Chain)->json.Object {
	status:="active"
	switch c.status {case .Active: case .Completed:status="completed";case .Cancelled:status="cancelled";case .Archived:status="archived"}
	return json.Object{"owner_user_id"=json.String(c.owner_user_id),"chain_id"=json.String(c.chain_id),"title"=json.String(c.title),"description"=json.String(c.description),"status"=json.String(status),"kind"=json.String(c.kind),"work_revision"=json.Integer(c.work_revision),"created_at"=json.String(c.created_at),"updated_at"=json.String(c.updated_at)}
}
control_id_ok :: proc(id:string)->bool {return strings.has_prefix(id,"chain_") && len(id)>6 && len(id)<=256 && vault.valid_id_value(id)}
// Services authorize every chain/task/comment before any decryption dispatch.
// Bounded projections deliberately omit briefs, facets and other nested data.
control_read :: proc(s:^Control_Service,owner,name:string,args:Control_Arguments)->(Control_Data,string) {
	if resource_tool(name) do return resource_read(s,owner,name,args.resource)
	if catalog_tool(name) do return control_read_catalog(s,owner,name,args.catalog)
	if name=="tasks.list" || name=="tasks.get" do return control_read_tasks(s,owner,name,args)
	principal:=control_auth(owner)
	if name=="chains.list" {
		all,err:=tc.list_chains(s.chains,principal)
		if err.code!=.None do return {},"request_failed"
		limit:=args.limit
		if limit==0 do limit=50
		start:=0
		if args.cursor!="" {
			value,ok:=strconv.parse_int(args.cursor)
			if !ok || value<0 || value>len(all) do return {},"invalid_arguments"
			start=value
		}
		stop:=min(len(all),start+limit)
		out:=Control_Data{chains=make([]json.Object,stop-start,context.temp_allocator)}
		for i in start..<stop {
			if string(all[i].owner_user_id)!=owner do return {},"request_failed"
			out.chains[i-start]=control_chain(all[i])
		}
		if stop<len(all) do out.next_cursor=fmt.tprintf("%d",stop)
		return out,""
	}
	c,found,err:=tc.get_chain_for_read(s.chains,principal,domain.Task_Chain_ID(args.chain_id))
	if !found || err.code!=.None || string(c.owner_user_id)!=owner do return {},"not_found"
	tasks,terr:=tc.list_tasks(s.chains,principal,c.chain_id)
	if terr.code!=.None || len(tasks)>1000 do return {},"result_too_large"
	out:=Control_Data{chain=control_chain(c),tasks=make([]json.Object,len(tasks),context.temp_allocator),comments=make([]json.Object,0,context.temp_allocator)}
	if args.include_configuration {
		configuration_revision,fleet,configured:=control_configuration(s,c)
		if !configured do return {},"request_failed"
		out.chain["configuration_revision"]=json.String(configuration_revision);out.chain["fleet"]=fleet
	}
	comments:=make([dynamic]json.Object,context.temp_allocator)
	for t,i in tasks {
		if string(t.owner_user_id)!=owner || t.chain_id!=c.chain_id do return {},"request_failed"
		reviews,rerr:=iface.taskchain_list_reviews_by_task(s.chains.repo,t.task_id,t.owner_user_id)
		if rerr.code!=.None do return {},"request_failed"
		// Review verdicts only: reviewer summaries may contain encrypted prose.
		r:=make(json.Array,0,len(reviews),context.temp_allocator)
		for review in reviews do if review.attempt_no==t.attempt_no do append(&r,json.Object{"verdict"=json.String(review.verdict),"role"=json.String(review.role),"reviewer_kind"=json.String(review.reviewer_kind)})
		out.tasks[i]=json.Object{"owner_user_id"=json.String(t.owner_user_id),"task_id"=json.String(t.task_id),"title"=json.String(t.title),"description"=json.String(t.description),"state"=json.String(domain.task_state_string(t.state)),"kind"=json.String(domain.task_kind_string(t.kind)),"attempt_no"=json.Integer(t.attempt_no),"requires_user_approval"=json.Boolean(t.requires_user_approval),"reviews"=r,"updated_at"=json.String(t.updated_at)}
		rows,cerr:=tc.list_comments(s.chains,principal,t.task_id)
		if cerr.code!=.None || len(comments)+len(rows)>2000 do return {},"result_too_large"
		for row in rows {
			if string(row.owner_user_id)!=owner || row.task_id!=t.task_id do return {},"request_failed"
			append(&comments,json.Object{"owner_user_id"=json.String(row.owner_user_id),"comment_id"=json.String(row.comment_id),"body"=json.String(row.body),"created_at"=json.String(row.created_at)})
		}
	}
	out.comments=comments[:]
	return out,""
}
control_transform :: vault.control_transform_data
Control_Transform :: struct {data:Control_Data,title,description,tool,body:string,seal:bool,task_fields,agent_fields,resource_fields:json.Object}

control_payload_ok :: proc(data:Control_Data)->bool {
	encoded,err:=json.marshal(data,allocator=context.temp_allocator)
	defer if len(encoded)>0 do crypto.zero_explicit(raw_data(encoded),len(encoded))
	return err==nil && len(encoded)<=4*1024*1024
}
control_record_matches :: proc(expected,actual:json.Object,kind:Hosted_Record_Kind)->bool {
	allowed,text:=vault.control_record_fields(kind)
	for key,value in actual {
		if _,present:=expected[key];!present do return false
		found:=false;is_text:=false
		for k in allowed do if k==key do found=true
		for k in text do if k==key do is_text=true
		if !found do return false
		if kind==.Issue && key=="comments" {
			items,typed:=value.(json.Array);original,original_typed:=expected[key].(json.Array)
			if !typed || !original_typed || len(items)!=len(original) do return false
			for item,i in items {row,ok:=item.(json.Object);source,source_ok:=original[i].(json.Object);if !ok || !source_ok || !control_record_matches(source,row,.Issue_Comment) do return false}
		} else if kind==.Provider && key=="models" {
			items,typed:=value.(json.Array);expected_items,expected_typed:=expected[key].(json.Array)
			if !typed || !expected_typed || len(items)!=len(expected_items) do return false
			for item,i in items {
				model,ok:=item.(json.Object);original,original_ok:=expected_items[i].(json.Object)
				if !ok || !original_ok || len(model)!=5 || len(original)!=5 do return false
				for k in ([]string{"model_id","label","state","rank","eligible"}) {
					if k=="label" {if _,typed:=model[k].(json.String);!typed do return false} else if !tc.json_values_equal(original[k],model[k]) do return false
				}
			}
		} else if kind==.Task_Detail && (key=="acceptance" || key=="inputs") {
			items,typed:=value.(json.Array);expected_items,expected_typed:=expected[key].(json.Array)
			if !typed || !expected_typed || len(items)!=len(expected_items) do return false
			for item in items do if _,string_item:=item.(json.String);!string_item do return false
		} else if is_text {
			text,ok:=value.(json.String);if !ok do return false
			if kind==.Artifact && key=="content" && (len(text)>65536 || strings.contains(string(text),"\x00")) do return false
			if kind==.Issue && key=="description" {if limit,typed:=expected["description_limit"].(json.Integer);typed && limit==512 && len(text)>512 do return false}
		} else if !tc.json_values_equal(expected[key],value) do return false
	}
	for key in allowed do if _,exists:=expected[key];exists {
		if _,present:=actual[key];!present do return false
	}
	return true
}
// Treat device output as untrusted even though its signature verifies: the Hub
// forwards only the exact records/metadata it requested, without nested extras.
control_result_ok :: proc(data:Control_Data,result:string)->bool {
	if len(result)>4*1024*1024 || strings.contains(result,vault.VAULT_V2_PREFIX) do return false
	parser:=json.make_parser_from_string(result,.JSON,true,context.temp_allocator)
	value,err:=json.parse_value(&parser)
	defer vault.control_wipe_value(value)
	root,object:=value.(json.Object)
	if err!=nil || !object || parser.curr_token.kind!=.EOF do return false
	for key in root do if key!="chain" && key!="chains" && key!="tasks" && key!="comments" && key!="next_cursor" && key!="comments_next_cursor" && key!="records_kind" && key!="records" do return false
	if kind,known:=vault.control_catalog_kind(data.records_kind);known {
		raw_kind,typed:=root["records_kind"].(json.String);if !typed || string(raw_kind)!=data.records_kind do return false
		rows,array_typed:=root["records"].(json.Array);if len(data.records)>0 && !array_typed || len(rows)!=len(data.records) do return false
		for item,i in rows {obj,ok:=item.(json.Object);if !ok || !control_record_matches(data.records[i],obj,kind) do return false}
	} else {if _,present:=root["records_kind"];present do return false;if _,present:=root["records"];present do return false}
	if data.chain!=nil {
		c,ok:=root["chain"].(json.Object);if !ok || !control_record_matches(data.chain,c,.Chain) do return false
	} else if _,present:=root["chain"];present do return false
	for field,i in ([]string{"chains","tasks","comments"}) {
		expected:=data.chains;kind:=Hosted_Record_Kind.Chain
		if i==1 {expected=data.tasks;kind=.Task;if len(expected)>0 {if _,details:=expected[0]["chain_id"];details do kind=.Task_Detail}}
		if i==2 {expected=data.comments;kind=.Comment}
		raw_array,present:=root[field]
		actual,ok:=raw_array.(json.Array)
		if present && !ok || len(expected)>0 && !ok || len(actual)!=len(expected) do return false
		for raw,j in actual {
			record,typed:=raw.(json.Object)
			if !typed || !control_record_matches(expected[j],record,kind) do return false
		}
	}
	cursor,present:=root["next_cursor"]
	if present {s,typed:=cursor.(json.String);if !typed || string(s)!=data.next_cursor do return false} else if data.next_cursor!="" do return false
	comment_cursor,comment_present:=root["comments_next_cursor"]
	if comment_present {s,typed:=comment_cursor.(json.String);if !typed || string(s)!=data.comments_next_cursor do return false} else if data.comments_next_cursor!="" do return false
	return true
}
control_sealed_ok :: proc(view:Access_View,text:string)->(title,description:string,ok:bool) {
	parser:=json.make_parser_from_string(text,.JSON,true,context.temp_allocator)
	value,err:=json.parse_value(&parser)
	obj,typed:=value.(json.Object)
	if err!=nil || !typed || len(obj)!=2 || parser.curr_token.kind!=.EOF do return "","",false
	t,tok:=obj["title"].(json.String);d,dok:=obj["description"].(json.String)
	if !tok || !dok do return "","",false
	for token in ([]string{string(t),string(d)}) {
		vid,epoch,_,result:=vault.envelope_parse(token,context.temp_allocator)
		buf:[16]byte
		if result!=.Ok || epoch!=view.epoch || vault.vault_id_hex(vid,buf[:])!=view.vault_id do return "","",false
	}
	return string(t),string(d),true
}
control_hosted_transform :: proc(ctx:rawptr,kr:^vault.Vault_Keyring)->(string,bool) {
	op:=(^Control_Transform)(ctx)
	if op.resource_fields!=nil do return vault.control_seal_resource_fields(kr,op.tool,op.resource_fields)
	if op.agent_fields!=nil do return vault.control_seal_agent_fields(kr,op.agent_fields)
	if op.task_fields!=nil do return vault.control_seal_task_fields(kr,op.task_fields)
	if op.tool=="tasks.comment" || op.tool=="chains.message" {
		payload,err:=json.marshal(struct {body:string}{op.body},allocator=context.temp_allocator)
		if err!=nil do return "",false
		defer if len(payload)>0 do crypto.zero_explicit(raw_data(payload),len(payload))
		operation:="seal_comment";if op.tool=="chains.message" do operation="seal_message"
		return vault.control_job_transform({operation=operation,payload=string(payload)},kr)
	}
	if !op.seal {
		if !vault.control_catalog_data_ok(op.tool,op.data) do return "",false
		return vault.control_transform_data(op.data,kr,op.tool=="tasks.get" || op.tool=="tasks.list")
	}
	t,d,ok:=hosted_seal_chain(kr,op.title,op.description)
	if !ok do return "",false
	encoded,err:=json.marshal(struct {title,description:string}{t,d},allocator=context.temp_allocator)
	return string(encoded),err==nil
}
