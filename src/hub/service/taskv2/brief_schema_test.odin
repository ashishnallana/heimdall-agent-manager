package taskv2

import "core:fmt"
import "core:strings"
import "core:testing"
import iface "odin_test:hub/repository/iface"

// REQ-TV2-4: chain.propose (pending and auto-approved) and proposal approval
// apply the same brief schema and reviewer identity contract as task create/update.
@(test)
test_chain_propose_and_decide_enforce_brief_contract :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "brief_schema_propose")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_bs")
	chain.publish_state = .Draft
	chain.published_at = ""
	chain.coordinator_agent_instance_id = "inst_coord"
	_, _, _ = iface.taskchain_save_chain(&fx.repo, chain)
	seed_instance(fx, chain, "inst_coord", "coordinator", "br_1", "idle", role = "coordinator")
	seed_agent(fx, "agt_rev")
	coord := Actor{kind = ACTOR_AGENT, id = "inst_coord"}

	bad_specs := [?]struct{name, tasks, code, needle: string}{
		{"unknown key", `[{"id":"bs_1","title":"T","brief":{"goal":"g","acceptance":["a"],"bogus":1}}]`, "unknown_brief_fields", `"unknown_brief_fields":["bogus"]`},
		{"instance reviewer", `[{"id":"bs_1","title":"T","brief":{"goal":"g","acceptance":["a"],"reviewers":["inst_bad"]}}]`, "reviewer_must_be_agent_id", "inst_bad"},
		{"unknown reviewer", `[{"id":"bs_1","title":"T","brief":{"goal":"g","acceptance":["a"],"reviewers":["agt_nobody"]}}]`, "reviewer_must_be_agent_id", "agt_nobody"},
	}
	for spec in bad_specs {
		for auto in ([]bool{false, true}) {
			_, pok, perr := chain_propose(&fx.svc, chain.chain_id, "u1", coord, Propose_Input{kind = "task", tasks_json = spec.tasks, auto_approve = auto})
			testing.expectf(t, !pok && perr.code == .Validation_Failed && strings.contains(perr.details_json, fmt.tprintf(`"code":"%s"`, spec.code)) && strings.contains(perr.details_json, spec.needle), "%s (auto_approve=%v): %s", spec.name, auto, perr.details_json)
			stored, _, _ := iface.taskchain_get_chain(&fx.repo, chain.chain_id)
			testing.expectf(t, chain_proposal_json(stored) == "", "%s: no proposal stored", spec.name)
			_, has_task, _ := iface.taskchain_get_task(&fx.repo, "bs_1")
			testing.expectf(t, !has_task, "%s: nothing materialized", spec.name)
		}
	}

	// A proposal already pending with a bad brief (stored before this check)
	// is refused on approval, not materialized.
	stored, _, _ := iface.taskchain_get_chain(&fx.repo, chain.chain_id)
	stored.defaults_json = set_chain_proposal_json(stored.defaults_json, `{"status":"pending","kind":"task","tasks":[{"id":"bs_1","title":"T","brief":{"goal":"g","acceptance":["a"],"reviewers":["inst_bad"]}}]}`)
	_, _, _ = iface.taskchain_save_chain(&fx.repo, stored)
	_, _, dok, derr := chain_proposal_decide(&fx.svc, chain.chain_id, "u1", Actor{kind = ACTOR_USER, id = "u1"}, "approve")
	testing.expectf(t, !dok && strings.contains(derr.details_json, "reviewer_must_be_agent_id"), "pending bad proposal refused on approve: %s", derr.details_json)
	_, has_task, _ := iface.taskchain_get_task(&fx.repo, "bs_1")
	testing.expect(t, !has_task, "refused approval materializes nothing")
	_, _, _, _ = chain_proposal_decide(&fx.svc, chain.chain_id, "u1", Actor{kind = ACTOR_USER, id = "u1"}, "reject")

	// Valid: a durable reviewer agent, and the shorthand spec (no brief object).
	seed_fleet(fx, chain, "agt_w")
	seed_fleet(fx, chain, "agt_rev", `["reviewer"]`)
	_, gok, gerr := chain_propose(&fx.svc, chain.chain_id, "u1", coord, Propose_Input{kind = "task", auto_approve = true,
		tasks_json = `[{"id":"bs_ok","title":"T","brief":{"goal":"g","acceptance":["a"],"reviewers":["agt_rev"]}},{"id":"bs_short","title":"Short","acceptance":["a"]}]`})
	testing.expectf(t, gok, "valid proposal: %s %s", gerr.message, gerr.details_json)
	ok_task, has_ok, _ := iface.taskchain_get_task(&fx.repo, "bs_ok")
	testing.expect(t, has_ok && strings.contains(ok_task.brief_json, "agt_rev"), "valid proposal materialized with its reviewer")
}
