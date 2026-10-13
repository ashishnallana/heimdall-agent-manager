package http

import "core:strings"
import "core:testing"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import agent "odin_test:hub/service/agent"
import bridge_runtime "odin_test:hub/service/bridge_runtime"
import project "odin_test:hub/service/project"
import platform "odin_test:hub/platform"

Registry_Durable_Fixture :: struct { saves: int }
registry_durable_get :: proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	return domain.Agent_Instance{
		agent_instance_id = strings.clone(id), bridge_id = strings.clone("bridge"),
		owner_user_id = domain.User_ID(strings.clone("customer")),
		runtime_status = strings.clone("stopped"), activity_status = strings.clone("idle"),
		last_applied_seq = 10,
	}, true, {}
}
registry_durable_save :: proc(ctx: rawptr, instance: domain.Agent_Instance) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	(^Registry_Durable_Fixture)(ctx).saves += 1
	return instance, true, {}
}
registry_durable_now :: proc(ctx: rawptr) -> string { return "2026-10-10T00:00:00Z" }

@(test)
test_runtime_expired_tombstone_cannot_override_durable_terminal_sequence :: proc(t: ^testing.T) {
	registry := new(project.Bridge_Runtime_Registry)
	defer { bridge_runtime.runtime_command_cache_destroy(registry); free(registry) }
	registry.limits.terminal_retention = time.Second
	hello, _, _ := bridge_runtime.runtime_accept_hello(registry, "bridge", 1, "", "customer")
	_, _, _ = project.bridge_runtime_instance_apply(registry, "bridge", hello.generation, "agent", "customer", "stopped", "idle", 10)
	_ = project.bridge_runtime_registry_sweep(registry, time.now()._nsec + i64(2 * time.Second))
	fixture: Registry_Durable_Fixture
	repo := iface.Agent_Repository{ctx = rawptr(&fixture), get_instance = registry_durable_get, save_instance = registry_durable_save}
	clock := platform.Clock{now = registry_durable_now}
	service := agent.Agent_Service{agents = &repo, clock = &clock}
	handlers := Bridge_Handlers{agents = &service, bridge_runtime_registry = registry}
	_, applied, err := bridge_apply_validated_status(&handlers, "bridge", hello.generation, "agent", 9, "running", "idle")
	testing.expect(t, !applied && err.code == .None)
	testing.expect_value(t, fixture.saves, 0)
	testing.expect_value(t, registry.active_instances, 0)
	fresh, _, _ := bridge_runtime.runtime_accept_hello(registry, "bridge", 1, "", "customer")
	_, applied, err = bridge_apply_validated_status(&handlers, "bridge", hello.generation, "agent", 11, "running", "idle")
	testing.expect(t, !applied && err.code == .Bridge_Offline)
	testing.expect(t, fresh.generation != hello.generation)
	testing.expect_value(t, fixture.saves, 0)
}
