package http

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import agent_service "odin_test:hub/service/agent"
import auth_service "odin_test:hub/service/auth"
import bridge_service "odin_test:hub/service/bridge"
import bridge_runtime_service "odin_test:hub/service/bridge_runtime"
import project_service "odin_test:hub/service/project"
import user_service "odin_test:hub/service/user"

import provider_service "odin_test:hub/service/provider"
@(private = "file")
Extension_Sink_Recorder :: struct {
	sent:     bool,
	count:    int,
	fail:     bool,
	last_cmd: project_service.Runtime_Command,
}

@(private = "file")
extension_test_sink :: proc(
	ctx: rawptr,
	cmd: project_service.Runtime_Command,
) -> (
	bool,
	domain.Domain_Error,
) {
	rec := (^Extension_Sink_Recorder)(ctx)
	if rec.fail do return false, domain.domain_error(.Bridge_Offline, "test send failed")
	rec.count += 1
	if rec.sent {
		delete(
			rec.last_cmd.bridge_id,
		); delete(rec.last_cmd.command_id); delete(rec.last_cmd.body_json)
	}
	rec.sent = true
	rec.last_cmd = project_service.Runtime_Command {
		bridge_id  = strings.clone(cmd.bridge_id),
		command_id = strings.clone(cmd.command_id),
		body_json  = strings.clone(cmd.body_json),
	}
	return true, domain.Domain_Error{}
}

// Wire fixture for HTTP handler tests
@(private = "file")
extension_handler_fixture :: struct {
	db_path:       string,
	conn:          sqlite.Conn,
	pr_impl:       sqlite.Provider_Repo_SQLite,
	pr_repo:       iface.Provider_Repository,
	pr_svc:        provider_service.Provider_Service,
	ph:            Provider_Handlers,
	catalog:       bridge_service.Bridge_Update_Catalog,
	br_impl:       sqlite.Bridge_Repo_SQLite,
	us_impl:       sqlite.User_Repo_SQLite,
	ag_impl:       sqlite.Agent_Repo_SQLite,
	br_repo:       iface.Bridge_Repository,
	us_repo:       iface.User_Repository,
	ag_repo:       iface.Agent_Repository,
	clock:         platform.Clock,
	ids:           platform.ID_Generator,
	br_svc:        bridge_service.Bridge_Service,
	us_svc:        user_service.User_Service,
	ag_svc:        agent_service.Agent_Service,
	auth_svc:      auth_service.Auth_Service,
	user_headers: []contracts.HTTP_Header, // session cookie for the fixture owner
	bh:            Bridge_Handlers,
	registry:      project_service.Bridge_Runtime_Registry,
	sink_rec:      Extension_Sink_Recorder,
	owner_user_id: string,
	bridge_id:     string,
}


