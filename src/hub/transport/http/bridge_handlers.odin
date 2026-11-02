package http

import "base:runtime"

import "core:crypto/legacy/sha1"
import base64 "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode/utf8"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import auth_service "odin_test:hub/service/auth"
import agent_service "odin_test:hub/service/agent"
import events "odin_test:hub/service/events"
import vd "odin_test:hub/service/vault_directory"
import platform "odin_test:hub/platform"
import bridge_service "odin_test:hub/service/bridge"
import device_auth_service "odin_test:hub/service/device_auth"
import bridge_log_service "odin_test:hub/service/bridge_log"
import bridge_runtime_service "odin_test:hub/service/bridge_runtime"
import content_service "odin_test:hub/service/content"
import project_service "odin_test:hub/service/project"
import provider_service "odin_test:hub/service/provider"
import taskchain_service "odin_test:hub/service/taskchain"
import taskv2 "odin_test:hub/service/taskv2"
import ws "odin_test:lib/ws"
import shell_session_svc "odin_test:hub/service/shell_session"
import jsonx "odin_test:lib/jsonx"
import vault "odin_test:lib/vault"
import metrics "odin_test:lib/metrics"

Bridge_Handlers :: struct {
	entitlements: domain.Entitlement_Lookup,
	auth: ^auth_service.Auth_Service,
	bridges: ^bridge_service.Bridge_Service,
	agents: ^agent_service.Agent_Service,
	content: ^content_service.Content_Service,
	taskchains: ^taskchain_service.Taskchain_Service,
	projects: ^project_service.Project_Service,
	event_bus: ^events.User_Event_Bus,
	bridge_runtime_registry: ^project_service.Bridge_Runtime_Registry,
	mcp_control: ^MCP_Control_Handlers,
	actions: rawptr,
	scheduled_prompts: rawptr,
	// experiments gates explorer relays (domain.PROJECT_VCS_EXPERIMENT_KEY) and Actions
	// bridge routes (domain.ACTIONS_EXPERIMENT_KEY) per owner (REQ-EXP-GATE-3).
	experiments: ^iface.Experiment_Repository,
	shell_sessions: ^shell_session_svc.Shell_Session_Service,
	// REQ-LSP-RLY-1: live LSP relays, so lsp_* frames can be fanned out to the
	// browser socket that owns each session.
	lsp_sessions: ^Lsp_Session_Registry,
	providers: ^provider_service.Provider_Service,
	// bridge_log relay: validated entries go to this writer; the owner API
	// reads through it. nil in tests that do not wire it (entries are then
	// validated and counted but not stored).
	bridge_logs: ^bridge_log_service.Service,
	// task_engine: Task System v2 — bridge hello re-sends unconfirmed grants,
	// stops lease-less orphans and re-plans chains with held tasks; the bridge
	// `busy` push is an implicit heartbeat. nil in tests that do not wire it.
	task_engine: ^taskv2.Service,
	// Passwordless vault: a rolled-back enrollment's directory entry is retired.
	vault: ^vd.Service,
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
	// REQ-EA-1: list_bridges returns enrolled bridges only. ?include_pending=1 (the
	// Settings view) includes enrollment_in_progress for pending replacements as
	// well as new pending rows. Existing targets retain enrollment_state:"enrolled"
	// and appear once; ordinary pickers keep their working bridge available.
	pending: []domain.Bridge
	if query_bool(req.query, "include_pending", false) {
		pending_err: domain.Domain_Error
		pending, pending_err = bridge_service.list_pending_enrollments(h.bridges, auth_ctx)
		if pending_err.code != .None do return respond_error(pending_err, req.request_id)
	}
	defer { for &p in pending do domain.bridge_destroy(&p); delete(pending) }
	b := strings.builder_make()
	strings.write_byte(&b, '[')
	n := 0
	for bridge in bridges {
		if n > 0 do strings.write_byte(&b, ',')
		in_progress := false
		for p in pending do if p.bridge_id == bridge.bridge_id { in_progress = true; break }
		write_bridge_json(&b, bridge, h.agents, h.bridges.catalog, in_progress)
		n += 1
	}
	for bridge in pending {
		already_listed := false
		for enrolled in bridges do if enrolled.bridge_id == bridge.bridge_id { already_listed = true; break }
		if already_listed do continue
		if n > 0 do strings.write_byte(&b, ',')
		write_bridge_json(&b, bridge, h.agents, h.bridges.catalog, true)
		n += 1
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
	publish_bridge_changed(h.event_bus, bridge, "updated")
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
	if err := require_terminal_input(h.entitlements, auth_ctx); err.code != .None {
		return respond_error(err, req.request_id)
	}

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
	if err := require_terminal_input(h.entitlements, auth_ctx); err.code != .None {
		return respond_error(err, req.request_id)
	}

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
	reply, reply_ok, reply_err := bridge_runtime_service.send_runtime_command_wait(h.bridge_runtime_registry, project_service.Runtime_Command{bridge_id = bridge.bridge_id, command_id = command_id, body_json = cmd_body}, fs_command_timeout_ms(command_type))
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

list_bridge_session_projects_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := bridge_fs_relay(h, req, path_part(req.path, 4), "session_projects", "")
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
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
//
// REQ-EA-2: this is also where an enrollment COMMITS. The relay has two targets:
//
//   - the ENROLL-ONLY socket (bridge_enroll_ws.odin), when the bridge is a pending
//     enrollment or the approval page asked for it with "enrollment":true. An
//     attach shares its bridge_id with a device that may be online, so the page
//     says which one it means rather than the hub guessing;
//   - the RUNTIME socket otherwise, exactly as before (Settings -> Unlock).
//
// For the enroll target the hub reads the bridge's answer, and ok:true — which a
// current bridge sends only after the key is stored, read back and its credential
// persisted — commits the enrollment. That answer is observed by the hub on its own
// socket, not reported about itself by the bridge in a later frame, so it may gate
// enrollment where domain.Bridge.vault_status may not.
bridge_unseal_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	auth_ctx, auth_ok, auth_resp := require_auth(h.auth, req)
	if !auth_ok do return auth_resp

	bridge_id := path_part(req.path, 4)
	bridge, bridge_ok, bridge_err := bridge_service.get_bridge_for_enrollment(h.bridges, auth_ctx, bridge_id)
	if !bridge_ok do return respond_error(bridge_err, req.request_id)
	if bridge.status == .Revoked do return respond_error(domain.domain_error(.Bridge_Revoked, "bridge is revoked"), req.request_id)

	// The body is the browser's sealed payload; the hub reads only these members and
	// relays the rest untouched (bridge_unseal_command_body).
	body_root, body_ok := jsonx.parse_body(req.body, context.temp_allocator)
	body_obj, body_is_obj := body_root.(json.Object)
	if !body_ok || !body_is_obj do return respond_error(domain.domain_error(.Validation_Failed, "unseal body must be a JSON object"), req.request_id)
	relay: Bridge_Unseal_Relay_Fields
	if !vault.wire_decode(req.body, &relay) do return respond_error(domain.domain_error(.Validation_Failed, "malformed unseal body"), req.request_id)

	pending := domain.bridge_is_pending(bridge)
	enroll_target := pending || relay.enrollment
	target_key := bridge.bridge_id
	enroll_key := ""
	defer if enroll_key != "" do delete(enroll_key)
	if enroll_target {
		enroll_key = bridge_enroll_registry_key(bridge.bridge_id)
		if !project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry, enroll_key) {
			return respond_error(domain.Domain_Error{code = .Bridge_Offline, cause = "enrollment_not_connected", message = "the enrolling bridge is not connected; its enrollment may have been rolled back — run `ham-bridge enroll` again"}, req.request_id)
		}
		// REQ-EA-7: refuse a seal addressed to a key the enrolling process does not
		// hold, with a reason, instead of relaying it into a bridge-side AEAD failure
		// that reads like tampering. Advisory only — the crypto is the real check.
		expected := strings.to_lower(strings.trim_space(relay.expected_public_key), context.temp_allocator)
		if expected != "" {
			live := project_service.bridge_runtime_registry_public_key(h.bridge_runtime_registry, enroll_key)
			defer delete(live)
			if strings.to_lower(live, context.temp_allocator) != expected {
				return respond_error(domain.Domain_Error{code = .Conflict, cause = "enrollment_key_mismatch", message = "the connected enrolling process does not hold the key you confirmed; run `ham-bridge enroll` again and approve the new request"}, req.request_id)
			}
		}
		target_key = enroll_key
	} else if bridge.status != .Online || !project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry, bridge.bridge_id) {
		return respond_error(domain.domain_error(.Bridge_Offline, fmt.tprintf("Bridge %s is not connected", bridge.bridge_id)), req.request_id)
	}

	cmd_id := relay.command_id
	if cmd_id == "" do cmd_id = fmt.tprintf("cmd_unseal_%d", time.to_unix_nanoseconds(time.now()))
	cmd_body, cmd_ok := bridge_unseal_command_body(body_obj, cmd_id)
	if !cmd_ok do return respond_error(domain.domain_error(.Internal_Error, "could not encode the unseal command"), req.request_id)

	reply, reply_ok, reply_err := bridge_runtime_service.send_runtime_command_wait(
		h.bridge_runtime_registry,
		project_service.Runtime_Command{bridge_id = target_key, command_id = cmd_id, body_json = cmd_body},
		10000,
	)
	if !reply_ok do return respond_error(reply_err, req.request_id)
	if enroll_target && bridge_vault_reply_ok(reply) {
		commit_err, committed := bridge_enroll_commit(h, bridge)
		// Tell the enrolling process the verdict: it has already persisted its key
		// and credential, and undoes them on committed:false (REQ-EA-4).
		bridge_enroll_send_result(h.bridge_runtime_registry, target_key, committed)
		if !committed do return respond_error(commit_err, req.request_id)
	}
	return respond_success(reply, req.request_id, auth_ctx_server_time(req))
}

// Bridge_Unseal_Relay_Fields are the members of an unseal request the hub itself
// reads (typed decode); everything else is the browser's payload for the bridge.
Bridge_Unseal_Relay_Fields :: struct {
	command_id:          string,
	enrollment:          bool,
	expected_public_key: string,
}

// bridge_unseal_command_body is the bridge_unseal command relayed to the bridge: the
// request object with its type forced to bridge_unseal and command_id set, re-encoded
// with json.marshal. The hub cannot read the sealed members and does not change them.
bridge_unseal_command_body :: proc(body: json.Object, command_id: string) -> (string, bool) {
	body := body
	body["type"] = json.String("bridge_unseal")
	body["command_id"] = json.String(command_id)
	data, err := json.marshal(json.Value(body), allocator = context.temp_allocator)
	if err != nil do return "", false
	return string(data), true
}

// bridge_vault_reply_ok reads a bridge vault command reply's top-level ok literal.
bridge_vault_reply_ok :: proc(reply: string) -> bool {
	r: struct {
		ok: bool,
	}
	return vault.wire_decode(reply, &r) && r.ok
}

