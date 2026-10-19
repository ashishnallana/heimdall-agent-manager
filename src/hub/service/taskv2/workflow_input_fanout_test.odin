package taskv2

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Workflow-input fan-out: `for_each: "inputs.<array-field>"`.

@(private = "file")
FANOUT_SPEC :: `{"schema":"workflow.v1","name":"fanout_inputs","inputs":{"subtopics":{"type":"array","required":true}},"stages":[
	{"key":"write","title":"Write {{item.title}}{{item}}","for_each":"inputs.subtopics","brief":{"goal":"Write {{item.title}} #{{stage.index}}/{{stage.count}}","acceptance":["done"],"verify":"none","review_roles":[]}},
	{"key":"merge","depends_on":["write"],"title":"Merge","brief":{"goal":"Merge","acceptance":["merged"],"verify":"none","review_roles":[]}}
]}`

@(private = "file")
fanout_stage_tasks :: proc(fx: ^Fixture, chain: domain.Task_Chain, run_id: domain.Workflow_Run_ID, stage: string, execution_no := 1) -> [dynamic]domain.Task {
	out := make([dynamic]domain.Task, context.temp_allocator)
	tasks, _ := iface.taskchain_list_tasks_by_chain(&fx.repo, chain.chain_id, "u1")
	for task in tasks {
		if task.workflow_run_id == run_id && task.stage_key == stage && task.workflow_execution_no == execution_no do append(&out, task)
	}
	return out
}

@(private = "file")
fanout_find_index :: proc(tasks: []domain.Task, index: int) -> (domain.Task, bool) {
	for task in tasks do if task.stage_index == index do return task, true
	return {}, false
}

@(test)
test_workflow_input_fan_out_definition_validation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fx, ok := fixture_open(t, "wf_input_fanout_define")
	defer fixture_close(fx)
	if !ok do return
	_, dok, derr := workflow_define(&fx.svc, "u1", FANOUT_SPEC)
	testing.expect(t, dok, fmt.tprintf("inputs.<array> for_each accepted at define: %s", derr.message))
	// Undeclared inputs are accepted (validated at run time) when no inputs are declared.
	_, uok, uerr := workflow_define(&fx.svc, "u1", `{"schema":"workflow.v1","name":"undeclared","stages":[{"key":"w","for_each":"inputs.topics","brief":{"goal":"{{item}}","acceptance":["a"],"verify":"none"}}]}`)
	testing.expect(t, uok, uerr.message)
	_, aok, aerr := workflow_define(&fx.svc, "u1", `{"schema":"workflow.v1","name":"alias","inputs":[{"name":"topics","type":"list"}],"stages":[{"key":"w","for_each":"workflow.input.topics","brief":{"goal":"{{item}}","acceptance":["a"],"verify":"none"}}]}`)
	testing.expect(t, aok, aerr.message)

	bad := [?]string{
		// declared scalar type
		`{"schema":"workflow.v1","name":"b1","inputs":{"topics":{"type":"string"}},"stages":[{"key":"w","for_each":"inputs.topics","brief":{"goal":"g","acceptance":["a"],"verify":"none"}}]}`,
		// shorthand scalar type
		`{"schema":"workflow.v1","name":"b2","inputs":{"topics":"string"},"stages":[{"key":"w","for_each":"inputs.topics","brief":{"goal":"g","acceptance":["a"],"verify":"none"}}]}`,
		// undeclared while other inputs are declared
		`{"schema":"workflow.v1","name":"b3","inputs":{"goal":"string"},"stages":[{"key":"w","for_each":"inputs.topics","brief":{"goal":"g","acceptance":["a"],"verify":"none"}}]}`,
		// nested path
		`{"schema":"workflow.v1","name":"b4","stages":[{"key":"w","for_each":"inputs.a.b","brief":{"goal":"g","acceptance":["a"],"verify":"none"}}]}`,
		// non-array default
		`{"schema":"workflow.v1","name":"b5","inputs":{"topics":{"type":"array","default":"x"}},"stages":[{"key":"w","for_each":"inputs.topics","brief":{"goal":"g","acceptance":["a"],"verify":"none"}}]}`,
		// gate cannot fan out
		`{"schema":"workflow.v1","name":"b6","stages":[{"key":"w","kind":"gate","for_each":"inputs.topics","approver":"user"}]}`,
	}
	for spec, i in bad {
		_, bok, berr := workflow_define(&fx.svc, "u1", spec)
		testing.expect(t, !bok && berr.code == .Validation_Failed && strings.contains(berr.details_json, "workflow_invalid"), fmt.tprintf("bad spec %d rejected (got ok=%v %s)", i, bok, berr.message))
	}
	// Stage-output fan-out keeps parsing.
	_, sok, serr := workflow_define(&fx.svc, "u1", `{"schema":"workflow.v1","name":"stage_out","stages":[
		{"key":"scan","brief":{"goal":"g","acceptance":["a"],"verify":"none","output":{"schema":"task_list.v1"}}},
		{"key":"fix","depends_on":["scan"],"for_each":"scan.outputs[0].tasks","brief":{"goal":"{{item.goal}}","acceptance":["a"],"verify":"none"}}]}`)
	testing.expect(t, sok, serr.message)
}

