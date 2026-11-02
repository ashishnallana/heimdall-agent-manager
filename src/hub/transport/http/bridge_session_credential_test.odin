package http

// A bridge WebSocket session is bound to the credential that opened it, for its
// whole lifetime (incident, 2026-10-25: a bridge whose access token had expired kept
// receiving launch_agent and PTY traffic over an already-open socket, because the
// hub authenticated the socket only at the upgrade).
//
// These drive the REAL upgrade handler and runtime loop over a loopback socket, with
// a fake hub clock for the bridge service so a token can be minted "almost expired"
// and the session's remaining life is a couple of seconds of wall time.
//
// Also here: the refresh reply round trip, hub handler -> the bridge's real decoder.

import "core:encoding/json"
import "core:fmt"
import "core:net"
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
import agent_service "odin_test:hub/service/agent"
import auth_service "odin_test:hub/service/auth"
import bridge_service "odin_test:hub/service/bridge"
import bridge_runtime_service "odin_test:hub/service/bridge_runtime"
import project_service "odin_test:hub/service/project"
import user_service "odin_test:hub/service/user"

@(private = "file")
Session_Fake_Clock :: struct {
	unix_seconds: i64, // atomic
}

@(private = "file")
session_fake_clock_now :: proc(ctx: rawptr) -> string {
	c := (^Session_Fake_Clock)(ctx)
	return platform.format_rfc3339_utc(time.Time{_nsec = sync.atomic_load(&c.unix_seconds) * 1_000_000_000})
}

@(private = "file")
Session_Fixture :: struct {
	conn:           sqlite.Conn,
	br_repo_sqlite: sqlite.Bridge_Repo_SQLite,
	us_repo_sqlite: sqlite.User_Repo_SQLite,
	ag_repo_sqlite: sqlite.Agent_Repo_SQLite,
	br_repo:        iface.Bridge_Repository,
	us_repo:        iface.User_Repository,
	ag_repo:        iface.Agent_Repository,
	real_clock:     platform.Clock,
	fake:           Session_Fake_Clock,
	hub_clock:      platform.Clock,
	ids:            platform.ID_Generator,
	br_svc:         bridge_service.Bridge_Service,
	us_svc:         user_service.User_Service,
	ag_svc:         agent_service.Agent_Service,
	auth_svc:       auth_service.Auth_Service,
	registry:       project_service.Bridge_Runtime_Registry,
	bh:             Bridge_Handlers,
	owner_user_id:  string,
	enrolled:       bridge_service.Enroll_Bridge_Result,
}

@(private = "file")
setup_session_fixture :: proc(t: ^testing.T) -> ^Session_Fixture {
	f := new(Session_Fixture)
	conn, open_ok, _ := sqlite.open(":memory:")
	testing.expect(t, open_ok, "sqlite open ok")
	f.conn = conn
	mig_ok, _ := sqlite.run_migrations(&f.conn)
	testing.expect(t, mig_ok, "migrations ok")
	f.br_repo = sqlite.new_bridge_repository(&f.br_repo_sqlite, &f.conn)
	f.us_repo = sqlite.new_user_repository(&f.us_repo_sqlite, &f.conn)
	f.ag_repo = sqlite.new_agent_repository(&f.ag_repo_sqlite, &f.conn)
	f.real_clock = platform.real_clock()
	f.fake = Session_Fake_Clock{unix_seconds = time.to_unix_seconds(time.now())}
	f.hub_clock = platform.Clock{ctx = rawptr(&f.fake), now = session_fake_clock_now}
	f.ids = http_test_id_generator()
	f.br_svc = bridge_service.new_bridge_service(&f.br_repo, &f.hub_clock, &f.ids)
	bridge_service.with_connection_closer(&f.br_svc, bridge_runtime_service.new_bridge_connection_closer(&f.registry))
	f.us_svc = user_service.new_user_service_basic(&f.us_repo, &f.real_clock, &f.ids)
	f.ag_svc = agent_service.new_agent_service(&f.ag_repo, &f.br_repo, &f.real_clock, &f.ids)
	f.auth_svc = auth_service.new_auth_service(auth_service.Auth_Config{auto_provision_users = true}, &f.us_svc)
	f.auth_svc.clock = &f.real_clock
	f.auth_svc.ids = &f.ids
	f.auth_svc.bridges = &f.br_svc
	f.auth_svc.agents = &f.ag_svc
	f.bh = Bridge_Handlers{auth = &f.auth_svc, bridges = &f.br_svc, agents = &f.ag_svc, bridge_runtime_registry = &f.registry}
	headers := http_test_login(t, &f.auth_svc, "tanmay")
	owner, owner_ok, _ := auth_service.resolve_auth_any(&f.auth_svc, auth_service.Auth_Request{remote_addr = "127.0.0.1:4444", headers = headers})
	testing.expect(t, owner_ok, "session owner resolved")
	f.owner_user_id = strings.clone(owner.user_id)
	enrolled, ok, err := bridge_service.enroll_bridge_from_device_grant(&f.br_svc, bridge_service.Device_Enroll_Input{
		owner_user_id = f.owner_user_id,
		bridge_public_key = "04aabb",
		bridge_key_fingerprint = "aaaa bbbb cccc dddd",
		machine_hostname = "session-box",
	})
	testing.expect(t, ok, err.message)
	f.enrolled = enrolled
	return f
}

