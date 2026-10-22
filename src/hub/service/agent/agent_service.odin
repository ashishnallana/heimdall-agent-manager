package agent

import "base:runtime"
import "core:fmt"
import base64 "core:encoding/base64"
import "core:strings"
import "core:sync"
import "core:crypto/hash"
import "core:encoding/hex"
import contracts "odin_test:contracts"
import bootcache "odin_test:hub/bootcache"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import ownership "odin_test:hub/service/ownership"
import project_service "odin_test:hub/service/project"
import platform "odin_test:hub/platform"
import jsonx "odin_test:lib/jsonx"

Agent_Service :: struct {
	entitlements: domain.Entitlement_Lookup,
	reconfiguration_mutex: sync.Mutex,
	agents: ^iface.Agent_Repository,
	bridges: ^iface.Bridge_Repository,
	projects: ^iface.Project_Repository,
	content: ^iface.Content_Repository,
	taskchains: ^iface.Taskchain_Repository,
	providers: ^iface.Provider_Repository,
	bridge_runtime_registry: ^project_service.Bridge_Runtime_Registry,
	bridge_command_sink: project_service.Bridge_Command_Sink,
	clock: ^platform.Clock,
	ids: ^platform.ID_Generator,
	// lifecycle hooks (Task System v2): set by wiring so every instance death
	// path funnels into ONE chokepoint (taskv2.on_instance_terminal) without the
	// agent package importing the engine.
	hooks: Lifecycle_Hooks,
}

Lifecycle_Hooks :: struct {
	ctx:              rawptr,
	on_terminal:      proc(ctx: rawptr, instance_id: string),
	on_activity:      proc(ctx: rawptr, instance_id, activity_status: string),
	on_start_success: proc(ctx: rawptr, inst: domain.Agent_Instance),
	// on_user_stopped: a person stopped the instance (stopped_by is already
	// persisted). The engine releases its lease without spending an attempt and
	// hands the task to another instance — BEFORE the stop is sent, so the later
	// terminal report finds nothing to expire (F4).
	on_user_stopped:  proc(ctx: rawptr, instance_id: string),
}

// STOPPED_BY_USER marks an instance a person stopped; the lease matcher never
// picks it again until a user starts or restarts it.
STOPPED_BY_USER :: "user"

// notify_instance_terminal is the ONE place every death path (status report
// stopped|failed|unreachable, heartbeat reconcile, bridge disconnect, reaper,
// delete) calls; the engine expires the instance's lease and re-plans.
notify_instance_terminal :: proc(service: ^Agent_Service, instance_id: string) {
	if service == nil || service.hooks.on_terminal == nil || instance_id == "" do return
	service.hooks.on_terminal(service.hooks.ctx, instance_id)
}

// Lifecycle_Fact is what a status write learned about an instance; callers that
// run under a Bridge_Runtime_Connection.state_mutex collect facts and deliver
// them with notify_facts AFTER the unlock (lock order tx_mutex → state_mutex).
Lifecycle_Fact :: struct {
	instance_id: string,
	terminal:    bool,
	activity:    string,
}

notify_facts :: proc(service: ^Agent_Service, facts: []Lifecycle_Fact) {
	for f in facts {
		if f.terminal do notify_instance_terminal(service, f.instance_id)
		else do notify_instance_activity(service, f.instance_id, f.activity)
	}
}

// notify_instances_terminal delivers the terminal fact for every instance a
// liveness sweep (reconcile_bridge_heartbeat, mark_bridge_instances_unreachable,
// reap_stale_instances) returned. Those procs never call the hooks themselves
// because two of their callers hold a connection state_mutex.
notify_instances_terminal :: proc(service: ^Agent_Service, insts: []domain.Agent_Instance) {
	for inst in insts do notify_instance_terminal(service, inst.agent_instance_id)
}

notify_instance_activity :: proc(service: ^Agent_Service, instance_id, activity_status: string) {
	if service == nil || service.hooks.on_activity == nil || instance_id == "" || activity_status == "" do return
	service.hooks.on_activity(service.hooks.ctx, instance_id, activity_status)
}

instance_runtime_is_terminal :: proc(runtime_status: string) -> bool {
	switch runtime_status {
	case "stopped", "failed", "unreachable": return true
	}
	return false
}

Create_Agent_Input :: struct {
	name: string,
	slug: string,
	template_id: string,
	instructions: string,
	has_template_id: bool,
}

Support_Input :: struct {
	bridge_id: string,
	enabled: bool,
	priority: int,
	max_instances: int,
}

Run_Request :: struct {
	provider: string,
	model: string,
}

List_Instances_Filter :: struct {
	agent_id: string,
	bridge_id: string,
	runtime_status: string,
	project_id: string,
}

Create_Instance_Input :: struct {
	agent_id: string,
	bridge_id: string,
	provider: string,
	model: string,
	project_id: domain.Project_ID,
	chain_id: string,
	display_name: string,
	member_role: string,
}

Stop_Instance_Input :: struct { reason: string, force: bool }
Reconfigure_Instance_Input :: struct { provider, model, agent_id, bridge_id, chain_id, conversation_id, display_name: string, project_id: domain.Project_ID, has_agent_id, has_bridge_id, has_project_id, has_chain_id, has_conversation_id, has_display_name: bool }

new_agent_service :: proc(agents: ^iface.Agent_Repository, bridges: ^iface.Bridge_Repository, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> Agent_Service {
	return Agent_Service{agents = agents, bridges = bridges, clock = clock, ids = ids}
}

new_agent_service_with_runtime :: proc(agents: ^iface.Agent_Repository, bridges: ^iface.Bridge_Repository, projects: ^iface.Project_Repository, content: ^iface.Content_Repository, taskchains: ^iface.Taskchain_Repository, sink: project_service.Bridge_Command_Sink, registry: ^project_service.Bridge_Runtime_Registry, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> Agent_Service {
	return Agent_Service{agents = agents, bridges = bridges, projects = projects, content = content, taskchains = taskchains, bridge_command_sink = sink, bridge_runtime_registry = registry, clock = clock, ids = ids}
}

create_agent :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, input: Create_Agent_Input) -> (domain.Agent, bool, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return domain.Agent{}, false, err
	if strings.trim_space(input.name) == "" do return domain.Agent{}, false, domain.domain_error(.Validation_Failed, "agent name is required")
	slug := input.slug
	if slug == "" do slug = input.name
	// Default new agents to the built-in 'empty' template when none is supplied so
	// every agent has a valid template (see domain.TEMPLATE_EMPTY_ID).
	template_id := strings.trim_space(input.template_id)
	if template_id == "" do template_id = domain.TEMPLATE_EMPTY_ID
	now := platform.clock_now(service.clock)
	agent := domain.Agent{agent_id = platform.generate_id(service.ids, "agt_"), owner_user_id = owner, name = input.name, slug = slug, template_id = template_id, instructions = input.instructions, state = .Active, created_at = now, updated_at = now}
	return iface.agent_save(service.agents, agent)
}

list_agents :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, limit: int = 50, cursor: string = "") -> ([]domain.Agent, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, err
	return iface.agent_list_by_owner(service.agents, owner, limit, cursor)
}

get_agent :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, agent_id: string) -> (domain.Agent, bool, domain.Domain_Error) {
	agent, ok, err := iface.agent_get(service.agents, agent_id)
	if !ok do return domain.Agent{}, false, err
	if owner_ok, owner_err := ownership.require_owner(auth, agent.owner_user_id); !owner_ok do return domain.Agent{}, false, owner_err
	return agent, true, domain.Domain_Error{}
}

update_agent :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, agent_id: string, input: Create_Agent_Input) -> (domain.Agent, bool, domain.Domain_Error) {
	agent, ok, err := get_agent(service, auth, agent_id)
	if !ok do return domain.Agent{}, false, err
	if input.name != "" do agent.name = input.name
	if input.slug != "" do agent.slug = input.slug
	if input.has_template_id {
		template_id := strings.trim_space(input.template_id)
		if template_id == "" do template_id = domain.TEMPLATE_EMPTY_ID
		if !agent_template_available(service, agent.owner_user_id, template_id) do return domain.Agent{}, false, domain.domain_error(.Validation_Failed, "template not found")
		agent.template_id = template_id
	}
	if input.instructions != "" do agent.instructions = input.instructions
	agent.updated_at = platform.clock_now(service.clock)
	return iface.agent_save(service.agents, agent)
}

// agent_template_available reports whether template_id is usable by owner: the
// built-in 'empty' template, any system template, or a template the owner owns.
// Mirrors content_service.template_available but reads the content repository the
// agent service already holds (avoiding a cross-service dependency).
agent_template_available :: proc(service: ^Agent_Service, owner: domain.User_ID, template_id: string) -> bool {
	if template_id == "" do return false
	switch template_id {
	case domain.TEMPLATE_EMPTY_ID, domain.TEMPLATE_COORDINATOR_ID, domain.TEMPLATE_WORKER_ID, domain.TEMPLATE_REVIEWER_ID, domain.TEMPLATE_SOLOIST_ID, domain.TEMPLATE_CURATOR_ID:
		return true
	}
	if service.content == nil do return false
	t, ok, _ := iface.content_get_template(service.content, template_id)
	return ok && (t.is_system || t.owner_user_id == owner)
}

archive_agent :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, agent_id: string) -> (domain.Agent, bool, domain.Domain_Error) {
	agent, ok, err := get_agent(service, auth, agent_id)
	if !ok do return domain.Agent{}, false, err
	agent.state = .Archived
	agent.updated_at = platform.clock_now(service.clock)
	return iface.agent_save(service.agents, agent)
}

list_support :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, agent_id: string) -> ([]domain.Agent_Bridge_Support, domain.Domain_Error) {
	agent, ok, err := get_agent(service, auth, agent_id)
	if !ok do return nil, err
	return iface.agent_list_support(service.agents, agent.agent_id, agent.owner_user_id)
}

upsert_support :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, agent_id: string, input: Support_Input) -> (domain.Agent_Bridge_Support, bool, domain.Domain_Error) {
	agent, ok, err := get_agent(service, auth, agent_id)
	if !ok do return domain.Agent_Bridge_Support{}, false, err
	if valid, validate_err := validate_support_input(service, auth, agent, input); !valid do return domain.Agent_Bridge_Support{}, false, validate_err
	now := platform.clock_now(service.clock)
	existing, existing_ok, _ := iface.agent_get_support(service.agents, agent_id, input.bridge_id)
	created_at := now
	if existing_ok do created_at = existing.created_at
	support := domain.Agent_Bridge_Support{agent_id = agent.agent_id, bridge_id = input.bridge_id, owner_user_id = agent.owner_user_id, enabled = input.enabled, priority = input.priority, max_instances = input.max_instances, created_at = created_at, updated_at = now}
	return iface.agent_save_support(service.agents, support)
}

validate_support_input :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, agent: domain.Agent, input: Support_Input) -> (bool, domain.Domain_Error) {
	bridge, bridge_ok, bridge_err := iface.bridge_get_bridge(service.bridges, input.bridge_id)
	if !bridge_ok do return false, bridge_err
	if owner_ok, owner_err := ownership.require_owner(auth, bridge.owner_user_id); !owner_ok do return false, owner_err
	if bridge.owner_user_id != agent.owner_user_id do return false, domain.domain_error(.Not_Found, "bridge not found")
	if input.max_instances < 0 do return false, domain.domain_error(.Validation_Failed, "max_instances must be positive")
	return true, domain.Domain_Error{}
}

replace_supports :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, agent_id: string, inputs: []Support_Input) -> ([]domain.Agent_Bridge_Support, bool, domain.Domain_Error) {
	agent, agent_ok, agent_err := get_agent(service, auth, agent_id)
	if !agent_ok do return nil, false, agent_err
	for input in inputs {
		if valid, validate_err := validate_support_input(service, auth, agent, input); !valid do return nil, false, validate_err
	}
	existing, list_err := iface.agent_list_support(service.agents, agent.agent_id, agent.owner_user_id)
	if list_err.code != .None do return nil, false, list_err
	for support in existing {
		_, delete_err := iface.agent_delete_support(service.agents, agent.agent_id, support.bridge_id, agent.owner_user_id)
		if delete_err.code != .None do return nil, false, delete_err
	}
	out := make([dynamic]domain.Agent_Bridge_Support)
	for input in inputs {
		support, saved, save_err := upsert_support(service, auth, agent_id, input)
		if !saved do return nil, false, save_err
		append(&out, support)
	}
	return out[:], true, domain.Domain_Error{}
}

delete_support :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, agent_id, bridge_id: string) -> (bool, domain.Domain_Error) {
	agent, ok, err := get_agent(service, auth, agent_id)
	if !ok do return false, err
	return iface.agent_delete_support(service.agents, agent.agent_id, bridge_id, agent.owner_user_id)
}

default_support_for_agent_bridge :: proc(agent: domain.Agent, bridge_id: string) -> domain.Agent_Bridge_Support {
	return domain.Agent_Bridge_Support{agent_id = agent.agent_id, bridge_id = bridge_id, owner_user_id = agent.owner_user_id, enabled = true}
}


// Reserve active tracking capacity before any launch is sent. Reservations are
// generation-scoped and expire if no status report confirms the launch.
reserve_runtime_launch :: proc(service: ^Agent_Service, inst: domain.Agent_Instance) -> (int, bool, domain.Domain_Error) {
	generation := project_service.bridge_runtime_registry_generation(service.bridge_runtime_registry, inst.bridge_id)
	_, admitted, err := project_service.bridge_runtime_instance_apply(service.bridge_runtime_registry, inst.bridge_id, generation, inst.agent_instance_id, string(inst.owner_user_id), "launching", "unknown", 0, reserve = true)
	return generation, admitted, err
}

create_instance :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, input: Create_Instance_Input) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	saved, generation, ok, err := prepare_instance(service, auth, input)
	if !ok do return domain.Agent_Instance{}, false, err
	if sent, send_err := send_instance_launch(service, saved); !sent {
		project_service.bridge_runtime_instance_cancel_reservation(service.bridge_runtime_registry, saved.bridge_id, generation, saved.agent_instance_id)
		return domain.Agent_Instance{}, false, send_err
	}
	return saved, true, domain.Domain_Error{}
}

