package hub_chain_member_instance_only_test

// REQ-TASKCHAIN-MEMBER-INSTANCE-ONLY-1:
// Ensures that only agent instance IDs (inst_...) are allowed as chain members,
// and agent template IDs (agt_...) are never recorded as members.
//
// Tests:
// 1. create_chain with coordinator_agent_id = "agt_xxx" does NOT insert an agt_ member.
// 2. create_chain with coordinator_agent_id = "inst_xxx" DOES insert the inst_ member as coordinator.
// 3. add_chain_member rejects agent_instance_id starting with "agt_" with Validation_Failed.
// 4. list_chain_members filters out any legacy phantom "agt_" records.
// 5. set_chain_coordinator removes any legacy "agt_" records during coordinator update.

import "core:fmt"
import "core:testing"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import taskchain_service "odin_test:hub/service/taskchain"
import platform "odin_test:hub/platform"

Repo :: struct {
	chains: [16]domain.Task_Chain,
	chain_count: int,
	members: [32]domain.Task_Chain_Member,
	member_count: int,
	instances: [16]domain.Agent_Instance,
	instance_count: int,
	seq: int,
}

now_proc :: proc(ctx: rawptr) -> string { _ = ctx; return "2026-07-22T10:00:00Z" }
id_proc :: proc(ctx: rawptr, prefix: string) -> string {
	r := (^Repo)(ctx); r.seq += 1; return strings.concatenate({prefix, fmt.tprintf("%d", r.seq)})
}

chain_get :: proc(ctx: rawptr, id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	r := (^Repo)(ctx)
	for i in 0..<r.chain_count { if r.chains[i].chain_id == id do return r.chains[i], true, domain.Domain_Error{} }
	return domain.Task_Chain{}, false, domain.domain_error(.Not_Found, "chain not found")
}
chain_save :: proc(ctx: rawptr, c: domain.Task_Chain) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	r := (^Repo)(ctx)
	for i in 0..<r.chain_count { if r.chains[i].chain_id == c.chain_id { r.chains[i] = c; return c, true, domain.Domain_Error{} } }
	r.chains[r.chain_count] = c; r.chain_count += 1; return c, true, domain.Domain_Error{}
}
member_save :: proc(ctx: rawptr, m: domain.Task_Chain_Member) -> (domain.Task_Chain_Member, bool, domain.Domain_Error) {
	r := (^Repo)(ctx)
	for i in 0..<r.member_count {
		if r.members[i].chain_id == m.chain_id && r.members[i].agent_instance_id == m.agent_instance_id {
			r.members[i] = m; return m, true, domain.Domain_Error{}
		}
	}
	r.members[r.member_count] = m; r.member_count += 1; return m, true, domain.Domain_Error{}
}
member_remove :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, agent_instance_id: string, owner: domain.User_ID) -> (bool, domain.Domain_Error) {
	_ = owner
	r := (^Repo)(ctx)
	found := -1
	for i in 0..<r.member_count {
		if r.members[i].chain_id == chain_id && r.members[i].agent_instance_id == agent_instance_id {
			found = i; break
		}
	}
	if found < 0 do return false, domain.domain_error(.Not_Found, "member not found")
	for i in found..<r.member_count - 1 { r.members[i] = r.members[i + 1] }
	r.member_count -= 1
	return true, domain.Domain_Error{}
}
member_list :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task_Chain_Member, domain.Domain_Error) {
	_ = owner
	r := (^Repo)(ctx)
	res := make([dynamic]domain.Task_Chain_Member, context.allocator)
	for i in 0..<r.member_count {
		if r.members[i].chain_id == chain_id do append(&res, r.members[i])
	}
	return res[:], domain.Domain_Error{}
}

agent_inst_get :: proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	r := (^Repo)(ctx)
	for i in 0..<r.instance_count { if r.instances[i].agent_instance_id == id do return r.instances[i], true, domain.Domain_Error{} }
	return domain.Agent_Instance{}, false, domain.domain_error(.Not_Found, "instance not found")
}

check :: proc(ok: bool, msg: string) {
	if !ok { fmt.eprintln("FAIL:", msg); os.exit(1) }
}

@(test)
test_hub_chain_member_instance_only_test :: proc(t: ^testing.T) {
	_ = t
	main()
}

