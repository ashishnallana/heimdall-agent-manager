package taskv2

import "core:fmt"
import "core:strings"
import "core:testing"
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

// Breaking run-scoped integration specifications. Updated for the new public
// contract; execution is deferred to the requested review/manual-testing stage.

workflow_example_definition :: proc(t: ^testing.T, fx: ^Fixture, name: string, spec: string) {
	_,ok,err := workflow_define(&fx.svc,"u1",spec,name)
	testing.expect(t,ok,err.message)
}

@(test)
test_workflow_runs_share_chain_but_not_stage_identity :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fx,ok := fixture_open(t,"runs_same_stage")
	defer fixture_close(fx)
	if !ok do return
	chain := seed_chain(t,fx,"chain_runs",true)
    seed_fleet(fx, chain, "agt_w")
	workflow_example_definition(t,fx,"simple",`{"schema":"workflow.v1","name":"simple","stages":[{"key":"build","brief":{"goal":"Build","verify":"none","output":{"schema":"inline"},"review_roles":[]}}]}`)
	first,aok,aerr := workflow_run(&fx.svc,"u1",Actor{kind=ACTOR_USER,id="u1"},Workflow_Run_Input{chain_id=string(chain.chain_id),ref="simple",request_id="one",inputs_json="{}"})
	second,bok,berr := workflow_run(&fx.svc,"u1",Actor{kind=ACTOR_USER,id="u1"},Workflow_Run_Input{chain_id=string(chain.chain_id),ref="simple",request_id="two",inputs_json="{}"})
	testing.expect(t,aok && bok,fmt.tprintf("%s / %s",aerr.message,berr.message))
	testing.expect(t,first.run_id != second.run_id && first.chain_id == second.chain_id,"one container, separate execution identities")
	tasks,_ := iface.taskchain_list_tasks_by_chain(&fx.repo,chain.chain_id,"u1")
	testing.expect(t,len(tasks)==2,"identical stage keys materialize twice")
	if len(tasks)==2 do testing.expect(t,tasks[0].stage_key == tasks[1].stage_key && tasks[0].workflow_run_id != tasks[1].workflow_run_id,"no stage collision")
	_ = seed_task(t,fx,chain,"ordinary_ticket")
	current,_,_ := iface.taskchain_get_chain(&fx.repo,chain.chain_id)
	testing.expect(t,current.status == .Active,"adding runs never changes chain status or execution type")
}

@(test)
test_workflow_retry_creates_fresh_generation_and_preserves_history :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fx,ok := fixture_open(t,"run_generation")
	defer fixture_close(fx)
	if !ok do return
	chain := seed_chain(t,fx,"chain_retry",true)
    seed_fleet(fx, chain, "agt_w")
	workflow_example_definition(t,fx,"retryable",`{"schema":"workflow.v1","name":"retryable","stages":[{"key":"build","brief":{"goal":"Build","verify":"none","output":{"schema":"inline"},"review_roles":[]}}]}`)
	run,rok,rerr := workflow_run(&fx.svc,"u1",Actor{kind=ACTOR_USER,id="u1"},Workflow_Run_Input{chain_id=string(chain.chain_id),ref="retryable",request_id="one",inputs_json="{}"})
	if !testing.expect(t,rok,rerr.message) do return
	_,cancelled,cerr := workflow_cancel(&fx.svc,run.run_id,"u1",Actor{kind=ACTOR_USER,id="u1"},"change approach",1)
	if !testing.expect(t,cancelled,cerr.message) do return
	retried,ok_retry,retry_err := workflow_retry(&fx.svc,run.run_id,"u1",Actor{kind=ACTOR_USER,id="u1"},"try again",run.revision)
	testing.expect(t,ok_retry,retry_err.message)
	testing.expect(t,retried.current_execution_no==2,"full-run retry advances generation")
    _, duplicate_ok, duplicate_err := workflow_cancel(&fx.svc,run.run_id,"u1",Actor{kind=ACTOR_USER,id="u1"},"late duplicate",1)
    testing.expect(t,duplicate_ok,duplicate_err.message)
    current, current_ok, _ := workflow_context(&fx.svc,run.run_id,"u1")
    testing.expect(t,current_ok && current.execution.execution_no==2 && current.execution.state=="running","late cancellation cannot touch the new generation")
    _, missing_target, target_err := workflow_cancel(&fx.svc,run.run_id,"u1",Actor{kind=ACTOR_USER,id="u1"},"missing target",0)
    testing.expect(t,!missing_target && target_err.code==.Validation_Failed,"cancellation requires an execution target")

	executions,_ := iface.taskchain_list_workflow_executions(&fx.repo,run.run_id,"u1")
	testing.expect(t,len(executions)==2,"old execution remains visible")
	tasks,_ := iface.taskchain_list_tasks_by_chain(&fx.repo,chain.chain_id,"u1")
	testing.expect(t,len(tasks)==2,"fresh tasks instead of parked stage keys")
	for task in tasks {
		testing.expect(t,task.stage_key=="build","stage identity is never rewritten")
		if task.workflow_execution_no==1 do testing.expect(t,task.state==.Cancelled,"old task stays cancelled")
	}
}

