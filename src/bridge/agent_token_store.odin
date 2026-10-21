package main

import "core:crypto/legacy/sha1"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import jsonx "odin_test:lib/jsonx"

Bridge_Local_Token_Role :: enum {
	Agent,
	Wrapper,
}

Bridge_Local_Agent_Token_Record :: struct {
	token_hash: string,
	agent_instance_id: string,
	instance_token: string, // Hub credential: Bridge-held only, never returned to wrapper/agent.
	role: Bridge_Local_Token_Role,
	issued_at_unix_ms: i64,
	rotated_at_unix_ms: i64,
	invalidated_at_unix_ms: i64,
}

Bridge_Local_Token_Issue_Result :: struct {
	endpoint: string,
	plaintext_token: string,
	agent_instance_id: string,
	role: Bridge_Local_Token_Role,
}

bridge_local_token_mutex: sync.Mutex
bridge_local_token_records: [dynamic]Bridge_Local_Agent_Token_Record
bridge_local_token_sequence: i64

bridge_agent_token_store_init :: proc() {
	bridge_local_token_mutex = sync.Mutex{}
	bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record)
	bridge_local_token_sequence = 0
	bridge_agent_token_store_load()
}

bridge_agent_token_issue :: proc(agent_instance_id, instance_token: string, role: Bridge_Local_Token_Role) -> Bridge_Local_Token_Issue_Result {
	if bridge_local_token_records == nil do bridge_agent_token_store_init()
	plain := bridge_local_generate_token("hlat_")
	now := bridge_local_now_unix_ms()
	record := Bridge_Local_Agent_Token_Record{
		token_hash = bridge_local_hash_token(plain),
		agent_instance_id = strings.clone(strings.trim_space(agent_instance_id)),
		instance_token = strings.clone(strings.trim_space(instance_token)),
		role = role,
		issued_at_unix_ms = now,
	}
	sync.mutex_lock(&bridge_local_token_mutex)
	append(&bridge_local_token_records, record)
	bridge_agent_token_store_save_locked()
	sync.mutex_unlock(&bridge_local_token_mutex)
	return Bridge_Local_Token_Issue_Result{plaintext_token = plain, agent_instance_id = record.agent_instance_id, role = role}
}

bridge_agent_token_verify :: proc(plaintext: string) -> (Bridge_Local_Agent_Token_Record, bool) {
	if bridge_local_token_records == nil do bridge_agent_token_store_init()
	hash := bridge_local_hash_token(strings.trim_space(plaintext))
	sync.mutex_lock(&bridge_local_token_mutex)
	defer sync.mutex_unlock(&bridge_local_token_mutex)
	for rec in bridge_local_token_records {
		if rec.token_hash == hash && rec.invalidated_at_unix_ms == 0 {
			return rec, true
		}
	}
	return {}, false
}

bridge_agent_token_rotate :: proc(plaintext: string) -> (Bridge_Local_Token_Issue_Result, bool) {
	rec, ok := bridge_agent_token_verify(plaintext)
	if !ok do return {}, false
	_ = bridge_agent_token_invalidate(plaintext)
	result := bridge_agent_token_issue(rec.agent_instance_id, rec.instance_token, rec.role)
	return result, true
}

bridge_agent_token_invalidate :: proc(plaintext: string) -> bool {
	if bridge_local_token_records == nil do bridge_agent_token_store_init()
	hash := bridge_local_hash_token(strings.trim_space(plaintext))
	now := bridge_local_now_unix_ms()
	sync.mutex_lock(&bridge_local_token_mutex)
	defer sync.mutex_unlock(&bridge_local_token_mutex)
	for i in 0..<len(bridge_local_token_records) {
		if bridge_local_token_records[i].token_hash == hash && bridge_local_token_records[i].invalidated_at_unix_ms == 0 {
			bridge_local_token_records[i].invalidated_at_unix_ms = now
			bridge_agent_token_store_save_locked()
			return true
		}
	}
	return false
}

