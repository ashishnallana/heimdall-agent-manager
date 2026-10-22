package agent

import "core:encoding/json"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import project_service "odin_test:hub/service/project"
import jsonx "odin_test:lib/jsonx"

Reconfigure_Operation_Input :: struct {
	bridge_id, project_id, provider, model, idempotency_key: string,
	expected_revision: int,
}

instance_assertion_token :: proc(inst: domain.Agent_Instance) -> string {
	if inst.launch_epoch == "" do return strings.concatenate({"hit_", inst.agent_instance_id})
	return strings.concatenate({"hit_", inst.agent_instance_id, "~", inst.launch_epoch})
}
instance_id_from_assertion :: proc(token: string) -> string {
	if !strings.has_prefix(token, "hit_") do return ""
	value := token[len("hit_"):]
	if separator := strings.index(value, "~"); separator >= 0 do return value[:separator]
	return value
}

reconfiguration_bridge_supported :: proc(bridge: domain.Bridge) -> bool {
	features := jsonx.extract_string_array(bridge.capabilities_json, "features")
	defer { for feature in features do delete(feature); delete(features) }
	for feature in features do if feature == "instance_reconfiguration_v1" do return true
	return false
}

configuration_snapshot :: proc(service: ^Agent_Service, inst: domain.Agent_Instance) -> domain.Instance_Configuration {
	config := domain.Instance_Configuration{bridge_id = inst.bridge_id, project_id = string(inst.project_id), project_path = inst.project_path, provider = inst.provider, model = inst.model}
	if bridge, found, _ := iface.bridge_get_bridge(service.bridges, inst.bridge_id); found {
		config.bridge_label = bridge.label
		if config.bridge_label == "" do config.bridge_label = bridge.machine_hostname
	}
	if inst.project_id != "" && service.projects != nil {
		if project, found, _ := iface.project_get(service.projects, inst.project_id); found do config.project_label = project.name
	}
	return config
}

reconfiguration_require_idle :: proc(service: ^Agent_Service, instance_id: string) -> (bool, domain.Domain_Error) {
	// Legacy fake repositories do not implement this additive surface.
	if service.agents == nil || service.agents.reconfiguration_list == nil do return true, {}
	ops, err := iface.instance_reconfiguration_list(service.agents, "", instance_id, true)
	defer { for &op in ops do domain.instance_reconfiguration_destroy(&op); delete(ops) }
	if err.code != .None do return false, err
	if len(ops) > 0 do return false, domain.domain_error(.Conflict, "instance configuration is changing or requires recovery; messages and runtime actions are temporarily disabled")
	return true, {}
}

