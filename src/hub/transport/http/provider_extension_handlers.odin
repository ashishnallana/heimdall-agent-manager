package http

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import bridge_service "odin_test:hub/service/bridge"
import project_service "odin_test:hub/service/project"
import provider_service "odin_test:hub/service/provider"

extension_command_terminal :: proc(state: string) -> bool {
	return state == "succeeded" || state == "failed" || state == "cancelled"
}

extension_command_set_state :: proc(
	command: ^domain.Provider_Extension_Command,
	state, message: string,
	progress: int,
) {
	delete(command.state); command.state = strings.clone(state)
	delete(command.message); command.message = strings.clone(message)
	command.progress = clamp(progress, 0, 100)
}

extension_install_supported :: proc(view: provider_service.Bridge_Provider_View) -> bool {
	return(
		view.catalog.state == "active" &&
		view.catalog.extension_json != "" &&
		(view.catalog.provider == "antigravity" ||
				view.catalog.provider == "claude" ||
				view.catalog.provider == "codex") \
	)
}

extension_command_json :: proc(command: domain.Provider_Extension_Command) -> string {
	b := strings.builder_make()
	strings.write_string(
		&b,
		"{\"command_id\":\"",
	); write_handler_json_string(&b, command.command_id)
	strings.write_string(
		&b,
		"\",\"bridge_id\":\"",
	); write_handler_json_string(&b, command.bridge_id)
	strings.write_string(&b, "\",\"provider\":\""); write_handler_json_string(&b, command.provider)
	strings.write_string(&b, "\",\"profile_id\":\""); write_handler_json_string(&b,domain.profile_effective_id(command.provider,command.profile_id))
	strings.write_string(&b, "\",\"kind\":\""); write_handler_json_string(&b, command.kind)
	strings.write_string(&b, "\",\"status\":\""); write_handler_json_string(&b, command.state)
	strings.write_string(&b, "\",\"message\":\""); write_handler_json_string(&b, command.message)
	strings.write_string(
		&b,
		"\",\"progress_percent\":",
	); strings.write_string(&b, fmt.tprintf("%d", command.progress))
	strings.write_string(
		&b,
		",\"parent_command_id\":\"",
	); write_handler_json_string(&b, command.parent_id)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

extension_install_command_json :: proc(command: domain.Provider_Extension_Command) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"provider_extension_install\",\"command_id\":\"")
	write_handler_json_string(&b, command.command_id)
	strings.write_string(&b, "\",\"provider\":\""); write_handler_json_string(&b, command.provider)
	strings.write_string(&b, "\",\"profile_id\":\""); write_handler_json_string(&b,domain.profile_effective_id(command.provider,command.profile_id))
	// Same frame for both actions, so the bridge serializes them per provider.
	if command.kind == "uninstall" do strings.write_string(&b, "\",\"action\":\"uninstall")
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

// An install or uninstall: both are explicit per-provider actions tracked the same way.
extension_action_kind :: proc(kind: string) -> bool {return kind == "install" || kind == "uninstall"}

// The caller holds extension_mutex; no synchronous command wait on the WS reader.
extension_command_dispatch :: proc(
	h: ^Provider_Handlers,
	command: domain.Provider_Extension_Command,
) -> (
	bool,
	domain.Domain_Error,
) {
	payload := ""
	if command.kind == "discovery" {
		payload = provider_discover_command_json(command.command_id, nil,command.profile_id)
	} else {
		payload = extension_install_command_json(command)
	}
	defer delete(payload)
	sink := h.bridges.bridge_command_sink
	return project_service.bridge_command_send_runtime(
		sink,
		{bridge_id = command.bridge_id, command_id = command.command_id, body_json = payload},
	)
}

// POST .../providers/:provider/extension-install (install or update).
bridge_provider_extension_install_handler :: proc(ctx: rawptr, req: Request) -> Response {
	return extension_action_start(ctx, req, "install")
}

// POST .../providers/:provider/extension-uninstall: the bridge runs the provider
// CLI's plugin uninstall and reports fresh discovery. Setup/update reinstall it.
bridge_provider_extension_uninstall_handler :: proc(ctx: rawptr, req: Request) -> Response {
	return extension_action_start(ctx, req, "uninstall")
}