// prepare_instance is create_instance WITHOUT the network send: it validates,
// reserves runtime capacity, writes the instance row, conversation and chain
// membership, and returns the row plus the registry generation of the
// reservation. The caller either sends the launch (send_instance_launch) or
// delivers the instance through a wake_agent run[] entry after its own commit
// (Task System v2 JIT grants), and must cancel the reservation if it gives up.
prepare_instance :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, input: Create_Instance_Input) -> (inst: domain.Agent_Instance, generation: int, ok: bool, err: domain.Domain_Error) {
	owner, owner_ok, owner_err := ownership.owner_from_auth(auth)
	if !owner_ok do return domain.Agent_Instance{}, 0, false, owner_err
	agent, agent_ok, agent_err := get_agent(service, auth, input.agent_id)
	if !agent_ok do return domain.Agent_Instance{}, 0, false, agent_err
	if agent.state != .Active do return {}, 0, false, domain.domain_error(.Conflict, "archived agents cannot be launched")
	bridge_id := strings.trim_space(input.bridge_id)
	if bridge_id == "" && auth.bridge_id != "" {
		bridge_id = auth.bridge_id
	}
	if bridge_id == "" do return domain.Agent_Instance{}, 0, false, domain.domain_error(.Validation_Failed, "bridge_id is required; choose the bridge to run this agent on")
	bridge, bridge_ok, bridge_err := iface.bridge_get_bridge(service.bridges, bridge_id)
	if !bridge_ok do return domain.Agent_Instance{}, 0, false, bridge_err
	if bridge.owner_user_id != owner || bridge.owner_user_id != agent.owner_user_id do return domain.Agent_Instance{}, 0, false, domain.domain_error(.Not_Found, "bridge not found")
	if plan_err := require_launch_bridge_enabled(service, bridge); plan_err.code != .None do return {}, 0, false, plan_err
	if bridge.status != .Online || !project_service.bridge_runtime_registry_has_live(service.bridge_runtime_registry, bridge.bridge_id) do return domain.Agent_Instance{}, 0, false, domain.domain_error(.Bridge_Offline, "bridge is offline")
	resolved, resolved_ok, resolved_err := resolve_provider_model(service, auth, agent.agent_id, bridge.bridge_id, Run_Request{provider = input.provider, model = input.model})
	if !resolved_ok do return domain.Agent_Instance{}, 0, false, resolved_err
	// Mint one per-agent global counter for this run and derive the default title
	// "<agent-name> #<n>". The same default title is used for the (new) chain and
	// the conversation so a run is identifiable before the agent/user renames it.
	default_title := default_title_for_agent(service, owner, agent)
	chain_id, chain_ok, chain_err := resolve_instance_chain(service, owner, input.chain_id, default_title)
	if !chain_ok do return domain.Agent_Instance{}, 0, false, chain_err
	project_path := ""
	if input.project_id != "" {
		path, path_ok, path_err := resolve_project_path_for_launch(service, owner, input.project_id, bridge.bridge_id)
		if !path_ok do return domain.Agent_Instance{}, 0, false, path_err
		project_path = path
	}
	now := platform.clock_now(service.clock)
	instance_id := platform.generate_id(service.ids, "inst_")
	conversation_id := platform.generate_id(service.ids, "chat_")
	display_name := strings.trim_space(input.display_name)
	if display_name == "" do display_name = default_title
	instance := domain.Agent_Instance{agent_instance_id = instance_id, owner_user_id = owner, agent_id = agent.agent_id, bridge_id = bridge.bridge_id, display_name = display_name, provider = resolved.provider, model = resolved.model, project_id = input.project_id, project_path = project_path, chain_id = chain_id, conversation_id = conversation_id, runtime_status = "launching", startup_status = "starting", activity_status = "unknown", last_applied_seq = 0, run_count = 1, created_at = now, updated_at = now, started_at = now, last_seen_at = now}
	admitted: bool
	quota_err: domain.Domain_Error
	generation, admitted, quota_err = reserve_runtime_launch(service, instance)
	if !admitted do return {}, 0, false, quota_err
	prepared := false
	defer if !prepared do project_service.bridge_runtime_instance_cancel_reservation(service.bridge_runtime_registry, instance.bridge_id, generation, instance.agent_instance_id)
	saved, saved_ok, save_err := iface.agent_save_instance(service.agents, instance)
	if !saved_ok do return domain.Agent_Instance{}, 0, false, save_err
	conv, conv_ok, conv_err := ensure_instance_conversation(service, saved, default_title)
	if !conv_ok do return domain.Agent_Instance{}, 0, false, conv_err
	if saved.conversation_id == "" { saved.conversation_id = conv.conversation_id; saved, saved_ok, save_err = iface.agent_save_instance(service.agents, saved); if !saved_ok do return domain.Agent_Instance{}, 0, false, save_err }
	if service.taskchains != nil && saved.chain_id != "" {
		members, _ := iface.taskchain_list_members_by_chain(service.taskchains, domain.Task_Chain_ID(saved.chain_id), saved.owner_user_id)
		role := input.member_role
		if role == "" {
			role = "coordinator" if len(members) == 0 else "worker"
		}
		now_m := platform.clock_now(service.clock)
		member := domain.Task_Chain_Member{chain_id = domain.Task_Chain_ID(saved.chain_id), agent_instance_id = saved.agent_instance_id, agent_id = saved.agent_id, owner_user_id = saved.owner_user_id, role = role, created_at = now_m}
		iface.taskchain_save_member(service.taskchains, member)
		if role == "coordinator" {
			update_private_chain_coordinator(service, saved)
		}
	}
	prepared = true
	return saved, generation, true, domain.Domain_Error{}
}

// send_instance_launch pushes the launch_agent command for a prepared instance.
send_instance_launch :: proc(service: ^Agent_Service, saved: domain.Agent_Instance) -> (bool, domain.Domain_Error) {
	command_id := strings.concatenate({platform.generate_id(service.ids, "cmd_launch_"), "_", saved.agent_instance_id})
	command := project_service.Runtime_Command{bridge_id = saved.bridge_id, command_id = command_id, body_json = launch_command_json_full(service, command_id, saved)}
	return project_service.bridge_command_send_runtime(service.bridge_command_sink, command)
}

launch_agent :: create_instance

create_provider_test_instance :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, bridge_id, provider, model: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	owner, owner_ok, owner_err := ownership.owner_from_auth(auth)
	if !owner_ok do return {}, false, owner_err
	bridge, bridge_ok, bridge_err := iface.bridge_get_bridge(service.bridges, bridge_id)
	if !bridge_ok do return {}, false, bridge_err
	defer domain.bridge_destroy(&bridge)
	if bridge.owner_user_id != owner do return {}, false, domain.domain_error(.Not_Found, "bridge not found")
	if plan_err := require_launch_bridge_enabled(service, bridge); plan_err.code != .None do return {}, false, plan_err
	if bridge.status != .Online || !project_service.bridge_runtime_registry_has_live(service.bridge_runtime_registry, bridge_id) do return {}, false, domain.domain_error(.Bridge_Offline, "bridge is not connected")
	now := platform.clock_now(service.clock)
	instance_id := platform.generate_id(service.ids, "provider-test-")
	inst := domain.Agent_Instance{agent_instance_id=instance_id,owner_user_id=owner,bridge_id=bridge_id,display_name="Provider test",provider=provider,model=model,kind="provider_test",runtime_status="launching",startup_status="starting",activity_status="unknown",run_count=1,created_at=now,updated_at=now,started_at=now,last_seen_at=now}
	saved, saved_ok, save_err := iface.agent_save_instance(service.agents, inst)
	if !saved_ok do return {}, false, save_err
	return saved, true, {}
}

launch_provider_test_instance :: proc(service: ^Agent_Service, saved: domain.Agent_Instance) -> domain.Domain_Error {
	if saved.kind != "provider_test" do return domain.domain_error(.Validation_Failed, "instance is not a provider test")
	generation, admitted, quota_err := reserve_runtime_launch(service, saved)
	if !admitted do return quota_err
	launch_sent := false
	defer if !launch_sent do project_service.bridge_runtime_instance_cancel_reservation(service.bridge_runtime_registry, saved.bridge_id, generation, saved.agent_instance_id)
	command_id := strings.concatenate({platform.generate_id(service.ids, "cmd_provider_test_"), "_", saved.agent_instance_id})
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"launch_provider_test\",\"command_id\":\""); write_service_json_string(&b, command_id)
	strings.write_string(&b, "\",\"agent_instance_id\":\""); write_service_json_string(&b, saved.agent_instance_id)
	strings.write_string(&b, "\",\"provider\":\""); write_service_json_string(&b, saved.provider)
	strings.write_string(&b, "\",\"model\":\""); write_service_json_string(&b, saved.model)
	strings.write_string(&b, "\"}")
	command := project_service.Runtime_Command{bridge_id=saved.bridge_id,command_id=command_id,body_json=strings.to_string(b)}
	if sent, send_err := project_service.bridge_command_send_runtime(service.bridge_command_sink, command); !sent {
		return send_err
	}
	launch_sent = true
	return {}
}

cleanup_provider_test_instance :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id: string) -> domain.Domain_Error {
	inst, ok, err := get_instance(service, auth, instance_id)
	if !ok do return err
	if inst.kind != "provider_test" do return domain.domain_error(.Forbidden, "instance is not a provider test")
	if project_service.bridge_runtime_registry_has_live(service.bridge_runtime_registry, inst.bridge_id) {
		command_id := strings.concatenate({platform.generate_id(service.ids, "cmd_provider_test_stop_"), "_", inst.agent_instance_id})
		command := project_service.Runtime_Command{bridge_id=inst.bridge_id,command_id=command_id,body_json=stop_command_json(command_id, inst.agent_instance_id, "provider_test_complete")}
		_, _ = project_service.bridge_command_send_runtime(service.bridge_command_sink, command)
	}
	_, delete_err := iface.agent_delete_instance(service.agents, instance_id)
	return delete_err
}

list_instances :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, limit: int = 50, cursor: string = "") -> ([]domain.Agent_Instance, domain.Domain_Error) {
	return list_instances_filtered(service, auth, List_Instances_Filter{}, limit, cursor)
}

list_instances_filtered :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, filter: List_Instances_Filter, limit: int = 50, cursor: string = "") -> ([]domain.Agent_Instance, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, err
	has_filter := filter.agent_id != "" || filter.bridge_id != "" || filter.runtime_status != "" || filter.project_id != ""
	fetch_limit := limit if !has_filter else max(limit * 10, 500)
	instances, list_err := iface.agent_list_instances_by_owner(service.agents, owner, fetch_limit, cursor)
	if list_err.code != .None do return nil, list_err
	out := make([dynamic]domain.Agent_Instance)
	for inst in instances {
		if filter.agent_id != "" && inst.agent_id != filter.agent_id do continue
		if filter.bridge_id != "" && inst.bridge_id != filter.bridge_id do continue
		if filter.project_id != "" && string(inst.project_id) != filter.project_id do continue
		if filter.runtime_status != "" {
			if filter.runtime_status == "live" || filter.runtime_status == "active" {
				if !runtime_expected_active(inst.runtime_status) do continue
			} else if inst.runtime_status != filter.runtime_status {
				continue
			}
		}
		append(&out, inst)
		if len(out) >= limit do break
	}
	return out[:], domain.Domain_Error{}
}

active_instance_count_for_bridge :: proc(service: ^Agent_Service, bridge_id: string) -> int {
	if service == nil || service.agents == nil || bridge_id == "" do return 0
	instances, err := iface.agent_list_instances_by_bridge(service.agents, bridge_id)
	if err.code != .None do return 0
	count := 0
	for inst in instances { if runtime_expected_active(inst.runtime_status) do count += 1 }
	return count
}

active_instance_count_for_agent :: proc(service: ^Agent_Service, agent: domain.Agent) -> int {
	if service == nil || service.agents == nil do return 0
	instances, err := iface.agent_list_instances_by_owner(service.agents, agent.owner_user_id, 1000, "")
	if err.code != .None do return 0
	count := 0
	for inst in instances { if inst.agent_id == agent.agent_id && runtime_expected_active(inst.runtime_status) do count += 1 }
	return count
}

supported_bridge_count_for_agent :: proc(service: ^Agent_Service, agent: domain.Agent) -> int {
	if service == nil || service.bridges == nil do return 0
	bridges, err := iface.bridge_list_by_owner(service.bridges, agent.owner_user_id)
	if err.code != .None do return 0
	count := 0
	for bridge in bridges {
		if bridge.plan_disabled_at == "" && bridge.status == .Online && bridge.capabilities_json != "" do count += 1
	}
	return count
}

get_instance :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	inst, ok, err := iface.agent_get_instance(service.agents, instance_id)
	if !ok do return domain.Agent_Instance{}, false, err
	if owner_ok, owner_err := ownership.require_owner(auth, inst.owner_user_id); !owner_ok do return domain.Agent_Instance{}, false, owner_err
	return inst, true, domain.Domain_Error{}
}

verify_instance_token :: proc(service: ^Agent_Service, token: string) -> (contracts.Auth_Context, domain.Agent_Instance, bool, domain.Domain_Error) {
	if service == nil || service.agents == nil do return contracts.Auth_Context{}, domain.Agent_Instance{}, false, domain.domain_error(.Internal_Error, "agent service is not configured")
	if !strings.has_prefix(token, "hit_") do return contracts.Auth_Context{}, domain.Agent_Instance{}, false, domain.domain_error(.Unauthenticated, "instance bearer token is required")
	instance_id := instance_id_from_assertion(strings.trim_space(token))
	if instance_id == "" do return contracts.Auth_Context{}, domain.Agent_Instance{}, false, domain.domain_error(.Unauthenticated, "instance bearer token is invalid")
	inst, ok, err := iface.agent_get_instance(service.agents, instance_id)
	if !ok do return contracts.Auth_Context{}, domain.Agent_Instance{}, false, err
	expected := instance_assertion_token(inst); defer delete(expected)
	if token != expected do return {}, {}, false, domain.domain_error(.Unauthenticated, "superseded launch token")
	return contracts.Auth_Context{kind = .Instance_Token, user_id = string(inst.owner_user_id), agent_instance_id = inst.agent_instance_id, bridge_id = inst.bridge_id}, inst, true, domain.Domain_Error{}
}

mark_instance_start_success :: proc(service: ^Agent_Service, auth: contracts.Auth_Context) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	if auth.kind != .Instance_Token || auth.agent_instance_id == "" do return domain.Agent_Instance{}, false, domain.domain_error(.Forbidden, "instance token is required")
	inst, ok, err := iface.agent_get_instance(service.agents, auth.agent_instance_id)
	if !ok do return domain.Agent_Instance{}, false, err
	if inst.owner_user_id != domain.User_ID(auth.user_id) do return domain.Agent_Instance{}, false, domain.domain_error(.Not_Found, "agent instance not found")
	now := platform.clock_now(service.clock)
	inst.runtime_status = "running"
	inst.startup_status = "ready"
	inst.activity_status = "idle"
	inst.last_applied_seq += 1
	inst.last_seen_at = now
	inst.stopped_at = ""
	inst.updated_at = now
	saved, saved_ok, save_err := iface.agent_save_instance(service.agents, inst)
	if saved_ok && service.hooks.on_start_success != nil do service.hooks.on_start_success(service.hooks.ctx, saved)
	return saved, saved_ok, save_err
}

bootstrap_skill_file_content :: proc(m: domain.Memory, name: string) -> string {
	body := m.body
	if strings.index(body, "\\n") >= 0 {
		replaced, _ := strings.replace_all(body, "\\n", "\n")
		body = replaced
	}
	trimmed := strings.trim_space(body)
	if strings.has_prefix(trimmed, "---\n") || strings.has_prefix(trimmed, "---\r\n") do return trimmed
	content := strings.builder_make()
	strings.write_string(&content, "---\nname: "); strings.write_string(&content, name)
	strings.write_string(&content, "\ndescription: ")
	if strings.trim_space(m.description) != "" {
		strings.write_string(&content, m.description)
	} else if strings.trim_space(m.title) != "" {
		strings.write_string(&content, m.title)
	} else {
		strings.write_string(&content, name)
	}
	strings.write_string(&content, "\nheimdall_managed: true\n---\n\n# ")
	if strings.trim_space(m.title) != "" { strings.write_string(&content, m.title) } else { strings.write_string(&content, name) }
	strings.write_string(&content, "\n\n")
	strings.write_string(&content, body)
	return strings.to_string(content)
}

bootstrap_skill_name :: proc(m: domain.Memory) -> string {
	if name := bootstrap_skill_frontmatter_value(m.body, "name"); name != "" do return bootstrap_safe_slug(name)
	if slug := bootstrap_safe_slug(m.title); slug != "" do return slug
	return bootstrap_safe_slug(m.memory_id)
}

bootstrap_skill_frontmatter_value :: proc(body, key: string) -> string {
	text := body
	if strings.index(text, "\\n") >= 0 { replaced, _ := strings.replace_all(text, "\\n", "\n"); text = replaced }
	trimmed := strings.trim_space(text)
	if !strings.has_prefix(trimmed, "---") do return ""
	prefix := strings.concatenate({key, ":"})
	defer delete(prefix)
	idx := 0
	for line in strings.split_lines_iterator(&trimmed) {
		line_trimmed := strings.trim_space(line)
		if idx == 0 {
			if line_trimmed != "---" do return ""
			idx += 1
			continue
		}
		if line_trimmed == "---" do break
		if strings.has_prefix(line_trimmed, prefix) do return strings.trim(strings.trim_space(line_trimmed[len(prefix):]), " \t\"'")
		idx += 1
	}
	return ""
}

bootstrap_safe_slug :: proc(value: string) -> string {
	b := strings.builder_make()
	last_dash := false
	for ch in strings.to_lower(strings.trim_space(value)) {
		switch ch {
		case 'a'..='z', '0'..='9':
			strings.write_rune(&b, ch); last_dash = false
		case '-', '_', ' ', '.', '/', ':':
			if !last_dash { strings.write_byte(&b, '-'); last_dash = true }
		case:
		}
	}
	return strings.trim(strings.to_string(b), "-")
}

write_bootstrap_memories :: proc(b: ^strings.Builder, service: ^Agent_Service, owner: domain.User_ID, inst: domain.Agent_Instance) {
	if service == nil || service.content == nil do return
	memories, err := iface.content_list_memories(service.content, owner)
	if err.code != .None do return
	written := 0
	for m in memories {
		if !bootstrap_memory_applies(m, service, owner, inst) do continue
		if written > 0 do strings.write_byte(b, ',')
		strings.write_string(b, "{\"memory_id\":\""); write_service_json_string(b, m.memory_id)
		strings.write_string(b, "\",\"agent_ids\":"); write_service_memory_id_array(b, m.agent_ids)
		strings.write_string(b, ",\"project_ids\":"); write_service_memory_project_array(b, m.project_ids)
		strings.write_string(b, ",\"template_ids\":"); write_service_memory_id_array(b, m.template_ids)
		strings.write_string(b, ",\"bridge_ids\":"); write_service_memory_id_array(b, m.bridge_ids)
		strings.write_string(b, ",\"type\":\""); write_service_json_string(b, domain.memory_type_string(m.type))
		strings.write_string(b, "\",\"status\":\""); write_service_json_string(b, m.status)
		strings.write_string(b, "\",\"title\":\""); write_service_json_string(b, m.title)
		strings.write_string(b, "\",\"body\":\""); write_service_json_string(b, m.body)
		strings.write_string(b, "\",\"evidence\":\""); write_service_json_string(b, m.evidence)
		strings.write_string(b, "\"}")
		written += 1
	}
}

