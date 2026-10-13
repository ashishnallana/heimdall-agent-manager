package hub_actionable_tasks_test

import "core:fmt"
import "core:testing"
import "core:os"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import taskchain_service "odin_test:hub/service/taskchain"
import platform "odin_test:hub/platform"

Fake_Repo :: struct {
	chains:     [8]domain.Task_Chain,
	chain_count: int,
	tasks:      [16]domain.Task,
	task_count: int,
	deps:       [16]domain.Task_Dependency,
	dep_count:  int,
	seq:        int,
}

now_str :: proc(ctx: rawptr) -> string { _ = ctx; return "2026-07-22T10:00:00Z" }
gen_id :: proc(ctx: rawptr, prefix: string) -> string { r := (^Fake_Repo)(ctx); r.seq += 1; return strings.concatenate({prefix, fmt.tprintf("%d", r.seq)}) }

c_get :: proc(ctx: rawptr, id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	r := (^Fake_Repo)(ctx)
	for i in 0..<r.chain_count { if r.chains[i].chain_id == id do return r.chains[i], true, {} }
	return {}, false, domain.domain_error(.Not_Found, "no chain")
}
c_list_by_owner :: proc(ctx: rawptr, owner: domain.User_ID) -> ([]domain.Task_Chain, domain.Domain_Error) {
	r := (^Fake_Repo)(ctx)
	out := make([dynamic]domain.Task_Chain)
	for i in 0..<r.chain_count { if r.chains[i].owner_user_id == owner do append(&out, r.chains[i]) }
	return out[:], {}
}
t_list_by_chain :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task, domain.Domain_Error) {
	r := (^Fake_Repo)(ctx)
	out := make([dynamic]domain.Task)
	for i in 0..<r.task_count { if r.tasks[i].chain_id == chain_id do append(&out, r.tasks[i]) }
	return out[:], {}
}
d_list_by_chain :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task_Dependency, domain.Domain_Error) {
	r := (^Fake_Repo)(ctx)
	out := make([dynamic]domain.Task_Dependency)
	for i in 0..<r.dep_count { if r.deps[i].chain_id == chain_id do append(&out, r.deps[i]) }
	return out[:], {}
}

assignee_ref :: proc(id: string) -> string { return strings.concatenate({`{"type":"agent_instance","agent_instance_id":"`, id, `"}`}) }

@(test)
test_hub_actionable_tasks_test :: proc(t: ^testing.T) {
	_ = t
	main()
}

main :: proc() {
	r: Fake_Repo
	clock := platform.Clock{ctx = nil, now = now_str}
	ids := platform.ID_Generator{ctx = rawptr(&r), generate = gen_id}
	repo := iface.Taskchain_Repository{
		ctx = rawptr(&r),
		get_chain = c_get, list_chains_by_owner = c_list_by_owner,
		list_tasks_by_chain = t_list_by_chain, list_dependencies_by_chain = d_list_by_chain,
	}
	service := taskchain_service.new_taskchain_service(&repo, nil, &clock, &ids)

	// One active published chain with three tasks:
	//  t1 assigned -> inst_local (actionable, no deps)
	//  t2 assigned -> inst_local, depends on t1 (actionable but deps not satisfied)
	//  t3 assigned -> inst_remote (belongs to a different bridge; excluded by filter)
	r.chains[0] = domain.Task_Chain{chain_id = "chain_1", owner_user_id = "alice", publish_state = .Published, status = .Active}
	r.chain_count = 1
	r.tasks[0] = domain.Task{task_id = "t1", chain_id = "chain_1", owner_user_id = "alice", publish_state = .Published, status = .Assigned, assignee_ref_json = assignee_ref("inst_local"), updated_at = "2026-07-22T09:00:00Z"}
	r.tasks[1] = domain.Task{task_id = "t2", chain_id = "chain_1", owner_user_id = "alice", publish_state = .Published, status = .Assigned, assignee_ref_json = assignee_ref("inst_local"), updated_at = "2026-07-22T09:00:00Z"}
	r.tasks[2] = domain.Task{task_id = "t3", chain_id = "chain_1", owner_user_id = "alice", publish_state = .Published, status = .Assigned, assignee_ref_json = assignee_ref("inst_remote"), updated_at = "2026-07-22T09:00:00Z"}
	r.task_count = 3
	r.deps[0] = domain.Task_Dependency{task_id = "t2", depends_on_task_id = "t1", chain_id = "chain_1", owner_user_id = "alice"}
	r.dep_count = 1

	// A draft chain and a completed task must be excluded.
	r.chains[1] = domain.Task_Chain{chain_id = "chain_draft", owner_user_id = "alice", publish_state = .Draft, status = .Active}
	r.chain_count = 2
	r.tasks[3] = domain.Task{task_id = "t_draftchain", chain_id = "chain_draft", owner_user_id = "alice", publish_state = .Published, status = .Assigned, assignee_ref_json = assignee_ref("inst_local"), updated_at = "2026-07-22T09:00:00Z"}
	r.tasks[4] = domain.Task{task_id = "t_done", chain_id = "chain_1", owner_user_id = "alice", publish_state = .Published, status = .Completed, assignee_ref_json = assignee_ref("inst_local"), updated_at = "2026-07-22T09:00:00Z"}
	r.task_count = 5

	local := [?]string{"inst_local"}
	items, err := taskchain_service.actionable_tasks_for_instances(&service, "alice", local[:])
	check(err.code == .None, "actionable query must succeed")

	// Expect exactly t1 and t2 (local, active, published, non-terminal). Not t3
	// (remote), not t_draftchain (draft chain), not t_done (terminal).
	check(len(items) == 2, fmt.tprintf("expected 2 actionable tasks, got %d", len(items)))

	saw_t1 := false; saw_t2 := false
	for it in items {
		if string(it.task_id) == "t1" {
			saw_t1 = true
			check(it.deps_satisfied, "t1 has no deps -> deps_satisfied true")
			check(it.target_instance_id == "inst_local", "t1 target must be local assignee")
			check(it.target_role == .Assignee, "t1 target role assignee")
		}
		if string(it.task_id) == "t2" {
			saw_t2 = true
			check(!it.deps_satisfied, "t2 depends on open t1 -> deps_satisfied false")
		}
		check(string(it.task_id) != "t3", "remote task must be excluded")
		check(string(it.task_id) != "t_draftchain", "draft-chain task must be excluded")
		check(string(it.task_id) != "t_done", "terminal task must be excluded")
	}
	check(saw_t1 && saw_t2, "both local actionable tasks must be present")

	// Complete t1; t2 deps now satisfied.
	r.tasks[0].status = .Completed
	items2, _ := taskchain_service.actionable_tasks_for_instances(&service, "alice", local[:])
	for it in items2 {
		if string(it.task_id) == "t2" do check(it.deps_satisfied, "t2 deps satisfied after t1 completes")
	}

	// Empty instance set yields nothing.
	empty, _ := taskchain_service.actionable_tasks_for_instances(&service, "alice", nil)
	check(len(empty) == 0, "no instances -> no actionable tasks")

	fmt.println("PASS: hub actionable tasks read model")
}

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln("FAIL:", message); os.exit(1) }
