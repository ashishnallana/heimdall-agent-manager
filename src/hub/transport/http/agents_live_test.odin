package http

// Unit tests for the GET /api/v1/agents/live tree builder + JSON serializer.
// build_agents_live_tree is pure (takes already-fetched data), so these lock the
// resolver semantics and wire shape without a DB, including cross-project chains
// (Option A): a chain with a RUNNING agent anywhere is emitted under EVERY project
// that has any of its members (live OR dead); per-project live_agents is scoped to
// that project's running agents (may be empty); members[] is the full roster with
// project_id on every entry.

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"

// live_test_fixture builds a small owner graph:
//   projects: "Beta" (proj_b), "Alpha" (proj_a)  -> alphabetical => Alpha, Beta
//   chain_x (CROSS-PROJECT): coordinator inst_coord (proj_a, running) +
//                            inst_worker (proj_b, running) +
//                            inst_rev (proj_a, stopped, non-live member)
//   chain_dead: only inst_dead (proj_b, stopped) => NO running agent => omitted
//   chain_p2dead (P1-live/P2-dead-only): inst_p1 (proj_a, running) +
//                            inst_p2dead (proj_b, stopped) => appears under BOTH
//                            proj_a (live_agents=[P1]) and proj_b (live_agents=[])
//   chain_u: inst_ucoord (project "", running) => trailing Unassigned bucket
// Returns caller-owned maps; delete via live_test_fixture_free.
live_test_fixture :: proc() -> (projects: []domain.Project, chains: []domain.Task_Chain, members_by_chain: map[string][]domain.Task_Chain_Member, instances_by_id: map[string]domain.Agent_Instance) {
	projects = make([]domain.Project, 2)
	projects[0] = domain.Project{project_id = "proj_b", name = "Beta"}
	projects[1] = domain.Project{project_id = "proj_a", name = "Alpha"}

	chains = make([]domain.Task_Chain, 4)
	chains[0] = domain.Task_Chain{chain_id = "chain_x", title = "Cross chain", coordinator_agent_instance_id = "inst_coord"}
	chains[1] = domain.Task_Chain{chain_id = "chain_dead", title = "Dead chain", coordinator_agent_instance_id = "inst_dead"}
	chains[2] = domain.Task_Chain{chain_id = "chain_p2dead", title = "P2-dead chain", coordinator_agent_instance_id = "inst_p1"}
	chains[3] = domain.Task_Chain{chain_id = "chain_u", title = "Unassigned chain", coordinator_agent_instance_id = "inst_ucoord"}

	members_by_chain = make(map[string][]domain.Task_Chain_Member)
	mx := make([]domain.Task_Chain_Member, 3)
	mx[0] = domain.Task_Chain_Member{chain_id = "chain_x", agent_instance_id = "inst_coord", role = "coordinator"}
	mx[1] = domain.Task_Chain_Member{chain_id = "chain_x", agent_instance_id = "inst_worker", role = "member"}
	mx[2] = domain.Task_Chain_Member{chain_id = "chain_x", agent_instance_id = "inst_rev", role = "reviewer"}
	members_by_chain["chain_x"] = mx
	md := make([]domain.Task_Chain_Member, 1)
	md[0] = domain.Task_Chain_Member{chain_id = "chain_dead", agent_instance_id = "inst_dead", role = "coordinator"}
	members_by_chain["chain_dead"] = md
	mp := make([]domain.Task_Chain_Member, 2)
	mp[0] = domain.Task_Chain_Member{chain_id = "chain_p2dead", agent_instance_id = "inst_p1", role = "coordinator"}
	mp[1] = domain.Task_Chain_Member{chain_id = "chain_p2dead", agent_instance_id = "inst_p2dead", role = "member"}
	members_by_chain["chain_p2dead"] = mp
	mu := make([]domain.Task_Chain_Member, 1)
	mu[0] = domain.Task_Chain_Member{chain_id = "chain_u", agent_instance_id = "inst_ucoord", role = "coordinator"}
	members_by_chain["chain_u"] = mu

	instances_by_id = make(map[string]domain.Agent_Instance)
	instances_by_id["inst_coord"] = domain.Agent_Instance{agent_instance_id = "inst_coord", display_name = "Coordinator", project_id = "proj_a", runtime_status = "running", activity_status = "busy", created_at = "2026-01-01T00:00:00Z"}
	instances_by_id["inst_worker"] = domain.Agent_Instance{agent_instance_id = "inst_worker", display_name = "Worker", project_id = "proj_b", runtime_status = "idle", activity_status = "idle", created_at = "2026-01-02T00:00:00Z"}
	instances_by_id["inst_rev"] = domain.Agent_Instance{agent_instance_id = "inst_rev", display_name = "Reviewer", project_id = "proj_a", runtime_status = "stopped", created_at = "2026-01-03T00:00:00Z"}
	instances_by_id["inst_dead"] = domain.Agent_Instance{agent_instance_id = "inst_dead", display_name = "Dead", project_id = "proj_b", runtime_status = "stopped", created_at = "2026-01-04T00:00:00Z"}
	instances_by_id["inst_p1"] = domain.Agent_Instance{agent_instance_id = "inst_p1", display_name = "P1 Runner", project_id = "proj_a", runtime_status = "running", activity_status = "busy", created_at = "2026-01-05T00:00:00Z"}
	instances_by_id["inst_p2dead"] = domain.Agent_Instance{agent_instance_id = "inst_p2dead", display_name = "P2 Dead", project_id = "proj_b", runtime_status = "stopped", created_at = "2026-01-06T00:00:00Z"}
	instances_by_id["inst_ucoord"] = domain.Agent_Instance{agent_instance_id = "inst_ucoord", display_name = "UCoord", project_id = "", runtime_status = "running", created_at = "2026-01-07T00:00:00Z"}
	return
}

