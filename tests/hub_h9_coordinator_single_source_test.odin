package hub_h9_coordinator_single_source_test

// H9: task_chain_members (role="coordinator") is the SINGLE canonical source of
// who coordinates a chain; the task_chains.coordinator_agent_instance_id column
// is only a derived mirror. Covers:
//   T1. create_chain by an instance token => caller is coordinator via the ONE
//       source; is_chain_coordinator true; the mirror column is derived, not
//       independently authoritative (empty-column lockout is unrepresentable).
//   T2. change coordinator => old member loses coordinator authority, new gains
//       it; the single source reflects it and the mirror follows.
//   T3. one agent coordinates TWO chains => list_chains_coordinated_by returns
//       BOTH (reverse query over the members table).
//   T4. legacy backfill: a chain with the column set but NO coordinator member is
//       still authorized once the member is backfilled (simulating migration 018).
//   T5. coordinator-gated actions authorize the coordinator and reject others,
//       using only the single source.
//   T6. ensure_chain_member must NOT demote an existing member: promoting the
//       coordinator onto a planning/micro-task used to rewrite its members row to
//       role="worker" (save_member upserts with SET role=excluded.role), locking the
//       real coordinator out of every coordinator-gated action. Regression for
//       iss_18d892561e009db7.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import taskchain_service "odin_test:hub/service/taskchain"
import platform "odin_test:hub/platform"

Repo :: struct {
	chains: [16]domain.Task_Chain,
	chain_count: int,
	members: [32]domain.Task_Chain_Member,
	member_count: int,
	instances: [16]domain.Agent_Instance,
	instance_count: int,
	seq: int,
}

now_proc :: proc(ctx: rawptr) -> string { _ = ctx; return "2026-07-22T10:00:00Z" }
id_proc :: proc(ctx: rawptr, prefix: string) -> string {
	r := (^Repo)(ctx); r.seq += 1; return strings.concatenate({prefix, fmt.tprintf("%d", r.seq)})
}

chain_get :: proc(ctx: rawptr, id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	r := (^Repo)(ctx)
	for i in 0..<r.chain_count { if r.chains[i].chain_id == id do return r.chains[i], true, domain.Domain_Error{} }
	return domain.Task_Chain{}, false, domain.domain_error(.Not_Found, "chain not found")
}
chain_save :: proc(ctx: rawptr, c: domain.Task_Chain) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	r := (^Repo)(ctx)
	for i in 0..<r.chain_count { if r.chains[i].chain_id == c.chain_id { r.chains[i] = c; return c, true, domain.Domain_Error{} } }
	r.chains[r.chain_count] = c; r.chain_count += 1; return c, true, domain.Domain_Error{}
}
member_save :: proc(ctx: rawptr, m: domain.Task_Chain_Member) -> (domain.Task_Chain_Member, bool, domain.Domain_Error) {
	r := (^Repo)(ctx)
	for i in 0..<r.member_count { if r.members[i].chain_id == m.chain_id && r.members[i].agent_instance_id == m.agent_instance_id { r.members[i] = m; return m, true, domain.Domain_Error{} } }
	r.members[r.member_count] = m; r.member_count += 1; return m, true, domain.Domain_Error{}
}
member_remove :: proc(ctx: rawptr, id: domain.Task_Chain_ID, agent_instance_id: string, owner: domain.User_ID) -> (bool, domain.Domain_Error) {
	r := (^Repo)(ctx)
	for i in 0..<r.member_count {
		if r.members[i].chain_id == id && r.members[i].agent_instance_id == agent_instance_id {
			// compact
			for j in i..<r.member_count-1 { r.members[j] = r.members[j+1] }
			r.member_count -= 1
			return true, domain.Domain_Error{}
		}
	}
	return false, domain.Domain_Error{}
}
member_list :: proc(ctx: rawptr, id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task_Chain_Member, domain.Domain_Error) {
	r := (^Repo)(ctx)
	out := make([dynamic]domain.Task_Chain_Member)
	for i in 0..<r.member_count { if r.members[i].chain_id == id do append(&out, r.members[i]) }
	return out[:], domain.Domain_Error{}
}
// Reverse query mirroring the sqlite JOIN: chains where the instance is a
// coordinator member, owner-scoped.
chains_by_coordinator :: proc(ctx: rawptr, agent_instance_id: string, owner: domain.User_ID) -> ([]domain.Task_Chain, domain.Domain_Error) {
	r := (^Repo)(ctx)
	out := make([dynamic]domain.Task_Chain)
	for ci in 0..<r.chain_count {
		c := r.chains[ci]
		if c.owner_user_id != owner do continue
		for mi in 0..<r.member_count {
			m := r.members[mi]
			if m.chain_id == c.chain_id && m.role == "coordinator" && m.agent_instance_id == agent_instance_id {
				append(&out, c)
				break
			}
		}
	}
	return out[:], domain.Domain_Error{}
}
inst_get :: proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	r := (^Repo)(ctx)
	for i in 0..<r.instance_count { if r.instances[i].agent_instance_id == id do return r.instances[i], true, domain.Domain_Error{} }
	return domain.Agent_Instance{}, false, domain.domain_error(.Not_Found, "instance not found")
}

