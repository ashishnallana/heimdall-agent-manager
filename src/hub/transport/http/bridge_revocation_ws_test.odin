package http

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import auth_service "odin_test:hub/service/auth"
import bridge_service "odin_test:hub/service/bridge"
import bridge_runtime_service "odin_test:hub/service/bridge_runtime"
import project_service "odin_test:hub/service/project"
import user_service "odin_test:hub/service/user"

// REQ-IMPL-3 / audit finding F6: REVOCATION MUST TERMINATE AN IN-FLIGHT WEBSOCKET.
//
// WHY A REAL SOCKET AND A REAL BLOCKED READER, rather than asserting that a mock
// closer was invoked. F6 is precisely the class of bug where the bookkeeping is all
// correct and the connection stays up anyway: `revoke_bridge` already flipped
// `bridges.status` to revoked, and a reviewer reading that code would reasonably
// conclude the bridge was cut off. It was not. A test that asserts "the seam was
// called" re-creates exactly that mistake one layer up — it proves the Hub INTENDED
// to close the socket.
//
// So this test reproduces the production shape: a loopback TCP pair stands in for
// the bridge's control connection, the hub end is registered in the runtime registry
// the way bridge_ws_upgrade_handler registers it, and a second thread parks in a
// blocking read on it exactly as bridge_ws_runtime_loop does. The assertion is about
// the SOCKET: the parked read must return promptly because the connection was torn
// down, not at its own deadline.
//
// WHY THE DEADLINE NUMBERS ARE WHAT THEY ARE. Production parks with a 120s receive
// timeout; using that here would make a FAILING test hang for two minutes. The
// reader's own timeout is therefore 10s — long enough that returning inside it can
// only be a teardown and not the deadline — while the assertion window is 3s. A
// revocation that works returns in microseconds; the gap exists for a loaded CI box,
// not because any part of this is expected to take seconds.

@(private = "file")
revocation_test_counter: int = 0

@(private = "file")
Revocation_Fixture :: struct {
	db_path:        string,
	conn:           sqlite.Conn,
	br_repo_sqlite: sqlite.Bridge_Repo_SQLite,
	us_repo_sqlite: sqlite.User_Repo_SQLite,
	br_repo:        iface.Bridge_Repository,
	us_repo:        iface.User_Repository,
	clock:          platform.Clock,
	ids:            platform.ID_Generator,
	br_svc:         bridge_service.Bridge_Service,
	us_svc:         user_service.User_Service,
	auth_svc:       auth_service.Auth_Service,
	registry:       project_service.Bridge_Runtime_Registry,
	owner_user_id:  string,
}

@(private = "file")
REVOCATION_TEST_HEADERS := [1]contracts.HTTP_Header{
	{name = "X-authentik-username", value = "tanmay"},
}

@(private = "file")
REVOCATION_TEST_CIDRS := [1]string{"127.0.0.1/32"}

