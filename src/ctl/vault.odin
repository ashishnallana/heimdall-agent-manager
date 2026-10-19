package main

import "core:crypto"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:encoding/json"
import http "odin_test:lib/http_client"
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
ctl_vault_keyring_from_response :: proc(response: string) -> (kr: vault.Vault_Keyring, ok: bool) {
	b64 := jsonx.extract_string(response, "keyring_b64", "", false, context.temp_allocator)
	defer crypto.zero_explicit(raw_data(b64), len(b64))
	epoch, epoch_ok := jsonx.extract_int_found(response, "current_epoch")
	if b64 == "" || !epoch_ok || epoch < 1 || i64(epoch) > i64(vault.MAX_EPOCH) do return {}, false
	return ctl_keyring_from_b64(b64, u32(epoch))
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
		msg := strings.concatenate({"{\"ok\":false,\"message\":\"unknown vault command: ", action, ". Run 'ham-ctl vault --help' for usage.\"}"})
		defer delete(msg)
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
	bridge_json := ctl_vault_status_bridge_json()
	defer delete(bridge_json)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	fields := strings.builder_make()
	defer strings.builder_destroy(&fields)
	strings.write_string(&fields, "\"env_override\":")
	strings.write_string(&fields, "true" if env_present else "false")
	strings.write_string(&fields, ",\"env_override_valid\":")
	strings.write_string(&fields, "true" if env_valid else "false")
	strings.write_string(&fields, ",\"bridge\":")
	strings.write_string(&fields, bridge_json)

	strings.write_string(&b, "{\"ok\":true,")
	strings.write_string(&b, strings.to_string(fields))
	strings.write_string(&b, ",\"data\":{")
	strings.write_string(&b, strings.to_string(fields))
	strings.write_string(&b, "}}")
	fmt.println(strings.to_string(b))
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

// ctl_vault_status_bridge_json renders the "bridge" object of the status payload:
// {"available":false} when no bridge can be asked, otherwise
// {"available":true,"status":<agent.vault.status data>}. The caller owns the result.
ctl_vault_status_bridge_json :: proc() -> string {
	endpoint, has_endpoint := os.lookup_env("HEIMDALL_BRIDGE_ENDPOINT", context.temp_allocator)
	token, has_token := os.lookup_env("HEIMDALL_AGENT_TOKEN", context.temp_allocator)
	if !has_endpoint || strings.trim_space(endpoint) == "" || !has_token || strings.trim_space(token) == "" {
		return strings.clone("{\"available\":false}")
	}

	response, call_ok := ctl_agent_local_call(endpoint, token, "agent.vault.status", "{}")
	if !call_ok do return strings.clone("{\"available\":false}")
	defer delete(response)

	// The bridge's vault.status data is {status, vault_status, configured,
	// permissions_valid, key_length}; forward it rather than re-deriving it.
	data_raw, data_ok := extract_json_object_raw(response, "data")
	if !data_ok do return strings.clone("{\"available\":false}")
	defer delete(data_raw)

	return strings.concatenate({"{\"available\":true,\"status\":", data_raw, "}"})
}

// ── Write-side policy (finding M2) ──────────────────────────────────────────
//
// Content ham-ctl sends must be sealed whenever the vault is configured. Having no
// keyring is NOT evidence that it is not: the bridge may be locked or unreachable.
// So without a keyring ham-ctl asks (agent.vault.status, or the hub's
// /api/v1/user/vault in user mode) and sends plaintext only when the answer is a
// definite "not configured". Anything else aborts.

Ctl_Vault_Config :: enum {
	Unknown,
	Configured,
	Not_Configured,
}

Ctl_Vault_Write :: enum {
	Seal,
	Plaintext,
	Abort,
}

// ctl_vault_write_decision is the pure policy behind ctl_vault_keyring_for_write.
ctl_vault_write_decision :: proc(have_keyring: bool, env_override_invalid: bool, cfg: Ctl_Vault_Config) -> Ctl_Vault_Write {
	if have_keyring do return .Seal
	if env_override_invalid do return .Abort
	if cfg == .Not_Configured do return .Plaintext
	return .Abort
}

// ctl_vault_config_from_agent_status reads agent.vault.status's response: only
// {"status":"disabled","configured":false} is Not_Configured.
ctl_vault_config_from_agent_status :: proc(response: string) -> Ctl_Vault_Config {
	parsed, ok := jsonx.parse_body(response, context.temp_allocator)
	if !ok do return .Unknown
	root, is_obj := parsed.(json.Object)
	if !is_obj do return .Unknown
	data, has_data := root["data"].(json.Object)
	if !has_data do return .Unknown
	status, s_ok := data["status"].(json.String)
	configured, c_ok := data["configured"].(json.Boolean)
	if !s_ok || !c_ok do return .Unknown
	if string(status) == "disabled" && !bool(configured) do return .Not_Configured
	if string(status) == "locked" || string(status) == "unlocked" || bool(configured) do return .Configured
	return .Unknown
}

// ctl_vault_config_probe is how ctl_vault_keyring_for_write learns the vault's
// state. Test builds never contact a bridge or hub: they answer Not_Configured
// (the pre-M2 behaviour the param-builder suites assert), and the fail-closed
// policy itself is covered through ctl_vault_write_decision.
when ODIN_TEST {
	ctl_vault_config_probe := proc(transport: Ctl_Transport) -> Ctl_Vault_Config { return .Not_Configured }
} else {
	ctl_vault_config_probe := ctl_vault_config_probe_live
}

// ctl_vault_config_probe_live asks the bridge (agent transport or the agent env)
// or, in user mode, the hub.
ctl_vault_config_probe_live :: proc(transport: Ctl_Transport) -> Ctl_Vault_Config {
	endpoint, token := transport.agent_endpoint, transport.agent_token
	if transport.kind != .Agent || endpoint == "" || token == "" {
		endpoint, _ = os.lookup_env("HEIMDALL_BRIDGE_ENDPOINT", context.temp_allocator)
		token, _ = os.lookup_env("HEIMDALL_AGENT_TOKEN", context.temp_allocator)
	}
	if strings.trim_space(endpoint) != "" && strings.trim_space(token) != "" {
		response, ok := ctl_agent_local_call(endpoint, token, "agent.vault.status", "{}")
		if !ok do return .Unknown
		defer delete(response)
		return ctl_vault_config_from_agent_status(response)
	}
	if transport.kind == .User && transport.user_base_url != "" && transport.user_token != "" {
		full_path := hub_url_path_prefix_join(transport.user_base_url, "/api/v1/user/vault")
		headers := [?]http.Header{{name = "Authorization", value = strings.concatenate({"Bearer ", transport.user_token}, context.temp_allocator)}}
		resp, ok := http.request_with_headers_timeout("GET", transport.user_base_url, full_path, "", headers[:], http.DEFAULT_TIMEOUT_MS)
		if !ok do return .Unknown
		if resp.status == 200 do return .Configured
		if resp.status == 404 && strings.contains(resp.body, `"configured":false`) do return .Not_Configured
	}
	return .Unknown
}

// ctl_vault_keyring_for_write returns the keyring to seal outgoing content with
// (ok=true), or ok=false only when the vault is definitely not configured, in which
// case plaintext is allowed. In every other case it prints an error and exits 1.
ctl_vault_keyring_for_write :: proc(args: []string, transport: Ctl_Transport = {}) -> (kr: ^vault.Vault_Keyring, ok: bool) {
	keyring, have := ctl_read_vault_keyring(args)
	env_present, env_valid := ctl_vault_env_override()
	cfg := Ctl_Vault_Config.Unknown
	if !have && !(env_present && !env_valid) do cfg = ctl_vault_config_probe(transport)
	switch ctl_vault_write_decision(have, env_present && !env_valid, cfg) {
	case .Seal:
		return keyring, true
	case .Plaintext:
		return nil, false
	case .Abort:
	}
	fmt.println(`{"ok":false,"message":"vault keyring unavailable and the vault is not known to be unconfigured; refusing to send plaintext (unlock the bridge vault and retry)"}`)
	os.exit(1)
}

// ctl_user_transport wraps hub user-mode credentials for ctl_vault_keyring_for_write.
ctl_user_transport :: proc(base, token: string) -> Ctl_Transport {
	return Ctl_Transport{kind = .User, user_base_url = base, user_token = token}
}
