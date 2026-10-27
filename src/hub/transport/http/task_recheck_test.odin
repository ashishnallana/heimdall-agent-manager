package http

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import taskv2 "odin_test:hub/service/taskv2"

// POST …/tasks/{id}/recheck: owner or coordinator; both route shapes; the
// response carries changed, actions, reasons and message.
@(test)
test_recheck_http_routes_auth_and_result :: proc(t: ^testing.T) {
	f := wire_setup(t, "task_recheck")
	defer wire_teardown(f)
	engine := taskv2.new_service(&f.tc_repo, &f.ag_repo, &f.br_repo, &f.clock, &f.ids)
	f.th.task_engine = &engine
	chain, _, _ := iface.taskchain_get_chain(&f.tc_repo, f.chain_id)
	chain.publish_state = .Published
	_, _, _ = iface.taskchain_save_chain(&f.tc_repo, chain)
	task := domain.Task{task_id = "task_recheck_http", chain_id = f.chain_id, owner_user_id = f.owner, title = "Re-check", publish_state = .Published, kind = .Task, state = .Ready, brief_json = `{"goal":"g","review_roles":[]}`}
	_, _, _ = iface.taskchain_save_task(&f.tc_repo, task)
	_, _, _ = taskv2.append_event(&f.tc_repo, &f.clock, task, taskv2.hub_actor(), taskv2.EV_PUBLISHED, `{}`)

	path := fmt.aprintf("/api/v1/task-chains/%s/tasks/%s/recheck", f.chain_id, task.task_id)
	defer delete(path)
	// A member worker may not re-check.
	_, _, _ = iface.taskchain_save_member(&f.tc_repo, domain.Task_Chain_Member{chain_id = f.chain_id, owner_user_id = f.owner, agent_instance_id = f.instance_id, role = "worker"})
	req := wire_cookie_request(f, "POST", path, `{}`)
	req.headers = f.agent_headers[:]
	denied := recheck_task_handler(&f.th, req)
	testing.expect_value(t, denied.status, 403)

	// The owner gets the result: ready, no worker row → a reason, no change.
	resp := recheck_task_handler(&f.th, wire_cookie_request(f, "POST", path, `{}`))
	testing.expect_value(t, resp.status, 200)
	testing.expect(t, strings.contains(resp.body, `"changed":false`), resp.body)
	testing.expect(t, strings.contains(resp.body, `"actions":[]`), resp.body)
	testing.expect(t, strings.contains(resp.body, `no fleet row holds the worker role`), resp.body)
	testing.expect(t, strings.contains(resp.body, `"message":"nothing to change: `), resp.body)
	testing.expect(t, strings.contains(resp.body, `"task":{`), resp.body)

	// The chain-less alias resolves the task's chain itself.
	alias := fmt.aprintf("/api/v1/tasks/%s/recheck", task.task_id)
	defer delete(alias)
	aresp := recheck_task_handler(&f.th, wire_cookie_request(f, "POST", alias, `{}`))
	testing.expect_value(t, aresp.status, 200)
	testing.expect(t, strings.contains(aresp.body, `"changed":false`), aresp.body)

	// A task in another chain is not reachable through this chain's path.
	wrong := fmt.aprintf("/api/v1/task-chains/%s/tasks/%s/recheck", "chain_other", task.task_id)
	defer delete(wrong)
	missing := recheck_task_handler(&f.th, wire_cookie_request(f, "POST", wrong, `{}`))
	testing.expect_value(t, missing.status, 404)
}
