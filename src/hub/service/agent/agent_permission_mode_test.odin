package agent

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// REQ-EXT-PERM-2: agents.permission_mode is created as 'yolo', editable to 'ask',
// validated, and carried to the bridge in every launch payload.

@(private = "file")
Permission_Agent_Store :: struct {
	agent: domain.Agent,
	has:   bool,
}

@(private = "file")
permission_store_save :: proc(ctx: rawptr, a: domain.Agent) -> (domain.Agent, bool, domain.Domain_Error) {
	store := cast(^Permission_Agent_Store)ctx
	store.agent = a
	store.has = true
	return a, true, {}
}

@(private = "file")
permission_store_get :: proc(ctx: rawptr, agent_id: string) -> (domain.Agent, bool, domain.Domain_Error) {
	store := cast(^Permission_Agent_Store)ctx
	if !store.has || store.agent.agent_id != agent_id do return {}, false, domain.domain_error(.Not_Found, "agent not found")
	return store.agent, true, {}
}

@(private = "file")
permission_service :: proc(store: ^Permission_Agent_Store, repo: ^iface.Agent_Repository, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> Agent_Service {
	repo^ = iface.Agent_Repository{ctx = store, save = permission_store_save, get = permission_store_get}
	clock^ = platform.real_clock()
	ids^ = platform.real_id_generator()
	return new_agent_service(repo, nil, clock, ids)
}

@(test)
test_agent_permission_mode_defaults_to_yolo_and_updates_to_ask :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	store: Permission_Agent_Store
	repo: iface.Agent_Repository
	clock: platform.Clock
	ids: platform.ID_Generator
	service := permission_service(&store, &repo, &clock, &ids)
	auth := contracts.Auth_Context{user_id = "user_1"}

	created, ok, _ := create_agent(&service, auth, Create_Agent_Input{name = "worker"})
	testing.expect_value(t, ok, true)
	testing.expect_value(t, created.permission_mode, domain.AGENT_PERMISSION_MODE_YOLO)

	// An update that does not mention permission_mode keeps it.
	renamed, rok, _ := update_agent(&service, auth, created.agent_id, Create_Agent_Input{name = "worker-2"})
	testing.expect_value(t, rok, true)
	testing.expect_value(t, renamed.permission_mode, domain.AGENT_PERMISSION_MODE_YOLO)

	asked, aok, _ := update_agent(&service, auth, created.agent_id, Create_Agent_Input{permission_mode = "ask"})
	testing.expect_value(t, aok, true)
	testing.expect_value(t, asked.permission_mode, domain.AGENT_PERMISSION_MODE_ASK)
	testing.expect_value(t, store.agent.permission_mode, domain.AGENT_PERMISSION_MODE_ASK)

	back, bok, _ := update_agent(&service, auth, created.agent_id, Create_Agent_Input{permission_mode = "yolo"})
	testing.expect_value(t, bok, true)
	testing.expect_value(t, back.permission_mode, domain.AGENT_PERMISSION_MODE_YOLO)
}

@(test)
test_agent_permission_mode_rejects_unknown_values :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	store: Permission_Agent_Store
	repo: iface.Agent_Repository
	clock: platform.Clock
	ids: platform.ID_Generator
	service := permission_service(&store, &repo, &clock, &ids)
	auth := contracts.Auth_Context{user_id = "user_1"}

	_, cok, cerr := create_agent(&service, auth, Create_Agent_Input{name = "worker", permission_mode = "never"})
	testing.expect_value(t, cok, false)
	testing.expect_value(t, cerr.code, domain.Error_Code.Validation_Failed)

	created, _, _ := create_agent(&service, auth, Create_Agent_Input{name = "worker", permission_mode = "ask"})
	testing.expect_value(t, created.permission_mode, domain.AGENT_PERMISSION_MODE_ASK)
	_, uok, uerr := update_agent(&service, auth, created.agent_id, Create_Agent_Input{permission_mode = "YOLO"})
	testing.expect_value(t, uok, false)
	testing.expect_value(t, uerr.code, domain.Error_Code.Validation_Failed)
	testing.expect_value(t, store.agent.permission_mode, domain.AGENT_PERMISSION_MODE_ASK)
}

@(test)
test_launch_payloads_carry_agent_permission_mode :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	store: Permission_Agent_Store
	repo: iface.Agent_Repository
	clock: platform.Clock
	ids: platform.ID_Generator
	service := permission_service(&store, &repo, &clock, &ids)
	auth := contracts.Auth_Context{user_id = "user_1"}
	created, _, _ := create_agent(&service, auth, Create_Agent_Input{name = "worker", permission_mode = "ask"})

	inst := domain.Agent_Instance{agent_instance_id = "inst_1", agent_id = created.agent_id, provider = "claude", model = "opus"}
	launch := launch_command_json_full(&service, "cmd_1", inst)
	testing.expect(t, strings.contains(launch, `"permission_mode":"ask"`), "launch_agent must carry the agent's ask mode")

	// Without a service (no agent lookup) the launch stays yolo.
	bare := launch_command_json("cmd_2", inst)
	testing.expect(t, strings.contains(bare, `"permission_mode":"yolo"`), "launch_agent without an agent lookup defaults to yolo")

	run := []Wake_Agent_Run_Entry{
		{agent_instance_id = "inst_1", task_id = "task_1", role = "worker", permission_mode = "ask"},
		{agent_instance_id = "inst_2", task_id = "task_2", role = "worker"},
	}
	wake := wake_agent_command_json("cmd_3", "chain_1", run, nil)
	testing.expect_value(t, strings.count(wake, `"permission_mode":"ask"`), 1)
	testing.expect_value(t, strings.count(wake, `"permission_mode"`), 1)
}
