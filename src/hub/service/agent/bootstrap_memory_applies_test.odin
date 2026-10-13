package agent

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"

// These tests cover the list-based memory targeting semantics: an empty list for
// a dimension means "applies to all"; a non-empty list means the instance value
// must be a member; dimensions are ANDed together. The template dimension is
// exercised separately (it needs an agent repository) — here we keep template_ids
// empty so a nil service is valid.

@(test)
test_bootstrap_memory_applies_empty_lists_apply_to_all :: proc(t: ^testing.T) {
	inst := domain.Agent_Instance{agent_id = "agt_1", project_id = domain.Project_ID("proj_1"), bridge_id = "brg_1"}
	m := domain.Memory{status = "active"} // all lists empty
	testing.expect_value(t, bootstrap_memory_applies(m, nil, "user_1", inst), true)
}

@(test)
test_bootstrap_memory_applies_inactive_never_matches :: proc(t: ^testing.T) {
	inst := domain.Agent_Instance{agent_id = "agt_1"}
	m := domain.Memory{status = "pending"}
	testing.expect_value(t, bootstrap_memory_applies(m, nil, "user_1", inst), false)
}

@(test)
test_bootstrap_memory_applies_agent_membership :: proc(t: ^testing.T) {
	inst := domain.Agent_Instance{agent_id = "agt_1", project_id = domain.Project_ID("proj_1"), bridge_id = "brg_1"}

	member := domain.Memory{status = "active", agent_ids = []string{"agt_0", "agt_1"}}
	testing.expect_value(t, bootstrap_memory_applies(member, nil, "user_1", inst), true)

	non_member := domain.Memory{status = "active", agent_ids = []string{"agt_2"}}
	testing.expect_value(t, bootstrap_memory_applies(non_member, nil, "user_1", inst), false)
}

@(test)
test_bootstrap_memory_applies_project_membership :: proc(t: ^testing.T) {
	inst := domain.Agent_Instance{agent_id = "agt_1", project_id = domain.Project_ID("proj_1")}

	member := domain.Memory{status = "active", project_ids = []domain.Project_ID{domain.Project_ID("proj_1")}}
	testing.expect_value(t, bootstrap_memory_applies(member, nil, "user_1", inst), true)

	non_member := domain.Memory{status = "active", project_ids = []domain.Project_ID{domain.Project_ID("proj_9")}}
	testing.expect_value(t, bootstrap_memory_applies(non_member, nil, "user_1", inst), false)
}

@(test)
test_bootstrap_memory_applies_bridge_membership :: proc(t: ^testing.T) {
	inst := domain.Agent_Instance{agent_id = "agt_1", bridge_id = "brg_1"}

	member := domain.Memory{status = "active", bridge_ids = []string{"brg_1"}}
	testing.expect_value(t, bootstrap_memory_applies(member, nil, "user_1", inst), true)

	non_member := domain.Memory{status = "active", bridge_ids = []string{"brg_2"}}
	testing.expect_value(t, bootstrap_memory_applies(non_member, nil, "user_1", inst), false)
}

@(test)
test_bootstrap_memory_applies_dimensions_are_anded :: proc(t: ^testing.T) {
	inst := domain.Agent_Instance{agent_id = "agt_1", project_id = domain.Project_ID("proj_1"), bridge_id = "brg_1"}

	// agent matches but project does not -> excluded.
	m := domain.Memory{status = "active", agent_ids = []string{"agt_1"}, project_ids = []domain.Project_ID{domain.Project_ID("proj_9")}}
	testing.expect_value(t, bootstrap_memory_applies(m, nil, "user_1", inst), false)

	// both agent and project match -> included.
	m2 := domain.Memory{status = "active", agent_ids = []string{"agt_1"}, project_ids = []domain.Project_ID{domain.Project_ID("proj_1")}}
	testing.expect_value(t, bootstrap_memory_applies(m2, nil, "user_1", inst), true)
}

