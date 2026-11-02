package main

import "core:fmt"
import "core:os"
import "core:strings"
import httpc "odin_test:lib/httpc"

// ── ham-bridge vault prune (plan P4) ────────────────────────────────────────
// One machine can hold the vault state of several bridges (one SCOPE per (hub,
// bridge id), keystore_scope.odin). When a bridge is revoked, re-enrolled or its hub
// is gone, its scope (identity record, keyring, epoch floor, private directory)
// stays behind. `vault prune` LISTS the scopes on this machine and checks, for the
// bridge a --config names, whether its hub still accepts its bridge token. It removes
// state only when asked, and only:
//   --remove        the --config's bridge, and only when its hub REJECTED the token
//                   (401/403); an unreachable hub is "unknown" and never pruned;
//   --remove-scope <bridge_id> --hub <url>
//                   a scope the user selects explicitly (e.g. its config is gone).
// Nothing is ever deleted silently: every removal is printed.

Prune_Verdict :: enum {
	Unknown, // the hub could not be asked (offline, TLS, 5xx): keep
	Alive,   // the hub accepts this bridge's token: keep
	Dead,    // the hub rejected the token (revoked / unknown bridge): prunable
	No_Token, // the config names no bridge token: cannot be checked
}

// bridge_prune_verdict classifies the hub's answer to an authenticated bridge GET.
bridge_prune_verdict :: proc(sent: bool, status: int) -> Prune_Verdict {
	if !sent do return .Unknown
	switch status {
	case 200 ..= 299: return .Alive
	case 401, 403:    return .Dead
	}
	return .Unknown
}

prune_verdict_string :: proc(v: Prune_Verdict) -> string {
	switch v {
	case .Unknown:  return "unknown (hub not reachable; kept)"
	case .Alive:    return "alive (hub accepts the bridge token; kept)"
	case .Dead:     return "dead (hub rejected the bridge token)"
	case .No_Token: return "unchecked (no bridge token configured)"
	}
	return "unknown"
}

// bridge_prune_list_scope_dirs lists the per-scope private directories on this machine.
bridge_prune_list_scope_dirs :: proc(allocator := context.allocator) -> []string {
	base, ok := bridge_vault_bridge_dir("x", context.temp_allocator)
	if !ok do return nil
	parent := strings.trim_suffix(strings.trim_suffix(base, "/"), "x")
	names := make([dynamic]string, allocator)
	entries, err := os.read_all_directory_by_path(parent, context.temp_allocator)
	if err != nil do return names[:]
	for e in entries {
		if e.type == .Directory && keystore_bridge_id_is_enrolled(e.name) do append(&names, strings.clone(e.name, allocator))
	}
	return names[:]
}

// bridge_prune_remove deletes bridge_id's vault state under the hub currently bound.
bridge_prune_remove :: proc(bridge_id: string) -> bool {
	scope, scoped := keystore_scope_name(bridge_id)
	if !scoped do return false
	keystore_lock_and_purge(bridge_id)
	ok := keystore_delete_identity_key(bridge_id)
	ok = keystore_identity_backup_drop(bridge_id) && ok
	when ODIN_OS == .Linux {
		if keystore_android_selected() do _ = keystore_android_delete_keystore_key(bridge_id)
	}
	if dir, dir_ok := bridge_vault_bridge_dir(scope, context.temp_allocator); dir_ok && os.exists(dir) {
		_ = os.remove_all(dir)
	}
	fmt.printfln("removed vault state of %s for hub %s (scope %s)", bridge_id, bridge_keystore_hub(), scope)
	return ok
}

bridge_vault_prune_command :: proc(args: []string) -> bool {
	fmt.println("Bridge vault scopes on this machine:")
	scopes := bridge_prune_list_scope_dirs(context.temp_allocator)
	if len(scopes) == 0 do fmt.println("  (none)")
	for s in scopes do fmt.printfln("  %s", s)

	if sel := strings.trim_space(option_value(args, "--remove-scope", "")); sel != "" {
		hub := strings.trim_space(option_value(args, "--hub", ""))
		if hub == "" || !bridge_keystore_set_hub(hub) {
			fmt.eprintln("--remove-scope <bridge_id> needs --hub <url> (the hub that bridge was enrolled with)")
			return false
		}
		if !keystore_bridge_id_is_enrolled(sel) {
			fmt.eprintfln("%q is not a bridge id", sel)
			return false
		}
		return bridge_prune_remove(sel)
	}

	if strings.trim_space(option_value(args, "--config", "")) == "" {
		fmt.println("\nPass --config <path> to check a bridge against its hub (add --remove to prune it when the hub rejects it),")
		fmt.println("or --remove-scope <bridge_id> --hub <url> to remove a scope you select.")
		return true
	}
	cfg := bridge_config_from_args(args)
	bridge_id := strings.trim_space(cfg.daemon_id)
	if !keystore_bridge_id_is_enrolled(bridge_id) || !bridge_keystore_set_hub(cfg.daemon_url) {
		fmt.eprintln("the --config names no enrolled bridge with a usable hub")
		return false
	}
	scope, _ := keystore_scope_name(bridge_id)
	verdict := Prune_Verdict.No_Token
	if strings.trim_space(cfg.bridge_token) != "" {
		headers := [?]httpc.Header{httpc.bearer(cfg.bridge_token)}
		resp, err := bridge_hub_http_send_alloc({method = .GET, url = bridge_hub_url(cfg.daemon_url), path = {"api", "v1", "bridge", "actions"}, headers = headers[:]}, context.temp_allocator)
		verdict = bridge_prune_verdict(err == .None, resp.status)
	}
	fmt.printfln("\n%s (hub %s, scope %s): %s", bridge_id, bridge_keystore_hub(), scope, prune_verdict_string(verdict))
	if !has_flag(args, "--remove") do return true
	if verdict != .Dead {
		fmt.println("not removed: only a bridge whose hub rejected its token is pruned with --remove (use --remove-scope to remove one explicitly)")
		return true
	}
	return bridge_prune_remove(bridge_id)
}
