package http

import "core:testing"
import "base:runtime"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import auth_service "odin_test:hub/service/auth"
import bridge_service "odin_test:hub/service/bridge"
import bridge_runtime "odin_test:hub/service/bridge_runtime"
import project "odin_test:hub/service/project"
import user_service "odin_test:hub/service/user"
import vault "odin_test:lib/vault"
import ws "odin_test:lib/ws"

@(test)
task_chain_search_relay_command_preserves_opaque_envelope_and_correlation :: proc(t: ^testing.T) {
	envelope := `search:v2:e4:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==`
	body := task_chain_search_command_json("cmd_one", "brg_one", "usr_one", "req_one", 1900000000000, envelope)
	defer delete(body)
	testing.expect_value(t, json_string(body, "type", context.temp_allocator), "task_chain_search")
	testing.expect_value(t, json_string(body, "command_id", context.temp_allocator), "cmd_one")
	testing.expect_value(t, json_string(body, "bridge_id", context.temp_allocator), "brg_one")
	testing.expect_value(t, json_string(body, "owner_user_id", context.temp_allocator), "usr_one")
	testing.expect_value(t, json_string(body, "request_id", context.temp_allocator), "req_one")
	testing.expect_value(t, json_string(body, "envelope", context.temp_allocator), envelope)
	testing.expect_value(t, json_int(body, "expires_at_ms", 0), 1900000000000)
}

// These tests call the authenticated production handler, not just its serializer.
// All DBs, identities, keys and sockets are disposable fixtures. The peer below
// stands in for the separate package-main Bridge; it uses the real v2 crypto and
// the runtime's connection-scoped result admission, without a production keyring.
@(private = "file")
Search_Relay_Fixture :: struct {
	conn: sqlite.Conn,
	br_impl: sqlite.Bridge_Repo_SQLite,
	us_impl: sqlite.User_Repo_SQLite,
	br_repo: iface.Bridge_Repository,
	us_repo: iface.User_Repository,
	clock: platform.Clock,
	ids: platform.ID_Generator,
	bridges: bridge_service.Bridge_Service,
	users: user_service.User_Service,
	auth: auth_service.Auth_Service,
	registry: project.Bridge_Runtime_Registry,
	h: Bridge_Handlers,
	owner, bridge_id: string,
	generation: int,
}

@(private = "file")
SEARCH_HEADERS := [1]contracts.HTTP_Header{{name = "X-authentik-username", value = "search_fixture_owner"}}
@(private = "file")
SEARCH_CIDRS := [1]string{"127.0.0.1/32"}

@(private = "file")
search_relay_fixture :: proc(t: ^testing.T) -> ^Search_Relay_Fixture {
	f := new(Search_Relay_Fixture)
	conn, opened, _ := sqlite.open(":memory:")
	if !opened do testing.fail_now(t, "fixture DB open")
	f.conn = conn
	migrated, _ := sqlite.run_migrations(&f.conn)
	if !migrated do testing.fail_now(t, "fixture migrations")
	f.br_repo = sqlite.new_bridge_repository(&f.br_impl, &f.conn)
	f.us_repo = sqlite.new_user_repository(&f.us_impl, &f.conn)
	f.clock = platform.real_clock()
	f.ids = http_test_id_generator()
	f.bridges = bridge_service.new_bridge_service(&f.br_repo, &f.clock, &f.ids)
	f.users = user_service.new_user_service_basic(&f.us_repo, &f.clock, &f.ids)
	f.auth = auth_service.new_auth_service({username_header = "X-authentik-username", trusted_proxy_cidrs = SEARCH_CIDRS[:], auto_provision_users = true}, &f.users)
	f.auth.clock, f.auth.ids, f.auth.bridges = &f.clock, &f.ids, &f.bridges
	owner, authenticated, _ := auth_service.resolve_auth_any(&f.auth, {remote_addr = "127.0.0.1:4444", headers = SEARCH_HEADERS[:]})
	if !authenticated do testing.fail_now(t, "fixture owner authentication")
	f.owner = strings.clone(owner.user_id)
	enrolled, enrolled_ok, _ := bridge_service.enroll_bridge_from_device_grant(&f.bridges, {owner_user_id = f.owner, bridge_public_key = "04aabb", bridge_key_fingerprint = "fixture", machine_hostname = "search-fixture"})
	if !enrolled_ok do testing.fail_now(t, "fixture bridge enrollment")
	f.bridge_id = strings.clone(enrolled.bridge.bridge_id)
	connected, connected_ok, _ := bridge_service.bridge_runtime_connect(&f.bridges, enrolled.bridge_token, "search-fixture", "linux", "amd64", "{}", "0.4.34", "fixture", "")
	defer domain.bridge_destroy(&connected)
	if !connected_ok do testing.fail_now(t, "fixture bridge connection")
	hello, accepted, _ := bridge_runtime.runtime_accept_hello(&f.registry, f.bridge_id, bridge_runtime.PROTOCOL_VERSION, "", f.owner)
	if !accepted do testing.fail_now(t, "fixture runtime hello")
	f.generation = hello.generation
	f.h = {auth = &f.auth, bridges = &f.bridges, bridge_runtime_registry = &f.registry}
	return f
}