begin_instance_reconfiguration :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id: string, input: Reconfigure_Operation_Input) -> (domain.Instance_Reconfiguration, bool, domain.Domain_Error) {
	inst, found, err := get_instance(service, auth, instance_id)
	if !found do return {}, false, err
	defer domain.agent_instance_destroy(&inst)
	if strings.trim_space(input.idempotency_key) == "" || len(input.idempotency_key) > 128 || input.bridge_id == "" || input.provider == "" || input.model == "" do return {}, false, domain.domain_error(.Validation_Failed, "idempotency key, bridge, provider and model are required")
	if existing, exists, _ := iface.instance_reconfiguration_get(service.agents, string(inst.owner_user_id), instance_id, input.idempotency_key); exists {
		if existing.destination.bridge_id != input.bridge_id || existing.destination.project_id != input.project_id || existing.destination.provider != input.provider || existing.destination.model != input.model {
			domain.instance_reconfiguration_destroy(&existing)
			return {}, false, domain.domain_error(.Conflict, "idempotency key already belongs to another configuration")
		}
		return existing, true, {}
	}
	if input.expected_revision != inst.configuration_revision do return {}, false, domain.domain_error(.Conflict, "configuration changed; refresh before applying")
	if idle, idle_err := reconfiguration_require_idle(service, instance_id); !idle do return {}, false, idle_err
	agent, agent_ok, agent_err := get_agent(service, auth, inst.agent_id)
	if !agent_ok do return {}, false, agent_err
	if agent.state != .Active do return {}, false, domain.domain_error(.Conflict, "agent is archived")
	source_bridge, source_ok, source_err := iface.bridge_get_bridge(service.bridges, inst.bridge_id)
	if !source_ok do return {}, false, source_err
	if source_bridge.owner_user_id != inst.owner_user_id do return {}, false, domain.domain_error(.Not_Found, "source bridge not found")
	if source_bridge.status != .Online || !project_service.bridge_runtime_registry_has_live(service.bridge_runtime_registry, inst.bridge_id) do return {}, false, domain.domain_error(.Bridge_Offline, "source bridge must be online to confirm termination")
	destination_bridge, bridge_ok, bridge_err := iface.bridge_get_bridge(service.bridges, input.bridge_id)
	if !bridge_ok do return {}, false, bridge_err
	if destination_bridge.owner_user_id != inst.owner_user_id do return {}, false, domain.domain_error(.Not_Found, "destination bridge not found")
	if plan_err := require_launch_bridge_enabled(service, destination_bridge); plan_err.code != .None do return {}, false, plan_err
	if destination_bridge.status != .Online || !project_service.bridge_runtime_registry_has_live(service.bridge_runtime_registry, input.bridge_id) do return {}, false, domain.domain_error(.Bridge_Offline, "destination bridge must be online")
	if !reconfiguration_bridge_supported(source_bridge) || !reconfiguration_bridge_supported(destination_bridge) do return {}, false, domain.domain_error(.Conflict, "update source and destination bridges before applying configuration changes")
	next := inst
	next.bridge_id = input.bridge_id; next.project_id = domain.Project_ID(input.project_id)
	next.provider = input.provider; next.model = input.model; next.project_path = ""
	_, provider_ok, provider_err := validate_pinned_provider_model(service, auth, next, input.provider, input.model)
	if !provider_ok do return {}, false, provider_err
	if input.project_id != "" {
		project, project_ok, project_err := iface.project_get(service.projects, next.project_id)
		if !project_ok do return {}, false, project_err
		if project.owner_user_id != inst.owner_user_id do return {}, false, domain.domain_error(.Not_Found, "destination project not found")
		if project.state != .Active do return {}, false, domain.domain_error(.Conflict, "destination project is archived")
		path, path_ok, path_err := resolve_project_path_for_launch(service, inst.owner_user_id, next.project_id, next.bridge_id)
		if !path_ok do return {}, false, path_err
		// Project paths are optional context; managed instance directories own cwd.
		if path != "" {
			validation, validation_ok, validation_err := project_service.bridge_command_validate_project_path(service.bridge_command_sink, project_service.Validate_Project_Path_Command{type = "validate_project_path", command_id = platform.generate_id(service.ids, "cmd_preflight_"), project_id = next.project_id, bridge_id = next.bridge_id, path = path, vcs_kind = project.vcs_kind, repo_url = project.repo_url})
			if !validation_ok do return {}, false, validation_err
			if !validation.ok do return {}, false, domain.domain_error(.Validation_Failed, "destination project path is not available on selected bridge")
		}
		next.project_path = path
	}
	if inst.chain_id != "" && service.taskchains != nil {
		chain, chain_ok, chain_err := iface.taskchain_get_chain(service.taskchains, domain.Task_Chain_ID(inst.chain_id))
		if !chain_ok do return {}, false, chain_err
		if chain.owner_user_id != inst.owner_user_id do return {}, false, domain.domain_error(.Not_Found, "task chain not found")
		// Chain membership/kind does not bind this instance to a checkout. Chain
		// directory records are context references, not owned runtime workspaces.
		// Moving the instance preserves the chain and its directory references.
		// Destination project/path validation above is the execution-location guard.
	}
	// Check and reserve destination capacity before stopping source. Reservations
	// are a runtime projection and are rechecked when committing after stop.
	generation, admitted, quota_err := reserve_runtime_launch(service, next)
	if !admitted do return {}, false, quota_err
	// Path preflight above can wait for a WS reply. Only acquire this lock after
	// preflight completes; the reader must remain free to deliver that reply.
	sync.lock(&service.reconfiguration_mutex)
	defer sync.unlock(&service.reconfiguration_mutex)
	defer project_service.bridge_runtime_instance_cancel_reservation(service.bridge_runtime_registry, next.bridge_id, generation, next.agent_instance_id)
	if existing, exists, _ := iface.instance_reconfiguration_get(service.agents, string(inst.owner_user_id), instance_id, input.idempotency_key); exists {
		if existing.destination.bridge_id != input.bridge_id || existing.destination.project_id != input.project_id || existing.destination.provider != input.provider || existing.destination.model != input.model {
			domain.instance_reconfiguration_destroy(&existing)
			return {}, false, domain.domain_error(.Conflict, "idempotency key already belongs to another configuration")
		}
		return existing, true, {}
	}
	// Preflight can wait for a bridge reply; recheck connectivity before stopping source.
	if !project_service.bridge_runtime_registry_has_live(service.bridge_runtime_registry, next.bridge_id) do return {}, false, domain.domain_error(.Bridge_Offline, "destination bridge disconnected during preflight; reconnect it before Apply")
	now := platform.clock_now(service.clock)
	op := domain.Instance_Reconfiguration{operation_id = platform.generate_id(service.ids, "reconfig_"), owner_user_id = string(inst.owner_user_id), agent_instance_id = inst.agent_instance_id, conversation_id = inst.conversation_id, actor_user_id = auth.user_id, idempotency_key = input.idempotency_key, expected_revision = input.expected_revision, revision = 1, phase = .Prepared, source = configuration_snapshot(service, inst), destination = configuration_snapshot(service, next), stop_command_id = platform.generate_id(service.ids, "cmd_reconfig_stop_"), launch_command_id = platform.generate_id(service.ids, "cmd_reconfig_launch_"), launch_epoch = platform.generate_id(service.ids, "launch_"), created_at = now, updated_at = now}
	stored, saved, save_err := iface.instance_reconfiguration_begin(service.agents, op)
	if !saved do return {}, false, save_err
	defer domain.instance_reconfiguration_destroy(&stored)
	return reconfiguration_start_stop(service, stored)
}

