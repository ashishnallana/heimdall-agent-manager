package hub_chain_closed_broadcast_test

// MEM-6 (spec §4 #10): closing a chain (completed/cancelled) broadcasts a
// human-readable [Chain Closed] wake to every LIVE chain member so any
// long-running loops/tasks halt. The actor (closer) is not self-woken.

import "core:fmt"
import "core:testing"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import taskchain_service "odin_test:hub/service/taskchain"
import project "odin_test:hub/service/project"
import platform "odin_test:hub/platform"

Repo :: struct {
	chain: domain.Task_Chain,
	seq:   int,
}
Agents :: struct {
	instances: [8]domain.Agent_Instance,
	count:     int,
}
Captured :: struct {
	bodies: [16]string,
	count:  int,
}
captured: Captured

clock_now :: proc(ctx: rawptr) -> string { _ = ctx; return "2026-08-31T10:00:00Z" }
gen_id :: proc(ctx: rawptr, prefix: string) -> string {
	r := (^Repo)(ctx); r.seq += 1
	return strings.concatenate({prefix, fmt.tprintf("%d", r.seq)})
}
chain_get :: proc(ctx: rawptr, id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	r := (^Repo)(ctx)
	if r.chain.chain_id == id do return r.chain, true, {}
	return {}, false, domain.domain_error(.Not_Found, "chain")
}
chain_save :: proc(ctx: rawptr, c: domain.Task_Chain) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	r := (^Repo)(ctx); r.chain = c
	return c, true, {}
}
members_list :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task_Chain_Member, domain.Domain_Error) {
	out := make([dynamic]domain.Task_Chain_Member)
	append(&out, domain.Task_Chain_Member{chain_id = chain_id, agent_instance_id = "inst_a", owner_user_id = owner, role = "worker"})
	append(&out, domain.Task_Chain_Member{chain_id = chain_id, agent_instance_id = "inst_b", owner_user_id = owner, role = "coordinator"})
	return out[:], {}
}
make_repo :: proc(r: ^Repo) -> iface.Taskchain_Repository {
	return iface.Taskchain_Repository{ctx = rawptr(r), get_chain = chain_get, save_chain = chain_save, list_members_by_chain = members_list}
}
agent_get :: proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	a := (^Agents)(ctx)
	for i in 0..<a.count { if a.instances[i].agent_instance_id == id do return a.instances[i], true, {} }
	return {}, false, domain.domain_error(.Not_Found, "instance")
}
make_agents :: proc(a: ^Agents) -> iface.Agent_Repository {
	return iface.Agent_Repository{ctx = rawptr(a), get_instance = agent_get}
}
capture_send :: proc(ctx: rawptr, command: project.Runtime_Command) -> (bool, domain.Domain_Error) {
	captured.bodies[captured.count] = strings.clone(command.body_json)
	captured.count += 1
	return true, {}
}
check :: proc(ok: bool, msg: string) { if ok do return; fmt.eprintln("FAIL:", msg); os.exit(1) }

@(test)
test_hub_chain_closed_broadcast_test :: proc(t: ^testing.T) {
	_ = t
	main()
}

main :: proc() {
	r: Repo
	a: Agents
	a.instances[0] = domain.Agent_Instance{agent_instance_id = "inst_a", owner_user_id = "alice", bridge_id = "brg_1", runtime_status = "running", display_name = "coder #1"}
	a.instances[1] = domain.Agent_Instance{agent_instance_id = "inst_b", owner_user_id = "alice", bridge_id = "brg_1", runtime_status = "idle", display_name = "coord #2"}
	a.count = 2
	r.chain = domain.Task_Chain{chain_id = "chain_1", owner_user_id = "alice", title = "Ship it", publish_state = .Published, status = .Active, coordinator_agent_instance_id = "inst_b"}

	repo := make_repo(&r)
	agents := make_agents(&a)
	clock := platform.Clock{ctx = nil, now = clock_now}
	ids := platform.ID_Generator{ctx = rawptr(&r), generate = gen_id}
	sink := project.Bridge_Command_Sink{ctx = nil, send_runtime_command = capture_send}
	service := taskchain_service.new_taskchain_service_with_runtime(&repo, &agents, sink, &clock, &ids)

	// User (proxy) closes the chain -> both members woken (actor is the user, empty).
	captured.count = 0
	user_auth := contracts.Auth_Context{kind = .Session, user_id = "alice"}
	_, ok, err := taskchain_service.change_chain_status(&service, user_auth, "chain_1", .Completed)
	check(ok, fmt.tprintf("chain complete should succeed: %v", err))
	check(captured.count == 2, fmt.tprintf("chain close must wake both live members, got %d", captured.count))
	joined := strings.concatenate({captured.bodies[0], captured.bodies[1]})
	check(strings.contains(joined, "[Chain Closed]"), "must carry [Chain Closed] tag")
	check(strings.contains(joined, "completed"), "must state completed")
	check(strings.contains(joined, "Ship it"), "must include chain title")
	check(strings.contains(joined, `"origin":"chain_closed"`), "must mark origin chain_closed")
	check(strings.contains(joined, `"agent_instance_id":"inst_a"`) && strings.contains(joined, `"agent_instance_id":"inst_b"`), "both members targeted")

	fmt.println("PASS: hub chain closed broadcast")
}