@(private = "file")
search_relay_fixture_destroy :: proc(f: ^Search_Relay_Fixture) {
	project.bridge_runtime_registry_destroy(&f.registry)
	sqlite.close(&f.conn)
	delete(f.owner); delete(f.bridge_id); free(f)
}

@(private = "file")
search_relay_body :: proc(bridge_id, request_id, envelope: string, expires: i64) -> string {
	return fmt.tprintf(`{{"bridge_id":"%s","request_id":"%s","expires_at_ms":%d,"envelope":"%s"}}`, bridge_id, request_id, expires, envelope)
}

@(private = "file")
search_relay_request :: proc(body: string) -> Request {
	return {method = "POST", path = "/api/v1/task-chains/search/relay", request_id = "http_correlation", remote_addr = "127.0.0.1:4444", headers = SEARCH_HEADERS[:], body = body}
}

@(private = "file")
Search_Relay_Peer :: struct {
	f: ^Search_Relay_Fixture,
	socket: net.TCP_Socket,
	expected_envelope: string,
	expires: i64,
	key: [32]byte,
	received, correlation_ok, opened, replied: bool,
	response_envelope: string,
}

@(private = "file")
search_relay_peer :: proc(data: rawptr) {
	j := (^Search_Relay_Peer)(data)
	reader: ws.Frame_Reader
	defer ws.reader_destroy(&reader)
	_, command, received := ws.read_frame(j.socket, &reader, time.Second)
	j.received = received
	if !received do return
	f := j.f
	cmd_id := json_string(command, "command_id"); defer delete(cmd_id)
	envelope := json_string(command, "envelope"); defer delete(envelope)
	j.correlation_ok = envelope == j.expected_envelope && json_string(command, "owner_user_id", context.temp_allocator) == f.owner && json_string(command, "request_id", context.temp_allocator) == "req_fixture" && json_string(command, "bridge_id", context.temp_allocator) == f.bridge_id && json_int(command, "expires_at_ms", 0) == int(j.expires) && json_string(command, "type", context.temp_allocator) == "task_chain_search"
	ep, payload, parsed := vault.search_envelope_parse(envelope, context.temp_allocator)
	if !parsed do return
	aad, _ := vault.search_aad(f.owner, f.bridge_id, "req_fixture", "request", j.expires, ep, context.temp_allocator)
	plain, opened := vault.search_open_payload(payload, j.key[:], ep, aad, context.temp_allocator)
	j.opened = opened && string(plain) == `{"request_id":"req_fixture","query":"fixture","limit":20}`
	if !j.opened do return
	response_aad, _ := vault.search_aad(f.owner, f.bridge_id, "req_fixture", "response", j.expires, ep, context.temp_allocator)
	response_plain := fmt.tprintf(`{{"request_id":"req_fixture","bridge_id":"%s","indexed_revision":7,"stale":false,"hits":[{{"chain_id":"chain_fixture"}}]}}`, f.bridge_id)
	nonce: [12]byte
	nonce[0] = 99
	j.response_envelope, _ = vault.search_seal_with_nonce(transmute([]byte)response_plain, j.key[:], ep, response_aad, nonce[:], runtime.default_allocator())
	result := fmt.tprintf(`{{"type":"task_chain_search_result","command_id":"%s","request_id":"req_fixture","ok":true,"envelope":"%s"}}`, cmd_id, j.response_envelope)
	j.replied = bridge_runtime.runtime_command_result_for_connection(&f.registry, f.bridge_id, f.generation, cmd_id, result)
}