@(test)
test_workflow_run_creation_request_is_idempotent :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fx,ok := fixture_open(t,"run_request")
	defer fixture_close(fx)
	if !ok do return
	chain := seed_chain(t,fx,"chain_request",true)
    seed_fleet(fx, chain, "agt_w")
	workflow_example_definition(t,fx,"once",`{"schema":"workflow.v1","name":"once","stages":[{"key":"build","brief":{"goal":"Build","verify":"none","output":{"schema":"inline"},"review_roles":[]}}]}`)
	input := Workflow_Run_Input{chain_id=string(chain.chain_id),ref="once",request_id="same",inputs_json="{}"}
	first,aok,_ := workflow_run(&fx.svc,"u1",Actor{kind=ACTOR_USER,id="u1"},input)
	second,bok,_ := workflow_run(&fx.svc,"u1",Actor{kind=ACTOR_USER,id="u1"},input)
	testing.expect(t,aok && bok && first.run_id==second.run_id,"duplicate request returns existing run")
    equivalent := input
    equivalent.request_id = "canonical"
    equivalent.inputs_json = `{"a":1,"nested":{"z":2,"b":3}}`
    canonical, first_ok, _ := workflow_run(&fx.svc,"u1",Actor{kind=ACTOR_USER,id="u1"},equivalent)
    equivalent.inputs_json = `{"nested":{"b":3,"z":2},"a":1}`
    same, second_ok, _ := workflow_run(&fx.svc,"u1",Actor{kind=ACTOR_USER,id="u1"},equivalent)
    testing.expect(t, first_ok && second_ok && canonical.run_id == same.run_id, "object key order does not change request identity")
	input.inputs_json=`{"changed":true}`
	_,accepted,err := workflow_run(&fx.svc,"u1",Actor{kind=ACTOR_USER,id="u1"},input)
	testing.expect(t,!accepted && err.code==.Conflict,"same request id with changed body rejected")
}

// REQ-MW-2/7/9: proposal decisions are orchestration, not worker authority.
@(test)
test_proposal_decision_requires_chain_owner_or_coordinator :: proc(t: ^testing.T) {
 fx, ok := fixture_open(t,"proposal_authority")
 defer fixture_close(fx)
 if !ok do return
 chain := seed_chain(t,fx,"proposal_auth",true)
 decisions := []string{"approve","reject"}
 for decision in decisions {
  _, _, accepted, err := chain_proposal_decide(&fx.svc,chain.chain_id,"u1",Actor{kind=ACTOR_AGENT,id="unrelated_worker"},decision)
  testing.expect(t,!accepted && err.code==.Forbidden,"unrelated worker cannot decide any proposal")
 }
}

