package main

import "core:strings"
import "core:testing"

// Task System v2 (M2) ctl surface: the brief param builder behind
// `task create/update` and the per-task rendering of a publish 422
// brief_incomplete (both envelopes). Pure procs, no bridge/hub involved.

@(test)
test_task_brief_json_from_flags :: proc(t: ^testing.T) {
	args := []string{
		"ham-ctl", "task", "create", "--title", "x",
		"--goal", "Retry transient 5xx",
		"--acceptance", "retries 3x, with backoff", // comma kept: acceptance is prose
		"--acceptance", "unit test covers 503",
		"--verify", "make test",
		"--input", "#evt_1,facet:t1:1:handoff",
		"--review-role", "reviewer", "--review-role", "security",
		"--auto-submit",
	}
	brief, ok := ctl_task_brief_json(args, "")
	defer delete(brief)
	testing.expect(t, ok, "brief present")
	testing.expect_value(t, brief, `{"goal":"Retry transient 5xx","acceptance":["retries 3x, with backoff","unit test covers 503"],"verify":"make test","inputs":["#evt_1","facet:t1:1:handoff"],"review_roles":["reviewer","security"],"auto_submit":true}`)
}

@(test)
test_task_brief_json_file_base_flags_override :: proc(t: ^testing.T) {
	file := `{"goal":"from file","acceptance":["a1","a2"],"verify":"go test ./...","inputs":["#e9"],"review_roles":["reviewer"],"auto_submit":false,"assignee":"agt_w","budget":{"max_attempts":3},"output":{"schema":"x"},"unknown":1}`
	// no flags: the file is carried (known keys only)
	base, ok := ctl_task_brief_json([]string{"ham-ctl"}, file)
	defer delete(base)
	testing.expect(t, ok, "file alone is a brief")
	testing.expect_value(t, base, `{"goal":"from file","acceptance":["a1","a2"],"verify":"go test ./...","inputs":["#e9"],"review_roles":["reviewer"],"auto_submit":false,"assignee":"agt_w","budget":{"max_attempts":3},"output":{"schema":"x"}}`)

	// flags override field by field; untouched file fields survive
	over, ok2 := ctl_task_brief_json([]string{"ham-ctl", "--goal", "from flag", "--acceptance", "only this", "--auto-submit"}, file)
	defer delete(over)
	testing.expect(t, ok2, "brief present")
	testing.expect(t, strings.has_prefix(over, `{"goal":"from flag","acceptance":["only this"],"verify":"go test ./...",`), "flags win, file fills the rest")
	testing.expect(t, strings.contains(over, `"auto_submit":true`), "--auto-submit overrides the file's false")
	testing.expect(t, strings.contains(over, `"review_roles":["reviewer"]`), "file review_roles kept")
}

@(test)
test_task_brief_json_absent :: proc(t: ^testing.T) {
	_, ok := ctl_task_brief_json([]string{"ham-ctl", "task", "update", "t1", "--title", "only title"}, "")
	testing.expect(t, !ok, "no brief flags, no file -> no brief")
	testing.expect(t, !ctl_task_brief_flags_present([]string{"--title", "x", "--priority", "p1"}), "no brief flags")
	testing.expect(t, ctl_task_brief_flags_present([]string{"--verify", "make"}), "verify is a brief flag")
}

@(test)
test_brief_incomplete_render_agent_envelope :: proc(t: ^testing.T) {
	// Agent mode: the bridge wraps the hub's 422 body as a JSON string in error.message.
	hub := `{"error":{"code":"validation_failed","message":"brief incomplete: ...","details":{"code":"brief_incomplete","tasks":[{"task_id":"task_a","missing":["goal","verify"]},{"task_id":"task_b","missing":["review_role:security"]}]}},"meta":{"request_id":"r1"}}`
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, `{"v":1,"id":"ham-ctl-agent","ok":false,"error":{"code":"hub_error","message":"`)
	json_write_string(&b, hub)
	strings.write_string(&b, `"}}`)
	text, found := ctl_brief_incomplete_render(strings.to_string(b))
	defer delete(text)
	testing.expect(t, found, "brief_incomplete detected through the bridge envelope")
	testing.expect(t, strings.contains(text, "task_a: missing goal, verify\n"), "per-task line a")
	testing.expect(t, strings.contains(text, "task_b: missing review_role:security\n"), "per-task line b")
	testing.expect(t, strings.has_prefix(text, "publish refused: brief incomplete\n"), "header")
}

