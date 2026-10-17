package taskv2

import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// M3b tests: workflow definitions, cycle/for_each validation, same-UoW stage
// materialization, fan-out stage completeness, idempotent reopen, Gate stages,
// retry + cascade carry-forward + orphaned_work, workflow immutability, and
// ticket on_output -> start_workflow trigger.

@(test)
test_workflow_define_and_cycle_check :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "m3b_define")
	defer lease_fixture_close(fx, log)
	if !ok do return

	// 1. All 3 built-in templates load and validate cleanly.
	tpls := workflow_builtin_templates()
	testing.expect_value(t, len(tpls), 3)
	for tpl in tpls {
		_, vok, verr := parse_and_validate_workflow_spec(tpl.spec_json)
		testing.expect(t, vok, fmt.tprintf("builtin template %s should validate: %s", tpl.name, verr.message))
	}

	// 2. Define a valid user workflow (v1), then define again with same name -> auto-versions to v2.
	valid_spec := `{
		"schema": "workflow.v1",
		"name": "custom_pipe",
		"title": "Custom Pipeline",
		"inputs": [{"name": "target", "type": "string", "required": true}],
		"stages": [
			{
				"key": "scan",
				"kind": "task",
				"title": "Scan {{inputs.target}}",
				"brief": {
					"goal": "Scan {{inputs.target}}",
					"acceptance": ["Produce task_list.v1"],
					"verify": "none",
					"output": {"schema": "task_list.v1"}
				}
			},
			{
				"key": "fix",
				"kind": "task",
				"title": "Fix {{item.key}}",
				"depends_on": ["scan"],
				"for_each": "scan.outputs[0].tasks",
				"brief": {
					"goal": "{{item.goal}}",
					"acceptance": ["Fixed"],
					"verify": "true"
				}
			}
		]
	}`
	d1, d1ok, d1err := workflow_define(&fx.svc, "u1", valid_spec)
	if !testing.expect(t, d1ok, fmt.tprintf("define v1: %s", d1err.message)) do return
	testing.expect_value(t, d1.name, "custom_pipe")
	testing.expect_value(t, d1.version, 1)

	d2, d2ok, _ := workflow_define(&fx.svc, "u1", valid_spec)
	testing.expect(t, d2ok && d2.version == 2, "second define increments version to 2")

	defs, lerr := workflow_list_definitions(&fx.svc, "u1")
	testing.expect(t, lerr.code == .None && len(defs) == 2, "2 persisted workflow definitions")

	// 3. Cycle detection: A -> B -> A must fail with 422 workflow_cycle.
	cycle_spec := `{
		"schema": "workflow.v1",
		"name": "bad_cycle",
		"stages": [
			{"key": "a", "kind": "task", "depends_on": ["b"], "brief": {"goal": "g", "acceptance": ["a"], "verify": "true"}},
			{"key": "b", "kind": "task", "depends_on": ["a"], "brief": {"goal": "g", "acceptance": ["a"], "verify": "true"}}
		]
	}`
	_, cok, cerr := workflow_define(&fx.svc, "u1", cycle_spec)
	testing.expect(t, !cok && cerr.code == .Validation_Failed && strings.contains(cerr.details_json, "workflow_cycle"), "cycle rejected with workflow_cycle")

	// 4. for_each referencing a stage not in depends_on closure must fail with 422 workflow_invalid.
	bad_fe_spec := `{
		"schema": "workflow.v1",
		"name": "bad_fe",
		"stages": [
			{"key": "a", "kind": "task", "brief": {"goal": "g", "acceptance": ["a"], "verify": "none", "output": {"schema": "task_list.v1"}}},
			{"key": "b", "kind": "task", "for_each": "a.outputs[0].tasks", "brief": {"goal": "g", "acceptance": ["a"], "verify": "true"}}
		]
	}`
	_, feok, feerr := workflow_define(&fx.svc, "u1", bad_fe_spec)
	testing.expect(t, !feok && feerr.code == .Validation_Failed && strings.contains(feerr.details_json, "workflow_invalid"), "unconnected for_each rejected")

	// 5. {{item.x}} placeholder without for_each must fail with 422 workflow_invalid.
	bad_item_spec := `{
		"schema": "workflow.v1",
		"name": "bad_item",
		"stages": [
			{"key": "a", "kind": "task", "title": "Fix {{item.key}}", "brief": {"goal": "g", "acceptance": ["a"], "verify": "true"}}
		]
	}`
	_, iok, ierr := workflow_define(&fx.svc, "u1", bad_item_spec)
	testing.expect(t, !iok && ierr.code == .Validation_Failed && strings.contains(ierr.details_json, "workflow_invalid"), "{{item.*}} without for_each rejected")
}