// setup_revocation_fixture builds the real service graph slice this test needs:
// sqlite (so the token rows and the bridge row are genuinely persisted), the bridge
// service with the PRODUCTION connection-closer seam
// (bridge_runtime_service.new_bridge_connection_closer — the same constructor
// wiring.odin calls), and a runtime registry.
@(private = "file")
setup_revocation_fixture :: proc(t: ^testing.T, tag: string) -> ^Revocation_Fixture {
	f := new(Revocation_Fixture)
	seq := sync.atomic_add(&revocation_test_counter, 1)
	f.db_path = ":memory:"
	

	conn, open_ok, _ := sqlite.open(f.db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	f.conn = conn
	mig_ok, mig_err := sqlite.run_migrations(&f.conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	f.br_repo = sqlite.new_bridge_repository(&f.br_repo_sqlite, &f.conn)
	f.us_repo = sqlite.new_user_repository(&f.us_repo_sqlite, &f.conn)
	f.clock = platform.real_clock()
	f.ids = http_test_id_generator()
	f.br_svc = bridge_service.new_bridge_service(&f.br_repo, &f.clock, &f.ids)
	bridge_service.with_connection_closer(&f.br_svc, bridge_runtime_service.new_bridge_connection_closer(&f.registry))
	f.us_svc = user_service.new_user_service_basic(&f.us_repo, &f.clock, &f.ids)
	f.auth_svc = auth_service.new_auth_service(auth_service.Trusted_Proxy_Config{
		username_header = "X-authentik-username",
		trusted_proxy_cidrs = REVOCATION_TEST_CIDRS[:],
		auto_provision_users = true,
	}, &f.us_svc)
	f.auth_svc.clock = &f.clock
	f.auth_svc.ids = &f.ids
	f.auth_svc.bridges = &f.br_svc

	owner_ctx, owner_ok, _ := auth_service.resolve_auth_any(&f.auth_svc, auth_service.Auth_Request{
		remote_addr = "127.0.0.1:4444",
		headers = REVOCATION_TEST_HEADERS[:],
	})
	testing.expect(t, owner_ok, "trusted proxy owner resolved")
	f.owner_user_id = strings.clone(owner_ctx.user_id)
	return f
}

@(private = "file")
teardown_revocation_fixture :: proc(f: ^Revocation_Fixture) {
	if f == nil do return
	sqlite.close(&f.conn)
	
	if len(f.owner_user_id) > 0 do delete(f.owner_user_id)
	free(f)
}

// enroll_device_bridge enrols a bridge through the device-grant path, which is the
// path that issues the REQ-IMPL-3 expiring pair.
@(private = "file")
enroll_device_bridge :: proc(t: ^testing.T, f: ^Revocation_Fixture, hostname: string) -> bridge_service.Enroll_Bridge_Result {
	result, ok, err := bridge_service.enroll_bridge_from_device_grant(&f.br_svc, bridge_service.Device_Enroll_Input{
		owner_user_id = f.owner_user_id,
		bridge_public_key = "04aabb",
		bridge_key_fingerprint = "aaaa bbbb cccc dddd",
		os_user = "tanmay",
		machine_hostname = hostname,
		machine_os = "linux",
	})
	testing.expect(t, ok, err.message)
	return result
}

@(private = "file")
Reader_Job :: struct {
	socket:     net.TCP_Socket,
	returned:   bool,
	bytes_read: int,
}

// parked_reader mirrors bridge_ws_runtime_loop's posture: one blocking read with a
// deadline, on the socket the registry holds. It records how long it was parked.
@(private = "file")
parked_reader :: proc(job: rawptr) {
	j := (^Reader_Job)(job)
	_ = net.set_option(j.socket, .Receive_Timeout, 10 * time.Second)
	buf: [256]byte
	n, _ := net.recv_tcp(j.socket, buf[:])
	j.bytes_read = n
	// Published LAST and atomically: the waiting test reads `returned` to decide the
	// read is over, so anything it then reads must already be written.
	sync.atomic_store(&j.returned, true)
}

// REQ-IMPL-3 AC: "Revocation terminates a live WebSocket."
@(test)
test_revoke_bridge_terminates_live_websocket :: proc(t: ^testing.T) {
	f := setup_revocation_fixture(t, "live_ws")
	defer teardown_revocation_fixture(f)

	enrolled := enroll_device_bridge(t, f, "revoke-me")
	bridge_id := strings.clone(enrolled.bridge.bridge_id)
	defer delete(bridge_id)
	access_token := strings.clone(enrolled.bridge_token)
	defer delete(access_token)

	// The credential works before revocation. Asserted so a later failure cannot be
	// mistaken for "the credential never worked".
	_, pre_ok, _ := bridge_service.verify_bridge_token(&f.br_svc, access_token)
	testing.expect(t, pre_ok, "the access token authenticates before revocation")

	// --- stand up the "live connection" exactly as the upgrade handler does ---
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if listen_err != nil do testing.fail_now(t, "could not listen on loopback")
	bound, bound_err := net.bound_endpoint(listener)
	if bound_err != nil {
		net.close(listener)
		testing.fail_now(t, "could not read the bound endpoint")
	}
	bridge_end, dial_err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	if dial_err != nil {
		net.close(listener)
		testing.fail_now(t, "could not dial loopback")
	}
	hub_end, _, accept_err := net.accept_tcp(listener)
	if accept_err != nil {
		net.close(listener)
		net.close(bridge_end)
		testing.fail_now(t, "could not accept on loopback")
	}
	defer {
		net.close(hub_end)
		net.close(bridge_end)
		net.close(listener)
	}
	project_service.bridge_runtime_registry_mark_live(&f.registry, bridge_id, false, "")
	project_service.bridge_runtime_registry_set_command_socket(&f.registry, bridge_id, hub_end)

	job := Reader_Job{socket = hub_end}
	reader := thread.create_and_start_with_data(rawptr(&job), parked_reader)
	defer thread.destroy(reader)
	// Let the reader actually reach its blocking read before revoking. Without this
	// the test could pass by racing — revoking before anything was parked — which
	// would prove nothing about an IN-FLIGHT connection.
	time.sleep(20 * time.Millisecond)
	testing.expect(t, !sync.atomic_load(&job.returned), "the reader is parked in a blocking read before revocation")

	owner_auth := contracts.Auth_Context{kind = .User_Token, user_id = f.owner_user_id}
	revoked, revoke_ok, revoke_err := bridge_service.revoke_bridge(&f.br_svc, owner_auth, bridge_id)
	testing.expect(t, revoke_ok, revoke_err.message)
	testing.expect_value(t, revoked.status, domain.Bridge_Status.Revoked)

	// THE ACTUAL F6 ASSERTION: the parked read returned because the connection was
	// torn down, well inside its own 10s deadline.
	deadline := time.now()
	for time.duration_seconds(time.since(deadline)) < 3 {
		if sync.atomic_load(&job.returned) do break
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, sync.atomic_load(&job.returned), "revocation tore down the live bridge socket (F6): the parked read returned")
	testing.expect(t, job.bytes_read == 0, "the torn-down read delivered no payload")

	// And the credentials are dead, so a reconnect cannot re-authenticate: the two
	// halves of revocation, both required. Either alone leaves a hole — a closed
	// socket with live credentials just reconnects, and dead credentials with a live
	// socket is F6 itself.
	_, post_ok, post_err := bridge_service.verify_bridge_token(&f.br_svc, access_token)
	testing.expect(t, !post_ok, "the access token no longer authenticates after revocation")
	testing.expect(t, post_err.code == .Forbidden, "a revoked credential is rejected as forbidden, not as merely invalid")
	_, refresh_ok, _ := bridge_service.refresh_bridge_token(&f.br_svc, enrolled.refresh_token)
	testing.expect(t, !refresh_ok, "a revoked bridge cannot refresh its way back in")
}

// REQ-IMPL-3 AC: "Revoking bridge A leaves bridge B of the same user working."
//
// PER-MACHINE REVOCATION IS THE WHOLE POINT OF A PER-MACHINE CREDENTIAL (§11.7). The
// failure this guards against is not hypothetical: the pre-existing device-token
// minter issues USER tokens whose only identity is the owner, so "revoke that
// machine" had no meaning for them. This asserts both directions — A dies, B lives —
// and does it with TWO LIVE SOCKETS, because a teardown that walked the registry
// instead of matching one bridge_id would pass a single-socket test.
@(test)
test_revoke_one_bridge_leaves_the_others_connected :: proc(t: ^testing.T) {
	f := setup_revocation_fixture(t, "isolation")
	defer teardown_revocation_fixture(f)

	a := enroll_device_bridge(t, f, "host-a")
	a_id := strings.clone(a.bridge.bridge_id); defer delete(a_id)
	a_token := strings.clone(a.bridge_token); defer delete(a_token)
	b := enroll_device_bridge(t, f, "host-b")
	b_id := strings.clone(b.bridge.bridge_id); defer delete(b_id)
	b_token := strings.clone(b.bridge_token); defer delete(b_token)
	b_refresh := strings.clone(b.refresh_token); defer delete(b_refresh)
	testing.expect(t, a_id != b_id, "two enrolments are two distinct bridges")

	listener, _ := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	bound, _ := net.bound_endpoint(listener)
	a_bridge_end, _ := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	a_hub_end, _, _ := net.accept_tcp(listener)
	b_bridge_end, _ := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	b_hub_end, _, _ := net.accept_tcp(listener)
	defer {
		net.close(a_hub_end); net.close(a_bridge_end)
		net.close(b_hub_end); net.close(b_bridge_end)
		net.close(listener)
	}
	project_service.bridge_runtime_registry_mark_live(&f.registry, a_id, false, "")
	project_service.bridge_runtime_registry_set_command_socket(&f.registry, a_id, a_hub_end)
	project_service.bridge_runtime_registry_mark_live(&f.registry, b_id, false, "")
	project_service.bridge_runtime_registry_set_command_socket(&f.registry, b_id, b_hub_end)

	a_job := Reader_Job{socket = a_hub_end}
	b_job := Reader_Job{socket = b_hub_end}
	a_reader := thread.create_and_start_with_data(rawptr(&a_job), parked_reader)
	defer thread.destroy(a_reader)
	b_reader := thread.create_and_start_with_data(rawptr(&b_job), parked_reader)
	defer thread.destroy(b_reader)
	time.sleep(20 * time.Millisecond)

	owner_auth := contracts.Auth_Context{kind = .User_Token, user_id = f.owner_user_id}
	_, revoke_ok, revoke_err := bridge_service.revoke_bridge(&f.br_svc, owner_auth, a_id)
	testing.expect(t, revoke_ok, revoke_err.message)

	started := time.now()
	for time.duration_seconds(time.since(started)) < 3 {
		if sync.atomic_load(&a_job.returned) do break
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, sync.atomic_load(&a_job.returned), "bridge A's socket was torn down")
	// B's reader must still be parked. This is the assertion that would catch a
	// teardown that closed every socket in the registry.
	testing.expect(t, !sync.atomic_load(&b_job.returned), "bridge B's socket is untouched by A's revocation")

	_, a_auth_ok, _ := bridge_service.verify_bridge_token(&f.br_svc, a_token)
	testing.expect(t, !a_auth_ok, "bridge A's credential is dead")
	b_ctx, b_auth_ok, b_err := bridge_service.verify_bridge_token(&f.br_svc, b_token)
	testing.expect(t, b_auth_ok, b_err.message)
	testing.expect_value(t, b_ctx.bridge_id, b_id)
	// B can still rotate: revoking A must not have touched B's token family.
	pair, b_refresh_ok, b_refresh_err := bridge_service.refresh_bridge_token(&f.br_svc, b_refresh)
	testing.expect(t, b_refresh_ok, b_refresh_err.message)
	testing.expect_value(t, pair.bridge_id, b_id)
}

// A bridge that is NOT connected must still revoke cleanly. The closer reports
// "nothing to close" and that is a normal outcome, not an error — a revocation that
// failed because the machine happened to be offline would be the worst possible
// time for it to fail.
@(test)
test_revoke_offline_bridge_succeeds_without_a_socket :: proc(t: ^testing.T) {
	f := setup_revocation_fixture(t, "offline")
	defer teardown_revocation_fixture(f)

	enrolled := enroll_device_bridge(t, f, "offline-host")
	bridge_id := strings.clone(enrolled.bridge.bridge_id); defer delete(bridge_id)
	owner_auth := contracts.Auth_Context{kind = .User_Token, user_id = f.owner_user_id}
	revoked, ok, err := bridge_service.revoke_bridge(&f.br_svc, owner_auth, bridge_id)
	testing.expect(t, ok, err.message)
	testing.expect_value(t, revoked.status, domain.Bridge_Status.Revoked)
	testing.expect(t, !project_service.bridge_runtime_registry_shutdown_command_socket(&f.registry, bridge_id), "an unconnected bridge has no socket to shut down")
}

// REQ-ENROLL-15: NO BARE BRIDGE TOKEN OF ANY SHAPE IS ACCEPTED ON A SHARED ENDPOINT.
//
// THIS TEST IS THE INVERSION OF AN EARLIER ONE, and the inversion is the point.
//
// It used to be `test_expiring_access_token_is_not_accepted_as_a_bare_token_in_
// monitor_mode`, and it asserted a CONTRAST: a bare `hba_` was refused, while a bare
// legacy `hbr_` was ACCEPTED — because `resolve_auth_any` carried an allowance gated
// on the permissive bridge-auth mode, which was the enum's zero value and the shipped
// deploy default. REQ-IMPL-3 wrote that test to stop the new credential inheriting
// the concession; the concession itself was left for REQ-IMPL-6 because deleting it
// while the deleted enrollment flow still minted legacy tokens would have locked out deployed
// bridges.
//
// REQ-IMPL-6 deleted the flow, the credential and the allowance, so the old
// assertion now states the opposite of the intended behaviour. It is inverted rather
// than deleted: the `hbr_` half is the half that regressed, so asserting its REFUSAL
// is more valuable than asserting the `hba_` refusal alone — which is all that would
// be left if the contrast were dropped.
//
// Note the legacy token is built as a literal string. Nothing mints an `hbr_` any
// more, which is itself part of the property: the only way such a credential reaches
// the Hub now is from an old config file or an attacker, and both must be refused.
@(test)
test_no_bare_bridge_token_is_accepted_on_a_shared_endpoint :: proc(t: ^testing.T) {
	f := setup_revocation_fixture(t, "bare_token")
	defer teardown_revocation_fixture(f)

	// A device-enrolled bridge: expiring `hba_` pair.
	modern := enroll_device_bridge(t, f, "modern-host")
	modern_headers := [1]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", modern.bridge_token}, context.temp_allocator)}}
	_, modern_ok, _ := auth_service.resolve_auth_any(&f.auth_svc, auth_service.Auth_Request{
		remote_addr = "127.0.0.1:4444",
		headers = modern_headers[:],
	})
	testing.expect(t, !modern_ok, "a bare hba_ is refused on a shared endpoint")

	// THE INVERTED ASSERTION. A legacy-shaped `hbr_` credential naming a REAL bridge
	// id — the most favourable case for the deleted allowance, since the old code
	// path looked the row up by exactly this id — is refused. Previously this
	// authenticated and returned a Bridge_Token context for that bridge.
	legacy_token := strings.concatenate({"hbr_", modern.bridge.bridge_id, ".", REVOCATION_TEST_FAKE_SECRET}, context.temp_allocator)
	legacy_headers := [1]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", legacy_token}, context.temp_allocator)}}
	legacy_ctx, legacy_auth_ok, _ := auth_service.resolve_auth_any(&f.auth_svc, auth_service.Auth_Request{
		remote_addr = "127.0.0.1:4444",
		headers = legacy_headers[:],
	})
	testing.expect(t, !legacy_auth_ok, "a bare legacy hbr_ is refused on a shared endpoint (the monitor allowance is gone)")
	// Assert the CONTEXT is empty too, not merely that ok is false: a caller that
	// ignores ok must not find a usable bridge identity sitting in the struct.
	testing.expect_value(t, legacy_ctx.bridge_id, "")
	testing.expect_value(t, legacy_ctx.user_id, "")

	// The refresh token is refused everywhere, including here.
	refresh_headers := [1]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", modern.refresh_token}, context.temp_allocator)}}
	_, refresh_ok, _ := auth_service.resolve_auth_any(&f.auth_svc, auth_service.Auth_Request{
		remote_addr = "127.0.0.1:4444",
		headers = refresh_headers[:],
	})
	testing.expect(t, !refresh_ok, "a refresh token authenticates nothing on a shared endpoint")
}

// REVOCATION_TEST_FAKE_SECRET is a syntactically valid credential secret (64 hex
// chars, the shape issue_credential produces) that was never issued. Using a
// well-formed secret matters: a malformed one could be refused by the credential
// SPLIT before any authorization decision is reached, which would make a test pass
// for the wrong reason.
REVOCATION_TEST_FAKE_SECRET :: "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