// bridge_enroll_commit turns an observed successful delivery into an enrollment
// (REQ-EA-2), using what the enroll-only socket's hello recorded. On failure the
// enrollment is left to the sweep, which rolls it back; the bridge's own credential
// then stops authenticating, which is the "never enrolled" outcome.
bridge_enroll_commit :: proc(h: ^Bridge_Handlers, bridge: domain.Bridge) -> (domain.Domain_Error, bool) {
	hello, found := bridge_enroll_hello_get(bridge.bridge_id)
	if !found do return domain.Domain_Error{code = .Conflict, cause = "enrollment_not_connected", message = "the enrolling bridge disconnected before its enrollment could be committed"}, false
	defer bridge_enroll_hello_destroy(&hello)
	fingerprint, _ := device_auth_service.bridge_key_fingerprint_for(hello.public_key, context.temp_allocator)
	committed, ok, err := bridge_service.commit_pending_enrollment(h.bridges, bridge_service.Pending_Commit_Input{
		bridge_id = bridge.bridge_id,
		family_id = hello.family_id,
		machine_hostname = hello.hostname,
		machine_os = hello.os,
		bridge_version = hello.version,
		bridge_public_key = hello.public_key,
		bridge_key_fingerprint = fingerprint,
	})
	if !ok {
		fmt.eprintfln("hub: bridge %s enrollment commit FAILED: %s", bridge.bridge_id, err.message)
		return err, false
	}
	defer { b := committed; domain.bridge_destroy(&b) }
	fmt.eprintfln("hub: bridge %s enrollment committed (vault key delivered)", bridge.bridge_id)
	// An attach supersedes the bridge's previous directory identity only NOW, once
	// the swap is committed (REQ-EA-8): retiring it at approval would leave a
	// rolled-back attach's still-working device with a retired entry. Idempotent, so
	// a duplicate ok:true retries it. A failure cannot undo the commit; it is logged
	// and the old identity stays live (inert: its credential died in the commit).
	if h.vault != nil {
		owner := string(committed.owner_user_id)
		retired, rerr := vd.retire_bridge_attach_predecessors(h.vault, owner, committed.bridge_id)
		if rerr.code != .None do fmt.eprintfln("hub: bridge %s attach committed, but its previous vault directory identity was not retired: %s", committed.bridge_id, rerr.message)
		if h.event_bus != nil do for id in retired do events.publish_resource_changed(h.event_bus, owner, VAULT_DEVICES_RESOURCE, id, "retired", "{}")
	}
	publish_bridge_enrollment_changed(h, string(committed.owner_user_id), committed.bridge_id)
	return domain.Domain_Error{}, true
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
	// Parse exactly one JSON object, including field types. Substring extraction
	// (and core's convenience unmarshal) can accept trailing bytes as a request.
	// Validate UTF-8 before core's string decoder, which assumes valid input.
	if !utf8.valid_string(req.body) do return respond_error(domain.domain_error(.Validation_Failed, "invalid search request"), req.request_id)
	parser := json.make_parser_from_string(req.body, .JSON, true, context.allocator)
	value, parse_err := json.parse_value(&parser)
	defer json.destroy_value(value)
	object, object_ok := value.(json.Object)
	if parse_err != nil || !object_ok || parser.curr_token.kind != .EOF {
		return respond_error(domain.domain_error(.Validation_Failed, "invalid search request"), req.request_id)
	}
	bridge_value, bridge_type_ok := object["bridge_id"].(json.String)
	request_value, request_type_ok := object["request_id"].(json.String)
	envelope_value, envelope_type_ok := object["envelope"].(json.String)
	expires_value, expires_type_ok := object["expires_at_ms"].(json.Integer)
	if !bridge_type_ok || !request_type_ok || !envelope_type_ok || !expires_type_ok {
		return respond_error(domain.domain_error(.Validation_Failed, "invalid search request"), req.request_id)
	}
	bridge_id, request_id, envelope, expires_at_ms := string(bridge_value), string(request_value), string(envelope_value), i64(expires_value)
	if bridge_id == "" || len(bridge_id) > 256 || !vault.valid_id_value(bridge_id) || request_id == "" || len(request_id) > 128 || !vault.valid_id_value(request_id) || len(envelope) > 32_768 {
		return respond_error(domain.domain_error(.Validation_Failed, "invalid search envelope"), req.request_id)
	}
	// Share the Bridge's v2 epoch/base64/nonce+tag grammar, without decrypting or
	// learning the current epoch. Key, epoch freshness and replay remain Bridge gates.
	_, payload, envelope_ok := vault.search_envelope_parse(envelope, context.temp_allocator)
	defer delete(payload, context.temp_allocator)
	if !envelope_ok do return respond_error(domain.domain_error(.Validation_Failed, "invalid search envelope"), req.request_id)
	now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000
	if expires_at_ms < now_ms || expires_at_ms > now_ms + 5_000 {
		return respond_error(domain.domain_error(.Validation_Failed, "search envelope expired"), req.request_id)
	}
	bridge, bridge_ok, bridge_err := bridge_service.get_bridge(h.bridges, auth_ctx, bridge_id)
	if !bridge_ok do return respond_error(bridge_err, req.request_id)
	defer domain.bridge_destroy(&bridge)
	if bridge.status != .Online || !project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry, bridge.bridge_id) {
		return respond_error(domain.domain_error(.Bridge_Offline, "target bridge is offline"), req.request_id)
	}
	command_id := fmt.aprintf("cmd_search_%d", time.to_unix_nanoseconds(time.now())); defer delete(command_id)
	cmd_body := task_chain_search_command_json(command_id, bridge_id, auth_ctx.user_id, request_id, expires_at_ms, envelope); defer delete(cmd_body)
	reply, reply_ok, reply_err := bridge_runtime_service.send_runtime_command_wait(
		h.bridge_runtime_registry,
		project_service.Runtime_Command{bridge_id = bridge.bridge_id, command_id = command_id, body_json = cmd_body},
		5000,
	)
	if !reply_ok do return respond_error(reply_err, req.request_id)
	defer delete(reply, runtime.default_allocator())
	return respond_success(reply, req.request_id, auth_ctx_server_time(req))
}

// bridge_enrollment_status_handler serves GET /api/v1/bridges/<id>/enrollment for the
// approval page (REQ-EA-6): whether the enrollment is still pending, whether the
// enroll-only process is connected to receive the key, and the key it holds — which
// is what the page seals to and what the REQ-EA-7 guard compares against.
bridge_enrollment_status_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	auth_ctx, auth_ok, auth_resp := require_auth(h.auth, req)
	if !auth_ok do return auth_resp
	bridge_id := path_part(req.path, 4)
	bridge, bridge_ok, bridge_err := bridge_service.get_bridge_for_enrollment(h.bridges, auth_ctx, bridge_id)
	if !bridge_ok do return respond_error(bridge_err, req.request_id)
	enroll_key := bridge_enroll_registry_key(bridge.bridge_id)
	defer delete(enroll_key)
	connected := project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry, enroll_key)
	unseal: project_service.Bridge_Unseal_Identity
	defer project_service.bridge_unseal_identity_destroy(&unseal)
	if connected do unseal, _ = project_service.bridge_runtime_registry_unseal_identity(h.bridge_runtime_registry, enroll_key)
	live_key := unseal.public_key
	family, has_family, family_err := bridge_service.pending_enrollment_family(h.bridges, bridge.bridge_id)
	defer delete(family)
	if family_err.code != .None do return respond_error(family_err, req.request_id)
	// An attach has no pending row; its pending-ness is a live enroll-scoped family.
	pending := domain.bridge_is_pending(bridge) || has_family
	out := Bridge_Enrollment_Status_Wire{
		bridge_id = bridge.bridge_id,
		enrollment_state = "pending" if pending else "enrolled",
		enrollment_pending_until = bridge.enrollment_pending_until,
		enroll_connected = connected,
		enroll_public_key = live_key,
		vault_status = bridge.vault_status,
	}
	bridge_unseal_identity_fill(&out, unseal)
	return vault_respond(out, req)
}

Bridge_Enrollment_Status_Wire :: struct {
	bridge_id:                string,
	enrollment_state:         string,
	enrollment_pending_until: string,
	enroll_connected:         bool,
	enroll_public_key:        string,
	vault_status:             string,
	// The unseal-key advertisement (bridge_unseal_identity_fill).
	unseal_boot_id:             string,
	unseal_key_signature:       Maybe(vault.Signature_Wire),
	bridge_identity_public_key: string,
	bridge_identity_sign_alg:   string,
}

Bridge_Enrollment_Cancel_Wire :: struct {
	bridge_id:   string,
	rolled_back: bool,
	committed:   bool,
	row_deleted: bool,
}

Bridge_Public_Key_Wire :: struct {
	bridge_id:         string,
	public_key:        string,
	bridge_public_key: string,
	// The unseal-key advertisement (bridge_unseal_identity_fill).
	unseal_boot_id:             string,
	unseal_key_signature:       Maybe(vault.Signature_Wire),
	bridge_identity_public_key: string,
	bridge_identity_sign_alg:   string,
}

// bridge_enrollment_cancel_handler serves POST /api/v1/bridges/<id>/enrollment/cancel:
// the operator abandons a pending enrollment, which rolls it back now instead of at
// the deadline (REQ-EA-3). An attach target is left as it was. Idempotent.
bridge_enrollment_cancel_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	auth_ctx, auth_ok, auth_resp := require_auth(h.auth, req)
	if !auth_ok do return auth_resp
	bridge_id := path_part(req.path, 4)
	bridge, bridge_ok, bridge_err := bridge_service.get_bridge_for_enrollment(h.bridges, auth_ctx, bridge_id)
	if !bridge_ok do return respond_error(bridge_err, req.request_id)
	enroll_key := bridge_enroll_registry_key(bridge.bridge_id)
	defer delete(enroll_key)
	// The verdict comes from the rollback itself, never from the request: a commit
	// that won the write lock first has made this bridge enrolled, and telling its
	// process committed:false could make it discard the live credential. Any read
	// failure on the way is an error response with nothing sent or deleted.
	rolled_back, removed, err := bridge_service.cancel_pending_enrollment(h.bridges, bridge.bridge_id)
	if err.code != .None do return respond_error(err, req.request_id)
	if rolled_back {
		// Before the close: a process that already saved its key undoes it on this;
		// one that misses it still sees its credential refused on reconnect.
		bridge_enroll_send_result(h.bridge_runtime_registry, enroll_key, false)
		_ = bridge_service.close_bridge_connection(h.bridges, enroll_key)
		// The identity approved with this enrollment never got the vault key; its
		// directory entry is retired so the host can re-enroll with a new identity.
		if h.vault != nil {
			if retired, rerr := vd.retire_bridge_entry(h.vault, string(bridge.owner_user_id), bridge.bridge_id); rerr.code != .None {
				return respond_error(rerr, req.request_id)
			} else if retired != "" && h.event_bus != nil {
				events.publish_resource_changed(h.event_bus, string(bridge.owner_user_id), VAULT_DEVICES_RESOURCE, retired, "retired", "{}")
			}
		}
	}
	publish_bridge_enrollment_changed(h, string(bridge.owner_user_id), bridge.bridge_id)
	return vault_respond(Bridge_Enrollment_Cancel_Wire{bridge_id = bridge.bridge_id, rolled_back = rolled_back, committed = !rolled_back, row_deleted = removed}, req)
}

bridge_public_key_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	// Agents (ham-ctl via its bridge) read the target bridge's unseal boot id here to
	// bind a shell enc_spec to it (finding N1), so instance tokens are accepted; a bare
	// bridge token is not.
	auth_ctx, auth_ok, auth_resp := require_auth_any(h.auth, req)
	if !auth_ok do return auth_resp
	if auth_ctx.kind == .Bridge_Token {
		return respond_error(domain.domain_error(.Forbidden, "bridge token cannot read bridge unseal keys"), req.request_id)
	}

	bridge_id := path_part(req.path, 4)
	bridge, bridge_ok, bridge_err := bridge_service.get_bridge_for_enrollment(h.bridges, auth_ctx, bridge_id)
	if !bridge_ok do return respond_error(bridge_err, req.request_id)

	pub_key := ""
	unseal: project_service.Bridge_Unseal_Identity
	defer project_service.bridge_unseal_identity_destroy(&unseal)
	if h.bridge_runtime_registry != nil {
		// REQ-EA: while an enrollment is pending, or when the approval page asks for
		// it (?enrollment=1, an attach whose old device may still be online), the key
		// that matters is the ENROLL-ONLY process's, not the runtime socket's.
		if domain.bridge_is_pending(bridge) || query_value(req.query, "enrollment") == "1" {
			enroll_key := bridge_enroll_registry_key(bridge.bridge_id)
			defer delete(enroll_key)
			unseal, _ = project_service.bridge_runtime_registry_unseal_identity(h.bridge_runtime_registry, enroll_key)
		} else {
			unseal, _ = project_service.bridge_runtime_registry_unseal_identity(h.bridge_runtime_registry, bridge.bridge_id)
		}
		pub_key = unseal.public_key
	}
	if pub_key == "" && bridge.capabilities_json != "" {
		// Enrollment-time key only: it carries no live unseal signature, so a client
		// that requires one (every unseal v2 client) will refuse it.
		pub_key = json_string(bridge.capabilities_json, "public_key", context.temp_allocator)
	}

	out := Bridge_Public_Key_Wire{bridge_id = bridge.bridge_id, public_key = pub_key, bridge_public_key = pub_key}
	bridge_unseal_identity_fill(&out, unseal)
	return vault_respond(out, req)
}

