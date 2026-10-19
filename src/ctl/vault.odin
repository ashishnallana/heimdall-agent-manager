package main

import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import jsonx "odin_test:lib/jsonx"
import vault "odin_test:lib/vault"

// ── vault verb group (REQ-VAULT-BRIDGE-CLI-1, passwordless vault P1) ─────────
// Reports where ham-ctl gets its vault KEYRING from. ham-ctl stores no key material
// of its own: it uses $HEIMDALL_VAULT_KEYRING when set, otherwise
// the keyring the local bridge holds.
//
// TRUST NOTE: agent.vault.get hands every local agent process the bridge's WHOLE
// keyring — every epoch it holds, not just the current one. That is the same trust
// level as before (agents on an unsealed bridge could always read the vault key), now
// including history: such an agent can read old-epoch content. A revoked device's
// residual access is bounded by the epoch rotation done on revoke, not by this call.

print_vault_help :: proc() {
	fmt.println("ham-ctl vault — inspect the zero-knowledge vault keyring source")
	fmt.println("")
	fmt.println("USAGE:")
	fmt.println("  ham-ctl vault status")
	fmt.println("")
	fmt.println("The keyring comes from $HEIMDALL_VAULT_KEYRING (base64 HKR1,")
	fmt.println("a single-bridge dev override) or, otherwise, the local bridge.")
}

// g_ctl_keyring holds the most recently resolved keyring. ham-ctl is a short-lived,
// single-threaded process; keeping ONE copy lets ctl_vault_wipe zero it on the way out
// instead of scattering copies through temp allocations.
// Thread-local so parallel tests cannot wipe each other's copy; ham-ctl itself is
// single-threaded, so this changes nothing in production.
@(private = "file", thread_local)
g_ctl_keyring: vault.Vault_Keyring

// ctl_vault_wipe zeroes the resolved keyring. main defers it.
ctl_vault_wipe :: proc() {
	vault.keyring_wipe(&g_ctl_keyring)
}

// ctl_keyring_from_b64 strictly decodes a base64 HKR1 keyring. When want_epoch is
// non-zero the keyring's current epoch must equal it.
ctl_keyring_from_b64 :: proc(b64: string, want_epoch: u32 = 0) -> (kr: vault.Vault_Keyring, ok: bool) {
	raw, dec_ok := vault.b64_decode_strict(b64, context.temp_allocator)
	if !dec_ok do return {}, false
	defer crypto.zero_explicit(raw_data(raw), len(raw))
	parsed, p_ok := vault.keyring_parse(raw)
	if !p_ok do return {}, false
	if want_epoch != 0 && parsed.current_epoch != want_epoch {
		vault.keyring_wipe(&parsed)
		return {}, false
	}
	return parsed, true
}

// ctl_read_vault_keyring resolves the vault keyring from, in order:
//   1. $HEIMDALL_VAULT_KEYRING (a single-bridge dev override; a bridge never passes
//      it to the agents it spawns)
//   2. the local bridge, via agent.vault.get (agent mode only)
// (Test builds also accept --vault-keyring <base64 HKR1> first; see below.)
//
// Source 1 is EXPLICIT: if it is present but invalid it is rejected and
// the bridge is NOT consulted, so a typo surfaces as an error instead of silently
// resolving to a different keyring. Only genuine ABSENCE falls through.
//
// DO NOT add a file source. The machine-wide ~/.config/heimdall/vault_key file is
// ignored (pinned by test_vault_legacy_key_file_is_ignored).
//
// The returned pointer refers to the process-wide copy wiped by ctl_vault_wipe.
ctl_read_vault_keyring :: proc(args: []string = nil, allocator := context.allocator) -> (kr: ^vault.Vault_Keyring, ok: bool) {
	_ = allocator
	vault.keyring_wipe(&g_ctl_keyring)
	// --vault-keyring exists ONLY in test builds, as a per-call injection point.
	// A production ham-ctl never takes key material on argv, where `ps` and shell
	// history can read it (finding L3).
	when ODIN_TEST {
		if args != nil && has_flag(args, "--vault-keyring") {
			parsed, p_ok := ctl_keyring_from_b64(strings.trim_space(option_value(args, "--vault-keyring", "")))
			if !p_ok do return nil, false
			g_ctl_keyring = parsed
			return &g_ctl_keyring, true
		}
	}
	if env_val, found := os.lookup_env("HEIMDALL_VAULT_KEYRING", context.temp_allocator); found {
		trimmed := strings.trim_space(env_val)
		if trimmed != "" {
			parsed, p_ok := ctl_keyring_from_b64(trimmed)
			if !p_ok do return nil, false
			g_ctl_keyring = parsed
			return &g_ctl_keyring, true
		}
	}
	parsed, b_ok := ctl_vault_keyring_from_bridge()
	if !b_ok do return nil, false
	g_ctl_keyring = parsed
	return &g_ctl_keyring, true
}