// write_service_memory_id_array / write_service_memory_project_array emit a
// memory targeting list as a JSON string array (empty list = applies to all).
write_service_memory_id_array :: proc(b: ^strings.Builder, values: []string) {
	strings.write_byte(b, '[')
	for v, i in values {
		if i > 0 do strings.write_byte(b, ',')
		strings.write_byte(b, '"'); write_service_json_string(b, v); strings.write_byte(b, '"')
	}
	strings.write_byte(b, ']')
}
write_service_memory_project_array :: proc(b: ^strings.Builder, values: []domain.Project_ID) {
	strings.write_byte(b, '[')
	for v, i in values {
		if i > 0 do strings.write_byte(b, ',')
		strings.write_byte(b, '"'); write_service_json_string(b, string(v)); strings.write_byte(b, '"')
	}
	strings.write_byte(b, ']')
}

write_bootstrap_memory_markdown :: proc(b: ^strings.Builder, service: ^Agent_Service, owner: domain.User_ID, inst: domain.Agent_Instance) {
	if service == nil || service.content == nil do return
	memories, err := iface.content_list_memories(service.content, owner)
	if err.code != .None do return
	written := 0
	for m in memories {
		if !bootstrap_memory_applies(m, service, owner, inst) do continue
		// Only fact and habit memories belong inline in AGENTS.md. Skill
		// memories are materialized as separate SKILL.md files and must not be
		// duplicated here (that just pollutes the bootstrap doc). Other types
		// (episode/expertise) are intentionally excluded from the inline doc.
		if m.type != .Fact && m.type != .Habit do continue
		if written == 0 do strings.write_string(b, "\\n\\n## Applicable Memories")
		strings.write_string(b, "\\n\\n### "); write_service_json_string(b, m.title)
		strings.write_string(b, "\\nType: "); write_service_json_string(b, domain.memory_type_string(m.type))
		strings.write_string(b, "\\n\\n"); write_bootstrap_markdown_json_string(b, m.body)
		written += 1
	}
}

write_bootstrap_markdown_json_string :: proc(b: ^strings.Builder, value: string) {
	text := value
	if strings.index(text, "\\n") >= 0 {
		replaced, _ := strings.replace_all(text, "\\n", "\n")
		text = replaced
	}
	write_service_json_string(b, text)
}

// bootstrap_memory_applies decides whether an active memory targets a specific
// instance. Each targeting dimension is a LIST: an empty list matches all; a
// non-empty list matches only when the instance's value is a member. The
// dimensions are ANDed, so every non-empty list must match.
bootstrap_memory_applies :: proc(m: domain.Memory, service: ^Agent_Service, owner: domain.User_ID, inst: domain.Agent_Instance) -> bool {
	if m.status != "active" do return false
	if !memory_list_matches(m.agent_ids, inst.agent_id) do return false
	if !memory_project_list_matches(m.project_ids, inst.project_id) do return false
	if len(m.template_ids) > 0 {
		if service == nil || service.agents == nil || strings.trim_space(inst.agent_id) == "" do return false
		agent, ok, _ := iface.agent_get(service.agents, inst.agent_id)
		if !ok || agent.owner_user_id != owner || !memory_list_contains(m.template_ids, agent.template_id) do return false
	}
	if !memory_list_matches(m.bridge_ids, inst.bridge_id) do return false
	return true
}

// memory_list_matches reports whether a targeting list applies to value: an
// empty list applies to all; otherwise value must be a member.
memory_list_matches :: proc(list: []string, value: string) -> bool {
	if len(list) == 0 do return true
	return memory_list_contains(list, value)
}
memory_list_contains :: proc(list: []string, value: string) -> bool {
	for v in list do if v == value do return true
	return false
}
memory_project_list_matches :: proc(list: []domain.Project_ID, value: domain.Project_ID) -> bool {
	if len(list) == 0 do return true
	for v in list do if v == value do return true
	return false
}

write_bootstrap_task_context :: proc(b: ^strings.Builder, service: ^Agent_Service, inst: domain.Agent_Instance, chain: domain.Task_Chain, chain_ok: bool) {
	// Task System v2: the current task is whatever lease the instance holds
	// (the lease verbs keep agent_instances.current_task_id in sync); the
	// runnable frontier is the chain's READY tasks (the matcher decides who gets
	// them — the agent never picks).
	strings.write_string(b, "{\"current_task\":")
	current_written := false
	if service.taskchains != nil && chain_ok {
		tasks, err := iface.taskchain_list_tasks_by_chain(service.taskchains, chain.chain_id, chain.owner_user_id)
		if err.code == .None {
			// CT-8: the current task is the SERVER-AUTHORITATIVE persisted pointer
			// on the instance (set by the auto-promotion engine), not a transient
			// client-side inference. Resolve the concrete task and surface its role
			// (work vs review) so the bootstrap doc is a single source of truth. Fall
			// back to null when the pointer is unset or the task is no longer present.
			if inst.current_task_id != "" {
				for task in tasks {
					if string(task.task_id) == inst.current_task_id {
						write_bootstrap_current_task_json(b, task, inst.current_task_role)
						current_written = true
						break
					}
				}
			}
			if !current_written do strings.write_string(b, "null")
			strings.write_string(b, ",\"runnable_frontier\":[")
			written := 0
			for task in tasks {
				if task.publish_state != .Published || task.state != .Ready do continue
				if written > 0 do strings.write_string(b, ",")
				write_bootstrap_task_json(b, task)
				written += 1
				if written >= 10 do break
			}
			strings.write_string(b, "]}")
			return
		}
	}
	if !current_written do strings.write_string(b, "null")
	strings.write_string(b, ",\"runnable_frontier\":[]}")
}

// write_bootstrap_current_task_json serializes the persisted current task with its
// role (work|review) and priority so the agent's bootstrap doc states, without
// ambiguity, whether the agent should WORK or REVIEW the task (R8/CT-8).
write_bootstrap_current_task_json :: proc(b: ^strings.Builder, task: domain.Task, role: domain.Current_Task_Role) {
	strings.write_string(b, "{\"task_id\":\""); write_service_json_string(b, string(task.task_id))
	strings.write_string(b, "\",\"title\":\""); write_service_json_string(b, task.title)
	strings.write_string(b, "\",\"state\":\""); write_service_json_string(b, domain.task_state_string(task.state))
	strings.write_string(b, "\",\"priority\":\""); write_service_json_string(b, domain.task_priority_string(task.priority))
	strings.write_string(b, "\",\"role\":\""); write_service_json_string(b, domain.current_task_role_string(role))
	strings.write_string(b, "\"}")
}

write_bootstrap_task_json :: proc(b: ^strings.Builder, task: domain.Task) {
	strings.write_string(b, "{\"task_id\":\""); write_service_json_string(b, string(task.task_id))
	strings.write_string(b, "\",\"title\":\""); write_service_json_string(b, task.title)
	strings.write_string(b, "\",\"state\":\""); write_service_json_string(b, domain.task_state_string(task.state))
	strings.write_string(b, "\"}")
}

write_bootstrap_messages :: proc(b: ^strings.Builder, service: ^Agent_Service, inst: domain.Agent_Instance) {
	if service.content == nil || inst.conversation_id == "" do return
	messages, err := iface.content_list_messages(service.content, inst.conversation_id, inst.owner_user_id, 20, "")
	if err.code != .None do return
	for m, i in messages {
		if i > 0 do strings.write_string(b, ",")
		strings.write_string(b, "{\"message_id\":\""); write_service_json_string(b, m.message_id)
		strings.write_string(b, "\",\"direction\":\""); write_service_json_string(b, m.direction)
		strings.write_string(b, "\",\"body\":\""); write_service_json_string(b, m.body)
		strings.write_string(b, "\",\"created_at\":\""); write_service_json_string(b, m.created_at)
		strings.write_string(b, "\"}")
	}
}

stop_instance :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id: string, input: Stop_Instance_Input) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	sync.lock(&service.reconfiguration_mutex)
	defer sync.unlock(&service.reconfiguration_mutex)
	if input.force {
		if inst, handled, err := force_stop_instance_reconfiguration_locked(service, auth, instance_id); handled do return inst, err.code == .None, err
	}
	if idle, err := reconfiguration_require_idle(service, instance_id); !idle do return {}, false, err
	inst, ok, err := get_instance(service, auth, instance_id)
	if !ok do return domain.Agent_Instance{}, false, err
	if !project_service.bridge_runtime_registry_has_live(service.bridge_runtime_registry, inst.bridge_id) do return domain.Agent_Instance{}, false, domain.domain_error(.Bridge_Offline, "bridge is offline")
	reason := input.reason; if reason == "" do reason = "user_requested"
	// F4: a user stop sticks. Persist it first (the matcher reads stopped_by),
	// then let the engine release the lease and re-plan, then send the stop.
	if strings.has_prefix(reason, "user") && inst.stopped_by != STOPPED_BY_USER {
		inst.stopped_by = STOPPED_BY_USER
		inst.updated_at = platform.clock_now(service.clock)
		saved, sok, serr := iface.agent_save_instance(service.agents, inst)
		if !sok do return domain.Agent_Instance{}, false, serr
		inst = saved
	}
	if strings.has_prefix(reason, "user") && service.hooks.on_user_stopped != nil {
		service.hooks.on_user_stopped(service.hooks.ctx, inst.agent_instance_id)
		if fresh, fok, _ := iface.agent_get_instance(service.agents, inst.agent_instance_id); fok do inst = fresh
	}
	command_id := strings.concatenate({platform.generate_id(service.ids, "cmd_stop_"), "_", inst.agent_instance_id})
	command := project_service.Runtime_Command{bridge_id = inst.bridge_id, command_id = command_id, body_json = stop_command_json(command_id, inst.agent_instance_id, reason, force = input.force)}
	if sent, send_err := project_service.bridge_command_send_runtime(service.bridge_command_sink, command); !sent do return domain.Agent_Instance{}, false, send_err
	inst.runtime_status = "stopping"
	inst.updated_at = platform.clock_now(service.clock)
	return iface.agent_save_instance(service.agents, inst)
}

restart_instance :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	if idle, err := reconfiguration_require_idle(service, instance_id); !idle do return {}, false, err
	inst, ok, err := get_instance(service, auth, instance_id)
	if !ok do return domain.Agent_Instance{}, false, err
	inst = clear_user_stop(service, inst)
	return relaunch_instance(service, auth, inst, inst.provider, inst.model)
}

// clear_user_stop: an explicit user start/restart makes the instance eligible
// for task leases again (F4).
clear_user_stop :: proc(service: ^Agent_Service, inst: domain.Agent_Instance) -> domain.Agent_Instance {
	if inst.stopped_by == "" do return inst
	next := inst
	next.stopped_by = ""
	next.updated_at = platform.clock_now(service.clock)
	if saved, sok, _ := iface.agent_save_instance(service.agents, next); sok do return saved
	return inst
}

// start_instance starts a STOPPED instance. Unlike restart (absolute
// stop-then-start), start refuses an instance that is already live so the agent
// gets a clear "already_running" (409/Conflict) instead of silently re-spawning.
// The machine-readable code rides in details_json so ham-ctl can branch on it.
start_instance :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	inst, ok, err := get_instance(service, auth, instance_id)
	if !ok do return domain.Agent_Instance{}, false, err
	if runtime_expected_active(inst.runtime_status) {
		msg := strings.concatenate({"instance ", inst.agent_instance_id, " is already running (runtime_status=", inst.runtime_status, ")"})
		details := strings.concatenate({"{\"code\":\"already_running\",\"runtime_status\":\"", inst.runtime_status, "\"}"})
		return domain.Agent_Instance{}, false, domain.domain_error(.Conflict, msg, details)
	}
	inst = clear_user_stop(service, inst)
	return relaunch_instance(service, auth, inst, inst.provider, inst.model)
}

get_instance_pane :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id: string, since_hash: string, width, line_limit: int) -> (string, bool, domain.Domain_Error) {
	inst, ok, err := get_instance(service, auth, instance_id)
	if !ok do return "", false, err

	if inst.runtime_status == "stopped" || inst.runtime_status == "failed" {
		b := strings.builder_make()
		strings.write_string(&b, "{\"ok\":true,\"status\":\"")
		write_service_json_string(&b, inst.runtime_status)
		strings.write_string(&b, "\",\"unchanged\":true,\"hash\":\"\",\"output\":\"\"}")
		return strings.to_string(b), true, domain.Domain_Error{}
	}

	if strings.trim_space(inst.bridge_id) == "" {
		return "", false, domain.domain_error(.Bridge_Offline, "agent instance has no bridge")
	}

	cmd_id := ""
	if service.ids != nil {
		cmd_id = platform.generate_id(service.ids, "cmd_")
	}

	cmd_b := strings.builder_make()
	strings.write_string(&cmd_b, "{\"type\":\"get_agent_pane\",\"command_id\":\"")
	write_service_json_string(&cmd_b, cmd_id)
	strings.write_string(&cmd_b, "\",\"agent_instance_id\":\"")
	write_service_json_string(&cmd_b, instance_id)
	strings.write_string(&cmd_b, "\",\"since_hash\":\"")
	write_service_json_string(&cmd_b, since_hash)
	strings.write_string(&cmd_b, "\",\"width\":")
	strings.write_int(&cmd_b, width)
	strings.write_string(&cmd_b, ",\"line_limit\":")
	strings.write_int(&cmd_b, line_limit)
	strings.write_string(&cmd_b, "}")

	reply, reply_ok, reply_err := project_service.bridge_command_send_runtime_wait(
		service.bridge_command_sink,
		project_service.Runtime_Command{
			bridge_id = inst.bridge_id,
			command_id = cmd_id,
			body_json = strings.to_string(cmd_b),
		},
		5000,
	)
	if !reply_ok {
		return "", false, reply_err
	}

	return reply, true, domain.Domain_Error{}
}

// REQ-PANE-INPUT-1/2: `enc_b64` carries vault ciphertext straight through to the bridge,
// which owns the vault key and decrypts it in bridge_hub_handle_shell_pty_input
// (src/bridge/hub_runtime_client.odin:1327-1395). The Hub never decrypts keystrokes — it
// holds only an encrypted vault key — so this is a relay, not a plaintext hop.
// Mirror of bridge_service.shell_pty_input_command_json (src/hub/service/bridge/bridge_service.odin:391):
// both panes emit the same `shell_pty_input` wire shape and must stay in step.
agent_pty_input_command_json :: proc(command_id, instance_id, data: string, enc_b64: string = "") -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_pty_input\",\"command_id\":\"")
	write_service_json_string(&b, command_id)
	strings.write_string(&b, "\",\"shell_id\":\"")
	write_service_json_string(&b, instance_id)
	strings.write_string(&b, "\",\"data_b64\":\"")
	payload := enc_b64
	if payload == "" { payload = string(base64.encode(transmute([]byte)data, allocator = context.temp_allocator)) }
	// An armored v2 token is re-framed to the PTY v2 binary layout (u32be epoch |
	// salt16 | nonce | tag | ct) so the bridge sees the epoch it must check; a non-armored
	// enc_b64 is already base64 of that layout and passes through untouched.
	if domain.is_vault_armored(payload) {
		if framed, ok := domain.vault_pty_v2_payload_from_armor(payload, context.temp_allocator); ok {
			payload = string(base64.encode(framed, allocator = context.temp_allocator))
		} else {
			payload = ""
		}
	}
	write_service_json_string(&b, payload)
	strings.write_string(&b, "\",\"is_encrypted\":")
	strings.write_string(&b, "true" if enc_b64 != "" else "false")
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

shell_pty_input_command_json :: agent_pty_input_command_json

// agent_service_send_pty_input forwards keystrokes to the instance's bridge. `data` is
// plaintext and `enc_b64` is vault ciphertext; exactly one of them is normally set — see
// agent_pty_input_command_json above for why the ciphertext is relayed rather than decrypted.
//
// wait_for_result (REST callers, T10 REQ-T10-2) waits for the bridge's command_result so a
// `vault_locked` refusal returns as a typed error; the pane WebSocket stays fire-and-forget
// and is told by the bridge's in-stream `shell_pty_vault_locked` frame instead.
agent_service_send_pty_input :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id: string, data: string, enc_b64: string = "", wait_for_result := false) -> (bool, domain.Domain_Error) {
	inst, ok, err := get_instance(service, auth, instance_id)
	if !ok do return false, err

	if strings.trim_space(inst.bridge_id) == "" {
		return false, domain.domain_error(.Bridge_Offline, "agent instance has no bridge")
	}

	cmd_id := ""
	if service.ids != nil {
		cmd_id = platform.generate_id(service.ids, "cmd_input_")
	}

	cmd_json := agent_pty_input_command_json(cmd_id, instance_id, data, enc_b64)
	defer delete(cmd_json)
	command := project_service.Runtime_Command{
		bridge_id = inst.bridge_id,
		command_id = cmd_id,
		body_json = cmd_json,
	}
	sent, send_err := project_service.bridge_command_send_runtime_checked(service.bridge_command_sink, command, wait_for_result)
	if !sent do return false, send_err

	return true, domain.Domain_Error{}
}

