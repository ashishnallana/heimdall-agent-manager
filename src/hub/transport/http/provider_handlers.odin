package http

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import agent_service "odin_test:hub/service/agent"
import auth_service "odin_test:hub/service/auth"
import bridge_service "odin_test:hub/service/bridge"
import bridge_runtime_service "odin_test:hub/service/bridge_runtime"
import events "odin_test:hub/service/events"
import project_service "odin_test:hub/service/project"
import provider_service "odin_test:hub/service/provider"

PROVIDER_TEST_TTL :: 2 * time.Minute

Provider_Handlers :: struct {
	auth:                    ^auth_service.Auth_Service,
	providers:               ^provider_service.Provider_Service,
	bridges:                 ^bridge_service.Bridge_Service,
	bridge_runtime_registry: ^project_service.Bridge_Runtime_Registry,
	clock:                   ^platform.Clock,
	ids:                     ^platform.ID_Generator,
	agents:                  ^agent_service.Agent_Service,
	// event_bus (nil in test wirings) carries REQ-2 provider_status_changed hints.
	event_bus:               ^events.User_Event_Bus,
}

Provider_Discovery_Item_Wire :: struct {
	profile_id: string `json:"profile_id"`,
	provider:     string `json:"provider"`,
	binary_path:  string `json:"binary_path"`,
	version_text: string `json:"version_text"`,
	state:        string `json:"state"`,
	checked_at:   string `json:"checked_at"`,
	extension_state:      string `json:"extension_state"`,
	extension_version:    string `json:"extension_version"`,
	extension_checked_at: string `json:"extension_checked_at"`,
}

Provider_Discovery_Report_Wire :: struct {
	request_id: string `json:"request_id"`,
	providers:  []Provider_Discovery_Item_Wire `json:"providers"`,
}

// GET /api/v1/providers
provider_catalog_list_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Provider_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp

	result, err := provider_service.list_catalog(h.providers)
	if err.code != .None do return respond_error(err, req.request_id)
	defer {
		domain.provider_catalog_destroy(result.providers)
		delete(result.catalog_etag)
	}

	body := provider_service.catalog_body_json(result.providers)
	defer delete(body)
	b := strings.builder_make()
	strings.write_string(&b, "{\"catalog_etag\":\"")
	contracts.write_json_string(&b, result.catalog_etag)
	strings.write_string(&b, "\",\"providers\":")
	// The public endpoint returns the canonical providers array without changing
	// its bytes or ordering; strip only the fixed {"providers":...} wrapper.
	strings.write_string(&b, body[len("{\"providers\":"):len(body) - 1])
	strings.write_string(&b, "}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

// GET /api/v1/providers/:provider/icon
provider_icon_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Provider_Handlers)(ctx)
	_, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp

	icon, found, err := provider_service.get_icon(h.providers, path_part(req.path, 4))
	if !found do return respond_error(err, req.request_id)
	defer domain.provider_icon_destroy(icon)

	headers := make([dynamic]contracts.HTTP_Header, 0, 2)
	append(
		&headers,
		contracts.HTTP_Header{name = "Cache-Control", value = "private, max-age=86400"},
	)
	append(&headers, contracts.HTTP_Header{name = "X-Content-Type-Options", value = "nosniff"})
	return Response {
		status = 200,
		content_type = icon.content_type,
		body = icon.content,
		headers = headers[:],
	}
}

