package hub_ct_notification_gating_test

// Phase 3 (CT-6, CT-8) notification-gating verification.
//
// Asserts that notifications are GATED on the recipient's PERSISTED current_task
// (single source of truth) and state the correct work-vs-review action (R8):
//   - a status-change notify to an instance whose current task is a DIFFERENT task
//     is suppressed for that instance (CT-6);
//   - a status-change notify carries the R8 action label;
//   - the actionable read model (which drives the nudger) only emits a row for the
//     recipient's current task and stamps the action (CT-8);
//   - an instance that is BOTH assignee (task A) and reviewer (task B) is only woken
//     for its current task, with the matching action label (R6/R8).

import "core:fmt"
import "core:testing"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import taskchain_service "odin_test:hub/service/taskchain"
import project_service "odin_test:hub/service/project"
import platform "odin_test:hub/platform"

check :: proc(ok: bool, msg: string) { if ok do return; fmt.eprintln("FAIL:", msg); os.exit(1) }

G :: struct {
	chains:     [4]domain.Task_Chain,
	chain_n:    int,
	tasks:      [16]domain.Task,
	task_n:     int,
	deps:       [8]domain.Task_Dependency,
	dep_n:      int,
	instances:  [8]domain.Agent_Instance,
	inst_n:     int,
	cmds:       [32]string,
	cmd_n:      int,
	seq:        int,
}
g: G

gnow :: proc(ctx: rawptr) -> string { _ = ctx; return "2026-07-22T10:00:00Z" }
gid :: proc(ctx: rawptr, prefix: string) -> string { g.seq += 1; return strings.concatenate({prefix, fmt.tprintf("%d", g.seq)}) }

gc_get :: proc(ctx: rawptr, id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	for i in 0..<g.chain_n { if g.chains[i].chain_id == id do return g.chains[i], true, {} }
	return {}, false, domain.domain_error(.Not_Found, "chain")
}
gc_list :: proc(ctx: rawptr, owner: domain.User_ID) -> ([]domain.Task_Chain, domain.Domain_Error) {
	out := make([dynamic]domain.Task_Chain)
	for i in 0..<g.chain_n { if g.chains[i].owner_user_id == owner do append(&out, g.chains[i]) }
	return out[:], {}
}
gt_get :: proc(ctx: rawptr, id: domain.Task_ID) -> (domain.Task, bool, domain.Domain_Error) {
	for i in 0..<g.task_n { if g.tasks[i].task_id == id do return g.tasks[i], true, {} }
	return {}, false, domain.domain_error(.Not_Found, "task")
}
gt_list :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task, domain.Domain_Error) {
	out := make([dynamic]domain.Task)
	for i in 0..<g.task_n { if g.tasks[i].chain_id == chain_id do append(&out, g.tasks[i]) }
	return out[:], {}
}
gd_list :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task_Dependency, domain.Domain_Error) {
	out := make([dynamic]domain.Task_Dependency)
	for i in 0..<g.dep_n { if g.deps[i].chain_id == chain_id do append(&out, g.deps[i]) }
	return out[:], {}
}
ga_get :: proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	for i in 0..<g.inst_n { if g.instances[i].agent_instance_id == id do return g.instances[i], true, {} }
	return {}, false, domain.domain_error(.Not_Found, "inst")
}
ga_by_bridge :: proc(ctx: rawptr, bridge_id: string) -> ([]domain.Agent_Instance, domain.Domain_Error) {
	out := make([dynamic]domain.Agent_Instance)
	for i in 0..<g.inst_n { if g.instances[i].bridge_id == bridge_id do append(&out, g.instances[i]) }
	return out[:], {}
}
gsink :: proc(ctx: rawptr, cmd: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	g.cmds[g.cmd_n] = strings.clone(cmd.body_json); g.cmd_n += 1
	return true, {}
}

aref :: proc(id: string) -> string { return strings.concatenate({`{"type":"agent_instance","agent_instance_id":"`, id, `"}`}) }
rref :: proc(id: string) -> string { return strings.concatenate({`[{"type":"agent_instance","agent_instance_id":"`, id, `"}]`}) }

make_service :: proc() -> taskchain_service.Taskchain_Service {
	repo := iface.Taskchain_Repository{ctx = nil, get_chain = gc_get, list_chains_by_owner = gc_list, get_task = gt_get, list_tasks_by_chain = gt_list, list_dependencies_by_chain = gd_list}
	// Leak the repo/agents structs onto the heap so their addresses stay valid for
	// the service lifetime (Odin: locals would dangle). Simplest: use static.
	@(static) repo_s: iface.Taskchain_Repository
	@(static) agents_s: iface.Agent_Repository
	repo_s = repo
	agents_s = iface.Agent_Repository{ctx = nil, get_instance = ga_get, list_instances_by_bridge = ga_by_bridge}
	@(static) clock_s: platform.Clock
	@(static) ids_s: platform.ID_Generator
	clock_s = platform.Clock{ctx = nil, now = gnow}
	ids_s = platform.ID_Generator{ctx = nil, generate = gid}
	sink := project_service.Bridge_Command_Sink{ctx = nil, send_runtime_command = gsink}
	return taskchain_service.new_taskchain_service_with_runtime(&repo_s, &agents_s, sink, &clock_s, &ids_s)
}

