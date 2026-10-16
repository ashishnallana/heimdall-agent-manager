package project

import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import ownership "odin_test:hub/service/ownership"
import platform "odin_test:hub/platform"
import jsonx "odin_test:lib/jsonx"

Validate_Project_Path_Command :: struct {
	type: string,
	command_id: string,
	project_id: domain.Project_ID,
	bridge_id: string,
	path: string,
	vcs_kind: string,
	repo_url: string,
}

Project_Path_Validation_Result :: struct {
	type: string,
	command_id: string,
	project_id: domain.Project_ID,
	path: string,
	ok: bool,
	validation_error: string,
	details_json: string,
}

Runtime_Command :: struct {
	bridge_id: string,
	command_id: string,
	body_json: string,
}

Bridge_Validate_Project_Path_Proc :: proc(ctx: rawptr, command: Validate_Project_Path_Command) -> (Project_Path_Validation_Result, bool, domain.Domain_Error)
Bridge_Send_Runtime_Command_Proc :: proc(ctx: rawptr, command: Runtime_Command) -> (bool, domain.Domain_Error)
Bridge_Send_Runtime_Command_Wait_Proc :: proc(ctx: rawptr, command: Runtime_Command, timeout_ms: int) -> (string, bool, domain.Domain_Error)

Bridge_Command_Sink :: struct {
	ctx: rawptr,
	validate_project_path: Bridge_Validate_Project_Path_Proc,
	send_runtime_command: Bridge_Send_Runtime_Command_Proc,
	send_runtime_command_wait: Bridge_Send_Runtime_Command_Wait_Proc,
}

Project_Service :: struct {
	projects: ^iface.Project_Repository,
	bridges: ^iface.Bridge_Repository,
	bridge_command_sink: Bridge_Command_Sink,
	clock: ^platform.Clock,
	ids: ^platform.ID_Generator,
}

Create_Project_Input :: struct {
	name, slug, description, repo_url, vcs_kind, default_path: string,
	owner_user_id: string, // ignored; authoritative owner comes from AuthContext
}
Update_Project_Input :: struct {
	name, slug, description, repo_url, vcs_kind, default_path: string,
	owner_user_id: string, // if present and different, rejected as immutable
}
Bridge_Path_Input :: struct { path: string }
Validation_Result :: struct { path: domain.Project_Bridge_Path, effective_path: string }