// REQ-MW-2/7: missing fleet coverage fails before any run is stored.
@(test)
test_workflow_fleet_requires_worker_and_named_reviewer :: proc(t: ^testing.T) {
 fx, ok := fixture_open(t,"workflow_fleet_validation")
 defer fixture_close(fx)
 if !ok do return
 chain := seed_chain(t,fx,"fleet_validation",true)
 err := workflow_validate_fleet(&fx.svc,chain,`{"goal":"g"}`)
 testing.expect(t,err.code==.Validation_Failed,"no worker rejected")
 seed_fleet(fx,chain,"worker")
 err = workflow_validate_fleet(&fx.svc,chain,`{"goal":"g","reviewers":["named"]}`)
 testing.expect(t,err.code==.Validation_Failed,"missing named reviewer rejected")
 seed_fleet(fx,chain,"named",roles=`["named-reviewer"]`)
 err = workflow_validate_fleet(&fx.svc,chain,`{"goal":"g","reviewers":["named"]}`)
 testing.expect(t,err.code==.None,"configured named reviewer accepted")
}

// REQ-MW-5/9: the generation cannot close or advance while a Done task's
// bridge merge is queued, in flight, offline, or awaiting recovery.
@(test)
test_workflow_cancel_waits_for_pending_merge :: proc(t: ^testing.T) {
 fx, ok := fixture_open(t,"workflow_merge_fence")
 defer fixture_close(fx)
 if !ok do return
 chain := seed_chain(t,fx,"merge_fence",true)
 seed_fleet(fx,chain,"worker")
 seed_directory(fx,chain,"git_dir","br_1","git")
 workflow_example_definition(t,fx,"mergeable",`{"schema":"workflow.v1","name":"mergeable","stages":[{"key":"build","brief":{"goal":"Build","verify":"none","output":{"schema":"inline"},"review_roles":[]}}]}`)
 run, created, err := workflow_run(&fx.svc,"u1",Actor{kind=ACTOR_USER,id="u1"},Workflow_Run_Input{chain_id=string(chain.chain_id),ref="mergeable",request_id="one",inputs_json="{}"})
 if !testing.expect(t,created,err.message) do return
 wf, _, _ := workflow_context(&fx.svc,run.run_id,"u1")
 tasks, _ := workflow_execution_tasks(&fx.svc,wf)
 if !testing.expect(t,len(tasks)==1,"one generated task") do return
 task := tasks[0]
 task.state = .Done
 task.attempt_no = 1
 task, _, _ = iface.taskchain_save_task(&fx.repo,task)
 _, _, _ = append_event(&fx.repo,&fx.clock,task,hub_actor(),EV_LEASE_GRANTED,`{"kind":"work","bridge_id":"br_1"}`)
 _, _, _ = append_event(&fx.repo,&fx.clock,task,hub_actor(),EV_SUBMITTED,`{}`)
 _, cancelled, cancel_err := workflow_cancel(&fx.svc,run.run_id,"u1",Actor{kind=ACTOR_USER,id="u1"},"change approach",1)
 testing.expect(t,!cancelled && cancel_err.code==.Conflict,"pending merge blocks cancellation")
 testing.expect(t,workflow_merge_allowed(&fx.svc,task),"current merge may settle")
 // Keep the cached projection in sync before cancellation freezes history.
 u, began, _ := begin_uow(&fx.svc)
 if !testing.expect(t,began,"merge-conflict uow") do return
 _, _, recorded, record_err := record_event(&fx.svc,&u,task,hub_actor(),EV_MERGE_CONFLICT,`{}`)
 _, _ = end_uow(&fx.svc,&u,recorded)
 if !testing.expect(t,recorded,record_err.message) do return
 testing.expect(t,workflow_require_merges_settled(&fx.svc,wf).code==.None,"settled conflict releases the generation fence")
 _, cancelled, cancel_err = workflow_cancel(&fx.svc,run.run_id,"u1",Actor{kind=ACTOR_USER,id="u1"},"change approach",1)
 testing.expect(t,cancelled,cancel_err.message)
 testing.expect(t,!workflow_merge_allowed(&fx.svc,task),"cancelled execution is fenced from recovery and jobs")
}
