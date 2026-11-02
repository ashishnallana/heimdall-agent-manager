package http

import "core:fmt"
import "core:os"
import "core:net"
import "core:thread"
import ws "odin_test:lib/ws"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import agent_service "odin_test:hub/service/agent"
import auth_service "odin_test:hub/service/auth"
import bridge_runtime_service "odin_test:hub/service/bridge_runtime"
import bridge_service "odin_test:hub/service/bridge"
import project_service "odin_test:hub/service/project"
import user_service "odin_test:hub/service/user"

@(private = "file")
update_test_counter: int = 0

// REQ-BUPD-2: Catalog resolution, semver comparison, and version metadata
@(test)
test_bridge_update_catalog_helpers :: proc(t: ^testing.T) {
	testing.expect_value(t, bridge_service.normalize_bridge_target("linux", "amd64"), "linux-amd64")
	testing.expect_value(t, bridge_service.normalize_bridge_target("Linux", "x86_64"), "linux-amd64")
	testing.expect_value(t, bridge_service.normalize_bridge_target("Darwin", "arm64"), "darwin-arm64")
	testing.expect_value(t, bridge_service.normalize_bridge_target("darwin", "aarch64"), "darwin-arm64")

	// Released v0.3.17 Bridges send canonical `target` but no separate os/arch
	// fields. The target repairs the combined enrollment display string stored in
	// machine_os and is authoritative when both forms are present.
	os_name, arch_name, target_ok := bridge_service.canonical_bridge_platform("", "", "linux-amd64")
	testing.expect(t, target_ok, "v0.3.17 target accepted")
	testing.expect_value(t, os_name, "linux")
	testing.expect_value(t, arch_name, "amd64")
	os_name, arch_name, target_ok = bridge_service.canonical_bridge_platform("Linux 6.18.49 amd64", "", "linux-amd64")
	testing.expect(t, target_ok, "canonical target overrides enrollment display string")
	testing.expect_value(t, os_name, "linux")
	testing.expect_value(t, arch_name, "amd64")
	_, _, target_ok = bridge_service.canonical_bridge_platform("", "", "plan9-mips")
	testing.expect(t, !target_ok, "unsupported target rejected")

	testing.expect_value(t, bridge_service.compare_semver("0.1.0", "0.2.0"), -1)
	testing.expect_value(t, bridge_service.compare_semver("0.2.0", "0.1.0"), 1)
	testing.expect_value(t, bridge_service.compare_semver("0.2.0", "0.2.0"), 0)
	testing.expect_value(t, bridge_service.compare_semver("v1.0.0", "1.0.0"), 0)
	testing.expect_value(t, bridge_service.compare_semver("0.1.9", "0.2.0"), -1)

	// Available when bridge version is older
	testing.expect(t, bridge_service.is_bridge_update_available("0.1.0", "c1", "0.2.0", "c2"), "older semver must report update available")
	// Not available when version and commit match
	testing.expect(t, !bridge_service.is_bridge_update_available("0.2.0", "c1", "0.2.0", "c1"), "identical version and commit must not report update available")
	// Available when version matches but commit differs
	testing.expect(t, bridge_service.is_bridge_update_available("0.2.0", "c1", "0.2.0", "c2"), "different commit with same version must report update available")
	// Available when bridge has no reported version
	testing.expect(t, bridge_service.is_bridge_update_available("", "", "0.2.0", "c2"), "empty bridge version must report update available")

	// Catalog resolution with overrides
	cat := bridge_service.Bridge_Update_Catalog{
		override_version = "0.2.5",
		override_commit_sha = "abcdef12",
		override_download_url = "/test/bundle.tar.gz",
		override_sha256 = "1234567890abcdef",
	}
	br := domain.Bridge{
		machine_os = "linux",
		machine_arch = "amd64",
		version = "0.1.0",
		commit_sha = "old_commit",
	}
	info := bridge_service.resolve_bridge_update_info(&cat, br)
	testing.expect(t, info.update_available, "catalog update available")
	testing.expect_value(t, info.latest_version, "0.2.5")
	testing.expect_value(t, info.latest_commit_sha, "abcdef12")
	testing.expect_value(t, info.download_url, "/test/bundle.tar.gz")
	testing.expect_value(t, info.sha256, "1234567890abcdef")
}