@(test)
test_materialize_on_done_same_uow :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "m3b_same_uow")
	defer lease_fixture_close(fx, log)
	if !ok do return

	spec := `{
		"schema": "workflow.v1",
		"name": "two_stage",
		"inputs": [{"name": "goal", "type": "string", "required": true}],
		"stages": [
			{
				"key": "first",
				"kind": "task",
				"title": "First: {{inputs.goal}}",
				"brief": {
					"goal": "Explore {{inputs.goal}}",
					"acceptance": ["Done first"],
					"verify": "none",
					"output": {"schema": "inline", "required_fields": ["summary"]},
					"review_roles": []
				}
			},
			{
				"key": "second",
				"kind": "task",
				"title": "Second after {{stage.first.output.summary}}",
				"depends_on": ["first"],
				"brief": {
					"goal": "Implement {{stage.first.output.summary}}",
					"acceptance": ["Done second"],
					"verify": "true",
					"review_roles": []
				}
			}
		]
	}`
	_, dok, derr := workflow_define(&fx.svc, "u1", spec)
	if !testing.expect(t, dok, fmt.tprintf("define: %s", derr.message)) do return

	seed_bridge(fx, "br_1")
	seed_agent(fx, "coder")
	seed_instance(fx, domain.Task_Chain{}, "inst_w1", "coder", "br_1", "idle")

	chain, rok, rerr := workflow_run(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, Workflow_Run_Input{
		ref            = "two_stage",
		inputs_json    = `{"goal":"ship m3b"}`,
		bridge_id      = "br_1",
		directory_path = "/repo",
	})
	if !testing.expect(t, rok, fmt.tprintf("workflow_run: %s", rerr.message)) do return
	testing.expect_value(t, chain.kind, domain.CHAIN_KIND_WORKFLOW)

	// Root stage "first" is materialised and leased immediately; "second" is NOT materialised yet.
	tasks_before, _ := iface.taskchain_list_tasks_by_chain(&fx.repo, chain.chain_id, "u1")
	testing.expect_value(t, len(tasks_before), 1)
	testing.expect_value(t, tasks_before[0].stage_key, "first")
	testing.expect_value(t, tasks_before[0].title, "First: ship m3b")
	testing.expect_value(t, tasks_before[0].state, domain.Task_State.In_Progress)

	// Confirm holder and submit stage "first" with output.
	confirm_holder(fx, "inst_w1")
	res, sok, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{
		summary     = "explored",
		verify      = "none",
		output_json = `{"summary":"clean-arch"}`,
	})
	if !testing.expect(t, sok, fmt.tprintf("submit first: %s", serr.message)) do return
	testing.expect_value(t, res.outcome, "done")

	// In the SAME UoW as `lease_submit` (no extra tick or reconcile call), stage "second"
	// must be materialised, substituted with `first`'s output, and leased to `inst_w1`!
	tasks_after, _ := iface.taskchain_list_tasks_by_chain(&fx.repo, chain.chain_id, "u1")
	testing.expect_value(t, len(tasks_after), 2)
	second_task := domain.Task{}
	for tk in tasks_after {
		if tk.stage_key == "second" do second_task = tk
	}
	testing.expect_value(t, second_task.title, "Second after clean-arch")
	testing.expect_value(t, second_task.state, domain.Task_State.In_Progress)
	l2, held2 := lease_of(fx, "inst_w1")
	testing.expect(t, held2 && l2.task_id == second_task.task_id, "second stage leased in same UoW")
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "same_uow")
}

