package http

import "base:runtime"

import "core:crypto/legacy/sha1"
import base64 "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import auth_service "odin_test:hub/service/auth"
import agent_service "odin_test:hub/service/agent"
import events "odin_test:hub/service/events"
import platform "odin_test:hub/platform"
import bridge_service "odin_test:hub/service/bridge"
import bridge_log_service "odin_test:hub/service/bridge_log"
import bridge_runtime_service "odin_test:hub/service/bridge_runtime"
import content_service "odin_test:hub/service/content"
import project_service "odin_test:hub/service/project"
import provider_service "odin_test:hub/service/provider"
import taskchain_service "odin_test:hub/service/taskchain"
import ws "odin_test:lib/ws"
import shell_session_svc "odin_test:hub/service/shell_session"
import jsonx "odin_test:lib/jsonx"
import metrics "odin_test:lib/metrics"

Bridge_Handlers :: struct {
	auth: ^auth_service.Auth_Service,
	bridges: ^bridge_service.Bridge_Service,
	agents: ^agent_service.Agent_Service,
	content: ^content_service.Content_Service,
	taskchains: ^taskchain_service.Taskchain_Service,
	projects: ^project_service.Project_Service,
	event_bus: ^events.User_Event_Bus,
	bridge_runtime_registry: ^project_service.Bridge_Runtime_Registry,
	actions: rawptr,
	scheduled_prompts: rawptr,
	shell_sessions: ^shell_session_svc.Shell_Session_Service,
	// REQ-LSP-RLY-1: live LSP relays, so lsp_* frames can be fanned out to the
	// browser socket that owns each session.
	lsp_sessions: ^Lsp_Session_Registry,
	providers: ^provider_service.Provider_Service,
	// bridge_log relay: validated entries go to this writer; the owner API
	// reads through it. nil in tests that do not wire it (entries are then
	// validated and counted but not stored).
	bridge_logs: ^bridge_log_service.Service,
}

list_bridges_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	// Accept user tokens AND bridge-relayed instance tokens so a coordinator agent
	// can DISCOVER bridges it owns (H5); list_bridges is same-owner scoped in the
	// service (owner_from_auth).
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	bridges, err := bridge_service.list_bridges(h.bridges, auth_ctx)
	if err.code != .None do return respond_error(err, req.request_id)
	b := strings.builder_make()
	strings.write_byte(&b, '[')
	for bridge, i in bridges {
		if i > 0 do strings.write_byte(&b, ',')
		write_bridge_json(&b, bridge, h.agents, h.bridges.catalog)
	}
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

bridge_detail_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	bridge_id := suffix_after(req.path, "/api/v1/bridges/")
	if strings.contains(bridge_id, "/") do return respond_error(domain.domain_error(.Not_Found, "route not found"), req.request_id)
	auth_ctx: contracts.Auth_Context
	if token, has_bearer := bearer_token(req); has_bearer {
		if rejected, resp := reject_query_or_body_token(req); rejected do return resp
		bridge_auth, bridge_ok, bridge_err := bridge_service.verify_bridge_token(h.bridges, token)
		if !bridge_ok do return respond_error(bridge_err, req.request_id)
		if bridge_auth.bridge_id != bridge_id do return respond_error(domain.domain_error(.Not_Found, "bridge not found"), req.request_id)
		auth_ctx = bridge_auth
	} else {
		user_auth, ok, auth_resp := require_auth(h.auth, req)
		if !ok do return auth_resp
		auth_ctx = user_auth
	}
	bridge, bridge_ok, err := bridge_service.get_bridge(h.bridges, auth_ctx, bridge_id)
	if !bridge_ok do return respond_error(err, req.request_id)
	b := strings.builder_make()
	write_bridge_json(&b, bridge, h.agents, h.bridges.catalog)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

rename_bridge_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	bridge_id := suffix_after(req.path, "/api/v1/bridges/")
	has_label := json_key_present(req.body, "label")
	has_telemetry := json_key_present(req.body, "telemetry_enabled")
	if !has_label && !has_telemetry {
		return respond_error(domain.domain_error(.Validation_Failed, "no supported fields to update"), req.request_id)
	}
	label := json_string(req.body, "label") if has_label else ""
	defer if has_label do delete(label)
	telemetry_enabled := json_string(req.body, "telemetry_enabled") if has_telemetry else ""
	defer if has_telemetry do delete(telemetry_enabled)

	bridge, patch_ok, err := bridge_service.patch_bridge(h.bridges, auth_ctx, bridge_id, label, has_label, telemetry_enabled, has_telemetry)
	if !patch_ok do return respond_error(err, req.request_id)
	if has_telemetry && h.bridge_runtime_registry != nil {
		// Hub-side opt-out for bridge_log frames follows the row, live or not.
		project_service.bridge_runtime_registry_set_telemetry_enabled(h.bridge_runtime_registry, bridge.bridge_id, bridge.telemetry_enabled != "disabled")
		if project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry, bridge.bridge_id) {
			enabled := bridge.telemetry_enabled == "enabled"
			cmd_id := fmt.tprintf("cmd_tel_%d", time.to_unix_nanoseconds(time.now()))
			cmd_payload := bridge_set_telemetry_payload(cmd_id, enabled, bridge.telemetry_enabled != "disabled")
			defer delete(cmd_payload)
			_, _ = bridge_runtime_service.send_runtime_command(h.bridge_runtime_registry, project_service.Runtime_Command{
				bridge_id = bridge.bridge_id,
				command_id = cmd_id,
				body_json = cmd_payload,
			})
		}
	}
	b := strings.builder_make()
	write_bridge_json(&b, bridge, h.agents, h.bridges.catalog)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

// POST /api/v1/bridges/{bridge_id}/shells/{shell_id}/input
// Delivers interactive keystrokes and raw PTY input to any target bridge shell.
bridge_shell_input_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	if auth_ctx.kind == .Bridge_Token {
		return respond_error(domain.domain_error(.Forbidden, "bridge cannot send shell input"), req.request_id)
	}

	bridge_id := path_part(req.path, 4)
	shell_id := path_part(req.path, 6)
	if strings.contains(bridge_id, "/") || strings.contains(shell_id, "/") || strings.trim_space(bridge_id) == "" || strings.trim_space(shell_id) == "" {
		return respond_error(domain.domain_error(.Not_Found, "route not found"), req.request_id)
	}

	data := json_string(req.body, "data")
	defer delete(data)
	enc_b64 := json_string(req.body, "enc_b64")
	defer delete(enc_b64)

	sink_override: project_service.Bridge_Command_Sink = {}
	if h.agents != nil {
		sink_override = h.agents.bridge_command_sink
	}

	sent, err := bridge_service.send_shell_input(h.bridges, auth_ctx, bridge_id, shell_id, data, enc_b64, sink_override, wait_for_result = true)
	if !sent do return respond_error(err, req.request_id)

	return respond_success("{\"ok\":true}", req.request_id, auth_ctx_server_time(req))
}

post_bridge_shell_input_handler :: bridge_shell_input_handler

// POST /api/v1/bridges/{bridge_id}/shells/{shell_id}/resize
// Updates the PTY terminal geometry (rows and cols) for any target bridge shell.
bridge_shell_resize_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	if auth_ctx.kind == .Bridge_Token {
		return respond_error(domain.domain_error(.Forbidden, "bridge cannot send shell resize"), req.request_id)
	}

	bridge_id := path_part(req.path, 4)
	shell_id := path_part(req.path, 6)
	if strings.contains(bridge_id, "/") || strings.contains(shell_id, "/") || strings.trim_space(bridge_id) == "" || strings.trim_space(shell_id) == "" {
		return respond_error(domain.domain_error(.Not_Found, "route not found"), req.request_id)
	}

	rows := json_int(req.body, "rows", 0)
	if rows <= 0 {
		str_val := json_string(req.body, "rows")
		defer delete(str_val)
		if parsed, ok_parse := strconv.parse_int(str_val); ok_parse do rows = int(parsed)
	}

	cols := json_int(req.body, "cols", 0)
	if cols <= 0 {
		str_val := json_string(req.body, "cols")
		defer delete(str_val)
		if parsed, ok_parse := strconv.parse_int(str_val); ok_parse do cols = int(parsed)
	}

	if rows < 1 || cols < 1 {
		return respond_error(domain.domain_error(.Validation_Failed, "rows and cols must be at least 1"), req.request_id)
	}

	sink_override: project_service.Bridge_Command_Sink = {}
	if h.agents != nil {
		sink_override = h.agents.bridge_command_sink
	}

	sent, err := bridge_service.send_shell_resize(h.bridges, auth_ctx, bridge_id, shell_id, rows, cols, sink_override)
	if !sent do return respond_error(err, req.request_id)

	return respond_success("{\"ok\":true}", req.request_id, auth_ctx_server_time(req))
}

post_bridge_shell_resize_handler :: bridge_shell_resize_handler

// --- Bridge filesystem directory management (browse/stat/mkdir) -----------
// Live pass-through to the target bridge (no hub persistence). Same owner + online
// guards as the provider relay; the bridge sandboxes every path to its fs_root.

bridge_fs_relay :: proc(h: ^Bridge_Handlers, req: Request, bridge_id, command_type, path: string) -> (string, bool, domain.Domain_Error) {
	auth_ctx, auth_ok, _ := require_auth(h.auth, req)
	if !auth_ok do return "", false, domain.domain_error(.Unauthenticated, "authentication required")
	bridge, bridge_ok, bridge_err := bridge_service.get_bridge(h.bridges, auth_ctx, bridge_id)
	if !bridge_ok do return "", false, bridge_err
	if bridge.status == .Revoked do return "", false, domain.domain_error(.Bridge_Revoked, "bridge is revoked")
	if bridge.status != .Online || !project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry, bridge.bridge_id) do return "", false, domain.domain_error(.Bridge_Offline, fmt.tprintf("Bridge %s is not connected", bridge.bridge_id))
	command_id := fmt.tprintf("cmd_fs_%d", time.to_unix_nanoseconds(time.now()))
	cmd_body := bridge_fs_command_json(command_type, command_id, path)
	reply, reply_ok, reply_err := bridge_runtime_service.send_runtime_command_wait(h.bridge_runtime_registry, project_service.Runtime_Command{bridge_id = bridge.bridge_id, command_id = command_id, body_json = cmd_body}, 10000)
	if !reply_ok do return "", false, reply_err
	// The bridge fs_* result IS the payload we return verbatim (already a flat JSON
	// object with ok/path/entries/error). Strip nothing.
	return reply, true, domain.Domain_Error{}
}

bridge_fs_command_json :: proc(command_type, command_id, path: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\""); write_handler_json_string(&b, command_type)
	strings.write_string(&b, "\",\"command_id\":\""); write_handler_json_string(&b, command_id)
	strings.write_string(&b, "\",\"path\":\""); write_handler_json_string(&b, path)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

list_bridge_dir_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := bridge_fs_relay(h, req, path_part(req.path, 4), "fs_list_dir", query_value(req.query, "path"))
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

stat_bridge_path_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := bridge_fs_relay(h, req, path_part(req.path, 4), "fs_stat", query_value(req.query, "path"))
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

mkdir_bridge_path_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := bridge_fs_relay(h, req, path_part(req.path, 4), "fs_make_dir", json_string(req.body, "path"))
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

// Hub-blind E2EE unseal relay handler (REQ-VAULT-HARDEN-3, REQ-VAULT-HARDEN-8).
// Relays blind ciphertext directly to Bridge via WS send_runtime_command_wait.
bridge_unseal_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	auth_ctx, auth_ok, auth_resp := require_auth(h.auth, req)
	if !auth_ok do return auth_resp

	bridge_id := path_part(req.path, 4)
	bridge, bridge_ok, bridge_err := bridge_service.get_bridge(h.bridges, auth_ctx, bridge_id)
	if !bridge_ok do return respond_error(bridge_err, req.request_id)
	if bridge.status == .Revoked do return respond_error(domain.domain_error(.Bridge_Revoked, "bridge is revoked"), req.request_id)
	if bridge.status != .Online || !project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry, bridge.bridge_id) {
		return respond_error(domain.domain_error(.Bridge_Offline, fmt.tprintf("Bridge %s is not connected", bridge.bridge_id)), req.request_id)
	}

	command_id := json_string(req.body, "command_id")
	defer delete(command_id)
	cmd_id := command_id
	allocated_cmd_id := false
	if cmd_id == "" {
		cmd_id = fmt.aprintf("cmd_unseal_%d", time.to_unix_nanoseconds(time.now()))
		allocated_cmd_id = true
	}
	defer if allocated_cmd_id do delete(cmd_id)

	cmd_body: string
	allocated_body := false
	trimmed := strings.trim_space(req.body)
	if strings.contains(trimmed, "\"type\"") && strings.contains(trimmed, "\"command_id\"") {
		cmd_body = trimmed
	} else {
		b := strings.builder_make()
		strings.write_string(&b, "{\"type\":\"bridge_unseal\",\"command_id\":\"")
		write_handler_json_string(&b, cmd_id)
		strings.write_string(&b, "\"")
		if strings.has_prefix(trimmed, "{") {
			strings.write_string(&b, ",")
			strings.write_string(&b, trimmed[1:])
		} else {
			strings.write_string(&b, "}")
		}
		cmd_body = strings.to_string(b)
		allocated_body = true
	}
	defer if allocated_body do delete(cmd_body)

	reply, reply_ok, reply_err := bridge_runtime_service.send_runtime_command_wait(
		h.bridge_runtime_registry,
		project_service.Runtime_Command{bridge_id = bridge.bridge_id, command_id = cmd_id, body_json = cmd_body},
		10000,
	)
	if !reply_ok do return respond_error(reply_err, req.request_id)
	return respond_success(reply, req.request_id, auth_ctx_server_time(req))
}

// Hub-blind, single-target task-chain search relay. The Hub authorizes only the
// target Bridge and forwards the armored envelope without possessing its key.
task_chain_search_command_json :: proc(command_id, bridge_id, owner_user_id, request_id: string, expires_at_ms: i64, envelope: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"type":"task_chain_search","command_id":"`); write_handler_json_string(&b, command_id)
	strings.write_string(&b, `","bridge_id":"`); write_handler_json_string(&b, bridge_id)
	strings.write_string(&b, `","owner_user_id":"`); write_handler_json_string(&b, owner_user_id)
	strings.write_string(&b, `","request_id":"`); write_handler_json_string(&b, request_id)
	strings.write_string(&b, `","expires_at_ms":`); strings.write_int(&b, int(expires_at_ms))
	strings.write_string(&b, `,"envelope":"`); write_handler_json_string(&b, envelope)
	strings.write_string(&b, `"}`)
	return strings.to_string(b)
}

task_chain_search_relay_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	auth_ctx, auth_ok, auth_resp := require_auth(h.auth, req)
	if !auth_ok do return auth_resp
	if len(req.body) > 36_000 do return respond_error(domain.domain_error(.Validation_Failed, "search envelope exceeds size limit"), req.request_id)
	bridge_id := json_string(req.body, "bridge_id"); defer delete(bridge_id)
	request_id := json_string(req.body, "request_id"); defer delete(request_id)
	envelope := json_string(req.body, "envelope"); defer delete(envelope)
	expires_at_ms := i64(json_int(req.body, "expires_at_ms", 0))
	if bridge_id == "" || request_id == "" || len(request_id) > 128 || !strings.has_prefix(envelope, "search:v1:") || len(envelope) > 32_768 {
		return respond_error(domain.domain_error(.Validation_Failed, "invalid search envelope"), req.request_id)
	}
	now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000
	if expires_at_ms < now_ms || expires_at_ms > now_ms + 5_000 {
		return respond_error(domain.domain_error(.Validation_Failed, "search envelope expired"), req.request_id)
	}
	bridge, bridge_ok, bridge_err := bridge_service.get_bridge(h.bridges, auth_ctx, bridge_id)
	if !bridge_ok do return respond_error(bridge_err, req.request_id)
	if bridge.status != .Online || !project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry, bridge.bridge_id) {
		return respond_error(domain.domain_error(.Bridge_Offline, "target bridge is offline"), req.request_id)
	}
	command_id := fmt.tprintf("cmd_search_%d", time.to_unix_nanoseconds(time.now())); defer delete(command_id)
	cmd_body := task_chain_search_command_json(command_id, bridge_id, auth_ctx.user_id, request_id, expires_at_ms, envelope); defer delete(cmd_body)
	reply, reply_ok, reply_err := bridge_runtime_service.send_runtime_command_wait(
		h.bridge_runtime_registry,
		project_service.Runtime_Command{bridge_id = bridge.bridge_id, command_id = command_id, body_json = cmd_body},
		5000,
	)
	if !reply_ok do return respond_error(reply_err, req.request_id)
	return respond_success(reply, req.request_id, auth_ctx_server_time(req))
}

