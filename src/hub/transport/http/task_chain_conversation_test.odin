package http

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import taskchain_service "odin_test:hub/service/taskchain"

// REQ-TV2-7: GET /task-chains/{cid}/conversation names the chain's CURRENT
// coordinator, so a `chain:<cid>` pane survives a coordinator replacement, and
// lists the replaced instance so its legacy link can be offered the chain URL.
@(test)
test_task_chain_conversation_follows_coordinator_replacement :: proc(t: ^testing.T) {
	f := wire_setup(t, "chain_conversation")
	defer wire_teardown(f)
	path := fmt.aprintf("/api/v1/task-chains/%s/conversation", f.chain_id)
	defer delete(path)

	// The fixture seeds f.instance_id as the chain's coordinator.
	seeded := get_task_chain_conversation_handler(&f.th, wire_cookie_request(f, "GET", path, ""))
	testing.expect_value(t, seeded.status, 200)
	testing.expectf(t, strings.contains(seeded.body, fmt.tprintf(`"coordinator_agent_instance_id":"%s"`, f.instance_id)), "seeded coordinator: %s", seeded.body)

	chain, _, _ := iface.taskchain_get_chain(&f.tc_repo, f.chain_id)
	chain = taskchain_service.set_chain_coordinator(&f.tc_svc, chain, "inst_coord_a")
	first := get_task_chain_conversation_handler(&f.th, wire_cookie_request(f, "GET", path, ""))
	testing.expect_value(t, first.status, 200)
	testing.expectf(t, strings.contains(first.body, `"coordinator_agent_instance_id":"inst_coord_a"`), "first coordinator: %s", first.body)
	testing.expect(t, strings.contains(first.body, `"title":"TB-2 Wire Chain"`), "chain title for the breadcrumb")
	testing.expectf(t, strings.contains(first.body, fmt.tprintf(`"replaced_coordinator_instance_ids":["%s"]`, f.instance_id)), "seeded coordinator replaced: %s", first.body)

	// A plain worker member is never reported as a replaced coordinator.
	_, _, _ = iface.taskchain_save_member(&f.tc_repo, domain.Task_Chain_Member{chain_id = f.chain_id, owner_user_id = f.owner, agent_instance_id = "inst_worker", role = "worker"})
	_ = taskchain_service.set_chain_coordinator(&f.tc_svc, chain, "inst_coord_b")
	second := get_task_chain_conversation_handler(&f.th, wire_cookie_request(f, "GET", path, ""))
	testing.expect_value(t, second.status, 200)
	testing.expectf(t, strings.contains(second.body, `"coordinator_agent_instance_id":"inst_coord_b"`), "replacement coordinator: %s", second.body)
	testing.expectf(t, strings.contains(second.body, fmt.tprintf(`"replaced_coordinator_instance_ids":["%s","inst_coord_a"]`, f.instance_id)), "replaced list: %s", second.body)

	missing := get_task_chain_conversation_handler(&f.th, wire_cookie_request(f, "GET", "/api/v1/task-chains/chain_missing/conversation", ""))
	testing.expect_value(t, missing.status, 404)
}