// ctl_vault_keyring_from_bridge asks the local bridge for the keyring it holds. Any
// failure (no endpoint, unreachable socket, error envelope, malformed value) is "no
// keyring". It uses ctl_agent_local_call, which neither prints nor exits.
ctl_vault_keyring_from_bridge :: proc() -> (kr: vault.Vault_Keyring, ok: bool) {
	endpoint, has_endpoint := os.lookup_env("HEIMDALL_BRIDGE_ENDPOINT", context.temp_allocator)
	if !has_endpoint || strings.trim_space(endpoint) == "" do return {}, false
	token, has_token := os.lookup_env("HEIMDALL_AGENT_TOKEN", context.temp_allocator)
	if !has_token || strings.trim_space(token) == "" do return {}, false

	response, call_ok := ctl_agent_local_call(endpoint, token, "agent.vault.get", "{}")
	if !call_ok do return {}, false
	defer {
		crypto.zero_explicit(raw_data(response), len(response))
		delete(response)
	}
	return ctl_vault_keyring_from_response(response)
}

// ctl_vault_keyring_from_response validates an agent.vault.get response:
// {"keyring_b64":"<base64 HKR1>","current_epoch":N}. The keyring must decode
// strictly, parse, and its current epoch must equal current_epoch.
// Ctl_Vault_Get_Data is the agent.vault.get answer (bare or under "data").
Ctl_Vault_Get_Data :: struct {
	keyring_b64:   string,
	current_epoch: Maybe(i64),
}

ctl_vault_keyring_from_response :: proc(response: string) -> (kr: vault.Vault_Keyring, ok: bool) {
	envelope: struct {
		data: Maybe(Ctl_Vault_Get_Data),
	}
	got: Ctl_Vault_Get_Data
	if vault.wire_decode(response, &envelope) {
		if d, has := envelope.data.?; has do got = d
	}
	if got.keyring_b64 == "" {
		flat: Ctl_Vault_Get_Data
		if vault.wire_decode(response, &flat) do got = flat
	}
	b64 := got.keyring_b64
	defer crypto.zero_explicit(raw_data(b64), len(b64))
	epoch, epoch_ok := got.current_epoch.?
	if b64 == "" || !epoch_ok || epoch < 1 || epoch > i64(vault.MAX_EPOCH) do return {}, false
	return ctl_keyring_from_b64(b64, u32(epoch))
}

// Ctl_Message is a {"ok":false,"message":...} line.
Ctl_Message :: struct {
	ok:      bool,
	message: string,
}

ctl_vault_command :: proc(cmd: []string, args: []string) {
	idx := 0
	if len(cmd) > 0 && cmd[0] == "vault" do idx = 1
	action := ""
	if idx < len(cmd) do action = cmd[idx]

	if action == "" || action == "help" || action == "--help" || has_flag(args, "--help") || has_flag(args, "-h") {
		print_vault_help()
		return
	}

	switch action {
	case "status":
		ctl_vault_status(args)
	case:
		msg, _ := vault.wire_encode(Ctl_Message{message = fmt.tprintf("unknown vault command: %s. Run 'ham-ctl vault --help' for usage.", action)}, context.temp_allocator)
		fmt.println(msg)
	}
}

// ctl_vault_status reports the two places a keyring can come from: whether a
// $HEIMDALL_VAULT_KEYRING override is present (and well formed), and the bridge's own
// view from agent.vault.status, forwarded verbatim under "bridge" so the two cannot
// drift. Nothing here looks at the filesystem.
//
// "bridge.available" distinguishes "the bridge says it has no key" from "we could
// not ask it" (hub mode, or an unreachable socket), which are very different things
// when diagnosing a decryption failure.
ctl_vault_status :: proc(args: []string) {
	_ = args
	env_present, env_valid := ctl_vault_env_override()
	fields := Ctl_Vault_Status_Fields{env_override = env_present, env_override_valid = env_valid, bridge = ctl_vault_status_bridge()}
	out, _ := vault.wire_encode(Ctl_Vault_Status_Output{ok = true, env_override = fields.env_override, env_override_valid = fields.env_override_valid, bridge = fields.bridge, data = fields}, context.temp_allocator)
	fmt.println(out)
}

// Ctl_Vault_Status_Bridge is the "bridge" object: available, and the bridge's own
// agent.vault.status data forwarded as-is (nil -> omitted when unavailable).
Ctl_Vault_Status_Bridge :: struct {
	available: bool,
	status:    json.Value `json:"status,omitempty"`,
}

Ctl_Vault_Status_Fields :: struct {
	env_override:       bool,
	env_override_valid: bool,
	bridge:             Ctl_Vault_Status_Bridge,
}

// The fields appear both at the top level (older consumers) and under "data".
Ctl_Vault_Status_Output :: struct {
	ok:                 bool,
	env_override:       bool,
	env_override_valid: bool,
	bridge:             Ctl_Vault_Status_Bridge,
	data:               Ctl_Vault_Status_Fields,
}

// ctl_vault_env_override reports whether $HEIMDALL_VAULT_KEYRING is set (non-blank)
// and whether its value is a usable keyring, mirroring source 2 of ctl_read_vault_keyring.
ctl_vault_env_override :: proc() -> (present: bool, valid: bool) {
	env_val, found := os.lookup_env("HEIMDALL_VAULT_KEYRING", context.temp_allocator)
	if !found do return false, false
	trimmed := strings.trim_space(env_val)
	if trimmed == "" do return false, false
	kr, ok := ctl_keyring_from_b64(trimmed)
	vault.keyring_wipe(&kr)
	return true, ok
}