// --- Project-scoped filesystem browser (browse/read/CRUD) -----------------
// Resolves (project_id -> bridge_id, root_path) via Project_Bridge_Path, then
// relays a WS command carrying that project root so the bridge re-sandboxes every
// path to the project (not the whole bridge fs_root). Same owner + online guards
// as bridge_fs_relay. Request paths are RELATIVE to the project root. The bridge
// result JSON is returned verbatim (already the flat {ok,...,error} envelope).

// explorer_gate_error is the Project Explorer guard (REQ-EXP-GATE-3/5) shared by the
// project and chain-directory fs/vcs relays, so every route and alias that reaches a
// relay is covered. It runs right after authentication and before any project/directory
// lookup, bridge lookup or relay, against the authenticated owner's project_vcs flag
// (agent instance credentials resolve to their owner user). Fails closed on repository
// errors.
explorer_gate_error :: proc(h: ^Bridge_Handlers, auth_ctx: contracts.Auth_Context) -> domain.Domain_Error {
	return experiment_gate_error(h.experiments, auth_ctx.user_id, domain.PROJECT_VCS_EXPERIMENT_KEY)
}

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
	if gate_err := explorer_gate_error(h, auth_ctx); gate_err.code != .None do return "", false, gate_err
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
	reply, reply_ok, reply_err := bridge_runtime_service.send_runtime_command_wait(h.bridge_runtime_registry, project_service.Runtime_Command{bridge_id = bridge.bridge_id, command_id = command_id, body_json = cmd_body}, fs_command_timeout_ms(cmd.command_type))
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
	if gate_err := explorer_gate_error(h, auth_ctx); gate_err.code != .None do return "", false, gate_err
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
	reply, reply_ok, reply_err := bridge_runtime_service.send_runtime_command_wait(h.bridge_runtime_registry, project_service.Runtime_Command{bridge_id = bridge.bridge_id, command_id = command_id, body_json = cmd_body}, fs_command_timeout_ms(cmd.command_type))
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
	if gate_err := explorer_gate_error(h, auth_ctx); gate_err.code != .None do return "", false, gate_err
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

