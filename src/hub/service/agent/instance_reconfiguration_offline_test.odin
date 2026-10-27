package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import project_service "odin_test:hub/service/project"

// REQ-RELOC-OFFLINE-1 / REQ-PROJ-FALLBACK-1: moving a stopped/unreachable
// instance away from a disconnected source Bridge commits the new canonical
// Bridge and launches immediately. A missing per-Bridge project override uses
// default_path without turning path validation into a launch prerequisite.

@(private = "file")
Offline_Reconfiguration_Sink :: struct {
	commands:         [dynamic]project_service.Runtime_Command,
	validation_calls: int,
	validation_ok:    bool,
}

@(private = "file")
offline_reconfiguration_validate :: proc(ctx: rawptr, command: project_service.Validate_Project_Path_Command) -> (project_service.Project_Path_Validation_Result, bool, domain.Domain_Error) {
	sink := (^Offline_Reconfiguration_Sink)(ctx)
	sink.validation_calls += 1
	return project_service.Project_Path_Validation_Result{command_id = command.command_id, project_id = command.project_id, path = command.path, ok = sink.validation_ok}, true, {}
}

@(private = "file")
offline_reconfiguration_send :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	sink := (^Offline_Reconfiguration_Sink)(ctx)
	append(&sink.commands, command)
	return true, {}
}

@(private = "file")
Offline_Reconfiguration_Harness :: struct {
	path:          string,
	conn:          sqlite.Conn,
	agent_impl:    sqlite.Agent_Repo_SQLite,
	bridge_impl:   sqlite.Bridge_Repo_SQLite,
	project_impl:  sqlite.Project_Repo_SQLite,
	content_impl:  sqlite.Content_Repo_SQLite,
	provider_impl: sqlite.Provider_Repo_SQLite,
	agents:        iface.Agent_Repository,
	bridges:       iface.Bridge_Repository,
	projects:      iface.Project_Repository,
	content:       iface.Content_Repository,
	providers:     iface.Provider_Repository,
	registry:      project_service.Bridge_Runtime_Registry,
	sink:          Offline_Reconfiguration_Sink,
	clock:         platform.Clock,
	ids:           platform.ID_Generator,
	service:       Agent_Service,
}

@(private = "file")
OFFLINE_RECONFIG_OWNER :: "user_offline_reconfig"
@(private = "file")
OFFLINE_RECONFIG_AGENT :: "agt_offline_reconfig"
@(private = "file")
OFFLINE_RECONFIG_INSTANCE :: "inst_offline_reconfig"
@(private = "file")
OFFLINE_RECONFIG_SOURCE :: "brg_offline_source"
@(private = "file")
OFFLINE_RECONFIG_DESTINATION :: "brg_online_destination"
@(private = "file")
OFFLINE_RECONFIG_PROJECT :: domain.Project_ID("proj_offline_reconfig")
@(private = "file")
OFFLINE_RECONFIG_DEFAULT_PATH :: "/workspace/default-project"
@(private = "file")
OFFLINE_RECONFIG_PROVIDER :: "codex"
@(private = "file")
OFFLINE_RECONFIG_MODEL :: "gpt-6.1-sol"

