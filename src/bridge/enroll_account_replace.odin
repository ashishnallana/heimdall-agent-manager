package main

// Enrollment hardening (audit F1, F2, F7, F21; REQ-ENR-1, REQ-ENR-12).
//
// - Account replace (F1): a machine enrolled to account A that enrolls under account
//   B asks for explicit confirmation (--replace-other-account, else an interactive
//   prompt), revokes A's bridge on the hub with A's own token (best effort), wipes
//   A's local secrets, and only then writes B's credential. Declined or impossible
//   to confirm, the freshly approved bridge of B is revoked instead, so the hub is
//   not left with a bridge nobody runs.
// - Running service (F2): enroll stops its own profile's service before it takes
//   the config lock, and starts it again if the enrollment fails.
// - Needs re-enrollment (F21, F7): a hub that refused this bridge's credential
//   (revoked, refresh 401, credential missing, vault key never delivered) leaves a
//   bridgesvc marker; the bridge PARKS on it instead of exiting non-zero, so its
//   supervisor does not crash-loop it, and `status --json` reports
//   state=needs_reenrollment with the command that recovers it.

import "core:bufio"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import cfg_lib "odin_test:lib/config"
import bridgesvc "odin_test:lib/bridgesvc"
import httpc "odin_test:lib/httpc"

BRIDGE_ENROLL_REPLACE_ACCOUNT_FLAG :: "--replace-other-account"
BRIDGE_SELF_REVOKE_PATH :: [?]string{"api", "v1", "bridge", "self", "revoke"}

// ===== Account replace =====

Bridge_Account_Decision :: enum {
	Same_Account, // nothing to replace (no previous owner, or the same account)
	Replace,      // another account; replacing it was confirmed
	Refuse,       // another account; not confirmed
}

// Bridge_Confirm answers the interactive question: .Unavailable when there is no
// terminal to ask on (installers, Electron), which counts as "not confirmed".
Bridge_Confirm :: enum {
	Unavailable,
	Yes,
	No,
}

// bridge_enroll_account_decision is the pure policy. An unknown owner on either side
// (an older hub, an identity record without one) is not proof of another account, so
// it is treated as the same one: the existing re-enroll path keeps handling it.
bridge_enroll_account_decision :: proc(old_owner, new_owner: string, flag_given: bool, confirm: Bridge_Confirm) -> Bridge_Account_Decision {
	old_o, new_o := strings.trim_space(old_owner), strings.trim_space(new_owner)
	if old_o == "" || new_o == "" || old_o == new_o do return .Same_Account
	if flag_given || confirm == .Yes do return .Replace
	return .Refuse
}

// bridge_enroll_previous_owner is the account that approved old_bridge_id on this
// machine ("" when there is no such identity record). Temp-allocated.
bridge_enroll_previous_owner :: proc(old_bridge_id: string) -> string {
	if !keystore_bridge_id_is_enrolled(old_bridge_id) do return ""
	rec: Bridge_Identity_Record
	defer mem.zero_explicit(&rec, size_of(rec))
	if keystore_read_identity(old_bridge_id, &rec) != .Found do return ""
	return strings.clone(bridge_identity_record_owner(&rec), context.temp_allocator)
}

// bridge_enroll_ask_replace asks on the terminal. Any answer but y/yes is "no".
bridge_enroll_ask_replace :: proc(args: []string, old_bridge_id: string) -> Bridge_Confirm {
	if !bridge_stdin_is_terminal(args) do return .Unavailable
	fmt.printfln("This machine is enrolled as bridge %s of ANOTHER Heimdall account.", old_bridge_id)
	fmt.println("  Replacing it revokes that bridge on the hub and deletes its credential, identity and vault key here.")
	fmt.print("  Replace it with the account that just approved? [y/N] ")
	r: bufio.Reader
	bufio.reader_init(&r, os.to_stream(os.stdin), 256, context.temp_allocator)
	line, err := bufio.reader_read_string(&r, '\n', context.temp_allocator)
	if err != nil && err != .EOF do return .No
	switch strings.to_lower(strings.trim_space(line), context.temp_allocator) {
	case "y", "yes": return .Yes
	}
	return .No
}

// Never prompts for --headless / --json-progress (installers, Electron), whatever stdin is.
bridge_stdin_is_terminal :: proc(args: []string) -> bool {
	if has_flag(args, "--headless") || has_flag(args, "--json-progress") do return false
	return os.is_tty(os.stdin)
}

// bridge_self_revoke asks the hub to revoke the bridge that token belongs to (POST
// /api/v1/bridge/self/revoke). Best effort: a hub that is down or predates the route
// leaves the bridge for the owner to revoke in Settings -> Devices.
bridge_self_revoke :: proc(api_base, token: string) -> (ok: bool, detail: string) {
	t := strings.trim_space(token)
	if t == "" do return false, "no credential"
	auth := strings.concatenate({"Bearer ", t}, context.temp_allocator)
	path := BRIDGE_SELF_REVOKE_PATH
	resp, err := httpc.send({
		method = .POST, url = bridge_hub_url(api_base), path = path[:],
		headers = {{name = "Authorization", value = auth}},
		body = httpc.json_body(struct{}{}), timeout_ms = 10_000,
	})
	defer httpc.response_destroy(&resp)
	if err != .None do return false, httpc.error_string(err)
	// 401/403: the hub already refuses this token (revoked, expired, past its
	// lifetime): it cannot be used again, which is all a revoke achieves.
	if resp.status == 200 || resp.status == 401 || resp.status == 403 do return true, ""
	// 404: a still-pending (atomic) enrollment; the hub rolls it back at its deadline.
	return false, fmt.tprintf("HTTP %d", resp.status)
}

