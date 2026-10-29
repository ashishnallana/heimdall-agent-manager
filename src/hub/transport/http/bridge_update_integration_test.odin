package http

import "core:fmt"
import "core:os"
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

// REQ-BUPD-5, REQ-BUPD-6: End-to-end integration and automated rollback test suite
// for the bridge update pipeline.

@(private = "file")
integ_test_counter: int = 0

@(private = "file")
Integration_Sink_Recorder :: struct {
	sent: bool,
	sent_count: int,
	last_cmd: project_service.Runtime_Command,
}

@(private = "file")
_test_integ_sink_proc :: proc(ctx: rawptr, cmd: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	rec := (^Integration_Sink_Recorder)(ctx)
	rec.sent = true
	rec.sent_count += 1
	if rec.last_cmd.bridge_id != "" {
		delete(rec.last_cmd.bridge_id)
		delete(rec.last_cmd.command_id)
		delete(rec.last_cmd.body_json)
	}
	rec.last_cmd = project_service.Runtime_Command{
		bridge_id = strings.clone(cmd.bridge_id),
		command_id = strings.clone(cmd.command_id),
		body_json = strings.clone(cmd.body_json),
	}
	return true, domain.Domain_Error{}
}

@(private = "file")
integration_update_fixture :: struct {
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
	sink_rec: Integration_Sink_Recorder,
	owner_user_id: string,
	bridge_id: string,

	bridge_token: string,
}