@(private = "file")
offline_reconfiguration_open :: proc(t: ^testing.T, h: ^Offline_Reconfiguration_Harness, name: string, with_override := false) -> bool {
	h.path = fmt.aprintf("%s/.cache/heimdall-tests/%s.db", os.get_env("HOME", context.temp_allocator), name)
	os.remove(h.path)
	conn, opened, open_err := sqlite.open(h.path)
	if !testing.expectf(t, opened, "open db: %s", open_err.message) do return false
	h.conn = conn
	if migrated, migration_err := sqlite.run_migrations(&h.conn); !testing.expectf(t, migrated, "migrations: %s", migration_err.message) do return false
	h.agents = sqlite.new_agent_repository(&h.agent_impl, &h.conn)
	h.bridges = sqlite.new_bridge_repository(&h.bridge_impl, &h.conn)
	h.projects = sqlite.new_project_repository(&h.project_impl, &h.conn)
	h.content = sqlite.new_content_repository(&h.content_impl, &h.conn)
	h.providers = sqlite.new_provider_repository(&h.provider_impl, &h.conn)
	h.clock = platform.real_clock()
	h.ids = platform.real_id_generator()
	sink := project_service.Bridge_Command_Sink{ctx = &h.sink, validate_project_path = offline_reconfiguration_validate, send_runtime_command = offline_reconfiguration_send}
	h.service = new_agent_service_with_runtime(&h.agents, &h.bridges, &h.projects, &h.content, nil, sink, &h.registry, &h.clock, &h.ids)
	h.service.providers = &h.providers

	now := "2026-10-27T10:00:00Z"
	feature_json := `{"features":["instance_reconfiguration_v1"]}`
	for bridge in ([]domain.Bridge{
		{bridge_id = OFFLINE_RECONFIG_SOURCE, owner_user_id = OFFLINE_RECONFIG_OWNER, label = "Offline source", machine_hostname = "offline-source", machine_os = "darwin", machine_arch = "amd64", capabilities_json = feature_json, hub_url = "https://hub.example", status = .Offline, bridge_token_hash = "source_hash", created_at = now, updated_at = now, last_seen_at = now},
		{bridge_id = OFFLINE_RECONFIG_DESTINATION, owner_user_id = OFFLINE_RECONFIG_OWNER, label = "Online destination", machine_hostname = "online-destination", machine_os = "darwin", machine_arch = "arm64", capabilities_json = feature_json, hub_url = "https://hub.example", status = .Online, bridge_token_hash = "destination_hash", created_at = now, updated_at = now, last_seen_at = now},
	}) {
		_, saved, save_err := iface.bridge_save_bridge(&h.bridges, bridge)
		if !testing.expect(t, saved, save_err.message) do return false
	}
	_, _, live := project_service.bridge_runtime_registry_accept_live(&h.registry, OFFLINE_RECONFIG_DESTINATION, false, "", OFFLINE_RECONFIG_OWNER)
	if !testing.expect(t, live, "destination Bridge is live") do return false

	_, saved, save_err := iface.agent_save(&h.agents, domain.Agent{agent_id = OFFLINE_RECONFIG_AGENT, owner_user_id = OFFLINE_RECONFIG_OWNER, name = "Worker", slug = "worker", template_id = domain.TEMPLATE_EMPTY_ID, state = .Active, created_at = now, updated_at = now})
	if !testing.expect(t, saved, save_err.message) do return false
	_, saved, save_err = iface.project_save(&h.projects, domain.Project{project_id = OFFLINE_RECONFIG_PROJECT, owner_user_id = OFFLINE_RECONFIG_OWNER, name = "Project", slug = "project", default_path = OFFLINE_RECONFIG_DEFAULT_PATH, state = .Active, created_at = now, updated_at = now})
	if !testing.expect(t, saved, save_err.message) do return false
	if with_override {
		_, saved, save_err = iface.project_save_bridge_path(&h.projects, domain.Project_Bridge_Path{project_id = OFFLINE_RECONFIG_PROJECT, bridge_id = OFFLINE_RECONFIG_DESTINATION, owner_user_id = OFFLINE_RECONFIG_OWNER, path = "/workspace/explicit-project", created_at = now, updated_at = now})
		if !testing.expect(t, saved, save_err.message) do return false
	}
	_, saved, save_err = iface.agent_save_instance(&h.agents, domain.Agent_Instance{agent_instance_id = OFFLINE_RECONFIG_INSTANCE, owner_user_id = OFFLINE_RECONFIG_OWNER, agent_id = OFFLINE_RECONFIG_AGENT, bridge_id = OFFLINE_RECONFIG_SOURCE, provider = OFFLINE_RECONFIG_PROVIDER, model = OFFLINE_RECONFIG_MODEL, project_id = OFFLINE_RECONFIG_PROJECT, project_path = "/workspace/old-project", conversation_id = "chat_offline_reconfig", runtime_status = "unreachable", startup_status = "stopped", created_at = now, updated_at = now})
	if !testing.expect(t, saved, save_err.message) do return false
	_, saved, save_err = iface.content_save_conversation(&h.content, domain.Chat_Conversation{conversation_id = "chat_offline_reconfig", owner_user_id = OFFLINE_RECONFIG_OWNER, agent_id = OFFLINE_RECONFIG_AGENT, agent_instance_id = OFFLINE_RECONFIG_INSTANCE, project_id = OFFLINE_RECONFIG_PROJECT, title = "Worker", created_at = now, updated_at = now})
	if !testing.expect(t, saved, save_err.message) do return false
	_, status_err := iface.bridge_provider_status_upsert(&h.providers, domain.Bridge_Provider_Status{bridge_id = OFFLINE_RECONFIG_DESTINATION, provider = OFFLINE_RECONFIG_PROVIDER, binary_path = "/usr/bin/codex", state = "present", checked_at = now})
	if !testing.expect(t, status_err.code == .None, status_err.message) do return false
	_, setting_err := iface.bridge_provider_setting_upsert(&h.providers, domain.Bridge_Provider_Setting{bridge_id = OFFLINE_RECONFIG_DESTINATION, provider = OFFLINE_RECONFIG_PROVIDER, enabled = true, updated_at = now})
	return testing.expect(t, setting_err.code == .None, setting_err.message)
}