send_pty_input :: agent_service_send_pty_input

// agent_service_send_pty_input_binary is the pane-WebSocket form: one binary pty_wire
// INPUT frame, no command_id, no ack (REQ-PTY-NET-3). Twin of
// bridge_service.send_shell_input_binary; the bridge keys both on shell_id.
agent_service_send_pty_input_binary :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id: string, payload: []byte, encrypted: bool) -> (bool, domain.Domain_Error) {
	inst, ok, err := get_instance(service, auth, instance_id)
	if !ok do return false, err
	if strings.trim_space(inst.bridge_id) == "" {
		return false, domain.domain_error(.Bridge_Offline, "agent instance has no bridge")
	}
	if len(payload) == 0 do return true, domain.Domain_Error{}
	frame := contracts.pty_wire_encode_session_frame(contracts.PTY_WIRE_KIND_INPUT, contracts.pty_wire_flags(false, encrypted), instance_id, payload, context.temp_allocator)
	if frame == nil do return false, domain.domain_error(.Validation_Failed, "instance id too long for a pty frame")
	return project_service.bridge_command_send_runtime_binary(service.bridge_command_sink, inst.bridge_id, frame)
}

agent_pty_resize_command_json :: proc(command_id, instance_id: string, rows, cols: int) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_pty_resize\",\"command_id\":\"")
	write_service_json_string(&b, command_id)
	strings.write_string(&b, "\",\"shell_id\":\"")
	write_service_json_string(&b, instance_id)
	strings.write_string(&b, "\",\"agent_instance_id\":\"")
	write_service_json_string(&b, instance_id)
	strings.write_string(&b, "\",\"rows\":")
	strings.write_int(&b, rows)
	strings.write_string(&b, ",\"cols\":")
	strings.write_int(&b, cols)
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

shell_pty_resize_command_json :: agent_pty_resize_command_json

agent_service_send_pty_resize :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id: string, rows, cols: int) -> (bool, domain.Domain_Error) {
	inst, ok, err := get_instance(service, auth, instance_id)
	if !ok do return false, err

	if strings.trim_space(inst.bridge_id) == "" {
		return false, domain.domain_error(.Bridge_Offline, "agent instance has no bridge")
	}

	cmd_id := ""
	if service.ids != nil {
		cmd_id = platform.generate_id(service.ids, "cmd_resize_")
	}

	cmd_json := agent_pty_resize_command_json(cmd_id, instance_id, rows, cols)
	sent, send_err := project_service.bridge_command_send_runtime(
		service.bridge_command_sink,
		project_service.Runtime_Command{
			bridge_id = inst.bridge_id,
			command_id = cmd_id,
			body_json = cmd_json,
		},
	)
	if !sent do return false, send_err

	return true, domain.Domain_Error{}
}

send_pty_resize :: agent_service_send_pty_resize

reconfigure_instance :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id: string, input: Reconfigure_Instance_Input) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	sync.lock(&service.reconfiguration_mutex)
	defer sync.unlock(&service.reconfiguration_mutex)
	if idle, err := reconfiguration_require_idle(service, instance_id); !idle do return {}, false, err
	inst, ok, err := get_instance(service, auth, instance_id)
	if !ok do return domain.Agent_Instance{}, false, err
	if input.has_agent_id || input.has_bridge_id || input.has_project_id || input.has_chain_id || input.has_conversation_id do return domain.Agent_Instance{}, false, domain.domain_error(.Conflict, "agent_id, bridge_id, project_id, chain_id, and conversation_id are immutable for an instance; changing them requires a new instance")
	provider := input.provider; if provider == "" do provider = inst.provider
	model := input.model; if model == "" do model = inst.model
	resolved, resolved_ok, resolved_err := validate_pinned_provider_model(service, auth, inst, provider, model)
	if !resolved_ok do return domain.Agent_Instance{}, false, resolved_err
	inst.provider = resolved.provider
	inst.model = resolved.model
	if input.has_display_name do inst.display_name = input.display_name
	if runtime_expected_active(inst.runtime_status) do return relaunch_instance_locked(service, auth, inst, resolved.provider, resolved.model)
	inst.updated_at = platform.clock_now(service.clock)
	return iface.agent_save_instance(service.agents, inst)
}

relaunch_instance :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, inst: domain.Agent_Instance, provider, model: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	sync.lock(&service.reconfiguration_mutex)
	defer sync.unlock(&service.reconfiguration_mutex)
	return relaunch_instance_locked(service, auth, inst, provider, model)
}

relaunch_instance_locked :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, inst: domain.Agent_Instance, provider, model: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	if idle, err := reconfiguration_require_idle(service, inst.agent_instance_id); !idle do return {}, false, err
	current, found, read_err := iface.agent_get_instance(service.agents, inst.agent_instance_id)
	if !found do return {}, false, read_err
	defer domain.agent_instance_destroy(&current)
	if current.configuration_revision != inst.configuration_revision || current.launch_epoch != inst.launch_epoch || current.bridge_id != inst.bridge_id do return {}, false, domain.domain_error(.Conflict, "instance configuration changed before runtime action")
	_, auth_ok, auth_err := validate_pinned_provider_model(service, auth, inst, provider, model)
	if !auth_ok do return domain.Agent_Instance{}, false, auth_err
	bridge, bridge_ok, bridge_err := iface.bridge_get_bridge(service.bridges, inst.bridge_id)
	if !bridge_ok do return domain.Agent_Instance{}, false, bridge_err
	if bridge.owner_user_id != inst.owner_user_id do return domain.Agent_Instance{}, false, domain.domain_error(.Not_Found, "bridge not found")
	if plan_err := require_launch_bridge_enabled(service, bridge); plan_err.code != .None do return {}, false, plan_err
	if bridge.status != .Online || !project_service.bridge_runtime_registry_has_live(service.bridge_runtime_registry, inst.bridge_id) do return domain.Agent_Instance{}, false, domain.domain_error(.Bridge_Offline, "pinned bridge is offline")
	now := platform.clock_now(service.clock)
	next := inst
	next.provider = provider
	next.model = model
	next.runtime_status = "launching"
	next.startup_status = "starting"
	next.activity_status = "unknown"
	next.run_count += 1
	next.started_at = now
	next.stopped_at = ""
	next.updated_at = now
	next.last_seen_at = now
	generation, admitted, quota_err := reserve_runtime_launch(service, next)
	if !admitted do return {}, false, quota_err
	launch_sent := false
	defer if !launch_sent do project_service.bridge_runtime_instance_cancel_reservation(service.bridge_runtime_registry, next.bridge_id, generation, next.agent_instance_id)
	command_id := strings.concatenate({platform.generate_id(service.ids, "cmd_launch_"), "_", next.agent_instance_id})
	command := project_service.Runtime_Command{bridge_id = next.bridge_id, command_id = command_id, body_json = launch_command_json_full(service, command_id, next)}
	if sent, send_err := project_service.bridge_command_send_runtime(service.bridge_command_sink, command); !sent do return domain.Agent_Instance{}, false, send_err
	launch_sent = true
	return iface.agent_save_instance(service.agents, next)
}

// error_json is the report's wire error object (REQ-ERR-PROTO-A), recorded as the
// instance's last_error (with a consecutive-failure attempt count) while it is
// failed; a successful start or a stop clears it, a retry in flight keeps it.
// facts: when non-nil the lifecycle hook is NOT called; the fact is appended
// for the caller to deliver after it releases its locks (review B1).
apply_bridge_status_report :: proc(service: ^Agent_Service, bridge_id, instance_id: string, state_seq: int, runtime_status, activity_status: string, owner_user_id: string = "", launch_epoch: string = "", error_json: string = "", facts: ^[dynamic]Lifecycle_Fact = nil) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	inst, ok, err := iface.agent_get_instance(service.agents, instance_id)
	if !ok do return domain.Agent_Instance{}, false, err
	if inst.bridge_id != bridge_id || (owner_user_id != "" && string(inst.owner_user_id) != owner_user_id) {
		domain.agent_instance_destroy(&inst)
		return domain.Agent_Instance{}, false, domain.domain_error(.Not_Found, "agent instance not found on bridge")
	}
	if inst.launch_epoch != launch_epoch {
		domain.agent_instance_destroy(&inst)
		return {}, false, domain.domain_error(.Conflict, "superseded launch status report")
	}
	effective_state_seq := state_seq
	if effective_state_seq <= inst.last_applied_seq {
		// Bridge runtime state is in-memory and can restart while ham-wrapper
		// processes keep running. A wrapper reconnect/liveness report with a reset
		// bridge-local seq is authoritative for recovery from non-live Hub states.
		if runtime_expected_active(runtime_status) && (inst.runtime_status == "unreachable" || inst.runtime_status == "launching" || inst.runtime_status == "starting") {
			effective_state_seq = inst.last_applied_seq + 1
		} else if runtime_expected_active(runtime_status) && runtime_expected_active(inst.runtime_status) {
			// Heartbeat/liveness update for an active instance: refresh last_seen_at
			// even if state_seq didn't advance, so idle agents are not falsely reaped.
			now := platform.clock_now(service.clock)
			if len(inst.last_seen_at) > 0 do delete(inst.last_seen_at)
			inst.last_seen_at = strings.clone(now)
			if len(inst.updated_at) > 0 do delete(inst.updated_at)
			inst.updated_at = strings.clone(now)
			if activity_status != "" && activity_status != inst.activity_status {
				if len(inst.activity_status) > 0 do delete(inst.activity_status)
				inst.activity_status = strings.clone(activity_status)
			}
			saved, saved_ok, save_err := iface.agent_save_instance(service.agents, inst)
			if saved_ok do emit_fact(service, facts, Lifecycle_Fact{instance_id = instance_id, activity = activity_status})
			return saved, saved_ok, save_err
		} else {
			domain.agent_instance_destroy(&inst)
			return domain.Agent_Instance{}, false, domain.Domain_Error{}
		}
	}
	now := platform.clock_now(service.clock)
	inst.last_applied_seq = effective_state_seq
	if runtime_status != "" {
		if len(inst.runtime_status) > 0 do delete(inst.runtime_status)
		inst.runtime_status = strings.clone(runtime_status)
	}
	if activity_status != "" {
		if len(inst.activity_status) > 0 do delete(inst.activity_status)
		inst.activity_status = strings.clone(activity_status)
	}
	if len(inst.last_seen_at) > 0 do delete(inst.last_seen_at)
	inst.last_seen_at = strings.clone(now)
	if len(inst.updated_at) > 0 do delete(inst.updated_at)
	inst.updated_at = strings.clone(now)
	switch inst.runtime_status {
	case "failed":
		if error_json != "" {
			recorded := instance_last_error_record(inst.last_error_json, error_json)
			if len(inst.last_error_json) > 0 do delete(inst.last_error_json)
			inst.last_error_json = recorded
		}
	case "launching", "starting":
		// A retry in flight keeps the failure (and its attempt count) until it succeeds.
	case:
		if len(inst.last_error_json) > 0 do delete(inst.last_error_json)
		inst.last_error_json = ""
	}
	switch inst.runtime_status {
	case "running", "idle", "busy":
		if len(inst.startup_status) > 0 do delete(inst.startup_status)
		inst.startup_status = strings.clone("ready")
	case "launching", "starting":
		if len(inst.startup_status) > 0 do delete(inst.startup_status)
		inst.startup_status = strings.clone("starting")
	case "blocked":
		if len(inst.startup_status) > 0 do delete(inst.startup_status)
		inst.startup_status = strings.clone("startup_blocked")
	case "failed":
		if len(inst.startup_status) > 0 do delete(inst.startup_status)
		inst.startup_status = strings.clone("startup_failed")
		if len(inst.stopped_at) > 0 do delete(inst.stopped_at)
		inst.stopped_at = strings.clone(now)
		clear_instance_current_task(&inst)
	case "stopped", "unreachable":
		if len(inst.startup_status) > 0 do delete(inst.startup_status)
		inst.startup_status = strings.clone("stopped")
		if len(inst.stopped_at) > 0 do delete(inst.stopped_at)
		inst.stopped_at = strings.clone(now)
		clear_instance_current_task(&inst)
	}
	saved, saved_ok, save_err := iface.agent_save_instance(service.agents, inst)
	if saved_ok {
		emit_fact(service, facts, Lifecycle_Fact{instance_id = instance_id, terminal = instance_runtime_is_terminal(saved.runtime_status), activity = activity_status})
	}
	return saved, saved_ok, save_err
}

@(private = "file")
emit_fact :: proc(service: ^Agent_Service, facts: ^[dynamic]Lifecycle_Fact, f: Lifecycle_Fact) {
	if facts != nil {
		append(facts, Lifecycle_Fact{instance_id = strings.clone(f.instance_id), terminal = f.terminal, activity = strings.clone(f.activity)})
		return
	}
	if f.terminal do notify_instance_terminal(service, f.instance_id)
	else do notify_instance_activity(service, f.instance_id, f.activity)
}

lifecycle_facts_destroy :: proc(facts: ^[dynamic]Lifecycle_Fact) {
	for f in facts { delete(f.instance_id); delete(f.activity) }
	delete(facts^)
}

// reconcile_bridge_heartbeat marks instances the bridge no longer reports active
// as unreachable, and refreshes last_seen_at for the ones it does.
//
// Returns the instances it marked unreachable, so callers can fan out on each one
// rather than only learning how many changed. That is what the other two
// liveness paths (mark_bridge_instances_unreachable, reap_stale_instances) already
// do, and REQ-SHELL-2 §9 needs the identities: this is the only SINGLE-INSTANCE
// unreachability signal in the hub — the bridge is still connected and reporting,
// and just this one instance has gone — so it is the most precise trigger for the
// foreground-run liveness rule. The caller owns the returned slice.
reconcile_bridge_heartbeat :: proc(service: ^Agent_Service, bridge_id: string, active_instance_ids: []string) -> []domain.Agent_Instance {
	instances, err := iface.agent_list_instances_by_bridge(service.agents, bridge_id)
	if err.code != .None do return nil
	// NO BLANKET `defer agent_instances_destroy(instances)` HERE. The elements this
	// proc RETURNS must outlive it, and a deferred destroy frees every element on the
	// way out — handing the caller freed strings, which it then frees again. Ownership
	// is therefore per element: an instance that escapes into `changed` is the
	// CALLER'S to destroy, every other one is destroyed here, and only the backing
	// slice is deleted at the end.
	//
	// This mirrors mark_bridge_instances_unreachable and reap_stale_instances exactly,
	// which is deliberate: all three return instances to a caller that destroys them,
	// so a third ownership pattern here would be a third thing to get wrong.
	changed := make([dynamic]domain.Agent_Instance)
	now := platform.clock_now(service.clock)
	for i in 0..<len(instances) {
		inst := instances[i]
		reported_active := string_slice_contains(active_instance_ids, inst.agent_instance_id)
		if runtime_expected_active(inst.runtime_status) && !reported_active {
			// Mutated IN PLACE rather than through a copy, and every overwritten field
			// is freed then CLONED. A shallow copy would alias inst's strings, so the
			// copy could not escape while inst was destroyed; and assigning a literal
			// ("unreachable") or aliasing `now` would hand the caller static storage and
			// one shared pointer to free once per instance.
			//
			// apply_runtime_startup_projection is deliberately NOT used on this path for
			// the same reason — it assigns literals and aliases `now`, which is correct
			// only for a struct that stays local. runtime_status is always "unreachable"
			// here, so the projection's branch for it is inlined verbatim: startup_status
			// "stopped", stopped_at now, and the current-task pointer cleared.
			if len(inst.runtime_status) > 0 do delete(inst.runtime_status)
			inst.runtime_status = strings.clone("unreachable")
			if len(inst.updated_at) > 0 do delete(inst.updated_at)
			inst.updated_at = strings.clone(now)
			if len(inst.startup_status) > 0 do delete(inst.startup_status)
			inst.startup_status = strings.clone("stopped")
			if len(inst.stopped_at) > 0 do delete(inst.stopped_at)
			inst.stopped_at = strings.clone(now)
			clear_instance_current_task(&inst)
			saved, ok, _ := iface.agent_save_instance(service.agents, inst)
			if ok {
				// Escapes to the caller, which owns it from here. NOT destroyed below.
				append(&changed, saved)
			} else {
				domain.agent_instance_destroy(&inst)
			}
			continue
		}
		if reported_active {
			// The heartbeat's active_instance_ids IS the liveness proof for a running
			// instance: refresh last_seen_at so the stale reaper (reap_stale_instances,
			// which checks last_seen_at age) does not falsely mark a steady-state
			// running agent "unreachable" between status-change pushes. Without this,
			// a running-but-idle agent's last_seen_at only advanced on a status change,
			// so after BRIDGE_INSTANCE_STALE_MS it was reaped despite every heartbeat
			// reporting it active.
			//
			// `to_save` is a local copy that does NOT escape, so aliasing `now` is fine
			// and nothing is cloned: the repository copies into the DB and returns the
			// input, and `inst` below still owns its original strings.
			if inst.last_seen_at != now {
				to_save := inst
				to_save.last_seen_at = now
				_, _, _ = iface.agent_save_instance(service.agents, to_save)
			}
		}
		// Did not escape: this proc owns it.
		domain.agent_instance_destroy(&inst)
	}
	// The backing slice only — its elements have each been destroyed above or handed
	// to the caller.
	delete(instances)
	if len(changed) == 0 {
		delete(changed)
		return nil
	}
	return changed[:]
}