// fs_command_timeout_ms is how long the hub waits for an fs_* command, and (sent as
// timeout_ms) how long the bridge may spend on it (REQ-ERR-PROTO-B). Mutations get the
// bridge's own 20s cap so a large recursive delete or batch write is not cut short;
// reads stay at 10s.
fs_command_timeout_ms :: proc(command_type: string) -> int {
	switch command_type {
	case "fs_make_dir", "fs_create_file", "fs_write_file", "fs_batch_write", "fs_move", "fs_delete":
		return 20_000
	}
	return 10_000
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

// --- Task chain directory VCS relay (read-only) -----------------------------
// Resolves (chain_id, directory_id -> bridge_id, dir.path) like directory_fs_relay,
// then relays a read-only vcs_* WS command carrying the directory path so the
// bridge computes VCS status/diff/commit-diff against the chain directory checkout.

directory_vcs_relay :: proc(h: ^Bridge_Handlers, req: Request, cmd: Project_Vcs_Command) -> (string, bool, domain.Domain_Error) {
	auth_ctx, auth_ok, _ := require_auth_any(h.auth, req)
	if !auth_ok do return "", false, domain.domain_error(.Unauthenticated, "authentication required")
	// Task review (TaskDetails) reads an attempt's commit diff through this relay; that
	// is a core chain workflow, not the explorer, so only vcs_commit_diff is exempt.
	if cmd.command_type != "vcs_commit_diff" {
		if gate_err := explorer_gate_error(h, auth_ctx); gate_err.code != .None do return "", false, gate_err
	}
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

	root_path, root_ok, root_err := project_vcs_effective_root(h, req, bridge.bridge_id, dir.path)
	if !root_ok do return "", false, root_err
	return project_vcs_send(h, bridge.bridge_id, cmd, root_path)
}

chain_directory_handle_vcs_capabilities :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := directory_vcs_relay(h, req, Project_Vcs_Command{command_type = "vcs_capabilities"})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

chain_directory_handle_vcs_status :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := directory_vcs_relay(h, req, Project_Vcs_Command{command_type = "vcs_status"})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

chain_directory_handle_vcs_files :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := directory_vcs_relay(h, req, Project_Vcs_Command{
		command_type = "vcs_files",
		cursor = query_value(req.query, "cursor"), send_cursor = true,
		limit = query_int(req.query, "limit", 100), send_limit = true,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

chain_directory_handle_vcs_diff :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	file := query_value(req.query, "file")
	if file == "" do file = query_value(req.query, "path")
	result, ok, err := directory_vcs_relay(h, req, Project_Vcs_Command{
		command_type = "vcs_diff",
		path = file, send_path = true,
		cursor = query_value(req.query, "cursor"), send_cursor = true,
		limit = query_int(req.query, "limit", 50), send_limit = true,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

chain_directory_handle_vcs_log :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := directory_vcs_relay(h, req, Project_Vcs_Command{
		command_type = "vcs_log",
		cursor = query_value(req.query, "cursor"), send_cursor = true,
		limit = query_int(req.query, "limit", 50), send_limit = true,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

chain_directory_handle_vcs_commit_diff :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	list_files := query_bool(req.query, "list_files", false)
	base_ref := query_value(req.query, "base_ref")
	if base_ref == "" do base_ref = query_value(req.query, "base")
	head_ref := query_value(req.query, "head_ref")
	if head_ref == "" do head_ref = query_value(req.query, "head")
	file := query_value(req.query, "file")
	if file == "" do file = query_value(req.query, "path")
	result, ok, err := directory_vcs_relay(h, req, Project_Vcs_Command{
		command_type = "vcs_commit_diff",
		base_ref = base_ref, send_base_ref = true,
		head_ref = head_ref, send_head_ref = true,
		path = file, send_path = true,
		list_files = list_files, send_list_files = true,
		cursor = query_value(req.query, "cursor"), send_cursor = !list_files,
		limit = query_int(req.query, "limit", 50), send_limit = !list_files,
	})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

chain_directory_handle_vcs_workspaces :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	result, ok, err := directory_vcs_relay(h, req, Project_Vcs_Command{command_type = "vcs_workspaces"})
	if !ok do return respond_error(err, req.request_id)
	return respond_success(result, req.request_id, auth_ctx_server_time(req))
}

// bridge_vcs_show_file_callback relays a vcs_show_file command to a connected
// bridge so task.fetch can resolve repo-relative paths and dir:<id>:<rev>:<path>
// refs against the chain directory's checkout.
bridge_vcs_show_file_callback :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID, directory_id, rev, file_path: string) -> (content: string, ok: bool, err: domain.Domain_Error) {
	h := (^Bridge_Handlers)(ctx)
	if h == nil || h.bridge_runtime_registry == nil || h.taskchains == nil || h.taskchains.repo == nil {
		return "", false, domain.domain_error(.Internal_Error, "bridge runtime registry is not configured")
	}
	dir, dir_ok, dir_err := iface.taskchain_get_directory(h.taskchains.repo, directory_id, chain_id, owner)
	if !dir_ok do return "", false, dir_err
	target_bridge_id := strings.trim_space(dir.bridge_id)
	if target_bridge_id == "" && h.bridges != nil && h.bridges.repo != nil {
		if bridges, berr := iface.bridge_list_by_owner(h.bridges.repo, owner); berr.code == .None {
			if len(bridges) == 1 {
				target_bridge_id = bridges[0].bridge_id
			} else {
				for b in bridges {
					if b.bridge_id == "brg_local" {
						target_bridge_id = "brg_local"
						break
					}
				}
			}
		}
	}
	if target_bridge_id == "" {
		if project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry, "brg_local") {
			target_bridge_id = "brg_local"
		}
	}
	if target_bridge_id == "" || !project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry, target_bridge_id) {
		return "", false, domain.domain_error(.Bridge_Offline, fmt.tprintf("Bridge %s is not connected", target_bridge_id))
	}
	command_id := fmt.tprintf("cmd_vshow_%d", time.to_unix_nanoseconds(time.now()))
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"vcs_show_file\",\"command_id\":\"")
	write_handler_json_string(&b, command_id)
	strings.write_string(&b, "\",\"root\":\"")
	write_handler_json_string(&b, dir.path)
	strings.write_string(&b, "\",\"rev\":\"")
	write_handler_json_string(&b, rev if rev != "" else "HEAD")
	strings.write_string(&b, "\",\"path\":\"")
	write_handler_json_string(&b, file_path)
	strings.write_string(&b, "\"}")
	reply, reply_ok, reply_err := bridge_runtime_service.send_runtime_command_wait(
		h.bridge_runtime_registry,
		project_service.Runtime_Command{bridge_id = target_bridge_id, command_id = command_id, body_json = strings.to_string(b)},
		10_000,
	)
	if !reply_ok do return "", false, reply_err
	if !jsonx.extract_bool(reply, "ok", true, true) {
		err_msg := jsonx.extract_string(reply, "message", "vcs_show_file failed", false)
		return "", false, domain.domain_error(.Not_Found, err_msg)
	}
	return jsonx.extract_string(reply, "content", "", true), true, {}
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
	reply, reply_ok, reply_err := bridge_runtime_service.send_runtime_command_wait(h.bridge_runtime_registry, project_service.Runtime_Command{bridge_id = bridge.bridge_id, command_id = command_id, body_json = cmd_body}, fs_command_timeout_ms(cmd.command_type))
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
	if !auth_ok && strings.has_prefix(token, bridge_service.ACCESS_TOKEN_PREFIX) {
		// REQ-EA-1: a pending enrollment's credential is refused by every runtime
		// path, this one included. It is accepted only for the enroll-only socket,
		// which shares this upgrade endpoint and nothing after it.
		enroll_auth, family_id, enroll_ok, _ := bridge_service.verify_enroll_access_token(h.bridges, token)
		if enroll_ok {
			if body_bridge_id != "" && body_bridge_id != enroll_auth.bridge_id { _ = write_ws_text_frame(client, bridge_ws_error_payload("bridge_id does not match bearer token")); return }
			bridge_ws_enroll_session(h, client, &reader, enroll_auth.bridge_id, enroll_auth.user_id, family_id, hello_text, hostname, platform_os, version_str)
			return
		}
	}
	// Unauthenticated attempts carry no trustworthy bridge_id: they share one series.
	if !auth_ok { bridge_metrics_connect_result(BRIDGE_ID_UNKNOWN, "auth_failed"); bridge_ws_auth_error(client, auth_err); return }
	admitted_bridge, found, lookup_err := iface.bridge_get_bridge(h.bridges.repo, bridge_auth.bridge_id)
	if !found { bridge_metrics_connect_result(BRIDGE_ID_UNKNOWN, "auth_failed"); _ = write_ws_text_frame(client, bridge_ws_error_payload(lookup_err.message)); return }
	defer domain.bridge_destroy(&admitted_bridge)
	if body_bridge_id != "" && body_bridge_id != admitted_bridge.bridge_id { _ = write_ws_text_frame(client, bridge_ws_error_payload("bridge_id does not match bearer token")); return }
	if plan_err := bridge_service.check_bridge_plan(h.bridges, admitted_bridge); plan_err.code != .None {
		bridge_metrics_connect_result(admitted_bridge.bridge_id, "plan_limit")
		bridge_ws_domain_error(client, plan_err)
		return
	}
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
	project_service.connection_state_lock(connection)
	if sync.atomic_load(&connection.retired) { project_service.connection_state_unlock(connection); return }
	bridge, connect_ok, err := bridge_service.bridge_runtime_connect(h.bridges, token, hostname, platform_os, platform_arch, hello_text, version_str, commit_sha_str, build_timestamp_str)
	// The hello's record is now the metadata authority for this connection; record the
	// contract under the same lock so no heartbeat sees one without the other (plan T3).
	if connect_ok do bridge_record_hello_metadata(connection, hello_text)
	project_service.connection_state_unlock(connection)
	if !connect_ok {
		bridge_metrics_connect_result(admitted_bridge.bridge_id, "revoked" if err.code == .Bridge_Revoked else "connect_failed")
		bridge_ws_domain_error(client, err)
		return
	}
	defer domain.bridge_destroy(&bridge)
	// Bind the session to the credential that opened it, for its whole lifetime:
	// the reader closes it at expiry (unless renewed in-band with bridge_reauth) or
	// on revocation, and command senders refuse it once expired.
	session_cred, session_ok := bridge_service.access_token_session_credential(h.bridges, token)
	if !session_ok {
		bridge_metrics_connect_result(admitted_bridge.bridge_id, "auth_failed")
		_ = write_ws_text_frame(client, bridge_ws_session_error_payload(BRIDGE_WS_TOKEN_EXPIRED_CODE, "bridge access token could not be bound to the session"))
		return
	}
	project_service.bridge_runtime_connection_set_auth(connection, session_cred.token_id, session_cred.valid_for_ms)
	// Inbound bytes for this connection land on the registry-owned series.
	reader.bytes_series = connection.rx_bytes
	project_service.bridge_runtime_registry_set_command_socket(h.bridge_runtime_registry, bridge.bridge_id, client, hello.generation)
	hello_unseal := bridge_hello_unseal_identity(hello_text)
	if hello_unseal.public_key != "" {
		project_service.bridge_runtime_registry_set_unseal_identity(h.bridge_runtime_registry, bridge.bridge_id, hello_unseal, hello.generation)
	}
	project_service.bridge_unseal_identity_destroy(&hello_unseal)
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
	_ = write_ws_text_frame_locked(h, bridge.bridge_id, client, bridge_ready_payload(bridge.bridge_id, hello.generation, hello.replaced_existing, catalog_etag, bridge.telemetry_enabled != "disabled", BRIDGE_HUB_HEARTBEAT_METADATA_OMISSION, BRIDGE_HUB_DIAGNOSTICS_FRAME_V1))
	// REQ-ENR-1: the disconnect path publishes offline; this is its counterpart, so
	// the UI learns a bridge came (back) online — e.g. right after enrollment commit
	// and service restart. The enroll-only socket returned long before this point.
	bridge_publish_online_status(h, bridge)
	if ext_err := bridge_extension_reconnected(h, bridge); ext_err.code != .None do fmt.eprintfln("extension reconnect failed bridge=%s: %s", bridge.bridge_id, ext_err.message)
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
		agent_service.notify_instances_terminal(h.agents, gone)
		for inst in gone {
			publish_instance_changed(h.event_bus, inst, "status_changed")
			if h.shell_sessions != nil {
				shell_session_svc.shell_session_background_runs_for_agent(h.shell_sessions, string(inst.owner_user_id), inst.agent_instance_id)
			}
		}
	}
	// Task System v2 (plan §2.4, bridge Online): re-send unconfirmed grants on
	// this bridge, stop[] live non-coordinator instances that hold no lease, and
	// match_chain for every chain with a held task. Runs AFTER the heartbeat
	// reconcile above so instances the bridge no longer runs have already
	// crossed on_instance_terminal.
	taskv2.on_bridge_hello(h.task_engine, bridge.bridge_id, hello_active)
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
	project_service.connection_state_lock(connection)
	defer project_service.connection_state_unlock(connection)
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
	// Lifecycle facts after the state_mutex is released (review B1). The engine
	// treats `unreachable` on an Offline bridge as bridge absence, not death: the
	// lease runs out via its TTL (review B2).
	agent_service.notify_instances_terminal(h.agents, cleared)
	// Blockers live in memory only; the bridge resends them when it reconnects.
	if still_current {
		agent_service.clear_bridge_blockers(h.agents, bridge_id)
		agent_service.tool_live_clear_bridge(h.agents, bridge_id)
	}
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
		publish_instance_changed(h.event_bus, inst, "status_changed")
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
	connection := (^project_service.Bridge_Runtime_Connection)(reader.control_context)
	last_frame := time.tick_now()
	next_revalidate := time.tick_add(time.tick_now(), bridge_ws_revalidate_interval)
	for {
		if connection != nil && sync.atomic_load(&connection.credential_revoked) {
			reason = .Credential_Revoked
			return
		}
		// 120s read deadline decoupled from the bridge's idle heartbeat cadence
		// (BRIDGE_HEARTBEAT_INTERVAL_SECONDS = 45s): a single delayed/dropped heartbeat
		// still leaves a full extra beat of margin before we treat the bridge as
		// gone, so we never tear down a healthy connection at the cadence edge.
		//
		// The read also wakes EARLY, at the session credential's expiry and at each
		// revocation re-check, so an idle session is ended on time. An early wake is
		// not idleness: the 120s idle rule still counts from the last frame.
		wait := BRIDGE_WS_IDLE_DEADLINE - time.tick_since(last_frame)
		wait = min(wait, max(time.Duration(0), time.tick_diff(time.tick_now(), next_revalidate)))
		if connection != nil {
			if expires := sync.atomic_load(&connection.auth_expires_unix_ms); expires > 0 {
				wait = min(wait, time.Duration(max(expires - project_service.bridge_runtime_wall_ms(), 0)) * time.Millisecond)
			}
		}
		wait = max(wait, BRIDGE_WS_MIN_READ_WAIT)
		text, ok, read_reason := bridge_ws_read_frame(reader, wait)
		if !ok && read_reason == .Read_Deadline && time.tick_since(last_frame) < BRIDGE_WS_IDLE_DEADLINE {
			if end := bridge_ws_session_check(h, connection, bridge_id, client, &next_revalidate); end != .None {
				reason = end
				return
			}
			continue
		}
		if !ok {
			reason = read_reason
			// A command sender that found the credential expired wakes this reader with
			// shutdown(.Receive), which reads as a clean close. Report it as what it is,
			// and still tell the bridge why (the write side is open).
			if reason == .Clean_Close && project_service.bridge_runtime_connection_auth_expired(connection) {
				reason = bridge_ws_session_check(h, connection, bridge_id, client, &next_revalidate)
			}
			if reason == .Fatal_Frame do metrics.counter_inc(metrics.with(project_service.fleet_metrics.bridge_frames_rejected, "fatal_frame"))
			return
		}
		last_frame = time.tick_now()
		// Inbound half of the bound: a frame that arrives after the credential ran out
		// is refused, never dispatched, so nothing slips in between timed checks.
		if end := bridge_ws_session_check(h, connection, bridge_id, client, &next_revalidate); end != .None {
			delete(text)
			reason = end
			return
		}
		if reader.last_opcode == 0x2 {
			if !bridge_ws_process_binary_frame(h, bridge_id, connection_generation, text) {
				reason = .Frame_Rejected
				metrics.counter_inc(metrics.with(project_service.fleet_metrics.bridge_frames_rejected, "rejected"))
				return
			}
			continue
		}
		if bridge_ws_try_reauth(h, connection, bridge_id, client, text) {
			delete(text)
			continue
		}
		if !bridge_ws_process_frame(h, bridge_id, connection_generation, client, &reassemblies, text, connection) {
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

BRIDGE_WS_IDLE_DEADLINE :: 120 * time.Second
// Floor on one read's wait, so a bound that is already due is handled by the next
// check rather than by spinning on zero-length reads.
BRIDGE_WS_MIN_READ_WAIT :: 50 * time.Millisecond
// How often a live session re-reads its token row for revocation. Bridge revocation
// itself closes the socket at once (close_bridge_connection); this catches every
// other way a credential dies (family reuse detection, an attach that retires the
// old device, a revocation on another hub process sharing the database).
// A variable only so a test can shorten it; production never writes it.
bridge_ws_revalidate_interval := 60 * time.Second

// Wire codes the bridge recognises on a session that is being ended for its
// credential. Sent as bridge_error.payload.code and as the WS close reason.
BRIDGE_WS_TOKEN_EXPIRED_CODE :: "bridge_token_expired"
BRIDGE_WS_CREDENTIAL_REVOKED_CODE :: "bridge_credential_revoked"
BRIDGE_WS_SUNSET_PENDING_CODE :: "bridge_sunset_pending"

// bridge_ws_session_check enforces the session credential bound: expired (wall
// clock against the bound recorded at upgrade or bridge_reauth), or revoked /
// expired per the token row (re-read every bridge_ws_revalidate_interval). On
// either it tells the bridge why, sends a close frame, and returns the teardown
// reason; the caller returns and the reader closes the socket.
bridge_ws_session_check :: proc(h: ^Bridge_Handlers, connection: ^project_service.Bridge_Runtime_Connection, bridge_id: string, client: net.TCP_Socket, next_revalidate: ^time.Tick) -> Bridge_WS_Disconnect_Reason {
	if connection == nil do return .None
	if sync.atomic_load(&connection.credential_revoked) do return .Credential_Revoked
	if project_service.bridge_runtime_connection_auth_expired(connection) {
		bridge_ws_end_session(h, bridge_id, client, BRIDGE_WS_TOKEN_EXPIRED_CODE, "bridge access token has expired; reconnect with the refreshed credential")
		return .Credential_Expired
	}
	if time.tick_diff(next_revalidate^, time.tick_now()) < 0 do return .None
	next_revalidate^ = time.tick_add(time.tick_now(), bridge_ws_revalidate_interval)
	// The reader is a persistent heap loop: scope every allocation of the row
	// re-read to a temp region so a once-a-minute check never accumulates.
	temp := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp)
	context.allocator = context.temp_allocator
	token_id := project_service.bridge_runtime_connection_auth_token_id(connection)
	if token_id == "" || h.bridges == nil do return .None
	switch bridge_service.session_credential_state(h.bridges, token_id) {
	case .Valid:
		return .None
	case .Expired:
		bridge_ws_end_session(h, bridge_id, client, BRIDGE_WS_TOKEN_EXPIRED_CODE, "bridge access token has expired; reconnect with the refreshed credential")
		return .Credential_Expired
	case .Pending_Sunset:
		bridge_ws_end_session(h, bridge_id, client, BRIDGE_WS_SUNSET_PENDING_CODE, "bridge retirement is pending enrollment; retain credentials and explicitly resume after rollback")
		return .Credential_Revoked
	case .Revoked:
		bridge_ws_end_session(h, bridge_id, client, BRIDGE_WS_CREDENTIAL_REVOKED_CODE, "bridge credential is revoked")
		return .Credential_Revoked
	}
	return .None
}

// bridge_ws_end_session sends the typed reason and a WS close (4401) under the
// connection's writer lock. Best effort: the socket is closing either way.
bridge_ws_end_session :: proc(h: ^Bridge_Handlers, bridge_id: string, client: net.TCP_Socket, code, message: string) {
	fmt.printfln("ham-hub bridge session ended bridge=%s reason=%s", bridge_id, code)
	payload := bridge_ws_session_error_payload(code, message, context.temp_allocator)
	connection := project_service.bridge_runtime_connection_acquire(h.bridge_runtime_registry, bridge_id)
	if connection == nil do return
	defer project_service.bridge_runtime_connection_release(h.bridge_runtime_registry, connection)
	project_service.bridge_runtime_connection_lock_writer(connection)
	defer sync.unlock(&connection.writer_mutex)
	if connection.socket != client do return
	_ = ws.write_server_text(client, payload, false)
	frame: [2 + 2 + 32]byte
	n := min(len(code), 32)
	frame[0] = 0x88 // FIN + CLOSE
	frame[1] = u8(2 + n)
	frame[2] = 0x11 // 4401, network byte order
	frame[3] = 0x31
	copy(frame[4:], code[:n])
	_, _ = net.send_tcp(client, frame[:4 + n])
}

Bridge_WS_Session_Error_Payload :: struct {
	code:    string,
	message: string,
}
Bridge_WS_Session_Error :: struct {
	type:             string,
	protocol_version: int,
	payload:          Bridge_WS_Session_Error_Payload,
}

// bridge_ws_session_error_payload is a bridge_error frame with a machine-readable
// code. Older bridges log `message`; newer ones act on `code`.
bridge_ws_session_error_payload :: proc(code, message: string, allocator := context.temp_allocator) -> string {
	data, err := json.marshal(Bridge_WS_Session_Error{type = "bridge_error", protocol_version = 1, payload = {code = code, message = message}}, allocator = allocator)
	if err != nil do return `{"type":"bridge_error","protocol_version":1,"payload":{"code":"internal_error"}}`
	return string(data)
}

Bridge_Reauth_Result_Payload :: struct {
	ok:         bool,
	expires_in: int,
	code:       string,
	message:    string,
}
Bridge_Reauth_Result :: struct {
	type:             string,
	protocol_version: int,
	payload:          Bridge_Reauth_Result_Payload,
}

// bridge_ws_try_reauth handles an in-band `bridge_reauth` frame: the bridge renews
// the session's credential after a refresh instead of reconnecting. The new token
// must verify and belong to THIS bridge; the session is then re-bound to it. A
// failed reauth changes nothing (the old bound still applies) and is answered
// ok:false. Returns false for any other frame. Advertised in bridge_ready as
// credential_reauth:true; a bridge that never sends it simply reconnects with its
// refreshed token when the session ends.
bridge_ws_try_reauth :: proc(h: ^Bridge_Handlers, connection: ^project_service.Bridge_Runtime_Connection, bridge_id: string, client: net.TCP_Socket, text: string) -> bool {
	if !strings.contains(text, `"bridge_reauth"`) do return false
	temp := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp)
	context.allocator = context.temp_allocator
	frame: struct {
		type:         string,
		access_token: string,
	}
	if json.unmarshal_string(text, &frame, json.Specification.JSON, context.temp_allocator) != nil || frame.type != "bridge_reauth" do return false
	result := Bridge_Reauth_Result{type = "bridge_reauth_result", protocol_version = 1}
	auth, ok, err := bridge_service.verify_bridge_token(h.bridges, frame.access_token)
	cred: bridge_service.Session_Credential
	cred_ok := false
	if ok && auth.bridge_id == bridge_id {
		cred, cred_ok = bridge_service.access_token_session_credential(h.bridges, frame.access_token)
	}
	if cred_ok && connection != nil {
		project_service.bridge_runtime_connection_set_auth(connection, cred.token_id, cred.valid_for_ms)
		result.payload = {ok = true, expires_in = int(cred.valid_for_ms / 1000)}
	} else {
		message := err.message if !ok else "the credential does not belong to this bridge"
		result.payload = {ok = false, code = BRIDGE_WS_CREDENTIAL_REVOKED_CODE if err.code == .Forbidden else BRIDGE_WS_TOKEN_EXPIRED_CODE, message = message}
		if err.cause == BRIDGE_WS_SUNSET_PENDING_CODE do result.payload.code = BRIDGE_WS_SUNSET_PENDING_CODE
		fmt.printfln("ham-hub bridge reauth refused bridge=%s: %s", bridge_id, message)
	}
	if data, merr := json.marshal(result, allocator = context.temp_allocator); merr == nil {
		_ = write_ws_text_frame_locked(h, bridge_id, client, string(data))
	}
	if !cred_ok && (result.payload.code == BRIDGE_WS_CREDENTIAL_REVOKED_CODE || result.payload.code == BRIDGE_WS_SUNSET_PENDING_CODE) {
		bridge_ws_end_session(h, bridge_id, client, result.payload.code, result.payload.message)
		if connection != nil do sync.atomic_store(&connection.credential_revoked, true)
		_ = net.shutdown(net.Any_Socket(client), .Receive)
	}
	return true
}

// bridge_ws_process_binary_frame routes one bridge->hub BINARY frame (REQ-PTY-NET-2).
// Today that is exactly one thing: a pty_wire OUTPUT session frame, handed to the shell
// fan-out WITHOUT re-encoding — the payload bytes (raw or GCM ciphertext) go to every
// viewer as they arrived. The frame string is owned here and freed before return.
// Returns false only for a frame that cannot be parsed at all: a desynchronised binary
// stream is not something to keep reading from.
bridge_ws_process_binary_frame :: proc(h: ^Bridge_Handlers, bridge_id: string, connection_generation: int, raw: string) -> bool {
	defer delete(raw)
	if project_service.bridge_runtime_registry_generation(h.bridge_runtime_registry, bridge_id) != connection_generation do return false
	kind, flags, session_id, payload, ok := contracts.pty_wire_decode_session_frame(transmute([]byte)raw)
	if !ok {
		fmt.eprintfln("ham-hub WARN bridge ws binary frame REJECTED bridge=%s bytes=%d (not a pty_wire session frame)", bridge_id, len(raw))
		return false
	}
	switch kind {
	case contracts.PTY_WIRE_KIND_OUTPUT:
		metrics.counter_inc(metrics.with(project_service.fleet_metrics.bridge_ws_frames, "rx", "shell_pty_output"))
		if h.shell_sessions != nil && len(payload) > 0 {
			shell_session_svc.shell_session_broadcast_output(h.shell_sessions, session_id, payload, contracts.pty_wire_is_encrypted(flags), contracts.pty_wire_is_snapshot(flags), bridge_id)
		}
	case:
		// Unknown kinds are dropped, not fatal: a newer bridge may add one.
		metrics.counter_inc(metrics.with(project_service.fleet_metrics.bridge_ws_frames, "rx", "other"))
	}
	return true
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
				// REQ-ERR-PROTO-A: tell the bridge why before the connection closes.
				refusal := bridge_protocol_error_frame(contracts.BRIDGE_WS_FRAME_KIND_CHUNK, contracts.wire_error(.Validation_Failed, "chunk_rejected", "chunk frame malformed, over the size cap, or refused admission"))
				_ = write_ws_text_frame_locked(h, bridge_id, client, refusal)
				delete(refusal)
				return false
			}
			if !complete do return true
			text = assembled
			type = json_string(text, "type")
		} else {
			delete(kind)
		}
	}
	// text and type belong to the reader's persistent heap, so they are freed
	// against it explicitly: the deferred deletes run under the scratch allocator
	// installed below.
	heap := context.allocator
	defer delete(text, heap)
	defer delete(type, heap)
	metrics.counter_inc(metrics.with(project_service.fleet_metrics.bridge_ws_frames, "rx", project_service.bridge_frame_kind(type)))

	// Per-frame scratch, the reader-thread counterpart of handle_client's
	// per-request arena. The arms below call the same services request handlers
	// do, which return owned rows and assume an arena reclaims anything the caller
	// does not free; on this thread the persistent heap kept all of it, for the
	// life of the connection (taskv2 hooks, repository rows, heartbeat parses).
	// Anything that outlives the frame is already cloned onto an explicit
	// allocator by its owner (runtime registry, viewer writers, event bus writes
	// synchronously, metrics registry, proxy/tunnel relays), or pinned here on
	// the heap where ownership crosses to another thread (bridge_log). Assign at
	// proc-body scope: a nested-scope assignment would revert.
	scratch: virtual.Arena
	scratch_ok := virtual.arena_init_growing(&scratch) == nil
	defer if scratch_ok do virtual.arena_destroy(&scratch)
	frame_allocator := heap
	if scratch_ok do frame_allocator = virtual.arena_allocator(&scratch)
	context.allocator = frame_allocator

	switch type {
	case "provider_catalog_request":
		payload, payload_ok := bridge_provider_catalog_payload(h.providers)
		if payload_ok {
			_ = write_ws_text_frame_locked(h, bridge_id, client, payload)
		}
		delete(payload)
	case "bridge_heartbeat":
		metrics.gauge_set(metrics.with(project_service.fleet_metrics.bridge_last_heartbeat, bridge_id), time.now()._nsec / 1_000_000_000)
		// Legacy diagnostic members are still ingested from Bridges that do not send
		// bridge_diagnostics. Once this connection has delivered a snapshot, that frame
		// owns the series and a stray legacy member must not overwrite it.
		if !project_service.bridge_diagnostics_owns_generation(bridge_id, connection_generation) {
			_ = bridge_apply_heartbeat_stats(bridge_id, text, connection)
			bridge_apply_heartbeat_reliability(bridge_id, text)
		}
		project_service.bridge_runtime_registry_set_task_chain_search_status(
			h.bridge_runtime_registry, bridge_id, connection_generation,
			json_bool_value(text, "task_chain_search_ready"), json_bool_value(text, "task_chain_search_stale"),
			i64(json_int(text, "task_chain_search_revision", 0)),
		)
		// Durable liveness on EVERY accepted heartbeat, metadata or not (plan T1): it
		// used to ride on the capabilities save, so a beat without "capabilities" left
		// last_seen_at to age into the 1h gone-bridge reaper. Narrow, fenced writes.
		if bridge_apply_heartbeat_liveness(h, bridge_id, connection_generation, text) == .Resync_Required {
			// The stored metadata is no longer what this connection's hello installed
			// (lost or rewritten under a live socket). Admission must not run on it:
			// close, and the Bridge's reconnect sends a fresh hello (plan §4.2).
			metrics.counter_inc(metrics.with(project_service.fleet_metrics.bridge_frames_rejected, HEARTBEAT_METADATA_REJECT_RESYNC))
			refusal := bridge_protocol_error_frame("bridge_heartbeat", contracts.wire_error(.Conflict, contracts.BRIDGE_RESYNC_REQUIRED_CAUSE, "stored bridge metadata does not match this connection's hello; reconnect to resync"))
			_ = project_service.bridge_runtime_connection_send_farewell(connection, refusal)
			delete(refusal)
			return false
		}
		bridge_apply_vault_status_report(h, bridge_id, text, connection_generation)
		// Plan T2: inventory repair and absence reconciliation run only on a complete
		// inventory; an absent or malformed one is counted and leaves instances alone.
		reconciled, superseded, _ := bridge_reconcile_heartbeat_inventory(h, bridge_id, connection_generation, text)
		schedules_version := 0
		if h.actions != nil {
			schedules_version = get_actions_bridge_version(h.actions, bridge_id)
		} else if h.scheduled_prompts != nil {
			schedules_version = get_scheduled_prompts_bridge_version(h.scheduled_prompts, bridge_id)
		}
		schedules_owner := ""
		if h.bridges != nil {
			if owner_bridge, owner_found, _ := iface.bridge_get_bridge(h.bridges.repo, bridge_id); owner_found {
				schedules_owner = strings.clone(string(owner_bridge.owner_user_id), context.temp_allocator)
				domain.bridge_destroy(&owner_bridge)
			}
		}
		// REQ-EXP-GATE-4: the token folds in the owner's Actions eligibility, so a
		// toggle immediately invalidates the bridge's cached schedule freshness.
		epoch, revision := action_schedules_owner_token(h.actions, h.experiments, schedules_owner)
		ack := bridge_heartbeat_ack_payload(reconciled, superseded, schedules_version, epoch, revision)
		_ = write_ws_text_frame_locked(h, bridge_id, client, ack)
		delete(ack)
		if superseded != nil {
			for s in superseded do delete(s)
			delete(superseded)
		}
	case "bridge_diagnostics":
		// Plan §4.3: same socket auth and generation as heartbeat (checked on entry and
		// again under the commit lock). Rejections are counted, never fatal.
		_ = bridge_apply_diagnostics_frame(h.bridge_runtime_registry, bridge_id, connection_generation, text, connection)
	case "agent_instance_status":
		instance_id := json_string(text, "agent_instance_id")
		state_seq := json_int(text, "state_seq", 0)
		runtime_status := json_string(text, "runtime_status")
		activity_status := json_string(text, "activity_status")
		if h.agents != nil {
			error_json, _ := jsonx.extract_raw_object(text, "error", true, context.temp_allocator)
			if inst, applied, _ := bridge_apply_validated_status(h, bridge_id, connection_generation, instance_id, state_seq, runtime_status, activity_status, json_string(text, "launch_epoch", context.temp_allocator), error_json); applied {
				publish_instance_changed(h.event_bus, inst, "status_changed")
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
	case "provider_extension_install_progress":
		if ext_err := bridge_extension_frame(h, bridge_id, type, text); ext_err.code != .None do fmt.eprintln("extension progress:", ext_err.message)
	case "bridge_update_progress":
		if ext_err := bridge_extension_frame(h, bridge_id, type, text); ext_err.code != .None do fmt.eprintln("extension update progress:", ext_err.message)
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
	case "mcp_transform_result":
		mcp_bridge_result(h,bridge_id,text,connection_generation)
	case "provider_profiles_report":
		if err:=bridge_provider_profiles_frame(h,bridge_id,text);err.code!=.None do fmt.eprintln("provider profiles report:",err.message)
	case "session_projects_result", "auto_update_config_result", "provider_profile_op_result", "command_result", "project_path_validation_result", "provider_discovery_report", "provider_model_discovery_report", "fs_list_dir_result", "fs_stat_result", "fs_make_dir_result", "fs_read_file_result", "fs_create_file_result", "fs_write_file_result", "fs_batch_write_result", "fs_move_result", "fs_delete_result", "vcs_capabilities_result", "vcs_status_result", "vcs_files_result", "vcs_diff_result", "vcs_log_result", "vcs_commit_diff_result", "vcs_show_file_result", "vcs_workspaces_result", "vcs_stage_result", "vcs_unstage_result", "vcs_revert_result", "vcs_save_file_result", "vcs_commit_result", "vcs_upload_result", "vcs_sync_result", "fs_find_files_result", "fs_grep_result", "shell_start_result", "shell_restart_result", "shell_list_result", "shell_logs_result", "shell_capture_result", "shell_set_port_result", "bridge_unseal_result", "task_chain_search_result", "taskv2_merge_worktree_result":
		if ext_err := bridge_extension_frame(h, bridge_id, type, text); ext_err.code != .None do fmt.eprintln("extension command result:", ext_err.message)
		command_id := json_string(text, "command_id")
		_ = bridge_runtime_service.runtime_command_result_for_connection(h.bridge_runtime_registry, bridge_id, connection_generation, command_id, text)
		if type == "command_result" && h.agents != nil do agent_service.apply_reconfiguration_command_result(h.agents, bridge_id, command_id, text)
		if type == "command_result" && h.agents != nil {
			restored: domain.Agent_Instance
			if agent_service.apply_stop_command_result(h.agents, bridge_id, command_id, text, &restored) {
				publish_instance_changed(h.event_bus, restored, "status_changed")
				domain.agent_instance_destroy(&restored)
			}
		}
		if type == "command_result" && command_id == "" {
			// An id-less failure cannot be matched to any pending command; log it so
			// hub/bridge protocol drift (e.g. missing_command_id) is visible.
			if werr, found := contracts.wire_error_parse(text, context.temp_allocator); found {
				fmt.eprintln("hub: bridge", bridge_id, "rejected command without id:", domain.error_code_string(werr.code), werr.cause)
			}
		}
		delete(command_id)
	case "pane_capture_result":
		if json_int(text, "protocol_version", 0) != 1 do return true
		if h.content != nil {
			pane_err, _ := contracts.wire_error_parse(text, context.temp_allocator)
			input := content_service.Pane_Capture_Result_Input{
				command_id = json_string_unescaped(text, "command_id"),
				pane_capture_request_id = json_string_unescaped(text, "pane_capture_request_id"),
				conversation_id = json_string_unescaped(text, "conversation_id"),
				message_id = json_string_unescaped(text, "message_id"),
				agent_instance_id = json_string_unescaped(text, "agent_instance_id"),
				ok = json_bool_value(text, "ok"),
				output = json_string_unescaped(text, "output"),
				error_code = strings.clone(pane_err.cause),
				message = strings.clone(pane_err.message),
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
		bridge_apply_vault_status_report(h, bridge_id, text, connection_generation)
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
				boot_id := json_string(text, "bridge_boot_id")
				defer delete(boot_id)
				shell_session_svc.shell_session_broadcast_stream_ready(h.shell_sessions, session_id, boot_id)
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
	// REQ-EXT-BLK-2: a full per-instance agent blocker snapshot. Scoped to the
	// authenticated bridge_id; the hub replaces its in-memory list wholesale.
	case "tool_stream_reset", "tool_stream_state", "tool_stream_unavailable":
        bridge_ws_tool_live_frame(h, bridge_id, connection_generation, connection, text)

	case "agent_blockers":
		if h.agents != nil do _ = agent_service.apply_bridge_blockers_leased(h.agents, bridge_id, text)
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
	case:
		// REQ-ERR-PROTO-A: a frame type the hub does not know is refused out loud
		// rather than dropped, so protocol drift shows on both sides. Fatal: the
		// bridge must not resend it.
		refusal := bridge_protocol_error_frame(type, contracts.wire_error(.Not_Implemented, "unknown_frame_type", "hub does not handle this frame type"))
		_ = write_ws_text_frame_locked(h, bridge_id, client, refusal)
		delete(refusal)
		fmt.eprintln("hub: bridge", bridge_id, "sent unknown frame type:", type)
	}

	return true
}

// bridge_protocol_error_frame is the hub's refusal of a bridge frame it cannot
// process: {"type":"protocol_error","frame_type":...,"ok":false,"error":{...}}.
bridge_protocol_error_frame :: proc(frame_type: string, err: contracts.Wire_Error) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"protocol_error\",\"frame_type\":\"")
	contracts.write_json_string(&b, frame_type)
	strings.write_string(&b, "\",\"ok\":false,\"error\":")
	contracts.write_wire_error(&b, err)
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

Bridge_Agent_Status_Report :: struct {
	agent_instance_id: string `json:"agent_instance_id"`,
	state_seq:         int    `json:"state_seq"`,
	runtime_status:    string `json:"runtime_status"`,
	activity_status:   string `json:"activity_status"`,
	launch_epoch: string `json:"launch_epoch"`,
}

// Serialize durable status writes with retirement. New connections do not finish
// admission until the old state writer has drained; a delayed old frame cannot
// save over the new generation's durable state.
bridge_apply_validated_status :: proc(h: ^Bridge_Handlers, bridge_id: string, generation: int, id: string, seq: int, status, activity: string, launch_epoch: string = "", error_json: string = "", changed: ^bool = nil) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	c := project_service.bridge_runtime_connection_acquire(h.bridge_runtime_registry, bridge_id, generation)
	if c == nil do return {}, false, domain.domain_error(.Bridge_Offline, "stale bridge generation")
	defer project_service.bridge_runtime_connection_release(h.bridge_runtime_registry, c)
	project_service.connection_state_lock(c)
	if sync.atomic_load(&c.retired) {
		project_service.connection_state_unlock(c)
		return {}, false, domain.domain_error(.Bridge_Offline, "retired bridge generation")
	}
	// Lifecycle facts are collected under state_mutex and delivered after the
	// unlock: the engine opens a unit of work (tx_mutex), and the allowed lock
	// order is tx_mutex → state_mutex, never the reverse (review B1).
	facts := make([dynamic]agent_service.Lifecycle_Fact, context.temp_allocator)
	instance, applied, err := agent_service.apply_bridge_status_report(h.agents, bridge_id, id, seq, status, activity, owner_user_id = c.owner_id, launch_epoch = launch_epoch, error_json = error_json, facts = &facts, changed = changed)
	project_service.connection_state_unlock(c)
	agent_service.notify_facts(h.agents, facts[:])
	if applied {
		_, _, tracking_err := project_service.bridge_runtime_instance_apply(h.bridge_runtime_registry, bridge_id, generation, id, string(instance.owner_user_id), string(instance.runtime_status), string(instance.activity_status), seq, recover = true)
		if tracking_err.code == .Bridge_Busy { fmt.eprintln("bridge runtime instance admission failed", bridge_id, id, tracking_err.message) }
	}
	return instance, applied, err
}

// Decodes the heartbeat inventory, repairs status from its reports and returns every
// reported instance id (active and terminal; caller owns the slice and its strings).
// A non-complete inventory (bridge_heartbeat_inventory.odin) applies nothing and
// returns nil. The heartbeat arm uses bridge_reconcile_heartbeat_inventory instead.
bridge_apply_heartbeat_digest :: proc(h: ^Bridge_Handlers, bridge_id, text: string, generation: int = 0) -> []string {
	inventory: Bridge_Heartbeat_Inventory
	bridge_decode_heartbeat_inventory(&inventory, text)
	defer bridge_heartbeat_inventory_destroy(&inventory)
	if inventory.state != .Complete || len(inventory.reports) == 0 do return nil
	bridge_apply_heartbeat_reports(h, bridge_id, generation, inventory.reports)
	ids := make([]string, len(inventory.reports), context.allocator)
	for report, i in inventory.reports do ids[i] = strings.clone(report.agent_instance_id, context.allocator)
	return ids
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

revoke_bridge_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	bridge_id := strings.trim_suffix(suffix_after(req.path, "/api/v1/bridges/"), "/revoke")
	return bridge_revoke_respond(h, auth_ctx, bridge_id, req)
}

// bridge_self_revoke_handler: POST /api/v1/bridge/self/revoke. A bridge revokes
// ITSELF with its own bearer token (audit F1): `ham-bridge enroll` replacing this
// machine's enrollment by another account's retires the old bridge on the hub
// instead of leaving it "offline" under the first account forever. The token names
// exactly one bridge, so there is no id in the path to confuse.
bridge_self_revoke_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	token, token_ok := bearer_token(req)
	if !token_ok do return respond_error(domain.domain_error(.Unauthenticated, "bridge bearer token is required"), req.request_id)
	bridge_auth, bridge_ok, bridge_err := bridge_service.verify_bridge_token(h.bridges, token)
	if !bridge_ok do return respond_error(bridge_err, req.request_id)
	return bridge_revoke_respond(h, bridge_auth, bridge_auth.bridge_id, req)
}

