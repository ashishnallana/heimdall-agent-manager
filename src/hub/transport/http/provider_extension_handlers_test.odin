package http

import "base:runtime"
import "core:net"
import "core:thread"
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
	fixed_now:string,
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
	fixed_now:string = "",
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
	if fixed_now!="" {f.fixed_now=fixed_now;f.clock=platform.Clock{ctx=rawptr(&f.fixed_now),now=profile_test_fixed_now}}
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
// The state of one command (temp-allocated; "" when it does not exist).
extension_test_state :: proc(t: ^testing.T, f: ^extension_handler_fixture, command_id: string) -> string {
	commands := extension_test_commands(t, f)
	defer domain.provider_extension_commands_destroy(commands)
	for command in commands {
		if command.command_id == command_id do return strings.clone(command.state, context.temp_allocator)
	}
	return ""
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
	extension_test_status(t, f, "codex", "present", "outdated")
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
	testing.expect(t, strings.has_prefix(id, "cmd_"), id)
	testing.expect_value(t, json_string(f.sink_rec.last_cmd.body_json, "command_id"), id)
	dispatched := f.sink_rec.count
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
	extension_test_status(t, f, "codex", "present", "outdated")
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
	testing.expect_value(t, extension_test_state(t, f, id), "dispatched")
	// Current generation processes the nested production envelope.
	current := fmt.aprintf(
		"{{\"type\":\"command_result\",\"protocol_version\":1,\"command_id\":\"%s\",\"ok\":true,\"payload\":{{\"status\":\"accepted\"}}}}",
		id,
	)
	accepted = bridge_ws_process_frame(&f.bh, f.bridge_id, generation, 0, &chunks, current)
	testing.expect(t, accepted)
	testing.expect_value(t, extension_test_state(t, f, id), "accepted")
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
test_provider_models_api_filter_empty_and_additive_metadata :: proc(t: ^testing.T) {
	context.allocator=context.temp_allocator
	f := extension_test_setup(t,"model_filter")
	defer extension_test_teardown(f)
	extension_test_status(t,f,"codex","present","present",false)
	extension_test_status(t,f,"claude","absent","absent",true)
	response := bridge_provider_discover_handler(rawptr(&f.ph),extension_test_request(f,fmt.tprintf("/api/v1/bridges/%s/providers/discover",f.bridge_id),`{"stage":"models","providers":["codex","claude"],"enabled":true}`))
	testing.expect_value(t,response.status,200)
	testing.expect_value(t,f.sink_rec.count,0)
	saved,err := iface.bridge_provider_models_list(&f.pr_repo,f.bridge_id)
	testing.expect_value(t,err.code,domain.Error_Code.None)
	testing.expect_value(t,len(saved),0)
	domain.bridge_provider_models_list_destroy(saved)
	views,_ := provider_service.list_bridge_providers(&f.pr_svc,f.bridge_id)
	defer provider_service.bridge_provider_views_destroy(views)
	eligible := provider_service.model_discovery_providers(views[:])
	testing.expect_value(t,len(eligible),0)
	for &view in views {
		if view.catalog.provider=="codex" do view.enabled=true
		if view.catalog.provider=="claude" do view.enabled=true // still absent
	}
	eligible=provider_service.model_discovery_providers(views[:])
	testing.expect_value(t,len(eligible),1)
	if len(eligible)==1 do testing.expect_value(t,eligible[0],"codex")
	for view in views do if view.catalog.provider=="codex" {
		b:=strings.builder_make()
		write_bridge_provider_view_json(&b,view)
		text:=strings.to_string(b)
		testing.expect(t,strings.contains(text,`"models_source":"static_fallback"`))
		testing.expect(t,strings.contains(text,`"models_state":"not_checked"`))
		testing.expect(t,strings.contains(text,`"models_has_snapshot":false`))
	}
	response=bridge_provider_discover_handler(rawptr(&f.ph),extension_test_request(f,fmt.tprintf("/api/v1/bridges/%s/providers/discover",f.bridge_id),`{"stage":"automatic"}`))
	testing.expect_value(t,response.status,400)
}

@(test)
test_provider_models_reply_correlation_presence_and_failure :: proc(t: ^testing.T) {
	context.allocator=context.temp_allocator
	f:=extension_test_setup(t,"model_reply")
	defer extension_test_teardown(f)
	allowed:=[]string{"codex"}
	prefix:=`{"type":"provider_model_discovery_report","request_id":"model-1","command_id":"model-1","providers":[`
	item:=`{"provider":"codex","binary_path":"/bin/codex","version_text":"v1","has_snapshot":true,"models_source":"codex_app_server","models_state":"success","models_checked_at":"2026-10-01T00:00:00Z","models_attempted_at":"2026-10-01T00:00:00Z","models":[{"model_id":"new-model","label":"New"}]}`
	reply:=strings.concatenate({prefix,item,"]}"})
	testing.expect_value(t,provider_models_apply_reply(&f.pr_svc,f.bridge_id,"wrong-request",allowed,reply,"now").code,domain.Error_Code.Validation_Failed)
	testing.expect_value(t,provider_models_apply_reply(&f.pr_svc,f.bridge_id,"model-1",allowed,reply,"now").code,domain.Error_Code.None)
	// Extension reconciliation may receive ordinary detection reports. They must
	// preserve the independent model fields without running any model probes.
	command:=domain.Provider_Extension_Command{command_id="ordinary-detection",bridge_id=f.bridge_id,kind="install",state="dispatched"}
	testing.expect_value(t,extension_apply_report(&f.bh,&command,`{"request_id":"ordinary-detection","providers":[{"provider":"codex","state":"present","checked_at":"2026-10-02","extension_state":"error"}]}`).code,domain.Error_Code.None)
	omitted:=strings.concatenate({prefix,`{"provider":"codex","has_snapshot":true,"models_source":"codex_app_server","models_state":"success","models_checked_at":"2026-10-02","models_attempted_at":"2026-10-02"}`,"]}"})
	testing.expect_value(t,provider_models_apply_reply(&f.pr_svc,f.bridge_id,"model-1",allowed,omitted,"now").code,domain.Error_Code.Validation_Failed)
	failed:=strings.concatenate({`{"type":"command_result","command_id":"model-1","error":`,contracts.wire_error_json(contracts.wire_error(.Validation_Failed,"unknown_command"),context.temp_allocator),"}"})
	testing.expect_value(t,provider_models_apply_reply(&f.pr_svc,f.bridge_id,"model-1",allowed,failed,"2026-10-03T00:00:00Z").code,domain.Error_Code.None)
	views,_:=provider_service.list_bridge_providers(&f.pr_svc,f.bridge_id)
	defer provider_service.bridge_provider_views_destroy(views)
	for view in views do if view.catalog.provider=="codex" {
		testing.expect_value(t,view.models_state,"unsupported")
		testing.expect_value(t,view.models_checked_at,"2026-10-01T00:00:00Z")
		testing.expect_value(t,len(view.catalog.models),1)
		if len(view.catalog.models)==1 do testing.expect_value(t,view.catalog.models[0].model_id,"new-model")
	}
	testing.expect_value(t,f.sink_rec.count,0)
}

@(private="file")
Model_API_Job :: struct { fixture:^extension_handler_fixture, status:int, body:string }
@(private="file")
model_api_test_worker :: proc(th:^thread.Thread) {
	context.allocator=context.temp_allocator
	job:=(^Model_API_Job)(th.data)
	req:=extension_test_request(job.fixture,fmt.tprintf("/api/v1/bridges/%s/providers/discover",job.fixture.bridge_id),`{"stage":"models","providers":["claude","pi"],"enabled":true}`)
	response:=bridge_provider_discover_handler(rawptr(&job.fixture.ph),req)
	job.status=response.status
	job.body=strings.clone(response.body,runtime.default_allocator())
	free_all(context.temp_allocator)
}
@(test)
test_provider_models_existing_api_runtime_round_trip :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	f:=extension_test_setup(t,"model_api_roundtrip")
	defer extension_test_teardown(f)
	extension_test_status(t,f,"codex","present","present",true)
	extension_test_status(t,f,"claude","present","present",false)
	extension_test_status(t,f,"pi","absent","unsupported",true)
	listener,listen_err:=net.listen_tcp(net.Endpoint{address=net.IP4_Loopback,port=0})
	if !testing.expect(t,listen_err==nil) do return
	defer net.close(listener)
	endpoint,_:=net.bound_endpoint(listener)
	client,dial_err:=net.dial_tcp(net.Endpoint{address=net.IP4_Loopback,port=endpoint.port})
	if !testing.expect(t,dial_err==nil) do return
	defer net.close(client)
	hub,_,accept_err:=net.accept_tcp(listener)
	if !testing.expect(t,accept_err==nil) do return
	defer net.close(hub)
	generation:=project_service.bridge_runtime_registry_generation(&f.registry,f.bridge_id)
	project_service.bridge_runtime_registry_set_command_socket(&f.registry,f.bridge_id,hub,generation)
	defer project_service.bridge_runtime_registry_mark_offline(&f.registry,f.bridge_id,generation)
	job:=Model_API_Job{fixture=f}
	worker:=thread.create(model_api_test_worker)
	worker.data=rawptr(&job)
	thread.start(worker)
	reader:=bridge_ws_reader_make(client)
	frame,received,_:=bridge_ws_read_frame(&reader,5*time.Second)
	bridge_ws_reader_destroy(&reader)
	if testing.expect(t,received,"explicit stage two sends a runtime request") {
		testing.expect_value(t,json_string(frame,"type"),"provider_models_discover")
		names:=json_string_array(frame,"providers")
		testing.expect_value(t,len(names),1)
		if len(names)==1 do testing.expect_value(t,names[0],"codex")
		request_id:=json_string(frame,"request_id")
		reply:=fmt.tprintf(`{{"type":"provider_model_discovery_report","request_id":"%s","command_id":"%s","providers":[{{"provider":"codex","has_snapshot":true,"models_source":"codex_app_server","models_state":"success","models_checked_at":"2026-10-01T00:00:00Z","models_attempted_at":"2026-10-01T00:00:00Z","models":[{{"model_id":"api-new-model","label":"New"}}]}}]}}`,request_id,request_id)
		testing.expect(t,bridge_runtime_service.runtime_command_result_for_connection(&f.registry,f.bridge_id,generation,request_id,reply))
	} else {
		project_service.bridge_runtime_registry_mark_offline(&f.registry,f.bridge_id,generation)
	}
	thread.join(worker);thread.destroy(worker)
	defer delete(job.body,runtime.default_allocator())
	testing.expect_value(t,job.status,200)
	testing.expect(t,strings.contains(job.body,`"model_id":"api-new-model"`),"existing provider response includes discovered models")
	testing.expect(t,strings.contains(job.body,`"models_source":"codex_app_server"`))
	testing.expect_value(t,provider_models_failure_state(.Bridge_Timeout,""),"timeout")
	testing.expect_value(t,provider_models_failure_state(.Validation_Failed,"unknown_command"),"unsupported")
	testing.expect_value(t,provider_models_failure_state(.Validation_Failed,"bridge_busy"),"busy")
}