live_test_fixture_free :: proc(projects: []domain.Project, chains: []domain.Task_Chain, members_by_chain: map[string][]domain.Task_Chain_Member, instances_by_id: map[string]domain.Agent_Instance) {
	delete(projects)
	delete(chains)
	mm := members_by_chain
	for _, v in mm do delete(v)
	delete(mm)
	im := instances_by_id
	delete(im)
}

// find_project returns the project entry with the given id (or a zero value).
find_project :: proc(tree: []Agents_Live_Project, project_id: string) -> (Agents_Live_Project, bool) {
	for p in tree do if p.project_id == project_id do return p, true
	return Agents_Live_Project{}, false
}
find_chain :: proc(p: Agents_Live_Project, chain_id: string) -> (Agents_Live_Chain, bool) {
	for c in p.chains do if c.chain_id == chain_id do return c, true
	return Agents_Live_Chain{}, false
}

@(test)
test_agents_live_tree_all_projects_alphabetical :: proc(t: ^testing.T) {
	projects, chains, members_by_chain, instances_by_id := live_test_fixture()
	defer live_test_fixture_free(projects, chains, members_by_chain, instances_by_id)
	tree := build_agents_live_tree(projects, chains, members_by_chain, instances_by_id)
	defer free_agents_live_tree(tree)

	// ALL projects present, alphabetical by name, plus trailing Unassigned.
	testing.expect_value(t, len(tree), 3)
	testing.expect_value(t, tree[0].name, "Alpha")
	testing.expect_value(t, tree[1].name, "Beta")
	testing.expect_value(t, tree[2].name, "Unassigned")
	testing.expect_value(t, tree[2].project_id, "")
	// Unassigned holds chain_u (running agent with no resolvable project).
	_, u_ok := find_chain(tree[2], "chain_u")
	testing.expect(t, u_ok, "chain_u under Unassigned bucket")
}