// bridge_revoke_respond revokes bridge_id as auth_ctx (owner-checked) and retires
// its vault identity, metrics and logs: the body shared by both revoke routes.
bridge_revoke_respond :: proc(h: ^Bridge_Handlers, auth_ctx: contracts.Auth_Context, bridge_id: string, req: Request) -> Response {
	bridge, revoke_ok, err := bridge_service.revoke_bridge(h.bridges, auth_ctx, bridge_id)
	if !revoke_ok do return respond_error(err, req.request_id)
	publish_bridge_changed(h.event_bus, bridge, "revoked")
	// Passwordless vault: the revoked machine's directory identity gets a retirement
	// HINT (no version, no log op). An approved browser that verifies the identity in
	// the signed log then signs its real revoke (new epoch + wraps). Credentials are
	// already dead here, so a failure leaves the safe state; it is reported and a retry
	// (revoke is idempotent) finishes it.
	if h.vault != nil {
		// .All: a revoke during a pending attach leaves two live identities, both dead now.
		retired, rerr := vd.retire_bridge_identities(h.vault, string(bridge.owner_user_id), bridge.bridge_id, .All)
		if rerr.code != .None {
			fmt.eprintfln("hub: bridge %s revoked, but its vault directory entry was not retired: %s", bridge.bridge_id, rerr.message)
			return respond_error(domain.Domain_Error{code = rerr.code, cause = "vault_entry_not_retired", message = "the bridge was revoked, but its vault directory entry could not be retired; retry the revoke"}, req.request_id)
		}
		if h.event_bus != nil {
			for id in retired do events.publish_resource_changed(h.event_bus, string(bridge.owner_user_id), VAULT_DEVICES_RESOURCE, id, "retired", "{}")
		}
	}
	// The live connection (if any) is being shut down and will tombstone on its
	// own teardown; do it here too so an offline revoked bridge leaves no info.
	project_service.fleet_metrics_tombstone_bridge(bridge.bridge_id)
	// A revoked bridge's error ring goes with it (plan §4.3).
	if h.bridge_logs != nil do _, _ = bridge_log_service.purge_bridge(h.bridge_logs, bridge.bridge_id)
	b := strings.builder_make()
	write_bridge_json(&b, bridge, h.agents, h.bridges.catalog)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

// bridge_uninstall_handler: POST /api/v1/bridges/{id}/uninstall {"purge": bool}
// (default true). The owning account asks an ONLINE bridge to uninstall itself:
// the bridge acknowledges the `bridge_uninstall` frame, then a detached
// `ham-bridge uninstall` wipes its service, binaries and secrets; the bridge stays
// here as offline (not revoked) so a reinstall can reuse it. Every request is audit-logged (bridge_service.log_bridge_uninstall),
// refused ones included. Another account's bridge is Not_Found (owner check); an
// offline bridge is 422: revoke it instead (POST /api/v1/bridges/{id}/revoke).
bridge_uninstall_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	bridge_id := strings.trim_suffix(suffix_after(req.path, "/api/v1/bridges/"), "/uninstall")
	user_id := string(auth_ctx.user_id)
	purge := true
	if jsonx.has_key(req.body, "purge", true) {
		value, valid := json_bool_literal(req.body, "purge")
		if !valid do return respond_error(domain.domain_error(.Validation_Failed, "purge must be a JSON boolean"), req.request_id)
		purge = value
	}
	live := project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry, bridge_id)
	cmd_id, sent, err := bridge_service.send_bridge_uninstall(h.bridges, auth_ctx, bridge_id, purge, live)
	if !sent {
		outcome := "failed"
		#partial switch err.code {
		case .Not_Found, .Forbidden:             outcome = "denied"
		case .Unprocessable_Entity, .Bridge_Offline: outcome = "offline"
		}
		bridge_service.log_bridge_uninstall(outcome, bridge_id, user_id, "", req.request_id, err.message)
		if err.code == .Bridge_Offline do return respond_error(domain.domain_error(.Unprocessable_Entity, err.message), req.request_id)
		return respond_error(err, req.request_id)
	}
	defer delete(cmd_id)
	bridge_service.log_bridge_uninstall("dispatched", bridge_id, user_id, cmd_id, req.request_id, "purge" if purge else "keep_data")
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "{\"command_id\":\"")
	write_handler_json_string(&b, cmd_id)
	strings.write_string(&b, "\",\"bridge_id\":\"")
	write_handler_json_string(&b, bridge_id)
	strings.write_string(&b, "\",\"status\":\"dispatched\",\"purge\":")
	strings.write_string(&b, "true" if purge else "false")
	strings.write_string(&b, "}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 202)
}

