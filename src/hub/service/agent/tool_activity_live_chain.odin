package agent

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:time"
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
	snapshot: json.Value,
	availability: string,
}
Tool_Live_Chain_Snapshot :: struct {
	chain_id: string,
	next_cursor: string,
	roster_token: string,
	members: []Tool_Live_Chain_Member,
}
tool_live_chain_snapshot :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, chain_id: string, cursor: string = "") -> (string, bool, domain.Domain_Error) {
    page_slot := tool_live_chain_admit(&service.tool_live, auth.user_id)
    if page_slot < 0 do return "", false, domain.domain_error(.Bridge_Busy,"live chain page capacity exceeded")
    defer tool_live_chain_release(&service.tool_live,page_slot)
    deadline := time.time_add(time.now(),TOOL_LIVE_TIMEOUT)
	chain, found, err := iface.taskchain_get_chain(service.taskchains, domain.Task_Chain_ID(chain_id))
	if !found do return "", false, err
	if ok, own_err := ownership.require_owner(auth, chain.owner_user_id); !ok do return "", false, own_err
	members: []domain.Task_Chain_Member
    mem_err: domain.Domain_Error
    if service.taskchains != nil && service.taskchains.list_tool_members_by_chain != nil {
        members, mem_err = service.taskchains.list_tool_members_by_chain(service.taskchains.ctx, chain.chain_id, chain.owner_user_id)
    } else { members, mem_err = iface.taskchain_list_members_by_chain(service.taskchains, chain.chain_id, chain.owner_user_id) }
    if len(members) > 256 do return "", false, domain.domain_error(.Validation_Failed, "live roster exceeds 256 members")
	if mem_err.code != .None do return "", false, mem_err
	if auth.kind == .Instance_Token {
		caller, caller_ok, _ := get_instance(service, auth, auth.agent_instance_id)
		allowed := caller_ok && (caller.chain_id == chain_id || chain.coordinator_agent_instance_id == caller.agent_instance_id)
		for m in members {
			if caller_ok && m.chain_id == chain.chain_id && m.owner_user_id == chain.owner_user_id && m.agent_instance_id == auth.agent_instance_id && m.role == "coordinator" do allowed = true
		}
		if !allowed do return "", false, domain.domain_error(.Forbidden, "instance is not currently in this chain")
	}
	insts: []domain.Agent_Instance
    list_err: domain.Domain_Error
    if service.agents != nil && service.agents.list_tool_instances_by_chain != nil {
        insts, list_err = service.agents.list_tool_instances_by_chain(service.agents.ctx, chain.owner_user_id, chain_id)
    } else { insts, list_err = iface.agent_list_instances_by_chain(service.agents, chain.owner_user_id, chain_id) }
	if len(insts) > 256 do return "", false, domain.domain_error(.Validation_Failed, "live roster exceeds 256 instances")
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
		inst, ok, _ := tool_live_instance(service, id)
		if ok && inst.owner_user_id == chain.owner_user_id do append(&selected, inst)
	}

    if len(selected) > 256 do return "", false, domain.domain_error(.Validation_Failed, "live tool roster exceeds 256-instance capacity")
    slice.sort_by(selected[:], proc(a,b: domain.Agent_Instance) -> bool { return a.agent_instance_id < b.agent_instance_id })
    // Bounded non-security roster fingerprint. Every page is independently
    // authorized; a token change tells UI to restart its initial page set.
    hash: u64 = 14695981039346656037
    for inst in selected {
        for c in transmute([]u8)inst.agent_instance_id { hash = (hash ~ u64(c)) * 1099511628211 }
        hash = (hash ~ 255) * 1099511628211
    }
    start := 0
    if cursor != "" {
        for start < len(selected) && selected[start].agent_instance_id <= cursor do start += 1
    }
    end := min(start + 8, len(selected))
    out := Tool_Live_Chain_Snapshot{roster_token = fmt.tprintf("%016x", hash), chain_id = chain_id,
        members = make([]Tool_Live_Chain_Member, end-start, context.temp_allocator)}
    if end < len(selected) && end > start do out.next_cursor = selected[end-1].agent_instance_id
    for inst, i in selected[start:end] {
        body, available, _ := tool_live_request_snapshot(service, inst, time.diff(time.now(),deadline))
        snap: json.Value = json.Null{}
        if available { snap, _ = json.parse_string(body, .JSON, true, context.temp_allocator); delete(body) }
        out.members[i] = {agent_id = inst.agent_id, instance_id = inst.agent_instance_id,
            display_name = inst.display_name, snapshot = snap, availability = "ready" if available else "offline"}
    }
    bytes, _ := json.marshal(out)
    return string(bytes), true, {}
}