cmd_targets :: proc(needle: string) -> int {
	n := 0
	for i in 0..<g.cmd_n { if strings.contains(g.cmds[i], needle) do n += 1 }
	return n
}

@(test)
test_hub_ct_notification_gating_test :: proc(t: ^testing.T) {
	_ = t
	main()
}

main :: proc() {
	test_status_notify_gated_and_labeled()
	test_actionable_gated_and_labeled()
	fmt.println("PASS: hub CT notification gating (CT-6/CT-8)")
}

// A dual-role instance inst_x is assignee of task_work and reviewer of task_rev.
// Its persisted current task is task_work (role work). A status-change notify on
// task_rev (entering In_Validation) must NOT wake inst_x (its current task is
// task_work), while a notify on task_work carries action=work.
test_status_notify_gated_and_labeled :: proc() {
	g = G{}
	service := make_service()

	g.chains[0] = domain.Task_Chain{chain_id = "chain_1", owner_user_id = "alice", publish_state = .Published, status = .Active}
	g.chain_n = 1
	g.tasks[0] = domain.Task{task_id = "task_work", chain_id = "chain_1", owner_user_id = "alice", publish_state = .Published, status = .In_Progress, priority = .P1, assignee_ref_json = aref("inst_x"), updated_at = "t1"}
	g.tasks[1] = domain.Task{task_id = "task_rev", chain_id = "chain_1", owner_user_id = "alice", publish_state = .Published, status = .In_Validation, priority = .P1, assignee_ref_json = aref("inst_author"), reviewer_refs_json = rref("inst_x"), updated_at = "t2"}
	g.task_n = 2
	// inst_x current task is task_work (work). inst_author on its own bridge.
	g.instances[0] = domain.Agent_Instance{agent_instance_id = "inst_x", owner_user_id = "alice", bridge_id = "brg_x", current_task_id = "task_work", current_task_role = .Work}
	g.instances[1] = domain.Agent_Instance{agent_instance_id = "inst_author", owner_user_id = "alice", bridge_id = "brg_a"}
	g.inst_n = 2

	chain, _, _ := gc_get(nil, "chain_1")

	// Notify on task_rev: inst_x is a reviewer but its current task is task_work,
	// so it must be gated out — no command targeting brg_x/inst_x.
	g.cmd_n = 0
	rev, _, _ := gt_get(nil, "task_rev")
	taskchain_service.notify_task_status_change(&service, contracts.Auth_Context{}, rev, chain)
	check(cmd_targets("inst_x") == 0, "reviewer whose current task differs must be gated out of status notify")

	// Notify on task_work: inst_x's current task — must be delivered with action=work.
	g.cmd_n = 0
	work, _, _ := gt_get(nil, "task_work")
	taskchain_service.notify_task_status_change(&service, contracts.Auth_Context{}, work, chain)
	check(cmd_targets("inst_x") == 1, "assignee must be woken for its current task")
	check(cmd_targets(`"action":"work"`) == 1, "status notify must state action=work (R8)")
	check(cmd_targets(`"message":"Work ready`) == 1, "status notify must carry a human-readable work message (R8)")
}

// The actionable read model (drives the nudger) must only emit a row for the
// recipient's current task and stamp the action label (CT-8).
test_actionable_gated_and_labeled :: proc() {
	g = G{}
	service := make_service()

	g.chains[0] = domain.Task_Chain{chain_id = "chain_1", owner_user_id = "alice", publish_state = .Published, status = .Active}
	g.chain_n = 1
	// Two work tasks for inst_x; current task is task_a only.
	g.tasks[0] = domain.Task{task_id = "task_a", chain_id = "chain_1", owner_user_id = "alice", publish_state = .Published, status = .In_Progress, priority = .P0, assignee_ref_json = aref("inst_x"), updated_at = "t1"}
	g.tasks[1] = domain.Task{task_id = "task_b", chain_id = "chain_1", owner_user_id = "alice", publish_state = .Published, status = .Assigned, priority = .P1, assignee_ref_json = aref("inst_x"), updated_at = "t2"}
	g.task_n = 2
	g.instances[0] = domain.Agent_Instance{agent_instance_id = "inst_x", owner_user_id = "alice", bridge_id = "brg_x", current_task_id = "task_a", current_task_role = .Work}
	g.inst_n = 1

	items, err := taskchain_service.actionable_tasks_for_instances(&service, "alice", []string{"inst_x"})
	check(err.code == .None, "actionable scan ok")
	// Only task_a (current task) should appear; task_b is gated out.
	count_a := 0; count_b := 0; action_a := ""
	for it in items {
		if it.task_id == "task_a" { count_a += 1; action_a = it.action }
		if it.task_id == "task_b" { count_b += 1 }
	}
	check(count_a == 1, "actionable must include the recipient's current task")
	check(count_b == 0, "actionable must gate out a non-current task")
	check(action_a == "work", "actionable row must carry the work action label")
}