bridge_update_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp

	bridge_id := strings.trim_suffix(suffix_after(req.path, "/api/v1/bridges/"), "/update")
	if strings.trim_space(bridge_id) == "" {
		return respond_error(
			domain.domain_error(.Validation_Failed, "bridge_id is required"),
			req.request_id,
		)
	}

	bridge, bridge_ok, err := bridge_service.get_bridge(h.bridges, auth_ctx, bridge_id)
	if !bridge_ok do return respond_error(err, req.request_id)

	// Validate bridge state and reject offline or not-live bridges with 422
	if bridge.status != .Online ||
	   !project_service.bridge_runtime_registry_has_live(
			   h.bridge_runtime_registry,
			   bridge.bridge_id,
		   ) {
		return respond_error(
			domain.domain_error(
				.Unprocessable_Entity,
				fmt.tprintf("Bridge %s is not online", bridge.bridge_id),
			),
			req.request_id,
		)
	}


	update_extensions := false
	if jsonx.has_key(req.body, "update_extensions", true) {
		value, valid := json_bool_literal(req.body, "update_extensions")
		if !valid do return respond_error(domain.domain_error(.Validation_Failed, "update_extensions must be a JSON boolean"), req.request_id)
		update_extensions = value
	}
	force := json_bool_value(req.body, "force")
	drain_timeout := json_int(req.body, "drain_timeout_seconds", 60)
	target_version_raw := json_string(req.body, "target_version")
	defer if len(target_version_raw) > 0 do delete(target_version_raw)
	target_version := target_version_raw if len(target_version_raw) > 0 else "latest"

	active_tasks := agent_service.active_instance_count_for_bridge(h.agents, bridge.bridge_id)
	if active_tasks > 0 && !force && drain_timeout <= 0 {
		return respond_error(
			domain.domain_error(
				.Conflict,
				fmt.tprintf(
					"Bridge %s has %d active agent tasks; specify force=true or a positive drain_timeout_seconds",
					bridge.bridge_id,
					active_tasks,
				),
			),
			req.request_id,
		)
	}

	cmd_id, send_ok, send_err := bridge_service.send_bridge_update(
		h.bridges,
		auth_ctx,
		bridge.bridge_id,
		target_version,
		force,
		drain_timeout,
		update_extensions = update_extensions,
	)
	if !send_ok {
		if send_err.code == .Bridge_Offline || send_err.code == .Unprocessable_Entity {
			return respond_error(
				domain.domain_error(.Unprocessable_Entity, send_err.message),
				req.request_id,
			)
		}
		return respond_error(send_err, req.request_id)
	}
	defer delete(cmd_id)
	// send_bridge_update stamped update_status=updating on the row.
	if updated, got, _ := bridge_service.get_bridge(h.bridges, auth_ctx, bridge.bridge_id); got do publish_bridge_changed(h.event_bus, updated, "updated")

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