// Uninstall is the same per-provider action as install: one at a time, the same
// frame with action=uninstall, tracked at .../extension-uninstall/:id.
@(test)
test_extension_uninstall_endpoint_dispatch_and_tracking :: proc(t: ^testing.T) {
	f := extension_test_setup(t, "uninstall")
	defer extension_test_teardown(f)
	extension_test_status(t, f, "codex", "present", "present")
	path := fmt.tprintf("/api/v1/bridges/%s/providers/codex/extension-uninstall", f.bridge_id)
	response := bridge_provider_extension_uninstall_handler(rawptr(&f.ph), extension_test_request(f, path))
	testing.expectf(t, response.status == 202, "expected 202, got %d: %s", response.status, response.body)
	id := json_string(response.body, "command_id")
	defer delete(id)
	testing.expect_value(t, json_string(response.body, "kind"), "uninstall")
	testing.expect_value(t, json_string(f.sink_rec.last_cmd.body_json, "type"), "provider_extension_install")
	testing.expect_value(t, json_string(f.sink_rec.last_cmd.body_json, "action"), "uninstall")
	testing.expect_value(t, json_string(f.sink_rec.last_cmd.body_json, "provider"), "codex")
	// An install cannot start while the uninstall runs.
	install := bridge_provider_extension_install_handler(rawptr(&f.ph), extension_test_request(f, fmt.tprintf("/api/v1/bridges/%s/providers/codex/extension-install", f.bridge_id)))
	testing.expect_value(t, install.status, 409)
	testing.expect_value(t, f.sink_rec.count, 1)
	err := bridge_extension_frame(&f.bh, f.bridge_id, "provider_extension_install_progress",
		fmt.tprintf("{{\"command_id\":\"%s\",\"stage\":\"uninstalling\",\"progress_percent\":20}}", id))
	testing.expect_value(t, err.code, domain.Error_Code.None)
	poll := extension_test_request(f, fmt.tprintf("%s/%s", path, id))
	poll.method = "GET"
	tracking := bridge_provider_extension_command_handler(rawptr(&f.ph), poll)
	testing.expect_value(t, tracking.status, 200)
	testing.expect(t, strings.contains(tracking.body, "\"status\":\"uninstalling\""), tracking.body)
	// The install path never finds an uninstall command.
	wrong := extension_test_request(f, fmt.tprintf("/api/v1/bridges/%s/providers/codex/extension-install/%s", f.bridge_id, id))
	wrong.method = "GET"
	testing.expect_value(t, bridge_provider_extension_command_handler(rawptr(&f.ph), wrong).status, 404)
	extension_test_report(t, f, id, "[{\"provider\":\"codex\",\"state\":\"present\",\"extension_state\":\"absent\"}]")
	err = bridge_extension_frame(&f.bh, f.bridge_id, "command_result", fmt.tprintf("{{\"command_id\":\"%s\",\"status\":\"succeeded\"}}", id))
	testing.expect_value(t, err.code, domain.Error_Code.None)
	tracking = bridge_provider_extension_command_handler(rawptr(&f.ph), poll)
	testing.expect(t, strings.contains(tracking.body, "\"status\":\"succeeded\""), tracking.body)
	statuses, _ := iface.bridge_provider_status_list(&f.pr_repo, f.bridge_id)
	defer domain.bridge_provider_statuses_destroy(statuses)
	for s in statuses do if s.provider == "codex" do testing.expect_value(t, s.extension_state, "absent")
}

