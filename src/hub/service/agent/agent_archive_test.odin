package agent

import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// One stored agent, read and replaced in place, so archive/unarchive can be
// exercised without sqlite.
Archive_Fake_Store :: struct {
	agent: domain.Agent,
}

archive_fake_get :: proc(ctx: rawptr, agent_id: string) -> (domain.Agent, bool, domain.Domain_Error) {
	store := cast(^Archive_Fake_Store)ctx
	if store.agent.agent_id != agent_id do return domain.Agent{}, false, domain.domain_error(.Not_Found, "agent not found")
	return store.agent, true, {}
}

archive_fake_save :: proc(ctx: rawptr, a: domain.Agent) -> (domain.Agent, bool, domain.Domain_Error) {
	store := cast(^Archive_Fake_Store)ctx
	store.agent = a
	return a, true, {}
}

@(test)
test_unarchive_agent_restores_active_for_its_owner_only :: proc(t: ^testing.T) {
	store := Archive_Fake_Store{agent = domain.Agent{agent_id = "agt_1", owner_user_id = "user_1", name = "coder", state = .Active}}
	repo := iface.Agent_Repository{ctx = &store, get = archive_fake_get, save = archive_fake_save}
	clock := platform.real_clock()
	ids := platform.real_id_generator()
	service := new_agent_service(&repo, nil, &clock, &ids)
	owner := contracts.Auth_Context{user_id = "user_1"}

	archived, archived_ok, _ := archive_agent(&service, owner, "agt_1")
	testing.expect(t, archived_ok, "archive ok")
	testing.expect_value(t, archived.state, domain.Agent_State.Archived)

	_, other_ok, _ := unarchive_agent(&service, contracts.Auth_Context{user_id = "user_2"}, "agt_1")
	testing.expect(t, !other_ok, "another owner cannot unarchive it")
	testing.expect_value(t, store.agent.state, domain.Agent_State.Archived)

	restored, restored_ok, _ := unarchive_agent(&service, owner, "agt_1")
	testing.expect(t, restored_ok, "unarchive ok")
	testing.expect_value(t, restored.state, domain.Agent_State.Active)
	testing.expect_value(t, store.agent.state, domain.Agent_State.Active)
}