// bridge_enroll_old_token reads old_bridge_id's access token from its credential
// file (the explicit --bridge-token-file, else the per-bridge default). Temp-allocated.
bridge_enroll_old_token :: proc(args: []string, api_base, old_bridge_id: string) -> (token, path: string) {
	path = bridge_enroll_token_file_from_args(args, api_base, old_bridge_id, context.temp_allocator)
	if path == "" || !os.exists(path) do return "", path
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return "", path
	tok, _, id, owned := bridge_credential_split(string(data))
	if owned && id != old_bridge_id do return "", path
	return tok, path
}

// bridge_enroll_wipe_bridge deletes every local secret of bridge_id: its access and
// refresh token files (and rotation leftovers), vault keyring, identity record and
// epoch floor, its re-enroll journal and any needs-reenrollment marker. Returns the
// paths it could not remove.
bridge_enroll_wipe_bridge :: proc(config_path, token_file, bridge_id: string) -> (failed: [dynamic]string) {
	failed = make([dynamic]string, context.temp_allocator)
	if token_file != "" {
		for suffix in ([?]string{"", ".pending-rotation-v1", BRIDGE_ENROLL_MARKER_SUFFIX}) {
			p := strings.concatenate({token_file, suffix}, context.temp_allocator)
			if os.exists(p) && os.remove(p) != nil do append(&failed, p)
		}
		for p in ([?]string{bridge_enroll_refresh_file_for(token_file, context.temp_allocator), bridge_refresh_request_path(token_file, context.temp_allocator)}) {
			if os.exists(p) && os.remove(p) != nil do append(&failed, p)
		}
	}
	keystore_lock_and_purge(bridge_id)
	if !keystore_delete_identity_key(bridge_id) do append(&failed, fmt.tprintf("identity of %s", bridge_id))
	if config_path != "" {
		_ = os.remove(bridge_reenroll_journal_path(config_path))
		bridge_reenroll_clear(config_path)
	}
	return
}

// bridge_enroll_resolve_account runs after approval and before anything of the new
// bridge is written. ok=false aborts the enrollment (the new bridge was revoked).
bridge_enroll_resolve_account :: proc(args: []string, api_base, config_path, old_bridge_id: string, cred: Bridge_Enroll_Credential) -> (ok: bool, replaced: bool) {
	if old_bridge_id == "" || old_bridge_id == cred.bridge_id do return true, false
	old_owner := bridge_enroll_previous_owner(old_bridge_id)
	flag := has_flag(args, BRIDGE_ENROLL_REPLACE_ACCOUNT_FLAG)
	confirm := Bridge_Confirm.Unavailable
	if !flag && old_owner != "" && old_owner != cred.owner_user_id do confirm = bridge_enroll_ask_replace(args, old_bridge_id)
	switch bridge_enroll_account_decision(old_owner, cred.owner_user_id, flag, confirm) {
	case .Same_Account:
		return true, false
	case .Refuse:
		fmt.eprintfln("bridge enroll REFUSED: this machine is enrolled as %s by another Heimdall account; nothing was written.", old_bridge_id)
		fmt.eprintfln("  To replace it, run again with %s (or answer yes at the prompt).", BRIDGE_ENROLL_REPLACE_ACCOUNT_FLAG)
		if rv_ok, detail := bridge_self_revoke(api_base, cred.access_token); rv_ok {
			fmt.eprintfln("  The bridge %s the approval just created was revoked again.", cred.bridge_id)
		} else {
			fmt.eprintfln("  Revoke the just-approved bridge %s in Settings -> Devices (%s).", cred.bridge_id, detail)
		}
		return false, false
	case .Replace:
	}
	fmt.printfln("Replacing bridge %s of another account with %s", old_bridge_id, cred.bridge_id)
	old_token, old_path := bridge_enroll_old_token(args, api_base, old_bridge_id)
	if rv_ok, detail := bridge_self_revoke(api_base, old_token); rv_ok {
		fmt.printfln("  revoked %s on the hub", old_bridge_id)
	} else {
		fmt.eprintfln("  could not revoke %s on the hub (%s); its owner can revoke it in Settings -> Devices", old_bridge_id, detail)
	}
	if failed := bridge_enroll_wipe_bridge(config_path, old_path, old_bridge_id); len(failed) > 0 {
		fmt.eprintfln("bridge enroll FAILED: could not delete the previous account's secrets: %s. Nothing of the new bridge was written.", strings.join(failed[:], ", ", context.temp_allocator))
		_, _ = bridge_self_revoke(api_base, cred.access_token)
		return false, false
	}
	fmt.printfln("  deleted %s's credential, identity and vault key from this machine", old_bridge_id)
	return true, true
}