// ctl_vault_status_bridge is the "bridge" object of the status payload:
// {"available":false} when no bridge can be asked, otherwise
// {"available":true,"status":<agent.vault.status data>} (temp-allocated).
ctl_vault_status_bridge :: proc() -> Ctl_Vault_Status_Bridge {
	endpoint, has_endpoint := os.lookup_env("HEIMDALL_BRIDGE_ENDPOINT", context.temp_allocator)
	token, has_token := os.lookup_env("HEIMDALL_AGENT_TOKEN", context.temp_allocator)
	if !has_endpoint || strings.trim_space(endpoint) == "" || !has_token || strings.trim_space(token) == "" {
		return {}
	}

	response, call_ok := ctl_agent_local_call(endpoint, token, "agent.vault.status", "{}")
	if !call_ok do return {}
	defer delete(response)

	// The bridge's vault.status data is {status, vault_status, configured,
	// permissions_valid, key_length}; forward it rather than re-deriving it.
	root, parsed := jsonx.parse_body(response, context.temp_allocator)
	if !parsed do return {}
	obj, is_obj := root.(json.Object)
	if !is_obj do return {}
	data, data_is_obj := obj["data"].(json.Object)
	if !data_is_obj do return {}
	return Ctl_Vault_Status_Bridge{available = true, status = data}
}

// ── Write-side policy (findings M2, N2) ─────────────────────────────────────
//
// There is no plaintext "vault not configured" mode: every content field ham-ctl
// sends is sealed. Without a keyring (locked or unenrolled bridge, unreachable
// bridge, invalid $HEIMDALL_VAULT_KEYRING) the command aborts.

// ctl_vault_keyring_for_write returns the keyring to seal outgoing content with,
// or prints an error and exits 1.
ctl_vault_keyring_for_write :: proc(args: []string) -> ^vault.Vault_Keyring {
	keyring, have := ctl_read_vault_keyring(args)
	if have do return keyring
	fmt.println(`{"ok":false,"message":"vault keyring unavailable; refusing to send plaintext (approve or unseal the bridge and retry)"}`)
	os.exit(1)
}

// CARD_OP_SEALED_FIELDS names, per card operation, the content fields the hub only
// STORES when it executes the op (it copies them into the issue / memory / project it
// creates), so they travel sealed. Everything else stays in clear because the hub
// must read it to execute: ids (task_id, memory_id, chain_id, project_id, agent_id,
// instance_id, target_id), status, result, attempt_no, scope/scope_type, type,
// expires_at. agent.prompt's prompt is delivered to the agent sealed by the normal
// chat path and agent.update edits identity metadata the hub indexes, so both are
// left as they are.
CARD_OP_SEALED_FIELDS :: [?][2]string{
	{"issue.create", "title"}, {"issue.create", "description"},
	{"memory.create", "title"}, {"memory.create", "body"}, {"memory.create", "description"}, {"memory.create", "evidence"},
	{"memory.update", "title"}, {"memory.update", "body"}, {"memory.update", "description"}, {"memory.update", "evidence"},
	{"project.update", "name"}, {"project.update", "description"},
}

@(private = "file")
card_op_field_sealed :: proc(op, field: string) -> bool {
	fields := CARD_OP_SEALED_FIELDS
	for f in fields do if f[0] == op && f[1] == field do return true
	return false
}

// ctl_seal_card_operations seals the store-only content fields of every operation in
// a card's `operations` JSON array (top level and inside `args`). Returns false when
// the value is not a JSON array of objects.
ctl_seal_card_operations :: proc(ops_json: string, kr: ^vault.Vault_Keyring, allocator := context.allocator) -> (string, bool) {
	value, err := json.parse_string(ops_json, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if err != nil do return "", false
	ops, is_arr := value.(json.Array)
	if !is_arr do return "", false
	seal_obj :: proc(op: string, obj: ^json.Object, kr: ^vault.Vault_Keyring) {
		for k, v in obj^ {
			s, is_str := v.(json.String)
			if is_str && card_op_field_sealed(op, k) do obj^[k] = json.String(ctl_seal_if(string(s), kr))
		}
	}
	for item in ops {
		obj, is_obj := item.(json.Object)
		if !is_obj do return "", false
		op, _ := obj["op"].(json.String)
		seal_obj(string(op), &obj, kr)
		if args, has_args := obj["args"].(json.Object); has_args do seal_obj(string(op), &args, kr)
	}
	out, merr := json.marshal(value, allocator = allocator)
	if merr != nil do return "", false
	return string(out), true
}

// ctl_seal_if seals value unless it is empty or already a valid envelope.
ctl_seal_if :: proc(value: string, kr: ^vault.Vault_Keyring) -> string {
	if value == "" || is_vault_armored(value) do return value
	return ctl_seal_or_exit(value, kr)
}