// REQ-BUPD-2: Manifest file reading from disk without use-after-free
@(test)
test_bridge_update_catalog_manifest_file_reading :: proc(t: ^testing.T) {
	manifest_path := fmt.tprintf("/tmp/test_manifest_%d_%d.json", os.get_pid(), time.now()._nsec)
	manifest_content := `{"version":"0.3.0","commit_sha":"manifest_sha_789","targets":{"linux-amd64":{"tarball_url":"/api/v1/updates/bundle/heimdall-local-linux-amd64.tar.gz","sha256":"hash789"}}}`
	write_err := os.write_entire_file(manifest_path, transmute([]byte)manifest_content)
	testing.expect(t, write_err == nil, "wrote test manifest")
	defer os.remove(manifest_path)

	cat := bridge_service.Bridge_Update_Catalog{
		manifest_path = manifest_path,
	}
	br := domain.Bridge{
		machine_os = "linux",
		machine_arch = "amd64",
		version = "0.1.0",
		commit_sha = "old_commit",
	}

	info := bridge_service.resolve_bridge_update_info(&cat, br)
	testing.expect(t, info.update_available, "update available from manifest")
	testing.expect_value(t, info.latest_version, "0.3.0")
	testing.expect_value(t, info.latest_commit_sha, "manifest_sha_789")
	testing.expect_value(t, info.sha256, "hash789")
	testing.expect_value(t, info.download_url, "/api/v1/updates/bundle/heimdall-local-linux-amd64.tar.gz")
}