// Profile transport tests share the real owner/auth/runtime fixture above.
@(private="file")
Profile_API_Job :: struct { fixture:^extension_handler_fixture, path,method,body:string, status:int, result:string }
@(private="file")
profile_api_test_worker :: proc(th:^thread.Thread) {
 context.allocator=context.temp_allocator
 job:=(^Profile_API_Job)(th.data)
 req:=extension_test_request(job.fixture,job.path,job.body);req.method=job.method
 response:=bridge_provider_profiles_handler(rawptr(&job.fixture.ph),req)
 job.status=response.status
 job.result=strings.clone(response.body,runtime.default_allocator())
 free_all(context.temp_allocator)
}
@(test)
test_profiles_opaque_relay_round_trip_all_operations :: proc(t:^testing.T) {
 context.allocator=context.temp_allocator
 f:=extension_test_setup(t,"profiles_relay",fixed_now="2026-10-30T12:00:00Z")
 defer extension_test_teardown(f)
 defer project_service.bridge_runtime_registry_destroy(&f.registry)
 listener,listen_err:=net.listen_tcp(net.Endpoint{address=net.IP4_Loopback,port=0})
 if !testing.expect(t,listen_err==nil) do return
 defer net.close(listener)
 endpoint,_:=net.bound_endpoint(listener)
 client,dial_err:=net.dial_tcp(net.Endpoint{address=net.IP4_Loopback,port=endpoint.port})
 if !testing.expect(t,dial_err==nil) do return
 defer net.close(client)
 hub,_,accept_err:=net.accept_tcp(listener)
 if !testing.expect(t,accept_err==nil) do return
 defer net.close(hub)
 generation:=project_service.bridge_runtime_registry_generation(&f.registry,f.bridge_id)
 project_service.bridge_runtime_registry_set_command_socket(&f.registry,f.bridge_id,hub,generation)
 defer project_service.bridge_runtime_registry_mark_offline(&f.registry,f.bridge_id,generation)
 sealed:="vault:v2:opaque:e7:UNCHANGED+/=ciphertext"
 for route in ([]struct{method,suffix,op:string}{{"PUT","","upsert"},{"DELETE","","remove"},{"POST","/reset","reset"},{"POST","/get","get"}}) {
  job:=Profile_API_Job{fixture=f,path=fmt.tprintf("/api/v1/bridges/%s/provider-profiles/claude_one%s",f.bridge_id,route.suffix),method=route.method,body=fmt.tprintf("{{\"sealed\":\"%s\"}}",sealed)}
  worker:=thread.create(profile_api_test_worker);worker.data=rawptr(&job);thread.start(worker)
  reader:=bridge_ws_reader_make(client)
  frame,received,_:=bridge_ws_read_frame(&reader,5*time.Second);bridge_ws_reader_destroy(&reader)
  if testing.expect(t,received,"relay dispatched opaque operation") {
   testing.expect_value(t,json_string(frame,"type"),"provider_profile_op")
   testing.expect_value(t,json_string(frame,"sealed"),sealed)
   testing.expect_value(t,json_string(frame,"op"),route.op)
   testing.expect_value(t,json_string(frame,"profile_id"),"claude_one")
   id:=json_string(frame,"command_id")
   reply:=fmt.tprintf("{{\"type\":\"provider_profile_op_result\",\"command_id\":\"%s\",\"ok\":true,\"error\":\"\",\"sealed\":\"vault:v2:opaque:e7:redacted-response\"}}",id)
   testing.expect(t,bridge_runtime_service.runtime_command_result_for_connection(&f.registry,f.bridge_id,generation,id,reply))
  } else {project_service.bridge_runtime_registry_mark_offline(&f.registry,f.bridge_id,generation)}
  thread.join(worker);thread.destroy(worker)
  testing.expect_value(t,job.status,200)
  testing.expect(t,strings.contains(job.result,"vault:v2:opaque:e7:redacted-response"))
  delete(job.result,runtime.default_allocator())
 }
}
@(test)
test_profiles_report_allowlist_authoritative_missing_and_in_use :: proc(t:^testing.T) {
 context.allocator=context.temp_allocator
 f:=extension_test_setup(t,"profiles_report",fixed_now="2026-10-30T12:00:00Z")
 defer extension_test_teardown(f)
 defer project_service.bridge_runtime_registry_destroy(&f.registry)
 frame:="{\"type\":\"provider_profiles_report\",\"ok\":true,\"profiles\":[{\"profile_id\":\"claude_one\",\"provider\":\"claude\",\"enabled\":true,\"state\":\"ok\",\"env_count\":1,\"binary_path\":\"NEVER_STORE_PRIVATE_PATH\",\"environment\":[{\"name\":\"NEVER_STORE_ENV_NAME\",\"value\":\"NEVER_STORE_SECRET\"}],\"launch_args\":\"NEVER_STORE_ARGS\"}]}"
 testing.expect_value(t,bridge_provider_profiles_frame(&f.bh,f.bridge_id,frame).code,domain.Error_Code.None)
 req:=extension_test_request(f,fmt.tprintf("/api/v1/bridges/%s/provider-profiles",f.bridge_id));req.method="GET"
 response:=bridge_provider_profiles_handler(rawptr(&f.ph),req)
 testing.expect_value(t,response.status,200)
 testing.expect(t,strings.contains(response.body,"claude_one"))
 testing.expect(t,!strings.contains(response.body,"NEVER_STORE"))
 profiles,_:=f.pr_repo.list_profiles(f.pr_repo.ctx,f.bridge_id)
 found:=false
 for p in profiles do if p.profile_id=="claude_one" do found=p.env_count==1
 testing.expect(t,found)
 _,saved,err:=iface.agent_save_instance(&f.ag_repo,domain.Agent_Instance{agent_instance_id="profile-live",owner_user_id=domain.User_ID(f.owner_user_id),agent_id="agent",bridge_id=f.bridge_id,provider="claude",provider_profile="claude_one",model="model",runtime_status="running"})
 testing.expect(t,saved,err.message)
 remove:=extension_test_request(f,fmt.tprintf("/api/v1/bridges/%s/provider-profiles/claude_one",f.bridge_id),"{\"sealed\":\"vault:v2:opaque:e1:test\"}");remove.method="DELETE"
 denied:=bridge_provider_profiles_handler(rawptr(&f.ph),remove)
 testing.expect_value(t,denied.status,409)
 testing.expect(t,strings.contains(denied.body,"profile_in_use") && strings.contains(denied.body,"profile-live"))
 testing.expect_value(t,bridge_provider_profiles_frame(&f.bh,f.bridge_id,"{\"ok\":false,\"profiles\":[]}").code,domain.Error_Code.Validation_Failed)
 profiles,_=f.pr_repo.list_profiles(f.pr_repo.ctx,f.bridge_id)
 for p in profiles do if p.profile_id=="claude_one" do testing.expect_value(t,p.state,"ok")
 testing.expect_value(t,bridge_provider_profiles_frame(&f.bh,f.bridge_id,"{\"ok\":true,\"profiles\":[]}").code,domain.Error_Code.None)
 profiles,_=f.pr_repo.list_profiles(f.pr_repo.ctx,f.bridge_id)
 found=false
 for p in profiles do if p.profile_id=="claude_one" do found=p.state=="missing"
 testing.expect(t,found)
}
@(test)
test_profiles_relay_auth_private_plaintext_and_offline_refused :: proc(t:^testing.T) {
 context.allocator=context.temp_allocator
 f:=extension_test_setup(t,"profiles_relay_boundary",fixed_now="2026-10-30T12:00:00Z")
 defer extension_test_teardown(f)
 defer project_service.bridge_runtime_registry_destroy(&f.registry)
 req:=extension_test_request(f,fmt.tprintf("/api/v1/bridges/%s/provider-profiles/claude_one",f.bridge_id),"{\"sealed\":\"vault:v2:opaque:e1:test\",\"environment\":{\"TOKEN\":\"private\"}}");req.method="PUT"
 result:=bridge_provider_profiles_handler(rawptr(&f.ph),req)
 testing.expect_value(t,result.status,400)
 req.headers=nil
 result=bridge_provider_profiles_handler(rawptr(&f.ph),req)
 testing.expect_value(t,result.status,401)
 req.headers=f.user_headers;req.body="{\"sealed\":\"vault:v2:opaque:e1:test\"}"
 generation:=project_service.bridge_runtime_registry_generation(&f.registry,f.bridge_id)
 project_service.bridge_runtime_registry_mark_offline(&f.registry,f.bridge_id,generation)
 result=bridge_provider_profiles_handler(rawptr(&f.ph),req)
 testing.expect_value(t,result.status,409)
}