@(private = "file")
extension_test_setup :: proc(
	t: ^testing.T,
	tag: string,
	database_path: string = ":memory:",
) -> ^extension_handler_fixture {
	f := new(extension_handler_fixture)
	f.db_path = database_path


	conn, open_ok, open_err := sqlite.open(f.db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	f.conn = conn

	mig_ok, mig_err := sqlite.run_migrations(&f.conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	f.br_repo = sqlite.new_bridge_repository(&f.br_impl, &f.conn)
	f.us_repo = sqlite.new_user_repository(&f.us_impl, &f.conn)
	f.ag_repo = sqlite.new_agent_repository(&f.ag_impl, &f.conn)

	f.clock = platform.real_clock()
	f.ids = http_test_id_generator()

	f.sink_rec = Extension_Sink_Recorder{}
	sink := project_service.Bridge_Command_Sink {
		ctx                  = rawptr(&f.sink_rec),
		send_runtime_command = extension_test_sink,
	}

	f.br_svc = bridge_service.new_bridge_service_with_runtime(&f.br_repo, sink, &f.clock, &f.ids)
	f.us_svc = user_service.new_user_service_basic(&f.us_repo, &f.clock, &f.ids)
	f.ag_svc = agent_service.new_agent_service(&f.ag_repo, &f.br_repo, &f.clock, &f.ids)

	f.auth_svc = auth_service.new_auth_service(auth_service.Auth_Config{auto_provision_users = true},
		&f.us_svc,
	)
	f.auth_svc.clock = &f.clock
	f.auth_svc.ids = &f.ids
	f.auth_svc.bridges = &f.br_svc
	f.auth_svc.agents = &f.ag_svc

	f.bh = Bridge_Handlers {
		auth                    = &f.auth_svc,
		bridges                 = &f.br_svc,
		agents                  = &f.ag_svc,
		bridge_runtime_registry = &f.registry,
	}

	f.user_headers = http_test_login(t, &f.auth_svc, "update_test_user")
	owner_ctx, owner_ok, _ := auth_service.resolve_auth_any(
		&f.auth_svc,
		auth_service.Auth_Request {
			remote_addr = "127.0.0.1:4444",
			headers = f.user_headers,
		},
	)
	testing.expect(t, owner_ok, "session owner resolved")
	f.owner_user_id = strings.clone(owner_ctx.user_id)

	owner_auth := contracts.Auth_Context {
		kind    = .Session,
		user_id = f.owner_user_id,
	}
	// Provisioned through the DEVICE-GRANT path, the only enrollment there is
	// (REQ-ENROLL-9). This replaced a create_enrollment + enroll_bridge pair; the
	// bridge and its credential are what this fixture needs, and how the credential
	// was approved is not what these tests are about.
	enrolled, e_ok, _ := bridge_service.enroll_bridge_from_device_grant(
		&f.br_svc,
		bridge_service.Device_Enroll_Input {
			owner_user_id = f.owner_user_id,
			bridge_public_key = "04aabb",
			bridge_key_fingerprint = "aaaa bbbb cccc dddd",
			machine_hostname = "test-box",
		},
	)
	testing.expect(t, e_ok, "bridge enrolled")
	f.bridge_id = strings.clone(enrolled.bridge.bridge_id)


	f.pr_repo = sqlite.new_provider_repository(&f.pr_impl, &f.conn)
	f.pr_svc = provider_service.new_provider_service(&f.pr_repo)
	f.br_svc.provider_repo = &f.pr_repo
	f.bh.providers = &f.pr_svc
	f.ph = {
		auth                    = &f.auth_svc,
		providers               = &f.pr_svc,
		bridges                 = &f.br_svc,
		bridge_runtime_registry = &f.registry,
		clock                   = &f.clock,
		ids                     = &f.ids,
	}
	bridge, _, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	bridge.status = .Online
	bridge.version = "0.1.0"
	bridge.commit_sha = "old"
	_, _, _ = iface.bridge_save_bridge(&f.br_repo, bridge)
	_, _, _ = bridge_runtime_service.runtime_accept_hello(
		&f.registry,
		f.bridge_id,
		bridge_runtime_service.PROTOCOL_VERSION,
		"",
	)
	f.catalog = {
		override_version      = "0.2.0",
		override_commit_sha   = "new",
		override_download_url = "https://example.com/heimdall-local-linux-amd64.tar.gz",
		override_sha256       = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
	}
	f.br_svc.catalog = &f.catalog
	return f
}

@(private = "file")
extension_test_teardown :: proc(f: ^extension_handler_fixture) {
	if f == nil do return
	sqlite.close(&f.conn)

	delete(f.owner_user_id)
	delete(f.bridge_id)
	if f.sink_rec.sent {
		delete(f.sink_rec.last_cmd.bridge_id)
		delete(f.sink_rec.last_cmd.command_id)
		delete(f.sink_rec.last_cmd.body_json)
	}
	free(f)
}


extension_test_request :: proc(
	f: ^extension_handler_fixture,
	path: string,
	body: string = "{}",
) -> Request {
	return {
		method = "POST",
		path = path,
		body = body,
		request_id = "req_extension",
		remote_addr = "127.0.0.1:4444",
		headers = f.user_headers,
	}
}
extension_test_status :: proc(
	t: ^testing.T,
	f: ^extension_handler_fixture,
	provider, state, ext_state: string,
	enabled: bool = true,
) {
	_, err := iface.bridge_provider_status_upsert(
		&f.pr_repo,
		{
			bridge_id = f.bridge_id,
			provider = provider,
			binary_path = "/bin/provider",
			state = state,
			extension_state = ext_state,
			extension_version = "0.1.0",
			checked_at = "2026-01-01",
			extension_checked_at = "2026-01-01",
		},
	)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	_, err = iface.bridge_provider_setting_upsert(
		&f.pr_repo,
		{bridge_id = f.bridge_id, provider = provider, enabled = enabled},
	)
	testing.expect_value(t, err.code, domain.Error_Code.None)
}
extension_test_commands :: proc(
	t: ^testing.T,
	f: ^extension_handler_fixture,
) -> [dynamic]domain.Provider_Extension_Command {
	commands, err := iface.provider_extension_command_list(&f.pr_repo, f.bridge_id)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	return commands
}
extension_test_update :: proc(
	t: ^testing.T,
	f: ^extension_handler_fixture,
	body: string,
) -> string {
	response := bridge_update_handler(
		rawptr(&f.bh),
		extension_test_request(f, fmt.tprintf("/api/v1/bridges/%s/update", f.bridge_id), body),
	)
	testing.expectf(
		t,
		response.status == 202,
		"expected 202, got %d: %s",
		response.status,
		response.body,
	)
	return json_string(response.body, "command_id")
}
extension_test_restart :: proc(
	t: ^testing.T,
	f: ^extension_handler_fixture,
	command_id: string,
	commit: string = "new",
) {
	frame := fmt.tprintf("{{\"command_id\":\"%s\",\"stage\":\"restarting\"}}", command_id)
	err := bridge_extension_frame(&f.bh, f.bridge_id, "bridge_update_progress", frame)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	bridge, _, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	defer domain.bridge_destroy(&bridge)
	delete(bridge.version); bridge.version = strings.clone("0.2.0")
	delete(bridge.commit_sha); bridge.commit_sha = strings.clone(commit)
	err = bridge_extension_reconnected(&f.bh, bridge)
	testing.expect_value(t, err.code, domain.Error_Code.None)
}
extension_test_report :: proc(
	t: ^testing.T,
	f: ^extension_handler_fixture,
	request_id, providers_json: string,
) {
	frame := fmt.tprintf(
		"{{\"type\":\"provider_discovery_report\",\"request_id\":\"%s\",\"providers\":%s}}",
		request_id,
		providers_json,
	)
	err := bridge_extension_frame(&f.bh, f.bridge_id, "provider_discovery_report", frame)
	testing.expect_value(t, err.code, domain.Error_Code.None)
}

@(test)
test_extension_install_endpoint_dispatch_tracking_and_verified_completion :: proc(t: ^testing.T) {
	f := extension_test_setup(t, "manual")
	defer extension_test_teardown(f)
	extension_test_status(t, f, "codex", "present", "absent")
	path := fmt.tprintf("/api/v1/bridges/%s/providers/codex/extension-install", f.bridge_id)
	response := bridge_provider_extension_install_handler(
		rawptr(&f.ph),
		extension_test_request(f, path),
	)
	testing.expectf(
		t,
		response.status == 202,
		"expected 202, got %d: %s",
		response.status,
		response.body,
	)
	id := json_string(response.body, "command_id")
	defer delete(id)
	testing.expect(t, strings.has_prefix(id, "cmd_ext_"))
	testing.expect_value(t, json_string(f.sink_rec.last_cmd.body_json, "provider"), "codex")
	testing.expect_value(
		t,
		json_string(f.sink_rec.last_cmd.body_json, "type"),
		"provider_extension_install",
	)
	testing.expect_value(t, json_string(f.sink_rec.last_cmd.body_json, "command_id"), id)
	commands := extension_test_commands(t, f)
	defer domain.provider_extension_commands_destroy(commands)
	testing.expect_value(t, len(commands), 1)
	testing.expect_value(t, commands[0].state, "dispatched")
	duplicate := bridge_provider_extension_install_handler(
		rawptr(&f.ph),
		extension_test_request(f, path),
	)
	testing.expect_value(t, duplicate.status, 409)
	testing.expect_value(t, f.sink_rec.count, 1)
	err := bridge_extension_frame(
		&f.bh,
		f.bridge_id,
		"command_result",
		fmt.tprintf("{{\"command_id\":\"%s\",\"status\":\"accepted\"}}", id),
	)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	poll := extension_test_request(f, fmt.tprintf("%s/%s", path, id))
	poll.method = "GET"
	tracking := bridge_provider_extension_command_handler(rawptr(&f.ph), poll)
	testing.expect_value(t, tracking.status, 200)
	testing.expect(t, strings.contains(tracking.body, "\"status\":\"accepted\""))
	err = bridge_extension_frame(
		&f.bh,
		f.bridge_id,
		"provider_extension_install_progress",
		fmt.tprintf(
			"{{\"command_id\":\"%s\",\"stage\":\"succeeded\",\"progress_percent\":100}}",
			id,
		),
	)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	tracking = bridge_provider_extension_command_handler(rawptr(&f.ph), poll)
	testing.expect(
		t,
		!strings.contains(tracking.body, "\"status\":\"succeeded\""),
		"progress must not masquerade as terminal completion",
	)
	extension_test_report(
		t,
		f,
		id,
		"[{\"provider\":\"codex\",\"state\":\"present\",\"extension_state\":\"present\",\"extension_version\":\"0.4.31\"}]",
	)
	err = bridge_extension_frame(
		&f.bh,
		f.bridge_id,
		"command_result",
		fmt.tprintf("{{\"command_id\":\"%s\",\"status\":\"succeeded\"}}", id),
	)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	tracking = bridge_provider_extension_command_handler(rawptr(&f.ph), poll)
	testing.expect(t, strings.contains(tracking.body, "\"status\":\"succeeded\""))
	statuses, _ := iface.bridge_provider_status_list(&f.pr_repo, f.bridge_id)
	defer domain.bridge_provider_statuses_destroy(statuses)
	testing.expect_value(t, statuses[0].extension_version, "0.4.31")
	// Late accepted frames cannot regress completion.
	_ = bridge_extension_frame(
		&f.bh,
		f.bridge_id,
		"command_result",
		fmt.tprintf("{{\"command_id\":\"%s\",\"status\":\"accepted\"}}", id),
	)
	tracking = bridge_provider_extension_command_handler(rawptr(&f.ph), poll)
	testing.expect(t, strings.contains(tracking.body, "\"status\":\"succeeded\""))
}

@(test)
test_extension_install_endpoint_auth_and_eligibility :: proc(t: ^testing.T) {
	f := extension_test_setup(t, "errors")
	defer extension_test_teardown(f)
	path := fmt.tprintf("/api/v1/bridges/%s/providers/codex/extension-install", f.bridge_id)
	req := extension_test_request(f, path)
	req.headers = nil; req.remote_addr = "192.0.2.1:123"
	response := bridge_provider_extension_install_handler(rawptr(&f.ph), req)
	testing.expect_value(t, response.status, 401)
	req = extension_test_request(f, path)
	response = bridge_provider_extension_install_handler(rawptr(&f.ph), req)
	testing.expect_value(t, response.status, 409)
	req.path = fmt.tprintf(
		"/api/v1/bridges/%s/providers/no-such-provider/extension-install",
		f.bridge_id,
	)
	response = bridge_provider_extension_install_handler(rawptr(&f.ph), req)
	testing.expect_value(t, response.status, 404)
	req.path = fmt.tprintf("/api/v1/bridges/%s/providers/pi/extension-install", f.bridge_id)
	response = bridge_provider_extension_install_handler(rawptr(&f.ph), req)
	testing.expect_value(t, response.status, 422)
	req.path = path
	extension_test_status(t, f, "codex", "present", "absent")
	f.sink_rec.fail = true
	response = bridge_provider_extension_install_handler(rawptr(&f.ph), req)
	testing.expect(t, response.status >= 400, "send failure must not return Accepted")
	f.sink_rec.fail = false
	bridge, _, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	bridge.status = .Offline
	_, _, _ = iface.bridge_save_bridge(&f.br_repo, bridge)
	response = bridge_provider_extension_install_handler(rawptr(&f.ph), req)
	testing.expect(t, response.status >= 400, "offline bridge rejected")
	testing.expect_value(t, f.sink_rec.count, 0)
}

@(test)
test_extension_update_opt_in_defaults_and_validation :: proc(t: ^testing.T) {
	for body in ([2]string{"{}", "{\"update_extensions\":false}"}) {
		f := extension_test_setup(t, "optout")
		id := extension_test_update(t, f, body)
		extension_test_restart(t, f, id)
		commands := extension_test_commands(t, f)
		testing.expect_value(t, len(commands), 1)
		testing.expect(t, !commands[0].update_extensions)
		testing.expect_value(t, f.sink_rec.count, 1)
		domain.provider_extension_commands_destroy(commands)
		delete(id)
		extension_test_teardown(f)
	}
	f := extension_test_setup(t, "invalid")
	defer extension_test_teardown(f)
	for body in ([3]string {
			"{\"update_extensions\":\"true\"}",
			"{\"update_extensions\":null}",
			"{\"update_extensions\":1}",
		}) {
		response := bridge_update_handler(
			rawptr(&f.bh),
			extension_test_request(f, fmt.tprintf("/api/v1/bridges/%s/update", f.bridge_id), body),
		)
		testing.expect_value(t, response.status, 400)
	}
	testing.expect_value(t, f.sink_rec.count, 0)
}

@(test)
test_extension_update_fresh_discovery_restart_recovery_and_dedup :: proc(t: ^testing.T) {
	f := extension_test_setup(t, "automatic")
	defer extension_test_teardown(f)
	extension_test_status(t, f, "codex", "present", "outdated")
	extension_test_status(t, f, "claude", "present", "outdated", false)
	extension_test_status(t, f, "antigravity", "present", "outdated")
	id := extension_test_update(t, f, "{\"update_extensions\":true}")
	defer delete(id)
	testing.expect_value(t, f.sink_rec.count, 1)
	// Recreate the service projection: opt-in and work survive a Hub restart.
	replacement := provider_service.new_provider_service(&f.pr_repo)
	f.bh.providers = &replacement
	f.ph.providers = &replacement
	extension_test_restart(t, f, id)
	testing.expect_value(t, f.sink_rec.count, 2)
	discovery := strings.clone(f.sink_rec.last_cmd.command_id)
	defer delete(discovery)
	testing.expect_value(
		t,
		json_string(f.sink_rec.last_cmd.body_json, "type"),
		"provider_discover",
	)
	report := "[{\"provider\":\"codex\",\"state\":\"present\",\"extension_state\":\"outdated\",\"extension_version\":\"0.1.0\"},{\"provider\":\"claude\",\"state\":\"present\",\"extension_state\":\"outdated\",\"extension_version\":\"0.1.0\"},{\"provider\":\"antigravity\",\"state\":\"present\",\"extension_state\":\"absent\",\"extension_version\":\"\"}]"
	extension_test_report(t, f, discovery, report)
	testing.expect_value(t, f.sink_rec.count, 3)
	testing.expect_value(t, json_string(f.sink_rec.last_cmd.body_json, "provider"), "codex")
	install_id := strings.clone(f.sink_rec.last_cmd.command_id)
	defer delete(install_id)
	extension_test_report(t, f, discovery, report)
	testing.expect_value(t, f.sink_rec.count, 3)
	// Duplicate update success events cannot enqueue a second follow-up.
	_ = bridge_extension_frame(
		&f.bh,
		f.bridge_id,
		"command_result",
		fmt.tprintf("{{\"command_id\":\"%s\",\"status\":\"succeeded\"}}", id),
	)
	commands := extension_test_commands(t, f)
	defer domain.provider_extension_commands_destroy(commands)
	testing.expect_value(t, len(commands), 3)
	installs := 0
	for command in commands {if command.kind ==
		   "install" {installs += 1; testing.expect_value(t, command.command_id, install_id)}}
	testing.expect_value(t, installs, 1)
}

@(test)
test_extension_update_failure_rollback_and_acceptance_queue_none :: proc(t: ^testing.T) {
	for state in ([3]string{"failed", "cancelled", "accepted"}) {
		f := extension_test_setup(t, "failed")
		id := extension_test_update(t, f, "{\"update_extensions\":true}")
		_ = bridge_extension_frame(
			&f.bh,
			f.bridge_id,
			"command_result",
			fmt.tprintf("{{\"command_id\":\"%s\",\"status\":\"%s\"}}", id, state),
		)
		bridge, _, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
		err := bridge_extension_reconnected(&f.bh, bridge)
		testing.expect_value(t, err.code, domain.Error_Code.None)
		domain.bridge_destroy(&bridge)
		testing.expect_value(t, f.sink_rec.count, 1)
		commands := extension_test_commands(t, f)
		testing.expect_value(t, len(commands), 1)
		domain.provider_extension_commands_destroy(commands)
		delete(id)
		extension_test_teardown(f)
	}
	f := extension_test_setup(t, "rollback")
	defer extension_test_teardown(f)
	id := extension_test_update(t, f, "{\"update_extensions\":true}")
	defer delete(id)
	extension_test_restart(t, f, id, "old")
	testing.expect_value(t, f.sink_rec.count, 1)
	commands := extension_test_commands(t, f)
	defer domain.provider_extension_commands_destroy(commands)
	testing.expect_value(t, commands[0].state, "failed")
}

@(test)
test_extension_update_replays_discovery_but_not_duplicate_followups :: proc(t: ^testing.T) {
	f := extension_test_setup(t, "recovery")
	defer extension_test_teardown(f)
	extension_test_status(t, f, "codex", "present", "outdated")
	id := extension_test_update(t, f, "{\"update_extensions\":true}")
	defer delete(id)
	extension_test_restart(t, f, id)
	discovery := strings.clone(f.sink_rec.last_cmd.command_id)
	defer delete(discovery)
	bridge, _, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	defer domain.bridge_destroy(&bridge)
	err := bridge_extension_reconnected(&f.bh, bridge)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, f.sink_rec.last_cmd.command_id, discovery)
	extension_test_report(
		t,
		f,
		discovery,
		"[{\"provider\":\"codex\",\"state\":\"present\",\"extension_state\":\"present\",\"extension_version\":\"0.4.31\"}]",
	)
	testing.expect_value(
		t,
		json_string(f.sink_rec.last_cmd.body_json, "type"),
		"provider_discover",
	)
	count := f.sink_rec.count
	err = bridge_extension_reconnected(&f.bh, bridge)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, f.sink_rec.count, count)
}

