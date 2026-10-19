package card

import "core:fmt"
import "core:testing"
import "core:time"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import content_service "odin_test:hub/service/content"

// Memory proposals in the attention deck (REQ-MEM-1..3): a pending, unexpired
// proposal is a live `memory` card, named for the deck (proposer, chain, scope).

pm_seed_memory_fixtures :: proc(t: ^testing.T, h: ^Projector_Harness) {
	ok := sqlite.exec(&h.conn, fmt.tprintf(`
INSERT INTO agents (agent_id, owner_user_id, name, slug, template_id, state, created_at, updated_at)
  VALUES ('agt_rev', '%s', 'codex-reviewer', 'codex-reviewer', 'tmpl_reviewer', 'active', '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z');
INSERT INTO agent_instances (agent_instance_id, owner_user_id, agent_id, bridge_id, display_name, runtime_status, kind, chain_id, created_at, updated_at)
  VALUES ('inst_prop', '%s', 'agt_rev', 'brg_x', 'soloist #21', 'running', 'agent', '%s', '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z');`,
		string(PH_OWNER), string(PH_OWNER), string(PH_CHAIN)))
	testing.expect(t, ok, "seed agent + instance")
}

pm_propose :: proc(t: ^testing.T, h: ^Projector_Harness, title: string, expires_at := "", templates: []string = nil) -> domain.Memory {
	m, ok, err := content_service.create_memory(&h.content_svc, ph_auth(), content_service.Memory_Input{
		type = .Fact, title = title, body = "**Use** the CAS helper.\n\n- one\n- two", status = "pending",
		agent_ids = []string{"agt_rev"}, template_ids = templates, expires_at = expires_at,
		proposed_by_instance_id = "inst_prop", proposed_in_chain_id = string(PH_CHAIN),
	})
	testing.expectf(t, ok, "propose memory: %s", err.message)
	return m
}

@(test)
test_memory_proposal_card_lifecycle :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_memory_lifecycle")
	defer ph_close(&h)
	pm_seed_memory_fixtures(t, &h)

	m := pm_propose(t, &h, "vault:v2:mem-title", templates = []string{"tmpl_reviewer"})
	testing.expect_value(t, m.proposed_by_instance_id, "inst_prop")
	testing.expect_value(t, m.proposed_in_chain_id, string(PH_CHAIN))

	// Proposing writes through: a live memory card, the deck's shape.
	cid := attention_memory_card_id(m.memory_id)
	c, found := ph_card(t, &h, cid)
	testing.expect(t, found, "proposal projected to a card")
	testing.expect_value(t, c.status, domain.CARD_STATUS_PENDING)
	testing.expect_value(t, c.kind, domain.CARD_KIND_MEMORY)
	testing.expect_value(t, c.attention_since, m.created_at)
	testing.expect_value(t, attention_first_op(c.operations_json), "memory.approve")

	r, err := list_attention(&h.svc, ph_auth(), "24h", "", true)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, r.counts.memory, 1)
	testing.expect_value(t, len(r.items), 1)
	if len(r.items) == 1 {
		it := r.items[0]
		testing.expect_value(t, it.reason, ATTENTION_REASON_MEMORY_PROPOSAL)
		testing.expect_value(t, it.primary_op, "memory.approve")
		testing.expect_value(t, it.ctx.agent_name, "soloist #21")
		testing.expect_value(t, it.ctx.chain_title, "vault:v2:chain-title")
		testing.expect(t, it.ctx.has_scope, "memory items carry a named scope")
		testing.expect_value(t, len(it.ctx.scope_agents), 1)
		if len(it.ctx.scope_agents) == 1 do testing.expect_value(t, it.ctx.scope_agents[0], "codex-reviewer")
		testing.expect_value(t, len(it.ctx.scope_projects), 0) // [] = all projects
		testing.expect_value(t, len(it.ctx.scope_templates), 1)
		if len(it.ctx.scope_templates) == 1 do testing.expect_value(t, it.ctx.scope_templates[0], "reviewer") // built-in, named in code
		testing.expect_value(t, attention_json_field(it.card.details_json, "body"), "**Use** the CAS helper.\n\n- one\n- two")
		testing.expect_value(t, attention_json_field(it.card.details_json, "type"), "fact")
	}
	rk, _ := list_attention(&h.svc, ph_auth(), "24h", domain.CARD_KIND_MEMORY, true)
	testing.expect_value(t, len(rk.items), 1)

	// Approving the memory retires its card.
	_, approved, _ := content_service.approve_memory(&h.content_svc, ph_auth(), m.memory_id)
	testing.expect(t, approved, "approve")
	after, _ := ph_card(t, &h, cid)
	testing.expect_value(t, after.status, domain.CARD_STATUS_RESOLVED)
	r2, _ := list_attention(&h.svc, ph_auth(), "24h", "", true)
	testing.expect_value(t, r2.counts.memory, 0)

	// Rejecting another one through the card (the deck's Reject) works too.
	m2 := pm_propose(t, &h, "second")
	_, rejected, rej_err := reject_card(&h.svc, ph_auth(), attention_memory_card_id(m2.memory_id))
	testing.expectf(t, rejected, "reject card: %s", rej_err.message)
	got, _, _ := content_service.get_memory(&h.content_svc, ph_auth(), m2.memory_id)
	testing.expect_value(t, got.status, "rejected")
}