// extension_action_start: explicit user action (kind install|uninstall). Acceptance is
// distinct from verified completion; one action per provider at a time.
extension_action_start :: proc(ctx: rawptr, req: Request, kind: string) -> Response {
	h := (^Provider_Handlers)(ctx)
	bridge, ok, response := provider_owned_bridge(h, req, path_part(req.path, 4))
	if !ok do return response
	defer domain.bridge_destroy(&bridge)
	if bridge.status != .Online || !project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry, bridge.bridge_id) do return respond_error(domain.domain_error(.Bridge_Offline, "bridge is not connected"), req.request_id)
	provider := path_part(req.path, 6)
	profile_id:=json_string(req.body,"profile_id");defer delete(profile_id)
	if e:=provider_service.validate_profile(h.providers.repo,bridge.bridge_id,provider,profile_id);e.code!=.None do return respond_error(e,req.request_id)
	views, view_err := provider_service.list_bridge_providers(h.providers, bridge.bridge_id)
	if view_err.code != .None do return respond_error(view_err, req.request_id)
	defer provider_service.bridge_provider_views_destroy(views)
	found, supported, present := false, false, false
	for view in views {
		if view.catalog.provider != provider || view.profile_id!=domain.profile_effective_id(provider,profile_id) do continue
		found =
			true; supported = extension_install_supported(view); present = view.detection_state == "present"
	}
	if !found do return respond_error(domain.domain_error(.Not_Found, "provider was not found"), req.request_id)
	if !supported do return respond_error(domain.domain_error(.Unprocessable_Entity, fmt.tprintf("provider extension %s is unsupported", kind)), req.request_id)
	if !present do return respond_error(domain.domain_error(.Conflict, "provider CLI is not present on this bridge"), req.request_id)
	sync.mutex_lock(&h.providers.extension_mutex)
	defer sync.mutex_unlock(&h.providers.extension_mutex)
	commands, list_err := iface.provider_extension_command_list(h.providers.repo, bridge.bridge_id)
	if list_err.code != .None do return respond_error(list_err, req.request_id)
	defer domain.provider_extension_commands_destroy(commands)
	for command in commands {
		if extension_action_kind(command.kind) && command.provider == provider && domain.profile_effective_id(provider,command.profile_id)==domain.profile_effective_id(provider,profile_id) && !extension_command_terminal(command.state) do return respond_error(domain.domain_error(.Conflict, "an extension install or uninstall is already in progress"), req.request_id)
	}
	command_id := strings.clone(platform.generate_id(h.ids, "cmd_ext_"))
	defer delete(command_id)
	command := domain.Provider_Extension_Command {
		command_id = command_id,
		bridge_id  = bridge.bridge_id,
		kind       = kind,
		provider   = provider,
		profile_id = domain.profile_effective_id(provider,profile_id),
		state      = "queued",
	}
	created, create_err := iface.provider_extension_command_create(h.providers.repo, command)
	if !created do return respond_error(create_err, req.request_id)
	sent, send_err := extension_command_dispatch(h, command)
	if !sent {
		command.state = "failed"; command.message = send_err.message
		_ = iface.provider_extension_command_save(h.providers.repo, command)
		return respond_error(send_err, req.request_id)
	}
	command.state = "dispatched"
	if save_err := iface.provider_extension_command_save(h.providers.repo, command); save_err.code != .None do return respond_error(save_err, req.request_id)
	body := extension_command_json(command)
	defer delete(body)
	result := respond_success(body, req.request_id, auth_ctx_server_time(req))
	result.status = 202
	return result
}

// GET .../providers/:provider/extension-{install,uninstall}/:command_id (same-owner scoped).
bridge_provider_extension_command_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Provider_Handlers)(ctx)
	bridge, ok, response := provider_owned_bridge(h, req, path_part(req.path, 4))
	if !ok do return response
	defer domain.bridge_destroy(&bridge)
	commands, err := iface.provider_extension_command_list(h.providers.repo, bridge.bridge_id)
	if err.code != .None do return respond_error(err, req.request_id)
	defer domain.provider_extension_commands_destroy(commands)
	for command in commands {
		want := "uninstall" if path_part(req.path, 7) == "extension-uninstall" else "install"
		if command.kind != want || command.command_id != path_part(req.path, 8) || command.provider != path_part(req.path, 6) do continue
		body := extension_command_json(command)
		defer delete(body)
		return respond_success(body, req.request_id, auth_ctx_server_time(req))
	}
	return respond_error(
		domain.domain_error(.Not_Found, "extension command was not found"),
		req.request_id,
	)
}

extension_frame_handlers :: proc(h: ^Bridge_Handlers) -> Provider_Handlers {
	return {
		providers = h.providers,
		bridges = h.bridges,
		bridge_runtime_registry = h.bridge_runtime_registry,
		clock = h.bridges.clock,
		ids = h.bridges.ids,
		event_bus = h.event_bus,
	}
}