@(test)
test_extension_command_owner_scope_and_stale_connection_frames :: proc(t: ^testing.T) {
	f := extension_test_setup(t, "scope")
	defer extension_test_teardown(f)
	extension_test_status(t, f, "codex", "present", "absent")
	path := fmt.tprintf("/api/v1/bridges/%s/providers/codex/extension-install", f.bridge_id)
	response := bridge_provider_extension_install_handler(
		rawptr(&f.ph),
		extension_test_request(f, path),
	)
	testing.expect_value(t, response.status, 202)
	id := json_string(response.body, "command_id")
	defer delete(id)
	other_headers := http_test_login(t, &f.auth_svc, "other-extension-owner")
	req := extension_test_request(f, path)
	req.headers = other_headers
	denied := bridge_provider_extension_install_handler(rawptr(&f.ph), req)
	testing.expect(t, denied.status == 403 || denied.status == 404, "other owner cannot install")
	req.path = fmt.tprintf("%s/%s", path, id); req.method = "GET"
	denied = bridge_provider_extension_command_handler(rawptr(&f.ph), req)
	testing.expect(t, denied.status == 403 || denied.status == 404, "other owner cannot poll")
	req = extension_test_request(f, fmt.tprintf("%s/not-this-command", path))
	req.method = "GET"
	missing := bridge_provider_extension_command_handler(rawptr(&f.ph), req)
	testing.expect_value(t, missing.status, 404)
	// The real dispatcher must reject stale generation frames before they mutate state.
	generation := project_service.bridge_runtime_registry_generation(&f.registry, f.bridge_id)
	chunks := [dynamic]Bridge_Chunk_Reassembly{}
	stale := fmt.aprintf(
		"{{\"type\":\"command_result\",\"protocol_version\":1,\"command_id\":\"%s\",\"ok\":true,\"payload\":{{\"status\":\"succeeded\"}}}}",
		id,
	)
	accepted := bridge_ws_process_frame(&f.bh, f.bridge_id, generation + 1, 0, &chunks, stale)
	testing.expect(t, !accepted)
	commands := extension_test_commands(t, f)
	testing.expect_value(t, commands[0].state, "dispatched")
	domain.provider_extension_commands_destroy(commands)
	// Current generation processes the nested production envelope.
	current := fmt.aprintf(
		"{{\"type\":\"command_result\",\"protocol_version\":1,\"command_id\":\"%s\",\"ok\":true,\"payload\":{{\"status\":\"accepted\"}}}}",
		id,
	)
	accepted = bridge_ws_process_frame(&f.bh, f.bridge_id, generation, 0, &chunks, current)
	testing.expect(t, accepted)
	commands = extension_test_commands(t, f)
	defer domain.provider_extension_commands_destroy(commands)
	testing.expect_value(t, commands[0].state, "accepted")
	req = extension_test_request(f, fmt.tprintf("/api/v1/bridges/%s/provider-status", f.bridge_id))
	req.method = "GET"
	provider_status := bridge_provider_status_handler(rawptr(&f.ph), req)
	testing.expect_value(t, provider_status.status, 200)
	testing.expect(t, strings.contains(provider_status.body, "\"extension_commands\":[{"))
	testing.expect(
		t,
		strings.contains(provider_status.body, id),
		"provider status exposes resumable command tracking",
	)
}

