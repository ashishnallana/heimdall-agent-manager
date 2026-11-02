package app

import "core:encoding/json"
import "core:strings"
import sqlite "odin_test:hub/repository/sqlite"
import iface "odin_test:hub/repository/iface"
import domain "odin_test:hub/domain"
import mcp "odin_test:hub/service/mcp"
import vd "odin_test:hub/service/vault_directory"
import tc "odin_test:hub/service/taskchain"
import tv2 "odin_test:hub/service/taskv2"
import agent "odin_test:hub/service/agent"
import contracts "odin_test:contracts"

mcp_task_write_check :: proc(g:^App_Graph,raw:string,view:mcp.Access_View,tool:string)->string {
	impl:sqlite.Vault_Directory_Repo_SQLite
	repo:=sqlite.new_vault_directory_repository(&impl,&g.db)
	directory:=vd.Service{repo=&repo,clock=&g.clock}
	authority:=MCP_Task_Authority{conn=&g.db,directory=&directory}
	service:=g.mcp_delegation
	service.authority_ctx=&authority;service.authority=mcp_task_authority
	return mcp.control_write_authorized(sqlite.mcp_transaction_view(&g.db),&service,&directory,raw,view,tool)
}
mcp_task_error :: proc(err:domain.Domain_Error)->string {
	#partial switch err.code {
	case .None:return ""
	case .Not_Found,.Forbidden:return "not_found"
	case .Conflict:return "conflict"
	case .Bridge_Offline:return "bridge_offline"
	case .Provider_Unavailable:return "provider_unavailable"
	case .Validation_Failed,.Unprocessable_Entity:return "invalid_arguments"
	case:return "request_failed"
	}
}

// Explicit fleet placement prevents a selected agent/machine from silently
// inheriting another provider or falling back to the coordinator's machine.
mcp_task_target :: proc(g:^App_Graph,owner:domain.User_ID,chain:domain.Task_Chain_ID,agent_id,bridge_id:string)->string {
	if agent_id=="" && bridge_id=="" do return ""
	if agent_id=="" || bridge_id=="" || !strings.has_prefix(agent_id,"agt_") do return "placement_required"
	a,found,err:=iface.agent_get(&g.repos.agents,agent_id)
	if !found || err.code!=.None || a.owner_user_id!=owner do return "not_found"
	if a.state!=.Active do return "agent_archived"
	b,owned,berr:=iface.bridge_get_bridge(&g.repos.bridges,bridge_id)
	if !owned || berr.code!=.None || b.owner_user_id!=owner do return "not_found"
	if b.status!=.Online || b.plan_disabled_at!="" || b.enrollment_pending_until!="" do return "bridge_offline"
	rows,rerr:=iface.taskchain_list_fleets_by_chain(&g.repos.taskchains,chain,owner)
	if rerr.code!=.None do return "request_failed"
	for row in rows do if row.agent_id==agent_id {
		explicit:=row.bridge_id==bridge_id
		if row.bridge_models_json!="" {
			entries:map[string]domain.Fleet_Bridge_Model
			if json.unmarshal_string(row.bridge_models_json,&entries,.JSON,context.temp_allocator)!=nil do return "request_failed"
			if _,present:=entries[bridge_id];present do explicit=true
		}
		provider,model:=tc.fleet_model_on_bridge(row,bridge_id)
		profile:=tc.fleet_profile_on_bridge(row,bridge_id)
		if !explicit || provider=="" || model=="" do return "placement_configuration_required"
		if g.taskchains.agent_service==nil do return "provider_unavailable"
		_,valid,_:=agent.resolve_provider_model(g.taskchains.agent_service,mcp.control_auth(string(owner)),agent_id,bridge_id,{provider=provider,model=model,provider_profile=profile})
		if !valid do return "provider_unavailable"
		return ""
	}
	return "placement_configuration_required"
}