new_project_service :: proc(projects: ^iface.Project_Repository, bridges: ^iface.Bridge_Repository, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> Project_Service {
	return Project_Service{projects = projects, bridges = bridges, clock = clock, ids = ids}
}

new_project_service_with_command_sink :: proc(projects: ^iface.Project_Repository, bridges: ^iface.Bridge_Repository, sink: Bridge_Command_Sink, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> Project_Service {
	return Project_Service{projects = projects, bridges = bridges, bridge_command_sink = sink, clock = clock, ids = ids}
}

bridge_command_validate_project_path :: proc(sink: Bridge_Command_Sink, command: Validate_Project_Path_Command) -> (Project_Path_Validation_Result, bool, domain.Domain_Error) {
	if sink.validate_project_path == nil do return Project_Path_Validation_Result{}, false, domain.domain_error(.Bridge_Offline, "bridge command sink is not connected")
	return sink.validate_project_path(sink.ctx, command)
}

bridge_command_send_runtime :: proc(sink: Bridge_Command_Sink, command: Runtime_Command) -> (bool, domain.Domain_Error) {
	if sink.send_runtime_command == nil do return false, domain.domain_error(.Bridge_Offline, "bridge command sink is not connected")
	return sink.send_runtime_command(sink.ctx, command)
}

bridge_command_send_runtime_wait :: proc(sink: Bridge_Command_Sink, command: Runtime_Command, timeout_ms: int) -> (string, bool, domain.Domain_Error) {
	if sink.send_runtime_command_wait == nil do return "", false, domain.domain_error(.Bridge_Offline, "bridge command sink is not connected")
	return sink.send_runtime_command_wait(sink.ctx, command, timeout_ms)
}

// PTY_INPUT_REPLY_TIMEOUT_MS bounds how long a REST keystroke waits for the bridge's
// command_result. The bridge answers input synchronously, so this only matters when
// the bridge is wedged.
PTY_INPUT_REPLY_TIMEOUT_MS :: 5000

// bridge_command_send_runtime_checked sends a command and, when wait_for_result is set
// and the sink can wait, reads the bridge's command_result so a TYPED refusal surfaces to the caller
// (T10, REQ-T10-2: `vault_locked` -> domain.Vault_Locked / HTTP 423) instead of
// being dropped on the floor by a fire-and-forget send. Any other outcome keeps the
// fire-and-forget contract: delivered == true. A sink without a wait proc (older
// wiring, test doubles) falls back to the plain send.
bridge_command_send_runtime_checked :: proc(sink: Bridge_Command_Sink, command: Runtime_Command, wait_for_result: bool, timeout_ms := PTY_INPUT_REPLY_TIMEOUT_MS) -> (bool, domain.Domain_Error) {
	if !wait_for_result || sink.send_runtime_command_wait == nil do return bridge_command_send_runtime(sink, command)
	reply, ok, err := bridge_command_send_runtime_wait(sink, command, timeout_ms)
	if !ok do return false, err
	defer delete(reply)
	return bridge_reply_refusal(reply, command.bridge_id)
}

// bridge_reply_refusal maps a bridge reply's typed error (REQ-ERR-PROTO-A) to a
// domain error; ok is true when the reply carries none.
bridge_reply_refusal :: proc(reply, bridge_id: string) -> (ok: bool, err: domain.Domain_Error) {
	werr, found := contracts.wire_error_parse(reply, context.temp_allocator)
	if !found do return true, {}
	if werr.code == .Vault_Locked do return false, domain.vault_locked_error(bridge_id)
	return false, domain.domain_error_from_wire(werr)
}


create :: proc(service: ^Project_Service, auth: contracts.Auth_Context, input: Create_Project_Input) -> (domain.Project, bool, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return domain.Project{}, false, err
	if input.name == "" do return domain.Project{}, false, domain.domain_error(.Validation_Failed, "project name is required")
	if input.default_path == "" do return domain.Project{}, false, domain.domain_error(.Validation_Failed, "default_path is required")
	now := platform.clock_now(service.clock)
	slug := input.slug; if slug == "" do slug = input.name
	project := domain.Project{project_id = domain.Project_ID(platform.generate_id(service.ids, "proj_")), owner_user_id = owner, name = input.name, slug = slug, description = input.description, repo_url = input.repo_url, vcs_kind = input.vcs_kind, default_path = input.default_path, created_at = now, updated_at = now}
	return iface.project_save(service.projects, project)
}

get :: proc(service: ^Project_Service, auth: contracts.Auth_Context, project_id: domain.Project_ID) -> (domain.Project, bool, domain.Domain_Error) {
	project, ok, err := iface.project_get(service.projects, project_id)
	if !ok do return domain.Project{}, false, err
	if owner_ok, owner_err := ownership.require_owner(auth, project.owner_user_id); !owner_ok do return domain.Project{}, false, owner_err
	return project, true, domain.Domain_Error{}
}

list :: proc(service: ^Project_Service, auth: contracts.Auth_Context, limit: int = 50, cursor: string = "") -> ([]domain.Project, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, err
	return iface.project_list_by_owner(service.projects, owner, limit, cursor)
}

update :: proc(service: ^Project_Service, auth: contracts.Auth_Context, project_id: domain.Project_ID, input: Update_Project_Input) -> (domain.Project, bool, domain.Domain_Error) {
	project, ok, err := get(service, auth, project_id)
	if !ok do return domain.Project{}, false, err
	if mutation_ok, mutation_err := ownership.reject_owner_mutation(project.owner_user_id, domain.User_ID(input.owner_user_id)); !mutation_ok do return domain.Project{}, false, mutation_err
	if input.name != "" do project.name = input.name
	if input.slug != "" do project.slug = input.slug
	if input.description != "" do project.description = input.description
	if input.repo_url != "" do project.repo_url = input.repo_url
	if input.vcs_kind != "" do project.vcs_kind = input.vcs_kind
	if input.default_path != "" do project.default_path = input.default_path
	project.updated_at = platform.clock_now(service.clock)
	return iface.project_update(service.projects, project)
}

// archive_project soft-archives a project (reversible), mirroring archive_agent:
// ownership is enforced via get(), state flips to Archived, and the row is
// persisted (never removed). No cascade to chains/tasks/instances.
archive_project :: proc(service: ^Project_Service, auth: contracts.Auth_Context, project_id: domain.Project_ID) -> (domain.Project, bool, domain.Domain_Error) {
	project, ok, err := get(service, auth, project_id)
	if !ok do return domain.Project{}, false, err
	project.state = .Archived
	project.updated_at = platform.clock_now(service.clock)
	return iface.project_update(service.projects, project)
}

set_bridge_path :: proc(service: ^Project_Service, auth: contracts.Auth_Context, project_id: domain.Project_ID, bridge_id: string, input: Bridge_Path_Input) -> (domain.Project_Bridge_Path, bool, domain.Domain_Error) {
	project, ok, err := get(service, auth, project_id)
	if !ok do return domain.Project_Bridge_Path{}, false, err
	bridge, bridge_ok, bridge_err := iface.bridge_get_bridge(service.bridges, bridge_id)
	if !bridge_ok do return domain.Project_Bridge_Path{}, false, bridge_err
	if bridge.owner_user_id != project.owner_user_id do return domain.Project_Bridge_Path{}, false, domain.domain_error(.Not_Found, "bridge not found")
	if input.path == "" do return domain.Project_Bridge_Path{}, false, domain.domain_error(.Validation_Failed, "path is required")
	now := platform.clock_now(service.clock)
	existing, existing_ok, _ := iface.project_get_bridge_path(service.projects, project_id, bridge_id)
	created_at := now; if existing_ok do created_at = existing.created_at
	path := domain.Project_Bridge_Path{project_id = project.project_id, bridge_id = bridge_id, owner_user_id = project.owner_user_id, path = input.path, is_validated = false, created_at = created_at, updated_at = now}
	return iface.project_save_bridge_path(service.projects, path)
}

delete_bridge_path :: proc(service: ^Project_Service, auth: contracts.Auth_Context, project_id: domain.Project_ID, bridge_id: string) -> (bool, domain.Domain_Error) {
	project, ok, err := get(service, auth, project_id)
	if !ok do return false, err
	bridge, bridge_ok, bridge_err := iface.bridge_get_bridge(service.bridges, bridge_id)
	if !bridge_ok do return false, bridge_err
	if bridge.owner_user_id != project.owner_user_id do return false, domain.domain_error(.Not_Found, "bridge not found")
	return iface.project_delete_bridge_path(service.projects, project.project_id, bridge_id, project.owner_user_id)
}

list_bridge_paths :: proc(service: ^Project_Service, auth: contracts.Auth_Context, project_id: domain.Project_ID) -> ([]domain.Project_Bridge_Path, domain.Domain_Error) {
	project, ok, err := get(service, auth, project_id)
	if !ok do return nil, err
	return iface.project_list_bridge_paths(service.projects, project.project_id, project.owner_user_id)
}

resolve_effective_path :: proc(service: ^Project_Service, auth: contracts.Auth_Context, project_id: domain.Project_ID, bridge_id: string) -> (string, bool, domain.Domain_Error) {
	project, ok, err := get(service, auth, project_id)
	if !ok do return "", false, err
	path, path_ok, _ := iface.project_get_bridge_path(service.projects, project.project_id, bridge_id)
	if path_ok do return path.path, true, domain.Domain_Error{}
	return project.default_path, true, domain.Domain_Error{}
}

Fs_Target :: struct { bridge_id: string, root_path: string }

// resolve_fs_target maps a project (owned by the caller) to the (bridge_id, root)
// pair the FS browser should operate against. When bridge_hint is supplied it is
// honored (must be a configured path for this project); otherwise the project's
// single configured bridge path is used. Ambiguous (multiple paths, no hint) or
// unconfigured projects are rejected so a browse never silently targets the wrong
// machine. Ownership is enforced via get().
resolve_fs_target :: proc(service: ^Project_Service, auth: contracts.Auth_Context, project_id: domain.Project_ID, bridge_hint: string = "") -> (Fs_Target, bool, domain.Domain_Error) {
	project, ok, err := get(service, auth, project_id)
	if !ok do return Fs_Target{}, false, err
	paths, list_err := iface.project_list_bridge_paths(service.projects, project.project_id, project.owner_user_id)
	if list_err.code != .None do return Fs_Target{}, false, list_err
	if bridge_hint != "" {
		// Prefer an explicit per-bridge path override for this bridge.
		for p in paths {
			if p.bridge_id == bridge_hint && strings.trim_space(p.path) != "" {
				return Fs_Target{bridge_id = p.bridge_id, root_path = p.path}, true, domain.Domain_Error{}
			}
		}
		// No override (or an empty one) for this bridge: fall back to the project's
		// default_path so the file browser still works on a bridge that just uses the
		// default checkout location. The bridge re-sandboxes to this root; if the dir
		// doesn't exist there the listing simply reports path_not_found.
		if strings.trim_space(project.default_path) != "" {
			return Fs_Target{bridge_id = bridge_hint, root_path = project.default_path}, true, domain.Domain_Error{}
		}
		return Fs_Target{}, false, domain.domain_error(.Validation_Failed, "project has no path configured on this bridge and no default_path")
	}
	configured := 0
	chosen := domain.Project_Bridge_Path{}
	for p in paths {
		if strings.trim_space(p.path) == "" do continue
		configured += 1
		chosen = p
	}
	if configured == 0 do return Fs_Target{}, false, domain.domain_error(.Validation_Failed, "project has no bridge path configured")
	if configured > 1 do return Fs_Target{}, false, domain.domain_error(.Validation_Failed, "project is configured on multiple bridges; specify bridge_id")
	return Fs_Target{bridge_id = chosen.bridge_id, root_path = chosen.path}, true, domain.Domain_Error{}
}

validate_bridge_path :: proc(service: ^Project_Service, auth: contracts.Auth_Context, project_id: domain.Project_ID, bridge_id: string) -> (Validation_Result, bool, domain.Domain_Error) {
	project, ok, err := get(service, auth, project_id)
	if !ok do return Validation_Result{}, false, err
	bridge, bridge_ok, bridge_err := iface.bridge_get_bridge(service.bridges, bridge_id)
	if !bridge_ok do return Validation_Result{}, false, bridge_err
	if bridge.owner_user_id != project.owner_user_id do return Validation_Result{}, false, domain.domain_error(.Not_Found, "bridge not found")
	if bridge.status == .Revoked do return Validation_Result{}, false, domain.domain_error(.Bridge_Revoked, "bridge is revoked")
	if bridge.status != .Online do return Validation_Result{}, false, domain.domain_error(.Bridge_Offline, "bridge is offline")
	effective, effective_ok, effective_err := resolve_effective_path(service, auth, project_id, bridge_id)
	if !effective_ok do return Validation_Result{}, false, effective_err
	command_id := strings.concatenate({platform.generate_id(service.ids, "cmd_"), "_", string(project.project_id), "_", bridge.bridge_id})
	command := Validate_Project_Path_Command{type = "validate_project_path", command_id = command_id, project_id = project.project_id, bridge_id = bridge.bridge_id, path = effective, vcs_kind = project.vcs_kind, repo_url = project.repo_url}
	result, result_ok, result_err := bridge_command_validate_project_path(service.bridge_command_sink, command)
	if !result_ok do return Validation_Result{}, false, result_err
	now := platform.clock_now(service.clock)
	path, path_ok, _ := iface.project_get_bridge_path(service.projects, project.project_id, bridge_id)
	if !path_ok { path = domain.Project_Bridge_Path{project_id = project.project_id, bridge_id = bridge_id, owner_user_id = project.owner_user_id, path = effective, created_at = now} }
	path.is_validated = result.ok
	path.last_validated_at = now
	path.validation_error = result.validation_error
	path.validation_details_json = result.details_json
	path.updated_at = now
	saved, saved_ok, save_err := iface.project_save_bridge_path(service.projects, path)
	if !saved_ok do return Validation_Result{}, false, save_err
	return Validation_Result{path = saved, effective_path = effective}, true, domain.Domain_Error{}
}