@(test)
test_extension_update_disk_reopen_retains_consent_and_followup_identity :: proc(t: ^testing.T) {
	database_path := fmt.aprintf(
		"/tmp/heimdall-extension-%d-%d.db",
		os.get_pid(),
		time.now()._nsec,
	)
	defer delete(database_path)
	defer _ = os.remove(database_path)
	f := extension_test_setup(t, "disk-restart", database_path)
	defer extension_test_teardown(f)
	extension_test_status(t, f, "codex", "present", "outdated")
	id := extension_test_update(t, f, "{\"update_extensions\":true}")
	defer delete(id)
	frame := fmt.tprintf("{{\"command_id\":\"%s\",\"payload\":{{\"status\":\"succeeded\"}}}}", id)
	err := bridge_extension_frame(&f.bh, f.bridge_id, "command_result", frame)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, f.sink_rec.count, 1) // replaced below: completion must still await reconnect
	sqlite.close(&f.conn)
	reopened, ok, open_err := sqlite.open(database_path)
	testing.expect(t, ok)
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	f.conn = reopened
	// Repositories keep a pointer to f.conn, so this is a real database close/open,
	// with a fresh service projection using the recovered durable journal.
	f.pr_svc = provider_service.new_provider_service(&f.pr_repo)
	f.bh.providers = &f.pr_svc
	commands := extension_test_commands(t, f)
	testing.expect_value(t, len(commands), 1)
	testing.expect(t, commands[0].update_extensions)
	testing.expect_value(t, commands[0].state, "restarting")
	domain.provider_extension_commands_destroy(commands)
	extension_test_restart(t, f, id)
	discovery := strings.clone(f.sink_rec.last_cmd.command_id)
	defer delete(discovery)
	// A freshly measured version may still have been judged against a cached old
	// catalog. The Hub's current minimum also makes this installed version outdated.
	extension_test_report(
		t,
		f,
		discovery,
		"[{\"provider\":\"codex\",\"state\":\"present\",\"extension_state\":\"present\",\"extension_version\":\"0.1.0\"}]",
	)
	testing.expect_value(
		t,
		json_string(f.sink_rec.last_cmd.body_json, "type"),
		"provider_extension_install",
	)
	install_id := strings.clone(f.sink_rec.last_cmd.command_id)
	defer delete(install_id)
	count := f.sink_rec.count
	extension_test_report(
		t,
		f,
		discovery,
		"[{\"provider\":\"codex\",\"state\":\"present\",\"extension_state\":\"outdated\",\"extension_version\":\"0.1.0\"}]",
	)
	testing.expect_value(t, f.sink_rec.count, count)
	commands = extension_test_commands(t, f)
	defer domain.provider_extension_commands_destroy(commands)
	testing.expect_value(t, len(commands), 3)
	// The DB unique key is authoritative even if a new caller tries another id.
	duplicate := domain.Provider_Extension_Command {
		command_id = "different-id",
		bridge_id  = f.bridge_id,
		kind       = "install",
		provider   = "codex",
		parent_id  = id,
		state      = "queued",
	}
	created, create_err := iface.provider_extension_command_create(&f.pr_repo, duplicate)
	testing.expect_value(t, create_err.code, domain.Error_Code.None)
	testing.expect(t, !created)
}

