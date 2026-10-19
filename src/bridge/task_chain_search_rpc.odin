package main

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:time"
import ws "odin_test:lib/ws"
import os_random "odin_test:lib/os_random"
import vault "odin_test:lib/vault"

// Search RPC v2 (docs/plans/passwordless-vault.md §1 "Search key v2"):
// envelope "search:v2:e<epoch>:<b64(nonce|tag|ct)>", key HKDF(epoch key, domain,
// domain|e<epoch>), AAD domain|owner|bridge|request|direction|expires|e<epoch>.
// The bridge accepts ONLY the keyring's current epoch (command epoch floor).
TASK_CHAIN_SEARCH_RPC_MAX_LIMIT :: 50
TASK_CHAIN_SEARCH_RPC_NONCE_CACHE :: 512

@(private = "file")
task_chain_search_nonce_cache: [TASK_CHAIN_SEARCH_RPC_NONCE_CACHE][12]u8
@(private = "file")
task_chain_search_nonce_count: int
@(private = "file")
task_chain_search_nonce_next: int
@(private = "file")
task_chain_search_nonce_mutex: sync.Mutex

task_chain_search_nonce_accept :: proc(nonce: []u8) -> bool {
	if len(nonce) != 12 do return false
	sync.mutex_lock(&task_chain_search_nonce_mutex)
	defer sync.mutex_unlock(&task_chain_search_nonce_mutex)
	for i in 0 ..< task_chain_search_nonce_count {
		if mem.compare(task_chain_search_nonce_cache[i][:], nonce) == 0 do return false
	}
	copy(task_chain_search_nonce_cache[task_chain_search_nonce_next][:], nonce)
	task_chain_search_nonce_next = (task_chain_search_nonce_next + 1) % TASK_CHAIN_SEARCH_RPC_NONCE_CACHE
	if task_chain_search_nonce_count < TASK_CHAIN_SEARCH_RPC_NONCE_CACHE do task_chain_search_nonce_count += 1
	return true
}

// task_chain_search_open opens a request envelope. It must be sealed under kr's
// CURRENT epoch; the AAD is built for that epoch. epoch is returned so the response
// is sealed under the same one.
task_chain_search_open :: proc(envelope: string, kr: ^vault.Vault_Keyring, owner_user_id, bridge_id, request_id, direction: string, expires_at_ms: i64, reject_replay := true, allocator := context.allocator) -> (plaintext: string, epoch: u32, ok: bool) {
	if kr == nil do return "", 0, false
	ep, payload, parsed := vault.search_envelope_parse(envelope, context.temp_allocator)
	if !parsed || ep != kr.current_epoch do return "", 0, false
	key, key_ok := vault.keyring_key_for_epoch(kr, ep)
	if !key_ok do return "", 0, false
	aad, aad_ok := vault.search_aad(owner_user_id, bridge_id, request_id, direction, expires_at_ms, ep, context.temp_allocator)
	if !aad_ok do return "", 0, false
	plain, opened := vault.search_open_payload(payload, key, ep, aad, allocator)
	if !opened do return "", 0, false
	if reject_replay && !task_chain_search_nonce_accept(payload[:12]) {
		delete(plain, allocator)
		return "", 0, false
	}
	return string(plain), ep, true
}

// task_chain_search_seal seals a response under epoch with a fresh CSPRNG nonce. A
// randomness failure returns ok=false and nothing is sealed.
task_chain_search_seal :: proc(plaintext: string, kr: ^vault.Vault_Keyring, epoch: u32, owner_user_id, bridge_id, request_id, direction: string, expires_at_ms: i64, allocator := context.allocator) -> (string, bool) {
	key, key_ok := vault.keyring_key_for_epoch(kr, epoch)
	if !key_ok do return "", false
	nonce: [12]u8
	if !os_random.fill(nonce[:]) do return "", false
	aad, aad_ok := vault.search_aad(owner_user_id, bridge_id, request_id, direction, expires_at_ms, epoch, context.temp_allocator)
	if !aad_ok do return "", false
	return vault.search_seal_with_nonce(transmute([]u8)plaintext, key, epoch, aad, nonce[:], allocator)
}