@(test)
test_brief_incomplete_render_user_envelope_and_negative :: proc(t: ^testing.T) {
	// User mode: the hub body IS the response.
	hub := `{"error":{"code":"validation_failed","message":"brief incomplete","details":{"code":"brief_incomplete","tasks":[{"task_id":"task_z","missing":["acceptance"]}]}},"meta":{}}`
	text, found := ctl_brief_incomplete_render(hub)
	defer delete(text)
	testing.expect(t, found, "detected in the plain hub envelope")
	testing.expect(t, strings.contains(text, "task_z: missing acceptance\n"), "rendered")

	_, other := ctl_brief_incomplete_render(`{"error":{"code":"validation_failed","message":"x","details":{"code":"other"}}}`)
	testing.expect(t, !other, "a different 422 is not rendered as brief_incomplete")
	_, success := ctl_brief_incomplete_render(`{"v":1,"ok":true,"data":{"data":{"chain_id":"c1","publish_state":"published"}}}`)
	testing.expect(t, !success, "success is untouched")
}

@(test)
test_verify_label_and_lease_parse :: proc(t: ^testing.T) {
	label := ctl_verify_label("task_1", 3, "deadbeef")
	defer delete(label)
	testing.expect_value(t, label, "verify task_1 #3 @deadbeef")
	empty := ctl_verify_label("task_1", 1, "")
	defer delete(empty)
	testing.expect_value(t, empty, "verify task_1 #1 @")

	resp := `{"v":1,"id":"ham-ctl-agent","ok":true,"data":{"data":{"status":"current","lease":{"lease_id":"lse_1","task_id":"task_1","attempt_no":2},"task":{"task_id":"task_1","brief":{"goal":"g","verify":"make test"}},"pack":{}}}}`
	lease, ok := ctl_verify_parse_lease(resp)
	testing.expect(t, ok, "lease parsed")
	testing.expect_value(t, lease.status, "current")
	testing.expect_value(t, lease.task_id, "task_1")
	testing.expect_value(t, lease.attempt_no, 2)
	testing.expect_value(t, lease.verify_cmd, "make test")

	w := ctl_verify_parse_wait(`{"v":1,"id":"x","ok":true,"data":{"session_id":"sh_1","status":"running","timed_out":true}}`)
	testing.expect(t, w.ok && w.timed_out && !w.finished, "timeout slice")
	d := ctl_verify_parse_wait(`{"v":1,"id":"x","ok":true,"data":{"exec_id":"sh_1","session_id":"sh_1","status":"exited","exit_code":2,"output":"FAIL\n","truncated":false}}`)
	testing.expect(t, d.ok && d.finished && d.has_code, "finished")
	testing.expect_value(t, d.exit_code, 2)
	testing.expect_value(t, d.output, "FAIL\n")
	e := ctl_verify_parse_wait(`{"v":1,"id":"x","ok":false,"error":{"code":"not_found","message":"no"}}`)
	testing.expect(t, !e.ok, "error envelope")
}

@(test)
test_verify_slices_heartbeat :: proc(t: ^testing.T) {
	State :: struct {
		wait_calls: int,
		hb_notes:   [dynamic]string,
	}
	st := State{hb_notes = make([dynamic]string, context.temp_allocator)}
	fake_call :: proc(ctx: rawptr, method, params_json: string) -> (string, bool) {
		s := (^State)(ctx)
		if method == "agent.shell.wait" {
			s.wait_calls += 1
			if s.wait_calls <= 2 {
				return `{"v":1,"id":"x","ok":true,"data":{"session_id":"sh_1","status":"running","timed_out":true}}`, true
			}
			return `{"v":1,"id":"x","ok":true,"data":{"session_id":"sh_1","status":"exited","exit_code":0,"output":"ALL PASS\n"}}`, true
		}
		if method == "agent.lease.heartbeat" {
			append(&s.hb_notes, strings.clone(params_json, context.temp_allocator))
			return `{"v":1,"id":"x","ok":true,"data":{}}`, true
		}
		return "", false
	}
	w, err := ctl_verify_wait_with_heartbeats("sh_1", 300_000, &st, fake_call)
	testing.expect_value(t, err, "")
	testing.expect(t, w.ok && w.finished && w.has_code && w.exit_code == 0, "finished after 3 wait slices")
	testing.expect_value(t, st.wait_calls, 3)
	testing.expect_value(t, len(st.hb_notes), 2)
	if len(st.hb_notes) == 2 {
		testing.expect_value(t, st.hb_notes[0], `{"note":"verify running"}`)
		testing.expect_value(t, st.hb_notes[1], "{}")
	}
}