@(private = "file")
teardown_session_fixture :: proc(f: ^Session_Fixture) {
	sqlite.close(&f.conn)
	delete(f.owner_user_id)
	free(f)
}

// age_token_to moves the hub clock so the fixture's access token has `seconds_left`
// of acceptance left (TTL + skew grace - elapsed).
@(private = "file")
age_token_to :: proc(f: ^Session_Fixture, seconds_left: i64) {
	sync.atomic_add(&f.fake.unix_seconds, i64(bridge_service.BRIDGE_ACCESS_TOKEN_TTL_SECONDS + bridge_service.BRIDGE_TOKEN_CLOCK_SKEW_SECONDS) - seconds_left)
}

@(private = "file")
Session_Socks :: struct {
	listener, client, hub: net.TCP_Socket,
}

@(private = "file")
session_socks :: proc(t: ^testing.T) -> Session_Socks {
	listener, _ := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	bound, _ := net.bound_endpoint(listener)
	client, _ := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	hub, _, _ := net.accept_tcp(listener)
	return Session_Socks{listener = listener, client = client, hub = hub}
}

@(private = "file")
session_masked_frame :: proc(text: string) -> [dynamic]byte {
	mask := [4]byte{0x12, 0x34, 0x56, 0x78}
	n := len(text)
	out := make([dynamic]byte)
	append(&out, 0x81)
	if n <= 125 {
		append(&out, byte(0x80 | n))
	} else {
		append(&out, byte(0x80 | 126), byte((n >> 8) & 0xff), byte(n & 0xff))
	}
	append(&out, mask[0], mask[1], mask[2], mask[3])
	for i in 0 ..< n do append(&out, text[i] ~ mask[i % 4])
	return out
}

@(private = "file")
session_send :: proc(sock: net.TCP_Socket, text: string) {
	frame := session_masked_frame(text)
	defer delete(frame)
	_, _ = net.send_tcp(sock, frame[:])
}

// Session_Stream reads hub->bridge frames. A close frame (0x88) or EOF ends it.
@(private = "file")
Session_Stream :: struct {
	sock:    net.TCP_Socket,
	pending: [dynamic]byte,
	closed:  bool, // saw a close frame or EOF
}

@(private = "file")
session_stream_next :: proc(s: ^Session_Stream, timeout: time.Duration) -> (string, bool) {
	_ = net.set_option(s.sock, .Receive_Timeout, timeout)
	for {
		if len(s.pending) >= 2 {
			opcode := s.pending[0] & 0x0f
			payload_len := int(s.pending[1] & 0x7f)
			off := 2
			if payload_len == 126 {
				if len(s.pending) < 4 do payload_len = -1
				else { payload_len = int(s.pending[2]) << 8 | int(s.pending[3]); off = 4 }
			}
			if payload_len >= 0 && len(s.pending) >= off + payload_len {
				text := strings.clone(string(s.pending[off:off + payload_len]))
				remaining := len(s.pending) - off - payload_len
				copy(s.pending[:], s.pending[off + payload_len:])
				resize(&s.pending, remaining)
				if opcode == 0x8 {
					s.closed = true
					return text, false
				}
				return text, true
			}
		}
		buf: [4096]byte
		n, err := net.recv_tcp(s.sock, buf[:])
		if err != nil do return "", false
		if n <= 0 {
			s.closed = true
			return "", false
		}
		append(&s.pending, ..buf[:n])
	}
}

@(private = "file")
Session_Runner :: struct {
	h:        ^Bridge_Handlers,
	req:      Request,
	sock:     net.TCP_Socket,
	returned: bool, // atomic: the handler (and so the session) has ended
}

@(private = "file")
session_runner_thread :: proc(data: rawptr) {
	r := (^Session_Runner)(data)
	bridge_ws_upgrade_handler(rawptr(r.h), r.req, r.sock)
	sync.atomic_store(&r.returned, true)
}

// connect opens a real bridge session with `token` and returns once bridge_ready
// arrived (its text in `ready`).
@(private = "file")
session_connect :: proc(t: ^testing.T, f: ^Session_Fixture, socks: ^Session_Socks, runner: ^Session_Runner, stream: ^Session_Stream, token: string, expected := "bridge_ready") -> (^thread.Thread, string) {
	headers := make([]contracts.HTTP_Header, 2, context.temp_allocator)
	headers[0] = {name = "Authorization", value = fmt.tprintf("Bearer %s", token)}
	headers[1] = {name = "Sec-WebSocket-Key", value = "dGhlIHNhbXBsZSBub25jZQ=="}
	runner^ = Session_Runner{h = &f.bh, sock = socks.hub, req = Request{method = "GET", path = "/api/v1/bridge-ws", headers = headers, request_id = "req_session", remote_addr = "127.0.0.1:4444"}}
	th := thread.create_and_start_with_data(rawptr(runner), session_runner_thread)
	// HTTP 101
	_ = net.set_option(socks.client, .Receive_Timeout, 2 * time.Second)
	acc := make([dynamic]byte, context.temp_allocator)
	for !strings.contains(string(acc[:]), "\r\n\r\n") {
		buf: [512]byte
		n, err := net.recv_tcp(socks.client, buf[:])
		if err != nil || n <= 0 do break
		append(&acc, ..buf[:n])
	}
	head := string(acc[:])
	if idx := strings.index(head, "\r\n\r\n"); idx >= 0 do append(&stream.pending, ..acc[idx + 4:])
	session_send(socks.client, fmt.tprintf(`{{"type":"bridge_hello","protocol_version":2,"hostname":"session-box","os":"linux","arch":"amd64","version":"1.0.0","bridge_id":"%s","capabilities":{{}}}}`, f.enrolled.bridge.bridge_id))
	for _ in 0 ..< 10 {
		text, ok := session_stream_next(stream, 2 * time.Second)
		if !ok do break
		if strings.contains(text, expected) do return th, text
		delete(text)
	}
	testing.fail_now(t, "no expected bridge session frame")
}