write_bridge_json :: proc(b: ^strings.Builder, br: domain.Bridge, agents: ^agent_service.Agent_Service, catalog: ^bridge_service.Bridge_Update_Catalog = nil, enrollment_in_progress := false) {
	strings.write_string(b, "{\"enrollment_in_progress\":"); strings.write_string(b, "true" if enrollment_in_progress || domain.bridge_is_pending(br) else "false")
	strings.write_string(b, ",\"bridge_id\":\""); write_handler_json_string(b, br.bridge_id)
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
	strings.write_string(b, ",\"tool_stream_supported\":"); strings.write_string(b, "true" if agent_service.tool_stream_feature_supported(br) else "false")
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
	strings.write_string(b, "\",\"plan_disabled_at\":\""); write_handler_json_string(b, br.plan_disabled_at)
	strings.write_string(b, "\",\"revoked_at\":\""); write_handler_json_string(b, br.revoked_at)
	update_info := bridge_service.resolve_bridge_update_info(catalog, br)
	strings.write_string(b, "\",\"target\":\""); write_handler_json_string(b, update_info.target)
	strings.write_string(b, "\",\"update_available\":"); strings.write_string(b, "true" if update_info.update_available else "false")
	// REQ-T13-2: false when the latest release ships no bundle for `target`.
	strings.write_string(b, ",\"update_artifact_available\":"); strings.write_string(b, "true" if update_info.artifact_available else "false")
	strings.write_string(b, ",\"latest_version\":\""); write_handler_json_string(b, update_info.latest_version)
	strings.write_string(b, "\",\"latest_source\":\""); write_handler_json_string(b, update_info.latest_source)
	strings.write_string(b, "\",\"update_warning\":\""); write_handler_json_string(b, update_info.warning)
	strings.write_string(b, "\",\"update_fallback_reason\":\""); write_handler_json_string(b, update_info.fallback_reason)
	strings.write_string(b, "\",\"latest_commit_sha\":\""); write_handler_json_string(b, update_info.latest_commit_sha)
	strings.write_string(b, "\",\"telemetry_enabled\":\""); write_handler_json_string(b, br.telemetry_enabled if br.telemetry_enabled != "" else "inherit")
	// REQ-BVS-2: emitted VERBATIM, with no default substitution. A bridge that has
	// never reported yields "", and the key is always present, so the UI can tell
	// "not reported" apart from a real state instead of being told "unlocked".
	strings.write_string(b, "\",\"vault_status\":\""); write_handler_json_string(b, br.vault_status)
	// REQ-EA-1: "pending" = approved but its vault key not yet delivered, so not
	// enrolled; the UI shows it as "Enrolling…" and never offers it as a target.
	strings.write_string(b, "\",\"enrollment_state\":\""); strings.write_string(b, "pending" if domain.bridge_is_pending(br) else "enrolled")
	strings.write_string(b, "\",\"enrollment_pending_until\":\""); write_handler_json_string(b, br.enrollment_pending_until)
	search_ready, search_stale, search_revision := false, false, i64(0)
	if agents != nil && agents.bridge_runtime_registry != nil {
		search_ready, search_stale, search_revision = project_service.bridge_runtime_registry_task_chain_search_status(agents.bridge_runtime_registry, br.bridge_id)
	}
	strings.write_string(b, `","task_chain_search_ready":`); strings.write_string(b, "true" if search_ready else "false")
	strings.write_string(b, `,"task_chain_search_stale":`); strings.write_string(b, "true" if search_stale else "false")
	strings.write_string(b, `,"task_chain_search_revision":`); strings.write_string(b, fmt.tprintf("%d", search_revision))
	pub_key := ""
	unseal: project_service.Bridge_Unseal_Identity
	defer project_service.bridge_unseal_identity_destroy(&unseal)
	if agents != nil && agents.bridge_runtime_registry != nil {
		unseal, _ = project_service.bridge_runtime_registry_unseal_identity(agents.bridge_runtime_registry, br.bridge_id)
		pub_key = unseal.public_key
	}
	if pub_key == "" && br.capabilities_json != "" {
		pub_key = json_string(br.capabilities_json, "public_key", context.temp_allocator)
	}
	strings.write_string(b, ",\"public_key\":\""); write_handler_json_string(b, pub_key)
	strings.write_string(b, "\",\"bridge_public_key\":\""); write_handler_json_string(b, pub_key)
	strings.write_string(b, "\"")
	write_bridge_unseal_identity_fields(b, unseal)
	strings.write_string(b, "}")
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

// BRIDGE_HEARTBEAT_INTERVAL_SECONDS is the heartbeat cadence bridge_ready asks for
// and the bridge follows (REQ-ERR-PROTO-B). Heartbeats are a reconciliation backstop
// (status changes are pushed as they happen), so 45s keeps idle traffic low while a
// missed beat stays well inside the 120s read deadline.
BRIDGE_HEARTBEAT_INTERVAL_SECONDS :: 45

// BRIDGE_HUB_HEARTBEAT_METADATA_OMISSION: this Hub refreshes liveness on every beat
// (T1) and treats the hello record as the only metadata authority on a negotiated
// connection (T3), so it may advertise heartbeat_metadata_omission to runtime sockets.
BRIDGE_HUB_HEARTBEAT_METADATA_OMISSION :: true

// heartbeat_stats tells the bridge whether to attach resource stats to its
// heartbeats (plan 4.3): false only when the owner set telemetry_enabled=disabled.
// heartbeat_metadata_omission is an ADVERTISEMENT only (contracts
// BRIDGE_FEATURE_HEARTBEAT_METADATA_OMISSION): it takes effect on a connection only when
// that connection's hello also listed the feature. diagnostics_frame_v1 tells the Bridge
// this hub accepts bridge_diagnostics (plan §4.3/§4.4); old Bridges ignore it, and a
// Bridge that sees it may move its diagnostics out of the heartbeat. The enroll-only
// socket, which never heartbeats, leaves both false.
bridge_ready_payload :: proc(bridge_id: string, generation: int, replaced: bool, catalog_etag: string = "", heartbeat_stats := true, heartbeat_metadata_omission := false, diagnostics_frame_v1 := false) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"bridge_ready\",\"protocol_version\":1,\"payload\":{\"bridge_id\":\"")
	write_handler_json_string(&b, bridge_id)
	strings.write_string(&b, fmt.tprintf("\",\"heartbeat_interval_seconds\":%d,\"command_ack_timeout_seconds\":10,\"connection_generation\":", BRIDGE_HEARTBEAT_INTERVAL_SECONDS))
	strings.write_string(&b, fmt.tprintf("%d", generation))
	strings.write_string(&b, ",\"replaced_existing\":")
	strings.write_string(&b, "true" if replaced else "false")
	strings.write_string(&b, ",\"catalog_etag\":\"")
	write_handler_json_string(&b, catalog_etag)
	strings.write_string(&b, "\"")
	strings.write_string(&b, ",\"heartbeat_stats\":")
	strings.write_string(&b, "true" if heartbeat_stats else "false")
	strings.write_string(&b, ",\"heartbeat_metadata_omission\":")
	strings.write_string(&b, "true" if heartbeat_metadata_omission else "false")
	strings.write_string(&b, ",\"diagnostics_frame_v1\":")
	strings.write_string(&b, "true" if diagnostics_frame_v1 else "false")
	// This hub bounds the session by its credential and accepts in-band
	// bridge_reauth after a refresh (bridge_ws_try_reauth).
	strings.write_string(&b, ",\"credential_reauth\":true")
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