@(test)
test_memory_proposal_expiry_and_reconcile :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_memory_expiry")
	defer ph_close(&h)
	pm_seed_memory_fixtures(t, &h)
	now := time.now()

	// Already expired: never a card.
	gone := pm_propose(t, &h, "expired", expires_at = platform.format_rfc3339_utc(time.time_add(now, -time.Minute)))
	_, found := ph_card(t, &h, attention_memory_card_id(gone.memory_id))
	testing.expect(t, !found, "an expired proposal is not projected")

	// Expiring within 6h: warn urgency.
	soon := pm_propose(t, &h, "soon", expires_at = platform.format_rfc3339_utc(time.time_add(now, 2 * time.Hour)))
	r, _ := list_attention(&h.svc, ph_auth(), "24h", domain.CARD_KIND_MEMORY, true)
	testing.expect_value(t, len(r.items), 1)
	if len(r.items) == 1 do testing.expect_value(t, r.items[0].urgency, ATTENTION_URGENCY_WARN)

	// The expiry itself writes nothing; reconciliation retires the card.
	ok := sqlite.exec(&h.conn, fmt.tprintf("UPDATE memories SET expires_at = '2000-01-01T00:00:00Z' WHERE memory_id = '%s';", soon.memory_id))
	testing.expect(t, ok, "expire in place")
	// A proposal written behind the projector's back is picked up too.
	ok = sqlite.exec(&h.conn, fmt.tprintf(`INSERT INTO memories (memory_id, owner_user_id, agent_ids, project_ids, template_ids, bridge_ids, type, status, title, description, body, evidence, expires_at, created_at, updated_at)
  VALUES ('mem_raw', '%s', '[]', '[]', '[]', '[]', 'habit', 'pending', 'raw', '', 'raw body', '', '', '%s', '%s');`, string(PH_OWNER), platform.format_rfc3339_utc(now), platform.format_rfc3339_utc(now)))
	testing.expect(t, ok, "raw proposal")
	stats := reconcile_attention(&h.svc)
	testing.expect_value(t, stats.failed, 0)
	expired_card, _ := ph_card(t, &h, attention_memory_card_id(soon.memory_id))
	testing.expect_value(t, expired_card.status, domain.CARD_STATUS_RESOLVED)
	raw_card, raw_found := ph_card(t, &h, attention_memory_card_id("mem_raw"))
	testing.expect(t, raw_found, "reconcile projects an unseen proposal")
	testing.expect_value(t, raw_card.status, domain.CARD_STATUS_PENDING)

	// A proposal with no proposer (user-made or pre-migration) still lists, with
	// no agent name and an all-scope.
	ra, _ := list_attention(&h.svc, ph_auth(), "24h", domain.CARD_KIND_MEMORY, true)
	testing.expect_value(t, len(ra.items), 1)
	if len(ra.items) == 1 {
		testing.expect_value(t, ra.items[0].ctx.agent_name, "")
		testing.expect_value(t, len(ra.items[0].ctx.scope_agents), 0)
	}
}