@(test)
test_workflow_input_fan_out_objects_scalars_and_idempotence :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fx, ok := fixture_open(t, "wf_input_fanout_run")
	defer fixture_close(fx)
	if !ok do return
	chain := seed_chain(t, fx, "chain_fanout", true)
	seed_fleet(fx, chain, "agt_w")
	user := Actor{kind = ACTOR_USER, id = "u1"}
	workflow_example_definition(t, fx, "fanout_inputs", FANOUT_SPEC)

	// Object items, no upstream echo stage.
	run, rok, rerr := workflow_run(&fx.svc, "u1", user, Workflow_Run_Input{chain_id = string(chain.chain_id), ref = "fanout_inputs", request_id = "objects",
		inputs_json = `{"subtopics":[{"key":"alpha","title":"Alpha"},{"key":"beta","title":"Beta","priority":"p0"},{"title":"Gamma"}]}`})
	if !testing.expect(t, rok, rerr.message) do return
	write := fanout_stage_tasks(fx, chain, run.run_id, "write")
	testing.expectf(t, len(write) == 3, "one task per input item, got %d", len(write))
	expect_titles := [?]string{"Write Alpha", "Write Beta", "Write Gamma"}
	for want, idx in expect_titles {
		task, found := fanout_find_index(write[:], idx)
		if !testing.expectf(t, found, "stage_index %d present", idx) do continue
		testing.expectf(t, strings.has_prefix(task.title, want), "index %d title %q starts with %q", idx, task.title, want)
		testing.expectf(t, strings.contains(task.brief_json, fmt.tprintf("#%d/3", idx)), "index placeholders substituted: %s", task.brief_json)
		testing.expectf(t, strings.contains(task.generated_by_json, `"input":"subtopics"`), "provenance names the input: %s", task.generated_by_json)
	}
	if beta, found := fanout_find_index(write[:], 1); found {
		testing.expect(t, beta.priority == .P0, "item priority honoured")
		testing.expect(t, strings.contains(beta.generated_by_json, `"item_key":"beta"`), "item key recorded")
	}
	if gamma, found := fanout_find_index(write[:], 2); found {
		testing.expect(t, strings.contains(gamma.generated_by_json, `"item_key":"item_2"`), "keyless item gets a positional key")
	}
	testing.expect(t, len(fanout_stage_tasks(fx, chain, run.run_id, "merge")) == 0, "downstream stage waits for the fan-out")

	// Repeated reconciliation never duplicates rows.
	for _ in 0 ..< 3 {
		u, began, _ := begin_uow(&fx.svc)
		if !testing.expect(t, began, "begin uow") do return
		current, _, _ := iface.taskchain_get_chain(&fx.repo, chain.chain_id)
		_, rec_ok, rec_err := workflow_reconcile_chain(&fx.svc, &u, current)
		testing.expect(t, rec_ok, rec_err.message)
		_, _ = end_uow(&fx.svc, &u, rec_ok)
	}
	testing.expect(t, len(fanout_stage_tasks(fx, chain, run.run_id, "write")) == 3, "reconciliation is idempotent")

	// Scalar items: {{item}} is the value; {{item.title}} is empty.
	scalars, sok, serr := workflow_run(&fx.svc, "u1", user, Workflow_Run_Input{chain_id = string(chain.chain_id), ref = "fanout_inputs", request_id = "scalars",
		inputs_json = `{"subtopics":["x-ray","yak",3,1.5]}`})
	if !testing.expect(t, sok, serr.message) do return
	sw := fanout_stage_tasks(fx, chain, scalars.run_id, "write")
	testing.expectf(t, len(sw) == 4, "scalar fan-out, got %d", len(sw))
	scalar_titles := [?]string{"Write x-ray", "Write yak", "Write 3", "Write 1.5"}
	for want, idx in scalar_titles {
		if task, found := fanout_find_index(sw[:], idx); found {
			testing.expectf(t, task.title == want, "scalar index %d title %q == %q", idx, task.title, want)
		}
	}

	// Retry re-expands from the immutable snapshot with identical indexes.
	_, cancelled, cerr := workflow_cancel(&fx.svc, scalars.run_id, "u1", user, "redo", 1)
	if !testing.expect(t, cancelled, cerr.message) do return
	retried, retry_ok, retry_err := workflow_retry(&fx.svc, scalars.run_id, "u1", user, "again", scalars.revision)
	if !testing.expect(t, retry_ok, retry_err.message) do return
	again := fanout_stage_tasks(fx, chain, scalars.run_id, "write", retried.current_execution_no)
	testing.expectf(t, len(again) == 4, "retry re-expands all items, got %d", len(again))
	for want, idx in scalar_titles {
		if task, found := fanout_find_index(again[:], idx); found do testing.expectf(t, task.title == want, "retry index %d title %q", idx, task.title)
	}
}