@(test)
test_command_tokens_skips_v2_flag_values :: proc(t: ^testing.T) {
	tokens := command_tokens([]string{"ham-ctl", "review", "post", "--verdict", "approve", "--findings-file", "f.json", "--on-behalf-of", "user"})
	defer delete(tokens)
	testing.expect_value(t, len(tokens), 2)
	if len(tokens) == 2 {
		testing.expect_value(t, tokens[0], "review")
		testing.expect_value(t, tokens[1], "post")
	}
}

// The handoff flags take values: `lease switch --dead-end x task_b` must keep
// task_b as the positional, not x.
@(test)
test_command_tokens_skips_handoff_flag_values :: proc(t: ^testing.T) {
	tokens := command_tokens([]string{"ham-ctl", "lease", "switch", "--dead-end", "tried x", "--next-steps", "do y", "--decision", "z", "task_b", "--summary", "s"})
	defer delete(tokens)
	testing.expect_value(t, len(tokens), 3)
	if len(tokens) == 3 do testing.expect_value(t, tokens[2], "task_b")
}

@(test)
test_m3_ctl_params_and_verify_helpers :: proc(t: ^testing.T) {
	// 1. --require-independent-verify in brief
	brief, ok := ctl_task_brief_json([]string{"ham-ctl", "task", "create", "--goal", "g", "--require-independent-verify"}, "")
	defer delete(brief)
	testing.expect(t, ok, "brief present")
	testing.expect(t, strings.contains(brief, `"require_independent_verify":true`), "require_independent_verify flag")

	// 2. lease submit --artifacts-file
	sub_p, sub_ok := ctl_v2_lease_submit_params(
		[]string{"ham-ctl", "lease", "submit", "--summary", "done"},
		"",
		"",
		`{"schema_version":1,"files":[{"path":"a.txt","kind":"report"}],"metrics":{"p99_ms":12}}`,
		"/tmp/work",
	)
	defer delete(sub_p)
	testing.expect(t, sub_ok, "lease submit params ok")
	testing.expect(t, strings.contains(sub_p, `"artifacts":{"schema_version":1,`), "artifacts included in lease submit params")

	// 3. review post --on-behalf-of user
	rev_p, rev_ok := ctl_v2_review_post_params(
		[]string{"post", "t1"},
		[]string{"ham-ctl", "review", "post", "t1", "--verdict", "approve", "--on-behalf-of", "user"},
		"",
	)
	defer delete(rev_p)
	testing.expect(t, rev_ok, "review post params ok")
	testing.expect(t, strings.contains(rev_p, `"on_behalf_of":"user"`), "on_behalf_of included in review post params")
	rev_s, rev_s_ok := ctl_v2_review_post_params(
		[]string{"post", "t1"},
		[]string{"ham-ctl", "review", "post", "t1", "--verdict", "request_changes", "--summary", "zero case crashes"},
		"",
	)
	defer delete(rev_s)
	testing.expect(t, rev_s_ok && strings.contains(rev_s, `"summary":"zero case crashes"`), "review post --summary reaches the hub")

	// 4. task-chain summary set (positional, --body, --file)
	sum_p, sum_ok := ctl_v2_task_chain_summary_params(
		[]string{"set", "All foundation tasks done."},
		[]string{"ham-ctl", "task-chain", "summary", "set", "All foundation tasks done."},
		"",
	)
	defer delete(sum_p)
	testing.expect(t, sum_ok, "task-chain summary params ok")
	testing.expect_value(t, sum_p, `{"summary":"All foundation tasks done."}`)

	sum_body, sum_body_ok := ctl_v2_task_chain_summary_params(
		[]string{"set"},
		[]string{"ham-ctl", "task-chain", "summary", "set", "--body", "Curated via --body flag.", "--chain", "ch_1"},
		"",
	)
	defer delete(sum_body)
	testing.expect(t, sum_body_ok, "task-chain summary --body params ok")
	testing.expect_value(t, sum_body, `{"chain_id":"ch_1","summary":"Curated via --body flag."}`)

	sum_file, sum_file_ok := ctl_v2_task_chain_summary_params(
		[]string{"set"},
		[]string{"ham-ctl", "task-chain", "summary", "set", "--file", "/tmp/sum.md"},
		"",
		"Curated via --file flag.\n",
	)
	defer delete(sum_file)
	testing.expect(t, sum_file_ok, "task-chain summary --file params ok")
	testing.expect_value(t, sum_file, `{"summary":"Curated via --file flag."}`)

	// 5. task-chain propose --file --auto-approve
	prop_p, prop_ok := ctl_v2_task_chain_propose_params(
		[]string{"ham-ctl", "task-chain", "propose", "--file", "p.json", "--auto-approve"},
		`{"kind":"split","rationale":"Need child","tasks":[{"title":"New"}]}`,
	)
	defer delete(prop_p)
	testing.expect(t, prop_ok, "task-chain propose params ok")
	testing.expect(t, strings.contains(prop_p, `"tasks":[{"title":"New"}]`), "tasks carried from proposal file")
	testing.expect(t, strings.contains(prop_p, `"auto_approve":true`), "auto_approve appended")

	// 6. task-chain fleet set placement fields
	fleet_b, fleet_ok := ctl_v2_fleet_set_body([]string{
		"ham-ctl", "task-chain", "fleet", "set", "ch_1",
		"--capacity", "4", "--min-warm", "1", "--idle-ttl", "300",
		"--roles", "worker,reviewer",
		"--bridge", "br_main", "--provider", "claude", "--model", "opus",
		"--bridge-models", `{"br_main":{"provider":"claude","model":"opus"}}`,
	})
	defer delete(fleet_b)
	testing.expect(t, fleet_ok, "fleet set body ok")
	testing.expect(t, strings.contains(fleet_b, `"capacity":4`), "capacity")
	testing.expect(t, strings.contains(fleet_b, `"roles":["worker","reviewer"]`), "roles")
	testing.expect(t, strings.contains(fleet_b, `"bridge_id":"br_main"`), "bridge_id")
	testing.expect(t, strings.contains(fleet_b, `"bridge_models":{"br_main":`), "bridge_models")

	// 7. verify independent label & lease parse (auto_submit + vcs.head/base)
	ind_lbl := ctl_verify_label("task_1", 2, "abc1234", true)
	defer delete(ind_lbl)
	testing.expect_value(t, ind_lbl, "verify task_1 #2 @abc1234 independent")

	resp := `{"v":1,"id":"x","ok":true,"data":{"data":{"status":"current","lease":{"lease_id":"l1","task_id":"t1","attempt_no":1,"vcs":{"base":"b000","head":"h111"}},"task":{"task_id":"t1","brief":{"goal":"g","verify":"make test","auto_submit":true}},"pack":{}}}}`
	lse, lok := ctl_verify_parse_lease(resp)
	testing.expect(t, lok, "lease parsed")
	testing.expect(t, lse.auto_submit, "auto_submit parsed")
	testing.expect_value(t, lse.vcs_base, "b000")
	testing.expect_value(t, lse.vcs_head, "h111")
}