// bridge_agent_token_invalidate_instance invalidates EVERY currently-valid local
// token (wrapper + agent roles) issued for one agent_instance_id. This is the
// core of the H7 restart-reap: on (re)launch the bridge invalidates the previous
// runtime's local tokens BEFORE issuing fresh ones, so a superseded old
// ham-wrapper fails its next wrapper.liveness.ping (bridge_agent_token_verify
// misses the now-invalidated token -> "unauthenticated") and self-terminates.
// This is transport/host independent (no tmux/PID reaping), so it works even
// when the old process is orphaned, detached from its tmux window, or the
// instance was restarted on a different bridge. Returns the count invalidated.
bridge_agent_token_invalidate_instance :: proc(agent_instance_id: string) -> int {
	if bridge_local_token_records == nil do bridge_agent_token_store_init()
	target := strings.trim_space(agent_instance_id)
	if target == "" do return 0
	now := bridge_local_now_unix_ms()
	sync.mutex_lock(&bridge_local_token_mutex)
	defer sync.mutex_unlock(&bridge_local_token_mutex)
	count := 0
	for i in 0..<len(bridge_local_token_records) {
		if bridge_local_token_records[i].agent_instance_id == target && bridge_local_token_records[i].invalidated_at_unix_ms == 0 {
			bridge_local_token_records[i].invalidated_at_unix_ms = now
			count += 1
		}
	}
	if count > 0 do bridge_agent_token_store_save_locked()
	return count
}