@(private = "file")
setup_integration_update_fixture :: proc(t: ^testing.T, tag: string) -> ^integration_update_fixture {
	f := new(integration_update_fixture)
	seq := sync.atomic_add(&integ_test_counter, 1)
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

	f.sink_rec = Integration_Sink_Recorder{}
	sink := project_service.Bridge_Command_Sink{
		ctx = rawptr(&f.sink_rec),
		send_runtime_command = _test_integ_sink_proc,
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

	f.user_headers = http_test_login(t, &f.auth_svc, "integ_test_operator")
	owner_ctx, owner_ok, _ := auth_service.resolve_auth_any(&f.auth_svc, auth_service.Auth_Request{
		remote_addr = "127.0.0.1:4444",
		headers = f.user_headers,
	})
	testing.expect(t, owner_ok, "session owner resolved")
	f.owner_user_id = strings.clone(owner_ctx.user_id)

	// Provisioned through the DEVICE-GRANT path, the only enrollment there is
	// (REQ-ENROLL-9). The fixture's `enrollment_token` field went with the flow:
	// there is no enrollment token to hold, and nothing here read it.
	enrolled, e_ok, _ := bridge_service.enroll_bridge_from_device_grant(&f.br_svc, bridge_service.Device_Enroll_Input{
		owner_user_id = f.owner_user_id,
		bridge_public_key = "04aabb",
		bridge_key_fingerprint = "aaaa bbbb cccc dddd",
		machine_hostname = "integ-worker-01",
	})
	testing.expect(t, e_ok, "bridge enrolled")
	f.bridge_id = strings.clone(enrolled.bridge.bridge_id)
	f.bridge_token = strings.clone(enrolled.bridge_token)

	return f
}

@(private = "file")
teardown_integration_update_fixture :: proc(f: ^integration_update_fixture) {
	if f == nil do return
	sqlite.close(&f.conn)
	
	delete(f.owner_user_id)
	delete(f.bridge_id)

	delete(f.bridge_token)
	if f.sink_rec.last_cmd.bridge_id != "" {
		delete(f.sink_rec.last_cmd.bridge_id)
		delete(f.sink_rec.last_cmd.command_id)
		delete(f.sink_rec.last_cmd.body_json)
	}
	free(f)
}

// REQ-BUPD-5: Wire tests prove Hub <-> Bridge update WebSocket messaging and
// successful end-to-end update with version bump and catalog recalculation.
@(test)
test_bridge_update_integration_wire_dispatch_and_version_bump :: proc(t: ^testing.T) {
	f := setup_integration_update_fixture(t, "wire_bump")
	defer teardown_integration_update_fixture(f)

	// 1. Initial State: Bridge connected on v0.1.0 (commit v1_hash)
	connected_br, conn_ok, _ := bridge_service.bridge_runtime_connect(
		&f.br_svc,
		f.bridge_token,
		"integ-worker-01",
		"linux",
		"amd64",
		`{"capabilities":["shell","fs"]}`,
		"0.1.0",
		"v1_hash_a57c",
		"2026-09-01T10:00:00Z",
	)
	testing.expect(t, conn_ok, "initial bridge runtime connect ok")
	testing.expect_value(t, connected_br.status, domain.Bridge_Status.Online)
	testing.expect_value(t, connected_br.version, "0.1.0")

	// Accept in registry to simulate live runtime socket
	_, reg_ok, _ := bridge_runtime_service.runtime_accept_hello(&f.registry, f.bridge_id, bridge_runtime_service.PROTOCOL_VERSION, "")
	testing.expect(t, reg_ok, "registered bridge hello in registry")

	// Configure central update catalog to serve target version 0.2.0
	catalog := bridge_service.Bridge_Update_Catalog{
		override_version = "0.2.0",
		override_commit_sha = "v2_hash_796b",
		override_download_url = "http://127.0.0.1:8989/api/v1/updates/bundle/heimdall-linux-amd64.tar.gz",
		override_sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
	}
	f.br_svc.catalog = &catalog

	// 2. Query initial status via GET /api/v1/bridges/{bridge_id}
	get_req1 := Request{
		method = "GET",
		path = fmt.tprintf("/api/v1/bridges/%s", f.bridge_id),
		request_id = "req_initial_state",
		remote_addr = "127.0.0.1:4444",
		headers = f.user_headers,
	}
	get_resp1 := bridge_detail_handler(rawptr(&f.bh), get_req1)
	testing.expect_value(t, get_resp1.status, 200)
	testing.expect(t, strings.contains(get_resp1.body, "\"version\":\"0.1.0\""), "initial version is 0.1.0")
	testing.expect(t, strings.contains(get_resp1.body, "\"commit_sha\":\"v1_hash_a57c\""), "initial commit is v1_hash_a57c")
	testing.expect(t, strings.contains(get_resp1.body, "\"update_available\":true"), "update available is true before upgrade")
	testing.expect(t, strings.contains(get_resp1.body, "\"latest_version\":\"0.2.0\""), "latest version is 0.2.0")
	testing.expect(t, strings.contains(get_resp1.body, "\"latest_commit_sha\":\"v2_hash_796b\""), "latest commit sha is v2_hash_796b")

	// 3. Dispatch Update: POST /api/v1/bridges/{bridge_id}/update
	upd_req := Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/bridges/%s/update", f.bridge_id),
		body = `{"target_version":"0.2.0","force":true,"drain_timeout_seconds":30}`,
		request_id = "req_wire_dispatch",
		remote_addr = "127.0.0.1:4444",
		headers = f.user_headers,
	}
	upd_resp := bridge_update_handler(rawptr(&f.bh), upd_req)
	testing.expectf(t, upd_resp.status == 202, "expected HTTP 202 Accepted, got %d (body: %s)", upd_resp.status, upd_resp.body)
	testing.expect(t, strings.contains(upd_resp.body, "\"status\":\"dispatched\""), "response payload reports status dispatched")
	testing.expect(t, strings.contains(upd_resp.body, "\"target_version\":\"0.2.0\""), "response payload reports target_version 0.2.0")
	testing.expect(t, strings.contains(upd_resp.body, "\"command_id\":\"cmd_upd_"), "response payload has command_id")

	// 4. Verify WebSocket Command Wire Frame dispatched to sink
	testing.expect(t, f.sink_rec.sent, "bridge_update frame was sent through WebSocket sink")
	testing.expect_value(t, f.sink_rec.last_cmd.bridge_id, f.bridge_id)
	ws_payload := f.sink_rec.last_cmd.body_json
	testing.expect(t, strings.contains(ws_payload, "\"type\":\"bridge_update\""), "frame has type bridge_update")
	testing.expect(t, strings.contains(ws_payload, "\"target_version\":\"0.2.0\""), "frame target_version matches 0.2.0")
	testing.expect(t, strings.contains(ws_payload, "\"download_url\":\"http://127.0.0.1:8989/api/v1/updates/bundle/heimdall-linux-amd64.tar.gz\""), "download_url matches")
	testing.expect(t, strings.contains(ws_payload, "\"sha256\":\"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\""), "sha256 checksum matches")
	testing.expect(t, strings.contains(ws_payload, "\"force\":true"), "force parameter passed through frame")
	testing.expect(t, strings.contains(ws_payload, "\"drain_timeout_seconds\":30"), "drain_timeout_seconds passed through frame")

	// Verify database row update_status
	br_in_db, db_ok, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	testing.expect(t, db_ok, "read bridge from db")
	testing.expect_value(t, br_in_db.update_status, "updating")

	// 5. Successful Update Simulation: Mock bridge restarts and reconnects with v0.2.0
	reconn_br, reconn_ok, _ := bridge_service.bridge_runtime_connect(
		&f.br_svc,
		f.bridge_token,
		"integ-worker-01",
		"linux",
		"amd64",
		`{"capabilities":["shell","fs"]}`,
		"0.2.0",
		"v2_hash_796b",
		"2026-10-01T12:00:00Z",
	)
	testing.expect(t, reconn_ok, "reconnection runtime connect ok")
	testing.expect_value(t, reconn_br.status, domain.Bridge_Status.Online)
	testing.expect_value(t, reconn_br.version, "0.2.0")
	testing.expect_value(t, reconn_br.commit_sha, "v2_hash_796b")

	// 6. Query updated status via GET /api/v1/bridges/{bridge_id}
	get_req2 := Request{
		method = "GET",
		path = fmt.tprintf("/api/v1/bridges/%s", f.bridge_id),
		request_id = "req_post_update_state",
		remote_addr = "127.0.0.1:4444",
		headers = f.user_headers,
	}
	get_resp2 := bridge_detail_handler(rawptr(&f.bh), get_req2)
	testing.expect_value(t, get_resp2.status, 200)
	testing.expect(t, strings.contains(get_resp2.body, "\"version\":\"0.2.0\""), "updated version is 0.2.0")
	testing.expect(t, strings.contains(get_resp2.body, "\"commit_sha\":\"v2_hash_796b\""), "updated commit is v2_hash_796b")
	testing.expect(t, strings.contains(get_resp2.body, "\"update_available\":false"), "update available is now false after version bump")
	testing.expect(t, strings.contains(get_resp2.body, "\"latest_version\":\"0.2.0\""), "latest version remains 0.2.0")
}

