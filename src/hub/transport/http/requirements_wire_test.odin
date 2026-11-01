package http

import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import taskv2 "odin_test:hub/service/taskv2"
import jsonx "odin_test:lib/jsonx"

@(test)
test_requirements_ack_and_submission_revision_wire :: proc(t: ^testing.T) {
    f := wire_setup(t, "requirements_wire")
    defer wire_teardown(f)
    engine := taskv2.new_service(&f.tc_repo, &f.ag_repo, &f.br_repo, &f.clock, &f.ids)
    f.ah.task_engine = &engine
    task := domain.Task{task_id = "wire_requirements", chain_id = f.chain_id, owner_user_id = f.owner,
        title = "work", publish_state = .Published, state = .In_Progress, attempt_no = 1,
        brief_json = `{"goal":"g","acceptance":["a"],"review_roles":[]}`,
        created_at = "2026-10-01T00:00:00Z", updated_at = "2026-10-01T00:00:00Z"}
    _, _, _ = iface.taskchain_save_task(&f.tc_repo, task)
    _, _, _ = iface.taskchain_append_event(&f.tc_repo, {task_id = task.task_id, chain_id = f.chain_id,
        owner_user_id = f.owner, kind = taskv2.EV_MIGRATED,
        payload_json = `{"state":"in_progress","published":true,"attempt_no":1}`})
    err := taskv2.requirements_record(&f.tc_repo, &f.clock, task,
        `{"goal":"g2","acceptance":["a"],"review_roles":[]}`, {kind = "user", id = string(f.owner)}, 1, "change", "")
    if !testing.expect(t, err.code == .None) do return
    task.brief_json = `{"goal":"g2","acceptance":["a"],"review_roles":[]}`
    _, _, _ = iface.taskchain_save_task(&f.tc_repo, task)
    _, _, _ = iface.taskchain_save_lease(&f.tc_repo, {
        lease_id = "wire_req_lease", task_id = task.task_id, chain_id = f.chain_id,
        owner_user_id = f.owner, attempt_no = 1, holder_instance_id = f.instance_id,
        kind = domain.LEASE_KIND_WORK, confirmed_at = "2026-10-01T00:00:00Z",
        expires_at = "2099-01-01T00:00:00Z"})
    premature := agent_action_lease_heartbeat_handler(&f.ah, wire_agent_request(f, "lease/heartbeat",
        `{"params":{"lease_id":"wire_req_lease","acknowledge_requirements_revision":2}}`))
    testing.expect_value(t, premature.status, 409)
    fetched := agent_action_lease_next_handler(&f.ah, wire_agent_request(f, "lease/next", `{"params":{}}`))
    if !testing.expectf(t, fetched.status == 200, "fetch: %s", fetched.body) do return
    ack := agent_action_lease_heartbeat_handler(&f.ah, wire_agent_request(f, "lease/heartbeat",
        `{"params":{"lease_id":"wire_req_lease","acknowledge_requirements_revision":2}}`))
    testing.expectf(t, ack.status == 200, "ack: %s", ack.body)
    stale := agent_action_lease_submit_handler(&f.ah, wire_agent_request(f, "lease/submit",
        `{"params":{"lease_id":"wire_req_lease","requirements_revision":1,"summary":"old work"}}`))
    testing.expect_value(t, stale.status, 409)
    current := agent_action_lease_submit_handler(&f.ah, wire_agent_request(f, "lease/submit",
        `{"params":{"lease_id":"wire_req_lease","requirements_revision":2,"summary":"current work","vcs":{"head":"wire-head"}}}`))
    testing.expectf(t, current.status == 200, "current: %s", current.body)
    events, _ := iface.taskchain_list_events_by_task(&f.tc_repo, task.task_id, f.owner)
    for event in events {
        if event.kind != taskv2.EV_SUBMITTED do continue
        testing.expect_value(t, jsonx.extract_int(event.payload_json, "requirements_revision", 0, true), 2)
        testing.expect_value(t, jsonx.extract_string(event.payload_json, "head", "", true, context.temp_allocator), "wire-head")
    }
}