reconfiguration_advance :: proc(service: ^Agent_Service, op: domain.Instance_Reconfiguration, phase: domain.Instance_Reconfiguration_Phase, stopped, committed: bool, failure_code: string = "", failure_message: string = "") -> (domain.Instance_Reconfiguration, bool, domain.Domain_Error) {
	next := op; next.phase = phase; next.revision += 1; next.updated_at = platform.clock_now(service.clock)
	next.source_stopped = stopped; next.destination_committed = committed; next.failure_code = failure_code; next.failure_message = failure_message
	return iface.instance_reconfiguration_advance(service.agents, next, op.revision)
}
reconfiguration_start_stop :: proc(service: ^Agent_Service, op: domain.Instance_Reconfiguration) -> (domain.Instance_Reconfiguration, bool, domain.Domain_Error) {
	stopping, accepted, err := reconfiguration_advance(service, op, .Stopping, false, false)
	if !accepted do return {}, false, err
	command := project_service.Runtime_Command{bridge_id = op.source.bridge_id, command_id = op.stop_command_id, body_json = stop_command_json(op.stop_command_id, op.agent_instance_id, "configuration_change")}
	if sent, _ := project_service.bridge_command_send_runtime(service.bridge_command_sink, command); !sent {
		defer domain.instance_reconfiguration_destroy(&stopping)
		return reconfiguration_advance(service, stopping, .Recovery_Required, false, false, "stop_unconfirmed", "Source stop could not be confirmed. No destination launch was requested.")
	}
	return stopping, true, {}
}