// A discovery with provider set waits for that install command, rather than
// representing an install itself. A new id avoids replaying the Bridge's cached
// pre-install discovery. Both the wait and its correlation survive Hub restart.
extension_resume_waiting_discoveries :: proc(h: ^Bridge_Handlers, bridge_id: string) -> domain.Domain_Error {
	commands, err := iface.provider_extension_command_list(h.providers.repo, bridge_id)
	if err.code != .None do return err
	defer domain.provider_extension_commands_destroy(commands)
	ph := extension_frame_handlers(h)
	for &command in commands {
		if command.kind != "discovery" || command.state != "waiting" do continue
		for blocker in commands {
			if blocker.command_id != command.provider || !extension_command_terminal(blocker.state) do continue
			sent, send_err := extension_command_dispatch(&ph, command)
			if !sent do return send_err
			extension_command_set_state(&command, "dispatched", "Rechecking after extension installation", 0)
			if save_err := iface.provider_extension_command_save(h.providers.repo, command); save_err.code != .None do return save_err
			break
		}
	}
	return {}
}

// Runs only after bridge_ready on a new authenticated connection. Target identity
// confirms restart success; an accepted command ("restarting") alone cannot do so.
bridge_extension_reconnected :: proc(
	h: ^Bridge_Handlers,
	bridge: domain.Bridge,
) -> domain.Domain_Error {
	if h.providers == nil || h.providers.repo == nil do return {}
	sync.mutex_lock(&h.providers.extension_mutex)
	defer sync.mutex_unlock(&h.providers.extension_mutex)
	ph := extension_frame_handlers(h)
	commands, err := iface.provider_extension_command_list(h.providers.repo, bridge.bridge_id)
	if err.code != .None do return err
	defer domain.provider_extension_commands_destroy(commands)
	for &command in commands {
		if command.kind != "bridge_update" || extension_command_terminal(command.state) do continue
		target_matches :=
			bridge.version == command.target_version &&
			(command.target_commit == "" || bridge.commit_sha == command.target_commit)
		identity_changed :=
			bridge.version != command.source_version ||
			(command.target_commit != "" && bridge.commit_sha != command.source_commit)
		// A new target identity proves completion even if the last progress frame was
		// lost during shutdown. Reinstalling the same build still needs restart evidence.
		if command.state != "restarting" && !(target_matches && identity_changed) do continue
		if !target_matches {
			// A rollback must never install extensions from the failed target.
			extension_command_set_state(
				&command,
				"failed",
				"Bridge reconnected without the requested update identity",
				0,
			)
		} else {
			extension_command_set_state(
				&command,
				"succeeded",
				"Bridge update verified after reconnect",
				100,
			)
		}
		if save_err := iface.provider_extension_command_save(h.providers.repo, command); save_err.code != .None do return save_err
	}
	// Re-read so a Hub restart between success and discovery creation is recoverable.
	domain.provider_extension_commands_destroy(commands)
	commands, err = iface.provider_extension_command_list(h.providers.repo, bridge.bridge_id)
	if err.code != .None do return err
	for command in commands {
		if command.kind != "bridge_update" || !command.update_extensions || command.state != "succeeded" do continue
		id := fmt.tprintf("%s_ext_discovery", command.command_id)
		discovery := domain.Provider_Extension_Command {
			command_id = id,
			bridge_id  = bridge.bridge_id,
			kind       = "discovery",
			parent_id  = command.command_id,
			state      = "queued",
		}
		_, create_err := iface.provider_extension_command_create(h.providers.repo, discovery)
		if create_err.code != .None do return create_err
	}
	domain.provider_extension_commands_destroy(commands)
	commands, err = iface.provider_extension_command_list(h.providers.repo, bridge.bridge_id)
	if err.code != .None do return err
	for &command in commands {
		if command.kind == "bridge_update" || command.state == "waiting" || extension_command_terminal(command.state) do continue
		// Same durable id on replay; the Bridge returns cached acceptance/results.
		sent, send_err := extension_command_dispatch(&ph, command)
		if !sent do return send_err
		if command.state == "queued" {
			extension_command_set_state(&command, "dispatched", "", 0)
			if save_err := iface.provider_extension_command_save(h.providers.repo, command); save_err.code != .None do return save_err
		}
	}
	return extension_resume_waiting_discoveries(h, bridge.bridge_id)
}