write_bridge_provider_view_json :: proc(
	b: ^strings.Builder,
	view: provider_service.Bridge_Provider_View,
) {
	strings.write_string(
		b,
		"{\"provider\":\"",
	); write_handler_json_string(b, view.catalog.provider)
	strings.write_string(b, "\",\"profile_id\":\""); write_handler_json_string(b,view.profile_id)
	strings.write_string(b, "\",\"profile_state\":\""); write_handler_json_string(b,view.profile_state)
	strings.write_string(b, "\",\"label_enc\":\""); write_handler_json_string(b,view.label_enc)
	strings.write_string(b, "\",\"accent\":\""); write_handler_json_string(b,view.accent)
	strings.write_string(
		b,
		"\",\"display_name\":\"",
	); write_handler_json_string(b, view.catalog.display_name)
	strings.write_string(
		b,
		"\",\"icon_url\":\"",
	); write_handler_json_string(b, view.catalog.icon_url)
	strings.write_string(
		b,
		"\",\"catalog_state\":\"",
	); write_handler_json_string(b, view.catalog.state)
	strings.write_string(b, "\",\"state\":\""); write_handler_json_string(b, view.detection_state)
	strings.write_string(
		b,
		"\",\"binary_path\":\"",
	); write_handler_json_string(b, view.binary_path)
	strings.write_string(
		b,
		"\",\"version_text\":\"",
	); write_handler_json_string(b, view.version_text)
	strings.write_string(b, "\",\"checked_at\":")
	if view.checked_at ==
	   "" {strings.write_string(b, "null")} else {strings.write_byte(b, '"'); write_handler_json_string(b, view.checked_at); strings.write_byte(b, '"')}
	strings.write_string(
		b,
		",\"enabled\":",
	); strings.write_string(b, "true" if view.enabled else "false")
	strings.write_string(b, ",\"models_source\":\""); write_handler_json_string(b,view.models_source)
	strings.write_string(b, "\",\"models_state\":\""); write_handler_json_string(b,view.models_state)
	strings.write_string(b, "\",\"models_checked_at\":\""); write_handler_json_string(b,view.models_checked_at)
	strings.write_string(b, "\",\"models_attempted_at\":\""); write_handler_json_string(b,view.models_attempted_at)
	strings.write_string(b, "\",\"models_binary_path\":\""); write_handler_json_string(b,view.models_binary_path)
	strings.write_string(b, "\",\"models_version_text\":\""); write_handler_json_string(b,view.models_version_text)
	strings.write_string(b, "\",\"models_has_snapshot\":"); strings.write_string(b,"true" if view.models_has_snapshot else "false")
	write_bridge_provider_extension_json(b, view)
	strings.write_string(b, ",\"models\":[")
	for model, i in view.catalog.models {
		if i > 0 do strings.write_byte(b, ',')
		provider_service.write_model_json(b, model)
	}
	strings.write_string(b, "]}")
}

// write_bridge_provider_extension_json emits the measured extension state next to
// the catalog's install_hint and capabilities (REQ-EXT-DET-1). It is null for a
// provider whose catalog row has no extension descriptor.
write_bridge_provider_extension_json :: proc(
	b: ^strings.Builder,
	view: provider_service.Bridge_Provider_View,
) {
	strings.write_string(b, ",\"extension\":")
	if view.catalog.extension_json == "" {
		strings.write_string(b, "null")
		return
	}
	descriptor: struct {
		plugin_id:    string `json:"plugin_id"`,
		min_version:  string `json:"min_version"`,
		install_hint: string `json:"install_hint"`,
		capabilities: []string `json:"capabilities"`,
	}
	if err := json.unmarshal_string(view.catalog.extension_json, &descriptor, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
		fmt.eprintfln("ham-hub WARN provider extension descriptor unreadable provider=%s err=%v", view.catalog.provider, err)
	}
	strings.write_string(b, "{\"state\":\""); write_handler_json_string(b, view.extension_state)
	strings.write_string(b, "\",\"version\":\""); write_handler_json_string(b, view.extension_version)
	strings.write_string(b, "\",\"checked_at\":")
	if view.extension_checked_at == "" {
		strings.write_string(b, "null")
	} else {
		strings.write_byte(b, '"'); write_handler_json_string(b, view.extension_checked_at); strings.write_byte(b, '"')
	}
	strings.write_string(b, ",\"plugin_id\":\""); write_handler_json_string(b, descriptor.plugin_id)
	strings.write_string(b, "\",\"min_version\":\""); write_handler_json_string(b, descriptor.min_version)
	strings.write_string(b, "\",\"install_hint\":\""); write_handler_json_string(b, descriptor.install_hint)
	strings.write_string(b, "\",\"capabilities\":[")
	for capability, i in descriptor.capabilities {
		if i > 0 do strings.write_byte(b, ',')
		strings.write_byte(b, '"'); write_handler_json_string(b, capability); strings.write_byte(b, '"')
	}
	strings.write_string(b, "]}")
}