reconfiguration_launch_destination :: proc(service: ^Agent_Service, op: domain.Instance_Reconfiguration) {
	if valid, validity_err := reconfiguration_validate_live_destination(service, op); !valid {
		failed, _, _ := reconfiguration_advance(service, op, .Recovery_Required, true, false, "destination_invalid", validity_err.message)
		domain.instance_reconfiguration_destroy(&failed)
		return
	}
	inst, found, _ := iface.agent_get_instance(service.agents, op.agent_instance_id)
	if !found do return
	defer domain.agent_instance_destroy(&inst)
	next := inst; next.bridge_id = op.destination.bridge_id; next.project_id = domain.Project_ID(op.destination.project_id); next.project_path = op.destination.project_path
	next.provider = op.destination.provider; next.model = op.destination.model
	generation, admitted, _ := reserve_runtime_launch(service, next)
	if !admitted {
		failed, _, _ := reconfiguration_advance(service, op, .Recovery_Required, true, false, "destination_capacity", "Source is stopped; destination capacity is unavailable.")
		domain.instance_reconfiguration_destroy(&failed)
		return
	}
	launching, committed, _ := reconfiguration_advance(service, op, .Launching, true, true)
	if !committed {
		project_service.bridge_runtime_instance_cancel_reservation(service.bridge_runtime_registry, next.bridge_id, generation, next.agent_instance_id)
		return
	}
	defer domain.instance_reconfiguration_destroy(&launching)
	next.launch_epoch = op.launch_epoch
	command := project_service.Runtime_Command{bridge_id = next.bridge_id, command_id = op.launch_command_id, body_json = launch_command_json_full(service, op.launch_command_id, next)}
	if sent, _ := project_service.bridge_command_send_runtime(service.bridge_command_sink, command); !sent {
		failed, _, _ := reconfiguration_advance(service, launching, .Recovery_Required, true, true, "launch_unconfirmed", "Source is stopped; destination launch could not be confirmed.")
		domain.instance_reconfiguration_destroy(&failed)
	}
}

// Called after transport has stored command results. Never waits or joins on the
// WS reader; it only persists progress and sends the next command.
apply_reconfiguration_command_result :: proc(service: ^Agent_Service, bridge_id, command_id, result: string) {
	sync.lock(&service.reconfiguration_mutex)
	defer sync.unlock(&service.reconfiguration_mutex)
	ops, err := iface.instance_reconfiguration_list(service.agents, "", "", true)
	if err.code != .None do return
	defer { for &op in ops do domain.instance_reconfiguration_destroy(&op); delete(ops) }
	for op in ops {
		if op.phase == .Recovery_Required && op.failure_code == "force_stopping" {
			target := op.destination.bridge_id if op.destination_committed else op.source.bridge_id
			if target != bridge_id || op.stop_command_id != command_id do continue
			status := jsonx.extract_string(result, "status"); defer delete(status)
			if status == "accepted" do return
			if status == "succeeded" {
				stopped, _, _ := reconfiguration_advance(service, op, .Failed, true, op.destination_committed, "recovery_stopped", "Agent stopped. Choose a model or bridge and Apply to start again.")
				domain.instance_reconfiguration_destroy(&stopped)
			} else {
				failed, _, _ := reconfiguration_advance(service, op, .Recovery_Required, op.source_stopped, op.destination_committed, "force_stopping", "Force stop was not confirmed. Reconnect the current bridge and retry Force stop.")
				domain.instance_reconfiguration_destroy(&failed)
			}
			return
		}
		is_stop := op.source.bridge_id == bridge_id && op.stop_command_id == command_id
		is_launch := op.destination.bridge_id == bridge_id && op.launch_command_id == command_id
		if !is_stop && !is_launch do continue
		status := jsonx.extract_string(result, "status"); defer delete(status)
		if status == "accepted" do return
		if is_stop && (op.phase == .Stopping || (op.phase == .Recovery_Required && !op.source_stopped)) {
			if status != "succeeded" {
				if op.phase == .Recovery_Required do return
				failed, _, _ := reconfiguration_advance(service, op, .Recovery_Required, false, false, "stop_failed", "Could not confirm source termination. Destination has not started.")
				domain.instance_reconfiguration_destroy(&failed); return
			}
			stopped, changed, _ := reconfiguration_advance(service, op, .Source_Stopped, true, false)
			if changed { reconfiguration_launch_destination(service, stopped); domain.instance_reconfiguration_destroy(&stopped) }
			return
		}
		if is_launch && op.phase == .Launching && status != "succeeded" {
			failed, _, _ := reconfiguration_advance(service, op, .Recovery_Required, true, true, "launch_failed", "Source is stopped; destination agent failed to start.")
			domain.instance_reconfiguration_destroy(&failed)
		}
	}
}

