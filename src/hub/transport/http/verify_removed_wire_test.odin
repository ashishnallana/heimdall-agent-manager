package http

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import taskv2 "odin_test:hub/service/taskv2"
import jsonx "odin_test:lib/jsonx"

// M2: an old ham-ctl still sends verify / skip_verify / skip_verify_reason /
// auto on submit. The submit succeeds, nothing is gated or executed, and the
// response names the dropped fields in a verify_removed warning.
@(test)
test_legacy_submit_verify_params_are_dropped_with_warning :: proc(t: ^testing.T) {
	f := wire_setup(t, "verify_removed")
	defer wire_teardown(f)
	engine := taskv2.new_service(&f.tc_repo, &f.ag_repo, &f.br_repo, &f.clock, &f.ids)
	f.ah.task_engine = &engine
	task := domain.Task{task_id = "wire_legacy", chain_id = f.chain_id, owner_user_id = f.owner, title = "work", publish_state = .Published, state = .In_Progress, attempt_no = 1, brief_json = `{"goal":"g","acceptance":["a"]}`, created_at = "2026-10-01T00:00:00Z", updated_at = "2026-10-01T00:00:00Z"}
	_, _, _ = iface.taskchain_save_task(&f.tc_repo, task)
	_, _, _ = iface.taskchain_save_lease(&f.tc_repo, domain.Task_Lease{lease_id = "wire_legacy_lease", task_id = task.task_id, chain_id = f.chain_id, owner_user_id = f.owner, attempt_no = 1, holder_instance_id = f.instance_id, kind = domain.LEASE_KIND_WORK, confirmed_at = "2026-10-01T00:00:00Z", expires_at = "2099-01-01T00:00:00Z"})
	resp := agent_action_lease_submit_handler(&f.ah, wire_agent_request(f, "lease/submit", `{"params":{"summary":"done; ran the unit tests","verify":"none","skip_verify":true,"skip_verify_reason":"  ","auto":true}}`))
	if !testing.expectf(t, resp.status == 200, "legacy submit accepted: %s", resp.body) do return
	data, _ := jsonx.extract_raw_object(resp.body, "data", true, context.temp_allocator)
	warnings, has_warnings := jsonx.extract_raw_array(data, "warnings", true, context.temp_allocator)
	testing.expectf(t, has_warnings && strings.contains(warnings, `"code":"verify_removed"`), "verify_removed warning present: %s", resp.body)
	for field in ([]string{"verify", "skip_verify", "skip_verify_reason", "auto"}) {
		testing.expectf(t, strings.contains(warnings, strings.concatenate({`"`, field, `"`}, context.temp_allocator)), "warning names %s", field)
	}
	handoff, ok := taskv2.get_facet(&engine, task, 1, taskv2.FACET_HANDOFF)
	testing.expect(t, ok && strings.contains(handoff.body_json, "ran the unit tests") && !strings.contains(handoff.body_json, "skip_verify"), "summary stored; no skip reason recorded")
	_, has_verify := taskv2.get_facet(&engine, task, 1, taskv2.FACET_VERIFY)
	testing.expect(t, !has_verify, "no verify facet")
}

// A submit without the removed params carries no warnings member at all.
@(test)
test_submit_without_legacy_params_has_no_warnings :: proc(t: ^testing.T) {
	testing.expect_value(t, with_verify_removed_warnings(`{"outcome":"done"}`, submit_verify_removed_fields(`{"summary":"x"}`)), `{"outcome":"done"}`)
	testing.expect_value(t, with_response_warnings(`{}`, `"a"`), `{"warnings":["a"]}`)
	testing.expect_value(t, with_response_warnings(`{"x":1}`, "", `{"code":"c"}`), `{"x":1,"warnings":[{"code":"c"}]}`)
	testing.expect_value(t, with_response_warnings(`{"x":1}`, ""), `{"x":1}`)
	fields := brief_verify_removed_fields(`{"brief":{"goal":"g","verify":"make","auto_submit":true}}`)
	testing.expect(t, len(fields) == 2 && fields[0] == "verify" && fields[1] == "auto_submit", "brief fields named in source order")
}