// Match only commands durably registered for THIS Bridge. The surrounding WS
// dispatcher rejects stale connection generations before entering this function.
bridge_extension_frame :: proc(
	h: ^Bridge_Handlers,
	bridge_id, frame_type, text: string,
) -> domain.Domain_Error {
	if h.providers == nil || h.providers.repo == nil do return {}
	if frame_type != "command_result" &&
	   frame_type != "provider_discovery_report" &&
	   frame_type != "bridge_update_progress" &&
	   frame_type != "provider_extension_install_progress" {
		return {}
	}
	command_id := json_string(text, "command_id")
	defer delete(command_id)
	if command_id == "" && frame_type == "provider_discovery_report" {
		command_id = json_string(text, "request_id")
	}
	if !strings.has_prefix(command_id, "cmd_ext_") && !strings.has_prefix(command_id, "cmd_upd_") do return {}
	sync.mutex_lock(&h.providers.extension_mutex)
	defer sync.mutex_unlock(&h.providers.extension_mutex)
	commands, err := iface.provider_extension_command_list(h.providers.repo, bridge_id)
	if err.code != .None do return err
	defer domain.provider_extension_commands_destroy(commands)
	for &command in commands {
		if command.command_id != command_id do continue
		if frame_type == "provider_discovery_report" {
			return extension_apply_report(h, &command, text)
		}
		if extension_command_terminal(command.state) do return extension_resume_waiting_discoveries(h, bridge_id)
		state := json_string(text, "stage" if frame_type != "command_result" else "status")
		defer delete(state)
		message := json_string(text, "message")
		defer delete(message)
		if state == "accepted" {
			// Acceptance cannot turn a restarting update back into an unconfirmed one.
			if command.state == "queued" || command.state == "dispatched" do extension_command_set_state(&command, "accepted", message, command.progress)
		} else if state == "failed" || state == "cancelled" {
			extension_command_set_state(&command, state, message, command.progress)
		} else if command.kind == "bridge_update" {
			if state == "restarting" || state == "succeeded" do extension_command_set_state(&command, "restarting", message, 95)
		} else if extension_action_kind(command.kind) &&
		   frame_type == "command_result" &&
		   state == "succeeded" {
			// Bridge's terminal result follows manifest/version verification and discovery.
			extension_command_set_state(&command, "succeeded", message, 100)
		} else if extension_action_kind(command.kind) &&
		   frame_type == "provider_extension_install_progress" {
			// A progress hint is never the terminal command result.
			extension_command_set_state(
				&command,
				"uninstalling" if command.kind == "uninstall" else "installing",
				message,
				json_int(text, "progress_percent", command.progress),
			)
		}
		if save_err := iface.provider_extension_command_save(h.providers.repo, command); save_err.code != .None do return save_err
		if extension_action_kind(command.kind) {
			bridge, found, _ := iface.bridge_get_bridge(h.bridges.repo, bridge_id)
			if found {
				defer domain.bridge_destroy(&bridge)
				publish_bridge_provider_status_changed(
					h.event_bus,
					string(bridge.owner_user_id),
					bridge_id,
					command.provider,
				)
			}
		}
		return extension_resume_waiting_discoveries(h, bridge_id)
	}
	return {}
}

