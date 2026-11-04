package app

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import mcp "odin_test:hub/service/mcp"
import agent "odin_test:hub/service/agent"
import events "odin_test:hub/service/events"
import project "odin_test:hub/service/project"
import tc "odin_test:hub/service/taskchain"
import tv2 "odin_test:hub/service/taskv2"
import http "odin_test:hub/transport/http"

// Use the native UOW connection, not the separate delegation connection: agent
// preparation writes instances, conversations and membership through graph.db.
mcp_create_chain :: proc(ctx:rawptr,raw:string,view:mcp.Access_View,args:mcp.Control_Arguments,title,description:string)->(string,string,string) {
	g:=(^App_Graph)(ctx)
	if !mcp.control_coordinator_arguments_ok(args) do return "","","coordinator_agent_id_and_bridge_id_required"
	uow,begun,err:=iface.unit_of_work_begin(&g.uow_factory)
	if !begun || err.code!=.None do return "","","request_failed"
	finished:=false
	defer if !finished do iface.unit_of_work_rollback(&uow)
	if code:=mcp_task_write_check(g,raw,view,"chains.create");code!="" do return "","",code
	principal:=mcp.control_auth(view.owner)
	definition,owned,aerr:=agent.get_agent(&g.agents,principal,args.coordinator_agent_id)
	if !owned || aerr.code!=.None do return "","","coordinator_not_found: choose an accessible coordinator_agent_id"
	if definition.state!=.Active do return "","","agent_archived"
	bridge,found,berr:=iface.bridge_get_bridge(&g.repos.bridges,args.bridge_id)
	if !found || berr.code!=.None || string(bridge.owner_user_id)!=view.owner do return "","","bridge_not_found: choose an accessible bridge_id"
	provider,model:=tv2.resolve_launch_model(&g.agents,args.bridge_id,args.provider,args.model,args.provider_profile)
	defer delete(provider);defer delete(model)
	if provider=="" || model=="" do return "","","provider_unavailable: choose an enabled provider and model on bridge_id"
	// Validate the optional project with the native launch rule (owned, active,
	// path resolvable) before the chain row, coordinator or reservation exist.
	if args.project_id!="" {
		perr:=agent.validate_launch_project(&g.agents,principal,domain.Project_ID(args.project_id),args.bridge_id)
		if perr.code==.Not_Found do return "","","project_not_found: choose an accessible project_id"
		if perr.code==.Conflict do return "","","project_archived: choose an active project_id"
		if perr.code!=.None do return "","","request_failed"
	}
	chain,created,cerr:=tc.create_chain(&g.taskchains,principal,{title=title,description=description})
	if !created || cerr.code!=.None do return "","",mcp_task_error(cerr)
	// Native coordinator naming: prepare_instance mints "<agent name> #<n>" for the
	// instance and conversation, like POST /task-chains. The chain keeps the caller
	// title. A sealed agent name yields "<token> #<n>"; MCP readers open embedded tokens.
	inst,generation,prepared,perr:=agent.prepare_instance(&g.agents,principal,{
		agent_id=args.coordinator_agent_id,bridge_id=args.bridge_id,project_id=domain.Project_ID(args.project_id),chain_id=string(chain.chain_id),
		provider=provider,provider_profile=args.provider_profile,model=model,
		member_role="coordinator",
	})
	if !prepared || perr.code!=.None do return "","",mcp_task_error(perr)
	committed:=false
	defer if !committed do project.bridge_runtime_instance_cancel_reservation(g.agents.bridge_runtime_registry,inst.bridge_id,generation,inst.agent_instance_id)
	// Native preparation currently treats membership writes as best effort. The
	// MCP operation promises atomic binding, so verify them before committing.
	saved,bound,rerr:=iface.taskchain_get_chain(&g.repos.taskchains,chain.chain_id)
	if !bound || rerr.code!=.None || saved.coordinator_agent_instance_id!=inst.agent_instance_id || string(inst.project_id)!=args.project_id do return "","","request_failed"
	members,merr:=iface.taskchain_list_members_by_chain(&g.repos.taskchains,chain.chain_id,domain.User_ID(view.owner))
	if merr.code!=.None do return "","","request_failed"
	member_ok:=false
	for member in members do if member.role=="coordinator" && member.agent_instance_id==inst.agent_instance_id && member.agent_id==args.coordinator_agent_id do member_ok=true
	if !member_ok do return "","","request_failed"
	ok,commit_err:=iface.unit_of_work_commit(&uow)
	finished=true
	if !ok || commit_err.code!=.None do return "","","request_failed"
	committed=true
	mcp_chain_create_publish(&g.event_bus,view.owner,inst,string(chain.chain_id))
	// Never dispatch under the UOW or retry an ambiguous launch. Return durable
	// identifiers even on dispatch failure, so the caller can inspect/recover it.
	fresh,valid:=mcp.access_view(&g.mcp_delegation,&g.mcp_vault_view,raw)
	if !valid || !mcp.access_same(view,fresh) {
		project.bridge_runtime_instance_cancel_reservation(g.agents.bridge_runtime_registry,inst.bridge_id,generation,inst.agent_instance_id)
		return string(chain.chain_id),inst.agent_instance_id,"coordinator_launch_not_dispatched"
	}
	if sent,_:=agent.send_instance_launch(&g.agents,inst);!sent {
		project.bridge_runtime_instance_cancel_reservation(g.agents.bridge_runtime_registry,inst.bridge_id,generation,inst.agent_instance_id)
		return string(chain.chain_id),inst.agent_instance_id,"coordinator_launch_unconfirmed"
	}
	return string(chain.chain_id),inst.agent_instance_id,""
}

// Announce the committed chain and its coordinator to the owner's live clients,
// the same pair POST /task-chains emits. The sidebar chain list resets only on a
// task_chain "created" frame, so without it an MCP-created chain stays hidden
// until reload. Sent once durable, whatever the launch dispatch outcome.
mcp_chain_create_publish :: proc(bus:^events.User_Event_Bus,owner:string,inst:domain.Agent_Instance,chain_id:string) {
	http.publish_instance_created(bus,inst)
	http.publish_chain_event(bus,owner,chain_id,"created")
}