bridge_public_key_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	auth_ctx, auth_ok, auth_resp := require_auth(h.auth, req)
	if !auth_ok do return auth_resp

	bridge_id := path_part(req.path, 4)
	bridge, bridge_ok, bridge_err := bridge_service.get_bridge(h.bridges, auth_ctx, bridge_id)
	if !bridge_ok do return respond_error(bridge_err, req.request_id)

	pub_key := ""
	owned_key := ""
	defer delete(owned_key)
	if h.bridge_runtime_registry != nil {
		owned_key = project_service.bridge_runtime_registry_public_key(h.bridge_runtime_registry, bridge.bridge_id)
		pub_key = owned_key
	}
	if pub_key == "" && bridge.capabilities_json != "" {
		pub_key = json_string(bridge.capabilities_json, "public_key", context.temp_allocator)
	}

	b := strings.builder_make()
	strings.write_string(&b, "{\"bridge_id\":\"")
	write_handler_json_string(&b, bridge.bridge_id)
	strings.write_string(&b, "\",\"public_key\":\"")
	write_handler_json_string(&b, pub_key)
	strings.write_string(&b, "\",\"bridge_public_key\":\"")
	write_handler_json_string(&b, pub_key)
	strings.write_string(&b, "\"}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

bridge_lock_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	auth_ctx, auth_ok, auth_resp := require_auth(h.auth, req)
	if !auth_ok do return auth_resp

	bridge_id := path_part(req.path, 4)
	bridge, bridge_ok, bridge_err := bridge_service.get_bridge(h.bridges, auth_ctx, bridge_id)
	if !bridge_ok do return respond_error(bridge_err, req.request_id)
	if bridge.status == .Revoked do return respond_error(domain.domain_error(.Bridge_Revoked, "bridge is revoked"), req.request_id)
	if bridge.status != .Online || !project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry, bridge.bridge_id) {
		return respond_error(domain.domain_error(.Bridge_Offline, fmt.tprintf("Bridge %s is not connected", bridge.bridge_id)), req.request_id)
	}

	command_id := json_string(req.body, "command_id")
	defer delete(command_id)
	cmd_id := command_id
	allocated_cmd_id := false
	if cmd_id == "" {
		cmd_id = fmt.aprintf("cmd_lock_%d", time.to_unix_nanoseconds(time.now()))
		allocated_cmd_id = true
	}
	defer if allocated_cmd_id do delete(cmd_id)

	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"bridge_lock\",\"command_id\":\"")
	write_handler_json_string(&b, cmd_id)
	strings.write_string(&b, "\"}")
	cmd_body := strings.to_string(b)
	defer delete(cmd_body)

	reply, reply_ok, reply_err := bridge_runtime_service.send_runtime_command_wait(
		h.bridge_runtime_registry,
		project_service.Runtime_Command{bridge_id = bridge.bridge_id, command_id = cmd_id, body_json = cmd_body},
		10000,
	)
	if !reply_ok do return respond_error(reply_err, req.request_id)
	return respond_success(reply, req.request_id, auth_ctx_server_time(req))
}

// --- Project-scoped filesystem browser (browse/read/CRUD) -----------------
// Resolves (project_id -> bridge_id, root_path) via Project_Bridge_Path, then
// relays a WS command carrying that project root so the bridge re-sandboxes every
// path to the project (not the whole bridge fs_root). Same owner + online guards
// as bridge_fs_relay. Request paths are RELATIVE to the project root. The bridge
// result JSON is returned verbatim (already the flat {ok,...,error} envelope).

Project_Fs_Command :: struct {
	command_type: string,
	path:         string, // primary path (relative to project root)
	// list options
	include_hidden: bool,
	send_include_hidden: bool,
	cursor: string,
	limit:  int,
	send_limit: bool,
	// move
	from: string,
	to:   string,
	send_from_to: bool,
	// delete
	recursive: bool,
	send_recursive: bool,
	// read-file byte-range pagination
	offset: int,
	send_offset: bool,
	read_limit: int,
	send_read_limit: bool,
	// single-file write
	content: string,
	send_content: bool,
	// multi-file batch write
	raw_files_json: string,
	send_raw_files: bool,
	// search / quick-open options
	query: string,
	send_query: bool,
	case_sensitive: bool,
	send_case_sensitive: bool,
}

project_fs_relay :: proc(h: ^Bridge_Handlers, req: Request, cmd: Project_Fs_Command) -> (string, bool, domain.Domain_Error) {
	auth_ctx, auth_ok, _ := require_auth(h.auth, req)
	if !auth_ok do return "", false, domain.domain_error(.Unauthenticated, "authentication required")
	project_id := domain.Project_ID(path_part(req.path, 4))
	bridge_hint := query_value(req.query, "bridge_id")
	target, target_ok, target_err := project_service.resolve_fs_target(h.projects, auth_ctx, project_id, bridge_hint)
	if !target_ok do return "", false, target_err
	bridge, bridge_ok, bridge_err := bridge_service.get_bridge(h.bridges, auth_ctx, target.bridge_id)
	if !bridge_ok do return "", false, bridge_err
	if bridge.status == .Revoked do return "", false, domain.domain_error(.Bridge_Revoked, "bridge is revoked")
	if bridge.status != .Online || !project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry, bridge.bridge_id) do return "", false, domain.domain_error(.Bridge_Offline, fmt.tprintf("Bridge %s is not connected", bridge.bridge_id))
	command_id := fmt.tprintf("cmd_pfs_%d", time.to_unix_nanoseconds(time.now()))
	cmd_body := project_fs_command_json(cmd, command_id, target.root_path)
	reply, reply_ok, reply_err := bridge_runtime_service.send_runtime_command_wait(h.bridge_runtime_registry, project_service.Runtime_Command{bridge_id = bridge.bridge_id, command_id = command_id, body_json = cmd_body}, 10000)
	if !reply_ok do return "", false, reply_err
	return reply, true, domain.Domain_Error{}
}