@(test)
test_sunset_and_revoke_notify_live_sessions_and_refuse_stale_startup :: proc(t: ^testing.T) {
    f := setup_session_fixture(t)
    defer teardown_session_fixture(f)
    replacement: bridge_service.Enroll_Bridge_Result
    {
        socks := session_socks(t)
        runner: Session_Runner
        stream := Session_Stream{sock = socks.client}
        th, ready := session_connect(t, f, &socks, &runner, &stream, f.enrolled.bridge_token)
        defer session_finish(&socks, th, &stream)
        delete(ready)
        enrolled, ok, err := bridge_service.enroll_bridge_from_device_grant(&f.br_svc, {
            owner_user_id = f.owner_user_id, bridge_public_key = "04aabb",
            pending = true, sunset_bridge_id = f.enrolled.bridge.bridge_id,
        })
        if !testing.expect(t, ok, err.message) do return
        replacement = enrolled
        found, frames := session_wait_for(&stream, BRIDGE_WS_SUNSET_PENDING_CODE, time.Second)
        defer free_frames(frames)
        testing.expect(t, found, "production closer sends temporary notice immediately, before its 60s recheck")
        for frame in frames do testing.expect(t, !strings.contains(frame, BRIDGE_WS_CREDENTIAL_REVOKED_CODE))
    }
    // Offline/restarting bridge learns suspension from the real admission path.
    {
        socks := session_socks(t)
        runner: Session_Runner
        stream := Session_Stream{sock = socks.client}
        th, refusal := session_connect(t, f, &socks, &runner, &stream, f.enrolled.bridge_token, BRIDGE_WS_SUNSET_PENDING_CODE)
        defer session_finish(&socks, th, &stream)
        defer delete(refusal)
        testing.expect(t, !strings.contains(refusal, BRIDGE_WS_CREDENTIAL_REVOKED_CODE))
    }
    _, removed, rollback_err := bridge_service.rollback_pending_enrollment(&f.br_svc, replacement.bridge.bridge_id, replacement.family_id)
    if !testing.expect(t, removed && rollback_err.code == .None) do return
    {
        socks := session_socks(t)
        runner: Session_Runner
        stream := Session_Stream{sock = socks.client}
        th, ready := session_connect(t, f, &socks, &runner, &stream, f.enrolled.bridge_token)
        defer session_finish(&socks, th, &stream)
        delete(ready)
        _, revoked, err := bridge_service.revoke_bridge(&f.br_svc, {kind = .Session, user_id = f.owner_user_id}, f.enrolled.bridge.bridge_id)
        testing.expect(t, revoked, err.message)
        found, frames := session_wait_for(&stream, BRIDGE_WS_CREDENTIAL_REVOKED_CODE, time.Second)
        defer free_frames(frames)
        testing.expect(t, found, "explicit revocation notifies before terminating the reader")
    }
    {
        socks := session_socks(t)
        runner: Session_Runner
        stream := Session_Stream{sock = socks.client}
        th, refusal := session_connect(t, f, &socks, &runner, &stream, f.enrolled.bridge_token, BRIDGE_WS_CREDENTIAL_REVOKED_CODE)
        defer session_finish(&socks, th, &stream)
        defer delete(refusal)
        testing.expect(t, !strings.contains(refusal, "bridge_ready"))
    }
}

