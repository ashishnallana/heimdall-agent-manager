package hub_readonly_cross_chain_test

// REQ-SEC-3 (T14): read-only cross-chain access for agents of the SAME OWNER.
//
// An Instance_Token agent may READ any chain/task/comment-metadata belonging to
// its OWN owner, even a chain it is NOT a member/coordinator of (e.g. the Curator
// or a worker inspecting another coordinator's chain). WRITES stay membership-
// gated exactly as before, and cross-OWNER access is still Not_Found (owner
// isolation is preserved — the membership gate is lifted on reads, never the
// owner gate).
//
// Setup: owner "alice" has two chains — X (coordinated by inst_a) and Y
// (coordinated by inst_b). inst_a is a member of X ONLY. Assertions:
//   1. inst_a can READ Y (same owner, non-member): list_chains sees Y;
//      get_chain_for_read(Y) ok; list_tasks(Y) ok; get_task_for_read(taskY) ok;
//      list_chain_members / list_chain_dependencies ok.
//   2. inst_a CANNOT WRITE to Y: create_task -> Forbidden (the closed hole);
//      the membership-gated get_chain/get_task still Forbid; change_chain_status
//      -> Forbidden.
//   3. Owner isolation: bob's Instance_Token gets Not_Found on Y and its task,
//      and list_chains returns none of alice's chains.
//   4. Member paths still work: inst_b (coordinator of Y) can create_task on Y;
//      inst_a can create_task on its own chain X.

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
	chains:         [16]domain.Task_Chain,
	chain_count:    int,
	members:        [32]domain.Task_Chain_Member,
	member_count:   int,
	instances:      [16]domain.Agent_Instance,
	instance_count: int,
	tasks:          [32]domain.Task,
	task_count:     int,
	seq:            int,
}

now_proc :: proc(ctx: rawptr) -> string { _ = ctx; return "2026-09-15T10:00:00Z" }
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
chains_by_owner :: proc(ctx: rawptr, owner: domain.User_ID) -> ([]domain.Task_Chain, domain.Domain_Error) {
	r := (^Repo)(ctx)
	out := make([dynamic]domain.Task_Chain)
	for i in 0..<r.chain_count { if r.chains[i].owner_user_id == owner do append(&out, r.chains[i]) }
	return out[:], domain.Domain_Error{}
}
task_save :: proc(ctx: rawptr, t: domain.Task) -> (domain.Task, bool, domain.Domain_Error) {
	r := (^Repo)(ctx)
	for i in 0..<r.task_count { if r.tasks[i].task_id == t.task_id { r.tasks[i] = t; return t, true, domain.Domain_Error{} } }
	r.tasks[r.task_count] = t; r.task_count += 1; return t, true, domain.Domain_Error{}
}
task_get :: proc(ctx: rawptr, id: domain.Task_ID) -> (domain.Task, bool, domain.Domain_Error) {
	r := (^Repo)(ctx)
	for i in 0..<r.task_count { if r.tasks[i].task_id == id do return r.tasks[i], true, domain.Domain_Error{} }
	return domain.Task{}, false, domain.domain_error(.Not_Found, "task not found")
}
tasks_by_chain :: proc(ctx: rawptr, id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task, domain.Domain_Error) {
	r := (^Repo)(ctx)
	out := make([dynamic]domain.Task)
	for i in 0..<r.task_count { if r.tasks[i].chain_id == id do append(&out, r.tasks[i]) }
	return out[:], domain.Domain_Error{}
}
member_save :: proc(ctx: rawptr, m: domain.Task_Chain_Member) -> (domain.Task_Chain_Member, bool, domain.Domain_Error) {
	r := (^Repo)(ctx)
	for i in 0..<r.member_count { if r.members[i].chain_id == m.chain_id && r.members[i].agent_instance_id == m.agent_instance_id { r.members[i] = m; return m, true, domain.Domain_Error{} } }
	r.members[r.member_count] = m; r.member_count += 1; return m, true, domain.Domain_Error{}
}
member_list :: proc(ctx: rawptr, id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task_Chain_Member, domain.Domain_Error) {
	r := (^Repo)(ctx)
	out := make([dynamic]domain.Task_Chain_Member)
	for i in 0..<r.member_count { if r.members[i].chain_id == id do append(&out, r.members[i]) }
	return out[:], domain.Domain_Error{}
}
chains_by_coordinator :: proc(ctx: rawptr, agent_instance_id: string, owner: domain.User_ID) -> ([]domain.Task_Chain, domain.Domain_Error) {
	r := (^Repo)(ctx)
	out := make([dynamic]domain.Task_Chain)
	for ci in 0..<r.chain_count {
		c := r.chains[ci]
		if c.owner_user_id != owner do continue
		for mi in 0..<r.member_count {
			m := r.members[mi]
			if m.chain_id == c.chain_id && m.role == "coordinator" && m.agent_instance_id == agent_instance_id { append(&out, c); break }
		}
	}
	return out[:], domain.Domain_Error{}
}
dependencies_by_chain :: proc(ctx: rawptr, id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task_Dependency, domain.Domain_Error) {
	return nil, domain.Domain_Error{}
}
inst_get :: proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	r := (^Repo)(ctx)
	for i in 0..<r.instance_count { if r.instances[i].agent_instance_id == id do return r.instances[i], true, domain.Domain_Error{} }
	return domain.Agent_Instance{}, false, domain.domain_error(.Not_Found, "instance not found")
}