@(test)
task_chain_search_relay_handler_v2_encrypted_roundtrip :: proc(t: ^testing.T) {
	f := search_relay_fixture(t); defer search_relay_fixture_destroy(f)
	listener, listen_err := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	if listen_err != nil do testing.fail_now(t, "loopback listen")
	defer net.close(listener)
	bound, _ := net.bound_endpoint(listener)
	peer, dial_err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	if dial_err != nil do testing.fail_now(t, "loopback dial")
	defer net.close(peer)
	hub, _, accept_err := net.accept_tcp(listener)
	if accept_err != nil do testing.fail_now(t, "loopback accept")
	defer net.close(hub)
	project.bridge_runtime_registry_set_command_socket(&f.registry, f.bridge_id, hub)
	expires := time.to_unix_nanoseconds(time.now()) / 1_000_000 + 4_000
	key: [32]byte // isolated fixture, never logged or persisted
	for i in 0 ..< len(key) do key[i] = 42
	nonce: [12]byte
	nonce[0] = 17
	aad, _ := vault.search_aad(f.owner, f.bridge_id, "req_fixture", "request", expires, 4, context.temp_allocator)
	envelope, sealed := vault.search_seal_with_nonce(transmute([]byte)string(`{"request_id":"req_fixture","query":"fixture","limit":20}`), key[:], 4, aad, nonce[:])
	defer delete(envelope)
	testing.expect(t, sealed, "fixture v2 seal")
	job := Search_Relay_Peer{f = f, socket = peer, expected_envelope = envelope, expires = expires, key = key}
	worker := thread.create_and_start_with_data(&job, search_relay_peer)
	response := task_chain_search_relay_handler(&f.h, search_relay_request(search_relay_body(f.bridge_id, "req_fixture", envelope, expires)))
	defer delete(response.body)
	thread.join(worker); thread.destroy(worker)
	defer delete(job.response_envelope, runtime.default_allocator())
	testing.expect_value(t, response.status, 200)
	testing.expect(t, job.received && job.correlation_ok && job.opened && job.replied, "authenticated relay dispatched unchanged ciphertext and correlated metadata through runtime socket")
	if response.status != 200 do return
	data := json_string(response.body, "envelope"); defer delete(data)
	testing.expect(t, data == job.response_envelope, "response ciphertext unchanged")
	ep, payload, parsed := vault.search_envelope_parse(data, context.temp_allocator)
	response_aad, _ := vault.search_aad(f.owner, f.bridge_id, "req_fixture", "response", expires, 4, context.temp_allocator)
	plain, opened := vault.search_open_payload(payload, key[:], ep, response_aad, context.temp_allocator)
	testing.expect(t, parsed && opened && strings.contains(string(plain), `"chain_id":"chain_fixture"`), "correlated v2 response decrypts")
	wrong_aad, _ := vault.search_aad(f.owner, f.bridge_id, "different_request", "response", expires, 4, context.temp_allocator)
	_, wrong_opened := vault.search_open_payload(payload, key[:], ep, wrong_aad, context.temp_allocator)
	testing.expect(t, !wrong_opened, "response cannot move to another request")
	testing.expect(t, !strings.contains(response.body, "chain_fixture") && !strings.contains(response.body, `"query"`), "HTTP response carries no search plaintext")
}