// detect_superseded_instances is the H7 cross-bridge reap detector. Given the
// instance ids a bridge just reported as active, it returns those whose CANONICAL
// bridge_id (per the hub's durable record) is now a DIFFERENT bridge — i.e. the
// instance was relaunched/moved to another bridge, so the reporting bridge is
// running a superseded old runtime. The caller (bridge WS handler) sends each id
// back to the reporting bridge in the heartbeat ack, and the bridge invalidates
// that instance's local tokens so the old ham-wrapper self-terminates on its next
// liveness ping. This is the authoritative cross-bridge coordination the user
// specified: the hub tracks running instance ids across bridges and tells a
// bridge when one of its instances is supposed to be running elsewhere.
detect_superseded_instances :: proc(service: ^Agent_Service, reporting_bridge_id: string, active_instance_ids: []string) -> []string {
	if service == nil || service.agents == nil || strings.trim_space(reporting_bridge_id) == "" do return nil
	out := make([dynamic]string)
	for id in active_instance_ids {
		inst, ok, _ := iface.agent_get_instance(service.agents, id)
		if !ok do continue
		if strings.trim_space(inst.bridge_id) != "" && inst.bridge_id != reporting_bridge_id {
			append(&out, strings.clone(id))
		}
		domain.agent_instance_destroy(&inst)
	}
	return out[:]
}

// mark_bridge_instances_unreachable clears the durable runtime state of every
// still-active instance on a bridge that just disconnected. The bridge runtime
// registry is in-memory only, so when a bridge WS drops (crash/restart/quit)
// nothing else transitions its instances out of "running" — reconcile_bridge_heartbeat
// needs a live heartbeat, which a gone bridge can never send. Returns the affected
// instances so the caller can fan out resource_changed and the UI clears them.
mark_bridge_instances_unreachable :: proc(service: ^Agent_Service, bridge_id: string) -> []domain.Agent_Instance {
	if service == nil || service.agents == nil || strings.trim_space(bridge_id) == "" do return nil
	instances, err := iface.agent_list_instances_by_bridge(service.agents, bridge_id)
	if err.code != .None do return nil
	now := platform.clock_now(service.clock)
	changed := make([dynamic]domain.Agent_Instance)
	for i in 0..<len(instances) {
		inst := instances[i]
		if !runtime_expected_active(inst.runtime_status) {
			domain.agent_instance_destroy(&inst)
			continue
		}
		if len(inst.runtime_status) > 0 do delete(inst.runtime_status)
		inst.runtime_status = strings.clone("unreachable")
		if len(inst.activity_status) > 0 do delete(inst.activity_status)
		inst.activity_status = strings.clone("idle")
		if len(inst.updated_at) > 0 do delete(inst.updated_at)
		inst.updated_at = strings.clone(now)
		if len(inst.startup_status) > 0 do delete(inst.startup_status)
		inst.startup_status = strings.clone("stopped")
		if len(inst.stopped_at) > 0 do delete(inst.stopped_at)
		inst.stopped_at = strings.clone(now)
		clear_instance_current_task(&inst)
		saved, ok, _ := iface.agent_save_instance(service.agents, inst)
		if ok {
			append(&changed, saved)
		} else {
			domain.agent_instance_destroy(&inst)
		}
	}
	delete(instances)
	if len(changed) == 0 {
		delete(changed)
		return nil
	}
	return changed[:]
}

// reap_stale_instances is a time-based safety net: any instance still in an
// active runtime state whose last_seen_at is older than stale_after_ms is marked
// unreachable. This catches states that survived a disconnect the hub never
// observed (e.g. hub restart with a persisted DB, or a lost WS close), so the UI
// self-heals without requiring a fresh bridge event. Returns affected instances.
reap_stale_instances :: proc(service: ^Agent_Service, stale_after_ms: i64) -> []domain.Agent_Instance {
	if service == nil || service.agents == nil || stale_after_ms <= 0 do return nil
	now_str := platform.clock_now(service.clock)
	now_ms, now_ok := rfc3339_to_unix_ms(now_str)
	if !now_ok do return nil
	instances, err := iface.agent_list_active_runtime_instances(service.agents)
	if err.code != .None do return nil
	changed := make([dynamic]domain.Agent_Instance)
	for i in 0..<len(instances) {
		inst := instances[i]
		if !runtime_expected_active(inst.runtime_status) {
			domain.agent_instance_destroy(&inst)
			continue
		}
		seen_ms, seen_ok := rfc3339_to_unix_ms(inst.last_seen_at)
		if !seen_ok {
			domain.agent_instance_destroy(&inst)
			continue
		}
		if now_ms - seen_ms < stale_after_ms {
			domain.agent_instance_destroy(&inst)
			continue
		}
		if len(inst.runtime_status) > 0 do delete(inst.runtime_status)
		inst.runtime_status = strings.clone("unreachable")
		if len(inst.activity_status) > 0 do delete(inst.activity_status)
		inst.activity_status = strings.clone("idle")
		if len(inst.updated_at) > 0 do delete(inst.updated_at)
		inst.updated_at = strings.clone(now_str)
		if len(inst.startup_status) > 0 do delete(inst.startup_status)
		inst.startup_status = strings.clone("stopped")
		if len(inst.stopped_at) > 0 do delete(inst.stopped_at)
		inst.stopped_at = strings.clone(now_str)
		clear_instance_current_task(&inst)
		saved, ok, _ := iface.agent_save_instance(service.agents, inst)
		if ok {
			append(&changed, saved)
		} else {
			domain.agent_instance_destroy(&inst)
		}
	}
	delete(instances)
	if len(changed) == 0 {
		delete(changed)
		return nil
	}
	return changed[:]
}

// rfc3339_to_unix_ms parses the hub's canonical "YYYY-MM-DDTHH:MM:SSZ" UTC
// timestamps into unix milliseconds. Returns ok=false for empty/malformed input
// so callers skip rather than misclassify. Only the fixed hub format is handled.
//
// DELEGATES to platform.rfc3339_to_unix_ms (REQ-SHELL-9 boy-scout). The body used to
// live here, duplicated character-for-character in the content package, and a third
// copy was about to be written for the shell-session age reap. It now sits next to
// format_rfc3339_utc, the proc that produces the strings it reads. Kept as a named
// wrapper rather than deleted so this package's callers and tests are unaffected.
rfc3339_to_unix_ms :: proc(s: string) -> (i64, bool) {
	return platform.rfc3339_to_unix_ms(s)
}

// days_from_civil returns days since 1970-01-01 for a proleptic Gregorian date.
// Delegates for the same reason as above; the algorithm lives in platform.
days_from_civil :: proc(y_in, m, d: int) -> int {
	return platform.days_from_civil(y_in, m, d)
}

require_enabled_support :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, agent_id: string) -> (bool, domain.Domain_Error) {
	supports, err := list_support(service, auth, agent_id)
	if err.code != .None do return false, err
	for s in supports { if s.enabled do return true, domain.Domain_Error{} }
	return false, domain.domain_error(.Provider_Unavailable, "agent has no enabled bridge support")
}

update_private_chain_coordinator :: proc(service: ^Agent_Service, inst: domain.Agent_Instance) {
	if service.taskchains == nil || inst.chain_id == "" do return
	chain, ok, _ := iface.taskchain_get_chain(service.taskchains, domain.Task_Chain_ID(inst.chain_id))
	if !ok || chain.owner_user_id != inst.owner_user_id || chain.coordinator_agent_instance_id != "" do return
	chain.coordinator_agent_instance_id = inst.agent_instance_id
	chain.updated_at = inst.updated_at
	_, _, _ = iface.taskchain_save_chain(service.taskchains, chain)
}

resolve_instance_chain :: proc(service: ^Agent_Service, owner: domain.User_ID, chain_id: string, default_title: string) -> (string, bool, domain.Domain_Error) {
	if service.taskchains == nil do return "", false, domain.domain_error(.Internal_Error, "taskchain repository is not configured")
	if chain_id != "" {
		chain, ok, err := iface.taskchain_get_chain(service.taskchains, domain.Task_Chain_ID(chain_id))
		if !ok do return "", false, err
		if chain.owner_user_id != owner do return "", false, domain.domain_error(.Not_Found, "task chain not found")
		return string(chain.chain_id), true, domain.Domain_Error{}
	}
	now := platform.clock_now(service.clock)
	title := strings.trim_space(default_title); if title == "" do title = "Private conversation"
	chain := domain.Task_Chain{chain_id = domain.Task_Chain_ID(platform.generate_id(service.ids, "chain_")), owner_user_id = owner, title = title, publish_state = .Published, status = .Active, kind = domain.CHAIN_KIND_MIXED_WORK, last_activity_at = now, title_source = "default", created_at = now, updated_at = now, published_at = now}
	created, saved, save_err := iface.taskchain_save_chain(service.taskchains, chain)
	if !saved do return "", false, save_err
	return string(created.chain_id), true, domain.Domain_Error{}
}

ensure_instance_conversation :: proc(service: ^Agent_Service, inst: domain.Agent_Instance, default_title: string = "") -> (domain.Chat_Conversation, bool, domain.Domain_Error) {
	if service.content == nil do return domain.Chat_Conversation{}, false, domain.domain_error(.Internal_Error, "content repository is not configured")
	existing, list_err := iface.content_list_conversations(service.content, inst.owner_user_id, 512, "")
	if list_err.code != .None do return domain.Chat_Conversation{}, false, list_err
	for c in existing {
		if c.agent_instance_id == inst.agent_instance_id {
			if c.agent_id != inst.agent_id do return domain.Chat_Conversation{}, false, domain.domain_error(.Conflict, "conversation agent binding is inconsistent")
			if c.chain_id != inst.chain_id do return domain.Chat_Conversation{}, false, domain.domain_error(.Conflict, "conversation chain binding is inconsistent")
			if inst.conversation_id != "" && c.conversation_id != inst.conversation_id do return domain.Chat_Conversation{}, false, domain.domain_error(.Conflict, "conversation identity is inconsistent")
			return c, true, domain.Domain_Error{}
		}
	}
	now := platform.clock_now(service.clock)
	conv_id := inst.conversation_id; if conv_id == "" do conv_id = platform.generate_id(service.ids, "chat_")
	// Never emit a raw agt_ id as a title: prefer the supplied default title
	// ("<agent-name> #<n>"), falling back to the agent's display name.
	title := strings.trim_space(default_title)
	if title == "" do title = strings.trim_space(inst.display_name)
	if title == "" do title = agent_display_name_for_id(service, inst.owner_user_id, inst.agent_id)
	conv := domain.Chat_Conversation{conversation_id = conv_id, owner_user_id = inst.owner_user_id, agent_id = inst.agent_id, agent_instance_id = inst.agent_instance_id, project_id = inst.project_id, chain_id = inst.chain_id, title = title, last_activity_at = now, title_source = "default", created_at = now, updated_at = now}
	return iface.content_save_conversation(service.content, conv)
}

agent_display_name_for_id :: proc(service: ^Agent_Service, owner: domain.User_ID, agent_id: string) -> string {
	fallback := strings.trim_space(agent_id)
	if service != nil && service.agents != nil && strings.trim_space(agent_id) != "" {
		if agent, ok, _ := iface.agent_get(service.agents, agent_id); ok && agent.owner_user_id == owner {
			if name := strings.trim_space(agent.name); name != "" do return name
			if slug := strings.trim_space(agent.slug); slug != "" do return slug
		}
	}
	return fallback
}

// default_title_for_agent mints the per-agent global counter and returns a
// default per-run title of the form "<agent-name> #<n>". The agent name never
// falls back to a raw agt_ id; if the display name is empty it uses "Agent".
default_title_for_agent :: proc(service: ^Agent_Service, owner: domain.User_ID, agent: domain.Agent) -> string {
	name := strings.trim_space(agent.name)
	if name == "" do name = strings.trim_space(agent.slug)
	if name == "" do name = "Agent"
	now := platform.clock_now(service.clock)
	n, ok, _ := iface.agent_next_title_counter(service.agents, agent.agent_id, owner, now)
	if !ok || n <= 0 do return name
	return fmt.tprintf("%s #%d", name, n)
}

resolve_provider_model :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, agent_id, bridge_id: string, req: Run_Request) -> (domain.Resolved_Provider_Model, bool, domain.Domain_Error) {
	agent, ok, err := get_agent(service, auth, agent_id)
	if !ok do return domain.Resolved_Provider_Model{}, false, err
	support := default_support_for_agent_bridge(agent, bridge_id)
	if stored, stored_ok, _ := iface.agent_get_support(service.agents, agent_id, bridge_id); stored_ok {
		if stored.owner_user_id != agent.owner_user_id do return domain.Resolved_Provider_Model{}, false, domain.domain_error(.Not_Found, "support not found")
		support = stored
	}
	if !support.enabled do return {}, false, domain.domain_error(.Provider_Unavailable, "agent is disabled on bridge")
	return validate_provider_model_intersection(service, bridge_id, req.provider, req.model)
}

validate_pinned_provider_model :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, inst: domain.Agent_Instance, provider, model: string) -> (domain.Resolved_Provider_Model, bool, domain.Domain_Error) {
	agent, ok, err := get_agent(service, auth, inst.agent_id)
	if !ok do return domain.Resolved_Provider_Model{}, false, err
	if agent.owner_user_id != inst.owner_user_id do return domain.Resolved_Provider_Model{}, false, domain.domain_error(.Not_Found, "agent not found")
	support := default_support_for_agent_bridge(agent, inst.bridge_id)
	if stored, stored_ok, _ := iface.agent_get_support(service.agents, inst.agent_id, inst.bridge_id); stored_ok {
		if stored.owner_user_id != inst.owner_user_id do return domain.Resolved_Provider_Model{}, false, domain.domain_error(.Not_Found, "support not found")
		support = stored
	}
	if !support.enabled do return {}, false, domain.domain_error(.Provider_Unavailable, "agent is disabled on bridge")
	resolved_provider := provider if strings.trim_space(provider) != "" else inst.provider
	resolved_model := model if strings.trim_space(model) != "" else inst.model
	return validate_provider_model_intersection(service, inst.bridge_id, resolved_provider, resolved_model)
}

validate_provider_model_intersection :: proc(service: ^Agent_Service, bridge_id, provider, model: string) -> (domain.Resolved_Provider_Model, bool, domain.Domain_Error) {
	if strings.trim_space(provider) == "" || strings.trim_space(model) == "" do return {}, false, domain.domain_error(.Unprocessable_Entity, "provider and model are required")
	if service.providers == nil do return {}, false, domain.domain_error(.Internal_Error, "provider repository is not configured")
	entry, found, entry_err := iface.provider_catalog_get(service.providers, provider)
	if entry_err.code != .None do return {}, false, entry_err
	if !found || entry.state != "active" do return {}, false, domain.domain_error(.Unprocessable_Entity, "provider is unknown or deprecated")
	defer domain.provider_catalog_entry_destroy(entry)
	model_ok := false
	for candidate in entry.models { if candidate.model_id == model && candidate.state == "active" { model_ok = true; break } }
	if !model_ok do return {}, false, domain.domain_error(.Unprocessable_Entity, "model is unknown or deprecated for provider")
	statuses, status_err := iface.bridge_provider_status_list(service.providers, bridge_id)
	if status_err.code != .None do return {}, false, status_err
	defer domain.bridge_provider_statuses_destroy(statuses)
	settings, settings_err := iface.bridge_provider_setting_list(service.providers, bridge_id)
	if settings_err.code != .None do return {}, false, settings_err
	defer domain.bridge_provider_settings_destroy(settings)
	present, enabled := false, false
	for status in statuses { if status.provider == provider && status.state == "present" { present = true; break } }
	for setting in settings { if setting.provider == provider && setting.enabled { enabled = true; break } }
	if !present || !enabled do return {}, false, domain.domain_error(.Provider_Unavailable, "provider is not enabled and present on bridge")
	return domain.Resolved_Provider_Model{provider = provider, model = model}, true, domain.Domain_Error{}
}