@(test)
test_agents_live_cross_project_chain_under_both :: proc(t: ^testing.T) {
	projects, chains, members_by_chain, instances_by_id := live_test_fixture()
	defer live_test_fixture_free(projects, chains, members_by_chain, instances_by_id)
	tree := build_agents_live_tree(projects, chains, members_by_chain, instances_by_id)
	defer free_agents_live_tree(tree)

	alpha, a_ok := find_project(tree, "proj_a")
	beta, b_ok := find_project(tree, "proj_b")
	testing.expect(t, a_ok && b_ok, "both projects present")

	// chain_x appears under BOTH proj_a and proj_b, live_agents scoped per project.
	ax, ax_ok := find_chain(alpha, "chain_x")
	bx, bx_ok := find_chain(beta, "chain_x")
	testing.expect(t, ax_ok, "chain_x under proj_a")
	testing.expect(t, bx_ok, "chain_x under proj_b")
	testing.expect_value(t, len(ax.live_agents), 1)
	testing.expect_value(t, ax.live_agents[0].display_name, "Coordinator")
	testing.expect_value(t, ax.live_agents[0].project_id, "proj_a")
	testing.expect_value(t, ax.live_agents[0].is_coordinator, true)
	testing.expect_value(t, len(bx.live_agents), 1)
	testing.expect_value(t, bx.live_agents[0].display_name, "Worker")
	testing.expect_value(t, bx.live_agents[0].project_id, "proj_b")

	// members[] is the FULL roster on BOTH entries (Coordinator/proj_a live,
	// Reviewer/proj_a dead, Worker/proj_b live), each with its own project_id.
	testing.expect_value(t, len(ax.members), 3)
	testing.expect_value(t, len(bx.members), 3)
	saw_rev := false
	saw_worker := false
	for m in bx.members {
		if m.agent_instance_id == "inst_rev" {
			saw_rev = true
			testing.expect_value(t, m.is_live, false)
			testing.expect_value(t, m.project_id, "proj_a")
			testing.expect_value(t, m.role, "reviewer")
		}
		if m.agent_instance_id == "inst_worker" {
			saw_worker = true
			testing.expect_value(t, m.is_live, true)
			testing.expect_value(t, m.project_id, "proj_b")
		}
	}
	testing.expect(t, saw_rev, "non-live cross-project member present in members roster")
	testing.expect(t, saw_worker, "live cross-project member present in members roster")
}

@(test)
test_agents_live_p1_live_p2_dead_only :: proc(t: ^testing.T) {
	projects, chains, members_by_chain, instances_by_id := live_test_fixture()
	defer live_test_fixture_free(projects, chains, members_by_chain, instances_by_id)
	tree := build_agents_live_tree(projects, chains, members_by_chain, instances_by_id)
	defer free_agents_live_tree(tree)

	alpha, _ := find_project(tree, "proj_a")
	beta, _ := find_project(tree, "proj_b")
	// chain_p2dead has a running agent in proj_a and only a DEAD member in proj_b.
	// It must appear under BOTH; under proj_b live_agents is EMPTY but members[]
	// still lists the full roster incl. the dead proj_b member.
	ap, ap_ok := find_chain(alpha, "chain_p2dead")
	bp, bp_ok := find_chain(beta, "chain_p2dead")
	testing.expect(t, ap_ok, "chain_p2dead under proj_a (live)")
	testing.expect(t, bp_ok, "chain_p2dead under proj_b (dead-only)")
	testing.expect_value(t, len(ap.live_agents), 1)
	testing.expect_value(t, ap.live_agents[0].display_name, "P1 Runner")
	testing.expect_value(t, len(bp.live_agents), 0) // dead-only project => empty
	testing.expect_value(t, len(bp.members), 2)     // full roster on the dead-only entry
	saw_p2dead := false
	for m in bp.members {
		if m.agent_instance_id == "inst_p2dead" {
			saw_p2dead = true
			testing.expect_value(t, m.is_live, false)
			testing.expect_value(t, m.project_id, "proj_b")
		}
	}
	testing.expect(t, saw_p2dead, "dead proj_b member present in members roster")
}

@(test)
test_agents_live_chain_omitted_when_no_running_agent :: proc(t: ^testing.T) {
	projects, chains, members_by_chain, instances_by_id := live_test_fixture()
	defer live_test_fixture_free(projects, chains, members_by_chain, instances_by_id)
	tree := build_agents_live_tree(projects, chains, members_by_chain, instances_by_id)
	defer free_agents_live_tree(tree)
	// chain_dead has a single stopped member -> omitted from EVERY project.
	for p in tree {
		_, ok := find_chain(p, "chain_dead")
		testing.expect(t, !ok, "chain with no running agent must be omitted everywhere")
	}
}

