package app

import "core:encoding/json"
import "core:sync"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import mcp "odin_test:hub/service/mcp"
import agent "odin_test:hub/service/agent"
import auth "odin_test:hub/service/auth"
import platform "odin_test:hub/platform"
import project "odin_test:hub/service/project"

MCP_Runtime_State :: struct {result:mcp.Runtime_Result,args:mcp.Runtime_Arguments,run_count,configuration_revision:int,native_key,launch_hash:string}
MCP_Runtime_Guard :: struct {g:^App_Graph,raw:string,view:mcp.Access_View,tool:string,instance:domain.Agent_Instance,code:string,cancel_ctx:rawptr,cancel:proc(ctx:rawptr)->bool}
mcp_runtime_native_guard :: proc(ctx:rawptr)->domain.Domain_Error {
	p:=(^MCP_Runtime_Guard)(ctx)
	if p.cancel!=nil && p.cancel(p.cancel_ctx) {p.code="cancelled"} else {p.code=mcp_runtime_dispatch_check(p.g,p.raw,p.view,p.tool,p.instance)}
	if p.code!="" do return domain.domain_error(.Forbidden,"delegated runtime precondition changed")
	return {}
}
mcp_runtime_key :: proc(view:mcp.Access_View,tool,request_id:string)->string {return strings.concatenate({"mcp_",auth.sha256_hex(strings.concatenate({view.grant,"/",tool,"/",request_id}))})}
mcp_runtime_encoded :: proc(result:mcp.Runtime_Result)->string {encoded,_:=json.marshal(result,allocator=context.temp_allocator);return string(encoded)}

