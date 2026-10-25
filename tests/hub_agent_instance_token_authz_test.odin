package hub_agent_instance_token_authz_test

// Authz test for agents acting on instances via an INSTANCE token
// (task_18d12bb726863c3e). Switching the stop/restart HTTP handlers to
// require_auth_any lets a bridge-relayed instance token reach them; the security
// boundary is the SERVICE layer's get_instance -> require_owner, which stop_instance
// and restart_instance both funnel through. This test asserts that gate directly:
//   - an Instance_Token Auth_Context whose owner MATCHES the target instance
//     resolves it (an agent may act on an instance it owns), and
//   - a cross-owner Instance_Token is rejected with Not_Found (no cross-owner
//     launch/stop/restart), identical to the user-token boundary.

import "core:fmt"
import "core:testing"
import "core:os"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import agent_service "odin_test:hub/service/agent"
import platform "odin_test:hub/platform"

Fake_Repo :: struct {
	instances: [8]domain.Agent_Instance,
	count:     int,
}

fr_save :: proc(ctx: rawptr, inst: domain.Agent_Instance) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	repo := (^Fake_Repo)(ctx)
	for i in 0..<repo.count {
		if repo.instances[i].agent_instance_id == inst.agent_instance_id {
			repo.instances[i] = inst
			return inst, true, domain.Domain_Error{}
		}
	}
	repo.instances[repo.count] = inst
	repo.count += 1
	return inst, true, domain.Domain_Error{}
}

fr_get :: proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	repo := (^Fake_Repo)(ctx)
	for i in 0..<repo.count {
		if repo.instances[i].agent_instance_id == id do return repo.instances[i], true, domain.Domain_Error{}
	}
	return domain.Agent_Instance{}, false, domain.domain_error(.Not_Found, "agent instance not found")
}

fr_now: string = "2026-09-01T10:00:00Z"
fr_clock_now :: proc(ctx: rawptr) -> string { _ = ctx; return fr_now }

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln("FAIL:", message); os.exit(1) }

@(test)
test_hub_agent_instance_token_authz_test :: proc(t: ^testing.T) {
	_ = t
	main()
}

main :: proc() {
	repo := new(Fake_Repo)
	agents := iface.Agent_Repository{ ctx = rawptr(repo), save_instance = fr_save, get_instance = fr_get }
	bridges := iface.Bridge_Repository{}
	clock := platform.Clock{ now = fr_clock_now }
	ids := platform.real_id_generator()
	svc := agent_service.new_agent_service(&agents, &bridges, &clock, &ids)

	_, _, _ = fr_save(rawptr(repo), domain.Agent_Instance{agent_instance_id = "inst_owned", owner_user_id = "usr_a", bridge_id = "brg_a", runtime_status = "running"})

	// An INSTANCE token for the SAME owner resolves the instance (agents may act
	// on instances they own). This is the exact gate stop_instance/restart_instance use.
	same_owner := contracts.Auth_Context{kind = .Instance_Token, user_id = "usr_a", agent_instance_id = "inst_coordinator", bridge_id = "brg_a"}
	inst, ok, err := agent_service.get_instance(&svc, same_owner, "inst_owned")
	check(ok && err.code == .None, "same-owner instance token must resolve the target instance")
	check(inst.agent_instance_id == "inst_owned", "resolved the correct instance")

	// A cross-owner instance token is rejected (Not_Found) — no cross-owner action.
	cross_owner := contracts.Auth_Context{kind = .Instance_Token, user_id = "usr_b", agent_instance_id = "inst_other", bridge_id = "brg_b"}
	_, ok2, err2 := agent_service.get_instance(&svc, cross_owner, "inst_owned")
	check(!ok2, "cross-owner instance token must NOT resolve another owner's instance")
	check(err2.code == .Not_Found, "cross-owner access must be Not_Found (no info leak)")

	// A user token for the same owner behaves identically (boundary is owner, not kind).
	user_same := contracts.Auth_Context{kind = .Session, user_id = "usr_a"}
	_, ok3, _ := agent_service.get_instance(&svc, user_same, "inst_owned")
	check(ok3, "same-owner user token resolves too (owner is the boundary, not token kind)")

	fmt.println("PASS: hub agent instance token authz (same-owner ok, cross-owner Not_Found)")
}