main :: proc() {
	data := Repo{}
	clock := platform.Clock{now = now_proc, ctx = rawptr(&data)}
	ids := platform.ID_Generator{generate = id_proc, ctx = rawptr(&data)}
	repo := iface.Taskchain_Repository{
		ctx = rawptr(&data),
		get_chain = chain_get,
		save_chain = chain_save,
		save_member = member_save,
		remove_member = member_remove,
		list_members_by_chain = member_list,
	}
	agents := iface.Agent_Repository{
		ctx = rawptr(&data),
		get_instance = agent_inst_get,
	}
	service := taskchain_service.new_taskchain_service(&repo, &agents, &clock, &ids)

	user_auth := contracts.Auth_Context{kind = .Session, user_id = "alice"}

	// --- 1. create_chain with agt_ coordinator_agent_id MUST NOT create an agt_ member ---
	chain1, ok1, err1 := taskchain_service.create_chain(&service, user_auth, taskchain_service.Create_Chain_Input{
		title = "test chain with agt",
		coordinator_agent_id = "agt_template_123",
	})
	check(ok1, err1.message)
	members1, _ := member_list(rawptr(&data), chain1.chain_id, "alice")
	check(len(members1) == 0, fmt.tprintf("Expected 0 members in chain1, got %d", len(members1)))
	check(chain1.coordinator_agent_instance_id == "", "Expected empty coordinator mirror column for agt template")

	// --- 2. create_chain with inst_ coordinator_agent_id DOES create coordinator member ---
	chain2, ok2, err2 := taskchain_service.create_chain(&service, user_auth, taskchain_service.Create_Chain_Input{
		title = "test chain with inst",
		coordinator_agent_id = "inst_coord_valid",
	})
	check(ok2, err2.message)
	members2, _ := member_list(rawptr(&data), chain2.chain_id, "alice")
	check(len(members2) == 1, fmt.tprintf("Expected 1 member in chain2, got %d", len(members2)))
	check(members2[0].agent_instance_id == "inst_coord_valid", "Expected coordinator to be inst_coord_valid")
	check(members2[0].role == "coordinator", "Expected role coordinator")
	check(chain2.coordinator_agent_instance_id == "inst_coord_valid", "Expected coordinator mirror column stamped")

	// --- 3. add_chain_member rejects agt_ agent_instance_id ---
	inst_auth := contracts.Auth_Context{kind = .Instance_Token, user_id = "alice", agent_instance_id = "inst_coord_valid"}
	_, add_ok, add_err := taskchain_service.add_chain_member(&service, inst_auth, chain2.chain_id, "agt_invalid_member", "worker")
	check(!add_ok, "Expected add_chain_member to fail for agt_ ID")
	check(add_err.code == .Validation_Failed, "Expected Validation_Failed error code")

	// --- 4. list_chain_members filters out legacy phantom agt_ records ---
	// Manually inject a legacy agt_ record into repo
	legacy_member := domain.Task_Chain_Member{
		chain_id = chain2.chain_id,
		agent_instance_id = "agt_legacy_phantom",
		role = "member",
		owner_user_id = "alice",
		created_at = "2026-07-22T10:00:00Z",
	}
	_, _, _ = member_save(rawptr(&data), legacy_member)
	raw_members, _ := member_list(rawptr(&data), chain2.chain_id, "alice")
	check(len(raw_members) == 2, "Expected 2 raw members in repo")

	filtered_members, list_err := taskchain_service.list_chain_members(&service, user_auth, chain2.chain_id)
	check(list_err.code == .None, "Expected list_chain_members to succeed")
	check(len(filtered_members) == 1, fmt.tprintf("Expected 1 filtered member, got %d", len(filtered_members)))
	check(filtered_members[0].agent_instance_id == "inst_coord_valid", "Expected inst_coord_valid in filtered members")

	// --- 5. set_chain_coordinator purges legacy agt_ records ---
	new_coord_inst := domain.Agent_Instance{
		agent_instance_id = "inst_coord_new",
		owner_user_id = "alice",
		chain_id = string(chain2.chain_id),
	}
	data.instances[data.instance_count] = new_coord_inst
	data.instance_count += 1

	updated_chain, upd_ok, upd_err := taskchain_service.update_chain_coordinator(&service, inst_auth, chain2.chain_id, "inst_coord_new")
	check(upd_ok, upd_err.message)
	check(updated_chain.coordinator_agent_instance_id == "inst_coord_new", "Expected new coordinator stamped")

	raw_members_after, _ := member_list(rawptr(&data), chain2.chain_id, "alice")
	for m in raw_members_after {
		check(!strings.has_prefix(m.agent_instance_id, "agt_"), fmt.tprintf("Found unexpected agt_ member %s in repo after set_chain_coordinator", m.agent_instance_id))
	}

	fmt.println("PASS: REQ-TASKCHAIN-MEMBER-INSTANCE-ONLY-1 verified cleanly")
}
