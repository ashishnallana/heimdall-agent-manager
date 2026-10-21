#+private file
package taskv2

import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"

// Agent-mode `ham-ctl task-chain graph|depend|remove-dependency|scope|complete`
// relays to agent.work.*, whose Hub handler passes actor_from_auth(instance
// token) = ACTOR_AGENT{instance id} into these services. This pins the
// contract the CLI relies on: the chain's coordinator instance may add a ticket
// prerequisite on a whole workflow run and edit/complete the graph; any other
// enrolled agent instance is refused every mutation, completion included.

authz_fixture :: proc(t: ^testing.T) -> (^Fixture, bool) {
	fx := new(Fixture)
	conn, ok := fixture_clone_migrated(t)
	if !ok do return fx, false
	fx.conn = conn
	fixture_wire(fx)
	chain := seed_chain(t, fx, "authz_chain", true)
	chain.coordinator_agent_instance_id = "coord_instance"
	_, _, _ = iface.taskchain_save_chain(&fx.repo, chain)
	_ = seed_task(t, fx, chain, "authz_ticket")
	return fx, true
}

authz_run :: proc(t: ^testing.T, fx: ^Fixture, id: string) -> domain.Work_Item_Ref {
	u, ok, err := begin_uow(&fx.svc)
	if !testing.expect(t, ok, err.message) do return {}
	now := platform.clock_now(&fx.clock)
	_, rok, _ := iface.taskchain_insert_workflow_run(&fx.repo, domain.Workflow_Run{
		run_id = domain.Workflow_Run_ID(id), chain_id = "authz_chain", owner_user_id = "u1",
		title = "Research", definition_ref = "research@1", spec_json = `{"name":"research","stages":[]}`,
		inputs_json = "{}", current_execution_no = 1, request_id = id, request_hash = "hash",
		created_by_kind = "user", created_by_id = "u1", created_at = now, updated_at = now, revision = 1,
	})
	_, eok, _ := iface.taskchain_insert_workflow_execution(&fx.repo, domain.Workflow_Run_Execution{
		run_id = domain.Workflow_Run_ID(id), execution_no = 1, chain_id = "authz_chain", owner_user_id = "u1",
		state = domain.WORKFLOW_EXECUTION_PENDING, resolved_inputs_json = "{}", output_manifest_json = "{}", revision = 1,
	})
	_, cerr := end_uow(&fx.svc, &u, rok && eok)
	testing.expect(t, rok && eok && cerr.code == .None, "seed workflow run")
	return domain.Work_Item_Ref{kind = domain.WORK_ITEM_WORKFLOW_RUN, id = id}
}

@(test)
test_mixed_work_agent_routing_authority :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fx, ok := authz_fixture(t)
	defer sqlite.close(&fx.conn)
	if !ok do return
	ticket := domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK, id = "authz_ticket"}
	run := authz_run(t, fx, "wrun_authz")
	coordinator := Actor{kind = ACTOR_AGENT, id = "coord_instance"}
	worker := Actor{kind = ACTOR_AGENT, id = "inst_worker"}

	_, denied, derr := work_dependency_add(&fx.svc, "u1", worker, "authz_chain", ticket, run, reconcile = false)
	testing.expect(t, !denied && derr.code == .Forbidden, "non-coordinator agent cannot add a graph edge")

	edge, added, aerr := work_dependency_add(&fx.svc, "u1", coordinator, "authz_chain", ticket, run, reconcile = false)
	testing.expect(t, added && aerr.code == .None, aerr.message)
	testing.expect(t, edge.prerequisite == run && edge.dependent == ticket, "ticket depends on the whole workflow run")
	testing.expect_value(t, edge.created_by_kind, ACTOR_AGENT)
	edges, _ := iface.taskchain_list_work_dependencies(&fx.repo, "authz_chain", "u1")
	testing.expect_value(t, len(edges), 1)

	removed, rerr := work_dependency_remove(&fx.svc, "u1", worker, "authz_chain", edge.dependency_id, "not mine", reconcile = false)
	testing.expect(t, !removed && rerr.code == .Forbidden, "non-coordinator agent cannot remove a graph edge")
	_, scoped, serr := work_scope_decide(&fx.svc, "u1", worker, "authz_chain", run, "exclude", "not mine")
	testing.expect(t, !scoped && serr.code == .Forbidden, "non-coordinator agent cannot record scope")
	chain, _, _ := iface.taskchain_get_chain(&fx.repo, "authz_chain")
	_, completed, cerr := work_chain_complete(&fx.svc, "u1", worker, "authz_chain", chain.work_revision, "done")
	testing.expect(t, !completed && cerr.code == .Forbidden, "non-coordinator agent cannot complete the chain")
	after, _, _ := iface.taskchain_get_chain(&fx.repo, "authz_chain")
	testing.expect(t, after.status == .Active, "refused completion leaves the chain active")

	// Another owner's view never sees the edge (cross-owner isolation).
	_, cross_owner, ferr := work_dependency_add(&fx.svc, "u2", coordinator, "authz_chain", ticket, run, reconcile = false)
	testing.expect(t, !cross_owner && ferr.code == .Not_Found, "foreign owner cannot address the chain")
}