add_instance :: proc(r: ^Repo, id, owner, chain_id: string) {
	r.instances[r.instance_count] = domain.Agent_Instance{agent_instance_id = id, owner_user_id = domain.User_ID(owner), agent_id = "agt_a", chain_id = chain_id}
	r.instance_count += 1
}
add_member :: proc(r: ^Repo, chain_id, instance_id, owner, role: string) {
	r.members[r.member_count] = domain.Task_Chain_Member{chain_id = domain.Task_Chain_ID(chain_id), agent_instance_id = instance_id, owner_user_id = domain.User_ID(owner), role = role, created_at = "2026-09-15T09:00:00Z"}
	r.member_count += 1
}

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln("FAIL:", message); os.exit(1) }

@(test)
test_hub_readonly_cross_chain_test :: proc(t: ^testing.T) {
	_ = t
	main()
}

main :: proc() {
	data: Repo
	clock := platform.Clock{ctx = nil, now = now_proc}
	ids := platform.ID_Generator{ctx = rawptr(&data), generate = id_proc}
	repo := iface.Taskchain_Repository{
		ctx = rawptr(&data),
		get_chain = chain_get, save_chain = chain_save, list_chains_by_owner = chains_by_owner,
		save_task = task_save, get_task = task_get, list_tasks_by_chain = tasks_by_chain,
		save_member = member_save, list_members_by_chain = member_list, list_chains_by_coordinator = chains_by_coordinator,
		list_dependencies_by_chain = dependencies_by_chain,
	}
	agents := iface.Agent_Repository{ctx = rawptr(&data), get_instance = inst_get}
	service := taskchain_service.new_taskchain_service(&repo, &agents, &clock, &ids)

	// Owner alice: chain X (coordinated by inst_a) and chain Y (coordinated by inst_b).
	// Chains are Draft so create_task takes no notification path.
	_, _, _ = chain_save(rawptr(&data), domain.Task_Chain{chain_id = "chain_x", owner_user_id = "alice", title = "X", publish_state = .Draft, status = .Active, coordinator_agent_instance_id = "inst_a", created_at = "t", updated_at = "t"})
	_, _, _ = chain_save(rawptr(&data), domain.Task_Chain{chain_id = "chain_y", owner_user_id = "alice", title = "Y", publish_state = .Draft, status = .Active, coordinator_agent_instance_id = "inst_b", created_at = "t", updated_at = "t"})
	add_instance(&data, "inst_a", "alice", "chain_x")
	add_instance(&data, "inst_b", "alice", "chain_y")
	add_member(&data, "chain_x", "inst_a", "alice", "coordinator")
	add_member(&data, "chain_y", "inst_b", "alice", "coordinator")
	// A task in Y (created by Y's coordinator context directly in the repo).
	_, _, _ = task_save(rawptr(&data), domain.Task{task_id = "task_y1", chain_id = "chain_y", owner_user_id = "alice", title = "y task", publish_state = .Draft, state = .Backlog, kind = .Task, brief_json = "{}"})

	// inst_a is a member of X only; it is a NON-member of Y (same owner alice).
	auth_a := contracts.Auth_Context{kind = .Instance_Token, user_id = "alice", agent_instance_id = "inst_a"}

	// ---- 1. READ Y as same-owner NON-member: allowed ----
	all_chains, lc_err := taskchain_service.list_chains(&service, auth_a)
	check(lc_err.code == .None, "1: list_chains must succeed")
	saw_x := false; saw_y := false
	for c in all_chains { if c.chain_id == "chain_x" do saw_x = true; if c.chain_id == "chain_y" do saw_y = true }
	check(saw_x && saw_y, "1: a same-owner agent must see ALL owner chains (incl. non-member chain Y)")

	_, gc_ok, gc_err := taskchain_service.get_chain_for_read(&service, auth_a, "chain_y")
	check(gc_ok && gc_err.code == .None, "1: get_chain_for_read(Y) must succeed for same-owner non-member")

	y_tasks, lt_err := taskchain_service.list_tasks(&service, auth_a, "chain_y")
	check(lt_err.code == .None && len(y_tasks) == 1, "1: list_tasks(Y) must succeed and return Y's task")

	_, gt_ok, gt_err := taskchain_service.get_task_for_read(&service, auth_a, "task_y1")
	check(gt_ok && gt_err.code == .None, "1: get_task_for_read(task in Y) must succeed for same-owner non-member")

	_, lm_err := taskchain_service.list_chain_members(&service, auth_a, "chain_y")
	check(lm_err.code == .None, "1: list_chain_members(Y) must succeed for same-owner non-member")
	_, ld_err := taskchain_service.list_chain_dependencies(&service, auth_a, "chain_y")
	check(ld_err.code == .None, "1: list_chain_dependencies(Y) must succeed for same-owner non-member")

	// ---- 2. WRITE to Y as non-member: denied ----
	_, ct_ok, ct_err := taskchain_service.create_task(&service, auth_a, taskchain_service.Create_Task_Input{chain_id = "chain_y", title = "sneak"})
	check(!ct_ok && ct_err.code == .Forbidden, "2: create_task on non-member chain Y must be Forbidden (closed hole)")

	// The membership-gated authorizers still block a non-member (writers use these).
	_, gcs_ok, gcs_err := taskchain_service.get_chain(&service, auth_a, "chain_y")
	check(!gcs_ok && gcs_err.code == .Forbidden, "2: strict get_chain(Y) must remain Forbidden for a non-member")
	_, gts_ok, gts_err := taskchain_service.get_task(&service, auth_a, "task_y1")
	check(!gts_ok && gts_err.code == .Forbidden, "2: strict get_task(Y task) must remain Forbidden for a non-member")
	_, ccs_ok, ccs_err := taskchain_service.change_chain_status(&service, auth_a, "chain_y", .Completed)
	check(!ccs_ok && ccs_err.code == .Forbidden, "2: change_chain_status(Y) must be Forbidden for a non-member")

	// ---- 3. Owner isolation: bob (different owner) gets Not_Found, never Forbidden ----
	auth_bob := contracts.Auth_Context{kind = .Instance_Token, user_id = "bob", agent_instance_id = "inst_bob"}
	bob_chains, _ := taskchain_service.list_chains(&service, auth_bob)
	check(len(bob_chains) == 0, "3: cross-owner agent must see NONE of alice's chains")
	_, bgc_ok, bgc_err := taskchain_service.get_chain_for_read(&service, auth_bob, "chain_y")
	check(!bgc_ok && bgc_err.code == .Not_Found, "3: cross-owner get_chain_for_read must be Not_Found (no leak)")
	_, bgt_ok, bgt_err := taskchain_service.get_task_for_read(&service, auth_bob, "task_y1")
	check(!bgt_ok && bgt_err.code == .Not_Found, "3: cross-owner get_task_for_read must be Not_Found (no leak)")
	_, blt_err := taskchain_service.list_tasks(&service, auth_bob, "chain_y")
	check(blt_err.code == .Not_Found, "3: cross-owner list_tasks must be Not_Found")

	// ---- 4. Member/coordinator write paths still work ----
	auth_b := contracts.Auth_Context{kind = .Instance_Token, user_id = "alice", agent_instance_id = "inst_b"}
	_, cby_ok, cby_err := taskchain_service.create_task(&service, auth_b, taskchain_service.Create_Task_Input{chain_id = "chain_y", title = "by coordinator"})
	check(cby_ok, fmt.tprintf("4: Y's coordinator must be able to create_task on Y: %s", cby_err.message))
	_, cax_ok, cax_err := taskchain_service.create_task(&service, auth_a, taskchain_service.Create_Task_Input{chain_id = "chain_x", title = "own chain"})
	check(cax_ok, fmt.tprintf("4: a member/coordinator must be able to create_task on its own chain X: %s", cax_err.message))

	fmt.println("PASS: hub read-only cross-chain access (same-owner reads ok, writes gated, cross-owner Not_Found)")
}