@(test)
test_for_each_waits_for_stage_completeness :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "m3b_foreach")
	defer lease_fixture_close(fx, log)
	if !ok do return

	spec := `{
		"schema": "workflow.v1",
		"name": "fanout_wf",
		"stages": [
			{
				"key": "plan",
				"kind": "task",
				"title": "Plan",
				"brief": {
					"goal": "Produce task list",
					"acceptance": ["Valid task_list.v1"],
					"verify": "none",
					"output": {"schema": "task_list.v1"},
					"review_roles": []
				}
			},
			{
				"key": "build",
				"kind": "task",
				"title": "Build {{item.key}}: {{item.title}}",
				"depends_on": ["plan"],
				"for_each": "plan.outputs[0].tasks",
				"max_parallel": 1,
				"brief": {
					"goal": "{{item.goal}}",
					"acceptance": ["Built {{item.key}}"],
					"verify": "true",
					"review_roles": []
				}
			},
			{
				"key": "verify",
				"kind": "task",
				"title": "Verify all",
				"depends_on": ["build"],
				"brief": {
					"goal": "Verify all built items",
					"acceptance": ["All green"],
					"verify": "true",
					"review_roles": []
				}
			}
		]
	}`
	_, dok, _ := workflow_define(&fx.svc, "u1", spec)
	testing.expect(t, dok, "define fanout_wf")

	seed_bridge(fx, "br_1")
	seed_agent(fx, "coder")
	seed_instance(fx, domain.Task_Chain{}, "inst_w1", "coder", "br_1", "idle")
	seed_instance(fx, domain.Task_Chain{}, "inst_w2", "coder", "br_1", "idle")

	chain, rok, _ := workflow_run(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, Workflow_Run_Input{
		ref            = "fanout_wf",
		inputs_json    = `{}`,
		bridge_id      = "br_1",
	})
	if !testing.expect(t, rok, "workflow_run fanout_wf") do return

	// Complete `plan` with 2 items in task_list.v1
	l_plan, held_plan := lease_of(fx, "inst_w1")
	if !held_plan {
		l_plan, held_plan = lease_of(fx, "inst_w2")
	}
	testing.expect(t, held_plan, "plan leased")
	confirm_holder(fx, l_plan.holder_instance_id)
	_, sok, serr := lease_submit(&fx.svc, inst_auth(l_plan.holder_instance_id), Submit_Input{
		summary     = "planned 2 items",
		verify      = "none",
		output_json = `{"schema":"task_list.v1","tasks":[{"key":"k1","title":"Part 1","goal":"Do part 1"},{"key":"k2","title":"Part 2","goal":"Do part 2"}]}`,
	})
	if !testing.expect(t, sok, fmt.tprintf("submit plan: %s", serr.message)) do return

	// Both build[0] and build[1] are materialised, `verify` is NOT materialised yet.
	// And because `max_parallel: 1`, only ONE of build[0], build[1] is In_Progress!
	tasks_mid, _ := iface.taskchain_list_tasks_by_chain(&fx.repo, chain.chain_id, "u1")
	build_count := 0
	in_prog_build := 0
	verify_count := 0
	first_build_holder := ""
	first_build_task := domain.Task{}
	for tk in tasks_mid {
		if tk.stage_key == "build" {
			build_count += 1
			if tk.state == .In_Progress {
				in_prog_build += 1
				first_build_task = tk
			}
		}
		if tk.stage_key == "verify" do verify_count += 1
	}
	testing.expect_value(t, build_count, 2)
	testing.expect_value(t, in_prog_build, 1)
	testing.expect_value(t, verify_count, 0)

	if l, ok1 := lease_of(fx, "inst_w1"); ok1 && l.task_id == first_build_task.task_id {
		first_build_holder = "inst_w1"
	} else {
		first_build_holder = "inst_w2"
	}
	confirm_holder(fx, first_build_holder)
	write_verify(fx, string(first_build_task.task_id), 1, "h1", 0)
	_, b1ok, b1err := lease_submit(&fx.svc, inst_auth(first_build_holder), Submit_Input{
		summary  = "built 1",
		vcs_json = `{"head":"h1","dirty":false}`,
	})
	if !testing.expect(t, b1ok, fmt.tprintf("submit build[0]: %s", b1err.message)) do return

	// After 1 of 2 build items is Done, `verify` MUST STILL NOT be materialised!
	tasks_after_b1, _ := iface.taskchain_list_tasks_by_chain(&fx.repo, chain.chain_id, "u1")
	verify_after_b1 := 0
	second_build_task := domain.Task{}
	for tk in tasks_after_b1 {
		if tk.stage_key == "verify" do verify_after_b1 += 1
		if tk.stage_key == "build" && tk.state == .In_Progress do second_build_task = tk
	}
	testing.expect_value(t, verify_after_b1, 0)
	testing.expect(t, second_build_task.task_id != "", "second build item is now In_Progress")

	// Complete second build item -> `verify` stage materialises immediately in the same UoW!
	second_holder := "inst_w1"
	if l, ok1 := lease_of(fx, "inst_w1"); !ok1 || l.task_id != second_build_task.task_id {
		second_holder = "inst_w2"
	}
	confirm_holder(fx, second_holder)
	write_verify(fx, string(second_build_task.task_id), 1, "h2", 0)
	_, b2ok, b2err := lease_submit(&fx.svc, inst_auth(second_holder), Submit_Input{
		summary  = "built 2",
		vcs_json = `{"head":"h2","dirty":false}`,
	})
	if !testing.expect(t, b2ok, fmt.tprintf("submit build[1]: %s", b2err.message)) do return

	tasks_final, _ := iface.taskchain_list_tasks_by_chain(&fx.repo, chain.chain_id, "u1")
	verify_final := 0
	for tk in tasks_final {
		if tk.stage_key == "verify" do verify_final += 1
	}
	testing.expect_value(t, verify_final, 1)
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "foreach_complete")
}

