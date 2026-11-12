package agent

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// One stored agent plus a settable usage, so the delete rules run without sqlite.
Delete_Fake_Store :: struct {
	agent:   domain.Agent,
	present: bool,
	usage:   domain.Agent_Usage,
	// usage_after_check simulates a reference landing between the service's own
	// usage check and the guarded DELETE.
	race:    bool,
}

delete_fake_get :: proc(ctx: rawptr, agent_id: string) -> (domain.Agent, bool, domain.Domain_Error) {
	store := cast(^Delete_Fake_Store)ctx
	if !store.present || store.agent.agent_id != agent_id do return domain.Agent{}, false, domain.domain_error(.Not_Found, "agent not found")
	return store.agent, true, {}
}

delete_fake_usage :: proc(ctx: rawptr, agent_id: string) -> (domain.Agent_Usage, domain.Domain_Error) {
	return (cast(^Delete_Fake_Store)ctx).usage, {}
}

delete_fake_delete_unused :: proc(ctx: rawptr, agent_id: string, owner: domain.User_ID) -> (bool, domain.Domain_Error) {
	store := cast(^Delete_Fake_Store)ctx
	if store.race {
		store.usage.instances = 1
		return false, {}
	}
	if domain.agent_usage_total(store.usage) > 0 || owner != store.agent.owner_user_id do return false, {}
	store.present = false
	return true, {}
}

@(private = "file")
delete_fixture :: proc(store: ^Delete_Fake_Store) -> (iface.Agent_Repository, platform.Clock, platform.ID_Generator) {
	repo := iface.Agent_Repository{ctx = store, get = delete_fake_get, usage = delete_fake_usage, delete_unused = delete_fake_delete_unused}
	return repo, platform.real_clock(), platform.real_id_generator()
}

@(test)
test_delete_agent_refuses_an_agent_in_use_with_a_409_naming_what_uses_it :: proc(t: ^testing.T) {
	store := Delete_Fake_Store{agent = domain.Agent{agent_id = "agt_1", owner_user_id = "user_1"}, present = true, usage = domain.Agent_Usage{instances = 2, chains = 1}}
	repo, clock, ids := delete_fixture(&store)
	service := new_agent_service(&repo, nil, &clock, &ids)

	_, deleted, err := delete_agent(&service, contracts.Auth_Context{user_id = "user_1"}, "agt_1")
	testing.expect(t, !deleted, "in-use agent is not deleted")
	testing.expect_value(t, err.code, domain.Error_Code.Conflict)
	testing.expect(t, strings.contains(err.message, "2 instances, 1 chain"), err.message)
	testing.expect(t, strings.contains(err.details_json, `"reason":"agent_in_use"`), err.details_json)
	testing.expect(t, strings.contains(err.details_json, `"instances":2`), err.details_json)
	testing.expect(t, store.present, "agent still stored")
}

@(test)
test_delete_agent_reports_a_reference_that_lands_after_the_check :: proc(t: ^testing.T) {
	store := Delete_Fake_Store{agent = domain.Agent{agent_id = "agt_1", owner_user_id = "user_1"}, present = true, race = true}
	repo, clock, ids := delete_fixture(&store)
	service := new_agent_service(&repo, nil, &clock, &ids)

	_, deleted, err := delete_agent(&service, contracts.Auth_Context{user_id = "user_1"}, "agt_1")
	testing.expect(t, !deleted, "a racing launch wins")
	testing.expect_value(t, err.code, domain.Error_Code.Conflict)
	testing.expect(t, strings.contains(err.message, "1 instance"), err.message)
}

@(test)
test_delete_agent_removes_an_unused_agent_for_its_owner_only :: proc(t: ^testing.T) {
	store := Delete_Fake_Store{agent = domain.Agent{agent_id = "agt_1", owner_user_id = "user_1"}, present = true}
	repo, clock, ids := delete_fixture(&store)
	service := new_agent_service(&repo, nil, &clock, &ids)

	_, other_ok, _ := delete_agent(&service, contracts.Auth_Context{user_id = "user_2"}, "agt_1")
	testing.expect(t, !other_ok, "another owner cannot delete it")
	testing.expect(t, store.present, "still stored after the refused call")

	usage, usage_ok, _ := get_agent_usage(&service, contracts.Auth_Context{user_id = "user_1"}, "agt_1")
	testing.expect(t, usage_ok, "owner can read usage")
	testing.expect_value(t, domain.agent_usage_total(usage), 0)

	deleted_agent, deleted, err := delete_agent(&service, contracts.Auth_Context{user_id = "user_1"}, "agt_1")
	testing.expect(t, deleted, err.message)
	testing.expect_value(t, deleted_agent.agent_id, "agt_1")
	testing.expect(t, !store.present, "agent removed")
}

@(test)
test_agent_usage_summary_lists_non_zero_counts_in_order :: proc(t: ^testing.T) {
	testing.expect_value(t, agent_usage_summary(domain.Agent_Usage{}), "")
	testing.expect_value(t, agent_usage_summary(domain.Agent_Usage{tasks = 3, instances = 1, memories = 1}), "1 instance, 3 tasks, 1 memory")
}