add_instance :: proc(r: ^Repo, id: string, owner: string, chain_id: string) {
	r.instances[r.instance_count] = domain.Agent_Instance{agent_instance_id = id, owner_user_id = domain.User_ID(owner), agent_id = "agt_a", chain_id = chain_id}
	r.instance_count += 1
}

@(test)
test_hub_h9_coordinator_single_source :: proc(t: ^testing.T) {
	_ = t
	main()
}

main :: proc() {
	data: Repo
	clock := platform.Clock{ctx = nil, now = now_proc}
	ids := platform.ID_Generator{ctx = rawptr(&data), generate = id_proc}
	repo := iface.Taskchain_Repository{ctx = rawptr(&data), get_chain = chain_get, save_chain = chain_save, save_member = member_save, remove_member = member_remove, list_members_by_chain = member_list, list_chains_by_coordinator = chains_by_coordinator}
	agents := iface.Agent_Repository{ctx = rawptr(&data), get_instance = inst_get}
	service := taskchain_service.new_taskchain_service(&repo, &agents, &clock, &ids)

	coord := "inst_coord"
	add_instance(&data, coord, "alice", "")
	auth := contracts.Auth_Context{kind = .Instance_Token, user_id = "alice", agent_instance_id = coord}

	// --- T1: create_chain => coordinator via the ONE source ---
	chain, ok, err := taskchain_service.create_chain(&service, auth, taskchain_service.Create_Chain_Input{title = "chain one"})
	check(ok, err.message)
	check(taskchain_service.is_chain_coordinator(&service, chain, coord), "T1: creator must be coordinator via the members table")
	// The coordinator lives in the members table (single source).
	members, _ := member_list(rawptr(&data), chain.chain_id, "alice")
	coord_member_found := false
	for m in members { if m.agent_instance_id == coord && m.role == "coordinator" do coord_member_found = true }
	check(coord_member_found, "T1: coordinator must exist as a role='coordinator' member")
	// Mirror column is derived (kept in sync), not independently authoritative.
	check(chain.coordinator_agent_instance_id == coord, "T1: derived mirror column reflects the members-table coordinator")

	// --- T2: change coordinator => authority moves; single source reflects it ---
	coord2 := "inst_coord2"
	add_instance(&data, coord2, "alice", string(chain.chain_id))
	_, add_ok, add_err := taskchain_service.add_chain_member(&service, auth, chain.chain_id, coord2, "worker")
	check(add_ok, add_err.message)
	changed, chg_ok, chg_err := taskchain_service.update_chain_coordinator(&service, auth, chain.chain_id, coord2)
	check(chg_ok, chg_err.message)
	check(changed.coordinator_agent_instance_id == coord2, "T2: mirror follows the new coordinator")
	check(taskchain_service.is_chain_coordinator(&service, changed, coord2), "T2: new coordinator has authority")
	check(!taskchain_service.is_chain_coordinator(&service, changed, coord), "T2: old coordinator lost authority (single source)")

	// --- T3: one agent coordinates TWO chains ---
	// coord2 now coordinates `chain`. Create a SECOND chain coordinated by coord2.
	auth2 := contracts.Auth_Context{kind = .Instance_Token, user_id = "alice", agent_instance_id = coord2}
	chain_b, ok_b, err_b := taskchain_service.create_chain(&service, auth2, taskchain_service.Create_Chain_Input{title = "chain two"})
	check(ok_b, err_b.message)
	coordinated, coord_err := taskchain_service.list_chains_coordinated_by(&service, auth2, "")
	check(coord_err.code == .None, "T3: reverse query must succeed")
	check(len(coordinated) == 2, fmt.tprintf("T3: coord2 must coordinate BOTH chains, got %d", len(coordinated)))
	seen_a := false; seen_b := false
	for c in coordinated { if c.chain_id == chain.chain_id do seen_a = true; if c.chain_id == chain_b.chain_id do seen_b = true }
	check(seen_a && seen_b, "T3: both coordinated chains must be returned")
	// Owner scoping: a different owner's token sees none of alice's coordinated chains.
	bob_auth := contracts.Auth_Context{kind = .Instance_Token, user_id = "bob", agent_instance_id = "inst_bob"}
	bob_coordinated, _ := taskchain_service.list_chains_coordinated_by(&service, bob_auth, coord2)
	check(len(bob_coordinated) == 0, "T3: cross-owner token must not see another owner's coordinated chains")

	// --- T4: legacy backfill (migration 018 simulation) ---
	// A chain with the mirror column set but NO coordinator member (the drift bug).
	legacy := domain.Task_Chain{chain_id = "chain_legacy", owner_user_id = "alice", title = "legacy", publish_state = .Published, status = .Active, coordinator_agent_instance_id = coord, created_at = "2026-07-22T09:00:00Z", updated_at = "2026-07-22T09:00:00Z"}
	_, _, _ = chain_save(rawptr(&data), legacy)
	add_instance(&data, coord, "alice", "chain_legacy")
	// Before backfill, authority reads the (empty) members table -> NOT coordinator.
	check(!taskchain_service.is_chain_coordinator(&service, legacy, coord), "T4: pre-backfill, empty members table means no coordinator authority (the drift)")
	// Simulate migration 018: insert the coordinator member row.
	_, _, _ = member_save(rawptr(&data), domain.Task_Chain_Member{chain_id = "chain_legacy", agent_instance_id = coord, owner_user_id = "alice", role = "coordinator", created_at = "2026-07-22T09:00:00Z"})
	check(taskchain_service.is_chain_coordinator(&service, legacy, coord), "T4: after backfill, the legacy coordinator is preserved via the members table")

	// --- T5: coordinator-gated action authorizes coordinator, rejects others ---
	// coord2 coordinates `chain`; a plain worker must be rejected.
	worker := "inst_worker"
	add_instance(&data, worker, "alice", string(chain.chain_id))
	_, _, _ = taskchain_service.add_chain_member(&service, auth2, chain.chain_id, worker, "worker")
	worker_auth := contracts.Auth_Context{kind = .Instance_Token, user_id = "alice", agent_instance_id = worker}
	_, w_ok, w_err := taskchain_service.update_chain(&service, worker_auth, chain.chain_id, taskchain_service.Update_Chain_Input{description = "nope"})
	check(!w_ok && w_err.code == .Forbidden, "T5: a worker must be rejected by the single-source coordinator gate")
	_, c_ok, c_err := taskchain_service.update_chain(&service, auth2, chain.chain_id, taskchain_service.Update_Chain_Input{description = "by coordinator"})
	check(c_ok, fmt.tprintf("T5: the coordinator must be authorized: %s", c_err.message))

	// --- T6: ensure_chain_member must not demote an existing member (iss_18d892561e009db7) ---
	// `chain` is coordinated by coord2 at this point (T2 moved it). Simulate promotion
	// choosing the COORDINATOR instance for a planning / micro-task: that path calls
	// ensure_chain_member for the chosen instance.
	check(taskchain_service.is_chain_coordinator(&service, chain, coord2), "T6: precondition — coord2 coordinates the chain")
	taskchain_service.ensure_chain_member(&service, chain, coord2, "agt_a")
	// Before the fix this wrote role="worker" over the coordinator row, so the canonical
	// members table stopped recognising the coordinator at all.
	check(taskchain_service.is_chain_coordinator(&service, chain, coord2), "T6: ensure_chain_member must NOT demote the coordinator to worker")
	// And the coordinator-gated actions the demotion broke must still authorize it.
	_, r_ok, r_err := taskchain_service.update_chain(&service, auth2, chain.chain_id, taskchain_service.Update_Chain_Input{description = "still coordinator after taking a task"})
	check(r_ok, fmt.tprintf("T6: coordinator must stay authorized after ensure_chain_member: %s", r_err.message))

	// A genuinely absent instance is still added, with the worker role (the original contract).
	newcomer := "inst_newcomer"
	add_instance(&data, newcomer, "alice", string(chain.chain_id))
	taskchain_service.ensure_chain_member(&service, chain, newcomer, "agt_a")
	t6_members, _ := member_list(rawptr(&data), chain.chain_id, "alice")
	newcomer_role := ""
	for m in t6_members { if m.agent_instance_id == newcomer do newcomer_role = m.role }
	check(newcomer_role == "worker", fmt.tprintf("T6: an absent instance must still be added as worker, got %q", newcomer_role))

	// An existing REVIEWER member must not be rewritten to worker either.
	rev := "inst_reviewer"
	add_instance(&data, rev, "alice", string(chain.chain_id))
	_, _, _ = taskchain_service.add_chain_member(&service, auth2, chain.chain_id, rev, "reviewer")
	taskchain_service.ensure_chain_member(&service, chain, rev, "agt_a")
	rev_members, _ := member_list(rawptr(&data), chain.chain_id, "alice")
	rev_role := ""
	for m in rev_members { if m.agent_instance_id == rev do rev_role = m.role }
	check(rev_role == "reviewer", fmt.tprintf("T6: an existing reviewer member must keep its role, got %q", rev_role))

	// --- T7 (H5): Cross-owner get_chain isolation and outsider coordinator target rejection ---
	_, cross_ok, cross_err := taskchain_service.get_chain(&service, bob_auth, chain.chain_id)
	check(!cross_ok && cross_err.code == .Not_Found, "T7: cross-owner instance token must not resolve another owner's chain")
	outsider := "inst_alice_outsider"
	add_instance(&data, outsider, "alice", "")
	_, bad_ok, bad_err := taskchain_service.update_chain(&service, auth2, chain.chain_id, taskchain_service.Update_Chain_Input{coordinator_agent_instance_id = outsider, has_coordinator = true})
	check(!bad_ok && bad_err.code == .Conflict, "T7: coordinator target must belong to the same chain")

	fmt.println("PASS: hub H9 coordinator single source of truth")
}

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln(message); os.exit(1) }