// Runtime network commands must never run under the DB transaction. Persist an
// at-most-once intent first; ambiguous process/network failures remain visible
// for repair and are never redispatched by replaying the MCP request.
mcp_runtime_call :: proc(ctx:rawptr,raw:string,view:mcp.Access_View,tool:string,a:mcp.Runtime_Arguments,cancel_ctx:rawptr=nil,cancel:proc(ctx:rawptr)->bool=nil)->(string,string) {
	g:=(^App_Graph)(ctx)
	if cancel!=nil && cancel(cancel_ctx) do return "","cancelled"
	if !sync.mutex_try_lock(&g.mcp_runtime_mutex) do return "","busy"
	defer sync.mutex_unlock(&g.mcp_runtime_mutex)
	uow,begun,e:=iface.unit_of_work_begin(&g.uow_factory);if !begun || e.code!=.None do return "","request_failed"
	finished:=false;defer if !finished do iface.unit_of_work_rollback(&uow)
	if code:=mcp_task_write_check(g,raw,view,tool);code!="" do return "",code
	lookup_tool:=tool;if tool=="instances.operations" do lookup_tool=a.operation_tool
	digest:=mcp.runtime_write_digest(a)
	old_digest,_,exists,read_err:=sqlite.mcp_receipt_get(&g.db,view.owner,view.grant,lookup_tool,a.request_id)
	if read_err.code!=.None do return "","request_failed"
	if exists {
		if tool!="instances.operations" && digest!=old_digest do return "","idempotency_conflict"
		stored,ok:=sqlite.mcp_receipt_result(&g.db,view.owner,view.grant,lookup_tool,a.request_id);state:MCP_Runtime_State
		if !ok || json.unmarshal_string(stored,&state,.JSON,context.temp_allocator)!=nil do return "","request_failed"
		if a.agent_instance_id!="" && a.agent_instance_id!=state.result.agent_instance_id do return "","not_found"
		return mcp_runtime_poll(g,view,state),""
	}
	if tool=="instances.operations" do return "","not_found"
	principal:=mcp.control_auth(view.owner)
	i:domain.Agent_Instance;create_title:string
	control:=mcp.Control_Service{agents=&g.agents}
	if tool=="instances.create" {
		definition,found,err:=agent.get_agent(&g.agents,principal,a.agent_id);if !found || err.code!=.None do return "","not_found"
		create_title=definition.name
		revision,ok:=mcp.catalog_agent_revision(&control,definition);if !ok do return "","request_failed";if revision!=a.expected_revision do return "","revision_conflict"
		chain,chain_found,chain_err:=iface.taskchain_get_chain(&g.repos.taskchains,domain.Task_Chain_ID(a.chain_id))
		if !chain_found || chain_err.code!=.None || string(chain.owner_user_id)!=view.owner do return "","not_found"
		if chain.status!=.Active do return "","conflict"
	} else {
		row,found,err:=agent.get_instance(&g.agents,principal,a.agent_instance_id);if !found || err.code!=.None || row.kind!="agent" do return "","not_found";i=row
		if mcp.runtime_revision(i)!=a.expected_revision do return "","revision_conflict"
		if code:=mcp_runtime_idle(g,i);code!="" do return "",code
		if busy,busy_err:=iface.agent_runtime_busy(&g.repos.agents,i.agent_instance_id);busy_err.code!=.None {return "","request_failed"} else if busy && a.retry_request_id=="" {return "","runtime_busy"}
		if tool=="instances.start" && agent.runtime_expected_active(i.runtime_status) do return "","already_running"
	}
	if tool=="instances.create" || tool=="instances.reconfigure" {
		bridge,found,err:=iface.bridge_get_bridge(&g.repos.bridges,a.bridge_id)
		if !found || err.code!=.None || string(bridge.owner_user_id)!=view.owner do return "","not_found"
		if !mcp.catalog_bridge_eligible(bridge) || !project.bridge_runtime_registry_has_live(g.agents.bridge_runtime_registry,a.bridge_id) do return "","bridge_offline"
		durable:=a.agent_id;if tool=="instances.reconfigure" do durable=i.agent_id
		_,valid,validation_err:=agent.resolve_provider_model(&g.agents,principal,durable,a.bridge_id,{provider=a.provider,provider_profile=a.provider_profile,model=a.model})
		if !valid || validation_err.code!=.None do return "",mcp_task_error(validation_err)
		if a.project_id!="" {_,valid_path,path_err:=agent.resolve_project_path_for_launch(&g.agents,domain.User_ID(view.owner),domain.Project_ID(a.project_id),a.bridge_id);if !valid_path || path_err.code!=.None do return "",mcp_task_error(path_err)}
	} else {
		bridge,found,err:=iface.bridge_get_bridge(&g.repos.bridges,i.bridge_id)
		if !found || err.code!=.None || string(bridge.owner_user_id)!=view.owner do return "","not_found"
		if !mcp.catalog_bridge_eligible(bridge) || !project.bridge_runtime_registry_has_live(g.agents.bridge_runtime_registry,i.bridge_id) do return "","bridge_offline"
	}
	state:=MCP_Runtime_State{args=a,result={operation_id=mcp_runtime_key(view,tool,a.request_id),tool=tool,agent_instance_id=i.agent_instance_id,agent_id=i.agent_id,status="accepted",phase="prepared",created_at=platform.clock_now(&g.clock)},run_count=i.run_count}
	if tool=="instances.start" do state.run_count+=1
	state.native_key=state.result.operation_id
	if a.retry_request_id!="" {
		prior_json,found:=sqlite.mcp_receipt_result(&g.db,view.owner,view.grant,"instances.reconfigure",a.retry_request_id);prior:MCP_Runtime_State
		if !found || json.unmarshal_string(prior_json,&prior,.JSON,context.temp_allocator)!=nil || prior.result.agent_instance_id!=i.agent_instance_id do return "","not_found"
		if prior.args.bridge_id!=a.bridge_id || prior.args.project_id!=a.project_id || prior.args.provider!=a.provider || prior.args.provider_profile!=a.provider_profile || prior.args.model!=a.model do return "","idempotency_conflict"
		state.native_key=prior.native_key
		op,op_found,err:=iface.instance_reconfiguration_get(&g.repos.agents,view.owner,i.agent_instance_id,state.native_key)
		if !op_found || err.code!=.None do return "","not_found"
		valid:=op.phase==.Recovery_Required && op.revision==a.expected_operation_revision
		domain.instance_reconfiguration_destroy(&op)
		if !valid do return "","revision_conflict"
	}
	generation:int;prepared:=false;committed:=false
	defer if prepared && !committed do project.bridge_runtime_instance_cancel_reservation(g.agents.bridge_runtime_registry,i.bridge_id,generation,i.agent_instance_id)
	if tool=="instances.create" {
		row,gen,ok,err:=agent.prepare_instance(&g.agents,principal,{agent_id=a.agent_id,bridge_id=a.bridge_id,project_id=domain.Project_ID(a.project_id),chain_id=a.chain_id,provider=a.provider,provider_profile=a.provider_profile,model=a.model,member_role="worker",display_name=create_title},create_title)
		if !ok || err.code!=.None do return "",mcp_task_error(err)
		i=row;generation=gen;prepared=true;state.run_count=i.run_count;state.result.agent_instance_id=i.agent_instance_id;state.result.agent_id=i.agent_id
		// The prepared row does not carry the joined effective agent permission.
		// Read it before hashing or comparing its actual launch configuration.
		fresh,found,read_err:=agent.get_instance(&g.agents,principal,i.agent_instance_id)
		if !found || read_err.code!=.None do return "","request_failed"
		i=fresh
	}
	state.configuration_revision=i.configuration_revision;state.launch_hash=auth.sha256_hex(i.launch_epoch)
	state.result.revision=mcp.runtime_revision(i)
	state_json,_:=json.marshal(state,allocator=context.temp_allocator)
	if err:=sqlite.mcp_receipt_put(&g.db,view.owner,view.grant,tool,a.request_id,digest,state.result.agent_instance_id,string(state_json));err.code!=.None do return "","request_failed"
	ok,err:=iface.unit_of_work_commit(&uow);finished=true
	if !ok || err.code!=.None do return "","request_failed"
	committed=true
	// The authorization and task lease check run again after preparation and
	// before entering any native network preflight or dispatch.
	guard:=MCP_Runtime_Guard{g=g,raw=raw,view=view,tool=tool,instance=i,cancel_ctx=cancel_ctx,cancel=cancel}
	if err:=mcp_runtime_native_guard(&guard);err.code!=.None {state.result.status="failed";state.result.phase="not_dispatched";state.result.error_code=guard.code;mcp_runtime_store(g,view,state,prepared);if prepared do project.bridge_runtime_instance_cancel_reservation(g.agents.bridge_runtime_registry,i.bridge_id,generation,i.agent_instance_id);return "",guard.code}
	state.result.phase="awaiting_runtime"
	switch tool {
	case "instances.create":
		sent,send_err:=agent.send_instance_launch(&g.agents,i)
		if !sent {state.result.status="repair_required";state.result.phase="launch_unconfirmed";state.result.error_code=mcp_task_error(send_err)}
	case "instances.start":
		row,accepted,action_err:=agent.start_instance(&g.agents,principal,i.agent_instance_id,&guard,mcp_runtime_native_guard)
		if accepted {state.run_count=row.run_count} else {state.result.status="repair_required";state.result.phase="start_unconfirmed";state.result.error_code=mcp_task_error(action_err)}
	case "instances.stop":
		_,accepted,action_err:=agent.stop_instance(&g.agents,principal,i.agent_instance_id,{reason="user_requested"},&guard,mcp_runtime_native_guard)
		if !accepted {state.result.status="repair_required";state.result.phase="stop_unconfirmed";state.result.error_code=mcp_task_error(action_err)}
	case "instances.reconfigure":
		op:domain.Instance_Reconfiguration;accepted:bool;action_err:domain.Domain_Error
		if a.retry_request_id!="" {op,accepted,action_err=agent.retry_instance_reconfiguration(&g.agents,principal,i.agent_instance_id,state.native_key,a.expected_operation_revision,&guard,mcp_runtime_native_guard)} else {op,accepted,action_err=agent.begin_instance_reconfiguration(&g.agents,principal,i.agent_instance_id,{bridge_id=a.bridge_id,project_id=a.project_id,provider=a.provider,provider_profile=a.provider_profile,model=a.model,idempotency_key=state.native_key,expected_revision=i.configuration_revision},&guard,mcp_runtime_native_guard)}
		if accepted {state.result.native_operation_id=strings.clone(op.operation_id,context.temp_allocator)} else {state.result.status="repair_required";state.result.phase="move_unconfirmed";state.result.error_code=mcp_task_error(action_err)}
		domain.instance_reconfiguration_destroy(&op)
		if !accepted {
			// Native move dispatch always follows a persisted operation. A
			// definitive missing row proves that this attempt sent no commands.
			existing,found,lookup_err:=iface.instance_reconfiguration_get(&g.repos.agents,view.owner,i.agent_instance_id,state.native_key)
			if found {state.result.status="accepted";state.result.phase="awaiting_runtime"} else if lookup_err.code==.Not_Found {state.result.status="failed";state.result.phase="not_dispatched"}
			domain.instance_reconfiguration_destroy(&existing)
		}
	}
	if guard.code!="" {state.result.status="failed";state.result.phase="not_dispatched";state.result.error_code=guard.code}
	if !mcp_runtime_store(g,view,state) {state.result.status="repair_required";state.result.phase="progress_unconfirmed"}
	if guard.code=="invalid_token" do return "","invalid_token"
	if code:=mcp_runtime_authorized(g,raw,view,tool);code!="" do return "",code
	return mcp_runtime_poll(g,view,state),""
}
mcp_runtime_authorized :: proc(g:^App_Graph,raw:string,view:mcp.Access_View,tool:string)->string {
	uow,ok,err:=iface.unit_of_work_begin(&g.uow_factory);if !ok || err.code!=.None do return "request_failed"
	defer iface.unit_of_work_rollback(&uow)
	return mcp_task_write_check(g,raw,view,tool)
}

