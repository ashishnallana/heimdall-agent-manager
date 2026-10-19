package main

import "core:fmt"
import "core:os"
import "core:strings"
import cfg_lib "odin_test:lib/config"

// ===== Credential file ownership (multi-bridge isolation) =====
//
// Several bridges can run on one machine for different hubs. A credential file that
// two of them share is a credential leak: enrolling bridge B over A's file makes A
// present B's token to A's hub. So:
//
//  - the default credential path is per (hub, bridge id) scope, the same scope that
//    names the bridge's keystore items: ~/.config/heimdall/bridges/<scope>/bridge-token;
//  - the access-token file starts with a fixed header naming its owner,
//      "heimdall-bridge-credential/v1 <canonical hub base> <bridge id>\n<token>\n"
//    and a running enrolled bridge refuses a file that names another hub or bridge
//    (or none);
//  - `ham-bridge enroll` refuses to write over a credential file owned by another
//    hub or bridge.
// The refresh token lives beside the access token (bridge_enroll_refresh_file_for),
// so the owner header of the access file covers the pair.

BRIDGE_CREDENTIAL_HEADER :: "heimdall-bridge-credential/v1"
BRIDGE_CREDENTIAL_FILE_NAME :: "bridge-token"

Bridge_Credential_Owner_Status :: enum {
	Missing,   // no such file
	Unowned,   // readable but no (or a malformed) owner header
	Owned,
}

// bridge_credential_file_text is the on-disk form of an access token for (hub, bridge).
// "" when hub is not a usable URL or bridge_id is not an enrolled id.
bridge_credential_file_text :: proc(hub_url, bridge_id, token: string, allocator := context.temp_allocator) -> string {
	base, ok := bridge_hub_canonical_base(hub_url, context.temp_allocator)
	if !ok || !keystore_bridge_id_is_enrolled(bridge_id) || strings.contains_any(strings.trim_space(token), " \r\n") do return ""
	return strings.concatenate({BRIDGE_CREDENTIAL_HEADER, " ", base, " ", bridge_id, "\n", strings.trim_space(token)}, allocator)
}

// bridge_write_credential_file writes an access token with its owner header (0600, atomic).
bridge_write_credential_file :: proc(path, hub_url, bridge_id, token: string) -> bool {
	if strings.trim_space(token) == "" do return bridge_write_secret_file(path, "")
	text := bridge_credential_file_text(hub_url, bridge_id, token)
	if text == "" {
		fmt.eprintln("refusing to write a credential with no usable owner (hub/bridge id) to", path)
		return false
	}
	return bridge_write_secret_file(path, text)
}

// bridge_credential_split separates the owner header from the token. With no header
// the whole text is the token (refresh files, tokens given by hand); owned is false.
bridge_credential_split :: proc(text: string) -> (token, hub, bridge_id: string, owned: bool) {
	t := strings.trim_space(text)
	if !strings.has_prefix(t, BRIDGE_CREDENTIAL_HEADER) do return t, "", "", false
	nl := strings.index_byte(t, '\n')
	if nl < 0 do return "", "", "", false
	fields := strings.fields(strings.trim_space(t[:nl]), context.temp_allocator)
	token = strings.trim_space(t[nl + 1:])
	if len(fields) != 3 || fields[0] != BRIDGE_CREDENTIAL_HEADER || token == "" || strings.contains_any(token, " \r\n") do return "", "", "", false
	return token, fields[1], fields[2], true
}

// bridge_credential_file_owner reads the owner header of a credential file.
// hub and bridge_id are temp-allocated.
bridge_credential_file_owner :: proc(path: string) -> (hub, bridge_id: string, status: Bridge_Credential_Owner_Status) {
	p := strings.trim_space(path)
	if p == "" || !os.exists(p) do return "", "", .Missing
	data, err := os.read_entire_file(p, context.temp_allocator)
	if err != nil do return "", "", .Unowned
	_, h, id, owned := bridge_credential_split(string(data))
	if !owned do return "", "", .Unowned
	return strings.clone(h, context.temp_allocator), strings.clone(id, context.temp_allocator), .Owned
}

// bridge_credential_file_belongs_to reports whether path is owned by exactly (hub, bridge_id).
bridge_credential_file_belongs_to :: proc(path, hub_url, bridge_id: string) -> bool {
	want, ok := bridge_hub_canonical_base(hub_url, context.temp_allocator)
	if !ok do return false
	hub, id, status := bridge_credential_file_owner(path)
	return status == .Owned && hub == want && id == bridge_id
}

// bridge_enroll_default_credential_path is the one place that knows where a
// credential goes when the operator named no path: shared by `enroll` (which writes
// it) and by startup (which reads it), so the two cannot drift apart. It is per
// (hub, bridge id) scope, inside the bridge's private state directory, so two bridges
// never share it. "" when HOME is unset, the hub is unusable or the id is not an
// enrolled one (an unenrolled bridge has no default credential).
bridge_enroll_default_credential_path :: proc(hub_url, bridge_id: string, allocator := context.allocator) -> string {
	scope, ok := keystore_scope_name_for_hub(hub_url, strings.trim_space(bridge_id))
	if !ok do return ""
	dir, dir_ok := bridge_vault_bridge_dir(scope, context.temp_allocator)
	if !dir_ok || strings.has_prefix(dir, "~") do return ""
	return strings.concatenate({dir, BRIDGE_CREDENTIAL_FILE_NAME}, allocator)
}

// bridge_enroll_token_file_conflict reports an EXISTING credential file that
// `ham-bridge enroll` must not overwrite: one owned by another hub or another bridge
// than `replacing` (the bridge id this config is enrolled as, if any), or one with no
// owner header at all.
bridge_enroll_token_file_conflict :: proc(token_file, hub_url, replacing: string) -> (reason: string, conflict: bool) {
	hub, id, status := bridge_credential_file_owner(token_file)
	switch status {
	case .Missing:
		return "", false
	case .Unowned:
		return "it holds a credential with no owner record", true
	case .Owned:
		want, ok := bridge_hub_canonical_base(hub_url, context.temp_allocator)
		if !ok || hub != want do return strings.concatenate({"it belongs to a bridge of hub ", hub}, context.temp_allocator), true
		if id != strings.trim_space(replacing) do return strings.concatenate({"it belongs to bridge ", id, " (a different bridge than this config's)"}, context.temp_allocator), true
	}
	return "", false
}

// bridge_enroll_config_bridge_id is the bridge id the config at config_path is
// enrolled as ("" when none).
bridge_enroll_config_bridge_id :: proc(config_path: string) -> string {
	if strings.trim_space(config_path) == "" do return ""
	loaded, ok := cfg_lib.load(config_path)
	if !ok do return ""
	id := strings.trim_space(loaded.config.daemon.daemon_id)
	return strings.clone(id, context.temp_allocator) if keystore_bridge_id_is_enrolled(id) else ""
}