// S1: the local-token store is namespaced PER BRIDGE so two bridges on one host
// (e.g. a dev-stack bridge and the mundus bridge) never share a file. Previously
// they shared ~/.local/share/heimdall/bridge/local-tokens.jsonl and each
// bridge_agent_token_store_save_locked() rewrote the whole file from its own
// in-memory records, so one bridge issuing a token WIPED the other's tokens —
// leaving those agents permanently unauthenticated on reconnect. The namespace
// key is the bridge's local_endpoint_run_dir, which is already unique per bridge.
bridge_agent_token_store_namespace :: proc() -> string {
	run_dir := strings.trim_space(bridge_config.local_endpoint_run_dir)
	if run_dir == "" do return "default"
	// Slugify the run dir into a single safe path segment.
	b := strings.builder_make()
	for i in 0..<len(run_dir) {
		ch := run_dir[i]
		if (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '-' || ch == '_' || ch == '.' {
			strings.write_byte(&b, ch)
		} else {
			strings.write_byte(&b, '_')
		}
	}
	slug := strings.to_string(b)
	if strings.trim_space(slug) == "" do return "default"
	return slug
}

bridge_agent_token_store_path :: proc() -> string {
	data_dir := bridge_expand_home(bridge_config.data_dir)
	expanded_default := false
	if strings.trim_space(data_dir) == "" {
		data_dir = bridge_expand_home("~/.local/share/heimdall")
		expanded_default = true
	}
	defer if expanded_default || data_dir != bridge_config.data_dir do delete(data_dir)
	ns := bridge_agent_token_store_namespace()
	defer if ns != "default" do delete(ns)
	return strings.concatenate({strings.trim_right(data_dir, "/"), "/bridge/", ns, "/local-tokens.jsonl"})
}

// bridge_agent_token_store_legacy_path is the pre-namespacing shared location.
// We migrate records for THIS bridge out of it on first load so tokens issued by
// the previous build are not lost across the upgrade.
bridge_agent_token_store_legacy_path :: proc() -> string {
	data_dir := bridge_expand_home(bridge_config.data_dir)
	expanded_default := false
	if strings.trim_space(data_dir) == "" {
		data_dir = bridge_expand_home("~/.local/share/heimdall")
		expanded_default = true
	}
	defer if expanded_default || data_dir != bridge_config.data_dir do delete(data_dir)
	return strings.concatenate({strings.trim_right(data_dir, "/"), "/bridge/local-tokens.jsonl"})
}

bridge_agent_token_store_load :: proc() {
	// Load the namespaced store first, then migrate any records for THIS bridge's
	// instances out of the legacy shared file (so an upgrade doesn't lose tokens).
	// Dedup by token_hash; namespaced records win.
	path := bridge_agent_token_store_path()
	defer delete(path)
	bridge_agent_token_store_load_file(path)
	legacy := bridge_agent_token_store_legacy_path()
	defer delete(legacy)
	if legacy != path {
		before := len(bridge_local_token_records)
		bridge_agent_token_store_load_file(legacy)
		// If we adopted any legacy records, persist them into the namespaced file so
		// the legacy shared file is no longer authoritative for this bridge.
		if len(bridge_local_token_records) > before do bridge_agent_token_store_save_locked()
	}
}

// bridge_agent_token_store_load_file merges records from one jsonl file into the
// in-memory set, skipping any whose token_hash we already hold.
bridge_agent_token_store_load_file :: proc(path: string) {
	raw, err := os.read_entire_file(path, context.allocator)
	if err != nil do return
	defer delete(raw)
	lines := strings.split(string(raw), "\n")
	defer delete(lines)
	for line in lines {
		trimmed := strings.trim_space(line)
		if trimmed == "" do continue
		rec := Bridge_Local_Agent_Token_Record{
			token_hash = bridge_agent_token_json_string(trimmed, "token_hash", ""),
			agent_instance_id = bridge_agent_token_json_string(trimmed, "agent_instance_id", ""),
			instance_token = bridge_agent_token_json_string(trimmed, "instance_token", ""),
			role = bridge_agent_token_role_from_string(bridge_agent_token_json_string(trimmed, "role", "agent")),
			issued_at_unix_ms = bridge_agent_token_json_i64(trimmed, "issued_at_unix_ms", 0),
			rotated_at_unix_ms = bridge_agent_token_json_i64(trimmed, "rotated_at_unix_ms", 0),
			invalidated_at_unix_ms = bridge_agent_token_json_i64(trimmed, "invalidated_at_unix_ms", 0),
		}
		if strings.trim_space(rec.token_hash) == "" || strings.trim_space(rec.agent_instance_id) == "" do continue
		already := false
		for existing in bridge_local_token_records { if existing.token_hash == rec.token_hash { already = true; break } }
		if !already do append(&bridge_local_token_records, rec)
	}
}

bridge_agent_token_store_save_locked :: proc() {
	path := bridge_agent_token_store_path()
	defer delete(path)
	if slash := strings.last_index_byte(path, '/'); slash > 0 { _ = bridge_make_directory_all(path[:slash]) }
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for rec in bridge_local_token_records {
		strings.write_string(&b, "{\"token_hash\":\""); bridge_agent_token_json_write(&b, rec.token_hash)
		strings.write_string(&b, "\",\"agent_instance_id\":\""); bridge_agent_token_json_write(&b, rec.agent_instance_id)
		strings.write_string(&b, "\",\"instance_token\":\""); bridge_agent_token_json_write(&b, rec.instance_token)
		strings.write_string(&b, "\",\"role\":\""); bridge_agent_token_json_write(&b, bridge_local_token_role_string(rec.role))
		strings.write_string(&b, "\",\"issued_at_unix_ms\":"); strings.write_string(&b, fmt.tprintf("%d", rec.issued_at_unix_ms))
		strings.write_string(&b, ",\"rotated_at_unix_ms\":"); strings.write_string(&b, fmt.tprintf("%d", rec.rotated_at_unix_ms))
		strings.write_string(&b, ",\"invalidated_at_unix_ms\":"); strings.write_string(&b, fmt.tprintf("%d", rec.invalidated_at_unix_ms))
		strings.write_string(&b, "}\n")
	}
	// S2: atomic write — write to a temp file then rename over the target, so a
	// crash mid-write can never truncate/corrupt the store (readers see either the
	// old or the new complete file, never a partial one).
	tmp := strings.concatenate({path, ".tmp"})
	defer delete(tmp)
	content := strings.to_string(b)
	if os.write_entire_file(tmp, transmute([]byte)content) != nil do return
	if os.rename(tmp, path) != nil {
		// Fallback: best-effort direct write if rename is unavailable.
		_ = os.write_entire_file(path, transmute([]byte)content)
		_ = os.remove(tmp)
	}
}

bridge_agent_token_role_from_string :: proc(value: string) -> Bridge_Local_Token_Role {
	if value == "wrapper" do return .Wrapper
	return .Agent
}

bridge_agent_token_json_string :: proc(body, key, fallback: string, allocator := context.allocator) -> string {
	return jsonx.extract_string(body, key, fallback, false, allocator)
}

bridge_agent_token_json_i64 :: proc(body, key: string, fallback: i64) -> i64 {
	return jsonx.extract_i64(body, key, fallback)
}

bridge_agent_token_json_write :: proc(b: ^strings.Builder, value: string) {
	for ch in value {
		switch ch {
		case '\\': strings.write_string(b, "\\\\")
		case '"': strings.write_string(b, "\\\"")
		case '\n': strings.write_string(b, "\\n")
		case '\r': strings.write_string(b, "\\r")
		case '\t': strings.write_string(b, "\\t")
		case: strings.write_rune(b, ch)
		}
	}
}

bridge_local_token_role_string :: proc(role: Bridge_Local_Token_Role) -> string {
	switch role {
	case .Agent: return "agent"
	case .Wrapper: return "wrapper"
	}
	return "agent"
}

bridge_local_generate_token :: proc(prefix: string) -> string {
	sync.mutex_lock(&bridge_local_token_mutex)
	bridge_local_token_sequence += 1
	seq := bridge_local_token_sequence
	sync.mutex_unlock(&bridge_local_token_mutex)
	return fmt.tprintf("%s%x_%d", prefix, time.to_unix_nanoseconds(time.now()), seq)
}

bridge_local_hash_token :: proc(token: string) -> string {
	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]byte)token)
	digest: [sha1.DIGEST_SIZE]byte
	sha1.final(&ctx, digest[:])
	builder := strings.builder_make()
	strings.write_string(&builder, "sha1:")
	for b in digest do bridge_local_write_hex_byte(&builder, b)
	return strings.to_string(builder)
}

