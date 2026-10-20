package http

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import taskv2 "odin_test:hub/service/taskv2"

@(test)
test_submit_skip_wire_validates_and_persists_reason :: proc(t: ^testing.T) {
	f := wire_setup(t, "verify_skip")
	defer wire_teardown(f)
	engine := taskv2.new_service(&f.tc_repo, &f.ag_repo, &f.br_repo, &f.clock, &f.ids)
	f.ah.task_engine = &engine
	task := domain.Task{task_id = "wire_skip", chain_id = f.chain_id, owner_user_id = f.owner, title = "work", publish_state = .Published, state = .In_Progress, attempt_no = 1, brief_json = `{"verify":"make test"}`, created_at = "2026-10-01T00:00:00Z", updated_at = "2026-10-01T00:00:00Z"}
	_, _, _ = iface.taskchain_save_task(&f.tc_repo, task)
	_, _, _ = iface.taskchain_save_lease(&f.tc_repo, domain.Task_Lease{lease_id = "wire_skip_lease", task_id = task.task_id, chain_id = f.chain_id, owner_user_id = f.owner, attempt_no = 1, holder_instance_id = f.instance_id, kind = domain.LEASE_KIND_WORK, confirmed_at = "2026-10-01T00:00:00Z", expires_at = "2099-01-01T00:00:00Z"})
	blank := agent_action_lease_submit_handler(&f.ah, wire_agent_request(f, "lease/submit", `{"params":{"summary":"done","skip_verify":true,"skip_verify_reason":"  "}}`))
	testing.expect_value(t, blank.status, 400)
	testing.expect(t, strings.contains(blank.body, "verify_skip_reason_required"), "wire rejects an empty skip reason")
	valid := agent_action_lease_submit_handler(&f.ah, wire_agent_request(f, "lease/submit", `{"params":{"summary":"done","skip_verify":true,"skip_verify_reason":"runner unavailable"}}`))
	testing.expectf(t, valid.status == 200, "skip fields reach the engine: %s", valid.body)
	handoff, ok := taskv2.get_facet(&engine, task, 1, taskv2.FACET_HANDOFF)
	testing.expect(t, ok && strings.contains(handoff.body_json, `"skip_verify_reason":"runner unavailable"`), "skip reason persisted through the real handler")
}