@(test)
test_workflow_input_fan_out_invalid_and_empty_inputs :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fx, ok := fixture_open(t, "wf_input_fanout_invalid")
	defer fixture_close(fx)
	if !ok do return
	chain := seed_chain(t, fx, "chain_fanout_bad", true)
	seed_fleet(fx, chain, "agt_w")
	user := Actor{kind = ACTOR_USER, id = "u1"}
	workflow_example_definition(t, fx, "fanout_inputs", FANOUT_SPEC)
	workflow_example_definition(t, fx, "fanout_optional", `{"schema":"workflow.v1","name":"fanout_optional","stages":[
		{"key":"prep","brief":{"goal":"Prep","acceptance":["a"],"verify":"none","review_roles":[]}},
		{"key":"write","depends_on":["prep"],"for_each":"inputs.topics","brief":{"goal":"{{item}}","acceptance":["a"],"verify":"none","review_roles":[]}}]}`)

	cases := [?]struct{ref, inputs: string}{
		{"fanout_inputs", `{}`},
		{"fanout_inputs", `{"subtopics":"not a list"}`},
		{"fanout_inputs", `{"subtopics":{"a":1}}`},
		{"fanout_inputs", `{"subtopics":null}`},
		// the stage is not first: the run must still fail before ANY stage dispatches
		{"fanout_optional", `{}`},
	}
	for c, i in cases {
		_, rok, rerr := workflow_run(&fx.svc, "u1", user, Workflow_Run_Input{chain_id = string(chain.chain_id), ref = c.ref, request_id = fmt.tprintf("bad_%d", i), inputs_json = c.inputs})
		testing.expectf(t, !rok && rerr.code == .Validation_Failed, "invalid inputs %d rejected (ok=%v %s)", i, rok, rerr.message)
	}
	runs, _ := iface.taskchain_list_workflow_runs(&fx.repo, chain.chain_id, "u1")
	tasks, _ := iface.taskchain_list_tasks_by_chain(&fx.repo, chain.chain_id, "u1")
	testing.expectf(t, len(runs) == 0 && len(tasks) == 0, "invalid inputs create nothing (runs=%d tasks=%d)", len(runs), len(tasks))

	// Empty array: the fan-out stage completes with zero items and downstream proceeds.
	run, eok, eerr := workflow_run(&fx.svc, "u1", user, Workflow_Run_Input{chain_id = string(chain.chain_id), ref = "fanout_inputs", request_id = "empty", inputs_json = `{"subtopics":[]}`})
	if !testing.expect(t, eok, eerr.message) do return
	testing.expect(t, len(fanout_stage_tasks(fx, chain, run.run_id, "write")) == 0, "empty array creates no stage tasks")
	testing.expect(t, len(fanout_stage_tasks(fx, chain, run.run_id, "merge")) == 1, "downstream stage materialises after an empty fan-out")
	wf, _, _ := workflow_context(&fx.svc, run.run_id, "u1")
	testing.expect(t, is_stage_marked_empty_done(&fx.svc, wf, "write"), "empty fan-out recorded as a zero-item expansion")
}