select_bridge_for_agent :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, agent: domain.Agent, req: Run_Request) -> (domain.Bridge, bool, domain.Domain_Error) {
	supports, err := list_support(service, auth, agent.agent_id)
	if err.code != .None do return domain.Bridge{}, false, err
	best: domain.Bridge
	best_priority := -2147483648
	found := false
	online_enabled_found := false
	last_provider := ""
	last_model := ""
	if strings.trim_space(req.provider) == "" || strings.trim_space(req.model) == "" do return {}, false, domain.domain_error(.Unprocessable_Entity, "provider and model are required")
	for support in supports {
		if !support.enabled do continue
		bridge, bridge_ok, _ := iface.bridge_get_bridge(service.bridges, support.bridge_id)
		if !bridge_ok || bridge.plan_disabled_at != "" || bridge.status != .Online || !project_service.bridge_runtime_registry_has_live(service.bridge_runtime_registry, bridge.bridge_id) do continue
		online_enabled_found = true
		provider := req.provider
		model := req.model
		last_provider = provider
		last_model = model
		if _, valid, _ := validate_provider_model_intersection(service, bridge.bridge_id, provider, model); !valid do continue
		if !found || support.priority > best_priority {
			best = bridge
			best_priority = support.priority
			found = true
		}
	}
	if !found && online_enabled_found do return domain.Bridge{}, false, domain.domain_error(.Provider_Unavailable, fmt.tprintf("no enabled online bridge supports provider/model %s/%s", last_provider, last_model))
	if !found do return domain.Bridge{}, false, domain.domain_error(.Bridge_Offline, "no online supported bridge is available")
	return best, true, domain.Domain_Error{}
}

resolve_project_path_for_launch :: proc(service: ^Agent_Service, owner: domain.User_ID, project_id: domain.Project_ID, bridge_id: string) -> (string, bool, domain.Domain_Error) {
	if service.projects == nil do return "", false, domain.domain_error(.Internal_Error, "project repository is not configured")
	project, ok, err := iface.project_get(service.projects, project_id)
	if !ok do return "", false, err
	if project.owner_user_id != owner do return "", false, domain.domain_error(.Not_Found, "project not found")
	if project.state != .Active do return "", false, domain.domain_error(.Conflict, "archived projects cannot be used for launches")
	path, path_ok, _ := iface.project_get_bridge_path(service.projects, project.project_id, bridge_id)
	if path_ok do return path.path, true, domain.Domain_Error{}
	return project.default_path, true, domain.Domain_Error{}
}

publish_state_string :: proc(state: domain.Publish_State) -> string { if state == .Published do return "published"; return "draft" }
chain_status_string :: proc(status: domain.Task_Chain_Status) -> string { if status == .Completed do return "completed"; if status == .Cancelled do return "cancelled"; if status == .Archived do return "archived"; return "active" }
json_or_empty_array :: proc(value: string) -> string { if strings.trim_space(value) == "" do return "[]"; return value }

apply_runtime_startup_projection :: proc(inst: ^domain.Agent_Instance, now: string) {
	if inst == nil do return
	switch inst.runtime_status {
	case "running", "idle", "busy":
		inst.startup_status = "ready"
	case "launching", "starting":
		inst.startup_status = "starting"
	case "blocked":
		// Startup probe classified the agent as blocked (e.g. an interactive prompt
		// the wrapper could not auto-dismiss). Surface it as startup_blocked so the UI
		// flags it. It stays active-but-not-ready: no stopped_at, keep current_task.
		inst.startup_status = "startup_blocked"
	case "failed":
		inst.startup_status = "startup_failed"
		inst.stopped_at = now
		clear_instance_current_task(inst)
	case "stopped", "unreachable":
		inst.startup_status = "stopped"
		inst.stopped_at = now
		// CT-7 consistency: a stopped/unreachable instance is no longer focused on
		// any task, so drop its persisted current_task pointer. The auto-promotion
		// engine will re-establish focus if/when the instance comes back and a
		// chain recompute runs.
		clear_instance_current_task(inst)
	}
}

// clear_instance_current_task drops an instance's persisted current_task pointer
// in place. Used by the runtime projection when an instance reaches a terminal
// runtime state (stopped/unreachable/failed) so the dashboard does not show a
// stale focus for an agent that is gone.
clear_instance_current_task :: proc(inst: ^domain.Agent_Instance) {
	if inst == nil do return
	inst.current_task_id = ""
	inst.current_task_role = .None
}

runtime_expected_active :: proc(runtime_status: string) -> bool {
	// "blocked" is active-but-not-ready: the wrapper is alive (still heartbeating),
	// so the instance counts as live and must not be reaped, but its startup_status
	// projects to startup_blocked rather than ready.
	return runtime_status == "launching" || runtime_status == "starting" || runtime_status == "running" || runtime_status == "idle" || runtime_status == "busy" || runtime_status == "stopping" || runtime_status == "blocked"
}

string_slice_contains :: proc(values: []string, needle: string) -> bool {
	for value in values { if strings.trim_space(value) == needle do return true }
	return false
}

launch_command_json :: proc(command_id: string, inst: domain.Agent_Instance) -> string {
	return launch_command_json_full(nil, command_id, inst)
}

// launch_command_json_full builds the enriched launch_agent WS payload. Beyond
// the routing fields it carries the per-instance DESCRIPTOR the bridge needs to
// (a) form the (agent_id, role, provider, project_id) key for the conditional
// bootstrap-manifest GET and (b) render the AGENTS.md header + coordinator wiring
// locally — WITHOUT the bridge querying hub chains/agents tables. When `service`
// is nil (or lookups fail) the descriptor fields degrade to empty strings and the
// role defaults to "worker"; the routing fields are always present.
launch_command_json_full :: proc(service: ^Agent_Service, command_id: string, inst: domain.Agent_Instance) -> string {
	role := "worker"
	coordinator_id := ""
	chain_title := ""
	agent_name := ""
	if service != nil {
		if service.taskchains != nil && inst.chain_id != "" {
			if chain, chain_ok, _ := iface.taskchain_get_chain(service.taskchains, domain.Task_Chain_ID(inst.chain_id)); chain_ok {
				coordinator_id = chain.coordinator_agent_instance_id
				chain_title = chain.title
				if chain.coordinator_agent_instance_id == inst.agent_instance_id do role = "coordinator"
			}
		}
		if service.agents != nil && inst.agent_id != "" {
			if agent, agent_ok, _ := iface.agent_get(service.agents, inst.agent_id); agent_ok {
				agent_name = agent.name
			}
		}
	}
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"launch_agent\",\"protocol_version\":1,\"message_id\":\""); write_service_json_string(&b, strings.concatenate({"msg_", command_id}))
	strings.write_string(&b, "\",\"command_id\":\""); write_service_json_string(&b, command_id)
	strings.write_string(&b, "\",\"payload\":{\"agent_instance_id\":\""); write_service_json_string(&b, inst.agent_instance_id)
	strings.write_string(&b, "\",\"agent_id\":\""); write_service_json_string(&b, inst.agent_id)
	strings.write_string(&b, "\",\"agent_name\":\""); write_service_json_string(&b, agent_name)
	strings.write_string(&b, "\",\"display_name\":\""); write_service_json_string(&b, inst.display_name)
	strings.write_string(&b, "\",\"role\":\""); write_service_json_string(&b, role)
	strings.write_string(&b, "\",\"coordinator_agent_instance_id\":\""); write_service_json_string(&b, coordinator_id)
	strings.write_string(&b, "\",\"chain_title\":\""); write_service_json_string(&b, chain_title)
	strings.write_string(&b, "\",\"project_id\":\""); write_service_json_string(&b, string(inst.project_id))
	strings.write_string(&b, "\",\"project_path\":\""); write_service_json_string(&b, inst.project_path)
	strings.write_string(&b, "\",\"chain_id\":\""); write_service_json_string(&b, inst.chain_id)
	strings.write_string(&b, "\",\"conversation_id\":\""); write_service_json_string(&b, inst.conversation_id)
	strings.write_string(&b, "\",\"provider\":\""); write_service_json_string(&b, inst.provider)
	strings.write_string(&b, "\",\"model\":\""); write_service_json_string(&b, inst.model)
	strings.write_string(&b, "\",\"launch_epoch\":\""); write_service_json_string(&b, inst.launch_epoch)
	token := instance_assertion_token(inst); defer delete(token)
	strings.write_string(&b, "\",\"instance_token\":\""); write_service_json_string(&b, token)
	strings.write_string(&b, "\",\"bootstrap_url\":\"/api/v1/bridge/agent-instances/"); write_service_json_string(&b, inst.agent_instance_id)
	strings.write_string(&b, "/bootstrap\"}}")
	return strings.to_string(b)
}

stop_command_json :: proc(command_id, instance_id, reason: string, force: bool = false) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"stop_agent\",\"protocol_version\":1,\"message_id\":\""); write_service_json_string(&b, strings.concatenate({"msg_", command_id}))
	strings.write_string(&b, "\",\"command_id\":\""); write_service_json_string(&b, command_id)
	strings.write_string(&b, "\",\"payload\":{\"agent_instance_id\":\""); write_service_json_string(&b, instance_id)
	strings.write_string(&b, "\",\"reason\":\""); write_service_json_string(&b, reason)
	strings.write_string(&b, "\",\"grace_seconds\":"); strings.write_string(&b, "0" if force else "10")
	strings.write_string(&b, ",\"force\":"); strings.write_string(&b, "true" if force else "false"); strings.write_string(&b, "}}")
	return strings.to_string(b)
}

// Wake_Agent_Run_Entry is one instance the bridge SHOULD have running for a chain:
// the agent instance, the task it is focused on, and its action role ("worker" or
// "reviewer"). Coordinators are never emitted (the reconcile pass excludes them).
Wake_Agent_Run_Entry :: struct {
	agent_instance_id: string,
	task_id:           string,
	role:              string,
	provider:          string,
	model:              string,
	// REQ-37: enriched descriptor (parity with launch_command_json_full) so the
	// bridge's wake path forms the (agent_id, role, provider, project) key and takes
	// the full agent-keyed template bootstrap instead of the header-only instance
	// fallback (which, post BT-6, carries only the 6-line header). agent_id is the
	// load-bearing field; without it the bridge cannot fetch the template manifest.
	agent_id:          string,
	agent_name:        string,
	chain_id:          string,
	chain_title:       string,
	coordinator_id:    string,
	project_id:        string,
	project_path:      string,
	// Task System v2: the lease this run entry delivers and its context pack
	// (a JSON object, emitted verbatim). Empty for non-lease wakes.
	lease_id:          string,
	pack_json:         string,
}

// wake_agent_command_json builds the ephemeral-lifecycle push the reconcile pass
// sends to a bridge (REQ-10): the run[] entries name the non-coordinator agents that
// should be running (started fresh, or restarted) and stop[] names the agent
// instances that should be stopped (were running, task no longer actionable). One
// command is sent per (chain × bridge). Shape:
//   {"type":"wake_agent","protocol_version":1,"command_id":"<id>","chain_id":"<id>","payload":{"run":[{"agent_instance_id":"..","task_id":"..","role":"..","provider":"..","model":".."}],"stop":["..",..]}}
// command_id is required: wake_agent is a queued command on the bridge, and the
// bridge's dispatcher rejects queued commands without one (missing_command_id).
// provider/model are optional per entry (omitted when empty) so the bridge restarts
// the instance on its saved provider/model rather than the bridge defaults (REQ-33).
wake_agent_command_json :: proc(command_id, chain_id: string, run: []Wake_Agent_Run_Entry, stop: []string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"wake_agent\",\"protocol_version\":1,\"command_id\":\""); write_service_json_string(&b, command_id)
	strings.write_string(&b, "\",\"chain_id\":\""); write_service_json_string(&b, chain_id)
	strings.write_string(&b, "\",\"payload\":{\"run\":[")
	for entry, i in run {
		if i > 0 do strings.write_string(&b, ",")
		strings.write_string(&b, "{\"agent_instance_id\":\""); write_service_json_string(&b, entry.agent_instance_id)
		strings.write_string(&b, "\",\"task_id\":\""); write_service_json_string(&b, entry.task_id)
		strings.write_string(&b, "\",\"role\":\""); write_service_json_string(&b, entry.role)
		strings.write_string(&b, "\"")   // close role value
		// provider/model are emitted only when non-empty so an old bridge that
		// ignores them, and a hub restarting an instance with no saved values,
		// both keep the previous "fall back to bridge defaults" behavior.
		if entry.provider != "" {
			strings.write_string(&b, ",\"provider\":\""); write_service_json_string(&b, entry.provider); strings.write_string(&b, "\"")
		}
		if entry.model != "" {
			strings.write_string(&b, ",\"model\":\""); write_service_json_string(&b, entry.model); strings.write_string(&b, "\"")
		}
		// REQ-37: enriched descriptor fields (same JSON keys as launch_command_json_full)
		// so the bridge takes the full agent-keyed template bootstrap. Emitted only when
		// non-empty; an old bridge ignores unknown keys and keeps its prior behavior.
		if entry.agent_id != "" {
			strings.write_string(&b, ",\"agent_id\":\""); write_service_json_string(&b, entry.agent_id); strings.write_string(&b, "\"")
		}
		if entry.agent_name != "" {
			strings.write_string(&b, ",\"agent_name\":\""); write_service_json_string(&b, entry.agent_name); strings.write_string(&b, "\"")
		}
		if entry.chain_id != "" {
			strings.write_string(&b, ",\"chain_id\":\""); write_service_json_string(&b, entry.chain_id); strings.write_string(&b, "\"")
		}
		if entry.chain_title != "" {
			strings.write_string(&b, ",\"chain_title\":\""); write_service_json_string(&b, entry.chain_title); strings.write_string(&b, "\"")
		}
		if entry.coordinator_id != "" {
			strings.write_string(&b, ",\"coordinator_agent_instance_id\":\""); write_service_json_string(&b, entry.coordinator_id); strings.write_string(&b, "\"")
		}
		if entry.project_id != "" {
			strings.write_string(&b, ",\"project_id\":\""); write_service_json_string(&b, entry.project_id); strings.write_string(&b, "\"")
		}
		if entry.project_path != "" {
			strings.write_string(&b, ",\"project_path\":\""); write_service_json_string(&b, entry.project_path); strings.write_string(&b, "\"")
		}
		if entry.lease_id != "" {
			strings.write_string(&b, ",\"lease_id\":\""); write_service_json_string(&b, entry.lease_id); strings.write_string(&b, "\"")
		}
		if strings.has_prefix(strings.trim_space(entry.pack_json), "{") {
			strings.write_string(&b, ",\"pack\":"); strings.write_string(&b, strings.trim_space(entry.pack_json))
		}
		strings.write_string(&b, "}")   // close entry object
	}
	strings.write_string(&b, "],\"stop\":[")
	for id, i in stop {
		if i > 0 do strings.write_string(&b, ",")
		strings.write_string(&b, "\""); write_service_json_string(&b, id); strings.write_string(&b, "\"")
	}
	strings.write_string(&b, "]}}")
	return strings.to_string(b)
}

write_service_json_string :: proc(b: ^strings.Builder, value: string) {
	contracts.write_json_string(b, value)
}

bootstrap_fragment_hash :: proc(body: string) -> string {
	buf: [32]byte
	hash.hash_string_to_buffer(.SHA256, body, buf[:])
	hex_str := hex.encode(buf[:])
	defer delete(hex_str)
	return strings.concatenate({"sha256:", string(hex_str)})
}

// BT-2: the single static AGENTS.md template. All static prose is inline; the
// bridge substitutes {scalar} placeholders and evaluates the three role blocks
// {{#is_coordinator}}/{{#is_worker}}/{{#is_reviewer}}. Served as a
// content-addressed blob in the manifest (kind=AGENTS_TEMPLATE) so an unchanged
// template skips re-transfer, exactly like every fragment blob.
BOOTSTRAP_AGENTS_TEMPLATE :: #load("../../../prompts/bootstrap_agents.md", string)

// Bootstrap_Variable is one DB-derived value the hub serves individually so the
// bridge can substitute it into the template. `value` is inlined in the manifest
// (the strings are tiny) AND the value is pushed into the fragment cache under
// `hash` so a bridge that prefers a per-hash blob GET can still fetch it. `hash`
// feeds the manifest version so a changed value re-bases the ETag.
Bootstrap_Variable :: struct {
	name:  string,
	value: string,
	hash:  string,
}

// bootstrap_build_project_variables produces the five project_* variables in a
// FIXED order (always all five, even when empty, for a deterministic version and
// explicit empty substitution). Each value is hashed + cached. BT-2a appends the
// identity variables (template_persona/template_instructions/agent_instructions)
// onto the slice this returns.
bootstrap_build_project_variables :: proc(project_name, project_path, project_repo, project_vcs, project_desc: string) -> [dynamic]Bootstrap_Variable {
	vars := make([dynamic]Bootstrap_Variable)
	add :: proc(vars: ^[dynamic]Bootstrap_Variable, name, value: string) {
		h := bootstrap_fragment_hash(value)
		hub_fragment_cache_put(h, value)
		append(vars, Bootstrap_Variable{name = name, value = value, hash = h})
	}
	add(&vars, "project_name", project_name)
	add(&vars, "project_path", project_path)
	add(&vars, "project_repo", project_repo)
	add(&vars, "project_vcs", project_vcs)
	add(&vars, "project_description", project_desc)
	return vars
}