bridge_provider_status_response :: proc(
	h: ^Provider_Handlers,
	bridge_id, request_id, server_time: string,
) -> Response {
	views, err := provider_service.list_bridge_providers(h.providers, bridge_id)
	if err.code != .None do return respond_error(err, request_id)
	defer provider_service.bridge_provider_views_destroy(views)
	b := strings.builder_make()
	strings.write_string(&b, "{\"bridge_id\":\""); write_handler_json_string(&b, bridge_id)
	strings.write_string(&b, "\",\"providers\":[")
	for view, i in views {if i > 0 do strings.write_byte(&b, ',')
		write_bridge_provider_view_json(&b, view)}
	strings.write_string(&b, "],\"extension_commands\":[")
	if h.providers.repo != nil && h.providers.repo.list_extension_commands != nil {
		commands, command_err := iface.provider_extension_command_list(h.providers.repo, bridge_id)
		if command_err.code != .None do return respond_error(command_err, request_id)
		defer domain.provider_extension_commands_destroy(commands)
		count := 0
		for command, i in commands {
			if command.kind != "install" do continue
			latest := true
			for j in i + 1 ..< len(commands) {
				if commands[j].kind == "install" &&
				   commands[j].provider == command.provider && domain.profile_effective_id(command.provider,commands[j].profile_id)==domain.profile_effective_id(command.provider,command.profile_id) {latest = false; break}
			}
			if !latest do continue
			if count > 0 do strings.write_byte(&b, ',')
			count += 1
			payload := extension_command_json(command)
			strings.write_string(&b, payload)
			delete(payload)
		}
	}
	strings.write_string(&b, "]}")
	return respond_success(strings.to_string(b), request_id, server_time)
}

provider_owned_bridge :: proc(
	h: ^Provider_Handlers,
	req: Request,
	bridge_id: string,
) -> (
	domain.Bridge,
	bool,
	Response,
) {
	auth_ctx, auth_ok, auth_resp := require_auth(h.auth, req)
	if !auth_ok do return {}, false, auth_resp
	bridge, bridge_ok, bridge_err := bridge_service.get_bridge(h.bridges, auth_ctx, bridge_id)
	if !bridge_ok do return {}, false, respond_error(bridge_err, req.request_id)
	if bridge.status == .Revoked {
		domain.bridge_destroy(&bridge)
		return {}, false, respond_error(domain.domain_error(.Gone, "bridge is archived"), req.request_id)
	}
	return bridge, true, {}
}

// GET /api/v1/bridges/:bridge_id/provider-status -- Hub DB only.
bridge_provider_status_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Provider_Handlers)(ctx)
	bridge, ok, response := provider_owned_bridge(h, req, path_part(req.path, 4))
	if !ok do return response
	defer domain.bridge_destroy(&bridge)
	return bridge_provider_status_response(
		h,
		bridge.bridge_id,
		req.request_id,
		auth_ctx_server_time(req),
	)
}