@(test)
test_materialize_idempotent_after_reopen :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "m3b_idem")
	defer lease_fixture_close(fx, log)
	if !ok do return

	spec := `{
		"schema": "workflow.v1",
		"name": "idem_wf",
		"stages": [
			{
				"key": "s1",
				"kind": "task",
				"title": "Stage 1",
				"brief": {"goal": "g1", "acceptance": ["a1"], "verify": "true", "review_roles": []}
			},
			{
				"key": "s2",
				"kind": "task",
				"title": "Stage 2",
				"depends_on": ["s1"],
				"brief": {"goal": "g2", "acceptance": ["a2"], "verify": "true", "review_roles": []}
			}
		]
	}`
	_, dok, _ := workflow_define(&fx.svc, "u1", spec)
	testing.expect(t, dok, "define idem_wf")

	seed_bridge(fx, "br_1")
	seed_agent(fx, "coder")
	seed_instance(fx, domain.Task_Chain{}, "inst_w1", "coder", "br_1", "idle")

	chain, rok, _ := workflow_run(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, Workflow_Run_Input{
		ref            = "idem_wf",
		inputs_json    = `{}`,
		bridge_id      = "br_1",
		directory_path = "/repo",
	})
	if !testing.expect(t, rok, "run idem_wf") do return

	confirm_holder(fx, "inst_w1")
	l1, _ := lease_of(fx, "inst_w1")
	write_verify(fx, string(l1.task_id), 1, "h1", 0)
	_, sok, _ := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{
		summary  = "s1 done",
		vcs_json = `{"head":"h1","dirty":false}`,
	})
	testing.expect(t, sok, "s1 submitted")

	tasks1, _ := iface.taskchain_list_tasks_by_chain(&fx.repo, chain.chain_id, "u1")
	testing.expect_value(t, len(tasks1), 2)
	s2_id := domain.Task_ID("")
	for tk in tasks1 {
		if tk.stage_key == "s2" do s2_id = tk.task_id
	}
	testing.expect(t, s2_id != "", "s2 materialised")

	// Complete s2 so it is terminal, then reopen s2 and re-run materializer: s2 must NOT be duplicated.
	confirm_holder(fx, "inst_w1")
	write_verify(fx, string(s2_id), 1, "h2", 0)
	_, s2ok, _ := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{
		summary  = "s2 done",
		vcs_json = `{"head":"h2","dirty":false}`,
	})
	testing.expect(t, s2ok, "s2 submitted")

	s2_done := get_task(fx, string(s2_id))
	_, reok, reerr := task_reopen(&fx.svc, s2_done, Actor{kind = ACTOR_USER, id = "u1"})
	testing.expect(t, reok, fmt.tprintf("reopen s2: %s", reerr.message))

	u, uok, _ := begin_uow(&fx.svc)
	if uok {
		_, _, _ = materialize_ready_stages_in_uow(&fx.svc, &u, chain)
		_, _ = end_uow(&fx.svc, &u, true)
	}

	tasks2, _ := iface.taskchain_list_tasks_by_chain(&fx.repo, chain.chain_id, "u1")
	s2_count := 0
	for tk in tasks2 {
		if tk.stage_key == "s2" do s2_count += 1
	}
	testing.expect_value(t, s2_count, 1)
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "idem_reopen")
}