extension_apply_report :: proc(
	h: ^Bridge_Handlers,
	command: ^domain.Provider_Extension_Command,
	text: string,
) -> domain.Domain_Error {
	if command.kind != "discovery" && !extension_action_kind(command.kind) do return {}
	if command.kind == "discovery" && extension_command_terminal(command.state) do return {}
	if command.state == "waiting" do return {} // no report has been requested yet
	report: Provider_Discovery_Report_Wire
	if decode_err := json.unmarshal_string(text, &report, json.DEFAULT_SPECIFICATION, context.temp_allocator); decode_err != nil || report.request_id != command.command_id do return domain.domain_error(.Validation_Failed, "invalid extension discovery report")
	statuses := make(
		[]domain.Bridge_Provider_Status,
		len(report.providers),
		context.temp_allocator,
	)
	for item, i in report.providers {
		statuses[i] = {
			bridge_id            = command.bridge_id,
			provider             = item.provider,
			profile_id = item.profile_id,
			binary_path          = item.binary_path,
			version_text         = item.version_text,
			state                = item.state,
			checked_at           = item.checked_at,
			extension_state      = item.extension_state,
			extension_version    = item.extension_version,
			extension_checked_at = item.extension_checked_at,
		}
	}
	if apply_err := provider_service.apply_discovery_report(h.providers, command.bridge_id, statuses); apply_err.code != .None do return apply_err
	bridge, found, _ := iface.bridge_get_bridge(h.bridges.repo, command.bridge_id)
	if found {
		defer domain.bridge_destroy(&bridge)
		publish_bridge_provider_status_changed(
			h.event_bus,
			string(bridge.owner_user_id),
			command.bridge_id,
			"",
		)
	}
	if extension_action_kind(command.kind) do return {}
	views, view_err := provider_service.list_bridge_providers(h.providers, command.bridge_id)
	if view_err.code != .None do return view_err
	defer provider_service.bridge_provider_views_destroy(views)
	commands, list_err := iface.provider_extension_command_list(h.providers.repo, command.bridge_id)
	if list_err.code != .None do return list_err
	defer domain.provider_extension_commands_destroy(commands)
	ph := extension_frame_handlers(h)
	for view in views {
        if !view.enabled || !extension_install_supported(view) do continue
        reported:=false
        for item in report.providers do if item.provider==view.catalog.provider && domain.profile_effective_id(item.provider,item.profile_id)==view.profile_id do reported=true
        if !reported do continue

		// A deferred report only resumes the provider whose install it waited on.
		if command.provider != "" {
			matches := false
			for prior in commands {
				if prior.command_id == command.provider && prior.provider == view.catalog.provider && domain.profile_effective_id(prior.provider,prior.profile_id)==view.profile_id do matches = true
			}
			if !matches do continue
		}
		already_scheduled := false
		blocker_id := ""
		after_discovery := false
		for prior in commands {
			if prior.command_id == command.command_id do after_discovery = true
			if !extension_action_kind(prior.kind) || prior.provider != view.catalog.provider || domain.profile_effective_id(prior.provider,prior.profile_id)!=view.profile_id do continue
			if prior.parent_id == command.parent_id do already_scheduled = true
			// Even a completed install invalidates a report requested before it.
			if after_discovery || !extension_command_terminal(prior.state) do blocker_id = prior.command_id
		}
		if already_scheduled do continue
		if blocker_id != "" {
			waiting := domain.Provider_Extension_Command {
				command_id = fmt.tprintf("%s_ext_after_%s", command.parent_id, blocker_id),
				bridge_id = command.bridge_id,
				kind = "discovery",
				provider = blocker_id,
				profile_id = view.profile_id,
				parent_id = command.parent_id,
				state = "waiting",
			}
			_, create_err := iface.provider_extension_command_create(h.providers.repo, waiting)
			if create_err.code != .None do return create_err
			continue
		}
		// Eligibility comes from THIS response, never stale rows from an earlier scan.
		eligible := false
		for item in report.providers {
			if item.provider == view.catalog.provider && domain.profile_effective_id(item.provider,item.profile_id)==view.profile_id &&
			   item.state == "present" &&
			   item.extension_state == "outdated" &&
			   item.extension_version != "" {eligible = true}
		}
		if !eligible {
			descriptor: struct {
				min_version: string,
			}
			if decode_err := json.unmarshal_string(
				view.catalog.extension_json,
				&descriptor,
				json.DEFAULT_SPECIFICATION,
				context.temp_allocator,
			); decode_err == nil && descriptor.min_version != "" {
				for item in report.providers {
					if item.provider == view.catalog.provider && domain.profile_effective_id(item.provider,item.profile_id)==view.profile_id &&
					   item.state == "present" &&
					   item.extension_state == "present" &&
					   item.extension_version != "" &&
					   bridge_service.compare_semver(
						   item.extension_version,
						   descriptor.min_version,
					   ) <
						   0 {
						eligible = true
					}
				}
			}
		}
		if !eligible do continue
		id := fmt.tprintf("%s_ext_%s", command.parent_id, view.profile_id)
		install := domain.Provider_Extension_Command {
			command_id = id,
			bridge_id  = command.bridge_id,
			kind       = "install",
			provider   = view.catalog.provider,
			profile_id = view.profile_id,
			parent_id  = command.parent_id,
			state      = "queued",
		}
		created, create_err := iface.provider_extension_command_create(h.providers.repo, install)
		if create_err.code != .None do return create_err
		if !created do continue
		sent, send_err := extension_command_dispatch(&ph, install)
		if !sent do return send_err // queued intent survives and is replayed on reconnect
		install.state = "dispatched"
		if save_err := iface.provider_extension_command_save(h.providers.repo, install); save_err.code != .None do return save_err
	}
	extension_command_set_state(command, "succeeded", "Fresh provider discovery processed", 100)
	if save_err := iface.provider_extension_command_save(h.providers.repo, command^); save_err.code != .None do return save_err
	return extension_resume_waiting_discoveries(h, command.bridge_id)
}