bridge_local_write_hex_byte :: proc(builder: ^strings.Builder, value: byte) {
	strings.write_byte(builder, bridge_local_hex_digit(value >> 4))
	strings.write_byte(builder, bridge_local_hex_digit(value & 0x0f))
}

bridge_local_hex_digit :: proc(n: byte) -> byte {
	if n < 10 do return '0' + n
	return 'a' + (n - 10)
}

bridge_local_now_unix_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}

// Return an owned assertion snapshot. Local tokens persist across Bridge restart,
// so the launch epoch survives loss of the in-memory status projection.
bridge_agent_instance_assertion :: proc(instance_id: string) -> string {
	sync.mutex_lock(&bridge_local_token_mutex)
	defer sync.mutex_unlock(&bridge_local_token_mutex)
	for i := len(bridge_local_token_records) - 1; i >= 0; i -= 1 {
		rec := bridge_local_token_records[i]
		if rec.agent_instance_id == instance_id && rec.invalidated_at_unix_ms == 0 do return strings.clone(rec.instance_token)
	}
	return ""
}
bridge_agent_instance_last_assertion :: proc(instance_id: string) -> string {
	sync.mutex_lock(&bridge_local_token_mutex)
	defer sync.mutex_unlock(&bridge_local_token_mutex)
	for i := len(bridge_local_token_records) - 1; i >= 0; i -= 1 {
		rec := bridge_local_token_records[i]
		if rec.agent_instance_id == instance_id do return strings.clone(rec.instance_token)
	}
	return ""
}
bridge_agent_instance_launch_epoch :: proc(instance_id: string) -> string {
	assertion := bridge_agent_instance_last_assertion(instance_id)
	defer delete(assertion)
	if separator := strings.index(assertion, "~"); separator >= 0 do return strings.clone(assertion[separator + 1:])
	return ""
}