@(test)
test_gate_materialised_in_review_and_never_leased :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "m3b_gate")
	defer lease_fixture_close(fx, log)
	if !ok do return

	spec := `{
		"schema": "workflow.v1",
		"name": "gated_wf",
		"stages": [
			{
				"key": "plan",
				"kind": "task",
				"title": "Plan",
				"brief": {"goal": "plan it", "acceptance": ["planned"], "verify": "true", "review_roles": []}
			},
			{
				"key": "approve_plan",
				"kind": "gate",
				"title": "Approve Plan",
				"depends_on": ["plan"],
				"approver": "user",
				"prompt": "Please approve the plan"
			},
			{
				"key": "deploy",
				"kind": "task",
				"title": "Deploy",
				"depends_on": ["approve_plan"],
				"brief": {"goal": "deploy it", "acceptance": ["deployed"], "verify": "true", "review_roles": []}
			}
		]
	}`
	_, dok, _ := workflow_define(&fx.svc, "u1", spec)
	testing.expect(t, dok, "define gated_wf")

	seed_bridge(fx, "br_1")
	seed_agent(fx, "agt_c")
	seed_agent(fx, "coder")
	seed_instance(fx, domain.Task_Chain{}, "inst_w1", "coder", "br_1", "idle")
	seed_instance(fx, domain.Task_Chain{}, "inst_coord", "agt_c", "br_1", "running")

	chain, rok, _ := workflow_run(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, Workflow_Run_Input{
		ref                           = "gated_wf",
		inputs_json                   = `{}`,
		coordinator_agent_instance_id = "inst_coord",
		bridge_id                     = "br_1",
		directory_path                = "/repo",
	})
	if !testing.expect(t, rok, "run gated_wf") do return

	// Complete `plan` stage
	confirm_holder(fx, "inst_w1")
	l1, _ := lease_of(fx, "inst_w1")
	write_verify(fx, string(l1.task_id), 1, "h1", 0)
	_, sok, _ := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{
		summary  = "plan ready",
		vcs_json = `{"head":"h1","dirty":false}`,
	})
	testing.expect(t, sok, "submit plan")

	// `approve_plan` gate is materialised directly in `In_Review`; `deploy` is not materialised yet.
	tasks_mid, _ := iface.taskchain_list_tasks_by_chain(&fx.repo, chain.chain_id, "u1")
	gate_task := domain.Task{}
	deploy_count := 0
	for tk in tasks_mid {
		if tk.stage_key == "approve_plan" do gate_task = tk
		if tk.stage_key == "deploy" do deploy_count += 1
	}
	testing.expect_value(t, gate_task.kind, domain.Task_Kind.Gate)
	testing.expect_value(t, gate_task.state, domain.Task_State.In_Review)
	testing.expect_value(t, deploy_count, 0)

	// Worker is NEVER leased the gate task.
	_, held_w := lease_of(fx, "inst_w1")
	testing.expect(t, !held_w, "gate is never leased to worker")
	ln, lnok, _ := lease_next(&fx.svc, inst_auth("inst_w1"), Lease_Next_Input{})
	testing.expect(t, lnok && ln.status == "none", "lease_next returns none while waiting at gate")

	// Because approver == "user", coordinator approval is rejected with 403 gate_requires_user.
	_, cgok, cgerr := review_post(&fx.svc, inst_auth("inst_coord"), Review_Input{
		task_id = string(gate_task.task_id),
		verdict = "approve",
	})
	testing.expect(t, !cgok && cgerr.code == .Forbidden && strings.contains(cgerr.details_json, "gate_requires_user"), "user-only gate rejects coordinator approval")

	// User approves the gate -> gate transitions to Done and `deploy` materialises & leases in the same UoW!
	gres, ugok, ugerr := user_review(&fx.svc, user_auth(), gate_task.task_id, Review_Input{
		task_id = string(gate_task.task_id),
		verdict = "approve",
	})
	if !testing.expect(t, ugok, fmt.tprintf("user approve gate: %s", ugerr.message)) do return
	testing.expect_value(t, gres.gate, Gate_Result.Approved)
	testing.expect_value(t, get_task(fx, string(gate_task.task_id)).state, domain.Task_State.Done)

	tasks_after, _ := iface.taskchain_list_tasks_by_chain(&fx.repo, chain.chain_id, "u1")
	deploy_task := domain.Task{}
	for tk in tasks_after {
		if tk.stage_key == "deploy" do deploy_task = tk
	}
	testing.expect(t, deploy_task.task_id != "", "deploy stage materialised on gate approval")
	testing.expect_value(t, deploy_task.state, domain.Task_State.In_Progress)
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "gate_approved")
}