project_fs_command_json :: proc(cmd: Project_Fs_Command, command_id, root_path: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\""); write_handler_json_string(&b, cmd.command_type)
	strings.write_string(&b, "\",\"command_id\":\""); write_handler_json_string(&b, command_id)
	strings.write_string(&b, "\",\"root\":\""); write_handler_json_string(&b, root_path)
	strings.write_string(&b, "\"")
	if cmd.send_from_to {
		strings.write_string(&b, ",\"from\":\""); write_handler_json_string(&b, cmd.from)
		strings.write_string(&b, "\",\"to\":\""); write_handler_json_string(&b, cmd.to); strings.write_string(&b, "\"")
	} else {
		strings.write_string(&b, ",\"path\":\""); write_handler_json_string(&b, cmd.path); strings.write_string(&b, "\"")
	}
	if cmd.send_include_hidden {
		strings.write_string(&b, ",\"include_hidden\":"); strings.write_string(&b, "true" if cmd.include_hidden else "false")
	}
	if cmd.cursor != "" {
		strings.write_string(&b, ",\"cursor\":\""); write_handler_json_string(&b, cmd.cursor); strings.write_string(&b, "\"")
	}
	if cmd.send_limit {
		strings.write_string(&b, ",\"limit\":"); strings.write_int(&b, cmd.limit)
	}
	if cmd.send_recursive {
		strings.write_string(&b, ",\"recursive\":"); strings.write_string(&b, "true" if cmd.recursive else "false")
	}
	if cmd.send_offset {
		strings.write_string(&b, ",\"offset\":"); strings.write_int(&b, cmd.offset)
	}
	if cmd.send_read_limit {
		strings.write_string(&b, ",\"limit\":"); strings.write_int(&b, cmd.read_limit)
	}
	if cmd.send_content {
		strings.write_string(&b, ",\"content\":\""); write_handler_json_string(&b, cmd.content); strings.write_string(&b, "\"")
	}
	if cmd.send_raw_files {
		strings.write_string(&b, ",\"files\":"); strings.write_string(&b, cmd.raw_files_json)
	}
	if cmd.send_query {
		strings.write_string(&b, ",\"query\":\""); write_handler_json_string(&b, cmd.query); strings.write_string(&b, "\"")
	}
	if cmd.send_case_sensitive {
		strings.write_string(&b, ",\"case_sensitive\":"); strings.write_string(&b, "true" if cmd.case_sensitive else "false")
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

list_project_dir_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	limit := query_int(req.query, "limit", 0)
	result, ok, err := project_fs_relay(h, req, Project_Fs_Command{
		command_type = "fs_list_dir",
		path = query_value(req.query, "path"),
		include_hidden = query_bool(req.query, "include_hidden", false), send_include_hidden = true,
		cursor = query_value(req.query, "cursor"),
		limit = limit, send_limit = limit > 0,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

read_project_file_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	// Byte-range pagination: ?offset= (default 0) & ?limit= (bytes; 0 = bridge
	// default page). Lets the UI stream a large text file in chunks over the
	// size-limited WS relay instead of one frame that times out.
	offset := query_int(req.query, "offset", 0)
	rlimit := query_int(req.query, "limit", 0)
	result, ok, err := project_fs_relay(h, req, Project_Fs_Command{
		command_type = "fs_read_file",
		path = query_value(req.query, "path"),
		offset = offset, send_offset = offset > 0,
		read_limit = rlimit, send_read_limit = rlimit > 0,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

create_project_file_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := project_fs_relay(h, req, Project_Fs_Command{command_type = "fs_create_file", path = json_string(req.body, "path")})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

write_project_file_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	path := json_string(req.body, "path")
	if path == "" do return respond_error(domain.domain_error(.Validation_Failed, "path is required"), req.request_id)
	content := json_string(req.body, "content")
	result, ok, err := project_fs_relay(h, req, Project_Fs_Command{
		command_type = "fs_write_file",
		path = path,
		content = content,
		send_content = true,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

batch_write_project_files_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	files_json, has_files := json_array_raw_balanced(req.body, "files")
	if !has_files {
		trimmed := strings.trim_space(req.body)
		if strings.has_prefix(trimmed, "[") && strings.has_suffix(trimmed, "]") {
			files_json = trimmed
			has_files = true
		}
	}
	if !has_files do return respond_error(domain.domain_error(.Validation_Failed, "files array is required"), req.request_id)
	result, ok, err := project_fs_relay(h, req, Project_Fs_Command{
		command_type = "fs_batch_write",
		raw_files_json = files_json,
		send_raw_files = true,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

create_project_dir_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := project_fs_relay(h, req, Project_Fs_Command{command_type = "fs_make_dir", path = json_string(req.body, "path")})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

move_project_path_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := project_fs_relay(h, req, Project_Fs_Command{command_type = "fs_move", from = json_string(req.body, "from"), to = json_string(req.body, "to"), send_from_to = true})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

delete_project_path_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := project_fs_relay(h, req, Project_Fs_Command{command_type = "fs_delete", path = query_value(req.query, "path"), recursive = query_bool(req.query, "recursive", false), send_recursive = true})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

// --- Task-chain directory filesystem browser (browse/read/CRUD/search) -----
// Resolves (chain_id, directory_id -> bridge_id, dir.path) via taskchain service.
// Guards ownership and chain membership (require_auth_any + get_chain), then
// relays a WS command carrying dir.path as root so the bridge sandboxes every
// path to the directory root. Same online + live guards as project_fs_relay.

directory_fs_relay :: proc(h: ^Bridge_Handlers, req: Request, cmd: Project_Fs_Command) -> (string, bool, domain.Domain_Error) {
	auth_ctx, auth_ok, _ := require_auth_any(h.auth, req)
	if !auth_ok do return "", false, domain.domain_error(.Unauthenticated, "authentication required")
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	dir_id := path_part(req.path, 6)
	if string(chain_id) == "" || dir_id == "" {
		return "", false, domain.domain_error(.Validation_Failed, "chain_id and directory_id are required")
	}
	dir, dir_ok, dir_err := taskchain_service.get_chain_directory(h.taskchains, auth_ctx, chain_id, dir_id)
	if !dir_ok do return "", false, dir_err

	bridge_id := dir.bridge_id
	if bridge_id == "" {
		bridge_id = query_value(req.query, "bridge_id")
	}
	if bridge_id == "" {
		if bridges, list_err := bridge_service.list_bridges(h.bridges, auth_ctx); list_err.code == .None {
			if len(bridges) == 1 {
				bridge_id = bridges[0].bridge_id
			} else {
				for b in bridges {
					if b.bridge_id == "brg_local" {
						bridge_id = "brg_local"
						break
					}
				}
			}
		}
	}
	if bridge_id == "" {
		return "", false, domain.domain_error(.Validation_Failed, "bridge_id is required or directory has no bridge configured")
	}

	bridge, bridge_ok, bridge_err := bridge_service.get_bridge(h.bridges, auth_ctx, bridge_id)
	if !bridge_ok do return "", false, bridge_err
	if bridge.status == .Revoked do return "", false, domain.domain_error(.Bridge_Revoked, "bridge is revoked")
	if bridge.status != .Online || !project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry, bridge.bridge_id) {
		return "", false, domain.domain_error(.Bridge_Offline, fmt.tprintf("Bridge %s is not connected", bridge.bridge_id))
	}

	command_id := fmt.tprintf("cmd_cdfs_%d", time.to_unix_nanoseconds(time.now()))
	cmd_body := project_fs_command_json(cmd, command_id, dir.path)
	reply, reply_ok, reply_err := bridge_runtime_service.send_runtime_command_wait(h.bridge_runtime_registry, project_service.Runtime_Command{bridge_id = bridge.bridge_id, command_id = command_id, body_json = cmd_body}, 10000)
	if !reply_ok do return "", false, reply_err
	return reply, true, domain.Domain_Error{}
}

list_chain_directory_fs_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	limit := query_int(req.query, "limit", 0)
	result, ok, err := directory_fs_relay(h, req, Project_Fs_Command{
		command_type = "fs_list_dir",
		path = query_value(req.query, "path"),
		include_hidden = query_bool(req.query, "include_hidden", false),
		send_include_hidden = true,
		cursor = query_value(req.query, "cursor"),
		limit = limit,
		send_limit = limit > 0,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

read_chain_directory_file_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	offset := query_int(req.query, "offset", 0)
	rlimit := query_int(req.query, "limit", 0)
	result, ok, err := directory_fs_relay(h, req, Project_Fs_Command{
		command_type = "fs_read_file",
		path = query_value(req.query, "path"),
		offset = offset,
		send_offset = offset > 0,
		read_limit = rlimit,
		send_read_limit = rlimit > 0,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

create_chain_directory_file_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := directory_fs_relay(h, req, Project_Fs_Command{command_type = "fs_create_file", path = json_string(req.body, "path")})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

write_chain_directory_file_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	path := json_string(req.body, "path")
	if path == "" do return respond_error(domain.domain_error(.Validation_Failed, "path is required"), req.request_id)
	content := json_string(req.body, "content")
	result, ok, err := directory_fs_relay(h, req, Project_Fs_Command{
		command_type = "fs_write_file",
		path = path,
		content = content,
		send_content = true,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

batch_write_chain_directory_files_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	files_json, has_files := json_array_raw_balanced(req.body, "files")
	if !has_files {
		trimmed := strings.trim_space(req.body)
		if strings.has_prefix(trimmed, "[") && strings.has_suffix(trimmed, "]") {
			files_json = trimmed
			has_files = true
		}
	}
	if !has_files do return respond_error(domain.domain_error(.Validation_Failed, "files array is required"), req.request_id)
	result, ok, err := directory_fs_relay(h, req, Project_Fs_Command{
		command_type = "fs_batch_write",
		raw_files_json = files_json,
		send_raw_files = true,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

create_chain_directory_dir_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := directory_fs_relay(h, req, Project_Fs_Command{command_type = "fs_make_dir", path = json_string(req.body, "path")})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

move_chain_directory_path_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := directory_fs_relay(h, req, Project_Fs_Command{command_type = "fs_move", from = json_string(req.body, "from"), to = json_string(req.body, "to"), send_from_to = true})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

delete_chain_directory_path_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := directory_fs_relay(h, req, Project_Fs_Command{command_type = "fs_delete", path = query_value(req.query, "path"), recursive = query_bool(req.query, "recursive", false), send_recursive = true})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

quick_open_chain_directory_fs_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	query := query_value(req.query, "query")
	limit := query_int(req.query, "limit", 100)
	result, ok, err := directory_fs_relay(h, req, Project_Fs_Command{
		command_type = "fs_find_files",
		query = query,
		send_query = true,
		limit = limit,
		send_limit = limit > 0,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

search_chain_directory_fs_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	query := query_value(req.query, "query")
	case_sensitive := query_bool(req.query, "case_sensitive", false)
	limit := query_int(req.query, "limit", 100)
	result, ok, err := directory_fs_relay(h, req, Project_Fs_Command{
		command_type = "fs_grep",
		query = query,
		send_query = true,
		case_sensitive = case_sensitive,
		send_case_sensitive = true,
		limit = limit,
		send_limit = limit > 0,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}


// --- Project-scoped VCS relay (read-only) ---------------------------------
// Resolves (project_id -> bridge_id, root_path) exactly like project_fs_relay,
// then relays a read-only vcs_* WS command carrying the project root so the
// bridge computes VCS status/diff against the project checkout. Same owner +
// online guards as project_fs_relay. The bridge result JSON is returned verbatim.

Project_Vcs_Command :: struct {
	command_type:  string, // vcs_capabilities | vcs_status | vcs_files | vcs_diff | vcs_log | vcs_commit_diff | vcs_workspaces | vcs_stage | vcs_unstage | vcs_revert
	path:          string, // file path for diff/write commands; empty for others
	cursor:        string,
	limit:         int,
	base_ref:      string, // vcs_commit_diff: compare base
	head_ref:      string, // vcs_commit_diff: compare head (empty/WORKDIR = worktree)
	content:       string, // vcs_save_file: full file text to write
	message:       string, // vcs_commit: commit message
	list_files:    bool, // vcs_commit_diff: return a changed-file list instead of hunks
	amend:         bool, // vcs_commit: amend the parent commit/CL
	send_path:     bool, // whether to include path in JSON body
	send_cursor:   bool,
	send_limit:    bool,
	send_base_ref: bool,
	send_head_ref: bool,
	send_content:  bool, // whether to include content in JSON body
	send_list_files: bool, // whether to include list_files in JSON body
	send_message:  bool, // whether to include message in JSON body
	send_amend:    bool, // whether to include amend in JSON body
}

project_vcs_relay :: proc(h: ^Bridge_Handlers, req: Request, cmd: Project_Vcs_Command) -> (string, bool, domain.Domain_Error) {
	auth_ctx, auth_ok, _ := require_auth(h.auth, req)
	if !auth_ok do return "", false, domain.domain_error(.Unauthenticated, "authentication required")
	project_id := domain.Project_ID(path_part(req.path, 4))
	bridge_hint := query_value(req.query, "bridge_id")
	target, target_ok, target_err := project_service.resolve_fs_target(h.projects, auth_ctx, project_id, bridge_hint)
	if !target_ok do return "", false, target_err
	bridge, bridge_ok, bridge_err := bridge_service.get_bridge(h.bridges, auth_ctx, target.bridge_id)
	if !bridge_ok do return "", false, bridge_err
	if bridge.status == .Revoked do return "", false, domain.domain_error(.Bridge_Revoked, "bridge is revoked")
	if bridge.status != .Online || !project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry, bridge.bridge_id) do return "", false, domain.domain_error(.Bridge_Offline, fmt.tprintf("Bridge %s is not connected", bridge.bridge_id))
	// Resolve the effective repo root, honoring an optional ?worktree_path override
	// validated against the bridge's vcs_workspaces whitelist (path-traversal guard).
	root_path, root_ok, root_err := project_vcs_effective_root(h, req, bridge.bridge_id, target.root_path)
	if !root_ok do return "", false, root_err
	return project_vcs_send(h, bridge.bridge_id, cmd, root_path)
}

vcs_command_timeout_ms :: proc(command_type: string) -> int {
	switch command_type {
	case "vcs_upload", "vcs_push", "vcs_sync", "vcs_pull":
		return 120_000
	}
	return 10_000
}

// project_vcs_send builds the vcs_* WS command carrying root_path and relays it to
// the bridge, returning the bridge result JSON verbatim.
project_vcs_send :: proc(h: ^Bridge_Handlers, bridge_id: string, cmd: Project_Vcs_Command, root_path: string) -> (string, bool, domain.Domain_Error) {
	command_id := fmt.tprintf("cmd_pvcs_%d", time.to_unix_nanoseconds(time.now()))
	cmd_body := project_vcs_command_json(cmd, command_id, root_path)
	reply, reply_ok, reply_err := bridge_runtime_service.send_runtime_command_wait(h.bridge_runtime_registry, project_service.Runtime_Command{bridge_id = bridge_id, command_id = command_id, body_json = cmd_body}, vcs_command_timeout_ms(cmd.command_type))
	if !reply_ok do return "", false, reply_err
	return reply, true, domain.Domain_Error{}
}

// project_vcs_effective_root resolves the repo root the vcs_* command runs against.
// Absent/empty ?worktree_path keeps the project's registered root_path (unchanged
// behavior). When supplied, the path must be absolute AND appear in the bridge's
// vcs_workspaces list for the project root; otherwise the request is rejected with
// HTTP 400 (validation_failed). This is the path-traversal guard: only paths the
// bridge itself advertises as workspaces may be targeted.
project_vcs_effective_root :: proc(h: ^Bridge_Handlers, req: Request, bridge_id: string, root_path: string) -> (string, bool, domain.Domain_Error) {
	worktree := strings.trim_space(query_value(req.query, "worktree_path"))
	if worktree == "" do return root_path, true, domain.Domain_Error{}
	if !strings.has_prefix(worktree, "/") do return "", false, worktree_path_rejected_error(worktree)
	ws_reply, ws_ok, ws_err := project_vcs_send(h, bridge_id, Project_Vcs_Command{command_type = "vcs_workspaces"}, root_path)
	if !ws_ok do return "", false, ws_err
	if vcs_workspaces_has_path(ws_reply, worktree) do return worktree, true, domain.Domain_Error{}
	return "", false, worktree_path_rejected_error(worktree)
}

// worktree_path_rejected_error is the shared 400 for a worktree_path that is not in
// the project's vcs_workspaces whitelist. details carries the machine-readable code
// and the supplied path so callers can surface exactly which override was refused.
worktree_path_rejected_error :: proc(supplied: string) -> domain.Domain_Error {
	b := strings.builder_make()
	strings.write_string(&b, "{\"error\":\"worktree_path_not_in_workspaces\",\"path\":\"")
	write_handler_json_string(&b, supplied)
	strings.write_string(&b, "\"}")
	return domain.domain_error(.Validation_Failed, "worktree_path_not_in_workspaces", strings.to_string(b))
}

// vcs_workspaces_has_path reports whether target exactly equals one of the workspace
// paths in a vcs_workspaces_result. Each workspace object carries a single "path"
// member; we scan every one in the workspaces array and compare unescaped values.
vcs_workspaces_has_path :: proc(ws_reply, target: string) -> bool {
	parsed, err := json.parse_string(ws_reply, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	defer json.destroy_value(parsed, context.temp_allocator)
	if err != .None do return false
	val, ok := jsonx.find_value(parsed, "workspaces", false)
	if !ok do return false
	arr, is_arr := val.(json.Array)
	if !is_arr do return false
	for item in arr {
		if obj, is_obj := item.(json.Object); is_obj {
			if path_val, path_ok := obj["path"]; path_ok {
				if path_str, is_str := path_val.(json.String); is_str {
					if string(path_str) == target do return true
				}
			}
		}
	}
	return false
}

project_vcs_command_json :: proc(cmd: Project_Vcs_Command, command_id, root_path: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\""); write_handler_json_string(&b, cmd.command_type)
	strings.write_string(&b, "\",\"command_id\":\""); write_handler_json_string(&b, command_id)
	strings.write_string(&b, "\",\"root\":\""); write_handler_json_string(&b, root_path)
	strings.write_string(&b, "\"")
	if cmd.send_path {
		strings.write_string(&b, ",\"path\":\""); write_handler_json_string(&b, cmd.path); strings.write_string(&b, "\"")
	}
	if cmd.send_base_ref {
		strings.write_string(&b, ",\"base_ref\":\""); write_handler_json_string(&b, cmd.base_ref); strings.write_string(&b, "\"")
	}
	if cmd.send_head_ref {
		strings.write_string(&b, ",\"head_ref\":\""); write_handler_json_string(&b, cmd.head_ref); strings.write_string(&b, "\"")
	}
	if cmd.send_cursor && cmd.cursor != "" {
		strings.write_string(&b, ",\"cursor\":\""); write_handler_json_string(&b, cmd.cursor); strings.write_string(&b, "\"")
	}
	if cmd.send_limit {
		strings.write_string(&b, ",\"limit\":"); strings.write_int(&b, cmd.limit)
	}
	if cmd.send_content {
		strings.write_string(&b, ",\"content\":\""); write_handler_json_string(&b, cmd.content); strings.write_string(&b, "\"")
	}
	if cmd.send_list_files && cmd.list_files {
		strings.write_string(&b, ",\"list_files\":true")
	}
	if cmd.send_message && cmd.message != "" {
		strings.write_string(&b, ",\"message\":\""); write_handler_json_string(&b, cmd.message); strings.write_string(&b, "\"")
	}
	if cmd.send_amend {
		strings.write_string(&b, ",\"amend\":"); strings.write_string(&b, "true" if cmd.amend else "false")
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

project_handle_vcs_capabilities :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := project_vcs_relay(h, req, Project_Vcs_Command{command_type = "vcs_capabilities"})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

project_handle_vcs_status :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := project_vcs_relay(h, req, Project_Vcs_Command{command_type = "vcs_status"})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

project_handle_vcs_files :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := project_vcs_relay(h, req, Project_Vcs_Command{
		command_type = "vcs_files",
		cursor = query_value(req.query, "cursor"), send_cursor = true,
		limit = query_int(req.query, "limit", 100), send_limit = true,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

project_handle_vcs_diff :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	// Accept either "file" or "path" as the query param (diff-view fallback from
	// origin/main ae48d955): the file panel calls with "path", the VCS tab with "file".
	file := query_value(req.query, "file")
	if file == "" do file = query_value(req.query, "path")
	result, ok, err := project_vcs_relay(h, req, Project_Vcs_Command{
		command_type = "vcs_diff",
		path = file, send_path = true,
		cursor = query_value(req.query, "cursor"), send_cursor = true,
		limit = query_int(req.query, "limit", 50), send_limit = true,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

project_handle_vcs_log :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := project_vcs_relay(h, req, Project_Vcs_Command{
		command_type = "vcs_log",
		cursor = query_value(req.query, "cursor"), send_cursor = true,
		limit = query_int(req.query, "limit", 50), send_limit = true,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

project_handle_vcs_commit_diff :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	// list_files mode returns a flat changed-file list (not paginated), so cursor and
	// limit are only forwarded in the default hunk mode.
	list_files := query_bool(req.query, "list_files", false)
	result, ok, err := project_vcs_relay(h, req, Project_Vcs_Command{
		command_type = "vcs_commit_diff",
		base_ref = query_value(req.query, "base_ref"), send_base_ref = true,
		head_ref = query_value(req.query, "head_ref"), send_head_ref = true,
		path = query_value(req.query, "file"), send_path = true,
		list_files = list_files, send_list_files = true,
		cursor = query_value(req.query, "cursor"), send_cursor = !list_files,
		limit = query_int(req.query, "limit", 50), send_limit = !list_files,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

project_handle_vcs_workspaces :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := project_vcs_relay(h, req, Project_Vcs_Command{command_type = "vcs_workspaces"})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

// project_handle_vcs_write is the shared body for the stage/unstage/revert POST
// endpoints: it maps the JSON body {"file":"<relative-path>"} onto the bridge write
// command's "path" field and relays it. Not cached (mutation).
project_handle_vcs_write :: proc(h: ^Bridge_Handlers, req: Request, command_type: string) -> Response {
	result, ok, err := project_vcs_relay(h, req, Project_Vcs_Command{
		command_type = command_type,
		path = json_string(req.body, "file"), send_path = true,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

project_handle_vcs_stage :: proc(ctx: rawptr, req: Request) -> Response {
	return project_handle_vcs_write((^Bridge_Handlers)(ctx), req, "vcs_stage")
}

project_handle_vcs_unstage :: proc(ctx: rawptr, req: Request) -> Response {
	return project_handle_vcs_write((^Bridge_Handlers)(ctx), req, "vcs_unstage")
}

project_handle_vcs_revert :: proc(ctx: rawptr, req: Request) -> Response {
	return project_handle_vcs_write((^Bridge_Handlers)(ctx), req, "vcs_revert")
}

// project_handle_vcs_save_file relays an editor save: body {"file":"<relative>",
// "content":"<full text>"[, "worktree_path":".."]} maps onto the bridge vcs_save_file
// command's "path"/"content" fields. worktree_path (query) is validated against the
// vcs_workspaces whitelist by project_vcs_relay like every other write. Not cached.
project_handle_vcs_save_file :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	file := json_string(req.body, "file")
	if file == "" do return respond_error(domain.domain_error(.Validation_Failed, "file is required"), req.request_id)
	result, ok, err := project_vcs_relay(h, req, Project_Vcs_Command{
		command_type = "vcs_save_file",
		path = file, send_path = true,
		content = json_string(req.body, "content"), send_content = true,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

// project_handle_vcs_commit relays a commit: body {"message":"<text>"[, "worktree_path"]}
// maps onto the bridge vcs_commit command's "message" field. worktree_path (query) is
// validated against the vcs_workspaces whitelist by project_vcs_relay like every other
// write. Not cached (mutation). An empty message is rejected with 400 before relaying.
project_handle_vcs_commit :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	message := strings.trim_space(json_string(req.body, "message"))
	if message == "" do return respond_error(domain.domain_error(.Validation_Failed, "message is required"), req.request_id)
	amend := json_bool(req.body, "amend")
	result, ok, err := project_vcs_relay(h, req, Project_Vcs_Command{
		command_type = "vcs_commit",
		message = message, send_message = true,
		amend = amend, send_amend = true,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

// project_handle_vcs_upload relays an upload mutation: runs provider.upload on the
// project repository (e.g. `hg upload chain` for fig).
project_handle_vcs_upload :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := project_vcs_relay(h, req, Project_Vcs_Command{
		command_type = "vcs_upload",
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

// project_handle_vcs_sync relays a sync mutation: runs provider.sync on the
// project repository (e.g. `hg sync` or `git pull --rebase`).
project_handle_vcs_sync :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := project_vcs_relay(h, req, Project_Vcs_Command{
		command_type = "vcs_sync",
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

// --- Agent instance run-dir browser (READ-ONLY) ---------------------------
// Resolves (instance_id -> owner-checked instance -> bridge_id) then relays a
// read-only agent_run_dir_* command carrying the instance_id. The bridge computes
// the run dir from the id (bridge_runtime_default_run_dir) and re-sandboxes every
// path to it, so the hub never needs to know the run-dir layout. Two-layer owner
// check: get_instance is same-owner scoped (Not_Found for others) and get_bridge
// is owner-scoped. Request paths are RELATIVE to the run-dir root. No mutation
// commands exist for this surface (read-only by construction). The bridge reuses
// the fs_list_dir_result / fs_read_file_result envelopes, returned verbatim.

Instance_Fs_Command :: struct {
	command_type:        string,
	path:                string, // relative to the instance run-dir root
	include_hidden:      bool,
	send_include_hidden: bool,
	cursor:              string,
	limit:               int,
	send_limit:          bool,
	// read-file byte-range pagination
	offset:              int,
	send_offset:         bool,
	read_limit:          int,
	send_read_limit:     bool,
}

instance_fs_relay :: proc(h: ^Bridge_Handlers, req: Request, cmd: Instance_Fs_Command) -> (string, bool, domain.Domain_Error) {
	auth_ctx, auth_ok, _ := require_auth(h.auth, req)
	if !auth_ok do return "", false, domain.domain_error(.Unauthenticated, "authentication required")
	instance_id := path_part(req.path, 4)
	inst, got, inst_err := agent_service.get_instance(h.agents, auth_ctx, instance_id)
	if !got do return "", false, inst_err
	bridge, bridge_ok, bridge_err := bridge_service.get_bridge(h.bridges, auth_ctx, inst.bridge_id)
	if !bridge_ok do return "", false, bridge_err
	if bridge.status == .Revoked do return "", false, domain.domain_error(.Bridge_Revoked, "bridge is revoked")
	if bridge.status != .Online || !project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry, bridge.bridge_id) do return "", false, domain.domain_error(.Bridge_Offline, fmt.tprintf("Bridge %s is not connected", bridge.bridge_id))
	command_id := fmt.tprintf("cmd_ifs_%d", time.to_unix_nanoseconds(time.now()))
	cmd_body := instance_fs_command_json(cmd, command_id, inst.agent_instance_id)
	reply, reply_ok, reply_err := bridge_runtime_service.send_runtime_command_wait(h.bridge_runtime_registry, project_service.Runtime_Command{bridge_id = bridge.bridge_id, command_id = command_id, body_json = cmd_body}, 10000)
	if !reply_ok do return "", false, reply_err
	return reply, true, domain.Domain_Error{}
}

instance_fs_command_json :: proc(cmd: Instance_Fs_Command, command_id, instance_id: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\""); write_handler_json_string(&b, cmd.command_type)
	strings.write_string(&b, "\",\"command_id\":\""); write_handler_json_string(&b, command_id)
	strings.write_string(&b, "\",\"instance_id\":\""); write_handler_json_string(&b, instance_id)
	strings.write_string(&b, "\",\"path\":\""); write_handler_json_string(&b, cmd.path); strings.write_string(&b, "\"")
	if cmd.send_include_hidden {
		strings.write_string(&b, ",\"include_hidden\":"); strings.write_string(&b, "true" if cmd.include_hidden else "false")
	}
	if cmd.cursor != "" {
		strings.write_string(&b, ",\"cursor\":\""); write_handler_json_string(&b, cmd.cursor); strings.write_string(&b, "\"")
	}
	if cmd.send_limit {
		strings.write_string(&b, ",\"limit\":"); strings.write_int(&b, cmd.limit)
	}
	if cmd.send_offset {
		strings.write_string(&b, ",\"offset\":"); strings.write_int(&b, cmd.offset)
	}
	if cmd.send_read_limit {
		strings.write_string(&b, ",\"limit\":"); strings.write_int(&b, cmd.read_limit)
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

list_instance_dir_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	limit := query_int(req.query, "limit", 0)
	// include_hidden defaults TRUE for the run-dir browser (show .heimdall/, dotfiles).
	result, ok, err := instance_fs_relay(h, req, Instance_Fs_Command{
		command_type = "agent_run_dir_list",
		path = query_value(req.query, "path"),
		include_hidden = query_bool(req.query, "include_hidden", true), send_include_hidden = true,
		cursor = query_value(req.query, "cursor"),
		limit = limit, send_limit = limit > 0,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

read_instance_file_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	offset := query_int(req.query, "offset", 0)
	rlimit := query_int(req.query, "limit", 0)
	result, ok, err := instance_fs_relay(h, req, Instance_Fs_Command{
		command_type = "agent_run_dir_read",
		path = query_value(req.query, "path"),
		offset = offset, send_offset = offset > 0,
		read_limit = rlimit, send_read_limit = rlimit > 0,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

bridge_ws_upgrade_handler :: proc(ctx: rawptr, req: Request, client: net.TCP_Socket) {
	h := (^Bridge_Handlers)(ctx)
	if rejected, resp := reject_query_or_body_token(req); rejected { write_upgrade_error(client, resp); return }
	token, token_ok := bearer_token(req)
	if !token_ok { write_upgrade_error(client, respond_error(domain.domain_error(.Unauthenticated, "bridge bearer token is required"), req.request_id)); return }
	key := header_value(req.headers, "Sec-WebSocket-Key")
	if key == "" { write_upgrade_error(client, respond_error(domain.domain_error(.Validation_Failed, "missing websocket key"), req.request_id)); return }
	if !write_ws_upgrade_response(client, ws_accept_key(key)) do return
	// One reader for the whole connection so a hello coalesced with the first frame
	// (or any later coalescing) is never dropped.
	reader := bridge_ws_reader_make(client)
	defer bridge_ws_reader_destroy(&reader)
	hello_text, hello_frame_ok := read_ws_text_blocking(&reader, 3 * time.Second)
	if !hello_frame_ok do return
	defer delete(hello_text)
	hostname := json_string(hello_text, "hostname"); defer delete(hostname)
	os_str := json_string(hello_text, "os"); defer delete(os_str)
	arch_str := json_string(hello_text, "arch"); defer delete(arch_str)
	target_str := json_string(hello_text, "target"); defer delete(target_str)
	platform_os := os_str
	platform_arch := arch_str
	if target_str != "" || os_str != "" || arch_str != "" {
		platform_ok := false
		platform_os, platform_arch, platform_ok = bridge_service.canonical_bridge_platform(os_str, arch_str, target_str)
		if !platform_ok {
			_ = write_ws_text_frame(client, bridge_ws_error_payload("unsupported bridge target"))
			return
		}
	}
	version_str := json_string(hello_text, "version"); defer delete(version_str)
	commit_sha_str := json_string(hello_text, "commit_sha"); defer delete(commit_sha_str)
	build_timestamp_str := json_string(hello_text, "built_at")
	if len(build_timestamp_str) == 0 {
		delete(build_timestamp_str)
		build_timestamp_str = json_string(hello_text, "build_timestamp")
	}
	defer delete(build_timestamp_str)
	validation_url := json_string(hello_text, "validation_ws_url"); defer delete(validation_url)
	body_bridge_id := json_string(hello_text, "bridge_id"); defer delete(body_bridge_id)
	bridge_auth, auth_ok, auth_err := bridge_service.verify_bridge_token(h.bridges, token)
	// Unauthenticated attempts carry no trustworthy bridge_id: they share one series.
	if !auth_ok { bridge_metrics_connect_result(BRIDGE_ID_UNKNOWN, "auth_failed"); _ = write_ws_text_frame(client, bridge_ws_error_payload(auth_err.message)); return }
	admitted_bridge, found, lookup_err := iface.bridge_get_bridge(h.bridges.repo, bridge_auth.bridge_id)
	if !found { bridge_metrics_connect_result(BRIDGE_ID_UNKNOWN, "auth_failed"); _ = write_ws_text_frame(client, bridge_ws_error_payload(lookup_err.message)); return }
	defer domain.bridge_destroy(&admitted_bridge)
	if body_bridge_id != "" && body_bridge_id != admitted_bridge.bridge_id { _ = write_ws_text_frame(client, bridge_ws_error_payload("bridge_id does not match bearer token")); return }
	hello, hello_ok, hello_err := bridge_runtime_service.runtime_accept_hello(h.bridge_runtime_registry, admitted_bridge.bridge_id, json_int(hello_text, "protocol_version", 1), validation_url, string(admitted_bridge.owner_user_id), bridge_connection_replaced_payload())
	if !hello_ok {
		bridge_metrics_connect_result(admitted_bridge.bridge_id, "limit" if hello_err.code == .Bridge_Busy else "hello_rejected")
		_ = write_ws_text_frame(client, bridge_ws_error_payload(hello_err.message))
		return
	}
	connection := project_service.bridge_runtime_connection_acquire(h.bridge_runtime_registry, admitted_bridge.bridge_id, hello.generation)
	if connection == nil do return
	reader.control_context = rawptr(connection)
	reader.control_writer = bridge_reader_write_pong
	defer project_service.bridge_runtime_connection_release(h.bridge_runtime_registry, connection)
	defer project_service.bridge_runtime_connection_quiesce(h.bridge_runtime_registry, connection)
	defer project_service.bridge_runtime_registry_mark_offline(h.bridge_runtime_registry, connection.bridge_id, hello.generation)
	// Admission and quota checks precede the durable Online transition. State
	// retirement also gates this write, so an older disconnect finishes first.
	sync.lock(&connection.state_mutex)
	if sync.atomic_load(&connection.retired) { sync.unlock(&connection.state_mutex); return }
	bridge, connect_ok, err := bridge_service.bridge_runtime_connect(h.bridges, token, hostname, platform_os, platform_arch, hello_text, version_str, commit_sha_str, build_timestamp_str)
	sync.unlock(&connection.state_mutex)
	if !connect_ok {
		bridge_metrics_connect_result(admitted_bridge.bridge_id, "revoked" if err.code == .Bridge_Revoked else "connect_failed")
		_ = write_ws_text_frame(client, bridge_ws_error_payload(err.message))
		return
	}
	defer domain.bridge_destroy(&bridge)
	// Inbound bytes for this connection land on the registry-owned series.
	reader.bytes_series = connection.rx_bytes
	project_service.bridge_runtime_registry_set_command_socket(h.bridge_runtime_registry, bridge.bridge_id, client, hello.generation)
	hello_pub_key := json_string(hello_text, "public_key")
	if hello_pub_key != "" {
		project_service.bridge_runtime_registry_set_public_key(h.bridge_runtime_registry, bridge.bridge_id, hello_pub_key, hello.generation)
	}
	delete(hello_pub_key)
	// From here the socket is registered, so other threads (fs/file commands) may
	// write it — serialize this and every subsequent write.
	// Provider discovery is an optional capability sync, not part of Bridge
	// authentication. Once the bearer token and hello are accepted, acknowledge
	// the runtime even if the catalog repository is unavailable. An empty etag
	// tells the Bridge to retain its last known-good cached catalog.
	catalog_etag := ""
	if catalog, catalog_err := provider_service.list_catalog(h.providers); catalog_err.code == .None {
		catalog_etag = strings.clone(catalog.catalog_etag)
		domain.provider_catalog_destroy(catalog.providers)
		delete(catalog.catalog_etag)
	} else {
		fmt.eprintfln(
			"bridge provider catalog unavailable during hello for %s: %s; continuing with cached Bridge catalog",
			bridge.bridge_id,
			catalog_err.message,
		)
	}
	defer delete(catalog_etag)
	// Cache the owner's switch on the connection BEFORE bridge_ready goes out: a
	// bridge may flush its bridge_log ring in the very next frame.
	project_service.bridge_runtime_registry_set_telemetry_enabled(h.bridge_runtime_registry, bridge.bridge_id, bridge.telemetry_enabled != "disabled")
	_ = write_ws_text_frame_locked(h, bridge.bridge_id, client, bridge_ready_payload(bridge.bridge_id, hello.generation, hello.replaced_existing, catalog_etag, bridge.telemetry_enabled != "disabled"))
	if bridge.telemetry_enabled == "enabled" {
		cmd_id := fmt.tprintf("cmd_tel_%d", time.to_unix_nanoseconds(time.now()))
		payload := bridge_set_telemetry_payload(cmd_id, true)
		defer delete(payload)
		_ = write_ws_text_frame_locked(h, bridge.bridge_id, client, payload)
	}
	// REQ-RECON-FIX-2: Ingest active_instance_ids from bridge_hello on WS connect
	// and immediately reconcile active instances for the connecting bridge.
	hello_active := json_string_array(hello_text, "active_instance_ids")
	_ = bridge_runtime_service.runtime_reconcile_digest(h.bridge_runtime_registry, bridge.bridge_id, hello.generation, hello_active)
	if h.agents != nil {
		gone := agent_service.reconcile_bridge_heartbeat(h.agents, bridge.bridge_id, hello_active)
		defer domain.agent_instances_destroy(gone)
		for inst in gone {
			if h.shell_sessions != nil {
				shell_session_svc.shell_session_background_runs_for_agent(h.shell_sessions, string(inst.owner_user_id), inst.agent_instance_id)
			}
		}
	}
	for s in hello_active do delete(s)
	delete(hello_active)
	// REQ-SHELL-3: deliver this bridge's OUTSTANDING KILL INTENTS. A kill accepted
	// while the bridge was offline is durable on the row and undelivered; this is
	// where it is re-issued, so "kill it even if the bridge is disconnected; it dies
	// when the bridge is next connected" holds. It runs after bridge_ready so the
	// command socket the send needs is registered.
	//
	// PUSHED from here rather than pulled by the bridge's reconcile pass: that pass
	// returns without touching anything when the pty-host daemon is unreachable, so a
	// kill riding it would be silently deferred while appearing to work. See
	// shell_session_replay_kill_intents for the full reasoning.
	//
	// Scheduled off the accept/reader path. Replay uses bounded producer windows and
	// terminal feedback, so a large durable backlog cannot fill the Bridge recovery
	// queue before heartbeats and normal commands begin flowing.
	//
	// The paced worker logs outstanding, delivered, and shortfall counts after its
	// bounded retry loop, preserving REQ-SHELL-23 observability.
	if h.shell_sessions != nil {
		_ = shell_session_svc.shell_session_schedule_kill_replay(h.shell_sessions, bridge.bridge_id)
	}
	// REQ-SHELL-41: the connection is fully established here — authenticated, hello
	// accepted, command socket registered — so this is the point at which "a bridge
	// connected" becomes true. `replaced_existing` was already computed above for the
	// bridge_ready payload and was previously discarded; it is the "did this replace an
	// existing connection for that bridge" fact AC2 asks for.
	connected_at_ns := time.now()._nsec
	bridge_ws_log_connect(bridge.bridge_id, req.remote_addr, hello.generation, hello.replaced_existing)
	bridge_metrics_connected(bridge, hello.replaced_existing)
	bridge_ws_runtime_loop(h, bridge.bridge_id, hello.generation, &reader, connected_at_ns)
}

// BRIDGE_INSTANCE_STALE_MS: an instance still in an active runtime state whose
// last_seen_at is older than this is reaped to "unreachable" by the opportunistic
// sweep on bridge heartbeats. Generously above the ~2s heartbeat cadence so a
// briefly-slow bridge is never falsely reaped.
BRIDGE_INSTANCE_STALE_MS :: 90_000

// bridge_ws_disconnect clears the durable runtime state of a disconnected
// bridge's instances (registry offline alone leaves them "running" forever) and
// fans out resource_changed so the UI updates immediately.
bridge_disconnect_persist :: proc(h: ^Bridge_Handlers, connection: ^project_service.Bridge_Runtime_Connection) -> (domain.Bridge, bool, []domain.Agent_Instance, bool) {
	if connection == nil do return {}, false, nil, false
	sync.lock(&connection.state_mutex)
	defer sync.unlock(&connection.state_mutex)
	if sync.atomic_load(&connection.retired) do return {}, false, nil, false
	bridge: domain.Bridge
	changed := false
	if h.bridges != nil { bridge, changed, _ = bridge_service.mark_bridge_offline(h.bridges, connection.bridge_id) }
	cleared: []domain.Agent_Instance
	if h.agents != nil { cleared = agent_service.mark_bridge_instances_unreachable(h.agents, connection.bridge_id) }
	return bridge, changed, cleared, true
}

bridge_ws_disconnect :: proc(
	h: ^Bridge_Handlers,
	bridge_id: string,
	connection_generation: int,
	reason: Bridge_WS_Disconnect_Reason = .None,
	connected_at_ns: i64 = 0,
) {
	// Only run the cascade if THIS connection generation is still the live one.
	// registry_mark_offline is generation-guarded (a newer reconnect already
	// replaced us => it returns without removing the live entry), so gate the
	// durable offline/cascade on the same generation to stay idempotent and avoid
	// clobbering a fresh reconnect's instances.
	// REQ-LSP-RLY-1: an LSP session's language server lives on this bridge, so a
	// disconnect ends every session started on it. This wakes those relay threads
	// (it never closes their sockets — see lsp_registry_wake_bridge_sessions) so
	// each unwinds and releases its own entry; the browser gets an lsp_error first.
	// Done before the generation gate: those sockets are dead either way, and a
	// reconnect must not inherit sessions whose server process is gone.
	if h.lsp_sessions != nil {
		_ = lsp_registry_wake_bridge_sessions(h.lsp_sessions, bridge_id)
	}
	connection := project_service.bridge_runtime_connection_acquire(h.bridge_runtime_registry, bridge_id, connection_generation)
	defer project_service.bridge_runtime_connection_release(h.bridge_runtime_registry, connection)
	bridge, changed, cleared, still_current := bridge_disconnect_persist(h, connection)
	defer domain.bridge_destroy(&bridge)
	defer domain.agent_instances_destroy(cleared)
	duration_ms := i64(-1)
	if connected_at_ns > 0 do duration_ms = (time.now()._nsec - connected_at_ns) / 1_000_000
	bridge_ws_log_disconnect(bridge_id, reason, connection_generation, duration_ms, still_current)
	project_service.bridge_runtime_registry_mark_offline(h.bridge_runtime_registry, bridge_id, connection_generation)
	// Per-bridge gauges (bridge_info with its owner/version labels, heartbeat
	// timestamp, M3 resource gauges) are tombstoned only once NO generation is
	// live: a replaced connection's teardown must not erase its successor's info.
	bridge_metrics_disconnected(reason, connected_at_ns, project_service.bridge_runtime_registry_generation(h.bridge_runtime_registry, bridge_id) == 0, bridge_id)
	if !still_current do return
	// A replacement already published its newer generation; do not publish old
	// status summaries after its connection has started.
	if project_service.bridge_runtime_registry_generation(h.bridge_runtime_registry, bridge_id) != 0 do return
	if changed {
		summary := bridge_status_summary_json(domain.bridge_status_string(bridge.status))
		events.publish_resource_changed(h.event_bus, string(bridge.owner_user_id), "bridge", bridge.bridge_id, "status_changed", summary)
		delete(summary)
	}
	for inst in cleared {
		// REQ-SHELL-2 §9: a FOREGROUND run is bound to its agent's liveness. Its
		// caller is blocked waiting for a result that will now never be delivered to
		// it, so the run must not stay a foreground run — convert it to background so
		// it remains addressable, reapable, capped and notifying, rather than a
		// foreground run nobody is listening to.
		//
		// CONVERT, NOT KILL, and this call site is exactly why. This sweep fires on
		// BRIDGE disconnect and clears EVERY instance on the bridge at once; the agent
		// processes are usually alive and only the hub link dropped. Killing here would
		// destroy in-flight work on a transient blip — and the kill could not be
		// delivered anyway, to a bridge that has just gone.
		shell_session_svc.shell_session_background_runs_for_agent(h.shell_sessions, string(inst.owner_user_id), inst.agent_instance_id)
		summary := agent_instance_status_summary_json(inst.runtime_status, inst.startup_status, inst.activity_status)
		events.publish_resource_changed(h.event_bus, string(inst.owner_user_id), "agent_instance", inst.agent_instance_id, "status_changed", summary)
		delete(summary)
	}
}

// Bridge_Chunk_Reassembly buffers the fragments of one in-flight chunk stream on
// the hub-runtime read path, keyed by chunk_id (which equals the frame's
// stream_id on the wire).
Bridge_Chunk_Reassembly :: ws.Chunk_Reassembly
BRIDGE_WS_REASSEMBLY_TTL :: ws.CHUNK_REASSEMBLY_TTL

bridge_chunk_reassembly_sweep :: proc(reassemblies: ^[dynamic]Bridge_Chunk_Reassembly, now_ns: i64) -> int {
	return ws.chunk_reassembly_sweep(reassemblies, now_ns)
}

bridge_chunk_reassembly_oldest_index :: proc(reassemblies: ^[dynamic]Bridge_Chunk_Reassembly) -> int {
	return ws.chunk_reassembly_oldest(reassemblies)
}

bridge_chunk_reassembly_remove :: proc(reassemblies: ^[dynamic]Bridge_Chunk_Reassembly, idx: int) {
	ws.chunk_reassembly_free(reassemblies, idx)
}

bridge_chunk_reassemblies_free :: proc(reassemblies: ^[dynamic]Bridge_Chunk_Reassembly) {
	ws.chunk_reassemblies_free(reassemblies)
}

bridge_ws_reassemble_chunk :: proc(reassemblies: ^[dynamic]Bridge_Chunk_Reassembly, text: string) -> (assembled: string, complete: bool, ok: bool) {
	return ws.reassemble_chunk(reassemblies, text)
}


bridge_ws_runtime_loop :: proc(
	h: ^Bridge_Handlers,
	bridge_id: string,
	connection_generation: int,
	reader: ^Bridge_WS_Reader,
	connected_at_ns: i64 = 0,
) {
	client := reader.socket
	// REQ-SHELL-41: the teardown reason, set on every exit path below and read by the
	// deferred disconnect. A plain local, so there is nothing allocated and nothing to
	// free on this loop's heap path (AC4). This relies on Odin evaluating a deferred
	// call's ARGUMENTS when the defer RUNS, not where it is written (verified
	// separately) — so the value assigned at the exit path is the one logged.
	//
	// Initialised to .None, which renders as "none", rather than to a plausible value
	// like .Clean_Close. Every exit path below assigns it, so this default is currently
	// unreachable; if a future exit path forgets to, the log must say "none" and look
	// WRONG rather than quietly claim an orderly shutdown. A misleading trace is worse
	// than an obviously-missing one — that is the whole premise of this task.
	reason := Bridge_WS_Disconnect_Reason.None
	defer bridge_ws_disconnect(h, bridge_id, connection_generation, reason, connected_at_ns)
	// Per-connection chunk reassembly buffer. The bridge (bridge_hub_send) splits
	// any bridge->hub frame larger than the edge proxy's ~16KB per-message cap into
	// ordered kind:"chunk" frames; we rebuild the original frame here before it is
	// dispatched. Reads for one connection are single-threaded (this loop), so the
	// buffer needs no lock; it is freed on loop return / disconnect.
	reassemblies := make([dynamic]Bridge_Chunk_Reassembly)
	defer bridge_chunk_reassemblies_free(&reassemblies)
	for {
		// 120s read deadline decoupled from the bridge's idle heartbeat cadence
		// (BRIDGE_HUB_HEARTBEAT_INTERVAL = 45s): a single delayed/dropped heartbeat
		// still leaves a full extra beat of margin before we treat the bridge as
		// gone, so we never tear down a healthy connection at the cadence edge.
		text, ok, read_reason := bridge_ws_read_frame(reader, 120 * time.Second)
		if !ok {
			reason = read_reason
			if reason == .Fatal_Frame do metrics.counter_inc(metrics.with(project_service.fleet_metrics.bridge_frames_rejected, "fatal_frame"))
			return
		}
		if !bridge_ws_process_frame(h, bridge_id, connection_generation, client, &reassemblies, text, (^project_service.Bridge_Runtime_Connection)(reader.control_context)) {
			// process_frame refuses a frame either because a newer connection replaced
			// this one (it says so on the wire via bridge_connection_replaced_payload)
			// or because dispatch rejected it. Distinguish the two: a replacement is
			// routine during a bridge restart, a rejection is not.
			reason = .Connection_Replaced if project_service.bridge_runtime_registry_generation(h.bridge_runtime_registry, bridge_id) != connection_generation else .Frame_Rejected
			if reason == .Frame_Rejected do metrics.counter_inc(metrics.with(project_service.fleet_metrics.bridge_frames_rejected, "rejected"))
			return
		}
	}
}

// connection is this reader's own registry connection (nil in unit tests that drive
// frames without a registered socket).
bridge_ws_process_frame :: proc(h: ^Bridge_Handlers, bridge_id: string, connection_generation: int, client: net.TCP_Socket, reassemblies: ^[dynamic]Bridge_Chunk_Reassembly, raw_text: string, connection: ^project_service.Bridge_Runtime_Connection = nil) -> bool {
	temp := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp)
	text := raw_text
	if project_service.bridge_runtime_registry_generation(h.bridge_runtime_registry, bridge_id) != connection_generation {
		delete(text)
		// A newer hello normally delivers connection_replaced while retiring us
		// (accept_live). This covers the window where we observe the generation flip
		// before that retirement runs. It must go to OUR socket under OUR writer mutex:
		// write_ws_text_frame_locked resolves bridge_id to the NEW connection and so
		// could never reach this one. send_farewell is once-only per connection.
		_ = project_service.bridge_runtime_connection_send_farewell(connection, bridge_connection_replaced_payload())
		return false
	}
	type := json_string(text, "type")
	// Chunk reassembly. A real chunk frame has kind:"chunk" and NO top-level
	// "type" (its payload_fragment is base64, so it can never contain a "type"
	// key) — that is what distinguishes it from a normal frame whose file
	// CONTENT merely embeds "kind":"chunk". Buffer until the stream completes,
	// then dispatch the reassembled original frame by its real type. Non-chunk
	// frames — including heartbeats interleaved between chunks — fall straight
	// through untouched. Ack-less: see the bridge's bridge_hub_send.
	if type == "" {
		kind := json_string(text, "kind")
		if kind == contracts.BRIDGE_WS_FRAME_KIND_CHUNK {
			delete(kind)
			delete(type)
			assembled, complete, cok := bridge_ws_reassemble_chunk(reassemblies, text)
			delete(text)
			// REQ-SHELL-32: a refused chunk used to vanish here without a word, which is
			// why a defect that made the hub totally deaf to every large frame on a
			// connection went unnoticed. `complete=false` is the normal "still
			// buffering" case and stays quiet; `ok=false` means the frame was DROPPED.
			if !cok {
				fmt.eprintfln(
					"ham-hub WARN bridge ws chunk frame DROPPED bridge=%s (malformed, over-cap, or admission refused)",
					bridge_id)
				return false
			}
			if !complete do return true
			text = assembled
			type = json_string(text, "type")
		} else {
			delete(kind)
		}
	}
	defer delete(text)
	defer delete(type)
	metrics.counter_inc(metrics.with(project_service.fleet_metrics.bridge_ws_frames, "rx", project_service.bridge_frame_kind(type)))

	switch type {
	case "provider_catalog_request":
		payload, payload_ok := bridge_provider_catalog_payload(h.providers)
		if payload_ok {
			_ = write_ws_text_frame_locked(h, bridge_id, client, payload)
		}
		delete(payload)
	case "bridge_heartbeat":
		metrics.gauge_set(metrics.with(project_service.fleet_metrics.bridge_last_heartbeat, bridge_id), time.now()._nsec / 1_000_000_000)
		_ = bridge_apply_heartbeat_stats(bridge_id, text, connection)
		project_service.bridge_runtime_registry_set_task_chain_search_status(
			h.bridge_runtime_registry, bridge_id, connection_generation,
			json_bool_value(text, "task_chain_search_ready"), json_bool_value(text, "task_chain_search_stale"),
			i64(json_int(text, "task_chain_search_revision", 0)),
		)
		if strings.contains(text, "\"capabilities\"") { _, _, _ = bridge_service.update_runtime_capabilities(h.bridges, bridge_id, text) }
		// REQ-BVS-1. Runs AFTER update_runtime_capabilities, which rewrites the row:
		// this one re-reads it, so it sees the fresh value and its own write is not
		// clobbered by the capabilities save.
		bridge_apply_vault_status_report(h, bridge_id, text)
		active := json_string_array(text, "active_instance_ids")
		digest_active := bridge_apply_heartbeat_digest(h, bridge_id, text, connection_generation)
		used_digest := false
		if len(active) == 0 && len(digest_active) > 0 {
			delete(active)
			active = digest_active
			used_digest = true
		}
		if h.agents != nil do agent_service.reconcile_instance_reconfigurations(h.agents, bridge_id)
		reconciled := bridge_runtime_service.runtime_reconcile_digest(h.bridge_runtime_registry, bridge_id, connection_generation, active)
		// H7 cross-bridge reap: any instance this bridge reports active whose
		// canonical bridge_id is now a DIFFERENT bridge has been relaunched
		// elsewhere. Tell this bridge to invalidate those instances' local tokens
		// (via the ack) so the stale old ham-wrapper self-terminates.
		superseded: []string
		if h.agents != nil do superseded = agent_service.detect_superseded_instances(h.agents, bridge_id, active)
		if h.agents != nil {
			// The per-instance unreachability signal: the bridge is still connected and
			// reporting, and these instances are simply no longer among the ones it
			// reports active. Their foreground runs get the same treatment as on a
			// bridge-wide disconnect — converted, not killed — deliberately, so there
			// is no "which signal fired?" branch whose wrong answer destroys work.
			gone := agent_service.reconcile_bridge_heartbeat(h.agents, bridge_id, active)
			defer domain.agent_instances_destroy(gone)
			metrics.counter_add(project_service.fleet_metrics.agent_instances_reconciled_gone, u64(len(gone)))
			for inst in gone {
				shell_session_svc.shell_session_background_runs_for_agent(h.shell_sessions, string(inst.owner_user_id), inst.agent_instance_id)
				reconciled += 1
			}
		}
		// Opportunistic time-based reap: catches instances stranded by a
		// disconnect the hub never observed (hub restart with persisted DB, or a
		// lost WS close). Request-driven, so no background thread is required.
		if h.agents != nil {
			reaped := agent_service.reap_stale_instances(h.agents, BRIDGE_INSTANCE_STALE_MS)
			for inst in reaped {
				shell_session_svc.shell_session_background_runs_for_agent(h.shell_sessions, string(inst.owner_user_id), inst.agent_instance_id)
				summary := agent_instance_status_summary_json(inst.runtime_status, inst.startup_status, inst.activity_status)
				events.publish_resource_changed(h.event_bus, string(inst.owner_user_id), "agent_instance", inst.agent_instance_id, "status_changed", summary)
				delete(summary)
				reconciled += 1
			}
			domain.agent_instances_destroy(reaped)
		}
		schedules_version := 0
		if h.actions != nil {
			schedules_version = get_actions_bridge_version(h.actions, bridge_id)
		} else if h.scheduled_prompts != nil {
			schedules_version = get_scheduled_prompts_bridge_version(h.scheduled_prompts, bridge_id)
		}
		ack := bridge_heartbeat_ack_payload(reconciled, superseded, schedules_version)
		_ = write_ws_text_frame_locked(h, bridge_id, client, ack)
		delete(ack)
		if superseded != nil {
			for s in superseded do delete(s)
			delete(superseded)
		}
		for s in active do delete(s)
		delete(active)
		if !used_digest && digest_active != nil {
			for s in digest_active do delete(s)
			delete(digest_active)
		}
	case "agent_instance_status":
		instance_id := json_string(text, "agent_instance_id")
		state_seq := json_int(text, "state_seq", 0)
		runtime_status := json_string(text, "runtime_status")
		activity_status := json_string(text, "activity_status")
		if h.agents != nil {
			if inst, applied, _ := bridge_apply_validated_status(h, bridge_id, connection_generation, instance_id, state_seq, runtime_status, activity_status, json_string(text, "launch_epoch", context.temp_allocator)); applied {
				summary := agent_instance_status_summary_json(inst.runtime_status, inst.startup_status, inst.activity_status)
				events.publish_resource_changed(h.event_bus, string(inst.owner_user_id), "agent_instance", inst.agent_instance_id, "status_changed", summary)
				delete(summary)
				domain.agent_instance_destroy(&inst)
			}
		}
		if h.agents != nil do agent_service.reconcile_instance_reconfigurations(h.agents, bridge_id)
		current_runtime, current_activity, current_seq, got := bridge_runtime_service.runtime_instance_status(h.bridge_runtime_registry, bridge_id, connection_generation, instance_id)
		defer delete(current_runtime)
		defer delete(current_activity)
		if !got && h.agents != nil {
			if stored, found, _ := iface.agent_get_instance(h.agents.agents, instance_id); found {
				if stored.bridge_id == bridge_id {
					current_runtime = strings.clone(stored.runtime_status)
					current_activity = strings.clone(stored.activity_status)
					current_seq = stored.last_applied_seq
				}
				domain.agent_instance_destroy(&stored)
			}
		}
		applied := current_seq == state_seq && current_runtime == runtime_status
		if applied && h.shell_sessions != nil && instance_id != "" && current_runtime != "" {
			shell_session_svc.shell_session_broadcast_status(h.shell_sessions, instance_id, current_runtime, 0, false)
		}
		ack := bridge_state_ack_payload(instance_id, applied, current_seq, current_runtime)
		_ = write_ws_text_frame_locked(h, bridge_id, client, ack)
		delete(ack)
		delete(instance_id)
		delete(runtime_status)
		delete(activity_status)
	case "bridge_log":
		// bridge_logs plan v2 §4.1: validate + count + hand off; never SQLite here.
		_ = bridge_apply_log_frame(h.bridge_logs, bridge_id, text, connection)
	case "bridge_update_progress":
		stage := json_string(text, "stage")
		message := json_string(text, "message")
		progress := json_int(text, "progress_percent", 0)
		persisted, _ := bridge_service.record_bridge_update_progress(h.bridges, bridge_id, stage, message, progress)
		if stage == "succeeded" || stage == "failed" do metrics.counter_inc(metrics.with(project_service.fleet_metrics.bridge_updates, stage if persisted else "invalid"))
		if persisted {
			bridge, found, _ := iface.bridge_get_bridge(h.bridges.repo, bridge_id)
			if found {
				summary := bridge_update_summary_json(bridge.update_status, bridge.update_message, bridge.update_progress, bridge.update_error)
				events.publish_resource_changed(h.event_bus, string(bridge.owner_user_id), "bridge", bridge.bridge_id, "update_progress", summary)
				delete(summary)
				domain.bridge_destroy(&bridge)
			}
		}
		delete(stage)
		delete(message)
	case "command_result", "project_path_validation_result", "provider_discovery_report", "fs_list_dir_result", "fs_stat_result", "fs_make_dir_result", "fs_read_file_result", "fs_create_file_result", "fs_write_file_result", "fs_batch_write_result", "fs_move_result", "fs_delete_result", "vcs_capabilities_result", "vcs_status_result", "vcs_files_result", "vcs_diff_result", "vcs_log_result", "vcs_commit_diff_result", "vcs_workspaces_result", "vcs_stage_result", "vcs_unstage_result", "vcs_revert_result", "vcs_save_file_result", "vcs_commit_result", "fs_find_files_result", "fs_grep_result", "shell_start_result", "shell_restart_result", "shell_list_result", "shell_logs_result", "shell_capture_result", "shell_set_port_result", "bridge_unseal_result", "bridge_lock_result", "task_chain_search_result":
		command_id := json_string(text, "command_id")
		_ = bridge_runtime_service.runtime_command_result_for_connection(h.bridge_runtime_registry, bridge_id, connection_generation, command_id, text)
		if type == "command_result" && h.agents != nil do agent_service.apply_reconfiguration_command_result(h.agents, bridge_id, command_id, text)
		if type == "command_result" && command_id == "" {
			// An id-less failure cannot be matched to any pending command; log it so
			// hub/bridge protocol drift (e.g. missing_command_id) is visible.
			status := json_string(text, "status")
			if status == "failed" {
				error_code := json_string(text, "error_code")
				fmt.eprintln("hub: bridge", bridge_id, "rejected command without id:", error_code)
				delete(error_code)
			}
			delete(status)
		}
		delete(command_id)
	case "pane_capture_result":
		if json_int(text, "protocol_version", 0) != 1 do return true
		if h.content != nil {
			input := content_service.Pane_Capture_Result_Input{
				command_id = json_string_unescaped(text, "command_id"),
				pane_capture_request_id = json_string_unescaped(text, "pane_capture_request_id"),
				conversation_id = json_string_unescaped(text, "conversation_id"),
				message_id = json_string_unescaped(text, "message_id"),
				agent_instance_id = json_string_unescaped(text, "agent_instance_id"),
				ok = json_bool_value(text, "ok"),
				output = json_string_unescaped(text, "output"),
				error_code = json_string_unescaped(text, "error_code"),
				message = json_string_unescaped(text, "message"),
				width = json_int(text, "width", 80),
				line_count = json_int(text, "line_count", 0),
				truncated = json_bool_value(text, "truncated"),
			}
			if msg, conv, applied, _ := content_service.complete_pane_capture(h.content, bridge_id, input); applied {
				evt := pane_capture_chat_event_json(conv, msg)
				events.publish_owned(h.event_bus, string(conv.owner_user_id), evt)
			}
			delete(input.command_id)
			delete(input.pane_capture_request_id)
			delete(input.conversation_id)
			delete(input.message_id)
			delete(input.agent_instance_id)
			delete(input.output)
			delete(input.error_code)
			delete(input.message)
		}
	case "bridge_vault_status":
		// REQ-BVS-1: the immediate report the bridge pushes after a successful unseal
		// or lock, so the vault settings page does not wait for the next heartbeat.
		// Deliberately NOT a synthetic bridge_heartbeat: that arm also reconciles the
		// instance digest and reaps stale instances, which a vault operation has no
		// business triggering.
		bridge_apply_vault_status_report(h, bridge_id, text)
	case "lsp_data", "lsp_error", "lsp_started", "lsp_stopped":
		// REQ-LSP-RLY-1. Every lsp_* type the bridge can send MUST have an arm in
		// this switch: a type with no arm falls through and is dropped silently,
		// with no error anywhere, and the feature simply never works.
		// lsp_forward_bridge_frame translates the Hub-internal wire session id
		// back to the id the browser chose and writes the frame to that socket.
		// It returns false for a frame whose session is already gone (the socket
		// closed while the server was still talking), which is expected and dropped.
		if h.lsp_sessions != nil {
			_ = lsp_forward_bridge_frame(h.lsp_sessions, type, text)
		}
	case "shell_pty_output":
		if h.shell_sessions != nil {
			session_id := json_string(text, "session_id")
			defer delete(session_id)
			data_b64 := json_string(text, "data_b64")
			defer delete(data_b64)
			is_encrypted, flag_ok := json_bool_literal(text, "is_encrypted")
			if session_id != "" && data_b64 != "" && flag_ok {
				shell_session_svc.shell_session_broadcast_output(h.shell_sessions, session_id, data_b64, is_encrypted, json_bool(text, "is_snapshot"), bridge_id)
			}
		}
	case "shell_pty_vault_locked":
		// T10 (REQ-T10-3): the bridge refused a pane's input or suspended its output
		// because its vault is locked. Relayed to that pane's viewers as a typed
		// `vault_locked` error frame; ownership is checked in the service.
		if h.shell_sessions != nil {
			session_id := json_string(text, "session_id")
			defer delete(session_id)
			shell_session_svc.shell_session_broadcast_vault_locked(h.shell_sessions, session_id, bridge_id)
		}
	case "pane_resync_required":
		if h.shell_sessions != nil {
			session_id := json_string(text, "session_id")
			defer delete(session_id)
			shell_session_svc.shell_session_resync_viewers(h.shell_sessions, session_id, bridge_id)
		}
	case "shell_pty_stream_ready":
		if h.shell_sessions != nil {
			session_id := json_string(text, "session_id")
			if session_id == "" {
				delete(session_id)
				session_id = json_string(text, "shell_id")
			}
			defer delete(session_id)
			if session_id != "" {
				shell_session_svc.shell_session_broadcast_stream_ready(h.shell_sessions, session_id)
			}
		}
	case "shell_pty_stream_closed":
		if h.shell_sessions != nil {
			session_id := json_string(text, "session_id")
			if session_id == "" {
				delete(session_id)
				session_id = json_string(text, "shell_id")
			}
			defer delete(session_id)
			exit_code := json_int(text, "exit_code", 0)
			exit_code_set := json_key_present(text, "exit_code")
			if session_id != "" {
				shell_session_svc.shell_session_broadcast_stream_closed(h.shell_sessions, session_id, exit_code, exit_code_set)
			}
		}
	case "shell_exited":
		if h.shell_sessions != nil {
			session_id := json_string(text, "session_id")
			status := json_string(text, "status")
			if status == "" do status = strings.clone("exited")
			exit_code := json_int(text, "exit_code", 0)
			exit_code_set := json_key_present(text, "exit_code")
			// REQ-SHELL-4: which RUN of the session this exit is about. Absent means
			// UNSTATED, which handle_exited applies rather than discards — see
			// SHELL_SESSION_RUN_SEQ_UNSTATED for why that is not spelled 0.
			run_seq := json_int(text, "run_seq", shell_session_svc.SHELL_SESSION_RUN_SEQ_UNSTATED)
			if session_id != "" {
				// APPLY FIRST, BROADCAST ONLY IF IT APPLIED. The broadcast used to run
				// unconditionally and ahead of the decision, so an exit the hub then
				// discarded — a stale run's, or a duplicate replayed from the bridge's
				// durable outbox — still reached every attached viewer, showing them a
				// terminal status the row does not have and that nothing later corrects.
				if shell_session_svc.shell_session_handle_exited(h.shell_sessions, session_id, bridge_id, status, exit_code, exit_code_set, run_seq) {
					shell_session_svc.shell_session_broadcast_status(h.shell_sessions, session_id, status, exit_code, exit_code_set)
				}
			}
			delete(session_id)
			delete(status)
		}
	// REQ-SHELL-10: the bridge's FULL LIVE SESSION LIST, sent on every (re)connect.
	// The whole frame is handed to the service rather than being parsed here, matching
	// bridge_proxy_handle_open above: the diff's decisions and its parse belong in one
	// testable place, and this arm has no decision of its own to make.
	//
	// bridge_id is the AUTHENTICATED id of the connection this frame arrived on, never
	// anything the frame itself names — an inventory mutates many rows at once, so the
	// scope it is confined to must come from the transport, not from its payload.
	case "shell_inventory":
		if h.shell_sessions != nil {
			_ = shell_session_svc.shell_session_apply_inventory(h.shell_sessions, bridge_id, text)
		}
	// tunnel_data: bridge→hub direction — response bytes from the dev server.
	case "tunnel_data":
		if h.shell_sessions != nil {
			stream_id := json_string(text, "stream_id")
			data_b64 := json_string(text, "data_b64")
			if stream_id != "" && data_b64 != "" {
				decoded, decode_err := base64.decode(data_b64)
				if decode_err == nil && len(decoded) > 0 {
					shell_session_svc.shell_session_tunnel_deliver(h.shell_sessions, stream_id, decoded)
				}
				delete(decoded)
			}
			delete(stream_id)
			delete(data_b64)
		}
	// tunnel_close: bridge→hub direction — dev server connection closed.
	case "tunnel_close":
		if h.shell_sessions != nil {
			stream_id := json_string(text, "stream_id")
			if stream_id != "" {
				shell_session_svc.shell_session_tunnel_close_stream(h.shell_sessions, stream_id)
			}
			delete(stream_id)
		}
	// REQ-XM-4 (bridge_proxy_relay.odin): streams a bridge ORIGINATES toward the hub, as
	// opposed to the tunnel_* frames above which belong to streams the hub originated
	// toward a bridge. Deliberately separate names: the two directions have different
	// lifecycles and sharing the names would make both harder to follow.
	case "proxy_open":
		if h.shell_sessions != nil do bridge_proxy_handle_open(h, bridge_id, text)
	case "proxy_data":
		if h.shell_sessions != nil do bridge_proxy_handle_data(h, bridge_id, text)
	case "proxy_close":
		if h.shell_sessions != nil do bridge_proxy_handle_close(h, bridge_id, text)
	}

	return true
}

Bridge_Agent_Status_Report :: struct {
	agent_instance_id: string `json:"agent_instance_id"`,
	state_seq:         int    `json:"state_seq"`,
	runtime_status:    string `json:"runtime_status"`,
	activity_status:   string `json:"activity_status"`,
	launch_epoch: string `json:"launch_epoch"`,
}

Bridge_Heartbeat_Message :: struct {
	type:                string                       `json:"type"`,
	active_instance_ids: []string                     `json:"active_instance_ids"`,
	digest:              []Bridge_Agent_Status_Report `json:"digest"`,
	instances:           []Bridge_Agent_Status_Report `json:"instances"`,
}

// Serialize durable status writes with retirement. New connections do not finish
// admission until the old state writer has drained; a delayed old frame cannot
// save over the new generation's durable state.
bridge_apply_validated_status :: proc(h: ^Bridge_Handlers, bridge_id: string, generation: int, id: string, seq: int, status, activity: string, launch_epoch: string = "") -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	c := project_service.bridge_runtime_connection_acquire(h.bridge_runtime_registry, bridge_id, generation)
	if c == nil do return {}, false, domain.domain_error(.Bridge_Offline, "stale bridge generation")
	defer project_service.bridge_runtime_connection_release(h.bridge_runtime_registry, c)
	sync.lock(&c.state_mutex)
	if sync.atomic_load(&c.retired) {
		sync.unlock(&c.state_mutex)
		return {}, false, domain.domain_error(.Bridge_Offline, "retired bridge generation")
	}
	instance, applied, err := agent_service.apply_bridge_status_report(h.agents, bridge_id, id, seq, status, activity, owner_user_id = c.owner_id, launch_epoch = launch_epoch)
	sync.unlock(&c.state_mutex)
	if applied {
		_, _, tracking_err := project_service.bridge_runtime_instance_apply(h.bridge_runtime_registry, bridge_id, generation, id, string(instance.owner_user_id), string(instance.runtime_status), string(instance.activity_status), seq, recover = true)
		if tracking_err.code == .Bridge_Busy { fmt.eprintln("bridge runtime instance admission failed", bridge_id, id, tracking_err.message) }
	}
	return instance, applied, err
}

bridge_apply_heartbeat_digest :: proc(h: ^Bridge_Handlers, bridge_id, text: string, generation: int = 0) -> []string {
	current_generation := generation
	if h != nil && current_generation == 0 { current_generation = project_service.bridge_runtime_registry_generation(h.bridge_runtime_registry, bridge_id) }
	msg: Bridge_Heartbeat_Message
	if err := json.unmarshal_string(text, &msg, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
		return nil
	}

	reports := msg.digest
	if len(reports) == 0 do reports = msg.instances
	if len(reports) == 0 do return nil

	active := make([dynamic]string, context.allocator)
	for report in reports {
		if report.agent_instance_id == "" do continue
		if h != nil {
			if h.agents == nil {
				_ = bridge_runtime_service.runtime_apply_state_report(h.bridge_runtime_registry, bridge_id, current_generation, report.agent_instance_id, report.state_seq, report.runtime_status, report.activity_status, "")
			}
			if h.agents != nil {
				if inst, applied, _ := bridge_apply_validated_status(h, bridge_id, current_generation, report.agent_instance_id, report.state_seq, report.runtime_status, report.activity_status, report.launch_epoch); applied {
					summary := agent_instance_status_summary_json(inst.runtime_status, inst.startup_status, inst.activity_status)
					events.publish_resource_changed(h.event_bus, string(inst.owner_user_id), "agent_instance", inst.agent_instance_id, "status_changed", summary)
					delete(summary)
					domain.agent_instance_destroy(&inst)
				}
			}
		}
		append(&active, strings.clone(report.agent_instance_id, context.allocator))
	}
	return active[:]
}

bridge_ws_handler :: proc(ctx: rawptr, req: Request) -> Response {
	_ = ctx
	return respond_error(domain.domain_error(.Validation_Failed, "bridge runtime requires WebSocket upgrade"), req.request_id)
}

bridge_instance_bootstrap_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	if rejected, resp := reject_query_or_body_token(req); rejected do return resp
	token, token_ok := bearer_token(req)
	if !token_ok do return respond_error(domain.domain_error(.Unauthenticated, "bridge bearer token is required"), req.request_id)
	bridge_auth, bridge_ok, bridge_err := bridge_service.verify_bridge_token(h.bridges, token)
	if !bridge_ok do return respond_error(bridge_err, req.request_id)
	// Manifest-only path: the legacy bundle response has been removed (HUB-4).
	// The bridge always fetches the manifest and resolves fragment/skill blobs
	// via per-hash GETs; per-instance data is injected by the bridge locally.
	instance_id := path_part(req.path, 5)
	manifest, manifest_ok, manifest_err := agent_service.bootstrap_manifest_json_for_bridge(h.agents, domain.User_ID(bridge_auth.user_id), bridge_auth.bridge_id, instance_id)
	if !manifest_ok do return respond_error(manifest_err, req.request_id)
	return respond_success(manifest, req.request_id, auth_ctx_server_time(req))
}

// bridge_agent_manifest_handler serves the conditional, agent-keyed bootstrap
// manifest (HUB-2). It is keyed by (agent_id, role, provider, project) — NO
// per-instance data — and honors If-None-Match: an unchanged agent yields a 304
// (indexed version compare only; no render, no memories scan), while a changed
// input yields 200 + manifest + a fresh ETag. LOG-1: every request logs whether
// it was a 304 HIT or a 200 MISS (render) with agent/role/provider/version.
bridge_agent_manifest_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	if rejected, resp := reject_query_or_body_token(req); rejected do return resp
	token, token_ok := bearer_token(req)
	if !token_ok do return respond_error(domain.domain_error(.Unauthenticated, "bridge bearer token is required"), req.request_id)
	bridge_auth, bridge_ok, bridge_err := bridge_service.verify_bridge_token(h.bridges, token)
	if !bridge_ok do return respond_error(bridge_err, req.request_id)
	// /api/v1/bridge/agents/{agent_id}/bootstrap-manifest -> agent_id at index 5.
	agent_id := path_part(req.path, 5)
	role := query_value(req.query, "role")
	provider := query_value(req.query, "provider")
	project := query_value(req.query, "project")
	// If-None-Match arrives quoted on the wire (RFC 7232); the service compares
	// against the raw ETag value, so strip the surrounding quotes first.
	if_none_match := etag_unquote(strings.trim_space(header_value(req.headers, "If-None-Match")))

	result, ok, err := agent_service.bootstrap_manifest_conditional(h.agents, domain.User_ID(bridge_auth.user_id), agent_id, role, provider, project, bridge_auth.bridge_id, if_none_match)
	if !ok do return respond_error(err, req.request_id)

	if result.status == 304 {
		fmt.println("bootstrap-manifest HIT (304)", "agent=", agent_id, "role=", role, "provider=", provider, "project=", project, "version=", result.version)
		headers := make([]contracts.HTTP_Header, 1)
		headers[0] = contracts.HTTP_Header{name = "ETag", value = etag_quote(result.etag)}
		return Response{status = 304, content_type = "application/json", body = "", headers = headers}
	}
	fmt.println("bootstrap-manifest MISS (200 render)", "agent=", agent_id, "role=", role, "provider=", provider, "project=", project, "version=", result.version)
	resp := respond_success(result.manifest_json, req.request_id, auth_ctx_server_time(req))
	headers := make([]contracts.HTTP_Header, 1)
	headers[0] = contracts.HTTP_Header{name = "ETag", value = etag_quote(result.etag)}
	resp.headers = headers
	return resp
}

// etag_quote wraps a raw ETag value in double quotes if not already quoted, per
// RFC 7232. Matching against If-None-Match uses the raw value; the wire form is
// quoted.
etag_quote :: proc(value: string) -> string {
	if strings.has_prefix(value, "\"") do return value
	return strings.concatenate({"\"", value, "\""})
}

// etag_unquote strips surrounding double quotes (and an optional weak "W/"
// prefix) from a wire ETag so it can be compared against the raw stored value.
etag_unquote :: proc(value: string) -> string {
	v := value
	if strings.has_prefix(v, "W/") do v = v[2:]
	v = strings.trim_space(v)
	if len(v) >= 2 && strings.has_prefix(v, "\"") && strings.has_suffix(v, "\"") do return v[1:len(v) - 1]
	return v
}

// bridge_blobs_handler is the optional cold-start warmup: POST a batch of hashes,
// receive the fragment bodies (HUB-3 keeps this only as a warmup convenience; the
// primary path is the per-hash immutable GET below).
bridge_blobs_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	if rejected, resp := reject_query_or_body_token(req); rejected do return resp
	token, token_ok := bearer_token(req)
	if !token_ok do return respond_error(domain.domain_error(.Unauthenticated, "bridge bearer token is required"), req.request_id)
	_, bridge_ok, bridge_err := bridge_service.verify_bridge_token(h.bridges, token)
	if !bridge_ok do return respond_error(bridge_err, req.request_id)
	result := agent_service.resolve_blobs_json(h.agents, req.body)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

// bridge_blob_handler serves ONE immutable content-addressed fragment by hash
// (HUB-3). Because a sha256 hash is its own validity token, the response is
// marked immutable with a one-year max-age so the bridge's disk cache and any
// intermediary can cache it forever. LOG-1: log the hash served.
bridge_blob_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	if rejected, resp := reject_query_or_body_token(req); rejected do return resp
	token, token_ok := bearer_token(req)
	if !token_ok do return respond_error(domain.domain_error(.Unauthenticated, "bridge bearer token is required"), req.request_id)
	_, bridge_ok, bridge_err := bridge_service.verify_bridge_token(h.bridges, token)
	if !bridge_ok do return respond_error(bridge_err, req.request_id)
	// /api/v1/bridge/blobs/{hash} -> hash at index 5. Hashes are url-encoded
	// ("sha256%3A..") since they contain a colon; decode before lookup.
	hash := query_component_decode(path_part(req.path, 5))
	body, found := agent_service.resolve_single_blob(h.agents, hash)
	if !found {
		fmt.println("bootstrap-blob MISS (404)", "hash=", hash)
		return respond_error(domain.domain_error(.Not_Found, "blob not found"), req.request_id)
	}
	fmt.println("bootstrap-blob served", "hash=", hash)
	b := strings.builder_make()
	strings.write_string(&b, "{\"hash\":\"")
	write_handler_json_string(&b, hash)
	strings.write_string(&b, "\",\"body\":\"")
	write_handler_json_string(&b, body)
	strings.write_string(&b, "\"}")
	resp := respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
	headers := make([]contracts.HTTP_Header, 1)
	headers[0] = contracts.HTTP_Header{name = "Cache-Control", value = "immutable, max-age=31536000"}
	resp.headers = headers
	return resp
}

// bridge_actionable_tasks_handler returns the compact actionable-task set for the
// calling bridge's hosted instances. The Bridge scheduler polls this once per
// tick to drive auto-promotion and auto-nudge locally, keeping the Hub lean.
bridge_actionable_tasks_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	if rejected, resp := reject_query_or_body_token(req); rejected do return resp
	token, token_ok := bearer_token(req)
	if !token_ok do return respond_error(domain.domain_error(.Unauthenticated, "bridge bearer token is required"), req.request_id)
	bridge_auth, bridge_ok, bridge_err := bridge_service.verify_bridge_token(h.bridges, token)
	if !bridge_ok do return respond_error(bridge_err, req.request_id)
	if h.taskchains == nil do return respond_error(domain.domain_error(.Internal_Error, "taskchain service is not configured"), req.request_id)
	items, err := taskchain_service.actionable_tasks_for_bridge(h.taskchains, domain.User_ID(bridge_auth.user_id), bridge_auth.bridge_id)
	if err.code != .None do return respond_error(err, req.request_id)
	b := strings.builder_make()
	strings.write_string(&b, "{\"tasks\":[")
	for item, i in items {
		if i > 0 do strings.write_byte(&b, ',')
		write_actionable_task_json(&b, item)
	}
	strings.write_string(&b, "]}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

write_actionable_task_json :: proc(b: ^strings.Builder, t: taskchain_service.Actionable_Task) {
	strings.write_string(b, "{\"task_id\":\""); write_handler_json_string(b, string(t.task_id))
	strings.write_string(b, "\",\"chain_id\":\""); write_handler_json_string(b, string(t.chain_id))
	strings.write_string(b, "\",\"status\":\""); write_handler_json_string(b, task_status_http(t.status))
	strings.write_string(b, "\",\"title\":\""); write_handler_json_string(b, t.title)
	strings.write_string(b, "\",\"target_instance_id\":\""); write_handler_json_string(b, t.target_instance_id)
	strings.write_string(b, "\",\"target_role\":\""); write_handler_json_string(b, taskchain_service.target_string(t.target_role))
	strings.write_string(b, "\",\"action\":\""); write_handler_json_string(b, t.action)
	strings.write_string(b, "\",\"updated_at\":\""); write_handler_json_string(b, t.updated_at)
	strings.write_string(b, "\",\"deps_satisfied\":"); strings.write_string(b, "true" if t.deps_satisfied else "false")
	strings.write_string(b, "}")
}

revoke_bridge_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	bridge_id := strings.trim_suffix(suffix_after(req.path, "/api/v1/bridges/"), "/revoke")
	bridge, revoke_ok, err := bridge_service.revoke_bridge(h.bridges, auth_ctx, bridge_id)
	if !revoke_ok do return respond_error(err, req.request_id)
	// The live connection (if any) is being shut down and will tombstone on its
	// own teardown; do it here too so an offline revoked bridge leaves no info.
	project_service.fleet_metrics_tombstone_bridge(bridge.bridge_id)
	// A revoked bridge's error ring goes with it (plan §4.3).
	if h.bridge_logs != nil do _, _ = bridge_log_service.purge_bridge(h.bridge_logs, bridge.bridge_id)
	b := strings.builder_make()
	write_bridge_json(&b, bridge, h.agents, h.bridges.catalog)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

bridge_update_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp

	bridge_id := strings.trim_suffix(suffix_after(req.path, "/api/v1/bridges/"), "/update")
	if strings.trim_space(bridge_id) == "" {
		return respond_error(domain.domain_error(.Validation_Failed, "bridge_id is required"), req.request_id)
	}

	bridge, bridge_ok, err := bridge_service.get_bridge(h.bridges, auth_ctx, bridge_id)
	if !bridge_ok do return respond_error(err, req.request_id)

	// Validate bridge state and reject offline or not-live bridges with 422
	if bridge.status != .Online || !project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry, bridge.bridge_id) {
		return respond_error(domain.domain_error(.Unprocessable_Entity, fmt.tprintf("Bridge %s is not online", bridge.bridge_id)), req.request_id)
	}

	force := json_bool_value(req.body, "force")
	drain_timeout := json_int(req.body, "drain_timeout_seconds", 60)
	target_version_raw := json_string(req.body, "target_version")
	defer if len(target_version_raw) > 0 do delete(target_version_raw)
	target_version := target_version_raw if len(target_version_raw) > 0 else "latest"

	active_tasks := agent_service.active_instance_count_for_bridge(h.agents, bridge.bridge_id)
	if active_tasks > 0 && !force && drain_timeout <= 0 {
		return respond_error(domain.domain_error(.Conflict, fmt.tprintf("Bridge %s has %d active agent tasks; specify force=true or a positive drain_timeout_seconds", bridge.bridge_id, active_tasks)), req.request_id)
	}

	cmd_id, send_ok, send_err := bridge_service.send_bridge_update(h.bridges, auth_ctx, bridge.bridge_id, target_version, force, drain_timeout)
	if !send_ok {
		if send_err.code == .Bridge_Offline || send_err.code == .Unprocessable_Entity {
			return respond_error(domain.domain_error(.Unprocessable_Entity, send_err.message), req.request_id)
		}
		return respond_error(send_err, req.request_id)
	}
	defer delete(cmd_id)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "{\"command_id\":\"")
	write_handler_json_string(&b, cmd_id)
	strings.write_string(&b, "\",\"bridge_id\":\"")
	write_handler_json_string(&b, bridge.bridge_id)
	strings.write_string(&b, "\",\"status\":\"dispatched\",\"target_version\":\"")
	write_handler_json_string(&b, target_version)
	strings.write_string(&b, "\",\"active_tasks\":")
	strings.write_string(&b, fmt.tprintf("%d", active_tasks))
	strings.write_string(&b, ",\"drain_timeout_seconds\":")
	strings.write_string(&b, fmt.tprintf("%d", drain_timeout))
	strings.write_string(&b, "}")

	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 202)
}

bearer_token :: proc(req: Request) -> (string, bool) {
	authz := header_value(req.headers, "Authorization")
	if !strings.has_prefix(authz, "Bearer ") do return "", false
	return strings.trim_space(authz[len("Bearer "):]), true
}

suffix_after :: proc(value, prefix: string) -> string {
	if strings.has_prefix(value, prefix) do return value[len(prefix):]
	return ""
}

write_bridge_json :: proc(b: ^strings.Builder, br: domain.Bridge, agents: ^agent_service.Agent_Service, catalog: ^bridge_service.Bridge_Update_Catalog = nil) {
	strings.write_string(b, "{\"bridge_id\":\""); write_handler_json_string(b, br.bridge_id)
	strings.write_string(b, "\",\"label\":\""); write_handler_json_string(b, br.label)
	strings.write_string(b, "\",\"label_is_user_customized\":"); strings.write_string(b, "true" if br.label_is_user_customized else "false")
	strings.write_string(b, ",\"machine_hostname\":\""); write_handler_json_string(b, br.machine_hostname)
	strings.write_string(b, "\",\"machine_os\":\""); write_handler_json_string(b, br.machine_os)
	strings.write_string(b, "\",\"machine_arch\":\""); write_handler_json_string(b, br.machine_arch)
	strings.write_string(b, "\",\"hub_url\":\""); write_handler_json_string(b, br.hub_url)
	strings.write_string(b, "\",\"status\":\""); write_handler_json_string(b, domain.bridge_status_string(br.status))
	strings.write_string(b, "\",\"capabilities\":"); strings.write_string(b, bridge_capabilities_json(br))
	connected := agents != nil && project_service.bridge_runtime_registry_has_live(agents.bridge_runtime_registry, br.bridge_id)
	strings.write_string(b, ",\"runtime_connected\":"); strings.write_string(b, "true" if connected else "false")
	strings.write_string(b, ",\"reconfiguration_supported\":"); strings.write_string(b, "true" if agent_service.reconfiguration_bridge_supported(br) else "false")
	strings.write_string(b, ",\"active_instance_count\":"); strings.write_string(b, fmt.tprintf("%d", agent_service.active_instance_count_for_bridge(agents, br.bridge_id)))
	strings.write_string(b, ",\"version\":\""); write_handler_json_string(b, br.version)
	strings.write_string(b, "\",\"commit_sha\":\""); write_handler_json_string(b, br.commit_sha)
	strings.write_string(b, "\",\"build_timestamp\":\""); write_handler_json_string(b, br.build_timestamp)
	strings.write_string(b, "\",\"update_status\":\""); write_handler_json_string(b, br.update_status if br.update_status != "" else "idle")
	strings.write_string(b, "\",\"update_message\":\""); write_handler_json_string(b, br.update_message)
	strings.write_string(b, "\",\"update_progress\":"); strings.write_string(b, fmt.tprintf("%d", br.update_progress))
	strings.write_string(b, ",\"update_error\":\""); write_handler_json_string(b, br.update_error)
	strings.write_string(b, "\",\"last_seen_at\":\""); write_handler_json_string(b, br.last_seen_at)
	strings.write_string(b, "\",\"updated_at\":\""); write_handler_json_string(b, br.updated_at)
	strings.write_string(b, "\",\"revoked_at\":\""); write_handler_json_string(b, br.revoked_at)
	update_info := bridge_service.resolve_bridge_update_info(catalog, br)
	strings.write_string(b, "\",\"target\":\""); write_handler_json_string(b, update_info.target)
	strings.write_string(b, "\",\"update_available\":"); strings.write_string(b, "true" if update_info.update_available else "false")
	// REQ-T13-2: false when the latest release ships no bundle for `target`.
	strings.write_string(b, ",\"update_artifact_available\":"); strings.write_string(b, "true" if update_info.artifact_available else "false")
	strings.write_string(b, ",\"latest_version\":\""); write_handler_json_string(b, update_info.latest_version)
	strings.write_string(b, "\",\"latest_commit_sha\":\""); write_handler_json_string(b, update_info.latest_commit_sha)
	strings.write_string(b, "\",\"telemetry_enabled\":\""); write_handler_json_string(b, br.telemetry_enabled if br.telemetry_enabled != "" else "inherit")
	// REQ-BVS-2: emitted VERBATIM, with no default substitution. A bridge that has
	// never reported yields "", and the key is always present, so the UI can tell
	// "not reported" apart from a real state instead of being told "unlocked".
	strings.write_string(b, "\",\"vault_status\":\""); write_handler_json_string(b, br.vault_status)
	search_ready, search_stale, search_revision := false, false, i64(0)
	if agents != nil && agents.bridge_runtime_registry != nil {
		search_ready, search_stale, search_revision = project_service.bridge_runtime_registry_task_chain_search_status(agents.bridge_runtime_registry, br.bridge_id)
	}
	strings.write_string(b, `","task_chain_search_ready":`); strings.write_string(b, "true" if search_ready else "false")
	strings.write_string(b, `,"task_chain_search_stale":`); strings.write_string(b, "true" if search_stale else "false")
	strings.write_string(b, `,"task_chain_search_revision":`); strings.write_string(b, fmt.tprintf("%d", search_revision))
	pub_key := ""
	owned_key := ""
	defer delete(owned_key)
	if agents != nil && agents.bridge_runtime_registry != nil {
		owned_key = project_service.bridge_runtime_registry_public_key(agents.bridge_runtime_registry, br.bridge_id)
		pub_key = owned_key
	}
	if pub_key == "" && br.capabilities_json != "" {
		pub_key = json_string(br.capabilities_json, "public_key", context.temp_allocator)
	}
	strings.write_string(b, ",\"public_key\":\""); write_handler_json_string(b, pub_key)
	strings.write_string(b, "\",\"bridge_public_key\":\""); write_handler_json_string(b, pub_key)
	strings.write_string(b, "\"}")
}

json_string :: proc(body, key: string, allocator := context.allocator) -> string {
	return jsonx.extract_string(body, key, allocator = allocator)
}

json_string_unescaped :: proc(body, key: string, allocator := context.allocator) -> string {
	return jsonx.extract_string(body, key, allocator = allocator)
}

json_object_raw_balanced :: proc(body, key: string, allocator := context.allocator) -> (string, bool) {
	return jsonx.extract_raw_object(body, key, allocator = allocator)
}

json_array_raw_balanced :: proc(body, key: string, allocator := context.allocator) -> (string, bool) {
	return jsonx.extract_raw_array(body, key, allocator = allocator)
}

bridge_capabilities_json :: proc(br: domain.Bridge) -> string {
	if br.capabilities_json == "" || !strings.contains(br.capabilities_json, "capabilities") do return "[]"
	if caps, ok := json_array_raw_balanced(br.capabilities_json, "capabilities"); ok do return caps
	provider := json_string(br.capabilities_json, "provider")
	defer delete(provider)
	default_model := json_string(br.capabilities_json, "default_model")
	defer delete(default_model)
	if provider == "" do return "[]"
	b := strings.builder_make()
	strings.write_string(&b, "[{\"provider\":\""); write_handler_json_string(&b, provider)
	strings.write_string(&b, "\",\"models\":[]")
	strings.write_string(&b, ",\"default_model\":\""); write_handler_json_string(&b, default_model)
	strings.write_string(&b, "\"}]")
	return strings.to_string(b)
}

json_key_present :: proc(body, key: string) -> bool {
	return jsonx.has_key(body, key)
}

// heartbeat_stats tells the bridge whether to attach resource stats to its
// heartbeats (plan 4.3): false only when the owner set telemetry_enabled=disabled.
bridge_ready_payload :: proc(bridge_id: string, generation: int, replaced: bool, catalog_etag: string = "", heartbeat_stats := true) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"bridge_ready\",\"protocol_version\":1,\"payload\":{\"bridge_id\":\"")
	write_handler_json_string(&b, bridge_id)
	strings.write_string(&b, "\",\"heartbeat_interval_seconds\":15,\"command_ack_timeout_seconds\":10,\"connection_generation\":")
	strings.write_string(&b, fmt.tprintf("%d", generation))
	strings.write_string(&b, ",\"replaced_existing\":")
	strings.write_string(&b, "true" if replaced else "false")
	strings.write_string(&b, ",\"catalog_etag\":\"")
	write_handler_json_string(&b, catalog_etag)
	strings.write_string(&b, "\"")
	strings.write_string(&b, ",\"heartbeat_stats\":")
	strings.write_string(&b, "true" if heartbeat_stats else "false")
	strings.write_string(&b, "}}")
	return strings.to_string(b)
}

bridge_provider_catalog_payload :: proc(providers: ^provider_service.Provider_Service) -> (string, bool) {
	result, err := provider_service.list_catalog(providers)
	if err.code != .None do return bridge_ws_error_payload(err.message), false
	defer {
		domain.provider_catalog_destroy(result.providers)
		delete(result.catalog_etag)
	}
	body := provider_service.catalog_body_json(result.providers)
	defer delete(body)
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"provider_catalog\",\"catalog_etag\":\"")
	write_handler_json_string(&b, result.catalog_etag)
	strings.write_string(&b, "\",\"catalog_json\":\"")
	write_handler_json_string(&b, body)
	strings.write_string(&b, "\"}")
	return strings.to_string(b), true
}

bridge_provider_catalog_version_payload :: proc(catalog_etag: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"provider_catalog_version\",\"catalog_etag\":\"")
	write_handler_json_string(&b, catalog_etag)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

// bridge_set_telemetry_payload carries TWO explicit switches so "inherit" means
// the same thing at PATCH time as at hello time:
//   enabled         — the local Telegraf exporter; true only for "enabled".
//   heartbeat_stats — heartbeat resource stats AND bridge_log shipping; true
//                     unless the owner chose "disabled" (same rule as
//                     bridge_ready.heartbeat_stats).
// Old bridges read only `enabled`; new bridges prefer `heartbeat_stats` and
// fall back to `enabled` when the key is absent (old hubs).
bridge_set_telemetry_payload :: proc(command_id: string, enabled: bool, heartbeat_stats := true) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"set_telemetry\",\"command_id\":\"")
	write_handler_json_string(&b, command_id)
	strings.write_string(&b, "\",\"enabled\":")
	strings.write_string(&b, "true" if enabled else "false")
	strings.write_string(&b, ",\"heartbeat_stats\":")
	strings.write_string(&b, "true" if heartbeat_stats else "false")
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

bridge_connection_replaced_payload :: proc() -> string {
	return "{\"type\":\"connection_replaced\",\"protocol_version\":1,\"payload\":{\"reason\":\"newer_bridge_connection\"}}"
}

bridge_heartbeat_ack_payload :: proc(reconciled: int, superseded_instance_ids: []string = nil, schedules_version: int = 0) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"bridge_heartbeat_ack\",\"protocol_version\":1,\"payload\":{\"reconciled_unreachable_count\":")
	strings.write_string(&b, fmt.tprintf("%d", reconciled))
	strings.write_string(&b, ",\"schedules_version\":")
	strings.write_string(&b, fmt.tprintf("%d", schedules_version))
	// H7: instance ids the reporting bridge must reap (relaunched on another
	// bridge). The bridge invalidates their local tokens so the stale wrapper exits.
	strings.write_string(&b, ",\"superseded_instance_ids\":[")
	for id, i in superseded_instance_ids {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_byte(&b, '"')
		write_handler_json_string(&b, id)
		strings.write_byte(&b, '"')
	}
	strings.write_string(&b, "]}}")
	return strings.to_string(b)
}

agent_instance_status_summary_json :: proc(runtime_status, startup_status, activity_status: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"runtime_status\":\""); write_handler_json_string(&b, runtime_status)
	strings.write_string(&b, "\",\"startup_status\":\""); write_handler_json_string(&b, startup_status)
	strings.write_string(&b, "\",\"activity_status\":\""); write_handler_json_string(&b, activity_status)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

// bridge_apply_vault_status_report stores a bridge's self-reported vault tri-state and
// publishes the bridge invalidation ONLY when the stored value actually moved
// (REQ-BVS-1). Shared by the bridge_heartbeat arm, which carries the field on every
// ~45s beat, and the dedicated bridge_vault_status arm the bridge sends immediately
// after an unseal or a lock. Both go through here so there is one store-and-publish
// path and the change detection cannot drift between them.
//
// A frame with no vault_status (an older bridge build) is a no-op: the empty value is
// rejected by the service, which leaves any previously reported value in place rather
// than erasing it.
//
// update_vault_status returns a FULLY OWNED row on every successful path, including
// the unchanged one, so it is destroyed unconditionally here. This proc runs on the
// bridge WS runtime loop, which has no per-request arena to reclaim it: a row kept
// instead of freed would leak on every heartbeat of every bridge, forever.
bridge_apply_vault_status_report :: proc(h: ^Bridge_Handlers, bridge_id, text: string) {
	if h == nil || h.bridges == nil do return
	value := json_string(text, "vault_status")
	defer delete(value)
	if value == "" do return
	bridge, changed, _ := bridge_service.update_vault_status(h.bridges, bridge_id, value)
	defer { b := bridge; domain.bridge_destroy(&b) }
	if !changed do return
	summary := bridge_vault_status_summary_json(bridge.vault_status)
	defer delete(summary)
	events.publish_resource_changed(h.event_bus, string(bridge.owner_user_id), "bridge", bridge.bridge_id, "vault_status_changed", summary)
}

bridge_vault_status_summary_json :: proc(vault_status: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"vault_status\":\""); write_handler_json_string(&b, vault_status)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

bridge_status_summary_json :: proc(status: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"status\":\""); write_handler_json_string(&b, status)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

bridge_update_summary_json :: proc(status, message: string, progress: int, update_error: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"update_status\":\""); write_handler_json_string(&b, status)
	strings.write_string(&b, "\",\"update_message\":\""); write_handler_json_string(&b, message)
	strings.write_string(&b, "\",\"update_progress\":"); strings.write_string(&b, fmt.tprintf("%d", progress))
	strings.write_string(&b, ",\"update_error\":\""); write_handler_json_string(&b, update_error)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

bridge_state_ack_payload :: proc(instance_id: string, applied: bool, state_seq: int, runtime_status: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"agent_instance_status_ack\",\"protocol_version\":1,\"payload\":{\"agent_instance_id\":\"")
	write_handler_json_string(&b, instance_id)
	strings.write_string(&b, "\",\"applied\":")
	strings.write_string(&b, "true" if applied else "false")
	strings.write_string(&b, ",\"state_seq\":")
	strings.write_string(&b, fmt.tprintf("%d", state_seq))
	strings.write_string(&b, ",\"runtime_status\":\"")
	write_handler_json_string(&b, runtime_status)
	strings.write_string(&b, "\"}}")
	return strings.to_string(b)
}

bridge_ws_error_payload :: proc(message: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"bridge_error\",\"protocol_version\":1,\"payload\":{\"message\":\"")
	write_handler_json_string(&b, message)
	strings.write_string(&b, "\"}}")
	return strings.to_string(b)
}

write_upgrade_error :: proc(client: net.TCP_Socket, resp: Response) { write_http_response(client, resp) }

write_ws_upgrade_response :: proc(client: net.TCP_Socket, accept_key: string) -> bool {
	response := fmt.tprintf("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", accept_key)
	_, err := net.send_tcp(client, transmute([]byte)response)
	return err == nil
}

ws_accept_key :: proc(key: string) -> string {
	GUID :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
	combined := fmt.tprintf("%s%s", key, GUID)
	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]byte)combined)
	digest: [sha1.DIGEST_SIZE]byte
	sha1.final(&ctx, digest[:])
	return base64.encode(digest[:])
}

// Bridge_WS_Reader holds the bridge command socket and a DURABLE receive buffer
// that persists across read_ws_text_blocking calls. The kernel can deliver several
// WS frames in one recv (e.g. a heartbeat/state frame coalesced with an fs_read_
// file_result); the previous per-call buffer returned the first frame and threw the
// rest away, so the coalesced result was permanently lost and the fs request timed
// out (the size-correlated >16KB failure). Keeping leftover bytes here — mirroring
// the bridge side's ws.Connection.pending_bytes — means every frame is delivered.
Bridge_WS_Reader :: struct {
	socket:            net.TCP_Socket,
	// Cached rx byte counter for this connection (nil until the bridge is known).
	bytes_series:      ^metrics.Series,
	pending:           [dynamic]byte,
	fatal_reason:      Bridge_WS_Disconnect_Reason,
	fragmented:        [dynamic]byte,
	fragmenting:       bool,
	fragmented_opcode: u8,
	control_context: rawptr,
	control_writer: proc(rawptr, net.TCP_Socket, string) -> bool,
}

bridge_ws_reader_make :: proc(socket: net.TCP_Socket) -> Bridge_WS_Reader {
	return Bridge_WS_Reader{
		socket     = socket,
		pending    = make([dynamic]byte),
		fragmented = make([dynamic]byte),
	}
}

bridge_ws_reader_destroy :: proc(reader: ^Bridge_WS_Reader) {
	if reader != nil {
		delete(reader.pending)
		delete(reader.fragmented)
		reader.pending = nil
		reader.fragmented = nil
		reader.fragmenting = false
	}
}

// bridge_ws_take_frame extracts ONE complete text frame or reassembled fragmented
// message from reader.pending, consuming its bytes and leaving any trailing bytes
// for the next call.
//
// Full RFC 6455 framing support (REQ-WS-FIX-2):
// - Decodes 64-bit extended payload lengths up to ws.WS_READER_DEFAULT_MAX_BUFFER_BYTES (32 MiB).
// - Interleaved Ping (0x9) control frames respond with Pong (0x8A 0x00) if socket != 0 and continue.
// - Interleaved Pong (0xA) control frames are ignored and continue.
// - Close (0x8) sets reader.fatal_reason = .Clean_Close and returns fatal = true.
// - Fragmented messages (FIN=0 text frames followed by 0x0 continuation frames up to FIN=1)
//   are reassembled into reader.fragmented and returned on FIN=1.
bridge_ws_take_frame :: proc(reader: ^Bridge_WS_Reader) -> (text: string, ok: bool, fatal: bool) {
	for {
		op, fin, payload, has_frame, ok_frame := ws.take_one_frame_from_pending(
			&reader.pending,
			allow_64bit = true,
			max_buffer_bytes = ws.WS_READER_DEFAULT_MAX_BUFFER_BYTES,
		)
		if !ok_frame {
			reader.fatal_reason = .Fatal_Frame
			return "", false, true
		}
		if !has_frame {
			return "", false, false
		}

		// Control frames ((op & 0x08) != 0)
		if (op & 0x08) != 0 {
			if !fin || len(payload) > 125 {
				delete(payload)
				reader.fatal_reason = .Fatal_Frame
				return "", false, true
			}
			if op == 0x8 {
				delete(payload)
				reader.fatal_reason = .Clean_Close
				return "", false, true
			}
			if op == 0x9 {
				delivered := true
				if reader.socket != 0 {
					if reader.control_writer != nil { delivered = reader.control_writer(reader.control_context, reader.socket, payload) } else { delivered = ws.write_server_opcode(reader.socket, 0xA, payload, true) == .Ok }
				}
				delete(payload)
				if !delivered { reader.fatal_reason = .Write_Failed; return "", false, true }
				continue
			}
			if op == 0xA {
				delete(payload)
				continue
			}
			delete(payload)
			reader.fatal_reason = .Fatal_Frame
			return "", false, true
		}

		// Data and continuation frames
		switch op {
		case 0x1:
			if reader.fragmenting {
				delete(payload)
				reader.fatal_reason = .Fatal_Frame
				return "", false, true
			}
			if fin {
				return payload, true, false
			}
			reader.fragmenting = true
			reader.fragmented_opcode = op
			clear(&reader.fragmented)
			append(&reader.fragmented, ..transmute([]u8)payload)
			delete(payload)
			continue
		case 0x0:
			if !reader.fragmenting {
				delete(payload)
				reader.fatal_reason = .Fatal_Frame
				return "", false, true
			}
			if len(reader.fragmented) + len(payload) > ws.WS_CONTINUATION_DEFAULT_MAX_BYTES {
				delete(payload)
				reader.fatal_reason = .Fatal_Frame
				return "", false, true
			}
			append(&reader.fragmented, ..transmute([]u8)payload)
			delete(payload)
			if fin {
				reader.fragmenting = false
				assembled := strings.clone(string(reader.fragmented[:]))
				clear(&reader.fragmented)
				return assembled, true, false
			}
			continue
		case:
			delete(payload)
			reader.fatal_reason = .Fatal_Frame
			return "", false, true
		}
	}
}


// read_ws_text_blocking reads one frame, reporting only WHETHER it got one.
//
// Kept as a wrapper over bridge_ws_read_frame so the callers that genuinely do not care
// why a read ended (the hello read, and the agent-instance / shell-session streams) stay
// exactly as they were. Anything that must REPORT the cause — the bridge runtime loop —
// calls bridge_ws_read_frame directly.
read_ws_text_blocking :: proc(reader: ^Bridge_WS_Reader, timeout: time.Duration) -> (string, bool) {
	text, ok, _ := bridge_ws_read_frame(reader, timeout)
	return text, ok
}

// bridge_ws_read_frame reads one frame and, when it cannot, says WHY.
//
// REQ-SHELL-41. This proc is the whole reason the task is not a one-line logging change.
// Its predecessor returned a bare bool, so a desynced frame, a 120s deadline expiry and
// a graceful peer close were indistinguishable at every call site — the reason was
// destroyed here, below the layer that needed to log it. The three outcomes are now
// separated at the exact points where they are still distinguishable:
//   - fatal from the framer      -> reader.fatal_reason (Clean_Close for a close opcode,
//                                   Fatal_Frame for a desync)
//   - recv `0, nil`              -> Clean_Close. core:net documents a graceful close as
//                                   exactly this, so it must NOT be lumped in with the
//                                   error arm the way `n <= 0 || err != nil` used to.
//   - .Would_Block / .Timeout    -> Read_Deadline. A blocking socket with SO_RCVTIMEO
//                                   reports an expired deadline as EAGAIN, which
//                                   core:net maps to .Would_Block, so both belong here.
//   - anything else              -> Recv_Error (ECONNRESET and friends).
bridge_ws_read_frame :: proc(
	reader: ^Bridge_WS_Reader,
	timeout: time.Duration,
) -> (string, bool, Bridge_WS_Disconnect_Reason) {
	// A frame may already be buffered from a previous coalesced recv — return it
	// without blocking on the socket.
	reader.fatal_reason = .None
	if text, ok, fatal := bridge_ws_take_frame(reader); fatal {
		return "", false, reader.fatal_reason
	} else if ok {
		return text, true, .None
	}
	_ = net.set_option(reader.socket, .Receive_Timeout, timeout)
	buf: [8192]byte
	for {
		n, err := net.recv_tcp(reader.socket, buf[:])
		if err != nil {
			if err == net.TCP_Recv_Error.Would_Block || err == net.TCP_Recv_Error.Timeout {
				return "", false, .Read_Deadline
			}
			return "", false, .Recv_Error
		}
		if n <= 0 do return "", false, .Clean_Close
		metrics.counter_add(reader.bytes_series, u64(n))
		append(&reader.pending, ..buf[:n])
		reader.fatal_reason = .None
		if text, ok, fatal := bridge_ws_take_frame(reader); fatal {
			return "", false, reader.fatal_reason
		} else if ok {
			return text, true, .None
		}
	}
}

// write_ws_text_frame writes one text frame on a socket that must stay within the
// 16-bit WebSocket length. REQ-SHELL-33 moved the framing itself into ws.write_server_text
// (three length arms, short-write loop, typed result); what stays here is the CHOICE.
//
// THE 16-BIT BOUND ON THIS WRITER IS DELIBERATE, NOT A MISSING FEATURE. Its callers
// include the BRIDGE command socket (the hello/error payloads at :1196-:1199 and every
// write_ws_text_frame_locked send), and our own bridge readers treat a 64-bit length as
// FATAL — src/lib/ws/ws.odin:200 drops the connection, bridge_ws_take_frame below returns
// fatal=true. Emitting one toward a bridge would turn a dropped frame into a killed bridge
// connection. That channel already chunks at the application level (kind:"chunk") so that
// no frame reaches the cap; this bound is the other half of that contract.
//
// Browser-facing callers whose payload can actually be large must use
// write_ws_text_frame_browser instead. Every caller left on THIS proc sends a small,
// fixed-shape control payload — a ready, an ack, an error — so Too_Large here means a bug,
// which is why it is logged rather than passed on: the bool tells the caller whether the
// frame arrived, and no caller of this one can do anything different about why.
write_ws_text_frame :: proc(client: net.TCP_Socket, text: string) -> bool {
	result := ws.write_server_text(client, text, false)
	if result == .Too_Large {
		fmt.eprintfln(
			"ham-hub WARN ws control frame exceeds the 16-bit length and was NOT sent bytes=%d limit=%d",
			len(text),
			ws.WS_16BIT_MAX_PAYLOAD,
		)
	}
	return result == .Ok
}

// write_ws_text_frame_browser writes one text frame to a BROWSER socket, where the 64-bit
// length arm is both correct and safe (the browser WebSocket stack parses it; see
// write_ws_text_frame for why the bridge channel cannot). It returns the typed result
// because its callers — the screen snapshot above all — must distinguish a frame they could
// not encode from a peer that is gone.
write_ws_text_frame_browser :: proc(client: net.TCP_Socket, text: string) -> ws.Text_Write_Result {
	return ws.write_server_text(client, text, true)
}

// write_ws_text_frame_locked serializes a write to the bridge command socket with
// every other write to it (the runtime loop's acks AND concurrent fs/file command
// sends on other threads), holding the registry command lock only for the write so
// bytes never interleave into a corrupt frame. Use this for any write AFTER the
// command socket is registered.
write_ws_text_frame_locked :: proc(h: ^Bridge_Handlers, bridge_id: string, client: net.TCP_Socket, text: string) -> bool {
	connection := project_service.bridge_runtime_connection_acquire(h.bridge_runtime_registry, bridge_id)
	if connection == nil do return false
	defer project_service.bridge_runtime_connection_release(h.bridge_runtime_registry, connection)
	sync.lock(&connection.writer_mutex)
	defer sync.unlock(&connection.writer_mutex)
	if sync.atomic_load(&connection.retired) || connection.socket != client do return false
	result := ws.write_server_text(client, text, false)
	if result == .Peer_Gone || result == .Desynchronised do _ = net.shutdown(net.Any_Socket(client), .Both)
	if result == .Ok do bridge_runtime_service.bridge_command_track_sent(connection, text)
	return result == .Ok
}

json_string_array :: proc(body, key: string, allocator := context.allocator) -> []string {
	dyn := jsonx.extract_string_array(body, key, allocator = allocator)
	return dyn[:]
}

json_bool_value :: proc(body, key: string) -> bool {
	return jsonx.extract_bool(body, key, fallback = false)
}

pane_capture_chat_event_json :: proc(c:domain.Chat_Conversation,m:domain.Chat_Message)->string{ b:=strings.builder_make(); strings.write_string(&b,"{\"type\":\"chat_event\",\"event\":\"chat_updated\",\"agent_instance_id\":\""); write_handler_json_string(&b,c.agent_instance_id); strings.write_string(&b,"\",\"conversation_id\":\""); write_handler_json_string(&b,c.conversation_id); strings.write_string(&b,"\",\"message_id\":\""); write_handler_json_string(&b,m.message_id); strings.write_string(&b,"\",\"direction\":\"pane_capture\",\"fetch_required\":true,\"fetch_kind\":\"chat_message\",\"fetch_id\":\""); write_handler_json_string(&b,m.message_id); strings.write_string(&b,"\",\"message_type\":\""); write_handler_json_string(&b,m.message_type); strings.write_string(&b,"\",\"message_status\":\""); write_handler_json_string(&b,m.message_status); strings.write_string(&b,"\"}"); return strings.to_string(b) }

json_int :: proc(body, key: string, default_value: int) -> int {
	return jsonx.extract_int(body, key, default_value)
}

bridge_reader_write_pong :: proc(raw: rawptr, socket: net.TCP_Socket, payload: string) -> bool {
	c := (^project_service.Bridge_Runtime_Connection)(raw)
	sync.mutex_lock(&c.writer_mutex)
	defer sync.mutex_unlock(&c.writer_mutex)
	if sync.atomic_load(&c.retired) do return false
	return ws.write_server_opcode(socket, 0xA, payload, false) == .Ok
}

pane_reader_write_pong :: proc(raw: rawptr, socket: net.TCP_Socket, payload: string) -> bool {
	return shell_session_svc.shell_session_enqueue_viewer_control((^shell_session_svc.Shell_Session_Service)(raw), socket, 0xA, payload)
}