// bootstrap_append_identity_variables appends the three identity variables
// (BT-2a) onto a variable slice in FIXED order: template_persona,
// template_instructions, agent_instructions. Each is hashed + cached. The bridge
// substitutes them into the template's {template_persona}/{template_instructions}/
// {agent_instructions} slots; the template's static ### Persona / ### Instructions
// headings + the approved persona->template_instructions->agent_instructions
// order live in bootstrap_agents.md (BT-1 §2.1). Empty values are still emitted
// (deterministic version + explicit empty substitution; a stray empty heading is
// acceptable per the approved design).
bootstrap_append_identity_variables :: proc(vars: ^[dynamic]Bootstrap_Variable, template_persona, template_instructions, agent_instructions: string) {
	add :: proc(vars: ^[dynamic]Bootstrap_Variable, name, value: string) {
		h := bootstrap_fragment_hash(value)
		hub_fragment_cache_put(h, value)
		append(vars, Bootstrap_Variable{name = name, value = value, hash = h})
	}
	add(vars, "template_persona", template_persona)
	add(vars, "template_instructions", template_instructions)
	add(vars, "agent_instructions", agent_instructions)
}

// bootstrap_build_memory_markdown_instance builds the MEMORY.md content for
// instance-keyed launches. Only fact and habit memories are inlined;
// skill memories are delivered as SKILL.md files. Option A: if no applicable
// memories exist, emits a clean empty-fallback notice.
bootstrap_build_memory_markdown_instance :: proc(service: ^Agent_Service, owner: domain.User_ID, inst: domain.Agent_Instance) -> string {
	b := strings.builder_make()
	if service == nil || service.content == nil {
		strings.write_string(&b, "# Applicable Memories\n\nNo specific memories recorded for this agent.\n")
		return strings.to_string(b)
	}
	memories, err := iface.content_list_memories(service.content, owner)
	if err.code != .None {
		strings.write_string(&b, "# Applicable Memories\n\nNo specific memories recorded for this agent.\n")
		return strings.to_string(b)
	}
	written := 0
	for m in memories {
		if !bootstrap_memory_applies(m, service, owner, inst) do continue
		if m.type != .Fact && m.type != .Habit do continue
		if written == 0 do strings.write_string(&b, "# Applicable Memories")
		fmt.sbprintf(&b, "\n\n### %s\nType: %s\n\n%s", m.title, domain.memory_type_string(m.type), m.body)
		written += 1
	}
	if written == 0 {
		strings.write_string(&b, "# Applicable Memories\n\nNo specific memories recorded for this agent.\n")
	}
	return strings.to_string(b)
}

// bootstrap_build_memory_markdown_agent is the agent-keyed variant used by
// render_agent_manifest. Same filtering rules as the instance variant.
bootstrap_build_memory_markdown_agent :: proc(service: ^Agent_Service, owner: domain.User_ID, agent: domain.Agent, project_id: domain.Project_ID, bridge_id: string) -> string {
	b := strings.builder_make()
	if service == nil || service.content == nil {
		strings.write_string(&b, "# Applicable Memories\n\nNo specific memories recorded for this agent.\n")
		return strings.to_string(b)
	}
	memories, err := iface.content_list_memories(service.content, owner)
	if err.code != .None {
		strings.write_string(&b, "# Applicable Memories\n\nNo specific memories recorded for this agent.\n")
		return strings.to_string(b)
	}
	written := 0
	for m in memories {
		if !bootstrap_memory_applies_agent(m, agent, owner, project_id, bridge_id) do continue
		if m.type != .Fact && m.type != .Habit do continue
		if written == 0 do strings.write_string(&b, "# Applicable Memories")
		fmt.sbprintf(&b, "\n\n### %s\nType: %s\n\n%s", m.title, domain.memory_type_string(m.type), m.body)
		written += 1
	}
	if written == 0 {
		strings.write_string(&b, "# Applicable Memories\n\nNo specific memories recorded for this agent.\n")
	}
	return strings.to_string(b)
}

// Skill_Manifest_Item is one skill entry in the manifest skills[] array: the
// slug (name) plus the content-addressed hash the bridge fetches + caches.
Skill_Manifest_Item :: struct {
	name: string,
	hash: string,
}

// bootstrap_append_static_skills appends the compile-time static skill set
// (STATIC_SKILLS, generated by tools/gen_static_skills from src/prompts/skills/)
// to skills_list. BT-6: the SAME set goes to EVERY agent — no role gating — so
// the hashes are identical across agents and dedupe in the bridge cache. Each
// entry is hashed + cached under that hash so the existing /blobs/<hash> path
// serves it, exactly like the former hardcoded skill procs did.
bootstrap_append_static_skills :: proc(skills_list: ^[dynamic]Skill_Manifest_Item) {
	for s in STATIC_SKILLS {
		hash := bootstrap_fragment_hash(s.content)
		hub_fragment_cache_put(hash, s.content)
		append(skills_list, Skill_Manifest_Item{name = s.slug, hash = hash})
	}
}

// bootstrap_template_hash hashes the template body and caches it under that hash
// so the existing /blobs/<hash> path serves it. Returns the hash.
bootstrap_template_hash :: proc() -> string {
	h := bootstrap_fragment_hash(BOOTSTRAP_AGENTS_TEMPLATE)
	hub_fragment_cache_put(h, BOOTSTRAP_AGENTS_TEMPLATE)
	return h
}

// bootstrap_write_template_and_variables_json appends the `template` object and
// the `variables` array to a manifest builder. Shared by both hub render paths
// so the contract is identical (BT-2). Caller writes the leading comma context.
bootstrap_write_template_and_variables_json :: proc(b: ^strings.Builder, template_hash: string, vars: []Bootstrap_Variable) {
	strings.write_string(b, ",\"template\":{\"kind\":\"AGENTS_TEMPLATE\",\"hash\":\"")
	write_service_json_string(b, template_hash)
	strings.write_string(b, "\"},\"variables\":[")
	for v, i in vars {
		if i > 0 do strings.write_byte(b, ',')
		strings.write_string(b, "{\"name\":\""); write_service_json_string(b, v.name)
		strings.write_string(b, "\",\"hash\":\""); write_service_json_string(b, v.hash)
		strings.write_string(b, "\",\"value\":\""); write_service_json_string(b, v.value)
		strings.write_string(b, "\"}")
	}
	strings.write_string(b, "]")
}

// bootstrap_template_identity_fields fetches the agent's template persona +
// instructions for the identity fragment. Returns empty strings when the agent
// has no template or the lookup misses (miss treated as empty, never an error).
// Built-in templates resolve to their compiled-in src/templates/*.md content so
// rows seeded by older migrations cannot shadow the current text.
bootstrap_template_identity_fields :: proc(service: ^Agent_Service, agent: domain.Agent) -> (persona: string, instructions: string) {
	if strings.trim_space(agent.template_id) == "" do return "", ""
	if builtin, ok := domain.builtin_template(agent.template_id); ok do return builtin.persona, builtin.instructions
	if service == nil || service.content == nil do return "", ""
	tmpl, ok, _ := iface.content_get_template(service.content, agent.template_id)
	if !ok do return "", ""
	return tmpl.persona, tmpl.instructions
}

render_skill :: proc(m: domain.Memory) -> (string, string) {
	name := bootstrap_skill_name(m)
	content := bootstrap_skill_file_content(m, name)
	return name, content
}

render_header_inline :: proc(agent_name, instance_id, chain_title, chain_id, coordinator_id: string, is_coordinator: bool) -> string {
	b := strings.builder_make()
	fmt.sbprintf(&b, "# Agent bootstrap\n\nAgent: %s\nInstance: %s", agent_name, instance_id)
	if chain_title != "" || chain_id != "" {
		fmt.sbprintf(&b, "\nTask chain: %s (%s)", chain_title, chain_id)
		if is_coordinator {
			strings.write_string(&b, "\nCoordinator: you (coordinator)")
		} else if coordinator_id != "" {
			fmt.sbprintf(&b, "\nCoordinator: %s", coordinator_id)
		}
	}
	return strings.to_string(b)
}

Hub_Fragment_Cache_Entry :: struct {
	hash: string,
	body: string,
}

Hub_Fragment_Cache :: struct {
	entries: map[string]Hub_Fragment_Cache_Entry,
	lock: sync.Mutex,
}

global_hub_fragment_cache: Hub_Fragment_Cache

// Upper bound on distinct cached fragments. The cache previously never evicted,
// so it grew without limit as new content hashes appeared (every skills/manifest
// revision). Fragments are content-addressed and cheap to re-render, so a simple
// capacity cap is safe.
HUB_FRAGMENT_CACHE_MAX :: 512

hub_fragment_cache_put :: proc(hash, body: string) {
	// The cache outlives the request that populates it, so it MUST own its strings
	// on the persistent heap — never on the caller's per-request arena. Previously
	// it stored the caller's pointers verbatim (a use-after-free waiting to happen
	// once callers freed per request) and overwrote entries without freeing the
	// prior body (a leak on every re-render).
	heap := runtime.heap_allocator()
	sync.mutex_lock(&global_hub_fragment_cache.lock)
	defer sync.mutex_unlock(&global_hub_fragment_cache.lock)
	if global_hub_fragment_cache.entries == nil {
		global_hub_fragment_cache.entries = make(map[string]Hub_Fragment_Cache_Entry, heap)
	}
	if prev, ok := global_hub_fragment_cache.entries[hash]; ok {
		delete_key(&global_hub_fragment_cache.entries, hash)
		delete(prev.hash, heap)
		delete(prev.body, heap)
	} else if len(global_hub_fragment_cache.entries) >= HUB_FRAGMENT_CACHE_MAX {
		// Evict one entry (capture first, then mutate — never delete during range).
		evict_key, evict_hash, evict_body: string
		for k, v in global_hub_fragment_cache.entries {
			evict_key, evict_hash, evict_body = k, v.hash, v.body
			break
		}
		delete_key(&global_hub_fragment_cache.entries, evict_key)
		delete(evict_hash, heap)
		delete(evict_body, heap)
	}
	key := strings.clone(hash, heap)
	global_hub_fragment_cache.entries[key] = Hub_Fragment_Cache_Entry{hash = key, body = strings.clone(body, heap)}
}

hub_fragment_cache_get :: proc(hash: string) -> (string, bool) {
	sync.mutex_lock(&global_hub_fragment_cache.lock)
	defer sync.mutex_unlock(&global_hub_fragment_cache.lock)
	if global_hub_fragment_cache.entries == nil do return "", false
	entry, ok := global_hub_fragment_cache.entries[hash]
	if !ok do return "", false
	return entry.body, true
}

// bootstrap_manifest_status_launchable reports whether an instance in the given
// runtime_status may have its bootstrap manifest fetched by the bridge. It allows
// the already-active/launching states plus the recoverable non-active states a
// scheduler legitimately wakes from ("stopped", "failed", "unreachable"). It does
// NOT allow states that indicate an in-progress teardown ("stopping") or unknown
// values, keeping the gate conservative.
bootstrap_manifest_status_launchable :: proc(runtime_status: string) -> bool {
	switch runtime_status {
	case "launching", "starting", "running", "idle", "busy", "blocked",
	     "stopped", "failed", "unreachable":
		return true
	}
	return false
}

bootstrap_manifest_json_for_bridge :: proc(service: ^Agent_Service, owner: domain.User_ID, bridge_id, instance_id: string) -> (string, bool, domain.Domain_Error) {
	inst, ok, err := iface.agent_get_instance(service.agents, instance_id)
	if !ok do return "", false, err
	if inst.bridge_id != bridge_id || inst.owner_user_id != owner do return "", false, domain.domain_error(.Not_Found, "agent instance not found")
	// A scheduled action (or auto-nudge) may need to wake an instance that is not
	// currently live. The bridge synthesizes a minimal launch and fetches this
	// manifest by instance id to materialize the agent, so we must also permit the
	// recoverable non-active states it legitimately wakes from -- "stopped",
	// "failed", and "unreachable" -- in addition to the already-active/launching
	// states. Previously those were rejected with 409 "not launchable", which meant
	// a scheduled action could never start a stopped instance (it only churned it to
	// startup_failed). This is a read-only manifest fetch; it does not itself change
	// instance state.
	if !bootstrap_manifest_status_launchable(inst.runtime_status) do return "", false, domain.domain_error(.Conflict, "agent instance is not launchable")
	agent, agent_ok, agent_err := iface.agent_get(service.agents, inst.agent_id)
	if !agent_ok do return "", false, agent_err
	bridge, bridge_ok, bridge_err := iface.bridge_get_bridge(service.bridges, bridge_id)
	if !bridge_ok do return "", false, bridge_err
	project_name := ""
	project_repo := ""
	project_vcs := ""
	project_desc := ""
	project_path := inst.project_path
	if inst.project_id != "" && service.projects != nil {
		if project, project_ok, _ := iface.project_get(service.projects, inst.project_id); project_ok {
			project_name = project.name
			project_repo = project.repo_url
			project_vcs = project.vcs_kind
			project_desc = project.description
			// Keep the instance's resolved bridge path, including an intentionally empty path.
		}
	}
	chain := domain.Task_Chain{}
	chain_ok := false
	if inst.chain_id != "" && service.taskchains != nil { chain, chain_ok, _ = iface.taskchain_get_chain(service.taskchains, domain.Task_Chain_ID(inst.chain_id)) }

	header_inline := render_header_inline(agent.name, inst.agent_instance_id, chain.title, string(chain.chain_id), chain.coordinator_agent_instance_id, chain.coordinator_agent_instance_id == inst.agent_instance_id)

	template_persona, template_instructions := bootstrap_template_identity_fields(service, agent)
	is_coordinator := chain_ok && chain.coordinator_agent_instance_id == inst.agent_instance_id

	skills_list := make([dynamic]Skill_Manifest_Item)
	// BT-6: the SAME static skill set goes to every agent (no role gating).
	// STATIC_SKILLS is generated by tools/gen_static_skills from
	// src/prompts/skills/<slug>/SKILL.md (see static_skills_gen.odin).
	bootstrap_append_static_skills(&skills_list)
	if service != nil && service.content != nil {
		memories, err := iface.content_list_memories(service.content, owner)
		if err.code == .None {
			for m in memories {
				if !bootstrap_memory_applies(m, service, owner, inst) || m.type != .Skill do continue
				name, content := render_skill(m)
				skill_hash := bootstrap_fragment_hash(content)
				hub_fragment_cache_put(skill_hash, content)
				append(&skills_list, Skill_Manifest_Item{name = name, hash = skill_hash})
			}
		}
	}

	// REQ-37 (B1): the instance descriptor the bridge's scheduler wake path reads to
	// build an enriched launch command (it only knows the instance_id locally). role
	// mirrors the wake/launch role vocabulary: coordinator > reviewer (current review
	// focus) > worker.
	instance_role := "worker"
	if is_coordinator {
		instance_role = "coordinator"
	} else if inst.current_task_role == .Review {
		instance_role = "reviewer"
	}

	memories_md := bootstrap_build_memory_markdown_instance(service, owner, inst)
	defer delete(memories_md)
	mem_hash := bootstrap_fragment_hash(memories_md)
	hub_fragment_cache_put(mem_hash, memories_md)

	b := strings.builder_make()
	strings.write_string(&b, "{\"protocol\":2,\"instance\":{\"agent_instance_id\":\"")
	write_service_json_string(&b, inst.agent_instance_id)
	strings.write_string(&b, "\",\"agent_id\":\""); write_service_json_string(&b, agent.agent_id)
	strings.write_string(&b, "\",\"agent_name\":\""); write_service_json_string(&b, agent.name)
	strings.write_string(&b, "\",\"role\":\""); write_service_json_string(&b, instance_role)
	strings.write_string(&b, "\",\"chain_id\":\""); write_service_json_string(&b, inst.chain_id)
	strings.write_string(&b, "\",\"chain_title\":\""); write_service_json_string(&b, chain.title)
	strings.write_string(&b, "\",\"coordinator_agent_instance_id\":\""); write_service_json_string(&b, chain.coordinator_agent_instance_id)
	strings.write_string(&b, "\",\"project_id\":\""); write_service_json_string(&b, string(inst.project_id))
	strings.write_string(&b, "\",\"project_path\":\""); write_service_json_string(&b, inst.project_path)
	// The scheduler wake builds its launch from this descriptor alone, so it must
	// carry the instance's provider/model; without them every wake failed at spawn
	// with provider_missing (REQ-ERR-6).
	strings.write_string(&b, "\",\"provider\":\""); write_service_json_string(&b, inst.provider)
	strings.write_string(&b, "\",\"model\":\""); write_service_json_string(&b, inst.model)
	token := instance_assertion_token(inst); defer delete(token)
	strings.write_string(&b, "\",\"instance_token\":\""); write_service_json_string(&b, token)
	strings.write_string(&b, "\",\"hub_url\":\""); write_service_json_string(&b, bridge.hub_url)
	strings.write_string(&b, "\"},\"files\":[{\"kind\":\"AGENTS_MD\",\"relative_path\":\"AGENTS.md\",\"assembly\":[")

	// BT-6: only the bridge-injected header is carried as an assembly section for
	// the legacy fallback path; the live path renders from the single template
	// blob + variables below. The old per-fragment sections (agent_identity/
	// project/tasks_guidance/role_guidance/memories) are gone.
	strings.write_string(&b, "{\"section\":\"header\",\"inline\":\"")
	write_service_json_string(&b, header_inline)
	strings.write_string(&b, "\"}]},{\"kind\":\"MEMORY_MD\",\"relative_path\":\"MEMORY.md\",\"hash\":\"")
	write_service_json_string(&b, mem_hash)
	strings.write_string(&b, "\"}]")

	// BT-2/BT-2a: single-template blob + all DB-derived variables (project_* + identity).
	instance_template_hash := bootstrap_template_hash()
	instance_variables := bootstrap_build_project_variables(project_name, project_path, project_repo, project_vcs, project_desc)
	defer delete(instance_variables)
	bootstrap_append_identity_variables(&instance_variables, template_persona, template_instructions, agent.instructions)
	bootstrap_write_template_and_variables_json(&b, instance_template_hash, instance_variables[:])

	strings.write_string(&b, ",\"skills\":[")
	for item, i in skills_list {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, "{\"kind\":\"SKILL\",\"name\":\"")
		write_service_json_string(&b, item.name)
		strings.write_string(&b, "\",\"target_hint\":\"")
		write_service_json_string(&b, fmt.tprintf(".agents/skills/%s/SKILL.md", item.name))
		strings.write_string(&b, "\",\"hash\":\"")
		write_service_json_string(&b, item.hash)
		strings.write_string(&b, "\"}")
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b), true, domain.Domain_Error{}
}