@(test)
test_retry_refused_with_downstream :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "m3b_retry_409")
	defer lease_fixture_close(fx, log)
	if !ok do return

	spec := `{
		"schema": "workflow.v1",
		"name": "retry_409_wf",
		"stages": [
			{"key": "s1", "kind": "task", "title": "S1", "brief": {"goal": "g1", "acceptance": ["a1"], "verify": "true", "review_roles": []}},
			{"key": "s2", "kind": "task", "title": "S2", "depends_on": ["s1"], "brief": {"goal": "g2", "acceptance": ["a2"], "verify": "true", "review_roles": []}}
		]
	}`
	_, dok, _ := workflow_define(&fx.svc, "u1", spec)
	testing.expect(t, dok, "define retry_409_wf")

	seed_bridge(fx, "br_1")
	seed_agent(fx, "coder")
	seed_instance(fx, domain.Task_Chain{}, "inst_w1", "coder", "br_1", "idle")

	chain, rok, _ := workflow_run(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, Workflow_Run_Input{
		ref            = "retry_409_wf",
		inputs_json    = `{}`,
		bridge_id      = "br_1",
		directory_path = "/repo",
	})
	if !testing.expect(t, rok, "run retry_409_wf") do return

	// Complete s1 so s2 is materialised
	confirm_holder(fx, "inst_w1")
	l1, _ := lease_of(fx, "inst_w1")
	write_verify(fx, string(l1.task_id), 1, "h1", 0)
	_, sok, _ := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{
		summary  = "s1 done",
		vcs_json = `{"head":"h1","dirty":false}`,
	})
	testing.expect(t, sok, "s1 done")

	// Retry s1 without cascade -> 409 downstream_materialised
	_, rtok, rterr := workflow_retry(&fx.svc, chain.chain_id, "u1", Actor{kind = ACTOR_USER, id = "u1"}, Workflow_Retry_Input{
		stage_key = "s1",
		cascade   = false,
	})
	testing.expect(t, !rtok && rterr.code == .Conflict && strings.contains(rterr.details_json, "downstream_materialised"), "retry without cascade refused with 409 downstream_materialised")
	testing.expect_value(t, get_task(fx, string(l1.task_id)).state, domain.Task_State.Done)
}

