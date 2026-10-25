package taskv2

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

@(private = "file")
dep_facet :: proc(fx: ^Fixture, task: domain.Task, attempt: int, kind, body: string) {
	_, _ = iface.taskchain_save_facet(&fx.repo, domain.Task_Attempt_Facet{
		task_id = task.task_id, attempt_no = attempt, chain_id = task.chain_id, owner_user_id = task.owner_user_id,
		kind = kind, v = 1, body_json = body, writer = FACET_WRITER_AGENT, written_at = platform.clock_now(&fx.clock),
	})
}

@(private = "file")
dep_link :: proc(fx: ^Fixture, task, on: domain.Task) {
    _, _, _ = iface.taskchain_insert_work_dependency(&fx.repo, domain.Work_Dependency{
        dependency_id = platform.generate_id(&fx.ids, "wdep_"), chain_id = task.chain_id, owner_user_id = task.owner_user_id,
        dependent = domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK, id = string(task.task_id)},
        prerequisite = domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK, id = string(on.task_id)},
        created_by_kind = "hub", created_by_id = "test", created_at = platform.clock_now(&fx.clock),
    })
}

@(test)
test_pack_dependencies_carry_handoffs :: proc(t: ^testing.T) {
	fx, ok := fixture_open(t, "pack_deps")
	defer fixture_close(fx)
	if !ok do return
	chain := seed_chain(t, fx, "chain_d", true)
	a := seed_task(t, fx, chain, "task_a")
	b := seed_task(t, fx, chain, "task_b")
	c := seed_task(t, fx, chain, "task_c")
	lone := seed_task(t, fx, chain, "task_lone")

	// A task that waits for nothing gets an empty list.
	testing.expect_value(t, dependencies_pack_json(&fx.svc, lone), "[]")

	// task_a: two attempts; the newest facet of each kind wins.
	a.state = .Done
	_, _, _ = iface.taskchain_save_task(&fx.repo, a)
	dep_facet(fx, a, 1, FACET_HANDOFF, `{"summary":"old summary","dead_ends":["old"]}`)
	dep_facet(fx, a, 2, FACET_HANDOFF, `{"summary":"Added the refresh_tokens table","decisions":["hash with sha256"],"dead_ends":["bcrypt was too slow"],"next_steps":"wire rotation"}`)
	dep_facet(fx, a, 2, FACET_OUTPUT, `{"tables":["refresh_tokens"]}`)
	dep_facet(fx, a, 2, FACET_VCS, `{"head":"abc123","files":["db/migrations/010.sql","src/auth.py"]}`)
	dep_facet(fx, a, 2, FACET_VERIFY, `{"command":"pytest -q","exit_code":0,"summary":"OK"}`)
	// task_c was cancelled without a handoff.
	c.state = .Cancelled
	_, _, _ = iface.taskchain_save_task(&fx.repo, c)
	dep_link(fx, b, a)
	dep_link(fx, b, c)

	deps := dependencies_pack_json(&fx.svc, b)
	testing.expect(t, strings.contains(deps, `"task_id":"task_a"`) && strings.contains(deps, `"state":"done"`), deps)
	testing.expect(t, strings.contains(deps, `"summary":"Added the refresh_tokens table"`) && !strings.contains(deps, "old summary"), "newest handoff wins")
	testing.expect(t, strings.contains(deps, `"decisions":["hash with sha256"]`), "decisions")
	testing.expect(t, strings.contains(deps, `"dead_ends":["bcrypt was too slow"]`), "dead ends")
	testing.expect(t, strings.contains(deps, `"next_steps":["wire rotation"]`), "a single-string list becomes an array")
	testing.expect(t, strings.contains(deps, `"output":{"tables":["refresh_tokens"]}`), "output inline")
	testing.expect(t, strings.contains(deps, `"head":"abc123"`) && !strings.contains(deps, "changed_files"), "vcs: head only (files is the uncommitted list)")
	testing.expect(t, !strings.contains(deps, `"verify"`) && !strings.contains(deps, "pytest -q"), "a legacy verify facet is history only and never enters the pack (D2)")
	testing.expect(t, strings.contains(deps, `"task_id":"task_c"`) && strings.contains(deps, `"state":"cancelled"`) && strings.contains(deps, `"summary":""`), "cancelled dependency is listed with its state")
	testing.expect(t, strings.contains(build_pack_dependencies_probe(fx, chain, b), `"dependencies":[`), "build_pack_json splices the field")

	// An output already listed in brief.inputs is referenced, not repeated.
	b.brief_json = `{"goal":"g","review_roles":[],"inputs":["output:task_a"]}`
	_, _, _ = iface.taskchain_save_task(&fx.repo, b)
	deps2 := dependencies_pack_json(&fx.svc, get_task(fx, "task_b"))
	testing.expect(t, !strings.contains(deps2, `"output":{`) && strings.contains(deps2, `"output_ref":"output:task_a"`), deps2)
}

@(test)
test_pack_dependencies_size_caps :: proc(t: ^testing.T) {
	fx, ok := fixture_open(t, "pack_deps_cap")
	defer fixture_close(fx)
	if !ok do return
	chain := seed_chain(t, fx, "chain_dc", true)
	a := seed_task(t, fx, chain, "task_big")
	b := seed_task(t, fx, chain, "task_next")
	big := strings.repeat("x", 5000, context.temp_allocator)
	dep_facet(fx, a, 1, FACET_HANDOFF, fmt.tprintf(`{{"summary":"%s"}}`, big))
	dep_facet(fx, a, 1, FACET_OUTPUT, fmt.tprintf(`{{"blob":"%s"}}`, big))
	dep_link(fx, b, a)

	deps := dependencies_pack_json(&fx.svc, b)
	testing.expect(t, len(deps) < 2 * DEP_SUMMARY_MAX_BYTES + 1500, fmt.tprintf("capped entry, got %d bytes", len(deps)))
	testing.expect(t, strings.contains(deps, "…"), "summary truncated with an ellipsis")
	testing.expect(t, strings.contains(deps, `"output_omitted":true`) && strings.contains(deps, `"output_ref":"output:task_big"`), "oversized output becomes a fetch ref")
}

// build_pack_dependencies_probe builds a full pack for `task` with a synthetic
// lease, to check the field is spliced at the top level.
@(private = "file")
build_pack_dependencies_probe :: proc(fx: ^Fixture, chain: domain.Task_Chain, task: domain.Task) -> string {
	lease := domain.Task_Lease{lease_id = "lease_probe", task_id = task.task_id, chain_id = chain.chain_id, owner_user_id = chain.owner_user_id, kind = domain.LEASE_KIND_WORK, attempt_no = 1}
	return build_pack_json(&fx.svc, chain, task, lease, domain.Agent_Instance{agent_instance_id = "inst_probe"})
}