// REQ-BUPD-2: write_bridge_json serializes update_available and latest_version
@(test)
test_write_bridge_json_update_available_output :: proc(t: ^testing.T) {
	cat := bridge_service.Bridge_Update_Catalog{
		override_version = "0.2.0",
		override_commit_sha = "796bfb57",
	}
	bridge := domain.Bridge{
		bridge_id = "brg_catalog_test",
		label = "Worker Beta",
		machine_hostname = "worker-02",
		machine_os = "linux",
		machine_arch = "amd64",
		hub_url = "http://127.0.0.1:8080",
		status = .Online,
		version = "0.1.0",
		commit_sha = "a57c83d9",
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	write_bridge_json(&b, bridge, nil, &cat)
	out := strings.to_string(b)

	testing.expect(t, strings.contains(out, "\"target\":\"linux-amd64\""), "target serialized")
	testing.expect(t, strings.contains(out, "\"update_available\":true"), "update_available:true serialized")
	testing.expect(t, strings.contains(out, "\"update_message\":\"\""), "update_message serialized")
	testing.expect(t, strings.contains(out, "\"update_progress\":0"), "update_progress serialized")
	testing.expect(t, strings.contains(out, "\"latest_version\":\"0.2.0\""), "latest_version serialized")
	testing.expect(t, strings.contains(out, "\"latest_source\":\"override\""), "catalog source serialized")
	testing.expect(t, strings.contains(out, "\"update_warning\":\"\""), "catalog warning serialized")
	testing.expect(t, strings.contains(out, "\"update_fallback_reason\":\"release source is not configured\""), "fallback reason serialized")
	testing.expect(t, strings.contains(out, "\"latest_commit_sha\":\"796bfb57\""), "latest_commit_sha serialized")
}

// REQ-BUPD-4: Bridge update dispatch over WebSocket command sink
@(private = "file")
Update_Sink_Recorder :: struct {
	sent: bool,
	last_cmd: project_service.Runtime_Command,
}

@(private = "file")
_test_update_sink_proc :: proc(ctx: rawptr, cmd: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	rec := (^Update_Sink_Recorder)(ctx)
	rec.sent = true
	rec.last_cmd = project_service.Runtime_Command{
		bridge_id = strings.clone(cmd.bridge_id),
		command_id = strings.clone(cmd.command_id),
		body_json = strings.clone(cmd.body_json),
	}
	return true, domain.Domain_Error{}
}

// Wire fixture for HTTP handler tests
@(private = "file")
update_handler_wire_fixture :: struct {
	db_path: string,
	conn: sqlite.Conn,
	br_impl: sqlite.Bridge_Repo_SQLite,
	us_impl: sqlite.User_Repo_SQLite,
	ag_impl: sqlite.Agent_Repo_SQLite,
	br_repo: iface.Bridge_Repository,
	us_repo: iface.User_Repository,
	ag_repo: iface.Agent_Repository,
	clock: platform.Clock,
	ids: platform.ID_Generator,
	br_svc: bridge_service.Bridge_Service,
	us_svc: user_service.User_Service,
	ag_svc: agent_service.Agent_Service,
	auth_svc: auth_service.Auth_Service,
	user_headers: []contracts.HTTP_Header, // session cookie for the fixture owner
	bh: Bridge_Handlers,
	registry: project_service.Bridge_Runtime_Registry,
	sink_rec: Update_Sink_Recorder,
	owner_user_id: string,
	bridge_id: string,
	bridge_token: string,
}


@(private = "file")
setup_update_test_fixture :: proc(t: ^testing.T, tag: string) -> ^update_handler_wire_fixture {
	f := new(update_handler_wire_fixture)
	seq := sync.atomic_add(&update_test_counter, 1)
	f.db_path = ":memory:"
	

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

	f.sink_rec = Update_Sink_Recorder{}
	sink := project_service.Bridge_Command_Sink{
		ctx = rawptr(&f.sink_rec),
		send_runtime_command = _test_update_sink_proc,
	}

	f.br_svc = bridge_service.new_bridge_service_with_runtime(&f.br_repo, sink, &f.clock, &f.ids)
	f.us_svc = user_service.new_user_service_basic(&f.us_repo, &f.clock, &f.ids)
	f.ag_svc = agent_service.new_agent_service(&f.ag_repo, &f.br_repo, &f.clock, &f.ids)

	f.auth_svc = auth_service.new_auth_service(auth_service.Auth_Config{auto_provision_users = true}, &f.us_svc)
	f.auth_svc.clock = &f.clock
	f.auth_svc.ids = &f.ids
	f.auth_svc.bridges = &f.br_svc
	f.auth_svc.agents = &f.ag_svc

	f.bh = Bridge_Handlers{
		auth = &f.auth_svc,
		bridges = &f.br_svc,
		agents = &f.ag_svc,
		bridge_runtime_registry = &f.registry,
	}

	f.user_headers = http_test_login(t, &f.auth_svc, "update_test_user")
	owner_ctx, owner_ok, _ := auth_service.resolve_auth_any(&f.auth_svc, auth_service.Auth_Request{
		remote_addr = "127.0.0.1:4444",
		headers = f.user_headers,
	})
	testing.expect(t, owner_ok, "session owner resolved")
	f.owner_user_id = strings.clone(owner_ctx.user_id)

	owner_auth := contracts.Auth_Context{kind = .Session, user_id = f.owner_user_id}
	// Provisioned through the DEVICE-GRANT path, the only enrollment there is
	// (REQ-ENROLL-9). This replaced a create_enrollment + enroll_bridge pair; the
	// bridge and its credential are what this fixture needs, and how the credential
	// was approved is not what these tests are about.
	enrolled, e_ok, _ := bridge_service.enroll_bridge_from_device_grant(&f.br_svc, bridge_service.Device_Enroll_Input{
		owner_user_id = f.owner_user_id,
		bridge_public_key = "04aabb",
		bridge_key_fingerprint = "aaaa bbbb cccc dddd",
		machine_hostname = "test-box",
	})
	testing.expect(t, e_ok, "bridge enrolled")
	f.bridge_id = strings.clone(enrolled.bridge.bridge_id)
	f.bridge_token = strings.clone(enrolled.bridge_token)

	return f
}

@(private = "file")
teardown_update_test_fixture :: proc(f: ^update_handler_wire_fixture) {
	if f == nil do return
	sqlite.close(&f.conn)
	
	delete(f.owner_user_id)
	delete(f.bridge_id)
	delete(f.bridge_token)
	if f.sink_rec.sent {
		delete(f.sink_rec.last_cmd.bridge_id)
		delete(f.sink_rec.last_cmd.command_id)
		delete(f.sink_rec.last_cmd.body_json)
	}
	free(f)
}

// REQ-BUPD-4: POST /api/v1/bridges/{id}/update unauthenticated returns 401
@(test)
test_bridge_update_handler_unauthenticated :: proc(t: ^testing.T) {
	f := setup_update_test_fixture(t, "unauth")
	defer teardown_update_test_fixture(f)

	req := Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/bridges/%s/update", f.bridge_id),
		body = `{"target_version":"0.2.0"}`,
		request_id = "req_unauth_upd",
		remote_addr = "192.168.1.1:1234", // Untrusted IP
	}
	resp := bridge_update_handler(rawptr(&f.bh), req)
	testing.expect_value(t, resp.status, 401)
}