mcp_task_stored_target :: proc(g:^App_Graph,task:domain.Task)->string {
	if task.workflow_run_id!="" do return "" // engine-managed placement
	value,err:=json.parse_string(task.brief_json if task.brief_json!="" else "{}",parse_integers=true,allocator=context.temp_allocator)
	obj,typed:=value.(json.Object)
	if err!=nil || !typed do return "request_failed"
	assignee,_:=obj["assignee"].(json.String)
	return mcp_task_target(g,task.owner_user_id,task.chain_id,string(assignee),task.bridge_id)
}

mcp_mutate_task :: proc(ctx:rawptr,raw:string,view:mcp.Access_View,command:mcp.Control_Task_Command)->(string,string) {
	g:=(^App_Graph)(ctx)
	uow,begun,err:=iface.unit_of_work_begin(&g.uow_factory)
	if !begun || err.code!=.None do return "","request_failed"
	finished:=false
	defer if !finished do iface.unit_of_work_rollback(&uow)
	if code:=mcp_task_write_check(g,raw,view,command.tool);code!="" do return "",code
	if command.tool=="tasks.update" || command.tool=="tasks.control" {
		bound,owned,berr:=tc.get_task_for_read(&g.taskchains,mcp.control_auth(view.owner),command.task_id)
		if !owned || berr.code!=.None || bound.chain_id!=command.chain_id do return "","not_found"
	} else {
		_,owned,berr:=tc.get_chain_for_read(&g.taskchains,mcp.control_auth(view.owner),command.chain_id)
		if !owned || berr.code!=.None do return "","not_found"
	}
	prior,result,found,rerr:=sqlite.mcp_receipt_get(&g.db,view.owner,view.grant,command.tool,command.request_id)
	if rerr.code!=.None do return "","request_failed"
	if found {
		if prior!=command.digest do return "","idempotency_conflict"
		encoded,loaded:=sqlite.mcp_receipt_result(&g.db,view.owner,view.grant,command.tool,command.request_id)
		if !loaded || encoded=="" do return "","request_failed"
		return encoded,""
	}
	principal:=mcp.control_auth(view.owner)
	reviewers:=command.create.reviewer_agent_ids
	if command.tool=="tasks.update" do reviewers=command.update.reviewer_agent_ids
	for reviewer in reviewers {
		a,exists,aerr:=iface.agent_get(&g.repos.agents,reviewer)
		if !strings.has_prefix(reviewer,"agt_") || !exists || aerr.code!=.None || string(a.owner_user_id)!=view.owner do return "","not_found"
	}
	chains:=g.taskchains
	chains.attention=nil // refresh cards after commit, never under the outer UOW
	service:=mcp.Control_Service{chains=&chains}
	task:domain.Task
	chain_id:=command.chain_id
	if command.tool=="tasks.update" || command.tool=="tasks.control" {
		var_ok:bool
		task,var_ok,err=tc.get_task_for_read(&g.taskchains,principal,command.task_id)
		if !var_ok || err.code!=.None do return "","not_found"
		if task.chain_id!=command.chain_id do return "","not_found"
		chain_id=task.chain_id
		revision,ok:=mcp.control_task_revision(&service,task)
		if !ok do return "","request_failed"
		if revision!=command.expected_revision do return "","revision_conflict"
	}
	chain,owned,cerr:=tc.get_chain_for_read(&g.taskchains,principal,chain_id)
	if !owned || cerr.code!=.None do return "","not_found"
	id:string
	operation_err:domain.Domain_Error
	ok:=false
	outcome:=mcp.Control_Mutation_Result{changed=true,applied_fields=command.applied_fields}
	switch command.tool {
	case "tasks.create":
		if code:=mcp_task_target(g,chain.owner_user_id,chain_id,command.create.assignee_agent_id,command.create.bridge_id);code!="" do return "",code
		created,created_ok,create_err:=tc.create_task(&chains,principal,command.create)
		id=string(created.task_id);ok=created_ok;operation_err=create_err
	case "tasks.update":
        // The mandatory whole-record revision was checked in this transaction.
        // Bind the native requirement revision to that same read; MCP callers
        // cannot silently bypass its optimistic concurrency check.
        req_state, req_err := tv2.requirements_read(g.taskchains.repo,task)
        if req_err.code!=.None do return "","request_failed"
        update_input:=command.update
        update_input.expected_requirements_revision=req_state.revision
        update_input.require_requirements_context=true
		if command.update.has_assignee || command.update.bridge_id!=nil {
			brief,_:=json.parse_string(task.brief_json,parse_integers=true,allocator=context.temp_allocator)
			obj,_:=brief.(json.Object);assignee,_:=obj["assignee"].(json.String)
			a:=string(assignee);b:=task.bridge_id
			if command.update.has_assignee do a=command.update.assignee_agent_id
			if command.update.bridge_id!=nil do b=command.update.bridge_id^
			if code:=mcp_task_target(g,chain.owner_user_id,chain_id,a,b);code!="" do return "",code
		}
		updated,updated_ok,update_err:=tc.update_task(&chains,principal,task.task_id,update_input)
		id=string(updated.task_id);ok=updated_ok;operation_err=update_err
	case "tasks.control":
		if command.action=="publish" {if code:=mcp_task_stored_target(g,task);code!="" do return "",code}
		actor:=tv2.Actor{kind=tv2.ACTOR_USER,id=view.owner}
		switch command.action {
		case "publish":_,ok,operation_err=tc.publish_task(&chains,principal,task.task_id)
		case "cancel":_,ok,operation_err=tc.cancel_task(&chains,principal,task.task_id,command.reason)
		case "reopen":_,ok,operation_err=tv2.task_reopen(&g.task_engine,task,actor)
		case "answer":_,ok,operation_err=tv2.task_answer(&g.task_engine,task,actor,command.reason)
		case "hold":
			res:tv2.Hold_Result;res,ok,operation_err=tv2.task_hold(&g.task_engine,task,actor,command.reason)
			outcome.changed=res.changed;outcome.checkpoint_requested=res.checkpoint_requested
		case "release":
			res:tv2.Hold_Result;res,ok,operation_err=tv2.task_release(&g.task_engine,task,actor)
			outcome.changed=res.changed
		case "recheck":
			res:tv2.Recheck_Result;res,ok,operation_err=tv2.task_recheck(&g.task_engine,task,actor)
			outcome.changed=res.changed
			outcome.actions=mcp.control_outcome_codes(res.actions,true)
			outcome.reasons=mcp.control_outcome_codes(res.reasons,false)
		case:return "","invalid_arguments"
		}
		id=string(task.task_id)
	case "chains.configure":
		revision,_,valid:=mcp.control_configuration(&service,chain)
		if !valid do return "","request_failed"
		if revision!=command.expected_revision do return "","revision_conflict"
		switch command.action {
		case "publish":
			tasks,terr:=tc.list_tasks(&g.taskchains,principal,chain.chain_id)
			if terr.code!=.None do return "","request_failed"
			for task in tasks do if code:=mcp_task_stored_target(g,task);code!="" do return "",code
			_,ok,operation_err=tc.publish_chain(&chains,principal,chain.chain_id)
		case "fleet":
			prior,perr:=iface.taskchain_list_fleets_by_chain(&g.repos.taskchains,chain.chain_id,chain.owner_user_id)
			if perr.code!=.None do return "","request_failed"
			selections:=make(map[string]domain.Fleet_Bridge_Model,context.temp_allocator)
			for row in prior do if row.agent_id==command.fleet.agent_id {
				if row.bridge_models_json!="" && json.unmarshal_string(row.bridge_models_json,&selections,.JSON,context.temp_allocator)!=nil do return "","request_failed"
				if row.bridge_id!="" && row.provider!="" && row.model!="" {
					if _,present:=selections[row.bridge_id];!present do selections[row.bridge_id]={provider=row.provider,model=row.model,provider_profile=row.provider_profile}
				}
			}
			a,exists,aerr:=iface.agent_get(&g.repos.agents,command.fleet.agent_id)
			if !exists || aerr.code!=.None || a.owner_user_id!=chain.owner_user_id do return "","not_found"
			if a.state!=.Active do return "","agent_archived"
			if command.fleet.bridge_id==nil do return "","placement_required"
			b,bridge_exists,berr:=iface.bridge_get_bridge(&g.repos.bridges,command.fleet.bridge_id^)
			if !bridge_exists || berr.code!=.None || b.owner_user_id!=chain.owner_user_id do return "","not_found"
			if b.status!=.Online || b.plan_disabled_at!="" || b.enrollment_pending_until!="" do return "","bridge_offline"
			if g.taskchains.agent_service==nil do return "","provider_unavailable"
			_,valid,_:=agent.resolve_provider_model(g.taskchains.agent_service,principal,command.fleet.agent_id,b.bridge_id,{provider=command.fleet.provider,model=command.fleet.model,provider_profile=command.fleet.provider_profile})
			if !valid do return "","provider_unavailable"
			selections[b.bridge_id]={provider=command.fleet.provider,model=command.fleet.model,provider_profile=command.fleet.provider_profile}
			encoded,eerr:=json.marshal(selections,allocator=context.temp_allocator)
			if eerr!=nil do return "","request_failed"
			fleet:=command.fleet;fleet.bridge_models_json=string(encoded)
			_,operation_err=tc.upsert_fleet(&chains,principal,fleet);ok=operation_err.code==.None
		case:return "","invalid_arguments"
		}
		id=string(chain.chain_id)
	case:return "","invalid_arguments"
	}
	if !ok || operation_err.code!=.None {code:=mcp_task_error(operation_err);if code=="" do code="request_failed";return "",code}
	outcome.resource_id=id;outcome.chain_id=string(chain_id)
	outcome.status="completed";if !outcome.changed do outcome.status="noop";if outcome.checkpoint_requested do outcome.status="accepted"
	if command.tool=="chains.configure" {
		fresh,exists,ferr:=iface.taskchain_get_chain(&g.repos.taskchains,chain_id)
		if !exists || ferr.code!=.None do return "","request_failed"
		outcome.revision,ok=mcp.control_configuration_revision(&service,fresh)
		outcome.state="active";outcome.publish_state="published" if fresh.publish_state==.Published else "draft"
	} else {
		fresh,exists,ferr:=iface.taskchain_get_task(&g.repos.taskchains,domain.Task_ID(id))
		if !exists || ferr.code!=.None do return "","request_failed"
		outcome.task_id=id;outcome.state=domain.task_state_string(fresh.state);outcome.publish_state="published" if fresh.publish_state==.Published else "draft"
		outcome.blocked=strings.trim_space(fresh.blocked_on_json)!=""
		outcome.revision,ok=mcp.control_task_revision(&service,fresh)
	}
	if !ok do return "","request_failed"
	encoded,eerr:=json.marshal(outcome,allocator=context.temp_allocator)
	if eerr!=nil do return "","request_failed"
	if perr:=sqlite.mcp_receipt_put(&g.db,view.owner,view.grant,command.tool,command.request_id,command.digest,id,string(encoded));perr.code!=.None do return "","request_failed"
	commit_ok,commit_err:=iface.unit_of_work_commit(&uow)
	// COMMIT consumes the UOW even on failure (SQLite rolls back and frees it).
	finished=true
	if !commit_ok || commit_err.code!=.None do return "","request_failed"
	if command.tool!="chains.configure" do contracts.attention_notify(g.taskchains.attention,view.owner,contracts.ATTENTION_SOURCE_TASK,id)
	return string(encoded),""
}
