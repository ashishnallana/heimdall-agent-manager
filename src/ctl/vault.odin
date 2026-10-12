package main

import "core:fmt"
import "core:os"
import "core:strings"

// ── vault verb group (REQ-VAULT-BRIDGE-CLI-1) ──────────────────────────────
// Reports where ham-ctl gets its 256-bit AES-GCM vault key from. ham-ctl stores no
// key of its own: it uses $HEIMDALL_VAULT_KEY when set, otherwise the key the local
// bridge holds (enable encryption and unseal each bridge from Settings -> Bridges).

print_vault_help :: proc() {
	fmt.println("ham-ctl vault — inspect the zero-knowledge vault key source")
	fmt.println("")
	fmt.println("USAGE:")
	fmt.println("  ham-ctl vault status")
	fmt.println("")
	fmt.println("The key comes from $HEIMDALL_VAULT_KEY (single-bridge dev override) or,")
	fmt.println("otherwise, the local bridge. Unseal a bridge from Settings -> Bridges.")
}

is_valid_hex_key :: proc(key: string) -> bool {
	if len(key) != 64 do return false
	for i in 0 ..< len(key) {
		ch := key[i]
		switch ch {
		case '0'..='9', 'a'..='f', 'A'..='F':
		case:
			return false
		}
	}
	return true
}

// ctl_read_vault_key resolves the vault key from, in order:
//   1. --vault-key <hex>
//   2. $HEIMDALL_VAULT_KEY (a single-bridge dev override)
//   3. the local bridge, via agent.vault.get (agent mode only)
//
// Sources 1 and 2 are EXPLICIT: if either is present but not a valid key it is
// rejected immediately and the bridge is NOT consulted, so a typo'd key surfaces as
// an error instead of silently resolving to a different one. Only genuine ABSENCE
// falls through to the bridge.
//
// The bridge is the only implicit source because it is the only one that holds the
// key live: it is unsealed per bridge from the UI and keeps its key in the keyring /
// Keychain, so an agent that asks it on each invocation picks up an unseal or a
// rotation with no respawn. The fetched key is never written to disk.
//
// DO NOT add a file source back. ham-ctl used to read the machine-wide
// ~/.config/heimdall/vault_key here; that file was shared by every bridge on the
// host, so it could hand one bridge's agents another bridge's key. It is no longer
// created, read or migrated by anything — an existing file is simply ignored
// (pinned by test_vault_legacy_key_file_is_ignored).
ctl_read_vault_key :: proc(args: []string = nil, allocator := context.allocator) -> (key_hex: string, ok: bool) {
	// 1. Check --vault-key command line flag if args passed
	if args != nil && has_flag(args, "--vault-key") {
		flag_val := option_value(args, "--vault-key", "")
		trimmed := strings.trim_space(flag_val)
		if len(trimmed) == 64 && is_valid_hex_key(trimmed) {
			return strings.clone(trimmed, allocator), true
		}
		// Explicit flag provided but invalid hex key: reject immediately, do NOT fall through
		return "", false
	}

	// 2. Check environment variable HEIMDALL_VAULT_KEY
	if env_val, found := os.lookup_env("HEIMDALL_VAULT_KEY", context.temp_allocator); found {
		trimmed := strings.trim_space(env_val)
		if trimmed != "" {
			if len(trimmed) == 64 && is_valid_hex_key(trimmed) {
				return strings.clone(trimmed, allocator), true
			}
			// Explicit env var set but invalid hex key: reject immediately, do NOT fall through
			return "", false
		}
	}

	// 3. Ask the live bridge.
	return ctl_vault_key_from_bridge(allocator)
}

// ctl_vault_key_from_bridge is source 3 of ctl_read_vault_key: ask the local bridge
// for the key it currently holds. Reached only once sources 1 and 2 are both absent.
//
// It deliberately uses ctl_agent_local_call, NOT ctl_agent_call: the latter prints
// the response to stdout and os.exit(1)s on failure, which inside a decrypt path
// would corrupt the JSON of every command that needs a key. We need the value
// returned to us, and an unreachable bridge must be an ordinary "no key".
//
// Any failure — no endpoint, no token, unreachable socket, an error response such
// as `not_found`, malformed JSON, or a key that is not 64 hex chars — resolves to
// ("", false), i.e. exactly the "no key" the caller already handles by emitting the
// [Encrypted: ...] fallback. It never aborts and never partially applies a key.
ctl_vault_key_from_bridge :: proc(allocator := context.allocator) -> (key_hex: string, ok: bool) {
	// Agent mode only: in hub mode these are unset and behaviour is unchanged.
	endpoint, has_endpoint := os.lookup_env("HEIMDALL_BRIDGE_ENDPOINT", context.temp_allocator)
	if !has_endpoint || strings.trim_space(endpoint) == "" do return "", false
	token, has_token := os.lookup_env("HEIMDALL_AGENT_TOKEN", context.temp_allocator)
	if !has_token || strings.trim_space(token) == "" do return "", false

	response, call_ok := ctl_agent_local_call(endpoint, token, "agent.vault.get", "{}")
	if !call_ok do return "", false
	// We own the response buffer, and the key is cloned out below, so release it
	// rather than leaving the whole read buffer alive for the rest of the process.
	defer delete(response)

	return ctl_vault_key_from_response(response, allocator)
}

// ctl_vault_key_from_response pulls the key out of an agent.vault.get response and
// validates it. Split out from the socket call so the parsing and validation rules
// can be tested exhaustively without standing up a bridge.
//
// Returns ("", false) for every non-conforming response: an error envelope such as
// `not_found` (which has no "key" member at all), truncated or malformed JSON, or a
// value that is not exactly 64 hex characters. There is deliberately no separate
// `"ok":true` check — absence of a usable key is already the same outcome, and
// validating the value itself is the stronger test.
ctl_vault_key_from_response :: proc(response: string, allocator := context.allocator) -> (key_hex: string, ok: bool) {
	// The matched pattern is `"key":"`, so this cannot pick up "key_length".
	fetched := strings.trim_space(extract_json_string(response, "key", ""))
	if len(fetched) != 64 || !is_valid_hex_key(fetched) do return "", false
	return strings.clone(fetched, allocator), true
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

// ctl_vault_status reports the two places a key can come from: whether a
// $HEIMDALL_VAULT_KEY override is present (and well formed), and the bridge's own
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

// ctl_vault_env_override reports whether $HEIMDALL_VAULT_KEY is set (non-blank) and
// whether its value is a usable key, mirroring source 2 of ctl_read_vault_key.
ctl_vault_env_override :: proc() -> (present: bool, valid: bool) {
	env_val, found := os.lookup_env("HEIMDALL_VAULT_KEY", context.temp_allocator)
	if !found do return false, false
	trimmed := strings.trim_space(env_val)
	if trimmed == "" do return false, false
	return true, len(trimmed) == 64 && is_valid_hex_key(trimmed)
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