// REQ-BUPD-4: POST /api/v1/bridges/{id}/update on offline bridge returns 422 Unprocessable Entity
@(test)
test_bridge_update_handler_offline_bridge_returns_422 :: proc(t: ^testing.T) {
	f := setup_update_test_fixture(t, "offline")
	defer teardown_update_test_fixture(f)

	req := Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/bridges/%s/update", f.bridge_id),
		body = `{"target_version":"0.2.0","force":false}`,
		request_id = "req_offline_upd",
		remote_addr = "127.0.0.1:4444",
		headers = f.user_headers,
	}
	resp := bridge_update_handler(rawptr(&f.bh), req)
	testing.expectf(t, resp.status == 422, "expected status 422 for offline bridge, got %d (body: %s)", resp.status, resp.body)
	testing.expect(t, strings.contains(resp.body, "unprocessable_entity"), "body reports unprocessable_entity error code")
}

// REQ-BUPD-4: POST /api/v1/bridges/{id}/update on online bridge dispatches WebSocket command and returns 202
@(test)
test_bridge_update_handler_online_dispatches_ws_command_and_returns_202 :: proc(t: ^testing.T) {
	f := setup_update_test_fixture(t, "online")
	defer teardown_update_test_fixture(f)

	// Set bridge status to Online in database
	bridge, ok, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	testing.expect(t, ok, "got bridge")
	bridge.status = .Online
	bridge.version = "0.1.0"
	bridge.commit_sha = "old_commit"
	_, save_ok, _ := iface.bridge_save_bridge(&f.br_repo, bridge)
	testing.expect(t, save_ok, "saved online bridge")
	catalog := bridge_service.Bridge_Update_Catalog{
		override_version = "0.2.0",
		override_commit_sha = "new_commit",
		override_download_url = "https://example.com/heimdall-local-linux-amd64.tar.gz",
		override_sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
	}
	f.br_svc.catalog = &catalog

	// Register bridge in live runtime registry
	_, accept_ok, _ := bridge_runtime_service.runtime_accept_hello(&f.registry, f.bridge_id, bridge_runtime_service.PROTOCOL_VERSION, "")
	testing.expect(t, accept_ok, "accepted bridge in registry")

	req := Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/bridges/%s/update", f.bridge_id),
		body = `{"target_version":"0.2.0","force":true,"drain_timeout_seconds":45}`,
		request_id = "req_online_upd",
		remote_addr = "127.0.0.1:4444",
		headers = f.user_headers,
	}

	stale_req := req
	stale_req.body = `{"target_version":"0.1.9","force":true}`
	stale_resp := bridge_update_handler(rawptr(&f.bh), stale_req)
	testing.expect_value(t, stale_resp.status, 400)
	testing.expect(t, strings.contains(stale_resp.body, "update catalog changed"))
	testing.expect(t, !f.sink_rec.sent, "stale version must not dispatch the current artifact")

	resp := bridge_update_handler(rawptr(&f.bh), req)
	testing.expectf(t, resp.status == 202, "expected status 202 Accepted, got %d (body: %s)", resp.status, resp.body)
	testing.expect(t, strings.contains(resp.body, "\"status\":\"dispatched\""), "status dispatched in response")
	testing.expect(t, strings.contains(resp.body, "\"command_id\":\"cmd_upd_"), "command_id in response")
	testing.expect(t, strings.contains(resp.body, "\"target_version\":\"0.2.0\""), "target_version in response")

	// Verify WebSocket command dispatch
	testing.expect(t, f.sink_rec.sent, "bridge_update command was dispatched to sink")
	testing.expect_value(t, f.sink_rec.last_cmd.bridge_id, f.bridge_id)
	testing.expect(t, strings.contains(f.sink_rec.last_cmd.body_json, "\"type\":\"bridge_update\""), "type bridge_update in frame")
	testing.expect(t, strings.contains(f.sink_rec.last_cmd.body_json, "\"target_version\":\"0.2.0\""), "target_version in frame")
	testing.expect(t, strings.contains(f.sink_rec.last_cmd.body_json, "\"force\":true"), "force true in frame")
	testing.expect(t, strings.contains(f.sink_rec.last_cmd.body_json, "\"drain_timeout_seconds\":45"), "drain_timeout_seconds 45 in frame")

	// Verify bridge status was updated to 'updating' in database
	updated_bridge, u_ok, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	testing.expect(t, u_ok, "got updated bridge")
	testing.expect_value(t, updated_bridge.update_status, "updating")
}