@(private = "file")
offline_reconfiguration_close :: proc(h: ^Offline_Reconfiguration_Harness) {
	project_service.bridge_runtime_registry_destroy(&h.registry)
	sqlite.close(&h.conn)
	os.remove(h.path)
}

@(private = "file")
offline_reconfiguration_input :: proc(key: string) -> Reconfigure_Operation_Input {
	return {bridge_id = OFFLINE_RECONFIG_DESTINATION, project_id = string(OFFLINE_RECONFIG_PROJECT), provider = OFFLINE_RECONFIG_PROVIDER, model = OFFLINE_RECONFIG_MODEL, idempotency_key = key, expected_revision = 0}
}

@(test)
test_reconfiguration_moves_from_offline_source_and_launches_destination :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	h: Offline_Reconfiguration_Harness
	if !offline_reconfiguration_open(t, &h, "offline_reconfiguration_move") { offline_reconfiguration_close(&h); return }
	defer offline_reconfiguration_close(&h)

	op, accepted, err := begin_instance_reconfiguration(&h.service, contracts.Auth_Context{kind = .Session, user_id = OFFLINE_RECONFIG_OWNER}, OFFLINE_RECONFIG_INSTANCE, offline_reconfiguration_input("offline-move"))
	if !testing.expect(t, accepted, err.message) do return
	defer domain.instance_reconfiguration_destroy(&op)
	testing.expect_value(t, op.phase, domain.Instance_Reconfiguration_Phase.Launching)
	testing.expect(t, op.source_stopped && op.destination_committed, "offline source is durably fenced before destination commit")
	testing.expect_value(t, h.sink.validation_calls, 0)
	testing.expect_value(t, len(h.sink.commands), 1)
	if len(h.sink.commands) == 1 {
		testing.expect_value(t, h.sink.commands[0].bridge_id, OFFLINE_RECONFIG_DESTINATION)
		testing.expect(t, strings.contains(h.sink.commands[0].body_json, `"type":"launch_agent"`), h.sink.commands[0].body_json)
		testing.expect(t, strings.contains(h.sink.commands[0].body_json, `"project_path":"/workspace/default-project"`), h.sink.commands[0].body_json)
		testing.expect(t, !strings.contains(h.sink.commands[0].body_json, `"type":"stop_agent"`), h.sink.commands[0].body_json)
	}
	inst, found, load_err := iface.agent_get_instance(&h.agents, OFFLINE_RECONFIG_INSTANCE)
	if !testing.expect(t, found, load_err.message) do return
	defer domain.agent_instance_destroy(&inst)
	testing.expect_value(t, inst.bridge_id, OFFLINE_RECONFIG_DESTINATION)
	testing.expect_value(t, inst.project_path, OFFLINE_RECONFIG_DEFAULT_PATH)
	superseded := detect_superseded_instances(&h.service, OFFLINE_RECONFIG_SOURCE, []string{OFFLINE_RECONFIG_INSTANCE})
	defer { for id in superseded do delete(id); delete(superseded) }
	testing.expect_value(t, len(superseded), 1)
}

@(test)
test_reconfiguration_keeps_explicit_destination_path_validation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	h: Offline_Reconfiguration_Harness
	if !offline_reconfiguration_open(t, &h, "offline_reconfiguration_explicit_path", with_override = true) { offline_reconfiguration_close(&h); return }
	defer offline_reconfiguration_close(&h)
	h.sink.validation_ok = false

	_, accepted, err := begin_instance_reconfiguration(&h.service, contracts.Auth_Context{kind = .Session, user_id = OFFLINE_RECONFIG_OWNER}, OFFLINE_RECONFIG_INSTANCE, offline_reconfiguration_input("explicit-path"))
	testing.expect(t, !accepted && err.code == .Validation_Failed, "an invalid explicit per-Bridge path still blocks relocation")
	testing.expect_value(t, h.sink.validation_calls, 1)
	testing.expect_value(t, len(h.sink.commands), 0)
}