@(test)
test_extension_auto_install_excludes_disabled_absent_error_and_unmeasured :: proc(t: ^testing.T) {
	for state in ([5]string{"disabled", "absent", "error", "unsupported", ""}) {
		f := extension_test_setup(t, "ineligible")
		extension_test_status(t, f, "codex", "present", "outdated")
		id := extension_test_update(t, f, "{\"update_extensions\":true}")
		extension_test_restart(t, f, id)
		discovery := strings.clone(f.sink_rec.last_cmd.command_id)
		report := fmt.tprintf(
			"[{{\"provider\":\"codex\",\"state\":\"present\",\"extension_state\":\"%s\",\"extension_version\":\"0.1.0\"}}]",
			state,
		)
		extension_test_report(t, f, discovery, report)
		testing.expect_value(
			t,
			json_string(f.sink_rec.last_cmd.body_json, "type"),
			"provider_discover",
		)
		delete(id); delete(discovery)
		extension_test_teardown(f)
	}
}


@(test)
test_extension_update_reconnect_recovers_lost_restart_progress :: proc(t: ^testing.T) {
	f := extension_test_setup(t, "lost-progress")
	defer extension_test_teardown(f)
	id := extension_test_update(t, f, "{\"update_extensions\":true}")
	defer delete(id)
	bridge, _, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	defer domain.bridge_destroy(&bridge)
	// An ordinary reconnect with the original build must do nothing.
	err := bridge_extension_reconnected(&f.bh, bridge)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, f.sink_rec.count, 1)
	delete(bridge.version); bridge.version = strings.clone("0.2.0")
	delete(bridge.commit_sha); bridge.commit_sha = strings.clone("new")
	err = bridge_extension_reconnected(&f.bh, bridge)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(
		t,
		json_string(f.sink_rec.last_cmd.body_json, "type"),
		"provider_discover",
	)
}