// ===== Running service (F2) =====

// bridge_enroll_stop_own_service stops this profile's registered service when it is
// running so the enrollment can take the config lock. Returns the service name to
// start again when the enrollment fails ("" when nothing was stopped).
bridge_enroll_stop_own_service :: proc(args: []string) -> (stopped: string) {
	host := bridge_service_host()
	name, installed := bridge_enroll_service_for(host, args)
	if !installed do return ""
	if !bridge_service_running(host, bridgesvc.layout_for(host, name)) do return ""
	fmt.printfln("bridge enroll: stopping the running service %s for the enrollment", name)
	if ok, out := bridge_service_action(host, name, .Stop); !ok {
		fmt.eprintfln("  could not stop %s (%s); trying anyway", name, out)
		return ""
	}
	return name
}

// bridge_enroll_config_lock_retry takes the config lock, retrying while a service
// that was just stopped releases it (process exit is asynchronous to the stop).
bridge_enroll_config_lock_retry :: proc(config_path: string, wait_ms: int) -> (lock_path: string, ok: bool) {
	deadline := time.tick_now()
	for {
		lock_path, ok = bridge_config_lock(config_path)
		if ok || time.duration_milliseconds(time.tick_since(deadline)) >= f64(wait_ms) do return
		time.sleep(250 * time.Millisecond)
	}
}

// ===== Needs re-enrollment (F21, F7) =====

Bridge_Reenroll_Reason :: enum {
	Revoked,
	Refresh_Rejected,
	Credential_Missing,
	Vault_Key_Timeout,
}

bridge_reenroll_reason_word :: proc(r: Bridge_Reenroll_Reason) -> string {
	switch r {
	case .Revoked:            return "revoked"
	case .Refresh_Rejected:   return "refresh_rejected"
	case .Credential_Missing: return "credential_missing"
	case .Vault_Key_Timeout:  return "vault_key_timeout"
	}
	return "revoked"
}

// bridge_reenroll_hint is the command that recovers the profile: an enrollment of
// the same config against the same hub, offering the old id for reuse.
bridge_reenroll_hint :: proc(api_base, config_path: string) -> string {
	hub := api_base if strings.trim_space(api_base) != "" else "<url>"
	if config_path == "" do return fmt.tprintf("ham-bridge enroll --hub %s", hub)
	return fmt.tprintf("ham-bridge enroll --hub %s --config %s", hub, config_path)
}

bridge_reenroll_state_dir :: proc(config_path: string) -> string {
	p := cfg_lib.expand_home(config_path)
	if p == "" do return ""
	return bridgesvc.pdir(p)
}

// bridge_reenroll_mark records that the hub refused this profile's credential.
bridge_reenroll_mark :: proc(config_path, api_base, bridge_id: string, reason: Bridge_Reenroll_Reason) {
	dir := bridge_reenroll_state_dir(config_path)
	if dir == "" || !os.is_dir(dir) do return
	m := bridgesvc.Reenroll_Marker {
		bridge_id = strings.trim_space(bridge_id),
		hub       = api_base,
		reason    = bridge_reenroll_reason_word(reason),
		hint      = bridge_reenroll_hint(api_base, config_path),
		at        = time.to_unix_seconds(time.now()),
	}
	if !bridgesvc.write_reenroll_marker(dir, m) do fmt.eprintln("bridge: could not write the needs-reenrollment marker in", dir)
}

bridge_reenroll_clear :: proc(config_path: string) {
	if dir := bridge_reenroll_state_dir(config_path); dir != "" do bridgesvc.clear_reenroll_marker(dir)
}

// bridge_reenroll_pending reports a marker that applies to bridge_id.
bridge_reenroll_pending :: proc(config_path, bridge_id: string) -> (m: bridgesvc.Reenroll_Marker, pending: bool) {
	dir := bridge_reenroll_state_dir(config_path)
	if dir == "" do return {}, false
	m, pending = bridgesvc.read_reenroll_marker(dir)
	if !pending do return
	id := strings.trim_space(bridge_id)
	return m, bridgesvc.reenroll_marker_applies(m, keystore_bridge_id_is_enrolled(id), id)
}

// bridge_reenroll_park keeps the process alive and idle (no listener, no hub
// connection) until the marker goes away, then exits 0 so the supervisor starts a
// fresh process with whatever the re-enrollment wrote. Exiting non-zero instead is
// what made Restart=on-failure / KeepAlive crash-loop a revoked bridge.
bridge_reenroll_park :: proc(config_path: string, m: bridgesvc.Reenroll_Marker) -> ! {
	fmt.eprintfln("ham-bridge: the hub no longer accepts bridge %s (%s). Waiting for re-enrollment: %s", m.bridge_id, m.reason, m.hint)
	bridge_local_status_write(false)
	dir := bridge_reenroll_state_dir(config_path)
	for {
		time.sleep(30 * time.Second)
		if _, still := bridgesvc.read_reenroll_marker(dir); !still do os.exit(0)
	}
}