mcp_runtime_idle :: proc(g:^App_Graph,i:domain.Agent_Instance)->string {
	if i.current_task_id!="" do return "active_task_lease"
	_,held,err:=iface.taskchain_get_lease_by_holder(&g.repos.taskchains,i.agent_instance_id)
	if err.code!=.None && err.code!=.Not_Found do return "request_failed"
	if held do return "active_task_lease"
	return ""
}
mcp_runtime_dispatch_check :: proc(g:^App_Graph,raw:string,view:mcp.Access_View,tool:string,i:domain.Agent_Instance)->string {
	uow,ok,err:=iface.unit_of_work_begin(&g.uow_factory);if !ok || err.code!=.None do return "request_failed"
	defer iface.unit_of_work_rollback(&uow)
	if code:=mcp_task_write_check(g,raw,view,tool);code!="" do return code
	if code:=mcp_runtime_idle(g,i);code!="" do return code
	fresh,found,e:=agent.get_instance(&g.agents,mcp.control_auth(view.owner),i.agent_instance_id);if !found || e.code!=.None do return "not_found"
	if mcp.runtime_revision(fresh)!=mcp.runtime_revision(i) do return "revision_conflict"
	return ""
}
mcp_runtime_store :: proc(g:^App_Graph,view:mcp.Access_View,state:MCP_Runtime_State,stop_prepared:bool=false)->bool {
	uow,ok,err:=iface.unit_of_work_begin(&g.uow_factory);if !ok || err.code!=.None do return false
	if stop_prepared {
		// A committed definition with a cancelled/revoked launch must not remain
		// eligible for an unsolicited task wake after its intent guard is cleared.
		i,found,e:=iface.agent_get_instance(&g.repos.agents,state.result.agent_instance_id)
		if !found || e.code!=.None || i.run_count!=state.run_count || i.configuration_revision!=state.configuration_revision || auth.sha256_hex(i.launch_epoch)!=state.launch_hash {iface.unit_of_work_rollback(&uow);return false}
		i.runtime_status="stopped";i.startup_status="stopped";i.stopped_by=agent.STOPPED_BY_USER
		i.updated_at=platform.clock_now(&g.clock);i.stopped_at=i.updated_at
		_,saved,save_err:=iface.agent_save_instance(&g.repos.agents,i)
		if !saved || save_err.code!=.None {iface.unit_of_work_rollback(&uow);return false}
	}
	encoded,_:=json.marshal(state,allocator=context.temp_allocator)
	if sqlite.mcp_runtime_receipt_update(&g.db,view.owner,view.grant,state.result.tool,state.args.request_id,string(encoded)).code!=.None {iface.unit_of_work_rollback(&uow);return false}
	committed,commit_err:=iface.unit_of_work_commit(&uow)
	return committed && commit_err.code==.None
}
mcp_runtime_poll :: proc(g:^App_Graph,view:mcp.Access_View,state:MCP_Runtime_State)->string {
	r:=state.result
	if r.phase=="progress_unconfirmed" do return mcp_runtime_encoded(r)
	if r.tool=="instances.reconfigure" {
		op,found,_:=iface.instance_reconfiguration_get(&g.repos.agents,view.owner,r.agent_instance_id,state.native_key)
		if found {
			r.native_operation_id=strings.clone(op.operation_id,context.temp_allocator);r.operation_revision=op.revision;r.phase=domain.instance_reconfiguration_phase_string(op.phase)
			#partial switch op.phase {case .Ready:r.status="completed";case .Failed:r.status="failed";case .Recovery_Required:r.status="repair_required";case:r.status="pending"}
			r.error_code=strings.clone(op.failure_code,context.temp_allocator);domain.instance_reconfiguration_destroy(&op)
			if i,exists,_:=agent.get_instance(&g.agents,mcp.control_auth(view.owner),r.agent_instance_id);exists do r.revision=mcp.runtime_revision(i)
			return mcp_runtime_encoded(r)
		}
	}
	if r.phase=="prepared" {r.status="repair_required";r.phase="dispatch_unconfirmed";return mcp_runtime_encoded(r)}
	i,found,err:=agent.get_instance(&g.agents,mcp.control_auth(view.owner),r.agent_instance_id)
	if !found || err.code!=.None {r.status="repair_required";r.phase="instance_unavailable";return mcp_runtime_encoded(r)}
	r.revision=mcp.runtime_revision(i)
	if r.status=="failed" do return mcp_runtime_encoded(r)
	if r.status=="repair_required" do return mcp_runtime_encoded(r)
	if i.configuration_revision!=state.configuration_revision || auth.sha256_hex(i.launch_epoch)!=state.launch_hash {r.status="repair_required";r.phase="runtime_changed";return mcp_runtime_encoded(r)}
	if r.tool=="instances.stop" && i.run_count==state.run_count && i.runtime_status=="stopped" {r.status="completed";r.phase="stopped";r.error_code=""} else if (r.tool=="instances.create" || r.tool=="instances.start") && i.run_count==state.run_count && i.startup_status=="ready" && agent.runtime_expected_active(i.runtime_status) {r.status="completed";r.phase="ready";r.error_code=""} else if i.runtime_status=="failed" || i.runtime_status=="blocked" || i.run_count>state.run_count {r.status="repair_required";r.phase="runtime_changed"} else if r.status!="repair_required" {
		created,cok:=platform.rfc3339_to_unix_ms(r.created_at);now,nok:=platform.rfc3339_to_unix_ms(platform.clock_now(&g.clock))
		if cok && nok && now-created>180_000 {r.status="repair_required";r.phase="confirmation_timeout"} else {r.status="pending"}
	}
	return mcp_runtime_encoded(r)
}