@(test)
test_retry_cascade_cancels_and_carries_forward :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "m3b_cascade")
	defer lease_fixture_close(fx, log)
	if !ok do return

	spec := `{
		"schema": "workflow.v1",
		"name": "cascade_wf",
		"stages": [
			{
				"key": "plan",
				"kind": "task",
				"title": "Plan",
				"brief": {
					"goal": "Produce task list",
					"acceptance": ["task_list.v1"],
					"verify": "none",
					"output": {"schema": "task_list.v1"},
					"review_roles": []
				}
			},
			{
				"key": "build",
				"kind": "task",
				"title": "Build {{item.key}}",
				"depends_on": ["plan"],
				"for_each": "plan.outputs[0].tasks",
				"brief": {
					"goal": "{{item.goal}}",
					"acceptance": ["Built {{item.key}}"],
					"verify": "true",
					"review_roles": []
				}
			}
		]
	}`
	_, dok, _ := workflow_define(&fx.svc, "u1", spec)
	testing.expect(t, dok, "define cascade_wf")

	seed_bridge(fx, "br_1")
	seed_agent(fx, "coder")
	seed_instance(fx, domain.Task_Chain{}, "inst_w1", "coder", "br_1", "idle")
	seed_instance(fx, domain.Task_Chain{}, "inst_w2", "coder", "br_1", "idle")

	chain, rok, _ := workflow_run(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, Workflow_Run_Input{
		ref         = "cascade_wf",
		inputs_json = `{}`,
		bridge_id   = "br_1",
	})
	if !testing.expect(t, rok, "run cascade_wf") do return

	// 1. Submit `plan` with 2 items: `item_a` and `item_b`.
	l_plan, held := lease_of(fx, "inst_w1")
	if !held do l_plan, held = lease_of(fx, "inst_w2")
	confirm_holder(fx, l_plan.holder_instance_id)
	_, pok, _ := lease_submit(&fx.svc, inst_auth(l_plan.holder_instance_id), Submit_Input{
		summary     = "initial plan",
		verify      = "none",
		output_json = `{"schema":"task_list.v1","tasks":[{"key":"item_a","goal":"Build A"},{"key":"item_b","goal":"Build B v1"}]}`,
	})
	testing.expect(t, pok, "submit initial plan")

	// Find build[0] (item_a) and build[1] (item_b).
	tasks_v1, _ := iface.taskchain_list_tasks_by_chain(&fx.repo, chain.chain_id, "u1")
	task_a := domain.Task{}
	task_b := domain.Task{}
	for tk in tasks_v1 {
		if tk.stage_key == "build" && tk.stage_index == 0 do task_a = tk
		if tk.stage_key == "build" && tk.stage_index == 1 do task_b = tk
	}
	testing.expect(t, task_a.task_id != "" && task_b.task_id != "", "both build tasks materialised")

	// 2. Complete `task_a` (Done), and record a VCS commit facet on `task_b` while `task_b` is In_Progress.
	holder_a := "inst_w1"
	if l, ok1 := lease_of(fx, "inst_w1"); !ok1 || l.task_id != task_a.task_id {
		holder_a = "inst_w2"
	}
	confirm_holder(fx, holder_a)
	write_verify(fx, string(task_a.task_id), 1, "head_a", 0)
	_, aok, _ := lease_submit(&fx.svc, inst_auth(holder_a), Submit_Input{
		summary  = "item_a finished",
		vcs_json = `{"head":"head_a","dirty":false}`,
	})
	testing.expect(t, aok, "task_a is Done")
	testing.expect_value(t, get_task(fx, string(task_a.task_id)).state, domain.Task_State.Done)

	// Record a VCS facet on `task_b` so cascade cancellation detects orphaned commits.
	_, _ = iface.taskchain_save_facet(&fx.repo, domain.Task_Attempt_Facet{
		task_id       = task_b.task_id,
		attempt_no    = 1,
		kind          = FACET_VCS,
		owner_user_id = "u1",
		writer        = FACET_WRITER_BRIDGE,
		body_json     = `{"head":"deadbeef999","dirty":false}`,
		written_at    = "2026-04-17T00:00:00Z",
	})

	// 3. Run `workflow_retry` on `plan` with `cascade = true`!
	rres, rtok, rterr := workflow_retry(&fx.svc, chain.chain_id, "u1", Actor{kind = ACTOR_USER, id = "u1"}, Workflow_Retry_Input{
		stage_key = "plan",
		cascade   = true,
		reason    = "revise item_b",
	})
	if !testing.expect(t, rtok, fmt.tprintf("cascade retry: %s", rterr.message)) do return
	testing.expect_value(t, len(rres.reopened_task_ids), 1)
	testing.expect_value(t, len(rres.cancelled_task_ids), 1)
	testing.expect_value(t, rres.cancelled_task_ids[0], task_b.task_id)
	testing.expect_value(t, len(rres.carried_forward_keys), 1)
	testing.expect_value(t, rres.carried_forward_keys[0], "item_a")
	testing.expect_value(t, len(rres.orphaned_task_ids), 1)
	testing.expect_value(t, rres.orphaned_task_ids[0], task_b.task_id)
	testing.expect_value(t, count_events(fx, string(task_b.task_id), EV_ORPHANED_WORK), 1)

	// 4. Submit `plan` attempt 2 with `item_a` UNCHANGED and `item_b` MODIFIED (`Build B v2`).
	l_plan2, held2 := lease_of(fx, "inst_w1")
	if !held2 do l_plan2, held2 = lease_of(fx, "inst_w2")
	if !held2 {
		leases_p, _ := iface.taskchain_list_leases_by_task(&fx.repo, l_plan.task_id)
		if len(leases_p) > 0 {
			l_plan2 = leases_p[0]
			held2 = true
		}
	}
	testing.expect(t, held2, "reopened plan is leased")
	confirm_holder(fx, l_plan2.holder_instance_id)
	_, p2ok, p2err := lease_submit(&fx.svc, inst_auth(l_plan2.holder_instance_id), Submit_Input{
		summary     = "revised plan",
		verify      = "none",
		output_json = `{"schema":"task_list.v1","tasks":[{"key":"item_a","goal":"Build A"},{"key":"item_b","goal":"Build B v2"}]}`,
	})
	if !testing.expect(t, p2ok, fmt.tprintf("submit revised plan: %s", p2err.message)) do return

	// 5. Verify `task_a` was carried forward as `Done` (same task_id, not re-run!)
	// and a new `build[1]` task was created for `Build B v2`.
	tasks_v2, _ := iface.taskchain_list_tasks_by_chain(&fx.repo, chain.chain_id, "u1")
	restored_a := domain.Task{}
	new_b := domain.Task{}
	for tk in tasks_v2 {
		if tk.stage_key == "build" && tk.stage_index == 0 do restored_a = tk
		if tk.stage_key == "build" && tk.stage_index == 1 do new_b = tk
	}
	testing.expect_value(t, restored_a.task_id, task_a.task_id)
	testing.expect_value(t, restored_a.state, domain.Task_State.Done)
	testing.expect(t, new_b.task_id != "" && new_b.task_id != task_b.task_id, "modified item_b got a fresh task")
	testing.expect(t, strings.contains(new_b.brief_json, "Build B v2"), "new item_b has updated goal")
}