@(test)
test_sunset_reauth_ends_session_without_waiting_for_revalidation :: proc(t: ^testing.T) {
    f := setup_session_fixture(t)
    defer teardown_session_fixture(f)
    // Model revocation on another Hub process: this session is not proactively
    // notified, and its normal 60s revalidation has not become due.
    f.br_svc.connection_closer = {}
    socks := session_socks(t)
    runner: Session_Runner
    stream := Session_Stream{sock = socks.client}
    th, ready := session_connect(t, f, &socks, &runner, &stream, f.enrolled.bridge_token)
    defer session_finish(&socks, th, &stream)
    delete(ready)
    _, ok, err := bridge_service.enroll_bridge_from_device_grant(&f.br_svc, {
        owner_user_id = f.owner_user_id, bridge_public_key = "04aabb",
        pending = true, sunset_bridge_id = f.enrolled.bridge.bridge_id,
    })
    if !testing.expect(t, ok, err.message) do return
    session_send(socks.client, fmt.tprintf(`{{"type":"bridge_reauth","access_token":"%s"}}`, f.enrolled.bridge_token))
    found, frames := session_wait_for(&stream, BRIDGE_WS_SUNSET_PENDING_CODE, time.Second)
    defer free_frames(frames)
    testing.expect(t, found)
    started := time.tick_now()
    for !sync.atomic_load(&runner.returned) && time.tick_since(started) < time.Second { time.sleep(time.Millisecond) }
    testing.expect(t, sync.atomic_load(&runner.returned), "failed reauth retires immediately, including already-buffered inbound work")
    // Directly assert the per-frame fence with a recheck deadline in the future.
    c := project_service.Bridge_Runtime_Connection{credential_revoked = true}
    next := time.tick_add(time.tick_now(), time.Hour)
    testing.expect_value(t, bridge_ws_session_check(&f.bh, &c, f.enrolled.bridge.bridge_id, socks.hub, &next), Bridge_WS_Disconnect_Reason.Credential_Revoked)
}

@(test)
test_bridge_admission_failure_only_parks_authoritative_credentials :: proc(t: ^testing.T) {
    cases := []struct {err: domain.Domain_Error, expected: string}{
        {domain.domain_error(.Internal_Error, "storage unavailable"), ""},
        {domain.domain_error(.Unauthenticated, "bridge access token has expired"), BRIDGE_WS_TOKEN_EXPIRED_CODE},
        {domain.domain_error(.Forbidden, "bridge credential is revoked"), BRIDGE_WS_CREDENTIAL_REVOKED_CODE},
        {{code = .Internal_Error, cause = BRIDGE_WS_SUNSET_PENDING_CODE, message = "pending"}, BRIDGE_WS_SUNSET_PENDING_CODE},
    }
    for c in cases {
        socks := session_socks(t)
        stream := Session_Stream{sock = socks.client}
        bridge_ws_auth_error(socks.hub, c.err)
        frame, got := session_stream_next(&stream, time.Second)
        testing.expect(t, got)
        if c.expected != "" {
            testing.expect(t, strings.contains(frame, c.expected))
        } else {
            testing.expect(t, !strings.contains(frame, BRIDGE_WS_CREDENTIAL_REVOKED_CODE))
            testing.expect(t, !strings.contains(frame, BRIDGE_WS_SUNSET_PENDING_CODE))
        }
        delete(frame)
        delete(stream.pending)
        net.close(socks.hub); net.close(socks.client); net.close(socks.listener)
    }
}

@(private = "file")
session_finish :: proc(socks: ^Session_Socks, th: ^thread.Thread, stream: ^Session_Stream) {
	_ = net.shutdown(socks.client, .Both)
	thread.join(th)
	thread.destroy(th)
	net.close(socks.client)
	net.close(socks.hub)
	net.close(socks.listener)
	delete(stream.pending)
}

// Waits for a frame containing `needle`; returns the frames seen (owned).
@(private = "file")
session_wait_for :: proc(stream: ^Session_Stream, needle: string, timeout: time.Duration) -> (found: bool, seen: [dynamic]string) {
	seen = make([dynamic]string)
	started := time.tick_now()
	for time.tick_since(started) < timeout {
		text, ok := session_stream_next(stream, timeout - time.tick_since(started))
		if !ok {
			if len(text) > 0 do append(&seen, text)
			if stream.closed do return false, seen
			continue
		}
		append(&seen, text)
		if strings.contains(text, needle) do return true, seen
	}
	return false, seen
}

@(private = "file")
free_frames :: proc(frames: [dynamic]string) {
	for f in frames do delete(f)
	delete(frames)
}

// A session whose access token expires mid-connection is closed with
// bridge_token_expired, and no command reaches it afterwards.
@(test)
test_bridge_session_is_closed_when_its_token_expires :: proc(t: ^testing.T) {
	f := setup_session_fixture(t)
	defer teardown_session_fixture(f)
	age_token_to(f, 2)
	socks := session_socks(t)
	runner: Session_Runner
	stream := Session_Stream{sock = socks.client}
	th, ready := session_connect(t, f, &socks, &runner, &stream, f.enrolled.bridge_token)
	defer session_finish(&socks, th, &stream)
	testing.expect(t, strings.contains(ready, `"credential_reauth":true`), "the hub advertises in-band renewal")
	delete(ready)

	found, frames := session_wait_for(&stream, `"bridge_token_expired"`, 6 * time.Second)
	defer free_frames(frames)
	testing.expect(t, found, "the expired session is told why it ends")
	for _ in 0 ..< 100 {
		if sync.atomic_load(&runner.returned) do break
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, sync.atomic_load(&runner.returned), "the session ended at its credential's expiry")

	// No command can be delivered to it any more.
	sent, send_err := bridge_runtime_service.send_runtime_command(rawptr(&f.registry), project_service.Runtime_Command{
		bridge_id = f.enrolled.bridge.bridge_id, command_id = "cmd_after_expiry",
		body_json = `{"type":"launch_agent","command_id":"cmd_after_expiry"}`,
	})
	testing.expect(t, !sent, "launch_agent is not dispatched to an expired session")
	testing.expect_value(t, send_err.code, domain.Error_Code.Bridge_Offline)
}