bridge_heartbeat_ack_payload :: proc(reconciled: int, superseded_instance_ids: []string = nil, schedules_version: int = 0, schedules_epoch := "", schedules_revision: i64 = -1) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"bridge_heartbeat_ack\",\"protocol_version\":1,\"payload\":{\"reconciled_unreachable_count\":")
	strings.write_string(&b, fmt.tprintf("%d", reconciled))
	strings.write_string(&b, ",\"schedules_version\":")
	strings.write_string(&b, fmt.tprintf("%d", schedules_version))
	if schedules_epoch != "" && schedules_revision >= 0 {
        strings.write_string(&b, fmt.tprintf(",\"schedules_epoch\":\"%s\",\"schedules_revision\":%d", schedules_epoch, schedules_revision))
    }
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
bridge_apply_vault_status_report :: proc(h: ^Bridge_Handlers, bridge_id, text: string, generation: int = 0) {
	if h == nil || h.bridges == nil do return
	report: struct {
		vault_status: string,
	}
	if !vault.wire_decode(text, &report) do return
	value := report.vault_status
	if value == "" do return
	c, current := bridge_runtime_state_enter(h, bridge_id, generation)
	if !current do return
	bridge, changed, _ := bridge_service.update_vault_status(h.bridges, bridge_id, value)
	bridge_runtime_state_leave(h, c)
	defer { b := bridge; domain.bridge_destroy(&b) }
	if !changed do return
	summary := bridge_vault_status_summary_json(bridge.vault_status)
	defer delete(summary)
	events.publish_resource_changed(h.event_bus, string(bridge.owner_user_id), "bridge", bridge.bridge_id, "vault_status_changed", summary)
}

// bridge_runtime_state_enter is the retirement barrier for durable Bridge-row writes
// made on behalf of one connection generation (plan T1), the same barrier
// bridge_apply_validated_status uses for instance rows: hold the generation's
// state_mutex and refuse once it is retired. A replacing hello retires the old
// generation before its own durable connect write, which takes the same lock, so a
// delayed frame from the old connection cannot land a liveness, metadata or vault
// write after the new generation was admitted. ok=false means "stale generation:
// write nothing". Generation 0 / no registry is a unit harness with no registered
// connection, where there is nothing to fence against. Publish AFTER
// bridge_runtime_state_leave: lock order is tx_mutex -> state_mutex, never reverse.
bridge_runtime_state_enter :: proc(h: ^Bridge_Handlers, bridge_id: string, generation: int) -> (^project_service.Bridge_Runtime_Connection, bool) {
	if h.bridge_runtime_registry == nil || generation == 0 do return nil, true
	c := project_service.bridge_runtime_connection_acquire(h.bridge_runtime_registry, bridge_id, generation)
	if c == nil do return nil, false
	project_service.connection_state_lock(c)
	if sync.atomic_load(&c.retired) {
		project_service.connection_state_unlock(c)
		project_service.bridge_runtime_connection_release(h.bridge_runtime_registry, c)
		return nil, false
	}
	return c, true
}

bridge_runtime_state_leave :: proc(h: ^Bridge_Handlers, c: ^project_service.Bridge_Runtime_Connection) {
	if c == nil do return
	project_service.connection_state_unlock(c)
	project_service.bridge_runtime_connection_release(h.bridge_runtime_registry, c)
}

// HEARTBEAT_METADATA_REJECT_RESYNC is the bridge_frames_rejected{reason} label for a
// beat that found this connection's hello metadata missing or replaced.
HEARTBEAT_METADATA_REJECT_RESYNC :: "metadata_resync"

Heartbeat_Metadata_Result :: enum {
	Applied,         // fenced write path ran (or nothing to do)
	Stale,           // generation replaced or retired: nothing written
	Resync_Required, // stored metadata no longer matches this connection's hello
}

// bridge_record_hello_metadata records which metadata contract this connection's hello
// installed: the canonical features the stored record must keep, and whether heartbeat
// metadata omission is negotiated — the Hub always advertises it, so it is negotiated
// exactly when the hello lists BRIDGE_FEATURE_HEARTBEAT_METADATA_OMISSION. Caller holds
// connection_state_lock (the same section that wrote the record).
bridge_record_hello_metadata :: proc(c: ^project_service.Bridge_Runtime_Connection, hello_text: string) {
	if c == nil do return
	features := bridge_service.bridge_runtime_features_raw(hello_text, context.temp_allocator)
	omission := false
	if BRIDGE_HUB_HEARTBEAT_METADATA_OMISSION {
		listed := jsonx.extract_string_array(hello_text, "features", true, context.temp_allocator)
		for f in listed do if f == contracts.BRIDGE_FEATURE_HEARTBEAT_METADATA_OMISSION do omission = true
	}
	project_service.bridge_runtime_connection_set_metadata(c, omission, features)
}

// bridge_apply_heartbeat_liveness refreshes durable Bridge liveness for an accepted
// heartbeat, then applies the metadata contract (plan T3), all under the generation
// barrier so a delayed frame from a replaced connection writes nothing:
//   - negotiated omission: heartbeat capabilities/features are IGNORED, present or not;
//     the hello record is the sole authority and is never overwritten by a beat.
//   - not negotiated (old Bridge, or a Bridge that did not list the feature): a legacy
//     beat carrying metadata is applied as a full replacement, as before; one that
//     omits it anyway (unsupported omission) changes nothing.
//   - whenever the beat did not apply metadata, the stored features must still be what
//     this connection installed; otherwise Resync_Required (fail closed — admission
//     reads that record).
// Only a status or capability diff publishes; an ordinary beat is silent.
bridge_apply_heartbeat_liveness :: proc(h: ^Bridge_Handlers, bridge_id: string, generation: int, text: string) -> Heartbeat_Metadata_Result {
	if h == nil || h.bridges == nil do return .Applied
	c, current := bridge_runtime_state_enter(h, bridge_id, generation)
	if !current do return .Stale
	bridge, moved, err := bridge_service.touch_runtime_liveness(h.bridges, bridge_id)
	caps_changed := false
	result := Heartbeat_Metadata_Result.Applied
	if err.code == .None {
		negotiated := c != nil && c.metadata_recorded && c.metadata_omission
		legacy := !negotiated && strings.contains(text, "\"capabilities\"")
		if legacy {
			caps_err: domain.Domain_Error
			caps_changed, caps_err = bridge_service.update_runtime_metadata(h.bridges, bridge_id, text)
			// The beat's list is now this connection's expectation (a legacy Bridge
			// may legitimately change it); a failed write is repaired by the next beat.
			if caps_err.code == .None do project_service.bridge_runtime_connection_set_metadata_features(c, bridge_service.bridge_runtime_features_raw(text, context.temp_allocator))
		} else if c != nil && c.metadata_recorded {
			stored, found := bridge_service.bridge_stored_features_raw(bridge.capabilities_json, context.temp_allocator)
			if !found || stored != c.metadata_features do result = .Resync_Required
		}
	}
	bridge_runtime_state_leave(h, c)
	if err.code != .None do return result
	defer domain.bridge_destroy(&bridge)
	if moved || caps_changed do publish_bridge_changed(h.event_bus, bridge, "capabilities_changed")
	return result
}

bridge_vault_status_summary_json :: proc(vault_status: string) -> string {
	out, _ := vault.wire_encode(struct {
		vault_status: string,
	}{vault_status = vault_status})
	return out
}

bridge_status_summary_json :: proc(status: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"status\":\""); write_handler_json_string(&b, status)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

// bridge_publish_online_status fans out the bridge `status_changed` invalidation for
// a runtime connect (REQ-ENR-1), in the same summary format the disconnect path
// uses. `bridge` is the row bridge_runtime_connect saved; anything but .Online (or a
// row with no owner) publishes nothing.
bridge_publish_online_status :: proc(h: ^Bridge_Handlers, bridge: domain.Bridge) {
	if h == nil || bridge.status != .Online do return
	summary := bridge_status_summary_json(domain.bridge_status_string(bridge.status))
	defer delete(summary)
	events.publish_resource_changed(h.event_bus, string(bridge.owner_user_id), "bridge", bridge.bridge_id, "status_changed", summary)
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
	// Opcode of the message most recently returned by bridge_ws_take_frame: 0x1 text,
	// 0x2 binary (REQ-PTY-NET-2: binary = a pty_wire frame, never JSON).
	last_opcode:       u8,
	max_buffer_bytes: int, // zero preserves existing default; bounded JSON streams opt in
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

// bridge_ws_take_frame extracts ONE complete text or binary frame or reassembled
// fragmented message from reader.pending (reader.last_opcode says which), consuming its bytes and leaving any trailing bytes
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
			max_buffer_bytes = reader.max_buffer_bytes if reader.max_buffer_bytes > 0 else ws.WS_READER_DEFAULT_MAX_BUFFER_BYTES,
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
		case 0x1, 0x2:
			if reader.fragmenting {
				delete(payload)
				reader.fatal_reason = .Fatal_Frame
				return "", false, true
			}
			if fin {
				reader.last_opcode = op
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
			if len(reader.fragmented) + len(payload) > (reader.max_buffer_bytes if reader.max_buffer_bytes > 0 else ws.WS_CONTINUATION_DEFAULT_MAX_BYTES) {
				delete(payload)
				reader.fatal_reason = .Fatal_Frame
				return "", false, true
			}
			append(&reader.fragmented, ..transmute([]u8)payload)
			delete(payload)
			if fin {
				reader.fragmenting = false
				reader.last_opcode = reader.fragmented_opcode
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
	project_service.bridge_runtime_connection_lock_writer(connection)
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
	project_service.bridge_runtime_connection_lock_writer(c)
	defer sync.mutex_unlock(&c.writer_mutex)
	if sync.atomic_load(&c.retired) do return false
	return ws.write_server_opcode(socket, 0xA, payload, false) == .Ok
}

pane_reader_write_pong :: proc(raw: rawptr, socket: net.TCP_Socket, payload: string) -> bool {
	return shell_session_svc.shell_session_enqueue_viewer_control((^shell_session_svc.Shell_Session_Service)(raw), socket, 0xA, payload)
}


// Keep the bridge_error shape understood by older bridges, with a typed code and
// upgrade path for current bridges. The server owns all values except the escaped message.
bridge_ws_plan_error_payload :: proc(err: domain.Domain_Error) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"type":"bridge_error","protocol_version":1,"payload":{"code":"plan_limit_reached","message":"`)
	write_handler_json_string(&b, err.message)
	strings.write_string(&b, `","upgrade_path":"/settings/account","details":`)
	strings.write_string(&b, err.details_json if err.details_json != "" else "{}")
	strings.write_string(&b, "}}")
	return strings.to_string(b)
}


// Plan refusals have an application close code as well as the diagnostic frame.
// These calls happen before registering a command socket, so there is one writer.
bridge_ws_domain_error :: proc(client: net.TCP_Socket, err: domain.Domain_Error) {
	if err.cause == BRIDGE_WS_SUNSET_PENDING_CODE || err.cause == BRIDGE_WS_CREDENTIAL_REVOKED_CODE || err.code == .Bridge_Revoked {
		bridge_ws_auth_error(client, err)
		return
	}
	if err.code != .Plan_Limit_Reached {
		_ = write_ws_text_frame(client, bridge_ws_error_payload(err.message))
		return
	}
	_ = write_ws_text_frame(client, bridge_ws_plan_error_payload(err))
	frame: [22]byte
	frame[0] = 0x88 // FIN + CLOSE
	frame[1] = 20
	frame[2] = 0x11 // 4402, network byte order
	frame[3] = 0x32
	copy(frame[4:], "plan_limit_reached")
	_, _ = net.send_tcp(client, frame[:])
}

// Used only after verifying a bridge bearer, never for unrelated authorization.
// Expiry can be refreshed; invalid/revoked credentials require explicit enrollment.
bridge_ws_auth_error :: proc(client: net.TCP_Socket, err: domain.Domain_Error) {
    if err.cause != BRIDGE_WS_SUNSET_PENDING_CODE && err.code != .Unauthenticated && err.code != .Forbidden && err.code != .Bridge_Revoked {
        // A transient admission failure is not authoritative revocation.
        _ = write_ws_text_frame(client, bridge_ws_error_payload(err.message))
        return
    }
    code := BRIDGE_WS_CREDENTIAL_REVOKED_CODE
    if err.cause == BRIDGE_WS_SUNSET_PENDING_CODE do code = BRIDGE_WS_SUNSET_PENDING_CODE
    else if err.code == .Unauthenticated && strings.contains(err.message, "expired") do code = BRIDGE_WS_TOKEN_EXPIRED_CODE
    _ = write_ws_text_frame(client, bridge_ws_session_error_payload(code, err.message, context.temp_allocator))
}
