package agent

import "core:encoding/json"
import "core:sync"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import ownership "odin_test:hub/service/ownership"

// Chain views use current instance bindings, plus explicit coordinator member
// rows (one coordinator can coordinate multiple chains). All run identities stay
// distinct even when workers and reviewers share the same durable agent_id.
Tool_Live_Chain_Member :: struct {
	agent_id: string,
	instance_id: string,
	display_name: string,
	snapshot: Tool_Live_Snapshot,
}
Tool_Live_Chain_Snapshot :: struct {
	chain_id: string,
	epoch: string,
	members: []Tool_Live_Chain_Member,
}
tool_live_chain_snapshot :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, chain_id: string) -> (string, bool, domain.Domain_Error) {
	chain, found, err := iface.taskchain_get_chain(service.taskchains, domain.Task_Chain_ID(chain_id))
	if !found do return "", false, err
	if ok, own_err := ownership.require_owner(auth, chain.owner_user_id); !ok do return "", false, own_err
	members, mem_err := iface.taskchain_list_members_by_chain(service.taskchains, chain.chain_id, chain.owner_user_id)
	if mem_err.code != .None do return "", false, mem_err
	if auth.kind == .Instance_Token {
		caller, caller_ok, _ := get_instance(service, auth, auth.agent_instance_id)
		allowed := caller_ok && (caller.chain_id == chain_id || chain.coordinator_agent_instance_id == caller.agent_instance_id)
		for m in members {
			if caller_ok && m.chain_id == chain.chain_id && m.owner_user_id == chain.owner_user_id && m.agent_instance_id == auth.agent_instance_id && m.role == "coordinator" do allowed = true
		}
		if !allowed do return "", false, domain.domain_error(.Forbidden, "instance is not currently in this chain")
	}
	insts, list_err := iface.agent_list_instances_by_chain(service.agents, chain.owner_user_id, chain_id)
	if list_err.code != .None do return "", false, list_err
	selected := make([dynamic]domain.Agent_Instance, context.temp_allocator)
	for inst in insts {
		if inst.owner_user_id == chain.owner_user_id && inst.chain_id == chain_id do append(&selected, inst)
	}
	coordinators := make([dynamic]string, context.temp_allocator)
	if chain.coordinator_agent_instance_id != "" do append(&coordinators, chain.coordinator_agent_instance_id)
	for m in members {
		if m.role == "coordinator" && m.chain_id == chain.chain_id && m.owner_user_id == chain.owner_user_id do append(&coordinators, m.agent_instance_id)
	}
	for id in coordinators {
		duplicate := false
		for inst in selected do if inst.agent_instance_id == id do duplicate = true
		if duplicate do continue
		inst, ok, _ := get_instance(service, auth, id)
		if ok && inst.owner_user_id == chain.owner_user_id do append(&selected, inst)
	}
	s := &service.tool_live
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	if s.epoch == 0 do tool_live_init(s)
	out := Tool_Live_Chain_Snapshot{chain_id = chain_id, epoch = tool_live_epoch(s),
		members = make([]Tool_Live_Chain_Member, len(selected), context.temp_allocator)}
	for inst, i in selected {
		e, _ := s.entries[inst.agent_instance_id]
		if e != nil && e.owner != string(chain.owner_user_id) do e = nil
		out.members[i] = Tool_Live_Chain_Member{agent_id = inst.agent_id, instance_id = inst.agent_instance_id,
			display_name = inst.display_name, snapshot = tool_live_snapshot_locked(s, inst, e)}
	}
	bytes, _ := json.marshal(out)
	return string(bytes), true, {}
}