// A target/catalog mismatch is rejected by the Hub before a command can send a
// Bridge to an endpoint that does not exist.
@(test)
test_bridge_update_handler_missing_artifact_fails_before_dispatch :: proc(t: ^testing.T) {
	f := setup_update_test_fixture(t, "missing_artifact")
	defer teardown_update_test_fixture(f)

	bridge, ok, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	testing.expect(t, ok, "got bridge")
	bridge.status = .Online
	bridge.machine_os = "linux"
	bridge.machine_arch = "amd64"
	_, save_ok, _ := iface.bridge_save_bridge(&f.br_repo, bridge)
	testing.expect(t, save_ok, "saved online bridge")
	_, accept_ok, _ := bridge_runtime_service.runtime_accept_hello(&f.registry, f.bridge_id, bridge_runtime_service.PROTOCOL_VERSION, "")
	testing.expect(t, accept_ok, "accepted bridge in registry")

	catalog := bridge_service.Bridge_Update_Catalog{
		override_version = "0.2.0",
		override_commit_sha = "new_commit",
	}
	f.br_svc.catalog = &catalog
	req := Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/bridges/%s/update", f.bridge_id),
		body = `{"target_version":"latest","force":true}`,
		request_id = "req_missing_artifact",
		remote_addr = "127.0.0.1:4444",
		headers = f.user_headers,
	}
	resp := bridge_update_handler(rawptr(&f.bh), req)
	testing.expect_value(t, resp.status, 400)
	testing.expect(t, strings.contains(resp.body, "no verified update artifact"), "explicit artifact error returned")
	testing.expect(t, !f.sink_rec.sent, "no update command dispatched")
}

// REQ-T13-2: a termux-arm64 Bridge on a release that only ships linux-arm64 is
// told the update is not available for its target; nothing is dispatched and
// the listing carries the target plus update_artifact_available:false.
@(test)
test_bridge_update_termux_target_without_artifact_not_available :: proc(t: ^testing.T) {
	f := setup_update_test_fixture(t, "termux_no_artifact")
	defer teardown_update_test_fixture(f)

	manifest_path := fmt.tprintf("/tmp/test_termux_manifest_%d_%d.json", os.get_pid(), time.now()._nsec)
	manifest := `{"version":"0.3.30","commit_sha":"c30","targets":{"linux-arm64":{"tarball_url":"https://example.com/heimdall-local-linux-arm64-v0.3.30.tar.gz","sha256":"hash_linux_arm64"}}}`
	testing.expect(t, os.write_entire_file(manifest_path, transmute([]byte)manifest) == nil, "wrote manifest")
	defer os.remove(manifest_path)

	bridge, ok, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	testing.expect(t, ok, "got bridge")
	bridge.status = .Online
	bridge.machine_os = "termux"
	bridge.machine_arch = "arm64"
	bridge.version = "0.3.29"
	_, save_ok, _ := iface.bridge_save_bridge(&f.br_repo, bridge)
	testing.expect(t, save_ok, "saved online termux bridge")
	_, accept_ok, _ := bridge_runtime_service.runtime_accept_hello(&f.registry, f.bridge_id, bridge_runtime_service.PROTOCOL_VERSION, "")
	testing.expect(t, accept_ok, "accepted bridge in registry")

	catalog := bridge_service.Bridge_Update_Catalog{manifest_path = manifest_path}
	f.br_svc.catalog = &catalog

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_bridge_json(&b, bridge, nil, &catalog)
	out := strings.to_string(b)
	testing.expect(t, strings.contains(out, "\"target\":\"termux-arm64\""), "termux target serialized")
	testing.expect(t, strings.contains(out, "\"update_available\":true"), "newer release reported")
	testing.expect(t, strings.contains(out, "\"update_artifact_available\":false"), "not available for this target")

	req := Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/bridges/%s/update", f.bridge_id),
		body = `{"target_version":"latest","force":true}`,
		request_id = "req_termux_no_artifact",
		remote_addr = "127.0.0.1:4444",
		headers = f.user_headers,
	}
	resp := bridge_update_handler(rawptr(&f.bh), req)
	testing.expect_value(t, resp.status, 400)
	testing.expect(t, strings.contains(resp.body, "not available for this target (termux-arm64)"), "target named in error")
	testing.expect(t, !strings.contains(resp.body, "linux-arm64"), "never offers the linux bundle")
	testing.expect(t, !f.sink_rec.sent, "no update command dispatched")
}