reconcile_instance_reconfigurations :: proc(service: ^Agent_Service, bridge_id: string) {
	if service == nil || service.agents == nil do return
	sync.lock(&service.reconfiguration_mutex)
	defer sync.unlock(&service.reconfiguration_mutex)
	ops, err := iface.instance_reconfiguration_list(service.agents, "", "", true)
	if err.code != .None do return
	defer { for &op in ops do domain.instance_reconfiguration_destroy(&op); delete(ops) }
	for op in ops {
		if op.source.bridge_id != bridge_id && op.destination.bridge_id != bridge_id do continue
		created_ms, created_ok := platform.rfc3339_to_unix_ms(op.updated_at)
		now_ms, now_ok := platform.rfc3339_to_unix_ms(platform.clock_now(service.clock))
		if created_ok && now_ok && now_ms - created_ms > 180_000 && (op.phase == .Stopping || op.phase == .Launching) {
			failed, _, _ := reconfiguration_advance(service, op, .Recovery_Required, op.source_stopped, op.destination_committed, "confirmation_timeout", "Runtime confirmation timed out. Apply can retry safely; messages remain disabled.")
			domain.instance_reconfiguration_destroy(&failed)
			continue
		}
		switch op.phase {
		case .Prepared:
			started, _, _ := reconfiguration_start_stop(service, op); domain.instance_reconfiguration_destroy(&started)
		case .Source_Stopped:
			reconfiguration_launch_destination(service, op)
		case .Launching:
			if inst, found, _ := iface.agent_get_instance(service.agents, op.agent_instance_id); found {
				if inst.launch_epoch == op.launch_epoch && inst.startup_status == "ready" {
					ready, _, _ := reconfiguration_advance(service, op, .Ready, true, true); domain.instance_reconfiguration_destroy(&ready)
				} else if inst.runtime_status == "failed" || inst.runtime_status == "blocked" {
					failed, _, _ := reconfiguration_advance(service, op, .Recovery_Required, true, true, "startup_failed", "Destination startup needs attention; conversation remains read-only."); domain.instance_reconfiguration_destroy(&failed)
				}
				if bridge_id == op.destination.bridge_id && inst.launch_epoch == op.launch_epoch && (inst.runtime_status == "launching" || inst.runtime_status == "unreachable") {
					_, _ = project_service.bridge_command_send_runtime(service.bridge_command_sink, project_service.Runtime_Command{bridge_id = bridge_id, command_id = op.launch_command_id, body_json = launch_command_json_full(service, op.launch_command_id, inst)})
				}
				domain.agent_instance_destroy(&inst)
			}
		case .Stopping:
			// Idempotent source-only stop is safe to resend after Hub restart: no
			// destination can launch until the acknowledged phase was persisted.
			if bridge_id == op.source.bridge_id {
				_, _ = project_service.bridge_command_send_runtime(service.bridge_command_sink, project_service.Runtime_Command{bridge_id = bridge_id, command_id = op.stop_command_id, body_json = stop_command_json(op.stop_command_id, op.agent_instance_id, "configuration_change")})
			}
		case .Recovery_Required:
			if op.failure_code == "force_stopping" {
				target := op.destination.bridge_id if op.destination_committed else op.source.bridge_id
				if bridge_id == target { _, _ = project_service.bridge_command_send_runtime(service.bridge_command_sink, project_service.Runtime_Command{bridge_id = target, command_id = op.stop_command_id, body_json = stop_command_json(op.stop_command_id, op.agent_instance_id, "recovery_force_stop", force = true)}) }
				continue
			}
			if op.destination_committed {
				if inst, found, _ := iface.agent_get_instance(service.agents, op.agent_instance_id); found {
					if inst.launch_epoch == op.launch_epoch && inst.startup_status == "ready" {
						ready, _, _ := reconfiguration_advance(service, op, .Ready, true, true); domain.instance_reconfiguration_destroy(&ready)
					}
					domain.agent_instance_destroy(&inst)
				}
			}
		case .Ready, .Failed:
		}
	}
}

reconfiguration_json :: proc(op: domain.Instance_Reconfiguration) -> string {
	data, err := json.marshal(op)
	if err != nil do return "{}"
	return string(data)
}

