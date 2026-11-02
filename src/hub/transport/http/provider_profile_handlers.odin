package http

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import bridge_runtime_service "odin_test:hub/service/bridge_runtime"
import project_service "odin_test:hub/service/project"
import provider_service "odin_test:hub/service/provider"
import jsonx "odin_test:lib/jsonx"

// GET lists metadata without contacting the bridge. Reading editable config
// uses POST /:profile/get because its request must carry a fresh sealed nonce.
bridge_provider_profiles_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Provider_Handlers)(ctx)
	bridge, ok, response := provider_owned_bridge(h, req, path_part(req.path, 4))
	if !ok do return response
	defer domain.bridge_destroy(&bridge)
	id := path_part(req.path, 6)
	if req.method == "GET" && id == "" {
		profiles, err := provider_service.list_profiles(h.providers.repo, bridge.bridge_id)
		if err.code != .None do return respond_error(err, req.request_id)
		defer domain.bridge_provider_profiles_destroy(profiles)
		bytes, jerr := json.marshal(struct {
				profiles: []domain.Bridge_Provider_Profile,
			}{profiles[:]}, allocator = context.temp_allocator)
		if jerr != nil do return respond_error(domain.domain_error(.Internal_Error, "profile list encoding failed"), req.request_id)
		return respond_success(string(bytes), req.request_id, auth_ctx_server_time(req))
	}
	if !provider_service.profile_id_valid(id) do return respond_error(domain.domain_error(.Validation_Failed, "invalid profile ID"), req.request_id)
	op := ""
	switch req.method {
	case "PUT":
		op = "upsert"
	case "DELETE":
		op = "remove"
	case "POST":
		switch path_part(req.path, 7) {
		case "get":
			op = "get"
		case "reset":
			op = "reset"
		}
	}
	if op == "" do return respond_error(domain.domain_error(.Validation_Failed, "invalid profile operation"), req.request_id)
	// A profile operation carries only opaque ciphertext, never private config.
	body: struct {
		sealed: string,
	}
	raw, parse_err := json.parse_string(
		req.body,
		json.DEFAULT_SPECIFICATION,
		true,
		context.temp_allocator,
	)
	object, is_object := raw.(json.Object)
	if parse_err != .None || !is_object || len(object) != 1 || json.unmarshal_string(req.body, &body, allocator = context.temp_allocator) != nil || !strings.has_prefix(body.sealed, "vault:v2:") || len(body.sealed) > 256 * 1024 do return respond_error(domain.domain_error(.Validation_Failed, "expected only a sealed profile operation"), req.request_id)
	if op == "remove" {
		if h.providers.repo.profile_references == nil do return respond_error(domain.domain_error(.Internal_Error, "profile references unavailable"), req.request_id)
		references, err := h.providers.repo.profile_references(
			h.providers.repo.ctx,
			bridge.bridge_id,
			id,
		)
		if err.code != .None do return respond_error(err, req.request_id)
		refs: struct {
			agents, fleets: []string,
		}
		if json.unmarshal_string(references, &refs, allocator = context.temp_allocator) != nil do return respond_error(domain.domain_error(.Internal_Error, "profile references invalid"), req.request_id)
		if len(refs.agents) + len(refs.fleets) > 0 {
			return Response {
				status = 409,
				content_type = "application/json",
				body = contracts.api_error_json(
					contracts.API_Error {
						code = "profile_in_use",
						message = "profile is referenced by agents or fleet rows",
						details_json = references,
					},
					contracts.api_meta(req.request_id, ""),
				),
			}
		}
	}
	if bridge.status != .Online || !project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry, bridge.bridge_id) do return respond_error(domain.domain_error(.Bridge_Offline, "bridge is not connected"), req.request_id)
	request_id := fmt.tprintf("ppr_%d", time.to_unix_nanoseconds(time.now()))
	// The bridge compares route binding to the authenticated inner envelope,
	// preventing a sealed remove from bypassing the in-use check via /get or PUT.
	command, jerr := json.marshal(struct {
			type, command_id, op, profile_id, sealed: string,
		} {
			"provider_profile_op",
			request_id,
			op,
			id,
			body.sealed,
		}, allocator = context.temp_allocator)
	if jerr != nil do return respond_error(domain.domain_error(.Internal_Error, "profile relay encoding failed"), req.request_id)
	reply, received, err := bridge_runtime_service.send_runtime_command_wait(
		h.bridge_runtime_registry,
		project_service.Runtime_Command {
			bridge_id = bridge.bridge_id,
			command_id = request_id,
			body_json = string(command),
		},
		10000,
	)
	if !received do return respond_error(err, req.request_id)
	defer delete(reply)
	result: struct {
		type, command_id: string,
	}
	if json.unmarshal_string(reply, &result, allocator = context.temp_allocator) != nil || result.type != "provider_profile_op_result" || result.command_id != request_id do return respond_error(domain.domain_error(.Internal_Error, "uncorrelated profile operation result"), req.request_id)
	return respond_success(reply, req.request_id, auth_ctx_server_time(req))
}

bridge_provider_profiles_frame :: proc(
	h: ^Bridge_Handlers,
	bridge_id, text: string,
) -> domain.Domain_Error {
	if h.providers == nil do return {}
	report: struct {
		ok:       bool,
		profiles: []domain.Bridge_Provider_Profile,
	}
	if json.unmarshal_string(text, &report, allocator = context.temp_allocator) != nil do return domain.domain_error(.Validation_Failed, "malformed profile report")
	// A store read error is not an authoritative empty report.
	if !report.ok || !jsonx.has_key(text, "profiles", true) do return domain.domain_error(.Validation_Failed, "profile store unavailable")
	if err := provider_service.apply_profiles_report(h.providers, bridge_id, report.profiles); err.code != .None do return err
	bridge, found, err := h.bridges.repo.get_bridge(h.bridges.repo.ctx, bridge_id)
	if found {
		publish_bridge_provider_status_changed(
			h.event_bus,
			string(bridge.owner_user_id),
			bridge_id,
			"",
		)
		domain.bridge_destroy(&bridge)
	}
	return err
}