// SKILL-SCOPE-1: the agent-keyed predicate is now bridge-aware. A bridge-scoped
// memory (empty agent_ids, non-empty bridge_ids) must materialize for ALL agents
// whose manifest is rendered for a matching bridge, and be excluded for other
// bridges — the same "empty list = all, non-empty = must match" rule every other
// dimension uses. The requesting bridge_id is threaded in from the authenticated
// bridge at render time.
@(test)
test_bootstrap_memory_applies_agent_bridge_scope :: proc(t: ^testing.T) {
	agent := domain.Agent{agent_id = "agt_1", owner_user_id = "user_1", template_id = "tmpl_1"}
	agent_other := domain.Agent{agent_id = "agt_2", owner_user_id = "user_1", template_id = "tmpl_1"}

	// agent_ids=[] + bridge_ids=[brg_1]: applies to any agent rendered for brg_1,
	// not for brg_2. (This is the exact bug SKILL-SCOPE-1 fixes.)
	bridge_scoped := domain.Memory{status = "active", bridge_ids = []string{"brg_1"}}
	testing.expect_value(t, bootstrap_memory_applies_agent(bridge_scoped, agent, "user_1", domain.Project_ID("proj_1"), "brg_1"), true)
	testing.expect_value(t, bootstrap_memory_applies_agent(bridge_scoped, agent_other, "user_1", domain.Project_ID("proj_1"), "brg_1"), true)
	testing.expect_value(t, bootstrap_memory_applies_agent(bridge_scoped, agent, "user_1", domain.Project_ID("proj_1"), "brg_2"), false)
	// An unattributable request (empty bridge_id) safely excludes bridge-scoped memories.
	testing.expect_value(t, bootstrap_memory_applies_agent(bridge_scoped, agent, "user_1", domain.Project_ID("proj_1"), ""), false)

	// agent_ids=[agt_1] + bridge_ids=[brg_1]: only (agt_1, brg_1).
	agent_and_bridge := domain.Memory{status = "active", agent_ids = []string{"agt_1"}, bridge_ids = []string{"brg_1"}}
	testing.expect_value(t, bootstrap_memory_applies_agent(agent_and_bridge, agent, "user_1", domain.Project_ID("proj_1"), "brg_1"), true)
	testing.expect_value(t, bootstrap_memory_applies_agent(agent_and_bridge, agent, "user_1", domain.Project_ID("proj_1"), "brg_2"), false) // right agent, wrong bridge
	testing.expect_value(t, bootstrap_memory_applies_agent(agent_and_bridge, agent_other, "user_1", domain.Project_ID("proj_1"), "brg_1"), false) // wrong agent, right bridge

	// agent_ids=[] + bridge_ids=[]: applies to every agent on every bridge.
	global := domain.Memory{status = "active"}
	testing.expect_value(t, bootstrap_memory_applies_agent(global, agent, "user_1", domain.Project_ID("proj_1"), "brg_1"), true)
	testing.expect_value(t, bootstrap_memory_applies_agent(global, agent_other, "user_1", domain.Project_ID("proj_9"), ""), true)

	// project ANDs with the new bridge rule: bridge matches, project doesn't -> excluded.
	proj_and_bridge := domain.Memory{status = "active", bridge_ids = []string{"brg_1"}, project_ids = []domain.Project_ID{domain.Project_ID("proj_1")}}
	testing.expect_value(t, bootstrap_memory_applies_agent(proj_and_bridge, agent, "user_1", domain.Project_ID("proj_1"), "brg_1"), true)
	testing.expect_value(t, bootstrap_memory_applies_agent(proj_and_bridge, agent, "user_1", domain.Project_ID("proj_9"), "brg_1"), false)

	// template ANDs with the new bridge rule.
	tmpl_and_bridge := domain.Memory{status = "active", template_ids = []string{"tmpl_1"}, bridge_ids = []string{"brg_1"}}
	testing.expect_value(t, bootstrap_memory_applies_agent(tmpl_and_bridge, agent, "user_1", domain.Project_ID("proj_1"), "brg_1"), true)
	testing.expect_value(t, bootstrap_memory_applies_agent(tmpl_and_bridge, agent, "user_1", domain.Project_ID("proj_1"), "brg_2"), false) // template ok, bridge wrong
	tmpl_miss := domain.Memory{status = "active", template_ids = []string{"tmpl_9"}}
	testing.expect_value(t, bootstrap_memory_applies_agent(tmpl_miss, agent, "user_1", domain.Project_ID("proj_1"), "brg_1"), false)
}

// The agent-keyed manifest cache key must include the requesting bridge_id so a
// bridge-scoped skill rendered for one bridge is never served to another bridge.
@(test)
test_bootstrap_manifest_cache_key_includes_bridge :: proc(t: ^testing.T) {
	k1 := bootstrap_manifest_cache_key("agt_1", "worker", "pi", "proj_1", "brg_1")
	defer delete(k1)
	k2 := bootstrap_manifest_cache_key("agt_1", "worker", "pi", "proj_1", "brg_2")
	defer delete(k2)
	testing.expect(t, k1 != k2, "cache keys for different bridges must differ")

	k3 := bootstrap_manifest_cache_key("agt_1", "worker", "pi", "proj_1", "brg_1")
	defer delete(k3)
	testing.expect_value(t, k1, k3) // same inputs -> same key
}

@(test)
test_bootstrap_build_memory_markdown_option_a_empty :: proc(t: ^testing.T) {
	agent := domain.Agent{agent_id = "agt_1", owner_user_id = "user_1"}
	out := bootstrap_build_memory_markdown_agent(nil, "user_1", agent, domain.Project_ID("proj_1"), "brg_1")
	defer delete(out)
	testing.expect_value(t, out, "# Applicable Memories\n\nNo specific memories recorded for this agent.\n")

	inst := domain.Agent_Instance{agent_id = "agt_1", owner_user_id = "user_1"}
	inst_out := bootstrap_build_memory_markdown_instance(nil, "user_1", inst)
	defer delete(inst_out)
	testing.expect_value(t, inst_out, "# Applicable Memories\n\nNo specific memories recorded for this agent.\n")
}

@(test)
test_bootstrap_render_agent_manifest_includes_memory_md :: proc(t: ^testing.T) {
	agent := domain.Agent{agent_id = "agt_1", name = "Worker", owner_user_id = "user_1"}
	manifest, version := render_agent_manifest(nil, "user_1", agent, false, "claude", "proj_1", "brg_1")
	defer delete(manifest)
	defer delete(version)

	testing.expect(t, strings.contains(manifest, `{"kind":"MEMORY_MD","relative_path":"MEMORY.md","hash":"`))
	testing.expect(t, version != "")
}