@(test)
test_workflow_fan_out_size_cap :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fx, ok := fixture_open(t, "wf_input_fanout_cap")
	defer fixture_close(fx)
	if !ok do return
	chain := seed_chain(t, fx, "chain_fanout_cap", true)
	seed_fleet(fx, chain, "agt_w")
	user := Actor{kind = ACTOR_USER, id = "u1"}
	workflow_example_definition(t, fx, "fanout_inputs", FANOUT_SPEC)

	// One item over the cap: rejected before the run (or any task) exists.
	b := strings.builder_make()
	strings.write_string(&b, `{"subtopics":[`)
	for i in 0 ..< WORKFLOW_FAN_OUT_MAX_ITEMS + 1 {
		if i > 0 do strings.write_byte(&b, ',')
		fmt.sbprintf(&b, `"t%d"`, i)
	}
	strings.write_string(&b, `]}`)
	_, rok, rerr := workflow_run(&fx.svc, "u1", user, Workflow_Run_Input{chain_id = string(chain.chain_id), ref = "fanout_inputs", request_id = "too_many", inputs_json = strings.to_string(b)})
	testing.expectf(t, !rok && rerr.code == .Validation_Failed && strings.contains(rerr.details_json, "workflow_input_invalid"), "oversized input fan-out rejected (ok=%v %s)", rok, rerr.message)
	runs, _ := iface.taskchain_list_workflow_runs(&fx.repo, chain.chain_id, "u1")
	tasks, _ := iface.taskchain_list_tasks_by_chain(&fx.repo, chain.chain_id, "u1")
	testing.expectf(t, len(runs) == 0 && len(tasks) == 0, "oversized input creates nothing (runs=%d tasks=%d)", len(runs), len(tasks))

	// The same limit applies to stage-output fan-out (checked at expansion).
	testing.expect(t, workflow_check_fan_out_size("fix", "scan.outputs[0].tasks", WORKFLOW_FAN_OUT_MAX_ITEMS, false).code == .None, "cap is inclusive")
	over := workflow_check_fan_out_size("fix", "scan.outputs[0].tasks", WORKFLOW_FAN_OUT_MAX_ITEMS + 1, false)
	testing.expectf(t, over.code == .Validation_Failed && strings.contains(over.details_json, "workflow_fan_out_too_large"), "stage-output over cap fails: %s", over.message)
}

@(test)
test_workflow_input_fan_out_item_rendering_and_defaults :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fx, ok := fixture_open(t, "wf_input_fanout_render")
	defer fixture_close(fx)
	if !ok do return
	chain := seed_chain(t, fx, "chain_fanout_render", true)
	seed_fleet(fx, chain, "agt_w")
	user := Actor{kind = ACTOR_USER, id = "u1"}
	workflow_example_definition(t, fx, "fanout_inputs", FANOUT_SPEC)
	workflow_example_definition(t, fx, "fanout_default", `{"schema":"workflow.v1","name":"fanout_default","inputs":{"topics":{"type":"array","required":false,"default":["a","b"]}},"stages":[
		{"key":"w","title":"T {{item}}","for_each":"inputs.topics","brief":{"goal":"All {{inputs.topics}}","acceptance":["a"],"verify":"none","review_roles":[]}}]}`)

	// A string item renders decoded, not as escaped JSON; scalar items have no
	// fields, so a "priority"-looking string does not override and item_key is positional.
	run, rok, rerr := workflow_run(&fx.svc, "u1", user, Workflow_Run_Input{chain_id = string(chain.chain_id), ref = "fanout_inputs", request_id = "escaped",
		inputs_json = `{"subtopics":["say \"hi\" \\ é"]}`})
	if !testing.expect(t, rok, rerr.message) do return
	w := fanout_stage_tasks(fx, chain, run.run_id, "write")
	if testing.expectf(t, len(w) == 1, "one task, got %d", len(w)) {
		testing.expectf(t, w[0].title == "Write say \"hi\" \\ é", "decoded string item, got %q", w[0].title)
		testing.expectf(t, strings.contains(w[0].generated_by_json, `"item_key":"item_0"`), "scalar item_key positional: %s", w[0].generated_by_json)
	}

	// Missing and null inputs fall back to the declared array default, and
	// {{inputs.<array>}} renders that default as JSON.
	for inputs, i in ([?]string{`{}`, `{"topics":null}`}) {
		dr, dok, derr := workflow_run(&fx.svc, "u1", user, Workflow_Run_Input{chain_id = string(chain.chain_id), ref = "fanout_default", request_id = fmt.tprintf("default_%d", i), inputs_json = inputs})
		if !testing.expect(t, dok, derr.message) do continue
		dt := fanout_stage_tasks(fx, chain, dr.run_id, "w")
		testing.expectf(t, len(dt) == 2, "default array expands (%s), got %d", inputs, len(dt))
		for task in dt {
			testing.expectf(t, strings.contains(task.brief_json, `All [\"a\",\"b\"]`), "default renders in {{inputs.topics}}: %s", task.brief_json)
		}
	}
}