// REQ-BUPD-3, REQ-BUPD-4: Active Agent Tasks Drain and Force Option Gating:
// When active agent tasks are running on a bridge, update requests without force
// or drain timeout are rejected with HTTP 409 Conflict. Specifying force=true or
// drain_timeout_seconds > 0 allows the update to proceed.
@(test)
test_bridge_update_integration_active_tasks_drain_and_force_gating :: proc(t: ^testing.T) {
	f := setup_integration_update_fixture(t, "drain_force")
	defer teardown_integration_update_fixture(f)

	// Set bridge online
	_, conn_ok, _ := bridge_service.bridge_runtime_connect(
		&f.br_svc,
		f.bridge_token,
		"integ-worker-01",
		"linux",
		"amd64",
		`{"capabilities":["shell","fs"]}`,
		"0.1.0",
		"v1_hash",
		"2026-09-01T00:00:00Z",
	)
	testing.expect(t, conn_ok, "bridge online")
	_, acc_ok, _ := bridge_runtime_service.runtime_accept_hello(&f.registry, f.bridge_id, bridge_runtime_service.PROTOCOL_VERSION, "")
	testing.expect(t, acc_ok, "registry accept ok")

	catalog := bridge_service.Bridge_Update_Catalog{
		override_version = "0.2.0",
		override_commit_sha = "v2_hash",
		override_download_url = "https://example.com/heimdall-local-linux-amd64.tar.gz",
		override_sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
	}
	f.br_svc.catalog = &catalog

	// Create an active agent instance assigned to this bridge
	active_inst := domain.Agent_Instance{
		agent_instance_id = "inst_active_gate_test",
		owner_user_id = domain.User_ID(f.owner_user_id),
		bridge_id = f.bridge_id,
		display_name = "Busy Agent",
		runtime_status = "running",
		activity_status = "busy",
		startup_status = "ready",
	}
	_, save_ok, _ := iface.agent_save_instance(&f.ag_repo, active_inst)
	testing.expect(t, save_ok, "saved active agent instance")

	// 1. Update without force or drain_timeout -> 409 Conflict
	conflict_req := Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/bridges/%s/update", f.bridge_id),
		body = `{"target_version":"0.2.0","force":false,"drain_timeout_seconds":0}`,
		request_id = "req_conflict",
		remote_addr = "127.0.0.1:4444",
		headers = f.user_headers,
	}
	conflict_resp := bridge_update_handler(rawptr(&f.bh), conflict_req)
	testing.expectf(t, conflict_resp.status == 409, "expected 409 Conflict for active tasks, got %d (body: %s)", conflict_resp.status, conflict_resp.body)
	testing.expect(t, strings.contains(conflict_resp.body, "active agent tasks"), "conflict body explains active tasks reason")

	// 2. Update with force=true -> 202 Accepted
	force_req := Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/bridges/%s/update", f.bridge_id),
		body = `{"target_version":"0.2.0","force":true,"drain_timeout_seconds":0}`,
		request_id = "req_force",
		remote_addr = "127.0.0.1:4444",
		headers = f.user_headers,
	}
	force_resp := bridge_update_handler(rawptr(&f.bh), force_req)
	testing.expectf(t, force_resp.status == 202, "expected 202 Accepted with force=true, got %d", force_resp.status)
	testing.expect(t, strings.contains(force_resp.body, "\"status\":\"dispatched\""), "dispatched status in response")
	testing.expect(t, strings.contains(f.sink_rec.last_cmd.body_json, "\"force\":true"), "force true in wire frame")

	// 3. Update with drain_timeout_seconds=60 -> 202 Accepted
	drain_req := Request{
		method = "POST",
		path = fmt.tprintf("/api/v1/bridges/%s/update", f.bridge_id),
		body = `{"target_version":"0.2.0","force":false,"drain_timeout_seconds":60}`,
		request_id = "req_drain",
		remote_addr = "127.0.0.1:4444",
		headers = f.user_headers,
	}
	drain_resp := bridge_update_handler(rawptr(&f.bh), drain_req)
	testing.expectf(t, drain_resp.status == 202, "expected 202 Accepted with drain_timeout_seconds=60, got %d", drain_resp.status)
	testing.expect(t, strings.contains(drain_resp.body, "\"status\":\"dispatched\""), "dispatched status in response")
	testing.expect(t, strings.contains(f.sink_rec.last_cmd.body_json, "\"drain_timeout_seconds\":60"), "drain_timeout_seconds in wire frame")
}