@(test)
test_agents_live_json_contract :: proc(t: ^testing.T) {
	projects, chains, members_by_chain, instances_by_id := live_test_fixture()
	defer live_test_fixture_free(projects, chains, members_by_chain, instances_by_id)
	tree := build_agents_live_tree(projects, chains, members_by_chain, instances_by_id)
	defer free_agents_live_tree(tree)
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	write_agents_live_json(&b, tree)
	out := strings.to_string(b)
	testing.expect(t, strings.contains(out, "\"projects\":["), "top-level projects array")
	testing.expect(t, strings.contains(out, "\"project_id\":\"proj_a\""), "project_id emitted")
	testing.expect(t, strings.contains(out, "\"name\":\"Alpha\""), "project name emitted")
	testing.expect(t, strings.contains(out, "\"coordinator_agent_instance_id\":\"inst_coord\""), "coordinator id emitted")
	testing.expect(t, strings.contains(out, "\"live_agents\":["), "live_agents array")
	testing.expect(t, strings.contains(out, "\"is_coordinator\":true"), "coordinator flag emitted")
	testing.expect(t, strings.contains(out, "\"is_live\":false"), "non-live member emitted")
	testing.expect(t, strings.contains(out, "\"activity_status\":\"busy\""), "activity_status emitted")
	// project_id present in BOTH live_agents and members entries.
	testing.expect(t, strings.contains(out, "\"activity_status\":\"busy\",\"project_id\":\"proj_a\""), "live_agent project_id emitted")
	testing.expect(t, strings.contains(out, "\"runtime_status\":\"stopped\",\"project_id\":\"proj_a\""), "member project_id emitted")
	// created_at surfaced on both live_agents and members entries.
	testing.expect(t, strings.contains(out, "\"project_id\":\"proj_a\",\"created_at\":\"2026-01-01T00:00:00Z\""), "created_at emitted per entry")
	// Alphabetical: Alpha's project object precedes Beta's.
	testing.expect(t, strings.index(out, "\"name\":\"Alpha\"") < strings.index(out, "\"name\":\"Beta\""), "projects alphabetical")
}

// order_fixture builds a single project "Ordering" (proj_o) with three chains so
// group + agent ordering can be asserted independently of the cross-project
// fixture:
//   chain_early: DEAD member (created 2026-01-01) + a running member (2026-01-20)
//                => group_created_at = 2026-01-01 (earliest incl. DEAD).
//   chain_multi: two running agents (2026-01-05, 2026-01-25)
//                => group_created_at = 2026-01-05.
//   chain_late:  one running agent (2026-01-10) => group_created_at = 2026-01-10.
// Expected group order within proj_o: chain_early, chain_multi, chain_late.
order_fixture :: proc() -> (projects: []domain.Project, chains: []domain.Task_Chain, members_by_chain: map[string][]domain.Task_Chain_Member, instances_by_id: map[string]domain.Agent_Instance) {
	projects = make([]domain.Project, 1)
	projects[0] = domain.Project{project_id = "proj_o", name = "Ordering"}

	chains = make([]domain.Task_Chain, 3)
	chains[0] = domain.Task_Chain{chain_id = "chain_late", title = "Late", coordinator_agent_instance_id = "inst_late"}
	chains[1] = domain.Task_Chain{chain_id = "chain_multi", title = "Multi", coordinator_agent_instance_id = "inst_m_old"}
	chains[2] = domain.Task_Chain{chain_id = "chain_early", title = "Early", coordinator_agent_instance_id = "inst_e_dead"}

	members_by_chain = make(map[string][]domain.Task_Chain_Member)
	ml := make([]domain.Task_Chain_Member, 1)
	ml[0] = domain.Task_Chain_Member{chain_id = "chain_late", agent_instance_id = "inst_late", role = "coordinator"}
	members_by_chain["chain_late"] = ml
	mm := make([]domain.Task_Chain_Member, 2)
	mm[0] = domain.Task_Chain_Member{chain_id = "chain_multi", agent_instance_id = "inst_m_old", role = "coordinator"}
	mm[1] = domain.Task_Chain_Member{chain_id = "chain_multi", agent_instance_id = "inst_m_new", role = "member"}
	members_by_chain["chain_multi"] = mm
	me := make([]domain.Task_Chain_Member, 2)
	me[0] = domain.Task_Chain_Member{chain_id = "chain_early", agent_instance_id = "inst_e_dead", role = "coordinator"}
	me[1] = domain.Task_Chain_Member{chain_id = "chain_early", agent_instance_id = "inst_e_run", role = "member"}
	members_by_chain["chain_early"] = me

	instances_by_id = make(map[string]domain.Agent_Instance)
	instances_by_id["inst_late"] = domain.Agent_Instance{agent_instance_id = "inst_late", display_name = "Late Runner", project_id = "proj_o", runtime_status = "running", created_at = "2026-01-10T00:00:00Z"}
	instances_by_id["inst_m_old"] = domain.Agent_Instance{agent_instance_id = "inst_m_old", display_name = "Multi Old", project_id = "proj_o", runtime_status = "running", created_at = "2026-01-05T00:00:00Z"}
	instances_by_id["inst_m_new"] = domain.Agent_Instance{agent_instance_id = "inst_m_new", display_name = "Multi New", project_id = "proj_o", runtime_status = "running", created_at = "2026-01-25T00:00:00Z"}
	instances_by_id["inst_e_dead"] = domain.Agent_Instance{agent_instance_id = "inst_e_dead", display_name = "Early Dead", project_id = "proj_o", runtime_status = "stopped", created_at = "2026-01-01T00:00:00Z"}
	instances_by_id["inst_e_run"] = domain.Agent_Instance{agent_instance_id = "inst_e_run", display_name = "Early Runner", project_id = "proj_o", runtime_status = "running", created_at = "2026-01-20T00:00:00Z"}
	return
}