@(test)
test_extension_manual_auto_overlap_waits_and_rechecks_durably :: proc(t: ^testing.T) {
	for outcome in ([2]string{"succeeded", "failed"}) {
		database_path := fmt.aprintf("/tmp/heimdall-overlap-%d-%d.db", os.get_pid(), time.now()._nsec)
		f := extension_test_setup(t, "overlap", database_path)
		extension_test_status(t, f, "codex", "present", "outdated")
		update_id := extension_test_update(t, f, "{\"update_extensions\":true}")
		extension_test_restart(t, f, update_id)
		discovery_id := strings.clone(f.sink_rec.last_cmd.command_id)
		path := fmt.tprintf("/api/v1/bridges/%s/providers/codex/extension-install", f.bridge_id)
		response := bridge_provider_extension_install_handler(rawptr(&f.ph), extension_test_request(f, path))
		testing.expect_value(t, response.status, 202)
		manual_id := json_string(response.body, "command_id")
		before := f.sink_rec.count
		outdated := "[{\"provider\":\"codex\",\"state\":\"present\",\"extension_state\":\"outdated\",\"extension_version\":\"0.1.0\"}]"
		extension_test_report(t, f, discovery_id, outdated)
		extension_test_report(t, f, discovery_id, outdated)
		testing.expect_value(t, f.sink_rec.count, before)
		commands := extension_test_commands(t, f)
		active, waiting := 0, 0
		for command in commands {
			if command.kind == "install" && !extension_command_terminal(command.state) do active += 1
			if command.kind == "discovery" && command.state == "waiting" do waiting += 1
		}
		testing.expect_value(t, active, 1)
		testing.expect_value(t, waiting, 1)
		domain.provider_extension_commands_destroy(commands)
		status := bridge_provider_status_handler(rawptr(&f.ph), extension_test_request(f, fmt.tprintf("/api/v1/bridges/%s/provider-status", f.bridge_id)))
		testing.expect(t, strings.contains(status.body, manual_id), "active manual command remains visible")
		// Close the actual SQLite database and rebuild the service projection.
		sqlite.close(&f.conn)
		reopened, ok, open_err := sqlite.open(database_path)
		testing.expect(t, ok)
		testing.expect_value(t, open_err.code, domain.Error_Code.None)
		f.conn = reopened
		f.pr_svc = provider_service.new_provider_service(&f.pr_repo)
		bridge, _, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
		err := bridge_extension_reconnected(&f.bh, bridge)
		domain.bridge_destroy(&bridge)
		testing.expect_value(t, err.code, domain.Error_Code.None)
		testing.expect_value(t, f.sink_rec.count, before + 1) // only manual replay
		testing.expect_value(t, f.sink_rec.last_cmd.command_id, manual_id)
		terminal := fmt.tprintf("{{\"command_id\":\"%s\",\"status\":\"%s\"}}", manual_id, outcome)
		err = bridge_extension_frame(&f.bh, f.bridge_id, "command_result", terminal)
		testing.expect_value(t, err.code, domain.Error_Code.None)
		testing.expect_value(t, json_string(f.sink_rec.last_cmd.body_json, "type"), "provider_discover")
		recheck_id := strings.clone(f.sink_rec.last_cmd.command_id)
		testing.expect(t, recheck_id != discovery_id)
		count := f.sink_rec.count
		_ = bridge_extension_frame(&f.bh, f.bridge_id, "command_result", terminal)
		testing.expect_value(t, f.sink_rec.count, count)
		fresh := outdated
		if outcome == "succeeded" do fresh = "[{\"provider\":\"codex\",\"state\":\"present\",\"extension_state\":\"present\",\"extension_version\":\"0.4.31\"}]"
		extension_test_report(t, f, recheck_id, fresh)
		if outcome == "succeeded" {
			testing.expect_value(t, f.sink_rec.count, count)
		} else {
			testing.expect_value(t, f.sink_rec.count, count + 1)
			testing.expect_value(t, json_string(f.sink_rec.last_cmd.body_json, "type"), "provider_extension_install")
		}
		count = f.sink_rec.count
		extension_test_report(t, f, recheck_id, fresh)
		extension_test_report(t, f, discovery_id, outdated)
		_ = bridge_extension_frame(&f.bh, f.bridge_id, "command_result", terminal)
		testing.expect_value(t, f.sink_rec.count, count)
		commands = extension_test_commands(t, f)
		active = 0
		for command in commands {
			if command.kind == "install" && !extension_command_terminal(command.state) do active += 1
		}
		testing.expect_value(t, active, 0 if outcome == "succeeded" else 1)
		domain.provider_extension_commands_destroy(commands)
		delete(update_id); delete(discovery_id); delete(manual_id); delete(recheck_id)
		extension_test_teardown(f)
		_ = os.remove(database_path)
		delete(database_path)
	}
}

