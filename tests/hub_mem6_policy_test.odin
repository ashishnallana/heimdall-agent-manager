package hub_mem6_policy_test

// MEM-6: unit tests for the human-readable notice builder + the status-policy
// wakes (paused/cancelled -> assignee + coordinator; validated_good -> coordinator).
// These need only the agent repo (display-name resolution) + a capture sink.

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

Agents :: struct { instances: [8]domain.Agent_Instance, count: int }
Captured :: struct { bodies: [16]string, count: int }
captured: Captured
seqn: int

clock_now :: proc(ctx: rawptr) -> string { _ = ctx; return "2026-08-31T10:00:00Z" }
gen_id :: proc(ctx: rawptr, prefix: string) -> string { seqn += 1; return strings.concatenate({prefix, fmt.tprintf("%d", seqn)}) }
agent_get :: proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	a := (^Agents)(ctx)
	for i in 0..<a.count { if a.instances[i].agent_instance_id == id do return a.instances[i], true, {} }
	return {}, false, domain.domain_error(.Not_Found, "instance")
}
capture_send :: proc(ctx: rawptr, command: project.Runtime_Command) -> (bool, domain.Domain_Error) {
	captured.bodies[captured.count] = strings.clone(command.body_json); captured.count += 1; return true, {}
}
check :: proc(ok: bool, msg: string) { if ok do return; fmt.eprintln("FAIL:", msg); os.exit(1) }

@(test)
test_hub_mem6_policy_test :: proc(t: ^testing.T) {
	_ = t
	main()
}

main :: proc() {
	a: Agents
	a.instances[0] = domain.Agent_Instance{agent_instance_id = "inst_assignee", owner_user_id = "alice", bridge_id = "brg_1", runtime_status = "idle", display_name = "coder #7"}
	a.instances[1] = domain.Agent_Instance{agent_instance_id = "inst_coord", owner_user_id = "alice", bridge_id = "brg_1", runtime_status = "running", display_name = "coord #2"}
	a.count = 2
	repo: iface.Taskchain_Repository
	agents := iface.Agent_Repository{ctx = rawptr(&a), get_instance = agent_get}
	clock := platform.Clock{ctx = nil, now = clock_now}
	ids := platform.ID_Generator{ctx = nil, generate = gen_id}
	sink := project.Bridge_Command_Sink{ctx = nil, send_runtime_command = capture_send}
	service := taskchain_service.new_taskchain_service_with_runtime(&repo, &agents, sink, &clock, &ids)

	task := domain.Task{task_id = "task_1", chain_id = "chain_1", owner_user_id = "alice", publish_state = .Published,
		title = "Fix the thing", status = .Paused, assignee_ref_json = `{"type":"agent_instance","agent_instance_id":"inst_assignee"}`}
	chain := domain.Task_Chain{chain_id = "chain_1", owner_user_id = "alice", coordinator_agent_instance_id = "inst_coord"}
	user_auth := contracts.Auth_Context{kind = .Trusted_Proxy, user_id = "alice"}

	// 1) Builder format + display resolution + excerpt truncation to 20 runes.
	notice := taskchain_service.build_human_readable_task_notice(&service, task, "inst_coord", "Comment", "commented on", "0123456789ABCDEFGHIJ_OVERFLOW")
	defer delete(notice)
	check(strings.contains(notice, "[Comment] @coord #2 commented on \"Fix the thing\" (task_1)"), fmt.tprintf("notice header wrong: %s", notice))
	check(strings.contains(notice, "0123456789ABCDEFGHIJ…"), fmt.tprintf("excerpt must truncate at 20 runes + ellipsis: %s", notice))
	check(!strings.contains(notice, "OVERFLOW"), "excerpt must not exceed 20 runes")

	// 1b) Title is also capped at 20 runes + ellipsis (user directive 2026-09-09).
	long_title_task := domain.Task{task_id = "task_2", title = "This Task Title Is Way Too Long To Fit", status = .In_Progress}
	tnotice := taskchain_service.build_human_readable_task_notice(&service, long_title_task, "inst_coord", "Work Started", "started work on", "")
	defer delete(tnotice)
	check(strings.contains(tnotice, "\"This Task Title Is W…\""), fmt.tprintf("title must truncate at 20 runes + ellipsis: %s", tnotice))
	check(!strings.contains(tnotice, "Too Long"), "title must not exceed 20 runes")

	// 1c) Vault ciphertext (starts with "vault:v1:") must bypass truncation completely.
	vault_cipher := "vault:v1:FQ+uOa5fKWwM4Tvj8GjZH4Y3dkNDoXqhh14W8xh0xp5eAVDfMXifD0LVN3/6eGuUryDtHRnJ1hrFmrPikHJWMMd9DyFL"
	vault_title_task := domain.Task{task_id = "task_vault", title = vault_cipher, status = .In_Progress}
	vnotice := taskchain_service.build_human_readable_task_notice(&service, vault_title_task, "inst_coord", "Work Started", "started work on", vault_cipher)
	defer delete(vnotice)
	check(strings.contains(vnotice, vault_cipher), fmt.tprintf("vault ciphertext in title must not be truncated: %s", vnotice))
	check(strings.contains(vnotice, fmt.tprintf(": \"%s\"", vault_cipher)), fmt.tprintf("vault ciphertext in excerpt must not be truncated: %s", vnotice))

	// 2) Paused -> assignee + coordinator, [Task Paused], actor @User (user auth).
	captured.count = 0
	taskchain_service.notify_status_policy(&service, user_auth, task, chain)
	check(captured.count == 2, fmt.tprintf("paused must wake assignee + coordinator, got %d", captured.count))
	j := strings.concatenate({captured.bodies[0], captured.bodies[1]})
	check(strings.contains(j, "[Task Paused]"), "must carry [Task Paused]")
	// body is JSON (quotes escaped), so assert the pieces around the escaped title.
	check(strings.contains(j, "@User paused") && strings.contains(j, "Fix the thing"), "must render @User paused <title>")
	check(strings.contains(j, `"agent_instance_id":"inst_assignee"`) && strings.contains(j, `"agent_instance_id":"inst_coord"`), "both assignee and coordinator woken")

	// 3) Validated_Good -> coordinator only, [Review Consensus].
	captured.count = 0
	task.status = .Validated_Good
	taskchain_service.notify_status_policy(&service, user_auth, task, chain)
	check(captured.count == 1, fmt.tprintf("validated_good must wake only coordinator, got %d", captured.count))
	check(strings.contains(captured.bodies[0], "[Review Consensus]"), "must carry [Review Consensus]")
	check(strings.contains(captured.bodies[0], `"agent_instance_id":"inst_coord"`), "coordinator targeted")

	fmt.println("PASS: hub mem6 policy")
}