@(test)
test_bridge_update_failure_progress_is_persisted :: proc(t: ^testing.T) {
	f := setup_update_test_fixture(t, "failed_progress")
	defer teardown_update_test_fixture(f)

	saved, save_err := bridge_service.record_bridge_update_progress(
		&f.br_svc,
		f.bridge_id,
		"failed",
		"tarball download failed (HTTP 404)",
		20,
	)
	testing.expect(t, saved, "failure progress persisted")
	testing.expect_value(t, save_err.code, domain.Error_Code.None)
	bridge, found, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	testing.expect(t, found, "bridge reloaded")
	defer if found do domain.bridge_destroy(&bridge)
	testing.expect_value(t, bridge.update_status, "failed")
	testing.expect_value(t, bridge.update_message, "tarball download failed (HTTP 404)")
	testing.expect_value(t, bridge.update_progress, 20)
	testing.expect_value(t, bridge.update_error, "tarball download failed (HTTP 404)")
}

// Remote uninstall audit capture. One test drives every case so the process-wide
// hook is never shared between parallel tests.
@(private = "file")
g_uninstall_audit: [dynamic]string

@(private = "file")
_test_uninstall_audit_hook :: proc(outcome, bridge_id, user_id, command_id, request_id, detail: string) {
	append(&g_uninstall_audit, fmt.aprintf("%s %s %s", outcome, bridge_id, request_id))
}

// F20 / REQ-ENR-10: POST /api/v1/bridges/{id}/uninstall. Another account is refused
// (owner check) and nothing is sent; the owner's request reaches an ONLINE bridge as
// a bridge_uninstall frame; an offline bridge is 422; every request is audited.
@(test)
test_bridge_uninstall_owner_only_online_and_audited :: proc(t: ^testing.T) {
	f := setup_update_test_fixture(t, "uninstall")
	defer teardown_update_test_fixture(f)
	bridge_service.bridge_uninstall_audit_hook = _test_uninstall_audit_hook
	defer {
		bridge_service.bridge_uninstall_audit_hook = nil
		for line in g_uninstall_audit do delete(line)
		delete(g_uninstall_audit)
		g_uninstall_audit = nil
	}
	path := fmt.tprintf("/api/v1/bridges/%s/uninstall", f.bridge_id)

	// Offline: the bridge cannot be told; nothing is sent.
	resp := bridge_uninstall_handler(rawptr(&f.bh), Request{method = "POST", path = path, body = `{}`, request_id = "req_uninst_offline", remote_addr = "127.0.0.1:4444", headers = f.user_headers})
	testing.expectf(t, resp.status == 422, "offline bridge: expected 422, got %d (%s)", resp.status, resp.body)
	testing.expect(t, !f.sink_rec.sent, "nothing sent to an offline bridge")

	bridge, ok, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	testing.expect(t, ok, "got bridge")
	bridge.status = .Online
	_, save_ok, _ := iface.bridge_save_bridge(&f.br_repo, bridge)
	testing.expect(t, save_ok, "saved online bridge")
	_, accept_ok, _ := bridge_runtime_service.runtime_accept_hello(&f.registry, f.bridge_id, bridge_runtime_service.PROTOCOL_VERSION, "")
	testing.expect(t, accept_ok, "bridge is live")

	// Another account: refused, no frame.
	other := http_test_login(t, &f.auth_svc, "uninstall_other_account")
	resp = bridge_uninstall_handler(rawptr(&f.bh), Request{method = "POST", path = path, body = `{}`, request_id = "req_uninst_other", remote_addr = "127.0.0.1:4444", headers = other})
	testing.expectf(t, resp.status == 403 || resp.status == 404, "non-owner: expected 403/404, got %d (%s)", resp.status, resp.body)
	testing.expect(t, !f.sink_rec.sent, "a non-owner's request sends nothing")

	// Unauthenticated: 401.
	resp = bridge_uninstall_handler(rawptr(&f.bh), Request{method = "POST", path = path, body = `{}`, request_id = "req_uninst_anon", remote_addr = "192.168.1.1:1234"})
	testing.expect_value(t, resp.status, 401)

	// Owner, online: the frame goes to that bridge.
	resp = bridge_uninstall_handler(rawptr(&f.bh), Request{method = "POST", path = path, body = `{"purge":true}`, request_id = "req_uninst_owner", remote_addr = "127.0.0.1:4444", headers = f.user_headers})
	testing.expectf(t, resp.status == 202, "owner: expected 202, got %d (%s)", resp.status, resp.body)
	testing.expect(t, f.sink_rec.sent, "frame sent")
	testing.expect_value(t, f.sink_rec.last_cmd.bridge_id, f.bridge_id)
	testing.expect(t, strings.contains(f.sink_rec.last_cmd.body_json, `"type":"bridge_uninstall"`), "bridge_uninstall frame")
	testing.expect(t, strings.contains(f.sink_rec.last_cmd.body_json, `"mode":"purge"`), "purge mode")
	testing.expect(t, strings.contains(resp.body, f.sink_rec.last_cmd.command_id), "response carries the command id")

	testing.expect_value(t, len(g_uninstall_audit), 3)
	if len(g_uninstall_audit) == 3 {
		testing.expect_value(t, g_uninstall_audit[0], fmt.tprintf("offline %s req_uninst_offline", f.bridge_id))
		testing.expect_value(t, g_uninstall_audit[1], fmt.tprintf("denied %s req_uninst_other", f.bridge_id))
		testing.expect_value(t, g_uninstall_audit[2], fmt.tprintf("dispatched %s req_uninst_owner", f.bridge_id))
	}
}