// The send-side gate on its own: a session whose bound has passed refuses every
// command before the reader has even noticed, and wakes the reader instead.
@(test)
test_expired_session_refuses_commands_before_the_reader_notices :: proc(t: ^testing.T) {
	registry: project_service.Bridge_Runtime_Registry
	socks := session_socks(t)
	defer { net.close(socks.client); net.close(socks.hub); net.close(socks.listener) }
	project_service.bridge_runtime_registry_mark_live(&registry, "brg_gate", false, "")
	project_service.bridge_runtime_registry_set_command_socket(&registry, "brg_gate", socks.hub)
	connection := project_service.bridge_runtime_connection_acquire(&registry, "brg_gate")
	project_service.bridge_runtime_connection_set_auth(connection, "btk_gate", -1)
	project_service.bridge_runtime_connection_release(&registry, connection)

	ok, err := bridge_runtime_service.send_runtime_command(rawptr(&registry), project_service.Runtime_Command{bridge_id = "brg_gate", command_id = "c1", body_json = `{"type":"launch_agent","command_id":"c1"}`})
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(err.message, "expired"), err.message)
	bin_ok, _ := bridge_runtime_service.send_runtime_binary(rawptr(&registry), "brg_gate", []byte{1, 2, 3})
	testing.expect(t, !bin_ok, "PTY input is not delivered either")
	// Nothing reached the bridge end.
	_ = net.set_option(socks.client, .Receive_Timeout, 200 * time.Millisecond)
	buf: [64]byte
	n, _ := net.recv_tcp(socks.client, buf[:])
	testing.expect(t, n <= 0, "no bytes were written to the expired session")
	// And the hub-side reader was woken: its receive side is shut down.
	_ = net.set_option(socks.hub, .Receive_Timeout, 2 * time.Second)
	m, rerr := net.recv_tcp(socks.hub, buf[:])
	testing.expect(t, m == 0 && rerr == nil, "the reader wakes to a clean EOF and closes the session itself")
}

// An inbound frame that arrives after expiry is refused, not dispatched: the
// heartbeat below would otherwise be answered with bridge_heartbeat_ack.
@(test)
test_inbound_frame_after_expiry_is_refused :: proc(t: ^testing.T) {
	f := setup_session_fixture(t)
	defer teardown_session_fixture(f)
	socks := session_socks(t)
	defer { net.close(socks.client); net.close(socks.hub); net.close(socks.listener) }
	bridge_id := f.enrolled.bridge.bridge_id
	_, generation, live_ok := project_service.bridge_runtime_registry_accept_live(&f.registry, bridge_id, false, "", f.owner_user_id)
	testing.expect(t, live_ok)
	project_service.bridge_runtime_registry_set_command_socket(&f.registry, bridge_id, socks.hub, generation)
	connection := project_service.bridge_runtime_connection_acquire(&f.registry, bridge_id, generation)
	defer project_service.bridge_runtime_connection_release(&f.registry, connection)
	project_service.bridge_runtime_connection_set_auth(connection, "btk_inbound", -1)

	// The frame is already waiting when the loop reads.
	session_send(socks.client, `{"type":"bridge_heartbeat","protocol_version":1,"active_instance_ids":[]}`)
	time.sleep(50 * time.Millisecond)
	reader := bridge_ws_reader_make(socks.hub)
	defer bridge_ws_reader_destroy(&reader)
	reader.control_context = rawptr(connection)
	bridge_ws_runtime_loop(&f.bh, bridge_id, generation, &reader)

	stream := Session_Stream{sock = socks.client}
	defer delete(stream.pending)
	found, frames := session_wait_for(&stream, `"bridge_token_expired"`, 2 * time.Second)
	defer free_frames(frames)
	testing.expect(t, found, "the session is ended with bridge_token_expired")
	for fr in frames do testing.expect(t, !strings.contains(fr, "bridge_heartbeat_ack"), "the post-expiry frame was not dispatched")
}

// A bridge that refreshes on schedule renews its live session in-band and keeps
// working past the old token's expiry: a healthy bridge is never disconnected.
@(test)
test_refreshed_session_keeps_working_after_reauth :: proc(t: ^testing.T) {
	f := setup_session_fixture(t)
	defer teardown_session_fixture(f)
	age_token_to(f, 3)
	socks := session_socks(t)
	runner: Session_Runner
	stream := Session_Stream{sock = socks.client}
	th, ready := session_connect(t, f, &socks, &runner, &stream, f.enrolled.bridge_token)
	defer session_finish(&socks, th, &stream)
	delete(ready)

	pair, ok, err := bridge_service.refresh_bridge_token(&f.br_svc, f.enrolled.refresh_token, "rrq_0123456789abcdef0123456789abcdef")
	testing.expect(t, ok, err.message)
	session_send(socks.client, fmt.tprintf(`{{"type":"bridge_reauth","access_token":"%s"}}`, pair.access_token))
	renewed, frames := session_wait_for(&stream, `"bridge_reauth_result"`, 2 * time.Second)
	defer free_frames(frames)
	testing.expect(t, renewed && strings.contains(frames[len(frames) - 1], `"ok":true`), "the refreshed credential renews the session")

	// Well past the ORIGINAL token's end: still up, still answering.
	time.sleep(4 * time.Second)
	testing.expect(t, !sync.atomic_load(&runner.returned), "the renewed session was not closed at the old expiry")
	session_send(socks.client, `{"type":"bridge_heartbeat","protocol_version":1,"active_instance_ids":[]}`)
	acked, frames2 := session_wait_for(&stream, "bridge_heartbeat_ack", 3 * time.Second)
	defer free_frames(frames2)
	testing.expect(t, acked, "the renewed session keeps working")
	for fr in frames2 do testing.expect(t, !strings.contains(fr, "bridge_token_expired"))
}

