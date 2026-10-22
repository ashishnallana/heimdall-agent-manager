package card

import "core:strings"
import "core:testing"
import "core:time"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import agent_service "odin_test:hub/service/agent"

// REQ-EXT-BLK-2 (user scope decision cmt_18e0c88f299c19b4): live agent blockers
// show up ONLY in the 'Needs you' attention surfaces, as attention item kind
// agent_blocker merged in at read time — counted in the summary, filterable by
// kind, carrying chain_id for chain scoping, and gone once the bridge's snapshot
// drops them. Nothing is written to the cards/attention tables.

@(private = "file")
ab_instances := [?]domain.Agent_Instance{
	{agent_instance_id = "inst_chain", owner_user_id = PH_OWNER, bridge_id = "brg_1", chain_id = string(PH_CHAIN), runtime_status = "running"},
	{agent_instance_id = "inst_solo", owner_user_id = PH_OWNER, bridge_id = "brg_1", runtime_status = "running"},
	{agent_instance_id = "inst_foreign", owner_user_id = "usr_other", bridge_id = "brg_9", runtime_status = "running"},
}

@(private = "file")
ab_get_instance :: proc(ctx: rawptr, instance_id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	for inst in ab_instances do if inst.agent_instance_id == instance_id do return inst, true, {}
	return {}, false, domain.domain_error(.Not_Found, "agent instance not found")
}

@(test)
test_attention_merges_live_agent_blockers :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_api_blockers")
	defer ph_close(&h)
	ph_save_task(t, &h, ph_task("task_2h", .In_Validation, ph_ago(2 * time.Hour)))

	agent_repo := iface.Agent_Repository{get_instance = ab_get_instance}
	agents := agent_service.new_agent_service(&agent_repo, nil, &h.clock, &h.ids)
	h.svc.agents = &agents

	testing.expect(t, agent_service.apply_bridge_blockers_snapshot(&agents, "brg_1", `{"agent_instance_id":"inst_chain","revision":5,"blockers":[{"blocker_id":"blk_chain","kind":"permission","agent_id":"sub-1","tool_name":"Bash","summary":"Bash: ls","input":{"command":"ls"},"created_at":"2026-10-22T09:59:00Z","expires_at":"2026-10-22T10:04:00Z"}]}`))
	testing.expect(t, agent_service.apply_bridge_blockers_snapshot(&agents, "brg_1", `{"agent_instance_id":"inst_solo","revision":7,"blockers":[{"blocker_id":"term_inst_solo","kind":"terminal_prompt","summary":"Waiting for input in terminal","created_at":"2026-10-22T09:58:00Z"}]}`))
	testing.expect(t, agent_service.apply_bridge_blockers_snapshot(&agents, "brg_9", `{"agent_instance_id":"inst_foreign","revision":1,"blockers":[{"blocker_id":"blk_foreign","kind":"permission","tool_name":"Bash"}]}`))

	r, err := list_attention(&h.svc, ph_auth(), "", "", true)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, r.counts.agent_blocker, 2) // the other owner's blocker never counts
	testing.expect_value(t, r.counts.task, 1)
	testing.expect_value(t, len(r.items), 3)
	// Blockers are urgency error: they come first, oldest first (terminal prompt 09:58).
	if len(r.items) == 3 {
		term, perm := r.items[0], r.items[1]
		testing.expect_value(t, string(term.card.card_id), "blk:term_inst_solo")
		testing.expect_value(t, term.card.kind, ATTENTION_KIND_AGENT_BLOCKER)
		testing.expect_value(t, term.reason, ATTENTION_REASON_TERMINAL_PROMPT)
		testing.expect_value(t, term.card.action_refs_json, `{"agent_instance_id":"inst_solo","chain_id":"","blocker_id":"term_inst_solo"}`)
		testing.expect_value(t, term.ctx.chain_title, "")

		testing.expect_value(t, string(perm.card.card_id), "blk:blk_chain")
		testing.expect_value(t, perm.reason, ATTENTION_REASON_PERMISSION)
		testing.expect_value(t, perm.urgency, ATTENTION_URGENCY_ERROR)
		testing.expect_value(t, perm.primary_op, "")
		testing.expect_value(t, perm.card.operations_json, "[]")
		testing.expect_value(t, perm.card.action_refs_json, `{"agent_instance_id":"inst_chain","chain_id":"chain_att","blocker_id":"blk_chain"}`)
		testing.expect_value(t, perm.card.details_json, `{"blocker_kind":"permission","tool_name":"Bash","summary":"Bash: ls","input":{"command":"ls"},"agent_id":"sub-1","agent_instance_id":"inst_chain","created_at":"2026-10-22T09:59:00Z","expires_at":"2026-10-22T10:04:00Z"}`)
		// Chain scoping context resolved like any other item.
		testing.expect_value(t, perm.ctx.chain_title, "vault:v2:chain-title")
		testing.expect_value(t, string(r.items[2].card.card_id), "crd_task_task_2h")
	}

	// kind=agent_blocker narrows to blockers; other kinds exclude them; summary counts them.
	rk, kerr := list_attention(&h.svc, ph_auth(), "all", ATTENTION_KIND_AGENT_BLOCKER, true)
	testing.expect_value(t, kerr.code, domain.Error_Code.None)
	testing.expect_value(t, len(rk.items), 2)
	rt, _ := list_attention(&h.svc, ph_auth(), "all", "task", true)
	for item in rt.items do testing.expect(t, item.card.kind != ATTENTION_KIND_AGENT_BLOCKER, string(item.card.card_id))
	rs, _ := list_attention(&h.svc, ph_auth(), "6h", "", false)
	testing.expect_value(t, rs.counts.agent_blocker, 2)
	ro, _ := list_attention(&h.svc, ph_auth("usr_other"), "all", ATTENTION_KIND_AGENT_BLOCKER, true)
	testing.expect_value(t, len(ro.items), 1)

	// Resolved (the bridge's next snapshot drops it) or stopped: gone from attention.
	testing.expect(t, agent_service.apply_bridge_blockers_snapshot(&agents, "brg_1", `{"agent_instance_id":"inst_chain","revision":6,"blockers":[]}`))
	agent_service.clear_instance_blockers(&agents, "inst_solo")
	ra, _ := list_attention(&h.svc, ph_auth(), "all", "", true)
	testing.expect_value(t, ra.counts.agent_blocker, 0)
	for item in ra.items do testing.expect(t, !strings.has_prefix(string(item.card.card_id), "blk:"), string(item.card.card_id))

	// Never stored: the attention tables hold no blocker card.
	live, _ := iface.attention_list_cards(&h.attention, PH_OWNER, ATTENTION_KIND_AGENT_BLOCKER, "", platform.clock_now(&h.clock), 50)
	testing.expect_value(t, len(live), 0)
}