task_chain_search_error_result :: proc(command_id, request_id, code: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"type":"task_chain_search_result","command_id":"`); bridge_runtime_write_json_string(&b, command_id)
	strings.write_string(&b, `","request_id":"`); bridge_runtime_write_json_string(&b, request_id)
	strings.write_string(&b, `",`)
	bridge_write_failure(&b, bridge_cause_wire_error(code, ""))
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

task_chain_search_send_error :: proc(conn: ^ws.Connection, command_id, request_id, code: string) {
	result := task_chain_search_error_result(command_id, request_id, code); defer delete(result)
	bridge_runtime_cache_command(command_id, result)
	if conn != nil do _ = bridge_hub_send(conn, result)
}

bridge_task_chain_search_handle_command :: proc(conn: ^ws.Connection, text: string) {
	command_id := extract_json_string(text, "command_id", ""); defer delete(command_id)
	request_id := extract_json_string(text, "request_id", ""); defer delete(request_id)
	owner_user_id := extract_json_string(text, "owner_user_id", ""); defer delete(owner_user_id)
	bridge_id := extract_json_string(text, "bridge_id", ""); defer delete(bridge_id)
	envelope := extract_json_string(text, "envelope", ""); defer delete(envelope)
	expires_at_ms := i64(extract_json_int(text, "expires_at_ms", 0))
	now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000
	if request_id == "" || owner_user_id == "" || bridge_id != bridge_config.daemon_id || expires_at_ms < now_ms || expires_at_ms > now_ms + 5_000 || len(envelope) > 32_768 {
		task_chain_search_send_error(conn, command_id, request_id, "invalid_envelope"); return
	}
	kr, key_ok := bridge_read_vault_keyring()
	defer vault.keyring_wipe(&kr)
	if !key_ok { task_chain_search_send_error(conn, command_id, request_id, "vault_locked"); return }
	plain, epoch, opened := task_chain_search_open(envelope, &kr, owner_user_id, bridge_id, request_id, "request", expires_at_ms); defer delete(plain)
	if !opened { task_chain_search_send_error(conn, command_id, request_id, "invalid_envelope"); return }
	inner_request_id := bridge_provider_json_extract_string(plain, "request_id", ""); defer delete(inner_request_id)
	query := bridge_provider_json_extract_string(plain, "query", ""); defer delete(query)
	project_id := bridge_provider_json_extract_string(plain, "project_id", ""); defer delete(project_id)
	status := bridge_provider_json_extract_string(plain, "status", ""); defer delete(status)
	limit, limit_ok := bridge_provider_json_extract_int(plain, "limit")
	if inner_request_id != request_id { task_chain_search_send_error(conn, command_id, request_id, "invalid_envelope"); return }
	if len(strings.trim_space(query)) < 2 { task_chain_search_send_error(conn, command_id, request_id, "query_too_short"); return }
	if !limit_ok || limit < 1 || limit > TASK_CHAIN_SEARCH_RPC_MAX_LIMIT { task_chain_search_send_error(conn, command_id, request_id, "limit_exceeded"); return }
	hits, queried, stale, revision := bridge_task_chain_search_query(query, project_id, status, limit)
	defer task_chain_search_hits_destroy(hits)
	if !queried { task_chain_search_send_error(conn, command_id, request_id, "search_not_ready"); return }
	b := strings.builder_make()
	strings.write_string(&b, `{"request_id":"`); bridge_runtime_write_json_string(&b, request_id)
	strings.write_string(&b, `","bridge_id":"`); bridge_runtime_write_json_string(&b, bridge_id)
	strings.write_string(&b, `","indexed_revision":`); strings.write_string(&b, fmt.tprintf("%d", revision))
	strings.write_string(&b, `,"stale":`); strings.write_string(&b, "true" if stale else "false")
	strings.write_string(&b, `,"hits":[`)
	for hit, i in hits {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, `{"chain_id":"`); bridge_runtime_write_json_string(&b, hit.chain_id)
		strings.write_string(&b, `","project_id":"`); bridge_runtime_write_json_string(&b, hit.project_id)
		strings.write_string(&b, `","status":"`); bridge_runtime_write_json_string(&b, hit.status)
		strings.write_string(&b, `","updated_at":"`); bridge_runtime_write_json_string(&b, hit.updated_at)
		strings.write_string(&b, `","title":"`); bridge_runtime_write_json_string(&b, hit.title)
		strings.write_string(&b, `","description":"`); bridge_runtime_write_json_string(&b, hit.description_snippet)
		strings.write_string(&b, `"}`)
	}
	strings.write_string(&b, `]}`)
	response_plain := strings.to_string(b); defer delete(response_plain)
	sealed, sealed_ok := task_chain_search_seal(response_plain, &kr, epoch, owner_user_id, bridge_id, request_id, "response", expires_at_ms); defer delete(sealed)
	if !sealed_ok { task_chain_search_send_error(conn, command_id, request_id, "invalid_envelope"); return }
	out := strings.builder_make()
	strings.write_string(&out, `{"type":"task_chain_search_result","command_id":"`); bridge_runtime_write_json_string(&out, command_id)
	strings.write_string(&out, `","request_id":"`); bridge_runtime_write_json_string(&out, request_id)
	strings.write_string(&out, `","ok":true,"envelope":"`); bridge_runtime_write_json_string(&out, sealed)
	strings.write_string(&out, `"}`)
	result := strings.to_string(out); defer delete(result)
	bridge_runtime_cache_command(command_id, result)
	if conn != nil do _ = bridge_hub_send(conn, result)
}