// A reauth with a credential that is not this bridge's is refused and changes
// nothing; the session still ends at its own expiry.
@(test)
test_reauth_with_a_foreign_or_bogus_token_is_refused :: proc(t: ^testing.T) {
	f := setup_session_fixture(t)
	defer teardown_session_fixture(f)
	other, o_ok, _ := bridge_service.enroll_bridge_from_device_grant(&f.br_svc, bridge_service.Device_Enroll_Input{
		owner_user_id = f.owner_user_id, bridge_public_key = "04ccdd", bridge_key_fingerprint = "cccc dddd eeee ffff", machine_hostname = "other-box",
	})
	testing.expect(t, o_ok)
	age_token_to(f, 3)
	socks := session_socks(t)
	runner: Session_Runner
	stream := Session_Stream{sock = socks.client}
	th, ready := session_connect(t, f, &socks, &runner, &stream, f.enrolled.bridge_token)
	defer session_finish(&socks, th, &stream)
	delete(ready)
	session_send(socks.client, fmt.tprintf(`{{"type":"bridge_reauth","access_token":"%s"}}`, other.bridge_token))
	_, frames := session_wait_for(&stream, `"bridge_reauth_result"`, 2 * time.Second)
	defer free_frames(frames)
	testing.expect(t, len(frames) > 0 && strings.contains(frames[len(frames) - 1], `"ok":false`), "another bridge's token cannot renew this session")
	ended, frames2 := session_wait_for(&stream, `"bridge_token_expired"`, 6 * time.Second)
	defer free_frames(frames2)
	testing.expect(t, ended, "the session still ends at its own credential's expiry")
}

// Refresh-token reuse detection revokes the family; the live session (whose access
// token is in that family) is ended promptly, not at its expiry.
@(test)
test_refresh_token_reuse_ends_the_live_session :: proc(t: ^testing.T) {
	f := setup_session_fixture(t)
	defer teardown_session_fixture(f)
	socks := session_socks(t)
	runner: Session_Runner
	stream := Session_Stream{sock = socks.client}
	th, ready := session_connect(t, f, &socks, &runner, &stream, f.enrolled.bridge_token)
	defer session_finish(&socks, th, &stream)
	delete(ready)
	_, ok, err := bridge_service.refresh_bridge_token(&f.br_svc, f.enrolled.refresh_token)
	testing.expect(t, ok, err.message)
	sync.atomic_add(&f.fake.unix_seconds, i64(bridge_service.BRIDGE_REFRESH_REUSE_GRACE_SECONDS + 5))
	_, replay_ok, _ := bridge_service.refresh_bridge_token(&f.br_svc, f.enrolled.refresh_token)
	testing.expect(t, !replay_ok, "the replayed token is refused")
	for _ in 0 ..< 150 {
		if sync.atomic_load(&runner.returned) do break
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, sync.atomic_load(&runner.returned), "reuse detection tore the live session down")
}

// Any other revocation of the session's token (here, the family revoked directly,
// with no closer involved) is caught by the reader's periodic re-check.
@(test)
test_revoked_family_is_caught_by_the_session_recheck :: proc(t: ^testing.T) {
	f := setup_session_fixture(t)
	defer teardown_session_fixture(f)
	bridge_ws_revalidate_interval = 300 * time.Millisecond
	socks := session_socks(t)
	runner: Session_Runner
	stream := Session_Stream{sock = socks.client}
	th, ready := session_connect(t, f, &socks, &runner, &stream, f.enrolled.bridge_token)
	defer session_finish(&socks, th, &stream)
	delete(ready)
	_, revoked_ok, _ := iface.bridge_revoke_token_family(&f.br_repo, f.enrolled.family_id, platform.clock_now(&f.hub_clock))
	testing.expect(t, revoked_ok)
	found, frames := session_wait_for(&stream, `"bridge_credential_revoked"`, 3 * time.Second)
	defer free_frames(frames)
	testing.expect(t, found, "the revoked session is told why it ends")
}

// ===== Refresh reply: typed marshal, decoded by the bridge's real decoder =====

