package http

import "core:crypto"
import "core:encoding/json"
import "core:time"
import domain "odin_test:hub/domain"
import auth "odin_test:hub/service/auth"
import mcp "odin_test:hub/service/mcp"
import vault "odin_test:lib/vault"
import tc "odin_test:hub/service/taskchain"

mcp_task_sealed_fields :: proc(view:mcp.Access_View,expected,actual:json.Object)->bool {
	if len(expected)!=len(actual) do return false
	for key,value in expected {
		if key=="acceptance" {
			items,typed:=actual[key].(json.Array);original,original_typed:=value.(json.Array)
			if !typed || !original_typed || len(items)!=len(original) do return false
			for item in items {s,ok:=item.(json.String);if !ok || !mcp_task_envelope_ok(view,string(s)) do return false}
		} else {
			s,typed:=actual[key].(json.String);if !typed || !mcp_task_envelope_ok(view,string(s)) do return false
		}
	}
	return true
}
mcp_task_envelope_ok :: proc(view:mcp.Access_View,token:string)->bool {
	vid,epoch,_,status:=vault.envelope_parse(token,context.temp_allocator)
	buf:[16]byte
	return status==.Ok && epoch==view.epoch && vault.vault_id_hex(vid,buf[:])==view.vault_id
}

mcp_task_write_call :: proc(h:^MCP_Control_Handlers,id:json.Value,raw:string,view:mcp.Access_View,tool:string,args:mcp.Task_Tool_Arguments,handle:mcp.Request_Handle,started:time.Tick)->Response {
	defer {
		for text in ([]string{args.title,args.description,args.goal,args.reason}) do if text!="" do crypto.zero_explicit(raw_data(text),len(text))
		for text in args.acceptance do if text!="" do crypto.zero_explicit(raw_data(text),len(text))
	}
	if h.mutate_task==nil do return mcp_tool_result(id,"request_failed",true)
	if tool=="tasks.update" || tool=="tasks.control" {
		task,owned,err:=tc.get_task_for_read(h.control.chains,mcp.control_auth(view.owner),domain.Task_ID(args.task_id))
		if !owned || err.code!=.None || string(task.chain_id)!=args.chain_id do return mcp_tool_result(id,"not_found",true)
	} else {
		_,owned,err:=tc.get_chain_for_read(h.control.chains,mcp.control_auth(view.owner),domain.Task_Chain_ID(args.chain_id))
		if !owned || err.code!=.None do return mcp_tool_result(id,"not_found",true)
	}
	encoded,err:=json.marshal(args,allocator=context.temp_allocator)
	if err!=nil do return mcp_tool_result(id,"request_failed",true)
	digest:=auth.sha256_hex(string(encoded))
	defer if len(encoded)>0 do crypto.zero_explicit(raw_data(encoded),len(encoded))
	fields:=make(json.Object,context.temp_allocator)
	for key in ([]string{"title","description","goal","reason"}) do if mcp.task_argument_present(args,key) {
		text:=args.title
		switch key {case "description":text=args.description;case "goal":text=args.goal;case "reason":text=args.reason}
		fields[key]=json.String(text)
	}
	if mcp.task_argument_present(args,"acceptance") {
		items:=make(json.Array,0,len(args.acceptance),context.temp_allocator)
		for item in args.acceptance do append(&items,json.String(item))
		fields["acceptance"]=items
	}
	sealed:=make(json.Object,context.temp_allocator)
	result:mcp.Delegation_Result
	defer if result.response!="" do crypto.zero_explicit(raw_data(result.response),len(result.response))
	if len(fields)>0 {
		op:=mcp.Control_Transform{tool=tool,task_fields=fields}
		if view.mode=="hosted" {result=mcp.hosted_with_access(h.delegation.service,h.delegation.grant_directory,raw,view.client,mcp.control_hosted_transform,&op)} else {result=mcp_device_transform(h,view,&op,handle,started)}
		if result.error=="invalid_token" do return mcp_unauthorized(h)
		if result.error!="" do return mcp_tool_result(id,result.error,true)
		var_ok:bool
		sealed,var_ok=mcp_parse_object(result.response)
		if !var_ok || !mcp_task_sealed_fields(view,fields,sealed) do return mcp_tool_result(id,"decryption_unavailable",true)
	}
	if mcp.request_cancelled(&h.requests,handle) || time.tick_since(started)>=30*time.Second do return mcp_tool_result(id,"cancelled",true)
	get_text :: proc(fields:json.Object,key:string)->string {s,_:=fields[key].(json.String);return string(s)}
	brief:=make(json.Object,context.temp_allocator)
	for key in ([]string{"goal","acceptance"}) do if value,present:=sealed[key];present do brief[key]=value
	brief_json:string
	if len(brief)>0 {data,eerr:=json.marshal(brief,allocator=context.temp_allocator);if eerr!=nil do return mcp_tool_result(id,"request_failed",true);brief_json=string(data)}
	deps:=make([]domain.Task_ID,len(args.depends_on),context.temp_allocator)
	for dep,i in args.depends_on do deps[i]=domain.Task_ID(dep)
	command:=mcp.Control_Task_Command{tool=tool,request_id=args.request_id,digest=digest,expected_revision=args.expected_revision,action=args.action,reason=get_text(sealed,"reason"),chain_id=domain.Task_Chain_ID(args.chain_id),task_id=domain.Task_ID(args.task_id)}
	command.create={chain_id=command.chain_id,title=get_text(sealed,"title"),description=get_text(sealed,"description"),brief_json=brief_json,assignee_agent_id=args.assignee_agent_id,bridge_id=args.bridge_id,reviewer_agent_ids=args.reviewers,depends_on=deps,requires_user_approval=args.requires_user_approval,has_requires_user_approval=mcp.task_argument_present(args,"requires_user_approval")}
	command.update={title=get_text(sealed,"title"),description=get_text(sealed,"description"),brief_json=brief_json,assignee_agent_id=args.assignee_agent_id,has_assignee=mcp.task_argument_present(args,"assignee_agent_id"),reviewer_agent_ids=args.reviewers,has_reviewers=mcp.task_argument_present(args,"reviewers"),depends_on=deps,has_depends_on=mcp.task_argument_present(args,"depends_on"),requires_user_approval=args.requires_user_approval,has_requires_user_approval=mcp.task_argument_present(args,"requires_user_approval")}
	command.create.priority=domain.task_priority_from_string(args.priority);command.create.has_priority=mcp.task_argument_present(args,"priority")
	command.update.priority=command.create.priority;command.update.has_priority=command.create.has_priority
    command.update.require_requirements_context=true
    command.update.requirements_reason=get_text(sealed,"reason")
    command.update.requirements_request_id=args.request_id
	bridge:=new(string,context.temp_allocator);bridge^=args.bridge_id
	if mcp.task_argument_present(args,"bridge_id") do command.update.bridge_id=bridge
	capacity:=args.capacity;if capacity==0 do capacity=1
	roles:=args.roles;if len(roles)==0 do roles=[]string{"worker"}
	profile:=args.provider_profile;if profile=="" do profile=args.provider
	command.fleet={chain_id=command.chain_id,agent_id=args.agent_id,bridge_id=bridge,provider=args.provider,model=args.model,provider_profile=profile,has_provider_profile=true,capacity=capacity,roles=roles,has_roles=true}
	applied:=make([dynamic]string,context.temp_allocator)
	for key in mcp.TASK_TOOL_KEYS do if mcp.task_argument_present(args,key) && key!="chain_id" && key!="task_id" && key!="request_id" && key!="expected_revision" do append(&applied,key)
	command.applied_fields=applied[:]
	result_json,code:=h.mutate_task(h.create_ctx,raw,view,command)
	if code=="invalid_token" do return mcp_unauthorized(h)
	if code!="" do return mcp_tool_result(id,code,true)
	return mcp_tool_result(id,result_json,false)
}