@(test)
task_chain_search_relay_handler_rejects_malformed_and_unauthorized :: proc(t: ^testing.T) {
	f := search_relay_fixture(t); defer search_relay_fixture_destroy(f)
	expires := time.to_unix_nanoseconds(time.now()) / 1_000_000 + 4_000
	valid := "search:v2:e4:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="
	// Includes unsupported versions, noncanonical epoch/base64, missing nonce/tag,
	// invalid alphabet/padding/trailing bits and the envelope byte cap.
	bad_envelopes := []string{"", "search:v1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==", "search:v3:e4:AAAA", "search:v2:e0:AAAA", "search:v2:e04:AAAA", "search:v2:e4294967296:AAAA", "search:v2:e-1:AAAA", "search:v2:e4:", "search:v2:e4:AA==", "search:v2:e4:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "search:v2:e4:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB==", "search:v2:e4:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA-A==", "search:v2:e4:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA===", "search:v2:e4:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==:extra", strings.repeat("A", 32_769, context.temp_allocator)}
	for envelope in bad_envelopes {
		r := task_chain_search_relay_handler(&f.h, search_relay_request(search_relay_body(f.bridge_id, "req_fixture", envelope, expires)))
		testing.expect_value(t, r.status, 400); delete(r.body)
	}
	for body in ([]string{"", "{}", "null", "[]", `{"bridge_id":4}`, `{"request_id":true}`, `{"expires_at_ms":"1"}`, fmt.tprintf("%strailing", search_relay_body(f.bridge_id, "req_fixture", valid, expires)), strings.repeat(" ", 36_001, context.temp_allocator)}) {
		r := task_chain_search_relay_handler(&f.h, search_relay_request(body))
		testing.expect_value(t, r.status, 400); delete(r.body)
	}
	good_body := search_relay_body(f.bridge_id, "req_fixture", valid, expires)
	for replacement in ([]string{fmt.tprintf(`"expires_at_ms":%d.5`, expires), fmt.tprintf(`"expires_at_ms":"%d"`, expires), `"expires_at_ms":null`}) {
		bad_body, _ := strings.replace_all(good_body, fmt.tprintf(`"expires_at_ms":%d`, expires), replacement, context.temp_allocator)
		r := task_chain_search_relay_handler(&f.h, search_relay_request(bad_body))
		testing.expect_value(t, r.status, 400); delete(r.body)
	}
	for body in ([]string{
		fmt.tprintf(`{{"nested":%s}}`, good_body),
		fmt.tprintf(`%s {}`, good_body),
		fmt.tprintf(`{{"request_id":"duplicate",%s`, good_body[1:]),
		fmt.tprintf("%s%c", good_body, byte(0xff)),
		search_relay_body(f.bridge_id, "req_fixture", fmt.tprintf("search:v2:e4:%s", strings.repeat("A", 32_760, context.temp_allocator)), expires),
	}) {
		r := task_chain_search_relay_handler(&f.h, search_relay_request(body))
		testing.expect_value(t, r.status, 400); delete(r.body)
	}
	for id in ([]string{"", "bad|aad", strings.repeat("r", 129, context.temp_allocator)}) {
		r := task_chain_search_relay_handler(&f.h, search_relay_request(search_relay_body(f.bridge_id, id, valid, expires)))
		testing.expect_value(t, r.status, 400); delete(r.body)
	}
	for deadline in ([]i64{0, expires - 10_000, expires + 10_000}) {
		r := task_chain_search_relay_handler(&f.h, search_relay_request(search_relay_body(f.bridge_id, "req_fixture", valid, deadline)))
		testing.expect_value(t, r.status, 400); delete(r.body)
	}
	req := search_relay_request(search_relay_body(f.bridge_id, "req_fixture", valid, expires))
	req.headers = nil
	r := task_chain_search_relay_handler(&f.h, req)
	testing.expect_value(t, r.status, 401); delete(r.body)
	req.headers = SEARCH_HEADERS[:]
	req.remote_addr = "192.0.2.1:4444"
	r = task_chain_search_relay_handler(&f.h, req)
	testing.expect_value(t, r.status, 401); delete(r.body) // spoofed proxy header
	req.remote_addr = "127.0.0.1:4444"
	other_headers := [1]contracts.HTTP_Header{{name = "X-authentik-username", value = "search_other_owner"}}
	req.headers = other_headers[:]
	r = task_chain_search_relay_handler(&f.h, req)
	testing.expect_value(t, r.status, 404); delete(r.body) // owner anti-enumeration
	req.headers = SEARCH_HEADERS[:]
	project.bridge_runtime_registry_mark_offline(&f.registry, f.bridge_id, f.generation)
	r = task_chain_search_relay_handler(&f.h, req)
	testing.expect_value(t, r.status, status_for_error(.Bridge_Offline)); delete(r.body)
	project.bridge_runtime_registry_mark_live(&f.registry, f.bridge_id, false, "")
	offline, _, _ := bridge_service.mark_bridge_offline(&f.bridges, f.bridge_id)
	defer domain.bridge_destroy(&offline)
	r = task_chain_search_relay_handler(&f.h, req)
	testing.expect_value(t, r.status, status_for_error(.Bridge_Offline)); delete(r.body)
	testing.expect_value(t, f.registry.command_count, 0)
}