@(test)
test_refresh_reply_round_trips_through_the_bridge_decoder :: proc(t: ^testing.T) {
	f := setup_session_fixture(t)
	defer teardown_session_fixture(f)
	headers := make([]contracts.HTTP_Header, 1, context.temp_allocator)
	headers[0] = {name = "Authorization", value = fmt.tprintf("Bearer %s", f.enrolled.refresh_token)}
	resp := bridge_refresh_handler(rawptr(&f.bh), Request{method = "POST", path = "/api/v1/device/bridge-refresh", body = "{}", headers = headers, request_id = "req_rt"})
	testing.expect_value(t, resp.status, 200)
	data, problem := contracts.bridge_token_response_decode_checked(resp.body)
	testing.expect_value(t, problem, "")
	testing.expect(t, strings.has_prefix(data.access_token, "hba_") && strings.contains(data.access_token, "."), "a usable access token")
	testing.expect(t, strings.has_prefix(data.refresh_token, "hbf_") && strings.contains(data.refresh_token, "."), "a usable refresh token")
	testing.expect_value(t, data.bridge_id, f.enrolled.bridge.bridge_id)
	testing.expect_value(t, data.expires_in, bridge_service.BRIDGE_ACCESS_TOKEN_TTL_SECONDS)
	testing.expect(t, data.refresh_expires_in > 0)
	// Byte-compatible field order with what 0.4.x / 0.5.x bridges parse.
	order := [?]string{`"access_token":`, `"refresh_token":`, `"bridge_id":`, `"token_type":"Bearer"`, `"expires_in":`, `"refresh_expires_in":`}
	last := -1
	for key in order {
		idx := strings.index(resp.body, key)
		testing.expectf(t, idx > last, "%s in wire order", key)
		last = idx
	}
	_, verify_ok, verify_err := bridge_service.verify_bridge_token(&f.br_svc, data.access_token)
	testing.expect(t, verify_ok, verify_err.message)
}