@(private="file")
profile_test_fixed_now :: proc(ctx:rawptr) -> string {
 return strings.clone((^string)(ctx)^)
}

@(test)
test_profiles_extension_actions_and_update_reports_cannot_cross_accounts :: proc(t:^testing.T) {
 context.allocator=context.temp_allocator
 f:=extension_test_setup(t,"profiles_extension_scope",fixed_now="2026-10-30T12:00:00Z")
 defer extension_test_teardown(f)
 defer project_service.bridge_runtime_registry_destroy(&f.registry)
 testing.expect_value(t,provider_service.apply_profiles_report(&f.pr_svc,f.bridge_id,[]domain.Bridge_Provider_Profile{{profile_id="claude_one",provider="claude",enabled=true,state="ok"},{profile_id="claude_two",provider="claude",enabled=true,state="ok"}}).code,domain.Error_Code.None)
 for id in ([]string{"claude_one","claude_two"}) {
  testing.expect_value(t,provider_service.apply_discovery_report(&f.pr_svc,f.bridge_id,[]domain.Bridge_Provider_Status{{bridge_id=f.bridge_id,provider="claude",profile_id=id,state="present",extension_state="outdated",extension_version="0.0.0"}}).code,domain.Error_Code.None)
  body:=fmt.tprintf("{{\"profile_id\":\"%s\"}}",id)
  req:=extension_test_request(f,fmt.tprintf("/api/v1/bridges/%s/providers/claude/extension-install",f.bridge_id),body)
  response:=bridge_provider_extension_install_handler(rawptr(&f.ph),req)
  testing.expect_value(t,response.status,202)
  testing.expect_value(t,json_string(f.sink_rec.last_cmd.body_json,"profile_id"),id)
 }
 testing.expect_value(t,f.sink_rec.count,2)
 // A default-account report cannot schedule an install into either custom
 // account, even though both have cached outdated extension observations.
 command:=domain.Provider_Extension_Command{command_id="cmd_ext_profiles_scan",bridge_id=f.bridge_id,kind="discovery",parent_id="profile-update",state="dispatched"}
 report:="{\"request_id\":\"cmd_ext_profiles_scan\",\"providers\":[{\"provider\":\"claude\",\"profile_id\":\"claude\",\"state\":\"present\",\"extension_state\":\"outdated\",\"extension_version\":\"0.0.0\"}]}"
 testing.expect_value(t,extension_apply_report(&f.bh,&command,report).code,domain.Error_Code.None)
 testing.expect_value(t,f.sink_rec.count,2)
 commands,_:=iface.provider_extension_command_list(&f.pr_repo,f.bridge_id)
 for c in commands do testing.expect(t,c.parent_id!="profile-update","default report must not queue custom-profile followups")
}