@(test)
test_m3b_workflow_ctl_params :: proc(t: ^testing.T) {
	// 1. command_tokens skips --inputs-file, --stage, --workflow, --on-output-workflow, --output-schema
	toks := command_tokens([]string{"ham-ctl", "workflow", "run", "fix_flaky_tests", "--chain", "ch_1", "--inputs-file", "in.json", "--input", "target=auth", "--request-id", "stable-key", "--after", "task:t_1"})
	defer delete(toks)
	testing.expect_value(t, len(toks), 3)
	if len(toks) == 3 {
		testing.expect_value(t, toks[0], "workflow")
		testing.expect_value(t, toks[1], "run")
		testing.expect_value(t, toks[2], "fix_flaky_tests")
	}

	// 2. workflow define params
	def_p, def_ok := ctl_v2_workflow_define_params(
		[]string{"ham-ctl", "workflow", "define", "--file", "wf.json", "--name", "custom_wf"},
		`{"kind":"workflow","v":1,"name":"custom_wf","stages":[]}`,
	)
	defer delete(def_p)
	testing.expect(t, def_ok, "workflow define params ok")
	testing.expect(t, strings.contains(def_p, `"name":"custom_wf"`), "name included")
	testing.expect(t, strings.contains(def_p, `"definition":{"kind":"workflow","v":1,`), "definition included")

	// 3. workflow run params (merges --inputs-file with repeated --input k=v)
	run_p, run_ok := ctl_v2_workflow_run_params(
		[]string{"run", "explore_plan_build"},
		[]string{"ham-ctl", "workflow", "run", "explore_plan_build", "--chain", "ch_wf", "--request-id", "stable-key", "--input", "goal=Add auth", "--input", "verify_cmd=make test"},
		`{"goal":"from_file","extra":"kept"}`,
	)
	defer delete(run_p)
	testing.expect(t, run_ok, "workflow run params ok")
	testing.expect(t, strings.contains(run_p, `"ref":"explore_plan_build"`), "workflow name included")
	testing.expect(t, strings.contains(run_p, `"chain_id":"ch_wf"`), "chain_id included")
	testing.expect(t, strings.contains(run_p, `"goal":"Add auth"`), "--input overrides --inputs-file key")
	testing.expect(t, strings.contains(run_p, `"extra":"kept"`), "untouched --inputs-file key preserved")
	testing.expect(t, strings.contains(run_p, `"verify_cmd":"make test"`), "second --input included")

	// 4. workflow output params (1 positional vs 2 positionals)
	cid1, stg1, out1, ok1 := ctl_v2_workflow_output_params(
		[]string{"output", "ch_1", "plan"},
		[]string{"ham-ctl", "workflow", "output", "ch_1", "plan"},
	)
	defer delete(out1)
	testing.expect(t, ok1 && cid1 == "ch_1" && stg1 == "plan", "2-positional workflow output")
	testing.expect_value(t, out1, `{"run_id":"ch_1","stage_key":"plan"}`)

	cid2, stg2, out2, ok2 := ctl_v2_workflow_output_params(
		[]string{"output", "plan"},
		[]string{"ham-ctl", "workflow", "output", "plan"},
	)
	defer delete(out2)
	testing.expect(t, !ok2 && cid2 == "" && stg2 == "", "stage output requires an explicit run and stage")
	testing.expect_value(t, out2, "")

    // Whole-run retry requires a concurrency token and a reason.
    rcid, rtgt, retry_p, rok := ctl_v2_workflow_retry_params(
        []string{"retry", "run_1"},
        []string{"ham-ctl", "workflow", "retry", "run_1", "--expected-revision", "2", "--reason", "correct inputs"},
    )
    defer delete(retry_p)
    testing.expect(t, rok && rcid == "run_1" && rtgt == "", "whole-run retry")
    testing.expect_value(t, retry_p, `{"run_id":"run_1","reason":"correct inputs","expected_revision":2}`)
    _, _, _, stage_retry := ctl_v2_workflow_retry_params([]string{"retry", "run_1", "plan"}, []string{"--cascade"})
    testing.expect(t, !stage_retry, "obsolete stage/cascade retry rejected")

	// 6. brief string output + on_output and workflow proposal
	brief_wf, bok := ctl_task_brief_json(
		[]string{"ham-ctl", "task", "create", "--goal", "triage", "--output-schema", "task_list.v1", "--on-output-workflow", "fix_flaky_tests"},
		"",
	)
	defer delete(brief_wf)
	testing.expect(t, bok, "brief with output-schema and on-output-workflow ok")
	testing.expect(t, strings.contains(brief_wf, `"output":"task_list.v1"`), "string output contract")
	testing.expect(t, strings.contains(brief_wf, `"on_output":{"start_workflow":"fix_flaky_tests"}`), "on_output start_workflow")

	wf_prop, wpok := ctl_v2_task_chain_propose_params(
		[]string{"ham-ctl", "task-chain", "propose", "--file", "wf_prop.json", "--auto-approve"},
		`{"kind":"workflow_run","workflow":"fix_flaky_tests","inputs":{"target":"auth"}}`,
	)
	defer delete(wf_prop)
	testing.expect(t, wpok, "workflow proposal params ok")
	testing.expect(t, strings.contains(wf_prop, `"workflow":"fix_flaky_tests"`), "workflow ref in proposal")
	testing.expect(t, strings.contains(wf_prop, `"inputs":{"target":"auth"}`), "inputs in proposal")
}


// REQ-MW-5/9: cancel always identifies an execution; delayed commands cannot
// silently retarget whichever generation happens to be current.
@(test)
test_workflow_cancel_params_require_execution :: proc(t: ^testing.T) {
 tokens := []string{"cancel","wrun_1"}
 missing, _ := ctl_v2_workflow_cancel_params(tokens,nil)
 testing.expect_value(t,missing,"")
 id, params := ctl_v2_workflow_cancel_params(tokens,[]string{"--execution","2","--reason","stop"})
 defer delete(params)
 testing.expect_value(t,id,"wrun_1")
 testing.expect(t,strings.contains(params,`"execution_no":2`),"execution is carried through the transport")
}
