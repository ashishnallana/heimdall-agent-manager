package main

import "core:crypto"
import "core:crypto/aes"
import "core:crypto/hkdf"
import base64 "core:encoding/base64"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:time"
import ws "odin_test:lib/ws"

TASK_CHAIN_SEARCH_RPC_PREFIX :: "search:v1:"
TASK_CHAIN_SEARCH_RPC_DOMAIN :: "heimdall/task-chain-search-rpc/v1"
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

task_chain_search_derive_key :: proc(key_hex: string, dst: []u8) -> bool {
	if len(dst) != 32 || !bridge_is_valid_hex_key(key_hex) do return false
	raw: [32]u8
	defer mem.zero_explicit(&raw, size_of(raw))
	if !bridge_hex_decode_to_buf(raw[:], key_hex) do return false
	domain := transmute([]u8)string(TASK_CHAIN_SEARCH_RPC_DOMAIN)
	hkdf.extract_and_expand(.SHA256, domain, raw[:], domain, dst)
	return true
}

task_chain_search_aad :: proc(owner_user_id, bridge_id, request_id, direction: string, expires_at_ms: i64, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator = allocator)
	strings.write_string(&b, TASK_CHAIN_SEARCH_RPC_DOMAIN)
	strings.write_byte(&b, '|'); strings.write_string(&b, owner_user_id)
	strings.write_byte(&b, '|'); strings.write_string(&b, bridge_id)
	strings.write_byte(&b, '|'); strings.write_string(&b, request_id)
	strings.write_byte(&b, '|'); strings.write_string(&b, direction)
	strings.write_byte(&b, '|'); strings.write_string(&b, fmt.tprintf("%d", expires_at_ms))
	return strings.to_string(b)
}

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

task_chain_search_open :: proc(envelope, key_hex, aad: string, reject_replay := true, allocator := context.allocator) -> (string, bool) {
	if !strings.has_prefix(envelope, TASK_CHAIN_SEARCH_RPC_PREFIX) do return "", false
	payload, err := base64.decode(envelope[len(TASK_CHAIN_SEARCH_RPC_PREFIX):], allocator = context.temp_allocator)
	if err != nil || len(payload) < 28 do return "", false
	nonce, tag, ciphertext := payload[:12], payload[12:28], payload[28:]
	key: [32]u8
	defer mem.zero_explicit(&key, size_of(key))
	if !task_chain_search_derive_key(key_hex, key[:]) do return "", false
	plain := make([]u8, len(ciphertext), allocator)
	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, key[:]); defer aes.reset_gcm(&gcm)
	if !aes.open_gcm(&gcm, plain, nonce, transmute([]u8)aad, ciphertext, tag) {
		delete(plain, allocator); return "", false
	}
	if reject_replay && !task_chain_search_nonce_accept(nonce) {
		delete(plain, allocator); return "", false
	}
	return string(plain), true
}

task_chain_search_seal :: proc(plaintext, key_hex, aad: string, allocator := context.allocator) -> (string, bool) {
	key: [32]u8
	defer mem.zero_explicit(&key, size_of(key))
	if !task_chain_search_derive_key(key_hex, key[:]) do return "", false
	nonce: [12]u8; crypto.rand_bytes(nonce[:])
	ciphertext := make([]u8, len(plaintext), context.temp_allocator)
	tag: [16]u8
	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, key[:]); defer aes.reset_gcm(&gcm)
	aes.seal_gcm(&gcm, ciphertext, tag[:], nonce[:], transmute([]u8)aad, transmute([]u8)plaintext)
	payload := make([]u8, 28 + len(ciphertext), context.temp_allocator)
	copy(payload[:12], nonce[:]); copy(payload[12:28], tag[:]); copy(payload[28:], ciphertext)
	encoded, err := base64.encode(payload, allocator = context.temp_allocator)
	if err != nil do return "", false
	return strings.concatenate({TASK_CHAIN_SEARCH_RPC_PREFIX, encoded}, allocator), true
}

task_chain_search_error_result :: proc(command_id, request_id, code: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"type":"task_chain_search_result","command_id":"`); bridge_runtime_write_json_string(&b, command_id)
	strings.write_string(&b, `","request_id":"`); bridge_runtime_write_json_string(&b, request_id)
	strings.write_string(&b, `","ok":false,"error_code":"`); bridge_runtime_write_json_string(&b, code)
	strings.write_string(&b, `"}`)
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
	key_hex, key_ok := bridge_read_vault_key()
	if !key_ok { task_chain_search_send_error(conn, command_id, request_id, "vault_locked"); return }
	defer { mem.zero_explicit(raw_data(key_hex), len(key_hex)); delete(key_hex) }
	aad := task_chain_search_aad(owner_user_id, bridge_id, request_id, "request", expires_at_ms); defer delete(aad)
	plain, opened := task_chain_search_open(envelope, key_hex, aad); defer delete(plain)
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
	response_aad := task_chain_search_aad(owner_user_id, bridge_id, request_id, "response", expires_at_ms); defer delete(response_aad)
	sealed, sealed_ok := task_chain_search_seal(response_plain, key_hex, response_aad); defer delete(sealed)
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