@(test)
test_workflow_task_create_403 :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "m3b_imm")
	defer lease_fixture_close(fx, log)
	if !ok do return

	seed_bridge(fx, "br_1")
	chain, rok, rerr := workflow_run(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, Workflow_Run_Input{
		ref            = "fix_flaky_tests",
		inputs_json    = `{"test_command":"odin test src/hub/service/taskv2"}`,
		bridge_id      = "br_1",
		directory_path = "/repo",
	})
	if !testing.expect(t, rok, fmt.tprintf("workflow_run: %s", rerr.message)) do return
	testing.expect_value(t, chain.kind, domain.CHAIN_KIND_WORKFLOW)

	// Attempting to mutate workflow_snapshot_json at the repo level returns 409 workflow_snapshot_immutable.
	mutated := chain
	mutated.workflow_snapshot_json = `{"schema":"workflow.v1","name":"tampered","stages":[]}`
	_, mok, merr := iface.taskchain_save_chain(&fx.repo, mutated)
	testing.expect(t, !mok && merr.code == .Conflict && strings.contains(merr.details_json, "workflow_snapshot_immutable"), "workflow_snapshot_json is immutable")
}

@(test)
test_ticket_on_output_starts_workflow :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "m3b_on_output")
	defer lease_fixture_close(fx, log)
	if !ok do return

	// 1. Seed a live `ticket` chain with a task whose brief has `output` + `on_output: start_workflow`.
	chain := seed_live_chain(t, fx, "chain_triage")
	chain.kind = domain.CHAIN_KIND_TICKET
	_, _, _ = iface.taskchain_save_chain(&fx.repo, chain)
	seed_fleet(fx, chain, "agt_w")
	seed_agent(fx, "coder")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_w2", "coder", "br_1", "idle")

	triage_brief := `{
		"goal": "Triage flaky test report",
		"acceptance": ["Emit test_command"],
		"verify": "none",
		"review_roles": [],
		"output": {
			"schema": "inline",
			"required_fields": ["test_command"]
		},
		"on_output": {
			"kind": "start_workflow",
			"workflow": "fix_flaky_tests",
			"title": "Auto-fix: {{output.test_command}}",
			"inputs": {
				"test_command": "{{output.test_command}}"
			}
		}
	}`
	triage_task := publish_task(t, fx, chain, "task_triage", brief = triage_brief)
	confirm_holder(fx, "inst_w1")

	// Submitting without required output field `test_command` fails with 422 output_contract_invalid.
	_, bad_ok, bad_err := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{
		summary     = "missing field",
		verify      = "none",
		output_json = `{"wrong_field":"x"}`,
	})
	testing.expect(t, !bad_ok && bad_err.code == .Validation_Failed && strings.contains(bad_err.details_json, "output_contract_invalid"), "missing required output field rejected")

	// Submitting with valid output completes the ticket AND spawns the `fix_flaky_tests` workflow in the SAME UoW!
	res, sok, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{
		summary     = "triaged flaky suite",
		verify      = "none",
		output_json = `{"test_command":"pytest tests/flaky"}`,
	})
	if !testing.expect(t, sok, fmt.tprintf("submit triage: %s", serr.message)) do return
	testing.expect_value(t, res.outcome, "done")

	// Verify EV_STARTED_WORKFLOW was recorded on `task_triage`.
	testing.expect_value(t, count_events(fx, string(triage_task.task_id), EV_STARTED_WORKFLOW), 1)
	evs, _ := iface.taskchain_list_events_by_task(&fx.repo, triage_task.task_id, "u1")
	spawned_chain_id := ""
	for ev in evs {
		if ev.kind == EV_STARTED_WORKFLOW {
			spawned_chain_id = strings.trim_space(
				iface_extract_str(ev.payload_json, "chain_id"),
			)
		}
	}
	testing.expect(t, spawned_chain_id != "", "EV_STARTED_WORKFLOW carries spawned chain_id")

	// Verify the spawned workflow chain exists, is Published + Active, has kind == "workflow",
	// and its root stage (`reproduce`) is materialised!
	wf_chain, wf_ok, _ := iface.taskchain_get_chain(&fx.repo, domain.Task_Chain_ID(spawned_chain_id))
	testing.expect(t, wf_ok, "spawned workflow chain exists")
	testing.expect_value(t, wf_chain.kind, domain.CHAIN_KIND_WORKFLOW)
	testing.expect_value(t, wf_chain.title, "Auto-fix: pytest tests/flaky")

	wf_tasks, _ := iface.taskchain_list_tasks_by_chain(&fx.repo, wf_chain.chain_id, "u1")
	testing.expect_value(t, len(wf_tasks), 1)
	testing.expect_value(t, wf_tasks[0].stage_key, "reproduce")
	testing.expect(t, strings.contains(wf_tasks[0].brief_json, "pytest tests/flaky"), "workflow input substituted into root stage brief")
}

@(private = "file")
iface_extract_str :: proc(json_str, key: string) -> string {
	members := jsonx_top_level_members(json_str)
	if raw, ok := members[key]; ok {
		return strings.trim(strings.trim_space(raw), "\"")
	}
	return ""
}