// Non-secret fields with characters that need escaping still produce valid JSON that
// the bridge decodes exactly (the old hand-built writers made this a per-site risk).
@(test)
test_typed_credential_replies_escape_non_secret_fields :: proc(t: ^testing.T) {
	odd := "brg_\"quoted\"\\back\nline\u2028</script>"
	resp := respond_success_typed(contracts.Bridge_Refresh_Reply{
		access_token = "hba_btk_1.s", refresh_token = "hbf_btk_2.s", bridge_id = odd, token_type = "Bearer", expires_in = 3600, refresh_expires_in = 60,
	}, "req_\"id", "")
	data, problem := contracts.bridge_token_response_decode_checked(resp.body)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, data.bridge_id, odd)
	testing.expect_value(t, data.access_token, "hba_btk_1.s")

	logout := respond_success_typed(Auth_Logout_Reply{logout_url = `https://idp.example/logout?x="1"&y=\`}, "r", "")
	envelope: struct { data: Auth_Logout_Reply }
	testing.expect(t, json.unmarshal_string(logout.body, &envelope, json.Specification.JSON, context.temp_allocator) == nil, "logout reply is valid JSON")
	testing.expect_value(t, envelope.data.logout_url, `https://idp.example/logout?x="1"&y=\`)
	ticket := respond_success_typed(User_WS_Ticket_Reply{ticket = "uwst_abc", expires_in = 30}, "r", "")
	testing.expect(t, strings.contains(ticket.body, `"data":{"ticket":"uwst_abc","expires_in":30}`), ticket.body)
}

// ===== POST /api/v1/bridge/self/revoke (audit F1: account replace) =====

// A bridge revokes ITSELF with its own access token; nothing else revokes through
// this route: no token and a refresh-kind token are refused, and a revoked token gets 401/403.
@(test)
test_bridge_self_revoke_uses_the_bridges_own_access_token :: proc(t: ^testing.T) {
	// Handlers and the revoke's repository reads allocate on the per-request arena
	// in production; mirror that so the leak tracker does not report them.
	context.allocator = context.temp_allocator
	f := setup_session_fixture(t)
	defer teardown_session_fixture(f)
	self_revoke := proc(f: ^Session_Fixture, bearer: string) -> Response {
		headers := make([dynamic]contracts.HTTP_Header, context.temp_allocator)
		if bearer != "" do append(&headers, contracts.HTTP_Header{name = "Authorization", value = fmt.tprintf("Bearer %s", bearer)})
		return bridge_self_revoke_handler(rawptr(&f.bh), Request{method = "POST", path = "/api/v1/bridge/self/revoke", body = "{}", headers = headers[:], request_id = "req_self_revoke"})
	}
	testing.expect_value(t, self_revoke(f, "").status, 401)
	refresh_resp := self_revoke(f, f.enrolled.refresh_token)
	testing.expectf(t, refresh_resp.status == 401 || refresh_resp.status == 403, "a refresh token cannot revoke (got %d)", refresh_resp.status)
	_, still_ok, _ := bridge_service.verify_bridge_token(&f.br_svc, f.enrolled.bridge_token)
	testing.expect(t, still_ok, "the refused attempts left the bridge enrolled")

	testing.expect_value(t, self_revoke(f, f.enrolled.bridge_token).status, 200)
	_, revoked_ok, _ := bridge_service.verify_bridge_token(&f.br_svc, f.enrolled.bridge_token)
	testing.expect(t, !revoked_ok, "the bridge's credential is dead after its self-revoke")
	// Already revoked: refused (the bridge client counts 401/403 as "revoked").
	again := self_revoke(f, f.enrolled.bridge_token)
	testing.expectf(t, again.status == 401 || again.status == 403, "a revoked token is refused (got %d)", again.status)
}

// Force the existing session to observe suspension via periodic revalidation,
// rather than admission's immediate socket closer. This is also the multi-hub path.
@(test)
test_pending_sunset_session_recheck_is_recoverable_and_rollback_reconnects :: proc(t: ^testing.T) {
    f := setup_session_fixture(t)
    defer teardown_session_fixture(f)
    old_interval := bridge_ws_revalidate_interval
    bridge_ws_revalidate_interval = 50 * time.Millisecond
    defer { bridge_ws_revalidate_interval = old_interval }
    f.br_svc.connection_closer = {}
    replacement: bridge_service.Enroll_Bridge_Result
    {
        socks := session_socks(t)
        runner: Session_Runner
        stream := Session_Stream{sock = socks.client}
        th, ready := session_connect(t, f, &socks, &runner, &stream, f.enrolled.bridge_token)
        defer session_finish(&socks, th, &stream)
        delete(ready)
        enrolled, ok, err := bridge_service.enroll_bridge_from_device_grant(&f.br_svc, {
            owner_user_id = f.owner_user_id, bridge_public_key = "04aabb",
            pending = true, sunset_bridge_id = f.enrolled.bridge.bridge_id,
        })
        if !testing.expect(t, ok, err.message) do return
        replacement = enrolled
        found, frames := session_wait_for(&stream, `"bridge_sunset_pending"`, 3 * time.Second)
        defer free_frames(frames)
        testing.expect(t, found, "temporary retirement has a recoverable session code")
        for frame in frames do testing.expect(t, !strings.contains(frame, BRIDGE_WS_CREDENTIAL_REVOKED_CODE), "no terminal revocation frame")
    }
    _, removed, rollback_err := bridge_service.rollback_pending_enrollment(&f.br_svc, replacement.bridge.bridge_id, replacement.family_id)
    if !testing.expect(t, removed && rollback_err.code == .None) do return
    socks := session_socks(t)
    runner: Session_Runner
    stream := Session_Stream{sock = socks.client}
    th, ready := session_connect(t, f, &socks, &runner, &stream, f.enrolled.bridge_token)
    defer session_finish(&socks, th, &stream)
    defer delete(ready)
    testing.expect(t, strings.contains(ready, "bridge_ready"), "same credential reconnects after rollback")
}


// Exercise the helper used by the signed vault-device revoke handler. A durable
// sunset receipt must not turn an explicit credential kill back into suspension.
@(test)
test_vault_revoke_sunset_bridge_cannot_be_restored_by_replacement_rollback :: proc(t: ^testing.T) {
	f := setup_session_fixture(t)
	defer teardown_session_fixture(f)
	replacement, enrolled_ok, enroll_err := bridge_service.enroll_bridge_from_device_grant(&f.br_svc, {
		owner_user_id = f.owner_user_id, bridge_public_key = "04ccdd",
		pending = true, sunset_bridge_id = f.enrolled.bridge.bridge_id,
	})
	if !testing.expect(t, enrolled_ok, enroll_err.message) do return
	_, suspended_ok, suspended_err := bridge_service.verify_bridge_token(&f.br_svc, f.enrolled.bridge_token)
	testing.expect(t, !suspended_ok && suspended_err.code == .Internal_Error, "receipt initially suspends credentials")
	auth := contracts.Auth_Context{kind = .Internal_User, user_id = f.owner_user_id}
	revoke_err := vault_revoke_bridge_credentials(&f.br_svc, auth, f.enrolled.bridge.bridge_id)
	if !testing.expect(t, revoke_err.code == .None, revoke_err.message) do return
	// The fake clock never advanced: this also catches same-second revocation.
	again := vault_revoke_bridge_credentials(&f.br_svc, auth, f.enrolled.bridge.bridge_id)
	testing.expect(t, again.code == .None, "explicit revocation is idempotent")
	_, removed, rollback_err := bridge_service.rollback_pending_enrollment(&f.br_svc, replacement.bridge.bridge_id, replacement.family_id)
	if !testing.expect(t, removed && rollback_err.code == .None, rollback_err.message) do return
	old, found, get_err := iface.bridge_get_bridge(&f.br_repo, f.enrolled.bridge.bridge_id)
	defer if found do domain.bridge_destroy(&old)
	testing.expect(t, found && get_err.code == .None && old.status == .Revoked, "vault-revoked bridge stays revoked")
	_, access_ok, access_err := bridge_service.verify_bridge_token(&f.br_svc, f.enrolled.bridge_token)
	testing.expect(t, !access_ok && access_err.code == .Forbidden, "old access credential remains finally revoked")
	_, refresh_ok, refresh_err := bridge_service.refresh_bridge_token(&f.br_svc, f.enrolled.refresh_token)
	testing.expect(t, !refresh_ok && refresh_err.code == .Unauthenticated, "old refresh credential cannot resume")
}