@(test)
test_bridge_auto_update_catalog_auth :: proc(t: ^testing.T) {
    f := setup_update_test_fixture(t, "auto-catalog")
    defer teardown_update_test_fixture(f)
    req := Request{method = "GET", path = "/api/v1/bridge/update-catalog", request_id = "auto-catalog", remote_addr = "192.0.2.1:1234"}
    testing.expect_value(t, bridge_auto_update_catalog_handler(rawptr(&f.bh), req).status, 401)
    req.headers = {{name = "Authorization", value = fmt.tprintf("Bearer %s", f.bridge_token)}}
    cat := bridge_service.Bridge_Update_Catalog{override_version = "9.0.0", override_download_url = "https://example.test/bundle.tar.gz", override_sha256 = "a"}
    f.br_svc.catalog = &cat
    response := bridge_auto_update_catalog_handler(rawptr(&f.bh), req)
    testing.expect_value(t, response.status, 200)
    testing.expect(t, strings.contains(response.body, "9.0.0"))
}

@(test)
test_bridge_auto_update_config_authorization :: proc(t: ^testing.T) {
    f := setup_update_test_fixture(t, "auto-config")
    defer teardown_update_test_fixture(f)
    req := Request{method = "GET", path = fmt.tprintf("/api/v1/bridges/%s/auto-update", f.bridge_id), request_id = "auto-config", remote_addr = "192.0.2.1:1234"}
    testing.expect_value(t, bridge_auto_update_config_handler(rawptr(&f.bh), req).status, 401)
    req.headers = f.user_headers
    req.method = "PUT"
    req.body = "{\"enabled\":\"false\"}"
    testing.expect_value(t, bridge_auto_update_config_handler(rawptr(&f.bh), req).status, 400)
    req.body = "{\"enabled\":false}"
    response := bridge_auto_update_config_handler(rawptr(&f.bh), req)
    testing.expect(t, response.status >= 400, "offline settings never report a successful save")
    other := http_test_login(t, &f.auth_svc, "auto_update_other_owner")
    req.headers = other
    response = bridge_auto_update_config_handler(rawptr(&f.bh), req)
    testing.expect(t, response.status == 403 || response.status == 404, "another account cannot edit the profile")
}