@(test)
test_agents_live_group_order_by_min_member_created_at :: proc(t: ^testing.T) {
	projects, chains, members_by_chain, instances_by_id := order_fixture()
	defer live_test_fixture_free(projects, chains, members_by_chain, instances_by_id)
	tree := build_agents_live_tree(projects, chains, members_by_chain, instances_by_id)
	defer free_agents_live_tree(tree)

	p, ok := find_project(tree, "proj_o")
	testing.expect(t, ok, "proj_o present")
	testing.expect_value(t, len(p.chains), 3)
	// Group order by per-project MIN(member created_at), earliest first — and
	// chain_early wins on its DEAD member's 2026-01-01 timestamp.
	testing.expect_value(t, p.chains[0].chain_id, "chain_early")
	testing.expect_value(t, p.chains[1].chain_id, "chain_multi")
	testing.expect_value(t, p.chains[2].chain_id, "chain_late")
}

@(test)
test_agents_live_agents_within_group_oldest_first :: proc(t: ^testing.T) {
	projects, chains, members_by_chain, instances_by_id := order_fixture()
	defer live_test_fixture_free(projects, chains, members_by_chain, instances_by_id)
	tree := build_agents_live_tree(projects, chains, members_by_chain, instances_by_id)
	defer free_agents_live_tree(tree)

	p, _ := find_project(tree, "proj_o")
	multi, ok := find_chain(p, "chain_multi")
	testing.expect(t, ok, "chain_multi present")
	testing.expect_value(t, len(multi.live_agents), 2)
	// Oldest-first by created_at: Multi Old (2026-01-05) before Multi New (2026-01-25).
	testing.expect_value(t, multi.live_agents[0].agent_instance_id, "inst_m_old")
	testing.expect_value(t, multi.live_agents[0].created_at, "2026-01-05T00:00:00Z")
	testing.expect_value(t, multi.live_agents[1].agent_instance_id, "inst_m_new")
	// members[] also ordered oldest-first by created_at.
	testing.expect_value(t, multi.members[0].agent_instance_id, "inst_m_old")
	testing.expect_value(t, multi.members[1].agent_instance_id, "inst_m_new")
}

@(test)
test_agents_live_archived_project_omitted_and_not_in_unassigned :: proc(t: ^testing.T) {
	projects, chains, members_by_chain, instances_by_id := live_test_fixture()
	defer live_test_fixture_free(projects, chains, members_by_chain, instances_by_id)

	// Mark proj_b (Beta) as Archived.
	projects[0].state = .Archived

	tree := build_agents_live_tree(projects, chains, members_by_chain, instances_by_id)
	defer free_agents_live_tree(tree)

	// Archived project Beta must NOT be in tree.
	_, beta_ok := find_project(tree, "proj_b")
	testing.expect(t, !beta_ok, "archived project Beta must be omitted from tree")

	// Active project Alpha must be in tree.
	alpha, alpha_ok := find_project(tree, "proj_a")
	testing.expect(t, alpha_ok, "active project Alpha must be present")

	// chain_x still appears under proj_a (Coordinator is in proj_a and running)
	_, ax_ok := find_chain(alpha, "chain_x")
	testing.expect(t, ax_ok, "chain_x present under active Alpha")

	// chain_p2dead appears under Alpha (P1 is in proj_a and running)
	_, ap_ok := find_chain(alpha, "chain_p2dead")
	testing.expect(t, ap_ok, "chain_p2dead present under active Alpha")

	// Unassigned must ONLY contain chain_u, NOT any chain or member from Beta.
	unassigned, u_ok := find_project(tree, "")
	testing.expect(t, u_ok, "unassigned bucket present")
	testing.expect_value(t, len(unassigned.chains), 1)
	testing.expect_value(t, unassigned.chains[0].chain_id, "chain_u")
}