json_string_array :: proc(body, key: string, allocator := context.allocator) -> []string {
	dyn := jsonx.extract_string_array(body, key, allocator = allocator)
	return dyn[:]
}

resolve_blobs_json :: proc(service: ^Agent_Service, request_body: string) -> string {
	hashes := json_string_array(request_body, "hashes")
	defer {
		for h in hashes do delete(h)
		delete(hashes)
	}
	b := strings.builder_make()
	strings.write_string(&b, "{\"blobs\":[")
	blobs_written := 0
	missing := make([dynamic]string)
	defer delete(missing)
	for hash in hashes {
		if body, found := hub_fragment_cache_get(hash); found {
			if blobs_written > 0 do strings.write_byte(&b, ',')
			strings.write_string(&b, "{\"hash\":\"")
			write_service_json_string(&b, hash)
			strings.write_string(&b, "\",\"body\":\"")
			write_service_json_string(&b, body)
			strings.write_string(&b, "\"}")
			blobs_written += 1
		} else {
			append(&missing, hash)
		}
	}
	strings.write_string(&b, "],\"missing\":[")
	for m_hash, i in missing {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, "\"")
		write_service_json_string(&b, m_hash)
		strings.write_string(&b, "\"")
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

// resolve_single_blob returns one immutable content-addressed fragment body by
// hash (HUB-3). Fragment bodies are populated in the in-process cache during
// manifest render, so a per-hash GET always follows a manifest render for the
// same agent and finds its blob. Returns ("", false) for an unknown hash.
resolve_single_blob :: proc(service: ^Agent_Service, hash: string) -> (string, bool) {
	_ = service
	if strings.trim_space(hash) == "" do return "", false
	return hub_fragment_cache_get(hash)
}

// -----------------------------------------------------------------------------
// Conditional, agent-keyed bootstrap manifest (HUB-1, HUB-2).
//
// The manifest is keyed by (agent_id, role, provider, project) and carries NO
// per-instance data — the bridge injects the per-instance header/tokens locally.
// A per-agent `bootstrap_version = sha256(concat of input fragment hashes)` is
// computed during render and embedded in the ETag. A shared content epoch (see
// hub/bootcache) lets a warm request short-circuit to a 304 with an indexed
// compare only (no render, no memories scan, no multi-table SQL).
// -----------------------------------------------------------------------------

Bootstrap_Manifest_Cache_Entry :: struct {
	epoch:         u64,
	version:       string,
	etag:          string,
	manifest_json: string,
}

Bootstrap_Manifest_Cache :: struct {
	entries: map[string]Bootstrap_Manifest_Cache_Entry,
	lock:    sync.Mutex,
}

global_bootstrap_manifest_cache: Bootstrap_Manifest_Cache

// manifest_render_count counts full manifest renders (each a memories scan +
// fragment hashing). Warm 304s must NOT increment it; tests assert an unchanged
// agent's second launch does not re-render. Exposed for observability/tests.
manifest_render_count: u64

bootstrap_manifest_render_count :: proc() -> u64 {
	return sync.atomic_load(&manifest_render_count)
}

bootstrap_manifest_cache_key :: proc(agent_id, role, provider, project, bridge_id: string) -> string {
	// bridge_id is part of the key so two bridges requesting the same agent's
	// manifest get separate cache entries — a bridge-scoped skill materialized for
	// one bridge must never be served to instances on another bridge.
	return strings.concatenate({agent_id, "|", role, "|", provider, "|", project, "|", bridge_id})
}

// Bootstrap_Manifest_Result carries everything the transport layer needs to emit
// a conditional response without knowing manifest internals.
Bootstrap_Manifest_Result :: struct {
	status:        int, // 200 or 304
	etag:          string,
	version:       string,
	manifest_json: string, // empty on 304
	was_render:    bool, // true when this request performed a full render (MISS)
}

// bootstrap_manifest_conditional resolves the conditional agent-keyed manifest.
// On a warm cache (cached epoch == current content epoch) it does an indexed
// ETag compare only: a matching If-None-Match yields 304 with no render/scan;
// otherwise it returns the cached 200 body (still no render). When the epoch has
// advanced (some memory/agent/project write) or nothing is cached, it renders
// once, recomputes the version, and then compares.
bootstrap_manifest_conditional :: proc(service: ^Agent_Service, owner: domain.User_ID, agent_id, role, provider, project, bridge_id, if_none_match: string) -> (Bootstrap_Manifest_Result, bool, domain.Domain_Error) {
	if service == nil || service.agents == nil do return {}, false, domain.domain_error(.Internal_Error, "agent service is not configured")
	agent, agent_ok, agent_err := iface.agent_get(service.agents, agent_id)
	if !agent_ok do return {}, false, agent_err
	if agent.owner_user_id != owner do return {}, false, domain.domain_error(.Not_Found, "agent not found")

	norm_role := role
	if norm_role != "coordinator" do norm_role = "worker"
	is_coordinator := norm_role == "coordinator"

	current_epoch := bootcache.content_epoch()
	key := bootstrap_manifest_cache_key(agent_id, norm_role, provider, project, bridge_id)
	defer delete(key)

	sync.mutex_lock(&global_bootstrap_manifest_cache.lock)
	defer sync.mutex_unlock(&global_bootstrap_manifest_cache.lock)
	if global_bootstrap_manifest_cache.entries == nil {
		// Heap-back the map itself: on the request path context.allocator is the
		// per-request arena (MEM-4), so a default make() would put the map's backing
		// store on the arena and free it after the response.
		global_bootstrap_manifest_cache.entries = make(map[string]Bootstrap_Manifest_Cache_Entry, runtime.heap_allocator())
	}

	entry, have := global_bootstrap_manifest_cache.entries[key]
	did_render := false
	if !have || entry.epoch != current_epoch {
		// MISS: (re)render the manifest and recompute the version. This is the
		// only path that scans memories / hashes fragments.
		manifest_json, version := render_agent_manifest(service, owner, agent, is_coordinator, provider, project, bridge_id)
		etag := strings.concatenate({agent_id, ":", norm_role, ":", provider, ":", project, ":", version})
		// The cache outlives this request. render_agent_manifest and the concatenate
		// above build these strings on the caller's per-request arena (MEM-4), which is
		// freed after the response, so the cache MUST own heap copies or every cached
		// entry dangles (and the delete() below would free arena pointers via the heap
		// allocator). Clone the values onto the persistent heap.
		heap := runtime.heap_allocator()
		new_entry := Bootstrap_Manifest_Cache_Entry{
			epoch = current_epoch,
			version = strings.clone(version, heap),
			etag = strings.clone(etag, heap),
			manifest_json = strings.clone(manifest_json, heap),
		}
		if have {
			// Overwrite under the ALREADY-STORED (stable) key: Odin maps store the
			// string header without copying the key bytes, so we must not insert a
			// transient key here. Free the superseded (heap-owned) value strings first
			// to avoid a per-re-render leak.
			delete(entry.version, heap)
			delete(entry.etag, heap)
			delete(entry.manifest_json, heap)
			global_bootstrap_manifest_cache.entries[key] = new_entry
		} else {
			// First insert: clone the key onto the heap so the map owns a stable buffer
			// that outlives this call's `defer delete(key)` (mirrors device_auth/service).
			global_bootstrap_manifest_cache.entries[strings.clone(key, heap)] = new_entry
		}
		entry = new_entry
		did_render = true
		sync.atomic_add(&manifest_render_count, 1)
	}

	result := Bootstrap_Manifest_Result{etag = entry.etag, version = entry.version, was_render = did_render}
	if if_none_match != "" && if_none_match == entry.etag {
		result.status = 304
	} else {
		result.status = 200
		result.manifest_json = entry.manifest_json
	}
	return result, true, domain.Domain_Error{}
}

// render_agent_manifest renders the agent-keyed manifest (no per-instance data)
// and returns (manifest_json, bootstrap_version). Every fragment/skill body is
// pushed into the in-process blob cache so the subsequent per-hash blob GETs are
// served without another render. The version is sha256 over the ordered set of
// input fragment hashes (identity, project, tasks, role, memories, skills) so it
// changes iff any input changes (HUB-1).
render_agent_manifest :: proc(service: ^Agent_Service, owner: domain.User_ID, agent: domain.Agent, is_coordinator: bool, provider, project_id, bridge_id: string) -> (string, string) {
	project_name := ""
	project_repo := ""
	project_vcs := ""
	project_desc := ""
	project_path := ""
	if project_id != "" && service != nil && service.projects != nil {
		if project, project_ok, _ := iface.project_get(service.projects, domain.Project_ID(project_id)); project_ok {
			project_name = project.name
			project_repo = project.repo_url
			project_vcs = project.vcs_kind
			project_desc = project.description
			project_path = project.default_path
		}
	}

	template_persona, template_instructions := bootstrap_template_identity_fields(service, agent)

	skills_list := make([dynamic]Skill_Manifest_Item)
	defer delete(skills_list)
	// BT-6: the SAME static skill set goes to every agent (no role gating),
	// generated by tools/gen_static_skills from src/prompts/skills/.
	bootstrap_append_static_skills(&skills_list)
	if service != nil && service.content != nil {
		memories, err := iface.content_list_memories(service.content, owner)
		if err.code == .None {
			for m in memories {
				if !bootstrap_memory_applies_agent(m, agent, owner, domain.Project_ID(project_id), bridge_id) || m.type != .Skill do continue
				name, content := render_skill(m)
				skill_hash := bootstrap_fragment_hash(content)
				hub_fragment_cache_put(skill_hash, content)
				append(&skills_list, Skill_Manifest_Item{name = name, hash = skill_hash})
			}
		}
	}

	// BT-2/BT-2a: single-template blob + all DB-derived variables (project_* + identity).
	template_hash := bootstrap_template_hash()
	variables := bootstrap_build_project_variables(project_name, project_path, project_repo, project_vcs, project_desc)
	defer delete(variables)
	bootstrap_append_identity_variables(&variables, template_persona, template_instructions, agent.instructions)
	agent_memories_md := bootstrap_build_memory_markdown_agent(service, owner, agent, domain.Project_ID(project_id), bridge_id)
	defer delete(agent_memories_md)
	agent_mem_hash := bootstrap_fragment_hash(agent_memories_md)
	hub_fragment_cache_put(agent_mem_hash, agent_memories_md)

	// bootstrap_version = sha256(concat of input hashes) in a stable order. BT-6:
	// the per-fragment sections are gone; the version now folds each skill
	// (name=hash), the single template hash, the memory_md hash, and each variable (name=hash), so the
	// ETag changes iff the template, a variable value, the memory set, or the skill set changes.
	vb := strings.builder_make()
	defer strings.builder_destroy(&vb)
	for item in skills_list {
		strings.write_string(&vb, item.name); strings.write_byte(&vb, '=')
		strings.write_string(&vb, item.hash); strings.write_byte(&vb, '\n')
	}
	strings.write_string(&vb, "template="); strings.write_string(&vb, template_hash); strings.write_byte(&vb, '\n')
	strings.write_string(&vb, "memory_md="); strings.write_string(&vb, agent_mem_hash); strings.write_byte(&vb, '\n')
	for v in variables {
		strings.write_string(&vb, v.name); strings.write_byte(&vb, '=')
		strings.write_string(&vb, v.hash); strings.write_byte(&vb, '\n')
	}
	version := bootstrap_fragment_hash(strings.to_string(vb))

	b := strings.builder_make()
	strings.write_string(&b, "{\"protocol\":2,\"version\":\"")
	write_service_json_string(&b, version)
	strings.write_string(&b, "\",\"agent_id\":\""); write_service_json_string(&b, agent.agent_id)
	strings.write_string(&b, "\",\"role\":\""); write_service_json_string(&b, "coordinator" if is_coordinator else "worker")
	strings.write_string(&b, "\",\"provider\":\""); write_service_json_string(&b, provider)
	strings.write_string(&b, "\",\"project_id\":\""); write_service_json_string(&b, project_id)
	strings.write_string(&b, "\",\"files\":[{\"kind\":\"AGENTS_MD\",\"relative_path\":\"AGENTS.md\",\"assembly\":[]},{\"kind\":\"MEMORY_MD\",\"relative_path\":\"MEMORY.md\",\"hash\":\"")
	write_service_json_string(&b, agent_mem_hash)
	strings.write_string(&b, "\"}]")

	bootstrap_write_template_and_variables_json(&b, template_hash, variables[:])

	strings.write_string(&b, ",\"skills\":[")
	for item, i in skills_list {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, "{\"kind\":\"SKILL\",\"name\":\"")
		write_service_json_string(&b, item.name)
		strings.write_string(&b, "\",\"target_hint\":\"")
		write_service_json_string(&b, fmt.tprintf(".agents/skills/%s/SKILL.md", item.name))
		strings.write_string(&b, "\",\"hash\":\"")
		write_service_json_string(&b, item.hash)
		strings.write_string(&b, "\"}")
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b), version
}

// bootstrap_memory_applies_agent is the agent-keyed (instance-free) variant of
// bootstrap_memory_applies used by the manifest render. It resolves scope from
// the agent + selected project + the REQUESTING bridge. The manifest is not
// per-instance, but the hub authenticates the calling bridge, so bridge_id is
// known at render time and bridge scope is honored the same way as every other
// dimension (empty list = applies to all; non-empty = the requesting bridge must
// be a member). bridge_id is threaded into the cache key so a bridge-scoped skill
// cannot bleed across bridges. An empty bridge_id (an unattributable request)
// safely excludes any bridge-scoped memory.
bootstrap_memory_applies_agent :: proc(m: domain.Memory, agent: domain.Agent, owner: domain.User_ID, project_id: domain.Project_ID, bridge_id: string) -> bool {
	if m.status != "active" do return false
	if !memory_list_matches(m.agent_ids, agent.agent_id) do return false
	if !memory_project_list_matches(m.project_ids, project_id) do return false
	if len(m.template_ids) > 0 {
		if agent.owner_user_id != owner || !memory_list_contains(m.template_ids, agent.template_id) do return false
	}
	if !memory_list_matches(m.bridge_ids, bridge_id) do return false
	return true
}


// A disabled bridge retains its running agents but accepts no new launches.
// Entitlement refresh can clear a suspension; read the current flag afterwards.
require_launch_bridge_enabled :: proc(service: ^Agent_Service, bridge: domain.Bridge) -> domain.Domain_Error {
	if service.entitlements.lookup == nil && bridge.plan_disabled_at == "" do return {}
	entitlements, err := domain.lookup_entitlements(service.entitlements, string(bridge.owner_user_id))
	if err.code != .None do return err
	current, found, current_err := iface.bridge_get_bridge(service.bridges, bridge.bridge_id)
	if !found do return current_err
	defer domain.bridge_destroy(&current)
	if current.plan_disabled_at == "" do return {}
	count, count_err := iface.bridge_count_active_by_owner(service.bridges, bridge.owner_user_id)
	if count_err.code != .None do return count_err
	return domain.plan_limit_error("max_bridges", entitlements.max_bridges, count, "Current")
}