provider_discover_command_json :: proc(request_id: string, providers: []string,profile_id: string = "") -> string {
	b := strings.builder_make()
	strings.write_string(
		&b,
		"{\"type\":\"provider_discover\",\"request_id\":\"",
	); write_handler_json_string(&b, request_id)
	strings.write_string(&b, "\",\"command_id\":\""); write_handler_json_string(&b, request_id)
	strings.write_string(&b, "\",\"profile_id\":\"");write_handler_json_string(&b,profile_id)
	strings.write_string(&b, "\",\"timeout_ms\":10000,\"providers\":[")
	for provider, i in providers {if i > 0 do strings.write_byte(&b, ','); strings.write_byte(
			&b,
			'"',
		)
		write_handler_json_string(&b, provider)
		strings.write_byte(&b, '"')}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

// POST /api/v1/bridges/:bridge_id/providers/discover
bridge_provider_discover_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Provider_Handlers)(ctx)
	bridge, ok, response := provider_owned_bridge(h, req, path_part(req.path, 4))
	if !ok do return response
	defer domain.bridge_destroy(&bridge)
	if bridge.status != .Online ||
	   !project_service.bridge_runtime_registry_has_live(
			   h.bridge_runtime_registry,
			   bridge.bridge_id,
		   ) {
		return respond_error(
			domain.domain_error(.Bridge_Offline, "bridge is not connected"),
			req.request_id,
		)
	}
	stage := json_string(req.body, "stage")
	defer delete(stage)
	if stage == "models" do return bridge_provider_models_refresh_response(h,req,bridge)
	if stage != "" && stage != "providers" do return respond_error(domain.domain_error(.Validation_Failed,"stage must be providers or models"),req.request_id)
	providers := json_string_array(req.body, "providers")
	defer {for provider in providers do delete(provider); delete(providers)}
	request_id := fmt.tprintf("pdr_%d", time.to_unix_nanoseconds(time.now()))
	profile_id:=json_string(req.body,"profile_id");defer delete(profile_id)
	command := provider_discover_command_json(request_id, providers,profile_id)
	defer delete(command)
	reply, reply_ok, reply_err := bridge_runtime_service.send_runtime_command_wait(
		h.bridge_runtime_registry,
		project_service.Runtime_Command {
			bridge_id = bridge.bridge_id,
			command_id = request_id,
			body_json = command,
		},
		10000,
	)
	if !reply_ok {
		if reply_err.code == .Bridge_Timeout {
			return Response {
				status = 504,
				content_type = "application/json",
				body = contracts.api_error_json(
					contracts.API_Error {
						code = "provider_discovery_timeout",
						message = "provider discovery timed out",
						details_json = "{}",
					},
					contracts.api_meta(req.request_id, ""),
				),
			}
		}
		return respond_error(reply_err, req.request_id)
	}
	defer delete(reply)
	report: Provider_Discovery_Report_Wire
	if decode_err := json.unmarshal_string(
		reply,
		&report,
		json.DEFAULT_SPECIFICATION,
		context.temp_allocator,
	); decode_err != nil || report.request_id != request_id {
		return respond_error(
			domain.domain_error(
				.Internal_Error,
				"bridge returned a malformed provider discovery report",
			),
			req.request_id,
		)
	}
	statuses := make(
		[]domain.Bridge_Provider_Status,
		len(report.providers),
		context.temp_allocator,
	)
	for item, i in report.providers {
		statuses[i] = domain.Bridge_Provider_Status {
			bridge_id    = bridge.bridge_id,
			provider     = item.provider,
			profile_id = item.profile_id,
			binary_path  = item.binary_path,
			version_text = item.version_text,
			state        = item.state,
			checked_at   = item.checked_at,
			extension_state      = item.extension_state,
			extension_version    = item.extension_version,
			extension_checked_at = item.extension_checked_at,
		}
	}
	if apply_err := provider_service.apply_discovery_report(h.providers, bridge.bridge_id, statuses); apply_err.code != .None do return respond_error(apply_err, req.request_id)
	// One hint after every upsert of the report, not one per provider.
	publish_bridge_provider_status_changed(h.event_bus, string(bridge.owner_user_id), bridge.bridge_id, "")
	return bridge_provider_status_response(
		h,
		bridge.bridge_id,
		req.request_id,
		auth_ctx_server_time(req),
	)
}

// PUT /api/v1/bridges/:bridge_id/providers/:provider
bridge_provider_enable_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Provider_Handlers)(ctx)
	bridge, ok, response := provider_owned_bridge(h, req, path_part(req.path, 4))
	if !ok do return response
	defer domain.bridge_destroy(&bridge)
	enabled, enabled_ok := json_bool_literal(req.body, "enabled")
	if !enabled_ok do return respond_error(domain.domain_error(.Validation_Failed, "enabled must be a JSON boolean"), req.request_id)
	provider := path_part(req.path, 6)
	profile_id:=json_string(req.body,"profile_id");defer delete(profile_id)
	setting, saved, save_err := provider_service.set_bridge_provider_enabled(
		h.providers,
		bridge.bridge_id,
		provider,
		platform.clock_now(h.clock),
		enabled,
		profile_id,
	)
	if !saved do return respond_error(save_err, req.request_id)
	publish_bridge_provider_status_changed(h.event_bus, string(bridge.owner_user_id), bridge.bridge_id, setting.provider)
	b := strings.builder_make()
	strings.write_string(&b, "{\"bridge_id\":\""); write_handler_json_string(&b, setting.bridge_id)
	strings.write_string(&b, "\",\"provider\":\""); write_handler_json_string(&b, setting.provider)
	strings.write_string(&b,"\",\"profile_id\":\"");write_handler_json_string(&b,domain.profile_effective_id(setting.provider,setting.profile_id))
	strings.write_string(
		&b,
		"\",\"enabled\":",
	); strings.write_string(&b, "true" if setting.enabled else "false")
	strings.write_string(&b, "}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

write_provider_test_json :: proc(b: ^strings.Builder, run: provider_service.Provider_Test_Run) {
	strings.write_string(b, "{\"run_id\":\""); write_handler_json_string(b, run.run_id)
	strings.write_string(b, "\",\"bridge_id\":\""); write_handler_json_string(b, run.bridge_id)
	strings.write_string(b, "\",\"provider\":\""); write_handler_json_string(b, run.provider)
	strings.write_string(b,"\",\"profile_id\":\"");write_handler_json_string(b,domain.profile_effective_id(run.provider,run.profile_id))
	strings.write_string(b, "\",\"model\":\""); write_handler_json_string(b, run.model)
	strings.write_string(
		b,
		"\",\"agent_instance_id\":\"",
	); write_handler_json_string(b, run.agent_instance_id)
	strings.write_string(b, "\",\"state\":\""); write_handler_json_string(b, run.state)
	strings.write_string(b, "\",\"expires_at\":\""); write_handler_json_string(b, run.expires_at)
	strings.write_string(b, "\",\"error\":")
	if run.error ==
	   "" {strings.write_string(b, "null")} else {strings.write_byte(b, '"'); write_handler_json_string(b, run.error); strings.write_byte(b, '"')}
	strings.write_byte(b, '}')
}

provider_test_response :: proc(
	run: provider_service.Provider_Test_Run,
	req: Request,
	status := 200,
) -> Response {
	b := strings.builder_make(); write_provider_test_json(&b, run)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), status)
}