retry_instance_reconfiguration :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id, key: string, expected_revision: int) -> (domain.Instance_Reconfiguration, bool, domain.Domain_Error) {
	sync.lock(&service.reconfiguration_mutex)
	defer sync.unlock(&service.reconfiguration_mutex)
	inst, found, err := get_instance(service, auth, instance_id)
	if !found do return {}, false, err
	defer domain.agent_instance_destroy(&inst)
	op, exists, op_err := iface.instance_reconfiguration_get(service.agents, string(inst.owner_user_id), instance_id, key)
	if !exists do return {}, false, op_err
	defer domain.instance_reconfiguration_destroy(&op)
	if op.failure_code == "force_stopping" do return {}, false, domain.domain_error(.Conflict, "Force stop must be confirmed before retrying")
	if op.phase != .Recovery_Required || op.revision != expected_revision do return {}, false, domain.domain_error(.Conflict, "operation changed; refresh before retrying")
	if valid, validity_err := reconfiguration_validate_live_destination(service, op); !valid do return {}, false, validity_err
	destination := inst; destination.bridge_id = op.destination.bridge_id; destination.provider = op.destination.provider; destination.model = op.destination.model
	_, valid, validation_err := validate_pinned_provider_model(service, auth, destination, destination.provider, destination.model)
	if !valid do return {}, false, validation_err
	if !op.source_stopped {
		next := op; next.stop_command_id = platform.generate_id(service.ids, "cmd_reconfig_stop_retry_")
		stopping, saved, save_err := reconfiguration_advance(service, next, .Stopping, false, false)
		if !saved do return {}, false, save_err
		_, _ = project_service.bridge_command_send_runtime(service.bridge_command_sink, project_service.Runtime_Command{bridge_id = op.source.bridge_id, command_id = stopping.stop_command_id, body_json = stop_command_json(stopping.stop_command_id, instance_id, "configuration_change")})
		return stopping, true, {}
	}
	if !op.destination_committed {
		stopped, saved, save_err := reconfiguration_advance(service, op, .Source_Stopped, true, false)
		if !saved do return {}, false, save_err
		defer domain.instance_reconfiguration_destroy(&stopped)
		reconfiguration_launch_destination(service, stopped)
		return iface.instance_reconfiguration_get(service.agents, op.owner_user_id, instance_id, key)
	}
	// Keep the launch epoch: an alive destination with that assertion is reused,
	// not restarted. A new command id lets an earlier failed result be retried.
	next := op; next.launch_command_id = platform.generate_id(service.ids, "cmd_reconfig_launch_retry_")
	launching, saved, save_err := reconfiguration_advance(service, next, .Launching, true, true)
	if !saved do return {}, false, save_err
	_, _ = project_service.bridge_command_send_runtime(service.bridge_command_sink, project_service.Runtime_Command{bridge_id = op.destination.bridge_id, command_id = launching.launch_command_id, body_json = launch_command_json_full(service, launching.launch_command_id, inst)})
	return launching, true, {}
}

validate_instance_message_configuration :: proc(service: ^Agent_Service, owner: domain.User_ID, instance_id: string) -> (bool, domain.Domain_Error) {
	inst, found, err := iface.agent_get_instance(service.agents, instance_id)
	if !found do return false, err
	defer domain.agent_instance_destroy(&inst)
	if inst.owner_user_id != owner do return false, domain.domain_error(.Not_Found, "agent instance not found")
	if idle, idle_err := reconfiguration_require_idle(service, instance_id); !idle do return false, idle_err
	bridge, bridge_ok, bridge_err := iface.bridge_get_bridge(service.bridges, inst.bridge_id)
	if !bridge_ok do return false, bridge_err
	defer domain.bridge_destroy(&bridge)
	if bridge.status != .Online || !project_service.bridge_runtime_registry_has_live(service.bridge_runtime_registry, inst.bridge_id) do return false, domain.domain_error(.Bridge_Offline, "conversation is read-only: reconnect the bridge or choose an online bridge")
	if inst.project_id != "" {
		project, project_ok, project_err := iface.project_get(service.projects, inst.project_id)
		if !project_ok do return false, project_err
		if project.owner_user_id != owner || project.state != .Active do return false, domain.domain_error(.Conflict, "conversation is read-only: choose an accessible active project or clear the project")
	}
	_, valid, validation_err := validate_pinned_provider_model(service, contracts.Auth_Context{kind = .User_Token, user_id = string(owner)}, inst, inst.provider, inst.model)
	return valid, validation_err
}

