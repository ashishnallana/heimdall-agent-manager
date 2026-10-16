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
	tokens := command_tokens([]string{"ham-ctl", "review", "post", "--verdict", "approve", "--findings-file", "f.json"})
	defer delete(tokens)
	testing.expect_value(t, len(tokens), 2)
	if len(tokens) == 2 {
		testing.expect_value(t, tokens[0], "review")
		testing.expect_value(t, tokens[1], "post")
	}
}
