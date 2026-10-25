// Behavioral tests for bridge JSON serialization (vault status, public key, version/update state) and heartbeat updates.
package http

import agent_service "odin_test:hub/service/agent"
import auth_service "odin_test:hub/service/auth"
import bridge_service "odin_test:hub/service/bridge"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import events "odin_test:hub/service/events"
import "core:fmt"
import iface "odin_test:hub/repository/iface"
import "core:os"
import platform "odin_test:hub/platform"
import project_service "odin_test:hub/service/project"
import sqlite "odin_test:hub/repository/sqlite"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import user_service "odin_test:hub/service/user"

// --- Consolidated from bridge_vault_status_test.odin ---

@(test)
test_write_bridge_json_vault_status_unreported_is_empty :: proc(t: ^testing.T) {
	bridge := domain.Bridge{
		bridge_id = "brg_vault_status_unreported",
		label = "Never Reported",
		machine_os = "linux",
		machine_arch = "amd64",
		status = .Online,
		capabilities_json = "{}",
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_bridge_json(&b, bridge, nil)
	out := strings.to_string(b)

	testing.expect(t, strings.contains(out, "\"vault_status\":\"\""), "an unreported bridge serializes vault_status as the empty string")
	testing.expect(t, !strings.contains(out, "\"vault_status\":\"unlocked\""), "an unreported bridge must NEVER be serialized as unlocked")
}

// REQ-BVS-2: each reported value round-trips through the serializer unchanged.
@(test)
test_write_bridge_json_vault_status_reported_values :: proc(t: ^testing.T) {
	for value in bridge_service.BRIDGE_VAULT_STATUS_VALUES {
		bridge := domain.Bridge{
			bridge_id = "brg_vault_status_reported",
			status = .Online,
			capabilities_json = "{}",
			vault_status = value,
		}
		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		write_bridge_json(&b, bridge, nil)
		expected := fmt.tprintf("\"vault_status\":\"%s\"", value)
		testing.expect(t, strings.contains(strings.to_string(b), expected), fmt.tprintf("vault_status=%s is emitted verbatim", value))
	}
}

@(private = "file")
vault_status_test_counter: int = 0

@(private = "file")
vault_status_fixture :: struct {
	db_path: string,
	conn: sqlite.Conn,
	br_repo_sqlite: sqlite.Bridge_Repo_SQLite,
	us_repo_sqlite: sqlite.User_Repo_SQLite,
	ag_repo_sqlite: sqlite.Agent_Repo_SQLite,
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
	registry: project_service.Bridge_Runtime_Registry,
	bus: events.User_Event_Bus,
	bh: Bridge_Handlers,
	owner_user_id: string,
	bridge_id: string,
}



@(private = "file")
setup_vault_status_fixture :: proc(t: ^testing.T, tag: string) -> ^vault_status_fixture {
	f := new(vault_status_fixture)
	seq := sync.atomic_add(&vault_status_test_counter, 1)
	f.db_path = ":memory:"
	

	conn, open_ok, open_err := sqlite.open(f.db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	f.conn = conn

	mig_ok, mig_err := sqlite.run_migrations(&f.conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	f.br_repo = sqlite.new_bridge_repository(&f.br_repo_sqlite, &f.conn)
	f.us_repo = sqlite.new_user_repository(&f.us_repo_sqlite, &f.conn)
	f.ag_repo = sqlite.new_agent_repository(&f.ag_repo_sqlite, &f.conn)

	f.clock = platform.real_clock()
	f.ids = http_test_id_generator()

	f.br_svc = bridge_service.new_bridge_service(&f.br_repo, &f.clock, &f.ids)
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
		event_bus = &f.bus,
		bridge_runtime_registry = &f.registry,
	}

	f.user_headers = http_test_login(t, &f.auth_svc, "tanmay")
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

	return f
}

@(private = "file")
teardown_vault_status_fixture :: proc(f: ^vault_status_fixture) {
	if f == nil do return
	sqlite.close(&f.conn)
	
	if len(f.owner_user_id) > 0 do delete(f.owner_user_id)
	if len(f.bridge_id) > 0 do delete(f.bridge_id)
	free(f)
}

// REQ-BVS-1: a freshly enrolled bridge has reported nothing, so the stored value is ""
// — NOT a status word. This is the state the serializer test above renders.
@(test)
test_enrolled_bridge_starts_with_empty_vault_status :: proc(t: ^testing.T) {
	f := setup_vault_status_fixture(t, "initial")
	defer teardown_vault_status_fixture(f)

	stored, ok, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	defer { b := stored; domain.bridge_destroy(&b) }
	testing.expect(t, ok, "bridge found in repo")
	testing.expect_value(t, stored.vault_status, "")
}

// REQ-BVS-1: a reported value is stored, and reporting it AGAIN is not a change.
@(test)
test_update_vault_status_stores_and_detects_change :: proc(t: ^testing.T) {
	f := setup_vault_status_fixture(t, "store")
	defer teardown_vault_status_fixture(f)

	bridge, changed, err := bridge_service.update_vault_status(&f.br_svc, f.bridge_id, "unlocked")
	defer { b := bridge; domain.bridge_destroy(&b) }
	testing.expect(t, changed, "first report is a change")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, bridge.vault_status, "unlocked")

	persisted, ok, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	defer { b := persisted; domain.bridge_destroy(&b) }
	testing.expect(t, ok, "bridge found in repo")
	testing.expect_value(t, persisted.vault_status, "unlocked")

	// The same value again: still stored, but NOT a change. The bridge reports this
	// in every heartbeat, ~45s, forever — if this returned true the hub would
	// invalidate every connected browser's bridge list twice a minute per bridge.
	unchanged_row, changed_again, err_again := bridge_service.update_vault_status(&f.br_svc, f.bridge_id, "unlocked")
	defer { b := unchanged_row; domain.bridge_destroy(&b) }
	testing.expect(t, !changed_again, "an unchanged report is not a change")
	testing.expect_value(t, err_again.code, domain.Error_Code.None)

	// A genuine transition is a change again, and overwrites.
	locked, locked_changed, _ := bridge_service.update_vault_status(&f.br_svc, f.bridge_id, "locked")
	defer { b := locked; domain.bridge_destroy(&b) }
	testing.expect(t, locked_changed, "unlocked -> locked is a change")
	testing.expect_value(t, locked.vault_status, "locked")

	relocked, _, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	defer { b := relocked; domain.bridge_destroy(&b) }
	testing.expect_value(t, relocked.vault_status, "locked")
}

// REQ-BVS-1: the hub pins the vocabulary. A bridge can put anything on the wire, and
// this value is rendered straight into the settings page.
@(test)
test_update_vault_status_rejects_illegal_values :: proc(t: ^testing.T) {
	f := setup_vault_status_fixture(t, "reject")
	defer teardown_vault_status_fixture(f)

	for bad in ([4]string{"", "Unlocked", "open", "unlocked "}) {
		rejected, changed, err := bridge_service.update_vault_status(&f.br_svc, f.bridge_id, bad)
		b := rejected; domain.bridge_destroy(&b)
		testing.expect(t, !changed, fmt.tprintf("%q is not stored", bad))
		testing.expect_value(t, err.code, domain.Error_Code.Validation_Failed)
	}

	stored, _, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	defer { b := stored; domain.bridge_destroy(&b) }
	testing.expect_value(t, stored.vault_status, "")
}

// REQ-BVS-1: the heartbeat/report arms store the value AND publish the bridge
// invalidation on a CHANGE ONLY.
//
// bus.event_seq is the observable: publish_resource_changed increments it on every
// published event and returns without touching it when there is nothing to publish.
// So "did the UI get told?" is a number, not an inference.
@(test)
test_apply_vault_status_report_publishes_on_change_only :: proc(t: ^testing.T) {
	f := setup_vault_status_fixture(t, "publish")
	defer teardown_vault_status_fixture(f)

	// The bus must have the owner subscribed for a publish to count; the handler
	// resolves the owner off the bridge row, so no socket is needed — only a seq.
	before := f.bus.event_seq

	bridge_apply_vault_status_report(&f.bh, f.bridge_id, `{"type":"bridge_vault_status","protocol_version":1,"vault_status":"unlocked"}`)
	after_change := f.bus.event_seq
	testing.expect(t, after_change == before + 1, "a changed value publishes exactly one invalidation")

	stored, _, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	defer { b := stored; domain.bridge_destroy(&b) }
	testing.expect_value(t, stored.vault_status, "unlocked")

	// Three more identical reports, as three heartbeats would deliver: no publishes.
	for _ in 0 ..< 3 {
		bridge_apply_vault_status_report(&f.bh, f.bridge_id, `{"type":"bridge_heartbeat","protocol_version":1,"vault_status":"unlocked","capabilities":[]}`)
	}
	testing.expect(t, f.bus.event_seq == after_change, "repeated unchanged heartbeats publish nothing")

	// A real transition publishes again.
	bridge_apply_vault_status_report(&f.bh, f.bridge_id, `{"type":"bridge_vault_status","protocol_version":1,"vault_status":"locked"}`)
	testing.expect(t, f.bus.event_seq == after_change + 1, "a transition publishes exactly one invalidation")

	locked, _, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	defer { b := locked; domain.bridge_destroy(&b) }
	testing.expect_value(t, locked.vault_status, "locked")
}

// REQ-BVS-1: a frame with no vault_status — an OLDER BRIDGE BUILD, which is the
// common case during a rollout — must leave the stored value alone rather than
// erasing a real reported status to "".
@(test)
test_apply_vault_status_report_ignores_frames_without_the_field :: proc(t: ^testing.T) {
	f := setup_vault_status_fixture(t, "absent")
	defer teardown_vault_status_fixture(f)

	bridge_apply_vault_status_report(&f.bh, f.bridge_id, `{"type":"bridge_vault_status","vault_status":"unlocked"}`)
	seq_after_report := f.bus.event_seq

	// An old-build heartbeat: no vault_status key at all.
	bridge_apply_vault_status_report(&f.bh, f.bridge_id, `{"type":"bridge_heartbeat","protocol_version":1,"capabilities":[]}`)

	stored, _, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	defer { b := stored; domain.bridge_destroy(&b) }
	testing.expect_value(t, stored.vault_status, "unlocked")
	testing.expect(t, f.bus.event_seq == seq_after_report, "a frame without the field publishes nothing")
}

// --- Consolidated from bridge_unseal_test.odin ---

@(test)
test_write_bridge_json_public_key_fields :: proc(t: ^testing.T) {
	registry: project_service.Bridge_Runtime_Registry
	defer project_service.bridge_runtime_registry_destroy(&registry)
	project_service.bridge_runtime_registry_mark_live(&registry, "brg_pk_test", false, "")
	project_service.bridge_runtime_registry_set_public_key(&registry, "brg_pk_test", "04aabbccddeeff")

	bridge := domain.Bridge{
		bridge_id = "brg_pk_test",
		label = "Worker Public Key",
		machine_hostname = "worker-pk",
		machine_os = "linux",
		machine_arch = "amd64",
		hub_url = "http://127.0.0.1:8080",
		status = .Online,
		capabilities_json = "{}",
		version = "0.2.0",
		commit_sha = "796bfb57",
		build_timestamp = "2026-10-01T12:00:00Z",
		update_status = "idle",
		update_error = "",
		last_seen_at = "2026-10-01T12:01:00Z",
		updated_at = "2026-10-01T12:01:00Z",
	}

	agents := agent_service.Agent_Service{
		bridge_runtime_registry = &registry,
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	write_bridge_json(&b, bridge, &agents, nil)
	out := strings.to_string(b)

	testing.expect(t, strings.contains(out, "\"public_key\":\"04aabbccddeeff\""), "public_key serialized from registry")
	testing.expect(t, strings.contains(out, "\"bridge_public_key\":\"04aabbccddeeff\""), "bridge_public_key serialized from registry")
	testing.expect(t, strings.contains(out, "\"task_chain_search_revision\":0,\"public_key\""), "numeric search revision is followed by a valid JSON field boundary")
	testing.expect(t, !strings.contains(out, "\"task_chain_search_revision\":0\",\"public_key\""), "numeric search revision must not gain a stray closing quote")
}

// Fallback to capabilities_json if registry is empty
@(test)
test_write_bridge_json_public_key_from_capabilities :: proc(t: ^testing.T) {
	bridge := domain.Bridge{
		bridge_id = "brg_cap_test",
		label = "Worker Cap",
		machine_hostname = "worker-cap",
		machine_os = "linux",
		machine_arch = "amd64",
		hub_url = "http://127.0.0.1:8080",
		status = .Online,
		capabilities_json = `{"public_key":"04112233445566"}`,
		version = "0.2.0",
		commit_sha = "796bfb57",
		build_timestamp = "2026-10-01T12:00:00Z",
		update_status = "idle",
		update_error = "",
		last_seen_at = "2026-10-01T12:01:00Z",
		updated_at = "2026-10-01T12:01:00Z",
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	write_bridge_json(&b, bridge, nil, nil)
	out := strings.to_string(b)

	testing.expect(t, strings.contains(out, "\"public_key\":\"04112233445566\""), "public_key serialized from capabilities_json")
	testing.expect(t, strings.contains(out, "\"bridge_public_key\":\"04112233445566\""), "bridge_public_key serialized from capabilities_json")
}

// --- Consolidated from bridge_version_json_test.odin ---

@(test)
test_write_bridge_json_version_fields :: proc(t: ^testing.T) {
	bridge := domain.Bridge{
		bridge_id = "brg_version_test",
		label = "Worker Alpha",
		machine_hostname = "worker-01",
		machine_os = "linux",
		machine_arch = "amd64",
		hub_url = "http://127.0.0.1:8080",
		status = .Online,
		capabilities_json = "{}",
		version = "0.2.0",
		commit_sha = "796bfb57",
		build_timestamp = "2026-10-01T12:00:00Z",
		update_status = "idle",
		update_message = "",
		update_progress = 0,
		update_error = "",
		last_seen_at = "2026-10-01T12:01:00Z",
		updated_at = "2026-10-01T12:01:00Z",
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	write_bridge_json(&b, bridge, nil)
	out := strings.to_string(b)

	testing.expect(t, strings.contains(out, "\"bridge_id\":\"brg_version_test\""), "bridge_id serialized")
	testing.expect(t, strings.contains(out, "\"version\":\"0.2.0\""), "version serialized")
	testing.expect(t, strings.contains(out, "\"commit_sha\":\"796bfb57\""), "commit_sha serialized")
	testing.expect(t, strings.contains(out, "\"build_timestamp\":\"2026-10-01T12:00:00Z\""), "build_timestamp serialized")
	testing.expect(t, strings.contains(out, "\"update_status\":\"idle\""), "update_status serialized")
	testing.expect(t, strings.contains(out, "\"update_progress\":0"), "update_progress serialized")
	testing.expect(t, strings.contains(out, "\"update_error\":\"\""), "update_error serialized")
	testing.expect(t, strings.contains(out, "\"target\":\"linux-amd64\""), "target serialized")
	testing.expect(t, strings.contains(out, "\"update_available\":"), "update_available serialized")
	testing.expect(t, strings.contains(out, "\"latest_version\":"), "latest_version serialized")

	// Test with active update error
	bridge.update_status = "failed"
	bridge.update_error = "verification failed: binary crashed"
	b2 := strings.builder_make()
	defer strings.builder_destroy(&b2)

	write_bridge_json(&b2, bridge, nil)
	out2 := strings.to_string(b2)
	testing.expect(t, strings.contains(out2, "\"update_status\":\"failed\""), "update_status failed serialized")
	testing.expect(t, strings.contains(out2, "\"update_error\":\"verification failed: binary crashed\""), "update_error text serialized")
}


_http_test_id_seq: int = 0

http_test_id_generate :: proc(ctx: rawptr, prefix: string) -> string {
	_ = ctx
	seq := sync.atomic_add(&_http_test_id_seq, 1)
	return fmt.tprintf("%s%x_%x", prefix, time.to_unix_nanoseconds(time.now()), seq)
}

http_test_id_generator :: proc() -> platform.ID_Generator {
	return platform.ID_Generator{ctx = nil, generate = http_test_id_generate}
}