// Starting a test supersedes any prior ephemeral test on the same owned bridge.
// Stop/delete the old instance before freeing its registry slot. Cleanup failure
// fails closed: we do not launch another potentially unbounded process.
provider_test_stop_superseded :: proc(
	h: ^Provider_Handlers,
	auth_ctx: contracts.Auth_Context,
	bridge_id: string,
) -> domain.Domain_Error {
	runs := provider_service.provider_test_active_runs_for_bridge(
		h.providers,
		auth_ctx.user_id,
		bridge_id,
	)
	defer provider_service.provider_test_runs_destroy(runs)
	for run in runs {
		cleanup_err := agent_service.cleanup_provider_test_instance(
			h.agents,
			auth_ctx,
			run.agent_instance_id,
		)
		if cleanup_err.code != .None && cleanup_err.code != .Not_Found do return cleanup_err
		cancelled, found := provider_service.provider_test_set_state(
			h.providers,
			run.run_id,
			auth_ctx.user_id,
			"cancelled",
			"superseded by a new provider test",
		)
		if found do provider_service.provider_test_run_destroy(&cancelled)
	}
	return {}
}

// POST /api/v1/bridges/:bridge_id/provider-tests
provider_test_start_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Provider_Handlers)(ctx)
	auth_ctx, auth_ok, auth_resp := require_auth(h.auth, req)
	if !auth_ok do return auth_resp
	bridge, bridge_ok, bridge_resp := provider_owned_bridge(h, req, path_part(req.path, 4))
	if !bridge_ok do return bridge_resp
	defer domain.bridge_destroy(&bridge)
	provider := json_string(req.body, "provider"); defer delete(provider)
	model := json_string(req.body, "model"); defer delete(model)
	profile_id:=json_string(req.body,"profile_id");defer delete(profile_id)
	if launch_err := provider_service.validate_launchable(h.providers, bridge.bridge_id, provider, model,profile_id); launch_err.code != .None do return respond_error(launch_err, req.request_id)
	if cleanup_err := provider_test_stop_superseded(h, auth_ctx, bridge.bridge_id); cleanup_err.code != .None do return respond_error(cleanup_err, req.request_id)
	inst, launched, launch_err := agent_service.create_provider_test_instance(
		h.agents,
		auth_ctx,
		bridge.bridge_id,
		provider,
		model,
		profile_id,
	)
	if !launched do return respond_error(launch_err, req.request_id)
	run := provider_service.Provider_Test_Run {
		profile_id = domain.profile_effective_id(provider,profile_id),
		run_id            = platform.generate_id(h.ids, "ptr_"),
		owner_user_id     = auth_ctx.user_id,
		bridge_id         = bridge.bridge_id,
		provider          = provider,
		model             = model,
		agent_instance_id = inst.agent_instance_id,
		state             = "detecting",
		expires_at        = platform.format_rfc3339_utc(
			time.time_add(time.now(), PROVIDER_TEST_TTL),
		),
	}
	saved, register_err := provider_service.provider_test_register(h.providers, run)
	if register_err.code != .None {
		_ = agent_service.cleanup_provider_test_instance(
			h.agents,
			auth_ctx,
			inst.agent_instance_id,
		)
		return respond_error(register_err, req.request_id)
	}
	defer provider_service.provider_test_run_destroy(&saved)
	if dispatch_err := agent_service.launch_provider_test_instance(h.agents, inst);
	   dispatch_err.code != .None {
		_ = agent_service.cleanup_provider_test_instance(
			h.agents,
			auth_ctx,
			inst.agent_instance_id,
		)
		failed, _ := provider_service.provider_test_set_state(
			h.providers,
			saved.run_id,
			auth_ctx.user_id,
			"failed",
			dispatch_err.message,
		)
		provider_service.provider_test_run_destroy(&failed)
		return respond_error(dispatch_err, req.request_id)
	}
	return provider_test_response(saved, req, 201)
}