// Discovery reuses the owner-only live filesystem relay; history must never be
// available through an unauthenticated or cross-owner request.
@(test)
test_session_projects_owner_authorization :: proc(t: ^testing.T) {
	f := setup_update_test_fixture(t, "session-projects")
	defer teardown_update_test_fixture(f)
	path := fmt.tprintf("/api/v1/bridges/%s/session-projects", f.bridge_id)
	resp := list_bridge_session_projects_handler(rawptr(&f.bh), Request{method = "GET", path = path, request_id = "history-anon", remote_addr = "192.168.1.1:1234"})
	testing.expect_value(t, resp.status, 401)
	other := http_test_login(t, &f.auth_svc, "session-history-other")
	resp = list_bridge_session_projects_handler(rawptr(&f.bh), Request{method = "GET", path = path, request_id = "history-other", remote_addr = "127.0.0.1:4444", headers = other})
	testing.expect(t, resp.status == 403 || resp.status == 404)
	resp = list_bridge_session_projects_handler(rawptr(&f.bh), Request{method = "GET", path = path, request_id = "history-owner", remote_addr = "127.0.0.1:4444", headers = f.user_headers})
	testing.expect_value(t, resp.status, 409)
	testing.expect(t, !f.sink_rec.sent, "no discovery sent when unauthorized or offline")
}


@(private = "file")
Session_Discovery_Peer :: struct {
	f: ^update_handler_wire_fixture,
	socket: net.TCP_Socket,
	generation: int,
	received: bool,
	correlated: bool,
}

@(private = "file")
session_discovery_peer :: proc(data: rawptr) {
	peer := (^Session_Discovery_Peer)(data)
	reader: ws.Frame_Reader
	defer ws.reader_destroy(&reader)
	_, command, ok := ws.read_frame(peer.socket, &reader, time.Second)
	if !ok do return
	defer delete(command)
	peer.received = json_string(command, "type", context.temp_allocator) == "session_projects"
	id := json_string(command, "command_id", context.temp_allocator)
	reply := fmt.tprintf(`{{"type":"session_projects_result","command_id":"%s","ok":true,"projects":[{{"source":"Codex","path":"/fixture/app","canonical_path":"/fixture/app","description":"App is a calendar service.","sessions":2,"last_session_at":"2026-10-31T10:00:00Z"}}],"truncated":false}}`, id)
	chunks: [dynamic]Bridge_Chunk_Reassembly
	defer bridge_chunk_reassemblies_free(&chunks)
	peer.correlated = bridge_ws_process_frame(&peer.f.bh, peer.f.bridge_id, peer.generation, peer.socket, &chunks, strings.clone(reply))
}

@(test)
test_session_projects_authorized_roundtrip :: proc(t: ^testing.T) {
	f := setup_update_test_fixture(t, "session-projects-roundtrip")
	defer teardown_update_test_fixture(f)
	bridge, ok, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	if !testing.expect(t, ok) do return
	defer domain.bridge_destroy(&bridge)
	bridge.status = .Online
	_, saved, _ := iface.bridge_save_bridge(&f.br_repo, bridge)
	testing.expect(t, saved)
	_, generation, live := project_service.bridge_runtime_registry_accept_live(&f.registry, f.bridge_id, false, "", f.owner_user_id)
	if !testing.expect(t, live) do return
	defer project_service.bridge_runtime_registry_destroy(&f.registry)
	listener, listen_err := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	if listen_err != nil do testing.fail_now(t, "loopback listen")
	defer net.close(listener)
	bound, _ := net.bound_endpoint(listener)
	socket, dial_err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	if dial_err != nil do testing.fail_now(t, "loopback dial")
	defer net.close(socket)
	hub, _, accept_err := net.accept_tcp(listener)
	if accept_err != nil do testing.fail_now(t, "loopback accept")
	defer net.close(hub)
	project_service.bridge_runtime_registry_set_command_socket(&f.registry, f.bridge_id, hub, generation)
	peer := Session_Discovery_Peer{f = f, socket = socket, generation = generation}
	worker := thread.create_and_start_with_data(&peer, session_discovery_peer)
	response := list_bridge_session_projects_handler(rawptr(&f.bh), Request{method = "GET", path = fmt.tprintf("/api/v1/bridges/%s/session-projects", f.bridge_id), request_id = "history-roundtrip", remote_addr = "127.0.0.1:4444", headers = f.user_headers})
	thread.join(worker)
	thread.destroy(worker)
	defer delete(response.body)
	testing.expect_value(t, response.status, 200)
	testing.expect(t, peer.received && peer.correlated)
	testing.expect(t, strings.contains(response.body, `"path":"/fixture/app"`))
	testing.expect(t, strings.contains(response.body, `"sessions":2`))
	testing.expect(t, strings.contains(response.body, `"description":"App is a calendar service."`))
}