// DB/runtime-projection checks only: safe on the WS reader after stop confirmation.
reconfiguration_validate_live_destination :: proc(service: ^Agent_Service, op: domain.Instance_Reconfiguration) -> (bool, domain.Domain_Error) {
	bridge, found, err := iface.bridge_get_bridge(service.bridges, op.destination.bridge_id)
	if !found do return false, err
	defer domain.bridge_destroy(&bridge)
	if string(bridge.owner_user_id) != op.owner_user_id do return false, domain.domain_error(.Not_Found, "destination bridge not found")
	if plan_err := require_launch_bridge_enabled(service, bridge); plan_err.code != .None do return false, plan_err
	if bridge.status != .Online || !project_service.bridge_runtime_registry_has_live(service.bridge_runtime_registry, bridge.bridge_id) do return false, domain.domain_error(.Bridge_Offline, "destination bridge is offline; reconnect it before Apply")
	if !reconfiguration_bridge_supported(bridge) do return false, domain.domain_error(.Conflict, "destination bridge must be updated before Apply")
	if op.destination.project_id != "" {
		project, project_found, project_err := iface.project_get(service.projects, domain.Project_ID(op.destination.project_id))
		if !project_found do return false, project_err
		if string(project.owner_user_id) != op.owner_user_id || project.state != .Active do return false, domain.domain_error(.Conflict, "destination project is unavailable or archived")
		path, path_found, path_err := resolve_project_path_for_launch(service, domain.User_ID(op.owner_user_id), domain.Project_ID(op.destination.project_id), op.destination.bridge_id)
		if !path_found do return false, path_err
		if path != op.destination.project_path do return false, domain.domain_error(.Conflict, "destination project path changed after preflight; recovery needs the original validated path")
	}
	_, valid, validation_err := validate_provider_model_intersection(service, op.destination.bridge_id, op.destination.provider, op.destination.model)
	return valid, validation_err
}

// Called with the operation mutex held. A force stop targets the current routing
// owner, never both bridges; the original move snapshots remain immutable.
force_stop_instance_reconfiguration_locked :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	inst, found, err := get_instance(service, auth, instance_id)
	if !found do return {}, true, err
	ops, list_err := iface.instance_reconfiguration_list(service.agents, string(inst.owner_user_id), instance_id, true)
	if list_err.code != .None { domain.agent_instance_destroy(&inst); return {}, true, list_err }
	defer { for &op in ops do domain.instance_reconfiguration_destroy(&op); delete(ops) }
	if len(ops) == 0 { domain.agent_instance_destroy(&inst); return {}, false, {} }
	if !project_service.bridge_runtime_registry_has_live(service.bridge_runtime_registry, inst.bridge_id) { domain.agent_instance_destroy(&inst); return {}, true, domain.domain_error(.Bridge_Offline, "reconnect the current bridge to confirm Force stop") }
	op := ops[0]
	next := op
	if op.failure_code != "force_stopping" do next.stop_command_id = platform.generate_id(service.ids, "cmd_recovery_force_stop_")
	stopping, saved, save_err := reconfiguration_advance(service, next, .Recovery_Required, op.source_stopped, op.destination_committed, "force_stopping", "Force stopping the current runtime. Settings unlock after termination is confirmed.")
	if !saved { domain.agent_instance_destroy(&inst); return {}, true, save_err }
	defer domain.instance_reconfiguration_destroy(&stopping)
	command := project_service.Runtime_Command{bridge_id = inst.bridge_id, command_id = stopping.stop_command_id, body_json = stop_command_json(stopping.stop_command_id, instance_id, "recovery_force_stop", force = true)}
	if sent, send_err := project_service.bridge_command_send_runtime(service.bridge_command_sink, command); !sent { domain.agent_instance_destroy(&inst); return {}, true, send_err }
	inst.runtime_status = "stopping"; inst.updated_at = platform.clock_now(service.clock)
	result, ok, persist_err := iface.agent_save_instance(service.agents, inst)
	return result, true, persist_err if !ok else domain.Domain_Error{}
}