provider_test_get_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Provider_Handlers)(
		ctx,
	); auth_ctx, ok, response := require_auth(h.auth, req); if !ok do return response
	run, found := provider_service.provider_test_get(
		h.providers,
		path_part(req.path, 4),
		auth_ctx.user_id,
	)
	if !found do return respond_error(domain.domain_error(.Not_Found, "provider test not found"), req.request_id)
	defer provider_service.provider_test_run_destroy(&run)
	if run.state != "stopped" &&
	   run.state != "failed" &&
	   run.state != "cancelled" &&
	   run.state != "expired" &&
	   run.expires_at != "" &&
	   run.expires_at <= platform.clock_now(h.clock) {
		_ = agent_service.cleanup_provider_test_instance(h.agents, auth_ctx, run.agent_instance_id)
		expired, _ := provider_service.provider_test_set_state(
			h.providers,
			run.run_id,
			auth_ctx.user_id,
			"expired",
			"provider test expired",
		)
		provider_service.provider_test_run_destroy(&run)
		run = expired
	}
	return provider_test_response(run, req)
}

provider_test_validate_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Provider_Handlers)(
		ctx,
	); auth_ctx, ok, response := require_auth(h.auth, req); if !ok do return response
	run_id := path_part(req.path, 4)
	run, found := provider_service.provider_test_get(h.providers, run_id, auth_ctx.user_id)
	if !found do return respond_error(domain.domain_error(.Not_Found, "provider test not found"), req.request_id)
	defer provider_service.provider_test_run_destroy(&run)
	if run.state == "stopped" do return provider_test_response(run, req)
	if run.state != "awaiting_validation" do return respond_error(domain.domain_error(.Conflict, "provider test has not reported start-success"), req.request_id)
	stopping, _ := provider_service.provider_test_set_state(
		h.providers,
		run_id,
		auth_ctx.user_id,
		"stopping",
		"",
	)
	provider_service.provider_test_run_destroy(&stopping)
	if cleanup_err := agent_service.cleanup_provider_test_instance(h.agents, auth_ctx, run.agent_instance_id); cleanup_err.code != .None do return respond_error(cleanup_err, req.request_id)
	stopped, _ := provider_service.provider_test_set_state(
		h.providers,
		run_id,
		auth_ctx.user_id,
		"stopped",
		"",
	)
	defer provider_service.provider_test_run_destroy(&stopped)
	return provider_test_response(stopped, req)
}

provider_test_cancel_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Provider_Handlers)(
		ctx,
	); auth_ctx, ok, response := require_auth(h.auth, req); if !ok do return response
	run_id := path_part(req.path, 4)
	run, found := provider_service.provider_test_get(h.providers, run_id, auth_ctx.user_id)
	if !found do return respond_error(domain.domain_error(.Not_Found, "provider test not found"), req.request_id)
	defer provider_service.provider_test_run_destroy(&run)
	if run.state == "stopped" || run.state == "cancelled" || run.state == "expired" do return provider_test_response(run, req)
	_ = agent_service.cleanup_provider_test_instance(h.agents, auth_ctx, run.agent_instance_id)
	cancelled, _ := provider_service.provider_test_set_state(
		h.providers,
		run_id,
		auth_ctx.user_id,
		"cancelled",
		"",
	)
	defer provider_service.provider_test_run_destroy(&cancelled)
	return provider_test_response(cancelled, req)
}