@(test)
test_extension_overlap_rechecks_late_reports_and_repeated_manual_installs :: proc(t: ^testing.T) {
	f := extension_test_setup(t, "late-overlap")
	defer extension_test_teardown(f)
	extension_test_status(t, f, "codex", "present", "outdated")
	update_id := extension_test_update(t, f, "{\"update_extensions\":true}")
	defer delete(update_id)
	extension_test_restart(t, f, update_id)
	discovery_id := strings.clone(f.sink_rec.last_cmd.command_id)
	defer delete(discovery_id)
	path := fmt.tprintf("/api/v1/bridges/%s/providers/codex/extension-install", f.bridge_id)
	response := bridge_provider_extension_install_handler(rawptr(&f.ph), extension_test_request(f, path))
	testing.expect_value(t, response.status, 202)
	manual_id := json_string(response.body, "command_id")
	defer delete(manual_id)
	// The initial probe was requested before the manual install; its delayed
	// report remains stale even after that install has finished.
	err := bridge_extension_frame(&f.bh, f.bridge_id, "command_result", fmt.tprintf("{{\"command_id\":\"%s\",\"status\":\"succeeded\"}}", manual_id))
	testing.expect_value(t, err.code, domain.Error_Code.None)
	outdated := "[{\"provider\":\"codex\",\"state\":\"present\",\"extension_state\":\"outdated\",\"extension_version\":\"0.1.0\"}]"
	extension_test_report(t, f, discovery_id, outdated)
	testing.expect_value(t, json_string(f.sink_rec.last_cmd.body_json, "type"), "provider_discover")
	recheck_id := strings.clone(f.sink_rec.last_cmd.command_id)
	defer delete(recheck_id)
	// A second manual action can overlap the recheck as well.
	response = bridge_provider_extension_install_handler(rawptr(&f.ph), extension_test_request(f, path))
	testing.expect_value(t, response.status, 202)
	second_id := json_string(response.body, "command_id")
	defer delete(second_id)
	count := f.sink_rec.count
	extension_test_report(t, f, recheck_id, outdated)
	testing.expect_value(t, f.sink_rec.count, count)
	// Persist completion while transport dispatch fails, then recover on reconnect.
	f.sink_rec.fail = true
	err = bridge_extension_frame(&f.bh, f.bridge_id, "command_result", fmt.tprintf("{{\"command_id\":\"%s\",\"status\":\"failed\"}}", second_id))
	testing.expect(t, err.code != .None)
	f.sink_rec.fail = false
	bridge, _, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	defer domain.bridge_destroy(&bridge)
	err = bridge_extension_reconnected(&f.bh, bridge)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, f.sink_rec.count, count + 1)
	testing.expect_value(t, json_string(f.sink_rec.last_cmd.body_json, "type"), "provider_discover")
	final_recheck := strings.clone(f.sink_rec.last_cmd.command_id)
	defer delete(final_recheck)
	testing.expect(t, final_recheck != recheck_id)
	// Fresh status, rather than the failed outcome, decides whether to install.
	extension_test_report(t, f, final_recheck, "[{\"provider\":\"codex\",\"state\":\"present\",\"extension_state\":\"present\",\"extension_version\":\"0.4.31\"}]")
	testing.expect_value(t, f.sink_rec.count, count + 1)
	commands := extension_test_commands(t, f)
	defer domain.provider_extension_commands_destroy(commands)
	installs := 0
	for command in commands {if command.kind == "install" do installs += 1}
	testing.expect_value(t, installs, 2) // exactly the two explicit manual requests
}
